// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";

/// @notice Fp, Fp² and domain arithmetic held to field laws by fuzzing: inverses, commutativity,
///         associativity, from_base homomorphism, X² = 7, norm, and root-of-unity order.
contract StarkFieldExtTest is Test {
    using F for F.Fp2;

    uint256 constant P = 0xFFFFFFFF00000001;

    function _fp(uint256 x) internal pure returns (uint256) {
        return x % P;
    }

    // -------- base field --------

    function testFuzz_FpInverse(uint256 a) public pure {
        a = _fp(a);
        vm.assume(a != 0);
        assertEq(F.fpMul(a, F.fpInv(a)), 1, "a * a^-1 != 1");
    }

    /// @notice The addition-chain inverse equals generic Fermat a^(p-2) for every input.
    function testFuzz_FpInvMatchesGenericPow(uint256 a) public pure {
        a = _fp(a);
        assertEq(F.fpInv(a), F.fpPow(a, P - 2), "addition-chain inverse != a^(p-2)");
    }

    function testFuzz_FpPowMatchesRepeatedMul(uint256 a) public pure {
        a = _fp(a);
        uint256 cube = F.fpMul(F.fpMul(a, a), a);
        assertEq(F.fpPow(a, 3), cube, "a^3 mismatch");
    }

    // -------- extension field --------

    function test_XSquaredIsSeven() public pure {
        // X = (0 + 1·X), and X² must equal the non-residue W = 7.
        F.Fp2 memory x = F.fp2(0, 1);
        assertTrue(F.eq(F.square(x), F.fp2(7, 0)), "X^2 != 7");
    }

    function testFuzz_FromBaseIsHomomorphic(uint256 a, uint256 b) public pure {
        a = _fp(a);
        b = _fp(b);
        // from_base(a) * from_base(b) == from_base(a*b)
        F.Fp2 memory lhs = F.mul(F.fromBase(a), F.fromBase(b));
        F.Fp2 memory rhs = F.fromBase(F.fpMul(a, b));
        assertTrue(F.eq(lhs, rhs), "from_base not multiplicative");
    }

    function testFuzz_Fp2MulCommutes(uint256 a0, uint256 a1, uint256 b0, uint256 b1) public pure {
        F.Fp2 memory a = F.fp2(_fp(a0), _fp(a1));
        F.Fp2 memory b = F.fp2(_fp(b0), _fp(b1));
        assertTrue(F.eq(F.mul(a, b), F.mul(b, a)), "mul not commutative");
    }

    function testFuzz_Fp2MulAssociates(uint256 a0, uint256 a1, uint256 b0, uint256 b1, uint256 c0, uint256 c1)
        public
        pure
    {
        F.Fp2 memory a = F.fp2(_fp(a0), _fp(a1));
        F.Fp2 memory b = F.fp2(_fp(b0), _fp(b1));
        F.Fp2 memory c = F.fp2(_fp(c0), _fp(c1));
        assertTrue(F.eq(F.mul(F.mul(a, b), c), F.mul(a, F.mul(b, c))), "mul not associative");
    }

    function testFuzz_Fp2Inverse(uint256 a0, uint256 a1) public pure {
        F.Fp2 memory a = F.fp2(_fp(a0), _fp(a1));
        vm.assume(!F.isZero(a));
        assertTrue(F.eq(F.mul(a, F.inv(a)), F.one()), "a * a^-1 != 1 in Fp2");
    }

    function testFuzz_Fp2MulBaseMatchesMul(uint256 a0, uint256 a1, uint256 s) public pure {
        F.Fp2 memory a = F.fp2(_fp(a0), _fp(a1));
        uint256 sb = _fp(s);
        assertTrue(F.eq(F.mulBase(a, sb), F.mul(a, F.fromBase(sb))), "mulBase != mul by from_base");
    }

    function testFuzz_NormEqualsElementTimesConjugate(uint256 a0, uint256 a1) public pure {
        F.Fp2 memory a = F.fp2(_fp(a0), _fp(a1));
        // a * conj(a) == norm(a) embedded in the base.
        F.Fp2 memory prod = F.mul(a, F.conjugate(a));
        assertTrue(F.eq(prod, F.fromBase(F.norm(a))), "a*conj(a) != norm");
    }

    function testFuzz_Fp2PowMatchesRepeatedMul(uint256 a0, uint256 a1) public pure {
        F.Fp2 memory a = F.fp2(_fp(a0), _fp(a1));
        F.Fp2 memory cube = F.mul(F.mul(a, a), a);
        assertTrue(F.eq(F.pow(a, 3), cube), "Fp2 a^3 mismatch");
    }

    // -------- evaluation domain --------

    function test_RootOfUnityHasExactOrder() public pure {
        for (uint32 k = 1; k <= 20; ++k) {
            uint256 omega = F.rootOfUnity(k);
            // omega^(2^k) == 1
            assertEq(F.fpPow(omega, uint256(1) << k), 1, "omega^(2^k) != 1");
            // omega^(2^(k-1)) == -1 == P-1 (primitive: domain closed under negation)
            assertEq(F.fpPow(omega, uint256(1) << (k - 1)), P - 1, "omega^(2^(k-1)) != -1");
        }
    }
}
