# Glossary

Terms used across these documents, in the sense the launch stack gives them. Each entry names the
contract, test or document where the term is worked out in full. Symbols follow the other documents:
$p$ is the Goldilocks prime, $z$ the out-of-domain point, $q$ a query count, $\rho$ the code rate.

- [Field and proof system](#field-and-proof-system)
- [Verifier contracts](#verifier-contracts)
- [Pool and notes](#pool-and-notes)
- [Wallet, relay and network](#wallet-relay-and-network)
- [Governance and fees](#governance-and-fees)

## Field and proof system

| term | meaning |
|---|---|
| Goldilocks | The prime field $\mathbb{F}_p$ with $p = 2^{64} - 2^{32} + 1$ (`Goldilocks.P`, `contracts/shield/libraries/Goldilocks.sol:7`). Every trace cell and every digest limb is an element of it |
| $\mathbb{F}_{p^2}$ | The quadratic extension $\mathbb{F}_p[X]/(X^2 - 7)$. The element 7 generates $\mathbb{F}_p^\times$, so it is a non-residue. The challenges, $z$ and every committed value at $z$ live here. [07](07-constraints.md) |
| Limb | A single Goldilocks element held in a 64-bit word. Canonical when below $p$ (`Goldilocks.isCanonicalLimb`) |
| Digest | Four canonical limbs packed into 32 bytes, limb 0 in the low 64 bits: $d = \sum_{i=0}^{3} 2^{64 i} d_i$ with every $d_i < p$ (`Goldilocks.isCanonicalDigest`). The pool refuses a non-canonical digest with `NonCanonicalFieldElement` |
| STARK | A proof that a committed execution trace satisfies polynomial constraints, checked with hashes and the FRI low-degree test. No trusted setup and no pairing curve |
| AIR | Algebraic intermediate representation: the transition and boundary constraints over the trace |
| Trace | The execution table of the circuit: 44 columns and $2^{13}$ rows on the launch shape (`traceWidth() = 44`, `logTraceLen() = 13`) |
| Region columns, permutation columns | Columns 0 to 33 are committed under the trace root. Columns 34 to 43 are committed under the permutation root after $\beta$ and $\gamma$ are drawn (`regionWidth() = 34`) |
| Two-round commitment | The trace root is absorbed, $\beta$ and $\gamma$ are drawn from it, and only then is the permutation root committed, so the prover cannot pick permutation columns after seeing the challenges. [05](05-transcript.md) |
| Mask pair | Trace columns 42 and 43, filled with fresh randomness to hide the witness. They are opened as one $\mathbb{F}_{p^2}$ value $M_{42} + X M_{43}$ in slot 42, and slot 43 must be zero (`MaskSlotNotZero`, `maskColumn() = 42`) |
| Rank check | A test the prover runs on the masks before a proof leaves the device. The chain does not run it |
| Zero knowledge | The proof reveals nothing about the witness beyond the statement. On the launch stack it is computational: the masks come from a keyed hash of device randomness. The verifier checks soundness only |
| Transition constraint | Relates a row to the next. The launch circuit has 38 |
| Boundary constraint | Pins a cell at a fixed row to a value. The launch circuit has 62, and some of them pin cells to the public limbs |
| Pin | A boundary whose value is a public limb. `ProgramFormEvaluatorBase` refuses an image whose pins leave any of the 36 limbs unread (`PinsNotContiguous`) |
| Periodic column | A preprocessed column whose values the circuit fixes. The launch shape has 93 (`nPeriodic() = 93`), committed under the immutable `periodicRoot()` of the verifier |
| Periodic claims | The values of the 93 periodic columns at $z$ that travel with a proof. They enter the transcript and the DEEP identity |
| Constraint degree | 11 on the launch circuit. It sets the size of the composition domain |
| Composition polynomial | The combination of the constraint quotients with coefficients $1, \alpha, \alpha^2, \dots$, 100 in all (`nCoeffs() = 100`, `powerCoeffs() = true`) |
| comp_z | The value of the composition at $z$. `LaunchEvaluator` computes it on chain from the proof. No caller supplies it (`recomputesCompZ() = true`) |
| Out-of-domain point $z$ | The $\mathbb{F}_{p^2}$ point, drawn after the composition root, at which the trace, the periodic columns and the composition are opened |
| Frame | The out-of-domain openings $T_c(z)$ and $T_c(gz)$ of the 44 trace columns |
| DEEP | The quotient that combines every opening at $z$ with the committed values at a query point, 182 terms $= 2 \cdot 44 + 1 + 93$ with coefficients $1, \delta, \delta^2, \dots$ (`powerDeep() = true`). FRI then tests its low degree. [03](03-verifier-overview.md) |
| Evaluation domain | The coset $s\,\omega^{i}$, $0 \le i < N$, with $N = 2^{23}$ and coset shift $s = 7$ (`logDomain() = 23`, `cosetShift() = 7`) |
| Rate, blowup | $\rho = 2^{-6}$ on the launch shape: 5 extra blowup bits over the composition domain of $2^{17}$ (`logDegreeBound() = 17`) |
| FRI | The folding protocol that shows a committed codeword is close to a polynomial of bounded degree. [06](06-merkle-and-fri.md) |
| Radix 4 | Each FRI fold takes four values of a coset to one (`friRadix() = 4`). The launch proof has 4 FRI roots and folds |
| Coset per leaf | All four values of a fold coset sit in one Merkle leaf, so a fold costs a single authentication path |
| Final layer | The polynomial left after the last fold, sent as 512 coefficients (`logFinal() = 9`, `finalAsCoefficients() = true`). The verifier evaluates it at each final point, computed from the index |
| Query | A position drawn from the transcript at which every commitment is opened and checked. 19 on the launch shape (`nq() = 19`). FRI and the base openings share the same positions |
| Grinding | A proof-of-work nonce whose hash with the transcript state must have a set number of leading zero bits (`StarkTranscript.verifyPow`). It raises the cost of resampling the challenges it gates |
| Round nonce | The nonce after each FRI root: 20 bits each (`roundGrindBits() = 20`) |
| Final nonces | 8 chained nonces of 25 bits after the final layer, before the query positions are drawn (`finalSearches() = 8`, `grindBits() = 25`) |
| Transcript | The Fiat-Shamir state: a Keccak-256 sponge that absorbs the public limbs and every commitment and squeezes every challenge in the order of the prover. The main transcript starts from `"NONOS-STARK-EXT"` and the FRI transcript from `"NONOS-STARK-FRI-EXT"`. [05](05-transcript.md) |
| KAT | A known-answer test vector. `spec/launch-honest/transcript-kat.json` records 1,482 transcript events |
| Digest width | Bytes of a Merkle node: 24, Keccak-256 truncated (`digestBytes() = 24`). Collision resistance about $2^{96}$ |
| Soundness bits | Two figures the adapter computes on chain. Provable, 80, is the floor of the smaller of the query term 80.774533 and the commit term 81.933909 in the Johnson regime. Conjectured, 142, assumes the Reed-Solomon proximity conjecture (`soundnessBits() = (142, 80)`). [02](02-threat-model.md#soundness) |
| Johnson bound | The proven proximity regime the provable figure uses, with a loss of $\log_2(7/6)$ bits per query |
| Direct proof | The launch proof is a STARK of the join-split itself. There is no recursion and no inner proof. The adapter records zero inner fields (`soundnessForSize(1)`) |
| Join-split | The launch circuit: two input notes spent, two output notes created, with value conserved over the integers and the relay fee and any public amount accounted for |

## Verifier contracts

| term | meaning |
|---|---|
| Adapter | `ComposedStarkVerifier` `0xf64c…0927`, the `IStarkVerifier` the pool calls. It maps a batch size to a `RealSplitVerifier`, expands words to limbs, and reports soundness. It serves batches of one intent |
| `RealSplitVerifier` | `0x59AA…47eA`. Verifies a single proof shape, fixed by constructor immutables. `verifyWholeComposed` is the entry point the adapter uses |
| `LaunchEvaluator` | `0x619A…3FF6`. Evaluates the 38 transitions and 62 boundaries of the launch circuit at $z$ and returns comp_z. `N_PUBLIC() = 36` |
| Image | The compiled constraint program `LaunchEvaluator` runs, stored in data contracts and taken only if it hashes to `LaunchProgram.IMAGE_HASH`. `LaunchImage.t.sol` holds the pin to the compile of the circuit tape |
| Tape | The straight-line program of the circuit constraints that the image is compiled from. [07](07-constraints.md) |
| One-call encoding | `abi.encode(ONE_CALL, head, claims, queries, word, word)` with `ONE_CALL = keccak256("NONOS-SHIELD-ONE-CALL-v1")`. A whole proof verified inside `settleBatch`. The two trailing words are never read |
| Attest, digest | `ComposedStarkVerifier.attest` verifies a whole proof and records `keccak256(proof)` against the hash of its words. `verifyBatch` then accepts those 32 bytes for the same words only |
| Head, claims, queries | The three sections of a whole proof that the adapter passes to `verifyWholeComposed`. [04](04-proof-codec.md) |
| Package proof | The proof file a prover emits: a 40-byte header starting `NOXP`, then the proof body of 112,916 bytes (`script/shield/SettleLaunch.s.sol`) |
| Public words | The 12 words of an intent that the pool reads (`ShieldedPool._decodeIntent`) |
| Public limbs | The 36 limbs the words expand to for the verifier (`PublicWords.publicsOf`): words 0 to 5 four limbs each, words 6 to 9 one limb each, words 10 and 11 four limbs of 48, 48, 48 and 16 bits |
| Deployed surface | The files the deployed verifier reaches by import. `DeployedSurface.t.sol` pins the list for `RealSplitVerifier.sol`. [01](01-architecture.md#contracts-outside-the-deployed-path) lists the files outside it |

## Pool and notes

| term | meaning |
|---|---|
| Note | A value of one asset owned by whoever holds the spending key behind its `ownerCommit` |
| $\mathsf{compress}$ | The two-to-one Poseidon compression over Goldilocks digests, `PoseidonGoldilocks.hash2`: width 8, S-box $x^7$, 32 full rounds |
| Spending key `sk` | The secret a wallet derives from its seed. The circuit asks for it to spend |
| `spend_pk` | $\mathrm{Poseidon}(sk, \mathrm{SPEND})$. Part of the address, never seen by the pool |
| `nk` | $\mathrm{Poseidon}(sk, \mathrm{NULL})$, the nullifier key. A holder of `nk` can compute nullifiers and cannot spend |
| Blinding | Fresh randomness in every note, hiding what the commitment holds |
| `ownerCommit` | $\mathsf{compress}(\mathit{spend\_pk}, \mathit{blinding})$. A digest the pool treats as opaque |
| Commitment (`cm`) | The Merkle leaf of a note, $\mathsf{compress}(\mathit{pub}, \mathtt{ownerCommit})$ with $\mathit{pub} = v_{lo} + 2^{64} v_{hi} + 2^{128} a + 2^{192} \cdot \mathtt{0x4E4F5445}$, $v_{lo} = v \bmod 2^{32}$, $v_{hi} = \lfloor v / 2^{32} \rfloor$ (`ShieldedPool._computeCommitmentWith`) |
| Opening | The values behind a commitment: value, asset, blinding and `spend_pk`. `absorb` takes the amount, the asset and `ownerCommit` and computes the commitment itself |
| Nullifier (`nf`) | $\mathrm{Poseidon}(\mathrm{Poseidon}(nk, cm), \mathit{position})$, published when a note is spent. The pool refuses a nullifier it has seen (`NullifierAlreadySpent`) and two equal nullifiers in one intent (`DuplicateNullifier`) |
| Intent | One spend inside a batch: two nullifiers, two outputs and 12 public words. [08](08-pool.md#the-words) |
| Batch | The intents of one `settleBatch` call under a proof. The launch adapter verifies batches of one intent |
| Private transfer | An intent with `publicAmount = 0` and `recipient = 0`. Value stays in the pool |
| Withdrawal, unshield, public leg | An intent with `publicAmount > 0`: that amount leaves the pool to `recipient`, with a fee of at most 0.5% |
| Deposit, shield | `absorb`: value enters the pool as a new note, net of the shield fee. The only way value enters (`ShieldInViaDepositOnly`) |
| Clearing price | Word 9, units of the output asset per unit of the input asset scaled by $10^{18}$, uniform across a batch. It anchors the residual floor |
| Residual | The swap a settlement may route through an approved DEX router, bounded by `residualBandBps` below the proven clearing price. No router is approved on the launch pool |
| Unit, base unit, scale | Notes count units. `scale[assetId]` base units make one unit: 1 wei for asset 0, $10^9$ base units of NOX for asset 1 |
| `MAX_VALUE` | $p - 2$ units, the circuit bound on a value, a fee and a public amount |
| Leaf, leaf index | A commitment in the tree and its position, from 0 up to $2^{32} - 2$ |
| Frontier | The rightmost filled node at each level of the tree, enough state to append without rehashing old leaves. [09](09-tree.md) |
| Deferred insertion | `absorb` and `settleBatch` update the frontier only. A root appears when someone calls `commitRoot` |
| `commitRoot` | Folds the frontier with 32 `hash2` calls and publishes a root. Permissionless |
| Root window | The last `ROOT_WINDOW = 128` published roots. A proof against any of them settles |
| Anonymity set | The leaves a spend could have come from: every leaf under the root it proves against. Bounded by how many independent people use the pool. [02](02-threat-model.md#the-anonymity-set) |
| Association set | A root in `AssociationSetRegistry`, which anyone may publish (append-only, canonical, nonzero). Every intent names one as `assocRoot`, and the proof shows the inputs lie under it |
| Solvency | Per asset, a debit larger than `totalShielded` reverts `ShieldedBalanceUnderflow` |

## Wallet, relay and network

| term | meaning |
|---|---|
| Client data | The per-output blob the pool emits in `OutputNote` and never reads: the sealed note. [17](17-client-data.md) |
| Sealed note | The opening of a note encrypted to its recipient with X-Wing and ChaCha20-Poly1305, 1,186 bytes |
| X-Wing | A hybrid key encapsulation of ML-KEM-768 and X25519. A note stays secret while either holds |
| View tag | One byte of client data derived from the per-note shared secret. A scanner that sees a mismatch skips the trial decryption. About one note in 256 matches by chance |
| Trial decryption | A wallet tries to open every sealed note whose view tag matches, and keeps those it can open and whose commitment it can recompute |
| nox1 address | The address a recipient shares: a version, `spend_pk` and the X-Wing public key. [16](16-wallet-integration.md) |
| Relayer | A service behind a Tor onion that checks a proof with `eth_call` and submits `settleBatch`. It is paid the relay fee |
| Relay fee | Word 7 of a private transfer, at most `maxRelayFee` of the asset, credited to `feeRecipient` |
| Fee recipient | Word 11. The relayer, or zero to send the fee to the fee router. It is part of the proven statement |
| Credit, claim | A fee to a fee recipient, or a payout a recipient refused, is added to `claimable`. The owner of the credit takes it with `claim(assetId, to)` |
| Settler | An address that may hold priority on `settleBatch`. None on the launch pool (`settler() = 0x0`), so anyone settles |
| Settler window, open slot | With a settler configured, it has priority for 24 hours after each settlement, and anyone may settle in the last hour of every 24-hour epoch (`SettlerGate`) |
| EIP-7623 | The calldata pricing rule with a per-byte floor. The 116,708 bytes of the settlement `0x1efa772d…8fa8` cost 1,836,152 gas |
| Transaction size limit | Nodes relay transactions up to 131,072 bytes. A launch settlement carries 116,708 bytes of calldata |
| Gas cap | 16,777,216 gas per transaction (EIP-7825). A launch settlement uses 7,066,977 to 7,882,382 gas across 43 receipts |

## Governance and fees

| term | meaning |
|---|---|
| Owner | The Safe `0xD4251BA8bD4F68690BaB9f27d544819cFBE11854`, threshold 2 of 3, over the pool, the fee router and the staking contract (`Ownable2Step`). [02](02-threat-model.md#the-owner) |
| Timelock | The delay before a change that can redirect value takes effect: 2 days for a fee router or DEX router, 48 hours for a settler. Anyone executes it after the delay |
| Shield fee | `shieldFeeBps`, taken from a deposit in units, 25 bps on the launch pool, at most 50 |
| Unshield fee setting | `unshieldFeeBps`, stored and published. Settlement does not read it. Each intent pays its proven fee |
| Fee router | `ShieldFeeRouter` `0xEBE4…1df6`. Swaps fees to NOX and splits them 40% to staking, 30% to the treasury and 30% to `0x…dEaD` |
| Unswept fees | Fees the router refused, held in the pool and sent later by anyone with `sweepFees` |
| Staking | `NoxShieldStaking` `0x739e…f397`. Pays NOX stakers from the staking share, with a 7-day unstake cooldown (`cooldown() = 604800`) |
| Beta mode | The gated phase of a pool: an allowlist, caps and `betaRefund`. Ended on the launch pool (`betaMode() = false`), where those functions have no effect |
| Proxy | None. The EIP-1967 implementation slot of every launch contract reads zero, and the pool holds its verifier in an immutable |
