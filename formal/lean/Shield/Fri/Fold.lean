import Shield.Arith.Fp2Impl
import Shield.Fri.Chain

/-!
# The radix-4 FRI fold

`RealQueryVerify._quadFold` folds the four values of a quad, `v_j = f(x ζ^j)` with `ζ` a primitive
fourth root of unity, by three radix-2 folds (`_fold2Raw`):

    u   = fold2(v0, v2; β,  1/x)
    w   = fold2(v1, v3; β,  1/(xζ))
    out = fold2(u,  w;  β², 1/x²)          where fold2(a, b; β, ix) = (a + b)·½ + β·(a − b)·½·ix.

`fold_quad` proves that for `f(X) = Σ_{j<4} X^j f_j(X^4)` this is `Σ_j β^j f_j(x^4)`. The `f_j`
are arbitrary functions. Polynomials are the case FRI uses (`exists_quad_decomposition`).
`quadFold_val` proves that the word-level `_quadFold`, transcribed from the contract, computes the
field expression, so `quadFold_correct` states the theorem over the contract's formula.
-/

namespace Shield.Fri

open Shield.Field Shield.Arith Polynomial

section Field

variable {K : Type*} [Field K]

/-- The radix-2 fold in the contract's shape: `(a + b)·h + β·((a − b)·(h·ix))`, `h = ½`. -/
def fold2 (h a b β ix : K) : K := (a + b) * h + β * ((a - b) * (h * ix))

/-- The radix-4 fold in the contract's shape. -/
def quadFoldF (h v0 v1 v2 v3 β ix0 ix1 : K) : K :=
  fold2 h (fold2 h v0 v2 β ix0) (fold2 h v1 v3 β ix1) (β ^ 2) (ix0 * ix0)

/-- **Radix-2 fold of an even/odd split.** With `a = E + xO` and `b = E − xO`, the fold under
`β` at `1/x` is `E + βO`. -/
theorem fold2_even_odd {h x : K} (hh : h * 2 = 1) (hx : x ≠ 0) (E O β : K) :
    fold2 h (E + x * O) (E - x * O) β x⁻¹ = E + β * O := by
  unfold fold2
  have : (E + x * O - (E - x * O)) * (h * x⁻¹) = O * (h * 2) := by field_simp; ring
  rw [this, hh]
  linear_combination E * hh

variable {f f₀ f₁ f₂ f₃ : K → K}

/-- The even/odd split of `f(X) = Σ X^j f_j(X⁴)` at a point. -/
theorem split_at (hf : ∀ y, f y = f₀ (y ^ 4) + y * f₁ (y ^ 4) + y ^ 2 * f₂ (y ^ 4) + y ^ 3 * f₃ (y ^ 4))
    (y : K) :
    f y = (f₀ (y ^ 4) + y ^ 2 * f₂ (y ^ 4)) + y * (f₁ (y ^ 4) + y ^ 2 * f₃ (y ^ 4)) := by
  rw [hf]; ring

theorem split_at_neg (hf : ∀ y, f y = f₀ (y ^ 4) + y * f₁ (y ^ 4) + y ^ 2 * f₂ (y ^ 4) + y ^ 3 * f₃ (y ^ 4))
    (y : K) :
    f (-y) = (f₀ (y ^ 4) + y ^ 2 * f₂ (y ^ 4)) - y * (f₁ (y ^ 4) + y ^ 2 * f₃ (y ^ 4)) := by
  rw [hf, show (-y) ^ 4 = y ^ 4 by ring]; ring

