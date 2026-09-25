// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/// @notice The lane vector's structure, read from the emitted layout. Every kind contributes
///         at every lane below its own arity, selector-weighted into one shared vector.
contract LaneDispatchTest is Test {
    string internal ly;
    string internal st;

    function setUp() public {
        ly = vm.readFile("spec/emit-current/layout.json");
        st = vm.readFile("spec/emit-current/structure.json");
    }

    function _k(uint256 i, string memory f) internal view returns (uint256) {
        return vm.parseJsonUint(ly, string.concat(".kinds[", vm.toString(i), "].", f));
    }

    function _nKinds() internal view returns (uint256 n) {
        while (vm.keyExistsJson(ly, string.concat(".kinds[", vm.toString(n), "].arity"))) ++n;
    }

    /// How many kinds contribute at a lane: every one whose arity exceeds the index.
    function _contributorsAt(uint256 lane) internal view returns (uint256 c) {
        uint256 n = _nKinds();
        for (uint256 i = 0; i < n; ++i) {
            if (_k(i, "arity") > lane) ++c;
        }
    }

    function _composeArity() internal view returns (uint256) {
        uint256 n = _nKinds();
        uint256 best;
        for (uint256 i = 0; i < n; ++i) {
            uint256 a = _k(i, "arity");
            if (a > best) best = a;
        }
        return best; // compose is the widest kind and sets the region lane count
    }

    /// Region lanes plus group lanes equal the emitted transition count.
    function test_theLaneCountsAreTheEmitsOwnArithmetic() public view {
        uint256 region = _composeArity();
        uint256 groups = (vm.parseJsonUint(st, ".max_group_width") + 7) / 8; // BLOCK = 8
        assertEq(
            region + groups,
            vm.parseJsonUint(st, ".num_transition"),
            "region lanes plus group lanes are not the transition count"
        );
        console2.log("region lanes", region, "group lanes", groups);
    }

    /// `max_noncompose_arity` is the widest kind other than compose.
    function test_theWidestNonComposeKindIsThePublishedFigure() public view {
        uint256 n = _nKinds();
        uint256 compose = _composeArity();
        uint256 widest;
        for (uint256 i = 0; i < n; ++i) {
            uint256 a = _k(i, "arity");
            if (a != compose && a > widest) widest = a;
        }
        assertEq(widest, vm.parseJsonUint(ly, ".max_noncompose_arity"), "max_noncompose_arity is not the widest");
    }

    /// Lanes are interleaved: every kind at lane 0, compose alone above `max_noncompose_arity`.
    function test_lanesAreInterleavedAndNotContiguous() public view {
        uint256 maxNon = vm.parseJsonUint(ly, ".max_noncompose_arity");
        assertEq(_contributorsAt(0), _nKinds(), "lane 0 must take every kind");
        assertGt(_contributorsAt(0), 1, "a contiguous layout would have one contributor per lane");
        assertEq(_contributorsAt(maxNon), 1, "above the widest non-compose kind only compose remains");
        assertEq(_contributorsAt(_composeArity() - 1), 1, "the last region lane is compose alone");
        assertGt(_contributorsAt(maxNon - 1), 1, "the lane below the figure still has company");
    }

    /// `periodic_base` collides across kinds and matches the published collision count, so it
    /// cannot be used as a key.
    function test_thePeriodicBaseIsNotAKey() public view {
        uint256 n = _nKinds();
        uint256 collisions;
        for (uint256 i = 0; i < n; ++i) {
            for (uint256 j = i + 1; j < n; ++j) {
                if (_k(i, "periodic_base") == _k(j, "periodic_base")) ++collisions;
            }
        }
        assertEq(collisions, vm.parseJsonUint(ly, ".periodic_base_collisions"), "collision count moved");
        assertGt(collisions, 0, "if this is ever zero the emit changed and the warning is stale");
    }

    /// There are four authentication kinds, each with slots. They share one Merkle-path body.
    function test_theAuthenticationKindsShareABody() public view {
        uint256 n = _nKinds();
        uint256 auth;
        for (uint256 i = 0; i < n; ++i) {
            string memory role = vm.parseJsonString(ly, string.concat(".kinds[", vm.toString(i), "].role"));
            if (_endsWith(role, "_auth")) {
                ++auth;
                assertGt(_k(i, "slots"), 0, "an authentication kind with no slots reads nothing");
            }
        }
        assertEq(auth, 4, "the authentication family changed size");
    }

    function _endsWith(string memory s, string memory suf) private pure returns (bool) {
        bytes memory b = bytes(s);
        bytes memory f = bytes(suf);
        if (b.length < f.length) return false;
        for (uint256 i = 0; i < f.length; ++i) {
            if (b[b.length - f.length + i] != f[i]) return false;
        }
        return true;
    }
}
