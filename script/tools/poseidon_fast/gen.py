#!/usr/bin/env python3
"""Generates PoseidonGoldilocksFast: straight-line EVM bytecode for Poseidon over Goldilocks
(width 8, x^7, 32 full rounds) from spec/poseidon-constants.json, bit-compatible with
contracts/shield/PoseidonGoldilocks.sol (hash2 and hashFields, the same reverts).

Three ideas carry the gas:

1. Integer MDS. M[j][k] = -1/(8+k-j) mod p, so M = f*M' with f = -1/L, L = lcm(1..15) and
   M'[j][k] = L/(8+k-j) a small integer (at most 360360, 19 bits).
2. Lane packing. With M' small and t = sbox(state) < p < 2^64, a row sum
   c*rc[j] + sum_k M'[j][k]*t[k] stays below 2^84. Three rows share one 256-bit word: column k
   of rows (a,b,c) is packed as P = M'[a][k] | M'[b][k]<<84 | M'[c][k]<<168, and one MUL by t[k]
   adds three row terms at once. 8 rows need 3 words, so 24 MULs per round instead of 64.
3. Rolling scale. The factor f is absorbed by carrying the state scaled, w_r = c_r*s_r, with
   c_{-1} = 1 and c_r = c_{r-1}^7 / f. Then w_r[j] = c_r*rc_r[j] + sum_k M'[j][k]*w_{r-1}[k]^7
   holds exactly, so no per-element multiply by f is left; the output is unscaled once by c_r^-1.
   The S-box takes the unreduced lane (< 2^84): l^2 by MUL, l^3 by MULMOD, l^6 by MUL, l^7 by
   MULMOD, four multiplies with two reductions.

Output: spec/poseidon-fast/PoseidonGoldilocksFast.initcode.hex, .runtime.hex and .lst (annotated
listing), or, with --print initcode|runtime, that hex on stdout and nothing written (the forge test
that regenerates the bytecode uses it). --out DIR writes elsewhere. --with-note adds the
commitNote(uint256[11]) entry the research build had; the pool does not call it, and the default
build leaves it out.
The runtime is a prefix of the initcode; the constructor tail sits after it and runs the
known-answer vectors through the same subroutines before returning the runtime.
"""
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
SPEC = os.environ.get("POSEIDON_SPEC") or os.path.join(ROOT, "spec", "poseidon-constants.json")
OUT = os.path.join(ROOT, "spec", "poseidon-fast")
WITH_NOTE = "--with-note" in sys.argv

spec = json.load(open(SPEC))
P = int(spec["field_modulus"])
WIDTH = int(spec["width"])
ROUNDS = int(spec["rounds"])
assert WIDTH == 8 and int(spec["sbox_alpha"]) == 7 and ROUNDS == 32
MDS = [[int(x) for x in row] for row in spec["mds"]]
RC = [[int(x) for x in row] for row in spec["round_constants"]]
NOTE_DOMAIN = 1313821765
MASK64 = (1 << 64) - 1

# ---------------------------------------------------------------- reference (spec conventions)


def ref_round(s, r):
    t = [pow(x, 7, P) for x in s]
    return [(RC[r][j] + sum(MDS[j][k] * t[k] for k in range(8))) % P for j in range(8)]


def ref_perm(s, n):
    for r in range(n):
        s = ref_round(s, r)
    return s


def ref_compress(a, b):
    return ref_perm(list(a) + list(b), ROUNDS)[:4]


def ref_hash4(x):
    return ref_perm(list(x) + [0] * 4, ROUNDS - 1)[:4]


def ref_note(m):
    p = list(m) + [NOTE_DOMAIN, 0, 0, 0, 0]
    return ref_compress(ref_compress(p[0:4], p[4:8]), ref_compress(p[8:12], p[12:16]))


def pack(l):
    return l[0] | l[1] << 64 | l[2] << 128 | l[3] << 192


for kat in spec["kats"]:
    want = [int(x) for x in kat["digest"]]
    if kat["op"] == "compress":
        got = ref_compress([int(x) for x in kat["left"]], [int(x) for x in kat["right"]])
    elif kat["op"] == "hash":
        got = ref_hash4([int(x) for x in kat["input"]])
    else:
        got = ref_note([int(x) for x in kat["limbs"]])
    assert got == want, kat["op"]

