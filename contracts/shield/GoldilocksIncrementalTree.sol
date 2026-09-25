// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoseidonGoldilocks} from "./interfaces/IPoseidonGoldilocks.sol";

/// @title GoldilocksIncrementalTree
/// @notice Append-only depth-32 Poseidon-Goldilocks Merkle tree with a window of recent roots.
/// @dev See docs/09-tree.md.
abstract contract GoldilocksIncrementalTree {
    /// @dev Depth cannot be raised after deployment. Do not lower it for gas.
    uint256 public constant TREE_DEPTH = 32;
    uint256 public constant ROOT_WINDOW = 128;
    // leaf 2^32-1 would carry past _frontier[31], so capacity stops one short of 2^32
    uint256 private constant MAX_LEAVES = (1 << 32) - 1;

    IPoseidonGoldilocks public immutable treeHasher;

    bytes32[TREE_DEPTH] private _frontier;
    bytes32[TREE_DEPTH] private _zeros;
    bytes32[ROOT_WINDOW] private _rootRing;
    mapping(bytes32 root => bool known) private _knownRoot;
    uint256 private _rootRingIndex;

    /// @notice Current leaf count.
    uint40 public nextLeafIndex;
    bytes32 public currentRoot;

    event RootUpdated(bytes32 indexed root, uint40 leafCount);

    error TreeIsFull();
    error NoLeaves();

    constructor(IPoseidonGoldilocks hasher_) {
        treeHasher = hasher_;
        bytes32 z = bytes32(0);
        for (uint256 i = 0; i < TREE_DEPTH; ++i) {
            _zeros[i] = z;
            _frontier[i] = z;
            z = hasher_.hash2(z, z);
        }
        // publish the empty root through _pushRoot, starting the cursor one before slot 0
        _rootRingIndex = ROOT_WINDOW - 1;
        _pushRoot(z, 0);
    }

    /// @notice Empty-subtree digest at `level`.
    function zeros(uint256 level) external view returns (bytes32) {
        return _zeros[level];
    }

    // exposed for single-vs-batch insert equivalence tests
    function _frontierAt(uint256 level) internal view returns (bytes32) {
        return _frontier[level];
    }

    /// @notice True if `root` is one of the last ROOT_WINDOW roots. Zero is never known.
    function isKnownRoot(bytes32 root) public view returns (bool) {
        if (root == bytes32(0)) return false;
        return _knownRoot[root];
    }

    // Evicting outright is safe only because a root cannot repeat without a Poseidon collision.
    function _pushRoot(bytes32 root, uint40 count) private {
        currentRoot = root;

        uint256 slot = (_rootRingIndex + 1) % ROOT_WINDOW;
        _rootRingIndex = slot;
        bytes32 evicted = _rootRing[slot];
        if (evicted != bytes32(0)) delete _knownRoot[evicted];
        _rootRing[slot] = root;
        _knownRoot[root] = true;

        emit RootUpdated(root, count);
    }

    // caller must pass a canonical digest
    function _insertLeaf(bytes32 leaf) internal returns (uint40 index) {
        index = nextLeafIndex;
        if (uint256(index) >= MAX_LEAVES) revert TreeIsFull();

        bytes32 node = leaf;
        uint256 path = index;
        for (uint256 level = 0; level < TREE_DEPTH; ++level) {
            if (path & 1 == 0) {
                _frontier[level] = node;
                node = treeHasher.hash2(node, _zeros[level]);
            } else {
                node = treeHasher.hash2(_frontier[level], node);
            }
            path >>= 1;
        }

        nextLeafIndex = index + 1;
        _pushRoot(node, index + 1);
    }

    // Deferred path: inserts update only the frontier and _commitRoot publishes the root.
    event RootCommitted(bytes32 indexed root, uint40 leafCount);

    error NoLeavesSinceLastRoot();

    function _insertLeafDeferred(bytes32 leaf) internal returns (uint40 index) {
        index = nextLeafIndex;
        if (uint256(index) >= MAX_LEAVES) revert TreeIsFull();

        bytes32 node = leaf;
        uint256 path = index;
        uint256 level = 0;
        while (path & 1 == 1) {
            node = treeHasher.hash2(_frontier[level], node);
            path >>= 1;
            unchecked {
                ++level;
            }
        }
        _frontier[level] = node;
        nextLeafIndex = index + 1;
    }

    function _commitRoot() internal returns (bytes32 root) {
        uint40 count = nextLeafIndex;
        if (count == 0) revert NoLeavesSinceLastRoot();
        root = _foldFrontier(count);

        // commitRoot is permissionless. A no-op commit must not advance the ring or it evicts live roots.
        if (root == currentRoot) return root;

        _pushRoot(root, count);
        emit RootCommitted(root, count);
    }

    // bit set: the frontier holds the left sibling. bit clear: an empty subtree sits on the right.
    function _foldFrontier(uint40 count) internal view returns (bytes32 node) {
        node = _zeros[0];
        uint256 p = uint256(count);
        for (uint256 level = 0; level < TREE_DEPTH; ++level) {
            node = (p & 1 == 1) ? treeHasher.hash2(_frontier[level], node) : treeHasher.hash2(node, _zeros[level]);
            p >>= 1;
        }
    }

    function _insertLeavesDeferred(bytes32[] memory leaves) internal returns (uint40 first) {
        uint256 k = leaves.length;
        if (k == 0) revert NoLeaves();
        first = nextLeafIndex;
        if (uint256(first) + k > MAX_LEAVES) revert TreeIsFull();

        for (uint256 i = 0; i < k; ++i) {
            bytes32 node = leaves[i];
            uint256 path = uint256(first) + i;
            uint256 level = 0;
            while (path & 1 == 1) {
                node = treeHasher.hash2(_frontier[level], node);
                path >>= 1;
                unchecked {
                    ++level;
                }
            }
            _frontier[level] = node;
        }
        nextLeafIndex = uint40(uint256(first) + k);
    }

    // Same result as sequential inserts, but only the last leaf walks the full depth.
    function _insertLeaves(bytes32[] memory leaves) internal returns (uint40 first) {
        uint256 k = leaves.length;
        if (k == 0) revert NoLeaves();
        first = nextLeafIndex;
        if (uint256(first) + k > MAX_LEAVES) revert TreeIsFull();

        for (uint256 i = 0; i + 1 < k; ++i) {
            bytes32 node = leaves[i];
            uint256 path = uint256(first) + i;
            uint256 level = 0;
            while (path & 1 == 1) {
                node = treeHasher.hash2(_frontier[level], node);
                path >>= 1;
                unchecked {
                    ++level;
                }
            }
            _frontier[level] = node;
        }

        uint40 index = uint40(uint256(first) + k - 1);
        bytes32 top = leaves[k - 1];
        uint256 p = index;
        for (uint256 level = 0; level < TREE_DEPTH; ++level) {
            if (p & 1 == 0) {
                _frontier[level] = top;
                top = treeHasher.hash2(top, _zeros[level]);
            } else {
                top = treeHasher.hash2(_frontier[level], top);
            }
            p >>= 1;
        }

        nextLeafIndex = index + 1;
        _pushRoot(top, index + 1);
    }
}
