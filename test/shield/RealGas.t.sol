// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";
import {PoseidonGoldilocks} from "../../contracts/shield/PoseidonGoldilocks.sol";
import {AssociationSetRegistry} from "../../contracts/shield/AssociationSetRegistry.sol";
import {IPoseidonGoldilocks} from "../../contracts/shield/interfaces/IPoseidonGoldilocks.sol";
import {IStarkVerifier} from "../../contracts/shield/interfaces/IStarkVerifier.sol";
import {IAssociationSetRegistry} from "../../contracts/shield/interfaces/IAssociationSetRegistry.sol";
import {MockStarkVerifier} from "./mocks/MockStarkVerifier.sol";

/// One empty client-data blob per settlement output. Empty is legal: the opening travels off-chain.
function _blobs(uint256 n) pure returns (bytes[] memory b) {
    b = new bytes[](n);
}

/// One blob per output for a batch of public words: two outputs and twelve words per intent.
function _blobsFor(uint256[] memory publicWords) pure returns (bytes[] memory) {
    return _blobs(2 * (publicWords.length / 12));
}


/// @notice Per-function gas table against the real Poseidon hasher the pool pins. The mock hasher
///         used elsewhere is far cheaper, so only these numbers are quotable.
contract RealGasTest is Test {
    ShieldedPool internal pool;
    PoseidonGoldilocks internal hasher;
    AssociationSetRegistry internal registry;
    MockStarkVerifier internal verifier;

    address internal safe = address(0x5AFE);
    address internal alice = address(0xA11CE);

    function setUp() public {
        hasher = new PoseidonGoldilocks();
        verifier = new MockStarkVerifier();
        registry = new AssociationSetRegistry();

        ShieldedPool.DeploymentSelfTest memory st;
        st.hash2Left = bytes32(uint256(1));
        st.hash2Right = bytes32(uint256(2));
        st.hash2Expected = hasher.hash2(st.hash2Left, st.hash2Right);
        st.fieldsInput = new uint256[](4);
        st.fieldsInput[0] = 1;
        st.fieldsInput[1] = 2;
        st.fieldsInput[2] = 3;
        st.fieldsInput[3] = 4;
        st.fieldsExpected = hasher.hashFields(st.fieldsInput);
        st.proof = hex"53454c4654455354";
        st.proofPublicInputs = new uint256[](12);
        st.noteValue = 1000;
        st.noteAssetId = 0;
        st.noteOwnerCommit = hasher.hash2(bytes32(uint256(7)), bytes32(uint256(8)));
        st.noteCommitmentExpected =
            hasher.hash2(bytes32(uint256(1000) | (uint256(0x4E4F5445) << 192)), st.noteOwnerCommit);

        pool = new ShieldedPool(
            safe,
            IStarkVerifier(address(verifier)),
            IPoseidonGoldilocks(address(hasher)),
            IAssociationSetRegistry(address(registry)),
            address(0xFEE),
            30,
            30,
            0,
            12,
            st
        );
        vm.prank(safe);
        pool.endBetaMode();
        vm.deal(alice, 1000 ether);
    }

    function _canon(bytes32 h) internal pure returns (bytes32 out) {
        return bytes32(uint256(h) & 0x7FFFFFFFFFFFFFFF7FFFFFFFFFFFFFFF7FFFFFFFFFFFFFFF7FFFFFFFFFFFFFFF);
    }

    bytes32 internal assocRoot;

    function _registerAssoc() internal {
        assocRoot = _canon(keccak256("assoc"));
        registry.publishRoot(assocRoot, "ipfs://a");
    }

    /// An N-intent batch in the 12-word layout. Private transfers carry no fee, recipient or price.
    function _batch(uint256 n, bytes32 root) internal returns (uint256[] memory w) {
        w = new uint256[](n * 12);
        for (uint256 i = 0; i < n; ++i) {
            uint256 o = i * 12;
            w[o] = uint256(root);
            w[o + 1] = uint256(assocRoot);
            w[o + 2] = uint256(_canon(keccak256(abi.encode("nf0", i, ++nonce))));
            w[o + 3] = uint256(_canon(keccak256(abi.encode("nf1", i, nonce))));
            w[o + 4] = uint256(_canon(keccak256(abi.encode("cm0", i, nonce))));
            w[o + 5] = uint256(_canon(keccak256(abi.encode("cm1", i, nonce))));
            // words 6..11 stay zero: amount, fee, asset, price, recipient, fee recipient
        }
    }

    uint256 internal nonce;

    function test_gas_settleBatch() public {
        _registerAssoc();
        vm.prank(alice);
        pool.absorb{value: 1 ether}(0, 1 ether, _canon(keccak256("seed")));
        bytes32 root = pool.commitRoot();

        ShieldedPool.ResidualExec memory r;
        r.path = new address[](0);

        for (uint256 k = 0; k < 4; ++k) {
            uint256 n = k == 0 ? 1 : (k == 1 ? 2 : (k == 2 ? 4 : 8));
            uint256[] memory w = _batch(n, root);
            uint256 g = gasleft();
            pool.settleBatch(hex"70726f6f66", w, r, "", _blobs(2 * n));
            uint256 used = g - gasleft();
            console2.log("settleBatch intents         :", n);
            console2.log("  total gas                 :", used);
            console2.log("  per payment               :", used / n);
        }
    }

    function test_gas_hasher() public view {
        uint256 g = gasleft();
        hasher.hash2(bytes32(uint256(1)), bytes32(uint256(2)));
        console2.log("hash2 (real Poseidon)        :", g - gasleft());
    }

    function test_gas_absorbFirstLeaf() public {
        vm.prank(alice);
        uint256 g = gasleft();
        pool.absorb{value: 1 ether}(0, 1 ether, _canon(keccak256("o1")));
        console2.log("absorb, first leaf           :", g - gasleft());
    }

    /// Absorb cost follows the index's trailing ones, not the tree depth.
    function test_gas_absorbAcrossIndices() public {
        for (uint256 i = 0; i < 8; ++i) {
            vm.prank(alice);
            uint256 g = gasleft();
            pool.absorb{value: 1 ether}(0, 1 ether, _canon(keccak256(abi.encode("o", i))));
            console2.log("absorb at leaf index", i, ":", g - gasleft());
        }
    }

    function test_gas_tableSummary() public {
        uint256 total;
        for (uint256 i = 0; i < 16; ++i) {
            vm.prank(alice);
            uint256 g = gasleft();
            pool.absorb{value: 1 ether}(0, 1 ether, _canon(keccak256(abi.encode("s", i))));
            total += g - gasleft();
        }
        console2.log("16 absorbs, total            :", total);
        console2.log("16 absorbs, mean             :", total / 16);
        uint256 g = gasleft();
        pool.commitRoot();
        uint256 commitGas = g - gasleft();
        console2.log("one commitRoot               :", commitGas);
        console2.log("16 deposits + 1 root         :", total + commitGas);
        console2.log("  per deposit amortised      :", (total + commitGas) / 16);
        console2.log("was, root on every absorb    :", uint256(71_799_763));
        console2.log("send cap                     :", uint256(16_777_216));
    }

}
