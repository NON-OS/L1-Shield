/-
Copyright (c) 2026 NØNOS. All rights reserved.

# Public-word limb packing

A model of `PublicWords.publicsOf` (contracts/shield/verifier/PublicWords.sol:33-68), which
expands the pool's `N × W` public words into the Goldilocks limbs that the STARK transcript absorbs,
and of the pool-side canonicality check `Goldilocks.isCanonicalDigest`
(contracts/shield/libraries/Goldilocks.sol:16-22) applied in `ShieldedPool._decodeIntent`.

Line numbers refer to the contracts in this repository. The layout is a parameter (`Layout`). The
source accepts `INTENT_WORDS = 11` (32 limbs, `Layout.v1`) or `INTENT_WORDS_FEE_RECIPIENT = 12`
(36 limbs), PublicWords.sol:12-13,21-24. `Layout.v2` reads words 10 and 11 as four 64-bit limbs.
The contract splits them into 48-bit limbs (PublicWords.sol:50-55), which no layout here models.
Every theorem is proved for an arbitrary layout and then instantiated.

Main results.
* `publicsOf_ok_iff_canonical` : `publicsOf` succeeds iff the layout is whole and every limb is `< p`.
* `publicsOf_lt_P`, `publicsOf_lt_two_pow` : every emitted limb is `< p < 2^64`.
* `publicsOf_length` : `N · W` words give `N · (limbs per intent)` limbs.
* `pack_publicsOf` : words → limbs → words is the identity on `uint256` words.
* `publicsOf_pack` : limbs → words → limbs is the identity on canonical limb vectors.
* `publicsOf_injective` : distinct `uint256` word vectors never expand to the same limbs.
* `isCanonicalDigest_iff` : the pool's digest check is the verifier's four-limb check.
* `pool_range_admits_noncanonical`, `recipient_not_always_representable` : the model-to-code gaps.
-/
import Mathlib.Tactic.NormNum
import Mathlib.Tactic.IntervalCases
import Mathlib.Tactic.Ring
import Mathlib.Tactic.Push
import Mathlib.Tactic.Positivity
import Mathlib.Data.Nat.Basic
import Shield.Field.Basic

namespace Shield.Protocol.Limbs

/-! ## Constants -/

/-- The Goldilocks prime `p`, `PublicWords.P` (PublicWords.sol:10) and `Goldilocks.P`
(Goldilocks.sol:7). -/
abbrev P : ℕ := 0xFFFFFFFF00000001

/-- The limb mask `LIMB = 2^64 - 1` (PublicWords.sol:11). -/
abbrev LIMB : ℕ := 0xFFFFFFFFFFFFFFFF

/-- This `P` is the modulus `Shield.Field.P` of the field modules (formal/lean/API.md). -/
theorem P_eq_field : P = Shield.Field.P := Shield.Field.P_val.symm

/-- `p = 2^64 - 2^32 + 1`. -/
theorem P_eq : P = 2 ^ 64 - 2 ^ 32 + 1 := by norm_num

/-- `p < 2^64`: a canonical limb fits in 64 bits. -/
theorem P_lt_two_pow : P < 2 ^ 64 := by norm_num

/-- The upper bound of a Solidity `uint256`. -/
abbrev WORD : ℕ := 2 ^ 256

/-! ## Limb extraction -/

/-- The `l`-th limb of `word`, `(word >> (64 * l)) & LIMB` (PublicWords.sol:58,
`Goldilocks.limb` at Goldilocks.sol:24-26). -/
def limb (word l : ℕ) : ℕ := (word >>> (64 * l)) &&& LIMB

/-- The bitwise limb is the arithmetic digit `⌊word / 2^{64 l}⌋ mod 2^64`. -/
theorem limb_eq (word l : ℕ) : limb word l = word / 2 ^ (64 * l) % 2 ^ 64 := by
  unfold limb
  rw [Nat.shiftRight_eq_div_pow, show LIMB = 2 ^ 64 - 1 by norm_num,
    Nat.and_two_pow_sub_one_eq_mod]

/-- Every extracted limb is below `2^64`, before any canonicality check. -/
theorem limb_lt (word l : ℕ) : limb word l < 2 ^ 64 := by
  rw [limb_eq]; exact Nat.mod_lt _ (by positivity)

/-! ## Layouts -/

/-- An intent layout: `words` public words per intent (`perIntent`, PublicWords.sol:33), of which
the positions with `isDigest` carry a four-limb digest and the rest a single limb
(PublicWords.sol:56). -/
structure Layout where
  /-- Words per intent, `INTENT_WORDS`. -/
  words : ℕ
  /-- Whether the word at a position within the intent is a four-limb digest. -/
  isDigest : ℕ → Bool
  /-- `INTENT_WORDS > 0`. -/
  words_pos : 0 < words

