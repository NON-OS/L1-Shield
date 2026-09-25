// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {RealSplitVerifier} from "../../contracts/shield/verifier/RealSplitVerifier.sol";
import {IProgramFormEvaluator} from "../../contracts/shield/verifier/IProgramFormEvaluator.sol";
import {ProgramFormAir} from "../../contracts/shield/verifier/ProgramFormAir.sol";
import {RealQueryVerify as V} from "../../contracts/shield/verifier/RealQueryVerify.sol";
import {StarkTranscript as TS} from "../../contracts/shield/verifier/StarkTranscript.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";
import {EmitCodec} from "../../script/shield/EmitCodec.sol";

/// Reverts with the point it was handed, so a test reads the point the verifier passes.
contract PointEcho is IProgramFormEvaluator {
    error Point(uint256[6] point);

    function evaluate(
        uint256[2][] calldata,
        uint256[2][] calldata,
        uint256[2][] calldata,
        uint256[] calldata,
        uint256[6] calldata point
    ) external pure returns (uint256, uint256) {
        revert Point(point);
    }
}

contract Replay {
    function checkpoint(V.Shape memory sh, bytes calldata head, bytes calldata claims, uint256[] calldata publics)
        external
        pure
        returns (V.Checkpoint memory c, V.Head memory h, F.Fp2[] memory ood)
    {
        (h, ood) = V.decodeHead(head, sh);
        h.periodicZ = V.decodeClaims(claims, sh);
        c = V.mainCheckpointFull(h, ood, sh, publics);
    }
}

