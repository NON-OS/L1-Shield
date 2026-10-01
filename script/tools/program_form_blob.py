#!/usr/bin/env python3
"""Split a program blob into its transition part and its boundary part.

    program_form_blob.py <dir>/program.bin [--sol PATH] [--library NAME]

Writes <dir>/tape.bin, the transition part (header, exempt points, ops and outputs). The evaluator's
tape data contract holds it and is checked by hash. With --sol it also writes a Solidity library
with TAPE_HASH, TAPE_LENGTH, PROGRAM_HASH and the boundary part as BOUNDARIES.

For spec/program-form the library is contracts/shield/verifier/ProgramFormProgram.sol. For
spec/launch-program these four constants match LaunchProgram. N_CHALLENGES, IMAGE_HASH and
LaunchSlots in LaunchProgram.sol do not come from this tool.
"""
import argparse
import hashlib
import pathlib
import struct
import subprocess


def keccak(b):
    """keccak256 through foundry's `cast`, which every environment building this repo has."""
    out = subprocess.run(["cast", "keccak", "0x" + b.hex()], capture_output=True, text=True, check=True)
    return out.stdout.strip()[2:]


OP_LEN = {0: 17, 1: 3, 2: 5, 3: 5, 4: 5, 5: 3}


def split(blob):
    n_ops, n_out, n_bnd, n_rows, n_frame, n_per, log_t, n_ex = struct.unpack(">HHHHHHBB", blob[:14])
    p = 14 + 8 * n_ex
    for _ in range(n_ops):
        p += OP_LEN[blob[p]]
    p += 2 * n_out
    return p, (n_ops, n_out, n_bnd, n_rows, n_frame, n_per, log_t, n_ex)


def pins(bnd, n_bnd, n_rows):
    """Indices of the boundaries that read a public word (source byte 1)."""
    p, out = 8 * n_rows, []
    for j in range(n_bnd):
        src = bnd[p + 3]
        if src == 1:
            out.append(j)
        p += 5 if src == 1 else 12
    if p != len(bnd):
        raise SystemExit(f"the boundary part is {len(bnd)} bytes, its list reads {p}")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("program")
    ap.add_argument("--sol", help="write the Solidity library here")
    ap.add_argument("--library", default="ProgramFormProgram")
    a = ap.parse_args()
    path = pathlib.Path(a.program)
    blob = path.read_bytes()
    at, hdr = split(blob)
    tape, bnd = blob[:at], blob[at:]
    (path.parent / "tape.bin").write_bytes(tape)
    pin = pins(bnd, hdr[2], hdr[3])
    print(f"blob {len(blob)} bytes: transition part {at}, boundary part {len(bnd)}, "
          f"{len(pin)} public pins, sha256 {hashlib.sha256(blob).hexdigest()}")
    if not a.sol:
        return
    run = pin and pin == list(range(pin[0], pin[0] + len(pin)))
    span = f" Boundaries {pin[0]}..{pin[-1]} read public word k." if run else ""
    rows = "\n".join('        hex"%s"' % bnd[i:i + 48].hex() for i in range(0, len(bnd), 48))
    src = f'''// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title {a.library}
/// @notice The program-form blob of `gen_program_air.py`, split: transition part by hash, boundary part inline.
/// @dev Written by `script/tools/program_form_blob.py`. Transition part {at} bytes ({hdr[0]} ops, {hdr[1]} outputs),
///      boundary part {len(bnd)} bytes ({hdr[2]} boundaries on {hdr[3]} rows).{span}
library {a.library} {{
    /// @notice keccak256 of the transition part the data contract must hold.
    bytes32 internal constant TAPE_HASH = 0x{keccak(tape)};
    /// @notice Length of the transition part, in bytes.
    uint256 internal constant TAPE_LENGTH = {at};
    /// @notice keccak256 of the whole blob, transition part then boundary part.
    bytes32 internal constant PROGRAM_HASH = 0x{keccak(blob)};

    /// @notice The boundary part of the blob.
    bytes internal constant BOUNDARIES =
{rows};
}}
'''
    pathlib.Path(a.sol).write_text(src)


main()
