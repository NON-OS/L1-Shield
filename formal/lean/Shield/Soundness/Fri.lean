import Shield.Field.Basic
import Mathlib.Analysis.SpecialFunctions.Pow.Real
import Mathlib.Analysis.SpecialFunctions.Sqrt

/-!
# The FRI soundness arithmetic

`StagedStarkVerifier._stageConjectured` and `_stageProvable` compute, for a stage with `q` queries,
`e` extra blowup bits (rate `ρ = 2^{-(e+1)}`) and `γ` grinding bits,

    conjectured = q(e + 1) + γ,        provable = ⌊q(e + 1)/2⌋ + γ.

`_bits` takes the outer stage's provable figure from `_outerTerms`, which adds a commit-phase
term, and applies `_stageProvable` only to an inner stage.

The file has three parts.

1. `johnson_query_bits`, `capacity_query_bits`: the two formulas are the bounds of the *query
   phase alone* when a single query accepts a far word with probability `α ≤ √ρ` (Johnson
   radius, no slack) or `α ≤ ρ` (capacity, conjectural), after grinding divides by `2^γ`.
2. `FriSoundnessHyp` states, as an explicit hypothesis, the provable bound of Ben-Sasson, Carmon,
   Ishai, Kopparty and Saraf, *Proximity Gaps for Reed-Solomon Codes* (FOCS 2020, ePrint 2020/654,
   version of 3 July 2021), Lemma 8.2 and Theorem 8.3, with the usual grinding model on the query
   term. A prover without correlated agreement of density `α = √ρ(1 + 1/2m)` is accepted with
   probability at most

       ε_FRI = (m + ½)^7 |D|² / (2 ρ^{3/2} |F|) + (2m + 1)(|D| + 1) Σ l^{(i)} / (√ρ |F|) + 2^{-γ} α^s.

   The first two terms (the commit phase) do not shrink with queries or grinding.
3. The bound evaluated at one fixed parameter set. Outer stage: `|D| = 2^28`, `ρ = 2^{-7}`,
   `s = 14`, `γ = 32`, `|F| = p²` (challenges in `𝔽_{p²}`), `Σ l^{(i)} ≤ 64`. Inner stage:
   `|D| = 2^17` (`2^13` rows, blowup 16), `ρ = 2^{-4}`, `s = 32`, `γ = 16`.
   * `outer_eps_le`: at `m = 3`, `ε_FRI ≤ 2^{-49}`.
   * `outer_eps_ge`: for every `m ≥ 3`, `ε_FRI ≥ 2^{-50}`. The theorem certifies between 49
     and 50 bits for this outer stage, against 81 from `_stageProvable`.
   * `inner_eps_le`: at `m = 4`, `ε_FRI ≤ 2^{-72}` for the inner stage.

These are not the launch parameters. The launch verifier has 19 queries, extra blowup 5, a
domain of `2^23`, 20 grinding bits per commit round and 8 final searches of 25 bits, and no
inner stage. No theorem here evaluates the bound at those values.

The proximity statement itself is not proved here. Nothing here models the random oracle, the
adversary's number of hash queries, or the DEEP/ALI reduction from the AIR to FRI.
-/

namespace Shield.Soundness

open Shield.Field Real

/-! ### The contract's formulas -/

/-- `_stageConjectured`. -/
def stageConjectured (q e γ : ℕ) : ℕ := q * (e + 1) + γ

/-- `_stageProvable` (integer division, as in the contract). -/
def stageProvable (q e γ : ℕ) : ℕ := q * (e + 1) / 2 + γ

/-- The formulas at outer `(14, 6, 32)` give 130 / 81, at inner `(32, 3, 16)` give 144 / 80, and
the minimum of each pair is 130 / 80. -/
theorem reported_figures :
    stageConjectured 14 6 32 = 130 ∧ stageProvable 14 6 32 = 81 ∧
      stageConjectured 32 3 16 = 144 ∧ stageProvable 32 3 16 = 80 ∧
      min (stageConjectured 14 6 32) (stageConjectured 32 3 16) = 130 ∧
      min (stageProvable 14 6 32) (stageProvable 32 3 16) = 80 := by
  decide

