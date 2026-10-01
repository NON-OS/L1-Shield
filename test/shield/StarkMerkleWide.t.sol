// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";
import {StarkMerkle as MK} from "../../contracts/shield/verifier/StarkMerkle.sol";

/// @dev Harness so the internal library functions are reachable from tests.
contract WideMerkleHarness {
    function leaf(uint256[] memory v) external pure returns (bytes32) {
        return MK.hashLeafWide(v);
    }

    function node(bytes32 a, bytes32 b) external pure returns (bytes32) {
        return MK.hashNode(a, b);
    }

    function verifyWide(bytes32 root, uint256 index, uint256[] memory v, bytes32[] memory path)
        external
        pure
        returns (bool)
    {
        return MK.verifyPathWide(root, index, v, path);
    }
}

/// @notice Validates the wide-leaf trace commit, leaf = keccak256(
///         "NONOS-STARK-MERKLE-LEAF-WIDE" ‖ v0..v_{n-1}) with 8-byte LE values
///         and one-path authentication, the production trace-opening shape.
contract StarkMerkleWideTest is Test {
    WideMerkleHarness internal h;

    function setUp() public {
        h = new WideMerkleHarness();
    }

    /// @dev Independent reference: build the exact preimage and keccak it.
    function _refLeaf(uint256[] memory v) internal pure returns (bytes32) {
        bytes memory dom = "NONOS-STARK-MERKLE-LEAF-WIDE";
        bytes memory buf = new bytes(dom.length + v.length * 8);
        uint256 o = 0;
        for (uint256 i = 0; i < dom.length; ++i) {
            buf[o++] = dom[i];
        }
        for (uint256 i = 0; i < v.length; ++i) {
            for (uint256 b = 0; b < 8; ++b) {
                buf[o++] = bytes1(uint8(v[i] >> (8 * b)));
            }
        }
        return keccak256(buf);
    }

    function _row(uint256 seed, uint256 n) internal pure returns (uint256[] memory v) {
        v = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            v[i] = uint256(keccak256(abi.encode(seed, i))) % F.P; // canonical Goldilocks
        }
    }

    function testFuzz_LeafMatchesReferenceEncoding(uint256 seed, uint8 rawN) public view {
        uint256 n = bound(uint256(rawN), 1, 86);
        uint256[] memory v = _row(seed, n);
        assertEq(h.leaf(v), _refLeaf(v), "wide leaf != reference keccak preimage");
    }

    function test_LeafDependsOnEveryColumn() public view {
        uint256[] memory v = _row(1, 86);
        bytes32 base = h.leaf(v);
        for (uint256 j = 0; j < 86; ++j) {
            uint256[] memory w = _row(1, 86);
            w[j] = w[j] + 1;
            assertTrue(h.leaf(w) != base, "leaf insensitive to a column");
        }
    }

    function test_VerifyWidePath_AcceptsAndRejects() public view {
        // A 2-leaf tree: leaf0 = wide(v0) at index 0, leaf1 = wide(v1).
        uint256[] memory v0 = _row(10, 86);
        uint256[] memory v1 = _row(20, 86);
        bytes32 leaf1 = h.leaf(v1);
        bytes32 root = h.node(h.leaf(v0), leaf1);

        bytes32[] memory path = new bytes32[](1);
        path[0] = leaf1;
        assertTrue(h.verifyWide(root, 0, v0, path), "honest wide opening rejected");

        // A tampered value changes the leaf, so the path fails.
        uint256[] memory bad = _row(10, 86);
        bad[42] = bad[42] + 1;
        assertFalse(h.verifyWide(root, 0, bad, path), "tampered wide opening accepted");

        // The wrong index fails.
        assertFalse(h.verifyWide(root, 1, v0, path), "wrong index accepted");
    }
}
