# NØNOS Shield documentation

NØNOS Shield is a shielded pool on Ethereum L1. Deposits become notes in a depth-32 Poseidon Merkle
tree over the Goldilocks field, and each private transfer or withdrawal settles under one STARK
proof that a Solidity verifier checks in one transaction. These documents are for engineers who
change the code, and for auditors and cryptographers who decide whether to trust it.

## What the chain verifies

`ShieldedPool` `0x8e377752…49e2` on Sepolia calls `ComposedStarkVerifier` `0xf64c3996…0927`,
which calls `RealSplitVerifier.verifyWholeComposed` on `0x59AA9624…47eA`. That call replays the
transcript once and has `LaunchEvaluator` `0x619A5ecd…3FF6` evaluate all 100 constraints of the
circuit at $z$, 38 transitions and 62 boundaries, from the frame, the 93 periodic claims and the
36 public limbs of the spend. The DEEP check uses that value, and no caller supplies it.

The same verifier draws the 19 query positions after four 20-bit round nonces and eight chained
25-bit final nonces, and checks FRI and the base openings at those positions. It computes its own
soundness on chain: `soundnessBits()` returns 142 conjectured and 80 provable bits.

The circuit source and the prover are outside this repository. What is checked on chain, what is
proved in Lean, what is assumed and what is not checked is in
[Security status](20-security-status.md).

## Index

| | document | covers |
|---|---|---|
| 01 | [Architecture](01-architecture.md) | the contracts and how they fit: what each one owns, and how a settlement flows through them |
| 02 | [Threat model](02-threat-model.md) | who is trusted with what: what is private, what is public, what an operator can and cannot do |
| 03 | [Verifier overview](03-verifier-overview.md) | how the EVM checks a STARK, and the verifier contracts involved |
| 04 | [Proof codec](04-proof-codec.md) | the wire format of a proof, field by field |
| 05 | [Transcript](05-transcript.md) | the Fiat-Shamir order and every challenge and nonce the verifier re-derives |
| 06 | [Merkle and FRI](06-merkle-and-fri.md) | the commitments, radix-4 FRI folding, and the DEEP value in layer zero |
| 07 | [Constraints](07-constraints.md) | the launch circuit at $z$: transitions, boundaries, public pins, and the evaluator |
| 08 | [The pool](08-pool.md) | `absorb`, `settleBatch`, nullifiers, roots, payouts |
| 09 | [The tree](09-tree.md) | the incremental Merkle tree, deferred root publication, the capacity boundary |
| 10 | [Fees, liveness, governance](10-fees-liveness-governance.md) | fee routing, relay fees, the settler window, timelocks |
| 11 | [Faucet](11-faucet.md) | EIP-712 tickets and relayable claims |
| 12 | [Gas](12-gas.md) | what each operation costs, measured from receipts |
| 13 | [Deployment](13-deployment.md) | how a stack goes on chain: order, constructor arguments, and the checks each constructor runs |
| 14 | [Testing](14-testing.md) | the suite, the real-proof tests, invariants, CI, and what the tests do not establish |
| 15 | [Glossary](15-glossary.md) | the vocabulary of these documents |
| 16 | [Wallet integration](16-wallet-integration.md) | building a wallet: deposits, scanning, intents, payouts and the faucet |
| 17 | [Client data](17-client-data.md) | the 1,186-byte sealed note, recipient addresses, and scanning |
| 18 | [Gas research](18-gas-research.md) | the proof size formula, the calldata arithmetic, and where the verifier gas goes |
| 19 | [Deployments and receipts](19-deployments-and-receipts.md) | every deployed address and the receipt behind every figure |
| 20 | [Security status](20-security-status.md) | what is checked today, and what is not |

The [repository README](../README.md#documentation) groups them the same way: the verifier byte
by byte (03 to 07), the pool and its economics (08 to 11), cost and deployment (12, 13), testing
and vocabulary (14, 15), building a wallet (16, 17), and every number with its receipt (18, 19).

A reader new to the system should read 01, 02 and 03, then [Security status](20-security-status.md),
before anything else.

## Conventions

- Every figure is a transaction receipt, a named test, a value in the code or an artifact, or
  arithmetic on those, and names its source. An estimate is labelled and says how it is derived.
- Shape constants (query count, trace width, coefficient count) are read from the
  `structure.json` and `layout.json` of an artifact and are not repeated as literals in tests. The launch
  artifacts are `spec/launch-honest`, `spec/launch-spend`, `spec/launch-withdraw-a`,
  `spec/launch-withdraw-b` and `spec/launch-program`, and `test/shield/LaunchBase.sol` builds the
  launch stack from them.
- Field elements are Goldilocks, $p = 2^{64} - 2^{32} + 1$, and extension elements are pairs
  $(c_0, c_1)$ meaning $c_0 + c_1 X$ in $\mathbb{F}_p[X]/(X^2 - 7)$.
- Every Shield deployment in these documents is on Sepolia.
