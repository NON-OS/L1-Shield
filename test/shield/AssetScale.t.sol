// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase} from "./ShieldTestBase.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";
import {Goldilocks} from "../../contracts/shield/libraries/Goldilocks.sol";
import {IStarkVerifier} from "../../contracts/shield/interfaces/IStarkVerifier.sol";
import {IPoseidonGoldilocks} from "../../contracts/shield/interfaces/IPoseidonGoldilocks.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// Per-asset unit scale: notes, fees and public amounts count units, and every on-chain
/// amount is units times the asset's scale.
contract AssetScaleTest is ShieldTestBase {
    uint256 internal constant GWEI = 1e9;

    MockERC20 internal wide;
    uint64 internal wideId;

    function setUp() public override {
        super.setUp();
        wide = new MockERC20("Wide", "WIDE");
        vm.prank(safe);
        wideId = pool.registerAsset(address(wide), GWEI);
        wide.mint(alice, 1e40);
        vm.prank(alice);
        wide.approve(address(pool), type(uint256).max);
    }

    function _newPool(uint256 nativeScale) internal returns (ShieldedPool) {
        return _newPool(nativeScale, _selfTest());
    }

    function _newPool(uint256 nativeScale, ShieldedPool.DeploymentSelfTest memory st) internal returns (ShieldedPool) {
        return new ShieldedPool(
            safe,
            IStarkVerifier(address(verifier)),
            IPoseidonGoldilocks(address(hasher)),
            registry,
            address(feeRouter),
            SHIELD_FEE_BPS,
            UNSHIELD_FEE_BPS,
            nativeScale,
            12,
            st
        );
    }

    function _commitmentOf(uint256 units, uint64 assetId, bytes32 owner) internal view returns (bytes32) {
        return hasher.hash2(
            bytes32(
                (units & 0xFFFFFFFF) | ((units >> 32) << 64) | (uint256(assetId) << 128)
                    | (uint256(pool.NOTE_DOMAIN()) << 192)
            ),
            owner
        );
    }

    // -- registration ------------------------------------------------------

    function test_theScaleIsFixedAtRegistrationAndEmitted() public {
        MockERC20 t = new MockERC20("T", "T");
        uint64 next = pool.nextAssetId();
        vm.expectEmit(true, true, false, true, address(pool));
        emit ShieldedPool.AssetRegistered(next, address(t), 1e6);
        vm.prank(safe);
        uint64 id = pool.registerAsset(address(t), 1e6);
        assertEq(pool.scale(id), 1e6);
        assertEq(pool.scale(wideId), GWEI);
    }

    function test_aScaleOfZeroOrAboveTheCapIsRefused() public {
        MockERC20 t = new MockERC20("T", "T");
        vm.startPrank(safe);
        vm.expectRevert(ShieldedPool.BadScale.selector);
        pool.registerAsset(address(t), 0);
        uint256 cap = pool.MAX_SCALE();
        vm.expectRevert(ShieldedPool.BadScale.selector);
        pool.registerAsset(address(t), cap + 1);
        uint64 id = pool.registerAsset(address(t), cap);
        vm.stopPrank();
        assertEq(pool.scale(id), cap, "the cap itself is allowed");
    }

    function test_onlyTheOwnerRegisters() public {
        MockERC20 t = new MockERC20("T", "T");
        vm.prank(alice);
        vm.expectRevert();
        pool.registerAsset(address(t), 1);
    }

    function test_theNativeScaleDefaultsToOneAndIsEmitted() public {
        assertEq(pool.scale(0), 1, "unconfigured native scale");
        vm.expectEmit(true, true, false, true);
        emit ShieldedPool.AssetRegistered(0, address(0), 1);
        _newPool(0);
    }

    function test_theNativeScaleCanBeConfiguredAtDeploy() public {
        ShieldedPool p = _newPool(GWEI);
        assertEq(p.scale(0), GWEI);
        ShieldedPool.DeploymentSelfTest memory st = _selfTest();
        vm.expectRevert(ShieldedPool.BadScale.selector);
        _newPool(1e18 + 1, st);
    }

    // -- absorb --------------------------------------------------------------

    /// A deposit that is not a whole number of units is refused, so no remainder sits outside a note.
    function test_aDepositWithARemainderIsRefused() public {
        vm.startPrank(alice);
        vm.expectRevert(ShieldedPool.InvalidAmount.selector);
        pool.absorb(wideId, 5 * GWEI + 1, fresh());
        vm.expectRevert(ShieldedPool.InvalidAmount.selector);
        pool.absorb(wideId, GWEI - 1, fresh()); // zero whole units
        vm.stopPrank();
    }

    /// The note commits to units, the ledger and the fee count base units, and nothing is left over.
    function test_aScaledDepositCommitsUnitsAndBooksBaseUnits() public {
        uint256 units = 12_345_678_901; // not a multiple of 400, so the fee rounds down
        uint256 feeUnits = (units * SHIELD_FEE_BPS) / 10_000;
        uint256 valueUnits = units - feeUnits;
        bytes32 owner = fresh();
        uint256 routerBefore = wide.balanceOf(address(feeRouter));

        vm.prank(alice);
        (bytes32 cm,) = pool.absorb(wideId, units * GWEI, owner);

        assertEq(cm, _commitmentOf(valueUnits, wideId, owner), "the commitment is over units");
        assertEq(pool.totalShielded(wideId), valueUnits * GWEI, "the ledger is in base units");
        assertEq(wide.balanceOf(address(feeRouter)) - routerBefore, feeUnits * GWEI, "a whole-unit fee");
        assertEq(wide.balanceOf(address(pool)), pool.totalShielded(wideId), "no dust in the pool");
    }

    /// MAX_VALUE bounds the deposit in units at any scale.
    function test_theValueCeilingIsInUnits() public {
        uint256 max = Goldilocks.MAX_VALUE;
        vm.startPrank(alice);
        pool.absorb(wideId, max * GWEI, fresh());
        vm.expectRevert(ShieldedPool.InvalidAmount.selector);
        pool.absorb(wideId, (max + 1) * GWEI, fresh());
        vm.stopPrank();
        assertGt(pool.totalShielded(wideId), 18e27, "about 18.4 billion whole tokens in one note");
    }

    function testFuzz_scaledDepositsLeaveNoDust(uint64 unitsRaw, uint8 exp) public {
        uint256 s = 10 ** (uint256(exp) % 19);
        MockERC20 t = new MockERC20("F", "F");
        vm.prank(safe);
        uint64 id = pool.registerAsset(address(t), s);
        uint256 units = bound(uint256(unitsRaw), 1, Goldilocks.MAX_VALUE);
        t.mint(alice, units * s);
        vm.startPrank(alice);
        t.approve(address(pool), units * s);
        pool.absorb(id, units * s, fresh());
        vm.stopPrank();
        assertEq(t.balanceOf(address(pool)), pool.totalShielded(id), "the pool holds exactly the notes");
        assertEq(pool.totalShielded(id) % s, 0, "whole units only");
    }

    // -- settlement ------------------------------------------------------------

    /// Public amount and fee are units. The payout, the credit and the debit are units times scale.
    function test_settlementPaysOutUnitsTimesScale() public {
        vm.prank(alice);
        pool.absorb(wideId, 1_000_000 * GWEI, fresh());
        uint256 shielded = pool.totalShielded(wideId);

        TIntent[] memory ins = new TIntent[](1);
        ins[0] = newIntent(400_000, 2_000, bob, wideId);
        ins[0].feeRecipient = relayer;
        settle(encodeBatch(pool.currentRoot(), assocRoot, 0, ins));

        assertEq(wide.balanceOf(bob), 400_000 * GWEI, "recipient paid units times scale");
        assertEq(pool.claimable(wideId, relayer), 2_000 * GWEI, "fee credited in base units");
        assertEq(shielded - pool.totalShielded(wideId), 402_000 * GWEI, "debit is (amount + fee) times scale");
        assertEq(
            wide.balanceOf(address(pool)),
            pool.totalShielded(wideId) + pool.totalClaimable(wideId) + pool.unsweptFees(wideId),
            "solvent to the base unit"
        );
    }

    // -- residual --------------------------------------------------------------

    function _approveDex() internal {
        vm.prank(safe);
        pool.proposeRouter(address(dex));
        vm.warp(block.timestamp + pool.ROUTER_DELAY());
        pool.executeRouterApproval(address(dex));
    }

    function _residual(uint256 amountIn, uint256 minOut) internal view returns (ShieldedPool.ResidualExec memory r) {
        r.router = address(dex);
        r.assetIn = 0;
        r.assetOut = wideId;
        r.amountIn = amountIn;
        r.amountOutMin = minOut;
        r.deadline = block.timestamp + 100;
        r.path = new address[](2);
        r.path[0] = address(0x1111);
        r.path[1] = address(wide);
    }

    /// The clearing price is units of assetOut per unit of assetIn. From native at scale 1 into a
    /// token at scale 1e9, 1e15 wei at a price of 3 units per unit must fetch 3e15 units, which is
    /// 3e24 base units. The band allows 2% under that, and one base unit less is refused.
    function test_theResidualFloorConvertsUnitsAcrossScales() public {
        depositNative(alice, 1 ether);
        _approveDex();
        wide.mint(address(dex), 1e30);
        uint256 price = 3e18;
        uint256 amountIn = 1e15;
        uint256 floorOut = (amountIn * 3 * GWEI * (10_000 - pool.residualBandBps())) / 10_000;
        dex.setRate(3 * GWEI * 1e18); // the dex pays at the clearing price

        TIntent[] memory ins = new TIntent[](1);
        ins[0] = newIntent(0, 0, address(0), 0);
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, price, ins);
        vm.expectRevert(ShieldedPool.ResidualBelowBand.selector);
        pool.settleBatch(hex"70", w, _residual(amountIn, floorOut - 1), "", _blobs(2));

        uint256 before = pool.totalShielded(wideId);
        pool.settleBatch(hex"70", w, _residual(amountIn, floorOut), "", _blobs(2));
        assertEq(pool.totalShielded(wideId) - before, amountIn * 3 * GWEI, "the residual arrived in base units");
    }

    /// The reverse direction divides by the scale: a token at 1e9 into native at 1.
    function test_theResidualFloorScalesDownIntoASmallerScale() public {
        vm.prank(alice);
        pool.absorb(wideId, 1_000 * GWEI, fresh());
        _approveDex();
        vm.deal(address(dex), 1 ether);
        uint256 amountIn = 500 * GWEI; // 500 units
        uint256 price = 2e18; // two wei per unit
        uint256 anchored = 1_000; // 500 units * 2 * scale 1
        uint256 floorOut = (anchored * (10_000 - pool.residualBandBps())) / 10_000;
        dex.setRate(2e18 / GWEI);

        ShieldedPool.ResidualExec memory r = _residual(amountIn, floorOut - 1);
        r.assetIn = wideId;
        r.assetOut = 0;
        r.path[0] = address(wide);
        r.path[1] = address(0x1111);
        TIntent[] memory ins = new TIntent[](1);
        ins[0] = newIntent(0, 0, address(0), 0);
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, price, ins);
        vm.expectRevert(ShieldedPool.ResidualBelowBand.selector);
        pool.settleBatch(hex"70", w, r, "", _blobs(2));
        r.amountOutMin = floorOut;
        pool.settleBatch(hex"70", w, r, "", _blobs(2));
    }

    /// A residual that is not a whole number of the input asset's units is refused.
    function test_aResidualOfPartialUnitsIsRefused() public {
        vm.prank(alice);
        pool.absorb(wideId, 1_000 * GWEI, fresh());
        _approveDex();
        ShieldedPool.ResidualExec memory r = _residual(GWEI + 1, 1);
        r.assetIn = wideId;
        r.assetOut = 0;
        TIntent[] memory ins = new TIntent[](1);
        ins[0] = newIntent(0, 0, address(0), 0);
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 1e18, ins);
        vm.expectRevert(ShieldedPool.InvalidAmount.selector);
        pool.settleBatch(hex"70", w, r, "", _blobs(2));
    }

    /// The unit bound on a public amount holds at any scale, and the product cannot overflow.
    function test_aPublicAmountAtTheCeilingDecodesAtTheLargestScale() public {
        MockERC20 t = new MockERC20("M", "M");
        uint256 cap = pool.MAX_SCALE();
        vm.prank(safe);
        uint64 id = pool.registerAsset(address(t), cap);
        TIntent[] memory ins = new TIntent[](1);
        ins[0] = newIntent(Goldilocks.MAX_VALUE, 0, bob, id);
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 0, ins);
        // decoded and multiplied without overflow, then refused because nothing backs it
        vm.expectRevert(ShieldedPool.ShieldedBalanceUnderflow.selector);
        settle(w);
    }
}

function _blobs(uint256 n) pure returns (bytes[] memory b) {
    b = new bytes[](n);
}
