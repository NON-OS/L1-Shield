// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ShieldedPool} from "../../contracts/shield/ShieldedPool.sol";
import {AssociationSetRegistry} from "../../contracts/shield/AssociationSetRegistry.sol";
import {ShieldFeeRouter} from "../../contracts/shield/ShieldFeeRouter.sol";
import {NoxShieldStaking} from "../../contracts/shield/NoxShieldStaking.sol";
import {Goldilocks} from "../../contracts/shield/libraries/Goldilocks.sol";
import {IStarkVerifier} from "../../contracts/shield/interfaces/IStarkVerifier.sol";
import {IPoseidonGoldilocks} from "../../contracts/shield/interfaces/IPoseidonGoldilocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockPoseidonGoldilocks} from "./mocks/MockPoseidonGoldilocks.sol";
import {MockStarkVerifier} from "./mocks/MockStarkVerifier.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockDexRouter} from "./mocks/MockDexRouter.sol";

/// One empty client-data blob per settlement output. Empty is legal: the opening travels
/// some other way.
function _blobs(uint256 n) pure returns (bytes[] memory b) {
    b = new bytes[](n);
}

/// One blob per output for a batch described by its public words: two outputs and twelve words
/// per intent. The pool refuses a blob count that does not match the batch size.
function _blobsFor(uint256[] memory publicWords) pure returns (bytes[] memory) {
    return _blobs(2 * (publicWords.length / 12));
}


