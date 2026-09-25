// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase} from "./ShieldTestBase.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";

/// A recipient with no receive or fallback, so it refuses native value.
contract HostileRecipient {
}

/// @notice A recipient that refuses ETH cannot make a batch revert. Its payout is credited
///         as claimable and stays covered by the pool balance.
contract BatchGriefTest is ShieldTestBase {
    function test_aRecipientThatRefusesPaymentDoesNotKillTheBatch() public {
        depositNative(alice, 10 ether);
        pool.commitRoot();

        address good = makeAddr("goodRecipient");
        HostileRecipient bad = new HostileRecipient();

        TIntent[] memory intents = new TIntent[](2);
        intents[0] = newIntent(1 ether, 0, good, 0);
        intents[1] = newIntent(1 ether, 0, address(bad), 0);
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 0, intents);

        settle(w);

        assertEq(good.balance, 1 ether, "the honest recipient lost their payout to somebody else");
        assertEq(pool.claimable(0, address(bad)), 1 ether, "the refused payout was not credited");
    }

    function test_whatWasRefusedStaysTheirsToClaim() public {
        depositNative(alice, 10 ether);
        pool.commitRoot();

        HostileRecipient bad = new HostileRecipient();
        settle(singleIntent(1 ether, 0, address(bad)));
        assertEq(pool.claimable(0, address(bad)), 1 ether, "not credited");

        // they cannot take it while they still refuse it
        vm.prank(address(bad));
        vm.expectRevert(ShieldedPool.NativeTransferFailed.selector);
        pool.claim(0, address(bad));

        // and nobody else can take it for themselves
        address thief = makeAddr("thief");
        vm.prank(thief);
        vm.expectRevert(ShieldedPool.NothingToClaim.selector);
        pool.claim(0, thief);

        // paid to wherever they can actually receive it
        address wallet = makeAddr("wallet");
        vm.prank(address(bad));
        pool.claim(0, wallet);
        assertEq(wallet.balance, 1 ether, "the claim did not deliver");
        assertEq(pool.claimable(0, address(bad)), 0, "still owed after paying");
    }

    /// Credited payouts are covered on top of the notes, like held fees.
    function test_creditedPayoutsAreCoveredOnTopOfTheNotes() public {
        depositNative(alice, 10 ether);
        pool.commitRoot();

        HostileRecipient bad = new HostileRecipient();
        settle(singleIntent(1 ether, 0, address(bad)));

        assertGe(
            address(pool).balance,
            pool.totalShielded(0) + pool.unsweptFees(0) + pool.claimable(0, address(bad)),
            "the pool cannot cover the notes and what it owes"
        );
    }
}
