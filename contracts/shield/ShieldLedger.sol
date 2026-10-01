// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ShieldLedger
/// @notice Pool fee and debit arithmetic, each check next to the subtraction it guards.
/// @dev Proven for all inputs in test/shield/halmos/ShieldLedger.halmos.t.sol.
library ShieldLedger {
    uint16 internal constant BPS = 10_000;

    function splitDeposit(uint256 amount, uint16 feeBps) internal pure returns (uint256 fee, uint256 value) {
        fee = (amount * feeBps) / BPS;
        value = amount - fee; // fee <= amount while feeBps <= BPS, and fee + value == amount
    }

    function splitUnshield(uint256 publicAmount, uint256 fee, uint16 maxFeeBps)
        internal
        pure
        returns (bool ok, uint256 toRecipient)
    {
        ok = fee * BPS <= publicAmount * maxFeeBps; // with maxFeeBps <= BPS this gives fee <= publicAmount
        toRecipient = ok ? publicAmount - fee : 0;
    }

    function debit(uint256 total, uint256 amount) internal pure returns (bool ok, uint256 left) {
        ok = total >= amount; // an over-debit is reported, the total never wraps
        left = ok ? total - amount : total;
    }
}
