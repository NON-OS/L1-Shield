# Private payments from your own code

The SDK in `sdk/` does everything around a proof except make it: it reads the fee schedule, fills the
fields a statement needs, packs a finished proof into one message, publishes it through Tor, and tells
you when it has landed. It never signs and never holds a key. Proving and note encryption live in the
wallet's core library.

You need Node 20 or later and a Tor client listening on a SOCKS port (Tor Browser uses 9150, the `tor`
daemon 9050).

```sh
cd sdk
npm install
npm test                 # offline checks
NOX_LIVE=1 npm test      # also reads the production pool on Sepolia
```

The package is not on the npm registry. To use it from your own project, install it from the
repository by path; it keeps its package name, `@nonos/shield`:

```sh
npm install /path/to/L1-Shield/sdk
```

## 1. Read the fees

```js
import { schedule, bps, ASSET } from "@nonos/shield";

const eth = await schedule(ASSET.ETH);
// { protocolFee: 500000000000000n, ladder: [2.5e15, 5e15, 1e16, 2e16] as bigints, set: true }
const { deposit, withdraw } = await bps();   // 50n and 50n, that is 0.50% each way
```

## 2. Work out the exact fee

The pool accepts one fee per proof and refuses every other. A proof someone else lands pays the
protocol part plus one gas rung; a proof you land yourself pays the protocol part alone.

```js
import { quote, checkFee } from "@nonos/shield";

const q = quote({ sched: eth, withdrawBps: withdraw, rung: 0 });
// a private transfer: 0.0005 ETH protocol + 0.0025 ETH rung = 0.003 ETH

await checkFee({ asset: ASSET.ETH, fee: q.fee, relayed: true });
// the policy contract itself agrees, or this throws before you spend time proving
```

For a withdrawal pass `publicAmount`: the protocol part becomes 0.50% of it.

## 3. Fill the statement

```js
import { notBefore, feeRecipientLimbs, isStandardAmount } from "@nonos/shield";

isStandardAmount(10n ** 16n);   // true: amounts are 1, 2 or 5 times a power of ten
feeRecipientLimbs();            // [1n, 0n, 0n, 0n]: the fee goes to whoever lands the proof
notBefore();                    // the last 600-second mark, so the proof can land at once
```

Give these, with the fee from step 2, to the prover.

## 4. Publish the proof

```js
import { encodePackage, publish } from "@nonos/shield";

const pkg = encodePackage(proof, sealedNote0, sealedNote1, limbs);   // at most 150 KB
await publish(pkg, { socks: "socks5h://127.0.0.1:9150" });
```

`publish` refuses to send unless it reached peers through the proxy, so a proof never leaves your
machine on your own IP address. Every lander listening on the topic hears it; the first to land it is
paid the rung.

## 5. Wait for it to land

```js
import { landed } from "@nonos/shield";

const { settled } = await landed(nf0, nf1);   // both nullifiers spent, two RPCs agree
```

Resend the same bytes every minute until `settled` is true. Landers ignore a package they have already
seen, and the pool spends a note only once.