/-- **Radix-4 fold correctness.** Let `f(X) = Σ_{j<4} X^j f_j(X⁴)`, `ζ² = −1`, `x ≠ 0` and
`v_j = f(x ζ^j)`. The contract's fold, with `ix0 = 1/x` and `ix1 = 1/(xζ)`, returns
`f₀(x⁴) + β f₁(x⁴) + β² f₂(x⁴) + β³ f₃(x⁴)`. -/
theorem fold_quad {h x ζ β : K} (hh : h * 2 = 1) (hx : x ≠ 0) (hζ : ζ ^ 2 = -1)
    (hf : ∀ y, f y = f₀ (y ^ 4) + y * f₁ (y ^ 4) + y ^ 2 * f₂ (y ^ 4) + y ^ 3 * f₃ (y ^ 4)) :
    quadFoldF h (f x) (f (x * ζ)) (f (x * ζ ^ 2)) (f (x * ζ ^ 3)) β x⁻¹ (x * ζ)⁻¹ =
      f₀ (x ^ 4) + β * f₁ (x ^ 4) + β ^ 2 * f₂ (x ^ 4) + β ^ 3 * f₃ (x ^ 4) := by
  have hζ0 : ζ ≠ 0 := by rintro rfl; norm_num at hζ
  have hy : x * ζ ≠ 0 := mul_ne_zero hx hζ0
  have h2 : x * ζ ^ 2 = -x := by rw [hζ]; ring
  have h3 : x * ζ ^ 3 = -(x * ζ) := by linear_combination (x * ζ) * hζ
  have hy2 : (x * ζ) ^ 2 = -x ^ 2 := by rw [mul_pow, hζ]; ring
  have hy4 : (x * ζ) ^ 4 = x ^ 4 := by
    rw [show (x * ζ) ^ 4 = ((x * ζ) ^ 2) ^ 2 by ring, hy2]; ring
  -- the two inner folds
  have hu : fold2 h (f x) (f (x * ζ ^ 2)) β x⁻¹ =
      (f₀ (x ^ 4) + β * f₁ (x ^ 4)) + x ^ 2 * (f₂ (x ^ 4) + β * f₃ (x ^ 4)) := by
    rw [h2, split_at hf, split_at_neg hf, fold2_even_odd hh hx]; ring
  have hw : fold2 h (f (x * ζ)) (f (x * ζ ^ 3)) β (x * ζ)⁻¹ =
      (f₀ (x ^ 4) + β * f₁ (x ^ 4)) - x ^ 2 * (f₂ (x ^ 4) + β * f₃ (x ^ 4)) := by
    rw [h3, split_at hf, split_at_neg hf, fold2_even_odd hh hy, hy4, hy2]; ring
  -- the outer fold, at x² under β²
  unfold quadFoldF
  rw [hu, hw, show x⁻¹ * x⁻¹ = (x ^ 2)⁻¹ by rw [sq, mul_inv],
    fold2_even_odd hh (pow_ne_zero 2 hx)]
  ring

/-- Every polynomial splits as `f = Σ_{j<4} X^j f_j(X⁴)`, with `f_j` collecting the coefficients
of index `≡ j (mod 4)`. -/
theorem exists_quad_decomposition (f : K[X]) :
    ∃ g : Fin 4 → K[X], ∀ y : K,
      f.eval y = ∑ j : Fin 4, y ^ (j : ℕ) * (g j).eval (y ^ 4) := by
  classical
  refine ⟨fun j ↦ ∑ n ∈ Finset.range (f.natDegree + 1), C (f.coeff (4 * n + j)) * X ^ n, ?_⟩
  intro y
  simp only [eval_finsetSum, eval_mul, eval_C, eval_pow, eval_X, Finset.mul_sum]
  rw [f.eval_eq_sum_range, Fin.sum_univ_four]
  have h3 : ((3 : Fin 4) : ℕ) = 3 := rfl
  simp only [Fin.val_zero, Fin.val_one, Fin.val_two, Fin.isValue, h3]
  -- Split `range (d+1)` by residue mod 4 inside `range (4(d+1))`.
  have hsplit : ∀ g : ℕ → K,
      ∑ i ∈ Finset.range (4 * (f.natDegree + 1)), g i =
        ∑ n ∈ Finset.range (f.natDegree + 1),
          (g (4 * n + 0) + g (4 * n + 1) + g (4 * n + 2) + g (4 * n + 3)) := by
    intro g
    induction f.natDegree + 1 with
    | zero => simp
    | succ d ih =>
      rw [show 4 * (d + 1) = 4 * d + 1 + 1 + 1 + 1 by ring, Finset.sum_range_succ,
        Finset.sum_range_succ, Finset.sum_range_succ, Finset.sum_range_succ, ih,
        Finset.sum_range_succ]
      ring_nf
  have hext : ∑ i ∈ Finset.range (f.natDegree + 1), f.coeff i * y ^ i =
      ∑ i ∈ Finset.range (4 * (f.natDegree + 1)), f.coeff i * y ^ i := by
    refine (Finset.sum_subset (f := fun i ↦ f.coeff i * y ^ i) (Finset.range_mono (show f.natDegree + 1 ≤ 4 * (f.natDegree + 1) by omega)) ?_)
    intro i _ hi
    simp only [Finset.mem_range, not_lt] at hi
    rw [coeff_eq_zero_of_natDegree_lt (by omega), zero_mul]
  rw [hext, hsplit, ← Finset.sum_add_distrib, ← Finset.sum_add_distrib, ← Finset.sum_add_distrib]
  refine Finset.sum_congr rfl fun n _ ↦ ?_
  simp only [add_zero, pow_add, pow_mul]
  ring

