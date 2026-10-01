// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";

/// @notice All 51 grand-product terms of the width-129 layout, checked against the oracle's
///         transition_z[38..88]. id, sig and gp_sel are read from the oracle's periodic_z.
/// @dev gp(g) = gp_sel·(z_next·den - z·num) + (1-gp_sel)·(z_next - z), with
///      num = Π(ood[wcol]+β·id+γ), den = Π(ood[wcol]+β·sig+γ), β=5, γ=7.
contract ProductionGpStatementTest is Test {
    uint256 internal constant BETA = 5;
    uint256 internal constant GAMMA = 7;
    uint256 internal constant WIDTH = 78; // stack.width
    uint256 internal constant STRIDE = 129; // trace_width
    uint256 internal constant REGION_TRANSITIONS = 38; // gp g → transition_z[38+g]

    F.Fp2[] internal ood; // 258
    F.Fp2[] internal pz; // 444 periodic_z
    F.Fp2[] internal tz; // 89 transition_z

    function setUp() public {
        _parseOod();
        string memory j = vm.readFile("spec/reference/intermediates.json");
        _readFp2(j, ".periodic_z", 444, pz);
        _readFp2(j, ".transition_z", 89, tz);
    }

    /// The statement-family terms (groups 0..5) and deep z (group 6) match the oracle.
    function test_StatementGpTermsMatchOracle() public view {
        // group g → (wired_cols, k, slot). Slots: 59 + cumulative(2k+1).
        // g0..g4 k5 (2*5+1=11 each), g5 k4. 59,70,81,92,103,114.
        _check(0, _c5(0, 22, 23, 4, 5, true), 59); // z: [0,22,23,4,5]
        _check(1, _c5(0, 24, 25, 26, 27, false), 70); // coeff grp0
        _check(2, _c5(0, 28, 29, 30, 31, false), 81); // coeff grp1
        _check(3, _c5(0, 32, 33, 34, 35, false), 92); // coeff grp2
        _check(4, _c5(0, 36, 37, 38, 39, false), 103); // coeff grp3
        _check(5, _c4(54, 55, 4, 5), 114); // comp_z
        // Deep family starts here. g6 (deep z) is fixed-wcol: slot 114 + (2*4+1) = 123.
        _check(6, _c3(0, 10, 11), 123); // deep z → r2 z(10,11)
    }

    /// The last 11 groups (fold, index, periodic, g40..g50) match transition_z[78..88].
    /// Slots count backward from 444, and fold-leaf's opened column is 4.
    function test_EndGpTermsMatchOracle() public view {
        // fold family (g40..g43)
        _check(40, _c2(0, 1), 361); // betas
        _check(41, _c4(2, 3, 4, 5), 366); // layer-0 leaf value (mc=4)
        _check(42, _c2(1, 6), 375); // point provenance (r7 x → r4 x)
        _check(43, _c2(0, 8), 380); // position bits
        // index family (g44..g45)
        _check(44, _c4(1, 2, 14, 15), 385); // consistency point (r6 → r2 x)
        _check(45, _c2(0, 8), 394); // path-direction bits
        // periodic family (g46..g50), k4 each, slots 399/408/417/426/435
        _check(46, _c4(10, 11, 12, 13), 399);
        _check(47, _c4(10, 11, 14, 15), 408);
        _check(48, _c4(10, 11, 16, 17), 417);
        _check(49, _c4(10, 11, 18, 19), 426);
        _check(50, _c4(10, 11, 20, 21), 435);
    }

    /// The 7 DEEP coefficient-squeeze groups (k3, slots 178..220) and the 6 roots groups
    /// (k5, slots 295..350) match the oracle.
    function test_MiddleFixedGpTermsMatchOracle() public view {
        // coeff-squeeze g15..g21 (k3), slot 178 + 7*i
        for (uint256 i = 0; i < 7; ++i) {
            _check(15 + i, _c3(0, 12, 13), 178 + 7 * i);
        }
        // roots g34..g39 (k5), slot 295 + 11*i
        for (uint256 i = 0; i < 6; ++i) {
            _check(34 + i, _c5(0, 1, 2, 3, 8, false), 295 + 11 * i);
        }
    }

    /// The 12 DEEP claim-cycle groups (g22..g33, slots 227..295) match the oracle.
    /// group1(i) = dedup{2i,8}, group2(i) = dedup{2i+1,8,9}, sorted ascending.
    function test_ClaimCycleGpTermsMatchOracle() public view {
        _check(22, _c2(0, 8), 227);
        _check(23, _c3(1, 8, 9), 232);
        _check(24, _c2(2, 8), 239);
        _check(25, _c3(3, 8, 9), 244);
        _check(26, _c2(4, 8), 251);
        _check(27, _c3(5, 8, 9), 256);
        _check(28, _c2(6, 8), 263);
        _check(29, _c3(7, 8, 9), 268);
        _check(30, _c1(8), 275); // i=4 group1: {8,8}→{8}
        _check(31, _c2(8, 9), 278); // i=4 group2: {9,9,8}→{8,9}
        _check(32, _c2(8, 10), 283);
        _check(33, _c3(8, 9, 11), 288);
    }

    /// The 8 opened-cell DEEP groups (g7, g8 and trace cycles g9..g14) match the oracle.
    /// Every opened cell has col = RATE = 4.
    function test_OcellsGpTermsMatchOracle() public view {
        _check(7, _c4(2, 3, 4, 5), 130); // deep result (dc=4)
        _check(8, _c4(6, 7, 4, 5), 139); // deep comp (cc=4)
        uint256[6] memory slots = [uint256(148), 153, 158, 163, 168, 173];
        for (uint256 t = 0; t < 6; ++t) {
            uint256[] memory cols = (t % 2 == 0) ? _c2(4, 6) : _c2(5, 7); // lane0 / lane1
            _check(9 + t, cols, slots[t]);
        }
    }

    function _c1(uint256 a) internal pure returns (uint256[] memory o) {
        o = new uint256[](1);
        o[0] = a;
    }

    function _c2(uint256 a, uint256 b) internal pure returns (uint256[] memory o) {
        o = new uint256[](2);
        o[0] = a;
        o[1] = b;
    }

    function _c3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory o) {
        o = new uint256[](3);
        o[0] = a;
        o[1] = b;
        o[2] = c;
    }

    function _check(uint256 g, uint256[] memory cols, uint256 slot) internal view {
        F.Fp2 memory got = _gp(cols, slot, g);
        F.Fp2 memory want = tz[REGION_TRANSITIONS + g];
        require(got.c0 == want.c0 && got.c1 == want.c1, string.concat("gp mismatch @ group ", vm.toString(g)));
    }

    function _gp(uint256[] memory cols, uint256 slot, uint256 g) internal view returns (F.Fp2 memory) {
        F.Fp2 memory num = F.one();
        F.Fp2 memory den = F.one();
        uint256 k = cols.length;
        for (uint256 jj = 0; jj < k; ++jj) {
            F.Fp2 memory v = ood[cols[jj]];
            num = F.mul(num, F.add(F.add(v, F.mulBase(pz[slot + 2 * jj], BETA)), F.fromBase(GAMMA)));
            den = F.mul(den, F.add(F.add(v, F.mulBase(pz[slot + 2 * jj + 1], BETA)), F.fromBase(GAMMA)));
        }
        F.Fp2 memory z = ood[WIDTH + g];
        F.Fp2 memory zNext = ood[STRIDE + WIDTH + g];
        F.Fp2 memory gpSel = pz[slot + 2 * k];
        F.Fp2 memory prod = F.sub(F.mul(zNext, den), F.mul(z, num));
        F.Fp2 memory carry = F.sub(zNext, z);
        return F.add(F.mul(gpSel, prod), F.mul(F.sub(F.one(), gpSel), carry));
    }

    function _c5(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e, bool)
        internal
        pure
        returns (uint256[] memory o)
    {
        o = new uint256[](5);
        o[0] = a;
        o[1] = b;
        o[2] = c;
        o[3] = d;
        o[4] = e;
    }

    function _c4(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory o) {
        o = new uint256[](4);
        o[0] = a;
        o[1] = b;
        o[2] = c;
        o[3] = d;
    }

    function _parseOod() internal {
        // Vector layout: trace_root(32) comp_root(32), then u32 count and count Fp2 OOD values.
        bytes memory p = vm.parseBytes(
            string.concat("0x", vm.parseJsonString(vm.readFile("spec/production-recursive-vector.json"), ".proof_hex"))
        );
        uint256 off = 64; // skip two 32-byte digests
        uint256 n = _u32(p, off);
        off += 4;
        for (uint256 i = 0; i < n; ++i) {
            uint256 c0 = _u64le(p, off);
            uint256 c1 = _u64le(p, off + 8);
            off += 16;
            ood.push(F.Fp2(c0, c1));
        }
    }

    function _u32(bytes memory b, uint256 o) internal pure returns (uint256 v) {
        for (uint256 i = 0; i < 4; ++i) {
            v |= uint256(uint8(b[o + i])) << (8 * i);
        }
    }

    function _u64le(bytes memory b, uint256 o) internal pure returns (uint256 v) {
        for (uint256 i = 0; i < 8; ++i) {
            v |= uint256(uint8(b[o + i])) << (8 * i);
        }
    }

    function _readFp2(string memory j, string memory path, uint256 len, F.Fp2[] storage dst) internal {
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
