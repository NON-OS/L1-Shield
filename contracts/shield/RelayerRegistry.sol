// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice The view the registry reads, the pool's AmountPolicy: per asset, whether the relay fee is
///         flat, and the fee, in note units. A flat fee is every relayer's fee; otherwise it is a cap.
interface IRelayFeeCap {
    function relayFee(uint64 assetId) external view returns (bool flat, uint256 units);
}

/// @title RelayerRegistry
/// @notice Permissionless list of bonded relayers for wallets to pick from. Holds bonds only.
/// @dev No owner. A bond leaves only to its operator, EXIT_DELAY after deregistration.
///      The balance equals the sum of bonds not yet withdrawn.
contract RelayerRegistry is ReentrancyGuard {
    /// @notice Least bond a relayer posts, in wei.
    uint256 public constant MIN_BOND = 0.05 ether;
    /// @notice Time from deregistration until the bond is withdrawable.
    uint256 public constant EXIT_DELAY = 7 days;
    /// @notice Longest endpoint string, in bytes.
    uint256 public constant MAX_ENDPOINT_BYTES = 128;

    struct Relayer {
        address feeRecipient; // the address the relayer binds in proofs
        bool active;
        uint64 exitAt; // zero while active
        uint256 bond; // wei
        string endpoint; // Tor onion address
    }

    /// @notice The policy that sets or caps every fee here.
    IRelayFeeCap public immutable pool;

    mapping(address operator => Relayer) internal _relayers;
    /// @notice Registrations per operator. Fees are keyed by it, so a new registration starts with none.
    mapping(address operator => uint256 count) public registrations;
    mapping(address operator => mapping(uint256 registration => mapping(uint64 assetId => uint256 units))) internal
        _fees;

    address[] internal _active;
    mapping(address operator => uint256 slot) internal _slotPlusOne;

    event RelayerRegistered(address indexed operator, address indexed feeRecipient, uint256 bond, string endpoint);
    event EndpointUpdated(address indexed operator, string endpoint);
    event FeeSet(address indexed operator, uint64 indexed assetId, uint256 units);
    event DeregistrationStarted(address indexed operator, uint64 withdrawableAt);
    event BondWithdrawn(address indexed operator, uint256 amount);

    error ZeroAddress();
    error BondTooSmall();
    error AlreadyRegistered();
    error NotActive();
    error NotExiting();
    error ExitDelayPending(uint64 withdrawableAt);
    error BadEndpoint();
    error LengthMismatch();
    error FeeAboveCap(uint64 assetId, uint256 units, uint256 cap);
    error FlatFeeAsset(uint64 assetId);
    error TransferFailed();

    constructor(IRelayFeeCap pool_) {
        if (address(pool_) == address(0)) revert ZeroAddress();
        pool = pool_;
    }

    /// @notice Registers the caller as a relayer with a bond of msg.value, at least MIN_BOND.
    /// @param fees Units per asset in `assetIds`, each at most its cap. An asset with a flat fee is refused.
    function register(
        address feeRecipient,
        string calldata endpoint,
        uint64[] calldata assetIds,
        uint256[] calldata fees
    ) external payable {
        if (feeRecipient == address(0)) revert ZeroAddress();
        if (msg.value < MIN_BOND) revert BondTooSmall();
        Relayer storage r = _relayers[msg.sender];
        // a record stays until its bond is withdrawn
        if (r.bond != 0) revert AlreadyRegistered();
        _checkEndpoint(endpoint);

        r.feeRecipient = feeRecipient;
        r.active = true;
        r.bond = msg.value;
        r.endpoint = endpoint;
        ++registrations[msg.sender];
        _active.push(msg.sender);
        _slotPlusOne[msg.sender] = _active.length;
        emit RelayerRegistered(msg.sender, feeRecipient, msg.value, endpoint);
        _setFees(assetIds, fees);
    }

    /// @notice Replaces the caller's endpoint.
    function updateEndpoint(string calldata endpoint) external {
        Relayer storage r = _requireActive();
        _checkEndpoint(endpoint);
        r.endpoint = endpoint;
        emit EndpointUpdated(msg.sender, endpoint);
    }

    /// @notice Sets the caller's fee for each asset. Zero stops serving that asset.
    function setFees(uint64[] calldata assetIds, uint256[] calldata fees) external {
        _requireActive();
        _setFees(assetIds, fees);
    }

    /// @notice Leaves the list. The bond is withdrawable EXIT_DELAY from now.
    function deregister() external {
        Relayer storage r = _requireActive();
        r.active = false;
        uint64 at = uint64(block.timestamp + EXIT_DELAY);
        r.exitAt = at;

        // swap and pop, so the list stays dense for paging
        uint256 slot = _slotPlusOne[msg.sender] - 1;
        address last = _active[_active.length - 1];
        _active[slot] = last;
        _slotPlusOne[last] = slot + 1;
        _active.pop();
        delete _slotPlusOne[msg.sender];
        emit DeregistrationStarted(msg.sender, at);
    }

    /// @notice Pays the caller's bond back once the exit delay has passed, and clears the record.
    function withdrawBond() external nonReentrant {
        Relayer storage r = _relayers[msg.sender];
        if (r.bond == 0 || r.active) revert NotExiting();
        if (block.timestamp < r.exitAt) revert ExitDelayPending(r.exitAt);
        uint256 amount = r.bond;
        delete _relayers[msg.sender];

        emit BondWithdrawn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function relayerCount() external view returns (uint256) {
        return _active.length;
    }

    /// @notice Up to `count` active operators from index `start`. Order changes on deregistration.
    function relayersPage(uint256 start, uint256 count) external view returns (address[] memory page) {
        uint256 len = _active.length;
        if (start >= len) return new address[](0);
        uint256 end = len - start < count ? len : start + count;
        page = new address[](end - start);
        for (uint256 i = start; i < end; ++i) {
            page[i - start] = _active[i];
        }
    }

    /// @notice Fee in note units of an active operator for one asset: the flat fee where the asset has
    ///         one, since every proof must pay exactly that, otherwise the operator's own. Zero means
    ///         not served.
    function feeOf(address operator, uint64 assetId) external view returns (uint256) {
        if (!_relayers[operator].active) return 0;
        (bool flat, uint256 units) = pool.relayFee(assetId);
        return flat ? units : _fees[operator][registrations[operator]][assetId];
    }

    /// @notice The record of one operator, active or exiting.
    function relayerOf(address operator) external view returns (Relayer memory) {
        return _relayers[operator];
    }

    function _requireActive() private view returns (Relayer storage r) {
        r = _relayers[msg.sender];
        if (!r.active) revert NotActive();
    }

    function _checkEndpoint(string calldata endpoint) private pure {
        uint256 n = bytes(endpoint).length;
        if (n == 0 || n > MAX_ENDPOINT_BYTES) revert BadEndpoint();
    }

    // The cap is read at set time. The pool refuses a fee over its current cap at settlement.
    function _setFees(uint64[] calldata assetIds, uint256[] calldata fees) private {
        if (assetIds.length != fees.length) revert LengthMismatch();
        uint256 reg = registrations[msg.sender];
        for (uint256 i = 0; i < assetIds.length; ++i) {
            (bool flat, uint256 cap) = pool.relayFee(assetIds[i]);
            if (flat) revert FlatFeeAsset(assetIds[i]);
            if (fees[i] > cap) revert FeeAboveCap(assetIds[i], fees[i], cap);
            _fees[msg.sender][reg][assetIds[i]] = fees[i];
            emit FeeSet(msg.sender, assetIds[i], fees[i]);
        }
    }
}
