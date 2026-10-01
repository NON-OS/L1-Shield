// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {LaunchBase, LaunchReplay} from "./LaunchBase.sol";
import {RealQueryVerify as V} from "../../contracts/shield/verifier/RealQueryVerify.sol";
import {StarkTranscript as TS} from "../../contracts/shield/verifier/StarkTranscript.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";

/// The launch transcript rules against the package's vectors, draw for draw and nonce for nonce.
/// Each transcript-kat.json lists the prover's verifier operations in order, with the state after each:
/// new, the publics, the trace root, beta and gamma (tags 0x06, 0x07), the permutation root, alpha,
/// the composition root, z, the frame and claims, alpha', the seed (0x08). The FRI transcript follows:
/// new, the seed, per layer its root, nonce and fold challenge, the final layer, query nonces, positions.
/// Values come from the verifier's own walk (LaunchReplay). A rule is restated only to check a vector.
contract LaunchTranscriptTest is LaunchBase {
    uint256 internal constant P = 0xFFFFFFFF00000001;
    string[4] internal names = ["honest", "spend", "withdraw-a", "withdraw-b"];

    LaunchReplay internal rp;

    function setUp() public override {
        super.setUp();
        rp = new LaunchReplay();
    }

    // Event positions, from the counts the shape fixes.
    struct At {
        uint256 trace; // absorb of the trace root
        uint256 alpha; // alpha.c0, then alpha.c1
        uint256 z;
        uint256 checkpoint; // the last frame or claim absorb
        uint256 alpha2; // alpha'.c0
        uint256 seed;
        uint256 round0; // layer 0's root, then its nonce and its challenge's two draws
        uint256 finalEnd; // the last final-layer absorb
        uint256 nonces; // the first query nonce
        uint256 index; // the first query position
    }

    function _at(V.Shape memory sh, uint256 nPub, uint256 rounds, uint256 nFinal) internal pure returns (At memory t) {
        t.trace = 1 + nPub;
        t.alpha = t.trace + 6;
        t.z = t.alpha + 3;
        t.checkpoint = t.z + 1 + 2 * (2 * sh.traceWidth + sh.nPeriodic);
        t.alpha2 = t.checkpoint + 1;
        t.seed = t.alpha2 + 2;
        t.round0 = t.seed + 3;
        t.finalEnd = t.round0 + 4 * rounds - 1 + 2 * nFinal;
        t.nonces = t.finalEnd + 1;
        t.index = t.nonces + V.searchesOf(sh);
    }

    function _ev(string memory kat, uint256 i, string memory field) internal view returns (string memory) {
        return vm.parseJsonString(kat, string.concat(".events_list[", vm.toString(i), "].", field));
    }

    function _state(string memory kat, uint256 i) internal view returns (bytes32) {
        return vm.parseBytes32(string.concat("0x", _ev(kat, i, "state")));
    }

    // a draw's raw word, reduced as the transcript reduces it
    function _draw(string memory kat, uint256 i) internal view returns (uint256 w) {
        w = vm.parseUint(string.concat("0x", _ev(kat, i, "word")));
        if (w >= P) w -= P;
    }

    // a nonce as the vector writes it: eight bytes, little endian
    function _nonce(string memory kat, uint256 i) internal view returns (uint64 n) {
        bytes memory b = vm.parseBytes(string.concat("0x", _ev(kat, i, "data")));
        for (uint256 k = 0; k < 8; ++k) n |= uint64(uint8(b[k])) << uint64(8 * k);
    }

    function _op(string memory kat, uint256 i, string memory want) internal view {
        assertEq(_ev(kat, i, "op"), want, string.concat("event ", vm.toString(i)));
    }

    function _replay(uint256 i) internal returns (LaunchReplay.Out memory o, string memory kat, At memory t) {
        string memory dir = string.concat("spec/launch-", names[i]);
        Cut memory c = _cut(vm.readFileBinary(string.concat(dir, "/settlement.proof")));
        uint256[] memory limbs = abi.decode(vm.parseJson(vm.readFile(string.concat(dir, "/publics-array.json"))), (uint256[]));
        V.Shape memory sh = v.shape();
        o = rp.replay(sh, c.head, c.claims, limbs);
        kat = vm.readFile(string.concat(dir, "/transcript-kat.json"));
        uint256 nFinal = uint256(1) << vm.parseJsonUint(ly, ".fri_final_log");
        t = _at(sh, limbs.length, o.betas.length, nFinal);
    }

    /// beta and gamma, alpha and the first four composition coefficients, z, and the state the
    /// main transcript reaches once the frame and claims are in.
    function test_theMainTranscriptIsThePackages() public {
        for (uint256 i = 0; i < 4; ++i) {
            (LaunchReplay.Out memory o, string memory kat, At memory t) = _replay(i);
            _op(kat, t.trace, "absorb_digest");
            assertEq(o.ck.beta.c0, _draw(kat, t.trace + 1), "beta.c0");
            assertEq(o.ck.beta.c1, _draw(kat, t.trace + 2), "beta.c1");
            assertEq(o.ck.gamma.c0, _draw(kat, t.trace + 3), "gamma.c0");
            assertEq(o.ck.gamma.c1, _draw(kat, t.trace + 4), "gamma.c1");

            _op(kat, t.alpha, "challenge_fp2_c0");
            F.Fp2 memory alpha = F.Fp2(_draw(kat, t.alpha), _draw(kat, t.alpha + 1));
            _powersAre(o.coeffs, alpha, 4, "composition coefficient");
            assertEq(o.coeffs.length, v.nCoeffs(), "one coefficient per constraint");

            assertEq(o.ck.z.c0, _draw(kat, t.z), "z.c0");
            assertEq(o.ck.z.c1, _draw(kat, t.z + 1), "z.c1");
            _op(kat, t.checkpoint, "absorb_fp");
            assertEq(o.ck.state, _state(kat, t.checkpoint), "the state after the frame and claims");
        }
    }

    /// alpha' and the DEEP coefficients as its powers, in the frame, composition, claims order, and
    /// the seed handed to FRI.
    function test_theDeepCoefficientsAndSeedAreThePackages() public {
        for (uint256 i = 0; i < 4; ++i) {
            (LaunchReplay.Out memory o, string memory kat, At memory t) = _replay(i);
            _op(kat, t.alpha2, "challenge_fp2_c0");
            F.Fp2 memory a2 = F.Fp2(_draw(kat, t.alpha2), _draw(kat, t.alpha2 + 1));
            _powersAre(o.deep, a2, 4, "DEEP coefficient");
            assertEq(o.deep.length, V.nDeepCoeffs(v.shape()), "one DEEP coefficient per term");
            // the last one is alpha'^(n-1), so the power runs the whole length
            F.Fp2 memory last = F.Fp2(1, 0);
            for (uint256 k = 1; k < o.deep.length; ++k) last = _mul(last, a2);
            assertEq(o.deep[o.deep.length - 1].c0, last.c0, "the last DEEP coefficient");
            assertEq(o.deep[o.deep.length - 1].c1, last.c1, "the last DEEP coefficient");
            _op(kat, t.seed, "challenge_seed");
            assertEq(o.seed, _state(kat, t.seed), "seed");
        }
    }

    /// Per layer: the nonce read from the proof's nonce region is absorbed after that layer's root,
    /// and the fold challenge is drawn after it.
    function test_eachFoldNonceAndChallengeIsThePackages() public {
        for (uint256 i = 0; i < 4; ++i) {
            (LaunchReplay.Out memory o, string memory kat, At memory t) = _replay(i);
            assertEq(o.roundNonces.length, o.betas.length, "one nonce per layer");
            for (uint256 m = 0; m < o.betas.length; ++m) {
                uint256 e = t.round0 + 4 * m;
                _op(kat, e, "absorb_digest");
                _op(kat, e + 1, "absorb_nonce");
                assertEq(o.roundNonces[m], _nonce(kat, e + 1), "fold nonce");
                // twenty leading zero bits of the state the nonce leaves
                assertLt(_le64(_state(kat, e + 1)), uint256(1) << (64 - v.roundGrindBits()), "round grind");
                assertEq(o.betas[m].c0, _draw(kat, e + 2), "fold challenge c0");
                assertEq(o.betas[m].c1, _draw(kat, e + 3), "fold challenge c1");
            }
        }
    }

    /// The eight query nonces, each checked against the state the previous one left, and the
    /// positions drawn after the last.
    function test_theSplitGrindAndThePositionsAreThePackages() public {
        for (uint256 i = 0; i < 4; ++i) {
            (LaunchReplay.Out memory o, string memory kat, At memory t) = _replay(i);
            uint256 s = V.searchesOf(v.shape());
            assertEq(o.finalNonces.length, s, "eight query nonces");
            TS.T memory tr = TS.T(_state(kat, t.finalEnd));
            for (uint256 k = 0; k < s; ++k) {
                _op(kat, t.nonces + k, "absorb_nonce");
                assertEq(o.finalNonces[k], _nonce(kat, t.nonces + k), "query nonce");
                assertTrue(TS.verifyPow(tr, o.finalNonces[k], uint32(v.grindBits())), "each nonce meets its bits");
                assertEq(tr.state, _state(kat, t.nonces + k), "the state after each query nonce");
            }
            uint256 mask = (uint256(1) << v.logDomain()) - 1;
            for (uint256 q = 0; q < o.friIdx.length; ++q) {
                _op(kat, t.index + q, "challenge_index");
                assertEq(o.friIdx[q], vm.parseUint(string.concat("0x", _ev(kat, t.index + q, "word"))) & mask, "position");
            }
            assertEq(t.index + o.friIdx.length, vm.parseJsonUint(kat, ".events"), "no event is left over");
        }
    }

    /// grind-kat.json: the split grind from a stated head, restated with the verifier's rule.
    function test_theGrindVector() public view {
        string memory g = vm.readFile(string.concat(FORGED, "/grind-kat.json"));
        TS.T memory t = TS.init("NONOS-STARK-FRI-EXT");
        TS.absorbDigest(t, keccak256("NOX-GRIND-KAT"), 24);
        assertEq(t.state, vm.parseBytes32(string.concat("0x", vm.parseJsonString(g, ".head"))), "head");
        uint256 n = vm.parseJsonUint(g, ".chunks");
        uint32 bits = uint32(vm.parseJsonUint(g, ".bits_per_chunk"));
        assertEq(n, v.finalSearches(), "the vector's searches are the deployment's");
        assertEq(bits, v.grindBits(), "the vector's bits are the deployment's");
        for (uint256 k = 0; k < n; ++k) {
            string memory at = string.concat(".grinds[", vm.toString(k), "]");
            uint64 nonce = uint64(vm.parseJsonUint(g, string.concat(at, ".nonce")));
            assertTrue(TS.verifyPow(t, nonce, bits), "nonce");
            assertEq(t.state, vm.parseBytes32(string.concat("0x", vm.parseJsonString(g, string.concat(at, ".state_after")))));
        }
    }

    /// The chain is what makes the split cost the whole: a nonce that meets its bits against the
    /// head, but not against the state the previous nonce left, is refused.
    function test_aQueryNonceSearchedAheadIsRefused() public {
        (LaunchReplay.Out memory o,,) = _replay(0);
        bytes memory p = vm.readFileBinary("spec/launch-honest/settlement.proof");
        Cut memory c = _cut(p);
        // swap the first two query nonces: each meets 25 bits against some state, but not against
        // the state it is checked from
        uint256 at = c.head.length - 4 - V.nonceBytes(v.shape(), o.betas.length);
        bytes memory h = bytes.concat(c.head);
        for (uint256 k = 0; k < 8; ++k) (h[at + k], h[at + 8 + k]) = (h[at + 8 + k], h[at + k]);
        uint256[] memory limbs = abi.decode(vm.parseJson(vm.readFile("spec/launch-honest/publics-array.json")), (uint256[]));
        V.Shape memory sh = v.shape();
        vm.expectRevert(abi.encodeWithSelector(V.FinalGrindRejected.selector, 0));
        rp.replay(sh, h, c.claims, limbs);
    }

    /// A fold nonce missing its bound is refused before its challenge is drawn.
    function test_aFoldNonceUnderItsBoundIsRefused() public {
        (LaunchReplay.Out memory o,,) = _replay(0);
        Cut memory c = _cut(vm.readFileBinary("spec/launch-honest/settlement.proof"));
        uint256 region = V.nonceBytes(v.shape(), o.betas.length);
        uint256 foldAt = c.head.length - 4 - region + 8 * V.searchesOf(v.shape());
        uint256[] memory limbs = abi.decode(vm.parseJson(vm.readFile("spec/launch-honest/publics-array.json")), (uint256[]));
        V.Shape memory sh = v.shape();
        for (uint256 m = 0; m < o.betas.length; ++m) {
            bytes memory h = bytes.concat(c.head);
            h[foldAt + 8 * m] ^= 0x01;
            vm.expectRevert(abi.encodeWithSelector(TS.RoundGrindRejected.selector, m));
            rp.replay(sh, h, c.claims, limbs);
        }
    }

    // ------------------------------------------------------------------------------ helpers

    function _powersAre(F.Fp2[] memory got, F.Fp2 memory a, uint256 n, string memory what) internal pure {
        F.Fp2 memory x = F.Fp2(1, 0);
        for (uint256 k = 0; k < n; ++k) {
            assertEq(got[k].c0, x.c0, what);
            assertEq(got[k].c1, x.c1, what);
            x = _mul(x, a);
        }
    }

    // Fp2 with X^2 = 7, written out here so the check does not lean on the verifier's arithmetic
    function _mul(F.Fp2 memory x, F.Fp2 memory y) internal pure returns (F.Fp2 memory) {
        return F.Fp2(
            addmod(mulmod(x.c0, y.c0, P), mulmod(7, mulmod(x.c1, y.c1, P), P), P),
            addmod(mulmod(x.c0, y.c1, P), mulmod(x.c1, y.c0, P), P)
        );
    }

    function _le64(bytes32 s) internal pure returns (uint256 w) {
        for (uint256 k = 0; k < 8; ++k) w |= uint256(uint8(s[k])) << (8 * k);
    }
}
