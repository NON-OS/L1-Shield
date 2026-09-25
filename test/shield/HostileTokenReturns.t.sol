// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase} from "./ShieldTestBase.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";

/// Deposits like a normal token. On `transfer` it misbehaves in the way `mode` names. A mode that
/// moves nothing leaves a refusal the pool must credit.
contract ShapeShiftingERC20 {
    enum Mode {
        Normal,
        GasBomb, // spins until the forwarded gas is gone
        DataBomb, // returns 100,000 bytes
        Short, // returns `shortLen` bytes, 1 to 31
        False, // returns abi-encoded false
        NotABool, // returns one word equal to 2
        TwoWords, // returns true followed by a second word
        Reverts,
        Hungry, // needs more than the pool's cap, then transfers normally
        DeliverThenShort, // moves the funds, then returns one byte
        HalfThenFalse, // moves half, then returns false
        DeliverThenFalseUnreadable // moves the funds, returns false, and balanceOf reverts
    }

    mapping(address => uint256) internal bal;
    mapping(address => mapping(address => uint256)) public allowance;
    Mode public mode;
    uint256 public shortLen;
    bool internal unreadable;

    function balanceOf(address a) external view returns (uint256) {
        require(!unreadable, "unreadable");
        return bal[a];
    }

    function set(Mode m, uint256 len) external {
        mode = m;
        shortLen = len;
    }

    function mint(address to, uint256 a) external {
        bal[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        bal[f] -= a;
        bal[to] += a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        Mode m = mode;
        if (m == Mode.Normal) return _move(to, a);
        if (m == Mode.Hungry) {
            uint256 stop = gasleft() > 150_000 ? gasleft() - 150_000 : 0;
            while (gasleft() > stop) {}
            return _move(to, a);
        }
        if (m == Mode.GasBomb) {
            while (true) {}
        }
        if (m == Mode.Reverts) revert("no");
        if (m == Mode.DeliverThenShort) {
            _move(to, a);
            assembly {
                mstore(0, shl(248, 1))
                return(0, 1)
            }
        }
        if (m == Mode.HalfThenFalse) {
            _move(to, a / 2);
            return false;
        }
        if (m == Mode.DeliverThenFalseUnreadable) {
            _move(to, a);
            unreadable = true;
            return false;
        }
        uint256 len;
        uint256 word;
        if (m == Mode.DataBomb) {
            len = 100_000;
            word = 1;
        } else if (m == Mode.Short) {
            len = shortLen;
            word = type(uint256).max;
        } else if (m == Mode.False) {
            len = 32;
        } else if (m == Mode.NotABool) {
            len = 32;
            word = 2;
        } else {
            len = 64;
            word = 1;
        }
        assembly {
            mstore(0, word)
            return(0, len)
        }
    }

    function _move(address to, uint256 a) private returns (bool) {
        bal[msg.sender] -= a;
        bal[to] += a;
        return true;
    }
}

/// The pool's token pushes are gas-capped, copy at most one word of return data, and treat
/// anything but no data or `true` as a refusal that credits. A hostile token can then cost its
/// own intents a push, never the batch.
contract HostileTokenReturnsTest is ShieldTestBase {
    ShapeShiftingERC20 internal tok;
    uint64 internal tokId;
    address internal carol = makeAddr("carol");

    uint256 internal constant PAY = 1e18;

    function setUp() public override {
        super.setUp();
        tok = new ShapeShiftingERC20();
        tokId = registerToken(address(tok));
        tok.mint(alice, 1e24);
        vm.startPrank(alice);
        tok.approve(address(pool), type(uint256).max);
        pool.absorb(tokId, 10e18, fresh());
        vm.stopPrank();
        depositNative(alice, 10 ether);
    }

    /// One intent on the hostile token paying bob, with a protocol fee, and one native intent
    /// paying carol, in the same batch.
    function _mixedBatch() internal returns (uint256[] memory) {
        TIntent[] memory ins = new TIntent[](2);
        ins[0] = newIntent(PAY, PAY / 200, bob, tokId);
        ins[1] = newIntent(1 ether, 0, carol, 0);
        return encodeBatch(pool.currentRoot(), assocRoot, 0, ins);
    }

    function _assertCredited(string memory what) internal view {
        assertEq(carol.balance, 1 ether, string.concat(what, ": the native intent was not paid"));
        assertEq(tok.balanceOf(bob), 0, string.concat(what, ": bob was paid by a refusing token"));
        assertEq(pool.claimable(tokId, bob), PAY, string.concat(what, ": bob's payout was not credited"));
        assertEq(pool.unsweptFees(tokId), PAY / 200, string.concat(what, ": the fee was not held"));
        assertEq(
            tok.balanceOf(address(pool)),
            pool.totalShielded(tokId) + pool.totalClaimable(tokId) + pool.unsweptFees(tokId),
            string.concat(what, ": the pool does not cover what it owes")
        );
    }

    function _settleIn(ShapeShiftingERC20.Mode m, uint256 len) internal {
        tok.set(m, len);
        settle(_mixedBatch());
    }

    function test_aGasBombIsCappedAndCredited() public {
        uint256[] memory w = _mixedBatch();
        tok.set(ShapeShiftingERC20.Mode.GasBomb, 0);
        uint256 before = gasleft();
        settle(w);
        uint256 used = before - gasleft();
        _assertCredited("gas bomb");
        // two capped pushes at 100,000 each, plus the settlement itself
        assertLt(used, 1_000_000, "the token burned more than the cap allows");
    }

    function test_aDataBombIsNotCopiedAndIsCredited() public {
        uint256[] memory w = _mixedBatch();
        tok.set(ShapeShiftingERC20.Mode.DataBomb, 0);
        uint256 before = gasleft();
        settle(w);
        uint256 used = before - gasleft();
        _assertCredited("data bomb");
        assertLt(used, 1_000_000, "the return data was copied");
    }

    /// Every return length from 1 to 31 bytes is a refusal, never a revert.
    function test_everyShortReturnFromOneToThirtyOneBytesIsCredited() public {
        for (uint256 len = 1; len <= 31; ++len) {
            uint256 owedBefore = pool.claimable(tokId, bob);
            uint256 heldBefore = pool.unsweptFees(tokId);
            tok.set(ShapeShiftingERC20.Mode.Short, len);
            TIntent[] memory ins = new TIntent[](1);
            ins[0] = newIntent(PAY / 100, PAY / 20_000, bob, tokId);
            settle(encodeBatch(pool.currentRoot(), assocRoot, 0, ins));
            assertEq(pool.claimable(tokId, bob) - owedBefore, PAY / 100, "short return not credited");
            assertEq(pool.unsweptFees(tokId) - heldBefore, PAY / 20_000, "short return fee not held");
        }
        assertEq(tok.balanceOf(bob), 0);
    }

    function test_falseIsCredited() public {
        _settleIn(ShapeShiftingERC20.Mode.False, 0);
        _assertCredited("false");
    }

    function test_aWordThatIsNotABoolIsCredited() public {
        _settleIn(ShapeShiftingERC20.Mode.NotABool, 0);
        _assertCredited("not a bool");
    }

    function test_trueFollowedByMoreDataIsCredited() public {
        _settleIn(ShapeShiftingERC20.Mode.TwoWords, 0);
        _assertCredited("two words");
    }

    function test_aRevertIsCredited() public {
        _settleIn(ShapeShiftingERC20.Mode.Reverts, 0);
        _assertCredited("revert");
    }

    /// A token that needs more gas than the cap is credited, and the uncapped claim delivers.
    function test_aHungryTokenIsCreditedThenClaimedWithoutTheCap() public {
        uint256 routerBefore = tok.balanceOf(address(feeRouter));
        _settleIn(ShapeShiftingERC20.Mode.Hungry, 0);
        _assertCredited("hungry");
        vm.prank(bob);
        pool.claim(tokId, bob);
        assertEq(tok.balanceOf(bob), PAY, "the claim delivered");
        pool.sweepFees(tokId);
        assertEq(tok.balanceOf(address(feeRouter)) - routerBefore, PAY / 200, "the sweep delivered");
    }

    /// A token that delivers and then answers badly is paid once: the pool sees its own balance
    /// fall and credits nothing, for the recipient and for the router.
    function test_aTokenThatDeliversThenAnswersBadlyIsPaidOnce() public {
        uint256 routerBefore = tok.balanceOf(address(feeRouter));
        _settleIn(ShapeShiftingERC20.Mode.DeliverThenShort, 0);
        assertEq(tok.balanceOf(bob), PAY, "bob was paid by the transfer");
        assertEq(pool.claimable(tokId, bob), 0, "and not credited a second time");
        assertEq(tok.balanceOf(address(feeRouter)) - routerBefore, PAY / 200, "the router was paid");
        assertEq(pool.unsweptFees(tokId), 0, "and its fee is not held a second time");
        assertEq(carol.balance, 1 ether, "the native intent was paid");
    }

    /// A partial delivery is credited only for the part that did not leave the pool.
    function test_aPartialDeliveryCreditsOnlyTheShortfall() public {
        _settleIn(ShapeShiftingERC20.Mode.HalfThenFalse, 0);
        assertEq(tok.balanceOf(bob), PAY / 2, "half arrived");
        assertEq(pool.claimable(tokId, bob), PAY - PAY / 2, "the other half is owed");
        assertEq(
            tok.balanceOf(address(pool)),
            pool.totalShielded(tokId) + pool.totalClaimable(tokId) + pool.unsweptFees(tokId),
            "the pool covers exactly what it owes"
        );
    }

    /// When the pool cannot read its balance after a refused push, it credits in full, so the
    /// recipient is never left unpaid. The cost falls on the token's own escrow.
    function test_anUnreadableBalanceCreditsInFull() public {
        TIntent[] memory ins = new TIntent[](1);
        ins[0] = newIntent(PAY, 0, bob, tokId);
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 0, ins);
        tok.set(ShapeShiftingERC20.Mode.DeliverThenFalseUnreadable, 0);
        settle(w);
        assertEq(pool.claimable(tokId, bob), PAY, "credited in full");
    }

    /// The same token, behaving, is paid by push and credits nothing.
    function test_aWellBehavedTokenIsPaidDirectly() public {
        uint256 routerBefore = tok.balanceOf(address(feeRouter));
        _settleIn(ShapeShiftingERC20.Mode.Normal, 0);
        assertEq(tok.balanceOf(bob), PAY, "bob paid");
        assertEq(tok.balanceOf(address(feeRouter)) - routerBefore, PAY / 200, "router paid");
        assertEq(pool.totalClaimable(tokId), 0, "nothing credited");
        assertEq(pool.unsweptFees(tokId), 0, "nothing held");
    }
}
