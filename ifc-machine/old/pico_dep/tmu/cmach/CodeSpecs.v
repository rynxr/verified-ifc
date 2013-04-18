Require Import ZArith.
Require Import List.
Require Import Utils.
Require Import LibTactics.
Import ListNotations. (* list notations *)

Require Import TMUInstr.
Require Import Lattices.
Require Import Concrete.
Require Import Rules. 
Require Import CodeGen.
Require Import CLattices.
Require Import ConcreteMachine.

Section TMUSpecs.
Local Open Scope Z_scope.

Context {T: Type}
        {Latt: JoinSemiLattice T}
        {CLatt: ConcreteLattice T}.

Definition imemory : Type := list (@Instr T).
Definition memory : Type := list (@Atom T). 
Definition stack : Type := list (@CStkElmt T). 
Definition code := list (@Instr T).
Definition state := @CS T.

Section Glue.

Import Vector.VectorNotations.

Definition glue {n:nat} (vls :Vector.t T n) : (option T * option T * option T) :=
match vls with
| [] => (None,None,None)
| [t1] => (Some t1, None,None)
| [t1; t2] => (Some t1, Some t2, None)
| (t1::(t2::(t3::_))) => (Some t1, Some t2, Some t3)
end. 

End Glue.

(* ---------------------------------------------------------------- *)
(* Specs for self-contained code *)

(* Instruction memory contains code [c] starting at address [pc]. *)
Fixpoint code_at (pc: Z) (im: imemory) (c: code): Prop :=
  match c with
  | nil     => True
  | i :: c' => index_list_Z pc im = Some i 
               /\ code_at (pc + 1) im c'
  end.

Lemma code_at_compose_1: forall im c1 c2 n,
  code_at n im (c1 ++ c2) ->
  code_at n im c1.
Proof.
  induction c1; intros; simpl in *.
  intuition.
  intuition. eapply IHc1. eauto.
Qed.

Lemma code_at_compose_2: forall im c1 c2 n,
  code_at n im (c1 ++ c2) ->
  code_at (n + Z_of_nat (length c1)) im c2.
Proof.
  induction c1; intros; simpl in *.

  exact_f_equal H; omega.

  intuition.
  apply_f_equal IHc1; eauto; zify; omega.
Qed.
    
(* Here's a possible definition of "total correctness" Hoare triples on segments of code
that always "fall through." *)
Definition HT 
              (imem: imemory) 
              (P: memory -> stack -> Prop) (* pre-condition *)
              (start_pc end_pc : Z) (* code segment *)
              (Q: memory -> stack -> Prop) (* post-condition when code "falls through" *) :=
forall mem0 stk0,
  P mem0 stk0 ->
  exists mem1 stk1,
  runsToEnd cstep start_pc end_pc {| mem := mem0;
                               imem := imem;
                               stk := stk0;
                               pc := (start_pc,handlerLabel);
                               priv := true |}
                            {| mem := mem1;
                               imem := imem;
                               stk := stk1;
                               pc := (end_pc,handlerLabel);
                               priv := true |}
    /\ Q mem1 stk1. 

Lemma HT_compose: forall imem P pc0 pc1 Q pc2 R,
  HT imem P pc0 pc1 Q -> 
  HT imem Q pc1 pc2 R -> 
  HT imem P pc0 pc2 R. 
Proof.
  unfold HT in *. intros.
  edestruct H as [m1 [stk1 [ris1 c1]]]; eauto. clear H. 
  edestruct H0 as [m2 [stk2 [ris2 c2]]]; eauto. clear H0. 
  exists m2. exists stk2. split; auto.
  eapply runs_to_end_compose; eauto. 
Qed.

(* Hoare triple for a list of instructions *)
Definition HT'' (c: code)
                (* pre-condition *)
                (P: memory -> stack -> Prop)
                (* post-condition when code "falls through" *)
                (Q: memory -> stack -> Prop)
