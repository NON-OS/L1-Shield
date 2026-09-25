// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";
import {StarkTranscript as TS} from "../../contracts/shield/verifier/StarkTranscript.sol";
import {StarkProofReader as R} from "../../contracts/shield/StarkProofReader.sol";

/// @notice Every challenge of the two-transcript replay over the real vector equals the
///         oracle in spec/reference/intermediates.json, draw by draw.
contract ProductionTranscriptTest is Test {
    uint256 internal constant N = 16777216; // 2^24 eval domain (log_eval_domain 24)
    uint256 internal constant T = 4096; // 2^12 trace len (log_trace_len 12)
    uint256 internal constant SHIFT = 7;
    uint256 internal constant NUM_COEFFS = 217; // num_transition 89 + num_boundary 128
    uint256 internal constant DEEP_LEN = 703; // 259 (width*window+1) + 444 periodic claims
    uint256 internal constant N_PERIODIC = 444;
    uint256 internal constant N_FOLDS = 16; // log_eval_domain 24 - fri_log_blowup 8
    uint256 internal constant BLOWUP = 256; // 2^fri_log_blowup
    uint256 internal constant N_QUERIES = 12;

    // parsed from the vector (transcript-relevant fields)
    bytes32 internal traceRoot;
    bytes32 internal compRoot;
    F.Fp2[] internal ood; // 258
    bytes32[] internal friRoots; // 16
    F.Fp2[] internal finalLayer; // 256
    uint64 internal powNonce;

    // oracle
    F.Fp2[] internal oCoeffs;
    F.Fp2[] internal oDeepCoeffs;
    F.Fp2[] internal oPz; // 444 periodic claims (== oracle periodic_z)
    F.Fp2[] internal oBetas;
    F.Fp2 internal oZ;
    uint256[] internal oFri;
    uint256[] internal oCons;

    function setUp() public {
        _parseVector();
        _parseOracle();
    }

    function test_TranscriptMatchesOracle() public view {
        TS.T memory ts = TS.init("NONOS-STARK-EXT");
        TS.absorbDigest(ts, traceRoot); // ONE wide-leaf trace root

        for (uint256 i = 0; i < NUM_COEFFS; ++i) {
            _eq(TS.challengeFp2(ts), oCoeffs[i], "coeff");
        }
        TS.absorbDigest(ts, compRoot);
        F.Fp2 memory z = _drawOod(ts);
        _eq(z, oZ, "z");
        for (uint256 i = 0; i < ood.length; ++i) {
            TS.absorbFp(ts, ood[i].c0);
            TS.absorbFp(ts, ood[i].c1);
        }
        // Preprocessed-periodic sidecar: absorb the 444 periodic-column claims at z
        // between the ood-frame absorb and the DEEP draw.
        for (uint256 i = 0; i < N_PERIODIC; ++i) {
            TS.absorbFp(ts, oPz[i].c0);
            TS.absorbFp(ts, oPz[i].c1);
        }
        for (uint256 i = 0; i < DEEP_LEN; ++i) {
            _eq(TS.challengeFp2(ts), oDeepCoeffs[i], "deep_coeff");
        }

        // Independent FRI transcript: betas, PoW, query indices.
        _checkFri();

        // Back on the STARK transcript: absorb deep root, draw consistency indices.
        TS.absorbDigest(ts, friRoots[0]);
        for (uint256 i = 0; i < N_QUERIES; ++i) {
            assertEq(TS.challengeIndex(ts, N), oCons[i], "consistency index");
        }
    }

    /// @dev One flipped bit in the trace root changes the first drawn coefficient.
    function test_TamperedTraceRootBreaksChain() public view {
        TS.T memory ts = TS.init("NONOS-STARK-EXT");
        TS.absorbDigest(ts, bytes32(uint256(traceRoot) ^ 1));
        F.Fp2 memory c0 = TS.challengeFp2(ts);
        require(c0.c0 != oCoeffs[0].c0 || c0.c1 != oCoeffs[0].c1, "tamper did not perturb the chain");
    }

    function _checkFri() internal view {
        TS.T memory tf = TS.init("NONOS-STARK-FRI-EXT");
        for (uint256 m = 0; m < N_FOLDS; ++m) {
            TS.absorbDigest(tf, friRoots[m]);
            _eq(TS.challengeFp2(tf), oBetas[m], "beta");
        }
        for (uint256 i = 0; i < finalLayer.length; ++i) {
            TS.absorbFp(tf, finalLayer[i].c0);
            TS.absorbFp(tf, finalLayer[i].c1);
        }
        assertTrue(TS.verifyPow(tf, powNonce, 16), "pow");
        for (uint256 i = 0; i < N_QUERIES; ++i) {
            assertEq(TS.challengeIndex(tf, N), oFri[i], "fri index");
        }
    }

    /// @dev draw_ood_point_ext: z = challenge_fp2, reject z^n==shift^n or z^t==1.
    function _drawOod(TS.T memory ts) internal pure returns (F.Fp2 memory z) {
        F.Fp2 memory shiftN = F.fromBase(F.fpPow(SHIFT, N));
        z = TS.challengeFp2(ts);
        while (F.eq(F.pow(z, N), shiftN) || F.eq(F.pow(z, T), F.one())) {
            z = TS.challengeFp2(ts);
        }
    }

    function _eq(F.Fp2 memory got, F.Fp2 memory want, string memory tag) internal pure {
        require(got.c0 == want.c0 && got.c1 == want.c1, tag);
    }

    function _parseVector() internal {
        bytes memory p = vm.parseBytes(
            string.concat("0x", vm.parseJsonString(vm.readFile("spec/production-recursive-vector.json"), ".proof_hex"))
        );
        R.Cursor memory c = R.Cursor(0);
        traceRoot = R.readDigest(p, c);
        compRoot = R.readDigest(p, c);
        uint256 oodCount = R.readU32(p, c);
        for (uint256 i = 0; i < oodCount; ++i) {
            ood.push(_fp2(R.readFp2(p, c)));
        }
        uint256 rc = R.readU32(p, c);
        for (uint256 i = 0; i < rc; ++i) {
            friRoots.push(R.readDigest(p, c));
        }
        uint256 fc = R.readU32(p, c);
        for (uint256 i = 0; i < fc; ++i) {
            finalLayer.push(_fp2(R.readFp2(p, c)));
        }
        // walk past fri.queries to reach pow_nonce
        uint256 fq = R.readU32(p, c);
        for (uint256 q = 0; q < fq; ++q) {
            uint256 layers = R.readU32(p, c);
            for (uint256 m = 0; m < layers; ++m) {
                R.readFp2(p, c);
                R.skipPath(p, c);
                R.readFp2(p, c);
                R.skipPath(p, c);
            }
        }
        powNonce = R.readU64(p, c);
    }

    function _fp2(R.Fp2 memory e) internal pure returns (F.Fp2 memory) {
        return F.Fp2(uint256(e.c0), uint256(e.c1));
    }

    function _parseOracle() internal {
        string memory j = vm.readFile("spec/reference/intermediates.json");
        _readFp2Array(j, ".coeffs", NUM_COEFFS, oCoeffs);
        _readFp2Array(j, ".deep_coeffs", DEEP_LEN, oDeepCoeffs);
        _readFp2Array(j, ".periodic_z", N_PERIODIC, oPz);
        _readFp2Array(j, ".betas", N_FOLDS, oBetas);
        oZ = F.Fp2(_u(j, ".z[0]"), _u(j, ".z[1]"));
        oFri = _readUintArray(j, ".fri_query_indices", N_QUERIES);
        oCons = _readUintArray(j, ".consistency_query_indices", N_QUERIES);
    }

    function _readFp2Array(string memory j, string memory path, uint256 len, F.Fp2[] storage dst) internal {
        for (uint256 i = 0; i < len; ++i) {
            string memory pre = string.concat(path, "[", vm.toString(i), "]");
            dst.push(F.Fp2(_u(j, string.concat(pre, "[0]")), _u(j, string.concat(pre, "[1]"))));
        }
    }

    function _readUintArray(string memory j, string memory path, uint256 len) internal returns (uint256[] memory out) {
        out = new uint256[](len);
        for (uint256 i = 0; i < len; ++i) {
            out[i] = vm.parseJsonUint(j, string.concat(path, "[", vm.toString(i), "]"));
        }
    }

    function _u(string memory j, string memory path) internal returns (uint256) {
        return vm.parseUint(vm.parseJsonString(j, path));
    }
}
