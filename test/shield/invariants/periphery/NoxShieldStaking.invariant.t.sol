// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NoxShieldStaking} from "../../../../contracts/shield/NoxShieldStaking.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {ShieldFeeRouter} from "../../../../contracts/shield/ShieldFeeRouter.sol";

/// Drives NoxShieldStaking through random stake, unstake, cancel, withdraw, claim, notify and warp
/// calls, records what each account put in and took out, and counts calls that should have failed.
contract StakingHandler is Test {
    uint256 public constant COOLDOWN = 604_800;

    NoxShieldStaking public st;
    MockERC20 public nox;
    address public notifier;
    address[] public actors;

    mapping(address => uint256) public deposited;
    mapping(address => uint256) public withdrawn;
    mapping(address => uint256) public claimed;
    mapping(address => uint256) public lastInitiateAt;
    uint256 public totalNotified;
    uint256 public totalClaimed;
    uint256 public notifications;

    uint256 public earlyWithdrawals; // withdrawals that succeeded inside the cooldown
    uint256 public overWithdrawals; // withdrawals that paid a different amount from the pending one
    uint256 public overUnstakes; // initiateUnstake calls that succeeded beyond the stake

    constructor(NoxShieldStaking st_, MockERC20 nox_, address notifier_) {
        st = st_;
        nox = nox_;
        notifier = notifier_;
        for (uint256 i = 0; i < 4; i++) {
            actors.push(address(uint160(0xA000 + i)));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function stake(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        // small amounts, since rounding in the accumulator only shows at small totals
        amount = seed % 3 == 0 ? bound(amount, 1, 1000) : bound(amount, 1, 1e24);
        nox.mint(a, amount);
        vm.startPrank(a);
        nox.approve(address(st), amount);
        st.stake(amount);
        vm.stopPrank();
        deposited[a] += amount;
    }

    function initiateUnstake(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        uint256 s = st.stakedOf(a);
        bool over = seed % 7 == 0;
        amount = over ? s + bound(amount, 1, 1e18) : (s == 0 ? 0 : bound(amount, 1, s));
        vm.prank(a);
        try st.initiateUnstake(amount) {
            if (over) overUnstakes++;
            lastInitiateAt[a] = block.timestamp;
        } catch {}
    }

    function cancelUnstake(uint256 seed) external {
        address a = _actor(seed);
        vm.prank(a);
        try st.cancelUnstake() {} catch {}
    }

    function withdrawUnstaked(uint256 seed) external {
        address a = _actor(seed);
        (uint256 pending,) = st.unstakeOf(a);
        uint256 b0 = nox.balanceOf(a);
        vm.prank(a);
        try st.withdrawUnstaked() {
            uint256 got = nox.balanceOf(a) - b0;
            if (block.timestamp < lastInitiateAt[a] + COOLDOWN) earlyWithdrawals++;
            if (got != pending) overWithdrawals++;
            withdrawn[a] += got;
        } catch {}
    }

    function claimRewards(uint256 seed) external {
        address a = _actor(seed);
        uint256 b0 = nox.balanceOf(a);
        vm.prank(a);
        try st.claimRewards() {
            uint256 got = nox.balanceOf(a) - b0;
            claimed[a] += got;
            totalClaimed += got;
        } catch {}
    }

    function notify(uint256 amount) external {
        amount = amount % 2 == 0 ? bound(amount, 1, 10) : bound(amount, 1, 1e22);
        nox.mint(notifier, amount);
        vm.startPrank(notifier);
        nox.approve(address(st), amount);
        st.notifyRewardAmount(amount);
        vm.stopPrank();
        totalNotified += amount;
        notifications++;
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 3 * COOLDOWN));
    }
}

