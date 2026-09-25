// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoseidonGoldilocks} from "../../../contracts/shield/interfaces/IPoseidonGoldilocks.sol";
import {Goldilocks} from "../../../contracts/shield/libraries/Goldilocks.sol";

/// @notice Keccak-based stand-in for the Poseidon-Goldilocks precompile. Outputs are
///         canonical 4-limb digests and non-canonical input limbs revert, as in the precompile.
contract MockPoseidonGoldilocks is IPoseidonGoldilocks {
    error NonCanonicalInput();

    function hash2(bytes32 left, bytes32 right) external pure returns (bytes32) {
        if (!Goldilocks.isCanonicalDigest(left) || !Goldilocks.isCanonicalDigest(right)) revert NonCanonicalInput();
        return _canon(keccak256(abi.encodePacked("nox.h2", left, right)));
    }

    function hashFields(uint256[] calldata limbs) external pure returns (bytes32) {
        for (uint256 i = 0; i < limbs.length; ++i) {
            if (!Goldilocks.isCanonicalLimb(limbs[i])) revert NonCanonicalInput();
        }
        return _canon(keccak256(abi.encodePacked("nox.hf", limbs)));
    }

    function commitNote(uint256[11] calldata limbs) external pure returns (bytes32) {
        for (uint256 i = 0; i < 11; ++i) {
            if (!Goldilocks.isCanonicalLimb(limbs[i])) revert NonCanonicalInput();
        }
        return _canon(keccak256(abi.encodePacked("nox.cm", limbs)));
    }

    /// @dev Reduces each 64-bit limb of `h` mod p so the digest is canonical.
    function _canon(bytes32 h) internal pure returns (bytes32 out) {
        uint256 v = uint256(h);
        uint256 acc;
        for (uint256 i = 0; i < 4; ++i) {
            acc |= (((v >> (64 * i)) & 0xFFFFFFFFFFFFFFFF) % Goldilocks.P) << (64 * i);
        }
        out = bytes32(acc);
    }
}
