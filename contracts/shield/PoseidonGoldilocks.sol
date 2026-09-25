// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoseidonGoldilocks} from "./interfaces/IPoseidonGoldilocks.sol";

/// @title PoseidonGoldilocks
/// @notice Poseidon over Goldilocks, width 8, S-box x^7, 32 full rounds, the hash of the NØNOS kernel.
/// @dev The MDS matrix, the round constants and the constructor vectors are those of
///      spec/poseidon-constants.json. See docs/09-tree.md.
contract PoseidonGoldilocks is IPoseidonGoldilocks {
    uint256 internal constant P = 0xFFFFFFFF00000001;
    uint256 internal constant WIDTH = 8;
    uint256 internal constant FULL_ROUNDS = 32;
    uint256 internal constant HASH_ROUNDS = 31; // rounds - 1 for the single-block domain
    uint64 internal constant MASK64 = 0xFFFFFFFFFFFFFFFF;
    uint256 internal constant NOTE_DOMAIN = 1313821765; // 0x4E4F5445, "NOTE"

    // M[j][k], 64 u64 big-endian, row-major
    bytes internal constant MDS =
        hex"1fffffffe0000000c71c71c65555555619999999800000008ba2e8b9a2e8ba2f15555555400000006276276213b13b14edb6db6cc924924a1111111100000000db6db6da924924931fffffffe0000000c71c71c65555555619999999800000008ba2e8b9a2e8ba2f15555555400000006276276213b13b14edb6db6cc924924a2aaaaaaa80000000db6db6da924924931fffffffe0000000c71c71c65555555619999999800000008ba2e8b9a2e8ba2f15555555400000006276276213b13b1433333333000000002aaaaaaa80000000db6db6da924924931fffffffe0000000c71c71c65555555619999999800000008ba2e8b9a2e8ba2f15555555400000003fffffffc000000033333333000000002aaaaaaa80000000db6db6da924924931fffffffe0000000c71c71c65555555619999999800000008ba2e8b9a2e8ba2f55555555000000003fffffffc000000033333333000000002aaaaaaa80000000db6db6da924924931fffffffe0000000c71c71c65555555619999999800000007fffffff8000000055555555000000003fffffffc000000033333333000000002aaaaaaa80000000db6db6da924924931fffffffe0000000c71c71c655555556ffffffff000000007fffffff8000000055555555000000003fffffffc000000033333333000000002aaaaaaa80000000db6db6da924924931fffffffe0000000";
    // RC[r][j], 256 u64 big-endian, row-major
    bytes internal constant RC =
        hex"13a92fe480f7d05f38fc520984299421eaaff1cc8774a6b5a1b20007322a5127c8085ce51764f3d0fd2d3d2ef2def99ec368b0d8ade5b70ef042e10a12470f4da035f85f22d173cc6605207c6e5c41ecd4d05e29f9bf07aa5bbbaf4ff12617ea453721506d7db6e85a83a10bfed0fcf02bead0b4716969e2c8ffb113ae3f4ba10d8caab57615e0ddc28e38e0ee92e46a8378bb1015e9c46efdf73a7722d85a016f14d23c83ecbd2b666ea8221c99a8008be25c271cbf1f4a098044a4bcd4df31fa85f0832eb4b5aec91c9acbb35b3f91ad5e4f9f1409f2b809da5a98886b9c75f8bb227a49261602037d52c975a26454dd969ffca9d54fac12746d923031a0f634d6b99d91141d0618808e8802fd62814432651e8e9a5c1aa0e71cd650d41ecb38fbbf171bea69a42d369b70b0e86771a755746555f7a9683018989f687aa32b09d3d91c58f92848385d3c90016012765963054af81da5c827a2d75d3dfd961020ec7b5ffb1b1aee88d9918f09410fcc93f1830f8a38b8f03789e98d6142875fa889311f0dda543a0f99ed05759106850bd79245af8c0e728e99e246c9a289e398f46e55b98b83cbd9e03f88266273ad4385e3f011b7e1ceb9d214c4a2094baa2910762d678b57048b74764c5b7573b7b961c94a3e5ec6a21bf80a58c1c954d8357ece0619a4be9ccaba544028a5b1edf8e72302fb1bc6c46a71cd2001a6304fe33024540ccda7b8cad73001fbfe46815e159a3e2381eb0419c9aabea2dc1828185bd3664b61a3266e0c7fa41c9e60d65efea8ec1ea9c9cb0c2e101a9f1c8aae1bda88e55a4764e0bf219a86a6f8aa6640c0d964dc54142d97a671c6408b04b74ce388bf4e474a56e3d99a4833fa317ef0ced94929d5f9a0bf1e8f71a451966285408c891e149647888c2caf4b02440fe2204f9d625d10df3de0104e026fe7f59c93016efb540528c87f6ac718aabd87aa32071f065b2b611e25cf9edb76712622eeafdd06920f12e6ebfaf0ae90aa8f3a2fd534897a3c5e83f2f42ad6bf0d2d2acd1d33b885d5f77c4c12bb9a83e3d2b39a84d5af7cd495db5f262b143aad68dd4d130d99bb129b40b150cff11133f3b73297795adb560ea1c016209423e546b531114f7d8201ec7346217998fc15bc98cc9170d9cc21d8223e0be25c2a6031048167e757cadee6fc011eae8f87507e2db3d76200276e57cd7a59473ffb39c4f36ea0baae1f8a671cdb753baa66e17095c623ea16691e06109622c96a8b8a3f818050d9be9ee9854e8ae4d32a41743d3f043a0e1de6de29de1e3aa95861d9f95f0216ebaa5ac3216eec02ee9ee6db12da216a4b5cae9a7afc6fc5699818a16eb476eb935d32e83efed4ec283d27e588c5e91d2f4674897c74d05efd6bdfba49aa4ac6aa1f07e2b6f398e0f83eda998a56aff88468005f8f331ce80f6bbf5d0b65307148324650a3010b5d3e7f5fa3f41ca53077b29a2fdcf7261f247673d7ecd277a4c8545a9253a6fb1881af713167db27d80bdf55a6e65fb547a02592c69d35d490f1c2ab181456da5a1e5638b9313c1a5d9fa7d4c3916c3a728d93de422a89bfc07cdfadcdb905a6c47412efd2cd359bbdb2184611a204d02d2e935b85316c979cd8c83d4e73939961e27ef7f43cedde5e62326214ae0887f5236e5fb4710f6538e6360b18bbc274b5b1247dbf257500747e2552cb555e80255220085d497202862d690516d47401bb27c5271986d09ee055e3df90d993ff889cfcaf03788e005d0afcded948533316ba6e760c42c1b1c256dfe2f0a9280b9a177713e58c1c935d55314d733fe2635e44559ec57b89a854c3d2e0e9203ebc8a48d358d02235a2f499f0601db495a713b5e69a758a38e7fd9009fe151b681242180b1b4775c626009e043fcd1bf7a5b9168f01c61a7b7dd6271ecc9d9d08f569f6b66da45e791e5e8660ea6e351c61c857015b254a5a49d8a8e5697d19ea24d0d62e16bc7dca8428e47e76831a057c9983ac23d5f30338997254a892d91d20977539e9da6dd6b26e32e52f4120819e834878a94fa3a237aa47a1160e9d6aead16f05f3300b4d1d410df710144af8ab87058e200017d129a3871ce6b76d0c9bde5d11898ac035e64c6d0bee618730d78cae38c17c9a9aced80ad33b06c942db6d85b521824fef996ca5a14410336494f206c0981f6da298facfadfb453bfdb93c537ae15c7d1fcabadbfc01e65880e6b30f85b1c006fb057e7ffe3a38fab319837c66405bd212bf4103d6ae1816bf3769c2d9eac1359c05354879545f14947eedab082bfee57d2202ef677025849b256f8be242627a03320f0b7a290f08e49298fc11b901c13c56947a4bdf2d56c410ba2d52b5f71f68a89f1e99e9e375e80f4da301c1342a8eaaa0bfe64f6a7b5fe2cfb16cb136056ed6448c58120039897818872e274a00190c48a741047e348341f41dc3b2f7dcbe3efd7816a91c904f8c5597d6af96b6437df65c80d9265940f91ce6814ac9c71c9a4e36c10ea262fc3d2151b1192046cb26183a150ae124d1b2281105d280928901ccdd1315af56e05748bfed2892380feb932da2fece510199626004c3f50975cc0b9e90efc1bdf0e60803f3d93ee3f8133e0bb2dafd5c382b3ab9383fffd4073e8941880e82369894d807efc0352f60c96fb1038e87d5d42d7631e6b4c74a099a7cfd1ab95dd0d9a5f96c8574007aec4e3a8638e0e1fbe72dccf3afacdab2f336cc397001adb0f6079efd3ba31b47cdd016b6aa59a3202a2ea139050bca7494944c695194836ffcbf5523e0a5716506d1af7016c2dfc3919fddb5524f1b510d46ecd6ac1bd8d9d8c2c1d65768d24988acd3a4b28f8426bb3bfedd442c8081b836531df9e22bccc1d37d1cb08dab7f";

    error NonCanonicalInput();
    error NoteCommitmentSpongeUndefined();
    error KatFailed();

    /// @notice Reverts unless the permutation, the single-block hash and the note commitment match their
    ///         known-answer vectors.
    constructor() {
        uint256[8] memory s;
        s[0] = 1;
        s[1] = 2;
        s[2] = 3;
        s[3] = 4;
        s[4] = 5;
        s[5] = 6;
        s[6] = 7;
        s[7] = 8;
        _permute(s, FULL_ROUNDS);
        if (
            s[0] != 1022089083010806312 || s[1] != 8134804760473441809 || s[2] != 13972665140821454643
                || s[3] != 18290724068579387637
        ) {
            revert KatFailed();
        }

        uint256[8] memory hs;
        hs[0] = 9;
        hs[1] = 10;
        hs[2] = 11;
        hs[3] = 12;
        _permute(hs, HASH_ROUNDS);
        if (
            hs[0] != 7369382236926714597 || hs[1] != 2436301979115149546 || hs[2] != 5720325819700556311
                || hs[3] != 17891017047452629057
        ) {
            revert KatFailed();
        }

        uint256[11] memory cn = [uint256(1), 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
        bytes32 cmKat = _commitNote(cn);
        if (
            cmKat
                != bytes32(
                    uint256(6455909588408588117) | (uint256(11340027322162162298) << 64)
                        | (uint256(9042362242223743603) << 128) | (uint256(14573159163843564693) << 192)
                )
        ) {
            revert KatFailed();
        }
    }

    /// @inheritdoc IPoseidonGoldilocks
    function hash2(bytes32 left, bytes32 right) external pure returns (bytes32) {
        uint256[8] memory s;
        s[0] = _limb(left, 0);
        s[1] = _limb(left, 1);
        s[2] = _limb(left, 2);
        s[3] = _limb(left, 3);
        s[4] = _limb(right, 0);
        s[5] = _limb(right, 1);
        s[6] = _limb(right, 2);
        s[7] = _limb(right, 3);
        for (uint256 i = 0; i < WIDTH; ++i) {
            if (s[i] >= P) revert NonCanonicalInput();
        }
        return _compress8(s);
    }

    /// @inheritdoc IPoseidonGoldilocks
    /// @dev cm = compress(compress(p[0..8]), compress(p[8..16])), p[11] = NOTE_DOMAIN, p[12..16] = 0.
    function commitNote(uint256[11] calldata limbs) external pure returns (bytes32) {
        uint256[11] memory m;
        for (uint256 i = 0; i < 11; ++i) {
            if (limbs[i] >= P) revert NonCanonicalInput();
            m[i] = limbs[i];
        }
        return _commitNote(m);
    }

    /// @inheritdoc IPoseidonGoldilocks
    /// @dev Four inputs only: the kernel defines no multi-block sponge.
    function hashFields(uint256[] calldata limbs) external pure returns (bytes32) {
        if (limbs.length != 4) revert NoteCommitmentSpongeUndefined();
        uint256[8] memory s;
        for (uint256 i = 0; i < 4; ++i) {
            if (limbs[i] >= P) revert NonCanonicalInput();
            s[i] = limbs[i];
        }
        _permute(s, HASH_ROUNDS);
        return _pack(s);
    }

    function _compress8(uint256[8] memory s) private pure returns (bytes32) {
        _permute(s, FULL_ROUNDS);
        return _pack(s);
    }

    // Callers check every limb is below P.
    function _commitNote(uint256[11] memory m) private pure returns (bytes32) {
        uint256[8] memory s0;
        s0[0] = m[0];
        s0[1] = m[1];
        s0[2] = m[2];
        s0[3] = m[3];
        s0[4] = m[4];
        s0[5] = m[5];
        s0[6] = m[6];
        s0[7] = m[7];
        bytes32 d0 = _compress8(s0);

        uint256[8] memory s1;
        s1[0] = m[8];
        s1[1] = m[9];
        s1[2] = m[10];
        s1[3] = NOTE_DOMAIN;
        bytes32 d1 = _compress8(s1);

        uint256[8] memory s2;
        s2[0] = _limb(d0, 0);
        s2[1] = _limb(d0, 1);
        s2[2] = _limb(d0, 2);
        s2[3] = _limb(d0, 3);
        s2[4] = _limb(d1, 0);
        s2[5] = _limb(d1, 1);
        s2[6] = _limb(d1, 2);
        s2[7] = _limb(d1, 3);
        return _compress8(s2);
    }

    // out[j] = RC[r][j] + sum_k M[j][k] * state[k]^7, MDS inlined as literals.
    function _permute(uint256[8] memory s, uint256 numRounds) internal pure {
        bytes memory rcb = RC;
        assembly {
            let p := 0xFFFFFFFF00000001
            let rp := add(rcb, 0x20)
            let t := mload(0x40) // s-box scratch row, reused every round
            mstore(0x40, add(t, 0x100))
            for { let r := 0 } lt(r, numRounds) { r := add(r, 1) } {
                {
                    let x := mload(s)
                    let x2 := mulmod(x, x, p)
                    let x4 := mulmod(x2, x2, p)
                    mstore(t, mulmod(mulmod(x4, x2, p), x, p))
                }
                {
                    let x := mload(add(s, 0x20))
                    let x2 := mulmod(x, x, p)
                    let x4 := mulmod(x2, x2, p)
                    mstore(add(t, 0x20), mulmod(mulmod(x4, x2, p), x, p))
                }
                {
                    let x := mload(add(s, 0x40))
                    let x2 := mulmod(x, x, p)
                    let x4 := mulmod(x2, x2, p)
                    mstore(add(t, 0x40), mulmod(mulmod(x4, x2, p), x, p))
                }
                {
                    let x := mload(add(s, 0x60))
                    let x2 := mulmod(x, x, p)
                    let x4 := mulmod(x2, x2, p)
                    mstore(add(t, 0x60), mulmod(mulmod(x4, x2, p), x, p))
                }
                {
                    let x := mload(add(s, 0x80))
                    let x2 := mulmod(x, x, p)
                    let x4 := mulmod(x2, x2, p)
                    mstore(add(t, 0x80), mulmod(mulmod(x4, x2, p), x, p))
                }
                {
                    let x := mload(add(s, 0xa0))
                    let x2 := mulmod(x, x, p)
                    let x4 := mulmod(x2, x2, p)
                    mstore(add(t, 0xa0), mulmod(mulmod(x4, x2, p), x, p))
                }
                {
                    let x := mload(add(s, 0xc0))
                    let x2 := mulmod(x, x, p)
                    let x4 := mulmod(x2, x2, p)
                    mstore(add(t, 0xc0), mulmod(mulmod(x4, x2, p), x, p))
                }
                {
                    let x := mload(add(s, 0xe0))
                    let x2 := mulmod(x, x, p)
                    let x4 := mulmod(x2, x2, p)
                    mstore(add(t, 0xe0), mulmod(mulmod(x4, x2, p), x, p))
                }
                // rcp starts at byte 64 * r and steps 8 bytes per constant
                let rcp := add(rp, shl(3, shl(3, r)))
                let acc := 0
                    // row 0
                    acc := shr(192, mload(rcp))
                    acc := addmod(acc, mulmod(0x1fffffffe0000000, mload(t), p), p)
                    acc := addmod(acc, mulmod(0xc71c71c655555556, mload(add(t, 0x20)), p), p)
                    acc := addmod(acc, mulmod(0x1999999980000000, mload(add(t, 0x40)), p), p)
                    acc := addmod(acc, mulmod(0x8ba2e8b9a2e8ba2f, mload(add(t, 0x60)), p), p)
                    acc := addmod(acc, mulmod(0x1555555540000000, mload(add(t, 0x80)), p), p)
                    acc := addmod(acc, mulmod(0x6276276213b13b14, mload(add(t, 0xa0)), p), p)
                    acc := addmod(acc, mulmod(0xedb6db6cc924924a, mload(add(t, 0xc0)), p), p)
                    acc := addmod(acc, mulmod(0x1111111100000000, mload(add(t, 0xe0)), p), p)
                    mstore(s, acc)
                    rcp := add(rcp, 8)
                    // row 1
                    acc := shr(192, mload(rcp))
                    acc := addmod(acc, mulmod(0xdb6db6da92492493, mload(t), p), p)
                    acc := addmod(acc, mulmod(0x1fffffffe0000000, mload(add(t, 0x20)), p), p)
                    acc := addmod(acc, mulmod(0xc71c71c655555556, mload(add(t, 0x40)), p), p)
                    acc := addmod(acc, mulmod(0x1999999980000000, mload(add(t, 0x60)), p), p)
                    acc := addmod(acc, mulmod(0x8ba2e8b9a2e8ba2f, mload(add(t, 0x80)), p), p)
                    acc := addmod(acc, mulmod(0x1555555540000000, mload(add(t, 0xa0)), p), p)
                    acc := addmod(acc, mulmod(0x6276276213b13b14, mload(add(t, 0xc0)), p), p)
                    acc := addmod(acc, mulmod(0xedb6db6cc924924a, mload(add(t, 0xe0)), p), p)
                    mstore(add(s, 0x20), acc)
                    rcp := add(rcp, 8)
                    // row 2
                    acc := shr(192, mload(rcp))
                    acc := addmod(acc, mulmod(0x2aaaaaaa80000000, mload(t), p), p)
                    acc := addmod(acc, mulmod(0xdb6db6da92492493, mload(add(t, 0x20)), p), p)
                    acc := addmod(acc, mulmod(0x1fffffffe0000000, mload(add(t, 0x40)), p), p)
                    acc := addmod(acc, mulmod(0xc71c71c655555556, mload(add(t, 0x60)), p), p)
                    acc := addmod(acc, mulmod(0x1999999980000000, mload(add(t, 0x80)), p), p)
                    acc := addmod(acc, mulmod(0x8ba2e8b9a2e8ba2f, mload(add(t, 0xa0)), p), p)
                    acc := addmod(acc, mulmod(0x1555555540000000, mload(add(t, 0xc0)), p), p)
                    acc := addmod(acc, mulmod(0x6276276213b13b14, mload(add(t, 0xe0)), p), p)
                    mstore(add(s, 0x40), acc)
                    rcp := add(rcp, 8)
                    // row 3
                    acc := shr(192, mload(rcp))
                    acc := addmod(acc, mulmod(0x3333333300000000, mload(t), p), p)
                    acc := addmod(acc, mulmod(0x2aaaaaaa80000000, mload(add(t, 0x20)), p), p)
                    acc := addmod(acc, mulmod(0xdb6db6da92492493, mload(add(t, 0x40)), p), p)
                    acc := addmod(acc, mulmod(0x1fffffffe0000000, mload(add(t, 0x60)), p), p)
                    acc := addmod(acc, mulmod(0xc71c71c655555556, mload(add(t, 0x80)), p), p)
                    acc := addmod(acc, mulmod(0x1999999980000000, mload(add(t, 0xa0)), p), p)
                    acc := addmod(acc, mulmod(0x8ba2e8b9a2e8ba2f, mload(add(t, 0xc0)), p), p)
                    acc := addmod(acc, mulmod(0x1555555540000000, mload(add(t, 0xe0)), p), p)
                    mstore(add(s, 0x60), acc)
                    rcp := add(rcp, 8)
                    // row 4
                    acc := shr(192, mload(rcp))
                    acc := addmod(acc, mulmod(0x3fffffffc0000000, mload(t), p), p)
                    acc := addmod(acc, mulmod(0x3333333300000000, mload(add(t, 0x20)), p), p)
                    acc := addmod(acc, mulmod(0x2aaaaaaa80000000, mload(add(t, 0x40)), p), p)
                    acc := addmod(acc, mulmod(0xdb6db6da92492493, mload(add(t, 0x60)), p), p)
                    acc := addmod(acc, mulmod(0x1fffffffe0000000, mload(add(t, 0x80)), p), p)
                    acc := addmod(acc, mulmod(0xc71c71c655555556, mload(add(t, 0xa0)), p), p)
                    acc := addmod(acc, mulmod(0x1999999980000000, mload(add(t, 0xc0)), p), p)
                    acc := addmod(acc, mulmod(0x8ba2e8b9a2e8ba2f, mload(add(t, 0xe0)), p), p)
                    mstore(add(s, 0x80), acc)
                    rcp := add(rcp, 8)
                    // row 5
                    acc := shr(192, mload(rcp))
                    acc := addmod(acc, mulmod(0x5555555500000000, mload(t), p), p)
                    acc := addmod(acc, mulmod(0x3fffffffc0000000, mload(add(t, 0x20)), p), p)
                    acc := addmod(acc, mulmod(0x3333333300000000, mload(add(t, 0x40)), p), p)
                    acc := addmod(acc, mulmod(0x2aaaaaaa80000000, mload(add(t, 0x60)), p), p)
                    acc := addmod(acc, mulmod(0xdb6db6da92492493, mload(add(t, 0x80)), p), p)
                    acc := addmod(acc, mulmod(0x1fffffffe0000000, mload(add(t, 0xa0)), p), p)
                    acc := addmod(acc, mulmod(0xc71c71c655555556, mload(add(t, 0xc0)), p), p)
                    acc := addmod(acc, mulmod(0x1999999980000000, mload(add(t, 0xe0)), p), p)
                    mstore(add(s, 0xa0), acc)
                    rcp := add(rcp, 8)
                    // row 6
                    acc := shr(192, mload(rcp))
                    acc := addmod(acc, mulmod(0x7fffffff80000000, mload(t), p), p)
                    acc := addmod(acc, mulmod(0x5555555500000000, mload(add(t, 0x20)), p), p)
                    acc := addmod(acc, mulmod(0x3fffffffc0000000, mload(add(t, 0x40)), p), p)
                    acc := addmod(acc, mulmod(0x3333333300000000, mload(add(t, 0x60)), p), p)
                    acc := addmod(acc, mulmod(0x2aaaaaaa80000000, mload(add(t, 0x80)), p), p)
                    acc := addmod(acc, mulmod(0xdb6db6da92492493, mload(add(t, 0xa0)), p), p)
                    acc := addmod(acc, mulmod(0x1fffffffe0000000, mload(add(t, 0xc0)), p), p)
                    acc := addmod(acc, mulmod(0xc71c71c655555556, mload(add(t, 0xe0)), p), p)
                    mstore(add(s, 0xc0), acc)
                    rcp := add(rcp, 8)
                    // row 7
                    acc := shr(192, mload(rcp))
                    acc := addmod(acc, mulmod(0xffffffff00000000, mload(t), p), p)
                    acc := addmod(acc, mulmod(0x7fffffff80000000, mload(add(t, 0x20)), p), p)
                    acc := addmod(acc, mulmod(0x5555555500000000, mload(add(t, 0x40)), p), p)
                    acc := addmod(acc, mulmod(0x3fffffffc0000000, mload(add(t, 0x60)), p), p)
                    acc := addmod(acc, mulmod(0x3333333300000000, mload(add(t, 0x80)), p), p)
                    acc := addmod(acc, mulmod(0x2aaaaaaa80000000, mload(add(t, 0xa0)), p), p)
                    acc := addmod(acc, mulmod(0xdb6db6da92492493, mload(add(t, 0xc0)), p), p)
                    acc := addmod(acc, mulmod(0x1fffffffe0000000, mload(add(t, 0xe0)), p), p)
                    mstore(add(s, 0xe0), acc)
            }
        }
    }

    function _decode(bytes memory blob, uint256 n) private pure returns (uint256[64] memory out) {
        for (uint256 i = 0; i < n; ++i) {
            out[i] = _u64(blob, i);
        }
    }

    function _decodeRc(bytes memory blob) private pure returns (uint256[256] memory out) {
        for (uint256 i = 0; i < 256; ++i) {
            out[i] = _u64(blob, i);
        }
    }

    // Caller keeps i < len / 8.
    function _u64(bytes memory blob, uint256 i) private pure returns (uint256 v) {
        assembly {
            v := shr(192, mload(add(add(blob, 0x20), mul(i, 8))))
        }
    }

    // limb 0 is the least significant 64 bits
    function _limb(bytes32 dg, uint256 i) private pure returns (uint256) {
        return (uint256(dg) >> (64 * i)) & MASK64;
    }

    function _pack(uint256[8] memory s) private pure returns (bytes32) {
        return bytes32(s[0] | (s[1] << 64) | (s[2] << 128) | (s[3] << 192));
    }
}
