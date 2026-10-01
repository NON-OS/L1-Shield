// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test-only stand-in with the parameter getters of a verifier at the format 7 point, for the
///         adapter's soundness figures. It verifies nothing. The format 7 walk (format 6, radix 8,
///         independent DEEP coefficients, exact challenge draws) is not in this repository yet.
contract ShapesPointVerifier {
    uint256 public nq = 17; // at rate 1/64
    uint256 public grindBits = 33; // one query nonce
    uint256 public finalSearches = 1;
    uint256 public logDomain = 23;
    uint256 public roundGrindBits = 21; // before each radix-8 fold challenge
    uint256 public friRadix = 8;
    bool public powerDeep = false; // independent DEEP coefficients
    uint256 public deepGrindBits = 19; // before the DEEP draw
    bool public exactChallenges = true; // a lane is accepted only below p
    uint256 public traceWidth = 44;
    uint256 public nPeriodic = 93;
    bytes32 public periodicRoot = keccak256("format 7 point");

    function set(uint256 roundGrind, uint256 deepGrind, bool exact, uint256 radix) external {
        roundGrindBits = roundGrind;
        deepGrindBits = deepGrind;
        exactChallenges = exact;
        friRadix = radix;
    }
}
