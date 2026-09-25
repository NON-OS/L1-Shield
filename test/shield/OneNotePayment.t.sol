// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase} from "./ShieldTestBase.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";

/// @notice The pool burns both nullifiers of every intent, so a one-note payment's dead input
///         needs a nullifier unique per proof and disjoint from real ones. The circuit derives it as
///         nf = compress(compress(nk, cm), [index, live ? 0 : DEAD_DOMAIN, 0, 0]), DEAD_DOMAIN = 0x44454144.
contract OneNotePaymentTest is ShieldTestBase {
    /// A constant dead nullifier lets one one-note payment through and reverts every later one.
    function test_aFixedDeadNullifierWouldMakeTheFeatureWorkOnce() public {
        depositNative(alice, 10 ether);
        pool.commitRoot();

        bytes32 deadNf = canon(keccak256("the canonical dead-note nullifier"));

        TIntent[] memory a = new TIntent[](1);
        a[0] = newIntent(1 ether, 0, makeAddr("first"), 0);
        a[0].nf1 = deadNf; // the dead input of a one-note payment
        settle(encodeBatch(pool.currentRoot(), assocRoot, 0, a));

        TIntent[] memory b = new TIntent[](1);
        b[0] = newIntent(1 ether, 0, makeAddr("second"), 0);
        b[0].nf1 = deadNf; // a different payment, same constant

        // built before expectRevert, since pool.currentRoot() is an external call
        uint256[] memory wb = encodeBatch(pool.currentRoot(), assocRoot, 0, b);
        vm.expectRevert(ShieldedPool.NullifierAlreadySpent.selector);
        settle(wb);
    }

    /// With a unique dead nullifier per proof, one-note payments repeat without limit.
    function test_aUniqueDeadNullifierLetsOneNotePaymentsRepeat() public {
        depositNative(alice, 10 ether);
        pool.commitRoot();

        for (uint256 i = 0; i < 5; ++i) {
            TIntent[] memory it = new TIntent[](1);
            it[0] = newIntent(0.5 ether, 0, makeAddr(vm.toString(i)), 0);
            it[0].nf1 = canon(keccak256(abi.encode("dead", i)));
            settle(encodeBatch(pool.currentRoot(), assocRoot, 0, it));
        }
        assertEq(makeAddr(vm.toString(uint256(0))).balance, 0.5 ether, "the first one-note payment did not land");
    }

    /// The pool burns a dead nullifier equal to a real one. Only the circuit's DEAD_DOMAIN prevents it.
    function test_aDeadNullifierColludingWithARealOneBurnsANoteNobodySpent() public {
        depositNative(alice, 10 ether);
        pool.commitRoot();

        bytes32 victimNf = canon(keccak256("a note that will want to be spent"));

        TIntent[] memory grief = new TIntent[](1);
        grief[0] = newIntent(0.5 ether, 0, makeAddr("griefer"), 0);
        grief[0].nf1 = victimNf; // a dead slot pointed at somebody else's nullifier
        settle(encodeBatch(pool.currentRoot(), assocRoot, 0, grief));

        assertTrue(pool.nullifierSpent(victimNf), "the pool burned it, because the pool always does");

        TIntent[] memory victim = new TIntent[](1);
        victim[0] = newIntent(0.5 ether, 0, makeAddr("victim"), 0);
        victim[0].nf0 = victimNf;
        uint256[] memory wv = encodeBatch(pool.currentRoot(), assocRoot, 0, victim);
        vm.expectRevert(ShieldedPool.NullifierAlreadySpent.selector);
        settle(wv);
    }
}
