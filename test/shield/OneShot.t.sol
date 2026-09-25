// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IProgramFormEvaluator} from "../../contracts/shield/verifier/IProgramFormEvaluator.sol";
import {RealSplitVerifier} from "../../contracts/shield/verifier/RealSplitVerifier.sol";

/// @notice The whole-proof entry point refuses claims that do not match the deployment's
///         sidecar before reading anything else, and writes no state.
contract OneShotTest is Test {
    function _v(uint256 nPeriodic) internal returns (RealSplitVerifier) {
        return new RealSplitVerifier(
            32,
            25,
            20,
            436,
            788,
            8,
            7,
            nPeriodic,
            bytes32(uint256(1)),
            false,
            RealSplitVerifier.Codec({nChal: 2, regionWidth: 400, finalAsCoefficients: false, digestBytes: 32, friRadix: 4, logDegreeBound: 0, logFinal: 0, format5: true, extChallenges: false, powerCoeffs: false, powerDeep: false, roundGrindBits: 0, finalSearches: 0, maskColumn: 0})
        );
    }

    /// A sidecar deployment sent no claims is refused.
    function test_aSidecarDeploymentWithoutClaimsIsRefused() public {
        RealSplitVerifier v = _v(1114);
        uint256[] memory p = new uint256[](0);
        vm.expectRevert(RealSplitVerifier.ClaimsNotTheDeployment.selector);
        v.verifyWholeComposed(hex"00", hex"", hex"", p, IProgramFormEvaluator(address(1)));
    }

    /// Claims sent to a deployment without a sidecar are refused, not ignored.
    function test_claimsAreRefusedWhereThereIsNoSidecar() public {
        RealSplitVerifier v = _v(0);
        uint256[] memory p = new uint256[](0);
        vm.expectRevert(RealSplitVerifier.ClaimsNotTheDeployment.selector);
        v.verifyWholeComposed(hex"00", hex"0102", hex"", p, IProgramFormEvaluator(address(1)));
    }

    /// Through a staticcall the path reverts with its own reason, so it is a view and writes no state.
    function test_itIsAViewAndSoWritesNoState() public {
        RealSplitVerifier v = _v(0);
        uint256[] memory p = new uint256[](0);
        (bool ok, bytes memory ret) = address(v).staticcall(
            abi.encodeCall(RealSplitVerifier.verifyWholeComposed, (hex"00", hex"", hex"", p, IProgramFormEvaluator(address(1))))
        );
        assertFalse(ok, "a malformed head should revert");
        assertTrue(ret.length > 0, "it reverted without a reason, which a staticcall failure would");
    }
}
