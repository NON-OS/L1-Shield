// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GoldilocksIncrementalTree} from "../../contracts/shield/GoldilocksIncrementalTree.sol";
import {IPoseidonGoldilocks} from "../../contracts/shield/interfaces/IPoseidonGoldilocks.sol";
import {MockPoseidonGoldilocks} from "./mocks/MockPoseidonGoldilocks.sol";

contract CapacityHarness is GoldilocksIncrementalTree {
    constructor(IPoseidonGoldilocks h) GoldilocksIncrementalTree(h) {}

    /// Places the leaf count at the boundary directly. The frontier stays empty, since only the
    /// index arithmetic is under test.
    function seek(uint40 n) external {
        nextLeafIndex = n;
    }

    function deferred(bytes32 l) external returns (uint40) {
        return _insertLeafDeferred(l);
    }

    function walk(bytes32 l) external returns (uint40) {
        return _insertLeaf(l);
    }

    function batch(bytes32[] memory ls) external returns (uint40) {
        return _insertLeavesDeferred(ls);
    }
}

/// @notice The top of the tree, where the frontier runs out of levels. Both insert paths agree
/// on where the tree ends.
contract TreeCapacityTest is Test {
    CapacityHarness t;
    uint40 constant LAST = uint40((uint256(1) << 32) - 2); // index of the final admissible leaf
    uint40 constant FULL = uint40((uint256(1) << 32) - 1); // the count at which the tree is full

    function setUp() public {
        t = new CapacityHarness(IPoseidonGoldilocks(address(new MockPoseidonGoldilocks())));
    }

    function test_theFinalLeafIsAcceptedByBothPaths() public {
        t.seek(LAST);
        assertEq(t.deferred(bytes32(uint256(1))), LAST, "deferred refused the final leaf");
        t.seek(LAST);
        assertEq(t.walk(bytes32(uint256(1))), LAST, "walk refused the final leaf");
    }

    function test_oneLeafPastTheEndIsTheWrittenErrorAndNotAPanic() public {
        t.seek(FULL);
        vm.expectRevert(GoldilocksIncrementalTree.TreeIsFull.selector);
        t.deferred(bytes32(uint256(1)));

        t.seek(FULL);
        vm.expectRevert(GoldilocksIncrementalTree.TreeIsFull.selector);
        t.walk(bytes32(uint256(1)));
    }

    function test_aBatchStraddlingTheEndIsRefusedWhole() public {
        bytes32[] memory two = new bytes32[](2);
        two[0] = bytes32(uint256(1));
        two[1] = bytes32(uint256(2));

        // At LAST the second leaf would pass the end, so the whole batch is refused.
        t.seek(LAST);
        vm.expectRevert(GoldilocksIncrementalTree.TreeIsFull.selector);
        t.batch(two);

        // two short: both fit
        t.seek(LAST - 1);
        assertEq(t.batch(two), LAST - 1, "a batch that fits was refused");
        assertEq(t.nextLeafIndex(), FULL, "the tree did not end where the constant says");
    }

    function test_bothPathsEndAtTheSameLeaf() public {
        t.seek(FULL);
        bytes memory deferredErr;
        try t.deferred(bytes32(uint256(1))) {
            fail();
        } catch (bytes memory e) {
            deferredErr = e;
        }
        t.seek(FULL);
        bytes memory walkErr;
        try t.walk(bytes32(uint256(1))) {
            fail();
        } catch (bytes memory e) {
            walkErr = e;
        }
        assertEq(deferredErr, walkErr, "the two insert paths disagree about where the tree ends");
    }
}
