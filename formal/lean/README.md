# Machine-checked mathematics for the Shield verifier

A Lean 4 project (Lean `v4.34.0`, Mathlib `v4.34.0`) that proves parts of the mathematics the
NØNOS Shield STARK verifier depends on, and properties of word-level models of its arithmetic
and of the pool contracts.

> [!WARNING]
> These proofs do not show that the verifier is sound. They cover the field, the FRI fold and
> inverse chain, the DEEP algebra, Merkle binding, limb conservation, a zero-knowledge rank bound
> and a state-machine model of the pool. FRI soundness is a named hypothesis, the Solidity is hand
> transcribed, and several models use parameters other than the launch parameters. See
> [Current limits](#current-limits) and `docs/20-security-status.md`.

| | |
|---|---|
| Toolchain | Lean `v4.34.0`, Mathlib `v4.34.0` |
| `sorry` / `admit` | none |
| Axioms | `propext`, `Classical.choice`, `Quot.sound` for every theorem `Axioms.lean` lists |
| Solidity link | hand transcription, checked by reading |
| FRI proximity | a named hypothesis (`FriSoundnessHyp`), not proved |
| CI | `.github/workflows/lean.yml`: clean build, no `sorry`/`admit`, no `axiom`, axiom list |

    lake exe cache get        # fetch prebuilt Mathlib
    lake build                # build every module under Shield/
    lake env lean Axioms.lean # print the axioms of each listed theorem

Stable names that other modules may import are listed in `API.md`. The pool, settler gate, limb
and fee router models under `Shield/Protocol/` are described in `Shield/Protocol/README.md`.

## Conventions

$p = 2^{64} - 2^{32} + 1$. $\mathbb{F}_p = \mathbb{Z}/p$. $\mathbb{F}_{p^2} = \mathbb{F}_p[X]/(X^2 - 7)$,
written $a + b\omega$ with $\omega^2 = 7$. In Lean it is `QuadraticAlgebra Fp 7 0`. A *word* is a
natural number. A word is *canonical* when it is less than $p$. The contracts' `addmod` and
`mulmod` are modelled as $(a+b) \bmod p$ and $ab \bmod p$ over $\mathbb{N}$, which is what the EVM
computes for a nonzero modulus.

## 1. The field: `Shield/Field/Basic.lean`, `Shield/Field/Fp2.lean`

**Primality** (`P_prime`, Basic.lean:83). $p$ is prime. The proof is a Lucas (Pratt) certificate
with $p - 1 = 2^{32}\cdot 3\cdot 5\cdot 17\cdot 257\cdot 65537$:
$$7^{p-1} \equiv 1 \pmod p, \qquad 7^{(p-1)/q} \not\equiv 1 \pmod p \quad (q \in \{2,3,5,17,257,65537\}),$$
and Mathlib's `lucas_primality`. The six powers are evaluated by the `reduce_mod_char` tactic,
which uses norm_num's binary modular exponentiation (`Mathlib.Tactic.NormNum.PowMod`) and leaves a
proof term the kernel checks. The six small primes are proved by `norm_num`. As a by-product
$7$ generates $\mathbb{F}_p^\times$ (`orderOf_seven`, Basic.lean:92).

**Non-residue** (`seven_not_square`, Basic.lean:97). $7$ is not a square mod $p$, by Euler's
criterion, since $7^{(p-1)/2} \equiv -1$.

**Irreducibility and the field** (`irreducible_X_sq_sub_seven`, Fp2.lean:27, and
`equivAdjoinRoot`, Fp2.lean:52). $X^2 - 7$ is irreducible over $\mathbb{F}_p$, and
$$\mathbb{F}_p[X]/(X^2-7) \;\cong\; \mathbb{F}_{p^2} \quad\text{as } \mathbb{F}_p\text{-algebras}, \qquad X \mapsto \omega,$$
so both are fields.

**Inverse formula** (`inv_eq`, Fp2.lean:71, `mul_inv_formula`, Fp2.lean:77, `norm_ne_zero`,
Fp2.lean:66). For every $a + b\omega$,
$$(a + b\omega)^{-1} = \frac{a - b\omega}{a^2 - 7b^2},$$
with both sides $0$ at $0$, and $a^2 - 7b^2 \ne 0$ unless $a = b = 0$.

**Frobenius** (`frobenius_eq_star`, Fp2.lean:98). $(a + b\omega)^p = a - b\omega$. The
contracts' `conjugate` is the Frobenius. There is no separate Frobenius function.

## 2. Chained FRI inverses: `Shield/Fri/Chain.lean`

In the field, for $\zeta^4 = 1$:
$$ (x_0\zeta)^{-1} = x_0^{-1}\zeta^{-1}\ \ (\texttt{inv\_mul\_zeta}, 29), \qquad \zeta^{-1} = \zeta^3\ \ (\texttt{zeta\_inv\_eq\_cube}, 32), \qquad (x^4)^{-1} = (x^{-1})^4\ \ (\texttt{inv\_pow\_four}, 37). $$

The radix-4 verifier `RealQueryVerify._verifyFriQuad` inverts once per query and moves between
layers with `_ixStep`. With layer-$m$ point $x_m = (s\,\omega^{i_m})^{4^m}$, quarter $q$ and
$\zeta = \omega^{q\cdot 4^{m+1}}$:
$$ \big((s\,\omega^{i + kq})^{4^m}\big)^4 = (s\,\omega^{i})^{4^{m+1}}\,\zeta^k \qquad (\texttt{next\_point}, 41), $$
and if $x'^4 = x\,\zeta^k$ with $k < 4$ then
$$ x^{-1} = \begin{cases} (x'^{-1})^4 & k = 0 \\ (x'^{-1})^4\,(\zeta^{-1})^{4-k} & k \ne 0 \end{cases} \qquad (\texttt{inv\_step}, 57). $$
`ixStep_spec` (104) proves that the word-level transcription of `_ixStep` (two `mulmod`
squarings, then $4-k$ multiplications by `izeta`) returns the canonical representative of
$x^{-1}$ given canonical $x'^{-1}$ and a representative of $\zeta^{-1}$.

## 3. Radix-4 fold: `Shield/Fri/Fold.lean`

The contract's radix-2 fold, transcribed from `_fold2Raw`, is
$\mathrm{fold}_2(a, b; \beta, i_x) = (a+b)\,h + \beta\,(a-b)\,h\,i_x$ with $h = 9223372034707292161 = 2^{-1}$
(`half_mul_two`, 130). `_quadFold` computes
$$ \mathrm{fold}_2\big(\mathrm{fold}_2(v_0, v_2; \beta, i_0),\ \mathrm{fold}_2(v_1, v_3; \beta, i_1);\ \beta^2,\ i_0^2\big). $$

**Theorem** (`fold_quad`, 60). In any field with $2 \ne 0$, let
$f(X) = \sum_{j<4} X^j f_j(X^4)$ for arbitrary functions $f_j$, $x \ne 0$, $\zeta^2 = -1$,
$v_j = f(x\zeta^j)$, $i_0 = x^{-1}$, $i_1 = (x\zeta)^{-1}$. Then the fold above equals
$$\sum_{j<4} \beta^j f_j(x^4).$$

`exists_quad_decomposition` (86) shows that every polynomial has such a decomposition.
`fold2Raw_val` (161) and `quadFold_val` (173) prove that the word-level transcriptions of
`_fold2Raw`, `_sqFp2` and `_quadFold` compute this field expression on canonical inputs, and
`quadFold_correct` (188) states the theorem over the transcribed contract formula, with the
opened values as canonical word pairs and $i_0, i_1$ as words.

## 4. The DEEP quotient: `Shield/Deep/Quotient.lean`

The verifier checks $\mathrm{deep}(x) = \sum_i k_i\,(f_i(x) - v_i)/(x - z_i)$ at each query.

**Division** (`deep_quotient`, 56, `dvd_sub_C_iff`, 51). For $f \in K[X]$ and $z \in K$,
$$ f - f(z) = (X - z)\,q, \qquad \deg q = \deg f - 1, $$
and $(X - z) \mid f - v \iff v = f(z)$.

**The combined term** (`combined_dvd_iff`, 87). Group the terms by distinct point $s \in S$ into
$g_s = \sum_{z_i = s} k_i (f_i - v_i)$. With $Z_S = \prod_{s\in S}(X - s)$ and
$N = \sum_{s} g_s \prod_{t \ne s}(X - t)$,
$$ Z_S \mid N \iff g_s(s) = 0 \ \text{ for all } s \in S. $$
`deep_group` (116) and `deep_eval` (103) show that for $x \notin S$ the verifier's sum equals
$N(x)/Z_S(x)$. The combined DEEP function is a polynomial iff, at every point, the
coefficient-weighted sum of the claim errors vanishes.

**Soundness direction.** Suppose some claim is wrong: $e_{i_0} = f_{i_0}(s) - v_{i_0} \ne 0$.

* (`bad_coefficient_unique`, 131, `bad_coefficient_card`, 150) For every choice of the other
  coefficients, a unique value of $k_{i_0}$ makes $g_s(s) = 0$. If $k_{i_0}$ is uniform in a
  finite field $K$, the combined term is a polynomial with probability $1/|K|$. For
  $K = \mathbb{F}_{p^2}$ that is about $2^{-128}$.
* (`deep_far`, 163) If $Z_S \nmid N$, then on any evaluation domain $D$ disjoint from $S$, the
  word $x \mapsto N(x)/Z_S(x)$ agrees with any polynomial $h$ on at most
  $\max(\deg N,\ \deg h + |S|)$ points of $D$.

The chain from "a claim is wrong" to "the verifier rejects" also needs three things. FRI must
reject words this far from the code (section 9, a hypothesis). The $k_i$ must be uniform and
independent of the prover's choices (Fiat-Shamir in the random-oracle model, not modelled). The
$f_i$ must be the committed columns (Merkle binding, section 8, plus the proof codec, not modelled).

## 5. Limb conservation: `Shield/Arith/LimbBalance.lean`

The model follows the value circuit of the launch statement. Per leg,
$\mathrm{value} = \mathrm{lo} + 2^{32}\mathrm{hi}$ and $\mathrm{room} = 2^{32} - 2 - \mathrm{hi}$, with
lo, hi, room range-checked to 32 bits. Per intent over $n = 6$ legs with signs $\sigma_j = \pm 1$,
$S_{lo} = \sum \sigma_j \mathrm{lo}_j$, $S_{hi} = \sum \sigma_j \mathrm{hi}_j$, and on the closing
row $S_{lo} = c\,2^{32}$, $S_{hi} = -c$ with $c + 3$ in 3 bits.

* `room_forces_hi_bound` (53): if $\mathrm{room} + \mathrm{hi} \equiv 2^{32} - 2 \pmod p$ and
  both are below $2^{32}$, then $\mathrm{hi} \le 2^{32} - 2$.
* `value_le` (62): $\mathrm{lo} < 2^{32},\ \mathrm{hi} \le 2^{32} - 2 \implies \mathrm{lo} + 2^{32}\mathrm{hi} \le p - 2$.
* `value_injective` (73), `bounded_value_zero_mod_p` (79): bounded values equal in
  $\mathbb{F}_p$ are equal in $\mathbb{N}$, and a bounded value that is $0$ in $\mathbb{F}_p$ is $0$.
  `unbounded_dummy_worth_p` (86): the limbs $(1, 2^{32} - 1)$ are worth $p$.
* `limbwise_conservation` (129): for $c \in [-3, 4]$, $(n + 4)\,2^{32} < p$ (true for $n = 6$,
  `six_legs_fit`), bounded legs and
  $S_{lo} \equiv c\,2^{32},\ S_{hi} \equiv -c \pmod p$, the congruences hold over $\mathbb{Z}$ and
  $$\sum_j \sigma_j\,\mathrm{value}_j = 0 \quad\text{in } \mathbb{Z}.$$
* `closes_iff_balances` (163): for $c \in [-3,4]$ the two field constraints hold iff
  $S_{lo} = c\,2^{32}$ and $S_{hi} = -c$ over $\mathbb{Z}$. `balances_of_closes` (174) and
  `balanced_has_carry` (155): these hold for some integer $c$ iff $\sum_j \sigma_j\,\mathrm{value}_j = 0$,
  and then $c$ is unique. Whether that $c$ lies in $[-3, 4]$ depends on how many legs are inputs
  and outputs, which the file does not fix.
* `modular_balance_alone_creates_value` (187): with only $\sum_j\sigma_j v_j \equiv 0 \pmod p$,
  an input worth 1 and an output worth $p + 1$ (a valid `u64`) balance, and the output's high
  limb is $2^{32} - 1$, which the bound refuses.

## 6. Goldilocks arithmetic as implemented: `Shield/Arith/Goldilocks.lean`

One-for-one transcriptions of `StarkFieldExt.fpAdd`, `fpSub`, `fpNeg`, `fpMul`, `fpPow` (the
square-and-multiply loop, with `exp & 1` and `exp >> 1`), `fpInv` (the addition chain and
`_pow2`, line by line) and `Goldilocks.isCanonicalLimb`, `limb`, `isCanonicalDigest`.

* `isCanonicalLimb_iff` (113): `isCanonicalLimb v` $\iff v < p$. `canonicalEquiv` (117):
  canonical words are in bijection with $\mathbb{F}_p$.
* `isCanonicalDigest_iff` (129): for $v < 2^{256}$, the check holds iff each of the four 64-bit
  limbs is below $p$ (the unmasked top limb is the same limb).
* `fpAdd_spec` (156), `fpMul_spec` (163), `fpPow_spec` (255), `fpInv_spec` (224): for **all**
  words, the result is the canonical representative of $a + b$, $ab$, $a^e$, and $a^{-1}$
  (with $0^{-1} = 0$). The chain computes $a^{p-2}$ because
  $p - 2 = (2^{31} - 1)\,2^{33} + (2^{32} - 1)$.
* `fpSub_spec` (176): for $b \le p$ (where Solidity's checked `P - b` does not revert), the
  result is the canonical representative of $a - b$. `fpNeg_spec` (191): the same for $-a$,
  $a$ canonical.

## 7. $\mathbb{F}_{p^2}$ as implemented: `Shield/Arith/Fp2Impl.lean`

Transcriptions of `add`, `sub`, `neg`, `mul`, `square`, `mulBase`, `conjugate`, `norm`,
`isZero`, `eq` and `inv` on word pairs `(c0, c1)`. With $\mathrm{val}(c_0, c_1) = c_0 + c_1\omega$:

* `mul_val` (139): $\mathrm{val}(\mathrm{mul}(a,b)) = \mathrm{val}(a)\,\mathrm{val}(b)$ for all words.
  Also `add_val`, `sub_val`, `neg_val`, `square_val`, `mulBase_val`.
* `inv_val` (168): $\mathrm{val}(\mathrm{inv}(a)) = \mathrm{val}(a)^{-1}$ on canonical pairs,
  including $a = 0$.
* `conjugate_eq_frobenius` (157): $\mathrm{val}(\mathrm{conjugate}(a)) = \mathrm{val}(a)^p$.
* `eq_iff` (105) and `isZero_iff` (115): on canonical pairs `eq` and `isZero` decide field
  equality. Every output is canonical (`*_canon`).

## 8. Merkle binding: `Shield/Merkle/Binding.lean`

A model of `StarkMerkle._fold` and `RealQueryVerify._pathInPlace`. At each level the node is
$H(\texttt{NODE\_TAG}\,\|\,\ell\,\|\,r)$ with the order chosen by the low index bit. The path
accepts iff the index is exhausted and the node equals the root. Digests are $w$-byte strings
($w = 24$ at launch). $H$ is an arbitrary function standing for keccak256 cut to $w$ bytes. The
six leaf tags and the node tag are the contract's ASCII strings.

* `index_lt_of_verify` (106): acceptance with a path of length $d$ forces $\mathrm{idx} < 2^d$.
* `verify_extracts_collision` (133): two accepted openings of different digests at the same
  index, under the same root, with paths of equal length, give $x \ne y$ with $H(x) = H(y)$.
* `opening_binding` (153): the same for leaf payloads of one leaf kind.
* `binding_of_collisionFree` (162): under the explicit hypothesis
  $\forall x\,y,\ H(x) = H(y) \to x = y$, an accepted opening determines the payload.
* `leaf_ne_node` (191): every leaf preimage differs from every node preimage, for all six
  leaf tags. They differ from `NONOS-STARK-MERKLE-NODE` at byte 19, or byte 12 for
  `NONOS-STARK-PERIODIC-WIDE`. `leaf_node_confusion_is_collision` (200): a leaf digest equal to
  a node digest is a collision.

The collision-freeness hypothesis is false for any compressing function. It is the idealisation
under which the corollary is stated. The extraction theorem is the useful form: an opening forgery
at fixed depth yields a collision of the truncated hash, with no loss. Separation between
different *leaf* kinds (a wide leaf read as a pair leaf, say) is not proved here. It rests on tag
bytes 24 to 27 and on payload lengths.

## 9. FRI soundness arithmetic: `Shield/Soundness/Fri.lean`

`StagedStarkVerifier._stageConjectured` and `_stageProvable` compute $q(e+1) + \gamma$ and
$\lfloor q(e+1)/2 \rfloor + \gamma$, with $\rho = 2^{-(e+1)}$. `_bits` takes the outer stage's
provable figure from `_outerTerms`, the minimum of a query-phase and a commit-phase term, and
applies `_stageProvable` only to an inner stage.

* `reported_figures` (60): $(q,e,\gamma) = (14, 6, 32)$ gives 130 / 81, $(32, 3, 16)$ gives
  144 / 80, and the minimum of each pair is 130 / 80.
* `johnson_query_bits` (70): if one query accepts a far word with probability $\alpha$,
  $\alpha^2 \le \rho$, then $2^{-\gamma}\alpha^q \le 2^{-(\lfloor q(e+1)/2\rfloor + \gamma)}$.
  `capacity_query_bits` (87): if $\alpha \le \rho$, the bound is $2^{-(q(e+1)+\gamma)}$. The two
  formulas are the query-phase terms alone, at the Johnson radius with no slack
  ($\alpha = \sqrt\rho$) and at capacity.

The provable bound in the literature has a second, commit-phase term. `FriSoundnessHyp` (110)
states as a named hypothesis Ben-Sasson, Carmon, Ishai, Kopparty and Saraf, *Proximity Gaps for
Reed-Solomon Codes* (ePrint 2020/654), Lemma 8.2 and Theorem 8.3, with grinding applied to the
query term. For every integer $m \ge 3$, acceptance of a prover without correlated agreement is
at most
$$ \varepsilon_{\mathrm{FRI}} = \frac{(m+\frac12)^7\,|D|^2}{2\rho^{3/2}|F|} + \frac{(2m+1)(|D|+1)}{\sqrt\rho}\cdot\frac{\sum_i l^{(i)}}{|F|} + 2^{-\gamma}\Big(\sqrt\rho\,\big(1 + \tfrac{1}{2m}\big)\Big)^{s}. $$
Evaluated with $|F| = p^2$ and $\sum_i l^{(i)} \le 64$:

* `outer_eps_le` (133): $|D| = 2^{28}$, $\rho = 2^{-7}$, $s = 14$, $\gamma = 32$, at
  $m = 3$: $\varepsilon_{\mathrm{FRI}} \le 2^{-49}$.
* `outer_eps_ge` (159): for every real $m \ge 3$, $\varepsilon_{\mathrm{FRI}} \ge 2^{-50}$. The
  commit-phase term alone exceeds $2^{-50}$ and grinding does not reduce it.
* `inner_eps_le` (183): $|D| = 2^{17}$, $\rho = 2^{-4}$, $s = 32$, $\gamma = 16$, at
  $m = 4$: $\varepsilon_{\mathrm{FRI}} \le 2^{-72}$.

At these parameters, taking the theorem as the provable bound, the outer stage is certified at
between 49 and 50 bits and the inner stage at no less than 72. These are not the launch
parameters (see [Current limits](#current-limits)).

## 10. Zero knowledge, the rank condition: `Shield/Zk/`

The prover's soundness note, Section 4.4, proves zero knowledge of FRI beyond layer zero under
the rank condition
$$ \textbf{(R)}\qquad \dim_{\mathbb{F}_p} F(\ker A) \;=\; \dim_{\mathbb{F}_p} F(\ker L_0), $$
where $F$ is the linear map from the DEEP polynomial to every value FRI reveals, $A$ the mask
columns' own openings (V1, V2) and $L_0$ FRI layer zero. The prover's `zk_fri_rank` tool measures
both sides as $1{,}328$ on each proof of the launch package. This section bounds the probability,
over the challenges, that (R) fails.

**Schwartz-Zippel, as used** (`card_zeros_div_le`, SchwartzZippel.lean:22, from Mathlib's
`MvPolynomial.schwartz_zippel_totalDegree`). For $f \in K[c_1,\dots,c_k]$, $f \ne 0$,
$\deg f \le d$, and finite $S \subseteq K$,
$$ \frac{\#\{c \in S^k : f(c) = 0\}}{|S|^k} \;\le\; \frac{d}{|S|}. $$

**Minors** (`exists_minor_ne_zero`, RankMinor.lean:46, `le_rank_of_minor_ne_zero`, 65). Over a
field, $\operatorname{rank} A \ge r$ iff some $r\times r$ minor of $A$ is nonzero.
**Degree of a determinant** (`totalDegree_det_le`, 79): entries of degree $\le e$ give an
$r \times r$ determinant of degree $\le r e$.

**The rank lemma** (`exists_rank_minor`, RankMinor.lean:100, `rank_lemma`, 115). Let
$M \in K[c_1,\dots,c_k]^{m\times n}$ with every entry of total degree $\le e$, and suppose
$\operatorname{rank} M(c_0) \ge r$. Then some $r\times r$ minor $P$ of $M$ satisfies $P \ne 0$,
$\deg P \le re$, and $\operatorname{rank} M(c) \ge r$ wherever $P(c) \ne 0$. For every
finite $S \subseteq K$
$$ \frac{\#\{c \in S^k : \operatorname{rank} M(c) < r\}}{|S|^k} \;\le\; \frac{r\,e}{|S|}. $$

**Coordinates** (`Coordinates.lean`). A challenge $u \in \mathbb{F}_{p^2}$ is uniform iff its
coordinates $(u_0, u_1) \in \mathbb{F}_p^2$ are. Quantities computed from challenges live in
`PolyFp2 σ` $= \mathbb{F}_p[c_i][\omega]/(\omega^2 - 7)$. `DegLE n x` says both coordinates have
total degree $\le n$. Degrees add under products (`DegLE.mul`, 74), conjugation is linear
(`DegLE.star`, 96), and evaluation `ev c` is a ring homomorphism to $\mathbb{F}_{p^2}$ (118).
The rank is taken over $\mathbb{F}_p$, of the matrix of $\mathbb{F}_p$-coordinates, so the
Schwartz-Zippel set is $S = \mathbb{F}_p$ in each of $k = 12$ coordinates.

**The model** (`FriMask.lean`). The twelve coordinates are those of
$z, \alpha, \beta_1, \dots, \beta_4$. Fix the query positions. They fix the opened points of each
layer and $W = \prod_{x \in V_1}(X - x)$ over the $152$ opened mask rows (`Geometry`, 186).
The model uses a parametrisation of $\ker A$:
$$ M = W\,\mu_z\,\mu_{gz}\,R, \qquad \mu_u = (X-u)(X-\bar u) = X^2 - 2\operatorname{Re}(u)X + N(u) \in \mathbb{F}_p[X], \qquad \deg R < B - 156. $$
Such $M$ lies in $\ker A$ (`maskPoly_eval_z`, 380, `maskPoly_eval_gz`, 385,
`maskPoly_eval_root`, 390, `quadFactor_map`, 335), and its DEEP quotients are
$$ \frac{M - M(z)}{X - z} = W (X - \bar z)\,\mu_{gz} R, \qquad \frac{M - M(gz)}{X - gz} = W \mu_z (X - g\bar z) R $$
(`quot0_spec`, 366, `quot1_spec`, 372, `deep_quotient_eval`, 397), whose coefficients have degree
$\le 3$ in the coordinates of $z$. With $a_{k,c} = \alpha^{44k + c}$, $c \in \{42, 43\}$, the mask
part of the DEEP polynomial for $R = X^i$ is `deepCol` (241), with coefficients of degree
$\le 87 + 3 = 90$ (`deepCol_deg`, 262). A radix-4 fold $d'_j = \sum_{r<4}\beta^r d_{4j+r}$ adds
$\le 3$ (`DegLE.fold`, 99, `DegLE.layer`, 107). `revealMatrix` (308) has rows the
$\mathbb{F}_p$-coordinates of layers $0$ to $3$ at their opened points and of the final
coefficients, and columns the basis masks $X^i$ of both mask columns.

* **Entry degree** (`revealMatrix_degree`, FriMask.lean:314): every entry has total degree
  $$ e \;\le\; 87 + 3 + 4\cdot 3 \;=\; 102. $$
* **Meaning** (`revealMatrix_eval`, 439, `deepCol_map`, 428): evaluated at $c$, each column is
  what FRI reveals, over $\mathbb{F}_{p^2}$ with the fold challenges of $c$, of
  $\sum_k \alpha^{44k+42+\mathrm{col}}\,(M - M(z_k))/(X - z_k)$ for $M = W\mu_z\mu_{gz}X^i$.

**The launch bound** (`Launch.lean`). Let $\mathcal{B}_G = \{c \in \mathbb{F}_p^{12} :
\operatorname{rank} M_G(c) < 1328\}$ (`badChallenges`, 61).

* `launch_rank_failure` (Launch.lean:72): if $\operatorname{rank} M_G(c_0) \ge 1328$ for one $c_0$,
  $$ \frac{|\mathcal{B}_G|}{p^{12}} \;\le\; \varepsilon \;=\; \frac{1328 \cdot 102}{p} \;=\; \frac{135456}{18446744069414584321}. $$
* `eps_gt`, `eps_lt` (129, 126): $2^{-47} < \varepsilon < 2^{-46}$, numerically
  $\varepsilon \approx 2^{-46.95}$. `eps_not_lt_two_pow_neg_80` (133): $\varepsilon < 2^{-80}$ is
  **false**.
* `sz_floor` (138): $1328/p > 2^{-54}$. Any Schwartz-Zippel bound of this form, with $r = 1328$ and
  $S = \mathbb{F}_p$, is above $2^{-54}$ whatever the degree, so $2^{-80}$ is out of reach of this
  method. Without the parametrisation of $\ker A$ the entries carry $z$ to degree $B - 1$, and
  the bound on the stacked matrix $[A; F]$ at rank $1640$ is about $2^{-36.3}$.
* `launch_condition_R` (96): for subspaces $F\!A(c) = F(\ker A_c)$ and $F\!L_0(c) = F(\ker L_{0,c})$,
  under (H3) to (H6) below, the proportion of $c$ at which (R) fails is at most $\varepsilon$.
  Its linear algebra: `finrank_range_comp_le` (44), $\operatorname{range}\Phi \le \ker A \Rightarrow
  \dim F\Phi \le \dim F(\ker A)$, and `condition_R_of_le` (52).
* `package_rank_failure` (161): for each of the four package proofs, with its own query
  positions, $|\mathcal{B}_G|/p^{12} < 2^{-46}$, under (H6) for that proof.
* `average_over_positions` (172): with positions $q \in Q$ drawn independently of $c$, if every
  $q \in G \subseteq Q$ has at most $\varepsilon|C|$ bad challenges, then
  $\Pr[\text{bad}] \le \Pr[q \notin G] + \varepsilon$. One matrix covers all layers at once, so
  no union bound over layers is needed. This average over positions is the only one.

**Hypotheses and modelling assumptions.** Each is a Lean hypothesis of the theorem named or an
input of the model. Those marked *open* are not checked against the prover here.

* **(H1) DEEP exponents** (`deepExp`, FriMask.lean:215). The mask columns are $42, 43$ of width
  $44$, window $2$, and their DEEP coefficients are $\alpha^{44k+c}$, maximum exponent $87$.
  *Open*. See [Current limits](#current-limits) for the launch frame.
* **(H2) Fold in coefficients** (`fold`, FriMask.lean:59). Layer $m+1$ has coefficients
  $\sum_{r<4}\beta_{m+1}^r d_{4j+r}$, the two radix-2 folds under $\beta, \beta^2$, and the final
  layer reveals its $512$ coefficients. *Open*.
* **(H3) Inclusion** (`hIncl`). $F(\ker A) \subseteq F(\ker L_0)$: Lemma 4.2 of the soundness
  note, not mechanized here.
* **(H4) Upper side** (`hUpper`). $\dim F(\ker L_0) \le 1328$: the $4 \times 38 = 152$
  fold-consistency relations remove $152$ of the $1{,}480$ coordinates beyond layer zero. Not
  mechanized here.
* **(H5) The matrix is $F$ on the parametrised kernel** (`hModel`).
  $\operatorname{rank} M_G(c) \le \dim F(\ker A_c)$. The Lean model proves that each column is
  $F$ of the DEEP mask part of a mask in $\ker A_c$ (`revealMatrix_eval`, `maskPoly_eval_*`). The
  identification of `reveal` with the prover's $F$, coordinate for coordinate, is by
  transcription of `zk_fri_rank`.
* **(H6) Reported rank** (`ReportedRank`, Launch.lean:81). At the challenges $c_0$ and positions
  of each package proof, $\operatorname{rank} M_G(c_0) \ge 1328$. `zk_fri_rank` reports
  $\dim F(\ker A_{c_0}) = 1328$ with the unparametrised kernel. The two agree when
  $\ker A_{c_0} = W\mu_{z}\mu_{gz}\,\mathbb{F}_p[X]_{<B-156}$, which holds when $z \notin
  \mathbb{F}_p$, $gz \notin \{z, \bar z\}$ and the $152$ opened rows are distinct. That equality
  is not proved here. *Open*.
* **(H7) Uniform challenges.** $(z, \alpha, \beta_1, \dots, \beta_4)$ uniform on
  $\mathbb{F}_{p^2}^6$ and the positions independent of them (random-oracle model, not modelled).
  The composition challenges and $\beta, \gamma$ of the copy constraint do not enter the mask part.
* **(H8) Positions.** The bound holds for each position set $G$ that has a witness (H6). The four
  package proofs witness four position sets. For all others, `average_over_positions` charges
  $\Pr[q \notin G]$, and no statement here makes that zero.

**Result.** For each position set with a witness, (R) fails with probability at most
$\varepsilon = 1328\cdot 102/p \approx 2^{-46.95}$ over the challenges. This is above $2^{-80}$,
and no Schwartz-Zippel argument over $\mathbb{F}_p$ coordinates at rank $1{,}328$ reaches
$2^{-80}$ (`sz_floor`).

## Current limits

One line each. `docs/20-security-status.md` holds the repository-wide list.

* FRI parameters: `Soundness/Fri.lean` evaluates the bound at 14 queries, 6 extra blowup bits, 32 grinding bits and $|D| = 2^{28}$ (inner stage 32, 3, 16 at $2^{17}$), not at the launch parameters: 19 queries, rate $1/64$ (extra blowup 5), 20-bit grinding per FRI commit round plus 8 final searches of 25 bits, $|D| = 2^{23}$, no inner stage.
* Commit-phase constant: `epsC` divides by $2\rho^{3/2}$, while the contract's `_outerTerms` divides by $3\rho^{3/2}$.
* Relay fee: the pool model's `DecodeOk` requires `fee = 0` when `publicAmount = 0`, while `ShieldedPool._decodeIntent` accepts a relay fee up to `maxRelayFee[assetId]` there, so the pool theorems do not cover relay-fee transfers.
* Public-word layout: the `Limbs` model reads words 10 and 11 of the 12-word layout as four 64-bit limbs, while `PublicWords.publicsOf` splits them into 48-bit limbs and rejects any word of $2^{160}$ or more.
* Residual swap: the pool model credits the whole swap output to `totalShielded` and admits a same-asset residual swap, while the contract moves sub-unit dust to `unsweptFees` and reverts a same-asset residual with `SameAssetResidual`.
* Axiom list: `Axioms.lean` does not print the `Shield/Protocol/` theorems, so CI does not check their axioms.
* Code path: the fold, inverse-chain and Merkle-path models transcribe `RealQueryVerify`, while the launch verifier runs FRI, DEEP and the query paths in `RealQueryWalk`, a Yul walk over calldata that no theorem models.
* DEEP coefficients: `Deep/Quotient.lean` treats each $k_i$ as uniform and independent, while the launch verifier takes them as powers of one challenge.
* ZK mask frame: (H1) gives column 43 the DEEP coefficient $\alpha^{44k+43}$, while the launch frame opens the mask pair 42, 43 as one $\mathbb{F}_{p^2}$ value and gives column 43 the coefficient $X$ times column 42's.
* ZK bound: (R) fails with probability up to $2^{-46.95}$ per position set, and (H1) to (H6) are hypotheses.
* Solidity and EVM semantics: each "as implemented" function is a hand transcription checked by reading, with no formal semantics of Solidity, Yul or the EVM and no link to compiler output.
* Assembly: the byte swaps, masks and `mstore` offsets in `StarkMerkle` and `RealQueryVerify._pathInPlace` are summarised in prose, and the summary is not proved.
* Random oracle and Fiat-Shamir: not modelled. Challenges are uniform where a theorem needs them to be, and no statement bounds an adversary's hash queries.
* FRI soundness: the proximity-gap theorem is stated, cited and used, not proved, and the grinding model is part of that hypothesis.
* AIR: not modelled. Nothing here says that the composition polynomial encodes the pool's circuit, and the limb theorems describe the constraints as specified, not the on-chain evaluator.
* Merkle: a reduction, not a bound. How hard a collision of truncated keccak256 is remains an assumption.
* Parameters: domain sizes, round counts and query counts are inputs to the models, not read from a contract.
