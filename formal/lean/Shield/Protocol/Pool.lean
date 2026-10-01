/-
Copyright (c) 2026 NØNOS. All rights reserved.

# The shielded pool as a state machine

A model of the accounting of `ShieldedPool` (contracts/shield/ShieldedPool.sol), with the arithmetic
of `ShieldLedger` (contracts/shield/ShieldLedger.sol) and the balance-delta accounting of
`BatchClearing.routeResidual` (contracts/shield/BatchClearing.sol:31-62). Line numbers refer to the
contracts in this repository (the launch pool: per-asset unit scale, `MAX_VALUE = p - 2`, an optional
twelfth word `feeRecipient` whose fee is credited, pro-rata `betaRefund`, `openDeposits`).

Each public entry point is a function `State → Option State`: `none` is a revert. Every choice the
environment makes is an explicit argument: how much of a push actually arrives (`_pushToken`
returns the unpaid part, ShieldedPool.sol:868-875), what a DEX router delivers, and what the
verifier answers. The verifier is an abstract oracle `V : Proof → List Intent → Bool`, and the
relation it is meant to enforce is the hypothesis `Sound V`, stated with `Conserves`: the notes
inside an accepted intent conserve value.

Ghost state. `surplus a` counts value that entered the pool with no liability (a plain transfer or
`receive()`, and a same-asset residual swap, which the model admits and the contract refuses).
`noteValue a` is the net value of notes minted
minus notes spent, as the witnesses declare it. Neither is read by any transition.

Main results, for every reachable state and every asset `a`.
* `conservation` (a): `bal a = totalShielded a + totalClaimable a + unsweptFees a + surplus a`.
  `solvent`: the pool always holds at least its liabilities.
* `nullifier_once` (b): the list of nullifiers spent along any run has no duplicates.
* `fee_caps`, `absorb_fee_le`, `settle_fee_le` (c): fees stay within their caps.
* `woundDown_final` (d): after wind-down, no `absorb` and no `settleBatch` succeeds, forever.
* `leafCount_mono` (e): the leaf count never decreases.
* `shielded_eq_notes`: under `Sound V`, `totalShielded` equals the net note value along runs
  without a residual swap or a refund.
* `legacy_refund_breaks_solvency`: a refund that floors `totalShielded` at zero can leave the pool
  holding less than its liabilities. The contract's pro-rata refund cannot (`refund_safe_on_witness`).
-/
import Mathlib.Logic.Function.Basic
import Mathlib.Tactic.NormNum
import Mathlib.Tactic.Ring
import Shield.Protocol.SettlerGate

namespace Shield.Protocol.Pool

open Function

/-- Asset ids, `uint64 assetId`. `0` is native (`NATIVE_ASSET_ID`, ShieldedPool.sol:89). -/
abbrev Asset := ℕ
/-- Addresses. `address(0)` is `0`. -/
abbrev Addr := ℕ
/-- Nullifiers, `bytes32`. -/
abbrev Nullifier := ℕ
/-- Proof bytes. -/
abbrev Proof := List ℕ

/-- `BPS = 10_000` (ShieldedPool.sol:76). -/
abbrev BPS : ℕ := 10000
/-- `MAX_FEE_BPS = 50` (ShieldedPool.sol:75). -/
abbrev MAX_FEE_BPS : ℕ := 50
/-- `MAX_BAND_BPS = 1_000` (ShieldedPool.sol:77). -/
abbrev MAX_BAND_BPS : ℕ := 1000
/-- `MAX_INTENTS = 64` (ShieldedPool.sol:90). -/
abbrev MAX_INTENTS : ℕ := 64
/-- `MAX_LEAVES = 2^32 - 1` (GoldilocksIncrementalTree.sol:14). -/
abbrev MAX_LEAVES : ℕ := 2 ^ 32 - 1

/-- Deployment parameters. -/
structure Params where
  /-- `scale[assetId]` (ShieldedPool.sol:134), base units per note unit, fixed at registration. -/
  scale : Asset → ℕ
  /-- A registered scale is at least one (ShieldedPool.sol:285,318). -/
  scale_pos : ∀ a, 0 < scale a
  /-- `Goldilocks.MAX_VALUE = p - 2` (Goldilocks.sol:10). -/
  maxValue : ℕ
  /-- `wordsPerIntent = 12` (ShieldedPool.sol:94): the intent carries a `feeRecipient` word. -/
  hasFeeRecipient : Bool

/-- Unit scale, `MAX_VALUE = p - 2`, eleven words. -/
def Params.unit : Params := ⟨fun _ => 1, fun _ => Nat.one_pos, 0xFFFFFFFF00000001 - 2, false⟩

/-- The storage the invariants speak about, plus two ghost variables. -/
structure State where
  /-- The pool's holdings of each asset: `address(this).balance`, or `balanceOf(address(this))`. -/
  bal : Asset → ℕ
  /-- `totalShielded` (ShieldedPool.sol:131). -/
  totalShielded : Asset → ℕ
  /-- `claimable` (ShieldedPool.sol:104). -/
  claimable : Asset → Addr → ℕ
  /-- `totalClaimable` (ShieldedPool.sol:107). -/
  totalClaimable : Asset → ℕ
  /-- `unsweptFees` (ShieldedPool.sol:110). -/
  unsweptFees : Asset → ℕ
  /-- `nullifierSpent` (ShieldedPool.sol:127). -/
  spent : Nullifier → Bool
  /-- `nextLeafIndex` (GoldilocksIncrementalTree.sol:25). -/
  leafCount : ℕ
  /-- `betaMode` (ShieldedPool.sol:145). -/
  betaMode : Bool
  /-- `betaWoundDown` (ShieldedPool.sol:169). -/
  woundDown : Bool
  /-- `betaRefundable` (ShieldedPool.sol:159). -/
  refundable : Asset → Addr → ℕ
  /-- `betaRefundableTotal` (ShieldedPool.sol:162). -/
  refundableTotal : Asset → ℕ
  /-- `refundAssets` (ShieldedPool.sol:165). -/
  refundAssets : Asset → ℕ
  /-- `refundBase` (ShieldedPool.sol:166). -/
  refundBase : Asset → ℕ
  /-- `shieldFeeBps` (ShieldedPool.sol:97). -/
  shieldFeeBps : ℕ
  /-- `unshieldFeeBps` (ShieldedPool.sol:98). -/
  unshieldFeeBps : ℕ
  /-- `residualBandBps` (ShieldedPool.sol:100). -/
  residualBandBps : ℕ
  /-- `settler` (ShieldedPool.sol:119). -/
  settler : Addr
  /-- `lastSettlement` (ShieldedPool.sol:122). -/
  lastSettlement : ℕ
  /-- Ghost: value received with no liability. -/
  surplus : Asset → ℕ
  /-- Ghost: net value of notes minted minus notes spent, in base units. -/
  noteValue : Asset → ℤ

/-- One intent's public words, decoded (`Intent`, ShieldedPool.sol:32-45), plus two witness-side
ghost fields. The roots, commitments and clearing price do not enter the accounting. -/
structure Intent where
  /-- `nf0`. -/
  nf0 : Nullifier
  /-- `nf1`. -/
  nf1 : Nullifier
  /-- `publicAmount`, in units. -/
  publicAmount : ℕ
  /-- `fee`, in units, spent on top of `publicAmount`. -/
  fee : ℕ
  /-- `assetId`. -/
  asset : Asset
  /-- `recipient`. -/
  recipient : Addr
  /-- `feeRecipient`. Zero sends the fee to the fee router. -/
  feeRecipient : Addr
  /-- Ghost: total value of the two input notes, in units. -/
  inValue : ℕ
  /-- Ghost: total value of the two output notes, in units. -/
  outValue : ℕ

/-- The settler-chosen residual swap (`ResidualExec`, ShieldedPool.sol:48-56), with `received`,
the amount the router actually delivers, chosen by the environment. -/
structure Residual where
  /-- `assetIn`. -/
  assetIn : Asset
  /-- `assetOut`. -/
  assetOut : Asset
  /-- `amountIn`, in base units. `0` skips the residual (ShieldedPool.sol:750). -/
  amountIn : ℕ
  /-- Tokens delivered by the router. -/
  received : ℕ

