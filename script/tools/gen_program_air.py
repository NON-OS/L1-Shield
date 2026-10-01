#!/usr/bin/env python3
"""Encode a circuit's transition tape and boundary list as program.bin, and plan its slot map.

    gen_program_air.py --tape transition-tape.json --oracle oracle.json --out-dir DIR [--library NAME]

Writes program.bin, slots.bin (one byte per op) and slots.sol (the slot map as a Solidity library)
into DIR. Launch inputs: spec/launch-program/transition-tape.json and spec/launch-honest/oracle.json.

Blob, big endian:
    u16 nOps  u16 nOut  u16 nBnd  u16 nRows  u16 nFrame  u16 nPer  u8 logT  u8 nExempt
    nExempt x u64    exempt points g^(t-k)
    nOps ops         u8 kind: 0 const u64 u64, 1 input u16, 2 add, 3 sub, 4 mul (u16 u16 each), 5 inv u16
    nOut x u16       the op that is transition i
    nRows x u64      g^row for each distinct boundary row
    nBnd entries     u8 col, u16 rowIdx, u8 src, then u64 value (src 0) or u8 public word k (src 1)
Input k reads the frame, then the periodic claims, then the challenge inputs.

The slot map follows the rules of ProgramFormAir `_liveness` and `_slots`. `plan` refuses a map
whose cell count is not the most values live at once.
"""
import argparse
import json
import pathlib
import struct
import subprocess

P = 0xFFFFFFFF00000001
OP_CONST, OP_INPUT, OP_ADD, OP_SUB, OP_MUL, OP_INV = range(6)
NO_SLOT = 0xFF


def keccak(b):
    """keccak256 through foundry's `cast`, which every environment building this repo has."""
    out = subprocess.run(["cast", "keccak", "0x" + b.hex()], capture_output=True, text=True, check=True)
    return out.stdout.strip()[2:]


def blob(tape, oracle):
    ops = tape["ops"]
    nf, npz = tape["inputs"]["frame"], tape["inputs"]["periodic"]
    t = 1 << oracle["log_trace_len"]
    g = oracle["g"]
    exempt = [pow(g, r, P) for r in oracle["exempt_rows"]]
    bnd = oracle["boundaries"]
    rows = []
    row_idx = {}
    for b in bnd:
        if b["row"] not in row_idx:
            row_idx[b["row"]] = len(rows)
            rows.append(b["row"])
    out = bytearray()
    out += struct.pack(">HHHHHHBB", len(ops), len(tape["outputs"]), len(bnd), len(rows),
                       nf, npz, oracle["log_trace_len"], len(exempt))
    for e in exempt:
        out += struct.pack(">Q", e)
    for op in ops:
        k = op[0]
        if k == "c":
            out += struct.pack(">BQQ", 0, op[1], op[2])
        elif k == "i":
            out += struct.pack(">BH", 1, op[1])
        elif k in "+-*":
            out += struct.pack(">BHH", {"+": 2, "-": 3, "*": 4}[k], op[1], op[2])
        elif k == "/":
            out += struct.pack(">BH", 5, op[1])
        else:
            raise SystemExit(f"unknown op {op}")
    for o in tape["outputs"]:
        out += struct.pack(">H", o)
    for r in rows:
        out += struct.pack(">Q", pow(g, r, P))
    for b in bnd:
        src = b["source"]
        if src == "const":
            out += struct.pack(">BHBQ", b["col"], row_idx[b["row"]], 0, b["value"])
        else:
            out += struct.pack(">BHBB", b["col"], row_idx[b["row"]], 1, int(src.split()[1]))
    assert len(ops) < 65536 and t == 1 << oracle["log_trace_len"]
    return bytes(out), len(rows)


def parse(prog):
    """The blob's ops as (kind, a, b), b = a for an inversion, its outputs, and where the
    transition part (header through outputs) ends."""
    n_ops, n_out, _, _, _, _, _, n_ex = struct.unpack(">HHHHHHBB", prog[:14])
    p = 14 + 8 * n_ex
    ops = []
    for _ in range(n_ops):
        k = prog[p]
        if k == OP_CONST:
            ops.append((k, 0, 0))
            p += 17
        elif k in (OP_INPUT, OP_INV):
            a = struct.unpack(">H", prog[p + 1:p + 3])[0]
            ops.append((k, a, a))
            p += 3
        else:
            ops.append((k,) + struct.unpack(">HH", prog[p + 1:p + 5]))
            p += 5
    outs = list(struct.unpack(f">{n_out}H", prog[p:p + 2 * n_out]))
    return ops, outs, p + 2 * n_out


