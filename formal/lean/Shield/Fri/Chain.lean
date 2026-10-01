import Shield.Arith.Goldilocks

/-!
# Chained inverses of the FRI evaluation points

`RealQueryVerify._verifyFriQuad` inverts once per query. At layer `m` the quad containing the
query sits at index `i_m = pos mod q_m`, `q_m = (n / 4^m) / 4`, and its four points are
`x_m · ζ^j` with `x_m = (s · ω^{i_m})^{4^m}` and `ζ = ω^{n/4}`. The contract keeps `ix = 1/x_m`
and `izeta = ζ^3`, passes `ix · izeta` as `1/(x_m ζ)`, and moves to the next layer by
`_ixStep`: `ix ← ix^4 · izeta^{4-k}` (no factor when `k = 0`), where `k = i_{m-1} / q_m`.

The file proves the three facts that make this correct, in any field and for the word-level
`_ixStep`:

* `inv_mul_zeta`: `1/(x ζ) = (1/x) · ζ^{-1}`, and `zeta_inv_eq_cube`: `ζ^{-1} = ζ^3` when `ζ^4 = 1`.
* `inv_pow_four`: `inv(x^4) = inv(x)^4`.
* `next_point` and `ixStep_spec`: the step computes `1/x_m` from `1/x_{m-1}`.
-/

namespace Shield.Fri

open Shield.Field Shield.Arith

section Field

variable {K : Type*} [Field K]

/-- The next point of a quad: `x₁ = x₀ ζ ⇒ 1/x₁ = (1/x₀) ζ⁻¹`. -/
theorem inv_mul_zeta (x₀ ζ : K) : (x₀ * ζ)⁻¹ = x₀⁻¹ * ζ⁻¹ := mul_inv x₀ ζ

