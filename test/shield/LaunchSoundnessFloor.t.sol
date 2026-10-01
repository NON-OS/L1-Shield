// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {LaunchBase} from "./LaunchBase.sol";
import {RealSplitVerifier} from "../../contracts/shield/verifier/RealSplitVerifier.sol";
import {StagedStarkVerifier} from "../../contracts/shield/verifier/StagedStarkVerifier.sol";
import {ComposedStarkVerifier} from "../../contracts/shield/verifier/ComposedStarkVerifier.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";
import {IStarkVerifier} from "../../contracts/shield/interfaces/IStarkVerifier.sol";
import {IPoseidonGoldilocks} from "../../contracts/shield/interfaces/IPoseidonGoldilocks.sol";
import {IAssociationSetRegistry} from "../../contracts/shield/interfaces/IAssociationSetRegistry.sol";
import {MockPoseidonGoldilocks} from "./mocks/MockPoseidonGoldilocks.sol";

/// Gas of the floor read, cold then warm, measured inside one call.
contract FloorProbe {
    function measure(ComposedStarkVerifier a, uint256 n) external view returns (uint256 cold, uint256 warm) {
        uint256 g = gasleft();
        a.soundnessBitsForSize(n);
        cold = g - gasleft();
        g = gasleft();
        a.soundnessBitsForSize(n);
        warm = g - gasleft();
    }
}

/// The pool's soundness floor against the launch adapter.
contract LaunchSoundnessFloorTest is LaunchBase {
    // The tree's constructor hashes before the floor is read, so the hasher must be real code.
    function _deployRefused(ComposedStarkVerifier adapter, uint256 bits) internal returns (ShieldedPool) {
        ShieldedPool.DeploymentSelfTest memory st;
        IPoseidonGoldilocks h = IPoseidonGoldilocks(address(new MockPoseidonGoldilocks()));
        vm.expectRevert(abi.encodeWithSelector(ShieldedPool.SoundnessBelowFloor.selector, 0, bits));
        return new ShieldedPool(
            makeAddr("safe"),
            IStarkVerifier(address(adapter)),
            h,
            IAssociationSetRegistry(makeAddr("registry")),
            makeAddr("router"),
            0,
            0,
            1,
            WORDS,
            st
        );
    }

    /// The read settleBatch makes costs under 6,000 gas on the launch adapter, cold: the figures are
    /// computed once at construction and read back from one slot.
    function test_theFloorReadCostsUnder6kGas() public {
        FloorProbe p = new FloorProbe();
        vm.cool(address(a));
        vm.cool(address(v));
        (uint256 cold, uint256 warm) = p.measure(a, 1);
        emit log_named_uint("floor read, cold", cold);
        emit log_named_uint("floor read, warm", warm);
        (, uint256 provable) = a.soundnessBitsForSize(1);
        assertEq(provable, 52);
        assertLt(cold, 6_000);
    }

    /// A size the adapter does not serve has no figure, so a batch of that size cannot pass the floor.
    function test_anUnservedSizeHasNoFigure() public {
        vm.expectRevert(abi.encodeWithSelector(StagedStarkVerifier.NoVerifierForSize.selector, 2));
        a.soundnessBitsForSize(2);
    }

    /// The launch adapter itself: 52 bits provable, set by the DEEP batching round with no grind
    /// before it and the worst-case loss of draws by reduction mod p. Its query term clears 80, its
    /// fold round is 78.35 with that loss, and no format 7 pool deploys on it.
    function test_theLaunchAdapterIsRefused() public {
        (uint256 query, uint256 commit) = a.soundnessTermsForSize(1);
        assertGe(query, 80e6);
        assertEq(commit, 78_348_946);
        _deployRefused(a, 52);
    }

    /// The launch adapter without its per-round grind is 52 bits provable, and no pool deploys on it.
    function test_theAdapterWithoutRoundGrindIsRefused() public {
        RealSplitVerifier.Codec memory c = _codec();
        c.roundGrindBits = 0;
        RealSplitVerifier v2 = new RealSplitVerifier(
            v.nq(),
            v.logDomain(),
            v.logTraceLen(),
            v.traceWidth(),
            v.nCoeffs(),
            v.grindBits(),
            v.cosetShift(),
            v.nPeriodic(),
            v.periodicRoot(),
            true,
            c
        );
        _deployRefused(_adapter(v2, ev), 52);
    }
}
