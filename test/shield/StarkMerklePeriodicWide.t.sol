// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";
import {StarkMerkle as MK} from "../../contracts/shield/verifier/StarkMerkle.sol";

/// @dev Harness so the internal library functions are reachable from tests.
contract PeriodicWideHarness {
    function leaf(uint256[] memory v) external pure returns (bytes32) {
        return MK.hashLeafWidePeriodic(v);
    }

    function traceLeaf(uint256[] memory v) external pure returns (bytes32) {
        return MK.hashLeafWide(v);
    }

    function node(bytes32 a, bytes32 b) external pure returns (bytes32) {
        return MK.hashNode(a, b);
    }

    function verifyPeriodic(bytes32 root, uint256 index, uint256[] memory v, bytes32[] memory path)
        external
        pure
        returns (bool)
    {
        return MK.verifyPathWidePeriodic(root, index, v, path);
    }
}

/// @notice The periodic wide leaf: keccak256("NONOS-STARK-PERIODIC-WIDE" ‖ v0..v_{P-1}), 8-byte LE
///         values, one leaf per eval-domain row, authenticated against the baked periodic root.
contract StarkMerklePeriodicWideTest is Test {
    PeriodicWideHarness internal h;

    function setUp() public {
        h = new PeriodicWideHarness();
    }

    /// Independent reference: build the preimage and keccak it.
    function _refLeaf(uint256[] memory v) internal pure returns (bytes32) {
        bytes memory dom = "NONOS-STARK-PERIODIC-WIDE";
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

    /// The periodic leaf matches the reference preimage hash for any P.
    function testFuzz_PeriodicLeafMatchesReference(uint256 seed, uint16 rawP) public view {
        // the format is P-agnostic, and P reaches past 100 periodic columns
        uint256 p = bound(uint256(rawP), 1, 200);
        uint256[] memory v = _row(seed, p);
        assertEq(h.leaf(v), _refLeaf(v), "periodic wide leaf != reference keccak preimage");
    }

    /// The same values hash differently as a periodic leaf and as a trace leaf.
    function test_PeriodicLeafDistinctFromTraceLeaf() public view {
        uint256[] memory v = _row(7, 120);
        assertTrue(h.leaf(v) != h.traceLeaf(v), "periodic and trace wide leaves collide");
    }

    /// Changing any one column changes the periodic leaf.
    function test_PeriodicLeafDependsOnEveryColumn() public view {
        uint256[] memory v = _row(1, 120);
        bytes32 base = h.leaf(v);
        for (uint256 j = 0; j < 120; ++j) {
            uint256[] memory w = _row(1, 120);
            w[j] = w[j] + 1;
            assertTrue(h.leaf(w) != base, "periodic leaf insensitive to a column");
        }
    }

    /// An honest periodic opening verifies, a tampered value or wrong index does not.
    function test_VerifyPeriodicPath_AcceptsAndRejects() public view {
        // A 2-leaf tree: leaf0 = periodic(v0) at index 0, leaf1 = periodic(v1).
        uint256[] memory v0 = _row(10, 120);
        uint256[] memory v1 = _row(20, 120);
        bytes32 leaf1 = h.leaf(v1);
        bytes32 root = h.node(h.leaf(v0), leaf1);

        bytes32[] memory path = new bytes32[](1);
        path[0] = leaf1;
        assertTrue(h.verifyPeriodic(root, 0, v0, path), "honest periodic opening rejected");

        // A tampered value changes the leaf, so the path fails.
        uint256[] memory bad = _row(10, 120);
        bad[57] = bad[57] + 1;
        assertFalse(h.verifyPeriodic(root, 0, bad, path), "tampered periodic opening accepted");

        // The wrong index fails.
        assertFalse(h.verifyPeriodic(root, 1, v0, path), "wrong index accepted");
    }
}
