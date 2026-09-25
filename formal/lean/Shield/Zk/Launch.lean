import Shield.Zk.FriMask
import Mathlib.Tactic.NormNum
import Mathlib.Tactic.Linarith

/-!
# The rank condition (R) at the launch parameters

The prover's soundness note, Section 4.4, reduces zero-knowledge of FRI beyond layer zero to

**(R)** `dim_{𝔽_p} F(ker A) = dim_{𝔽_p} F(ker L₀)`,

and checks it per proof (`zk_fri_rank`: both sides `1,328` on the four package proofs). This
file proves that, over uniformly random challenges `(z, α, β₁, …, β₄) ∈ 𝔽_{p²}^6`, (R) fails with
probability at most

`ε = 1328 · 102 / p ≈ 2^{-46.95}`,

for every set of query positions at which one challenge point reaching rank `1,328` is known.

* `launch_rank_failure`: `Pr_c[rank M(c) < 1328] ≤ 1328·102/p` for the FRI mask matrix `M`.
* `launch_condition_R`: the same bound for the failure of (R), under the named hypotheses that
  connect the matrix to the two sides of (R).
* `eps_lt`, `eps_gt`: `2^{-47} < ε < 2^{-46}`, so `ε < 2^{-80}` is false (`eps_not_lt_two_pow_neg_80`).
* `sz_floor`: with `r = 1328` rows over `S = 𝔽_p`, no degree `e ≥ 1` gives better than
  `2^{-54}`. A `2^{-80}` bound is out of reach of this argument.
* `average_over_positions`: the per-position bound, averaged over query positions drawn
  independently of the challenges. This is the only union bound the argument needs, since one
  matrix covers every layer.
-/

namespace Shield.Zk

open Shield.Field MvPolynomial Finset Module

/-! ### Linear algebra behind (R) -/

section LinearAlgebra

variable {K U V W₁ : Type*} [Field K] [AddCommGroup U] [Module K U] [AddCommGroup V] [Module K V]
  [AddCommGroup W₁] [Module K W₁] [FiniteDimensional K W₁]

/-- A parametrisation `Φ` of masks inside `ker A` gives a lower bound on `dim F(ker A)`:
`dim range (F ∘ Φ) ≤ dim F(ker A)` whenever `range Φ ≤ ker A`. -/
theorem finrank_range_comp_le {W₂ : Type*} [AddCommGroup W₂] [Module K W₂]
    (A : V →ₗ[K] W₂) (F : V →ₗ[K] W₁) (Φ : U →ₗ[K] V) (hΦ : LinearMap.range Φ ≤ LinearMap.ker A) :
    finrank K (LinearMap.range (F ∘ₗ Φ)) ≤ finrank K ((LinearMap.ker A).map F) := by
  rw [LinearMap.range_comp]
  exact Submodule.finrank_mono (Submodule.map_mono hΦ)

/-- **(R) from a rank bound.** If `F(ker A) ⊆ F(ker L₀)`, `dim F(ker L₀) ≤ r` and
`dim F(ker A) ≥ r`, the two spaces are equal. -/
theorem condition_R_of_le {S₁ S₂ : Submodule K W₁} {r : ℕ} (hle : S₁ ≤ S₂)
    (hS₂ : finrank K S₂ ≤ r) (hS₁ : r ≤ finrank K S₁) : S₁ = S₂ :=
  Submodule.eq_of_le_of_finrank_le hle (hS₂.trans hS₁)

end LinearAlgebra

/-! ### The launch bound -/

/-- The number of challenge points with rank below `1,328`, for the geometry `G`. -/
noncomputable def badChallenges (G : Geometry) : Finset (Coord → Fp) :=
  {c ∈ Fintype.piFinset fun _ : Coord ↦ (univ : Finset Fp) |
    ((revealMatrix G).map (eval c)).rank < 1328}

theorem card_univ_Fp : #(univ : Finset Fp) = P := by
  rw [card_univ, ZMod.card]

