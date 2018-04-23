Require Import ZArith List String Omega.
Require Import Vellvm.LLVMAst Vellvm.Classes Vellvm.Util.
Require Import Vellvm.StepSemantics Vellvm.LLVMIO Vellvm.LLVMBaseTypes.
Require Import FSets.FMapAVL.
Require Import Integers.
Require Coq.Structures.OrderedTypeEx.
Require Import ZMicromega.
Import ListNotations.

Set Implicit Arguments.
Set Contextual Implicit.

Module A : Vellvm.LLVMIO.ADDR with Definition addr := (Z * Z) % type.
  Definition addr := (Z * Z) % type.
  Definition null := (0, 0).
End A.

Definition addr := A.addr.

Module SS := StepSemantics.StepSemantics(A).
Export SS.
Export SS.DV.

Module IM := FMapAVL.Make(Coq.Structures.OrderedTypeEx.Z_as_OT).
Definition IntMap := IM.t.

Definition add {a} k (v:a) := IM.add k v.
Definition delete {a} k (m:IntMap a) := IM.remove k m.
Definition member {a} k (m:IntMap a) := IM.mem k m.
Definition lookup {a} k (m:IntMap a) := IM.find k m.
Definition empty {a} := @IM.empty a.

Fixpoint add_all {a} ks (m:IntMap a) :=
  match ks with
  | [] => m
  | (k,v) :: tl => add k v (add_all tl m)
  end.

Fixpoint add_all_index {a} vs (i:Z) (m:IntMap a) :=
  match vs with
  | [] => m
  | v :: tl => add i v (add_all_index tl (i+1) m)
  end.

(* Give back a list of values from i to (i + sz) - 1 in m. *)
(* Uses def as the default value if a lookup failed. *)
Definition lookup_all_index {a} (i:Z) (sz:Z) (m:IntMap a) (def:a) : list a :=
  map (fun x =>
         let x' := lookup (Z.of_nat x) m in
         match x' with
         | None => def
         | Some val => val
         end) (seq (Z.to_nat i) (Z.to_nat sz)).

Definition union {a} (m1 : IntMap a) (m2 : IntMap a)
  := IM.map2 (fun mx my =>
                match mx with | Some x => Some x | None => my end) m1 m2.

Definition size {a} (m : IM.t a) : Z := Z.of_nat (IM.cardinal m).

