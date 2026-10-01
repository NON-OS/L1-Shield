# Running a lander

A lander takes finished proofs, checks them, and puts them on chain. Every proof pays whoever lands it a
gas rung (0.0025 ETH or 2,000 NOX at the lowest), so landing pays for itself, and the more landers run,
the less anyone depends on one.

A lander never sees who sent a proof, cannot change where the money goes (the proof fixes it), and
cannot take more than the rung the proof names.

## One command

On a fresh Linux x86-64 machine with systemd:

```sh
git clone https://github.com/NON-OS/L1-Shield && cd L1-Shield/settlement/lander
sudo ./install.sh 0xaEe51E82965Ec1DeD870F3f4c248Ad4AdDc3e1cb 60
```

The second argument is the root standby in seconds. The pool's root is committed on a 300-second slot;
a standby lander commits only if nobody has by that point in the slot. Use 0 for a first lander, and a
different value below 300 for each additional one.

The installer:
- downloads Node and Foundry, each checked against a pinned SHA-256;
- creates a lander key on the machine (a generated password, never typed, never printed);
- runs three services as three separate users: the lander, which holds the key; the listener, which
  hears proofs on the public topic and cannot read the key; and a Waku node, which gives wallets another
  way into the network;
- sends settlements through a private RPC, so nobody can copy a settlement from the public mempool and
  take its rung;
- prints the lander's address.

Send that address about 0.1 Sepolia ETH for gas. Each settlement costs about 4 million gas and pays the
rung back.

## Checking it

```sh
curl -s http://127.0.0.1:8480/v1/status
journalctl -fu nox-lander -u nox-lander-ear
```

`/v1/status` shows the pool, the gas balance, the queue, the last settlement, the root clock, the
standby and whether settlements go out privately.

## Opening it to wallets over Tor

Add an onion service pointing port 80 at `127.0.0.1:8480`. Wallets try their list of landers in order
and move to the next when one does not answer.
