// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AssociationSetRegistry} from "../../../../contracts/shield/AssociationSetRegistry.sol";

/// Publishes random roots from random callers: canonical ones, the zero root, roots with one limb at
/// or above the Goldilocks prime, and repeats of roots already published. It keeps its own copy of
/// every accepted root in order.
contract RegistryHandler is Test {
    uint256 constant P = 0xFFFFFFFF00000001;

    AssociationSetRegistry public reg;
    bytes32[] public accepted;
    bytes32[] public refused;
    uint256 public wrongId;

    constructor(AssociationSetRegistry reg_) {
        reg = reg_;
    }

    function acceptedCount() external view returns (uint256) {
        return accepted.length;
    }

    function refusedCount() external view returns (uint256) {
        return refused.length;
    }

    function _limb(uint256 x) internal pure returns (uint256) {
        return x % P;
    }

    function publish(address caller, uint256 kind, uint256 a, uint256 b, uint256 c, uint256 d) external {
        bytes32 root;
        uint256 k = kind % 5;
        if (k == 0) {
            root = bytes32(0);
        } else if (k == 1 && accepted.length > 0) {
            root = accepted[a % accepted.length];
        } else {
            uint256 v = _limb(a) | (_limb(b) << 64) | (_limb(c) << 128) | (_limb(d) << 192);
            if (k == 2) {
                // push one limb to P or above
                uint256 i = b % 4;
                uint256 bad = P + (c % (type(uint64).max - P + 1));
                v = (v & ~(uint256(0xFFFFFFFFFFFFFFFF) << (64 * i))) | (bad << (64 * i));
            }
            root = bytes32(v);
        }
        uint256 expectId = reg.setCount();
        vm.prank(caller);
        try reg.publishRoot(root, "ipfs://set") returns (uint256 id) {
            if (id != expectId) wrongId++;
            accepted.push(root);
        } catch {
            refused.push(root);
        }
    }
}

/// Invariants of AssociationSetRegistry over random publication sequences.
/// Run: forge test --match-contract AssociationSetRegistryInvariants (5,000 runs of depth 200 each).
contract AssociationSetRegistryInvariants is Test {
    uint256 constant P = 0xFFFFFFFF00000001;
    AssociationSetRegistry reg;
    RegistryHandler h;

    function setUp() public {
        reg = new AssociationSetRegistry();
        h = new RegistryHandler(reg);
        targetContract(address(h));
    }

    function _canonical(bytes32 root) internal pure returns (bool) {
        uint256 v = uint256(root);
        return (v & 0xFFFFFFFFFFFFFFFF) < P && ((v >> 64) & 0xFFFFFFFFFFFFFFFF) < P
            && ((v >> 128) & 0xFFFFFFFFFFFFFFFF) < P && (v >> 192) < P;
    }

    /// The count equals the number of accepted publications, ids are handed out in order, the
    /// newest id holds the newest accepted root, and the slot at the count is empty.
    /// forge-config: default.invariant.runs = 5000
    /// forge-config: default.invariant.depth = 200
    function invariant_countAndNewestEntryMatch() public view {
        uint256 n = h.acceptedCount();
        assertEq(reg.setCount(), n);
        assertEq(h.wrongId(), 0);
        if (n > 0) assertEq(reg.rootOf(n - 1), h.accepted(n - 1));
        assertEq(reg.rootOf(n), bytes32(0));
    }

    /// At the end of each run every id still holds the root accepted at that position. Accepted
    /// roots are canonical, non-zero and registered. Refused roots are unregistered.
    function afterInvariant() public view {
        uint256 n = h.acceptedCount();
        for (uint256 i = 0; i < n; i++) {
            bytes32 r = h.accepted(i);
            assertEq(reg.rootOf(i), r);
            assertTrue(r != bytes32(0) && _canonical(r));
            assertTrue(reg.isRegisteredRoot(r));
        }
        for (uint256 i = 0; i < h.refusedCount(); i++) {
            bytes32 r = h.refused(i);
            assertTrue(r == bytes32(0) || !_canonical(r));
            assertFalse(reg.isRegisteredRoot(r));
        }
    }
}
