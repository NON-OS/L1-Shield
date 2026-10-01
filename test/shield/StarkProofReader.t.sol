// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StarkProofReader} from "../../contracts/shield/StarkProofReader.sol";

/// @notice The `StarkProofExt` parser on the 41,408-byte engine-level vector in
///         spec/engine-selftest.json. Covers parsing only and verifies nothing.
contract StarkProofReaderTest is Test {
    using StarkProofReader for bytes;

    bytes internal proof;
    // params from spec/engine-selftest.json.
    uint32 internal nFolds;
    uint32 internal nQueries;
    uint32 internal width;
    uint32 internal blowup;
    uint256 internal proofLen;

    function setUp() public {
        string memory json = vm.readFile("spec/engine-selftest.json");
        string memory hexStr = vm.parseJsonString(json, ".proof_hex");
        proof = vm.parseBytes(string.concat("0x", hexStr));
        proofLen = vm.parseJsonUint(json, ".proof_len_bytes");

        nFolds = uint32(vm.parseJsonUint(json, ".params.n_folds"));
        nQueries = uint32(vm.parseJsonUint(json, ".params.n_queries"));
        width = uint32(vm.parseJsonUint(json, ".params.trace_width"));
        blowup = uint32(1) << uint32(vm.parseJsonUint(json, ".params.log_blowup")); // final layer = blowup
    }

    /// The vector's byte length matches its declared proof_len_bytes.
    function test_VectorLengthMatchesHeader() public view {
        assertEq(proof.length, proofLen, "proof_hex length != proof_len_bytes");
        assertEq(proof.length, 41408, "expected 41,408-byte conservation vector");
    }

    /// @notice Walks the full `StarkProofExt` layout and asserts it consumes the
    ///         entire blob with every declared count matching `params`.
    function test_WalksFullLayoutAndConsumesExactly() public view {
        bytes memory proof_ = proof; // one storage-to-memory copy for the whole walk
        StarkProofReader.Cursor memory c = StarkProofReader.Cursor(0);

        // trace_roots : u32 count, then count × digest
        uint32 traceRootCount = proof_.readU32(c);
        assertGt(traceRootCount, 0, "no trace roots");
        for (uint256 i = 0; i < traceRootCount; ++i) {
            proof_.readDigest(c);
        }

        // comp_root : digest
        proof_.readDigest(c);

        // ood_frame : u32 count, then count × Fp2
        uint32 oodCount = proof_.readU32(c);
        assertGt(oodCount, 0, "empty ood frame");
        for (uint256 i = 0; i < oodCount; ++i) {
            proof_.readFp2(c);
        }

        // fri.roots : u32 count (= n_folds), then count × digest
        uint32 friRootCount = proof_.readU32(c);
        assertEq(friRootCount, nFolds, "fri.roots count != n_folds");
        for (uint256 i = 0; i < friRootCount; ++i) {
            proof_.readDigest(c);
        }

        // fri.final_layer : u32 count (= blowup), then count × Fp2
        uint32 finalCount = proof_.readU32(c);
        assertEq(finalCount, blowup, "final_layer count != blowup");
        for (uint256 i = 0; i < finalCount; ++i) {
            proof_.readFp2(c);
        }

        // fri.queries : u32 count (= n_queries), per query n_folds layers of (a, a_path, b, b_path)
        uint32 friQueryCount = proof_.readU32(c);
        assertEq(friQueryCount, nQueries, "fri.queries count != n_queries");
        for (uint256 q = 0; q < friQueryCount; ++q) {
            uint32 layers = proof_.readU32(c);
            assertEq(layers, nFolds, "fri query layers != n_folds");
            for (uint256 l = 0; l < layers; ++l) {
                proof_.readFp2(c); // a
                proof_.skipPath(c); // a_path
                proof_.readFp2(c); // b
                proof_.skipPath(c); // b_path
            }
        }

        // pow_nonce : u64
        proof_.readU64(c);

        // queries : u32 count (= n_queries), per query deep/deep_path/trace/trace_paths/comp/comp_path
        uint32 queryCount = proof_.readU32(c);
        assertEq(queryCount, nQueries, "queries count != n_queries");
        for (uint256 q = 0; q < queryCount; ++q) {
            proof_.readFp2(c); // deep
            proof_.skipPath(c); // deep_path (Fp2 leaf)

            uint32 traceCount = proof_.readU32(c);
            assertEq(traceCount, width, "trace count != width");
            for (uint256 i = 0; i < traceCount; ++i) {
                proof_.readFp(c);
            }

            uint32 tracePathCount = proof_.readU32(c);
            assertEq(tracePathCount, width, "trace_paths count != width");
            for (uint256 i = 0; i < tracePathCount; ++i) {
                proof_.skipPath(c); // base Fp leaf path
            }

            proof_.readFp2(c); // comp
            proof_.skipPath(c); // comp_path (Fp2 leaf)
        }

        // The layout consumes every byte of the blob, no more and no less.
        assertTrue(proof_.done(c), "did not consume the proof exactly");
        assertEq(c.off, proof_.length, "trailing or truncated bytes");
    }

    /// @notice A proof one byte short reverts.
    function test_TruncatedProofReverts() public {
        bytes memory shortProof = new bytes(proof.length - 1);
        for (uint256 i = 0; i < shortProof.length; ++i) {
            shortProof[i] = proof[i];
        }
        StarkProofReader.Cursor memory c = StarkProofReader.Cursor(0);
        // Walking will eventually run past the end.
        vm.expectRevert(); // OutOfBounds somewhere in the walk
        this.walkExternal(shortProof, c);
    }

    /// @dev External wrapper so expectRevert can catch the library revert.
    function walkExternal(bytes memory b, StarkProofReader.Cursor memory c) external pure {
        uint32 traceRootCount = StarkProofReader.readU32(b, c);
        for (uint256 i = 0; i < traceRootCount; ++i) {
            StarkProofReader.readDigest(b, c);
        }
        StarkProofReader.readDigest(b, c);
        uint32 oodCount = StarkProofReader.readU32(b, c);
        for (uint256 i = 0; i < oodCount; ++i) {
            StarkProofReader.readFp2(b, c);
        }
        uint32 friRootCount = StarkProofReader.readU32(b, c);
        for (uint256 i = 0; i < friRootCount; ++i) {
            StarkProofReader.readDigest(b, c);
        }
        uint32 finalCount = StarkProofReader.readU32(b, c);
        for (uint256 i = 0; i < finalCount; ++i) {
            StarkProofReader.readFp2(b, c);
        }
        uint32 friQueryCount = StarkProofReader.readU32(b, c);
        for (uint256 q = 0; q < friQueryCount; ++q) {
            uint32 layers = StarkProofReader.readU32(b, c);
            for (uint256 l = 0; l < layers; ++l) {
                StarkProofReader.readFp2(b, c);
                StarkProofReader.skipPath(b, c);
                StarkProofReader.readFp2(b, c);
                StarkProofReader.skipPath(b, c);
            }
        }
        StarkProofReader.readU64(b, c);
        uint32 queryCount = StarkProofReader.readU32(b, c);
        for (uint256 q = 0; q < queryCount; ++q) {
            StarkProofReader.readFp2(b, c);
            StarkProofReader.skipPath(b, c);
            uint32 traceCount = StarkProofReader.readU32(b, c);
            for (uint256 i = 0; i < traceCount; ++i) {
                StarkProofReader.readFp(b, c);
            }
            uint32 tracePathCount = StarkProofReader.readU32(b, c);
            for (uint256 i = 0; i < tracePathCount; ++i) {
                StarkProofReader.skipPath(b, c);
            }
            StarkProofReader.readFp2(b, c);
            StarkProofReader.skipPath(b, c);
        }
    }
}
