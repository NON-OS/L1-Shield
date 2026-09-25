// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

/// Shared shape of every differential test here: one calldata, sent to the Yul harness and to
/// its Solidity reference twin, must come back with the same success flag and the same bytes,
/// whether that is a return value or revert data.
abstract contract DiffBase is Test {
    uint256 internal constant P = 0xFFFFFFFF00000001;

    function _same(address yul, address ref, bytes memory cd) internal view returns (bool ok, bytes memory out) {
        (bool okY, bytes memory rY) = yul.staticcall(cd);
        (bool okR, bytes memory rR) = ref.staticcall(cd);
        assertEq(okY, okR, "one side reverted and the other did not");
        assertEq(rY, rR, "return or revert data differ");
        return (okY, rY);
    }

    /// Maps a fuzzed word onto the edges half the time: zero, one, P - 1, P, P + 1, 2^64 - 1,
    /// 2^256 - 1, or the word reduced into the field, and the raw word otherwise.
    function _edge(uint256 sel, uint256 raw) internal pure returns (uint256) {
        uint256 k = sel % 16;
        if (k == 0) return 0;
        if (k == 1) return 1;
        if (k == 2) return P - 1;
        if (k == 3) return P;
        if (k == 4) return P + 1;
        if (k == 5) return type(uint64).max;
        if (k == 6) return type(uint256).max;
        if (k == 7) return raw % P;
        return k < 12 ? raw % P : raw;
    }
}
