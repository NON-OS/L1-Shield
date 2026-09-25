// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase} from "./ShieldTestBase.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";

/// @notice Beta deposit gate kept armed: allowlist, caps, pause, depositor-only refund, and the
///         one-way exit that removes the refund path once the pool opens.
contract BetaGateTest is ShieldTestBase {
    uint256 internal constant ADDR_CAP = 5 ether;
    uint256 internal constant TOTAL_CAP = 8 ether;

    /// @dev Keep the beta armed for this suite.
    function _settleBetaPosture() internal override {
        vm.startPrank(safe);
        pool.setBetaDepositor(alice, true);
        pool.setBetaCaps(0, ADDR_CAP, TOTAL_CAP);
        vm.stopPrank();
    }

    function _deposit(address from, uint256 amount) internal {
        vm.prank(from);
        pool.absorb{value: amount}(0, amount, fresh());
    }

    // -- the gate is on by default ---------------------------------------

    function test_betaModeOnByDefault() public view {
        assertTrue(pool.betaMode(), "a fresh pool must ship gated");
        assertFalse(pool.betaPaused());
    }

    function test_allowlistedUnderCapSucceeds() public {
        _deposit(alice, 1 ether);
        assertEq(pool.betaDeposited(0, alice), 1 ether);
        assertEq(pool.betaTotalDeposited(0), 1 ether);
    }

    function test_nonAllowlistedDepositReverts() public {
        vm.expectRevert(ShieldedPool.NotBetaDepositor.selector);
        _deposit(bob, 1 ether);
    }

    // -- caps -------------------------------------------------------------

    function test_overAddrCapReverts() public {
        _deposit(alice, ADDR_CAP);
        vm.expectRevert(ShieldedPool.BetaAddrCapExceeded.selector);
        _deposit(alice, 1);
    }

    function test_capIsCumulativeNotPerTx() public {
        _deposit(alice, 3 ether);
        _deposit(alice, 2 ether);
        vm.expectRevert(ShieldedPool.BetaAddrCapExceeded.selector);
        _deposit(alice, 1);
    }

    function test_overTotalCapReverts() public {
        vm.startPrank(safe);
        pool.setBetaDepositor(bob, true);
        vm.stopPrank();

        _deposit(alice, ADDR_CAP); // 5
        _deposit(bob, 3 ether); // 8 == TOTAL_CAP
        vm.expectRevert(ShieldedPool.BetaTotalCapExceeded.selector);
        _deposit(bob, 1);
    }

    function test_unsetCapsAreFailClosed() public {
        // usd was registered but never given caps.
        vm.prank(alice);
        vm.expectRevert(ShieldedPool.BetaAddrCapExceeded.selector);
        pool.absorb(usdAssetId, 1, fresh());
    }

    // -- pause ------------------------------------------------------------

    function test_pauseBlocksDeposit() public {
        vm.prank(safe);
        pool.setBetaPaused(true);
        vm.expectRevert(ShieldedPool.BetaIsPaused.selector);
        _deposit(alice, 1 ether);
    }

    function test_unpauseRestoresDeposit() public {
        vm.startPrank(safe);
        pool.setBetaPaused(true);
        pool.setBetaPaused(false);
        vm.stopPrank();
        _deposit(alice, 1 ether);
    }

    // -- refund -------------------------------------------------------------

    function _netOf(uint256 gross) internal view returns (uint256) {
        uint256 bps = pool.shieldFeeBps();
        return gross - (gross * bps) / 10_000;
    }

    /// @notice A depositor refunds without a pause, proof, settler, or governance.
    function test_refundNeedsNoPauseAndNoGovernance() public {
        _deposit(alice, 2 ether);
        uint256 net = _netOf(2 ether);
        uint256 before = alice.balance;

        assertFalse(pool.betaPaused(), "no pause required");
        vm.prank(alice);
        uint256 got = pool.betaRefund(0, alice);

        assertEq(got, net);
        assertEq(alice.balance - before, net);
    }

    function test_depositorRefundsThemselves() public {
        _deposit(alice, 2 ether);
        uint256 net = _netOf(2 ether);
        assertEq(pool.betaRefundable(0, alice), net);

        uint256 before = alice.balance;
        vm.prank(safe);
        pool.setBetaPaused(true);

        vm.prank(alice);
        uint256 got = pool.betaRefund(0, alice);

        assertEq(got, net);
        assertEq(alice.balance - before, net);
        assertEq(pool.betaRefundable(0, alice), 0);
        assertEq(address(pool).balance, 0);
    }

    function test_governanceRefundsOnBehalfButOnlyToTheDepositor() public {
        _deposit(alice, 2 ether);
        uint256 net = _netOf(2 ether);
        uint256 aliceBefore = alice.balance;
        uint256 safeBefore = safe.balance;

        vm.startPrank(safe);
        pool.setBetaPaused(true);
        pool.betaRefund(0, alice);
        vm.stopPrank();

        // The money went to the depositor, not to governance.
        assertEq(alice.balance - aliceBefore, net);
        assertEq(safe.balance, safeBefore);
    }

    /// @notice Governance can return a beta depositor's funds and cannot redirect them.
    function test_governanceCannotSeizeBetaFunds() public {
        _deposit(alice, 2 ether);
        vm.prank(safe);
        pool.setBetaPaused(true);

        // Governance cannot name itself, or anyone else, as the recipient.
        vm.prank(safe);
        vm.expectRevert(ShieldedPool.NothingToRefund.selector);
        pool.betaRefund(0, safe);

        vm.prank(safe);
        vm.expectRevert(ShieldedPool.NothingToRefund.selector);
        pool.betaRefund(0, bob);

        // A stranger cannot pull someone else's refund either.
        vm.prank(bob);
        vm.expectRevert(ShieldedPool.NotRefundCaller.selector);
        pool.betaRefund(0, alice);

        assertEq(address(pool).balance, _netOf(2 ether), "funds stayed put");
    }

    function test_refundCannotBeTakenTwice() public {
        _deposit(alice, 2 ether);
        vm.prank(safe);
        pool.setBetaPaused(true);

        vm.startPrank(alice);
        pool.betaRefund(0, alice);
        vm.expectRevert(ShieldedPool.NothingToRefund.selector);
        pool.betaRefund(0, alice);
        vm.stopPrank();
    }

    // -- the wind-down is one-way ----------------------------------------

    /// @dev A refunded note stays in the tree, so settlement must never restart.
    function test_refundWindsThePoolDownForGood() public {
        _deposit(alice, 2 ether);
        vm.prank(safe);
        pool.setBetaPaused(true);
        vm.prank(alice);
        pool.betaRefund(0, alice);

        assertTrue(pool.betaWoundDown());

        vm.startPrank(safe);
        vm.expectRevert(ShieldedPool.BetaIsWoundDown.selector);
        pool.setBetaPaused(false);
        vm.expectRevert(ShieldedPool.BetaIsWoundDown.selector);
        pool.endBetaMode();
        vm.stopPrank();
    }

    /// A wound-down pool refuses new deposits, even from an allowlisted depositor while unpaused.
    function test_aWoundDownPoolTakesNoDeposits() public {
        _deposit(alice, 2 ether);
        vm.prank(alice);
        pool.betaRefund(0, alice);
        assertTrue(pool.betaWoundDown());
        assertFalse(pool.betaPaused());
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(ShieldedPool.BetaIsWoundDown.selector);
        pool.absorb{value: 1 ether}(0, 1 ether, fresh());
    }

    function test_onlyOwnerControlsTheGate() public {
        vm.startPrank(bob);
        vm.expectRevert();
        pool.setBetaDepositor(bob, true);
        vm.expectRevert();
        pool.setBetaCaps(0, 1, 1);
        vm.expectRevert();
        pool.setBetaPaused(true);
        vm.expectRevert();
        pool.endBetaMode();
        vm.stopPrank();
    }

    // -- one-way exit -----------------------------------------------------

    function test_endBetaOpensDepositsAndKillsTheDrain() public {
        vm.prank(safe);
        pool.endBetaMode();

        assertFalse(pool.betaMode());
        // Anyone may deposit over the beta caps. A single deposit still has to fit the
        // Goldilocks value bound.
        _deposit(bob, 10 ether);

        // And the beta escape hatch is gone for good.
        vm.startPrank(safe);
        vm.expectRevert(ShieldedPool.BetaModeAlreadyEnded.selector);
        pool.betaRefund(0, bob);
        vm.expectRevert(ShieldedPool.BetaModeAlreadyEnded.selector);
        pool.endBetaMode();
        vm.stopPrank();
    }

    /// @notice Once deposits open, no beta path can move public funds.
    function test_publicDepositsAreNeverTouchableByBetaPaths() public {
        assertTrue(pool.betaMode(), "gated: public locked out");
        vm.expectRevert(ShieldedPool.NotBetaDepositor.selector);
        _deposit(bob, 1 ether);

        vm.prank(safe);
        pool.endBetaMode();

        _deposit(bob, 1 ether); // public in
        assertEq(pool.betaRefundable(0, bob), 0, "public deposits record no beta claim");

        vm.prank(safe);
        vm.expectRevert(ShieldedPool.BetaModeAlreadyEnded.selector);
        pool.betaRefund(0, bob);
    }

    // -- open deposits ------------------------------------------------------

    function _open(bool on) internal {
        vm.prank(safe);
        pool.setOpenDeposits(on);
    }

    function test_openDepositsIsOffByDefaultAndOwnerOnly() public {
        assertFalse(pool.openDeposits(), "a fresh pool must ship with the allowlist on");
        vm.prank(alice);
        vm.expectRevert();
        pool.setOpenDeposits(true);
        address registrar = makeAddr("registrar");
        vm.prank(safe);
        pool.setDepositorRegistrar(registrar);
        vm.prank(registrar);
        vm.expectRevert();
        pool.setOpenDeposits(true);
    }

    function test_settingOpenDepositsEmits() public {
        vm.expectEmit(false, false, false, true, address(pool));
        emit ShieldedPool.OpenDepositsSet(true);
        _open(true);
        assertTrue(pool.openDeposits());
        vm.expectEmit(false, false, false, true, address(pool));
        emit ShieldedPool.OpenDepositsSet(false);
        _open(false);
    }

    /// Open deposits skip the allowlist and nothing else: the caps still bind.
    function test_openDepositsLetAnyoneInUnderTheCaps() public {
        _open(true);
        _deposit(bob, 2 ether);
        assertEq(pool.betaDeposited(0, bob), 2 ether, "an unlisted depositor is counted");
        vm.expectRevert(ShieldedPool.BetaAddrCapExceeded.selector);
        _deposit(bob, ADDR_CAP - 2 ether + 1);
        _deposit(alice, ADDR_CAP);
        vm.expectRevert(ShieldedPool.BetaTotalCapExceeded.selector);
        _deposit(bob, TOTAL_CAP - ADDR_CAP - 2 ether + 1);
    }

    /// The beta pause still freezes an open pool.
    function test_openDepositsStillObeyTheBetaPause() public {
        _open(true);
        vm.prank(safe);
        pool.setBetaPaused(true);
        vm.expectRevert(ShieldedPool.BetaIsPaused.selector);
        _deposit(bob, 1 ether);
    }

    /// An unlisted depositor let in by open deposits can still take the beta refund, and that
    /// refund winds the pool down as any other does.
    function test_anOpenDepositorIsRefundableAndWindsDown() public {
        _open(true);
        _deposit(bob, 1 ether);
        uint256 owed = pool.betaRefundable(0, bob);
        assertGt(owed, 0);
        uint256 before = bob.balance;
        vm.prank(bob);
        pool.betaRefund(0, bob);
        assertEq(bob.balance - before, owed, "refund paid");
        assertTrue(pool.betaWoundDown(), "the refund wound the pool down");
        vm.expectRevert(ShieldedPool.BetaIsWoundDown.selector);
        _deposit(bob, 1 ether);
    }

    /// Turning the switch off restores the allowlist.
    function test_closingOpenDepositsRestoresTheAllowlist() public {
        _open(true);
        _deposit(bob, 1 ether);
        _open(false);
        vm.expectRevert(ShieldedPool.NotBetaDepositor.selector);
        _deposit(bob, 1 ether);
        _deposit(alice, 1 ether);
    }

    // -- refunds after a spend ------------------------------------------------

    function _allow(address a) internal {
        vm.prank(safe);
        pool.setBetaDepositor(a, true);
    }

    function _refund(address a) internal returns (uint256 paid) {
        uint256 before = a.balance;
        vm.prank(a);
        pool.betaRefund(0, a);
        paid = a.balance - before;
    }

    /// A depositor who unshields their own note and then asks for the refund is paid from the
    /// others' deposits, but only pro rata: the refunds together never exceed what the notes still
    /// held, and the last depositor to ask is still paid.
    function test_aDoubleDipIsDilutedAndNeverOverdrawsThePool() public {
        _allow(bob);
        _deposit(alice, 4 ether);
        _deposit(bob, 4 ether);
        uint256 v = pool.betaRefundable(0, alice);

        // alice spends her whole note back to herself
        settle(singleIntent(v, 0, alice));
        uint256 held = pool.totalShielded(0);
        assertEq(held, v, "only bob's value is left in notes");

        uint256 a = _refund(alice);
        uint256 b = _refund(bob);

        assertEq(pool.refundAssets(0), held, "snapshot of what the notes held");
        assertEq(pool.refundBase(0), 2 * v, "snapshot of what was deposited");
        assertEq(a, v / 2, "alice gets her share of what is left, not her deposit");
        assertEq(b, v / 2, "bob is diluted by alice's double dip, and still paid");
        assertLe(a + b, held, "refunds exceeded what the pool held for notes");
        assertEq(pool.totalShielded(0), held - a - b, "the ledger fell by what was paid");
        assertGe(address(pool).balance, pool.totalShielded(0) + pool.totalClaimable(0) + pool.unsweptFees(0));
    }

    /// With no spend, the pro-rata share is the whole deposit.
    function test_withoutASpendEveryRefundIsWhole() public {
        _allow(bob);
        _deposit(alice, 3 ether);
        _deposit(bob, 2 ether);
        uint256 va = pool.betaRefundable(0, alice);
        uint256 vb = pool.betaRefundable(0, bob);
        assertEq(_refund(bob), vb, "bob whole");
        assertEq(_refund(alice), va, "alice whole");
        assertEq(pool.totalShielded(0), 0, "nothing left");
    }

    /// The snapshot is taken once, by the first refund in the asset, and later refunds read it.
    function test_theRefundSnapshotIsTakenOnce() public {
        _allow(bob);
        _deposit(alice, 3 ether);
        _deposit(bob, 2 ether);
        assertEq(pool.refundBase(0), 0, "no snapshot before the first refund");
        _refund(alice);
        uint256 assets = pool.refundAssets(0);
        uint256 base = pool.refundBase(0);
        _refund(bob);
        assertEq(pool.refundAssets(0), assets, "assets snapshot moved");
        assertEq(pool.refundBase(0), base, "base snapshot moved");
    }

    /// For any deposits and any unshield, the refunds sum to at most what the notes held, every
    /// refund succeeds, and the pool stays solvent.
    function testFuzz_refundsNeverExceedWhatTheNotesHeld(uint64 ra, uint64 rb, uint64 rc, uint64 rs) public {
        address carol = makeAddr("carol");
        vm.deal(carol, 10 ether);
        _allow(bob);
        _allow(carol);
        vm.prank(safe);
        pool.setBetaCaps(0, 5 ether, 15 ether);
        _deposit(alice, bound(ra, 1e6, 5 ether));
        _deposit(bob, bound(rb, 1e6, 5 ether));
        _deposit(carol, bound(rc, 1e6, 5 ether));
        uint256 spend = bound(rs, 0, pool.betaRefundable(0, alice));
        if (spend != 0) settle(singleIntent(spend, 0, alice));

        uint256 held = pool.totalShielded(0);
        uint256 paid = _refund(alice) + _refund(bob) + _refund(carol);
        assertLe(paid, held, "refunds exceeded what the notes held");
        assertLe(held - paid, 3, "more than rounding dust was left behind");
        assertGe(address(pool).balance, pool.totalShielded(0) + pool.totalClaimable(0) + pool.unsweptFees(0));
    }
}
