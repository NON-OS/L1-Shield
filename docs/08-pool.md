# The pool

`contracts/shield/ShieldedPool.sol` holds shielded deposits, settles proven intents and pays out.

This document lists every external function, every check and revert in the order the code runs them,
and the flows for deposits, settlement, credits and claims. It is for wallet builders, relayers and
auditors.

Line references are to `contracts/shield/ShieldedPool.sol` and tests are in `test/shield/` unless a
path is given. $p = 2^{64} - 2^{32} + 1$ is the Goldilocks modulus throughout. Live values are read
from the launch pool `0x8e377752C8890E23A1E9F40eBbD41183Fc6949e2` on Sepolia with `cast call`.

- [Constants](#constants)
- [External functions](#external-functions)
- [Custody](#custody)
- [Assets, units and scale](#assets-units-and-scale)
- [`absorb`: deposit](#absorb-deposit)
- [The value ceiling](#the-value-ceiling)
- [`commitRoot`: publishing a root](#commitroot-publishing-a-root)
- [`settleBatch`](#settlebatch)
- [Nullifiers](#nullifiers)
- [Public legs, fees and credits](#public-legs-fees-and-credits)
- [Payouts a recipient refuses](#payouts-a-recipient-refuses)
- [The residual route](#the-residual-route)
- [Governance](#governance)
- [Beta mode](#beta-mode)

## Constants

| name | value | meaning |
|---|---|---|
| `MAX_FEE_BPS` | 50 | ceiling on each fee setting and on the proven fee of a withdrawal, 0.5% |
| `BPS` | 10,000 | basis-point denominator |
| `MAX_BAND_BPS` | 1,000 | ceiling on the residual price band, 10% |
| `PRICE_SCALE` | $10^{18}$ | fixed-point scale of `clearingPrice` |
| `NOTE_DOMAIN` | `0x4E4F5445` | ASCII `NOTE`, limb 3 of the public half of a commitment |
| `NATIVE_ASSET_ID` | 0 | the native coin |
| `MAX_SCALE` | $10^{18}$ | largest unit scale an asset may take |
| `MAX_INTENTS` | 64 | intents per batch the pool decodes. The launch adapter verifies batches of 1 |
| `SETTLER_WINDOW` | 24 hours | the priority of a configured settler after each settlement |
| `SETTLEMENT_EPOCH`, `OPEN_SLOT` | 24 hours, 1 hour | anyone may settle in the last hour of every epoch |
| `SETTLER_DELAY` | 48 hours | timelock on a settler change |
| `ROUTER_DELAY`, `FEE_ROUTER_DELAY` | 2 days each | timelock on a DEX router approval and on a fee router change |
| `NATIVE_PUSH_GAS` | 50,000 | gas forwarded on a native push (private, line 884) |
| `TOKEN_PUSH_GAS` | 100,000 | gas forwarded on an ERC-20 push (private, line 888) |
| `TOKEN_READ_GAS` | 50,000 | gas forwarded when the pool reads its own token balance (private, line 891) |

`wordsPerIntent` is immutable and reads 12 on the launch pool. `residualBandBps` is a storage variable
that starts at 200. The tree constants `TREE_DEPTH = 32` and `ROOT_WINDOW = 128` are in
[the tree](09-tree.md).

## External functions

| function | caller | effect |
|---|---|---|
| `absorb(assetId, amount, ownerCommit)` | anyone | deposit, [below](#absorb-deposit) |
| `commitRoot()` | anyone | publish a root, [below](#commitroot-publishing-a-root) |
| `settleBatch(proof, publicInputs, residual, attestation, clientData)` | anyone while `settler() = 0x0` | settle, [below](#settlebatch) |
| `claim(assetId, to)` | the credited address | collect a credit, [below](#payouts-a-recipient-refuses) |
| `sweepFees(assetId)` | anyone | send held fees to the current fee router |
| `executeFeeRouterChange()`, `executeSettlerChange()`, `executeRouterApproval(router)` | anyone | install a change whose timelock has passed |
| `betaRefund(assetId, depositor)` | the depositor or the owner | reverts `BetaModeAlreadyEnded` on the launch pool |
| `setBetaDepositor(depositor, allowed)` | the owner or the registrar | inert on the launch pool |
| the owner functions in [Governance](#governance) | the owner | parameters |
| `isRepresentable(a)`, `isKnownRoot(root)`, `zeros(level)` and the public getters | anyone, view | reads |
| `receive()` | anyone | accepts native proceeds of a residual swap |

## Custody

The verifier, the association registry, the tree hasher, `wordsPerIntent` and the scale of every
registered asset are fixed.

The pool has no proxy, no upgrade path and no withdrawal pause, and a new proof system needs a new
pool. None of the governance powers moves or freezes a note
([02-threat-model.md](02-threat-model.md#the-owner)).

The constructor (lines 272 to 316) refuses a zero verifier, registry or fee router (`ZeroAddress`),
a fee above `MAX_FEE_BPS` (`FeeBpsTooHigh`), a native scale above `MAX_SCALE` (`BadScale`), and a
width other than 11 or 12 words (`BadWordsPerIntent`).

A native scale of zero is stored as 1. The constructor then tests its dependencies before it
writes any state:

| check (lines 296 to 305) | revert |
|---|---|
| `hasher.hash2(left, right)` and `hasher.hashFields(input)` against known vectors | `HasherSelfTestFailed` |
| the pool derivation of a note commitment against the prover vector | `NoteCommitmentSelfTestFailed` |
| `verifier.verifyBatch(proof, publicInputs)` on a known proof | `VerifierSelfTestFailed` |

The launch pool passed the verifier check with the 32-byte digest `0x80914f72…1c30`, which
`ComposedStarkVerifier.attest` recorded after verifying the whole proof in tx
`0xa6ffb574c26b8203f473569e6e3497ef6256fd34839a8cdb54cd7ec3c2254b99` (6,748,211 gas).

The check shows that the verifier accepts an honest proof. Refusal is covered by the tests in
[02-threat-model.md](02-threat-model.md#what-the-verifier-establishes).

## Assets, units and scale

Notes, fees and public amounts count units. `scale[assetId]` is the number of base units in one
unit, so every amount that moves on chain is units times scale. The ledgers `totalShielded`,
`claimable`, `totalClaimable` and `unsweptFees` are kept in base units.

| asset | token | `scale` | `maxRelayFee` |
|---|---|---:|---:|
| 0 | native ETH | 1 (wei) | $10^{15}$ units, 0.001 ETH |
| 1 | NOX `0x3E5249A65CA513D5e11260222e0D26f46b465d36`, 18 decimals | $10^9$ | $10^{10}$ units, 10 NOX |

Asset 0 is registered by the pool constructor and asset 1 in tx
`0x25f3f01ac8a1d9a779e7526eb5d38652a55da2c7b5164051e5f5fedd2c3a9450`.

The relay caps were set in tx `0x11197557485cc911e98df343fac79feffd6ca272eeb3984afe3bfa3743a00f92`
(asset 0) and tx `0x1cbad1787ba0c33d3560b975dbfa7348b57bc3cf8d9cb251c1cc7aecb1a4c338` (asset 1).

`registerAsset(token, scale)` (line 324) is owner only, because the scale is permanent and a
squatter could otherwise pick one that caps every note of a token at a useless size.

It refuses a zero token (`ZeroAddress`), a scale of 0 or above `MAX_SCALE` (`BadScale`), a token
without code (`NotAContract`) and a token already listed (`AssetAlreadyRegistered`). It assigns the
next id, starting at 1, and emits `AssetRegistered(assetId, token, scale)`.

A scale of $10^9$ on an 18-decimal token makes one unit $10^{-9}$ token. Deposits must then be whole
units: `amount % scale != 0` reverts `InvalidAmount`, since a remainder would back no note
(`AssetScale.t.sol`).

## `absorb`: deposit

```solidity
function absorb(uint64 assetId, uint256 amount, bytes32 ownerCommit)
    external payable nonReentrant
    returns (bytes32 commitment, uint40 leafIndex)
```

The caller supplies the gross amount in base units and `ownerCommit = compress(spend_pk, blinding)`.
The pool treats `ownerCommit` as opaque and derives the commitment itself from the net value in units
(`_computeCommitmentWith`, line 841):

$$\mathrm{pub} = (v \bmod 2^{32}) + 2^{64}\lfloor v / 2^{32} \rfloor + 2^{128}\,\mathtt{assetId} + 2^{192}\,\mathtt{NOTE\_DOMAIN}, \qquad \mathrm{cm} = \mathsf{hash2}(\mathrm{pub}, \mathtt{ownerCommit}).$$

Read as four 64-bit limbs, limb 0 lowest, the public half is `[value_lo, value_hi, assetId,
NOTE_DOMAIN]`. The circuit range argument bounds the 32-bit split. The commitment does not bind the
leaf index, so a wallet uses a fresh blinding for every note
([16-wallet-integration.md](16-wallet-integration.md)).

Order of operations (lines 355 to 392), with $s$ the scale and $u = \mathtt{amount}/s$:

1. `depositsPaused` is false, else `DepositsArePaused`.
2. `betaWoundDown` is false, else `BetaIsWoundDown`.
3. The asset is registered, else `UnknownAsset`.
4. $1 \le u \le p - 2$ and `amount % s == 0`, else `InvalidAmount`.
5. `_gateBeta`, which returns at once while `betaMode` is false.
6. `ownerCommit` has every limb below $p$, else `NonCanonicalFieldElement`.
7. Native: `msg.value == amount`, else `WrongMsgValue`. ERC-20: `msg.value == 0`, else
   `WrongMsgValue`. The pool pulls `amount` with `safeTransferFrom` and requires its balance to rise by
   `amount`, else `NonStandardTokenTransfer`.
8. Split the fee in units (`ShieldLedger.splitDeposit`): $f = \lfloor u \cdot \mathtt{shieldFeeBps} / 10^4 \rfloor$
   and $v = u - f$. $v = 0$ reverts `InvalidAmount`. `shieldFeeBps` reads 25.
9. Compute the commitment over $v$ and insert it with `_insertLeafDeferred`. No root is published.
10. `totalShielded[assetId] += v s`, and emit `NoteCommitted(commitment, leafIndex)`.
11. `_payFee(assetId, f s)`: deliver the fee to the router, or hold it in `unsweptFees` and emit
    `FeeDeferred`.

A new note cannot be spent until `commitRoot` publishes a root that contains it. The cost depends on
the number $\tau$ of trailing one bits of the leaf index. Native deposits of 2 ETH on the launch pool:

| leaf | $\tau$ | gas | tx |
|---:|---:|---:|---|
| 4 | 0 | 263,690 | `0x0cf5c334d215a3c1e8aae97203c5d1d197e1dd8c598f9a96582fe623d6b6e636` |
| 5 | 1 | 364,554 | `0x89dc693d6b2a96c6a03c5f0bd1be2087a678768cf0d017918ecad61c9650086e` |
| 11 | 2 | 499,618 | `0xf0ad89004997b7aab8d0b4b2dc601e1c2186fbacbfb247bca908db81c3fe47a0` |
| 7 | 3 | 634,682 | `0x9a8b5441cf706db2534e1b46cc5e923387a2f2a73a856833ca12005c4fba5f1e` |
| 15 | 4 | 769,746 | `0xddd64bbb862c6eb4ccbfd82ee6f6d91949ea7c792dff6e45a4f3026ea951522f` |

Each trailing one past the first adds 135,064 gas, one `hash2` call and its frontier read. The 80
deposits of the launch record range from 229,490 to 958,623 gas ([12-gas.md](12-gas.md)).

## The value ceiling

A note value is two 32-bit limbs in the commitment and one limb on the public-input side. The circuit
bounds a value, a fee and a public amount by $p - 2$, and `Goldilocks.MAX_VALUE` is that bound:

| asset | largest note, units | in the token |
|---|---:|---|
| 0, scale 1 | 18,446,744,069,414,584,319 | about 18.45 ETH |
| 1, scale $10^9$ | 18,446,744,069,414,584,319 | about 18.45 billion NOX |

A larger deposit takes several notes. On the settlement side `publicAmount` and `fee` above
`MAX_VALUE` revert `AmountOutOfRange` and `FeeOutOfRange`, so the pool, the circuit and
`PublicWords.publicsOf` agree on the bound.

## `commitRoot`: publishing a root

```solidity
function commitRoot() external returns (bytes32 root)
```

Anyone may call it. It folds the frontier into the root for the current leaf count and pushes the
root into the window.

When the folded root equals `currentRoot` it returns without touching the window, so repeated calls
cannot evict roots that pending proofs use. It reverts `NoLeavesSinceLastRoot` on an empty tree.

Measured: 4,424,015 gas at leaf count 2, tx
`0x1788bdff125f9bf8d0e4df5b2a9453187d7593f10aff5e68dc8811dff5b63fd9`, block 11,772,298. The fold and
the window are in [the tree](09-tree.md).

## `settleBatch`

```solidity
function settleBatch(
    bytes calldata proof,
    uint256[] calldata publicInputs,   // N x 12 words
    ResidualExec calldata residual,
    bytes calldata attestation,
    bytes[] calldata clientData        // 2N blobs, outCm0 then outCm1 per intent
) external nonReentrant
```

`proof` is either a whole proof in one-call encoding or a 32-byte digest that
`ComposedStarkVerifier.attest` recorded for these words ([01-architecture.md](01-architecture.md#composedstarkverifier)).

### The words

Per intent, with the check each word gets in the pool (`_decodeIntent`, lines 689 to 735) and in the
verifier (`PublicWords.publicsOf`). Amounts are in units of the asset of the intent.

| # | word | pool | verifier |
|---|---|---|---|
| 0 | `noteRoot` | canonical digest, and in the window (`UnknownOrStaleRoot`) | four limbs below $p$ |
| 1 | `assocRoot` | canonical digest, and registered (`UnknownAssociationRoot`) | four limbs below $p$ |
| 2, 3 | `nf0`, `nf1` | canonical digests, `nf0 != nf1` (`DuplicateNullifier`), each unspent ([Nullifiers](#nullifiers)) | four limbs below $p$ |
| 4, 5 | `outCm0`, `outCm1` | canonical digests | four limbs below $p$ |
| 6 | `publicAmount` | read as `int256`. Negative reverts `ShieldInViaDepositOnly`, above $p - 2$ reverts `AmountOutOfRange` | one limb below $p$ |
| 7 | `fee` | at most $p - 2$ (`FeeOutOfRange`). With `publicAmount = 0`, at most `maxRelayFee[assetId]`. Otherwise $10^4 \cdot \mathtt{fee} \le 50 \cdot \mathtt{publicAmount}$. Either breach reverts `FeeExceedsCap` | one limb below $p$ |
| 8 | `assetId` | fits `uint64` and is registered (`UnknownAsset`) | one limb below $p$ |
| 9 | `clearingPrice` | below $p$ (`PriceOutOfRange`), equal in every intent of the batch (`NonUniformClearingPrice`) | one limb below $p$ |
| 10 | `recipient` | fits 160 bits (`NotAnAddress`). Zero when `publicAmount = 0` (`NoPublicLegFieldsSet`), nonzero otherwise (`RecipientRequired`) | four limbs of 48, 48, 48 and 16 bits |
| 11 | `feeRecipient` | fits 160 bits (`NotAnAddress`). Nonzero only with a nonzero fee (`FeeRecipientWithoutFee`). Zero sends the fee to the fee router | four limbs of 48, 48, 48 and 16 bits |

A canonical digest has all four 64-bit limbs below $p$ (`Goldilocks.isCanonicalDigest`), else
`NonCanonicalFieldElement`. The verifier sees $8 \cdot 4 + 4 = 36$ limbs per intent. At 12 words every
address has a single encoding, and `isRepresentable(a)` returns true for every address.

### Order of operations

Lines 406 to 459, with $k = 12$:

1. `betaWoundDown` is false, else `BetaIsWoundDown`.
2. `SettlerGate.open(settler, msg.sender, lastSettlement, now, SETTLER_WINDOW)` or
   `SettlerGate.inOpenSlot(now, SETTLEMENT_EPOCH, OPEN_SLOT)`, else `NotSettler`. With
   `settler() = 0x0` the first is always true. Then `lastSettlement = now`.
3. `publicInputs.length` is a nonzero multiple of $k$ (`BadBatchLayout`), and $N = \mathtt{length}/k \le 64$
   (`TooManyIntents`).
4. Per intent: decode and check the words above, require a uniform clearing price, check `noteRoot`
   against the window, call `associationRegistry.isRegisteredRoot(assocRoot)`, and mark `nf0` and
   `nf1` spent.
5. `verifier.verifyBatch(proof, publicInputs)`, a view call, else `InvalidProof`.
6. Record whether the attestation verifies. With `attestationVerifier() = 0x0` this is false. It sets
   only the `attested` flag of `BatchSettled`.
7. Insert the $2N$ output commitments with `_insertLeavesDeferred`. No root is published.
8. Require $2N$ `clientData` blobs (`ClientDataLengthMismatch`), and emit `NoteCommitted` and
   `OutputNote(leafIndex, clientData)` per output.
9. `_settleIntents`: debits and credits for every intent, then the transfers
   ([Public legs, fees and credits](#public-legs-fees-and-credits)).
10. `_settleResidual`, which returns at once when `residual.amountIn == 0`.
11. Emit `BatchSettled(keccak256(abi.encode(publicInputs)), N, clearingPrice, attested)`.

Every nullifier is marked spent and every output inserted before the first transfer. Before step 9
every external call is a `STATICCALL`: the registry, the verifier, the attestation verifier and the
tree hasher.

Outputs enter the tree without a root, and a recipient can spend an output only after a later
`commitRoot`.

The pool relies on the proof for conservation, value ranges, nullifier derivation, membership of the
inputs under `noteRoot` and `assocRoot`, and ownership.

Its own checks are the word rules above and per-asset solvency: a debit larger than
`totalShielded[assetId]` reverts `ShieldedBalanceUnderflow` (`ShieldLedger.debit`).

## Nullifiers

```solidity
mapping(bytes32 nullifier => bool spent) public nullifierSpent;   // line 127
```

Each intent carries two nullifiers, words 2 and 3. The pool treats each as an opaque canonical digest
and enforces three rules.

1. **Distinct within an intent.** `_decodeIntent` reverts `DuplicateNullifier` when `nf0 == nf1`
   (line 723).
2. **Spent at most once.** `_spend` (lines 737 to 741) reverts `NullifierAlreadySpent` if the flag is
   set, and otherwise sets it and emits `NullifierSpent(nf)`. The flag covers every earlier batch and
   every earlier intent of the same batch.
3. **Spent before any call that can change state.** The loop calls `_spend` for every intent before
   the verifier, before any insert and before any transfer.

No function clears a flag. A batch that reverts at a later step, an invalid proof included, reverts
its spends with it, so a nullifier is marked spent only in a batch that settles.

| property | test (`NullifierAndRoot.t.sol`) |
|---|---|
| a nullifier repeated in two intents of a batch reverts `NullifierAlreadySpent` | `test_theSameNullifierTwiceInOneBatchReverts` |
| a nullifier spent in one batch is refused in a later batch | `test_aNullifierCannotBeReplayedInALaterBatch` |
| an intent carrying a nullifier twice reverts `DuplicateNullifier` | `test_anIntentCannotCarryOneNullifierTwice` |
| a token hook that re-submits the batch during its payout is refused | `test_aReentrantSettleCannotRespendTheBatchItIsInside` |

## Public legs, fees and credits

`_settleIntents` (line 746) runs two loops over the intents and skips any intent with
`publicAmount = 0` and `fee = 0`. With $s$ the scale of the asset:

**Accounting loop.** Debit `totalShielded[assetId]` by $(\mathtt{publicAmount} + \mathtt{fee})\,s$,
since the circuit spends both. If `feeRecipient` is nonzero, credit $\mathtt{fee}\,s$ to
`claimable[assetId][feeRecipient]`. Emit `IntentUnshielded(assetId, recipient, publicAmount·s, fee·s)`.

**Transfer loop.** Pay $\mathtt{publicAmount}\,s$ to `recipient` through `_payOrCredit`. If
`feeRecipient` is zero, pay $\mathtt{fee}\,s$ to the fee router through `_payFee`.

Every intent is written to the ledgers before the first payout, so no transfer observes a half-settled
pool. The flows by kind of intent:

| intent | public words | where the value goes |
|---|---|---|
| private transfer, no fee | `publicAmount = 0`, `fee = 0`, `recipient = 0`, `feeRecipient = 0` | nothing leaves the pool |
| private transfer through a relayer | `publicAmount = 0`, `0 < fee <= maxRelayFee`, `recipient = 0`, `feeRecipient` = relayer | `fee·s` credited to the relayer, who calls `claim` |
| private transfer, fee to the protocol | as above with `feeRecipient = 0` | `fee·s` to the fee router |
| withdrawal | `publicAmount > 0`, `recipient` set, fee at most 0.5% | `publicAmount·s` pushed to the recipient, the fee credited or routed as above |

Tests: `FeeRecipient.t.sol` (`test_theFeeIsCreditedToTheFeeRecipientAndNeverPushed`,
`test_aZeroFeeRecipientSendsTheFeeToTheRouter`, `test_aPrivateTransferPaysARelayerWithinTheCap`,
`test_aTransferFeeAboveTheCapIsRefused`).

### Fees the router refuses

`_payFee` (line 937) pushes to `feeRouter` with a gas cap. If the router does not take the whole
amount, the rest is added to `unsweptFees[assetId]` and `FeeDeferred` is emitted. A broken router
blocks neither deposits nor settlement.

`sweepFees(assetId)` (line 955) is permissionless. It refuses an empty balance (`NoFeesHeld`), clears
it, and pays it to the current router without a gas cap. A failed transfer reverts the sweep and
leaves the balance in place.

## Payouts a recipient refuses

A recipient is named inside an intent by whoever built it. If a failed transfer reverted, one
recipient could void every proven intent of a batch. `_payOrCredit` (line 853) does not revert:

- Native: `call{value: amount, gas: NATIVE_PUSH_GAS}`. On failure the whole amount is credited.
- ERC-20: `_pushToken` (line 897) reads the balance of the pool, calls `transfer` in assembly with
  `TOKEN_PUSH_GAS` (`_tryTransfer`, line 920), and on failure reads the balance again. Success is a
  call that returns no data from an address with code, or a single 32-byte word equal to 1. Any other
  return is a failure. On a failure what left the pool counts as paid and only the shortfall is
  credited. If either balance read fails, the whole amount is credited.

A credit adds to `claimable[assetId][to]` and `totalClaimable[assetId]` and emits `PayoutCredited`.

```solidity
function claim(uint64 assetId, address to) external nonReentrant
```

`claim` refuses a zero `to` (`ZeroAddress`) and an empty credit (`NothingToClaim`). It clears the
credit of `msg.sender`, pays the whole amount to `to` without a gas cap, and emits `PayoutClaimed`.

A failed transfer reverts and leaves the credit. An address that cannot receive the asset names
another `to`.

Every push is gas-capped and copies at most one word of return data, so neither a recipient nor a
token can consume the gas of the batch. A settler that sends too little gas can turn a payout into a
credit, which the recipient then claims. `HostileTokenReturns.t.sol` covers each return shape.

## The residual route

`ResidualExec` is chosen by whoever calls `settleBatch`, and none of it is proven. The pool bounds it
(`_settleResidual`, line 773). No DEX router is approved on the launch pool (no `RouterApproved`
event), so every residual with `amountIn != 0` reverts `RouterNotApproved`.

- `router` must be approved (`approvedRouter`), else `RouterNotApproved`.
- `assetIn` and `assetOut` must be registered and differ (`SameAssetResidual`). `amountIn` must be a
  whole number of `assetIn` units (`InvalidAmount`).
- With $P$ the proven clearing price, $b$ = `residualBandBps` and scales $s_{in}$, $s_{out}$:

$$a = \left\lceil \frac{\mathtt{amountIn} \cdot P \cdot s_{out}}{10^{18}\, s_{in}} \right\rceil, \qquad \mathtt{amountOutMin} \ge \left\lceil \frac{a\,(10^4 - b)}{10^4} \right\rceil,$$

  else `ResidualBelowBand`.
- `BatchClearing.routeResidual` refuses a zero `amountOutMin` (`ZeroMinOut`), path endpoints that do
  not match the assets (`PathEndpointsMismatch`), and native in and out together (`NativeInAndOut`).
  It measures the output by balance change and resets token approvals to zero.
- `totalShielded[assetIn]` falls by `amountIn`. `totalShielded[assetOut]` rises by the output rounded
  down to whole units, and the remainder goes to `unsweptFees[assetOut]`.
- `ResidualRouted(assetIn, assetOut, amountIn, amountOut)` is emitted.

## Governance

The owner is `0xD4251BA8bD4F68690BaB9f27d544819cFBE11854`, a Safe with a threshold of 2 of 3
(`Ownable2Step`). Every function below is `onlyOwner` unless stated.

| action | function | delay | bound |
|---|---|---|---|
| list an ERC-20 and its scale | `registerAsset` | none | scale 1 to `MAX_SCALE`, fixed for good |
| set shield and unshield fees | `setFeeBps` | none | each at most `MAX_FEE_BPS` (`FeeBpsTooHigh`) |
| cap the relay fee of private transfers | `setMaxRelayFee` | none | registered asset, at most $p - 2$ units (`FeeOutOfRange`) |
| set the residual band | `setResidualBand` | none | at most `MAX_BAND_BPS` (`BandTooHigh`) |
| replace the fee router | `proposeFeeRouter`, `executeFeeRouterChange` (anyone) | `FEE_ROUTER_DELAY` | nonzero. `cancelFeeRouterChange` |
| replace the settler | `proposeSettler`, `executeSettlerChange` (anyone) | `SETTLER_DELAY` | zero opens settlement to anyone. `cancelSettlerChange` |
| approve a DEX router | `proposeRouter`, `executeRouterApproval` (anyone) | `ROUTER_DELAY` | nonzero |
| remove a DEX router | `revokeRouter` | none | |
| pause deposits | `setDepositsPaused` | none | settlement, claims and sweeps continue |
| attestation verifier | `setAttestationVerifier` | none | affects only the `attested` flag |
| beta allowlist, registrar, caps, pause, open deposits | `setBetaDepositor`, `setDepositorRegistrar`, `setBetaCaps`, `setBetaPaused`, `setOpenDeposits` | none | read only while `betaMode` is true |
| end beta | `endBetaMode` | none | one-way (`BetaModeAlreadyEnded`) |

A timelocked execution reverts `NoPendingChange` without a proposal and `TimelockNotReady` before
its time.

`executeSettlerChange` also resets `lastSettlement`, so the window of a new settler starts at the
change. Anything that can redirect value waits behind a timelock. Anything that only narrows what
can happen is immediate. Fee changes are immediate and capped at 0.5%.

Live values: `shieldFeeBps() = 25`, `unshieldFeeBps() = 25`, `residualBandBps() = 200`,
`settler() = 0x0`, `depositsPaused() = false`, `attestationVerifier() = 0x0`. Settlement does not read
`unshieldFeeBps`.

## Beta mode

Beta ended in tx `0xcbd9542ec16f00ce7b1e3777066e7f62716ab77d2299619a240b553deb29c9d5` (block
11,775,568), and the pool reads `betaMode() = false` and `betaWoundDown() = false`. Deposits are open to any address.

With beta over, `_gateBeta` returns at once, so the allowlist, the caps and the beta pause have no
effect. `betaRefund` reverts `BetaModeAlreadyEnded`, and `endBetaMode` cannot run again. The refund
and wind-down rules apply only to a pool still in beta, and `BetaGate.t.sol` covers them.
