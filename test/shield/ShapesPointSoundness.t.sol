// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {LaunchBase} from "./LaunchBase.sol";
import {RealSplitVerifier} from "../../contracts/shield/verifier/RealSplitVerifier.sol";
import {StagedStarkVerifier} from "../../contracts/shield/verifier/StagedStarkVerifier.sol";
import {ComposedStarkVerifier} from "../../contracts/shield/verifier/ComposedStarkVerifier.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";
import {IStarkVerifier} from "../../contracts/shield/interfaces/IStarkVerifier.sol";
import {IPoseidonGoldilocks} from "../../contracts/shield/interfaces/IPoseidonGoldilocks.sol";
import {IAssociationSetRegistry} from "../../contracts/shield/interfaces/IAssociationSetRegistry.sol";
import {MockPoseidonGoldilocks} from "./mocks/MockPoseidonGoldilocks.sol";
import {ShapesPointVerifier} from "./mocks/ShapesPointVerifier.sol";

/// The format 7 point under BCIKS20 alone: rate 1/64, 17 queries at a 33-bit grind, radix-8 folds at a
/// 21-bit grind, independent DEEP coefficients at a 19-bit grind, exact challenge draws. Every round
/// clears 80, the weakest is the first fold at 80.13, and the pool's floor lets it through.
contract ShapesPointSoundnessTest is LaunchBase {
    ShapesPointVerifier internal pt;
    IPoseidonGoldilocks internal hasher;

    function _shapesAdapter() internal returns (ComposedStarkVerifier) {
        uint256[] memory sizes = new uint256[](1);
        sizes[0] = 1;
        RealSplitVerifier[] memory vs = new RealSplitVerifier[](1);
        vs[0] = RealSplitVerifier(address(pt));
        StagedStarkVerifier.Soundness[] memory sd = new StagedStarkVerifier.Soundness[](1);
        sd[0] = StagedStarkVerifier.Soundness(17, 5, 33, 0, 0, 0);
        return new ComposedStarkVerifier(sizes, vs, sd, address(0), ev, WORDS);
    }

    function _pool(ComposedStarkVerifier adapter) internal returns (ShieldedPool) {
        ShieldedPool.DeploymentSelfTest memory st;
        return new ShieldedPool(
            makeAddr("safe"),
            IStarkVerifier(address(adapter)),
            hasher,
            IAssociationSetRegistry(makeAddr("registry")),
            makeAddr("router"),
            0,
            0,
            1,
            WORDS,
            st
        );
    }

    function setUp() public override {
        super.setUp();
        pt = new ShapesPointVerifier();
        // the tree's constructor hashes before the floor is read, so the hasher must be real code
        hasher = IPoseidonGoldilocks(address(new MockPoseidonGoldilocks()));
    }

    function test_theShapesPointIsEightyBits() public {
        ComposedStarkVerifier a2 = _shapesAdapter();
        (uint256 query, uint256 commit) = a2.soundnessTermsForSize(1);
        // 17 (3 - log2(7/6)) + 33
        assertEq(query, 80_219_319, "query phase");
        // 61.933909 - log2 7 + 21: a radix-8 fold is a curve of degree 7
        assertEq(commit, 80_126_554, "first fold, the weakest round");
        // 61.933909 + 19: independent coefficients are one line's error
        assertEq(a2.soundnessDeepTermForSize(1), 80_933_909, "DEEP round");
        (uint256 conjectured, uint256 provable) = a2.soundnessBits();
        assertEq(provable, 80, "80.13, whole bits");
        assertEq(conjectured, 17 * 6 + 33, "conjectured");
    }

    /// The format 7 point passes the pool's floor: construction goes on to the hasher self-test, which the
    /// empty self-test vector fails.
    function test_theShapesPointPassesThePoolFloor() public {
        ComposedStarkVerifier a2 = _shapesAdapter();
        vm.expectRevert(ShieldedPool.HasherSelfTestFailed.selector);
        _pool(a2);
    }

    /// Each piece of the format 7 point is needed: without it one round falls under 80 and the pool
    /// refuses the adapter.
    function test_everyPieceOfTheShapesPointIsNeeded() public {
        // a 20-bit round grind: the radix-8 fold is 79.13
        pt.set(20, 19, true, 8);
        _refused(79);
        // an 18-bit DEEP grind: 79.93
        pt.set(21, 18, true, 8);
        _refused(79);
        // draws by reduction mod p: both Fp2 rounds lose 2 bits in the worst case
        pt.set(21, 19, false, 8);
        _refused(78);
        // radix 4 with the same grinds clears 80 on the fold, 81.35
        pt.set(21, 19, true, 4);
        (, uint256 commit) = _shapesAdapter().soundnessTermsForSize(1);
        assertEq(commit, 81_348_946);
    }

    function _refused(uint256 bits) internal {
        ComposedStarkVerifier a2 = _shapesAdapter();
        vm.expectRevert(abi.encodeWithSelector(ShieldedPool.SoundnessBelowFloor.selector, 0, bits));
        _pool(a2);
    }
}
