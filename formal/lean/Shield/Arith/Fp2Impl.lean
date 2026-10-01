import Shield.Arith.Goldilocks
import Shield.Field.Fp2

/-!
# `𝔽_{p²}` arithmetic as the contracts implement it

One-for-one models of `StarkFieldExt.add`, `sub`, `neg`, `mul`, `mulBase`, `conjugate`, `norm`,
`square`, `isZero`, `eq` and `inv` on the word pairs `Fp2 { c0; c1 }`, and the proof that each one
computes the corresponding operation of `𝔽_p[X]/(X² − 7)` (`Shield.Field.Fp2`) on canonical
inputs, with canonical outputs. The contracts have no separate Frobenius. `conjugate` is the Frobenius
(`conjugate_eq_frobenius`).
-/

namespace Shield.Arith

open Shield.Field QuadraticAlgebra

/-- The contracts' `StarkFieldExt.Fp2`: two words, `c0 + c1·X`. -/
structure W2 where
  c0 : ℕ
  c1 : ℕ

namespace W2

/-- Both words below `P`. -/
def Canon (a : W2) : Prop := a.c0 < P ∧ a.c1 < P

/-- The field element a canonical pair denotes. -/
def val (a : W2) : Fp2 := ⟨(a.c0 : Fp), (a.c1 : Fp)⟩

/-- `add`. -/
def add (a b : W2) : W2 := ⟨addmod a.c0 b.c0 P, addmod a.c1 b.c1 P⟩

/-- `sub`: `addmod(a.ci, P - b.ci, P)`. -/
def sub (a b : W2) : W2 := ⟨addmod a.c0 (P - b.c0) P, addmod a.c1 (P - b.c1) P⟩

/-- `neg`. -/
def neg (a : W2) : W2 := ⟨fpNeg a.c0, fpNeg a.c1⟩

/-- `mul`: `(ac + W·bd) + (ad + bc)X`, with `W = 7`. -/
def mul (a b : W2) : W2 :=
  let ac := mulmod a.c0 b.c0 P
  let bd := mulmod a.c1 b.c1 P
  let ad := mulmod a.c0 b.c1 P
  let bc := mulmod a.c1 b.c0 P
  ⟨addmod ac (mulmod 7 bd P) P, addmod ad bc P⟩

/-- `square`, which is `mul(a, a)`. -/
def square (a : W2) : W2 := mul a a

/-- `mulBase`. -/
def mulBase (a : W2) (s : ℕ) : W2 := ⟨mulmod a.c0 s P, mulmod a.c1 s P⟩

/-- `conjugate`: `(c0, fpNeg(c1))`. -/
def conjugate (a : W2) : W2 := ⟨a.c0, fpNeg a.c1⟩

/-- `norm`: `addmod(c0², P − mulmod(W, c1², P), P)`. -/
def norm (a : W2) : ℕ :=
  let c0sq := mulmod a.c0 a.c0 P
  let c1sq := mulmod a.c1 a.c1 P
  addmod c0sq (P - mulmod 7 c1sq P) P

/-- `isZero`. -/
def isZero (a : W2) : Bool := a.c0 == 0 && a.c1 == 0

/-- `eq`. -/
def eq (a b : W2) : Bool := a.c0 == b.c0 && a.c1 == b.c1

/-- `inv`: zero for zero, else `conjugate(a) · fpInv(norm(a))`. -/
def inv (a : W2) : W2 :=
  if a.isZero then ⟨0, 0⟩
  else
    let nInv := fpInv (norm a)
    let conj := conjugate a
    ⟨mulmod conj.c0 nInv P, mulmod conj.c1 nInv P⟩

/-! ### Canonical outputs -/

theorem add_canon (a b : W2) : (add a b).Canon := ⟨addmod_lt _ _, addmod_lt _ _⟩
theorem sub_canon (a b : W2) : (sub a b).Canon := ⟨addmod_lt _ _, addmod_lt _ _⟩
theorem mul_canon (a b : W2) : (mul a b).Canon := ⟨addmod_lt _ _, addmod_lt _ _⟩
theorem mulBase_canon (a : W2) (s : ℕ) : (mulBase a s).Canon := ⟨mulmod_lt _ _, mulmod_lt _ _⟩
theorem neg_canon {a : W2} (ha : a.Canon) : (neg a).Canon := ⟨fpNeg_lt ha.1, fpNeg_lt ha.2⟩
theorem conjugate_canon {a : W2} (ha : a.Canon) : (conjugate a).Canon := ⟨ha.1, fpNeg_lt ha.2⟩

theorem inv_canon (a : W2) : (inv a).Canon := by
  unfold inv; split_ifs
  · exact ⟨P_pos, P_pos⟩
  · exact ⟨mulmod_lt _ _, mulmod_lt _ _⟩

/-! ### Correctness -/

