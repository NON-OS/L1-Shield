// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ShieldTestBase} from "./ShieldTestBase.sol";
import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// One empty client-data blob per settlement output. Empty is legal: the opening travels off-chain.
function _blobs(uint256 n) pure returns (bytes[] memory b) {
    b = new bytes[](n);
}

/// One blob per output for a batch of public words: two outputs and twelve words per intent.
function _blobsFor(uint256[] memory publicWords) pure returns (bytes[] memory) {
    return _blobs(2 * (publicWords.length / 12));
}


/// A settlement recipient that refuses native value and can claim what it is owed.
/// Drives the credit-on-refusal path and `claim`.
contract RefusingSink {
    ShieldedPool private immutable POOL;

    constructor(ShieldedPool p) {
        POOL = p;
    }

    function claimTo(uint64 assetId, address to) external {
        POOL.claim(assetId, to);
    }
    // no receive: native value bounces
}

/// Randomized action driver for the invariant suite, legal and illegal interactions alike.
contract ShieldHandler is Test {
    ShieldedPool public pool;
    address public safe;
    bytes32 public assocRoot;
    MockERC20 public usd;
    MockERC20 public nox;
    uint64 public usdAssetId;
    address public dex;
    RefusingSink public sink;

    uint256 internal seedCounter;
    bytes32[] public spentNullifiers;
    // Value ledger per asset: credited on deposit or residual in, debited on unshield, refund or
    // residual out. totalShielded == credited - debited.
    mapping(uint64 => uint256) public credited;
    mapping(uint64 => uint256) public debited;

    constructor(
        ShieldedPool pool_,
        address safe_,
        bytes32 assocRoot_,
        MockERC20 usd_,
        uint64 usdAssetId_,
        address dex_
    ) {
        pool = pool_;
        safe = safe_;
        assocRoot = assocRoot_;
        usd = usd_;
        nox = usd_; // same token twice, so a repeat listing reverts and changes nothing
        usdAssetId = usdAssetId_;
        dex = dex_;
        sink = new RefusingSink(pool_);
    }

    receive() external payable {}

    /// @dev True while this handler may settle. A settling action without permission is a no-op,
    ///      so fail_on_revert still catches unexpected reverts.
    function _canSettle() internal view returns (bool) {
        address st = pool.settler();
        return st == address(0) || st == address(this)
            || block.timestamp >= pool.lastSettlement() + pool.SETTLER_WINDOW();
    }

    function _fresh() internal returns (bytes32 out) {
        uint256 v = uint256(keccak256(abi.encode("h", ++seedCounter)));
        // Canonical: every 64-bit limb < 2^63 < p.
        out = bytes32(v & 0x7FFFFFFFFFFFFFFF7FFFFFFFFFFFFFFF7FFFFFFFFFFFFFFF7FFFFFFFFFFFFFFF);
    }

    function depositNative(uint96 amount) external {
        uint256 amt = bound(uint256(amount), 1, 1 ether);
        if (pool.depositsPaused()) return;
        vm.deal(address(this), amt);
        pool.absorb{value: amt}(0, amt, _fresh());
        credited[0] += amt - (amt * pool.shieldFeeBps()) / 10_000; // net value shielded
    }

    function privateTransferBatch(uint8 rawCount) external {
        if (!_canSettle()) return;
        if (pool.nextLeafIndex() == 0) return;
        uint256 n = bound(uint256(rawCount), 1, 4);
        uint256[] memory w = _batch(n, 0, 0, address(0), 0);
        _settle(w);
    }

    function unshieldBatch(uint96 rawAmount) external {
        if (!_canSettle()) return;
        uint256 shielded = pool.totalShielded(0);
        if (shielded < 3) return;
        uint256 outAmt = bound(uint256(rawAmount), 1, shielded / 2);
        uint256[] memory w = _batch(1, outAmt, 0, address(0xBEEF), 0);
        _settle(w);
        debited[0] += outAmt; // public_amount leaves the shielded pool
    }

    /// ERC-20 deposit of the USD asset, so multi-asset accounting is fuzzed.
    function depositErc20(uint96 amount) external {
        uint256 amt = bound(uint256(amount), 1, 1e18); // < Goldilocks.MAX_VALUE (p - 2)
        if (pool.depositsPaused()) return;
        usd.mint(address(this), amt);
        usd.approve(address(pool), amt);
        pool.absorb(usdAssetId, amt, _fresh());
        credited[usdAssetId] += amt - (amt * pool.shieldFeeBps()) / 10_000;
    }

    /// ERC-20 unshield of the USD asset to a fixed recipient, with no fee.
    function unshieldErc20(uint96 rawAmount) external {
        if (!_canSettle()) return;
        uint256 shielded = pool.totalShielded(usdAssetId);
        if (shielded < 3) return;
        uint256 outAmt = bound(uint256(rawAmount), 1, shielded / 2);
        uint256[] memory w = _batch(1, outAmt, 0, address(0xBEEF), usdAssetId);
        _settle(w);
        debited[usdAssetId] += outAmt;
    }

    /// Private swap residual: native to USD through the approved DEX at a 1:1 clearing price.
    function residualSwapNativeToUsd(uint96 rawAmount) external {
        if (!_canSettle()) return;
        if (!pool.approvedRouter(dex)) return;
        uint256 shielded = pool.totalShielded(0);
        if (shielded < 4) return;
        uint256 amountIn = bound(uint256(rawAmount), 1, shielded / 2);

        // One private-transfer intent carrying the clearing price, plus the residual.
        uint256[] memory w = new uint256[](12);
        w[0] = uint256(pool.currentRoot());
        w[1] = uint256(assocRoot);
        w[2] = uint256(_fresh());
        w[3] = uint256(_fresh());
        w[4] = uint256(_fresh());
        w[5] = uint256(_fresh());
        w[9] = 1e18; // clearingPrice (1:1)

        ShieldedPool.ResidualExec memory r;
        r.router = dex;
        r.assetIn = 0;
        r.assetOut = usdAssetId;
        r.amountIn = amountIn;
        r.amountOutMin = amountIn; // band floor at price 1e18, and the mock pays out amountIn
        r.deadline = block.timestamp + 100;
        r.path = new address[](2);
        r.path[0] = address(0x1111); // wrapped-native placeholder
        r.path[1] = address(usd);

        pool.settleBatch(hex"70", w,  r, "", _blobsFor(w));
        spentNullifiers.push(bytes32(w[2]));
        spentNullifiers.push(bytes32(w[3]));

        // Native leaves and USD enters. At rate 1:1, amountOut == amountIn.
        debited[0] += amountIn;
        credited[usdAssetId] += amountIn;
    }

    function attemptDoubleSpend(uint256 pick) external {
        if (spentNullifiers.length == 0) return;
        // the settler gate runs before the nullifier check
        if (!_canSettle()) return;
        bytes32 nf = spentNullifiers[pick % spentNullifiers.length];
        uint256[] memory w = _batch(1, 0, 0, address(0), 0);
        w[2] = uint256(nf); // replay a spent nullifier (word[2] = nf0)
        ShieldedPool.ResidualExec memory r;
        r.path = new address[](0);
        vm.expectRevert(ShieldedPool.NullifierAlreadySpent.selector);
        pool.settleBatch(hex"70", w, r, "", _blobsFor(w));
    }

    function setFees(uint16 a, uint16 b) external {
        uint16 sf = uint16(bound(uint256(a), 0, 60));
        uint16 uf = uint16(bound(uint256(b), 0, 60));
        vm.startPrank(safe);
        if (sf > pool.MAX_FEE_BPS() || uf > pool.MAX_FEE_BPS()) {
            vm.expectRevert(ShieldedPool.FeeBpsTooHigh.selector);
            pool.setFeeBps(sf, uf);
        } else {
            pool.setFeeBps(sf, uf);
        }
        vm.stopPrank();
    }

    function togglePause(bool paused) external {
        vm.prank(safe);
        pool.setDepositsPaused(paused);
    }

    function spentCount() external view returns (uint256) {
        return spentNullifiers.length;
    }

    function _batch(uint256 n, uint256 publicAmount, uint256 fee, address recipient, uint64 assetId)
        internal
        returns (uint256[] memory w)
    {
        w = new uint256[](n * 12);
        for (uint256 i = 0; i < n; ++i) {
            uint256 o = i * 12;
            w[o] = uint256(pool.currentRoot());
            w[o + 1] = uint256(assocRoot);
            w[o + 2] = uint256(_fresh()); // nf0
            w[o + 3] = uint256(_fresh()); // nf1
            w[o + 4] = uint256(_fresh()); // outCm0
            w[o + 5] = uint256(_fresh()); // outCm1
            w[o + 6] = i == 0 ? publicAmount : 0; // public_amount
            w[o + 7] = i == 0 ? fee : 0; // fee
            w[o + 8] = assetId; // asset_id
            w[o + 9] = 0; // clearingPrice (uniform)
            w[o + 10] = uint256(uint160(i == 0 ? recipient : address(0)));
        }
    }

    function _settle(uint256[] memory w) internal {
        uint256 n = w.length / 12;
        ShieldedPool.ResidualExec memory r;
        r.path = new address[](0);
        pool.settleBatch(hex"70", w,  r, "", _blobsFor(w));
        for (uint256 i = 0; i < n; ++i) {
            spentNullifiers.push(bytes32(w[i * 12 + 2]));
            spentNullifiers.push(bytes32(w[i * 12 + 3]));
        }
    }
    // Governance and beta wind-down actions.

    function betaRefundSelf(uint8 which) external {
        uint64 asset = which % 2 == 0 ? 0 : usdAssetId;
        if (!pool.betaMode()) return;
        uint256 owed = pool.betaRefundable(asset, address(this));
        if (owed == 0) return;
        pool.betaRefund(asset, address(this));
        // a refund removes value from the shielded set, like an unshield
        debited[asset] += owed;
    }

    /// Publishes the root, including when nothing has changed.
    function commitTheRoot() external {
        if (pool.nextLeafIndex() == 0) return;
        pool.commitRoot();
    }

    /// Settle a native unshield to a recipient that bounces it, so the credit path is reached.
    function unshieldToARecipientThatRefuses(uint96 rawAmount) external {
        if (!_canSettle()) return;
        uint256 shielded = pool.totalShielded(0);
        if (shielded < 3) return;
        uint256 outAmt = bound(uint256(rawAmount), 1, shielded / 2);
        uint256[] memory w = _batch(1, outAmt, 0, address(sink), 0);
        _settle(w);
        debited[0] += outAmt;
    }

    /// Claims a payout the recipient refused.
    function claimAPayout() external {
        if (pool.claimable(0, address(sink)) == 0) return;
        try sink.claimTo(0, address(0xBEEF)) {} catch {}
    }

    /// Sweeps fees the router refused. The sweep is permissionless, so the caller is not pranked.
    function sweepTheFees(bool native) external {
        uint64 a = native ? 0 : usdAssetId;
        if (pool.unsweptFees(a) == 0) return;
        try pool.sweepFees(a) {} catch {}
    }

    /// An asset listing moves neither the leaf count nor the root.
    /// Asserted per call, since other actions move the leaf count.
    function listAnAsset(uint8 pick) external {
        address token = pick % 2 == 0 ? address(usd) : address(nox);
        uint40 before = pool.nextLeafIndex();
        bytes32 rootBefore = pool.currentRoot();
        vm.prank(safe);
        try pool.registerAsset(token, 1) {} catch {}
        require(pool.nextLeafIndex() == before, "a listing moved the leaf count");
        require(pool.currentRoot() == rootBefore, "a listing moved the root");
    }

    function setAttestation(address v) external {
        vm.prank(safe);
        try pool.setAttestationVerifier(v) {} catch {}
    }

    function toggleBetaPause(bool on) external {
        if (pool.betaWoundDown() && !on) return; // one-way once wind-down starts
        vm.prank(safe);
        try pool.setBetaPaused(on) {} catch {}
    }

    function endBeta() external {
        if (!pool.betaMode() || pool.betaWoundDown()) return;
        vm.prank(safe);
        try pool.endBetaMode() {} catch {}
    }

    function setCaps(uint96 addrCap, uint96 totalCap) external {
        vm.prank(safe);
        try pool.setBetaCaps(0, uint256(addrCap), uint256(totalCap)) {} catch {}
    }

    function setDepositor(address who, bool ok) external {
        vm.prank(safe);
        try pool.setBetaDepositor(who, ok) {} catch {}
    }

    function setRegistrar(address who) external {
        vm.prank(safe);
        try pool.setDepositorRegistrar(who) {} catch {}
    }

    function setBand(uint16 bps) external {
        vm.prank(safe);
        try pool.setResidualBand(bps % 10_001) {} catch {}
    }

    function proposeAndMaybeExecuteSettler(address who, bool execute, uint32 warp) external {
        vm.prank(safe);
        try pool.proposeSettler(who) {} catch { return; }
        if (execute) {
            vm.warp(block.timestamp + bound(uint256(warp), 0, 5 days));
            try pool.executeSettlerChange() {} catch {}
        } else {
            vm.prank(safe);
            try pool.cancelSettlerChange() {} catch {}
        }
    }

    function proposeAndMaybeExecuteFeeRouter(address who, bool execute, uint32 warp) external {
        if (who == address(0)) return;
        vm.prank(safe);
        try pool.proposeFeeRouter(who) {} catch { return; }
        if (execute) {
            vm.warp(block.timestamp + bound(uint256(warp), 0, 5 days));
            try pool.executeFeeRouterChange() {} catch {}
        } else {
            vm.prank(safe);
            try pool.cancelFeeRouterChange() {} catch {}
        }
    }

    function revokeTheRouter() external {
        vm.prank(safe);
        try pool.revokeRouter(dex) {} catch {}
    }

}

