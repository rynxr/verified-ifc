Require Import ZArith.
Require Import List.
Require Import Utils.
Import ListNotations.
Require Vector.

Require Import LibTactics.
Require Import Instr Memory.
Require Import Lattices.
Require Import Concrete.
Require Import ConcreteMachine.
Require Import Rules.
Require Import CLattices.
Require Import CodeTriples.
Require Import CodeSpecs.
Require Import CodeGen.
Require Import CLattices.
Require Import ConcreteExecutions.

Notation Atom := (Atom Z privilege).
Notation memory := (Mem.t Atom privilege).
Notation PcAtom := (PcAtom Z).
Notation block := (block privilege).

Section TMU.

Open Local Scope Z_scope.

Variable cblock : block.
Variable stamp_cblock : Mem.stamp cblock = Kernel.

Notation cget := (cget cblock).
Notation cache_hit_mem := (cache_hit_mem cblock).
Notation HT := (HT cblock).
Notation GT := (GT cblock).

Context {T: Type}
        {Latt: JoinSemiLattice T}
        {CLatt: ConcreteLattice T}
        {WFCLatt: WfConcreteLattice cblock T Latt CLatt}.


(* --------------------- TMU Fault Handler code ----------------------------------- *)

(* Compilation of rules *)

Definition genError :=
  push (-1) ++ [Jump].

Definition genVar {n:nat} (l:LAB n) :=
  match l with
  (* NC: We assume the operand labels are stored at these memory
     addresses when the fault handler runs. *)
  | lab1 _ => loadFromCache addrTag1
  | lab2 _ => loadFromCache addrTag2
  | lab3 _ => loadFromCache addrTag3
  | labpc => loadFromCache addrTagPC
  end.

Fixpoint genExpr {n:nat} (e: rule_expr n) :=
  match e with
  | L_Bot => genBot
  | L_Var l => genVar l
  (* NC: push the arguments in reverse order. *)
  | L_Join e1 e2 => genExpr e2 ++ genExpr e1 ++ genJoin
 end.

Fixpoint genScond {n:nat} (s: rule_cond n) : code :=
  match s with
  | A_True => genTrue
  | A_False => genFalse
  | A_LE e1 e2 => genExpr e2 ++ genExpr e1 ++ genFlows
  | A_And s1 s2 => genScond s2 ++ genScond s1 ++ genAnd
  | A_Or s1 s2 => genScond s2 ++ genScond s1 ++ genOr
  end.


Definition genApplyRule {n:nat} (am:AllowModify n): code :=
  ite (genScond (allow am))
      (some
        (genExpr (labResPC am) ++
         genExpr (labRes am))
      )
      none.

Section FaultHandler.

Definition genCheckOp (op:OpCode): code :=
  genTestEqual (push (opCodeToZ op)) (loadFromCache addrOpLabel).

Definition fetch_rule_impl_type: Type := forall (opcode:OpCode),  {n:nat & AllowModify n}.

Variable fetch_rule_impl: fetch_rule_impl_type.

Definition opcodes :=
  [OpNoop;
   OpAdd;
   OpSub;
   OpEq;
   OpPush;
   OpPop;
   OpLoad;
   OpStore;
   OpJump;
   OpBranchNZ;
   OpCall;
   OpRet;
   OpVRet;
   OpOutput;
   OpDup;
   OpSwap;
   OpAlloc].

(* Just making sure the above is correct *)
Lemma opcodes_correct : forall op, In op opcodes.
Proof. intros []; compute; intuition. Qed.

Definition genApplyRule' op := genApplyRule (projT2 (fetch_rule_impl op)).

(** Put rule application results on stack. *)

Definition genComputeResults: code :=
  indexed_cases nop genCheckOp genApplyRule' opcodes.

(** Write fault handler results to memory. *)

Definition genStoreResults: code :=
  ifNZ (storeAt addrTagRes ++
        storeAt addrTagResPC ++
        genTrue)
       genFalse.

(** The entire handler *)

Definition faultHandler: code :=
  genComputeResults ++
  genStoreResults ++
  ifNZ [Ret] genError.

(* NC: or

   ite (genComputeResults ++ genStoreResults)
        [Ret]
        genError.
*)

End FaultHandler.


(* ================================================================ *)
(* Fault-handler Code Specifications                                *)

(* Connecting vectors of labels to triples of tags. *)

Section Glue.

Import Vector.VectorNotations.

Local Open Scope nat_scope.


Definition nth_labToZ {n:nat} (vls: Vector.t T n) (s:nat) : Z -> memory -> Prop :=
  fun z m =>
    match le_lt_dec n s with
      | left _ => z = dontCare
      | right p => labToZ (Vector.nth_order vls p) z m
  end.

Lemma of_nat_lt_proof_irrel:
  forall (m n: nat) (p q: m < n),
    Fin.of_nat_lt p = Fin.of_nat_lt q.
Proof.
  induction m; intros.
    destruct n.
      false; omega.
      reflexivity.
    destruct n.
      false; omega.
      simpl; erewrite IHm; eauto.
Qed.

(* NC: this took a few tries ... *)
Lemma nth_order_proof_irrel:
  forall (m n: nat) (v: Vector.t T n) (p q: m < n),
    Vector.nth_order v p = Vector.nth_order v q.
Proof.
  intros.
  unfold Vector.nth_order.
  erewrite of_nat_lt_proof_irrel; eauto.
Qed.

Lemma nth_order_valid: forall (n:nat) (vls: Vector.t T n) m,
  forall (lt: m < n),
  nth_labToZ vls m = labToZ (Vector.nth_order vls lt).
Proof.
  intros.
  unfold nth_labToZ.
  destruct (le_lt_dec n m).
  false; omega.
  (* NC: Interesting: here we have two different proofs [m < n0] being
  used as arguments to [nth_order], and we need to know that the
  result of [nth_order] is the same in both cases.  I.e., we need
  proof irrelevance! *)
  erewrite nth_order_proof_irrel; eauto.
Qed.

Definition labsToZs {n:nat} (vls :Vector.t T n) (m: memory) : (Z * Z * Z) -> Prop :=
fun z0z1z2 =>
  let '(z0,z1,z2) := z0z1z2 in
  nth_labToZ vls 0 z0 m /\
  nth_labToZ vls 1 z1 m /\
  nth_labToZ vls 2 z2 m.

End Glue.

Section TMUSpecs.

Inductive handler_initial_mem_matches
            (opcode: Z)
            (tag1: Z) (tag2: Z) (tag3: Z) (pctag: Z)
            (m: memory) : Prop :=
