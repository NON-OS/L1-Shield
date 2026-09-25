// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RealSplitVerifier} from "../../contracts/shield/verifier/RealSplitVerifier.sol";
import {RealQueryVerify as V} from "../../contracts/shield/verifier/RealQueryVerify.sol";
import {RealQueryWalk as W} from "../../contracts/shield/verifier/RealQueryWalk.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";
import {StagedStarkVerifier} from "../../contracts/shield/verifier/StagedStarkVerifier.sol";
import {ComposedStarkVerifier} from "../../contracts/shield/verifier/ComposedStarkVerifier.sol";
import {LaunchEvaluator} from "../../contracts/shield/verifier/LaunchEvaluator.sol";
import {EmitCodec} from "../../script/shield/EmitCodec.sol";

/// The verifier's own transcript walk over a one-call head, everything it draws handed back.
contract LaunchReplay {
    struct Out {
        V.Checkpoint ck;
        F.Fp2[] coeffs;
        F.Fp2[] deep;
        bytes32 seed;
        F.Fp2[] betas;
        uint256[] friIdx;
        uint64[] roundNonces;
        uint64[] finalNonces;
        F.Fp2[] ood;
        F.Fp2[] periodicZ;
    }

    function replay(V.Shape memory sh, bytes calldata head, bytes calldata claims, uint256[] calldata publics)
        external
        pure
        returns (Out memory o)
    {
        V.Head memory h;
        (h, o.ood) = W.readHead(head, sh);
        h.periodicZ = W.readClaims(claims, sh);
        o.periodicZ = h.periodicZ;
        (o.ck, o.coeffs) = V.mainCheckpointCoeffs(h, o.ood, sh, publics);
        (o.deep,, o.seed) = V.mainResume(o.ck.state, h, sh);
        (o.betas, o.friIdx) = V.friChallenges(h, sh, o.seed);
        o.roundNonces = h.roundNonces;
        o.finalNonces = h.finalNonces;
    }
}

