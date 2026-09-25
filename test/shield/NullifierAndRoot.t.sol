// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase} from "./ShieldTestBase.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";
import {MockReentrantERC20} from "./mocks/MockHostileERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// One empty client-data blob per settlement output. Empty is legal: the opening travels out of band.
function _blobs(uint256 n) pure returns (bytes[] memory b) {
    b = new bytes[](n);
}

/// One blob per output, derived from the public words: twelve words and two outputs per intent.
function _blobsFor(uint256[] memory publicWords) pure returns (bytes[] memory) {
    return _blobs(2 * (publicWords.length / 12));
}


/// Every way a nullifier could clear twice, and every way a non-canonical root could reach
/// settlement, one test per path. All are refused.
contract NullifierAndRootTest is ShieldTestBase {
    MockReentrantERC20 hook;
    uint64 hookId;

    function setUp() public override {
        super.setUp();
        hook = new MockReentrantERC20();
        hookId = registerToken(address(hook));
        hook.mint(alice, 1e24);
        vm.prank(alice);
        hook.approve(address(pool), type(uint256).max);
    }

    function _batchWith(bytes32 root, uint64 assetId, uint256 amount, address to)
        internal
        returns (uint256[] memory w)
    {
        TIntent[] memory intents = new TIntent[](1);
        intents[0] = newIntent(amount, 0, to, assetId);
        w = encodeBatch(root, assocRoot, 0, intents);
    }

    /// The same nullifier in two intents of one batch is refused before anything is stored.
    function test_theSameNullifierTwiceInOneBatchReverts() public {
        depositNative(alice, 4 ether);
        TIntent[] memory intents = new TIntent[](2);
        intents[0] = newIntent(1e17, 0, bob, 0);
        intents[1] = newIntent(1e17, 0, bob, 0);
        intents[1].nf0 = intents[0].nf0; // the collision
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 0, intents);
        vm.expectRevert(ShieldedPool.NullifierAlreadySpent.selector);
        settle(w);
    }

    /// A nullifier spent in one batch is refused in a later one with a new recipient, amount and root.
    function test_aNullifierCannotBeReplayedInALaterBatch() public {
        depositNative(alice, 6 ether);
        TIntent[] memory first = new TIntent[](1);
        first[0] = newIntent(1e17, 0, bob, 0);
        settle(encodeBatch(pool.currentRoot(), assocRoot, 0, first));

        TIntent[] memory second = new TIntent[](1);
        second[0] = newIntent(2e17, 0, relayer, 0);
        second[0].nf0 = first[0].nf0; // the replay
        // Built before expectRevert, which would otherwise catch the `pool.currentRoot()` call.
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 0, second);
        vm.expectRevert(ShieldedPool.NullifierAlreadySpent.selector);
        settle(w);
    }

    /// A token hook that re-settles the batch during its own payout is refused. Under the push gas
    /// cap the hooked payout fails and is credited, so the hook runs when bob claims.
    function test_aReentrantSettleCannotRespendTheBatchItIsInside() public {
        vm.prank(alice);
        pool.absorb(hookId, 10e18, fresh());

        TIntent[] memory intents = new TIntent[](1);
        intents[0] = newIntent(1e18, 0, bob, hookId);
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 0, intents);
        // the hook re-submits the very batch being settled
        hook.arm(address(pool), abi.encodeCall(pool.settleBatch, (hex"70726f6f66", w,  noResidual(), "", _blobs(2))));
        settle(w);
        assertEq(pool.claimable(hookId, bob), 1e18, "the hooked push failed and bob is owed");

        vm.prank(bob);
        pool.claim(hookId, bob);
        assertTrue(hook.fired(), "the hook must have run, or this test proves nothing");
        assertEq(bytes4(hook.lastError()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "re-entry refused");
        assertEq(hook.balanceOf(bob), 1e18, "paid once");
        assertTrue(pool.nullifierSpent(bytes32(w[2])), "and the nullifier is spent exactly once");
    }

    /// An intent whose two nullifiers are equal is refused.
    function test_anIntentCannotCarryOneNullifierTwice() public {
        depositNative(alice, 2 ether);
        TIntent[] memory intents = new TIntent[](1);
        intents[0] = newIntent(1e17, 0, bob, 0);
        intents[0].nf1 = intents[0].nf0;
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 0, intents);
        vm.expectRevert(ShieldedPool.DuplicateNullifier.selector);
        settle(w);
    }

    /// A well-formed root that was never published is refused.
    function test_anInventedRootIsRefused() public {
        depositNative(alice, 2 ether);
        vm.expectRevert(ShieldedPool.UnknownOrStaleRoot.selector);
        settle(_batchWith(canon(dig("invented")), 0, 1e17, bob));
    }

    /// The zero digest, which fills the ring's empty slots, is never a known root.
    function test_theZeroRootIsNeverAccepted() public {
        depositNative(alice, 2 ether);
        assertFalse(pool.isKnownRoot(bytes32(0)), "zero must not read as known");
        vm.expectRevert(ShieldedPool.UnknownOrStaleRoot.selector);
        settle(_batchWith(bytes32(0), 0, 1e17, bob));
    }

    /// A canonical root evicted from the window is refused.
    function test_aRootEvictedFromTheWindowIsRefused() public {
        depositNative(alice, 2 ether);
        pool.commitRoot();
        bytes32 stale = pool.currentRoot();
        assertTrue(pool.isKnownRoot(stale), "canonical when made");
        // The ring advances once per published root, so a window of publications evicts.
        for (uint256 i = 0; i < pool.ROOT_WINDOW(); ++i) {
            depositNative(alice, 1e15);
            pool.commitRoot();
        }
        assertFalse(pool.isKnownRoot(stale), "evicted after a full window of published roots");
        vm.expectRevert(ShieldedPool.UnknownOrStaleRoot.selector);
        settle(_batchWith(stale, 0, 1e17, bob));
    }

    /// Registering an asset moves no tree state, so listing cannot inject a root.
    function test_assetListingCannotInjectARoot() public {
        bytes32 before = pool.currentRoot();
        uint40 leavesBefore = pool.nextLeafIndex();
        registerToken(address(new MockReentrantERC20()));
        assertEq(pool.currentRoot(), before, "listing moved the root");
        assertEq(pool.nextLeafIndex(), leavesBefore, "listing inserted a leaf");
    }

    /// Absorb and settle leave the published root alone, and each `commitRoot` publishes a known root.
    function test_onlyCommittedRootsAndSettledOutputsAreKnown() public {
        bytes32 r0 = pool.currentRoot();
        depositNative(alice, 1 ether);
        assertEq(pool.currentRoot(), r0, "absorbing alone must not move the published root");

        bytes32 r1 = pool.commitRoot();
        assertTrue(r1 != r0 && pool.isKnownRoot(r1), "committing publishes a new known root");

        TIntent[] memory intents = new TIntent[](1);
        intents[0] = newIntent(1e17, 0, bob, 0);
        settle(encodeBatch(r1, assocRoot, 0, intents));
        // Settlement inserts its outputs and leaves the root walk to commitRoot.
        assertEq(pool.currentRoot(), r1, "settling alone must not move the published root");

        bytes32 r2 = pool.commitRoot();
        assertTrue(r2 != r1 && pool.isKnownRoot(r2), "committing after settlement publishes");
        assertTrue(pool.isKnownRoot(r1), "and the root the batch proved against stays known");
    }

    /// A window of no-op `commitRoot` calls does not evict a live root.
    function test_noOpCommitsCannotEvictTheWindow() public {
        depositNative(alice, 1 ether);
        bytes32 victim = pool.commitRoot();      // a prover starts building against this
        depositNative(alice, 1 ether);
        pool.commitRoot();                        // the tree moves on
        assertTrue(pool.isKnownRoot(victim), "victim root known before the spam");

        // No further deposits, so every commit republishes the same root.
        for (uint256 i = 0; i < pool.ROOT_WINDOW(); ++i) {
            pool.commitRoot();
        }
        assertTrue(pool.isKnownRoot(victim), "a window of no-op commits evicted a live root");
        assertEq(pool.currentRoot(), pool.commitRoot(), "a no-op commit returns the same root");

        // A commit that moves the root still publishes.
        depositNative(alice, 1 ether);
        bytes32 moved = pool.commitRoot();
        assertTrue(moved != victim && pool.isKnownRoot(moved), "a real commit still publishes");
    }

}
