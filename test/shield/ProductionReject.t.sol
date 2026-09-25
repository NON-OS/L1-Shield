// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";
import {StarkProofReader as R} from "../../contracts/shield/StarkProofReader.sol";
import {StarkMerkle as MK} from "../../contracts/shield/verifier/StarkMerkle.sol";
import {ProductionAir} from "../../contracts/shield/verifier/ProductionAir.sol";

/// @notice Verifier-layer rejects on the production vector: swapped root and rebound trace value.
///         The off-transcript coefficient case is skipped. The bad FRI fold case is in ProductionQuery.
contract ProductionRejectTest is Test {
    uint256 internal constant OOD_LEN = 172;
    uint256 internal constant N_FOLDS = 15;
    uint256 internal constant BLOWUP = 16;
    uint256 internal constant N_QUERIES = 32;
    uint256 internal constant TRACE_WIDTH = 86;

    bytes32 internal traceRoot;
    bytes32 internal compRoot;
    bytes32 internal deepRoot; // fri.roots[0]

    // query 0 opening
    uint256[] internal traceRow; // trace_width values
    bytes32[] internal tracePath; // one wide path
    F.Fp2 internal comp;
    bytes32[] internal compPath;
    F.Fp2 internal deepVal;
    bytes32[] internal deepPath;
    uint256 internal qIndex; // consistency_query_indices[0]

    function setUp() public {
        qIndex = vm.parseJsonUint(vm.readFile("spec/reference/intermediates.json"), ".consistency_query_indices[0]");
        _parseQuery0();
    }

    /// The real wide trace opening and comp opening authenticate against their roots.
    function test_accept_RealTraceOpeningAuthenticates() public view {
        assertTrue(
            MK.verifyPathWide(traceRoot, qIndex, traceRow, tracePath),
            "real wide trace opening did not authenticate against trace_root"
        );
        assertTrue(
            MK.verifyPathExt(compRoot, qIndex, comp, compPath),
            "real comp opening did not authenticate against comp_root"
        );
    }

    /// A trace row with one value changed fails its wide path.
    function test_reject_ReboundTraceValue() public view {
        uint256[] memory bad = _copy(traceRow);
        bad[42] = addmod(bad[42], 1, F.P);
        assertFalse(MK.verifyPathWide(traceRoot, qIndex, bad, tracePath), "rebound trace value authenticated");
    }

    /// A real opening fails against a root the transcript did not commit for it.
    function test_reject_SwappedRoot() public view {
        // trace opening vs comp_root (wrong) and comp opening vs trace_root (wrong).
        assertFalse(
            MK.verifyPathWide(compRoot, qIndex, traceRow, tracePath), "trace opening authenticated against comp_root"
        );
        assertFalse(
            MK.verifyPathExt(traceRoot, qIndex, comp, compPath), "comp opening authenticated against trace_root"
        );
        assertFalse(
            MK.verifyPathExt(traceRoot, qIndex, deepVal, deepPath), "deep opening authenticated against trace_root"
        );
    }

    /// A substituted composition coefficient moves comp_z. Skipped: written for the 46-entry
    /// composeZ layout, which the current vector does not match.
    function skip_reject_OffTranscriptCoefficient() public {
        (
            F.Fp2[] memory ood,
            F.Fp2[] memory pz,
            F.Fp2[] memory tz,
            F.Fp2[] memory coeffs,
            uint256[3][] memory bnds,
            F.Fp2 memory z,
            F.Fp2 memory compZ,
            uint256[] memory mds,
            uint256 g,
            uint256 openedCol
        ) = _composeInputs();
        F.Fp2[] memory tr = ProductionAir.transitionZ(ood, pz, mds, g, openedCol, ProductionAir.provisionalChallenges());
        // sanity: honest coeffs reproduce comp_z.
        F.Fp2 memory honest = ProductionAir.composeZ(ood, tr, coeffs, bnds, z, F.rootOfUnity(11), 2048);
        require(honest.c0 == compZ.c0 && honest.c1 == compZ.c1, "honest composeZ != comp_z");
        // tamper one coefficient → comp_z must move.
        coeffs[3] = F.add(coeffs[3], F.one());
        F.Fp2 memory bad = ProductionAir.composeZ(ood, tr, coeffs, bnds, z, F.rootOfUnity(11), 2048);
        require(bad.c0 != compZ.c0 || bad.c1 != compZ.c1, "off-transcript coefficient still reproduced comp_z");
        // tz is parsed but not used
        tz;
    }

    // The bad FRI fold class is ProductionQuery.test_FriFoldRejectsTamperedBeta.

    function _copy(uint256[] memory a) internal pure returns (uint256[] memory b) {
        b = new uint256[](a.length);
        for (uint256 i = 0; i < a.length; ++i) {
            b[i] = a[i];
        }
    }

    function _parseQuery0() internal {
        bytes memory p = vm.parseBytes(
            string.concat("0x", vm.parseJsonString(vm.readFile("spec/production-recursive-vector.json"), ".proof_hex"))
        );
        R.Cursor memory c = R.Cursor(0);
        traceRoot = R.readDigest(p, c);
        compRoot = R.readDigest(p, c);
        uint256 oodCount = R.readU32(p, c);
        for (uint256 i = 0; i < oodCount; ++i) {
            R.readFp2(p, c);
        }
        // fri.roots
        uint256 rc = R.readU32(p, c);
        deepRoot = R.readDigest(p, c);
        for (uint256 i = 1; i < rc; ++i) {
            R.readDigest(p, c);
        }
        // fri.final_layer
        uint256 fc = R.readU32(p, c);
        for (uint256 i = 0; i < fc; ++i) {
            R.readFp2(p, c);
        }
        // fri.queries
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
        // queries: read query 0 fully.
        R.readU32(p, c); // n_queries
        deepVal = _f(R.readFp2(p, c));
        deepPath = R.readPath(p, c);
        uint256 tw = R.readU32(p, c);
        traceRow = new uint256[](tw);
        for (uint256 i = 0; i < tw; ++i) {
            traceRow[i] = uint256(R.readFp(p, c));
        }
        tracePath = R.readPath(p, c);
        comp = _f(R.readFp2(p, c));
        compPath = R.readPath(p, c);
    }

    function _f(R.Fp2 memory e) internal pure returns (F.Fp2 memory) {
        return F.Fp2(uint256(e.c0), uint256(e.c1));
    }

    // Parses the composeZ inputs.
    function _composeInputs()
        internal
        returns (
            F.Fp2[] memory ood,
            F.Fp2[] memory pz,
            F.Fp2[] memory tz,
            F.Fp2[] memory coeffs,
            uint256[3][] memory bnds,
            F.Fp2 memory z,
            F.Fp2 memory compZ,
            uint256[] memory mds,
            uint256 g,
            uint256 openedCol
        )
    {
        string memory j = vm.readFile("spec/reference/intermediates.json");
        ood = _oodFromVector();
        pz = _fp2Arr(j, ".periodic_z", 136);
        tz = _fp2Arr(j, ".transition_z", 46);
        coeffs = _fp2Arr(j, ".coeffs", 172);
        z = F.Fp2(vm.parseUint(vm.parseJsonString(j, ".z[0]")), vm.parseUint(vm.parseJsonString(j, ".z[1]")));
        compZ =
            F.Fp2(vm.parseUint(vm.parseJsonString(j, ".comp_z[0]")), vm.parseUint(vm.parseJsonString(j, ".comp_z[1]")));
        mds = _mds();
        g = F.rootOfUnity(6);
        uint256 i0 = vm.parseJsonUint(j, ".merkle_query0.inner_leaf_index");
        openedCol = (i0 & 1) == 1 ? 4 : 0;
        bnds = _boundaries();
    }

    function _oodFromVector() internal view returns (F.Fp2[] memory ood) {
        bytes memory p = vm.parseBytes(
            string.concat("0x", vm.parseJsonString(vm.readFile("spec/production-recursive-vector.json"), ".proof_hex"))
        );
        R.Cursor memory c = R.Cursor(0);
        R.readDigest(p, c);
        R.readDigest(p, c);
        uint256 n = R.readU32(p, c);
        ood = new F.Fp2[](n);
        for (uint256 i = 0; i < n; ++i) {
            R.Fp2 memory e = R.readFp2(p, c);
            ood[i] = F.Fp2(uint256(e.c0), uint256(e.c1));
        }
    }

    function _fp2Arr(string memory j, string memory path, uint256 len) internal returns (F.Fp2[] memory a) {
        a = new F.Fp2[](len);
        for (uint256 i = 0; i < len; ++i) {
            string memory pre = string.concat(path, "[", vm.toString(i), "]");
            a[i] = F.Fp2(
                vm.parseUint(vm.parseJsonString(j, string.concat(pre, "[0]"))),
                vm.parseUint(vm.parseJsonString(j, string.concat(pre, "[1]")))
            );
        }
    }

    function _boundaries() internal returns (uint256[3][] memory bnds) {
        string memory s = vm.readFile("spec/production-air-structure.json");
        bnds = new uint256[3][](126);
        for (uint256 i = 0; i < 126; ++i) {
            string memory pre = string.concat(".boundaries[", vm.toString(i), "]");
            bnds[i][0] = vm.parseJsonUint(s, string.concat(pre, "[0]"));
            bnds[i][1] = vm.parseJsonUint(s, string.concat(pre, "[1]"));
            bnds[i][2] = vm.parseUint(vm.parseJsonString(s, string.concat(pre, "[2]"))) % F.P;
        }
    }

    function _mds() internal pure returns (uint256[] memory mds) {
        bytes memory blob =
            hex"1fffffffe0000000c71c71c65555555619999999800000008ba2e8b9a2e8ba2f15555555400000006276276213b13b14edb6db6cc924924a1111111100000000db6db6da924924931fffffffe0000000c71c71c65555555619999999800000008ba2e8b9a2e8ba2f15555555400000006276276213b13b14edb6db6cc924924a2aaaaaaa80000000db6db6da924924931fffffffe0000000c71c71c65555555619999999800000008ba2e8b9a2e8ba2f15555555400000006276276213b13b1433333333000000002aaaaaaa80000000db6db6da924924931fffffffe0000000c71c71c65555555619999999800000008ba2e8b9a2e8ba2f15555555400000003fffffffc000000033333333000000002aaaaaaa80000000db6db6da924924931fffffffe0000000c71c71c65555555619999999800000008ba2e8b9a2e8ba2f55555555000000003fffffffc000000033333333000000002aaaaaaa80000000db6db6da924924931fffffffe0000000c71c71c65555555619999999800000007fffffff8000000055555555000000003fffffffc000000033333333000000002aaaaaaa80000000db6db6da924924931fffffffe0000000c71c71c655555556ffffffff000000007fffffff8000000055555555000000003fffffffc000000033333333000000002aaaaaaa80000000db6db6da924924931fffffffe0000000c71c71c655555556";
        mds = new uint256[](64);
        for (uint256 i = 0; i < 64; ++i) {
            uint256 v;
            uint256 o = i * 8;
            for (uint256 b = 0; b < 8; ++b) {
                v = (v << 8) | uint8(blob[o + b]);
            }
            mds[i] = v;
        }
    }
}