/-- **The provable formula is the idealised Johnson query bound.** If one query accepts with
probability `α` where `α² ≤ ρ = 2^{-(e+1)}`, then `q` independent queries after `γ` bits of
grinding accept with probability at most `2^{-(⌊q(e+1)/2⌋ + γ)}`. -/
theorem johnson_query_bits {α : ℝ} (hα0 : 0 ≤ α) (q e γ : ℕ) (hα : α ^ 2 ≤ (1 / 2) ^ (e + 1)) :
    (1 / 2 : ℝ) ^ γ * α ^ q ≤ (1 / 2) ^ stageProvable q e γ := by
  set k := q * (e + 1)
  have hsq : (α ^ q) ^ 2 ≤ ((1 / 2 : ℝ) ^ (k / 2)) ^ 2 := by
    calc (α ^ q) ^ 2 = (α ^ 2) ^ q := by ring
      _ ≤ ((1 / 2 : ℝ) ^ (e + 1)) ^ q := by gcongr
      _ = (1 / 2 : ℝ) ^ k := by rw [← pow_mul, mul_comm]
      _ ≤ (1 / 2 : ℝ) ^ (2 * (k / 2)) :=
          pow_le_pow_of_le_one (by norm_num) (by norm_num) (Nat.mul_div_le k 2)
      _ = ((1 / 2 : ℝ) ^ (k / 2)) ^ 2 := by rw [← pow_mul, mul_comm]
  have hq : α ^ q ≤ (1 / 2 : ℝ) ^ (k / 2) :=
    (pow_le_pow_iff_left₀ (by positivity) (by positivity) two_ne_zero).mp hsq
  calc (1 / 2 : ℝ) ^ γ * α ^ q ≤ (1 / 2) ^ γ * (1 / 2) ^ (k / 2) := by gcongr
    _ = (1 / 2) ^ stageProvable q e γ := by rw [stageProvable, ← pow_add, add_comm]

/-- **The conjectured formula is the capacity query bound.** If one query accepts with probability
`α ≤ ρ = 2^{-(e+1)}`, the stage accepts with probability at most `2^{-(q(e+1) + γ)}`. -/
theorem capacity_query_bits {α : ℝ} (hα0 : 0 ≤ α) (q e γ : ℕ) (hα : α ≤ (1 / 2) ^ (e + 1)) :
    (1 / 2 : ℝ) ^ γ * α ^ q ≤ (1 / 2) ^ stageConjectured q e γ := by
  calc (1 / 2 : ℝ) ^ γ * α ^ q ≤ (1 / 2) ^ γ * ((1 / 2) ^ (e + 1)) ^ q := by gcongr
    _ = (1 / 2) ^ stageConjectured q e γ := by
        rw [stageConjectured, ← pow_mul, ← pow_add, add_comm, mul_comm (e + 1)]

/-! ### BCIKS20, Theorem 8.3, as a hypothesis -/

/-- The commit-phase error `ε_C` of BCIKS20 Lemma 8.2. `n = |D|`, `F = |F|`, `L = Σ l^{(i)}`. -/
noncomputable def epsC (n ρ F m L : ℝ) : ℝ :=
  (m + 1 / 2) ^ 7 * n ^ 2 / (2 * (ρ * √ρ) * F) + (2 * m + 1) * (n + 1) / √ρ * L / F

/-- The per-query acceptance bound `α = √ρ (1 + 1/2m)` of BCIKS20 Theorem 8.3. -/
noncomputable def alpha (ρ m : ℝ) : ℝ := √ρ * (1 + 1 / (2 * m))

/-- `ε_FRI` with `s` queries and `γ` grinding bits applied to the query term. -/
noncomputable def epsFRI (n ρ F m L : ℝ) (s γ : ℕ) : ℝ :=
  epsC n ρ F m L + (1 / 2) ^ γ * alpha ρ m ^ s

