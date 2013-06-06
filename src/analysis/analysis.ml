open Form
open FormUtil
open Prog

(** Infer sets of accessed and modified variables *)
(* Todo: the fix-point loop is brain damaged - rather use a top. sort of the call graph *)
let infer_accesses prog =
  let rec pm prog = function
    | Loop (lc, pp) ->
        let has_new1, prebody1 = pm prog lc.loop_prebody in
        let has_new2, postbody1 = pm prog lc.loop_postbody in
        has_new1 || has_new2, 
        mk_loop_cmd lc.loop_inv prebody1 lc.loop_test postbody1 pp.pp_pos
    | Choice (cs, pp) ->
        let has_new, mods, accs, cs1 = 
          List.fold_right 
            (fun c (has_new, mods, accs, cs1) ->
              let has_new1, c1 = pm prog c in
              has_new1 || has_new, 
              IdSet.union (modifies c1) mods, 
              IdSet.union (accesses c1) accs, 
              c1 :: cs1)
            cs (false, IdSet.empty, IdSet.empty, [])
        in
        let pp1 = {pp with pp_modifies = mods; pp_accesses = accs} in
        has_new, Choice (cs1, pp1)
    | Seq (cs, pp) ->
        let has_new, mods, accs, cs1 = 
          List.fold_right 
            (fun c (has_new, mods, accs, cs1) ->
              let has_new1, c1 = pm prog c in
              has_new1 || has_new, 
              IdSet.union (modifies c1) mods, 
              IdSet.union (accesses c1) accs, 
              c1 :: cs1)
            cs (false, IdSet.empty, IdSet.empty, [])
        in
        let pp1 = {pp with pp_modifies = mods; pp_accesses = accs} in
        has_new, Seq (cs1, pp1)
    | Basic (Call cc, pp) ->
        let callee = find_proc prog cc.call_name in
        let mods = modifies_proc prog callee in
        let accs = accesses_proc prog callee in
        let has_new = 
          not (IdSet.subset mods pp.pp_modifies) ||  
          not (IdSet.subset accs pp.pp_accesses)
        in
        let pp1 = {pp with pp_modifies = mods; pp_accesses = accs} in
        has_new, Basic (Call cc, pp1)
    | c ->  false, c
  in
  let pm_pred prog pred =
    let accs_preds, body_accs =
      match pred.pred_body.spec_form with
      | SL f -> 
          let accs_preds = SlUtil.preds f in
          let accs = SlUtil.free_consts f in
          accs_preds, accs
      | FOL f -> IdSet.empty, free_consts f
    in
    let accs = 
      IdSet.fold (fun p -> 
        let opred = find_pred prog p in
        IdSet.union opred.pred_accesses)
        accs_preds body_accs
    in
    let global_accs = 
      IdSet.filter (fun id -> IdMap.mem id prog.prog_vars) accs
    in
    not (IdSet.subset global_accs pred.pred_accesses),
    { pred with pred_accesses = global_accs }
  in
  let rec pm_prog prog = 
    let procs = procs prog in
    let has_new, procs1 =
      List.fold_left 
        (fun (has_new, procs1) proc ->
          match proc.proc_body with
          | Some body ->
              let has_new1, body1 = pm prog body in
              let proc1 = {proc with proc_body = Some body1} in
              (has_new || has_new1, proc1 :: procs1)
          | None -> (has_new, proc :: procs1))
        (false, []) procs
    in 
    let procs2 = 
      List.fold_left 
      (fun procs2 proc -> IdMap.add proc.proc_name proc procs2) 
      IdMap.empty procs1
    in
    let preds = preds prog in
    let has_new, preds1 = 
      List.fold_left 
        (fun (has_new, preds1) pred ->
          let has_new1, pred1 = pm_pred prog pred in
          (has_new || has_new1, pred1 :: preds1))
        (has_new, []) preds
    in
    let preds2 = 
      List.fold_left 
      (fun preds2 pred -> IdMap.add pred.pred_name pred preds2)
      IdMap.empty preds1
    in
    let prog1 = 
      { prog with 
        prog_procs = procs2;
        prog_preds = preds2 
      } in
    if has_new then pm_prog prog1 else prog1 
  in
  pm_prog prog


