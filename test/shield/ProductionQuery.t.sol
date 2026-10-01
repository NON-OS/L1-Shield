// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";
import {StarkProofReader as R} from "../../contracts/shield/StarkProofReader.sol";
import {ProductionAir} from "../../contracts/shield/verifier/ProductionAir.sol";

/// A constant final layer as a one-element polynomial, the degree-zero case of `friFold`.
function _constFinal(F.Fp2 memory v) pure returns (F.Fp2[] memory o) {
    o = new F.Fp2[](1);
    o[0] = v;
}


/// @notice Production DEEP consistency and FRI fold against the oracle's query0 and fri_query0.
///         DEEP algebra only: trace_row and comp come from the oracle unauthenticated.
contract ProductionQueryTest is Test {
    uint256 internal constant SHIFT = 7;
    uint256 internal constant N = 16777216; // 2^24 eval domain
    uint256 internal constant N_FOLDS = 16;

    F.Fp2[] internal ood; // 258 from the vector
    F.Fp2[] internal deepCoeffs; // 703
    F.Fp2[] internal betas; // 16
    uint256[] internal traceRow; // 129 base values
    F.Fp2 internal qComp;
    F.Fp2 internal qDeep;
    uint256 internal qIndex;
    uint256 internal qX;
    F.Fp2 internal zPt;
    F.Fp2 internal compZ;
    // fri_query0
    F.Fp2[] internal friA;
    F.Fp2[] internal friB;
    F.Fp2 internal friFinal;
    uint256 internal friIndex;
    // preprocessed-periodic sidecar
    F.Fp2[] internal periodicZ; // 444 claims (== oracle periodic_z)
    uint256[] internal periodicRow; // query 0's authenticated periodic row P_j(x)

    function setUp() public {
        _parseVectorOnce();
        _parseOracle();
    }

    /// The DEEP combination at query 0 equals the oracle's deep value, with x derived.
    function test_DeepConsistencyMatchesQuery0() public view {
        // x is derived from the query index, never taken from the oracle
        uint256 omega = F.rootOfUnity(24);
        uint256 x = F.fpMul(SHIFT, F.fpPow(omega, qIndex));
        require(x == qX, "derived x != oracle query0.x");

        ProductionAir.DeepCtx memory ctx = ProductionAir.DeepCtx(ood, deepCoeffs, zPt, compZ, x, F.rootOfUnity(12));
        // Full DEEP with the preprocessed-periodic fold-in (703 coeffs = 259 + 444).
        F.Fp2 memory got = ProductionAir.deepAtQueryPre(traceRow, qComp, ctx, periodicRow, periodicZ);
        require(got.c0 == qDeep.c0 && got.c1 == qDeep.c1, "DEEP consistency != query0.deep");
    }

    /// The FRI fold chain for fri_query0 closes to the final value.
    function test_FriFoldChainMatchesFriQuery0() public view {
        bool ok = ProductionAir.friFold(friA, friB, betas, friIndex, _constFinal(friFinal), F.rootOfUnity(24), N_FOLDS, N, false);
        require(ok, "FRI fold chain rejected the honest query");
    }

    /// @dev Corrupting a beta must break the fold chain.
    function test_FriFoldRejectsTamperedBeta() public view {
        F.Fp2[] memory badBetas = new F.Fp2[](betas.length);
        for (uint256 i = 0; i < betas.length; ++i) {
            badBetas[i] = betas[i];
        }
        badBetas[0] = F.add(badBetas[0], F.one());
        bool ok = ProductionAir.friFold(friA, friB, badBetas, friIndex, _constFinal(friFinal), F.rootOfUnity(24), N_FOLDS, N, false);
        require(!ok, "FRI fold accepted a tampered beta");
    }

    /// Parses the proof once: extracts the ood frame and walks to query 0's authenticated
    /// periodic row P_j(x) (444 base values, no per-row length prefix).
    function _parseVectorOnce() internal {
        bytes memory p = vm.parseBytes(
            string.concat("0x", vm.parseJsonString(vm.readFile("spec/production-recursive-vector.json"), ".proof_hex"))
        );
        R.Cursor memory c = R.Cursor(0);
        R.readDigest(p, c); // trace_root
        R.readDigest(p, c); // comp_root
        uint256 n = R.readU32(p, c);
        for (uint256 i = 0; i < n; ++i) {
            R.Fp2 memory e = R.readFp2(p, c);
            ood.push(F.Fp2(uint256(e.c0), uint256(e.c1))); // ood frame
        }
        uint256 rc = R.readU32(p, c);
        for (uint256 i = 0; i < rc; ++i) {
            R.readDigest(p, c); // fri.roots
        }
        uint256 fc = R.readU32(p, c);
        for (uint256 i = 0; i < fc; ++i) {
            R.readFp2(p, c); // fri.final_layer
        }
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
        R.readU64(p, c); // pow_nonce
        uint256 nq = R.readU32(p, c); // queries
        for (uint256 q = 0; q < nq; ++q) {
            R.readFp2(p, c); // deep
            R.skipPath(p, c);
            uint256 tw = R.readU32(p, c);
            for (uint256 i = 0; i < tw; ++i) {
                R.readFp(p, c); // trace row
            }
            R.skipPath(p, c);
            R.readFp2(p, c); // comp
            R.skipPath(p, c);
        }
        // sidecar: num_periodic, num_periodic claims, then query 0's row.
        uint256 np = R.readU32(p, c);
        for (uint256 i = 0; i < np; ++i) {
            R.readFp2(p, c); // claims
        }
        periodicRow = new uint256[](np);
        for (uint256 i = 0; i < np; ++i) {
            periodicRow[i] = uint256(R.readFp(p, c)); // query 0 periodic row (no prefix)
        }
    }

    function _parseOracle() internal {
        string memory j = vm.readFile("spec/reference/intermediates.json");
        _readFp2Array(j, ".deep_coeffs", 703, deepCoeffs);
        _readFp2Array(j, ".periodic_z", 444, periodicZ);
        _readFp2Array(j, ".betas", 16, betas);
        zPt = _fp2(j, ".z");
        compZ = _fp2(j, ".comp_z");
        // query0
        qIndex = vm.parseJsonUint(j, ".query0.index");
        qX = vm.parseUint(vm.parseJsonString(j, ".query0.x"));
        qComp = _fp2(j, ".query0.comp");
        qDeep = _fp2(j, ".query0.deep");
        for (uint256 i = 0; i < 129; ++i) {
            traceRow.push(vm.parseUint(vm.parseJsonString(j, string.concat(".query0.trace_row[", vm.toString(i), "]"))));
        }
        // fri_query0
        friIndex = vm.parseJsonUint(j, ".fri_query_indices[0]");
        friFinal = _fp2(j, ".fri_query0.final_value");
        for (uint256 m = 0; m < N_FOLDS; ++m) {
            string memory pre = string.concat(".fri_query0.layers[", vm.toString(m), "]");
            friA.push(_fp2(j, string.concat(pre, ".a")));
            friB.push(_fp2(j, string.concat(pre, ".b")));
        }
    }

    function _fp2(string memory j, string memory path) internal view returns (F.Fp2 memory) {
        return F.Fp2(
            vm.parseUint(vm.parseJsonString(j, string.concat(path, "[0]"))),
            vm.parseUint(vm.parseJsonString(j, string.concat(path, "[1]")))
        );
    }

    function _readFp2Array(string memory j, string memory path, uint256 len, F.Fp2[] storage dst) internal {
        for (uint256 i = 0; i < len; ++i) {
            string memory pre = string.concat(path, "[", vm.toString(i), "]");
            dst.push(
                F.Fp2(
                    vm.parseUint(vm.parseJsonString(j, string.concat(pre, "[0]"))),
                    vm.parseUint(vm.parseJsonString(j, string.concat(pre, "[1]")))
                )
            );
        }
    }
}
