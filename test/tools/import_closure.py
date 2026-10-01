#!/usr/bin/env python3
"""Print the import closure of a Solidity file as basenames on one line, space separated.

Reads the Solidity source, so it measures what a reader sees.
Used by test/shield/DeployedSurface.t.sol to pin what the deployed verifier reaches.
"""
import collections
import os
import re
import sys

ROOT = "contracts/shield"


def main(entry: str) -> None:
    edges = collections.defaultdict(set)
    known = {}
    for dirpath, _, files in os.walk(ROOT):
        for name in files:
            if not name.endswith(".sol"):
                continue
            path = os.path.join(dirpath, name)
            known[name] = path
            for target in re.findall(r'from\s*"([^"]+)"', open(path).read()):
                edges[name].add(os.path.basename(target))

    live, stack = set(), [os.path.basename(entry)]
    while stack:
        node = stack.pop()
        if node in live or node not in known:
            continue
        live.add(node)
        stack.extend(edges[node])
    print(" ".join(sorted(live)))


if __name__ == "__main__":
    main(sys.argv[1])
