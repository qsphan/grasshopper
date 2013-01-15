open Util

type ident = string * int

type term =
  | Const of ident
  | Var of ident
  | FunApp of ident * term list

type form =
  | BoolConst of bool
  | Pred of ident * term list
  | Eq of term * term
  | Not of form
  | And of form list
  | Or of form list
  | Comment of string * form  

let fresh_ident =
  let used_names = Hashtbl.create 0 in
  fun (name : string) ->
    let last_index = 
      try Hashtbl.find used_names name 
      with Not_found -> -1
    in 
    Hashtbl.replace used_names name (last_index + 1);
    (name, last_index + 1)

let sort_str = "usort"

let str_of_ident (id, n) =
  if n = 0 then id else
  Printf.sprintf "%s_%d" id n

let is_pred_id id = String.capitalize (fst id) = fst id

let eq_base (id1, n1) (id2, n2) = id1 = id2

let mk_ident id = (id, 0)

let mk_const id = Const id
let mk_var id = Var id
let mk_app id ts = FunApp (id, ts) 

let mk_true = BoolConst true
let mk_false = BoolConst false
let mk_and = function
  | [] -> mk_true
  | [f] -> f
  | fs -> And fs
let mk_or fs = Or fs
let mk_not = function
  | BoolConst b -> BoolConst (not b)
  | f -> Not f
let mk_eq s t = Eq (s, t)
let mk_pred id ts = Pred (id, ts)

let mk_comment c = function
  | Comment (c', f) -> Comment (c ^ "_" ^ c', f)
  | f -> Comment (c, f)

let str_true = "True"
let str_false = "False"

let id_true = mk_ident str_true
let id_false = mk_ident str_false

module IdSet = Set.Make(struct
    type t = ident
    let compare = compare
  end)

module IdMap = Map.Make(struct
    type t = ident
    let compare = compare
  end)

module TermSet = Set.Make(struct
    type t = term
    let compare = compare
  end)

module TermMap = Map.Make(struct
    type t = term
    let compare = compare
  end)

module FormSet = Set.Make(struct
    type t = form
    let compare = compare
  end)

type subst_map = term IdMap.t

let id_set_to_list ids = 
  IdSet.fold (fun v acc -> v :: acc) ids []

let form_set_to_list fs =
  FormSet.fold (fun f acc -> f :: acc) fs []

let form_set_of_list fs =
  List.fold_left (fun acc f -> FormSet.add f acc) FormSet.empty fs

let smk_and fs = 
  let rec mkand1 fs acc = 
    match fs with
    | [] ->
        begin
          match form_set_to_list acc with
	  | [] -> BoolConst true
	  | [f] -> f
	  | fs -> mk_and fs
        end
    | And fs0 :: fs1 -> mkand1 (fs0 @ fs1) acc
    | BoolConst true :: fs1 -> mkand1 fs1 acc
    | BoolConst false :: fs1 -> BoolConst false
    | f::fs1 -> mkand1 fs1 (FormSet.add f acc)
  in mkand1 fs FormSet.empty

let smk_or fs = 
  let rec mkor1 fs acc = 
    match fs with
    | [] ->
        begin
          match form_set_to_list acc with
	  | [] -> BoolConst false
	  | [f] -> f
	  | fs -> mk_or fs
        end
    | Or fs0 :: fs1 -> mkor1 (fs0 @ fs1) acc
    | BoolConst false :: fs1 -> mkor1 fs1 acc
    | BoolConst true :: fs1 -> BoolConst true
    | f::fs1 -> mkor1 fs1 (FormSet.add f acc)
  in mkor1 fs FormSet.empty

(** compute negation normal form of a formula *)
let rec nnf = function
  | Not (BoolConst b) -> BoolConst (not b)
  | Not (Not f) -> nnf f
  | Not (And fs) -> smk_or (List.map (fun f -> nnf (mk_not f)) fs)
  | Not (Or fs) -> smk_and (List.map (fun f -> nnf (mk_not f)) fs)
  | And fs -> smk_and (List.map nnf fs)
  | Or fs -> smk_or (List.map nnf fs)
  | Not (Comment (c, f)) -> Comment (c, nnf (mk_not f))
  | Comment (c, f) -> Comment (c, nnf f)
  | f -> f
  

