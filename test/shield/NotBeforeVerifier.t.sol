// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IProgramFormEvaluator} from "../../contracts/shield/verifier/IProgramFormEvaluator.sol";
import {Chunk} from "../../contracts/shield/verifier/shapes/CodeChunk.sol";
import {ComposedStarkVerifierShapes, IShapeWalk} from "../../contracts/shield/verifier/shapes/ComposedStarkVerifierShapes.sol";
import {NbStraightEvaluatorAt} from "../../contracts/shield/verifier/nb/NbStraightEvaluatorAt.sol";
import {PrepareNb_A} from "../../contracts/shield/verifier/nb/PrepareNb_A.sol";
import {PrepareNb_Ap} from "../../contracts/shield/verifier/nb/PrepareNb_Ap.sol";
import {PrepareNb_B} from "../../contracts/shield/verifier/nb/PrepareNb_B.sol";
import {WalkNb_A} from "../../contracts/shield/verifier/nb/WalkNb_A.sol";
import {WalkNb_Ap} from "../../contracts/shield/verifier/nb/WalkNb_Ap.sol";
import {WalkNb_B} from "../../contracts/shield/verifier/nb/WalkNb_B.sol";
import {SplitFormat7} from "../../script/shield/SplitFormat7.sol";

/// @notice The not-before circuit's verifier stack, through the adapter the pool calls, on the five
///         pinned proofs of spec/not-before as 13-word statements: all accepted, and refused when word 12
///         (the not-before time) moves one grid step either way or goes to zero, when the statement is
///         cut back to 12 words.
contract NotBeforeVerifierTest is Test {
    uint256 internal constant WORDS = 13;
    uint256 internal constant N_PERIODIC = 59;
    bytes32 internal constant IMAGE = 0x4364151e9f54797f3bbf9c8d28465f5a7dcf8ca1aafa9c9b48eb43cedf4e2429;

    ComposedStarkVerifierShapes internal adapter;
    bytes32[3] internal pid = [
        bytes32(0xccba76ed5748b5ee54dfd62935fd1d10998b5c0f84e35a9dc899905cfb1eadb5),
        bytes32(0x9a15f4ba74bab7fb97df9245b02c80a1f6a2aff41471c3d26483a6248f8b7acf),
        bytes32(0x4ef4256faa865857cce2cf3ea7c54cd4617dfc9dbb3d158393da9f02446a3350)
    ];

    function setUp() public {
        address[] memory at = new address[](3);
        for (uint256 k = 0; k < 3; ++k) {
            string memory f = string.concat("spec/not-before/chunk", vm.toString(k), ".hex");
            at[k] = address(new Chunk(vm.parseBytes(string.concat("0x", vm.readFile(f)))));
        }
        NbStraightEvaluatorAt ev = new NbStraightEvaluatorAt(at);
        address[3] memory pr = [address(new PrepareNb_A()), address(new PrepareNb_Ap()), address(new PrepareNb_B())];
        address[3] memory w = [
            address(new WalkNb_A(PrepareNb_A(pr[0]))),
            address(new WalkNb_Ap(PrepareNb_Ap(pr[1]))),
            address(new WalkNb_B(PrepareNb_B(pr[2])))
        ];
        ComposedStarkVerifierShapes.Shape[] memory s = new ComposedStarkVerifierShapes.Shape[](3);
        uint256[] memory ids = new uint256[](3);
        bytes32[] memory pids = new bytes32[](3);
        uint16[3] memory q = [uint16(19), 18, 17];
        uint16[3] memory b = [uint16(25), 28, 30];
        for (uint256 i = 0; i < 3; ++i) {
            s[i] = ComposedStarkVerifierShapes.Shape(IShapeWalk(w[i]), q[i], b[i], 8);
            ids[i] = i + 1;
            pids[i] = pid[i];
        }
        bytes32[] memory code = new bytes32[](10);
        code[0] = address(ev).codehash;
        for (uint256 k = 0; k < 3; ++k) {
            code[1 + k] = at[k].codehash;
        }
        for (uint256 i = 0; i < 3; ++i) {
            code[4 + 2 * i] = pr[i].codehash;
            code[5 + 2 * i] = w[i].codehash;
        }
        adapter = new ComposedStarkVerifierShapes(IProgramFormEvaluator(address(ev)), WORDS, address(0), ids, pids, s, IMAGE, code);
    }

    function _load(string memory name, uint256 nq) internal view returns (bytes memory whole, uint256[] memory words) {
        string memory d = string.concat("spec/not-before/", name);
        bool ok;
        (ok, whole) = SplitFormat7.whole(vm.readFileBinary(string.concat(d, "/proof.bin")), nq, N_PERIODIC);
        require(ok, "the proof does not cut");
        words = _words(vm.parseJsonUintArray(vm.readFile(string.concat(d, "/publics.json")), ".publics"));
    }

    // 37 limbs to 13 words: digests four 64-bit limbs low first, words 6 to 9 and 12 one limb each,
    // the recipient and fee recipient 48 + 48 + 48 + 16 bits.
    function _words(uint256[] memory L) internal pure returns (uint256[] memory w) {
        require(L.length == 37, "a statement is 37 limbs");
        w = new uint256[](WORDS);
        uint256[13] memory at = [uint256(0), 4, 8, 12, 16, 20, 24, 25, 26, 27, 28, 32, 36];
        for (uint256 i = 0; i < WORDS; ++i) {
            if ((i >= 6 && i <= 9) || i == 12) w[i] = L[at[i]];
            else if (i >= 10) for (uint256 l = 0; l < 4; ++l) w[i] |= L[at[i] + l] << (48 * l);
            else for (uint256 l = 0; l < 4; ++l) w[i] |= L[at[i] + l] << (64 * l);
        }
    }

    /// @dev A refusal is a false or a revert: a changed statement changes the transcript, and the walk
    ///      reverts on the first grind it no longer meets. The pool refuses the settlement either way.
    function _accepts(bytes memory whole, uint256[] memory words) internal view returns (bool) {
        try adapter.verifyBatch(whole, words) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }

    function _check(string memory name, uint256 nq) internal view {
        (bytes memory whole, uint256[] memory words) = _load(name, nq);
        assertTrue(_accepts(whole, words), string.concat(name, " is refused"));

        uint256 t = words[12];
        words[12] = t + 600;
        assertFalse(_accepts(whole, words), "accepted a time one step later");
        words[12] = t - 600;
        assertFalse(_accepts(whole, words), "accepted a time one step earlier");
        words[12] = 0;
        assertFalse(_accepts(whole, words), "accepted a zero time");
        words[12] = t;

        uint256[] memory cut = new uint256[](12);
        for (uint256 i = 0; i < 12; ++i) {
            cut[i] = words[i];
        }
        assertFalse(_accepts(whole, cut), "accepted a 12-word statement");
    }

    function test_shapeA() public view {
        _check("transfer-eth-shape1", 19);
    }

    function test_shapeAp() public view {
        _check("transfer-eth-shape2", 18);
    }

    function test_shapeB() public view {
        _check("transfer-eth-shape3", 17);
    }

    function test_withdrawFlat() public view {
        _check("withdraw-flat-shape1", 19);
    }

    function test_withdrawLive() public view {
        _check("withdraw-live-shape1", 19);
    }

    function test_imageAndWidth() public view {
        assertEq(adapter.imageHash(), IMAGE);
        assertEq(adapter.wordsPerIntent(), WORDS);
        assertEq(adapter.shapeCount(), 3);
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(adapter.shapeOfParams(pid[i]), i + 1);
        }
    }
}