| hiim_intro : forall
                 (HOPCODE : value_on_cache cblock m addrOpLabel (Vint opcode))
                 (HTAG1 : value_on_cache cblock m addrTag1 (Vint tag1))
                 (HTAG2 : value_on_cache cblock m addrTag2 (Vint tag2))
                 (HTAG3 : value_on_cache cblock m addrTag3 (Vint tag3))
                 (HPC : value_on_cache cblock m addrTagPC (Vint pctag)),
                 handler_initial_mem_matches opcode tag1 tag2 tag3 pctag m.
Hint Constructors handler_initial_mem_matches.

(* Connecting to the definition used in ConcreteMachine.v *)
Lemma init_enough: forall {n} (vls:Vector.t T n) m opcode pcl z0 z1 z2 zpc,
                   forall (Hvls: labsToZs vls m (z0,z1,z2))
                          (Hpcl: labToZ pcl zpc m),
    cache_hit_mem m (opCodeToZ opcode) (z0,z1,z2) zpc ->
    handler_initial_mem_matches (opCodeToZ opcode) z0 z1 z2 zpc m.
Proof.
  intros. destruct Hvls as [Hz0 [Hz1 Hz2]].
  unfold Concrete.cache_hit_mem,
         ConcreteMachine.cget in *.
  destruct (Mem.get_frame m cblock) as [cache|] eqn:E; inv H.
  inv UNPACK. inv OP. inv TAG1. inv TAG2. inv TAG3. inv TAGPC.
  econstructor; econstructor; unfold load; rewrite E; jauto.
Qed.

Variable fetch_rule_impl: fetch_rule_impl_type.
Variable (opcode: OpCode).
Let n := projT1 (fetch_rule_impl opcode).
Let am := projT2 (fetch_rule_impl opcode).
Variable (vls: Vector.t T n).
Variable (pcl: T).
Let eval_var := mk_eval_var vls pcl.

Inductive INIT_MEM (m0 : memory) : Prop :=
| IM_intro :
    forall z0 z1 z2 zpc zr zrpc
           (Hz0 : nth_labToZ vls 0 z0 m0)
           (Hz1 : nth_labToZ vls 1 z1 m0)
           (Hz2 : nth_labToZ vls 2 z2 m0)
           (Hpc : labToZ pcl zpc m0)
           (Hhandler : handler_initial_mem_matches (opCodeToZ opcode)
                                                   z0 z1 z2 zpc
                                                   m0),
      value_on_cache cblock m0 addrTagResPC zrpc ->
      value_on_cache cblock m0 addrTagRes zr ->
      INIT_MEM m0.
Hint Constructors INIT_MEM.

Variable (m0: memory).
Hypothesis initial_m0 : INIT_MEM m0.

(*
Ltac clean_up_initial_mem :=
  unfold handler_initial_mem_matches in *;
  intuition;
  generalize initial_mem_matches; intros HH; clear initial_mem_matches;
  jauto_set_hyps; intros.
*)

Lemma extension_comp_nth_labToZ : forall m1 m2 (n m:nat) (vls: Vector.t T n) z,
    nth_labToZ vls m z m1 ->
    extends m1 m2 ->
    mem_def_on_cache cblock m1 ->
    nth_labToZ vls m z m2.
Proof.
  unfold nth_labToZ; intros.
  destruct (le_lt_dec n0 m); eauto.
  eapply labToZ_extension_comp; eauto.
Qed.

Lemma extension_comp_value_on_cache :
  forall m1 m2 addr v,
    value_on_cache cblock m1 addr v ->
    extends m1 m2 ->
    value_on_cache cblock m2 addr v.
Proof.
  intros m1 m2 addr v H1 H2. inv H1. econstructor. eauto.
Qed.
Hint Resolve extension_comp_value_on_cache.

Lemma extension_comp_INIT_MEM : forall m1 m2,
    INIT_MEM m1 ->
    extends m1 m2 ->
    INIT_MEM m2.
Proof.
  intros.
  destruct H.
  inv Hhandler.
  assert (Hm1 : mem_def_on_cache cblock m1) by (econstructor; eauto).
  econstructor; eauto 7 using extension_comp_nth_labToZ, labToZ_extension_comp.
Qed.

Lemma INIT_MEM_def_on_cache: forall m, INIT_MEM m -> mem_def_on_cache cblock m.
Proof.
  intros m H. destruct H. inv Hhandler.
  econstructor; eauto using extension_comp_nth_labToZ, extension_comp_value_on_cache.
Qed.

(* genVar is only loading things on the stack, so no need
   of the memory extension hyp of I *)
Lemma genVar_spec:
  forall v l,
    eval_var v = l ->
    forall I,
      HT (genVar v)
         (fun m s => extends m0 m /\ I m s)
         (fun m s =>
            match s with
              | (Vint z,t) ::: tl => extends m0 m /\
                                labToZ l z m /\
                                I m tl
              | _ => False
            end).
Proof.
  intros v l Heval_var I.
  destruct initial_m0.
  inv Hhandler.
  assert (Hmem0: mem_def_on_cache cblock m0) by (econstructor; eauto).
  case_eq v; intros; subst; simpl;
  match goal with
    | [HH : value_on_cache cblock _ ?addr ?zz |-
       HT (loadFromCache ?addr) _ _] =>
       eapply HT_strengthen_premise
              with (P:= (fun m1 s0 => value_on_cache cblock m1 addr zz /\
                                      ((fun m s => extends m0 m /\ I m s) m1 s0)));
       try solve [intuition eauto];
       eapply HT_weaken_conclusion
  end;
  try (eapply loadFromCache_spec_I with (I := (fun m s => extends m0 m /\ I m s))); eauto;
  simpl; intros;
  destruct s; intuition;
  (destruct c; intuition);
  (destruct a; intuition);
  subst; intuition eauto using labToZ_extension_comp;
  unfold nth_labToZ in *;
  repeat match goal with
           | H : context [le_lt_dec ?n ?m] |- _ =>
             destruct (le_lt_dec n m); try omega
         end;
  erewrite nth_order_proof_irrel; eauto using labToZ_extension_comp.
Qed.

Hint Resolve  extension_comp_INIT_MEM INIT_MEM_def_on_cache.

Lemma genExpr_spec: forall (e: rule_expr n),
  forall l,
    eval_expr eval_var e = l ->
    forall I
           (Hext: extension_comp I),
      HT   (genExpr e)
           (fun m s => extends m0 m /\ I m s)
           (fun m s => match s with
                         | (Vint z, t) ::: tl => I m tl /\ labToZ l z m  /\
                                                 extends m0 m /\ INIT_MEM m
                         | _ => False
                       end).
