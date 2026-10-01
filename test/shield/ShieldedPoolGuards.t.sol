// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase} from "./ShieldTestBase.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";

/// One empty client-data blob per settlement output. Empty is legal: the opening travels out of band.
function _blobs(uint256 n) pure returns (bytes[] memory b) {
    b = new bytes[](n);
}

/// One blob per output, derived from the public words: twelve words and two outputs per intent.
function _blobsFor(uint256[] memory publicWords) pure returns (bytes[] memory) {
    return _blobs(2 * (publicWords.length / 12));
}


/// @notice Governance and guard branches of ShieldedPool that ShieldedPool.t.sol does not reach.
contract ShieldedPoolGuardsTest is ShieldTestBase {
    // -------- residual band --------

    function test_SetResidualBand_SuccessAndCap() public {
        vm.prank(safe);
        pool.setResidualBand(1000); // at MAX_BAND_BPS
        assertEq(pool.residualBandBps(), 1000);

        vm.prank(safe);
        vm.expectRevert(ShieldedPool.BandTooHigh.selector);
        pool.setResidualBand(1001);
    }

    function test_SetResidualBand_OnlyOwner() public {
        vm.expectRevert();
        pool.setResidualBand(100);
    }

    // -------- fee-router timelock: cancel and no-pending branches --------

    function test_CancelFeeRouterChange_SuccessAndNoPending() public {
        vm.prank(safe);
        vm.expectRevert(ShieldedPool.NoPendingChange.selector);
        pool.cancelFeeRouterChange();

        address newRouter = makeAddr("newRouter");
        vm.prank(safe);
        pool.proposeFeeRouter(newRouter);
        vm.prank(safe);
        pool.cancelFeeRouterChange();

        // After a cancel nothing is pending, so execute reverts.
        vm.expectRevert(ShieldedPool.NoPendingChange.selector);
        pool.executeFeeRouterChange();
    }

    // -------- settler and attestation verifier setters --------

    function test_SetSettlerAndAttestationVerifier() public {
        vm.prank(safe);
        pool.proposeSettler(keeper);
        vm.warp(block.timestamp + pool.SETTLER_DELAY());
        pool.executeSettlerChange();
        assertEq(pool.settler(), keeper);

        address av = makeAddr("attestationVerifier");
        vm.prank(safe);
        pool.setAttestationVerifier(av);
        assertEq(address(pool.attestationVerifier()), av);
    }

    function test_SetAttestationVerifier_OnlyOwner() public {
        vm.expectRevert();
        pool.setAttestationVerifier(makeAddr("x"));
    }

    // -------- asset registration guards --------

    function test_RegisterAsset_ZeroAndEOA() public {
        vm.startPrank(safe);
        vm.expectRevert(ShieldedPool.ZeroAddress.selector);
        pool.registerAsset(address(0), 1);

        vm.expectRevert(ShieldedPool.NotAContract.selector);
        pool.registerAsset(makeAddr("eoa"), 1);
        vm.stopPrank();
    }

    function test_Deposit_UnknownAssetReverts() public {
        uint64 unknownId = 999;
        vm.prank(alice);
        vm.expectRevert(ShieldedPool.UnknownAsset.selector);
        pool.absorb(unknownId, 1e18, fresh());
    }

    // -------- empty residual --------

    function test_Settle_ZeroResidualIsNoop() public {
        depositNative(alice, 5 ether);
        TIntent[] memory intents = new TIntent[](1);
        intents[0] = newIntent(0, 0, address(0), 0);
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 1e18, intents);

        ShieldedPool.ResidualExec memory r; // amountIn == 0, so the residual is skipped
        r.path = new address[](0);
        uint256 nativeBefore = pool.totalShielded(0);
        pool.settleBatch(hex"70", w, r, "", _blobsFor(w));
        assertEq(pool.totalShielded(0), nativeBefore, "no residual movement");
    }

    // -------- a plain native deposit returns a commitment at leaf 0 --------

    function test_DepositWithNoteAndViewTag() public {
        vm.prank(alice);
        (bytes32 cm, uint40 idx) = pool.absorb{value: 1 ether}(0, 1 ether, fresh());
        assertTrue(cm != bytes32(0));
        assertEq(idx, 0);
    }

    // Adversarial absorb. The pool takes an owner digest it cannot open and derives the
    // commitment itself.

    /// Two identical absorbs land as the same commitment at two leaves, both accepted. The
    /// nullifier covers the leaf index, so the notes retire separately.
    function test_absorb_identicalInputsGiveTwoSpendableLeaves() public {
        bytes32 owner = dig("same-owner");
        vm.prank(alice);
        (bytes32 cm1, uint40 i1) = pool.absorb{value: 1 ether}(0, 1 ether, owner);
        vm.prank(alice);
        (bytes32 cm2, uint40 i2) = pool.absorb{value: 1 ether}(0, 1 ether, owner);

        assertEq(cm1, cm2, "identical inputs must give an identical commitment");
        assertTrue(i1 != i2, "and two distinct leaves");
        assertEq(pool.nextLeafIndex(), i2 + 1, "both were inserted");
    }

    /// A copied owner digest buys nothing. An attacker who watches a deposit and absorbs with
    /// the same digest funds a note whose spend key they do not have.
    function test_absorb_copyingAnOwnerDigestFundsTheOriginalOwner() public {
        bytes32 owner = dig("victim-owner");
        vm.prank(alice);
        (bytes32 victimCm,) = pool.absorb{value: 1 ether}(0, 1 ether, owner);
        vm.prank(bob);
        (bytes32 copyCm,) = pool.absorb{value: 1 ether}(0, 1 ether, owner);
        assertEq(copyCm, victimCm, "the copy commits to the same note");
        // Bob paid for a leaf only alice can open.
    }

    function test_absorb_refusesANonCanonicalOwnerDigest() public {
        bytes32 bad = bytes32(type(uint256).max); // every limb above p
        vm.prank(alice);
        vm.expectRevert(ShieldedPool.NonCanonicalFieldElement.selector);
        pool.absorb{value: 1 ether}(0, 1 ether, bad);
    }

    /// At the largest accepted amount both value limbs stay canonical, so the commitment hashes.
    function test_absorb_atTheLargestAcceptedValueTheLimbsStayCanonical() public {
        uint256 max = 0xFFFFFFFF00000001 - 2; // Goldilocks.MAX_VALUE = p - 2, about 18.44 ETH in wei
        vm.deal(alice, max + 1 ether);
        vm.prank(alice);
        (bytes32 cm,) = pool.absorb{value: max}(0, max, dig("big"));
        assertTrue(cm != bytes32(0), "the largest accepted value still commits");
    }

    function test_absorb_refusesAValueAboveTheField() public {
        uint256 tooBig = 0xFFFFFFFF00000001 - 1; // p - 1, one above MAX_VALUE
        vm.deal(alice, tooBig + 1 ether);
        vm.prank(alice);
        vm.expectRevert(ShieldedPool.InvalidAmount.selector);
        pool.absorb{value: tooBig}(0, tooBig, dig("too-big"));
    }


}
