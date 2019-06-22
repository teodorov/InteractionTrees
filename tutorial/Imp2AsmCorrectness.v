(** * Functional correctness of the compiler *)

(** We finally turn to proving our compiler correct.

SAZ: This needs to be updated.

    We express the result as a (weak) bisimulation between
    the [itree] resulting from the denotation of the source
    _Imp_ statement and the denotation of the compiled _Asm_
    program. This weak bisimulation is a _up-to-tau_ bisimulation.
    More specifically, we relate the itrees after having
    interpreted the [Locals] events contained in the trees into
    the state monad, and run them.

    The proof is essentially structured as followed:
    - a simulation relation is defined to relate the local
    environments during the simulation. This relation is
    strengthened into a second one used during the simulation
    of expressions.
    - the desired bisimulation is defined to carry out the
    the simulation invariant into a up-to-tau after interpretation
    of [Locals] relation. Once again a slightly different
    bisimulation is defined when handling expressions.
    - Linking is proved in isolation: the "high level" control
    flow combinators for _Asm_ defined in [Imp2Asm.v] are
    proved correct in the same style as the elementary ones
    from [AsmCombinators.v].
    - Finally, all the pieces are tied together to prove the
    correctness.

    We emphasize the following aspects of the proof:
    - Despite establishing a termination-sensitive correctness
    result over Turing-complete languages, we have not written
    a single [cofix]. All coinductive reasoning is internalized
    into the [itree] library.
    - We have separated the control-flow-related reasoning from
    the functional correctness one. In particular, the low-level
    [asm] combinators are entirely reusable, and the high-level
    ones are only very loosely tied to _Imp_.
    - All reasoning is equational. In particular, reasoning at the
    level of [ktree]s rather than introducing the entry label and
    trying to reason at the level of [itree]s ease sensibly the pain
    by reducing the amount of binders under which we need to work.
    - We transparently make use of the heterogeneous bisimulation provided
    by the [itree] library to relate computations of _Asm_ expressions
    that return an environment and a [unit] value to ones of _Imp_
    that return an environment and an [Imp.value].
*)

(* begin hide *)
Require Import Imp Asm Utils_tutorial AsmCombinators Imp2Asm Label.

Require Import Psatz.

From Coq Require Import
     Strings.String
     Program.Basics
     Morphisms
     ZArith
     Setoid
     Fin
     RelationClasses.

From ITree Require Import
     Basics.Basics
     CategoryOps
     ITree
     ITreeFacts
     Events.StateFacts
     Events.MapDefault
     SubKTree
     SubKTreeFacts.

Import ITreeNotations.

From ExtLib Require Import
     Core.RelDec
     Structures.Monad
     Structures.Maps
     Data.Map.FMapAList.

Import ListNotations.
Open Scope string_scope.

Import CatNotations.
Local Open Scope cat.

Import Monads.
Open Scope monad_scope.
(* end hide *)


(* ================================================================= *)
(** ** Simulation relations and invariants *)

(** The compiler is proved correct by constructing a (itree) bisimulation
    between the source program and its compilation.  The compiler does two
    things that affect the state:

      - it translates source Imp variables to Asm global variables, which should
        match at each step of computation

      - it introduces temporary local variables that name intermediate values

    As is traditional, we define, to this end, a simulation relation [Renv] and
    invariants that relate the source Imp environment to the target Asm
    environment, following the description above.
   
    [Renv] relates two [alist var value] environments if they act as 
    equivalent maps.  This is used to relate Imp's [ImpState] environment to
    Asm's [Memory].  

*)

