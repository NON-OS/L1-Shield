// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Goldilocks} from "./libraries/Goldilocks.sol";

/// @title StarkProofReader
/// @notice Bounds-checked cursor reader for the frozen StarkProofExt byte layout. Verifies nothing.
/// @dev Integers are little-endian. Every Fp read rejects values >= p. See docs/04-proof-codec.md.
library StarkProofReader {
    struct Cursor {
        uint256 off;
    }

    // c0 + c1*X, X^2 = 7
    struct Fp2 {
        uint64 c0;
        uint64 c1;
    }

    error OutOfBounds();
    error NonCanonicalFp();

    function readU32(bytes memory b, Cursor memory c) internal pure returns (uint32 v) {
        uint256 o = c.off;
        if (o + 4 > b.length) revert OutOfBounds();
        assembly {
            let w := shr(224, mload(add(add(b, 0x20), o)))
            w := or(shr(8, and(w, 0xFF00FF00)), shl(8, and(w, 0x00FF00FF)))
            w := or(shr(16, w), and(shl(16, w), 0xFFFF0000))
            v := w
        }
        c.off = o + 4;
    }

    function readU64(bytes memory b, Cursor memory c) internal pure returns (uint64 v) {
        uint256 o = c.off;
        if (o + 8 > b.length) revert OutOfBounds();
        assembly {
            let w := shr(192, mload(add(add(b, 0x20), o)))
            w := or(shr(8, and(w, 0xFF00FF00FF00FF00)), shl(8, and(w, 0x00FF00FF00FF00FF)))
            w := or(shr(16, and(w, 0xFFFF0000FFFF0000)), shl(16, and(w, 0x0000FFFF0000FFFF)))
            w := or(shr(32, w), and(shl(32, w), 0xFFFFFFFF00000000))
            v := w
        }
        c.off = o + 8;
    }

    function readFp(bytes memory b, Cursor memory c) internal pure returns (uint64 v) {
        v = readU64(b, c);
        if (uint256(v) >= Goldilocks.P) revert NonCanonicalFp();
    }

    // Same bytes and same rejects as n calls to readFp.
    function readFpArray(bytes memory b, Cursor memory c, uint256 n) internal pure returns (uint256[] memory out) {
        uint256 o = c.off;
        if (o + n * 8 > b.length) revert OutOfBounds();
        bool bad;
        assembly {
            out := mload(0x40)
            mstore(out, n)
            let dst := add(out, 0x20)
            let src := add(add(b, 0x20), o)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let w := shr(192, mload(add(src, mul(i, 8))))
                w := or(shr(8, and(w, 0xFF00FF00FF00FF00)), shl(8, and(w, 0x00FF00FF00FF00FF)))
                w := or(shr(16, and(w, 0xFFFF0000FFFF0000)), shl(16, and(w, 0x0000FFFF0000FFFF)))
                w := or(shr(32, w), and(shl(32, w), 0xFFFFFFFF00000000))
                if iszero(lt(w, 0xFFFFFFFF00000001)) { bad := 1 }
                mstore(add(dst, mul(i, 32)), w)
            }
            mstore(0x40, add(dst, mul(n, 32)))
        }
        if (bad) revert NonCanonicalFp();
        c.off = o + n * 8;
    }

    function readFp2(bytes memory b, Cursor memory c) internal pure returns (Fp2 memory e) {
        e.c0 = readFp(b, c);
        e.c1 = readFp(b, c);
    }

    // A w-byte digest, left aligned, the tail past w masked to zero. The launch proof has w = 24.
    function readDigest(bytes memory b, Cursor memory c, uint256 w) internal pure returns (bytes32 d) {
        uint256 o = c.off;
        if (o + w > b.length) revert OutOfBounds();
        assembly {
            d := and(mload(add(add(b, 0x20), o)), shl(mul(8, sub(32, w)), not(0)))
        }
        c.off = o + w;
    }

    function readDigest(bytes memory b, Cursor memory c) internal pure returns (bytes32 d) {
        return readDigest(b, c, 32);
    }

    // u32 count, then count digests leaf to root. Bounds are checked before allocating.
    function readPath(bytes memory b, Cursor memory c, uint256 w)
        internal
        pure
        returns (bytes32[] memory path)
    {
        uint32 k = readU32(b, c);
        if (c.off + uint256(k) * w > b.length) revert OutOfBounds();
        path = new bytes32[](k);
        uint256 o = c.off;
        assembly {
            let src := add(add(b, 0x20), o)
            let dst := add(path, 0x20)
            let mask := shl(mul(8, sub(32, w)), not(0))
            for { let i := 0 } lt(i, k) { i := add(i, 1) } {
                mstore(add(dst, mul(i, 32)), and(mload(add(src, mul(i, w))), mask))
            }
        }
        c.off = o + uint256(k) * w;
    }

    function readPath(bytes memory b, Cursor memory c) internal pure returns (bytes32[] memory path) {
        return readPath(b, c, 32);
    }

    function skipPath(bytes memory b, Cursor memory c, uint256 w) internal pure returns (uint32 k) {
        k = readU32(b, c);
        uint256 end = c.off + uint256(k) * w;
        if (end > b.length) revert OutOfBounds();
        c.off = end;
    }

    function skipPath(bytes memory b, Cursor memory c) internal pure returns (uint32 k) {
        return skipPath(b, c, 32);
    }

    function done(bytes memory b, Cursor memory c) internal pure returns (bool) {
        return c.off == b.length;
    }
}
