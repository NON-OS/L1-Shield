// Read-only JSON-RPC: eth_call with hand-encoded arguments. No signing, no keys.
import { RPCS } from "./constants.mjs";

const SEL = {
  scheduleOf: "0x01e7d8d8", // scheduleOf(uint64)
  bps: "0x68237329", // bps()
  settlementFee: "0x73d8e932", // settlementFee(uint64,uint256,uint256,bool)
  depositFee: "0xabc15819", // depositFee(uint64,uint256)
  nullifierSpent: "0x38c86911", // nullifierSpent(bytes32)
  currentRoot: "0xfdab463d", // currentRoot()
  isKnownRoot: "0x6d9833e3", // isKnownRoot(bytes32)
};

const word = (v) => BigInt(v).toString(16).padStart(64, "0");
const b32 = (h) => h.replace(/^0x/, "").padStart(64, "0");

export function encode(fn, ...args) {
  return SEL[fn] + args.map((a) => (typeof a === "string" ? b32(a) : word(typeof a === "boolean" ? (a ? 1 : 0) : a))).join("");
}

export function words(hex) {
  const h = hex.replace(/^0x/, "");
  const out = [];
  for (let i = 0; i + 64 <= h.length; i += 64) out.push(BigInt("0x" + h.slice(i, i + 64)));
  return out;
}

export async function call(to, data, { rpc = RPCS[0], fetchFn = fetch } = {}) {
  const r = await fetchFn(rpc, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to, data }, "latest"] }),
  });
  const j = await r.json();
  if (j.error) {
    const e = new Error(j.error.message || "eth_call failed");
    e.data = j.error.data;
    throw e;
  }
  return j.result;
}
