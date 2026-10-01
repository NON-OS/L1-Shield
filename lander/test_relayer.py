#!/usr/bin/env python3
# Offline tests of the lander. It loads relayer.py serving a format 7 pool, with the wallet
# lookup and every chain call stubbed, so nothing touches a key or the network. The pool's amount
# policy is modelled on the rehearsal deployment: ETH ranged 10^15..10^19 wei, flat fee = the pinned
# transfer's fee.
import base64, importlib.util, json, os, subprocess, sys, types

SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "relayer.py")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = os.path.join(ROOT, "spec", "shapes")
SHAPES_POOL = "0xd0dbce195c082da39a218c62c01a732ce5b4d541"
PROOFS = {"transfer-eth-shape1": "A", "transfer-eth-shape2": "Ap", "transfer-eth-shape3": "B"}


def pinned(name):
    proof = open(f"{SPEC}/{name}/proof.bin", "rb").read()
    limbs = json.load(open(f"{SPEC}/{name}/publics.json"))["publics"]
    return proof, limbs


_, L0 = pinned("transfer-eth-shape1")
PAYEE = "0x%040x" % sum(v << (48 * i) for i, v in enumerate(L0[32:36]))
FLAT = L0[25]


def standard(units):
    if units == 0:
        return True
    for k in range(15, 20):
        if units in (10**k, 2 * 10**k, 5 * 10**k):
            return True
    return False


def fake_cast(*args):
    if args[:3] == ("call", "0xpolicy", "check(uint64,uint256,uint256)"):
        asset, amount, fee = (int(a) for a in args[3:6])
        if asset != 0:
            raise RuntimeError("execution reverted: NotRanged()")
        if not standard(amount):
            raise RuntimeError("execution reverted: NonStandardAmount()")
        if fee not in (0, FLAT):
            raise RuntimeError("execution reverted: FeeNotFlat()")
        return ""
    raise AssertionError(f"unexpected chain call {args}")


def load(env):
    real = subprocess.run
    os.environ.update({"RELAY_POOL": SHAPES_POOL, "RELAY_OFFLINE": "1", **env})
    subprocess.run = lambda *a, **k: types.SimpleNamespace(stdout=PAYEE + "\n", stderr="", returncode=0)
    try:
        spec = importlib.util.spec_from_file_location("lander_under_test", SRC)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
    finally:
        subprocess.run = real
        for k in ("RELAY_POOL", "RELAY_OFFLINE", *env):
            os.environ.pop(k, None)
    m.cast = fake_cast
    m.POLICY = "0xpolicy"
    return m


def body(proof, limbs, rank=None):
    d = {"proof": base64.b64encode(proof).decode(), "publics": limbs,
         "blob0": base64.b64encode(bytes(1186)).decode(), "blob1": base64.b64encode(bytes(1186)).decode()}
    if rank is not None:
        d["rank"] = rank
    return json.dumps(d).encode()


fails = 0


def ok(name, cond):
    global fails
    fails += not cond
    print(("PASS " if cond else "FAIL ") + name)


def refused(m, b, want):
    try:
        m.check(b)
        return False
    except (ValueError, m.RankError) as e:
        return want in str(e)


m = load({})
ok("serves the 12-word pool, with its own job directory", not m.NOT_BEFORE and m.POOL.lower() == SHAPES_POOL and m.JOBS.endswith("jobs"))
ok("settles through the format 7 script", m.SETTLE_SCRIPT == "script/SettleHandoff.s.sol")

for name, shape in PROOFS.items():
    p, L = pinned(name)
    jid, files = m.check(body(p, L))
    ok(f"accepted: {name} as shape {shape} ({len(p):,} bytes)", len(jid) == 64 and m.format7_shape(p)[0] == shape)

# The pool calls AmountPolicy.check on a withdrawal too, so its fee must be the flat fee. The pinned
# withdrawal pays 0.5% of its amount, which the pool refuses, and so does the relayer, before any gas.
pw, Lw = pinned("withdraw-capped-shape1")
ok("refused: a withdrawal whose fee is not the flat fee", refused(m, body(pw, Lw), "flat fee"))
L2 = list(Lw); L2[25] = FLAT
ok("accepted: a withdrawal at the flat fee, as shape A", len(m.check(body(pw, L2))[0]) == 64 and m.format7_shape(pw)[0] == "A")

