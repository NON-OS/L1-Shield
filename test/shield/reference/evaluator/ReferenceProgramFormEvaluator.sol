// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IProgramFormEvaluator} from "../../../../contracts/shield/verifier/IProgramFormEvaluator.sol";
import {ProgramFormProgram as Prog} from "../../../../contracts/shield/verifier/ProgramFormProgram.sol";
import {ReferenceProgramFormAir as ProgramFormAir} from "./ReferenceProgramFormAir.sol";

/// @title ReferenceProgramFormEvaluator
/// @notice Solidity reference for ProgramFormEvaluator, test only.
/// @dev The transition part lives in the `tape` data contract, re-hashed on every call. `_gate`
///      refuses the words ProgramFormEvaluator refuses, with the same error after the same length
///      checks, so a differential test can hold both to the same result or revert on any input.
contract ReferenceProgramFormEvaluator is IProgramFormEvaluator {
    address public immutable tape;

    uint256 private constant N_PUBLIC = 32;

    /// @notice The transition part does not hash to `ProgramFormProgram.TAPE_HASH`.
    error TapeMismatch();
    error TapeNotDeployed();
    error NotThisCircuit();
    /// @notice Same signature as ProgramFormAir.NonCanonical, so the same selector.
    error NonCanonical();

    uint256 private constant P = 0xFFFFFFFF00000001;
    // the gate's lengths, from the tape header: u16 nOps, nOut, nBnd, nRows, nFrame, nPer
    uint256 private immutable N_FRAME;
    uint256 private immutable N_PER;
    uint256 private immutable N_ALPHA;

    constructor(bytes memory tape_) {
        if (tape_.length != Prog.TAPE_LENGTH || keccak256(tape_) != Prog.TAPE_HASH) revert TapeMismatch();
        // initcode returning 0x00 ++ tape_, the leading STOP keeps it from running
        bytes memory init = bytes.concat(hex"61", bytes2(uint16(tape_.length + 1)), hex"80600a3d393df300", tape_);
        address a;
        assembly {
            a := create(0, add(init, 0x20), mload(init))
        }
        if (a == address(0) || a.code.length != tape_.length + 1) revert TapeNotDeployed();
        tape = a;
        N_FRAME = uint16(bytes2(bytes.concat(tape_[8], tape_[9])));
        N_PER = uint16(bytes2(bytes.concat(tape_[10], tape_[11])));
        N_ALPHA = uint16(bytes2(bytes.concat(tape_[2], tape_[3]))) + uint16(bytes2(bytes.concat(tape_[4], tape_[5])));
    }

    /// @inheritdoc IProgramFormEvaluator
    function evaluate(
        uint256[2][] calldata frame,
        uint256[2][] calldata periodic,
        uint256[2][] calldata coeffs,
        uint256[] calldata publics,
        uint256[6] calldata point
    ) external view returns (uint256 c0, uint256 c1) {
        return _evaluate(frame, periodic, coeffs, publics, point);
    }

    /// @dev The body of `evaluate`, split out so a test harness can read msize after it.
    function _evaluate(
        uint256[2][] calldata frame,
        uint256[2][] calldata periodic,
        uint256[2][] calldata coeffs,
        uint256[] calldata publics,
        uint256[6] calldata point
    ) internal view returns (uint256 c0, uint256 c1) {
        if (publics.length != N_PUBLIC) revert NotThisCircuit();
        _gate(frame, periodic, coeffs, publics, point);
        return ProgramFormAir.composition(program(), _flat(frame), _flat(periodic), _flat(coeffs), publics, point);
    }

    /// @notice The program: the data contract's bytes, hash-checked, then the boundary part.
    function program() public view returns (bytes memory prog) {
        uint256 n = Prog.TAPE_LENGTH;
        bytes memory t = new bytes(n);
        address a = tape;
        assembly {
            extcodecopy(a, add(t, 0x20), 1, n)
        }
        if (keccak256(t) != Prog.TAPE_HASH) revert TapeMismatch();
        prog = bytes.concat(t, Prog.BOUNDARIES);
    }

    /// @dev Refuses the lengths the composition would refuse, with the same empty revert, then any
    ///      frame, periodic, point or public word at or above P.
    function _gate(
        uint256[2][] calldata frame,
        uint256[2][] calldata periodic,
        uint256[2][] calldata coeffs,
        uint256[] calldata publics,
        uint256[6] calldata point
    ) private view {
        if (frame.length != N_FRAME || periodic.length != N_PER || coeffs.length != N_ALPHA) revert();
        for (uint256 i = 0; i < frame.length; ++i) {
            if (frame[i][0] >= P || frame[i][1] >= P) revert NonCanonical();
        }
        for (uint256 i = 0; i < periodic.length; ++i) {
            if (periodic[i][0] >= P || periodic[i][1] >= P) revert NonCanonical();
        }
        for (uint256 i = 0; i < 6; ++i) {
            if (point[i] >= P) revert NonCanonical();
        }
        for (uint256 i = 0; i < publics.length; ++i) {
            if (publics[i] >= P) revert NonCanonical();
        }
    }

    function _flat(uint256[2][] calldata a) private pure returns (uint256[] memory o) {
        uint256 n = 2 * a.length;
        o = new uint256[](n);
        assembly {
            calldatacopy(add(o, 0x20), a.offset, mul(n, 0x20))
        }
    }
}
