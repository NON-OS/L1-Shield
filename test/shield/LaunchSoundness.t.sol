// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {LaunchBase} from "./LaunchBase.sol";
import {RealSplitVerifier} from "../../contracts/shield/verifier/RealSplitVerifier.sol";
import {StagedStarkVerifier} from "../../contracts/shield/verifier/StagedStarkVerifier.sol";
import {ComposedStarkVerifier} from "../../contracts/shield/verifier/ComposedStarkVerifier.sol";

/// The adapter's provable figure is the weakest round under BCIKS20: the query term, each fold as
/// the curve its challenge powers form, and the DEEP batching round, with the worst-case loss of
/// challenges drawn by reduction mod p. At the launch point the DEEP round sets it: 54.4 bits before
/// that loss, 52.4 after, and 80.0 under the 2025 proximity gaps, a preprint the adapter does not
/// rest on (docs/02-threat-model.md). Pinned at the launch point.
contract LaunchSoundnessTest is LaunchBase {
    /// 19 queries at rate 1/64, a 20-bit grind per FRI layer, 8 query nonces of 25 bits.
    function test_theLaunchPointIsFiftyTwoBits() public view {
        assertEq(v.nq(), 19, "queries");
        assertEq(uint256(_soundness().outerExtraBlowupBits) + 1, 6, "rate 1/64");
        assertEq(v.roundGrindBits(), 20, "round grind");
        assertEq(v.finalSearches(), 8, "query nonces");
        assertEq(v.grindBits(), 25, "bits per query nonce");

        (uint256 query, uint256 commit) = a.soundnessTermsForSize(1);
        // 19 (3 - log2(7/6)) + 25 + log2 8
        assertEq(query, 80_774_533, "query phase, millionths of a bit");
        // 128 - log2(3.5^7 (2^23)^2 / (3 (1/64)^1.5)) - 2 - log2 3 + 20: a radix-4 fold is a curve of
        // degree 3, and the launch transcript draws by reduction mod p
        assertEq(commit, 78_348_946, "commit phase, millionths of a bit");
        (uint256 conjectured, uint256 provable) = a.soundnessBits();
        assertEq(a.soundnessDeepTermForSize(1), 52_434_063, "DEEP round, millionths of a bit");
        assertEq(provable, 52, "the weakest round, whole bits");
        assertEq(conjectured, 19 * 6 + 28, "conjectured");
    }

    /// Round by round, the proximity-gap error of the commit term without its grind belongs to the
    /// round that draws the DEEP coefficients. They are powers of one draw, a curve of degree
    /// 2w + nPeriodic = 181, which multiplies that error by 181 (BCIKS20, Theorem 1.5), and no nonce
    /// is ground before the draw. That is 54.4 bits before the sampling loss; the adapter charges the
    /// loss as well, since the launch transcript draws by reduction mod p, and returns 52.
    function test_theDeepBatchingRoundSetsTheProvableFigure() public view {
        assertTrue(v.powerDeep(), "powers of one draw");
        assertEq(2 * v.traceWidth() + v.nPeriodic(), 181, "degree of the DEEP curve");
        (uint256 query, uint256 commit) = a.soundnessTermsForSize(1);
        // log2 3 = 1.5849625 and log2 181 = 7.4998459, rounded up so the figure errs low
        uint256 line = commit - v.roundGrindBits() * 1e6 + 1_584_963 + 2e6;
        assertEq(line, 61_933_909, "one line, no grind, no sampling loss");
        uint256 deep = line - 7_499_846;
        assertEq(deep, 54_434_063, "DEEP batching round under BCIKS20");
        assertEq(a.soundnessDeepTermForSize(1), deep - 2e6, "the adapter charges the sampling loss");
        assertLt(deep, query);
        assertLt(deep, commit);
        (, uint256 reported) = a.soundnessBits();
        assertEq(reported, 52, "what the adapter returns");
        // a 26-bit nonce before the draw would lift the round to 80, with exact draws
        assertEq((deep + 26e6) / 1e6, 80);
    }

    /// The same DEEP round under the 2025 proximity gaps (Ben-Sasson, Carmon, Haboeck, Kopparty and
    /// Saraf, a preprint, Theorems 1.5 and 4.2). A line has at most
    ///     a = 2 (m + 1/2)^5 N / (3 rho^1.5) + (gamma N + 1)(m + 1/2) / sqrt(rho)
    /// bad challenges, linear in N, and a curve of degree 181 has 181 a. In integers, with m = 3,
    /// N = 2^23, gamma bounded by 1, and 1/rho^1.5 and 1/sqrt(rho) at the code's true rate
    /// (2^17 - 1) / 2^23 bounded by 2^9 (1 + 2^-16) and 8 (1 + 2^-16), so every step errs high:
    ///     3 * 2^16 * a <= A3 = (16807 * 2^28 + 3 * 28 * (N + 1)) (2^16 + 1).
    /// The round clears 80 bits iff 181 a 2^80 <= p^2, and it does; it does not clear 81.
    function test_theDeepRoundUnderBothTheorems() public view {
        assertTrue(v.powerDeep(), "powers of one draw");
        assertEq(v.logDomain(), 23, "N = 2^23");
        assertEq(uint256(_soundness().outerExtraBlowupBits) + 1, 6, "rate 1/64");
        uint256 p = 2 ** 64 - 2 ** 32 + 1;
        uint256 n = 2 ** 23;
        uint256 a3 = (16_807 * 2 ** 28 + 3 * 28 * (n + 1)) * (2 ** 16 + 1);
        // 181 a 2^80 <= p^2  <=>  181 A3 2^80 <= 3 2^16 p^2  <=>  181 A3 2^64 <= 3 p^2
        assertLe(181 * a3 * 2 ** 64, 3 * p * p, "80 bits under the 2025 bound");
        assertGt(181 * a3 * 2 ** 65, 3 * p * p, "not 81: the margin is under one bit");

        // under BCIKS20 the same round is 54, and 52 with the worst-case sampling loss
        assertEq(a.soundnessDeepTermForSize(1), 52_434_063, "52 under the 2020 bound, sampling loss charged");
    }

    /// Without the per-round grind the commit term falls to 58.35, far under 80: the grind is what
    /// carries it. The DEEP round, 52, is weaker still.
    function test_withoutTheRoundGrindTheCommitTermDecides() public {
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
        ComposedStarkVerifier a2 = _adapter(v2, ev);
        (uint256 query, uint256 commit) = a2.soundnessTermsForSize(1);
        assertEq(commit, 58_348_946, "commit phase without its grind");
        assertLt(commit, query);
        (, uint256 provable) = a2.soundnessBits();
        assertEq(provable, 52);
    }

    /// Independent DEEP coefficients drop the factor 181: the DEEP round is then one line's error,
    /// 61.93, less the sampling loss, and still the weakest.
    function test_independentDeepCoefficientsDropTheCurveFactor() public {
        RealSplitVerifier.Codec memory c = _codec();
        c.powerDeep = false;
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
        ComposedStarkVerifier a2 = _adapter(v2, ev);
        assertEq(a2.soundnessDeepTermForSize(1), 59_933_909, "no curve factor");
        (, uint256 provable) = a2.soundnessBits();
        assertEq(provable, 59);
    }

    /// One query nonce of 28 bits prices the same as eight of 25.
    function test_aSplitGrindCountsAsItsTotalWork() public {
        RealSplitVerifier.Codec memory c = _codec();
        c.finalSearches = 0;
        RealSplitVerifier v2 = new RealSplitVerifier(
            v.nq(),
            v.logDomain(),
            v.logTraceLen(),
            v.traceWidth(),
            v.nCoeffs(),
            28,
            v.cosetShift(),
            v.nPeriodic(),
            v.periodicRoot(),
            true,
            c
        );
        uint256[] memory sizes = new uint256[](1);
        sizes[0] = 1;
        RealSplitVerifier[] memory vs = new RealSplitVerifier[](1);
        vs[0] = v2;
        StagedStarkVerifier.Soundness[] memory sd = new StagedStarkVerifier.Soundness[](1);
        sd[0] = _soundness();
        sd[0].outerGrindBits = 28;
        ComposedStarkVerifier a2 = new ComposedStarkVerifier(sizes, vs, sd, address(0), ev, WORDS);
        (uint256 q1,) = a.soundnessTermsForSize(1);
        (uint256 q2,) = a2.soundnessTermsForSize(1);
        assertEq(q1, q2);
    }
}
