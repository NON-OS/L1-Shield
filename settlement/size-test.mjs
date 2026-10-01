import { readFileSync } from "node:fs";
// Open settlement, test 1: does a full proof package travel over the public Waku network?
// Two independent light nodes: one subscribes with Filter, the other publishes with LightPush.
// Payloads grow from 10 KB to past a real proof package (format 7 proof + two sealed notes + limbs),
// so the result is both the size limit and the delivery of a real package.
// Node 20 lacks Promise.withResolvers, which libp2p uses
if (!Promise.withResolvers) Promise.withResolvers = function () { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const { createLightNode, createEncoder, createDecoder, Protocols } = await import("@waku/sdk");

const TOPIC = "/nox-shield/1/proof/proto";
const PKG = process.argv[2]; // a format 7 proof file, to build one real package
const timeout = (ms, what) => new Promise((_, rej) => setTimeout(() => rej(new Error(`timeout: ${what}`)), ms));

function realPackage() {
  const proof = readFileSync(PKG);
  const notes = Buffer.alloc(2 * 1186, 7);
  const limbs = Buffer.from(JSON.stringify(Array.from({ length: 37 }, (_, i) => String(i))));
  const head = Buffer.alloc(12);
  head.writeUInt32BE(proof.length, 0);
  head.writeUInt32BE(notes.length, 4);
  head.writeUInt32BE(limbs.length, 8);
  return Buffer.concat([head, proof, notes, limbs]);
}

async function node(name) {
  const n = await createLightNode({ defaultBootstrap: true });
  await n.start();
  await Promise.race([n.waitForPeers([Protocols.LightPush, Protocols.Filter]), timeout(90_000, `${name} peers`)]);
  return n;
}

const t0 = Date.now();
const [sub, pub] = await Promise.all([node("subscriber"), node("publisher")]);
console.log(`peers found in ${((Date.now() - t0) / 1000).toFixed(1)} s`);

const routing = { clusterId: 1, shardId: 0 };
const encoder = pub.createEncoder ? pub.createEncoder({ contentTopic: TOPIC }) : createEncoder({ contentTopic: TOPIC });
const decoder = sub.createDecoder ? sub.createDecoder({ contentTopic: TOPIC }) : createDecoder(TOPIC);

const seen = new Map();
await sub.filter.subscribe(decoder, (msg) => {
  const p = msg.payload;
  const id = p.length >= 4 ? p.readUInt32BE?.(0) : 0;
  seen.set(p.length, Date.now());
});

const sizes = [10_000, 50_000, 100_000, 120_000, 140_000, 150_000, 160_000, 200_000];
const payloads = sizes.map((s) => ({ label: `${s} B`, bytes: Buffer.alloc(s, s % 251) }));
if (PKG) {
  const p = realPackage();
  payloads.splice(3, 0, { label: `real package ${p.length} B`, bytes: p });
}

for (const { label, bytes } of payloads) {
  const sent = Date.now();
  let res;
  try {
    res = await Promise.race([pub.lightPush.send(encoder, { payload: new Uint8Array(bytes) }), timeout(60_000, "send")]);
  } catch (e) {
    console.log(`${label}: send failed: ${e.message}`);
    continue;
  }
  const ok = (res.successes || []).length;
  const fails = (res.failures || []).map((f) => f.error || f).join(",");
  let got = false;
  for (let i = 0; i < 60 && !got; i++) {
    await new Promise((r) => setTimeout(r, 500));
    got = seen.has(bytes.length);
  }
  const ms = got ? seen.get(bytes.length) - sent : null;
  console.log(`${label}: pushed to ${ok} peer(s)${fails ? `, failures ${fails}` : ""}; delivered ${got ? `in ${(ms / 1000).toFixed(1)} s` : "NO (30 s)"}`);
}

await sub.stop();
await pub.stop();
process.exit(0);
