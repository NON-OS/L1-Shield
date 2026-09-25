// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {ShieldedPool} from "../../../contracts/shield/ShieldedPool.sol";
import {SettlerGate} from "../../../contracts/shield/SettlerGate.sol";
import {Goldilocks} from "../../../contracts/shield/libraries/Goldilocks.sol";
import {IStarkVerifier} from "../../../contracts/shield/interfaces/IStarkVerifier.sol";
import {PublicWords} from "../../../contracts/shield/verifier/PublicWords.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPoseidonGoldilocks} from "../mocks/MockPoseidonGoldilocks.sol";
import {AssociationSetRegistry} from "../../../contracts/shield/AssociationSetRegistry.sol";
import {IPoseidonGoldilocks} from "../../../contracts/shield/interfaces/IPoseidonGoldilocks.sol";

/// A verifier whose answer the handler sets. The pool's accounting must hold whatever it says,
/// so the handler drives both answers and checks that a refusal leaves no trace.
contract HandlerVerifier is IStarkVerifier {
    bool public accept = true;

    function setAccept(bool a) external {
        accept = a;
    }

    function verifyBatch(bytes calldata, uint256[] calldata) external view returns (bool) {
        return accept;
    }
}

/// A fee router that can be told to refuse native value, so the pool has to hold the fee in
/// unsweptFees. Held fees are a liability the solvency invariant must count.
contract SwitchableFeeSink {
    bool public refusing;

    function setRefusing(bool r) external {
        refusing = r;
    }

    receive() external payable {
        if (refusing) revert("refused");
    }
}

/// A settlement recipient with no receive function. Every native payout to it bounces and becomes
/// a claimable credit, which is the other liability the pool holds on top of totalShielded.
contract BouncingRecipient {
    function claimTo(ShieldedPool pool, uint64 assetId, address to) external {
        pool.claim(assetId, to);
    }
}

/// Deploys a pool whose constructor self-test passes with the mock hasher and an accepting verifier.
abstract contract PoolDeploy is Test {
    /// Registers an asset as the pool owner.
    function _registerAsset(ShieldedPool pool, address owner, address token, uint256 unitScale)
        internal
        returns (uint64 id)
    {
        vm.prank(owner);
        id = pool.registerAsset(token, unitScale);
    }

    /// Native value counts in wei, scale 1. The pool reads IntentWords.WORDS words per intent.
    function _deployPool(address safe, HandlerVerifier v, MockPoseidonGoldilocks h, AssociationSetRegistry r, address sink)
        internal
        returns (ShieldedPool)
    {
        ShieldedPool.DeploymentSelfTest memory st;
        st.hash2Left = bytes32(uint256(1));
        st.hash2Right = bytes32(uint256(2));
        st.hash2Expected = h.hash2(st.hash2Left, st.hash2Right);
        st.fieldsInput = new uint256[](3);
        st.fieldsInput[0] = 1;
        st.fieldsInput[1] = 2;
        st.fieldsInput[2] = 3;
        st.fieldsExpected = h.hashFields(st.fieldsInput);
        st.proof = hex"00";
        st.proofPublicInputs = new uint256[](11);
        st.noteValue = 1000;
        st.noteOwnerCommit = h.hash2(bytes32(uint256(7)), bytes32(uint256(8)));
        st.noteCommitmentExpected =
            h.hash2(bytes32(uint256(1000) | (uint256(0x4E4F5445) << 192)), st.noteOwnerCommit);
        return new ShieldedPool(
            safe,
            IStarkVerifier(address(v)),
            IPoseidonGoldilocks(address(h)),
            r,
            sink,
            25,
            25,
            1,
            IntentWords.WORDS,
            st
        );
    }
}

/// One intent as the model sees it, independent of how the pool lays it out in public words.
struct ModelIntent {
    bytes32 noteRoot;
    bytes32 assocRoot;
    bytes32 nf0;
    bytes32 nf1;
    bytes32 outCm0;
    bytes32 outCm1;
    uint256 publicAmount;
    uint256 fee;
    uint64 assetId;
    uint256 clearingPrice;
    address recipient;
    address feeRecipient;
}

