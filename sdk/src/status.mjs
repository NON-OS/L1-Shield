// Has a proof landed? Both nullifiers spent means settled. Read from two RPCs; they must agree.
import { POOL, RPCS } from "./constants.mjs";
import { call, encode } from "./rpc.mjs";

async function spentOn(rpc, nfs, fetchFn) {
  const r = [];
  for (const nf of nfs) r.push(BigInt(await call(POOL, encode("nullifierSpent", nf), { rpc, fetchFn })) === 1n);
  return r;
}

export async function landed(nf0, nf1, { rpcs = RPCS, fetchFn } = {}) {
  const answers = await Promise.all(rpcs.map((rpc) => spentOn(rpc, [nf0, nf1], fetchFn).catch(() => null)));
  const ok = answers.filter(Boolean);
  if (!ok.length) throw new Error("no RPC answered");
  const done = ok.map((a) => a[0] && a[1]);
  if (done.some((d) => d !== done[0])) return { settled: false, disagree: true };
  return { settled: done[0], disagree: false, partly: ok[0][0] !== ok[0][1] };
}
