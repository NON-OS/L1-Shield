// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SymTest} from "halmos-cheatcodes/SymTest.sol";
import {Test} from "forge-std/Test.sol";
import {AssociationSetRegistry} from "../../../../contracts/shield/AssociationSetRegistry.sol";

/// Halmos proofs for the association-set registry over every root and caller. A root must be a
/// canonical Goldilocks digest and never changes once published.
/// Run: FOUNDRY_PROFILE=halmos halmos --match-contract AssociationSetRegistryHalmos
contract AssociationSetRegistryHalmos is SymTest, Test {
    uint256 constant P = 0xFFFFFFFF00000001;

    AssociationSetRegistry reg;

    function setUp() public {
        reg = new AssociationSetRegistry();
    }

    function _canonical(bytes32 root) internal pure returns (bool) {
        uint256 v = uint256(root);
        return (v & 0xFFFFFFFFFFFFFFFF) < P && ((v >> 64) & 0xFFFFFFFFFFFFFFFF) < P
            && ((v >> 128) & 0xFFFFFFFFFFFFFFFF) < P && (v >> 192) < P;
    }

    function _publish(address caller, bytes32 root) internal returns (bool ok, uint256 id) {
        vm.prank(caller);
        bytes memory ret;
        (ok, ret) = address(reg).call(abi.encodeCall(reg.publishRoot, (root, "ipfs://set")));
        if (ok) id = abi.decode(ret, (uint256));
    }

    /// A publication succeeds if and only if the root is non-zero and canonical.
    function check_aRootIsAcceptedExactlyWhenCanonicalAndNonZero(address caller, bytes32 root) public {
        (bool ok,) = _publish(caller, root);
        assert(ok == (root != bytes32(0) && _canonical(root)));
    }

    /// A refused publication changes neither the count, the next id slot, nor the registration.
    function check_aRefusedRootLeavesNoTrace(address caller, bytes32 root) public {
        uint256 countBefore = reg.setCount();
        (bool ok,) = _publish(caller, root);
        if (!ok) {
            assert(reg.setCount() == countBefore);
            assert(reg.rootOf(countBefore) == bytes32(0));
            assert(!reg.isRegisteredRoot(root));
        }
    }

    /// Two successful publications by any callers get consecutive ids starting at the count.
    function check_setIdsIncreaseByExactlyOne(address a, address b, bytes32 r1, bytes32 r2) public {
        uint256 start = reg.setCount();
        (bool ok1, uint256 id1) = _publish(a, r1);
        vm.assume(ok1);
        assert(id1 == start);
        assert(reg.setCount() == start + 1);
        (bool ok2, uint256 id2) = _publish(b, r2);
        vm.assume(ok2);
        assert(id2 == id1 + 1);
        assert(reg.setCount() == start + 2);
    }

    /// A published root never changes or loses its registration, whatever is published after it.
    function check_aPublishedRootNeverChanges(address a, address b, bytes32 r1, bytes32 r2) public {
        (bool ok1, uint256 id1) = _publish(a, r1);
        vm.assume(ok1);
        _publish(b, r2);
        assert(reg.rootOf(id1) == r1);
        assert(reg.isRegisteredRoot(r1));
    }

    /// After one publication into an empty registry only that root is registered, and no id at or
    /// past the count holds a root.
    function check_registrationMatchesPublication(address a, bytes32 r1, bytes32 q, uint256 id) public {
        assert(reg.setCount() == 0);
        assert(!reg.isRegisteredRoot(q));
        (bool ok1,) = _publish(a, r1);
        vm.assume(ok1);
        assert(reg.isRegisteredRoot(q) == (q == r1));
        vm.assume(id >= reg.setCount());
        assert(reg.rootOf(id) == bytes32(0));
    }

    /// The zero root is never registered, so an unset root never reads as an approved set.
    function check_theZeroRootIsNeverRegistered(address a, bytes32 r1) public {
        _publish(a, r1);
        assert(!reg.isRegisteredRoot(bytes32(0)));
    }
}
