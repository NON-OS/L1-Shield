#!/usr/bin/env bash
# A quantity the structure file publishes has one home in contracts/shield. A second literal home
# fails the gate. Homes are counted by constant name, never by value, since unrelated quantities
# share the value 7. Duplicated internal constants are reported and do not fail.
set -uo pipefail
cd "$(dirname "$0")/../../.." || exit 2
DIR=contracts/shield

# With no files every quantity has zero homes, so an empty scan is refused and never reported as a pass.
if [ ! -d "$DIR" ]; then
  echo "one-home: $DIR does not exist. Refusing to report a pass over nothing" >&2
  exit 2
fi
SCANNED=$(find "$DIR" -name '*.sol' | wc -l | tr -d ' ')
if [ "${SCANNED:-0}" -lt 10 ]; then
  echo "one-home: only $SCANNED solidity files under $DIR. Refusing to report a pass over nothing" >&2
  exit 2
fi
echo "scanned $SCANNED solidity files under $DIR"
echo

fail=0
report() {
  pat="$1"; what="$2"; src="$3"; hard="$4"
  homes=$(grep -rlE "constant (${pat}) = [0-9]+;" "$DIR" 2>/dev/null | sort -u)
  n=$(printf '%s' "$homes" | grep -c . || true)
  printf '%-44s %-6s %s\n' "$what" "$n" "$src"
  if [ "$n" -gt 1 ]; then
    printf '%s\n' "$homes" | sed 's|^|      |'
    if [ "$hard" = hard ]; then fail=1; fi
  fi
}

printf '%-44s %-6s %s\n' "QUANTITY" "HOMES" "SHOULD READ"
echo "published by the structure file, more than one home fails"
report 'SHIFT|COSET_SHIFT' 'the evaluation coset offset (coset_shift)' 'ProductionAir.COSET_SHIFT' hard
echo "internal, reported only"
report 'BETA'  'the permutation challenge beta'  'a transcript squeeze, never a constant' soft
report 'GAMMA' 'the permutation challenge gamma' 'a transcript squeeze, never a constant' soft
report 'W'     'the Fp2 tower modulus X^2-W'     'StarkFieldExt.W' soft
report 'GEN'   'the domain generator'            'one definition' soft

echo
if [ "$fail" -eq 0 ]; then
  echo "every published quantity has one home."
  exit 0
fi
cat <<'MSG'
A published quantity above has more than one home.

The copies agree only while every copy holds the same number. No test catches a drift, since both
homes say the same thing to every test. Read the single source, or read the structure file at
construction. Where a signature cannot take another argument, refuse the mismatch at the boundary,
as RealSplitVerifier does with CosetShiftMismatch.
MSG
exit 1
