// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase} from "./ShieldTestBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoseidonGoldilocks} from "../../contracts/shield/PoseidonGoldilocks.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";
import {Goldilocks} from "../../contracts/shield/libraries/Goldilocks.sol";
import {IStarkVerifier} from "../../contracts/shield/interfaces/IStarkVerifier.sol";
import {IPoseidonGoldilocks} from "../../contracts/shield/interfaces/IPoseidonGoldilocks.sol";
import {MockFeeOnTransferERC20} from "./mocks/MockERC20.sol";

/// One empty client-data blob per settlement output. Empty is legal: the opening travels out of band.
function _blobs(uint256 n) pure returns (bytes[] memory b) {
    b = new bytes[](n);
}

/// One blob per output, derived from the public words: twelve words and two outputs per intent.
function _blobsFor(uint256[] memory publicWords) pure returns (bytes[] memory) {
    return _blobs(2 * (publicWords.length / 12));
}


contract ShieldedPoolTest is ShieldTestBase {
    // Intent-tuple word offsets (frozen AIR).
    uint256 constant NF0 = 2;
    uint256 constant NF1 = 3;
    uint256 constant PUBLIC_AMOUNT = 6;

    function test_DepositNative_CreditsNetValueAndRoutesFee() public {
        uint256 amount = 1 ether;
        uint256 expectedFee = (amount * SHIELD_FEE_BPS) / 10_000;
        uint256 routerBefore = address(feeRouter).balance;
        (, uint256 value) = depositNative(alice, amount);

        assertEq(value, amount - expectedFee, "net value");
        assertEq(pool.totalShielded(0), value);
        assertEq(address(pool).balance, value);
        assertEq(address(feeRouter).balance - routerBefore, expectedFee, "fee routed");
        assertEq(pool.nextLeafIndex(), 1);
    }

    /// Absorb derives the note commitment on chain from `ownerCommit` and the value it took custody of.
    function test_AbsorbComputesTheNestedCommitmentOnChain() public {
        uint256 amount = 2 ether;
        bytes32 ownerCommit = hasher.hash2(dig("pk"), dig("blind"));
        uint256 value = amount - (amount * SHIELD_FEE_BPS) / 10_000;

        vm.prank(alice);
        (bytes32 commitment,) = pool.absorb{value: amount}(0, amount, ownerCommit);

        bytes32 pub = bytes32(
            (value & 0xFFFFFFFF) | ((value >> 32) << 64) | (uint256(0) << 128)
                | (uint256(pool.NOTE_DOMAIN()) << 192)
        );
        assertEq(commitment, hasher.hash2(pub, ownerCommit), "nested commitment layout");
    }

    /// The case-1 commitment vector reproduces byte for byte.
    function test_TheCase1VectorReproduces() public {
        // Uses the real hasher in place of the suite's mock.
        PoseidonGoldilocks real = new PoseidonGoldilocks();
        bytes32 spendPk = bytes32(uint256(0x1aa7e2234dc226325077c305b959aab0b5ea865198956bec4125af9c305c6855));
        bytes32 blinding = bytes32(uint256(0x0000000000000009000000000000000800000000000000070000000000000006));
        bytes32 owner = real.hash2(spendPk, blinding);
        assertEq(
            owner,
            bytes32(uint256(0x94d55b34707f286d34d832be375e1d8974afcf049f038ca56258b69a86dd903e)),
            "owner digest"
        );
        bytes32 pub = bytes32(uint256(1000) | (uint256(0x4E4F5445) << 192));
        assertEq(
            real.hash2(pub, owner),
            bytes32(uint256(0x281060b5f54dddb77a934b725461e6d6c5eebaf304b0014fc63a34e7ab498196)),
            "note commitment"
        );
    }

    function test_DepositFeeOnTransferTokenReverts() public {
        MockFeeOnTransferERC20 fot = new MockFeeOnTransferERC20(100);
        fot.mint(alice, 10e18);
        uint64 id = registerToken(address(fot));
        vm.startPrank(alice);
        fot.approve(address(pool), 1e18);
        vm.expectRevert(ShieldedPool.NonStandardTokenTransfer.selector);
        pool.absorb(id, 1e18, fresh());
        vm.stopPrank();
    }

    function test_PauseBlocksDepositsNeverWithdrawals() public {
        (, uint256 value) = depositNative(alice, 1 ether);
        vm.prank(safe);
        pool.setDepositsPaused(true);

        vm.prank(alice);
        vm.expectRevert(ShieldedPool.DepositsArePaused.selector);
        pool.absorb{value: 1 ether}(0, 1 ether, fresh());

        // Pausing deposits does not block an unshield.
        uint256 outAmt = value / 2;
        uint256[] memory w = singleIntent(outAmt, 0, bob);
        uint256 bobBefore = bob.balance;
        settle(w);
        assertEq(bob.balance - bobBefore, outAmt, "unshield paid while paused (fee 0)");
    }

    function test_PrivateTransferBatch_RoundTrip() public {
        depositNative(alice, 5 ether);
        uint256[] memory w = singleIntent(0, 0, address(0));
        verifier.setExpectedInputs(w); // proves the pool forwards inputs verbatim

        uint256 leavesBefore = pool.nextLeafIndex();
        uint256 balBefore = address(pool).balance;
        settle(w);
        verifier.clearExpectedInputs();

        assertTrue(pool.nullifierSpent(bytes32(w[NF0])) && pool.nullifierSpent(bytes32(w[NF1])), "nullifiers spent");
        assertEq(pool.nextLeafIndex(), leavesBefore + 2, "two outputs inserted");
        assertEq(address(pool).balance, balBefore, "no value moved");
    }

    function test_UnshieldBatch_PaysRecipientAndFeeRouter() public {
        (, uint256 value) = depositNative(alice, 10 ether);
        uint256 outAmt = value / 3;
        uint256 fee = (outAmt * MAX_FEE_BPS_LOCAL()) / 10_000; // at the cap
        uint256[] memory w = singleIntent(outAmt, fee, bob);

        uint256 bobBefore = bob.balance;
        uint256 routerBefore = address(feeRouter).balance;
        uint256 shieldedBefore = pool.totalShielded(0);

        settle(w);

        // the notes pay public_amount + fee, the recipient gets public_amount whole
        assertEq(bob.balance - bobBefore, outAmt, "recipient exact");
        assertEq(address(feeRouter).balance - routerBefore, fee, "protocol fee exact");
        assertEq(shieldedBefore - pool.totalShielded(0), outAmt + fee, "shielded accounting");
    }

    function test_FeeAboveCapReverts() public {
        depositNative(alice, 10 ether);
        uint256 outAmt = 1 ether;
        uint256 tooMuch = (outAmt * (MAX_FEE_BPS_LOCAL() + 1)) / 10_000;
        uint256[] memory w = singleIntent(outAmt, tooMuch, bob);
        vm.expectRevert(ShieldedPool.FeeExceedsCap.selector);
        settle(w);
    }

    function test_FeeOnPrivateTransferReverts() public {
        depositNative(alice, 1 ether);
        uint256[] memory w = singleIntent(0, 1, bob); // no public amount, so the recipient is refused
        vm.expectRevert(ShieldedPool.NoPublicLegFieldsSet.selector);
        settle(w);
    }

    function test_MultiIntentBatch_AllApplied() public {
        depositNative(alice, 10 ether);
        TIntent[] memory intents = new TIntent[](3);
        intents[0] = newIntent(0, 0, address(0), 0); // transfer
        intents[1] = newIntent(1 ether, 0, bob, 0); // unshield
        intents[2] = newIntent(0.5 ether, 1e14, bob, 0); // unshield + fee
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 0, intents);

        uint256 bobBefore = bob.balance;
        uint256 leaves = pool.nextLeafIndex();
        settle(w);

        assertEq(pool.nextLeafIndex(), leaves + 6, "6 output leaves");
        assertEq(bob.balance - bobBefore, 1 ether + 0.5 ether, "both unshields paid in full, the fee on top");
    }

    function test_PrivateSwapResidualRoutedToDex() public {
        depositNative(alice, 10 ether);
        vm.startPrank(alice);
        usd.approve(address(pool), 5e18);
        pool.absorb(usdAssetId, 5e18, fresh());
        vm.stopPrank();

        vm.prank(safe);
        pool.proposeRouter(address(dex));
        vm.warp(block.timestamp + pool.ROUTER_DELAY());
        pool.executeRouterApproval(address(dex));
        usd.mint(address(dex), 1e24);
        vm.deal(address(dex), 100 ether);

        // The residual is 1 ether of native (asset 0) swapped into USD at price 1e18.
        TIntent[] memory intents = new TIntent[](1);
        intents[0] = newIntent(0, 0, address(0), 0);
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 1e18, intents);

        ShieldedPool.ResidualExec memory r;
        r.router = address(dex);
        r.assetIn = 0;
        r.assetOut = usdAssetId;
        r.amountIn = 1 ether;
        r.amountOutMin = 0.99e18;
        r.deadline = block.timestamp + 100;
        address[] memory path = new address[](2);
        path[0] = address(0x1111); // placeholder, a native leg checks only the tokenOut endpoint
        path[1] = address(usd);
        r.path = path;

        uint256 nativeBefore = pool.totalShielded(0);
        uint256 usdBefore = pool.totalShielded(usdAssetId);
        vm.recordLogs();
        pool.settleBatch(hex"70", w, r, "", _blobsFor(w));

        // both assets are topics, so an indexer can filter residuals by either side
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ResidualRouted(uint64,uint64,uint256,uint256)");
        bool seen;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            seen = true;
            assertEq(logs[i].topics.length, 3, "assetIn and assetOut indexed");
            assertEq(uint256(logs[i].topics[1]), 0, "assetIn topic");
            assertEq(uint256(logs[i].topics[2]), usdAssetId, "assetOut topic");
            assertEq(logs[i].data, abi.encode(uint256(1 ether), uint256(1e18)), "amounts in data");
        }
        assertTrue(seen, "ResidualRouted not emitted");

        assertEq(nativeBefore - pool.totalShielded(0), 1 ether, "native residual left");
        assertEq(pool.totalShielded(usdAssetId) - usdBefore, 1e18, "usd residual entered");
    }

    /// A residual from an asset into itself is refused: the balance delta would count the input
    /// leaving as a loss and strand it in the pool.
    function test_SameAssetResidualReverts() public {
        vm.startPrank(alice);
        usd.approve(address(pool), 5e18);
        pool.absorb(usdAssetId, 5e18, fresh());
        vm.stopPrank();
        vm.prank(safe);
        pool.proposeRouter(address(dex));
        vm.warp(block.timestamp + pool.ROUTER_DELAY());
        pool.executeRouterApproval(address(dex));
        usd.mint(address(dex), 1e24);

        TIntent[] memory intents = new TIntent[](1);
        intents[0] = newIntent(0, 0, address(0), 0);
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 1e18, intents);
        ShieldedPool.ResidualExec memory r;
        r.router = address(dex);
        r.assetIn = usdAssetId;
        r.assetOut = usdAssetId;
        r.amountIn = 1e18;
        r.amountOutMin = 1e18;
        r.deadline = block.timestamp + 100;
        address[] memory path = new address[](2);
        path[0] = address(usd);
        path[1] = address(usd);
        r.path = path;

        vm.expectRevert(ShieldedPool.SameAssetResidual.selector);
        pool.settleBatch(hex"70", w, r, "", _blobsFor(w));
    }

    function test_ResidualBelowBandReverts() public {
        depositNative(alice, 10 ether);
        vm.prank(safe);
        pool.proposeRouter(address(dex));
        vm.warp(block.timestamp + pool.ROUTER_DELAY());
        pool.executeRouterApproval(address(dex));
        usd.mint(address(dex), 1e24);

        TIntent[] memory intents = new TIntent[](1);
        intents[0] = newIntent(0, 0, address(0), 0);
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 1e18, intents);

        ShieldedPool.ResidualExec memory r;
        r.router = address(dex);
        r.assetIn = 0;
        r.assetOut = usdAssetId;
        r.amountIn = 1 ether;
        r.amountOutMin = 0.5e18; // far below the 1e18 clearing price, outside the band
        r.deadline = block.timestamp + 100;
        address[] memory path = new address[](2);
        path[0] = address(0x1111);
        path[1] = address(usd);
        r.path = path;

        vm.expectRevert(ShieldedPool.ResidualBelowBand.selector);
        pool.settleBatch(hex"70", w, r, "", _blobsFor(w));
    }

    function test_DoubleSpendAcrossBatchesReverts() public {
        depositNative(alice, 5 ether);
        uint256[] memory w = singleIntent(1e17, 0, bob);
        settle(w);

        TIntent[] memory intents = new TIntent[](1);
        intents[0] = newIntent(0, 0, address(0), 0);
        intents[0].nf0 = bytes32(w[NF0]); // replay
        uint256[] memory w2 = encodeBatch(pool.currentRoot(), assocRoot, 0, intents);
        vm.expectRevert(ShieldedPool.NullifierAlreadySpent.selector);
        settle(w2);
    }

    function test_DuplicateNullifierWithinIntentReverts() public {
        depositNative(alice, 1 ether);
        TIntent[] memory intents = new TIntent[](1);
        intents[0] = newIntent(0, 0, address(0), 0);
        intents[0].nf1 = intents[0].nf0;
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 0, intents);
        vm.expectRevert(ShieldedPool.DuplicateNullifier.selector);
        settle(w);
    }

    function test_DuplicateNullifierAcrossIntentsReverts() public {
        depositNative(alice, 1 ether);
        TIntent[] memory intents = new TIntent[](2);
        intents[0] = newIntent(0, 0, address(0), 0);
        intents[1] = newIntent(0, 0, address(0), 0);
        intents[1].nf0 = intents[0].nf1;
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 0, intents);
        vm.expectRevert(ShieldedPool.NullifierAlreadySpent.selector);
        settle(w);
    }

    function test_NonUniformClearingPriceReverts() public {
        depositNative(alice, 1 ether);
        TIntent[] memory intents = new TIntent[](2);
        intents[0] = newIntent(0, 0, address(0), 0);
        intents[1] = newIntent(0, 0, address(0), 0);
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 1e18, intents);
        w[9 + 12] = 2e18; // second intent's clearingPrice differs
        vm.expectRevert(ShieldedPool.NonUniformClearingPrice.selector);
        settle(w);
    }

    function test_UnregisteredAssocRootReverts() public {
        depositNative(alice, 1 ether);
        TIntent[] memory intents = new TIntent[](1);
        intents[0] = newIntent(0, 0, address(0), 0);
        uint256[] memory w = encodeBatch(pool.currentRoot(), dig("rogue"), 0, intents);
        vm.expectRevert(ShieldedPool.UnknownAssociationRoot.selector);
        settle(w);
    }

    function test_UnknownRootReverts() public {
        depositNative(alice, 1 ether);
        TIntent[] memory intents = new TIntent[](1);
        intents[0] = newIntent(0, 0, address(0), 0);
        uint256[] memory w = encodeBatch(dig("never"), assocRoot, 0, intents);
        vm.expectRevert(ShieldedPool.UnknownOrStaleRoot.selector);
        settle(w);
    }

    function test_StaleRootEviction() public {
        depositNative(alice, 1 ether);
        pool.commitRoot();
        bytes32 oldRoot = pool.currentRoot();
        for (uint256 i = 0; i < 127; ++i) {
            depositNative(alice, 0.001 ether);
            pool.commitRoot(); // the ring advances once per published root
        }
        assertTrue(pool.isKnownRoot(oldRoot), "still in window");

        depositNative(alice, 0.001 ether);
        pool.commitRoot(); // evicts oldRoot
        assertFalse(pool.isKnownRoot(oldRoot), "evicted");
        TIntent[] memory intents = new TIntent[](1);
        intents[0] = newIntent(0, 0, address(0), 0);
        uint256[] memory w = encodeBatch(oldRoot, assocRoot, 0, intents);
        vm.expectRevert(ShieldedPool.UnknownOrStaleRoot.selector);
        settle(w);
    }

    function test_InvalidProofReverts_AndDoesNotSettle() public {
        depositNative(alice, 1 ether);
        verifier.setResult(false);
        uint256[] memory w = singleIntent(1e17, 0, bob);
        vm.expectRevert(ShieldedPool.InvalidProof.selector);
        settle(w);
        verifier.setResult(true);
        assertFalse(pool.nullifierSpent(bytes32(w[NF0])), "reverted tx marked nothing");
    }

    function test_NonCanonicalBatchInputsRevert() public {
        depositNative(alice, 1 ether);
        uint256[] memory w = singleIntent(0, 0, address(0));
        w[NF0] = type(uint256).max;
        vm.expectRevert(ShieldedPool.NonCanonicalFieldElement.selector);
        settle(w);
    }

    function test_ShieldInViaBatchReverts() public {
        depositNative(alice, 1 ether);
        uint256[] memory w = singleIntent(0, 0, address(0));
        w[PUBLIC_AMOUNT] = uint256(-int256(1e15)); // negative public_amount
        vm.expectRevert(ShieldedPool.ShieldInViaDepositOnly.selector);
        settle(w);
    }

    function test_BadBatchLayoutReverts() public {
        depositNative(alice, 1 ether);
        uint256[] memory w = new uint256[](11); // one word short of an intent
        vm.expectRevert(ShieldedPool.BadBatchLayout.selector);
        pool.settleBatch(hex"70", w, noResidual(), "", _blobsFor(w));
    }

    function test_ResidualRequiresApprovedRouter() public {
        depositNative(alice, 10 ether);
        TIntent[] memory intents = new TIntent[](1);
        intents[0] = newIntent(0, 0, address(0), 0);
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 1e18, intents);
        ShieldedPool.ResidualExec memory r;
        r.router = address(dex); // not approved
        r.assetIn = 0;
        r.assetOut = usdAssetId;
        r.amountIn = 1 ether;
        r.amountOutMin = 1e18;
        r.deadline = block.timestamp + 100;
        address[] memory path = new address[](2);
        path[0] = address(0x1111);
        path[1] = address(usd);
        r.path = path;
        vm.expectRevert(ShieldedPool.RouterNotApproved.selector);
        pool.settleBatch(hex"70", w, r, "", _blobsFor(w));
    }

    function test_SettlerGate() public {
        depositNative(alice, 1 ether);
        vm.prank(safe);
        pool.proposeSettler(keeper);
        vm.warp(block.timestamp + pool.SETTLER_DELAY());
        pool.executeSettlerChange();

        uint256[] memory w = singleIntent(0, 0, address(0));
        vm.prank(alice);
        vm.expectRevert(ShieldedPool.NotSettler.selector);
        settle(w);

        vm.prank(keeper);
        settle(w);
    }

    function test_CrossAssetDrainBlockedByAccounting() public {
        depositNative(alice, 10 ether);
        TIntent[] memory intents = new TIntent[](1);
        intents[0] = newIntent(1e18, 0, bob, usdAssetId); // unshield USD backed by nothing
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 0, intents);
        vm.expectRevert(ShieldedPool.ShieldedBalanceUnderflow.selector);
        settle(w);
    }

    function test_TooManyIntentsReverts() public {
        depositNative(alice, 1 ether);
        uint256 n = pool.MAX_INTENTS() + 1;
        TIntent[] memory intents = new TIntent[](n);
        for (uint256 i = 0; i < n; ++i) {
            intents[i] = newIntent(0, 0, address(0), 0);
        }
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 0, intents);
        vm.expectRevert(ShieldedPool.TooManyIntents.selector);
        settle(w);
    }

    function test_FeeBpsHardCap() public {
        vm.prank(safe);
        pool.setFeeBps(50, 50);
        vm.prank(safe);
        vm.expectRevert(ShieldedPool.FeeBpsTooHigh.selector);
        pool.setFeeBps(51, 0);
    }

    function test_BandHardCap() public {
        vm.prank(safe);
        pool.setResidualBand(1000);
        vm.prank(safe);
        vm.expectRevert(ShieldedPool.BandTooHigh.selector);
        pool.setResidualBand(1001);
    }

    function test_OnlyOwnerGovernance() public {
        vm.expectRevert();
        pool.setFeeBps(1, 1);
        vm.expectRevert();
        pool.setDepositsPaused(true);
        vm.expectRevert();
        pool.proposeRouter(address(dex));
        vm.expectRevert();
        pool.proposeSettler(bob);
    }

    function test_FeeRouterChangeTimelocked() public {
        address newRouter = makeAddr("newRouter");
        vm.prank(safe);
        pool.proposeFeeRouter(newRouter);
        vm.expectRevert(ShieldedPool.TimelockNotReady.selector);
        pool.executeFeeRouterChange();
        vm.warp(block.timestamp + pool.FEE_ROUTER_DELAY());
        pool.executeFeeRouterChange();
        assertEq(pool.feeRouter(), newRouter);
    }

    function test_RouterWhitelistTimelockAddInstantRevoke() public {
        vm.prank(safe);
        pool.proposeRouter(address(dex));
        vm.expectRevert(ShieldedPool.TimelockNotReady.selector);
        pool.executeRouterApproval(address(dex));
        vm.warp(block.timestamp + pool.ROUTER_DELAY());
        pool.executeRouterApproval(address(dex));
        assertTrue(pool.approvedRouter(address(dex)));
        vm.prank(safe);
        pool.revokeRouter(address(dex));
        assertFalse(pool.approvedRouter(address(dex)));
    }

    function test_AssetRegistrationOwnerOnlyUnique() public {
        vm.prank(bob);
        vm.expectRevert();
        pool.registerAsset(address(nox), 1);

        uint64 id = registerToken(address(nox));
        assertEq(pool.assetToken(id), address(nox));
        vm.startPrank(safe);
        vm.expectRevert(ShieldedPool.AssetAlreadyRegistered.selector);
        pool.registerAsset(address(nox), 1);
        vm.expectRevert(ShieldedPool.NotAContract.selector);
        pool.registerAsset(makeAddr("eoa"), 1);
        vm.stopPrank();
    }

    function test_DeploymentRevertsWhenVerifierSelfTestFails() public {
        ShieldedPool.DeploymentSelfTest memory st = _selfTest();
        verifier.setResult(false);
        vm.expectRevert(ShieldedPool.VerifierSelfTestFailed.selector);
        new ShieldedPool(
            safe,
            IStarkVerifier(address(verifier)),
            IPoseidonGoldilocks(address(hasher)),
            registry,
            address(feeRouter),
            0,
            0,
            0,
            12,
            st
        );
        verifier.setResult(true);
    }

    function test_DeploymentRevertsWhenHasherSelfTestFails() public {
        ShieldedPool.DeploymentSelfTest memory st = _selfTest();
        st.hash2Expected = dig("wrong");
        vm.expectRevert(ShieldedPool.HasherSelfTestFailed.selector);
        new ShieldedPool(
            safe,
            IStarkVerifier(address(verifier)),
            IPoseidonGoldilocks(address(hasher)),
            registry,
            address(feeRouter),
            0,
            0,
            0,
            12,
            st
        );
    }

    function MAX_FEE_BPS_LOCAL() internal view returns (uint256) {
        return pool.MAX_FEE_BPS();
    }

}
