// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LaunchRulesPolicy} from "./mocks/LaunchRulesPolicy.sol";
import {ShieldTestBase, _blobsFor} from "./ShieldTestBase.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";
import {AmountPolicy} from "../../contracts/shield/AmountPolicy.sol";
import {RelayerRegistry, IRelayFeeCap} from "../../contracts/shield/RelayerRegistry.sol";

/// Standard amounts, the fee schedule and their timelocks, on the pool's real policy. Native asset at
/// scale 1, so a unit is a wei. The suite's pool takes 0.25% on deposits and withdrawals; a private
/// transfer pays a flat protocol fee, and a relayed settlement adds one rung of the gas ladder.
contract AmountPolicyTest is ShieldTestBase {
    AmountPolicy internal policy;
    uint256 internal constant FLAT = 1e15;
    uint256 internal constant NEW_FLAT = 2e15;
    uint64 internal constant PROTO = 5e14;
    uint256 internal constant RUNG = 1e15;

    event RangeSet(uint64 indexed assetId, uint8 minExp, uint8 maxExp, uint256 fee);
    event RangeQueued(uint64 indexed assetId, uint8 minExp, uint8 maxExp, uint256 fee, uint64 eta);
    event RangeActivated(uint64 indexed assetId, uint8 minExp, uint8 maxExp, uint256 fee, uint64 graceUntil);

    function _launchAmountRules() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        policy = pool.amountPolicy();
    }

    function _init(uint64 assetId, uint8 minExp, uint8 maxExp, uint256 fee) internal {
        uint64[] memory ids = new uint64[](1);
        uint8[] memory mins = new uint8[](1);
        uint8[] memory maxs = new uint8[](1);
        uint256[] memory fees = new uint256[](1);
        ids[0] = assetId;
        mins[0] = minExp;
        maxs[0] = maxExp;
        fees[0] = fee;
        vm.startPrank(safe);
        policy.initRanges(ids, mins, maxs, fees);
        uint64[] memory proto = new uint64[](1);
        proto[0] = PROTO;
        uint64[4][] memory ladders = new uint64[4][](1);
        ladders[0] = [uint64(RUNG), 2e15, 4e15, 8e15];
        policy.initSchedules(ids, proto, ladders);
        vm.stopPrank();
    }

    /// The protocol part of a withdrawal of `amount`: the suite's 0.25%.
    function _pct(uint256 amount) internal pure returns (uint256) {
        return amount * UNSHIELD_FEE_BPS / 10_000;
    }

    /// Native ETH from 0.001 to 50 ETH, with the schedule above.
    function _initEth() internal {
        _init(0, 15, 19, FLAT);
    }

    function _intent(uint256 publicAmount, uint256 fee, address to, address feeTo)
        internal
        returns (uint256[] memory w)
    {
        TIntent[] memory ins = new TIntent[](1);
        ins[0] = newIntent(publicAmount, fee, to, 0);
        ins[0].feeRecipient = feeTo;
        w = encodeBatch(pool.currentRoot(), assocRoot, 0, ins);
    }

    function _expectSettleReverts(uint256[] memory w, bytes4 err) internal {
        vm.expectRevert(err);
        settle(w);
    }

    // -- wiring and failing closed ---------------------------------------------------

    function test_thePoolCreatesItsPolicyOwnedByItsOwner() public view {
        assertEq(address(policy.pool()), address(pool), "pool");
        assertEq(policy.owner(), safe, "owner");
        (,,, bool ranged) = policy.rules(0);
        assertFalse(ranged, "no range until the owner sets one");
    }

    /// An asset with no range takes no deposit.
    function test_anUnrangedAssetCannotBeDeposited() public {
        vm.prank(alice);
        vm.expectRevert(AmountPolicy.NotRanged.selector);
        pool.absorb{value: 1 ether}(0, 1 ether, fresh());
    }

    /// An asset with no range settles nothing: no withdrawal and no private transfer, fee or not.
    function test_anUnrangedAssetSettlesNothing() public {
        _expectSettleReverts(_intent(1 ether, 0, bob, address(0)), AmountPolicy.NotRanged.selector);
        _expectSettleReverts(_intent(0, 0, address(0), address(0)), AmountPolicy.NotRanged.selector);
        _expectSettleReverts(_intent(0, 1, address(0), relayer), AmountPolicy.NotRanged.selector);
    }

    /// Ranging one asset leaves every other asset closed.
    function test_rangingOneAssetLeavesTheOthersClosed() public {
        _initEth();
        depositNative(alice, 1 ether);
        vm.startPrank(alice);
        usd.approve(address(pool), type(uint256).max);
        vm.expectRevert(AmountPolicy.NotRanged.selector);
        pool.absorb(usdAssetId, 1e18, fresh());
        vm.stopPrank();
    }

    // -- the first range -------------------------------------------------------------

    function test_initRangesSetsEveryListedAssetAtOnceAndEmits() public {
        uint64[] memory ids = new uint64[](2);
        uint8[] memory mins = new uint8[](2);
        uint8[] memory maxs = new uint8[](2);
        uint256[] memory fees = new uint256[](2);
        (ids[0], mins[0], maxs[0], fees[0]) = (0, 15, 19, FLAT);
        (ids[1], mins[1], maxs[1], fees[1]) = (usdAssetId, 18, 19, 1e18);
        vm.expectEmit(true, false, false, true, address(policy));
        emit RangeSet(0, 15, 19, FLAT);
        vm.expectEmit(true, false, false, true, address(policy));
        emit RangeSet(usdAssetId, 18, 19, 1e18);
        vm.prank(safe);
        policy.initRanges(ids, mins, maxs, fees);

        (uint64 fee, uint8 minExp, uint8 maxExp, bool ranged) = policy.rules(usdAssetId);
        assertEq(fee, 1e18);
        assertEq(minExp, 18);
        assertEq(maxExp, 19);
        assertTrue(ranged);

        // a range alone does not open an asset: it has no fee schedule yet, so it fails closed
        vm.prank(alice);
        vm.expectRevert(AmountPolicy.NoSchedule.selector);
        pool.absorb{value: 1 ether}(0, 1 ether, fresh());
        uint64[] memory one = new uint64[](1);
        uint64[] memory proto = new uint64[](1);
        proto[0] = PROTO;
        uint64[4][] memory ladders = new uint64[4][](1);
        ladders[0] = [uint64(RUNG), 2e15, 4e15, 8e15];
        vm.prank(safe);
        policy.initSchedules(one, proto, ladders);
        depositNative(alice, 1 ether);
    }

    function test_initRangesIsOwnerOnlyAndBounded() public {
        uint64[] memory ids = new uint64[](1);
        uint8[] memory mins = new uint8[](1);
        uint8[] memory maxs = new uint8[](1);
        uint256[] memory fees = new uint256[](1);
        vm.expectRevert();
        policy.initRanges(ids, mins, maxs, fees);

        vm.startPrank(safe);
        (mins[0], maxs[0]) = (5, 4);
        vm.expectRevert(AmountPolicy.BadRange.selector);
        policy.initRanges(ids, mins, maxs, fees);
        (mins[0], maxs[0]) = (0, 20);
        vm.expectRevert(AmountPolicy.BadRange.selector);
        policy.initRanges(ids, mins, maxs, fees);
        (maxs[0], fees[0]) = (19, 0xFFFFFFFF00000001 - 1);
        vm.expectRevert(AmountPolicy.FeeOutOfRange.selector);
        policy.initRanges(ids, mins, maxs, fees);
        (ids[0], fees[0]) = (99, 1);
        vm.expectRevert(AmountPolicy.UnknownAsset.selector);
        policy.initRanges(ids, mins, maxs, fees);
        vm.expectRevert(AmountPolicy.LengthMismatch.selector);
        policy.initRanges(ids, mins, maxs, new uint256[](0));
        vm.stopPrank();
    }

    /// A second first range is refused: a change of a ranged asset waits for the timelock.
    function test_initRangesRefusesARangedAsset() public {
        _initEth();
        uint64[] memory ids = new uint64[](1);
        uint8[] memory mins = new uint8[](1);
        uint8[] memory maxs = new uint8[](1);
        uint256[] memory fees = new uint256[](1);
        vm.prank(safe);
        vm.expectRevert(AmountPolicy.AlreadyRanged.selector);
        policy.initRanges(ids, mins, maxs, fees);
    }

    // -- the standard-amount rule ----------------------------------------------------

    /// Every digit d and exponent k: d x 10^k is standard exactly when d is 1, 2 or 5.
    function test_everyLeadingDigitAtEveryExponent() public {
        _init(0, 0, 19, 0);
        for (uint256 k = 0; k <= 19; ++k) {
            for (uint256 d = 1; d <= 9; ++d) {
                bool want = d == 1 || d == 2 || d == 5;
                assertEq(policy.isStandard(0, d * 10 ** k), want, "d x 10^k");
            }
        }
    }

    function test_edgeAmountsAreRefused() public {
        _init(0, 0, 19, 0);
        assertFalse(policy.isStandard(0, 0), "zero");
        assertFalse(policy.isStandard(0, 3), "three");
        assertFalse(policy.isStandard(0, 25), "two digits");
        assertFalse(policy.isStandard(0, 1_000_001), "10^6 + 1");
        assertFalse(policy.isStandard(0, 999_999), "10^6 - 1");
        assertFalse(policy.isStandard(0, 10 ** 20), "exponent above the range");
        assertFalse(policy.isStandard(0, type(uint256).max), "largest word");
        assertFalse(policy.isStandard(0, 10 ** 77), "largest power of ten in a word");
    }

    function test_theRangeBoundsTheExponent() public {
        _init(0, 2, 4, 0);
        assertFalse(policy.isStandard(0, 50), "k = 1");
        assertTrue(policy.isStandard(0, 100), "k = 2");
        assertTrue(policy.isStandard(0, 50_000), "k = 4");
        assertFalse(policy.isStandard(0, 100_000), "k = 5");
    }

    function test_nothingIsStandardWithoutARange() public view {
        assertFalse(policy.isStandard(0, 1), "one");
        assertFalse(policy.isStandard(usdAssetId, 10 ** 18), "a power of ten");
    }

    function testFuzz_standardMatchesTheDefinition(uint256 units) public {
        _init(0, 0, 19, 0);
        uint256 v = units;
        uint256 k;
        while (v != 0 && v % 10 == 0) {
            v /= 10;
            ++k;
        }
        bool want = (v == 1 || v == 2 || v == 5) && k <= 19;
        assertEq(policy.isStandard(0, units), want);
    }

    // -- deposits --------------------------------------------------------------------

    function test_standardDepositsAreAcceptedAndOthersRefused() public {
        _initEth();
        depositNative(alice, 1 ether);
        depositNative(alice, 2 ether);
        depositNative(alice, 5e15);

        vm.startPrank(alice);
        vm.expectRevert(AmountPolicy.NonStandardAmount.selector);
        pool.absorb{value: 3 ether}(0, 3 ether, fresh());
        vm.expectRevert(AmountPolicy.NonStandardAmount.selector);
        pool.absorb{value: 1 ether + 1}(0, 1 ether + 1, fresh());
        vm.expectRevert(AmountPolicy.NonStandardAmount.selector);
        pool.absorb{value: 1e14}(0, 1e14, fresh());
        vm.stopPrank();
    }

    /// The rule reads note units: at scale 10^12, 5 x 10^18 base units is 5 x 10^6 units.
    function test_theRuleCountsNoteUnitsNotBaseUnits() public {
        vm.prank(safe);
        uint64 id = pool.registerAsset(address(nox), 1e12);
        _init(id, 6, 6, 0);
        nox.mint(alice, 1e25);
        vm.startPrank(alice);
        nox.approve(address(pool), type(uint256).max);
        pool.absorb(id, 5e18, fresh());
        vm.expectRevert(AmountPolicy.NonStandardAmount.selector);
        pool.absorb(id, 5e19, fresh());
        vm.stopPrank();
    }

    // -- withdrawals -----------------------------------------------------------------

    function test_aStandardWithdrawalPaysItsPercentAndARung() public {
        _initEth();
        depositNative(alice, 10 ether);
        uint256 before = bob.balance;
        settle(_intent(1 ether, _pct(1 ether) + RUNG, bob, relayer));
        assertEq(bob.balance - before, 1 ether, "recipient");
        assertEq(pool.claimable(0, relayer), RUNG, "the relayer is credited the rung");
    }

    function test_aNonStandardWithdrawalIsRefused() public {
        _initEth();
        depositNative(alice, 10 ether);
        _expectSettleReverts(_intent(1 ether + 1, RUNG, bob, relayer), AmountPolicy.NonStandardAmount.selector);
        _expectSettleReverts(_intent(3 ether, 0, bob, address(0)), AmountPolicy.NonStandardAmount.selector);
    }

    function test_aWithdrawalFeeOffTheLadderIsRefused() public {
        _initEth();
        depositNative(alice, 10 ether);
        uint256[] memory w = _intent(1 ether, _pct(1 ether) + RUNG - 1, bob, relayer);
        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.FeeNotOnLadder.selector, RUNG - 1));
        settle(w);
        w = _intent(1 ether, _pct(1 ether) + RUNG + 1, bob, relayer);
        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.FeeNotOnLadder.selector, RUNG + 1));
        settle(w);
    }

    /// Self-submission: no fee recipient, and the fee is the percentage alone.
    function test_aSelfSubmittedWithdrawalPaysOnlyItsPercent() public {
        _initEth();
        depositNative(alice, 10 ether);
        uint256 before = bob.balance;
        settle(_intent(2 ether, _pct(2 ether), bob, address(0)));
        assertEq(bob.balance - before, 2 ether);
    }

    /// The old cap of 0.5% on a whole withdrawal fee is gone: the percentage is bounded by the
    /// policy, and the gas rung by the ladder, so a small relayed withdrawal settles.
    function test_aSmallRelayedWithdrawalSettles() public {
        _init(0, 12, 19, FLAT);
        depositNative(alice, 10 ether);
        settle(_intent(1e17, _pct(1e17) + RUNG, bob, relayer));
        assertEq(pool.claimable(0, relayer), RUNG);
    }

    // -- private transfers -----------------------------------------------------------

    /// A private transfer's amount stays private: its fee is the flat protocol fee, plus one rung when
    /// relayed.
    function test_aTransferPaysTheProtocolFeeAndARung() public {
        _initEth();
        depositNative(alice, 10 ether);
        settle(_intent(0, PROTO + RUNG, address(0), relayer));
        assertEq(pool.claimable(0, relayer), RUNG, "the rung");
        settle(_intent(0, PROTO, address(0), address(0)));
        uint256[] memory w = _intent(0, PROTO + RUNG / 2, address(0), relayer);
        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.FeeNotOnLadder.selector, RUNG / 2));
        settle(w);
        w = _intent(0, 0, address(0), address(0));
        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.FeeBelowProtocolPart.selector, uint256(0), uint256(PROTO)));
        settle(w);
    }

    /// Whoever submits earns the rung.
    function test_bountyModePaysTheSubmitterTheRung() public {
        _initEth();
        depositNative(alice, 10 ether);
        address carol = makeAddr("carol");
        uint256[] memory w = _intent(1 ether, _pct(1 ether) + RUNG, bob, pool.SUBMITTER());
        vm.prank(carol);
        pool.settleBatch(hex"70726f6f66", w, noResidual(), "", _blobsFor(w));
        assertEq(pool.claimable(0, carol), RUNG, "submitter");
    }

    // -- changes, behind the timelock ------------------------------------------------

    function _queue(uint8 minExp, uint8 maxExp, uint256 fee) internal {
        vm.prank(safe);
        policy.queueRange(0, minExp, maxExp, fee);
    }

    function test_queueRangeIsOwnerOnlyAnnouncedAndBounded() public {
        _initEth();
        vm.expectRevert();
        policy.queueRange(0, 15, 19, NEW_FLAT);
        uint64 eta = uint64(block.timestamp + 48 hours);
        vm.expectEmit(true, false, false, true, address(policy));
        emit RangeQueued(0, 16, 19, NEW_FLAT, eta);
        _queue(16, 19, NEW_FLAT);
        (uint64 fee, uint8 minExp, uint8 maxExp, uint64 at) = policy.pending(0);
        assertEq(fee, NEW_FLAT);
        assertEq(minExp, 16);
        assertEq(maxExp, 19);
        assertEq(at, eta);

        vm.startPrank(safe);
        vm.expectRevert(AmountPolicy.BadRange.selector);
        policy.queueRange(0, 19, 18, 0);
        vm.expectRevert(AmountPolicy.NotRanged.selector);
        policy.queueRange(usdAssetId, 0, 1, 0);
        vm.stopPrank();
    }

    /// Queue, too early, activate, grace, after grace: the whole life of one change.
    function test_aRangeChangeTakesEffectOnlyAfterTheDelay() public {
        _initEth();
        depositNative(alice, 10 ether);
        _queue(18, 19, NEW_FLAT);

        // during the window: the old range rules
        depositNative(alice, 1e15);

        // too early
        vm.warp(block.timestamp + 48 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.TooEarly.selector, uint64(block.timestamp + 1)));
        policy.activateRange(0);

        // activate, by anyone
        vm.warp(block.timestamp + 1);
        uint64 graceUntil = uint64(block.timestamp + 1 hours);
        vm.expectEmit(true, false, false, true, address(policy));
        emit RangeActivated(0, 18, 19, NEW_FLAT, graceUntil);
        vm.prank(bob);
        policy.activateRange(0);
        assertEq(policy.maxRelayFee(0), NEW_FLAT, "new fee in force");

        // the new range is in force at once
        vm.prank(alice);
        vm.expectRevert(AmountPolicy.NonStandardAmount.selector);
        pool.absorb{value: 1e15}(0, 1e15, fresh());
        depositNative(alice, 1 ether);

        // settlement follows the fee schedule, which the range change leaves alone
        settle(_intent(0, PROTO + RUNG, address(0), relayer));

        vm.expectRevert(AmountPolicy.NothingPending.selector);
        policy.activateRange(0);
    }

    function test_aCancelledRangeChangeNeverTakesEffect() public {
        _initEth();
        depositNative(alice, 10 ether);
        _queue(15, 19, NEW_FLAT);
        vm.expectRevert();
        policy.cancelRange(0);
        vm.prank(safe);
        policy.cancelRange(0);
        (,,, uint64 at) = policy.pending(0);
        assertEq(at, 0, "nothing pending");
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(AmountPolicy.NothingPending.selector);
        policy.activateRange(0);
    }

    /// A new queue replaces the old one and restarts its delay.
    function test_requeueingRestartsTheDelay() public {
        _initEth();
        _queue(15, 19, NEW_FLAT);
        vm.warp(block.timestamp + 47 hours);
        _queue(15, 19, 3e15);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert();
        policy.activateRange(0);
        vm.warp(block.timestamp + 47 hours);
        policy.activateRange(0);
        assertEq(policy.maxRelayFee(0), 3e15);
    }

    // -- the relayer registry --------------------------------------------------------

    /// With a flat fee the registry reports it for every active relayer and takes no fee of its own.
    function test_theRegistryReportsTheFlatFeeAndRefusesItsOwn() public {
        _initEth();
        RelayerRegistry reg = new RelayerRegistry(IRelayFeeCap(address(policy)));
        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        reg.register{value: 0.05 ether}(relayer, "a.onion", new uint64[](0), new uint256[](0));
        assertEq(reg.feeOf(relayer, 0), FLAT, "the flat fee");

        uint64[] memory ids = new uint64[](1);
        uint256[] memory fees = new uint256[](1);
        fees[0] = FLAT;
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(RelayerRegistry.FlatFeeAsset.selector, uint64(0)));
        reg.setFees(ids, fees);

        // an asset with no range has neither a flat fee nor room for one: its cap is zero
        ids[0] = usdAssetId;
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(RelayerRegistry.FeeAboveCap.selector, usdAssetId, FLAT, 0));
        reg.setFees(ids, fees);
        assertEq(reg.feeOf(relayer, usdAssetId), 0);
    }
}
