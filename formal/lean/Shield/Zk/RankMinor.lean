import Shield.Zk.SchwartzZippel
import Mathlib.LinearAlgebra.Matrix.Rank
import Mathlib.LinearAlgebra.Matrix.NonsingularInverse
import Mathlib.LinearAlgebra.Dimension.OrzechProperty
import Mathlib.Algebra.MvPolynomial.CommRing

/-!
# The rank lemma for matrices of polynomials

Let `M(c)` be a matrix whose entries are polynomials of total degree at most `e` in challenge
variables `c = (c₁, …, c_k)`. If `rank M(c₀) ≥ r` at one point `c₀`, then some `r × r` minor of `M`
is a nonzero polynomial of degree at most `r·e`, and `rank M(c) ≥ r` wherever that minor does not
vanish. By Schwartz-Zippel, for `c` uniform on `S^k`,
`Pr[rank M(c) < r] ≤ r·e / |S|`.

* `exists_rows_linearIndependent`, `exists_minor_ne_zero`, `le_rank_of_minor_ne_zero`: over a
  field, `rank A ≥ r` if and only if some `r × r` minor of `A` is nonzero.
* `totalDegree_det_le`: an `r × r` determinant of polynomials of degree `≤ e` has degree `≤ r·e`.
* `rank_lemma`: the statement above.
-/

namespace Shield.Zk

open Matrix MvPolynomial Finset Fintype Module

section Minors

variable {K : Type*} [Field K] {m n : Type*} [Fintype m] [Fintype n]

/-- If `r ≤ rank A`, then `r` rows of `A` are linearly independent. -/
theorem exists_rows_linearIndependent {A : Matrix m n K} {r : ℕ} (h : r ≤ A.rank) :
    ∃ f : Fin r → m, LinearIndependent K (fun i ↦ A (f i)) := by
  classical
  obtain ⟨κ, a, -, hspan, hli⟩ := exists_linearIndependent' K A.row
  have hκ : Finite κ := Finite.of_injective a (hli.injective.of_comp)
  have : Fintype κ := Fintype.ofFinite κ
  have hcard : Fintype.card κ = A.rank := by
    rw [linearIndependent_iff_card_eq_finrank_span.mp hli, Set.finrank, hspan,
      A.rank_eq_finrank_span_row]
  obtain ⟨emb⟩ : Nonempty (Fin r ↪ κ) :=
    Function.Embedding.nonempty_of_card_le (by simpa [hcard] using h)
  exact ⟨a ∘ emb, hli.comp emb emb.injective⟩

/-- **Minors detect rank (one direction).** If `r ≤ rank A`, some `r × r` minor of `A` is
nonzero. -/
theorem exists_minor_ne_zero {A : Matrix m n K} {r : ℕ} (h : r ≤ A.rank) :
    ∃ (f : Fin r → m) (g : Fin r → n), (A.submatrix f g).det ≠ 0 := by
  classical
  obtain ⟨f, hf⟩ := exists_rows_linearIndependent h
  set B : Matrix (Fin r) n K := A.submatrix f id
  have hB : B.rank = r := by
    have := LinearIndependent.rank_matrix (M := B) hf
    simpa using this
  obtain ⟨g, hg⟩ := exists_rows_linearIndependent (A := Bᵀ) (r := r) (by rw [rank_transpose, hB])
  refine ⟨f, g, ?_⟩
  have hunit : IsUnit ((Bᵀ).submatrix g id) :=
    linearIndependent_rows_iff_isUnit.mp hg
  have : (A.submatrix f g) = ((Bᵀ).submatrix g id)ᵀ := by
    ext i j; rfl
  rw [this, det_transpose]
  exact (isUnit_iff_isUnit_det _).mp hunit |>.ne_zero

omit [Fintype m] in
/-- **Minors detect rank (the other direction).** A nonzero `r × r` minor gives `rank A ≥ r`. -/
theorem le_rank_of_minor_ne_zero {A : Matrix m n K} {r : ℕ} {f : Fin r → m} {g : Fin r → n}
    (h : (A.submatrix f g).det ≠ 0) : r ≤ A.rank := by
  classical
  calc r = (A.submatrix f g).rank := by rw [rank_of_det_ne_zero h, Fintype.card_fin]
    _ ≤ A.rank := rank_submatrix_le A f g

end Minors

section Polynomial

variable {K : Type*} [Field K] {σ : Type*}