/-- The eleven-word layout, `if (w <= 5 || w >= 10)` (PublicWords.sol:56): `0..5` and `10`
digests, `6..9` single limbs. -/
def Layout.v1 : Layout where
  words := 11
  isDigest w := decide (w ≤ 5) || decide (10 ≤ w)
  words_pos := by norm_num

/-- A twelve-word layout with `if (w <= 5 || w >= 10)`, so word `11` (`feeRecipient`, limbs 32-35)
is a further four-limb digest. The contract's twelve-word branch splits words 10 and 11 into 48-bit
limbs (PublicWords.sol:50-55), so this layout is not that branch. -/
def Layout.v2 : Layout where
  words := 12
  isDigest w := decide (w ≤ 5) || decide (10 ≤ w)
  words_pos := by norm_num

variable (L : Layout)

/-- Number of limbs contributed by the word at global index `j`. -/
def size (j : ℕ) : ℕ := if L.isDigest (j % L.words) then 4 else 1

/-- `∑_{k < n} size (j + k)`, the number of limbs of `n` consecutive words starting at `j`. -/
def sizeSum : ℕ → ℕ → ℕ
  | _, 0 => 0
  | j, n + 1 => size L j + sizeSum (j + 1) n

/-- Limbs per intent, `limbs(perIntent)` (PublicWords.sol:21-24). -/
def limbsPerIntent : ℕ := sizeSum L 0 L.words

/-- The eleven-word layout has 32 limbs per intent, matching `limbs(11) = 4 · 11 - 12 = 32`. -/
theorem limbsPerIntent_v1 : limbsPerIntent Layout.v1 = 32 := by decide

/-- `Layout.v2` has 36 limbs per intent, matching `limbs(12) = 4 · 12 - 12 = 36`. -/
theorem limbsPerIntent_v2 : limbsPerIntent Layout.v2 = 36 := by decide

/-! ## The contract function -/

/-- Revert reasons of `publicsOf` (PublicWords.sol:17,19). -/
inductive Err
  /-- `BadPublicLayout(length)`. -/
  | badLayout (length : ℕ)
  /-- `NonCanonicalLimb(word, limb, value)`. -/
  | nonCanonical (word limb value : ℕ)
  deriving DecidableEq

/-- `if (v >= P) revert NonCanonicalLimb(j, l, v); out[k++] = v;` (PublicWords.sol:59-60,63-64). -/
def checkLimb (j l v : ℕ) : Except Err ℕ :=
  if P ≤ v then .error (.nonCanonical j l v) else .ok v

/-- The inner body of the loop for the word at global index `j = base + w`
(PublicWords.sol:49-65): four checked limbs, low limb first, for a digest position, and otherwise
the word itself, checked. -/
def expandWord (j word : ℕ) : Except Err (List ℕ) :=
  if L.isDigest (j % L.words) then do
    let a ← checkLimb j 0 (limb word 0)
    let b ← checkLimb j 1 (limb word 1)
    let c ← checkLimb j 2 (limb word 2)
    let d ← checkLimb j 3 (limb word 3)
    pure [a, b, c, d]
  else do
    let a ← checkLimb j 0 word
    pure [a]

/-- The two nested loops of PublicWords.sol:46-67, flattened: words are visited in order of their
global index `base + w`, and the first failing check reverts. -/
def expandAll : ℕ → List ℕ → Except Err (List (List ℕ))
  | _, [] => .ok []
  | j, w :: ws => do
    let g ← expandWord L j w
    let gs ← expandAll (j + 1) ws
    pure (g :: gs)

/-- `PublicWords.publicsOf(publicInputs, perIntent)` (PublicWords.sol:33-68). The width check
`limbs(perIntent)` (line 38) is the choice of `Layout`. -/
def publicsOf (ws : List ℕ) : Except Err (List ℕ) :=
  if ws.length = 0 ∨ ws.length % L.words ≠ 0 then .error (.badLayout ws.length)
  else (expandAll L 0 ws).map List.flatten

/-- The canonicality condition that `publicsOf` enforces on the word at global index `j`. -/
def WordCanonical (j word : ℕ) : Prop :=
  if L.isDigest (j % L.words) then ∀ l < 4, limb word l < P else word < P

/-! ## The inverse direction: packing limbs into words -/

/-- Little-endian base-`2^64` evaluation: `∑ᵢ gᵢ · 2^{64 i}`. -/
def packLimbs : List ℕ → ℕ
  | [] => 0
  | x :: xs => x + 2 ^ 64 * packLimbs xs

