/-
Copyright (c) 2026 NØNOS. All rights reserved.

# The settler gate

A model of `SettlerGate.open` and `SettlerGate.inOpenSlot`
(contracts/shield/SettlerGate.sol:9-22) and of the gate in `ShieldedPool.settleBatch`
(contracts/shield/ShieldedPool.sol:395-398), with the constants `SETTLER_WINDOW = 24 hours`,
`SETTLEMENT_EPOCH = 24 hours` and `OPEN_SLOT = 1 hours` (ShieldedPool.sol:81-84).

Main results.
* `inOpenSlot_iff_slot` : `inOpenSlot` holds iff `nowTs` lies in a slot `[s, s + slot)` with
  `s ≡ epoch - slot (mod epoch)`.
* `exists_slot_within_epoch` : every instant `t` is followed, within one epoch, by the start of a
  whole open slot.
* `passes_in_slot` : within the slot anyone passes.
* `passes_iff_settler` : outside the settler window and the slot, only the settler passes.
* `anyone_passes_within_epoch` : no caller is kept out for longer than one epoch.
-/
import Mathlib.Tactic.NormNum

namespace Shield.Protocol.SettlerGate

/-- `SettlerGate.open` (SettlerGate.sol:9-17). Addresses are natural numbers, `address(0)` is `0`.
`lastSettlement + window` cannot overflow a `uint256`, since `lastSettlement` is a `uint64`. -/
def «open» (settler caller lastSettlement nowTs window : ℕ) : Bool :=
  if settler = 0 then true
  else if caller = settler then true
  else decide (lastSettlement + window ≤ nowTs)

/-- `SettlerGate.inOpenSlot` (SettlerGate.sol:20-22): `nowTs % epoch >= epoch - slot`. -/
def inOpenSlot (nowTs epoch slot : ℕ) : Bool := decide (epoch - slot ≤ nowTs % epoch)

/-- `SETTLER_WINDOW = 24 hours` (ShieldedPool.sol:81). -/
abbrev SETTLER_WINDOW : ℕ := 86400
/-- `SETTLEMENT_EPOCH = 24 hours` (ShieldedPool.sol:83). -/
abbrev SETTLEMENT_EPOCH : ℕ := 86400
/-- `OPEN_SLOT = 1 hours` (ShieldedPool.sol:84). -/
abbrev OPEN_SLOT : ℕ := 3600

/-- The gate of `settleBatch` (ShieldedPool.sol:395-398): the call proceeds iff
`open(settler, msg.sender, lastSettlement, block.timestamp, SETTLER_WINDOW)` or
`inOpenSlot(block.timestamp, SETTLEMENT_EPOCH, OPEN_SLOT)`. -/
def passes (settler caller lastSettlement nowTs : ℕ) : Bool :=
  «open» settler caller lastSettlement nowTs SETTLER_WINDOW ||
    inOpenSlot nowTs SETTLEMENT_EPOCH OPEN_SLOT

/-- A slot start: a timestamp congruent to `epoch - slot` modulo `epoch`. -/
def SlotStart (epoch slot s : ℕ) : Prop := s % epoch = epoch - slot

section General

variable {epoch slot : ℕ}

/-- The residue of `epoch · q + c` is `c` when `c < epoch`. -/
theorem mul_add_mod_of_lt {q c : ℕ} (hc : c < epoch) : (epoch * q + c) % epoch = c := by
  rw [Nat.mul_add_mod, Nat.mod_eq_of_lt hc]

/-- **Characterisation of the open slot.** For `0 < slot ≤ epoch`, `inOpenSlot u` holds iff `u`
lies in some `[s, s + slot)` with `s` a slot start. -/
theorem inOpenSlot_iff_slot (hslot : 0 < slot) (hse : slot ≤ epoch) (u : ℕ) :
    inOpenSlot u epoch slot = true ↔ ∃ s, SlotStart epoch slot s ∧ s ≤ u ∧ u < s + slot := by
  have hep : 0 < epoch := lt_of_lt_of_le hslot hse
  have hdm := Nat.div_add_mod u epoch
  have hr := Nat.mod_lt u hep
  simp only [inOpenSlot, decide_eq_true_eq, SlotStart]
  constructor
  · intro h
    refine ⟨epoch * (u / epoch) + (epoch - slot), ?_, by omega, by omega⟩
    exact mul_add_mod_of_lt (by omega)
  · rintro ⟨s, hs, hsu, hus⟩
    have hsd := Nat.div_add_mod s epoch
    -- `u = s + d` with `d < slot`, and `s mod epoch + d < epoch`, so `u mod epoch = s mod epoch + d`.
    obtain ⟨d, rfl⟩ : ∃ d, u = s + d := ⟨u - s, by omega⟩
    have hmod : (s + d) % epoch = epoch - slot + d := by
      calc (s + d) % epoch = (epoch * (s / epoch) + (s % epoch + d)) % epoch := by
            congr 1; omega
        _ = s % epoch + d := mul_add_mod_of_lt (by omega)
        _ = epoch - slot + d := by rw [hs]
    omega

