// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldTestBase} from "./ShieldTestBase.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";

/// One empty client-data blob per settlement output.
function _blobs(uint256 n) pure returns (bytes[] memory b) {
    b = new bytes[](n);
}

/// One blob per output: two outputs and twelve public words per intent.
function _blobsFor(uint256[] memory publicWords) pure returns (bytes[] memory) {
    return _blobs(2 * (publicWords.length / 12));
}


/// @dev A recipient that rejects native value, to exercise the payout failure path.
contract RejectEther {
    receive() external payable {
        revert("no");
    }
}

/// @notice ShieldedPool reject paths: decode ranges, recipients, empty timelocks, payouts and fee caps.
contract ShieldedPoolRejectTest is ShieldTestBase {
    uint256 internal constant TWO64 = 1 << 64;
    uint256 internal constant P = 0xFFFFFFFF00000001; // MAX_VALUE is P - 2
    uint256 internal constant TWO160 = 1 << 160;

    /// A public amount above MAX_VALUE is refused, starting at p - 1.
    function test_reject_PublicAmountOutOfRange() public {
        uint256[] memory w = singleIntent(0, 0, alice);
        w[6] = P - 1;
        vm.expectRevert(ShieldedPool.AmountOutOfRange.selector);
        settle(w);
    }

    /// A fee word above MAX_VALUE is refused before the fee cap is checked, starting at p - 1.
    function test_reject_FeeOutOfRange() public {
        uint256[] memory w = singleIntent(0, 0, alice);
        w[7] = P - 1;
        vm.expectRevert(ShieldedPool.FeeOutOfRange.selector);
        settle(w);
    }

    /// A public amount of MAX_VALUE passes the range check and fails only on backing.
    function test_aPublicAmountAtMaxValuePassesTheRangeCheck() public {
        uint256[] memory w = singleIntent(P - 2, 0, alice);
        vm.expectRevert(ShieldedPool.ShieldedBalanceUnderflow.selector);
        settle(w);
    }

    /// A fee of MAX_VALUE passes the range check and meets the fee cap instead.
    function test_aFeeAtMaxValuePassesTheRangeCheck() public {
        uint256[] memory w = singleIntent(P - 2, P - 2, alice);
        vm.expectRevert(ShieldedPool.FeeExceedsCap.selector);
        settle(w);
    }

    /// Words at 2^64 are refused.
    function test_reject_AmountAndFeeAtTwoToThe64() public {
        uint256[] memory w = singleIntent(0, 0, alice);
        w[6] = TWO64;
        vm.expectRevert(ShieldedPool.AmountOutOfRange.selector);
        settle(w);
        w[6] = 1 ether;
        w[7] = TWO64;
        vm.expectRevert(ShieldedPool.FeeOutOfRange.selector);
        settle(w);
    }

    /// The pool itself refuses a clearing price at or above p.
    function test_reject_ClearingPriceAtOrAboveP() public {
        TIntent[] memory ins = new TIntent[](1);
        ins[0] = newIntent(0, 0, address(0), 0);
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, P, ins);
        vm.expectRevert(ShieldedPool.PriceOutOfRange.selector);
        settle(w);
        w[9] = type(uint256).max;
        vm.expectRevert(ShieldedPool.PriceOutOfRange.selector);
        settle(w);
    }

    /// p - 1 is the largest clearing price the pool accepts.
    function test_aClearingPriceOfPMinusOneIsAccepted() public {
        TIntent[] memory ins = new TIntent[](1);
        ins[0] = newIntent(0, 0, address(0), 0);
        settle(encodeBatch(pool.currentRoot(), assocRoot, P - 1, ins));
    }

    /// An asset_id word above uint64 is refused as an unknown asset.
    function test_reject_AssetIdWordAboveU64() public {
        uint256[] memory w = singleIntent(0, 0, alice);
        w[8] = TWO64 + 1;
        vm.expectRevert(ShieldedPool.UnknownAsset.selector);
        settle(w);
    }

    /// An in-range asset id that was never registered is refused.
    function test_reject_UnregisteredAssetInIntent() public {
        uint256[] memory w = singleIntent(0, 0, alice);
        w[8] = 99;
        vm.expectRevert(ShieldedPool.UnknownAsset.selector);
        settle(w);
    }

    /// A recipient word wider than 160 bits is refused.
    function test_reject_RecipientWordNotAnAddress() public {
        uint256[] memory w = singleIntent(0, 0, alice);
        w[10] = TWO160 + 1;
        vm.expectRevert(ShieldedPool.NotAnAddress.selector);
        settle(w);
    }

    /// An unshield with a zero recipient is refused.
    function test_reject_UnshieldRequiresRecipient() public {
        uint256[] memory w = singleIntent(100, 0, address(0));
        vm.expectRevert(ShieldedPool.RecipientRequired.selector);
        settle(w);
    }

    function test_reject_ExecuteFeeRouterChangeNoPending() public {
        vm.expectRevert(ShieldedPool.NoPendingChange.selector);
        pool.executeFeeRouterChange();
    }

    function test_reject_ExecuteRouterApprovalNoPending() public {
        vm.expectRevert(ShieldedPool.NoPendingChange.selector);
        pool.executeRouterApproval(makeAddr("someRouter"));
    }

    /// A recipient that rejects native value is credited, and its own failed claim keeps the credit.
    function test_reject_RejectingRecipientIsCreditedNotReverted() public {
        (, uint256 value) = depositNative(alice, 1 ether);
        RejectEther bad = new RejectEther();
        uint256[] memory w = singleIntent(value, 0, address(bad));

        settle(w);
        assertEq(pool.claimable(0, address(bad)), value, "the refused payout was not credited");

        vm.prank(address(bad));
        vm.expectRevert(ShieldedPool.NativeTransferFailed.selector);
        pool.claim(0, address(bad));
        assertEq(pool.claimable(0, address(bad)), value, "a failed claim ate the credit");
    }

    /// An ERC-20 deposit that also sends native value is refused.
    function test_reject_Erc20DepositWithMsgValue() public {
        vm.prank(alice);
        vm.expectRevert(ShieldedPool.WrongMsgValue.selector);
        pool.absorb{value: 1}(usdAssetId, 1e18, fresh());
    }

    /// An unshieldFeeBps above MAX_FEE_BPS (50) is refused.
    function test_reject_UnshieldFeeBpsAboveCap() public {
        vm.prank(safe);
        vm.expectRevert(ShieldedPool.FeeBpsTooHigh.selector);
        pool.setFeeBps(25, 51);
    }

    /// A transfer that carries a fee is refused while the asset's relay fee cap is the default 0.
    function test_reject_TransferWithFee() public {
        TIntent[] memory ins = new TIntent[](1);
        ins[0] = newIntent(0, 1, address(0), 0);
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 0, ins);
        vm.expectRevert(ShieldedPool.FeeExceedsCap.selector);
        pool.settleBatch(hex"70726f6f66", w, noResidual(), "", _blobsFor(w));
    }

    /// A zero-amount intent with a clearing price is a private swap and settles. The circuit
    /// binds the price as a boundary constant.
    function test_aZeroAmountIntentMayCarryAClearingPrice() public {
        TIntent[] memory ins = new TIntent[](1);
        ins[0] = newIntent(0, 0, address(0), 0);
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 1e18, ins);
        pool.settleBatch(hex"70726f6f66", w, noResidual(), "", _blobsFor(w));
    }

    /// A transfer that names a recipient is refused.
    function test_reject_TransferWithRecipient() public {
        TIntent[] memory ins = new TIntent[](1);
        ins[0] = newIntent(0, 0, alice, 0);
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 0, ins);
        vm.expectRevert(ShieldedPool.NoPublicLegFieldsSet.selector);
        pool.settleBatch(hex"70726f6f66", w, noResidual(), "", _blobsFor(w));
    }

    /// A transfer recipient is refused before the verifier runs.
    function test_transferSettleFieldsRefusedBeforeTheVerifierRuns() public {
        TIntent[] memory ins = new TIntent[](1);
        ins[0] = newIntent(0, 0, alice, 0);
        uint256[] memory w = encodeBatch(pool.currentRoot(), assocRoot, 0, ins);
        // The decode guard runs in the intent loop, before verifyBatch is called.
        vm.expectRevert(ShieldedPool.NoPublicLegFieldsSet.selector);
        pool.settleBatch(hex"00", w, noResidual(), "", _blobsFor(w));
    }

    /// A transfer with no settle fields passes the decode guard and settles.
    function test_aCleanTransferStillDecodes() public {
        uint256[] memory w = singleTransfer();
        pool.settleBatch(hex"70726f6f66", w, noResidual(), "", _blobsFor(w));
    }


}
