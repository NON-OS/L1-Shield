// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDexRouterV2} from "./interfaces/IDexRouterV2.sol";

/// @title BatchClearing
/// @notice Routes a batch's net residual to a whitelisted DEX from the pool's own context.
/// @dev The pool checks the router whitelist. A zero slippage floor is rejected here.
///      See docs/08-pool.md.
library BatchClearing {
    using SafeERC20 for IERC20;

    error ZeroMinOut();
    error PathEndpointsMismatch();
    error NativeInAndOut();

    struct Route {
        address router;
        address tokenIn; // address(0) for native
        address tokenOut; // address(0) for native
        uint256 amountIn;
        uint256 amountOutMin; // must be > 0
        address[] path;
        uint256 deadline; // unix seconds
    }

    /// @notice Executes the residual swap. For a native leg only the ERC-20 path endpoint is checked.
    /// @return amountOut Measured by balance delta so the router cannot over-report it.
    function routeResidual(Route memory r) internal returns (uint256 amountOut) {
        if (r.amountOutMin == 0) revert ZeroMinOut();
        if (r.tokenIn == address(0) && r.tokenOut == address(0)) revert NativeInAndOut();

        address inEndpoint = r.path[0];
        address outEndpoint = r.path[r.path.length - 1];

        if (r.tokenIn == address(0)) {
            if (outEndpoint != r.tokenOut) revert PathEndpointsMismatch();
            uint256 before = IERC20(r.tokenOut).balanceOf(address(this));
            IDexRouterV2(r.router).swapExactETHForTokens{value: r.amountIn}(
                r.amountOutMin, r.path, address(this), r.deadline
            );
            amountOut = IERC20(r.tokenOut).balanceOf(address(this)) - before;
        } else if (r.tokenOut == address(0)) {
            // Approvals are reset to zero after each swap so the router keeps no allowance.
            if (inEndpoint != r.tokenIn) revert PathEndpointsMismatch();
            IERC20(r.tokenIn).forceApprove(r.router, r.amountIn);
            uint256 before = address(this).balance;
            IDexRouterV2(r.router).swapExactTokensForETH(r.amountIn, r.amountOutMin, r.path, address(this), r.deadline);
            IERC20(r.tokenIn).forceApprove(r.router, 0);
            amountOut = address(this).balance - before;
        } else {
            if (inEndpoint != r.tokenIn || outEndpoint != r.tokenOut) revert PathEndpointsMismatch();
            IERC20(r.tokenIn).forceApprove(r.router, r.amountIn);
            uint256 before = IERC20(r.tokenOut).balanceOf(address(this));
            IDexRouterV2(r.router)
                .swapExactTokensForTokens(r.amountIn, r.amountOutMin, r.path, address(this), r.deadline);
            IERC20(r.tokenIn).forceApprove(r.router, 0);
            amountOut = IERC20(r.tokenOut).balanceOf(address(this)) - before;
        }
    }
}
