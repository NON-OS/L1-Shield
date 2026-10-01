// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProgramFormEvaluatorBase, ProgramFormImage} from "./ProgramFormEvaluator.sol";
import {LaunchProgram as Prog} from "./LaunchProgram.sol";

/// @title LaunchEvaluator
/// @notice The constraints at z of the launch circuit, the join-split over 36 public words.
/// @dev The image is compiled ahead of time and pinned by hash, since compiling it costs more gas than
///      one transaction carries. LaunchImage.t.sol holds the pin to the compile of the tape. The copy
///      constraint is in pair arithmetic, so the tape reads beta and gamma as four limbs.
contract LaunchEvaluator is ProgramFormEvaluatorBase {
    constructor(bytes memory image_) ProgramFormEvaluatorBase(ProgramFormImage.pinned(image_, Prog.IMAGE_HASH)) {}
}