/// @notice Shared deployment and batch helpers for the NOX Shield test suite.
abstract contract ShieldTestBase is Test {
    uint16 internal constant SHIELD_FEE_BPS = 25;
    uint16 internal constant UNSHIELD_FEE_BPS = 25;
    uint16 internal constant STAKING_BPS = 4000;
    uint16 internal constant TREASURY_BPS = 3000;
    uint16 internal constant BURN_BPS = 3000;
    uint256 internal constant COOLDOWN = 7 days;

    address internal safe = makeAddr("safe");
    address internal treasury = makeAddr("treasury");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal relayer = makeAddr("relayer");

    MockPoseidonGoldilocks internal hasher;
    MockStarkVerifier internal verifier;
    MockERC20 internal nox;
    MockERC20 internal usd;
    MockDexRouter internal dex;
    AssociationSetRegistry internal registry;
    NoxShieldStaking internal staking;
    ShieldFeeRouter internal feeRouter;
    ShieldedPool internal pool;

    bytes32 internal assocRoot;
    uint64 internal usdAssetId;
    uint256 internal nfCounter;

    /// @notice Test-side mirror of one intent's mutable fields. noteRoot, assocRoot and
    ///         clearingPrice come from the batch header in {encodeBatch}.
    struct TIntent {
        bytes32 nf0;
        bytes32 nf1;
        bytes32 outCm0;
        bytes32 outCm1;
        uint256 publicAmount;
        uint256 fee;
        address recipient;
        uint64 assetId;
        address feeRecipient;
    }

    function setUp() public virtual {
        hasher = new MockPoseidonGoldilocks();
        verifier = new MockStarkVerifier();
        nox = new MockERC20("NOX", "NOX");
        usd = new MockERC20("USD", "USD");
        dex = new MockDexRouter();
        registry = new AssociationSetRegistry();
        staking = new NoxShieldStaking(safe, IERC20(address(nox)), COOLDOWN);
        feeRouter = new ShieldFeeRouter(
            safe, IERC20(address(nox)), address(staking), treasury, STAKING_BPS, TREASURY_BPS, BURN_BPS
        );
        pool = new ShieldedPool(
            safe,
            IStarkVerifier(address(verifier)),
            IPoseidonGoldilocks(address(hasher)),
            registry,
            address(feeRouter),
            SHIELD_FEE_BPS,
            UNSHIELD_FEE_BPS,
            0, // native scale left at its default of 1
            12, // the launch layout, with a fee recipient
            _selfTest()
        );

        vm.prank(safe);
        staking.setRewardNotifier(address(feeRouter));

        usdAssetId = registerToken(address(usd));

        assocRoot = dig("assoc-root-1");
        registry.publishRoot(assocRoot, "ipfs://assoc-1");

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        usd.mint(alice, 1e24);
        usd.mint(bob, 1e24);

        _settleBetaPosture();
    }

    /// @dev Ends beta mode so the suite runs against the public pool. The beta-gate tests
    ///      override this to keep the gate armed.
    function _settleBetaPosture() internal virtual {
        vm.prank(safe);
        pool.endBetaMode();
    }

    function _selfTest() internal view returns (ShieldedPool.DeploymentSelfTest memory st) {
        st.hash2Left = bytes32(uint256(1));
        st.hash2Right = bytes32(uint256(2));
        st.hash2Expected = hasher.hash2(st.hash2Left, st.hash2Right);
        st.fieldsInput = new uint256[](3);
        st.fieldsInput[0] = 1;
        st.fieldsInput[1] = 2;
        st.fieldsInput[2] = 3;
        st.fieldsExpected = hasher.hashFields(st.fieldsInput);
        st.proof = hex"53454c4654455354";
        st.proofPublicInputs = new uint256[](12); // one intent tuple
        // Note-commitment gate: value, asset, owner digest and the expected commitment,
        // computed through the hasher the pool pins.
        st.noteValue = 1000;
        st.noteAssetId = 0;
        st.noteOwnerCommit = hasher.hash2(bytes32(uint256(7)), bytes32(uint256(8)));
        st.noteCommitmentExpected = hasher.hash2(
            bytes32(uint256(1000) | (uint256(0) << 64) | (uint256(0) << 128) | (uint256(0x4E4F5445) << 192)),
            st.noteOwnerCommit
        );
    }

    function dig(string memory seed) internal pure returns (bytes32) {
        return canon(keccak256(bytes(seed)));
    }

    function fresh() internal returns (bytes32) {
        return canon(keccak256(abi.encode("fresh", ++nfCounter)));
    }

    function canon(bytes32 h) internal pure returns (bytes32 out) {
        uint256 v = uint256(h);
        uint256 acc;
        for (uint256 i = 0; i < 4; ++i) {
            acc |= (((v >> (64 * i)) & 0xFFFFFFFFFFFFFFFF) % Goldilocks.P) << (64 * i);
        }
        out = bytes32(acc);
    }

    function newIntent(uint256 publicAmount, uint256 fee, address recipient, uint64 assetId)
        internal
        returns (TIntent memory it)
    {
        it.nf0 = fresh();
        it.nf1 = fresh();
        it.outCm0 = fresh();
        it.outCm1 = fresh();
        it.publicAmount = publicAmount;
        it.fee = fee;
        it.recipient = recipient;
        it.assetId = assetId;
    }

    /// @dev Encodes a batch as N × 12-word tuples in the frozen AIR order.
    function encodeBatch(bytes32 noteRoot, bytes32 assocRoot_, uint256 clearingPrice, TIntent[] memory intents)
        internal
        pure
        returns (uint256[] memory w)
    {
        uint256 n = intents.length;
        w = new uint256[](n * 12);
        for (uint256 i = 0; i < n; ++i) {
            uint256 o = i * 12;
            w[o] = uint256(noteRoot);
            w[o + 1] = uint256(assocRoot_);
            w[o + 2] = uint256(intents[i].nf0);
            w[o + 3] = uint256(intents[i].nf1);
            w[o + 4] = uint256(intents[i].outCm0);
            w[o + 5] = uint256(intents[i].outCm1);
            w[o + 6] = intents[i].publicAmount;
            w[o + 7] = intents[i].fee;
            w[o + 8] = intents[i].assetId;
            w[o + 9] = clearingPrice;
            w[o + 10] = uint256(uint160(intents[i].recipient));
            w[o + 11] = uint256(uint160(intents[i].feeRecipient));
        }
    }

    function noResidual() internal pure returns (ShieldedPool.ResidualExec memory r) {
        r.path = new address[](0);
    }

    /// @dev Settle a batch of one or more intents, no residual.
    function settle(uint256[] memory w) internal {
        pool.settleBatch(hex"70726f6f66", w, noResidual(), "", _blobsFor(w));
    }

    /// @dev A single-intent batch (native asset, no swap, no residual).
    function singleIntent(uint256 publicAmount, uint256 fee, address recipient) internal returns (uint256[] memory w) {
        TIntent[] memory intents = new TIntent[](1);
        intents[0] = newIntent(publicAmount, fee, recipient, 0);
        w = encodeBatch(pool.currentRoot(), assocRoot, 0, intents);
    }

    /// @dev A legal private transfer: public_amount, fee, clearing_price and recipient all zero.
    ///      With no public amount, a recipient or a fee above maxRelayFee is refused before the verifier runs.
    function singleTransfer() internal returns (uint256[] memory w) {
        TIntent[] memory intents = new TIntent[](1);
        intents[0] = newIntent(0, 0, address(0), 0);
        w = encodeBatch(pool.currentRoot(), assocRoot, 0, intents);
    }

    /// @dev Registers a token at scale 1, as the owner.
    function registerToken(address token) internal returns (uint64) {
        vm.prank(safe);
        return pool.registerAsset(token, 1);
    }

    function depositNative(address from, uint256 amount) internal returns (bytes32 commitment, uint256 value) {
        vm.prank(from);
        (commitment,) = pool.absorb{value: amount}(0, amount, fresh());
        value = amount - (amount * SHIELD_FEE_BPS) / 10_000;
    }

}
