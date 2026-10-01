// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

import {IStarkVerifier} from "../../interfaces/IStarkVerifier.sol";
import {IStarkSoundness} from "../../interfaces/IStarkSoundness.sol";
import {RealQueryVerify as V} from "../RealQueryVerify.sol";
import {PublicWords} from "../PublicWords.sol";
import {IProgramFormEvaluator} from "../IProgramFormEvaluator.sol";

interface IShapeWalk {
    function prep() external view returns (address);

    function verifyWholeComposed(
        bytes calldata head,
        bytes calldata claims,
        bytes calldata queries,
        uint256[] calldata publics,
        address ev
    ) external view returns (bool);
}

interface IChunkedEvaluator {
    function chunks() external view returns (address[] memory);
}

interface IShapedPrepare {
    function shape() external view returns (V.Shape memory);

    function shapeId() external view returns (uint256);
}

/// @title ComposedStarkVerifierShapes
/// @notice The format 7 adapter: one intent per proof, a fixed set of query shapes (docs/16), one compiled
///         walk per shape. A proof names its shape by its parameter id (docs/17: no shape byte on the
///         wire), carried in the ONE_CALL encoding's first trailing word. An id not in the set is refused.
/// @dev Soundness is declared per shape and round by round under the 2020 proximity gaps (BCIKS20),
///      in millionths of a bit, rounded so the figure errs low. The provable figure of a shape is the
///      weakest of its rounds; the pool reads the weakest shape, since a prover picks its shape.
///        query phase  q (log2(1/rho) / 2 - log2(1 + 1/(2m))) + chunk bits + log2(chunks)
///        commit       log2 |K| - log2((m + 1/2)^7 N^2 / (3 rho^1.5)) + round grind - log2(radix - 1)
///        DEEP         the same line term + the DEEP grind: independent coefficients, no curve factor
///      At rate 1/64, N = 2^23, radix 8, a 21-bit round grind and a 19-bit DEEP grind: commit 80.127,
///      DEEP 80.934, queries 80.775 (A, 19 at 8 x 25), 80.997 (A', 18 at 8 x 28), 80.219 (B, 17 at
///      8 x 30). Every shape declares 80 whole bits.
contract ComposedStarkVerifierShapes is IStarkVerifier, IStarkSoundness {
    uint256 internal constant MICRO = 1e6;
    uint256 internal constant JOHNSON_LOSS = 222_393; // log2(7/6), up
    uint256 internal constant LOG_K = 127_999_999; // 2 log2 p, down
    uint256 internal constant COMMIT_CONST = 11_066_090; // 7 log2(3.5) - log2(3), up

    uint256 public constant LOG_DOMAIN = 23;
    uint256 public constant RATE_BITS = 6;
    uint256 public constant RADIX = 8;
    uint256 public constant ROUND_GRIND = 21;
    uint256 public constant DEEP_GRIND = 19;

    bytes32 public constant ONE_CALL = keccak256("NONOS-SHIELD-ONE-CALL-v1");

    struct Shape {
        IShapeWalk walk;
        uint16 queries;
        uint16 chunkBits;
        uint16 chunks;
    }

    IProgramFormEvaluator public immutable evaluator;
    uint256 public immutable wordsPerIntent;
    address public immutable settler;

    mapping(uint256 => Shape) public shapeOf;
    uint256[] public shapeIds;
    /// @notice parameter id => shape id (1, 2, 3); zero for an id not accepted.
    mapping(bytes32 => uint256) public shapeOfParams;
    /// @dev conjectured << 128 | provable, whole bits, per shape id
    mapping(uint256 => uint256) internal figures;
    uint256 internal weakest;

    mapping(bytes32 => bytes32) public attested;

    /// @notice keccak256 of the evaluator image this stack was generated from (MANIFEST.md). The
    ///         image itself is not on chain: the code hashes below are, and each was checked against
    ///         the value the deployment computed from the build of that image.
    bytes32 public immutable imageHash;
    /// @dev the contracts of the stack, in codeHashes order, and their runtime code hashes
    address[] internal stack_;
    bytes32[] internal codeHashes_;

    event ShapeDeclared(uint256 indexed id, address walk, uint256 conjecturedBits, uint256 provableBits);
    event Attested(bytes32 indexed digest, bytes32 indexed batchHash);

    error BadConstruction();
    error ShapeMismatch(uint256 id);
    error NoVerifierForSize(uint256 intents);
    error NoShape(uint256 id);
    error NotAccepted();
    error CodeMismatch(uint256 index, address at, bytes32 expected, bytes32 actual);

    constructor(
        IProgramFormEvaluator evaluator_,
        uint256 wordsPerIntent_,
        address settler_,
        uint256[] memory ids,
        bytes32[] memory paramIds,
        Shape[] memory shapes,
        bytes32 imageHash_,
        bytes32[] memory codeHashes
    ) {
        if (
            address(evaluator_) == address(0) || ids.length == 0 || ids.length != shapes.length
                || ids.length != paramIds.length
        ) revert BadConstruction();
        PublicWords.limbs(wordsPerIntent_);
        evaluator = evaluator_;
        wordsPerIntent = wordsPerIntent_;
        settler = settler_;
        uint256 lowC = type(uint256).max;
        uint256 lowP = type(uint256).max;
        for (uint256 i = 0; i < ids.length; ++i) {
            Shape memory s = shapes[i];
            if (ids[i] == 0 || ids[i] > 255 || address(shapeOf[ids[i]].walk) != address(0)) revert BadConstruction();
            if (address(s.walk) == address(0) || s.queries == 0 || s.chunks == 0) revert BadConstruction();
            if (paramIds[i] == bytes32(0) || shapeOfParams[paramIds[i]] != 0) revert BadConstruction();
            // the declared figures must describe the code that verifies
            V.Shape memory w = IShapedPrepare(s.walk.prep()).shape();
            if (
                w.nq != s.queries || w.grindBits != s.chunkBits || w.finalSearches != s.chunks
                    || w.roundGrindBits != ROUND_GRIND || w.friRadix != RADIX || w.logDomain != LOG_DOMAIN
                    || w.digestBytes != 32 || w.powerDeep || IShapedPrepare(s.walk.prep()).shapeId() != ids[i]
            ) revert ShapeMismatch(ids[i]);
            shapeOfParams[paramIds[i]] = ids[i];
            shapeOf[ids[i]] = s;
            shapeIds.push(ids[i]);
            (uint256 c, uint256 p) = _bits(s);
            figures[ids[i]] = c << 128 | p;
            if (c < lowC) lowC = c;
            if (p < lowP) lowP = p;
            emit ShapeDeclared(ids[i], address(s.walk), c, p);
        }
        weakest = lowC << 128 | lowP;
        imageHash = imageHash_;
        _bindCode(address(evaluator_), ids, codeHashes);
    }

    /// @dev The stack is the evaluator, its code chunks, then each shape's prepare and walk in id
    ///      order. Every one must carry exactly the code hash the deployment computed from the build.
    function _bindCode(address ev, uint256[] memory ids, bytes32[] memory expected) private {
        if (imageHash == bytes32(0)) revert BadConstruction();
        address[] memory ch = IChunkedEvaluator(ev).chunks();
        stack_.push(ev);
        for (uint256 i = 0; i < ch.length; ++i) {
            stack_.push(ch[i]);
        }
        for (uint256 i = 0; i < ids.length; ++i) {
            address w = address(shapeOf[ids[i]].walk);
            stack_.push(IShapeWalk(w).prep());
            stack_.push(w);
        }
        if (expected.length != stack_.length) revert BadConstruction();
        for (uint256 i = 0; i < expected.length; ++i) {
            bytes32 h = stack_[i].codehash;
            if (h != expected[i] || stack_[i].code.length == 0) revert CodeMismatch(i, stack_[i], expected[i], h);
            codeHashes_.push(h);
        }
    }

    /// @notice The contracts of the stack and their runtime code hashes: the evaluator, its chunks,
    ///         then each shape's prepare and walk. One call to check a deployment against MANIFEST.md.
    function stack() external view returns (bytes32 image, address[] memory at, bytes32[] memory codeHashes) {
        return (imageHash, stack_, codeHashes_);
    }

    // ------------------------------------------------------------------ soundness

    /// @notice A shape's three terms in millionths of a bit: query phase, commit (first fold), DEEP.
    function soundnessTermsForShape(uint256 id) public view returns (uint256 query, uint256 commit, uint256 deep) {
        Shape memory s = shapeOf[id];
        if (address(s.walk) == address(0)) revert NoShape(id);
        return _terms(s);
    }

    /// @notice A shape's figures in whole bits, with and without the FRI conjecture.
    function soundnessBitsForShape(uint256 id) external view returns (uint256 conjectured, uint256 provable) {
        uint256 f = figures[id];
        if (f == 0) revert NoShape(id);
        return (f >> 128, uint128(f));
    }

    /// @inheritdoc IStarkSoundness
    function soundnessBits() external view returns (uint256 conjectured, uint256 provable) {
        return (weakest >> 128, uint128(weakest));
    }

    /// @inheritdoc IStarkSoundness
    function soundnessBitsForSize(uint256 intents) external view returns (uint256 conjectured, uint256 provable) {
        if (intents != 1) revert NoVerifierForSize(intents);
        return (weakest >> 128, uint128(weakest));
    }

    function shapeCount() external view returns (uint256) {
        return shapeIds.length;
    }

    function _terms(Shape memory s) internal pure returns (uint256 query, uint256 commit, uint256 deep) {
        query = uint256(s.queries) * (RATE_BITS * MICRO / 2 - JOHNSON_LOSS)
            + (uint256(s.chunkBits) + _log2(s.chunks)) * MICRO;
        uint256 line = LOG_K - (COMMIT_CONST + 2 * LOG_DOMAIN * MICRO + 3 * RATE_BITS * MICRO / 2);
        commit = line + ROUND_GRIND * MICRO - _log2MicroUp(RADIX - 1);
        deep = line + DEEP_GRIND * MICRO;
    }

    function _bits(Shape memory s) internal pure returns (uint256 conjectured, uint256 provable) {
        (uint256 q, uint256 c, uint256 d) = _terms(s);
        provable = q < c ? q : c;
        if (d < provable) provable = d;
        provable /= MICRO;
        conjectured = uint256(s.queries) * RATE_BITS + s.chunkBits + _log2(s.chunks);
    }

    // log2 x in millionths, rounded up (StagedStarkVerifier._log2MicroUp)
    function _log2MicroUp(uint256 x) internal pure returns (uint256) {
        uint256 k = _log2(x);
        uint256 y = (x << 127) >> k;
        uint256 frac;
        for (uint256 i = 0; i < 30; ++i) {
            y = (y * y) >> 127;
            frac <<= 1;
            if (y >= 1 << 128) {
                y >>= 1;
                frac |= 1;
            }
        }
        return k * MICRO + ((frac * MICRO) >> 30) + 1;
    }

    function _log2(uint256 x) internal pure returns (uint256 r) {
        while (x > 1) {
            x >>= 1;
            ++r;
        }
    }

    // ------------------------------------------------------------------ verification

    /// @notice Accepts a whole proof of a shape in the set, or the digest of one `attest` accepted
    ///         for this batch. A shape not in the set is refused.
    function verifyBatch(bytes calldata proof, uint256[] calldata publicInputs) external view returns (bool) {
        if (proof.length == 32) {
            bytes32 d = attested[bytes32(proof)];
            return d != bytes32(0) && d == keccak256(abi.encode(publicInputs));
        }
        if (proof.length <= 192 || bytes32(proof[:32]) != ONE_CALL) return false;
        return _whole(proof, publicInputs);
    }

    /// @notice Verifies a whole proof and records its digest, for the pool's constructor self-test.
    function attest(bytes calldata proof, uint256[] calldata publicInputs) external returns (bytes32 digest) {
        if (proof.length <= 192 || bytes32(proof[:32]) != ONE_CALL) revert NotAccepted();
        if (!_whole(proof, publicInputs)) revert NotAccepted();
        digest = keccak256(proof);
        attested[digest] = keccak256(abi.encode(publicInputs));
        emit Attested(digest, attested[digest]);
    }

    function _whole(bytes calldata proof, uint256[] calldata publicInputs) private view returns (bool) {
        uint256 k = wordsPerIntent;
        if (publicInputs.length != k) return false;
        IShapeWalk w = shapeOf[shapeOfParams[bytes32(proof[128:160])]].walk;
        if (address(w) == address(0)) return false;
        return w.verifyWholeComposed(
            _field(proof, 1), _field(proof, 2), _field(proof, 3), PublicWords.publicsOf(publicInputs, k), address(evaluator)
        );
    }

    function _field(bytes calldata proof, uint256 i) internal pure returns (bytes calldata) {
        uint256 off = uint256(bytes32(proof[32 * i:32 * i + 32]));
        uint256 len = uint256(bytes32(proof[off:off + 32]));
        return proof[off + 32:off + 32 + len];
    }
}