def plan(ops, outs):
    """Liveness, fusion and slots, as ProgramFormAir's `_liveness` and `_slots` compute them."""
    n = len(ops)
    reads, last = [0] * n, [0] * n

    def read(v, reader):
        if reads[v] == 0:
            last[v] = reader
        reads[v] += 1

    for o in outs:
        read(o, n)
    for i in range(n - 1, -1, -1):
        k, a, b = ops[i]
        if k < OP_ADD or (reads[i] == 0 and k != OP_INV):
            continue
        read(a, i)
        if k != OP_INV:
            read(b, i)
    live = [reads[i] > 0 or ops[i][0] == OP_INV for i in range(n)]
    fused = [False] * n
    for i in range(n - 1):
        k, a, b = ops[i + 1]
        if ops[i][0] == OP_MUL and reads[i] == 1 and k in (OP_ADD, OP_SUB) and reads[i + 1] > 0 and i in (a, b):
            fused[i] = True

    def mac(i):
        return ops[i][0] == OP_ADD and fused[i - 1]

    chained = [False] * n
    for i in range(1, n - 2):
        if mac(i) and mac(i + 2) and reads[i] == 1 and i in ops[i + 2][1:]:
            chained[i] = True

    def operands(i):
        """As `_operands`: a and b, or for a fused run each multiply's a and b, then the first add's x."""
        k, a, b = ops[i]
        if i == 0 or not fused[i - 1]:
            return [a, b]
        head = i
        while head >= 3 and chained[head - 2]:
            head -= 2
        rd = []
        for m in range(head - 1, i, 2):
            rd += [ops[m][1], ops[m][2]]
        x = ops[head][1]
        return rd + [ops[head][2] if x == head - 1 else x]

    slot, free, n_slots = [NO_SLOT] * n, [], 0
    birth, death, t, dots = {}, {}, 0, 0  # instruction positions, for the independent count below
    for i in range(n):
        k = ops[i][0]
        if k < OP_ADD or not live[i] or fused[i] or chained[i]:
            continue
        rd = operands(i)
        dots += len(rd) > 3
        seen = []
        for v in rd:
            if v in seen:
                continue
            seen.append(v)
            if slot[v] == NO_SLOT:
                continue
            death[v] = t
            if last[v] <= i:
                free.append(slot[v])
        s = free.pop() if free else n_slots
        n_slots = max(n_slots, s + 1)
        if reads[i] == 0:
            free.append(s)
            death[i] = t
        slot[i] = s
        birth[i] = t
        t += 1
    for o in outs:
        if slot[o] != NO_SLOT:
            death[o] = t
    # the most values in cells at once: those born before an instruction and read after it,
    # plus the value it writes
    peak = max((sum(1 for v in birth if birth[v] < x and death[v] > x) + 1 for x in range(t)), default=0)
    if n_slots != peak or n_slots >= NO_SLOT:
        raise SystemExit(f"slot assignment took {n_slots} cells, the most live at once is {peak}")
    stats = {
        "instructions": t,
        "fused": sum(fused),
        "dots": dots,
        "chained": sum(chained),
        "dead": sum(1 for i in range(n) if ops[i][0] >= OP_ADD and not live[i]),
        "slots": n_slots,
    }
    return bytes(slot), stats


def slots_library(slots, n_slots, tape_hash):
    lines = "\n".join('        hex"%s"' % slots[i:i + 48].hex() for i in range(0, len(slots), 48))
    return f'''    /// @notice keccak256 of the transition part the slots were assigned for.
    bytes32 internal constant TAPE_HASH = 0x{tape_hash};
    /// @notice Slot cells the program takes: the most computed values live at once.
    uint256 internal constant N_SLOTS = {n_slots};
    /// @notice One byte per op: the slot of the value it writes, 0xff where it writes none.
    bytes internal constant SLOTS =
{lines};'''




def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tape", required=True)
    ap.add_argument("--oracle", required=True, help="an oracle of the circuit, for its boundary list")
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--library", default="LaunchSlots", help="name of the slot map library in slots.sol")
    a = ap.parse_args()
    tape = json.load(open(a.tape))
    oracle = json.load(open(a.oracle))
    prog, n_rows = blob(tape, oracle)
    ops, outs, tape_end = parse(prog)
    slots, st = plan(ops, outs)
    d = pathlib.Path(a.out_dir)
    d.mkdir(parents=True, exist_ok=True)
    (d / "program.bin").write_bytes(prog)
    (d / "slots.bin").write_bytes(slots)
    lib = slots_library(slots, st["slots"], keccak(prog[:tape_end]))
    (d / "slots.sol").write_text(f"library {a.library} {{\n{lib}\n}}\n")
    print(f"program.bin {len(prog)} bytes: {len(tape['ops'])} ops, {len(tape['outputs'])} transitions, "
          f"{len(oracle['boundaries'])} boundaries on {n_rows} rows")
    print(f"slots: {st['instructions']} instructions, {st['fused']} multiplies fused, {st['dots']} dot runs "
          f"covering {st['chained']} chained adds, {st['dead']} dead values dropped, "
          f"{st['slots']} slot cells")


main()
