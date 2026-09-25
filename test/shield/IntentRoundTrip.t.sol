// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PublicWords} from "../../contracts/shield/verifier/PublicWords.sol";

/// @notice The prover's 32 public limbs rebuild into the pool's 11 intent words and expand back
/// through `publicsOf` unchanged. Vector from spec/emit-real, the 704/1,114 shape. The 12-word
/// layout adds the fee recipient as limbs 32 to 35.
contract IntentRoundTripTest is Test {
    /// All 32 emitted limbs round-trip through the pool's word layout.
    function test_theProofsStatementIsAnIntentThePoolCanRead() public view {
        uint256[] memory limbs = vm.parseJsonUintArray(vm.readFile("spec/emit-real/transitions-z.json"), ".publics");
        assertEq(limbs.length, PublicWords.LIMBS_PER_INTENT, "not one intent's worth of limbs");

        // six digests, then four scalars, then the recipient: the frozen layout
        uint256[] memory words = new uint256[](PublicWords.INTENT_WORDS);
        for (uint256 i = 0; i < 6; ++i) {
            words[i] = _pack(limbs, 4 * i);
        }
        for (uint256 j = 0; j < 4; ++j) {
            words[6 + j] = limbs[24 + j];
        }
        words[10] = _pack(limbs, 28);

        // the decoded statement
        assertEq(words[6], 200, "public amount");
        assertEq(words[7], 100, "fee");
        assertEq(words[8], 0, "asset");
        assertEq(words[9], 1000000, "clearing price");
        assertEq(words[10], 0xBEEF, "recipient");

        uint256[] memory back = this.expand(words);
        assertEq(back.length, limbs.length, "expansion changed the limb count");
        for (uint256 i = 0; i < limbs.length; ++i) {
            assertEq(back[i], limbs[i], "the pool's expansion disagrees with the prover's limbs");
        }
        console2.log("32 of 32 limbs round-trip");
    }

    /// The two widths and their limb counts. Anything else is refused.
    function test_limbsPerIntentForEachWidth() public {
        assertEq(this.limbsOf(11), 32);
        assertEq(this.limbsOf(12), 36);
        vm.expectRevert(abi.encodeWithSelector(PublicWords.BadIntentWidth.selector, 10));
        this.limbsOf(10);
        vm.expectRevert(abi.encodeWithSelector(PublicWords.BadIntentWidth.selector, 13));
        this.limbsOf(13);
    }

    /// The first 11 words expand to the same 32 limbs at either width.
    function test_theTwelveWordLayoutExtendsTheElevenWordOne() public view {
        uint256[] memory limbs = vm.parseJsonUintArray(vm.readFile("spec/emit-real/transitions-z.json"), ".publics");
        uint256[] memory w11 = new uint256[](11);
        uint256[] memory w12 = new uint256[](12);
        for (uint256 i = 0; i < 6; ++i) {
            w11[i] = _pack(limbs, 4 * i);
        }
        for (uint256 j = 0; j < 4; ++j) {
            w11[6 + j] = limbs[24 + j];
        }
        w11[10] = _pack(limbs, 28);
        for (uint256 i = 0; i < 11; ++i) {
            w12[i] = w11[i];
        }
        uint256[] memory a = this.expand(w11);
        uint256[] memory b = this.expandAt(w12, 12);
        assertEq(b.length, 36);
        for (uint256 i = 0; i < 32; ++i) {
            assertEq(a[i], b[i], "the widths disagree on a shared limb");
        }
    }

    /// Word 11 carries the fee recipient as an address, like word 10: limbs 32 to 35 split it at
    /// 48-bit boundaries, 48 + 48 + 48 + 16, so every limb is below p.
    function test_theFeeRecipientIsLimbsThirtyTwoToThirtyFive() public view {
        uint256[] memory words = new uint256[](12);
        address fr = 0xFeEdfAceCAFeBeEfDeADbeef0123456789ABCDEF;
        uint256 a = uint256(uint160(fr));
        words[11] = a;
        uint256[] memory limbs = this.expandAt(words, 12);
        assertEq(limbs.length, 36);
        uint256 m = (1 << 48) - 1;
        assertEq(limbs[32], a & m, "bits 0..47");
        assertEq(limbs[33], (a >> 48) & m, "bits 48..95");
        assertEq(limbs[34], (a >> 96) & m, "bits 96..143");
        assertEq(limbs[35], a >> 144, "bits 144..159");
        for (uint256 i = 0; i < 32; ++i) {
            assertEq(limbs[i], 0, "word 11 leaked into another limb");
        }
    }

    /// An address word wider than 160 bits is refused: no address encodes to it.
    function test_aFeeRecipientWiderThanAnAddressIsRefused() public {
        uint256[] memory words = new uint256[](12);
        words[11] = uint256(1) << 160;
        vm.expectRevert(abi.encodeWithSelector(PublicWords.NonCanonicalLimb.selector, 11, 3, uint256(1) << 16));
        this.expandAt(words, 12);
    }

    /// Each width refuses a batch that is not a whole number of its intents.
    function test_eachWidthRefusesTheOthersBatch() public {
        uint256[] memory eleven = new uint256[](11);
        vm.expectRevert(abi.encodeWithSelector(PublicWords.BadPublicLayout.selector, 11));
        this.expandAt(eleven, 12);
        uint256[] memory twelve = new uint256[](12);
        vm.expectRevert(abi.encodeWithSelector(PublicWords.BadPublicLayout.selector, 12));
        this.expand(twelve);
    }

    /// External hops so `publicsOf` reads calldata, as it does from the adapter.
    function expand(uint256[] calldata words) external pure returns (uint256[] memory) {
        return PublicWords.publicsOf(words);
    }

    function expandAt(uint256[] calldata words, uint256 perIntent) external pure returns (uint256[] memory) {
        return PublicWords.publicsOf(words, perIntent);
    }

    function limbsOf(uint256 perIntent) external pure returns (uint256) {
        return PublicWords.limbs(perIntent);
    }

    function _pack(uint256[] memory l, uint256 o) private pure returns (uint256) {
        return l[o] | (l[o + 1] << 64) | (l[o + 2] << 128) | (l[o + 3] << 192);
    }
}
