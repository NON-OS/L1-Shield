# NOX Shield documentation

NOX Shield is a shielded pool on Ethereum L1. Deposits become notes in a depth-32 Poseidon Merkle
tree over the Goldilocks field, and each private transfer or withdrawal settles under one STARK
proof that a Solidity verifier checks in one transaction. These documents are for engineers who
change the code, and for auditors and cryptographers who decide whether to trust it.

## What the chain verifies

**The production pool**, `ShieldedPool` `0xaEe51E82965Ec1DeD870F3f4c248Ad4AdDc3e1cb`, live since
30 September 2026, is the pool the apps use. A statement is 13 words: the 12-word pool's, plus a
not-before time on a 600-second grid. `AmountPolicy` `0x660f66ab31Ca9919D9e1770FEDc88Ff2dd29CE59` takes
0.50% on deposits and withdrawals and, per private transfer, a protocol part plus one gas rung that the
proof pays to whoever lands it. Its verifier `0xDA9dD4A3e957AFD2179131273C93dabBA1186A44` is the shape
adapter over the not-before stack, bound to image `0x4364151e…2429`. Chapter 22 describes what it changes,
and [deployments](deployments.md) lists every address.

**The previous pool**, `0xD0dBCe19…4d541`, the 12-word pool, live since block 11,786,912. Chapters 01 to
21 describe it, and everything they say holds for the production pool except what chapter 22 changes.
`ComposedStarkVerifierShapes` `0xde611014…23C1` reads the shape from the proof's parameter id and hands
the proof to that shape's prepare and walk. The walk replays the format 7 transcript, with every
challenge drawn exactly, and `ShapesStraightEvaluatorAt` `0x8f9eFa66…6975` evaluates all 105 constraints
at $z$, 43 transitions and 62 boundaries, from the frame, the 59 periodic claims and the 36 public limbs.
The evaluator is bound to `IMAGE_HASH` `0x72f4ccfc…2765`, and the adapter holds the code hash of every
contract of its stack. No caller supplies `comp_z`.

The walk checks 19, 18 or 17 queries by shape over shared 32-byte Merkle paths and radix-8 FRI.
Every shape declares 80 provable bits under the 2020 theorem alone, the weakest round included, and
the pool refuses a verifier below 80. A guardian can pause for at most 7 days, extendable once.

**The launch pool (superseded)**, `0x8e377752…49e2`, has its deposits paused since block
11,785,998. Its verifier `0xf64c3996…0927` calls `RealSplitVerifier.verifyWholeComposed` on
`0x59AA9624…47eA`, and `LaunchEvaluator` `0x619A5ecd…3FF6` evaluates its 100 constraints. Its provable
soundness is set by the DEEP batching round: 54.4 bits under the 2020 theorem, 80.0 under the 2025
proximity gaps (a preprint); conjectured 142. Its own `soundnessBits()` returns 142 and 80 from two
terms, leaving that round out.

The prover is outside this repository. What is checked on chain, what is proved in Lean, what is
assumed and what is not checked is in [Security status](20-security-status.md).

## Index

