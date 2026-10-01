// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";
import {StarkMerkle as MK} from "../../contracts/shield/verifier/StarkMerkle.sol";

/// @notice Prices the parts of a base query: the DEEP term loop, the wide leaves, one path and one
/// inversion. The DEEP quotient takes two field inversions per query, not one per term.
contract DeepLoopCostTest is Test {
    function test_whatTheDeepLoopCosts() public view {
        uint256 n = 2523; // n_deep_terms at the deployed shape
        F.Fp2[] memory a = new F.Fp2[](n);
        for (uint256 i = 0; i < n; ++i) a[i] = F.Fp2(i + 7, i + 11);
        F.Fp2 memory acc = F.zero();
        F.Fp2 memory k = F.Fp2(3, 5);

        uint256 g = gasleft();
        for (uint256 i = 0; i < n; ++i) {
            acc = F.add(acc, F.mul(k, F.sub(a[i], k)));
        }
        uint256 used = g - gasleft();
        console2.log("2523 terms, sub+mul+add :", used);
        console2.log("  per term              :", used / n);
        assertTrue(acc.c0 != 1, "keep");
    }

    function test_whatTheWideLeavesCost() public view {
        uint256[] memory trace = new uint256[](704);
        uint256[] memory per = new uint256[](1114);
        for (uint256 i = 0; i < 704; ++i) trace[i] = i + 1;
        for (uint256 i = 0; i < 1114; ++i) per[i] = i + 1;

        uint256 g = gasleft();
        MK.hashLeafWide(trace);
        uint256 t = g - gasleft();
        g = gasleft();
        MK.hashLeafWidePeriodic(per);
        uint256 p = g - gasleft();
        console2.log("trace wide leaf   704 cols:", t);
        console2.log("periodic wide leaf 1114   :", p);
    }

    function test_whatAPathCosts() public view {
        bytes32[] memory path = new bytes32[](26);
        for (uint256 i = 0; i < 26; ++i) path[i] = keccak256(abi.encode(i));
        uint256 g = gasleft();
        MK.verifyPathExt(bytes32(uint256(1)), 12345, F.Fp2(7, 11), path);
        console2.log("one 26-level path         :", g - gasleft());
    }

    /// An Fp2 inversion, so the two per query can be priced against the rest.
    function test_whatAnInversionCosts() public view {
        F.Fp2 memory x = F.Fp2(123456789, 987654321);
        uint256 g = gasleft();
        F.inv(x);
        console2.log("one Fp2 inversion         :", g - gasleft());
    }
}
