// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PoseidonGoldilocks} from "../../contracts/shield/PoseidonGoldilocks.sol";

/// @notice The STATICCALL to the pinned `PoseidonGoldilocks` is a negligible share of hash cost
///         (about 30 of ~133,000 gas), so keeping the hasher a separate contract costs almost nothing.
contract CallOverheadTest is Test {
    PoseidonGoldilocks h;
    function setUp() public { h = new PoseidonGoldilocks(); }

    /// Per-call gas across 32 warm hashes stays within 500 of a single warm call.
    function test_whereTheHashGasGoes() public view {
        bytes32 a = bytes32(uint256(1));
        bytes32 b = bytes32(uint256(2));
        h.hash2(a, b); // warm the account and the code

        uint256 g = gasleft();
        h.hash2(a, b);
        uint256 one = g - gasleft();

        g = gasleft();
        for (uint256 i = 0; i < 32; ++i) h.hash2(a, b);
        uint256 thirtyTwo = g - gasleft();

        console2.log("one warm hash2               :", one);
        console2.log("32 warm hash2                :", thirtyTwo);
        console2.log("  implied per call           :", thirtyTwo / 32);
        // the per-call figure must stay within a few hundred gas of a single call, or the
        // call overhead has become material and inlining is worth revisiting
        assertApproxEqAbs(thirtyTwo / 32, one, 500, "call overhead became material; revisit inlining");
    }
}