(** Transform loops into tail recursive procedures. *)
let elim_loops (prog : program) =
  let rec elim prog proc = function
    | Loop (lc, pp) -> 
        let proc_name = 
          fresh_ident ((str_of_ident proc.proc_name) ^ "_loop") 
        in
        let locals = 
          IdMap.filter 
            (fun id _ -> IdSet.mem id pp.pp_accesses)
            proc.proc_locals
        in
        let returns, return_decls = 
          IdMap.fold 
            (fun id decl (returns, decls) -> id :: returns, decl :: decls)
            locals ([], [])
        in
        let subst_formals, formals, locals =
          List.fold_right
            (fun decl (sm, ids, locals) -> 
              let init_id = fresh_ident (FormUtil.name decl.var_name ^ "_init") in
              let init_decl = { decl with var_name = init_id } in
              IdMap.add decl.var_name init_id sm, 
              init_id :: ids,
              IdMap.add init_id init_decl locals
            )
            return_decls (IdMap.empty, [], locals)
        in    
        let id_to_term id =
          let decl = IdMap.find id locals in
          mk_free_const ~srt:decl.var_sort id
        in
        let ids_to_terms ids = List.map id_to_term ids in
        let loop_call pos = 
          let pp_call = 
            { pp_pos = pos; 
              pp_modifies = pp.pp_modifies; 
              pp_accesses = pp.pp_accesses;
            }
          in
          let call = mk_call_cmd returns proc_name (ids_to_terms returns) pos in
          update_ppoint pp_call call
        in
        let loop_end_pos = end_pos pp.pp_pos in
        let loop_start_pos = start_pos pp.pp_pos in
        let body, prog =
          let prog, prebody = elim prog proc lc.loop_prebody in
          let prog, postbody = elim prog proc lc.loop_postbody in
          let init_returns = 
            mk_assign_cmd returns (ids_to_terms formals) loop_start_pos 
          in
          let else_cmd = 
            mk_return_cmd (ids_to_terms returns) loop_end_pos
          in
          let then_cmd = 
            mk_seq_cmd
              [ postbody;
                loop_call loop_end_pos
              ] 
              pp.pp_pos
          in
          mk_seq_cmd 
            [ init_returns;
              prebody;
              mk_ite 
                lc.loop_test dummy_position 
                then_cmd else_cmd pp.pp_pos
            ]
            pp.pp_pos,
          prog
        in
        (* loop exit condition *)
        let loop_exit =
          let name = "loop exit condition of " ^ (str_of_ident proc_name) in
          mk_free_spec_form (FOL (mk_not lc.loop_test)) name None loop_end_pos
        in
        (* frame conditions for non-modified locals *)          
        let framecond =
          List.fold_left2 
            (fun frames id init_id ->
              if IdSet.mem id pp.pp_modifies 
              then frames
              else 
                let f = mk_eq (id_to_term id) (id_to_term init_id) in
                mk_free_spec_form (FOL f) 
                  ("framecondition of " ^ str_of_ident proc_name) 
                  None pp.pp_pos :: frames
            )
            [] returns formals
        in
        let postcond =
          loop_exit :: 
          (* invariant *)
          List.map (fun sf -> { sf with spec_kind = Free }) lc.loop_inv
          (* framecondition *)
          @ framecond
        in
        let loop_proc = 
          { proc_name = proc_name;
            proc_formals = formals;
            proc_returns = returns;
            proc_locals = locals;
            proc_precond = List.map (subst_id_spec subst_formals) lc.loop_inv;
            proc_postcond = postcond;
            proc_body = Some body;
            proc_pos = pp.pp_pos;
          } 
        in
        let call_loop =
          loop_call pp.pp_pos
        in
        declare_proc prog loop_proc, call_loop
    | Seq (cs, pp) ->
       let prog1, cs1 =
         List.fold_right 
           (fun c (prog, cs1) ->
             let prog1, c1 = elim prog proc c in
             prog1, c1 :: cs1)
           cs (prog, [])
       in 
       prog1, mk_seq_cmd cs1 pp.pp_pos
    | Choice (cs, pp) ->
       let prog1, cs1 =
         List.fold_right 
           (fun c (prog, cs1) ->
             let prog1, c1 = elim prog proc c in
             prog1, c1 :: cs1)
           cs (prog, [])
       in 
       prog1, mk_choice_cmd cs1 pp.pp_pos
    | Basic _ as c -> prog, c
  in
  let elim_proc prog proc =
    let prog1, body1 =
      match proc.proc_body with
      | Some body -> 
          let prog1, body1 = elim prog proc body in
          prog1, Some body1
      | None -> prog, None
    in 
    let proc1 = { proc with proc_body = body1 } in
    declare_proc prog1 proc1
  in
  fold_procs elim_proc prog prog

