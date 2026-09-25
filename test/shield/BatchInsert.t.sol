// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {GoldilocksIncrementalTree} from "../../contracts/shield/GoldilocksIncrementalTree.sol";
import {IPoseidonGoldilocks} from "../../contracts/shield/interfaces/IPoseidonGoldilocks.sol";
import {PoseidonGoldilocks} from "../../contracts/shield/PoseidonGoldilocks.sol";

/// A tree exposing both insertion paths, so the batched one can be compared with the single-leaf one.
contract TreeHarness is GoldilocksIncrementalTree {
    constructor(IPoseidonGoldilocks h) GoldilocksIncrementalTree(h) {}

    function one(bytes32 leaf) external returns (uint40) {
        return _insertLeaf(leaf);
    }

    function many(bytes32[] memory leaves) external returns (uint40) {
        return _insertLeaves(leaves);
    }

    function frontierAt(uint256 level) external view returns (bytes32) {
        return _frontierAt(level);
    }

    function deferred(bytes32 leaf) external returns (uint40) {
        return _insertLeafDeferred(leaf);
    }

    function commit() external returns (bytes32) {
        return _commitRoot();
    }
}

/// Batched insertion matches the single-leaf loop in root, next index and frontier, at powers of
/// two, one either side of them, and odd starting offsets.
contract BatchInsertTest is Test {
    PoseidonGoldilocks hasher;

    function setUp() public {
        hasher = new PoseidonGoldilocks();
    }

    function _leaf(uint256 i) internal pure returns (bytes32) {
        // Any canonical digest will do. The tree does not interpret leaves.
        return bytes32(uint256(keccak256(abi.encode("leaf", i))) >> 8);
    }

    function _compare(uint256 preload, uint256 batch) internal {
        TreeHarness seq = new TreeHarness(IPoseidonGoldilocks(address(hasher)));
        TreeHarness bat = new TreeHarness(IPoseidonGoldilocks(address(hasher)));

        // Both trees get the same history one leaf at a time, so the batch starts from a
        // populated frontier.
        for (uint256 i = 0; i < preload; ++i) {
            seq.one(_leaf(i));
            bat.one(_leaf(i));
        }

        bytes32[] memory ls = new bytes32[](batch);
        for (uint256 i = 0; i < batch; ++i) ls[i] = _leaf(preload + i);

        for (uint256 i = 0; i < batch; ++i) seq.one(ls[i]);
        uint40 firstBat = bat.many(ls);

        assertEq(firstBat, uint40(preload), "batch must report the first new index");
        assertEq(bat.nextLeafIndex(), seq.nextLeafIndex(), "next index differs");
        assertEq(bat.currentRoot(), seq.currentRoot(), "ROOT DIFFERS: not equivalent");
        assertTrue(bat.isKnownRoot(bat.currentRoot()), "batch root must enter the window");
        for (uint256 l = 0; l < 32; ++l) {
            assertEq(bat.frontierAt(l), seq.frontierAt(l), "frontier differs at a level");
        }
    }

    function test_batchEqualsSequential_fromEmpty() public {
        _compare(0, 2);
        _compare(0, 3);
        _compare(0, 4);
        _compare(0, 5);
        _compare(0, 8);
        _compare(0, 16);
    }

    /// the alignment cases: a batch that starts mid-subtree, and one that straddles a power of two
    function test_batchEqualsSequential_fromOffsets() public {
        _compare(1, 2);
        _compare(1, 3);
        _compare(3, 5);
        _compare(5, 6);
        _compare(7, 2);
        _compare(7, 9);
        _compare(15, 2);
        _compare(9, 7);
    }

    function test_aSingletonBatchMatchesASingleInsert() public {
        _compare(0, 1);
        _compare(6, 1);
    }

    function test_anEmptyBatchIsRefused() public {
        TreeHarness t = new TreeHarness(IPoseidonGoldilocks(address(hasher)));
        bytes32[] memory none = new bytes32[](0);
        vm.expectRevert(GoldilocksIncrementalTree.NoLeaves.selector);
        t.many(none);
    }

    /// Batched insertion of a settlement's outputs costs under a quarter of the sequential gas.
    function test_theGasItSaves() public {
        uint256 k = 16; // eight intents, two outputs each
        TreeHarness seq = new TreeHarness(IPoseidonGoldilocks(address(hasher)));
        TreeHarness bat = new TreeHarness(IPoseidonGoldilocks(address(hasher)));
        bytes32[] memory ls = new bytes32[](k);
        for (uint256 i = 0; i < k; ++i) ls[i] = _leaf(i);

        uint256 g0 = gasleft();
        for (uint256 i = 0; i < k; ++i) seq.one(ls[i]);
        uint256 seqGas = g0 - gasleft();

        g0 = gasleft();
        bat.many(ls);
        uint256 batGas = g0 - gasleft();

        console2.log("16 leaves, one at a time :", seqGas);
        console2.log("16 leaves, batched       :", batGas);
        console2.log("send cap                 :", uint256(16777216));
        assertEq(bat.currentRoot(), seq.currentRoot(), "and still the same root");
        assertLt(batGas, seqGas / 4, "batching must be a large multiple cheaper, not a trim");
    }

    // Deferred insertion: updating only the frontier carry and walking to the root at commit
    // reproduces the sequential tree.

    function _compareDeferred(uint256 n) internal {
        TreeHarness seq = new TreeHarness(IPoseidonGoldilocks(address(hasher)));
        TreeHarness def = new TreeHarness(IPoseidonGoldilocks(address(hasher)));
        for (uint256 i = 0; i < n; ++i) {
            seq.one(_leaf(i));
            def.deferred(_leaf(i));
        }
        def.commit();
        assertEq(def.nextLeafIndex(), seq.nextLeafIndex(), "leaf count differs");
        assertEq(def.currentRoot(), seq.currentRoot(), "ROOT DIFFERS: deferring changed the tree");

        // Only live frontier entries are compared. Level L is live when bit L of the leaf count
        // is set, and only live levels are read. The sequential tree leaves scratch at other levels.
        for (uint256 l = 0; l < 32; ++l) {
            if ((n >> l) & 1 == 1) {
                assertEq(def.frontierAt(l), seq.frontierAt(l), "live frontier entry differs");
            }
        }
    }

    function test_deferredMatchesSequential() public {
        _compareDeferred(1);
        _compareDeferred(2);
        _compareDeferred(3);
        _compareDeferred(4);
        _compareDeferred(5);
        _compareDeferred(7);
        _compareDeferred(8);
        _compareDeferred(9);
        _compareDeferred(16);
        _compareDeferred(17);
    }

    /// Committing more than once, or part-way through, must not change where the tree ends up.
    function test_intermediateCommitsDoNotDisturbTheTree() public {
        TreeHarness seq = new TreeHarness(IPoseidonGoldilocks(address(hasher)));
        TreeHarness def = new TreeHarness(IPoseidonGoldilocks(address(hasher)));
        for (uint256 i = 0; i < 12; ++i) {
            seq.one(_leaf(i));
            def.deferred(_leaf(i));
            if (i % 3 == 0) def.commit(); // commit at arbitrary points
        }
        def.commit();
        assertEq(def.currentRoot(), seq.currentRoot(), "intermediate commits changed the root");
    }

    /// Every committed root is a root the sequential tree also held, so a note deposited before
    /// a commit can prove against it.
    function test_everyCommittedRootIsOneTheSequentialTreeHeld() public {
        TreeHarness seq = new TreeHarness(IPoseidonGoldilocks(address(hasher)));
        TreeHarness def = new TreeHarness(IPoseidonGoldilocks(address(hasher)));
        for (uint256 i = 0; i < 6; ++i) {
            seq.one(_leaf(i));
            def.deferred(_leaf(i));
            bytes32 committed = def.commit();
            assertEq(committed, seq.currentRoot(), "committed a root the sequential tree never had");
            assertTrue(def.isKnownRoot(committed), "committed root not in the window");
        }
    }

    function test_theGasDeferringSaves() public {
        TreeHarness seq = new TreeHarness(IPoseidonGoldilocks(address(hasher)));
        TreeHarness def = new TreeHarness(IPoseidonGoldilocks(address(hasher)));
        uint256 n = 16;

        uint256 g0 = gasleft();
        for (uint256 i = 0; i < n; ++i) seq.one(_leaf(i));
        uint256 seqGas = g0 - gasleft();

        g0 = gasleft();
        for (uint256 i = 0; i < n; ++i) def.deferred(_leaf(i));
        uint256 defInserts = g0 - gasleft();
        g0 = gasleft();
        def.commit();
        uint256 commitGas = g0 - gasleft();

        console2.log("16 inserts, root each time  :", seqGas);
        console2.log("16 deferred inserts         :", defInserts);
        console2.log("one root commit             :", commitGas);
        console2.log("deferred total              :", defInserts + commitGas);
        assertEq(def.currentRoot(), seq.currentRoot(), "and the same root");
        assertLt(defInserts + commitGas, seqGas / 2, "deferring must be a large multiple cheaper");
    }

}
