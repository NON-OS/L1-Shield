import Shield.Field.Basic
import Mathlib.FieldTheory.Finite.Basic

/-!
# Goldilocks arithmetic as the contracts implement it

One-for-one models of `StarkFieldExt.fpAdd`, `fpSub`, `fpNeg`, `fpMul`, `fpPow`, `fpInv` (with its
addition chain and `_pow2`) and of `Goldilocks.isCanonicalLimb` / `isCanonicalDigest`
(`contracts/shield/verifier/StarkFieldExt.sol`, `contracts/shield/libraries/Goldilocks.sol`).

## The EVM model

Words are natural numbers. `ADDMOD` and `MULMOD` with a nonzero modulus compute
`(a + b) mod m` and `(a · b) mod m` over the integers, without reduction mod `2^256` of the
intermediate, and the models below compute the same. Solidity's checked `P - b` reverts when
`b > P`. The model uses truncated subtraction and every theorem about it assumes `b ≤ P` (in particular
every canonical `b`), where the two agree. Shifts and masks are `>>>` and `&&&` on `ℕ`, which agree
with the EVM on words below `2^256`.

## The results

For every theorem, "canonical" means `< P`. Each operation returns a canonical word whose image in
`𝔽_p` is the field result, so it returns *the* canonical representative of the field result
(`ZMod.val`). `fpInv` returns `a^(P-2) mod P`, which is `a⁻¹` for `a ≢ 0` and `0` for `a ≡ 0`.
-/

namespace Shield.Arith

open Shield.Field

/-- EVM `ADDMOD` for a nonzero modulus. -/
def addmod (a b m : ℕ) : ℕ := (a + b) % m

/-- EVM `MULMOD` for a nonzero modulus. -/
def mulmod (a b m : ℕ) : ℕ := (a * b) % m

/-- `StarkFieldExt.fpAdd`. -/
def fpAdd (a b : ℕ) : ℕ := addmod a b P

/-- `StarkFieldExt.fpSub`: `addmod(a, P - b, P)`. Solidity reverts if `b > P`. -/
def fpSub (a b : ℕ) : ℕ := addmod a (P - b) P

/-- `StarkFieldExt.fpNeg`: `a == 0 ? 0 : P - a`. -/
def fpNeg (a : ℕ) : ℕ := if a = 0 then 0 else P - a

/-- `StarkFieldExt.fpMul`. -/
def fpMul (a b : ℕ) : ℕ := mulmod a b P

/-- `StarkFieldExt._pow2`: `k` squarings, `x ↦ x^(2^k)`. -/
def pow2 (x : ℕ) : ℕ → ℕ
  | 0 => x
  | k + 1 => pow2 (mulmod x x P) k

/-- `StarkFieldExt.fpInv`, the addition chain for `P - 2 = (2^31 - 1)·2^33 + (2^32 - 1)`,
transcribed line by line. -/
def fpInv (a : ℕ) : ℕ :=
  let a1 := a % P
  let a2 := mulmod (pow2 a1 1) a1 P
  let a3 := mulmod (pow2 a2 1) a1 P
  let a6 := mulmod (pow2 a3 3) a3 P
  let a7 := mulmod (pow2 a6 1) a1 P
  let a14 := mulmod (pow2 a7 7) a7 P
  let a15 := mulmod (pow2 a14 1) a1 P
  let a30 := mulmod (pow2 a15 15) a15 P
  let a31 := mulmod (pow2 a30 1) a1 P
  let a32 := mulmod (pow2 a31 1) a1 P
  mulmod (pow2 a31 33) a32 P

/-- The loop of `StarkFieldExt.fpPow` after `acc = 1; base %= P`:
`if (exp & 1 == 1) acc = mulmod(acc, base, P); base = mulmod(base, base, P); exp >>= 1;`. -/
def powLoop (acc base exp : ℕ) : ℕ :=
  if exp = 0 then acc
  else
    powLoop (if exp &&& 1 = 1 then mulmod acc base P else acc) (mulmod base base P) (exp >>> 1)
