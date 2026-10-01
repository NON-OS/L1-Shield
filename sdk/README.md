# @nonos/shield

Everything a wallet, exchange or app needs around a NOX Shield proof, except making it. Proving and
note sealing (X25519 + ML-KEM-768) are in the wallet's Rust core.

```js
import { schedule, bps, quote, checkFee, notBefore, feeRecipientLimbs, encodePackage, publish, landed, ASSET } from "@nonos/shield";

const sched = await schedule(ASSET.ETH);                        // protocol fee + 4-rung gas ladder
const { withdraw } = await bps();                                // 50 = 0.50%
const { fee } = quote({ sched, withdrawBps: withdraw, rung: 0 }); // exact; the pool refuses any other fee
await checkFee({ asset: ASSET.ETH, fee, relayed: true });         // the policy itself agrees, before proving

// statement: fee recipient feeRecipientLimbs() = address(1), limb 36 = notBefore(), limb 25 = fee
// ... the Rust core proves ...

await publish(encodePackage(proof, note0, note1, limbs));         // Tor only; refuses without the proxy
const { settled } = await landed(nf0, nf1);                       // both nullifiers spent, two RPCs agree
```

| Module | What |
|---|---|
| `fees` | `schedule`, `bps`, `quote`, `checkFee`, `depositFee` from the amount policy |
| `statement` | `notBefore` (the 600 s grid point just passed), `isStandardAmount`, `feeRecipientLimbs` |
| `package` | the `NOXH` v1 Waku message: format 7 proof, two sealed notes, 37 limbs, at most 150 KB |
| `publish` | LightPush to `/nox-shield/1/proof/proto` through a SOCKS proxy (Tor); `peers` (or `NOX_WAKU_PEERS`) adds entry nodes beside the default bootstrap |
| `peers` | `extraPeers`: validates extra entry multiaddrs, drops bad ones with a warning |
| `status` | `landed`: both nullifiers spent, read from two RPCs that must agree |

Read-only: the SDK never signs and never holds a key. `npm test` runs offline; `npm run test:live`
also checks the production deployment on Sepolia (13 of 13 on 2026-10-01).

Not yet: a browser build of `publish` (it needs a Tor transport in the page), and the proving bindings.
