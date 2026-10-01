// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PoseidonGoldilocks} from "../../contracts/shield/PoseidonGoldilocks.sol";

/// @dev Prints known-answer vectors for the nullifier IMT, computed with the PoseidonGoldilocks
///      hash2. Run with -vv to capture them.
contract GenNullifierImt is Test {
    PoseidonGoldilocks poseidon;
    uint256 constant IMT_LEAF_DOMAIN = 0x494D544C; // "IMTL"
    uint256 constant DEPTH = 32;

    function setUp() public {
        poseidon = new PoseidonGoldilocks();
    }

    function _pack(uint256 l0, uint256 l1, uint256 l2, uint256 l3) internal pure returns (bytes32) {
        return bytes32(l0 | (l1 << 64) | (l2 << 128) | (l3 << 192));
    }

    /// leaf(value[4], nextIndex, isLast, nextValue[4]):
    ///   p[0..3]=value, p[4..7]=nextValue, p[8]=nextIndex, p[9]=isLast, p[10]=DOMAIN, p[11..15]=0
    ///   d0 = compress(p[0..4], p[4..8]), d1 = compress(p[8..12], p[12..16]), leaf = compress(d0, d1)
    function _leaf(
        uint256 v0,
        uint256 v1,
        uint256 v2,
        uint256 v3,
        uint256 nextIndex,
        uint256 isLast,
        uint256 n0,
        uint256 n1,
        uint256 n2,
        uint256 n3
    ) internal view returns (bytes32) {
        bytes32 d0 = poseidon.hash2(_pack(v0, v1, v2, v3), _pack(n0, n1, n2, n3));
        bytes32 d1 = poseidon.hash2(_pack(nextIndex, isLast, IMT_LEAF_DOMAIN, 0), bytes32(0));
        return poseidon.hash2(d0, d1);
    }

    function test_emit_imt_vectors() public view {
        // 1. leaf(1,2,3,isLast=0): value=1, nextIndex=2, nextValue=3
        bytes32 leaf123 = _leaf(1, 0, 0, 0, 2, 0, 3, 0, 0, 0);
        // 2. genesis sentinel: leaf(0,0,0,isLast=1)
        bytes32 sentinel = _leaf(0, 0, 0, 0, 0, 1, 0, 0, 0, 0);
        bytes32 emptyLeaf = _leaf(0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

        // 3. GENESIS_ROOT: leaf[0]=sentinel, leaf[1..]=EMPTY_LEAF, depth 32
        bytes32[] memory zeros = new bytes32[](DEPTH);
        zeros[0] = emptyLeaf;
        for (uint256 i = 1; i < DEPTH; ++i) {
            zeros[i] = poseidon.hash2(zeros[i - 1], zeros[i - 1]);
        }
        bytes32 node = sentinel;
        for (uint256 lvl = 0; lvl < DEPTH; ++lvl) {
            node = poseidon.hash2(node, zeros[lvl]);
        }
        bytes32 genesisRoot = node;

        // 4. batchDigest of a fixed 2-intent (22-word) public vector = keccak(packed uint256[22])
        uint256[] memory pubs = new uint256[](22);
        for (uint256 i = 0; i < 22; ++i) {
            pubs[i] = i + 1;
        }
        bytes32 batchDigest = keccak256(abi.encodePacked(pubs));

        console2.log("IMT_LEAF_DOMAIN = 0x494D544C (IMTL)  DEPTH = 32");
        console2.log("leaf_1_2_3_isLast0:");
        console2.logBytes32(leaf123);
        console2.log("sentinel_0_0_0_isLast1:");
        console2.logBytes32(sentinel);
        console2.log("empty_leaf:");
        console2.logBytes32(emptyLeaf);
        console2.log("genesis_root:");
        console2.logBytes32(genesisRoot);
        console2.log("batch_digest_1to22:");
        console2.logBytes32(batchDigest);
    }
}
