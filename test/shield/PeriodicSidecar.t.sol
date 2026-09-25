// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";
import {StarkMerkle as MK} from "../../contracts/shield/verifier/StarkMerkle.sol";
import {ProductionDeepQuery} from "../../contracts/shield/verifier/ProductionDeepQuery.sol";
import {RealSplitVerifier} from "../../contracts/shield/verifier/RealSplitVerifier.sol";

/// The periodic sidecar binds each claim P_j(z) to an authenticated periodic row under a root fixed
/// at deployment, tested on constructed data.
contract PeriodicSidecarTest is Test {
    uint256 constant P = 0xFFFFFFFF00000001;
    uint256 constant WIDTH = 8;
    uint256 constant NPER = 5;

    function _fp2(uint256 i) internal pure returns (F.Fp2 memory) {
        return F.Fp2((i * 2654435761 + 11) % P, (i * 40503 + 7) % P);
    }

    function _ctx(uint256 nPeriodic) internal pure returns (ProductionDeepQuery.Ctx memory ctx) {
        ctx.z = _fp2(5);
        ctx.compZ = _fp2(6);
        ctx.x = 12345;
        ctx.g = 7;
        ctx.width = WIDTH;
        ctx.nPeriodic = nPeriodic;
    }

    function _inputs()
        internal
        pure
        returns (uint256[] memory row, F.Fp2[] memory ood, F.Fp2[] memory coeffs, uint256[] memory per, F.Fp2[] memory perZ)
    {
        row = new uint256[](WIDTH);
        for (uint256 i = 0; i < WIDTH; ++i) row[i] = (i * 7919 + 3) % P;
        ood = new F.Fp2[](2 * WIDTH);
        for (uint256 i = 0; i < 2 * WIDTH; ++i) ood[i] = _fp2(i);
        coeffs = new F.Fp2[](2 * WIDTH + 1 + NPER);
        for (uint256 i = 0; i < coeffs.length; ++i) coeffs[i] = _fp2(i + 99);
        per = new uint256[](NPER);
        for (uint256 i = 0; i < NPER; ++i) per[i] = (i * 104729 + 17) % P;
        perZ = new F.Fp2[](NPER);
        for (uint256 i = 0; i < NPER; ++i) perZ[i] = _fp2(i + 555);
    }

    /// With no sidecar the DEEP combination is unchanged.
    function test_withNoSidecarTheCombinationIsUnchanged() public pure {
        (uint256[] memory row, F.Fp2[] memory ood, F.Fp2[] memory coeffs,, ) = _inputs();
        ProductionDeepQuery.Ctx memory ctx = _ctx(0);
        F.Fp2 memory plain = ProductionDeepQuery.combine(row, _fp2(8), ood, coeffs, ctx);
        F.Fp2 memory viaSidecar = ProductionDeepQuery.combineWithPeriodic(
            row, _fp2(8), ood, coeffs, ctx, new uint256[](0), new F.Fp2[](0)
        );
        assertEq(plain.c0, viaSidecar.c0, "c0 must not move when there is no sidecar");
        assertEq(plain.c1, viaSidecar.c1, "c1 must not move when there is no sidecar");
    }

    /// With a sidecar the periodic terms enter the combination.
    function test_theSidecarTermsActuallyEnterTheCombination() public pure {
        (uint256[] memory row, F.Fp2[] memory ood, F.Fp2[] memory coeffs, uint256[] memory per, F.Fp2[] memory perZ) =
            _inputs();
        F.Fp2 memory without = ProductionDeepQuery.combine(row, _fp2(8), ood, coeffs, _ctx(0));
        F.Fp2 memory with = ProductionDeepQuery.combineWithPeriodic(row, _fp2(8), ood, coeffs, _ctx(NPER), per, perZ);
        assertTrue(with.c0 != without.c0 || with.c1 != without.c1, "the periodic terms must change the sum");
    }

    /// A bent claim changes the combination, so it fails the DEEP identity at every query.
    function test_aBentClaimChangesTheCombination() public pure {
        (uint256[] memory row, F.Fp2[] memory ood, F.Fp2[] memory coeffs, uint256[] memory per, F.Fp2[] memory perZ) =
            _inputs();
        F.Fp2 memory honest = ProductionDeepQuery.combineWithPeriodic(row, _fp2(8), ood, coeffs, _ctx(NPER), per, perZ);
        for (uint256 j = 0; j < NPER; ++j) {
            F.Fp2[] memory bent = new F.Fp2[](NPER);
            for (uint256 i = 0; i < NPER; ++i) bent[i] = perZ[i];
            bent[j] = F.Fp2(addmod(bent[j].c0, 1, P), bent[j].c1);
            F.Fp2 memory got =
                ProductionDeepQuery.combineWithPeriodic(row, _fp2(8), ood, coeffs, _ctx(NPER), per, bent);
            assertTrue(got.c0 != honest.c0 || got.c1 != honest.c1, "every claim must be bound, not just some");
        }
    }

    /// A periodic row that opens under one deployment's root does not open under another's.
    function test_aPeriodicRowCannotBeReplayedAcrossProofs() public pure {
        (,,, uint256[] memory per,) = _inputs();
        bytes32[] memory path = new bytes32[](3);
        for (uint256 i = 0; i < 3; ++i) path[i] = keccak256(abi.encode("sibling", i));
        bytes32 rootA = _rootFrom(MK.hashLeafWidePeriodic(per), 5, path);

        // a second deployment, same row and position, one different sibling: a different root
        bytes32[] memory pathB = new bytes32[](3);
        for (uint256 i = 0; i < 3; ++i) pathB[i] = path[i];
        pathB[1] = keccak256(abi.encode("other-schedule", uint256(1)));
        bytes32 rootB = _rootFrom(MK.hashLeafWidePeriodic(per), 5, pathB);
        assertTrue(rootA != rootB, "two schedules must commit differently");

        assertTrue(MK.verifyPathWidePeriodic(rootA, 5, per, path), "the row opens under its own root");
        assertFalse(MK.verifyPathWidePeriodic(rootB, 5, per, path), "and not under another proof's root");
        assertFalse(MK.verifyPathWidePeriodic(rootA, 5, per, pathB), "nor with another proof's path");
    }

    function _rootFrom(bytes32 leaf, uint256 index, bytes32[] memory path) internal pure returns (bytes32 node) {
        node = leaf;
        uint256 idx = index;
        for (uint256 i = 0; i < path.length; ++i) {
            node = (idx & 1) == 0 ? MK.hashNode(node, path[i]) : MK.hashNode(path[i], node);
            idx >>= 1;
        }
    }

    /// A periodic row opens only against the root fixed at deployment, never a root the proof carries.
    function test_aPeriodicRowOpensOnlyAgainstTheBakedRoot() public pure {
        (,,, uint256[] memory per,) = _inputs();
        bytes32[] memory path = new bytes32[](3);
        for (uint256 i = 0; i < 3; ++i) path[i] = keccak256(abi.encode("sibling", i));
        bytes32 leaf = MK.hashLeafWidePeriodic(per);
        bytes32 node = leaf;
        uint256 idx = 5;
        for (uint256 i = 0; i < 3; ++i) {
            node = (idx & 1) == 0 ? MK.hashNode(node, path[i]) : MK.hashNode(path[i], node);
            idx >>= 1;
        }
        assertTrue(MK.verifyPathWidePeriodic(node, 5, per, path), "the honest row opens");

        uint256[] memory bent = new uint256[](NPER);
        for (uint256 i = 0; i < NPER; ++i) bent[i] = per[i];
        bent[2] = addmod(bent[2], 1, P);
        assertFalse(MK.verifyPathWidePeriodic(node, 5, bent, path), "a bent row must not open");

        // and a periodic leaf is not a trace leaf: the domains are distinct, so a row
        // authenticated against one commitment cannot be replayed against the other.
        assertTrue(MK.hashLeafWidePeriodic(per) != MK.hashLeafWide(per), "periodic and trace leaves must differ");
    }
}
