// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AmountPolicy} from "../../contracts/shield/AmountPolicy.sol";

/// @notice The fee schedule of the production pool, and the Safe calldata that sets it.
/// @dev The deposit and withdrawal percentages are set when the pool creates its policy (the pool's
///      shieldFeeBps and unshieldFeeBps constructor arguments, 50 and 50: 0.50% each way). This script
///      prints the one owner call that sets the flat protocol fee and the gas ladder of ETH and NOX, for
///      the Safe to execute after `initRanges`. Values are in note units: ETH at scale 1 (wei), NOX at
///      scale 1e9, so one NOX is 1e9 units.
///
///      ETH: protocol 0.0005 ETH; ladder 0.0025, 0.005, 0.01, 0.02 ETH, covering 4,000,000 gas at 0.5,
///      1, 2 and 4 gwei with a 25% margin.
///      NOX: protocol 400 NOX; ladder 2,000, 4,000, 8,000 and 16,000 NOX.
///
///      env: none. Run: forge script script/shield/FeeSchedule.s.sol
library FeeSchedule {
    uint64 internal constant ETH = 0;
    uint64 internal constant NOX = 1;
    uint16 internal constant DEPOSIT_BPS = 50;
    uint16 internal constant WITHDRAW_BPS = 50;

    function assetIds() internal pure returns (uint64[] memory ids) {
        ids = new uint64[](2);
        ids[0] = ETH;
        ids[1] = NOX;
    }

    function protocolFees() internal pure returns (uint64[] memory fees) {
        fees = new uint64[](2);
        fees[0] = 5e14; // 0.0005 ETH
        fees[1] = 400 * 1e9; // 400 NOX
    }

    function ladders() internal pure returns (uint64[4][] memory l) {
        l = new uint64[4][](2);
        l[0] = [uint64(2.5e15), 5e15, 1e16, 2e16];
        l[1] = [uint64(2_000 * 1e9), 4_000 * 1e9, 8_000 * 1e9, 16_000 * 1e9];
    }
}

contract PrintFeeScheduleCalldata is Script {
    function run() external pure {
        bytes memory data = abi.encodeCall(
            AmountPolicy.initSchedules, (FeeSchedule.assetIds(), FeeSchedule.protocolFees(), FeeSchedule.ladders())
        );
        console2.log("AmountPolicy.initSchedules calldata, for the Safe:");
        console2.logBytes(data);
    }
}
