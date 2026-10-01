// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {LaunchBase} from "./LaunchBase.sol";
import {RealSplitVerifier} from "../../contracts/shield/verifier/RealSplitVerifier.sol";
import {RealQueryVerify as V} from "../../contracts/shield/verifier/RealQueryVerify.sol";
import {RealQueryWalk as W} from "../../contracts/shield/verifier/RealQueryWalk.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";
import {IProgramFormEvaluator} from "../../contracts/shield/verifier/IProgramFormEvaluator.sol";

/// The steps of RealSplitVerifier.verifyWholeComposed, in its order, with the gas of each.
contract PhaseReplay {
    struct Out {
        uint256 head;
        uint256 transcript;
        uint256 evaluate;
        uint256 friChallenges;
        uint256 prepareDeep;
        uint256 fri;
        uint256 bases;
    }

    struct S {
        V.Shape sh;
        V.Head h;
        F.Fp2[] ood;
        V.Checkpoint ck;
        F.Fp2[] coeffs;
        uint256 cz0;
        uint256 cz1;
        F.Fp2[] betas;
        uint256[] friIdx;
        W.Base b;
        uint256[] deep;
        uint256 off;
    }

    function run(
        RealSplitVerifier v,
        IProgramFormEvaluator ev,
        bytes calldata head,
        bytes calldata claims,
        bytes calldata queries,
        uint256[] calldata publics
    ) external view returns (Out memory o) {
        S memory s;
        uint256 g = gasleft();
        s.sh = v.shape();
        (s.h, s.ood) = W.readHead(head, s.sh);
        s.h.periodicZ = W.readClaims(claims, s.sh);
        o.head = g - gasleft();

        g = gasleft();
        (s.ck, s.coeffs) = V.mainCheckpointCoeffs(s.h, s.ood, s.sh, publics);
        o.transcript = g - gasleft();

        g = gasleft();
        (s.cz0, s.cz1) = _evaluate(ev, s, publics);
        o.evaluate = g - gasleft();

        g = gasleft();
        bytes32 seed;
        (s.coeffs,, seed) = V.mainResume(s.ck.state, s.h, s.sh);
        (s.betas, s.friIdx) = V.friChallenges(s.h, s.sh, seed);
        o.friChallenges = g - gasleft();

        g = gasleft();
        s.b = _base(v, s);
        W.prepareDeep(s.b, s.ood, s.coeffs, s.h.periodicZ, s.cz0, s.cz1);
        o.prepareDeep = g - gasleft();

        g = gasleft();
        _fri(v, s, queries);
        o.fri = g - gasleft();

        g = gasleft();
        for (uint256 i = 0; i < s.sh.nq; ++i) {
            s.off = W.baseQuery(queries, s.off, s.b, i, s.friIdx[i], s.deep[2 * i], s.deep[2 * i + 1]);
        }
        o.bases = g - gasleft();
        require(s.off == queries.length, "the walk did not consume the proof");
    }

    function _fri(RealSplitVerifier v, S memory s, bytes calldata queries) private view {
        s.deep = new uint256[](2 * s.sh.nq);
        W.Fri memory f = W.Fri(s.h.friRoots, s.betas, s.h.finalFlat, s.b.omega, v.logDomain(), v.digestBytes(), true);
        for (uint256 i = 0; i < s.sh.nq; ++i) {
            (s.off, s.deep[2 * i], s.deep[2 * i + 1]) = W.friQuery(queries, s.off, f, s.friIdx[i], i);
        }
    }

    function _base(RealSplitVerifier v, S memory s) private view returns (W.Base memory b) {
        b.traceRoot = s.h.traceRoot;
        b.permRoot = s.h.permRoot;
        b.compRoot = s.h.compRoot;
        b.periodicRoot = v.periodicRoot();
        b.w = v.digestBytes();
        b.traceWidth = v.traceWidth();
        b.regionWidth = v.regionWidth();
        b.nPeriodic = v.nPeriodic();
        b.z0 = s.ck.z.c0;
        b.z1 = s.ck.z.c1;
        b.g = F.fpPow(V.GEN, (V.PMOD - 1) >> v.logTraceLen());
        b.omega = V.domainRoot(s.sh);
        b.cosetShift = v.cosetShift();
    }

    function _evaluate(IProgramFormEvaluator ev, S memory s, uint256[] calldata publics)
        private
        view
        returns (uint256, uint256)
    {
        uint256[2][] memory fr;
        uint256[2][] memory pz;
        uint256[2][] memory cf;
        F.Fp2[] memory ood = s.ood;
        F.Fp2[] memory per = s.h.periodicZ;
        F.Fp2[] memory co = s.coeffs;
        assembly {
            fr := ood
            pz := per
            cf := co
        }
        V.Checkpoint memory ck = s.ck;
        return ev.evaluate(fr, pz, cf, publics, [ck.beta.c0, ck.beta.c1, ck.gamma.c0, ck.gamma.c1, ck.z.c0, ck.z.c1]);
    }
}

/// Where the execution gas of one launch verification goes, phase by phase, on the honest proof.
contract LaunchPhaseGasTest is LaunchBase {
    function test_phases() public {
        Cut memory c = _cut(vm.readFileBinary(string.concat(HONEST, "/settlement.proof")));
        uint256[] memory limbs = abi.decode(vm.parseJson(vm.readFile(string.concat(HONEST, "/publics-array.json"))), (uint256[]));
        PhaseReplay r = new PhaseReplay();
        PhaseReplay.Out memory o = r.run(v, ev, c.head, c.claims, c.queries, limbs);

        uint256 g = gasleft();
        assertTrue(v.verifyWholeComposed(c.head, c.claims, c.queries, limbs, ev), "the honest proof verifies");
        uint256 whole = g - gasleft();

        uint256 sum = o.head + o.transcript + o.evaluate + o.friChallenges + o.prepareDeep + o.fri + o.bases;
        console2.log("verifyWholeComposed, whole call", whole);
        console2.log("sum of the phases", sum);
        console2.log("1 decode head and claims", o.head);
        console2.log("2 main transcript and coefficients", o.transcript);
        console2.log("3 constraint evaluation at z", o.evaluate);
        console2.log("4 DEEP draw, FRI transcript and grinding", o.friChallenges);
        console2.log("5 DEEP preparation", o.prepareDeep);
        console2.log("6 FRI queries, 19", o.fri);
        console2.log("7 base queries and DEEP, 19", o.bases);
    }
}
