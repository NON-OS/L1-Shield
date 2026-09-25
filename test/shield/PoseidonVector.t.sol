// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PoseidonGoldilocks} from "../../contracts/shield/PoseidonGoldilocks.sol";

/// The on-chain Poseidon permutation against the prover's own permutation vectors.
contract PoseidonVectorTest is Test, PoseidonGoldilocks {
    /// The full-round permutation of [1..8] matches the prover on all eight lanes.
    function test_thePermutationAgreesWithTheProverOnAllEightLanes() public view {
        uint256[8] memory s = [uint256(1), 2, 3, 4, 5, 6, 7, 8];
        _permute(s, FULL_ROUNDS);
        uint256[8] memory want = [
            uint256(1022089083010806312),
            8134804760473441809,
            13972665140821454643,
            18290724068579387637,
            33538716422518085,
            4874145967630906442,
            3176566405087518195,
            7617985140508846139
        ];
        for (uint256 i = 0; i < 8; ++i) {
            assertEq(s[i], want[i], string.concat("lane ", vm.toString(i), " disagrees"));
        }
    }

    /// The 31-round single-block hash form of [1,2,3,4] matches the prover.
    function test_theHashRoundFormAgreesToo() public view {
        uint256[8] memory s;
        s[0] = 1;
        s[1] = 2;
        s[2] = 3;
        s[3] = 4;
        _permute(s, HASH_ROUNDS);
        console2.log("hash(1,2,3,4) lanes:");
        for (uint256 i = 0; i < 4; ++i) console2.log("  ", s[i]);
        assertEq(s[0], 2169049970631926957, "hash lane 0");
        assertEq(s[1], 6775483557278429577, "hash lane 1");
        assertEq(s[2], 12065499352586199786, "hash lane 2");
        assertEq(s[3], 5346927755136647619, "hash lane 3");
    }
}
