// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StarkFieldExt as F} from "../../../contracts/shield/verifier/StarkFieldExt.sol";

/// @title StarkTranscriptRef
/// @notice The Solidity twin of contracts/shield/verifier/StarkTranscript.sol, written from the
///         transcript's definition, state = keccak256(tag || state || data), with no assembly.
///         Test-only, never deployed.
library StarkTranscriptRef {
    uint256 internal constant P = 0xFFFFFFFF00000001;

    error RoundGrindRejected(uint256 round);

    struct T {
        bytes32 state;
    }

    function init(bytes memory label) internal pure returns (T memory t) {
        t.state = keccak256(label);
    }

    function mix(T memory t, uint8 tag, bytes memory data) internal pure {
        t.state = keccak256(abi.encodePacked(tag, t.state, data));
    }

    function _le8(uint256 v) internal pure returns (bytes8 r) {
        uint64 x = uint64(v);
        bytes memory b = new bytes(8);
        for (uint256 i = 0; i < 8; ++i) b[i] = bytes1(uint8(x >> (8 * i)));
        r = bytes8(b);
    }

    function _u64le(bytes32 h) internal pure returns (uint64 r) {
        for (uint256 i = 0; i < 8; ++i) r |= uint64(uint8(h[i])) << uint64(8 * i);
    }

    function absorbDigest(T memory t, bytes32 digest, uint256 w) internal pure {
        bytes memory d = new bytes(w);
        for (uint256 i = 0; i < w; ++i) d[i] = digest[i];
        t.state = keccak256(abi.encodePacked(uint8(0x01), t.state, d));
    }

    function absorbFp(T memory t, uint256 value) internal pure {
        t.state = keccak256(abi.encodePacked(uint8(0x02), t.state, _le8(value)));
    }

    function absorbFpArray(T memory t, uint256[] memory a) internal pure {
        for (uint256 i = 0; i < a.length; ++i) absorbFp(t, a[i]);
    }

    function absorbFpWire(T memory t, bytes memory wire) internal pure {
        for (uint256 i = 0; i + 8 <= wire.length; i += 8) {
            bytes memory limb = new bytes(8);
            for (uint256 k = 0; k < 8; ++k) limb[k] = wire[i + k];
            t.state = keccak256(abi.encodePacked(uint8(0x02), t.state, limb));
        }
    }

    function absorbFp2Array(T memory t, F.Fp2[] memory a) internal pure {
        for (uint256 i = 0; i < a.length; ++i) {
            absorbFp(t, a[i].c0);
            absorbFp(t, a[i].c1);
        }
    }

    function squeezeU64(T memory t, uint8 tag) internal pure returns (uint64) {
        t.state = keccak256(abi.encodePacked(tag, t.state));
        return _u64le(t.state);
    }

    function _reduce(uint64 x) internal pure returns (uint256) {
        return uint256(x) >= P ? uint256(x) - P : uint256(x);
    }

    function challengeFp(T memory t) internal pure returns (uint256) {
        return _reduce(squeezeU64(t, 0x03));
    }

    function challengeFp2(T memory t) internal pure returns (F.Fp2 memory r) {
        r.c0 = _reduce(squeezeU64(t, 0x06));
        r.c1 = _reduce(squeezeU64(t, 0x07));
    }

    function challengeFp2Batch(T memory t, uint256 n) internal pure returns (F.Fp2[] memory out) {
        out = new F.Fp2[](n);
        for (uint256 i = 0; i < n; ++i) out[i] = challengeFp2(t);
    }

    function skipChallengeFp2(T memory t, uint256 n) internal pure {
        for (uint256 i = 0; i < n; ++i) challengeFp2(t);
    }

    function powers(F.Fp2 memory a, uint256 n) internal pure returns (F.Fp2[] memory out) {
        out = new F.Fp2[](n);
        F.Fp2 memory x = F.Fp2(1, 0);
        for (uint256 i = 0; i < n; ++i) {
            out[i] = x;
            x = F.Fp2(
                addmod(mulmod(x.c0, a.c0, P), mulmod(7, mulmod(x.c1, a.c1, P), P), P),
                addmod(mulmod(x.c0, a.c1, P), mulmod(x.c1, a.c0, P), P)
            );
        }
    }

    function challengeIndex(T memory t, uint256 bound) internal pure returns (uint256) {
        return uint256(squeezeU64(t, 0x04)) & (bound - 1);
    }

    function verifyPow(T memory t, uint64 nonce, uint32 bits) internal pure returns (bool) {
        bytes32 h = keccak256(abi.encodePacked(uint8(0x05), t.state, _le8(nonce)));
        uint64 powWord = _u64le(h);
        if (bits != 0 && (uint256(powWord) >> (64 - bits)) != 0) return false;
        t.state = h;
        return true;
    }

    function grindRound(T memory t, uint64 nonce, uint32 bits, uint256 round) internal pure {
        if (!verifyPow(t, nonce, bits)) revert RoundGrindRejected(round);
    }
}