end Field

/-! ### The contract's `_fold2Raw`, `_sqFp2` and `_quadFold` -/

/-- `9223372034707292161`, the contract's `1/2`. -/
def HALF : ℕ := 9223372034707292161

private theorem half_mul_two' : (9223372034707292161 : ZMod 18446744069414584321) * 2 = 1 := by
  decide

theorem half_mul_two : (HALF : Fp) * 2 = 1 := half_mul_two'

/-- `RealQueryVerify._fold2Raw`, transcribed. -/
def fold2Raw (a b : W2) (be0 be1 invx : ℕ) : W2 :=
  let s := mulmod HALF invx P
  let e0 := mulmod (addmod a.c0 b.c0 P) HALF P
  let e1 := mulmod (addmod a.c1 b.c1 P) HALF P
  let o0 := mulmod (addmod a.c0 (P - b.c0) P) s P
  let o1 := mulmod (addmod a.c1 (P - b.c1) P) s P
  ⟨addmod e0 (addmod (mulmod be0 o0 P) (mulmod 7 (mulmod be1 o1 P) P) P) P,
    addmod e1 (addmod (mulmod be0 o1 P) (mulmod be1 o0 P) P) P⟩

/-- `RealQueryVerify._sqFp2`, transcribed. -/
def sqFp2 (a0 a1 : ℕ) : W2 :=
  ⟨addmod (mulmod a0 a0 P) (mulmod 7 (mulmod a1 a1 P) P) P, mulmod 2 (mulmod a0 a1 P) P⟩

/-- `RealQueryVerify._quadFold`, transcribed. -/
def quadFold (v : Fin 4 → W2) (beta : W2) (ix0 ix1 : ℕ) : W2 :=
  let u := fold2Raw (v 0) (v 2) beta.c0 beta.c1 ix0
  let w := fold2Raw (v 1) (v 3) beta.c0 beta.c1 ix1
  let b := sqFp2 beta.c0 beta.c1
  fold2Raw u w b.c0 b.c1 (mulmod ix0 ix0 P)

/-- The base-field embedding. -/
abbrev emb (x : Fp) : Fp2 := algebraMap Fp Fp2 x

theorem fold2Raw_canon (a b : W2) (be0 be1 invx : ℕ) : (fold2Raw a b be0 be1 invx).Canon :=
  ⟨addmod_lt _ _, addmod_lt _ _⟩

