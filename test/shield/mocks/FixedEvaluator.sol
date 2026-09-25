// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProgramFormEvaluator} from "../../../contracts/shield/verifier/IProgramFormEvaluator.sol";

/// Answers a fixed comp_z, so the verifier's walk can be held to a real proof apart from the
/// evaluator.
contract FixedEvaluator is IProgramFormEvaluator {
    uint256 internal immutable a;
    uint256 internal immutable b;

    constructor(uint256 a_, uint256 b_) {
        a = a_;
        b = b_;
    }

    function evaluate(
        uint256[2][] calldata,
        uint256[2][] calldata,
        uint256[2][] calldata,
        uint256[] calldata,
        uint256[6] calldata
    ) external view returns (uint256, uint256) {
        return (a, b);
    }
}
