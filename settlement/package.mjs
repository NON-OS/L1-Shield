// The open settlement package: one Waku message carrying everything a lander needs to settle a proof.
//
//   bytes 0..3    "NOXH"
//   byte  4       version, 1
//   bytes 5..8    proof length P, u32 big-endian
//   bytes 9..12   limbs length L, u32 big-endian
//   then          the format 7 proof package (P bytes, starts "NOXP" 07 00)
//   then          sealed note 0 (1,186 bytes), sealed note 1 (1,186 bytes)
//   then          the public limbs as JSON, an array of decimal strings (L bytes)
//
// The whole message must stay under the network's 150 KiB limit; a proof is at most about 100 KB.
export const TOPIC = "/nox-shield/1/proof/proto";
export const MAX_BYTES = 150 * 1024;
const MAGIC = Buffer.from("NOXH");
const NOTE = 1186;

export function encode(proof, note0, note1, limbs) {
  if (proof.subarray(0, 6).toString("hex") !== "4e4f58500700") throw new Error("not a format 7 proof");
  if (note0.length !== NOTE || note1.length !== NOTE) throw new Error("each sealed note is 1,186 bytes");
  const lj = Buffer.from(JSON.stringify(limbs.map((v) => BigInt(v).toString())));
  const head = Buffer.alloc(13);
  MAGIC.copy(head, 0);
  head[4] = 1;
  head.writeUInt32BE(proof.length, 5);
  head.writeUInt32BE(lj.length, 9);
  const out = Buffer.concat([head, proof, note0, note1, lj]);
  if (out.length > MAX_BYTES) throw new Error(`a package is at most ${MAX_BYTES} bytes, this one ${out.length}`);
  return out;
}

export function decode(buf) {
  const b = Buffer.from(buf);
  if (b.length > MAX_BYTES) throw new Error(`a package is at most ${MAX_BYTES} bytes`);
  if (b.length < 13 || !b.subarray(0, 4).equals(MAGIC) || b[4] !== 1) throw new Error("not a version 1 package");
  const p = b.readUInt32BE(5);
  const l = b.readUInt32BE(9);
  if (13 + p + 2 * NOTE + l !== b.length) throw new Error("the lengths do not add up");
  const proof = b.subarray(13, 13 + p);
  const note0 = b.subarray(13 + p, 13 + p + NOTE);
  const note1 = b.subarray(13 + p + NOTE, 13 + p + 2 * NOTE);
  const limbs = JSON.parse(b.subarray(13 + p + 2 * NOTE).toString()).map((s) => BigInt(s));
  return { proof, note0, note1, limbs };
}
