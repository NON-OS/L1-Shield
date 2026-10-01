// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {LaunchBase, LaunchReplay} from "./LaunchBase.sol";
import {RealQueryVerify as V} from "../../contracts/shield/verifier/RealQueryVerify.sol";
import {LaunchEvaluator} from "../../contracts/shield/verifier/LaunchEvaluator.sol";
import {ProgramFormEvaluator, ProgramFormEvaluatorBase} from "../../contracts/shield/verifier/ProgramFormEvaluator.sol";
import {ProgramFormAir as Air} from "../../contracts/shield/verifier/ProgramFormAir.sol";

/// The launch gate, held to the frozen package: every honest proof verifies through the composed
/// path with 12 public words, every forgery and tampered statement is refused, and the evaluator's
/// comp_z and the replayed z are the prover's.
contract LaunchGateTest is LaunchBase {
    string[4] internal names = ["honest", "spend", "withdraw-a", "withdraw-b"];

    function _dir(uint256 i) internal view returns (string memory) {
        return string.concat("spec/launch-", names[i]);
    }

    function _proof(uint256 i) internal view returns (bytes memory whole, uint256[] memory words) {
        bytes memory p = vm.readFileBinary(string.concat(_dir(i), "/settlement.proof"));
        whole = _whole(_cut(p));
        words = _words(_pubs(i));
    }

    function _pubs(uint256 i) internal view returns (uint256[] memory) {
        return abi.decode(vm.parseJson(vm.readFile(string.concat(_dir(i), "/publics-array.json"))), (uint256[]));
    }

    function test_everyHonestProofVerifiesWithTwelveWords() public {
        for (uint256 i = 0; i < 4; ++i) {
            (bytes memory whole, uint256[] memory words) = _proof(i);
            assertTrue(a.verifyBatch(whole, words), names[i]);
            // the callee's own gas: the caller's memory, which grows with each proof, is not in it
            console2.log(names[i], "verifyBatch gas", vm.lastCallGas().gasTotalUsed);
        }
    }

    /// The withdrawals carry real addresses in both address words, each of four nonzero limbs.
    function test_theWithdrawalsExerciseEveryAddressLimb() public view {
        for (uint256 i = 2; i < 4; ++i) {
            uint256[] memory L = _pubs(i);
            for (uint256 k = 28; k < 36; ++k) assertTrue(L[k] != 0, "an address limb is zero");
            uint256[] memory w = _words(L);
            assertTrue(w[10] >> 160 == 0 && w[11] >> 160 == 0, "an address word is wider than an address");
            assertTrue(w[10] >> 144 != 0 && w[11] >> 144 != 0, "the top limb is not exercised");
        }
    }

    /// The replay draws the package's z, and the launch evaluator at that z returns its comp_z.
    function test_theOraclesMatch() public {
        LaunchReplay rp = new LaunchReplay();
        V.Shape memory sh = v.shape();
        for (uint256 i = 0; i < 4; ++i) {
            Cut memory c = _cut(vm.readFileBinary(string.concat(_dir(i), "/settlement.proof")));
            uint256[] memory limbs = _pubs(i);
            LaunchReplay.Out memory o = rp.replay(sh, c.head, c.claims, limbs);
            string memory oracle = vm.readFile(string.concat(_dir(i), "/oracle.json"));
            uint256[] memory z = vm.parseJsonUintArray(oracle, ".z");
            assertEq(o.ck.z.c0, z[0], "z.c0");
            assertEq(o.ck.z.c1, z[1], "z.c1");
            uint256[] memory b = vm.parseJsonUintArray(oracle, ".challenges[0]");
            uint256[] memory gm = vm.parseJsonUintArray(oracle, ".challenges[1]");
            assertEq(o.ck.beta.c0, b[0], "beta.c0");
            assertEq(o.ck.beta.c1, b[1], "beta.c1");
            assertEq(o.ck.gamma.c0, gm[0], "gamma.c0");
            assertEq(o.ck.gamma.c1, gm[1], "gamma.c1");

            (uint256 c0, uint256 c1) = _compZ(o, limbs);
            uint256[] memory want = vm.parseJsonUintArray(oracle, ".comp_z");
            assertEq(c0, want[0], string.concat(names[i], " comp_z.c0"));
            assertEq(c1, want[1], string.concat(names[i], " comp_z.c1"));
        }
    }

    function _compZ(LaunchReplay.Out memory o, uint256[] memory limbs) internal view returns (uint256, uint256) {
        (uint256[2][] memory fr, uint256[2][] memory pz, uint256[2][] memory cf) = _asPairs(o);
        V.Checkpoint memory ck = o.ck;
        return ev.evaluate(fr, pz, cf, limbs, [ck.beta.c0, ck.beta.c1, ck.gamma.c0, ck.gamma.c1, ck.z.c0, ck.z.c1]);
    }

    function _asPairs(LaunchReplay.Out memory o)
        internal
        pure
        returns (uint256[2][] memory fr, uint256[2][] memory pz, uint256[2][] memory cf)
    {
        fr = new uint256[2][](o.ood.length);
        for (uint256 k = 0; k < fr.length; ++k) fr[k] = [o.ood[k].c0, o.ood[k].c1];
        pz = new uint256[2][](o.periodicZ.length);
        for (uint256 k = 0; k < pz.length; ++k) pz[k] = [o.periodicZ[k].c0, o.periodicZ[k].c1];
        cf = new uint256[2][](o.coeffs.length);
        for (uint256 k = 0; k < cf.length; ++k) cf[k] = [o.coeffs[k].c0, o.coeffs[k].c1];
    }

    /// Each evaluator takes only its own circuit: the launch one only its pinned image, the
    /// program-form one only its own tape.
    function test_eachEvaluatorServesOnlyItsCircuit() public {
        bytes memory image = vm.readFileBinary("spec/launch-program/image.bin");
        image[image.length - 1] ^= 0x01;
        vm.expectRevert(ProgramFormEvaluatorBase.ImageMismatch.selector);
        new LaunchEvaluator(image);
        vm.expectRevert(ProgramFormEvaluatorBase.ImageMismatch.selector);
        new LaunchEvaluator(vm.readFileBinary("spec/launch-program/tape.bin"));
        vm.expectRevert(ProgramFormEvaluatorBase.TapeMismatch.selector);
        new ProgramFormEvaluator(vm.readFileBinary("spec/launch-program/tape.bin"));
        assertEq(ev.N_PUBLIC(), 36, "the launch circuit pins 36 public words");
    }

    /// The launch program reads four challenge inputs. Compiled as if it read two, its first read of
    /// gamma.c0 is an operand past the inputs and the compile refuses it. A count of three is refused.
    function test_theChallengeCountIsNotGuessed() public {
        bytes memory prog = vm.readFileBinary("spec/launch-program/program.bin");
        Compiler c = new Compiler();
        vm.expectRevert();
        c.compile(prog, Air.N_CHALLENGES);
        vm.expectRevert(Air.BadChallengeCount.selector);
        c.compile(prog, 3);
        assertGt(c.compile(prog, Air.N_CHALLENGES_SPLIT), 0);
    }

    // ------------------------------------------------------------------------------ forgeries

    function _refuses(string memory proofPath, string memory publicsPath, string memory what) internal view {
        bytes memory whole = _whole(_cut(_body(proofPath)));
        assertFalse(_accepts(whole, _words(_limbs(publicsPath))), what);
    }

    /// The control is the forgeries' construction with an honest witness. It must pass, or their
    /// refusals would say nothing about the witness.
    function test_theForgeryControlIsAccepted() public view {
        bytes memory whole = _whole(_cut(_body(string.concat(FORGED, "/control.bin"))));
        assertTrue(_accepts(whole, _words(_limbs(string.concat(FORGED, "/control.bin.publics.json")))));
    }

    /// The mask pair is opened as one Fp2 value: the verifier is built with the rule on.
    function test_theMaskPairIsOpenedAsOneValue() public view {
        assertEq(v.maskColumn(), 42, "the mask pair starts at column 42");
    }

    /// A proof that opens the mask pair as two values is refused at the zero check.
    function test_aMaskOpenedApartIsRefused() public view {
        _refuses(string.concat(FORGED, "/mask_split.bin"), string.concat(FORGED, "/mask_split.bin.publics.json"), "mask split");
    }

    /// An otherwise honest proof whose second mask slot is not zero is refused.
    function test_anHonestProofOfTheEarlierRuleIsRefused() public view {
        _refuses(string.concat(FORGED, "/route1-honest.bin"), string.concat(FORGED, "/route1-honest.bin.publics.json"), "route 1");
    }

    function test_aBentTraceIsRefused() public view {
        _refuses(string.concat(FORGED, "/bent.bin"), string.concat(FORGED, "/bent.bin.publics.json"), "bent");
    }

    function test_aValueBalancedOnlyModPIsRefused() public view {
        _refuses(string.concat(FORGED, "/wrap.bin"), string.concat(FORGED, "/wrap.bin.publics.json"), "wrap");
    }

    function test_aDummyWorthPIsRefused() public view {
        _refuses(string.concat(FORGED, "/dummy_p.bin"), string.concat(FORGED, "/dummy_p.bin.publics.json"), "dummy");
    }

    function test_aWrongNullifierIsRefused() public view {
        _refuses(
            string.concat(FORGED, "/nullifier.bin"), string.concat(FORGED, "/nullifier.bin.publics.json"), "nullifier"
        );
    }

    /// A proof whose composition is not the circuit's: comp_z computed on chain catches it at DEEP.
    function test_aCompositionTakenAsToldIsRefused() public view {
        _refuses(
            string.concat(FORGED, "/lying/control.bin"),
            string.concat(FORGED, "/lying/control.bin.publics.json"),
            "lying"
        );
    }

    function test_aStatementSwapIsRefused() public view {
        (bytes memory whole,) = _proof(0);
        assertFalse(_accepts(whole, _words(_pubs(1))), "honest under spend's statement");
        (whole,) = _proof(2);
        assertFalse(_accepts(whole, _words(_pubs(3))), "withdraw-a under withdraw-b's statement");
    }

    function test_aTamperedAmountIsRefused() public view {
        (bytes memory whole,) = _proof(0);
        assertFalse(_accepts(whole, _words(_limbs(string.concat(FORGED, "/tampered.publics.json")))));
    }

    function test_aTamperedRecipientIsRefused() public view {
        (bytes memory whole,) = _proof(2);
        assertFalse(_accepts(whole, _words(_limbs(string.concat(FORGED, "/tampered-recipient.publics.json")))));
    }

    /// Each nonce is bound: one bit off in any of the twelve and the proof is refused.
    function test_aTamperedNonceIsRefused() public view {
        bytes memory p = vm.readFileBinary(string.concat(_dir(0), "/settlement.proof"));
        Cut memory c = _cut(p);
        uint256[] memory words = _words(_pubs(0));
        // the nonce region ends four bytes before the head does, at the base count
        uint256 end = c.head.length - 4;
        for (uint256 k = 0; k < 12; ++k) {
            bytes memory h = bytes.concat(c.head);
            h[end - 8 * (12 - k)] ^= 0x01;
            bytes memory whole = abi.encode(a.ONE_CALL(), h, c.claims, c.queries, uint256(0), uint256(0));
            assertFalse(_accepts(whole, words), "a tampered nonce was accepted");
        }
    }
}

contract Compiler {
    function compile(bytes memory prog, uint256 nChal) external pure returns (uint256) {
        return Air.compile(prog, "", 0x80, nChal).length;
    }
}
