import Shield.Field.Fp2
import Mathlib.Algebra.MvPolynomial.CommRing

/-!
# `𝔽_{p²}`-valued polynomials in base-field coordinates

A challenge `u ∈ 𝔽_{p²}` drawn uniformly is a pair `(u₀, u₁) ∈ 𝔽_p²` drawn uniformly, with
`u = u₀ + u₁ω`. A quantity that the verifier computes from challenges by ring operations,
conjugation and fixed constants is then an element of

`PolyFp2 σ = 𝔽_p[c_i : i ∈ σ][ω] / (ω² − 7)`,

that is, a pair `(re, im)` of polynomials over `𝔽_p` in the coordinates `c_i`. This file gives
that ring a degree (`DegLE n x`: both coordinates have total degree at most `n`), proves how the
degree behaves under the ring operations and conjugation, and defines evaluation at a point
`c : σ → 𝔽_p` as a ring homomorphism `ev c : PolyFp2 σ →+* 𝔽_{p²}`.
-/

namespace Shield.Zk

open Shield.Field MvPolynomial

/-- `𝔽_{p²}`-valued polynomial expressions in `𝔽_p`-coordinates indexed by `σ`. -/
abbrev PolyFp2 (σ : Type*) : Type _ := QuadraticAlgebra (MvPolynomial σ Fp) 7 0

variable {σ : Type*}

/-- `x` has degree at most `n`: both coordinates have total degree at most `n`. -/
def DegLE (n : ℕ) (x : PolyFp2 σ) : Prop :=
  x.re.totalDegree ≤ n ∧ x.im.totalDegree ≤ n

/-- A variable pair `u = X i + X j · ω`: a challenge in `𝔽_{p²}` with coordinates `i`, `j`. -/
noncomputable def var (i j : σ) : PolyFp2 σ := ⟨X i, X j⟩

/-- A constant of `𝔽_{p²}`. -/
noncomputable def cst (u : Fp2) : PolyFp2 σ := ⟨C u.re, C u.im⟩

private theorem totalDegree_seven : (7 : MvPolynomial σ Fp).totalDegree = 0 := by
  rw [show (7 : MvPolynomial σ Fp) = C 7 from (map_ofNat C 7).symm, totalDegree_C]

private theorem totalDegree_seven_mul_le (x y : MvPolynomial σ Fp) :
    (7 * x * y).totalDegree ≤ x.totalDegree + y.totalDegree := by
  calc (7 * x * y).totalDegree ≤ (7 * x).totalDegree + y.totalDegree := totalDegree_mul _ _
    _ ≤ ((7 : MvPolynomial σ Fp).totalDegree + x.totalDegree) + y.totalDegree := by
        gcongr; exact totalDegree_mul _ _
    _ = x.totalDegree + y.totalDegree := by rw [totalDegree_seven, zero_add]

namespace DegLE

theorem mono {m n : ℕ} {x : PolyFp2 σ} (h : DegLE m x) (hmn : m ≤ n) : DegLE n x :=
  ⟨h.1.trans hmn, h.2.trans hmn⟩

theorem zero (n : ℕ) : DegLE n (0 : PolyFp2 σ) := by
  constructor <;> simp

theorem one (n : ℕ) : DegLE n (1 : PolyFp2 σ) := by
  refine ⟨?_, ?_⟩
  · show (1 : MvPolynomial σ Fp).totalDegree ≤ n; simp
  · show (0 : MvPolynomial σ Fp).totalDegree ≤ n; simp

theorem add {n : ℕ} {x y : PolyFp2 σ} (hx : DegLE n x) (hy : DegLE n y) : DegLE n (x + y) :=
  ⟨(totalDegree_add _ _).trans (max_le hx.1 hy.1),
    (totalDegree_add _ _).trans (max_le hx.2 hy.2)⟩

theorem neg {n : ℕ} {x : PolyFp2 σ} (hx : DegLE n x) : DegLE n (-x) := by
  refine ⟨?_, ?_⟩
  · show (-x.re).totalDegree ≤ n; rw [totalDegree_neg]; exact hx.1
  · show (-x.im).totalDegree ≤ n; rw [totalDegree_neg]; exact hx.2

theorem sub {n : ℕ} {x y : PolyFp2 σ} (hx : DegLE n x) (hy : DegLE n y) : DegLE n (x - y) := by
  rw [sub_eq_add_neg]; exact hx.add hy.neg

