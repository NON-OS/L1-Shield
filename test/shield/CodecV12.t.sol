// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {StarkMerkle as MK} from "../../contracts/shield/verifier/StarkMerkle.sol";
import {StarkTranscript as TS} from "../../contracts/shield/verifier/StarkTranscript.sol";
import {StarkProofReader as R} from "../../contracts/shield/StarkProofReader.sol";

/// @notice Codec v1.2 24-byte Merkle path, reader and transcript against vectors built with `cast keccak`.
/// Four leaves over 1..4: leaf_v = keccak256(DOM_LEAF || le64(v))[..24],
/// node = keccak256(DOM_NODE || left[..24] || right[..24])[..24].
contract CodecV12Test is Test {
    bytes32 internal constant LEAF0 = bytes32(hex"b7675f33387d5a3f61aca06e88f065099e1700443fc10af0");
    bytes32 internal constant LEAF1 = bytes32(hex"7e1fcab86e4b5d68b3f057f5570e84a3c7d8455d2ddd3af4");
    bytes32 internal constant LEAF2 = bytes32(hex"b27131dc42b1902225b68344aa4af6ab7ef531d85d0a4bf9");
    bytes32 internal constant LEAF3 = bytes32(hex"151cf130a22ca76d6c278a00e923e34a185091186c0a7021");
    bytes32 internal constant N01 = bytes32(hex"7c3b67983a47b4a800c544e4d55ea80ddd76511ea2f8072c");
    bytes32 internal constant N23 = bytes32(hex"b31539c6ec279e8cc870fa60644d4c7774d5d70dec84f795");
    bytes32 internal constant ROOT = bytes32(hex"a512315092b05802b5964d4735db5f67756dbb397429d652");

    function test_leafHashCutToTwentyFour() public pure {
        assertEq(MK.trunc(MK.hashLeaf(1), 24), LEAF0, "leaf 1");
        assertEq(MK.trunc(MK.hashLeaf(2), 24), LEAF1, "leaf 2");
        assertEq(MK.trunc(MK.hashLeaf(3), 24), LEAF2, "leaf 3");
        assertEq(MK.trunc(MK.hashLeaf(4), 24), LEAF3, "leaf 4");
    }

    function test_nodeHashAtTwentyFour() public pure {
        assertEq(MK.hashNode(LEAF0, LEAF1, 24), N01, "node(0,1)");
        assertEq(MK.hashNode(LEAF2, LEAF3, 24), N23, "node(2,3)");
        assertEq(MK.hashNode(N01, N23, 24), ROOT, "root");
    }

    /// The node preimage is 23 + 2w bytes, so the same children hash differently at 24 and 32.
    function test_widthChangesTheNodePreimage() public pure {
        assertTrue(MK.hashNode(LEAF0, LEAF1, 24) != MK.trunc(MK.hashNode(LEAF0, LEAF1, 32), 24));
    }

    function _path() internal pure returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = LEAF1;
        p[1] = N23;
    }

    function test_foldWalksToTheRoot() public pure {
        assertTrue(MK.verifyPath(ROOT, 0, 1, _path(), 24), "leaf 0 does not open");
    }

    /// A path that opens at width 24 does not open at width 32.
    function test_theWidthIsBinding() public pure {
        assertFalse(MK.verifyPath(ROOT, 0, 1, _path(), 32), "a 24-byte path opened at width 32");
    }

    function test_wrongIndexFails() public pure {
        assertFalse(MK.verifyPath(ROOT, 1, 1, _path(), 24), "opened at the wrong index");
    }

    /// @notice The reader takes 24 bytes and zeroes the tail, even when the next eight bytes are 0xff.
    function test_readerMasksTheTail() public pure {
        bytes memory blob = bytes.concat(bytes24(LEAF0), hex"ffffffffffffffff");
        R.Cursor memory c = R.Cursor(0);
        assertEq(R.readDigest(blob, c, 24), LEAF0, "tail leaked into the digest");
        assertEq(c.off, 24, "cursor advanced by the wrong width");
    }

    function test_readPathMasksAndStrides() public pure {
        bytes memory blob = bytes.concat(hex"02000000", bytes24(LEAF1), bytes24(N23));
        R.Cursor memory c = R.Cursor(0);
        bytes32[] memory got = R.readPath(blob, c, 24);
        assertEq(got.length, 2, "count");
        assertEq(got[0], LEAF1, "first node");
        assertEq(got[1], N23, "second node");
        assertEq(c.off, 4 + 48, "cursor");
    }

    /// @notice The transcript absorbs 24 bytes, not 24 padded back to 32.
    function test_transcriptAbsorbsTheNarrowDigest() public pure {
        TS.T memory a = TS.init("v12-selftest");
        TS.T memory b = TS.init("v12-selftest");
        TS.absorbDigest(a, ROOT, 24);
        TS.absorbDigest(b, ROOT, 32);
        assertTrue(a.state != b.state, "absorbing 24 bytes matched absorbing 32");
    }

    /// The default width is 32, so v1.1 calls are unchanged.
    function test_thirtyTwoIsUnchanged() public pure {
        TS.T memory a = TS.init("v12-selftest");
        TS.T memory b = TS.init("v12-selftest");
        TS.absorbDigest(a, ROOT);
        TS.absorbDigest(b, ROOT, 32);
        assertEq(a.state, b.state, "the default width stopped meaning 32");
        assertEq(MK.hashNode(LEAF0, LEAF1), MK.hashNode(LEAF0, LEAF1, 32), "hashNode default moved");
    }
}

/// @notice Gas of the 24-byte digest: hashing costs the same (both preimages are three keccak
/// words), and the saving is in calldata and memory.
contract CodecV12GasTest is Test {
    function _path(uint256 n) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) p[i] = MK.trunc(keccak256(abi.encode(i)), 24);
    }

    function test_foldCostsTheSameAtBothWidths() public {
        bytes32[] memory p = _path(29);
        uint256 g = gasleft();
        MK.verifyPath(bytes32(0), 0, 1, p, 24);
        uint256 at24 = g - gasleft();
        g = gasleft();
        MK.verifyPath(bytes32(0), 0, 1, p, 32);
        uint256 at32 = g - gasleft();

        console2.log("29-node fold at 24 bytes", at24);
        console2.log("29-node fold at 32 bytes", at32);
        console2.log("difference              ", at32 > at24 ? at32 - at24 : at24 - at32);

        // Three keccak words at either width.
        assertApproxEqAbs(at24, at32, 200, "the fold's cost moved with the width");
    }

    /// The saving is 17,469 digests at eight bytes each, paid as calldata.
    function test_whereTheSavingIs() public pure {
        uint256 digests = 17469;
        uint256 saved = digests * 8;
        // EIP-7623: a nonzero calldata byte is 4 tokens at 4 gas, 16 gas a byte when the floor does not bind.
        uint256 gasSaved = saved * 16;
        console2.log("bytes saved at 24 vs 32 ", saved);
        console2.log("calldata gas saved      ", gasSaved);
        assertEq(saved, 139752);
    }
}