Proof.
  induction e; intros ? Heval_expr ? Hext;
  simpl; simpl in Heval_expr.
  subst l.
  - eapply HT_weaken_conclusion.
    eapply genBot_spec' ; eauto.
    unfold extension_comp, extends in *; intuition ; eauto.
    go_match.

  - eapply HT_weaken_conclusion.
    eapply genVar_spec; eauto.
    go_match.

  - eapply HT_compose.
    eapply IHe2; eauto.

    eapply HT_compose.
    + eapply HT_strengthen_premise.
      eapply (IHe1 (eval_expr eval_var e1) (eq_refl _)
                   (fun m s =>
                      match s with
                        | (Vint z,t):::tl => I m tl
                                             /\ labToZ (eval_expr eval_var e2) z m
                                             /\ extends m0 m /\ INIT_MEM m
                        | _ => False
                      end)); eauto.
      unfold extension_comp, extends.
      destruct s; intuition.
      destruct c; intuition.
      destruct a.
      destruct v; intuition eauto using labToZ_extension_comp.
      go_match.
    + eapply HT_strengthen_premise.
      eapply HT_weaken_conclusion.
      eapply genJoin_spec'; eauto.
      go_match.
      go_match.
Qed.

Lemma genScond_spec: forall (c: rule_cond n),
  forall b,
    eval_cond eval_var c = b ->
    forall I (Hext: extension_comp I),
      HT   (genScond c)
           (fun m s => extends m0 m /\ I m s)
           (fun m s => match s with
                           | (Vint z,t):::tl => I m tl /\ boolToZ b = z /\
                                                extends m0 m /\ INIT_MEM m
                           | _ => False
                       end).
Proof.
  induction c; intros; simpl;
    try (simpl in H); subst.

  (* True *)
  eapply HT_weaken_conclusion.
  eapply push_spec_I. go_match.

  (* False *)
  eapply HT_weaken_conclusion.
  eapply push_spec_I. go_match.

  (* Flows *)
  eapply HT_compose.
  eapply genExpr_spec; eauto.

  eapply HT_compose.
  eapply HT_strengthen_premise; eauto.
  eapply (genExpr_spec r (eval_expr eval_var r) (eq_refl _))
  with
  (I:= fun m s =>
         match s with
           | (Vint z, t) ::: tl => I m tl /\ labToZ (eval_expr eval_var r0) z m /\
                                   extends m0 m
           | _ => False
     end).
    unfold extension_comp, extends; simpl.
    intros.
    destruct s; intuition.
    destruct c; intuition.
    destruct a.
    destruct v; intuition eauto using labToZ_extension_comp.
    go_match.
  eapply HT_consequence.
  eapply (genFlows_spec' cblock (eval_expr eval_var r) (eval_expr eval_var r0)
         (fun m s => extends m0 m /\ I m s)) ; eauto.
  unfold extension_comp, extends; simpl. intuition; eauto.
  go_match.
  go_match.

  (* And *)
  eapply HT_compose.
  eapply IHc2; eauto.

  eapply HT_compose.
  eapply HT_strengthen_premise.
  eapply (IHc1 (eval_cond eval_var c1) (eq_refl _)
                 (fun m s =>
                    match s with
                      | (Vint z,t):::tl => I m tl
                        /\ boolToZ (eval_cond eval_var c2) = z
                        /\ extends m0 m
                      | _ => False
                    end)); eauto.
  unfold extension_comp, extends; simpl.
  intuition; eauto. go_match.

  go_match.

  eapply HT_consequence.
  eapply (genAnd_spec_I) with (I:= fun m s => extends m0 m /\ I m s) ; eauto.
  go_match.
  go_match.

    (* OR *)
  eapply HT_compose.
  eapply IHc2; eauto.

  eapply HT_compose.
  eapply HT_strengthen_premise.
  eapply (IHc1 (eval_cond eval_var c1) (eq_refl _)
                 (fun m s =>
                    match s with
                      | (Vint z,t):::tl => I m tl
                        /\ boolToZ (eval_cond eval_var c2) = z
                        /\ extends m0 m
                      | _ => False
                    end)); eauto.
  unfold extension_comp, extends; simpl.
  intuition; eauto. go_match.
  go_match.

  eapply HT_consequence.
  eapply (genOr_spec_I) with (I:= fun m s => extends m0 m /\ I m s) ; eauto.
  go_match.
  go_match.
Qed.

(* XXX: how to best model [option]s and monadic sequencing in the code
   gens?  E.g., for [genApplyRule_spec], I need to handle both [Some
   (Some l1, l2)] and [Some (None, l2)].  Do I do different things to
   memory in these cases? If so I need to distinguish these cases in
   my stack returns.

   Also, modeling [option]s in the generated code might make the
   correctness proof easier? *)

(* NC: Nota bene: we should only need to reason about what
   [genApplyRule] does for the current opcode, since that's the only
   code that is going to run. *)

(* XXX: could factor out all the [apply_rule] assumptions
   below as:

     Parameter ar.
     Hypothesis apply_rule_eq: apply_rule am vls pcl = ar.

   and then use [ar] in place of [apply_rule am vls pcl] everywhere.
*)

Lemma genApplyRule_spec_Some:
  forall l1 l2,
    apply_rule am pcl vls = Some (l1, l2) ->
    forall I (Hext: extension_comp I),
      HT   (genApplyRule am)
           (fun m s => extends m0 m /\ I m s)
           (fun m s => match s with
                           | (Vint some1, t1) ::: (Vint zr, t3) ::: (Vint zrpc, t4) ::: tl =>
                             1 = some1 (* [Some (...)] *)
                             /\ labToZ l1 zrpc m /\ labToZ l2 zr m
                             /\ extends m0 m /\ I m tl
                           | _ => False
                       end).
