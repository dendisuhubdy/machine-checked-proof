(*  Author:     Christian Urban and Makarius

The nominal induct proof method.
*)

structure NominalInduct:
sig
  val nominal_induct_tac: bool -> (binding option * (term * bool)) option list list ->
    (string * typ) list -> (string * typ) list list -> thm list ->
    thm list -> int -> context_tactic
  val nominal_induct_method: (Proof.context -> Proof.method) context_parser
end =
struct

(* proper tuples -- nested left *)

fun tupleT Ts = HOLogic.unitT |> fold (fn T => fn U => HOLogic.mk_prodT (U, T)) Ts;
fun tuple ts = HOLogic.unit |> fold (fn t => fn u => HOLogic.mk_prod (u, t)) ts;

fun tuple_fun Ts (xi, T) =
  Library.funpow (length Ts) HOLogic.mk_case_prod
    (Var (xi, (HOLogic.unitT :: Ts) ---> Term.range_type T));

fun split_all_tuples ctxt =
  Simplifier.full_simplify (put_simpset HOL_basic_ss ctxt addsimps
    [@{thm split_conv}, @{thm split_paired_all}, @{thm unit_all_eq1}, @{thm fresh_unit_elim}, @{thm fresh_prod_elim}] @
    @{thms fresh_star_unit_elim} @ @{thms fresh_star_prod_elim});


(* prepare rule *)

