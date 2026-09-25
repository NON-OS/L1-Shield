// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title GoldilocksCore
/// @notice Goldilocks Fp and Fp2 = Fp[X]/(X^2 - 7) on bare words, the arithmetic every field
///         routine of the verifier calls. StarkFieldExt wraps it for Fp2 structs.
/// @dev Stack only, results canonical. Where the Solidity form reverts, these revert with the same
///      Panic(0x11). The reference twin is test/shield/reference/GoldilocksCoreRef.sol.
library GoldilocksCore {
    uint256 internal constant P = 0xFFFFFFFF00000001;
    /// @dev X^2 = W, a quadratic non-residue mod P.
    uint256 internal constant W = 7;
    uint256 internal constant HALF = 0x7FFFFFFF80000001; // 1/2 mod P, the halving of a radix-2 fold
    /// @dev Panic(uint256) selector and the arithmetic-underflow code Solidity 0.8 raises.
    uint256 internal constant PANIC_SELECTOR = 0x4e487b71;
    uint256 internal constant PANIC_UNDERFLOW = 0x11;

    function mul(uint256 a, uint256 b) internal pure returns (uint256 r) {
        assembly {
            r := mulmod(a, b, P)
        }
    }

    function add(uint256 a, uint256 b) internal pure returns (uint256 r) {
        assembly {
            r := addmod(a, b, P)
        }
    }

    /// @notice a - b. Reverts with Panic(0x11) for b > P, as `addmod(a, P - b, P)` does.
    function sub(uint256 a, uint256 b) internal pure returns (uint256 r) {
        assembly {
            if gt(b, P) { _panicUnderflow() }
            r := addmod(a, sub(P, b), P)
            // Panic(0x11) laid out in scratch space 0x00..0x24, which nothing reads after the revert
            function _panicUnderflow() {
                mstore(0x00, shl(224, PANIC_SELECTOR))
                mstore(0x04, PANIC_UNDERFLOW)
                revert(0x00, 0x24)
            }
        }
    }

    /// @notice -a for a canonical a. Reverts with Panic(0x11) for a > P.
    function neg(uint256 a) internal pure returns (uint256 r) {
        assembly {
            if gt(a, P) { _panicUnderflow() }
            if a { r := sub(P, a) }
            function _panicUnderflow() {
                mstore(0x00, shl(224, PANIC_SELECTOR))
                mstore(0x04, PANIC_UNDERFLOW)
                revert(0x00, 0x24)
            }
        }
    }

    /// @notice base^e by square and multiply over the bits of e, low bit first.
    function pow(uint256 base, uint256 e) internal pure returns (uint256 acc) {
        assembly {
            acc := 1
            base := mod(base, P)
            for {} e {} {
                if and(e, 1) { acc := mulmod(acc, base, P) }
                base := mulmod(base, base, P)
                if and(e, 2) { acc := mulmod(acc, base, P) }
                base := mulmod(base, base, P)
                e := shr(2, e)
            }
        }
    }

    /// @notice a^(P - 2), zero for zero: 63 squarings and 9 multiplications, fully unrolled.
    function inv(uint256 a) internal pure returns (uint256 r) {
        assembly {
            // each name holds a^(2^k - 1), and is overwritten once its last use has passed
            let a1 := mod(a, P)
            let x := mulmod(mulmod(a1, a1, P), a1, P) // 2^2 - 1
            x := mulmod(mulmod(x, x, P), a1, P) // 2^3 - 1
            x := mulmod(_sq(x, 3), x, P) // 2^6 - 1
            x := mulmod(mulmod(x, x, P), a1, P) // 2^7 - 1
            x := mulmod(_sq(x, 7), x, P) // 2^14 - 1
            x := mulmod(mulmod(x, x, P), a1, P) // 2^15 - 1
            x := mulmod(_sq(x, 15), x, P) // 2^30 - 1
            x := mulmod(mulmod(x, x, P), a1, P) // 2^31 - 1
            let a32 := mulmod(mulmod(x, x, P), a1, P) // 2^32 - 1
            r := mulmod(_sq(x, 33), a32, P)

            function _sq(v, k) -> y {
                y := v
                for {} gt(k, 2) { k := sub(k, 3) } {
                    y := mulmod(y, y, P)
                    y := mulmod(y, y, P)
                    y := mulmod(y, y, P)
                }
                for {} k { k := sub(k, 1) } { y := mulmod(y, y, P) }
            }
        }
    }

    /// @notice (a0 + a1 X)(b0 + b1 X) = (a0 b0 + W a1 b1) + (a0 b1 + a1 b0) X
    function mul2(uint256 a0, uint256 a1, uint256 b0, uint256 b1) internal pure returns (uint256 r0, uint256 r1) {
        assembly {
            r0 := addmod(mulmod(a0, b0, P), mulmod(W, mulmod(a1, b1, P), P), P)
            r1 := addmod(mulmod(a0, b1, P), mulmod(a1, b0, P), P)
        }
    }

    /// @notice (a0 + a1 X)^2
    function sqr2(uint256 a0, uint256 a1) internal pure returns (uint256 r0, uint256 r1) {
        assembly {
            r0 := addmod(mulmod(a0, a0, P), mulmod(W, mulmod(a1, a1, P), P), P)
            r1 := mulmod(2, mulmod(a0, a1, P), P)
        }
    }

    /// @notice (a0 + a1 X)^-1 = (a0 - a1 X) / (a0^2 - W a1^2), zero for the zero word pair.
    /// @dev A non-zero pair with a1 > P reverts with Panic(0x11), as the conjugate's negation does.
    function inv2(uint256 a0, uint256 a1) internal pure returns (uint256 r0, uint256 r1) {
        if (a0 == 0 && a1 == 0) return (0, 0);
        uint256 n;
        assembly {
            n := addmod(mulmod(a0, a0, P), sub(P, mulmod(W, mulmod(a1, a1, P), P)), P)
        }
        uint256 ni = inv(n);
        uint256 c1 = neg(a1);
        assembly {
            r0 := mulmod(a0, ni, P)
            r1 := mulmod(c1, ni, P)
        }
    }

    /// @notice One radix-2 FRI fold: (a + b)/2 + beta (a - b)/(2x), with invx = 1/x.
    /// @dev Reverts with Panic(0x11) for b0 or b1 above P, the checked `P - b` of the Solidity form.
    function fold2(uint256 a0, uint256 a1, uint256 b0, uint256 b1, uint256 be0, uint256 be1, uint256 invx)
        internal
        pure
        returns (uint256 r0, uint256 r1)
    {
        assembly {
            if or(gt(b0, P), gt(b1, P)) { _panicUnderflow() }
            // built in the output slots and the spent invx slot: seven inputs leave no stack room for more names
            invx := mulmod(HALF, invx, P)
            r0 := mulmod(addmod(a0, sub(P, b0), P), invx, P)
            r1 := mulmod(addmod(a1, sub(P, b1), P), invx, P)
            invx := addmod(mulmod(be0, r0, P), mulmod(W, mulmod(be1, r1, P), P), P)
            r1 := addmod(mulmod(be0, r1, P), mulmod(be1, r0, P), P)
            r0 := addmod(mulmod(addmod(a0, b0, P), HALF, P), invx, P)
            r1 := addmod(mulmod(addmod(a1, b1, P), HALF, P), r1, P)
            function _panicUnderflow() {
                mstore(0x00, shl(224, PANIC_SELECTOR))
                mstore(0x04, PANIC_UNDERFLOW)
                revert(0x00, 0x24)
            }
        }
    }
}