Section Simulation_Relation.

  (** ** Definition of the simulation relations *)

  (** The simulation relation for evaluation of statements.
      The relation relates two environments of type [alist var value].
      The source and target environments exactly agree on user variables.
   *)
  Definition Renv (g_asm : memory) (g_imp : globals) : Prop :=
    forall k v, alist_In k g_imp v <-> alist_In k g_asm v.

  Global Instance Renv_refl : Reflexive Renv.
  Proof.
    red. intros. unfold Renv. tauto.
  Qed.    
  
 (** The simulation relation for evaluation of expressions.

     The relation connects 

       - the global state at the Imp level
          
       - the memory and register states at the Asm level

     and, additionally the returned value at the _Imp_ level. The _Asm_ side
     does not carry a [value], but a [unit], since its denotation does not
     return any [value].

     The [sim_rel] relation is parameterized by the state of the local [asm]
     environment before the step, and the name of the variable used to store the
     result.


     It enforces three conditions:
     - [Renv] on the global environments, ensuring that evaluation of expressions does
     not change user variables;

     - Agreement on the computed value, i.e. the returned value [v] is stored at
     the assembly level in the expected temporary;

     - The "stack" of temporaries used to compute intermediate results is left
       untouched.
  *) 
  Definition sim_rel l_asm n: (globals * value) -> (memory * (registers * unit)) -> Prop :=
    fun '(g_imp', v) '(g_asm', (l_asm', _))  =>
      Renv g_imp' g_asm' /\            (* we don't corrupt any of the imp variables *)
      alist_In n l_asm' v /\           (* we get the right value *)
      (forall m, m < n -> forall v,              (* we don't mess with anything on the "stack" *)
            alist_In m l_asm v <-> alist_In m l_asm' v).

  Lemma sim_rel_find : forall g_asm g_imp l_asm l_asm' n  v,
    sim_rel l_asm n (g_imp, v) (g_asm, (l_asm', tt)) ->
    alist_find n l_asm' = Some v.
  Proof.
    intros.
    destruct H as [_ [IN _]].
    apply IN.
  Qed.    

  (** ** Facts on the simulation relations *)
  
  (** [Renv] entails agreement of lookup of user variables. *)
  Lemma Renv_find:
    forall g_asm g_imp x,
      Renv g_imp g_asm ->
      alist_find x g_imp = alist_find x g_asm.
  Proof.
    intros.
    destruct (alist_find x g_imp) eqn:LUL, (alist_find x g_asm) eqn:LUR; auto.
    - eapply H in LUL.
      rewrite LUL in LUR; auto.
    - eapply H in LUL.
      rewrite LUL in LUR; auto.
    - eapply H in LUR.
      rewrite LUR in LUL; inv LUL.
  Qed.      

  (** [sim_rel] can be initialized from [Renv]. *)
  Lemma sim_rel_add: forall g_asm l_asm g_imp n v,
      Renv g_imp g_asm ->
      sim_rel l_asm n  (g_imp, v) (g_asm, (alist_add n v l_asm, tt)).
  Proof.
    intros.
    split; [| split].
    - assumption.
    - apply In_add_eq.
    - intros m LT v'.
      apply In_add_ineq_iff; lia.
  Qed.

  (** [Renv] can be recovered from [sim_rel]. *)
  Lemma sim_rel_Renv: forall l_asm n s1 l v1 s2 v2,
      sim_rel l_asm n (s2,v2) (s1,(l,v1)) -> Renv s2 s1 .
  Proof.
    intros ? ? ? ? ? ? ? H; apply H.
  Qed.

  Lemma sim_rel_find_tmp_n:
    forall l_asm g_asm' n l_asm' g_imp' v,
      sim_rel l_asm n  (g_imp',v) (g_asm', (l_asm', tt)) ->
      alist_In n l_asm' v.
  Proof.
    intros ? ? ? ? ? ? [_ [H _]]; exact H. 
  Qed.

  (** [sim_rel] entails agreement of lookups in the "stack" between its argument
      and the current Asm environement *)
  Lemma sim_rel_find_tmp_lt_n:
    forall l_asm g_asm' n m l_asm' g_imp' v,
      m < n ->
      sim_rel l_asm n (g_imp',v) (g_asm', (l_asm', tt)) ->
      alist_find m l_asm = alist_find m l_asm'.
  Proof.
    intros ? ? ? ? ? ? ? ineq [_ [_ H]].
    match goal with
    | |- _ = ?x => destruct x eqn:EQ
    end.
    setoid_rewrite (H _ ineq); auto.
    match goal with
    | |- ?x = _ => destruct x eqn:EQ'
    end; [| reflexivity].
    setoid_rewrite (H _ ineq) in EQ'.
    rewrite EQ' in EQ; easy.
  Qed.

  Lemma sim_rel_find_tmp_n_trans:
    forall l_asm n l_asm' l_asm'' g_asm' g_asm'' g_imp' g_imp'' v v',
      sim_rel l_asm n (g_imp',v) (g_asm', (l_asm', tt))  ->
      sim_rel l_asm' (S n) (g_imp'',v') (g_asm'', (l_asm'', tt))  ->
      alist_In n l_asm'' v.
  Proof.
    intros.
    generalize H; intros LU; apply sim_rel_find_tmp_n in LU.
    unfold alist_In in LU; erewrite sim_rel_find_tmp_lt_n in LU; eauto.
  Qed.

  (** [Renv] is preserved by assignment.
   *)
  Lemma Renv_write_local:
    forall (k : Imp.var) (g_asm g_imp : alist var value) v,
      Renv g_imp g_asm ->
      Renv (alist_add k v g_imp) (alist_add k v g_asm).
  Proof.
    intros k m m' v HRel k' v'.
    unfold alist_add, alist_In; simpl.
    flatten_goal;
      repeat match goal with
             | h: _ = true |- _ => rewrite rel_dec_correct in h
             | h: _ = false |- _ => rewrite <- neg_rel_dec_correct in h
             end; try subst.
    - tauto.
    - setoid_rewrite In_remove_In_ineq_iff; eauto using RelDec_string_Correct.
  Qed.

  (** [sim_rel] can be composed when proving binary arithmetic operators. *)
  Lemma sim_rel_binary_op:
    forall (l_asm l_asm' l_asm'' : registers) (g_asm' g_asm'' : memory) (g_imp' g_imp'' : globals)
      (n v v' : nat)
      (Hsim : sim_rel l_asm n (g_imp', v) (g_asm', (l_asm', tt)))
      (Hsim': sim_rel l_asm' (S n) (g_imp'', v') (g_asm'', (l_asm'', tt)))
      (op: nat -> nat -> nat),
      sim_rel l_asm n (g_imp'', op v v') (g_asm'', (alist_add n (op v v') l_asm'', tt)).
  Proof.
    intros.
    split; [| split].
    - eapply sim_rel_Renv; eassumption.
    - apply In_add_eq.
    - intros m LT v''.
      rewrite <- In_add_ineq_iff; [| lia].
      destruct Hsim as [_ [_ Hsim]].
      destruct Hsim' as [_ [_ Hsim']].
      rewrite Hsim; [| auto with arith].
      rewrite Hsim'; [| auto with arith].
      reflexivity.
  Qed.

End Simulation_Relation.

(* ================================================================= *)
(** ** Bisimulation *)

(** We now make precise the bisimulation established to show the correctness of
    the compiler.  Naturally, we cannot establish a _strong bisimulation_
    between the source program and the target program: the [asm] counterpart
    performs "more steps" when evaluating expressions.  The appropriate notion
    is of course the _equivalence up to tau_. However, the [itree] structures
    are also quite different.  [asm] programs manipulate two state
    components. The simulation will establish that the [imp] global state
    corresponds to the [asm] memory, but do establish that correspondence we
    also need to interpret the [asm] register effects.  *)

Section Bisimulation.

  
  (** Definition of our bisimulation relation.

      As previously explained, it relates (up-to-tau) two [itree]s after having
      interpreted their events.

      We additionally bake into it a simulation
      -  events are interpreted from related states.
      - Returned values must contain related states, as well as computed datas
      related by another relation [RR] taken in parameter.
      In our case, we specialize [RR] to equality since both trees return [unit],
      and [Renv_] to [Renv].
   *)
  (* SAZ: TODO - rename some of the variables here to make it clear what are environemnts, etc. 
     maybe rename a and b to use pattern binding: a == '(src_env, src_res)

     Annoyingly, using pattern matching here prevents lemmas like [eutt_interp_state_loop] 
     from applying because 
   *)

  Definition state_invariant {A B} (RAB: A -> B -> Prop) (a : Imp.globals * A) (b : Asm.memory * (Asm.registers * B))  :=
    Renv (fst a) (fst b) /\ (RAB (snd a) (snd (snd b))).
  
  Definition bisimilar {A B E} (RAB: A -> B -> Prop) (t1 : itree (ImpState +' E) A) (t2 : itree (Reg +' Memory +' E) B)  :=
    forall g_asm g_imp l,
      Renv g_imp g_asm ->
      eutt (state_invariant RAB)
           (interp_imp t1 g_imp)
           (interp_asm t2 g_asm l).
              
  (** [eq_locals] is compatible with [eutt]. *)

  Global Instance eutt_bisimilar  {A B E}  (RAB : A -> B -> Prop):
    Proper (eutt eq ==> eutt eq ==> iff) (@bisimilar A B E RAB).
  Proof.
    repeat intro.
    unfold bisimilar. split.
    - intros.
      rewrite <- H, <- H0. auto.
    - intros.
      rewrite H, H0. auto.
  Qed.

  Lemma bisimilar_bind' {A A' B C E} (RAA' : A -> A' -> Prop) (RBC: B -> C -> Prop):
    forall (t1 : itree (ImpState +' E) A) (t2 : itree (Reg +' Memory +' E) A') ,
      bisimilar RAA' t1 t2 ->
      forall (k1 : A -> itree (ImpState +' E) B) (k2 : A' -> itree (Reg +' Memory +' E) C) 
        (H: forall (a:A) (a':A'), RAA' a a' -> bisimilar RBC (k1 a) (k2 a')),
        bisimilar RBC (t1 >>= k1) (t2 >>= k2).
  Proof.
    repeat intro.
    rewrite interp_asm_bind.
    rewrite interp_imp_bind.
    eapply eutt_clo_bind.
    { eapply H; auto. }
    intros.
    destruct u1 as [? ?].
    destruct u2 as [? [? ?]]. 
    unfold state_invariant in H2.
    simpl in H2. destruct H2. subst.
    eapply H0; eauto.
  Qed.

  (* SAZ + LX: again, typeclass resolution doesn't find Aloop_itree.  Maybe universes get in the way? *)
  Notation loop' := (@loop _ _ (ALoop_itree) _ _ _).
    
  (** [eq_locals] is compatible with [loop]. *)

  (*
  Lemma bisimilar_loop {A B C E} x
        (t1 : C + A -> itree (ImpState +' E) (C + B)) 
        (t2 : C + A -> itree (Reg +' Memory +' E) (C + B)) :
    (forall l, bisimilar (t1 l) (t2 l)) ->
    bisimilar (loop' t1 x) (loop' t2 x).
  Proof.
    unfold bisimilar, interp_asm, interp_imp, run_map.
    intros.
    setoid_rewrite interp_loop.
    pose proof @interp_state_loop.
    red in H1.
    setoid_rewrite H1.
    pose proof @interp_state_loop2.
    red in H2.
    setoid_rewrite H2.
    unfold loop. cbn.
    unfold aloop. unfold ALoop_stateT0. unfold aloop. unfold ALoop_itree.
    eapply eutt_clo_bind.
    apply H. assumption.
    intros.
    eapply eutt_aloop' with (RI := state_invariant).
    2 : { destruct H3. red.  simpl. tauto. }
    
    intros.
    destruct H4. setoid_rewrite H5.
    destruct j2 as [m1 [m2 [a|a]]]; cbn.

    - constructor. eapply H. apply H4.
    - constructor. red. cbn in *. tauto.
*)

  Lemma interp_state_aloop' {E F } S (f : E ~> stateT S (itree F)) {I A}
      (t  : I -> itree E I + A)
  : forall i, state_eq (State.interp_state f (ITree.aloop t i))
                  (aloop (fun i => match t i with inl u => inl (State.interp_state f u) | inr a => inr a end) i).
  Proof.
    eapply interp_state_aloop.
    intros i.
    destruct (t i); constructor; auto. red.  intros.
    reflexivity.
  Qed.


  
  Lemma bisimilar_iter {E A A' B B'}
        (R : A -> A' -> Prop)
        (S : B -> B' -> Prop)
        (t1 : A -> itree (_ +' E) (A + B))
        (t2 : A' -> itree (_ +' _ +' E) (A' + B')) :
    (forall l l', R l l' -> bisimilar (sum_rel R S) (t1 l) (t2 l')) ->
    forall x x', R x x' ->
    bisimilar S (KTree.iter t1 x) (KTree.iter t2 x').
  Proof.
    
    unfold bisimilar, interp_asm, interp_imp, run_map.
    intros. rewrite 2 interp_iter.
    unfold KTree.iter, Iter_ktree.
    pose proof @interp_state_aloop'.
    red in H2.
    
    do 2 rewrite H2.
    unfold aloop, ALoop_stateT0, aloop, ALoop_itree .
    rewrite H2.
    eapply (eutt_aloop' (state_invariant (sum_rel R S))).
    intros.
    destruct H3. simpl.
    destruct H4.
    - constructor. apply H; auto.
    - constructor. constructor; auto.
    - split; auto. simpl. constructor; auto.
  Qed.

  (** [sim_rel] at [n] entails that [GetVar (gen_tmp n)] gets interpreted
      as returning the same value as the _Imp_ related one.
   *)
  Lemma sim_rel_get_tmp0:
    forall {E} n l l' g_asm g_imp v,
      sim_rel l' n (g_imp,v) (g_asm, (l,tt)) ->
      eutt eq (interp_asm ((trigger (GetReg n)) : itree (Reg +' Memory +' E) value)
                                       g_asm l)
           (Ret (g_asm, (l, v))).
  Proof.
    intros.
    
    unfold interp_asm.
    rewrite interp_trigger.
    rewrite tau_eutt.
    cbn.
    unfold run_map.
    unfold map_reg, CategoryOps.cat, Cat_Handler, Handler.cat. 
    unfold inl_, Inl_sum1_Handler, Handler.inl_, Handler.htrigger. cbn.
    unfold lookup_def; cbn.
    unfold embed, Embeddable_itree, Embeddable_forall, embed.
    rewrite interp_trigger.
    rewrite tau_eutt.
    rewrite interp_state_trigger.
    rewrite !tau_eutt.
    cbn.
    rewrite interp_state_ret.
    unfold lookup_default, lookup, Map_alist.
    erewrite sim_rel_find.
    reflexivity.
    apply H.
  Qed.
    

End Bisimulation.

(* ================================================================= *)
(** ** Linking *)

(** We first show that our "high level" [asm] combinators are correct.
    These proofs are mostly independent from the compiler, and therefore
    fairly reusable.
    Once again, these notion of correctness are expressed as equations
    commuting the denotation with the combinator.
 *)

Section Linking.

  (** [seq_asm] is denoted as the (horizontal) composition of denotations. *)
  Lemma seq_asm_correct {A B C} (ab : asm A B) (bc : asm B C) :
      denote_asm (seq_asm ab bc)
    ⩯ denote_asm ab >>> denote_asm bc.
  Proof.
    unfold seq_asm. 
    rewrite link_asm_correct, relabel_asm_correct, app_asm_correct.
    rewrite <- lift_sktree_id, cat_assoc.
    rewrite cat_id_r.
    rewrite sym_sktree_unfold.
    apply cat_from_loop.
  Qed.

  (** [if_asm] is denoted as the ktree first denoting the branching condition,
      then looking-up the appropriate variable and following with either denotation. *)
  (* This proof should be nicer. *)
  Lemma if_asm_correct {A} (e : list instr) (tp fp : asm 1 A) :
      denote_asm (if_asm e tp fp)
    ⩯ ((fun _ =>
         denote_list e ;;
         v <- trigger (GetReg tmp_if) ;;
         if v : value then denote_asm fp F1 else denote_asm tp F1) : sktree _ _ _).
  Proof.
    unfold if_asm.
    rewrite seq_asm_correct.
    unfold cond_asm.
    rewrite raw_asm_block_correct_lifted.
    rewrite relabel_asm_correct.
    intros ?.
    unfold CategoryOps.cat, Cat_sktree, CategoryOps.cat, Cat_Kleisli; simpl.
    rewrite denote_after.
    Local Opaque denote_asm.
    cbn.
    repeat setoid_rewrite bind_bind.
    apply eqit_bind; try reflexivity. intros _.
    apply eqit_bind; try reflexivity. intros [].

    - rewrite !bind_ret.
      setoid_rewrite (app_asm_correct tp fp _).
      setoid_rewrite bind_bind.
      unfold isum_suml, isum_sum, lift_ktree; cbn.
      rewrite bind_ret; cbn.
      rewrite bind_bind.
      rewrite <- (bind_ret2 (denote_asm fp F1)) at 2.
      eapply eqit_bind; [| reflexivity].
      intros ?.
      Local Opaque merge_fin_sum.
      rewrite 2 bind_ret; cbn.
      apply eqit_Ret.
      unfold merge. unfold id_, Id_iFun, id_, Id_Fun.
      unfold case_, case_isum, CategoryOps.cat, Cat_Fun, case_, case_sum, CoprodCase_Kleisli. cbn.
      setoid_rewrite (@iso_epi _ _ _ _ _ _ _ _ _ (@FinSumIso A A)).
      reflexivity.

    - rewrite !bind_ret.
      setoid_rewrite (app_asm_correct tp fp _).
      setoid_rewrite bind_bind.
      unfold isum_suml, isum_sum, lift_ktree; cbn.
      rewrite bind_ret; cbn.
      rewrite bind_bind.
      rewrite <- (bind_ret2 (denote_asm tp F1)) at 2.
      eapply eqit_bind; [| reflexivity].
      intros ?.
      Local Opaque merge_fin_sum.
      rewrite 2 bind_ret; cbn.
      apply eqit_Ret.
      unfold merge. unfold id_, Id_iFun, id_, Id_Fun.
      unfold case_, case_isum, CategoryOps.cat, Cat_Fun, case_, case_sum, CoprodCase_Kleisli. cbn.
      setoid_rewrite (@iso_epi _ _ _ _ _ _ _ _ _ (@FinSumIso A A)).
      reflexivity.
  Qed.


  (** [while_asm] is denoted as the loop of the body with two entry point, the exit
      of the loop, and the body in which we have the same structure as for the conditional *)
   Lemma while_asm_correct (e : list instr) (p : asm 1 1) :
      denote_asm (while_asm e p)
    ⩯ sloop (fun l: F (1 + 1) =>
         match l with
         | F1 =>
           denote_list e ;;
           v <- ITree.trigger (inl1 (GetReg tmp_if)) ;;
           if v : value then
             Ret (FS F1)
           else
             (denote_asm p F1;; Ret F1)
         | FS _ => Ret F1
         end).
  Proof.
    unfold while_asm.
    rewrite link_asm_correct.
    apply Proper_loop.
    rewrite relabel_asm_correct.
    rewrite <- lift_sktree_id, cat_id_l.
    rewrite app_asm_correct.
    rewrite if_asm_correct.
    intros x.
    unfold bimap, Bimap_Coproduct, Case_sktree, CoprodCase_Kleisli, case_, lift_sktree, isum_suml, case_sum, lift_sktree, lift_ktree, cat, Cat_sktree, cat, Cat_Kleisli; cbn.
    rewrite bind_ret.
    apply (caseS' x); cbn.
    - rewrite !bind_bind.
      eapply eutt_clo_bind; try reflexivity. intros; subst.
      rewrite bind_bind.
      eapply eutt_clo_bind; try reflexivity. intros; subst. destruct u0.
      + rewrite (pure_asm_correct _ _).
        unfold inl_, Inl_sktree, inl_, CoprodInl_Kleisli, sum_isuml, lift_sktree, lift_ktree, cat, Cat_Kleisli; cbn.
        rewrite !bind_ret.
        reflexivity.
      + rewrite (relabel_asm_correct _ _ _ _).
        unfold CategoryOps.cat, Cat_Kleisli.
        simpl; repeat setoid_rewrite bind_bind.
        unfold inl_, Inl_sktree, inl_, CoprodInl_Kleisli, sum_isuml, lift_sktree, lift_ktree, cat, Cat_Kleisli; cbn.
        rewrite bind_ret.
        eapply eutt_clo_bind; try reflexivity.
        intros ? ? []. rewrite (unique_F1 u1).
        repeat rewrite bind_ret. reflexivity.
    - intros k; rewrite (unique_F1 k).
      rewrite (pure_asm_correct _ _).
      unfold inr_, Inr_sktree, inr_, CoprodInr_Kleisli, inl_, Inl_sktree, inl_, CoprodInl_Kleisli, isum_inl, sum_isuml, lift_sktree, lift_ktree, cat, Cat_Kleisli; cbn.
      rewrite !bind_ret.
      reflexivity.
  Qed.

End Linking.

(* ================================================================= *)
(** ** Correctness *)

Section Correctness.


  (** Correctness of expressions.
      We strengthen [eq_locals]: initial environments are still related by [Renv],
      but intermediate ones must now satisfy [sim_rel].
      Note that by doing so, we use a _heterogeneous bisimulation_: the trees
      return values of different types ([alist var value * unit] for _Asm_,
      [alist var value * value] for _Imp_). The differeence is nonetheless mostly
      transparent for the user, except for the use of the more generale [eqit_bind'].
   *)
  Lemma compile_expr_correct : forall {E} e g_imp g_asm l n,
      Renv g_imp g_asm ->
      @eutt E _ _ (sim_rel l n)
            (interp_imp (denote_expr e) g_imp)
            (interp_asm (denote_list (compile_expr n e)) g_asm l).
(*
  Lemma compile_expr_correct : forall e g_imp g_asm n,
      Renv g_asm g_imp ->
      eutt (sim_rel g_asm n)
           (interp_locals (denote_list (compile_expr n e)) g_asm)
           (interp_locals (denoteExpr e) g_imp).
*)
  Proof.
    induction e; simpl; intros.
    - (* Var case *)
      (* We first compute and eliminate taus on both sides. *)

      tau_steps.

      (* We are left with [Ret] constructs on both sides, that remains to be related *)
      red; rewrite <-eqit_Ret.
      unfold lookup_default, lookup, Map_alist.
      
      (* On the _Asm_ side, we bind to [gen_tmp n] a lookup to [varOf v] *)
      (* On the _Imp_ side, we return the value of a lookup to [varOf v] *)
      erewrite Renv_find; [| eassumption].
      apply sim_rel_add; assumption.

    - (* Literal case *)
      (* We reduce both sides to Ret constructs *)
      tau_steps.

      red; rewrite <-eqit_Ret.
      (* _Asm_ bind the litteral to [gen_tmp n] while _Imp_ returns it *)
      apply sim_rel_add; assumption.

    (* The three binary operator cases are identical *)
    - (* Plus case *)
      (* We push [interp_locals] into the denotations *)

      do 2 setoid_rewrite denote_list_app.
      rewrite interp_asm_bind.
      rewrite interp_imp_bind.

      (* The Induction hypothesis on [e1] relates the first itrees *)
      eapply eutt_clo_bind.
      { eapply IHe1; assumption. }
      (* We obtain new related environments *)
      intros [g_imp' v] [g_asm' [l' []]] HSIM.
      (* The Induction hypothesis on [e2] relates the second itrees *)
      rewrite interp_asm_bind.
      rewrite interp_imp_bind.
      eapply eutt_clo_bind.
      { eapply IHe2.
        eapply sim_rel_Renv; eassumption. }
      (* And we once again get new related environments *)
      intros [g_imp'' v'] [g_asm'' [l'' []]] HSIM'.
      (* We can now reduce down to Ret constructs that remains to be related *)
      tau_steps.
      red. rewrite <- eqit_Ret.

      clear -HSIM HSIM'. unfold lookup_default, lookup, Map_alist.
      erewrite sim_rel_find_tmp_n_trans; eauto. 
      erewrite sim_rel_find_tmp_n; eauto. 
      eapply sim_rel_binary_op; eauto.

    - (* Sub case *)
      (* We push [interp_locals] into the denotations *)
      do 2 setoid_rewrite denote_list_app.
      rewrite interp_asm_bind.
      rewrite interp_imp_bind.

      (* The Induction hypothesis on [e1] relates the first itrees *)
      eapply eutt_clo_bind.
      { eapply IHe1; assumption. }
      (* We obtain new related environments *)
      intros [g_imp' v] [g_asm' [l' []]] HSIM.
      (* The Induction hypothesis on [e2] relates the second itrees *)
      rewrite interp_asm_bind.
      rewrite interp_imp_bind.
      eapply eutt_clo_bind.
      { eapply IHe2.
        eapply sim_rel_Renv; eassumption. }
      (* And we once again get new related environments *)
      intros [g_imp'' v'] [g_asm'' [l'' []]]  HSIM'.
      (* We can now reduce down to Ret constructs that remains to be related *)
      tau_steps.
      red. rewrite <- eqit_Ret.

      clear -HSIM HSIM'. unfold lookup_default, lookup, Map_alist.
      erewrite sim_rel_find_tmp_n_trans; eauto. 
      erewrite sim_rel_find_tmp_n; eauto. 
      eapply sim_rel_binary_op; eauto.

    - (* Mul case *)
      (* We push [interp_locals] into the denotations *)
      do 2 setoid_rewrite denote_list_app.
      rewrite interp_asm_bind.
      rewrite interp_imp_bind.

      (* The Induction hypothesis on [e1] relates the first itrees *)
      eapply eutt_clo_bind.
      { eapply IHe1; assumption. }
      (* We obtain new related environments *)
      intros [g_imp' v] [g_asm' [l' []]] HSIM.
      (* The Induction hypothesis on [e2] relates the second itrees *)
      rewrite interp_asm_bind.
      rewrite interp_imp_bind.
      eapply eutt_clo_bind.
      { eapply IHe2.
        eapply sim_rel_Renv; eassumption. }
      (* And we once again get new related environments *)
      intros [g_imp'' v'] [g_asm'' [l'' []]] HSIM'.
      (* We can now reduce down to Ret constructs that remains to be related *)
      tau_steps.
      red. rewrite <- eqit_Ret.

      clear -HSIM HSIM'. unfold lookup_default, lookup, Map_alist.
      erewrite sim_rel_find_tmp_n_trans; eauto. 
      erewrite sim_rel_find_tmp_n; eauto. 
      eapply sim_rel_binary_op; eauto.
  Qed.

  (** Correctness of the assign statement.
      The resulting list of instruction is denoted as
      denoting the expression followed by setting the variable.
   *)
  Lemma compile_assign_correct : forall {E} e x,
      bisimilar eq
        ((v <- denote_expr e ;; trigger (Imp.SetVar x v)) : itree (ImpState +' E) unit)
        ((denote_list (compile_assign x e)) : itree (Reg +' Memory +' E) unit).
  Proof.
    red; intros.
    unfold compile_assign.
    (* We push interpreters inside of the denotations *)
    rewrite denote_list_app.
    rewrite interp_asm_bind.
    rewrite interp_imp_bind.

    (* By correctness of the compilation of expressions,
       we can match the head trees.
     *)
    eapply eutt_clo_bind.
    { eapply compile_expr_correct; eauto. }

    (* Once again, we get related environments *)
    intros [g_imp' v]  [g_asm' [l' y]] HSIM.
    simpl in HSIM.
    
    (* We can now reduce to Ret constructs *)
    tau_steps.
    red. rewrite <- eqit_Ret.

    (* And remains to relate the results *)
    unfold state_invariant.
    unfold lookup_default, lookup, Map_alist.
    rewrite sim_rel_find_tmp_n; eauto; simpl.
    apply sim_rel_Renv in HSIM.
    split; auto.
    eapply Renv_write_local; eauto.
    eauto.
  Qed.


  (* The first parameter of [eq_locals] is useless for this development. We use to require equality,
 which carried not information since the return type was unit on both side.
 Now the return type is heterogeneous, [F 1] on one side and [unit] on the other.
   *)
  Definition TT {A B}: A -> B -> Prop  := fun _ _ => True.
  Hint Unfold TT.

  
  Definition equivalent (s:stmt) (t:asm 1 1) : Prop :=
    bisimilar TT (denote_stmt s) (denote_asm t F1).
  
  Opaque eutt.


  (* Utility: slight rephrasing of [while] to facilitate rewriting
     in the main theorem.*)
  Lemma while_is_loop {E} (body : itree E (unit+unit)) :
    while body
          ≈ KTree.iter (fun l : unit + unit =>
                    match l with
                    | inl _ => x <- body;; match x with inl _ => Ret (inl (inl tt)) | inr _ => Ret (inr tt) end
                    | inr _ => Ret (inl (inl tt))   (* Enter loop *)
                    end) (inr tt).
  Proof.
    unfold while.
    rewrite! unfold_iter_ktree.
    rewrite! tau_eutt.
    rewrite bind_ret.
    rewrite unfold_iter_ktree.
    rewrite! tau_eutt, bind_bind.
    eapply eutt_clo_bind. reflexivity.
    intros. subst.
    destruct u2 as [[]|[]].
    rewrite bind_ret.

    2 : {
      force_right. reflexivity.
    }
  Admitted.
  (* TODO: Fix this
    match goal with
    | [ |- _ (_ ?f _) (_ ?g _) ] =>
      epose proof (Proper_iter f g) as Hfg; apply Hfg; clear Hfg
    end.
    intros [[]|[]]; simpl; [| reflexivity].
    unfold ITree.map.
    eapply eutt_clo_bind; try reflexivity.
    intros; subst. destruct u2; reflexivity.
  Qed.
  *)

Definition to_itree' {E A} (f : sktree E 1 A) : itree E (F A) := f F1.
Lemma fold_to_itree' {E} (f : sktree E 1 1) : f F1 = to_itree' f.
Proof. reflexivity. Qed.

Global Instance Proper_to_itree' {E A} :
  Proper (eq2 ==> eutt eq) (@to_itree' E A).
Proof.
  repeat intro.
  apply H.
Qed.

Notation Inr_Kleisli := CoprodInr_Kleisli.

  (** Correctness of the compiler.
      After interpretation of the [Locals], the source _Imp_ statement
      denoted as an [itree] and the compiled _Asm_ program denoted
      as an [itree] are equivalent up-to-taus.
      The correctness is termination sensitive, but nonetheless a simple
      induction on statements.
      We only are left with reasoning about the functional correctness of
      the compiler, all control-flow related reasoning having been handled
      in isolation.
   *)
  Theorem compile_correct (s : stmt) :
    equivalent s (compile s).
  Proof.
    unfold equivalent.
    induction s.

    - (* Assign *)
      simpl.
      (* We push [denote_asm] inside of the combinators *)
      rewrite raw_asm_block_correct.
      rewrite denote_after.

      (* The head trees match by correctness of assign *)
      rewrite <- (bind_ret2 (ITree.bind (denote_expr e) _)).
      eapply bisimilar_bind'.
      { eapply compile_assign_correct; auto. }

      (* And remains to trivially relate the results *)
      
      intros []; simpl.
      repeat intro.
      force_left; force_right.
      Transparent eutt. red.      
      rewrite <- eqit_Ret; auto.
      unfold state_invariant; auto.

    - (* Seq *)
      (* We commute [denote_asm] with [seq_asm] *)
      rewrite fold_to_itree'; simpl.
      rewrite seq_asm_correct. unfold to_itree'.

      (* And the result is immediate by indcution hypothesis *)
      eapply bisimilar_bind'.
      { eassumption. }
      intros [] ? _. rewrite (unique_F1 a').
      eassumption.

    - (* If *)
      (* We commute [denote_asm] with [if_asm] *)
      rewrite fold_to_itree'. simpl.
      rewrite if_asm_correct.
      unfold to_itree'.

      (* We now need to line up the evaluation of the test,
         and eliminate them by correctness of [compile_expr] *)
      repeat intro.
      rewrite interp_asm_bind.
      rewrite interp_imp_bind.
      eapply eutt_clo_bind.
      { apply compile_expr_correct; auto. }

      (* We get in return [sim_rel] related environments *)
      intros [g_imp' v] [g_asm' [l' x]] HSIM.

      (* We know that interpreting [GetVar tmp_if] is eutt to [Ret (g_asm,v)] *)
      generalize HSIM; intros EQ.  eapply sim_rel_get_tmp0 in EQ.
      unfold tmp_if.
      rewrite interp_asm_bind.
      rewrite EQ; clear EQ.
      rewrite bind_ret_; simpl.

      (* We can weaken [sim_rel] down to [Renv] *)
      apply sim_rel_Renv in HSIM.
      (* And finally conclude in both cases *)
      destruct v; simpl; auto. 

    - (* While *)
      (* We commute [denote_asm] with [while_asm], and restructure the
         _Imp_ [loop] with [while_is_loop] *)
      simpl; rewrite fold_to_itree'.
      rewrite while_is_loop.
      rewrite while_asm_correct.
      Local Opaque denote_asm.

      unfold to_itree'.
      unfold sloop. unfold iter at 2.
      unfold Iter_sktree, Inr_sktree, Inr_Kleisli, inr_, sum_isuml, lift_ktree, cat, Cat_sktree, cat, Cat_Kleisli.
      simpl.
      rewrite 2 bind_ret.
      simpl. 
      eapply (bisimilar_iter (fun x x' => (x = inl tt /\ x' = F1) \/ (x = inr tt /\ x' = FS F1))).
      2: { auto. }
      (* The two cases correspond to entering the loop, or exiting it*)
      intros ? ? [[] | []]; subst; cbn.

      (* The exiting case is trivial *)
      2:{ repeat intro.
          force_left. force_right.
          red. rewrite <- eqit_Ret; auto.
          unfold state_invariant. simpl. auto.
      }


      (* We now need to line up the evaluation of the test,
         and eliminate them by correctness of [compile_expr] *)
      repeat intro.
      rewrite !interp_imp_bind.
      rewrite !interp_asm_bind.
      rewrite !bind_bind.

      eapply eutt_clo_bind.
      { apply compile_expr_correct; auto. }

      intros [g_imp' v] [g_asm' [l' x]] HSIM.
      rewrite !interp_asm_bind.
      rewrite !bind_bind.

      (* We know that interpreting [GetVar tmp_if] is eutt to [Ret (g_asm,v)] *)
      generalize HSIM; intros EQ. eapply sim_rel_get_tmp0 in EQ.
      unfold tmp_if.

      rewrite EQ; clear EQ.
      rewrite bind_ret_; simpl.

      (* We can weaken [sim_rel] down to [Renv] *)
      apply sim_rel_Renv in HSIM.
      (* And now consider both cases *)
      destruct v; simpl; auto.
      + (* The false case is trivial *)
        force_left; force_right.
        red. rewrite <- eqit_Ret.
        unfold state_invariant. simpl. auto.
      + (* In the true case, we line up the body of the loop to use the induction hypothesis *)
        rewrite !interp_asm_bind.
        rewrite !interp_imp_bind.
        rewrite !bind_bind.
        eapply eutt_clo_bind.
        { eapply IHs; auto. }
        intros [g_imp'' v''] [g_asm'' [l'' x']] [HSIM' ?].
        force_right; force_left.
        red; rewrite <- eqit_Ret; simpl; split; auto; constructor; auto.

    - (* Skip *)
      Local Transparent denote_asm.
      repeat intro.
      tau_steps.
      red. apply eqit_Ret.
      unfold state_invariant. simpl. auto.
  Qed.

End Correctness.

(* ================================================================= *)
(** ** Closing word. *)

(** Through this medium-sized exemple, we have seen how to use [itree]s to
    denote two languages, how to run them and how to prove correct a compiler
    between them both.
    We have emphasized that the theory of [ktree]s allowed us to decouple
    all reasoning about the control-flow from the proof of the compiler itself.
    The resulting proof is entirely structurally inductive and equational. In
    particular, we obtain a final theorem relating potentially infinite
    computations without having to write any cofixpoint.
    
    If this result is encouraging, one might always wonder how things scale.

    A first good sanity check is to extend the languages with a _Print_
    instruction.
    It requires to add a new event to the language and therefore makes the
    correctness theorem relate trees actually still containing events.
    This change, which a good exercise to try, turns out to be as
    straightforward as one would hope. The only new lemma needed is to show
    that [interp_locals] leaves the new [Print] event untouched.
    This extension can be found in the _tutorial-print_ branch.

    More importantly, our compiler is fairly stupid and inefficient: it creates
    blocks for each compiled statement! One would hope to easily write and
    prove an optimization coalescing elementary blocks together.
    This however raises for now a difficulty: our representation of labels as
    binary trees encoded in [Type] is so unstructured that introspection on
    [asm] programs is difficult.
    We might therefore need to change our representation of labels, for instance
    to a [Fin] type.
    But this change turns out to be more interesting that it might seem: it
    moves [bks] from [fun (A B: Type) => A -> block B] to
    [fun (A B: nat) => Fin.t A -> block (Fin.t B)].
    Correspondingly, their denotation moves from
    [fun (A B: Type) => bks A B -> ktree E A B]
    to [fun (A B: nat) => ktree E (Fin.t A) (Fin.t B)].
    But our proof crucially rested on the categorie [(Type, ktree E)] being
    provided by the [itree] library with a traced monoidal structure. We would
    therefore need to redo all the work to equip the category
    [(Nat, fun A B => ktree E (t A) (t B))] with the same structure, which is
    significant low level work. We might therefore want to investigate whether
    [ktree] should be generalized to something along the lines of
    [ktree (i : Type) (F : i -> Type) (E : Type -> Type) (a b : i) : Type := F a -> itree E (F b).]
 *)
