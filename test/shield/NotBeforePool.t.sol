// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase} from "./ShieldTestBase.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";
import {AmountPolicy} from "../../contracts/shield/AmountPolicy.sol";
import {IStarkVerifier} from "../../contracts/shield/interfaces/IStarkVerifier.sol";
import {IPoseidonGoldilocks} from "../../contracts/shield/interfaces/IPoseidonGoldilocks.sol";

/// @notice The pool with the not-before statement and the real fee schedule, on a mock verifier:
///         13 words per intent, 0.50% on deposits and withdrawals, a flat protocol fee on private
///         transfers, the four-rung gas ladder, and the fee split between the router and whoever
///         submits. Every figure is the Sepolia deployment's.
contract NotBeforePoolTest is ShieldTestBase {
    uint256 internal constant WORDS = 13;
    uint256 internal constant GRID = 600;
    uint64 internal constant PROTOCOL = 5e14;
    uint64 internal constant RUNG0 = 2.5e15;
    address internal constant SUBMITTER = address(1);

    uint256 internal notBefore;

    function _launchAmountRules() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        // the same stack as the base, rebuilt at 13 words on the real policy
        uint256[] memory stWords = new uint256[](WORDS);
        ShieldedPool.DeploymentSelfTest memory st = _selfTest();
        st.proofPublicInputs = stWords;
        pool = new ShieldedPool(
            safe,
            IStarkVerifier(address(verifier)),
            IPoseidonGoldilocks(address(hasher)),
            registry,
            address(feeRouter),
            50,
            50,
            0,
            WORDS,
            st
        );
        vm.startPrank(safe);
        pool.endBetaMode();
        AmountPolicy policy = pool.amountPolicy();
        uint64[] memory ids = new uint64[](1);
        uint8[] memory mins = new uint8[](1);
        uint8[] memory maxs = new uint8[](1);
        uint256[] memory fees = new uint256[](1);
        mins[0] = 15;
        maxs[0] = 19;
        fees[0] = 1e15;
        policy.initRanges(ids, mins, maxs, fees);
        uint64[] memory protocol = new uint64[](1);
        protocol[0] = PROTOCOL;
        uint64[4][] memory ladders = new uint64[4][](1);
        ladders[0] = [uint64(2.5e15), 5e15, 1e16, 2e16];
        policy.initSchedules(ids, protocol, ladders);
        vm.stopPrank();

        vm.warp(1_790_812_800 + 1);
        notBefore = 1_790_812_800; // on the grid, in the past
    }

    function _encode(TIntent[] memory ins, uint256 nb) internal view returns (uint256[] memory w) {
        uint256[] memory w12 = encodeBatch(pool.currentRoot(), assocRoot, 0, ins);
        uint256 n = ins.length;
        w = new uint256[](n * WORDS);
        for (uint256 i = 0; i < n; ++i) {
            for (uint256 k = 0; k < 12; ++k) {
                w[i * WORDS + k] = w12[i * 12 + k];
            }
            w[i * WORDS + 12] = nb;
        }
    }

    function _one(uint256 publicAmount, uint256 fee, address recipient, address feeRecipient, uint256 nb)
        internal
        returns (uint256[] memory)
    {
        TIntent[] memory ins = new TIntent[](1);
        ins[0] = newIntent(publicAmount, fee, recipient, 0);
        ins[0].feeRecipient = feeRecipient;
        return _encode(ins, nb);
    }

    function _settle(uint256[] memory w, address sender) internal {
        vm.prank(sender);
        pool.settleBatch(hex"70726f6f66", w, noResidual(), "", new bytes[](2 * (w.length / WORDS)));
    }

    function _deposit(uint256 amount) internal {
        vm.prank(alice);
        pool.absorb{value: amount}(0, amount, fresh());
    }

    // -- deposits ---------------------------------------------------------------------------------------

    function test_depositPaysHalfAPercent() public {
        uint256 before = address(feeRouter).balance;
        _deposit(1 ether);
        assertEq(address(feeRouter).balance - before, 0.005 ether, "the router takes 0.50%");
        assertEq(pool.totalShielded(0), 0.995 ether, "the note holds the rest");
    }

    function test_depositOutsideTheRangeIsRefused() public {
        vm.prank(alice);
        vm.expectRevert(AmountPolicy.NonStandardAmount.selector);
        pool.absorb{value: 3 ether}(0, 3 ether, fresh());
    }

    // -- private transfers ------------------------------------------------------------------------------

    function test_privateTransferSplitsTheFee() public {
        _deposit(1 ether);
        uint256 before = address(feeRouter).balance;
        _settle(_one(0, PROTOCOL + RUNG0, address(0), SUBMITTER, notBefore), relayer);
        assertEq(address(feeRouter).balance - before, PROTOCOL, "the router takes the protocol part");
        assertEq(pool.claimable(0, relayer), RUNG0, "whoever submits is credited the rung");
    }

    function test_privateTransferOffTheLadderIsRefused() public {
        _deposit(1 ether);
        uint256[] memory w = _one(0, PROTOCOL + RUNG0 + 1, address(0), SUBMITTER, notBefore);
        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.FeeNotOnLadder.selector, uint256(RUNG0 + 1)));
        _settle(w, relayer);
    }

    function test_selfSubmittedTransferPaysOnlyTheProtocolPart() public {
        _deposit(1 ether);
        uint256 before = address(feeRouter).balance;
        _settle(_one(0, PROTOCOL, address(0), address(0), notBefore), alice);
        assertEq(address(feeRouter).balance - before, PROTOCOL);
    }

    function test_selfSubmittedTransferWithAGasPartIsRefused() public {
        _deposit(1 ether);
        uint256[] memory w = _one(0, PROTOCOL + RUNG0, address(0), address(0), notBefore);
        vm.expectRevert(abi.encodeWithSelector(AmountPolicy.GasPartWithoutSubmitter.selector, uint256(RUNG0)));
        _settle(w, alice);
    }

    // -- withdrawals ------------------------------------------------------------------------------------

    function test_withdrawalPaysHalfAPercentAndARung() public {
        _deposit(1 ether);
        uint256 amount = 0.1 ether;
        uint256 pct = amount * 50 / 10_000;
        uint256 routerBefore = address(feeRouter).balance;
        uint256 bobBefore = bob.balance;
        _settle(_one(amount, pct + RUNG0, bob, SUBMITTER, notBefore), relayer);
        assertEq(bob.balance - bobBefore, amount, "the recipient gets the public amount");
        assertEq(address(feeRouter).balance - routerBefore, pct, "the router takes 0.50%");
        assertEq(pool.claimable(0, relayer), RUNG0, "whoever submits is credited the rung");
    }

    function test_withdrawalAtTheOldFlatFeeIsRefused() public {
        _deposit(1 ether);
        uint256[] memory w = _one(0.1 ether, 5e13, bob, SUBMITTER, notBefore);
        vm.expectRevert();
        _settle(w, relayer);
    }

    // -- the not-before time -------------------------------------------------------------------------------

    function test_notBeforeOffTheGridIsRefused() public {
        _deposit(1 ether);
        uint256[] memory w = _one(0, PROTOCOL + RUNG0, address(0), SUBMITTER, notBefore + 1);
        vm.expectRevert(abi.encodeWithSelector(ShieldedPool.NotBeforeOffGrid.selector, notBefore + 1));
        _settle(w, relayer);
    }

    function test_notBeforeZeroIsRefused() public {
        _deposit(1 ether);
        uint256[] memory w = _one(0, PROTOCOL + RUNG0, address(0), SUBMITTER, 0);
        vm.expectRevert(abi.encodeWithSelector(ShieldedPool.NotBeforeOffGrid.selector, uint256(0)));
        _settle(w, relayer);
    }

    function test_notBeforeInTheFutureWaits() public {
        _deposit(1 ether);
        uint256 later = notBefore + 2 * GRID;
        uint256[] memory w = _one(0, PROTOCOL + RUNG0, address(0), SUBMITTER, later);
        vm.expectRevert(abi.encodeWithSelector(ShieldedPool.NotYet.selector, later));
        _settle(w, relayer);
        vm.warp(later);
        _settle(w, relayer);
        assertEq(pool.claimable(0, relayer), RUNG0);
    }

    /// Any fee: accepted if and only if it is the protocol part plus one rung.
    function testFuzz_onlyTheLadderSettles(uint256 fee) public {
        fee = bound(fee, 0, 3e16);
        _deposit(1 ether);
        uint256[] memory w = _one(0, fee, address(0), SUBMITTER, notBefore);
        bool onLadder = fee == PROTOCOL + 2.5e15 || fee == PROTOCOL + 5e15 || fee == PROTOCOL + 1e16
            || fee == PROTOCOL + 2e16;
        vm.prank(relayer);
        try pool.settleBatch(hex"70726f6f66", w, noResidual(), "", new bytes[](2)) {
            assertTrue(onLadder, "settled off the ladder");
        } catch {
            assertFalse(onLadder, "refused a rung");
        }
    }
}
