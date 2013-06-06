%{
open Sl
open SlUtil
open SimpleLanguage

let parse_error = ParseError.parse_error

%}

%token <string> TIDENT
%token <string> PIDENT
%token <int> INT
%token LPAREN RPAREN LBRACKET RBRACKET
%token SEMICOLON DOT
%token PLUS MINUS DIV MULT
%token EQ NEQ LEQ GEQ LT GT
%token PTS BPTS TRUE FALSE EMP NULL
%token COLONEQ
%token ASSUME ASSERT NEW NEXT PREV DATA DISPOSE RETURN
%token SEP AND OR NOT COMMA
%token IF ELSE WHILE
%token PROCEDURE REQUIRES ENSURES INVARIANT
%token EOF

%left OR
%left AND
%left SEP
%left DOT
%right NOT
%left SEMICOLON

%nonassoc EQ 
%nonassoc NEQ 
%nonassoc PTS LS
%nonassoc TRUE FALSE
%nonassoc COLONEQ 
%nonassoc ASSUME ASSERT
%nonassoc NEW DISPOSE

%start main
%type <SimpleLanguage.procedure list> main
%%

main:
  procedure main { $1 :: $2 }
| /* empty */ { [] }
;

procedure:
  PROCEDURE TIDENT LPAREN argsId RPAREN proc_contract LBRACKET block RBRACKET 
  { { name = mk_ident $2;
      args = $4;
      precondition = fst $6;
      postcondition = snd $6;
      body = Block $8} 
  }
;

proc_contract:
| REQUIRES sl_form SEMICOLON proc_contract { (mk_sep $2 (fst $4), snd $4) }
| ENSURES sl_form SEMICOLON proc_contract { (fst $4, mk_sep $2 (snd $4)) }
| /* empty */ { (mk_emp, mk_emp) }

argsId:
  TIDENT { [mk_ident $1] }
| TIDENT COMMA argsId { (mk_ident $1) :: $3 }
| /* empty */ { [] }
;

sl_form:
/* pure part */
| TRUE { mk_true }
| FALSE { mk_false }
| pterm EQ pterm { mk_pure (FormUtil.mk_eq $1 $3) }
| pterm NEQ pterm { mk_pure (FormUtil.mk_neq $1 $3) }
| pterm LT pterm { mk_pure (FormUtil.mk_lt $1 $3) }
| pterm GT pterm { mk_pure (FormUtil.mk_gt $1 $3) }
| pterm LEQ pterm { mk_pure (FormUtil.mk_leq $1 $3) }
| pterm GEQ pterm { mk_pure (FormUtil.mk_geq $1 $3) }
/* spatial part */
| EMP { mk_emp }
| pterm PTS pterm { mk_pts fpts $1 $3 }
| pterm BPTS pterm { mk_pts fprev_pts $1 $3 }
| TIDENT LPAREN args RPAREN { mk_spatial_pred $1 $3 }
/* boolean structure */
| NOT sl_form { mk_not $2 }
| sl_form AND sl_form { mk_and $1 $3 }
| sl_form OR sl_form { mk_or $1 $3 }
| sl_form SEP sl_form { mk_sep $1 $3 }
| LPAREN sl_form RPAREN { $2 }
;

args:
  pterm { [$1] }
| pterm COMMA args { $1 :: $3 }
| /* empty */ { [] }
;

block:
  stmnt block { $1 :: $2 }
| /* empty */ { [] }
;

stmnt:
| NEW TIDENT SEMICOLON { New (mk_ident $2) }
| DISPOSE pterm SEMICOLON { Dispose $2 }
| pterm COLONEQ rhs SEMICOLON { match $1 with
                                | Form.App (Form.FreeSym id, [], _) -> VarUpdate (id, $3)
                                | Form.App (Form.Read, [Form.App (Form.FreeSym id, [], _); ind], _) -> FunUpdate (id, ind, $3)
                                | _ -> failwith "pterm rule returned something strange"
                              }
| ASSUME sl_form SEMICOLON { Assume $2 }
| ASSERT sl_form SEMICOLON { Assert ($2, None) }
| IF LPAREN expr RPAREN stmnt ELSE stmnt { Ite ($3, $5, $7) }
| IF LPAREN expr RPAREN stmnt { Ite ($3, $5, Block []) }
| WHILE LPAREN expr RPAREN loop_contract LBRACKET block RBRACKET { While ($3, $5, Block $7) }
| RETURN pterm SEMICOLON { Return $2 }
| call SEMICOLON { VarUpdate (FormUtil.mk_ident "no_return", $1) }
| LBRACKET block RBRACKET { Block $2 }
;

loop_contract:
  INVARIANT sl_form SEMICOLON loop_contract { mk_sep $2 $4 }
| /* empty */ { mk_emp }

rhs:
  pterm { Term $1 }
| call { $1 }

call:
| TIDENT LPAREN argsCall RPAREN { Call (mk_ident $1, $3) }

argsCall:
  pterm { [Term $1] }
| pterm COMMA argsCall { (Term $1) :: $3 }
| /* empty */ { [] }
;

pterm:
| pterm DOT NEXT { FormUtil.mk_read fpts $1 }
| pterm DOT PREV { FormUtil.mk_read fprev_pts $1 }
| pterm DOT DATA { FormUtil.mk_read fdata $1 }
| pterm PLUS pterm { FormUtil.mk_plus $1 $3 }
| pterm MINUS pterm { FormUtil.mk_minus $1 $3 }
| pterm MULT pterm { FormUtil.mk_mult $1 $3 }
| pterm DIV pterm { FormUtil.mk_div $1 $3 }
| MINUS pterm { FormUtil.mk_uminus $2 }
| TIDENT { FormUtil.mk_free_const (mk_ident $1) }
| NEXT { fpts }
| PREV { fprev_pts }
| DATA { fdata }
| NULL { FormUtil.mk_null }
| INT { FormUtil.mk_int $1 }
| LPAREN pterm RPAREN { $2 }
;

expr:
| LPAREN expr RPAREN { $2 }
| NOT expr { FormUtil.mk_not $2 }
| expr AND expr { FormUtil.mk_and [$1; $3] }
| expr OR expr { FormUtil.mk_or [$1; $3] }
| atom { $1 }
;

atom:
| TRUE { FormUtil.mk_true }
| FALSE { FormUtil.mk_false }
| pterm EQ pterm { FormUtil.mk_eq $1 $3 }
| pterm NEQ pterm { FormUtil.mk_not (FormUtil.mk_eq $1 $3) }
| pterm LT pterm { FormUtil.mk_lt $1 $3 }
| pterm GT pterm { FormUtil.mk_gt $1 $3 }
| pterm LEQ pterm { FormUtil.mk_leq $1 $3 }
| pterm GEQ pterm { FormUtil.mk_geq $1 $3 }
| PIDENT args { FormUtil.mk_pred (mk_ident $1) $2 }
;
