// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title INoxShieldStaking
/// @notice Receives protocol fees from ShieldFeeRouter for NOX stakers.
interface INoxShieldStaking {
    /// @notice Pulls `amount` NOX from the notifier and credits it to stakers pro rata.
    function notifyRewardAmount(uint256 amount) external;
}
