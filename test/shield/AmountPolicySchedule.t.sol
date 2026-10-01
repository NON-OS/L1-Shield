// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AmountPolicy} from "../../contracts/shield/AmountPolicy.sol";

/// @notice The fee schedule of AmountPolicy: the flat protocol fee and gas ladder per asset, the global
///         deposit and withdrawal percentages, the pool's two calls, and the 48-hour queue with grace.
/// @dev The test contract stands in for the pool, which creates the policy and answers nextAssetId.
contract AmountPolicyScheduleTest is Test {
    AmountPolicy policy;
    address safe = address(0x5AFE);
    address stranger = address(0xBAD);

    uint64 constant ETH = 0;
    uint64 constant NOX = 1;

    // ETH in wei (scale 1): 0.01 to 10 ETH
    uint64 constant ETH_PROTOCOL = 5e14;
    uint64[4] ETH_LADDER = [uint64(2.5e15), 5e15, 1e16, 2e16];
    // NOX in note units (scale 1e9): 1,000 to 5,000,000 NOX, protocol 400 NOX, ladder 2k to 16k NOX
    uint64 constant NOX_PROTOCOL = 4e11;
    uint64[4] NOX_LADDER = [uint64(2e12), 4e12, 8e12, 1.6e13];

    function nextAssetId() external pure returns (uint64) {
        return 2;
    }

    function setUp() public {
        vm.warp(1_790_812_800);
        policy = new AmountPolicy(safe, 50, 50);

        uint64[] memory ids = new uint64[](2);
        ids[0] = ETH;
        ids[1] = NOX;
        uint8[] memory minE = new uint8[](2);
        uint8[] memory maxE = new uint8[](2);
        uint256[] memory flat = new uint256[](2);
        (minE[0], maxE[0], flat[0]) = (16, 19, 5e13);
        (minE[1], maxE[1], flat[1]) = (12, 15, 5e9);
        uint64[] memory prot = new uint64[](2);
        prot[0] = ETH_PROTOCOL;
        prot[1] = NOX_PROTOCOL;
        uint64[4][] memory ladders = new uint64[4][](2);
        ladders[0] = ETH_LADDER;
        ladders[1] = NOX_LADDER;

        vm.startPrank(safe);
        policy.initRanges(ids, minE, maxE, flat);
        policy.initSchedules(ids, prot, ladders);
        vm.stopPrank();
    }

    // -- construction ------------------------------------------------------------------------------

    function test_constructorSetsGlobalBps() public view {
        (uint16 d, uint16 w) = policy.bps();
        assertEq(d, 50);
        assertEq(w, 50);
        assertEq(address(policy.pool()), address(this));
    }

    function test_constructorRefusesBpsAboveOnePercent() public {
        vm.expectRevert(AmountPolicy.BpsTooHigh.selector);
        new AmountPolicy(safe, 101, 50);
        vm.expectRevert(AmountPolicy.BpsTooHigh.selector);
        new AmountPolicy(safe, 50, 101);
        new AmountPolicy(safe, 100, 100); // the cap itself is fine
    }

    // -- private transfers -------------------------------------------------------------------------

    function test_relayedTransferPaysProtocolPlusARung() public view {
        for (uint256 i = 0; i < 4; ++i) {
            (uint256 p, uint256 g) = policy.settlementFee(ETH, 0, ETH_PROTOCOL + ETH_LADDER[i], true);
            assertEq(p, ETH_PROTOCOL);
            assertEq(g, ETH_LADDER[i]);
        }
        (uint256 pn, uint256 gn) = policy.settlementFee(NOX, 0, NOX_PROTOCOL + NOX_LADDER[3], true);
        assertEq(pn, NOX_PROTOCOL);
        assertEq(gn, NOX_LADDER[3]);
    }

    function test_selfSubmittedTransferPaysTheProtocolPartAlone() public view {
        (uint256 p, uint256 g) = policy.settlementFee(ETH, 0, ETH_PROTOCOL, false);
        assertEq(p, ETH_PROTOCOL);
        assertEq(g, 0);
    }

    function test_selfSubmittedTransferWithAGasPartRefused() public {
        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.GasPartWithoutSubmitter.selector, uint256(ETH_LADDER[0])));
        policy.settlementFee(ETH, 0, ETH_PROTOCOL + ETH_LADDER[0], false);
    }

    function test_relayedTransferWithNoGasPartRefused() public {
        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.FeeNotOnLadder.selector, uint256(0)));
        policy.settlementFee(ETH, 0, ETH_PROTOCOL, true);
    }

    function test_offLadderRefused() public {
        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.FeeNotOnLadder.selector, uint256(ETH_LADDER[1] + 1)));
        policy.settlementFee(ETH, 0, ETH_PROTOCOL + ETH_LADDER[1] + 1, true);
    }

    function test_feeBelowProtocolPartRefused() public {
        vm.expectRevert(
            abi.encodeWithSelector(AmountPolicy.FeeBelowProtocolPart.selector, uint256(ETH_PROTOCOL - 1), ETH_PROTOCOL)
        );
        policy.settlementFee(ETH, 0, ETH_PROTOCOL - 1, true);
    }

    // -- withdrawals -------------------------------------------------------------------------------

    function test_withdrawalProtocolPartIsHalfAPercent() public view {
        uint256 amount = 1e17; // 0.1 ETH
        uint256 protocolPart = amount / 200;
        (uint256 p, uint256 g) = policy.settlementFee(ETH, amount, protocolPart + ETH_LADDER[0], true);
        assertEq(p, protocolPart);
        assertEq(g, ETH_LADDER[0]);
        (p, g) = policy.settlementFee(ETH, amount, protocolPart, false);
        assertEq(p, protocolPart);
        assertEq(g, 0);
    }

    function test_smallestWithdrawalClearsWithTheTopRung() public view {
        // the pool's old cap made small relayed withdrawals fail; here the gas part is bounded by the ladder
        uint256 amount = 1e16;
        (uint256 p, uint256 g) = policy.settlementFee(ETH, amount, amount / 200 + ETH_LADDER[3], true);
        assertEq(p, 5e13);
        assertEq(g, ETH_LADDER[3]);
    }

    function test_nonStandardWithdrawalRefused() public {
        vm.expectRevert(AmountPolicy.NonStandardAmount.selector);
        policy.settlementFee(ETH, 3e16, 0, false);
        vm.expectRevert(AmountPolicy.NonStandardAmount.selector);
        policy.settlementFee(ETH, 1e15, 0, false); // below the range
    }

    // -- refusals shared by both calls --------------------------------------------------------------

    function test_unrangedAssetRefused() public {
        AmountPolicy fresh = new AmountPolicy(safe, 50, 50);
        vm.expectRevert(AmountPolicy.NotRanged.selector);
        fresh.settlementFee(ETH, 0, 0, false);
        vm.expectRevert(AmountPolicy.NotRanged.selector);
        fresh.depositFee(ETH, 1e17);
    }

    function test_rangedButUnscheduledAssetRefused() public {
        AmountPolicy fresh = new AmountPolicy(safe, 50, 50);
        uint64[] memory ids = new uint64[](1);
        uint8[] memory minE = new uint8[](1);
        uint8[] memory maxE = new uint8[](1);
        uint256[] memory flat = new uint256[](1);
        (minE[0], maxE[0], flat[0]) = (16, 19, 5e13);
        vm.prank(safe);
        fresh.initRanges(ids, minE, maxE, flat);
        vm.expectRevert(AmountPolicy.NoSchedule.selector);
        fresh.settlementFee(ETH, 0, 0, false);
        vm.expectRevert(AmountPolicy.NoSchedule.selector);
        fresh.depositFee(ETH, 1e17);
    }

    function test_pauseRefusesBothCalls() public {
        vm.prank(safe);
        policy.pausePool();
        (uint64 until,,,) = policy.pause();
        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.IsPaused.selector, until));
        policy.settlementFee(ETH, 0, ETH_PROTOCOL, false);
        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.IsPaused.selector, until));
        policy.depositFee(ETH, 1e17);
    }

    // -- deposits ----------------------------------------------------------------------------------

    function test_depositFeeIsHalfAPercentRoundedDown() public view {
        assertEq(policy.depositFee(ETH, 1e18), 5e15);
        assertEq(policy.depositFee(NOX, 1e12), 5e9);
        assertEq(policy.depositFee(ETH, 1e16), 5e13);
    }

    function test_nonStandardDepositRefused() public {
        vm.expectRevert(AmountPolicy.NonStandardAmount.selector);
        policy.depositFee(ETH, 3e17);
        vm.expectRevert(AmountPolicy.NonStandardAmount.selector);
        policy.depositFee(ETH, 0);
    }

    // -- the schedule queue ------------------------------------------------------------------------

    function _newLadder() internal pure returns (uint64[4] memory l) {
        l = [uint64(3e15), 6e15, 1.2e16, 2.4e16];
    }

    function test_pendingScheduleSettlesFromItsAnnouncement() public {
        uint64[4] memory l = _newLadder();
        vm.prank(safe);
        policy.queueSchedule(ETH, 6e14, l);
        (uint256 p, uint256 g) = policy.settlementFee(ETH, 0, 6e14 + l[2], true);
        assertEq(p, 6e14);
        assertEq(g, l[2]);
        // the schedule in force still settles too
        (p, g) = policy.settlementFee(ETH, 0, ETH_PROTOCOL + ETH_LADDER[2], true);
        assertEq(p, ETH_PROTOCOL);
    }

    function test_scheduleWaitsItsDelayThenTheOldOneHasGrace() public {
        uint64[4] memory l = _newLadder();
        vm.prank(safe);
        policy.queueSchedule(ETH, 6e14, l);
        (, uint64 eta) = policy.pendingScheduleOf(ETH);
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.TooEarly.selector, eta));
        policy.activateSchedule(ETH);

        vm.warp(eta);
        policy.activateSchedule(ETH); // anyone
        assertEq(policy.scheduleOf(ETH).protocolFee, 6e14);

        // the replaced schedule still settles for an hour
        policy.settlementFee(ETH, 0, ETH_PROTOCOL + ETH_LADDER[0], true);
        vm.warp(eta + policy.GRACE());
        vm.expectRevert();
        policy.settlementFee(ETH, 0, ETH_PROTOCOL + ETH_LADDER[0], true);
        policy.settlementFee(ETH, 0, 6e14 + l[0], true);
    }

    function test_cancelledScheduleNeverSettles() public {
        uint64[4] memory l = _newLadder();
        vm.startPrank(safe);
        policy.queueSchedule(ETH, 6e14, l);
        policy.cancelSchedule(ETH);
        vm.stopPrank();
        vm.expectRevert();
        policy.settlementFee(ETH, 0, 6e14 + l[0], true);
        vm.expectRevert(AmountPolicy.NothingPending.selector);
        policy.activateSchedule(ETH);
    }

    function test_badSchedulesRefused() public {
        vm.startPrank(safe);
        vm.expectRevert(AmountPolicy.BadSchedule.selector);
        policy.queueSchedule(ETH, 1, [uint64(0), 1, 2, 3]); // rung 0 is zero
        vm.expectRevert(AmountPolicy.BadSchedule.selector);
        policy.queueSchedule(ETH, 1, [uint64(1), 2, 2, 3]); // not strictly increasing
        vm.expectRevert(AmountPolicy.FeeOutOfRange.selector);
        policy.queueSchedule(ETH, type(uint64).max, [uint64(1), 2, 3, 4]); // over a limb
        vm.stopPrank();
    }

    function test_initSchedulesOnlyOnceAndOnlyOnARange() public {
        uint64[] memory ids = new uint64[](1);
        uint64[] memory prot = new uint64[](1);
        uint64[4][] memory ladders = new uint64[4][](1);
        ladders[0] = ETH_LADDER;
        vm.prank(safe);
        vm.expectRevert(AmountPolicy.AlreadyScheduled.selector);
        policy.initSchedules(ids, prot, ladders);

        AmountPolicy fresh = new AmountPolicy(safe, 50, 50);
        vm.prank(safe);
        vm.expectRevert(AmountPolicy.NotRanged.selector);
        fresh.initSchedules(ids, prot, ladders);

        uint64[] memory two = new uint64[](2);
        vm.prank(safe);
        vm.expectRevert(AmountPolicy.LengthMismatch.selector);
        fresh.initSchedules(two, prot, ladders);
    }

    function test_onlyTheOwnerChangesFees() public {
        uint64[4] memory l = _newLadder();
        vm.startPrank(stranger);
        vm.expectRevert();
        policy.queueSchedule(ETH, 6e14, l);
        vm.expectRevert();
        policy.queueBps(10, 10);
        vm.expectRevert();
        policy.cancelBps();
        vm.expectRevert();
        policy.cancelSchedule(ETH);
        vm.stopPrank();
    }

    // -- the percentage queue ------------------------------------------------------------------------

    function test_bpsQueueDelayAndGrace() public {
        vm.prank(safe);
        policy.queueBps(100, 100);
        uint256 amount = 1e17;
        // the announced withdrawal percentage settles at once, beside the one in force
        policy.settlementFee(ETH, amount, amount / 100 + ETH_LADDER[0], true);
        policy.settlementFee(ETH, amount, amount / 200 + ETH_LADDER[0], true);
        // deposits follow only the percentage in force
        assertEq(policy.depositFee(ETH, amount), amount / 200);

        (, uint64 eta) = policy.pendingBps();
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.TooEarly.selector, eta));
        policy.activateBps();
        vm.warp(eta);
        policy.activateBps();
        assertEq(policy.depositFee(ETH, amount), amount / 100);

        // the old withdrawal percentage keeps its grace hour, then stops
        policy.settlementFee(ETH, amount, amount / 200 + ETH_LADDER[0], true);
        vm.warp(eta + policy.GRACE());
        vm.expectRevert();
        policy.settlementFee(ETH, amount, amount / 200 + ETH_LADDER[0], true);
        policy.settlementFee(ETH, amount, amount / 100 + ETH_LADDER[0], true);
    }

    function test_queueBpsCapped() public {
        vm.prank(safe);
        vm.expectRevert(AmountPolicy.BpsTooHigh.selector);
        policy.queueBps(101, 0);
    }

    // -- the launch check is unchanged ---------------------------------------------------------------

    function test_launchCheckStillReadsTheFlatFee() public view {
        policy.check(ETH, 0, 5e13);
        policy.check(ETH, 1e17, 0);
    }

    function test_launchCheckStillRefusesOtherFees() public {
        vm.expectRevert(AmountPolicy.FeeNotFlat.selector);
        policy.check(ETH, 0, ETH_PROTOCOL + ETH_LADDER[0]);
    }

    // -- properties ----------------------------------------------------------------------------------

    /// A private transfer's fee is accepted exactly when it is the protocol fee plus one rung (relayed)
    /// or the protocol fee alone (self-submitted), and the split returned adds up to the fee.
    function testFuzz_transferAcceptedIffOnTheLadder(uint256 fee, bool relayed, uint8 pick) public view {
        if (pick % 3 == 0) fee = ETH_PROTOCOL + ETH_LADDER[pick % 4];
        else if (pick % 3 == 1) fee = ETH_PROTOCOL;
        fee = bound(fee, 0, 1e20);
        bool onLadder;
        for (uint256 i = 0; i < 4; ++i) {
            if (fee == ETH_PROTOCOL + ETH_LADDER[i]) onLadder = true;
        }
        bool expected = relayed ? onLadder : fee == ETH_PROTOCOL;
        try policy.settlementFee(ETH, 0, fee, relayed) returns (uint256 p, uint256 g) {
            assertTrue(expected, "accepted a fee off the schedule");
            assertEq(p + g, fee);
            assertEq(p, ETH_PROTOCOL);
        } catch {
            assertFalse(expected, "refused a fee on the schedule");
        }
    }

    /// The same for a withdrawal of any standard amount in the range.
    function testFuzz_withdrawalAcceptedIffOnTheLadder(uint8 k, uint8 m, uint8 rung, bool relayed, uint256 noise)
        public
        view
    {
        uint256[3] memory mant = [uint256(1), 2, 5];
        uint256 amount = mant[m % 3] * 10 ** (16 + uint256(k % 4));
        uint256 protocolPart = amount * 50 / 10_000;
        uint256 fee = relayed ? protocolPart + ETH_LADDER[rung % 4] : protocolPart;
        if (noise % 2 == 1) fee += bound(noise, 1, 1e15);
        bool onLadder;
        for (uint256 i = 0; i < 4; ++i) {
            if (fee == protocolPart + ETH_LADDER[i]) onLadder = true;
        }
        bool expected = relayed ? onLadder : fee == protocolPart;
        try policy.settlementFee(ETH, amount, fee, relayed) returns (uint256 p, uint256 g) {
            assertTrue(expected);
            assertEq(p, protocolPart);
            assertEq(p + g, fee);
        } catch {
            assertFalse(expected);
        }
    }

    /// A queued change, of the schedule or the percentages, is never in force before its 48 hours.
    function testFuzz_noQueuedChangeTakesEffectEarly(uint256 dt, address caller) public {
        dt = bound(dt, 0, 48 hours - 1);
        vm.startPrank(safe);
        policy.queueSchedule(ETH, 6e14, _newLadder());
        policy.queueBps(10, 10);
        vm.stopPrank();
        vm.warp(block.timestamp + dt);
        vm.startPrank(caller);
        vm.expectRevert();
        policy.activateSchedule(ETH);
        vm.expectRevert();
        policy.activateBps();
        vm.stopPrank();
        assertEq(policy.scheduleOf(ETH).protocolFee, ETH_PROTOCOL);
        (uint16 d, uint16 w) = policy.bps();
        assertEq(d, 50);
        assertEq(w, 50);
    }
}
