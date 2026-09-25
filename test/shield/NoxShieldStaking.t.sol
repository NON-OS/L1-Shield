// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase} from "./ShieldTestBase.sol";
import {NoxShieldStaking} from "../../contracts/shield/NoxShieldStaking.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract NoxShieldStakingTest is ShieldTestBase {
    address internal notifier;

    function setUp() public override {
        super.setUp();
        // Use a plain EOA notifier so tests can push rewards directly.
        notifier = makeAddr("notifier");
        vm.prank(safe);
        staking.setRewardNotifier(notifier);
        nox.mint(notifier, 1e27);
        vm.prank(notifier);
        nox.approve(address(staking), type(uint256).max);

        nox.mint(alice, 1e24);
        nox.mint(bob, 1e24);
        vm.prank(alice);
        nox.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        nox.approve(address(staking), type(uint256).max);
    }

    function _notify(uint256 amount) internal {
        vm.prank(notifier);
        staking.notifyRewardAmount(amount);
    }

    function test_MultiStakerMultiEpoch_ExactAccounting() public {
        // Epoch 1: Alice alone with 100, earns the whole 10.
        vm.prank(alice);
        staking.stake(100e18);
        _notify(10e18);

        // Epoch 2: Bob joins with 300, the next 10 splits 25/75.
        vm.prank(bob);
        staking.stake(300e18);
        _notify(10e18);

        assertEq(staking.earned(alice), 10e18 + 2.5e18, "alice exact");
        assertEq(staking.earned(bob), 7.5e18, "bob exact");

        // Claims pay what earned() reported.
        uint256 aliceBefore = nox.balanceOf(alice);
        vm.prank(alice);
        staking.claimRewards();
        assertEq(nox.balanceOf(alice) - aliceBefore, 12.5e18, "claim exact");
        assertEq(staking.earned(alice), 0, "zeroed after claim");

        // Epoch 3: Alice cools down half her stake, and only her remaining 50 earns.
        vm.prank(alice);
        staking.initiateUnstake(50e18);
        _notify(7e18);
        assertEq(staking.earned(alice), 1e18, "alice 50/350");
        assertEq(staking.earned(bob), 7.5e18 + 6e18, "bob 300/350");
    }

    function test_RewardsWithNoStakersAreBurned() public {
        _notify(5e18);
        assertEq(staking.carriedRewards(), 0, "nothing carried while empty");
        assertEq(nox.balanceOf(staking.BURN_ADDRESS()), 5e18, "burned while empty");

        vm.prank(alice);
        staking.stake(100e18);
        _notify(1e18);
        // Only the reward that arrives after the stake goes to the staker.
        assertEq(staking.earned(alice), 1e18, "only what arrived after the stake");
        assertEq(staking.carriedRewards(), 0);
    }

    function testFuzz_NotifyNeverStrandsValue(uint96 rawStake, uint96 rawReward) public {
        uint256 stakeAmt = bound(uint256(rawStake), 1, 1e24); // alice's funded balance
        uint256 reward = bound(uint256(rawReward), 1, 1e27); // notifier's funded balance
        vm.prank(alice);
        staking.stake(stakeAmt);
        _notify(reward);
        // The booked share rounds up, so distributed plus carried is the reward or one wei less.
        uint256 distributed = staking.earned(alice);
        assertLe(distributed + staking.carriedRewards(), reward, "reward conservation");
        assertLe(reward - (distributed + staking.carriedRewards()), 1, "at most one wei of dust");
    }

    function test_CooldownGatesWithdrawal() public {
        vm.startPrank(alice);
        staking.stake(100e18);
        staking.initiateUnstake(40e18);

        vm.expectRevert(NoxShieldStaking.CooldownNotElapsed.selector);
        staking.withdrawUnstaked();

        vm.warp(block.timestamp + COOLDOWN);
        uint256 before = nox.balanceOf(alice);
        staking.withdrawUnstaked();
        assertEq(nox.balanceOf(alice) - before, 40e18, "released after cooldown");
        assertEq(staking.stakedOf(alice), 60e18, "remaining stake");
        vm.stopPrank();
    }

    function test_ToppingUpCooldownResetsTimer() public {
        vm.startPrank(alice);
        staking.stake(100e18);
        staking.initiateUnstake(10e18);
        vm.warp(block.timestamp + COOLDOWN - 1);
        staking.initiateUnstake(10e18); // resets the clock

        vm.warp(block.timestamp + 1); // old timer would have elapsed
        vm.expectRevert(NoxShieldStaking.CooldownNotElapsed.selector);
        staking.withdrawUnstaked();

        vm.warp(block.timestamp + COOLDOWN);
        staking.withdrawUnstaked();
        assertEq(staking.stakedOf(alice), 80e18);
        vm.stopPrank();
    }

    function test_CancelUnstakeRestakesImmediately() public {
        vm.startPrank(alice);
        staking.stake(100e18);
        staking.initiateUnstake(100e18);
        vm.stopPrank();

        // While cooling down, Alice earns nothing.
        _notify(10e18);
        assertEq(staking.earned(alice), 0, "cooldown earns nothing");
        assertEq(staking.carriedRewards(), 0, "nobody staked, so it is burned");

        vm.prank(alice);
        staking.cancelUnstake();
        assertEq(staking.stakedOf(alice), 100e18);
        _notify(1e18);
        assertEq(staking.earned(alice), 1e18, "earning again after cancel");
    }

    function test_OnlyNotifierMayNotify() public {
        vm.prank(alice);
        vm.expectRevert(NoxShieldStaking.NotNotifier.selector);
        staking.notifyRewardAmount(1e18);
    }

    function test_CooldownCapEnforcedAtConstruction() public {
        vm.expectRevert(NoxShieldStaking.CooldownTooLong.selector);
        new NoxShieldStaking(safe, IERC20(address(nox)), 31 days);
    }

    function test_InsufficientStakeReverts() public {
        vm.prank(alice);
        staking.stake(10e18);
        vm.prank(alice);
        vm.expectRevert(NoxShieldStaking.InsufficientStake.selector);
        staking.initiateUnstake(11e18);
    }
}
