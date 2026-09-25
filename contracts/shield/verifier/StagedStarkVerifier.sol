// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IStarkVerifier} from "../interfaces/IStarkVerifier.sol";
import {RealSplitVerifier} from "./RealSplitVerifier.sol";
import {PublicWords} from "./PublicWords.sol";

/// @title StagedStarkVerifier
/// @notice Batch-size routing and soundness figures for the IStarkVerifier adapters. The concrete
///         adapter supplies verifyBatch.
abstract contract StagedStarkVerifier is IStarkVerifier {
    address public immutable settler;

    /// @notice Intent count => verifier for that batch size, fixed at construction.
    mapping(uint256 => RealSplitVerifier) public verifierForSize;
    /// @notice Batch sizes served, in constructor order.
    uint256[] public sizes;

    /// @notice Declared FRI parameters for one batch size, outer and inner stage.
    struct Soundness {
        uint16 outerQueries;
        uint16 outerExtraBlowupBits;
        uint16 outerGrindBits;
        uint16 innerQueries;
        uint16 innerExtraBlowupBits;
        uint16 innerGrindBits;
    }

    mapping(uint256 => Soundness) public soundnessForSize;

    event SoundnessDeclared(
        uint256 indexed intents,
        uint256 conjecturedBits,
        uint256 provableBits,
        uint16 innerExtraBlowupBits,
        bytes32 innerPeriodicRoot
    );

    error NoVerifierForSize(uint256 intents);
    error BadConstruction();
    error SoundnessMismatch(uint256 intents);

    constructor(
        uint256[] memory sizes_,
        RealSplitVerifier[] memory verifiers_,
        Soundness[] memory soundness_,
        address settler_
    ) {
        if (sizes_.length == 0 || sizes_.length != verifiers_.length || sizes_.length != soundness_.length) {
            revert BadConstruction();
        }
        settler = settler_;
        for (uint256 i = 0; i < sizes_.length; ++i) {
            if (sizes_[i] == 0 || address(verifiers_[i]) == address(0)) revert BadConstruction();
            if (address(verifierForSize[sizes_[i]]) != address(0)) revert BadConstruction();

            Soundness memory s = soundness_[i];
            // Outer params must match what the deployed verifier enforces.
            if (s.outerQueries != verifiers_[i].nq() || s.outerGrindBits != verifiers_[i].grindBits()) {
                revert SoundnessMismatch(sizes_[i]);
            }
            // A circuit proved directly for the chain declares zero inner queries.
            if (verifiers_[i].periodicRoot() == bytes32(0)) revert BadConstruction();
            if (_stageConjectured(s.outerQueries, s.outerExtraBlowupBits, s.outerGrindBits) == 0) {
                revert BadConstruction();
            }

            verifierForSize[sizes_[i]] = verifiers_[i];
            soundnessForSize[sizes_[i]] = s;
            sizes.push(sizes_[i]);
            (uint256 c, uint256 pv) = _bits(s, verifiers_[i]);
            emit SoundnessDeclared(sizes_[i], c, pv, s.innerExtraBlowupBits, verifiers_[i].periodicRoot());
        }
    }

    function _stageConjectured(uint16 q, uint16 extra, uint16 grind) private pure returns (uint256) {
        return uint256(q) * (uint256(extra) + 1) + uint256(grind);
    }

    function _stageProvable(uint16 q, uint16 extra, uint16 grind) private pure returns (uint256) {
        return uint256(q) * (uint256(extra) + 1) / 2 + uint256(grind);
    }

    // The outer stage under the full bound (Johnson regime, list parameter m = 3, challenges in
    // K = Fp2, rate rho = 2^-(extra + 1), domain N = 2^logDomain), in millionths of a bit:
    //   query phase   q (log2(1/rho) / 2 - log2(1 + 1/(2m))) + final grind
    //   commit phase  log2 |K| - log2((m + 1/2)^7 N^2 / (3 rho^1.5)) + per-round grind
    // Constants round so the figure errs low. s searches of b bits count as b + floor(log2 s).
    uint256 internal constant MICRO = 1e6;
    /// @dev log2(7/6) = 0.2223924..., rounded up.
    uint256 internal constant JOHNSON_LOSS = 222_393;
    /// @dev 2 log2(p) for p = 2^64 - 2^32 + 1, a hair under 128, rounded down.
    uint256 internal constant LOG_K = 127_999_999;
    /// @dev 7 log2(3.5) - log2(3) = 11.0660892..., rounded up.
    uint256 internal constant COMMIT_CONST = 11_066_090;

    function _outerTerms(Soundness memory s, RealSplitVerifier v)
        private
        view
        returns (uint256 query, uint256 commit)
    {
        uint256 rateBits = uint256(s.outerExtraBlowupBits) + 1;
        query = uint256(s.outerQueries) * (rateBits * MICRO / 2 - JOHNSON_LOSS)
            + (uint256(s.outerGrindBits) + _log2(v.finalSearches())) * MICRO;
        uint256 cost = COMMIT_CONST + 2 * v.logDomain() * MICRO + 3 * rateBits * MICRO / 2;
        commit = LOG_K > cost ? LOG_K - cost : 0;
        commit += v.roundGrindBits() * MICRO;
    }

    // The weaker stage, and within the outer stage the weaker term.
    function _bits(Soundness memory s, RealSplitVerifier v)
        private
        view
        returns (uint256 conjectured, uint256 provable)
    {
        (uint256 query, uint256 commit) = _outerTerms(s, v);
        uint256 grind = s.outerGrindBits + _log2(v.finalSearches());
        conjectured = uint256(s.outerQueries) * (uint256(s.outerExtraBlowupBits) + 1) + grind;
        provable = (query < commit ? query : commit) / MICRO;
        if (s.innerQueries != 0) {
            uint256 ic = _stageConjectured(s.innerQueries, s.innerExtraBlowupBits, s.innerGrindBits);
            uint256 ip = _stageProvable(s.innerQueries, s.innerExtraBlowupBits, s.innerGrindBits);
            if (ic < conjectured) conjectured = ic;
            if (ip < provable) provable = ip;
        }
    }

    function _log2(uint256 x) private pure returns (uint256 r) {
        while (x > 1) {
            x >>= 1;
            ++r;
        }
    }

    /// @notice The outer stage's two terms under the full bound, in millionths of a bit.
    function soundnessTermsForSize(uint256 intents) external view returns (uint256 queryPhase, uint256 commitPhase) {
        RealSplitVerifier v = verifierForSize[intents];
        if (address(v) == address(0)) revert NoVerifierForSize(intents);
        return _outerTerms(soundnessForSize[intents], v);
    }

    /// @notice Soundness bits for one batch size, with and without the FRI conjecture.
    function soundnessBitsForSize(uint256 intents)
        public
        view
        returns (uint256 conjectured, uint256 provable)
    {
        if (address(verifierForSize[intents]) == address(0)) revert NoVerifierForSize(intents);
        return _bits(soundnessForSize[intents], verifierForSize[intents]);
    }

    /// @notice Soundness of the weakest batch size. The pool does not read it.
    function soundnessBits() external view returns (uint256 conjectured, uint256 provable) {
        conjectured = type(uint256).max;
        provable = type(uint256).max;
        for (uint256 i = 0; i < sizes.length; ++i) {
            (uint256 c, uint256 p) = _bits(soundnessForSize[sizes[i]], verifierForSize[sizes[i]]);
            if (c < conjectured) conjectured = c;
            if (p < provable) provable = p;
        }
    }

    function sizeCount() external view returns (uint256) {
        return sizes.length;
    }

    /// @notice Prefix tag of a whole proof: abi.encode(ONE_CALL, head, claims, queries, word, word).
    ///         The two trailing words are never read.
    bytes32 public constant ONE_CALL = keccak256("NONOS-SHIELD-ONE-CALL-v1");

    function _field(bytes calldata proof, uint256 i) internal pure returns (bytes calldata) {
        uint256 off = uint256(bytes32(proof[32 * i:32 * i + 32]));
        uint256 len = uint256(bytes32(proof[off:off + 32]));
        return proof[off + 32:off + 32 + len];
    }
}