/-- **`_fold2Raw` computes the fold formula** in `𝔽_{p²}` (with `b` canonical, so the contract's
`P - b.ci` does not underflow). -/
theorem fold2Raw_val (a : W2) {b : W2} (hb : b.Canon) (be : W2) (invx : ℕ) :
    (fold2Raw a b be.c0 be.c1 invx).val =
      fold2 (emb (HALF : Fp)) a.val b.val be.val (emb (invx : Fp)) := by
  unfold fold2Raw fold2
  ext <;> simp [W2.val, cast_P_sub hb.1.le, cast_P_sub hb.2.le] <;> ring

/-- `_sqFp2` squares. -/
theorem sqFp2_val (a : W2) : (sqFp2 a.c0 a.c1).val = a.val ^ 2 := by
  unfold sqFp2
  ext <;> simp [W2.val, sq] <;> ring

/-- **`_quadFold` computes `quadFoldF`** on canonical inputs. -/
theorem quadFold_val (v : Fin 4 → W2) (hv2 : (v 2).Canon) (hv3 : (v 3).Canon) (beta : W2)
    (ix0 ix1 : ℕ) :
    (quadFold v beta ix0 ix1).val =
      quadFoldF (emb (HALF : Fp)) (v 0).val (v 1).val (v 2).val (v 3).val beta.val
        (emb (ix0 : Fp)) (emb (ix1 : Fp)) := by
  unfold quadFold quadFoldF
  rw [fold2Raw_val _ (fold2Raw_canon _ _ _ _ _), fold2Raw_val _ hv2, fold2Raw_val _ hv3,
    sqFp2_val, cast_mulmod]
  simp only [emb, map_mul]

/-- **Radix-4 fold correctness, over the contract's formula.** Let `f(X) = Σ_{j<4} X^j f_j(X⁴)`
on `𝔽_{p²}`, `x ∈ 𝔽_p^×`, `ζ ∈ 𝔽_p` with `ζ² = −1`, and let the four canonical opened values be
`v_j = f(x ζ^j)`. If `ix0` represents `1/x` and `ix1` represents `1/(xζ)` (as the contract's
`ix · izeta` does, `Shield.Fri.inv_mul_zeta`), then `_quadFold` returns
`Σ_j β^j f_j(x⁴)`. -/
theorem quadFold_correct {f f₀ f₁ f₂ f₃ : Fp2 → Fp2}
    (hf : ∀ y, f y = f₀ (y ^ 4) + y * f₁ (y ^ 4) + y ^ 2 * f₂ (y ^ 4) + y ^ 3 * f₃ (y ^ 4))
    {x ζ : Fp} (hx : x ≠ 0) (hζ : ζ ^ 2 = -1)
    (v : Fin 4 → W2) (hv2 : (v 2).Canon) (hv3 : (v 3).Canon)
    (hv : ∀ j : Fin 4, (v j).val = f (emb (x * ζ ^ (j : ℕ))))
    (beta : W2) {ix0 ix1 : ℕ} (hix0 : (ix0 : Fp) = x⁻¹) (hix1 : (ix1 : Fp) = (x * ζ)⁻¹) :
    (quadFold v beta ix0 ix1).val =
      f₀ (emb x ^ 4) + beta.val * f₁ (emb x ^ 4) + beta.val ^ 2 * f₂ (emb x ^ 4) +
        beta.val ^ 3 * f₃ (emb x ^ 4) := by
  have hh : emb (HALF : Fp) * 2 = 1 := by
    rw [show (2 : Fp2) = emb 2 from (map_ofNat _ 2).symm, ← map_mul, half_mul_two, map_one]
  have hx' : emb x ≠ 0 := by simpa using hx
  have hζ' : emb ζ ^ 2 = -1 := by rw [← map_pow, hζ, map_neg, map_one]
  rw [quadFold_val v hv2 hv3, hv 0, hv 1, hv 2, hv 3, hix0, hix1]
  simp only [Fin.val_zero, Fin.val_one, Fin.val_two, map_mul, map_pow, map_inv₀, pow_zero,
    mul_one, pow_one]
  exact fold_quad hh hx' hζ' hf

end Shield.Fri
