# The production pool

The pool the apps use, `ShieldedPool` `0xaEe51E82965Ec1DeD870F3f4c248Ad4AdDc3e1cb` on Sepolia, deployed on
30 September 2026 by `script/shield/DeployNotBefore.s.sol`. It is the 12-word pool described in chapters
01 to 21 with three changes: a 13th public word, a fee schedule in place of one flat fee, and proofs
that pay whoever lands them. Every address is in [deployments](deployments.md).

## Contents

- [The 13th word: not before](#the-13th-word-not-before)
- [Fees](#fees)
- [Open settlement](#open-settlement)
- [Roots](#roots)
- [The pause](#the-pause)
- [Tests](#tests)

## The 13th word: not before

A statement is 13 words, 37 limbs. Words 0 to 11 are the 12-word pool's
([16](16-wallet-integration.md#the-statement-12-words-36-limbs)); word 12 is a time, one limb, the
earliest moment the proof may settle. `_decodeIntent` refuses a time that is zero or not a multiple of
`NOT_BEFORE_GRID` (600 seconds) with `NotBeforeOffGrid(nb)`, and a time still in the future with
`NotYet(nb)`.

The grid is what makes the word safe to publish: every proof made in the same ten minutes carries the
same value, so the time says which ten minutes, not which wallet. A wallet uses the grid point just
passed, `floor(now / 600) * 600`, so its proof can land at once.

The verifier for 13-word statements is the not-before stack in `contracts/shield/verifier/nb`: an
evaluator bound to image `0x4364151e…2429`, one prepare and one walk per shape, and the shape adapter
`ComposedStarkVerifierShapes`. Its pinned proofs are in `spec/not-before`.

## Fees

`AmountPolicy` `0x660f66ab31Ca9919D9e1770FEDc88Ff2dd29CE59` holds, per asset, a schedule: a protocol
part for a private transfer and a ladder of four gas rungs. Deposits and withdrawals take a percentage.

| | ETH | NOX |
|---|---|---|
| Deposit | 0.50% (`depositFee`) | 0.50% |
| Withdrawal, protocol part | 0.50% of the amount | 0.50% |
| Private transfer, protocol part | 0.0005 ETH | 400 NOX |
| Gas rungs | 0.0025, 0.005, 0.01, 0.02 ETH | 2,000, 4,000, 8,000, 16,000 NOX |

The pool calls `settlementFee(asset, publicAmount, fee, relayed)` for every intent. When the proof names
a fee recipient, the fee must be the protocol part plus exactly one rung; when it names none, the fee
must be the protocol part alone. Any other fee is refused with `FeeBelowProtocolPart` or
`FeeNotOnLadder`, before any value moves. Wallets call the same function before proving.

The protocol part goes to `ShieldFeeRouter` `0x0Be77d3c…3f6D`. A schedule or percentage change is queued
by the owner and takes effect only after `CHANGE_DELAY`, 48 hours; for one hour after (`GRACE`) the old
values still settle, so a proof made just before a change is not stranded. A percentage cannot exceed
`MAX_BPS`, 1%.

## Open settlement

A proof whose fee recipient is `SUBMITTER`, `address(1)`, credits its gas rung to `msg.sender` of the
settlement. Whoever lands the proof is paid, so nobody has to be trusted or registered to carry a
proof to the chain, and no lander can redirect the payment or the rung: both are fixed by the proof.

A wallet hands its proof to a lander over a Tor onion service, or publishes it through Tor to the Waku
topic `/nox-shield/1/proof/proto`, where any lander can hear it ([settlement/](../settlement/README.md)).
`lander/relayer.py` checks each proof against the pool's own rules before it spends gas, waits for the
not-before time, settles through a private RPC so the transaction cannot be copied from the public
mempool, and collects its credits with `claim`. Five landers serve the pool today; anyone can run
another ([running a lander](tutorials/02-run-a-lander.md)).

A proof its owner submits pays the protocol part only. That always works and needs no lander, but it
links the owner's public account to the settlement.

## Roots

New notes become spendable when a root that contains them is committed. `RootBounty` `0x0DBd…4cAd`
commits the pool's root for anyone and pays the caller from its balance, at most once per 10-minute
interval. Landers commit on a 300-second clock, only when deposits have arrived; a standby lander waits
a fixed number of seconds into each slot and commits only if nobody has, so several landers never race.
A deposit is spendable within about five minutes.

## The pause

The guardian or the owner can stop every deposit and settlement for 7 days, and the stop ends by itself.
The owner can extend it once, by 7 more days, through a 48-hour delay, and a new pause must wait 7 days
after the last one ends. The longest any holder can be kept from withdrawing is 14 days.
Nothing in the pause can move a note or change who is paid. See
[the containment lever](08-pool.md#the-containment-lever).

## Tests

| Test | What it establishes |
|---|---|
| `NotBeforeVerifier.t.sol` | the five pinned proofs verify through the adapter; each is refused when word 12 moves one grid step either way, is zero, or the statement is cut to 12 words |
| `NotBeforePool.t.sol` | the pool refuses a time off the grid, a zero time and a future time, splits a fee between the router and the lander, and refuses a fee off the ladder |
| `SubmitterFee.t.sol` | a proof naming `address(1)` credits its gas part to whoever settles it |
| `AmountPolicySchedule.t.sol` | the schedule, the ladder, the percentages, the 48-hour delay and the grace hour |
| `PauseLever.t.sol` | the pause, its end, its one extension and its cooldown |
| `lander/test_relayer.py` | the lander refuses every proof the pool would refuse, before it spends gas |
