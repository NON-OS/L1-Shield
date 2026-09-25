// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProductionAir} from "../../contracts/shield/verifier/ProductionAir.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";

/// @notice The FRI final layer's degree check, fixed per deployment by its form: a constant
/// layer needs every cell equal (degree zero), k coefficients bound the degree below k.
contract EarlyStopTest is Test {
    /// Horner over k coefficients evaluates a polynomial of degree below k.
    function test_coefficientsBoundTheDegree() public pure {
        F.Fp2[] memory c = new F.Fp2[](3); // 1 + 2x + 3x^2
        c[0] = F.Fp2(1, 0);
        c[1] = F.Fp2(2, 0);
        c[2] = F.Fp2(3, 0);
        assertEq(ProductionAir.evalFinal(c, 0).c0, 1, "p(0) is the constant term");
        assertEq(ProductionAir.evalFinal(c, 1).c0, 6, "p(1) is the coefficient sum");
        assertEq(ProductionAir.evalFinal(c, 2).c0, 17, "1 + 4 + 12");
    }

    /// A single coefficient is degree zero and evaluates to itself at every x.
    function test_aConstantIsDegreeZero() public pure {
        F.Fp2[] memory one = new F.Fp2[](1);
        one[0] = F.Fp2(42, 7);
        for (uint256 x = 0; x < 50; x += 7) {
            assertEq(ProductionAir.evalFinal(one, x).c0, 42, "a constant does not vary with x");
            assertEq(ProductionAir.evalFinal(one, x).c1, 7);
        }
    }

    /// Indexing a layer by query position accepts arbitrary cells, so it is no degree check.
    function test_positionIndexingIsNotADegreeCheck() public pure {
        F.Fp2[] memory arbitrary = new F.Fp2[](4);
        arbitrary[0] = F.Fp2(999999, 0);
        arbitrary[1] = F.Fp2(3, 0);
        arbitrary[2] = F.Fp2(770077, 0);
        arbitrary[3] = F.Fp2(1, 0);
        // Indexing returns a value for any layer.
        assertEq(arbitrary[5 % 4].c0, 3);
        assertTrue(arbitrary[0].c0 != arbitrary[1].c0, "an arbitrary layer, accepted by indexing");
    }
}
