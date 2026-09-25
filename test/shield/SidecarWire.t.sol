// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RealQueryVerify as V} from "../../contracts/shield/verifier/RealQueryVerify.sol";
import {StarkProofReader as R} from "../../contracts/shield/StarkProofReader.sol";

/// Wire layout with a periodic sidecar: claims at z, then one periodic row and opening per query.
/// File base sections carry no row. Chunk base sections end with one. The claim count must match the shape.
contract SidecarWireTest is Test {
    uint256 constant WIDTH = 4;
    uint256 constant NPER = 3;

    function _u32(uint32 v) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(v), uint8(v >> 8), uint8(v >> 16), uint8(v >> 24));
    }

    function _fp(uint64 v) internal pure returns (bytes memory o) {
        o = new bytes(8);
        for (uint256 i = 0; i < 8; ++i) o[i] = bytes1(uint8(v >> (8 * i)));
    }

    function _fp2(uint64 a, uint64 b) internal pure returns (bytes memory) {
        return bytes.concat(_fp(a), _fp(b));
    }

    function _path(uint32 d) internal pure returns (bytes memory o) {
        o = _u32(d);
        for (uint256 i = 0; i < d; ++i) o = bytes.concat(o, keccak256(abi.encode("sib", i)));
    }

    function _shape(uint256 nPeriodic) internal pure returns (V.Shape memory sh) {
        sh.nq = 1;
        sh.logDomain = 8;
        sh.logTraceLen = 4;
        sh.traceWidth = WIDTH;
        sh.nCoeffs = 4;
        sh.grindBits = 1;
        sh.cosetShift = 7;
        sh.nPeriodic = nPeriodic;
        sh.periodicRoot = keccak256("schedule");
    }

    /// A base section, which carries no periodic data at either setting.
    function _baseSection() internal pure returns (bytes memory o) {
        o = bytes.concat(_fp2(11, 12), _path(3));
        o = bytes.concat(o, _u32(uint32(WIDTH)));
        for (uint256 i = 0; i < WIDTH; ++i) o = bytes.concat(o, _fp(uint64(100 + i)));
        o = bytes.concat(o, _path(3));
        o = bytes.concat(o, _fp2(21, 22), _path(3));
    }

    /// A chunk's base section: the file's, with this query's row and opening appended.
    function _chunkSection() internal pure returns (bytes memory o) {
        o = _baseSection();
        for (uint256 j = 0; j < NPER; ++j) o = bytes.concat(o, _fp(uint64(200 + j)));
        o = bytes.concat(o, _path(3));
    }

    /// The appended sidecar: the claims, then a bare row and an opening per query.
    function _sidecar(uint256 nq) internal pure returns (bytes memory o) {
        o = _u32(uint32(NPER));
        for (uint256 j = 0; j < NPER; ++j) o = bytes.concat(o, _fp2(uint64(500 + j), uint64(600 + j)));
        for (uint256 q = 0; q < nq; ++q) {
            for (uint256 j = 0; j < NPER; ++j) o = bytes.concat(o, _fp(uint64(200 + j)));
            o = bytes.concat(o, _path(3));
        }
    }

    /// File sections without a row and chunk sections with one each tile under their own shape.
    function test_eachSectionFormTilesUnderItsOwnShape() public pure {
        bytes memory file = bytes.concat(_baseSection(), _baseSection());
        R.Cursor memory c = R.Cursor(0);
        V.skipBase(file, c, 2, _shape(0));
        assertEq(c.off, file.length, "the artifact's sections carry no row");

        bytes memory chunk = bytes.concat(_chunkSection(), _chunkSection());
        c = R.Cursor(0);
        V.skipBase(chunk, c, 2, _shape(NPER));
        assertEq(c.off, chunk.length, "a chunk's section closes with its row and opening");
    }

    /// Skipping chunk sections with the file shape overruns and reverts.
    function test_walkingAChunkWithTheFileShapeOverruns() public {
        WireHarness h = new WireHarness();
        bytes memory chunk = bytes.concat(_chunkSection(), _chunkSection());
        vm.expectRevert();
        h.skipTwo(chunk, _shape(0));
    }

    /// A claim count that differs from the deployed periodic column count is refused.
    function test_aClaimCountThatDisagreesWithTheBakeIsRefused() public {
        WireHarness h = new WireHarness();
        bytes memory sidecar = _sidecar(0);
        vm.expectRevert(abi.encodeWithSelector(V.PeriodicCountMismatch.selector, NPER));
        h.readClaims(sidecar, _shape(NPER + 1));
    }

    /// The matching count reads every claim.
    function test_theHonestCountReadsEveryClaim() public {
        WireHarness h = new WireHarness();
        assertEq(h.readClaims(_sidecar(0), _shape(NPER)), NPER, "every claim");
    }
}

contract WireHarness {
    function skipTwo(bytes memory sections, V.Shape memory sh) external pure {
        R.Cursor memory c = R.Cursor(0);
        V.skipBase(sections, c, 2, sh);
    }

    function readClaims(bytes memory sidecar, V.Shape memory sh) external pure returns (uint256) {
        R.Cursor memory c = R.Cursor(0);
        uint256 n = R.readU32(sidecar, c);
        if (n != sh.nPeriodic) revert V.PeriodicCountMismatch(n);
        return n;
    }
}
