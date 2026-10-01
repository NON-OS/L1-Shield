// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IStarkVerifier
/// @notice STARK/FRI batch verifier the pool pins by address. See docs/03-verifier-overview.md.
interface IStarkVerifier {
    /// @notice True only once the whole proof is checked against these public inputs.
    function verifyBatch(bytes calldata proof, uint256[] calldata publicInputs) external view returns (bool ok);
}
