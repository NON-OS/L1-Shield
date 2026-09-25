import Mathlib.Data.List.Basic
import Mathlib.Tactic.Ring
import Mathlib.Tactic.Linarith

/-!
# Merkle binding for `StarkMerkle`

A model of `StarkMerkle._fold` (and of `RealQueryVerify._pathInPlace`, which is the same loop over
siblings read in place):

    node := leaf digest
    for each sibling:  node := H(NODE_TAG ‖ node ‖ sib)   if idx is even
                       node := H(NODE_TAG ‖ sib ‖ node)   if idx is odd
                       idx  := idx >> 1
    accept iff idx = 0 and node = root

Digests are `w`-byte strings (`w = 24` at launch). `H` stands for keccak256 of the
preimage cut to its first `w` bytes. A sibling enters the hash through its first `w` bytes only,
which is what the assembly hashes. Leaf digests are `H(LEAF_TAG ‖ payload)` for one of the six
leaf tags of `StarkMerkle`.

## What is proved

* `foldPath_index`: the final index is `idx / 2^depth`, so acceptance forces `idx < 2^depth`.
* `verify_extracts_collision`: two accepted openings of *different* digests at the same index,
  under the same root, with paths of the same length, yield two distinct preimages with equal
  hash. The collision is found by walking both paths.
* `opening_binding`: the same for leaf payloads, through the leaf tag.
* `binding_of_collisionFree`: under the explicit hypothesis `CollisionFree H` (no two distinct
  preimages hash alike), an accepted opening binds the payload to the root and index.
* `leaf_ne_node`: every leaf preimage differs from every node preimage, for all six leaf tags,
  because the tags differ at a byte both have (byte 19, `L` vs `N`, or byte 12 for the periodic
  tag). `leaf_node_confusion_is_collision`: a leaf digest equal to a node digest is a collision.

`CollisionFree H` is false for any real compressing hash. It is the idealisation the corollary
needs. The extraction theorem is the statement with content: forging an opening is at least as
hard as finding a keccak collision on `w`-byte truncations (birthday bound `2^{4w}`, `2^96` at
`w = 24`), with no loss in the reduction.
-/

namespace Shield.Merkle

/-- ASCII bytes of a tag, as the contract writes them. -/
def tagOf (s : String) : List UInt8 := s.toList.map fun c ↦ c.toNat.toUInt8

/-- `DOM_NODE`. -/
def nodeTag : List UInt8 := tagOf "NONOS-STARK-MERKLE-NODE"

/-- The six leaf tags of `StarkMerkle`. -/
inductive LeafKind
  | base | ext | pair | quad | wide | periodic
  deriving DecidableEq

/-- The tag for each leaf kind (`DOM_LEAF`, `DOM_LEAF_EXT`, the pair and quad literals,
`DOM_LEAF_WIDE`, `DOM_LEAF_PERIODIC`). -/
def leafTag : LeafKind → List UInt8
  | .base => tagOf "NONOS-STARK-MERKLE-LEAF"
  | .ext => tagOf "NONOS-STARK-MERKLE-LEAF-EXT"
  | .pair => tagOf "NONOS-STARK-MERKLE-LEAF-PAIR"
  | .quad => tagOf "NONOS-STARK-MERKLE-LEAF-QUAD"
  | .wide => tagOf "NONOS-STARK-MERKLE-LEAF-WIDE"
  | .periodic => tagOf "NONOS-STARK-PERIODIC-WIDE"

/-- A `w`-byte digest. -/
structure Digest (w : ℕ) where
  bytes : List UInt8
  len : bytes.length = w

theorem Digest.ext_bytes {w : ℕ} {d d' : Digest w} (h : d.bytes = d'.bytes) : d = d' := by
  cases d; cases d'; cases h; rfl

variable {w : ℕ} (H : List UInt8 → Digest w)

/-- The leaf preimage. -/
def leafPre (k : LeafKind) (payload : List UInt8) : List UInt8 := leafTag k ++ payload

/-- The node preimage `NODE_TAG ‖ left ‖ right`. -/
def nodePre (l r : Digest w) : List UInt8 := nodeTag ++ l.bytes ++ r.bytes

/-- One level of `_fold`. -/
def step (idx : ℕ) (node sib : Digest w) : Digest w :=
  if idx % 2 = 0 then H (nodePre node sib) else H (nodePre sib node)

/-- The loop of `_fold`: final node and final index. -/
def foldPath : ℕ → Digest w → List (Digest w) → Digest w × ℕ
  | idx, node, [] => (node, idx)
  | idx, node, s :: rest => foldPath (idx / 2) (step H idx node s) rest

/-- `_fold`'s acceptance: `idx` exhausted and the node equals the root. -/
def Verify (root : Digest w) (idx : ℕ) (leaf : Digest w) (path : List (Digest w)) : Prop :=
  (foldPath H idx leaf path).2 = 0 ∧ (foldPath H idx leaf path).1 = root

/-- Two distinct preimages with the same digest. -/
def Collision : Prop := ∃ x y : List UInt8, x ≠ y ∧ H x = H y

/-- The idealised hypothesis: `H` has no collisions. -/
def CollisionFree : Prop := ∀ x y : List UInt8, H x = H y → x = y

