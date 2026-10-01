// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProgramFormImage} from "../../contracts/shield/verifier/ProgramFormEvaluator.sol";
import {LaunchProgram as Prog, LaunchSlots as Slots} from "../../contracts/shield/verifier/LaunchProgram.sol";

/// The launch evaluator is deployed with an image compiled ahead of time. Its pin must be the
/// compile of the circuit's own tape, by the compiler the program-form evaluator runs at construction.
contract LaunchImageTest is Test {
    function test_thePinIsTheCompileOfTheTape() public view {
        bytes memory tape = vm.readFileBinary("spec/launch-program/tape.bin");
        bytes memory image = ProgramFormImage.compiled(
            tape, Prog.TAPE_HASH, Prog.TAPE_LENGTH, Prog.BOUNDARIES, Slots.TAPE_HASH, Slots.SLOTS, Prog.N_CHALLENGES
        );
        assertEq(keccak256(image), Prog.IMAGE_HASH, "the pin is not the compile");
        assertEq(keccak256(vm.readFileBinary("spec/launch-program/image.bin")), Prog.IMAGE_HASH, "image.bin");
        assertEq(
            keccak256(bytes.concat(tape, Prog.BOUNDARIES)),
            keccak256(vm.readFileBinary("spec/launch-program/program.bin")),
            "the tape and boundaries are not the program"
        );
        assertEq(Prog.PROGRAM_HASH, keccak256(vm.readFileBinary("spec/launch-program/program.bin")));
    }
}
