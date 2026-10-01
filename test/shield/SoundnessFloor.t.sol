// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase} from "./ShieldTestBase.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";
import {IStarkVerifier} from "../../contracts/shield/interfaces/IStarkVerifier.sol";
import {IPoseidonGoldilocks} from "../../contracts/shield/interfaces/IPoseidonGoldilocks.sol";

/// A verifier that accepts everything and publishes no soundness figure.
contract SilentVerifier is IStarkVerifier {
    function verifyBatch(bytes calldata, uint256[] calldata) external pure returns (bool) {
        return true;
    }
}

/// The pool deploys only on a verifier whose weakest provable figure reaches 80 bits, and settles
/// a batch only when the figure for its size does.
contract SoundnessFloorTest is ShieldTestBase {
    function _deploy(IStarkVerifier v) internal returns (ShieldedPool) {
        return _deploy(v, _selfTest());
    }

    function _deploy(IStarkVerifier v, ShieldedPool.DeploymentSelfTest memory st) internal returns (ShieldedPool) {
        ShieldedPool made = new ShieldedPool(
            safe,
            v,
            IPoseidonGoldilocks(address(hasher)),
            registry,
            address(feeRouter),
            0,
            0,
            0,
            12,
            st
        );
        etchLaunchAmountRules(made);
        return made;
    }

    function _pair() internal returns (uint256[] memory w) {
        TIntent[] memory intents = new TIntent[](2);
        intents[0] = newIntent(0, 0, address(0), 0);
        intents[1] = newIntent(0, 0, address(0), 0);
        w = encodeBatch(pool.currentRoot(), assocRoot, 0, intents);
    }

    /// The floor is 80 bits and a verifier at 80 deploys.
    function test_aVerifierAtTheFloorDeploys() public {
        assertEq(pool.SOUNDNESS_FLOOR_BITS(), 80);
        verifier.setProvableBits(80);
        _deploy(IStarkVerifier(address(verifier)));
    }

    /// A verifier whose weakest size is 79 bits provable is refused at construction.
    function test_aVerifierUnderTheFloorIsRefused() public {
        verifier.setProvableBits(79);
        ShieldedPool.DeploymentSelfTest memory st = _selfTest();
        vm.expectRevert(abi.encodeWithSelector(ShieldedPool.SoundnessBelowFloor.selector, 0, 79));
        _deploy(IStarkVerifier(address(verifier)), st);
    }

    /// A verifier that publishes no figure is refused at construction.
    function test_aVerifierWithoutAFigureIsRefused() public {
        IStarkVerifier silent = new SilentVerifier();
        ShieldedPool.DeploymentSelfTest memory st = _selfTest();
        vm.expectRevert();
        _deploy(silent, st);
    }

    /// A batch whose size falls under the floor is refused and spends nothing.
    function test_aBatchUnderTheFloorIsRefused() public {
        depositNative(alice, 1 ether);
        uint256[] memory w = singleTransfer();
        verifier.setProvableBitsForSize(1, 79);
        vm.expectRevert(abi.encodeWithSelector(ShieldedPool.SoundnessBelowFloor.selector, 1, 79));
        settle(w);
        assertFalse(pool.nullifierSpent(bytes32(w[2])));
    }

    /// The floor is read per batch size. A weak size blocks only its own batches.
    function test_theFloorIsPerBatchSize() public {
        depositNative(alice, 1 ether);
        verifier.setProvableBitsForSize(2, 79);
        uint256[] memory two = _pair();
        vm.expectRevert(abi.encodeWithSelector(ShieldedPool.SoundnessBelowFloor.selector, 2, 79));
        settle(two);
        uint256[] memory one = singleTransfer();
        settle(one);
        assertTrue(pool.nullifierSpent(bytes32(one[2])));
    }

    /// A batch settles when its provable figure is 80 or more and is refused under 80.
    function testFuzz_theFloorBoundary(uint256 bits) public {
        bits = bound(bits, 1, 256);
        depositNative(alice, 1 ether);
        uint256[] memory w = singleTransfer();
        verifier.setProvableBitsForSize(1, bits);
        if (bits < 80) vm.expectRevert(abi.encodeWithSelector(ShieldedPool.SoundnessBelowFloor.selector, 1, bits));
        settle(w);
        assertEq(pool.nullifierSpent(bytes32(w[2])), bits >= 80);
    }
}
