// The fee model, read from the amount policy. A relayed proof (one landed by someone else) pays the
// protocol part plus exactly one gas rung; a self-submitted proof pays the protocol part only. The pool
// refuses any other fee, so quote() is exact, never a cap.
import { AMOUNT_POLICY } from "./constants.mjs";
import { call, encode, words } from "./rpc.mjs";

export async function schedule(asset, opts) {
  const w = words(await call(AMOUNT_POLICY, encode("scheduleOf", asset), opts));
  return { protocolFee: w[0], ladder: w.slice(1, 5), set: w[5] === 1n };
}

export async function bps(opts) {
  const w = words(await call(AMOUNT_POLICY, encode("bps"), opts));
  return { deposit: w[0], withdraw: w[1] };
}

/** The protocol part: the flat fee for a private transfer (publicAmount 0), else the withdrawal share. */
export function protocolPart(publicAmount, sched, withdrawBps) {
  return publicAmount === 0n ? sched.protocolFee : (publicAmount * withdrawBps) / 10_000n;
}

/** The exact fee for a proof. rung: 0..3 when relayed, null when the sender lands it. */
export function quote({ publicAmount = 0n, rung = 0, sched, withdrawBps }) {
  const proto = protocolPart(BigInt(publicAmount), sched, BigInt(withdrawBps));
  if (rung === null) return { fee: proto, protocolPart: proto, gasPart: 0n };
  if (!Number.isInteger(rung) || rung < 0 || rung > 3) throw new Error("rung is 0 to 3, or null when self-submitted");
  const gas = sched.ladder[rung];
  return { fee: proto + gas, protocolPart: proto, gasPart: gas };
}

/** Asks the policy itself: reverts on any fee the pool would refuse. Use before proving. */
export async function checkFee({ asset, publicAmount = 0n, fee, relayed }, opts) {
  const w = words(await call(AMOUNT_POLICY, encode("settlementFee", asset, publicAmount, fee, relayed), opts));
  return { protocolPart: w[0], gasPart: w[1] };
}

export async function depositFee(asset, amount, opts) {
  return words(await call(AMOUNT_POLICY, encode("depositFee", asset, amount), opts))[0];
}
