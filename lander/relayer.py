#!/usr/bin/env python3
# NOX Shield lander. Takes proofs, from wallets over a Tor onion service or from the open proof topic
# through settlement/bridge.mjs, checks each one before it spends any gas, settles it from its own key,
# and commits a root on a fixed clock. Proofs pay whoever lands them. The key holds gas money only.
# Nothing about a sender is logged.
#
#   GET  /v1/info             relayer address, pool, flat fees, current root, leaves, queue length
#   GET  /v1/status           health: gas balance, credits, root, leaves, queue, last settlement,
#                             uptime, features on or off (wei amounts are decimal strings)
#   POST /v1/handoff          {"proof": b64, "publics": [36 or 37 limbs], "blob0": b64, "blob1": b64, "rank": {...}}
#   GET  /v1/handoff/<id>     {"status": queued | scheduled | settling | settled | refused, "tx", "reason"}
#
# Configuration, from the environment (systemd drop-in):
#   RELAY_POOL             the pool it serves. Required: a format 7 pool. A pool whose wordsPerIntent is 13
#                          takes 37-limb statements with a not-before time, one of 12 takes 36 limbs.
#   RELAY_ROOT_BOUNTY      commit roots through this bounty; unset, straight on the pool
#   RELAY_ROOT_EVERY_S     the root clock: at most one commit per slot of this many seconds (1800)
#   RELAY_ROOT_STANDBY_S   commit only this many seconds into a slot, if no one has yet (0)
#   RELAY_DELAY_MEAN_S     > 0: each hand-off settles at now + min(Exp(mean), RELAY_DELAY_CAP_S)
#   RELAY_DELAY_CAP_S      the cap on that delay (3600)
#   RELAY_REQUIRE_RANK     = 1: a hand-off must carry a full rank certificate for its shape
#   RELAY_SEND_RPC         where settlements are broadcast; a private RPC keeps the gas rung yours
#   RELAY_HOME            state, keystore and password; default below
#   RELAY_KIT             the forge project that holds script/SettleHandoff.s.sol: this lander/ directory
#   RELAY_OFFLINE          = 1: read nothing from the chain at start (tests only)
import base64, hashlib, heapq, json, os, random, re, shutil, subprocess, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# The launch pool takes format 5 proofs and no deposits; its withdrawals settle through its own tools.
LAUNCH_POOL = "0x8e377752c8890e23a1e9f40ebbd41183fc6949e2"

POOL = os.environ["RELAY_POOL"]
if POOL.lower() == LAUNCH_POOL:
    raise SystemExit("this lander settles format 7 pools; the launch pool is not one")
HOME = os.environ.get("RELAY_HOME", "/var/lib/nox-relayer")
KIT = os.environ.get("RELAY_KIT", os.path.dirname(os.path.abspath(__file__)))
JOBS = f"{HOME}/jobs"
KEYSTORE = f"{HOME}/keystore/nox-relayer"
PASSWORD = f"{HOME}/password"
BOUNTY = os.environ.get("RELAY_ROOT_BOUNTY", "")
OFFLINE = os.environ.get("RELAY_OFFLINE", "0") == "1"
CHAIN_ID = 11155111
RPCS = ["https://ethereum-sepolia-rpc.publicnode.com", "https://sepolia.gateway.tenderly.co"]
P = 2**64 - 2**32 + 1                     # Goldilocks: every public limb is below it
BLOB_BYTES = 1186
MAX_BODY = 256 * 1024
MAX_QUEUE = 64
ROOT_EVERY = int(os.environ.get("RELAY_ROOT_EVERY_S", "1800"))
# A standby lander waits this many seconds into each root slot, so it commits only if the landers
# ahead of it did not: several landers, staggered, never race each other's commitRoot.
ROOT_STANDBY = int(os.environ.get("RELAY_ROOT_STANDBY_S", "0"))
if not 0 <= ROOT_STANDBY < ROOT_EVERY:
    raise SystemExit(f"RELAY_ROOT_STANDBY_S must be below the root slot ({ROOT_EVERY} s): a standby at or past it never commits")