/// The ext codec draws beta and gamma in Fp2. Held to the f5-honest head, it differs from the base
/// codec only in the draws: two squeezes tagged 0x06 then 0x07 per challenge, in place of one 0x03.
contract ExtChallengesTest is Test {
    uint256 internal constant P = 0xFFFFFFFF00000001;
    string internal constant DIR = "spec/f5-honest";

    RealSplitVerifier internal base;
    RealSplitVerifier internal ext;
    Replay internal rp;
    bytes internal head;
    bytes internal claims;
    bytes internal queries;
    uint256[] internal pubs;

    function setUp() public {
        base = _verifier(false);
        ext = _verifier(true);
        rp = new Replay();
        (head, claims, queries) = _cut(vm.readFileBinary(string.concat(DIR, "/settlement.proof")), base.shape());
        pubs = abi.decode(vm.parseJson(vm.readFile(string.concat(DIR, "/publics-array.json"))), (uint256[]));
    }

    struct Sections {
        uint256[] b;
        uint256[] rows;
        uint256[] perms;
        uint256[] fri;
        uint256 so;
    }

    // the verifier's own section walk, from V.sectionsOf
    function _cut(bytes memory p, V.Shape memory sh)
        internal
        pure
        returns (bytes memory h, bytes memory c, bytes memory q)
    {
        Sections memory x;
        (x.b, x.rows, x.perms, x.fri, x.so,) = V.sectionsOf(p, sh);
        h = bytes.concat(_sub(p, 0, x.fri[0]), _sub(p, x.b[0] - 12, x.b[0]));
        c = _sub(p, x.so, x.so + 4 + sh.nPeriodic * 16);
        q = _sub(p, x.fri[0], x.fri[sh.nq]);
        for (uint256 i = 0; i < sh.nq; ++i) {
            q = bytes.concat(
                q, _sub(p, x.b[i], x.b[i + 1]), _sub(p, x.rows[i], x.rows[i + 1]), _sub(p, x.perms[i], x.perms[i + 1])
            );
        }
    }

    function _verifier(bool extChallenges) internal returns (RealSplitVerifier) {
        string memory st = vm.readFile(string.concat(DIR, "/structure.json"));
        string memory ly = vm.readFile(string.concat(DIR, "/layout.json"));
        RealSplitVerifier.Codec memory c = _codec(st, ly, extChallenges);
        uint256 nPer = vm.parseJsonUint(ly, ".outer_n_periodic");
        bytes32 root = vm.parseJsonBytes32(ly, ".outer_periodic_root_keccak_at_deployment_rate");
        return new RealSplitVerifier(
            vm.parseJsonUint(st, ".outer_n_queries"),
            vm.parseJsonUint(st, ".log_domain"),
            vm.parseJsonUint(st, ".log_trace_len"),
            vm.parseJsonUint(st, ".trace_width"),
            vm.parseJsonUint(st, ".n_coeffs"),
            vm.parseJsonUint(st, ".grind_bits"),
            vm.parseJsonUint(st, ".coset_shift"),
            nPer,
            root,
            false,
            c
        );
    }

    function _codec(string memory st, string memory ly, bool extChallenges)
        internal
        view
        returns (RealSplitVerifier.Codec memory)
    {
        return RealSplitVerifier.Codec({
            nChal: vm.parseJsonUint(ly, ".n_chal"),
            regionWidth: vm.parseJsonUint(st, ".region_width"),
            finalAsCoefficients: true,
            digestBytes: vm.parseJsonUint(ly, ".digest_bytes"),
            friRadix: vm.parseJsonUint(ly, ".fri_radix"),
            logDegreeBound: vm.parseJsonUint(st, ".log_domain") - vm.parseJsonUint(st, ".extra_blowup_bits") - 1,
            logFinal: vm.parseJsonUint(ly, ".fri_final_log"),
            format5: vm.parseJsonBool(ly, ".format5"),
            extChallenges: extChallenges,
            powerCoeffs: EmitCodec.powerCoeffs(ly),
            powerDeep: EmitCodec.powerDeep(ly),
            roundGrindBits: EmitCodec.roundGrindBits(ly),
            finalSearches: EmitCodec.finalSearches(ly),
        maskColumn: 0
        });
    }

    // keccak256(tag || state), then the first eight bytes little-endian, reduced once
    function _squeeze(bytes32 s, uint8 tag) internal pure returns (bytes32 next, uint256 v) {
        next = keccak256(abi.encodePacked(tag, s));
        uint64 x;
        for (uint256 i = 0; i < 8; ++i) {
            x |= uint64(uint8(next[i])) << uint64(8 * i);
        }
        v = x >= P ? x - P : x;
    }

    // The transcript up to the draws: publics, then the trace root.
    function _head(V.Head memory h, V.Shape memory sh) internal view returns (TS.T memory t) {
        t = TS.init("NONOS-STARK-EXT");
        for (uint256 i = 0; i < pubs.length; ++i) {
            TS.absorbFp(t, pubs[i]);
        }
        TS.absorbDigest(t, h.traceRoot, sh.digestBytes);
    }

    // Everything after the draws, as the base codec does it.
    function _tail(TS.T memory t, V.Head memory h, F.Fp2[] memory ood, V.Shape memory sh)
        internal
        pure
        returns (F.Fp2 memory z)
    {
        TS.absorbDigest(t, h.permRoot, sh.digestBytes);
        TS.skipChallengeFp2(t, sh.nCoeffs);
        TS.absorbDigest(t, h.compRoot, sh.digestBytes);
        z = TS.challengeFp2(t);
        TS.absorbFp2Array(t, ood);
        TS.absorbFp2Array(t, h.periodicZ);
    }

    function test_extDrawsAreTwoSqueezesWhereTheBaseDrawWas() public view {
        V.Shape memory shB = base.shape();
        V.Shape memory shE = ext.shape();
        assertTrue(shE.extChallenges && !shB.extChallenges, "codec flag");
        (V.Checkpoint memory cb, V.Head memory h, F.Fp2[] memory ood) = rp.checkpoint(shB, head, claims, pubs);
        (V.Checkpoint memory ce,,) = rp.checkpoint(shE, head, claims, pubs);
        bytes32 s0 = _head(h, shB).state;
        console2.log("head state");
        console2.logBytes32(s0);

        bytes32 sBase = _baseDraws(s0, cb);
        bytes32 sExt = _extDraws(s0, ce);

        // every later step is unchanged: each codec's checkpoint is the common tail from its own state
        TS.T memory t = TS.T(sBase);
        F.Fp2 memory z = _tail(t, h, ood, shB);
        assertEq(cb.state, t.state, "base checkpoint");
        _eq(cb.z, z, "base z");
        t = TS.T(sExt);
        z = _tail(t, h, ood, shE);
        assertEq(ce.state, t.state, "ext checkpoint");
        _eq(ce.z, z, "ext z");
        assertTrue(ce.state != cb.state, "the codecs share a state");
    }

    // one 0x03 squeeze each
    function _baseDraws(bytes32 s0, V.Checkpoint memory cb) internal pure returns (bytes32 s) {
        uint256 v;
        (s, v) = _squeeze(s0, 0x03);
        assertEq(cb.beta.c0, v, "base beta");
        (s, v) = _squeeze(s, 0x03);
        assertEq(cb.gamma.c0, v, "base gamma");
        console2.log("base beta, gamma", cb.beta.c0, cb.gamma.c0);
        assertEq(cb.beta.c1 | cb.gamma.c1, 0, "a base draw has no extension part");
    }

    // 0x06 then 0x07 for beta, again for gamma, from the same state
    function _extDraws(bytes32 s0, V.Checkpoint memory ce) internal pure returns (bytes32 s) {
        uint256[4] memory e;
        (s, e[0]) = _squeeze(s0, 0x06);
        (s, e[1]) = _squeeze(s, 0x07);
        (s, e[2]) = _squeeze(s, 0x06);
        (s, e[3]) = _squeeze(s, 0x07);
        _eq([ce.beta.c0, ce.beta.c1, ce.gamma.c0, ce.gamma.c1], e, "ext beta, gamma");
        for (uint256 i = 0; i < 4; ++i) {
            console2.log("ext beta.c0 beta.c1 gamma.c0 gamma.c1", e[i]);
        }

        TS.T memory t = TS.T(s0);
        F.Fp2 memory tb = TS.challengeFp2(t);
        F.Fp2 memory tg = TS.challengeFp2(t);
        _eq([tb.c0, tb.c1, tg.c0, tg.c1], e, "challengeFp2");
        assertEq(t.state, s, "challengeFp2 state");
    }

    // The verifier hands the evaluator [beta.c0, beta.c1, gamma.c0, gamma.c1, z.c0, z.c1].
    function test_verifierPassesTheSixWordsInOrder() public {
        PointEcho echo = new PointEcho();
        RealSplitVerifier[2] memory vs = [base, ext];
        for (uint256 k = 0; k < 2; ++k) {
            (V.Checkpoint memory c,,) = rp.checkpoint(vs[k].shape(), head, claims, pubs);
            uint256[6] memory want = [c.beta.c0, c.beta.c1, c.gamma.c0, c.gamma.c1, c.z.c0, c.z.c1];
            vm.expectRevert(abi.encodeWithSelector(PointEcho.Point.selector, want));
            vs[k].verifyWholeComposed(head, claims, queries, pubs, echo);
        }
    }

    // A two-op program whose transitions are beta and gamma themselves, at t = 1, so comp_z is
    // (a0 beta + a1 gamma) / (z - 1). Each unit alpha reads one challenge back whole.
    function test_evaluatorReadsTheSixWordsInOrder() public pure {
        // header: 2 ops, 2 outputs, no boundaries, rows, frame or periodic, logT 0, no exempt rows
        bytes memory prog = abi.encodePacked(uint16(2), uint16(2), uint64(0), uint16(0));
        // input 0 is beta and input 1 gamma, once the frame and periodic slots are passed
        prog = abi.encodePacked(prog, uint8(1), uint16(0), uint8(1), uint16(1), uint16(0), uint16(1));
        uint256[6] memory pt = [uint256(11), 13, 17, 19, 23, 29];
        _eq(_readBack(prog, pt, 0), F.Fp2(pt[0], pt[1]), "beta is words 0, 1");
        _eq(_readBack(prog, pt, 1), F.Fp2(pt[2], pt[3]), "gamma is words 2, 3");
    }

    // comp_z with alpha_k = 1 and the other zero, times (z - 1)
    function _readBack(bytes memory prog, uint256[6] memory pt, uint256 k) internal pure returns (F.Fp2 memory r) {
        uint256[] memory al = new uint256[](4);
        al[2 * k] = 1;
        uint256[] memory none = new uint256[](0);
        (uint256 c0, uint256 c1) = ProgramFormAir.composition(prog, none, none, al, none, pt);
        r = F.mul(F.Fp2(c0, c1), F.Fp2(pt[4] - 1, pt[5]));
    }

    function test_extNeedsFormatFive() public {
        string memory st = vm.readFile(string.concat(DIR, "/structure.json"));
        RealSplitVerifier.Codec memory c = _codec(st, vm.readFile(string.concat(DIR, "/layout.json")), true);
        c.format5 = false;
        vm.expectRevert(RealSplitVerifier.FormatFiveOnly.selector);
        new RealSplitVerifier(
            vm.parseJsonUint(st, ".outer_n_queries"),
            vm.parseJsonUint(st, ".log_domain"),
            vm.parseJsonUint(st, ".log_trace_len"),
            vm.parseJsonUint(st, ".trace_width"),
            vm.parseJsonUint(st, ".n_coeffs"),
            vm.parseJsonUint(st, ".grind_bits"),
            vm.parseJsonUint(st, ".coset_shift"),
            0,
            bytes32(0),
            false,
            c
        );
    }

    function _eq(uint256[4] memory a, uint256[4] memory b, string memory what) internal pure {
        for (uint256 i = 0; i < 4; ++i) {
            assertEq(a[i], b[i], what);
        }
    }

    function _eq(F.Fp2 memory a, F.Fp2 memory b, string memory what) internal pure {
        assertEq(a.c0, b.c0, what);
        assertEq(a.c1, b.c1, what);
    }

    function _sub(bytes memory b, uint256 from, uint256 to) internal pure returns (bytes memory o) {
        o = new bytes(to - from);
        for (uint256 i = 0; i < o.length; ++i) {
            o[i] = b[from + i];
        }
    }
}
