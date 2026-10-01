// Publishing a package to the open topic, through Tor only. A publish that left the machine directly
// would tie the proof to its IP address, so this refuses to send without peers through the proxy.
import { TOPIC } from "./constants.mjs";
import { extraPeers } from "./peers.mjs";

if (!Promise.withResolvers) Promise.withResolvers = function () { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };

const timeout = (ms, what) => new Promise((_, rej) => setTimeout(() => rej(new Error(`timeout: ${what}`)), ms));

/** peers: extra entry multiaddrs, beside the default bootstrap (default: env NOX_WAKU_PEERS). */
export async function publish(pkg, { socks = "socks5h://127.0.0.1:9150", peersMs = 90_000, peers } = {}) {
  const { createLightNode, Protocols } = await import("@waku/sdk");
  const { webSockets } = await import("@libp2p/websockets");
  const { SocksProxyAgent } = await import("socks-proxy-agent");
  const node = await createLightNode({
    defaultBootstrap: true,
    bootstrapPeers: extraPeers(peers),
    libp2p: { transports: [webSockets({ websocket: { agent: new SocksProxyAgent(socks) } })] },
  });
  try {
    await node.start();
    await Promise.race([node.waitForPeers([Protocols.LightPush]), timeout(peersMs, "no peers through the proxy")]);
    const res = await Promise.race([
      node.lightPush.send(node.createEncoder({ contentTopic: TOPIC }), { payload: new Uint8Array(pkg) }),
      timeout(60_000, "send"),
    ]);
    const accepted = (res.successes || []).length;
    if (!accepted) throw new Error("no peer accepted the package");
    return { peers: accepted, bytes: pkg.length };
  } finally {
    await node.stop();
  }
}
