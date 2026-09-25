// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title StarkFieldExt
/// @notice Goldilocks field Fp and its extension Fp2 = Fp[X]/(X^2 - 7).
/// @dev Inputs must be canonical. fpSub and sub revert when the subtrahend exceeds P.
library StarkFieldExt {
    uint256 internal constant P = 0xFFFFFFFF00000001; // 2^64 - 2^32 + 1
    uint256 internal constant W = 7; // X^2 = W, a non-residue
    uint256 internal constant GENERATOR = 7; // also the coset shift

    struct Fp2 { // c0 + c1 X
        uint256 c0;
        uint256 c1;
    }

    function fpAdd(uint256 a, uint256 b) internal pure returns (uint256) {
        return addmod(a, b, P);
    }

    function fpSub(uint256 a, uint256 b) internal pure returns (uint256) {
        return addmod(a, P - b, P);
    }

    function fpNeg(uint256 a) internal pure returns (uint256) {
        return a == 0 ? 0 : P - a;
    }

    function fpMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return mulmod(a, b, P);
    }

    function fpPow(uint256 base, uint256 exp) internal pure returns (uint256 acc) {
        acc = 1;
        base %= P;
        while (exp != 0) {
            if (exp & 1 == 1) acc = mulmod(acc, base, P);
            base = mulmod(base, base, P);
            exp >>= 1;
        }
    }

    // a^(p - 2) by an addition chain, p - 2 = (2^31 - 1) * 2^33 + (2^32 - 1). Returns 0 for 0.
    function fpInv(uint256 a) internal pure returns (uint256) {
        uint256 a1 = a % P;
        uint256 a2 = mulmod(_pow2(a1, 1), a1, P); // 2^2-1
        uint256 a3 = mulmod(_pow2(a2, 1), a1, P); // 2^3-1
        uint256 a6 = mulmod(_pow2(a3, 3), a3, P); // 2^6-1
        uint256 a7 = mulmod(_pow2(a6, 1), a1, P); // 2^7-1
        uint256 a14 = mulmod(_pow2(a7, 7), a7, P); // 2^14-1
        uint256 a15 = mulmod(_pow2(a14, 1), a1, P); // 2^15-1
        uint256 a30 = mulmod(_pow2(a15, 15), a15, P); // 2^30-1
        uint256 a31 = mulmod(_pow2(a30, 1), a1, P); // 2^31-1
        uint256 a32 = mulmod(_pow2(a31, 1), a1, P); // 2^32-1
        return mulmod(_pow2(a31, 33), a32, P);
    }

    // x^(2^k)
    function _pow2(uint256 x, uint256 k) private pure returns (uint256) {
        for (uint256 i = 0; i < k; ++i) {
            x = mulmod(x, x, P);
        }
        return x;
    }

    function fp2(uint256 c0, uint256 c1) internal pure returns (Fp2 memory) {
        return Fp2(c0, c1);
    }

    function fromBase(uint256 a) internal pure returns (Fp2 memory) {
        return Fp2(a, 0);
    }

    function zero() internal pure returns (Fp2 memory) {
        return Fp2(0, 0);
    }

    function one() internal pure returns (Fp2 memory) {
        return Fp2(1, 0);
    }

    function eq(Fp2 memory a, Fp2 memory b) internal pure returns (bool) {
        return a.c0 == b.c0 && a.c1 == b.c1;
    }

    function isZero(Fp2 memory a) internal pure returns (bool) {
        return a.c0 == 0 && a.c1 == 0;
    }

    function add(Fp2 memory a, Fp2 memory b) internal pure returns (Fp2 memory) {
        return Fp2(addmod(a.c0, b.c0, P), addmod(a.c1, b.c1, P));
    }

    function sub(Fp2 memory a, Fp2 memory b) internal pure returns (Fp2 memory) {
        return Fp2(addmod(a.c0, P - b.c0, P), addmod(a.c1, P - b.c1, P));
    }

    function neg(Fp2 memory a) internal pure returns (Fp2 memory) {
        return Fp2(fpNeg(a.c0), fpNeg(a.c1));
    }

    // (a + bX)(c + dX) = (ac + W bd) + (ad + bc)X
    function mul(Fp2 memory a, Fp2 memory b) internal pure returns (Fp2 memory) {
        uint256 ac = mulmod(a.c0, b.c0, P);
        uint256 bd = mulmod(a.c1, b.c1, P);
        uint256 ad = mulmod(a.c0, b.c1, P);
        uint256 bc = mulmod(a.c1, b.c0, P);
        return Fp2(addmod(ac, mulmod(W, bd, P), P), addmod(ad, bc, P));
    }

    function mulBase(Fp2 memory a, uint256 s) internal pure returns (Fp2 memory) {
        return Fp2(mulmod(a.c0, s, P), mulmod(a.c1, s, P));
    }

    function conjugate(Fp2 memory a) internal pure returns (Fp2 memory) {
        return Fp2(a.c0, fpNeg(a.c1));
    }

    // N = c0^2 - W c1^2, zero only at zero
    function norm(Fp2 memory a) internal pure returns (uint256) {
        uint256 c0sq = mulmod(a.c0, a.c0, P);
        uint256 c1sq = mulmod(a.c1, a.c1, P);
        return addmod(c0sq, P - mulmod(W, c1sq, P), P);
    }

    function square(Fp2 memory a) internal pure returns (Fp2 memory) {
        return mul(a, a);
    }

    // conj(a) / N. Returns zero for zero, so callers must exclude a zero denominator.
    function inv(Fp2 memory a) internal pure returns (Fp2 memory) {
        if (isZero(a)) return Fp2(0, 0);
        uint256 nInv = fpInv(norm(a));
        Fp2 memory conj = conjugate(a);
        return Fp2(mulmod(conj.c0, nInv, P), mulmod(conj.c1, nInv, P));
    }

    function pow(Fp2 memory a, uint256 exp) internal pure returns (Fp2 memory acc) {
        acc = Fp2(1, 0);
        Fp2 memory base = a;
        while (exp != 0) {
            if (exp & 1 == 1) acc = mul(acc, base);
            base = square(base);
            exp >>= 1;
        }
    }

    // primitive 2^logN-th root of unity, valid for logN <= 32
    function rootOfUnity(uint32 logN) internal pure returns (uint256) {
        return fpPow(GENERATOR, (P - 1) >> logN);
    }

    // O(n^2) reference Lagrange evaluation at z, used for parity tests. xs must be distinct.
    function evalLagrangeExt(uint256[] memory xs, uint256[] memory ys, Fp2 memory z)
        internal
        pure
        returns (Fp2 memory acc)
    {
        uint256 n = xs.length < ys.length ? xs.length : ys.length;
        acc = Fp2(0, 0);
        for (uint256 i = 0; i < n; ++i) {
            Fp2 memory num = Fp2(1, 0);
            uint256 den = 1;
            for (uint256 j = 0; j < n; ++j) {
                if (i != j) {
                    num = mul(num, sub(z, fromBase(xs[j])));
                    den = mulmod(den, addmod(xs[i], P - xs[j], P), P);
                }
            }
            acc = add(acc, mul(fromBase(ys[i]), mulBase(num, fpInv(den))));
        }
    }

    // Montgomery batch inversion. Inputs must be nonzero, one zero input zeroes every output.
    function batchInv(Fp2[] memory a) internal pure returns (Fp2[] memory out) {
        uint256 n = a.length;
        out = new Fp2[](n);
        Fp2[] memory prefix = new Fp2[](n + 1);
        prefix[0] = Fp2(1, 0);
        for (uint256 i = 0; i < n; ++i) {
            prefix[i + 1] = mul(prefix[i], a[i]);
        }
        Fp2 memory acc = inv(prefix[n]);
        for (uint256 i = n; i > 0; --i) {
            out[i - 1] = mul(acc, prefix[i - 1]);
            acc = mul(acc, a[i - 1]);
        }
    }

    // L(z) = (z^n - 1) / n * sum_i y_i g^i / (z - g^i) over powG = [g^i]. z must be off the subgroup.
    function evalLagrangeUnity(uint256[] memory powG, uint256[][] memory cols, Fp2 memory z)
        internal
        pure
        returns (Fp2[] memory outVals)
    {
        uint256 n = powG.length;
        Fp2[] memory denom = new Fp2[](n);
        for (uint256 i = 0; i < n; ++i) {
            denom[i] = sub(z, fromBase(powG[i]));
        }
        Fp2[] memory invDenom = batchInv(denom);
        Fp2 memory factor = mulBase(sub(pow(z, n), Fp2(1, 0)), fpInv(n));

        outVals = new Fp2[](cols.length);
        for (uint256 col = 0; col < cols.length; ++col) {
            outVals[col] = mul(factor, _lagrangeColumnSum(powG, cols[col], invDenom));
        }
    }

    function _lagrangeColumnSum(uint256[] memory powG, uint256[] memory ys, Fp2[] memory invDenom)
        private
        pure
        returns (Fp2 memory sum)
    {
        sum = Fp2(0, 0);
        for (uint256 i = 0; i < ys.length; ++i) {
            if (ys[i] != 0) {
                sum = add(sum, mulBase(invDenom[i], mulmod(ys[i], powG[i], P)));
            }
        }
    }
}