/-- **Degrees add under multiplication.** -/
theorem mul {m n : ℕ} {x y : PolyFp2 σ} (hx : DegLE m x) (hy : DegLE n y) :
    DegLE (m + n) (x * y) := by
  refine ⟨?_, ?_⟩
  · rw [QuadraticAlgebra.re_mul]
    refine (totalDegree_add _ _).trans (max_le ?_ ?_)
    · exact (totalDegree_mul _ _).trans (add_le_add hx.1 hy.1)
    · exact (totalDegree_seven_mul_le _ _).trans (add_le_add hx.2 hy.2)
  · rw [QuadraticAlgebra.im_mul, zero_mul, zero_mul, add_zero]
    refine (totalDegree_add _ _).trans (max_le ?_ ?_)
    · exact (totalDegree_mul _ _).trans (add_le_add hx.1 hy.2)
    · exact (totalDegree_mul _ _).trans (add_le_add hx.2 hy.1)

theorem pow {n : ℕ} {x : PolyFp2 σ} (hx : DegLE n x) (k : ℕ) : DegLE (k * n) (x ^ k) := by
  induction k with
  | zero => simpa using one 0
  | succ k ih => rw [pow_succ, Nat.succ_mul]; exact ih.mul hx

theorem sum {ι : Type*} {s : Finset ι} {f : ι → PolyFp2 σ} {n : ℕ}
    (h : ∀ i ∈ s, DegLE n (f i)) : DegLE n (∑ i ∈ s, f i) :=
  Finset.sum_induction f (DegLE n) (fun _ _ ↦ add) (zero n) h

/-- Conjugation `u ↦ ū` is linear in the coordinates: it does not raise the degree. -/
theorem star {n : ℕ} {x : PolyFp2 σ} (hx : DegLE n x) : DegLE n (star x) := by
  refine ⟨?_, ?_⟩
  · rw [QuadraticAlgebra.re_star, zero_mul, add_zero]; exact hx.1
  · rw [QuadraticAlgebra.im_star, totalDegree_neg]; exact hx.2

theorem var (i j : σ) : DegLE 1 (var i j : PolyFp2 σ) :=
  ⟨(totalDegree_X_le i).trans le_rfl, (totalDegree_X_le j).trans le_rfl⟩
where
  totalDegree_X_le (i : σ) : (X i : MvPolynomial σ Fp).totalDegree ≤ 1 := by
    rw [totalDegree_X]

theorem cst (u : Fp2) (n : ℕ) : DegLE n (cst u : PolyFp2 σ) :=
  ⟨by simp [Shield.Zk.cst, totalDegree_C], by simp [Shield.Zk.cst, totalDegree_C]⟩

theorem algebraMap (a : Fp) (n : ℕ) : DegLE n (algebraMap Fp (PolyFp2 σ) a) := by
  refine ⟨?_, ?_⟩
  · show (MvPolynomial.C a : MvPolynomial σ Fp).totalDegree ≤ n; simp [totalDegree_C]
  · show (0 : MvPolynomial σ Fp).totalDegree ≤ n; simp

end DegLE

/-- **Evaluation at a point of coordinates**, `PolyFp2 σ → 𝔽_{p²}`. -/
noncomputable def ev (c : σ → Fp) : PolyFp2 σ →+* Fp2 where
  toFun x := ⟨eval c x.re, eval c x.im⟩
  map_one' := by
    ext
    · exact map_one (eval c)
    · exact map_zero (eval c)
  map_mul' x y := by ext <;> simp [map_ofNat]
  map_zero' := by ext <;> simp
  map_add' x y := by ext <;> simp

@[simp] theorem ev_re (c : σ → Fp) (x : PolyFp2 σ) : (ev c x).re = eval c x.re := rfl

@[simp] theorem ev_im (c : σ → Fp) (x : PolyFp2 σ) : (ev c x).im = eval c x.im := rfl

@[simp] theorem ev_var (c : σ → Fp) (i j : σ) : ev c (var i j) = ⟨c i, c j⟩ := by
  ext <;> simp [var]

@[simp] theorem ev_cst (c : σ → Fp) (u : Fp2) : ev c (cst u) = u := by
  ext <;> simp [cst]

@[simp] theorem ev_algebraMap (c : σ → Fp) (a : Fp) :
    ev c (algebraMap Fp (PolyFp2 σ) a) = algebraMap Fp Fp2 a := by
  ext
  · show eval c (MvPolynomial.C a) = a; simp
  · show eval c (0 : MvPolynomial σ Fp) = 0; simp

@[simp] theorem ev_star (c : σ → Fp) (x : PolyFp2 σ) : ev c (star x) = star (ev c x) := by
  ext <;> simp

end Shield.Zk
