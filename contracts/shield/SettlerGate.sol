// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SettlerGate
/// @notice The settler has priority for `window` seconds after each settlement, then anyone may settle.
///         Anyone may also settle in the last `slot` seconds of every `epoch`, however often the
///         settler acts, so no intent can be kept out for longer than one epoch.
library SettlerGate {
    function open(address settler, address caller, uint256 lastSettlement, uint256 nowTs, uint256 window)
        internal
        pure
        returns (bool)
    {
        if (settler == address(0)) return true;
        if (caller == settler) return true;
        return nowTs >= lastSettlement + window;
    }

    /// @notice True in the last `slot` seconds of every `epoch`, counted from timestamp zero.
    function inOpenSlot(uint256 nowTs, uint256 epoch, uint256 slot) internal pure returns (bool) {
        return nowTs % epoch >= epoch - slot;
    }
}
