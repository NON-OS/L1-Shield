// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {Test} from "forge-std/Test.sol";
import {ShieldLedger} from "../../../contracts/shield/ShieldLedger.sol";
import {Goldilocks} from "../../../contracts/shield/libraries/Goldilocks.sol";

/// Symbolic proofs of ShieldLedger over every input. The pool calls splitDeposit and debit.
/// Run: FOUNDRY_PROFILE=halmos halmos --forge-build-out out-halmos --match-contract ShieldLedgerHalmos
contract ShieldLedgerHalmos is SymTest, Test {
    uint16 constant BPS = 10_000;
    uint16 constant MAX_FEE_BPS = 50;
    uint256 constant MAX_VALUE = Goldilocks.MAX_VALUE;

    /// A deposit split loses nothing: fee plus value equals the amount at every allowed rate.
    function check_aDepositSplitLosesNothing(uint256 amount, uint16 feeBps) public pure {
        vm.assume(amount <= MAX_VALUE);
        vm.assume(feeBps <= MAX_FEE_BPS);
        (uint256 fee, uint256 value) = ShieldLedger.splitDeposit(amount, feeBps);
        assert(fee + value == amount);
    }

    function check_aDepositFeeNeverExceedsTheAmount(uint256 amount, uint16 feeBps) public pure {
        vm.assume(amount <= MAX_VALUE);
        vm.assume(feeBps <= BPS);
        (uint256 fee, uint256 value) = ShieldLedger.splitDeposit(amount, feeBps);
        assert(fee <= amount);
        assert(value <= amount);
    }

    /// A fee that passes the cap is at most the public leg, so the subtraction never reverts.
    function check_theFeeCapIsWhatMakesTheUnshieldSubtractionSafe(uint256 publicAmount, uint256 fee) public pure {
        vm.assume(publicAmount <= MAX_VALUE);
        vm.assume(fee <= MAX_VALUE);
        (bool ok, uint256 toRecipient) = ShieldLedger.splitUnshield(publicAmount, fee, MAX_FEE_BPS);
        if (ok) {
            assert(fee <= publicAmount);
            assert(toRecipient + fee == publicAmount);
        }
    }

    /// A fee taking the whole leg is refused, stated multiplicatively to keep the solver in time.
    function check_aFeeTakingTheWholeLegIsRefused(uint256 publicAmount) public pure {
        vm.assume(publicAmount > 0);
        vm.assume(publicAmount <= MAX_VALUE);
        (bool ok,) = ShieldLedger.splitUnshield(publicAmount, publicAmount, MAX_FEE_BPS);
        assert(!ok);
    }

    /// Any fee above one percent of the leg is refused, the cap being half of one percent.
    function check_aFeeAboveOnePercentIsRefused(uint256 publicAmount, uint256 fee) public pure {
        vm.assume(publicAmount <= MAX_VALUE);
        vm.assume(fee <= MAX_VALUE);
        vm.assume(fee * 100 > publicAmount);
        (bool ok,) = ShieldLedger.splitUnshield(publicAmount, fee, MAX_FEE_BPS);
        assert(!ok);
    }

    /// A debit is refused or lowers the total by the amount, and never wraps or grows it.
    function check_aDebitNeverWrapsAndNeverGrows(uint256 total, uint256 amount) public pure {
        (bool ok, uint256 left) = ShieldLedger.debit(total, amount);
        assert(left <= total);
        if (ok) assert(left + amount == total);
        else assert(left == total);
    }

    /// splitUnshield never pays more than the leg, pays nothing when refused, and conserves the leg.
    function check_anUnshieldNeverPaysMoreThanItsLeg(uint256 publicAmount, uint256 fee, uint16 maxFeeBps)
        public
        pure
    {
        vm.assume(publicAmount <= MAX_VALUE && fee <= MAX_VALUE);
        vm.assume(maxFeeBps <= BPS);
        (bool ok, uint256 toRecipient) = ShieldLedger.splitUnshield(publicAmount, fee, maxFeeBps);
        assert(toRecipient <= publicAmount);
        if (!ok) assert(toRecipient == 0);
        else assert(toRecipient + fee == publicAmount);
    }

    /// Under any cap up to BPS, an accepted fee is at most the leg.
    function check_anyCapUpToBpsKeepsTheFeeWithinTheLeg(uint256 publicAmount, uint256 fee, uint16 maxFeeBps)
        public
        pure
    {
        vm.assume(publicAmount <= MAX_VALUE && fee <= MAX_VALUE);
        vm.assume(maxFeeBps <= BPS);
        (bool ok,) = ShieldLedger.splitUnshield(publicAmount, fee, maxFeeBps);
        if (ok) assert(fee <= publicAmount);
    }
}
