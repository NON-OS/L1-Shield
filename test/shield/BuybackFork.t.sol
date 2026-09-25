// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ShieldFeeRouter} from "../../contracts/shield/ShieldFeeRouter.sol";
import {NoxShieldStaking} from "../../contracts/shield/NoxShieldStaking.sol";

interface IUniV2Factory {
    function getPair(address, address) external view returns (address);
}

interface IUniV2RouterView {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
}

/// @notice Mainnet-fork test of the buyback leg against the Uniswap V2 router, skipped without
///         MAINNET_RPC_URL. Buys NOX if it has a WETH pair, DAI otherwise.
contract BuybackForkTest is Test {
    address internal constant UNIV2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address internal constant UNIV2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant NOX = 0xBf0415ebFC762B4166e198736a15Ff0B53744e43;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function test_ForkBuybackConvertDistribute() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            emit log("SKIP: MAINNET_RPC_URL not set");
            return;
        }
        vm.createSelectFork(rpc);

        address token = IUniV2Factory(UNIV2_FACTORY).getPair(WETH, NOX) != address(0) ? NOX : DAI;
        emit log_named_address("buyback target token", token);

        address safe = makeAddr("safe");
        address treasury = makeAddr("treasury");
        NoxShieldStaking staking = new NoxShieldStaking(safe, IERC20(token), 7 days);
        ShieldFeeRouter feeRouter =
            new ShieldFeeRouter(safe, IERC20(token), address(staking), treasury, 4000, 3000, 3000);
        vm.prank(safe);
        staking.setRewardNotifier(address(feeRouter));

        // Whitelist the real Uniswap V2 router behind the timelock.
        vm.prank(safe);
        feeRouter.proposeRouter(UNIV2_ROUTER);
        vm.warp(block.timestamp + feeRouter.TIMELOCK_DELAY());
        feeRouter.executeRouterApproval(UNIV2_ROUTER);

        // Simulate accrued native protocol fees, then convert with a real
        // slippage floor quoted from the live pool.
        vm.deal(address(feeRouter), 1 ether);
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = token;
        uint256 quoted = IUniV2RouterView(UNIV2_ROUTER).getAmountsOut(1 ether, path)[1];
        uint256 minOut = (quoted * 99) / 100;

        // A floor above the quote reverts.
        vm.prank(safe);
        vm.expectRevert();
        feeRouter.convertNative(UNIV2_ROUTER, 1 ether, quoted * 2, path, block.timestamp + 300);

        vm.prank(safe);
        uint256 out = feeRouter.convertNative(UNIV2_ROUTER, 1 ether, minOut, path, block.timestamp + 300);
        assertGe(out, minOut, "buyback met the floor");

        // Split against the real ERC-20, exact to the wei.
        uint256 stakingBefore = IERC20(token).balanceOf(address(staking));
        uint256 treasuryBefore = IERC20(token).balanceOf(treasury);
        uint256 deadBefore = IERC20(token).balanceOf(DEAD);

        feeRouter.distribute();

        uint256 gotStaking = IERC20(token).balanceOf(address(staking)) - stakingBefore;
        uint256 gotTreasury = IERC20(token).balanceOf(treasury) - treasuryBefore;
        uint256 gotDead = IERC20(token).balanceOf(DEAD) - deadBefore;
        assertEq(gotStaking, (out * 4000) / 10_000, "staking share");
        assertEq(gotTreasury, (out * 3000) / 10_000, "treasury share");
        assertEq(gotStaking + gotTreasury + gotDead, out, "wei-exact conservation");
        assertEq(IERC20(token).balanceOf(address(feeRouter)), 0, "router drained");
    }
}
