// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ProductionDeepQuery as D} from "../../contracts/shield/verifier/ProductionDeepQuery.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";
import {StarkTranscript as TS} from "../../contracts/shield/verifier/StarkTranscript.sol";
import {StarkProofReader as R} from "../../contracts/shield/StarkProofReader.sol";
import {StarkMerkle as MK} from "../../contracts/shield/verifier/StarkMerkle.sol";

/// @notice Gas breakdown of one base query at 704 trace columns and 1114 periodic columns:
/// DEEP combine, leaf hashes, coefficient redraw, and row decode.
contract QueryProfileTest is Test {
    uint256 constant W = 704;
    uint256 constant NP = 1114;
    uint256 constant TERMS = 2 * W + 1 + NP; // 2523

    function _ctx() internal pure returns (D.Ctx memory c) {
        c.z = F.Fp2(12345, 67890);
        c.compZ = F.Fp2(1111, 2222);
        c.x = 999983;
        c.g = 9306717745644682924;
        c.width = W;
        c.nPeriodic = NP;
        c.preSummedClaims = F.Fp2(5, 7);
    }

    function test_profileOneBaseQuery() public view {
        uint256[] memory row = new uint256[](W);
        for (uint256 i = 0; i < W; ++i) row[i] = i + 1;
        uint256[] memory per = new uint256[](NP);
        for (uint256 i = 0; i < NP; ++i) per[i] = i + 3;
        F.Fp2[] memory ood = new F.Fp2[](2 * W);
        for (uint256 i = 0; i < 2 * W; ++i) ood[i] = F.Fp2(i + 5, i + 9);
        F.Fp2[] memory co = new F.Fp2[](TERMS);
        for (uint256 i = 0; i < TERMS; ++i) co[i] = F.Fp2(i + 13, i + 17);
        F.Fp2 memory comp = F.Fp2(31, 37);

        uint256 g = gasleft();
        D.combine(row, comp, ood, co, _ctx());
        uint256 frame = g - gasleft();

        g = gasleft();
        D.combineWithScalar(row, comp, ood, co, _ctx(), per, F.Fp2(5, 7));
        uint256 whole = g - gasleft();

        g = gasleft();
        MK.hashLeafWide(row);
        uint256 lt = g - gasleft();
        g = gasleft();
        MK.hashLeafWidePeriodic(per);
        uint256 lp = g - gasleft();

        console2.log("frame terms   1409 :", frame);
        console2.log("whole  terms  2523 :", whole);
        console2.log("  sidecar portion  :", whole - frame);
        console2.log("trace wide leaf    :", lt);
        console2.log("periodic wide leaf :", lp);
        console2.log("gas per deep term  :", whole / TERMS);

        // what a chunk re-derives from the checkpoint, once per chunk
        TS.T memory t = TS.T(keccak256("cp"));
        g = gasleft();
        TS.challengeFp2Batch(t, TERMS);
        console2.log("redraw 2523 coeffs :", g - gasleft());

        // decoding the two wide rows out of bytes
        bytes memory buf = new bytes(NP * 8);
        R.Cursor memory c = R.Cursor(0);
        g = gasleft();
        R.readFpArray(buf, c, W);
        uint256 dt = g - gasleft();
        c.off = 0;
        g = gasleft();
        R.readFpArray(buf, c, NP);
        console2.log("decode 704 trace   :", dt);
        console2.log("decode 1114 sidecar:", g - gasleft());
    }
}

/// Hashing a wide leaf from wire bytes gives the same digest as from values, for less gas.
contract RawLeafTest is Test {
    function test_theRawLeafIsTheSameDigestAndCheaper() public view {
        uint256 n = 704;
        bytes memory wire = new bytes(n * 8);
        uint256[] memory vals = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 v = (i * 2654435761) % 0xFFFFFFFF00000001;
            vals[i] = v;
            for (uint256 b = 0; b < 8; ++b) wire[i * 8 + b] = bytes1(uint8(v >> (8 * b)));
        }
        uint256 g = gasleft();
        bytes32 a = MK.hashLeafWide(vals);
        uint256 built = g - gasleft();
        g = gasleft();
        bytes32 b2 = MK.hashLeafWideRaw(wire, 0, n);
        uint256 raw = g - gasleft();
        assertEq(a, b2, "the raw form is a different preimage");
        console2.log("built from values :", built);
        console2.log("hashed from wire  :", raw);
        console2.log("saved per leaf    :", built - raw);
    }
}

/// Cost of reading DEEP coefficients through `Fp2[]` pointers against a flat array of 2n words.
contract FlatCoeffTest is Test {
    function test_whatTheIndirectionCosts() public view {
        uint256 n = 2523;
        F.Fp2[] memory ptr = new F.Fp2[](n);
        uint256[] memory flat = new uint256[](2 * n);
        for (uint256 i = 0; i < n; ++i) {
            ptr[i] = F.Fp2(i + 7, i + 11);
            flat[2 * i] = i + 7;
            flat[2 * i + 1] = i + 11;
        }
        uint256 a0;
        uint256 a1;

        uint256 g = gasleft();
        assembly {
            let P := 0xFFFFFFFF00000001
            let cp := add(ptr, 0x20)
            for { let j := 0 } lt(j, n) { j := add(j, 1) } {
                let k := mload(add(cp, mul(j, 32)))
                a0 := addmod(a0, mulmod(mload(k), 3, P), P)
                a1 := addmod(a1, mulmod(mload(add(k, 32)), 3, P), P)
            }
        }
        uint256 chased = g - gasleft();

        g = gasleft();
        assembly {
            let P := 0xFFFFFFFF00000001
            let fp := add(flat, 0x20)
            for { let j := 0 } lt(j, n) { j := add(j, 1) } {
                let o := add(fp, mul(j, 64))
                a0 := addmod(a0, mulmod(mload(o), 3, P), P)
                a1 := addmod(a1, mulmod(mload(add(o, 32)), 3, P), P)
            }
        }
        uint256 direct = g - gasleft();

        console2.log("pointer-chased 2523 :", chased);
        console2.log("flat           2523 :", direct);
        console2.log("saved per query     :", chased - direct);
        assertTrue(a0 != 1, "keep");
    }
}