/// The pool's public-word layout. The word count comes from PublicWords, which the pool and the
/// verifier also read.
library IntentWords {
    uint256 internal constant WORDS = PublicWords.INTENT_WORDS_FEE_RECIPIENT;

    function encode(ModelIntent[] memory its) internal pure returns (uint256[] memory w) {
        w = new uint256[](its.length * WORDS);
        for (uint256 j = 0; j < its.length; ++j) {
            uint256 o = j * WORDS;
            ModelIntent memory it = its[j];
            w[o] = uint256(it.noteRoot);
            w[o + 1] = uint256(it.assocRoot);
            w[o + 2] = uint256(it.nf0);
            w[o + 3] = uint256(it.nf1);
            w[o + 4] = uint256(it.outCm0);
            w[o + 5] = uint256(it.outCm1);
            w[o + 6] = it.publicAmount;
            w[o + 7] = it.fee;
            w[o + 8] = it.assetId;
            w[o + 9] = it.clearingPrice;
            w[o + 10] = uint256(uint160(it.recipient));
            w[o + 11] = uint256(uint160(it.feeRecipient));
        }
    }
}

/// Drives the pool through deposits, settlements, root commits, refunds, fee and pause changes,
/// settler rotation and time. Each action checks its expected outcome and counts disagreements.
/// The model holds the notes an honest prover could open, and an intent spends only live notes.
/// With a sound proof system those are the only batches the pool sees, so "no value from nothing"
/// is a statement about the pool and not about the mock verifier.
contract PoolHandler is Test {
    ShieldedPool public immutable pool;
    HandlerVerifier public immutable verifier;
    MockERC20 public immutable usd;
    SwitchableFeeSink public immutable feeSink;
    BouncingRecipient public immutable bouncer;
    address public immutable safe;
    bytes32 public immutable assocRoot;
    uint64 public immutable usdId;

    address[] internal actors;
    address public immutable outsider; // never on the beta allowlist
    address[3] internal settlerChoices;

    struct Note {
        uint64 asset;
        uint256 value;
        address depositor; // zero for a settlement output
        bool spent;
    }

    Note[] internal notes;
    uint256 internal digestCounter;

    // a depositor whose own deposit note a settlement spent. Refunding such a depositor shifts
    // value from the others, as KnownIssues.t.sol shows. It cannot make the pool insolvent, so
    // the handler issues it like any other refund.
    mapping(address depositor => mapping(uint64 asset => bool)) public depositNoteSpent;

    // the ledger a correct pool must reproduce: deposits net of fee, minus each unshield's public
    // amount and fee, minus what each beta refund paid
    mapping(uint64 asset => uint256) public ghostShielded;
    uint256 public ghostLeaves;

    // one counter per property, so a failure names the property it broke
    uint256 public gateViolations;
    uint256 public nullifierViolations;
    uint256 public treeViolations;
    uint256 public feeCapViolations;
    uint256 public windDownViolations;
    uint256 public pauseViolations;
    uint256 public proofViolations;
    uint256 public unexpectedReverts;
    bytes4 public lastUnexpected;
    string public lastUnexpectedWhere;

    // coverage, read by the report test and printed in the run summary
    uint256 public absorbAttempts;
    uint256 public okAbsorbs;
    uint256 public okSettles;
    uint256 public okIntents;
    uint256 public okUnshields;
    uint256 public okRefunds;
    uint256 public okCommits;
    uint256 public okClaims;
    uint256 public okSweeps;
    uint256 public refusedByGate;
    uint256 public settledInOpenSlotByStranger;
    uint256 public refusedReplays;
    uint256 public refusedProofs;
    uint256 public refusedOverCapFees;
    uint256 public refusedAfterWindDown;

    uint40 internal lastLeafCount;

    constructor(
        ShieldedPool pool_,
        HandlerVerifier verifier_,
        MockERC20 usd_,
        SwitchableFeeSink sink_,
        address safe_,
        bytes32 assocRoot_,
        uint64 usdId_,
        address[] memory actors_,
        address settlerA,
        address settlerB,
        address outsider_
    ) {
        pool = pool_;
        verifier = verifier_;
        usd = usd_;
        feeSink = sink_;
        safe = safe_;
        assocRoot = assocRoot_;
        usdId = usdId_;
        actors = actors_;
        settlerChoices = [address(0), settlerA, settlerB];
        bouncer = new BouncingRecipient();
        outsider = outsider_;
    }

    // ------------------------------------------------------------------ actions

    /// Deposits `units` note units of one asset. One call in eight comes from an outsider who is
    /// not on the beta allowlist, and one in eight offers an amount that is not a whole number of
    /// units. Both have a single correct outcome the handler checks.
    function absorb(uint256 actorSeed, bool native, uint256 units) external {
        uint64 asset = native ? 0 : usdId;
        uint256 s = pool.scale(asset);
        units = bound(units, 1, 1e12);
        bool fromOutsider = actorSeed % 8 == 7;
        bool ragged = s > 1 && (actorSeed >> 8) % 8 == 7;
        address actor = fromOutsider ? outsider : actors[actorSeed % actors.length];
        uint256 amount = units * s + (ragged ? 1 : 0);
        bytes32 owner = _digest();
        absorbAttempts++;

        bool paused = pool.depositsPaused();
        bool wound = pool.betaWoundDown();
        bool betaGate = pool.betaMode() && pool.betaPaused();
        bool allowlistGate = pool.betaMode() && !pool.openDeposits() && fromOutsider;
        uint16 bps = pool.shieldFeeBps();

        vm.prank(actor);
        try pool.absorb{value: native ? amount : 0}(asset, amount, owner) {
            if (paused || betaGate || allowlistGate) pauseViolations++;
            if (wound) windDownViolations++;
            if (ragged) unexpectedReverts++; // a remainder would back no note
            uint256 valueUnits = units - (units * bps) / 10_000;
            ghostShielded[asset] += valueUnits * s;
            ghostLeaves += 1;
            notes.push(Note(asset, valueUnits, actor, false));
            okAbsorbs++;
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (paused && sel == ShieldedPool.DepositsArePaused.selector) return;
            if (wound && sel == ShieldedPool.BetaIsWoundDown.selector) {
                refusedAfterWindDown++;
                return;
            }
            if (ragged && sel == ShieldedPool.InvalidAmount.selector) return;
            if (betaGate && sel == ShieldedPool.BetaIsPaused.selector) return;
            if (allowlistGate && sel == ShieldedPool.NotBetaDepositor.selector) return;
            _unexpected(sel, "absorb");
        }
        _checkTree();
    }

    function setOpenDeposits(bool open) external {
        vm.prank(safe);
        pool.setOpenDeposits(open);
    }

    struct Attempt {
        address caller;
        address settler;
        bool gateOpen;
        bool wound;
        bool inSlot;
        bool overCap;
        bool refuseProof;
    }

    /// Settles 1 to 3 intents, each spending up to two live notes of one asset. `shape` picks the
    /// caller, whether the verifier refuses, and whether one intent names a fee above the cap.
    function settle(uint256 seed, uint256 shape) external {
        Batch memory bt = _buildBatch(seed, 1 + (seed % 3), shape % 7 == 3);
        uint256[] memory w = IntentWords.encode(bt.its);
        Attempt memory at;
        at.overCap = overCapApplied;
        at.refuseProof = shape % 11 == 5;
        at.caller = _pickCaller(shape >> 8);
        at.gateOpen = _gateOpen(at.caller);
        at.wound = pool.betaWoundDown();
        at.inSlot = SettlerGate.inOpenSlot(block.timestamp, 24 hours, 1 hours);
        at.settler = pool.settler();

        if (at.refuseProof) verifier.setAccept(false);
        vm.prank(at.caller);
        try pool.settleBatch(hex"00", w, _noResidual(), "", new bytes[](2 * bt.its.length)) {
            if (at.wound) windDownViolations++;
            if (!at.gateOpen) gateViolations++;
            if (at.refuseProof) proofViolations++; // a refused proof must never settle
            if (at.overCap) feeCapViolations++;
            _recordSettled(bt);
            if (at.inSlot && at.settler != address(0) && at.caller != at.settler) settledInOpenSlotByStranger++;
        } catch (bytes memory err) {
            _classifySettleRevert(at, bytes4(err), bt.its[0].nf0);
        }
        if (at.refuseProof) verifier.setAccept(true);
        _checkTree();
    }

    function _classifySettleRevert(Attempt memory at, bytes4 sel, bytes32 firstNullifier) internal {
        if (at.wound) {
            if (sel == ShieldedPool.BetaIsWoundDown.selector) refusedAfterWindDown++;
            else windDownViolations++;
        } else if (!at.gateOpen) {
            if (sel == ShieldedPool.NotSettler.selector) refusedByGate++;
            else gateViolations++;
        } else if (at.overCap && sel == ShieldedPool.FeeExceedsCap.selector) {
            refusedOverCapFees++;
        } else if (at.refuseProof && sel == ShieldedPool.InvalidProof.selector) {
            refusedProofs++;
            // the refusal rolled back every nullifier the batch would have spent
            if (pool.nullifierSpent(firstNullifier)) nullifierViolations++;
        } else {
            // an open gate, a live pool, an honest batch: this must settle
            _unexpected(sel, "settle");
        }
    }

    /// Re-submits a nullifier that is already spent, alone or twice in one batch. Both must fail
    /// with NullifierAlreadySpent, or with BetaIsWoundDown once the pool is closed.
    function replaySpent(uint256 seed, bool twiceInOneBatch) external {
        bytes32 nf;
        if (twiceInOneBatch) {
            nf = _digest();
        } else {
            uint256 len = notes.length;
            if (len == 0) return;
            uint256 start = seed % len;
            bool found;
            for (uint256 k = 0; k < len; ++k) {
                uint256 i = (start + k) % len;
                if (settledNote[i]) {
                    nf = _nullifierOf(i);
                    found = pool.nullifierSpent(nf);
                    if (found) break;
                }
            }
            if (!found) return;
        }
        uint256 m = twiceInOneBatch ? 2 : 1;
        ModelIntent[] memory its = new ModelIntent[](m);
        for (uint256 j = 0; j < m; ++j) {
            its[j] = _privateIntent(nf, _digest());
        }
        uint256[] memory w = IntentWords.encode(its);
        address caller = _openCaller();
        bool wound = pool.betaWoundDown();
        vm.prank(caller);
        try pool.settleBatch(hex"00", w, _noResidual(), "", new bytes[](2 * m)) {
            nullifierViolations++;
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            if (wound) {
                if (sel != ShieldedPool.BetaIsWoundDown.selector) windDownViolations++;
            } else if (sel == ShieldedPool.NullifierAlreadySpent.selector) {
                refusedReplays++;
            } else {
                nullifierViolations++;
            }
        }
        _checkTree();
    }

    function commitRoot() external {
        if (pool.nextLeafIndex() == 0) return;
        try pool.commitRoot() returns (bytes32 root) {
            if (!pool.isKnownRoot(root) || pool.currentRoot() != root) treeViolations++;
            okCommits++;
        } catch (bytes memory err) {
            _unexpected(bytes4(err), "commitRoot");
        }
        _checkTree();
    }

    /// A beta refund by any depositor with a recorded deposit. Rare, since the first refund closes
    /// the pool for the rest of the run.
    function betaRefund(uint256 actorSeed, bool native, uint256 rarity) external {
        if (rarity % 16 != 0) return;
        address actor = actors[actorSeed % actors.length];
        uint64 asset = native ? 0 : usdId;
        if (!pool.betaMode()) return;
        if (pool.betaRefundable(asset, actor) == 0) return;

        vm.prank(actor);
        try pool.betaRefund(asset, actor) returns (uint256 amount) {
            // a refund reduces the shielded total by the amount it pays
            ghostShielded[asset] -= amount;
            // the refunded notes stay in the tree but can never be spent: the pool is wound down
            for (uint256 i = 0; i < notes.length; ++i) {
                if (notes[i].depositor == actor && notes[i].asset == asset) notes[i].spent = true;
            }
            okRefunds++;
        } catch (bytes memory err) {
            _unexpected(bytes4(err), "betaRefund");
        }
    }

    function setFees(uint16 shieldBps, uint16 unshieldBps) external {
        shieldBps = uint16(bound(shieldBps, 0, 80)); // about a third of the draws land above the cap
        unshieldBps = uint16(bound(unshieldBps, 0, 80));
        bool over = shieldBps > 50 || unshieldBps > 50;
        vm.prank(safe);
        try pool.setFeeBps(shieldBps, unshieldBps) {
            if (over) feeCapViolations++;
        } catch (bytes memory err) {
            if (!over || bytes4(err) != ShieldedPool.FeeBpsTooHigh.selector) _unexpected(bytes4(err), "setFeeBps");
        }
    }

    /// Pauses land a quarter of the time each, so deposits stay open for most of a run.
    function setPauses(uint256 seed) external {
        bool deposits = seed % 4 == 0;
        bool beta = (seed >> 8) % 4 == 0;
        vm.startPrank(safe);
        pool.setDepositsPaused(deposits);
        bool wound = pool.betaWoundDown();
        try pool.setBetaPaused(beta) {
            if (!beta && wound) windDownViolations++; // resuming a wound-down pool must be refused
        } catch (bytes memory err) {
            if (!(!beta && wound && bytes4(err) == ShieldedPool.BetaIsWoundDown.selector)) {
                _unexpected(bytes4(err), "setBetaPaused");
            }
        }
        vm.stopPrank();
    }

    function endBeta(uint256 rarity) external {
        if (rarity % 12 != 0 || !pool.betaMode()) return;
        bool wound = pool.betaWoundDown();
        vm.prank(safe);
        try pool.endBetaMode() {
            if (wound) windDownViolations++;
        } catch (bytes memory err) {
            if (!(wound && bytes4(err) == ShieldedPool.BetaIsWoundDown.selector)) _unexpected(bytes4(err), "endBeta");
        }
    }

    function rotateSettler(uint256 seed) external {
        address next = settlerChoices[seed % 3];
        vm.prank(safe);
        pool.proposeSettler(next);
        vm.warp(block.timestamp + pool.SETTLER_DELAY());
        pool.executeSettlerChange();
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 30 hours));
    }

    /// Lands somewhere inside the next open slot, the last hour of a 24-hour epoch.
    function warpIntoOpenSlot(uint256 offset) external {
        uint256 t = block.timestamp;
        uint256 start = t - (t % 24 hours) + 23 hours;
        if (start <= t) start += 24 hours;
        vm.warp(start + bound(offset, 0, 1 hours - 1));
    }

    function setFeeSinkRefusing(bool r) external {
        feeSink.setRefusing(r);
    }

    function sweepFees(bool native) external {
        uint64 asset = native ? 0 : usdId;
        if (pool.unsweptFees(asset) == 0 || feeSink.refusing()) return;
        try pool.sweepFees(asset) {
            okSweeps++;
        } catch (bytes memory err) {
            _unexpected(bytes4(err), "sweepFees");
        }
    }

    /// An actor collects a credit, from a named fee or a refused payout, to itself.
    function claimCredit(uint256 actorSeed, bool native) external {
        address actor = actors[actorSeed % actors.length];
        uint64 asset = native ? 0 : usdId;
        if (pool.claimable(asset, actor) == 0) return;
        vm.prank(actor);
        try pool.claim(asset, actor) {
            okClaims++;
        } catch (bytes memory err) {
            _unexpected(bytes4(err), "claimCredit");
        }
    }

    function claimBounced(uint256 actorSeed) external {
        if (pool.claimable(0, address(bouncer)) == 0) return;
        try bouncer.claimTo(pool, 0, actors[actorSeed % actors.length]) {
            okClaims++;
        } catch (bytes memory err) {
            _unexpected(bytes4(err), "claim");
        }
    }

    // ------------------------------------------------------------------ views for the invariants

    function noteCount() external view returns (uint256) {
        return notes.length;
    }

    function liveNoteValue(uint64 asset) external view returns (uint256 sum) {
        for (uint256 i = 0; i < notes.length; ++i) {
            if (!notes[i].spent && notes[i].asset == asset) sum += notes[i].value;
        }
    }

    /// Every note the model has spent carries a nullifier the pool records as spent.
    function everySpentNoteIsMarked() external view returns (bool) {
        for (uint256 i = 0; i < notes.length; ++i) {
            if (settledNote[i] && !pool.nullifierSpent(_nullifierOf(i))) return false;
        }
        return true;
    }

    // ------------------------------------------------------------------ internals

    // notes spent by a settlement, as opposed to notes closed by a refund, which have no nullifier
    mapping(uint256 => bool) internal settledNote;
    bool internal overCapApplied;

    struct Batch {
        ModelIntent[] its;
        uint256[] picked; // note indices the batch spends
        uint256 pickedCount;
        uint256[] outs; // output note values, two per intent
    }

    function _buildBatch(uint256 seed, uint256 n, bool overCap) internal returns (Batch memory bt) {
        bt.its = new ModelIntent[](n);
        bt.picked = new uint256[](2 * n);
        bt.outs = new uint256[](2 * n);
        overCapApplied = false;
        for (uint256 j = 0; j < n; ++j) {
            seed = uint256(keccak256(abi.encode(seed, j)));
            (uint256 a, uint256 b, uint64 asset, uint256 inValue) = _pickInputs(seed, bt.picked, bt.pickedCount);
            ModelIntent memory it = _privateIntent(bytes32(0), bytes32(0));
            if (a != type(uint256).max) bt.picked[bt.pickedCount++] = a;
            if (b != type(uint256).max) bt.picked[bt.pickedCount++] = b;
            it.nf0 = a != type(uint256).max ? _nullifierOf(a) : _digest();
            it.nf1 = b != type(uint256).max ? _nullifierOf(b) : _digest();
            it.assetId = asset;
            _setPublicLeg(it, seed, inValue, overCap && j == 0);
            // an over-cap intent may ask for more than its inputs. It is refused before any debit.
            uint256 debit = _debitUnits(it);
            uint256 rest = inValue > debit ? inValue - debit : 0;
            bt.outs[2 * j] = rest / 2;
            bt.outs[2 * j + 1] = rest - rest / 2;
            bt.its[j] = it;
        }
    }

    function _setPublicLeg(ModelIntent memory it, uint256 seed, uint256 inValue, bool overCap) internal {
        // the fee comes on top of publicAmount, so both must fit inside the spent notes
        uint256 pub = (seed >> 16) % 3 == 0 ? 0 : bound(seed >> 32, 0, (inValue * 10_000) / 10_050);
        if (pub > 0) {
            uint256 cap = (pub * 50) / 10_000;
            it.publicAmount = pub;
            it.fee = bound(seed >> 96, 0, cap);
            if (overCap) {
                it.fee = cap + 1;
                overCapApplied = true;
            }
            // a named fee recipient is credited, never pushed. One fee in three goes that way.
            if (it.fee > 0 && (seed >> 160) % 3 == 0) it.feeRecipient = actors[(seed >> 168) % actors.length];
            // a bouncing recipient on native legs half the time, to exercise the credit path
            it.recipient = (it.assetId == 0 && (seed >> 128) % 2 == 0)
                ? address(bouncer)
                : actors[(seed >> 136) % actors.length];
        } else if (overCap && inValue > 0) {
            // no public leg to carry a fee: shape it as a one-unit unshield with a one-unit fee
            it.publicAmount = 1;
            it.fee = 1;
            it.recipient = actors[0];
            overCapApplied = true;
        }
    }

    /// Units one intent takes out of the shielded total: the recipient's publicAmount and the fee
    /// on top of it. This is the pool's settlement rule, stated once for the model.
    function _debitUnits(ModelIntent memory it) internal pure returns (uint256) {
        return it.publicAmount == 0 ? 0 : it.publicAmount + it.fee;
    }

    // up to two live notes of one asset, never one this batch already picked
    function _pickInputs(uint256 seed, uint256[] memory picked, uint256 pickedCount)
        internal
        view
        returns (uint256 a, uint256 b, uint64 asset, uint256 inValue)
    {
        a = type(uint256).max;
        b = type(uint256).max;
        asset = (seed & 1) == 0 ? 0 : usdId;
        uint256 len = notes.length;
        if (len == 0) return (a, b, asset, 0);
        uint256 start = (seed >> 8) % len;
        for (uint256 k = 0; k < len; ++k) {
            uint256 i = (start + k) % len;
            Note storage nt = notes[i];
            if (nt.spent || nt.asset != asset || _in(picked, pickedCount, i)) continue;
            if (a == type(uint256).max) {
                a = i;
                inValue = nt.value;
                if ((seed >> 200) % 2 == 0) break; // half the intents spend one real note
            } else {
                b = i;
                inValue += nt.value;
                break;
            }
        }
    }

    function _recordSettled(Batch memory bt) internal {
        ModelIntent[] memory its = bt.its;
        uint256[] memory outs = bt.outs;
        uint256 n = its.length;
        for (uint256 k = 0; k < bt.pickedCount; ++k) {
            Note storage nt = notes[bt.picked[k]];
            nt.spent = true;
            settledNote[bt.picked[k]] = true;
            if (nt.depositor != address(0)) depositNoteSpent[nt.depositor][nt.asset] = true;
        }
        for (uint256 j = 0; j < n; ++j) {
            uint64 asset = its[j].assetId;
            if (its[j].publicAmount > 0) {
                ghostShielded[asset] -= _debitUnits(its[j]) * pool.scale(asset);
                okUnshields++;
            }
            notes.push(Note(asset, outs[2 * j], address(0), false));
            notes.push(Note(asset, outs[2 * j + 1], address(0), false));
        }
        ghostLeaves += 2 * n;
        okSettles++;
        okIntents += n;
    }

    /// A private transfer shape: fresh outputs, no public leg, spending the given nullifiers
    /// against the current root.
    function _privateIntent(bytes32 nf0, bytes32 nf1) internal returns (ModelIntent memory it) {
        it.noteRoot = pool.currentRoot();
        it.assocRoot = assocRoot;
        it.nf0 = nf0;
        it.nf1 = nf1;
        it.outCm0 = _digest();
        it.outCm1 = _digest();
    }

    function _gateOpen(address caller) internal view returns (bool) {
        address s = pool.settler();
        if (s == address(0) || caller == s) return true;
        if (block.timestamp >= uint256(pool.lastSettlement()) + 24 hours) return true;
        return SettlerGate.inOpenSlot(block.timestamp, 24 hours, 1 hours);
    }

    function _pickCaller(uint256 s) internal view returns (address) {
        if (s % 3 == 0 && pool.settler() != address(0)) return pool.settler();
        return actors[s % actors.length];
    }

    function _openCaller() internal view returns (address) {
        address s = pool.settler();
        return s == address(0) ? actors[0] : s;
    }

    function _checkTree() internal {
        uint40 now_ = pool.nextLeafIndex();
        if (now_ < lastLeafCount) treeViolations++;
        if (uint256(now_) != ghostLeaves) treeViolations++;
        lastLeafCount = now_;
    }

    function _unexpected(bytes4 sel, string memory where) internal {
        unexpectedReverts++;
        lastUnexpected = sel;
        lastUnexpectedWhere = where;
    }

    function _nullifierOf(uint256 i) internal pure returns (bytes32) {
        return _canon(keccak256(abi.encode("model-nullifier", i)));
    }

    function _digest() internal returns (bytes32) {
        return _canon(keccak256(abi.encode("model-digest", ++digestCounter)));
    }

    function _in(uint256[] memory xs, uint256 len, uint256 x) internal pure returns (bool) {
        for (uint256 k = 0; k < len; ++k) {
            if (xs[k] == x) return true;
        }
        return false;
    }

    function _noResidual() internal pure returns (ShieldedPool.ResidualExec memory r) {
        r.path = new address[](0);
    }

    function _canon(bytes32 h) internal pure returns (bytes32 out) {
        uint256 v = uint256(h);
        uint256 acc;
        for (uint256 i = 0; i < 4; ++i) {
            acc |= (((v >> (64 * i)) & 0xFFFFFFFFFFFFFFFF) % Goldilocks.P) << (64 * i);
        }
        out = bytes32(acc);
    }

    receive() external payable {}
}
