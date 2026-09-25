// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";
import {ProductionDeepQuery as DQ, DeepQueryHarness} from "../../contracts/shield/verifier/ProductionDeepQuery.sol";

/// The claims add one scalar S to every query, so a session pre-sums them at begin and each chunk
/// carries only its own row. The scalar form is held to the per-claim fold at several query points.
contract ClaimScalarTest is Test {
    uint256 constant P = 0xFFFFFFFF00000001;
    uint256 constant W = 749;
    uint256 constant NP = 2649;

    function _fp2(uint256 i) internal pure returns (F.Fp2 memory) {
        return F.Fp2((i * 2654435761 + 11) % P, (i * 40503 + 7) % P);
    }

    function _ctx(uint256 x) internal pure returns (DQ.Ctx memory ctx) {
        ctx.z = _fp2(5);
        ctx.compZ = _fp2(6);
        ctx.x = x;
        ctx.g = 7;
        ctx.width = W;
        ctx.nPeriodic = NP;
    }

    function _inputs()
        internal
        pure
        returns (uint256[] memory row, F.Fp2[] memory ood, F.Fp2[] memory k, F.Fp2[] memory pz)
    {
        row = new uint256[](W);
        for (uint256 i = 0; i < W; ++i) row[i] = (i * 7919 + 3) % P;
        ood = new F.Fp2[](2 * W);
        for (uint256 i = 0; i < 2 * W; ++i) ood[i] = _fp2(i);
        k = new F.Fp2[](2 * W + 1 + NP);
        for (uint256 i = 0; i < k.length; ++i) k[i] = _fp2(i + 99);
        pz = new F.Fp2[](NP);
        for (uint256 i = 0; i < NP; ++i) pz[i] = _fp2(i + 555);
    }

    /// The scalar form equals the per-claim form, at several query points.
    function test_theScalarFormEqualsThePerClaimForm() public pure {
        (uint256[] memory row, F.Fp2[] memory ood, F.Fp2[] memory k, F.Fp2[] memory pz) = _inputs();

        F.Fp2 memory s = DQ.claimScalar(k, pz, W);

        for (uint256 t = 0; t < 4; ++t) {
            uint256 x = 12345 + t * 99991;
            F.Fp2 memory perClaim = DQ.combineWithPeriodic(row, _fp2(8), ood, k, _ctx(x), row, pz);
            F.Fp2 memory scalar = DQ.combineWithScalar(row, _fp2(8), ood, k, _ctx(x), row, s);
            assertEq(scalar.c0, perClaim.c0, "scalar form must equal per-claim, c0");
            assertEq(scalar.c1, perClaim.c1, "scalar form must equal per-claim, c1");
        }
    }

    /// The claims enter each query as one subtraction of S, so only the row is summed.
    function test_theScalarFormIsCheaperPerQuery() public {
        (uint256[] memory row, F.Fp2[] memory ood, F.Fp2[] memory k, F.Fp2[] memory pz) = _inputs();
        F.Fp2 memory s = DQ.claimScalar(k, pz, W);
        H h = new H();

        uint256 gPer = h.perClaim(row, ood, k, _ctx(12345), pz);
        uint256 gScalar = h.scalar(row, ood, k, _ctx(12345), s);
        console2.log("per-claim fold, per query:", gPer);
        console2.log("scalar fold,    per query:", gScalar);
        console2.log("saved per base query     :", gPer - gScalar);
        // S is computed once and shared by all queries
        uint256 g0 = gasleft();
        DQ.claimScalar(k, pz, W);
        console2.log("claimScalar, once at begin:", g0 - gasleft());
    }
}

contract H {
    function perClaim(uint256[] memory row, F.Fp2[] memory ood, F.Fp2[] memory k, DQ.Ctx memory ctx, F.Fp2[] memory pz)
        external view returns (uint256 g) {
        uint256 g0 = gasleft();
        DQ.combineWithPeriodic(row, F.Fp2(8, 0), ood, k, ctx, row, pz);
        g = g0 - gasleft();
    }
    function scalar(uint256[] memory row, F.Fp2[] memory ood, F.Fp2[] memory k, DQ.Ctx memory ctx, F.Fp2 memory s)
        external view returns (uint256 g) {
        uint256 g0 = gasleft();
        DQ.combineWithScalar(row, F.Fp2(8, 0), ood, k, ctx, row, s);
        g = g0 - gasleft();
    }
}
