// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NoxShieldStaking} from "../../contracts/shield/NoxShieldStaking.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Direct branch coverage for NoxShieldStaking's guard paths and the
///         reward-accumulator edge branches the happy-path suite doesn't hit.
contract NoxShieldStakingGuardsTest is Test {
    NoxShieldStaking internal s;
    MockERC20 internal nox;
    address internal safe = makeAddr("safe");
    address internal notifier = makeAddr("notifier");
    address internal alice = makeAddr("alice");

    function setUp() public {
        nox = new MockERC20("NOX", "NOX");
        s = new NoxShieldStaking(safe, IERC20(address(nox)), 7 days);
        vm.prank(safe);
        s.setRewardNotifier(notifier);
        nox.mint(alice, 1e24);
        nox.mint(notifier, 1e24);
        vm.prank(alice);
        nox.approve(address(s), type(uint256).max);
        vm.prank(notifier);
        nox.approve(address(s), type(uint256).max);
    }

    // -------- constructor guards --------

    function test_Constructor_RevertsZeroToken() public {
        vm.expectRevert(NoxShieldStaking.ZeroAddress.selector);
        new NoxShieldStaking(safe, IERC20(address(0)), 7 days);
    }

    function test_Constructor_RevertsCooldownTooLong() public {
        vm.expectRevert(NoxShieldStaking.CooldownTooLong.selector);
        new NoxShieldStaking(safe, IERC20(address(nox)), 31 days);
    }

    // -------- owner-only + zero-address guards --------

    function test_SetRewardNotifier_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        s.setRewardNotifier(alice);
    }

    function test_SetRewardNotifier_RevertsZero() public {
        vm.prank(safe);
        vm.expectRevert(NoxShieldStaking.ZeroAddress.selector);
        s.setRewardNotifier(address(0));
    }

    // -------- stake / unstake guards --------

    function test_Stake_RevertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(NoxShieldStaking.ZeroAmount.selector);
        s.stake(0);
    }

    function test_InitiateUnstake_RevertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(NoxShieldStaking.ZeroAmount.selector);
        s.initiateUnstake(0);
    }

    function test_WithdrawUnstaked_RevertsNothingPending() public {
        vm.prank(alice);
        vm.expectRevert(NoxShieldStaking.NothingPending.selector);
        s.withdrawUnstaked();
    }

    function test_CancelUnstake_RevertsNothingPending() public {
        vm.prank(alice);
        vm.expectRevert(NoxShieldStaking.NothingPending.selector);
        s.cancelUnstake();
    }

    // -------- reward-notify guards + accumulator edge branches --------

    function test_Notify_RevertsNotNotifier() public {
        vm.prank(alice);
        vm.expectRevert(NoxShieldStaking.NotNotifier.selector);
        s.notifyRewardAmount(1e18);
    }

    function test_Notify_RevertsZeroAmount() public {
        vm.prank(notifier);
        vm.expectRevert(NoxShieldStaking.ZeroAmount.selector);
        s.notifyRewardAmount(0);
    }

    /// @dev Notify with no stakers carries the whole amount (totalStaked==0 branch), and a
    ///      later notify with a staker distributes carried + new.
    function test_Notify_BurnsWhenNoStakersThenDistributes() public {
        vm.prank(notifier);
        s.notifyRewardAmount(5e18);
        assertEq(s.carriedRewards(), 0, "nothing carried while empty");
        assertEq(IERC20(address(s.nox())).balanceOf(s.BURN_ADDRESS()), 5e18, "burned while empty");

        vm.prank(alice);
        s.stake(100e18);
        vm.prank(notifier);
        s.notifyRewardAmount(1e18);
        assertEq(s.earned(alice), 1e18, "only what arrived after the stake");
        assertEq(s.carriedRewards(), 0);
    }

    /// @dev claimRewards with nothing earned takes the amount==0 early-return
    ///      branch (no transfer, no revert).
    function test_Claim_NoRewardsIsNoop() public {
        vm.prank(alice);
        s.stake(1e18);
        uint256 before = nox.balanceOf(alice);
        vm.prank(alice);
        s.claimRewards(); // earned == 0 → early return
        assertEq(nox.balanceOf(alice), before, "no payout when nothing earned");
    }

    function test_CancelUnstake_RestakesAndEarnsAgain() public {
        vm.startPrank(alice);
        s.stake(100e18);
        s.initiateUnstake(100e18);
        vm.stopPrank();
        // cooling down earns nothing.
        vm.prank(notifier);
        s.notifyRewardAmount(10e18);
        assertEq(s.earned(alice), 0);

        vm.prank(alice);
        s.cancelUnstake();
        assertEq(s.stakedOf(alice), 100e18);
        vm.prank(notifier);
        s.notifyRewardAmount(1e18);
        assertEq(s.earned(alice), 1e18, "earning again after cancel, the cooldown share burned");
    }
}
