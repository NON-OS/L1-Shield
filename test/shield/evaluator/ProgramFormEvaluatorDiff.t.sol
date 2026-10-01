// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IProgramFormEvaluator} from "../../../contracts/shield/verifier/IProgramFormEvaluator.sol";
import {ProgramFormEvaluator, ProgramFormEvaluatorBase} from "../../../contracts/shield/verifier/ProgramFormEvaluator.sol";
import {ProgramFormAir, ProgramFormSlots} from "../../../contracts/shield/verifier/ProgramFormAir.sol";
import {ReferenceProgramFormEvaluator} from "../reference/evaluator/ReferenceProgramFormEvaluator.sol";
import {ReferenceProgramFormAir} from "../reference/evaluator/ReferenceProgramFormAir.sol";

/// The size of the current frame's memory, without msize (which the Yul optimizer refuses): one
/// load far past it is charged 3 gas plus the expansion from that size, a second load in the
/// already expanded region only the 3 plus the same overhead, and the expansion cost
/// 3 w + w^2 / 512 of w words is inverted for the size.
library MemoryProbe {
    uint256 internal constant FAR = 1 << 22;

    function top() internal view returns (uint256) {
        uint256 far = FAR;
        uint256 a;
        uint256 b;
        uint256 g0 = gasleft();
        assembly {
            a := mload(far)
        }
        uint256 g1 = gasleft();
        assembly {
            b := mload(sub(far, 0x20))
        }
        uint256 g2 = gasleft();
        uint256 expansion = (g0 - g1) - (g1 - g2) + a + b; // a and b are zero, kept so the loads stay
        uint256 w = (far + 0x20) / 0x20;
        uint256 before = 3 * w + (w * w) / 512 - expansion;
        uint256 lo = 0;
        uint256 hi = w;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (3 * mid + (mid * mid) / 512 <= before) lo = mid;
            else hi = mid - 1;
        }
        return lo * 0x20;
    }
}

/// The evaluator with the size of its memory once it is done, read in the same frame.
contract MeasuredEvaluator is ProgramFormEvaluator {
    constructor(bytes memory tape_) ProgramFormEvaluator(tape_) {}

    function measure(
        uint256[2][] calldata frame,
        uint256[2][] calldata periodic,
        uint256[2][] calldata coeffs,
        uint256[] calldata publics,
        uint256[6] calldata point
    ) external view returns (uint256 c0, uint256 c1, uint256 top) {
        (c0, c1) = _evaluate(frame, periodic, coeffs, publics, point);
        top = MemoryProbe.top();
    }
}

contract MeasuredReference is ReferenceProgramFormEvaluator {
    constructor(bytes memory tape_) ReferenceProgramFormEvaluator(tape_) {}

    function measure(
        uint256[2][] calldata frame,
        uint256[2][] calldata periodic,
        uint256[2][] calldata coeffs,
        uint256[] calldata publics,
        uint256[6] calldata point
    ) external view returns (uint256 c0, uint256 c1, uint256 top) {
        (c0, c1) = _evaluate(frame, periodic, coeffs, publics, point);
        top = MemoryProbe.top();
    }
}

/// Both generic compositions (blob in memory, inputs in memory) behind an external surface, so a
/// revert is data to compare.
contract TwoCompositions {
    function rewrite(
        bytes memory prog,
        uint256[] memory frame,
        uint256[] memory periodic,
        uint256[] memory alphas,
        uint256[] memory publics,
        uint256[6] memory point
    ) external pure returns (uint256, uint256) {
        return ProgramFormAir.composition(prog, frame, periodic, alphas, publics, point);
    }

    function reference_(
        bytes memory prog,
        uint256[] memory frame,
        uint256[] memory periodic,
        uint256[] memory alphas,
        uint256[] memory publics,
        uint256[6] memory point
    ) external pure returns (uint256, uint256) {
        return ReferenceProgramFormAir.composition(prog, frame, periodic, alphas, publics, point);
    }

    function compile(bytes memory prog, bytes memory slots, uint256 arena) external pure returns (bytes memory) {
        return ProgramFormAir.compile(prog, slots, arena);
    }
}

