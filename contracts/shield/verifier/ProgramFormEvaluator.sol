// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProgramFormEvaluator} from "./IProgramFormEvaluator.sol";
import {ProgramFormAir as Air, ProgramFormSlots as Slots} from "./ProgramFormAir.sol";
import {ProgramFormProgram as Prog} from "./ProgramFormProgram.sol";

/// @title ProgramFormImage
/// @notice The two ways a circuit's image reaches the evaluator's constructor.
library ProgramFormImage {
    /// @notice The tape checked against its hash, then compiled with its boundary part.
    function compiled(
        bytes memory tape_,
        bytes32 tapeHash,
        uint256 tapeLength,
        bytes memory boundaries,
        bytes32 slotsTapeHash,
        bytes memory slots,
        uint256 nChallenges
    ) internal pure returns (bytes memory) {
        if (tape_.length != tapeLength || keccak256(tape_) != tapeHash) {
            revert ProgramFormEvaluatorBase.TapeMismatch();
        }
        if (slotsTapeHash != tapeHash) revert ProgramFormEvaluatorBase.SlotsNotForThisTape();
        return Air.compile(bytes.concat(tape_, boundaries), slots, ARENA, nChallenges);
    }

    /// @notice An image compiled ahead of time, taken only if it hashes to the circuit's pin.
    /// @dev For a circuit whose compile costs more gas than one transaction carries.
    function pinned(bytes memory image_, bytes32 imageHash) internal pure returns (bytes memory) {
        if (keccak256(image_) != imageHash) revert ProgramFormEvaluatorBase.ImageMismatch();
        return image_;
    }
}

/// @dev The arena start, the first byte past reserved memory. Every image is compiled against it.
uint256 constant ARENA = 0x80;