(* TODO: replace Coq byte with CompCert's int8 *)

Inductive SByte :=
| Byte : byte -> SByte
| Ptr : addr -> SByte
| PtrFrag : SByte
| SUndef : SByte.

Definition mem_block := IntMap SByte.
Definition memory := IntMap mem_block.
Definition undef t := DVALUE_Undef t None. (* TODO: should this be an empty block? *)

(* Computes the byte size of this type. *)
Fixpoint sizeof_typ (ty:typ) : Z :=
  match ty with
  | TYPE_I sz => 8 (* All integers are padded to 8 bytes. *)
  | TYPE_Pointer t => 8
  | TYPE_Struct l => fold_left (fun x acc => x + sizeof_typ acc) l 0
  | TYPE_Array sz ty' => sz * sizeof_typ ty'
  | _ => 0 (* TODO: add support for more types as necessary *)
  end.

(* Should be Int8.repr or something like it. *)

Definition byte_of (_ _ _ _ _ _ _ _:Z) : byte := Byte.zero.

Fixpoint one_bits_to_bytes (l:list Z) : list SByte :=
  match l with
  | b0::b1::b2::b3::b4::b5::b6::b7::r =>
    let bs := one_bits_to_bytes r in
    (Byte (byte_of b0 b1 b2 b3 b4 b5 b6 b7))::bs
  | r => []
  end.

(* Convert integer to its SByte representation. *)
Definition Z_to_sbyte_list (z:Z) : list SByte :=
  one_bits_to_bytes (Int64.Z_one_bits 64 z 8).

Fixpoint bytes_to_one_bits (l:list SByte) : list Z :=
  match l with
  | (Byte b)::tl =>
    Int64.Z_one_bits 8 (Byte.unsigned b) 0 ++ bytes_to_one_bits tl 
  | _ => [] (* error *)
  end.

(* Converts SBytes into their integer representation. *)
Definition sbyte_list_to_Z (bytes:list SByte) : Z :=
  Int64.powerserie (bytes_to_one_bits bytes).

(* Serializes a dvalue into its SByte-sensitive form. *)
Fixpoint serialize_dvalue (dval:dvalue) : list SByte :=
  match dval with
  | DVALUE_Addr addr => (Ptr addr) :: (repeat PtrFrag 7)
  | DVALUE_I1 i => Z_to_sbyte_list (Int1.unsigned i)
  | DVALUE_I32 i => Z_to_sbyte_list (Int32.unsigned i)
  | DVALUE_I64 i => Z_to_sbyte_list (Int64.unsigned i)
  | DVALUE_Struct fields | DVALUE_Array fields =>
      (* note the _right_ fold is necessary for byte ordering. *)
      fold_right (fun '(typ, dv) acc => ((serialize_dvalue dv) ++ acc) % list) [] fields
  | _ => [] (* TODO add more dvalues as necessary *)
  end.

(* Deserialize a list of SBytes into a dvalue. *)
Fixpoint deserialize_sbytes (bytes:list SByte) (t:typ) : dvalue :=
  match t with
  | TYPE_I sz =>
    let des_int := sbyte_list_to_Z bytes in
    match sz with
    | 1 => DVALUE_I1 (Int1.repr des_int)
    | 32 => DVALUE_I32 (Int32.repr des_int)
    | 64 => DVALUE_I64 (Int64.repr des_int)
    | _ => DVALUE_None (* invalid size. *)
    end
  | TYPE_Pointer t' =>
    match bytes with
    | Ptr addr :: tl => DVALUE_Addr addr
    | _ => DVALUE_None (* invalid pointer. *)
    end
  | TYPE_Array sz t' =>
    let fix array_parse count byte_sz bytes :=
        match count with
        | O => []
        | S n => (t', deserialize_sbytes (firstn byte_sz bytes) t')
                   :: array_parse n byte_sz (skipn byte_sz bytes)
        end in
    DVALUE_Array (array_parse (Z.to_nat sz) (Z.to_nat (sizeof_typ t')) bytes)
  | TYPE_Struct fields =>
    let fix struct_parse typ_list bytes :=
        match typ_list with
        | [] => []
        | t :: tl =>
          let size_ty := Z.to_nat (sizeof_typ t) in
          (t, deserialize_sbytes (firstn size_ty bytes) t)
            :: struct_parse tl (skipn size_ty bytes)
        end in
    DVALUE_Struct (struct_parse fields bytes)
  | _ => DVALUE_None (* TODO add more as serialization support increases *)
  end.

(* Construct block indexed from 0 to n. *)
Fixpoint init_block_h (n:nat) (m:mem_block) : mem_block :=
  match n with
  | O => add 0 SUndef m
  | S n' => add (Z.of_nat n) SUndef (init_block_h n' m)
  end.

(* Initializes a block of n 0-bytes. *)
Definition init_block (n:Z) : mem_block :=
  match n with
  | 0 => empty
  | Z.pos n' => init_block_h (BinPosDef.Pos.to_nat (n' - 1)) empty
  | Z.neg _ => empty (* invalid argument *)
  end.

(* Makes a block appropriately sized for the given type. *)
Definition make_empty_block (ty:typ) : mem_block :=
  init_block (sizeof_typ ty).

Definition mem_step {X} (e:IO X) (m:memory) : (IO X) + (memory * X) :=
  match e with
  | Alloca t =>
    let new_block := make_empty_block t in
    inr  (add (size m) new_block m,
          DVALUE_Addr (size m, 0))
         
  | Load t dv =>
    match dv with
    | DVALUE_Addr a =>
      match a with
      | (b, i) =>
        match lookup b m with
        | Some block =>
          inr (m,
               deserialize_sbytes (lookup_all_index i (sizeof_typ t) block SUndef) t)
        | None => inl (Load t dv)
        end
      end
    | _ => inl (Load t dv)
    end 

  | Store dv v =>
    match dv with
    | DVALUE_Addr a =>
      match a with
      | (b, i) =>
        match lookup b m with
        | Some m' =>
          inr (add b (add_all_index (serialize_dvalue v) i m') m, ()) 
        | None => inl (Store dv v)
        end
      end
    | _ => inl (Store dv v)
    end
      
  | GEP t dv vs =>
    (* Index into a structured data type. *)
    let index_into_type typ index :=
        match typ with
        | TYPE_Array sz ty =>
          if sz <=? index then None else
            Some (ty, index * (sizeof_typ ty))
        | TYPE_Struct fields =>
          let new_typ := List.nth_error fields (Z.to_nat index) in
          match new_typ with
          | Some new_typ' =>
            (* Compute the byte-offset induced by the first i elements of the struct. *)
            let fix compute_offset typ_list i :=
                match typ_list with
                | [] => 0
                | hd :: tl =>
                  if i <? index
                  then sizeof_typ hd + compute_offset tl (i + 1)
                  else 0
                end
              in
            Some (new_typ', compute_offset fields 0)
          | None => None
          end
        | _ => None (* add type support as necessary *)
        end
    in
    (* Give back the final byte-offset into mem_bytes *)
    let fix gep_helper mem_bytes cur_type offsets offset_acc :=
        match offsets with
        | [] => offset_acc
        | dval :: tl =>
          match dval with
          | DVALUE_I32 x =>
            let nat_index := Int32.unsigned x in
            let new_typ_info := index_into_type cur_type nat_index in
            match new_typ_info with
              | Some (new_typ, offset) => 
                gep_helper mem_bytes new_typ tl (offset_acc + offset)
              | None => 0 (* fail *)
            end
          | _ => 0 (* fail, at least until supporting non-i32 indexes *)
          end
        end
    in
    match dv with
    | DVALUE_Addr a =>
      match a with
      | (b, i) =>
        match lookup b m with
        | Some block =>
          let mem_val := lookup_all_index i (sizeof_typ t) block SUndef in
          let answer := gep_helper mem_val t vs 0 in
          inr (m, DVALUE_Addr (b, i + answer))
        | None => inl (GEP t dv vs)
        end
      end
    | _ => inl (GEP t dv vs)
    end
  | ItoP t i => inl (ItoP t i) (* TODO: ItoP semantics *)

  | PtoI t a => inl (PtoI t a) (* TODO: ItoP semantics *)                     
                       
  | Call t f args  => inl (Call t f args)

                         
  | DeclareFun f =>
    (* TODO: should check for re-declarations and maintain that state in the memory *)
    inr (m,
         DVALUE_FunPtr f)
  end.

(*
 memory -> TraceLLVMIO () -> TraceX86IO () -> Prop
*)

CoFixpoint memD {X} (m:memory) (d:Trace X) : Trace X :=
  match d with
  | Trace.Tau d'            => Trace.Tau (memD m d')
  | Trace.Vis _ io k =>
    match mem_step io m with
    | inr (m', v) => Trace.Tau (memD m' (k v))
    | inl e => Trace.Vis io k
    end
  | Trace.Ret x => d
  | Trace.Err x => d
  end.


Definition run_with_memory prog : option (Trace dvalue) :=
  let scfg := AstLib.modul_of_toplevel_entities prog in
  match CFG.mcfg_of_modul scfg with
  | None => None
  | Some mcfg =>
    mret
      (memD empty
      ('s <- SS.init_state mcfg "main";
         SS.step_sem mcfg (SS.Step s)))
  end.

(*
Fixpoint MemDFin (m:memory) (d:Trace ()) (steps:nat) : option memory :=
  match steps with
  | O => None
  | S x =>
    match d with
    | Vis (Fin d) => Some m
    | Vis (Err s) => None
    | Tau _ d' => MemDFin m d' x
    | Vis (Eff e)  =>
      match mem_step e m with
      | inr (m', v, k) => MemDFin m' (k v) x
      | inl _ => None
      end
    end
  end%N.
*)

(*
Previous bug: 
Fixpoint MemDFin {A} (memory:mtype) (d:Obs A) (steps:nat) : option mtype :=
  match steps with
  | O => None
  | S x =>
    match d with
    | Ret a => None
    | Fin d => Some memory
    | Err s => None
    | Tau d' => MemDFin memory d' x
    | Eff (Alloca t k)  => MemDFin (memory ++ [undef])%list (k (DVALUE_Addr (pred (List.length memory)))) x
    | Eff (Load a k)    => MemDFin memory (k (nth_default undef memory a)) x
    | Eff (Store a v k) => MemDFin (replace memory a v) k x
    | Eff (Call d ds k)    => None
    end
  end%N.
*)
