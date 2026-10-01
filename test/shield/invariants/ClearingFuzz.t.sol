// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldedPool} from "../../../contracts/shield/ShieldedPool.sol";
import {AssociationSetRegistry} from "../../../contracts/shield/AssociationSetRegistry.sol";
import {Goldilocks} from "../../../contracts/shield/libraries/Goldilocks.sol";
import {MockPoseidonGoldilocks} from "../mocks/MockPoseidonGoldilocks.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockDexRouter} from "../mocks/MockDexRouter.sol";

import {PoolDeploy, HandlerVerifier, ModelIntent, IntentWords} from "./PoolHandler.sol";

/// Residual clearing through the real pool. The residual is where the pool trades on its own
/// account, along a route the settler picks and no proof covers. Its ledger rules are checked
/// against a router that can deliver any amount.
contract ClearingFuzz is PoolDeploy {
    ShieldedPool internal pool;
    MockERC20 internal usd;
    MockDexRouter internal dex;
    uint64 internal usdId;
    bytes32 internal assoc = bytes32(uint256(0xA55C));
    address internal safe = makeAddr("safe");
    address internal alice = makeAddr("alice");
    uint256 internal counter;

    uint256 internal constant USD_SCALE = 1e6;

    function setUp() public {
        MockPoseidonGoldilocks h = new MockPoseidonGoldilocks();
        AssociationSetRegistry reg = new AssociationSetRegistry();
        reg.publishRoot(assoc, "");
        pool = _deployPool(safe, new HandlerVerifier(), h, reg, makeAddr("feeSink"));
        usd = new MockERC20("USD", "USD");
        usdId = _registerAsset(pool, safe, address(usd), USD_SCALE);
        dex = new MockDexRouter();
        usd.mint(address(dex), 1e40);

        vm.startPrank(safe);
        pool.endBetaMode();
        pool.proposeRouter(address(dex));
        vm.stopPrank();
        vm.warp(block.timestamp + pool.ROUTER_DELAY());
        pool.executeRouterApproval(address(dex));

        vm.deal(alice, 100 ether);
        vm.prank(alice);
        pool.absorb{value: 10 ether}(0, 10 ether, _digest());
        pool.commitRoot();
    }

    function _settleWithResidual(uint256 amountIn, uint256 price, uint256 minOut) internal {
        ModelIntent[] memory its = new ModelIntent[](1);
        its[0].noteRoot = pool.currentRoot();
        its[0].assocRoot = assoc;
        its[0].nf0 = _digest();
        its[0].nf1 = _digest();
        its[0].outCm0 = _digest();
        its[0].outCm1 = _digest();
        its[0].clearingPrice = price;
        ShieldedPool.ResidualExec memory r;
        r.router = address(dex);
        r.assetIn = 0;
        r.assetOut = usdId;
        r.amountIn = amountIn;
        r.amountOutMin = minOut;
        r.path = new address[](2);
        r.path[0] = address(0xEEEE);
        r.path[1] = address(usd);
        r.deadline = block.timestamp;
        pool.settleBatch(hex"00", IntentWords.encode(its), r, "", new bytes[](2));
    }

    /// Clearing never creates value. The input total falls by amountIn. The output total plus
    /// the fee dust rises by what arrived in the pool's balance. Both assets stay solvent.
    function testFuzz_clearingCreditsExactlyWhatArrived(uint256 amountIn, uint256 rate) public {
        amountIn = bound(amountIn, 1, pool.totalShielded(0));
        rate = bound(rate, 1e6, 1e24); // usd base units per 1e18 wei
        dex.setRate(rate);
        uint256 expectedOut = (amountIn * rate) / 1e18;
        vm.assume(expectedOut > 0);

        uint256 inBefore = pool.totalShielded(0);
        uint256 outBefore = pool.totalShielded(usdId);
        uint256 feesBefore = pool.unsweptFees(usdId);
        uint256 balBefore = usd.balanceOf(address(pool));
        _settleWithResidual(amountIn, 0, expectedOut);

        assertEq(inBefore - pool.totalShielded(0), amountIn, "input total did not fall by amountIn");
        uint256 arrived = usd.balanceOf(address(pool)) - balBefore;
        uint256 credited = pool.totalShielded(usdId) - outBefore;
        uint256 dust = pool.unsweptFees(usdId) - feesBefore;
        assertEq(credited + dust, arrived, "credited plus dust differs from what arrived");
        assertEq(credited % USD_SCALE, 0, "a fraction of a unit was shielded");
        assertLt(dust, USD_SCALE, "more than a unit went to fees");
        assertGe(address(pool).balance, pool.totalShielded(0) + pool.totalClaimable(0) + pool.unsweptFees(0));
        assertGe(
            usd.balanceOf(address(pool)),
            pool.totalShielded(usdId) + pool.totalClaimable(usdId) + pool.unsweptFees(usdId)
        );
    }

    /// A floor below the band is refused before anything moves.
    function testFuzz_aFloorBelowTheBandIsRefused(uint256 amountIn, uint256 priceUnits) public {
        amountIn = bound(amountIn, 1e12, pool.totalShielded(0));
        priceUnits = bound(priceUnits, 1e12, 18_446_744_069_414_584_320); // below p, so the band check is what refuses
        uint256 anchored = (amountIn * priceUnits * USD_SCALE) / 1e18;
        uint256 floor = (anchored * (10_000 - pool.residualBandBps())) / 10_000;
        vm.assume(floor > 0);
        vm.expectRevert(ShieldedPool.ResidualBelowBand.selector);
        this.settleExternal(amountIn, priceUnits, floor - 1);
    }

    function settleExternal(uint256 amountIn, uint256 price, uint256 minOut) external {
        _settleWithResidual(amountIn, price, minOut);
    }

    /// Every shielded total is a whole number of note units, so every base unit the pool holds for
    /// notes can be withdrawn by some note. The part of a residual below one unit goes to the fee
    /// router instead of the shielded total.
    function test_aResidualShieldsOnlyWholeUnits() public {
        dex.setRate(1_234_567_891); // 1 ether in, 1_234_567_891 usd base units out: 1234.567891 units
        _settleWithResidual(1 ether, 0, 1);
        assertEq(pool.totalShielded(usdId) % USD_SCALE, 0, "a fraction of a unit was shielded");
    }

    /// Rounding in the residual floor favours the pool: both divisions round up, so a route that
    /// delivers less than the exact band floor is refused.
    function test_theResidualFloorRoundsTowardThePool() public {
        vm.prank(safe);
        pool.setResidualBand(0);
        // one wei in at a price whose exact floor is 1.500000000001 usd base units: a settler
        // floor of 1 is below it and is refused
        dex.setRate(1e18);
        uint256 amountIn = 1;
        uint256 priceUnits = 1_500_000_000_001;
        uint256 exactNumerator = amountIn * priceUnits * USD_SCALE; // the exact floor times 1e18
        uint256 roundedDown = exactNumerator / 1e18;
        vm.expectRevert(ShieldedPool.ResidualBelowBand.selector);
        this.settleExternal(amountIn, priceUnits, roundedDown);
    }

    function _digest() internal returns (bytes32) {
        uint256 v = uint256(keccak256(abi.encode("clearing", ++counter)));
        uint256 acc;
        for (uint256 i = 0; i < 4; ++i) {
            acc |= (((v >> (64 * i)) & 0xFFFFFFFFFFFFFFFF) % Goldilocks.P) << (64 * i);
        }
        return bytes32(acc);
    }
}
