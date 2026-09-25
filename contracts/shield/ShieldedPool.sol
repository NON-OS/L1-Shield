// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShieldLedger} from "./ShieldLedger.sol";
import {SettlerGate} from "./SettlerGate.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Goldilocks} from "./libraries/Goldilocks.sol";
import {GoldilocksIncrementalTree} from "./GoldilocksIncrementalTree.sol";
import {BatchClearing} from "./BatchClearing.sol";
import {PublicWords} from "./verifier/PublicWords.sol";
import {IStarkVerifier} from "./interfaces/IStarkVerifier.sol";
import {IPoseidonGoldilocks} from "./interfaces/IPoseidonGoldilocks.sol";
import {IAssociationSetRegistry} from "./interfaces/IAssociationSetRegistry.sol";
import {IAttestationVerifier} from "./interfaces/IAttestationVerifier.sol";

/// @title ShieldedPool
/// @notice Shielded UTXO pool. Deposits via absorb, batches of private intents settle under one STARK proof.
/// @dev Custody is immutable and governance cannot move user funds. The verifier checks every
///      constraint on chain, so a settler holds ordering only. See docs/08-pool.md.
contract ShieldedPool is GoldilocksIncrementalTree, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Goldilocks for bytes32;
    using BatchClearing for BatchClearing.Route;

    // The 12 public words of one intent, in order. Amounts are in asset units, see `scale`.
    struct Intent {
        bytes32 noteRoot;
        bytes32 assocRoot;
        bytes32 nf0;
        bytes32 nf1;
        bytes32 outCm0;
        bytes32 outCm1;
        uint256 publicAmount; // 0 = private transfer or swap, > 0 = unshield
        uint256 fee;
        uint64 assetId; // 0 = native
        uint256 clearingPrice; // units of assetOut per unit of assetIn, 1e18-scaled
        address recipient;
        address feeRecipient; // zero sends the fee to the fee router
    }

    // Settler-chosen and unproven. Only the floor is checked, against the proven clearing price.
    struct ResidualExec {
        address router;
        uint64 assetIn;
        uint64 assetOut;
        uint256 amountIn;
        uint256 amountOutMin;
        address[] path;
        uint256 deadline;
    }


    // Vectors checked against the hasher and verifier at construction.
    struct DeploymentSelfTest {
        bytes32 hash2Left;
        bytes32 hash2Right;
        bytes32 hash2Expected;
        uint256[] fieldsInput;
        bytes32 fieldsExpected;
        bytes proof;
        uint256[] proofPublicInputs;
        // Prover's note-commitment vector. A mismatch would insert leaves no proof can open.
        uint256 noteValue;
        uint64 noteAssetId;
        bytes32 noteOwnerCommit;
        bytes32 noteCommitmentExpected;
    }

    uint16 public constant MAX_FEE_BPS = 50;
    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_BAND_BPS = 1_000;
    uint256 public constant PRICE_SCALE = 1e18;
    uint256 public constant FEE_ROUTER_DELAY = 2 days;
    /// @notice After this long without a settlement, anyone with a valid proof may settle.
    uint256 public constant SETTLER_WINDOW = 24 hours;
    /// @notice Anyone may settle in the last OPEN_SLOT of every SETTLEMENT_EPOCH, whatever the settler does.
    uint256 public constant SETTLEMENT_EPOCH = 24 hours;
    uint256 public constant OPEN_SLOT = 1 hours;
    /// @notice Must exceed SETTLER_WINDOW so a hostile settler change lands after settlement opens.
    uint256 public constant SETTLER_DELAY = 48 hours;
    uint256 public constant ROUTER_DELAY = 2 days;
    uint64 public constant NOTE_DOMAIN = 0x4E4F5445; // "NOTE"
    uint64 public constant NATIVE_ASSET_ID = 0;
    uint256 public constant MAX_INTENTS = 64; // keeps settleBatch within a block

    IStarkVerifier public immutable verifier;
    /// @notice Public words per intent: 11, or 12 with a fee recipient. The launch pool uses 12.
    uint256 public immutable wordsPerIntent;
    IAssociationSetRegistry public immutable associationRegistry;

    uint16 public shieldFeeBps;
    uint16 public unshieldFeeBps;
    /// @notice Max shortfall of the residual slippage floor below the proven clearing price, in bps.
    uint16 public residualBandBps = 200;
    address public feeRouter;

    /// @notice Payouts held because the recipient refused them. Held on top of totalShielded.
    mapping(uint64 => mapping(address => uint256)) public claimable;

    /// @notice Sum of claimable per asset, so solvency is one read.
    mapping(uint64 => uint256) public totalClaimable;

    /// @notice Fees held because the router refused them. Held on top of totalShielded.
    mapping(uint64 => uint256) public unsweptFees;
    address public pendingFeeRouter;
    uint64 public pendingFeeRouterEta;
    bool public depositsPaused;

    /// @notice Optional. Only sets the `attested` flag of BatchSettled.
    IAttestationVerifier public attestationVerifier;

    /// @notice Holds the settleBatch ordering privilege. Zero means open to anyone.
    address public settler;
    address public pendingSettler;
    uint64 public pendingSettlerEta;
    uint64 public lastSettlement; // settler window starts here, also reset on settler change

    mapping(address router => bool approved) public approvedRouter;
    mapping(address router => uint64 eta) public pendingRouterEta;

    mapping(bytes32 nullifier => bool spent) public nullifierSpent;
    mapping(uint64 assetId => address token) public assetToken;
    mapping(address token => uint64 assetId) public tokenAssetId;
    uint64 public nextAssetId = 1;
    mapping(uint64 assetId => uint256 amount) public totalShielded;

    /// @notice Base units per note unit. Every on-chain amount is units times scale, fixed at registration.
    mapping(uint64 assetId => uint256 baseUnits) public scale;

    /// @notice Largest fee a private transfer or swap may pay, in units. Zero forbids one.
    mapping(uint64 assetId => uint256 units) public maxRelayFee;

    /// @notice Largest scale an asset may take. Keeps MAX_VALUE times scale far from overflow.
    uint256 public constant MAX_SCALE = 1e18;

    // Beta: allowlisted deposits under per-asset caps that default to zero, so the gate fails closed.

    /// @notice True until endBetaMode. Gates the allowlist, the caps and betaRefund.
    bool public betaMode = true;

    bool public betaPaused; // freezes deposits only, never betaRefund

    /// @notice Lets anyone deposit during beta. Caps, refunds and wind-down still apply.
    bool public openDeposits;

    mapping(address depositor => bool allowed) public betaDepositor;
    mapping(uint64 assetId => uint256 cap) public betaAddrCap;
    mapping(uint64 assetId => uint256 cap) public betaTotalCap;
    mapping(uint64 assetId => mapping(address depositor => uint256 amount)) public betaDeposited;
    mapping(uint64 assetId => uint256 amount) public betaTotalDeposited;

    /// @notice Net deposits per beta depositor, what betaRefund returns. Caps count gross.
    mapping(uint64 assetId => mapping(address depositor => uint256 value)) public betaRefundable;

    /// @notice Sum of betaRefundable per asset as deposited, the denominator of a pro-rata refund.
    mapping(uint64 assetId => uint256 value) public betaRefundableTotal;

    /// @notice totalShielded and betaRefundableTotal of an asset, frozen by its first refund.
    mapping(uint64 assetId => uint256 value) public refundAssets;
    mapping(uint64 assetId => uint256 value) public refundBase;

    /// @notice Set by the first betaRefund. After that the pool never settles again.
    bool public betaWoundDown;

    /// @notice May edit the beta allowlist and nothing else.
    address public depositorRegistrar;

    event BetaDepositorSet(address indexed depositor, bool allowed);
    event DepositorRegistrarSet(address indexed registrar);
    event BetaCapsSet(uint64 indexed assetId, uint256 addrCap, uint256 totalCap);
    event BetaPausedSet(bool paused);
    event OpenDepositsSet(bool open);
    event MaxRelayFeeSet(uint64 indexed assetId, uint256 units);
    event BetaModeEnded();
    event BetaWindDownStarted();
    event BetaRefunded(uint64 indexed assetId, address indexed depositor, uint256 amount);

    event NoteCommitted(bytes32 indexed commitment, uint40 indexed leafIndex);

    /// @notice Opaque client data for one settlement output, so the payee can find the note. The view
    ///         tag comes from the per-note shared secret. See docs/17-client-data.md.
    event OutputNote(uint40 indexed leafIndex, bytes clientData);
    event BatchSettled(bytes32 indexed batchCommitment, uint256 intentCount, uint256 clearingPrice, bool attested);
    event IntentUnshielded(uint64 indexed assetId, address indexed recipient, uint256 amount, uint256 fee);
    event ResidualRouted(uint64 indexed assetIn, uint64 indexed assetOut, uint256 amountIn, uint256 amountOut);
    event NullifierSpent(bytes32 indexed nullifier);
    event AssetRegistered(uint64 indexed assetId, address indexed token, uint256 scale);
    event FeeBpsUpdated(uint16 shieldFeeBps, uint16 unshieldFeeBps);
    event ResidualBandUpdated(uint16 bandBps);
    event PayoutCredited(uint64 indexed assetId, address indexed owner, uint256 amount);
    event PayoutClaimed(uint64 indexed assetId, address indexed owner, address indexed to, uint256 amount);

    event FeeDeferred(uint64 indexed assetId, uint256 amount, uint256 held);
    event FeesSwept(uint64 indexed assetId, address indexed router, uint256 amount);

    event FeeRouterProposed(address indexed proposed, uint64 eta);
    event FeeRouterProposalCancelled(address indexed cancelled);
    event FeeRouterChanged(address indexed previousRouter, address indexed newRouter);
    event DepositsPausedSet(bool paused);
    event RouterProposed(address indexed router, uint64 eta);
    event RouterApproved(address indexed router);
    event RouterRevoked(address indexed router);
    event SettlerProposed(address indexed settler, uint64 eta);
    event SettlerProposalCancelled(address indexed settler);
    event SettlerChanged(address indexed previous, address indexed settler);
    event AttestationVerifierSet(address indexed verifier);

    error HasherSelfTestFailed();
    error NoteCommitmentSelfTestFailed();
    error VerifierSelfTestFailed();
    error ZeroAddress();
    error FeeBpsTooHigh();
    error BandTooHigh();
    error DepositsArePaused();
    error UnknownAsset();
    error AssetAlreadyRegistered();
    error NotAContract();
    error InvalidAmount();
    error NonCanonicalFieldElement();
    error WrongMsgValue();
    error NonStandardTokenTransfer();
    error UnknownOrStaleRoot();
    error UnknownAssociationRoot();
    error NullifierAlreadySpent();
    error DuplicateNullifier();
    error InvalidProof();
    error AmountOutOfRange();
    error FeeOutOfRange();
    error PriceOutOfRange();
    error SameAssetResidual();
    error FeeExceedsCap();
    error ClientDataLengthMismatch(uint256 given, uint256 outputs);
    error NotAnAddress();
    error RecipientRequired();
    error FeeRecipientWithoutFee();
    error BadScale();
    error BadWordsPerIntent();
    error ShieldInViaDepositOnly();
    error NoPublicLegFieldsSet();
    error ShieldedBalanceUnderflow();
    error NativeTransferFailed();
    error NoFeesHeld();
    error NothingToClaim();
    error TimelockNotReady();
    error NoPendingChange();
    error NotSettler();
    error BadBatchLayout();
    error TooManyIntents();
    error RouterNotApproved();
    error NonUniformClearingPrice();
    error ResidualBelowBand();
    error NotBetaDepositor();
    error NotRegistrar();
    error BetaAddrCapExceeded();
    error BetaTotalCapExceeded();
    error BetaIsPaused();
    error BetaModeAlreadyEnded();
    error BetaIsWoundDown();
    error NothingToRefund();
    error NotRefundCaller();

    constructor(
        address safe_,
        IStarkVerifier verifier_,
        IPoseidonGoldilocks hasher_,
        IAssociationSetRegistry registry_,
        address feeRouter_,
        uint16 shieldFeeBps_,
        uint16 unshieldFeeBps_,
        uint256 nativeScale_,
        uint256 wordsPerIntent_,
        DeploymentSelfTest memory selfTest
    ) GoldilocksIncrementalTree(hasher_) Ownable(safe_) {
        if (address(verifier_) == address(0) || address(registry_) == address(0) || feeRouter_ == address(0)) {
            revert ZeroAddress();
        }
        if (shieldFeeBps_ > MAX_FEE_BPS || unshieldFeeBps_ > MAX_FEE_BPS) revert FeeBpsTooHigh();
        // zero means unconfigured: the native coin counts in wei
        if (nativeScale_ == 0) nativeScale_ = 1;
        if (nativeScale_ > MAX_SCALE) revert BadScale();
        if (wordsPerIntent_ != PublicWords.INTENT_WORDS && wordsPerIntent_ != PublicWords.INTENT_WORDS_FEE_RECIPIENT) {
            revert BadWordsPerIntent();
        }

        // Self-test against the deployed hasher and verifier, before any state is written.
        if (hasher_.hash2(selfTest.hash2Left, selfTest.hash2Right) != selfTest.hash2Expected) {
            revert HasherSelfTestFailed();
        }
        if (hasher_.hashFields(selfTest.fieldsInput) != selfTest.fieldsExpected) revert HasherSelfTestFailed();
        if (
            _computeCommitmentWith(
                hasher_, selfTest.noteValue, selfTest.noteAssetId, selfTest.noteOwnerCommit
            ) != selfTest.noteCommitmentExpected
        ) revert NoteCommitmentSelfTestFailed();
        if (!verifier_.verifyBatch(selfTest.proof, selfTest.proofPublicInputs)) revert VerifierSelfTestFailed();

        verifier = verifier_;
        wordsPerIntent = wordsPerIntent_;
        associationRegistry = registry_;
        feeRouter = feeRouter_;
        lastSettlement = uint64(block.timestamp);
        shieldFeeBps = shieldFeeBps_;
        unshieldFeeBps = unshieldFeeBps_;
        scale[NATIVE_ASSET_ID] = nativeScale_;
        emit AssetRegistered(NATIVE_ASSET_ID, address(0), nativeScale_);
    }

    /// @notice Registers an ERC-20 under the next asset id with a fixed scale, 1 to MAX_SCALE.
    /// @dev Owner only: the scale is permanent, and a squatter could pick one that caps every note.
    function registerAsset(address token, uint256 scale_) external onlyOwner returns (uint64 assetId) {
        if (token == address(0)) revert ZeroAddress();
        if (scale_ == 0 || scale_ > MAX_SCALE) revert BadScale();
        if (token.code.length == 0) revert NotAContract();
        if (tokenAssetId[token] != 0) revert AssetAlreadyRegistered();

        assetId = nextAssetId;
        unchecked {
            nextAssetId = assetId + 1;
        }
        assetToken[assetId] = token;
        tokenAssetId[token] = assetId;
        scale[assetId] = scale_;
        emit AssetRegistered(assetId, token, scale_);
    }

    /// @notice Shields `amount` base units, a whole number of units, into a new note, net of the shield
    ///         fee. The leaf becomes provable once commitRoot publishes a root that contains it.
    // absorb is nonReentrant, so no entry point moves the balance read around the transfer.
    // slither-disable-next-line reentrancy-balance
    function absorb(uint64 assetId, uint256 amount, bytes32 ownerCommit)
        external
        payable
        nonReentrant
        returns (bytes32 commitment, uint40 leafIndex)
    {
        if (depositsPaused) revert DepositsArePaused();
        // a wound-down pool never settles again, so it takes no new notes
        if (betaWoundDown) revert BetaIsWoundDown();
        address token = _requireAsset(assetId);
        uint256 s = scale[assetId];
        uint256 units = amount / s;
        // a remainder would sit in the pool backing no note
        if (units == 0 || units > Goldilocks.MAX_VALUE || amount % s != 0) revert InvalidAmount();
        _gateBeta(assetId, amount);
        if (!ownerCommit.isCanonicalDigest()) revert NonCanonicalFieldElement();

        if (assetId == NATIVE_ASSET_ID) {
            if (msg.value != amount) revert WrongMsgValue();
        } else {
            if (msg.value != 0) revert WrongMsgValue();
            uint256 before = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            if (IERC20(token).balanceOf(address(this)) - before != amount) revert NonStandardTokenTransfer();
        }

        // split in units, so the fee and the note are both whole units
        (uint256 feeUnits, uint256 valueUnits) = ShieldLedger.splitDeposit(units, shieldFeeBps);
        if (valueUnits == 0) revert InvalidAmount();
        uint256 value = valueUnits * s;

        if (betaMode) {
            betaRefundable[assetId][msg.sender] += value;
            betaRefundableTotal[assetId] += value;
        }

        commitment = _computeCommitment(valueUnits, assetId, ownerCommit);
        // deferred: the root is published by commitRoot
        leafIndex = _insertLeafDeferred(commitment);
        totalShielded[assetId] += value;

        emit NoteCommitted(commitment, leafIndex);

        _payFee(assetId, feeUnits * s);
    }

    /// @notice Settles a batch of private intents under one STARK proof.
    /// @dev Nullifiers are spent and outputs inserted before any external call.
    /// @param publicInputs `wordsPerIntent` words per intent, see docs/08-pool.md.
    /// @param clientData One sealed note per output, 2N in total, in output order.
    function settleBatch(
        bytes calldata proof,
        uint256[] calldata publicInputs,
        ResidualExec calldata residual,
        bytes calldata attestation,
        bytes[] calldata clientData
    ) external nonReentrant {
        if (betaWoundDown) revert BetaIsWoundDown();
        // the settler has priority for SETTLER_WINDOW after each settlement, except in the daily open slot
        if (
            !SettlerGate.open(settler, msg.sender, lastSettlement, block.timestamp, SETTLER_WINDOW)
                && !SettlerGate.inOpenSlot(block.timestamp, SETTLEMENT_EPOCH, OPEN_SLOT)
        ) revert NotSettler();
        lastSettlement = uint64(block.timestamp);
        uint256 k = wordsPerIntent;
        if (publicInputs.length == 0 || publicInputs.length % k != 0) revert BadBatchLayout();

        uint256 n = publicInputs.length / k;
        if (n > MAX_INTENTS) revert TooManyIntents();

        // validate every intent and mark its nullifiers spent before any external call
        Intent[] memory intents = new Intent[](n);
        uint256 clearingPrice;
        for (uint256 i = 0; i < n; ++i) {
            Intent memory it = _decodeIntent(publicInputs, i * k);
            if (i == 0) {
                clearingPrice = it.clearingPrice;
            } else if (it.clearingPrice != clearingPrice) {
                revert NonUniformClearingPrice();
            }
            if (!isKnownRoot(it.noteRoot)) revert UnknownOrStaleRoot();
            if (!associationRegistry.isRegisteredRoot(it.assocRoot)) revert UnknownAssociationRoot();
            _spend(it.nf0);
            _spend(it.nf1);
            intents[i] = it;
        }

        // one proof for the whole batch, by view call
        if (!verifier.verifyBatch(proof, publicInputs)) revert InvalidProof();

        bool attested = _checkAttestation(publicInputs, attestation);

        // 2N contiguous leaves in one batch insert, which computes shared ancestors once
        bytes32[] memory cms = new bytes32[](2 * n);
        for (uint256 i = 0; i < n; ++i) {
            cms[2 * i] = intents[i].outCm0;
            cms[2 * i + 1] = intents[i].outCm1;
        }
        uint40 firstLeaf = _insertLeavesDeferred(cms);
        // one blob per output
        if (clientData.length != cms.length) revert ClientDataLengthMismatch(clientData.length, cms.length);
        for (uint256 i = 0; i < cms.length; ++i) {
            emit NoteCommitted(cms[i], firstLeaf + uint40(i));
            emit OutputNote(firstLeaf + uint40(i), clientData[i]);
        }

        // external transfers last
        _settleIntents(intents);
        _settleResidual(residual, clearingPrice);

        emit BatchSettled(keccak256(abi.encode(publicInputs)), n, clearingPrice, attested);
    }

    /// @notice Folds the frontier and publishes a root covering every leaf inserted so far.
    /// @dev Permissionless and idempotent. A commit that does not move the root uses no ring slot.
    function commitRoot() external returns (bytes32 root) {
        return _commitRoot();
    }

    /// @notice Sets the shield and unshield fees in bps, each at most MAX_FEE_BPS.
    /// @dev Settlement charges each intent's proven fee and does not read unshieldFeeBps.
    function setFeeBps(uint16 shieldFeeBps_, uint16 unshieldFeeBps_) external onlyOwner {
        if (shieldFeeBps_ > MAX_FEE_BPS || unshieldFeeBps_ > MAX_FEE_BPS) revert FeeBpsTooHigh();
        shieldFeeBps = shieldFeeBps_;
        unshieldFeeBps = unshieldFeeBps_;
        emit FeeBpsUpdated(shieldFeeBps_, unshieldFeeBps_);
    }

    /// @notice Sets how far below the clearing price the residual slippage floor may sit, in bps.
    function setResidualBand(uint16 bandBps) external onlyOwner {
        if (bandBps > MAX_BAND_BPS) revert BandTooHigh();
        residualBandBps = bandBps;
        emit ResidualBandUpdated(bandBps);
    }

    /// @notice Proposes a new fee router, executable after FEE_ROUTER_DELAY.
    function proposeFeeRouter(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert ZeroAddress();
        pendingFeeRouter = newRouter;
        pendingFeeRouterEta = uint64(block.timestamp + FEE_ROUTER_DELAY);
        emit FeeRouterProposed(newRouter, pendingFeeRouterEta);
    }

    /// @notice Cancels the pending fee router proposal.
    function cancelFeeRouterChange() external onlyOwner {
        address cancelled = pendingFeeRouter;
        if (cancelled == address(0)) revert NoPendingChange();
        delete pendingFeeRouter;
        delete pendingFeeRouterEta;
        emit FeeRouterProposalCancelled(cancelled);
    }

    /// @notice Installs the pending fee router once its delay has passed. Callable by anyone.
    function executeFeeRouterChange() external {
        address proposed = pendingFeeRouter;
        if (proposed == address(0)) revert NoPendingChange();
        if (block.timestamp < pendingFeeRouterEta) revert TimelockNotReady();
        address previous = feeRouter;
        feeRouter = proposed;
        delete pendingFeeRouter;
        delete pendingFeeRouterEta;
        emit FeeRouterChanged(previous, proposed);
    }

    /// @notice Pauses or resumes absorb. Settlement, claims and refunds are unaffected.
    function setDepositsPaused(bool paused) external onlyOwner {
        depositsPaused = paused;
        emit DepositsPausedSet(paused);
    }

    /// @notice Allows or removes a beta depositor. Callable by the owner or the registrar.
    function setBetaDepositor(address depositor, bool allowed) external {
        if (msg.sender != owner() && msg.sender != depositorRegistrar) revert NotRegistrar();
        if (depositor == address(0)) revert ZeroAddress();
        betaDepositor[depositor] = allowed;
        emit BetaDepositorSet(depositor, allowed);
    }

    /// @notice Sets per-address and pool-wide beta caps for one asset, in base units, zero by default.
    function setBetaCaps(uint64 assetId, uint256 addrCap, uint256 totalCap) external onlyOwner {
        _requireAsset(assetId);
        betaAddrCap[assetId] = addrCap;
        betaTotalCap[assetId] = totalCap;
        emit BetaCapsSet(assetId, addrCap, totalCap);
    }

    /// @notice Freezes or resumes beta deposits. Cannot resume once the wind-down has begun.
    function setBetaPaused(bool paused) external onlyOwner {
        if (!paused && betaWoundDown) revert BetaIsWoundDown();
        betaPaused = paused;
        emit BetaPausedSet(paused);
    }

    /// @notice Opens beta deposits to every address, or restores the allowlist. Caps, the beta pause,
    ///         refunds and the wind-down apply either way.
    function setOpenDeposits(bool open) external onlyOwner {
        openDeposits = open;
        emit OpenDepositsSet(open);
    }

    /// @notice Sets the largest fee, in units, that an intent with no public amount may pay, at most
    ///         MAX_VALUE. A transfer has no amount to take a share of, so its fee needs a ceiling.
    function setMaxRelayFee(uint64 assetId, uint256 units) external onlyOwner {
        _requireAsset(assetId);
        if (units > Goldilocks.MAX_VALUE) revert FeeOutOfRange();
        maxRelayFee[assetId] = units;
        emit MaxRelayFeeSet(assetId, units);
    }

    /// @notice Appoints the beta allowlist registrar, or clears it with the zero address.
    function setDepositorRegistrar(address registrar) external onlyOwner {
        depositorRegistrar = registrar;
        emit DepositorRegistrarSet(registrar);
    }

    /// @notice Ends the beta: lifts the allowlist and caps and closes betaRefund. One-way.
    function endBetaMode() external onlyOwner {
        if (!betaMode) revert BetaModeAlreadyEnded();
        if (betaWoundDown) revert BetaIsWoundDown();
        betaMode = false;
        betaPaused = false;
        emit BetaModeEnded();
    }

    /// @notice Refunds a beta depositor deposit * refundAssets / refundBase, at most the net deposit.
    /// @dev The first refund winds the pool down for good, because refunded notes stay in the tree.
    ///      Needs no proof and ignores every pause.
    function betaRefund(uint64 assetId, address depositor) external nonReentrant returns (uint256 amount) {
        if (!betaMode) revert BetaModeAlreadyEnded();
        if (msg.sender != depositor && msg.sender != owner()) revert NotRefundCaller();

        uint256 owed = betaRefundable[assetId][depositor];
        if (owed == 0) revert NothingToRefund();
        betaRefundable[assetId][depositor] = 0;

        if (!betaWoundDown) {
            betaWoundDown = true;
            emit BetaWindDownStarted();
        }
        uint256 base = refundBase[assetId];
        if (base == 0) {
            base = betaRefundableTotal[assetId];
            refundBase[assetId] = base;
            refundAssets[assetId] = totalShielded[assetId];
        }
        amount = (owed * refundAssets[assetId]) / base;
        // swap proceeds can leave an asset holding more than was deposited, and a refund is not a profit
        if (amount > owed) amount = owed;
        _reduceShielded(assetId, amount);

        emit BetaRefunded(assetId, depositor, amount);
        _payOut(assetId, depositor, amount);
    }

    /// @dev Beta gate: allowlist unless deposits are open, caps and pause. Records the deposit before any external call.
    function _gateBeta(uint64 assetId, uint256 amount) private {
        if (!betaMode) return;
        if (betaPaused) revert BetaIsPaused();
        if (!openDeposits && !betaDepositor[msg.sender]) revert NotBetaDepositor();

        uint256 addrTotal = betaDeposited[assetId][msg.sender] + amount;
        uint256 poolTotal = betaTotalDeposited[assetId] + amount;
        if (addrTotal > betaAddrCap[assetId]) revert BetaAddrCapExceeded();
        if (poolTotal > betaTotalCap[assetId]) revert BetaTotalCapExceeded();

        betaDeposited[assetId][msg.sender] = addrTotal;
        betaTotalDeposited[assetId] = poolTotal;
    }

    /// @notice Proposes a DEX router for residual routing, approvable after ROUTER_DELAY.
    function proposeRouter(address router) external onlyOwner {
        if (router == address(0)) revert ZeroAddress();
        pendingRouterEta[router] = uint64(block.timestamp + ROUTER_DELAY);
        emit RouterProposed(router, pendingRouterEta[router]);
    }

    /// @notice Whitelists a proposed router once its delay has passed. Callable by anyone.
    function executeRouterApproval(address router) external {
        uint64 eta = pendingRouterEta[router];
        if (eta == 0) revert NoPendingChange();
        if (block.timestamp < eta) revert TimelockNotReady();
        delete pendingRouterEta[router];
        approvedRouter[router] = true;
        emit RouterApproved(router);
    }

    /// @notice Removes a router from the whitelist immediately.
    function revokeRouter(address router) external onlyOwner {
        approvedRouter[router] = false;
        emit RouterRevoked(router);
    }

    /// @notice Proposes a new settler, executable after SETTLER_DELAY. Zero opens settlement.
    function proposeSettler(address settler_) external onlyOwner {
        pendingSettler = settler_;
        pendingSettlerEta = uint64(block.timestamp + SETTLER_DELAY);
        emit SettlerProposed(settler_, pendingSettlerEta);
    }

    /// @notice Cancels the pending settler proposal.
    function cancelSettlerChange() external onlyOwner {
        address cancelled = pendingSettler;
        if (pendingSettlerEta == 0) revert NoPendingChange();
        delete pendingSettler;
        delete pendingSettlerEta;
        emit SettlerProposalCancelled(cancelled);
    }

    /// @notice Installs the pending settler once its delay has passed. Callable by anyone.
    function executeSettlerChange() external {
        if (pendingSettlerEta == 0) revert NoPendingChange();
        if (block.timestamp < pendingSettlerEta) revert TimelockNotReady();
        address previous = settler;
        settler = pendingSettler;
        lastSettlement = uint64(block.timestamp);
        delete pendingSettler;
        delete pendingSettlerEta;
        emit SettlerChanged(previous, settler);
    }

    /// @notice Sets or clears the attestation verifier. It only affects BatchSettled.attested.
    function setAttestationVerifier(address verifier_) external onlyOwner {
        attestationVerifier = IAttestationVerifier(verifier_);
        emit AttestationVerifierSet(verifier_);
    }

    function _requireAsset(uint64 assetId) private view returns (address token) {
        if (assetId >= nextAssetId) revert UnknownAsset();
        token = assetToken[assetId];
    }

    function _decodeIntent(uint256[] calldata w, uint256 o) private view returns (Intent memory it) {
        it.noteRoot = bytes32(w[o]);
        it.assocRoot = bytes32(w[o + 1]);
        it.nf0 = bytes32(w[o + 2]);
        it.nf1 = bytes32(w[o + 3]);
        it.outCm0 = bytes32(w[o + 4]);
        it.outCm1 = bytes32(w[o + 5]);
        if (
            !it.noteRoot.isCanonicalDigest() || !it.assocRoot.isCanonicalDigest() || !it.nf0.isCanonicalDigest()
                || !it.nf1.isCanonicalDigest() || !it.outCm0.isCanonicalDigest() || !it.outCm1.isCanonicalDigest()
        ) revert NonCanonicalFieldElement();

        // public_amount is signed, and settlement only accepts 0 <= v <= MAX_VALUE
        int256 pa = int256(w[o + 6]);
        if (pa < 0) revert ShieldInViaDepositOnly();
        if (uint256(pa) > Goldilocks.MAX_VALUE) revert AmountOutOfRange();
        it.publicAmount = uint256(pa);

        if (w[o + 7] > Goldilocks.MAX_VALUE) revert FeeOutOfRange();
        it.fee = w[o + 7];

        if (w[o + 8] > type(uint64).max) revert UnknownAsset();
        it.assetId = uint64(w[o + 8]);
        _requireAsset(it.assetId);

        if (!Goldilocks.isCanonicalLimb(w[o + 9])) revert PriceOutOfRange();
        it.clearingPrice = w[o + 9];

        // the 11-word statement has no fee recipient, and its fee goes to the router
        uint256 fr = wordsPerIntent > PublicWords.INTENT_WORDS ? w[o + 11] : 0;
        if (w[o + 10] > type(uint160).max || fr > type(uint160).max) revert NotAnAddress();
        it.recipient = address(uint160(w[o + 10]));
        it.feeRecipient = address(uint160(fr));

        if (it.nf0 == it.nf1) revert DuplicateNullifier();
        // the prover's rule, repeated so a fee recipient never stands for a zero fee
        if (it.feeRecipient != address(0) && it.fee == 0) revert FeeRecipientWithoutFee();

        // a private transfer or swap pays no recipient, and its fee, if any, pays whoever relayed it
        if (it.publicAmount == 0) {
            if (it.recipient != address(0)) revert NoPublicLegFieldsSet();
            if (it.fee > maxRelayFee[it.assetId]) revert FeeExceedsCap();
        } else {
            if (it.fee * BPS > it.publicAmount * MAX_FEE_BPS) revert FeeExceedsCap();
            if (it.recipient == address(0)) revert RecipientRequired();
        }
    }

    function _spend(bytes32 nf) private {
        if (nullifierSpent[nf]) revert NullifierAlreadySpent();
        nullifierSpent[nf] = true;
        emit NullifierSpent(nf);
    }

    // A failed push is credited after its call returns. Entry points touching credits are nonReentrant.
    // slither-disable-next-line reentrancy-eth
    function _settleIntents(Intent[] memory intents) private {
        uint256[] memory toRecipient = new uint256[](intents.length);
        // every accounting write precedes the first payout, so no transfer sees a half-settled pool
        for (uint256 i = 0; i < intents.length; ++i) {
            Intent memory it = intents[i];
            if (it.publicAmount == 0 && it.fee == 0) continue; // nothing leaves the notes
            // the circuit spends public_amount + fee, so both leave the shielded total
            uint256 s = scale[it.assetId];
            uint256 amount = it.publicAmount * s;
            uint256 fee = it.fee * s;
            _reduceShielded(it.assetId, amount + fee);
            toRecipient[i] = amount;
            // a named fee recipient is only ever credited, so it has no call in which to grief
            if (it.feeRecipient != address(0)) _credit(it.assetId, it.feeRecipient, fee);
            emit IntentUnshielded(it.assetId, it.recipient, amount, fee);
        }
        for (uint256 i = 0; i < intents.length; ++i) {
            Intent memory it = intents[i];
            if (it.publicAmount == 0 && it.fee == 0) continue;
            _payOrCredit(it.assetId, it.recipient, toRecipient[i]);
            if (it.feeRecipient == address(0)) _payFee(it.assetId, it.fee * scale[it.assetId]);
        }
    }

    /// @dev Routes the batch residual through a whitelisted DEX. The settler's slippage floor may
    ///      sit at most `residualBandBps` below the proven clearing price.
    function _settleResidual(ResidualExec calldata r, uint256 clearingPrice) private {
        if (r.amountIn == 0) return;
        if (!approvedRouter[r.router]) revert RouterNotApproved();
        _requireAsset(r.assetIn);
        _requireAsset(r.assetOut);
        // a swap into the same token measures its own outflow as a loss and strands the input
        if (r.assetIn == r.assetOut) revert SameAssetResidual();
        uint256 scaleIn = scale[r.assetIn];
        if (r.amountIn % scaleIn != 0) revert InvalidAmount();

        // the price is in units, so the floor converts: amountIn / scaleIn * price / 1e18 * scaleOut.
        // Both divisions round up, so the settler can never accept less than the exact band floor.
        uint256 scaleOut = scale[r.assetOut];
        uint256 anchored = Math.mulDiv(r.amountIn, clearingPrice * scaleOut, PRICE_SCALE * scaleIn, Math.Rounding.Ceil);
        uint256 bandFloor = Math.mulDiv(anchored, BPS - residualBandBps, BPS, Math.Rounding.Ceil);
        if (r.amountOutMin < bandFloor) revert ResidualBelowBand();

        // the residual leaves as assetIn and returns as assetOut, both shielded
        _reduceShielded(r.assetIn, r.amountIn);

        BatchClearing.Route memory route = BatchClearing.Route({
            router: r.router,
            tokenIn: assetToken[r.assetIn],
            tokenOut: assetToken[r.assetOut],
            amountIn: r.amountIn,
            amountOutMin: r.amountOutMin,
            path: r.path,
            deadline: r.deadline
        });
        uint256 amountOut = route.routeResidual();
        // only whole units join the shielded total, and the remainder goes to the fee router
        uint256 dust = amountOut % scaleOut;
        totalShielded[r.assetOut] += amountOut - dust;
        if (dust != 0) {
            unsweptFees[r.assetOut] += dust;
            emit FeeDeferred(r.assetOut, dust, unsweptFees[r.assetOut]);
        }

        emit ResidualRouted(r.assetIn, r.assetOut, r.amountIn, amountOut);
    }

    function _checkAttestation(uint256[] calldata publicInputs, bytes calldata attestation)
        private
        view
        returns (bool)
    {
        if (address(attestationVerifier) == address(0) || attestation.length == 0) return false;
        return attestationVerifier.verifyAttestation(keccak256(abi.encode(publicInputs)), attestation);
    }

    function _reduceShielded(uint64 assetId, uint256 amount) private {
        (bool ok, uint256 left) = ShieldLedger.debit(totalShielded[assetId], amount);
        if (!ok) revert ShieldedBalanceUnderflow();
        totalShielded[assetId] = left;
    }

    /// @dev cm = Poseidon([value_lo32, value_hi, asset, NOTE_DOMAIN], ownerCommit), over the value
    ///      actually received. The 32-bit split matches the circuit's range argument.
    function _computeCommitment(uint256 value, uint64 assetId, bytes32 ownerCommit)
        private
        view
        returns (bytes32)
    {
        return _computeCommitmentWith(treeHasher, value, assetId, ownerCommit);
    }

    /// @dev {_computeCommitment} against an explicit hasher, for the constructor self-test.
    function _computeCommitmentWith(IPoseidonGoldilocks h, uint256 value, uint64 assetId, bytes32 ownerCommit)
        private
        view
        returns (bytes32)
    {
        uint256 pub = (value & 0xFFFFFFFF) | ((value >> 32) << 64) | (uint256(assetId) << 128)
            | (uint256(NOTE_DOMAIN) << 192);
        return h.hash2(bytes32(pub), ownerCommit);
    }

    /// @dev Pays a recipient, or credits them to `claim` later, so one refusal voids no batch.
    function _payOrCredit(uint64 assetId, address to, uint256 amount) private {
        if (amount == 0) return;
        if (assetId == NATIVE_ASSET_ID) {
            // slither-disable-next-line arbitrary-send-eth
            (bool ok,) = payable(to).call{value: amount, gas: NATIVE_PUSH_GAS}(""); // recipient named by a proven intent
            if (!ok) _credit(assetId, to, amount);
        } else {
            _credit(assetId, to, _pushToken(assetToken[assetId], to, amount));
        }
    }

    function _credit(uint64 assetId, address to, uint256 amount) private {
        if (amount == 0) return;
        claimable[assetId][to] += amount;
        totalClaimable[assetId] += amount;
        emit PayoutCredited(assetId, to, amount);
    }

    /// @notice Collects a payout the pool is holding for the caller and sends it to `to`.
    /// @param to Recipient of the whole held amount.
    function claim(uint64 assetId, address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = claimable[assetId][msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimable[assetId][msg.sender] = 0;
        totalClaimable[assetId] -= amount;
        _payOut(assetId, to, amount);
        emit PayoutClaimed(assetId, msg.sender, to, amount);
    }

    /// @dev Gas forwarded with a native push, so the callee cannot consume the caller's gas.
    uint256 private constant NATIVE_PUSH_GAS = 50_000;

    /// @dev Gas forwarded with a token push. A token that needs more is credited instead.
    uint256 private constant TOKEN_PUSH_GAS = 100_000;

    /// @dev Gas for reading the pool's own token balance around a push.
    uint256 private constant TOKEN_READ_GAS = 50_000;

    /// @dev Pushes `amount` and returns what did not arrive, measured on the balance of the pool, so a
    ///      token that moves funds and then answers badly is not paid twice.
    function _pushToken(address token, address to, uint256 amount) private returns (uint256 unpaid) {
        (bool read, uint256 before) = _selfBalance(token);
        if (_tryTransfer(token, to, amount)) return 0;
        (bool readAfter, uint256 left) = _selfBalance(token);
        if (!read || !readAfter || left >= before) return amount;
        uint256 moved = before - left;
        return moved >= amount ? 0 : amount - moved;
    }

    function _selfBalance(address token) private view returns (bool ok, uint256 bal) {
        bytes4 sel = IERC20.balanceOf.selector;
        assembly ("memory-safe") {
            mstore(0, sel)
            mstore(4, address())
            ok := staticcall(TOKEN_READ_GAS, token, 0, 36, 0, 32)
            ok := and(ok, eq(returndatasize(), 32))
            bal := mload(0)
        }
    }

    /// @dev ERC-20 transfer that cannot revert the caller. Success is no data from a contract, or one
    ///      word equal to 1. Only that word is copied.
    function _tryTransfer(address token, address to, uint256 amount) private returns (bool ok) {
        bytes4 sel = IERC20.transfer.selector;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, sel)
            mstore(add(ptr, 4), to)
            mstore(add(ptr, 36), amount)
            ok := call(TOKEN_PUSH_GAS, token, 0, ptr, 68, 0, 32)
            switch returndatasize()
            case 0 { ok := and(ok, gt(extcodesize(token), 0)) }
            case 32 { ok := and(ok, eq(mload(0), 1)) }
            default { ok := 0 }
        }
    }

    /// @dev Pays the fee router, or holds the fee in `unsweptFees`, so a broken router blocks nothing.
    function _payFee(uint64 assetId, uint256 amount) private {
        if (amount == 0) return;
        address router = feeRouter;
        if (assetId == NATIVE_ASSET_ID) {
            // slither-disable-next-line arbitrary-send-eth
            (bool ok,) = payable(router).call{value: amount, gas: NATIVE_PUSH_GAS}(""); // the governance fee router
            if (ok) return;
        } else {
            amount = _pushToken(assetToken[assetId], router, amount);
            if (amount == 0) return;
        }

        unsweptFees[assetId] += amount;
        emit FeeDeferred(assetId, amount, unsweptFees[assetId]);
    }

    /// @notice Sends fees the router refused earlier to the current router. Permissionless.
    /// @param assetId The asset whose held fees to deliver.
    function sweepFees(uint64 assetId) external nonReentrant {
        uint256 amount = unsweptFees[assetId];
        if (amount == 0) revert NoFeesHeld();
        // cleared before the transfer, which reverts the whole sweep if it fails
        unsweptFees[assetId] = 0;
        address router = feeRouter;
        _payOut(assetId, router, amount);
        emit FeesSwept(assetId, router, amount);
    }

    function _payOut(uint64 assetId, address to, uint256 amount) private {
        if (assetId == NATIVE_ASSET_ID) {
            // slither-disable-next-line arbitrary-send-eth
            (bool ok,) = payable(to).call{value: amount}(""); // the caller's own balance, or the fee router
            if (!ok) revert NativeTransferFailed();
        } else {
            IERC20(assetToken[assetId]).safeTransfer(to, amount);
        }
    }

    /// @notice Whether an address can be named as a recipient or fee recipient in a proof.
    /// @dev A 12-word pool splits an address into 48-bit limbs and accepts every address. An 11-word
    ///      pool uses 64-bit limbs and refuses about one address in 2^32.
    function isRepresentable(address a) external view returns (bool) {
        // the 12-word layout splits an address into 48-bit limbs, all below p
        if (wordsPerIntent == PublicWords.INTENT_WORDS_FEE_RECIPIENT) return true;
        return bytes32(uint256(uint160(a))).isCanonicalDigest();
    }

    /// @notice Accepts native residual proceeds from the DEX router.
    receive() external payable {}
}
