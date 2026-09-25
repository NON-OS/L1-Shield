# Stable names exported by the field modules

Other modules (including `Shield/Protocol/`) may rely on these names. They will not be renamed.

## `import Shield.Field.Basic`

| name | type | meaning |
|---|---|---|
| `Shield.Field.P` | `ℕ` | `0xFFFFFFFF00000001`, the Goldilocks modulus |
| `Shield.Field.P_eq` | `P = 2 ^ 64 - 2 ^ 32 + 1` | |
| `Shield.Field.P_val` | `P = 18446744069414584321` | `rfl` |
| `Shield.Field.P_prime` | `P.Prime` | Lucas certificate, witness 7 |
| instance | `Fact P.Prime` | so `ZMod P` is a field |
| `Shield.Field.Fp` | `Type`, `abbrev` for `ZMod P` | the base field |
| `Shield.Field.seven_not_square` | `¬ IsSquare (7 : Fp)` | |
| `Shield.Field.orderOf_seven` | `orderOf (7 : Fp) = P - 1` | 7 generates `Fp^×` |

## `import Shield.Field.Fp2`

| name | type | meaning |
|---|---|---|
| `Shield.Field.Fp2` | `Type`, `abbrev` for `QuadraticAlgebra Fp 7 0` | `⟨c0, c1⟩ = c0 + c1·ω`, `ω² = 7`, a `Field` |
| `Shield.Field.omega2` | `Fp2` | `ω` |
| `Shield.Field.irreducible_X_sq_sub_seven` | `Irreducible (X ^ 2 - C 7 : Fp[X])` | |
| `Shield.Field.equivAdjoinRoot` | `Fp2 ≃ₐ[Fp] AdjoinRoot (X ^ 2 - C 7)` | |
| `Shield.Field.inv_eq` | `z⁻¹ = ⟨z.re / (z.re^2 - 7 z.im^2), -z.im / (z.re^2 - 7 z.im^2)⟩` | |
| `Shield.Field.norm_ne_zero` | `z ≠ 0 → z.re ^ 2 - 7 * z.im ^ 2 ≠ 0` | |
| `Shield.Field.star_eq` | `star z = ⟨z.re, -z.im⟩` | conjugate |
| `Shield.Field.frobenius_eq_star` | `z ^ P = star z` | |
