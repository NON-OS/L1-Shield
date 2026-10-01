import Mathlib.Algebra.Polynomial.Div
import Mathlib.Algebra.Polynomial.Roots
import Mathlib.Algebra.BigOperators.Group.Finset.Piecewise
import Mathlib.Algebra.Order.BigOperators.Group.Finset
import Mathlib.Algebra.BigOperators.Field
import Mathlib.Tactic.FieldSimp
import Mathlib.Tactic.LinearCombination
import Mathlib.Tactic.GCongr

/-!
# The DEEP quotient

The verifier's DEEP value at a query point `x` is (`RealQueryWalk`, `ProductionDeepQuery`)

  `deep(x) = Σ_i k_i · (f_i(x) − v_i) / (x − z_i)`,

one term per opened column and composition segment, with `z_i ∈ {z, z·g}` the out-of-domain points,
`v_i` the prover's claimed values `f_i(z_i)` and `k_i` the DEEP coefficients. Throughout, `K` is
any field. The verifier's is `𝔽_{p²}`.

What is proved here:

1. `dvd_sub_C_iff` and `deep_quotient`: `(f − f(z))/(X − z)` is a polynomial, of degree
   `deg f − 1`, and `(f − v)/(X − z)` is a polynomial iff `v = f(z)`.
2. `combined_dvd_iff`: with the terms grouped by distinct point `s`, into `g_s = Σ_{z_i = s}
   k_i (f_i − v_i)`, the combined term `Σ_s g_s/(X − s)` is a polynomial
   (`∏(X − s) ∣ Σ_s g_s ∏_{t ≠ s}(X − t)`) iff `g_s(s) = 0` for every `s`. `deep_eval` and
   `deep_group` identify it with the verifier's pointwise formula off the points.
3. `bad_coefficient_unique`: if some claim is wrong, then for any fixing of the other coefficients
   a unique value of the wrong claim's coefficient makes `g_s(s) = 0`.
4. `deep_far`: if the combined term is not a polynomial, its values on any evaluation domain
   avoiding the points agree with any polynomial `h` on at most
   `max(deg N, deg h + |S|)` points, where `N` is the combined numerator.

Not proved here: that the FRI test rejects a word this far from low degree (the proximity
statement, a named hypothesis in `Shield.Soundness`), that the coefficients are uniform and
independent (Fiat-Shamir in the random-oracle model), and the link between the committed trace
columns and the `f_i`. The launch verifier takes the `k_i` as powers of one challenge, so they are
not independent.
-/

namespace Shield.Deep

open Polynomial Finset

variable {K : Type*} [Field K]

/-! ### One quotient -/

/-- **`(X − z) ∣ f − v` iff `v = f(z)`.** The single-claim form of DEEP soundness. -/
theorem dvd_sub_C_iff (f : K[X]) (z v : K) : X - C z ∣ f - C v ↔ f.eval z = v := by
  rw [dvd_iff_isRoot, IsRoot, eval_sub, eval_C, sub_eq_zero]

/-- **The DEEP quotient is a polynomial.** `f − f(z) = (X − z)·q` with
`q = (f − f(z)) /ₘ (X − z)` and `deg q = deg f − 1`. -/
theorem deep_quotient (f : K[X]) (z : K) :
    (X - C z) * ((f - C (f.eval z)) /ₘ (X - C z)) = f - C (f.eval z) ∧
      ((f - C (f.eval z)) /ₘ (X - C z)).natDegree = f.natDegree - 1 := by
  refine ⟨mul_divByMonic_eq_iff_isRoot.mpr (by simp), ?_⟩
  rw [natDegree_divByMonic _ (monic_X_sub_C z), natDegree_X_sub_C]
  rcases Nat.eq_zero_or_pos f.natDegree with h0 | hpos
  · rw [eq_C_of_natDegree_eq_zero h0]; simp
  · rw [natDegree_sub_C]

/-! ### The combined term -/

variable [DecidableEq K]

/-- The common denominator `Z_S = ∏_{s ∈ S} (X − s)`. -/
noncomputable def vanishing (S : Finset K) : K[X] := ∏ s ∈ S, (X - C s)