/// The Yul evaluator against the reference evaluator in test/shield/reference/evaluator: the same
/// bytes back, value or revert, on the prover's oracles and on fuzzed inputs, canonical and not.
contract ProgramFormEvaluatorDiffTest is Test {
    uint256 internal constant P = 0xFFFFFFFF00000001;
    uint256 internal constant N_FRAME = 82;
    uint256 internal constant N_PER = 119;
    uint256 internal constant N_ALPHA = 792;
    uint256 internal constant N_PUB = 32;
    uint256 internal constant LOG_T = 18;
    uint256 internal constant EIP170 = 24576;
    uint256 internal constant EIP3860 = 49152;

    MeasuredEvaluator internal neu;
    MeasuredReference internal ref;
    TwoCompositions internal two;
    bytes internal tape;
    uint256 internal g;

    struct In {
        uint256[2][] frame;
        uint256[2][] periodic;
        uint256[2][] coeffs;
        uint256[] publics;
        uint256[6] point;
    }

    function setUp() public {
        tape = vm.readFileBinary("spec/program-form/tape.bin");
        neu = new MeasuredEvaluator(tape);
        ref = new MeasuredReference(tape);
        two = new TwoCompositions();
        g = vm.parseJsonUint(vm.readFile("spec/f5-honest/oracle.json"), ".g");
    }

    // ------------------------------------------------------------------ inputs

    function _pairs(string memory o, string memory key) internal pure returns (uint256[2][] memory r) {
        uint256[][] memory a = abi.decode(vm.parseJson(o, key), (uint256[][]));
        r = new uint256[2][](a.length);
        for (uint256 i = 0; i < a.length; ++i) r[i] = [a[i][0], a[i][1]];
    }

    function _oracle(string memory dir) internal view returns (In memory x, uint256[] memory want) {
        string memory o = vm.readFile(string.concat(dir, "/oracle.json"));
        x.frame = _pairs(o, ".frame");
        x.periodic = _pairs(o, ".periodic_z");
        uint256[2][] memory ta = _pairs(o, ".transitions[*].alpha");
        uint256[2][] memory ba = _pairs(o, ".boundaries[*].alpha");
        x.coeffs = new uint256[2][](ta.length + ba.length);
        for (uint256 i = 0; i < ta.length; ++i) x.coeffs[i] = ta[i];
        for (uint256 j = 0; j < ba.length; ++j) x.coeffs[ta.length + j] = ba[j];
        x.publics = abi.decode(vm.parseJson(o, ".publics"), (uint256[]));
        uint256[] memory ch = abi.decode(vm.parseJson(o, ".challenges"), (uint256[]));
        uint256[] memory z = abi.decode(vm.parseJson(o, ".z"), (uint256[]));
        x.point = [ch[0], 0, ch[1], 0, z[0], z[1]];
        want = abi.decode(vm.parseJson(o, ".comp_z"), (uint256[]));
    }

    function _word(bytes32 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i))) % P;
    }

    /// Canonical random inputs of this circuit's shape, beta and gamma in Fp2.
    function _random(bytes32 seed) internal pure returns (In memory x) {
        uint256 n;
        x.frame = new uint256[2][](N_FRAME);
        for (uint256 i = 0; i < N_FRAME; ++i) x.frame[i] = [_word(seed, n++), _word(seed, n++)];
        x.periodic = new uint256[2][](N_PER);
        for (uint256 i = 0; i < N_PER; ++i) x.periodic[i] = [_word(seed, n++), _word(seed, n++)];
        x.coeffs = new uint256[2][](N_ALPHA);
        for (uint256 i = 0; i < N_ALPHA; ++i) x.coeffs[i] = [_word(seed, n++), _word(seed, n++)];
        x.publics = new uint256[](N_PUB);
        for (uint256 i = 0; i < N_PUB; ++i) x.publics[i] = _word(seed, n++);
        for (uint256 i = 0; i < 6; ++i) x.point[i] = _word(seed, n++);
    }

    /// A word at or above P: P itself, just past it, the top of the u64 range, the top of the
    /// word, or a random word with a high bit.
    function _nonCanonical(uint256 junk) internal pure returns (uint256) {
        uint256 k = junk % 5;
        if (k == 0) return P;
        if (k == 1) return P + 1 + (junk >> 8) % 0xFFFFFFFE;
        if (k == 2) return type(uint64).max;
        if (k == 3) return type(uint256).max;
        return (junk | (1 << 255));
    }

    function _call(address e, In memory x) internal view returns (bool ok, bytes memory ret, uint256 used) {
        bytes memory data = abi.encodeCall(IProgramFormEvaluator.evaluate, (x.frame, x.periodic, x.coeffs, x.publics, x.point));
        used = gasleft();
        (ok, ret) = e.staticcall(data);
        used -= gasleft();
    }

    function _same(In memory x) internal view returns (bool ok, uint256 gasNew, uint256 gasRef) {
        bytes memory a;
        bytes memory b;
        bool okB;
        (ok, a, gasNew) = _call(address(neu), x);
        (okB, b, gasRef) = _call(address(ref), x);
        assertEq(ok, okB, "one evaluator reverted and the other did not");
        assertEq(a, b, "the evaluators' return or revert bytes differ");
    }

    // ------------------------------------------------------------------ the oracles

    function _atOracle(string memory dir) internal view {
        (In memory x, uint256[] memory want) = _oracle(dir);
        (bool ok, uint256 gasNew, uint256 gasRef) = _same(x);
        assertTrue(ok, "the oracle's inputs were refused");
        (uint256 c0, uint256 c1, uint256 topNew) = neu.measure(x.frame, x.periodic, x.coeffs, x.publics, x.point);
        assertEq(c0, want[0], "comp_z c0");
        assertEq(c1, want[1], "comp_z c1");
        (,, uint256 topRef) = ref.measure(x.frame, x.periodic, x.coeffs, x.publics, x.point);
        console2.log("evaluate gas, rewrite  ", gasNew);
        console2.log("evaluate gas, reference", gasRef);
        console2.log("peak memory bytes, rewrite  ", topNew);
        console2.log("peak memory bytes, reference", topRef);
    }

    function test_honestOracle() public view {
        _atOracle("spec/f5-honest");
    }

    function test_spendOracle() public view {
        _atOracle("spec/f5-spend");
    }

    /// Every public word moves comp_z, the same way in both.
    function test_everyPublicWordIsRead() public view {
        (In memory x, uint256[] memory want) = _oracle("spec/f5-spend");
        for (uint256 k = 0; k < N_PUB; ++k) {
            x.publics[k] = (x.publics[k] + 1) % P;
            (bool ok, bytes memory a,) = _call(address(neu), x);
            (, bytes memory b,) = _call(address(ref), x);
            assertTrue(ok);
            assertEq(a, b, "the evaluators disagree after a public word moved");
            assertTrue(keccak256(a) != keccak256(abi.encode(want[0], want[1])), "a public word did not move comp_z");
            x.publics[k] = (x.publics[k] + P - 1) % P;
        }
    }

    // ------------------------------------------------------------------ fuzzed

    /// 10,000 fuzzed frames and points. Mode picks what is fuzzed: canonical inputs, coefficients
    /// at any word, a non-canonical frame, periodic, point or public word, z on the trace domain,
    /// on a boundary row or on the exempt point, a wrong length. Both give the same bytes back.
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_sameAsReference(bytes32 seed, uint8 mode, uint16 at, uint256 junk) public view {
        In memory x = _random(seed);
        uint256 m = mode % 12;
        if (m == 1) {
            // beta and gamma in the base field, c1 zero
            x.point[1] = 0;
            x.point[3] = 0;
        } else if (m == 2) {
            // coefficients meet only mulmod: any word is taken, the same way by both
            x.coeffs[at % N_ALPHA][junk % 2] = junk;
        } else if (m == 3) {
            x.frame[at % N_FRAME][junk % 2] = _nonCanonical(junk);
        } else if (m == 4) {
            x.periodic[at % N_PER][junk % 2] = _nonCanonical(junk);
        } else if (m == 5) {
            x.point[at % 6] = _nonCanonical(junk);
        } else if (m == 6) {
            x.publics[at % N_PUB] = _nonCanonical(junk);
        } else if (m == 7) {
            // z on the trace domain: z^t - 1 = 0
            x.point[4] = _pow(g, junk % (1 << LOG_T));
            x.point[5] = 0;
        } else if (m == 8) {
            // z on a boundary row: that row's z - g^row = 0
            uint256[4] memory rows = [uint256(0), 4882, 4883, 13433];
            x.point[4] = _pow(g, rows[junk % 4]);
            x.point[5] = 0;
        } else if (m == 9) {
            // z on the exempt point g^(t-1): E(z) = 0, the transitions drop out
            x.point[4] = _pow(g, (1 << LOG_T) - 1);
            x.point[5] = 0;
        } else if (m == 10) {
            x.coeffs = new uint256[2][](N_ALPHA - 1 + 2 * (junk % 2));
        } else if (m == 11) {
            uint256 n = at % 64;
            x.publics = new uint256[](n == N_PUB ? 0 : n);
        }
        (bool ok,,) = _same(x);
        if (m <= 2) assertTrue(ok, "canonical inputs were refused");
        if (m >= 3 && m <= 8 || m >= 10) assertFalse(ok, "an input the evaluator must refuse was taken");
    }

    function _pow(uint256 b, uint256 e) internal pure returns (uint256 r) {
        r = 1;
        while (e != 0) {
            if (e & 1 == 1) r = mulmod(r, b, P);
            b = mulmod(b, b, P);
            e >>= 1;
        }
    }

    // ------------------------------------------------------------------ small random programs

    /// Random blobs that use every instruction kind, inversions and a fused a b - x included, run
    /// by both generic compositions on the same random inputs.
    /// forge-config: default.fuzz.runs = 2000
    function testFuzz_randomProgramsMatch(bytes32 seed) public view {
        (bytes memory prog, uint256 nF, uint256 nP, uint256 nA, uint256 nPub) = _program(seed);
        uint256[] memory fr = _words(seed, 1, 2 * nF);
        uint256[] memory pz = _words(seed, 2, 2 * nP);
        uint256[] memory al = _words(seed, 3, 2 * nA);
        uint256[] memory pu = _words(seed, 4, nPub);
        uint256[6] memory pt;
        for (uint256 i = 0; i < 6; ++i) pt[i] = _word(keccak256(abi.encode(seed, 5)), i);
        (bool okA, bytes memory a) = address(two).staticcall(abi.encodeCall(TwoCompositions.rewrite, (prog, fr, pz, al, pu, pt)));
        (bool okB, bytes memory b) = address(two).staticcall(abi.encodeCall(TwoCompositions.reference_, (prog, fr, pz, al, pu, pt)));
        assertEq(okA, okB, "one composition reverted");
        assertEq(a, b, "the compositions differ");
    }

    function _words(bytes32 seed, uint256 tag, uint256 n) internal pure returns (uint256[] memory w) {
        w = new uint256[](n);
        bytes32 s = keccak256(abi.encode(seed, tag));
        for (uint256 i = 0; i < n; ++i) w[i] = _word(s, i);
    }

    /// A blob of 3 frame values, 2 periodic, 60 ops over them, 3 outputs, 4 boundaries on 3 rows.
    /// The ops mix every kind. A multiply read at once by an add or subtract is common, so all three
    /// fused kinds appear. An inversion reads a random earlier value, and a zero reverts in both.
    function _program(bytes32 seed)
        internal
        pure
        returns (bytes memory prog, uint256 nF, uint256 nP, uint256 nA, uint256 nPub)
    {
        nF = 3;
        nP = 2;
        uint256 nOps = 60;
        uint256 nOut = 3;
        uint256 nBnd = 4;
        nA = nOut + nBnd;
        nPub = 2;
        prog = abi.encodePacked(uint16(nOps), uint16(nOut), uint16(nBnd), uint16(3), uint16(nF), uint16(nP), uint8(3), uint8(1));
        prog = abi.encodePacked(prog, uint64(123456789));
        uint256 nIn = nF + nP + 2;
        for (uint256 i = 0; i < nOps; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, "op", i)));
            if (i < nIn) {
                prog = abi.encodePacked(prog, uint8(1), uint16(i));
            } else if (i == nIn) {
                prog = abi.encodePacked(prog, uint8(0), uint64(r % P), uint64((r >> 64) % P));
            } else {
                uint256 k = [uint256(2), 3, 4, 4, 4, 5, 2, 3][r % 8];
                uint256 a = (r >> 8) % i;
                uint256 b = (r >> 24) % i;
                // after a multiply, often read it at once, on either side
                if (i > nIn + 1 && (r >> 40) % 3 == 0) {
                    k = [uint256(2), 3, 3][(r >> 48) % 3];
                    if ((r >> 56) % 2 == 0) a = i - 1;
                    else b = i - 1;
                }
                if (k == 5) prog = abi.encodePacked(prog, uint8(5), uint16(a));
                else prog = abi.encodePacked(prog, uint8(k), uint16(a), uint16(b));
            }
        }
        prog = abi.encodePacked(prog, uint16(nOps - 1), uint16(nOps - 2), uint16(nOps / 2));
        prog = abi.encodePacked(prog, uint64(7), uint64(11), uint64(13));
        prog = abi.encodePacked(prog, uint8(0), uint16(1), uint8(0), uint64(5));
        prog = abi.encodePacked(prog, uint8(1), uint16(0), uint8(1), uint8(1));
        prog = abi.encodePacked(prog, uint8(2), uint16(1), uint8(1), uint8(0));
        prog = abi.encodePacked(prog, uint8(0), uint16(2), uint8(0), uint64(P - 1));
    }

    // ------------------------------------------------------------------ the compile

    /// The slots `gen_program_air.py` assigned are the ones the compile assigns by the same rule,
    /// and they take the fewest cells: the generator checks that count against the most values
    /// live at once.
    function test_generatorSlotsAreTheCompilesOwn() public view {
        bytes memory prog = vm.readFileBinary("spec/program-form/program.bin");
        bytes memory mine = two.compile(prog, "", 0x80);
        bytes memory theirs = two.compile(prog, ProgramFormSlots.SLOTS, 0x80);
        assertEq(keccak256(mine), keccak256(theirs), "the compile's slots are not the generator's");
        assertEq(ProgramFormSlots.SLOTS.length, 2592, "one slot byte per op");
        console2.log("slot cells", ProgramFormSlots.N_SLOTS);
        console2.log("image bytes", theirs.length);
    }

    /// A slot map that puts a value where a value still to be read lives is refused.
    function test_aClobberingSlotMapIsRefused() public {
        bytes memory prog = vm.readFileBinary("spec/program-form/program.bin");
        bytes memory map = bytes.concat(ProgramFormSlots.SLOTS);
        // the next value in another slot takes the first slotted value's cell
        uint256 first = type(uint256).max;
        for (uint256 i = 0; i < map.length; ++i) {
            if (uint8(map[i]) == 0xff) continue;
            if (first == type(uint256).max) {
                first = i;
            } else if (map[i] != map[first]) {
                map[i] = map[first];
                break;
            }
        }
        vm.expectRevert();
        two.compile(prog, map, 0x80);
    }

    function test_aForwardOperandIsRefused() public {
        bytes memory prog = abi.encodePacked(uint16(2), uint16(1), uint64(0), uint16(0));
        prog = abi.encodePacked(prog, uint8(2), uint16(1), uint16(0), uint8(1), uint16(0), uint16(0));
        vm.expectRevert(abi.encodeWithSelector(ProgramFormAir.BadOperand.selector, 0));
        two.compile(prog, "", 0x80);
    }

    function test_aNonCanonicalConstantIsRefused() public {
        bytes memory prog = abi.encodePacked(uint16(1), uint16(1), uint64(0), uint16(0));
        prog = abi.encodePacked(prog, uint8(0), uint64(P), uint64(0), uint16(0));
        vm.expectRevert(abi.encodeWithSelector(ProgramFormAir.ConstantNotCanonical.selector, 0));
        two.compile(prog, "", 0x80);
    }

    function test_aChangedTapeIsRefused() public {
        bytes memory t = bytes.concat(tape);
        t[100] ^= 0x01;
        vm.expectRevert(ProgramFormEvaluatorBase.TapeMismatch.selector);
        new ProgramFormEvaluator(t);
    }

    // ------------------------------------------------------------------ size

    /// The evaluator and each image contract within EIP-170, and its creation within EIP-3860.
    function test_withinTheCodeSizeLimits() public {
        ProgramFormEvaluator ev = new ProgramFormEvaluator(tape);
        (address a, uint256 lenA, address b, uint256 lenB) = ev.image();
        assertLe(address(ev).code.length, EIP170, "the evaluator is over EIP-170");
        assertLe(a.code.length, EIP170, "the first image contract is over EIP-170");
        assertLe(b.code.length, EIP170, "the second image contract is over EIP-170");
        assertEq(a.code.length, lenA + 1);
        assertEq(b.code.length, lenB == 0 ? 0 : lenB + 1);
        uint256 initcode = type(ProgramFormEvaluator).creationCode.length + abi.encode(tape).length;
        assertLe(initcode, EIP3860, "the evaluator's creation is over EIP-3860");
        console2.log("evaluator runtime bytes", address(ev).code.length);
        console2.log("evaluator initcode bytes", initcode);
        console2.log("image bytes", lenA + lenB);
    }
}
