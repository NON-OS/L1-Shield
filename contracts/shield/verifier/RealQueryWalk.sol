// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StarkFieldExt as F} from "./StarkFieldExt.sol";
import {GoldilocksCore as C} from "./GoldilocksCore.sol";
import {ProductionAir} from "./ProductionAir.sol";
import {StarkMerkle as MK} from "./StarkMerkle.sol";
import {RealQueryVerify as V} from "./RealQueryVerify.sol";

/// @title RealQueryWalk
/// @notice The verifier's per-query checks, reading the proof straight from calldata: one radix-4
///         FRI query, and one base query with its DEEP identity.
/// @dev Same wire format and rejections as the reference twin, test/shield/reference/RealQueryWalkRef.sol.
///      No proof section is copied to memory. Revert data is written at 0x00, over the free pointer
///      and zero slot when long, immediately before `revert`.
library RealQueryWalk {
    uint256 internal constant P = 0xFFFFFFFF00000001;

    // Selectors of the errors this walk raises. Their signatures are declared in RealQueryVerify
    // and StarkProofReader, and test/shield/yul/RealQueryWalkDiff.t.sol pins each value.
    uint256 internal constant SEL_OUT_OF_BOUNDS = 0xb4120f14; // OutOfBounds()
    uint256 internal constant SEL_NON_CANONICAL = 0x459d1ca5; // NonCanonicalFp()
    uint256 internal constant SEL_LAYER_AUTH = 0x5b4e7e79; // LayerAuthFailed(uint256,uint256)
    uint256 internal constant SEL_FOLD_CHASE = 0xa66f022d; // FoldChaseFailed(uint256)
    uint256 internal constant SEL_ROW_WIDTH = 0x288103ee; // TraceRowWidthMismatch(uint256)
    uint256 internal constant SEL_REGION_WIDTH = 0xcad7b59a; // RegionWidthMismatch(uint256,uint256)
    uint256 internal constant SEL_TRACE_AUTH = 0xff048298; // TraceAuthFailed(uint256)
    uint256 internal constant SEL_COPY_COMMIT = 0x05d8a812; // CopyCommitMismatch(uint256)
    uint256 internal constant SEL_COMP_AUTH = 0xec79543f; // CompAuthFailed(uint256)
    uint256 internal constant SEL_PERIODIC_AUTH = 0x582fd29f; // PeriodicAuthFailed(uint256)
    uint256 internal constant SEL_PERIODIC_LIMB = 0x0f16c6ba; // NonCanonicalPeriodicLimb()
    uint256 internal constant SEL_DEEP_MISMATCH = 0xff0bd45f; // DeepMismatch(uint256,uint256,uint256,uint256,uint256)

    /// @dev "NONOS-STARK-MERKLE-LEAF-QUAD", 28 bytes, left-aligned in a word.
    bytes32 internal constant DOM_QUAD = "NONOS-STARK-MERKLE-LEAF-QUAD";
    uint256 internal constant DOM_QUAD_LEN = 28;
    /// @dev "NONOS-STARK-MERKLE-NODE", 23 bytes, left-aligned in a word.
    bytes32 internal constant DOM_NODE = "NONOS-STARK-MERKLE-NODE";
    uint256 internal constant DOM_NODE_LEN = 23;

    /// @dev A fold group on the wire: four Fp2 values, eight 8-byte limbs, c0 then c1 per value.
    uint256 internal constant QUAD_BYTES = 64;
    uint256 internal constant LIMB_BYTES = 8;
    uint256 internal constant U32_BYTES = 4;
    /// @dev 1/2 mod P.
    uint256 internal constant HALF = 0x7FFFFFFF80000001;
    /// @dev Panic(uint256) and the division-by-zero code Solidity raises for `x % 0`.
    uint256 internal constant PANIC_SELECTOR = 0x4e487b71;
    uint256 internal constant PANIC_DIV_ZERO = 0x12;

    // One FRI query's scratch, claimed at the free pointer for the query and released with it.
    //   V_AT      eight words, the fold group's limbs in wire order v0.c0 v0.c1 .. v3.c1
    //   PRE_AT    a hash preimage: domain tag then data, at most 28 + 64 bytes for a leaf and
    //             23 + 2 * 32 for a node, so 0x80 bytes suffice
    //   ST_*      the loop's state and constants, one word each. They live here and not on the
    //             stack because the legacy code generator reaches only sixteen slots deep.
    uint256 internal constant V_AT = 0x000;
    uint256 internal constant PRE_AT = 0x100;
    uint256 internal constant LEFT_AT = 0x117; // PRE_AT + DOM_NODE_LEN: a node's left child
    uint256 internal constant ST_OFF = 0x180; // cursor into p
    uint256 internal constant ST_IX = 0x1a0; // 1/x0 at the current layer
    uint256 internal constant ST_IZETA = 0x1c0; // zeta^-1
    uint256 internal constant ST_C0 = 0x1e0; // the previous layer's fold, c0
    uint256 internal constant ST_C1 = 0x200; // and c1
    uint256 internal constant ST_PREV = 0x220; // the previous layer's group index
    uint256 internal constant ST_D0 = 0x240; // layer zero's value at pos, c0
    uint256 internal constant ST_D1 = 0x260; // and c1
    uint256 internal constant ST_POS = 0x280;
    uint256 internal constant ST_Q = 0x2a0;
    uint256 internal constant ST_LOGN = 0x2c0;
    uint256 internal constant ST_W = 0x2e0; // digest bytes
    uint256 internal constant ST_MASK = 0x300; // the high w bytes set
    uint256 internal constant ST_ROOTS = 0x320; // memory pointer to roots
    uint256 internal constant ST_BETAS = 0x340; // memory pointer to betas
    uint256 internal constant ST_BASE = 0x360; // p.offset
    uint256 internal constant ST_LEN = 0x380; // p.length
    uint256 internal constant SCRATCH_BYTES = 0x3a0;

    /// @notice What one FRI query needs from the transcript and the head.
    struct Fri {
        bytes32[] roots; // one per layer, left-aligned, masked to w
        F.Fp2[] betas; // one per layer
        uint256[] finalFlat; // c0, c1 per coefficient
        uint256 omega; // the layer-zero domain generator
        uint256 logDomain;
        uint256 w; // digest bytes, 24 or 32
        bool finalAsCoefficients;
    }

    /// @notice Verifies FRI query `q` at position `pos`, starting at p[off].
    /// @return end The offset just past the query.
    /// @return d0 The layer-zero value at `pos`, c0: the DEEP value the base query checks.
    /// @return d1 Its c1.
    function friQuery(bytes calldata p, uint256 off, Fri memory f, uint256 pos, uint256 q)
        internal
        pure
        returns (uint256 end, uint256 d0, uint256 d1)
    {
        uint256 layers = _u32(p, off);
        off += U32_BYTES;
        if (layers != f.roots.length) _revert1(SEL_FOLD_CHASE, q);
        uint256 n = uint256(1) << f.logDomain;
        // 1/x0 at layer zero, and zeta^-1 = zeta^3 for zeta = omega^(n/4), a fourth root of unity
        uint256 ix = C.inv(C.mul(ProductionAir.COSET_SHIFT, C.pow(f.omega, pos % (n >> 2))));
        uint256 izeta = C.pow(f.omega, 3 * (n >> 2));
        uint256[2] memory carry;
        (end, d0, d1) = _layers(p, off, f, pos, q, [ix, izeta, layers], carry);
        uint256[2] memory expect;
        if (f.finalAsCoefficients) {
            uint256 x = ProductionAir.xFinal(f.omega, pos, n, 2 * layers);
            (expect[0], expect[1]) = _horner(f.finalFlat, x);
        } else {
            expect[0] = f.finalFlat[0];
            expect[1] = f.finalFlat[1];
        }
        if (carry[0] != expect[0] || carry[1] != expect[1]) _revert1(SEL_FOLD_CHASE, q);
    }

    // The layer loop. `k` carries 1/x0, zeta^-1 and the layer count in, and `carry` takes the last
    // layer's fold out.
    function _layers(
        bytes calldata p,
        uint256 off,
        Fri memory f,
        uint256 pos,
        uint256 q,
        uint256[3] memory k,
        uint256[2] memory carry
    ) private pure returns (uint256 end, uint256 d0, uint256 d1) {
        bytes32[] memory roots = f.roots;
        F.Fp2[] memory betas = f.betas;
        uint256 logDomain = f.logDomain;
        uint256 w = f.w;
        assembly {
            // Scratch for the query at the free pointer, laid out per V_AT, PRE_AT and ST_*. The
            // free pointer is moved past it for the loop and put back after.
            let s := mload(0x40)
            mstore(0x40, add(s, SCRATCH_BYTES))
            mstore(add(s, ST_OFF), off)
            mstore(add(s, ST_IX), mload(k))
            mstore(add(s, ST_IZETA), mload(add(k, 0x20)))
            mstore(add(s, ST_C0), 0)
            mstore(add(s, ST_C1), 0)
            mstore(add(s, ST_PREV), 0)
            mstore(add(s, ST_D0), 0)
            mstore(add(s, ST_D1), 0)
            mstore(add(s, ST_POS), pos)
            mstore(add(s, ST_Q), q)
            mstore(add(s, ST_LOGN), logDomain)
            mstore(add(s, ST_W), w)
            mstore(add(s, ST_MASK), shl(mul(8, sub(32, w)), not(0)))
            mstore(add(s, ST_ROOTS), roots)
            mstore(add(s, ST_BETAS), betas)
            mstore(add(s, ST_BASE), p.offset)
            mstore(add(s, ST_LEN), p.length)
            let layers := mload(add(k, 0x40))
            for { let m := 0 } lt(m, layers) { m := add(m, 1) } { _layer(s, m) }
            mstore(carry, mload(add(s, ST_C0)))
            mstore(add(carry, 0x20), mload(add(s, ST_C1)))
            end := mload(add(s, ST_OFF))
            d0 := mload(add(s, ST_D0))
            d1 := mload(add(s, ST_D1))
            mstore(0x40, s)

            // Layer m: read and authenticate its group, check the previous fold landed in it, fold.
            function _layer(sc, m) {
                let quarter := shr(2, shr(mul(2, m), shl(mload(add(sc, ST_LOGN)), 1)))
                // a remainder by zero is a Panic(0x12) in the Solidity form
                if iszero(quarter) { _panic(PANIC_DIV_ZERO) }
                let ps := mload(add(sc, ST_POS))
                let i := mod(ps, quarter)
                let o := mload(add(sc, ST_OFF))
                // Invariant: once _read returns, s + V_AT holds this layer's eight limbs, canonical.
                _read(sc, o)
                let leaf := and(_leafQuad(sc, o), mload(add(sc, ST_MASK)))
                let root := mload(add(mload(add(sc, ST_ROOTS)), mul(add(m, 1), 0x20)))
                if iszero(_path(sc, add(o, QUAD_BYTES), root, i, leaf)) {
                    _revert2(SEL_LAYER_AUTH, mload(add(sc, ST_Q)), m)
                }
                switch m
                case 0 {
                    // position pos sits in slot pos / quarter of its layer-zero group
                    let slot := add(sc, mul(div(ps, quarter), 0x40))
                    mstore(add(sc, ST_D0), mload(slot))
                    mstore(add(sc, ST_D1), mload(add(slot, 0x20)))
                }
                default {
                    // the previous layer's output is the value in slot (prevI / quarter) of this group
                    let kk := div(mload(add(sc, ST_PREV)), quarter)
                    let slot := add(sc, mul(mod(kk, 4), 0x40))
                    if or(
                        iszero(eq(mload(slot), mload(add(sc, ST_C0)))),
                        iszero(eq(mload(add(slot, 0x20)), mload(add(sc, ST_C1))))
                    ) { _revert1(SEL_FOLD_CHASE, mload(add(sc, ST_Q))) }
                    // layer m-1's index is layer m's plus kk quarters, so
                    // 1/x0 <- (1/x0)^4 zeta^kk, and zeta^kk = (zeta^-1)^(4 - kk)
                    let ix := mload(add(sc, ST_IX))
                    ix := mulmod(ix, ix, P)
                    ix := mulmod(ix, ix, P)
                    if kk {
                        let iz := mload(add(sc, ST_IZETA))
                        for { let t := kk } lt(t, 4) { t := add(t, 1) } { ix := mulmod(ix, iz, P) }
                    }
                    mstore(add(sc, ST_IX), ix)
                }
                let beta := mload(add(mload(add(sc, ST_BETAS)), mul(add(m, 1), 0x20)))
                let r0, r1 := _quadFold(sc, mload(beta), mload(add(beta, 0x20)))
                mstore(add(sc, ST_C0), r0)
                mstore(add(sc, ST_C1), r1)
                mstore(add(sc, ST_PREV), i)
            }

            // The fold group at p[o..o+64] into sc + V_AT as eight byte-reversed limbs. Reverts
            // OutOfBounds past the end, then NonCanonicalFp on any limb >= P, in that order.
            function _read(sc, o) {
                if gt(add(o, QUAD_BYTES), mload(add(sc, ST_LEN))) { _revert0(SEL_OUT_OF_BOUNDS) }
                let src := add(mload(add(sc, ST_BASE)), o)
                let lo := calldataload(src)
                let hi := calldataload(add(src, 0x20))
                let bad := _put(sc, 0x00, shr(192, lo))
                bad := or(bad, _put(sc, 0x20, shr(128, lo)))
                bad := or(bad, _put(sc, 0x40, shr(64, lo)))
                bad := or(bad, _put(sc, 0x60, lo))
                bad := or(bad, _put(sc, 0x80, shr(192, hi)))
                bad := or(bad, _put(sc, 0xa0, shr(128, hi)))
                bad := or(bad, _put(sc, 0xc0, shr(64, hi)))
                bad := or(bad, _put(sc, 0xe0, hi))
                if bad { _revert0(SEL_NON_CANONICAL) }
            }

            // The low eight bytes of word, read little-endian, stored at sc + V_AT + at, and 1 if >= P.
            function _put(sc, at, word) -> bad {
                let v := _le(and(word, 0xFFFFFFFFFFFFFFFF))
                mstore(add(add(sc, V_AT), at), v)
                bad := iszero(lt(v, P))
            }

            // keccak256(DOM_QUAD || the 64 wire bytes at p[o]). The wire bytes are the preimage's
            // limb encoding, so they are copied, not re-encoded. Preimage at sc + PRE_AT.
            function _leafQuad(sc, o) -> h {
                let pre := add(sc, PRE_AT)
                mstore(pre, DOM_QUAD)
                calldatacopy(add(pre, DOM_QUAD_LEN), add(mload(add(sc, ST_BASE)), o), QUAD_BYTES)
                h := keccak256(pre, add(DOM_QUAD_LEN, QUAD_BYTES))
            }

            // A u32 count at p[o], then that many w-byte siblings, folded from leaf to root, and
            // the cursor moved past them. The count past the end reverts OutOfBounds, and siblings
            // past the end return not-ok.
            // Node preimage at sc + PRE_AT: DOM_NODE, left child at LEFT_AT, right child w bytes on.
            // Invariant: node and every sibling are masked to w bytes, so a child's store leaves
            // zeros where the other child's bytes begin or end.
            function _path(sc, o, root, idx, node) -> ok {
                let wd := mload(add(sc, ST_W))
                let src := 0
                let fin := 0
                {
                    let len := mload(add(sc, ST_LEN))
                    if gt(add(o, U32_BYTES), len) { _revert0(SEL_OUT_OF_BOUNDS) }
                    let base := mload(add(sc, ST_BASE))
                    let cnt := _le32(shr(224, calldataload(add(base, o))))
                    o := add(o, U32_BYTES)
                    let last := add(o, mul(cnt, wd))
                    if gt(last, len) { leave }
                    mstore(add(sc, ST_OFF), last)
                    src := add(base, o)
                    fin := add(base, last)
                }
                mstore(add(sc, PRE_AT), DOM_NODE)
                let mk := mload(add(sc, ST_MASK))
                for {} lt(src, fin) { src := add(src, wd) } {
                    let sib := and(calldataload(src), mk)
                    switch and(idx, 1)
                    case 0 {
                        mstore(add(sc, LEFT_AT), node)
                        mstore(add(add(sc, LEFT_AT), wd), sib)
                    }
                    default {
                        mstore(add(sc, LEFT_AT), sib)
                        mstore(add(add(sc, LEFT_AT), wd), node)
                    }
                    node := and(keccak256(add(sc, PRE_AT), add(DOM_NODE_LEN, shl(1, wd))), mk)
                    idx := shr(1, idx)
                }
                ok := and(iszero(idx), eq(node, root))
            }

            // fold(fold(v0, v2, x0, b), fold(v1, v3, x1, b), x0^2, b^2), 1/x1 = (1/x0) zeta^-1,
            // over the limbs at sc + V_AT.
            function _quadFold(sc, b0, b1) -> r0, r1 {
                let ix0 := mload(add(sc, ST_IX))
                let u0, u1 := _fold2(mload(sc), mload(add(sc, 0x20)), mload(add(sc, 0x80)), mload(add(sc, 0xa0)), b0, b1, ix0)
                let w0, w1 := _fold2(
                    mload(add(sc, 0x40)),
                    mload(add(sc, 0x60)),
                    mload(add(sc, 0xc0)),
                    mload(add(sc, 0xe0)),
                    b0,
                    b1,
                    mulmod(ix0, mload(add(sc, ST_IZETA)), P)
                )
                // beta^2, as GoldilocksCore.sqr2
                let bb0 := addmod(mulmod(b0, b0, P), mulmod(7, mulmod(b1, b1, P), P), P)
                b1 := mulmod(2, mulmod(b0, b1, P), P)
                r0, r1 := _fold2(u0, u1, w0, w1, bb0, b1, mulmod(ix0, ix0, P))
            }

            // GoldilocksCore.fold2 on canonical inputs, where its range check cannot fire.
            function _fold2(a0, a1, b0, b1, be0, be1, invx) -> r0, r1 {
                invx := mulmod(HALF, invx, P)
                r0 := mulmod(addmod(a0, sub(P, b0), P), invx, P)
                r1 := mulmod(addmod(a1, sub(P, b1), P), invx, P)
                invx := addmod(mulmod(be0, r0, P), mulmod(7, mulmod(be1, r1, P), P), P)
                r1 := addmod(mulmod(be0, r1, P), mulmod(be1, r0, P), P)
                r0 := addmod(mulmod(addmod(a0, b0, P), HALF, P), invx, P)
                r1 := addmod(mulmod(addmod(a1, b1, P), HALF, P), r1, P)
            }

            function _le(x) -> r {
                x := or(shr(8, and(x, 0xFF00FF00FF00FF00)), shl(8, and(x, 0x00FF00FF00FF00FF)))
                x := or(shr(16, and(x, 0xFFFF0000FFFF0000)), shl(16, and(x, 0x0000FFFF0000FFFF)))
                r := or(shr(32, x), and(shl(32, x), 0xFFFFFFFF00000000))
            }

            function _le32(x) -> r {
                x := or(shr(8, and(x, 0xFF00FF00)), shl(8, and(x, 0x00FF00FF)))
                r := or(shr(16, x), and(shl(16, x), 0xFFFF0000))
            }

            // Revert data at 0x00: selector, then arguments. Nothing runs after it.
            function _revert0(sel) {
                mstore(0x00, shl(224, sel))
                revert(0x00, 0x04)
            }

            function _revert1(sel, a) {
                mstore(0x00, shl(224, sel))
                mstore(0x04, a)
                revert(0x00, 0x24)
            }

            function _revert2(sel, a, b) {
                mstore(0x00, shl(224, sel))
                mstore(0x04, a)
                mstore(0x24, b)
                revert(0x00, 0x44)
            }

            // Panic(uint256) with the given code, as Solidity raises it.
            function _panic(code) {
                mstore(0x00, shl(224, PANIC_SELECTOR))
                mstore(0x04, code)
                revert(0x00, 0x24)
            }
        }
    }

    // ------------------------------------------------------------------------------------ head

    uint256 internal constant FP2_BYTES = 16;
    uint256 internal constant U64_BYTES = 8;
    /// @dev Panic code for an out-of-range index, which an empty final layer's first cell raises.
    uint256 internal constant PANIC_INDEX = 0x32;

    /// @notice Decodes a format-5 head in place: prefix, frame, FRI roots, the final layer, then
    ///         the nonce region: the query nonces, and one per FRI layer when rounds grind.
    /// @dev Refuses what the memory decoder refuses, in the same order, except that a root count
    ///      whose roots cannot fit is refused with OutOfBounds before anything is allocated.
    ///      The final layer is returned flat in h.finalFlat and h.finalPoly is left empty.
    function readHead(bytes calldata p, V.Shape memory sh) internal pure returns (V.Head memory h, F.Fp2[] memory ood) {
        uint256 w = sh.digestBytes;
        uint256 o;
        (h.permRoot, o) = _digest(p, 0, w);
        uint256 rw = _u32(p, o);
        o += U32_BYTES;
        if (rw != sh.regionWidth) revert V.RegionWidthMismatch(rw, sh.regionWidth);
        (h.traceRoot, o) = _digest(p, o, w);
        (h.compRoot, o) = _digest(p, o, w);
        uint256 oodN = _u32(p, o);
        o += U32_BYTES;
        if (oodN != 2 * sh.traceWidth) revert V.OodFrameMismatch(oodN);
        (ood, o) = readFp2Array(p, o, oodN);
        o = _roots(p, o, w, h);
        o = _finalLayer(p, o, h, sh.finalAsCoefficients);
        o += U32_BYTES;
        _u32(p, o - U32_BYTES);
        o = _nonces(p, o, h, sh);
        _u32(p, o);
        o += U32_BYTES;
        h.periodicZ = new F.Fp2[](0);
        if (o != p.length) revert V.HeadTrailingBytes();
    }

    /// @notice The sidecar claims P_j(z): a u32 count that must be the deployment's, then the values.
    function readClaims(bytes calldata p, V.Shape memory sh) internal pure returns (F.Fp2[] memory periodicZ) {
        if (sh.nPeriodic == 0) {
            if (p.length != 0) revert V.HeadTrailingBytes();
            return new F.Fp2[](0);
        }
        uint256 np = _u32(p, 0);
        if (np != sh.nPeriodic) revert V.PeriodicCountMismatch(np);
        uint256 o;
        (periodicZ, o) = readFp2Array(p, U32_BYTES, np);
        if (o != p.length) revert V.HeadTrailingBytes();
    }

    function _digest(bytes calldata p, uint256 o, uint256 w) private pure returns (bytes32 d, uint256 next) {
        next = o + w;
        if (next > p.length) _revert0(SEL_OUT_OF_BOUNDS);
        assembly {
            d := and(calldataload(add(p.offset, o)), shl(shl(3, sub(32, w)), not(0)))
        }
    }

    function _limb(bytes calldata p, uint256 o) private pure returns (uint256 v) {
        assembly {
            v := shr(192, calldataload(add(p.offset, o)))
            v := or(shr(8, and(v, 0xFF00FF00FF00FF00)), shl(8, and(v, 0x00FF00FF00FF00FF)))
            v := or(shr(16, and(v, 0xFFFF0000FFFF0000)), shl(16, and(v, 0x0000FFFF0000FFFF)))
            v := or(shr(32, v), and(shl(32, v), 0xFFFFFFFF00000000))
        }
    }

    // A u32 count, then the roots.
    function _roots(bytes calldata p, uint256 o, uint256 w, V.Head memory h) private pure returns (uint256) {
        uint256 rc = _u32(p, o);
        o += U32_BYTES;
        if (o + rc * w > p.length) _revert0(SEL_OUT_OF_BOUNDS);
        h.friRoots = new bytes32[](rc);
        for (uint256 m = 0; m < rc; ++m) (h.friRoots[m], o) = _digest(p, o, w);
        return o;
    }

    // The nonce region in the order RealQueryVerify.QUERY_NONCES_FIRST fixes, as the memory
    // decoder reads it. One search fills h.nonce, several fill h.finalNonces.
    function _nonces(bytes calldata p, uint256 o, V.Head memory h, V.Shape memory sh) private pure returns (uint256) {
        uint256 rounds = sh.roundGrindBits == 0 ? 0 : h.friRoots.length;
        uint256 n = V.searchesOf(sh);
        if (o + (n + rounds) * U64_BYTES > p.length) _revert0(SEL_OUT_OF_BOUNDS);
        if (!V.QUERY_NONCES_FIRST) (h.roundNonces, o) = _u64s(p, o, rounds);
        if (n == 1) {
            h.nonce = uint64(_limb(p, o));
            o += U64_BYTES;
        } else {
            (h.finalNonces, o) = _u64s(p, o, n);
        }
        if (V.QUERY_NONCES_FIRST) (h.roundNonces, o) = _u64s(p, o, rounds);
        return o;
    }

    // n little-endian u64s at p[o..]. Bounds are the caller's.
    function _u64s(bytes calldata p, uint256 o, uint256 n) private pure returns (uint64[] memory out, uint256 next) {
        out = new uint64[](n);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = uint64(_limb(p, o));
            o += U64_BYTES;
        }
        next = o;
    }

    // A u32 cell count then the cells, flat. Constant form must repeat its first cell.
    function _finalLayer(bytes calldata p, uint256 o, V.Head memory h, bool asCoefficients)
        private
        pure
        returns (uint256)
    {
        uint256 fc = _u32(p, o);
        o += U32_BYTES;
        h.finalCount = fc;
        uint256[] memory flat;
        (flat, o) = readFpFlat(p, o, 2 * fc);
        h.finalFlat = flat;
        if (fc == 0) _panic(PANIC_INDEX);
        h.finalValue = F.Fp2(flat[0], flat[1]);
        if (!asCoefficients) {
            for (uint256 i = 1; i < fc; ++i) {
                if (flat[2 * i] != flat[0] || flat[2 * i + 1] != flat[1]) revert V.FinalLayerNotConstant(i);
            }
        }
        return o;
    }

    /// @notice n Fp2 values at p[o..], decoded into a new Fp2[]: length, n pointers, n cells.
    /// @dev OutOfBounds before anything is read, then NonCanonicalFp once all are decoded, as
    ///      the memory reader orders them. Moves the free pointer past the cells.
    function readFp2Array(bytes calldata p, uint256 o, uint256 n) internal pure returns (F.Fp2[] memory out, uint256 next) {
        next = o + n * FP2_BYTES;
        if (next > p.length) _revert0(SEL_OUT_OF_BOUNDS);
        bool bad;
        assembly {
            out := mload(0x40)
            mstore(out, n)
            let ptr := add(out, 0x20)
            let cell := add(ptr, mul(n, 0x20))
            let fin := add(cell, mul(n, 0x40))
            mstore(0x40, fin)
            let src := add(p.offset, o)
            for {} lt(cell, fin) {
                cell := add(cell, 0x40)
                ptr := add(ptr, 0x20)
                src := add(src, FP2_BYTES)
            } {
                mstore(ptr, cell)
                let word := calldataload(src)
                let v0 := _le(shr(192, word))
                let v1 := _le(and(shr(128, word), 0xFFFFFFFFFFFFFFFF))
                bad := or(bad, or(iszero(lt(v0, P)), iszero(lt(v1, P))))
                mstore(cell, v0)
                mstore(add(cell, 0x20), v1)
            }

            function _le(v) -> r {
                v := or(shr(8, and(v, 0xFF00FF00FF00FF00)), shl(8, and(v, 0x00FF00FF00FF00FF)))
                v := or(shr(16, and(v, 0xFFFF0000FFFF0000)), shl(16, and(v, 0x0000FFFF0000FFFF)))
                r := or(shr(32, v), and(shl(32, v), 0xFFFFFFFF00000000))
            }
        }
        if (bad) _revert0(SEL_NON_CANONICAL);
    }

    /// @notice n limbs at p[o..], decoded into a new uint256[]. Bounds and range as readFp2Array.
    function readFpFlat(bytes calldata p, uint256 o, uint256 n) internal pure returns (uint256[] memory out, uint256 next) {
        next = o + n * LIMB_BYTES;
        if (next > p.length) _revert0(SEL_OUT_OF_BOUNDS);
        bool bad;
        assembly {
            out := mload(0x40)
            mstore(out, n)
            let dst := add(out, 0x20)
            let fin := add(dst, mul(n, 0x20))
            mstore(0x40, fin)
            let src := add(p.offset, o)
            for {} lt(dst, fin) {
                dst := add(dst, 0x20)
                src := add(src, LIMB_BYTES)
            } {
                let v := shr(192, calldataload(src))
                v := or(shr(8, and(v, 0xFF00FF00FF00FF00)), shl(8, and(v, 0x00FF00FF00FF00FF)))
                v := or(shr(16, and(v, 0xFFFF0000FFFF0000)), shl(16, and(v, 0x0000FFFF0000FFFF)))
                v := or(shr(32, v), and(shl(32, v), 0xFFFFFFFF00000000))
                bad := or(bad, iszero(lt(v, P)))
                mstore(dst, v)
            }
        }
        if (bad) _revert0(SEL_NON_CANONICAL);
    }

    function _panic(uint256 code) private pure {
        assembly {
            mstore(0x00, shl(224, PANIC_SELECTOR))
            mstore(0x04, code)
            revert(0x00, 0x24)
        }
    }

    // ------------------------------------------------------------------------------ base query

    /// @dev Byte-reversal masks for four 64-bit lanes at once: bytes, then pairs, then halves.
    uint256 internal constant LANE_M8 = 0xFF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00FF00;
    uint256 internal constant LANE_M16 = 0xFFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000FFFF0000;
    uint256 internal constant LANE_M32 = 0xFFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000FFFFFFFF00000000;
    uint256 internal constant LIMB_MASK = 0xFFFFFFFFFFFFFFFF;

    /// @notice What one base query needs from the deployment, the head and the transcript.
    /// @dev _deep reads these fields by the B_* word offsets below, so their order must not change.
    ///      The DEEP sum is regrouped as sum_c k_c row_c - K0, K0 = sum_c k_c ood_c, and the same for
    ///      row 1 and the claims. prepareDeep folds the constants into cst0..cst3 once per proof.
    struct Base {
        bytes32 traceRoot;
        bytes32 permRoot;
        bytes32 compRoot;
        bytes32 periodicRoot;
        uint256 w; // digest bytes
        uint256 traceWidth;
        uint256 regionWidth; // columns below open under traceRoot, the rest under permRoot
        uint256 nPeriodic;
        uint256[] kflat; // per column k_c.c0, k_c.c1, k_(w+c).c0, k_(w+c).c1, then per claim k.c0, k.c1
        uint256 kc0; // k_2w, the composition's coefficient
        uint256 kc1;
        uint256 cst0; // row-0 bucket constant: K0 + k_2w comp_z + S
        uint256 cst1;
        uint256 cst2; // row-1 bucket constant: K1
        uint256 cst3;
        uint256 z0; // the out-of-domain point
        uint256 z1;
        uint256 g; // the trace domain's generator: row 1 sits at z g
        uint256 omega; // the evaluation domain's generator
        uint256 cosetShift;
    }

    uint256 internal constant B_TRACE_WIDTH = 0xa0;
    uint256 internal constant B_N_PERIODIC = 0xe0;
    uint256 internal constant B_KFLAT = 0x100;
    uint256 internal constant B_KC0 = 0x120;
    uint256 internal constant B_KC1 = 0x140;
    uint256 internal constant B_CST0 = 0x160;
    uint256 internal constant B_CST1 = 0x180;
    uint256 internal constant B_CST2 = 0x1a0;
    uint256 internal constant B_CST3 = 0x1c0;

    /// @notice Fills b.kflat, b.kc* and b.cst* from the DEEP coefficients, once per proof.
    /// @param coeffs 2w frame coefficients, the composition's, then one per periodic claim.
    function prepareDeep(
        Base memory b,
        F.Fp2[] memory ood,
        F.Fp2[] memory coeffs,
        F.Fp2[] memory periodicZ,
        uint256 compZ0,
        uint256 compZ1
    ) internal pure {
        uint256 w = b.traceWidth;
        uint256 np = b.nPeriodic;
        uint256[] memory kf = new uint256[](4 * w + 2 * np);
        b.kflat = kf;
        uint256[4] memory acc; // K0 + S unreduced, then K1 unreduced
        assembly {
            // kf: length word, then words. coeffs, ood, periodicZ: length, pointers, two-word cells.
            // Invariant: every cell is canonical, so each mulmod term is below P and the unreduced
            // sums over at most a few hundred terms stay far below 2^256.
            let kp := add(coeffs, 0x20)
            let op := add(ood, 0x20)
            let dst := add(kf, 0x20)
            for { let c := 0 } lt(c, w) { c := add(c, 1) } {
                let k := mload(add(kp, shl(5, c)))
                let o := mload(add(op, shl(5, c)))
                mstore(dst, mload(k))
                mstore(add(dst, 0x20), mload(add(k, 0x20)))
                _mac(acc, 0x00, k, o)
                k := mload(add(kp, shl(5, add(w, c))))
                o := mload(add(op, shl(5, add(w, c))))
                mstore(add(dst, 0x40), mload(k))
                mstore(add(dst, 0x60), mload(add(k, 0x20)))
                _mac(acc, 0x40, k, o)
                dst := add(dst, 0x80)
            }
            let zp := add(periodicZ, 0x20)
            let cp := add(kp, shl(5, add(shl(1, w), 1)))
            for { let j := 0 } lt(j, np) { j := add(j, 1) } {
                let k := mload(add(cp, shl(5, j)))
                mstore(dst, mload(k))
                mstore(add(dst, 0x20), mload(add(k, 0x20)))
                _mac(acc, 0x00, k, mload(add(zp, shl(5, j))))
                dst := add(dst, 0x40)
            }

            // acc[at], acc[at + 1] += k * v, (k0 + k1 X)(v0 + v1 X) = (k0 v0 + 7 k1 v1) + (k0 v1 + k1 v0) X
            function _mac(a, at, k, v) {
                let k0 := mload(k)
                let k1 := mload(add(k, 0x20))
                let v0 := mload(v)
                let v1 := mload(add(v, 0x20))
                let slot := add(a, at)
                mstore(slot, add(mload(slot), add(mulmod(k0, v0, P), mulmod(7, mulmod(k1, v1, P), P))))
                slot := add(slot, 0x20)
                mstore(slot, add(mload(slot), add(mulmod(k0, v1, P), mulmod(k1, v0, P))))
            }
        }
        F.Fp2 memory kc = coeffs[2 * w];
        (b.kc0, b.kc1) = (kc.c0, kc.c1);
        (uint256 t0, uint256 t1) = C.mul2(kc.c0, kc.c1, compZ0, compZ1);
        b.cst0 = addmod(acc[0] % P, t0, P);
        b.cst1 = addmod(acc[1] % P, t1, P);
        b.cst2 = acc[2] % P;
        b.cst3 = acc[3] % P;
    }

    /// @dev Where each section of a base query sits: a byte offset, or a sibling count.
    struct Spans {
        uint256 trace; // the row's first limb
        uint256 tracePath; // first sibling
        uint256 traceCnt;
        uint256 comp; // c0's first byte
        uint256 compPath;
        uint256 compCnt;
        uint256 periodic;
        uint256 periodicPath;
        uint256 periodicCnt;
        uint256 permPath;
        uint256 permCnt;
    }

    uint256 internal constant SP_TRACE = 0x00;
    uint256 internal constant SP_COMP = 0x60;
    uint256 internal constant SP_PERIODIC = 0xc0;

    /// @notice Verifies base query `q` at domain index `idx` against the DEEP value FRI opened there.
    /// @dev b must have been through prepareDeep.
    /// @return end The offset just past the query.
    function baseQuery(bytes calldata p, uint256 off, Base memory b, uint256 q, uint256 idx, uint256 d0, uint256 d1)
        internal
        pure
        returns (uint256 end)
    {
        Spans memory sp;
        end = _spans(p, off, b, sp);
        uint256 x = C.mul(b.cosetShift, C.pow(b.omega, idx));
        _auths(p, b, sp, q, idx);
        (uint256 g0, uint256 g1) = _deep(p, b, sp, x);
        if (g0 != d0 || g1 != d1) _revert5(SEL_DEEP_MISMATCH, q, g0, g1, d0, d1);
    }

    // Walks the section layout, refusing it as the memory reader would: a row of the wrong width,
    // a read past the end, a non-canonical row or composition limb, in wire order.
    function _spans(bytes calldata p, uint256 off, Base memory b, Spans memory sp) private pure returns (uint256) {
        uint256 tw = _u32(p, off);
        if (tw != b.traceWidth) _revert1(SEL_ROW_WIDTH, tw);
        off += U32_BYTES;
        if (off + tw * LIMB_BYTES > p.length) _revert0(SEL_OUT_OF_BOUNDS);
        if (!_canonical(p, off, tw)) _revert0(SEL_NON_CANONICAL);
        sp.trace = off;
        off += tw * LIMB_BYTES;
        (sp.tracePath, sp.traceCnt, off) = _pathSpan(p, off, b.w);
        sp.comp = off;
        for (uint256 k = 0; k < 2; ++k) {
            if (off + LIMB_BYTES > p.length) _revert0(SEL_OUT_OF_BOUNDS);
            if (!_canonical(p, off, 1)) _revert0(SEL_NON_CANONICAL);
            off += LIMB_BYTES;
        }
        (sp.compPath, sp.compCnt, off) = _pathSpan(p, off, b.w);
        sp.periodic = off;
        off += b.nPeriodic * LIMB_BYTES;
        (sp.periodicPath, sp.periodicCnt, off) = _pathSpan(p, off, b.w);
        (sp.permPath, sp.permCnt, off) = _pathSpan(p, off, b.w);
        return off;
    }

    // A u32 sibling count, then the siblings. A count or siblings past the end revert OutOfBounds.
    function _pathSpan(bytes calldata p, uint256 off, uint256 w)
        private
        pure
        returns (uint256 at, uint256 cnt, uint256 next)
    {
        cnt = _u32(p, off);
        at = off + U32_BYTES;
        next = at + cnt * w;
        if (next > p.length) _revert0(SEL_OUT_OF_BOUNDS);
    }

    // True when all n 8-byte little-endian limbs at p[off..] are below P. Bounds are the caller's.
    // Four limbs per load, byte-reversed lane by lane. Reads calldata only.
    function _canonical(bytes calldata p, uint256 off, uint256 n) private pure returns (bool ok) {
        assembly {
            let bad := 0
            let src := add(p.offset, off)
            let fin := add(src, mul(n, LIMB_BYTES))
            for {} lt(add(src, 0x18), fin) { src := add(src, 0x20) } {
                let v := _lanes(calldataload(src))
                bad := or(bad, or(or(_big(shr(192, v)), _big(and(shr(128, v), LIMB_MASK))), or(_big(and(shr(64, v), LIMB_MASK)), _big(and(v, LIMB_MASK)))))
            }
            for {} lt(src, fin) { src := add(src, LIMB_BYTES) } {
                bad := or(bad, _big(shr(192, _lanes(calldataload(src)))))
            }
            ok := iszero(bad)

            function _big(v) -> r {
                r := iszero(lt(v, P))
            }

            // each 64-bit lane byte-reversed: four wire limbs to four values
            function _lanes(x) -> r {
                x := or(shr(8, and(x, LANE_M8)), shl(8, and(x, shr(8, LANE_M8))))
                x := or(shr(16, and(x, LANE_M16)), shl(16, and(x, shr(16, LANE_M16))))
                r := or(shr(32, and(x, LANE_M32)), shl(32, and(x, shr(32, LANE_M32))))
            }
        }
    }

    // Every opening of the query, in the memory walk's order: both trace halves, the
    // composition value, then the periodic row.
    function _auths(bytes calldata p, Base memory b, Spans memory sp, uint256 q, uint256 idx) private pure {
        uint256 w = b.w;
        uint256 rw = b.regionWidth;
        if (rw >= b.traceWidth) _revert2(SEL_REGION_WIDTH, rw, b.traceWidth);
        bytes32 leaf = MK.hashWire(MK.TAG_LEAF_WIDE, MK.TAG_LEAF_WIDE_LEN, p, sp.trace, rw * LIMB_BYTES);
        if (!MK.walk(p, sp.tracePath, sp.traceCnt, b.traceRoot, idx, leaf, w)) _revert1(SEL_TRACE_AUTH, q);
        leaf = MK.hashWire(
            MK.TAG_LEAF_WIDE, MK.TAG_LEAF_WIDE_LEN, p, sp.trace + rw * LIMB_BYTES, (b.traceWidth - rw) * LIMB_BYTES
        );
        if (!MK.walk(p, sp.permPath, sp.permCnt, b.permRoot, idx, leaf, w)) _revert1(SEL_COPY_COMMIT, q);
        leaf = MK.hashWire(MK.TAG_LEAF_EXT, MK.TAG_LEAF_EXT_LEN, p, sp.comp, 2 * LIMB_BYTES);
        if (!MK.walk(p, sp.compPath, sp.compCnt, b.compRoot, idx, leaf, w)) _revert1(SEL_COMP_AUTH, q);
        if (b.nPeriodic != 0) {
            leaf = MK.hashWire(MK.TAG_LEAF_PERIODIC, MK.TAG_LEAF_PERIODIC_LEN, p, sp.periodic, b.nPeriodic * LIMB_BYTES);
            if (!MK.walk(p, sp.periodicPath, sp.periodicCnt, b.periodicRoot, idx, leaf, w)) {
                _revert1(SEL_PERIODIC_AUTH, q);
            }
        }
    }

    // The DEEP combination at x, regrouped as prepareDeep describes:
    //   (sum_c k_c row_c + sum_j kp_j prow_j + k_2w comp - cst01) inv0 + (sum_c k_(w+c) row_c - cst23) inv1
    // with inv0 = 1/(x - z) and inv1 = 1/(x - z g) from one inversion.
    function _deep(bytes calldata p, Base memory b, Spans memory sp, uint256 x)
        private
        pure
        returns (uint256 g0, uint256 g1)
    {
        uint256[4] memory inv; // inv0.c0, inv0.c1, inv1.c0, inv1.c1
        _inverses(b, x, inv);
        uint256[4] memory acc; // row-0 bucket c0, c1, row-1 bucket c0, c1, all unreduced
        assembly {
            // Reads: b by the B_* offsets, sp by SP_*, kflat as a length word then words, calldata
            // at the row, composition and periodic offsets. Writes only acc.
            // Invariant: row limbs were range-checked by _spans and kflat is canonical, so each
            // product is below P and the unreduced bucket sums stay far below 2^256.
            let w := mload(add(b, B_TRACE_WIDTH))
            let kf := add(mload(add(b, B_KFLAT)), 0x20)
            _rows(acc, add(p.offset, mload(add(sp, SP_TRACE))), w, kf)
            let np := mload(add(b, B_N_PERIODIC))
            if np { _periodic(acc, add(p.offset, mload(add(sp, SP_PERIODIC))), np, add(kf, shl(7, w))) }
            {
                let src := add(p.offset, mload(add(sp, SP_COMP)))
                let c := _lanes(calldataload(src))
                let t0, t1 := _mul(shr(192, c), and(shr(128, c), LIMB_MASK), mload(add(b, B_KC0)), mload(add(b, B_KC1)))
                mstore(acc, add(mload(acc), t0))
                mstore(add(acc, 0x20), add(mload(add(acc, 0x20)), t1))
            }
            let s0 := addmod(mod(mload(acc), P), sub(P, mload(add(b, B_CST0))), P)
            let s1 := addmod(mod(mload(add(acc, 0x20)), P), sub(P, mload(add(b, B_CST1))), P)
            g0, g1 := _mul(s0, s1, mload(inv), mload(add(inv, 0x20)))
            s0 := addmod(mod(mload(add(acc, 0x40)), P), sub(P, mload(add(b, B_CST2))), P)
            s1 := addmod(mod(mload(add(acc, 0x60)), P), sub(P, mload(add(b, B_CST3))), P)
            let t0, t1 := _mul(s0, s1, mload(add(inv, 0x40)), mload(add(inv, 0x60)))
            g0 := addmod(g0, t0, P)
            g1 := addmod(g1, t1, P)

            // Both window rows in one pass: each wire limb is read once and multiplied into both
            // buckets by the four kflat words of its column. Four columns per load.
            function _rows(a, src, width, k) {
                let a0 := 0
                let a1 := 0
                let b0 := 0
                let b1 := 0
                let fin := add(src, mul(width, LIMB_BYTES))
                for {} lt(add(src, 0x18), fin) {
                    src := add(src, 0x20)
                    k := add(k, 0x200)
                } {
                    let v := _lanes(calldataload(src))
                    let r := shr(192, v)
                    a0 := add(a0, mulmod(mload(k), r, P))
                    a1 := add(a1, mulmod(mload(add(k, 0x20)), r, P))
                    b0 := add(b0, mulmod(mload(add(k, 0x40)), r, P))
                    b1 := add(b1, mulmod(mload(add(k, 0x60)), r, P))
                    r := and(shr(128, v), LIMB_MASK)
                    a0 := add(a0, mulmod(mload(add(k, 0x80)), r, P))
                    a1 := add(a1, mulmod(mload(add(k, 0xa0)), r, P))
                    b0 := add(b0, mulmod(mload(add(k, 0xc0)), r, P))
                    b1 := add(b1, mulmod(mload(add(k, 0xe0)), r, P))
                    r := and(shr(64, v), LIMB_MASK)
                    a0 := add(a0, mulmod(mload(add(k, 0x100)), r, P))
                    a1 := add(a1, mulmod(mload(add(k, 0x120)), r, P))
                    b0 := add(b0, mulmod(mload(add(k, 0x140)), r, P))
                    b1 := add(b1, mulmod(mload(add(k, 0x160)), r, P))
                    r := and(v, LIMB_MASK)
                    a0 := add(a0, mulmod(mload(add(k, 0x180)), r, P))
                    a1 := add(a1, mulmod(mload(add(k, 0x1a0)), r, P))
                    b0 := add(b0, mulmod(mload(add(k, 0x1c0)), r, P))
                    b1 := add(b1, mulmod(mload(add(k, 0x1e0)), r, P))
                }
                for {} lt(src, fin) {
                    src := add(src, LIMB_BYTES)
                    k := add(k, 0x80)
                } {
                    let r := shr(192, _lanes(calldataload(src)))
                    a0 := add(a0, mulmod(mload(k), r, P))
                    a1 := add(a1, mulmod(mload(add(k, 0x20)), r, P))
                    b0 := add(b0, mulmod(mload(add(k, 0x40)), r, P))
                    b1 := add(b1, mulmod(mload(add(k, 0x60)), r, P))
                }
                mstore(a, a0)
                mstore(add(a, 0x20), a1)
                mstore(add(a, 0x40), b0)
                mstore(add(a, 0x60), b1)
            }

            // The periodic row into the row-0 bucket, two kflat words per claim. A limb >= P
            // reverts NonCanonicalPeriodicLimb once the row is summed, as the memory walk does.
            function _periodic(a, src, n, k) {
                let a0 := mload(a)
                let a1 := mload(add(a, 0x20))
                let bad := 0
                let fin := add(src, mul(n, LIMB_BYTES))
                for {} lt(add(src, 0x18), fin) {
                    src := add(src, 0x20)
                    k := add(k, 0x100)
                } {
                    let v := _lanes(calldataload(src))
                    let r := shr(192, v)
                    bad := or(bad, iszero(lt(r, P)))
                    a0 := add(a0, mulmod(mload(k), r, P))
                    a1 := add(a1, mulmod(mload(add(k, 0x20)), r, P))
                    r := and(shr(128, v), LIMB_MASK)
                    bad := or(bad, iszero(lt(r, P)))
                    a0 := add(a0, mulmod(mload(add(k, 0x40)), r, P))
                    a1 := add(a1, mulmod(mload(add(k, 0x60)), r, P))
                    r := and(shr(64, v), LIMB_MASK)
                    bad := or(bad, iszero(lt(r, P)))
                    a0 := add(a0, mulmod(mload(add(k, 0x80)), r, P))
                    a1 := add(a1, mulmod(mload(add(k, 0xa0)), r, P))
                    r := and(v, LIMB_MASK)
                    bad := or(bad, iszero(lt(r, P)))
                    a0 := add(a0, mulmod(mload(add(k, 0xc0)), r, P))
                    a1 := add(a1, mulmod(mload(add(k, 0xe0)), r, P))
                }
                for {} lt(src, fin) {
                    src := add(src, LIMB_BYTES)
                    k := add(k, 0x40)
                } {
                    let r := shr(192, _lanes(calldataload(src)))
                    bad := or(bad, iszero(lt(r, P)))
                    a0 := add(a0, mulmod(mload(k), r, P))
                    a1 := add(a1, mulmod(mload(add(k, 0x20)), r, P))
                }
                if bad {
                    mstore(0x00, shl(224, SEL_PERIODIC_LIMB))
                    revert(0x00, 0x04)
                }
                mstore(a, a0)
                mstore(add(a, 0x20), a1)
            }

            // GoldilocksCore.mul2
            function _mul(a0, a1, c0, c1) -> r0, r1 {
                r0 := addmod(mulmod(a0, c0, P), mulmod(7, mulmod(a1, c1, P), P), P)
                r1 := addmod(mulmod(a0, c1, P), mulmod(a1, c0, P), P)
            }

            function _lanes(v) -> r {
                v := or(shr(8, and(v, LANE_M8)), shl(8, and(v, shr(8, LANE_M8))))
                v := or(shr(16, and(v, LANE_M16)), shl(16, and(v, shr(16, LANE_M16))))
                r := or(shr(32, and(v, LANE_M32)), shl(32, and(v, shr(32, LANE_M32))))
            }
        }
    }

    // 1/(x - z) and 1/(x - z g) for one inversion. A zero denominator, which a random z reaches
    // with negligible probability, is inverted on its own so it maps to zero as F.inv maps it.
    function _inverses(Base memory b, uint256 x, uint256[4] memory inv) private pure {
        uint256 a0 = C.sub(x, b.z0);
        uint256 a1 = C.neg(b.z1);
        uint256 c0 = C.sub(x, C.mul(b.z0, b.g));
        uint256 c1 = C.neg(C.mul(b.z1, b.g));
        if ((a0 == 0 && a1 == 0) || (c0 == 0 && c1 == 0)) {
            (inv[0], inv[1]) = C.inv2(a0, a1);
            (inv[2], inv[3]) = C.inv2(c0, c1);
            return;
        }
        (uint256 n0, uint256 n1) = C.mul2(a0, a1, c0, c1);
        (n0, n1) = C.inv2(n0, n1);
        (inv[0], inv[1]) = C.mul2(n0, n1, c0, c1);
        (inv[2], inv[3]) = C.mul2(n0, n1, a0, a1);
    }

    function _revert2(uint256 sel, uint256 a, uint256 b) private pure {
        assembly {
            mstore(0x00, shl(224, sel))
            mstore(0x04, a)
            mstore(0x24, b)
            revert(0x00, 0x44)
        }
    }

    // Five words of arguments overrun 0x40 and 0x60 as well, and the revert follows at once.
    function _revert5(uint256 sel, uint256 a, uint256 b, uint256 c, uint256 d, uint256 e) private pure {
        assembly {
            mstore(0x00, shl(224, sel))
            mstore(0x04, a)
            mstore(0x24, b)
            mstore(0x44, c)
            mstore(0x64, d)
            mstore(0x84, e)
            revert(0x00, 0xa4)
        }
    }

    /// @notice sum_j c_j x^j over a flat coefficient list, c0 and c1 as two chains.
    /// @dev The head decoder refuses an empty final layer. Each step leaves acc below 2P, and the
    ///      result is reduced once at the end. Four steps per iteration.
    function _horner(uint256[] memory flat, uint256 x) private pure returns (uint256 a0, uint256 a1) {
        assembly {
            let first := add(flat, 0x20)
            let at := add(first, mul(sub(mload(flat), 2), 0x20))
            a0 := mload(at)
            a1 := mload(add(at, 0x20))
            // at - first is 0x40 per step still to take
            for {} gt(sub(at, first), 0xc0) {} {
                at := sub(at, 0x40)
                a0 := add(mulmod(a0, x, P), mload(at))
                a1 := add(mulmod(a1, x, P), mload(add(at, 0x20)))
                at := sub(at, 0x40)
                a0 := add(mulmod(a0, x, P), mload(at))
                a1 := add(mulmod(a1, x, P), mload(add(at, 0x20)))
                at := sub(at, 0x40)
                a0 := add(mulmod(a0, x, P), mload(at))
                a1 := add(mulmod(a1, x, P), mload(add(at, 0x20)))
                at := sub(at, 0x40)
                a0 := add(mulmod(a0, x, P), mload(at))
                a1 := add(mulmod(a1, x, P), mload(add(at, 0x20)))
            }
            for {} gt(at, first) {} {
                at := sub(at, 0x40)
                a0 := add(mulmod(a0, x, P), mload(at))
                a1 := add(mulmod(a1, x, P), mload(add(at, 0x20)))
            }
            a0 := mod(a0, P)
            a1 := mod(a1, P)
        }
    }

    function _u32(bytes calldata p, uint256 off) private pure returns (uint256 v) {
        if (off + U32_BYTES > p.length) _revert0(SEL_OUT_OF_BOUNDS);
        assembly {
            v := shr(224, calldataload(add(p.offset, off)))
            v := or(shr(8, and(v, 0xFF00FF00)), shl(8, and(v, 0x00FF00FF)))
            v := or(shr(16, v), and(shl(16, v), 0xFFFF0000))
        }
    }

    function _revert0(uint256 sel) private pure {
        assembly {
            mstore(0x00, shl(224, sel))
            revert(0x00, 0x04)
        }
    }

    function _revert1(uint256 sel, uint256 a) private pure {
        assembly {
            mstore(0x00, shl(224, sel))
            mstore(0x04, a)
            revert(0x00, 0x24)
        }
    }
}
