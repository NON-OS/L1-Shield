// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StarkFieldExt} from "../../../contracts/shield/verifier/StarkFieldExt.sol";
import {SettlerGate} from "../../../contracts/shield/SettlerGate.sol";
import {ShieldLedger} from "../../../contracts/shield/ShieldLedger.sol";
import {Goldilocks} from "../../../contracts/shield/libraries/Goldilocks.sol";

/// Field properties the SMT solvers do not close inside the default timeout, as fuzz tests.
/// The reference forms products with plain 256-bit arithmetic and `%`, never with mulmod.
contract FieldFuzz is Test {
    using StarkFieldExt for StarkFieldExt.Fp2;

    uint256 constant P = 0xFFFFFFFF00000001;
    uint256 constant W = 7;

    function _c(uint256 x) internal pure returns (uint256) {
        return x % P;
    }

    function testFuzz_fpMulMatchesTheReference(uint256 a, uint256 b) public pure {
        a = _c(a);
        b = _c(b);
        assertEq(StarkFieldExt.fpMul(a, b), (a * b) % P);
    }

    /// For every non-zero canonical x, x * inv(x) = 1.
    function testFuzz_fpInvIsTheInverse(uint256 x) public pure {
        x = _c(x);
        vm.assume(x != 0);
        assertEq((x * StarkFieldExt.fpInv(x)) % P, 1);
    }

    /// The addition chain agrees with square-and-multiply to the exponent p - 2 (Fermat).
    function testFuzz_fpInvAgreesWithFermat(uint256 x) public pure {
        x = _c(x);
        assertEq(StarkFieldExt.fpInv(x), StarkFieldExt.fpPow(x, P - 2));
    }

    /// The inverse at 1, p - 1, 2^32, 2^32 - 1, 2^63 and the generator.
    function test_fpInvAtTheEdges() public pure {
        uint256[6] memory xs = [uint256(1), P - 1, 1 << 32, (1 << 32) - 1, 1 << 63, 7];
        for (uint256 i = 0; i < xs.length; ++i) {
            assertEq((xs[i] * StarkFieldExt.fpInv(xs[i])) % P, 1);
        }
    }

    /// Fp2 mul is (a0 + a1 X)(b0 + b1 X) with X^2 = 7.
    function testFuzz_fp2MulMatchesTheReference(uint256 a0, uint256 a1, uint256 b0, uint256 b1) public pure {
        (a0, a1, b0, b1) = (_c(a0), _c(a1), _c(b0), _c(b1));
        StarkFieldExt.Fp2 memory m = StarkFieldExt.mul(StarkFieldExt.Fp2(a0, a1), StarkFieldExt.Fp2(b0, b1));
        assertEq(m.c0, (a0 * b0 + W * ((a1 * b1) % P)) % P);
        assertEq(m.c1, (a0 * b1 + a1 * b0) % P);
    }

    function testFuzz_fp2MulBaseMatchesTheReference(uint256 a0, uint256 a1, uint256 k) public pure {
        (a0, a1, k) = (_c(a0), _c(a1), _c(k));
        StarkFieldExt.Fp2 memory m = StarkFieldExt.mulBase(StarkFieldExt.Fp2(a0, a1), k);
        assertEq(m.c0, (a0 * k) % P);
        assertEq(m.c1, (a1 * k) % P);
    }

    /// a times its conjugate is its norm, in the base field.
    function testFuzz_fp2TimesConjugateIsNorm(uint256 a0, uint256 a1) public pure {
        StarkFieldExt.Fp2 memory a = StarkFieldExt.Fp2(_c(a0), _c(a1));
        StarkFieldExt.Fp2 memory m = StarkFieldExt.mul(a, StarkFieldExt.conjugate(a));
        assertEq(m.c1, 0);
        assertEq(m.c0, StarkFieldExt.norm(a));
    }

    /// For every non-zero a in Fp2, a * inv(a) = 1, and the norm of a is non-zero.
    function testFuzz_fp2InvIsTheInverse(uint256 a0, uint256 a1) public pure {
        StarkFieldExt.Fp2 memory a = StarkFieldExt.Fp2(_c(a0), _c(a1));
        vm.assume(!a.isZero());
        assertTrue(StarkFieldExt.norm(a) != 0, "a non-zero element with zero norm");
        StarkFieldExt.Fp2 memory one = StarkFieldExt.mul(a, StarkFieldExt.inv(a));
        assertEq(one.c0, 1);
        assertEq(one.c1, 0);
    }

    /// Inversion of purely real and purely imaginary elements.
    function testFuzz_fp2InvOnTheAxes(uint256 x) public pure {
        x = _c(x);
        vm.assume(x != 0);
        StarkFieldExt.Fp2 memory r = StarkFieldExt.mul(StarkFieldExt.Fp2(x, 0), StarkFieldExt.inv(StarkFieldExt.Fp2(x, 0)));
        assertTrue(r.c0 == 1 && r.c1 == 0);
        StarkFieldExt.Fp2 memory i = StarkFieldExt.mul(StarkFieldExt.Fp2(0, x), StarkFieldExt.inv(StarkFieldExt.Fp2(0, x)));
        assertTrue(i.c0 == 1 && i.c1 == 0);
    }

    /// 7 is a quadratic non-residue: 7^((p-1)/2) = -1. Otherwise Fp2 is not a field.
    function test_sevenIsANonResidue() public pure {
        assertEq(StarkFieldExt.fpPow(W, (P - 1) / 2), P - 1);
    }

    function testFuzz_batchInvAgreesWithInv(uint256 s0, uint256 s1, uint256 s2) public pure {
        StarkFieldExt.Fp2[] memory xs = new StarkFieldExt.Fp2[](3);
        xs[0] = StarkFieldExt.Fp2(_c(s0) | 1, _c(s1));
        xs[1] = StarkFieldExt.Fp2(_c(s1), _c(s2) | 1);
        xs[2] = StarkFieldExt.Fp2(_c(s2) | 1, _c(s0) | 1);
        StarkFieldExt.Fp2[] memory out = StarkFieldExt.batchInv(xs);
        for (uint256 i = 0; i < 3; ++i) {
            StarkFieldExt.Fp2 memory want = StarkFieldExt.inv(xs[i]);
            assertTrue(out[i].eq(want), "batch inverse differs");
        }
    }
}