fun inst_mutual_rule ctxt insts avoiding rules =
  let
    val (nconcls, joined_rule) = Rule_Cases.strict_mutual_rule ctxt rules;
    val concls = Logic.dest_conjunctions (Thm.concl_of joined_rule);
    val (cases, consumes) = Rule_Cases.get joined_rule;

    val l = length rules;
    val _ =
      if length insts = l then ()
      else error ("Bad number of instantiations for " ^ string_of_int l ^ " rules");

    fun subst inst concl =
      let
        val vars = Induct.vars_of concl;
        val m = length vars and n = length inst;
        val _ = if m >= n + 2 then () else error "Too few variables in conclusion of rule";
        val P :: x :: ys = vars;
        val zs = drop (m - n - 2) ys;
      in
        (P, tuple_fun (map #2 avoiding) (Term.dest_Var P)) ::
        (x, tuple (map Free avoiding)) ::
        map_filter (fn (z, SOME t) => SOME (z, t) | _ => NONE) (zs ~~ inst)
      end;
     val substs =
       map2 subst insts concls |> flat |> distinct (op =)
       |> map (fn (t, u) => (#1 (dest_Var t), Thm.cterm_of ctxt u));
  in 
    (((cases, nconcls), consumes), infer_instantiate ctxt substs joined_rule) 
  end;

fun rename_params_rule internal xs rule =
  let
    val tune =
      if internal then Name.internal
      else perhaps (try Name.dest_internal);
    val n = length xs;
    fun rename prem =
      let
        val ps = Logic.strip_params prem;
        val p = length ps;
        val ys =
          if p < n then []
          else map (tune o #1) (take (p - n) ps) @ xs;
      in Logic.list_rename_params ys prem end;
    fun rename_prems prop =
      let val (As, C) = Logic.strip_horn prop
      in Logic.list_implies (map rename As, C) end;
  in Thm.renamed_prop (rename_prems (Thm.prop_of rule)) rule end;


(* nominal_induct_tac *)

fun nominal_induct_tac simp def_insts avoiding fixings rules facts i (ctxt, st) =
  let
    val ((insts, defs), defs_ctxt) = fold_map Induct.add_defs def_insts ctxt |>> split_list;
    val atomized_defs = map (map (Conv.fconv_rule (Induct.atomize_cterm ctxt))) defs;

    val finish_rule =
      split_all_tuples defs_ctxt
      #> rename_params_rule true
        (map (Name.clean o Variable.revert_fixed defs_ctxt o fst) avoiding);

    fun rule_cases ctxt r =
      let val r' = if simp then Induct.simplified_rule ctxt r else r
      in Rule_Cases.make_nested ctxt (Thm.prop_of r') (Induct.rulified_term ctxt r') end;

    fun context_tac _ _ =
      rules
      |> inst_mutual_rule ctxt insts avoiding
      |> Rule_Cases.consume ctxt (flat defs) facts
      |> Seq.maps (fn (((cases, concls), (more_consumes, more_facts)), rule) =>
        (PRECISE_CONJUNCTS (length concls) (ALLGOALS (fn j =>
          (CONJUNCTS (ALLGOALS
            let
              val adefs = nth_list atomized_defs (j - 1);
              val frees = fold (Term.add_frees o Thm.prop_of) adefs [];
              val xs = nth_list fixings (j - 1);
              val k = nth concls (j - 1) + more_consumes
            in
              Method.insert_tac ctxt (more_facts @ adefs) THEN'
                (if simp then
                   Induct.rotate_tac k (length adefs) THEN'
                   Induct.arbitrary_tac defs_ctxt k (List.partition (member op = frees) xs |> op @)
                 else
                   Induct.arbitrary_tac defs_ctxt k xs)
            end)
          THEN' Induct.inner_atomize_tac defs_ctxt) j))
        THEN' Induct.atomize_tac ctxt) i st |> Seq.maps (fn st' =>
            Induct.guess_instance ctxt
              (finish_rule (Induct.internalize ctxt more_consumes rule)) i st'
            |> Seq.maps (fn rule' =>
              CONTEXT_CASES (rule_cases ctxt rule' cases)
                (resolve_tac ctxt [rename_params_rule false [] rule'] i THEN
                  PRIMITIVE (singleton (Proof_Context.export defs_ctxt ctxt))) (ctxt, st'))));
  in
    (context_tac CONTEXT_THEN_ALL_NEW
      ((if simp then Induct.simplify_tac ctxt THEN' (TRY o Induct.trivial_tac ctxt)
        else K all_tac) THEN_ALL_NEW Induct.rulify_tac ctxt)) i (ctxt, st)
  end;


(* concrete syntax *)

local

val avoidingN = "avoiding";
val fixingN = "arbitrary";  (* to be consistent with induct; hopefully this changes again *)
val ruleN = "rule";

val inst = Scan.lift (Args.$$$ "_") >> K NONE ||
  Args.term >> (SOME o rpair false) ||
  Scan.lift (Args.$$$ "(") |-- (Args.term >> (SOME o rpair true)) --|
    Scan.lift (Args.$$$ ")");

val def_inst =
  ((Scan.lift (Args.binding --| (Args.$$$ "\<equiv>" || Args.$$$ "==")) >> SOME)
      -- (Args.term >> rpair false)) >> SOME ||
    inst >> Option.map (pair NONE);

val free = Args.context -- Args.term >> (fn (_, Free v) => v | (ctxt, t) =>
  error ("Bad free variable: " ^ Syntax.string_of_term ctxt t));

fun unless_more_args scan = Scan.unless (Scan.lift
  ((Args.$$$ avoidingN || Args.$$$ fixingN || Args.$$$ ruleN) -- Args.colon)) scan;


val avoiding = Scan.optional (Scan.lift (Args.$$$ avoidingN -- Args.colon) |--
  Scan.repeat (unless_more_args free)) [];

val fixing = Scan.optional (Scan.lift (Args.$$$ fixingN -- Args.colon) |--
  Parse.and_list' (Scan.repeat (unless_more_args free))) [];

val rule_spec = Scan.lift (Args.$$$ "rule" -- Args.colon) |-- Attrib.thms;

in

val nominal_induct_method : (Proof.context -> Proof.method) context_parser =
  Scan.lift (Args.mode Induct.no_simpN) --
  (Parse.and_list' (Scan.repeat (unless_more_args def_inst)) --
    avoiding -- fixing -- rule_spec) >>
  (fn (no_simp, (((x, y), z), w)) => fn _ => fn facts =>
    (nominal_induct_tac (not no_simp) x y z w facts 1));

end;

end;