termination_by exp
decreasing_by rw [Nat.shiftRight_eq_div_pow]; omega

/-- `StarkFieldExt.fpPow`. -/
def fpPow (base exp : ℕ) : ℕ := powLoop 1 (base % P) exp

/-- `Goldilocks.isCanonicalLimb`. -/
def isCanonicalLimb (v : ℕ) : Bool := decide (v < P)

/-- `Goldilocks.limb`: `(digest >> 64 i) & 0xFFFFFFFFFFFFFFFF`. -/
def limb (d i : ℕ) : ℕ := (d >>> (64 * i)) &&& 0xFFFFFFFFFFFFFFFF

/-- `Goldilocks.isCanonicalDigest`, transcribed: the top limb is `v >> 192` with no mask. -/
def isCanonicalDigest (v : ℕ) : Bool :=
  decide ((v &&& 0xFFFFFFFFFFFFFFFF) < P) && decide (((v >>> 64) &&& 0xFFFFFFFFFFFFFFFF) < P) &&
    decide (((v >>> 128) &&& 0xFFFFFFFFFFFFFFFF) < P) && decide ((v >>> 192) < P)

/-! ### Casting lemmas -/

theorem P_pos : 0 < P := by norm_num [P]

@[simp] theorem cast_addmod (a b : ℕ) : ((addmod a b P : ℕ) : Fp) = a + b := by
  simp [addmod, ZMod.natCast_mod]

@[simp] theorem cast_mulmod (a b : ℕ) : ((mulmod a b P : ℕ) : Fp) = a * b := by
  simp [mulmod, ZMod.natCast_mod]

theorem addmod_lt (a b : ℕ) : addmod a b P < P := Nat.mod_lt _ P_pos

theorem mulmod_lt (a b : ℕ) : mulmod a b P < P := Nat.mod_lt _ P_pos

/-- A canonical word is determined by its image in `𝔽_p`: it is that image's `val`. -/
theorem eq_val_of_lt {r : ℕ} {y : Fp} (hr : r < P) (hy : (r : Fp) = y) : r = y.val := by
  rw [← hy, ZMod.val_cast_of_lt hr]

/-! ### `isCanonical` -/

/-- **`isCanonicalLimb v` holds iff `v < P`.** -/
theorem isCanonicalLimb_iff (v : ℕ) : isCanonicalLimb v = true ↔ v < P := by
  simp [isCanonicalLimb]