/// The open-slot rule over the uint64 timestamp range, as a fuzz test. The symbolic form in
/// test/shield/halmos/SettlerGate.halmos.t.sol does not finish inside the default timeout.
contract SettlerSlotFuzz is Test {
    uint256 constant EPOCH = 24 hours;
    uint256 constant SLOT = 1 hours;

    /// From any timestamp a slot starts less than one epoch later, or the timestamp is inside one.
    function testFuzz_theOpenSlotIsNeverMoreThanAnEpochAway(uint64 t) public pure {
        uint256 r = uint256(t) % EPOCH;
        uint256 wait = r >= EPOCH - SLOT ? 0 : EPOCH - SLOT - r;
        assertLt(wait, EPOCH);
        assertTrue(SettlerGate.inOpenSlot(uint256(t) + wait, EPOCH, SLOT));
        if (wait > 0) assertFalse(SettlerGate.inOpenSlot(uint256(t) + wait - 1, EPOCH, SLOT), "slot starts early");
    }

    /// The slot is the last SLOT seconds of each epoch and nothing else.
    function testFuzz_theOpenSlotIsTheLastHourOfEveryEpoch(uint64 t) public pure {
        assertEq(SettlerGate.inOpenSlot(t, EPOCH, SLOT), uint256(t) % EPOCH >= EPOCH - SLOT);
    }

    /// Composed as the pool composes it: outside the window and the slot only the settler is let in.
    function testFuzz_outsideWindowAndSlotOnlyTheSettlerSettles(address settler, address caller, uint64 last, uint64 t)
        public
        pure
    {
        vm.assume(uint256(t) % EPOCH < EPOCH - SLOT);
        vm.assume(uint256(t) < uint256(last) + 24 hours);
        bool allowed = SettlerGate.open(settler, caller, last, t, 24 hours) || SettlerGate.inOpenSlot(t, EPOCH, SLOT);
        assertEq(allowed, settler == address(0) || caller == settler);
    }

    /// Inside the slot everyone is let in.
    function testFuzz_insideTheSlotEveryoneSettles(address settler, address caller, uint64 last, uint64 t0, uint16 x)
        public
        pure
    {
        // move t0 into its epoch's slot, so no draw is rejected
        uint256 t = uint256(t0) - (uint256(t0) % EPOCH) + (EPOCH - SLOT) + (uint256(x) % SLOT);
        assertTrue(SettlerGate.open(settler, caller, last, t, 24 hours) || SettlerGate.inOpenSlot(t, EPOCH, SLOT));
    }
}

/// Deposit-fee rounding, as a fuzz test. The symbolic form times out.
contract LedgerRoundingFuzz is Test {
    /// The deposit fee is the exact fee rounded down, short by less than one unit, and
    /// fee + value equals the amount.
    function testFuzz_theDepositFeeRoundsDownByLessThanOneUnit(uint256 amount, uint16 feeBps) public pure {
        amount = bound(amount, 0, Goldilocks.MAX_VALUE);
        feeBps = uint16(bound(feeBps, 0, 50));
        (uint256 fee, uint256 value) = ShieldLedger.splitDeposit(amount, feeBps);
        assertLe(fee * 10_000, amount * feeBps);
        assertLt(amount * feeBps, (fee + 1) * 10_000);
        assertEq(fee + value, amount);
    }
}