(** compute conjunctive normal form of a formula *)
(* Todo: avoid exponential blowup *)
let rec cnf = 
  let rec cnf_and acc = function
    | [] ->
	begin
	  match acc with
	  | [] -> BoolConst true
	  | [f] -> f
	  | fs -> mk_and fs
	end
    | And fs :: fs1 -> cnf_and acc (fs @ fs1)
    | Comment (c, And fs) :: fs1 -> 
	cnf_and acc (List.map (fun f -> Comment (c, f)) fs @ fs1)
    | BoolConst false :: _ -> BoolConst false
    | BoolConst true :: fs -> cnf_and acc fs
    | f :: fs -> cnf_and (f :: acc) fs
  in
  let rec cnf_or acc = function
    | [] ->
	begin
	  match acc with
	  | [] -> BoolConst false
	  | [f] -> f
	  | fs -> mk_or fs
	end
    | Or fs :: fs1 -> cnf_or acc (fs @ fs1)
    | Comment (c, Or fs) :: fs1 -> cnf_or acc (List.map (fun f -> Comment (c, f)) fs @ fs1)
    | And fs :: fs1 -> 
	let fs_or = acc @ fs1 in
	let fs_and = List.map (fun f -> Or (f :: fs_or)) fs in
	cnf (And fs_and)
    | BoolConst true :: _ -> BoolConst true
    | BoolConst false :: fs -> cnf_or acc fs
    | f :: fs -> cnf_or (f :: acc) fs  
  in
  function
    | And fs
    | Comment (_, And fs) ->  cnf_and [] (List.rev_map cnf fs)
    | Or fs 
    | Comment (_, Or fs) -> cnf_or [] (List.rev_map cnf fs)
    | f -> f

let mk_neq s t = mk_not (mk_eq s t)

let mk_implies a b =
  smk_or [nnf (mk_not a); b]

let mk_equiv a b =
  smk_or [smk_and [a; b]; smk_and [nnf (mk_not a); nnf (mk_not b)]]

let collect_from_terms col init f =
  let rec ct acc = function
    | And fs 
    | Or fs ->
	List.fold_left ct acc fs
    | Not f -> ct acc f
    | Pred (_, ts) ->
	List.fold_left col acc ts
    | Eq (s, t) -> col (col acc s) t
    | Comment (c, f) -> ct acc f
    | _ -> acc
  in ct init f

let fv f = 
  let rec fvt vars = function
    | Var id -> IdSet.add id vars
    | FunApp (_, ts) ->
	List.fold_left fvt vars ts
    | _ -> vars
  in collect_from_terms fvt IdSet.empty f


let ground_terms f =
  let rec gt terms t = 
    match t with
    | Var _ -> terms, false
    | Const _ -> TermSet.add t terms, true
    | FunApp (_, ts) ->
	let terms1, is_ground = 
	  List.fold_left 
	    (fun (terms, is_ground) t ->
	      let terms_t, is_ground_t = gt terms t in
	      terms_t, is_ground && is_ground_t)
	    (terms, true) ts
	in
	if is_ground then TermSet.add t terms, true else terms, false
  in collect_from_terms (fun acc t -> fst (gt acc t)) TermSet.empty f
  
let fv_in_fun_terms f =
  let rec fvt vars = function
    | Var id -> IdSet.add id vars
    | FunApp (_, ts) ->
	List.fold_left fvt vars ts
    | _ -> vars
  in
  let rec ct vars t = 
    match t with
    | FunApp (_, _) -> fvt vars t
    | _ -> vars
  in collect_from_terms ct IdSet.empty f
     

type decl = {is_pred: bool; arity: int}

let sign f =
  let rec fts decls = function
    | Var _ -> decls
    | Const id -> IdMap.add id {is_pred = false; arity = 0} decls
    | FunApp (id, ts) ->
	let decl = {is_pred = false; arity = List.length ts} in
	List.fold_left fts (IdMap.add id decl decls) ts
  in 
  let rec ffs decls = function
    | And fs 
    | Or fs ->
	List.fold_left ffs decls fs
    | Not f -> ffs decls f
    | Pred (id, ts) ->
	let decl = {is_pred = true; arity = List.length ts} in
	List.fold_left fts (IdMap.add id decl decls) ts
    | Eq (s, t) -> fts (fts decls s) t
    | Comment (c, f) -> ffs decls f
    | _ -> decls
  in
  ffs IdMap.empty f


let funs_in_term t =
  let rec fts funs = function
    | Var _ -> funs
    | Const id -> IdSet.add id funs
    | FunApp (id, ts) ->
	List.fold_left fts (IdSet.add id funs) ts
  in fts IdSet.empty t

let funs f =
  let rec fts funs = function
    | Var _ -> funs
    | Const id -> IdSet.add id funs
    | FunApp (id, ts) ->
	List.fold_left fts (IdSet.add id funs) ts
  in collect_from_terms fts IdSet.empty f

let subst_id_term subst_map t =
  let sub_id id =
    try IdMap.find id subst_map with Not_found -> id
  in
  let rec sub = function
    | Const id -> Const  (sub_id id)
    | Var id -> Var (sub_id id)
    | FunApp (id, ts) -> FunApp (sub_id id, List.map sub ts)
  in sub t

