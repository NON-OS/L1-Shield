# Threat model

This document states what the launch verifier establishes about a proof, what NØNOS Shield keeps
private and what it publishes, and who is trusted with what: the owner, the settler, the relayer,
the RPC provider, the device that proves, and the publishers of association sets.

Read it before relying on a security property described anywhere else in these documents.

Every power listed here is read from the code and, where it depends on state, from the live Sepolia
contracts with `cast call`. [20-security-status.md](20-security-status.md) is the single list of what
the chain checks and what it does not.

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

`StagedStarkVerifier._outerTerms` computes both terms on chain from the parameters of the verifier.
With $q = 19$ queries, $\log_2(1/\rho) = e + 1 = 6$, final grind $\kappa = 25$ over $S = 8$ chained
nonces, round grind $\kappa_r = 20$ and $\log_2 N = 23$:

$$
\text{query} = q\Big(\tfrac{1}{2}\log_2\tfrac{1}{\rho} - \log_2\tfrac{7}{6}\Big) + \kappa + \log_2 S = 80.774533,
$$

$$
\text{commit} = 2\log_2 p - \Big(7\log_2 3.5 - \log_2 3 + 2\log_2 N + \tfrac{3}{2}\log_2\tfrac{1}{\rho}\Big) + \kappa_r = 81.933909,
$$

$$
\text{provable} = \big\lfloor \min(\text{query},\ \text{commit}) \big\rfloor = 80, \qquad
\text{conjectured} = q\log_2\tfrac{1}{\rho} + \kappa + \log_2 S = 142 .
$$

The constants are rounded so the figure errs low: `JOHNSON_LOSS = 222393`, `LOG_K = 127999999` and
`COMMIT_CONST = 11066090`, in millionths of a bit.

On chain, `soundnessTermsForSize(1)` returns `(80774533, 81933909)` and `soundnessBits()` returns
`(142, 80)`. `LaunchSoundness.t.sol` holds the 80-bit floor for the launch parameters.

The limits of these figures:

- The adapter constructor compares the declared query count and final grind with `nq()` and
  `grindBits()` (`SoundnessMismatch`). It does not compare the declared blowup. On the launch
  verifier, `logDomain() - logDegreeBound() = 23 - 17 = 6`, which agrees with $e + 1 = 6$.
- No contract enforces a floor. `ShieldedPool` never reads `soundnessBits()`.
- The figures bound the FRI and query layer. They assume Keccak and Poseidon behave as random
  functions, and the conjectured figure assumes the Reed-Solomon proximity conjecture.

## Digest width

The codec truncates Keccak-256 to 24 bytes for Merkle leaves, nodes and roots, and the transcript
absorbs those 24 bytes.

A Merkle commitment binds at the birthday bound of its digest, about $2^{96}$ hash evaluations at 24
bytes against $2^{128}$ at 32. `RealSplitVerifier` accepts a width of 24 or 32 at construction and
reverts on any other.

A collision is found once and reused against every proof. FRI soundness is per statement, and an
attacker repeats that work for each forgery. A 96-bit collision bound above an 80-bit per-statement
figure is consistent for that reason. Against a quantum attacker the collision bound is lower.

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