/// @notice Pool invariants under random deposits, settlements, governance and replays.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 150
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: deep.invariant.runs = 1024
/// forge-config: deep.invariant.depth = 500
contract ShieldInvariantsTest is ShieldTestBase {
    ShieldHandler internal handler;

    function setUp() public override {
        super.setUp();
        // Approve and fund the DEX for the residual-swap action.
        vm.prank(safe);
        pool.proposeRouter(address(dex));
        vm.warp(block.timestamp + pool.ROUTER_DELAY());
        pool.executeRouterApproval(address(dex));
        usd.mint(address(dex), 1e24);
        vm.deal(address(dex), 100 ether);

        handler = new ShieldHandler(pool, safe, assocRoot, usd, usdAssetId, address(dex));
        targetContract(address(handler));
    }

    /// @notice The pool holds at least the shielded native total.
    function invariant_NativeSolvency() public view {
        assertGe(address(pool).balance, pool.totalShielded(0), "native: pool balance < shielded value");
    }

    function invariant_Erc20Solvency() public view {
        assertGe(usd.balanceOf(address(pool)), pool.totalShielded(usdAssetId), "erc20: pool balance < shielded value");
    }

    /// @notice The shielded total equals net value deposited minus value unshielded.
    function invariant_NativeConservation() public view {
        assertEq(pool.totalShielded(0), handler.credited(0) - handler.debited(0), "native: value not conserved");
    }

    function invariant_Erc20Conservation() public view {
        assertEq(
            pool.totalShielded(handler.usdAssetId()),
            handler.credited(handler.usdAssetId()) - handler.debited(handler.usdAssetId()),
            "erc20: value not conserved"
        );
    }

    function invariant_FeeBpsCapped() public view {
        assertLe(pool.shieldFeeBps(), pool.MAX_FEE_BPS());
        assertLe(pool.unshieldFeeBps(), pool.MAX_FEE_BPS());
    }

    function invariant_NullifiersNeverReset() public view {
        uint256 n = handler.spentCount();
        for (uint256 i = 0; i < n; ++i) {
            assertTrue(pool.nullifierSpent(handler.spentNullifiers(i)), "spent nullifier reset");
        }
    }

    function invariant_CurrentRootAlwaysKnown() public view {
        assertTrue(pool.isKnownRoot(pool.currentRoot()), "current root out of window");
    }

    function invariant_CustodyPinsUnchanged() public view {
        assertEq(address(pool.verifier()), address(verifier));
        assertEq(address(pool.treeHasher()), address(hasher));
        assertEq(address(pool.associationRegistry()), address(registry));
    }

    // Beta wind-down.

    /// @notice A refund never exceeds what the depositor put in.
    function invariant_RefundNeverExceedsDeposited() public view {
        assertLe(
            pool.betaRefundable(0, address(handler)),
            handler.credited(0),
            "refundable exceeds what was ever credited"
        );
    }

    /// @notice The wind-down is one-way: once wound down, the pool stays in beta mode.
    function invariant_WindDownIsOneWay() public view {
        if (pool.betaWoundDown()) {
            assertTrue(pool.betaMode(), "wound down implies still in beta: endBetaMode must be shut");
        }
    }

    /// @notice The refund phase and the public phase never coexist.
    function invariant_RefundAndPublicPhaseNeverCoexist() public view {
        assertFalse(!pool.betaMode() && pool.betaWoundDown(), "refundable phase overlapped the public phase");
    }

    /// @notice Refunds keep the pool solvent in both assets.
    function invariant_SolventAcrossRefunds() public view {
        assertGe(address(pool).balance, pool.totalShielded(0), "refund broke native solvency");
        assertGe(usd.balanceOf(address(pool)), pool.totalShielded(usdAssetId), "refund broke erc20 solvency");
    }

    /// Held router fees sit on top of what depositors are owed.
    function invariant_HeldFeesSitOnTopOfWhatIsOwed() public view {
        assertGe(
            address(pool).balance,
            pool.totalShielded(0) + pool.unsweptFees(0),
            "held native fees are coming out of depositor funds"
        );
        assertGe(
            usd.balanceOf(address(pool)),
            pool.totalShielded(usdAssetId) + pool.unsweptFees(usdAssetId),
            "held erc20 fees are coming out of depositor funds"
        );
    }

    /// The pool covers notes, held fees and held payouts together.
    function invariant_ThePoolCoversEverythingItOwes() public view {
        assertGe(
            address(pool).balance,
            pool.totalShielded(0) + pool.unsweptFees(0) + pool.totalClaimable(0),
            "native obligations exceed the native held"
        );
        assertGe(
            usd.balanceOf(address(pool)),
            pool.totalShielded(usdAssetId) + pool.unsweptFees(usdAssetId) + pool.totalClaimable(usdAssetId),
            "erc20 obligations exceed the erc20 held"
        );
    }

    /// @notice Fees and the residual band stay under their caps through governance churn.
    function invariant_FeeBpsStillCappedAfterGovernanceChurn() public view {
        assertLe(pool.shieldFeeBps(), pool.MAX_FEE_BPS(), "shield fee escaped its cap");
        assertLe(pool.unshieldFeeBps(), pool.MAX_FEE_BPS(), "unshield fee escaped its cap");
        assertLe(pool.residualBandBps(), pool.MAX_BAND_BPS(), "residual band escaped its cap");
    }

    /// @notice A second commit keeps the root and evicts nothing from the window.
    ///         Otherwise repeated permissionless commits could evict every live root.
    function invariant_CommittingIsIdempotentAndAlwaysKnown() public {
        if (pool.nextLeafIndex() == 0) return;
        bytes32 first = pool.commitRoot();
        assertTrue(pool.isKnownRoot(first), "a committed root must be in the window");
        bytes32 second = pool.commitRoot();
        assertEq(second, first, "a second commit moved the root");
        assertTrue(pool.isKnownRoot(first), "a second commit evicted the root it just published");
    }


}