let subst_id subst_map f =
  let sub_id id =
    try IdMap.find id subst_map with Not_found -> id
  in
  let subt = subst_id_term subst_map in
  let rec sub = function 
    | And fs -> And (List.map sub fs)
    | Or fs -> Or (List.map sub fs)
    | Not g -> Not (sub g)
    | Eq (s, t) -> Eq (subt s, subt t)
    | Pred (id, ts) -> Pred (sub_id id, List.map subt ts)
    | Comment (c, f) -> Comment (c, sub f)
    | f -> f
  in sub f

let subst_term subst_map t =
  let sub_id id t =
    try IdMap.find id subst_map with Not_found -> t
  in
  let rec sub = function
    | (Const id as t)
    | (Var id as t) -> sub_id id t 
    | FunApp (id, ts) -> FunApp (id, List.map sub ts)
  in sub t

let subst subst_map f =
  let subt = subst_term subst_map in
  let rec sub = function 
    | And fs -> And (List.map sub fs)
    | Or fs -> Or (List.map sub fs)
    | Not g -> Not (sub g)
    | Eq (s, t) -> Eq (subt s, subt t)
    | Pred (id, ts) -> Pred (id, List.map subt ts)
    | Comment (c, f) -> Comment (c, sub f)
    | f -> f
  in sub f

let reset_ident f = 
  let reset id = (fst id, 0) in 
  let rec terms t = match t with
    | Const id -> Const (reset id)
    | Var id -> Var (reset id)
    | FunApp (id, args) -> FunApp (reset id, List.map terms args)
  in
  let rec sub f = match f with
    | And fs -> And (List.map sub fs)
    | Or fs -> Or (List.map sub fs)
    | Not g -> Not (sub g)
    | Eq (s, t) -> Eq (terms s, terms t)
    | Pred (id, ts) -> Pred (reset id, List.map terms ts)
    | Comment (c, f) -> Comment (c, sub f)
    | f -> f
  in
    sub f

let string_of_term t = 
  let rec st = function
    | Const id 
    | Var id -> str_of_ident id
    | FunApp (id, ts) ->
	let str_ts = List.map st ts in
	str_of_ident id ^ "(" ^ 
	String.concat ", " str_ts ^
	")"
  in st t

let rec string_of_form f = match f with
    | And lst -> "(" ^ (String.concat ") && (" (List.map string_of_form lst)) ^ ")"
    | Or lst -> "(" ^ (String.concat ") || (" (List.map string_of_form lst)) ^ ")"
    | Eq (s, t) -> (string_of_term s) ^ " = " ^ (string_of_term t)
    | Not (Eq (s, t)) -> (string_of_term s) ^ " ~= " ^ (string_of_term t)
    | Not f -> "~ " ^ (string_of_form f)
    | Comment (c, f) -> string_of_form f
    | Pred (p, ts) -> (str_of_ident p) ^ "(" ^ (String.concat ", " (List.map string_of_term ts)) ^ ")"
    | BoolConst b -> if b then "true" else "false" 

let print_form out_ch =
  let print = output_string out_ch in
  let print_list indent delim p = function
    | [] -> ()
    | x :: xs ->
	p "" "" x;
	List.iter (p indent delim) xs 
  in
  let rec pt indent delim = function
    | Const id 
    | Var id -> 
	print (indent ^ delim ^ str_of_ident id)
    | FunApp (id, ts) ->
	print (indent ^ delim ^ str_of_ident id ^ "(");
	print_list "" ", " pt ts;
	print ")"
  in
  let rec pf indent delim = function
    | And fs ->
	print indent;
	print delim;
	print "( ";
	print_list (indent ^ "  ") "& " (fun indent delim f -> pf indent delim f; print "\n") fs;
	print (indent ^ "  )");
    | Or fs ->
	print indent;
	print delim;
	print "( ";
	print_list (indent ^ "  ") "| " (fun indent delim f -> pf indent delim f; print "\n") fs;
	print (indent ^ "  )");
    | Not (Eq (s, t)) ->
	print indent;
	print delim;
	print_list "" " ~= " pt [s;t]
    | Not f ->
	print (indent ^ delim ^ "~");  
	print_list (indent ^ " ") "" pf [f]
    | Comment (c, f) ->
	pf indent delim f
    | Pred (p, ts) ->
	print (indent ^ delim ^ str_of_ident p ^ "(");
	print_list "" ", " pt ts;
	print ")";
    | Eq (s, t) ->
	print indent;
	print delim;
	print_list "" " = " pt [s;t]
    | BoolConst b ->
	print indent;
	print delim;
	if b then print "True" else print "False" 
  in function
    | And fs 
    | Comment (_, And fs) ->
	print "  ";
	print_list "" "& " (fun indent delim f -> pf indent delim f; print "\n") fs;
    | Or fs 
    | Comment (_, Or fs) ->
	print "  ";
	print_list "" "| " (fun indent delim f -> pf indent delim f; print "\n") fs;
    | f -> pf "" "" f; print "\n"
  

