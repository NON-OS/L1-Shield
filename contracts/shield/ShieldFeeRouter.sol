// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDexRouterV2} from "./interfaces/IDexRouterV2.sol";
import {INoxShieldStaking} from "./interfaces/INoxShieldStaking.sol";

/// @title ShieldFeeRouter
/// @notice Swaps Shield fees into NOX and splits them between staking, treasury and burn.
/// @dev Treasury share is capped at 50%. Address changes and router approvals are timelocked.
///      See docs/10-fees-liveness-governance.md.
contract ShieldFeeRouter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct PendingAddress {
        address value;
        uint64 eta; // unix seconds
    }

    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_TREASURY_BPS = 5_000;
    uint256 public constant TIMELOCK_DELAY = 2 days;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD; // the burn share is sent here, beyond any key

    IERC20 public immutable nox;

    uint16 public stakingBps;
    uint16 public treasuryBps;
    uint16 public burnBps; // also takes the rounding remainder

    address public staking;
    address public treasury;
    address public keeper;

    mapping(address router => bool approved) public approvedRouter;

    PendingAddress public pendingStaking;
    PendingAddress public pendingTreasury;
    mapping(address router => uint64 eta) public pendingRouterEta; // 0 = none pending

    event FeeSplit(uint256 total, uint256 toStaking, uint256 toTreasury, uint256 burned);
    event Buyback(address indexed tokenIn, uint256 amountIn, uint256 noxOut); // tokenIn 0 = native
    event SplitsUpdated(uint16 stakingBps, uint16 treasuryBps, uint16 burnBps);
    event ChangeProposed(bytes32 indexed kind, address indexed value, uint64 eta);
    event ChangeExecuted(bytes32 indexed kind, address indexed value);
    event RouterRevoked(address indexed router);
    event KeeperSet(address indexed keeper);

    error ZeroAddress();
    error BadSplit();
    error TreasuryShareTooHigh();
    error NotKeeperOrOwner();
    error RouterNotApproved();
    error BadSwapPath();
    error NothingToDistribute();
    error TimelockNotReady();
    error NoPendingChange();
    error ZeroAmount();

    /// @param safe_ The NOX Safe, set as owner.
    constructor(
        address safe_,
        IERC20 nox_,
        address staking_,
        address treasury_,
        uint16 stakingBps_,
        uint16 treasuryBps_,
        uint16 burnBps_
    ) Ownable(safe_) {
        if (address(nox_) == address(0) || staking_ == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        _checkSplit(stakingBps_, treasuryBps_, burnBps_);
        nox = nox_;
        staking = staking_;
        treasury = treasury_;
        stakingBps = stakingBps_;
        treasuryBps = treasuryBps_;
        burnBps = burnBps_;
        emit SplitsUpdated(stakingBps_, treasuryBps_, burnBps_);
    }

    receive() external payable {}

    /// @notice Swaps a held ERC-20 fee asset into NOX through an approved router.
    /// @param minNoxOut Nonzero floor from an off-chain quote, bounds sandwich loss.
    /// @param path Starts at the fee asset, ends at NOX.
    function convertToken(
        address router,
        uint256 amountIn,
        uint256 minNoxOut,
        address[] calldata path,
        uint256 deadline
    ) external nonReentrant returns (uint256 noxOut) {
        _checkKeeper();
        _checkSwap(router, amountIn, minNoxOut, path);
        if (path[0] == address(nox)) revert BadSwapPath();

        IERC20 tokenIn = IERC20(path[0]);
        tokenIn.forceApprove(router, amountIn);
        uint256 before = nox.balanceOf(address(this));
        IDexRouterV2(router).swapExactTokensForTokens(amountIn, minNoxOut, path, address(this), deadline);
        tokenIn.forceApprove(router, 0);
        noxOut = nox.balanceOf(address(this)) - before;
        emit Buyback(path[0], amountIn, noxOut);
    }

    /// @notice Swaps held native fees into NOX through an approved router.
    /// @param path Starts at wrapped native, ends at NOX.
    function convertNative(
        address router,
        uint256 amountIn,
        uint256 minNoxOut,
        address[] calldata path,
        uint256 deadline
    ) external nonReentrant returns (uint256 noxOut) {
        _checkKeeper();
        _checkSwap(router, amountIn, minNoxOut, path);

        uint256 before = nox.balanceOf(address(this));
        IDexRouterV2(router).swapExactETHForTokens{value: amountIn}(minNoxOut, path, address(this), deadline);
        noxOut = nox.balanceOf(address(this)) - before;
        emit Buyback(address(0), amountIn, noxOut);
    }

    /// @notice Splits the whole NOX balance by the configured bps. Permissionless.
    function distribute() external nonReentrant {
        uint256 total = nox.balanceOf(address(this));
        if (total == 0) revert NothingToDistribute();

        uint256 toStaking = (total * stakingBps) / BPS;
        uint256 toTreasury = (total * treasuryBps) / BPS;
        // stakingBps + treasuryBps <= BPS and both round down, so no underflow
        uint256 toBurn;
        unchecked {
            toBurn = total - toStaking - toTreasury;
        }

        if (toStaking != 0) {
            nox.forceApprove(staking, toStaking);
            INoxShieldStaking(staking).notifyRewardAmount(toStaking);
        }
        if (toTreasury != 0) nox.safeTransfer(treasury, toTreasury);
        if (toBurn != 0) nox.safeTransfer(BURN_ADDRESS, toBurn);

        emit FeeSplit(total, toStaking, toTreasury, toBurn);
    }

    /// @notice Sets the split. Shares must sum to 10_000 with treasury at most 5_000.
    function setSplits(uint16 stakingBps_, uint16 treasuryBps_, uint16 burnBps_) external onlyOwner {
        _checkSplit(stakingBps_, treasuryBps_, burnBps_);
        stakingBps = stakingBps_;
        treasuryBps = treasuryBps_;
        burnBps = burnBps_;
        emit SplitsUpdated(stakingBps_, treasuryBps_, burnBps_);
    }

    /// @notice Sets the keeper, who can only swap fees into NOX through approved routers.
    /// @param keeper_ address(0) leaves only the owner able to swap.
    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @notice Proposes a new staking contract. Replaces any pending proposal.
    function proposeStaking(address value) external onlyOwner {
        if (value == address(0)) revert ZeroAddress();
        pendingStaking = PendingAddress(value, uint64(block.timestamp + TIMELOCK_DELAY));
        emit ChangeProposed("staking", value, pendingStaking.eta);
    }

    /// @notice Executes a matured staking change. Permissionless.
    function executeStaking() external {
        staking = _consumePending(pendingStaking, "staking");
        delete pendingStaking;
    }

    /// @notice Proposes a new treasury. Replaces any pending proposal.
    function proposeTreasury(address value) external onlyOwner {
        if (value == address(0)) revert ZeroAddress();
        pendingTreasury = PendingAddress(value, uint64(block.timestamp + TIMELOCK_DELAY));
        emit ChangeProposed("treasury", value, pendingTreasury.eta);
    }

    /// @notice Executes a matured treasury change. Permissionless.
    function executeTreasury() external {
        treasury = _consumePending(pendingTreasury, "treasury");
        delete pendingTreasury;
    }

    /// @notice Proposes approving a DEX router for buybacks.
    function proposeRouter(address router) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        pendingRouterEta[router] = uint64(block.timestamp + TIMELOCK_DELAY);
        emit ChangeProposed("router", router, pendingRouterEta[router]);
    }

    /// @notice Approves a matured router proposal. Permissionless.
    function executeRouterApproval(address router) external {
        uint64 eta = pendingRouterEta[router];
        if (eta == 0) revert NoPendingChange();
        if (block.timestamp < eta) revert TimelockNotReady();
        delete pendingRouterEta[router];
        approvedRouter[router] = true;
        emit ChangeExecuted("router", router);
    }

    /// @notice Revokes a router immediately. Does not cancel a pending approval.
    function revokeRouter(address router) external onlyOwner {
        approvedRouter[router] = false;
        emit RouterRevoked(router);
    }

    function _checkSplit(uint16 stakingBps_, uint16 treasuryBps_, uint16 burnBps_) private pure {
        if (uint256(stakingBps_) + treasuryBps_ + burnBps_ != BPS) revert BadSplit();
        if (treasuryBps_ > MAX_TREASURY_BPS) revert TreasuryShareTooHigh();
    }

    function _checkKeeper() private view {
        if (msg.sender != keeper && msg.sender != owner()) revert NotKeeperOrOwner();
    }

    function _checkSwap(address router, uint256 amountIn, uint256 minNoxOut, address[] calldata path) private view {
        if (!approvedRouter[router]) revert RouterNotApproved();
        if (amountIn == 0 || minNoxOut == 0) revert ZeroAmount();
        if (path.length < 2 || path[path.length - 1] != address(nox)) revert BadSwapPath();
    }

    function _consumePending(PendingAddress memory pending, bytes32 kind) private returns (address value) {
        if (pending.value == address(0)) revert NoPendingChange();
        if (block.timestamp < pending.eta) revert TimelockNotReady();
        value = pending.value;
        emit ChangeExecuted(kind, value);
    }
}
