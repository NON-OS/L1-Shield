// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {Test} from "forge-std/Test.sol";
import {Goldilocks} from "../../../contracts/shield/libraries/Goldilocks.sol";
import {StarkFieldExt} from "../../../contracts/shield/verifier/StarkFieldExt.sol";

/// Halmos checks of the Goldilocks field and its extension against a plain `%` reference.
/// Two-operand mulmod properties time out and are fuzzed in test/shield/invariants/FieldFuzz.t.sol.
contract FieldHalmos is SymTest, Test {
    uint256 constant P = 0xFFFFFFFF00000001;

    /// A limb is canonical if and only if it is below p.
    function check_aLimbIsCanonicalExactlyBelowP(uint256 v) public pure {
        assert(Goldilocks.isCanonicalLimb(v) == (v < P));
    }

    /// A digest is canonical if and only if each 64-bit limb is below p.
    function check_aDigestIsCanonicalExactlyWhenEveryLimbIs(bytes32 d) public pure {
        uint256 v = uint256(d);
        bool ref = (v % 2 ** 64) < P && ((v / 2 ** 64) % 2 ** 64) < P && ((v / 2 ** 128) % 2 ** 64) < P
            && (v / 2 ** 192) < P;
        assert(Goldilocks.isCanonicalDigest(d) == ref);
    }

    /// limb(d, i) reads limb i, low limb first.
    function check_limbReadsTheRightBits(bytes32 d) public pure {
        uint256 v = uint256(d);
        assert(Goldilocks.limb(d, 0) == v % 2 ** 64);
        assert(Goldilocks.limb(d, 1) == (v / 2 ** 64) % 2 ** 64);
        assert(Goldilocks.limb(d, 2) == (v / 2 ** 128) % 2 ** 64);
        assert(Goldilocks.limb(d, 3) == v / 2 ** 192);
    }

    /// Four canonical limbs pack into a canonical digest and read back unchanged.
    function check_packingFourCanonicalLimbsRoundTrips(uint64 a, uint64 b, uint64 c, uint64 e) public pure {
        vm.assume(a < P && b < P && c < P && e < P);
        bytes32 d = bytes32(uint256(a) | (uint256(b) << 64) | (uint256(c) << 128) | (uint256(e) << 192));
        assert(Goldilocks.isCanonicalDigest(d));
        assert(Goldilocks.limb(d, 0) == a && Goldilocks.limb(d, 1) == b);
        assert(Goldilocks.limb(d, 2) == c && Goldilocks.limb(d, 3) == e);
    }

    /// Every amount up to MAX_VALUE, and one more, is a canonical limb.
    function check_everyAcceptedAmountIsCanonical(uint256 v) public pure {
        vm.assume(v <= Goldilocks.MAX_VALUE);
        assert(Goldilocks.isCanonicalLimb(v));
        assert(Goldilocks.isCanonicalLimb(v + 1));
    }

    /// fpAdd is addition mod p and stays canonical.
    function check_fpAdd(uint64 a, uint64 b) public pure {
        vm.assume(a < P && b < P);
        uint256 r = StarkFieldExt.fpAdd(a, b);
        assert(r == (uint256(a) + b) % P);
        assert(r < P);
    }

    /// fpSub is subtraction mod p for canonical operands: (a - b) + b = a.
    function check_fpSub(uint64 a, uint64 b) public pure {
        vm.assume(a < P && b < P);
        uint256 r = StarkFieldExt.fpSub(a, b);
        assert(r < P);
        assert((r + b) % P == a);
    }

    /// fpNeg is the additive inverse and maps zero to zero, never to p.
    function check_fpNeg(uint64 a) public pure {
        vm.assume(a < P);
        uint256 r = StarkFieldExt.fpNeg(a);
        assert(r < P);
        assert((r + a) % P == 0);
    }

    /// fpInv(0) is 0. Callers that divide must rule out zero.
    function check_fpInvOfZeroIsZero() public pure {
        assert(StarkFieldExt.fpInv(0) == 0);
    }

    function check_fp2AddSub(uint64 a0, uint64 a1, uint64 b0, uint64 b1) public pure {
        vm.assume(a0 < P && a1 < P && b0 < P && b1 < P);
        StarkFieldExt.Fp2 memory a = StarkFieldExt.Fp2(a0, a1);
        StarkFieldExt.Fp2 memory b = StarkFieldExt.Fp2(b0, b1);
        StarkFieldExt.Fp2 memory s = StarkFieldExt.add(a, b);
        assert(s.c0 == (uint256(a0) + b0) % P && s.c1 == (uint256(a1) + b1) % P);
        StarkFieldExt.Fp2 memory back = StarkFieldExt.sub(s, b);
        assert(back.c0 == a0 && back.c1 == a1);
    }

    function check_fp2Neg(uint64 a0, uint64 a1) public pure {
        vm.assume(a0 < P && a1 < P);
        StarkFieldExt.Fp2 memory a = StarkFieldExt.Fp2(a0, a1);
        StarkFieldExt.Fp2 memory z = StarkFieldExt.add(a, StarkFieldExt.neg(a));
        assert(z.c0 == 0 && z.c1 == 0);
    }

    /// inv of zero is zero, the documented sentinel.
    function check_fp2InvOfZeroIsZero() public pure {
        StarkFieldExt.Fp2 memory z = StarkFieldExt.inv(StarkFieldExt.Fp2(0, 0));
        assert(z.c0 == 0 && z.c1 == 0);
    }
}
