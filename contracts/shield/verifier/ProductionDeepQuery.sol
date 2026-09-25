// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StarkFieldExt as F} from "./StarkFieldExt.sol";

/// @title ProductionDeepQuery
/// @notice The DEEP combination of one query, for RealQueryVerify.verifyBase. The launch verifier
///         computes DEEP in RealQueryWalk instead.
/// @dev deep(x) = sum_r sum_c k[r*w + c] (row[c] - ood[r*w + c]) / (x - z g^r) + k[2w] (comp - comp_z) / (x - z)
library ProductionDeepQuery {
    /// @notice A periodic limb read from the wire is at or above the Goldilocks modulus.
    error NonCanonicalPeriodicLimb();

    struct Ctx {
        F.Fp2 z;
        F.Fp2 compZ;
        uint256 x; // shift * omega^p, base field
        uint256 g; // outer trace-domain generator, root_of_unity(log_trace_len)
        uint256 width; // outer trace width, from the emitted structure
        uint256 nPeriodic; // periodic sidecar columns, 0 if none
        F.Fp2 preSummedClaims; // S = sum_j k_j Pz_j, computed once at begin
    }

    // invDen * sum_c k (row[c] - ood[c]) for window row r
    function _rowSum(
        uint256[] memory traceRow,
        F.Fp2[] memory ood,
        F.Fp2[] memory coeffs,
        uint256 r,
        F.Fp2 memory invDen,
        uint256 width
    ) private pure returns (F.Fp2 memory acc) {
        uint256 a0;
        uint256 a1;
        assembly {
            let P := 0xFFFFFFFF00000001
            let base := mul(r, width)
            let rowp := add(traceRow, 0x20)
            let oodp := add(add(ood, 0x20), mul(base, 32))
            let cofp := add(add(coeffs, 0x20), mul(base, 32))
            for { let c := 0 } lt(c, width) { c := add(c, 1) } {
                let o := mload(add(oodp, mul(c, 32)))
                let k := mload(add(cofp, mul(c, 32)))
                let d0 := addmod(mload(add(rowp, mul(c, 32))), sub(P, mload(o)), P)
                let d1 := addmod(0, sub(P, mload(add(o, 32))), P)
                let k0 := mload(k)
                let k1 := mload(add(k, 32))
                // (k0 + k1 X)(d0 + d1 X) = (k0 d0 + 7 k1 d1) + (k0 d1 + k1 d0) X
                a0 := addmod(a0, addmod(mulmod(k0, d0, P), mulmod(7, mulmod(k1, d1, P), P), P), P)
                a1 := addmod(a1, addmod(mulmod(k0, d1, P), mulmod(k1, d0, P), P), P)
            }
        }
        acc = F.mul(F.Fp2(a0, a1), invDen);
    }

    // invXz * sum_j k_j (P_j(x) - Pz_j). This binds each claim Pz_j to the committed schedule.
    function _periodicSum(
        uint256[] memory periodicRow,
        F.Fp2[] memory periodicZ,
        F.Fp2[] memory coeffs,
        F.Fp2 memory invXz,
        uint256 width
    ) private pure returns (F.Fp2 memory acc) {
        uint256 a0;
        uint256 a1;
        assembly {
            let P := 0xFFFFFFFF00000001
            let n := mload(periodicZ)
            let rowp := add(periodicRow, 0x20)
            let zp := add(periodicZ, 0x20)
            let cofp := add(add(coeffs, 0x20), mul(add(mul(2, width), 1), 32))
            for { let j := 0 } lt(j, n) { j := add(j, 1) } {
                let zc := mload(add(zp, mul(j, 32)))
                let k := mload(add(cofp, mul(j, 32)))
                let d0 := addmod(mload(add(rowp, mul(j, 32))), sub(P, mload(zc)), P)
                let d1 := addmod(0, sub(P, mload(add(zc, 32))), P)
                let k0 := mload(k)
                let k1 := mload(add(k, 32))
                a0 := addmod(a0, addmod(mulmod(k0, d0, P), mulmod(7, mulmod(k1, d1, P), P), P), P)
                a1 := addmod(a1, addmod(mulmod(k0, d1, P), mulmod(k1, d0, P), P), P)
            }
        }
        acc = F.mul(F.Fp2(a0, a1), invXz);
    }

    /// @notice DEEP combination without periodic columns.
    function combine(
        uint256[] memory traceRow,
        F.Fp2 memory comp,
        F.Fp2[] memory ood,
        F.Fp2[] memory coeffs,
        Ctx memory ctx
    ) internal pure returns (F.Fp2 memory acc) {
        F.Fp2 memory xf = F.fromBase(ctx.x);
        F.Fp2 memory inv0 = F.inv(F.sub(xf, ctx.z)); // row 0 and the comp term
        F.Fp2 memory inv1 = F.inv(F.sub(xf, F.mulBase(ctx.z, ctx.g))); // row 1
        acc = _rowSum(traceRow, ood, coeffs, 0, inv0, ctx.width);
        acc = F.add(acc, _rowSum(traceRow, ood, coeffs, 1, inv1, ctx.width));
        // the composition coefficient follows the 2 * width frame terms
        acc =F.add(acc, F.mul(coeffs[2 * ctx.width], F.mul(F.sub(comp, ctx.compZ), inv0)));
    }

    /// @notice combineWithPeriodic using the pre-summed claim scalar S.
    /// @dev sum_j k_j (row_j - Pz_j) = sum_j k_j row_j - S, and S is the same for every query.
    function combineWithScalar(
        uint256[] memory traceRow,
        F.Fp2 memory comp,
        F.Fp2[] memory ood,
        F.Fp2[] memory coeffs,
        Ctx memory ctx,
        uint256[] memory periodicRow,
        F.Fp2 memory preSummedClaims
    ) internal pure returns (F.Fp2 memory acc) {
        acc = combine(traceRow, comp, ood, coeffs, ctx);
        if (ctx.nPeriodic == 0) return acc;
        F.Fp2 memory invXz = F.inv(F.sub(F.fromBase(ctx.x), ctx.z));
        F.Fp2 memory rowSum = _rowScaledSum(periodicRow, coeffs, ctx.width, ctx.nPeriodic);
        acc = F.add(acc, F.mul(F.sub(rowSum, preSummedClaims), invXz));
    }

    /// @notice sum_j k_j row_j over a periodic row of little-endian 8-byte limbs at src[off].
    /// @dev Reverts on a limb at or above P, which would reduce to a value the leaf does not commit.
    function rowScaledSumRaw(
        bytes memory src,
        uint256 off,
        F.Fp2[] memory coeffs,
        uint256 width,
        uint256 n
    ) internal pure returns (F.Fp2 memory) {
        require(off + n * 8 <= src.length, "periodic row out of bounds");
        uint256 a0;
        uint256 a1;
        bool bad;
        assembly {
            let P := 0xFFFFFFFF00000001
            let sp := add(add(src, 0x20), off)
            let cofp := add(add(coeffs, 0x20), mul(add(mul(2, width), 1), 32))
            for { let j := 0 } lt(j, n) { j := add(j, 1) } {
                let w := shr(192, mload(add(sp, mul(j, 8))))
                w := or(shr(8, and(w, 0xFF00FF00FF00FF00)), shl(8, and(w, 0x00FF00FF00FF00FF)))
                w := or(shr(16, and(w, 0xFFFF0000FFFF0000)), shl(16, and(w, 0x0000FFFF0000FFFF)))
                w := or(shr(32, w), and(shl(32, w), 0xFFFFFFFF00000000))
                if iszero(lt(w, P)) { bad := 1 }
                let k := mload(add(cofp, mul(j, 32)))
                a0 := addmod(a0, mulmod(mload(k), w, P), P)
                a1 := addmod(a1, mulmod(mload(add(k, 32)), w, P), P)
            }
        }
        if (bad) revert NonCanonicalPeriodicLimb();
        return F.Fp2(a0, a1);
    }

    /// @notice combineWithScalar with the periodic row read from the wire.
    function combineWithScalarRaw(
        uint256[] memory traceRow,
        F.Fp2 memory comp,
        F.Fp2[] memory ood,
        F.Fp2[] memory coeffs,
        Ctx memory ctx,
        bytes memory src,
        uint256 off,
        F.Fp2 memory preSummedClaims
    ) internal pure returns (F.Fp2 memory acc) {
        F.Fp2[2] memory inv = _inv2(ctx);
        acc = _rowSum(traceRow, ood, coeffs, 0, inv[0], ctx.width);
        acc = F.add(acc, _rowSum(traceRow, ood, coeffs, 1, inv[1], ctx.width));
        acc = F.add(acc, F.mul(coeffs[2 * ctx.width], F.mul(F.sub(comp, ctx.compZ), inv[0])));
        if (ctx.nPeriodic == 0) return acc;
        F.Fp2 memory rowSum = rowScaledSumRaw(src, off, coeffs, ctx.width, ctx.nPeriodic);
        acc = F.add(acc, F.mul(F.sub(rowSum, preSummedClaims), inv[0]));
    }

    /// @dev 1/(x - z) and 1/(x - z g) for one inversion. A zero denominator, which a random z
    ///      reaches with negligible probability, takes two F.inv calls so it maps to zero as
    ///      `combine` maps it.
    function _inv2(Ctx memory ctx) private pure returns (F.Fp2[2] memory r) {
        F.Fp2 memory xf = F.fromBase(ctx.x);
        F.Fp2 memory d0 = F.sub(xf, ctx.z);
        F.Fp2 memory d1 = F.sub(xf, F.mulBase(ctx.z, ctx.g));
        if (F.isZero(d0) || F.isZero(d1)) {
            r[0] = F.inv(d0);
            r[1] = F.inv(d1);
            return r;
        }
        F.Fp2 memory pinv = F.inv(F.mul(d0, d1));
        r[0] = F.mul(pinv, d1);
        r[1] = F.mul(pinv, d0);
    }

    /// @notice S = sum_j k_j Pz_j, with the periodic coefficients starting at 2 * width + 1.
    function claimScalar(F.Fp2[] memory coeffs, F.Fp2[] memory periodicZ, uint256 width)
        internal
        pure
        returns (F.Fp2 memory s)
    {
        uint256 base = 2 * width + 1;
        uint256 a0;
        uint256 a1;
        uint256 n = periodicZ.length;
        for (uint256 j = 0; j < n; ++j) {
            F.Fp2 memory k = coeffs[base + j];
            F.Fp2 memory z = periodicZ[j];
            assembly {
                let P := 0xFFFFFFFF00000001
                let k0 := mload(k)
                let k1 := mload(add(k, 32))
                let z0 := mload(z)
                let z1 := mload(add(z, 32))
                a0 := addmod(a0, addmod(mulmod(k0, z0, P), mulmod(7, mulmod(k1, z1, P), P), P), P)
                a1 := addmod(a1, addmod(mulmod(k0, z1, P), mulmod(k1, z0, P), P), P)
            }
        }
        s = F.Fp2(a0, a1);
    }

    function _rowScaledSum(uint256[] memory periodicRow, F.Fp2[] memory coeffs, uint256 width, uint256 n)
        private
        pure
        returns (F.Fp2 memory)
    {
        uint256 a0;
        uint256 a1;
        assembly {
            let P := 0xFFFFFFFF00000001
            let rowp := add(periodicRow, 0x20)
            let cofp := add(add(coeffs, 0x20), mul(add(mul(2, width), 1), 32))
            for { let j := 0 } lt(j, n) { j := add(j, 1) } {
                let r := mload(add(rowp, mul(j, 32)))
                let k := mload(add(cofp, mul(j, 32)))
                a0 := addmod(a0, mulmod(mload(k), r, P), P)
                a1 := addmod(a1, mulmod(mload(add(k, 32)), r, P), P)
            }
        }
        return F.Fp2(a0, a1);
    }

    /// @notice DEEP combination with the periodic sidecar folded in term by term.
    function combineWithPeriodic(
        uint256[] memory traceRow,
        F.Fp2 memory comp,
        F.Fp2[] memory ood,
        F.Fp2[] memory coeffs,
        Ctx memory ctx,
        uint256[] memory periodicRow,
        F.Fp2[] memory periodicZ
    ) internal pure returns (F.Fp2 memory acc) {
        acc = combine(traceRow, comp, ood, coeffs, ctx);
        if (ctx.nPeriodic == 0) return acc;
        F.Fp2 memory invXz = F.inv(F.sub(F.fromBase(ctx.x), ctx.z));
        acc = F.add(acc, _periodicSum(periodicRow, periodicZ, coeffs, invXz, ctx.width));
    }
}

/// @notice Test harness that meters one DEEP combination.
contract DeepQueryHarness {
    /// @notice Run ProductionDeepQuery.combine and return its gas.
    function combineMetered(
        uint256[] memory traceRow,
        F.Fp2 memory comp,
        F.Fp2[] memory ood,
        F.Fp2[] memory coeffs,
        ProductionDeepQuery.Ctx memory ctx
    ) external view returns (F.Fp2 memory acc, uint256 gasUsed) {
        uint256 g0 = gasleft();
        acc = ProductionDeepQuery.combine(traceRow, comp, ood, coeffs, ctx);
        gasUsed = g0 - gasleft();
    }
}
