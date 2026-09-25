// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GoldilocksIncrementalTree} from "../../contracts/shield/GoldilocksIncrementalTree.sol";
import {IPoseidonGoldilocks} from "../../contracts/shield/interfaces/IPoseidonGoldilocks.sol";
import {MockPoseidonGoldilocks} from "./mocks/MockPoseidonGoldilocks.sol";

contract DepthProbe is GoldilocksIncrementalTree {
    constructor(IPoseidonGoldilocks h) GoldilocksIncrementalTree(h) {}
}

/// @notice Tree depth stays 32: the depth is a capacity ceiling that cannot be raised later, and
///         a full tree forces a second pool that splits the anonymity set.
contract TreeDepthDecisionTest is Test {
    /// TREE_DEPTH is 32.
    function test_theDepthIsThirtyTwoOnPurpose() public {
        DepthProbe t = new DepthProbe(IPoseidonGoldilocks(address(new MockPoseidonGoldilocks())));
        assertEq(
            t.TREE_DEPTH(),
            32,
            "TREE_DEPTH was lowered. If this was for gas, read the comment on the constant: the "
            "saving is off the payment path and the cost is a permanent cap on the anonymity set. "
            "Prover cost is flat from depth 8 to 32, so the prover gains nothing from a shallower tree."
        );
    }

    /// Depth 32 caps the tree one leaf short of 2^32, over two billion two-note payments.
    function test_theCeilingIsWhatTheDepthIsFor() public {
        DepthProbe t = new DepthProbe(IPoseidonGoldilocks(address(new MockPoseidonGoldilocks())));
        uint256 leaves = 1 << t.TREE_DEPTH();
        assertEq(leaves, 4_294_967_296, "the ceiling moved");
        // two output notes per payment is the join-split's shape
        assertGt(leaves / 2, 2_000_000_000, "fewer than two billion payments of headroom");
    }
}
