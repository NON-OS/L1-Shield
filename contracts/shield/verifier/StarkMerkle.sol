// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StarkFieldExt as F} from "./StarkFieldExt.sol";

/// @title StarkMerkle
/// @notice Domain-separated Keccak256 Merkle verification, matching the prover.
/// @dev Every leaf kind and the node have their own domain tag, so no leaf can be read as a node.
///      A short path leaves the index nonzero and is refused. See docs/06-merkle-and-fri.md.
library StarkMerkle {
    bytes internal constant DOM_LEAF = "NONOS-STARK-MERKLE-LEAF";
    bytes internal constant DOM_LEAF_EXT = "NONOS-STARK-MERKLE-LEAF-EXT";
    bytes internal constant DOM_NODE = "NONOS-STARK-MERKLE-NODE";
    bytes internal constant DOM_LEAF_WIDE = "NONOS-STARK-MERKLE-LEAF-WIDE"; // one leaf per trace row
    bytes internal constant DOM_LEAF_PERIODIC = "NONOS-STARK-PERIODIC-WIDE"; // one leaf per periodic row

    // Preimages are built in scratch memory past the free pointer. Assembly literals must match
    // the DOM_ constants above. Field elements are eight bytes little-endian throughout.

    /// @notice keccak256(DOM_LEAF || value)
    function hashLeaf(uint256 value) internal pure returns (bytes32 h) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, "NONOS-STARK-MERKLE-LEAF")
            mstore(add(ptr, 23), shl(192, _bswap64(value)))
            h := keccak256(ptr, 31)
            function _bswap64(w) -> r {
                w := or(shr(8, and(w, 0xFF00FF00FF00FF00)), shl(8, and(w, 0x00FF00FF00FF00FF)))
                w := or(shr(16, and(w, 0xFFFF0000FFFF0000)), shl(16, and(w, 0x0000FFFF0000FFFF)))
                r := or(shr(32, w), and(shl(32, w), 0xFFFFFFFF00000000))
            }
        }
    }

    /// @notice keccak256("NONOS-STARK-MERKLE-LEAF-PAIR" || a || b), one leaf per fold pair.
    function hashLeafPair(F.Fp2 memory a, F.Fp2 memory b) internal pure returns (bytes32 h) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, "NONOS-STARK-MERKLE-LEAF-PAIR")
            mstore(add(ptr, 28), shl(192, _bswap64(mload(a))))
            mstore(add(ptr, 36), shl(192, _bswap64(mload(add(a, 32)))))
            mstore(add(ptr, 44), shl(192, _bswap64(mload(b))))
            mstore(add(ptr, 52), shl(192, _bswap64(mload(add(b, 32)))))
            h := keccak256(ptr, 60)
            function _bswap64(w) -> r {
                w := or(shr(8, and(w, 0xFF00FF00FF00FF00)), shl(8, and(w, 0x00FF00FF00FF00FF)))
                w := or(shr(16, and(w, 0xFFFF0000FFFF0000)), shl(16, and(w, 0x0000FFFF0000FFFF)))
                r := or(shr(32, w), and(shl(32, w), 0xFFFFFFFF00000000))
            }
        }
    }

    /// @notice Open a fold pair against its shared leaf.
    function verifyPathPair(
        bytes32 root,
        uint256 index,
        F.Fp2 memory a,
        F.Fp2 memory b,
        bytes32[] memory path
    ) internal pure returns (bool) {
        return _fold(root, index, hashLeafPair(a, b), path);
    }

    /// @notice keccak256("NONOS-STARK-MERKLE-LEAF-QUAD" || a || b || c || d), one leaf per radix-4 fold.
    function hashLeafQuad(F.Fp2 memory a, F.Fp2 memory b, F.Fp2 memory c, F.Fp2 memory d)
        internal
        pure
        returns (bytes32 h)
    {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, "NONOS-STARK-MERKLE-LEAF-QUAD")
            mstore(add(ptr, 28), shl(192, _bswap64(mload(a))))
            mstore(add(ptr, 36), shl(192, _bswap64(mload(add(a, 32)))))
            mstore(add(ptr, 44), shl(192, _bswap64(mload(b))))
            mstore(add(ptr, 52), shl(192, _bswap64(mload(add(b, 32)))))
            mstore(add(ptr, 60), shl(192, _bswap64(mload(c))))
            mstore(add(ptr, 68), shl(192, _bswap64(mload(add(c, 32)))))
            mstore(add(ptr, 76), shl(192, _bswap64(mload(d))))
            mstore(add(ptr, 84), shl(192, _bswap64(mload(add(d, 32)))))
            h := keccak256(ptr, 92)
            function _bswap64(w) -> r {
                w := or(shr(8, and(w, 0xFF00FF00FF00FF00)), shl(8, and(w, 0x00FF00FF00FF00FF)))
                w := or(shr(16, and(w, 0xFFFF0000FFFF0000)), shl(16, and(w, 0x0000FFFF0000FFFF)))
                r := or(shr(32, w), and(shl(32, w), 0xFFFFFFFF00000000))
            }
        }
    }

    /// @notice Open a radix-4 fold's four values against their shared leaf, at digest width `w`.
    function verifyPathQuad(
        bytes32 root,
        uint256 index,
        F.Fp2 memory a,
        F.Fp2 memory b,
        F.Fp2 memory c,
        F.Fp2 memory d,
        bytes32[] memory path,
        uint256 w
    ) internal pure returns (bool) {
        return _fold(root, index, trunc(hashLeafQuad(a, b, c, d), w), path, w);
    }

    /// @notice keccak256(DOM_LEAF_EXT || c0 || c1)
    function hashLeafExt(F.Fp2 memory leaf) internal pure returns (bytes32 h) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, "NONOS-STARK-MERKLE-LEAF-EXT")
            mstore(add(ptr, 27), shl(192, _bswap64(mload(leaf))))
            mstore(add(ptr, 35), shl(192, _bswap64(mload(add(leaf, 32)))))
            h := keccak256(ptr, 43)
            function _bswap64(w) -> r {
                w := or(shr(8, and(w, 0xFF00FF00FF00FF00)), shl(8, and(w, 0x00FF00FF00FF00FF)))
                w := or(shr(16, and(w, 0xFFFF0000FFFF0000)), shl(16, and(w, 0x0000FFFF0000FFFF)))
                r := or(shr(32, w), and(shl(32, w), 0xFFFFFFFF00000000))
            }
        }
    }

    function hashNode(bytes32 left, bytes32 right) internal pure returns (bytes32 h) {
        return hashNode(left, right, 32);
    }

    /// @notice keccak256(DOM_NODE || left[..w] || right[..w])[..w]
    /// @dev Truncation lowers binding to the birthday bound on w bytes. 24 bytes gives 2^96.
    ///      Callers must pass the deployment's width.
    function hashNode(bytes32 left, bytes32 right, uint256 w) internal pure returns (bytes32 h) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, "NONOS-STARK-MERKLE-NODE")
            mstore(add(ptr, 23), left)
            mstore(add(ptr, add(23, w)), right)
            h := and(keccak256(ptr, add(23, mul(2, w))), shl(mul(8, sub(32, w)), not(0)))
        }
    }

    function hashLeafWide(uint256[] memory values) internal pure returns (bytes32) {
        return _hashLeafWideDom(DOM_LEAF_WIDE, values);
    }

    function hashLeafWidePeriodic(uint256[] memory values) internal pure returns (bytes32) {
        return _hashLeafWideDom(DOM_LEAF_PERIODIC, values);
    }

    /// @notice Wide leaf hashed from the wire bytes, same digest as `_hashLeafWideDom`.
    /// @dev Does no field check. The caller must also decode the same bytes with `readFpArray`.
    /// @param off Byte offset of the first element in `src`.
    /// @param n Number of field elements, eight bytes each.
    function hashLeafWideRawDom(bytes memory dom, bytes memory src, uint256 off, uint256 n)
        internal
        pure
        returns (bytes32 h)
    {
        require(off + n * 8 <= src.length, "wide leaf out of bounds");
        assembly {
            let dl := mload(dom)
            let ptr := mload(0x40)
            for { let i := 0 } lt(i, dl) { i := add(i, 32) } {
                mstore(add(ptr, i), mload(add(add(dom, 0x20), i)))
            }
            let len := mul(n, 8)
            let o := add(ptr, dl)
            let s := add(add(src, 0x20), off)
            for { let i := 0 } lt(i, len) { i := add(i, 32) } {
                mstore(add(o, i), mload(add(s, i)))
            }
            h := keccak256(ptr, add(dl, len))
        }
    }

    function hashLeafWideRaw(bytes memory src, uint256 off, uint256 n) internal pure returns (bytes32) {
        return hashLeafWideRawDom(DOM_LEAF_WIDE, src, off, n);
    }

    function hashLeafWidePeriodicRaw(bytes memory src, uint256 off, uint256 n) internal pure returns (bytes32) {
        return hashLeafWideRawDom(DOM_LEAF_PERIODIC, src, off, n);
    }

    // keccak256(dom || v0 || ... || v_{n-1}), values packed in column order
    function _hashLeafWideDom(bytes memory dom, uint256[] memory values) private pure returns (bytes32 h) {
        assembly {
            let dl := mload(dom)
            let n := mload(values)
            let ptr := mload(0x40)
            // Each store writes a full word. The next value overwrites its low 24 bytes.
            for { let i := 0 } lt(i, dl) { i := add(i, 32) } {
                mstore(add(ptr, i), mload(add(add(dom, 0x20), i)))
            }
            let o := add(ptr, dl)
            let src := add(values, 0x20)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let w := mload(add(src, mul(i, 32)))
                w := or(shr(8, and(w, 0xFF00FF00FF00FF00)), shl(8, and(w, 0x00FF00FF00FF00FF)))
                w := or(shr(16, and(w, 0xFFFF0000FFFF0000)), shl(16, and(w, 0x0000FFFF0000FFFF)))
                w := or(shr(32, w), and(shl(32, w), 0xFFFFFFFF00000000))
                mstore(add(o, mul(i, 8)), shl(192, w))
            }
            h := keccak256(ptr, add(dl, mul(n, 8)))
        }
    }

    /// @notice Verify a trace row opening against one wide leaf.
    function verifyPathWide(bytes32 root, uint256 index, uint256[] memory values, bytes32[] memory path)
        internal
        pure
        returns (bool)
    {
        return _fold(root, index, hashLeafWide(values), path);
    }

    /// @notice Verify a periodic row opening against the periodic root fixed at deployment.
    function verifyPathWidePeriodic(bytes32 root, uint256 index, uint256[] memory values, bytes32[] memory path)
        internal
        pure
        returns (bool)
    {
        return _fold(root, index, hashLeafWidePeriodic(values), path);
    }

    /// @notice Verify a base-Fp leaf's authentication path.
    function verifyPath(bytes32 root, uint256 index, uint256 leaf, bytes32[] memory path) internal pure returns (bool) {
        bytes32 node = hashLeaf(leaf);
        return _fold(root, index, node, path);
    }

    /// @notice Verify an Fp2 leaf's authentication path.
    function verifyPathExt(bytes32 root, uint256 index, F.Fp2 memory leaf, bytes32[] memory path)
        internal
        pure
        returns (bool)
    {
        bytes32 node = hashLeafExt(leaf);
        return _fold(root, index, node, path);
    }

    /// @notice Walk a path from a leaf digest the caller already has.
    function verifyLeaf(bytes32 root, uint256 index, bytes32 leaf, bytes32[] memory path)
        internal
        pure
        returns (bool)
    {
        return _fold(root, index, leaf, path);
    }

    /// @notice A digest cut to `w` bytes, left aligned, with a zero tail.
    function trunc(bytes32 h, uint256 w) internal pure returns (bytes32 o) {
        assembly {
            o := and(h, shl(mul(8, sub(32, w)), not(0)))
        }
    }

    // Width-carrying overloads: hash as the 32-byte form, cut to `w`, fold at `w`.
    function verifyPathPair(
        bytes32 root,
        uint256 index,
        F.Fp2 memory a,
        F.Fp2 memory b,
        bytes32[] memory path,
        uint256 w
    ) internal pure returns (bool) {
        return _fold(root, index, trunc(hashLeafPair(a, b), w), path, w);
    }

    function verifyPathExt(bytes32 root, uint256 index, F.Fp2 memory leaf, bytes32[] memory path, uint256 w)
        internal
        pure
        returns (bool)
    {
        return _fold(root, index, trunc(hashLeafExt(leaf), w), path, w);
    }

    function verifyPath(bytes32 root, uint256 index, uint256 leaf, bytes32[] memory path, uint256 w)
        internal
        pure
        returns (bool)
    {
        return _fold(root, index, trunc(hashLeaf(leaf), w), path, w);
    }

    function verifyPathWide(bytes32 root, uint256 index, uint256[] memory values, bytes32[] memory path, uint256 w)
        internal
        pure
        returns (bool)
    {
        return _fold(root, index, trunc(hashLeafWide(values), w), path, w);
    }

    function verifyPathWidePeriodic(
        bytes32 root,
        uint256 index,
        uint256[] memory values,
        bytes32[] memory path,
        uint256 w
    ) internal pure returns (bool) {
        return _fold(root, index, trunc(hashLeafWidePeriodic(values), w), path, w);
    }

    function verifyLeaf(bytes32 root, uint256 index, bytes32 leaf, bytes32[] memory path, uint256 w)
        internal
        pure
        returns (bool)
    {
        return _fold(root, index, trunc(leaf, w), path, w);
    }

    /// @notice The root a leaf and its path fold to. Tooling only.
    /// @dev Never use this in a verification path. A root taken from the proof lets the prover open anything.
    function foldTo(bytes32 leaf, uint256 index, bytes32[] memory path, uint256 w)
        internal
        pure
        returns (bytes32 node)
    {
        node = trunc(leaf, w);
        uint256 idx = index;
        for (uint256 i = 0; i < path.length; ++i) {
            node = (idx & 1) == 0 ? hashNode(node, path[i], w) : hashNode(path[i], node, w);
            idx >>= 1;
        }
    }

    function _fold(bytes32 root, uint256 index, bytes32 node, bytes32[] memory path) private pure returns (bool ok) {
        return _fold(root, index, node, path, 32);
    }

    // Siblings and leaf arrive left aligned and masked to `w`.
    function _fold(bytes32 root, uint256 index, bytes32 node, bytes32[] memory path, uint256 w)
        private
        pure
        returns (bool ok)
    {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, "NONOS-STARK-MERKLE-NODE")
            let n := mload(path)
            let src := add(path, 0x20)
            let idx := index
            let rightAt := add(ptr, add(23, w))
            let len := add(23, mul(2, w))
            let mask := shl(mul(8, sub(32, w)), not(0))
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                let sib := mload(add(src, mul(i, 32)))
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
    }

    // ---------------------------------------------------------------- calldata, read in place
    // The proof stays in calldata. The wire bytes of a leaf are already its limb encoding, so they are
    // copied behind the tag as they are. Preimages sit at the free pointer, unclaimed, since nothing
    // allocates between writing and hashing. Reference twin: test/shield/reference/StarkMerkleRef.sol.

    /// @dev Domain tags as left-aligned words, with their lengths in bytes.
    bytes32 internal constant TAG_LEAF_WIDE = "NONOS-STARK-MERKLE-LEAF-WIDE";
    uint256 internal constant TAG_LEAF_WIDE_LEN = 28;
    bytes32 internal constant TAG_LEAF_PERIODIC = "NONOS-STARK-PERIODIC-WIDE";
    uint256 internal constant TAG_LEAF_PERIODIC_LEN = 25;
    bytes32 internal constant TAG_LEAF_EXT = "NONOS-STARK-MERKLE-LEAF-EXT";
    uint256 internal constant TAG_LEAF_EXT_LEN = 27;
    bytes32 internal constant TAG_NODE = "NONOS-STARK-MERKLE-NODE";
    uint256 internal constant TAG_NODE_LEN = 23;

    /// @notice keccak256(tag[..tagLen] || p[off..off+len]).
    /// @dev The caller has checked off + len <= p.length. Memory at the free pointer: the tag
    ///      word at +0, the wire bytes from +tagLen, len + tagLen bytes hashed, nothing claimed.
    function hashWire(bytes32 tag, uint256 tagLen, bytes calldata p, uint256 off, uint256 len)
        internal
        pure
        returns (bytes32 h)
    {
        assembly {
            let pre := mload(0x40)
            mstore(pre, tag)
            calldatacopy(add(pre, tagLen), add(p.offset, off), len)
            h := keccak256(pre, add(tagLen, len))
        }
    }

    /// @notice Folds `leaf` up `cnt` siblings of w bytes each at p[off..] and compares with root.
    /// @dev The caller has checked off + cnt * w <= p.length. Children are masked to w bytes, so the
    ///      right child overwrites only the zero tail of the left. A short path leaves the index
    ///      nonzero and is refused.
    function walk(bytes calldata p, uint256 off, uint256 cnt, bytes32 root, uint256 index, bytes32 leaf, uint256 w)
        internal
        pure
        returns (bool ok)
    {
        assembly {
            let pre := mload(0x40)
            mstore(pre, TAG_NODE)
            let leftAt := add(pre, TAG_NODE_LEN)
            let rightAt := add(leftAt, w)
            let hl := add(TAG_NODE_LEN, shl(1, w))
            let mask := shl(shl(3, sub(32, w)), not(0))
            let node := and(leaf, mask)
            let src := add(p.offset, off)
            let fin := add(src, mul(cnt, w))
            for {} lt(src, fin) { src := add(src, w) } {
                let sib := and(calldataload(src), mask)
                switch and(index, 1)
                case 0 {
                    mstore(leftAt, node)
                    mstore(rightAt, sib)
                }
                default {
                    mstore(leftAt, sib)
                    mstore(rightAt, node)
                }
                node := and(keccak256(pre, hl), mask)
                index := shr(1, index)
            }
            ok := and(iszero(index), eq(node, root))
        }
    }
}