/-- **Named hypothesis (BCIKS20 Lemma 8.2 and Theorem 8.3 with grinding).** For every integer
`m ≥ 3`, a FRI prover whose committed functions do not have correlated agreement of density
`α = √ρ(1 + 1/2m)` with the Reed-Solomon code is accepted with probability at most `ε_FRI`.
The grinding factor on the query term is the standard proof-of-work model, not part of BCIKS20. -/
def FriSoundnessHyp (accept n ρ F L : ℝ) (s γ : ℕ) : Prop :=
  ∀ m : ℕ, 3 ≤ m → accept ≤ epsFRI n ρ F m L s γ

/-- Under the hypothesis, any evaluation of `ε_FRI` is a certified bound. -/
theorem certified_of_hyp {accept n ρ F L b : ℝ} {s γ m : ℕ} (h : FriSoundnessHyp accept n ρ F L s γ)
    (hm : 3 ≤ m) (hb : epsFRI n ρ F m L s γ ≤ b) : accept ≤ b :=
  (h m hm).trans hb

/-! ### The evaluated parameters -/

/-- Rational bounds on `√(1/128) ≈ 0.08839`. -/
theorem sqrt_rho_outer : (883 / 10000 : ℝ) ≤ √(1 / 128) ∧ √(1 / 128) ≤ 221 / 2500 := by
  constructor
  · rw [show (883 / 10000 : ℝ) = √((883 / 10000) ^ 2) by rw [Real.sqrt_sq (by norm_num)]]
    exact Real.sqrt_le_sqrt (by norm_num)
  · rw [show (221 / 2500 : ℝ) = √((221 / 2500) ^ 2) by rw [Real.sqrt_sq (by norm_num)]]
    exact Real.sqrt_le_sqrt (by norm_num)

theorem P_sq_real : ((P : ℝ)) ^ 2 = 18446744069414584321 ^ 2 := by
  norm_num [P]

/-- **Outer stage, what BCIKS20 certifies (upper bound).** At `m = 3`, with `Σ l^{(i)} ≤ 64`,
`ε_FRI ≤ 2^{-49}`. -/
theorem outer_eps_le {L : ℝ} (hL0 : 0 ≤ L) (hL : L ≤ 64) :
    epsFRI (2 ^ 28) (1 / 128) ((P : ℝ) ^ 2) 3 L 14 32 ≤ (1 / 2) ^ 49 := by
  obtain ⟨hs1, hs2⟩ := sqrt_rho_outer
  set s := √(1 / 128 : ℝ)
  have hs0 : 0 < s := lt_of_lt_of_le (by norm_num) hs1
  unfold epsFRI epsC alpha
  rw [P_sq_real]
  have t1 : (3 + 1 / 2 : ℝ) ^ 7 * (2 ^ 28) ^ 2 / (2 * (1 / 128 * s) * 18446744069414584321 ^ 2) ≤
      (3 + 1 / 2) ^ 7 * (2 ^ 28) ^ 2 / (2 * (1 / 128 * (883 / 10000)) * 18446744069414584321 ^ 2) := by
    gcongr
  have t2 : (2 * 3 + 1 : ℝ) * (2 ^ 28 + 1) / s * L / 18446744069414584321 ^ 2 ≤
      (2 * 3 + 1) * (2 ^ 28 + 1) / (883 / 10000) * 64 / 18446744069414584321 ^ 2 := by
    gcongr
  have t3 : (1 / 2 : ℝ) ^ 32 * (s * (1 + 1 / (2 * 3))) ^ 14 ≤
      (1 / 2) ^ 32 * (221 / 2500 * (1 + 1 / (2 * 3))) ^ 14 := by
    gcongr
  have num : (3 + 1 / 2 : ℝ) ^ 7 * (2 ^ 28) ^ 2 /
        (2 * (1 / 128 * (883 / 10000)) * 18446744069414584321 ^ 2) +
      (2 * 3 + 1) * (2 ^ 28 + 1) / (883 / 10000) * 64 / 18446744069414584321 ^ 2 +
      (1 / 2) ^ 32 * (221 / 2500 * (1 + 1 / (2 * 3))) ^ 14 ≤ (1 / 2) ^ 49 := by
    norm_num
  linarith