/-- Split a limb vector into the per-word groups of `n` consecutive words starting at `j`. -/
def unflatten : ℕ → ℕ → List ℕ → List (List ℕ)
  | _, 0, _ => []
  | j, n + 1, ls => ls.take (size L j) :: unflatten (j + 1) n (ls.drop (size L j))

/-- The packing map, limbs → words. -/
def pack (ls : List ℕ) : List ℕ :=
  (unflatten L 0 (L.words * (ls.length / limbsPerIntent L)) ls).map packLimbs

/-- A list of limb groups has the shape of the words starting at global index `j`. -/
def Shaped : ℕ → List (List ℕ) → Prop
  | _, [] => True
  | j, g :: gs => g.length = size L j ∧ Shaped (j + 1) gs

/-! ## Monadic bookkeeping -/

section Except

variable {α β ε : Type}

/-- A bind in `Except` succeeds iff both halves do. -/
theorem bind_eq_ok {x : Except ε α} {f : α → Except ε β} {b : β} :
    (x >>= f) = .ok b ↔ ∃ a, x = .ok a ∧ f a = .ok b := by
  cases x with
  | error e => simp [bind, Except.bind]
  | ok a => simp [bind, Except.bind]

/-- `pure a = ok b` in `Except` iff `a = b`. -/
theorem pure_eq_ok {a b : α} : (pure a : Except ε α) = .ok b ↔ a = b := by
  simp [pure, Except.pure]

end Except

/-- `checkLimb` succeeds iff the value is canonical, and then returns it unchanged. -/
theorem checkLimb_eq_ok {j l v x : ℕ} : checkLimb j l v = .ok x ↔ v < P ∧ x = v := by
  unfold checkLimb
  split_ifs with h
  · simp only [false_iff, not_and]; intro h'; omega
  · simp only [Except.ok.injEq]; constructor
    · rintro rfl; exact ⟨by omega, rfl⟩
    · rintro ⟨-, rfl⟩; rfl

/-- The digest branch of `expandWord`. -/
theorem expandWord_digest {j word : ℕ} {g : List ℕ} (h : L.isDigest (j % L.words) = true) :
    expandWord L j word = .ok g ↔
      (∀ l < 4, limb word l < P) ∧ g = [limb word 0, limb word 1, limb word 2, limb word 3] := by
  simp only [expandWord, h, ite_true, bind_eq_ok, pure_eq_ok, checkLimb_eq_ok]
  constructor
  · rintro ⟨a, ⟨ha, rfl⟩, b, ⟨hb, rfl⟩, c, ⟨hc, rfl⟩, d, ⟨hd, rfl⟩, rfl⟩
    refine ⟨fun l hl => ?_, rfl⟩
    rcases (by omega : l = 0 ∨ l = 1 ∨ l = 2 ∨ l = 3) with rfl | rfl | rfl | rfl
    exacts [ha, hb, hc, hd]
  · rintro ⟨hl, rfl⟩
    exact ⟨_, ⟨hl 0 (by norm_num), rfl⟩, _, ⟨hl 1 (by norm_num), rfl⟩,
      _, ⟨hl 2 (by norm_num), rfl⟩, _, ⟨hl 3 (by norm_num), rfl⟩, rfl⟩

/-- The single-limb branch of `expandWord`. -/
theorem expandWord_single {j word : ℕ} {g : List ℕ} (h : L.isDigest (j % L.words) = false) :
    expandWord L j word = .ok g ↔ word < P ∧ g = [word] := by
  simp only [expandWord, h, Bool.false_eq_true, ite_false, bind_eq_ok, pure_eq_ok,
    checkLimb_eq_ok]
  constructor
  · rintro ⟨a, ⟨ha, rfl⟩, rfl⟩; exact ⟨ha, rfl⟩
  · rintro ⟨ha, rfl⟩; exact ⟨_, ⟨ha, rfl⟩, rfl⟩

/-- `expandWord` succeeds iff the word is canonical. -/
theorem expandWord_isOk {j word : ℕ} :
    (∃ g, expandWord L j word = .ok g) ↔ WordCanonical L j word := by
  unfold WordCanonical
  cases h : L.isDigest (j % L.words)
  · simp [expandWord_single L h]
  · simp [expandWord_digest L h]

