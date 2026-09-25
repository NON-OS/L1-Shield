// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

/// Pins the deployable surface: every file reachable from `RealSplitVerifier` by import.
/// A new import on that path fails here until it is added to the list with its reason.
contract DeployedSurfaceTest is Test {
    /// The deployable files, each with the reason it is reachable.
    function _deployable() internal pure returns (string[13] memory) {
        return [
            "RealSplitVerifier.sol", // the entry point
            "RealQueryVerify.sol", // the shape, both transcript walks, the memory decoder
            "RealQueryWalk.sol", // the head decoder and every per-query check, read from calldata
            "GoldilocksCore.sol", // Fp and Fp2 on bare words, for the walk
            "ProductionAir.sol", // the fri fold chase
            "ProductionComposeAir.sol", // the composition terms the chase needs
            "ProductionDeepQuery.sol", // the deep combination, with the periodic fold-in
            "StarkFieldExt.sol", // Fp and Fp2 arithmetic
            "StarkMerkle.sol", // leaf and path hashing for every authentication
            "StarkProofReader.sol", // the byte reader
            "StarkTranscript.sol", // both fiat-shamir transcripts
            "Goldilocks.sol", // the field modulus and canonicity bound, via the reader
            "IProgramFormEvaluator.sol" // the evaluator interface verifyWholeComposed calls
        ];
    }

    /// The verifier's import closure equals the declared list, no more and no less.
    function test_theDeployedVerifierReachesExactlyTheseContracts() public {
        string[13] memory want = _deployable();
        string[] memory found = _closure("contracts/shield/verifier/RealSplitVerifier.sol");

        for (uint256 i = 0; i < want.length; ++i) {
            assertTrue(_has(found, want[i]), string.concat("expected on the deployed path: ", want[i]));
        }
        for (uint256 i = 0; i < found.length; ++i) {
            bool expected;
            for (uint256 j = 0; j < want.length; ++j) {
                if (keccak256(bytes(found[i])) == keccak256(bytes(want[j]))) expected = true;
            }
            assertTrue(
                expected,
                string.concat(
                    "a contract reached the deployed path without being declared here: ",
                    found[i],
                    ". if that is intended, add it to _deployable and say why."
                )
            );
        }
    }

    /// The import closure of a Solidity file, read from source.
    function _closure(string memory entry) internal returns (string[] memory) {
        string[] memory cmd = new string[](3);
        cmd[0] = "python3";
        cmd[1] = "test/tools/import_closure.py";
        cmd[2] = entry;
        return vm.split(_trim(string(vm.ffi(cmd))), " ");
    }

    function _trim(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 end = b.length;
        while (end > 0 && (b[end - 1] == 0x0a || b[end - 1] == 0x20)) --end;
        bytes memory o = new bytes(end);
        for (uint256 i = 0; i < end; ++i) o[i] = b[i];
        return string(o);
    }

    function _has(string[] memory hay, string memory needle) internal pure returns (bool) {
        for (uint256 i = 0; i < hay.length; ++i) {
            if (keccak256(bytes(hay[i])) == keccak256(bytes(needle))) return true;
        }
        return false;
    }
}
