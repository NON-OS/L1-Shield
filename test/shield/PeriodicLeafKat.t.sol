// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StarkMerkle as MK} from "../../contracts/shield/verifier/StarkMerkle.sol";

/// The prover's known-answer vectors for the periodic Merkle tree.
contract PeriodicLeafKatTest is Test {
    /// Leaf and node hashes match the prover, including a row at the modulus boundary.
    function test_theLeafEncodingMatchesTheProver() public pure {
        uint256[] memory a = new uint256[](4);
        a[0] = 1;
        a[1] = 2;
        a[2] = 3;
        a[3] = 4;
        assertEq(
            MK.hashLeafWidePeriodic(a),
            bytes32(0x29df673b623ce579548bb1974297026bc4435dc4566a64893a3e65e775901105),
            "leaf([1,2,3,4])"
        );

        uint256[] memory b = new uint256[](4);
        b[0] = 0xFFFFFFFF00000000;
        b[1] = 7;
        b[2] = 0;
        b[3] = 0xFFFFFFFF00000000;
        assertEq(
            MK.hashLeafWidePeriodic(b),
            bytes32(0x72f107ed9cff4617ca0e2bb77ee7f1a8fac0d41f7d41e64527933973f2710669),
            "leaf at the modulus boundary"
        );

        assertEq(
            MK.hashNode(MK.hashLeafWidePeriodic(a), MK.hashLeafWidePeriodic(b)),
            bytes32(0x93516974620bb9ce11d376ce9ca474401baf02e08378aacf808453a2d39669f3),
            "node(first, second)"
        );
    }
}
