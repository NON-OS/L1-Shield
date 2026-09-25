#!/usr/bin/env bash
# Custom errors that no revert or selector reaches, and role constants that nothing gates on.
# Either one reads as a guarantee the code does not give. Exit 1 if any are found, 2 on an empty scan.
set -euo pipefail
cd "$(dirname "$0")/../../.."

python3 - <<'PY'
import re, os, sys, collections

decl = collections.defaultdict(list)
used = set()

scanned = 0

def scan(tree, collect_decls):
    global scanned
    for root, _, files in os.walk(tree):
        for f in files:
            if not f.endswith('.sol'):
                continue
            p = os.path.join(root, f)
            scanned += 1
            s = open(p).read()
            s = re.sub(r'//.*', '', s)
            s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
            if collect_decls:
                for m in re.finditer(r'\berror\s+(\w+)\s*\(', s):
                    decl[m.group(1)].append(p)
            # A qualified name, `revert Base.Err()`, reaches the error declared in Base.
            for m in re.finditer(r'revert\s+(?:\w+\.)*(\w+)\s*\(', s):
                used.add(m.group(1))
            for m in re.finditer(r'(\w+)\.selector', s):
                used.add(m.group(1))

scan('contracts', True)
scan('test', False)
scan('script', False)

dead = sorted(n for n in decl if n not in used)
for n in dead:
    print("UNENFORCED ERROR  %-28s %s" % (n, decl[n][0]))

# A role constant that nothing gates on reads as a restriction that does not exist.
roles = collections.defaultdict(list)
gated = set()
for root, _, files in os.walk('contracts'):
    for f in files:
        if not f.endswith('.sol'):
            continue
        p = os.path.join(root, f)
        src = re.sub(r'/\*.*?\*/', '', re.sub(r'//.*', '', open(p).read()), flags=re.S)
        for m in re.finditer(r'bytes32\s+(?:public|internal|private)?\s*constant\s+(\w*ROLE\w*|\w*CALLER\w*)\s*=', src):
            if m.group(1) != 'DEFAULT_ADMIN_ROLE':
                roles[m.group(1)].append(p)
        for m in re.finditer(r'(?:onlyRole|hasRole|_checkRole|checkRole)\s*\(\s*(\w+)', src):
            gated.add(m.group(1))

ungated = sorted(r for r in roles if r not in gated)
for r in ungated:
    print("UNGATED ROLE      %-28s %s" % (r, roles[r][0]))


# A walk over no files finds nothing, so an empty scan is refused and never reported as a pass.
if scanned < 10:
    sys.stderr.write(f"declared-but-unenforced: only {scanned} solidity files scanned. "
                     "Refusing to report a pass over nothing\n")
    sys.exit(2)
print(f"scanned {scanned} solidity files")

print("\n%d errors declared, %d unenforced" % (len(decl), len(dead)))
print("%d roles declared, %d gate nothing" % (len(roles), len(ungated)))
dead = dead + ungated
if dead:
    print("\nEach is either dead code to delete, or a guard that was intended and never written.")
    print("Decide which. Do not leave it declared.")
sys.exit(1 if dead else 0)
PY