/-- Every limb `expandWord` emits is canonical. -/
theorem expandWord_lt_P {j word : ℕ} {g : List ℕ} (hg : expandWord L j word = .ok g) :
    ∀ x ∈ g, x < P := by
  cases h : L.isDigest (j % L.words)
  · obtain ⟨hw, rfl⟩ := (expandWord_single L h).1 hg; simpa using hw
  · obtain ⟨hl, rfl⟩ := (expandWord_digest L h).1 hg
    simp only [List.mem_cons, List.not_mem_nil, or_false]
    rintro x (rfl | rfl | rfl | rfl)
    exacts [hl 0 (by norm_num), hl 1 (by norm_num), hl 2 (by norm_num), hl 3 (by norm_num)]

/-- `expandWord` emits `size j` limbs. -/
theorem expandWord_length {j word : ℕ} {g : List ℕ} (hg : expandWord L j word = .ok g) :
    g.length = size L j := by
  unfold size
  cases h : L.isDigest (j % L.words)
  · obtain ⟨-, rfl⟩ := (expandWord_single L h).1 hg; rfl
  · obtain ⟨-, rfl⟩ := (expandWord_digest L h).1 hg; rfl

/-! ## Arithmetic of four limbs -/

/-- A `uint256` is the base-`2^64` evaluation of its four limbs. -/
theorem packLimbs_limbs {word : ℕ} (hw : word < WORD) :
    packLimbs [limb word 0, limb word 1, limb word 2, limb word 3] = word := by
  simp only [packLimbs, limb_eq]
  norm_num at hw ⊢
  omega

/-- Four 64-bit limbs are recovered from their evaluation. -/
theorem limbs_packLimbs {a b c d : ℕ} (ha : a < 2 ^ 64) (hb : b < 2 ^ 64) (hc : c < 2 ^ 64)
    (hd : d < 2 ^ 64) :
    [limb (packLimbs [a, b, c, d]) 0, limb (packLimbs [a, b, c, d]) 1,
      limb (packLimbs [a, b, c, d]) 2, limb (packLimbs [a, b, c, d]) 3] = [a, b, c, d] := by
  simp only [packLimbs, limb_eq, List.cons.injEq, and_true]
  norm_num at ha hb hc hd ⊢
  omega

/-- The evaluation of a single limb is the limb. -/
theorem packLimbs_singleton (x : ℕ) : packLimbs [x] = x := by simp [packLimbs]

/-! ## Periodicity of the layout -/

/-- The limb count of a word depends only on its position within the intent. -/
theorem size_add_words (j : ℕ) : size L (j + L.words) = size L j := by
  simp [size, Nat.add_mod_right]

/-- Every word contributes at least one limb. -/
theorem one_le_size (j : ℕ) : 1 ≤ size L j := by
  unfold size; split_ifs <;> norm_num

/-- `sizeSum` is additive over concatenated ranges. -/
theorem sizeSum_add (j a b : ℕ) : sizeSum L j (a + b) = sizeSum L j a + sizeSum L (j + a) b := by
  induction a generalizing j with
  | zero => simp [sizeSum]
  | succ a ih =>
    rw [Nat.succ_add, sizeSum, ih, sizeSum]
    rw [show j + 1 + a = j + (a + 1) by omega]; omega

/-- `sizeSum` is invariant under a shift by one intent. -/
theorem sizeSum_shift (j n : ℕ) : sizeSum L (j + L.words) n = sizeSum L j n := by
  induction n generalizing j with
  | zero => rfl
  | succ n ih =>
    simp only [sizeSum, size_add_words]
    rw [show j + L.words + 1 = j + 1 + L.words by omega, ih]

/-- The words of `m` whole intents carry `m · limbsPerIntent` limbs. -/
theorem sizeSum_intents (m : ℕ) : sizeSum L 0 (L.words * m) = limbsPerIntent L * m := by
  induction m with
  | zero => simp [sizeSum]
  | succ m ih =>
    have hshift : ∀ k, sizeSum L (L.words * k) L.words = limbsPerIntent L := by
      intro k
      induction k with
      | zero => simp [limbsPerIntent]
      | succ k ihk => rw [Nat.mul_succ, sizeSum_shift, ihk]
    calc sizeSum L 0 (L.words * (m + 1))
        = sizeSum L 0 (L.words * m) + sizeSum L (0 + L.words * m) L.words := by
          rw [Nat.mul_succ, sizeSum_add]
      _ = limbsPerIntent L * m + limbsPerIntent L := by rw [ih, Nat.zero_add, hshift]
      _ = limbsPerIntent L * (m + 1) := by ring

/-- `n` words carry at least `n` limbs. -/
theorem le_sizeSum (j n : ℕ) : n ≤ sizeSum L j n := by
  induction n generalizing j with
  | zero => rfl
  | succ n ih => have := one_le_size L j; have := ih (j + 1); simp only [sizeSum]; omega

