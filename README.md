<p align="center">
  <img src="docs/assets/banner.png" alt="NØNOS: Privacy, Proofs, Software" width="100%"/>
</p>

<div align="center">

# NOX Shield

**Private payments on Ethereum L1. Each transfer is settled by one STARK, verified in one transaction.**

No trusted setup · No pairing curves · No SNARK wrapper · Zero-knowledge proofs · Post-quantum notes

</div>

> [!WARNING]
> **Sepolia testnet, before any external audit.** Nothing is deployed on mainnet and the pool holds no
> real value. The anonymity set is small. Read [docs/20-security-status.md](docs/20-security-status.md)
> before you rely on anything here.

NOX Shield lets two people pay each other in ETH or NOX on Ethereum without the chain recording who
paid whom or how much. Money goes into a shielded pool and becomes notes only their owner can open.
Spending a note is a zero-knowledge proof that the spender owns unspent notes in the pool and that the
amounts balance; the proof says nothing about which notes. Ethereum checks the proof itself, in
Solidity, with no trusted setup and no committee.

## A transfer in six steps

1. **Shield.** A wallet deposits a standard amount (1, 2 or 5 times a power of ten) into the pool. The
   chain sees an address and an amount go in; the pool adds a note commitment to its tree. Within about
   five minutes a root that contains it is committed and the note can be spent.
2. **Prove.** The sender's phone builds a STARK: it owns two unspent notes under a known root, they
   have never been spent, and what goes in equals what comes out plus the fee. The new notes for the
   recipient are sealed with X-Wing (ML-KEM-768 and X25519), so only the recipient can open them.
3. **Hand off.** The phone sends the proof through Tor, to a lander's onion service or to the public
   Waku topic `/nox-shield/1/proof/proto`. No server learns the sender's IP address.
4. **Land.** Any lander checks the proof against the pool's own rules and submits it. The proof pays
   the lander a fixed gas rung, so landing pays for itself and nobody has to be trusted to do it.
5. **Settle.** The pool verifies the STARK on chain, marks the two nullifiers spent so the notes can
   never be spent again, and adds the two new notes to its tree. The chain sees that some notes were
   spent and two were made; not whose, and not how much.
6. **Receive.** The recipient's wallet reads every new note, opens the one sealed to it, and owns it.
   It can spend it privately in turn, or withdraw to any address, which is public.

## The production pool