CAST, FORGE = "/usr/local/bin/cast", "/usr/local/bin/forge"
NOX_ASSET = 1
SUBMITTER = 1                             # the pool's address(1): the fee goes to whoever submits
# Where settlements are sent. A public mempool lets anyone copy the transaction and take the gas
# rung (the proof pays msg.sender); a private RPC such as https://rpc-sepolia.flashbots.net keeps it.
SEND_RPC = os.environ.get("RELAY_SEND_RPC", RPCS[0])
DELAY_MEAN = float(os.environ.get("RELAY_DELAY_MEAN_S", "0"))
DELAY_CAP = float(os.environ.get("RELAY_DELAY_CAP_S", "3600"))
REQUIRE_RANK = os.environ.get("RELAY_REQUIRE_RANK", "0") == "1"
STARTED = time.time()
draw = random.SystemRandom()

# Format 7 packages, 40-byte header (NOXP, u16 format, u16 protocol, parameter id).
# Each shape is named by its parameter id; the size window holds every pinned and settled proof of
# that shape with room for the spread of shared Merkle paths. Rank bounds are the pinned proofs'.
SHAPES_36 = {
    bytes.fromhex("add18dbb2dba8c5426d79bca1187f6c5221a5e86108cc49ce0909d958bb5a80a"): ("A", 19, 88_000, 100_000, 1006),
    bytes.fromhex("7ad145c3e095bb83fb9841d0ccf3556a3349d1cf551328166770725c88f5ae44"): ("Ap", 18, 85_000, 97_000, 980),
    bytes.fromhex("94ef16ef21b538d3e4fa340ddfea9a1ddc9afbb80c725374eaa739902e37079b"): ("B", 17, 80_000, 93_000, 954),
}
# The not-before circuit (37 limbs): same shapes, new parameter ids, same rank bounds.
SHAPES_37 = {
    bytes.fromhex("ccba76ed5748b5ee54dfd62935fd1d10998b5c0f84e35a9dc899905cfb1eadb5"): ("A", 19, 88_000, 100_000, 1006),
    bytes.fromhex("9a15f4ba74bab7fb97df9245b02c80a1f6a2aff41471c3d26483a6248f8b7acf"): ("Ap", 18, 85_000, 97_000, 980),
    bytes.fromhex("4ef4256faa865857cce2cf3ea7c54cd4617dfc9dbb3d158393da9f02446a3350"): ("B", 17, 80_000, 93_000, 954),
}
NOT_BEFORE_GRID = 600
SETTLE_SCRIPT = "script/SettleHandoff.s.sol"


class Schedule:
    """The settlement queue. Jobs leave by due time, ties in arrival order, so with every due time
    zero it is first in first out."""

    def __init__(self):
        self.heap, self.seq, self.cv = [], 0, threading.Condition()

    def put(self, jid, due=0.0):
        with self.cv:
            heapq.heappush(self.heap, (due, self.seq, jid))
            self.seq += 1
            self.cv.notify()

    def get(self):
        with self.cv:
            while True:
                wait = self.heap[0][0] - time.time() if self.heap else None
                if wait is not None and wait <= 0:
                    return heapq.heappop(self.heap)[2]
                self.cv.wait(wait)

    def qsize(self):
        with self.cv:
            return len(self.heap)


def settle_at(now):
    """When a newly accepted hand-off settles: now, or with the delay on, a random time after it."""
    if DELAY_MEAN <= 0:
        return 0.0
    return now + min(draw.expovariate(1 / DELAY_MEAN), DELAY_CAP)


CHAIN_LAG_S = 30  # the chain's latest block trails the wall clock by up to a block or two
NOT_YET_RETRY_S = 15


def not_before_of(jid):
    """A 13-word job is due no earlier than its proof's not-before time plus CHAIN_LAG_S: the pool
    compares with the block's timestamp, which trails the wall clock."""
    if not NOT_BEFORE:
        return 0.0
    try:
        return float(json.load(open(f"{JOBS}/{jid}/spend.proof.publics.json"))["publics"][36]) + CHAIN_LAG_S
    except (OSError, ValueError, KeyError, IndexError):
        return 0.0


def chain_time():
    return int(cast("block", "latest", "--field", "timestamp").split()[0])


class RankError(ValueError):
    pass