(** Eliminate global dependencies of predicates *)
let elim_global_deps prog =
  let elim_spec sf = 
    let subst_preds_sl f =
      let sf p args =
        let decl = find_pred prog p in
        let accs = decl.pred_accesses in
        let tas = 
          List.map (fun id ->
            let decl = find_global prog id in
            mk_free_const ~srt:decl.var_sort id)
            (IdSet.elements accs)
        in SlUtil.mk_pred p (tas @ args)
      in SL (SlUtil.subst_preds sf f)
    in
    let subst_preds_fol f = FOL f (* todo *) in
    let f1 = fold_spec_form subst_preds_fol subst_preds_sl sf in
    { sf with spec_form = f1 }
  in
  let elim_stmt = function
    | (Assert sf, pp) ->
        mk_assert_cmd (elim_spec sf) pp.pp_pos
    | (Assume sf, pp) ->
        mk_assume_cmd (elim_spec sf) pp.pp_pos
    | (bc, pp) -> Basic (bc, pp)
  in
  let elim_proc proc =
    let precond1 = List.map elim_spec proc.proc_precond in
    let postcond1 = List.map elim_spec proc.proc_postcond in
    let body1 = Util.optmap (map_basic_cmds elim_stmt) proc.proc_body in
    { proc with 
      proc_body = body1;
      proc_precond = precond1;
      proc_postcond = postcond1;
    } 
  in
  let elim_pred pred =
    let body1 = elim_spec pred.pred_body in
    let formals1 = IdSet.elements pred.pred_accesses @ pred.pred_formals in
    let locals1 = 
      IdSet.fold 
        (fun id locals -> IdMap.add id (find_global prog id) locals) 
        pred.pred_accesses pred.pred_locals
    in
    { pred with 
      pred_body = body1; 
      pred_formals = formals1; 
      pred_locals = locals1; 
      pred_accesses = IdSet.empty;
    } 
  in
  let prog1 = map_procs elim_proc prog in
  map_preds elim_pred prog1


(** Auxiliary variables for desugaring SL specifications *)
let alloc_id = mk_ident "Alloc"
let alloc_set = mk_free_const ~srt:(Set Loc) alloc_id

let init_alloc_id = mk_ident "Alloc_init"
let init_alloc_set = mk_free_const ~srt:(Set Loc) init_alloc_id

let alloc_callee_id = mk_ident "AllocCallee"
let alloc_callee_set = mk_free_const ~srt:(Set Loc) alloc_callee_id

let init_alloc_callee_id = mk_ident "AllocCallee_init"
let init_alloc_callee_set = mk_free_const ~srt:(Set Loc) init_alloc_callee_id

let frame_id = mk_ident "AllocCaller"
let frame_set = mk_free_const ~srt:(Set Loc) frame_id

let pred_struct (name, num) = (name ^ "_struct", num)
let pred_domain (name, num) = (name ^ "_dom", num)

(** Desugare SL specification to FOL specifications. 
 ** Assumes that loops have been transformed to tail-recursive procedures. *)
