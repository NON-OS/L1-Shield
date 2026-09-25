// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase} from "./ShieldTestBase.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";

/// Settlement is gated by the proof: the settler has priority for one window after the last
/// settlement, then anyone with a valid proof settles. A settler change outlasts the window.
contract SettlerWindowTest is ShieldTestBase {
    function _installSettler(address who) internal {
        vm.prank(safe);
        pool.proposeSettler(who);
        vm.warp(block.timestamp + pool.SETTLER_DELAY());
        pool.executeSettlerChange();
    }

    function test_insideTheWindowOnlyTheSettlerSettles() public {
        depositNative(alice, 1 ether);
        _installSettler(keeper);
        uint256[] memory w = singleIntent(0, 0, address(0));
        vm.prank(alice);
        vm.expectRevert(ShieldedPool.NotSettler.selector);
        settle(w);
        vm.prank(keeper);
        settle(w);
    }

    function test_pastTheWindowAnyoneWithAProofSettles() public {
        depositNative(alice, 1 ether);
        _installSettler(keeper);
        vm.warp(block.timestamp + pool.SETTLER_WINDOW());
        uint256[] memory w = singleIntent(0, 0, address(0));
        vm.prank(alice);
        settle(w);
    }

    function test_aSettlementRestartsTheWindow() public {
        depositNative(alice, 2 ether);
        _installSettler(keeper);
        vm.warp(block.timestamp + pool.SETTLER_WINDOW());
        vm.prank(keeper);
        settle(singleIntent(0, 0, address(0)));
        // the settler just acted, so the window is fresh and an outsider waits again
        uint256[] memory w = singleIntent(0, 0, address(0));
        vm.prank(alice);
        vm.expectRevert(ShieldedPool.NotSettler.selector);
        settle(w);
    }

    function test_aSettlerChangeWaitsLongerThanTheWindow() public {
        assertGt(pool.SETTLER_DELAY(), pool.SETTLER_WINDOW(), "the delay must outlast the window");
        vm.prank(safe);
        pool.proposeSettler(keeper);
        vm.expectRevert(ShieldedPool.TimelockNotReady.selector);
        pool.executeSettlerChange();
        vm.warp(block.timestamp + pool.SETTLER_DELAY());
        pool.executeSettlerChange();
        assertEq(pool.settler(), keeper);
    }

    function test_aProposalCanBeCancelledAndNothingElseInstallsASettler() public {
        vm.prank(safe);
        pool.proposeSettler(keeper);
        vm.prank(safe);
        pool.cancelSettlerChange();
        vm.expectRevert(ShieldedPool.NoPendingChange.selector);
        pool.executeSettlerChange();
        assertEq(pool.settler(), address(0));
    }

    /// With deposits paused and a dead settler installed, a valid proof from any caller moves
    /// funds out one window later.
    function test_noStateInWhichFundsCannotLeaveWithoutAProof() public {
        (, uint256 value) = depositNative(alice, 4 ether);
        vm.startPrank(safe);
        pool.setDepositsPaused(true);
        pool.proposeSettler(address(0xDEAD));
        vm.stopPrank();
        vm.warp(block.timestamp + pool.SETTLER_DELAY());
        pool.executeSettlerChange();
        assertEq(pool.settler(), address(0xDEAD), "the dead settler is installed");

        // inside its fresh window the dead settler blocks outsiders, as designed
        uint256 outAmt = value / 4;
        uint256[] memory w = singleIntent(outAmt, 0, bob);
        vm.prank(relayer);
        vm.expectRevert(ShieldedPool.NotSettler.selector);
        settle(w);

        // and one window later the proof alone is enough
        vm.warp(block.timestamp + pool.SETTLER_WINDOW());
        uint256 before = bob.balance;
        vm.prank(relayer);
        settle(w);
        assertEq(bob.balance - before, outAmt, "funds left on a proof, from an arbitrary caller, under a dead settler");
    }

    /// A settler that settles as often as it likes still cannot keep an outsider out past the next
    /// open slot, so no intent waits longer than one epoch.
    function test_anActiveSettlerCannotExcludeAnyoneBeyondOneEpoch() public {
        depositNative(alice, 2 ether);
        _installSettler(keeper);
        uint256[] memory w1 = singleIntent(0, 0, address(0));
        vm.prank(keeper);
        settle(w1);
        uint256 epoch = pool.SETTLEMENT_EPOCH();
        uint256 t = block.timestamp;
        uint256 slotStart = t - (t % epoch) + epoch - pool.OPEN_SLOT();
        if (slotStart <= t) slotStart += epoch;
        assertLt(slotStart - t, epoch + 1, "the next open slot is within one epoch");
        vm.warp(slotStart);
        assertLt(block.timestamp, uint256(pool.lastSettlement()) + pool.SETTLER_WINDOW(), "still inside the settler's window");
        uint256[] memory w2 = singleIntent(0, 0, address(0));
        vm.prank(alice);
        settle(w2);
    }

    /// Outside the open slot and inside the window, an outsider is still refused.
    function test_outsideTheOpenSlotTheSettlerKeepsPriority() public {
        depositNative(alice, 1 ether);
        _installSettler(keeper);
        uint256 epoch = pool.SETTLEMENT_EPOCH();
        assertLt(block.timestamp % epoch, epoch - pool.OPEN_SLOT(), "this test runs outside the slot");
        uint256[] memory w = singleIntent(0, 0, address(0));
        vm.prank(alice);
        vm.expectRevert(ShieldedPool.NotSettler.selector);
        settle(w);
    }
}
