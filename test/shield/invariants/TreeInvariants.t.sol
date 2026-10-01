// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {GoldilocksIncrementalTree} from "../../../contracts/shield/GoldilocksIncrementalTree.sol";
import {Goldilocks} from "../../../contracts/shield/libraries/Goldilocks.sol";
import {IPoseidonGoldilocks} from "../../../contracts/shield/interfaces/IPoseidonGoldilocks.sol";
import {MockPoseidonGoldilocks} from "../mocks/MockPoseidonGoldilocks.sol";

/// Exposes every insert path of the tree, deferred and immediate.
contract TreeHarness is GoldilocksIncrementalTree {
    constructor(IPoseidonGoldilocks h) GoldilocksIncrementalTree(h) {}

    function insertDeferred(bytes32 leaf) external returns (uint40) {
        return _insertLeafDeferred(leaf);
    }

    function insertManyDeferred(bytes32[] memory leaves) external returns (uint40) {
        return _insertLeavesDeferred(leaves);
    }

    function insertNow(bytes32 leaf) external returns (uint40) {
        return _insertLeaf(leaf);
    }

    function insertManyNow(bytes32[] memory leaves) external returns (uint40) {
        return _insertLeaves(leaves);
    }

    function commit() external returns (bytes32) {
        return _commitRoot();
    }

    /// The root a commit would publish now, without publishing it.
    function pendingRoot() external view returns (bytes32) {
        return _foldFrontier(nextLeafIndex);
    }
}

/// Feeds the same leaves to two trees, one on the pool's deferred path (insert, then commitRoot)
/// and one on the immediate path (a root per insert), and keeps every leaf for a reference root
/// computed level by level from scratch.
contract TreeHandler is Test {
    TreeHarness public immutable deferred;
    TreeHarness public immutable immediate;
    IPoseidonGoldilocks public immutable hasher;

    bytes32[] internal leaves;
    bytes32[] public pushedRoots; // roots the deferred tree pushed into its ring, in order
    uint256 internal counter;

    uint256 public countViolations;
    uint256 public commitViolations;
    uint256 public noOpViolations;

    constructor(TreeHarness d, TreeHarness i, IPoseidonGoldilocks h) {
        deferred = d;
        immediate = i;
        hasher = h;
    }

    function insert(uint256 k) external {
        k = bound(k, 1, 5);
        bytes32[] memory batch = new bytes32[](k);
        for (uint256 j = 0; j < k; ++j) {
            batch[j] = _leaf();
            leaves.push(batch[j]);
        }
        uint40 before = deferred.nextLeafIndex();
        uint40 first;
        if (k == 1) {
            first = deferred.insertDeferred(batch[0]);
            immediate.insertNow(batch[0]);
        } else {
            first = deferred.insertManyDeferred(batch);
            immediate.insertManyNow(batch);
        }
        // leaves append: the first new index is the old count, and the count grows by k
        if (first != before || deferred.nextLeafIndex() != before + k) countViolations++;
    }

    function commit() external {
        if (deferred.nextLeafIndex() == 0) return;
        bytes32 prior = deferred.currentRoot();
        bytes32 root = deferred.commit();
        if (root != deferred.currentRoot() || !deferred.isKnownRoot(root)) commitViolations++;
        if (root != prior) pushedRoots.push(root);
        // a second commit with no new leaf is a no-op: same root, and no ring slot used, so the
        // oldest live root is not evicted by a caller who only wants to burn the window
        bytes32 oldest = _oldestLive();
        if (deferred.commit() != root) noOpViolations++;
        if (oldest != bytes32(0) && !deferred.isKnownRoot(oldest)) noOpViolations++;
    }

    function leafCount() external view returns (uint256) {
        return leaves.length;
    }

    function pushedCount() external view returns (uint256) {
        return pushedRoots.length;
    }

    /// The root of the depth-32 tree holding `leaves` then zeros, computed from scratch.
    function referenceRoot() external view returns (bytes32) {
        uint256 n = leaves.length;
        bytes32[] memory level = new bytes32[](n == 0 ? 1 : n);
        for (uint256 i = 0; i < n; ++i) {
            level[i] = leaves[i];
        }
        bytes32 z = bytes32(0);
        if (n == 0) level[0] = z;
        uint256 width = n == 0 ? 1 : n;
        for (uint256 d = 0; d < 32; ++d) {
            uint256 next = (width + 1) / 2;
            for (uint256 i = 0; i < next; ++i) {
                bytes32 l = level[2 * i];
                bytes32 r = 2 * i + 1 < width ? level[2 * i + 1] : z;
                level[i] = hasher.hash2(l, r);
            }
            width = next;
            z = hasher.hash2(z, z);
        }
        return level[0];
    }

    function _oldestLive() internal view returns (bytes32) {
        uint256 n = pushedRoots.length;
        if (n == 0) return bytes32(0);
        uint256 window = deferred.ROOT_WINDOW() - 1; // the ring also holds the empty root at first
        return n > window ? pushedRoots[n - window] : pushedRoots[0];
    }

    function _leaf() internal returns (bytes32) {
        uint256 v = uint256(keccak256(abi.encode("leaf", ++counter)));
        uint256 acc;
        for (uint256 i = 0; i < 4; ++i) {
            acc |= (((v >> (64 * i)) & 0xFFFFFFFFFFFFFFFF) % Goldilocks.P) << (64 * i);
        }
        return bytes32(acc);
    }
}