def check_rank(d, bound_required):
    r = d.get("rank")
    if not isinstance(r, dict):
        raise RankError("the hand-off carries no rank certificate, and this relayer requires one")
    bound, certified = r.get("bound"), r.get("certified")
    if not all(type(v) is int for v in (bound, certified)):
        raise RankError("the rank certificate needs integer bound and certified fields")
    if certified != bound:
        raise RankError(f"the rank certificate is short: certified {certified}, bound {bound}")
    if bound != bound_required:
        raise RankError(f"the rank bound is {bound}, and this shape requires {bound_required}")


chain = threading.Lock()                  # one writer: settlements and roots never race on the nonce
jobs, work = {}, Schedule()
last_slot = -1
last_settled = {}


def log(msg):
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), msg, flush=True)


def cast(*args):
    last = ""
    for rpc in RPCS:
        r = subprocess.run([CAST, *args, "--rpc-url", rpc], capture_output=True, text=True, timeout=120)
        if r.returncode == 0:
            return r.stdout.strip()
        last = r.stderr.strip()
    raise RuntimeError(last[-300:])


RELAYER = subprocess.run([CAST, "wallet", "address", "--keystore", KEYSTORE, "--password-file", PASSWORD],
                         capture_output=True, text=True, check=True).stdout.strip()
POLICY = ASSOCIATION = None
WORDS = int(os.environ.get("RELAY_WORDS", "12"))
if not OFFLINE:
    POLICY = cast("call", POOL, "amountPolicy()(address)")
    ASSOCIATION = cast("call", POOL, "associationRegistry()(address)")
    WORDS = int(cast("call", POOL, "wordsPerIntent()(uint256)").split()[0])
NOT_BEFORE = WORDS == 13  # the not-before statement and the fee schedule
LIMBS = 37 if NOT_BEFORE else 36
SHAPES = SHAPES_37 if NOT_BEFORE else SHAPES_36


def word(limbs, bits):
    return "0x%064x" % sum(v << (bits * i) for i, v in enumerate(limbs))


def format7_shape(proof):
    """(shape, queries, low, high, rank bound) of a format 7 package, or ValueError."""
    if proof[:4] != b"NOXP":
        raise ValueError("the proof is not a NOXP package")
    if proof[4:6] != b"\x07\x00":
        raise ValueError("the proof is not a format 7 package")
    s = SHAPES.get(bytes(proof[8:40]))
    if s is None:
        raise ValueError("the parameter id is not one of the pool's three shapes")
    name, _, low, high, _ = s
    if not low <= len(proof) <= high:
        raise ValueError(f"a shape {name} package is {low:,} to {high:,} bytes, not {len(proof):,}")
    return s


def policy_check(asset, amount, fee):
    """The pool's own amount policy decides: standard amount, ranged asset, and the fee: the flat fee
    on the 12-word pool, the protocol part plus one ladder rung on the 13-word pool."""
    try:
        if NOT_BEFORE:
            cast("call", POLICY, "settlementFee(uint64,uint256,uint256,bool)(uint256,uint256)",
                 str(asset), str(amount), str(fee), "true")
        else:
            cast("call", POLICY, "check(uint64,uint256,uint256)", str(asset), str(amount), str(fee))
    except RuntimeError as e:
        m = str(e)
        if "FeeNotOnLadder" in m or "FeeBelowProtocolPart" in m:
            raise ValueError("the fee is not the protocol fee plus one rung of the gas ladder") from None
        if "NoSchedule" in m:
            raise ValueError("the pool has no fee schedule for this asset") from None
        if "NotRanged" in m:
            raise ValueError("the pool does not take this asset") from None
        if "NonStandardAmount" in m:
            raise ValueError("the public amount is not a standard amount") from None
        if "FeeNotFlat" in m:
            raise ValueError("the fee is not the pool's flat fee") from None
        raise ValueError("the pool's amount policy refuses this hand-off") from None


def save(jid):
    j = dict(jobs[jid])
    with open(f"{JOBS}/{jid}/status.json", "w") as f:
        json.dump(j, f)


def set_status(jid, status, **kw):
    jobs[jid].update(status=status, t=int(time.time()), **kw)
    save(jid)
    if status == "settled" and kw.get("tx"):
        last_settled.update(tx=kw["tx"], t=jobs[jid]["t"])
    log(f"handoff {jid[:12]} {status} {kw.get('tx', '')}{kw.get('reason', '')}")