p, L = pinned("transfer-eth-shape1")
bad = bytearray(p); bad[10] ^= 1
ok("refused: an unknown parameter id", refused(m, body(bytes(bad), L), "not one of the pool's three shapes"))
bad = bytearray(p); bad[4] = 5
ok("refused: a format 5 package", refused(m, body(bytes(bad), L), "not a format 7 package"))
ok("refused: shape A too long", refused(m, body(p + bytes(20_000), L), "shape A package"))
ok("refused: shape A too short", refused(m, body(p[:60_000], L), "shape A package"))
ok("refused: not a package", refused(m, body(b"XXXX" + p[4:], L), "not a NOXP package"))
launch = b"NOXP" + bytes(112_956 - 4)
ok("refused: a launch-size package", refused(m, body(launch, L), "format 7"))

L2 = list(L); L2[25] = FLAT + 1
ok("refused: a fee other than the flat fee", refused(m, body(p, L2), "flat fee"))
L2 = list(L); L2[25] = 0
ok("refused: a zero fee", refused(m, body(p, L2), "the fee is zero"))
pw, Lw = pinned("withdraw-capped-shape1")
L2 = list(Lw); L2[24] = 3 * 10**15
ok("refused: a non-standard withdrawal amount", refused(m, body(pw, L2), "not a standard amount"))
L2 = list(L); L2[26] = 1
ok("refused: an asset the pool does not range", refused(m, body(p, L2), "does not take this asset"))
L2 = list(L); L2[32:36] = [7, 0, 0, 0]
ok("refused: a fee paid to someone else", refused(m, body(p, L2), "another address"))
L2 = list(L); L2[32:36] = [1, 0, 0, 0]
ok("accepted: a fee to whoever submits, address(1)", len(m.check(body(p, L2))[0]) == 64)
ok("refused: 36 limbs required", refused(m, body(p, L[:35]), "36 limbs"))

rk = load({"RELAY_REQUIRE_RANK": "1"})
p3, L3 = pinned("transfer-eth-shape3")
ok("rank on: shape A with its bound 1006 accepted", len(rk.check(body(p, L, {"bound": 1006, "certified": 1006}))[0]) == 64)
ok("rank on: shape B with its bound 954 accepted", len(rk.check(body(p3, L3, {"bound": 954, "certified": 954}))[0]) == 64)
ok("rank on: shape A with the launch bound refused", refused(rk, body(p, L, {"bound": 1328, "certified": 1328}), "requires 1006"))
ok("rank on: short certificate refused", refused(rk, body(p, L, {"bound": 1006, "certified": 1005}), "short"))
ok("rank on: missing certificate refused", refused(rk, body(p, L), "no rank certificate"))

# -- the 13-word pool: 13 words, 37 limbs, the not-before time and the fee schedule ------------------
NOT_BEFORE_SPEC = os.path.join(ROOT, "spec", "not-before")
PROTO, LADDER, WBPS = 5 * 10**14, (25 * 10**14, 5 * 10**15, 10**16, 2 * 10**16), 50


def not_before_cast(*args):
    if args[:3] == ("call", "0xpolicy", "settlementFee(uint64,uint256,uint256,bool)(uint256,uint256)"):
        asset, amount, fee = (int(a) for a in args[3:6])
        if asset != 0:
            raise RuntimeError("execution reverted: NotRanged()")
        if not standard(amount):
            raise RuntimeError("execution reverted: NonStandardAmount()")
        proto = PROTO if amount == 0 else amount * WBPS // 10_000
        if fee < proto:
            raise RuntimeError("execution reverted: FeeBelowProtocolPart()")
        if fee - proto not in LADDER:
            raise RuntimeError("execution reverted: FeeNotOnLadder()")
        return f"{proto}\n{fee - proto}"
    raise AssertionError(f"unexpected chain call {args}")


def pinned_not_before(name):
    proof = open(f"{NOT_BEFORE_SPEC}/{name}/proof.bin", "rb").read()
    limbs = json.load(open(f"{NOT_BEFORE_SPEC}/{name}/publics.json"))["publics"]
    return proof, limbs


