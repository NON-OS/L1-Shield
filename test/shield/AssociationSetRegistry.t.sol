// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AssociationSetRegistry} from "../../contracts/shield/AssociationSetRegistry.sol";
import {Goldilocks} from "../../contracts/shield/libraries/Goldilocks.sol";

contract AssociationSetRegistryTest is Test {
    AssociationSetRegistry internal registry;

    event AssociationSetPublished(uint256 indexed setId, bytes32 indexed root, address indexed publisher, string uri);

    function setUp() public {
        registry = new AssociationSetRegistry();
    }

    function _canon(bytes32 h) internal pure returns (bytes32 out) {
        uint256 v = uint256(h);
        uint256 acc;
        for (uint256 i = 0; i < 4; ++i) {
            acc |= (((v >> (64 * i)) & 0xFFFFFFFFFFFFFFFF) % Goldilocks.P) << (64 * i);
        }
        out = bytes32(acc);
    }

    function test_PublishIsPermissionless() public {
        bytes32 root = _canon(keccak256("set-1"));
        address randomPublisher = makeAddr("anyone");

        vm.expectEmit(true, true, true, true);
        emit AssociationSetPublished(0, root, randomPublisher, "ipfs://set-1");
        vm.prank(randomPublisher);
        uint256 setId = registry.publishRoot(root, "ipfs://set-1");

        assertEq(setId, 0);
        assertTrue(registry.isRegisteredRoot(root));
        assertEq(registry.rootOf(0), root);
        assertEq(registry.setCount(), 1);
    }

    function test_RepublishSameRootGetsFreshSetId_HistoryAppendOnly() public {
        bytes32 root = _canon(keccak256("set-1"));
        registry.publishRoot(root, "ipfs://a");
        uint256 second = registry.publishRoot(root, "ipfs://b");
        assertEq(second, 1, "new publication id");
        assertEq(registry.rootOf(0), root, "old record untouched");
        assertTrue(registry.isRegisteredRoot(root), "still registered");
    }

    function test_NonCanonicalRootReverts() public {
        vm.expectRevert(AssociationSetRegistry.NonCanonicalRoot.selector);
        registry.publishRoot(bytes32(type(uint256).max), "");
    }

    function test_ZeroRootReverts() public {
        vm.expectRevert(AssociationSetRegistry.EmptyRoot.selector);
        registry.publishRoot(bytes32(0), "");
    }

    /// @notice Fuzz: registration is append-only, once registered, no sequence
    ///         of further publications can unregister a root.
    function testFuzz_AppendOnly(bytes32 a, bytes32 b) public {
        bytes32 rootA = _canon(a);
        bytes32 rootB = _canon(b);
        vm.assume(rootA != bytes32(0) && rootB != bytes32(0));

        registry.publishRoot(rootA, "");
        registry.publishRoot(rootB, "");
        assertTrue(registry.isRegisteredRoot(rootA));
        assertTrue(registry.isRegisteredRoot(rootB));
    }
}
