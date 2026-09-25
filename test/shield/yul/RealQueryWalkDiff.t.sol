// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DiffBase} from "./DiffBase.sol";
import {StarkFieldExt as F} from "../../../contracts/shield/verifier/StarkFieldExt.sol";
import {RealQueryWalk as W} from "../../../contracts/shield/verifier/RealQueryWalk.sol";
import {RealQueryVerify as V} from "../../../contracts/shield/verifier/RealQueryVerify.sol";
import {StarkProofReader as R} from "../../../contracts/shield/StarkProofReader.sol";
import {RealQueryWalkRef as WR} from "../reference/RealQueryWalkRef.sol";
import {GoldilocksCoreRef as C} from "../reference/GoldilocksCoreRef.sol";

interface IFriQuery {
    function friQuery(bytes calldata p, W.Fri calldata f, uint256 pos, uint256 q)
        external
        pure
        returns (uint256 end, uint256 d0, uint256 d1);
}

contract FriYul is IFriQuery {
    function friQuery(bytes calldata p, W.Fri calldata f, uint256 pos, uint256 q)
        external
        pure
        returns (uint256, uint256, uint256)
    {
        return W.friQuery(p, 0, f, pos, q);
    }
}

contract FriRef is IFriQuery {
    function friQuery(bytes calldata p, W.Fri calldata f, uint256 pos, uint256 q)
        external
        pure
        returns (uint256, uint256, uint256)
    {
        return WR.friQuery(p, 0, f, pos, q);
    }
}

