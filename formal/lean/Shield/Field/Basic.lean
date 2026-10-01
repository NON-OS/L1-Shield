import Mathlib.NumberTheory.LucasPrimality
import Mathlib.NumberTheory.LegendreSymbol.Basic
import Mathlib.Tactic.ReduceModChar
import Mathlib.Tactic.NormNum.Prime

/-!
# The Goldilocks prime

`P = 0xFFFFFFFF00000001 = 2^64 - 2^32 + 1`, the modulus of `StarkFieldExt` and `Goldilocks`.

Primality is proved by a Lucas (Pratt) certificate: the witness `7` has multiplicative order
`P - 1`, checked against the factorisation `P - 1 = 2^32 · 3 · 5 · 17 · 257 · 65537`.
The modular powers are evaluated by `reduce_mod_char`, which calls norm_num's binary modular
exponentiation (`Mathlib.Tactic.NormNum.PowMod`) and leaves a kernel-checked proof term. The six
small primes are proved by `norm_num`.
-/

namespace Shield.Field

/-- The Goldilocks modulus, written as in the contracts. -/
def P : ℕ := 0xFFFFFFFF00000001

theorem P_eq : P = 2 ^ 64 - 2 ^ 32 + 1 := by norm_num [P]

theorem P_val : P = 18446744069414584321 := rfl

/-- `P - 1 = 2^32 · 3 · 5 · 17 · 257 · 65537`. -/
theorem P_sub_one_eq : P - 1 = 2 ^ 32 * (3 * (5 * (17 * (257 * 65537)))) := by norm_num [P]

/-- Every prime divisor of `P - 1` is one of `2, 3, 5, 17, 257, 65537`. -/
theorem prime_dvd_P_sub_one {q : ℕ} (hq : q.Prime) (hd : q ∣ P - 1) :
    q = 2 ∨ q = 3 ∨ q = 5 ∨ q = 17 ∨ q = 257 ∨ q = 65537 := by
  have eq_of {r : ℕ} (hr : r.Prime) (h : q ∣ r) : q = r := (Nat.prime_dvd_prime_iff_eq hq hr).mp h
  rw [P_sub_one_eq] at hd
  rcases (Nat.Prime.dvd_mul hq).mp hd with h | h
  · exact .inl (eq_of Nat.prime_two (hq.dvd_of_dvd_pow h))
  rcases (Nat.Prime.dvd_mul hq).mp h with h | h
  · exact .inr (.inl (eq_of (by norm_num) h))
  rcases (Nat.Prime.dvd_mul hq).mp h with h | h
  · exact .inr (.inr (.inl (eq_of (by norm_num) h)))
  rcases (Nat.Prime.dvd_mul hq).mp h with h | h
  · exact .inr (.inr (.inr (.inl (eq_of (by norm_num) h))))
  rcases (Nat.Prime.dvd_mul hq).mp h with h | h
  · exact .inr (.inr (.inr (.inr (.inl (eq_of (by norm_num) h)))))
  · exact .inr (.inr (.inr (.inr (.inr (eq_of (by norm_num) h)))))

/-! The certificate's six modular powers, evaluated over the literal modulus. -/

private theorem pow_full : (7 : ZMod 18446744069414584321) ^ 18446744069414584320 = 1 := by
  reduce_mod_char
private theorem pow_2 : (7 : ZMod 18446744069414584321) ^ 9223372034707292160 = -1 := by
  reduce_mod_char
private theorem pow_3 : (7 : ZMod 18446744069414584321) ^ 6148914689804861440 ≠ 1 := by
  reduce_mod_char; decide
private theorem pow_5 : (7 : ZMod 18446744069414584321) ^ 3689348813882916864 ≠ 1 := by
  reduce_mod_char; decide
private theorem pow_17 : (7 : ZMod 18446744069414584321) ^ 1085102592318504960 ≠ 1 := by
  reduce_mod_char; decide
private theorem pow_257 : (7 : ZMod 18446744069414584321) ^ 71777214277877760 ≠ 1 := by
  reduce_mod_char; decide
private theorem pow_65537 : (7 : ZMod 18446744069414584321) ^ 281470681743360 ≠ 1 := by
  reduce_mod_char; decide
private theorem neg_one_ne_one' : (-1 : ZMod 18446744069414584321) ≠ 1 := by decide

/-- Fermat's condition for the witness: `7^(P-1) = 1` in `ZMod P`. -/
theorem seven_pow_P_sub_one : (7 : ZMod P) ^ (P - 1) = 1 := pow_full

/-- Euler's criterion evaluated at 7: `7^((P-1)/2) = -1`. -/
theorem seven_pow_half : (7 : ZMod P) ^ (P / 2) = -1 := pow_2

/-- The witness `7` has order `P - 1`: no maximal proper divisor kills it. -/
theorem seven_pow_ne_one {q : ℕ} (hq : q.Prime) (hd : q ∣ P - 1) :
    (7 : ZMod P) ^ ((P - 1) / q) ≠ 1 := by
  rcases prime_dvd_P_sub_one hq hd with rfl | rfl | rfl | rfl | rfl | rfl
  · rw [show (P - 1) / 2 = P / 2 from rfl, seven_pow_half]; exact neg_one_ne_one'
  · exact pow_3
  · exact pow_5
  · exact pow_17
  · exact pow_257
  · exact pow_65537

/-- **The Goldilocks modulus is prime.** Lucas certificate with witness 7. -/
theorem P_prime : P.Prime := lucas_primality P 7 seven_pow_P_sub_one fun _ hq hd ↦
  seven_pow_ne_one hq hd

instance : Fact P.Prime := ⟨P_prime⟩

/-- The base field `𝔽_p`. -/
abbrev Fp : Type := ZMod P

/-- `7` generates `𝔽_p^×`: its order is `P - 1`. -/
theorem orderOf_seven : orderOf (7 : Fp) = P - 1 :=
  orderOf_eq_of_pow_and_pow_div_prime (by norm_num [P]) seven_pow_P_sub_one
    fun _ hq hd ↦ seven_pow_ne_one hq hd

/-- **7 is a quadratic non-residue modulo P.** -/
theorem seven_not_square : ¬ IsSquare (7 : Fp) := by
  have h7 : (7 : Fp) ≠ 0 := by
    show (7 : ZMod 18446744069414584321) ≠ 0
    decide
  rw [ZMod.euler_criterion P h7, seven_pow_half]
  exact neg_one_ne_one'

instance : Fact (¬ IsSquare (7 : Fp)) := ⟨seven_not_square⟩

end Shield.Field
