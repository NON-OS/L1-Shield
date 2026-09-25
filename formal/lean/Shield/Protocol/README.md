# Shield/Protocol: the contract layer

Four modules model the Solidity that moves value in NØNOS Shield and prove the properties the pool
relies on. The verifier is out of scope here. It is an abstract oracle, and what it is meant to
establish is a named hypothesis. Line numbers refer to `contracts/shield/` in this repository (per-asset
unit scale, `MAX_VALUE = p − 2`, optional `feeRecipient` word, pro-rata `betaRefund`).

```
cd formal/lean
lake build Shield.Protocol.Limbs Shield.Protocol.SettlerGate Shield.Protocol.FeeRouter Shield.Protocol.Pool
grep -rn "sorr[y]" Shield/Protocol       # empty
```

Every theorem depends only on `propext`, `Classical.choice` and `Quot.sound`, checked with
`#print axioms`. `FeeRouter.split_three` depends on none. `Axioms.lean` does not list these modules.
`Limbs.P` is tied to `Shield.Field.P` by `P_eq_field`.

---

## 1. `Limbs.lean`: public words and limbs

Source: `PublicWords.publicsOf(publicInputs, perIntent)` (verifier/PublicWords.sol:33-68),
`Goldilocks.isCanonicalDigest` (libraries/Goldilocks.sol:16-22), `ShieldedPool._decodeIntent`
(ShieldedPool.sol:667-713).

A layout of width $W$ marks each position $w < W$ as a digest (four limbs) or a scalar (one limb).
The rule is $w \le 5 \lor w \ge 10$. Write $\ell_l(x) = \lfloor x / 2^{64 l}\rfloor \bmod 2^{64}$
and $p = 2^{64} - 2^{32} + 1$. For $W = 11$ an intent has $32$ limbs, for $W = 12$ it has $36$,
matching `limbs(perIntent) = 4·perIntent − 12` (`limbsPerIntent_v1`, `limbsPerIntent_v2`). At
$W = 12$ the contract splits words 10 and 11 into 48-bit limbs (PublicWords.sol:50-55). `Layout.v2`
reads them as four 64-bit limbs, so it does not model that branch.

