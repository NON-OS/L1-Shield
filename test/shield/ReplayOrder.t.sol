// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StarkTranscript as TS} from "../../contracts/shield/verifier/StarkTranscript.sol";

/// Transcript index order: the k-th consistency index is the k-th consecutive draw, and the
/// grind nonce folded before the draws shifts every index.
contract ReplayOrderTest is Test {
    uint256 constant BOUND = 1 << 20; // eval-domain size (power of two)
    uint256 constant N = 8;

    function _seed() internal pure returns (TS.T memory t) {
        t = TS.init("NONOS-STARK-EXT");
        TS.absorbDigest(t, keccak256("trace-root"));
        TS.absorbDigest(t, keccak256("comp-root"));
    }

    /// Index k equals the (k+1)-th consecutive draw from the same seed.
    function test_indexSequenceIsConsecutive() public pure {
        TS.T memory a = _seed();
        uint256[] memory A = new uint256[](N);
        for (uint256 k = 0; k < N; ++k) {
            A[k] = TS.challengeIndex(a, BOUND);
        }
        for (uint256 k = 0; k < N; ++k) {
            TS.T memory b = _seed();
            uint256 last;
            for (uint256 j = 0; j <= k; ++j) {
                last = TS.challengeIndex(b, BOUND);
            }
            assertEq(last, A[k], "index k is not the k-th consecutive draw");
        }
    }

    /// Consecutive draws differ, so an off-by-one changes the drawn value.
    function test_drawsEvolve() public pure {
        TS.T memory a = _seed();
        uint256 i0 = TS.challengeIndex(a, BOUND);
        uint256 i1 = TS.challengeIndex(a, BOUND);
        assertTrue(i0 != i1, "consecutive draws identical - state not evolving");
    }

    /// Folding the grind nonce before the index draw shifts the drawn index.
    function test_grindBeforeIndicesShifts() public pure {
        TS.T memory withGrind = _seed();
        bool ok = TS.verifyPow(withGrind, 12345, 0); // bits=0 always passes and still mixes the nonce
        assertTrue(ok, "pow(bits=0) should pass");
        uint256 idxWith = TS.challengeIndex(withGrind, BOUND);

        TS.T memory without = _seed();
        uint256 idxWithout = TS.challengeIndex(without, BOUND);

        assertTrue(idxWith != idxWithout, "grind placement must shift the index");
    }
}
