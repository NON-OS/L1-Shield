// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ShieldFeeRouter} from "../../../../contracts/shield/ShieldFeeRouter.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/// Stands in for the staking contract: it pulls what it is notified of, as the real one does.
contract PullingStaking {
    IERC20 immutable nox;

    constructor(IERC20 nox_) {
        nox = nox_;
    }

    function notifyRewardAmount(uint256 amount) external {
        nox.transferFrom(msg.sender, address(this), amount);
    }
}

/// Symbolic proofs for the fee router's split and its access control.
/// Run: FOUNDRY_PROFILE=halmos halmos --match-contract ShieldFeeRouterHalmos
/// The router has no sweep, so a lost wei stays stranded. Staking and treasury are floored and burn
/// takes the remainder, 0 to 2 wei above its floored share, so the shares sum to the balance.
contract ShieldFeeRouterHalmos is SymTest, Test {
    uint256 constant BPS = 10_000;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address safe = address(0x5AFE);
    address treasury = address(0x7EA5);
    MockERC20 nox;
    PullingStaking staking;
    ShieldFeeRouter router;

    function setUp() public {
        nox = new MockERC20("NOX", "NOX");
        staking = new PullingStaking(IERC20(address(nox)));
        router = new ShieldFeeRouter(safe, IERC20(address(nox)), address(staking), treasury, 4000, 3000, 3000);
    }

    /// At 4000/3000/3000 the shares sum to the input, and only burn differs from its floored share,
    /// by 0 to 2 wei. Floor division is stated as q * BPS <= x < q * BPS + BPS, since the division
    /// operator times out the solver. check_distributeMovesTheWholeBalanceExactly runs the real divisions.
    function check_theDeployedSplitSumsExactlyAndDustGoesToBurn(uint256 total, uint256 s, uint256 t, uint256 bFloor)
        public
        pure
    {
        vm.assume(total < 2 ** 128);
        vm.assume(s < 2 ** 128 && t < 2 ** 128 && bFloor < 2 ** 128); // no wrap in q * BPS
        vm.assume(s * BPS <= total * 4000 && total * 4000 < s * BPS + BPS);
        vm.assume(t * BPS <= total * 3000 && total * 3000 < t * BPS + BPS);
        vm.assume(bFloor * BPS <= total * 3000 && total * 3000 < bFloor * BPS + BPS);
        assert(s + t <= total);
        uint256 b = total - s - t;
        assert(s + t + b == total);
        assert(b >= bFloor);
        assert(b - bFloor <= 2);
    }

    /// For every allowed split the two floored shares never exceed the total, so the unchecked
    /// subtraction in distribute cannot wrap, and burn's dust is at most two wei.
    function check_everyAllowedSplitSumsExactly(
        uint256 total,
        uint16 sBps,
        uint16 tBps,
        uint256 s,
        uint256 t,
        uint256 bFloor
    ) public pure {
        vm.assume(total < 2 ** 128);
        vm.assume(uint256(sBps) + tBps <= BPS);
        uint256 bBps = BPS - sBps - tBps;
        vm.assume(s < 2 ** 128 && t < 2 ** 128 && bFloor < 2 ** 128); // no wrap in q * BPS
        vm.assume(s * BPS <= total * sBps && total * sBps < s * BPS + BPS);
        vm.assume(t * BPS <= total * tBps && total * tBps < t * BPS + BPS);
        vm.assume(bFloor * BPS <= total * bBps && total * bBps < bFloor * BPS + BPS);
        assert(s + t <= total);
        uint256 b = total - s - t;
        assert(b >= bFloor && b - bFloor <= 2);
    }

    /// distribute on the real contract pays the floored shares and the remainder, empties the router,
    /// and mints or loses no NOX.
    function check_distributeMovesTheWholeBalanceExactly(uint256 total, address caller) public {
        vm.assume(total > 0 && total < 2 ** 128);
        nox.mint(address(router), total);
        vm.prank(caller);
        router.distribute();
        uint256 s = nox.balanceOf(address(staking));
        uint256 t = nox.balanceOf(treasury);
        uint256 b = nox.balanceOf(DEAD);
        assert(s == (total * 4000) / BPS);
        assert(t == (total * 3000) / BPS);
        assert(s + t + b == total);
        assert(nox.balanceOf(address(router)) == 0);
        assert(nox.totalSupply() == total);
        uint256 bFloor = (total * 3000) / BPS;
        assert(b >= bFloor && b - bFloor <= 2);
    }

    function _call(address caller, bytes memory data) internal returns (bool ok) {
        vm.prank(caller);
        (ok,) = address(router).call(data);
    }

    /// Only the owner can change the split. A stranger who could would route the staking share to
    /// treasury, or set it to zero.
    function check_onlyTheOwnerSetsTheSplit(address caller, uint16 a, uint16 b, uint16 c) public {
        vm.assume(caller != safe);
        assert(!_call(caller, abi.encodeCall(router.setSplits, (a, b, c))));
    }

    /// An owner-set split is always a valid one: it sums to 10,000 and the treasury share is capped
    /// at 5,000 bps.
    function check_anAcceptedSplitIsValid(uint16 a, uint16 b, uint16 c) public {
        bool ok = _call(safe, abi.encodeCall(router.setSplits, (a, b, c)));
        assert(ok == (uint256(a) + b + c == BPS && b <= 5000));
        uint256 sum = uint256(router.stakingBps()) + router.treasuryBps() + router.burnBps();
        assert(sum == BPS);
        assert(router.treasuryBps() <= 5000);
    }

    /// Only the owner can name the keeper, propose a staking contract, a treasury or a DEX router, or
    /// revoke a router.
    function check_onlyTheOwnerConfigures(address caller, address v) public {
        vm.assume(caller != safe);
        assert(!_call(caller, abi.encodeCall(router.setKeeper, (v))));
        assert(!_call(caller, abi.encodeCall(router.proposeStaking, (v))));
        assert(!_call(caller, abi.encodeCall(router.proposeTreasury, (v))));
        assert(!_call(caller, abi.encodeCall(router.proposeRouter, (v))));
        assert(!_call(caller, abi.encodeCall(router.revokeRouter, (v))));
    }

    /// A proposed staking contract, treasury or DEX router cannot take effect before the two-day
    /// timelock has run, whoever calls execute.
    function check_noChangeTakesEffectInsideTheTimelock(address v, address caller, uint256 dt) public {
        vm.assume(v != address(0));
        vm.assume(dt < 2 days);
        vm.startPrank(safe);
        router.proposeStaking(v);
        router.proposeTreasury(v);
        router.proposeRouter(v);
        vm.stopPrank();
        vm.warp(block.timestamp + dt);
        assert(!_call(caller, abi.encodeCall(router.executeStaking, ())));
        assert(!_call(caller, abi.encodeCall(router.executeTreasury, ())));
        assert(!_call(caller, abi.encodeCall(router.executeRouterApproval, (v))));
        assert(router.staking() == address(staking));
        assert(router.treasury() == treasury);
        assert(!router.approvedRouter(v));
    }

    /// Once the timelock has run, anyone may execute, and the proposed value lands.
    function check_aMaturedChangeLandsTheProposedValue(address v, address caller, uint256 dt) public {
        vm.assume(v != address(0));
        vm.assume(dt >= 2 days && dt < 2 ** 64);
        vm.startPrank(safe);
        router.proposeStaking(v);
        router.proposeTreasury(v);
        router.proposeRouter(v);
        vm.stopPrank();
        vm.warp(block.timestamp + dt);
        assert(_call(caller, abi.encodeCall(router.executeStaking, ())));
        assert(_call(caller, abi.encodeCall(router.executeTreasury, ())));
        assert(_call(caller, abi.encodeCall(router.executeRouterApproval, (v))));
        assert(router.staking() == v);
        assert(router.treasury() == v);
        assert(router.approvedRouter(v));
    }

    /// Only the keeper or the owner can start a buyback, and even they only through an approved
    /// router: every other caller is refused before any token moves.
    function check_onlyKeeperOrOwnerConverts(address caller, address keeper, address dex, uint256 amt) public {
        vm.prank(safe);
        router.setKeeper(keeper);
        vm.assume(caller != safe && caller != keeper);
        address[] memory path = new address[](2);
        path[0] = address(0xBEEF);
        path[1] = address(nox);
        assert(!_call(caller, abi.encodeCall(router.convertToken, (dex, amt, 1, path, type(uint256).max))));
        assert(!_call(caller, abi.encodeCall(router.convertNative, (dex, amt, 1, path, type(uint256).max))));
    }

    /// The keeper cannot swap through a router the owner has not approved behind the timelock.
    function check_theKeeperNeedsAnApprovedRouter(address keeper, address dex, uint256 amt, uint256 minOut) public {
        vm.prank(safe);
        router.setKeeper(keeper);
        vm.assume(!router.approvedRouter(dex));
        address[] memory path = new address[](2);
        path[0] = address(0xBEEF);
        path[1] = address(nox);
        assert(!_call(keeper, abi.encodeCall(router.convertToken, (dex, amt, minOut, path, type(uint256).max))));
        assert(!_call(keeper, abi.encodeCall(router.convertNative, (dex, amt, minOut, path, type(uint256).max))));
    }
}
