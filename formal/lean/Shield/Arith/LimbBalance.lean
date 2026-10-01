import Shield.Field.Basic
import Mathlib.Algebra.Order.BigOperators.Group.Finset
import Mathlib.Tactic.Linarith

/-!
# Limb conservation for the pool's 32-bit limbs

The launch circuit represents each
leg's amount by two range-checked 32-bit limbs and carries conservation limb by limb:

* per leg: `value = lo + 2^32 hi`, `room = 2^32 − 2 − hi`, with `lo`, `hi`, `room` each in a
  32-bit range segment.
* per intent, over `n` legs with signs `σ_j = ±1` (inputs `+`, outputs `−`): running sums
  `S_lo = Σ σ_j lo_j`, `S_hi = Σ σ_j hi_j`, and on the closing row `S_lo = c·2^32`, `S_hi = −c`,
  with the cell `c + 3` in a 3-bit segment, so `c ∈ [−3, 4]`. The circuit has `n = 6`
  (18 32-bit segments per intent: `lo`, `hi`, `room` of six legs).

Every constraint holds in `𝔽_p`. This file proves that, under the range checks, the constraints
say over the integers what they should:

* `room_forces_hi_bound`: `room + hi ≡ 2^32 − 2` with both below `2^32` gives `hi ≤ 2^32 − 2`.
* `value_le`: `lo + 2^32 hi ≤ p − 2 < p`; `value_injective` and `bounded_value_zero_mod_p`:
  field equality of bounded values is equality over `ℕ` (the "dummy worth p" case).
* `limbwise_conservation`: the two closing congruences imply `Σ σ_j v_j = 0` over `ℤ`, and
  `closes_iff_balances`: the closing row is satisfiable with `c ∈ [−3, 4]` iff the integer sums
  balance with that carry.
* `modular_balance_alone_creates_value`: without the limb bounds, a transfer balancing only mod `p`
  pays out `p` more than it takes in.
-/

namespace Shield.Limbs

open Shield.Field Finset

/-- `2^32`. -/
abbrev B : ℕ := 2 ^ 32

theorem P_eq_B : P = B * B - B + 1 := by norm_num [P]

/-- A leg's two limbs. -/
structure Leg where
  lo : ℕ
  hi : ℕ

/-- The integer value of a leg. -/
def Leg.value (l : Leg) : ℕ := l.lo + B * l.hi

/-- The range checks: `lo < 2^32`, `hi ≤ 2^32 − 2`. -/
def Leg.Bounded (l : Leg) : Prop := l.lo < B ∧ l.hi ≤ B - 2