# ---------------------------------------------------------------- integer MDS and scales

# find n with M[j][k] = sgn/n
D = [[None] * 8 for _ in range(8)]
for j in range(8):
    for k in range(8):
        for n in range(1, 64):
            if MDS[j][k] * n % P == P - 1:
                D[j][k] = n
                break
        assert D[j][k] is not None, "MDS entry is not -1/n"
L = 1
for row in D:
    for n in row:
        L = L * n // math.gcd(L, n)
MP = [[L // D[j][k] for k in range(8)] for j in range(8)]  # M' integers
F = (-pow(L, -1, P)) % P  # M = F * M'
for j in range(8):
    for k in range(8):
        assert MDS[j][k] == F * MP[j][k] % P

FINV = pow(F, -1, P)
C = []  # C[r]: w_r = C[r] * s_r
c = 1
for r in range(ROUNDS):
    c = pow(c, 7, P) * FINV % P
    C.append(c)
CINV = [pow(x, -1, P) for x in C]

W = 84  # lane width
LANE_MASK = (1 << W) - 1
GROUPS = [[0, 1, 2], [3, 4, 5], [6, 7]]
for g in GROUPS:
    for i, j in enumerate(g):
        bound = (P - 1) * (1 + sum(MP[j]))  # init < p, each t < p
        cap = W if i < len(g) - 1 else 256 - W * i
        assert bound < (1 << cap), (j, math.log2(bound))
    assert W * (len(g) - 1) < 256


def packed_col(g, k):
    return sum(MP[j][k] << (W * i) for i, j in enumerate(GROUPS[g]))


def packed_init(g, r):
    return sum((C[r] * RC[r][j] % P) << (W * i) for i, j in enumerate(GROUPS[g]))


# fast model, mirroring the bytecode's integer operations exactly
U256 = (1 << 256) - 1


def fast_sbox(l):
    assert l < (1 << 128)
    l2 = l * l
    l3 = l2 * l % P
    l6 = l3 * l3
    assert l6 <= U256
    return l6 * l % P


def fast_round(lanes, r, groups):
    t = [fast_sbox(x) for x in lanes]
    accs = []
    for g in groups:
        acc = packed_init(g, r)
        for k in range(8):
            acc += packed_col(g, k) * t[k]
            assert acc <= U256
        accs.append(acc)
    return accs


def unpack(accs, groups):
    out = {}
    for acc, g in zip(accs, groups):
        for i, j in enumerate(GROUPS[g]):
            out[j] = (acc >> (W * i)) & (LANE_MASK if i < len(GROUPS[g]) - 1 else U256)
    return out


def fast_perm(x, n):
    lanes = list(x)
    for r in range(n):
        groups = [0, 1, 2] if r < ROUNDS - 1 else [0, 1]
        accs = fast_round(lanes, r, groups)
        u = unpack(accs, groups)
        lanes = [u.get(j) for j in range(8)]
    return [lanes[j] * CINV[n - 1] % P for j in range(4)]


import random

rng = random.Random(1)
for _ in range(200):
    x = [rng.randrange(P) for _ in range(8)]
    assert fast_perm(x, 32) == ref_perm(x, 32)[:4]
    assert fast_perm(x[:4] + [0] * 4, 31) == ref_perm(x[:4] + [0] * 4, 31)[:4]
assert fast_perm([P - 1] * 8, 32) == ref_perm([P - 1] * 8, 32)[:4]

# ---------------------------------------------------------------- assembler

OPS = {
    "STOP": 0x00, "ADD": 0x01, "MUL": 0x02, "SUB": 0x03, "MOD": 0x06, "MULMOD": 0x09,
    "LT": 0x10, "GT": 0x11, "SLT": 0x12, "EQ": 0x14, "ISZERO": 0x15, "AND": 0x16, "OR": 0x17,
    "SHL": 0x1B, "SHR": 0x1C, "CALLVALUE": 0x34, "CALLDATALOAD": 0x35, "CALLDATASIZE": 0x36,
    "CODESIZE": 0x38, "CODECOPY": 0x39, "POP": 0x50, "MLOAD": 0x51, "MSTORE": 0x52,
    "JUMP": 0x56, "JUMPI": 0x57, "JUMPDEST": 0x5B, "RETURN": 0xF3, "REVERT": 0xFD,
}
for i in range(1, 17):
    OPS[f"DUP{i}"] = 0x7F + i
    OPS[f"SWAP{i}"] = 0x8F + i
GAS = {"STOP": 0, "JUMPDEST": 1, "JUMP": 8, "JUMPI": 10, "MUL": 5, "MOD": 5, "MULMOD": 8,
       "CALLVALUE": 2, "CALLDATASIZE": 2, "CODESIZE": 2, "POP": 2}


class Asm:
    def __init__(self):
        self.items = []  # (kind, value, comment)

    def op(self, name, comment=""):
        assert name in OPS, name
        self.items.append(("op", name, comment))

    def push(self, v, comment="", width=None):
        assert 0 <= v <= U256
        n = width or max(1, (v.bit_length() + 7) // 8)
        self.items.append(("push", (v, n), comment))

    def pushlabel(self, lab, comment=""):
        self.items.append(("plabel", lab, comment))

    def label(self, lab):
        self.items.append(("label", lab, ""))

    def data(self, b, comment=""):
        self.items.append(("data", b, comment))

    def assemble(self):
        pcs, labels, pc = [], {}, 0
        for kind, v, _ in self.items:
            pcs.append(pc)
            if kind == "op":
                pc += 1
            elif kind == "push":
                pc += 1 + v[1]
            elif kind == "plabel":
                pc += 3
            elif kind == "label":
                labels[v] = pc
                pc += 1
            elif kind == "mark":
                labels[v] = pc
            else:
                pc += len(v)
        out, lst = bytearray(), []
        for (kind, v, cm), at in zip(self.items, pcs):
            if kind == "op":
                out.append(OPS[v])
                txt = v
            elif kind == "push":
                out.append(0x5F + v[1])
                out += v[0].to_bytes(v[1], "big")
                txt = f"PUSH{v[1]} 0x{v[0]:x}"
            elif kind == "plabel":
                out.append(0x61)
                out += labels[v].to_bytes(2, "big")
                txt = f"PUSH2 {v} ({labels[v]})"
            elif kind == "label":
                out.append(0x5B)
                txt = f"JUMPDEST  ; {v}:"
            elif kind == "mark":
                txt = f"; ---- {v} ----"
            else:
                out += v
                txt = f"DATA {len(v)} bytes"
            lst.append(f"{at:05x}  {txt}" + (f"   ; {cm}" if cm else ""))
        return bytes(out), labels, lst


class Stack:
    """Tracks symbolic stack names (bottom first) while emitting code."""

    def __init__(self, asm, names):
        self.a = asm
        self.st = list(names)

    def depth(self, name):
        i = len(self.st) - 1 - self.st.index(name)
        return i + 1

    def push(self, v, name, comment=""):
        self.a.push(v, comment)
        self.st.append(name)

    def pushlabel(self, lab, name):
        self.a.pushlabel(lab)
        self.st.append(name)

    def dup(self, name, new):
        d = self.depth(name)
        assert d <= 16, ("DUP too deep", name, d)
        self.a.op(f"DUP{d}")
        self.st.append(new)

    def swap(self, n):
        assert 1 <= n <= 16, n
        self.a.op(f"SWAP{n}")
        self.st[-1], self.st[-1 - n] = self.st[-1 - n], self.st[-1]

    def to_top(self, name):
        d = self.depth(name)
        if d > 1:
            self.swap(d - 1)

    def op(self, name, pops, new=None, comment=""):
        self.a.op(name, comment)
        for _ in range(pops):
            self.st.pop()
        if new is not None:
            self.st.append(new)

    def pop(self):
        self.op("POP", 1)

    def rename(self, old, new):
        self.st[self.st.index(old)] = new

    def arrange(self, order):
        """Permute the top len(order) items to `order` (bottom first) with SWAPs."""
        n = len(order)
        assert sorted(self.st[-n:]) == sorted(order), (self.st[-n:], order)
        for i in range(n):  # fix position i (from the bottom of the window)
            want = order[i]
            pos_d = n - i  # depth of slot i
            if self.st[-pos_d] == want:
                continue
            if self.st[-1] != want:
                self.to_top(want)
            if pos_d > 1:
                self.swap(pos_d - 1)
        assert self.st[-n:] == order


# ---------------------------------------------------------------- code generation

CONST_WORDS = [packed_col(g, k) for g in range(3) for k in range(8)]
CONST_BYTES = b"".join(w.to_bytes(32, "big") for w in CONST_WORDS)


def caddr(g, k):
    return 32 * (8 * g + k)


def sbox(s, lname, tname):
    """Top of stack is lane `lname` (< 2^84 or canonical); replaces it with t = lane^7 mod p."""
    assert s.st[-1] == lname
    s.dup(lname, "_l1")
    s.dup(lname, "_l1b")
    s.op("MUL", 2, "_l2")
    s.push(P, "_p")
    s.swap(1)
    s.dup(lname, "_l")
    s.op("MULMOD", 3, "_l3")
    s.dup("_l3", "_l3b")
    s.op("MUL", 2, "_l6")
    s.push(P, "_p")
    s.swap(2)
    s.op("MULMOD", 3, tname)


def mds(s, r, groups, tnames):
    """t's on top (any order); leaves one packed accumulator per group, last group on top."""
    for g in groups[:-1]:
        init = packed_init(g, r)
        s.push(init, f"acc{g}", f"round {r} group {g} init")
        for k in range(8):
            s.push(caddr(g, k), "_a")
            s.op("MLOAD", 1, "_c")
            s.dup(tnames[k], "_t")
            s.op("MUL", 2, "_m")
            s.op("ADD", 2, f"acc{g}")
        s.swap(8)  # bury below the t's
    g = groups[-1]
    first = True
    for _ in range(8):
        tk = s.st[-1] if first else s.st[-2]
        if not first:
            s.swap(1)
        k = tnames.index(tk)
        s.push(caddr(g, k), "_a")
        s.op("MLOAD", 1, "_c")
        s.op("MUL", 2, f"acc{g}" if first else "_m")
        if not first:
            s.op("ADD", 2, f"acc{g}")
        first = False
    init = packed_init(g, r)
    if init:
        s.push(init, "_i", f"round {r} group {g} init")
        s.op("ADD", 2, f"acc{g}")
    # rename to round-tagged names
    for gg in groups:
        s.rename(f"acc{gg}", f"acc{gg}_r{r}")


def lane(s, acc, g, i, new, consume):
    """Pushes lane i of packed word `acc`; with consume, the word is replaced (top lane or last use)."""
    n = len(GROUPS[g])
    top = i == n - 1
    if consume:
        s.to_top(acc)
        s.rename(acc, "_w")
    else:
        s.dup(acc, "_w")
    if i:
        s.push(W * i, "_sh")
        s.op("SHR", 2, "_w")
    if not top:
        s.push(LANE_MASK, "_mk")
        s.op("AND", 2, "_w")
    s.rename("_w", new)


def lanes_to_t(s, r):
    """Packed round-r accumulators on the stack -> the 8 t's feeding round r+1."""
    tn = []
    for g in (2, 1, 0):
        acc = f"acc{g}_r{r}"
        n = len(GROUPS[g])
        for i, j in enumerate(GROUPS[g]):
            lane(s, acc, g, i, f"l{j}", consume=(i == n - 1))
            sbox(s, f"l{j}", f"t{j}")
            tn.append(f"t{j}")
    return [f"t{j}" for j in range(8)]


def unscale(s, name, cinv, new):
    assert s.st[-1] == name
    s.push(P, "_p")
    s.swap(1)
    s.push(cinv, "_ci")
    s.op("MULMOD", 3, new)




# Calling conventions (stack bottom first, ret = return label):
#   PERM31     [ret, x0..x7]        -> rounds 0..30 -> jumps to ret with [acc0, acc1, acc2]
#   COMPRESS_R [ret2, acc0..acc2]   -> round 31, unscale -> jumps to ret2 with [r0, r1, r2, r3]
# A compression is: push ret2, push COMPRESS_R, push x0..x7, jump PERM31.


def gen_perm31(a):
    a.label("PERM31")
    s = Stack(a, ["ret"] + [f"x{k}" for k in range(8)])
    for k in range(7, -1, -1):  # x7 is on top already
        s.to_top(f"x{k}")
        s.rename(f"x{k}", f"l{k}")
        sbox(s, f"l{k}", f"t{k}")
    mds(s, 0, [0, 1, 2], [f"t{k}" for k in range(8)])
    for r in range(1, ROUNDS - 1):
        tn = lanes_to_t(s, r - 1)
        mds(s, r, [0, 1, 2], tn)
    res = [f"acc{g}_r{ROUNDS - 2}" for g in range(3)]
    assert s.st == ["ret"] + res
    s.arrange(res[:2] + ["ret", res[2]])
    s.swap(1)
    s.op("JUMP", 1)
    assert s.st == res


def gen_compress_r(a):
    a.label("COMPRESS_R")
    r0 = ROUNDS - 2
    s = Stack(a, ["ret"] + [f"acc{g}_r{r0}" for g in range(3)])
    tn = lanes_to_t(s, r0)
    r = ROUNDS - 1
    mds(s, r, [0, 1], tn)
    emit_out4(s, r)
    s.arrange(["r0", "r1", "r2", "ret", "r3"])
    s.swap(1)
    s.op("JUMP", 1)
    assert s.st == ["r0", "r1", "r2", "r3"]


def emit_out4(s, r):
    """Rows 0,1,2 are acc0's lanes, row 3 is acc1's lane 0; unscale by C[r]^-1."""
    lane(s, f"acc0_r{r}", 0, 0, "o0", False)
    unscale(s, "o0", CINV[r], "r0")
    lane(s, f"acc0_r{r}", 0, 1, "o1", False)
    unscale(s, "o1", CINV[r], "r1")
    lane(s, f"acc0_r{r}", 0, 2, "o2", True)
    unscale(s, "o2", CINV[r], "r2")
    lane(s, f"acc1_r{r}", 1, 0, "o3", True)
    unscale(s, "o3", CINV[r], "r3")
    s.arrange(["r0", "r1", "r2", "r3"])


def emit_pack(s):
    """[.., r0, r1, r2, r3] -> digest = r0 | r1<<64 | r2<<128 | r3<<192."""
    assert s.st[-4:] == ["r0", "r1", "r2", "r3"]
    s.push(192, "_s")
    s.op("SHL", 2, "_d")
    s.swap(1)
    s.push(128, "_s")
    s.op("SHL", 2, "_e")
    s.op("OR", 2, "_d")
    s.swap(1)
    s.push(64, "_s")
    s.op("SHL", 2, "_e")
    s.op("OR", 2, "_d")
    s.op("OR", 2, "digest")


def emit_consts(a):
    a.push(len(CONST_BYTES), "constant table", 2)
    a.pushlabel("CONSTS")
    a.push(0)
    a.op("CODECOPY")


def emit_revert_sel(a, lab, sel):
    a.label(lab)
    a.push(sel)
    a.push(224)
    a.op("SHL")
    a.push(0)
    a.op("MSTORE")
    a.push(4)
    a.push(0)
    a.op("REVERT")


SEL_HASH2, SEL_FIELDS, SEL_NOTE = 0xB30C0B6A, 0xA9F139E7, 0x77FC0203
ERR_NONCANON, ERR_SPONGE, ERR_KAT = 0x81AB7440, 0x85434ABE, 0x46D87A89


def emit_flag(s, names):
    """Pushes 'bad' = OR over names of (x > p-1)."""
    for i, n in enumerate(names):
        s.push(P - 1, "_pm")
        s.dup(n, "_x")
        s.op("GT", 2, "_g" if i == 0 else "_g2")
        if i:
            s.op("OR", 2, "_g")
    s.rename("_g", "bad")


def emit_min_len(s, n):
    """revert(0,0) if slt(sub(calldatasize, 4), n), as solc's ABI decoder."""
    s.push(n, "_n")
    s.push(4, "_4")
    s.op("CALLDATASIZE", 0, "_cs")
    s.op("SUB", 2, "_len")
    s.op("SLT", 2, "_b")
    s.a.pushlabel("REV")
    s.op("JUMPI", 1)


def emit_return_word(s):
    s.push(0, "_z")
    s.op("MSTORE", 2)
    s.a.push(32)
    s.a.push(0)
    s.a.op("RETURN")


def emit_jump(s, lab):
    s.a.pushlabel(lab)
    s.a.op("JUMP")


def build():
    a = Asm()
    a.op("CALLVALUE")
    a.pushlabel("REV")
    a.op("JUMPI")
    a.push(4)
    a.op("CALLDATASIZE")
    a.op("LT")
    a.pushlabel("SHORT")
    a.op("JUMPI")
    a.push(0)
    a.op("CALLDATALOAD")
    a.push(224)
    a.op("SHR")
    for sel, lab in ((SEL_HASH2, "F_HASH2"),) + (((SEL_NOTE, "F_NOTE"),) if WITH_NOTE else ()):
        a.op("DUP1")
        a.push(sel)
        a.op("EQ")
        a.pushlabel(lab)
        a.op("JUMPI")
    a.push(SEL_FIELDS)
    a.op("EQ")
    a.pushlabel("F_FIELDS")
    a.op("JUMPI")
    a.label("REV")
    a.push(0)
    a.op("DUP1")
    a.op("REVERT")
    a.label("SHORT")
    a.pushlabel("RUNTIME_END")
    a.op("CODESIZE")
    a.op("GT")
    a.pushlabel("CTOR")
    a.op("JUMPI")
    a.push(0)
    a.op("DUP1")
    a.op("REVERT")
    emit_revert_sel(a, "E_NONCANON", ERR_NONCANON)
    emit_revert_sel(a, "E_SPONGE", ERR_SPONGE)

    # ---------------- hash2(bytes32 left, bytes32 right)
    a.label("F_HASH2")
    s = Stack(a, ["sel"])
    s.pop()
    emit_min_len(s, 64)
    s.pushlabel("RET_HASH2", "ret2")
    s.pushlabel("COMPRESS_R", "ret")
    for k in range(8):
        s.push(4 if k < 4 else 36, "_o")
        s.op("CALLDATALOAD", 1, "_w")
        sh = 64 * (k % 4)
        if sh:
            s.push(sh, "_s")
            s.op("SHR", 2, "_w")
        if sh != 192:
            s.push(MASK64, "_m")
            s.op("AND", 2, "_w")
        s.rename("_w", f"x{k}")
    emit_flag(s, [f"x{k}" for k in range(8)])
    s.a.pushlabel("E_NONCANON")
    s.op("JUMPI", 1)
    emit_consts(a)
    emit_jump(s, "PERM31")
    a.label("RET_HASH2")
    s = Stack(a, ["r0", "r1", "r2", "r3"])
    emit_pack(s)
    emit_return_word(s)

    # ---------------- commitNote(uint256[11] limbs), --with-note only
    # cm = compress(compress(m0..m7), compress(m8, m9, m10, NOTE, 0, 0, 0, 0))
    if WITH_NOTE:
        emit_note_entry(a)

    emit_fields_entry(a)

    # ---------------- subroutines and constants
    emit_tail(a)
    return a


def emit_note_entry(a):
    a.label("F_NOTE")
    s = Stack(a, ["sel"])
    s.pop()
    emit_min_len(s, 352)
    for i in range(11):
        s.push(P - 1, "_pm")
        s.push(4 + 32 * i, "_o")
        s.op("CALLDATALOAD", 1, "_x")
        s.op("GT", 2, "_g" if i == 0 else "_g2")
        if i:
            s.op("OR", 2, "_g")
    s.a.pushlabel("E_NONCANON")
    s.op("JUMPI", 1)
    emit_consts(a)
    emit_note_body(s, "RET_NOTE", lambda s, i: calldata_limb(s, i), "N")
    a.label("RET_NOTE")
    s = Stack(a, ["r0", "r1", "r2", "r3"])
    emit_pack(s)
    emit_return_word(s)


def emit_fields_entry(a):
    # ---------------- hashFields(uint256[] limbs)
    a.label("F_FIELDS")
    s = Stack(a, [])
    emit_min_len(s, 32)
    s.push(4, "_4")
    s.op("CALLDATALOAD", 1, "off")
    s.push(MASK64, "_m")
    s.dup("off", "_o")
    s.op("GT", 2, "_b")
    s.a.pushlabel("REV")
    s.op("JUMPI", 1)
    s.push(4, "_4")
    s.op("ADD", 2, "o")
    s.op("CALLDATASIZE", 0, "_cs")
    s.push(0x1F, "_1f")
    s.dup("o", "_o")
    s.op("ADD", 2, "_e")
    s.op("SLT", 2, "_b")
    s.op("ISZERO", 1, "_b")
    s.a.pushlabel("REV")
    s.op("JUMPI", 1)
    s.dup("o", "_o")
    s.op("CALLDATALOAD", 1, "len")
    s.push(MASK64, "_m")
    s.dup("len", "_l")
    s.op("GT", 2, "_b")
    s.a.pushlabel("REV")
    s.op("JUMPI", 1)
    s.swap(1)
    s.push(32, "_32")
    s.op("ADD", 2, "pos")
    s.op("CALLDATASIZE", 0, "_cs")
    s.push(32, "_32")
    s.dup("len", "_l")
    s.op("MUL", 2, "_ml")
    s.dup("pos", "_p")
    s.op("ADD", 2, "_end")
    s.op("GT", 2, "_b")
    s.a.pushlabel("REV")
    s.op("JUMPI", 1)
    s.push(4, "_4")
    s.dup("len", "_l")
    s.op("EQ", 2, "_b")
    s.op("ISZERO", 1, "_b")
    s.a.pushlabel("E_SPONGE")
    s.op("JUMPI", 1)
    s.pushlabel("RET_FIELDS", "ret")
    for i in range(4):
        s.dup("pos", "_p")
        if i:
            s.push(32 * i, "_d")
            s.op("ADD", 2, "_p")
        s.op("CALLDATALOAD", 1, f"x{i}")
    emit_flag(s, [f"x{i}" for i in range(4)])
    s.a.pushlabel("E_NONCANON")
    s.op("JUMPI", 1)
    for i in range(4, 8):
        s.push(0, f"x{i}")
    emit_consts(a)
    emit_jump(s, "PERM31")
    a.label("RET_FIELDS")
    s = Stack(a, [f"acc{g}_r{ROUNDS - 2}" for g in range(3)])
    s.pop()
    emit_out4(s, ROUNDS - 2)
    emit_pack(s)
    emit_return_word(s)


def emit_tail(a):
    gen_perm31(a)
    gen_compress_r(a)
    a.items.append(("mark", "CONSTS", ""))
    a.data(CONST_BYTES, "packed M' columns: 3 groups x 8 columns")
    a.items.append(("mark", "RUNTIME_END", ""))
    # the table can end inside a PUSH's immediate as far as jumpdest analysis goes; 32 STOP bytes
    # (initcode only) realign it so CTOR's JUMPDEST is valid
    a.data(b"\0" * 32, "jumpdest-analysis padding")

    # ---------------- constructor tail (only reachable from initcode)
    a.label("CTOR")
    a.op("CALLVALUE")
    a.pushlabel("REV")
    a.op("JUMPI")
    emit_consts(a)
    kc = next(k for k in spec["kats"] if k["op"] == "compress")
    kh = next(k for k in spec["kats"] if k["op"] == "hash")
    # compress KAT
    s = Stack(a, [])
    s.pushlabel("K1", "ret2")
    s.pushlabel("COMPRESS_R", "ret")
    for i, v in enumerate([int(x) for x in kc["left"]] + [int(x) for x in kc["right"]]):
        s.push(v, f"x{i}")
    emit_jump(s, "PERM31")
    a.label("K1")
    s = Stack(a, ["r0", "r1", "r2", "r3"])
    emit_kat_check(s, pack([int(x) for x in kc["digest"]]))
    # hash KAT
    s.pushlabel("K2", "ret")
    for i, v in enumerate([int(x) for x in kh["input"]] + [0] * 4):
        s.push(v, f"x{i}")
    emit_jump(s, "PERM31")
    a.label("K2")
    s = Stack(a, [f"acc{g}_r{ROUNDS - 2}" for g in range(3)])
    s.pop()
    emit_out4(s, ROUNDS - 2)
    emit_kat_check(s, pack([int(x) for x in kh["digest"]]))
    if WITH_NOTE:
        kn = next(k for k in spec["kats"] if k["op"] == "commit_note")
        lim = [int(x) for x in kn["limbs"]]
        emit_note_body(s, "K3", lambda s, i: s.push(lim[i], f"m{i}"), "K")
        a.label("K3")
        s = Stack(a, ["r0", "r1", "r2", "r3"])
        emit_kat_check(s, pack([int(x) for x in kn["digest"]]))
    # CODECOPY(dest 0, offset 0, size len) then RETURN(0, len): the runtime is the code prefix
    a.pushlabel("RUNTIME_END")
    a.push(0)
    a.push(0)
    a.op("CODECOPY")
    a.pushlabel("RUNTIME_END")
    a.push(0)
    a.op("RETURN")
    emit_revert_sel(a, "E_KAT", ERR_KAT)


def calldata_limb(s, i):
    s.push(4 + 32 * i, "_o")
    s.op("CALLDATALOAD", 1, f"m{i}")


def emit_note_body(s, ret_label, load, tag):
    """Three compressions. Labels for all three go down first; the second returns straight into
    PERM31 of the third, whose inputs d0..d3, e0..e3 are then exactly on the stack."""
    s.pushlabel(ret_label, "ret2c")
    s.pushlabel("COMPRESS_R", "retc")
    s.pushlabel(f"{tag}_2", "ret2a")
    s.pushlabel("COMPRESS_R", "reta")
    for i in range(8):
        load(s, i)
    emit_jump(s, "PERM31")
    s.a.label(f"{tag}_2")
    s.st = s.st[:-(4 + 8)] + ["d0", "d1", "d2", "d3"]
    s.pushlabel("PERM31", "ret2b")
    s.pushlabel("COMPRESS_R", "retb")
    for i in range(8, 11):
        load(s, i)
    s.push(NOTE_DOMAIN, "m11")
    for i in range(12, 16):
        s.push(0, f"m{i}")
    emit_jump(s, "PERM31")


def emit_kat_check(s, want):
    emit_pack(s)
    s.push(want, "_w")
    s.op("EQ", 2, "_ok")
    s.op("ISZERO", 1, "_bad")
    s.a.pushlabel("E_KAT")
    s.op("JUMPI", 1)


def assemble_all():
    code, labels, lst = build().assemble()
    runtime = code[: labels["RUNTIME_END"]]
    assert labels["CTOR"] == len(runtime) + 32
    return code, runtime, labels, lst


if __name__ == "__main__":
    init, runtime, labels, lst = assemble_all()
    if "--print" in sys.argv:
        which = sys.argv[sys.argv.index("--print") + 1]
        sys.stdout.write("0x" + {"initcode": init, "runtime": runtime}[which].hex())
        sys.exit(0)
    if "--out" in sys.argv:
        OUT = sys.argv[sys.argv.index("--out") + 1]
    os.makedirs(OUT, exist_ok=True)
    open(os.path.join(OUT, "PoseidonGoldilocksFast.initcode.hex"), "w").write(init.hex())
    open(os.path.join(OUT, "PoseidonGoldilocksFast.runtime.hex"), "w").write(runtime.hex())
    open(os.path.join(OUT, "PoseidonGoldilocksFast.lst"), "w").write("\n".join(lst) + "\n")
    print(f"runtime {len(runtime)} bytes (EIP-170 limit 24576), initcode {len(init)} bytes")
