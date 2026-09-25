// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StarkFieldExt as F} from "./StarkFieldExt.sol";
import {ProductionComposeAir} from "./ProductionComposeAir.sol";

/// @notice Permutation challenges. They must be drawn after the region columns are committed.
struct Challenges {
    F.Fp2 beta;
    F.Fp2 gamma;
}

/// @title ProductionAir
/// @notice The recursion AIR transition at z, with the DEEP and FRI checks that consume it.
/// @dev The launch verifier reads only COSET_SHIFT and xFinal from here, through RealQueryWalk.
///      No launch accept path calls the AIR functions. See docs/07-constraints.md.
library ProductionAir {
    uint256 private constant W = 7; // Fp2 = Fp[X]/(X^2 - 7)
    uint256 internal constant WIDTH = 78; // stack.width (widest region = compose)
    uint256 internal constant STRIDE = 129; // trace_width = stack.width 78 + 51 gp columns
    uint256 internal constant INV2 = 9223372034707292161; // (P+1)/2
    /// @dev Must equal Shape.cosetShift. RealSplitVerifier refuses to construct if they differ.
    uint256 internal constant COSET_SHIFT = 7;
    uint256 internal constant TRACE_WIDTH = 129; // opened wide-leaf row width
    uint256 private constant OOD_WINDOW = 2;

    /// @notice The fixed (beta, gamma) = (5, 7) of the recursion AIR.
    /// @dev Constants the prover knows, so this grand product is not a sound permutation argument.
    ///      The launch circuit draws beta and gamma from the transcript instead.
    function provisionalChallenges() internal pure returns (Challenges memory) {
        return Challenges({beta: F.fromBase(5), gamma: F.fromBase(7)});
    }

    struct DeepCtx {
        F.Fp2[] ood;
        F.Fp2[] deepCoeffs;
        F.Fp2 z;
        F.Fp2 compZ;
        uint256 x;
        uint256 g;
    }

    /// @notice The 46 transition values at z, in oracle order.
    /// @param openedCol (i0 & 1) == 1 ? RATE : 0, derived per query and never pinned.
    function transitionZ(
        F.Fp2[] memory ood,
        F.Fp2[] memory pz,
        uint256[] memory mds,
        uint256 g,
        uint256 openedCol,
        Challenges memory chal
    ) internal pure returns (F.Fp2[] memory out) {
        out = new F.Fp2[](46);
        for (uint256 i = 0; i < 46; ++i) {
            out[i] = F.zero();
        }
        _addTranscript(out, ood, pz, pz[0], 6, mds);
        _addCompose(out, ood, pz[1], g);
        _addDeep(out, ood, pz, pz[2], 15);
        _addTranscript(out, ood, pz, pz[3], 27, mds);
        _addFold(out, ood, pz, pz[4], 36);
        _addMerkle(out, ood, pz, pz[5], 39, mds);
        _addGrandProducts(out, ood, pz, openedCol, chal);
    }

    /// @notice The outer composition value comp_z.
    /// @dev sum coeff * tz * (z - g^(t-1)) / (z^t - 1) + sum coeff * (ood[col] - expected) / (z - g^row)
    /// @param boundaries (col, row, expected) triples.
    function composeZ(
        F.Fp2[] memory ood,
        F.Fp2[] memory tz,
        F.Fp2[] memory coeffs,
        uint256[3][] memory boundaries,
        F.Fp2 memory z,
        uint256 g,
        uint256 t
    ) internal pure returns (F.Fp2 memory acc) {
        F.Fp2 memory ez = F.mul(F.sub(z, F.fromBase(F.fpPow(g, t - 1))), F.inv(F.sub(F.pow(z, t), F.one())));
        acc = F.zero();
        uint256 nt = tz.length;
        for (uint256 c = 0; c < nt; ++c) {
            acc = F.add(acc, F.mul(coeffs[c], F.mul(tz[c], ez)));
        }
        F.Fp2[] memory dinv = _boundaryInverses(g, z, boundaries);
        for (uint256 j = 0; j < boundaries.length; ++j) {
            F.Fp2 memory numer = F.sub(ood[boundaries[j][0]], F.fromBase(boundaries[j][2]));
            acc = F.add(acc, F.mul(coeffs[nt + j], F.mul(numer, dinv[j])));
        }
    }

    // 1 / (z - g^row) for every boundary, by Montgomery batch inversion
    function _boundaryInverses(uint256 g, F.Fp2 memory z, uint256[3][] memory boundaries)
        private
        pure
        returns (F.Fp2[] memory dinv)
    {
        uint256 n = boundaries.length;
        dinv = new F.Fp2[](n);
        F.Fp2[] memory d = new F.Fp2[](n);
        F.Fp2 memory run = F.one();
        for (uint256 j = 0; j < n; ++j) {
            d[j] = F.sub(z, F.fromBase(F.fpPow(g, boundaries[j][1])));
            dinv[j] = run;
            run = F.mul(run, d[j]);
        }
        F.Fp2 memory inv = F.inv(run);
        for (uint256 k = n; k > 0; --k) {
            uint256 j = k - 1;
            dinv[j] = F.mul(dinv[j], inv); // p_{j-1} / p_j = 1/d[j]
            inv = F.mul(inv, d[j]);
        }
    }

    /// @notice The DEEP value at query point x, to compare with the opened one.
    /// @dev sum_k,c coeff * (trace[c] - ood[k][c]) / (x - z * g^k) + coeff * (comp - comp_z) / (x - z)
    function deepAtQuery(uint256[] memory traceRow, F.Fp2 memory comp, DeepCtx memory ctx)
        internal
        pure
        returns (F.Fp2 memory acc)
    {
        acc = F.zero();
        for (uint256 k = 0; k < OOD_WINDOW; ++k) {
            acc = _deepRow(acc, traceRow, ctx, k);
        }
        F.Fp2 memory compTerm = F.mul(
            ctx.deepCoeffs[TRACE_WIDTH * OOD_WINDOW],
            F.mul(F.sub(comp, ctx.compZ), F.inv(F.sub(F.fromBase(ctx.x), ctx.z)))
        );
        acc = F.add(acc, compTerm);
    }

    /// @notice deepAtQuery plus sum_j pc_j * (P_j(x) - Pz_j) / (x - z) for the periodic columns.
    /// @dev The caller must authenticate `periodicRow` against periodic_root first.
    function deepAtQueryPre(
        uint256[] memory traceRow,
        F.Fp2 memory comp,
        DeepCtx memory ctx,
        uint256[] memory periodicRow,
        F.Fp2[] memory periodicZ
    ) internal pure returns (F.Fp2 memory acc) {
        acc = deepAtQuery(traceRow, comp, ctx);
        F.Fp2 memory invXz = F.inv(F.sub(F.fromBase(ctx.x), ctx.z));
        uint256 base = TRACE_WIDTH * OOD_WINDOW + 1; // 259: pc coeffs start here
        for (uint256 j = 0; j < periodicZ.length; ++j) {
            F.Fp2 memory diff = F.sub(F.fromBase(periodicRow[j]), periodicZ[j]);
            acc = F.add(acc, F.mul(ctx.deepCoeffs[base + j], F.mul(diff, invXz)));
        }
    }

    function _deepRow(F.Fp2 memory acc, uint256[] memory traceRow, DeepCtx memory ctx, uint256 k)
        private
        pure
        returns (F.Fp2 memory)
    {
        F.Fp2 memory invXzk = F.inv(F.sub(F.fromBase(ctx.x), F.mul(ctx.z, F.fromBase(F.fpPow(ctx.g, k)))));
        for (uint256 c = 0; c < TRACE_WIDTH; ++c) {
            F.Fp2 memory claimed = ctx.ood[k * TRACE_WIDTH + c];
            F.Fp2 memory term =
                F.mul(ctx.deepCoeffs[k * TRACE_WIDTH + c], F.mul(F.sub(F.fromBase(traceRow[c]), claimed), invXzk));
            acc = F.add(acc, term);
        }
        return acc;
    }

    /// @notice Horner evaluation of final-layer coefficients, lowest degree first, at base-field x.
    /// @dev The coefficient count is the degree bound. There is no separate degree check.
    function evalFinal(F.Fp2[] memory coeffs, uint256 x) internal pure returns (F.Fp2 memory acc) {
        // x is in the base field, so c0 and c1 run as separate chains with no per-step allocation.
        uint256 a0;
        uint256 a1;
        assembly {
            let P := 0xFFFFFFFF00000001
            let n := mload(coeffs)
            let slot := add(coeffs, mul(n, 0x20))
            let top := mload(slot)
            a0 := mload(top)
            a1 := mload(add(top, 0x20))
            for { let end := add(coeffs, 0x20) } gt(slot, end) {} {
                slot := sub(slot, 0x20)
                let c := mload(slot)
                a0 := addmod(mulmod(a0, x, P), mload(c), P)
                a1 := addmod(mulmod(a1, x, P), mload(add(c, 0x20)), P)
            }
        }
        acc = F.Fp2(a0, a1);
    }

    /// @notice Checks one FRI query's fold chain down to the final layer.
    /// @dev `asCoefficients` must be a deployment parameter. If the prover picked the final-layer
    ///      form it could claim whichever one its layer satisfies.
    /// @param asCoefficients True if `finalLayer` is coefficients, false if it is equal cells.
    function friFold(
        F.Fp2[] memory a,
        F.Fp2[] memory b,
        F.Fp2[] memory betas,
        uint256 q,
        F.Fp2[] memory finalLayer,
        uint256 baseOmega,
        uint256 nFolds,
        uint256 n,
        bool asCoefficients
    ) internal pure returns (bool) {
        uint256 inv2 = INV2;
        // x_{m+1} = (-1)^bit * x_m^2, so only layer 0 needs an exponentiation and an inversion
        uint256 invx = F.fpInv(F.fpMul(COSET_SHIFT, F.fpPow(baseOmega, q % (n >> 1))));
        for (uint256 m = 0; m < nFolds; ++m) {
            uint256 i = q % (n >> (m + 1));
            F.Fp2 memory expect;
            if (m + 1 < nFolds) {
                expect = i < (n >> (m + 2)) ? a[m + 1] : b[m + 1];
            } else if (asCoefficients) {
                // Squaring the running 1/x again gives +-x_final, so recompute it from q.
                expect = evalFinal(finalLayer, xFinal(baseOmega, q, n, nFolds));
            } else {
                // the decoder enforces that every cell is equal
                expect = finalLayer[0];
            }
            if (!_foldLayerEq(a[m], b[m], betas[m], inv2, invx, expect)) return false;
            invx = F.fpMul(invx, invx);
            if (i >= (n >> (m + 2))) invx = F.fpNeg(invx);
        }
        return true;
    }

    /// @notice x_final = (shift * omega^(q mod (n >> nFolds)))^(2^nFolds).
    function xFinal(uint256 baseOmega, uint256 q, uint256 n, uint256 nFolds)
        internal
        pure
        returns (uint256)
    {
        return F.fpPow(F.fpMul(COSET_SHIFT, F.fpPow(baseOmega, q % (n >> nFolds))), 1 << nFolds);
    }

    /// @notice One radix-4 fold, done as two radix-2 folds under beta then beta^2.
    /// @dev v0..v3 sit at p, p + N/4, p + N/2, p + 3N/4. Any other order fails every query.
    /// @param invxShift 1/(x*g) for the v1/v3 pair.
    function friFoldQuad(
        F.Fp2 memory v0,
        F.Fp2 memory v1,
        F.Fp2 memory v2,
        F.Fp2 memory v3,
        F.Fp2 memory beta,
        uint256 invx,
        uint256 invxShift
    ) internal pure returns (F.Fp2 memory) {
        F.Fp2 memory u0 = _fold2(v0, v2, beta, invx);
        F.Fp2 memory u1 = _fold2(v1, v3, beta, invxShift);
        return _fold2(u0, u1, F.mul(beta, beta), F.fpMul(invx, invx));
    }

    // (a+b)/2 + beta*(a-b)/(2x)
    function _fold2(F.Fp2 memory a, F.Fp2 memory b, F.Fp2 memory beta, uint256 invx)
        private
        pure
        returns (F.Fp2 memory)
    {
        F.Fp2 memory even = F.mulBase(F.add(a, b), INV2);
        F.Fp2 memory odd = F.mulBase(F.mulBase(F.sub(a, b), INV2), invx);
        return F.add(even, F.mul(beta, odd));
    }

    // (a+b)/2 + beta*(a-b)/(2x) == expect, without allocating
    function _foldLayerEq(
        F.Fp2 memory a,
        F.Fp2 memory b,
        F.Fp2 memory beta,
        uint256 inv2,
        uint256 invx,
        F.Fp2 memory expect
    ) private pure returns (bool ok) {
        assembly {
            let P := 0xFFFFFFFF00000001
            let a0 := mload(a)
            let a1 := mload(add(a, 32))
            let b0 := mload(b)
            let b1 := mload(add(b, 32))
            let e0 := mulmod(addmod(a0, b0, P), inv2, P)
            let e1 := mulmod(addmod(a1, b1, P), inv2, P)
            let s := mulmod(inv2, invx, P)
            let o0 := mulmod(addmod(a0, sub(P, b0), P), s, P)
            let o1 := mulmod(addmod(a1, sub(P, b1), P), s, P)
            let k0 := mload(beta)
            let k1 := mload(add(beta, 32))
            let v0 := addmod(e0, addmod(mulmod(k0, o0, P), mulmod(7, mulmod(k1, o1, P), P), P), P)
            let v1 := addmod(e1, addmod(mulmod(k0, o1, P), mulmod(k1, o0, P), P), P)
            ok := and(eq(v0, mload(expect)), eq(v1, mload(add(expect, 32))))
        }
    }

    function _round(F.Fp2[8] memory state, F.Fp2[] memory pz, uint256 rcBase, uint256[] memory mds)
        private
        pure
        returns (F.Fp2[8] memory outp)
    {
        F.Fp2[8] memory sb;
        for (uint256 k = 0; k < 8; ++k) {
            sb[k] = F.pow(state[k], 7);
        }
        for (uint256 j = 0; j < 8; ++j) {
            F.Fp2 memory acc = pz[rcBase + j];
            uint256 base = j * 8;
            for (uint256 k = 0; k < 8; ++k) {
                acc = F.add(acc, F.mulBase(sb[k], mds[base + k]));
            }
            outp[j] = acc;
        }
    }

    // next = round(state with pz[rcBase+8] added to word 0)
    function _addTranscript(
        F.Fp2[] memory out,
        F.Fp2[] memory ood,
        F.Fp2[] memory pz,
        F.Fp2 memory sel,
        uint256 rcBase,
        uint256[] memory mds
    ) private pure {
        F.Fp2[8] memory state;
        for (uint256 j = 0; j < 8; ++j) {
            state[j] = ood[j];
        }
        state[0] = F.add(state[0], pz[rcBase + 8]);
        F.Fp2[8] memory pr = _round(state, pz, rcBase, mds);
        for (uint256 j = 0; j < 8; ++j) {
            F.Fp2 memory cons = F.sub(ood[STRIDE + j], pr[j]);
            out[j] = F.add(out[j], F.mul(sel, cons));
        }
    }

    function _addCompose(F.Fp2[] memory out, F.Fp2[] memory ood, F.Fp2 memory sel, uint256 g) private pure {
        F.Fp2[] memory c = ProductionComposeAir.transition(ood, g);
        for (uint256 i = 0; i < 38; ++i) {
            out[i] = F.add(out[i], F.mul(sel, c[i]));
        }
    }

    function _addDeep(F.Fp2[] memory out, F.Fp2[] memory ood, F.Fp2[] memory pz, F.Fp2 memory sel, uint256 b)
        private
        pure
    {
        _deepQ0(out, ood, pz, sel, b);
        _deepQ1(out, ood, pz, sel, b);
        _deepAcc(out, ood, pz, sel, b);
        // comp_sel * (ood[4,5] - pz[b+2,b+3])
        out[4] = F.add(out[4], F.mul(sel, F.mul(pz[b + 11], F.sub(ood[4], pz[b + 2]))));
        out[5] = F.add(out[5], F.mul(sel, F.mul(pz[b + 11], F.sub(ood[5], pz[b + 3]))));
    }

    // sel_row * sel_deep * (q0 d0 + W q1 d1 - (val0 - claim0))
    function _deepQ0(F.Fp2[] memory out, F.Fp2[] memory ood, F.Fp2[] memory pz, F.Fp2 memory sel, uint256 b)
        private
        pure
    {
        F.Fp2 memory d0 = F.sub(pz[b + 8], pz[b + 4]);
        F.Fp2 memory d1 = F.sub(pz[b + 9], pz[b + 5]);
        F.Fp2 memory qd0 = F.add(F.mul(ood[0], d0), F.mulBase(F.mul(ood[1], d1), W));
        F.Fp2 memory n0 = F.sub(pz[b], pz[b + 2]);
        out[0] = F.add(out[0], F.mul(sel, F.mul(pz[b + 10], F.sub(qd0, n0))));
    }

    // sel_row * sel_deep * (q0 d1 + q1 d0 - (val1 - claim1))
    function _deepQ1(F.Fp2[] memory out, F.Fp2[] memory ood, F.Fp2[] memory pz, F.Fp2 memory sel, uint256 b)
        private
        pure
    {
        F.Fp2 memory d0 = F.sub(pz[b + 8], pz[b + 4]);
        F.Fp2 memory d1 = F.sub(pz[b + 9], pz[b + 5]);
        F.Fp2 memory qd1 = F.add(F.mul(ood[0], d1), F.mul(ood[1], d0));
        F.Fp2 memory n1 = F.sub(pz[b + 1], pz[b + 3]);
        out[1] = F.add(out[1], F.mul(sel, F.mul(pz[b + 10], F.sub(qd1, n1))));
    }

    // sel_row * (nacc - acc - sel_deep * coeff * q)
    function _deepAcc(F.Fp2[] memory out, F.Fp2[] memory ood, F.Fp2[] memory pz, F.Fp2 memory sel, uint256 b)
        private
        pure
    {
        F.Fp2 memory cq0 = F.add(F.mul(pz[b + 6], ood[0]), F.mulBase(F.mul(pz[b + 7], ood[1]), W));
        F.Fp2 memory cq1 = F.add(F.mul(pz[b + 6], ood[1]), F.mul(pz[b + 7], ood[0]));
        F.Fp2 memory sl = pz[b + 10];
        out[2] = F.add(out[2], F.mul(sel, F.sub(F.sub(ood[STRIDE + 2], ood[2]), F.mul(sl, cq0))));
        out[3] = F.add(out[3], F.mul(sel, F.sub(F.sub(ood[STRIDE + 3], ood[3]), F.mul(sl, cq1))));
    }

    function _addFold(F.Fp2[] memory out, F.Fp2[] memory ood, F.Fp2[] memory pz, F.Fp2 memory sel, uint256 b)
        private
        pure
    {
        _foldOut(out, ood, pz, sel, b, 0);
        _foldOut(out, ood, pz, sel, b, 1);
    }

    // beta = ood[0,1], a = ood[2,3], b = ood[4,5], next is a when dir = 0 and b when dir = 1
    function _foldOut(
        F.Fp2[] memory out,
        F.Fp2[] memory ood,
        F.Fp2[] memory pz,
        F.Fp2 memory sel,
        uint256 b,
        uint256 comp
    ) private pure {
        F.Fp2 memory xInv = pz[b + 1];
        F.Fp2 memory odd0 = F.mul(F.mulBase(F.sub(ood[2], ood[4]), INV2), xInv);
        F.Fp2 memory odd1 = F.mul(F.mulBase(F.sub(ood[3], ood[5]), INV2), xInv);
        F.Fp2 memory even = F.mulBase(F.add(ood[2 + comp], ood[4 + comp]), INV2);
        F.Fp2 memory bo = comp == 0
            ? F.add(F.mul(ood[0], odd0), F.mulBase(F.mul(ood[1], odd1), W))
            : F.add(F.mul(ood[0], odd1), F.mul(ood[1], odd0));
        F.Fp2 memory dir = pz[b + 2];
        F.Fp2 memory expected =
            F.add(F.mul(F.sub(F.one(), dir), ood[STRIDE + 2 + comp]), F.mul(dir, ood[STRIDE + 4 + comp]));
        out[comp] = F.add(out[comp], F.mul(sel, F.mul(pz[b], F.sub(F.add(even, bo), expected))));
    }

    // periodic from b: rc[8], slot_bnd, op_bnd, dir, sib[4], reset[8]
    function _addMerkle(
        F.Fp2[] memory out,
        F.Fp2[] memory ood,
        F.Fp2[] memory pz,
        F.Fp2 memory sel,
        uint256 b,
        uint256[] memory mds
    ) private pure {
        F.Fp2[8] memory state;
        for (uint256 j = 0; j < 8; ++j) {
            state[j] = ood[j];
        }
        F.Fp2[8] memory pr = _round(state, pz, b, mds);
        for (uint256 j = 0; j < 8; ++j) {
            _merkleRow(out, ood, pr, pz, sel, b, j);
        }
    }

    // expected = op_bnd * reset + slot_bnd * inject + (1 - op_bnd - slot_bnd) * pr
    function _merkleRow(
        F.Fp2[] memory out,
        F.Fp2[] memory ood,
        F.Fp2[8] memory pr,
        F.Fp2[] memory pz,
        F.Fp2 memory sel,
        uint256 b,
        uint256 j
    ) private pure {
        F.Fp2 memory dir = pz[b + 10];
        F.Fp2 memory omd = F.sub(F.one(), dir);
        F.Fp2 memory inj = j < 4
            ? F.add(F.mul(omd, pr[j]), F.mul(dir, pz[b + 11 + j]))
            : F.add(F.mul(omd, pz[b + 11 + (j - 4)]), F.mul(dir, pr[j - 4]));
        F.Fp2 memory noBnd = F.sub(F.sub(F.one(), pz[b + 9]), pz[b + 8]);
        F.Fp2 memory expected =
            F.add(F.add(F.mul(pz[b + 9], pz[b + 15 + j]), F.mul(pz[b + 8], inj)), F.mul(noBnd, pr[j]));
        out[j] = F.add(out[j], F.mul(sel, F.sub(ood[STRIDE + j], expected)));
    }

    // out[38..46]. Slots and wired columns follow the prover.
    function _addGrandProducts(
        F.Fp2[] memory out,
        F.Fp2[] memory ood,
        F.Fp2[] memory pz,
        uint256 openedCol,
        Challenges memory chal
    )
        private
        pure
    {
        out[38] = _gp(ood, pz, _c3(0, 22, 23), 62, 0, chal);
        out[39] = _gp(ood, pz, _c5(0, 24, 25, 26, 27), 69, 1, chal);
        out[40] = _gp(ood, pz, _c5(0, 28, 29, 30, 31), 80, 2, chal);
        out[41] = _gp(ood, pz, _c5(0, 32, 33, 34, 35), 91, 3, chal);
        out[42] = _gp(ood, pz, _c5(0, 36, 37, 38, 39), 102, 4, chal);
        out[43] = _gp(ood, pz, _c4(54, 55, 4, 5), 113, 5, chal);
        out[44] = _gp(ood, pz, _c2(0, 1), 122, 6, chal);
        // g7 binds fold cols [2,3] to the opened Merkle cell
        out[45] = _gp(ood, pz, _c4(2, 3, openedCol, openedCol + 1), 127, 7, chal);
    }

    // value + beta * slot + gamma
    function _term(F.Fp2 memory v, F.Fp2 memory slotVal, Challenges memory chal)
        private
        pure
        returns (F.Fp2 memory)
    {
        return F.add(F.add(v, F.mul(slotVal, chal.beta)), chal.gamma);
    }

    function _gp(
        F.Fp2[] memory ood,
        F.Fp2[] memory pz,
        uint256[] memory cols,
        uint256 slot,
        uint256 gIdx,
        Challenges memory chal
    ) private pure returns (F.Fp2 memory) {
        F.Fp2 memory num = F.one();
        F.Fp2 memory den = F.one();
        uint256 k = cols.length;
        for (uint256 j = 0; j < k; ++j) {
            num = F.mul(num, _term(ood[cols[j]], pz[slot + 2 * j], chal));
            den = F.mul(den, _term(ood[cols[j]], pz[slot + 2 * j + 1], chal));
        }
        F.Fp2 memory gpSel = pz[slot + 2 * k];
        {
            // scoped to stay under the stack limit
            F.Fp2 memory z = ood[WIDTH + gIdx];
            F.Fp2 memory zNext = ood[STRIDE + WIDTH + gIdx];
            num = F.sub(F.mul(zNext, den), F.mul(z, num)); // num becomes prod
            den = F.sub(zNext, z); // den becomes carry
        }
        return F.add(F.mul(gpSel, num), F.mul(F.sub(F.one(), gpSel), den));
    }

    function _c2(uint256 a, uint256 b) private pure returns (uint256[] memory c) {
        c = new uint256[](2);
        c[0] = a;
        c[1] = b;
    }

    function _c3(uint256 a, uint256 b, uint256 cc) private pure returns (uint256[] memory c) {
        c = new uint256[](3);
        c[0] = a;
        c[1] = b;
        c[2] = cc;
    }

    function _c4(uint256 a, uint256 b, uint256 cc, uint256 d) private pure returns (uint256[] memory c) {
        c = new uint256[](4);
        c[0] = a;
        c[1] = b;
        c[2] = cc;
        c[3] = d;
    }

    function _c5(uint256 a, uint256 b, uint256 cc, uint256 d, uint256 e) private pure returns (uint256[] memory c) {
        c = new uint256[](5);
        c[0] = a;
        c[1] = b;
        c[2] = cc;
        c[3] = d;
        c[4] = e;
    }
}