/// The launch emit: one verifier, the launch evaluator and a 12-word adapter, built from
/// spec/launch-honest the way script/shield/DeployLaunch.s.sol builds them.
abstract contract LaunchBase is Test {
    string internal constant HONEST = "spec/launch-honest";
    string internal constant FORGED = "spec/launch-forgeries";
    uint256 internal constant HEADER = 40; // a package proof file's header: magic, format, parameter id
    uint256 internal constant WORDS = 12;

    RealSplitVerifier internal v;
    LaunchEvaluator internal ev;
    ComposedStarkVerifier internal a;
    string internal st;
    string internal ly;

    function setUp() public virtual {
        st = vm.readFile(string.concat(HONEST, "/structure.json"));
        ly = vm.readFile(string.concat(HONEST, "/layout.json"));
        v = _verifier();
        ev = new LaunchEvaluator(vm.readFileBinary("spec/launch-program/image.bin"));
        a = _adapter(v, ev);
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
            true,
            _codec()
        );
    }

    function _codec() internal view returns (RealSplitVerifier.Codec memory) {
        return RealSplitVerifier.Codec({
            nChal: vm.parseJsonUint(ly, ".n_chal"),
            regionWidth: vm.parseJsonUint(st, ".region_width"),
            finalAsCoefficients: vm.parseJsonBool(ly, ".final_layer_coefficients"),
            digestBytes: vm.parseJsonUint(ly, ".digest_bytes"),
            friRadix: vm.parseJsonUint(ly, ".fri_radix"),
            logDegreeBound: vm.parseJsonUint(st, ".log_domain") - vm.parseJsonUint(st, ".extra_blowup_bits") - 1,
            logFinal: vm.parseJsonUint(ly, ".fri_final_log"),
            format5: vm.parseJsonBool(ly, ".format5"),
            extChallenges: vm.parseJsonBool(ly, ".ext_challenges"),
            powerCoeffs: EmitCodec.powerCoeffs(ly),
            powerDeep: EmitCodec.powerDeep(ly),
            roundGrindBits: EmitCodec.roundGrindBits(ly),
            finalSearches: EmitCodec.finalSearches(ly),
        maskColumn: EmitCodec.maskColumn(st)
        });
    }

    function _soundness() internal view returns (StagedStarkVerifier.Soundness memory) {
        return StagedStarkVerifier.Soundness({
            outerQueries: uint16(vm.parseJsonUint(st, ".outer_n_queries")),
            outerExtraBlowupBits: uint16(vm.parseJsonUint(st, ".extra_blowup_bits")),
            outerGrindBits: uint16(EmitCodec.grindBits(st, ly)),
            innerQueries: uint16(vm.parseJsonUint(st, ".inner_n_queries")),
            innerExtraBlowupBits: uint16(vm.parseJsonUint(st, ".inner_extra_blowup_bits")),
            innerGrindBits: 0
        });
    }

    function _adapter(RealSplitVerifier v_, LaunchEvaluator ev_) internal returns (ComposedStarkVerifier) {
        uint256[] memory sizes = new uint256[](1);
        sizes[0] = 1;
        RealSplitVerifier[] memory vs = new RealSplitVerifier[](1);
        vs[0] = v_;
        StagedStarkVerifier.Soundness[] memory sd = new StagedStarkVerifier.Soundness[](1);
        sd[0] = _soundness();
        return new ComposedStarkVerifier(sizes, vs, sd, address(0), ev_, WORDS);
    }

    struct Cut {
        bytes head;
        bytes claims;
        bytes queries;
    }

    /// Splits a proof body into its one-call parts: the head up to the FRI sections plus the nonce
    /// region and base count, the claims, then the FRI sections and each base section with its row and path.
    function _cut(bytes memory p) internal view returns (Cut memory c) {
        V.Shape memory sh = v.shape();
        (uint256[] memory b, uint256[] memory rows, uint256[] memory perms, uint256[] memory fri, uint256 so,) =
            V.sectionsOf(p, sh);
        uint256 region = V.nonceBytes(sh, _rounds(p, sh)) + 4;
        c.head = bytes.concat(_sub(p, 0, fri[0]), _sub(p, b[0] - region, b[0]));
        c.claims = _sub(p, so, so + 4 + sh.nPeriodic * 16);
        c.queries = _sub(p, fri[0], fri[sh.nq]);
        for (uint256 i = 0; i < sh.nq; ++i) {
            c.queries = bytes.concat(
                c.queries, _sub(p, b[i], b[i + 1]), _sub(p, rows[i], rows[i + 1]), _sub(p, perms[i], perms[i + 1])
            );
        }
    }

    function _rounds(bytes memory p, V.Shape memory sh) internal pure returns (uint256) {
        (V.Head memory h,) = V.decode(p, sh);
        return h.friRoots.length;
    }

    /// A package file's body: the 40-byte header is the prover's, never the verifier's.
    function _body(string memory path) internal view returns (bytes memory) {
        bytes memory f = vm.readFileBinary(path);
        require(f.length > HEADER && f[0] == "N" && f[1] == "O" && f[2] == "X" && f[3] == "P", "not a package proof");
        return _sub(f, HEADER, f.length);
    }

    function _limbs(string memory path) internal view returns (uint256[] memory) {
        return vm.parseJsonUintArray(vm.readFile(path), ".publics");
    }

    /// The pool's 12 words from the circuit's 36 limbs: digests are four 64-bit limbs low first,
    /// words 6 to 9 one limb each, and the two addresses 48 + 48 + 48 + 16 bits.
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

    function _whole(Cut memory c) internal view returns (bytes memory) {
        return abi.encode(a.ONE_CALL(), c.head, c.claims, c.queries, uint256(0), uint256(0));
    }

    /// verifyBatch's verdict, a revert read as a refusal.
    function _accepts(bytes memory whole, uint256[] memory words) internal view returns (bool) {
        try a.verifyBatch(whole, words) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    function _sub(bytes memory b, uint256 from, uint256 to) internal pure returns (bytes memory o) {
        o = new bytes(to - from);
        for (uint256 i = 0; i < o.length; ++i) o[i] = b[from + i];
    }
}