/-- The combined numerator `N = Σ_s g_s ∏_{t ≠ s} (X − t)`, so `Σ_s g_s/(X − s) = N / Z_S`. -/
noncomputable def numerator (S : Finset K) (g : K → K[X]) : K[X] :=
  ∑ s ∈ S, g s * ∏ t ∈ S.erase s, (X - C t)

theorem eval_numerator_at {S : Finset K} {s : K} (hs : s ∈ S) (g : K → K[X]) :
    (numerator S g).eval s = (g s).eval s * ∏ t ∈ S.erase s, (s - t) := by
  rw [numerator, eval_finsetSum, sum_eq_single s]
  · simp [eval_prod]
  · intro s' _ hne
    rw [eval_mul, eval_prod]
    refine mul_eq_zero_of_right _ (prod_eq_zero (mem_erase.mpr ⟨hne.symm, hs⟩) ?_)
    simp
  · exact fun h ↦ absurd hs h

/-- **The combined DEEP term is a polynomial iff every grouped claim holds at its point.** -/
theorem combined_dvd_iff (S : Finset K) (g : K → K[X]) :
    vanishing S ∣ numerator S g ↔ ∀ s ∈ S, (g s).eval s = 0 := by
  constructor
  · intro h s hs
    have hZ : X - C s ∣ numerator S g :=
      (dvd_prod_of_mem (fun t ↦ X - C t) hs).trans h
    rw [dvd_iff_isRoot, IsRoot, eval_numerator_at hs] at hZ
    refine (mul_eq_zero.mp hZ).resolve_right (prod_ne_zero_iff.mpr fun t ht ↦ ?_)
    exact sub_ne_zero.mpr (ne_of_mem_erase ht).symm
  · intro h
    refine dvd_sum fun s hs ↦ ?_
    obtain ⟨q, hq⟩ := dvd_iff_isRoot.mpr (h s hs)
    rw [hq, vanishing, ← mul_prod_erase S (fun t ↦ X - C t) hs]
    exact ⟨q, by ring⟩

/-- Off the points, the combined term is `N(x) / Z_S(x)`. -/
theorem deep_eval (S : Finset K) (g : K → K[X]) {x : K} (hx : x ∉ S) :
    ∑ s ∈ S, (g s).eval x / (x - s) = (numerator S g).eval x / (vanishing S).eval x := by
  have hne : ∀ t ∈ S, x - t ≠ 0 := fun t ht ↦ sub_ne_zero.mpr fun h ↦ hx (h ▸ ht)
  rw [numerator, vanishing, eval_finsetSum, eval_prod, sum_div]
  refine sum_congr rfl fun s hs ↦ ?_
  rw [eval_mul, eval_prod, ← mul_prod_erase S (fun t ↦ eval x (X - C t)) hs]
  simp only [eval_sub, eval_X, eval_C]
  have hP : ∏ t ∈ S.erase s, (x - t) ≠ 0 :=
    prod_ne_zero_iff.mpr fun t ht ↦ hne t (mem_of_mem_erase ht)
  field_simp [hne s hs, hP]

/-- The verifier's per-column sum, grouped by point: with `g_s = Σ_{z_i = s} k_i (f_i − v_i)`,
`Σ_i k_i (f_i(x) − v_i)/(x − z_i) = Σ_{s} g_s(x)/(x − s)`. -/
theorem deep_group {ι : Type*} (I : Finset ι) (z : ι → K) (k v : ι → K) (f : ι → K[X]) (x : K) :
    ∑ i ∈ I, k i * ((f i).eval x - v i) / (x - z i) =
      ∑ s ∈ I.image z,
        (∑ i ∈ I.filter (fun i ↦ z i = s), C (k i) * (f i - C (v i))).eval x / (x - s) := by
  rw [← sum_fiberwise_of_maps_to (g := z) (t := I.image z) (fun i hi ↦ mem_image_of_mem z hi)]
  refine sum_congr rfl fun s _ ↦ ?_
  rw [eval_finsetSum, sum_div]
  refine sum_congr rfl fun i hi ↦ ?_
  rw [(mem_filter.mp hi).2]
  simp

