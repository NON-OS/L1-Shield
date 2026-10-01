#!/usr/bin/env python3
"""Standard (pre-EIP-7623) gasUsed of a mined transaction, from its struct-log trace.

    standard.py RPC TXHASH

std = 21000 + 4 zero + 16 nonzero calldata bytes + execution - min(refund, used / 5). Execution is
the gas at the first step minus the gas left after the last one.
"""
import json
import sys
import urllib.request


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(url, body, {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=3600))["result"]


url, h = sys.argv[1], sys.argv[2]
tx = rpc(url, "eth_getTransactionByHash", [h])
rc = rpc(url, "eth_getTransactionReceipt", [h])
data = bytes.fromhex(tx["input"][2:])
z = data.count(0)
nz = len(data) - z
intrinsic = 21000 + 4 * z + 16 * nz
floor = 21000 + 10 * (z + 4 * nz)
opts = {"disableStack": True, "disableMemory": True, "disableStorage": True, "enableReturnData": False}
t = rpc(url, "debug_traceTransaction", [h, opts])
logs = t["structLogs"]
first, last = logs[0], logs[-1]
execution = first["gas"] - (last["gas"] - last["gasCost"])
refund = max(l.get("refund", 0) for l in logs[-50:])
used = intrinsic + execution
std = used - min(refund, used // 5)
print(json.dumps({
    "tx": h, "receipt_gasUsed": int(rc["gasUsed"], 16), "calldata_bytes": len(data),
    "intrinsic_standard": intrinsic, "execution": execution, "refund": refund,
    "standard": std, "floor": floor, "steps": len(logs), "applied": max(std, floor),
}))
