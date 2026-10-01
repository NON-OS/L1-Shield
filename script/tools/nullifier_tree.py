#!/usr/bin/env python3
"""The week's nullifier tree (D9): a depth-16 Poseidon-Goldilocks Merkle tree over every nullifier the
pool recorded in a window, in chain order, built exactly as the pool builds its note tree (docs/09-tree.md):
empty leaves are zero, an empty subtree at level i+1 is hash2(z_i, z_i), a node is hash2(left, right).
Hashes come from the deployed hasher, by eth_call, so the tree is the pool's own construction.

    python3 script/tools/nullifier_tree.py --pool 0x... --from-time 1790812800 --to-time 1791417600

Reads NullifierSpent(bytes32) logs from --rpc (default Tenderly; publicnode has been seen to drop logs
silently), in pages, and refuses a log set with a repeated nullifier. The pool keeps no count of spends,
so run it against two RPCs and compare roots. Writes the root, the leaves and each leaf's path as JSON.

--asset N keeps only nullifiers whose settlement intent spends asset N (the rewards programme's weekly
root uses --asset 1, NOX). Each spend's transaction is decoded as the pool decodes it (ShieldedPool.
_decodeIntent): an intent is wordsPerIntent words, nf0 at word 2, nf1 at word 3, assetId at word 8.
A spend whose transaction is not a direct settleBatch call to the pool is refused, never guessed.
"""
import argparse, json, subprocess, sys

DEPTH = 16
SETTLE = "settleBatch(bytes,uint256[],(address,uint64,uint64,uint256,uint256,address[],uint256),bytes,bytes[])"
SETTLE_SEL = "0x7f478216"
NF0, NF1, ASSET = 2, 3, 8  # word offsets in an intent, as ShieldedPool._decodeIntent reads them
TOPIC = "0x" + subprocess.run(["cast", "keccak", "NullifierSpent(bytes32)"], capture_output=True, text=True).stdout.strip()[2:]


def cast(*a, rpc):
    r = subprocess.run(["cast", *a, "--rpc-url", rpc], capture_output=True, text=True, timeout=120)
    if r.returncode:
        raise RuntimeError(r.stderr.strip()[-300:])
    return r.stdout.strip()


def logs(pool, start, end, rpc, page=5000):
    out, b = [], start
    while b <= end:
        e = min(b + page - 1, end)
        raw = json.loads(cast("logs", "--from-block", str(b), "--to-block", str(e), "--address", pool, TOPIC, "--json", rpc=rpc))
        out += raw
        b = e + 1
    out.sort(key=lambda l: (int(l["blockNumber"], 16), int(l["logIndex"], 16)))
    return out


def assets_of(tx, pool, k, rpc):
    """nullifier -> assetId for every intent the settlement transaction `tx` carries."""
    t = json.loads(cast("tx", tx, "--json", rpc=rpc))
    if (t.get("to") or "").lower() != pool.lower() or not t["input"].startswith(SETTLE_SEL):
        raise RuntimeError(f"{tx} is not a direct settleBatch call to the pool: its spends cannot be attributed")
    r = subprocess.run(["cast", "calldata-decode", "--json", SETTLE, t["input"]], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stderr.strip()[-300:])
    words = [int(w) for w in json.loads(r.stdout)[1]]
    if not words or len(words) % k:
        raise RuntimeError(f"{tx}: {len(words)} public words is not a whole number of {k}-word intents")
    out = {}
    for o in range(0, len(words), k):
        for nf in (words[o + NF0], words[o + NF1]):
            out["0x%064x" % nf] = words[o + ASSET]
    return out


def block_at(ts, rpc):
    """The first block with timestamp >= ts, by binary search."""
    lo, hi = 0, int(cast("block-number", rpc=rpc))
    while lo < hi:
        mid = (lo + hi) // 2
        if int(cast("block", str(mid), "--field", "timestamp", rpc=rpc)) < ts:
            lo = mid + 1
        else:
            hi = mid
    return lo


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pool", required=True)
    ap.add_argument("--from-time", type=int, required=True)
    ap.add_argument("--to-time", type=int, required=True)
    ap.add_argument("--from-block", type=int, default=0, help="the pool's deployment block, to bound the search")
    ap.add_argument("--rpc", default="https://sepolia.gateway.tenderly.co")
    ap.add_argument("--asset", type=int, help="keep only spends of this asset id (1 = NOX)")
    a = ap.parse_args()

    hasher = cast("call", a.pool, "treeHasher()(address)", rpc=a.rpc)
    h2 = lambda l, r: cast("call", hasher, "hash2(bytes32,bytes32)(bytes32)", l, r, rpc=a.rpc)

    start = max(block_at(a.from_time, a.rpc), a.from_block)
    end = block_at(a.to_time, a.rpc) - 1
    evs = logs(a.pool, start, end, a.rpc)
    if a.asset is not None:
        k = int(cast("call", a.pool, "wordsPerIntent()(uint256)", rpc=a.rpc).split()[0])
        cache, kept = {}, []
        for l in evs:
            tx = l["transactionHash"]
            if tx not in cache:
                cache[tx] = assets_of(tx, a.pool, k, a.rpc)
            nf = l["topics"][1].lower()
            if nf not in cache[tx]:
                sys.exit(f"{nf} is spent in {tx} but in none of its intents")
            if cache[tx][nf] == a.asset:
                kept.append(l)
        evs = kept
    leaves = [l["topics"][1] for l in evs]
    if len(leaves) != len(set(leaves)):
        sys.exit("a nullifier appears twice: the logs are wrong")
    if len(leaves) > 1 << DEPTH:
        sys.exit("more spends than the tree holds")

    zeros = ["0x" + "00" * 32]
    for _ in range(DEPTH):
        zeros.append(h2(zeros[-1], zeros[-1]))

    level, paths = list(leaves), [[] for _ in leaves]
    index = list(range(len(leaves)))
    for d in range(DEPTH):
        nxt = []
        for i in range(0, max(len(level), 1), 2):
            left = level[i] if i < len(level) else zeros[d]
            right = level[i + 1] if i + 1 < len(level) else zeros[d]
            nxt.append(h2(left, right) if level else zeros[d + 1])
        for k, pos in enumerate(index):
            sib = pos ^ 1
            paths[k].append(level[sib] if sib < len(level) else zeros[d])
            index[k] = pos // 2
        level = nxt
    root = level[0] if leaves else zeros[DEPTH]

    json.dump({"pool": a.pool, "asset": a.asset, "hasher": hasher, "from_time": a.from_time, "to_time": a.to_time,
               "from_block": start, "to_block": end, "depth": DEPTH, "root": root, "count": len(leaves),
               "leaves": [{"index": i, "nullifier": n, "block": int(evs[i]["blockNumber"], 16),
                           "tx": evs[i]["transactionHash"], "path": paths[i]} for i, n in enumerate(leaves)]},
              sys.stdout, indent=1)


if __name__ == "__main__":
    main()
