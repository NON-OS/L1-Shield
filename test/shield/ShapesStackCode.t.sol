// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IProgramFormEvaluator} from "../../contracts/shield/verifier/IProgramFormEvaluator.sol";
import {Chunk} from "../../contracts/shield/verifier/shapes/CodeChunk.sol";
import {ShapesStraightEvaluatorAt} from "../../contracts/shield/verifier/shapes/ShapesStraightEvaluatorAt.sol";
import {ComposedStarkVerifierShapes, IShapeWalk} from "../../contracts/shield/verifier/shapes/ComposedStarkVerifierShapes.sol";
import {PrepareShapes_A} from "../../contracts/shield/verifier/shapes/PrepareShapes_A.sol";
import {PrepareShapes_Ap} from "../../contracts/shield/verifier/shapes/PrepareShapes_Ap.sol";
import {PrepareShapes_B} from "../../contracts/shield/verifier/shapes/PrepareShapes_B.sol";
import {WalkShapes_A} from "../../contracts/shield/verifier/shapes/WalkShapes_A.sol";
import {WalkShapes_Ap} from "../../contracts/shield/verifier/shapes/WalkShapes_Ap.sol";
import {WalkShapes_B} from "../../contracts/shield/verifier/shapes/WalkShapes_B.sol";

/// @notice The three-shape adapter binds its stack to the code the deployment names: the evaluator,
///         its chunks, and each shape's prepare and walk. Any other code hash is refused at
///         construction, and `stack()` returns the image hash and every address and code hash.
contract ShapesStackCodeTest is Test {
    bytes32 internal constant IMAGE = 0x72f4ccfc972a6dfd9e032031a725936e0337860bc2bebf32b137e165f71b2765;

    address internal ev;
    address[] internal chunks;
    address[3] internal pr;
    address[3] internal w;
    bytes32[] internal params;

    function setUp() public {
        for (uint256 k = 0; k < 3; ++k) {
            string memory f = string.concat("spec/shapes/chunk", vm.toString(k), ".hex");
            chunks.push(address(new Chunk(vm.parseBytes(string.concat("0x", vm.readFile(f))))));
        }
        ev = address(new ShapesStraightEvaluatorAt(chunks));
        pr[0] = address(new PrepareShapes_A());
        pr[1] = address(new PrepareShapes_Ap());
        pr[2] = address(new PrepareShapes_B());
        w[0] = address(new WalkShapes_A(PrepareShapes_A(pr[0])));
        w[1] = address(new WalkShapes_Ap(PrepareShapes_Ap(pr[1])));
        w[2] = address(new WalkShapes_B(PrepareShapes_B(pr[2])));
        string memory pj = vm.readFile("spec/shapes/params.json");
        params.push(vm.parseJsonBytes32(pj, ".A"));
        params.push(vm.parseJsonBytes32(pj, ".Ap"));
        params.push(vm.parseJsonBytes32(pj, ".B"));
    }

    function _actual() internal view returns (bytes32[] memory h) {
        h = new bytes32[](10);
        h[0] = ev.codehash;
        for (uint256 k = 0; k < 3; ++k) {
            h[1 + k] = chunks[k].codehash;
        }
        for (uint256 i = 0; i < 3; ++i) {
            h[4 + 2 * i] = pr[i].codehash;
            h[5 + 2 * i] = w[i].codehash;
        }
    }

    function _deploy(bytes32 image, bytes32[] memory code) internal returns (ComposedStarkVerifierShapes) {
        ComposedStarkVerifierShapes.Shape[] memory s = new ComposedStarkVerifierShapes.Shape[](3);
        uint256[] memory ids = new uint256[](3);
        uint16[3] memory q = [uint16(19), 18, 17];
        uint16[3] memory b = [uint16(25), 28, 30];
        for (uint256 i = 0; i < 3; ++i) {
            s[i] = ComposedStarkVerifierShapes.Shape(IShapeWalk(w[i]), q[i], b[i], 8);
            ids[i] = i + 1;
        }
        return new ComposedStarkVerifierShapes(IProgramFormEvaluator(ev), 12, address(0), ids, params, s, image, code);
    }

    function test_theStackIsReadableInOneCall() public {
        bytes32[] memory h = _actual();
        ComposedStarkVerifierShapes a = _deploy(IMAGE, h);
        (bytes32 image, address[] memory at, bytes32[] memory code) = a.stack();
        assertEq(image, IMAGE);
        assertEq(a.imageHash(), IMAGE);
        assertEq(at.length, 10);
        assertEq(at[0], ev);
        assertEq(at[1], chunks[0]);
        assertEq(at[4], pr[0]);
        assertEq(at[9], w[2]);
        for (uint256 i = 0; i < 10; ++i) {
            assertEq(code[i], h[i]);
            assertEq(at[i].codehash, h[i]);
        }
    }

    function test_anyOtherCodeHashIsRefused() public {
        for (uint256 i = 0; i < 10; ++i) {
            bytes32[] memory h = _actual();
            bytes32 actual = h[i];
            h[i] = bytes32(uint256(h[i]) ^ 1);
            address at = i == 0 ? ev : i < 4 ? chunks[i - 1] : i % 2 == 0 ? pr[(i - 4) / 2] : w[(i - 5) / 2];
            vm.expectRevert(
                abi.encodeWithSelector(ComposedStarkVerifierShapes.CodeMismatch.selector, i, at, h[i], actual)
            );
            this.deployExternal(IMAGE, h);
        }
    }

    function test_aShortOrLongListIsRefused() public {
        bytes32[] memory h = _actual();
        bytes32[] memory shorter = new bytes32[](9);
        for (uint256 i = 0; i < 9; ++i) {
            shorter[i] = h[i];
        }
        vm.expectRevert(ComposedStarkVerifierShapes.BadConstruction.selector);
        this.deployExternal(IMAGE, shorter);
        bytes32[] memory longer = new bytes32[](11);
        for (uint256 i = 0; i < 10; ++i) {
            longer[i] = h[i];
        }
        vm.expectRevert(ComposedStarkVerifierShapes.BadConstruction.selector);
        this.deployExternal(IMAGE, longer);
    }

    function test_aZeroImageHashIsRefused() public {
        bytes32[] memory h = _actual();
        vm.expectRevert(ComposedStarkVerifierShapes.BadConstruction.selector);
        this.deployExternal(bytes32(0), h);
    }

    function deployExternal(bytes32 image, bytes32[] memory code) external returns (address) {
        return address(_deploy(image, code));
    }
}
