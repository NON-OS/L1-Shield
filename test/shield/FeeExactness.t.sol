// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase} from "./ShieldTestBase.sol";

/// Fee + value equals the deposit with rounding dust in `value`, and a refund pays under every
/// pause.
contract FeeExactnessTest is ShieldTestBase {
    uint256 constant BPS = 10_000;

    function _settleBetaPosture() internal override {
        vm.startPrank(safe);
        pool.setBetaDepositor(alice, true);
        pool.setBetaCaps(0, 100 ether, 100 ether);
        vm.stopPrank();
    }

    /// For every amount and legal bps, fee + value == amount, the fee is the floor and the dust
    /// is in `value`.
    function test_fuzz_feeAlgebraExact(uint96 amountRaw, uint16 bpsRaw) public pure {
        uint256 amount = bound(uint256(amountRaw), 1, type(uint96).max);
        uint256 bps = bound(uint256(bpsRaw), 0, 50); // MAX_FEE_BPS
        uint256 fee = (amount * bps) / BPS;
        uint256 value = amount - fee;
        assertEq(fee + value, amount, "fee + value must equal amount exactly");
        // fee is floored, so the remainder rides `value`
        assertGe(value * BPS, amount * (BPS - bps), "dust did not land in value");
        assertLe(fee * BPS, amount * bps, "fee took more than its floor share");
    }

    /// On a dust-forcing deposit, escrow and note credit equal value and the router gets the fee.
    function test_depositLedgerExactWithDust() public {
        vm.prank(safe);
        pool.setFeeBps(50, 0); // max shield fee to force nonzero fee + dust

        uint256 amount = 1 ether + 3; // not a multiple of 200, so the fee rounds down
        uint256 fee = (amount * 50) / BPS;
        uint256 value = amount - fee;
        assertTrue(fee * BPS != amount * 50, "pick an amount that actually rounds");

        address router = pool.feeRouter();
        uint256 poolBefore = address(pool).balance;
        uint256 routerBefore = router.balance;

        vm.prank(alice);
        pool.absorb{value: amount}(0, amount, fresh());

        assertEq(address(pool).balance - poolBefore, value, "escrow delta != value");
        assertEq(router.balance - routerBefore, fee, "router delta != fee");
        assertEq(pool.betaRefundable(0, alice), value, "note credit != value");
        assertEq(pool.totalShielded(0), value, "totalShielded != value");
        // every wei of `amount` is in one named place
        assertEq(value + fee, amount, "ledger does not close");
    }

    /// With deposits and beta both paused, the refund still pays.
    function test_exitAlwaysPossible_underEveryPause() public {
        vm.prank(alice);
        pool.absorb{value: 1 ether}(0, 1 ether, fresh());
        uint256 refundable = pool.betaRefundable(0, alice);
        assertGt(refundable, 0, "setup: nothing refundable");

        vm.startPrank(safe);
        pool.setDepositsPaused(true);
        pool.setBetaPaused(true);
        vm.stopPrank();

        uint256 before = alice.balance;
        vm.prank(alice);
        uint256 paid = pool.betaRefund(0, alice);
        assertEq(paid, refundable, "refund short-paid");
        assertEq(alice.balance - before, refundable, "refund did not reach the depositor");
    }
}
