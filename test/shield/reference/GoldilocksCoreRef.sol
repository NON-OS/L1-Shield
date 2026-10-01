// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title GoldilocksCoreRef
/// @notice The Solidity twin of contracts/shield/verifier/GoldilocksCore.sol. Test-only, never
///         deployed: it is what the Yul is held to, bit for bit, including every revert.
library GoldilocksCoreRef {
    uint256 internal constant P = 0xFFFFFFFF00000001;
    uint256 internal constant W = 7;
    uint256 internal constant HALF = 9223372034707292161;

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        return mulmod(a, b, P);
    }

    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return addmod(a, b, P);
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return addmod(a, P - b, P);
    }

    function neg(uint256 a) internal pure returns (uint256) {
        return a == 0 ? 0 : P - a;
    }

    function pow(uint256 base, uint256 exp) internal pure returns (uint256 acc) {
        acc = 1;
        base %= P;
        while (exp != 0) {
            if (exp & 1 == 1) acc = mulmod(acc, base, P);
            base = mulmod(base, base, P);
            exp >>= 1;
        }
    }

    function inv(uint256 a) internal pure returns (uint256) {
        uint256 a1 = a % P;
        uint256 a2 = mulmod(_pow2(a1, 1), a1, P);
        uint256 a3 = mulmod(_pow2(a2, 1), a1, P);
        uint256 a6 = mulmod(_pow2(a3, 3), a3, P);
        uint256 a7 = mulmod(_pow2(a6, 1), a1, P);
        uint256 a14 = mulmod(_pow2(a7, 7), a7, P);
        uint256 a15 = mulmod(_pow2(a14, 1), a1, P);
        uint256 a30 = mulmod(_pow2(a15, 15), a15, P);
        uint256 a31 = mulmod(_pow2(a30, 1), a1, P);
        uint256 a32 = mulmod(_pow2(a31, 1), a1, P);
        return mulmod(_pow2(a31, 33), a32, P);
    }

    function _pow2(uint256 x, uint256 k) private pure returns (uint256) {
        for (uint256 i = 0; i < k; ++i) {
            x = mulmod(x, x, P);
        }
        return x;
    }

    function mul2(uint256 a0, uint256 a1, uint256 b0, uint256 b1) internal pure returns (uint256, uint256) {
        uint256 ac = mulmod(a0, b0, P);
        uint256 bd = mulmod(a1, b1, P);
        return (addmod(ac, mulmod(W, bd, P), P), addmod(mulmod(a0, b1, P), mulmod(a1, b0, P), P));
    }

    function sqr2(uint256 a0, uint256 a1) internal pure returns (uint256, uint256) {
        return mul2(a0, a1, a0, a1);
    }

    function inv2(uint256 a0, uint256 a1) internal pure returns (uint256, uint256) {
        if (a0 == 0 && a1 == 0) return (0, 0);
        uint256 n = addmod(mulmod(a0, a0, P), P - mulmod(W, mulmod(a1, a1, P), P), P);
        uint256 ni = inv(n);
        uint256 c1 = neg(a1);
        return (mulmod(a0, ni, P), mulmod(c1, ni, P));
    }

    function fold2(uint256 a0, uint256 a1, uint256 b0, uint256 b1, uint256 be0, uint256 be1, uint256 invx)
        internal
        pure
        returns (uint256 r0, uint256 r1)
    {
        (r0, r1) = _betaOdd(a0, a1, b0, b1, be0, be1, invx);
        r0 = addmod(mulmod(addmod(a0, b0, P), HALF, P), r0, P);
        r1 = addmod(mulmod(addmod(a1, b1, P), HALF, P), r1, P);
    }

    // beta (a - b) / (2x)
    function _betaOdd(uint256 a0, uint256 a1, uint256 b0, uint256 b1, uint256 be0, uint256 be1, uint256 invx)
        private
        pure
        returns (uint256, uint256)
    {
        uint256[2] memory o;
        uint256 s = mulmod(HALF, invx, P);
        o[0] = mulmod(addmod(a0, P - b0, P), s, P);
        o[1] = mulmod(addmod(a1, P - b1, P), s, P);
        return (
            addmod(mulmod(be0, o[0], P), mulmod(W, mulmod(be1, o[1], P), P), P),
            addmod(mulmod(be0, o[1], P), mulmod(be1, o[0], P), P)
        );
    }
}
