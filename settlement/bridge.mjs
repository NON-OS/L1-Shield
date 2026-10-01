// The open lander's ear: listens on the NOX Shield Waku topic and hands every package to a local
// lander (relayer.py, POST /v1/handoff), which runs every check and settles. Anyone may run this pair;
// nothing about it is ours. Proofs pay whoever submits them, so the fastest lander is paid.
//
//   LANDER=http://127.0.0.1:8480 NOX_WAKU_PEERS=/ip4/.../tcp/8000/ws/p2p/... node bridge.mjs
//
// NOX_WAKU_PEERS adds entry points beside Waku's default bootstrap (comma or space separated multiaddrs
// with a /p2p/ id), such as the lander's own nwaku node, so the ear keeps hearing if the fleet goes.
//
// It keeps no record of who sent a package: a Waku message carries no sender, and the wallet publishes
// over Tor. Identical packages are handed off once; the same proof with other limbs is a different package.
import { createHash } from "node:crypto";
if (!Promise.withResolvers) Promise.withResolvers = function () { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const { createLightNode, Protocols } = await import("@waku/sdk");
const { TOPIC, decode } = await import("./package.mjs");
const { extraPeers } = await import("./peers.mjs");

const LANDER = process.env.LANDER || "http://127.0.0.1:8480";
// Ids already handed off, oldest first, capped: an open topic can be flooded with distinct
// packages, and an unbounded set would grow until the machine runs out of memory. An id evicted and
// seen again is handed off again, which the lander answers with the job's state.
const SEEN_MAX = 50_000;
const seen = new Set();
const remember = (id) => {
  seen.add(id);
  if (seen.size > SEEN_MAX) seen.delete(seen.values().next().value);
};
const log = (m) => console.log(new Date().toISOString(), m);

const node = await createLightNode({ defaultBootstrap: true, bootstrapPeers: extraPeers() });
await node.start();
await node.waitForPeers([Protocols.Filter]);
log(`listening on ${TOPIC}, handing off to ${LANDER}`);

await node.filter.subscribe(node.createDecoder({ contentTopic: TOPIC }), async (msg) => {
  let pkg;
  try {
    pkg = decode(msg.payload);
  } catch (e) {
    return log(`ignored: ${e.message}`);
  }
  const id = createHash("sha256").update(msg.payload).digest("hex"); // the whole package, never the proof alone
  if (seen.has(id)) return;
  remember(id);
  // limbs reach 2^64, past a JS number: write them as bare JSON integers by hand
  const b64 = (x) => Buffer.from(x).toString("base64");
  const body = `{"proof":"${b64(pkg.proof)}","publics":[${pkg.limbs.join(",")}],"blob0":"${b64(pkg.note0)}","blob1":"${b64(pkg.note1)}"}`;
  try {
    const r = await fetch(`${LANDER}/v1/handoff`, { method: "POST", headers: { "Content-Type": "application/json" }, body });
    const j = await r.json();
    log(`package ${id.slice(0, 12)}: ${r.status} ${j.status || j.error || ""}`);
  } catch (e) {
    log(`package ${id.slice(0, 12)}: lander unreachable: ${e.message}`);
  }
});
