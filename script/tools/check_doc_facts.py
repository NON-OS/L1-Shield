#!/usr/bin/env python3
"""Checks the README and docs against the deployment records. Run from the repository root.

1. Every 20-byte address in README.md and docs/*.md appears in deployments/sepolia.env or
   deployments/sepolia-launch.env.
2. Every gas figure (a number of seven or more digits, with commas, on a line that says "gas")
   appears in a receipt file under deployments/, or in docs/19-deployments-and-receipts.md, which
   carries the launch receipts, or is derived below from such figures, or is a measurement named
   below with its source.
Exits 1 and prints each miss.
"""
import glob, re, sys

LAUNCH_SETTLEMENTS_MAX = 7_882_382
LAUNCH_DEPLOY = [1_921_383, 220_074, 1_162_012, 1_848_604]  # docs/19, the stack before DeployLaunch
DERIVED = {
    "10,247,097": round(LAUNCH_SETTLEMENTS_MAX * 1.3),            # a 130% pad on the highest settlement
    "8,894,834": 16_777_216 - LAUNCH_SETTLEMENTS_MAX,               # headroom under the EIP-7825 cap
    "30,005,421": 4_523_512 + 5_687_769 + 1_380_943 + 6_748_211 + 11_664_986,  # DeployLaunch, docs/19
}
MEASURED = {
    "16,777,216": "EIP-7825 gas cap of one transaction",
    "90,000,000,000": "gas_limit in foundry.toml, for tests",
    "4,980,509": "eth_estimateGas of verifyBatch on settlement 0x1efa772d…8fa8, less base and calldata",
    "6,797,269": "eth_estimateGas of verifyBatch on settlement 0x1efa772d…8fa8",
    "1,795,760": "4 x calldata tokens of that verifyBatch call",
    "1,836,152": "4 x calldata tokens of settlement 0x1efa772d…8fa8",
    "77,032,392": "baseFeePerGas of mainnet block 26,036,876, in wei",
    "3,911,723": "verify_shapes.sh rehearsal with HASHER_STANDARD=true, shape A",
    "26,036,876": "the mainnet block the dollar figures are read at",
}

docs = ["README.md"] + sorted(glob.glob("docs/*.md"))
env = "".join(open(f).read() for f in glob.glob("deployments/*.env")).lower()
records = "".join(open(f).read() for f in glob.glob("deployments/*.json*"))
record_numbers = set(re.findall(r"\d+", records))
receipts_doc = open("docs/19-deployments-and-receipts.md").read()

for n, v in DERIVED.items():
    assert int(n.replace(",", "")) == v, f"derived {n} is {v:,}"

miss = 0
for d in docs:
    text = open(d).read()
    for a in sorted(set(re.findall(r"0x[0-9a-fA-F]{40}(?![0-9a-fA-F])", text))):
        if a.lower() not in env:
            print(f"{d}: address {a} is in no deployments/*.env"); miss += 1
    if d.endswith("19-deployments-and-receipts.md"):
        continue
    for line in text.splitlines():
        if "gas" not in line.lower():
            continue
        for n in re.findall(r"(?<![\d.,])\d{1,3}(?:,\d{3}){2,}(?![\d,])", line):
            if n.replace(",", "") in record_numbers or n in receipts_doc or n in DERIVED or n in MEASURED:
                continue
            print(f"{d}: gas figure {n} has no receipt or source"); miss += 1
print(f"{len(docs)} files checked, {miss} misses")
sys.exit(1 if miss else 0)
