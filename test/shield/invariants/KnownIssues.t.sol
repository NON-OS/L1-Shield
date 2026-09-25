// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ShieldedPool} from "../../../contracts/shield/ShieldedPool.sol";
import {AssociationSetRegistry} from "../../../contracts/shield/AssociationSetRegistry.sol";
import {Goldilocks} from "../../../contracts/shield/libraries/Goldilocks.sol";
import {MockPoseidonGoldilocks} from "../mocks/MockPoseidonGoldilocks.sol";

import {PoolDeploy, HandlerVerifier, ModelIntent, IntentWords} from "./PoolHandler.sol";

/// An ERC-20 that behaves until told otherwise, then answers `transfer` in one of the ways a
/// hostile contract can. Deposits go through `transferFrom`, which stays honest, so the attacker
/// can hold a real note in the asset before turning the token.
contract HostileToken is ERC20 {
    enum Mode {
        Honest,
        BurnAllGas, // consumes every unit of gas the caller forwards
        ReturnDataBomb, // returns as much data as the forwarded gas can pay for
        ShortReturn, // returns between 1 and 31 bytes
        NonBoolWord // returns one 32-byte word that is neither 0 nor 1
    }

    Mode public mode;
    uint256 public shortLen;

    constructor() ERC20("Hostile", "HST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function turn(Mode m, uint256 len) external {
        mode = m;
        shortLen = len;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        Mode m = mode;
        if (m == Mode.Honest) return super.transfer(to, value);
        if (m == Mode.BurnAllGas) {
            assembly {
                invalid()
            }
        }
        if (m == Mode.ReturnDataBomb) {
            // memory for w words costs 3w + w^2/512. Spend about nine tenths of the gas left on it.
            uint256 words = Math.sqrt((gasleft() * 9 / 10) * 512);
            assembly {
                return(0, mul(words, 32))
            }
        }
        _transfer(msg.sender, to, value);
        if (m == Mode.ShortReturn) {
            uint256 len = shortLen;
            assembly {
                mstore(0, shl(248, 1))
                return(0, len)
            }
        }
        assembly {
            mstore(0, 2)
            return(0, 32)
        }
    }
}

