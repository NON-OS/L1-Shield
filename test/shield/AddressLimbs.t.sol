// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PublicWords} from "../../contracts/shield/verifier/PublicWords.sol";

contract LimbsHarness {
    function expand(uint256[] calldata words, uint256 perIntent) external pure returns (uint256[] memory) {
        return PublicWords.publicsOf(words, perIntent);
    }
}

/// At 12 words an address is carried as 48 + 48 + 48 + 16 bit limbs. These tests pin the packing
/// to the formula the prover uses and show that every address has one encoding.
contract AddressLimbsTest is Test {
    LimbsHarness internal h;
    uint256 internal constant M48 = (1 << 48) - 1;

    function setUp() public {
        h = new LimbsHarness();
    }

    function _intent(uint256 recipient, uint256 feeRecipient) internal pure returns (uint256[] memory w) {
        w = new uint256[](12);
        w[10] = recipient;
        w[11] = feeRecipient;
    }

    function test_theAddressWordsSplitAt48BitBoundaries() public view {
        uint256 a = uint256(uint160(0x406b7762902EAC70d270f457916295a4695f4540));
        uint256[] memory out = h.expand(_intent(a, 0), 12);
        assertEq(out.length, 36);
        // words 0..5 give 24 limbs and words 6..9 give 4, so word 10 starts at limb 28
        assertEq(out[28], a & M48);
        assertEq(out[29], (a >> 48) & M48);
        assertEq(out[30], (a >> 96) & M48);
        assertEq(out[31], a >> 144);
        assertEq(out[28] | (out[29] << 48) | (out[30] << 96) | (out[31] << 144), a);
    }

    function test_theAllOnesAddressHasAnEncodingOnlyUnderTheNarrowLayout() public {
        uint256 a = type(uint160).max;
        uint256[] memory out = h.expand(_intent(a, a), 12);
        for (uint256 i = 28; i < 36; ++i) assertLt(out[i], 1 << 48);
        uint256[] memory w11 = new uint256[](11);
        w11[10] = a;
        vm.expectRevert();
        h.expand(w11, 11);
    }

    function testFuzz_everyAddressRoundTrips(address who, address feeTo) public view {
        uint256 a = uint256(uint160(who));
        uint256 b = uint256(uint160(feeTo));
        uint256[] memory out = h.expand(_intent(a, b), 12);
        assertEq(out[28] | (out[29] << 48) | (out[30] << 96) | (out[31] << 144), a);
        assertEq(out[32] | (out[33] << 48) | (out[34] << 96) | (out[35] << 144), b);
    }

    function test_aWordWiderThanAnAddressIsRefused() public {
        vm.expectRevert();
        h.expand(_intent(uint256(1) << 160, 0), 12);
    }
}
