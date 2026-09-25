import Mathlib.Algebra.MvPolynomial.SchwartzZippel

/-!
# The Schwartz-Zippel lemma, in the form the rank argument uses

Mathlib proves the lemma as `MvPolynomial.schwartz_zippel_totalDegree`: for a nonzero polynomial
`f` in `k` variables over an integral domain and a finite set `S`, the proportion of points of
`S^k` at which `f` vanishes is at most `totalDegree f / |S|`. The rank argument has a degree
*bound* `d ≥ totalDegree f`, not the degree itself; `card_zeros_div_le` restates the lemma with
such a bound.
-/

namespace Shield.Zk

open MvPolynomial Finset Fintype

variable {K : Type*} [Field K] [DecidableEq K]

/-- **Schwartz-Zippel, as used.** Let `f ≠ 0` in `K[c₁, …, c_k]` with `totalDegree f ≤ d`, and
let `S ⊆ K` be finite. Then
`|{c ∈ S^k : f(c) = 0}| / |S|^k ≤ d / |S|`. -/
theorem card_zeros_div_le {k d : ℕ} {f : MvPolynomial (Fin k) K} (hf : f ≠ 0)
    (hd : f.totalDegree ≤ d) (S : Finset K) :
    (#{c ∈ piFinset fun _ : Fin k ↦ S | eval c f = 0} : ℚ≥0) / (#S ^ k : ℚ≥0) ≤ d / #S :=
  calc (#{c ∈ piFinset fun _ : Fin k ↦ S | eval c f = 0} : ℚ≥0) / (#S ^ k : ℚ≥0)
      ≤ f.totalDegree / #S := schwartz_zippel_totalDegree hf S
    _ ≤ d / #S := by gcongr

/-- The same bound as a count: at most `d · |S|^(k-1)` zeros, written `d · |S|^k / |S|`. -/
theorem card_zeros_le {k d : ℕ} {f : MvPolynomial (Fin k) K} (hf : f ≠ 0)
    (hd : f.totalDegree ≤ d) (S : Finset K) (hS : S.Nonempty) :
    (#{c ∈ piFinset fun _ : Fin k ↦ S | eval c f = 0} : ℚ≥0) ≤ d / #S * (#S ^ k : ℚ≥0) := by
  have hpos : (0 : ℚ≥0) < (#S ^ k : ℚ≥0) := by
    have : (0 : ℚ≥0) < #S := by exact_mod_cast hS.card_pos
    positivity
  rw [← div_le_iff₀ hpos]
  exact card_zeros_div_le hf hd S

end Shield.Zk