/-- **Degree of a determinant.** If every entry of an `r × r` matrix of polynomials has total
degree at most `e`, its determinant has total degree at most `r·e`. -/
theorem totalDegree_det_le {r e : ℕ} (M : Matrix (Fin r) (Fin r) (MvPolynomial σ K))
    (he : ∀ i j, (M i j).totalDegree ≤ e) : M.det.totalDegree ≤ r * e := by
  rw [det_apply]
  refine totalDegree_finsetSum_le fun τ _ ↦ ?_
  calc (Equiv.Perm.sign τ • ∏ i, M (τ i) i).totalDegree
      ≤ (∏ i, M (τ i) i).totalDegree := by
        rcases Int.units_eq_one_or (Equiv.Perm.sign τ) with h | h <;> simp [h, totalDegree_neg]
    _ ≤ ∑ i, (M (τ i) i).totalDegree := totalDegree_finsetProd _ _
    _ ≤ ∑ _i : Fin r, e := sum_le_sum fun i _ ↦ he _ _
    _ = r * e := by simp

/-- Evaluation commutes with taking a minor. -/
theorem eval_det_submatrix {m n : Type*} {r : ℕ} (M : Matrix m n (MvPolynomial σ K))
    (f : Fin r → m) (g : Fin r → n) (c : σ → K) :
    eval c (M.submatrix f g).det = ((M.map (eval c)).submatrix f g).det := by
  rw [RingHom.map_det]; rfl

variable {m n : Type*} [Fintype m] [Fintype n]

/-- **The minor behind a rank.** If `rank M(c₀) ≥ r`, there is an `r × r` minor `P` of `M` with
`P ≠ 0`, `deg P ≤ r·e`, and `rank M(c) ≥ r` at every `c` with `P(c) ≠ 0`. -/
theorem exists_rank_minor {k r e : ℕ} (M : Matrix m n (MvPolynomial (Fin k) K))
    (he : ∀ i j, (M i j).totalDegree ≤ e) {c₀ : Fin k → K} (h₀ : r ≤ (M.map (eval c₀)).rank) :
    ∃ P : MvPolynomial (Fin k) K, P ≠ 0 ∧ P.totalDegree ≤ r * e ∧
      ∀ c, eval c P ≠ 0 → r ≤ (M.map (eval c)).rank := by
  obtain ⟨f, g, hfg⟩ := exists_minor_ne_zero h₀
  refine ⟨(M.submatrix f g).det, ?_, totalDegree_det_le _ fun i j ↦ he _ _, fun c hc ↦ ?_⟩
  · intro h0
    apply hfg
    rw [← eval_det_submatrix, h0, map_zero]
  · rw [eval_det_submatrix] at hc
    exact le_rank_of_minor_ne_zero hc

/-- **The rank lemma.** Let `M(c)` have polynomial entries of total degree at most `e` in `k`
variables, and suppose `rank M(c₀) ≥ r` at some point `c₀`. For every finite `S ⊆ K`,
`|{c ∈ S^k : rank M(c) < r}| / |S|^k ≤ r·e / |S|`. -/
theorem rank_lemma [DecidableEq K] {k r e : ℕ} (M : Matrix m n (MvPolynomial (Fin k) K))
    (he : ∀ i j, (M i j).totalDegree ≤ e) {c₀ : Fin k → K} (h₀ : r ≤ (M.map (eval c₀)).rank)
    (S : Finset K) :
    (#{c ∈ piFinset fun _ : Fin k ↦ S | (M.map (eval c)).rank < r} : ℚ≥0) / (#S ^ k : ℚ≥0)
      ≤ (r * e : ℕ) / #S := by
  obtain ⟨P, hP, hdeg, hrank⟩ := exists_rank_minor M he h₀
  have hsub : ({c ∈ piFinset fun _ : Fin k ↦ S | (M.map (eval c)).rank < r} : Finset (Fin k → K))
      ⊆ {c ∈ piFinset fun _ : Fin k ↦ S | eval c P = 0} := by
    intro c hc
    simp only [mem_filter] at hc ⊢
    exact ⟨hc.1, by_contra fun h ↦ (hrank c h).not_gt hc.2⟩
  calc (#{c ∈ piFinset fun _ : Fin k ↦ S | (M.map (eval c)).rank < r} : ℚ≥0) / (#S ^ k : ℚ≥0)
      ≤ (#{c ∈ piFinset fun _ : Fin k ↦ S | eval c P = 0} : ℚ≥0) / (#S ^ k : ℚ≥0) := by
        gcongr
    _ ≤ (r * e : ℕ) / #S := card_zeros_div_le hP hdeg S

end Polynomial

end Shield.Zk
