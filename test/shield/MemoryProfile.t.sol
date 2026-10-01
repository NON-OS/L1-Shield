// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {RealSplitVerifier} from "../../contracts/shield/verifier/RealSplitVerifier.sol";
import {RealQueryVerify as V} from "../../contracts/shield/verifier/RealQueryVerify.sol";
import {NullSink} from "./NullSink.sol";
import {FixedEvaluator} from "./mocks/FixedEvaluator.sol";
import {EmitCodec} from "../../script/shield/EmitCodec.sol";

/// @notice One-call verifier gas against query count, acceptance of the emitted proof, and
/// refusal of single-bit tampering in each proof section. comp_z comes from a fixed evaluator
/// holding the artifact's value, so every reading here is the walk and not the constraints.
contract MemoryProfileTest is Test {
    bytes internal proof;
    string internal st;
    string internal ly;
    string internal dir;

    function setUp() public {
        dir = vm.envOr("EMIT", string("spec/f5-honest"));
        proof = vm.readFileBinary(string.concat(dir, "/settlement.proof"));
        st = vm.readFile(string.concat(dir, "/structure.json"));
        ly = vm.readFile(string.concat(dir, "/layout.json"));
    }

    function _shape() internal view returns (V.Shape memory sh) {
        sh.nq = vm.parseJsonUint(st, ".outer_n_queries");
        sh.logDomain = vm.parseJsonUint(st, ".log_domain");
        sh.traceWidth = vm.parseJsonUint(st, ".trace_width");
        sh.nCoeffs = vm.parseJsonUint(st, ".n_coeffs");
        sh.nPeriodic = vm.parseJsonUint(ly, ".outer_n_periodic");
        sh.nChal = vm.parseJsonUint(ly, ".n_chal");
        sh.regionWidth = vm.parseJsonUint(st, ".region_width");
        sh.digestBytes = vm.keyExistsJson(ly, ".digest_bytes") ? vm.parseJsonUint(ly, ".digest_bytes") : 32;
        sh.finalAsCoefficients =
            vm.keyExistsJson(ly, ".final_layer_coefficients") && vm.parseJsonBool(ly, ".final_layer_coefficients");
        // An absent fri_radix means radix two.
        sh.friRadix = vm.keyExistsJson(ly, ".fri_radix") ? vm.parseJsonUint(ly, ".fri_radix") : 2;
        sh.format5 = _f5();
    }

    /// Format 5 artifacts say so in their layout. It orders the whole-proof walk FRI first.
    function _f5() internal view returns (bool) {
        return vm.keyExistsJson(ly, ".format5") && vm.parseJsonBool(ly, ".format5");
    }

    /// Piece index of base query q and of FRI query q, in walk order.
    function _base(V.Shape memory sh, uint256 q) internal view returns (uint256) {
        return _f5() ? sh.nq + q : q;
    }

    function _fri(V.Shape memory sh, uint256 q) internal view returns (uint256) {
        return _f5() ? q : sh.nq + q;
    }

    function _v() internal returns (RealSplitVerifier) {
        return new RealSplitVerifier(
            vm.parseJsonUint(st, ".outer_n_queries"),
            vm.parseJsonUint(st, ".log_domain"),
            vm.parseJsonUint(st, ".log_trace_len"),
            vm.parseJsonUint(st, ".trace_width"),
            vm.parseJsonUint(st, ".n_coeffs"),
            vm.parseJsonUint(st, ".grind_bits"),
            vm.parseJsonUint(st, ".coset_shift"),
            vm.parseJsonUint(ly, ".outer_n_periodic"),
            vm.parseJsonBytes32(ly, ".outer_periodic_root_keccak_at_deployment_rate"),
            false,
            RealSplitVerifier.Codec({
                nChal: vm.parseJsonUint(ly, ".n_chal"),
                regionWidth: vm.parseJsonUint(st, ".region_width"),
                finalAsCoefficients: vm.keyExistsJson(ly, ".final_layer_coefficients")
                    && vm.parseJsonBool(ly, ".final_layer_coefficients"),
                digestBytes: vm.keyExistsJson(ly, ".digest_bytes") ? vm.parseJsonUint(ly, ".digest_bytes") : 32,
                friRadix: vm.keyExistsJson(ly, ".fri_radix") ? vm.parseJsonUint(ly, ".fri_radix") : 2,
                logDegreeBound: vm.keyExistsJson(ly, ".final_layer_coefficients")
                    && vm.parseJsonBool(ly, ".final_layer_coefficients")
                    ? vm.parseJsonUint(st, ".log_domain") - vm.parseJsonUint(st, ".extra_blowup_bits") - 1
                    : 0,
                logFinal: vm.keyExistsJson(ly, ".fri_final_log") ? vm.parseJsonUint(ly, ".fri_final_log") : 0,
                format5: _f5(),
                extChallenges: vm.keyExistsJson(ly, ".ext_challenges") && vm.parseJsonBool(ly, ".ext_challenges"),
                powerCoeffs: EmitCodec.powerCoeffs(ly),
                powerDeep: EmitCodec.powerDeep(ly),
                roundGrindBits: EmitCodec.roundGrindBits(ly),
                finalSearches: EmitCodec.finalSearches(ly),
            maskColumn: 0
            })
        );
    }

    function _sub(uint256 a, uint256 b) internal view returns (bytes memory o) {
        o = new bytes(b - a);
        for (uint256 i = 0; i < o.length; ++i) o[i] = proof[a + i];
    }

    struct Parts {
        bytes head;
        bytes claims;
        bytes[] pieces;
        uint256[] pubs;
        uint256 c0;
        uint256 c1;
        address ev;
    }

    function _parts(V.Shape memory sh) internal returns (Parts memory p) {
        (uint256[] memory base, uint256[] memory rows, uint256[] memory perms, uint256[] memory fri, uint256 so,) =
            V.sectionsOf(proof, sh);

        p.head = bytes.concat(_sub(0, fri[0]), _sub(base[0] - 12, base[0]));
        p.claims = _sub(so, so + 4 + sh.nPeriodic * 16);

        p.pieces = new bytes[](2 * sh.nq);
        for (uint256 q = 0; q < sh.nq; ++q) {
            p.pieces[_base(sh, q)] =
                bytes.concat(_sub(base[q], base[q + 1]), _sub(rows[q], rows[q + 1]), _sub(perms[q], perms[q + 1]));
        }
        for (uint256 q = 0; q < sh.nq; ++q) p.pieces[_fri(sh, q)] = _sub(fri[q], fri[q + 1]);

        string memory cz = vm.readFile(string.concat(dir, "/compz.json"));
        p.c0 = vm.parseUint(vm.parseJsonString(cz, ".c0"));
        p.c1 = vm.parseUint(vm.parseJsonString(cz, ".c1"));
        p.pubs = abi.decode(vm.parseJson(vm.readFile(string.concat(dir, "/publics-array.json"))), (uint256[]));
        p.ev = address(new FixedEvaluator(p.c0, p.c1));
    }

    function _cd(Parts memory p, bytes memory q) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(RealSplitVerifier.verifyWholeComposed.selector, p.head, p.claims, q, p.pubs, p.ev);
    }

    /// Gas for the whole-proof call given only the first `k` pieces. It walks the `k` pieces in one
    /// frame, then reverts on the first read past the short section.
    function _upTo(Parts memory p, uint256 k) internal returns (uint256 used) {
        bytes memory q;
        for (uint256 i = 0; i < k; ++i) q = bytes.concat(q, p.pieces[i]);
        RealSplitVerifier v = _v();
        bytes memory cd = _cd(p, q);
        uint256 g = gasleft();
        (bool ok,) = address(v).staticcall(cd);
        used = g - gasleft();
        ok; // a short section is refused, the gas is the reading
    }

    function test_gasAgainstQueryCount() public {
        V.Shape memory sh = _shape();
        Parts memory p = _parts(sh);
        uint256 n = p.pieces.length;

        uint256 base = _upTo(p, 0);
        console2.log("pieces total        ", n);
        console2.log("head only, k=0      ", base);
        console2.log("--- k, gas, work, work per piece, second difference ---");

        uint256[9] memory ks = [uint256(1), 2, 4, 6, 8, 12, 16, 20, 24];
        uint256 prevWork;
        uint256 prevSlope;
        for (uint256 i = 0; i < ks.length; ++i) {
            uint256 k = ks[i];
            if (k > n) break;
            uint256 gk = _upTo(p, k);
            uint256 work = gk > base ? gk - base : 0;
            uint256 slope = work / k;
            console2.log(k, gk, work, slope);
            // A constant slope means linear cost, a slope growing with k means quadratic.
            if (i > 0) {
                console2.log("   slope growth x1000", prevSlope == 0 ? 0 : slope * 1000 / prevSlope);
            }
            prevWork = work;
            prevSlope = slope;
        }
        prevWork;
    }

    /// The whole emitted proof is accepted. Gas is read around the real call.
    function test_acceptsTheArtifact() public {
        V.Shape memory sh = _shape();
        Parts memory p = _parts(sh);
        bytes memory all;
        for (uint256 i = 0; i < p.pieces.length; ++i) all = bytes.concat(all, p.pieces[i]);
        RealSplitVerifier v = _v();
        uint256 g = gasleft();
        bool ok = v.verifyWholeComposed(p.head, p.claims, all, p.pubs, FixedEvaluator(p.ev));
        uint256 used = g - gasleft();
        console2.log("queries    ", sh.nq);
        console2.log("calldata   ", p.head.length + p.claims.length + all.length);
        console2.log("gas        ", used);
        console2.log("ACCEPTED   ", ok);
        assertTrue(ok, "the verifier must accept the shipped artifact");
    }

    /// Runs the whole-proof call on the pieces and reports whether it refused, with the revert selector.
    function _refuses(Parts memory p) internal returns (bool refused, bytes4 why) {
        bytes memory all;
        for (uint256 i = 0; i < p.pieces.length; ++i) all = bytes.concat(all, p.pieces[i]);
        RealSplitVerifier v = _v();
        (bool ok, bytes memory ret) = address(v).staticcall(_cd(p, all));
        if (ok && abi.decode(ret, (bool))) return (false, bytes4(0));
        return (true, ret.length >= 4 ? bytes4(ret) : bytes4(0));
    }

    function _flip(bytes memory b, uint256 at) internal pure {
        b[at] = bytes1(uint8(b[at]) ^ 1);
    }

    /// A flipped bit in the first FRI value of the first query is refused.
    function test_refusesATamperedFriValue() public {
        V.Shape memory sh = _shape();
        Parts memory p = _parts(sh);
        _flip(p.pieces[_fri(sh, 0)], 4);
        (bool refused, bytes4 why) = _refuses(p);
        console2.logBytes4(why);
        assertTrue(refused, "a changed FRI value must be refused");
    }

    /// A flipped bit in a FRI authentication path node is refused.
    function test_refusesATamperedFriPath() public {
        V.Shape memory sh = _shape();
        Parts memory p = _parts(sh);
        _flip(p.pieces[_fri(sh, 0)], 4 + 16 * 4 + 4);
        (bool refused, bytes4 why) = _refuses(p);
        console2.logBytes4(why);
        assertTrue(refused, "a changed FRI path node must be refused");
    }

    /// A flipped bit in the last query's last-layer value, checked against the final polynomial, is refused.
    function test_refusesATamperedLastLayer() public {
        V.Shape memory sh = _shape();
        Parts memory p = _parts(sh);
        _flip(p.pieces[_fri(sh, sh.nq - 1)], 4);
        (bool refused, bytes4 why) = _refuses(p);
        console2.logBytes4(why);
        assertTrue(refused, "a changed last-layer value must be refused");
    }

    /// A flipped bit in the grinding nonce, which opens the twelve bytes appended to the head, is refused.
    function test_refusesATamperedNonce() public {
        V.Shape memory sh = _shape();
        Parts memory p = _parts(sh);
        _flip(p.head, p.head.length - 12);
        (bool refused, bytes4 why) = _refuses(p);
        console2.logBytes4(why);
        assertTrue(refused, "a changed grinding nonce must be refused");
    }

    /// A flipped bit in the first cell of a base query's trace row is refused at its path.
    function test_refusesATamperedTraceCell() public {
        V.Shape memory sh = _shape();
        Parts memory p = _parts(sh);
        _flip(p.pieces[_base(sh, 0)], 4);
        (bool refused, bytes4 why) = _refuses(p);
        assertTrue(refused, "a changed trace cell must be refused");
        assertEq(why, V.TraceAuthFailed.selector);
    }

    /// A flipped bit in the last cell of the last base query's trace row, which sits in the
    /// half committed under the permutation root, is refused there.
    function test_refusesATamperedPermutationHalfCell() public {
        V.Shape memory sh = _shape();
        Parts memory p = _parts(sh);
        _flip(p.pieces[_base(sh, sh.nq - 1)], 4 + sh.traceWidth * 8 - 8);
        (bool refused, bytes4 why) = _refuses(p);
        assertTrue(refused, "a changed permutation-half cell must be refused");
        assertEq(why, V.CopyCommitMismatch.selector);
    }

    /// A flipped bit in a base query's composition value is refused at its path.
    function test_refusesATamperedCompositionValue() public {
        V.Shape memory sh = _shape();
        Parts memory p = _parts(sh);
        bytes memory b = p.pieces[_base(sh, 3)];
        uint256 at = 4 + sh.traceWidth * 8;
        // the path's u32 count is little-endian
        uint256 k = uint256(uint8(b[at])) | uint256(uint8(b[at + 1])) << 8 | uint256(uint8(b[at + 2])) << 16
            | uint256(uint8(b[at + 3])) << 24;
        _flip(b, at + 4 + k * sh.digestBytes);
        (bool refused, bytes4 why) = _refuses(p);
        assertTrue(refused, "a changed composition value must be refused");
        assertEq(why, V.CompAuthFailed.selector);
    }

    /// A coefficient-form verifier cannot be deployed without its degree bound.
    function test_refusesAnUnpinnedFriShape() public {
        vm.expectRevert(RealSplitVerifier.FriShapeUnpinned.selector);
        new RealSplitVerifier(
            vm.parseJsonUint(st, ".outer_n_queries"),
            vm.parseJsonUint(st, ".log_domain"),
            vm.parseJsonUint(st, ".log_trace_len"),
            vm.parseJsonUint(st, ".trace_width"),
            vm.parseJsonUint(st, ".n_coeffs"),
            vm.parseJsonUint(st, ".grind_bits"),
            vm.parseJsonUint(st, ".coset_shift"),
            vm.parseJsonUint(ly, ".outer_n_periodic"),
            vm.parseJsonBytes32(ly, ".outer_periodic_root_keccak_at_deployment_rate"),
            false,
            RealSplitVerifier.Codec({
                nChal: vm.parseJsonUint(ly, ".n_chal"),
                regionWidth: vm.parseJsonUint(st, ".region_width"),
                finalAsCoefficients: true,
                digestBytes: 24,
                friRadix: 4,
                logDegreeBound: 0,
                logFinal: 0,
                format5: true,
                extChallenges: false,
                powerCoeffs: EmitCodec.powerCoeffs(ly),
                powerDeep: EmitCodec.powerDeep(ly),
                roundGrindBits: EmitCodec.roundGrindBits(ly),
                finalSearches: EmitCodec.finalSearches(ly),
            maskColumn: 0
            })
        );
    }

    /// Verifies the format 3 proof from `EMIT3` in one external call, so any revert reads as refusal.
    function verifyFormatThree() external {
        string memory d3 = vm.envOr("EMIT3", string("spec/onetx-v3"));
        proof = vm.readFileBinary(string.concat(d3, "/settlement.proof"));
        dir = d3;
        V.Shape memory sh = _shape();
        Parts memory p = _parts(sh);
        bytes memory all;
        for (uint256 i = 0; i < p.pieces.length; ++i) all = bytes.concat(all, p.pieces[i]);
        require(_v().verifyWholeComposed(p.head, p.claims, all, p.pubs, FixedEvaluator(p.ev)), "refused");
    }

    /// A format 3 proof, made without the DEEP-to-FRI root tie, is refused.
    function test_refusesAFormatThreeProof() public {
        require(bytes(vm.envOr("EMIT3", string("spec/onetx-v3"))).length != 0, "EMIT3 must name the format 3 emit");
        try this.verifyFormatThree() {
            fail();
        } catch {}
    }

    /// Verifier execution gas alone: the full call minus a NullSink call with the same calldata.
    function test_verifierAloneAgainstTheSink() public {
        V.Shape memory sh = _shape();
        Parts memory p = _parts(sh);
        bytes memory all;
        for (uint256 i = 0; i < p.pieces.length; ++i) all = bytes.concat(all, p.pieces[i]);
        RealSplitVerifier v = _v();
        NullSink s = new NullSink();
        // encoded once, before any gas is read, so neither call is charged for building it
        bytes memory cd = _cd(p, all);
        uint256 g = gasleft();
        (bool okS,) = address(s).staticcall(cd);
        uint256 sink = g - gasleft();
        g = gasleft();
        (bool okV, bytes memory ret) = address(v).staticcall(cd);
        uint256 full = g - gasleft();
        assertTrue(okS && okV && abi.decode(ret, (bool)), "both calls succeed and the verifier accepts");
        console2.log("verifier call       ", full);
        console2.log("empty call, same cd ", sink);
        console2.log("VERIFIER ALONE      ", full - sink);
        console2.log("transaction total   ", 21000 + 1768940 + full);
    }
}