def check(body):
    """Cheap checks, before anything is queued. Returns (id, files) or raises ValueError."""
    d = json.loads(body)
    proof, b0, b1 = (base64.b64decode(d[k], validate=True) for k in ("proof", "blob0", "blob1"))
    limbs = d["publics"]
    shape = format7_shape(proof)
    if len(b0) != BLOB_BYTES or len(b1) != BLOB_BYTES:
        raise ValueError("each sealed note is 1,186 bytes")
    if len(limbs) != LIMBS or not all(isinstance(v, int) and 0 <= v < P for v in limbs):
        raise ValueError(f"the statement is {LIMBS} limbs, each below p")
    if NOT_BEFORE:
        nb = limbs[36]
        if nb == 0 or nb % NOT_BEFORE_GRID:
            raise ValueError("the not-before time is not on the 600-second grid")
    if REQUIRE_RANK:
        check_rank(d, shape[4])
    payee = int(word(limbs[32:36], 48), 16)
    if payee != int(RELAYER, 16) and payee != SUBMITTER:
        raise ValueError(f"the proof pays its fee to another address, not to {RELAYER}")
    amount, fee, asset = limbs[24], limbs[25], limbs[26]
    if fee == 0:
        raise ValueError("the fee is zero")
    policy_check(asset, amount, fee)
    # The id covers everything settled, not the proof alone: on an open topic anyone can resend a proof
    # with a changed limb, and a proof-only id would let that copy shadow the real one.
    jid = hashlib.sha256(proof + json.dumps(limbs).encode() + b0 + b1).hexdigest()
    return jid, {"spend.proof": proof, "blob0.bin": b0, "blob1.bin": b1,
                 "spend.proof.publics.json": json.dumps({"publics": limbs}).encode()}


def settle(jid):
    d = f"{JOBS}/{jid}"
    limbs = json.load(open(f"{d}/spend.proof.publics.json"))["publics"]
    root, nf0, nf1 = word(limbs[0:4], 64), word(limbs[8:12], 64), word(limbs[12:16], 64)
    spent = [cast("call", POOL, "nullifierSpent(bytes32)(bool)", nf) == "true" for nf in (nf0, nf1)]
    if all(spent) and jobs[jid].get("status") == "settling":
        # sent before a restart and mined, but the hash was not recorded
        return set_status(jid, "settled", reason="settled before the relayer restarted")
    if any(spent):
        return set_status(jid, "refused", reason="a note it spends is already spent")
    if cast("call", POOL, "isKnownRoot(bytes32)(bool)", root) != "true":
        return set_status(jid, "refused", reason="the root is not one the pool knows")
    if NOT_BEFORE:
        # the pool checks not-before against the block's timestamp, so wait for the chain's clock
        nb = limbs[36]
        if chain_time() < nb:
            due = time.time() + NOT_YET_RETRY_S
            set_status(jid, "scheduled", due=due)
            return work.put(jid, due)
    run = f"{KIT}/input/{jid}"
    os.makedirs(run, exist_ok=True)
    for f in ("spend.proof", "spend.proof.publics.json", "blob0.bin", "blob1.bin"):
        shutil.copy(f"{d}/{f}", f"{run}/{f}")
    env = dict(os.environ, POOL=POOL, WORDS=str(WORDS), PUBLICS=f"{run}/spend.proof.publics.json",
               BLOB0=f"{run}/blob0.bin", BLOB1=f"{run}/blob1.bin")
    env.update(PKG=f"{run}/spend.proof", **{f"PARAM_{v[0].upper()}": "0x" + pid.hex() for pid, v in SHAPES.items()})
    set_status(jid, "settling")
    with chain:
        r = subprocess.run([FORGE, "script", SETTLE_SCRIPT, "--rpc-url", SEND_RPC, "--broadcast",
                            "--keystore", KEYSTORE, "--password-file", PASSWORD, "--sender", RELAYER,
                            "--slow", "--gas-estimate-multiplier", "120"],
                           cwd=KIT, env=env, capture_output=True, text=True, timeout=900)
    shutil.rmtree(run, ignore_errors=True)
    out = r.stdout + r.stderr
    if "ONCHAIN EXECUTION COMPLETE & SUCCESSFUL" not in out:
        if NOT_BEFORE and "NotYet" in out:
            # a clock race at the boundary: the proof is valid, so try again shortly rather than refuse
            due = time.time() + NOT_YET_RETRY_S
            set_status(jid, "scheduled", due=due)
            return work.put(jid, due)
        why = re.findall(r"(?:Error|revert)[^\n]{0,160}", out)
        return set_status(jid, "refused", reason=(why[0] if why else "the settlement did not go through"))
    name = os.path.basename(SETTLE_SCRIPT)
    tx = json.load(open(f"{KIT}/broadcast/{name}/{CHAIN_ID}/run-latest.json"))["receipts"][-1]["transactionHash"]
    set_status(jid, "settled", tx=tx)


