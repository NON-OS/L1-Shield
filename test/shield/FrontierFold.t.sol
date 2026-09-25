// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GoldilocksIncrementalTree} from "../../contracts/shield/GoldilocksIncrementalTree.sol";
import {IPoseidonGoldilocks} from "../../contracts/shield/interfaces/IPoseidonGoldilocks.sol";
import {MockPoseidonGoldilocks} from "./mocks/MockPoseidonGoldilocks.sol";

contract FoldHarness is GoldilocksIncrementalTree {
    constructor(IPoseidonGoldilocks h) GoldilocksIncrementalTree(h) {}

    function one(bytes32 leaf) external returns (uint40) {
        return _insertLeaf(leaf);
    }

    function deferred(bytes32 leaf) external returns (uint40) {
        return _insertLeafDeferred(leaf);
    }

    function commit() external returns (bytes32) {
        return _commitRoot();
    }

    function frontierAt(uint256 l) external view returns (bytes32) {
        return _frontierAt(l);
    }
}

/// @notice `_foldFrontier`, which produces every published root, fuzzed against the sequential
///         insert walk at leaf counts 1 to 64.
contract FrontierFoldTest is Test {
    MockPoseidonGoldilocks hasher;

    function setUp() public {
        hasher = new MockPoseidonGoldilocks();
    }

    function _leaf(uint256 i) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode("fold", i))) >> 8);
    }

    /// For any leaf count, the fold and the walk give the same root.
    function testFuzz_foldMatchesTheWalkAtEveryCount(uint8 rawN) public {
        uint256 n = bound(uint256(rawN), 1, 64);
        FoldHarness seq = new FoldHarness(IPoseidonGoldilocks(address(hasher)));
        FoldHarness def = new FoldHarness(IPoseidonGoldilocks(address(hasher)));
        for (uint256 i = 0; i < n; ++i) {
            seq.one(_leaf(i));
            def.deferred(_leaf(i));
        }
        assertEq(def.commit(), seq.currentRoot(), "fold disagreed with the walk");
        assertEq(def.nextLeafIndex(), seq.nextLeafIndex(), "leaf count diverged");
    }

    /// Commits at arbitrary points do not change the final tree.
    function testFuzz_commitsAtArbitraryPointsDoNotDisturbTheTree(uint64 schedule) public {
        FoldHarness seq = new FoldHarness(IPoseidonGoldilocks(address(hasher)));
        FoldHarness def = new FoldHarness(IPoseidonGoldilocks(address(hasher)));
        for (uint256 i = 0; i < 40; ++i) {
            seq.one(_leaf(i));
            def.deferred(_leaf(i));
            if ((schedule >> (i % 64)) & 1 == 1) def.commit();
        }
        assertEq(def.commit(), seq.currentRoot(), "a commit schedule changed the root");
    }

    /// Every published root is one the sequential tree held at that leaf count.
    function testFuzz_everyPublishedRootIsOneTheWalkWouldHaveProduced(uint8 rawN) public {
        uint256 n = bound(uint256(rawN), 1, 40);
        FoldHarness seq = new FoldHarness(IPoseidonGoldilocks(address(hasher)));
        FoldHarness def = new FoldHarness(IPoseidonGoldilocks(address(hasher)));
        for (uint256 i = 0; i < n; ++i) {
            seq.one(_leaf(i));
            def.deferred(_leaf(i));
            assertEq(def.commit(), seq.currentRoot(), "published a root the walk never produced");
        }
    }

    /// zeros[0] is the empty leaf and each level hashes two copies of the level below.
    function test_theZerosChainIsWhatTheFoldAssumes() public {
        FoldHarness t = new FoldHarness(IPoseidonGoldilocks(address(hasher)));
        assertEq(t.zeros(0), bytes32(0), "zeros[0] must be the empty leaf");
        for (uint256 l = 0; l + 1 < 32; ++l) {
            assertEq(t.zeros(l + 1), hasher.hash2(t.zeros(l), t.zeros(l)), "zeros chain broken");
        }
    }
}
