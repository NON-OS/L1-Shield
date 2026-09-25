// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {Test} from "forge-std/Test.sol";
import {PublicWords} from "../../../contracts/shield/verifier/PublicWords.sol";

/// Calls the library from calldata, the only way it is called.
contract PublicWordsHarness {
    function expand(uint256[] calldata words, uint256 perIntent) external pure returns (uint256[] memory) {
        return PublicWords.publicsOf(words, perIntent);
    }
}

/// Halmos checks of the public-word to limb expansion at 11 words (32 limbs) and 12 (36 limbs).
/// Words 0..5 are four-limb digests, words 6..9 one limb. Word 10 is four 64-bit limbs at 11 words,
/// and words 10 and 11 are addresses split 48 + 48 + 48 + 16 bits at 12.
/// @custom:halmos --loop 64
contract PublicWordsHalmos is SymTest, Test {
    uint256 constant P = 0xFFFFFFFF00000001;
    uint256 constant M = 0xFFFFFFFFFFFFFFFF;

    PublicWordsHarness h;

    function setUp() public {
        h = new PublicWordsHarness();
    }

    function _width(bool twelve) internal pure returns (uint256) {
        return twelve ? PublicWords.INTENT_WORDS_FEE_RECIPIENT : PublicWords.INTENT_WORDS;
    }

    function _words(uint256[12] memory w, uint256 n) internal pure returns (uint256[] memory a) {
        a = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            a[i] = w[i];
        }
    }

    function _isDigestWord(uint256 i) internal pure returns (bool) {
        return i <= 5 || i >= 10;
    }

    function _canonicalWord(uint256 i, uint256 v, bool twelve) internal pure returns (bool) {
        if (twelve && i >= 10) return v >> 160 == 0;
        if (!_isDigestWord(i)) return v < P;
        return (v & M) < P && ((v >> 64) & M) < P && ((v >> 128) & M) < P && (v >> 192) < P;
    }

    function _roundTrip(uint256[12] memory w, uint256 n) internal view {
        bool twelve = n == PublicWords.INTENT_WORDS_FEE_RECIPIENT;
        for (uint256 i = 0; i < n; ++i) {
            vm.assume(_canonicalWord(i, w[i], twelve));
        }
        uint256[] memory limbs = h.expand(_words(w, n), n);
        assert(limbs.length == 4 * n - 12);
        uint256 k;
        for (uint256 i = 0; i < n; ++i) {
            uint256 packed;
            if (twelve && i >= 10) {
                for (uint256 l = 0; l < 4; ++l) {
                    assert(limbs[k] < P);
                    packed |= limbs[k++] << (48 * l);
                }
            } else if (_isDigestWord(i)) {
                for (uint256 l = 0; l < 4; ++l) {
                    assert(limbs[k] < P);
                    packed |= limbs[k++] << (64 * l);
                }
            } else {
                assert(limbs[k] < P);
                packed = limbs[k++];
            }
            assert(packed == w[i]);
        }
    }

    /// Canonical 11-word intents expand to 32 limbs and pack back to the same words.
    function check_canonicalWordsRoundTrip11(uint256[12] memory w) public view {
        _roundTrip(w, PublicWords.INTENT_WORDS);
    }

    /// The same at 12 words, 36 limbs, the addresses repacked from their 48-bit limbs.
    function check_canonicalWordsRoundTrip12(uint256[12] memory w) public view {
        _roundTrip(w, PublicWords.INTENT_WORDS_FEE_RECIPIENT);
    }

    // one word set to v at index `at`, matched and never used as a memory offset
    function _oneWord(uint256 at, uint256 v, uint256 n) internal pure returns (uint256[] memory a) {
        a = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            if (i == at) a[i] = v;
        }
    }

    function _refused(uint256[] memory words, uint256 n) internal view {
        try h.expand(words, n) {
            assert(false);
        } catch {}
    }

    /// A single-limb word (amount, fee, asset, price) at or above p is refused at both widths.
    function check_aNonCanonicalScalarWordIsRefused(uint256 v, uint8 which) public view {
        vm.assume(v >= P);
        uint256 at = 6 + (which % 4);
        _refused(_oneWord(at, v, 11), 11);
        _refused(_oneWord(at, v, 12), 12);
    }

    /// A digest word with any one limb at or above p is refused, whichever word and limb it is. At 12
    /// words an address word is refused only above bit 160, so limbs 0 and 1 of words 10 and 11 pass.
    function check_aNonCanonicalDigestLimbIsRefused(uint64 bad, uint8 which, uint8 limb) public view {
        vm.assume(bad >= P);
        uint256 i = which % 8; // digest words 0..5, 10, 11
        uint256 at = i <= 5 ? i : i + 4;
        uint256 v = uint256(bad) << (64 * (limb % 4));
        if (at < 11) _refused(_oneWord(at, v, 11), 11);
        if (at < 10 || limb % 4 >= 2) _refused(_oneWord(at, v, 12), 12);
    }

    /// A batch that is not a whole number of intents is refused, at both widths.
    function check_aPartialIntentIsRefused() public view {
        for (uint256 len = 0; len < 12; ++len) {
            if (len != 11) _refused(new uint256[](len), 11);
            _refused(new uint256[](len), 12);
        }
    }

    /// Any width other than 11 or 12 is refused.
    function check_anyOtherWidthIsRefused(uint8 perIntent) public view {
        vm.assume(perIntent != 11 && perIntent != 12);
        _refused(new uint256[](24), perIntent);
    }
}
