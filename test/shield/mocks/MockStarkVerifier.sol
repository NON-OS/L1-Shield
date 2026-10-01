// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStarkVerifier} from "../../../contracts/shield/interfaces/IStarkVerifier.sol";

/// @notice Test-only verifier stand-in that verifies nothing, for testing pool logic alone.
///         When set, `expectedInputsHash` requires the pool to forward public inputs verbatim.
contract MockStarkVerifier is IStarkVerifier {
    bool public result = true;
    bytes32 public expectedInputsHash;
    /// @notice The provable figure reported for every batch size unless one is set for that size.
    uint256 public provableBits = 80;
    mapping(uint256 intents => uint256 bits) public provableBitsFor;

    function setResult(bool result_) external {
        result = result_;
    }

    function setExpectedInputs(uint256[] calldata publicInputs) external {
        expectedInputsHash = keccak256(abi.encode(publicInputs));
    }

    function setProvableBits(uint256 bits) external {
        provableBits = bits;
    }

    function setProvableBitsForSize(uint256 intents, uint256 bits) external {
        provableBitsFor[intents] = bits;
    }

    function soundnessBits() external view returns (uint256, uint256) {
        return (provableBits, provableBits);
    }

    function soundnessBitsForSize(uint256 intents) external view returns (uint256, uint256) {
        uint256 b = provableBitsFor[intents];
        if (b == 0) b = provableBits;
        return (b, b);
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
