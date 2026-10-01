# Threat model

This document states what the launch verifier establishes about a proof, what NOX Shield keeps
private and what it publishes, and who is trusted with what: the owner, the settler, the relayer,
the RPC provider, the device that proves, and the publishers of association sets.

Read it before relying on a security property described anywhere else in these documents.

Every power listed here is read from the code and, where it depends on state, from the live Sepolia
contracts with `cast call`. [20-security-status.md](20-security-status.md) is the single list of what
the chain checks and what it does not.

- [12-word pool](#the-12-word-pool)
- [Assets and adversaries](#assets-and-adversaries)
- [What the verifier establishes](#what-the-verifier-establishes)
- [Soundness](#soundness)
- [Digest width](#digest-width)
- [What is private](#what-is-private)
- [What is public](#what-is-public)
- [The anonymity set](#the-anonymity-set)
- [Who is trusted with what](#who-is-trusted-with-what)
- [The owner](#the-owner)
- [The settler](#the-settler)
- [The relayer](#the-relayer)
- [The RPC provider](#the-rpc-provider)
- [The prover device](#the-prover-device)
- [Association set publishers](#association-set-publishers)
- [Deploy-time gates](#deploy-time-gates)
- [Audit status](#audit-status)

## The 12-word pool

The rest of this document was written for the launch pool (superseded). The 12-word pool keeps its model and
changes these points:

| | format 7 |
|---|---|
| **Soundness** | every shape declares 80 provable bits under the 2020 theorem alone, the weakest round included; the DEEP coefficients are independent behind a 19-bit grind, and every challenge is drawn exactly |
| **Digests** | 32 bytes, collision resistance $2^{128}$ |
| **The verifier** | immutable; accepts three parameter ids; every contract of its stack held to its code hash |
| **The owner, the Safe** | also owns `AmountPolicy`: it can change a size range or the flat fee only after 48 hours, and names the guardian |
| **The guardian** | `0x6B02…3188`: can stop deposits and settlement at once, for at most 7 days, then not again for 7 days. It cannot move notes or change a rule. While it pauses, honest withdrawals wait |
| **What is public** | a deposit or withdrawal amount is one of a short list of standard sizes, and every relayed transfer pays the same fee, so neither names a person or a wallet build |
| **The relayer** | none is needed: with `feeRecipient = address(1)` whoever submits earns the fee, and `RootBounty` pays whoever publishes a root |
| **The anonymity set** | per asset and per size, and small while the pool is new |

Timing, the deposit address and the withdrawal address are what the proof cannot hide. The wallet's
defaults, a wait before spending a new note and a fresh address for every withdrawal, and the
relayer's random settle delay and fixed root clock address them
([16-wallet-integration.md](16-wallet-integration.md#what-a-wallet-needs)).

## Assets and adversaries

| asset | held by | protected by |
|---|---|---|
| deposited value | `ShieldedPool` | the verifier answer in `settleBatch`, nullifiers, the root window |
| the spending key `sk` | the wallet of the owner | the pool sees only `ownerCommit` and never a key |
| the link between a deposit and a spend | the wallet of the depositor | the membership proof, the masked trace, and the size of the anonymity set |
| the opening of a note | the sender and the recipient | X-Wing sealing of the client data ([17-client-data.md](17-client-data.md)) |
| liveness of settlement | anyone with a proof | no settler is configured, and `SettlerGate` bounds any future settler |

The adversaries considered are a prover who submits proofs of its own making, a relayer or settler
who controls what is submitted and when, an owner who controls the parameters governance may set, an
RPC provider who serves the wallet, and an observer who reads the chain.

## What the verifier establishes

The pool calls `ComposedStarkVerifier.verifyBatch`, which calls
`RealSplitVerifier.verifyWholeComposed` with `LaunchEvaluator` as the evaluator. For a proof $\pi$
and the 36 public limbs $u$ of an intent, the verifier accepts only if:

1. $\pi$ decodes at the deployed shape, every field element is below $p$, and no byte trails.
2. The transcript replay, which absorbs $u$ first, yields the challenges the proof was made against.
3. The composition value at $z$, which `LaunchEvaluator` computes from the out-of-domain frame, the
   periodic claims, the coefficients, $(\beta, \gamma, z)$ and $u$, agrees with the committed
   composition polynomial through the DEEP identity at every query.
4. Every opened trace row, composition value, periodic row and FRI value authenticates against its
   root, and slot 43 of the mask pair is zero (`MaskSlotNotZero`).
5. Every FRI fold is consistent, the final layer of 512 coefficients agrees at every final point,
   each of the 4 round nonces has 20 leading zero bits, and the 8 chained final nonces have 25 each.

The statement enters as boundaries. The evaluator image reads every one of the 36 public limbs
through a pin (`ProgramFormEvaluatorBase` refuses an image whose pins leave a limb unread,
`PinsNotContiguous`). A proof made for one set of words fails under any other.

Up to the soundness error, acceptance means the prover committed to a trace that satisfies the 38
transitions and 62 boundaries of the launch circuit, with the public limbs pinned.

What those constraints state is in [07-constraints.md](07-constraints.md). What the tests show on
the launch shape (`test/shield/LaunchGate.t.sol`):

| property | test |
|---|---|
| every honest launch proof verifies with its 12 words | `test_everyHonestProofVerifiesWithTwelveWords` |
| a changed amount, recipient or nonce is refused | `test_aTamperedAmountIsRefused`, `test_aTamperedRecipientIsRefused`, `test_aTamperedNonceIsRefused` |
| a proof presented with the words of another spend is refused | `test_aStatementSwapIsRefused` |
| a trace that breaks one constraint is refused | `test_aBentTraceIsRefused` |
| a composition value supplied from outside is refused | `test_aCompositionTakenAsToldIsRefused` |
| value balanced only modulo $p$, and a dummy input worth $p$, are refused | `test_aValueBalancedOnlyModPIsRefused`, `test_aDummyWorthPIsRefused` |
| a nullifier the witness does not derive is refused | `test_aWrongNullifierIsRefused` |
| a mask pair opened as two values is refused | `test_aMaskOpenedApartIsRefused` |

The verifier checks soundness only. Whether a proof hides its witness depends on the prover.

## Soundness

`StagedStarkVerifier._outerTerms` computes the query and commit terms on chain from the parameters
of the verifier. The DEEP term is not computed on chain; it is derived below.
With $q = 19$ queries, $\log_2(1/\rho) = e + 1 = 6$, final grind $\kappa = 25$ over $S = 8$ chained
nonces, round grind $\kappa_r = 20$ and $\log_2 N = 23$:

$$
\text{query} = q\Big(\tfrac{1}{2}\log_2\tfrac{1}{\rho} - \log_2\tfrac{7}{6}\Big) + \kappa + \log_2 S = 80.774533,
$$

$$
\text{commit} = 2\log_2 p - \Big(7\log_2 3.5 - \log_2 3 + 2\log_2 N + \tfrac{3}{2}\log_2\tfrac{1}{\rho}\Big) + \kappa_r = 81.933909,
$$

$$
\text{deep} = 2\log_2 p - \Big(7\log_2 3.5 - \log_2 3 + 2\log_2 N + \tfrac{3}{2}\log_2\tfrac{1}{\rho}\Big) - \log_2 181 = 54.434063,
$$

$$
\text{provable} = \big\lfloor \min(\text{query},\ \text{commit},\ \text{deep}) \big\rfloor = 54, \qquad
\text{conjectured} = q\log_2\tfrac{1}{\rho} + \kappa + \log_2 S = 142 .
$$

These are the terms under the 2020 proximity-gaps theorem. Under the 2025 one (a preprint, below)
the DEEP term is 80.05 and the provable figure 80.0:

| round | 2020 theorem (BCIKS20) | 2025 preprint (BCHKS25) |
|---|---|---|
| DEEP batching, a degree-181 curve, no grind | 54.4 | 80.0 |
| first fold, radix 4, a degree-3 curve, 20-bit grind | 80.3 | 106.0 |
| query draw | 80.8 | 80.8 |
| **provable, round by round** | **54.4** | **80.0** |
| worst case of the mod-$p$ sampling bias | 52.4 | 78.0 |

The commit term above bounds a fold as a line. A radix-4 fold draws the powers
$\beta, \beta^2, \beta^3$ of one challenge, a curve of degree 3, which costs $\log_2 3$: 80.3 bits
round by round, still above 80, so the provable figure does not move. The adapter's 81.9 leaves that
factor out. The last row is explained under [The DEEP batching round](#the-deep-batching-round).

The constants are rounded so the figure errs low: `JOHNSON_LOSS = 222393`, `LOG_K = 127999999` and
`COMMIT_CONST = 11066090`, in millionths of a bit.

On chain, `soundnessTermsForSize(1)` returns `(80774533, 81933909)` and `soundnessBits()` returns
`(142, 80)`. The adapter's 80 is the smaller of two terms and leaves out the DEEP round.
`LaunchSoundness.t.sol` pins what the adapter returns and derives the DEEP term from the deployed
parameters (`test_theDeepBatchingRoundSetsTheProvableFigure`).

The limits of these figures:

- The adapter constructor compares the declared query count and final grind with `nq()` and
  `grindBits()` (`SoundnessMismatch`). It does not compare the declared blowup. On the launch
  verifier, `logDomain() - logDegreeBound() = 23 - 17 = 6`, which agrees with $e + 1 = 6$.
- The deployed pool enforces no floor and never reads `soundnessBits()`. The pool in this source
  refuses to deploy, and `settleBatch` refuses a batch, under 80 provable bits
  (`SOUNDNESS_FLOOR_BITS`).
- The on-chain figure covers two rounds of the protocol. It does not bound every challenge round,
  and the round it leaves out is the weakest (below).
- The figures bound the FRI and query layer. They assume Keccak and Poseidon behave as random
  functions, and the conjectured figure assumes the Reed-Solomon proximity conjecture.

### The DEEP batching round

The standard analysis of a Fiat-Shamir STARK goes round by round (ethSTARK documentation v1.2,
Theorem 5): each challenge is bounded on its own, and a grind raises only the round it precedes. In
that analysis the proximity-gap term $(m + \tfrac12)^7 N^2 / (3\rho^{3/2}|K|)$, $2^{-61.933909}$ at
the launch shape, belongs to the round that draws the DEEP coefficients.

At launch those coefficients are the powers $\alpha'^0, \dots, \alpha'^{181}$ of one draw
([05](05-transcript.md#powers-of-one-draw)), a curve of degree 181. Correlated agreement over a
curve of degree $l$ carries $l$ times the error of a line (Ben-Sasson, Carmon, Ishai, Kopparty and
Saraf, Theorem 1.5), so that round's error is $181 \cdot 2^{-61.933909} = 2^{-54.434063}$ per
attempt. No nonce is ground between `compRoot` and $\alpha'$. The four 20-bit round nonces come
after the FRI roots and raise the fold rounds only.

Under the 2020 theorem the weakest round sets the provable figure at **54.4 bits**. The query term,
the fold rounds and the conjectured 142 are unchanged. This is a bound, not an attack, and no attack
is known. The round-by-round treatment of batched FRI in ePrint 2025/1993 gives no bound for power
batching that removes the factor 181. Plonky3 added a grind before its batching challenge for the
same reason (pull request 2112).

**Under the 2025 proximity gaps.** Ben-Sasson, Carmon, Haböck, Kopparty and Saraf, *On Proximity
Gaps for Reed-Solomon Codes* (November 2025, a preprint; Theorems 1.5 and 4.2), bound the bad
challenges for a line up to the Johnson radius by a count linear in $N$, where the 2020 count is
quadratic:

$$
a = \frac{2(m+\tfrac12)^5 N}{3\rho^{3/2}} + \frac{(\gamma N + 1)(m+\tfrac12)}{\sqrt{\rho}} \approx 2^{40.452},
$$

with the same $m = 3$ and the same radius $\gamma = 1 - \sqrt{\rho}\,(1 + \tfrac{1}{2m})$ as the query
term. A curve of degree $M$ carries $M a$, so the DEEP round is
$2\log_2 p - \log_2(181\,a) = 80.048$ bits, and the provable figure is **80.0**. The margin is thin:
81 does not hold. The prover repository checks the figure in integer arithmetic in Lean
(`Shield.Gaps2025.live_point_clears_eighty`), with the code's true rate $(2^{17}-1)/2^{23}$ bounded
conservatively, and derives $a$ from the paper's Lemma 3.1 and condition (13) rather than its
summary line. The result is a preprint by the authors of the 2020 theorem. Until it has been
reviewed, every figure that rests on it names it.

**The sampling bias.** The live transcript turns a squeezed 64-bit word into a field element by
reduction mod $p$. The $2^{32} - 1$ smallest values then have two preimages each, so a coordinate
can be up to twice as likely as uniform. A round's error counts bad challenges, and if all of them
sat where both coordinates of an $\mathbb{F}_{p^2}$ challenge are doubled, the round would lose up to
2 bits. In that worst case the live pool is 78.0 bits under the 2025 bound and 52.4 under the 2020
one. No way to place the bad challenges there is known. The query positions are unaffected: they
are masked to a power of two.

The deployed adapter is immutable and keeps returning 80. The adapter in this source computes, under the 2020 theorem alone, the query term, each fold as the
curve its challenge powers form (a radix-$r$ fold draws $\beta, \dots, \beta^{r-1}$, a curve of
degree $r - 1$), and the DEEP round, and charges a verifier that draws challenges by reduction mod
$p$ the worst-case 2 bits on both $\mathbb{F}_{p^2}$ rounds. A DEEP grind and exact draws count
only when the verifier reports them (`deepGrindBits()`, `exactChallenges()`); the launch verifier
reports neither. At the launch parameters it returns $(142, 52)$: fold 78.348946, DEEP 52.434063. The pool's 80-bit floor refuses
to deploy on them (`LaunchSoundnessFloor.t.sol::test_theLaunchAdapterIsRefused`). The adapter does
not rest on the preprint. The fix belongs to a new deployment and does not touch the
circuit. Under the 2020 theorem alone, a grind of at least 26 bits before $\alpha'$ lifts the round
to 80.434063, and independent DEEP coefficients with a 19-bit grind lift it to 80.933909:
independent coefficients make the batch an affine space, whose error is one line's (Theorem 1.6),
with no factor 181. Drawing each challenge by rejection, a 64-bit lane accepted only when it is
below $p$, removes the sampling bias.

Sources: the ethSTARK documentation v1.2 (ePrint 2021/582), Theorem 5 and Section 6.3; *Proximity
Gaps for Reed-Solomon Codes* (ePrint 2020/654), Theorems 1.5 and 1.6; *On Proximity Gaps for
Reed-Solomon Codes* (Ben-Sasson, Carmon, Haböck, Kopparty and Saraf, 2025, a preprint), Theorems
1.5 and 4.2, Lemma 3.1; *A Simplified Round-by-round Soundness Proof of FRI* (ePrint 2025/1993).

## Digest width

The codec truncates Keccak-256 to 24 bytes for Merkle leaves, nodes and roots, and the transcript
absorbs those 24 bytes.

A Merkle commitment binds at the birthday bound of its digest, about $2^{96}$ hash evaluations at 24
bytes against $2^{128}$ at 32. `RealSplitVerifier` accepts a width of 24 or 32 at construction and
reverts on any other.

A collision is found once and reused against every proof. FRI soundness is per statement, and an
attacker repeats that work for each forgery. A 96-bit collision bound above a per-statement
figure of 54.4 (2020) or 80.0 (2025) bits is consistent for that reason. Against a quantum attacker the collision bound is lower.

## What is private

- **Which note was spent.** A settlement publishes two nullifiers and two new commitments. The
  circuit proves that each input is a leaf under the named root and that the spender knows its key,
  and no public word names the leaf. The anonymity set is every leaf under that root.
- **The link between a deposit and a spend.** A deposit publishes a commitment and a spend publishes
  a nullifier. No public value connects them.
- **The spending key.** `ownerCommit` is `compress(spend_pk, blinding)`. The pool never sees
  `spend_pk`, and `spend_pk` does not give `sk`.
- **The value of a private transfer.** An intent with `publicAmount = 0` must name no recipient
  (`NoPublicLegFieldsSet`). The values of its notes are not among the public words.
- **The witness.** The trace is masked in columns 42 and 43. The masks come from a keyed hash of
  device randomness, so hiding is computational.

## What is public

- **Deposits.** `absorb(assetId, amount, ownerCommit)` carries the address of the depositor, the
  asset, the amount and the time.
- **Value leaving the pool.** For a withdrawal, `publicAmount`, `fee`, `assetId` and `recipient` are
  public words, and `IntentUnshielded` repeats them.
- **The asset and the relay fee of every intent.** `assetId`, `fee` and `feeRecipient` are public
  words. A private transfer with a fee emits `IntentUnshielded` with a zero recipient and amount and
  the fee in base units.
- **Intent grouping.** The two nullifiers and the two output commitments of an intent travel
  together, so an observer learns which outputs came from which pair of spends.
- **Timing and submitter.** Every settlement has a block time and a sending address.

## The anonymity set

Privacy is bounded by how many unrelated people use the pool. Two notes deposited by one person give
an anonymity set of one.

Many wallets funded from one source are linkable through that source. The contracts cannot create an
anonymity set. It exists only when independent users deposit, and the Sepolia pool has few.

## Who is trusted with what

| party | trusted for | cannot |
|---|---|---|
| owner Safe | fee levels within caps, asset listing, timelocked router and settler changes, the deposit pause | move a note, replace the verifier, hasher or registry, pause settlement or claims |
| settler | none today: `settler() = 0x0`, so anyone settles | change a proven word |
| relayer | liveness of the transfers it accepts | change the amount, the recipient, the fee or the fee recipient |
| RPC provider | an honest view of chain state, and network privacy when the wallet does not use Tor | make the pool accept a false statement |
| prover device | the keys, the witness, and the randomness that hides it | make the chain accept a false statement |
| association set publishers | the meaning of the sets they publish | remove a root, or put a note under a root that does not contain it |

## The owner

The owner of `ShieldedPool` is `0xD4251BA8bD4F68690BaB9f27d544819cFBE11854` (`owner()`,
`Ownable2Step`, `pendingOwner() = 0x0`). It is a Safe: `VERSION() = "1.4.1"`, `getThreshold() = 2`,
and `getOwners()` lists three addresses. The same Safe owns the fee router and the staking contract.

| power in `ShieldedPool` | delay | bound |
|---|---|---|
| `registerAsset(token, scale)` | none | a new asset id only. An existing scale never changes |
| `setFeeBps` | none | each fee at most `MAX_FEE_BPS = 50`. Settlement does not read `unshieldFeeBps` |
| `setMaxRelayFee` | none | at most $p - 2$ units. Lowering it refuses private transfers whose proven fee exceeds the new cap |
| `setResidualBand` | none | at most `MAX_BAND_BPS = 1000` |
| `proposeFeeRouter`, executed by anyone | 2 days | the new router receives future fees only |
| `proposeSettler`, executed by anyone | 48 hours | bounded by `SettlerGate` ([The settler](#the-settler)) |
| `proposeRouter`, executed by anyone | 2 days | approving a DEX router opens the residual route of `settleBatch`, whose floor rests on the proven clearing price. No router is approved on the launch pool |
| `revokeRouter`, `setDepositsPaused` | none | narrow what can happen. The pause stops `absorb` only |
| `setAttestationVerifier` | none | sets the `attested` flag of `BatchSettled` only |
| beta allowlist, caps and pause | none | inert: `betaMode() = false`, and `endBetaMode` is one-way |
| `transferOwnership`, `renounceOwnership` | two steps for a transfer | from `Ownable2Step` |

The owner cannot replace the verifier, the association registry, the tree hasher or
`wordsPerIntent`, which are immutable.

No owner function moves a note or a credit in `claimable`. Held fees go to the fee router, which the
owner can replace after 2 days. Settlement, `claim`, `sweepFees` and `commitRoot` have no pause.

In `ShieldFeeRouter` the owner sets the split, with the treasury share at most
`MAX_TREASURY_BPS = 5000`, appoints a keeper, and changes the staking contract, the treasury or a
buyback DEX router after `TIMELOCK_DELAY = 2 days`.

On the launch router the treasury is `0x7098…65dE`, an address without code that is also a Safe
owner. These powers reach fees only.

In `NoxShieldStaking` the owner can only set the reward notifier. It cannot move stakes or rewards.

## The settler

`ShieldedPool.settler()` is `0x0`, so `SettlerGate.open` returns true for every caller and anyone may
call `settleBatch`. A sender can submit its own proof with no relayer at all.

If the owner installs a settler through the 48-hour timelock, that settler has priority for
`SETTLER_WINDOW = 24 hours` after each settlement. `SETTLER_DELAY` is longer than
`SETTLER_WINDOW`, so a hostile change lands after settlement has opened.

Anyone may still settle in the last `OPEN_SLOT = 1 hour` of every `SETTLEMENT_EPOCH = 24 hours`
(`SettlerGate.inOpenSlot`). No intent can be kept out for longer than an epoch
(`SettlerWindow.t.sol`: `test_anActiveSettlerCannotExcludeAnyoneBeyondOneEpoch`).

The adapter also stores `settler() = 0x0`. No code path of `ComposedStarkVerifier` reads it.

## The relayer

The relayer is an automatic service behind a Tor onion. It checks a proof with `eth_call` and then
submits `settleBatch`. It sees the proof, the 12 words and the sealed notes. It sees no key, and a
wallet that reaches it over Tor shows it no IP address.

| the relayer can | the relayer cannot |
|---|---|
| drop or delay a transfer | change any public word: the fee and `feeRecipient` are words 7 and 11 of the proven statement |
| learn the time a transfer was requested | open a sealed note |
| choose the gas price it pays | take a fee larger than `maxRelayFee` of the asset, 1e15 wei for asset 0 and 1e10 units for asset 1 on the launch pool |

Anyone who copies a pending transaction submits the same words, so the fee still goes to the proven
`feeRecipient`.

The fee is credited to `claimable` and taken with `claim`, so a fee recipient has no call in which
to refuse or revert. A dropped transfer spends nothing, and the sender can submit the same proof
itself while its root stays in the window.

## The RPC provider

A wallet reads roots, events and balances through an RPC endpoint and sends transactions through
one. The provider sees the IP address of a wallet that does not route through Tor, and the time and
content of every request.

A provider can withhold or falsify what it serves: hide an `OutputNote`, report a stale root, or
answer an `eth_call` wrongly.

None of this moves value. A proof against a root the pool does not know reverts
`UnknownOrStaleRoot`, and a wallet recomputes the commitment of every note it opens. Wallets fetch
every `OutputNote`, so the requests reveal no recipient.

## The prover device

The device holds the seed, `sk`, the openings of its notes and the witness of every proof. It draws
the mask randomness, and a rank check on the masks runs on the device before a proof leaves it. The
chain checks none of this.

A compromised device can spend the notes of its owner and can leak the witness. It cannot make the
verifier accept a false statement, beyond the soundness error above. Hiding rests on the keyed hash
that derives the masks and on the randomness of the device.

## Association set publishers

`AssociationSetRegistry.publishRoot` is open to anyone. It refuses a zero root and a non-canonical
digest, and records any other with its publisher and a URI. Nothing removes a root.

The pool requires `assocRoot` to be registered, and the proof requires the input notes to lie under
it. A root carries no statement about the origin of the funds under it.

What a set means comes from its publisher, and which publishers to trust is a client decision. A
root published over a subset of notes lets a user show that their funds come from that subset
without revealing which notes are theirs.

## Deploy-time gates

The `ShieldedPool` constructor reverts unless:

1. the hasher reproduces a `hash2` vector and a `hashFields` vector (`HasherSelfTestFailed`),
2. the pool derivation of a note commitment reproduces the prover vector
   (`NoteCommitmentSelfTestFailed`), and
3. the verifier accepts a known proof for known public words (`VerifierSelfTestFailed`).

A pool whose commitment function disagrees with the circuit would insert leaves no proof can open.
Gate 2 refuses that.

Gate 3 shows that the verifier accepts an honest proof, and says nothing about refusing dishonest
ones. The tests in [What the verifier establishes](#what-the-verifier-establishes) cover refusal.

## Audit status

No part of this system has had an external audit. See [20-security-status.md](20-security-status.md).