:= forall imem mem0 stk0 n n',
  code_at n imem c ->
  P mem0 stk0 ->
  n' = n + Z_of_nat (length c) -> 
  exists mem1 stk1,
  (* NC: would we gain anything by using projections to specify the
  state? *)
  Q mem1 stk1 /\
  runsToEnd' cstep n n' {| mem := mem0;
                           imem := imem;
                           stk := stk0;
                           pc := (n, handlerLabel);
                           priv := true |}
                        {| mem := mem1;
                           imem := imem;
                           stk := stk1;
                           pc := (n', handlerLabel);
                           priv := true |}.


Lemma HT''_compose: forall c1 c2 P Q R,
  HT'' c1 P Q ->
  HT'' c2 Q R ->
  HT'' (c1 ++ c2) P R.
Proof.
  unfold HT'' in *.
  intros c1 c2 P Q R HT1 HT2 imem mem0 stk0 n n' HC12 HP Hn'.
  subst.
  
  edestruct HT1 as [mem1 [stk1 [HQ RTE1]]]; eauto.
  apply code_at_compose_1 in HC12; eauto.

  edestruct HT2 as [mem2 [stk2 [HR RTE2]]]; eauto.
  apply code_at_compose_2 in HC12; eauto.

  eexists. eexists. intuition. eauto.
  eapply runsToEnd'_compose; eauto.

  (* NC: why is this let-binding necessary ? *)
  let t := (rewrite app_length; zify; omega) in
  exact_f_equal RTE2; rec_f_equal t.
  (* Because 'tacarg's which are not 'id's or 'term's need to be
     preceded by 'ltac' and enclosed in parens.  E.g., the following
     works:

       exact_f_equal RTE2;
       rec_f_equal ltac:(rewrite app_length; zify; omega).

     See grammar at
     http://coq.inria.fr/distrib/8.4/refman/Reference-Manual012.html

   *)
Qed.

(* NC: is there a way to give specifications as state transformers?
   The tricky part seems to be specifying the transformer arguments in
   terms of the needed stack "shape".

   Instead [HT c P Q], we'd have [HT c P Delta], and the meaning would
   be that code [c] takes state with [sm: stack * memory] satisfying
   [P sm] to state with [stack * memory] replaced by [Delta sm].

 *)
Definition HT' (c: code)
               (* pre-condition *)
               (P: memory -> stack -> Prop)
               (* post-condition when code "falls through" *)
               (Q: memory -> stack -> Prop)
:= forall imem mem0 stk0 n n',
  code_at n imem c ->
  P mem0 stk0 ->
  n' = n + Z_of_nat (length c) -> 
  exists mem1 stk1,
  (* NC: would we gain anything by using projections to specify the
  state? *)
  Q mem1 stk1 /\
  runsToEnd cstep n n'           {| mem := mem0;
                               imem := imem;
                               stk := stk0;
                               pc := (n, handlerLabel);
                               priv := true |}
                            {| mem := mem1;
                               imem := imem;
                               stk := stk1;
                               pc := (n', handlerLabel);
                               priv := true |}.

Lemma skipNZ_continuation_spec_NZ: forall c P v l,
  v <> 0 ->
  HT'' (skipNZ (length c) ++ c)
       (fun m s => (exists s', s = CData (v,l) :: s' 
                               /\ P m s'))
       P.
Proof.
  intros c P v l Hv.
  intros imem mem0 stk0 n n' Hcode HP Hn'.
  destruct HP as [stk1 [H_stkeq HPs']].
  exists mem0.
  exists stk1.
  intuition.

  (* Load an instruction *)
  subst. simpl.
  unfold skipNZ in *.
  unfold code_at in *. simpl in *. intuition. fold code_at in *.

  (* Run an instruction *) 
  eapply runsToEndStep'; eauto. 
  eapply cstep_branchnz ; eauto. 
  
  simpl. 
  assert (Hif: v =? 0 = false) by (destruct v; [omega | auto | auto]).
  rewrite Hif.
  econstructor 1.
  auto.
Qed.

Lemma skipNZ_spec_Z: forall n P v l,
  v = 0 ->
  HT'' (skipNZ n)
       (fun m s => (exists s', s = CData (v,l) :: s' 
                               /\ P m s'))
       P.
Proof.
  intros c P v l Hv.
  intros imem mem0 stk0 n n' Hcode HP Hn'.
  destruct HP as [stk1 [H_stkeq HPs']].
  exists mem0.
  exists stk1.
  intuition.

  (* Load an instruction *)
  subst. simpl.
  unfold skipNZ in *.
  unfold code_at in *. simpl in *. intuition. 

  (* Run an instruction *)
  eapply runsToEndStep'; auto.
  eapply cstep_branchnz ; eauto. 

  simpl.
  constructor. auto.
Qed.

Lemma skipNZ_continuation_spec_Z: forall c P Q v l,
  v = 0 ->
  HT'' c P Q  ->
  HT'' (skipNZ (length c) ++ c)
       (fun m s => (exists s', s = CData (v,l) :: s' 
                               /\ P m s'))
       Q.
Proof.
  intros c P Q v l Hv HTc.
  eapply HT''_compose.
  eapply skipNZ_spec_Z; auto.
  auto.
Qed.

Lemma push_spec: forall v P,
  HT'' (push v :: nil)
       (fun m s => P m (CData (v,handlerLabel) :: s))
       P.
Proof.
  intros v P.
  intros imem mem0 stk0 n n' Hcode HP Hn'.
  eexists. eexists. intuition. eauto.
  
  (* Load an instruction *)
  subst. simpl.
  unfold skipNZ in *.
  unfold code_at in *. simpl in *. intuition. 

  (* Run an instruction *)
  eapply runsToEndStep'; auto.
  eapply cstep_push ; eauto.

  simpl.

  constructor; auto.
Qed.

Lemma push_spec': forall v P,
  HT'' (push v :: nil)
       P
       (fun m s => head s = Some (CData (v,handlerLabel)) /\
                            P m (tail s)).
Proof.
  intros v P.
  intros imem mem0 stk0 n n' Hcode HP Hn'.
  exists mem0. exists (CData (v, handlerLabel) :: stk0).
  intuition.
  
  (* Load an instruction *)
  subst. simpl.
  unfold skipNZ in *.
  unfold code_at in *. intuition. 

  (* Run an instruction *)
  eapply runsToEndStep'; auto.
  eapply cstep_push ; eauto.
    
  simpl.
  constructor; auto.
Qed.

Lemma HT''_strengthen_premise: forall c (P' P Q: memory -> stack -> Prop),
  HT'' c P  Q ->
  (forall m s, P' m s -> P m s) ->
  HT'' c P' Q.
Proof.
  intros c P' P Q HTPQ P'__P.
  intros imem mem0 stk0 n n' Hcode HP' Hn'.
  edestruct HTPQ as [mem2 [stk2 [HR RTE2]]]; eauto.
Qed.

Lemma HT''_weaken_conclusion: forall c (P Q Q': memory -> stack -> Prop),
  HT'' c P  Q ->
  (forall m s, Q m s -> Q' m s) ->
  HT'' c P Q'.
Proof.
  intros ? ? ? ? HTPQ ?.
  intros imem mem0 stk0 n n' Hcode HP' Hn'.
  edestruct HTPQ as [mem2 [stk2 [HR RTE2]]]; eauto.
Qed.

Lemma HT''_consequence: forall c (P' P Q Q': memory -> stack -> Prop),
  HT'' c P Q ->
  (forall m s, P' m s -> P m s) ->
  (forall m s, Q m s -> Q' m s) ->
  HT'' c P' Q'.
Proof.
  intros.
  eapply HT''_weaken_conclusion; eauto.
  eapply HT''_strengthen_premise; eauto.
Qed.


(* A strengthened rule of consequence that takes into account that [Q]
   need only be provable under the assumption that [P] is true for
   *some* state.  This lets us utilize any "pure" content in [P] when
   establishing [Q]. *)
Lemma HT''_consequence': forall c (P' P Q Q': memory -> stack -> Prop),
  HT'' c P Q ->
  (forall m s, P' m s -> P m s) ->
  (forall m s, (exists m' s', P' m' s') -> Q m s -> Q' m s) ->
  HT'' c P' Q'.
Proof.
  intros ? ? ? ? ? HTPQ HPP' HP'QQ'.
  intros imem mem0 stk0 n n' Hcode HP' Hn'.
  edestruct HTPQ as [mem2 [stk2 [HR RTE2]]]; eauto.
  eexists. eexists.
  intuition.
  eapply HP'QQ'; eauto.
  auto.
Qed.

Lemma skip_spec: forall c P,
  HT'' (skip (length c) ++ c)
       P
       P.
Proof.
  intros c P.
  unfold skip.
  rewrite app_ass.  
  eapply HT''_compose.
  eapply push_spec'.
  eapply HT''_strengthen_premise.
  eapply skipNZ_continuation_spec_NZ.

  (* NC: how to avoid this [Focus]? We need the equality to come later
  the [skipNZ] spec maybe? *)
  Focus 2.
  intros.
  simpl.
  exists (tl s); intuition.
  destruct s; inversion H0; eauto.

  (* Back at the first (blurred) goal, which is now [1 <> 0] :P *)
  omega.
Qed.

Lemma ifNZ_spec_Z: forall v l t f P Q,
  HT'' f P Q ->
  v = 0 ->
  HT'' (ifNZ t f)
       (fun m s => (exists s', s = CData (v,l) :: s' /\ P m s'))
       Q.
Proof.
  intros v l t f P Q HTf Hveq0.
  unfold ifNZ.
  rewrite app_ass.
  eapply HT''_compose.
  
  apply skipNZ_spec_Z; auto.

  eapply HT''_compose; eauto.

  apply skip_spec.
Qed.

Lemma ifNZ_spec_NZ: forall v l t f P Q,
  HT'' t P Q ->
  v <> 0 ->
  HT'' (ifNZ t f)
       (fun m s => (exists s', s = CData (v,l) :: s' /\ P m s'))
       Q.
Proof.
  intros v l t f P Q HTt Hveq0.
  unfold ifNZ.
  rewrite <- app_ass.
  eapply HT''_compose; eauto.
  apply skipNZ_continuation_spec_NZ; auto.
Qed.

Lemma HT''_decide_join: forall T c c1 c2 P1 P2 P1' P2' Q (D: T -> Prop),
  (forall v, HT'' c1 P1 Q -> ~ D v -> HT'' c (P1' v) Q) ->
  (forall v, HT'' c2 P2 Q ->   D v -> HT'' c (P2' v) Q) ->
  (forall v, ~ D v \/ D v) ->
  HT'' c1 P1 Q ->
  HT'' c2 P2 Q ->
  HT'' c (fun m s => exists v, (~ D v /\ P1' v m s) \/ (D v /\ P2' v m s)) Q.
Proof.
  intros ? c c1 c2 P1 P2 P1' P2' Q D spec1 spec2 decD HT1 HT2.
  unfold HT''. intros imem mem0 stk0 n n' H_code_at HP neq.
  destruct HP as [v Htovornottov].
  pose (decD v) as dec. intuition.

  eapply spec1; eauto.
  eapply spec2; eauto.
Qed.

Lemma HT''_decide_join': forall T (v: T) c c1 c2 P1 P2 P1' P2' Q (D: T -> Prop),
  (HT'' c1 P1 Q -> ~ D v -> HT'' c P1' Q) ->
  (HT'' c2 P2 Q ->   D v -> HT'' c P2' Q) ->
  (forall v, ~ D v \/ D v) ->
  HT'' c1 P1 Q ->
  HT'' c2 P2 Q ->
  (* Switched to implication here.  I think this is a weaker
     assumption, and it's closer to the form of the [ifNZ] spec I want
   *)
  HT'' c (fun m s => (~ D v -> P1' m s) /\ (D v -> P2' m s)) Q.
Proof.
  intros ? v c c1 c2 P1 P2 P1' P2' Q D spec1 spec2 decD HT1 HT2.
  unfold HT''. intros imem mem0 stk0 n n' H_code_at HP neq.
  (* destruct HP as [v [[HDv HP1'] | [HnDv HP2']]]. *)
  pose (decD v) as dec. intuition.
Qed.

Lemma ifNZ_spec_helper: forall v l t f Pt Pf Q,
  HT'' t Pt Q ->
  HT'' f Pf Q ->
  HT'' (ifNZ t f)
       (fun m s => ((v <> 0 -> exists s', s = CData (v,l) :: s' /\ Pt m s') /\
                    (v =  0 -> exists s', s = CData (v,l) :: s' /\ Pf m s')))
       Q.
Proof.
  intros v l t f Pt Pf Q HTt HTf.
  eapply HT''_decide_join' with (D := fun v => v = 0).
  apply ifNZ_spec_NZ.
  apply ifNZ_spec_Z.
  intros; omega.
  auto.
  auto.
Qed.

Lemma ifNZ_spec: forall v l t f Pt Pf Q,
  HT'' t Pt Q ->
  HT'' f Pf Q ->
  HT'' (ifNZ t f)
       (fun m s => (exists s', s = CData (v,l) :: s' /\
                                   (v <> 0 -> Pt m s') /\
                                   (v =  0 -> Pf m s')))
       Q.
Proof.
  intros v l t f Pt Pf Q HTt HTf.
  eapply HT''_strengthen_premise.
  eapply ifNZ_spec_helper; eauto.
  intros m s [s' [s_eq [HNZ HZ]]].
  destruct (dec_eq v 0); subst; intuition;
    eexists; intuition.
Qed.

(* Hoare triples are implications, and so this corresponds to the
   quantifier juggling lemma:

     (forall x, (P x -> Q)) ->
     ((exists x, P x) -> Q)

*)
Lemma HT''_forall_exists: forall T c P Q,
  (forall (x:T), HT'' c (P x) Q) ->
  HT'' c (fun m s => exists (x:T), P x m s) Q.
Proof.
  intros ? c P Q HPQ.
  unfold HT''.
  intros imem mem0 stk0 n n' Hcode_at [x HPx] neq.
  eapply HPQ; eauto.
(*
  (* Annoyingly, we can't use [HT''_strengthen_premise] here, because
     the existential [x] in [exists (x:T), P x m s] is not introduced
     early enough :P.  I'm not alone:
     https://sympa.inria.fr/sympa/arc/coq-club/2013-01/msg00055.html *)
  intros ? c P Q HPQ.
  eapply HT''_strengthen_premise.
  eapply HPQ.
  intros m s [x HPx].
  (* Error: Instance is not well-typed in the environment of ?14322 *)
  (* instantiate (1:=x). *)
  (* And similar problems with: *)
  (* exact HPx. *)
*)
Qed.

(* The other direction (which I don't need) is provable from
   [HT''_strengthen_premise] *)
Lemma HT''_exists_forall: forall T c P Q,
  HT'' c (fun m s => exists (x:T), P x m s) Q ->
  (forall (x:T), HT'' c (P x) Q).
Proof.
  intros ? c P Q HPQ x.
  eapply HT''_strengthen_premise.
  eapply HPQ.
  intuition.
  eauto.
Qed.

(* I need to existentially bind [v] for the [ite_spec]. May have been
   easier to use existentials from the beginning ... *)
Lemma ifNZ_spec_existential: forall t f Pt Pf Q,
  HT'' t Pt Q ->
  HT'' f Pf Q ->
  HT'' (ifNZ t f)
       (fun m s => (exists v l s', s = CData (v,l) :: s' /\
                                   (v <> 0 -> Pt m s') /\
                                   (v =  0 -> Pf m s')))
       Q.
Proof.
  intros t f Pt Pf Q HTt HTf.
  eapply HT''_forall_exists.
  intro v.
  eapply HT''_forall_exists.
  intro l.
  apply ifNZ_spec.
  auto.
  auto.
Qed.

(* Might make more sense to make [Qc] be the thing that [Qc] implies
   here.  I.e., this version has an implicit use of
   [HT''_strengthen_premise] in it, which could always be inserted
   manually when needed. *)
Lemma ite_spec: forall c t f P Pt Pf Qc Q,
  HT'' c P  Qc ->
  HT'' t Pt Q ->
  HT'' f Pf Q ->
  (forall m s, Qc m s -> (exists v l s', s = CData (v,l) :: s' /\
                                         (v <> 0 -> Pt m s') /\
                                         (v =  0 -> Pf m s')))
  ->
  HT'' (ite c t f) P Q.
Proof.
  intros c t f P Pt Pf Qc Q HTc HTt HTf HQcP.
  unfold ite.
  eapply HT''_compose.
  apply HTc.
  eapply HT''_strengthen_premise.
  Focus 2.
  apply HQcP.
  apply ifNZ_spec_existential.
  auto.
  auto.
Qed.

Lemma cases_spec_base: forall d P Q,
  HT'' d P Q -> HT'' (cases nil d) P Q.
Proof.
  auto.
Qed.

Lemma cases_spec_step: forall c b cbs d P Qc Pt Pf Q,
  HT'' c P Qc ->
  HT'' b Pt Q ->
  HT'' (cases cbs d) Pf Q ->
  (forall m s, Qc m s -> (exists v l s', s = CData (v,l) :: s' /\
                                         (v <> 0 -> Pt m s') /\
                                         (v =  0 -> Pf m s')))
  ->
  HT'' (cases ((c,b)::cbs) d) P Q.
Proof.
  intros.
  eapply ite_spec; eauto.
Qed.

(* A specialized spec for the [cases] combinator.

   If

   - the conditions don't modify the existing stack or memory,
     but just push a value onto the stack, and that value is computed as
     a function of the stack and memory;

   - the different branches have different conclusions.

  Then if [cases] terminates, the conclusion of the first branch whose
  guard returned non-zero holds.

  Actually, that's what you get if you unfold this definition over a
  list of [(guard, branch)] pairs; this spec is just one step of
  unfolding. *)
Lemma cases_spec_step_specialized: forall c vc b cbs d P Qb Qcbs,
  (* This could be abstracted: code that transforms the stack by
  pushing one value computed from the existing stack and memory *)
  (forall m0 s0,
     HT'' c (fun m s => P m0 s0 /\
                        m = m0 /\
                        s = s0)
            (fun m s => P m0 s0 /\
                        m = m0 /\ 
                        s = CData (vc m0 s0, handlerLabel) :: s0)) ->
  HT'' b P Qb ->
  HT'' (cases cbs d) P Qcbs ->
  (forall m0 s0,
    HT'' (cases ((c,b)::cbs) d) (fun m s => P m0 s0 /\
                                            m = m0 /\
                                            s = s0)
                                (fun m s => (vc m0 s0 <> 0 -> Qb m s) /\
                                            (vc m0 s0 = 0 -> Qcbs m s))).
Proof.
  intros c vc b cbs d P Qb Qcbs Hc Hb Hcbs.
  intros m0 s0.
  pose (Hc m0 s0) as Hcm0s0.
  eapply ite_spec with (Pt := (fun m s => P m s /\ vc m0 s0 <> 0))
                       (Pf := (fun m s => P m s /\ vc m0 s0 =  0)).
  exact Hcm0s0.

  apply (HT''_consequence' _ _ _ _ _ Hb); intuition.
  elimtype False; jauto.

  apply (HT''_consequence' _ _ _ _ _ Hcbs); intuition.
  elimtype False; jauto.

  intuition.
  exists (vc m0 s0).
  exists handlerLabel.
  exists s0.
  intuition; subst; auto.
Qed.


(* Simplest example: the specification of a single instruction run in
privileged mode *)
Lemma add_spec: forall (z1 z2: Z) (l1 l2: T) (m: memory) (s: stack),
  HT' (Add :: nil)
      (fun m1 s1 => m1 = m /\ s1 = CData (z1,l1) :: CData (z2,l2) :: s)
      (fun m2 s2 => m2 = m /\ s2 = CData (z1 + z2, handlerLabel) :: s).
Proof.
  (* Introduce hyps *)
  intros.
  unfold HT'. intros. intuition.
  eexists.
  eexists.
  intros.
  intuition. 

  (* Load an instruction *)
  subst. simpl.
  unfold code_at in *. intuition. 
  
  (* Run an instruction *)
  eapply runsToEndStep; auto.
  unfold in_bounds.  simpl.  omega. 

  eapply cstep_add ; eauto.
  
  (* Finish running *)
  eapply runsToEndDone.
  omega. 
  auto.
Qed.

Lemma add_sub_spec: forall (z1 z2: Z) (l1 l2: T) (m: memory) (s: stack),
  HT' (Add :: Sub :: nil)
      (fun m1 s1 => m1 = m /\ s1 = CData (z1,l1) :: CData (z2,l2) :: CData (z2,l2) :: s)
      (fun m2 s2 => m2 = m /\ s2 = CData (z1, handlerLabel) :: s).
Proof.
  (* Introduce hyps *)
  intros.
  unfold HT'. intros. intuition. subst. 
  eexists.
  eexists. 
  intuition. 

  (* Load an instruction *)
  simpl.
  unfold code_at in *. intuition. 
  
  (* Run an instruction *)
  eapply runsToEndStep; auto.
  unfold in_bounds; simpl; try omega.

  eapply cstep_add; eauto.
  
  (* Run an instruction *)
  eapply runsToEndStep; auto.

  unfold in_bounds; simpl.  omega. 
  eapply cstep_sub; eauto.

  (* Finish running *)
  let t := (auto || omega) in
  apply_f_equal @runsToEndDone; rec_f_equal t.
Qed.


(* ================================================================ *)
(* Fault-handler-specific specs *)

Definition boolToZ (b: bool): Z  := if b then 1 else 0.

Hypothesis genJoin_spec: forall l l' m0 s0,
  HT'' genJoin
       (fun m s => m = m0 /\
                   s = CData (labToZ l, handlerLabel) ::
                       CData (labToZ l', handlerLabel) :: s0)
       (fun m s => m = m0 /\               
                   s = CData (labToZ (join l l'), handlerLabel) :: s0).

(* XXX: we can discharge this by implementing [genFlows] in terms of
   [genJoin], and using the fact that [flows l l' = true <-> join l l' = l']. *)
Hypothesis genFlows_spec: forall l l' m0 s0,
  HT'' genFlows
       (fun m s => m = m0 /\
                   s = CData (labToZ l, handlerLabel) ::
                       CData (labToZ l', handlerLabel) :: s0)
       (fun m s => m = m0 /\               
                   s = CData (boolToZ (flows l l'), handlerLabel) :: s0).

(* XXX: NC: Copied from ../mach_exec/TMUFaultRoutine.v. I'm not sure
how that file relates to ./FaultRoutine.v *)
Definition handler_initial_mem_matches 
           (opcode: OpCode)
           (op1lab: option T) (op2lab:option T) (op3lab:option T) (pclab: T) 
           (m: memory) : Prop := 
  index_list_Z addrOpLabel m = Some(opCodeToZ opcode,handlerLabel)
  /\ (match op1lab with
      | Some op1 => index_list_Z addrTag1 m = Some (labToZ op1,handlerLabel)
      |    None=> True
   end)  
  /\ (match op2lab with
      | Some op2 => index_list_Z addrTag2 m = Some (labToZ op2,handlerLabel)
      | None => True
      end)
  /\ (match op3lab with
      | Some op3 => index_list_Z addrTag3 m = Some (labToZ op3,handlerLabel)
      | None => True
      end)
  /\ index_list_Z addrTagPC m = Some (labToZ pclab,handlerLabel)
.

Parameter (opcode: OpCode).
Definition n := labelCount opcode. 
Parameter (vls: Vector.t T n). 
Parameter (pcl: T).
Parameter (m0: memory).


Hypothesis initial_mem_matches:
  let '(opv1,opv2,opv3) := glue vls in 
  handler_initial_mem_matches opcode opv1 opv2 opv3 pcl m0.

Definition eval_var := mk_eval_var vls pcl.

Conjecture genVar_spec:
  forall v l,
    eval_var v = l ->
    forall s0,
      HT'' (genVar v)
           (fun m s => m = m0 /\
                       s = s0)
           (fun m s => m = m0 /\
                       s = CData (labToZ l, handlerLabel) :: s0).

Conjecture genExpr_spec: forall (e: rule_expr n),
  forall l,
    eval_expr eval_var e = l ->
    forall s0,
      HT'' (genExpr e)
           (fun m s => m = m0 /\
                       s = s0)
           (fun m s => m = m0 /\
                       s = CData (labToZ l, handlerLabel) :: s0).

(* NC: I had to change the definition of [eval_cond] in
   ../amach/Rules.v to return [Some bool] instead of [bool] to make
   this provable.  Before, [eval_cond] returned [false] when
   [eval_var] returned [None], but now it returns [None] in that case.
   Without this change we can't distinguish between [eval_var]
   returning [None] and causing [eval_cond] to return [false], and
   [eval_cond] to returning [false] because the side condition
   failed. But, since we don't model the [option T] at the level of
   memory, we have no control over what [genVar v] returns when
   [eval_var v] returns [None]. *)

Conjecture genScond_spec: forall (c: rule_scond n),
  forall b,
    eval_cond eval_var c = b ->
    forall s0,
      HT'' (genScond c)
           (fun m s => m = m0 /\
                       s = s0)
           (fun m s => m = m0 /\
                       s = CData (boolToZ b, handlerLabel) :: s0).

(* XXX: Need to change the definition of [genRule] for this: it should
   take an AllowModify, but not an opcode, since that check will be
   part of the fault handler (a [cases] construct). The modified
   [genRule] will be called [genApplyRule]. *)

(* XXX: how to best model [option]s and monadic sequencing in the code
   gens?  E.g., for [genApplyRule_spec], I need to handle both [Some
   (Some l1, l2)] and [Some (None, l2)].  Do I do different things to
   memory in these cases? If so I need to distinguish these cases in
   my stack returns.

   Also, modeling [option]s in the generated code might make the
   correctness proof easier? *)

(* XXX: def this in ./CodeGen.v *)
Hypothesis genApplyRule:  AllowModify n -> code.


(* NC: NB: we should only need to reason about what [genApplyRule]
   does for the current opcode, since that's the only code that is
   going to run. *)


(* This is def in ../amach/AbstractMachine.v *)
Hypothesis fetch_rule: OpCode -> AllowModify n.

Conjecture genApplyRule_spec_Some:
  forall l1 l2,
    apply_rule (fetch_rule opcode) vls pcl = Some (Some l1, l2) ->
    forall s0,
      HT'' (genApplyRule (fetch_rule opcode))
           (fun m s => m = m0 /\
                       s = s0)
           (fun m s => m = m0 /\
                       s = CData (        1, handlerLabel) :: (* Model the [Some l1] *)
                           CData (labToZ l1, handlerLabel) ::
                           CData (labToZ l2, handlerLabel) :: s0).

Conjecture genApplyRule_spec_None:
  forall l2,
    apply_rule (fetch_rule opcode) vls pcl = Some (None, l2) ->
    forall s0,
      HT'' (genApplyRule (fetch_rule opcode))
           (fun m s => m = m0 /\
                       s = s0)
           (fun m s => m = m0 /\
                       s = CData (        0, handlerLabel) :: (* Model the [None] *)
                           CData (labToZ l2, handlerLabel) :: s0).


End TMUSpecs. 