/-- **Every instant is followed by a whole open slot within one epoch.** For `0 < slot ≤ epoch` and
any `t`, there is a slot start `s` with `t < s ≤ t + epoch`, and every `u ∈ [s, s + slot)` is in
the open slot. -/
theorem exists_slot_within_epoch (hslot : 0 < slot) (hse : slot ≤ epoch) (t : ℕ) :
    ∃ s, t < s ∧ s ≤ t + epoch ∧ SlotStart epoch slot s ∧
      ∀ u, s ≤ u → u < s + slot → inOpenSlot u epoch slot = true := by
  have hep : 0 < epoch := lt_of_lt_of_le hslot hse
  have hdm := Nat.div_add_mod t epoch
  have hr := Nat.mod_lt t hep
  have hstart : ∀ s, SlotStart epoch slot s →
      ∀ u, s ≤ u → u < s + slot → inOpenSlot u epoch slot = true :=
    fun s hs u h1 h2 => (inOpenSlot_iff_slot hslot hse u).2 ⟨s, hs, h1, h2⟩
  by_cases hlt : t % epoch < epoch - slot
  · -- the slot of the current epoch is still ahead
    refine ⟨epoch * (t / epoch) + (epoch - slot), by omega, by omega, ?_, hstart _ ?_⟩ <;>
      exact mul_add_mod_of_lt (by omega)
  · -- `t` is at or past this epoch's slot start: take the next epoch's
    refine ⟨epoch * (t / epoch + 1) + (epoch - slot), ?_, ?_, ?_, hstart _ ?_⟩
    · rw [Nat.mul_succ]; omega
    · rw [Nat.mul_succ]; omega
    all_goals exact mul_add_mod_of_lt (by omega)

end General

/-- The contract's open slot is the last hour of each UTC day: `82800 ≤ t mod 86400`. -/
theorem inOpenSlot_const_iff (t : ℕ) :
    inOpenSlot t SETTLEMENT_EPOCH OPEN_SLOT = true ↔ 82800 ≤ t % 86400 := by
  simp only [inOpenSlot, decide_eq_true_eq]; norm_num

/-- **Within the slot anyone passes**, whoever the settler and whenever the last settlement. -/
theorem passes_in_slot {settler caller last t : ℕ}
    (h : inOpenSlot t SETTLEMENT_EPOCH OPEN_SLOT = true) : passes settler caller last t = true := by
  simp [passes, h]

/-- **The settler always passes.** -/
theorem settler_passes {settler last t : ℕ} : passes settler settler last t = true := by
  unfold passes «open»; by_cases h : settler = 0 <;> simp [h]

/-- **With no settler appointed, anyone passes** (`settler == address(0)`, SettlerGate.sol:14). -/
theorem passes_of_no_settler {caller last t : ℕ} : passes 0 caller last t = true := by
  simp [passes, «open»]

/-- **After the settler window anyone passes.** -/
theorem passes_after_window {settler caller last t : ℕ} (h : last + SETTLER_WINDOW ≤ t) :
    passes settler caller last t = true := by
  unfold passes «open»; split_ifs <;> simp [h]

/-- **Outside the settler window and the slot, only the settler passes.** If a settler is
appointed, the window since the last settlement has not elapsed, and `t` is not in the open slot,
then the gate admits the settler and no other caller. -/
theorem passes_iff_settler {settler caller last t : ℕ} (hs : settler ≠ 0)
    (hw : t < last + SETTLER_WINDOW) (hslot : inOpenSlot t SETTLEMENT_EPOCH OPEN_SLOT = false) :
    passes settler caller last t = true ↔ caller = settler := by
  unfold passes «open»
  rw [hslot]
  by_cases hc : caller = settler
  · simp [hs, hc]
  · simp only [hs, hc, ite_false, Bool.or_false, decide_eq_true_eq, iff_false]; omega

/-- **Liveness.** Whatever the settler does, every caller passes the gate at some instant in
`(t, t + SETTLEMENT_EPOCH]`: the settler can keep an intent out for at most one epoch. -/
theorem anyone_passes_within_epoch (settler caller last t : ℕ) :
    ∃ u, t < u ∧ u ≤ t + SETTLEMENT_EPOCH ∧ passes settler caller last u = true := by
  obtain ⟨s, hts, hst, -, hin⟩ :=
    exists_slot_within_epoch (epoch := SETTLEMENT_EPOCH) (slot := OPEN_SLOT) (by norm_num)
      (by norm_num) t
  exact ⟨s, hts, hst, passes_in_slot (hin s le_rfl (by norm_num))⟩

end Shield.Protocol.SettlerGate
