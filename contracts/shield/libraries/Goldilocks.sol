// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Goldilocks
/// @notice Canonicality checks for Goldilocks limbs and packed four-limb digests.
library Goldilocks {
    uint256 internal constant P = 0xFFFFFFFF00000001; // 2^64 - 2^32 + 1

    /// @dev The circuit's range bound on a value, fee or public amount, in asset units.
    uint256 internal constant MAX_VALUE = P - 2;

    function isCanonicalLimb(uint256 v) internal pure returns (bool) {
        return v < P;
    }

    function isCanonicalDigest(bytes32 digest) internal pure returns (bool ok) {
        uint256 v = uint256(digest);
        unchecked {
            ok = (v & 0xFFFFFFFFFFFFFFFF) < P && ((v >> 64) & 0xFFFFFFFFFFFFFFFF) < P
                && ((v >> 128) & 0xFFFFFFFFFFFFFFFF) < P && (v >> 192) < P;
        }
    }

    function limb(bytes32 digest, uint256 i) internal pure returns (uint256) {
        return (uint256(digest) >> (64 * i)) & 0xFFFFFFFFFFFFFFFF; // limb 0 is the low 64 bits
    }
}
