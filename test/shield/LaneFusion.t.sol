// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";

/// @notice The region-lane fusion rule against the prover's vector, using emitted body values:
///         lane c = sum over kinds k with arity > c of selector_z[k] * values[k][c].
///         Lanes 162..215 are the permutation product and are not checked here.
contract LaneFusionTest is Test {
    string internal j;

    function setUp() public {
        j = vm.readFile(vm.envOr("KINDS", string("spec/emit-v11/kinds-flat-z.json")));
    }

    function _fp2(uint256[] memory f, uint256 i) internal pure returns (F.Fp2 memory) {
        return F.Fp2(f[2 * i], f[2 * i + 1]);
    }

    /// The fusion rule reproduces every region lane of the prover's transition vector.
    function test_theFusionRuleIsTheProvers() public view {
        uint256[] memory arity = vm.parseJsonUintArray(j, ".arity");
        uint256[] memory off = vm.parseJsonUintArray(j, ".value_offset");
        uint256[] memory sel = vm.parseJsonUintArray(j, ".selectors");
        uint256[] memory vals = vm.parseJsonUintArray(j, ".values");
        uint256[] memory want = vm.parseJsonUintArray(j, ".transitions_z");

        uint256 regionLanes;
        for (uint256 k = 0; k < arity.length; ++k) if (arity[k] > regionLanes) regionLanes = arity[k];

        uint256 matched;
        for (uint256 c = 0; c < regionLanes; ++c) {
            F.Fp2 memory acc = F.Fp2(0, 0);
            for (uint256 k = 0; k < arity.length; ++k) {
                if (c >= arity[k]) continue; // a kind contributes nothing past its own arity
                acc = F.add(acc, F.mul(_fp2(sel, k), _fp2(vals, off[k] + c)));
            }
            if (acc.c0 == want[2 * c] && acc.c1 == want[2 * c + 1]) ++matched;
            else if (matched == c) {
                console2.log("first divergence at lane", c);
                console2.log("  ours", acc.c0);
                console2.log("  want", want[2 * c]);
            }
        }
        console2.log("region lanes fused", matched, "of", regionLanes);
        assertEq(matched, regionLanes, "the fusion rule does not reproduce the prover's lanes");
    }

    /// Every kind contributes at lane 0, and fewer do at lane 40, so lanes interleave.
    function test_everyKindContributesAtLaneZero() public view {
        uint256[] memory arity = vm.parseJsonUintArray(j, ".arity");
        uint256 atZero;
        uint256 atForty;
        for (uint256 k = 0; k < arity.length; ++k) {
            if (arity[k] > 0) ++atZero;
            if (arity[k] > 40) ++atForty;
        }
        console2.log("kinds contributing at lane 0 :", atZero);
        console2.log("kinds contributing at lane 40:", atForty);
        assertEq(atZero, arity.length, "a kind with zero arity would be a body nothing runs");
        assertLt(atForty, atZero, "lanes are blocks, not interleaved: the dispatch model is wrong");
    }
}