| | |
|---|---|
| **Pool** | `ShieldedPool` [`0xaEe51E82965Ec1DeD870F3f4c248Ad4AdDc3e1cb`](https://sepolia.etherscan.io/address/0xaEe51E82965Ec1DeD870F3f4c248Ad4AdDc3e1cb) on Sepolia, owned by a 2 of 3 Safe |
| **Proof** | STARK over Goldilocks, format 7: 32-byte Keccak commitments with shared Merkle paths, FRI at radix 8, challenges drawn exactly in $\mathbb{F}_{p^2}$ |
| **Statement** | 13 words: roots, nullifiers, new note commitments, amount, fee, asset, recipient, fee recipient, and a not-before time on a 600-second grid |
| **Shapes** | A: 19 queries after a 28-bit grind. A′: 18 after 31 bits. B: 17 after 33 bits. The verifier accepts these three and nothing else |
| **Soundness** | 80 provable bits for every shape under the 2020 proximity-gap theorem alone, the weakest round included; the query phase at shape A gives 80.8. The pool refuses a verifier below 80 |
| **Fees** | 0.50% on deposits and withdrawals. A private transfer pays 0.0005 ETH (or 400 NOX) plus one gas rung, from 0.0025 ETH (or 2,000 NOX), to whoever lands it |
| **Gas** | the first private transfer on this pool used 3,934,660 gas |
| **Trust** | no setup ceremony, no proxy, no upgrade key over the verifier. A guardian can pause deposits and settlement for 7 days, extendable once by the Safe |

Every address, the verifier's pins and the five landers are in [docs/deployments.md](docs/deployments.md).
What the production pool adds to the design the chapters describe is in
[docs/22-production-pool.md](docs/22-production-pool.md).

## Repository

```
contracts/shield/                  the pool, amount policy, fee router, root bounty, note tree, hashers,
                                   association sets, staking, the relayer registry of the previous pool
contracts/shield/verifier/         the field, transcript, Merkle and FRI code, and the launch verifier
contracts/shield/verifier/shapes/  the format 7 shape adapter, and the previous pool's prepare, walk and evaluator
contracts/shield/verifier/nb/      the production pool's prepare, walk and evaluator (13-word statements)
contracts/faucet/, contracts/rewards/  the testnet faucet and the link registry
spec/                              pinned proofs and evaluator images: not-before/ (production), shapes/
                                   (previous pool), and the launch program, proofs and refused proofs
script/shield/                     deploy, settle and fork-rehearsal scripts
script/tools/                      program generators, the fast Poseidon generator, the nullifier tree
lander/                            a lander: takes proofs, checks them, lands them, commits roots
settlement/                        the proof package, publishing through Tor, a lander's listener, the installer
sdk/                               @nonos/shield: fees, statements, packages, publishing, landing status
test/                              unit, property, invariant, symbolic and real-proof tests
formal/lean/                       Lean proofs, and where they stop
deployments/                       every address on Sepolia, machine-readable, and the receipts
docs/                              the design, one topic per file, and the tutorials
```

## Build and test

```sh
git clone --recurse-submodules https://github.com/NON-OS/L1-Shield
cd L1-Shield
forge build
forge test
python3 lander/test_relayer.py
cd sdk && npm install && npm test
cd ../formal/lean && lake exe cache get && lake build
```

One test forks mainnet and returns early when `MAINNET_RPC_URL` is unset. The invariant suites run at
full depth in CI; `FOUNDRY_INVARIANT_RUNS=64 forge test` is a quicker local run. `DeployedSurface.t.sol`
uses `ffi` to run `test/tools/import_closure.py`. The symbolic checks run under Halmos, as
[docs/14](docs/14-testing.md) shows.

## Tutorials

| | |
|---|---|
| [Private payments from your own code](docs/tutorials/01-sdk-quickstart.md) | read the fees, fill a statement, publish a proof through Tor, wait for it to land |
| [Running a lander](docs/tutorials/02-run-a-lander.md) | one command to land proofs for anyone and be paid for it |
| [Checking the verifier yourself](docs/tutorials/03-verify-the-verifier.md) | rebuild the verifier and match it to the deployed contract |
| [Auditing the pool's spends](docs/tutorials/04-audit-a-week.md) | fold a window of spends into a tree anyone can reproduce |

## Documentation

| | |
|---|---|
| [01 Architecture](docs/01-architecture.md) · [02 Threat model](docs/02-threat-model.md) | the contracts and how they fit; who is trusted with what |
| [03 Verifier](docs/03-verifier-overview.md) · [04 Codec](docs/04-proof-codec.md) · [05 Transcript](docs/05-transcript.md) · [06 Merkle and FRI](docs/06-merkle-and-fri.md) · [07 Constraints](docs/07-constraints.md) | the verifier, byte by byte |
| [08 Pool](docs/08-pool.md) · [09 Tree](docs/09-tree.md) · [10 Fees and governance](docs/10-fees-liveness-governance.md) · [11 Faucet](docs/11-faucet.md) | the pool and its economics |
| [12 Gas](docs/12-gas.md) · [13 Deployment](docs/13-deployment.md) · [18 Gas research](docs/18-gas-research.md) | what each operation costs, and how a stack goes on chain |
| [14 Testing](docs/14-testing.md) · [15 Glossary](docs/15-glossary.md) | how it is tested, and the vocabulary |
| [16 Wallet integration](docs/16-wallet-integration.md) · [17 Client data](docs/17-client-data.md) | building a wallet |
| [19 Receipts](docs/19-deployments-and-receipts.md) · [Deployments](docs/deployments.md) · [Deployed names](docs/deployed-names.md) | every address, and the receipt behind every figure |
| [20 Security status](docs/20-security-status.md) · [21 Gas drop](docs/21-gas-drop.md) · [22 The production pool](docs/22-production-pool.md) | what is checked and what is not; a design not built; what the production pool adds |

## Limits

| Limit | Why |
|---|---|
| No external audit | the verifier, the evaluator and the pool are tested and partly proved in Lean; no outside party has reviewed them |
| Sepolia only | nothing is deployed on mainnet, and test assets have no value |
| Small anonymity set | privacy grows with the number of notes under a root, and the pool is new |
| Landers today are run by NØNOS | anyone can run one with [one command](docs/tutorials/02-run-a-lander.md), and a proof's owner can always land it alone, at the cost of linking its public account |
| Deposits and withdrawals are public | an address, a standard amount and a time enter or leave the pool in the clear |
| Amount and timing correlation | depositing an amount and withdrawing the same amount soon after links them, whatever the proof hides |
| The asset is public | an ETH transfer can only come from an ETH note |
| A bounded pause | a guardian can stop deposits and settlement, withdrawals included, for 7 days; the Safe can extend it once by 7 days, announced 48 hours ahead |
| Computational zero knowledge | the masks come from a keyed hash of device randomness, so hiding rests on that hash and the device's randomness |
| Phone proving time | measured on a server (35.8 seconds for shape A on 6 cores, 50.9 on 4), not yet on a phone |
| Lean coverage | [formal/lean/README.md](formal/lean/README.md) lists every gap |

## Security

Report a vulnerability privately to `team@nonos.systems`, as [SECURITY.md](SECURITY.md) describes, and
never in a public issue.

## License

MIT, see [LICENSE](LICENSE). Files whose SPDX header reads `AGPL-3.0-or-later` are under that
license instead.

The banner uses "Etna Volcano Paroxysmal Eruption July 30 2011" by gnuckx, licensed under
[CC BY 2.0](https://creativecommons.org/licenses/by/2.0/), recoloured by NØNOS.