let elim_sl prog =
  let mk_set_decl id pos =
    { var_name = id;
      var_orig_name = name id;
      var_sort = Set Loc;
      var_is_ghost = true;
      var_is_aux = true;
      var_pos = pos;
    }
  in
  let compile_pred =
    let dom_id = mk_ident "Domain" in
    let dom_set = mk_free_const ~srt:(Set Loc) dom_id in
    fun acc pred ->
      match pred.pred_body.spec_form with
      | SL f ->
          let dom_decl = mk_set_decl dom_id pred.pred_pos in
          let args = 
            List.map (fun id ->
              let decl = IdMap.find id pred.pred_locals in
              mk_free_const ~srt:decl.var_sort id) 
              pred.pred_formals
          in
          let formals = dom_id :: pred.pred_formals in
          let locals = IdMap.add dom_id dom_decl pred.pred_locals in
          let str_body, dom_body = 
            Symbols.pred_to_form pred.pred_name args dom_set in
          let pred_str =
            { pred_name = pred_struct pred.pred_name;
              pred_formals = formals;
              pred_locals = locals;
              pred_body = { pred.pred_body with spec_form = FOL str_body };
              pred_pos = pred.pred_pos;
              pred_accesses = IdSet.empty;
            }
          in
          let pred_dom = 
            { pred_str with 
              pred_name = pred_domain pred.pred_name;
              pred_body = { pred.pred_body with spec_form = FOL dom_body } 
            }
          in
          IdMap.add pred_dom.pred_name pred_dom
            (IdMap.add pred_str.pred_name pred_str acc)
      | FOL _ -> acc
  in
  let pred_to_form p args dom =
    FormUtil.mk_pred (pred_struct p) (dom :: args),
    FormUtil.mk_pred (pred_domain p) (dom :: args)
  in
  let compile_proc proc =
    (* add auxiliary set variables *)
    let locals =
      List.fold_left 
        (fun locals id -> IdMap.add id (mk_set_decl id proc.proc_pos) locals)
        proc.proc_locals 
        [alloc_id; init_alloc_id; frame_id; alloc_callee_id; init_alloc_callee_id]
    in
    let returns = init_alloc_id :: alloc_id :: proc.proc_returns in
    let formals = frame_id :: proc.proc_formals in
    let convert_sl_form sfs name =
      let fs, aux, kind = 
        List.fold_right (fun sf (fs, aux, kind) -> 
          let new_kind = 
            match kind with
            | Free -> sf.spec_kind
            | k -> k
          in
          match sf.spec_form, aux with
          | SL f, None -> 
              f :: fs, 
              Some (sf.spec_name, sf.spec_msg, sf.spec_pos),
              new_kind
          | SL f, Some (_, _, p) -> 
              f :: fs, 
              Some (sf.spec_name, sf.spec_msg, merge_src_positions p sf.spec_pos),
              new_kind
          | _ -> fs, aux, kind)
          sfs ([], None, Free)
      in
      let name, msg, pos = Util.safe_unopt (name, None, dummy_position) aux in
      SlUtil.mk_sep_lst fs, kind, name, msg, pos
    in
    (* compile SL precondition *)
    let sl_precond, other_precond = List.partition is_sl_spec proc.proc_precond in
    let precond, footprint =
      let name = "precondition of " ^ str_of_ident proc.proc_name in
      let f, _, name, msg, pos = convert_sl_form sl_precond name in
      let f_in_frame = ToGrass.to_grass_contained pred_to_form frame_id f in
      let f_notin_frame = ToGrass.to_grass_not_contained pred_to_form frame_id f in
      let f_eq_init_alloc = ToGrass.to_grass pred_to_form init_alloc_id f in
      let precond = mk_checked_spec_form (FOL f_in_frame) name msg pos in
      let fp_name = "initial footprint of " ^ str_of_ident proc.proc_name in
      let footprint_form = 
        FOL (mk_and [mk_not (mk_elem mk_null init_alloc_set); f_eq_init_alloc])
      in
      { precond with spec_form_negated = Some f_notin_frame }, 
      mk_free_spec_form footprint_form fp_name None pos
    in
    (* compile SL postcondition *)
    let sl_postcond, other_postcond = List.partition is_sl_spec proc.proc_postcond in
    let postcond =
      let name = "postcondition of " ^ str_of_ident proc.proc_name in
      let f, kind, name, msg, pos = convert_sl_form sl_postcond name in
      let f_eq_alloc = ToGrass.to_grass pred_to_form alloc_id f in
      let f_neq_alloc = ToGrass.to_grass_negated pred_to_form alloc_id f in
      let postcond = mk_spec_form (FOL f_eq_alloc) name msg pos in
      { postcond with 
        spec_kind = kind;
        spec_form_negated = Some f_neq_alloc;
      }
    in
    (* generate frame condition *) 
    let framecond = 
      let frame_wo_alloc = mk_diff frame_set init_alloc_set in
      let name = "framecondition of " ^ (str_of_ident proc.proc_name) in
      let mk_framecond f = mk_free_spec_form (FOL f) name None postcond.spec_pos in
      (* null in not allocated *)
      mk_framecond (mk_not (smk_elem mk_null alloc_set)) ::
      (* initial footprint is contained in frame *)
      mk_framecond (mk_subseteq init_alloc_set frame_set) ::
      (* final footprint is disjoint from frame w/o alloc *)
      mk_framecond (mk_eq (mk_inter [alloc_set; frame_wo_alloc]) (mk_empty (Some (Set Loc)))) ::
      (* frame axioms for modified fields *)
      IdSet.fold (fun var frames ->
        let decl = find_global prog var in
        let old_var = oldify var in
        match decl.var_sort with
        | Fld _ as srt -> 
            let frame_axiom = 
              mk_frame 
                init_alloc_set 
                frame_set
                (mk_free_const ~srt:srt old_var)
                (mk_free_const ~srt:srt var)
            in 
            mk_framecond frame_axiom :: frames
        | _ -> frames)
        (modifies_proc prog proc) []
    in
    (* update all procedure calls and return commands in body *)
    let rec compile_stmt = function
      | (Call cc, pp) ->
          let assign_alloc =
            let new_alloc_set =
              mk_union [alloc_callee_set; (mk_diff alloc_set init_alloc_callee_set)]
            in
            mk_assign_cmd [alloc_id] [new_alloc_set] pp.pp_pos
          in
          let cc1 = 
            { cc with 
              call_lhs = init_alloc_callee_id :: alloc_callee_id :: cc.call_lhs;
              call_args = alloc_set :: cc.call_args;
            } 
          in
          mk_seq_cmd [Basic (Call cc1, pp); assign_alloc] pp.pp_pos
      | (Return rc, pp) ->
          let rc1 = { return_args = init_alloc_set :: alloc_set :: rc.return_args } in
          Basic (Return rc1, pp)
      | (Assume sf, pp) ->
          (match sf.spec_form with
          | SL f ->
              let f1 = ToGrass.to_grass pred_to_form alloc_id f in
              let sf1 = mk_spec_form (FOL f1) sf.spec_name sf.spec_msg sf.spec_pos in
              mk_assume_cmd sf1 pp.pp_pos
          | FOL f -> Basic (Assume sf, pp))
      | (Assert sf, pp) ->
          (match sf.spec_form with
          | SL f ->
              let f1 = ToGrass.to_grass pred_to_form alloc_id f in
              let f1_negated = ToGrass.to_grass_negated pred_to_form alloc_id f in
              let sf1 = mk_spec_form (FOL f1) sf.spec_name sf.spec_msg sf.spec_pos in
              mk_assert_cmd { sf1 with spec_form_negated = Some f1_negated } pp.pp_pos
          | FOL f -> Basic (Assert sf, pp))
      | (c, pp) -> Basic (c, pp)
    in
    let body = 
      Util.optmap 
        (fun body ->
          let body1 = map_basic_cmds compile_stmt body in
          let assume_footprint = mk_assume_cmd footprint footprint.spec_pos in
          let assign_alloc = mk_assign_cmd [alloc_id] [init_alloc_set] footprint.spec_pos in
          mk_seq_cmd [assume_footprint; assign_alloc; body1] (prog_point body).pp_pos
        ) proc.proc_body 
    in
    let old_footprint = 
      oldify_spec (modifies_proc prog proc) footprint
    in
    { proc with
      proc_formals = formals;
      proc_returns = returns;
      proc_locals = locals;
      proc_precond = precond :: other_precond;
      proc_postcond = old_footprint :: postcond :: framecond @ other_postcond;
      proc_body = body;
    } 
  in
  let preds = fold_preds compile_pred IdMap.empty prog in
  let prog = { prog with prog_preds = preds } in
  { prog with prog_procs = IdMap.map compile_proc prog.prog_procs }

