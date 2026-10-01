import { readFileSync } from "node:fs";
// Open settlement, test 2: the wallet side publishes over Tor. Its libp2p WebSockets go through a local
// Tor SOCKS port, so no Waku node sees its address. The lander side listens on clearnet.
if (!Promise.withResolvers) Promise.withResolvers = function () { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const { createLightNode, Protocols } = await import("@waku/sdk");
const { webSockets } = await import("@libp2p/websockets");
const { SocksProxyAgent } = await import("socks-proxy-agent");

const TOPIC = "/nox-shield/1/proof/proto";
const SOCKS = process.env.SOCKS || "socks5h://127.0.0.1:9150";
const timeout = (ms, what) => new Promise((_, rej) => setTimeout(() => rej(new Error(`timeout: ${what}`)), ms));

const proof = readFileSync(process.argv[2]);
const pkg = Buffer.concat([proof, Buffer.alloc(2 * 1186, 7), Buffer.from("[" + Array.from({ length: 37 }, (_, i) => i).join(",") + "]")]);

const agent = new SocksProxyAgent(SOCKS);
const t0 = Date.now();
const pub = await createLightNode({ defaultBootstrap: true, libp2p: { transports: [webSockets({ websocket: { agent } })] } });
const sub = await createLightNode({ defaultBootstrap: true });
await Promise.all([pub.start(), sub.start()]);
await Promise.race([Promise.all([pub.waitForPeers([Protocols.LightPush]), sub.waitForPeers([Protocols.Filter])]), timeout(180_000, "peers")]);
console.log(`peers over Tor in ${((Date.now() - t0) / 1000).toFixed(1)} s`);

let gotAt = 0;
await sub.filter.subscribe(sub.createDecoder({ contentTopic: TOPIC }), (m) => { if (m.payload.length === pkg.length) gotAt = Date.now(); });

for (let round = 1; round <= 3; round++) {
  gotAt = 0;
  const sent = Date.now();
  const res = await Promise.race([pub.lightPush.send(pub.createEncoder({ contentTopic: TOPIC }), { payload: new Uint8Array(pkg) }), timeout(120_000, "send")]);
  for (let i = 0; i < 120 && !gotAt; i++) await new Promise((r) => setTimeout(r, 500));
  console.log(`round ${round}: ${pkg.length} B pushed over Tor to ${(res.successes || []).length} peer(s); delivered ${gotAt ? `in ${((gotAt - sent) / 1000).toFixed(1)} s` : "NO (60 s)"}`);
}
await pub.stop(); await sub.stop(); process.exit(0);
