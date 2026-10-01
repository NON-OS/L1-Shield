#!/usr/bin/env python3
"""A tiny interpreter for the opcodes gen.py emits, for local checks before the server run.
Gas is the Paris static cost plus memory expansion and copy cost (no call overhead)."""
import random
import sys

import gen

U = (1 << 256) - 1
STATIC = {0x01: 3, 0x02: 5, 0x03: 3, 0x06: 5, 0x09: 8, 0x10: 3, 0x11: 3, 0x12: 3, 0x14: 3, 0x15: 3,
          0x16: 3, 0x17: 3, 0x1B: 3, 0x1C: 3, 0x34: 2, 0x35: 3, 0x36: 2, 0x38: 2, 0x39: 3, 0x50: 2,
          0x51: 3, 0x52: 3, 0x56: 8, 0x57: 10, 0x5B: 1, 0xF3: 0, 0xFD: 0}


def s256(x):
    return x - (1 << 256) if x >> 255 else x


def run(code, calldata=b"", value=0):
    jd = set()
    i = 0
    while i < len(code):
        op = code[i]
        if op == 0x5B:
            jd.add(i)
        i += 1 + (op - 0x5F if 0x60 <= op <= 0x7F else 0)
    st, mem, pc, gas, words = [], bytearray(), 0, 0, 0

    def expand(end):
        nonlocal gas, words
        w = (end + 31) // 32
        if w > words:
            gas += (3 * w + w * w // 512) - (3 * words + words * words // 512)
            words = w
            mem.extend(b"\0" * (w * 32 - len(mem)))

    def cdl(o):
        return int.from_bytes((calldata[o:o + 32] if o < len(calldata) else b"").ljust(32, b"\0"), "big")

    while True:
        op = code[pc]
        if 0x60 <= op <= 0x7F:
            n = op - 0x5F
            st.append(int.from_bytes(code[pc + 1:pc + 1 + n], "big"))
            gas += 3
            pc += 1 + n
            continue
        if 0x80 <= op <= 0x8F:
            st.append(st[-(op - 0x7F)])
            gas += 3
        elif 0x90 <= op <= 0x9F:
            n = op - 0x8F
            st[-1], st[-1 - n] = st[-1 - n], st[-1]
            gas += 3
        else:
            gas += STATIC[op]
            if op == 0x01:
                st.append((st.pop() + st.pop()) & U)
            elif op == 0x02:
                st.append((st.pop() * st.pop()) & U)
            elif op == 0x03:
                a, b = st.pop(), st.pop()
                st.append((a - b) & U)
            elif op == 0x06:
                a, b = st.pop(), st.pop()
                st.append(a % b if b else 0)
            elif op == 0x09:
                a, b, n = st.pop(), st.pop(), st.pop()
                st.append(a * b % n if n else 0)
            elif op == 0x10:
                a, b = st.pop(), st.pop()
                st.append(int(a < b))
            elif op == 0x11:
                a, b = st.pop(), st.pop()
                st.append(int(a > b))
            elif op == 0x12:
                a, b = st.pop(), st.pop()
                st.append(int(s256(a) < s256(b)))
            elif op == 0x14:
                st.append(int(st.pop() == st.pop()))
            elif op == 0x15:
                st.append(int(st.pop() == 0))
            elif op == 0x16:
                st.append(st.pop() & st.pop())
            elif op == 0x17:
                st.append(st.pop() | st.pop())
            elif op == 0x1B:
                sh, v = st.pop(), st.pop()
                st.append((v << sh) & U if sh < 256 else 0)
            elif op == 0x1C:
                sh, v = st.pop(), st.pop()
                st.append(v >> sh if sh < 256 else 0)
            elif op == 0x34:
                st.append(value)
            elif op == 0x35:
                st.append(cdl(st.pop()))
            elif op == 0x36:
                st.append(len(calldata))
            elif op == 0x38:
                st.append(len(code))
            elif op == 0x39:
                d, o, n = st.pop(), st.pop(), st.pop()
                expand(d + n)
                gas += 3 * ((n + 31) // 32)
                mem[d:d + n] = code[o:o + n].ljust(n, b"\0")
            elif op == 0x50:
                st.pop()
            elif op == 0x51:
                o = st.pop()
                expand(o + 32)
                st.append(int.from_bytes(mem[o:o + 32], "big"))
            elif op == 0x52:
                o, v = st.pop(), st.pop()
                expand(o + 32)
                mem[o:o + 32] = v.to_bytes(32, "big")
            elif op == 0x56:
                pc = st.pop()
                assert pc in jd
                continue
            elif op == 0x57:
                d, c = st.pop(), st.pop()
                if c:
                    assert d in jd, d
                    pc = d
                    continue
            elif op in (0xF3, 0xFD):
                o, n = st.pop(), st.pop()
                if n:
                    expand(o + n)
                return op == 0xF3, bytes(mem[o:o + n]), gas, len(st)
        assert len(st) <= 1024
        pc += 1


def enc_hash2(a, b):
    return bytes.fromhex("b30c0b6a") + a.to_bytes(32, "big") + b.to_bytes(32, "big")


def enc_note(m):
    return bytes.fromhex("77fc0203") + b"".join(x.to_bytes(32, "big") for x in m)


def enc_fields(x):
    return bytes.fromhex("a9f139e7") + (32).to_bytes(32, "big") + len(x).to_bytes(32, "big") + b"".join(
        v.to_bytes(32, "big") for v in x)


if __name__ == "__main__":
    init, runtime, _, _ = gen.assemble_all()
    ok, out, g, _ = run(init)
    assert ok and out == runtime, "constructor"
    print("constructor ok, gas (execution only)", g)
    P = gen.P
    rng = random.Random(7)
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 50
    gh = []
    for _ in range(n):
        a = [rng.randrange(P) for _ in range(4)]
        b = [rng.randrange(P) for _ in range(4)]
        ok, out, g, _ = run(runtime, enc_hash2(gen.pack(a), gen.pack(b)))
        assert ok and int.from_bytes(out, "big") == gen.pack(gen.ref_compress(a, b))
        gh.append(g)
        m = [rng.randrange(P) for _ in range(11)]
        ok, out, gn, _ = run(runtime, enc_note(m))
        assert ok and int.from_bytes(out, "big") == gen.pack(gen.ref_note(m))
        ok, out, gf, _ = run(runtime, enc_fields(a))
        assert ok and int.from_bytes(out, "big") == gen.pack(gen.ref_hash4(a))
    print("agree", n, "x3; hash2 exec gas", gh[0], "commitNote", gn, "hashFields", gf)
    bad = gen.pack([1, 2, P, 4])
    print("noncanon hash2", run(runtime, enc_hash2(bad, 0))[:2])
    print("noncanon note", run(runtime, enc_note([0] * 10 + [P]))[:2])
    print("fields len 3", run(runtime, enc_fields([1, 2, 3]))[:2])
    print("fields noncanon", run(runtime, enc_fields([1, 2, 3, 2**64 - 1]))[:2])
    print("short", run(runtime, b"\xb3\x0c")[:2], "value", run(runtime, enc_hash2(0, 0), 1)[:2])