def worker():
    while True:
        jid = work.get()
        try:
            settle(jid)
        except Exception as e:
            set_status(jid, "refused", reason=f"relayer error: {str(e)[:160]}")


def roots():
    """Commits a root at most once per clock slot, and only if deposits arrived since the last one.
    Roots follow the clock, never a deposit, so a root's time says nothing about who deposited."""
    global last_slot
    sign = ["--keystore", KEYSTORE, "--password-file", PASSWORD]
    while True:
        time.sleep(30)
        slot = int(time.time()) // ROOT_EVERY
        if slot == last_slot or int(time.time()) % ROOT_EVERY < ROOT_STANDBY:
            continue
        try:
            if cast("call", POOL, "commitRoot()(bytes32)") == cast("call", POOL, "currentRoot()(bytes32)"):
                last_slot = slot
                continue
            with chain:
                if BOUNTY:
                    cast("send", BOUNTY, "commit()", "--gas-limit", "6000000", *sign)
                else:
                    cast("send", POOL, "commitRoot()", "--gas-limit", "6000000", *sign)
                root = cast("call", POOL, "currentRoot()(bytes32)")
                registry = ASSOCIATION
                if cast("call", registry, "isRegisteredRoot(bytes32)(bool)", root) != "true":
                    cast("send", registry, "publishRoot(bytes32,string)", root, "pool root, relayer", *sign)
            last_slot = slot
            log(f"root {root} committed and published")
        except Exception as e:
            log(f"root commit failed: {str(e)[:160]}")


def flat_fees():
    """What a proof must pay, per asset, in note units. The 12-word pool: its flat fee. The 13-word pool:
    the protocol part of a private transfer, the withdrawal percentage, and the four gas rungs, from the
    schedule and percentages in force; a relayed proof pays the protocol part plus exactly one rung."""
    out = {}
    for i, a in ((0, "eth"), (1, "nox")):
        try:
            if NOT_BEFORE:
                (protocol, ladder, is_set), = json.loads(
                    cast("call", POLICY, "scheduleOf(uint64)((uint64,uint64[4],bool))", str(i), "--json"))
                if not is_set:
                    continue
                deposit_bps, withdraw_bps = json.loads(cast("call", POLICY, "bps()(uint16,uint16)", "--json"))
                out[a] = {"protocol_fee": int(protocol), "ladder": [int(x) for x in ladder],
                          "deposit_bps": int(deposit_bps), "withdraw_bps": int(withdraw_bps)}
            else:
                out[a] = int(cast("call", POLICY, "rules(uint64)(uint64,uint8,uint8,bool)", str(i)).split()[0])
        except (RuntimeError, ValueError, IndexError):
            pass
    return out


