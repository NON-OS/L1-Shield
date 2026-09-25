// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase} from "./ShieldTestBase.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";
import {IStarkVerifier} from "../../contracts/shield/interfaces/IStarkVerifier.sol";
import {IPoseidonGoldilocks} from "../../contracts/shield/interfaces/IPoseidonGoldilocks.sol";

/// Refuses every native payment, so any push to it would fail.
contract RefusingRelayer {
    receive() external payable {
        revert("no");
    }

    function claimTo(ShieldedPool pool, uint64 assetId, address to) external {
        pool.claim(assetId, to);
    }
}

/// Word 11, the fee recipient: the fee is credited to it and never pushed, and the notes pay
/// public_amount + fee, so nothing is left behind in the pool.
contract FeeRecipientTest is ShieldTestBase {
    address internal carol = makeAddr("carol");

    function _unshield(uint256 publicAmount, uint256 fee, address to, address feeTo)
        internal
        returns (uint256[] memory w)
    {
        TIntent[] memory ins = new TIntent[](1);
        ins[0] = newIntent(publicAmount, fee, to, 0);
        ins[0].feeRecipient = feeTo;
        w = encodeBatch(pool.currentRoot(), assocRoot, 0, ins);
    }

    function _owedByThePool(uint64 assetId) internal view returns (uint256) {
        return pool.totalShielded(assetId) + pool.totalClaimable(assetId) + pool.unsweptFees(assetId);
    }

    /// The recipient gets public_amount whole, the relayer is credited the fee, and the router
    /// gets nothing from this intent.
    function test_theFeeIsCreditedToTheFeeRecipientAndNeverPushed() public {
        (, uint256 value) = depositNative(alice, 10 ether);
        uint256 amount = value / 2;
        uint256 fee = (amount * 50) / 10_000;

        uint256 bobBefore = bob.balance;
        uint256 relayerBefore = relayer.balance;
        uint256 routerBefore = address(feeRouter).balance;

        vm.expectEmit(true, true, false, true, address(pool));
        emit ShieldedPool.PayoutCredited(0, relayer, fee);
        settle(_unshield(amount, fee, bob, relayer));

        assertEq(bob.balance - bobBefore, amount, "the recipient is paid public_amount in full");
        assertEq(relayer.balance, relayerBefore, "a fee recipient is never pushed to");
        assertEq(pool.claimable(0, relayer), fee, "the fee is held for the relayer");
        assertEq(address(feeRouter).balance, routerBefore, "a named relayer's fee does not reach the router");
        assertEq(value - pool.totalShielded(0), amount + fee, "the notes paid public_amount + fee");

        vm.prank(relayer);
        pool.claim(0, relayer);
        assertEq(relayer.balance - relayerBefore, fee, "the relayer claims its fee");
        assertEq(pool.totalClaimable(0), 0, "nothing left owed");
    }

    /// With no fee recipient the fee goes to the fee router, as a protocol fee.
    function test_aZeroFeeRecipientSendsTheFeeToTheRouter() public {
        (, uint256 value) = depositNative(alice, 10 ether);
        uint256 amount = value / 2;
        uint256 fee = (amount * 50) / 10_000;
        uint256 routerBefore = address(feeRouter).balance;

        settle(_unshield(amount, fee, bob, address(0)));

        assertEq(address(feeRouter).balance - routerBefore, fee, "the router took the fee");
        assertEq(pool.totalClaimable(0), 0, "nothing was credited");
    }

    /// Spending a whole note leaves no value in the pool that nobody is owed, on both fee paths.
    function test_anUnshieldWithAFeeStrandsNothing() public {
        (, uint256 v1) = depositNative(alice, 10 ether);
        uint256 fee1 = (v1 * 50) / 10_050; // largest fee with fee <= 0.5% of what remains
        settle(_unshield(v1 - fee1, fee1, bob, relayer));
        assertEq(pool.totalShielded(0), 0, "the note is fully spent");
        assertEq(address(pool).balance, _owedByThePool(0), "value stranded after a relayed unshield");
        assertEq(address(pool).balance, fee1, "only the relayer's fee remains");

        (, uint256 v2) = depositNative(alice, 4 ether);
        uint256 fee2 = (v2 * 50) / 10_050;
        settle(_unshield(v2 - fee2, fee2, bob, address(0)));
        assertEq(pool.totalShielded(0), 0, "the second note is fully spent");
        assertEq(address(pool).balance, _owedByThePool(0), "value stranded after a protocol-fee unshield");
    }

    /// A fee recipient that refuses native value cannot void the batch, because nothing is sent.
    function test_aContractFeeRecipientCannotGriefTheBatch() public {
        (, uint256 value) = depositNative(alice, 10 ether);
        RefusingRelayer bad = new RefusingRelayer();
        uint256 amount = value / 4;
        uint256 fee = (amount * 50) / 10_000;

        TIntent[] memory ins = new TIntent[](2);
        ins[0] = newIntent(amount, fee, bob, 0);
        ins[0].feeRecipient = address(bad);
        ins[1] = newIntent(amount, 0, carol, 0);
        uint256 bobBefore = bob.balance;
        settle(encodeBatch(pool.currentRoot(), assocRoot, 0, ins));

        assertEq(bob.balance - bobBefore, amount, "bob paid");
        assertEq(carol.balance, amount, "carol paid");
        assertEq(pool.claimable(0, address(bad)), fee, "the refusing relayer is owed its fee");

        bad.claimTo(pool, 0, carol);
        assertEq(carol.balance, amount + fee, "and can direct it elsewhere");
    }

    /// The prover's rule: a fee recipient only with a nonzero fee.
    function test_aFeeRecipientWithoutAFeeIsRefused() public {
        depositNative(alice, 10 ether);
        uint256[] memory w = _unshield(1 ether, 0, bob, relayer);
        vm.expectRevert(ShieldedPool.FeeRecipientWithoutFee.selector);
        settle(w);
    }

    /// A private transfer naming a fee recipient is refused under the same rule.
    function test_aTransferNamingAFeeRecipientIsRefused() public {
        depositNative(alice, 10 ether);
        uint256[] memory w = _unshield(0, 0, address(0), relayer);
        vm.expectRevert(ShieldedPool.FeeRecipientWithoutFee.selector);
        settle(w);
    }

    /// A fee recipient word wider than 160 bits is refused.
    function test_aFeeRecipientWordWiderThanAnAddressIsRefused() public {
        depositNative(alice, 10 ether);
        uint256[] memory w = _unshield(1 ether, 1e14, bob, relayer);
        w[11] = (uint256(1) << 160) | uint160(relayer);
        vm.expectRevert(ShieldedPool.NotAnAddress.selector);
        settle(w);
    }

    /// Word 11 decodes at the top of the address range.
    function test_theLargestAddressDecodesAsAFeeRecipient() public {
        (, uint256 value) = depositNative(alice, 10 ether);
        address top = address(type(uint160).max);
        uint256 fee = 1e14;
        settle(_unshield(value / 2, fee, bob, top));
        assertEq(pool.claimable(0, top), fee, "credited to the top address");
    }

    /// Each intent in a batch credits its own fee recipient, and two fees to one relayer add up.
    function test_feesInOneBatchAccumulatePerRecipient() public {
        depositNative(alice, 10 ether);
        TIntent[] memory ins = new TIntent[](3);
        ins[0] = newIntent(1 ether, 1e15, bob, 0);
        ins[0].feeRecipient = relayer;
        ins[1] = newIntent(1 ether, 2e15, bob, 0);
        ins[1].feeRecipient = relayer;
        ins[2] = newIntent(1 ether, 3e15, bob, 0);
        ins[2].feeRecipient = carol;
        settle(encodeBatch(pool.currentRoot(), assocRoot, 0, ins));
        assertEq(pool.claimable(0, relayer), 3e15, "relayer");
        assertEq(pool.claimable(0, carol), 3e15, "carol");
        assertEq(pool.totalClaimable(0), 6e15, "total");
    }

    /// Batches must be whole 12-word intents: 11 and 13 words are refused, 24 settle as two.
    function test_theBatchLayoutIsTwelveWordsPerIntent() public {
        depositNative(alice, 1 ether);
        assertEq(pool.MAX_INTENTS(), 64);
        for (uint256 len = 11; len <= 13; len += 2) {
            uint256[] memory bad = new uint256[](len);
            vm.expectRevert(ShieldedPool.BadBatchLayout.selector);
            pool.settleBatch(hex"70", bad, noResidual(), "", _blobs(2));
        }
        TIntent[] memory ins = new TIntent[](2);
        ins[0] = newIntent(0, 0, address(0), 0);
        ins[1] = newIntent(0, 0, address(0), 0);
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 0, ins);
        assertEq(w.length, 24);
        uint256 leaves = pool.nextLeafIndex();
        pool.settleBatch(hex"70", w, noResidual(), "", _blobs(4));
        assertEq(pool.nextLeafIndex(), leaves + 4, "two intents, four outputs");
    }

    // -- the 11-word pool ------------------------------------------------------

    function _poolOfWidth(uint256 width) internal returns (ShieldedPool p) {
        ShieldedPool.DeploymentSelfTest memory st = _selfTest();
        p = new ShieldedPool(
            safe,
            IStarkVerifier(address(verifier)),
            IPoseidonGoldilocks(address(hasher)),
            registry,
            address(feeRouter),
            SHIELD_FEE_BPS,
            UNSHIELD_FEE_BPS,
            0,
            width,
            st
        );
    }

    function test_onlyElevenAndTwelveWordPoolsDeploy() public {
        assertEq(pool.wordsPerIntent(), 12, "the suite's pool");
        assertEq(_poolOfWidth(11).wordsPerIntent(), 11);
        ShieldedPool.DeploymentSelfTest memory st = _selfTest();
        for (uint256 width = 10; width <= 13; width += 3) {
            vm.expectRevert(ShieldedPool.BadWordsPerIntent.selector);
            new ShieldedPool(
                safe,
                IStarkVerifier(address(verifier)),
                IPoseidonGoldilocks(address(hasher)),
                registry,
                address(feeRouter),
                SHIELD_FEE_BPS,
                UNSHIELD_FEE_BPS,
                0,
                width,
                st
            );
        }
    }

    /// An 11-word pool reads the format 5 statement: no fee recipient word, the fee goes to the
    /// router, and a 12-word batch is refused.
    function test_anElevenWordPoolSendsTheFeeToTheRouter() public {
        ShieldedPool p = _poolOfWidth(11);
        vm.prank(safe);
        p.endBetaMode();
        vm.prank(alice);
        p.absorb{value: 10 ether}(0, 10 ether, fresh());

        uint256[] memory w12 = _unshield(1 ether, 5e15, bob, address(0));
        w12[0] = uint256(p.currentRoot());
        uint256[] memory w11 = new uint256[](11);
        for (uint256 i = 0; i < 11; ++i) {
            w11[i] = w12[i];
        }

        vm.expectRevert(ShieldedPool.BadBatchLayout.selector);
        p.settleBatch(hex"70", w12, noResidual(), "", _blobs(2));

        uint256 routerBefore = address(feeRouter).balance;
        uint256 bobBefore = bob.balance;
        p.settleBatch(hex"70", w11, noResidual(), "", _blobs(2));
        assertEq(bob.balance - bobBefore, 1 ether, "recipient paid in full");
        assertEq(address(feeRouter).balance - routerBefore, 5e15, "the fee went to the router");
        assertEq(p.totalClaimable(0), 0, "nothing credited");
    }

    // -- representable addresses ------------------------------------------------

    /// A 12-word pool splits addresses into 48-bit limbs, so every address can be named in a proof,
    /// including those whose 64-bit limbs would reach p.
    function test_isRepresentableHoldsForEveryAddressAtTwelveWords() public view {
        uint256 p = 0xFFFFFFFF00000001;
        assertTrue(pool.isRepresentable(bob));
        assertTrue(pool.isRepresentable(address(uint160(p))), "a 64-bit limb at p");
        assertTrue(pool.isRepresentable(address(type(uint160).max)), "all ones");
    }

    /// The 11-word layout keeps its 64-bit limbs, so an address with a limb at p cannot be
    /// named there.
    function test_isRepresentableKeepsTheLimbRuleAtElevenWords() public {
        uint256 p = 0xFFFFFFFF00000001;
        ShieldedPool eleven = _poolOfWidth(11);
        assertTrue(eleven.isRepresentable(bob));
        assertFalse(eleven.isRepresentable(address(uint160(p))), "limb 0 at p");
        assertFalse(eleven.isRepresentable(address(type(uint160).max)), "all ones");
    }

    function testFuzz_isRepresentableAtTwelveWords(address a) public view {
        assertTrue(pool.isRepresentable(a));
    }

    // -- relay fees on private transfers ------------------------------------------

    function _relayCap(uint256 units) internal {
        vm.prank(safe);
        pool.setMaxRelayFee(0, units);
    }

    /// A private transfer pays its relayer out of the notes, up to the asset's cap.
    function test_aPrivateTransferPaysARelayerWithinTheCap() public {
        depositNative(alice, 1 ether);
        _relayCap(1e15);
        uint256 shielded = pool.totalShielded(0);
        uint256 balance = address(pool).balance;
        settle(_unshield(0, 1e15, address(0), relayer));
        assertEq(pool.claimable(0, relayer), 1e15, "relayer credited");
        assertEq(shielded - pool.totalShielded(0), 1e15, "the fee left the notes");
        assertEq(address(pool).balance, balance, "nothing was pushed");
        assertEq(address(pool).balance, _owedByThePool(0), "nothing stranded");
    }

    /// With no fee recipient a transfer's fee goes to the router.
    function test_aTransferFeeWithNoRecipientGoesToTheRouter() public {
        depositNative(alice, 1 ether);
        _relayCap(1e15);
        uint256 routerBefore = address(feeRouter).balance;
        settle(_unshield(0, 5e14, address(0), address(0)));
        assertEq(address(feeRouter).balance - routerBefore, 5e14);
    }

    function test_aTransferFeeAboveTheCapIsRefused() public {
        depositNative(alice, 1 ether);
        _relayCap(1e15);
        uint256[] memory w = _unshield(0, 1e15 + 1, address(0), relayer);
        vm.expectRevert(ShieldedPool.FeeExceedsCap.selector);
        settle(w);
    }

    function test_aTransferFeeAtTheDefaultCapOfZeroIsRefused() public {
        depositNative(alice, 1 ether);
        assertEq(pool.maxRelayFee(0), 0, "default");
        uint256[] memory w = _unshield(0, 1, address(0), relayer);
        vm.expectRevert(ShieldedPool.FeeExceedsCap.selector);
        settle(w);
    }

    /// The relay cap does not touch unshields, which keep the bps cap.
    function test_theRelayCapDoesNotLoosenTheUnshieldCap() public {
        depositNative(alice, 10 ether);
        _relayCap(1 ether);
        uint256[] memory w = _unshield(1 ether, 1 ether / 200 + 1, bob, relayer);
        vm.expectRevert(ShieldedPool.FeeExceedsCap.selector);
        settle(w);
    }

    function test_setMaxRelayFeeIsOwnerOnlyBoundedAndEmits() public {
        vm.expectRevert();
        pool.setMaxRelayFee(0, 1);
        vm.startPrank(safe);
        vm.expectEmit(true, false, false, true, address(pool));
        emit ShieldedPool.MaxRelayFeeSet(0, 7);
        pool.setMaxRelayFee(0, 7);
        vm.expectRevert(ShieldedPool.FeeOutOfRange.selector);
        pool.setMaxRelayFee(0, 0xFFFFFFFF00000001 - 1);
        vm.expectRevert(ShieldedPool.UnknownAsset.selector);
        pool.setMaxRelayFee(99, 1);
        vm.stopPrank();
    }
}

function _blobs(uint256 n) pure returns (bytes[] memory b) {
    b = new bytes[](n);
}
