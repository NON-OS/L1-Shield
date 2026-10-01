# Open settlement

A wallet's proof pays whoever lands it (fee recipient `address(1)`). The wallet publishes the package
through Tor to a public Waku topic; any lander picks it up, checks it, simulates it and lands it. No
server of ours is in the path, and no lander learns who sent a package.

| File | Role |
|---|---|
| `package.mjs` | the package format (`NOXH` v1), encode and decode |
| `publish.mjs` | the wallet side, as a command: publish one package through Tor |
| `bridge.mjs` | the lander's ear: subscribe to the topic, hand each package to `../lander/relayer.py` |
| `peers.mjs` | extra Waku entry points from `NOX_WAKU_PEERS`, beside the default bootstrap |
| `lander/install.sh` | one command: lander, ear and a Waku entry node, each under its own user |
| `size-test.mjs`, `tor-test.mjs` | the network tests |

Run a lander by hand (any machine, any key with gas money; `lander/install.sh` does all of this as
services, see [running a lander](../docs/tutorials/02-run-a-lander.md)):

```sh
npm ci
RELAY_POOL=0xaEe51E82965Ec1DeD870F3f4c248Ad4AdDc3e1cb RELAY_SEND_RPC=https://rpc-sepolia.flashbots.net \
  python3 ../lander/relayer.py &
node bridge.mjs
```

Results, 2026-10-01, public Waku network, `@waku/sdk` 0.0.36:

| Test | Result |
|---|---|
| largest message accepted | 150 KB delivered, 160 KB refused |
| real package, direct | 97,320 B in 1.4 s |
| real package, through Tor | 3 of 3, 1.6 to 2.3 s |
| Tor proxy dead (negative control) | no peers, nothing sent |
| Tor → Waku → bridge → `relayer.py` check | accepted and scheduled |
| same proof, one limb changed, sent first | own id, does not shadow the real package |
| fee off the gas ladder | refused, 400 |

## Our own Waku entry nodes

The default bootstrap reaches The Waku Network through Waku's own fleet. So that the proof topic does
not depend on it, every lander installed with `lander/install.sh` also runs an nwaku node:

| | |
|---|---|
| image | `wakuorg/nwaku@sha256:8ff9f04b…e238` (v0.38.1), pulled by digest |
| network | `--preset=twn`, cluster 1, shard 6: where `/nox-shield/1/proof/proto` autoshards with 8 shards |
| protocols | relay and filter on, store off; lightpush only with an RLN membership (below) |
| isolation | user `nox-waku`, read-only root, no capabilities, only `/var/lib/nox-waku` mounted; the lander key is not reachable |
| ports | 60000/tcp, 8000/tcp (websocket), 9000/udp (discv5); REST on 127.0.0.1:8645 only |

The installer prints the node's address (`/ip4/<ip>/tcp/8000/ws/p2p/<id>`) and gives it to the local ear.
Wallets and other ears add entry points with `NOX_WAKU_PEERS` (bridge) or `publish(pkg, { peers })` (SDK),
comma or space separated. A malformed or unreachable entry is dropped with a warning; the default
bootstrap is always kept.

**Lightpush needs an RLN membership.** The Waku Network rate-limits publishers with RLN, registered on
Linea Sepolia. Without a membership the node relays and serves filter, which is what ears need, and
wallets keep publishing through the fleet. To serve wallets too, register a membership once and pass
`NWAKU_RLN_KEYSTORE=<file> NWAKU_RLN_PASSWORD_FILE=<file>` to the installer.

Docker writes its own firewall rules: the three published ports are open even under ufw.

Tested 1 October 2026: publish through Tor with a dead and a malformed extra peer still delivered
(97,763 B, 1 peer); the ear starts with the same pair. The installer passes `bash -n` and shellcheck and
has been run on four Linux hosts; one was rebooted and came back with every service.
