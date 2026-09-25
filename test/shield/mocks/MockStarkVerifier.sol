// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStarkVerifier} from "../../../contracts/shield/interfaces/IStarkVerifier.sol";

/// @notice Test-only verifier stand-in that verifies nothing, for testing pool logic alone.
///         When set, `expectedInputsHash` requires the pool to forward public inputs verbatim.
contract MockStarkVerifier is IStarkVerifier {
    bool public result = true;
    bytes32 public expectedInputsHash;

    function setResult(bool result_) external {
        result = result_;
    }

    function setExpectedInputs(uint256[] calldata publicInputs) external {
        expectedInputsHash = keccak256(abi.encode(publicInputs));
    }

    function clearExpectedInputs() external {
        expectedInputsHash = bytes32(0);
    }

    function verifyBatch(bytes calldata, uint256[] calldata publicInputs) external view returns (bool) {
        if (expectedInputsHash != bytes32(0) && keccak256(abi.encode(publicInputs)) != expectedInputsHash) {
            return false;
        }
        return result;
    }
}
