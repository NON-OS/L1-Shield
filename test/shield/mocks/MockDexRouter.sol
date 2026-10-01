// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDexRouterV2} from "../../../contracts/shield/interfaces/IDexRouterV2.sol";

/// @notice Test-only V2-style DEX router with a settable fixed rate. It enforces `amountOutMin`
///         and `deadline`, and pays out of its own token and native inventory.
contract MockDexRouter is IDexRouterV2 {
    uint256 public rate = 1e18; // output units per 1e18 input units

    error Expired();
    error InsufficientOutputAmount();

    receive() external payable {}

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        if (block.timestamp > deadline) revert Expired();
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = (amountIn * rate) / 1e18;
        if (out < amountOutMin) revert InsufficientOutputAmount();
        IERC20(path[path.length - 1]).transfer(to, out);
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = out;
    }

    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts)
    {
        if (block.timestamp > deadline) revert Expired();
        uint256 out = (msg.value * rate) / 1e18;
        if (out < amountOutMin) revert InsufficientOutputAmount();
        IERC20(path[path.length - 1]).transfer(to, out);
        amounts = new uint256[](path.length);
        amounts[0] = msg.value;
        amounts[path.length - 1] = out;
    }

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        if (block.timestamp > deadline) revert Expired();
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = (amountIn * rate) / 1e18;
        if (out < amountOutMin) revert InsufficientOutputAmount();
        (bool ok,) = payable(to).call{value: out}("");
        require(ok, "native out failed");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = out;
    }
}
