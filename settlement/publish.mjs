// The wallet side of open settlement, as a command: publish one package to the NOX Shield topic
// through Tor. The wallet does the same in-process; this is the reference and the test tool.
//
//   SOCKS=socks5h://127.0.0.1:9150 node publish.mjs proof.bin publics.json [note0.bin note1.bin]
//
// Without notes it sends two zero notes, for tests only. Refuses to start without a working proxy:
// a publish that leaves the machine directly would tie the proof to this IP address.
import { readFileSync } from "node:fs";
if (!Promise.withResolvers) Promise.withResolvers = function () { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
const { createLightNode, Protocols } = await import("@waku/sdk");
const { webSockets } = await import("@libp2p/websockets");
const { SocksProxyAgent } = await import("socks-proxy-agent");
const { TOPIC, encode } = await import("./package.mjs");

const SOCKS = process.env.SOCKS || "socks5h://127.0.0.1:9150";
const [proofF, publicsF, n0F, n1F] = process.argv.slice(2);
const proof = readFileSync(proofF);
const limbs = JSON.parse(readFileSync(publicsF, "utf8").replace(/(\d{16,})/g, '"$1"')).publics;
const note = (f) => (f ? readFileSync(f) : Buffer.alloc(1186));
const pkg = encode(proof, note(n0F), note(n1F), limbs);

const timeout = (ms, what) => new Promise((_, rej) => setTimeout(() => rej(new Error(`timeout: ${what}`)), ms));
const node = await createLightNode({
  defaultBootstrap: true,
  libp2p: { transports: [webSockets({ websocket: { agent: new SocksProxyAgent(SOCKS) } })] },
});
await node.start();
await Promise.race([node.waitForPeers([Protocols.LightPush]), timeout(90_000, "peers")]);
const res = await Promise.race([node.lightPush.send(node.createEncoder({ contentTopic: TOPIC }), { payload: new Uint8Array(pkg) }), timeout(60_000, "send")]);
const ok = (res.successes || []).length;
console.log(`published ${pkg.length} B to ${ok} peer(s) through Tor`);
await node.stop();
process.exit(ok ? 0 : 1);