/-- **Outer stage, what BCIKS20 cannot certify (lower bound).** For every `m ≥ 3` and `L ≥ 0`,
`ε_FRI ≥ 2^{-50}`: the commit-phase term alone exceeds it. Theorem 8.3 certifies at most 50
bits for the outer stage at these parameters. -/
theorem outer_eps_ge {m : ℝ} (hm : 3 ≤ m) {L : ℝ} (hL0 : 0 ≤ L) :
    (1 / 2 : ℝ) ^ 50 ≤ epsFRI (2 ^ 28) (1 / 128) ((P : ℝ) ^ 2) m L 14 32 := by
  obtain ⟨hs1, hs2⟩ := sqrt_rho_outer
  set s := √(1 / 128 : ℝ)
  have hs0 : 0 < s := lt_of_lt_of_le (by norm_num) hs1
  have hm0 : 0 < m := by linarith
  unfold epsFRI epsC alpha
  rw [P_sq_real]
  have t1 : (3 + 1 / 2 : ℝ) ^ 7 * (2 ^ 28) ^ 2 /
        (2 * (1 / 128 * (221 / 2500)) * 18446744069414584321 ^ 2) ≤
      (m + 1 / 2) ^ 7 * (2 ^ 28) ^ 2 / (2 * (1 / 128 * s) * 18446744069414584321 ^ 2) := by
    gcongr
  have t2 : 0 ≤ (2 * m + 1) * (2 ^ 28 + 1) / s * L / 18446744069414584321 ^ 2 := by positivity
  have t3 : 0 ≤ (1 / 2 : ℝ) ^ 32 * (s * (1 + 1 / (2 * m))) ^ 14 := by positivity
  have num : (1 / 2 : ℝ) ^ 50 ≤ (3 + 1 / 2 : ℝ) ^ 7 * (2 ^ 28) ^ 2 /
      (2 * (1 / 128 * (221 / 2500)) * 18446744069414584321 ^ 2) := by
    norm_num
  linarith

/-- `√(1/16) = 1/4`. -/
theorem sqrt_rho_inner : √(1 / 16 : ℝ) = 1 / 4 := by
  rw [show (1 / 16 : ℝ) = (1 / 4) ^ 2 by norm_num, Real.sqrt_sq (by norm_num)]

/-- **Inner stage.** At `m = 4`, with `Σ l^{(i)} ≤ 64`, `ε_FRI ≤ 2^{-72}`. -/
theorem inner_eps_le {L : ℝ} (hL : L ≤ 64) :
    epsFRI (2 ^ 17) (1 / 16) ((P : ℝ) ^ 2) 4 L 32 16 ≤ (1 / 2) ^ 72 := by
  unfold epsFRI epsC alpha
  rw [P_sq_real, sqrt_rho_inner]
  have t2 : (2 * 4 + 1 : ℝ) * (2 ^ 17 + 1) / (1 / 4) * L / 18446744069414584321 ^ 2 ≤
      (2 * 4 + 1) * (2 ^ 17 + 1) / (1 / 4) * 64 / 18446744069414584321 ^ 2 := by
    gcongr
  have num : (4 + 1 / 2 : ℝ) ^ 7 * (2 ^ 17) ^ 2 / (2 * (1 / 16 * (1 / 4)) * 18446744069414584321 ^ 2) +
      (2 * 4 + 1) * (2 ^ 17 + 1) / (1 / 4) * 64 / 18446744069414584321 ^ 2 +
      (1 / 2) ^ 16 * (1 / 4 * (1 + 1 / (2 * 4))) ^ 32 ≤ (1 / 2) ^ 72 := by
    norm_num
  linarith

end Shield.Soundness