/-- Every intent carries at least one limb. -/
theorem limbsPerIntent_pos : 0 < limbsPerIntent L :=
  lt_of_lt_of_le L.words_pos (le_sizeSum L 0 L.words)

/-! ## Groups, flattening and unflattening -/

/-- A shaped list of groups flattens to `sizeSum` limbs. -/
theorem Shaped.length_flatten {j : ℕ} {gs : List (List ℕ)} (h : Shaped L j gs) :
    gs.flatten.length = sizeSum L j gs.length := by
  induction gs generalizing j with
  | nil => rfl
  | cons g gs ih =>
    obtain ⟨hg, hgs⟩ := h
    simp [sizeSum, hg, ih hgs]

/-- `unflatten` inverts `flatten` on shaped groups. -/
theorem unflatten_flatten {j : ℕ} {gs : List (List ℕ)} (h : Shaped L j gs) :
    unflatten L j gs.length gs.flatten = gs := by
  induction gs generalizing j with
  | nil => rfl
  | cons g gs ih =>
    obtain ⟨hg, hgs⟩ := h
    simp only [List.length_cons, List.flatten_cons, unflatten, ← hg, List.take_left',
      List.drop_left', ih hgs]

/-- `flatten` inverts `unflatten` on a limb vector of the right length, and the groups are shaped. -/
theorem flatten_unflatten {j n : ℕ} {ls : List ℕ} (h : ls.length = sizeSum L j n) :
    (unflatten L j n ls).flatten = ls ∧ Shaped L j (unflatten L j n ls) ∧
      (unflatten L j n ls).length = n := by
  induction n generalizing j ls with
  | zero =>
    simp only [sizeSum] at h
    simp [unflatten, Shaped, List.length_eq_zero_iff.1 h]
  | succ n ih =>
    simp only [sizeSum] at h
    obtain ⟨h1, h2, h3⟩ := ih (j := j + 1) (ls := ls.drop (size L j)) (by simp [h])
    refine ⟨?_, ⟨?_, h2⟩, by simp [unflatten, h3]⟩
    · simp [unflatten, h1]
    · simp [List.length_take]; omega

/-- A successful `expandAll` returns groups of the right shape, one per word. -/
theorem expandAll_shaped {j : ℕ} {ws : List ℕ} {gs : List (List ℕ)}
    (h : expandAll L j ws = .ok gs) : Shaped L j gs ∧ gs.length = ws.length := by
  induction ws generalizing j gs with
  | nil => simp only [expandAll, Except.ok.injEq] at h; subst h; exact ⟨trivial, rfl⟩
  | cons w ws ih =>
    simp only [expandAll, bind_eq_ok, pure_eq_ok] at h
    obtain ⟨g, hg, gs', hgs', rfl⟩ := h
    obtain ⟨hs, hl⟩ := ih hgs'
    exact ⟨⟨expandWord_length L hg, hs⟩, by simp [hl]⟩

/-- `expandAll` succeeds iff every word is canonical at its global index. -/
theorem expandAll_isOk {j : ℕ} {ws : List ℕ} :
    (∃ gs, expandAll L j ws = .ok gs) ↔
      ∀ i (hi : i < ws.length), WordCanonical L (j + i) ws[i] := by
  induction ws generalizing j with
  | nil => simp [expandAll]
  | cons w ws ih =>
    simp only [expandAll, bind_eq_ok, pure_eq_ok]
    constructor
    · rintro ⟨_, g, hg, gs, hgs, rfl⟩ i hi
      cases i with
      | zero => simpa using (expandWord_isOk L).1 ⟨g, hg⟩
      | succ i =>
        have := (ih (j := j + 1)).1 ⟨gs, hgs⟩ i (by simpa using hi)
        simpa [show j + (i + 1) = j + 1 + i by omega] using this
    · intro hall
      obtain ⟨g, hg⟩ := (expandWord_isOk L).2 (by simpa using hall 0 (by simp))
      obtain ⟨gs, hgs⟩ := (ih (j := j + 1)).2 fun i hi => by
        have := hall (i + 1) (by simp; omega)
        rw [List.getElem_cons_succ] at this
        rwa [show j + (i + 1) = j + 1 + i by omega] at this
      exact ⟨_, g, hg, gs, hgs, rfl⟩

/-- Every limb inside a successful `expandAll` is canonical. -/
theorem expandAll_lt_P {j : ℕ} {ws : List ℕ} {gs : List (List ℕ)}
    (h : expandAll L j ws = .ok gs) : ∀ g ∈ gs, ∀ x ∈ g, x < P := by
  induction ws generalizing j gs with
  | nil => simp only [expandAll, Except.ok.injEq] at h; subst h; simp
  | cons w ws ih =>
    simp only [expandAll, bind_eq_ok, pure_eq_ok] at h
    obtain ⟨g, hg, gs', hgs', rfl⟩ := h
    intro g' hg'
    rcases List.mem_cons.1 hg' with rfl | hmem
    · exact expandWord_lt_P L hg
    · exact ih hgs' g' hmem

/-- Packing inverts a successful `expandAll` on `uint256` words. -/
theorem map_packLimbs_expandAll {j : ℕ} {ws : List ℕ} {gs : List (List ℕ)}
    (hw : ∀ w ∈ ws, w < WORD) (h : expandAll L j ws = .ok gs) : gs.map packLimbs = ws := by
  induction ws generalizing j gs with
  | nil => simp only [expandAll, Except.ok.injEq] at h; subst h; rfl
  | cons w ws ih =>
    simp only [expandAll, bind_eq_ok, pure_eq_ok] at h
    obtain ⟨g, hg, gs', hgs', rfl⟩ := h
    simp only [List.map_cons, List.cons.injEq]
    refine ⟨?_, ih (fun x hx => hw x (List.mem_cons_of_mem _ hx)) hgs'⟩
    cases hd : L.isDigest (j % L.words)
    · obtain ⟨-, rfl⟩ := (expandWord_single L hd).1 hg; exact packLimbs_singleton w
    · obtain ⟨-, rfl⟩ := (expandWord_digest L hd).1 hg
      exact packLimbs_limbs (hw w List.mem_cons_self)

/-- On shaped groups of canonical limbs, `expandAll` inverts packing. -/
theorem expandAll_map_packLimbs {j : ℕ} {gs : List (List ℕ)} (hs : Shaped L j gs)
    (hP : ∀ g ∈ gs, ∀ x ∈ g, x < P) : expandAll L j (gs.map packLimbs) = .ok gs := by
  induction gs generalizing j with
  | nil => rfl
  | cons g gs ih =>
    obtain ⟨hg, hgs⟩ := hs
    have hrest := ih hgs fun g' hg' => hP g' (List.mem_cons_of_mem _ hg')
    have hgP : ∀ x ∈ g, x < P := hP g List.mem_cons_self
    have hexp : expandWord L j (packLimbs g) = .ok g := by
      unfold size at hg
      cases hd : L.isDigest (j % L.words)
      · rw [hd] at hg
        obtain ⟨x, rfl⟩ := List.length_eq_one_iff.1 hg
        rw [expandWord_single L hd, packLimbs_singleton]
        exact ⟨hgP x (by simp), rfl⟩
      · rw [hd] at hg
        match g, hg with
        | [a, b, c, d], _ =>
          have h64 : ∀ x ∈ [a, b, c, d], x < 2 ^ 64 := fun x hx => (hgP x hx).trans P_lt_two_pow
          have hl := limbs_packLimbs (h64 a (by simp)) (h64 b (by simp)) (h64 c (by simp))
            (h64 d (by simp))
          rw [expandWord_digest L hd, hl]
          refine ⟨fun l hlt => ?_, rfl⟩
          simp only [List.cons.injEq] at hl
          obtain ⟨h0, h1, h2, h3, -⟩ := hl
          interval_cases l
          · rw [h0]; exact hgP a (by simp)
          · rw [h1]; exact hgP b (by simp)
          · rw [h2]; exact hgP c (by simp)
          · rw [h3]; exact hgP d (by simp)
    simp only [List.map_cons, expandAll, hexp, hrest]; rfl

