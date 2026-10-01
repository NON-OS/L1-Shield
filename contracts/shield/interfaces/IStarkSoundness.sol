// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IStarkSoundness
/// @notice Soundness figures an adapter publishes, in whole bits. The pool reads the provable one.
/// @dev The provable figure is the minimum over every challenge round, analysed round by round,
///      including the round that draws the DEEP coefficients and each fold as the curve its
///      challenge powers form. A query-phase figure alone is not it. It rests on the established
///      proximity gaps (BCIKS20), not on the 2025 preprint, and charges the worst-case loss of a
///      challenge drawn by reduction mod p rather than by rejection.
interface IStarkSoundness {
    /// @notice The weakest batch size served, with and without the FRI conjecture.
    function soundnessBits() external view returns (uint256 conjectured, uint256 provable);

    /// @notice One batch size, with and without the FRI conjecture. Reverts for a size not served.
    function soundnessBitsForSize(uint256 intents) external view returns (uint256 conjectured, uint256 provable);
}
