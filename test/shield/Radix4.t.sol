// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ProductionAir} from "../../contracts/shield/verifier/ProductionAir.sol";
import {StarkMerkle as MK} from "../../contracts/shield/verifier/StarkMerkle.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";

/// @notice Radix-4 FRI equals two radix-2 folds, under beta then beta squared, so radix-2
///         soundness carries over. Also covers the quad leaf's domain, inputs and order.
contract Radix4Test is Test {
    uint256 internal constant INV2 = 9223372034707292161;

    function _fold2(F.Fp2 memory a, F.Fp2 memory b, F.Fp2 memory beta, uint256 invx)
        internal
        pure
        returns (F.Fp2 memory)
    {
        F.Fp2 memory even = F.mulBase(F.add(a, b), INV2);
        F.Fp2 memory odd = F.mulBase(F.mulBase(F.sub(a, b), INV2), invx);
        return F.add(even, F.mul(beta, odd));
    }

    /// The quad fold equals two hand-composed radix-2 folds.
    function test_radix4IsTwoRadix2Folds() public pure {
        F.Fp2 memory v0 = F.Fp2(111, 222);
        F.Fp2 memory v1 = F.Fp2(333, 444);
        F.Fp2 memory v2 = F.Fp2(555, 666);
        F.Fp2 memory v3 = F.Fp2(777, 888);
        F.Fp2 memory beta = F.Fp2(1234567, 7654321);
        uint256 invx = F.fpInv(99991);
        uint256 invxShift = F.fpInv(31337);

        F.Fp2 memory u0 = _fold2(v0, v2, beta, invx);
        F.Fp2 memory u1 = _fold2(v1, v3, beta, invxShift);
        F.Fp2 memory want = _fold2(u0, u1, F.mul(beta, beta), F.fpMul(invx, invx));

        F.Fp2 memory got = ProductionAir.friFoldQuad(v0, v1, v2, v3, beta, invx, invxShift);
        assertEq(got.c0, want.c0, "the quad fold is not two radix-2 folds");
        assertEq(got.c1, want.c1, "the quad fold is not two radix-2 folds");
    }

    /// Each of the four fold inputs moves the result.
    function test_everyInputMovesTheResult() public pure {
        F.Fp2[4] memory v =
            [F.Fp2(111, 222), F.Fp2(333, 444), F.Fp2(555, 666), F.Fp2(777, 888)];
        F.Fp2 memory beta = F.Fp2(1234567, 7654321);
        uint256 a = F.fpInv(99991);
        uint256 b = F.fpInv(31337);
        F.Fp2 memory base = ProductionAir.friFoldQuad(v[0], v[1], v[2], v[3], beta, a, b);
        for (uint256 i = 0; i < 4; ++i) {
            F.Fp2[4] memory w = v;
            w[i] = F.add(w[i], F.one());
            F.Fp2 memory got = ProductionAir.friFoldQuad(w[0], w[1], w[2], w[3], beta, a, b);
            assertTrue(got.c0 != base.c0 || got.c1 != base.c1, "a value did not affect the fold");
        }
    }

    /// A different beta gives a different fold.
    function test_theChallengeMatters() public pure {
        F.Fp2 memory v0 = F.Fp2(1, 2);
        F.Fp2 memory v1 = F.Fp2(3, 4);
        F.Fp2 memory v2 = F.Fp2(5, 6);
        F.Fp2 memory v3 = F.Fp2(7, 8);
        uint256 a = F.fpInv(7);
        uint256 b = F.fpInv(11);
        F.Fp2 memory x = ProductionAir.friFoldQuad(v0, v1, v2, v3, F.Fp2(9, 9), a, b);
        F.Fp2 memory y = ProductionAir.friFoldQuad(v0, v1, v2, v3, F.Fp2(10, 9), a, b);
        assertTrue(x.c0 != y.c0 || x.c1 != y.c1, "beta did not affect the fold");
    }

    // ------------------------------------------------------------------ the leaf

    /// The quad leaf hash is domain-separated from the pair leaf hash.
    function test_theQuadLeafHasItsOwnDomain() public pure {
        F.Fp2 memory a = F.Fp2(1, 2);
        F.Fp2 memory b = F.Fp2(3, 4);
        assertTrue(
            MK.hashLeafQuad(a, b, F.zero(), F.zero()) != MK.hashLeafPair(a, b),
            "a quad leaf of two values and two zeros collided with a pair leaf"
        );
    }

    /// Each of the four values enters the quad leaf hash.
    function test_everyValueEntersTheLeaf() public pure {
        F.Fp2[4] memory v = [F.Fp2(1, 2), F.Fp2(3, 4), F.Fp2(5, 6), F.Fp2(7, 8)];
        bytes32 base = MK.hashLeafQuad(v[0], v[1], v[2], v[3]);
        for (uint256 i = 0; i < 4; ++i) {
            F.Fp2[4] memory w = v;
            w[i] = F.add(w[i], F.one());
            assertTrue(MK.hashLeafQuad(w[0], w[1], w[2], w[3]) != base, "a value is not in the leaf");
        }
    }

    /// Leaf order is committed: p, p+N/4, p+N/2, p+3N/4.
    function test_theLeafIsOrdered() public pure {
        F.Fp2 memory a = F.Fp2(1, 2);
        F.Fp2 memory b = F.Fp2(3, 4);
        F.Fp2 memory c = F.Fp2(5, 6);
        F.Fp2 memory d = F.Fp2(7, 8);
        assertTrue(MK.hashLeafQuad(a, b, c, d) != MK.hashLeafQuad(b, a, c, d), "the leaf is order blind");
    }

    // ------------------------------------------------------------------ what it buys

    /// Radix 4 carries fewer FRI bytes per query than radix 2.
    function test_whatRadixFourBuys() public pure {
        uint256 logDomain = 30;
        uint256 d = 24;
        uint256 stop = 8;
        uint256 blow = 9;

        uint256 layers2 = logDomain - blow - stop;
        uint256 b2 = 4;
        for (uint256 m = 0; m < layers2; ++m) b2 += 4 + 2 * 16 + d * (logDomain - 1 - m);

        uint256 layers4 = (logDomain - blow - stop + 1) / 2;
        uint256 b4 = 4;
        for (uint256 m = 0; m < layers4; ++m) b4 += 4 + 4 * 16 + d * (logDomain - 2 - 2 * m);

        console2.log("radix 2: layers", layers2, "FRI bytes a query", b2);
        console2.log("radix 4: layers", layers4, "FRI bytes a query", b4);
        console2.log("saved a query  ", b2 - b4);
        console2.log("saved at 9 q   ", 9 * (b2 - b4));
        assertLt(b4, b2, "radix 4 did not reduce the bytes");
    }
}
