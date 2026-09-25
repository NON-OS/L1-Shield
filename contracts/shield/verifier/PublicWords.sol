// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PublicWords
/// @notice Maps the pool's public words to the Goldilocks limbs the transcript absorbs.
/// @dev Words 0..5 are 4-limb digests, low limb first, and words 6..9 one limb each. At 12 words,
///      the launch intent, each address word fits 160 bits and splits into 48 + 48 + 48 + 16 bits,
///      so an address has one encoding. At 11 words, word 10 splits into four 64-bit limbs.
library PublicWords {
    uint256 internal constant P = 0xFFFFFFFF00000001;
    uint256 internal constant LIMB = 0xFFFFFFFFFFFFFFFF;
    uint256 internal constant INTENT_WORDS = 11;
    uint256 internal constant INTENT_WORDS_FEE_RECIPIENT = 12;
    uint256 internal constant LIMBS_PER_INTENT = 32;
    uint256 internal constant ADDRESS_LIMB = 0xFFFFFFFFFFFF; // 2^48 - 1

    error BadPublicLayout(uint256 length);
    error BadIntentWidth(uint256 perIntent);
    error NonCanonicalLimb(uint256 word, uint256 limb, uint256 value);

    function limbs(uint256 perIntent) internal pure returns (uint256) {
        if (perIntent != INTENT_WORDS && perIntent != INTENT_WORDS_FEE_RECIPIENT) revert BadIntentWidth(perIntent);
        return 4 * perIntent - 12; // 32 or 36: four per digest or address word, one per scalar word
    }

    /// @notice Expands N x 11 public words into N x 32 limbs. Reverts on a partial batch or any limb >= p.
    function publicsOf(uint256[] calldata publicInputs) internal pure returns (uint256[] memory) {
        return publicsOf(publicInputs, INTENT_WORDS);
    }

    /// @notice Expands N x perIntent public words into N x limbs(perIntent) limbs. Reverts on a
    ///         width other than 11 or 12, a partial batch, or any limb >= p.
    function publicsOf(uint256[] calldata publicInputs, uint256 perIntent)
        internal
        pure
        returns (uint256[] memory out)
    {
        uint256 width = limbs(perIntent);
        if (publicInputs.length == 0 || publicInputs.length % perIntent != 0) {
            revert BadPublicLayout(publicInputs.length);
        }
        uint256 n = publicInputs.length / perIntent;
        out = new uint256[](n * width);
        uint256 k;
        bool narrowAddresses = perIntent == INTENT_WORDS_FEE_RECIPIENT;
        for (uint256 i = 0; i < n; ++i) {
            uint256 base = i * perIntent;
            for (uint256 w = 0; w < perIntent; ++w) {
                uint256 word = publicInputs[base + w];
                if (narrowAddresses && w >= 10) {
                    if (word >> 160 != 0) revert NonCanonicalLimb(base + w, 3, word >> 144);
                    out[k++] = word & ADDRESS_LIMB;
                    out[k++] = (word >> 48) & ADDRESS_LIMB;
                    out[k++] = (word >> 96) & ADDRESS_LIMB;
                    out[k++] = word >> 144;
                } else if (w <= 5 || w >= 10) {
                    for (uint256 l = 0; l < 4; ++l) {
                        uint256 v = (word >> (64 * l)) & LIMB;
                        if (v >= P) revert NonCanonicalLimb(base + w, l, v);
                        out[k++] = v;
                    }
                } else {
                    if (word >= P) revert NonCanonicalLimb(base + w, 0, word);
                    out[k++] = word;
                }
            }
        }
    }
}
