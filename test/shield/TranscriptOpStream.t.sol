// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

/// @notice Two-round transcript draw offsets follow from op costs: Fp 1, Fp2 2, digest 4.
contract TranscriptOpStreamTest is Test {
    string internal ly;

    uint256 constant OPS_PER_DIGEST = 4;
    uint256 constant OPS_PER_FP2 = 2;
    uint256 constant OPS_PER_FP = 1;

    function setUp() public {
        ly = vm.readFile(
            vm.envOr("COMPOSE_LAYOUT", string("spec/emit-v11-first/real-structure-layout.json"))
        );
    }

    function _l(string memory k) internal view returns (uint256) {
        return vm.parseJsonUint(ly, string.concat(".", k));
    }

    function test_everyPublishedDrawSitsWhereTheModelPutsIt() public view {
        uint256 pubLen = _l("pub_len");
        uint256 nChal = _l("n_chal");
        uint256 ncoeff2 = _l("ncoeff2");
        uint256 frameLen = _l("frame_len");
        uint256 nPz = _l("n_pz");

        // absorb every public word, then the trace root
        uint256 op = pubLen * OPS_PER_FP + OPS_PER_DIGEST;

        // beta, then gamma, each a single base-field squeeze
        assertEq(op, _l("beta_op"), "beta does not sit one digest past the publics");
        op += nChal * OPS_PER_FP;

        // the permutation root, committed after beta and gamma are drawn
        op += OPS_PER_DIGEST;
        assertEq(op, _l("coeff_op"), "the coefficients do not follow the permutation root");

        // the composition coefficients, then the composition root, then the point
        op += ncoeff2;
        op += OPS_PER_DIGEST;
        assertEq(op, _l("z_op"), "the point does not follow the composition root");

        // z itself, then the opened frame
        op += OPS_PER_FP2;
        op += frameLen * OPS_PER_FP2;
        assertEq(op, _l("claim_op"), "the periodic claims do not follow the frame");

        // the claims at z, then the DEEP coefficients
        op += nPz * OPS_PER_FP2;
        assertEq(op, _l("deep_coeff_op"), "the DEEP coefficients do not follow the claims");
    }

    function test_theCoefficientOpCountIsTwoPerCoefficient() public view {
        assertEq(_l("ncoeff2"), _l("n_coeff") * OPS_PER_FP2, "ncoeff2 is not 2 * n_coeff");
    }

    /// Round two adds six ops after the trace root: beta, gamma and the permutation root.
    function test_roundTwoAddsExactlySixOperationsAfterTheTraceRoot() public view {
        uint256 roundOneCoeffOp = _l("pub_len") * OPS_PER_FP + OPS_PER_DIGEST;
        assertEq(
            _l("coeff_op") - roundOneCoeffOp,
            _l("n_chal") * OPS_PER_FP + OPS_PER_DIGEST,
            "round two does not add exactly the challenges plus one digest"
        );
        assertEq(_l("coeff_op") - roundOneCoeffOp, 6, "the gap is not the six operations expected");
    }

    function test_theGapIsThereBecauseTheLayoutDeclaresTwoRounds() public view {
        assertTrue(vm.parseJsonBool(ly, ".rounds"), "layout is not two-round");
        assertEq(_l("n_chal"), 2, "two rounds without two challenges");
    }
}
