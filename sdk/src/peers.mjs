// Extra Waku entry points, beside the default bootstrap: our landers' own nwaku nodes and any the
// community runs. If Waku's fleet disappears, these keep the topic reachable. Each entry must be a
// multiaddr with a /p2p/ peer id; anything else is dropped with a warning, never fatal.
import { multiaddr } from "@multiformats/multiaddr";

export function extraPeers(list = process.env.NOX_WAKU_PEERS, warn = console.warn) {
  const raw = Array.isArray(list) ? list : String(list || "").split(/[\s,]+/);
  const ok = [];
  for (const s of raw.map((x) => String(x).trim()).filter(Boolean)) {
    try {
      const m = multiaddr(s);
      if (!m.getPeerId()) throw new Error("no /p2p/ peer id");
      ok.push(m.toString());
    } catch (e) {
      warn(`extra Waku peer ignored (${s}): ${e.message}`);
    }
  }
  return [...new Set(ok)];
}
