// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/// @notice EIP-7623 calldata floor arithmetic, pinned to the proof-size and gas figures.
/// tokens = zero + 4 * nonzero, cost = 21000 + max(4 * tokens + execution, 10 * tokens).
contract CalldataFloorTest is Test {
    uint256 constant INTRINSIC = 21_000;
    uint256 constant STANDARD_PER_TOKEN = 4;
    uint256 constant FLOOR_PER_TOKEN = 10;

    function tokens(uint256 nonzero, uint256 zero) internal pure returns (uint256) {
        return zero + 4 * nonzero;
    }

    function txCost(uint256 nonzero, uint256 zero, uint256 execution) internal pure returns (uint256) {
        uint256 t = tokens(nonzero, zero);
        uint256 std = STANDARD_PER_TOKEN * t + execution;
        uint256 flr = FLOOR_PER_TOKEN * t;
        return INTRINSIC + (std > flr ? std : flr);
    }

    /// Prices a proof as all non-zero bytes, the conservative case for hash-dense data.
    function costOfProof(uint256 sizeBytes, uint256 execution) internal pure returns (uint256) {
        return txCost(sizeBytes, 0, execution);
    }

    /// The floor cost at 32-, 24- and 20-byte digest proof sizes.
    function test_theReachableFloorCostsWhatWeSayItDoes() public pure {
        assertEq(costOfProof(43_520, 0), 1_761_800, "43,520 B at 32-byte digests");
        assertEq(costOfProof(36_704, 0), 1_489_160, "36,704 B at 24-byte digests");
        assertEq(costOfProof(33_296, 0), 1_352_840, "33,296 B at 20-byte digests");
    }

    /// 24,475 bytes is the largest proof under one million gas while execution stays under the floor threshold.
    function test_theOneMillionCeilingIsAboutBytesNotCode() public pure {
        uint256 ceiling;
        for (uint256 b = 1_000; b < 40_000; b += 1) {
            if (costOfProof(b, 0) > 1_000_000) {
                ceiling = b - 1;
                break;
            }
        }
        assertEq(ceiling, 24_475, "max proof size for a 1,000,000 gas transaction");

        // 200,000 and 400,000 gas of execution both sit under the threshold of 587,400
        assertEq(costOfProof(ceiling, 200_000), costOfProof(ceiling, 400_000), "execution changed the total");
    }

    /// Below `6 * tokens` of execution the total is the floor, and above it the total rises.
    function test_executionIsFreeBelowTheFloorThreshold() public pure {
        uint256 size = 17_294;
        uint256 free = 6 * tokens(size, 0);
        assertEq(free, 415_056, "free execution budget at 17,294 bytes");
        assertEq(costOfProof(size, 0), costOfProof(size, free - 1), "spending under the line changed the total");
        assertGt(costOfProof(size, free + 100_000), costOfProof(size, 0), "and above it, it does not");
    }

    /// Per-payment gas is under one million from two payments per batch, and over it at one.
    function test_perPaymentAtTheReachableFloor() public pure {
        uint256 proof = 43_520;
        uint256 perPaymentBytes = 2 * 32; // two output commitments
        for (uint256 i = 0; i < 4; ++i) {
            uint256 n = i == 0 ? 1 : (i == 1 ? 2 : (i == 2 ? 5 : 10));
            uint256 total = costOfProof(proof + n * perPaymentBytes, 0);
            console2.log("payments in batch  :", n);
            console2.log("  total gas        :", total);
            console2.log("  per payment      :", total / n);
        }
        assertLt(costOfProof(proof + 2 * perPaymentBytes, 0) / 2, 1_000_000, "n=2 must be under a million");
        assertGt(costOfProof(proof + perPaymentBytes, 0), 1_000_000, "and n=1 must not be, or the claim is wrong");
    }

    /// A size model without FRI paths fits under one million gas, and the full proof does not.
    function test_aSubsetModelLooksLikeAgreementUntilItIsPriced() public pure {
        uint256 subset = 20_224; // trace and aux openings only
        uint256 full = 43_520; // plus FRI paths and coset values
        assertLt(costOfProof(subset, 0), 1_000_000, "the subset appears to fit");
        assertGt(costOfProof(full, 0), 1_000_000, "the full object does not");
    }
}
