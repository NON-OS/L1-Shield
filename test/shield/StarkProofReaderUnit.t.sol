// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StarkProofReader as R} from "../../contracts/shield/StarkProofReader.sol";

/// @dev External harness so cheatcode expectRevert catches the library's reverts
///      and so each primitive's guard branch is exercised directly.
contract ReaderHarness {
    function readU32At(bytes memory b, uint256 off) external pure returns (uint32) {
        R.Cursor memory c = R.Cursor(off);
        return R.readU32(b, c);
    }

    function readU64At(bytes memory b, uint256 off) external pure returns (uint64) {
        R.Cursor memory c = R.Cursor(off);
        return R.readU64(b, c);
    }

    function readFpAt(bytes memory b, uint256 off) external pure returns (uint64) {
        R.Cursor memory c = R.Cursor(off);
        return R.readFp(b, c);
    }

    function readDigestAt(bytes memory b, uint256 off) external pure returns (bytes32) {
        R.Cursor memory c = R.Cursor(off);
        return R.readDigest(b, c);
    }

    function readPathAt(bytes memory b, uint256 off) external pure returns (uint256) {
        R.Cursor memory c = R.Cursor(off);
        return R.readPath(b, c).length;
    }

    function skipPathAt(bytes memory b, uint256 off) external pure returns (uint32) {
        R.Cursor memory c = R.Cursor(off);
        return R.skipPath(b, c);
    }
}

/// @notice Each StarkProofReader primitive on its own: reads, bounds guards and the canonical guard.
contract StarkProofReaderUnitTest is Test {
    ReaderHarness internal h;

    function setUp() public {
        h = new ReaderHarness();
    }

    // -------- success (canonical happy paths) --------

    function test_ReadU32_LittleEndian() public view {
        // 0x04030201 little-endian = bytes 01 02 03 04.
        assertEq(h.readU32At(hex"01020304", 0), 0x04030201);
    }

    function test_ReadU64_LittleEndian() public view {
        assertEq(h.readU64At(hex"0100000000000000", 0), 1);
    }

    function test_ReadFp_Canonical() public view {
        assertEq(h.readFpAt(hex"0700000000000000", 0), 7);
    }

    function test_ReadDigest_ReadsThirtyTwoBytes() public view {
        bytes32 want = keccak256("x");
        assertEq(h.readDigestAt(abi.encodePacked(want), 0), want);
    }

    function test_ReadPath_And_SkipPath() public view {
        // u32 count = 2, then 2 × 32-byte digests.
        bytes memory p = abi.encodePacked(uint8(2), uint8(0), uint8(0), uint8(0), keccak256("a"), keccak256("b"));
        assertEq(h.readPathAt(p, 0), 2);
        assertEq(h.skipPathAt(p, 0), 2);
    }

    // -------- out-of-bounds guards --------

    function test_ReadU32_RevertsOutOfBounds() public {
        vm.expectRevert(R.OutOfBounds.selector);
        h.readU32At(hex"010203", 0); // only 3 bytes
    }

    function test_ReadU64_RevertsOutOfBounds() public {
        vm.expectRevert(R.OutOfBounds.selector);
        h.readU64At(hex"01020304050607", 0); // only 7 bytes
    }

    function test_ReadDigest_RevertsOutOfBounds() public {
        vm.expectRevert(R.OutOfBounds.selector);
        h.readDigestAt(new bytes(31), 0);
    }

    function test_ReadPath_RevertsOnOversizedCount() public {
        // count = 5 but no digest bytes follow, so 5*32 bytes run past the end.
        vm.expectRevert(R.OutOfBounds.selector);
        h.readPathAt(hex"05000000", 0);
    }

    function test_SkipPath_RevertsOnOversizedCount() public {
        vm.expectRevert(R.OutOfBounds.selector);
        h.skipPathAt(hex"05000000", 0);
    }

    // -------- non-canonical field guard --------

    function test_ReadFp_RevertsOnNonCanonical() public {
        // 0xFFFFFFFF00000001 = p, little-endian = 01 00 00 00 FF FF FF FF.
        vm.expectRevert(R.NonCanonicalFp.selector);
        h.readFpAt(hex"01000000ffffffff", 0);
    }
}
