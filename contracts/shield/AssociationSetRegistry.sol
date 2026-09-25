// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Goldilocks} from "./libraries/Goldilocks.sol";
import {IAssociationSetRegistry} from "./interfaces/IAssociationSetRegistry.sol";

/// @title AssociationSetRegistry
/// @notice Permissionless, append-only registry of association-set roots. See docs/02-threat-model.md.
contract AssociationSetRegistry is IAssociationSetRegistry {
    uint256 public setCount; // also the next set id

    mapping(bytes32 root => bool registered) public isRegisteredRoot;

    mapping(uint256 setId => bytes32 root) public rootOf;

    event AssociationSetPublished(uint256 indexed setId, bytes32 indexed root, address indexed publisher, string uri);

    error NonCanonicalRoot();
    error EmptyRoot();

    function publishRoot(bytes32 root, string calldata uri) external returns (uint256 setId) {
        if (root == bytes32(0)) revert EmptyRoot();
        if (!Goldilocks.isCanonicalDigest(root)) revert NonCanonicalRoot();

        setId = setCount;
        unchecked { // one per call, cannot reach 2^256
            setCount = setId + 1;
        }
        rootOf[setId] = root;
        isRegisteredRoot[root] = true;

        emit AssociationSetPublished(setId, root, msg.sender, uri);
    }
}