/-- For a fourth root of unity, `ζ⁻¹ = ζ³` (the contract's `izeta = z·z·z`). -/
theorem zeta_inv_eq_cube {ζ : K} (h4 : ζ ^ 4 = 1) : ζ⁻¹ = ζ ^ 3 := by
  refine (eq_inv_of_mul_eq_one_left ?_).symm
  rw [← pow_succ, h4]

/-- **Inversion commutes with the fourth power**: `inv(x⁴) = inv(x)⁴`. -/
theorem inv_pow_four (x : K) : (x ^ 4)⁻¹ = x⁻¹ ^ 4 := (inv_pow x 4).symm

/-- **The layer relation.** If the index at layer `m` is `i + k q` and `q · 4^{m+1} = n/4`, then
the fourth power of layer `m`'s point is layer `m + 1`'s point times `ζ^k`, `ζ = ω^{q·4^{m+1}}`. -/
theorem next_point (s ω : K) (i k q m : ℕ) :
    ((s * ω ^ (i + k * q)) ^ 4 ^ m) ^ 4 =
      (s * ω ^ i) ^ 4 ^ (m + 1) * (ω ^ (q * 4 ^ (m + 1))) ^ k := by
  rw [← pow_mul, ← pow_succ]
  ring

/-- `ζ^k = (ζ⁻¹)^{4-k}` for a fourth root of unity and `k ≤ 4`. -/
theorem zeta_pow_eq_inv_pow {ζ : K} (h4 : ζ ^ 4 = 1) {k : ℕ} (hk : k ≤ 4) :
    ζ ^ k = ζ⁻¹ ^ (4 - k) := by
  have hζ : ζ ≠ 0 := by rintro rfl; simp at h4
  rw [inv_pow]
  refine eq_inv_of_mul_eq_one_left ?_
  rw [← pow_add, Nat.add_sub_cancel' hk, h4]

/-- **One step of the chain, in the field.** If `x'^4 = x ζ^k` with `ζ^4 = 1` and `k < 4`, then
`1/x = (1/x')^4 · (ζ⁻¹)^{4-k}` for `k ≠ 0`, and `1/x = (1/x')^4` for `k = 0`. -/
theorem inv_step {x x' ζ : K} {k : ℕ} (h4 : ζ ^ 4 = 1) (hk : k < 4)
    (hx : x' ^ 4 = x * ζ ^ k) :
    x⁻¹ = if k = 0 then x'⁻¹ ^ 4 else x'⁻¹ ^ 4 * ζ⁻¹ ^ (4 - k) := by
  have hζ : ζ ≠ 0 := by rintro rfl; simp at h4
  have hx4 : x = x' ^ 4 * ζ⁻¹ ^ k := by
    rw [hx, mul_assoc, ← mul_pow, mul_inv_cancel₀ hζ, one_pow, mul_one]
  split_ifs with h0
  · subst h0; rw [hx4, pow_zero, mul_one, inv_pow]
  · rw [hx4, mul_inv, inv_pow, inv_pow, inv_inv, ← zeta_pow_eq_inv_pow h4 hk.le]

end Field

/-! ### The word-level `_ixStep` -/

/-- `for (t = k; t < 4; ++t) ix = mulmod(ix, izeta, P)`, as `r` repetitions. -/
def mulRepeat (ix izeta : ℕ) : ℕ → ℕ
  | 0 => ix
  | r + 1 => mulRepeat (mulmod ix izeta P) izeta r

/-- `RealQueryVerify._ixStep`: square twice, then multiply by `izeta` `4 - k` times if `k ≠ 0`. -/
def ixStep (ix izeta k : ℕ) : ℕ :=
  let a := mulmod ix ix P
  let b := mulmod a a P
  if k ≠ 0 then mulRepeat b izeta (4 - k) else b

theorem mulRepeat_cast (ix izeta r : ℕ) :
    (mulRepeat ix izeta r : Fp) = ix * (izeta : Fp) ^ r := by
  induction r generalizing ix with
  | zero => simp [mulRepeat]
  | succ r ih => rw [mulRepeat, ih, cast_mulmod, pow_succ']; ring

theorem mulRepeat_lt {ix : ℕ} (hix : ix < P) (izeta r : ℕ) : mulRepeat ix izeta r < P := by
  induction r generalizing ix with
  | zero => exact hix
  | succ r ih => exact ih (mulmod_lt _ _)

/-- `_ixStep` computes `ix^4 · izeta^{4-k}` (or `ix^4` for `k = 0`) in `𝔽_p`. -/
theorem ixStep_cast (ix izeta k : ℕ) :
    (ixStep ix izeta k : Fp) =
      if k = 0 then (ix : Fp) ^ 4 else (ix : Fp) ^ 4 * (izeta : Fp) ^ (4 - k) := by
  unfold ixStep
  by_cases h : k = 0
  · simp only [h, ne_eq, not_true_eq_false, ite_false, ite_true, cast_mulmod]; ring
  · simp only [h, ne_eq, not_false_eq_true, ite_true, ite_false, mulRepeat_cast, cast_mulmod]; ring

/-- **`_ixStep` is correct.** If `ix` is the canonical `1/x'`, `izeta` represents `ζ⁻¹` with
`ζ^4 = 1`, `k < 4`, and `x'^4 = x ζ^k`, then `_ixStep` returns the canonical `1/x`. -/
theorem ixStep_spec {x x' ζ : Fp} {ix izeta k : ℕ} (h4 : ζ ^ 4 = 1) (hk : k < 4)
    (hx : x' ^ 4 = x * ζ ^ k) (hix : (ix : Fp) = x'⁻¹) (hiz : (izeta : Fp) = ζ⁻¹) :
    ixStep ix izeta k = (x⁻¹).val := by
  refine eq_val_of_lt ?_ ?_
  · unfold ixStep; split_ifs
    · exact mulRepeat_lt (mulmod_lt _ _) _ _
    · exact mulmod_lt _ _
  · rw [ixStep_cast, hix, hiz, inv_step h4 hk hx]

end Shield.Fri
