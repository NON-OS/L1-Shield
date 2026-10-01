// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IRootCommitter {
    function currentRoot() external view returns (bytes32);
    function commitRoot() external returns (bytes32 root);
}

/// @title RootBounty
/// @notice Pays whoever commits a new pool root through it, from ETH anyone sends it.
/// @dev No owner. Pays only when the root moves, at most `bounty` per `interval`, and never
///      touches the pool's funds. The pool's code is at its size limit, so the reserve lives here.
contract RootBounty is ReentrancyGuard {
    uint256 public constant MAX_BOUNTY = 0.001 ether;
    uint256 public constant MIN_INTERVAL = 10 minutes;

    IRootCommitter public immutable pool;
    uint256 public immutable bounty; // wei
    uint256 public immutable interval; // seconds between paid commits
    uint64 public lastPaidAt;

    event Funded(address indexed from, uint256 amount);
    event BountyPaid(address indexed to, bytes32 indexed root, uint256 amount);

    error ZeroAddress();
    error BadBounty();
    error BadInterval();
    error TransferFailed();

    constructor(IRootCommitter pool_, uint256 bounty_, uint256 interval_) {
        if (address(pool_) == address(0)) revert ZeroAddress();
        if (bounty_ == 0 || bounty_ > MAX_BOUNTY) revert BadBounty();
        if (interval_ < MIN_INTERVAL) revert BadInterval();
        pool = pool_;
        bounty = bounty_;
        interval = interval_;
    }

    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }

    /// @notice Commits the pool's root and pays the caller if it moved and the interval has passed.
    function commit() external nonReentrant returns (bytes32 root, uint256 paid) {
        bytes32 before = pool.currentRoot();
        root = pool.commitRoot();
        if (root == before || block.timestamp < uint256(lastPaidAt) + interval) return (root, 0);
        paid = address(this).balance < bounty ? address(this).balance : bounty;
        if (paid == 0) return (root, 0);
        lastPaidAt = uint64(block.timestamp);
        emit BountyPaid(msg.sender, root, paid);
        (bool ok,) = msg.sender.call{value: paid}("");
        if (!ok) revert TransferFailed();
    }
}
