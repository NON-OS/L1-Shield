// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {Test} from "forge-std/Test.sol";
import {SettlerGate} from "../../../contracts/shield/SettlerGate.sol";

/// SettlerGate over every settler, caller and timestamp. Run: halmos --match-contract SettlerGateHalmos
/// The pool calls these functions, and SettlerWindow.t.sol binds the pool to them.
contract SettlerGateHalmos is SymTest, Test {
    uint256 constant WINDOW = 24 hours;

    /// Once the window has passed, the gate is open to every caller, whatever the settler is.
    function check_pastTheWindowEveryCallerMaySettle(address settler, address caller, uint256 last, uint256 nowTs)
        public
        pure
    {
        vm.assume(last <= type(uint256).max - WINDOW);
        vm.assume(nowTs >= last + WINDOW);
        assert(SettlerGate.open(settler, caller, last, nowTs, WINDOW));
    }

    function check_theSettlerMayAlwaysSettle(address settler, uint256 last, uint256 nowTs) public pure {
        assert(SettlerGate.open(settler, settler, last, nowTs, WINDOW));
    }

    function check_noSettlerMeansOpen(address caller, uint256 last, uint256 nowTs) public pure {
        assert(SettlerGate.open(address(0), caller, last, nowTs, WINDOW));
    }

    /// Inside the window a stranger is refused, so the first property is not vacuous.
    function check_insideTheWindowAStrangerIsRefused(address settler, address caller, uint256 last, uint256 nowTs)
        public
        pure
    {
        vm.assume(settler != address(0));
        vm.assume(caller != settler);
        vm.assume(last <= type(uint256).max - WINDOW);
        vm.assume(nowTs < last + WINDOW);
        assert(!SettlerGate.open(settler, caller, last, nowTs, WINDOW));
    }

    uint256 constant EPOCH = 24 hours;
    uint256 constant SLOT = 1 hours;

    // `%` repeats every epoch, so every offset in two epochs, day 0 and day 20_000, covers the gate.
    // SettlerSlotFuzz in test/shield/invariants/FieldFuzz.t.sol fuzzes the whole range.
    uint256 constant ERA = 20_000 * EPOCH;

    /// The open slot is the last SLOT seconds of the epoch, at every offset.
    function check_theOpenSlotIsTheLastHourOfTheEpoch(uint32 r, bool atZero) public pure {
        vm.assume(r < EPOCH);
        uint256 t = (atZero ? 0 : ERA) + r;
        assert(SettlerGate.inOpenSlot(t, EPOCH, SLOT) == (r >= EPOCH - SLOT));
    }

    /// From every offset a slot starts within one epoch, so a settler can delay an intent less than an epoch.
    function check_theOpenSlotIsNeverMoreThanAnEpochAway(uint32 r, bool atZero) public pure {
        vm.assume(r < EPOCH);
        uint256 t = (atZero ? 0 : ERA) + r;
        uint256 wait = r >= EPOCH - SLOT ? 0 : EPOCH - SLOT - r;
        assert(wait < EPOCH);
        assert(SettlerGate.inOpenSlot(t + wait, EPOCH, SLOT));
    }

    /// Outside the window and the slot only the settler settles, through the gate as the pool composes it.
    function check_outsideWindowAndSlotOnlyTheSettlerSettles(address settler, address caller, uint64 last, uint32 r)
        public
        pure
    {
        vm.assume(r < EPOCH - SLOT);
        uint256 t = ERA + r;
        vm.assume(t < uint256(last) + WINDOW);
        bool allowed = SettlerGate.open(settler, caller, last, t, WINDOW) || SettlerGate.inOpenSlot(t, EPOCH, SLOT);
        assert(allowed == (settler == address(0) || caller == settler));
    }

    function check_insideTheSlotEveryoneSettles(address settler, address caller, uint64 last, uint32 r) public pure {
        vm.assume(r >= EPOCH - SLOT && r < EPOCH);
        uint256 t = ERA + r;
        assert(SettlerGate.open(settler, caller, last, t, WINDOW) || SettlerGate.inOpenSlot(t, EPOCH, SLOT));
    }
}
