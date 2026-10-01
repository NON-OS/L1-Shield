// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DiffBase} from "./DiffBase.sol";
import {StarkMerkle as MK} from "../../../contracts/shield/verifier/StarkMerkle.sol";
import {StarkMerkleRef as MR} from "../reference/StarkMerkleRef.sol";

interface IMerkleCd {
    function hashWire(bytes32 tag, uint256 tagLen, bytes calldata p, uint256 off, uint256 len)
        external
        pure
        returns (bytes32);
    function walk(bytes calldata p, uint256 off, uint256 cnt, bytes32 root, uint256 index, bytes32 leaf, uint256 w)
        external
        pure
        returns (bool);
}

contract MerkleYul is IMerkleCd {
    function hashWire(bytes32 tag, uint256 tagLen, bytes calldata p, uint256 off, uint256 len)
        external
        pure
        returns (bytes32)
    {
        return MK.hashWire(tag, tagLen, p, off, len);
    }

    function walk(bytes calldata p, uint256 off, uint256 cnt, bytes32 root, uint256 index, bytes32 leaf, uint256 w)
        external
        pure
        returns (bool)
    {
        return MK.walk(p, off, cnt, root, index, leaf, w);
    }
}

contract MerkleRef is IMerkleCd {
    function hashWire(bytes32 tag, uint256 tagLen, bytes calldata p, uint256 off, uint256 len)
        external
        pure
        returns (bytes32)
    {
        return MR.hashWire(tag, tagLen, p, off, len);
    }

    function walk(bytes calldata p, uint256 off, uint256 cnt, bytes32 root, uint256 index, bytes32 leaf, uint256 w)
        external
        pure
        returns (bool)
    {
        return MR.walk(p, off, cnt, root, index, leaf, w);
    }
}

/// StarkMerkle's calldata forms against their Solidity twin.
contract StarkMerkleDiffTest is DiffBase {
    address internal y;
    address internal r;

    function setUp() public {
        y = address(new MerkleYul());
        r = address(new MerkleRef());
    }

    function _tag(uint256 k) internal pure returns (bytes32 t, uint256 len) {
        k %= 4;
        if (k == 0) return (MK.TAG_LEAF_WIDE, MK.TAG_LEAF_WIDE_LEN);
        if (k == 1) return (MK.TAG_LEAF_PERIODIC, MK.TAG_LEAF_PERIODIC_LEN);
        if (k == 2) return (MK.TAG_LEAF_EXT, MK.TAG_LEAF_EXT_LEN);
        return (MK.TAG_NODE, MK.TAG_NODE_LEN);
    }

    /// Every domain tag over any stretch of wire, including the empty one and one ending at the
    /// last byte.
    function testFuzz_hashWire(uint256 k, bytes memory p, uint256 a, uint256 b) public view {
        (bytes32 t, uint256 tl) = _tag(k);
        uint256 off = p.length == 0 ? 0 : a % (p.length + 1);
        uint256 len = (p.length - off) == 0 ? 0 : b % (p.length - off + 1);
        _same(y, r, abi.encodeCall(IMerkleCd.hashWire, (t, tl, p, off, len)));
    }

    /// The tags the Yul keeps as words are the strings StarkMerkle's memory forms hash.
    function test_tagsAreTheDomainStrings() public pure {
        assertEq(_cut(MK.TAG_LEAF_WIDE, MK.TAG_LEAF_WIDE_LEN), MK.DOM_LEAF_WIDE);
        assertEq(_cut(MK.TAG_LEAF_PERIODIC, MK.TAG_LEAF_PERIODIC_LEN), MK.DOM_LEAF_PERIODIC);
        assertEq(_cut(MK.TAG_LEAF_EXT, MK.TAG_LEAF_EXT_LEN), MK.DOM_LEAF_EXT);
        assertEq(_cut(MK.TAG_NODE, MK.TAG_NODE_LEN), MK.DOM_NODE);
    }

    function _cut(bytes32 d, uint256 n) internal pure returns (bytes memory o) {
        o = new bytes(n);
        for (uint256 i = 0; i < n; ++i) o[i] = d[i];
    }

    struct Path {
        bytes wire;
        bytes32 root;
        uint256 index;
        bytes32 leaf;
        uint256 w;
        uint256 depth;
    }

    // An honest path of `depth` random siblings, behind `pad` bytes of unrelated wire.
    function _path(uint256 seed, uint256 depth, uint256 pad, bool wide) internal pure returns (Path memory t) {
        t.w = wide ? 32 : 24;
        t.depth = depth;
        t.index = depth == 0 ? 0 : uint256(keccak256(abi.encode(seed, "i"))) % (uint256(1) << depth);
        t.leaf = keccak256(abi.encode(seed, "leaf"));
        t.wire = new bytes(pad);
        bytes32 mask = bytes32(~uint256(0) << (8 * (32 - t.w)));
        bytes32 node = t.leaf & mask;
        uint256 idx = t.index;
        for (uint256 d = 0; d < depth; ++d) {
            bytes32 sib = keccak256(abi.encode(seed, d));
            t.wire = bytes.concat(t.wire, _cut(sib, t.w));
            bytes memory l = _cut((idx & 1) == 0 ? node : sib & mask, t.w);
            bytes memory rr = _cut((idx & 1) == 0 ? sib & mask : node, t.w);
            node = keccak256(abi.encodePacked("NONOS-STARK-MERKLE-NODE", l, rr)) & mask;
            idx >>= 1;
        }
        t.root = node;
    }

    function _walk(Path memory t, uint256 pad) internal view returns (bool) {
        (, bytes memory out) =
            _same(y, r, abi.encodeCall(IMerkleCd.walk, (t.wire, pad, t.depth, t.root, t.index, t.leaf, t.w)));
        return abi.decode(out, (bool));
    }

    /// Honest paths of every depth up to 32 open on both.
    function testFuzz_honestPathOpens(uint256 seed, uint8 depth, uint8 pad, bool wide) public view {
        Path memory t = _path(seed, depth % 33, pad % 40, wide);
        assertTrue(_walk(t, pad % 40));
    }

    /// One bit flipped in any sibling, the leaf, the root or the index: both refuse. A flip in a
    /// sibling's bytes past w is not read, and both agree on that too.
    function testFuzz_bentPath(uint256 seed, uint8 depth, uint256 at, uint8 kind, bool wide) public view {
        Path memory t = _path(seed, 1 + depth % 32, 0, wide);
        uint256 k = kind % 4;
        if (k == 0) t.wire[at % t.wire.length] ^= 0x01;
        if (k == 1) t.leaf ^= bytes32(uint256(1) << (255 - (at % (8 * t.w))));
        if (k == 2) t.root ^= bytes32(uint256(1) << (255 - (at % (8 * t.w))));
        if (k == 3) t.index ^= uint256(1) << (at % 40);
        assertFalse(_walk(t, 0));
    }

    /// A path one short or one long for its index does not land on the root.
    function testFuzz_wrongLength(uint256 seed, uint8 depth, bool wide) public view {
        Path memory t = _path(seed, 2 + depth % 30, 0, wide);
        t.index |= uint256(1) << t.depth;
        assertFalse(_walk(t, 0));
    }
}
