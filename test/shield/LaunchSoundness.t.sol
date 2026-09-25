// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {LaunchBase} from "./LaunchBase.sol";
import {RealSplitVerifier} from "../../contracts/shield/verifier/RealSplitVerifier.sol";
import {StagedStarkVerifier} from "../../contracts/shield/verifier/StagedStarkVerifier.sol";
import {ComposedStarkVerifier} from "../../contracts/shield/verifier/ComposedStarkVerifier.sol";

/// The published figure is the weaker of the query and commit terms under the full bound, with
/// the per-round grind counted. Pinned at the launch point.
contract LaunchSoundnessTest is LaunchBase {
    /// 19 queries at rate 1/64, a 20-bit grind per FRI layer, 8 query nonces of 25 bits.
    function test_theLaunchPointIsAtLeastEightyBits() public view {
        assertEq(v.nq(), 19, "queries");
        assertEq(uint256(_soundness().outerExtraBlowupBits) + 1, 6, "rate 1/64");
        assertEq(v.roundGrindBits(), 20, "round grind");
        assertEq(v.finalSearches(), 8, "query nonces");
        assertEq(v.grindBits(), 25, "bits per query nonce");

        (uint256 query, uint256 commit) = a.soundnessTermsForSize(1);
        // 19 (3 - log2(7/6)) + 25 + log2 8
        assertEq(query, 80_774_533, "query phase, millionths of a bit");
        // 128 - log2(3.5^7 (2^23)^2 / (3 (1/64)^1.5)) + 20
        assertEq(commit, 81_933_909, "commit phase, millionths of a bit");
        (uint256 conjectured, uint256 provable) = a.soundnessBits();
        assertEq(provable, 80, "the minimum, whole bits");
        assertGe(provable, 80);
        assertEq(conjectured, 19 * 6 + 28, "conjectured");
    }

    /// Without the per-round grind the commit term is the minimum, and it is far under 80: the
    /// grind is what carries it.
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
        assertEq(commit, 61_933_909, "commit phase without its grind");
        assertLt(commit, query);
        (, uint256 provable) = a2.soundnessBits();
        assertEq(provable, 61);
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
