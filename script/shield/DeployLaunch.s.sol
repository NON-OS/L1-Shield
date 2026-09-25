// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {RealSplitVerifier} from "../../contracts/shield/verifier/RealSplitVerifier.sol";
import {RealQueryVerify as V} from "../../contracts/shield/verifier/RealQueryVerify.sol";
import {StagedStarkVerifier} from "../../contracts/shield/verifier/StagedStarkVerifier.sol";
import {ComposedStarkVerifier} from "../../contracts/shield/verifier/ComposedStarkVerifier.sol";
import {LaunchEvaluator} from "../../contracts/shield/verifier/LaunchEvaluator.sol";
import {IStarkVerifier} from "../../contracts/shield/interfaces/IStarkVerifier.sol";
import {IPoseidonGoldilocks} from "../../contracts/shield/interfaces/IPoseidonGoldilocks.sol";
import {IAssociationSetRegistry} from "../../contracts/shield/interfaces/IAssociationSetRegistry.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";
import {EmitCodec} from "./EmitCodec.sol";

/// @notice Deploys the launch stack from a launch emit: verifier, evaluator, adapter, then a pool
///         of 12 words per intent, no settler and native scale 1, gated on an attested real proof.
/// @dev env: EMIT (default spec/launch-honest), IMAGE (default spec/launch-program/image.bin), SAFE,
///      HASHER, REGISTRY, FEE_ROUTER. The Safe sets the relay fee caps once the pool exists.
contract DeployLaunch is Script {
    uint256 internal constant WORDS = 12;
    /// @dev The floor the published provable figure must reach before anything else is deployed.
    uint256 internal constant FLOOR_BITS = 80;

    string internal dir;
    string internal st;
    string internal ly;

    function run() external {
        dir = vm.envOr("EMIT", string("spec/launch-honest"));
        st = vm.readFile(string.concat(dir, "/structure.json"));
        ly = vm.readFile(string.concat(dir, "/layout.json"));
        require(vm.parseJsonBool(ly, ".format5"), "emit is not format 5");
        require(vm.parseJsonUint(ly, ".n_chal") == 2, "emit is not two-round");

        vm.startBroadcast();
        RealSplitVerifier v = _verifier();
        LaunchEvaluator ev =
            new LaunchEvaluator(vm.readFileBinary(vm.envOr("IMAGE", string("spec/launch-program/image.bin"))));
        ComposedStarkVerifier a = _adapter(v, ev);
        (, uint256 provable) = a.soundnessBits();
        require(provable >= FLOOR_BITS, "the provable figure is under the floor");
        (bytes memory whole, uint256[] memory words) = _whole(v, a);
        bytes32 digest = a.attest(whole, words);
        ShieldedPool pool = new ShieldedPool(
            vm.envAddress("SAFE"),
            IStarkVerifier(address(a)),
            IPoseidonGoldilocks(vm.envAddress("HASHER")),
            IAssociationSetRegistry(vm.envAddress("REGISTRY")),
            vm.envAddress("FEE_ROUTER"),
            25,
            25,
            1, // native scale: one unit is one wei
            WORDS,
            _selfTest(digest, words)
        );
        vm.stopBroadcast();

        (uint256 conjectured,) = a.soundnessBits();
        console2.log("RealSplitVerifier     ", address(v));
        console2.log("LaunchEvaluator       ", address(ev));
        console2.log("ComposedStarkVerifier ", address(a));
        console2.log("ShieldedPool          ", address(pool));
        console2.log("provable, conjectured ", provable, conjectured);
        console2.logBytes32(digest);
    }

    function _verifier() internal returns (RealSplitVerifier) {
        return new RealSplitVerifier(
            vm.parseJsonUint(st, ".outer_n_queries"),
            vm.parseJsonUint(st, ".log_domain"),
            vm.parseJsonUint(st, ".log_trace_len"),
            vm.parseJsonUint(st, ".trace_width"),
            vm.parseJsonUint(st, ".n_coeffs"),
            EmitCodec.grindBits(st, ly),
            vm.parseJsonUint(st, ".coset_shift"),
            vm.parseJsonUint(ly, ".outer_n_periodic"),
            vm.parseJsonBytes32(ly, ".outer_periodic_root_keccak_at_deployment_rate"),
            true, // verifyWholeComposed is the only entry, and it computes comp_z itself
            RealSplitVerifier.Codec({
                nChal: vm.parseJsonUint(ly, ".n_chal"),
                regionWidth: vm.parseJsonUint(st, ".region_width"),
                finalAsCoefficients: vm.parseJsonBool(ly, ".final_layer_coefficients"),
                digestBytes: vm.parseJsonUint(ly, ".digest_bytes"),
                friRadix: vm.parseJsonUint(ly, ".fri_radix"),
                logDegreeBound: vm.parseJsonUint(st, ".log_domain") - vm.parseJsonUint(st, ".extra_blowup_bits") - 1,
                logFinal: vm.parseJsonUint(ly, ".fri_final_log"),
                format5: true,
                extChallenges: vm.parseJsonBool(ly, ".ext_challenges"),
                powerCoeffs: EmitCodec.powerCoeffs(ly),
                powerDeep: EmitCodec.powerDeep(ly),
                roundGrindBits: EmitCodec.roundGrindBits(ly),
                finalSearches: EmitCodec.finalSearches(ly),
            maskColumn: EmitCodec.maskColumn(st)
            })
        );
    }

    function _adapter(RealSplitVerifier v, LaunchEvaluator ev) internal returns (ComposedStarkVerifier) {
        uint256[] memory sizes = new uint256[](1);
        sizes[0] = 1;
        RealSplitVerifier[] memory vs = new RealSplitVerifier[](1);
        vs[0] = v;
        StagedStarkVerifier.Soundness[] memory sd = new StagedStarkVerifier.Soundness[](1);
        // proved directly for the chain: no inner stage
        sd[0] = StagedStarkVerifier.Soundness({
            outerQueries: uint16(vm.parseJsonUint(st, ".outer_n_queries")),
            outerExtraBlowupBits: uint16(vm.parseJsonUint(st, ".extra_blowup_bits")),
            outerGrindBits: uint16(EmitCodec.grindBits(st, ly)),
            innerQueries: uint16(vm.parseJsonUint(st, ".inner_n_queries")),
            innerExtraBlowupBits: uint16(vm.parseJsonUint(st, ".inner_extra_blowup_bits")),
            innerGrindBits: 0
        });
        return new ComposedStarkVerifier(sizes, vs, sd, address(0), ev, WORDS);
    }

    // The ONE_CALL blob: the head through the final layer, the nonce region and base count, the
    // claims, the FRI sections, then each base section with its periodic row and path.
    function _whole(RealSplitVerifier v, ComposedStarkVerifier a)
        internal
        view
        returns (bytes memory whole, uint256[] memory words)
    {
        bytes memory p = vm.readFileBinary(string.concat(dir, "/settlement.proof"));
        V.Shape memory sh = v.shape();
        (uint256[] memory base, uint256[] memory rows, uint256[] memory perms, uint256[] memory fri, uint256 so,) =
            V.sectionsOf(p, sh);
        bytes memory head = bytes.concat(_sub(p, 0, fri[0]), _sub(p, base[0] - _region(p, sh), base[0]));
        bytes memory claims = _sub(p, so, so + 4 + sh.nPeriodic * 16);
        bytes memory queries = _sub(p, fri[0], fri[sh.nq]);
        for (uint256 q = 0; q < sh.nq; ++q) {
            queries = bytes.concat(
                queries, _sub(p, base[q], base[q + 1]), _sub(p, rows[q], rows[q + 1]), _sub(p, perms[q], perms[q + 1])
            );
        }
        whole = abi.encode(a.ONE_CALL(), head, claims, queries, uint256(0), uint256(0));
        words = _words(abi.decode(vm.parseJson(vm.readFile(string.concat(dir, "/publics-array.json"))), (uint256[])));
    }

    // the nonce region and the base count that closes the head
    function _region(bytes memory p, V.Shape memory sh) internal pure returns (uint256) {
        (V.Head memory h,) = V.decode(p, sh);
        return V.nonceBytes(sh, h.friRoots.length) + 4;
    }

    // 36 limbs to 12 words: digests four 64-bit limbs low first, words 6 to 9 one limb each, and
    // the recipient and fee recipient 48 + 48 + 48 + 16 bits.
    function _words(uint256[] memory L) internal pure returns (uint256[] memory w) {
        require(L.length == 36, "a launch statement is 36 limbs");
        w = new uint256[](WORDS);
        uint256[12] memory at = [uint256(0), 4, 8, 12, 16, 20, 24, 25, 26, 27, 28, 32];
        for (uint256 i = 0; i < WORDS; ++i) {
            if (i >= 6 && i <= 9) w[i] = L[at[i]];
            else if (i >= 10) for (uint256 l = 0; l < 4; ++l) w[i] |= L[at[i] + l] << (48 * l);
            else for (uint256 l = 0; l < 4; ++l) w[i] |= L[at[i] + l] << (64 * l);
        }
    }

    function _selfTest(bytes32 digest, uint256[] memory words)
        internal
        view
        returns (ShieldedPool.DeploymentSelfTest memory s)
    {
        // expected hashes come from the vector file, never from the hasher under test
        string memory j = vm.readFile("spec/launch-selftest.json");
        s.hash2Left = vm.parseJsonBytes32(j, ".hash2.left");
        s.hash2Right = vm.parseJsonBytes32(j, ".hash2.right");
        s.hash2Expected = vm.parseJsonBytes32(j, ".hash2.expected");
        s.fieldsInput = vm.parseJsonUintArray(j, ".hashFields.input");
        s.fieldsExpected = vm.parseJsonBytes32(j, ".hashFields.expected");
        s.proof = abi.encodePacked(digest);
        s.proofPublicInputs = words;
        s.noteValue = vm.parseJsonUint(j, ".noteVector.value");
        s.noteAssetId = uint64(vm.parseJsonUint(j, ".noteVector.assetId"));
        s.noteOwnerCommit = vm.parseJsonBytes32(j, ".noteVector.ownerCommit");
        s.noteCommitmentExpected = vm.parseJsonBytes32(j, ".noteVector.commitment");
    }

    function _sub(bytes memory b, uint256 from, uint256 to) internal pure returns (bytes memory o) {
        o = new bytes(to - from);
        for (uint256 i = 0; i < o.length; ++i) o[i] = b[from + i];
    }
}
