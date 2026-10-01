// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAssociationSetRegistry
/// @notice Append-only registry of association-set roots the pool accepts.
interface IAssociationSetRegistry {
    /// @notice True if `root` has been published. A registered root stays registered.
    function isRegisteredRoot(bytes32 root) external view returns (bool);
}
