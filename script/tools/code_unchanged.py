#!/usr/bin/env python3
"""Prove a comment pass changed no code.

Strips every comment from two versions of each Solidity file, respecting string literals, and
compares what is left token for token. Whitespace and spacing around punctuation are normalised.
Any other change to code fails.

    code_unchanged.py <before-dir> <after-dir>     exit 0 only if every file matches
"""
import pathlib
import re
import sys


def strip(src: str) -> str:
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c in "\"'":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            out.append(src[i:j + 1])
            i = j + 1
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
            out.append(" ")
        else:
            out.append(c)
            i += 1
    code = re.sub(r"\s+", " ", "".join(out)).strip()
    # Removing a comment often moves spacing around punctuation, which carries no meaning.
    return re.sub(r" ?([()\[\]{},;=+\-*/%<>!&|^~?:.]) ?", r"\1", code)


def main():
    a, b = map(pathlib.Path, sys.argv[1:3])
    bad = 0
    files = sorted(p.relative_to(a) for p in a.rglob("*.sol"))
    for rel in files:
        pb = b / rel
        if not pb.exists():
            print(f"MISSING  {rel}")
            bad += 1
            continue
        if strip((a / rel).read_text()) != strip(pb.read_text()):
            print(f"CODE CHANGED  {rel}")
            bad += 1
    extra = sorted(p.relative_to(b) for p in b.rglob("*.sol") if not (a / p.relative_to(b)).exists())
    for rel in extra:
        print(f"NEW FILE  {rel}")
        bad += 1
    print(f"{len(files)} files, {bad} problems")
    sys.exit(1 if bad else 0)


main()
