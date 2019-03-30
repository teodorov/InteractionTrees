
(* begin hide *)
From Coq Require Import
     Setoid
     Morphisms
     RelationClasses.

From Paco Require Import paco.

From ITree Require Import
     Basics.Basics
     Basics.Category
     Core.ITreeDefinition
     Eq.UpToTausEquivalence
     Indexed.Sum
     Interp.Interp
     Interp.Handler
     Interp.TranslateFacts
     Interp.InterpFacts.

Import ITree.Basics.Basics.Monads.
Import ITreeNotations.

Open Scope itree_scope.

(* end hide *)

Lemma eh_cmp_id_left_strong {A R} (t : itree A R)
  : interp (id_ A) t ≈ t.
Proof.
  revert t. gstep. gcofix CIH. intros.
  rewrite unfold_interp. rewrite (itree_eta t) at 2.
  destruct (observe t); simpl; try (gstep; constructor; eauto with paco; fail).
  unfold id_, Id_Handler, Handler.id_, ITree.send. rewrite bind_vis_.
  gstep. do 2 constructor.
  right; rewrite bind_ret; auto with paco.
Qed.

Instance CatIdR_Handler : CatIdR Handler.
Proof.
  red; intros A B f X e.
  apply eh_cmp_id_left_strong.
Qed.

Instance CatIdL_Handler : CatIdL Handler.
Proof.
  red; intros A B f X e.
  unfold cat, Cat_Handler, Handler.cat, id_, Id_Handler, Handler.id_.
  rewrite interp_send, tau_eutt.
  reflexivity.
Qed.

Instance CatAssoc_Handler : CatAssoc Handler.
Proof.
  red; intros A B C D f g h X e.
  unfold cat, Cat_Handler, Handler.cat.
  rewrite interp_interp.
  reflexivity.
Qed.
