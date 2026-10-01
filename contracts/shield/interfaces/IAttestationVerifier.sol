// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAttestationVerifier
/// @notice Optional attestation of a batch. It only sets the `attested` flag on BatchSettled.
interface IAttestationVerifier {
    /// @param batchCommitment keccak256(abi.encode(publicInputs)).
    function verifyAttestation(bytes32 batchCommitment, bytes calldata attestation) external view returns (bool);
}
