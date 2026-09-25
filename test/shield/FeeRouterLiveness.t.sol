// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase} from "./ShieldTestBase.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";

/// A router that accepts no ETH, like any contract without a payable fallback.
contract RefusingRouter {
}

/// A router that accepts ETH and then burns all the gas it is given.
contract GreedyRouter {
    uint256[] private junk;

    receive() external payable {
        while (true) junk.push(block.timestamp);
    }
}

contract AcceptingRouter {
    uint256 public received;

    receive() external payable {
        received += msg.value;
    }
}

/// @notice A refusing or gas-burning fee router cannot stop deposits. Fees it will not take
/// are held and swept later.
contract FeeRouterLivenessTest is ShieldTestBase {
    function _setRouter(address r) internal {
        vm.prank(safe);
        pool.proposeFeeRouter(r);
        vm.warp(block.timestamp + pool.FEE_ROUTER_DELAY());
        pool.executeFeeRouterChange();
        assertEq(pool.feeRouter(), r, "router did not take");
    }

    function _absorbNative(uint256 amt) internal returns (bytes32 cm) {
        vm.deal(address(this), amt);
        (cm,) = pool.absorb{value: amt}(0, amt, bytes32(uint256(keccak256(abi.encode(amt))) >> 8));
    }

    function test_aRouterThatTakesNothingDoesNotStopDeposits() public {
        if (pool.shieldFeeBps() == 0) {
            vm.prank(safe);
            pool.setFeeBps(100, 100);
        }
        _setRouter(address(new RefusingRouter()));

        uint256 before = pool.unsweptFees(0);
        _absorbNative(1 ether);
        assertGt(pool.unsweptFees(0) - before, 0, "the fee was neither delivered nor held");
    }

    function test_aRouterThatBurnsItsGasDoesNotStopDeposits() public {
        if (pool.shieldFeeBps() == 0) {
            vm.prank(safe);
            pool.setFeeBps(100, 100);
        }
        _setRouter(address(new GreedyRouter()));

        // the gas cap on the fee push keeps the deposit alive
        _absorbNative(1 ether);
        assertGt(pool.unsweptFees(0), 0, "a greedy router was not contained");
    }

    function test_heldFeesReachTheRouterOnceItWillTakeThem() public {
        if (pool.shieldFeeBps() == 0) {
            vm.prank(safe);
            pool.setFeeBps(100, 100);
        }
        _setRouter(address(new RefusingRouter()));
        _absorbNative(1 ether);
        uint256 held = pool.unsweptFees(0);
        assertGt(held, 0, "nothing was held");

        AcceptingRouter good = new AcceptingRouter();
        _setRouter(address(good));
        pool.sweepFees(0);

        assertEq(good.received(), held, "the sweep did not deliver what was held");
        assertEq(pool.unsweptFees(0), 0, "the pool still holds fees it delivered");
    }

    function test_sweepingNothingIsRefused() public {
        vm.expectRevert(ShieldedPool.NoFeesHeld.selector);
        pool.sweepFees(0);
    }

    /// A held fee sits on top of `totalShielded`: the pool balance covers both.
    function test_holdingAFeeRaisesTheMarginRatherThanEatingIt() public {
        if (pool.shieldFeeBps() == 0) {
            vm.prank(safe);
            pool.setFeeBps(100, 100);
        }
        _setRouter(address(new RefusingRouter()));
        _absorbNative(1 ether);

        assertGe(
            address(pool).balance,
            pool.totalShielded(0) + pool.unsweptFees(0),
            "the pool cannot cover both the notes and the fees it is holding"
        );
    }
}
