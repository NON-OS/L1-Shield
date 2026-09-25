// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title StarkMerkleRef
/// @notice The Solidity twin of StarkMerkle's calldata forms, `hashWire` and `walk`, written from
///         the tree's definition with no assembly. Test-only, never deployed.
library StarkMerkleRef {
    function _cut(bytes32 d, uint256 w) internal pure returns (bytes memory o) {
        o = new bytes(w);
        for (uint256 i = 0; i < w; ++i) o[i] = d[i];
    }

    function _mask(uint256 w) internal pure returns (bytes32) {
        return bytes32(~uint256(0) << (8 * (32 - w)));
    }

    function hashWire(bytes32 tag, uint256 tagLen, bytes calldata p, uint256 off, uint256 len)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(_cut(tag, tagLen), p[off:off + len]));
    }

    function walk(bytes calldata p, uint256 off, uint256 cnt, bytes32 root, uint256 index, bytes32 leaf, uint256 w)
        internal
        pure
        returns (bool)
    {
        bytes32 node = leaf & _mask(w);
        for (uint256 j = 0; j < cnt; ++j) {
            bytes32 sib = bytes32(p[off + j * w:off + j * w + w]) & _mask(w);
            bytes memory l = _cut(index & 1 == 0 ? node : sib, w);
            bytes memory r = _cut(index & 1 == 0 ? sib : node, w);
            node = keccak256(abi.encodePacked("NONOS-STARK-MERKLE-NODE", l, r)) & _mask(w);
            index >>= 1;
        }
        return index == 0 && node == root;
    }
}