(** Annotate safety checks for heap accesses *)
let annotate_heap_checks prog =
  let rec derefs acc = function
    | App (Read, [fld; loc], _) ->
        derefs (derefs (TermSet.add loc acc) fld) loc
    | App (Write, fld :: loc :: ts, _) ->
        List.fold_left derefs (TermSet.add loc acc) (fld :: loc :: ts)
    | App (_, ts, _) -> 
        List.fold_left derefs acc ts
    | _ -> acc
  in
  let mk_term_checks pos acc t =
    let locs = derefs TermSet.empty t in
    TermSet.fold 
      (fun t acc ->
        let t_in_alloc = FOL (mk_elem t alloc_set) in
        let mk_msg callee pos = "Possible heap access through null or dangling reference." in
        let sf = mk_spec_form t_in_alloc "check heap access" (Some mk_msg) pos in
        let check_access = mk_assert_cmd sf pos in
        check_access :: acc)
      locs acc
  in
  let ann_term_checks ts cmd =
    let checks = List.fold_left (mk_term_checks (source_pos cmd)) [] ts in
    mk_seq_cmd (checks @ [cmd]) (source_pos cmd)
  in
  let annotate = function
    | (Assign ac, pp) ->
        ann_term_checks ac.assign_rhs (Basic (Assign ac, pp))
    | (Dispose dc, pp) ->
        let arg = dc.dispose_arg in
        let arg_in_alloc = FOL (mk_elem arg alloc_set) in
        let mk_msg callee pos = "This deallocation might be unsafe." in
        let sf = mk_spec_form arg_in_alloc "check free" (Some mk_msg) pp.pp_pos in
        let check_dispose = mk_assert_cmd sf pp.pp_pos in
        let arg_checks = mk_term_checks pp.pp_pos [check_dispose] arg in
        mk_seq_cmd (arg_checks @ [Basic (Dispose dc, pp)]) pp.pp_pos
    | (Call cc, pp) ->
        ann_term_checks cc.call_args (Basic (Call cc, pp))
    | (Return rc, pp) ->
        ann_term_checks rc.return_args (Basic (Return rc, pp))
    | (bc, pp) -> Basic (bc, pp)
  in
  let annotate_proc proc = 
    { proc with proc_body = Util.optmap (map_basic_cmds annotate) proc.proc_body } 
  in
  { prog with prog_procs = IdMap.map annotate_proc prog.prog_procs }

(** Eliminate all new and dispose commands.
 ** Assumes that alloc sets have been introduced. *)
