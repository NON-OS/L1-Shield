// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StarkFieldExt as F} from "./StarkFieldExt.sol";

/// @notice Compose region transition of the width-86 recursion AIR. No launch accept path calls it.
library ProductionComposeAir {
    uint256 private constant W = 7;
    // Fixed challenges the prover knows in advance, so this grand product does not bind wiring.
    uint256 private constant BETA = 5;
    uint256 private constant GAMMA = 7;

    struct Cell {
        F.Fp2 a;
        F.Fp2 b;
    }

    function _rd(F.Fp2[] memory ood, uint256 slot) private pure returns (Cell memory) {
        return Cell(ood[2 * slot], ood[2 * slot + 1]);
    }

    function _cmul(Cell memory x, Cell memory y) private pure returns (Cell memory) {
        return Cell(F.add(F.mul(x.a, y.a), F.mulBase(F.mul(x.b, y.b), W)), F.add(F.mul(x.a, y.b), F.mul(x.b, y.a)));
    }

    function _cadd(Cell memory x, Cell memory y) private pure returns (Cell memory) {
        return Cell(F.add(x.a, y.a), F.add(x.b, y.b));
    }

    function _csub(Cell memory x, Cell memory y) private pure returns (Cell memory) {
        return Cell(F.sub(x.a, y.a), F.sub(x.b, y.b));
    }

    function _cbase(uint256 v) private pure returns (Cell memory) {
        return Cell(F.fromBase(v), F.zero());
    }

    /// @param g Inner trace generator for t = 64.
    /// @return out 38 unweighted residuals.
    function transition(F.Fp2[] memory ood, uint256 g) internal pure returns (F.Fp2[] memory out) {
        Cell[19] memory res;
        _tower(res, ood);
        _fused(res, ood);
        _boundariesAndCompZ(res, ood, g);

        out = new F.Fp2[](38);
        for (uint256 i = 0; i < 19; ++i) {
            out[2 * i] = res[i].a;
            out[2 * i + 1] = res[i].b;
        }
    }

    // zpow[k] = z^(2^(k+1)), and z_h_inv * (z^t - 1) = 1
    function _tower(Cell[19] memory res, F.Fp2[] memory ood) private pure {
        Cell memory z = _rd(ood, 11);
        Cell memory prev = z;
        for (uint256 k = 0; k < 6; ++k) {
            Cell memory zp = _rd(ood, 33 + k);
            res[k] = _csub(zp, _cmul(prev, prev));
            prev = zp;
        }
        Cell memory zHinv = _rd(ood, 20);
        res[6] = _csub(_cmul(zHinv, _csub(_rd(ood, 38), _cbase(1))), _cbase(1));
    }

    function _fused(Cell[19] memory res, F.Fp2[] memory ood) private pure {
        // out0 = sel0*(w3 - w0 - w1) + sel1*(w0 - 2 w3 - w1)
        Cell memory accT = _csub(_rd(ood, 3), _cadd(_rd(ood, 0), _rd(ood, 1)));
        Cell memory rngT = _csub(_csub(_rd(ood, 0), _cmul(_cbase(2), _rd(ood, 3))), _rd(ood, 1));
        res[8] = _csub(_rd(ood, 22), _cadd(_cmul(_rd(ood, 6), accT), _cmul(_rd(ood, 7), rngT)));
        res[9] = _csub(_rd(ood, 23), _cmul(_rd(ood, 7), _cmul(_rd(ood, 1), _csub(_rd(ood, 1), _cbase(1)))));
        // num = w0 + beta*id + gamma, den = w0 + beta*sigma + gamma
        res[10] = _csub(_rd(ood, 25), _cadd(_cadd(_rd(ood, 0), _cmul(_cbase(BETA), _rd(ood, 8))), _cbase(GAMMA)));
        res[11] = _csub(_rd(ood, 26), _cadd(_cadd(_rd(ood, 0), _cmul(_cbase(BETA), _rd(ood, 9))), _cbase(GAMMA)));
        _out2(res, ood);
    }

    // out2 = gp_sel * (w5*den - w2*num) + (1 - gp_sel) * (w5 - w2)
    function _out2(Cell[19] memory res, F.Fp2[] memory ood) private pure {
        Cell memory w2 = _rd(ood, 2);
        Cell memory w5 = _rd(ood, 5);
        Cell memory gpSel = _rd(ood, 10);
        Cell memory prod = _csub(_cmul(w5, _rd(ood, 26)), _cmul(w2, _rd(ood, 25)));
        Cell memory gp = _cadd(_cmul(gpSel, prod), _cmul(_csub(_cbase(1), gpSel), _csub(w5, w2)));
        res[12] = _csub(_rd(ood, 24), gp);
    }

    function _boundariesAndCompZ(Cell[19] memory res, F.Fp2[] memory ood, uint256 g) private pure {
        Cell memory z = _rd(ood, 11);
        Cell memory zHinv = _rd(ood, 20);
        // E = (z - g^(t-1)) * z_h_inv, t = 64
        Cell memory eCell = _rd(ood, 21);
        res[7] = _csub(eCell, _cmul(_csub(z, _cbase(F.fpPow(g, 63))), zHinv));

        // q * (z - g^row) = window[col] - expected
        uint256[5] memory cols = [uint256(0), 0, 0, 2, 2];
        uint256[5] memory rows = [uint256(0), 7, 23, 0, 32];
        uint256[5] memory exps = [uint256(0), 0, 0, 1, 1];
        for (uint256 j = 0; j < 5; ++j) {
            Cell memory q = _rd(ood, 28 + j);
            Cell memory denom = _csub(z, _cbase(F.fpPow(g, rows[j])));
            Cell memory numer = _csub(_rd(ood, cols[j]), _cbase(exps[j]));
            res[13 + j] = _csub(_cmul(q, denom), numer);
        }

        // comp_z = (c0*out0 + c1*out1 + c2*out2) * E + sum_j coeff[3 + j] * quotient[j]
        Cell memory acc = _cmul(_cmul(_rd(ood, 12), _rd(ood, 22)), eCell);
        acc = _cadd(acc, _cmul(_cmul(_rd(ood, 13), _rd(ood, 23)), eCell));
        acc = _cadd(acc, _cmul(_cmul(_rd(ood, 14), _rd(ood, 24)), eCell));
        for (uint256 j = 0; j < 5; ++j) {
            acc = _cadd(acc, _cmul(_rd(ood, 15 + j), _rd(ood, 28 + j)));
        }
        res[18] = _csub(_rd(ood, 27), acc);
    }
}