/// One radix-4 FRI query, Yul against its Solidity twin, on queries built to verify and then
/// damaged one way at a time.
contract RealQueryWalkDiffTest is DiffBase {
    uint256 internal constant GEN = 7;
    address internal y;
    address internal r;

    function setUp() public {
        y = address(new FriYul());
        r = address(new FriRef());
    }

    struct Build {
        uint256 logDomain;
        uint256 layers;
        uint256 w;
        uint256 pos;
        uint256 omega;
        uint256 seed;
        uint256 c0;
        uint256 c1;
        uint256 prevI;
        bytes wire;
    }

    function _rand(Build memory b, uint256 tag) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(b.seed, tag)));
    }

    function _le(uint256 v, uint256 n) internal pure returns (bytes memory o) {
        o = new bytes(n);
        for (uint256 i = 0; i < n; ++i) o[i] = bytes1(uint8(v >> (8 * i)));
    }

    function _mask(uint256 w) internal pure returns (bytes32) {
        return bytes32(~uint256(0) << (8 * (32 - w)));
    }

    function _node(bytes32 l, bytes32 rr, uint256 w) internal pure returns (bytes32) {
        bytes memory a = new bytes(w);
        bytes memory c = new bytes(w);
        for (uint256 i = 0; i < w; ++i) {
            a[i] = l[i];
            c[i] = rr[i];
        }
        return keccak256(abi.encodePacked("NONOS-STARK-MERKLE-NODE", a, c)) & _mask(w);
    }

    /// A query that verifies: every layer's group holds the previous fold where the next layer
    /// looks for it, every path opens to its root, and the final polynomial meets the last fold.
    function _build(uint256 seed, bool coeffs, uint256 fcLog)
        internal
        pure
        returns (Build memory b, W.Fri memory f)
    {
        uint256 logDomain = 6 + (seed % 11); // 6..16
        return _buildAt(seed, coeffs, fcLog, logDomain, 1 + (seed >> 8) % ((logDomain - 2) / 2));
    }

    function _buildAt(uint256 seed, bool coeffs, uint256 fcLog, uint256 logDomain, uint256 layers)
        internal
        pure
        returns (Build memory b, W.Fri memory f)
    {
        b.seed = seed;
        b.logDomain = logDomain;
        b.layers = layers;
        b.w = (seed >> 16) % 2 == 0 ? 24 : 32;
        b.pos = _rand(b, 1) % (1 << b.logDomain);
        b.omega = C.pow(GEN, (P - 1) >> b.logDomain);
        f.logDomain = b.logDomain;
        f.w = b.w;
        f.omega = b.omega;
        f.finalAsCoefficients = coeffs;
        f.roots = new bytes32[](b.layers);
        f.betas = new F.Fp2[](b.layers);
        b.wire = _le(b.layers, 4);
        uint256 zeta = C.pow(b.omega, (1 << b.logDomain) >> 2);
        for (uint256 m = 0; m < b.layers; ++m) {
            _layer(b, f, m, zeta);
        }
        uint256 fc = coeffs ? 1 << (fcLog % 4) : 1 + fcLog % 3;
        f.finalFlat = new uint256[](2 * fc);
        if (coeffs) {
            uint256 nf = 2 * b.layers;
            uint256 x = C.pow(C.mul(7, C.pow(b.omega, b.pos % ((1 << b.logDomain) >> nf))), 1 << nf);
            // choose c_1.. at random, then c_0 so the polynomial meets the last fold at x
            uint256 s0;
            uint256 s1;
            uint256 xp = 1;
            for (uint256 j = 1; j < fc; ++j) {
                xp = mulmod(xp, x, P);
                f.finalFlat[2 * j] = _rand(b, 1000 + j) % P;
                f.finalFlat[2 * j + 1] = _rand(b, 2000 + j) % P;
                s0 = addmod(s0, mulmod(f.finalFlat[2 * j], xp, P), P);
                s1 = addmod(s1, mulmod(f.finalFlat[2 * j + 1], xp, P), P);
            }
            f.finalFlat[0] = addmod(b.c0, P - s0, P);
            f.finalFlat[1] = addmod(b.c1, P - s1, P);
        } else {
            for (uint256 j = 0; j < fc; ++j) {
                f.finalFlat[2 * j] = b.c0;
                f.finalFlat[2 * j + 1] = b.c1;
            }
        }
    }

    function _layer(Build memory b, W.Fri memory f, uint256 m, uint256 zeta) internal pure {
        uint256 quarter = ((1 << b.logDomain) >> (2 * m)) >> 2;
        uint256[8] memory v;
        for (uint256 k = 0; k < 8; ++k) v[k] = _rand(b, 10 * m + k + 100) % P;
        if (m > 0) {
            uint256 slot = (b.prevI / quarter) % 4;
            v[2 * slot] = b.c0;
            v[2 * slot + 1] = b.c1;
        }
        bytes memory group;
        for (uint256 k = 0; k < 8; ++k) group = bytes.concat(group, _le(v[k], 8));
        bytes memory path;
        (f.roots[m], path) = _openTo(b, m, quarter, group);
        b.wire = bytes.concat(b.wire, group, path);
        f.betas[m] = F.Fp2(_rand(b, 7000 + m) % P, _rand(b, 8000 + m) % P);
        _fold(b, v, f.betas[m], m, b.pos % quarter, zeta);
    }

    // A path of random siblings from the group's leaf, deep enough to use up the index, and the
    // root it reaches.
    function _openTo(Build memory b, uint256 m, uint256 quarter, bytes memory group)
        internal
        pure
        returns (bytes32 node, bytes memory path)
    {
        node = keccak256(abi.encodePacked("NONOS-STARK-MERKLE-LEAF-QUAD", group)) & _mask(b.w);
        uint256 depth;
        while ((uint256(1) << depth) < quarter) ++depth;
        path = _le(depth, 4);
        uint256 idx = b.pos % quarter;
        for (uint256 d = 0; d < depth; ++d) {
            bytes32 sib = bytes32(_rand(b, 5000 + 64 * m + d)) & _mask(b.w);
            path = bytes.concat(path, _cut(sib, b.w));
            node = (idx & 1) == 0 ? _node(node, sib, b.w) : _node(sib, node, b.w);
            idx >>= 1;
        }
    }

    // The layer's fold at x0 = (s w^i)^(4^m), computed directly from the index.
    function _fold(Build memory b, uint256[8] memory v, F.Fp2 memory beta, uint256 m, uint256 i, uint256 zeta)
        internal
        pure
    {
        uint256 x0 = C.pow(C.mul(7, C.pow(b.omega, i)), 1 << (2 * m));
        uint256[4] memory t;
        (t[0], t[1]) = C.fold2(v[0], v[1], v[4], v[5], beta.c0, beta.c1, C.inv(x0));
        (t[2], t[3]) = C.fold2(v[2], v[3], v[6], v[7], beta.c0, beta.c1, C.inv(C.mul(x0, zeta)));
        (uint256 bb0, uint256 bb1) = C.sqr2(beta.c0, beta.c1);
        uint256 ix0 = C.inv(x0);
        (b.c0, b.c1) = C.fold2(t[0], t[1], t[2], t[3], bb0, bb1, mulmod(ix0, ix0, P));
        b.prevI = i;
    }

    function _cut(bytes32 d, uint256 w) internal pure returns (bytes memory o) {
        o = new bytes(w);
        for (uint256 i = 0; i < w; ++i) o[i] = d[i];
    }

    function _call(Build memory b, W.Fri memory f, bytes memory wire) internal view returns (bool, bytes memory) {
        return _same(y, r, abi.encodeCall(IFriQuery.friQuery, (wire, f, b.pos, 3)));
    }

    /// Honest queries verify on both, with the same end offset and the same DEEP value.
    function testFuzz_honestQueryVerifies(uint256 seed, bool coeffs, uint256 fcLog) public view {
        (Build memory b, W.Fri memory f) = _build(seed, coeffs, fcLog);
        (bool ok, bytes memory out) = _call(b, f, b.wire);
        assertTrue(ok, "an honest query was refused");
        (uint256 end,,) = abi.decode(out, (uint256, uint256, uint256));
        assertEq(end, b.wire.length);
    }

    /// One byte changed anywhere in the query: both give the same refusal, or the same answer
    /// where the byte is not read.
    function testFuzz_oneByteChanged(uint256 seed, bool coeffs, uint256 at, uint8 x) public view {
        (Build memory b, W.Fri memory f) = _build(seed, coeffs, seed >> 32);
        bytes memory wire = b.wire;
        wire[at % wire.length] = bytes1(uint8(wire[at % wire.length]) ^ (x | 1));
        _call(b, f, wire);
    }

    /// A limb at P, at 2^64 - 1, or just below P, in any slot of any layer.
    function testFuzz_limbEdges(uint256 seed, uint256 which, uint8 kind) public view {
        (Build memory b, W.Fri memory f) = _build(seed, true, seed >> 32);
        uint256 layerStart = 4;
        uint256 m = which % b.layers;
        for (uint256 j = 0; j < m; ++j) {
            uint256 cnt = uint8(b.wire[layerStart + 64]) | uint256(uint8(b.wire[layerStart + 65])) << 8;
            layerStart += 64 + 4 + cnt * b.w;
        }
        uint256 limb = (which >> 8) % 8;
        uint256 v = kind % 3 == 0 ? P : kind % 3 == 1 ? type(uint64).max : P - 1;
        bytes memory le = _le(v, 8);
        for (uint256 k = 0; k < 8; ++k) b.wire[layerStart + 8 * limb + k] = le[k];
        _call(b, f, b.wire);
    }

    /// Cut short at any byte: both refuse, with the same error.
    function testFuzz_truncated(uint256 seed, uint256 at) public view {
        (Build memory b, W.Fri memory f) = _build(seed, true, seed >> 32);
        bytes memory wire = new bytes(at % b.wire.length);
        for (uint256 i = 0; i < wire.length; ++i) wire[i] = b.wire[i];
        (bool ok,) = _call(b, f, wire);
        assertFalse(ok);
    }

    /// A wrong root, a wrong beta, a wrong layer count, a position off by one.
    function testFuzz_wrongContext(uint256 seed, uint8 kind) public view {
        (Build memory b, W.Fri memory f) = _build(seed, (seed & 1) == 0, seed >> 32);
        uint256 k = kind % 4;
        if (k == 0) f.roots[seed % b.layers] ^= bytes32(uint256(1) << 200);
        if (k == 1) f.betas[seed % b.layers].c1 = addmod(f.betas[seed % b.layers].c1, 1, P);
        if (k == 2) b.wire[0] = bytes1(uint8(b.wire[0]) + 1);
        if (k == 3) b.pos = (b.pos + 1) % (1 << b.logDomain);
        (bool ok,) = _call(b, f, b.wire);
        assertFalse(ok);
    }

    /// The deployed domain, 2^28, with its 26-deep layer-zero path, at the six layers the
    /// deployment folds and at the thirteen the domain allows. Then its last byte is flipped.
    function testFuzz_maximumDepth(uint256 seed, bool most) public view {
        (Build memory b, W.Fri memory f) = _buildAt(seed, true, 3, 28, most ? 13 : 6);
        (bool ok,) = _call(b, f, b.wire);
        assertTrue(ok, "a full-depth query was refused");
        b.wire[b.wire.length - 1] ^= 0x01;
        (ok,) = _call(b, f, b.wire);
        assertFalse(ok);
    }

    /// The selectors the Yul writes by number are the ones the errors declare.
    function test_selectorsAreTheDeclaredOnes() public pure {
        assertEq(W.SEL_OUT_OF_BOUNDS, uint32(R.OutOfBounds.selector));
        assertEq(W.SEL_NON_CANONICAL, uint32(R.NonCanonicalFp.selector));
        assertEq(W.SEL_LAYER_AUTH, uint32(V.LayerAuthFailed.selector));
        assertEq(W.SEL_FOLD_CHASE, uint32(V.FoldChaseFailed.selector));
    }
}
