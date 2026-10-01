// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProductionAir} from "../../contracts/shield/verifier/ProductionAir.sol";
import {RealQueryVerify as V} from "../../contracts/shield/verifier/RealQueryVerify.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";

/// @notice Early-stop `x_final` against the prover's 32-query vector at log_n 26 and 14 folds.
/// Vector from the prover's fri-final emit, (query index, x_final) pairs.
contract FriFinalVectorTest is Test {
    uint256 internal constant LOG_N = 26;
    uint256 internal constant N_FOLDS = 14;

    function _vector() internal pure returns (uint256[2][32] memory v) {
        v[0][0] = 11723028; v[0][1] = 12425600731870078394;
        v[1][0] = 49096621; v[1][1] = 10513588107883014851;
        v[2][0] = 41888001; v[2][1] = 3191945344974037401;
        v[3][0] = 47049167; v[3][1] = 5816668135317920814;
        v[4][0] = 20653665; v[4][1] = 16020562740473052899;
        v[5][0] = 59271379; v[5][1] = 4420683899145030490;
        v[6][0] = 18948011; v[6][1] = 10988428271093178462;
        v[7][0] = 9532449; v[7][1] = 15864896855047867938;
        v[8][0] = 396111; v[8][1] = 13349829791867246406;
        v[9][0] = 21209647; v[9][1] = 15316740973447564095;
        v[10][0] = 24272435; v[10][1] = 14890462837404435871;
        v[11][0] = 62699968; v[11][1] = 998098477292261200;
        v[12][0] = 2036778; v[12][1] = 15369796445506219828;
        v[13][0] = 19903017; v[13][1] = 7969145787476349176;
        v[14][0] = 3234952; v[14][1] = 901576348173948987;
        v[15][0] = 50915635; v[15][1] = 11969699574041004633;
        v[16][0] = 38554321; v[16][1] = 12220404096570240031;
        v[17][0] = 54673450; v[17][1] = 15302320629163758019;
        v[18][0] = 11662616; v[18][1] = 5536821206297982763;
        v[19][0] = 53602647; v[19][1] = 18176792648460327367;
        v[20][0] = 41443983; v[20][1] = 11188583910780299490;
        v[21][0] = 49871175; v[21][1] = 445271138126922210;
        v[22][0] = 40901603; v[22][1] = 8136593059812229017;
        v[23][0] = 13635202; v[23][1] = 8614447423884830109;
        v[24][0] = 61420782; v[24][1] = 5757796024197086171;
        v[25][0] = 61892081; v[25][1] = 45800427667027330;
        v[26][0] = 37371793; v[26][1] = 9690194113914772689;
        v[27][0] = 29774771; v[27][1] = 8702478176788244970;
        v[28][0] = 56077431; v[28][1] = 18090428282967098523;
        v[29][0] = 35007669; v[29][1] = 5008351457554761113;
        v[30][0] = 16918406; v[30][1] = 17292654010409136514;
        v[31][0] = 36909924; v[31][1] = 16014836652122967314;
    }

    /// xFinal equals the prover's point at all 32 queries.
    function test_xFinalMatchesTheProver() public pure {
        uint256 omega = F.fpPow(7, (V.PMOD - 1) >> LOG_N);
        uint256[2][32] memory v = _vector();
        for (uint256 i = 0; i < 32; ++i) {
            assertEq(
                ProductionAir.xFinal(omega, v[i][0], 1 << LOG_N, N_FOLDS),
                v[i][1],
                "x_final does not match the prover at this query"
            );
        }
    }

    /// xFinal never equals the negated point, so the last layer's sign is not dropped.
    function test_theNegatedPointIsRejected() public pure {
        uint256 omega = F.fpPow(7, (V.PMOD - 1) >> LOG_N);
        uint256[2][32] memory v = _vector();
        uint256 wrong = 0;
        for (uint256 i = 0; i < 32; ++i) {
            if (ProductionAir.xFinal(omega, v[i][0], 1 << LOG_N, N_FOLDS) != F.fpNeg(v[i][1])) ++wrong;
        }
        assertEq(wrong, 32, "a negated final point was accepted somewhere");
    }
}