class Api(BaseHTTPRequestHandler):
    server_version = "nox-relayer"
    sys_version = ""

    def log_message(self, *a):          # no access log: the relayer keeps nothing about who asked
        pass

    def reply(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path == "/v1/info":
            try:
                return self.reply(200, {"relayer": RELAYER, "pool": POOL, "chain_id": CHAIN_ID,
                                        "fee_units": flat_fees(), "fee_to_submitter_accepted": True,
                                        "root": cast("call", POOL, "currentRoot()(bytes32)"),
                                        "leaves": int(cast("call", POOL, "nextLeafIndex()(uint40)").split()[0]),
                                        "queue": work.qsize()})
            except (RuntimeError, subprocess.TimeoutExpired):
                return self.reply(502, {"error": "the chain is not reachable right now"})
        if self.path == "/v1/status":
            try:
                chain_view = {"eth_balance_wei": cast("balance", RELAYER),
                              "claimable_nox_wei": cast("call", POOL, "claimable(uint64,address)(uint256)",
                                                        str(NOX_ASSET), RELAYER).split()[0],
                              "root": cast("call", POOL, "currentRoot()(bytes32)"),
                              "leaves": int(cast("call", POOL, "nextLeafIndex()(uint40)").split()[0])}
            except (RuntimeError, subprocess.TimeoutExpired):
                return self.reply(502, {"error": "the chain is not reachable right now"})
            return self.reply(200, {"relayer": RELAYER, "pool": POOL, "chain_id": CHAIN_ID, **chain_view,
                                    "queue": work.qsize(), "last_settlement": dict(last_settled) or None,
                                    "uptime_s": int(time.time() - STARTED),
                                    "features": {"delay": {"on": DELAY_MEAN > 0, "mean_s": DELAY_MEAN, "cap_s": DELAY_CAP},
                                                 "root_clock_s": ROOT_EVERY, "root_bounty": BOUNTY or None,
                                                 "root_standby_s": ROOT_STANDBY,
                                                 "private_send": SEND_RPC not in RPCS,
                                                 "send_host": SEND_RPC.split("/")[2] if "//" in SEND_RPC else SEND_RPC,
                                                 "require_rank": REQUIRE_RANK}})
        m = re.fullmatch(r"/v1/handoff/([0-9a-f]{64})", self.path)
        if m and m.group(1) in jobs:
            j = jobs[m.group(1)]
            return self.reply(200, {k: j[k] for k in ("status", "tx", "reason") if k in j})
        self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/v1/handoff":
            return self.reply(404, {"error": "not found"})
        n = int(self.headers.get("Content-Length", 0))
        if n <= 0 or n > MAX_BODY:
            return self.reply(413, {"error": "the body must be a hand-off of at most 256 KB"})
        try:
            jid, files = check(self.rfile.read(n))
        except RankError as e:
            return self.reply(422, {"error": str(e)})
        except (ValueError, KeyError, TypeError, json.JSONDecodeError, base64.binascii.Error) as e:
            return self.reply(400, {"error": str(e) or "malformed hand-off"})
        if jid in jobs:
            return self.reply(200, {"id": jid, "status": jobs[jid]["status"]})
        if work.qsize() >= MAX_QUEUE:
            return self.reply(503, {"error": "the queue is full, try again shortly"})
        os.makedirs(f"{JOBS}/{jid}", exist_ok=True)
        for name, data in files.items():
            with open(f"{JOBS}/{jid}/{name}", "wb") as f:
                f.write(data)
        jobs[jid] = {}
        due = max(settle_at(time.time()), not_before_of(jid))
        if due:
            set_status(jid, "scheduled", due=due)
        else:
            set_status(jid, "queued")
        work.put(jid, due)
        self.reply(202, {"id": jid, "status": jobs[jid]["status"]})


def restore():
    """After a restart: settled and refused jobs keep their answer; unfinished ones run again, and a
    job whose notes are already spent is not sent twice, because settle() checks the nullifiers."""
    os.makedirs(JOBS, exist_ok=True)
    for jid in sorted(os.listdir(JOBS)):
        try:
            jobs[jid] = json.load(open(f"{JOBS}/{jid}/status.json"))
        except (OSError, ValueError):
            continue
        if jobs[jid].get("status") in ("queued", "scheduled", "settling"):
            work.put(jid, jobs[jid].get("due", 0.0) if jobs[jid]["status"] == "scheduled" else 0.0)
        if jobs[jid].get("status") == "settled" and jobs[jid].get("tx") and jobs[jid]["t"] >= last_settled.get("t", 0):
            last_settled.update(tx=jobs[jid]["tx"], t=jobs[jid]["t"])


if __name__ == "__main__":
    restore()
    threading.Thread(target=worker, daemon=True).start()
    threading.Thread(target=roots, daemon=True).start()
    log(f"relayer {RELAYER} serving the pool {POOL}, roots every {ROOT_EVERY} s")
    ThreadingHTTPServer(("127.0.0.1", int(os.environ.get("RELAY_PORT", "8480"))), Api).serve_forever()
