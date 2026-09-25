// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ShieldFeeRouter} from "../../../../contracts/shield/ShieldFeeRouter.sol";
import {NoxShieldStaking} from "../../../../contracts/shield/NoxShieldStaking.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockDexRouter} from "../../mocks/MockDexRouter.sol";

/// Drives ShieldFeeRouter through random sequences of fee arrivals, buybacks, distributions,
/// configuration attempts by the owner, the keeper and strangers, timelocked changes and time.
/// Every call that should have been refused and was not is counted, and every NOX that enters the
/// router is recorded so conservation can be checked against where it ended up.
contract FeeRouterHandler is Test {
    uint256 constant BPS = 10_000;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    ShieldFeeRouter public router;
    MockERC20 public nox;
    MockERC20 public feeToken;
    MockDexRouter public dexA; // proposed and approved at setup
    MockDexRouter public dexB; // only ever approved through the handler's own timelocked path
    address public owner;
    address public keeper;
    address public stranger = address(0x5712);
    address public wnative = address(0x3E7);

    address[2] public stakings;
    address[2] public treasuries;

    uint256 public noxIn; // every NOX wei that entered the router, by fee or by swap
    uint256 public distributions;

    uint256 public unauthorisedConfig; // a config call by a non-owner that succeeded
    uint256 public unauthorisedConvert; // a buyback by neither keeper nor owner that succeeded
    uint256 public invalidSplitAccepted; // a split off 10,000 or with treasury over 5,000 accepted
    uint256 public badDistribution; // a distribute whose shares differ from the floored bps or lose a wei
    uint256 public maxBurnDust; // the largest burn-over-floor seen, in wei
    uint256 public earlyExecution; // a timelocked change that took effect before its eta
    uint256 public noxLeakOnConvert; // a buyback after which the router held less NOX than before
    uint256 public unapprovedSwap; // a buyback through a router that was not approved at the time

    mapping(bytes32 => uint256) public proposedAt;

    constructor(
        ShieldFeeRouter router_,
        MockERC20 nox_,
        MockERC20 feeToken_,
        MockDexRouter dexA_,
        MockDexRouter dexB_,
        address owner_,
        address keeper_,
        address[2] memory stakings_,
        address[2] memory treasuries_
    ) {
        router = router_;
        nox = nox_;
        feeToken = feeToken_;
        dexA = dexA_;
        dexB = dexB_;
        owner = owner_;
        keeper = keeper_;
        stakings = stakings_;
        treasuries = treasuries_;
    }

    function _who(uint256 seed) internal view returns (address) {
        uint256 k = seed % 3;
        return k == 0 ? owner : (k == 1 ? keeper : stranger);
    }

    function _dex(uint256 seed) internal view returns (address) {
        return seed % 2 == 0 ? address(dexA) : address(dexB);
    }

    // ------------------------------------------------------------------ fee arrivals

    function noxFee(uint256 amount) external {
        amount = amount % 4 == 0 ? bound(amount, 1, 50) : bound(amount, 1, 1e24);
        nox.mint(address(router), amount);
        noxIn += amount;
    }

    function tokenFee(uint256 amount) external {
        feeToken.mint(address(router), bound(amount, 1, 1e24));
    }

    function nativeFee(uint256 amount) external {
        vm.deal(address(router), address(router).balance + bound(amount, 1, 100 ether));
    }

    // ------------------------------------------------------------------ keeper path

    function convertToken(uint256 whoSeed, uint256 dexSeed, uint256 amount, uint256 minOut) external {
        address who = _who(whoSeed);
        address dex = _dex(dexSeed);
        uint256 held = feeToken.balanceOf(address(router));
        if (held == 0) return;
        amount = bound(amount, 1, held);
        minOut = bound(minOut, 1, amount);
        bool approved = router.approvedRouter(dex);
        address[] memory path = new address[](2);
        path[0] = address(feeToken);
        path[1] = address(nox);
        uint256 b0 = nox.balanceOf(address(router));
        vm.prank(who);
        try router.convertToken(dex, amount, minOut, path, block.timestamp) returns (uint256 out) {
            if (who == stranger) unauthorisedConvert++;
            if (!approved) unapprovedSwap++;
            uint256 b1 = nox.balanceOf(address(router));
            if (b1 < b0 || b1 - b0 != out) noxLeakOnConvert++;
            noxIn += out;
        } catch {}
    }

    function convertNative(uint256 whoSeed, uint256 dexSeed, uint256 amount, uint256 minOut) external {
        address who = _who(whoSeed);
        address dex = _dex(dexSeed);
        uint256 held = address(router).balance;
        if (held == 0) return;
        amount = bound(amount, 1, held);
        minOut = bound(minOut, 1, amount);
        bool approved = router.approvedRouter(dex);
        address[] memory path = new address[](2);
        path[0] = wnative;
        path[1] = address(nox);
        uint256 b0 = nox.balanceOf(address(router));
        vm.prank(who);
        try router.convertNative(dex, amount, minOut, path, block.timestamp) returns (uint256 out) {
            if (who == stranger) unauthorisedConvert++;
            if (!approved) unapprovedSwap++;
            uint256 b1 = nox.balanceOf(address(router));
            if (b1 < b0 || b1 - b0 != out) noxLeakOnConvert++;
            noxIn += out;
        } catch {}
    }

    // ------------------------------------------------------------------ distribution

    function distribute(address caller) external {
        uint256 total = nox.balanceOf(address(router));
        address st = router.staking();
        address tr = router.treasury();
        uint256 s0 = nox.balanceOf(st);
        uint256 t0 = nox.balanceOf(tr);
        uint256 d0 = nox.balanceOf(DEAD);
        // with nothing staked, the staking contract burns the staking share it is sent
        uint256 sShare = (total * router.stakingBps()) / BPS;
        bool stakeBurns = NoxShieldStaking(st).totalStaked() == 0;
        uint256 tShare = (total * router.treasuryBps()) / BPS;
        uint256 bFloor = (total * router.burnBps()) / BPS + (stakeBurns ? sShare : 0);
        if (stakeBurns) sShare = 0;
        vm.prank(caller);
        try router.distribute() {
            distributions++;
            uint256 ds = nox.balanceOf(st) - s0;
            uint256 dt = nox.balanceOf(tr) - t0;
            uint256 dd = nox.balanceOf(DEAD) - d0;
            if (ds != sShare || dt != tShare) badDistribution++;
            if (ds + dt + dd != total || nox.balanceOf(address(router)) != 0) badDistribution++;
            if (dd < bFloor || dd - bFloor > 2) badDistribution++;
            else if (dd - bFloor > maxBurnDust) maxBurnDust = dd - bFloor;
        } catch {}
    }

    // ------------------------------------------------------------------ configuration

    function setSplits(uint256 whoSeed, uint16 a, uint16 b) external {
        address who = _who(whoSeed);
        // half the attempts are valid splits, half are arbitrary
        uint16 c;
        if (whoSeed % 2 == 0) {
            a = uint16(bound(a, 0, BPS));
            b = uint16(bound(b, 0, BPS - a));
            c = uint16(BPS - a - b);
        } else {
            c = uint16(uint256(keccak256(abi.encode(a, b))) % (BPS + 1));
        }
        vm.prank(who);
        try router.setSplits(a, b, c) {
            if (who != owner) unauthorisedConfig++;
            if (uint256(a) + b + c != BPS || b > 5000) invalidSplitAccepted++;
        } catch {}
    }

    function setKeeper(uint256 whoSeed) external {
        address who = _who(whoSeed);
        address current = router.keeper();
        vm.prank(who);
        try router.setKeeper(current) {
            if (who != owner) unauthorisedConfig++;
        } catch {}
    }

    function proposeStaking(uint256 whoSeed, uint256 pick) external {
        address who = _who(whoSeed);
        address v = stakings[pick % 2];
        vm.prank(who);
        try router.proposeStaking(v) {
            if (who != owner) unauthorisedConfig++;
            proposedAt["staking"] = block.timestamp;
        } catch {}
    }

    function executeStaking(address caller) external {
        vm.prank(caller);
        try router.executeStaking() {
            if (block.timestamp < proposedAt["staking"] + 2 days) earlyExecution++;
        } catch {}
    }

    function proposeTreasury(uint256 whoSeed, uint256 pick) external {
        address who = _who(whoSeed);
        address v = treasuries[pick % 2];
        vm.prank(who);
        try router.proposeTreasury(v) {
            if (who != owner) unauthorisedConfig++;
            proposedAt["treasury"] = block.timestamp;
        } catch {}
    }

    function executeTreasury(address caller) external {
        vm.prank(caller);
        try router.executeTreasury() {
            if (block.timestamp < proposedAt["treasury"] + 2 days) earlyExecution++;
        } catch {}
    }

    function proposeRouter(uint256 whoSeed, uint256 dexSeed) external {
        address who = _who(whoSeed);
        address dex = _dex(dexSeed);
        vm.prank(who);
        try router.proposeRouter(dex) {
            if (who != owner) unauthorisedConfig++;
            proposedAt[keccak256(abi.encode(dex))] = block.timestamp;
        } catch {}
    }

    function executeRouter(address caller, uint256 dexSeed) external {
        address dex = _dex(dexSeed);
        vm.prank(caller);
        try router.executeRouterApproval(dex) {
            if (block.timestamp < proposedAt[keccak256(abi.encode(dex))] + 2 days) earlyExecution++;
        } catch {}
    }

    function revokeRouter(uint256 whoSeed, uint256 dexSeed) external {
        address who = _who(whoSeed);
        vm.prank(who);
        try router.revokeRouter(_dex(dexSeed)) {
            if (who != owner) unauthorisedConfig++;
        } catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 3 days));
    }
}

