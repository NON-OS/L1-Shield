// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase, _blobsFor} from "./ShieldTestBase.sol";
import {AmountPolicy} from "../../contracts/shield/AmountPolicy.sol";

/// The containment lever on the pool's real policy: a guardian or the owner pauses every deposit and
/// settlement at once, the pause ends by itself, the owner may extend it once through a delay, and the
/// next pause waits out a cooldown.
contract PauseLeverTest is ShieldTestBase {
    AmountPolicy internal policy;
    address internal guardian = makeAddr("guardian");
    address internal stranger = makeAddr("stranger");

    event GuardianSet(address indexed previous, address indexed guardian);
    event Paused(address indexed by, uint64 until);
    event Unpaused(address indexed by);
    event ExtensionQueued(uint64 eta);
    event Extended(uint64 until);

    function _launchAmountRules() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        policy = pool.amountPolicy();
        uint64[] memory ids = new uint64[](1);
        uint8[] memory mins = new uint8[](1);
        uint8[] memory maxs = new uint8[](1);
        uint256[] memory fees = new uint256[](1);
        (ids[0], mins[0], maxs[0], fees[0]) = (0, 15, 19, 1e15);
        vm.startPrank(safe);
        policy.initRanges(ids, mins, maxs, fees);
        // the fee model refuses every settlement on an asset with no schedule
        uint64[] memory proto = new uint64[](1);
        proto[0] = 5e14;
        uint64[4][] memory ladders = new uint64[4][](1);
        ladders[0] = [uint64(1e15), 2e15, 4e15, 8e15];
        policy.initSchedules(ids, proto, ladders);
        policy.setGuardian(guardian);
        vm.stopPrank();
        depositNative(alice, 1 ether); // shielded value for the transfers' fees
    }

    /// @dev One private transfer paying the protocol part, as the fee model requires; settled by
    ///      its sender, so no gas rung.
    function paidTransfer() internal returns (uint256[] memory w) {
        TIntent[] memory intents = new TIntent[](1);
        intents[0] = newIntent(0, 5e14, address(0), 0);
        w = encodeBatch(pool.currentRoot(), assocRoot, 0, intents);
    }

    function _until() internal view returns (uint64 until) {
        (until,,,) = policy.pause();
    }

    function _pauseAs(address who) internal {
        vm.prank(who);
        policy.pausePool();
    }

    function _expectPaused() internal {
        uint64 until = _until();
        uint256[] memory w = paidTransfer();
        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.IsPaused.selector, until));
        settle(w);
        bytes32 owner_ = fresh();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.IsPaused.selector, until));
        pool.absorb{value: 1 ether}(0, 1 ether, owner_);
    }

    function _expectRunning() internal {
        settle(paidTransfer());
        depositNative(alice, 1 ether);
    }

    // -- who may pause, and what a pause stops -----------------------------------------

    function test_onlyTheOwnerNamesTheGuardian() public {
        vm.prank(stranger);
        vm.expectRevert();
        policy.setGuardian(stranger);
        vm.expectEmit(true, true, false, false, address(policy));
        emit GuardianSet(guardian, address(0));
        vm.prank(safe);
        policy.setGuardian(address(0));
        assertEq(policy.guardian(), address(0));
    }

    function test_theGuardianPausesAndEveryDepositAndSettlementStops() public {
        _expectRunning();
        vm.expectEmit(true, false, false, true, address(policy));
        emit Paused(guardian, uint64(block.timestamp + 7 days));
        _pauseAs(guardian);
        assertTrue(policy.paused());
        _expectPaused();
        // a withdrawal is refused like a transfer: a pause stops honest exits too
        uint256[] memory w = singleIntent(1 ether, 0, bob);
        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.IsPaused.selector, _until()));
        settle(w);
    }

    function test_theOwnerMayPauseToo() public {
        _pauseAs(safe);
        _expectPaused();
    }

    function test_noOneElseMayPause() public {
        vm.prank(stranger);
        vm.expectRevert(AmountPolicy.NotGuardian.selector);
        policy.pausePool();
        vm.prank(safe);
        policy.setGuardian(address(0));
        vm.prank(guardian);
        vm.expectRevert(AmountPolicy.NotGuardian.selector);
        policy.pausePool();
    }

    function test_aRunningPauseCannotBeRestarted() public {
        _pauseAs(guardian);
        uint64 until = _until();
        vm.warp(block.timestamp + 6 days);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.IsPaused.selector, until));
        policy.pausePool();
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.IsPaused.selector, until));
        policy.pausePool();
    }

    // -- a pause ends by itself, and the next one waits ----------------------------------

    function test_aPauseEndsByItself() public {
        _pauseAs(guardian);
        vm.warp(block.timestamp + 7 days - 1);
        _expectPaused();
        vm.warp(block.timestamp + 1);
        assertFalse(policy.paused());
        _expectRunning();
    }

    function test_theNextPauseWaitsOutTheCooldown() public {
        _pauseAs(guardian);
        uint64 until = _until();
        vm.warp(until);
        uint64 open = uint64(until + 7 days);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.CoolingDown.selector, open));
        policy.pausePool();
        vm.warp(open - 1);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.CoolingDown.selector, open));
        policy.pausePool();
        vm.warp(open);
        _pauseAs(guardian);
        assertTrue(policy.paused());
    }

    // -- ending a pause early ---------------------------------------------------------------

    function test_theOwnerEndsAPauseEarlyAndTheCooldownStartsThen() public {
        _pauseAs(guardian);
        vm.warp(block.timestamp + 1 days);
        vm.expectEmit(true, false, false, false, address(policy));
        emit Unpaused(safe);
        vm.prank(safe);
        policy.unpausePool();
        assertFalse(policy.paused());
        _expectRunning();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.CoolingDown.selector, uint64(block.timestamp + 7 days)));
        policy.pausePool();
    }

    function test_theGuardianEndsOnlyItsOwnUnextendedPause() public {
        _pauseAs(guardian);
        vm.prank(guardian);
        policy.unpausePool();
        assertFalse(policy.paused());

        vm.warp(block.timestamp + 7 days);
        _pauseAs(safe);
        vm.prank(guardian);
        vm.expectRevert(AmountPolicy.NotGuardian.selector);
        policy.unpausePool();
        vm.prank(stranger);
        vm.expectRevert(AmountPolicy.NotGuardian.selector);
        policy.unpausePool();
    }

    function test_nothingToEndWhenRunning() public {
        vm.prank(safe);
        vm.expectRevert(AmountPolicy.NotPaused.selector);
        policy.unpausePool();
    }

    // -- one extension, through a delay --------------------------------------------------

    function test_theOwnerExtendsOnceThroughTheDelay() public {
        _pauseAs(guardian);
        uint64 until = _until();
        uint64 eta = uint64(block.timestamp + 48 hours);

        vm.prank(guardian);
        vm.expectRevert();
        policy.queueExtension();

        vm.expectEmit(false, false, false, true, address(policy));
        emit ExtensionQueued(eta);
        vm.prank(safe);
        policy.queueExtension();

        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.TooEarly.selector, eta));
        policy.extendPause();

        vm.warp(eta);
        vm.expectEmit(false, false, false, true, address(policy));
        emit Extended(until + 7 days);
        vm.prank(stranger);
        policy.extendPause();
        assertEq(_until(), until + 7 days);

        vm.prank(safe);
        vm.expectRevert(AmountPolicy.AlreadyExtended.selector);
        policy.queueExtension();
        vm.expectRevert(AmountPolicy.NothingPending.selector);
        policy.extendPause();

        // fourteen days at most, then the pool runs again
        vm.warp(until + 7 days - 1);
        _expectPaused();
        vm.warp(until + 7 days);
        _expectRunning();
    }

    function test_theGuardianCannotEndAPauseTheOwnerExtended() public {
        _pauseAs(guardian);
        vm.prank(safe);
        policy.queueExtension();
        vm.prank(guardian);
        vm.expectRevert(AmountPolicy.NotGuardian.selector);
        policy.unpausePool();
        vm.prank(safe);
        policy.unpausePool();
        assertFalse(policy.paused());
    }

    function test_anExtensionMustLandWhileThePauseRuns() public {
        _pauseAs(guardian);
        vm.warp(block.timestamp + 5 days + 1);
        vm.prank(safe);
        vm.expectRevert(AmountPolicy.ExtensionTooLate.selector);
        policy.queueExtension();

        vm.warp(block.timestamp + 2 days);
        vm.prank(safe);
        vm.expectRevert(AmountPolicy.NotPaused.selector);
        policy.queueExtension();
    }

    function test_aLapsedPauseIsNeverRevivedByItsExtension() public {
        _pauseAs(guardian);
        uint64 until = _until();
        vm.prank(safe);
        policy.queueExtension();
        vm.warp(until);
        vm.expectRevert(AmountPolicy.NotPaused.selector);
        policy.extendPause();
        _expectRunning();
    }

    function test_aNewPauseStartsWithoutTheOldExtension() public {
        _pauseAs(guardian);
        vm.prank(safe);
        policy.queueExtension();
        vm.warp(block.timestamp + 48 hours);
        policy.extendPause();
        vm.warp(_until() + 7 days);
        _pauseAs(guardian);
        (, uint64 eta, bool extended, bool ownerHeld) = policy.pause();
        assertEq(eta, 0);
        assertFalse(extended);
        assertFalse(ownerHeld);
        vm.prank(safe);
        policy.queueExtension();
    }

    // -- what the lever costs when unused -------------------------------------------------

    function test_gas_checkWhenRunning() public {
        uint256 g = gasleft();
        policy.check(0, 1e18, 1e15);
        emit log_named_uint("policy.check, cold, running", g - gasleft());
    }

    function test_gas_settleOneTransferWhenRunning() public {
        uint256[] memory w = paidTransfer();
        bytes[] memory blobs = _blobsFor(w);
        uint256 g = gasleft();
        pool.settleBatch(hex"70726f6f66", w, noResidual(), "", blobs);
        emit log_named_uint("settleBatch, one transfer, running", g - gasleft());
    }
}