nx = load({"RELAY_WORDS": "13"})
nx.cast = not_before_cast
ok("13 words: 37 limbs and the not-before grid", nx.NOT_BEFORE and nx.LIMBS == 37)
for name, shape in (("transfer-eth-shape1", "A"), ("transfer-eth-shape2", "Ap"), ("transfer-eth-shape3", "B")):
    p, L = pinned_not_before(name)
    L = list(L); L[25] = PROTO + LADDER[0]; L[32:36] = [1, 0, 0, 0]
    ok(f"13 words, accepted: {name} as shape {shape}, fee on the ladder", len(nx.check(body(p, L))[0]) == 64 and nx.format7_shape(p)[0] == shape)
p, L = pinned_not_before("transfer-eth-shape1")
L = list(L); L[25] = PROTO + LADDER[0]; L[32:36] = [1, 0, 0, 0]
S = list(L); S[0] ^= 1
ok("13 words: a resent proof with a changed limb gets its own id, so it cannot shadow the real one",
   nx.check(body(p, L))[0] != nx.check(body(p, S))[0])
p, L = pinned_not_before("transfer-eth-shape1")
L = list(L); L[32:36] = [1, 0, 0, 0]
ok("13 words, refused: the old flat fee", refused(nx, body(p, L), "one rung of the gas ladder"))
L2 = list(L); L2[25] = PROTO + LADDER[0]; L2[36] = L2[36] + 1
ok("13 words, refused: a not-before time off the grid", refused(nx, body(p, L2), "600-second grid"))
L2 = list(L); L2[25] = PROTO + LADDER[0]; L2[36] = 0
ok("13 words, refused: a zero not-before time", refused(nx, body(p, L2), "600-second grid"))
ok("13 words, refused: a 36-limb statement", refused(nx, body(p, L[:36]), "37 limbs"))
p36, L36 = pinned("transfer-eth-shape1")
ok("13 words, refused: a proof of the 12-word circuit", refused(nx, body(p36, list(L36) + [1790812800]), "not one of the pool's three shapes"))
pw, Lw = pinned_not_before("withdraw-live-shape1")
Lw = list(Lw); Lw[25] = Lw[24] * WBPS // 10_000 + LADDER[0]; Lw[32:36] = [1, 0, 0, 0]
ok("13 words, accepted: a withdrawal paying 0.50% and a rung", len(nx.check(body(pw, Lw))[0]) == 64)

# -- the 13-word pool: settle waits for the chain's clock, and NotYet requeues ----------------------
import tempfile
tmp = tempfile.mkdtemp()
nx.JOBS = tmp
nx.jobs.clear()
p, L = pinned_not_before("transfer-eth-shape1")
L = list(L); L[25] = PROTO + LADDER[0]; L[32:36] = [1, 0, 0, 0]
jid, files = nx.check(body(p, L))
os.makedirs(f"{tmp}/{jid}")
for n, dta in files.items():
    open(f"{tmp}/{jid}/{n}", "wb").write(dta)
nx.jobs[jid] = {}
state = {"chain": L[36] - 5, "forge": "Error: script failed: custom error NotYet(1790000400)"}


def settle_cast(*args):
    if args[:2] == ("call", nx.POOL) and "nullifierSpent" in args[2]:
        return "false"
    if args[:2] == ("call", nx.POOL) and "isKnownRoot" in args[2]:
        return "true"
    if args[:2] == ("block", "latest"):
        return str(state["chain"])
    raise AssertionError(f"unexpected chain call {args}")


nx.cast = settle_cast
real_run = nx.subprocess.run
nx.subprocess.run = lambda *a, **k: types.SimpleNamespace(stdout=state["forge"], stderr="", returncode=1)
os.makedirs(f"{tmp}/kit/input", exist_ok=True)
nx.KIT = f"{tmp}/kit"
before = nx.work.qsize()
nx.settle(jid)
ok("13 words: a job waits while the chain's clock is before not-before", nx.jobs[jid]["status"] == "scheduled" and nx.work.qsize() == before + 1)
state["chain"] = L[36] + 1
nx.settle(jid)
ok("13 words: NotYet at the boundary requeues instead of refusing", nx.jobs[jid]["status"] == "scheduled" and nx.work.qsize() == before + 2)
state["forge"] = "Error: script failed: custom error FeeNotOnLadder(1)"
nx.settle(jid)
ok("13 words: any other failure still refuses", nx.jobs[jid]["status"] == "refused")
nx.subprocess.run = real_run
ok("13 words: a job is due 30 s after its not-before time", nx.not_before_of(jid) == L[36] + 30)

print("all passed" if not fails else f"{fails} failed")
sys.exit(1 if fails else 0)
