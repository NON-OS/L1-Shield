// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {Goldilocks} from "./libraries/Goldilocks.sol";

/// @notice The pool view the policy reads, to refuse a setting for an asset that does not exist.
interface IAssetCount {
    function nextAssetId() external view returns (uint64);
}

/// @title AmountPolicy
/// @notice The public amounts and fees the pool accepts, per asset. Every deposit and withdrawal must be
///         1, 2 or 5 times 10^k note units, with k inside the asset's range. Amounts and fees then stop
///         naming the people and wallets that use them.
///
///         Fees come in two forms. The launch form is one flat relay fee per asset, read by `check`. The
///         schedule form, read by `settlementFee` and `depositFee`, splits every settlement fee in two:
///         a protocol part, which is a flat fee on a private transfer and a percentage of the public
///         amount on a withdrawal, and a gas part, which is exactly one rung of a four-rung ladder when
///         the proof names someone to submit it, and nothing when its sender submits it. A deposit pays a
///         percentage of its amount. Every value is the same for everyone at a given moment, so a fee
///         names no one. The two percentages hold for every asset. The flat fee and the ladder are set per
///         asset, since each asset has its own units.
/// @dev Fails closed: an asset with no range, or with no schedule, can be neither deposited nor settled
///      through the schedule form. The first range and the first schedule of an asset are set at once,
///      since nothing could use the asset before them. Every later change, the percentages included,
///      waits CHANGE_DELAY after it is announced, is accepted from the announcement so a proof made for
///      it lands when it takes effect, and the value it replaces still settles for GRACE after, so a
///      proof made before the switch still lands. Created by the pool in its constructor, so the pool is
///      fixed here, and owned by its owner.
///
///      It also holds the pool's containment lever. A verifier or circuit fault must be containable, so
///      a guardian named by the owner, or the owner, may pause every deposit and settlement at once. A
///      pause is bounded: it ends by itself after PAUSE_DURATION, the owner may extend it once by
///      EXTENSION through EXTEND_DELAY, and the next pause waits PAUSE_COOLDOWN after the last one
///      ended, so no one can hold the pool shut for good and every holder gets a window to exit.
contract AmountPolicy is Ownable2Step {
    /// @notice Largest exponent a range may reach. MAX_VALUE is below 2 x 10^19 units.
    uint8 public constant MAX_EXP = 19;
    /// @notice Time from announcing a change of range, fee or schedule until it can take effect.
    uint256 public constant CHANGE_DELAY = 48 hours;
    /// @notice Time after a change takes effect during which the value it replaced still settles.
    uint256 public constant GRACE = 1 hours;
    /// @notice Largest deposit or withdrawal fee, in basis points: 1%.
    uint16 public constant MAX_BPS = 100;
    /// @notice The denominator of every basis-point figure.
    uint256 public constant BPS = 10_000;
    /// @notice Rungs in the gas ladder.
    uint256 public constant RUNGS = 4;

    /// @notice How long a pause lasts unless the owner ends it sooner or extends it.
    uint256 public constant PAUSE_DURATION = 7 days;
    /// @notice What the one extension a pause may have adds to it.
    uint256 public constant EXTENSION = 7 days;
    /// @notice Time from the owner announcing an extension until it can take effect.
    uint256 public constant EXTEND_DELAY = 48 hours;
    /// @notice Time after a pause ends before the next one may begin: every holder's window to exit.
    uint256 public constant PAUSE_COOLDOWN = 7 days;

    /// @notice The pool that consults this policy.
    IAssetCount public immutable pool;

    /// @notice The rule in force for an asset. `ranged` is false until its first range is set.
    struct Rule {
        uint64 fee;
        uint8 minExp;
        uint8 maxExp;
        bool ranged;
    }

    /// @notice An announced change. `eta` is zero when none is pending.
    struct Pending {
        uint64 fee;
        uint8 minExp;
        uint8 maxExp;
        uint64 eta;
    }

    /// @notice The flat fee a change replaced, which still settles until `until`.
    struct Grace {
        uint64 fee;
        uint64 until;
    }

    mapping(uint64 assetId => Rule) public rules;
    mapping(uint64 assetId => Pending) public pending;
    mapping(uint64 assetId => Grace) public grace;

    /// @notice An asset's fee schedule, in note units. `set` is false until the first one is given.
    /// @dev The ladder is strictly increasing with rung 0 above zero, so each rung names one gas price
    ///      band and a gas part matches at most one rung.
    struct Schedule {
        uint64 protocolFee; // the protocol part of a private transfer's fee, flat
        uint64[4] ladder; // the gas part of a relayed settlement is exactly one of these
        bool set;
    }

    /// @notice An announced schedule and when it may take effect. `eta` is zero when none is pending.
    struct PendingSchedule {
        Schedule schedule;
        uint64 eta;
    }

    /// @notice The schedule a change replaced, which still settles until `until`.
    struct GraceSchedule {
        Schedule schedule;
        uint64 until;
    }

    /// @notice The deposit and withdrawal percentages, in basis points, for every asset.
    struct Bps {
        uint16 deposit; // of a deposit's amount
        uint16 withdraw; // of a withdrawal's public amount: the protocol part of its fee
    }

    /// @notice Announced percentages and when they may take effect. `eta` is zero when none are pending.
    struct PendingBps {
        Bps bps;
        uint64 eta;
    }

    /// @notice The percentages a change replaced, which still settle until `until`.
    struct GraceBps {
        Bps bps;
        uint64 until;
    }

    mapping(uint64 assetId => Schedule) internal _schedules;
    mapping(uint64 assetId => PendingSchedule) internal _pendingSchedules;
    mapping(uint64 assetId => GraceSchedule) internal _graceSchedules;

    /// @notice The percentages in force.
    Bps public bps;
    /// @notice The announced percentages, if any.
    PendingBps public pendingBps;
    /// @notice The percentages in grace, if any.
    GraceBps public graceBps;

    /// @notice The state of the containment lever, in one slot so `check` reads it once.
    /// @dev `until` is when the current or last pause ends, zero if there never was one.
    ///      `extensionEta` is when the announced extension may take effect, zero if none is.
    ///      `extended` is set once the owner announces an extension, and cleared by the next pause.
    ///      `ownerHeld` is set when the owner paused or announced an extension: the guardian may then no
    ///      longer end the pause, so a guardian key cannot reopen what the owner chose to hold.
    struct Pause {
        uint64 until;
        uint64 extensionEta;
        bool extended;
        bool ownerHeld;
    }

    /// @notice Who may pause at once, beside the owner. Zero when there is none.
    address public guardian;
    /// @notice The current or last pause.
    Pause public pause;

    event RangeSet(uint64 indexed assetId, uint8 minExp, uint8 maxExp, uint256 fee);
    event RangeQueued(uint64 indexed assetId, uint8 minExp, uint8 maxExp, uint256 fee, uint64 eta);
    event RangeCancelled(uint64 indexed assetId);
    event RangeActivated(uint64 indexed assetId, uint8 minExp, uint8 maxExp, uint256 fee, uint64 graceUntil);
    event ScheduleSet(uint64 indexed assetId, uint64 protocolFee, uint64[4] ladder);
    event ScheduleQueued(uint64 indexed assetId, uint64 protocolFee, uint64[4] ladder, uint64 eta);
    event ScheduleCancelled(uint64 indexed assetId);
    event ScheduleActivated(uint64 indexed assetId, uint64 protocolFee, uint64[4] ladder, uint64 graceUntil);
    event BpsSet(uint16 depositBps, uint16 withdrawBps);
    event BpsQueued(uint16 depositBps, uint16 withdrawBps, uint64 eta);
    event BpsCancelled();
    event BpsActivated(uint16 depositBps, uint16 withdrawBps, uint64 graceUntil);
    event GuardianSet(address indexed previous, address indexed guardian);
    event Paused(address indexed by, uint64 until);
    event Unpaused(address indexed by);
    event ExtensionQueued(uint64 eta);
    event Extended(uint64 until);

    error UnknownAsset();
    error LengthMismatch();
    error AlreadyRanged();
    error NotRanged();
    error BadRange();
    error FeeOutOfRange();
    error NothingPending();
    error TooEarly(uint64 eta);
    error NonStandardAmount();
    error FeeNotFlat();
    error NotGuardian();
    error IsPaused(uint64 until);
    error NotPaused();
    error CoolingDown(uint64 until);
    error AlreadyExtended();
    error ExtensionTooLate();
    error BpsTooHigh();
    error BadSchedule();
    error NoSchedule();
    error AlreadyScheduled();
    error FeeBelowProtocolPart(uint256 fee, uint256 protocolPart);
    error FeeNotOnLadder(uint256 gasPart);
    error GasPartWithoutSubmitter(uint256 gasPart);

    /// @param depositBps_ The deposit percentage, at most MAX_BPS.
    /// @param withdrawBps_ The withdrawal percentage, at most MAX_BPS.
    constructor(address owner_, uint16 depositBps_, uint16 withdrawBps_) Ownable(owner_) {
        pool = IAssetCount(msg.sender);
        _requireValidBps(depositBps_, withdrawBps_);
        bps = Bps(depositBps_, withdrawBps_);
        emit BpsSet(depositBps_, withdrawBps_);
    }

    // -- ranges and the flat fee --------------------------------------------------------------

    /// @notice Sets the first range and flat fee of each listed asset, at once. An asset that already
    ///         has one is refused: its changes go through `queueRange`.
    function initRanges(
        uint64[] calldata assetIds,
        uint8[] calldata minExps,
        uint8[] calldata maxExps,
        uint256[] calldata fees
    ) external onlyOwner {
        uint256 n = assetIds.length;
        if (minExps.length != n || maxExps.length != n || fees.length != n) revert LengthMismatch();
        for (uint256 i = 0; i < n; ++i) {
            uint64 id = assetIds[i];
            _requireAsset(id);
            if (rules[id].ranged) revert AlreadyRanged();
            _requireValid(minExps[i], maxExps[i], fees[i]);
            rules[id] = Rule(uint64(fees[i]), minExps[i], maxExps[i], true);
            emit RangeSet(id, minExps[i], maxExps[i], fees[i]);
        }
    }

    /// @notice Announces a new range and flat fee for an asset, effective CHANGE_DELAY from now. The new
    ///         fee settles from this moment; the new range only once activated. Replaces any change
    ///         already pending, and restarts its delay.
    function queueRange(uint64 assetId, uint8 minExp, uint8 maxExp, uint256 fee) external onlyOwner {
        if (!rules[assetId].ranged) revert NotRanged();
        _requireValid(minExp, maxExp, fee);
        uint64 eta = uint64(block.timestamp + CHANGE_DELAY);
        pending[assetId] = Pending(uint64(fee), minExp, maxExp, eta);
        emit RangeQueued(assetId, minExp, maxExp, fee, eta);
    }

    /// @notice Withdraws a pending change.
    function cancelRange(uint64 assetId) external onlyOwner {
        if (pending[assetId].eta == 0) revert NothingPending();
        delete pending[assetId];
        emit RangeCancelled(assetId);
    }

    /// @notice Puts a pending change in force once its delay has passed. Anyone may call it.
    function activateRange(uint64 assetId) external {
        Pending memory p = pending[assetId];
        if (p.eta == 0) revert NothingPending();
        if (block.timestamp < p.eta) revert TooEarly(p.eta);
        uint64 until = uint64(block.timestamp + GRACE);
        grace[assetId] = Grace(rules[assetId].fee, until);
        rules[assetId] = Rule(p.fee, p.minExp, p.maxExp, true);
        delete pending[assetId];
        emit RangeActivated(assetId, p.minExp, p.maxExp, p.fee, until);
    }

    /// @notice The flat fee in force, in units: zero for an asset with no range.
    function maxRelayFee(uint64 assetId) external view virtual returns (uint256) {
        return rules[assetId].fee;
    }

    /// @notice What the relayer registry reads: whether the asset's fee is flat, and the fee a
    ///         relayer charges, or may charge at most when it is not.
    function relayFee(uint64 assetId) external view virtual returns (bool flat, uint256 units) {
        Rule memory r = rules[assetId];
        return (r.ranged, r.fee);
    }

    /// @notice Whether `units` is a standard amount of the asset in force. Nothing is while the asset
    ///         has no range, and zero never is.
    function isStandard(uint64 assetId, uint256 units) external view returns (bool) {
        Rule memory r = rules[assetId];
        return r.ranged && _standard(r, units);
    }

    /// @notice The launch pool's check of one public amount and its fee, in units. A deposit passes its
    ///         amount and no fee, an intent its public amount and fee. Reverts on a refusal. A zero
    ///         amount is a private transfer's, which is not public and not checked.
    /// @dev Unchanged, for pools built on the flat fee. A pool built on the schedule calls
    ///      `settlementFee` and `depositFee` instead.
    function check(uint64 assetId, uint256 publicAmount, uint256 fee) external view virtual {
        uint64 until = pause.until;
        if (block.timestamp < until) revert IsPaused(until);
        Rule memory r = rules[assetId];
        if (!r.ranged) revert NotRanged();
        if (publicAmount != 0 && !_standard(r, publicAmount)) revert NonStandardAmount();
        if (fee == 0 || fee == r.fee) return;
        // one fee for everyone, with the announced fee and the replaced one as the only overlaps
        Pending memory p = pending[assetId];
        if (p.eta != 0 && fee == p.fee) return;
        Grace memory g = grace[assetId];
        if (block.timestamp < g.until && fee == g.fee) return;
        revert FeeNotFlat();
    }

    // -- the fee schedule -----------------------------------------------------------------------

    /// @notice Sets the first protocol fee and gas ladder of each listed asset, at once. The asset must
    ///         already have a range. An asset that already has a schedule is refused: its changes go
    ///         through `queueSchedule`.
    function initSchedules(uint64[] calldata assetIds, uint64[] calldata protocolFees, uint64[4][] calldata ladders)
        external
        onlyOwner
    {
        uint256 n = assetIds.length;
        if (protocolFees.length != n || ladders.length != n) revert LengthMismatch();
        for (uint256 i = 0; i < n; ++i) {
            uint64 id = assetIds[i];
            if (!rules[id].ranged) revert NotRanged();
            if (_schedules[id].set) revert AlreadyScheduled();
            _requireValidSchedule(protocolFees[i], ladders[i]);
            _schedules[id] = Schedule(protocolFees[i], ladders[i], true);
            emit ScheduleSet(id, protocolFees[i], ladders[i]);
        }
    }

    /// @notice Announces a new protocol fee and gas ladder for an asset, effective CHANGE_DELAY from now.
    ///         Fees on the new schedule settle from this moment. Replaces any schedule already pending,
    ///         and restarts its delay.
    function queueSchedule(uint64 assetId, uint64 protocolFee, uint64[4] calldata ladder) external onlyOwner {
        if (!_schedules[assetId].set) revert NoSchedule();
        _requireValidSchedule(protocolFee, ladder);
        uint64 eta = uint64(block.timestamp + CHANGE_DELAY);
        _pendingSchedules[assetId] = PendingSchedule(Schedule(protocolFee, ladder, true), eta);
        emit ScheduleQueued(assetId, protocolFee, ladder, eta);
    }

    /// @notice Withdraws a pending schedule.
    function cancelSchedule(uint64 assetId) external onlyOwner {
        if (_pendingSchedules[assetId].eta == 0) revert NothingPending();
        delete _pendingSchedules[assetId];
        emit ScheduleCancelled(assetId);
    }

    /// @notice Puts a pending schedule in force once its delay has passed. Anyone may call it. The
    ///         schedule it replaces still settles for GRACE.
    function activateSchedule(uint64 assetId) external {
        PendingSchedule memory p = _pendingSchedules[assetId];
        if (p.eta == 0) revert NothingPending();
        if (block.timestamp < p.eta) revert TooEarly(p.eta);
        uint64 until = uint64(block.timestamp + GRACE);
        _graceSchedules[assetId] = GraceSchedule(_schedules[assetId], until);
        _schedules[assetId] = p.schedule;
        delete _pendingSchedules[assetId];
        emit ScheduleActivated(assetId, p.schedule.protocolFee, p.schedule.ladder, until);
    }

    /// @notice Announces new deposit and withdrawal percentages, for every asset, effective
    ///         CHANGE_DELAY from now. Withdrawals on the new percentage settle from this moment.
    ///         Replaces any change already pending, and restarts its delay.
    function queueBps(uint16 depositBps_, uint16 withdrawBps_) external onlyOwner {
        _requireValidBps(depositBps_, withdrawBps_);
        uint64 eta = uint64(block.timestamp + CHANGE_DELAY);
        pendingBps = PendingBps(Bps(depositBps_, withdrawBps_), eta);
        emit BpsQueued(depositBps_, withdrawBps_, eta);
    }

    /// @notice Withdraws pending percentages.
    function cancelBps() external onlyOwner {
        if (pendingBps.eta == 0) revert NothingPending();
        delete pendingBps;
        emit BpsCancelled();
    }

    /// @notice Puts pending percentages in force once their delay has passed. Anyone may call it. The
    ///         withdrawal percentage they replace still settles for GRACE.
    function activateBps() external {
        PendingBps memory p = pendingBps;
        if (p.eta == 0) revert NothingPending();
        if (block.timestamp < p.eta) revert TooEarly(p.eta);
        uint64 until = uint64(block.timestamp + GRACE);
        graceBps = GraceBps(bps, until);
        bps = p.bps;
        delete pendingBps;
        emit BpsActivated(p.bps.deposit, p.bps.withdraw, until);
    }

    /// @notice The pool's one call for an intent. Refuses while paused, for an asset with no range or no
    ///         schedule, and for a public amount that is not standard (zero is a private transfer's, which
    ///         is not public and not checked). Then splits the fee into its protocol part and its gas part.
    ///         `relayed` is true when the proof names someone to submit it: the fee is then the protocol
    ///         part plus exactly one ladder rung. Otherwise the fee is the protocol part alone.
    /// @dev Every pairing of a schedule (in force, pending, in grace) with a withdrawal percentage (in
    ///      force, pending, in grace) that exists is tried, in force first, and the first that accepts the
    ///      fee decides the split. A fee none accepts is refused with the reason of the values in force.
    function settlementFee(uint64 assetId, uint256 publicAmount, uint256 fee, bool relayed)
        external
        view
        virtual
        returns (uint256 protocolPart, uint256 gasPart)
    {
        Rule memory r = _openRule(assetId);
        if (publicAmount != 0 && !_standard(r, publicAmount)) revert NonStandardAmount();
        Schedule[] memory schedules = _settlingSchedules(assetId);
        // a private transfer's protocol part is the flat fee, so only a withdrawal reads a percentage
        uint16[] memory rates = _settlingWithdrawBps(publicAmount != 0);
        return _match(schedules, rates, publicAmount, fee, relayed);
    }

    /// @notice The pool's one call for a deposit. Refuses while paused, for an asset with no range or no
    ///         schedule, and for an amount that is not standard. Returns the fee, in units, that the
    ///         deposit percentage in force takes from the amount, rounded down.
    function depositFee(uint64 assetId, uint256 amount) external view virtual returns (uint256) {
        Rule memory r = _openRule(assetId);
        if (!_standard(r, amount)) revert NonStandardAmount();
        if (!_schedules[assetId].set) revert NoSchedule();
        return (amount * bps.deposit) / BPS;
    }

    /// @notice The schedule in force for an asset.
    function scheduleOf(uint64 assetId) external view returns (Schedule memory) {
        return _schedules[assetId];
    }

    /// @notice The pending schedule for an asset and when it may take effect, zero if none.
    function pendingScheduleOf(uint64 assetId) external view returns (Schedule memory schedule, uint64 eta) {
        PendingSchedule memory p = _pendingSchedules[assetId];
        return (p.schedule, p.eta);
    }

    /// @notice The schedule in grace for an asset and when its grace ends, zero if none ever was.
    function graceScheduleOf(uint64 assetId) external view returns (Schedule memory schedule, uint64 until) {
        GraceSchedule memory g = _graceSchedules[assetId];
        return (g.schedule, g.until);
    }

    // -- containment ----------------------------------------------------------------------

    /// @notice Names who may pause beside the owner, or no one with the zero address.
    function setGuardian(address guardian_) external onlyOwner {
        emit GuardianSet(guardian, guardian_);
        guardian = guardian_;
    }

    /// @notice Refuses every deposit and settlement for PAUSE_DURATION, starting now. The guardian or
    ///         the owner may call it, but not while a pause runs, nor within PAUSE_COOLDOWN of the end
    ///         of the last one.
    function pausePool() external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        uint64 last = pause.until;
        if (block.timestamp < last) revert IsPaused(last);
        if (last != 0 && block.timestamp < last + PAUSE_COOLDOWN) revert CoolingDown(uint64(last + PAUSE_COOLDOWN));
        uint64 until = uint64(block.timestamp + PAUSE_DURATION);
        pause = Pause(until, 0, false, msg.sender == owner());
        emit Paused(msg.sender, until);
    }

    /// @notice Ends the running pause now, which starts the cooldown. The owner may always. The
    ///         guardian may end only a pause it began and the owner has not extended.
    function unpausePool() external {
        Pause memory p = pause;
        if (block.timestamp >= p.until) revert NotPaused();
        if (msg.sender != owner() && (msg.sender != guardian || p.ownerHeld)) revert NotGuardian();
        pause = Pause(uint64(block.timestamp), 0, p.extended, p.ownerHeld);
        emit Unpaused(msg.sender);
    }

    /// @notice Announces the one extension a pause may have. It takes effect EXTEND_DELAY from now,
    ///         which must fall while the pause still runs, so a lapsed pause is never revived.
    function queueExtension() external onlyOwner {
        Pause memory p = pause;
        if (block.timestamp >= p.until) revert NotPaused();
        if (p.extended) revert AlreadyExtended();
        uint64 eta = uint64(block.timestamp + EXTEND_DELAY);
        if (eta >= p.until) revert ExtensionTooLate();
        pause = Pause(p.until, eta, true, true);
        emit ExtensionQueued(eta);
    }

    /// @notice Puts the announced extension in force once its delay has passed, while the pause still
    ///         runs. Anyone may call it.
    function extendPause() external {
        Pause memory p = pause;
        if (p.extensionEta == 0) revert NothingPending();
        if (block.timestamp >= p.until) revert NotPaused();
        if (block.timestamp < p.extensionEta) revert TooEarly(p.extensionEta);
        uint64 until = uint64(p.until + EXTENSION);
        pause = Pause(until, 0, true, true);
        emit Extended(until);
    }

    /// @notice Whether deposits and settlements are refused right now.
    function paused() external view returns (bool) {
        return block.timestamp < pause.until;
    }

    /// @dev The rule of an asset that may be used now: not paused, and ranged.
    function _openRule(uint64 assetId) private view returns (Rule memory r) {
        uint64 until = pause.until;
        if (block.timestamp < until) revert IsPaused(until);
        r = rules[assetId];
        if (!r.ranged) revert NotRanged();
    }

    /// @dev The schedules that settle now, in force first: in force, then pending, then in grace.
    function _settlingSchedules(uint64 assetId) private view returns (Schedule[] memory out) {
        Schedule memory sc = _schedules[assetId];
        if (!sc.set) revert NoSchedule();
        PendingSchedule memory ps = _pendingSchedules[assetId];
        GraceSchedule memory gs = _graceSchedules[assetId];
        bool hasPending = ps.eta != 0;
        bool hasGrace = block.timestamp < gs.until;
        out = new Schedule[](1 + (hasPending ? 1 : 0) + (hasGrace ? 1 : 0));
        uint256 n = 0;
        out[n++] = sc;
        if (hasPending) out[n++] = ps.schedule;
        if (hasGrace) out[n] = gs.schedule;
    }

    /// @dev The withdrawal percentages that settle now, in force first. Only the one in force when
    ///      `withdrawal` is false, since a private transfer does not read it.
    function _settlingWithdrawBps(bool withdrawal) private view returns (uint16[] memory out) {
        PendingBps memory pb = pendingBps;
        GraceBps memory gb = graceBps;
        bool hasPending = withdrawal && pb.eta != 0;
        bool hasGrace = withdrawal && block.timestamp < gb.until;
        out = new uint16[](1 + (hasPending ? 1 : 0) + (hasGrace ? 1 : 0));
        uint256 n = 0;
        out[n++] = bps.withdraw;
        if (hasPending) out[n++] = pb.bps.withdraw;
        if (hasGrace) out[n] = gb.bps.withdraw;
    }

    /// @dev The first pairing of schedule and percentage that accepts `fee` decides the split. None
    ///      accepting it, the reason of the values in force is given.
    function _match(Schedule[] memory schedules, uint16[] memory rates, uint256 publicAmount, uint256 fee, bool relayed)
        private
        pure
        returns (uint256 protocolPart, uint256 gasPart)
    {
        for (uint256 i = 0; i < schedules.length; ++i) {
            for (uint256 j = 0; j < rates.length; ++j) {
                bool ok;
                (ok, protocolPart, gasPart) = _split(schedules[i], rates[j], publicAmount, fee, relayed);
                if (ok) return (protocolPart, gasPart);
            }
        }
        _refuse(schedules[0], rates[0], publicAmount, fee, relayed);
    }

    /// @dev The protocol part under a schedule and a withdrawal percentage: the flat fee for a private
    ///      transfer, the percentage of the public amount, rounded down, for a withdrawal.
    function _protocolPart(Schedule memory sc, uint16 withdrawBps, uint256 publicAmount)
        private
        pure
        returns (uint256)
    {
        return publicAmount == 0 ? sc.protocolFee : (publicAmount * withdrawBps) / BPS;
    }

    /// @dev Whether `fee` fits the schedule and percentage, and its split if it does.
    function _split(Schedule memory sc, uint16 withdrawBps, uint256 publicAmount, uint256 fee, bool relayed)
        private
        pure
        returns (bool ok, uint256 protocolPart, uint256 gasPart)
    {
        protocolPart = _protocolPart(sc, withdrawBps, publicAmount);
        if (fee < protocolPart) return (false, 0, 0);
        gasPart = fee - protocolPart;
        if (!relayed) return (gasPart == 0, protocolPart, gasPart);
        for (uint256 i = 0; i < RUNGS; ++i) {
            if (gasPart == sc.ladder[i]) return (true, protocolPart, gasPart);
        }
        return (false, 0, 0);
    }

    /// @dev Reverts with the reason the values in force refuse `fee`.
    function _refuse(Schedule memory sc, uint16 withdrawBps, uint256 publicAmount, uint256 fee, bool relayed)
        private
        pure
    {
        uint256 protocolPart = _protocolPart(sc, withdrawBps, publicAmount);
        if (fee < protocolPart) revert FeeBelowProtocolPart(fee, protocolPart);
        if (!relayed) revert GasPartWithoutSubmitter(fee - protocolPart);
        revert FeeNotOnLadder(fee - protocolPart);
    }

    /// @dev 1, 2 or 5 times 10^k, with k inside the rule's range.
    function _standard(Rule memory r, uint256 units) private pure returns (bool) {
        uint256 k;
        while (units != 0 && units % 10 == 0) {
            units /= 10;
            ++k;
        }
        return (units == 1 || units == 2 || units == 5) && k >= r.minExp && k <= r.maxExp;
    }

    function _requireValid(uint8 minExp, uint8 maxExp, uint256 fee) private pure {
        if (minExp > maxExp || maxExp > MAX_EXP) revert BadRange();
        if (fee > Goldilocks.MAX_VALUE) revert FeeOutOfRange();
    }

    /// @dev Rung 0 above zero, rungs strictly increasing, and the largest fee a private transfer can
    ///      carry within one public limb.
    function _requireValidSchedule(uint64 protocolFee, uint64[4] calldata ladder) private pure {
        if (ladder[0] == 0) revert BadSchedule();
        for (uint256 i = 1; i < RUNGS; ++i) {
            if (ladder[i] <= ladder[i - 1]) revert BadSchedule();
        }
        if (uint256(protocolFee) + ladder[RUNGS - 1] > Goldilocks.MAX_VALUE) revert FeeOutOfRange();
    }

    function _requireValidBps(uint16 depositBps_, uint16 withdrawBps_) private pure {
        if (depositBps_ > MAX_BPS || withdrawBps_ > MAX_BPS) revert BpsTooHigh();
    }

    function _requireAsset(uint64 assetId) private view {
        if (assetId >= pool.nextAssetId()) revert UnknownAsset();
    }
}
