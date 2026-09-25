import Shield.Zk.Coordinates
import Shield.Zk.RankMinor
import Mathlib.Algebra.Polynomial.Eval.Defs
import Mathlib.Algebra.Polynomial.Coeff
import Mathlib.Algebra.Polynomial.FieldDivision

/-!
# The FRI mask map as a matrix of polynomials in the challenges

This file models what FRI reveals of the mask part of the DEEP polynomial
(the prover's soundness note, Section 4.4), restricted to the masks that the proof's own openings leave
free, and shows that every entry of the resulting matrix is a polynomial of total degree at most
`102` in the twelve `𝔽_p`-coordinates of the challenges `z, α, β₁, β₂, β₃, β₄ ∈ 𝔽_{p²}`.

## The kernel of the mask openings, parametrised

A mask column is `M ∈ 𝔽_p[X]` of degree below `B = 2^17`. The proof opens it at the `152` rows
`V₁` (the layer-zero points of the `19` queries and their successors) and at `z, g z ∈ 𝔽_{p²}`.
Let `W = ∏_{x ∈ V₁} (X − x)` and, for `u ∈ 𝔽_{p²}`,
`μ_u = (X − u)(X − ū) = X² − 2 Re(u) X + N(u) ∈ 𝔽_p[X]` (`quadFactor`, `quadFactor_map`).
Every

`M = W · μ_z · μ_{gz} · R,   R ∈ 𝔽_p[X],  deg R < B − 156`

vanishes at every opening (`maskPoly_eval_root`, `maskPoly_eval_z`, `maskPoly_eval_gz`), so lies
in `ker A`. For such `M` the DEEP quotients are polynomials whose coefficients are *linear* in the
coordinates of `z` (`quot0_spec`, `quot1_spec`, `deep_quotient_eval`):

`(M − M(z))/(X − z) = W · (X − z̄) · μ_{gz} · R,   (M − M(gz))/(X − gz) = W · μ_z · (X − g z̄) · R`.

This is what removes the degree `B − 1` in `z` that the openings `M(z)` would otherwise carry.

## The revealed values

With DEEP coefficients `a_{k,c} = α^{44k + c}` for the mask columns `c ∈ {42, 43}`, the mask part
of the DEEP polynomial for the basis mask `R = X^i` in column `c` is `deepCol c i`. FRI folds
coefficients by `d'_j = Σ_{r<4} β^r d_{4j+r}` (`fold`, `layer`) and reveals the values of layers
`0..3` at the opened points and the `512` coefficients of the final layer (`reveal`). Taking the
two `𝔽_p`-coordinates of each revealed value gives `revealMatrix`, with rows the revealed
coordinates and columns the basis masks.

* `revealMatrix_degree`: every entry has total degree `≤ 102 = 87 + 3 + 4·3`.
* `revealMatrix_eval`: evaluated at `c`, the matrix equals the matrix computed over `𝔽_{p²}` from the
  exact DEEP quotients of the masks `W μ_z μ_{gz} X^i`.
-/

namespace Shield.Zk

open Shield.Field Polynomial Finset

/-! ### Coefficient folding and evaluation, over any commutative ring -/

section Fold

variable {R S : Type*} [CommRing R] [CommRing S]

/-- One radix-four fold in coefficients: `d'_j = Σ_{r<4} β^r d_{4j+r}`. It is the fold of
`Shield.Fri.fold_quad` read on coefficients, and `fold` in the prover's `zk_fri_rank` tool. -/
def fold (β : R) (d : ℕ → R) : ℕ → R :=
  fun j ↦ ∑ r ∈ range 4, β ^ r * d (4 * j + r)

/-- The coefficients of FRI layer `m`: layer `0` is `d`, layer `m + 1` folds layer `m` by `β m`. -/
def layer (β : ℕ → R) (d : ℕ → R) : ℕ → ℕ → R
  | 0 => d
  | m + 1 => fold (β m) (layer β d m)

/-- The value at `x` of the polynomial with coefficients `d₀, …, d_{len-1}`. -/
def valueAt (d : ℕ → R) (len : ℕ) (x : R) : R :=
  ∑ l ∈ range len, d l * x ^ l

theorem map_fold (φ : R →+* S) (β : R) (d : ℕ → R) (j : ℕ) :
    φ (fold β d j) = fold (φ β) (φ ∘ d) j := by
  simp [fold, map_sum, map_mul, map_pow]

theorem map_layer (φ : R →+* S) (β d : ℕ → R) (m j : ℕ) :
    φ (layer β d m j) = layer (φ ∘ β) (φ ∘ d) m j := by
  induction m generalizing j with
  | zero => rfl
  | succ m ih =>
    simp only [layer]
    rw [map_fold]
    congr 1
    funext l
    exact ih l

theorem map_valueAt (φ : R →+* S) (d : ℕ → R) (len : ℕ) (x : R) :
    φ (valueAt d len x) = valueAt (φ ∘ d) len (φ x) := by
  simp [valueAt, map_sum, map_mul, map_pow]

end Fold

/-! ### Degrees through the folds -/

section FoldDegree

variable {σ : Type*}

/-- **A fold adds at most `3` to the degree**, when `β` has degree at most `1`. -/
theorem DegLE.fold {δ : ℕ} {β : PolyFp2 σ} {d : ℕ → PolyFp2 σ} (hβ : DegLE 1 β)
    (hd : ∀ l, DegLE δ (d l)) (j : ℕ) : DegLE (δ + 3) (fold β d j) := by
  refine DegLE.sum fun r hr ↦ ?_
  have hr : r ≤ 3 := Nat.lt_succ_iff.mp (mem_range.mp hr)
  refine ((hβ.pow r).mul (hd _)).mono ?_
  omega

/-- **Layer `m` has degree at most `δ + 3m`.** -/
theorem DegLE.layer {δ : ℕ} {β d : ℕ → PolyFp2 σ} (hβ : ∀ m, DegLE 1 (β m))
    (hd : ∀ l, DegLE δ (d l)) (m j : ℕ) : DegLE (δ + 3 * m) (layer β d m j) := by
  induction m generalizing j with
  | zero => exact hd j
  | succ m ih =>
    have := DegLE.fold (hβ m) ih j
    simpa [Zk.layer, Nat.mul_succ, Nat.add_assoc] using this

/-- Evaluating at a base-field point does not raise the degree. -/
theorem valueAt_degLE {δ len : ℕ} {d : ℕ → PolyFp2 σ} (hd : ∀ l, DegLE δ (d l)) (x : Fp) :
    DegLE δ (valueAt d len (algebraMap Fp (PolyFp2 σ) x)) := by
  refine DegLE.sum fun l _ ↦ ?_
  simpa using (hd l).mul ((DegLE.algebraMap x 0).pow l)

end FoldDegree

/-! ### Coefficient-wise degree of polynomials over `PolyFp2 σ` -/

section CoeffDegree

variable {σ : Type*}

/-- Every coefficient of `p` has degree at most `n`. -/
def CoeffDegLE (n : ℕ) (p : (PolyFp2 σ)[X]) : Prop :=
  ∀ l, DegLE n (p.coeff l)

namespace CoeffDegLE

theorem mono {m n : ℕ} {p : (PolyFp2 σ)[X]} (h : CoeffDegLE m p) (hmn : m ≤ n) :
    CoeffDegLE n p :=
  fun l ↦ (h l).mono hmn

theorem add {n : ℕ} {p q : (PolyFp2 σ)[X]} (hp : CoeffDegLE n p) (hq : CoeffDegLE n q) :
    CoeffDegLE n (p + q) :=
  fun l ↦ by rw [coeff_add]; exact (hp l).add (hq l)

theorem sub {n : ℕ} {p q : (PolyFp2 σ)[X]} (hp : CoeffDegLE n p) (hq : CoeffDegLE n q) :
    CoeffDegLE n (p - q) :=
  fun l ↦ by rw [coeff_sub]; exact (hp l).sub (hq l)

/-- **Coefficient degrees add under multiplication.** -/
theorem mul {m n : ℕ} {p q : (PolyFp2 σ)[X]} (hp : CoeffDegLE m p) (hq : CoeffDegLE n q) :
    CoeffDegLE (m + n) (p * q) :=
  fun l ↦ by rw [coeff_mul]; exact DegLE.sum fun x _ ↦ (hp x.1).mul (hq x.2)

theorem C {n : ℕ} {u : PolyFp2 σ} (hu : DegLE n u) : CoeffDegLE n (Polynomial.C u) :=
  fun l ↦ by rw [coeff_C]; split_ifs; exacts [hu, DegLE.zero n]

theorem X : CoeffDegLE 0 (Polynomial.X : (PolyFp2 σ)[X]) :=
  fun l ↦ by rw [coeff_X]; split_ifs; exacts [DegLE.one 0, DegLE.zero 0]

theorem X_pow (i : ℕ) : CoeffDegLE 0 (Polynomial.X ^ i : (PolyFp2 σ)[X]) :=
  fun l ↦ by rw [coeff_X_pow]; split_ifs; exacts [DegLE.one 0, DegLE.zero 0]

/-- `X − u` has coefficients of degree at most `deg u`. -/
theorem X_sub_C {n : ℕ} {u : PolyFp2 σ} (hu : DegLE n u) :
    CoeffDegLE n (Polynomial.X - Polynomial.C u) :=
  (X.mono (Nat.zero_le n)).sub (C hu)

/-- A polynomial over `𝔽_p` has constant coefficients. -/
theorem map_algebraMap (W : Fp[X]) :
    CoeffDegLE 0 (W.map (algebraMap Fp (PolyFp2 σ))) :=
  fun l ↦ by rw [coeff_map]; exact DegLE.algebraMap _ 0

end CoeffDegLE

end CoeffDegree

/-! ### The launch geometry and the challenge variables -/

/-- What the query positions and the circuit fix: base-field constants only.

* `nPts`: opened points per FRI layer (`radix · queries = 4 · 19 = 76`).
* `pts m q`: the `q`-th opened point of layer `m`, for `m = 0, 1, 2, 3`.
* `len m`: the number of coefficients of layer `m`.
* `nFinal`: the number of final-layer coefficients (`512`).
* `nR`: the number of free mask coefficients per column (`B − 156`).
* `W`: the vanishing polynomial of the mask's opened rows `V₁` (degree `152`).
* `g`: the generator of the trace domain. -/
structure Geometry where
  nPts : ℕ
  pts : Fin 4 → Fin nPts → Fp
  len : Fin 4 → ℕ
  nFinal : ℕ
  nR : ℕ
  W : Fp[X]
  g : Fp

/-- The twelve `𝔽_p`-coordinates: `z` is `0, 1`; `α` is `2, 3`; `β_{m+1}` is `4 + 2m, 5 + 2m`. -/
abbrev Coord : Type := Fin 12

/-- The out-of-domain point `z`. -/
noncomputable def zV : PolyFp2 Coord := var 0 1

/-- The DEEP challenge `α`. -/
noncomputable def alphaV : PolyFp2 Coord := var 2 3

/-- The fold challenge of layer `m + 1` (`m < 4`). -/
noncomputable def betaV (m : ℕ) : PolyFp2 Coord :=
  if h : m < 4 then var ⟨4 + 2 * m, by omega⟩ ⟨5 + 2 * m, by omega⟩ else 0

theorem betaV_deg (m : ℕ) : DegLE 1 (betaV m) := by
  unfold betaV; split_ifs
  · exact DegLE.var _ _
  · exact DegLE.zero 1

/-- **Modelling input: the DEEP exponent.** The DEEP coefficient of column `c` at `z_k = g^k z`
is `α^{44k + c}` (width `44`, window `2`); the mask columns are `42` and `43`. -/
def deepExp (k : ℕ) (c : Fin 2) : ℕ := 44 * k + 42 + c

theorem deepExp_le (k : ℕ) (hk : k < 2) (c : Fin 2) : deepExp k c ≤ 87 := by
  unfold deepExp; have := c.isLt; omega

/-! ### The DEEP mask part over the parametrised kernel -/

section Deep

variable (G : Geometry)

/-- `g z` as a polynomial expression. -/
noncomputable def gzV : PolyFp2 Coord := algebraMap Fp (PolyFp2 Coord) G.g * zV

/-- `(M − M(z))/(X − z)` for `M = W μ_z μ_{gz} X^i`: `W (X − z̄) (X − gz)(X − g z̄) X^i`. -/
noncomputable def quot0V (i : ℕ) : (PolyFp2 Coord)[X] :=
  G.W.map (algebraMap Fp _) * (X - C (star zV)) * ((X - C (gzV G)) * (X - C (star (gzV G))))
    * X ^ i

/-- `(M − M(gz))/(X − gz)` for `M = W μ_z μ_{gz} X^i`: `W (X − z)(X − z̄) (X − g z̄) X^i`. -/
noncomputable def quot1V (i : ℕ) : (PolyFp2 Coord)[X] :=
  G.W.map (algebraMap Fp _) * ((X - C zV) * (X - C (star zV))) * (X - C (star (gzV G)))
    * X ^ i

/-- The mask part of the DEEP polynomial for the basis mask `X^i` in mask column `c`:
`Σ_k α^{44k + 42 + c} · (M − M(z_k))/(X − z_k)`. -/
noncomputable def deepCol (c : Fin 2) (i : ℕ) : (PolyFp2 Coord)[X] :=
  C (alphaV ^ deepExp 0 c) * quot0V G i + C (alphaV ^ deepExp 1 c) * quot1V G i

theorem gzV_deg : DegLE 1 (gzV G) := by
  unfold gzV zV
  simpa using (DegLE.algebraMap G.g 0).mul (DegLE.var 0 1)

theorem quot0V_deg (i : ℕ) : CoeffDegLE 3 (quot0V G i) := by
  have h := ((((CoeffDegLE.map_algebraMap G.W).mul
    (CoeffDegLE.X_sub_C (DegLE.star (DegLE.var 0 1)))).mul
    ((CoeffDegLE.X_sub_C (gzV_deg G)).mul (CoeffDegLE.X_sub_C (gzV_deg G).star))).mul
    (CoeffDegLE.X_pow i))
  exact h

theorem quot1V_deg (i : ℕ) : CoeffDegLE 3 (quot1V G i) := by
  have h := ((((CoeffDegLE.map_algebraMap G.W).mul
    ((CoeffDegLE.X_sub_C (DegLE.var 0 1)).mul (CoeffDegLE.X_sub_C (DegLE.var 0 1).star))).mul
    (CoeffDegLE.X_sub_C (gzV_deg G).star)).mul (CoeffDegLE.X_pow i))
  exact h

/-- **The DEEP mask part has coefficients of degree at most `90 = 87 + 3`.** -/
theorem deepCol_deg (c : Fin 2) (i : ℕ) : CoeffDegLE 90 (deepCol G c i) := by
  have hα : ∀ k, k < 2 → DegLE 87 (alphaV ^ deepExp k c) := fun k hk ↦
    ((DegLE.var 2 3).pow (deepExp k c)).mono (by simpa using deepExp_le k hk c)
  exact ((CoeffDegLE.C (hα 0 (by norm_num))).mul (quot0V_deg G i)).add
    ((CoeffDegLE.C (hα 1 (by norm_num))).mul (quot1V_deg G i))

end Deep

/-! ### What FRI reveals, and the matrix -/

section Reveal

variable (G : Geometry)

/-- The revealed values: layer `m` at its `q`-th opened point, or final coefficient `j`. -/
abbrev Revealed : Type := (Fin 4 × Fin G.nPts) ⊕ Fin G.nFinal

/-- The value FRI reveals, from the challenges `β` and the layer-zero coefficients `d`. -/
def reveal {R : Type*} [CommRing R] [Algebra Fp R] (β : ℕ → R) (d : ℕ → R) : Revealed G → R
  | .inl (m, q) => valueAt (layer β d m) (G.len m) (algebraMap Fp R (G.pts m q))
  | .inr j => layer β d 4 j

theorem map_reveal {R S : Type*} [CommRing R] [Algebra Fp R] [CommRing S] [Algebra Fp S]
    (φ : R →+* S) (hφ : ∀ a, φ (algebraMap Fp R a) = algebraMap Fp S a) (β d : ℕ → R)
    (v : Revealed G) : φ (reveal G β d v) = reveal G (φ ∘ β) (φ ∘ d) v := by
  rcases v with ⟨m, q⟩ | j
  · simp only [reveal]
    rw [map_valueAt, hφ]
    congr 1
    funext l
    exact map_layer φ β d m l
  · exact map_layer φ β d 4 j

/-- The coordinate `part` (`0`: real, `1`: imaginary) of an element of `PolyFp2`. -/
def coordOf (part : Fin 2) (y : PolyFp2 Coord) : MvPolynomial Coord Fp :=
  if part = 0 then y.re else y.im

theorem coordOf_totalDegree_le (part : Fin 2) {n : ℕ} {y : PolyFp2 Coord} (hy : DegLE n y) :
    (coordOf part y).totalDegree ≤ n := by
  unfold coordOf
  split_ifs
  exacts [hy.1, hy.2]

/-- **The FRI mask matrix.** Rows: the `𝔽_p`-coordinates of the revealed values. Columns: the
basis masks `X^i` (`i < nR`) of each of the two mask columns. Entry: that coordinate of what FRI
reveals of the DEEP mask part, as a polynomial in the twelve challenge coordinates. -/
noncomputable def revealMatrix :
    Matrix (Revealed G × Fin 2) (Fin 2 × Fin G.nR) (MvPolynomial Coord Fp) :=
  fun v col ↦ coordOf v.2 (reveal G betaV (fun l ↦ (deepCol G col.1 col.2).coeff l) v.1)

/-- **Entry degree.** Every entry of the FRI mask matrix has total degree at most `102`:
`87` from `α`, `3` from the quotient factors in `z`, and `3` from each of the four folds. -/
theorem revealMatrix_degree (v : Revealed G × Fin 2) (col : Fin 2 × Fin G.nR) :
    (revealMatrix G v col).totalDegree ≤ 102 := by
  have hd : ∀ l, DegLE 90 ((deepCol G col.1 col.2).coeff l) := deepCol_deg G col.1 col.2
  have hv : DegLE 102 (reveal G betaV (fun l ↦ (deepCol G col.1 col.2).coeff l) v.1) := by
    rcases v with ⟨⟨m, q⟩ | j, part⟩
    · have hm := valueAt_degLE (len := G.len m)
        (fun l ↦ DegLE.layer betaV_deg hd m l) (G.pts m q)
      exact hm.mono (n := 102) (by have := m.isLt; omega)
    · exact DegLE.layer betaV_deg hd 4 j
  exact coordOf_totalDegree_le v.2 hv

end Reveal

/-! ### What the model means over `𝔽_{p²}` -/

section Semantics

/-- `μ_u = X² − 2 Re(u) X + N(u)`, the minimal polynomial over `𝔽_p` of `u ∉ 𝔽_p`. -/
noncomputable def quadFactor (u : Fp2) : Fp[X] :=
  X ^ 2 - C (2 * u.re) * X + C (u.re ^ 2 - 7 * u.im ^ 2)

theorem quadFactor_map (u : Fp2) :
    (quadFactor u).map (algebraMap Fp Fp2) = (X - C u) * (X - C (star u)) := by
  have h1 : algebraMap Fp Fp2 (2 * u.re) = u + star u := by
    ext
    · simp; ring
    · simp
  have h2 : algebraMap Fp Fp2 (u.re ^ 2 - 7 * u.im ^ 2) = u * star u := by
    ext <;> simp only [QuadraticAlgebra.algebraMap_re, QuadraticAlgebra.algebraMap_im,
      QuadraticAlgebra.re_mul, QuadraticAlgebra.im_mul, QuadraticAlgebra.re_star,
      QuadraticAlgebra.im_star] <;> ring
  have e : C (algebraMap Fp Fp2 (2 * u.re)) = C u + C (star u) := by rw [h1, C_add]
  simp only [quadFactor, Polynomial.map_add, Polynomial.map_sub, Polynomial.map_mul,
    Polynomial.map_pow, Polynomial.map_X, Polynomial.map_C, h2, C_mul]
  have e2 : C (algebraMap Fp Fp2 (2 * u.re)) = C (algebraMap Fp Fp2 2) * C (algebraMap Fp Fp2 u.re) := by
    rw [map_mul, C_mul]
  linear_combination (-X) * e + X * e2

/-- The mask column `M = W · μ_z · μ_{gz} · X^i`, a polynomial over `𝔽_p`. -/
noncomputable def maskPoly (W : Fp[X]) (g : Fp) (z : Fp2) (i : ℕ) : Fp[X] :=
  W * quadFactor z * quadFactor (algebraMap Fp Fp2 g * z) * X ^ i

/-- The quotient at `z`, over `𝔽_{p²}`. -/
noncomputable def quot0 (W : Fp[X]) (g : Fp) (z : Fp2) (i : ℕ) : Fp2[X] :=
  W.map (algebraMap Fp Fp2) * (X - C (star z)) *
    ((X - C (algebraMap Fp Fp2 g * z)) * (X - C (star (algebraMap Fp Fp2 g * z)))) * X ^ i

/-- The quotient at `g z`, over `𝔽_{p²}`. -/
noncomputable def quot1 (W : Fp[X]) (g : Fp) (z : Fp2) (i : ℕ) : Fp2[X] :=
  W.map (algebraMap Fp Fp2) * ((X - C z) * (X - C (star z))) *
    (X - C (star (algebraMap Fp Fp2 g * z))) * X ^ i

theorem quot0_spec (W : Fp[X]) (g : Fp) (z : Fp2) (i : ℕ) :
    (X - C z) * quot0 W g z i = (maskPoly W g z i).map (algebraMap Fp Fp2) := by
  simp only [maskPoly, quot0, Polynomial.map_mul, quadFactor_map, Polynomial.map_pow,
    Polynomial.map_X]
  ring

theorem quot1_spec (W : Fp[X]) (g : Fp) (z : Fp2) (i : ℕ) :
    (X - C (algebraMap Fp Fp2 g * z)) * quot1 W g z i =
      (maskPoly W g z i).map (algebraMap Fp Fp2) := by
  simp only [maskPoly, quot1, Polynomial.map_mul, quadFactor_map, Polynomial.map_pow,
    Polynomial.map_X]
  ring

/-- The mask vanishes at `z`: it lies in the kernel of the opening at `z`. -/
theorem maskPoly_eval_z (W : Fp[X]) (g : Fp) (z : Fp2) (i : ℕ) :
    ((maskPoly W g z i).map (algebraMap Fp Fp2)).eval z = 0 := by
  rw [← quot0_spec]; simp

/-- The mask vanishes at `g z`. -/
theorem maskPoly_eval_gz (W : Fp[X]) (g : Fp) (z : Fp2) (i : ℕ) :
    ((maskPoly W g z i).map (algebraMap Fp Fp2)).eval (algebraMap Fp Fp2 g * z) = 0 := by
  rw [← quot1_spec]; simp

/-- The mask vanishes at every opened row, the roots of `W`. -/
theorem maskPoly_eval_root (W : Fp[X]) (g : Fp) (z : Fp2) (i : ℕ) {x : Fp}
    (hx : W.eval x = 0) : (maskPoly W g z i).eval x = 0 := by
  simp [maskPoly, hx]

/-- **The model's quotient is the DEEP quotient.** At every `x ≠ z`,
`quot0(x) = (M(x) − M(z)) / (x − z)` for the mask `M = W μ_z μ_{gz} X^i`. The same holds for
`quot1` at `g z`. -/
theorem deep_quotient_eval (W : Fp[X]) (g : Fp) (z : Fp2) (i : ℕ) {x : Fp2} (hx : x ≠ z) :
    (quot0 W g z i).eval x =
      (((maskPoly W g z i).map (algebraMap Fp Fp2)).eval x -
        ((maskPoly W g z i).map (algebraMap Fp Fp2)).eval z) / (x - z) := by
  rw [maskPoly_eval_z, sub_zero, ← quot0_spec, eval_mul]
  simp only [eval_sub, eval_X, eval_C]
  field_simp [sub_ne_zero.mpr hx]

theorem deep_quotient_eval' (W : Fp[X]) (g : Fp) (z : Fp2) (i : ℕ) {x : Fp2}
    (hx : x ≠ algebraMap Fp Fp2 g * z) :
    (quot1 W g z i).eval x =
      (((maskPoly W g z i).map (algebraMap Fp Fp2)).eval x -
        ((maskPoly W g z i).map (algebraMap Fp Fp2)).eval (algebraMap Fp Fp2 g * z)) /
        (x - algebraMap Fp Fp2 g * z) := by
  rw [maskPoly_eval_gz, sub_zero, ← quot1_spec, eval_mul]
  simp only [eval_sub, eval_X, eval_C]
  field_simp [sub_ne_zero.mpr hx]

variable (G : Geometry)

theorem ev_comp_algebraMap (c : Coord → Fp) :
    (ev c).comp (algebraMap Fp (PolyFp2 Coord)) = algebraMap Fp Fp2 :=
  RingHom.ext (ev_algebraMap c)

/-- The challenges at a point `c` of coordinates. -/
def zAt (c : Coord → Fp) : Fp2 := ⟨c 0, c 1⟩

def alphaAt (c : Coord → Fp) : Fp2 := ⟨c 2, c 3⟩

/-- **Evaluating the model gives the `𝔽_{p²}` computation.** At `c`, the DEEP mask part of the
model is `α^{e₀} · quot0 + α^{e₁} · quot1` for the mask `W μ_z μ_{gz} X^i`. -/
theorem deepCol_map (c : Coord → Fp) (col : Fin 2) (i : ℕ) :
    (deepCol G col i).map (ev c) =
      C (alphaAt c ^ deepExp 0 col) * quot0 G.W G.g (zAt c) i +
        C (alphaAt c ^ deepExp 1 col) * quot1 G.W G.g (zAt c) i := by
  simp [deepCol, quot0V, quot1V, quot0, quot1, gzV, zV, alphaV, zAt, alphaAt,
    Polynomial.map_map, ev_comp_algebraMap]

/-- **The evaluated matrix.** At every point `c`, the entry of the FRI mask matrix is the
coordinate of what FRI reveals, computed over `𝔽_{p²}` with the fold challenges of `c`, of the
DEEP mask part `Σ_k α^{44k+42+col} (M − M(z_k))/(X − z_k)` of the mask
`M = W μ_z μ_{gz} X^i`. -/
theorem revealMatrix_eval (c : Coord → Fp) (v : Revealed G) (part : Fin 2)
    (col : Fin 2 × Fin G.nR) :
    (revealMatrix G).map (MvPolynomial.eval c) (v, part) col =
      let y := reveal G (ev c ∘ betaV) (fun l ↦
        (C (alphaAt c ^ deepExp 0 col.1) * quot0 G.W G.g (zAt c) col.2 +
          C (alphaAt c ^ deepExp 1 col.1) * quot1 G.W G.g (zAt c) col.2).coeff l) v
      if part = 0 then y.re else y.im := by
  have key : ev c (reveal G betaV (fun l ↦ (deepCol G col.1 col.2).coeff l) v) =
      reveal G (ev c ∘ betaV) (fun l ↦
        (C (alphaAt c ^ deepExp 0 col.1) * quot0 G.W G.g (zAt c) col.2 +
          C (alphaAt c ^ deepExp 1 col.1) * quot1 G.W G.g (zAt c) col.2).coeff l) v := by
    rw [map_reveal G (ev c) (ev_algebraMap c), ← deepCol_map]
    congr 1
    funext l
    simp [coeff_map]
  simp only [Matrix.map_apply, revealMatrix, coordOf]
  rw [← key]
  split_ifs <;> rfl

end Semantics

end Shield.Zk
