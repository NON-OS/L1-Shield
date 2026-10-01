// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase} from "./ShieldTestBase.sol";
import {RelayerRegistry, IRelayFeeCap} from "../../contracts/shield/RelayerRegistry.sol";

/// Tries to take its bond twice by calling withdrawBond again from its receive hook.
contract ReentrantRelayer {
    RelayerRegistry internal reg;
    bool public reentered;
    uint256 public received;

    constructor(RelayerRegistry reg_) {
        reg = reg_;
    }

    function join(uint256 bond) external {
        reg.register{value: bond}(address(this), "reentrant.onion", new uint64[](0), new uint256[](0));
        reg.deregister();
    }

    function exit() external {
        reg.withdrawBond();
    }

    receive() external payable {
        received += msg.value;
        try reg.withdrawBond() {
            reentered = true;
        } catch {}
    }
}

/// A relayer that refuses its own bond.
contract RefusingRelayer {
    function join(RelayerRegistry reg) external payable {
        reg.register{value: msg.value}(address(this), "refuse.onion", new uint64[](0), new uint256[](0));
        reg.deregister();
    }

    function exit(RelayerRegistry reg) external {
        reg.withdrawBond();
    }
}

contract RelayerRegistryTest is ShieldTestBase {
    RelayerRegistry internal reg;
    uint256 internal constant CAP = 1000;
    uint256 internal constant BOND = 0.05 ether;
    uint256 internal constant DELAY = 7 days;
    string internal constant ONION = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz2345.onion";

    event RelayerRegistered(address indexed operator, address indexed feeRecipient, uint256 bond, string endpoint);
    event EndpointUpdated(address indexed operator, string endpoint);
    event FeeSet(address indexed operator, uint64 indexed assetId, uint256 units);
    event DeregistrationStarted(address indexed operator, uint64 withdrawableAt);
    event BondWithdrawn(address indexed operator, uint256 amount);

    function setUp() public override {
        super.setUp();
        reg = new RelayerRegistry(IRelayFeeCap(address(pool.amountPolicy())));
        setRelayCap(0, CAP);
        setRelayCap(usdAssetId, CAP * 2);
    }

    function _one(uint64 id, uint256 fee) internal pure returns (uint64[] memory ids, uint256[] memory fees) {
        ids = new uint64[](1);
        fees = new uint256[](1);
        ids[0] = id;
        fees[0] = fee;
    }

    function _join(address op, uint256 fee) internal {
        (uint64[] memory ids, uint256[] memory fees) = _one(0, fee);
        vm.deal(op, op.balance + 1 ether);
        vm.prank(op);
        reg.register{value: BOND}(op, ONION, ids, fees);
    }

    function _exit(address op) internal {
        vm.prank(op);
        reg.deregister();
    }

    /// The bond and the delay are the figures the tests assume.
    function test_constants() public view {
        assertEq(reg.MIN_BOND(), BOND);
        assertEq(reg.EXIT_DELAY(), DELAY);
        assertEq(address(reg.pool()), address(pool.amountPolicy()), "the pool's amount policy");
    }

    /// Anyone registers with a bond, an endpoint and fees, and every field and event lands.
    function test_registerRecordsEverythingAndEmits() public {
        (uint64[] memory ids, uint256[] memory fees) = _one(usdAssetId, CAP * 2);
        vm.deal(relayer, 1 ether);
        vm.expectEmit(true, true, false, true);
        emit RelayerRegistered(relayer, bob, 0.06 ether, ONION);
        vm.expectEmit(true, true, false, true);
        emit FeeSet(relayer, usdAssetId, CAP * 2);
        vm.prank(relayer);
        reg.register{value: 0.06 ether}(bob, ONION, ids, fees);

        RelayerRegistry.Relayer memory r = reg.relayerOf(relayer);
        assertEq(r.feeRecipient, bob);
        assertTrue(r.active);
        assertEq(r.exitAt, 0);
        assertEq(r.bond, 0.06 ether);
        assertEq(r.endpoint, ONION);
        assertEq(reg.feeOf(relayer, usdAssetId), CAP * 2);
        assertEq(reg.feeOf(relayer, 0), 0, "an asset not set is not served");
        assertEq(reg.relayerCount(), 1);
        assertEq(address(reg).balance, 0.06 ether);
    }

    /// A bond under MIN_BOND, a zero fee recipient and an empty or oversized endpoint are refused.
    function test_registerRefusesBadInputs() public {
        vm.deal(relayer, 1 ether);
        uint256 bond = reg.MIN_BOND();
        vm.startPrank(relayer);
        vm.expectRevert(RelayerRegistry.BondTooSmall.selector);
        reg.register{value: bond - 1}(relayer, ONION, new uint64[](0), new uint256[](0));
        vm.expectRevert(RelayerRegistry.ZeroAddress.selector);
        reg.register{value: bond}(address(0), ONION, new uint64[](0), new uint256[](0));
        vm.expectRevert(RelayerRegistry.BadEndpoint.selector);
        reg.register{value: bond}(relayer, "", new uint64[](0), new uint256[](0));
        vm.expectRevert(RelayerRegistry.BadEndpoint.selector);
        reg.register{value: bond}(relayer, string(new bytes(129)), new uint64[](0), new uint256[](0));
        vm.expectRevert(RelayerRegistry.LengthMismatch.selector);
        reg.register{value: bond}(relayer, ONION, new uint64[](1), new uint256[](0));
        vm.stopPrank();
    }

    /// An operator holds one registration until its bond is withdrawn.
    function test_registerTwiceIsRefused() public {
        _join(relayer, 1);
        vm.expectRevert(RelayerRegistry.AlreadyRegistered.selector);
        _join(relayer, 1);
        _exit(relayer);
        vm.expectRevert(RelayerRegistry.AlreadyRegistered.selector);
        _join(relayer, 1);
    }

    /// A fee over the pool's cap is refused at registration and on update.
    function test_feeAboveTheCapIsRefused() public {
        (uint64[] memory ids, uint256[] memory fees) = _one(0, CAP + 1);
        vm.deal(relayer, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(RelayerRegistry.FeeAboveCap.selector, uint64(0), CAP + 1, CAP));
        vm.prank(relayer);
        reg.register{value: 0.05 ether}(relayer, ONION, ids, fees);

        _join(relayer, CAP);
        vm.expectRevert(abi.encodeWithSelector(RelayerRegistry.FeeAboveCap.selector, uint64(0), CAP + 1, CAP));
        vm.prank(relayer);
        reg.setFees(ids, fees);
    }

    /// An asset the pool does not know has cap zero, so any fee on it is refused.
    function test_feeOnAnUnknownAssetIsRefused() public {
        (uint64[] memory ids, uint256[] memory fees) = _one(99, 1);
        _join(relayer, 1);
        vm.expectRevert(abi.encodeWithSelector(RelayerRegistry.FeeAboveCap.selector, uint64(99), 1, 0));
        vm.prank(relayer);
        reg.setFees(ids, fees);
    }

    /// Fee and endpoint updates land and emit, and only an active relayer may make them.
    function test_updatesLandAndEmit() public {
        _join(relayer, 5);
        (uint64[] memory ids, uint256[] memory fees) = _one(0, 7);
        vm.expectEmit(true, true, false, true);
        emit FeeSet(relayer, 0, 7);
        vm.prank(relayer);
        reg.setFees(ids, fees);
        assertEq(reg.feeOf(relayer, 0), 7);

        vm.expectEmit(true, false, false, true);
        emit EndpointUpdated(relayer, "new.onion");
        vm.prank(relayer);
        reg.updateEndpoint("new.onion");
        assertEq(reg.relayerOf(relayer).endpoint, "new.onion");

        vm.startPrank(alice);
        vm.expectRevert(RelayerRegistry.NotActive.selector);
        reg.setFees(ids, fees);
        vm.expectRevert(RelayerRegistry.NotActive.selector);
        reg.updateEndpoint("x.onion");
        vm.expectRevert(RelayerRegistry.NotActive.selector);
        reg.deregister();
        vm.stopPrank();
    }

    /// A deregistered relayer leaves the list at once and quotes no fee.
    function test_deregisterLeavesTheList() public {
        _join(relayer, 5);
        vm.expectEmit(true, false, false, true);
        emit DeregistrationStarted(relayer, uint64(block.timestamp + DELAY));
        _exit(relayer);
        assertEq(reg.relayerCount(), 0);
        assertEq(reg.feeOf(relayer, 0), 0);
        assertFalse(reg.relayerOf(relayer).active);
        vm.expectRevert(RelayerRegistry.NotActive.selector);
        vm.prank(relayer);
        reg.updateEndpoint("x.onion");
    }

    /// The bond is locked until EXIT_DELAY after deregistration, then paid once.
    function test_bondWithdrawsOnceAfterTheDelay() public {
        _join(relayer, 5);
        vm.expectRevert(RelayerRegistry.NotExiting.selector);
        vm.prank(relayer);
        reg.withdrawBond();

        _exit(relayer);
        uint64 at = uint64(block.timestamp + reg.EXIT_DELAY());
        vm.warp(at - 1);
        vm.expectRevert(abi.encodeWithSelector(RelayerRegistry.ExitDelayPending.selector, at));
        vm.prank(relayer);
        reg.withdrawBond();

        vm.warp(at);
        uint256 before = relayer.balance;
        vm.expectEmit(true, false, false, true);
        emit BondWithdrawn(relayer, 0.05 ether);
        vm.prank(relayer);
        reg.withdrawBond();
        assertEq(relayer.balance - before, 0.05 ether);
        assertEq(address(reg).balance, 0);

        vm.expectRevert(RelayerRegistry.NotExiting.selector);
        vm.prank(relayer);
        reg.withdrawBond();
    }

    /// A re-registration starts with no fees from the last one.
    function test_reRegistrationStartsClean() public {
        _join(relayer, 5);
        _exit(relayer);
        vm.warp(block.timestamp + reg.EXIT_DELAY());
        vm.prank(relayer);
        reg.withdrawBond();
        vm.prank(relayer);
        reg.register{value: 0.05 ether}(relayer, ONION, new uint64[](0), new uint256[](0));
        assertEq(reg.feeOf(relayer, 0), 0);
        assertEq(reg.registrations(relayer), 2);
    }

    /// A receive hook that calls withdrawBond again gets nothing more.
    function test_withdrawalCannotBeReentered() public {
        ReentrantRelayer r = new ReentrantRelayer(reg);
        vm.deal(address(r), 1 ether);
        r.join(0.05 ether);
        _join(alice, 1); // a second bond the attacker would drain
        vm.warp(block.timestamp + reg.EXIT_DELAY());
        r.exit();
        assertFalse(r.reentered());
        assertEq(r.received(), 0.05 ether);
        assertEq(address(reg).balance, 0.05 ether, "the other bond stays");
    }

    /// A relayer that refuses ETH keeps its record, and the bond stays for a later try.
    function test_refusedPaymentKeepsTheBond() public {
        RefusingRelayer r = new RefusingRelayer();
        r.join{value: 0.05 ether}(reg);
        vm.warp(block.timestamp + reg.EXIT_DELAY());
        vm.expectRevert(RelayerRegistry.TransferFailed.selector);
        r.exit(reg);
        assertEq(reg.relayerOf(address(r)).bond, 0.05 ether);
        assertEq(address(reg).balance, 0.05 ether);
    }

    /// The registry takes no plain ETH, so its balance moves only with bonds.
    function test_plainEthIsRefused() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(reg).call{value: 1}("");
        assertFalse(ok);
    }

    /// Any bond at or above MIN_BOND and any fee at or under the cap registers. Over the cap does not.
    function testFuzz_registerBondAndFee(uint256 bond, uint256 fee, bool over) public {
        bond = bound(bond, reg.MIN_BOND(), 1000 ether);
        fee = over ? bound(fee, CAP + 1, type(uint256).max) : bound(fee, 0, CAP);
        (uint64[] memory ids, uint256[] memory fees) = _one(0, fee);
        vm.deal(relayer, bond);
        if (over) vm.expectRevert(abi.encodeWithSelector(RelayerRegistry.FeeAboveCap.selector, uint64(0), fee, CAP));
        vm.prank(relayer);
        reg.register{value: bond}(relayer, ONION, ids, fees);
        assertEq(address(reg).balance, over ? 0 : bond);
        assertEq(reg.feeOf(relayer, 0), over ? 0 : fee);
    }

    /// The bond is refused one second before the delay ends and paid at any time after.
    function testFuzz_exitDelay(uint256 wait) public {
        wait = bound(wait, 0, 3650 days);
        _join(relayer, 1);
        uint256 start = block.timestamp;
        _exit(relayer);
        vm.warp(start + wait);
        if (wait < reg.EXIT_DELAY()) {
            vm.expectRevert(
                abi.encodeWithSelector(RelayerRegistry.ExitDelayPending.selector, uint64(start + reg.EXIT_DELAY()))
            );
        }
        vm.prank(relayer);
        reg.withdrawBond();
    }

    /// Pages cover every active relayer once, whatever the page size, after random exits.
    function testFuzz_pagingCoversTheActiveSetOnce(uint8 n, uint256 exits, uint8 pageSize) public {
        n = uint8(bound(n, 0, 40));
        pageSize = uint8(bound(pageSize, 1, 50));
        address[] memory ops = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            ops[i] = address(uint160(0x1000 + i));
            _join(ops[i], 1);
        }
        bool[] memory gone = new bool[](n);
        uint256 live = n;
        for (uint256 i = 0; i < n; ++i) {
            if ((exits >> i) & 1 == 1) {
                _exit(ops[i]);
                gone[i] = true;
                --live;
            }
        }
        assertEq(reg.relayerCount(), live);

        uint256 seen;
        for (uint256 start = 0; start < live; start += pageSize) {
            address[] memory page = reg.relayersPage(start, pageSize);
            assertEq(page.length, live - start < pageSize ? live - start : pageSize);
            for (uint256 j = 0; j < page.length; ++j) {
                uint256 k = uint160(page[j]) - 0x1000;
                assertFalse(gone[k], "a page holds only active relayers");
                gone[k] = true; // marks it seen, so a repeat fails the line above
                ++seen;
            }
        }
        assertEq(seen, live);
        assertEq(reg.relayersPage(live, pageSize).length, 0, "a page past the end is empty");
        assertEq(reg.relayersPage(0, type(uint256).max).length, live, "an oversized count stops at the end");
    }
}