/-- On canonical pairs, `val` is injective: equal field elements have equal words. -/
theorem val_injective {a b : W2} (ha : a.Canon) (hb : b.Canon) (h : a.val = b.val) : a = b := by
  have h0 := congrArg QuadraticAlgebra.re h
  have h1 := congrArg QuadraticAlgebra.im h
  simp only [val] at h0 h1
  have e0 := congrArg ZMod.val h0
  have e1 := congrArg ZMod.val h1
  rw [ZMod.val_cast_of_lt ha.1, ZMod.val_cast_of_lt hb.1] at e0
  rw [ZMod.val_cast_of_lt ha.2, ZMod.val_cast_of_lt hb.2] at e1
  cases a; cases b; simp_all

/-- **`eq` decides field equality** on canonical pairs. -/
theorem eq_iff {a b : W2} (ha : a.Canon) (hb : b.Canon) : eq a b = true ↔ a.val = b.val := by
  constructor
  · intro h
    simp only [eq, Bool.and_eq_true, beq_iff_eq] at h
    simp [val, h.1, h.2]
  · intro h
    have := val_injective ha hb h
    simp [eq, this]

/-- **`isZero` decides `= 0`** on canonical pairs. -/
theorem isZero_iff {a : W2} (ha : a.Canon) : isZero a = true ↔ a.val = 0 := by
  have hz : (⟨0, 0⟩ : W2).val = 0 := by ext <;> simp [val]
  rw [← hz]
  constructor
  · intro h
    simp only [isZero, Bool.and_eq_true, beq_iff_eq] at h
    simp [val, h.1, h.2]
  · intro h
    have := val_injective ha ⟨P_pos, P_pos⟩ h
    simp [isZero, this]

/-- **`add` is field addition.** -/
theorem add_val (a b : W2) : (add a b).val = a.val + b.val := by
  ext <;> simp [add, val]

/-- **`sub` is field subtraction** (`b` canonical, so `P - b.ci` does not revert). -/
theorem sub_val (a : W2) {b : W2} (hb : b.Canon) : (sub a b).val = a.val - b.val := by
  ext <;> simp [sub, val, cast_P_sub hb.1.le, cast_P_sub hb.2.le, sub_eq_add_neg]

/-- **`neg` is field negation** on canonical pairs. -/
theorem neg_val {a : W2} (ha : a.Canon) : (neg a).val = -a.val := by
  ext <;> simp [neg, val, fpNeg_cast ha.1, fpNeg_cast ha.2]

/-- **`mul` is multiplication in `𝔽_p[X]/(X² − 7)`** (any words). -/
theorem mul_val (a b : W2) : (mul a b).val = a.val * b.val := by
  ext
  · simp [mul, val]; ring
  · simp [mul, val]

/-- **`square` is squaring.** -/
theorem square_val (a : W2) : (square a).val = a.val ^ 2 := by
  rw [square, mul_val, sq]

/-- **`mulBase` is scalar multiplication by a base-field element.** -/
theorem mulBase_val (a : W2) (s : ℕ) : (mulBase a s).val = a.val * algebraMap Fp Fp2 s := by
  ext <;> simp [mulBase, val]

/-- **`conjugate` is `star`** on canonical pairs. -/
theorem conjugate_val {a : W2} (ha : a.Canon) : (conjugate a).val = star a.val := by
  rw [star_eq]; ext <;> simp [conjugate, val, fpNeg_cast ha.2]

/-- **`conjugate` is the Frobenius** `z ↦ z^p` on canonical pairs. -/
theorem conjugate_eq_frobenius {a : W2} (ha : a.Canon) : (conjugate a).val = a.val ^ P := by
  rw [conjugate_val ha, frobenius_eq_star]

/-- **`norm` is `c0² − 7c1²`**, as a canonical word. -/
theorem norm_cast (a : W2) : (norm a : Fp) = (a.val.re) ^ 2 - 7 * (a.val.im) ^ 2 := by
  simp only [norm, cast_addmod, cast_P_sub (mulmod_lt _ _).le, cast_mulmod, val]
  push_cast; ring

theorem norm_lt (a : W2) : norm a < P := addmod_lt _ _

/-- **`inv` is field inversion** on canonical pairs, including `inv 0 = 0`. -/
theorem inv_val {a : W2} (ha : a.Canon) : (inv a).val = a.val⁻¹ := by
  unfold inv
  split_ifs with hz
  · rw [(isZero_iff ha).mp hz, inv_zero]; ext <;> simp [val]
  · rw [inv_eq]
    ext
    · simp only [val, conjugate, cast_mulmod, fpInv_cast, pow_P_sub_two, norm_cast]
      simp [div_eq_mul_inv]
    · simp only [val, conjugate, cast_mulmod, fpInv_cast, pow_P_sub_two, norm_cast,
        fpNeg_cast ha.2]
      simp [div_eq_mul_inv]

end W2

end Shield.Arith
