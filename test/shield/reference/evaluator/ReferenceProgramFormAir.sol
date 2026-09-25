// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @notice Solidity reference for ProgramFormAir, test only. The differential tests in
///         test/shield/evaluator hold the production evaluator to it.
/// @notice The program-form outer's composition at z:
///         sum_i alpha_i C_i(z) E(z) / (z^t - 1) + sum_j alpha_{nOut+j} (frame[col_j] - v_j) / (z - g^row_j).
/// @dev C_i run as the straight-line program in `prog`. v_j is a constant, or for a pin the public
///      word it names. Inputs are Fp2 as (c0, c1) words below P, which the caller guarantees.
library ReferenceProgramFormAir {
    uint256 internal constant P = 0xFFFFFFFF00000001;

    /// @param frame     2 * window * width words, row-major, (c0, c1) per value
    /// @param periodic  2 * nPer words
    /// @param alphas    2 * (nOut + nBnd) words, in draw order
    /// @param publics   the statement's words, one Goldilocks element each
    /// @param point     [beta0, beta1, gamma0, gamma1, z0, z1], a base-field challenge with c1 zero
    function composition(
        bytes memory prog,
        uint256[] memory frame,
        uint256[] memory periodic,
        uint256[] memory alphas,
        uint256[] memory publics,
        uint256[6] memory point
    ) internal pure returns (uint256 c0, uint256 c1) {
        assembly ("memory-safe") {
            function f2mul(a0, a1, b0, b1) -> r0, r1 {
                let q := 0xFFFFFFFF00000001
                r0 := addmod(mulmod(a0, b0, q), mulmod(7, mulmod(a1, b1, q), q), q)
                r1 := addmod(mulmod(a0, b1, q), mulmod(a1, b0, q), q)
            }
            function fpinv(a) -> r {
                // a^(p-2), p - 2 = 0xFFFFFFFEFFFFFFFF
                let q := 0xFFFFFFFF00000001
                r := 1
                let e := 0xFFFFFFFEFFFFFFFF
                for {} e {} {
                    if and(e, 1) { r := mulmod(r, a, q) }
                    a := mulmod(a, a, q)
                    e := shr(1, e)
                }
            }
            function f2inv(a0, a1) -> r0, r1 {
                // 1 / (a0 + a1 u) = (a0 - a1 u) / (a0^2 - 7 a1^2)
                let q := 0xFFFFFFFF00000001
                let n := addmod(mulmod(a0, a0, q), sub(q, mulmod(7, mulmod(a1, a1, q), q)), q)
                if iszero(n) { revert(0, 0) }
                let i := fpinv(n)
                r0 := mulmod(a0, i, q)
                r1 := mulmod(sub(q, a1), i, q)
            }
            function rd(ptr, n) -> v { v := shr(sub(256, mul(8, n)), mload(ptr)) }
            function ld(base, i) -> a0, a1 {
                let at := add(base, shl(6, i))
                a0 := mload(at)
                a1 := mload(add(at, 32))
            }
            function st(base, i, a0, a1) {
                let at := add(base, shl(6, i))
                mstore(at, a0)
                mstore(add(at, 32), a1)
            }

            /*
             * ctx, in memory: 0 nOps, 1 nOut, 2 nBnd, 3 nRows, 4 nFrame, 5 nPer, 6 logT, 7 nEx,
             * 8 frame data, 9 periodic data, 10 alphas data, 11 publics data, 12 nPub, 13 beta0,
             * 14 beta1, 15 gamma0, 16 gamma1, 17 z0, 18 z1, 19 vals, 20 den, 21 pre.
             * Input slot nFrame + nPer is beta, the next gamma, each a whole Fp2.
             */
            function cx(ctx, k) -> v { v := mload(add(ctx, shl(5, k))) }

            function input(ctx, k) -> r0, r1 {
                let nFrame := cx(ctx, 4)
                switch lt(k, nFrame)
                case 1 { r0, r1 := ld(cx(ctx, 8), k) }
                default {
                    let q := sub(k, nFrame)
                    switch lt(q, cx(ctx, 5))
                    case 1 { r0, r1 := ld(cx(ctx, 9), q) }
                    default {
                        switch sub(q, cx(ctx, 5))
                        case 0 {
                            r0 := cx(ctx, 13)
                            r1 := cx(ctx, 14)
                        }
                        case 1 {
                            r0 := cx(ctx, 15)
                            r1 := cx(ctx, 16)
                        }
                        default { revert(0, 0) }
                    }
                }
            }

            function binop(kind, vals, pp) -> r0, r1 {
                let q := 0xFFFFFFFF00000001
                let a0, a1 := ld(vals, rd(add(pp, 1), 2))
                let b0, b1 := ld(vals, rd(add(pp, 3), 2))
                switch kind
                case 2 {
                    r0 := addmod(a0, b0, q)
                    r1 := addmod(a1, b1, q)
                }
                case 3 {
                    r0 := addmod(a0, sub(q, b0), q)
                    r1 := addmod(a1, sub(q, b1), q)
                }
                case 4 { r0, r1 := f2mul(a0, a1, b0, b1) }
                default { revert(0, 0) }
            }

            function program(ctx, pp) -> pq {
                let vals := cx(ctx, 19)
                let nOps := cx(ctx, 0)
                for { let i := 0 } lt(i, nOps) { i := add(i, 1) } {
                    let kind := rd(pp, 1)
                    let r0 := 0
                    let r1 := 0
                    switch kind
                    case 0 {
                        r0 := rd(add(pp, 1), 8)
                        r1 := rd(add(pp, 9), 8)
                        pp := add(pp, 17)
                    }
                    case 1 {
                        r0, r1 := input(ctx, rd(add(pp, 1), 2))
                        pp := add(pp, 3)
                    }
                    case 5 {
                        let a0, a1 := ld(vals, rd(add(pp, 1), 2))
                        r0, r1 := f2inv(a0, a1)
                        pp := add(pp, 3)
                    }
                    default {
                        r0, r1 := binop(kind, vals, pp)
                        pp := add(pp, 5)
                    }
                    st(vals, i, r0, r1)
                }
                pq := pp
            }

            // sum alpha_i C_i, times E(z) / (z^t - 1).
            function transitions(ctx, pp, e0, e1) -> pq, x0, x1 {
                let q := 0xFFFFFFFF00000001
                let s0 := 0
                let s1 := 0
                for { let i := 0 } lt(i, cx(ctx, 1)) { i := add(i, 1) } {
                    let v0, v1 := ld(cx(ctx, 19), rd(pp, 2))
                    pp := add(pp, 2)
                    let a0, a1 := ld(cx(ctx, 10), i)
                    let t0, t1 := f2mul(a0, a1, v0, v1)
                    s0 := addmod(s0, t0, q)
                    s1 := addmod(s1, t1, q)
                }
                let zt0 := cx(ctx, 17)
                let zt1 := cx(ctx, 18)
                for { let k := 0 } lt(k, cx(ctx, 6)) { k := add(k, 1) } { zt0, zt1 := f2mul(zt0, zt1, zt0, zt1) }
                let h0, h1 := f2inv(addmod(zt0, sub(q, 1), q), zt1)
                let f0, f1 := f2mul(e0, e1, h0, h1)
                x0, x1 := f2mul(s0, s1, f0, f1)
                pq := pp
            }

            // z - g^row for each distinct row, batch inverted in place.
            function rows(ctx, pp) -> pq {
                let q := 0xFFFFFFFF00000001
                let den := cx(ctx, 20)
                let pre := cx(ctx, 21)
                let z1 := cx(ctx, 18)
                let n := cx(ctx, 3)
                let q0 := 1
                let q1 := 0
                for { let r := 0 } lt(r, n) { r := add(r, 1) } {
                    let d0 := addmod(cx(ctx, 17), sub(q, rd(pp, 8)), q)
                    pp := add(pp, 8)
                    st(den, r, d0, z1)
                    st(pre, r, q0, q1)
                    q0, q1 := f2mul(q0, q1, d0, z1)
                }
                let i0, i1 := f2inv(q0, q1)
                for { let r := n } r { } {
                    r := sub(r, 1)
                    let d0, d1 := ld(den, r)
                    let p0, p1 := ld(pre, r)
                    let v0, v1 := f2mul(i0, i1, p0, p1)
                    i0, i1 := f2mul(i0, i1, d0, d1)
                    st(den, r, v0, v1)
                }
                pq := pp
            }

            function boundaries(ctx, pp, x0, x1) -> r0, r1 {
                let q := 0xFFFFFFFF00000001
                let nOut := cx(ctx, 1)
                for { let j := 0 } lt(j, cx(ctx, 2)) { j := add(j, 1) } {
                    let col := rd(pp, 1)
                    let ri := rd(add(pp, 1), 2)
                    let v := 0
                    switch rd(add(pp, 3), 1)
                    case 0 {
                        v := rd(add(pp, 4), 8)
                        pp := add(pp, 12)
                    }
                    default {
                        let k := rd(add(pp, 4), 1)
                        if iszero(lt(k, cx(ctx, 12))) { revert(0, 0) }
                        v := mload(add(cx(ctx, 11), shl(5, k)))
                        pp := add(pp, 5)
                    }
                    let f0, f1 := ld(cx(ctx, 8), col)
                    let d0, d1 := ld(cx(ctx, 20), ri)
                    let n0, n1 := f2mul(addmod(f0, sub(q, v), q), f1, d0, d1)
                    let a0, a1 := ld(cx(ctx, 10), add(nOut, j))
                    n0, n1 := f2mul(n0, n1, a0, a1)
                    x0 := addmod(x0, n0, q)
                    x1 := addmod(x1, n1, q)
                }
                r0 := x0
                r1 := x1
            }

            let ctx := mload(0x40)
            let pp := add(prog, 32)
            mstore(ctx, rd(pp, 2))
            mstore(add(ctx, 32), rd(add(pp, 2), 2))
            mstore(add(ctx, 64), rd(add(pp, 4), 2))
            mstore(add(ctx, 96), rd(add(pp, 6), 2))
            mstore(add(ctx, 128), rd(add(pp, 8), 2))
            mstore(add(ctx, 160), rd(add(pp, 10), 2))
            mstore(add(ctx, 192), rd(add(pp, 12), 1))
            mstore(add(ctx, 224), rd(add(pp, 13), 1))
            mstore(add(ctx, 256), add(frame, 32))
            mstore(add(ctx, 288), add(periodic, 32))
            mstore(add(ctx, 320), add(alphas, 32))
            mstore(add(ctx, 352), add(publics, 32))
            mstore(add(ctx, 384), mload(publics))
            for { let k := 0 } lt(k, 6) { k := add(k, 1) } {
                mstore(add(ctx, add(416, shl(5, k))), mload(add(point, shl(5, k))))
            }
            let vals := add(ctx, 704)
            mstore(add(ctx, 608), vals)
            let den := add(vals, shl(6, cx(ctx, 0)))
            mstore(add(ctx, 640), den)
            mstore(add(ctx, 672), add(den, shl(6, cx(ctx, 3))))
            mstore(0x40, add(cx(ctx, 21), shl(6, cx(ctx, 3))))
            if iszero(eq(mload(frame), shl(1, cx(ctx, 4)))) { revert(0, 0) }
            if iszero(eq(mload(periodic), shl(1, cx(ctx, 5)))) { revert(0, 0) }
            if iszero(eq(mload(alphas), shl(1, add(cx(ctx, 1), cx(ctx, 2))))) { revert(0, 0) }
            pp := add(pp, 14)

            // E(z): the exempt rows' factor.
            let e0 := 1
            let e1 := 0
            for { let k := 0 } lt(k, cx(ctx, 7)) { k := add(k, 1) } {
                let d0 := addmod(cx(ctx, 17), sub(0xFFFFFFFF00000001, rd(pp, 8)), 0xFFFFFFFF00000001)
                pp := add(pp, 8)
                e0, e1 := f2mul(e0, e1, d0, cx(ctx, 18))
            }
            pp := program(ctx, pp)
            pp, c0, c1 := transitions(ctx, pp, e0, e1)
            pp := rows(ctx, pp)
            c0, c1 := boundaries(ctx, pp, c0, c1)
        }
    }
}
