// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RelayerRegistry, IRelayFeeCap} from "../../../../contracts/shield/RelayerRegistry.sol";

/// A fixed relay fee cap of 1000 units on every asset.
contract FixedCap is IRelayFeeCap {
    function relayFee(uint64) external pure returns (bool, uint256) {
        return (false, 1000);
    }
}

/// Five operators register, reprice, deregister and withdraw in random order with random bonds,
/// fees and waits. The handler counts what went in and what came out.
contract RelayerHandler is Test {
    RelayerRegistry public reg;
    address[5] public ops;
    uint256 public paidIn;
    uint256 public paidOut;

    constructor(RelayerRegistry reg_) {
        reg = reg_;
        for (uint256 i = 0; i < 5; ++i) {
            ops[i] = address(uint160(0xA000 + i));
        }
    }

    function register(uint256 who, uint256 bond, uint256 fee) external {
        address op = ops[who % 5];
        bond = bound(bond, 0, 2 ether);
        vm.deal(op, bond);
        uint64[] memory ids = new uint64[](1);
        uint256[] memory fees = new uint256[](1);
        fees[0] = bound(fee, 0, 1500);
        vm.prank(op);
        try reg.register{value: bond}(op, "relay.onion", ids, fees) {
            paidIn += bond;
        } catch {}
    }

    function setFee(uint256 who, uint64 asset, uint256 fee) external {
        uint64[] memory ids = new uint64[](1);
        uint256[] memory fees = new uint256[](1);
        ids[0] = asset % 3;
        fees[0] = bound(fee, 0, 1500);
        vm.prank(ops[who % 5]);
        try reg.setFees(ids, fees) {} catch {}
    }

    function deregister(uint256 who) external {
        vm.prank(ops[who % 5]);
        try reg.deregister() {} catch {}
    }

    function wait(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 10 days));
    }

    function withdraw(uint256 who) external {
        address op = ops[who % 5];
        uint256 before = op.balance;
        vm.prank(op);
        try reg.withdrawBond() {
            paidOut += op.balance - before;
        } catch {}
    }
}

/// Invariants of RelayerRegistry over random sequences of every entry point.
contract RelayerRegistryInvariants is Test {
    RelayerRegistry reg;
    RelayerHandler h;

    function setUp() public {
        reg = new RelayerRegistry(new FixedCap());
        h = new RelayerHandler(reg);
        targetContract(address(h));
    }

    /// The registry's balance equals the sum of bonds not yet withdrawn, and equals what came in less what went out.
    function invariant_balanceIsTheSumOfLiveBonds() public view {
        uint256 sum;
        for (uint256 i = 0; i < 5; ++i) {
            sum += reg.relayerOf(h.ops(i)).bond;
        }
        assertEq(address(reg).balance, sum);
        assertEq(address(reg).balance, h.paidIn() - h.paidOut());
    }

    /// The list holds every active operator once and nothing else, and no active fee is over the cap.
    function invariant_listIsTheActiveSet() public view {
        address[] memory page = reg.relayersPage(0, 10);
        uint256 active;
        for (uint256 i = 0; i < 5; ++i) {
            address op = h.ops(i);
            RelayerRegistry.Relayer memory r = reg.relayerOf(op);
            uint256 hits;
            for (uint256 j = 0; j < page.length; ++j) {
                if (page[j] == op) ++hits;
            }
            assertEq(hits, r.active ? 1 : 0);
            if (r.active) {
                ++active;
                assertGe(r.bond, reg.MIN_BOND());
                assertEq(r.exitAt, 0);
            }
            assertLe(reg.feeOf(op, 0), 1000);
        }
        assertEq(reg.relayerCount(), active);
        assertEq(page.length, active);
    }
}
