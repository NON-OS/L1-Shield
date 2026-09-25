// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StarkFieldExt as F} from "../../../contracts/shield/verifier/StarkFieldExt.sol";
import {RealQueryWalk as W} from "../../../contracts/shield/verifier/RealQueryWalk.sol";
import {GoldilocksCoreRef as C} from "./GoldilocksCoreRef.sol";

/// @title RealQueryWalkRef
/// @notice The Solidity twin of contracts/shield/verifier/RealQueryWalk.sol: one radix-4 FRI
///         query over a memory copy of the proof, with every read, hash and field step written
///         out in plain Solidity. Test-only, never deployed.
library RealQueryWalkRef {
    uint256 internal constant P = 0xFFFFFFFF00000001;
    uint256 internal constant COSET_SHIFT = 7;

    error OutOfBounds();
    error NonCanonicalFp();
    error LayerAuthFailed(uint256 query, uint256 layer);
    error FoldChaseFailed(uint256 query);

    struct St {
        uint256 off;
        uint256 c0;
        uint256 c1;
        uint256 prevI;
        uint256 ix;
        uint256 izeta;
        uint256 d0;
        uint256 d1;
    }

    function _u32(bytes memory p, uint256 o) internal pure returns (uint256 v) {
        if (o + 4 > p.length) revert OutOfBounds();
        for (uint256 i = 0; i < 4; ++i) v |= uint256(uint8(p[o + i])) << (8 * i);
    }

    function _u64(bytes memory p, uint256 o) internal pure returns (uint256 v) {
        for (uint256 i = 0; i < 8; ++i) v |= uint256(uint8(p[o + i])) << (8 * i);
    }

    function _slice(bytes memory p, uint256 o, uint256 n) internal pure returns (bytes memory b) {
        b = new bytes(n);
        for (uint256 i = 0; i < n; ++i) b[i] = p[o + i];
    }

    function _trunc(bytes32 h, uint256 w) internal pure returns (bytes32) {
        return h & bytes32(~uint256(0) << (8 * (32 - w)));
    }

    function friQuery(bytes memory p, uint256 off, W.Fri memory f, uint256 pos, uint256 q)
        internal
        pure
        returns (uint256 end, uint256 d0, uint256 d1)
    {
        uint256 layers = _u32(p, off);
        if (layers != f.roots.length) revert FoldChaseFailed(q);
        uint256 n = 1 << f.logDomain;
        St memory st;
        st.off = off + 4;
        st.ix = C.inv(C.mul(COSET_SHIFT, C.pow(f.omega, pos % (n >> 2))));
        uint256 z = C.pow(f.omega, n >> 2);
        st.izeta = mulmod(mulmod(z, z, P), z, P);
        for (uint256 m = 0; m < layers; ++m) {
            _layer(p, f, pos, q, m, st);
        }
        (uint256 e0, uint256 e1) = _expect(f, pos, layers);
        if (st.c0 != e0 || st.c1 != e1) revert FoldChaseFailed(q);
        return (st.off, st.d0, st.d1);
    }

    function _expect(W.Fri memory f, uint256 pos, uint256 layers) internal pure returns (uint256, uint256) {
        if (!f.finalAsCoefficients) return (f.finalFlat[0], f.finalFlat[1]);
        uint256 n = 1 << f.logDomain;
        uint256 nFolds = 2 * layers;
        uint256 x = C.pow(C.mul(COSET_SHIFT, C.pow(f.omega, pos % (n >> nFolds))), 1 << nFolds);
        return _evalFinal(f.finalFlat, x);
    }

    function _evalFinal(uint256[] memory flat, uint256 x) internal pure returns (uint256 a0, uint256 a1) {
        uint256 fc = flat.length / 2;
        a0 = flat[2 * (fc - 1)];
        a1 = flat[2 * (fc - 1) + 1];
        for (uint256 j = fc - 1; j > 0; --j) {
            a0 = addmod(mulmod(a0, x, P), flat[2 * (j - 1)], P);
            a1 = addmod(mulmod(a1, x, P), flat[2 * (j - 1) + 1], P);
        }
    }

    function _layer(bytes memory p, W.Fri memory f, uint256 pos, uint256 q, uint256 m, St memory st) private pure {
        uint256 quarter = ((1 << f.logDomain) >> (2 * m)) >> 2;
        uint256 i = pos % quarter;
        uint256[8] memory v = _readQuad(p, st.off);
        bytes32 leaf = _trunc(keccak256(abi.encodePacked("NONOS-STARK-MERKLE-LEAF-QUAD", _slice(p, st.off, 64))), f.w);
        st.off += 64;
        if (!_path(p, st, f.roots[m], i, leaf, f.w)) revert LayerAuthFailed(q, m);
        if (m == 0) {
            uint256 slot = pos / quarter;
            st.d0 = v[2 * slot];
            st.d1 = v[2 * slot + 1];
        }
        if (m > 0) {
            uint256 k = st.prevI / quarter;
            if (st.c0 != v[2 * (k % 4)] || st.c1 != v[2 * (k % 4) + 1]) revert FoldChaseFailed(q);
            uint256 ix = mulmod(st.ix, st.ix, P);
            ix = mulmod(ix, ix, P);
            if (k != 0) for (uint256 t = k; t < 4; ++t) ix = mulmod(ix, st.izeta, P);
            st.ix = ix;
        }
        F.Fp2 memory beta = f.betas[m];
        (st.c0, st.c1) = _quadFold(v, beta.c0, beta.c1, st.ix, mulmod(st.ix, st.izeta, P));
        st.prevI = i;
    }

    function _readQuad(bytes memory p, uint256 o) private pure returns (uint256[8] memory v) {
        if (o + 64 > p.length) revert OutOfBounds();
        bool bad;
        for (uint256 k = 0; k < 8; ++k) {
            v[k] = _u64(p, o + 8 * k);
            if (v[k] >= P) bad = true;
        }
        if (bad) revert NonCanonicalFp();
    }

    function _path(bytes memory p, St memory st, bytes32 root, uint256 idx, bytes32 node, uint256 w)
        private
        pure
        returns (bool)
    {
        uint256 k = _u32(p, st.off);
        uint256 o = st.off + 4;
        if (o + k * w > p.length) return false;
        for (uint256 j = 0; j < k; ++j) {
            bytes32 sib = bytes32(_slice(p, o + j * w, w)) & bytes32(~uint256(0) << (8 * (32 - w)));
            bytes memory l = _slice(abi.encodePacked(idx & 1 == 0 ? node : sib), 0, w);
            bytes memory r = _slice(abi.encodePacked(idx & 1 == 0 ? sib : node), 0, w);
            node = _trunc(keccak256(abi.encodePacked("NONOS-STARK-MERKLE-NODE", l, r)), w);
            idx >>= 1;
        }
        st.off = o + k * w;
        return idx == 0 && node == root;
    }

    function _quadFold(uint256[8] memory v, uint256 b0, uint256 b1, uint256 ix0, uint256 ix1)
        private
        pure
        returns (uint256, uint256)
    {
        uint256[4] memory t;
        (t[0], t[1]) = C.fold2(v[0], v[1], v[4], v[5], b0, b1, ix0);
        (t[2], t[3]) = C.fold2(v[2], v[3], v[6], v[7], b0, b1, ix1);
        (uint256 bb0, uint256 bb1) = C.sqr2(b0, b1);
        return C.fold2(t[0], t[1], t[2], t[3], bb0, bb1, mulmod(ix0, ix0, P));
    }
}
