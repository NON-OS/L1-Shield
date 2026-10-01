import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as S from "../src/index.mjs";

const sched = { protocolFee: 500000000000000n, ladder: [2500000000000000n, 5000000000000000n, 10000000000000000n, 20000000000000000n], set: true };

test("a private transfer pays the protocol part plus exactly one rung", () => {
  assert.deepEqual(S.quote({ sched, withdrawBps: 50n, rung: 0 }), { fee: 3000000000000000n, protocolPart: 500000000000000n, gasPart: 2500000000000000n });
  assert.equal(S.quote({ sched, withdrawBps: 50n, rung: 3 }).fee, 20500000000000000n);
});

test("a self-submitted proof pays the protocol part only", () => {
  assert.equal(S.quote({ sched, withdrawBps: 50n, rung: null }).fee, 500000000000000n);
});

test("a withdrawal's protocol part is 0.50% of the amount", () => {
  assert.equal(S.quote({ publicAmount: 10n ** 18n, sched, withdrawBps: 50n, rung: 0 }).protocolPart, 5n * 10n ** 15n);
});

test("a rung outside the ladder is refused", () => {
  assert.throws(() => S.quote({ sched, withdrawBps: 50n, rung: 4 }));
  assert.throws(() => S.quote({ sched, withdrawBps: 50n, rung: 1.5 }));
});

test("not-before is the grid point just passed, never ahead of now", () => {
  assert.equal(S.notBefore(1790812800), 1790812800n);
  assert.equal(S.notBefore(1790813399), 1790812800n);
  assert.equal(S.notBefore(1790813400), 1790813400n);
  const now = Math.floor(Date.now() / 1000);
  const nb = S.notBefore(now);
  assert.ok(nb <= BigInt(now) && nb % 600n === 0n && nb > 0n);
});

test("standard amounts are 1, 2 or 5 times a power of ten", () => {
  for (const ok of [1n, 2n, 5n, 10n ** 15n, 2n * 10n ** 18n, 5n * 10n ** 17n]) assert.ok(S.isStandardAmount(ok), String(ok));
  for (const bad of [0n, 3n, 15n, 25n * 10n ** 14n, 1001n]) assert.ok(!S.isStandardAmount(bad), String(bad));
});

test("open settlement pays address(1)", () => {
  assert.deepEqual(S.feeRecipientLimbs(), [1n, 0n, 0n, 0n]);
});

test("a package round-trips, and a changed length is refused", () => {
  const proof = Buffer.concat([Buffer.from("4e4f58500700", "hex"), Buffer.alloc(90_000, 3)]);
  const limbs = Array.from({ length: 37 }, (_, i) => (i === 0 ? S.P - 1n : BigInt(i)));
  const pkg = S.encodePackage(proof, Buffer.alloc(1186, 1), Buffer.alloc(1186, 2), limbs);
  const d = S.decodePackage(pkg);
  assert.ok(Buffer.from(d.proof).equals(proof));
  assert.deepEqual(d.limbs, limbs);
  assert.throws(() => S.decodePackage(pkg.subarray(0, pkg.length - 1)));
});

test("a format 5 proof and an oversized package are refused", () => {
  const f5 = Buffer.concat([Buffer.from("4e4f58500500", "hex"), Buffer.alloc(100)]);
  assert.throws(() => S.encodePackage(f5, Buffer.alloc(1186), Buffer.alloc(1186), []));
  const huge = Buffer.concat([Buffer.from("4e4f58500700", "hex"), Buffer.alloc(S.MAX_BYTES)]);
  assert.throws(() => S.encodePackage(huge, Buffer.alloc(1186), Buffer.alloc(1186), []));
});

const live = process.env.NOX_LIVE ? test : test.skip;

live("live: the schedule and percentages are the production ones", async () => {
  const eth = await S.schedule(S.ASSET.ETH);
  assert.deepEqual(eth, sched);
  assert.deepEqual(await S.bps(), { deposit: 50n, withdraw: 50n });
});

live("live: the policy agrees with quote() and refuses a fee off the ladder", async () => {
  const q = S.quote({ sched, withdrawBps: 50n, rung: 0 });
  assert.deepEqual(await S.checkFee({ asset: 0n, fee: q.fee, relayed: true }), { protocolPart: q.protocolPart, gasPart: q.gasPart });
  await assert.rejects(S.checkFee({ asset: 0n, fee: q.fee + 1n, relayed: true }));
  assert.equal(await S.depositFee(0n, 10n ** 18n), 5n * 10n ** 15n);
});

live("live: C9's notes read as landed on both RPCs", async () => {
  // the C9 transfer on the production pool; its nullifiers from its statement
  const v = JSON.parse(readFileSync(new URL("./c9.json", import.meta.url)));
  const r = await S.landed(v.nf0, v.nf1);
  assert.equal(r.settled, true);
  assert.equal(r.disagree, false);
});

test("extra Waku peers: valid multiaddrs kept, malformed and peer-less dropped, never fatal", async () => {
  const { generateKeyPair } = await import("@libp2p/crypto/keys");
  const { peerIdFromPrivateKey } = await import("@libp2p/peer-id");
  const id = peerIdFromPrivateKey(await generateKeyPair("secp256k1")).toString();
  const good = `/ip4/127.0.0.1/tcp/1/ws/p2p/${id}`;
  const warned = [];
  const out = S.extraPeers([good, "garbage", "/ip4/127.0.0.1/tcp/1/ws", good], (m) => warned.push(m));
  assert.deepEqual(out, [good]);
  assert.equal(warned.length, 2);
  assert.deepEqual(S.extraPeers(`${good}, ${good}`, () => {}), [good]);
  assert.deepEqual(S.extraPeers("", () => {}), []);
});
