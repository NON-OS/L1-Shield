// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StarkFieldExt as F} from "./StarkFieldExt.sol";

/// @title StarkTranscript
/// @notice Keccak Fiat-Shamir transcript: every step is state = keccak256(tag || state || data).
/// @dev Tags: digest 0x01, fp 0x02, challenge 0x03, index 0x04, grinding 0x05, fp2 0x06 and 0x07.
///      Limbs are 8 bytes little-endian. The preimage sits unclaimed at the free pointer.
///      Reference twin: test/shield/reference/StarkTranscriptRef.sol. See docs/05-transcript.md.
library StarkTranscript {
    uint256 internal constant P = 0xFFFFFFFF00000001;

    uint256 internal constant TAG_AT = 0;
    uint256 internal constant STATE_AT = 1;
    uint256 internal constant DATA_AT = 33;
    /// @dev Preimage lengths: tag and state alone, and with one 8-byte limb or nonce.
    uint256 internal constant LEN_BARE = 33;
    uint256 internal constant LEN_LIMB = 41;

    uint256 internal constant TAG_DIGEST = 0x01;
    uint256 internal constant TAG_FP = 0x02;
    uint256 internal constant TAG_CHALLENGE_FP = 0x03;
    uint256 internal constant TAG_INDEX = 0x04;
    uint256 internal constant TAG_GRIND = 0x05;
    uint256 internal constant TAG_FP2_C0 = 0x06;
    uint256 internal constant TAG_FP2_C1 = 0x07;

    /// @dev An Fp2 array is a length word, n pointer words, then n cells of two words each.
    uint256 internal constant WORD = 0x20;
    uint256 internal constant CELL = 0x40;

    uint256 internal constant PANIC_SELECTOR = 0x4e487b71;
    uint256 internal constant PANIC_UNDERFLOW = 0x11;

    /// @notice A round nonce missed its grinding bound.
    error RoundGrindRejected(uint256 round);

    struct T {
        bytes32 state;
    }

    function init(bytes memory label) internal pure returns (T memory t) {
        t.state = keccak256(label);
    }

    // state = keccak256(tag || state || data), data copied word by word from a bytes array.
    // Words past the end of data are copied too and land beyond the hashed length.
    function mix(T memory t, uint8 tag, bytes memory data) internal pure {
        assembly {
            let pre := mload(0x40)
            mstore8(add(pre, TAG_AT), tag)
            mstore(add(pre, STATE_AT), mload(t))
            let len := mload(data)
            for { let i := 0 } lt(i, len) { i := add(i, WORD) } {
                mstore(add(add(pre, DATA_AT), i), mload(add(add(data, WORD), i)))
            }
            mstore(t, keccak256(pre, add(DATA_AT, len)))
        }
    }

    function absorbDigest(T memory t, bytes32 digest) internal pure {
        absorbDigest(t, digest, 32);
    }

    // The first w bytes of a left-aligned digest, absorbed unpadded.
    function absorbDigest(T memory t, bytes32 digest, uint256 w) internal pure {
        assembly {
            let pre := mload(0x40)
            mstore8(add(pre, TAG_AT), TAG_DIGEST)
            mstore(add(pre, STATE_AT), mload(t))
            mstore(add(pre, DATA_AT), digest)
            mstore(t, keccak256(pre, add(DATA_AT, w)))
        }
    }

    // The low 64 bits of value, little-endian.
    function absorbFp(T memory t, uint256 value) internal pure {
        assembly {
            let pre := mload(0x40)
            mstore8(add(pre, TAG_AT), TAG_FP)
            mstore(add(pre, STATE_AT), mload(t))
            mstore(add(pre, DATA_AT), shl(192, _le64(value)))
            mstore(t, keccak256(pre, LEN_LIMB))

            // the low eight bytes of w, byte-reversed into the low eight bytes of r
            function _le64(w) -> r {
                w := and(w, 0xFFFFFFFFFFFFFFFF)
                w := or(shr(8, and(w, 0xFF00FF00FF00FF00)), shl(8, and(w, 0x00FF00FF00FF00FF)))
                w := or(shr(16, and(w, 0xFFFF0000FFFF0000)), shl(16, and(w, 0x0000FFFF0000FFFF)))
                r := or(shr(32, w), and(shl(32, w), 0xFFFFFFFF00000000))
            }
        }
    }

    /// @notice absorbFp over every word of a flat array, in order.
    /// @dev The tag byte is written once: each step rewrites only the state and the limb, and
    ///      neither reaches pre + TAG_AT. Two limbs per iteration, since an iteration's own cost
    ///      is near that of a limb.
    function absorbFpArray(T memory t, uint256[] memory a) internal pure {
        assembly {
            let pre := mload(0x40)
            let s := mload(t)
            let n := mload(a)
            let src := add(a, WORD)
            let end := add(src, mul(n, WORD))
            mstore8(add(pre, TAG_AT), TAG_FP)
            let stAt := add(pre, STATE_AT)
            let dAt := add(pre, DATA_AT)
            if and(n, 1) {
                mstore(stAt, s)
                mstore(dAt, shl(192, _le64(mload(src))))
                s := keccak256(pre, LEN_LIMB)
                src := add(src, WORD)
            }
            for {} lt(src, end) { src := add(src, CELL) } {
                mstore(stAt, s)
                mstore(dAt, shl(192, _le64(mload(src))))
                s := keccak256(pre, LEN_LIMB)
                mstore(stAt, s)
                mstore(dAt, shl(192, _le64(mload(add(src, WORD)))))
                s := keccak256(pre, LEN_LIMB)
            }
            mstore(t, s)

            function _le64(w) -> r {
                w := and(w, 0xFFFFFFFFFFFFFFFF)
                w := or(shr(8, and(w, 0xFF00FF00FF00FF00)), shl(8, and(w, 0x00FF00FF00FF00FF)))
                w := or(shr(16, and(w, 0xFFFF0000FFFF0000)), shl(16, and(w, 0x0000FFFF0000FFFF)))
                r := or(shr(32, w), and(shl(32, w), 0xFFFFFFFF00000000))
            }
        }
    }

    /// @notice absorbFp over nLimbs 8-byte little-endian limbs read straight from calldata at
    ///         p[off..]. The wire bytes are the preimage bytes, so nothing is decoded.
    /// @dev Bounds and canonical form are the caller's to check, on the same bytes.
    function absorbFpWire(T memory t, bytes calldata p, uint256 off, uint256 nLimbs) internal pure {
        assembly {
            let pre := mload(0x40)
            let s := mload(t)
            let src := add(p.offset, off)
            let end := add(src, mul(nLimbs, 8))
            mstore8(add(pre, TAG_AT), TAG_FP)
            let stAt := add(pre, STATE_AT)
            let dAt := add(pre, DATA_AT)
            for {} lt(src, end) { src := add(src, 8) } {
                mstore(stAt, s)
                // a whole word is loaded, and only its first eight bytes are hashed
                mstore(dAt, calldataload(src))
                s := keccak256(pre, LEN_LIMB)
            }
            mstore(t, s)
        }
    }

    // squeeze_u64(tag): mix(tag, []) then state[0..8] as u64 LE
    function squeezeU64(T memory t, uint8 tag) internal pure returns (uint64 r) {
        assembly {
            let pre := mload(0x40)
            mstore8(add(pre, TAG_AT), tag)
            mstore(add(pre, STATE_AT), mload(t))
            let h := keccak256(pre, LEN_BARE)
            mstore(t, h)
            let w := shr(192, h)
            w := or(shr(8, and(w, 0xFF00FF00FF00FF00)), shl(8, and(w, 0x00FF00FF00FF00FF)))
            w := or(shr(16, and(w, 0xFFFF0000FFFF0000)), shl(16, and(w, 0x0000FFFF0000FFFF)))
            r := or(shr(32, w), and(shl(32, w), 0xFFFFFFFF00000000))
        }
    }

    // beta and gamma on the base codec. The extension codec draws them with challengeFp2, and
    // the codec is fixed per deployment because the draw width shifts every later challenge.
    function challengeFp(T memory t) internal pure returns (uint256) {
        return _fromU64(squeezeU64(t, uint8(TAG_CHALLENGE_FP)));
    }

    function challengeFp2(T memory t) internal pure returns (F.Fp2 memory) {
        uint256 c0 = _fromU64(squeezeU64(t, uint8(TAG_FP2_C0)));
        uint256 c1 = _fromU64(squeezeU64(t, uint8(TAG_FP2_C1)));
        return F.Fp2(c0, c1);
    }

    /// @notice n challengeFp2 draws into a new Fp2 array.
    /// @dev Allocates the array as the Fp2[] layout: length, n pointers, n two-word cells, and
    ///      moves the free pointer past the cells. The preimage then sits at the new free pointer.
    ///      The two tags alternate, so each squeeze rewrites the tag byte it needs.
    function challengeFp2Batch(T memory t, uint256 n) internal pure returns (F.Fp2[] memory out) {
        assembly {
            out := mload(0x40)
            mstore(out, n)
            let ptr := add(out, WORD)
            let cell := add(ptr, mul(n, WORD))
            let end := add(cell, mul(n, CELL))
            mstore(0x40, end)
            let pre := end
            let stAt := add(pre, STATE_AT)
            let s := mload(t)
            for {} lt(cell, end) {
                cell := add(cell, CELL)
                ptr := add(ptr, WORD)
            } {
                mstore(ptr, cell)
                mstore8(pre, TAG_FP2_C0)
                mstore(stAt, s)
                s := keccak256(pre, LEN_BARE)
                mstore(cell, _draw(s))
                mstore8(pre, TAG_FP2_C1)
                mstore(stAt, s)
                s := keccak256(pre, LEN_BARE)
                mstore(add(cell, WORD), _draw(s))
            }
            mstore(t, s)

            // the state's first eight bytes as a little-endian u64, reduced once
            function _draw(h) -> r {
                let w := shr(192, h)
                w := or(shr(8, and(w, 0xFF00FF00FF00FF00)), shl(8, and(w, 0x00FF00FF00FF00FF)))
                w := or(shr(16, and(w, 0xFFFF0000FFFF0000)), shl(16, and(w, 0x0000FFFF0000FFFF)))
                r := or(shr(32, w), and(shl(32, w), 0xFFFFFFFF00000000))
                if iszero(lt(r, P)) { r := sub(r, P) }
            }
        }
    }

    // Same preimages as a loop of absorbFp over both limbs of each element.
    function absorbFp2Array(T memory t, F.Fp2[] memory a) internal pure {
        assembly {
            let pre := mload(0x40)
            let s := mload(t)
            let ptr := add(a, WORD)
            let end := add(ptr, mul(mload(a), WORD))
            mstore8(add(pre, TAG_AT), TAG_FP)
            let stAt := add(pre, STATE_AT)
            let dAt := add(pre, DATA_AT)
            for {} lt(ptr, end) { ptr := add(ptr, WORD) } {
                let cell := mload(ptr)
                mstore(stAt, s)
                mstore(dAt, shl(192, _le64(mload(cell))))
                s := keccak256(pre, LEN_LIMB)
                mstore(stAt, s)
                mstore(dAt, shl(192, _le64(mload(add(cell, WORD)))))
                s := keccak256(pre, LEN_LIMB)
            }
            mstore(t, s)

            function _le64(w) -> r {
                w := and(w, 0xFFFFFFFFFFFFFFFF)
                w := or(shr(8, and(w, 0xFF00FF00FF00FF00)), shl(8, and(w, 0x00FF00FF00FF00FF)))
                w := or(shr(16, and(w, 0xFFFF0000FFFF0000)), shl(16, and(w, 0x0000FFFF0000FFFF)))
                r := or(shr(32, w), and(shl(32, w), 0xFFFFFFFF00000000))
            }
        }
    }

    // Same state trajectory as challengeFp2Batch, values discarded.
    function skipChallengeFp2(T memory t, uint256 n) internal pure {
        assembly {
            let pre := mload(0x40)
            let stAt := add(pre, STATE_AT)
            let s := mload(t)
            for {} n { n := sub(n, 1) } {
                mstore8(pre, TAG_FP2_C0)
                mstore(stAt, s)
                s := keccak256(pre, LEN_BARE)
                mstore8(pre, TAG_FP2_C1)
                mstore(stAt, s)
                s := keccak256(pre, LEN_BARE)
            }
            mstore(t, s)
        }
    }

    /// @notice 1, a, a^2, ..., a^(n-1) as a new Fp2 array, in the layout challengeFp2Batch returns.
    /// @dev Allocates length, n pointers and n cells, and moves the free pointer past the cells.
    function powers(F.Fp2 memory a, uint256 n) internal pure returns (F.Fp2[] memory out) {
        uint256 a0 = a.c0;
        uint256 a1 = a.c1;
        assembly {
            out := mload(0x40)
            mstore(out, n)
            let ptr := add(out, WORD)
            let cell := add(ptr, mul(n, WORD))
            let end := add(cell, mul(n, CELL))
            mstore(0x40, end)
            let x0 := 1
            let x1 := 0
            for {} lt(cell, end) {
                cell := add(cell, CELL)
                ptr := add(ptr, WORD)
            } {
                mstore(ptr, cell)
                mstore(cell, x0)
                mstore(add(cell, WORD), x1)
                // (x0 + x1 X)(a0 + a1 X), X^2 = 7, as GoldilocksCore.mul2
                let y0 := addmod(mulmod(x0, a0, P), mulmod(7, mulmod(x1, a1, P), P), P)
                x1 := addmod(mulmod(x0, a1, P), mulmod(x1, a0, P), P)
                x0 := y0
            }
        }
    }

    // Masked, so bound must be a power of two.
    function challengeIndex(T memory t, uint256 bound) internal pure returns (uint256) {
        return uint256(squeezeU64(t, uint8(TAG_INDEX))) & (bound - 1);
    }

    // pow_word = keccak256(0x05 || state || nonce_le)[0..8] as u64 LE. State advances only on success.
    // leading_zeros(pow_word) >= bits  <=>  pow_word < 2^(64 - bits)
    function verifyPow(T memory t, uint64 nonce, uint32 bits) internal pure returns (bool ok) {
        assembly {
            let pre := mload(0x40)
            mstore8(add(pre, TAG_AT), TAG_GRIND)
            mstore(add(pre, STATE_AT), mload(t))
            let w := nonce
            w := or(shr(8, and(w, 0xFF00FF00FF00FF00)), shl(8, and(w, 0x00FF00FF00FF00FF)))
            w := or(shr(16, and(w, 0xFFFF0000FFFF0000)), shl(16, and(w, 0x0000FFFF0000FFFF)))
            w := or(shr(32, w), and(shl(32, w), 0xFFFFFFFF00000000))
            mstore(add(pre, DATA_AT), shl(192, w))
            let h := keccak256(pre, LEN_LIMB)
            let v := shr(192, h)
            v := or(shr(8, and(v, 0xFF00FF00FF00FF00)), shl(8, and(v, 0x00FF00FF00FF00FF)))
            v := or(shr(16, and(v, 0xFFFF0000FFFF0000)), shl(16, and(v, 0x0000FFFF0000FFFF)))
            v := or(shr(32, v), and(shl(32, v), 0xFFFFFFFF00000000))
            // 64 - bits in uint32 underflows past 64 bits: the same Panic(0x11), in scratch 0x00..0x24
            if gt(bits, 64) {
                mstore(0x00, shl(224, PANIC_SELECTOR))
                mstore(0x04, PANIC_UNDERFLOW)
                revert(0x00, 0x24)
            }
            ok := or(iszero(bits), iszero(shr(sub(64, bits), v)))
            if ok { mstore(t, h) }
        }
    }

    /// @notice verifyPow for FRI round `round`, reverting instead of returning false.
    function grindRound(T memory t, uint64 nonce, uint32 bits, uint256 round) internal pure {
        if (!verifyPow(t, nonce, bits)) revert RoundGrindRejected(round);
    }

    function _fromU64(uint64 x) private pure returns (uint256) {
        return uint256(x) >= P ? uint256(x) - P : uint256(x);
    }
}
