// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @notice Accepts every call with the verifier's signature and does nothing. Measuring a call
///         against it isolates the cost of calldata and ABI decoding from verification.
contract NullSink {
    function verifyWholeComposed(bytes calldata, bytes calldata, bytes calldata, uint256[] calldata, address)
        external
        pure
        returns (bool)
    {
        return true;
    }
}