omit [DecidableEq K] in
/-- **One wrong claim, one bad coefficient.** If `e_{i₀} = f_{i₀}(s) − v_{i₀} ≠ 0`, then for any
values of the other coefficients a unique value of `k_{i₀}` makes `Σ_i k_i e_i = 0`. Over a
uniformly random `k_{i₀}` in a finite field the grouped claim passes with probability `1/|K|`. -/
theorem bad_coefficient_unique {ι : Type*} [DecidableEq ι] (I : Finset ι) {i₀ : ι} (hi₀ : i₀ ∈ I)
    (e k : ι → K) (he : e i₀ ≠ 0) :
    ∃! t : K, ∑ i ∈ I, Function.update k i₀ t i * e i = 0 := by
  have hsum : ∀ t, ∑ i ∈ I, Function.update k i₀ t i * e i =
      t * e i₀ + ∑ i ∈ I \ {i₀}, k i * e i := by
    intro t
    rw [← sum_sdiff (singleton_subset_iff.mpr hi₀), sum_singleton, Function.update_self]
    rw [add_comm]
    congr 1
    refine sum_congr rfl fun i hi ↦ ?_
    rw [Function.update_of_ne (by simpa using (mem_sdiff.mp hi).2)]
  refine ⟨-(∑ i ∈ I \ {i₀}, k i * e i) / e i₀, ?_, ?_⟩
  · beta_reduce
    rw [hsum]; field_simp; ring
  · intro t ht
    rw [hsum] at ht
    field_simp
    linear_combination ht

theorem bad_coefficient_card {ι : Type*} [DecidableEq ι] [Fintype K] (I : Finset ι) {i₀ : ι}
    (hi₀ : i₀ ∈ I) (e k : ι → K) (he : e i₀ ≠ 0) :
    (univ.filter fun t : K ↦ ∑ i ∈ I, Function.update k i₀ t i * e i = 0).card = 1 := by
  obtain ⟨t, ht, huniq⟩ := bad_coefficient_unique I hi₀ e k he
  rw [card_eq_one]
  refine ⟨t, ?_⟩
  ext u
  simp only [mem_filter, mem_univ, true_and, mem_singleton]
  exact ⟨huniq u, fun h ↦ h ▸ ht⟩

/-- **A non-polynomial DEEP term is far from every low-degree word.** Let `D ⊆ K` avoid `S`, and
suppose `Z_S ∤ N`. For every polynomial `h`, the number of `x ∈ D` with `N(x)/Z_S(x) = h(x)` is
at most `max(deg N, deg h + |S|)`. -/
theorem deep_far (S : Finset K) (N h : K[X]) (hdvd : ¬ vanishing S ∣ N) (D : Finset K)
    (hD : ∀ x ∈ D, x ∉ S) :
    (D.filter fun x ↦ N.eval x / (vanishing S).eval x = h.eval x).card ≤
      max N.natDegree (h.natDegree + S.card) := by
  set A := D.filter fun x ↦ N.eval x / (vanishing S).eval x = h.eval x
  have hZx : ∀ x ∈ D, (vanishing S).eval x ≠ 0 := by
    intro x hx
    rw [vanishing, eval_prod, prod_ne_zero_iff]
    intro t ht
    simp only [eval_sub, eval_X, eval_C]
    exact sub_ne_zero.mpr fun e ↦ hD x hx (e ▸ ht)
  have hne : N - h * vanishing S ≠ 0 := by
    intro h0
    exact hdvd ⟨h, by rw [sub_eq_zero.mp h0, mul_comm]⟩
  have hroots : A.val ⊆ (N - h * vanishing S).roots := by
    intro x hx
    have hx' := mem_filter.mp hx
    rw [mem_roots hne, IsRoot, eval_sub, eval_mul, sub_eq_zero]
    rw [div_eq_iff (hZx x hx'.1)] at hx'
    exact hx'.2
  have hdeg : (vanishing S).natDegree = S.card := by
    rw [vanishing, natDegree_prod_of_monic _ _ fun t _ ↦ monic_X_sub_C t]
    simp
  calc A.card ≤ (N - h * vanishing S).natDegree := card_le_degree_of_subset_roots hroots
    _ ≤ max N.natDegree (h * vanishing S).natDegree := natDegree_sub_le _ _
    _ ≤ max N.natDegree (h.natDegree + S.card) := by
        gcongr
        exact natDegree_mul_le.trans (by rw [hdeg])

end Shield.Deep