let elim_new_dispose prog =
  let elim = function
    | (New nc, pp) ->
        let havoc = mk_havoc_cmd [nc.new_lhs] pp.pp_pos in
        let arg = mk_free_const ~srt:nc.new_sort nc.new_lhs in
        let aux =
          match nc.new_sort with
          | Loc ->          
              let new_loc = mk_and [mk_not (mk_elem arg alloc_set); mk_neq arg mk_null] in
              let sf = mk_spec_form (FOL new_loc) "new" None pp.pp_pos in
              let assume_fresh = mk_assume_cmd sf pp.pp_pos in
              let assign_alloc = mk_assign_cmd [alloc_id] [mk_union [alloc_set; mk_setenum [arg]]] pp.pp_pos in
              [assume_fresh; assign_alloc]
          | _ -> []
        in
        mk_seq_cmd (havoc :: aux) pp.pp_pos
    | (Dispose dc, pp) ->
        let arg = dc.dispose_arg in
        let assign_alloc = 
          mk_assign_cmd [alloc_id] [mk_diff alloc_set (mk_setenum [arg])] pp.pp_pos 
        in
        assign_alloc
    | (c, pp) -> Basic (c, pp)
  in
  let elim_proc proc = { proc with proc_body = Util.optmap (map_basic_cmds elim) proc.proc_body } in
  { prog with prog_procs = IdMap.map elim_proc prog.prog_procs }


(** Eliminate all return commands.
 ** Assumes that all SL formulas have been desugared. *)
let elim_return prog =
  let elim returns mk_postcond_check = function
    | (Return rc, pp) ->
        let rt_assign = 
          mk_assign_cmd returns rc.return_args pp.pp_pos 
        in
        let fls = 
          mk_spec_form (FOL mk_false) "return" None pp.pp_pos 
        in
        let rt_false = mk_assume_cmd fls pp.pp_pos in
        let rt_postcond = mk_postcond_check pp.pp_pos in
        mk_seq_cmd (rt_assign :: rt_postcond @ [rt_false]) pp.pp_pos
    | (c, pp) -> Basic (c, pp)
  in
  let elim_proc proc =
    let mk_postcond_check = 
      let posts = 
        Util.filter_map 
          is_checked_spec
          (fun sf ->
            match sf.spec_form with
            | FOL _ -> oldify_spec (id_set_of_list proc.proc_formals) sf
            | SL _ -> failwith "elim_return: Found SL formula that should have been desugared.")
          proc.proc_postcond
      in fun pos -> List.map (fun sf -> mk_assert_cmd sf pos) posts
    in
    let body = 
      (* add final check of postcondition at the end of procedure body *)
      let body1 = 
        Util.optmap 
          (fun body -> 
            let pos = (prog_point body).pp_pos in
            let return_pos = 
              { sp_file = pos.sp_file;
                sp_start_line = pos.sp_end_line;
                sp_start_col = pos.sp_end_col;
                sp_end_line = pos.sp_end_line;
                sp_end_col = pos.sp_end_col;
              } 
            in
            mk_seq_cmd (body :: mk_postcond_check return_pos) (prog_point body).pp_pos) 
          proc.proc_body
      in
      Util.optmap (map_basic_cmds (elim proc.proc_returns mk_postcond_check)) body1
         
    in
    { proc with proc_body = body }
  in
  { prog with prog_procs = IdMap.map elim_proc prog.prog_procs }


(** Eliminate all state (via SSA computation) 
 ** Assumes that:
 ** - all loops have been eliminated 
 ** - all SL formulas have been desugared
 ** - the only remaining basic commands are assume/assert/assign/havoc/call. *)
