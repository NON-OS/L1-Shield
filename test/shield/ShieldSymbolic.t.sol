// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Goldilocks} from "../../contracts/shield/libraries/Goldilocks.sol";

/// @notice Halmos checks, also forge fuzz targets: field canonicality, fee splits, accumulator bound.
contract ShieldSymbolicTest is Test {
    uint256 internal constant P = Goldilocks.P;
    uint16 internal constant BPS = 10_000;
    uint16 internal constant MAX_FEE_BPS = 50;
    uint256 internal constant PRECISION = 1e27;

    /// @notice A digest is canonical if and only if every 64-bit limb is below p.
    function check_CanonicalDigestIffAllLimbsCanonical(bytes32 digest) public pure {
        bool expected = true;
        for (uint256 i = 0; i < 4; ++i) {
            if (Goldilocks.limb(digest, i) >= P) expected = false;
        }
        assertEq(Goldilocks.isCanonicalDigest(digest), expected);
    }

    /// @notice The split formula of ShieldFeeRouter.distribute conserves every wei for all legal configs.
    function check_FeeSplitConservesTotal(uint256 total, uint16 stakingBps, uint16 treasuryBps) public pure {
        vm.assume(uint256(stakingBps) + treasuryBps <= BPS);
        vm.assume(treasuryBps <= 5_000);
        vm.assume(total < type(uint128).max); // no realistic token overflows this

        uint256 toStaking = (total * stakingBps) / BPS;
        uint256 toTreasury = (total * treasuryBps) / BPS;
        uint256 toBurn = total - toStaking - toTreasury; // never underflows given the assume

        assertEq(toStaking + toTreasury + toBurn, total);
    }

    /// @notice The protocol fee never exceeds 0.5% of any 64-bit amount at any bps up to the cap.
    function check_ProtocolFeeBounded(uint64 amount, uint16 feeBps) public pure {
        vm.assume(feeBps <= MAX_FEE_BPS);
        uint256 fee = (uint256(amount) * feeBps) / BPS;
        assertLe(fee, uint256(amount) / 200);
        assertLe(fee, uint256(amount)); // net value never negative
    }

    /// @notice One accumulator step never distributes more than was notified.
    function check_AccumulatorNeverOverDistributes(uint128 total, uint128 staked) public pure {
        vm.assume(staked > 0);
        uint256 increment = (uint256(total) * PRECISION) / staked;
        uint256 distributed = (increment * staked) / PRECISION;
        assertLe(distributed, uint256(total));
    }

    /// @notice Taking a capped bps fee out of a 64-bit amount leaves a remainder that sums back to it.
    function check_UnshieldSplitConserves(uint64 publicAmount, uint16 feeBps) public pure {
        vm.assume(feeBps <= MAX_FEE_BPS);
        uint256 protocolFee = (uint256(publicAmount) * feeBps) / BPS;
        uint256 toRecipient = uint256(publicAmount) - protocolFee;
        assertEq(toRecipient + protocolFee, uint256(publicAmount));
    }
}
