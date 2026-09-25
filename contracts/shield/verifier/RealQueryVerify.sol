// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StarkFieldExt as F} from "./StarkFieldExt.sol";
import {StarkTranscript as TS} from "./StarkTranscript.sol";
import {StarkMerkle as MK} from "./StarkMerkle.sol";
import {StarkProofReader as R} from "../StarkProofReader.sol";
import {ProductionAir} from "./ProductionAir.sol";
import {ProductionDeepQuery} from "./ProductionDeepQuery.sol";

/// @title RealQueryVerify
/// @notice Proof decoding, both transcript walks and per-query checks, driven by a Shape fixed at deployment.
/// @dev See docs/03-verifier-overview.md.
library RealQueryVerify {
    uint256 internal constant PMOD = 0xFFFFFFFF00000001;
    uint256 internal constant GEN = 7; // field generator, used only for the domain root

    // Every field is deployment config. None is read from the proof.
    struct Shape {
        uint256 nq;
        uint256 logDomain;
        uint256 logTraceLen;
        uint256 traceWidth;
        uint256 nCoeffs; // num_transition + boundaries
        uint256 grindBits;
        uint256 cosetShift; // x = cosetShift * omega^idx
        uint256 nPeriodic; // 0 = no sidecar
        bytes32 periodicRoot;
        uint256 nChal; // 0 single-round, 2 two-round
        uint256 regionWidth; // columns below authenticate under traceRoot, the rest under permRoot
        uint256 digestBytes; // 0 = 32. 24 bytes binds at 2^96 instead of 2^128
        uint256 friRadix; // 0 = 2
        bool finalAsCoefficients; // final layer form picks the degree check
        bool format5; // positions drawn once by FRI, DEEP value read from FRI layer zero
        bool extChallenges; // beta and gamma drawn in Fp2, format 5 only
        bool powerCoeffs; // composition coefficients are the powers of one Fp2 draw
        bool powerDeep; // DEEP coefficients are the powers of one Fp2 draw
        uint256 roundGrindBits; // 0 = off, otherwise the bits each FRI round nonce must meet
        uint256 finalSearches; // 0 or 1 = one query nonce, otherwise that many chained nonces of grindBits each
        uint256 maskColumn; // 0 = off, otherwise columns c and c + 1 are the mask pair, opened as one Fp2 value
    }

    // 2 * width frame terms + 1 composition term + nPeriodic
    function nDeepCoeffs(Shape memory sh) internal pure returns (uint256) {
        return 2 * sh.traceWidth + 1 + sh.nPeriodic;
    }

    struct Head {
        bytes32 traceRoot;
        bytes32 permRoot; // two-round only
        bytes32 compRoot;
        bytes32 deepRoot; // two-round only, must equal friRoots[0]
        bytes32[] friRoots;
        F.Fp2[] finalPoly;
        F.Fp2 finalValue; // finalPoly[0]
        uint256 finalCount;
        F.Fp2[] periodicZ;
        uint64 nonce; // the query nonce when there is one search
        uint256 friQOff;
        uint256 baseQOff;
        uint256[] finalFlat; // calldata decoder: the final layer as c0, c1 per cell
        uint64[] roundNonces; // per-round grinding nonces, one per FRI root
        uint64[] finalNonces; // the chained query nonces when there is more than one search
    }

    struct Challenges {
        uint256 baseOmega; // derived once and carried
        F.Fp2 z;
        F.Fp2[] deepCoeffs;
        uint256[] consIdx;
        F.Fp2[] betas;
        uint256[] friIdx;
        F.Fp2[] deepVals; // format 5: each query's DEEP value, from FRI layer zero
    }

    struct BaseQ {
        F.Fp2 deepVal;
        F.Fp2[3] deepOthers; // two-round only, rest of the layer-zero leaf in order
        bytes32[] deepPath;
        uint256[] traceRow;
        bytes32[] tracePath;
        F.Fp2 comp;
        bytes32[] compPath;
        uint256[] periodicRow;
        bytes32[] periodicPath;
        bytes32[] permPath;
        uint256 traceOff; // row offsets in the input buffer, hashed in place
        uint256 periodicOff;
    }

    // Distinct from TraceAuthFailed: the copy constraint was not committed.
    error CopyCommitMismatch(uint256 queryIndex);
    error GrindRejected();
    error MaskSlotNotZero(uint256 row);
    /// @notice Query nonce `search` of a split grind missed its bound.
    error FinalGrindRejected(uint256 search);
    error FinalLayerNotConstant(uint256 cell);
    error PeriodicAuthFailed(uint256 query);
    error PeriodicCountMismatch(uint256 claimed);
    error OodFrameMismatch(uint256 cells);
    error TraceRowWidthMismatch(uint256 width);
    error HeadTrailingBytes();
    // Both sides are reported. The identity is linear in comp_z, so two misses recover it.
    error DeepMismatch(uint256 query, uint256 gotC0, uint256 gotC1, uint256 wantC0, uint256 wantC1);
    error TraceAuthFailed(uint256 query);
    error DeepRootNotFriRoot();
    error CompAuthFailed(uint256 query);
    error LayerAuthFailed(uint256 query, uint256 layer);
    error FoldChaseFailed(uint256 query);

    // The consistency query must open the codeword FRI tests.
    function _tie(Head memory h, Shape memory sh) private pure {
        if (!sh.format5 && sh.nChal != 0 && (h.friRoots.length == 0 || h.deepRoot != h.friRoots[0])) {
            revert DeepRootNotFriRoot();
        }
    }

    function _fp2(R.Fp2 memory v) private pure returns (F.Fp2 memory) {
        return F.Fp2(uint256(v.c0), uint256(v.c1));
    }

    error RegionWidthMismatch(uint256 declared, uint256 expected);

    // The round-two prefix. The codec is fixed by sh.nChal, and the wire regionWidth is only compared.
    function _readRoundTwoPrefix(bytes memory p, R.Cursor memory c, Shape memory sh, Head memory h)
        private
        pure
    {
        if (sh.nChal == 0) return;
        h.permRoot = R.readDigest(p, c, _dw(sh));
        uint256 rw = R.readU32(p, c);
        if (rw != sh.regionWidth) revert RegionWidthMismatch(rw, sh.regionWidth);
    }

    // Sits between compRoot and the frame, and is not absorbed.
    function _readDeepRoot(bytes memory p, R.Cursor memory c, Shape memory sh, Head memory h) private pure {
        if (sh.nChal == 0 || sh.format5) return;
        h.deepRoot = R.readDigest(p, c, _dw(sh));
    }

    // Array form of R.readFp2, decoded in place. Rejects non-canonical limbs the same way.
    function _readFp2Array(bytes memory p, R.Cursor memory c, uint256 n) private pure returns (F.Fp2[] memory out) {
        uint256 o = c.off;
        if (o + n * 16 > p.length) revert R.OutOfBounds();
        bool bad;
        assembly {
            out := mload(0x40)
            mstore(out, n)
            let ptrs := add(out, 0x20)
            let cells := add(ptrs, mul(n, 32))
            mstore(0x40, add(cells, mul(n, 64)))
            let src := add(add(p, 0x20), o)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let cell := add(cells, mul(i, 64))
                mstore(add(ptrs, mul(i, 32)), cell)
                for { let k := 0 } lt(k, 2) { k := add(k, 1) } {
                    let w := shr(192, mload(add(src, add(mul(i, 16), mul(k, 8)))))
                    w := or(shr(8, and(w, 0xFF00FF00FF00FF00)), shl(8, and(w, 0x00FF00FF00FF00FF)))
                    w := or(shr(16, and(w, 0xFFFF0000FFFF0000)), shl(16, and(w, 0x0000FFFF0000FFFF)))
                    w := or(shr(32, w), and(shl(32, w), 0xFFFFFFFF00000000))
                    if iszero(lt(w, 0xFFFFFFFF00000001)) { bad := 1 }
                    mstore(add(cell, mul(k, 32)), w)
                }
            }
        }
        if (bad) revert R.NonCanonicalFp();
        c.off = o + n * 16;
    }

    function decode(bytes memory p, Shape memory sh) internal pure returns (Head memory h, F.Fp2[] memory ood) {
        R.Cursor memory c = R.Cursor(0);
        _readRoundTwoPrefix(p, c, sh, h);
        h.traceRoot = R.readDigest(p, c, _dw(sh));
        h.compRoot = R.readDigest(p, c, _dw(sh));
        _readDeepRoot(p, c, sh, h);
        uint256 oodN = R.readU32(p, c);
        ood = _readFp2Array(p, c, oodN);
        uint256 rc = R.readU32(p, c);
        h.friRoots = new bytes32[](rc);
        for (uint256 m = 0; m < rc; ++m) {
            h.friRoots[m] = R.readDigest(p, c, _dw(sh));
        }
        _readFinalLayer(p, c, h, sh);
        _tie(h, sh);
        R.readU32(p, c);
        h.friQOff = c.off;
        skipFri(p, c, sh.nq, sh);
        _readNonces(p, c, sh, h);
        R.readU32(p, c);
        h.baseQOff = c.off;
    }

    // friChallenges must absorb these cells before squeezing query indices.
    function _readFinalLayer(bytes memory p, R.Cursor memory c, Head memory h, Shape memory sh)
        private
        pure
    {
        uint256 fc = R.readU32(p, c);
        h.finalCount = fc;
        h.finalPoly = _readFp2Array(p, c, fc);
        h.finalValue = h.finalPoly[0];
        // degree-zero check in cell form
        if (!sh.finalAsCoefficients) {
            for (uint256 i = 1; i < fc; ++i) {
                if (h.finalPoly[i].c0 != h.finalValue.c0 || h.finalPoly[i].c1 != h.finalValue.c1) {
                    revert FinalLayerNotConstant(i);
                }
            }
        }
    }

    function challenges(Head memory h, F.Fp2[] memory ood, Shape memory sh)
        internal
        pure
        returns (Challenges memory ch)
    {
        bytes32 state;
        (ch.z, state) = mainCheckpoint(h, ood, sh);
        bytes32 seed;
        (ch.deepCoeffs, ch.consIdx, seed) = mainResume(state, h, sh);
        (ch.betas, ch.friIdx) = friChallenges(h, sh, seed);
        ch.baseOmega = domainRoot(sh);
    }

    // digestBytes zero means 32. A zero-width read would mask every digest.
    function _dw(Shape memory sh) private pure returns (uint256) {
        return sh.digestBytes == 0 ? 32 : sh.digestBytes;
    }

    function _rx(Shape memory sh) private pure returns (uint256) {
        return sh.friRadix == 0 ? 2 : sh.friRadix;
    }

    // The nonce region sits where format 5 carries its one nonce, between the FRI and the base
    // sections: the query nonces in search order, then one per FRI layer when rounds grind. The
    // transcript takes them in protocol order instead, each layer's after its root and the query
    // nonces after the final layer. Both decoders read the region through these two functions.
    bool internal constant QUERY_NONCES_FIRST = true;

    function searchesOf(Shape memory sh) internal pure returns (uint256) {
        return sh.finalSearches <= 1 ? 1 : sh.finalSearches;
    }

    /// @notice Bytes in the nonce region for a proof with `rounds` FRI layers.
    function nonceBytes(Shape memory sh, uint256 rounds) internal pure returns (uint256) {
        return 8 * (searchesOf(sh) + (sh.roundGrindBits == 0 ? 0 : rounds));
    }

    function _readNonces(bytes memory p, R.Cursor memory c, Shape memory sh, Head memory h) private pure {
        uint256 rounds = sh.roundGrindBits == 0 ? 0 : h.friRoots.length;
        if (!QUERY_NONCES_FIRST) h.roundNonces = _readU64s(p, c, rounds);
        uint256 n = searchesOf(sh);
        if (n == 1) h.nonce = R.readU64(p, c);
        else h.finalNonces = _readU64s(p, c, n);
        if (QUERY_NONCES_FIRST) h.roundNonces = _readU64s(p, c, rounds);
    }

    function _readU64s(bytes memory p, R.Cursor memory c, uint256 n) private pure returns (uint64[] memory out) {
        out = new uint64[](n);
        for (uint256 i = 0; i < n; ++i) out[i] = R.readU64(p, c);
    }

    // GEN^((p - 1) >> logDomain)
    function domainRoot(Shape memory sh) internal pure returns (uint256) {
        return F.fpPow(GEN, (PMOD - 1) >> sh.logDomain);
    }

    // Chunk header: prefix up to the FRI queries, then nonce and base query count.
    function decodeHead(bytes memory p, Shape memory sh) internal pure returns (Head memory h, F.Fp2[] memory ood) {
        R.Cursor memory c = R.Cursor(0);
        _readRoundTwoPrefix(p, c, sh, h);
        h.traceRoot = R.readDigest(p, c, _dw(sh));
        h.compRoot = R.readDigest(p, c, _dw(sh));
        _readDeepRoot(p, c, sh, h);
        uint256 oodN = R.readU32(p, c);
        if (oodN != 2 * sh.traceWidth) revert OodFrameMismatch(oodN);
        ood = _readFp2Array(p, c, oodN);
        uint256 rc = R.readU32(p, c);
        h.friRoots = new bytes32[](rc);
        for (uint256 m = 0; m < rc; ++m) {
            h.friRoots[m] = R.readDigest(p, c, _dw(sh));
        }
        _readFinalLayer(p, c, h, sh);
        _tie(h, sh);
        R.readU32(p, c);
        _readNonces(p, c, sh, h);
        R.readU32(p, c);

        // claims arrive once at begin via decodeClaims, not in the head
        h.periodicZ = new F.Fp2[](0);
        if (!R.done(p, c)) revert HeadTrailingBytes();
    }

    // Sidecar claims P_j(z). The count must match the baked shape.
    function decodeClaims(bytes memory p, Shape memory sh) internal pure returns (F.Fp2[] memory periodicZ) {
        if (sh.nPeriodic == 0) {
            if (p.length != 0) revert HeadTrailingBytes();
            return new F.Fp2[](0);
        }
        R.Cursor memory c = R.Cursor(0);
        uint256 np = R.readU32(p, c);
        if (np != sh.nPeriodic) revert PeriodicCountMismatch(np);
        periodicZ = _readFp2Array(p, c, np);
        if (!R.done(p, c)) revert HeadTrailingBytes();
    }

    // Steps over the OOD frame. The session digest still covers it.
    function decodeHeadFri(bytes memory p, Shape memory sh) internal pure returns (Head memory h) {
        R.Cursor memory c = R.Cursor(0);
        _readRoundTwoPrefix(p, c, sh, h);
        h.traceRoot = R.readDigest(p, c, _dw(sh));
        h.compRoot = R.readDigest(p, c, _dw(sh));
        _readDeepRoot(p, c, sh, h);
        uint256 oodN = R.readU32(p, c);
        if (oodN != 2 * sh.traceWidth) revert OodFrameMismatch(oodN);
        c.off += oodN * 16;
        uint256 rc = R.readU32(p, c);
        h.friRoots = new bytes32[](rc);
        for (uint256 m = 0; m < rc; ++m) {
            h.friRoots[m] = R.readDigest(p, c, _dw(sh));
        }
        _readFinalLayer(p, c, h, sh);
        _tie(h, sh);
        R.readU32(p, c);
        _readNonces(p, c, sh, h);
        R.readU32(p, c);

        h.periodicZ = new F.Fp2[](0);
        if (!R.done(p, c)) revert HeadTrailingBytes();
    }

    // Main transcript through the OOD absorption. Sessions store the state once.
    function mainCheckpoint(Head memory h, F.Fp2[] memory ood, Shape memory sh)
        internal
        pure
        returns (F.Fp2 memory z, bytes32 state)
    {
        return mainCheckpoint(h, ood, sh, new uint256[](0));
    }

    /// @dev beta and gamma are the permutation challenges, zero for a single-round shape. A base
    ///      draw sits in c0 with c1 zero, so one evaluator serves both codecs.
    struct Checkpoint {
        F.Fp2 z;
        bytes32 state;
        F.Fp2 beta;
        F.Fp2 gamma;
    }

    /// @notice A two-round shape was read through the single-round checkpoint.
    error ChallengesWouldBeDiscarded();
    /// @notice The deployment declares a challenge count this transcript does not implement.
    error UnsupportedChallengeCount(uint256 nChal);

    /// @notice The single-round form. Refuses a two-round shape instead of dropping its challenges.
    function mainCheckpoint(Head memory h, F.Fp2[] memory ood, Shape memory sh, uint256[] memory publics)
        internal
        pure
        returns (F.Fp2 memory z, bytes32 state)
    {
        if (sh.nChal != 0) revert ChallengesWouldBeDiscarded();
        Checkpoint memory c = mainCheckpointFull(h, ood, sh, publics);
        return (c.z, c.state);
    }

    /// @notice The main transcript up to the OOD absorption.
    /// @dev Public words are absorbed first, before the trace root, so a proof is bound to them.
    /// @param publics Goldilocks limbs in absorb order, from PublicWords.
    function mainCheckpointFull(Head memory h, F.Fp2[] memory ood, Shape memory sh, uint256[] memory publics)
        internal
        pure
        returns (Checkpoint memory c)
    {
        (c,) = _mainCheckpoint(h, ood, sh, publics, false);
    }

    /// @notice {mainCheckpointFull} that also returns the composition coefficients.
    function mainCheckpointCoeffs(Head memory h, F.Fp2[] memory ood, Shape memory sh, uint256[] memory publics)
        internal
        pure
        returns (Checkpoint memory c, F.Fp2[] memory coeffs)
    {
        return _mainCheckpoint(h, ood, sh, publics, true);
    }

    function _mainCheckpoint(
        Head memory h,
        F.Fp2[] memory ood,
        Shape memory sh,
        uint256[] memory publics,
        bool keep
    ) private pure returns (Checkpoint memory c, F.Fp2[] memory coeffs) {
        TS.T memory t = TS.init("NONOS-STARK-EXT");
        TS.absorbFpArray(t, publics);
        TS.absorbDigest(t, h.traceRoot, _dw(sh));

        // round two: traceRoot, beta, gamma, permRoot, then the composition coefficients.
        // See docs/05-transcript.md before changing the order.
        if (sh.nChal != 0) {
            if (sh.nChal != 2) revert UnsupportedChallengeCount(sh.nChal);
            // in Fp2 the copy constraint's soundness is no longer capped by the 64-bit base field
            if (sh.extChallenges) {
                c.beta = TS.challengeFp2(t);
                c.gamma = TS.challengeFp2(t);
            } else {
                c.beta.c0 = TS.challengeFp(t);
                c.gamma.c0 = TS.challengeFp(t);
            }
            TS.absorbDigest(t, h.permRoot, _dw(sh));
        }

        // The composition coefficients: a query never reads them, the recomputing composer does.
        // In power form they are 1, a, a^2, ... for one draw a, in the same order.
        if (sh.powerCoeffs) {
            F.Fp2 memory a = TS.challengeFp2(t);
            if (keep) coeffs = TS.powers(a, sh.nCoeffs);
        } else if (keep) {
            coeffs = TS.challengeFp2Batch(t, sh.nCoeffs);
        } else {
            TS.skipChallengeFp2(t, sh.nCoeffs);
        }
        TS.absorbDigest(t, h.compRoot, _dw(sh));
        c.z = TS.challengeFp2(t);
        // The mask pair is opened as one Fp2 value N = M_c + X M_{c+1} in slot c, so the second
        // slot must be zero. A proof that opens the pair apart is refused here.
        if (sh.maskColumn != 0) {
            for (uint256 k = 0; k < 2; ++k) {
                F.Fp2 memory v = ood[k * sh.traceWidth + sh.maskColumn + 1];
                if (v.c0 != 0 || v.c1 != 0) revert MaskSlotNotZero(k);
            }
        }
        // batch absorb, same preimages as the per-element loop (TranscriptAgainstOracle.t.sol)
        TS.absorbFp2Array(t, ood);
        TS.absorbFp2Array(t, h.periodicZ);
        c.state = t.state;
    }

    /// @notice The DEEP coefficients alone, re-drawn from a stored checkpoint.
    function deepCoeffsFrom(bytes32 state, Shape memory sh) internal pure returns (F.Fp2[] memory) {
        TS.T memory t = TS.T(state);
        return _deepCoeffs(t, sh);
    }

    // Frame values, then the composition, then the periodic claims: independent draws, or in
    // power form 1, a, a^2, ... for one draw a.
    function _deepCoeffs(TS.T memory t, Shape memory sh) private pure returns (F.Fp2[] memory d) {
        d = sh.powerDeep ? TS.powers(TS.challengeFp2(t), nDeepCoeffs(sh)) : TS.challengeFp2Batch(t, nDeepCoeffs(sh));
        // With the mask pair opened as N = M_c + X M_{c+1}, the second column's coefficient is the
        // first's times X, so the two DEEP terms combine into one term on N.
        if (sh.maskColumn != 0) {
            for (uint256 k = 0; k < 2; ++k) {
                uint256 i = k * sh.traceWidth + sh.maskColumn;
                d[i + 1] = F.Fp2(mulmod(7, d[i].c1, F.P), d[i].c0);
            }
        }
    }

    /// @notice The rest of the main transcript from a checkpoint: DEEP coefficients and
    ///         consistency indices.
    /// @dev Coefficients are drawn before the indices, so batching queries per chunk is sound.
    function mainResume(bytes32 state, Head memory h, Shape memory sh)
        internal
        pure
        returns (F.Fp2[] memory deepCoeffs, uint256[] memory consIdx, bytes32 seed) // seed: format 5 only
    {
        TS.T memory t = TS.T(state);
        deepCoeffs = _deepCoeffs(t, sh);
        if (sh.format5) {
            TS.mix(t, 0x08, "");
            return (deepCoeffs, new uint256[](0), t.state);
        }
        // consistency indices are drawn after the DEEP root, which must be FRI's first root
        if (sh.nChal != 0 && h.deepRoot != h.friRoots[0]) revert DeepRootNotFriRoot();
        TS.absorbDigest(t, h.friRoots[0], _dw(sh));
        consIdx = new uint256[](sh.nq);
        for (uint256 i = 0; i < sh.nq; ++i) {
            consIdx[i] = TS.challengeIndex(t, 1 << sh.logDomain);
        }
    }

    /// The FRI transcript in full: betas, the grind check and the FRI indices. Cheap enough to
    /// derive in every FRI chunk.
    function friChallenges(Head memory h, Shape memory sh, bytes32 seed)
        internal
        pure
        returns (F.Fp2[] memory betas, uint256[] memory friIdx)
    {
        TS.T memory tf = TS.init("NONOS-STARK-FRI-EXT");
        if (sh.format5) TS.absorbDigest(tf, seed, _dw(sh));
        betas = new F.Fp2[](h.friRoots.length);
        for (uint256 m = 0; m < h.friRoots.length; ++m) {
            TS.absorbDigest(tf, h.friRoots[m], _dw(sh));
            // the round's nonce is checked and absorbed before its fold challenge is drawn
            if (sh.roundGrindBits != 0) TS.grindRound(tf, h.roundNonces[m], uint32(sh.roundGrindBits), m);
            betas[m] = TS.challengeFp2(tf);
        }
        // every final-layer cell is absorbed: the calldata decoder leaves it flat, the memory one
        // as cells, and either holds finalCount of them
        if (h.finalFlat.length != 0) {
            assert(h.finalFlat.length == 2 * h.finalCount);
            TS.absorbFpArray(tf, h.finalFlat);
        } else {
            assert(h.finalPoly.length == h.finalCount);
            TS.absorbFp2Array(tf, h.finalPoly);
        }
        // grind bits come from the shape, so the checked bound is the claimed one. A split grind
        // checks each nonce against the state the previous one left, so none can be searched ahead.
        uint256 searches = searchesOf(sh);
        if (searches == 1) {
            if (!TS.verifyPow(tf, h.nonce, uint32(sh.grindBits))) revert GrindRejected();
        } else {
            for (uint256 i = 0; i < searches; ++i) {
                if (!TS.verifyPow(tf, h.finalNonces[i], uint32(sh.grindBits))) revert FinalGrindRejected(i);
            }
        }
        friIdx = new uint256[](sh.nq);
        for (uint256 i = 0; i < sh.nq; ++i) {
            friIdx[i] = TS.challengeIndex(tf, 1 << sh.logDomain);
        }
    }

    /// Header walk that skips the OOD cell reads: roots, final layer, nonce and the two query
    /// offsets, for chunks that carry the OOD frame in the committed challenge blob.
    function decodeLite(bytes memory p, Shape memory sh) internal pure returns (Head memory h) {
        R.Cursor memory c = R.Cursor(0);
        _readRoundTwoPrefix(p, c, sh, h);
        h.traceRoot = R.readDigest(p, c, _dw(sh));
        h.compRoot = R.readDigest(p, c, _dw(sh));
        _readDeepRoot(p, c, sh, h);
        uint256 oodN = R.readU32(p, c);
        // Step over the frame, as decodeHeadFri does. Several decoders read this header, and
        // they agree on offsets only if every one of them is changed together with the format.
        c.off += oodN * 16;
        uint256 rc = R.readU32(p, c);
        h.friRoots = new bytes32[](rc);
        for (uint256 m = 0; m < rc; ++m) {
            h.friRoots[m] = R.readDigest(p, c, _dw(sh));
        }
        _readFinalLayer(p, c, h, sh);
        _tie(h, sh);
        R.readU32(p, c);
        h.friQOff = c.off;
        for (uint256 q = 0; q < sh.nq; ++q) {
            uint256 layers = R.readU32(p, c);
            for (uint256 m = 0; m < layers; ++m) {
                c.off += 16;
                R.skipPath(p, c, _dw(sh));
                c.off += 16;
                R.skipPath(p, c, _dw(sh));
            }
        }
        _readNonces(p, c, sh, h);
        R.readU32(p, c);
        h.baseQOff = c.off;
    }

    /// @notice Steps over n base query sections without verifying them.
    /// @dev Pass nPeriodic = 0 to walk the artifact file and the deployed shape to walk a chunk.
    function skipBase(bytes memory p, R.Cursor memory c, uint256 n, Shape memory sh) internal pure {
        for (uint256 q = 0; q < n; ++q) {
            if (!sh.format5) {
                c.off += 16;
                R.skipPath(p, c, _dw(sh));
            }
            uint256 tw = R.readU32(p, c);
            c.off += tw * 8;
            R.skipPath(p, c, _dw(sh));
            c.off += 16;
            R.skipPath(p, c, _dw(sh));
            // in a chunk the sidecar row closes each section
            if (sh.nPeriodic != 0) {
                c.off += sh.nPeriodic * 8;
                R.skipPath(p, c, _dw(sh));
            }
            // then the round-two path, or every later query is read at the wrong offset
            if (sh.nChal != 0) R.skipPath(p, c, _dw(sh));
        }
    }

    /// @notice Start offsets of every section, walked with the decoder's own readers. `ends` is the
    ///         byte after the last section and must equal the proof length.
    function sectionsOf(bytes memory p, Shape memory sh)
        internal
        pure
        returns (
            uint256[] memory base,
            uint256[] memory rows,
            uint256[] memory perms,
            uint256[] memory fri,
            uint256 sidecarOff,
            uint256 ends
        )
    {
        (Head memory h,) = decode(p, sh);
        uint256 n = sh.nq;
        base = new uint256[](n + 1);
        rows = new uint256[](n + 1);
        perms = new uint256[](n + 1);
        fri = new uint256[](n + 1);

        // the file is five blocks: FRI sections, base sections, claims, sidecar rows, round-two paths
        R.Cursor memory c = R.Cursor(h.friQOff);
        for (uint256 q = 0; q < n; ++q) {
            fri[q] = c.off;
            skipFri(p, c, 1, sh);
        }
        fri[n] = c.off;

        c.off = h.baseQOff;
        BaseQ memory b;
        for (uint256 q = 0; q < n; ++q) {
            base[q] = c.off;
            b = _readBase(p, c, sh);
        }
        base[n] = c.off;

        // the claims travel once, between the base sections and the rows: a u32 count, then
        // nPeriodic Fp2 values of 16 bytes
        sidecarOff = c.off;
        c.off += 4 + sh.nPeriodic * 16;

        for (uint256 q = 0; q < n; ++q) {
            rows[q] = c.off;
            _readPeriodic(p, c, sh, b);
        }
        rows[n] = c.off;

        for (uint256 q = 0; q < n; ++q) {
            perms[q] = c.off;
            _readPerm(p, c, sh, b);
        }
        perms[n] = c.off;
        ends = p.length;
    }

    /// @dev Steps the FRI cursor past n queries. Round one writes two leaves and two paths, round
    ///      two one leaf per fold group and one path.
    function skipFri(bytes memory p, R.Cursor memory c, uint256 n, Shape memory sh) internal pure {
        for (uint256 q = 0; q < n; ++q) {
            uint256 layers = R.readU32(p, c);
            for (uint256 m = 0; m < layers; ++m) {
                if (sh.nChal == 0) {
                    c.off += 16;
                    R.skipPath(p, c, _dw(sh));
                    c.off += 16;
                    R.skipPath(p, c, _dw(sh));
                } else {
                    // the fold group, in one leaf: two values at radix two, four at radix four.
                    c.off += 16 * _rx(sh);
                    R.skipPath(p, c, _dw(sh));
                }
            }
        }
    }

    function _readBase(bytes memory p, R.Cursor memory c, Shape memory sh) private pure returns (BaseQ memory b) {
        if (!sh.format5) {
            b.deepVal = _fp2(R.readFp2(p, c));
            if (sh.nChal != 0) {
                for (uint256 k = 0; k < 3; ++k) b.deepOthers[k] = _fp2(R.readFp2(p, c));
            }
            b.deepPath = R.readPath(p, c, _dw(sh));
        }
        uint256 tw = R.readU32(p, c);
        // the DEEP sum reads traceWidth cells of this row by index
        if (tw != sh.traceWidth) revert TraceRowWidthMismatch(tw);
        b.traceOff = c.off;
        b.traceRow = R.readFpArray(p, c, tw);
        b.tracePath = R.readPath(p, c, _dw(sh));
        b.comp = _fp2(R.readFp2(p, c));
        b.compPath = R.readPath(p, c, _dw(sh));
    }

    /// @dev The query's periodic row, when the shape has one. Its width is fixed by the deployment.
    function _readPeriodic(bytes memory p, R.Cursor memory c, Shape memory sh, BaseQ memory b) private pure {
        if (sh.nPeriodic == 0) return;
        b.periodicOff = c.off;
        c.off += sh.nPeriodic * 8;
        b.periodicPath = R.readPath(p, c, _dw(sh));
    }

    /// @dev The round-two path for this query.
    function _readPerm(bytes memory p, R.Cursor memory c, Shape memory sh, BaseQ memory b) private pure {
        if (sh.nChal == 0) return;
        b.permPath = R.readPath(p, c, _dw(sh));
    }

    /// @dev The DEEP identity at one query. The periodic claims enter as the scalar computed from
    ///      the transcript-bound claims.
    function _checkDeep(
        bytes memory p,
        BaseQ memory b,
        Challenges memory ch,
        F.Fp2[] memory ood,
        ProductionDeepQuery.Ctx memory ctx,
        uint256 q
    ) private pure {
        F.Fp2 memory got = ProductionDeepQuery.combineWithScalarRaw(
            b.traceRow, b.comp, ood, ch.deepCoeffs, ctx, p, b.periodicOff, ctx.preSummedClaims
        );
        if (got.c0 != b.deepVal.c0 || got.c1 != b.deepVal.c1) {
            revert DeepMismatch(q, got.c0, got.c1, b.deepVal.c0, b.deepVal.c1);
        }
    }

    /// @dev The row is committed in halves: [0, regionWidth) under traceRoot and the rest under
    ///      permRoot. The split comes from the deployment, never from the proof.
    function _checkTrace(
        bytes memory p,
        BaseQ memory b,
        Head memory h,
        Shape memory sh,
        uint256 idx,
        uint256 q
    ) private pure {
        if (sh.nChal == 0) {
            bytes32 whole = MK.hashLeafWideRaw(p, b.traceOff, b.traceRow.length);
            if (!MK.verifyLeaf(h.traceRoot, idx, whole, b.tracePath, _dw(sh))) revert TraceAuthFailed(q);
            return;
        }
        uint256 w = b.traceRow.length;
        uint256 rw = sh.regionWidth;
        if (rw >= w) revert RegionWidthMismatch(rw, w);

        // Both halves hash straight from the wire, with no copy into a sub-array and no
        // re-encoding of decoded values.
        bytes32 lo = MK.hashLeafWideRaw(p, b.traceOff, rw);
        if (!MK.verifyLeaf(h.traceRoot, idx, lo, b.tracePath, _dw(sh))) revert TraceAuthFailed(q);

        bytes32 hi = MK.hashLeafWideRaw(p, b.traceOff + rw * 8, w - rw);
        if (!MK.verifyLeaf(h.permRoot, idx, hi, b.permPath, _dw(sh))) revert CopyCommitMismatch(q);
    }

    /// Authenticates every opening of a base query: trace (both halves), DEEP, composition and
    /// the periodic row.
    function _checkAuths(
        bytes memory p,
        BaseQ memory b,
        Head memory h,
        Shape memory sh,
        uint256 idx,
        uint256 q
    ) private pure {
        _checkTrace(p, b, h, sh, idx, q);
        // the DEEP value needs no path here: it is FRI's own layer-zero opening, authenticated by verifyFri
        if (!MK.verifyPathExt(h.compRoot, idx, b.comp, b.compPath, _dw(sh))) revert CompAuthFailed(q);
        // the periodic row opens against the root fixed at deployment
        if (sh.nPeriodic != 0) {
            bytes32 leaf = MK.hashLeafWidePeriodicRaw(p, b.periodicOff, sh.nPeriodic);
            if (!MK.verifyLeaf(sh.periodicRoot, idx, leaf, b.periodicPath, _dw(sh))) revert PeriodicAuthFailed(q);
        }
    }

    /// Verifies base query `q`: reads its sections, authenticates every opening, then checks
    /// the DEEP identity at the query's point.
    function verifyBase(
        bytes memory p,
        R.Cursor memory c,
        Head memory h,
        Challenges memory ch,
        F.Fp2[] memory ood,
        ProductionDeepQuery.Ctx memory ctx,
        Shape memory sh,
        uint256 q
    ) internal pure {
        BaseQ memory b = _readBase(p, c, sh);
        _readPeriodic(p, c, sh, b);
        _readPerm(p, c, sh, b);
        uint256 idx = ch.friIdx[q];
        b.deepVal = ch.deepVals[q];
        // x = coset_shift * omega^idx: the shift comes from the shape, the root from the field.
        ctx.x = F.fpMul(sh.cosetShift, F.fpPow(ch.baseOmega, idx));
        // authenticate every opening before using its values
        _checkAuths(p, b, h, sh, idx, q);
        _checkDeep(p, b, ch, ood, ctx, q);
    }

    // One query's fold state, carried from layer to layer.
    struct QuadSt {
        F.Fp2 carry;
        uint256 prevI;
        uint256 ix; // 1/x0 at this layer
        uint256 izeta; // zeta^-1, zeta = omega^(n/4)
        uint256 pos;
    }

    /// @notice Radix-4 FRI for one query:
    ///   quarter = (n >> 2m) >> 2, i = pos mod quarter, x0 = (s w^i)^(4^m), x1 = x0 zeta, zeta^4 = 1
    ///   out = fold(fold(v0, v2, x0, b), fold(v1, v3, x1, b), x0^2, b^2)
    /// @dev One inversion per query: layer m+1's 1/x0 is layer m's to the fourth times a power of zeta.
    function _verifyFriQuad(
        bytes memory p,
        R.Cursor memory c,
        Head memory h,
        Challenges memory ch,
        Shape memory sh,
        uint256 q
    ) private pure {
        uint256 layers = R.readU32(p, c);
        if (layers != h.friRoots.length) revert FoldChaseFailed(q);
        uint256 n = 1 << sh.logDomain;
        uint256 pos = ch.friIdx[q];
        QuadSt memory st;
        st.pos = pos;
        st.ix = F.fpInv(F.fpMul(ProductionAir.COSET_SHIFT, F.fpPow(ch.baseOmega, pos % (n >> 2))));
        uint256 z = F.fpPow(ch.baseOmega, n >> 2);
        st.izeta = mulmod(mulmod(z, z, PMOD), z, PMOD);
        for (uint256 m = 0; m < layers; ++m) {
            _quadLayer(p, c, h, ch, sh, q, m, st);
        }
        F.Fp2 memory expect = sh.finalAsCoefficients
            ? ProductionAir.evalFinal(h.finalPoly, ProductionAir.xFinal(ch.baseOmega, pos, n, 2 * layers))
            : h.finalPoly[0];
        if (!_eqFp2(st.carry, expect)) revert FoldChaseFailed(q);
    }

    function _quadLayer(
        bytes memory p,
        R.Cursor memory c,
        Head memory h,
        Challenges memory ch,
        Shape memory sh,
        uint256 q,
        uint256 m,
        QuadSt memory st
    ) private pure {
        uint256 quarter = ((1 << sh.logDomain) >> (2 * m)) >> 2;
        F.Fp2[4] memory v = _readQuad(p, c, h.friRoots[m], st.pos % quarter, sh, q, m);
        if (m == 0) {
            // copied by field: the caller releases this query's memory, the cell outlives it
            F.Fp2 memory d = v[st.pos / quarter];
            ch.deepVals[q].c0 = d.c0;
            ch.deepVals[q].c1 = d.c1;
        }
        if (m > 0) {
            uint256 k = st.prevI / quarter;
            if (!_eqFp2(st.carry, v[k % 4])) revert FoldChaseFailed(q);
            _ixStep(st, k);
        }
        st.carry = _quadFold(v, ch.betas[m], st.ix, mulmod(st.ix, st.izeta, PMOD));
        st.prevI = st.pos % quarter;
    }

    // Layer m's index is layer m+1's plus k quarters, so 1/x0' = (1/x0)^4 zeta^k, and zeta^k = (zeta^-1)^(4 - k).
    function _ixStep(QuadSt memory st, uint256 k) private pure {
        uint256 ix = mulmod(st.ix, st.ix, PMOD);
        ix = mulmod(ix, ix, PMOD);
        if (k != 0) for (uint256 t = k; t < 4; ++t) ix = mulmod(ix, st.izeta, PMOD);
        st.ix = ix;
    }

    /// @dev Reads the four values at quad index i and checks their path.
    function _readQuad(
        bytes memory p,
        R.Cursor memory c,
        bytes32 root,
        uint256 i,
        Shape memory sh,
        uint256 q,
        uint256 m
    ) private pure returns (F.Fp2[4] memory v) {
        {
            F.Fp2[] memory a = _readFp2Array(p, c, 4);
            v[0] = a[0];
            v[1] = a[1];
            v[2] = a[2];
            v[3] = a[3];
        }
        uint256 w = _dw(sh);
        bytes32 leaf = MK.trunc(MK.hashLeafQuad(v[0], v[1], v[2], v[3]), w);
        if (!_pathInPlace(p, c, root, i, leaf, w)) revert LayerAuthFailed(q, m);
    }

    /// @dev StarkMerkle._fold over siblings read in place. The index must be exhausted and the
    ///      node must equal the root.
    function _pathInPlace(bytes memory p, R.Cursor memory c, bytes32 root, uint256 index, bytes32 leaf, uint256 w)
        private
        pure
        returns (bool ok)
    {
        uint256 k = R.readU32(p, c);
        uint256 o = c.off;
        if (o + k * w > p.length) return false;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, "NONOS-STARK-MERKLE-NODE")
            let src := add(add(p, 0x20), o)
            let node := leaf
            let idx := index
            let rightAt := add(ptr, add(23, w))
            let len := add(23, mul(2, w))
            let mask := shl(mul(8, sub(32, w)), not(0))
            for { let j := 0 } lt(j, k) { j := add(j, 1) } {
                let sib := and(mload(add(src, mul(j, w))), mask)
                switch and(idx, 1)
                case 0 {
                    mstore(add(ptr, 23), node)
                    mstore(rightAt, sib)
                }
                default {
                    mstore(add(ptr, 23), sib)
                    mstore(rightAt, node)
                }
                node := and(keccak256(ptr, len), mask)
                idx := shr(1, idx)
            }
            ok := and(iszero(idx), eq(node, root))
        }
        c.off = o + k * w;
    }

    /// @dev friFoldQuad in local words: two radix-2 folds under beta, one under beta^2 at x^2.
    function _quadFold(F.Fp2[4] memory v, F.Fp2 memory beta, uint256 ix0, uint256 ix1)
        private
        pure
        returns (F.Fp2 memory out)
    {
        (uint256 u0, uint256 u1) = _fold2Raw(v[0], v[2], beta.c0, beta.c1, ix0);
        (uint256 w0, uint256 w1) = _fold2Raw(v[1], v[3], beta.c0, beta.c1, ix1);
        (uint256 b0, uint256 b1) = _sqFp2(beta.c0, beta.c1);
        out = F.Fp2(0, 0);
        (out.c0, out.c1) = _fold2Raw(F.Fp2(u0, u1), F.Fp2(w0, w1), b0, b1, mulmod(ix0, ix0, 0xFFFFFFFF00000001));
    }

    /// @dev (a + b)/2 + beta (a - b)/(2x) in local words, X^2 = 7. 9223372034707292161 is 1/2.
    ///      Inputs are canonical, so P - b cannot underflow.
    function _fold2Raw(F.Fp2 memory a, F.Fp2 memory b, uint256 be0, uint256 be1, uint256 invx)
        private
        pure
        returns (uint256 r0, uint256 r1)
    {
        uint256 s = mulmod(9223372034707292161, invx, 0xFFFFFFFF00000001);
        uint256 e0 = mulmod(addmod(a.c0, b.c0, 0xFFFFFFFF00000001), 9223372034707292161, 0xFFFFFFFF00000001);
        uint256 e1 = mulmod(addmod(a.c1, b.c1, 0xFFFFFFFF00000001), 9223372034707292161, 0xFFFFFFFF00000001);
        uint256 o0 = mulmod(addmod(a.c0, 0xFFFFFFFF00000001 - b.c0, 0xFFFFFFFF00000001), s, 0xFFFFFFFF00000001);
        uint256 o1 = mulmod(addmod(a.c1, 0xFFFFFFFF00000001 - b.c1, 0xFFFFFFFF00000001), s, 0xFFFFFFFF00000001);
        r0 = addmod(
            e0,
            addmod(mulmod(be0, o0, 0xFFFFFFFF00000001), mulmod(7, mulmod(be1, o1, 0xFFFFFFFF00000001), 0xFFFFFFFF00000001), 0xFFFFFFFF00000001),
            0xFFFFFFFF00000001
        );
        r1 = addmod(
            e1,
            addmod(mulmod(be0, o1, 0xFFFFFFFF00000001), mulmod(be1, o0, 0xFFFFFFFF00000001), 0xFFFFFFFF00000001),
            0xFFFFFFFF00000001
        );
    }

    /// Squares `a0 + a1*X` in Fp2.
    function _sqFp2(uint256 a0, uint256 a1) private pure returns (uint256 r0, uint256 r1) {
        r0 = addmod(mulmod(a0, a0, 0xFFFFFFFF00000001), mulmod(7, mulmod(a1, a1, 0xFFFFFFFF00000001), 0xFFFFFFFF00000001), 0xFFFFFFFF00000001);
        r1 = mulmod(2, mulmod(a0, a1, 0xFFFFFFFF00000001), 0xFFFFFFFF00000001);
    }

    function _eqFp2(F.Fp2 memory a, F.Fp2 memory b) private pure returns (bool) {
        return a.c0 == b.c0 && a.c1 == b.c1;
    }

    /// Verifies FRI query `q` at radix four, recording its DEEP value for the base query.
    function verifyFri(
        bytes memory p,
        R.Cursor memory c,
        Head memory h,
        Challenges memory ch,
        Shape memory sh,
        uint256 q
    ) internal pure {
        _verifyFriQuad(p, c, h, ch, sh, q);
    }
}
