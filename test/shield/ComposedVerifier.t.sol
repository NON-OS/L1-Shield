// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {OneCallSettleTest} from "./OneCallSettle.t.sol";
import {RealSplitVerifier} from "../../contracts/shield/verifier/RealSplitVerifier.sol";
import {StagedStarkVerifier} from "../../contracts/shield/verifier/StagedStarkVerifier.sol";
import {ComposedStarkVerifier} from "../../contracts/shield/verifier/ComposedStarkVerifier.sol";
import {IProgramFormEvaluator} from "../../contracts/shield/verifier/IProgramFormEvaluator.sol";
import {ProgramFormEvaluator} from "../../contracts/shield/verifier/ProgramFormEvaluator.sol";
import {FixedEvaluator} from "./mocks/FixedEvaluator.sol";

/// The adapter that recomputes comp_z, held to the proof artifact from `EMIT`.
contract ComposedVerifierTest is OneCallSettleTest {
    function _composed(IProgramFormEvaluator c, RealSplitVerifier v) internal returns (ComposedStarkVerifier) {
        uint256[] memory sizes = new uint256[](1);
        sizes[0] = 1;
        RealSplitVerifier[] memory vs = new RealSplitVerifier[](1);
        vs[0] = v;
        StagedStarkVerifier.Soundness[] memory sd = new StagedStarkVerifier.Soundness[](1);
        sd[0] = StagedStarkVerifier.Soundness({
            outerQueries: uint16(vm.parseJsonUint(st, ".outer_n_queries")),
            outerExtraBlowupBits: uint16(vm.parseJsonUint(st, ".extra_blowup_bits")),
            outerGrindBits: uint16(vm.parseJsonUint(st, ".grind_bits")),
            innerQueries: uint16(vm.parseJsonUint(st, ".inner_n_queries")),
            innerExtraBlowupBits: uint16(vm.parseJsonUint(st, ".inner_extra_blowup_bits")),
            innerGrindBits: 16
        });
        return new ComposedStarkVerifier(sizes, vs, sd, makeAddr("settler"), c, 11);
    }

    function _oracle() internal view returns (uint256 c0, uint256 c1) {
        string memory cz = vm.readFile(string.concat(dir, "/compz.json"));
        c0 = vm.parseUint(vm.parseJsonString(cz, ".c0"));
        c1 = vm.parseUint(vm.parseJsonString(cz, ".c1"));
    }

    /// With an evaluator that returns the honest comp_z, the whole proof verifies.
    function test_acceptsWhenTheComputedCompZIsTheProofs() public {
        (uint256 c0, uint256 c1) = _oracle();
        ComposedStarkVerifier a2 = _composed(new FixedEvaluator(c0, c1), _v());
        (bytes memory whole, uint256[] memory words) = _wholeWith(a2);
        assertTrue(a2.verifyBatch(whole, words));
    }

    /// The DEEP check uses the evaluator's comp_z, so a value one bit off the committed
    /// composition is refused.
    function test_refusesWhenTheComputedCompZDiffers() public {
        (uint256 c0, uint256 c1) = _oracle();
        ComposedStarkVerifier a2 = _composed(new FixedEvaluator(c0, c1 ^ 1), _v());
        (bytes memory whole, uint256[] memory words) = _wholeWith(a2);
        try a2.verifyBatch(whole, words) returns (bool ok) {
            assertFalse(ok, "a comp_z off the committed composition was accepted");
        } catch {}
    }

    /// The real evaluator serves the bound program-form circuit only: on its emit the whole proof
    /// verifies with comp_z computed on chain, and on another circuit's emit it refuses.
    function test_theRealEvaluatorServesOnlyItsCircuit() public {
        RealSplitVerifier v = _v();
        ComposedStarkVerifier a2 = _composed(new ProgramFormEvaluator(_tape()), v);
        (bytes memory whole, uint256[] memory words) = _wholeWith(a2);
        if (_f5()) {
            assertTrue(a2.verifyBatch(whole, words), "the evaluator's circuit's proof was refused");
        } else {
            try a2.verifyBatch(whole, words) returns (bool ok) {
                assertFalse(ok, "another circuit's proof was accepted");
            } catch {}
        }
    }

    function _tape() internal view returns (bytes memory) {
        return vm.readFileBinary("spec/program-form/tape.bin");
    }

    /// A digest is only as good as the attest that verified it whole, and only for its batch.
    function test_attestThenTheDigestVerifiesForItsBatchOnly() public {
        (uint256 c0, uint256 c1) = _oracle();
        ComposedStarkVerifier a2 = _composed(new FixedEvaluator(c0, c1), _v());
        (bytes memory whole, uint256[] memory words) = _wholeWith(a2);
        bytes32 d = a2.attest(whole, words);
        assertTrue(a2.verifyBatch(abi.encodePacked(d), words));
        words[6] ^= 1;
        assertFalse(a2.verifyBatch(abi.encodePacked(d), words));
        assertFalse(a2.verifyBatch(abi.encodePacked(keccak256("never attested")), words));
    }

    function _wholeWith(ComposedStarkVerifier a2) internal returns (bytes memory whole, uint256[] memory words) {
        a = StagedStarkVerifier(address(a2));
        return _whole();
    }
}
