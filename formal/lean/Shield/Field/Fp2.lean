import Shield.Field.Basic
import Mathlib.Algebra.QuadraticAlgebra.Basic
import Mathlib.FieldTheory.KummerPolynomial
import Mathlib.RingTheory.AdjoinRoot

/-!
# The quadratic extension `𝔽_{p²} = 𝔽_p[X]/(X² − 7)`

`Fp2` is Mathlib's `QuadraticAlgebra Fp 7 0`: pairs `⟨c0, c1⟩` read as `c0 + c1·ω` with `ω² = 7`,
which is the contracts' `StarkFieldExt.Fp2 { c0; c1 }`. Its `Field` instance comes from
`seven_not_square`. The file proves that `X² − 7` is irreducible, that `Fp2` is isomorphic as an
`𝔽_p`-algebra to `AdjoinRoot (X² − 7)`, that inversion is the conjugate over the norm, and that the
conjugate is the Frobenius `z ↦ z^p`.
-/

namespace Shield.Field

open Polynomial QuadraticAlgebra

/-- `𝔽_{p²}`, elements `⟨c0, c1⟩ = c0 + c1·ω`, `ω² = 7`. -/
abbrev Fp2 : Type := QuadraticAlgebra Fp 7 0

/-- The generator `ω` (the contracts' `X`). -/
abbrev omega2 : Fp2 := QuadraticAlgebra.omega

/-- **`X² − 7` is irreducible over `𝔽_p`.** -/
theorem irreducible_X_sq_sub_seven : Irreducible (X ^ 2 - C 7 : Fp[X]) :=
  X_pow_sub_C_irreducible_of_prime Nat.prime_two fun b hb ↦
    seven_not_square ⟨b, by rw [← hb, sq]⟩

instance : Fact (Irreducible (X ^ 2 - C 7 : Fp[X])) := ⟨irreducible_X_sq_sub_seven⟩

/-- `𝔽_p[X]/(X² − 7)` is a field (Mathlib's `AdjoinRoot` field instance). -/
noncomputable example : Field (AdjoinRoot (X ^ 2 - C 7 : Fp[X])) := inferInstance

/-- `Fp2` is a field. -/
example : Field Fp2 := inferInstance

private theorem root_sq :
    AdjoinRoot.root (X ^ 2 - C 7 : Fp[X]) * AdjoinRoot.root (X ^ 2 - C 7) =
      (7 : Fp) • 1 + (0 : Fp) • AdjoinRoot.root (X ^ 2 - C 7) := by
  have h := AdjoinRoot.eval₂_root (X ^ 2 - C 7 : Fp[X])
  simp only [eval₂_sub, eval₂_X_pow, eval₂_C] at h
  rw [zero_smul, add_zero, Algebra.smul_def, mul_one, ← sq]
  exact sub_eq_zero.mp h

/-- The `𝔽_p`-algebra map `Fp2 → 𝔽_p[X]/(X² − 7)` sending `ω` to the class of `X`. -/
noncomputable def toAdjoinRoot : Fp2 →ₐ[Fp] AdjoinRoot (X ^ 2 - C 7 : Fp[X]) :=
  QuadraticAlgebra.lift ⟨_, root_sq⟩

/-- **`Fp2 ≃ 𝔽_p[X]/(X² − 7)`** as `𝔽_p`-algebras, with `ω ↦ X`. -/
noncomputable def equivAdjoinRoot : Fp2 ≃ₐ[Fp] AdjoinRoot (X ^ 2 - C 7 : Fp[X]) :=
  AlgEquiv.ofBijective toAdjoinRoot
    ⟨toAdjoinRoot.toRingHom.injective,
      (QuadraticAlgebra.lift_surjective_iff root_sq).mpr (AdjoinRoot.adjoinRoot_eq_top)⟩

theorem equivAdjoinRoot_omega :
    equivAdjoinRoot omega2 = AdjoinRoot.root (X ^ 2 - C 7 : Fp[X]) := by
  simp [equivAdjoinRoot, toAdjoinRoot]

/-- The norm `N(a + bω) = a² − 7b²`. -/
theorem norm_eq (z : Fp2) : QuadraticAlgebra.norm z = z.re ^ 2 - 7 * z.im ^ 2 := by
  rw [norm_def]; ring

/-- The norm vanishes only at zero. -/
theorem norm_ne_zero {z : Fp2} (hz : z ≠ 0) : z.re ^ 2 - 7 * z.im ^ 2 ≠ 0 := by
  rw [← norm_eq]; exact fun h ↦ hz (norm_eq_zero_iff_eq_zero.mp h)

/-- **The inversion formula** `(a + bω)⁻¹ = (a − bω)/(a² − 7b²)`, for every `z`. At `z = 0` both
sides are `0`, which is also what `StarkFieldExt.inv` returns. -/
theorem inv_eq (z : Fp2) :
    z⁻¹ = ⟨z.re / (z.re ^ 2 - 7 * z.im ^ 2), -z.im / (z.re ^ 2 - 7 * z.im ^ 2)⟩ := by
  rw [inv_def, norm_eq]
  ext <;> simp [re_star, im_star, div_eq_inv_mul]

/-- The formula is a two-sided inverse on nonzero elements. -/
theorem mul_inv_formula {z : Fp2} (hz : z ≠ 0) :
    z * ⟨z.re / (z.re ^ 2 - 7 * z.im ^ 2), -z.im / (z.re ^ 2 - 7 * z.im ^ 2)⟩ = 1 := by
  rw [← inv_eq]; exact mul_inv_cancel₀ hz

/-- The conjugate `a + bω ↦ a − bω`. -/
theorem star_eq (z : Fp2) : star z = ⟨z.re, -z.im⟩ := by
  ext <;> simp [re_star, im_star]

instance : CharP Fp2 P :=
  charP_of_injective_algebraMap (algebraMap Fp Fp2).injective P

/-- `ω^p = −ω`, because `7^((p−1)/2) = −1`. -/
theorem omega_pow_P : omega2 ^ P = -omega2 := by
  have hP : P = 2 * (P / 2) + 1 := by norm_num [P]
  have hsq : omega2 ^ 2 = algebraMap Fp Fp2 7 := by
    ext <;> simp [sq, QuadraticAlgebra.algebraMap_eq]
  calc omega2 ^ P = omega2 ^ (2 * (P / 2) + 1) := congrArg (omega2 ^ ·) hP
    _ = -omega2 := by
      rw [pow_succ, pow_mul, hsq, ← map_pow, seven_pow_half, map_neg, map_one, neg_one_mul]

/-- **The conjugate is the Frobenius**: `z^p = a − bω` for `z = a + bω`. -/
theorem frobenius_eq_star (z : Fp2) : z ^ P = star z := by
  have hz : z = algebraMap Fp Fp2 z.re + z.im • omega2 := by
    ext <;> simp [QuadraticAlgebra.algebraMap_eq]
  have hr : ∀ r : Fp, (algebraMap Fp Fp2 r) ^ P = algebraMap Fp Fp2 r := fun r ↦ by
    rw [← map_pow, ZMod.pow_card]
  conv_lhs => rw [hz]
  rw [add_pow_char, hr, smul_pow, ZMod.pow_card, omega_pow_P, star_eq]
  ext <;> simp [QuadraticAlgebra.algebraMap_eq]

end Shield.Field