/// @title ProgramFormEvaluatorBase
/// @notice A program-form circuit's constraints at z, pin k read from public word k.
/// @dev Each circuit is a concrete contract, so its code fixes the circuit. The image lives in data
///      contracts and is copied whole on each call. `evaluate` checks the free pointer is at ARENA.
abstract contract ProgramFormEvaluatorBase is IProgramFormEvaluator {
    /// @dev A data contract's code is a STOP byte then the data, within the EIP-170 limit.
    uint256 private constant CODE_LIMIT = 24576;
    uint256 private constant CHUNK = CODE_LIMIT - 1;
    /// @dev Initcode ahead of the data: ten bytes that copy what follows and return it.
    uint256 private constant INIT_HEAD = 11;

    address private immutable IMAGE_A;
    address private immutable IMAGE_B;
    uint256 private immutable LEN_A;
    uint256 private immutable LEN_B;
    uint256 private immutable IMAGE_AT;
    uint256 private immutable N_FRAME;
    uint256 private immutable N_PER;
    uint256 private immutable N_ALPHA;
    /// @notice Public words 0 to N_PUBLIC - 1, each read by a pin. 36 for the launch circuit.
    uint256 public immutable N_PUBLIC;

    /// @notice The transition part does not hash to the circuit's tape hash.
    error TapeMismatch();
    /// @notice The image does not hash to the circuit's pin.
    error ImageMismatch();
    /// @notice ProgramFormSlots was generated for another tape.
    error SlotsNotForThisTape();
    error ImageTooLarge();
    error ImageNotDeployed();
    error NotThisCircuit();
    error MemoryInUse();
    /// @notice The pins do not read public words 0 to n - 1, each of them.
    error PinsNotContiguous();

    constructor(bytes memory compiled) {
        uint256 nPub = _word(compiled, Air.H_N_PUB);
        if (nPub == 0 || nPub > 255 || _word(compiled, Air.H_PINS) != (1 << nPub) - 1) revert PinsNotContiguous();
        N_PUBLIC = nPub;
        uint256 size = compiled.length;
        if (size > 2 * CHUNK) revert ImageTooLarge();
        uint256 lenA = size < CHUNK ? size : CHUNK;
        IMAGE_A = _deploy(compiled, 0, lenA);
        LEN_A = lenA;
        IMAGE_B = size > lenA ? _deploy(compiled, lenA, size - lenA) : address(0);
        LEN_B = size - lenA;
        IMAGE_AT = _word(compiled, Air.H_ARENA_END);
        N_FRAME = _word(compiled, Air.H_N_FRAME);
        N_PER = _word(compiled, Air.H_N_PER);
        N_ALPHA = _word(compiled, Air.H_N_ALPHA);
    }

    /// @inheritdoc IProgramFormEvaluator
    /// @dev Reverts with no data on a wrong length or a zero denominator, NonCanonical on a word >= P.
    function evaluate(
        uint256[2][] calldata frame,
        uint256[2][] calldata periodic,
        uint256[2][] calldata coeffs,
        uint256[] calldata publics,
        uint256[6] calldata point
    ) external view returns (uint256 c0, uint256 c1) {
        return _evaluate(frame, periodic, coeffs, publics, point);
    }

    function _evaluate(
        uint256[2][] calldata frame,
        uint256[2][] calldata periodic,
        uint256[2][] calldata coeffs,
        uint256[] calldata publics,
        uint256[6] calldata point
    ) internal view returns (uint256 c0, uint256 c1) {
        if (publics.length != N_PUBLIC) revert NotThisCircuit();
        if (frame.length != N_FRAME || periodic.length != N_PER || coeffs.length != N_ALPHA) revert();
        uint256 img = _load();
        _stage(img, frame, periodic, publics, point);
        return _run(img, coeffs, publics);
    }

    /// @dev The inputs into the arena, every word of them and of the public words checked canonical.
    function _stage(
        uint256 img,
        uint256[2][] calldata frame,
        uint256[2][] calldata periodic,
        uint256[] calldata publics,
        uint256[6] calldata point
    ) private view {
        uint256 fr;
        uint256 pz;
        uint256 pu;
        uint256 pt;
        assembly {
            fr := frame.offset
            pz := periodic.offset
            pu := publics.offset
            pt := point
        }
        if (!Air.stageCalldata(img, fr, pz, pt, pu, N_PUBLIC)) revert Air.NonCanonical();
    }

    function _run(uint256 img, uint256[2][] calldata coeffs, uint256[] calldata publics)
        private
        pure
        returns (uint256 c0, uint256 c1)
    {
        uint256 cf;
        uint256 pu;
        assembly {
            cf := coeffs.offset
            pu := publics.offset
        }
        return Air.runCalldata(img, cf, pu);
    }

    /// @notice The data contracts holding the image, and each one's length.
    function image() external view returns (address a, uint256 lenA, address b, uint256 lenB) {
        return (IMAGE_A, LEN_A, IMAGE_B, LEN_B);
    }

    /// @dev Copies the image to IMAGE_AT, the end of the arena, and returns that address.
    function _load() private view returns (uint256 img) {
        uint256 free;
        assembly {
            free := mload(0x40)
        }
        if (free != ARENA) revert MemoryInUse();
        img = IMAGE_AT;
        address a = IMAGE_A;
        address b = IMAGE_B;
        uint256 lenA = LEN_A;
        uint256 lenB = LEN_B;
        assembly {
            extcodecopy(a, img, 1, lenA)
            if lenB { extcodecopy(b, add(img, lenA), 1, lenB) }
        }
    }

    /// @dev A data contract whose code is 0x00 then image[from, from + n). The leading STOP keeps it inert.
    function _deploy(bytes memory image_, uint256 from, uint256 n) private returns (address a) {
        bytes memory init = bytes.concat(hex"61", bytes2(uint16(n + 1)), hex"80600a3d393df300", new bytes(n));
        assembly {
            // word copy behind INIT_HEAD, the last word may run into free memory nothing reads
            let src := add(add(image_, 0x20), from)
            let dst := add(add(init, 0x20), INIT_HEAD)
            for { let i := 0 } lt(i, n) { i := add(i, 0x20) } { mstore(add(dst, i), mload(add(src, i))) }
            a := create(0, add(init, 0x20), mload(init))
        }
        if (a == address(0) || a.code.length != n + 1) revert ImageNotDeployed();
    }

    function _word(bytes memory image_, uint256 field) private pure returns (uint256 v) {
        assembly {
            v := mload(add(add(image_, 0x20), field))
        }
    }
}

/// @title ProgramFormEvaluator
/// @notice The constraints at z of the 11-word circuit of ProgramFormProgram, compiled at
///         construction. The launch pool uses LaunchEvaluator.
contract ProgramFormEvaluator is ProgramFormEvaluatorBase {
    constructor(bytes memory tape_)
        ProgramFormEvaluatorBase(
            ProgramFormImage.compiled(
                tape_, Prog.TAPE_HASH, Prog.TAPE_LENGTH, Prog.BOUNDARIES, Slots.TAPE_HASH, Slots.SLOTS, Air.N_CHALLENGES
            )
        )
    {}
}