/// Invariants of the append-only note tree. Every note the pool accepts lives here, and a proof
/// opens a note against a root from the ring, so a wrong root or a lost root strands funds.
contract TreeInvariants is StdInvariant, Test {
    TreeHandler internal handler;
    TreeHarness internal deferred;
    TreeHarness internal immediate;

    function setUp() public {
        MockPoseidonGoldilocks h = new MockPoseidonGoldilocks();
        deferred = new TreeHarness(h);
        immediate = new TreeHarness(h);
        handler = new TreeHandler(deferred, immediate, h);
        targetContract(address(handler));
    }

    /// Leaves only append: each insert takes the next index and the count equals the number of
    /// leaves ever inserted, on both paths.
    function invariant_leavesOnlyAppend() public view {
        assertEq(handler.countViolations(), 0, "an insert did not append at the end");
        assertEq(uint256(deferred.nextLeafIndex()), handler.leafCount(), "deferred count");
        assertEq(uint256(immediate.nextLeafIndex()), handler.leafCount(), "immediate count");
    }

    /// The deferred tree's pending root, the immediate root and a root rebuilt from scratch over
    /// the same leaves are equal. A difference makes every new note unprovable.
    function invariant_theRootIsDeterministic() public view {
        if (deferred.nextLeafIndex() == 0) return;
        bytes32 committed = deferred.pendingRoot();
        assertEq(committed, immediate.currentRoot(), "deferred and immediate roots differ");
        assertEq(committed, handler.referenceRoot(), "root differs from the reference");
    }

    /// A known root stays known for the whole window: the last ROOT_WINDOW - 1 roots pushed by
    /// commits are all known, and a commit that does not move the root evicts nothing.
    function invariant_aKnownRootStaysKnownForTheWindow() public view {
        assertEq(handler.commitViolations(), 0, "commitRoot published a root that is not known");
        assertEq(handler.noOpViolations(), 0, "a no-op commit moved the ring");
        uint256 n = handler.pushedCount();
        uint256 window = deferred.ROOT_WINDOW() - 1;
        uint256 from = n > window ? n - window : 0;
        for (uint256 i = from; i < n; ++i) {
            assertTrue(deferred.isKnownRoot(handler.pushedRoots(i)), "a root inside the window was evicted");
        }
    }
}

/// The capacity bound, checked at its edge by writing the leaf count directly.
contract TreeCapacityEdge is Test {
    TreeHarness internal tree;
    uint256 internal constant MAX_LEAVES = (1 << 32) - 1;

    function setUp() public {
        tree = new TreeHarness(new MockPoseidonGoldilocks());
    }

    function _setCount(uint256 count) internal {
        // nextLeafIndex is the low 40 bits of its slot, and the slot holds nothing else
        bytes32 slot = bytes32(uint256(_countSlot()));
        vm.store(address(tree), slot, bytes32(count));
        assertEq(uint256(tree.nextLeafIndex()), count, "count slot");
    }

    function _countSlot() internal pure returns (uint256) {
        // after _frontier (32 slots), _zeros (32), _rootRing (128), _knownRoot and _rootRingIndex
        return 32 + 32 + 128 + 1 + 1;
    }

    /// The last index the tree accepts is 2^32 - 2, so the count stops at 2^32 - 1. One more leaf
    /// would carry past the top frontier level and corrupt the root, so it must be refused.
    function test_theTreeStopsOneShortOf2To32() public {
        _setCount(MAX_LEAVES - 1);
        tree.insertDeferred(bytes32(uint256(1)));
        assertEq(uint256(tree.nextLeafIndex()), MAX_LEAVES);
        vm.expectRevert(GoldilocksIncrementalTree.TreeIsFull.selector);
        tree.insertDeferred(bytes32(uint256(2)));
        vm.expectRevert(GoldilocksIncrementalTree.TreeIsFull.selector);
        tree.insertNow(bytes32(uint256(2)));
    }

    /// A batch that would cross the bound is refused whole, never partly inserted.
    function testFuzz_aBatchCrossingTheBoundIsRefusedWhole(uint8 room, uint8 extra) public {
        uint256 r = bound(room, 0, 8);
        uint256 k = r + bound(extra, 1, 8);
        _setCount(MAX_LEAVES - r);
        bytes32[] memory batch = new bytes32[](k);
        for (uint256 i = 0; i < k; ++i) {
            batch[i] = bytes32(i + 1);
        }
        vm.expectRevert(GoldilocksIncrementalTree.TreeIsFull.selector);
        tree.insertManyDeferred(batch);
        vm.expectRevert(GoldilocksIncrementalTree.TreeIsFull.selector);
        tree.insertManyNow(batch);
        assertEq(uint256(tree.nextLeafIndex()), MAX_LEAVES - r, "a refused batch moved the count");
    }

    /// A batch that fills the remaining room is accepted.
    function testFuzz_aBatchThatFitsExactlyIsAccepted(uint8 room) public {
        uint256 r = bound(room, 1, 8);
        _setCount(MAX_LEAVES - r);
        bytes32[] memory batch = new bytes32[](r);
        for (uint256 i = 0; i < r; ++i) {
            batch[i] = bytes32(i + 1);
        }
        tree.insertManyDeferred(batch);
        assertEq(uint256(tree.nextLeafIndex()), MAX_LEAVES);
    }

    /// An empty tree has no root to commit, and the empty root is published at construction.
    function test_anEmptyTreeRefusesACommitAndKnowsTheEmptyRoot() public {
        assertTrue(tree.isKnownRoot(tree.currentRoot()));
        vm.expectRevert(GoldilocksIncrementalTree.NoLeavesSinceLastRoot.selector);
        tree.commit();
    }

    /// Zero is never a known root, so an intent naming root zero is always refused.
    function test_zeroIsNeverAKnownRoot() public view {
        assertFalse(tree.isKnownRoot(bytes32(0)));
    }
}