let elim_state prog =
  let elim_proc proc =
    let fresh_decl id pos =
      let decl = find_var prog proc id in
      let id1 = fresh_ident (name id) in
      let decl1 = 
        { decl with 
          var_name = id1;
          var_is_aux = true;
          var_pos = pos;
        }
      in decl1
    in
    let fresh sm locals pos ids =
      List.fold_left (fun (sm, locals) id ->
        let decl = fresh_decl id pos in
        IdMap.add id decl.var_name sm, 
        IdMap.add decl.var_name decl locals)
        (sm, locals) ids
    in
    let rec elim sm locals = function
      | Loop _ as c -> 
          (* ignore loops - they should have been desugared by now *)
          sm, locals, c
      | Seq (cs, pp) ->
          let sm, locals, cs1 = 
            List.fold_left 
              (fun (sm, locals, cs1) c  ->
                let sm, locals, c1 = elim sm locals c in
                sm, locals, c1 :: cs1)
              (sm, locals, []) cs
          in
          sm, locals, Seq (List.rev cs1, pp)
      | Choice (cs, pp) ->
          (* bring commands cs into SSA form *)
          let sms, locals, cs1 =
            List.fold_right  
              (fun c (sms, locals, cs1) ->
                let sm1, locals, c1 = elim sm locals c in
                sm1 :: sms, locals, c1 :: cs1)
              cs ([], locals, [])
          in
          (* compute joined substitution map *)
          let sm_join = 
            List.fold_left 
              (fun sm1 sm -> 
                IdMap.merge 
                  (fun x -> function 
                    | None -> (function 
                        | None -> None
                        | Some z -> Some z)
                    | Some y -> (function
                        | None -> Some y
                        | Some z -> Some y)
                  )
                  sm1 sm
              )
              IdMap.empty sms
          in
          (* add missing equalities to commands cs according to joined substitution map *)
          let cs2 =
            List.fold_right2 (fun sm_c c cs2 ->
              let eqs = 
                IdSet.fold 
                  (fun x eqs ->
                    let x_join = IdMap.find x sm_join in
                    let x_c = 
                      try IdMap.find x sm_c with Not_found -> x
                    in
                    if x_join  = x_c then eqs
                    else 
                      let x_decl = find_var prog proc x in
                      let x_srt = x_decl.var_sort in
                      let xc = mk_free_const ~srt:x_srt x_c in
                      let xj = mk_free_const ~srt:x_srt x_join in
                      mk_eq xj xc :: eqs
                  )
                  pp.pp_modifies []
              in 
              let sf = mk_spec_form (FOL (mk_and eqs)) "join" None pp.pp_pos in
              Seq ([c; mk_assume_cmd sf pp.pp_pos], pp) :: cs2)
              sms cs1 []
          in
          sm_join, locals, mk_choice_cmd cs2 pp.pp_pos
      | Basic (bc, pp) ->
          match bc with
          | Assume sf -> 
              sm, locals, Basic (Assume (subst_id_spec sm sf), pp)
          | Assert sf ->
              let sf1 = unoldify_spec (subst_id_spec sm sf) in
              sm, locals, Basic (Assert sf1, pp)
          | Havoc hc ->
              let sm1, locals = fresh sm locals pp.pp_pos hc.havoc_args in
              sm1, locals, Seq ([], pp)
          | Assign ac ->
              let sm1, locals = fresh sm locals pp.pp_pos ac.assign_lhs in
              let eqs =
                List.map2 
                  (fun x e ->
                    let x_decl = find_var prog proc x in
                    let x1 = mk_free_const ~srt:x_decl.var_sort (IdMap.find x sm1) in
                    let e1 = subst_id_term sm e in
                    mk_eq x1 e1)
                  ac.assign_lhs ac.assign_rhs
              in
              let sf = mk_spec_form  (FOL (mk_and eqs)) "assign" None pp.pp_pos in
              sm1, locals, mk_assume_cmd sf pp.pp_pos
          | Call cc ->
              let to_term_subst sm locals =
                IdMap.fold (fun id1 id2 sm -> 
                  let decl = IdMap.find id2 locals in
                  IdMap.add id1 (mk_free_const ~srt:decl.var_sort id2) sm)
                  sm IdMap.empty
              in
              let callee_decl = find_proc prog cc.call_name in
              (* update actual arguments of call *)
              let args1 = List.map (subst_id_term sm) cc.call_args in
              (* compute substitution for precondition *)
              let subst_pre = 
                List.fold_left2 
                  (fun sm id arg -> IdMap.add id arg sm) 
                  (to_term_subst sm locals) 
                  callee_decl.proc_formals args1
              in
              (* assert updated precondition *)
              let assert_precond =
                Util.filter_map is_checked_spec 
                  (fun sf -> mk_assert_cmd (subst_spec subst_pre sf) pp.pp_pos)
                  callee_decl.proc_precond
              in
              (* compute mod set and final substitution *)
              let mods = cc.call_lhs @ IdSet.elements (modifies_proc prog callee_decl) in
              let sm1, locals = fresh sm locals pp.pp_pos mods in
              (* compute substitution for postcondition *)
              let subst_post = 
                let subst_wo_old_mods_formals =
                  List.fold_left 
                    (fun sm id ->
                      IdMap.add (oldify id) (IdMap.find id subst_pre) sm)
                    subst_pre callee_decl.proc_formals
                in
                let subst_wo_old_mods = 
                  List.fold_left2
                    (fun sm id rtn_id -> 
                      let decl = IdMap.find rtn_id locals in
                      IdMap.add id (mk_free_const ~srt:decl.var_sort rtn_id) sm)
                    subst_wo_old_mods_formals
                    callee_decl.proc_returns 
                    (List.map (fun id -> IdMap.find id sm1) cc.call_lhs)
                in
                let subst_wo_old =
                  List.fold_left (fun sm id -> 
                    IdMap.add id (IdMap.find id (to_term_subst sm1 locals)) sm)
                    subst_wo_old_mods
                    mods
                in
                List.fold_left 
                  (fun subst_post id ->
                    let decl = IdMap.find (IdMap.find id sm1) locals in
                    let old_id = try IdMap.find id sm with Not_found -> id in
                    IdMap.add (oldify id) (mk_free_const ~srt:decl.var_sort old_id) subst_post)
                  subst_wo_old mods
              in
              (* assume updated postcondition *)
              let assume_postcond =
                Util.filter_map is_free_spec 
                  (fun sf -> 
                    let old_sf = oldify_spec (id_set_of_list callee_decl.proc_formals) sf in
                    let sf1 = subst_spec subst_post old_sf in
                    mk_assume_cmd sf1 pp.pp_pos)
                  callee_decl.proc_postcond
              in
              sm1, locals, mk_seq_cmd (assert_precond @ assume_postcond) pp.pp_pos
          | _ -> sm, locals, Basic (bc, pp)
    in
    let locals, body =
      match proc.proc_body with
      | None -> proc.proc_locals, None
      | Some body -> 
          let _, locals, body1 = elim IdMap.empty proc.proc_locals body in
          locals, Some body1
    in
    { proc with proc_locals = locals; proc_body = body }
  in
  { prog with prog_procs = IdMap.map elim_proc prog.prog_procs }

