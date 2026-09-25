// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProductionAir} from "../../contracts/shield/verifier/ProductionAir.sol";

/// @notice The settlement emit, held to its own arithmetic: each field checked against others.
/// `EMIT_DIR` selects the emit directory. These checks do not show which emit is current.
contract SettlementEmitAgreementTest is Test {
    string internal st;
    string internal ly;

    function setUp() public {
        string memory dir = vm.envOr("EMIT_DIR", string("spec/emit-v11-first"));
        st = vm.readFile(string.concat(dir, "/real-structure.json"));
        ly = vm.readFile(string.concat(dir, "/real-structure-layout.json"));
    }

    function _s(string memory k) internal view returns (uint256) {
        return vm.parseJsonUint(st, string.concat(".", k));
    }

    function _l(string memory k) internal view returns (uint256) {
        return vm.parseJsonUint(ly, string.concat(".", k));
    }

    function _sStr(string memory k) internal view returns (string memory) {
        return vm.parseJsonString(st, string.concat(".", k));
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// n_deep_terms and n_coeffs each match their derivation and differ from each other.
    function test_theDeepCountAndTheCoefficientCountAreBothRightAndAreNotEachOther() public view {
        uint256 deep = 2 * _s("trace_width") + _l("outer_n_periodic") + 1;
        assertEq(_l("n_deep_terms"), deep, "n_deep_terms is not 2*trace_width + periodic + 1");
        assertEq(_s("n_coeffs"), _s("num_transition") + _s("num_boundary"), "n_coeffs is not transitions + boundaries");
        assertTrue(_l("n_deep_terms") != _s("n_coeffs"), "the two counts collapsed onto one number");
    }

    /// The permutation challenges are declared as transcript draws against the trace root.
    function test_theChallengesAreDeclaredToComeFromTheTranscript() public view {
        assertTrue(
            _eq(_sStr("permutation_challenges"), "transcript"),
            "the emit does not declare its permutation challenges as transcript draws"
        );
        assertTrue(
            _eq(_sStr("permutation_challenge_root"), "trace_root"),
            "the challenges are not declared as drawn against the trace root"
        );
    }

    /// The rounds flag and the challenge count agree: two rounds with two challenges, or neither.
    function test_theRoundsFlagAndTheChallengeCountAgree() public view {
        bool rounds = vm.parseJsonBool(ly, ".rounds");
        if (rounds) {
            assertEq(_l("n_chal"), 2, "two rounds declared but not two challenges");
        } else {
            assertEq(_l("n_chal"), 0, "challenges declared without the round that draws them");
        }
    }

    /// A stated inner_soundness_bits equals q*(extra+1)+grind, and the provable half clears 80.
    function test_theStatedSoundnessAgreesWithTheParametersBesideIt() public view {
        if (!vm.keyExistsJson(st, ".inner_soundness_bits")) return; // the key is optional
        uint256 q = _s("inner_n_queries");
        uint256 rateBits = _s("inner_extra_blowup_bits") + 1;
        uint256 grind = _s("grind_bits");
        assertEq(_s("inner_soundness_bits"), q * rateBits + grind, "the stated conjectured figure is not its own parameters");
        assertGe(q * rateBits / 2 + grind, 80, "the provable figure is under the floor every production point is gated on");
    }

    /// The four compose-region column relations hold on the real emit.
    function test_theComposeColumnsSitWhereTheArithmeticPutsThem() public view {
        uint256 f = _l("frame_len");
        uint256 p = _l("n_pz");
        uint256 c = _l("n_chal");
        assertEq(_l("c_periodic_col"), 2 * f, "c_periodic_col is not 2*frame_len");
        assertEq(_l("c_chal_col"), 2 * (f + p), "c_chal_col is not 2*(frame_len + n_pz)");
        assertEq(_l("c_z_col"), 2 * (f + p + c), "c_z_col is not 2*(frame_len + n_pz + n_chal)");
        assertEq(_l("c_coeff_col"), _l("c_z_col") + 2, "the first coefficient is not one slot past the point");
    }
}

/// @notice The emitted coset offset agrees with the `COSET_SHIFT` that `friFold` bakes.
contract CosetShiftAgreementTest is Test {
    /// The emit's coset_shift equals ProductionAir.COSET_SHIFT.
    function test_theEmittedCosetIsTheOneTheFoldBakes() public view {
        string memory dir = vm.envOr("EMIT_DIR", string("spec/emit-v11-first"));
        uint256 emitted = vm.parseJsonUint(vm.readFile(string.concat(dir, "/real-structure.json")), ".coset_shift");
        assertEq(emitted, ProductionAir.COSET_SHIFT, "the emit's coset offset is not the one friFold bakes");
    }
}
