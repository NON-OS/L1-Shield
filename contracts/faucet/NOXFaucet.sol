// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title NOXFaucet
/// @notice Dispenses ETH and NOX against signed tickets that any relayer may submit.
/// @dev Caps, cooldown, epoch budget and ETH floor bound payout. A leaked signer key loses at
///      most one epoch budget per epoch until the owner rotates it. See docs/11-faucet.md.
contract NOXFaucet is Ownable2Step, Pausable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    bytes32 public constant CLAIM_TYPEHASH =
        keccak256("Claim(address recipient,uint256 ethAmount,uint256 noxAmount,uint256 nonce,uint256 deadline)");

    IERC20 public immutable NOX;

    /// @notice Key whose EIP-712 signature authorises a ticket.
    address public signer;

    uint128 public maxEthPerClaim; // wei
    uint128 public maxNoxPerClaim; // NOX wei
    uint64 public cooldown; // seconds between claims by one recipient
    uint64 public epochLength; // seconds
    uint128 public epochEthBudget; // wei per epoch
    uint128 public epochNoxBudget; // NOX wei per epoch

    uint64 public epochId; // block.timestamp / epochLength at the last reset
    uint128 public epochEthSpent;
    uint128 public epochNoxSpent;

    /// @notice ETH balance, in wei, the faucet will not spend below.
    uint256 public ethFloor;

    /// @notice Enables the unsigned `claim()` path, gated on cooldown alone.
    bool public openClaims;

    mapping(address => uint64) public lastClaimAt;
    mapping(address => uint256) public nonces;

    event Claimed(
        address indexed recipient, address indexed relayer, uint256 ethAmount, uint256 noxAmount, bool ticketed
    );
    event SignerUpdated(address indexed previous, address indexed current);
    event LimitsUpdated(uint128 maxEth, uint128 maxNox, uint64 cooldown, uint256 ethFloor);
    event EpochUpdated(uint64 epochLength, uint128 ethBudget, uint128 noxBudget);
    event OpenClaimsUpdated(bool open);
    event Funded(address indexed from, uint256 amount);
    event Swept(address indexed to, uint256 ethAmount, uint256 noxAmount);

    error ZeroAddress();
    error ZeroEpoch();
    error TicketExpired();
    error BadSignature();
    error BadNonce(uint256 expected, uint256 given);
    error OpenClaimsDisabled();
    error StillCooling(uint64 nextEligible);
    error NothingToPay();
    error EpochExhausted();
    error EthSendFailed();

    constructor(
        IERC20 nox_,
        address owner_,
        address signer_,
        uint128 maxEthPerClaim_,
        uint128 maxNoxPerClaim_,
        uint64 cooldown_,
        uint64 epochLength_,
        uint128 epochEthBudget_,
        uint128 epochNoxBudget_
    ) Ownable(owner_) EIP712("NOXFaucet", "1") {
        if (address(nox_) == address(0) || owner_ == address(0) || signer_ == address(0)) revert ZeroAddress();
        if (epochLength_ == 0) revert ZeroEpoch();
        NOX = nox_;
        signer = signer_;
        maxEthPerClaim = maxEthPerClaim_;
        maxNoxPerClaim = maxNoxPerClaim_;
        cooldown = cooldown_;
        epochLength = epochLength_;
        epochEthBudget = epochEthBudget_;
        epochNoxBudget = epochNoxBudget_;
        epochId = uint64(block.timestamp / epochLength_);
        emit SignerUpdated(address(0), signer_);
    }

    /// @notice Redeems a signed ticket. Funds go to `recipient` and the caller only pays gas.
    /// @dev Amounts are clamped. The per-recipient nonce makes tickets single-use and ordered.
    /// @param nonce Must equal `nonces[recipient]`.
    /// @param deadline Unix seconds.
    function claimWithTicket(
        address recipient,
        uint256 ethAmount,
        uint256 noxAmount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata sig
    ) external nonReentrant whenNotPaused {
        if (recipient == address(0)) revert ZeroAddress();
        if (block.timestamp > deadline) revert TicketExpired();

        uint256 expected = nonces[recipient];
        if (nonce != expected) revert BadNonce(expected, nonce);

        bytes32 digest =
            _hashTypedDataV4(keccak256(abi.encode(CLAIM_TYPEHASH, recipient, ethAmount, noxAmount, nonce, deadline)));
        if (ECDSA.recover(digest, sig) != signer) revert BadSignature();

        nonces[recipient] = expected + 1;
        _dispense(recipient, ethAmount, noxAmount, true);
    }

    /// @notice Unsigned claim at the per-claim caps. Requires `openClaims`.
    function claim() external nonReentrant whenNotPaused {
        if (!openClaims) revert OpenClaimsDisabled();
        _dispense(msg.sender, maxEthPerClaim, maxNoxPerClaim, false);
    }

    // Clamp to caps, epoch remainder, then reserves. State is written before any transfer.
    function _dispense(address to, uint256 ethWant, uint256 noxWant, bool ticketed) private {
        uint64 last = lastClaimAt[to];
        if (last != 0 && block.timestamp < last + cooldown) revert StillCooling(last + cooldown);
        lastClaimAt[to] = uint64(block.timestamp);

        uint256 ethAmt = ethWant > maxEthPerClaim ? maxEthPerClaim : ethWant;
        uint256 noxAmt = noxWant > maxNoxPerClaim ? maxNoxPerClaim : noxWant;

        uint64 e = uint64(block.timestamp / epochLength);
        if (e != epochId) {
            epochId = e;
            epochEthSpent = 0;
            epochNoxSpent = 0;
        }

        uint256 ethLeft = epochEthBudget > epochEthSpent ? epochEthBudget - epochEthSpent : 0;
        uint256 noxLeft = epochNoxBudget > epochNoxSpent ? epochNoxBudget - epochNoxSpent : 0;
        if (ethAmt > ethLeft) ethAmt = ethLeft;
        if (noxAmt > noxLeft) noxAmt = noxLeft;

        uint256 bal = address(this).balance;
        uint256 spendable = bal > ethFloor ? bal - ethFloor : 0;
        if (ethAmt > spendable) ethAmt = spendable;
        uint256 noxBal = NOX.balanceOf(address(this));
        if (noxAmt > noxBal) noxAmt = noxBal;

        if (ethAmt == 0 && noxAmt == 0) {
            if (ethLeft == 0 && noxLeft == 0) revert EpochExhausted();
            revert NothingToPay();
        }

        epochEthSpent += uint128(ethAmt);
        epochNoxSpent += uint128(noxAmt);

        if (noxAmt != 0) NOX.safeTransfer(to, noxAmt);
        if (ethAmt != 0) {
            (bool ok,) = to.call{value: ethAmt}("");
            if (!ok) revert EthSendFailed();
        }

        emit Claimed(to, msg.sender, ethAmt, noxAmt, ticketed);
    }

    /// @notice What `recipient` would get now for a request at the per-claim caps.
    /// @return claimable Whether the payout would be non-zero.
    /// @return nextEligible When the cooldown ends, 0 if never claimed.
    function quote(address recipient)
        external
        view
        returns (
            bool claimable,
            uint64 nextEligible,
            uint256 ethAmount,
            uint256 noxAmount,
            uint256 nonce,
            uint256 epochEthLeft,
            uint256 epochNoxLeft
        )
    {
        nonce = nonces[recipient];
        uint64 last = lastClaimAt[recipient];
        nextEligible = last == 0 ? 0 : last + cooldown;

        uint64 e = uint64(block.timestamp / epochLength);
        uint128 spentE = e == epochId ? epochEthSpent : 0;
        uint128 spentN = e == epochId ? epochNoxSpent : 0;
        epochEthLeft = epochEthBudget > spentE ? epochEthBudget - spentE : 0;
        epochNoxLeft = epochNoxBudget > spentN ? epochNoxBudget - spentN : 0;

        uint256 bal = address(this).balance;
        uint256 spendable = bal > ethFloor ? bal - ethFloor : 0;
        ethAmount = maxEthPerClaim;
        if (ethAmount > epochEthLeft) ethAmount = epochEthLeft;
        if (ethAmount > spendable) ethAmount = spendable;

        noxAmount = maxNoxPerClaim;
        if (noxAmount > epochNoxLeft) noxAmount = epochNoxLeft;
        uint256 noxBal = NOX.balanceOf(address(this));
        if (noxAmount > noxBal) noxAmount = noxBal;

        claimable = !paused() && block.timestamp >= nextEligible && (ethAmount != 0 || noxAmount != 0);
    }

    /// @notice EIP-712 digest the signer signs for a ticket.
    function claimDigest(address recipient, uint256 ethAmount, uint256 noxAmount, uint256 nonce, uint256 deadline)
        external
        view
        returns (bytes32)
    {
        return
            _hashTypedDataV4(keccak256(abi.encode(CLAIM_TYPEHASH, recipient, ethAmount, noxAmount, nonce, deadline)));
    }

    /// @notice ETH and NOX held. The ETH figure includes the floor.
    function reserves() external view returns (uint256 ethBalance, uint256 noxBalance) {
        return (address(this).balance, NOX.balanceOf(address(this)));
    }

    /// @notice Rotates the ticket signer.
    function setSigner(address s) external onlyOwner {
        if (s == address(0)) revert ZeroAddress();
        emit SignerUpdated(signer, s);
        signer = s;
    }

    /// @notice Sets per-claim caps, the cooldown and the ETH floor.
    /// @param cd Cooldown in seconds.
    /// @param floor_ ETH in wei the faucet keeps.
    function setLimits(uint128 maxEth, uint128 maxNox, uint64 cd, uint256 floor_) external onlyOwner {
        maxEthPerClaim = maxEth;
        maxNoxPerClaim = maxNox;
        cooldown = cd;
        ethFloor = floor_;
        emit LimitsUpdated(maxEth, maxNox, cd, floor_);
    }

    /// @notice Sets the epoch length and budgets and starts a fresh epoch.
    /// @param length_ Epoch length in seconds.
    function setEpoch(uint64 length_, uint128 ethBudget, uint128 noxBudget) external onlyOwner {
        if (length_ == 0) revert ZeroEpoch();
        epochLength = length_;
        epochEthBudget = ethBudget;
        epochNoxBudget = noxBudget;
        epochId = uint64(block.timestamp / length_);
        epochEthSpent = 0;
        epochNoxSpent = 0;
        emit EpochUpdated(length_, ethBudget, noxBudget);
    }

    /// @notice Enables or disables the unsigned `claim()` path.
    function setOpenClaims(bool open) external onlyOwner {
        openClaims = open;
        emit OpenClaimsUpdated(open);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Withdraws funds to `to`, ignoring the ETH floor.
    function sweep(address to, uint256 ethAmount, uint256 noxAmount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (noxAmount != 0) NOX.safeTransfer(to, noxAmount);
        if (ethAmount != 0) {
            (bool ok,) = to.call{value: ethAmount}("");
            if (!ok) revert EthSendFailed();
        }
        emit Swept(to, ethAmount, noxAmount);
    }

    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }
}
