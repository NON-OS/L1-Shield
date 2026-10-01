// Statement fields the wallet sets before proving.
import { NOT_BEFORE_GRID, SUBMITTER } from "./constants.mjs";

/** The grid point just passed: on the 600 s grid, never zero, and already reached, so no wait. */
export function notBefore(nowSeconds = Math.floor(Date.now() / 1000)) {
  const t = Math.floor(nowSeconds / NOT_BEFORE_GRID) * NOT_BEFORE_GRID;
  if (t <= 0) throw new Error("the clock is before the grid");
  return BigInt(t);
}

/** Amounts come in standard sizes only: 1, 2 or 5 times a power of ten, in note units. */
export function isStandardAmount(units) {
  let u = BigInt(units);
  if (u <= 0n) return false;
  while (u % 10n === 0n) u /= 10n;
  return u === 1n || u === 2n || u === 5n;
}

/** Fee recipient limbs for open settlement: the proof pays whoever lands it. */
export const feeRecipientLimbs = () => [...SUBMITTER];