/-- Canonical words are in bijection with `𝔽_p` (inverse `ZMod.val`). -/
def canonicalEquiv : {v : ℕ // isCanonicalLimb v = true} ≃ Fp where
  toFun v := (v.1 : Fp)
  invFun x := ⟨x.val, (isCanonicalLimb_iff _).mpr (ZMod.val_lt x)⟩
  left_inv v := Subtype.ext (ZMod.val_cast_of_lt ((isCanonicalLimb_iff _).mp v.2))
  right_inv x := ZMod.natCast_zmod_val x

theorem limb_eq (d i : ℕ) : limb d i = d / 2 ^ (64 * i) % 2 ^ 64 := by
  rw [limb, show (0xFFFFFFFFFFFFFFFF : ℕ) = 2 ^ 64 - 1 by norm_num,
    Nat.and_two_pow_sub_one_eq_mod, Nat.shiftRight_eq_div_pow]

/-- **`isCanonicalDigest` checks the four 64-bit limbs**, for every 256-bit word. The top limb is
read without a mask, which is the same limb because `v < 2^256`. -/
theorem isCanonicalDigest_iff {v : ℕ} (hv : v < 2 ^ 256) :
    isCanonicalDigest v = true ↔ ∀ i < 4, limb v i < P := by
  have h0 : v &&& 0xFFFFFFFFFFFFFFFF = limb v 0 := by simp [limb]
  have h1 : (v >>> 64) &&& 0xFFFFFFFFFFFFFFFF = limb v 1 := by simp [limb]
  have h2 : (v >>> 128) &&& 0xFFFFFFFFFFFFFFFF = limb v 2 := by simp [limb]
  have h3 : v >>> 192 = limb v 3 := by
    rw [limb_eq, Nat.shiftRight_eq_div_pow, Nat.mod_eq_of_lt]
    rw [Nat.div_lt_iff_lt_mul (by positivity)]
    calc v < 2 ^ 256 := hv
      _ = 2 ^ 64 * 2 ^ (64 * 3) := by norm_num
  simp only [isCanonicalDigest, h0, h1, h2, h3, Bool.and_eq_true, decide_eq_true_eq]
  constructor
  · rintro ⟨⟨⟨a, b⟩, c⟩, d⟩ i hi
    match i, hi with
    | 0, _ => exact a
    | 1, _ => exact b
    | 2, _ => exact c
    | 3, _ => exact d
  · intro h
    exact ⟨⟨⟨h 0 (by norm_num), h 1 (by norm_num)⟩, h 2 (by norm_num)⟩, h 3 (by norm_num)⟩

/-! ### Add, sub, neg, mul -/

theorem fpAdd_cast (a b : ℕ) : (fpAdd a b : Fp) = a + b := cast_addmod a b
theorem fpAdd_lt (a b : ℕ) : fpAdd a b < P := addmod_lt a b

/-- **`fpAdd` returns the canonical representative of `a + b`** (any inputs). -/
theorem fpAdd_spec (a b : ℕ) : fpAdd a b = ((a : Fp) + b).val :=
  eq_val_of_lt (fpAdd_lt a b) (fpAdd_cast a b)

theorem fpMul_cast (a b : ℕ) : (fpMul a b : Fp) = a * b := cast_mulmod a b
theorem fpMul_lt (a b : ℕ) : fpMul a b < P := mulmod_lt a b

/-- **`fpMul` returns the canonical representative of `a · b`** (any inputs). -/
theorem fpMul_spec (a b : ℕ) : fpMul a b = ((a : Fp) * b).val :=
  eq_val_of_lt (fpMul_lt a b) (fpMul_cast a b)

theorem cast_P_sub {b : ℕ} (hb : b ≤ P) : ((P - b : ℕ) : Fp) = -b := by
  rw [Nat.cast_sub hb, ZMod.natCast_self, zero_sub]

theorem fpSub_cast (a : ℕ) {b : ℕ} (hb : b ≤ P) : (fpSub a b : Fp) = a - b := by
  rw [fpSub, cast_addmod, cast_P_sub hb, sub_eq_add_neg]

theorem fpSub_lt (a b : ℕ) : fpSub a b < P := addmod_lt _ _

/-- **`fpSub` returns the canonical representative of `a − b`** whenever `b ≤ P`, the range in
which Solidity's `P - b` does not revert. -/
theorem fpSub_spec (a : ℕ) {b : ℕ} (hb : b ≤ P) : fpSub a b = ((a : Fp) - b).val :=
  eq_val_of_lt (fpSub_lt a b) (fpSub_cast a hb)

theorem fpNeg_cast {a : ℕ} (ha : a < P) : (fpNeg a : Fp) = -a := by
  unfold fpNeg
  split_ifs with h
  · simp [h]
  · exact cast_P_sub ha.le

theorem fpNeg_lt {a : ℕ} (ha : a < P) : fpNeg a < P := by
  unfold fpNeg; split_ifs with h
  · exact P_pos
  · omega

/-- **`fpNeg` returns the canonical representative of `−a`** for canonical `a`. -/
theorem fpNeg_spec {a : ℕ} (ha : a < P) : fpNeg a = (-(a : Fp)).val :=
  eq_val_of_lt (fpNeg_lt ha) (fpNeg_cast ha)

/-! ### Powers and the inverse -/

theorem pow2_cast (x k : ℕ) : (pow2 x k : Fp) = (x : Fp) ^ 2 ^ k := by
  induction k generalizing x with
  | zero => simp [pow2]
  | succ k ih => rw [pow2, ih, cast_mulmod, ← sq, ← pow_mul, ← pow_succ']

theorem pow2_lt {x : ℕ} (hx : x < P) (k : ℕ) : pow2 x k < P := by
  induction k generalizing x with
  | zero => exact hx
  | succ k ih => exact ih (mulmod_lt x x)

/-- `a^(P-2) = a⁻¹` in `𝔽_p`, including `a = 0`. -/
theorem pow_P_sub_two (a : Fp) : a ^ (P - 2) = a⁻¹ := by
  rcases eq_or_ne a 0 with rfl | ha
  · rw [inv_zero, zero_pow (by norm_num [P])]
  · refine (eq_inv_of_mul_eq_one_left ?_)
    rw [← pow_succ, show P - 2 + 1 = P - 1 by norm_num [P]]
    exact ZMod.pow_card_sub_one_eq_one ha

/-- The chain in `fpInv` computes `a^(P-2)`. -/
theorem fpInv_cast (a : ℕ) : (fpInv a : Fp) = (a : Fp) ^ (P - 2) := by
  simp only [fpInv, cast_mulmod, pow2_cast, ZMod.natCast_mod]
  rw [show P - 2 = 18446744069414584319 from rfl]
  ring

theorem fpInv_lt (a : ℕ) : fpInv a < P := mulmod_lt _ _

/-- **`fpInv` returns the canonical representative of `a⁻¹`** (and `0` for `a ≡ 0 mod P`), for
every word `a`. -/
theorem fpInv_spec (a : ℕ) : fpInv a = ((a : Fp)⁻¹).val :=
  eq_val_of_lt (fpInv_lt a) (by rw [fpInv_cast, pow_P_sub_two])

theorem powLoop_cast (acc base exp : ℕ) :
    (powLoop acc base exp : Fp) = acc * (base : Fp) ^ exp := by
  induction exp using Nat.strong_induction_on generalizing acc base with
  | _ e ih =>
    rw [powLoop]
    split_ifs with h0 h1
    · simp [h0]
    · rw [Nat.and_one_is_mod] at h1
      rw [ih _ (by rw [Nat.shiftRight_eq_div_pow]; omega), cast_mulmod, cast_mulmod,
        Nat.shiftRight_eq_div_pow, ← sq, ← pow_mul, mul_assoc, ← pow_succ']
      congr 2
      omega
    · rw [Nat.and_one_is_mod] at h1
      rw [ih _ (by rw [Nat.shiftRight_eq_div_pow]; omega), cast_mulmod,
        Nat.shiftRight_eq_div_pow, ← sq, ← pow_mul]
      congr 2
      omega

theorem powLoop_lt {acc base : ℕ} (ha : acc < P) (exp : ℕ) : powLoop acc base exp < P := by
  induction exp using Nat.strong_induction_on generalizing acc base with
  | _ e ih =>
    rw [powLoop]
    split_ifs with h0 h1
    · exact ha
    · exact ih _ (by rw [Nat.shiftRight_eq_div_pow]; omega) (mulmod_lt _ _)
    · exact ih _ (by rw [Nat.shiftRight_eq_div_pow]; omega) ha

/-- **`fpPow` returns the canonical representative of `base^exp`**, for every pair of words. -/
theorem fpPow_spec (base exp : ℕ) : fpPow base exp = ((base : Fp) ^ exp).val :=
  eq_val_of_lt (powLoop_lt (by norm_num [P]) exp)
    (by rw [fpPow, powLoop_cast, ZMod.natCast_mod, Nat.cast_one, one_mul])

end Shield.Arith
