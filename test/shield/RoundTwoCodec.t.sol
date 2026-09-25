// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RealQueryVerify as V} from "../../contracts/shield/verifier/RealQueryVerify.sol";
import {RealSplitVerifier} from "../../contracts/shield/verifier/RealSplitVerifier.sol";
import {StarkTranscript as TS} from "../../contracts/shield/verifier/StarkTranscript.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";

/// @notice The two-round codec: the region columns commit first, beta and gamma are drawn from
///         that root, and the permutation columns commit second. A replay in single-round order
///         diverges at the first squeeze, and a split that authenticates half a row is refused.
contract RoundTwoCodecTest is Test {
    uint256 constant N_COEFFS = 4;

    function _head(uint256 nPz) internal pure returns (V.Head memory h) {
        h.traceRoot = keccak256("traceRoot");
        h.permRoot = keccak256("permRoot");
        h.compRoot = keccak256("compRoot");
        h.periodicZ = new F.Fp2[](nPz);
        for (uint256 i = 0; i < nPz; ++i) {
            h.periodicZ[i] = F.Fp2(100 + i, 200 + i);
        }
    }

    function _shape(uint256 nChal, uint256 regionWidth) internal pure returns (V.Shape memory sh) {
        sh.nCoeffs = N_COEFFS;
        sh.traceWidth = 8;
        sh.nChal = nChal;
        sh.regionWidth = regionWidth;
    }

    function _ood() internal pure returns (F.Fp2[] memory o) {
        o = new F.Fp2[](3);
        for (uint256 i = 0; i < 3; ++i) {
            o[i] = F.Fp2(7 + i, 11 + i);
        }
    }

    function _publics() internal pure returns (uint256[] memory p) {
        p = new uint256[](5);
        for (uint256 i = 0; i < 5; ++i) {
            p[i] = 40960 + i;
        }
    }

    /// The replay, against the same operations written out by hand.
    function test_theRoundTwoReplayIsTheOrderWrittenOutByHand() public pure {
        V.Head memory h = _head(2);
        V.Shape memory sh = _shape(2, 5);
        F.Fp2[] memory ood = _ood();
        uint256[] memory publics = _publics();

        TS.T memory t = TS.init("NONOS-STARK-EXT");
        for (uint256 i = 0; i < publics.length; ++i) {
            TS.absorbFp(t, publics[i]);
        }
        TS.absorbDigest(t, h.traceRoot);
        uint256 beta = TS.challengeFp(t);
        uint256 gamma = TS.challengeFp(t);
        TS.absorbDigest(t, h.permRoot);
        TS.skipChallengeFp2(t, N_COEFFS);
        TS.absorbDigest(t, h.compRoot);
        F.Fp2 memory z = TS.challengeFp2(t);
        for (uint256 i = 0; i < ood.length; ++i) {
            TS.absorbFp(t, ood[i].c0);
            TS.absorbFp(t, ood[i].c1);
        }
        for (uint256 i = 0; i < h.periodicZ.length; ++i) {
            TS.absorbFp(t, h.periodicZ[i].c0);
            TS.absorbFp(t, h.periodicZ[i].c1);
        }

        V.Checkpoint memory c = V.mainCheckpointFull(h, ood, sh, publics);
        assertEq(c.beta.c0, beta, "beta is not the first squeeze after the trace root");
        assertEq(c.gamma.c0, gamma, "gamma is not the second");
        assertEq(c.z.c0, z.c0, "the point diverged");
        assertEq(c.state, t.state, "the transcript state diverged from the written-out order");
    }

    /// The six operations move every later value, so the two-round branch runs.
    function test_theSixOperationsChangeEveryLaterValue() public pure {
        F.Fp2[] memory ood = _ood();
        uint256[] memory publics = _publics();
        V.Checkpoint memory one = V.mainCheckpointFull(_head(2), ood, _shape(0, 0), publics);
        V.Checkpoint memory two = V.mainCheckpointFull(_head(2), ood, _shape(2, 5), publics);

        assertTrue(one.state != two.state, "the two codecs share a transcript state");
        assertTrue(one.z.c0 != two.z.c0 || one.z.c1 != two.z.c1, "the point did not move");
        assertEq(one.beta.c0, 0, "a single-round replay drew a challenge");
        assertTrue(two.beta.c0 != 0 || two.gamma.c0 != 0, "a two-round replay drew nothing");
    }

    /// A value the transcript draws must be read, and a proof that leaves one unread is refused.
    function test_thePairLessFormRefusesATwoRoundDeployment() public {
        V.Head memory h = _head(1);
        V.Shape memory sh = _shape(2, 5);
        F.Fp2[] memory ood = _ood();
        uint256[] memory publics = _publics();
        vm.expectRevert(V.ChallengesWouldBeDiscarded.selector);
        this.callPairLess(h, ood, sh, publics);
    }

    function callPairLess(V.Head memory h, F.Fp2[] memory ood, V.Shape memory sh, uint256[] memory publics)
        external
        pure
        returns (F.Fp2 memory, bytes32)
    {
        return V.mainCheckpoint(h, ood, sh, publics);
    }

    function test_anUnsupportedChallengeCountIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(V.UnsupportedChallengeCount.selector, uint256(3)));
        this.callFull(_head(1), _ood(), _shape(3, 5), _publics());
    }

    function callFull(V.Head memory h, F.Fp2[] memory ood, V.Shape memory sh, uint256[] memory publics)
        external
        pure
        returns (V.Checkpoint memory)
    {
        return V.mainCheckpointFull(h, ood, sh, publics);
    }

    function _deploy(uint256 nChal, uint256 regionWidth) internal returns (RealSplitVerifier) {
        return new RealSplitVerifier(
            32,
            25,
            20,
            436,
            788,
            8,
            7,
            0,
            bytes32(0),
            false,
            RealSplitVerifier.Codec({nChal: nChal, regionWidth: regionWidth, finalAsCoefficients: false, digestBytes: 32, friRadix: 2, logDegreeBound: 0, logFinal: 0, format5: false, extChallenges: false, powerCoeffs: false, powerDeep: false, roundGrindBits: 0, finalSearches: 0, maskColumn: 0})
        );
    }

    function test_aRoundTwoDeploymentWithoutASplitIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(RealSplitVerifier.RegionWidthOutOfRange.selector, uint256(0), uint256(436)));
        _deploy(2, 0);
    }

    /// A split at or past the width leaves the permutation half empty, which authenticates one
    /// half of every row and calls it two.
    function test_aSplitPastTheWidthIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(RealSplitVerifier.RegionWidthOutOfRange.selector, uint256(436), uint256(436)));
        _deploy(2, 436);
    }

    /// And a split with no second root to check it against is a number nobody reads.
    function test_aSingleRoundDeploymentWithASplitIsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(RealSplitVerifier.RegionWidthOutOfRange.selector, uint256(510), uint256(436)));
        _deploy(0, 510);
    }
}