| | document | covers |
|---|---|---|
| 01 | [Architecture](01-architecture.md) | the contracts and how they fit: what each one owns, and how a settlement flows through them |
| 02 | [Threat model](02-threat-model.md) | who is trusted with what: what is private, what is public, what an operator can and cannot do |
| 03 | [Verifier overview](03-verifier-overview.md) | how the EVM checks a STARK, and the verifier contracts involved |
| 04 | [Proof codec](04-proof-codec.md) | the wire format of a proof, format 7 and format 5, field by field |
| 05 | [Transcript](05-transcript.md) | the Fiat-Shamir order, exact draws, and every challenge and nonce the verifier re-derives |
| 06 | [Merkle and FRI](06-merkle-and-fri.md) | 32-byte digests and shared paths, radix-8 FRI in the 12-word pool and radix 4 at launch, and the DEEP value in layer zero |
| 07 | [Constraints](07-constraints.md) | the circuit at $z$: transitions, boundaries, public pins, and the evaluator |
| 08 | [The pool](08-pool.md) | `absorb`, `settleBatch`, nullifiers, roots, payouts, standard sizes, the flat fee, the bounded pause |
| 09 | [The tree](09-tree.md) | the incremental Merkle tree, deferred root publication, the capacity boundary |
| 10 | [Fees, liveness, governance](10-fees-liveness-governance.md) | fee routing, relay fees, the relayer registry, the root bounty, timelocks, the pause |
| 11 | [Faucet](11-faucet.md) | EIP-712 tickets and relayable claims |
| 12 | [Gas](12-gas.md) | what each operation costs, measured from receipts |
| 13 | [Deployment](13-deployment.md) | how a stack goes on chain: order, constructor arguments, and the checks each constructor runs |
| 14 | [Testing](14-testing.md) | the suite, the real-proof tests, invariants, CI, and what the tests do not establish |
| 15 | [Glossary](15-glossary.md) | the vocabulary of these documents |
| 16 | [Wallet integration](16-wallet-integration.md) | building a wallet on the 12-word pool: contracts, the prover, shapes, sizes, the flat fee, Tor, scanning, payouts |
| 17 | [Client data](17-client-data.md) | the 1,186-byte sealed note, recipient addresses, and scanning |
| 18 | [Gas research](18-gas-research.md) | the proof size formula, the calldata arithmetic, and where the verifier gas goes |
| 19 | [Deployments and receipts](19-deployments-and-receipts.md) | every deployed address and the receipt behind every figure |
| 20 | [Security status](20-security-status.md) | what is checked today, and what is not |
| 21 | [Gas drop](21-gas-drop.md) | a design for withdrawals that carry their own gas, not implemented |
| 22 | [The production pool](22-production-pool.md) | the 13th word, the fee schedule, open settlement, roots and the pause |
| | [Deployments](deployments.md) | every deployed address, the verifier pins, the fees and the landers |
| | [Deployed names](deployed-names.md) | the names some contracts were deployed under |

## Tutorials

| | tutorial | for |
|---|---|---|
| 1 | [Private payments from your own code](tutorials/01-sdk-quickstart.md) | reading fees, filling a statement, publishing a proof through Tor, waiting for it to land |
| 2 | [Running a lander](tutorials/02-run-a-lander.md) | one command to land proofs for anyone and be paid for it |
| 3 | [Checking the verifier yourself](tutorials/03-verify-the-verifier.md) | rebuilding the verifier and matching it to the deployed contract |
| 4 | [Auditing the pool's spends](tutorials/04-audit-a-week.md) | folding a window of spends into a tree anyone can reproduce |

The [repository README](../README.md#documentation) groups them the same way: the verifier byte
by byte (03 to 07), the pool and its economics (08 to 11), cost and deployment (12, 13), testing
and vocabulary (14, 15), building a wallet (16, 17), every number with its receipt (18, 19), and the production pool (22).

A reader new to the system should read 01, 02, 03 and 22, then [Security status](20-security-status.md),
before anything else.

## Conventions

- Every figure is a transaction receipt, a named test, a value in the code or an artifact, or
  arithmetic on those, and names its source. An estimate is labelled and says how it is derived.
- Shape constants (query count, trace width, coefficient count) are read from the
  `structure.json` and `layout.json` of an artifact and are not repeated as literals in tests. The launch
  artifacts are `spec/launch-honest`, `spec/launch-spend`, `spec/launch-withdraw-a`,
  `spec/launch-withdraw-b` and `spec/launch-program`, and `test/shield/LaunchBase.sol` builds the
  launch stack from them. The 12-word artifacts are in `spec/shapes`, with `MANIFEST.md` of the prover run
  that made them.
- Field elements are Goldilocks, $p = 2^{64} - 2^{32} + 1$, and extension elements are pairs
  $(c_0, c_1)$ meaning $c_0 + c_1 X$ in $\mathbb{F}_p[X]/(X^2 - 7)$.
- Every NOX Shield deployment in these documents is on Sepolia; nothing is on mainnet. The production
  pool is the pool to use; the launch pool is marked superseded wherever it is described.
