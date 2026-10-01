// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NoxShieldStaking} from "../../../../contracts/shield/NoxShieldStaking.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/// Symbolic proofs for single steps of NoxShieldStaking, over every amount, caller and time.
/// Run: FOUNDRY_PROFILE=halmos halmos --match-contract NoxShieldStakingHalmos
///
/// Multi-step properties (solvency across many notifications, principal conservation over long
/// sequences) are in test/shield/invariants/periphery/NoxShieldStaking.invariant.t.sol, because a
/// symbolic run over an unbounded sequence of calls does not terminate.
contract NoxShieldStakingHalmos is SymTest, Test {
    uint256 constant COOLDOWN = 604_800;
    uint256 constant PRECISION = 1e27;
    /// Far above NOX supply, and low enough that no accumulator product overflows.
    uint256 constant MAX_AMOUNT = 2 ** 96;

    address safe = address(0x5AFE);
    address notifier = address(0xFEE);
    MockERC20 nox;
    NoxShieldStaking st;

    function setUp() public {
        nox = new MockERC20("NOX", "NOX");
        st = new NoxShieldStaking(safe, IERC20(address(nox)), COOLDOWN);
        vm.prank(safe);
        st.setRewardNotifier(notifier);
    }

    function _stake(address who, uint256 amount) internal {
        nox.mint(who, amount);
        vm.startPrank(who);
        nox.approve(address(st), amount);
        st.stake(amount);
        vm.stopPrank();
    }

    function _user(address who) internal view {
        vm.assume(who != address(0) && who != address(st) && who != notifier);
    }

    /// Staking raises the stake, totalStaked and the contract balance by the amount and credits no reward.
    function check_stakeCreditsExactlyTheAmount(address who, uint256 amount) public {
        _user(who);
        vm.assume(amount > 0 && amount <= MAX_AMOUNT);
        nox.mint(who, amount);
        vm.startPrank(who);
        nox.approve(address(st), amount);
        st.stake(amount);
        vm.stopPrank();
        assert(st.stakedOf(who) == amount);
        assert(st.totalStaked() == amount);
        assert(nox.balanceOf(address(st)) == amount);
        assert(nox.balanceOf(who) == 0);
        assert(st.earned(who) == 0);
    }

    /// Moving more than the stake into cooldown reverts and changes nothing. The 2^128 bound keeps the
    /// solver in time.
    function check_cannotUnstakeMoreThanStaked(address who, uint256 staked, uint256 amount) public {
        _user(who);
        vm.assume(staked > 0 && staked <= MAX_AMOUNT);
        vm.assume(amount > staked && amount <= 2 ** 128);
        _stake(who, staked);
        vm.prank(who);
        (bool ok,) = address(st).call(abi.encodeCall(st.initiateUnstake, (amount)));
        assert(!ok);
        assert(st.stakedOf(who) == staked && st.totalStaked() == staked);
    }

    /// Starting an unstake moves the amount from stake to pending one for one, lowers totalStaked by
    /// the same amount, and sets the release a full 604,800 seconds from now.
    function check_initiateUnstakeMovesStakeToPendingOneForOne(address who, uint256 staked, uint256 amount) public {
        _user(who);
        vm.assume(staked > 0 && staked <= MAX_AMOUNT);
        vm.assume(amount > 0 && amount <= staked);
        _stake(who, staked);
        vm.prank(who);
        st.initiateUnstake(amount);
        (uint256 pending, uint64 releaseAt) = st.unstakeOf(who);
        assert(pending == amount);
        assert(st.stakedOf(who) == staked - amount);
        assert(st.totalStaked() == staked - amount);
        assert(releaseAt == block.timestamp + COOLDOWN);
        assert(nox.balanceOf(address(st)) == staked);
    }

    /// Nothing leaves before the cooldown has run: at any time short of 604,800 seconds after the
    /// last initiateUnstake, withdrawal reverts and the pending amount stays in the contract.
    function check_noWithdrawalInsideTheCooldown(address who, uint256 staked, uint256 dt) public {
        _user(who);
        vm.assume(staked > 0 && staked <= MAX_AMOUNT);
        vm.assume(dt < COOLDOWN);
        _stake(who, staked);
        vm.prank(who);
        st.initiateUnstake(staked);
        vm.warp(block.timestamp + dt);
        vm.prank(who);
        (bool ok,) = address(st).call(abi.encodeCall(st.withdrawUnstaked, ()));
        assert(!ok);
        assert(nox.balanceOf(address(st)) == staked);
    }

    /// A second initiateUnstake restarts the clock for the whole pending amount, so the first tranche
    /// cannot be withdrawn on its original schedule either.
    function check_aSecondUnstakeRestartsTheWholeCooldown(address who, uint256 staked, uint256 gap, uint256 dt)
        public
    {
        _user(who);
        vm.assume(staked >= 2 && staked <= MAX_AMOUNT);
        vm.assume(gap < COOLDOWN && dt < COOLDOWN);
        _stake(who, staked);
        vm.prank(who);
        st.initiateUnstake(1);
        vm.warp(block.timestamp + gap);
        vm.prank(who);
        st.initiateUnstake(1);
        vm.warp(block.timestamp + dt);
        vm.prank(who);
        (bool ok,) = address(st).call(abi.encodeCall(st.withdrawUnstaked, ()));
        assert(!ok);
    }

    /// After the cooldown the withdrawal pays the pending amount to the caller and leaves the stake alone.
    function check_withdrawPaysExactlyThePending(address who, uint256 staked, uint256 amount, uint256 dt) public {
        _user(who);
        vm.assume(staked > 0 && staked <= MAX_AMOUNT);
        vm.assume(amount > 0 && amount <= staked);
        vm.assume(dt >= COOLDOWN && dt < 2 ** 40);
        _stake(who, staked);
        vm.prank(who);
        st.initiateUnstake(amount);
        vm.warp(block.timestamp + dt);
        vm.prank(who);
        st.withdrawUnstaked();
        assert(nox.balanceOf(who) == amount);
        assert(nox.balanceOf(address(st)) == staked - amount);
        assert(st.stakedOf(who) == staked - amount);
        (uint256 pending,) = st.unstakeOf(who);
        assert(pending == 0);
    }

    /// Someone who never staked and never started an unstake cannot withdraw anything.
    function check_nothingPendingNothingPaid(address who, address staker, uint256 staked) public {
        _user(who);
        _user(staker);
        vm.assume(who != staker);
        vm.assume(staked > 0 && staked <= MAX_AMOUNT);
        _stake(staker, staked);
        vm.prank(who);
        (bool ok,) = address(st).call(abi.encodeCall(st.withdrawUnstaked, ()));
        assert(!ok);
        assert(nox.balanceOf(who) == 0);
    }

    /// Only the reward notifier can add rewards, so no one can inflate the accumulator.
    function check_onlyTheNotifierNotifies(address caller, uint256 amount) public {
        vm.assume(caller != notifier);
        vm.prank(caller);
        (bool ok,) = address(st).call(abi.encodeCall(st.notifyRewardAmount, (amount)));
        assert(!ok);
        assert(st.rewardPerTokenStored() == 0);
    }

    /// No reward from nothing: without a notification, a staker's claim pays nothing, whatever they
    /// stake, unstake or cancel.
    function check_noRewardWithoutANotification(address who, uint256 staked, uint256 amount) public {
        _user(who);
        vm.assume(staked > 0 && staked <= MAX_AMOUNT);
        vm.assume(amount > 0 && amount <= staked);
        _stake(who, staked);
        vm.startPrank(who);
        st.initiateUnstake(amount);
        st.cancelUnstake();
        st.claimRewards();
        vm.stopPrank();
        assert(nox.balanceOf(who) == 0);
        assert(st.earned(who) == 0);
        assert(st.stakedOf(who) == staked);
    }

    /// One notification commits no more than it brought in. The booked share rounds up, so owed plus
    /// carried is the amount or one wei less.
    function check_aNotificationConservesItsAmount(address who, uint256 staked, uint256 amount) public {
        _user(who);
        vm.assume(staked > 0 && staked <= MAX_AMOUNT);
        vm.assume(amount > 0 && amount <= MAX_AMOUNT);
        _stake(who, staked);
        nox.mint(notifier, amount);
        vm.startPrank(notifier);
        nox.approve(address(st), amount);
        st.notifyRewardAmount(amount);
        vm.stopPrank();
        uint256 carried = st.carriedRewards();
        uint256 owed = st.earned(who);
        assert(owed + carried <= amount);
        assert(amount - (owed + carried) <= 1);
        assert(nox.balanceOf(address(st)) >= staked + owed);
    }

    /// With nothing staked the contract burns the reward and credits no one.
    function check_rewardsWithNoStakeAreBurned(address who, uint256 amount) public {
        _user(who);
        vm.assume(amount > 0 && amount <= MAX_AMOUNT);
        nox.mint(notifier, amount);
        vm.startPrank(notifier);
        nox.approve(address(st), amount);
        st.notifyRewardAmount(amount);
        vm.stopPrank();
        assert(st.carriedRewards() == 0);
        assert(nox.balanceOf(st.BURN_ADDRESS()) == amount);
        assert(st.rewardPerTokenStored() == 0);
        assert(st.earned(who) == 0);
    }
}
