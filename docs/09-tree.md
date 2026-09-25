# The tree

`contracts/shield/GoldilocksIncrementalTree.sol` is the append-only Merkle tree of note commitments
that `ShieldedPool` inherits, hashed with Poseidon over Goldilocks.

This document covers capacity, deferred insertion, root publication and the window of known roots.
It is for wallet and prover builders who need to know which root a spend may use, and for auditors.

- [Parameters](#parameters)
- [The tree as a function](#the-tree-as-a-function)
- [Capacity](#capacity)
- [Depth 32](#depth-32)
- [Deferred insertion](#deferred-insertion)
- [`commitRoot`](#commitroot)
- [The known-root window](#the-known-root-window)
- [The hasher](#the-hasher)

Line references are to `GoldilocksIncrementalTree.sol` and tests are in `test/shield/`. Receipts are
from the launch pool `0x8e377752C8890E23A1E9F40eBbD41183Fc6949e2` on Sepolia.

## Parameters

```solidity
uint256 public constant TREE_DEPTH  = 32;
uint256 public constant ROOT_WINDOW = 128;
uint256 private constant MAX_LEAVES = (1 << 32) - 1;
IPoseidonGoldilocks public immutable treeHasher;
bytes32[TREE_DEPTH]  private _frontier; // one slot per level
bytes32[TREE_DEPTH]  private _zeros;    // empty-subtree digests Z_0 .. Z_31
bytes32[ROOT_WINDOW] private _rootRing; // the window
mapping(bytes32 root => bool known) private _knownRoot;
```

| state | meaning |
|---|---|
| `nextLeafIndex()` | the index the next leaf receives, equal to the leaf count |
| `currentRoot()` | the most recently published root |
| `isKnownRoot(root)` | true for any root still in the window, false for `bytes32(0)` |
| `zeros(level)` | $Z_{\mathrm{level}}$ |

On the launch pool `treeHasher()` is `0x0096416e4385BBd459141140A542f30E05b1A4d7`,
`TREE_DEPTH() = 32` and `ROOT_WINDOW() = 128`.

## The tree as a function

Write $H(\ell, r)$ for `treeHasher.hash2(left, right)`. The empty-subtree digests are

$$Z_0 = 0, \qquad Z_{t+1} = H(Z_t, Z_t),$$

computed in the constructor (lines 33 to 44). $Z_0$ to $Z_{31}$ are stored, and $Z_{32}$ is the root
of the empty tree.

A tree state is a vector $V$ of $2^{32}$ leaf words, where $V_j$ is the commitment inserted at index
$j$ and every position at or after `nextLeafIndex` holds 0. Its root is the binary Merkle root of $V$
under $H$, with leaf $j$ at depth 32 and the bits of $j$, least significant first, choosing left (0)
or right (1) at each level. `BatchInsert.t.sol` and `FrontierFold.t.sol` hold the deferred paths
below to a full walk over the same leaves.

## Capacity

The frontier holds 32 slots, one per level. Inserting leaf $2^{32} - 1$ would set every index bit,
so the carry would run through all 32 levels and write one slot past the array. The capacity is
$2^{32} - 1$ leaves.

Every insert path checks the count against `MAX_LEAVES` and reverts `TreeIsFull` before any array
bound is reached. A batch that would cross the end is refused whole (lines 79, 104, 146, 169).

| property | test (`TreeCapacity.t.sol`) |
|---|---|
| the last leaf, index $2^{32} - 2$, is accepted by the single and batch paths | `test_theFinalLeafIsAcceptedByBothPaths` |
| a leaf past the end reverts `TreeIsFull`, with no panic | `test_oneLeafPastTheEndIsTheWrittenErrorAndNotAPanic` |
| a batch straddling the end is refused whole | `test_aBatchStraddlingTheEndIsRefusedWhole` |
| the single and batch paths end at the same leaf | `test_bothPathsEndAtTheSameLeaf` |

## Depth 32

The depth is fixed at deployment and every leaf is bound to it. A full pool can only be followed by
a second pool, and two pools split the anonymity set for good. Depth 32 gives 4,294,967,295 leaves.

Each deposit is one leaf, a settlement adds two, and a large deposit takes several notes ([the value
ceiling](08-pool.md#the-value-ceiling)). `TreeDepthDecision.t.sol` fails if `TREE_DEPTH` changes.

A shallower tree would make `commitRoot` cheaper, since it makes one `hash2` call per level. The
launch `commitRoot` receipt below averages $4{,}424{,}015 / 32 \approx 138{,}250$ gas per level.

Depth 24 would save 8 calls, near 1.1M gas per `commitRoot`. That saving is an estimate with no
receipt. The cost falls on root publication and not on the payment path.

## Deferred insertion

Inserting a leaf and publishing a root are separate steps.

| function | used by | work | publishes a root |
|---|---|---|---|
| `_insertLeafDeferred(leaf)` (line 102) | `absorb` | one `hash2` per trailing one bit of the leaf index, then one frontier write | no |
| `_insertLeavesDeferred(leaves)` (line 142) | `settleBatch` | the same, per leaf | no |
| `_commitRoot()` (line 120) | `commitRoot` | 32 `hash2` calls folding the frontier | yes |

To insert leaf $\lambda$ at index $j$, let $\tau$ be the number of trailing one bits of $j$. The insert
computes

$$n_0 = \lambda, \qquad n_{t+1} = H(F_t, n_t) \quad (0 \le t < \tau),$$

and stores $F_\tau \leftarrow n_\tau$, where $F_t$ is `_frontier[t]`. Nothing above level $\tau$
changes and no root is computed.

**Invariant.** Let $c$ be the leaf count and $c_t$ its bit $t$. Whenever $c_t = 1$, $F_t$ is the root
of the complete subtree of height $t$ that holds leaves $2^{t+1}\lfloor c / 2^{t+1} \rfloor$ to
$2^{t+1}\lfloor c / 2^{t+1} \rfloor + 2^t - 1$.

*Sketch.* Inserting at index $j$ with $\tau$ trailing ones makes $c = j + 1$, whose bit $\tau$ is
set, whose bits below $\tau$ are clear, and whose bits above $\tau$ equal those of $j$.

The values $n_t$ climb the right edge of the height-$\tau$ subtree that ends at leaf $j$. They hash
with the complete left siblings $F_0, \dots, F_{\tau-1}$ that the invariant supplies for $j$, so
$n_\tau$ is the root of that subtree.

Slots above $\tau$ keep their meaning because the bits above $\tau$ do not change. Slots below $\tau$
now have clear bits. No path reads a slot whose bit is clear, and the insert that sets such a bit
again writes the slot in the same step.

The cost of an insert grows with $\tau$. Native deposits of 2 ETH:

| leaf | $\tau$ | `absorb` gas | tx |
|---:|---:|---:|---|
| 4 | 0 | 263,690 | `0x0cf5c334d215a3c1e8aae97203c5d1d197e1dd8c598f9a96582fe623d6b6e636` |
| 5 | 1 | 364,554 | `0x89dc693d6b2a96c6a03c5f0bd1be2087a678768cf0d017918ecad61c9650086e` |
| 11 | 2 | 499,618 | `0xf0ad89004997b7aab8d0b4b2dc601e1c2186fbacbfb247bca908db81c3fe47a0` |
| 7 | 3 | 634,682 | `0x9a8b5441cf706db2534e1b46cc5e923387a2f2a73a856833ca12005c4fba5f1e` |
| 15 | 4 | 769,746 | `0xddd64bbb862c6eb4ccbfd82ee6f6d91949ea7c792dff6e45a4f3026ea951522f` |

From $\tau = 1$ on, each further trailing one adds 135,064 gas: one `hash2` call and the frontier read
it needs. Half of all leaves have $\tau = 0$ and pay no hash at insertion.

The deferred paths produce the same frontier, and after `commitRoot` the same root, as inserting the
same leaves one at a time with a full walk. `BatchInsert.t.sol` holds this in
`test_deferredMatchesSequential`, `test_intermediateCommitsDoNotDisturbTheTree` and
`test_everyCommittedRootIsOneTheSequentialTreeHeld`, and `FrontierFold.t.sol` fuzzes it.

The contract also carries `_insertLeaf` and `_insertLeaves` (lines 77 and 165), which walk to the root
on every call and publish it. The pool never calls them.

## `commitRoot`

```solidity
function commitRoot() external returns (bytes32 root)   // ShieldedPool
```

`_foldFrontier(c)` (line 133) computes the root for leaf count $c$:

$$m_0 = Z_0, \qquad m_{t+1} = \begin{cases} H(F_t, m_t) & c_t = 1 \\ H(m_t, Z_t) & c_t = 0 \end{cases}, \qquad \mathrm{root} = m_{32}.$$

$m_t$ is the root of the height-$t$ subtree that contains position $c$, the first empty leaf. When
$c_t = 1$ that subtree is a right child whose left sibling is complete and equals $F_t$ by the
invariant. When $c_t = 0$ it is a left child whose right sibling is empty and equals $Z_t$. By
induction $m_{32}$ is the root of $V$, the root a full walk produces for the same leaves.

| property | behaviour |
|---|---|
| caller | anyone |
| empty tree | reverts `NoLeavesSinceLastRoot` |
| root unchanged since the last publication | returns it, uses no window slot and emits no event |
| root changed | pushed into the window, `RootUpdated` and `RootCommitted` emitted |
| gas | 4,424,015 at leaf count 2, tx `0x1788bdff125f9bf8d0e4df5b2a9453187d7593f10aff5e68dc8811dff5b63fd9`, block 11,772,298 |

The cost is 32 `hash2` calls whatever the leaf count. A root is published only when someone calls
`commitRoot`, so every note inserted between two publications becomes provable under the same root.
One call serves every deposit before it.

A spend is proven against a published root. A note inserted by `absorb`, or an output inserted by
`settleBatch`, cannot be spent until a later `commitRoot` publishes a root that contains it. Wallets
and relayers call it when they need a root, and nothing calls it automatically.

Since anyone may call `commitRoot`, a call that does not move the root must not take a window slot.
If it did, 128 such calls would evict every root a pending proof could be using
(`NullifierAndRoot.t.sol`: `test_noOpCommitsCannotEvictTheWindow`).

## The known-root window

The last `ROOT_WINDOW = 128` published roots stay valid for `settleBatch`. The window is a ring of
128 slots with a mapping for constant-time lookup.

`_pushRoot` (line 63) advances the cursor modulo 128, deletes the mapping entry of the root it
overwrites, and records the new root. The constructor publishes the empty root $Z_{32}$ through the
same `_pushRoot` path as every later root.

Proving takes time. Without a window, any publication during proving would invalidate the root the
prover used, and anyone could stall spenders by depositing and committing repeatedly. With 128 slots
a root survives 127 later publications and is evicted by the 128th.

**Published roots never repeat.** Eviction deletes a root from the mapping outright, which is correct
only if the same root cannot sit in two slots. Let $V_i$ be the leaf vector at publication $i$. A
publication happens only when the root differs from `currentRoot`, so $V_{i+1} \ne V_i$.

Leaves are only ever written from 0 to a value and never cleared, so the set of nonzero positions of
$V$ only grows, and $V_j \ne V_i$ for every $j > i$. Two distinct vectors with the same root give a
collision in $H$. Published roots are pairwise distinct unless Poseidon-Goldilocks collides.

`isKnownRoot(bytes32(0))` is always false. Settlement refuses a root that was never published or has
been evicted (`UnknownOrStaleRoot`):

| property | test (`NullifierAndRoot.t.sol`) |
|---|---|
| a well-formed root that was never published is refused | `test_anInventedRootIsRefused` |
| the zero root is never accepted | `test_theZeroRootIsNeverAccepted` |
| a root evicted from the window is refused | `test_aRootEvictedFromTheWindowIsRefused` |
| `absorb` and `settleBatch` leave the published root alone, and each moving `commitRoot` publishes a known root | `test_onlyCommittedRootsAndSettledOutputsAreKnown` |
| listing an asset cannot inject a root | `test_assetListingCannotInjectARoot` |
| no-op commits cannot evict the window | `test_noOpCommitsCannotEvictTheWindow` |

## The hasher

`treeHasher` is an immutable `IPoseidonGoldilocks`, fixed in the constructor, which also computes the
empty-subtree digests with it. A tree with two hash functions would hold leaves that no proof could
open.

`PoseidonGoldilocks.hash2(left, right)` loads the four limbs of each digest into a width-8 state,
refuses any limb at or above $p$ (`NonCanonicalInput`), applies the permutation with 32 full rounds
and S-box $x^7$, and packs limbs 0 to 3 of the result, limb 0 lowest.

Its constructor checks known-answer vectors for the permutation, the single-block hash and the note
commitment (`KatFailed`).

The `ShieldedPool` constructor checks the hasher against known `hash2` and `hashFields` vectors, and
its own commitment derivation against the prover vector. It reverts the deployment on any mismatch
([the pool](08-pool.md#custody)).
