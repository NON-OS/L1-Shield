// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase} from "./ShieldTestBase.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// One empty client-data blob per settlement output. Empty is legal and suits a fixture.
function _blobs(uint256 n) pure returns (bytes[] memory b) {
    b = new bytes[](n);
}

/// One blob per output for a batch given by its public words: 12 words and 2 outputs per intent.
function _blobsFor(uint256[] memory publicWords) pure returns (bytes[] memory) {
    return _blobs(2 * (publicWords.length / 12));
}

import {
    MockRebasingERC20,
    MockReentrantERC20,
    MockPickyERC20,
    MockNoReturnERC20
} from "./mocks/MockHostileERC20.sol";

/// The hostile-token matrix: rebasing, reentrant, blocking and no-return tokens.
/// Each test checks that a hostile token cannot reach anything outside its own escrow.
contract HostileTokensTest is ShieldTestBase {
    MockRebasingERC20 rebase;
    MockReentrantERC20 hook;
    MockPickyERC20 picky;
    MockNoReturnERC20 noret;
    uint64 rebaseId;
    uint64 hookId;
    uint64 pickyId;
    uint64 noretId;

    function setUp() public override {
        super.setUp();
        rebase = new MockRebasingERC20();
        hook = new MockReentrantERC20();
        picky = new MockPickyERC20();
        noret = new MockNoReturnERC20();
        rebaseId = registerToken(address(rebase));
        hookId = registerToken(address(hook));
        pickyId = registerToken(address(picky));
        noretId = registerToken(address(noret));
        rebase.mint(alice, 1e24);
        hook.mint(alice, 1e24);
        picky.mint(alice, 1e24);
        noret.mint(alice, 1e24);
        vm.startPrank(alice);
        rebase.approve(address(pool), type(uint256).max);
        hook.approve(address(pool), type(uint256).max);
        picky.approve(address(pool), type(uint256).max);
        noret.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function _deposit(uint64 id, uint256 amount) internal {
        vm.prank(alice);
        pool.absorb(id, amount, fresh());
    }

    /// A token that delivers less than it claims is refused at deposit by balance difference.
    function test_aTokenThatUnderdeliversIsRefusedAtDeposit() public {
        rebase.setFactorBps(9_000); // every transfer delivers 90 percent
        vm.prank(alice);
        vm.expectRevert(ShieldedPool.NonStandardTokenTransfer.selector);
        pool.absorb(rebaseId, 1e18, fresh());
    }

    /// A rebase after deposit does not change the shielded total.
    function test_aRebaseAfterDepositCannotChangeWhatThePoolOwes() public {
        _deposit(rebaseId, 1e18);
        uint256 owed = pool.totalShielded(rebaseId);
        rebase.setFactorBps(20_000); // the token doubles every balance under the pool's feet
        assertEq(pool.totalShielded(rebaseId), owed, "shielded accounting must not follow the token");
        rebase.setFactorBps(1);
        assertEq(pool.totalShielded(rebaseId), owed, "nor when it collapses");
    }

    /// A transfer hook that re-enters deposit is refused and the outer deposit still lands.
    function test_aTransferHookCannotReenterDeposit() public {
        hook.arm(address(pool), abi.encodeCall(pool.absorb, (hookId, 1e18, bytes32(uint256(1)))));
        _deposit(hookId, 1e18);
        assertTrue(hook.fired(), "the hook must have run, or this test proves nothing");
        assertEq(pool.totalShielded(hookId), _net(1e18), "one deposit, not two");
    }

    /// A transfer hook that re-enters settlement is refused, and bob is paid once. The hook runs in the
    /// payout if it fits the push gas cap, or else in the claim of the credit.
    function test_aTransferHookCannotReenterSettlement() public {
        _deposit(hookId, 10e18);
        uint256[] memory reenter = _intentFor(hookId, 1e18, bob);
        hook.arm(address(pool), abi.encodeCall(pool.settleBatch, (hex"70726f6f66", reenter, noResidual(), "", _blobs(2))));

        uint256[] memory w = _intentFor(hookId, 2e18, bob);
        settle(w);
        if (!hook.fired()) {
            assertEq(pool.claimable(hookId, bob), 2e18, "a refused push is credited");
            vm.prank(bob);
            pool.claim(hookId, bob);
        }
        assertTrue(hook.fired(), "the hook must have run, or this test proves nothing");
        assertEq(bytes4(hook.lastError()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "re-entry refused");
        assertEq(hook.balanceOf(bob), 2e18, "bob got the settled amount once, not twice");
        assertEq(pool.claimable(hookId, bob), 0, "nothing left owed");
    }

    /// A blocked recipient is credited what it could not be sent, and the batch still settles.
    function test_aBlockedRecipientIsOwedItRatherThanCostingEveryoneTheBatch() public {
        _deposit(pickyId, 10e18);
        picky.block_(bob, true);
        uint256[] memory w = _intentFor(pickyId, 1e18, bob);

        settle(w);

        (uint256 nf0,) = _nullifiers(w);
        assertTrue(pool.nullifierSpent(bytes32(nf0)), "the batch settled, so the note is spent");
        assertEq(picky.balanceOf(bob), 0, "a blocked recipient cannot have been paid");
        assertEq(pool.claimable(pickyId, bob), 1e18, "spent and gone rather than spent and owed");
    }

    /// Once the token stops blocking, the credited recipient claims the full amount.
    function test_theBlockedRecipientCollectsOnceTheTokenRelents() public {
        _deposit(pickyId, 10e18);
        picky.block_(bob, true);
        settle(_intentFor(pickyId, 1e18, bob));
        assertEq(pool.claimable(pickyId, bob), 1e18, "not credited");

        picky.block_(bob, false);
        vm.prank(bob);
        pool.claim(pickyId, bob);

        assertEq(picky.balanceOf(bob), 1e18, "the claim did not deliver");
        assertEq(pool.claimable(pickyId, bob), 0, "still owed after paying");
    }

    /// A token with no return value deposits through SafeERC20 and is paid out by push.
    function test_aTokenWithNoReturnValueWorks() public {
        _deposit(noretId, 1e18);
        assertEq(pool.totalShielded(noretId), _net(1e18), "recorded by balance difference");
        uint256[] memory w = _intentFor(noretId, 1e17, bob);
        settle(w);
        assertEq(noret.balanceOf(bob), 1e17, "and it pays out");
    }

    /// An amount above the Goldilocks bound is refused whatever the token's decimals.
    function test_anAmountAboveTheFieldBoundIsRefusedWhateverTheDecimals() public {
        assertEq(noret.decimals(), 36, "the token claims 36 decimals");
        vm.prank(alice);
        vm.expectRevert(ShieldedPool.InvalidAmount.selector);
        pool.absorb(noretId, 1e30, fresh());
        _deposit(noretId, 1e18); // and below the bound it behaves
        assertEq(pool.totalShielded(noretId), _net(1e18), "usable below the bound");
    }

    /// No hostile token moves another asset's escrow, and native still pays out afterwards.
    function test_noHostileTokenCanReachAnotherAssetsEscrow() public {
        (, uint256 nativeValue) = depositNative(alice, 5 ether);
        uint256 nativeBefore = pool.totalShielded(0);
        uint256 usdBefore = pool.totalShielded(usdAssetId);

        _deposit(rebaseId, 1e18);
        rebase.setFactorBps(1_000_000);
        _deposit(pickyId, 1e18);
        picky.block_(address(pool), false);
        hook.arm(address(pool), abi.encodeCall(pool.betaRefund, (0, alice)));
        _deposit(hookId, 1e18);

        assertEq(pool.totalShielded(0), nativeBefore, "native escrow untouched");
        assertEq(pool.totalShielded(usdAssetId), usdBefore, "usd escrow untouched");

        uint256 outAmt = nativeValue / 2;
        uint256 before = bob.balance;
        settle(singleIntent(outAmt, 0, bob));
        assertEq(bob.balance - before, outAmt, "and native still pays out in full");
    }

    /// the value a deposit of `amount` leaves in the pool, after the shield fee.
    function _net(uint256 amount) internal view returns (uint256) {
        return amount - (amount * uint256(SHIELD_FEE_BPS)) / 10_000;
    }

    function _intentFor(uint64 assetId, uint256 amount, address to) internal returns (uint256[] memory w) {
        TIntent[] memory intents = new TIntent[](1);
        intents[0] = newIntent(amount, 0, to, assetId);
        w = encodeBatch(pool.currentRoot(), assocRoot, 0, intents);
    }

    function _nullifiers(uint256[] memory w) internal pure returns (uint256 nf0, uint256 nf1) {
        nf0 = w[2];
        nf1 = w[3];
    }
}
