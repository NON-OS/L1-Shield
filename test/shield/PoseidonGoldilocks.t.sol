// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoseidonGoldilocks} from "../../contracts/shield/PoseidonGoldilocks.sol";

/// @notice The Poseidon-Goldilocks hasher against the pinned kernel KATs in
///         spec/poseidon-constants.json, through its external entry points.
contract PoseidonGoldilocksTest is Test {
    PoseidonGoldilocks internal poseidon;

    function setUp() public {
        // Deployment reverts (KatFailed) if constants or algorithm are wrong.
        poseidon = new PoseidonGoldilocks();
    }

    /// @dev limb 0 = least significant 64 bits.
    function pack(uint64 l0, uint64 l1, uint64 l2, uint64 l3) internal pure returns (bytes32) {
        return bytes32(uint256(l0) | (uint256(l1) << 64) | (uint256(l2) << 128) | (uint256(l3) << 192));
    }

    /// compress([1,2,3,4], [5,6,7,8]) matches the kernel digest.
    function test_Compress_KAT() public view {
        bytes32 left = pack(1, 2, 3, 4);
        bytes32 right = pack(5, 6, 7, 8);
        bytes32 got = poseidon.hash2(left, right);
        bytes32 want = pack(1022089083010806312, 8134804760473441809, 13972665140821454643, 18290724068579387637);
        assertEq(got, want, "compress KAT mismatch");
    }

    /// The single-block hash of [9,10,11,12] matches the kernel digest.
    function test_SingleBlockHash_KAT() public view {
        uint256[] memory in4 = new uint256[](4);
        in4[0] = 9;
        in4[1] = 10;
        in4[2] = 11;
        in4[3] = 12;
        bytes32 got = poseidon.hashFields(in4);
        bytes32 want = pack(7369382236926714597, 2436301979115149546, 5720325819700556311, 17891017047452629057);
        assertEq(got, want, "single-block hash KAT mismatch");
    }

    /// hashFields accepts only 4 elements.
    function test_HashFields_RejectsNonSingleBlockLengths() public {
        uint256[] memory in11 = new uint256[](11);
        vm.expectRevert(PoseidonGoldilocks.NoteCommitmentSpongeUndefined.selector);
        poseidon.hashFields(in11);

        uint256[] memory in3 = new uint256[](3);
        vm.expectRevert(PoseidonGoldilocks.NoteCommitmentSpongeUndefined.selector);
        poseidon.hashFields(in3);
    }

    /// hash2 and hashFields refuse non-canonical field elements.
    function test_RejectsNonCanonicalInput() public {
        bytes32 bad = bytes32(type(uint256).max); // every limb >= p
        vm.expectRevert(PoseidonGoldilocks.NonCanonicalInput.selector);
        poseidon.hash2(bad, bytes32(0));

        uint256[] memory in4 = new uint256[](4);
        in4[0] = 18446744069414584321; // == p, non-canonical
        vm.expectRevert(PoseidonGoldilocks.NonCanonicalInput.selector);
        poseidon.hashFields(in4);
    }

    /// The same inputs hash to the same digest.
    function test_Deterministic() public view {
        bytes32 a = poseidon.hash2(pack(1, 2, 3, 4), pack(5, 6, 7, 8));
        bytes32 b = poseidon.hash2(pack(1, 2, 3, 4), pack(5, 6, 7, 8));
        assertEq(a, b);
    }
}
