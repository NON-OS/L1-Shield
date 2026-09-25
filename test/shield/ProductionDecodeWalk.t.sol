// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StarkProofReader as R} from "../../contracts/shield/StarkProofReader.sol";

/// @notice The production wide-leaf wire format: spec/production-recursive-vector.json walks
///         to its last byte with every count matching the AIR and the periodic sidecar.
contract ProductionDecodeWalkTest is Test {
    using R for bytes;

    bytes internal proof;
    uint256 internal proofLen;
    uint256 internal traceWidth;
    uint256 internal nQueries;
    uint256 internal nFolds;
    uint256 internal blowup;
    uint256 internal logEvalDomain;

    function setUp() public {
        string memory json = vm.readFile("spec/production-recursive-vector.json");
        proof = vm.parseBytes(string.concat("0x", vm.parseJsonString(json, ".proof_hex")));
        proofLen = vm.parseJsonUint(json, ".proof_len_bytes");
        traceWidth = vm.parseJsonUint(json, ".trace_width");
        nQueries = vm.parseJsonUint(json, ".n_queries");

        string memory air = vm.readFile("spec/production-air-structure.json");
        uint256 logDomain = vm.parseJsonUint(air, ".log_eval_domain");
        logEvalDomain = logDomain;
        uint256 logBlowup = vm.parseJsonUint(air, ".fri_log_blowup");
        nFolds = logDomain - logBlowup;
        blowup = 1 << logBlowup;

        assertEq(vm.parseJsonUint(air, ".n_queries"), nQueries, "artifact n_queries disagree");
        assertEq(vm.parseJsonUint(air, ".trace_width"), traceWidth, "artifact trace_width disagree");
    }

    /// The vector's header parameters match the pinned geometry.
    function test_HeaderParams() public view {
        assertEq(proof.length, proofLen, "proof_hex len != proof_len_bytes");
        // 12 queries over a 2^24 domain at rate 1/256.
        assertEq(traceWidth, 129, "trace_width");
        assertEq(nQueries, 12, "n_queries");
        assertEq(nFolds, 16, "n_folds");
        assertEq(blowup, 256, "blowup");
    }

    /// The wide-leaf layout consumes the whole proof and sidecar with no bytes left over.
    function test_WalksWideLeafLayoutAndConsumesExactly() public view {
        bytes memory p = proof; // storage → memory once
        R.Cursor memory c = R.Cursor(0);

        // trace_root, one digest for the wide-leaf commitment, then comp_root
        p.readDigest(c);
        p.readDigest(c);

        // ood_frame : u32 count (= window*width = 2*width), then count × Fp2
        uint256 oodCount = p.readU32(c);
        assertEq(oodCount, 2 * traceWidth, "ood != window*width");
        for (uint256 i = 0; i < oodCount; ++i) {
            p.readFp2(c);
        }

        // fri.roots (= n_folds), fri.final_layer (= blowup)
        assertEq(p.readU32(c), nFolds, "fri.roots != n_folds");
        for (uint256 i = 0; i < nFolds; ++i) {
            p.readDigest(c);
        }
        assertEq(p.readU32(c), blowup, "final_layer != blowup");
        for (uint256 i = 0; i < blowup; ++i) {
            p.readFp2(c);
        }

        // fri.queries : per query, n_folds layers of (a, a_path, b, b_path)
        assertEq(p.readU32(c), nQueries, "fri.queries != n_queries");
        for (uint256 q = 0; q < nQueries; ++q) {
            assertEq(p.readU32(c), nFolds, "fri query layers != n_folds");
            for (uint256 m = 0; m < nFolds; ++m) {
                p.readFp2(c);
                p.skipPath(c);
                p.readFp2(c);
                p.skipPath(c);
            }
        }

        // pow_nonce : u64
        p.readU64(c);

        // queries : per query, deep/deep_path/trace(=width)/ONE wide trace_path/comp/comp_path
        assertEq(p.readU32(c), nQueries, "queries != n_queries");
        for (uint256 q = 0; q < nQueries; ++q) {
            p.readFp2(c); // deep
            p.skipPath(c); // deep_path (Fp2 leaf)
            assertEq(p.readU32(c), traceWidth, "trace count != width");
            for (uint256 i = 0; i < traceWidth; ++i) {
                p.readFp(c); // row values
            }
            p.skipPath(c); // ONE wide trace_path
            p.readFp2(c); // comp
            p.skipPath(c); // comp_path (Fp2 leaf)
        }

        // Periodic sidecar: u32 num_periodic, num_periodic Fp2 claims, then per consistency query a
        // row of num_periodic Fp values with no length prefix and one wide periodic path.
        uint256 nPeriodic = p.readU32(c);
        assertEq(nPeriodic, 444, "sidecar num_periodic");
        for (uint256 i = 0; i < nPeriodic; ++i) {
            p.readFp2(c); // periodic_z claim
        }
        for (uint256 q = 0; q < nQueries; ++q) {
            for (uint256 i = 0; i < nPeriodic; ++i) {
                p.readFp(c); // periodic row value, count from header
            }
            // The wide periodic tree spans the evaluation domain: depth log_eval_domain.
            assertEq(p.skipPath(c), logEvalDomain, "periodic path depth");
        }

        assertTrue(p.done(c), "did not consume the production proof + sidecar exactly");
        assertEq(c.off, p.length, "trailing or truncated bytes");
    }
}