let print_smtlib_term out_ch t =
  let print = output_string out_ch in
  let print_list fn xs = List.iter (fun x -> fn x; print " ") xs in
  let rec smt_term = function
    | Const id 
    | Var id -> print (str_of_ident id)
    | FunApp (id, ts) ->
	print "(";
	print (str_of_ident id);
	print " ";
	print_list smt_term ts;
	print ")"
  in
    smt_term t

let print_smtlib_form_generic before_f after_f out_ch f =
  let print = output_string out_ch in
  let print_list fn xs = List.iter (fun x -> fn x; print " ") xs in
  let rec smt_form = function
  | And fs -> 
      print "(and ";
      print_list smt_form fs;
      print ")"
  | Or fs -> 
      print "(or ";
      print_list smt_form fs;
      print ")"
  | Not f -> 
      print "(not ";
      smt_form f;
      print ")";
  | Comment (c, f) ->
      smt_form f
  | Pred (id, ts) -> 
      if (ts = []) then
        print (" " ^ (str_of_ident id))
      else
        begin
          print "(";
          print (str_of_ident id);
          print " ";
          print_list (print_smtlib_term out_ch) ts;
          print ")"
        end
  | Eq (s, t) -> 
      print "(= ";
      print_list (print_smtlib_term out_ch) [s; t];
      print ")"
  | BoolConst b -> if b then print " true" else print " false"
  in 
  before_f out_ch f;
  smt_form f;
  after_f out_ch f

let print_smtlib_form out_ch f =
  let before_quantify out_ch f =
    let print = output_string out_ch in
    let vars = fv f in
    if not (IdSet.is_empty vars) then print "(forall (";
    IdSet.iter (fun id -> print ("(" ^ str_of_ident id ^ " " ^ sort_str ^ ") ")) vars;
    if not (IdSet.is_empty vars) then print ")"
  in
  let after_quantify out_ch f =
    let print = output_string out_ch in
    let vars = fv f in
    if not (IdSet.is_empty vars) then print ")"
  in
    print_smtlib_form_generic before_quantify after_quantify out_ch f

let print_smtlib_form_with_triggers out_ch f =
  let vars = fv f in
  let triggers = 
    let with_vars =
      if !Config.use_triggers then
        begin
          let rec has_var t = match t with 
            | Var _ -> true
            | Const _ -> false
            | FunApp (_, ts) -> List.exists has_var ts
          in
          let rec get acc t =
            if has_var t then TermSet.add t acc
            else acc
          in
            collect_from_terms get TermSet.empty f
        end
      else
        IdSet.fold (fun id acc -> TermSet.add (mk_var id) acc) vars TermSet.empty
    in
      TermSet.filter (fun t -> match t with Var _ -> false | _ -> true) with_vars
  in
  let before_quantify out_ch f =
    let print = output_string out_ch in
    if not (IdSet.is_empty vars) then
       begin
         print "(forall (";
         IdSet.iter (fun id -> print ("(" ^ str_of_ident id ^ " " ^ sort_str ^ ") ")) vars;
         print ") (!";
       end
  in
  let after_quantify out_ch f =
    let print = output_string out_ch in
    let print_list fn xs = List.iter (fun x -> fn x; print " ") xs in
      if not (TermSet.is_empty triggers) then
        begin
          print ":pattern (";
          print_list (print_smtlib_term out_ch) (TermSet.elements triggers);
          print ")))"
        end
      else if not (IdSet.is_empty vars) then
        print "))"
  in
    print_smtlib_form_generic before_quantify after_quantify out_ch f
      

let print_forms ch = function
  | f :: fs -> 
      print_form ch f;
      List.iter (fun f -> output_string ch ";\n"; print_form ch f) fs;
  | [] -> ()

module Clauses = struct

  type clause = form list
  type clauses = clause list
       
  (** convert a formula into a set of clauses *)
  let from_form f : clauses = 
    let nf = cnf (nnf f) in
    let to_clause = function
      | Or fs -> fs
      |	Comment (c, Or fs) -> List.map (fun f -> Comment (c, f)) fs
      | BoolConst false
      |	Comment (_, BoolConst false) -> []
      | f -> [f]
    in
    match nf with
    | And fs -> List.map to_clause fs
    | Comment (c, And fs) -> List.map (fun f -> to_clause (Comment (c, f))) fs
    | BoolConst true 
    | Comment (_, BoolConst true) -> []
    | f -> [to_clause f]
	  
  (** convert a set of clauses into a formula *)
  let to_form cs = smk_and (List.map smk_or cs)

end


