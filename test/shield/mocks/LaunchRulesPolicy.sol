// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AmountPolicy} from "../../../contracts/shield/AmountPolicy.sol";

/// The launch pool's amount rules on the AmountPolicy storage layout: any amount, a relay fee cap per
/// asset on transfers, and the launch cap of 0.5% on a withdrawal's fee. A fee to a named recipient goes
/// to it whole, and a fee with no recipient to the router whole, as at launch: the protocol part is the
/// whole fee when not relayed and zero when relayed. The deposit fee is the deposit percentage the pool
/// was built with. The suites that test the pool's own logic run on it, etched over the pool's policy;
/// AmountPolicy.t.sol and AmountPolicySchedule.t.sol run on the real policy, which fails closed.
contract LaunchRulesPolicy is AmountPolicy {
    mapping(uint64 assetId => uint256 units) internal _cap;

    event MaxRelayFeeSet(uint64 indexed assetId, uint256 units);

    error FeeExceedsCap();

    constructor(address owner_) AmountPolicy(owner_, 0, 0) {}

    /// The deposit and withdrawal percentages at once, for tests only: the real policy queues them.
    function setBpsNow(uint16 depositBps_, uint16 withdrawBps_) external onlyOwner {
        if (depositBps_ > MAX_BPS || withdrawBps_ > MAX_BPS) revert BpsTooHigh();
        bps = Bps(depositBps_, withdrawBps_);
    }

    function setMaxRelayFee(uint64 assetId, uint256 units) external onlyOwner {
        _cap[assetId] = units;
        emit MaxRelayFeeSet(assetId, units);
    }

    function maxRelayFee(uint64 assetId) external view override returns (uint256) {
        return _cap[assetId];
    }

    function relayFee(uint64 assetId) external view override returns (bool, uint256) {
        return (false, _cap[assetId]);
    }

    function check(uint64 assetId, uint256 publicAmount, uint256 fee) external view override {
        if (publicAmount == 0 && fee > _cap[assetId]) revert FeeExceedsCap();
    }

    function settlementFee(uint64 assetId, uint256 publicAmount, uint256 fee, bool relayed)
        external
        view
        override
        returns (uint256 protocolPart, uint256 gasPart)
    {
        if (publicAmount == 0 && fee > _cap[assetId]) revert FeeExceedsCap();
        if (publicAmount != 0 && fee * 10_000 > publicAmount * 50) revert FeeExceedsCap();
        if (relayed) return (0, fee);
        return (fee, 0);
    }

    function depositFee(uint64, uint256 amount) external view override returns (uint256) {
        return (amount * bps.deposit) / 10_000;
    }
}

import {Vm} from "forge-std/Vm.sol";
import {ShieldedPool} from "../../../contracts/shield/ShieldedPool.sol";

/// Puts LaunchRulesPolicy's code at a pool's policy address, keeping its storage and owner. A pool
/// whose construction reverted under expectRevert has no code and is left alone.
function etchLaunchRules(Vm vm, ShieldedPool p, address owner) {
    if (address(p).code.length == 0) return;
    vm.prank(address(p));
    LaunchRulesPolicy rules = new LaunchRulesPolicy(owner);
    vm.etch(address(p.amountPolicy()), address(rules).code);
}