(** Generate predicate instances *)
let add_pred_insts prog f =
  let pred_apps = 
    let collect acc = function
      | App (FreeSym p, ts, _) as t -> 
          if IdMap.mem p prog.prog_preds 
          then TermSet.add t acc
          else acc
      | _ -> acc
    in FormUtil.fold_terms collect TermSet.empty f 
  in
  f

(** Simplify the given program by applying all transformation steps. *)
let simplify prog =
  let dump_if n prog = 
    if !Config.dump_ghp == n 
    then print_prog stdout prog 
    else ()
  in
  dump_if 0 prog;
  let prog = infer_accesses prog in
  let prog = elim_loops prog in
  let prog = elim_global_deps prog in
  dump_if 1 prog;
  let prog = elim_sl prog in
  let prog = annotate_heap_checks prog in
  let prog = elim_new_dispose prog in
  dump_if 2 prog;
  let prog = elim_return prog in
  let prog = elim_state prog in
  dump_if 3 prog;
  prog

(** Generate verification conditions for given procedure. 
 ** Assumes that proc has been transformed into SSA form. *)
let vcgen prog proc =
  let rec vcs acc pre = function
    | Loop _ -> 
        failwith "vcgen: loop should have been desugared"
    | Choice (cs, pp) ->
        let acc1, traces = 
          List.fold_left (fun (acc, traces) c ->
            let acc1, trace = vcs acc pre c in
            acc1, trace :: traces)
            (acc, []) cs
        in acc1, [mk_or (List.rev_map mk_and traces)]
    | Seq (cs, pp) -> 
        let acc1, trace, _ = 
          List.fold_left (fun (acc, trace, pre) c ->
            let acc1, c_trace = vcs acc pre c in
            acc1, trace @ c_trace, pre @ c_trace)
            (acc, [], pre) cs 
        in
        acc1, trace
    | Basic (bc, pp) ->
        match bc with
        | Assume s ->
            let name = 
              Printf.sprintf "%s_%d_%d" 
                s.spec_name pp.pp_pos.sp_start_line pp.pp_pos.sp_start_col
            in
            (match s.spec_form with
              | FOL f -> acc, [mk_comment name f]
              | _ -> failwith "vcgen: found SL formula that should have been desugared")
        | Assert s ->
            let name = 
              Printf.sprintf "%s_%d_%d" 
                s.spec_name pp.pp_pos.sp_start_line pp.pp_pos.sp_start_col
            in
            let f =
              match s.spec_form_negated, s.spec_form with
              | Some f, _ -> unoldify_form f
              | None, FOL f -> unoldify_form (mk_not f)
              | _ -> failwith "vcgen: found SL formula that should have been desugared"
            in
            let vc_name = 
              Str.global_replace (Str.regexp " ") "_"
                (str_of_ident proc.proc_name ^ "_" ^ name)
            in
            let vc_msg = 
              match s.spec_msg with
              | None -> ("Possible assertion violation.", pp.pp_pos)
              | Some msg -> (msg proc.proc_name s.spec_pos, pp.pp_pos)
            in
            let vc = pre @ [mk_comment name f] in
            (vc_name, vc_msg, smk_and vc) :: acc, []
        | _ -> 
            failwith "vcgen: found unexpected basic command that should have been desugared"
  in
  match proc.proc_body with
  | Some body -> List.rev (fst (vcs [] [] body))
  | None -> []

(** Generate verification conditions for given procedure and check them. *)
let check_proc prog proc =
  let check_vc (vc_name, (vc_msg, pp), vc) =
    match Prover.check_sat ~session_name:vc_name vc with
    | Some false -> ()
    | _ -> ProgError.error pp vc_msg
  in
  let vcs = vcgen prog proc in
  List.iter check_vc vcs