/-- **The rank lemma at the launch parameters.** Fix the query positions (the geometry `G`). If
at some challenge point `c₀` the FRI mask matrix has rank at least `1,328`, then for challenges
uniform on `𝔽_{p²}^6`,
`Pr[rank M(c) < 1328] ≤ 1328 · 102 / p`. -/
theorem launch_rank_failure (G : Geometry) {c₀ : Coord → Fp}
    (h₀ : 1328 ≤ ((revealMatrix G).map (eval c₀)).rank) :
    (#(badChallenges G) : ℚ≥0) / ((P : ℚ≥0) ^ 12) ≤ (1328 * 102 : ℕ) / (P : ℚ≥0) := by
  have h := rank_lemma (revealMatrix G) (revealMatrix_degree G) h₀ (univ : Finset Fp)
  rw [card_univ_Fp] at h
  exact h

/-- **Hypothesis (ReportedRank).** At the challenges `c₀` of a proof whose query positions give
`G`, the FRI mask matrix has rank `1,328`, the value `zk_fri_rank` reports for `dim F(ker A)`. -/
def ReportedRank (G : Geometry) (c₀ : Coord → Fp) : Prop :=
  1328 ≤ ((revealMatrix G).map (eval c₀)).rank

-- The linter's traversal of this proof exceeds the recursion limit. The proof itself does not.
set_option linter.constructorNameAsVariable false in
/-- **(R) fails with probability at most `1328·102/p`.** For each challenge point `c`, let
`FA c = F(ker A)` and `FL0 c = F(ker L₀)` be subspaces of the revealed coordinates. Assume

* `hIncl`: `F(ker A) ⊆ F(ker L₀)` (Lemma 4.2 of the soundness note).
* `hUpper`: `dim F(ker L₀) ≤ 1328` (the `152` fold-consistency relations of FRI).
* `hModel`: `rank M(c) ≤ dim F(ker A)` (the columns of `M(c)` are `F` of masks in `ker A`,
  `maskPoly_eval_*`, `revealMatrix_eval`).
* `h₀`: `ReportedRank G c₀`.

Then the proportion of challenge points at which (R) fails is at most `1328·102/p`. -/
theorem launch_condition_R (G : Geometry) {V : Type*} [AddCommGroup V] [Module Fp V]
    [FiniteDimensional Fp V] [DecidableEq (Submodule Fp V)] (FA FL0 : (Coord → Fp) → Submodule Fp V)
    (hIncl : ∀ c, FA c ≤ FL0 c) (hUpper : ∀ c, finrank Fp (FL0 c) ≤ 1328)
    (hModel : ∀ c, ((revealMatrix G).map (eval c)).rank ≤ finrank Fp (FA c))
    {c₀ : Coord → Fp} (h₀ : ReportedRank G c₀) :
    (#{c ∈ Fintype.piFinset fun _ : Coord ↦ (univ : Finset Fp) | FA c ≠ FL0 c} : ℚ≥0) /
        ((P : ℚ≥0) ^ 12) ≤ (1328 * 102 : ℕ) / (P : ℚ≥0) := by
  refine le_trans ?_ (launch_rank_failure G h₀)
  have hsub : {c ∈ Fintype.piFinset fun _ : Coord ↦ (univ : Finset Fp) | FA c ≠ FL0 c}
      ⊆ badChallenges G := by
    intro c hc
    rw [mem_filter] at hc
    rw [badChallenges, mem_filter]
    refine ⟨by rw [Fintype.mem_piFinset]; intro i; exact mem_univ _, ?_⟩
    by_contra hr
    exact hc.2 (condition_R_of_le (hIncl c) (hUpper c) ((not_lt.mp hr).trans (hModel c)))
  have hcard : (#{c ∈ Fintype.piFinset fun _ : Coord ↦ (univ : Finset Fp) | FA c ≠ FL0 c} : ℚ≥0)
      ≤ #(badChallenges G) := by
    have h := card_le_card hsub
    exact_mod_cast h
  exact div_le_div_of_nonneg_right hcard zero_le

/-! ### The number -/

/-- `ε = 1328 · 102 / p`. -/
noncomputable def eps : ℚ := (1328 * 102 : ℚ) / P

theorem eps_eq : eps = 135456 / 18446744069414584321 := by
  rw [eps, P_val]; norm_num

theorem eps_lt : eps < (2 : ℚ) ^ (-46 : ℤ) := by
  rw [eps_eq]; norm_num

theorem eps_gt : (2 : ℚ) ^ (-47 : ℤ) < eps := by
  rw [eps_eq]; norm_num

/-- The target `2^{-80}` is not met by this argument. -/
theorem eps_not_lt_two_pow_neg_80 : ¬ eps < (2 : ℚ) ^ (-80 : ℤ) := by
  rw [eps_eq]; norm_num

/-- **The floor of the method.** Even with entry degree `1`, `r = 1328` over `S = 𝔽_p` gives
`r / p > 2^{-54}`. -/
theorem sz_floor : (2 : ℚ) ^ (-54 : ℤ) < (1328 : ℚ) / P := by
  rw [P_val]; norm_num

theorem launch_rank_failure_eps (G : Geometry) {c₀ : Coord → Fp} (h₀ : ReportedRank G c₀) :
    (#(badChallenges G) : ℚ) / ((P : ℚ) ^ 12) ≤ eps := by
  have h := NNRat.coe_le_coe.mpr (launch_rank_failure G h₀)
  push_cast at h
  refine h.trans (le_of_eq ?_)
  rw [eps]; norm_num

/-! ### The four package proofs -/

/-- The four proofs of the launch package on which `zk_fri_rank` reports rank `1,328`. -/
inductive PackageProof
  | withdrawA
  | withdrawB
  | honest
  | spend

/-- **Instantiation at the package proofs.** Let `G π` be the geometry fixed by the query
positions of proof `π` and `c₀ π` its challenges. Under `ReportedRank (G π) (c₀ π)` for each of
the four proofs, for challenges uniform on `𝔽_{p²}^6` and the query positions of any one of them,
`Pr[rank M(c) < 1328] ≤ ε < 2^{-46}`. -/
theorem package_rank_failure (G : PackageProof → Geometry) (c₀ : PackageProof → Coord → Fp)
    (hrep : ∀ π, ReportedRank (G π) (c₀ π)) (π : PackageProof) :
    (#(badChallenges (G π)) : ℚ) / ((P : ℚ) ^ 12) < (2 : ℚ) ^ (-46 : ℤ) :=
  (launch_rank_failure_eps (G π) (hrep π)).trans_lt eps_lt

/-! ### Averaging over the query positions -/

/-- **Averaging over positions.** Let the query positions `q` range over `Q` and the challenges
over `C`, independently. If for every `q` in `G ⊆ Q` at most `ε·|C|` challenges are bad, then at
most `|Q \ G|·|C| + ε·|Q|·|C|` pairs are bad, so
`Pr[bad] ≤ Pr[q ∉ G] + ε`. -/
theorem average_over_positions {ι γ : Type*} [DecidableEq ι] (Q G : Finset ι) (C : Finset γ)
    (bad : ι → γ → Prop) [∀ q c, Decidable (bad q c)] (ε : ℚ≥0)
    (hG : ∀ q ∈ G, (#{c ∈ C | bad q c} : ℚ≥0) ≤ ε * #C) :
    (#{x ∈ Q ×ˢ C | bad x.1 x.2} : ℚ≥0) ≤ #(Q \ G) * #C + ε * #Q * #C := by
  have hcount : #{x ∈ Q ×ˢ C | bad x.1 x.2} = ∑ q ∈ Q, #{c ∈ C | bad q c} := by
    rw [card_filter, sum_product]
    simp only [card_filter]
  have hsplit : (∑ q ∈ Q, (#{c ∈ C | bad q c} : ℚ≥0))
      ≤ ∑ q ∈ Q, ((if q ∈ G then 0 else (#C : ℚ≥0)) + ε * #C) := by
    refine sum_le_sum fun q _ ↦ ?_
    split_ifs with hq
    · simpa using hG q hq
    · calc (#{c ∈ C | bad q c} : ℚ≥0) ≤ #C := by exact_mod_cast card_filter_le _ _
        _ ≤ #C + ε * #C := le_add_of_nonneg_right (by positivity)
  have hQG : ∑ q ∈ Q, (if q ∈ G then (0 : ℚ≥0) else (#C : ℚ≥0)) = #(Q \ G) * #C := by
    rw [sum_ite, sum_const_zero, zero_add, sum_const, nsmul_eq_mul, ← sdiff_eq_filter]
  calc (#{x ∈ Q ×ˢ C | bad x.1 x.2} : ℚ≥0) = ∑ q ∈ Q, (#{c ∈ C | bad q c} : ℚ≥0) := by
        rw [hcount]; push_cast; rfl
    _ ≤ ∑ q ∈ Q, ((if q ∈ G then 0 else (#C : ℚ≥0)) + ε * #C) := hsplit
    _ = #(Q \ G) * #C + ε * #Q * #C := by
        rw [sum_add_distrib, hQG, sum_const, nsmul_eq_mul]; ring

end Shield.Zk
