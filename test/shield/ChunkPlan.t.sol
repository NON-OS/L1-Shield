// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {RealQueryVerify as V} from "../../contracts/shield/verifier/RealQueryVerify.sol";

/// Queries per relayable chunk, derived from the proof shape. Nodes drop transactions above
/// 128 KB, so the count must shrink when the periodic sidecar grows a base query.
contract ChunkPlanTest is Test {
    /// Node relay policy, not a protocol constant.
    uint256 constant RELAY_LIMIT = 131072;
    /// Claim-free head: frame, roots and nonce. The claim-carrying head adds the 2,649 periodic
    /// claims (42,388 bytes). A chunk count depends on which head it assumes.
    uint256 constant HEAD_CLAIM_FREE = 24956;
    uint256 constant HEAD_WITH_CLAIMS = 24956 + 42388;
    uint256 constant NPER = 2649;

    function _baseQueryBytes(uint256 traceWidth, uint256 nPeriodic, uint256 depth)
        internal
        pure
        returns (uint256)
    {
        uint256 b = 16 + (4 + depth * 32); // the deep value and its path
        b += 4 + traceWidth * 8 + (4 + depth * 32); // the trace row and its path
        b += 16 + (4 + depth * 32); // the composition value and its path
        if (nPeriodic != 0) b += 4 + nPeriodic * 8 + (4 + depth * 32);
        return b;
    }

    function _perChunk(uint256 qBytes) internal pure returns (uint256 n) {
        return _perChunk(qBytes, HEAD_CLAIM_FREE);
    }

    function _perChunk(uint256 qBytes, uint256 head) internal pure returns (uint256 n) {
        n = (RELAY_LIMIT - head) / qBytes;
        require(n > 0, "a single query does not fit a chunk");
    }

    function test_thePlannerSizesChunksFromTheShapeAndNotFromHabit() public pure {
        uint256 today = _baseQueryBytes(747, 0, 26);
        uint256 withSidecar = _baseQueryBytes(747, 2641, 26);

        uint256 nToday = _perChunk(today);
        uint256 nSidecar = _perChunk(withSidecar);

        console2.log("base query today          ", today);
        console2.log("  queries per chunk       ", nToday);
        console2.log("base query with sidecar   ", withSidecar);
        console2.log("  queries per chunk       ", nSidecar);
        console2.log("base chunks for 32 queries", (32 + nSidecar - 1) / nSidecar);

        assertLe(HEAD_CLAIM_FREE + nToday * today, RELAY_LIMIT, "today's chunk must be relayable");
        assertLe(HEAD_CLAIM_FREE + nSidecar * withSidecar, RELAY_LIMIT, "the sidecar chunk must be relayable");

        // One more query does not fit, so chunks are full.
        assertGt(HEAD_CLAIM_FREE + (nToday + 1) * today, RELAY_LIMIT, "today's chunk is under-filled");
        assertGt(HEAD_CLAIM_FREE + (nSidecar + 1) * withSidecar, RELAY_LIMIT, "the sidecar chunk is under-filled");
    }

    /// The sidecar-free query count builds an unrelayable chunk at the sidecar shape.
    function test_todaysCountBecomesUnrelayableWithTheSidecar() public pure {
        uint256 withSidecar = _baseQueryBytes(747, 2641, 26);
        uint256 nToday = _perChunk(_baseQueryBytes(747, 0, 26));
        uint256 wouldBe = HEAD_CLAIM_FREE + nToday * withSidecar;
        console2.log("chunk if the count does not change", wouldBe);
        assertGt(wouldBe, RELAY_LIMIT, "this is the regression the planner must not have");
    }

    /// Per-chunk query counts for the claim-carrying head (two) and the claim-free head (three).
    function test_bothChunkCountsAreNamedByTheirHead() public pure {
        uint256 baseQ = _baseQueryBytes(749, NPER, 26);

        uint256 perChunkWithClaims = _perChunk(baseQ, HEAD_WITH_CLAIMS);
        uint256 perChunkClaimFree = _perChunk(baseQ, HEAD_CLAIM_FREE);

        assertEq(perChunkWithClaims, 2, "claim-carrying: two base queries a chunk, as walked");
        // The emit's n_chunks is the Poseidon absorb count (70 div-ceil 4 = 18), not a walk count.
        assertEq(perChunkClaimFree, 3, "claim-free: three base queries a chunk");

        assertLt(HEAD_WITH_CLAIMS + perChunkWithClaims * baseQ, RELAY_LIMIT, "claim-carrying fits");
        assertLt(HEAD_CLAIM_FREE + perChunkClaimFree * baseQ, RELAY_LIMIT, "claim-free fits");
    }
}
