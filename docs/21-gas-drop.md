# Gas drop

This document describes a withdrawal that carries its own gas: a small fixed amount of ETH sent to
the recipient of a token withdrawal, so a fresh address can move what it received. It is a design.
Nothing here is implemented, in the 12-word pool or the launch pool, because every sound version needs a new
public word.

## The problem

A token withdrawal to a fresh address leaves that address with tokens and no ETH. It cannot pay gas
to move them without funding from a linked address, which undoes the privacy the pool gave.

## Why the pool cannot do it alone

- The ETH must come from somewhere. A token withdrawal carries no ETH, and the pool has no price
  at which to turn a slice of the withdrawn tokens into ETH.
- The relayer can send ETH with the settlement and take tokens in the fee. Without a proven word
  the user cannot require it. A relayer could keep the fee and skip the drop, and the pool would
  not know.
- A native withdrawal needs no drop: the recipient already receives ETH.

## Design

One new public word per intent, `gasDrop`, in wei, bound by the proof like the fee.

| Rule | Where |
|---|---|
| `gasDrop` is 0 unless `publicAmount > 0` and the asset is not native | circuit and pool |
| `gasDrop <= maxGasDrop`, an owner-set cap under a constant ceiling | pool |
| The submitter sends the sum of the batch's `gasDrop` as `msg.value` to `settleBatch` | pool |
| The pool pushes each `gasDrop` to its recipient, or credits it on refusal | pool |
| The submitter is repaid in the intent's fee, which the user sizes to cover the drop | wallet |

The drop is the submitter's ETH, and the fee repays it in the withdrawn token. The pool holds none
of it, so solvency is unchanged. A settlement whose `msg.value` differs from the sum is refused.

## Cost of the change

- The intent grows from 12 to 13 words. The circuit, the program image, the verifier's public-word
  layout and `PublicWords` all change, and a new pool is deployed.
- A batch without drops pays one more calldata word per intent and one comparison.

## Open questions

- The ceiling for `maxGasDrop`. Enough for one ERC-20 transfer at a high base fee is about 0.002 ETH.
- Whether a pool-held ETH reserve should fund drops when no relayer is used. That adds a liability
  and a drain to bound, as the root bounty does.