/// Invariants of ShieldFeeRouter over random call sequences.
/// Run: forge test --match-contract ShieldFeeRouterInvariants (5,000 runs of depth 200 each).
contract ShieldFeeRouterInvariants is Test {
    address safe = address(0x5AFE);
    address keeper = address(0x6EE9);
    FeeRouterHandler h;
    ShieldFeeRouter router;
    MockERC20 nox;
    address[2] stakings;
    address[2] treasuries = [address(0x7EA1), address(0x7EA2)];

    function setUp() public {
        vm.warp(1_700_000_000);
        nox = new MockERC20("NOX", "NOX");
        MockERC20 feeToken = new MockERC20("USD", "USD");
        NoxShieldStaking sA = new NoxShieldStaking(safe, IERC20(address(nox)), 604_800);
        NoxShieldStaking sB = new NoxShieldStaking(safe, IERC20(address(nox)), 604_800);
        stakings = [address(sA), address(sB)];
        router = new ShieldFeeRouter(safe, IERC20(address(nox)), address(sA), treasuries[0], 4000, 3000, 3000);
        vm.startPrank(safe);
        sA.setRewardNotifier(address(router));
        sB.setRewardNotifier(address(router));
        MockDexRouter dexA = new MockDexRouter();
        MockDexRouter dexB = new MockDexRouter();
        router.proposeRouter(address(dexA));
        router.setKeeper(keeper);
        vm.stopPrank();
        vm.warp(block.timestamp + 2 days);
        router.executeRouterApproval(address(dexA));
        nox.mint(address(dexA), 1e40);
        nox.mint(address(dexB), 1e40);
        dexA.setRate(0.97e18);
        dexB.setRate(1.01e18);
        h = new FeeRouterHandler(router, nox, feeToken, dexA, dexB, safe, keeper, stakings, treasuries);
        targetContract(address(h));
    }

    /// Conservation of NOX: every wei that entered the router, as a direct fee or as the output of
    /// a buyback, is either still in the router or sits with a staking contract, a treasury or the
    /// burn address. Nothing is created and nothing is lost.
    /// forge-config: default.invariant.runs = 5000
    /// forge-config: default.invariant.depth = 200
    function invariant_everyNoxThatEnteredIsAccountedFor() public view {
        uint256 out = nox.balanceOf(stakings[0]) + nox.balanceOf(stakings[1]) + nox.balanceOf(treasuries[0])
            + nox.balanceOf(treasuries[1]) + nox.balanceOf(h.DEAD());
        assertEq(nox.balanceOf(address(router)) + out, h.noxIn());
    }

    /// Every distribution pays staking and treasury their floored bps share, sends the whole remainder
    /// to burn and empties the router. With nothing staked, the staking share is burned too.
    /// forge-config: default.invariant.runs = 5000
    /// forge-config: default.invariant.depth = 200
    function invariant_everyDistributionSplitsExactly() public view {
        assertEq(h.badDistribution(), 0);
        assertLe(h.maxBurnDust(), 2);
    }

    /// The configured split is always valid: it sums to 10,000 and the treasury takes at most half.
    /// No non-owner changed the split, the keeper, a proposal or a revocation, and no invalid split
    /// was ever accepted.
    /// forge-config: default.invariant.runs = 5000
    /// forge-config: default.invariant.depth = 200
    function invariant_configIsOwnerOnlyAndAlwaysValid() public view {
        assertEq(uint256(router.stakingBps()) + router.treasuryBps() + router.burnBps(), 10_000);
        assertLe(router.treasuryBps(), 5000);
        assertEq(h.unauthorisedConfig(), 0);
        assertEq(h.invalidSplitAccepted(), 0);
        assertEq(router.owner(), safe);
    }

    /// The keeper path is confined: no buyback by anyone but the keeper or owner succeeded, no
    /// buyback went through a router that was not approved at the time, no buyback reduced the
    /// router's NOX, and no timelocked change took effect before its two days had run.
    /// forge-config: default.invariant.runs = 5000
    /// forge-config: default.invariant.depth = 200
    function invariant_keeperPathAndTimelockHold() public view {
        assertEq(h.unauthorisedConvert(), 0);
        assertEq(h.unapprovedSwap(), 0);
        assertEq(h.noxLeakOnConvert(), 0);
        assertEq(h.earlyExecution(), 0);
    }
}
