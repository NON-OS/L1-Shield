// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BatchClearing} from "../../contracts/shield/BatchClearing.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockDexRouter} from "./mocks/MockDexRouter.sol";

/// @dev Minimal harness: BatchClearing routes funds from the CALLER's context, so
///      tests drive it through a contract that actually holds the tokens/native.
contract BatchClearingHarness {
    using BatchClearing for BatchClearing.Route;

    function route(BatchClearing.Route memory r) external returns (uint256) {
        return r.routeResidual();
    }

    receive() external payable {}
}

/// @notice Direct branch coverage for BatchClearing.routeResidual, all three
///         swap directions (native→ERC20, ERC20→native, ERC20→ERC20) and every
///         guard (zero minOut, native-in-and-out, mismatched path endpoints).
contract BatchClearingTest is Test {
    BatchClearingHarness internal h;
    MockDexRouter internal dex;
    MockERC20 internal usd;
    MockERC20 internal dai;
    address internal wnative = address(0x1111);

    function setUp() public {
        h = new BatchClearingHarness();
        dex = new MockDexRouter();
        usd = new MockERC20("USD", "USD");
        dai = new MockERC20("DAI", "DAI");
        // Router inventory to pay out swaps.
        usd.mint(address(dex), 1e24);
        dai.mint(address(dex), 1e24);
        vm.deal(address(dex), 100 ether);
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function test_TokenToToken() public {
        usd.mint(address(h), 100e18);
        BatchClearing.Route memory r = BatchClearing.Route({
            router: address(dex),
            tokenIn: address(usd),
            tokenOut: address(dai),
            amountIn: 100e18,
            amountOutMin: 100e18,
            path: _path(address(usd), address(dai)),
            deadline: block.timestamp + 100
        });
        uint256 out = h.route(r);
        assertEq(out, 100e18, "token->token out");
        assertEq(dai.balanceOf(address(h)), 100e18);
    }

    function test_NativeToToken() public {
        vm.deal(address(h), 1 ether);
        BatchClearing.Route memory r = BatchClearing.Route({
            router: address(dex),
            tokenIn: address(0),
            tokenOut: address(usd),
            amountIn: 1 ether,
            amountOutMin: 1 ether,
            path: _path(wnative, address(usd)),
            deadline: block.timestamp + 100
        });
        uint256 out = h.route(r);
        assertEq(out, 1 ether, "native->token out");
        assertEq(usd.balanceOf(address(h)), 1 ether);
    }

    function test_TokenToNative() public {
        usd.mint(address(h), 2 ether);
        uint256 before = address(h).balance;
        BatchClearing.Route memory r = BatchClearing.Route({
            router: address(dex),
            tokenIn: address(usd),
            tokenOut: address(0),
            amountIn: 2 ether,
            amountOutMin: 2 ether,
            path: _path(address(usd), wnative),
            deadline: block.timestamp + 100
        });
        uint256 out = h.route(r);
        assertEq(out, 2 ether, "token->native out");
        assertEq(address(h).balance - before, 2 ether);
    }

    function test_RevertsOnZeroMinOut() public {
        BatchClearing.Route memory r = BatchClearing.Route({
            router: address(dex),
            tokenIn: address(usd),
            tokenOut: address(dai),
            amountIn: 1e18,
            amountOutMin: 0,
            path: _path(address(usd), address(dai)),
            deadline: block.timestamp + 100
        });
        vm.expectRevert(BatchClearing.ZeroMinOut.selector);
        h.route(r);
    }

    function test_RevertsOnNativeInAndOut() public {
        BatchClearing.Route memory r = BatchClearing.Route({
            router: address(dex),
            tokenIn: address(0),
            tokenOut: address(0),
            amountIn: 1e18,
            amountOutMin: 1,
            path: _path(wnative, wnative),
            deadline: block.timestamp + 100
        });
        vm.expectRevert(BatchClearing.NativeInAndOut.selector);
        h.route(r);
    }

    function test_RevertsOnMismatchedPath_TokenToToken() public {
        usd.mint(address(h), 1e18);
        BatchClearing.Route memory r = BatchClearing.Route({
            router: address(dex),
            tokenIn: address(usd),
            tokenOut: address(dai),
            amountIn: 1e18,
            amountOutMin: 1,
            path: _path(address(usd), address(usd)), // out endpoint != tokenOut
            deadline: block.timestamp + 100
        });
        vm.expectRevert(BatchClearing.PathEndpointsMismatch.selector);
        h.route(r);
    }

    function test_RevertsOnMismatchedPath_NativeToToken() public {
        vm.deal(address(h), 1 ether);
        BatchClearing.Route memory r = BatchClearing.Route({
            router: address(dex),
            tokenIn: address(0),
            tokenOut: address(usd),
            amountIn: 1 ether,
            amountOutMin: 1,
            path: _path(wnative, address(dai)), // out endpoint != tokenOut(usd)
            deadline: block.timestamp + 100
        });
        vm.expectRevert(BatchClearing.PathEndpointsMismatch.selector);
        h.route(r);
    }

    function test_RevertsOnMismatchedPath_TokenToNative() public {
        usd.mint(address(h), 1 ether);
        BatchClearing.Route memory r = BatchClearing.Route({
            router: address(dex),
            tokenIn: address(usd),
            tokenOut: address(0),
            amountIn: 1 ether,
            amountOutMin: 1,
            path: _path(address(dai), wnative), // in endpoint != tokenIn(usd)
            deadline: block.timestamp + 100
        });
        vm.expectRevert(BatchClearing.PathEndpointsMismatch.selector);
        h.route(r);
    }
}
