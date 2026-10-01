// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {StagedStarkVerifier} from "./StagedStarkVerifier.sol";
import {RealSplitVerifier} from "./RealSplitVerifier.sol";
import {PublicWords} from "./PublicWords.sol";
import {IProgramFormEvaluator} from "./IProgramFormEvaluator.sol";

/// @title ComposedStarkVerifier
/// @notice The pool's verifier: a whole proof per call, comp_z computed on chain by `evaluator`.
/// @dev A 32-byte digest verifies only after `attest` accepted the whole proof for that batch.
contract ComposedStarkVerifier is StagedStarkVerifier {
    /// @notice The contract that evaluates the constraints of the circuit at z.
    IProgramFormEvaluator public immutable evaluator;
    /// @notice Public words per intent, 12 with a fee recipient. It must match the pool.
    uint256 public immutable wordsPerIntent;

    /// @notice Digest of a proof verified by `attest`, mapped to keccak256 of its ABI-encoded batch.
    mapping(bytes32 => bytes32) public attested;

    event Attested(bytes32 indexed digest, bytes32 indexed batchHash);

    error ZeroEvaluator();
    error NotAccepted();

    constructor(
        uint256[] memory sizes_,
        RealSplitVerifier[] memory verifiers_,
        Soundness[] memory soundness_,
        address settler_,
        IProgramFormEvaluator evaluator_,
        uint256 wordsPerIntent_
    ) StagedStarkVerifier(sizes_, verifiers_, soundness_, settler_) {
        if (address(evaluator_) == address(0)) revert ZeroEvaluator();
        evaluator = evaluator_;
        PublicWords.limbs(wordsPerIntent_); // refuses any width but 11 or 12
        wordsPerIntent = wordsPerIntent_;
    }

    /// @notice Accepts a whole proof, or the digest of one `attest` accepted for this batch.
    function verifyBatch(bytes calldata proof, uint256[] calldata publicInputs)
        external
        view
        override
        returns (bool)
    {
        if (proof.length == 32) {
            bytes32 d = attested[bytes32(proof)];
            return d != bytes32(0) && d == keccak256(abi.encode(publicInputs));
        }
        if (proof.length <= 192 || bytes32(proof[:32]) != ONE_CALL) return false;
        return _composedWhole(proof, publicInputs);
    }

    /// @notice Verifies a whole proof and records its digest, for the pool's constructor self-test.
    function attest(bytes calldata proof, uint256[] calldata publicInputs) external returns (bytes32 digest) {
        if (proof.length <= 192 || bytes32(proof[:32]) != ONE_CALL) revert NotAccepted();
        if (!_composedWhole(proof, publicInputs)) revert NotAccepted();
        digest = keccak256(proof);
        attested[digest] = keccak256(abi.encode(publicInputs));
        emit Attested(digest, attested[digest]);
    }

    function _composedWhole(bytes calldata proof, uint256[] calldata publicInputs) private view returns (bool) {
        uint256 k = wordsPerIntent;
        if (publicInputs.length == 0 || publicInputs.length % k != 0) return false;
        RealSplitVerifier v = verifierForSize[publicInputs.length / k];
        if (address(v) == address(0)) return false;
        return v.verifyWholeComposed(
            _field(proof, 1), _field(proof, 2), _field(proof, 3), PublicWords.publicsOf(publicInputs, k), evaluator
        );
    }
}
