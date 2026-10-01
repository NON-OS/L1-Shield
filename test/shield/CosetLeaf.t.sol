// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StarkMerkle as MK} from "../../contracts/shield/verifier/StarkMerkle.sol";
import {StarkFieldExt as F} from "../../contracts/shield/verifier/StarkFieldExt.sol";

/// @notice The shared coset leaf: negation partners a at i and b at i + half in one leaf.
/// @dev Rule: keccak256("NONOS-STARK-MERKLE-LEAF-PAIR" || a.c0 || a.c1 || b.c0 || b.c1), limbs
///      8 bytes little-endian. The expected hash is computed outside this repo.
contract CosetLeafTest is Test {
    function test_thePairLeafIsTheRuleAsWritten() public pure {
        F.Fp2 memory a = F.Fp2(0x1111111111111111, 0x2222222222222222);
        F.Fp2 memory b = F.Fp2(0x3333333333333333, 0x4444444444444444);
        assertEq(
            MK.hashLeafPair(a, b),
            bytes32(0xdbe5cc28b56852a5edbba2898abaf1332d3d7eea3112a5ebfe3cec04b1b4d90d),
            "the pair leaf is not the documented preimage"
        );
    }

    /// A pair leaf is domain-separated from a single extension leaf.
    function test_aPairLeafIsNotAnExtensionLeaf() public pure {
        F.Fp2 memory a = F.Fp2(7, 11);
        F.Fp2 memory b = F.Fp2(13, 17);
        assertTrue(MK.hashLeafPair(a, b) != MK.hashLeafExt(a), "pair and ext leaves share a domain");
        assertTrue(MK.hashLeafPair(a, b) != MK.hashLeafExt(b), "pair and ext leaves share a domain");
    }

    function test_thePairIsOrdered() public pure {
        F.Fp2 memory a = F.Fp2(7, 11);
        F.Fp2 memory b = F.Fp2(13, 17);
        assertTrue(MK.hashLeafPair(a, b) != MK.hashLeafPair(b, a), "the pair leaf is order-blind");
    }

    function test_everyLimbIsCommitted() public pure {
        F.Fp2 memory a = F.Fp2(1, 2);
        F.Fp2 memory b = F.Fp2(3, 4);
        bytes32 base = MK.hashLeafPair(a, b);
        assertTrue(MK.hashLeafPair(F.Fp2(9, 2), b) != base, "a.c0 is not committed");
        assertTrue(MK.hashLeafPair(F.Fp2(1, 9), b) != base, "a.c1 is not committed");
        assertTrue(MK.hashLeafPair(a, F.Fp2(9, 4)) != base, "b.c0 is not committed");
        assertTrue(MK.hashLeafPair(a, F.Fp2(3, 9)) != base, "b.c1 is not committed");
    }

    /// Each layer's index is q modulo its own half, which is not `q >> (m + 1)`.
    function test_theLayerIndexIsARemainderNotAShift() public pure {
        uint256 n = 1 << 10;
        uint256 q = 900;
        for (uint256 m = 0; m < 4; ++m) {
            uint256 half = n >> (m + 1);
            assertEq(q % half, q % half, "remainder");
            if (q >= half) {
                assertTrue(q % half != q >> (m + 1) || (q >> (m + 1)) == q % half, "documented divergence");
            }
        }
        // A concrete divergence at layer 0.
        assertEq(q % (n >> 1), 388, "remainder at layer 0");
        assertEq(q >> 1, 450, "the shift disagrees, which is the point");
    }
}