Proof.
  introv Happly.
  unfold genApplyRule.
  unfold apply_rule in Happly.
  cases_if in Happly.
  inv  Happly. intros I Hext.

  - eapply (ite_spec_specialized_I' cblock (boolToZ true)); eauto.

    + eapply HT_weaken_conclusion.
      eapply (genScond_spec (allow am) true H I); eauto.
      go_match.

    + intros.
      eapply HT_weaken_conclusion.
      eapply some_spec_I.

      eapply HT_compose.
      eapply genExpr_spec with (I:= I); eauto.

      eapply HT_strengthen_premise.
      eapply genExpr_spec with
      (I:= fun m s => match s with
                        | (Vint z, t) ::: tl0 =>
                          I m tl0
                          /\ labToZ (eval_expr eval_var (labResPC am)) z m
                          /\ extends m0 m
                        | _ => False
                      end); eauto.
      unfold extension_comp, extends in *.
      simpl. intuition. go_match. eauto using labToZ_extension_comp.
      go_match.
      go_match.
    + intros; false; omega.
Qed.

Lemma genApplyRule_spec_None:
    apply_rule am pcl vls  = None ->
    forall I (Hext: extension_comp I),
      HT   (genApplyRule am)
           (fun m s => extends m0 m /\ I m s)
           (fun m s => match s with
                         | (Vint none1, t1) :::  tl =>
                           0 = none1  (* [None] *)
                           /\ extends m0 m /\ I m tl
                         | _ => False
                       end).
Proof.
  introv Happly Hext.
  unfold genApplyRule.
  unfold apply_rule in Happly.
  cases_if in Happly.

  eapply ite_spec_specialized_I' with (v:=boolToZ false); eauto; intros.
  eapply HT_weaken_conclusion.
  eapply genScond_spec; auto. unfold eval_var, n.
  rewrite H.
  go_match.
  unfold boolToZ in *; false; try omega.

  eapply HT_weaken_conclusion.
  eapply (push_spec_I cblock 0); eauto.
  go_match.
Qed.

Definition listify_apply_rule (ar: option (T * T))
                              (s0: stack) (zr zpc: Z) : stack -> Prop :=
  match ar with
  | None           => fun s => exists t, s = CData (Vint 0, t) :: s0
  | Some (lpc, lr) => fun s => exists t1 t2 t3, s = CData (Vint 1, t1)   ::
                                                    CData (Vint zr, t2)  ::
                                                    CData (Vint zpc, t3) :: s0
  end.

Definition labToZ_rule_res (ar: option (T * T)) (zr zpc: Z) m : Prop :=
  match ar with
  | None           => True
  | Some (lpc, lr) => labToZ lr zr m /\ labToZ lpc zpc m
  end.

Lemma genApplyRule_spec:
  forall ar,
    apply_rule am pcl vls = ar ->
    forall I (Hext: extension_comp I),
      HT   (genApplyRule am)
           (fun m s => extends m0 m /\ I m s)
           (fun m s => extends m0 m /\
                       exists s0 zr zrpc,
                       labToZ_rule_res ar zr zrpc m /\
                       listify_apply_rule ar s0 zr zrpc s /\
                       I m s0).
Proof.
  intros.
  unfold listify_apply_rule, labToZ_rule_res.
  case_eq ar ; [intros [r rpc] | intros rpc] ; intros ; subst.
  - eapply HT_weaken_conclusion.
    eapply (genApplyRule_spec_Some r rpc H0 I); eauto.
    go_match.
    do 5 eexists; eauto.
  - eapply HT_weaken_conclusion.
    eapply genApplyRule_spec_None; eauto.
    go_match. eexists. eexists 0. eexists 0.
    eauto.
Qed.

Lemma genApplyRule_spec_GT_ext:
  forall ar,
    apply_rule am pcl vls = ar ->
    forall (I:HProp) (Hext: extension_comp I),
      GT_ext cblock (genApplyRule am)
         (fun m s => extends m0 m /\ I m s)
         (fun m0' s0 m s => extends m0 m0' /\ extends m0' m /\
                            exists zr zrpc,
                              labToZ_rule_res ar zr zrpc m /\
                              listify_apply_rule ar s0 zr zrpc s /\
                              I m s0).
Proof.
  unfold GT_ext; intros.
  eapply HT_consequence.
  eapply  (genApplyRule_spec ar H (fun m s => extends m0 m1 /\
                                              extends m1 m /\
                                              s = s0 /\ I m s)); eauto.
  unfold extension_comp; eauto.
  unfold extends in *; intuition ; eauto.
  go_match. intuition; substs; eauto.
  unfold extends. auto.
  simpl. intros m s [Hm [s1 [zr [zrpc [Har Hlist]]]]].
  intuition. substs; eauto.
Qed.

Lemma genCheckOp_spec_HT_ext:
  forall opcode' I (Hext: extension_comp I),
    HT (genCheckOp opcode')
       (fun m s => extends m0 m /\ I m s)
       (fun m s => match s with
                       | (Vint z,t):::tl =>
                         extends m0 m /\
                         boolToZ (opCodeToZ opcode' =? opCodeToZ opcode) = z /\
                         I m tl
                       | _ => False
                   end).
Proof.
  destruct initial_m0.
  inv Hhandler. intuition.
  unfold genCheckOp.
  eapply genTestEqual_spec_I; try assumption. intros I' HextI'.
  eapply HT_strengthen_premise.
  eapply HT_weaken_conclusion.
  eapply (push_spec_I) with (I:= fun m s => extends m0 m /\ I' m s).
  go_match.
  go_match. intuition.
  intros I' HextI'.
  eapply HT_strengthen_premise.
  eapply HT_weaken_conclusion.
  eapply loadFromCache_spec_I with (v := Vint (opCodeToZ opcode)) (I:= fun m s => extends m0 m /\ I' m s); eauto.
  eauto.
  go_match.
  go_match; intuition eauto using extension_comp_value_on_cache.
Qed.

Lemma genCheckOp_spec_GT_ext:
  forall opcode' I (Hext: extension_comp I),
    GT_ext cblock (genCheckOp opcode')
       (fun m s => extends m0 m /\ I m s)
       (fun m0' s0 m s => exists t, extends m0 m0' /\ extends m0' m /\
                          s = (Vint (boolToZ (opCodeToZ opcode' =? opCodeToZ opcode))
                               ,t) ::: s0
                          /\ I m s0).
Proof.
  unfold GT_ext; intros.
  eapply HT_weaken_conclusion.
  eapply HT_strengthen_premise.
  eapply genCheckOp_spec_HT_ext with (I:= fun m s => extends m0 m1 /\
                                                 extends m1 m /\
                                                 I m s /\ s = s0).
  unfold extension_comp, extends ; simpl ; eauto.
  simpl; intuition (subst; eauto).
  simpl. intuition; substs; auto.
  unfold extends in * ; eauto.
  unfold extends in * ; eauto.
  simpl. go_match.
Qed.

End TMUSpecs.

Section FaultHandlerSpec.

Variable ar: option (T * T).

Variable fetch_rule_impl: fetch_rule_impl_type.
Variable (opcode: OpCode).
Let n := projT1 (fetch_rule_impl opcode).
Let am := projT2 (fetch_rule_impl opcode).

Variable (vls: Vector.t T n).
Variable (pcl: T).

Let eval_var := mk_eval_var vls pcl.

Hypothesis H_apply_rule: apply_rule am pcl vls = ar.

(* Don't really need to specify [Qnil] since it will never run *)
Definition Qnil: GProp := fun m0' s0 m s => True.
Definition genV: OpCode -> HFun :=
  fun i _ _ => boolToZ (opCodeToZ i =? opCodeToZ opcode).
Definition genC: OpCode -> code := genCheckOp.
Definition genB: OpCode -> code := genApplyRule' fetch_rule_impl.
Definition genQ: HProp -> OpCode -> GProp :=
         (fun I i m0' s0 m s => extends m0' m /\
                                exists zr zrpc,
                                  labToZ_rule_res ar zr zrpc m /\
                                  listify_apply_rule ar s0 zr zrpc s /\ I m s0).

Let INIT_MEM := INIT_MEM fetch_rule_impl opcode vls pcl.

Variable m0 : memory.
Hypothesis INIT_MEM0: INIT_MEM m0.

Lemma genCheckOp_spec_GT_push_v_ext:
  forall opcode' I (Hext: extension_comp I),
    GT_push_v_ext cblock (genC opcode')
                  (fun m s => extends m0 m /\ I m s)
                  (genV opcode').
Proof.
  intros; eapply GT_consequence'_ext; eauto.
  eapply genCheckOp_spec_GT_ext with (I:= fun m s => extends m0 m /\ I m s); eauto.
  unfold extension_comp, extends in *; intuition ; eauto.
  intuition.
  simpl.
  split_vc.
Qed.

Lemma dec_eq_OpCode: forall (o o': OpCode),
  o = o' \/ o <> o'.
Proof.
  destruct o; destruct o'; solve [ left; reflexivity | right; congruence ].
Qed.

Lemma opCodeToZ_inj: forall opcode opcode',
  (boolToZ (opCodeToZ opcode' =? opCodeToZ opcode) <> 0) ->
  opcode' = opcode.
Proof.
  intros o o'.
  destruct o; destruct o'; simpl; solve [ auto | intros; false; omega ].
Qed.

Lemma genApplyRule'_spec_GT_guard_v_ext:
  forall opcode' I (Hext: extension_comp I),
    GT_guard_v_ext cblock (genB opcode')
               (fun m s => extends m0 m /\ I m s)
               (genV opcode')
               (genQ I opcode').
Proof.
  intros.
  cases (dec_eq_OpCode opcode' opcode) as Eq; clear Eq. substs.
  - eapply GT_consequence'_ext; try assumption.
    unfold genB, genApplyRule'.
    eapply genApplyRule_spec_GT_ext; eauto.
    intuition.
    simpl. intuition.
    econstructor; eauto.

  - unfold GT_guard_v_ext, GT_ext, CodeTriples.HT.
    intros.
    unfold genV in *.
    pose (opCodeToZ_inj opcode opcode').
    false; intuition.
Qed.


Lemma H_indexed_hyps: forall (I:HProp) (Hext: extension_comp I),
                        indexed_hyps_ext cblock _ genC genB (genQ I)
                        genV (fun m s => extends m0 m /\ I m s) opcodes.
Proof.
  unfold indexed_hyps_ext; simpl;
  intuition ; try (solve
    [ (eapply GT_consequence'_ext; eauto);
    try solve [(eapply genCheckOp_spec_GT_push_v_ext; eauto)];
    try (simpl ; intuition ; subst ; iauto)
    | eapply genApplyRule'_spec_GT_guard_v_ext; eauto ]).
Qed.

End FaultHandlerSpec.

Variable ar: option (T * T).

Variable fetch_rule_impl: fetch_rule_impl_type.
Variable (opcode: OpCode).
Let n := projT1 (fetch_rule_impl opcode).
Let am := projT2 (fetch_rule_impl opcode).

Variable (vls: Vector.t T n).
Variable (pcl: T).

Let eval_var := mk_eval_var vls pcl.

Hypothesis H_apply_rule: apply_rule am pcl vls = ar.
Let INIT_MEM := INIT_MEM fetch_rule_impl opcode vls pcl.

Lemma genComputeResults_spec_GT_ext: forall I (Hext: extension_comp I)
                                       m0 (INIT_MEM0: INIT_MEM m0),
    GT_ext cblock (genComputeResults fetch_rule_impl)
       (fun m s => extends m0 m /\ I m s)
       (fun m0' s0 m s => extends m0 m0' /\ extends m0' m /\
                          exists zr zpc,
                            labToZ_rule_res ar zr zpc m /\
                            listify_apply_rule ar s0 zr zpc s /\ I m s0).
Proof.
  intros.
  unfold genComputeResults.
  eapply GT_consequence'_ext; try assumption.
  eapply indexed_cases_spec_ext with
  (Qnil:= Qnil)
  (genV:= genV opcode)
  (P:= fun m s => extends m0 m /\ I m s)
  (genQ:= genQ ar I); try assumption.
  - Case "default case that we never reach".
    unfold GT_ext; intros.
    eapply HT_consequence.
    eapply nop_spec_I with (I:= fun m s => extends m1 m /\ I m s /\ I m1 s); eauto.
    intros. intuition; subst.
    unfold extends in * ; eauto.
    eauto.
    unfold Qnil; iauto.
  - eapply (H_indexed_hyps ar fetch_rule_impl opcode vls pcl H_apply_rule m0 INIT_MEM0  I); auto.
  - simpl. iauto.
  - Case "untangle post condition".
    simpl.
    assert (0 = 0) by reflexivity.
    assert (1 <> 0) by omega.
    (* NC: Otherwise [cases] fails.  Thankfully, [cases] tells us this
    is the problematic lemma, whereas [destruct] just spits out a huge
    term and says it's ill typed *)
    clear H_apply_rule.
    unfold genV, genQ.
    cases opcode; simpl; intuition.
Qed.

Lemma genComputeResults_spec: forall I s0 m0 (INIT_MEM0: INIT_MEM m0),
    forall (Hext: extension_comp I),
      HT   (genComputeResults fetch_rule_impl)
           (fun m s => extends m0 m /\ s = s0 /\ I m0 s /\ I m s)
           (fun m s => extends m0 m /\
                       exists zr zpc,
                         labToZ_rule_res ar zr zpc m /\
                         listify_apply_rule ar s0 zr zpc s /\ I m s0).
Proof.
  intros.
  eapply HT_consequence.
  eapply (genComputeResults_spec_GT_ext I Hext m0); eauto.
  simpl.

  intros; intuition; substs; auto.
  unfold extends; eauto. auto.
  unfold extends; eauto.
  intros; intuition; intuition.
Qed.

(* trying in WP wtyle *)
Lemma storeAt_spec_wp': forall a Q,
  HT (storeAt a)
     (fun m0 s0 => exists vl s m, s0 = vl ::: s /\
                               store cblock a vl m0 = Some m /\
                               Q m s)
     Q.
Proof.
  intros.
  eapply HT_compose_flip.
  eapply store_spec_wp'; eauto.
  unfold push.
  eapply HT_strengthen_premise.
  eapply push_cptr_spec_wp.

  intuition; eauto. destruct H as [vl [s0 [m0 Hint]]]. intuition; substs.
  do 5 eexists; intuition; eauto.
Qed.

Lemma genStoreResults_spec_Some: forall Q,
  forall lr lpc,
    ar = Some (lpc,lr) ->
      HT genStoreResults
         (fun m s => exists s0 zr zpc,
            labToZ_rule_res ar zr zpc m /\
            listify_apply_rule ar s0 zr zpc s /\
            valid_address cblock addrTagRes m /\
            valid_address cblock addrTagResPC m /\
            forall t1 t2,
            exists m' m'',
              (store cblock addrTagRes (Vint zr,t1) m = Some m')
               /\ store cblock addrTagResPC (Vint zpc,t2) m' = Some m''
               /\ labToZ_rule_res ar zr zpc m''
               /\ Q m'' ((Vint 1,handlerTag):::s0))
         Q
.
Proof.
  introv Har_eq; intros.
  unfold listify_apply_rule.
  rewrite Har_eq.
  unfold genStoreResults.
  eapply HT_strengthen_premise.
  eapply ifNZ_spec_existential.
  eapply HT_compose_flip.
  eapply HT_compose_flip.
  eapply genTrue_spec_wp; eauto.
  eapply storeAt_spec_wp'.
  eapply storeAt_spec_wp'.
  eapply genFalse_spec_wp.

  intros. destruct H as [s0 [zr [zpc Hint]]]. intuition.
  split_vc.
  edestruct H4 as [m' [m'' Hint]]. intuition.
  subst.

  split_vc.
  inv H7.
Qed.

Lemma genStoreResults_spec_None: forall Q: memory -> stack -> Prop,
  ar = None ->
    HT genStoreResults
       (fun m s => exists s0 zr zpc,
                     labToZ_rule_res ar zr zpc m /\
                     listify_apply_rule ar s0 zr zpc s /\
                     (forall m0,
                       extends m m0 -> Q m0 ((Vint 0,handlerTag) ::: s0)))
       Q.
Proof.
  introv Har_eq; intros.
  unfold listify_apply_rule.
  rewrite Har_eq.
  unfold genStoreResults.

  eapply HT_strengthen_premise.
  eapply ifNZ_spec_existential.


  eapply HT_compose_flip.
  eapply HT_compose_flip.
  eapply genTrue_spec_wp; eauto.
  eapply storeAt_spec_wp'.
  eapply storeAt_spec_wp'.
  eapply genFalse_spec_wp.

  intros. destruct H as [s0 [zr [zpc [t Hint]]]].
  split_vc.
  eauto using extends_refl.
Qed.

(* DELETE?
(* The irrelevant memory never changes *)
Lemma genStoreResults_update_cache_spec_rvec:
  valid_address cblock addrTagRes m0 ->
  valid_address cblock addrTagResPC m0 ->
  forall s0,
    HT genStoreResults
       (fun m s => m = m0 /\
                   s = listify_apply_rule ar s0)
       (fun m s => update_cache_spec_rvec cblock m0 m).
Proof.
  intros.
  unfold update_cache_spec_rvec in *.

  cases ar as Eq_ar.
  destruct p.

  + eapply HT_weaken_conclusion;
    rewrite <- Eq_ar in *.

    eapply genStoreResults_spec_Some; eauto.

    simpl.
    intros;

    jauto_set_hyps; intros.
    split.
    * intros args NEQ.
      symmetry.
      exploit get_frame_store_neq; eauto.
      intros E. rewrite E. clear E H2.
      exploit get_frame_store_neq; eauto.
    * intros.
      rewrite (load_store_old H2); try congruence.
      rewrite (load_store_old H1); congruence.

  + eapply HT_weaken_conclusion;
    rewrite <- Eq_ar in *.

    eapply genStoreResults_spec_None; eauto.

    simpl; intuition; subst; auto.
    intros addr NEQ. trivial.
Qed.
*)

Definition handler_final_mem_matches (lrpc lr: T) (m m': memory): Z -> Z -> Prop :=
  fun zpc zr =>
    exists m_ext,
      extends m m_ext /\
      labToZ lrpc zpc m' /\
      labToZ lr zr m' /\
      cache_hit_read_mem cblock m' zr zpc /\
      update_cache_spec_rvec cblock m_ext m'. (* Nothing else changed since the extension *)

(* DELETE?
Lemma genStoreResults_spec_Some': forall lr lpc,
  valid_address cblock addrTagRes m0 ->
  valid_address cblock addrTagResPC m0 ->
  ar = Some (lpc, lr) ->
  forall s0,
    HT genStoreResults
       (fun m s => m = m0 /\
                   s = listify_apply_rule ar s0)
       (fun m s => handler_final_mem_matches lpc lr m0 m
                   /\ s = (Vint 1,handlerTag) ::: s0).
Proof.
  introv HvalidRes HvalidResPC Har_eq; intros.
  destruct HvalidRes as [m' Hm'].
  destruct HvalidResPC as [m'' Hm''].
  destruct (load_some_store_some Hm' (Vint (labToZ lr), handlerTag)) as [m''' T'].
  assert (TT:exists m'''',
            store cblock addrTagResPC (Vint (labToZ lpc), handlerTag) m''' = Some m'''').
    eapply load_some_store_some.
    erewrite load_store_old; eauto.
    compute; congruence.
  destruct TT as [m4 T4].
  unfold genStoreResults.
  eapply HT_strengthen_premise.
  eapply ifNZ_spec_NZ with (v := 1); try omega.
  eapply HT_compose_flip.
  eapply HT_compose_flip.
  eapply genTrue_spec_wp.
  simpl.
  eapply storeAt_spec_wp; auto.
  eapply storeAt_spec_wp; auto.
  rewrite Har_eq. simpl.
  intros m s [Hm Hs]. subst.
  eexists.
  repeat (split; eauto); try econstructor; eauto.
  + unfold cache_hit_read_mem.
    generalize (load_store_new T4).
    exploit (load_store_old T4 cblock addrTagRes).
    compute; congruence.
    intros EE.
    generalize (load_store_new T').
    rewrite <- EE.
    unfold load.
    destruct (Mem.get_frame m4 cblock) eqn:E; try congruence.
    econstructor;
    constructor; auto.
  + intros addr NEQ.
    exploit get_frame_store_neq; eauto.
    intros E. rewrite E. clear T4.
    exploit get_frame_store_neq; eauto.
  + intros ofs H1 H2.
    exploit (load_store_old T4 cblock ofs); try congruence.
    exploit (load_store_old T' cblock ofs); try congruence.
Qed.
*)

Lemma genError_specEscape: forall raddr (P: memory -> stack -> Prop),
  HTEscape cblock raddr genError
           P
           (fun m s => (P m s , Failure)).
Proof.
  intros.
  unfold genError.
  eapply HTEscape_compose.
  - eapply push_spec'.
  - eapply HTEscape_strengthen_premise.
    + eapply jump_specEscape_Failure; auto.
    + intuition.
      cases s; subst.
      * rewrite hd_error_nil in *; false.
      * rewrite hd_error_cons in *.
        inversion H0; subst; jauto.
Qed.

Definition genFaultHandlerReturn: code := ifNZ [Ret] genError.

(* ???
Lemma genFaultHandlerReturn_specEscape_Some: forall raddr lr lpc,
  forall s0,
  HTEscape cblock raddr genFaultHandlerReturn
       (fun (m : memory) (s : stack) =>
        handler_final_mem_matches lr lpc m0 m /\
        s = (Vint 1, handlerTag) ::: CRet raddr false false :: s0)
       (fun (m : memory) (s : stack) =>
        (s = s0 /\ handler_final_mem_matches lr lpc m0 m, Success)).
Proof.
  intros.
  unfold genFaultHandlerReturn.
  eapply HTEscape_strengthen_premise.
  - eapply ifNZ_specEscape with (v:=1) (Pf:=fun m s => True); auto; intros.
    eapply ret_specEscape.
    auto.
    false.
  - subst.
    intuition.
    jauto_set_goal; eauto.
Qed.
*)

Lemma genFaultHandlerReturn_specEscape_Some: forall raddr (Q: memory -> stack -> Prop),
  HTEscape cblock raddr genFaultHandlerReturn
           (fun m s =>
              exists s0,
              s = (Vint 1, handlerTag) ::: CRet raddr false false :: s0 /\
              Q m s0)
           (fun m s  => (Q m s, Success)).
Proof.
  intros.
  unfold genFaultHandlerReturn.
  eapply HTEscape_strengthen_premise.
  - eapply ifNZ_specEscape with (v:=1) (Pf:=fun m s => True); intros; try assumption.
    eapply ret_specEscape; try assumption.
    false.
  - subst.
    intuition. split_vc.
Qed.

Lemma genFaultHandlerReturn_specEscape_None: forall raddr s0 m0,
 HTEscape cblock raddr genFaultHandlerReturn
   (fun m s => (extends m0 m /\ s = (Vint 0, handlerTag) ::: s0))
   (fun m s => (extends m0 m /\ s = s0, Failure)).
Proof.
  intros.
  unfold genFaultHandlerReturn.
  eapply HTEscape_strengthen_premise.
  - eapply ifNZ_specEscape with (v := 0) (Pt := fun m s => True); intros; try assumption.
    + intuition.
    + eapply genError_specEscape.
  - intros.
    subst.
    intuition.
    jauto_set_goal; eauto.
Qed.

(* DELETE?
Lemma genFaultHandlerReturn_specEscape_None: forall raddr s0,
 HTEscape cblock raddr genFaultHandlerReturn
   (fun (m : memory) (s : stack) => m = m0 /\ s = (Vint 0, handlerTag) ::: s0)
   (fun (m : memory) (s : stack) => (m = m0 /\ s = s0, Failure)).
Proof.
  intros.
  unfold genFaultHandlerReturn.
  eapply HTEscape_strengthen_premise.
  - eapply ifNZ_specEscape with (v := 0) (Pt := fun m s => True); auto; intros.
    + intuition.
    + eapply genError_specEscape.
  - intros.
    subst.
    intuition.
    jauto_set_goal; eauto.
Qed.
*)

(* MOVE *)
Lemma extends_valid_address: forall m m' a,
                               valid_address cblock a m ->
                               extends m m' ->
                               valid_address cblock a m'.
Proof.
  intros m m' a VALID EXT.
  inv VALID.
  econstructor. apply EXT. eauto.
Qed.

Lemma faultHandler_specEscape_Some: forall syscode raddr lr lpc m0,
  INIT_MEM m0 ->
  valid_address cblock addrTagRes m0 ->
  valid_address cblock addrTagResPC m0 ->
  ar = Some (lpc, lr) ->
  forall s0,
    HTEscape cblock raddr ((faultHandler fetch_rule_impl)++syscode)
             (fun m s => m = m0 /\
                         s = (CRet raddr false false::s0))
             (fun m s => ( exists zr zpc,
                             s = s0 /\
                             handler_final_mem_matches lpc lr m0 m zpc zr
                         , Success )).
Proof.
  intros.
  eapply HTEscape_append.
  unfold faultHandler.

  eapply HTEscape_compose_flip.
  eapply HTEscape_compose_flip.

  eapply genFaultHandlerReturn_specEscape_Some ; eauto.
  eapply genStoreResults_spec_Some; eauto.
  eapply HT_consequence.
  eapply genComputeResults_spec with
    (I := fun m s => True)
    (m0 := m0)
    (s0 := CRet raddr false false :: s0)
  ; eauto.
  unfold extension_comp; eauto.
  intros. intuition. substs. unfold extends; eauto.
  simpl. intros. intuition.
  destruct H5 as [zr [zpc Hint]]. intuition.
  exists (CRet raddr false false :: s0).
  exists zr ; exists zpc.
  intuition; eauto using extends_valid_address.

  assert (Hm'm'':
            exists m' m'',
              store cblock addrTagRes (Vint zr, t1) m = Some m' /\
              store cblock addrTagResPC (Vint zpc, t2) m' = Some m'').
  {
   exploit (extends_valid_address m0 m addrTagRes); eauto. intros HvalidRes.
   exploit (extends_valid_address m0 m addrTagResPC); eauto. intros HvalidResPC.
   eapply (valid_store cblock addrTagRes (Vint zr,t1)) in HvalidRes.
   destruct HvalidRes as [m' ?].
   eapply valid_address_upd with (a:= addrTagResPC) in HvalidResPC; eauto.
   eapply valid_store in HvalidResPC.
   destruct HvalidResPC as [m'' ?]; eauto.
  }

  destruct Hm'm'' as [m' [m'' [Hm' Hm'']]].
  assert (Hup: mem_eq_except_cache cblock m m''); eauto.
  {
    econstructor.
    - eapply INIT_MEM_def_on_cache; eauto using extension_comp_INIT_MEM.
    - intros b.
      unfold store in *.
      split.
      + intros USER.
        transitivity (Mem.get_frame m' b);
        eapply get_frame_store_neq; eauto;
        congruence.
      + intros fr KERNEL NEQ DEF.
        rewrite <- DEF.
        transitivity (Mem.get_frame m' b);
        eapply get_frame_store_neq; eauto;
        assumption.
  }
  do 2 eexists ; intuition; eauto.
  {  unfold labToZ_rule_res in *.
     rewrite H2 in *. intuition; eapply labToZ_cache; eauto.
  }
  eexists; intuition; eauto.
  exists zr ; exists zpc ; intuition; eauto.
  exists m. intuition; eauto.
  {  unfold labToZ_rule_res in *.
     rewrite H2 in *. intuition; eapply labToZ_cache; eauto.
  }
  {  unfold labToZ_rule_res in *.
     rewrite H2 in *. intuition; eapply labToZ_cache; eauto.
  }
  { assert (Hm''' : load cblock addrTagRes m'' = Some (Vint zr, t1)).
    { eapply load_store_new in Hm'.
      erewrite load_store_old; eauto.
      compute; congruence. }
    clear Hm'.
    eapply load_store_new in Hm''.
    unfold load, cache_hit_read_mem in *.
    destruct (Mem.get_frame m'' cblock) as [fr|]; try congruence.
    econstructor; econstructor; eauto.
  }

  unfold update_cache_spec_rvec. destruct Hup.
  split; auto.
  clear - Hm' Hm''.
  intros addr NEQ1 NEQ2.
  symmetry.
  transitivity (load cblock addr m');
  eapply load_store_old; eauto; congruence.
Qed.

(* AAA: Stopped transcription here *)

Lemma faultHandler_specEscape_None: forall syscode raddr m0,
                                    forall (INIT_MEM0: INIT_MEM m0),
  ar = None ->
  forall s0,
    HTEscape cblock raddr ((faultHandler fetch_rule_impl)++syscode)
             (fun m s => m0  = m /\ s = s0)
             (fun m s => ((extends m0 m /\ s = s0)
                         , Failure)).
Proof.
  intros.
  eapply HTEscape_append.
  unfold faultHandler.
  eapply HTEscape_compose_flip.
  eapply HTEscape_compose_flip.
  eapply genFaultHandlerReturn_specEscape_None ; eauto.
  eapply genStoreResults_spec_None; eauto.
  eapply HT_consequence.
  eapply genComputeResults_spec with
    (I := fun m s => True)
    (m0 := m0)
    (s0 := s0)
  ; eauto.
  unfold extension_comp; eauto.
  intros. intuition.
  subst. unfold extends in *; intuition.
  simpl. intros. intuition.
  destruct H2 as [zr [zpc Hint]]. intuition.
  exists s0. exists zr ; exists zpc.
  intuition; eauto using extends_valid_address.
  unfold extends in *; intuition.
Qed.

End TMU.

Section HandlerCorrect.

Variable cblock : block.
Variable stamp_cblock : Mem.stamp cblock = Kernel.

Context {T : Type}
        {Latt : JoinSemiLattice T}
        {CLatt : ConcreteLattice T}
        {WFCLatt : WfConcreteLattice cblock T Latt CLatt}.

Variable get_rule : forall (opcode:OpCode), {n:nat & AllowModify n}.
Definition handler : list Instr := faultHandler get_rule.

Require Import ConcreteExecutions.

Theorem handler_correct_succeed :
  forall syscode opcode vls pcl c raddr s i lr lpc z1 z2 z3 zpc,
  forall
    (LABS: (labsToZs vls) c (z1, z2, z3))
    (LABPC: (labToZ pcl) zpc c)
    (INPUT: cache_hit_mem cblock c (opCodeToZ opcode) (z1,z2,z3) zpc)
    (RULE: apply_rule (projT2 (get_rule opcode)) pcl vls = Some (lpc,lr)),
    exists c' zr zrpc,
    runsToEscape cblock
                 (CState c (handler++syscode) i (CRet raddr false false::s) (0,handlerTag) true)
                 (CState c' (handler++syscode) i s raddr false) /\
    handler_final_mem_matches cblock lpc lr c c' zrpc zr.
Proof.
 intros.
  assert (valid_address cblock addrTagRes c).
  { unfold cache_hit_mem, valid_address, load in *.
    destruct (Mem.get_frame c cblock) as [fr|]; try solve [intuition].
    inv INPUT. inv TAGR. eauto. }
  assert (valid_address cblock addrTagResPC c).
  { unfold cache_hit_mem, valid_address, load in *.
    destruct (Mem.get_frame c cblock) as [fr|]; try solve [intuition].
    inv INPUT. inv TAGRPC. eauto. }
  edestruct (faultHandler_specEscape_Some cblock stamp_cblock
                                          (Some (lpc,lr)) _
                                          opcode vls pcl RULE syscode raddr lr lpc c)
    as [stk1 HH]; eauto.
 - exploit (@init_enough cblock stamp_cblock _ _ _ _ (projT1 (get_rule opcode)) vls); eauto.
   intros Hmem.
   repeat match goal with
            | H : valid_address _ _ _ |- _ =>
              destruct H as ([? ?] & ?)
          end;
   econstructor; simpl in LABS; intuition; eauto;
   econstructor; eauto.
 - apply code_at_id.
 - destruct HH as [cache1 [pc1 [priv1 [[zr [zpc' [P1 P2]]] [P3 P4]]]]].
   subst. inv P3.
   exists cache1;  exists zr; exists zpc'.
   split; auto.
   eapply P4.
Qed.

Theorem handler_correct_fail :
  forall syscode opcode vls pcl c raddr s i z1 z2 z3 zpc,
  forall (LABS: (labsToZs vls) c (z1, z2, z3))
         (LABPC: (labToZ pcl) zpc c)
         (INPUT: cache_hit_mem cblock c (opCodeToZ opcode) (z1,z2,z3) zpc)
         (RULE: apply_rule (projT2 (get_rule opcode)) pcl vls = None),
    exists st c',
      runsToEscape cblock
                   (CState c (handler++syscode) i (CRet raddr false false::s) (0,handlerTag) true)
                   (CState c' (handler++syscode) i st (-1,handlerTag) true) /\
    extends c c'.
Proof.
  intros.
  assert (valid_address cblock addrTagRes c).
  { unfold cache_hit_mem, valid_address, load in *.
    destruct (Mem.get_frame c cblock) as [fr|]; try solve [intuition].
    inv INPUT. inv TAGR. eauto. }
  assert (valid_address cblock addrTagResPC c).
  { unfold cache_hit_mem, valid_address, load in *.
    destruct (Mem.get_frame c cblock) as [fr|]; try solve [intuition].
    inv INPUT. inv TAGRPC. eauto. }
  edestruct (faultHandler_specEscape_None cblock stamp_cblock None _ opcode vls pcl RULE syscode raddr c)
      as [stk1 HH]; eauto.
  - exploit (@init_enough cblock stamp_cblock _ _ _ _ (projT1 (get_rule opcode))); eauto.
    intros Hmem.
    repeat match goal with
             | H : valid_address _ _ _ |- _ =>
               destruct H as ([? ?] & ?)
           end;
    econstructor; simpl in LABS; intuition; eauto;
    econstructor; eauto.
  - apply code_at_id.
  - destruct HH as [cache1 [pc1 [priv1 [[P1 P2] [P3 P4]]]]].
    substs. inv P3.
    eexists ; eexists; intuition; eauto.
Qed.

End HandlerCorrect.