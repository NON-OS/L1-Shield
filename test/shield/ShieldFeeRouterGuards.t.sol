// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase} from "./ShieldTestBase.sol";
import {ShieldFeeRouter} from "../../contracts/shield/ShieldFeeRouter.sol";

/// @notice Guard and timelock branches of ShieldFeeRouter that ShieldFeeRouter.t.sol does not reach.
contract ShieldFeeRouterGuardsTest is ShieldTestBase {
    function test_Distribute_RevertsNothingToDistribute() public {
        vm.expectRevert(ShieldFeeRouter.NothingToDistribute.selector);
        feeRouter.distribute(); // zero NOX balance
    }

    // -------- timelocked proposals: zero-address guards --------

    function test_ProposeStaking_RevertsZero() public {
        vm.prank(safe);
        vm.expectRevert(ShieldFeeRouter.ZeroAddress.selector);
        feeRouter.proposeStaking(address(0));
    }

    function test_ProposeTreasury_RevertsZero() public {
        vm.prank(safe);
        vm.expectRevert(ShieldFeeRouter.ZeroAddress.selector);
        feeRouter.proposeTreasury(address(0));
    }

    function test_ProposeRouter_RevertsZero() public {
        vm.prank(safe);
        vm.expectRevert(ShieldFeeRouter.ZeroAddress.selector);
        feeRouter.proposeRouter(address(0));
    }

    // -------- execute with no pending change --------

    function test_ExecuteStaking_RevertsNoPending() public {
        vm.expectRevert(ShieldFeeRouter.NoPendingChange.selector);
        feeRouter.executeStaking();
    }

    function test_ExecuteTreasury_RevertsNoPending() public {
        vm.expectRevert(ShieldFeeRouter.NoPendingChange.selector);
        feeRouter.executeTreasury();
    }

    function test_ExecuteRouter_RevertsNoPending() public {
        vm.expectRevert(ShieldFeeRouter.NoPendingChange.selector);
        feeRouter.executeRouterApproval(address(dex));
    }

    // -------- staking change: full timelock lifecycle (success branch) --------

    function test_StakingChange_TimelockLifecycle() public {
        address newStaking = makeAddr("newStaking");
        vm.prank(safe);
        feeRouter.proposeStaking(newStaking);

        vm.expectRevert(ShieldFeeRouter.TimelockNotReady.selector);
        feeRouter.executeStaking();

        vm.warp(block.timestamp + feeRouter.TIMELOCK_DELAY());
        feeRouter.executeStaking(); // anyone may execute after the delay
        assertEq(feeRouter.staking(), newStaking, "staking updated");
    }

    // -------- keeper vs owner branch of the swap gate --------

    function test_ConvertGate_OwnerCounts_KeeperReverts() public {
        address[] memory path = new address[](2);
        path[0] = address(usd);
        path[1] = address(nox);

        // A caller that is neither keeper nor owner is refused.
        vm.prank(alice);
        vm.expectRevert(ShieldFeeRouter.NotKeeperOrOwner.selector);
        feeRouter.convertToken(address(dex), 1e18, 1, path, block.timestamp + 1);

        // The owner passes the keeper gate and stops at RouterNotApproved.
        vm.prank(safe);
        vm.expectRevert(ShieldFeeRouter.RouterNotApproved.selector);
        feeRouter.convertToken(address(dex), 1e18, 1, path, block.timestamp + 1);
    }

    function test_SetSplits_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        feeRouter.setSplits(4000, 3000, 3000);
    }
}