/-- **The room constraint forces the high-limb bound.** If `room + hi ≡ 2^32 − 2 (mod p)` with
`room` and `hi` both range-checked to 32 bits, then `hi ≤ 2^32 − 2` (and `room = 2^32 − 2 − hi`). -/
theorem room_forces_hi_bound {hi room : ℕ} (hhi : hi < B) (hroom : room < B)
    (h : ((room + hi : ℕ) : Fp) = ((B - 2 : ℕ) : Fp)) : hi ≤ B - 2 ∧ room = B - 2 - hi := by
  have hlt : room + hi < P := by norm_num [P] at *; omega
  have hlt' : B - 2 < P := by norm_num [P]
  have := congrArg ZMod.val h
  rw [ZMod.val_cast_of_lt hlt, ZMod.val_cast_of_lt hlt'] at this
  omega

/-- **A bounded value is at most `p − 2`.** -/
theorem value_le {l : Leg} (hl : l.Bounded) : l.value ≤ P - 2 := by
  obtain ⟨hlo, hhi⟩ := hl
  have : B * l.hi ≤ B * (B - 2) := Nat.mul_le_mul_left B hhi
  unfold Leg.value
  norm_num [P] at *
  omega

theorem value_lt {l : Leg} (hl : l.Bounded) : l.value < P :=
  lt_of_le_of_lt (value_le hl) (by norm_num [P])

/-- **Field equality of bounded values is equality over `ℕ`.** -/
theorem value_injective {l l' : Leg} (hl : l.Bounded) (hl' : l'.Bounded)
    (h : (l.value : Fp) = (l'.value : Fp)) : l.value = l'.value := by
  have := congrArg ZMod.val h
  rwa [ZMod.val_cast_of_lt (value_lt hl), ZMod.val_cast_of_lt (value_lt hl')] at this

/-- **A bounded value that is zero in the field is zero** (the dummy-input case). -/
theorem bounded_value_zero_mod_p {l : Leg} (hl : l.Bounded) (h : (l.value : Fp) = 0) :
    l.value = 0 := by
  have := congrArg ZMod.val h
  rwa [ZMod.val_cast_of_lt (value_lt hl), ZMod.val_zero] at this

/-- The bound is tight: the limbs `(1, 2^32 − 1)`, just outside it, are worth `p` and are zero in
the field. This is the dummy the fix refuses. -/
theorem unbounded_dummy_worth_p : (⟨1, B - 1⟩ : Leg).value = P ∧
    (((⟨1, B - 1⟩ : Leg).value : ℕ) : Fp) = 0 := by
  have h : (⟨1, B - 1⟩ : Leg).value = P := by norm_num [Leg.value, P]
  exact ⟨h, by rw [h, ZMod.natCast_self]⟩

/-! ### Conservation -/

section Balance

variable {n : ℕ} (σ : Fin n → ℤ) (legs : Fin n → Leg)

/-- Signed low-limb sum. -/
def sLo : ℤ := ∑ j, σ j * (legs j).lo

/-- Signed high-limb sum. -/
def sHi : ℤ := ∑ j, σ j * (legs j).hi

/-- Signed value sum. -/
def sVal : ℤ := ∑ j, σ j * (legs j).value

theorem sVal_eq : sVal σ legs = sLo σ legs + B * sHi σ legs := by
  simp only [sVal, sLo, sHi, Leg.value, mul_sum, ← sum_add_distrib]
  refine sum_congr rfl fun j _ ↦ ?_
  push_cast; ring

variable {σ legs}

theorem abs_signed_le (hσ : ∀ j, σ j = 1 ∨ σ j = -1) (a : Fin n → ℕ) (M : ℕ)
    (ha : ∀ j, a j ≤ M) : |∑ j, σ j * (a j : ℤ)| ≤ n * M := by
  calc |∑ j, σ j * (a j : ℤ)| ≤ ∑ j, |σ j * (a j : ℤ)| := abs_sum_le_sum_abs _ _
    _ ≤ ∑ _j : Fin n, (M : ℤ) := by
        refine sum_le_sum fun j _ ↦ ?_
        rcases hσ j with h | h <;> simp [h, ha j]
    _ = n * M := by simp

/-- If `m ∣ x − y` and `|x − y| < m` then `x = y`. -/
theorem eq_of_dvd_of_abs_lt {m x y : ℤ} (hd : m ∣ x - y) (hl : |x - y| < m) : x = y :=
  sub_eq_zero.mp (Int.eq_zero_of_abs_lt_dvd hd hl)

/-- **Limbwise conservation.** With every leg range-checked (`lo < 2^32`, `hi ≤ 2^32 − 2`), signs
`±1`, a carry `c ∈ [−3, 4]`, `(n + 4)·2^32 < p` (true for the circuit's `n = 6`), and the two
closing constraints in `𝔽_p`, `S_lo ≡ c·2^32` and `S_hi ≡ −c`, the signed values balance over
`ℤ`: `Σ σ_j v_j = 0`. Both congruences are equalities over `ℤ`. -/
theorem limbwise_conservation (hσ : ∀ j, σ j = 1 ∨ σ j = -1) (hb : ∀ j, (legs j).Bounded)
    {c : ℤ} (hc : -3 ≤ c ∧ c ≤ 4) (hn : (n + 4) * B < P)
    (hlo : ((sLo σ legs : ℤ) : Fp) = ((c * B : ℤ) : Fp))
    (hhi : ((sHi σ legs : ℤ) : Fp) = ((-c : ℤ) : Fp)) :
    sLo σ legs = c * B ∧ sHi σ legs = -c ∧ sVal σ legs = 0 := by
  have hP : ((n : ℤ) + 4) * (B : ℤ) < ((P : ℕ) : ℤ) := by exact_mod_cast hn
  have bLo := abs_signed_le hσ (fun j ↦ (legs j).lo) B fun j ↦ (hb j).1.le
  have bHi := abs_signed_le hσ (fun j ↦ (legs j).hi) B fun j ↦ (hb j).2.trans (Nat.sub_le _ _)
  have hB : (0 : ℤ) < B := by norm_num
  have hlo' : sLo σ legs = c * B := by
    refine eq_of_dvd_of_abs_lt ((ZMod.intCast_eq_intCast_iff_dvd_sub _ _ _).mp hlo.symm) ?_
    have hcB : |c * (B : ℤ)| ≤ 4 * B := by
      rw [abs_mul, abs_of_pos hB]; gcongr; exact abs_le.mpr ⟨by linarith, hc.2⟩
    calc |sLo σ legs - c * B| ≤ |sLo σ legs| + |c * (B : ℤ)| := abs_sub _ _
      _ ≤ n * B + 4 * B := add_le_add bLo hcB
      _ < P := by linarith
  have hhi' : sHi σ legs = -c := by
    refine eq_of_dvd_of_abs_lt ((ZMod.intCast_eq_intCast_iff_dvd_sub _ _ _).mp hhi.symm) ?_
    calc |sHi σ legs - -c| ≤ |sHi σ legs| + |c| := by rw [sub_neg_eq_add]; exact abs_add_le _ _
      _ ≤ n * B + 4 := add_le_add bHi (abs_le.mpr ⟨by linarith, hc.2⟩)
      _ < P := by linarith
  refine ⟨hlo', hhi', ?_⟩
  rw [sVal_eq, hlo', hhi']; ring

/-- **Completeness: a balanced transfer has an integer carry.** If `Σ σ_j v_j = 0` over `ℤ`, then
`c = S_lo / 2^32` satisfies `S_lo = c·2^32` and `S_hi = −c`, and it is the only such integer. -/
theorem balanced_has_carry (h : sVal σ legs = 0) :
    ∃! c : ℤ, sLo σ legs = c * B ∧ sHi σ legs = -c := by
  rw [sVal_eq] at h
  refine ⟨-sHi σ legs, ⟨by linarith, by ring⟩, fun c hc ↦ by linarith [hc.2]⟩

/-- **The closing row is satisfiable iff the integer sums balance.** For a carry `c ∈ [−3, 4]`,
the two closing constraints hold in `𝔽_p` iff `S_lo = c·2^32` and `S_hi = −c` over `ℤ`, and these
hold for some integer `c` iff `Σ σ_j v_j = 0`. -/
theorem closes_iff_balances (hσ : ∀ j, σ j = 1 ∨ σ j = -1) (hb : ∀ j, (legs j).Bounded)
    {c : ℤ} (hc : -3 ≤ c ∧ c ≤ 4) (hn : (n + 4) * B < P) :
    ((((sLo σ legs : ℤ) : Fp) = ((c * B : ℤ) : Fp)) ∧ (((sHi σ legs : ℤ) : Fp) = ((-c : ℤ) : Fp)))
      ↔ (sLo σ legs = c * B ∧ sHi σ legs = -c) := by
  constructor
  · rintro ⟨h1, h2⟩
    obtain ⟨a, b, -⟩ := limbwise_conservation hσ hb hc hn h1 h2
    exact ⟨a, b⟩
  · rintro ⟨h1, h2⟩
    exact ⟨by rw [h1], by rw [h2]⟩

theorem balances_of_closes {c : ℤ} (h : sLo σ legs = c * B ∧ sHi σ legs = -c) :
    sVal σ legs = 0 := by
  rw [sVal_eq, h.1, h.2]; ring

/-- The circuit's instance: six legs. -/
theorem six_legs_fit : (6 + 4) * B < P := by norm_num [P]

end Balance

/-- **Modular balance alone creates value.** With one input of value `1` and one output of value
`p + 1` (a valid `u64` amount), the value-level constraint `Σ σ_j v_j ≡ 0 (mod p)` holds, while
over `ℤ` the transfer pays out `p` more than it takes in. The output's high limb is `2^32 − 1`, so
the fixed circuit's bound `hi ≤ 2^32 − 2` refuses it. -/
theorem modular_balance_alone_creates_value :
    let legs : Fin 2 → Leg := ![⟨1, 0⟩, ⟨2, B - 1⟩]
    let σ : Fin 2 → ℤ := ![1, -1]
    (legs 1).value = P + 1 ∧ (legs 1).value < 2 ^ 64 ∧
      ((sVal σ legs : ℤ) : Fp) = 0 ∧ sVal σ legs = -(P : ℤ) ∧ ¬ (legs 1).Bounded := by
  intro legs σ
  have hv : (legs 1).value = P + 1 := by norm_num [legs, Leg.value, P]
  have hs : sVal σ legs = -(P : ℤ) := by
    simp only [sVal, Fin.sum_univ_two]
    norm_num [legs, σ, Leg.value, P]
  refine ⟨hv, by rw [hv]; norm_num [P], ?_, hs, ?_⟩
  · rw [hs, Int.cast_neg, Int.cast_natCast, ZMod.natCast_self, neg_zero]
  · rintro ⟨-, h⟩
    norm_num [legs] at h

end Shield.Limbs