/-- **The relation R.** Conservation of the notes inside an intent: the inputs pay for the
outputs, the public amount and the fee (ShieldedPool.sol:729, "the circuit spends public_amount
+ fee"). -/
def Conserves (it : Intent) : Prop := it.inValue = it.outValue + it.publicAmount + it.fee

/-- **Soundness of the verifier oracle**, the hypothesis under which R may be used: every intent of
an accepted batch satisfies R. -/
def Sound (V : Proof → List Intent → Bool) : Prop :=
  ∀ π its, V π its = true → ∀ it ∈ its, Conserves it

/-! ## Primitive updates -/

/-- `f[a] += x`. -/
def bump (f : Asset → ℕ) (a : Asset) (x : ℕ) : Asset → ℕ := update f a (f a + x)

/-- `f[a] -= x`, truncated. Every use is guarded. -/
def drop (f : Asset → ℕ) (a : Asset) (x : ℕ) : Asset → ℕ := update f a (f a - x)

/-- Pointwise value of `bump`. -/
@[simp] theorem bump_apply (f : Asset → ℕ) (a x b : ℕ) :
    bump f a x b = f b + if b = a then x else 0 := by
  unfold bump; by_cases h : b = a
  · subst h; simp
  · simp [h]

/-- Pointwise value of `drop`. -/
@[simp] theorem drop_apply (f : Asset → ℕ) (a x b : ℕ) :
    drop f a x b = if b = a then f b - x else f b := by
  unfold drop; by_cases h : b = a
  · subst h; simp
  · simp [h]

/-- The part of a push that arrives: what the environment reports, at most the amount and at most
what the pool holds. -/
def arrived (s : State) (a : Asset) (amount paid : ℕ) : ℕ := min paid (min amount (s.bal a))

/-- `_credit` (ShieldedPool.sol:838-843). -/
def credit (s : State) (a : Asset) (dest : Addr) (amount : ℕ) : State :=
  { s with
    claimable := update s.claimable a (update (s.claimable a) dest (s.claimable a dest + amount))
    totalClaimable := bump s.totalClaimable a amount }

/-- `_payFee` (ShieldedPool.sol:906-920): a push to the fee router. What does not arrive is held
in `unsweptFees`. The native push is all or nothing, a special case of `paid`. -/
def payFee (s : State) (a : Asset) (amount paid : ℕ) : State :=
  if amount = 0 then s
  else { s with
    bal := drop s.bal a (arrived s a amount paid)
    unsweptFees := bump s.unsweptFees a (amount - arrived s a amount paid) }

/-- `_payOrCredit` (ShieldedPool.sol:827-836): a push. What does not arrive is credited. -/
def payOrCredit (s : State) (a : Asset) (dest : Addr) (amount paid : ℕ) : State :=
  if amount = 0 then s
  else credit { s with bal := drop s.bal a (arrived s a amount paid) } a dest
    (amount - arrived s a amount paid)

/-- `_payOut` (ShieldedPool.sol:934-942): a transfer that reverts on failure. -/
def payOut (s : State) (a : Asset) (amount : ℕ) : Option State :=
  if amount ≤ s.bal a then some { s with bal := drop s.bal a amount } else none

/-- `_reduceShielded` with `ShieldLedger.debit` (ShieldedPool.sol:799-803, ShieldLedger.sol:24-27). -/
def reduceShielded (s : State) (a : Asset) (amount : ℕ) : Option State :=
  if amount ≤ s.totalShielded a then some { s with totalShielded := drop s.totalShielded a amount }
  else none

/-! ## Entry points -/

variable (P : Params) (V : Proof → List Intent → Bool)

/-- `ShieldLedger.splitDeposit` (ShieldLedger.sol:10-13): `(fee, value)`. -/
def splitDeposit (amount feeBps : ℕ) : ℕ × ℕ :=
  (amount * feeBps / BPS, amount - amount * feeBps / BPS)

/-- The note value `absorb` mints, in units (ShieldedPool.sol:363). -/
def valueUnits (s : State) (units : ℕ) : ℕ := (splitDeposit units s.shieldFeeBps).2

/-- The storage writes of `absorb` before the fee is paid (ShieldedPool.sol:353-375). -/
def absorbCore (s : State) (a : Asset) (amount : ℕ) (sender : Addr) : State :=
  let value := valueUnits s (amount / P.scale a) * P.scale a                 -- line 365
  { s with
    bal := bump s.bal a amount                                               -- lines 353-360
    refundable := if s.betaMode then                                         -- line 368
      update s.refundable a (update (s.refundable a) sender (s.refundable a sender + value))
      else s.refundable
    refundableTotal := if s.betaMode then bump s.refundableTotal a value     -- line 369
      else s.refundableTotal
    leafCount := s.leafCount + 1                                             -- line 374
    totalShielded := bump s.totalShielded a value                            -- line 375
    noteValue := update s.noteValue a (s.noteValue a + value) }

/-- `absorb` (ShieldedPool.sol:336-380). `amount`, in base units, is what the pool receives:
`msg.value`, or the exact balance delta of `safeTransferFrom` (lines 353-360). `feePaid` is the part
of the fee push that arrives. -/
def absorb (s : State) (a : Asset) (amount : ℕ) (sender : Addr) (feePaid : ℕ) : Option State :=
  if s.woundDown then none                                                   -- line 344
  else if amount / P.scale a = 0 ∨ P.maxValue < amount / P.scale a ∨
      amount % P.scale a ≠ 0 then none                                       -- line 349
  else if valueUnits s (amount / P.scale a) = 0 then none                    -- line 364
  else if MAX_LEAVES ≤ s.leafCount then none                                 -- tree, line 104
  else some (payFee (absorbCore P s a amount sender) a
    ((splitDeposit (amount / P.scale a) s.shieldFeeBps).1 * P.scale a) feePaid)  -- line 379

/-- The range and consistency checks of `_decodeIntent` on the accounting fields
(ShieldedPool.sol:667-713). The clause `publicAmount = 0 → fee = 0` is stricter than the contract,
which admits a relay fee up to `maxRelayFee[assetId]` there (line 708). -/
def DecodeOk (it : Intent) : Prop :=
  it.publicAmount ≤ P.maxValue ∧ it.fee ≤ P.maxValue ∧                        -- lines 682,685
    (P.hasFeeRecipient = false → it.feeRecipient = 0) ∧                      -- line 696
    it.nf0 ≠ it.nf1 ∧                                                        -- line 701
    (it.feeRecipient ≠ 0 → it.fee ≠ 0) ∧                                     -- line 703
    (it.publicAmount = 0 → it.fee = 0 ∧ it.recipient = 0) ∧                  -- lines 706-708
    (it.publicAmount ≠ 0 →
      it.fee * BPS ≤ it.publicAmount * MAX_FEE_BPS ∧ it.recipient ≠ 0)       -- lines 710-711

instance (it : Intent) : Decidable (DecodeOk P it) := by unfold DecodeOk; infer_instance

/-- The nullifiers of a batch, in the order `settleBatch` spends them (ShieldedPool.sol:418-419). -/
def nullifiers (its : List Intent) : List Nullifier := its.flatMap fun it => [it.nf0, it.nf1]

/-- `_spend` (ShieldedPool.sol:715-719). -/
def spend (s : State) (nf : Nullifier) : Option State :=
  if s.spent nf then none else some { s with spent := update s.spent nf true }

/-- `_spend` over a list, in order. -/
def spendList : State → List Nullifier → Option State
  | s, [] => some s
  | s, nf :: ns => (spend s nf).bind (spendList · ns)

/-- The fee credit of the first loop (ShieldedPool.sol:736). -/
def feeCredit (s : State) (it : Intent) : State :=
  if it.feeRecipient = 0 then s else credit s it.asset it.feeRecipient (it.fee * P.scale it.asset)

/-- The first loop of `_settleIntents` (ShieldedPool.sol:726-738). -/
def debitAll : State → List Intent → Option State
  | s, [] => some s
  | s, it :: its =>
    if it.publicAmount = 0 then debitAll s its                                          -- line 728
    else (reduceShielded s it.asset ((it.publicAmount + it.fee) * P.scale it.asset)).bind
      fun t => debitAll (feeCredit P t it) its                                          -- 733-736

/-- The public leg of one intent in the second loop (ShieldedPool.sol:742-743). -/
def payOne (s : State) (it : Intent) (paid feePaid : ℕ) : State :=
  if it.publicAmount = 0 then s
  else
    let t := payOrCredit s it.asset it.recipient (it.publicAmount * P.scale it.asset) paid
    if it.feeRecipient = 0 then payFee t it.asset (it.fee * P.scale it.asset) feePaid else t

/-- The second loop of `_settleIntents` (ShieldedPool.sol:739-744). -/
def payAll : State → List Intent → (Intent → ℕ) → (Intent → ℕ) → State
  | s, [], _, _ => s
  | s, it :: its, paid, feePaid => payAll (payOne P s it (paid it) (feePaid it)) its paid feePaid

/-- The swap of `BatchClearing.routeResidual` (BatchClearing.sol:31-62) and the credit at
ShieldedPool.sol:781. `amountOut` is the balance delta of `assetOut` across the swap. The model
admits `assetIn = assetOut`, which the contract refuses (`SameAssetResidual`, line 755). For an
ERC-20 that delta is `received - amountIn`, and a native one reverts (BatchClearing.sol:33). -/
def swap (s : State) (r : Residual) : Option State :=
  if s.bal r.assetIn < r.amountIn then none
  else if r.assetIn ≠ r.assetOut then
    some { s with
      bal := bump (drop s.bal r.assetIn r.amountIn) r.assetOut r.received
      totalShielded := bump s.totalShielded r.assetOut r.received }
  else if r.assetIn = 0 ∨ r.received < r.amountIn then none
  else
    some { s with
      bal := bump (drop s.bal r.assetIn r.amountIn) r.assetIn r.received
      totalShielded := bump s.totalShielded r.assetIn (r.received - r.amountIn)
      surplus := bump s.surplus r.assetIn r.amountIn }

/-- `_settleResidual` (ShieldedPool.sol:749-788). The slippage band is not modelled, and the whole
`received` is credited to `totalShielded`, where the contract moves the sub-unit dust to
`unsweptFees` (lines 780-785). -/
def residualStep (s : State) (r : Residual) : Option State :=
  if r.amountIn = 0 then some s                                               -- line 750
  else if r.amountIn % P.scale r.assetIn ≠ 0 then none                        -- line 757
  else (reduceShielded s r.assetIn r.amountIn).bind (swap · r)                -- lines 767-781

/-- The ghost update of the note ledger for a batch: outputs minted, inputs spent. -/
def noteDelta (its : List Intent) (a : Asset) : ℤ :=
  (its.map fun it => if a = it.asset then
    ((it.outValue : ℤ) - it.inValue) * P.scale it.asset else 0).sum

/-- The leaf insertion of `settleBatch` (ShieldedPool.sol:430-434), with the ghost note update. -/
def insertOutputs (s : State) (its : List Intent) : State :=
  { s with
    leafCount := s.leafCount + 2 * its.length
    noteValue := fun a => s.noteValue a + noteDelta P its a }

/-- `settleBatch` after the nullifiers are spent (ShieldedPool.sol:430-444). -/
def settleCore (s : State) (its : List Intent) (r : Residual) (paid feePaid : Intent → ℕ) :
    Option State :=
  if MAX_LEAVES < s.leafCount + 2 * its.length then none                    -- tree, line 146
  else (debitAll P (insertOutputs P s its) its).bind fun s₃ =>               -- line 443
    residualStep P (payAll P s₃ its paid feePaid) r                          -- line 444

/-- `settleBatch` (ShieldedPool.sol:386-447). The model asks the verifier before the nullifier
writes and the contract asks it after them (line 424). It is a `view` call and a revert undoes both,
so the order does not change the outcome. -/
def settle (s : State) (caller now : ℕ) (π : Proof) (its : List Intent) (r : Residual)
    (paid feePaid : Intent → ℕ) : Option State :=
  if s.woundDown then none                                                      -- line 393
  else if !SettlerGate.passes s.settler caller s.lastSettlement now then none   -- lines 395-398
  else if its.length = 0 ∨ MAX_INTENTS < its.length then none                   -- lines 401-404
  else if ¬ ∀ it ∈ its, DecodeOk P it then none                                 -- line 410
  else if !V π its then none                                                    -- line 424
  else (spendList { s with lastSettlement := now } (nullifiers its)).bind       -- lines 399,418
    (settleCore P · its r paid feePaid)

/-- `claim` (ShieldedPool.sol:847-855). -/
def claim (s : State) (a : Asset) (caller dest : Addr) : Option State :=
  if dest = 0 ∨ s.claimable a caller = 0 then none
  else if s.totalClaimable a < s.claimable a caller then none          -- checked, line 852
  else payOut { s with
    claimable := update s.claimable a (update (s.claimable a) caller 0)
    totalClaimable := drop s.totalClaimable a (s.claimable a caller) } a (s.claimable a caller)

/-- `sweepFees` (ShieldedPool.sol:924-932). -/
def sweepFees (s : State) (a : Asset) : Option State :=
  if s.unsweptFees a = 0 then none
  else payOut { s with unsweptFees := update s.unsweptFees a 0 } a (s.unsweptFees a)

/-- The storage writes of `betaRefund` before the debit (ShieldedPool.sol:567-580): the owed
amount is cleared, the pool winds down, and the first refund of an asset freezes its base. -/
def refundCore (s : State) (a : Asset) (depositor : Addr) : State :=
  { s with
    refundable := update s.refundable a (update (s.refundable a) depositor 0)
    woundDown := true
    refundBase := if s.refundBase a = 0 then update s.refundBase a (s.refundableTotal a)
      else s.refundBase
    refundAssets := if s.refundBase a = 0 then update s.refundAssets a (s.totalShielded a)
      else s.refundAssets }

/-- The amount `betaRefund` pays: `min (owed · refundAssets / base, owed)` (lines 581-583). -/
def refundAmount (t : State) (a : Asset) (owed : ℕ) : ℕ :=
  min (owed * t.refundAssets a / t.refundBase a) owed

/-- `betaRefund` (ShieldedPool.sol:563-588). The caller check (line 565) is not modelled. -/
def betaRefund (s : State) (a : Asset) (depositor : Addr) : Option State :=
  if !s.betaMode then none                                                   -- line 564
  else if s.refundable a depositor = 0 then none                             -- line 568
  else if (refundCore s a depositor).refundBase a = 0 then none              -- division by zero
  else
    let t := refundCore s a depositor
    let amount := refundAmount t a (s.refundable a depositor)
    (reduceShielded t a amount).bind (payOut · a amount)                     -- lines 584,587

/-- A plain transfer to the pool, or `receive()` (ShieldedPool.sol:954). -/
def donate (s : State) (a : Asset) (x : ℕ) : State :=
  { s with bal := bump s.bal a x, surplus := bump s.surplus a x }

/-- `setFeeBps` (ShieldedPool.sol:457-462). -/
def setFeeBps (s : State) (sh un : ℕ) : Option State :=
  if MAX_FEE_BPS < sh ∨ MAX_FEE_BPS < un then none
  else some { s with shieldFeeBps := sh, unshieldFeeBps := un }

/-- `setResidualBand` (ShieldedPool.sol:465-469). -/
def setResidualBand (s : State) (b : ℕ) : Option State :=
  if MAX_BAND_BPS < b then none else some { s with residualBandBps := b }

/-- `endBetaMode` (ShieldedPool.sol:552-558). -/
def endBetaMode (s : State) : Option State :=
  if !s.betaMode ∨ s.woundDown then none else some { s with betaMode := false }

/-- `executeSettlerChange` (ShieldedPool.sol:645-654). The timelock is not modelled. -/
def settlerChange (s : State) (newSettler now : ℕ) : State :=
  { s with settler := newSettler, lastSettlement := now }

/-- The state after the constructor (ShieldedPool.sol:268-312), with fees checked at line 283. -/
def init (sh un now : ℕ) : State where
  bal _ := 0
  totalShielded _ := 0
  claimable _ _ := 0
  totalClaimable _ := 0
  unsweptFees _ := 0
  spent _ := false
  leafCount := 0
  betaMode := true
  woundDown := false
  refundable _ _ := 0
  refundableTotal _ := 0
  refundAssets _ := 0
  refundBase _ := 0
  shieldFeeBps := sh
  unshieldFeeBps := un
  residualBandBps := 200
  settler := 0
  lastSettlement := now
  surplus _ := 0
  noteValue _ := 0

/-- Step labels: the nullifiers a settlement spends and its residual input, or a refund. -/
inductive Label
  /-- A step that is neither a settlement nor a refund. -/
  | quiet
  /-- A settlement spending `ns`, with residual input `residualIn`. -/
  | settle (ns : List Nullifier) (residualIn : ℕ)
  /-- A `betaRefund`. -/
  | refund
  deriving DecidableEq

/-- The nullifiers a step spends. -/
def Label.spent : Label → List Nullifier
  | .settle ns _ => ns
  | _ => []

/-- One successful transaction. Entry points that touch none of the modelled storage
(`commitRoot`, `registerAsset`, timelock proposals, the beta allowlist and caps, `openDeposits`)
are identities here. -/
inductive Step : State → Label → State → Prop
  | absorb {s s'} (a amount sender paid) (h : absorb P s a amount sender paid = some s') :
      Step s .quiet s'
  | settle {s s'} (caller now π its r paid feePaid)
      (h : settle P V s caller now π its r paid feePaid = some s') :
      Step s (.settle (nullifiers its) r.amountIn) s'
  | claim {s s'} (a caller dest) (h : claim s a caller dest = some s') : Step s .quiet s'
  | sweep {s s'} (a) (h : sweepFees s a = some s') : Step s .quiet s'
  | refund {s s'} (a d) (h : betaRefund s a d = some s') : Step s .refund s'
  | donate {s} (a x) : Step s .quiet (donate s a x)
  | setFee {s s'} (sh un) (h : setFeeBps s sh un = some s') : Step s .quiet s'
  | setBand {s s'} (b) (h : setResidualBand s b = some s') : Step s .quiet s'
  | endBeta {s s'} (h : endBetaMode s = some s') : Step s .quiet s'
  | settlerChange {s} (x now) : Step s .quiet (settlerChange s x now)

/-- Runs from deployment, with the nullifiers spent so far, in order. -/
inductive Reach : State → List Nullifier → Prop
  | init (sh un now) (h₁ : sh ≤ MAX_FEE_BPS) (h₂ : un ≤ MAX_FEE_BPS) : Reach (init sh un now) []
  | step {s l lab s'} : Reach s l → Step P V s lab s' → Reach s' (l ++ lab.spent)

/-- A reachable state. -/
def Reachable (s : State) : Prop := ∃ l, Reach P V s l

/-- The reflexive-transitive closure of `Step`. -/
inductive Star : State → State → Prop
  | refl (s) : Star s s
  | tail {s t u lab} : Star s t → Step P V t lab u → Star s u

/-! ## Frames: what each internal phase leaves untouched -/

/-- `t'` agrees with `t` on every field that no payment, debit or swap writes. -/
structure Frame (t t' : State) : Prop where
  spent : t'.spent = t.spent
  leafCount : t'.leafCount = t.leafCount
  woundDown : t'.woundDown = t.woundDown
  betaMode : t'.betaMode = t.betaMode
  shieldFeeBps : t'.shieldFeeBps = t.shieldFeeBps
  unshieldFeeBps : t'.unshieldFeeBps = t.unshieldFeeBps
  residualBandBps : t'.residualBandBps = t.residualBandBps
  noteValue : t'.noteValue = t.noteValue

/-- Every state frames itself. -/
theorem Frame.rfl' (t : State) : Frame t t := ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

/-- Frames compose. -/
theorem Frame.trans {t t' t'' : State} (h : Frame t t') (h' : Frame t' t'') : Frame t t'' :=
  ⟨h'.1.trans h.1, h'.2.trans h.2, h'.3.trans h.3, h'.4.trans h.4, h'.5.trans h.5,
    h'.6.trans h.6, h'.7.trans h.7, h'.8.trans h.8⟩

/-- `_credit` writes only `claimable` and `totalClaimable`. -/
theorem frame_credit (s : State) (a d x) : Frame s (credit s a d x) :=
  ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

/-- `_payFee` writes only `bal` and `unsweptFees`. -/
theorem frame_payFee (s : State) (a x p) : Frame s (payFee s a x p) := by
  unfold payFee; split_ifs <;> exact ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

/-- `_payOrCredit` writes only `bal` and the credit fields. -/
theorem frame_payOrCredit (s : State) (a d x p) : Frame s (payOrCredit s a d x p) := by
  unfold payOrCredit; split_ifs <;> exact ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

/-- One public leg writes only payment fields. -/
theorem frame_payOne (s : State) (it p q) : Frame s (payOne P s it p q) := by
  unfold payOne
  split_ifs
  · exact Frame.rfl' s
  · exact (frame_payOrCredit _ _ _ _ _).trans (frame_payFee _ _ _ _)
  · exact frame_payOrCredit _ _ _ _ _

/-- The second loop of `_settleIntents` writes only payment fields. -/
theorem frame_payAll (s : State) (its p q) : Frame s (payAll P s its p q) := by
  induction its generalizing s with
  | nil => exact Frame.rfl' s
  | cons it its ih => exact (frame_payOne P s _ _ _).trans (ih _)

/-- `_reduceShielded` writes only `totalShielded`. -/
theorem frame_reduceShielded {s s' : State} {a x} (h : reduceShielded s a x = some s') :
    Frame s s' := by
  unfold reduceShielded at h; split_ifs at h; cases h
  exact ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

/-- The fee credit writes only the credit fields. -/
theorem frame_feeCredit (s : State) (it) : Frame s (feeCredit P s it) := by
  unfold feeCredit; split_ifs
  · exact Frame.rfl' s
  · exact frame_credit _ _ _ _

/-- The fee credit leaves `totalShielded` alone. -/
theorem feeCredit_totalShielded (s : State) (it) :
    (feeCredit P s it).totalShielded = s.totalShielded := by
  unfold feeCredit credit; split_ifs <;> rfl

/-- The first loop of `_settleIntents` writes only `totalShielded` and the credit fields. -/
theorem frame_debitAll {s s' : State} {its} (h : debitAll P s its = some s') : Frame s s' := by
  induction its generalizing s with
  | nil => simp only [debitAll, Option.some.injEq] at h; subst h; exact Frame.rfl' s
  | cons it its ih =>
    simp only [debitAll] at h
    split_ifs at h
    · exact ih h
    · obtain ⟨t, h₁, h₂⟩ := Option.bind_eq_some_iff.1 h
      exact (frame_reduceShielded h₁).trans ((frame_feeCredit P t it).trans (ih h₂))

/-- The swap writes only `bal`, `totalShielded` and the ghost `surplus`. -/
theorem frame_swap {s s' : State} {r} (h : swap s r = some s') : Frame s s' := by
  unfold swap at h; split_ifs at h <;> cases h <;> exact ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

/-- `_settleResidual` writes only `bal`, `totalShielded` and the ghost `surplus`. -/
theorem frame_residual {s s' : State} {r} (h : residualStep P s r = some s') : Frame s s' := by
  unfold residualStep at h
  split_ifs at h
  · cases h; exact Frame.rfl' s
  · obtain ⟨t, h₁, h₂⟩ := Option.bind_eq_some_iff.1 h
    exact (frame_reduceShielded h₁).trans (frame_swap h₂)

/-- `settleCore` changes, of the framed fields, only the leaf count and the note ledger. -/
theorem settleCore_frame {s s' : State} {its r p q} (h : settleCore P s its r p q = some s') :
    Frame (insertOutputs P s its) s' := by
  unfold settleCore at h
  split_ifs at h
  obtain ⟨t, h₁, h₂⟩ := Option.bind_eq_some_iff.1 h
  exact (frame_debitAll P h₁).trans ((frame_payAll P _ _ _ _).trans (frame_residual P h₂))

/-- `spendList` touches only `spent`. -/
theorem spendList_frame {s s' : State} {ns : List Nullifier} (h : spendList s ns = some s') :
    s' = { s with spent := s'.spent } := by
  induction ns generalizing s with
  | nil => simp only [spendList, Option.some.injEq] at h; subst h; rfl
  | cons nf ns ih =>
    simp only [spendList] at h
    obtain ⟨s₁, h₁, h₂⟩ := Option.bind_eq_some_iff.1 h
    unfold spend at h₁; split_ifs at h₁; cases h₁
    rw [ih h₂]

/-- The decomposition of a successful settlement. -/
theorem settle_eq_some {s s' : State} {caller now π its r paid feePaid}
    (h : settle P V s caller now π its r paid feePaid = some s') :
    s.woundDown = false ∧ (∀ it ∈ its, DecodeOk P it) ∧ V π its = true ∧
      ∃ s₁, spendList { s with lastSettlement := now } (nullifiers its) = some s₁ ∧
        settleCore P s₁ its r paid feePaid = some s' := by
  unfold settle at h
  split_ifs at h with hw hg hl hdec hv
  simp only [Bool.not_eq_true] at hw
  simp only [Bool.not_eq_true', Bool.not_eq_false] at hv
  exact ⟨hw, hdec, hv, Option.bind_eq_some_iff.1 h⟩

/-- The framed fields after a settlement: leaves grow by `2n`, the rest is kept. -/
theorem settle_frame {s s' : State} {caller now π its r paid feePaid}
    (h : settle P V s caller now π its r paid feePaid = some s') :
    s'.leafCount = s.leafCount + 2 * its.length ∧ s'.woundDown = s.woundDown ∧
      s'.betaMode = s.betaMode ∧ s'.shieldFeeBps = s.shieldFeeBps ∧
      s'.unshieldFeeBps = s.unshieldFeeBps ∧ s'.residualBandBps = s.residualBandBps := by
  obtain ⟨-, -, -, s₁, h₁, h₂⟩ := settle_eq_some P V h
  have hf := settleCore_frame P h₂
  rw [spendList_frame h₁] at hf
  exact ⟨hf.2, hf.3, hf.4, hf.5, hf.6, hf.7⟩

/-- `_payOut` writes only `bal`. -/
theorem payOut_frame {s s' : State} {a x} (h : payOut s a x = some s') : Frame s s' := by
  unfold payOut at h; split_ifs at h; cases h; exact ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

/-- The framed fields after `absorb`: one more leaf, everything else kept. -/
theorem absorb_frame {s s' : State} {a amount sender p}
    (h : absorb P s a amount sender p = some s') :
    s'.spent = s.spent ∧ s'.leafCount = s.leafCount + 1 ∧ s'.woundDown = s.woundDown ∧
      s'.betaMode = s.betaMode ∧ s'.shieldFeeBps = s.shieldFeeBps ∧
      s'.unshieldFeeBps = s.unshieldFeeBps ∧ s'.residualBandBps = s.residualBandBps := by
  unfold absorb at h; split_ifs at h; cases h
  have f := frame_payFee (absorbCore P s a amount sender) a
    ((splitDeposit (amount / P.scale a) s.shieldFeeBps).1 * P.scale a) p
  exact ⟨f.1, f.2, f.3, f.4, f.5, f.6, f.7⟩

/-- `claim` keeps every framed field. -/
theorem claim_frame {s s' : State} {a c d} (h : claim s a c d = some s') : Frame s s' := by
  unfold claim at h; split_ifs at h
  have f := payOut_frame h
  exact ⟨f.1, f.2, f.3, f.4, f.5, f.6, f.7, f.8⟩

/-- `sweepFees` keeps every framed field. -/
theorem sweep_frame {s s' : State} {a} (h : sweepFees s a = some s') : Frame s s' := by
  unfold sweepFees at h; split_ifs at h
  have f := payOut_frame h
  exact ⟨f.1, f.2, f.3, f.4, f.5, f.6, f.7, f.8⟩

/-- The decomposition of a successful refund. -/
theorem refund_eq_some {s s' : State} {a d} (h : betaRefund s a d = some s') :
    s.betaMode = true ∧ ∃ t, reduceShielded (refundCore s a d) a
      (refundAmount (refundCore s a d) a (s.refundable a d)) = some t ∧
      payOut t a (refundAmount (refundCore s a d) a (s.refundable a d)) = some s' := by
  unfold betaRefund at h
  split_ifs at h with hb
  simp only [Bool.not_eq_true', Bool.not_eq_false] at hb
  exact ⟨hb, Option.bind_eq_some_iff.1 h⟩

/-- The fields a refund keeps, and wind-down. -/
theorem refund_frame {s s' : State} {a d} (h : betaRefund s a d = some s') :
    s'.spent = s.spent ∧ s'.leafCount = s.leafCount ∧ s'.woundDown = true ∧
      s'.shieldFeeBps = s.shieldFeeBps ∧ s'.unshieldFeeBps = s.unshieldFeeBps ∧
      s'.residualBandBps = s.residualBandBps ∧ s'.betaMode = s.betaMode := by
  obtain ⟨-, t, h₁, h₂⟩ := refund_eq_some h
  have f := (frame_reduceShielded h₁).trans (payOut_frame h₂)
  exact ⟨f.1, f.2, f.3, f.5, f.6, f.7, f.4⟩

/-! ## (a) Conservation -/

/-- The slack of the conservation equation at asset `a`, in `ℤ`. -/
def slack (s : State) (a : Asset) : ℤ :=
  (s.bal a : ℤ) - s.totalShielded a - s.totalClaimable a - s.unsweptFees a - s.surplus a

/-- The conservation equation, pointwise. -/
def Conserved (s : State) : Prop :=
  ∀ a, s.bal a = s.totalShielded a + s.totalClaimable a + s.unsweptFees a + s.surplus a

/-- Conservation is the vanishing of the slack. -/
theorem conserved_iff (s : State) : Conserved s ↔ ∀ a, slack s a = 0 := by
  unfold Conserved slack
  refine forall_congr' fun a => ?_
  omega

/-- The indicator `[a = b] · x`, in `ℤ`. -/
def at_ (b a : Asset) (x : ℕ) : ℤ := if a = b then (x : ℤ) else 0

/-- A credit lowers the slack by its amount. -/
theorem slack_credit (s : State) (b d x : ℕ) (a : Asset) :
    slack (credit s b d x) a = slack s a - at_ b a x := by
  by_cases hab : a = b
  · subst hab; simp [credit, slack, at_, bump_apply]; omega
  · simp [credit, slack, at_, bump_apply, hab]

/-- What arrives is at most the amount and at most the balance. -/
theorem arrived_le (s : State) (a x p : ℕ) : arrived s a x p ≤ x ∧ arrived s a x p ≤ s.bal a :=
  ⟨(min_le_right _ _).trans (min_le_left _ _), (min_le_right _ _).trans (min_le_right _ _)⟩

/-- `_payFee` lowers the slack by the fee: what arrives leaves, the rest becomes a liability. -/
theorem slack_payFee (s : State) (b x p : ℕ) (a : Asset) :
    slack (payFee s b x p) a = slack s a - at_ b a x := by
  unfold payFee
  split_ifs with h0
  · subst h0; simp [at_]
  · obtain ⟨h1, h2⟩ := arrived_le s b x p
    by_cases hab : a = b
    · subst hab; simp [slack, at_]; omega
    · simp [slack, at_, hab]

/-- `_payOrCredit` lowers the slack by the payout. -/
theorem slack_payOrCredit (s : State) (b d x p : ℕ) (a : Asset) :
    slack (payOrCredit s b d x p) a = slack s a - at_ b a x := by
  unfold payOrCredit
  split_ifs with h0
  · subst h0; simp [at_]
  · rw [slack_credit]
    obtain ⟨h1, h2⟩ := arrived_le s b x p
    by_cases hab : a = b
    · subst hab; simp [slack, at_]; omega
    · simp [slack, at_, hab]

/-- `_payOut` lowers the slack by the payout. -/
theorem slack_payOut {s s' : State} {b x : ℕ} (h : payOut s b x = some s') (a : Asset) :
    slack s' a = slack s a - at_ b a x := by
  unfold payOut at h
  split_ifs at h with hx
  cases h
  by_cases hab : a = b
  · subst hab; simp [slack, at_]; omega
  · simp [slack, at_, hab]

/-- `_reduceShielded` raises the slack by the debit. -/
theorem slack_reduceShielded {s s' : State} {b x : ℕ} (h : reduceShielded s b x = some s')
    (a : Asset) : slack s' a = slack s a + at_ b a x := by
  unfold reduceShielded at h
  split_ifs at h with hx
  cases h
  by_cases hab : a = b
  · subst hab; simp [slack, at_]; omega
  · simp [slack, at_, hab]

/-- What one intent's public leg owes outside the pool's liabilities after the first loop: the
public amount, plus the fee when it goes to the router. -/
def legOf (it : Intent) : ℕ :=
  if it.publicAmount = 0 then 0
  else it.publicAmount * P.scale it.asset +
    if it.feeRecipient = 0 then it.fee * P.scale it.asset else 0

/-- The batch sum of `legOf` at asset `a`. -/
def legsOf (its : List Intent) (a : Asset) : ℤ := (its.map fun it => at_ it.asset a (legOf P it)).sum

/-- The first loop raises the slack by the batch's legs: it debits `publicAmount + fee` and
credits the fee to a named fee recipient. -/
theorem slack_debitAll {s s' : State} {its : List Intent} (h : debitAll P s its = some s')
    (a : Asset) : slack s' a = slack s a + legsOf P its a := by
  induction its generalizing s with
  | nil => simp only [debitAll, Option.some.injEq] at h; subst h; simp [legsOf]
  | cons it its ih =>
    simp only [debitAll] at h
    split_ifs at h with h0
    · rw [ih h]; simp [legsOf, legOf, h0, at_]
    · obtain ⟨s₁, h₁, h₂⟩ := Option.bind_eq_some_iff.1 h
      rw [ih h₂]
      have hfc : slack (feeCredit P s₁ it) a = slack s₁ a -
          at_ it.asset a (if it.feeRecipient = 0 then 0 else it.fee * P.scale it.asset) := by
        unfold feeCredit; split_ifs
        · simp [at_]
        · exact slack_credit _ _ _ _ _
      rw [hfc, slack_reduceShielded h₁]
      simp only [legsOf, legOf, h0, List.map_cons, List.sum_cons, at_, ite_false]
      split_ifs <;> push_cast <;> ring

/-- One public leg lowers the slack by `legOf`. -/
theorem slack_payOne (s : State) (it : Intent) (p q : ℕ) (a : Asset) :
    slack (payOne P s it p q) a = slack s a - at_ it.asset a (legOf P it) := by
  unfold payOne legOf
  split_ifs with h0 hf
  · simp [at_]
  · rw [slack_payFee, slack_payOrCredit]; unfold at_; split_ifs <;> push_cast <;> ring
  · rw [slack_payOrCredit]; unfold at_; split_ifs <;> push_cast <;> ring

/-- The second loop lowers the slack by the batch's legs. -/
theorem slack_payAll (s : State) (its : List Intent) (p q : Intent → ℕ) (a : Asset) :
    slack (payAll P s its p q) a = slack s a - legsOf P its a := by
  induction its generalizing s with
  | nil => simp [payAll, legsOf]
  | cons it its ih =>
    simp only [payAll]
    rw [ih, slack_payOne]
    simp only [legsOf, List.map_cons, List.sum_cons]; ring

/-- The swap lowers the slack by `amountIn`, which offsets the debit before it. -/
theorem slack_swap {s s' : State} {r : Residual} (h : swap s r = some s') (a : Asset) :
    slack s' a = slack s a - at_ r.assetIn a r.amountIn := by
  unfold swap at h
  split_ifs at h with hb hne hbad <;> cases h
  · have hb' : r.amountIn ≤ s.bal r.assetIn := not_lt.1 hb
    by_cases h1 : a = r.assetIn
    · simp [slack, at_, h1, hne]; omega
    · by_cases h2 : a = r.assetOut
      · subst h2; simp [slack, at_, h1]
      · simp [slack, at_, h1, h2]
  · have hb' : r.amountIn ≤ s.bal r.assetIn := not_lt.1 hb
    have hr : r.amountIn ≤ r.received := by omega
    by_cases h1 : a = r.assetIn
    · subst h1; simp [slack, at_]; omega
    · simp [slack, at_, h1]

/-- The residual swap does not move the slack. -/
theorem slack_residual {s s' : State} {r : Residual} (h : residualStep P s r = some s')
    (a : Asset) : slack s' a = slack s a := by
  unfold residualStep at h
  split_ifs at h with h0
  · cases h; rfl
  · obtain ⟨s₁, h₁, h₂⟩ := Option.bind_eq_some_iff.1 h
    rw [slack_swap h₂, slack_reduceShielded h₁]; ring

/-- `settleBatch` does not move the slack. -/
theorem slack_settle {s s' : State} {caller now π its r paid feePaid}
    (h : settle P V s caller now π its r paid feePaid = some s') (a : Asset) :
    slack s' a = slack s a := by
  obtain ⟨-, -, -, s₁, h₁, h₂⟩ := settle_eq_some P V h
  unfold settleCore at h₂
  split_ifs at h₂
  obtain ⟨s₃, h₃, h₄⟩ := Option.bind_eq_some_iff.1 h₂
  rw [slack_residual P h₄, slack_payAll, slack_debitAll P h₃, spendList_frame h₁]
  simp [slack, insertOutputs]

/-- `absorb` does not move the slack: the deposit of `units · scale` backs a note of
`valueUnits · scale` and a fee of `feeUnits · scale`, which leaves or is held. -/
theorem slack_absorb {s s' : State} {b amount sender p}
    (h : absorb P s b amount sender p = some s') (a : Asset) : slack s' a = slack s a := by
  unfold absorb at h
  split_ifs at h with hw hr hv hleaf
  cases h
  rw [slack_payFee]
  simp only [absorbCore]
  push Not at hr
  obtain ⟨-, -, hmod⟩ := hr
  have hsplit : amount = (splitDeposit (amount / P.scale b) s.shieldFeeBps).1 * P.scale b +
      valueUnits s (amount / P.scale b) * P.scale b := by
    have hdiv : amount = amount / P.scale b * P.scale b := (Nat.div_mul_cancel
      (Nat.dvd_of_mod_eq_zero hmod)).symm
    have hle : amount / P.scale b * s.shieldFeeBps / BPS ≤ amount / P.scale b := by
      unfold valueUnits splitDeposit at hv; simp only at hv; omega
    unfold valueUnits splitDeposit
    rw [← Nat.add_mul, Nat.add_sub_cancel' hle]; exact hdiv
  generalize (splitDeposit (amount / P.scale b) s.shieldFeeBps).1 * P.scale b = fee at hsplit ⊢
  generalize valueUnits s (amount / P.scale b) * P.scale b = value at hsplit ⊢
  by_cases hab : a = b
  · subst hab; simp [slack, at_]; omega
  · simp [slack, at_, hab]

/-- `claim` does not move the slack. -/
theorem slack_claim {s s' : State} {b caller d} (h : claim s b caller d = some s') (a : Asset) :
    slack s' a = slack s a := by
  unfold claim at h
  split_ifs at h with h0 hc
  rw [slack_payOut h]
  by_cases hab : a = b
  · subst hab; simp [slack, at_]; omega
  · simp [slack, at_, hab]

/-- `sweepFees` does not move the slack. -/
theorem slack_sweep {s s' : State} {b} (h : sweepFees s b = some s') (a : Asset) :
    slack s' a = slack s a := by
  unfold sweepFees at h
  split_ifs at h with h0
  rw [slack_payOut h]
  by_cases hab : a = b
  · subst hab; simp [slack, at_]; ring
  · simp [slack, at_, hab]

/-- `betaRefund` does not move the slack: it debits `totalShielded` by what it pays, and
the debit is checked (ShieldedPool.sol:584). -/
theorem slack_refund {s s' : State} {b d} (h : betaRefund s b d = some s') (a : Asset) :
    slack s' a = slack s a := by
  obtain ⟨-, t, h₁, h₂⟩ := refund_eq_some h
  rw [slack_payOut h₂, slack_reduceShielded h₁]
  simp [slack, refundCore]

/-- Every step preserves the slack. -/
theorem slack_step {s s' : State} {lab} (h : Step P V s lab s') (a : Asset) :
    slack s' a = slack s a := by
  cases h with
  | absorb _ _ _ _ h => exact slack_absorb P h a
  | settle _ _ _ _ _ _ _ h => exact slack_settle P V h a
  | claim _ _ _ h => exact slack_claim h a
  | sweep _ h => exact slack_sweep h a
  | refund _ _ h => exact slack_refund h a
  | donate b x =>
    by_cases hab : a = b
    · subst hab; simp [donate, slack]; ring
    · simp [donate, slack, hab]
  | setFee _ _ h => unfold setFeeBps at h; split_ifs at h; cases h; rfl
  | setBand _ h => unfold setResidualBand at h; split_ifs at h; cases h; rfl
  | endBeta h => unfold endBetaMode at h; split_ifs at h; cases h; rfl
  | settlerChange _ _ => rfl

/-- **(a) Conservation.** In every reachable state, for every asset,
`bal = totalShielded + totalClaimable + unsweptFees + surplus`. -/
theorem conservation {s : State} (hs : Reachable P V s) : Conserved s := by
  obtain ⟨l, hl⟩ := hs
  rw [conserved_iff]
  induction hl with
  | init => intro a; simp [slack, init]
  | step _ hst ih => intro a; rw [slack_step P V hst, ih]

/-- **Solvency.** In every reachable state the pool holds at least its liabilities in each asset:
the notes, the credits and the held fees. -/
theorem solvent {s : State} (hs : Reachable P V s) (a : Asset) :
    s.totalShielded a + s.totalClaimable a + s.unsweptFees a ≤ s.bal a := by
  have := conservation P V hs a; omega

/-! ## (b) Nullifiers -/

/-- `spendList` succeeds only if the list has no duplicates and none is spent yet. It marks
those nullifiers and no others. -/
theorem spendList_spec {s s' : State} {ns : List Nullifier} (h : spendList s ns = some s') :
    ns.Nodup ∧ (∀ nf ∈ ns, s.spent nf = false) ∧
      ∀ nf, s'.spent nf = (s.spent nf || decide (nf ∈ ns)) := by
  induction ns generalizing s with
  | nil => simp only [spendList, Option.some.injEq] at h; subst h; simp
  | cons nf ns ih =>
    simp only [spendList] at h
    obtain ⟨s₁, h₁, h₂⟩ := Option.bind_eq_some_iff.1 h
    unfold spend at h₁
    split_ifs at h₁ with hsp
    cases h₁
    obtain ⟨hnd, hfree, hmark⟩ := ih h₂
    simp only [Bool.not_eq_true] at hsp
    refine ⟨List.nodup_cons.2 ⟨fun hm => ?_, hnd⟩, fun x hx => ?_, fun x => ?_⟩
    · have := hfree nf hm; simp at this
    · rcases List.mem_cons.1 hx with rfl | hx
      · exact hsp
      · have := hfree x hx
        by_cases hxe : x = nf
        · subst hxe; exact hsp
        · simpa [update_of_ne hxe] using this
    · rw [hmark x]
      by_cases hxe : x = nf
      · subst hxe; simp
      · simp [hxe]

/-- A settlement's nullifiers are fresh and distinct, and afterwards spent. -/
theorem settle_spends {s s' : State} {caller now π its r paid feePaid}
    (h : settle P V s caller now π its r paid feePaid = some s') :
    (nullifiers its).Nodup ∧ (∀ nf ∈ nullifiers its, s.spent nf = false) ∧
      ∀ nf, s'.spent nf = (s.spent nf || decide (nf ∈ nullifiers its)) := by
  obtain ⟨-, -, -, s₁, h₁, h₂⟩ := settle_eq_some P V h
  obtain ⟨hnd, hfree, hmark⟩ := spendList_spec h₁
  have hf := (settleCore_frame P h₂).spent
  refine ⟨hnd, hfree, fun nf => ?_⟩
  rw [hf]
  exact hmark nf

/-- How a step changes `spent`: it adds the nullifiers of its label and no others. -/
theorem spent_step {s s' : State} {lab} (h : Step P V s lab s') :
    ∀ nf, s'.spent nf = (s.spent nf || decide (nf ∈ lab.spent)) := by
  cases h with
  | settle _ _ _ _ _ _ _ h => exact (settle_spends P V h).2.2
  | absorb _ _ _ _ h => intro nf; simp [Label.spent, (absorb_frame P h).1]
  | claim _ _ _ h => intro nf; simp [Label.spent, (claim_frame h).spent]
  | sweep _ h => intro nf; simp [Label.spent, (sweep_frame h).spent]
  | refund _ _ h => intro nf; simp [Label.spent, (refund_frame h).1]
  | donate _ _ => simp [Label.spent, donate]
  | setFee _ _ h => unfold setFeeBps at h; split_ifs at h; cases h; simp [Label.spent]
  | setBand _ h => unfold setResidualBand at h; split_ifs at h; cases h; simp [Label.spent]
  | endBeta h => unfold endBetaMode at h; split_ifs at h; cases h; simp [Label.spent]
  | settlerChange _ _ => simp [Label.spent, settlerChange]

/-- A step spends only fresh nullifiers, each once. -/
theorem step_spends_fresh {s s' : State} {lab} (h : Step P V s lab s') :
    lab.spent.Nodup ∧ ∀ nf ∈ lab.spent, s.spent nf = false := by
  cases h with
  | settle _ _ _ _ _ _ _ h => exact ⟨(settle_spends P V h).1, (settle_spends P V h).2.1⟩
  | _ => simp [Label.spent]

/-- **(b) A nullifier is spent at most once.** Along any run, the nullifiers spent form a list
without duplicates, and a nullifier is marked spent iff it is in that list. -/
theorem nullifier_once {s : State} {l : List Nullifier} (h : Reach P V s l) :
    l.Nodup ∧ ∀ nf, s.spent nf = decide (nf ∈ l) := by
  induction h with
  | init => simp [init]
  | step _ hst ih =>
    obtain ⟨hnd, hsp⟩ := ih
    obtain ⟨hnd', hfresh⟩ := step_spends_fresh P V hst
    refine ⟨List.nodup_append.2 ⟨hnd, hnd', fun x hx y hy hxy => ?_⟩, fun nf => ?_⟩
    · subst hxy; have := hfresh x hy; rw [hsp x] at this; simp [hx] at this
    · rw [spent_step P V hst, hsp]; simp [List.mem_append]

/-! ## (c) Fee caps -/

/-- **(c) The fee settings stay within their caps** in every reachable state:
`shieldFeeBps, unshieldFeeBps ≤ 50` and `residualBandBps ≤ 1000`. -/
theorem fee_caps {s : State} (hs : Reachable P V s) :
    s.shieldFeeBps ≤ MAX_FEE_BPS ∧ s.unshieldFeeBps ≤ MAX_FEE_BPS ∧
      s.residualBandBps ≤ MAX_BAND_BPS := by
  obtain ⟨l, hl⟩ := hs
  induction hl with
  | init _ _ _ h₁ h₂ => exact ⟨h₁, h₂, by norm_num [init]⟩
  | step _ hst ih =>
    obtain ⟨i₁, i₂, i₃⟩ := ih
    cases hst with
    | absorb _ _ _ _ h =>
      obtain ⟨-, -, -, -, e₁, e₂, e₃⟩ := absorb_frame P h; rw [e₁, e₂, e₃]; exact ⟨i₁, i₂, i₃⟩
    | settle _ _ _ _ _ _ _ h =>
      obtain ⟨-, -, -, e₁, e₂, e₃⟩ := settle_frame P V h; rw [e₁, e₂, e₃]; exact ⟨i₁, i₂, i₃⟩
    | claim _ _ _ h =>
      have f := claim_frame h; rw [f.shieldFeeBps, f.unshieldFeeBps, f.residualBandBps]
      exact ⟨i₁, i₂, i₃⟩
    | sweep _ h =>
      have f := sweep_frame h; rw [f.shieldFeeBps, f.unshieldFeeBps, f.residualBandBps]
      exact ⟨i₁, i₂, i₃⟩
    | refund _ _ h =>
      obtain ⟨-, -, -, e₁, e₂, e₃, -⟩ := refund_frame h; rw [e₁, e₂, e₃]; exact ⟨i₁, i₂, i₃⟩
    | donate _ _ => exact ⟨i₁, i₂, i₃⟩
    | setFee _ _ h =>
      unfold setFeeBps at h; split_ifs at h with hc; cases h
      exact ⟨by dsimp only; omega, by dsimp only; omega, i₃⟩
    | setBand _ h =>
      unfold setResidualBand at h; split_ifs at h with hc; cases h
      exact ⟨i₁, i₂, by dsimp only; omega⟩
    | endBeta h => unfold endBetaMode at h; split_ifs at h; cases h; exact ⟨i₁, i₂, i₃⟩
    | settlerChange _ _ => exact ⟨i₁, i₂, i₃⟩

/-- **(c) The shield fee is within its cap**: in a reachable state, the fee `absorb` charges on
`units` is at most `⌊units · 50 / 10⁴⌋` units, and fee plus note value is `units`. -/
theorem absorb_fee_le {s : State} (hs : Reachable P V s) (units : ℕ) :
    (splitDeposit units s.shieldFeeBps).1 ≤ units * MAX_FEE_BPS / BPS ∧
      (splitDeposit units s.shieldFeeBps).1 + (splitDeposit units s.shieldFeeBps).2 = units := by
  have hcap := (fee_caps P V hs).1
  have hle : units * s.shieldFeeBps ≤ units * MAX_FEE_BPS := Nat.mul_le_mul_left _ hcap
  have h1 : units * s.shieldFeeBps / BPS ≤ units * MAX_FEE_BPS / BPS := Nat.div_le_div_right hle
  refine ⟨h1, ?_⟩
  have h2 : units * MAX_FEE_BPS / BPS ≤ units := by simp only [MAX_FEE_BPS, BPS]; omega
  simp only [splitDeposit]
  omega

/-- **(c) The unshield fee is within its cap**: every intent of a successful settlement pays
`fee · 10⁴ ≤ publicAmount · 50`. In the model a private intent (`publicAmount = 0`) pays none. -/
theorem settle_fee_le {s s' : State} {caller now π its r paid feePaid}
    (h : settle P V s caller now π its r paid feePaid = some s') :
    ∀ it ∈ its, it.fee * BPS ≤ it.publicAmount * MAX_FEE_BPS := by
  obtain ⟨-, hdec, -⟩ := settle_eq_some P V h
  intro it hit
  obtain ⟨-, -, -, -, -, h0, hpos⟩ := hdec it hit
  by_cases hp : it.publicAmount = 0
  · simp [(h0 hp).1]
  · exact (hpos hp).1

/-! ## (d) Wind-down -/

/-- `absorb` reverts in a wound-down pool (ShieldedPool.sol:344). -/
theorem absorb_woundDown {s : State} (hw : s.woundDown = true) (a amount sender p) :
    absorb P s a amount sender p = none := by simp [absorb, hw]

/-- `settleBatch` reverts in a wound-down pool (ShieldedPool.sol:393). -/
theorem settle_woundDown {s : State} (hw : s.woundDown = true) (caller now π its r paid feePaid) :
    settle P V s caller now π its r paid feePaid = none := by simp [settle, hw]

/-- No step clears `woundDown`. -/
theorem woundDown_step {s s' : State} {lab} (h : Step P V s lab s') (hw : s.woundDown = true) :
    s'.woundDown = true := by
  cases h with
  | absorb _ _ _ _ h => rw [absorb_woundDown P hw] at h; cases h
  | settle _ _ _ _ _ _ _ h => rw [settle_woundDown P V hw] at h; cases h
  | claim _ _ _ h => rw [(claim_frame h).woundDown]; exact hw
  | sweep _ h => rw [(sweep_frame h).woundDown]; exact hw
  | refund _ _ h => exact (refund_frame h).2.2.1
  | donate _ _ => exact hw
  | setFee _ _ h => unfold setFeeBps at h; split_ifs at h; cases h; exact hw
  | setBand _ h => unfold setResidualBand at h; split_ifs at h; cases h; exact hw
  | endBeta h => unfold endBetaMode at h; split_ifs at h; cases h; exact hw
  | settlerChange _ _ => exact hw

/-- **(d) After wind-down, no absorb or settle succeeds**: in every state reachable from a
wound-down state, `woundDown` still holds and both entry points revert, whatever their arguments. -/
theorem woundDown_final {s t : State} (hw : s.woundDown = true) (hst : Star P V s t) :
    t.woundDown = true ∧ (∀ a amount sender p, absorb P t a amount sender p = none) ∧
      ∀ caller now π its r paid feePaid, settle P V t caller now π its r paid feePaid = none := by
  have ht : t.woundDown = true := by
    induction hst with
    | refl => exact hw
    | tail _ hstep ih => exact woundDown_step P V hstep ih
  exact ⟨ht, absorb_woundDown P ht, settle_woundDown P V ht⟩

/-- A refund always winds the pool down (ShieldedPool.sol:571-574). -/
theorem refund_woundDown {s s' : State} {a d} (h : betaRefund s a d = some s') :
    s'.woundDown = true := (refund_frame h).2.2.1

/-! ## (e) Leaves -/

/-- Every step leaves the leaf count at least as large. `absorb` adds one leaf and a settlement
of `n` intents adds `2n`. -/
theorem leafCount_step {s s' : State} {lab} (h : Step P V s lab s') :
    s.leafCount ≤ s'.leafCount := by
  cases h with
  | absorb _ _ _ _ h => rw [(absorb_frame P h).2.1]; omega
  | settle _ _ _ _ _ _ _ h => rw [(settle_frame P V h).1]; omega
  | claim _ _ _ h => rw [(claim_frame h).leafCount]
  | sweep _ h => rw [(sweep_frame h).leafCount]
  | refund _ _ h => rw [(refund_frame h).2.1]
  | donate _ _ => exact le_rfl
  | setFee _ _ h => unfold setFeeBps at h; split_ifs at h; cases h; exact le_rfl
  | setBand _ h => unfold setResidualBand at h; split_ifs at h; cases h; exact le_rfl
  | endBeta h => unfold endBetaMode at h; split_ifs at h; cases h; exact le_rfl
  | settlerChange _ _ => exact le_rfl

/-- **(e) The leaf count only increases** along any sequence of transactions. -/
theorem leafCount_mono {s t : State} (h : Star P V s t) : s.leafCount ≤ t.leafCount := by
  induction h with
  | refl => exact le_rfl
  | tail _ hstep ih => exact ih.trans (leafCount_step P V hstep)

/-! ## The note ledger under R -/

/-- The gap between `totalShielded` and the net note value. -/
def noteGap (s : State) (a : Asset) : ℤ := (s.totalShielded a : ℤ) - s.noteValue a

/-- The on-chain value a batch removes from `totalShielded` at asset `a` in the first loop. -/
def debitOf (its : List Intent) (a : Asset) : ℤ :=
  (its.map fun it => if it.publicAmount = 0 then 0
    else at_ it.asset a ((it.publicAmount + it.fee) * P.scale it.asset)).sum

/-- Under R, and with `publicAmount = 0 → fee = 0` from `DecodeOk`, a batch's note delta is minus
its debits: `out - in = -(publicAmount + fee)` per intent. -/
theorem noteDelta_eq {its : List Intent} (hR : ∀ it ∈ its, Conserves it)
    (hdec : ∀ it ∈ its, DecodeOk P it) (a : Asset) : noteDelta P its a = -debitOf P its a := by
  induction its with
  | nil => simp [noteDelta, debitOf]
  | cons it its ih =>
    have h1 := hR it List.mem_cons_self
    have hd := hdec it List.mem_cons_self
    have ih' := ih (fun it' h' => hR it' (List.mem_cons_of_mem _ h'))
      (fun it' h' => hdec it' (List.mem_cons_of_mem _ h'))
    simp only [noteDelta, debitOf, List.map_cons, List.sum_cons] at ih' ⊢
    rw [ih']
    unfold Conserves at h1
    obtain ⟨-, -, -, -, -, h0, -⟩ := hd
    unfold at_
    by_cases hp : it.publicAmount = 0
    · obtain ⟨hf, -⟩ := h0 hp
      rw [hf, hp] at h1
      simp only [hp, ite_true]
      split_ifs <;> (try rw [h1]) <;> push_cast <;> ring
    · simp only [hp, ite_false]
      split_ifs
      · rw [h1]; push_cast; ring
      · ring

/-- `payAll` leaves `totalShielded` alone. -/
theorem payAll_totalShielded (t : State) (its p q) :
    (payAll P t its p q).totalShielded = t.totalShielded := by
  induction its generalizing t with
  | nil => rfl
  | cons it its ih =>
    simp only [payAll]; rw [ih]
    unfold payOne payOrCredit payFee credit
    split_ifs <;> rfl

/-- `debitAll` lowers `totalShielded` by the batch's debits. -/
theorem debitAll_totalShielded {t t' : State} {its} (hd : debitAll P t its = some t') (a : Asset) :
    (t'.totalShielded a : ℤ) = t.totalShielded a - debitOf P its a := by
  induction its generalizing t with
  | nil => simp only [debitAll, Option.some.injEq] at hd; subst hd; simp [debitOf]
  | cons it its ih =>
    simp only [debitAll] at hd
    split_ifs at hd with h0
    · rw [ih hd]; simp [debitOf, h0]
    · obtain ⟨t₁, ht₁, ht₂⟩ := Option.bind_eq_some_iff.1 hd
      unfold reduceShielded at ht₁
      split_ifs at ht₁ with hx
      cases ht₁
      rw [ih ht₂]
      rw [feeCredit_totalShielded]
      simp only [drop_apply, debitOf, List.map_cons, List.sum_cons, at_, h0, ite_false]
      split_ifs with hb
      · subst hb; push_cast [hx]; ring
      · ring

/-- **The shielded supply tracks the notes.** Under a sound verifier, every step except a
settlement with a residual swap and a refund preserves `totalShielded - noteValue`. -/
theorem noteGap_step (hV : Sound V) {s s' : State} {lab} (h : Step P V s lab s')
    (hclean : ∀ ns r, lab = .settle ns r → r = 0) (hnr : lab ≠ .refund) (a : Asset) :
    noteGap s' a = noteGap s a := by
  cases h with
  | absorb _ _ _ _ h =>
    unfold absorb at h; split_ifs at h; cases h
    have e : ∀ (t : State) x y p, (payFee t x y p).totalShielded = t.totalShielded ∧
        (payFee t x y p).noteValue = t.noteValue := by
      intro t x y p; unfold payFee; split_ifs <;> exact ⟨rfl, rfl⟩
    rw [noteGap, (e _ _ _ _).1, (e _ _ _ _).2]
    simp only [noteGap, absorbCore, bump_apply]
    split_ifs with ha
    · subst ha; simp
    · simp [ha]
  | settle caller now π its r paid feePaid h =>
    have hr0 : r.amountIn = 0 := hclean _ _ rfl
    obtain ⟨-, hdec, hv, s₁, h₁, h₂⟩ := settle_eq_some P V h
    have hR := hV π its hv
    unfold settleCore at h₂
    split_ifs at h₂
    obtain ⟨s₃, h₃, h₄⟩ := Option.bind_eq_some_iff.1 h₂
    simp only [residualStep, hr0, ite_true, Option.some.injEq] at h₄
    subst h₄
    have hnv := ((frame_debitAll P h₃).trans (frame_payAll P s₃ its paid feePaid)).noteValue
    simp only [noteGap]
    rw [payAll_totalShielded, debitAll_totalShielded P h₃, hnv, spendList_frame h₁]
    simp only [insertOutputs, noteDelta_eq P hR hdec]
    ring
  | claim _ _ _ h =>
    unfold claim payOut at h; split_ifs at h; cases h; rfl
  | sweep _ h => unfold sweepFees payOut at h; split_ifs at h; cases h; rfl
  | refund _ _ h => exact absurd rfl hnr
  | donate _ _ => rfl
  | setFee _ _ h => unfold setFeeBps at h; split_ifs at h; cases h; rfl
  | setBand _ h => unfold setResidualBand at h; split_ifs at h; cases h; rfl
  | endBeta h => unfold endBetaMode at h; split_ifs at h; cases h; rfl
  | settlerChange _ _ => rfl

/-- Runs from deployment with no residual swap and no refund. -/
inductive CleanReach : State → Prop
  | init (sh un now) (h₁ : sh ≤ MAX_FEE_BPS) (h₂ : un ≤ MAX_FEE_BPS) : CleanReach (init sh un now)
  | step {s lab s'} : CleanReach s → Step P V s lab s' → (∀ ns r, lab = .settle ns r → r = 0) →
      lab ≠ .refund → CleanReach s'

/-- **Shielded supply equals note value.** Under a sound verifier, along any run with no residual
swap and no refund, `totalShielded a` equals the net value of the notes of asset `a`, in base
units (minted by `absorb` and by settlement outputs, minus settlement inputs). -/
theorem shielded_eq_notes (hV : Sound V) {s : State} (h : CleanReach P V s) (a : Asset) :
    (s.totalShielded a : ℤ) = s.noteValue a := by
  suffices noteGap s a = 0 by unfold noteGap at this; omega
  induction h with
  | init => simp [noteGap, init]
  | step _ hst hc hr ih => rw [noteGap_step P V hV hst hc hr, ih]

/-! ## A floored refund -/

section Legacy

/-- A refund the contract does not use: it floors `totalShielded` at zero instead of checking the
debit (`totalShielded = shielded > amount ? shielded - amount : 0`), and pays the whole recorded
deposit. -/
def legacyBetaRefund (s : State) (a : Asset) (depositor : Addr) : Option State :=
  if !s.betaMode then none
  else if s.refundable a depositor = 0 then none
  else payOut { s with
    refundable := update s.refundable a (update (s.refundable a) depositor 0)
    totalShielded := update s.totalShielded a
      (if s.totalShielded a > s.refundable a depositor
        then s.totalShielded a - s.refundable a depositor else 0)
    woundDown := true } a (s.refundable a depositor)

/-- A verifier that accepts everything. The witness below does not depend on it. -/
def acceptAll : Proof → List Intent → Bool := fun _ _ => true

/-- Alice (address 1) shields 100 wei. Her note is unshielded to Bob (address 7), whose push does
not arrive, so 100 is credited to him. -/
def witnessIntent : Intent := ⟨1, 2, 100, 0, 0, 7, 0, 100, 0⟩

/-- The deployment. -/
def w₀ : State := init 0 0 0

/-- Alice's `absorb` of 100 succeeds. -/
theorem w₁_isSome : (absorb Params.unit w₀ 0 100 1 0).isSome := by decide

/-- After Alice's deposit. -/
def w₁ : State := (absorb Params.unit w₀ 0 100 1 0).get w₁_isSome

/-- The settlement crediting Bob succeeds. -/
theorem w₂_isSome : (settle Params.unit acceptAll w₁ 9 0 [] [witnessIntent] ⟨0, 0, 0, 0⟩
    (fun _ => 0) (fun _ => 0)).isSome := by decide

/-- After the settlement that credits Bob. -/
def w₂ : State := (settle Params.unit acceptAll w₁ 9 0 [] [witnessIntent] ⟨0, 0, 0, 0⟩
    (fun _ => 0) (fun _ => 0)).get w₂_isSome

/-- `w₂` is reachable. -/
theorem w₂_reachable : Reachable Params.unit acceptAll w₂ :=
  ⟨_, .step (.step (.init 0 0 0 (by norm_num) (by norm_num))
    (.absorb 0 100 1 0 (Option.some_get w₁_isSome).symm))
    (.settle 9 0 [] [witnessIntent] ⟨0, 0, 0, 0⟩ _ _ (Option.some_get w₂_isSome).symm)⟩

/-- **A floored refund breaks solvency.** From a reachable state in which Alice's note has been
unshielded and credited to Bob, `legacyBetaRefund` pays Alice 100 out of Bob's credit. The pool
then holds less than its liabilities, and Bob's `claim` reverts. -/
theorem legacy_refund_breaks_solvency :
    ∃ s', legacyBetaRefund w₂ 0 1 = some s' ∧
      s'.bal 0 < s'.totalShielded 0 + s'.totalClaimable 0 + s'.unsweptFees 0 ∧
      claim s' 0 7 7 = none := by
  refine ⟨_, rfl, by decide, by decide⟩

/-- **The contract's pro-rata refund is safe on the same state.** It pays `100 · 0 / 100 = 0`, the pool
stays solvent (`solvent`), and Bob's credit remains claimable. -/
theorem refund_safe_on_witness :
    ∃ s', betaRefund w₂ 0 1 = some s' ∧ s'.bal 0 = 100 ∧ s'.totalClaimable 0 = 100 ∧
      (claim s' 0 7 7).isSome := by
  refine ⟨_, rfl, by decide, by decide, by decide⟩

end Legacy

end Shield.Protocol.Pool
