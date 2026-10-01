// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase} from "./ShieldTestBase.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";

/// A fee recipient word of SUBMITTER pays the fee to whoever submits the batch.
contract SubmitterFeeTest is ShieldTestBase {
    uint256 internal constant RELAY_CAP = 1e15;
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");

    function setUp() public override {
        super.setUp();
        setRelayCap(0, RELAY_CAP);
    }

    function _transfer(uint256 fee, address feeRecipient) internal returns (uint256[] memory) {
        TIntent[] memory intents = new TIntent[](1);
        intents[0] = newIntent(0, fee, address(0), 0);
        intents[0].feeRecipient = feeRecipient;
        return encodeBatch(pool.currentRoot(), assocRoot, 0, intents);
    }

    function _settleAs(address who, uint256[] memory w) internal {
        vm.prank(who);
        settle(w);
    }

    /// A fee bound to SUBMITTER is credited to whoever submits the batch.
    function test_theSubmitterEarnsTheSentinelFee() public {
        depositNative(alice, 5 ether);
        pool.commitRoot();
        uint256[] memory w = _transfer(RELAY_CAP, pool.SUBMITTER());
        _settleAs(carol, w);
        assertEq(pool.claimable(0, carol), RELAY_CAP);
        assertEq(pool.claimable(0, pool.SUBMITTER()), 0);

        uint256[] memory w2 = _transfer(RELAY_CAP / 2, pool.SUBMITTER());
        _settleAs(dave, w2);
        assertEq(pool.claimable(0, dave), RELAY_CAP / 2, "a different submitter earns its own batch");
        assertEq(pool.claimable(0, carol), RELAY_CAP);
    }

    /// A named fee recipient is credited whoever submits.
    function test_aNamedRecipientIsPaidWhoeverSubmits() public {
        depositNative(alice, 5 ether);
        pool.commitRoot();
        _settleAs(carol, _transfer(RELAY_CAP, relayer));
        assertEq(pool.claimable(0, relayer), RELAY_CAP);
        assertEq(pool.claimable(0, carol), 0);
    }

    /// The sentinel with a zero fee is refused like any other named recipient.
    function test_theSentinelWithoutAFeeIsRefused() public {
        depositNative(alice, 5 ether);
        pool.commitRoot();
        uint256[] memory w = _transfer(0, pool.SUBMITTER());
        vm.expectRevert(ShieldedPool.FeeRecipientWithoutFee.selector);
        settle(w);
    }

    /// An unshield fee bound to SUBMITTER goes to the submitter, and the recipient gets the amount whole.
    function test_anUnshieldFeeGoesToTheSubmitter() public {
        depositNative(alice, 5 ether);
        pool.commitRoot();
        TIntent[] memory intents = new TIntent[](1);
        intents[0] = newIntent(1 ether, 1e15, bob, 0);
        intents[0].feeRecipient = pool.SUBMITTER();
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 0, intents);
        uint256 before = bob.balance;
        _settleAs(carol, w);
        assertEq(bob.balance - before, 1 ether);
        assertEq(pool.claimable(0, carol), 1e15);
    }
}
