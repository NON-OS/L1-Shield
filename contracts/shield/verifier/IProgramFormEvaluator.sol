// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Evaluates a circuit composition at z from values the replay of the verifier produced.
interface IProgramFormEvaluator {
    /// @notice comp_z at z from the verifier's replay: frame, periodic claims and coefficients as (c0, c1).
    /// @param publics the public words, one Goldilocks element each.
    /// @param point beta.c0, beta.c1, gamma.c0, gamma.c1, z.c0, z.c1. A base-field challenge has c1 zero.
    /// @return c0 comp_z, base component.
    /// @return c1 comp_z, extension component.
    function evaluate(
        uint256[2][] calldata frame,
        uint256[2][] calldata periodic,
        uint256[2][] calldata coeffs,
        uint256[] calldata publics,
        uint256[6] calldata point
    ) external view returns (uint256 c0, uint256 c1);
}
