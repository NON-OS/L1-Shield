// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase} from "./ShieldTestBase.sol";
import {ShieldFeeRouter} from "../../contracts/shield/ShieldFeeRouter.sol";
import {MockDexRouter} from "./mocks/MockDexRouter.sol";

contract ShieldFeeRouterTest is ShieldTestBase {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function setUp() public override {
        super.setUp();
        // Approve the mock DEX router behind the timelock and set the keeper.
        vm.startPrank(safe);
        feeRouter.proposeRouter(address(dex));
        feeRouter.setKeeper(keeper);
        vm.stopPrank();
        vm.warp(block.timestamp + feeRouter.TIMELOCK_DELAY());
        feeRouter.executeRouterApproval(address(dex));
        // Give the mock router NOX inventory to pay out swaps.
        nox.mint(address(dex), 1e27);
    }

    function test_DistributeExactToTheWei() public {
        // An odd amount forces rounding. The remainder is burned, so the three shares sum to the total.
        uint256 total = 10_000_000_000_000_001; // odd wei
        nox.mint(address(feeRouter), total);

        uint256 expStaking = (total * STAKING_BPS) / 10_000;
        uint256 expTreasury = (total * TREASURY_BPS) / 10_000;
        uint256 expBurn = total - expStaking - expTreasury;

        feeRouter.distribute();

        // nothing is staked, so the staking contract burns its exact share
        assertEq(nox.balanceOf(address(staking)), 0, "staking holds nothing");
        assertEq(nox.balanceOf(treasury), expTreasury, "treasury exact");
        assertEq(nox.balanceOf(DEAD), expBurn + expStaking, "burn exact, with the staking share");
        assertEq(expStaking + expTreasury + expBurn, total, "conservation");
        assertEq(nox.balanceOf(address(feeRouter)), 0, "router drained");
    }

    function testFuzz_DistributeConservesEveryWei(uint96 amount) public {
        vm.assume(amount > 0);
        nox.mint(address(feeRouter), amount);
        feeRouter.distribute();
        assertEq(
            nox.balanceOf(address(staking)) + nox.balanceOf(treasury) + nox.balanceOf(DEAD),
            amount,
            "no wei created or lost"
        );
    }

    function test_SplitCapsEnforced() public {
        vm.startPrank(safe);
        vm.expectRevert(ShieldFeeRouter.BadSplit.selector);
        feeRouter.setSplits(5000, 3000, 1000); // != 10000

        vm.expectRevert(ShieldFeeRouter.TreasuryShareTooHigh.selector);
        feeRouter.setSplits(2000, 5001, 2999); // treasury > 50%

        feeRouter.setSplits(5000, 5000, 0); // at cap: fine
        vm.stopPrank();
    }

    function test_BuybackSlippageGuardReverts() public {
        vm.deal(address(feeRouter), 1 ether);
        address[] memory path = new address[](2);
        path[0] = makeAddr("wnative");
        path[1] = address(nox);

        dex.setRate(0.9e18); // router only pays 0.9 NOX per native
        vm.prank(keeper);
        vm.expectRevert(MockDexRouter.InsufficientOutputAmount.selector);
        feeRouter.convertNative(address(dex), 1 ether, 1e18, path, block.timestamp + 1);

        // With an honest minOut the swap goes through.
        vm.prank(keeper);
        uint256 out = feeRouter.convertNative(address(dex), 1 ether, 0.9e18, path, block.timestamp + 1);
        assertEq(out, 0.9e18);
        assertEq(nox.balanceOf(address(feeRouter)), 0.9e18);
    }

    function test_ConvertTokenBuybackAndGates() public {
        usd.mint(address(feeRouter), 100e18);
        address[] memory path = new address[](2);
        path[0] = address(usd);
        path[1] = address(nox);

        // Only keeper or owner.
        vm.prank(alice);
        vm.expectRevert(ShieldFeeRouter.NotKeeperOrOwner.selector);
        feeRouter.convertToken(address(dex), 100e18, 1, path, block.timestamp + 1);

        // Router must be whitelisted.
        MockDexRouter rogue = new MockDexRouter();
        vm.prank(keeper);
        vm.expectRevert(ShieldFeeRouter.RouterNotApproved.selector);
        feeRouter.convertToken(address(rogue), 100e18, 1, path, block.timestamp + 1);

        // Path must terminate in NOX.
        address[] memory badPath = new address[](2);
        badPath[0] = address(usd);
        badPath[1] = address(usd);
        vm.prank(keeper);
        vm.expectRevert(ShieldFeeRouter.BadSwapPath.selector);
        feeRouter.convertToken(address(dex), 100e18, 1, badPath, block.timestamp + 1);

        // A zero minOut is refused.
        vm.prank(keeper);
        vm.expectRevert(ShieldFeeRouter.ZeroAmount.selector);
        feeRouter.convertToken(address(dex), 100e18, 0, path, block.timestamp + 1);

        // Honest call succeeds.
        vm.prank(keeper);
        uint256 out = feeRouter.convertToken(address(dex), 100e18, 100e18, path, block.timestamp + 1);
        assertEq(out, 100e18);
    }

    function test_RouterApprovalIsTimelocked_RevocationIsInstant() public {
        MockDexRouter r2 = new MockDexRouter();
        vm.prank(safe);
        feeRouter.proposeRouter(address(r2));

        vm.expectRevert(ShieldFeeRouter.TimelockNotReady.selector);
        feeRouter.executeRouterApproval(address(r2));

        vm.warp(block.timestamp + feeRouter.TIMELOCK_DELAY());
        feeRouter.executeRouterApproval(address(r2));
        assertTrue(feeRouter.approvedRouter(address(r2)));

        vm.prank(safe);
        feeRouter.revokeRouter(address(r2)); // instant
        assertFalse(feeRouter.approvedRouter(address(r2)));
    }

    function test_StakingAndTreasuryChangesAreTimelocked() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(safe);
        feeRouter.proposeTreasury(newTreasury);

        vm.expectRevert(ShieldFeeRouter.TimelockNotReady.selector);
        feeRouter.executeTreasury();

        vm.warp(block.timestamp + feeRouter.TIMELOCK_DELAY());
        feeRouter.executeTreasury();
        assertEq(feeRouter.treasury(), newTreasury);
    }
}
