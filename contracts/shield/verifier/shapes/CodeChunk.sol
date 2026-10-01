// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Deploys its constructor argument as its own runtime code.
contract Chunk {
    constructor(bytes memory code) {
        assembly {
            return(add(code, 0x20), mload(code))
        }
    }
}
