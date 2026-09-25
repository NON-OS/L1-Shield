// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StarkFieldExt as F} from "./StarkFieldExt.sol";
import {RealQueryVerify as V} from "./RealQueryVerify.sol";
import {RealQueryWalk as W} from "./RealQueryWalk.sol";
import {ProductionAir} from "./ProductionAir.sol";
import {IProgramFormEvaluator} from "./IProgramFormEvaluator.sol";

/// @title RealSplitVerifier
/// @notice Verifies one whole STARK proof in a single call, with comp_z computed on chain by the
///         evaluator of the circuit. See docs/03-verifier-overview.md.
contract RealSplitVerifier {
    // proof shape, fixed at deployment
    uint256 public immutable nq;
    uint256 public immutable logDomain;
    uint256 public immutable logTraceLen;
    uint256 public immutable traceWidth;
    uint256 public immutable nCoeffs;
    uint256 public immutable grindBits;
    uint256 public immutable cosetShift;
    /// @notice Permutation challenges drawn, 0 for single-round or 2 for two-round.
    /// @dev One codec per instance, so a prover cannot pick the single-round encoding and skip the copy check.
    uint256 public immutable nChal;
    /// @notice Column where a row splits into its two committed halves. Compared with the proof, never read from it.
    uint256 public immutable regionWidth;
    /// @notice Periodic sidecar column count and root, both zero without a sidecar.
    uint256 public immutable nPeriodic;
    bytes32 public immutable periodicRoot;
    /// @notice A flag the deployment sets. verifyWholeComposed, the only entry point, computes comp_z.
    bool public immutable recomputesCompZ;

    /// @notice Final FRI layer form, coefficients or a repeated constant. Set by the deployment, never by the proof.
    bool public immutable finalAsCoefficients;
    /// @notice Merkle digest width on the wire, in bytes: 24 or 32.
    uint256 public immutable digestBytes;
    /// @notice FRI folding radix, always 4.
    uint256 public immutable friRadix;
    /// @notice log2 of the composition degree bound, checked against every head's FRI shape. Zero only for constant form.
    uint256 public immutable logDegreeBound;
    /// @notice log2 of the final polynomial's coefficient count.
    uint256 public immutable logFinal;
    /// @notice Format 5: FRI draws the only positions and carries the DEEP value. Always true.
    bool public immutable format5;
    /// @notice beta and gamma are Fp2 draws, tags 0x06 and 0x07, instead of one 0x03 squeeze each.
    bool public immutable extChallenges;
    /// @notice The composition coefficients are 1, a, a^2, ... for one Fp2 draw a.
    bool public immutable powerCoeffs;
    /// @notice The DEEP coefficients are 1, a', a'^2, ... for one further Fp2 draw a'.
    bool public immutable powerDeep;
    /// @notice Leading zero bits each FRI round nonce must reach before its fold challenge, 0 for off.
    uint256 public immutable roundGrindBits;
    /// @notice Chained query nonces of grindBits each, 1 for the single grind.
    uint256 public immutable finalSearches;
    /// @notice The first column of the mask pair opened as one Fp2 value, or 0 when the pair is opened apart.
    uint256 public immutable maskColumn;

    /// @notice Wire-format parameters, grouped to keep the constructor inside the stack limit.
    struct Codec {
        uint256 nChal;
        uint256 regionWidth;
        bool finalAsCoefficients;
        uint256 digestBytes; // 24 or 32, zero reads as 32
        uint256 friRadix; // must be 4
        uint256 logDegreeBound; // required for coefficient form
        uint256 logFinal;
        bool format5;
        bool extChallenges;
        bool powerCoeffs;
        bool powerDeep;
        uint256 roundGrindBits; // 0 = no per-round grinding
        uint256 finalSearches; // 0 or 1 = one query nonce
        uint256 maskColumn; // 0 = off, otherwise the first column of the mask pair
    }

    constructor(
        uint256 nq_,
        uint256 logDomain_,
        uint256 logTraceLen_,
        uint256 traceWidth_,
        uint256 nCoeffs_,
        uint256 grindBits_,
        uint256 cosetShift_,
        uint256 nPeriodic_,
        bytes32 periodicRoot_,
        bool recomputesCompZ_,
        Codec memory codec_
    ) {
        nq = nq_;
        logDomain = logDomain_;
        logTraceLen = logTraceLen_;
        traceWidth = traceWidth_;
        nCoeffs = nCoeffs_;
        grindBits = grindBits_;
        // the FRI fold fixes its coset offset, and the DEEP side must use the same one
        if (cosetShift_ != ProductionAir.COSET_SHIFT) revert CosetShiftMismatch(cosetShift_, ProductionAir.COSET_SHIFT);
        cosetShift = cosetShift_;
        nPeriodic = nPeriodic_;
        periodicRoot = periodicRoot_;
        recomputesCompZ = recomputesCompZ_;

        // two rounds need a split strictly inside the row, one round needs none
        if (codec_.nChal != 0) {
            if (codec_.nChal != 2) revert UnsupportedChallengeCount(codec_.nChal);
            if (codec_.regionWidth == 0 || codec_.regionWidth >= traceWidth_) {
                revert RegionWidthOutOfRange(codec_.regionWidth, traceWidth_);
            }
        } else if (codec_.regionWidth != 0) {
            revert RegionWidthOutOfRange(codec_.regionWidth, traceWidth_);
        }
        nChal = codec_.nChal;
        regionWidth = codec_.regionWidth;
        finalAsCoefficients = codec_.finalAsCoefficients;
        uint256 dw = codec_.digestBytes == 0 ? 32 : codec_.digestBytes;
        require(dw == 24 || dw == 32, "digest width must be 24 or 32 bytes");
        digestBytes = dw;
        uint256 rx = codec_.friRadix;
        // a base query's DEEP value is authenticated only as FRI's layer-zero opening, and FRI folds
        // only at radix four, so any other codec would leave the DEEP value unauthenticated
        if (!codec_.format5 || codec_.nChal == 0 || rx != 4) revert FormatFiveOnly();
        friRadix = rx;
        // a coefficient list checks degree only by its length, so pin the length and the fold count
        if (codec_.finalAsCoefficients && codec_.logDegreeBound == 0) revert FriShapeUnpinned();
        if (codec_.logDegreeBound >= logDomain_) revert FriShapeUnpinned();
        if (codec_.logFinal > codec_.logDegreeBound) revert FriShapeUnpinned();
        if ((codec_.logDegreeBound - codec_.logFinal) % 2 != 0) revert FriShapeUnpinned();
        logDegreeBound = codec_.logDegreeBound;
        logFinal = codec_.logFinal;
        format5 = true;
        extChallenges = codec_.extChallenges;
        // a proof-of-work bound past 64 bits has no passing nonce and would only revert
        if (grindBits_ > 64 || codec_.roundGrindBits > 64) revert GrindBitsOutOfRange();
        powerCoeffs = codec_.powerCoeffs;
        powerDeep = codec_.powerDeep;
        roundGrindBits = codec_.roundGrindBits;
        // each search is one Keccak on chain, and past 64 the split buys the prover nothing more
        if (codec_.finalSearches > 64) revert GrindSearchesOutOfRange();
        finalSearches = codec_.finalSearches <= 1 ? 1 : codec_.finalSearches;
        if (codec_.maskColumn != 0 && codec_.maskColumn + 1 >= traceWidth_) revert MaskColumnOutOfRange();
        maskColumn = codec_.maskColumn;
    }

    // finalCount * friRadix^roots must equal 2^logDegreeBound. The loop exits once past the bound.
    function _friShape(V.Head memory h) private view {
        uint256 bound = logDegreeBound;
        if (bound == 0) return;
        uint256 n = h.friRoots.length;
        if (finalAsCoefficients && h.finalCount != uint256(1) << logFinal) {
            revert FriShapeNotTheDeployment(n, h.finalCount);
        }
        uint256 claimed = finalAsCoefficients ? h.finalCount : 1;
        uint256 target = uint256(1) << bound;
        for (uint256 m = 0; m < n && claimed <= target; ++m) claimed *= friRadix;
        if (claimed != target) revert FriShapeNotTheDeployment(n, h.finalCount);
    }

    /// @notice The deployment's proof shape. No field is ever read from the proof.
    function shape() public view returns (V.Shape memory) {
        return V.Shape(
            nq,
            logDomain,
            logTraceLen,
            traceWidth,
            nCoeffs,
            grindBits,
            cosetShift,
            nPeriodic,
            periodicRoot,
            nChal,
            regionWidth,
            digestBytes,
            friRadix,
            finalAsCoefficients,
            format5,
            extChallenges,
            powerCoeffs,
            powerDeep,
            roundGrindBits,
            finalSearches,
            maskColumn
        );
    }

    error CosetShiftMismatch(uint256 configured, uint256 baked);
    /// @notice Claims were passed without a sidecar, or a sidecar deployment got none.
    error ClaimsNotTheDeployment();
    /// @notice verifyWholeComposed was given no evaluator.
    error NoEvaluator();
    error UnsupportedChallengeCount(uint256 nChal);
    /// @notice The row split is zero, at or past the trace width, or set without two rounds.
    error RegionWidthOutOfRange(uint256 regionWidth, uint256 traceWidth);
    /// @notice The FRI shape is missing on a coefficient-form deployment or not reachable in whole folds.
    error FriShapeUnpinned();
    error FriShapeNotTheDeployment(uint256 roots, uint256 finalCount);
    /// @notice Only format 5 at radix four is verified: its DEEP value is FRI's own layer-zero opening.
    error FormatFiveOnly();
    error GrindBitsOutOfRange();
    error GrindSearchesOutOfRange();
    error MaskColumnOutOfRange();
    error ChunkLengthMismatch(uint256 consumed, uint256 supplied);

    // bundled to stay inside the stack limit
    struct Walk {
        V.Head h;
        F.Fp2[] ood;
        V.Shape sh;
        F.Fp2[] betas;
        uint256[] friIdx;
        uint256[] deep; // each query's DEEP value, c0 then c1, from its FRI query
    }

    /// @notice Verifies a whole proof with comp_z computed by `ev` from this call's own replay.
    /// @dev The DEEP check uses the value of `ev` at the replayed z. The proof is read in calldata.
    /// @param ev the evaluator of this circuit's constraints at z.
    /// @return True when every query verifies. Malformed input reverts.
    function verifyWholeComposed(
        bytes calldata head,
        bytes calldata claims,
        bytes calldata queries,
        uint256[] calldata publics,
        IProgramFormEvaluator ev
    ) external view returns (bool) {
        if (address(ev) == address(0)) revert NoEvaluator();
        if ((nPeriodic == 0) != (claims.length == 0)) revert ClaimsNotTheDeployment();

        Walk memory w;
        w.sh = shape();
        (w.h, w.ood) = W.readHead(head, w.sh);
        _friShape(w.h);
        // the claims are absorbed with the frame, so they must be on the head before the checkpoint
        w.h.periodicZ = W.readClaims(claims, w.sh);
        (V.Checkpoint memory ck, F.Fp2[] memory coeffs) = V.mainCheckpointCoeffs(w.h, w.ood, w.sh, publics);
        W.Base memory b = _base(w, ck);
        (uint256 cz0, uint256 cz1) = _evaluate(ev, w, coeffs, publics, ck);
        bytes32 seed;
        (coeffs,, seed) = V.mainResume(ck.state, w.h, w.sh);
        (w.betas, w.friIdx) = V.friChallenges(w.h, w.sh, seed);
        W.prepareDeep(b, w.ood, coeffs, w.h.periodicZ, cz0, cz1);
        uint256 off = _fri(queries, w, b.omega);
        off = _bases(queries, off, w, b);
        if (off != queries.length) revert ChunkLengthMismatch(off, queries.length);
        return true;
    }

    function _base(Walk memory w, V.Checkpoint memory ck) private view returns (W.Base memory b) {
        b.traceRoot = w.h.traceRoot;
        b.permRoot = w.h.permRoot;
        b.compRoot = w.h.compRoot;
        b.periodicRoot = periodicRoot;
        b.w = digestBytes;
        b.traceWidth = traceWidth;
        b.regionWidth = regionWidth;
        b.nPeriodic = nPeriodic;
        b.z0 = ck.z.c0;
        b.z1 = ck.z.c1;
        b.g = F.fpPow(V.GEN, (V.PMOD - 1) >> logTraceLen);
        b.omega = V.domainRoot(w.sh);
        b.cosetShift = cosetShift;
    }

    // Every FRI query first, each recording the layer-zero value its base query checks.
    function _fri(bytes calldata q, Walk memory w, uint256 omega) private view returns (uint256 off) {
        uint256 n = w.sh.nq;
        w.deep = new uint256[](2 * n);
        W.Fri memory f = W.Fri(w.h.friRoots, w.betas, w.h.finalFlat, omega, logDomain, digestBytes, finalAsCoefficients);
        for (uint256 i = 0; i < n; ++i) {
            uint256 fmp = _mark();
            (off, w.deep[2 * i], w.deep[2 * i + 1]) = W.friQuery(q, off, f, w.friIdx[i], i);
            _release(fmp);
        }
    }

    function _bases(bytes calldata q, uint256 off, Walk memory w, W.Base memory b) private pure returns (uint256) {
        uint256 n = w.sh.nq;
        for (uint256 i = 0; i < n; ++i) {
            uint256 fmp = _mark();
            off = W.baseQuery(q, off, b, i, w.friIdx[i], w.deep[2 * i], w.deep[2 * i + 1]);
            _release(fmp);
        }
        return off;
    }

    function _mark() private pure returns (uint256 fmp) {
        assembly {
            fmp := mload(0x40)
        }
    }

    function _release(uint256 fmp) private pure {
        assembly {
            mstore(0x40, fmp)
        }
    }

    /// @dev Fp2 arrays are passed as uint256[2][], whose ABI encoding matches Fp2[].
    function _evaluate(
        IProgramFormEvaluator ev,
        Walk memory w,
        F.Fp2[] memory coeffs,
        uint256[] calldata publics,
        V.Checkpoint memory ck
    ) private view returns (uint256, uint256) {
        uint256[2][] memory fr;
        uint256[2][] memory pz;
        uint256[2][] memory cf;
        F.Fp2[] memory ood = w.ood;
        F.Fp2[] memory per = w.h.periodicZ;
        assembly {
            fr := ood
            pz := per
            cf := coeffs
        }
        return ev.evaluate(fr, pz, cf, publics, _point(ck));
    }

    function _point(V.Checkpoint memory ck) private pure returns (uint256[6] memory) {
        return [ck.beta.c0, ck.beta.c1, ck.gamma.c0, ck.gamma.c1, ck.z.c0, ck.z.c1];
    }
}
