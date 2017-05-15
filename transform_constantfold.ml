open Instr

(*
 * Constant folding.
 *
 * This optimization combines constant propagation and constant folding.
 *
 * A variable is constant if
 *   (1) It is defined as `var x = l` where `l` is a literal
 *   (2) It is defined as `var x = op(se)` where `op(se)` is a primop involving
 *       literals or constant variables
 *
 * Then, whenever `x` is used in an expression (while x is still in scope), it
 * is replaced by its constant value. Afterwards, the variable `x` is no longer
 * used, and the declaration can be removed by running `minimize_lifetimes`.
 *)
let const_fold ({formals; instrs} : analysis_input) : instructions option =
  let module VarMap = Map.Make(Variable) in
  let module Approx = struct
    type t = Unknown | Value of value
    let equal a1 a2 = match a1, a2 with
      | Unknown, Unknown -> true
      | Unknown, Value _ | Value _, Unknown -> false
      | Value v1, Value v2 -> Eval.value_eq v1 v2
  end in

  (* Constant fold an expression. *)
  let fold exp =
    if not (VarSet.is_empty (expr_vars exp)) then exp
    else Simple (Constant (Eval.eval Eval.Heap.empty Eval.Env.empty exp))
  in

  (* Constant fold an instruction. *)
  let fold_instr instr =
    match instr with
    | Decl_var (x, e) -> Decl_var (x, fold e)
    | Decl_array (x, def) ->
      let def = match def with
      | Length e -> Length (fold e)
      | List es -> List (List.map fold es)
      in Decl_array (x, def)
    | Call (x, f, es) -> Call (x, f, List.map fold es)
    | Return e -> Return (fold e)
    | Assign (x, e) -> Assign (x, fold e)
    | Array_assign (x, ei, e) -> Array_assign (x, fold ei, fold e)
    | Branch (e, l1, l2) -> Branch (fold e, l1, l2)
    | Print e -> Print (fold e)
    | Assert e -> Assert (fold e)
    | Stop e -> Stop (fold e)
    | Osr {cond; target; map} ->
      let cond = List.map fold cond in
      let map = List.map (fun (Osr_var (y, e)) -> Osr_var (y, fold e)) map in
      Osr {cond; target; map}
    | Drop _ | Read _ | Label _ | Goto _ | Comment _ -> instr
  in

  (* Replaces the var `x` with var or val `v` in instruction `instr`. *)
  let replace x v instr =
    let replace = Edit.replace_var_in_exp x v in
    let replace_arg = Edit.replace_var_in_arg x v in
    match instr with
    | Call (y, f, es) ->
      assert (x <> y);
      Call (y, replace f, List.map replace_arg es)
    | Stop e ->
      Stop (replace e)
    | Return e ->
      Return (replace e)
    | Decl_var (y, e) ->
      assert (x <> y);
      Decl_var (y, replace e)
    | Decl_array (y, def) ->
      assert (x <> y);
      let def = match def with
        | Length e -> Length (replace e)
        | List es -> List (List.map replace es)
      in Decl_array (y, def)
    | Assign (y, e) ->
      Assign (y, replace e)
    | Array_assign (y, i, e) ->
      Array_assign (y, replace i, replace e)
    | Branch (e, l1, l2) -> Branch (replace e, l1, l2)
    | Print e -> Print (replace e)
    | Assert e -> Assert (replace e)
    | Osr {cond; target; map} ->
      (* Replace all expressions in the osr environment. *)
      let map = List.map (fun (Osr_var (y, e)) -> Osr_var (y, replace e)) map in
      let cond = List.map replace cond in
      Osr {cond; target; map}
    | Drop y
    | Read y ->
      instr
    | Label _ | Goto _ | Comment _ -> instr in

  (* for each instruction, what is the set of variables that are constant? *)
  let constants =
    let open Analysis in
    let open Approx in

    let merge pc cur incom =
      let merge_approx x mv1 mv2 = match mv1, mv2 with
        | Some Unknown, _ | _, Some Unknown -> Some Unknown
        | Some (Value v1), Some (Value v2) ->
          if Eval.value_eq v1 v2 then Some (Value v1) else Some Unknown
        | None, _ | _, None -> (*BISECT-IGNORE*) failwith "scope error?"
      in
      if VarMap.equal Approx.equal cur incom then None
      else Some (VarMap.merge merge_approx cur incom)
    in

    let update pc cur =
      (* Before we check if the variable declaration `var x = e` is constant,
       * we have to normalize `e`. We do this by constant propagating the
       * current variables, and then constant folding the expression. *)
      let approx env exp =
        let try_prop x e =
          match VarMap.find x env with
          | Approx.Unknown -> e
          | Approx.Value l -> Edit.replace_var_in_exp x (Constant l) e
        in
        match fold (VarSet.fold try_prop (expr_vars exp) exp) with
        | Simple (Constant l) -> Value l
        | Simple (Var _) | Op _ -> Unknown
      in
      match[@warning "-4"] instrs.(pc) with
      | Decl_var (x, e)
      | Assign (x, e) ->
        VarMap.add x (approx cur e) cur
      | Decl_array (x, _) ->
        (* this case could be improved with approximation for arrays so
           that, eg., length(x) could be constant-folded *)
        VarMap.add x Unknown cur
      | Call (x, _, _) as call ->
        let mark_unknown x cur = VarMap.add x Unknown cur in
        cur
        |> VarSet.fold mark_unknown (changed_vars call)
        |> VarMap.add x Unknown
      | Drop x ->
        VarMap.remove x cur
      | Array_assign (x, _, _) | Read x ->
        assert (VarMap.mem x cur);
        (* the array case could be improved with approximation for
           arrays *)
        VarMap.add x Unknown cur
      | ( Branch _ | Label _ | Goto _ | Return _
        | Print _ | Assert _ | Stop _ | Osr _ | Comment _)
        as instr ->
        begin
          assert (VarSet.is_empty (changed_vars instr));
          assert (VarSet.is_empty (dropped_vars instr));
          assert (VarSet.is_empty (defined_vars instr));
        end;
        cur
    in

    let initial_state =
      let add_formal x st = VarMap.add x Unknown st in
      VarSet.fold add_formal formals VarMap.empty
    in
    Analysis.forward_analysis initial_state instrs merge update
  in

  let transform_instr pc instr =
    let consts = constants pc in
    let transform x approx instr =
      match approx with
      | Approx.Unknown -> instr
      | Approx.Value l -> replace x (Constant l) instr in
    VarMap.fold transform consts instr |> fold_instr in

  let new_instrs = Array.mapi transform_instr instrs in
  if new_instrs = instrs
  then None
  else Some new_instrs
