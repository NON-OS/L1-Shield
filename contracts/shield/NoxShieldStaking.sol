// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {INoxShieldStaking} from "./interfaces/INoxShieldStaking.sol";

/// @title NoxShieldStaking
/// @notice Stake NOX and earn a pro-rata share of the shield fee router's staking allocation.
/// @dev The owner can only set the reward notifier. It cannot move stakes or rewards.
///      See docs/10-fees-liveness-governance.md.
contract NoxShieldStaking is INoxShieldStaking, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Unstake {
        uint256 amount;
        uint64 releaseAt; // unix seconds
    }

    uint256 public constant PRECISION = 1e27; // accumulator scale
    uint256 public constant MAX_COOLDOWN = 30 days;

    IERC20 public immutable nox;
    uint256 public immutable cooldown; // seconds

    address public rewardNotifier;
    uint256 public totalStaked; // excludes balances in cooldown
    uint256 public rewardPerTokenStored;
    uint256 public carriedRewards; // undistributed remainder and rewards sent while nothing was staked

    mapping(address account => uint256 amount) public stakedOf;
    mapping(address account => uint256 value) public userRewardPerTokenPaid;
    mapping(address account => uint256 amount) public rewardsOf;
    mapping(address account => Unstake pending) public unstakeOf;

    event Staked(address indexed account, uint256 amount, uint256 totalStaked);
    event UnstakeInitiated(address indexed account, uint256 amount, uint64 releaseAt); // new pending total
    event Unstaked(address indexed account, uint256 amount);
    event UnstakeCancelled(address indexed account, uint256 amount);
    event RewardPaid(address indexed account, uint256 amount);
    event RewardNotified(uint256 amount, uint256 distributed, uint256 carried);
    event RewardNotifierSet(address indexed notifier);

    error ZeroAddress();
    error ZeroAmount();
    error CooldownTooLong();
    error NotNotifier();
    error InsufficientStake();
    error NothingPending();
    error CooldownNotElapsed();

    constructor(address safe_, IERC20 nox_, uint256 cooldown_) Ownable(safe_) {
        if (address(nox_) == address(0)) revert ZeroAddress();
        if (cooldown_ > MAX_COOLDOWN) revert CooldownTooLong();
        nox = nox_;
        cooldown = cooldown_;
    }

    /// @notice Claimable rewards for `account`, in NOX wei.
    function earned(address account) public view returns (uint256) {
        return
            rewardsOf[account] + (stakedOf[account] * (rewardPerTokenStored - userRewardPerTokenPaid[account]))
                / PRECISION;
    }

    /// @notice Stakes `amount` NOX wei. Credits the balance change, so fee-on-transfer is safe.
    // slither-disable-next-line reentrancy-balance
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _updateReward(msg.sender);

        uint256 before = nox.balanceOf(address(this));
        nox.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = nox.balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();

        stakedOf[msg.sender] += received;
        totalStaked += received;
        emit Staked(msg.sender, received, totalStaked);
    }

    /// @notice Moves `amount` into cooldown and restarts the timer for the whole pending amount.
    function initiateUnstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (stakedOf[msg.sender] < amount) revert InsufficientStake();
        _updateReward(msg.sender);

        // Cannot underflow: amount <= stakedOf[msg.sender] <= totalStaked.
        unchecked {
            stakedOf[msg.sender] -= amount;
            totalStaked -= amount;
        }
        Unstake storage pending = unstakeOf[msg.sender];
        pending.amount += amount;
        pending.releaseAt = uint64(block.timestamp + cooldown);
        emit UnstakeInitiated(msg.sender, pending.amount, pending.releaseAt);
    }

    /// @notice Withdraws the caller's whole pending amount once its cooldown has elapsed.
    function withdrawUnstaked() external nonReentrant {
        Unstake memory pending = unstakeOf[msg.sender];
        if (pending.amount == 0) revert NothingPending();
        if (block.timestamp < pending.releaseAt) revert CooldownNotElapsed();

        delete unstakeOf[msg.sender];
        nox.safeTransfer(msg.sender, pending.amount);
        emit Unstaked(msg.sender, pending.amount);
    }

    /// @notice Re-stakes a pending cooldown without waiting for release.
    function cancelUnstake() external nonReentrant {
        Unstake memory pending = unstakeOf[msg.sender];
        if (pending.amount == 0) revert NothingPending();
        _updateReward(msg.sender);

        delete unstakeOf[msg.sender];
        stakedOf[msg.sender] += pending.amount;
        totalStaked += pending.amount;
        emit UnstakeCancelled(msg.sender, pending.amount);
        emit Staked(msg.sender, pending.amount, totalStaked);
    }

    /// @notice Claims the caller's accrued rewards. A no-op when there are none.
    function claimRewards() external nonReentrant {
        _updateReward(msg.sender);
        uint256 amount = rewardsOf[msg.sender];
        if (amount == 0) return;
        rewardsOf[msg.sender] = 0;
        nox.safeTransfer(msg.sender, amount);
        emit RewardPaid(msg.sender, amount);
    }

    /// @inheritdoc INoxShieldStaking
    /// @dev The floor-division remainder carries forward, and so does everything while nothing is staked.
    function notifyRewardAmount(uint256 amount) external nonReentrant {
        if (msg.sender != rewardNotifier) revert NotNotifier();
        if (amount == 0) revert ZeroAmount();

        uint256 before = nox.balanceOf(address(this));
        nox.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = nox.balanceOf(address(this)) - before;

        uint256 total = received + carriedRewards;
        uint256 distributed;
        if (totalStaked == 0) {
            carriedRewards = total;
        } else {
            uint256 increment = (total * PRECISION) / totalStaked;
            rewardPerTokenStored += increment;
            distributed = (increment * totalStaked) / PRECISION;
            // Cannot underflow: both divisions round down, so distributed <= total.
            unchecked {
                carriedRewards = total - distributed;
            }
        }
        emit RewardNotified(received, distributed, carriedRewards);
    }

    /// @notice Sets the reward notifier, normally the ShieldFeeRouter.
    function setRewardNotifier(address notifier) external onlyOwner {
        if (notifier == address(0)) revert ZeroAddress();
        rewardNotifier = notifier;
        emit RewardNotifierSet(notifier);
    }

    // Must run before any change to the account's stake.
    function _updateReward(address account) private {
        rewardsOf[account] = earned(account);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
    }
}