/-! ## Main theorems -/

/-- **Acceptance.** `publicsOf` returns limbs iff the batch is whole and nonempty and every word
is canonical at its position. Otherwise it reverts. -/
theorem publicsOf_ok_iff_canonical (ws : List ℕ) :
    (∃ ls, publicsOf L ws = .ok ls) ↔
      ws.length ≠ 0 ∧ ws.length % L.words = 0 ∧
        ∀ i (hi : i < ws.length), WordCanonical L i ws[i] := by
  unfold publicsOf
  by_cases hlay : ws.length = 0 ∨ ws.length % L.words ≠ 0
  · simp only [hlay, ite_true, reduceCtorEq, exists_false, false_iff]
    omega
  · simp only [hlay, ite_false]
    push Not at hlay
    have := expandAll_isOk L (j := 0) (ws := ws)
    simp only [Nat.zero_add] at this
    rw [← this]
    constructor
    · rintro ⟨ls, hls⟩
      cases h : expandAll L 0 ws with
      | error e => rw [h] at hls; cases hls
      | ok gs => exact ⟨hlay.1, hlay.2, gs, rfl⟩
    · rintro ⟨-, -, gs, hgs⟩; exact ⟨gs.flatten, by rw [hgs]; rfl⟩

/-- Decomposition of a successful `publicsOf` into its per-word groups. -/
theorem publicsOf_eq_ok {ws ls : List ℕ} (h : publicsOf L ws = .ok ls) :
    ws.length ≠ 0 ∧ ws.length % L.words = 0 ∧
      ∃ gs, expandAll L 0 ws = .ok gs ∧ ls = gs.flatten := by
  unfold publicsOf at h
  split_ifs at h with hlay
  push Not at hlay
  cases hgs : expandAll L 0 ws with
  | error e => rw [hgs] at h; cases h
  | ok gs =>
    rw [hgs] at h
    exact ⟨hlay.1, hlay.2, gs, rfl, (Except.ok.inj h).symm⟩

