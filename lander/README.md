# Lander

`relayer.py` takes finished proofs for a format 7 pool, checks each one against the pool's own rules,
and lands it from its own key. Every proof pays whoever lands it a gas rung, so a lander pays for its
own gas. It also commits the pool's root on a fixed clock.

| File | Role |
|---|---|
| `relayer.py` | the HTTP API (`/v1/info`, `/v1/status`, `POST /v1/handoff`, `GET /v1/handoff/<id>`), the checks, the settlement queue and the root clock |
| `script/SettleHandoff.s.sol` | the settlement: cuts the package into the single-call layout, checks it with the pool's verifier, and sends `settleBatch` |
| `script/SplitFormat7.sol`, `script/IShieldedPoolLite.sol` | the cut, and the part of the pool's interface the script calls |
| `test_relayer.py` | offline tests against the pinned proofs in `../spec/shapes` and `../spec/not-before` |
| `foundry.toml` | a small forge project, so the settlement builds in seconds with no verifier code |

Configuration is by environment variable, listed at the top of `relayer.py`. The one-command install,
with a listener on the public proof topic and a Waku node, is `../settlement/lander/install.sh`; see
[running a lander](../docs/tutorials/02-run-a-lander.md).

```sh
python3 test_relayer.py
```
