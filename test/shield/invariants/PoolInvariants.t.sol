// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console2} from "forge-std/console2.sol";

import {ShieldedPool} from "../../../contracts/shield/ShieldedPool.sol";
import {AssociationSetRegistry} from "../../../contracts/shield/AssociationSetRegistry.sol";
import {MockPoseidonGoldilocks} from "../mocks/MockPoseidonGoldilocks.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

import {PoolHandler, PoolDeploy, HandlerVerifier, SwitchableFeeSink} from "./PoolHandler.sol";

/// Custody and accounting invariants of the pool, driven by PoolHandler.
/// Run:  FOUNDRY_INVARIANT_RUNS=5000 FOUNDRY_INVARIANT_DEPTH=200 forge test --match-contract PoolInvariants
contract PoolInvariants is StdInvariant, PoolDeploy {
    ShieldedPool internal pool;
    PoolHandler internal handler;
    MockERC20 internal usd;
    uint64 internal usdId;

    address internal safe = makeAddr("safe");

    function setUp() public {
        vm.warp(1_750_000_000);
        MockPoseidonGoldilocks hasher = new MockPoseidonGoldilocks();
        HandlerVerifier verifier = new HandlerVerifier();
        AssociationSetRegistry registry = new AssociationSetRegistry();
        SwitchableFeeSink sink = new SwitchableFeeSink();
        usd = new MockERC20("USD", "USD");
        pool = _deployPool(safe, verifier, hasher, registry, address(sink));
        usdId = _registerAsset(pool, safe, address(usd), 1e6);

        bytes32 assoc = bytes32(uint256(0xA55C));
        registry.publishRoot(assoc, "");

        address outsider = makeAddr("outsider");
        vm.deal(outsider, 1e30);
        usd.mint(outsider, 1e30);
        vm.prank(outsider);
        usd.approve(address(pool), type(uint256).max);

        address[] memory actors = new address[](4);
        for (uint256 i = 0; i < actors.length; ++i) {
            actors[i] = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
            vm.deal(actors[i], 1e30);
            usd.mint(actors[i], 1e30);
            vm.prank(actors[i]);
            usd.approve(address(pool), type(uint256).max);
        }

        // the pool starts in beta, so every actor is allowlisted and the caps are opened
        vm.startPrank(safe);
        for (uint256 i = 0; i < actors.length; ++i) {
            pool.setBetaDepositor(actors[i], true);
        }
        pool.setBetaCaps(0, type(uint128).max, type(uint128).max);
        pool.setBetaCaps(usdId, type(uint128).max, type(uint128).max);
        vm.stopPrank();

        handler = new PoolHandler(
            pool,
            verifier,
            usd,
            sink,
            safe,
            assoc,
            usdId,
            actors,
            makeAddr("settlerA"),
            makeAddr("settlerB"),
            outsider
        );
        targetContract(address(handler));
    }

    function _balance(uint64 asset) internal view returns (uint256) {
        return asset == 0 ? address(pool).balance : usd.balanceOf(address(pool));
    }

    /// For each asset the pool holds at least the shielded total, the held credits and the held fees.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_solvency() public view {
        for (uint64 a = 0; a <= usdId; ++a) {
            uint256 owed = pool.totalShielded(a) + pool.totalClaimable(a) + pool.unsweptFees(a);
            assertGe(_balance(a), owed, "pool holds less than it owes");
        }
    }

    /// totalShielded matches the handler's ledger and, while the pool is live, the live note value.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_ledgerMovesOnlyByDepositsUnshieldsAndRefunds() public view {
        for (uint64 a = 0; a <= usdId; ++a) {
            assertEq(pool.totalShielded(a), handler.ghostShielded(a), "totalShielded left the ledger");
            if (!pool.betaWoundDown()) {
                assertEq(
                    pool.totalShielded(a), handler.liveNoteValue(a) * pool.scale(a), "totalShielded differs from live notes"
                );
            }
        }
    }

    /// While the pool is live, every shielded total is a whole number of note units.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_shieldedTotalsAreWholeUnits() public view {
        if (pool.betaWoundDown()) return;
        for (uint64 a = 0; a <= usdId; ++a) {
            assertEq(pool.totalShielded(a) % pool.scale(a), 0, "a fraction of a unit is shielded");
        }
    }

    /// Every note the model spent is marked spent, and no replay of a nullifier settles.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_nullifierSpentAtMostOnce() public view {
        assertEq(handler.nullifierViolations(), 0, "a spent nullifier settled again");
        assertTrue(handler.everySpentNoteIsMarked(), "a settled nullifier is not marked spent");
    }

    /// Leaves grow by one per deposit and two per intent, and the current root is always known.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_leavesOnlyGrowAndTheRootIsKnown() public view {
        assertEq(handler.treeViolations(), 0, "leaf count moved backwards or commitRoot left an unknown root");
        assertEq(uint256(pool.nextLeafIndex()), handler.ghostLeaves(), "leaf count differs from inserts");
        assertTrue(pool.isKnownRoot(pool.currentRoot()), "current root is not known");
    }

    /// Both fee rates stay at or under MAX_FEE_BPS, and no intent with a fee above the cap settles.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_feesNeverExceedTheirCaps() public view {
        assertLe(pool.shieldFeeBps(), pool.MAX_FEE_BPS(), "shield fee above cap");
        assertLe(pool.unshieldFeeBps(), pool.MAX_FEE_BPS(), "unshield fee above cap");
        assertEq(handler.feeCapViolations(), 0, "a fee above the cap was accepted");
    }

    /// A wound-down pool never absorbs or settles, and a paused pool never absorbs.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_aWoundDownPoolNeverSettlesOrAbsorbs() public view {
        assertEq(handler.windDownViolations(), 0, "a wound-down pool took a deposit or a settlement");
        assertEq(handler.pauseViolations(), 0, "a paused pool took a deposit");
    }

    /// Outside the settler window and the open slot only the settler settles. A refused proof never settles.
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_theSettlerGate() public view {
        assertEq(handler.gateViolations(), 0, "the gate let a stranger in or kept one out");
        assertEq(handler.proofViolations(), 0, "a refused proof settled");
    }

    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_honestBatchesSettle() public view {
        assertEq(handler.unexpectedReverts(), 0, handler.lastUnexpectedWhere());
    }

    function afterInvariant() external view {
        console2.log("absorbs", handler.okAbsorbs(), "of", handler.absorbAttempts());
        console2.log("settles", handler.okSettles(), "unexpected", handler.unexpectedReverts());
        console2.log("intents", handler.okIntents(), "unshields", handler.okUnshields());
        console2.log("refunds", handler.okRefunds(), "commits", handler.okCommits());
        console2.log("claims", handler.okClaims(), "sweeps", handler.okSweeps());
        console2.log("gate refusals", handler.refusedByGate(), "open-slot strangers", handler.settledInOpenSlotByStranger());
        console2.log("replays refused", handler.refusedReplays(), "proofs refused", handler.refusedProofs());
        console2.log("over-cap refused", handler.refusedOverCapFees(), "after wind-down", handler.refusedAfterWindDown());
    }
}