/-- **Canonicity.** Every limb `publicsOf` emits lies below `p`. -/
theorem publicsOf_lt_P {ws ls : List ℕ} (h : publicsOf L ws = .ok ls) : ∀ x ∈ ls, x < P := by
  obtain ⟨-, -, gs, hgs, rfl⟩ := publicsOf_eq_ok L h
  intro x hx
  obtain ⟨g, hg, hxg⟩ := List.mem_flatten.1 hx
  exact expandAll_lt_P L hgs g hg x hxg

/-- **Range.** Every limb `publicsOf` emits lies below `2^64`. -/
theorem publicsOf_lt_two_pow {ws ls : List ℕ} (h : publicsOf L ws = .ok ls) :
    ∀ x ∈ ls, x < 2 ^ 64 :=
  fun x hx => (publicsOf_lt_P L h x hx).trans P_lt_two_pow

/-- **Length.** `N · W` words expand to `N · limbsPerIntent` limbs (`N · 32` for `Layout.v1`,
`N · 36` for `Layout.v2`). -/
theorem publicsOf_length {ws ls : List ℕ} (h : publicsOf L ws = .ok ls) :
    ls.length = limbsPerIntent L * (ws.length / L.words) := by
  obtain ⟨-, hmod, gs, hgs, rfl⟩ := publicsOf_eq_ok L h
  obtain ⟨hs, hl⟩ := expandAll_shaped L hgs
  rw [hs.length_flatten, hl, ← sizeSum_intents]
  congr 1
  exact (Nat.mul_div_cancel' (Nat.dvd_of_mod_eq_zero hmod)).symm

/-- **Round trip, words → limbs → words.** On `uint256` words, `pack` inverts `publicsOf`. -/
theorem pack_publicsOf {ws ls : List ℕ} (hw : ∀ w ∈ ws, w < WORD)
    (h : publicsOf L ws = .ok ls) : pack L ls = ws := by
  have hlen := publicsOf_length L h
  obtain ⟨-, hmod, gs, hgs, rfl⟩ := publicsOf_eq_ok L h
  obtain ⟨hs, hl⟩ := expandAll_shaped L hgs
  have hn : L.words * (gs.flatten.length / limbsPerIntent L) = gs.length := by
    rw [hlen, Nat.mul_div_cancel_left _ (limbsPerIntent_pos L), hl]
    exact Nat.mul_div_cancel' (Nat.dvd_of_mod_eq_zero hmod)
  unfold pack
  rw [hn, unflatten_flatten L hs]
  exact map_packLimbs_expandAll L hw hgs

/-- **Round trip, limbs → words → limbs.** A vector of `m ≥ 1` intents' worth of canonical limbs
is recovered from its packing by `publicsOf`. -/
theorem publicsOf_pack {ls : List ℕ} {m : ℕ} (hm : 0 < m)
    (hlen : ls.length = limbsPerIntent L * m) (hP : ∀ x ∈ ls, x < P) :
    publicsOf L (pack L ls) = .ok ls := by
  have hn : L.words * (ls.length / limbsPerIntent L) = L.words * m := by
    rw [hlen, Nat.mul_div_cancel_left _ (limbsPerIntent_pos L)]
  have hlen' : ls.length = sizeSum L 0 (L.words * m) := by rw [sizeSum_intents, hlen]
  obtain ⟨hflat, hs, hgl⟩ := flatten_unflatten L hlen'
  set gs := unflatten L 0 (L.words * m) ls with hgs_def
  have hgP : ∀ g ∈ gs, ∀ x ∈ g, x < P := fun g hg x hx =>
    hP x (hflat ▸ List.mem_flatten.2 ⟨g, hg, hx⟩)
  unfold pack
  rw [hn, ← hgs_def]
  unfold publicsOf
  have hW := L.words_pos
  have hlay : ¬((gs.map packLimbs).length = 0 ∨ (gs.map packLimbs).length % L.words ≠ 0) := by
    simp only [List.length_map, hgl, Nat.mul_mod_right, ne_eq, not_true_eq_false, or_false]
    exact Nat.ne_of_gt (Nat.mul_pos hW hm)
  simp only [hlay, ite_false]
  rw [expandAll_map_packLimbs L hs hgP]
  simp [Except.map, hflat]

/-- **Injectivity.** Two `uint256` word vectors that `publicsOf` expands to the same limbs are
equal. -/
theorem publicsOf_injective {ws ws' ls : List ℕ} (hw : ∀ w ∈ ws, w < WORD)
    (hw' : ∀ w ∈ ws', w < WORD) (h : publicsOf L ws = .ok ls) (h' : publicsOf L ws' = .ok ls) :
    ws = ws' := by
  rw [← pack_publicsOf L hw h, ← pack_publicsOf L hw' h']

/-! ## The pool-side check -/

/-- `Goldilocks.isCanonicalDigest` (Goldilocks.sol:16-22), called in `ShieldedPool._decodeIntent`
(ShieldedPool.sol:674-677) and `absorb` (ShieldedPool.sol:351). -/
def isCanonicalDigest (v : ℕ) : Prop :=
  (v &&& LIMB) < P ∧ ((v >>> 64) &&& LIMB) < P ∧ ((v >>> 128) &&& LIMB) < P ∧ (v >>> 192) < P

/-- **The pool and the verifier agree on digests.** On a `uint256`, the pool's
`isCanonicalDigest` is the four-limb check of `publicsOf`. -/
theorem isCanonicalDigest_iff {v : ℕ} (hv : v < WORD) :
    isCanonicalDigest v ↔ ∀ l < 4, limb v l < P := by
  have e0 : v &&& LIMB = limb v 0 := by simp [limb]
  have e1 : (v >>> 64) &&& LIMB = limb v 1 := by simp [limb]
  have e2 : (v >>> 128) &&& LIMB = limb v 2 := by simp [limb]
  have e3 : v >>> 192 = limb v 3 := by
    rw [limb_eq, Nat.shiftRight_eq_div_pow]; norm_num at hv ⊢; omega
  unfold isCanonicalDigest
  rw [e0, e1, e2, e3]
  constructor
  · rintro ⟨h0, h1, h2, h3⟩ l hl
    rcases (by omega : l = 0 ∨ l = 1 ∨ l = 2 ∨ l = 3) with rfl | rfl | rfl | rfl
    exacts [h0, h1, h2, h3]
  · intro h; exact ⟨h 0 (by norm_num), h 1 (by norm_num), h 2 (by norm_num), h 3 (by norm_num)⟩

/-- **A bound of `2^64 - 1` admits non-canonical words.** A pool that bounded `publicAmount` and
`fee` by `2^64 - 1` would accept `p ≤ v < 2^64`, which only `publicsOf` inside the verifier rejects. -/
theorem pool_range_admits_noncanonical :
    ∃ v, v ≤ 2 ^ 64 - 1 ∧ ¬ WordCanonical Layout.v1 6 v := ⟨P, by norm_num, by
      simp [WordCanonical, Layout.v1]⟩

/-- **`MAX_VALUE = p - 2` closes it.** With that bound (Goldilocks.sol:10, checked at
ShieldedPool.sol:682,685), every amount and fee the pool accepts is a canonical single limb. -/
theorem maxValue_redeploy_canonical {v : ℕ} (hv : v ≤ P - 2) : v < P := by
  norm_num at hv ⊢; omega

/-- **Address words under four-limb layouts.** Words 10 (`recipient`) and 11 (`feeRecipient`) are
addresses, `< 2^160` (ShieldedPool.sol:697). `Layout.v1` and `Layout.v2` read them as four-limb
digests, so an address whose low 64 bits are `≥ p` (about `2^{-32}` of all addresses) never appears
in an accepted batch. The contract's twelve-word branch accepts every address (PublicWords.sol:50-55). -/
theorem recipient_not_always_representable :
    ∃ a, a < 2 ^ 160 ∧ ¬ WordCanonical Layout.v1 10 a ∧ ¬ WordCanonical Layout.v2 10 a ∧
      ¬ WordCanonical Layout.v2 11 a := by
  refine ⟨P, by norm_num, ?_, ?_, ?_⟩ <;>
  · simp only [WordCanonical, Layout.v1, Layout.v2]
    intro h
    have := h 0 (by norm_num)
    rw [limb_eq] at this
    norm_num at this

end Shield.Protocol.Limbs
