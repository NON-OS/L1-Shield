// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @notice Transcript rules from the layout.json of an emit, each off when its key is absent.
library EmitCodec {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice `coeff_rule: "powers"`: the composition coefficients are the powers of one draw.
    function powerCoeffs(string memory ly) internal view returns (bool) {
        return _powers(ly, ".coeff_rule");
    }

    /// @notice `deep_rule: "powers"`: the DEEP coefficients are the powers of one further draw.
    function powerDeep(string memory ly) internal view returns (bool) {
        return _powers(ly, ".deep_rule");
    }

    function roundGrindBits(string memory ly) internal view returns (uint256) {
        return vm.keyExistsJson(ly, ".round_grind_bits") ? vm.parseJsonUint(ly, ".round_grind_bits") : 0;
    }

    function finalSearches(string memory ly) internal view returns (uint256) {
        return vm.keyExistsJson(ly, ".final_grind") ? vm.parseJsonUint(ly, ".final_grind.searches") : 0;
    }

    /// @notice Bits per query nonce: `final_grind.bits` for a split grind, else `grind_bits`.
    function grindBits(string memory st, string memory ly) internal view returns (uint256) {
        return vm.keyExistsJson(ly, ".final_grind")
            ? vm.parseJsonUint(ly, ".final_grind.bits")
            : vm.parseJsonUint(st, ".grind_bits");
    }

    function _powers(string memory ly, string memory key) private view returns (bool) {
        if (!vm.keyExistsJson(ly, key)) return false;
        bytes32 r = keccak256(bytes(vm.parseJsonString(ly, key)));
        if (r == keccak256("powers")) return true;
        require(r == keccak256("independent"), "layout.json names a coefficient rule this verifier does not know");
        return false;
    }

    /// @notice First mask column when the emit opens the pair as one Fp2 value, otherwise zero.
    function maskColumn(string memory st) internal view returns (uint256) {
        if (!vm.keyExistsJson(st, ".frame")) return 0;
        return vm.parseJsonUint(st, ".trace_width") - 2;
    }
}
