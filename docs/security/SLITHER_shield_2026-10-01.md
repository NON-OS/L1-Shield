# Slither: the production pool's contracts, 1 October 2026

Slither 0.11.6 with the repository's `slither.config.json`, on `ShieldedPool`, `AmountPolicy`,
`ShieldFeeRouter`, `RootBounty`, `AssociationSetRegistry`, `LinkRegistry` and `PublicWords` at
`2f6ce22`. 42 results. None is a defect; each is triaged below.

| Impact | Check | n | Finding | Verdict |
|---|---|---|---|---|
| High | reentrancy-eth | 1 | `settleBatch` writes `totalShielded` and `unsweptFees` after the residual swap and the native pushes | False positive. `settleBatch` is `nonReentrant`, and every function that writes either variable (`absorb`, `settleBatch`, `claim`, `betaRefund`, `sweepFees`) is `nonReentrant` too, so no reentry can reach a writer. Pushes carry 50,000 gas; routers are Safe-approved behind a timelock. |
| Medium | reentrancy-no-eth | 1 | `_settleResidual` writes after `routeResidual()` | The same guard; the route is a Safe-approved contract. |
| Medium | divide-before-multiply | 2 | `n = length / k`, then `n * width` | Exact: both functions first refuse a length that is not a multiple of `k`. |
| Medium | uninitialized-local | 2 | `clearingPrice`, `k` | Intended zero starts. |
| Medium | unused-return | 6 | `settlementFee`'s gas part, `soundnessBits`' first value, `tryRecover`'s third, the two DEX swaps' amounts | Intended: the pool needs only the protocol part; the floor reads only the provable figure; `tryRecover`'s error is checked; the swaps revert below `minNoxOut` and the router measures its balance. |
| Medium | incorrect-equality | 14 | `eta == 0` and exact-amount checks | Intended: "nothing queued" tests and exact fee matches, not balance comparisons. |
| Low | calls-loop, missing-zero-check, return-bomb | 11 | pushes in the settlement loop; constructor addresses; return data | Pushes are gas-capped and a failed push is credited, so one recipient cannot block a batch. Constructor addresses are checked by the deployment script and read back on chain after deployment. |
| Info | assembly, cyclomatic-complexity, missing-inheritance | 5 | | Noted. |

The generated verifier code (walks, prepares, evaluators) is outside this run; it is covered by the
pinned-proof and tamper tests.
