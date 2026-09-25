// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test, console2} from "forge-std/Test.sol";
import {ProfAir, ProfSlots} from "./ProfAir.sol";
import {ProgramFormAir, ProgramFormSlots} from "../../../../contracts/shield/verifier/ProgramFormAir.sol";
contract C { 
  function a(bytes memory p, bytes memory s) external pure returns (bytes memory) { return ProfAir.compile(p, s, 0x80); }
  function b(bytes memory p, bytes memory s) external pure returns (bytes memory) { return ProgramFormAir.compile(p, s, 0x80); }
}
contract ProfTest is Test {
    function test_prof() public {
        C c = new C();
        bytes memory prog = vm.readFileBinary("spec/program-form/program.bin");
        uint256 g = gasleft();
        bytes memory x = c.a(prog, ProfSlots.SLOTS);
        console2.log("yul compile", g - gasleft()); g = gasleft();
        bytes memory y = c.b(prog, ProgramFormSlots.SLOTS);
        console2.log("sol compile", g - gasleft());
        assertEq(keccak256(x), keccak256(y), "map");
        assertEq(keccak256(c.a(prog, "")), keccak256(y), "own");
    }
}
