Require Import ZArith.
Require Import List.
Import ListNotations. 

Require Import TMUInstr.
Require Import Lattices.
Require Import CodeGen.

(* Lattice-dependent parameters *)
Class ConcreteLattice (T: Type) :=
{ labToZ :  T -> Z
; ZToLab :  Z -> T
; genJoin : list (@Instr T)
; genFlows : list (@Instr T)
}.

Require Import LatticeHL. 
Local Open Scope Z_scope. 

Instance TMUHL : ConcreteLattice Lab :=
{
  labToZ l :=
    match l with
      | L => 0
      | H => 1
    end
 
  ;ZToLab z :=
    match z with
      | 0 => L
      | _ => H
    end

  ;genJoin := 
    ifNZ (pop ++ push' 1) nop  (* same as genOr *)

  ;genFlows := (* l1 is on top of stack, l2 underneath *)
    ifNZ nop (pop ++ genTrue) (* punning in true branch *)
}.



(*
Module HL : TMULattice.  
(* Here are possible instantiations of lattice-dependent parameters for HL Lattice *)

  Require Import LatticeHL. 

  Local Open Scope Z_scope. 

  Definition labToZ (l:Lab) : Z :=
    match l with
      | L => 0
      | H => 1
    end.
 
  Definition ZToLab (z:Z) : Lab :=
    match z with
      | 0 => L
      | _ => H
    end.

  Definition T := Lab. 
  Definition Latt := HL. 

  Definition handlerLabel := H. 

  Definition pop := (@BranchNZ T) 1. 
  Definition push v := Push (v,handlerLabel).
  Definition branch ofs := 
  [push 1;
   BranchNZ (if ofs >=? 0 then ofs else ofs - 1 )]. 

  Definition genJoin :=
    [BranchNZ 3] ++
    branch 3 ++  (* length 2 *)
    [pop;
     push 1].

  Definition genFlows := (* l2 is on top of stack, l1 underneath *)
    [BranchNZ 2;
     BranchNZ 4;
     push 1] ++
     branch 2 ++ (* length 2 *)
     [push 0].
End HL. 

Module TMUHL := TMU(HL). 
*)