| theorem | statement |
|---|---|
| `publicsOf_ok_iff_canonical` | $\mathrm{publicsOf}(w)\ \text{succeeds} \iff |w| \neq 0 \land W \mid |w| \land \forall i,\ \mathrm{canon}_i(w_i)$, where $\mathrm{canon}_i(x) = \forall l<4,\ \ell_l(x) < p$ at digest positions and $x < p$ otherwise |
| `publicsOf_lt_P`, `publicsOf_lt_two_pow` | every emitted limb $v$ satisfies $v < p < 2^{64}$ |
| `publicsOf_length` | $|\mathrm{publicsOf}(w)| = \mathrm{limbs}(W)\cdot |w|/W$ |
| `pack_publicsOf` | $w_i < 2^{256} \Rightarrow \mathrm{pack}(\mathrm{publicsOf}(w)) = w$, with $\mathrm{pack}(g) = \sum_l g_l\, 2^{64 l}$ per word |
| `publicsOf_pack` | $|v| = \mathrm{limbs}(W)\cdot m,\ m \ge 1,\ v_j < p \Rightarrow \mathrm{publicsOf}(\mathrm{pack}(v)) = v$ |
| `publicsOf_injective` | $\mathrm{publicsOf}(w) = \mathrm{publicsOf}(w') \Rightarrow w = w'$ on `uint256` words |
| `isCanonicalDigest_iff` | for $x < 2^{256}$: $\mathrm{isCanonicalDigest}(x) \iff \forall l<4,\ \ell_l(x) < p$ |
| `maxValue_redeploy_canonical` | $v \le p - 2 \Rightarrow v < p$ |
| `pool_range_admits_noncanonical` | a bound of $2^{64}-1$ would admit $v = p$, which only the verifier rejects |
| `recipient_not_always_representable` | $\exists a < 2^{160}$ with $\ell_0(a) \ge p$: the four-limb layouts reject it at words 10 and 11 |

The limb is modelled bit for bit, `(word >>> 64l) &&& LIMB`, and `limb_eq` proves it equal to
$\ell_l$. The two loops are modelled as one recursion over the global word index `base + w`, which
visits words in the same order and reverts at the same first failing limb, with the same error
payload.

**Gap.** Solidity's `uint256[]` is a list of naturals below $2^{256}$. The round trip and
injectivity carry that hypothesis explicitly. `publicsOf` in the model returns `Except` where the
Solidity reverts. At $W = 11$ the verifier rejects about $2^{-32}$ of all addresses at word 10, so a
payout to such an address can never be proven (`ShieldedPool.isRepresentable` reports it). The
contract's 12-word branch accepts every address below $2^{160}$ and is not modelled.

## 2. `Pool.lean`: the pool as a state machine

Source: `ShieldedPool.sol` (`absorb` 336-380, `settleBatch` 386-447, `_decodeIntent` 667-713,
`_spend` 715-719, `_settleIntents` 723-745, `_settleResidual` 749-788, `_reduceShielded` 799-803,
`_payOrCredit` 827-836, `_credit` 838-843, `claim` 847-855, `_pushToken` 868-875, `_payFee`
906-920, `sweepFees` 924-932, `_payOut` 934-942, `betaRefund` 563-588, `endBetaMode` 552-558,
`setFeeBps` 457-462, `setResidualBand` 465-469, `executeSettlerChange` 645-654, `receive` 954),
`ShieldLedger.sol` (`splitDeposit`, `debit`), `BatchClearing.routeResidual` (31-62).

State: $\mathrm{bal}_a$ (the pool's holding), $T_a$ = `totalShielded`, $C_a$ = `totalClaimable`,
$F_a$ = `unsweptFees`, `claimable`, `nullifierSpent`, `nextLeafIndex`, the beta fields, fee
settings, settler fields, and two ghosts: $S_a$ (`surplus`, value received with no liability) and
$N_a$ (`noteValue`, net note value in base units). Each entry point is `State → Option State`.
Every environment choice (how much of a push arrives, what the router delivers, what the verifier
answers) is an argument. Parameters are `scale` $s_a \ge 1$, `maxValue`, and whether the intent has
the `feeRecipient` word.

**The hypothesis R** (`Conserves`, `Sound`): if $V(\pi, \vec{it})$ accepts, then for every intent
$\mathrm{in} = \mathrm{out} + \mathrm{publicAmount} + \mathrm{fee}$ (in units).

| theorem | statement |
|---|---|
| `conservation` (a) | for every reachable state and asset $a$: $\mathrm{bal}_a = T_a + C_a + F_a + S_a$ |
| `solvent` | $T_a + C_a + F_a \le \mathrm{bal}_a$ |
| `nullifier_once` (b) | along any run, the spent nullifiers form a list $L$ with $\mathrm{Nodup}(L)$ and $\mathrm{spent}(n) \iff n \in L$ |
| `fee_caps` (c) | $\mathrm{shieldFeeBps}, \mathrm{unshieldFeeBps} \le 50$, $\mathrm{residualBandBps} \le 1000$ |
| `absorb_fee_le` (c) | $\mathrm{fee}(u) \le \lfloor 50u/10^4\rfloor$ and $\mathrm{fee}(u) + \mathrm{value}(u) = u$ |
| `settle_fee_le` (c) | each settled intent has $10^4\cdot\mathrm{fee} \le 50\cdot \mathrm{publicAmount}$ |
| `woundDown_final` (d) | from a wound-down state, every later state is wound down and `absorb`, `settleBatch` return `none` for all arguments |
| `leafCount_mono` (e) | $s \to^* t \Rightarrow \mathrm{leaves}(s) \le \mathrm{leaves}(t)$ (`leafCount_step`: $+1$ per absorb, $+2n$ per batch) |
| `shielded_eq_notes` | under `Sound V`, on runs without residual swap or refund, $T_a = N_a$ |
| `legacy_refund_breaks_solvency` | a refund that floors $T_0$ at zero reaches $\mathrm{bal}_0 < T_0 + C_0 + F_0$ and Bob's `claim` reverts |
| `refund_safe_on_witness` | the contract's pro-rata refund pays $0$ on the same state and Bob can claim |

The proof of (a) is one integer function, the slack $\sigma_a = \mathrm{bal}_a - T_a - C_a - F_a - S_a$,
and one lemma per primitive: a payment of $x$ lowers $\sigma$ by $x$ whether it arrives, is
credited or is held. A debit of $T$ raises it by $x$. In `settleBatch` the first loop debits
$(\mathrm{pa} + \mathrm{fee})s$ and credits a named fee recipient, which raises $\sigma$ by
$\mathrm{leg} = \mathrm{pa}\cdot s + [\mathrm{feeRecipient} = 0]\,\mathrm{fee}\cdot s$. The second
loop pays $\mathrm{leg}$. `absorb` uses $\mathrm{amount} = u s$ (from `amount % s == 0`) and
$u = \mathrm{fee} + \mathrm{value}$.

**Gap.**
* Guards that only make calls revert are dropped (roots, association registry, clearing price
  uniformity, slippage band, pauses, allowlist and caps, `openDeposits`, owner and caller checks,
  timelocks, `registerAsset`, the same-asset residual check). Dropping a guard enlarges the set of runs, so the invariants still
  hold for the contract. `uint256` overflow is not modelled for the same reason, except where the
  contract relies on a checked subtraction, which is a guard in the model.
* **Relay fees are not modelled.** `DecodeOk` requires `fee = 0` when `publicAmount = 0`, and
  `_settleIntents` in the model skips such intents. The contract admits a relay fee up to
  `maxRelayFee[assetId]` there (ShieldedPool.sol:708) and debits and pays it (lines 728-743). The
  theorems do not cover batches with a relay fee.
* Tokens are standard. A push moves at most the amount asked (`arrived`), `_payOut` moves the whole
  amount or reverts, and no token changes balances on its own (rebasing, fee-on-transfer after
  the `absorb` check). A token that reports success and moves nothing breaks conservation and is
  outside the model. External calls are atomic. `nonReentrant` excludes reentrancy, and a
  callee's plain transfer to the pool is the `donate` step.
* The router moves `amountIn` and no more. The model credits the whole `received` to
  `totalShielded`, and the contract moves the sub-unit dust to `unsweptFees` (lines 780-785).
  The model admits a same-asset ERC-20 swap, which the contract refuses (line 755), and records its
  gain as `surplus`.
* The model asks the verifier before the nullifier writes and the contract after them (line 424).
  It is a `view` call and a revert undoes both.
* R is a hypothesis. `shielded_eq_notes` excludes residual swaps and refunds. A swap moves value
  between assets at a price the model does not track, and a refund pays out a note
  which stays in the tree.
* A refund that floors `totalShielded` at zero and pays the whole recorded deposit is paid out of
  other liabilities once a beta depositor's note has been unshielded (`legacy_refund_breaks_solvency`).
  The contract's checked, pro-rata refund pays $0$ on that state (`refund_safe_on_witness`).

## 3. `SettlerGate.lean`: the settler gate

Source: `SettlerGate.open` (SettlerGate.sol:9-17), `SettlerGate.inOpenSlot` (20-22), the gate in
`settleBatch` (ShieldedPool.sol:395-398), $E$ = `SETTLEMENT_EPOCH` $= 86400$, $\Sigma$ = `OPEN_SLOT`
$= 3600$, $W$ = `SETTLER_WINDOW` $= 86400$ (ShieldedPool.sol:81-84).
$\mathrm{pass}(t) = \mathrm{open} \lor (t \bmod E \ge E - \Sigma)$.

| theorem | statement |
|---|---|
| `inOpenSlot_iff_slot` | for $0 < \Sigma \le E$: $t \bmod E \ge E - \Sigma \iff \exists s \equiv E - \Sigma \pmod E,\ s \le t < s + \Sigma$ |
| `exists_slot_within_epoch` | $\forall t\ \exists s,\ t < s \le t + E,\ s \equiv E-\Sigma,\ \forall u \in [s, s+\Sigma),\ \mathrm{inOpenSlot}(u)$ |
| `inOpenSlot_const_iff` | the slot is $82800 \le t \bmod 86400$, the last hour of each UTC day |
| `passes_in_slot` | within the slot anyone passes |
| `passes_iff_settler` | $\mathrm{settler} \ne 0,\ t < \mathrm{last} + W,\ \lnot\mathrm{inOpenSlot}(t) \Rightarrow (\mathrm{pass} \iff \mathrm{caller} = \mathrm{settler})$ |
| `anyone_passes_within_epoch` | $\forall t\ \exists u \in (t, t+E],\ \mathrm{pass}(u)$ for every caller |

Also `settler_passes`, `passes_of_no_settler`, `passes_after_window`.

**Gap.** Timestamps are naturals. `lastSettlement` is a `uint64`, so the sum cannot overflow a
`uint256`. Liveness is about the gate only. The call must still pass every other check.

## 4. `FeeRouter.lean`: the fee split

Source: `ShieldFeeRouter.distribute` (ShieldFeeRouter.sol:132-152), `_checkSplit` (219-222).
$\mathrm{st} = \lfloor t\,\sigma/10^4 \rfloor$, $\mathrm{tr} = \lfloor t\,\tau/10^4\rfloor$,
$\mathrm{bu} = t - \mathrm{st} - \mathrm{tr}$ (unchecked).

| theorem | statement |
|---|---|
| `split_sum` | $\sigma + \tau \le 10^4 \Rightarrow \mathrm{st} + \mathrm{tr} \le t$ (no wrap) and $\mathrm{st} + \mathrm{tr} + \mathrm{bu} = t$ |
| `split_rounding` | $0 \le t\sigma - 10^4\mathrm{st} < 10^4$, likewise for tr, and $0 \le 10^4\mathrm{bu} - t\beta < 2\cdot 10^4$ with $\beta = 10^4 - \sigma - \tau$ |
| `split_4000_3000_3000` | the 4000 / 3000 / 3000 split passes `_checkSplit`, parts sum to $t$, $\mathrm{st} = \lfloor 0.4t\rfloor$, $\mathrm{tr} = \lfloor 0.3t\rfloor$, $0.3t \le \mathrm{bu} < 0.3t + 2$, $\mathrm{tr} \le \mathrm{bu}$ |
| `split_three` | $t = 3$ gives $(1, 0, 2)$: burn exceeds $\lfloor 0.3t\rfloor$ by 2, the bound is attained |

**Gap.** `total · bps` overflow (`total > 2^{256}/10^4`) reverts in Solidity and is not modelled.
The whole NOX balance is split, so what the router holds is the input.
