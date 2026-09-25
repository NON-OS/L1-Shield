// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPoseidonGoldilocks
/// @notice Poseidon over Goldilocks. A digest packs four canonical 64-bit limbs, limb 0 lowest.
interface IPoseidonGoldilocks {
    /// @notice Merkle node hash.
    function hash2(bytes32 left, bytes32 right) external view returns (bytes32 digest);

    /// @notice Hashes four limbs. Reverts on any other length.
    function hashFields(uint256[] calldata limbs) external view returns (bytes32 digest);

    /// @notice Note commitment over the 11-limb note layout.
    function commitNote(uint256[11] calldata limbs) external view returns (bytes32 digest);
}