/// Hostile-token and beta-refund cases. Each test states the behaviour the pool must have.
contract KnownIssues is PoolDeploy {
    ShieldedPool internal pool;
    HandlerVerifier internal verifier;
    HostileToken internal hostile;
    uint64 internal hostileId;
    bytes32 internal assoc = bytes32(uint256(0xA55C));

    address internal safe = makeAddr("safe");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");
    address internal feeSink = makeAddr("feeSink");

    uint256 internal digestCounter;
    uint256 internal attackerBalanceBeforeSettle;

    /// A settler's transaction budget: one 30M-gas block.
    uint256 internal constant SETTLE_GAS = 30_000_000;

    function setUp() public {
        MockPoseidonGoldilocks hasher = new MockPoseidonGoldilocks();
        verifier = new HandlerVerifier();
        AssociationSetRegistry registry = new AssociationSetRegistry();
        registry.publishRoot(assoc, "");
        pool = _deployPool(safe, verifier, hasher, registry, feeSink);

        // a token that behaves at listing and turns later, as an upgradeable or pausable token can
        hostile = new HostileToken();
        hostileId = _registerAsset(pool, safe, address(hostile), 1);

        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        hostile.mint(attacker, 1e24);
        vm.prank(attacker);
        hostile.approve(address(pool), type(uint256).max);
    }

    function _publicPool() internal {
        vm.prank(safe);
        pool.endBetaMode();
    }

    // ------------------------------------------------------------------ hostile token

    /// Alice shields native value, the attacker shields its own token. Both then unshield in one
    /// batch, alice first. `feeOnHostileLeg` decides whether the hostile intent pays a fee, which
    /// puts a second hostile call in the batch through _payFee.
    function _mixedBatch(bool feeOnHostileLeg) internal returns (uint256[] memory w, bytes32 aliceNf) {
        _publicPool();
        vm.prank(alice);
        pool.absorb{value: 10 ether}(0, 10 ether, _digest());
        vm.prank(attacker);
        pool.absorb(hostileId, 1e18, _digest());
        pool.commitRoot();

        ModelIntent[] memory its = new ModelIntent[](2);
        its[0] = _intent(0, 1 ether, 0, alice);
        its[1] = _intent(hostileId, 1e17, feeOnHostileLeg ? 1e14 : 0, attacker);
        aliceNf = its[0].nf0;
        w = IntentWords.encode(its);
    }

    /// One recipient's token cannot void the other proven intents in its batch. A token that
    /// misbehaves inside `transfer` ends as a credit or a held fee, with alice paid and every
    /// nullifier spent.
    function _expectBatchSurvives(uint256[] memory w, bytes32 aliceNf) internal {
        uint256 aliceBefore = alice.balance;
        attackerBalanceBeforeSettle = hostile.balanceOf(attacker);
        (bool ok,) = address(pool).call{gas: SETTLE_GAS}(
            abi.encodeCall(ShieldedPool.settleBatch, (hex"00", w, _noResidual(), "", new bytes[](4)))
        );
        assertTrue(ok, "a hostile token reverted the whole batch");
        assertTrue(pool.nullifierSpent(aliceNf), "alice's intent did not settle");
        assertEq(alice.balance - aliceBefore, 1 ether, "alice was not paid");
    }

    /// The hostile leg is paid once: what the token delivered plus what the pool credited for
    /// `claim` equals the payout, and a refused fee is held for the router.
    function _expectHostileLegHeld(uint256 payout, uint256 fee) internal view {
        uint256 delivered = hostile.balanceOf(attacker) - attackerBalanceBeforeSettle;
        assertEq(delivered + pool.claimable(hostileId, attacker), payout, "the payout was not made exactly once");
        assertEq(pool.unsweptFees(hostileId), fee, "the refused fee was not held");
    }

    /// The pool holds at least what it owes in the token.
    function _expectSolventIn(uint64 id, ERC20 token) internal view {
        assertGe(
            token.balanceOf(address(pool)),
            pool.totalShielded(id) + pool.totalClaimable(id) + pool.unsweptFees(id),
            "the pool holds less of the token than it owes"
        );
    }

    /// `transfer` executes INVALID and burns all the gas it is forwarded, on both the recipient
    /// leg and the fee leg. The pool forwards a fixed gas amount per token call, so the batch settles.
    function test_knownIssue_hostileTokenVoidsBatch_burnsAllGas() public {
        (uint256[] memory w, bytes32 nf) = _mixedBatch(true);
        hostile.turn(HostileToken.Mode.BurnAllGas, 0);
        _expectBatchSurvives(w, nf);
        _expectHostileLegHeld(1e17, 1e14);
    }

    /// Control: one gas-burning call with no fee leg settles inside a 30M budget.
    function test_control_oneGasBurningCallAloneFitsA30MBudget() public {
        (uint256[] memory w, bytes32 nf) = _mixedBatch(false);
        hostile.turn(HostileToken.Mode.BurnAllGas, 0);
        _expectBatchSurvives(w, nf);
    }

    /// `transfer` returns as many bytes as its forwarded gas can pay for. The pool copies at most
    /// one word of return data, so the size costs it nothing.
    function test_knownIssue_hostileTokenVoidsBatch_returnDataBomb() public {
        (uint256[] memory w, bytes32 nf) = _mixedBatch(false);
        hostile.turn(HostileToken.Mode.ReturnDataBomb, 0);
        _expectBatchSurvives(w, nf);
        _expectHostileLegHeld(1e17, 0);
    }

    /// `transfer` moves the tokens and returns 1 to 31 bytes. The pool reads a short return as a
    /// failed call and the batch settles. Fuzzed over every length in the range.
    function test_knownIssue_hostileTokenVoidsBatch_shortReturn(uint8 len) public {
        len = uint8(bound(len, 1, 31));
        (uint256[] memory w, bytes32 nf) = _mixedBatch(false);
        hostile.turn(HostileToken.Mode.ShortReturn, len);
        _expectBatchSurvives(w, nf);
        _expectHostileLegHeld(1e17, 0);
    }

    /// `transfer` returns the word 2. The pool compares the word to 1 and treats it as a failure.
    function test_knownIssue_hostileTokenVoidsBatch_nonBoolWord() public {
        (uint256[] memory w, bytes32 nf) = _mixedBatch(false);
        hostile.turn(HostileToken.Mode.NonBoolWord, 0);
        _expectBatchSurvives(w, nf);
        _expectHostileLegHeld(1e17, 0);
    }

    /// A payout is made once. A token that moves the tokens and then returns one byte counts as a
    /// failed transfer. The pool measures its own balance and credits only what did not arrive.
    function test_knownIssue_aTokenThatDeliversThenAnswersBadlyIsPaidTwice() public {
        (uint256[] memory w, bytes32 nf) = _mixedBatch(false);
        hostile.turn(HostileToken.Mode.ShortReturn, 1);
        uint256 attackerBefore = hostile.balanceOf(attacker);
        _expectBatchSurvives(w, nf);
        uint256 delivered = hostile.balanceOf(attacker) - attackerBefore;
        uint256 credited = pool.claimable(hostileId, attacker);
        assertEq(delivered + credited, 1e17, "the recipient was paid more than the payout");
        _expectSolventIn(hostileId, hostile);
    }

    /// Control: the same batch with the token still honest settles, so the failures above come
    /// from the token's answer and nothing else.
    function test_control_honestTokenBatchSettles() public {
        (uint256[] memory w, bytes32 nf) = _mixedBatch(true);
        _expectBatchSurvives(w, nf);
    }

    // ------------------------------------------------------------------ beta refund after unshield

    /// The nullifier does not name the note, so a depositor who unshields their own note and then
    /// asks for a refund still takes a pro-rata share. That share dilutes the others. It never
    /// overdraws the pool, and the last depositor to ask is paid.
    function test_betaRefundAfterUnshieldDilutesButNeverOverdraws() public {
        vm.startPrank(safe);
        pool.setBetaDepositor(alice, true);
        pool.setBetaDepositor(bob, true);
        pool.setBetaCaps(0, 1_000 ether, 1_000 ether);
        vm.stopPrank();

        vm.prank(alice);
        pool.absorb{value: 10 ether}(0, 10 ether, _digest());
        vm.prank(bob);
        pool.absorb{value: 10 ether}(0, 10 ether, _digest());
        pool.commitRoot();
        uint256 aliceValue = pool.betaRefundable(0, alice);

        // alice spends her own note: an honest unshield of its full value, back to herself
        ModelIntent[] memory its = new ModelIntent[](1);
        its[0] = _intent(0, aliceValue, 0, alice);
        pool.settleBatch(hex"00", IntentWords.encode(its), _noResidual(), "", new bytes[](2));

        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        try pool.betaRefund(0, alice) {} catch {}
        uint256 aliceRefund = alice.balance - aliceBefore;

        uint256 bobValue = pool.betaRefundable(0, bob);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        (bool ok,) = address(pool).call(abi.encodeCall(ShieldedPool.betaRefund, (0, bob)));
        uint256 bobRefund = bob.balance - bobBefore;
        assertTrue(ok, "the last refund failed: the pool was overdrawn");
        assertLe(aliceRefund + bobRefund, bobValue, "refunds exceeded what the notes held");
        assertLt(bobRefund, bobValue, "the double dip did not dilute: it came from somewhere else");
        assertGt(bobRefund, 0, "bob was left with nothing");
        assertGe(
            address(pool).balance, pool.totalShielded(0) + pool.totalClaimable(0) + pool.unsweptFees(0), "insolvent"
        );
    }

    // ------------------------------------------------------------------ helpers

    function _intent(uint64 asset, uint256 pub, uint256 fee, address to) internal returns (ModelIntent memory it) {
        it.noteRoot = pool.currentRoot();
        it.assocRoot = assoc;
        it.nf0 = _digest();
        it.nf1 = _digest();
        it.outCm0 = _digest();
        it.outCm1 = _digest();
        it.publicAmount = pub;
        it.fee = fee;
        it.assetId = asset;
        it.recipient = to;
    }

    function _noResidual() internal pure returns (ShieldedPool.ResidualExec memory r) {
        r.path = new address[](0);
    }

    function _digest() internal returns (bytes32) {
        uint256 v = uint256(keccak256(abi.encode("known-issue", ++digestCounter)));
        uint256 acc;
        for (uint256 i = 0; i < 4; ++i) {
            acc |= (((v >> (64 * i)) & 0xFFFFFFFFFFFFFFFF) % Goldilocks.P) << (64 * i);
        }
        return bytes32(acc);
    }
}
