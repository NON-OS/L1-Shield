// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase} from "./ShieldTestBase.sol";
import {RootBounty, IRootCommitter} from "../../contracts/shield/RootBounty.sol";

/// Commits through the bounty and refuses every native payment.
contract RefusingCommitter {
    function commit(RootBounty b) external {
        b.commit();
    }
}

/// The root bounty pays for commits that move the pool's root, at most once per interval.
contract RootBountyTest is ShieldTestBase {
    uint256 internal constant BOUNTY = 1e14;
    uint256 internal constant INTERVAL = 1 hours;
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    RootBounty internal rb;

    event BountyPaid(address indexed to, bytes32 indexed root, uint256 amount);

    function setUp() public override {
        super.setUp();
        vm.warp(1_750_000_000);
        rb = new RootBounty(IRootCommitter(address(pool)), BOUNTY, INTERVAL);
    }

    function _fund(uint256 amount) internal {
        (bool ok,) = address(rb).call{value: amount}("");
        assertTrue(ok);
    }

    function _leafAndCommit(address who) internal returns (uint256 paid) {
        depositNative(alice, 1 ether);
        vm.prank(who);
        (, paid) = rb.commit();
    }

    /// The bounty and the interval are capped at construction, and there is no owner to change them.
    function test_theBountyIsCappedAtConstruction() public {
        IRootCommitter p = IRootCommitter(address(pool));
        uint256 cap = rb.MAX_BOUNTY();
        uint256 minI = rb.MIN_INTERVAL();
        vm.expectRevert(RootBounty.BadBounty.selector);
        new RootBounty(p, cap + 1, INTERVAL);
        vm.expectRevert(RootBounty.BadBounty.selector);
        new RootBounty(p, 0, INTERVAL);
        vm.expectRevert(RootBounty.BadInterval.selector);
        new RootBounty(p, BOUNTY, minI - 1);
        vm.expectRevert(RootBounty.ZeroAddress.selector);
        new RootBounty(IRootCommitter(address(0)), BOUNTY, INTERVAL);
    }

    /// A commit that moves the root pays its caller. A repeat that moves nothing pays nothing.
    function test_onlyAMovingCommitIsPaid() public {
        _fund(1 ether);
        depositNative(alice, 1 ether);
        vm.expectEmit(true, false, false, false);
        emit BountyPaid(carol, bytes32(0), BOUNTY);
        vm.prank(carol);
        (bytes32 root, uint256 paid) = rb.commit();
        assertEq(paid, BOUNTY);
        assertEq(carol.balance, BOUNTY);
        assertEq(pool.currentRoot(), root);

        vm.warp(block.timestamp + INTERVAL);
        vm.prank(dave);
        (, paid) = rb.commit();
        assertEq(paid, 0, "a no-op commit earns nothing");
        assertEq(dave.balance, 0);
        assertEq(address(rb).balance, 1 ether - BOUNTY);
    }

    /// A root committed on the pool directly leaves nothing for the bounty to pay.
    function test_aDirectCommitLeavesNoBounty() public {
        _fund(1 ether);
        depositNative(alice, 1 ether);
        pool.commitRoot();
        vm.prank(carol);
        (, uint256 paid) = rb.commit();
        assertEq(paid, 0);
    }

    /// At most one bounty is paid per interval, however many roots move.
    function test_oneBountyPerInterval() public {
        _fund(1 ether);
        assertEq(_leafAndCommit(carol), BOUNTY);
        assertEq(_leafAndCommit(dave), 0, "second commit inside the interval");
        vm.warp(block.timestamp + INTERVAL - 1);
        assertEq(_leafAndCommit(dave), 0);
        vm.warp(block.timestamp + 1);
        assertEq(_leafAndCommit(dave), BOUNTY);
    }

    /// An empty bounty pays nothing and the root still lands. A short balance pays what it holds.
    function test_theBalanceBoundsThePayment() public {
        depositNative(alice, 1 ether);
        vm.prank(carol);
        (bytes32 root, uint256 paid) = rb.commit();
        assertEq(pool.currentRoot(), root);
        assertEq(paid, 0);

        _fund(4e13);
        assertEq(_leafAndCommit(carol), 4e13);
        assertEq(address(rb).balance, 0);
    }

    /// A caller that refuses ETH gets its commit reverted, and the bounty stays.
    function test_aRefusingCallerIsReverted() public {
        _fund(1 ether);
        RefusingCommitter c = new RefusingCommitter();
        depositNative(alice, 1 ether);
        vm.expectRevert(RootBounty.TransferFailed.selector);
        c.commit(rb);
        assertEq(address(rb).balance, 1 ether);
    }

    /// Commits spaced at random pay at most one bounty per interval and never more than was funded.
    function testFuzz_noDrain(uint256 seed) public {
        _fund(0.0005 ether);
        uint256 start = block.timestamp;
        uint256 paid;
        for (uint256 i = 0; i < 12; ++i) {
            vm.warp(block.timestamp + (uint256(keccak256(abi.encode(seed, i))) % 2 hours));
            paid += _leafAndCommit(carol);
        }
        assertLe(paid, ((block.timestamp - start) / INTERVAL + 1) * BOUNTY);
        assertEq(carol.balance, paid);
        assertEq(address(rb).balance, 0.0005 ether - paid);
    }
}