/// Invariants of NoxShieldStaking over random call sequences.
/// Run: forge test --match-contract NoxShieldStakingInvariants (5,000 runs of depth 200 each).
contract NoxShieldStakingInvariants is Test {
    NoxShieldStaking st;
    MockERC20 nox;
    StakingHandler h;
    address safe = address(0x5AFE);
    address notifier = address(0xFEE);

    function setUp() public {
        nox = new MockERC20("NOX", "NOX");
        st = new NoxShieldStaking(safe, IERC20(address(nox)), 604_800);
        vm.prank(safe);
        st.setRewardNotifier(notifier);
        h = new StakingHandler(st, nox, notifier);
        targetContract(address(h));
    }

    function _sums() internal view returns (uint256 staked, uint256 pending, uint256 owed) {
        for (uint256 i = 0; i < h.actorCount(); i++) {
            address a = h.actors(i);
            staked += st.stakedOf(a);
            (uint256 p,) = st.unstakeOf(a);
            pending += p;
            owed += st.earned(a);
        }
    }

    /// totalStaked equals the sum of every account's active stake. Rewards are divided by
    /// totalStaked, so any drift here mis-prices every reward that follows.
    /// forge-config: default.invariant.runs = 5000
    /// forge-config: default.invariant.depth = 200
    function invariant_totalStakedIsTheSumOfStakes() public view {
        (uint256 staked,,) = _sums();
        assert(st.totalStaked() == staked);
    }

    /// Principal is conserved: what every account has taken back through withdrawals, plus what is
    /// still staked or in cooldown, equals what it deposited. No account ever withdraws more principal
    /// than it put in.
    /// forge-config: default.invariant.runs = 5000
    /// forge-config: default.invariant.depth = 200
    function invariant_principalIsConservedPerAccount() public view {
        for (uint256 i = 0; i < h.actorCount(); i++) {
            address a = h.actors(i);
            (uint256 p,) = st.unstakeOf(a);
            assert(h.withdrawn(a) + st.stakedOf(a) + p == h.deposited(a));
            assert(h.withdrawn(a) <= h.deposited(a));
        }
    }

    /// The cooldown holds and no withdrawal exceeds the stake: no withdrawal ever succeeded less than
    /// 604,800 seconds after the account's last initiateUnstake, no withdrawal paid anything but the
    /// pending amount, and no initiateUnstake beyond the active stake ever succeeded.
    /// forge-config: default.invariant.runs = 5000
    /// forge-config: default.invariant.depth = 200
    function invariant_cooldownAndStakeBoundsHold() public view {
        assert(h.earlyWithdrawals() == 0);
        assert(h.overWithdrawals() == 0);
        assert(h.overUnstakes() == 0);
    }

    /// No reward from nothing: what has been claimed, plus what is still owed, plus what is carried,
    /// never exceeds what the notifier paid in.
    /// forge-config: default.invariant.runs = 5000
    /// forge-config: default.invariant.depth = 200
    function invariant_rewardsNeverExceedWhatWasNotified() public view {
        (,, uint256 owed) = _sums();
        assert(h.totalClaimed() + owed + st.carriedRewards() <= h.totalNotified());
    }

    /// Solvency: the contract holds every stake, every pending unstake, every owed reward and the
    /// carried remainder.
    /// forge-config: default.invariant.runs = 5000
    /// forge-config: default.invariant.depth = 200
    function invariant_solvent() public view {
        (uint256 staked, uint256 pending, uint256 owed) = _sums();
        assert(nox.balanceOf(address(st)) >= staked + pending + owed + st.carriedRewards());
    }
}

/// Two reward properties as concrete traces: rounding never books a wei as both carried and owed,
/// and a reward that arrives while nothing is staked goes to no one.
contract NoxShieldStakingRewardTraces is Test {
    NoxShieldStaking st;
    MockERC20 nox;
    address safe = address(0x5AFE);
    address notifier = address(0xFEE);
    address alice = address(0xA11CE);

    function setUp() public {
        nox = new MockERC20("NOX", "NOX");
        st = new NoxShieldStaking(safe, IERC20(address(nox)), 604_800);
        vm.prank(safe);
        st.setRewardNotifier(notifier);
        nox.mint(notifier, 1000);
        vm.prank(notifier);
        nox.approve(address(st), type(uint256).max);
    }

    function _stake(address a, uint256 amt) internal {
        nox.mint(a, amt);
        vm.startPrank(a);
        nox.approve(address(st), amt);
        st.stake(amt);
        vm.stopPrank();
    }

    /// Three wei notified across a stake change pay alice at most three, and her principal comes back.
    /// The booked share rounds up, so the wei a floor leaves over is carried and never also owed.
    function test_roundingNeverOverCommitsAcrossNotifications() public {
        _stake(alice, 3);
        vm.startPrank(notifier);
        st.notifyRewardAmount(1);
        st.notifyRewardAmount(1);
        vm.stopPrank();
        _stake(alice, 1);
        vm.prank(notifier);
        st.notifyRewardAmount(1);

        vm.startPrank(alice);
        st.claimRewards();
        assertLe(nox.balanceOf(alice), 3, "alice is paid at most the three wei notified");
        st.initiateUnstake(4);
        vm.warp(block.timestamp + 604_800);
        // an account can always withdraw the principal it staked
        st.withdrawUnstaked();
        vm.stopPrank();
        assertLe(nox.balanceOf(alice), 7, "principal returned in full, reward at most three");
        assertGe(nox.balanceOf(alice), 4, "principal returned in full");
    }

    /// A staking share that arrives while nothing is staked is burned, so a one-wei stake made after
    /// it earns only its share of what arrives next.
    function test_aRewardWithNoStakerIsBurned() public {
        address treasury = address(0x7EA5);
        ShieldFeeRouter router = new ShieldFeeRouter(safe, IERC20(address(nox)), address(st), treasury, 4000, 3000, 3000);
        vm.prank(safe);
        st.setRewardNotifier(address(router));

        nox.mint(address(router), 1000e18);
        router.distribute();
        assertEq(st.carriedRewards(), 0, "nothing is carried for a later staker");
        assertEq(nox.balanceOf(st.BURN_ADDRESS()), 400e18 + 300e18, "the staking share and the burn share are burned");

        address attacker = address(0xBAD);
        _stake(attacker, 1);
        nox.mint(attacker, 3);
        vm.startPrank(attacker);
        nox.transfer(address(router), 3);
        router.distribute();
        st.claimRewards();
        vm.stopPrank();

        // one wei staked for no time earns at most its share of the next notification
        assertLe(nox.balanceOf(attacker), 1, "attacker took the carried staking share");
    }
}