theorem foldPath_index (idx : ℕ) (node : Digest w) (path : List (Digest w)) :
    (foldPath H idx node path).2 = idx / 2 ^ path.length := by
  induction path generalizing idx node with
  | nil => simp [foldPath]
  | cons s rest ih => rw [foldPath, ih, Nat.div_div_eq_div_mul, List.length_cons, pow_succ']

/-- **Fixed depth.** An accepted opening has `idx < 2^depth`. -/
theorem index_lt_of_verify {root leaf : Digest w} {idx : ℕ} {path : List (Digest w)}
    (h : Verify H root idx leaf path) : idx < 2 ^ path.length := by
  have := h.1
  rw [foldPath_index, Nat.div_eq_zero_iff] at this
  rcases this with h0 | h0
  · exact absurd h0 (pow_ne_zero _ two_ne_zero)
  · exact h0

/-- Node preimages determine their children. -/
theorem nodePre_injective {l r l' r' : Digest w} (h : nodePre l r = nodePre l' r') :
    l = l' ∧ r = r' := by
  unfold nodePre at h
  rw [List.append_assoc, List.append_assoc] at h
  have h' := List.append_cancel_left h
  obtain ⟨h1, h2⟩ := List.append_inj h' (by rw [l.len, l'.len])
  exact ⟨Digest.ext_bytes h1, Digest.ext_bytes h2⟩

/-- If one level maps two different nodes to the same parent, that is a collision. -/
theorem step_collision {idx : ℕ} {d d' s s' : Digest w} (hne : d ≠ d')
    (h : step H idx d s = step H idx d' s') : Collision H := by
  unfold step at h
  split_ifs at h
  · exact ⟨_, _, fun e ↦ hne (nodePre_injective e).1, h⟩
  · exact ⟨_, _, fun e ↦ hne (nodePre_injective e).2, h⟩

/-- **Extraction.** Two accepted openings, at the same index and under the same root with paths of
the same length, of different digests, give a collision of `H`. -/
theorem verify_extracts_collision {root d d' : Digest w} {idx : ℕ} {p p' : List (Digest w)}
    (hlen : p.length = p'.length) (hv : Verify H root idx d p) (hv' : Verify H root idx d' p')
    (hne : d ≠ d') : Collision H := by
  have hroot : (foldPath H idx d p).1 = (foldPath H idx d' p').1 := hv.2.trans hv'.2.symm
  clear hv hv'
  induction p generalizing idx d d' p' with
  | nil =>
    cases p' with
    | nil => exact absurd hroot hne
    | cons _ _ => simp at hlen
  | cons s rest ih =>
    cases p' with
    | nil => simp at hlen
    | cons s' rest' =>
      by_cases he : step H idx d s = step H idx d' s'
      · exact step_collision H hne he
      · exact ih (by simpa using hlen) he hroot

/-- **Binding of leaf payloads.** Two accepted openings of different payloads of the same leaf kind,
at the same index under the same root with paths of the same length, give a collision of `H`. -/
theorem opening_binding {root : Digest w} {idx : ℕ} {k : LeafKind} {a a' : List UInt8}
    {p p' : List (Digest w)} (hlen : p.length = p'.length)
    (hv : Verify H root idx (H (leafPre k a)) p) (hv' : Verify H root idx (H (leafPre k a')) p')
    (hne : a ≠ a') : Collision H := by
  by_cases hd : H (leafPre k a) = H (leafPre k a')
  · exact ⟨_, _, fun e ↦ hne (List.append_cancel_left e), hd⟩
  · exact verify_extracts_collision H hlen hv hv' hd

/-- **Binding under `CollisionFree`.** An accepted opening fixes the payload. -/
theorem binding_of_collisionFree (hcr : CollisionFree H) {root : Digest w} {idx : ℕ}
    {k : LeafKind} {a a' : List UInt8} {p p' : List (Digest w)} (hlen : p.length = p'.length)
    (hv : Verify H root idx (H (leafPre k a)) p) (hv' : Verify H root idx (H (leafPre k a')) p') :
    a = a' := by
  by_contra hne
  obtain ⟨x, y, hxy, hH⟩ := opening_binding H hlen hv hv' hne
  exact hxy (hcr x y hH)

/-! ### Domain separation -/

/-- Lists that differ at an index both prefixes cover differ after any extension. -/
theorem append_ne_of_getElem?_ne {a b x y : List UInt8} {i : ℕ} (ha : i < a.length)
    (hb : i < b.length) (h : a[i]? ≠ b[i]?) : a ++ x ≠ b ++ y := by
  intro e
  have := congrArg (fun l ↦ l[i]?) e
  simp only [List.getElem?_append_left ha, List.getElem?_append_left hb] at this
  exact h this

/-- The byte at which each leaf tag departs from the node tag. -/
def sepIndex : LeafKind → ℕ
  | .periodic => 12
  | _ => 19

theorem sep_facts (k : LeafKind) :
    sepIndex k < (leafTag k).length ∧ sepIndex k < nodeTag.length ∧
      (leafTag k)[sepIndex k]? ≠ nodeTag[sepIndex k]? := by
  cases k <;> decide

/-- **Leaf and node preimages never coincide**, for every leaf kind, payload and pair of children. -/
theorem leaf_ne_node (k : LeafKind) (payload : List UInt8) (l r : Digest w) :
    leafPre k payload ≠ nodePre l r := by
  obtain ⟨h1, h2, h3⟩ := sep_facts k
  unfold leafPre nodePre
  rw [List.append_assoc]
  exact append_ne_of_getElem?_ne h1 h2 h3

/-- **Leaf/node confusion is a collision.** A leaf digest equal to a node digest exhibits two
distinct preimages with the same hash. -/
theorem leaf_node_confusion_is_collision {k : LeafKind} {payload : List UInt8} {l r : Digest w}
    (h : H (leafPre k payload) = H (nodePre l r)) : Collision H :=
  ⟨_, _, leaf_ne_node k payload l r, h⟩

end Shield.Merkle
