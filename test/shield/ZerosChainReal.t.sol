// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {GoldilocksIncrementalTree} from "../../contracts/shield/GoldilocksIncrementalTree.sol";
import {PoseidonGoldilocks} from "../../contracts/shield/PoseidonGoldilocks.sol";
import {IPoseidonGoldilocks} from "../../contracts/shield/interfaces/IPoseidonGoldilocks.sol";

contract RealTree is GoldilocksIncrementalTree {
    constructor(IPoseidonGoldilocks h) GoldilocksIncrementalTree(h) {}

    function deferred(bytes32 l) external returns (uint40) {
        return _insertLeafDeferred(l);
    }

    function walk(bytes32 l) external returns (uint40) {
        return _insertLeaf(l);
    }

    function commit() external returns (bytes32) {
        return _commitRoot();
    }
}

/// @notice The zeros chain under the real Poseidon hasher, in place of the suite's mock.
/// Values are pinned, so a change to the permutation fails here.
contract ZerosChainRealTest is Test {
    PoseidonGoldilocks real;
    RealTree tree;

    function setUp() public {
        real = new PoseidonGoldilocks();
        tree = new RealTree(IPoseidonGoldilocks(address(real)));
    }

    /// The chain the constructor built is the chain the real hasher produces.
    function test_theChainIsTheRealHashersOwn() public view {
        assertEq(tree.zeros(0), bytes32(0), "zeros[0] must be the empty leaf");
        for (uint256 l = 0; l + 1 < 32; ++l) {
            assertEq(
                tree.zeros(l + 1), real.hash2(tree.zeros(l), tree.zeros(l)), "zeros chain left the real hasher"
            );
        }
    }

    /// Every entry is a canonical Goldilocks digest, so a proof can open beside any empty subtree.
    function test_everyEntryIsACanonicalDigest() public view {
        uint64 P = 0xFFFFFFFF00000001;
        for (uint256 l = 0; l < 32; ++l) {
            bytes32 z = tree.zeros(l);
            for (uint256 limb = 0; limb < 4; ++limb) {
                uint64 v = uint64(uint256(z) >> (limb * 64));
                assertLt(v, P, "zeros entry carries a non-canonical limb");
            }
        }
    }

    /// The fold and the walk agree under the real permutation.
    function test_foldMatchesTheWalkUnderTheRealPermutation() public {
        RealTree seq = new RealTree(IPoseidonGoldilocks(address(real)));
        RealTree def = new RealTree(IPoseidonGoldilocks(address(real)));
        for (uint256 i = 0; i < 5; ++i) {
            bytes32 leaf = bytes32(uint256(keccak256(abi.encode("real", i))) >> 8);
            seq.walk(leaf);
            def.deferred(leaf);
            assertEq(def.commit(), seq.currentRoot(), "fold left the walk under real Poseidon");
        }
    }

    /// The constructor's chain matches the pinned vector. Regenerate it with `test_zzz_printTheChain`.
    function test_theChainIsTheOneWeShipped() public view {
        bytes32[32] memory z;
            z[0] = 0x0000000000000000000000000000000000000000000000000000000000000000;
            z[1] = 0x4bbbda1ac693e3d65a430037146e172f26df37317f569e223cda43bb24edcd9c;
            z[2] = 0x86927e668f7edd28702fb401044a2dfc98373342979de9033d7f757c2cd311c1;
            z[3] = 0x3b999b0c5b286b0416a7ed349a809e3fefdc14bf9d55277b6b0ab6d9923e132d;
            z[4] = 0xd37f897c27358eb90abfabe30fde5f880a48573200d5bb9555a072ead6631eb5;
            z[5] = 0xc76971305761250075361dc1c5520ef3391d24e992f5992c6a68878ce6a4153b;
            z[6] = 0xf0194962e76ca75dd909aebc2117c398cc1bfcdd7e397a5a9aa68aa47c5dff24;
            z[7] = 0x5619b15134f62658158d9943a2784efd3e324bc5f855c049af61dda557be02cc;
            z[8] = 0x0947fd53c5d8c7d58356145e1f8e0de43559fc1c39587b43271a2bccfbf6e066;
            z[9] = 0x78aa655ef661ac34c79cf4814acfdec220dd0e735b46597a48915dc2177b5cd0;
            z[10] = 0xc6e7e94fc7b0b68c597c70228dbd9ea4b94833a0fa2c5d3f56c270a09688a273;
            z[11] = 0x48db5749d2536eb3e86aef82e59031d167ab98e6aa1d1d3cd3d3f45d8f4f5705;
            z[12] = 0xafc6af9fcab2fabb9c4f26eeb5ead85ec2734cdfd14b2309a50dcc8467c5b3e0;
            z[13] = 0x12f9b71aca5a625f38ea4a7028a6ebf35bfaba07219bd0b5363c4906666b4723;
            z[14] = 0xad4c3afed529029be48a71aaa9c2d376bcac86bcb6926e4e149ce6f5f772f82d;
            z[15] = 0xfa344f8ff4df71e8aa1eecb5502c4727c4f1fc2eb7eb3bb9eeab4bd588944123;
            z[16] = 0xbf0ffbbae458163672a1b6c5adafde721496c882914edc409724827f7d549101;
            z[17] = 0xd4acc377b03d51d6bfef4fd4b853b3ee1735889ff0729c2681621110e620fd7f;
            z[18] = 0x05925358772aed8f90b7c9a13a1e3582316f55f8e294d1dc83301ea8b0ffd062;
            z[19] = 0x3bae28d7db673fddad499b12caaa785dd814b55966117734aaf3a64d7680177d;
            z[20] = 0x1935e123a97490bcee5b803aa140ded225fcdb71272679b0d1801a166a2e6dfe;
            z[21] = 0x8766a456101ddffc13d0c0aaff3480050bf322067caa5ec54389815090fa6b43;
            z[22] = 0x50fbd198b1f28741d7fb2917bac9b369be2345ffa81659a6a3abfdbd5ae347b6;
            z[23] = 0x27c428e1ec9557f6a97771769e9baef3083dcf27e485189e542863dfa30620ba;
            z[24] = 0x1859bdfddab9b3334b99bbce554726a35e080db752c66d0798481375269d80db;
            z[25] = 0x6a8e23db8ad4c059de8e193a8276eac8f24e59319c90fd4f1ee4c11afc325f3e;
            z[26] = 0x8a66c3d547a814a05aa2965b2136d4e7a9b1c4410e40735ac9b78b3ead9708f1;
            z[27] = 0x041c11eca8df31bf9ef92b7c1898a40d327684341fbed0e6e495241b6f6a283b;
            z[28] = 0x328b87550b9c46fb93cfc9642bddd54fa21199090135ec916abf487955606f61;
            z[29] = 0x5aa8604c284adedcbee721ec2a751e8e1b15b3e0a0693cabd729cfdf9c610a26;
            z[30] = 0x2387930588f6d8794126ccc837b3fc30fd47c4c2ea7e5826c7a71641aac66662;
            z[31] = 0x1d15f2d82f2865d9f8e87cf462765245048b5c22cc073dfb27136b99e9a20e89;
        for (uint256 l = 0; l < 32; ++l) {
            assertEq(tree.zeros(l), z[l], "the zeros chain moved");
        }
    }

    /// Prints the chain, for regenerating the pinned vector when the hasher changes.
    function test_zzz_printTheChain() public view {
        for (uint256 l = 0; l < 32; ++l) {
            console2.logBytes32(tree.zeros(l));
        }
    }
}
