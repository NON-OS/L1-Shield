/-
Copyright (c) 2026 NØNOS. All rights reserved.

# The fee-router split

A model of `ShieldFeeRouter.distribute` (contracts/shield/ShieldFeeRouter.sol:132-152) and of the
split invariant `_checkSplit` (ShieldFeeRouter.sol:219-222).

`distribute` computes `toStaking = ⌊total · stakingBps / 10⁴⌋`, `toTreasury = ⌊total · treasuryBps
/ 10⁴⌋` and, in an `unchecked` block, `toBurn = total - toStaking - toTreasury`: the burn share takes
the rounding remainder (ShieldFeeRouter.sol:34,136-142).

Main results.
* `split_sum` : the three parts sum to `total`, and the unchecked subtraction never wraps.
* `split_rounding` : staking and treasury are rounded down by less than one unit each, and burn
  exceeds its exact share by less than two units.
* `split_4000_3000_3000` : the configured split, with the rounding stated.
* `split_three` : the bound of two units is attained.
-/
import Mathlib.Tactic.NormNum

namespace Shield.Protocol.FeeRouter

/-- `BPS = 10_000` (ShieldFeeRouter.sol:25). -/
abbrev BPS : ℕ := 10000

/-- `_checkSplit` (ShieldFeeRouter.sol:219-222): the shares sum to `BPS`, treasury at most `5000`. -/
def CheckSplit (stakingBps treasuryBps burnBps : ℕ) : Prop :=
  stakingBps + treasuryBps + burnBps = BPS ∧ treasuryBps ≤ 5000

/-- The three amounts computed by `distribute` (ShieldFeeRouter.sol:136-142). The subtraction is
truncated here. `split_sum` proves it never truncates. -/
def split (total stakingBps treasuryBps : ℕ) : ℕ × ℕ × ℕ :=
  let toStaking := total * stakingBps / BPS
  let toTreasury := total * treasuryBps / BPS
  (toStaking, toTreasury, total - toStaking - toTreasury)

/-- Floor division by `BPS` loses less than one unit: `q · BPS ≤ a < q · BPS + BPS`. -/
theorem floor_bounds (a : ℕ) : a / BPS * BPS ≤ a ∧ a < a / BPS * BPS + BPS := by
  simp only [BPS]; omega

/-- **The parts sum to the input.** Whenever `stakingBps + treasuryBps ≤ BPS` (in
particular under `_checkSplit`), `toStaking + toTreasury ≤ total`, so the unchecked subtraction at
ShieldFeeRouter.sol:141 does not wrap, and `toStaking + toTreasury + toBurn = total`. -/
theorem split_sum {total s t : ℕ} (h : s + t ≤ BPS) :
    (split total s t).1 + (split total s t).2.1 ≤ total ∧
      (split total s t).1 + (split total s t).2.1 + (split total s t).2.2 = total := by
  have hst : total * s + total * t ≤ total * BPS := by
    rw [← Nat.mul_add]; exact Nat.mul_le_mul_left _ h
  have := floor_bounds (total * s)
  have := floor_bounds (total * t)
  simp only [split, BPS] at *
  omega

/-- **Rounding.** With `b = BPS - s - t` the burn share in bps: the staking and treasury amounts
are the exact shares rounded down, each by less than one unit, and the burn amount exceeds its exact
share `total · b / BPS` by at least `0` and less than `2` units. All inequalities are stated
multiplied by `BPS`, so they are exact. -/
theorem split_rounding {total s t : ℕ} (h : s + t ≤ BPS) :
    let r := split total s t
    (r.1 * BPS ≤ total * s ∧ total * s < r.1 * BPS + BPS) ∧
      (r.2.1 * BPS ≤ total * t ∧ total * t < r.2.1 * BPS + BPS) ∧
      (total * (BPS - s - t) ≤ r.2.2 * BPS ∧ r.2.2 * BPS < total * (BPS - s - t) + 2 * BPS) := by
  have hsum : total * s + total * t + total * (BPS - s - t) = total * BPS := by
    rw [← Nat.mul_add, ← Nat.mul_add]; congr 1; omega
  have hs := floor_bounds (total * s)
  have ht := floor_bounds (total * t)
  obtain ⟨hle, heq⟩ := split_sum (total := total) h
  simp only [split] at hle heq ⊢
  refine ⟨hs, ht, ?_, ?_⟩
  · calc total * (BPS - s - t)
        = total * BPS - total * s - total * t := by omega
      _ ≤ total * BPS - total * s / BPS * BPS - total * t / BPS * BPS := by omega
      _ = (total - total * s / BPS - total * t / BPS) * BPS := by
          rw [Nat.sub_mul, Nat.sub_mul]
  · calc (total - total * s / BPS - total * t / BPS) * BPS
        = total * BPS - total * s / BPS * BPS - total * t / BPS * BPS := by
          rw [Nat.sub_mul, Nat.sub_mul, Nat.mul_comm total]
      _ < total * (BPS - s - t) + 2 * BPS := by omega

/-- **The configured split, 4000 / 3000 / 3000.** It satisfies `_checkSplit`, the parts sum to
`total`, staking and treasury are `⌊0.4 · total⌋` and `⌊0.3 · total⌋`, and burn lies in
`[0.3 · total, 0.3 · total + 2)`, so it is never below the treasury part. -/
theorem split_4000_3000_3000 (total : ℕ) :
    let r := split total 4000 3000
    CheckSplit 4000 3000 3000 ∧
      r.1 + r.2.1 + r.2.2 = total ∧
      r.1 = total * 4000 / BPS ∧ r.2.1 = total * 3000 / BPS ∧
      total * 3000 ≤ r.2.2 * BPS ∧ r.2.2 * BPS < total * 3000 + 2 * BPS ∧
      r.2.1 ≤ r.2.2 := by
  obtain ⟨-, heq⟩ := split_sum (total := total) (s := 4000) (t := 3000) (by norm_num)
  obtain ⟨-, ⟨ht1, -⟩, hb1, hb2⟩ := split_rounding (total := total) (s := 4000) (t := 3000)
    (by norm_num)
  simp only [show BPS - 4000 - 3000 = 3000 by norm_num] at hb1 hb2
  refine ⟨by simp [CheckSplit], heq, rfl, rfl, hb1, hb2, ?_⟩
  -- treasury · BPS ≤ 3000 · total ≤ burn · BPS
  exact Nat.le_of_mul_le_mul_right (ht1.trans hb1) (by norm_num : 0 < BPS)

/-- **The two-unit bound is attained.** For `total = 3`: staking `1`, treasury `0`, burn `2`,
while `⌊0.3 · 3⌋ = 0`. -/
theorem split_three : split 3 4000 3000 = (1, 0, 2) ∧ 3 * 3000 / BPS = 0 := by decide

end Shield.Protocol.FeeRouter
