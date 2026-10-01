// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

// A copy of the ProgramFormAir compiler with an assembly compile, for gas profiling in Prof.t.sol.

/// @notice The program-form outer's composition at z:
///         sum_i alpha_i C_i(z) E(z) / (z^t - 1) + sum_j alpha_{nOut+j} (frame[col_j] - v_j) / (z - g^row_j).
/// @dev `compile` checks a program blob once and lowers it to an image, and `stage*` and `run*` run
///      it in Fp2 = Fp[u]/(u^2 - 7), every kept value below P. The calldata and memory interpreters
///      differ only in how they load coefficients and public words. Blob format: docs/07-constraints.md.
library ProfAir {
    uint256 internal constant P = 0xFFFFFFFF00000001;
    /// @dev A multiple of P above 2^131, so BIG - x never underflows for a product of canonical words.
    uint256 internal constant BIG = 0xFFFFFFFF000000010000000000000000000;
    uint256 internal constant NON_RESIDUE = 7;

    // ------------------------------------------------------------------ blob

    uint256 internal constant BLOB_HEADER = 14;
    uint256 internal constant OP_CONST = 0;
    uint256 internal constant OP_INPUT = 1;
    uint256 internal constant OP_ADD = 2;
    uint256 internal constant OP_SUB = 3;
    uint256 internal constant OP_MUL = 4;
    uint256 internal constant OP_INV = 5;
    uint256 internal constant OP_CONST_LEN = 17;
    uint256 internal constant OP_UNARY_LEN = 3;
    uint256 internal constant OP_BINARY_LEN = 5;
    uint256 internal constant BND_CONST_SRC_LEN = 12;
    uint256 internal constant BND_PIN_SRC_LEN = 5;
    /// @dev Inputs past the frame and the periodic claims: beta, then gamma.
    uint256 internal constant N_CHALLENGES = 2;

    // ------------------------------------------------------------------ arena
    // One 64-byte cell per value, c0 then c1: frame | periodic | beta | gamma | z | 2 registers |
    // constants | slots. A slot cell is reused once its value is read for the last time.

    uint256 internal constant CELL = 64;
    uint256 internal constant WORD = 32;
    /// @dev beta, gamma, z: the point's six words.
    uint256 internal constant POINT_BYTES = 192;
    /// @dev Operand addresses are 24 bits in the image.
    uint256 internal constant ADDRESS_LIMIT = 1 << 24;
    uint256 internal constant N_REGISTERS = 2;

    // ------------------------------------------------------------------ image
    //
    // Header: one word per field, at these byte offsets. `_AT` fields are byte offsets into the
    // image, and `_CELL` and `ARENA` fields are absolute memory addresses.

    uint256 internal constant H_N_FRAME = 0x000;
    uint256 internal constant H_N_PER = 0x020;
    uint256 internal constant H_N_ALPHA = 0x040;
    /// @dev Public words the pins read: the highest k pinned, plus one.
    uint256 internal constant H_N_PUB = 0x060;
    uint256 internal constant H_LOG_T = 0x080;
    uint256 internal constant H_ARENA = 0x0a0;
    uint256 internal constant H_Z_CELL = 0x0c0;
    uint256 internal constant H_CONST_CELL = 0x0e0;
    uint256 internal constant H_REG_CELL = 0x100;
    uint256 internal constant H_ARENA_END = 0x120;
    uint256 internal constant H_CONSTS_AT = 0x140;
    uint256 internal constant H_N_CONST = 0x160;
    uint256 internal constant H_STREAM_AT = 0x180;
    uint256 internal constant H_OUTS_AT = 0x1a0;
    uint256 internal constant H_N_OUT = 0x1c0;
    uint256 internal constant H_EXEMPT_AT = 0x1e0;
    uint256 internal constant H_N_EXEMPT = 0x200;
    uint256 internal constant H_ROWS_AT = 0x220;
    uint256 internal constant H_N_ROWS = 0x240;
    uint256 internal constant H_SIZE = 0x260;
    /// @dev Bit k set when some boundary pins public word k.
    uint256 internal constant H_PINS = 0x280;
    uint256 internal constant HEADER_BYTES = 0x2a0;

    /// @dev A constant: u64 c0, u64 c1.
    uint256 internal constant CONST_LEN = 16;
    uint256 internal constant CONST_C1_SHIFT = 128;

    // Instruction: u8 kind, u24 a, u24 b, u24 d, then u24 x for a fused kind. a, b, d and x are
    // cell addresses. The dispatch tries the kinds in order of how often the real program uses
    // them: MAC, MUL, SUB, DOT, MSUB, ADD, MSUBR, INV.
    uint256 internal constant I_END = 0; // stop
    uint256 internal constant I_MAC = 1; // d = x + a b
    uint256 internal constant I_MUL = 2; // d = a b
    uint256 internal constant I_SUB = 3; // d = a - b
    uint256 internal constant I_MSUB = 4; // d = x - a b
    uint256 internal constant I_ADD = 5; // d = a + b
    uint256 internal constant I_MSUBR = 6; // d = a b - x
    uint256 internal constant I_INV = 7; // d = 1 / a, b = a
    uint256 internal constant I_DOT = 8; // d = x + a b + a_2 b_2 + ... + a_n b_n
    uint256 internal constant INS_LEN = 10;
    uint256 internal constant INS_FUSED_LEN = 13;
    // I_DOT: the fused layout, then u8 n, then n - 1 more pairs of u24 a_i, u24 b_i
    uint256 internal constant DOT_HEAD_LEN = 14;
    uint256 internal constant DOT_PAIR_LEN = 6;
    uint256 internal constant DOT_N_SHIFT = 144;
    uint256 internal constant DOT_A_SHIFT = 232;
    uint256 internal constant DOT_B_SHIFT = 208;
    uint256 internal constant DOT_LIMIT = 255;
    uint256 internal constant INS_END_LEN = 1;
    // bit positions of the fields in the word an instruction starts
    uint256 internal constant INS_KIND_SHIFT = 248;
    uint256 internal constant INS_A_SHIFT = 224;
    uint256 internal constant INS_B_SHIFT = 200;
    uint256 internal constant INS_D_SHIFT = 176;
    uint256 internal constant INS_X_SHIFT = 152;
    uint256 internal constant MASK24 = 0xffffff;
    uint256 internal constant MASK16 = 0xffff;
    uint256 internal constant MASK8 = 0xff;
    uint256 internal constant MASK64 = 0xffffffffffffffff;

    /// @dev An output: the u24 address of the value that is transition i.
    uint256 internal constant OUT_LEN = 3;
    uint256 internal constant OUT_SHIFT = 232;
    /// @dev An exempt point or a row point: u64.
    uint256 internal constant POINT_LEN = 8;
    uint256 internal constant POINT_SHIFT = 192;

    // A row group: u64 g^row, u8 nConst, u8 nPin, then nConst constant entries and nPin pin
    // entries. Constant entry: u24 frame cell, u16 coefficient offset, u64 value. Pin entry:
    // u24 frame cell, u16 coefficient offset, u16 public offset. The coefficient offset is
    // 64 (nOut + j) for boundary j, the public offset 32 k for public word k.
    uint256 internal constant ROW_HEAD_LEN = 10;
    uint256 internal constant ROW_NC_SHIFT = 184;
    uint256 internal constant ROW_NP_SHIFT = 176;
    uint256 internal constant ENT_CONST_LEN = 13;
    uint256 internal constant ENT_PIN_LEN = 7;
    uint256 internal constant ENT_CELL_SHIFT = 232;
    uint256 internal constant ENT_ALPHA_SHIFT = 216;
    uint256 internal constant ENT_VALUE_SHIFT = 152;
    uint256 internal constant ENT_PUB_SHIFT = 200;
    uint256 internal constant ROW_ENTRY_LIMIT = 255;
    /// @dev Coefficient offsets are u16: 64 (nOut + nBnd) must fit.
    uint256 internal constant ALPHA_LIMIT = 1024;

    /// @dev Slot map entry for a value that holds no slot.
    uint256 internal constant NO_SLOT = 0xff;

    // ------------------------------------------------------------------ errors

    /// @notice A frame, periodic, point or public word is not below P.
    error NonCanonical();
    error BlobTruncated();
    error BlobTrailing();
    error BadOp(uint256 i);
    error BadOperand(uint256 i);
    error ConstantNotCanonical(uint256 i);
    error BadOutput(uint256 i);
    error PointNotCanonical();
    error BadBoundary(uint256 j);
    error RowTooWide(uint256 row);
    error TooManyCoefficients();
    /// @notice The slot map puts value `i` where a value still to be read lives, or nowhere.
    error BadSlot(uint256 i);
    /// @notice An operand of the instruction for op `i` is not in the cell it should be in.
    error NotResident(uint256 i);
    error ArenaTooLarge();

    // ------------------------------------------------------------------ compile
    //
    // Runs once, in the evaluator's constructor, so it is written for gas too: each phase is one
    // assembly block over tables of words, and a phase that finds the blob malformed reverts
    // there with the named error, its selector a constant below (the tests check each one).

    uint256 private constant SEL_BLOB_TRUNCATED = 0x6d753ade;
    uint256 private constant SEL_BLOB_TRAILING = 0x3c4e7bd9;
    uint256 private constant SEL_BAD_OP = 0x57294732;
    uint256 private constant SEL_BAD_OPERAND = 0xcf132d6e;
    uint256 private constant SEL_CONSTANT_NOT_CANONICAL = 0x64d99531;
    uint256 private constant SEL_BAD_OUTPUT = 0x97a0f8c7;
    uint256 private constant SEL_POINT_NOT_CANONICAL = 0xb26ea7a0;
    uint256 private constant SEL_BAD_BOUNDARY = 0xe44f9229;
    uint256 private constant SEL_ROW_TOO_WIDE = 0xc02f072f;
    uint256 private constant SEL_BAD_SLOT = 0xd5703f17;
    uint256 private constant SEL_NOT_RESIDENT = 0xb2efc22e;

    /// @notice The error selectors the compile's assembly reverts with, for the tests.
    function selectors() internal pure returns (uint256[11] memory s) {
        s = [
            SEL_BLOB_TRUNCATED,
            SEL_BLOB_TRAILING,
            SEL_BAD_OP,
            SEL_BAD_OPERAND,
            SEL_CONSTANT_NOT_CANONICAL,
            SEL_BAD_OUTPUT,
            SEL_POINT_NOT_CANONICAL,
            SEL_BAD_BOUNDARY,
            SEL_ROW_TOO_WIDE,
            SEL_BAD_SLOT,
            SEL_NOT_RESIDENT
        ];
    }

    // bit positions of a blob op's fields in the word it starts
    uint256 private constant BOP_KIND_SHIFT = 248;
    uint256 private constant BOP_A_SHIFT = 232;
    uint256 private constant BOP_B_SHIFT = 216;
    uint256 private constant BOP_C0_SHIFT = 184;
    uint256 private constant BOP_C1_SHIFT = 120;
    // bit positions of a blob boundary's fields: u8 col, u16 rowIdx, u8 src, then value or k
    uint256 private constant BND_COL_SHIFT = 248;
    uint256 private constant BND_ROW_SHIFT = 232;
    uint256 private constant BND_SRC_SHIFT = 224;
    uint256 private constant BND_VALUE_SHIFT = 160;
    uint256 private constant BND_K_SHIFT = 216;
    uint256 private constant U16_SHIFT = 240;

    /// @dev Per op, packed: kind | a << 8 | b << 24 | blob offset << 40. For a constant `a` is its
    ///      ordinal among the constants, for an input the input index, for an inversion b = a.
    uint256 private constant OPK_A = 8;
    uint256 private constant OPK_B = 24;
    uint256 private constant OPK_AT = 40;

    /// @dev Per op, packed: live reads | last reader << 16 | slot << 32 | fused << 48 |
    ///      chained << 49. A last reader of `nOps` is the output list. A slot of NO_SLOT is none.
    uint256 private constant INF_LAST = 16;
    uint256 private constant INF_SLOT = 32;
    uint256 private constant INF_FUSED = 48;
    uint256 private constant INF_CHAINED = 49;
    /// @dev The fused and chained bits, from INF_FUSED: set when an op folds into a later one.
    uint256 private constant FOLDED = 3;

    /// @dev The blob's counts and where each section starts.
    struct Blob {
        uint256 nOps;
        uint256 nOut;
        uint256 nBnd;
        uint256 nRows;
        uint256 nFrame;
        uint256 nPer;
        uint256 logT;
        uint256 nEx;
        uint256 nConst;
        uint256 opsAt;
        uint256 outsAt;
        uint256 rowsAt;
        uint256 bndAt;
    }

    /// @dev Where the arena's regions start, for one compile.
    struct Layout {
        uint256 arena;
        uint256 zCell;
        uint256 regCell;
        uint256 constCell;
        uint256 slotCell;
        uint256 end;
        uint256 nSlots;
    }

    // The emit phase's context, one word each at these offsets, so its Yul functions take one
    // pointer instead of seven values.
    uint256 private constant CX_OP = 0x00; // op table data
    uint256 private constant CX_INF = 0x20; // info table data
    uint256 private constant CX_OWNER = 0x40; // owner table data: value + 1 per slot cell, 0 free
    uint256 private constant CX_ARENA = 0x60;
    uint256 private constant CX_CONST_CELL = 0x80;
    uint256 private constant CX_SLOT_CELL = 0xa0;
    uint256 private constant CX_WORDS = 6;

    // The entry writer's context: coefficient offset of boundary 0, the arena, the constant and
    // pin cursor tables.
    uint256 private constant EX_ALPHA0 = 0x00;
    uint256 private constant EX_ARENA = 0x20;
    uint256 private constant EX_NC = 0x40;
    uint256 private constant EX_NP = 0x60;
    uint256 private constant EX_WORDS = 4;

    /// @notice Check `prog` and lower it to an image whose arena starts at `arena`.
    /// @param slots one byte per op, the slot of each value that needs one and NO_SLOT for the rest,
    ///        as `gen_program_air.py` assigns them, or empty to assign them here by the same rule.
    function compile(bytes memory prog, bytes memory slots, uint256 arena) internal pure returns (bytes memory image) {
        Blob memory b = _header(prog);
        uint256[] memory op = new uint256[](b.nOps);
        uint256[] memory inf = new uint256[](b.nOps);
        (b.nConst, b.outsAt) = _parse(prog, op, b.opsAt, b.nFrame + b.nPer + N_CHALLENGES);
        b.rowsAt = b.outsAt + 2 * b.nOut;
        b.bndAt = b.rowsAt + POINT_LEN * b.nRows;
        uint256 end = _walk(prog, b.bndAt, b.nBnd);
        if (end > prog.length) revert BlobTruncated();
        if (end != prog.length) revert BlobTrailing();
        if (b.nOut + b.nBnd > ALPHA_LIMIT) revert TooManyCoefficients();
        _liveness(prog, b.outsAt, b.nOut, op, inf);
        Layout memory l;
        l.nSlots = _slots(op, inf, slots);
        _place(b, l, arena);
        image = _emit(prog, b, op, inf, l);
    }

    /// @notice Bytes the arena of `prog` can take at most, for a caller that must reserve it first.
    function arenaBound(bytes memory prog) internal pure returns (uint256) {
        Blob memory b = _header(prog);
        return CELL * (b.nFrame + b.nPer + N_CHALLENGES + 1 + N_REGISTERS + b.nOps);
    }

    function _header(bytes memory prog) private pure returns (Blob memory b) {
        if (prog.length < BLOB_HEADER) revert BlobTruncated();
        uint256 h;
        assembly {
            h := shr(sub(256, mul(8, BLOB_HEADER)), mload(add(prog, WORD)))
        }
        // u16 nOps, nOut, nBnd, nRows, nFrame, nPer, u8 logT, nExempt: 14 bytes, low end last
        b.nEx = h & MASK8;
        b.logT = (h >> 8) & MASK8;
        b.nPer = (h >> 16) & MASK16;
        b.nFrame = (h >> 32) & MASK16;
        b.nRows = (h >> 48) & MASK16;
        b.nBnd = (h >> 64) & MASK16;
        b.nOut = (h >> 80) & MASK16;
        b.nOps = (h >> 96) & MASK16;
        b.opsAt = BLOB_HEADER + POINT_LEN * b.nEx;
    }

    /// @dev The ops into `op`, each checked: a known kind, operands earlier ops, an input index
    ///      below nIn, a constant canonical. Returns the constant count and where the ops end.
    ///      Memory: reads prog and writes op's data words.
    function _parse(bytes memory prog, uint256[] memory op, uint256 p, uint256 nIn)
        private
        pure
        returns (uint256 nConst, uint256 end)
    {
        assembly {
            function fail(sel, at) {
                mstore(0, shl(224, sel))
                mstore(4, at)
                revert(0, 0x24)
            }
            function opLen(k, i) -> len {
                switch k
                case 0 { len := OP_CONST_LEN }
                case 1 { len := OP_UNARY_LEN }
                case 5 { len := OP_UNARY_LEN }
                default {
                    // OP_ADD, OP_SUB, OP_MUL, and anything above is no op
                    if gt(k, OP_MUL) { fail(SEL_BAD_OP, i) }
                    len := OP_BINARY_LEN
                }
            }
            // First pass: each op's length and blob offset, and each constant's ordinal, into the
            // table as offset << OPK_AT | ordinal << OPK_A. Returns the constants and the end.
            function measure(table, n, base, plen, q) -> ordinals, next {
                next := q
                for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                    if iszero(lt(next, plen)) { fail(SEL_BLOB_TRUNCATED, 0) }
                    let k := shr(BOP_KIND_SHIFT, mload(add(base, next)))
                    let len := opLen(k, i)
                    if gt(add(next, len), plen) { fail(SEL_BLOB_TRUNCATED, 0) }
                    let ord := 0
                    if iszero(k) {
                        ord := ordinals
                        ordinals := add(ordinals, 1)
                    }
                    mstore(add(table, shl(5, i)), or(shl(OPK_AT, next), shl(OPK_A, ord)))
                    next := add(next, len)
                }
            }
            // Second pass: each op's fields from its blob word, checked, the offset kept.
            function decode(w, prov, i, inputs) -> fields {
                let k := shr(BOP_KIND_SHIFT, w)
                let x := and(shr(BOP_A_SHIFT, w), MASK16)
                let y := and(shr(BOP_B_SHIFT, w), MASK16)
                switch k
                case 0 {
                    // OP_CONST: x is its ordinal among the constants
                    let c0 := and(shr(BOP_C0_SHIFT, w), MASK64)
                    let c1 := and(shr(BOP_C1_SHIFT, w), MASK64)
                    if iszero(and(lt(c0, P), lt(c1, P))) { fail(SEL_CONSTANT_NOT_CANONICAL, i) }
                    x := and(shr(OPK_A, prov), MASK16)
                    y := 0
                }
                case 1 {
                    // OP_INPUT
                    if iszero(lt(x, inputs)) { fail(SEL_BAD_OPERAND, i) }
                    y := 0
                }
                case 5 {
                    // OP_INV: b = a
                    if iszero(lt(x, i)) { fail(SEL_BAD_OPERAND, i) }
                    y := x
                }
                default {
                    if iszero(and(lt(x, i), lt(y, i))) { fail(SEL_BAD_OPERAND, i) }
                }
                fields := or(or(k, shl(OPK_A, x)), or(shl(OPK_B, y), shl(OPK_AT, shr(OPK_AT, prov))))
            }
            function decodeAll(table, n, base, inputs) {
                for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                    let at := add(table, shl(5, i))
                    let prov := mload(at)
                    mstore(at, decode(mload(add(base, shr(OPK_AT, prov))), prov, i, inputs))
                }
            }
            nConst, end := measure(add(op, WORD), mload(op), add(prog, WORD), mload(prog), p)
            decodeAll(add(op, WORD), mload(op), add(prog, WORD), nIn)
        }
    }

    /// @dev Where the boundary list starting at p ends, each entry's length read from its source.
    function _walk(bytes memory prog, uint256 p, uint256 nBnd) private pure returns (uint256 end) {
        assembly {
            let base := add(prog, WORD)
            let plen := mload(prog)
            for { let j := 0 } lt(j, nBnd) { j := add(j, 1) } {
                if gt(add(p, BND_PIN_SRC_LEN), plen) {
                    // leave the rest to the caller's length check
                    p := add(plen, 1)
                    break
                }
                let src := and(shr(BND_SRC_SHIFT, mload(add(base, p))), MASK8)
                if gt(src, 1) {
                    mstore(0, shl(224, SEL_BAD_BOUNDARY))
                    mstore(4, j)
                    revert(0, 0x24)
                }
                p := add(p, sub(BND_CONST_SRC_LEN, mul(src, sub(BND_CONST_SRC_LEN, BND_PIN_SRC_LEN))))
            }
            end := p
        }
    }

    /// @dev Walks the ops backward: counts the reads of each live value and its last reader, marks a
    ///      multiply read once by the add or subtract right after it as fused, and marks runs of fused
    ///      adds as chained, one I_DOT each. An inversion is always live because it refuses a zero.
    function _liveness(bytes memory prog, uint256 outsAt, uint256 nOut, uint256[] memory op, uint256[] memory inf)
        private
        pure
    {
        assembly {
            // one more live read of v. The first seen walking backward is its last reader
            function read(infs, v, reader) {
                let at := add(infs, shl(5, v))
                let w := mload(at)
                if iszero(and(w, MASK16)) { w := or(w, shl(INF_LAST, reader)) }
                mstore(at, add(w, 1))
            }
            function fusedAt(infs, i) -> f { f := and(shr(INF_FUSED, mload(add(infs, shl(5, i)))), 1) }
            // op i is x + a b: an add the multiply right before it is fused into
            function mac(ops, infs, i) -> m {
                m := and(eq(and(mload(add(ops, shl(5, i))), MASK8), OP_ADD), fusedAt(infs, sub(i, 1)))
            }
            function reads(ops, w, i) -> r {
                r := or(eq(and(shr(OPK_A, w), MASK16), i), eq(and(shr(OPK_B, w), MASK16), i))
            }
            // a multiply read once, by the live add or subtract right after it
            function fusable(ops, infs, i) -> f {
                let nx := mload(add(ops, shl(5, add(i, 1))))
                let k := and(nx, MASK8)
                let once := eq(and(mload(add(infs, shl(5, i))), MASK16), 1)
                let nextLive := iszero(iszero(and(mload(add(infs, shl(5, add(i, 1)))), MASK16)))
                f := and(and(eq(and(mload(add(ops, shl(5, i))), MASK8), OP_MUL), once), and(or(eq(k, OP_ADD), eq(k, OP_SUB)), nextLive))
                f := and(f, reads(ops, nx, i))
            }
            // an x + a b read once, by the x + a b two ops on
            function chainable(ops, infs, i) -> c {
                let once := eq(and(mload(add(infs, shl(5, i))), MASK16), 1)
                c := and(and(mac(ops, infs, i), mac(ops, infs, add(i, 2))), once)
                c := and(c, reads(ops, mload(add(ops, shl(5, add(i, 2)))), i))
            }
            let n := mload(op)
            let ops := add(op, WORD)
            let infs := add(inf, WORD)
            let outs := add(add(prog, WORD), outsAt)
            for { let i := 0 } lt(i, nOut) { i := add(i, 1) } {
                let o := shr(U16_SHIFT, mload(add(outs, shl(1, i))))
                if iszero(lt(o, n)) {
                    mstore(0, shl(224, SEL_BAD_OUTPUT))
                    mstore(4, i)
                    revert(0, 0x24)
                }
                read(infs, o, n)
            }
            for { let i := n } i {} {
                i := sub(i, 1)
                let w := mload(add(ops, shl(5, i)))
                let k := and(w, MASK8)
                let live := or(and(mload(add(infs, shl(5, i))), MASK16), eq(k, OP_INV))
                if and(iszero(lt(k, OP_ADD)), iszero(iszero(live))) {
                    read(infs, and(shr(OPK_A, w), MASK16), i)
                    if iszero(eq(k, OP_INV)) { read(infs, and(shr(OPK_B, w), MASK16), i) }
                }
            }
            for { let i := 0 } lt(add(i, 1), n) { i := add(i, 1) } {
                if fusable(ops, infs, i) {
                    let at := add(infs, shl(5, i))
                    mstore(at, or(mload(at), shl(INF_FUSED, 1)))
                }
            }
            for { let i := 1 } lt(add(i, 2), n) { i := add(i, 1) } {
                if chainable(ops, infs, i) {
                    let at := add(infs, shl(5, i))
                    mstore(at, or(mload(at), shl(INF_CHAINED, 1)))
                }
            }
        }
    }

    /// @dev A slot for every value an instruction writes, by the rule of `gen_program_air.py`: free the
    ///      slots of operands read for the last time, then take the most recently freed slot or a new
    ///      one. The map is not trusted: `_emit` checks every read against the owner of its cell.
    function _slots(uint256[] memory op, uint256[] memory inf, bytes memory map) private pure returns (uint256 nSlots) {
        uint256 n = op.length;
        bool given = map.length != 0;
        if (given && map.length != n) revert BadSlot(n);
        uint256[] memory free = new uint256[](n);
        assembly {
            function fail(sel, at) {
                mstore(0, shl(224, sel))
                mstore(4, at)
                revert(0, 0x24)
            }
            // Fields of the op and info tables (see OPK_ and INF_), and the operands of the instruction
            // that ends at op i: plain, a and b, else each fused multiply's a and b in program order, then
            // x, the other addend of the run's first add. `head` is that first add, 0 for a plain one.
            function kindOf(ops, v) -> k {
                k := and(mload(add(ops, shl(5, v))), MASK8)
            }
            function aOf(ops, v) -> a {
                a := and(shr(OPK_A, mload(add(ops, shl(5, v)))), MASK16)
            }
            function bOf(ops, v) -> b {
                b := and(shr(OPK_B, mload(add(ops, shl(5, v)))), MASK16)
            }
            function flag(infs, v, bit) -> f {
                f := and(shr(bit, mload(add(infs, shl(5, v)))), 1)
            }
            // a live add, subtract, multiply or inversion, neither fused nor chained into a later op
            function ends(ops, infs, i) -> e {
                let k := kindOf(ops, i)
                let w := mload(add(infs, shl(5, i)))
                let live := or(iszero(iszero(and(w, MASK16))), eq(k, OP_INV))
                e := and(and(iszero(lt(k, OP_ADD)), live), iszero(and(shr(INF_FUSED, w), FOLDED)))
            }
            function headOf(ops, infs, i) -> head {
                if i {
                    if flag(infs, sub(i, 1), INF_FUSED) {
                        head := i
                        for {} and(gt(head, 2), flag(infs, sub(head, 2), INF_CHAINED)) {} { head := sub(head, 2) }
                    }
                }
            }
            function countOf(head, i) -> c {
                c := 2
                if head { c := add(shl(1, add(shr(1, sub(i, head)), 1)), 1) }
            }
            function operand(ops, head, i, r) -> v {
                switch head
                case 0 {
                    v := aOf(ops, i)
                    if r { v := bOf(ops, i) }
                }
                default {
                    switch lt(r, sub(countOf(head, i), 1))
                    case 1 {
                        let m := add(sub(head, 1), shl(1, shr(1, r)))
                        v := aOf(ops, m)
                        if and(r, 1) { v := bOf(ops, m) }
                    }
                    default {
                        v := aOf(ops, head)
                        if eq(v, sub(head, 1)) { v := bOf(ops, head) }
                    }
                }
            }
            // operand r repeats an earlier operand of the same instruction
            function seen(ops, head, i, r, v) -> s {
                for { let q := 0 } lt(q, r) { q := add(q, 1) } {
                    if eq(operand(ops, head, i, q), v) {
                        s := 1
                        break
                    }
                }
            }
            // the slot operand r of the instruction ending at op i frees: its value's, when this
            // instruction is its last reader and r its first mention, else NO_SLOT
            function freed(ops, infs, head, i, r) -> s {
                s := NO_SLOT
                let v := operand(ops, head, i, r)
                if iszero(seen(ops, head, i, r, v)) {
                    let w := mload(add(infs, shl(5, v)))
                    if iszero(gt(and(shr(INF_LAST, w), MASK16), i)) { s := and(shr(INF_SLOT, w), MASK16) }
                }
            }
            // push the slots the instruction ending at op i frees, in operand order
            function release(ops, infs, stack, top, i) -> t {
                t := top
                let head := headOf(ops, infs, i)
                for { let r := 0 } lt(r, countOf(head, i)) { r := add(r, 1) } {
                    let s := freed(ops, infs, head, i, r)
                    if iszero(eq(s, NO_SLOT)) {
                        mstore(add(stack, shl(5, t)), s)
                        t := add(t, 1)
                    }
                }
            }
            function assign(ops, infs, stack, mp, useMap, nOps) -> count {
                let top := 0
                for { let i := 0 } lt(i, nOps) { i := add(i, 1) } {
                    let at := add(infs, shl(5, i))
                    switch ends(ops, infs, i)
                    case 0 { mstore(at, or(mload(at), shl(INF_SLOT, NO_SLOT))) }
                    default {
                        let s := count
                        switch useMap
                        case 1 {
                            s := byte(0, mload(add(mp, i)))
                            if eq(s, NO_SLOT) { fail(SEL_BAD_SLOT, i) }
                        }
                        default {
                            top := release(ops, infs, stack, top, i)
                            if top {
                                top := sub(top, 1)
                                s := mload(add(stack, shl(5, top)))
                            }
                            if eq(s, NO_SLOT) { fail(SEL_BAD_SLOT, i) }
                            // an inversion nothing reads gives its cell straight back
                            if iszero(and(mload(at), MASK16)) {
                                mstore(add(stack, shl(5, top)), s)
                                top := add(top, 1)
                            }
                        }
                        if iszero(lt(s, count)) { count := add(s, 1) }
                        mstore(at, or(mload(at), shl(INF_SLOT, s)))
                    }
                }
            }
            nSlots := assign(add(op, WORD), add(inf, WORD), add(free, WORD), add(map, WORD), given, n)
        }
    }

    function _place(Blob memory b, Layout memory l, uint256 arena) private pure {
        l.arena = arena;
        l.zCell = arena + CELL * (b.nFrame + b.nPer + N_CHALLENGES);
        l.regCell = l.zCell + CELL;
        l.constCell = l.regCell + CELL * N_REGISTERS;
        l.slotCell = l.constCell + CELL * b.nConst;
        l.end = l.slotCell + CELL * l.nSlots;
        if (l.end > ADDRESS_LIMIT) revert ArenaTooLarge();
    }

    function _emit(bytes memory prog, Blob memory b, uint256[] memory op, uint256[] memory inf, Layout memory l)
        private
        pure
        returns (bytes memory image)
    {
        uint256 bound = HEADER_BYTES + CONST_LEN * b.nConst + INS_FUSED_LEN * b.nOps + INS_END_LEN + OUT_LEN * b.nOut
            + POINT_LEN * b.nEx + ROW_HEAD_LEN * b.nRows + ENT_CONST_LEN * b.nBnd;
        image = new bytes(bound + WORD);
        uint256[] memory owner = new uint256[](l.nSlots);
        uint256[CX_WORDS] memory cx;
        assembly {
            mstore(add(cx, CX_OP), add(op, WORD))
            mstore(add(cx, CX_INF), add(inf, WORD))
            mstore(add(cx, CX_OWNER), add(owner, WORD))
        }
        cx[CX_ARENA / WORD] = l.arena;
        cx[CX_CONST_CELL / WORD] = l.constCell;
        cx[CX_SLOT_CELL / WORD] = l.slotCell;

        _field(image, H_N_FRAME, b.nFrame);
        _field(image, H_N_PER, b.nPer);
        _field(image, H_N_ALPHA, b.nOut + b.nBnd);
        _field(image, H_LOG_T, b.logT);
        _field(image, H_ARENA, l.arena);
        _field(image, H_Z_CELL, l.zCell);
        _field(image, H_REG_CELL, l.regCell);
        _field(image, H_CONST_CELL, l.constCell);
        _field(image, H_ARENA_END, l.end);
        _field(image, H_N_CONST, b.nConst);
        _field(image, H_N_OUT, b.nOut);
        _field(image, H_N_EXEMPT, b.nEx);
        _field(image, H_N_ROWS, b.nRows);

        uint256 at = HEADER_BYTES;
        _field(image, H_CONSTS_AT, at);
        at = _constants(image, at, prog, op);
        _field(image, H_STREAM_AT, at);
        at = _stream(image, at, cx);
        _field(image, H_OUTS_AT, at);
        at = _outputs(image, at, prog, b.outsAt, b.nOut, cx);
        _field(image, H_EXEMPT_AT, at);
        at = _exempt(image, at, prog, b.nEx);
        _field(image, H_ROWS_AT, at);
        uint256 nPub;
        uint256 pins;
        (at, nPub, pins) = _rows(image, at, prog, b, l.arena);
        _field(image, H_N_PUB, nPub);
        _field(image, H_PINS, pins);
        _field(image, H_SIZE, at);
        assembly {
            mstore(image, at)
        }
    }

    function _field(bytes memory image, uint256 field, uint256 v) private pure {
        assembly {
            mstore(add(add(image, WORD), field), v)
        }
    }

    // The emit phases write the image through `put`: a big-endian write of the low `len` bytes of
    // v at `ptr`, one read-modify-write of the word there. The image has a word of slack past
    // its bound, so that word never leaves the allocation.

    /// @dev The constant table: u64 c0, u64 c1 per constant, in op order.
    function _constants(bytes memory image, uint256 at, bytes memory prog, uint256[] memory op)
        private
        pure
        returns (uint256)
    {
        assembly {
            let ptr := add(add(image, WORD), at)
            let base := add(prog, WORD)
            let ops := add(op, WORD)
            let end := add(ops, shl(5, mload(op)))
            for {} lt(ops, end) { ops := add(ops, WORD) } {
                let w := mload(ops)
                if iszero(and(w, MASK8)) {
                    // OP_CONST: its 16 value bytes, copied whole
                    let v := and(shr(BOP_C1_SHIFT, mload(add(base, shr(OPK_AT, w)))), 0xffffffffffffffffffffffffffffffff)
                    mstore(ptr, or(and(mload(ptr), shr(128, not(0))), shl(128, v)))
                    ptr := add(ptr, CONST_LEN)
                }
            }
            at := sub(ptr, add(image, WORD))
        }
        return at;
    }

    /// @dev The instructions, each operand checked resident: in the cell the image names and, for
    ///      a slot cell, still owned by that value. Then the result's slot is taken. Then END.
    ///      Memory: reads the tables in cx and writes the image and the owner table.
    function _stream(bytes memory image, uint256 at, uint256[CX_WORDS] memory cx) private pure returns (uint256) {
        assembly {
            function fail(sel, i) {
                mstore(0, shl(224, sel))
                mstore(4, i)
                revert(0, 0x24)
            }
            function put(ptr, v, len) -> next {
                let bits := shl(3, len)
                mstore(ptr, or(and(mload(ptr), shr(bits, not(0))), shl(sub(256, bits), v)))
                next := add(ptr, len)
            }
            // Fields of the op and info tables (see OPK_ and INF_), and the operands of the instruction
            // that ends at op i: plain, a and b, else each fused multiply's a and b in program order, then
            // x, the other addend of the run's first add. `head` is that first add, 0 for a plain one.
            function kindOf(ops, v) -> k {
                k := and(mload(add(ops, shl(5, v))), MASK8)
            }
            function aOf(ops, v) -> a {
                a := and(shr(OPK_A, mload(add(ops, shl(5, v)))), MASK16)
            }
            function bOf(ops, v) -> b {
                b := and(shr(OPK_B, mload(add(ops, shl(5, v)))), MASK16)
            }
            function flag(infs, v, bit) -> f {
                f := and(shr(bit, mload(add(infs, shl(5, v)))), 1)
            }
            // a live add, subtract, multiply or inversion, neither fused nor chained into a later op
            function ends(ops, infs, i) -> e {
                let k := kindOf(ops, i)
                let w := mload(add(infs, shl(5, i)))
                let live := or(iszero(iszero(and(w, MASK16))), eq(k, OP_INV))
                e := and(and(iszero(lt(k, OP_ADD)), live), iszero(and(shr(INF_FUSED, w), FOLDED)))
            }
            function headOf(ops, infs, i) -> head {
                if i {
                    if flag(infs, sub(i, 1), INF_FUSED) {
                        head := i
                        for {} and(gt(head, 2), flag(infs, sub(head, 2), INF_CHAINED)) {} { head := sub(head, 2) }
                    }
                }
            }
            function countOf(head, i) -> c {
                c := 2
                if head { c := add(shl(1, add(shr(1, sub(i, head)), 1)), 1) }
            }
            function operand(ops, head, i, r) -> v {
                switch head
                case 0 {
                    v := aOf(ops, i)
                    if r { v := bOf(ops, i) }
                }
                default {
                    switch lt(r, sub(countOf(head, i), 1))
                    case 1 {
                        let m := add(sub(head, 1), shl(1, shr(1, r)))
                        v := aOf(ops, m)
                        if and(r, 1) { v := bOf(ops, m) }
                    }
                    default {
                        v := aOf(ops, head)
                        if eq(v, sub(head, 1)) { v := bOf(ops, head) }
                    }
                }
            }
            // operand r repeats an earlier operand of the same instruction
            function seen(ops, head, i, r, v) -> s {
                for { let q := 0 } lt(q, r) { q := add(q, 1) } {
                    if eq(operand(ops, head, i, q), v) {
                        s := 1
                        break
                    }
                }
            }
            // The cell value v lives in, checked for instruction `who`: an input or constant cell, or a
            // slot cell v still owns. ctx is the emit context (see CX_).
            function resident(ctx, v, who) -> c {
                let ops := mload(add(ctx, CX_OP))
                switch kindOf(ops, v)
                case 0 {
                    // OP_CONST: its own cell, by ordinal
                    c := add(mload(add(ctx, CX_CONST_CELL)), shl(6, aOf(ops, v)))
                }
                case 1 {
                    // OP_INPUT: the input's cell
                    c := add(mload(add(ctx, CX_ARENA)), shl(6, aOf(ops, v)))
                }
                default {
                    let s := and(shr(INF_SLOT, mload(add(mload(add(ctx, CX_INF)), shl(5, v)))), MASK16)
                    let owner := mload(add(ctx, CX_OWNER))
                    if iszero(lt(s, mload(sub(owner, WORD)))) { fail(SEL_NOT_RESIDENT, who) }
                    if iszero(eq(mload(add(owner, shl(5, s))), add(v, 1))) { fail(SEL_NOT_RESIDENT, who) }
                    c := add(mload(add(ctx, CX_SLOT_CELL)), shl(6, s))
                }
            }
            // the kind for the instruction ending at op i with nm fused multiplies
            function kindFor(ops, i, nm) -> kind {
                let w := mload(add(ops, shl(5, i)))
                switch nm
                case 0 {
                    kind := I_INV
                    switch and(w, MASK8)
                    case 2 { kind := I_ADD }
                    case 3 { kind := I_SUB }
                    case 4 { kind := I_MUL }
                }
                case 1 {
                    kind := I_MAC
                    if eq(and(w, MASK8), OP_SUB) {
                        kind := I_MSUBR
                        if eq(and(shr(OPK_B, w), MASK16), sub(i, 1)) { kind := I_MSUB }
                    }
                }
                default { kind := I_DOT }
            }
            // the cell of operand r of the instruction ending at op i, checked resident
            function rc(ctx, head, i, r) -> c {
                c := resident(ctx, operand(mload(add(ctx, CX_OP)), head, i, r), i)
            }
            // One instruction at ptr. Every operand is checked resident as it is written, and
            // only then does the result's slot change hands, so a result may take the cell of an
            // operand it consumes.
            function instruction(ctx, ptr, i) -> next {
                let head := headOf(mload(add(ctx, CX_OP)), mload(add(ctx, CX_INF)), i)
                let last := sub(countOf(head, i), 1) // x's index when fused
                let nm := shr(1, last) // multiplies: 0 plain, 1 fused, more a dot
                if gt(nm, DOT_LIMIT) { fail(SEL_BAD_OP, i) }
                let s := and(shr(INF_SLOT, mload(add(mload(add(ctx, CX_INF)), shl(5, i)))), MASK16)
                if iszero(lt(s, mload(sub(mload(add(ctx, CX_OWNER)), WORD)))) { fail(SEL_BAD_SLOT, i) }
                next := put(ptr, kindFor(mload(add(ctx, CX_OP)), i, nm), 1)
                next := put(next, rc(ctx, head, i, 0), 3)
                next := put(next, rc(ctx, head, i, 1), 3)
                next := put(next, add(mload(add(ctx, CX_SLOT_CELL)), shl(6, s)), 3)
                if nm { next := put(next, rc(ctx, head, i, last), 3) }
                if gt(nm, 1) {
                    next := put(next, nm, 1)
                    for { let r := 2 } lt(r, last) { r := add(r, 1) } { next := put(next, rc(ctx, head, i, r), 3) }
                }
                mstore(add(mload(add(ctx, CX_OWNER)), shl(5, s)), add(i, 1))
            }
            let ops := mload(add(cx, CX_OP))
            let infs := mload(add(cx, CX_INF))
            let n := mload(sub(ops, WORD))
            let ptr := add(add(image, WORD), at)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                if ends(ops, infs, i) { ptr := instruction(cx, ptr, i) }
            }
            ptr := put(ptr, I_END, INS_END_LEN)
            at := sub(ptr, add(image, WORD))
        }
        return at;
    }

    /// @dev The output list: the cell of each output value, checked resident at the end.
    function _outputs(bytes memory image, uint256 at, bytes memory prog, uint256 outsAt, uint256 nOut, uint256[CX_WORDS] memory cx)
        private
        pure
        returns (uint256)
    {
        assembly {
            function fail(sel, i) {
                mstore(0, shl(224, sel))
                mstore(4, i)
                revert(0, 0x24)
            }
            function put(ptr, v, len) -> next {
                let bits := shl(3, len)
                mstore(ptr, or(and(mload(ptr), shr(bits, not(0))), shl(sub(256, bits), v)))
                next := add(ptr, len)
            }
            // Fields of the op and info tables (see OPK_ and INF_), and the operands of the instruction
            // that ends at op i: plain, a and b, else each fused multiply's a and b in program order, then
            // x, the other addend of the run's first add. `head` is that first add, 0 for a plain one.
            function kindOf(ops, v) -> k {
                k := and(mload(add(ops, shl(5, v))), MASK8)
            }
            function aOf(ops, v) -> a {
                a := and(shr(OPK_A, mload(add(ops, shl(5, v)))), MASK16)
            }
            function bOf(ops, v) -> b {
                b := and(shr(OPK_B, mload(add(ops, shl(5, v)))), MASK16)
            }
            function flag(infs, v, bit) -> f {
                f := and(shr(bit, mload(add(infs, shl(5, v)))), 1)
            }
            // a live add, subtract, multiply or inversion, neither fused nor chained into a later op
            function ends(ops, infs, i) -> e {
                let k := kindOf(ops, i)
                let w := mload(add(infs, shl(5, i)))
                let live := or(iszero(iszero(and(w, MASK16))), eq(k, OP_INV))
                e := and(and(iszero(lt(k, OP_ADD)), live), iszero(and(shr(INF_FUSED, w), FOLDED)))
            }
            function headOf(ops, infs, i) -> head {
                if i {
                    if flag(infs, sub(i, 1), INF_FUSED) {
                        head := i
                        for {} and(gt(head, 2), flag(infs, sub(head, 2), INF_CHAINED)) {} { head := sub(head, 2) }
                    }
                }
            }
            function countOf(head, i) -> c {
                c := 2
                if head { c := add(shl(1, add(shr(1, sub(i, head)), 1)), 1) }
            }
            function operand(ops, head, i, r) -> v {
                switch head
                case 0 {
                    v := aOf(ops, i)
                    if r { v := bOf(ops, i) }
                }
                default {
                    switch lt(r, sub(countOf(head, i), 1))
                    case 1 {
                        let m := add(sub(head, 1), shl(1, shr(1, r)))
                        v := aOf(ops, m)
                        if and(r, 1) { v := bOf(ops, m) }
                    }
                    default {
                        v := aOf(ops, head)
                        if eq(v, sub(head, 1)) { v := bOf(ops, head) }
                    }
                }
            }
            // operand r repeats an earlier operand of the same instruction
            function seen(ops, head, i, r, v) -> s {
                for { let q := 0 } lt(q, r) { q := add(q, 1) } {
                    if eq(operand(ops, head, i, q), v) {
                        s := 1
                        break
                    }
                }
            }
            // The cell value v lives in, checked for instruction `who`: an input or constant cell, or a
            // slot cell v still owns. ctx is the emit context (see CX_).
            function resident(ctx, v, who) -> c {
                let ops := mload(add(ctx, CX_OP))
                switch kindOf(ops, v)
                case 0 {
                    // OP_CONST: its own cell, by ordinal
                    c := add(mload(add(ctx, CX_CONST_CELL)), shl(6, aOf(ops, v)))
                }
                case 1 {
                    // OP_INPUT: the input's cell
                    c := add(mload(add(ctx, CX_ARENA)), shl(6, aOf(ops, v)))
                }
                default {
                    let s := and(shr(INF_SLOT, mload(add(mload(add(ctx, CX_INF)), shl(5, v)))), MASK16)
                    let owner := mload(add(ctx, CX_OWNER))
                    if iszero(lt(s, mload(sub(owner, WORD)))) { fail(SEL_NOT_RESIDENT, who) }
                    if iszero(eq(mload(add(owner, shl(5, s))), add(v, 1))) { fail(SEL_NOT_RESIDENT, who) }
                    c := add(mload(add(ctx, CX_SLOT_CELL)), shl(6, s))
                }
            }
            let ptr := add(add(image, WORD), at)
            let outs := add(add(prog, WORD), outsAt)
            for { let i := 0 } lt(i, nOut) { i := add(i, 1) } {
                ptr := put(ptr, resident(cx, shr(U16_SHIFT, mload(add(outs, shl(1, i)))), i), OUT_LEN)
            }
            at := sub(ptr, add(image, WORD))
        }
        return at;
    }

    /// @dev The exempt points, each checked canonical.
    function _exempt(bytes memory image, uint256 at, bytes memory prog, uint256 nEx) private pure returns (uint256) {
        for (uint256 i = 0; i < nEx; ++i) {
            uint256 x = _u64(prog, BLOB_HEADER + POINT_LEN * i);
            if (x >= P) revert PointNotCanonical();
            _put(image, at, x, POINT_LEN);
            at += POINT_LEN;
        }
        return at;
    }

    /// @dev The boundaries grouped by row, rows in the blob's order and each row's constants then
    ///      its pins, each in draw order. Returns where they end, the count of public words the
    ///      pins need and the set of words they pin, bit k for word k.
    function _rows(bytes memory image, uint256 at, bytes memory prog, Blob memory b, uint256 arena)
        private
        pure
        returns (uint256, uint256 nPub, uint256 pins)
    {
        uint256[] memory nc = new uint256[](b.nRows);
        uint256[] memory np = new uint256[](b.nRows);
        (nPub, pins) = _count(prog, b.bndAt, b.nBnd, b.nFrame, nc, np);
        // group heads, and the cursors each row's constants and pins are written at
        for (uint256 r = 0; r < b.nRows; ++r) {
            if (nc[r] > ROW_ENTRY_LIMIT || np[r] > ROW_ENTRY_LIMIT) revert RowTooWide(r);
            uint256 x = _u64(prog, b.rowsAt + POINT_LEN * r);
            if (x >= P) revert PointNotCanonical();
            _put(image, at, x, POINT_LEN);
            _put(image, at + POINT_LEN, nc[r], 1);
            _put(image, at + POINT_LEN + 1, np[r], 1);
            uint256 c = at + ROW_HEAD_LEN;
            at = c + ENT_CONST_LEN * nc[r] + ENT_PIN_LEN * np[r];
            np[r] = c + ENT_CONST_LEN * nc[r];
            nc[r] = c;
        }
        _entries(image, prog, b, arena, nc, np);
        return (at, nPub, pins);
    }

    /// @dev Per row, its constant and pin counts, every entry checked: column in the frame, row
    ///      in the table, constant canonical.
    function _count(bytes memory prog, uint256 p, uint256 nBnd, uint256 nFrame, uint256[] memory nc, uint256[] memory np)
        private
        pure
        returns (uint256 nPub, uint256 pins)
    {
        assembly {
            function fail(j) {
                mstore(0, shl(224, SEL_BAD_BOUNDARY))
                mstore(4, j)
                revert(0, 0x24)
            }
            function bump(arr, r) {
                let c := add(add(arr, WORD), shl(5, r))
                mstore(c, add(mload(c), 1))
            }
            // entry j at blob offset q: checked, counted in its row. Returns the next offset
            function one(base, q, j, frameCells, counts, pinCounts) -> next {
                let w := mload(add(base, q))
                let r := and(shr(BND_ROW_SHIFT, w), MASK16)
                if iszero(and(lt(shr(BND_COL_SHIFT, w), frameCells), lt(r, mload(counts)))) { fail(j) }
                switch and(shr(BND_SRC_SHIFT, w), MASK8)
                case 0 {
                    if iszero(lt(and(shr(BND_VALUE_SHIFT, w), MASK64), P)) { fail(j) }
                    bump(counts, r)
                    next := add(q, BND_CONST_SRC_LEN)
                }
                default {
                    bump(pinCounts, r)
                    next := add(q, BND_PIN_SRC_LEN)
                }
            }
            let base := add(prog, WORD)
            for { let j := 0 } lt(j, nBnd) { j := add(j, 1) } {
                let w := mload(add(base, p))
                if and(shr(BND_SRC_SHIFT, w), MASK8) {
                    let k := and(shr(BND_K_SHIFT, w), MASK8)
                    if iszero(lt(k, nPub)) { nPub := add(k, 1) }
                    pins := or(pins, shl(k, 1))
                }
                p := one(base, p, j, nFrame, nc, np)
            }
        }
    }

    /// @dev Every entry at its row's cursor: frame cell, coefficient offset, then the value or
    ///      the public offset.
    function _entries(bytes memory image, bytes memory prog, Blob memory b, uint256 arena, uint256[] memory nc, uint256[] memory np)
        private
        pure
    {
        // EX_: the entry writer's context, one word each
        uint256[EX_WORDS] memory ex;
        ex[EX_ALPHA0 / WORD] = CELL * b.nOut;
        ex[EX_ARENA / WORD] = arena;
        assembly {
            mstore(add(ex, EX_NC), nc)
            mstore(add(ex, EX_NP), np)
        }
        uint256 p = b.bndAt;
        uint256 nBnd = b.nBnd;
        assembly {
            function put(ptr, v, len) -> next {
                let bits := shl(3, len)
                mstore(ptr, or(and(mload(ptr), shr(bits, not(0))), shl(sub(256, bits), v)))
                next := add(ptr, len)
            }
            // boundary j, blob word w, at its row's cursor, which moves past it. Returns the
            // entry's length in the blob
            function entry(img, ctx, w, j) -> blobLen {
                let src := and(shr(BND_SRC_SHIFT, w), MASK8)
                let cursors := mload(add(ctx, EX_NC))
                let tail := and(shr(BND_VALUE_SHIFT, w), MASK64)
                let tailLen := POINT_LEN
                blobLen := BND_CONST_SRC_LEN
                if src {
                    cursors := mload(add(ctx, EX_NP))
                    tail := shl(5, and(shr(BND_K_SHIFT, w), MASK8))
                    tailLen := 2
                    blobLen := BND_PIN_SRC_LEN
                }
                let c := add(add(cursors, WORD), shl(5, and(shr(BND_ROW_SHIFT, w), MASK16)))
                let ptr := add(img, mload(c))
                ptr := put(ptr, add(mload(add(ctx, EX_ARENA)), shl(6, shr(BND_COL_SHIFT, w))), 3)
                ptr := put(ptr, add(mload(add(ctx, EX_ALPHA0)), shl(6, j)), 2)
                ptr := put(ptr, tail, tailLen)
                mstore(c, sub(ptr, img))
            }
            let base := add(prog, WORD)
            let img := add(image, WORD)
            for { let j := 0 } lt(j, nBnd) { j := add(j, 1) } { p := add(p, entry(img, ex, mload(add(base, p)), j)) }
        }
    }

    function _u64(bytes memory s, uint256 at) private pure returns (uint256 v) {
        if (at + POINT_LEN > s.length) revert BlobTruncated();
        assembly {
            v := shr(POINT_SHIFT, mload(add(add(s, WORD), at)))
        }
    }

    function _put(bytes memory image, uint256 at, uint256 v, uint256 len) private pure {
        assembly {
            let ptr := add(add(image, WORD), at)
            let bits := shl(3, len)
            mstore(ptr, or(and(mload(ptr), shr(bits, not(0))), shl(sub(256, bits), v)))
        }
    }

    // ------------------------------------------------------------------ run, calldata

    /// @notice Copy the frame, the periodic claims and the point into the arena, and check every
    ///         word of them and of the first `nPub` public words canonical.
    /// @dev Writes [arena, zCell + CELL). Every other region is the caller's: `img` must be the
    ///      image in memory and the arena free. The calldata offsets point at the arrays' data.
    function stageCalldata(uint256 img, uint256 frame, uint256 periodic, uint256 point, uint256 publics, uint256 nPub)
        internal
        pure
        returns (bool ok)
    {
        assembly {
            let arena := mload(add(img, H_ARENA))
            let per := add(arena, shl(6, mload(add(img, H_N_FRAME))))
            let beta := add(per, shl(6, mload(add(img, H_N_PER))))
            calldatacopy(arena, frame, sub(per, arena))
            calldatacopy(per, periodic, sub(beta, per))
            calldatacopy(beta, point, POINT_BYTES)
            // invariant: every cell word is compared, two per step, over a whole number of cells
            ok := 1
            let end := add(beta, POINT_BYTES)
            for { let p := arena } lt(p, end) { p := add(p, CELL) } {
                ok := and(ok, and(lt(mload(p), P), lt(mload(add(p, WORD)), P)))
            }
            let pe := add(publics, shl(5, nPub))
            for { let p := publics } lt(p, pe) { p := add(p, WORD) } { ok := and(ok, lt(calldataload(p), P)) }
        }
    }

    /// @notice comp_z from a staged arena, the coefficients and public words read from calldata.
    /// @param img the image, in memory
    /// @param alphas calldata offset of the coefficient pairs, transitions then boundaries
    /// @param publics calldata offset of the public words
    function runCalldata(uint256 img, uint256 alphas, uint256 publics) internal pure returns (uint256 c0, uint256 c1) {
        assembly {
            // ih is the image, ca the coefficients, pw the public words. Writes only arena cells and
            // scratch 0x00. Every cell word is below P, so an Fp2 product takes mul and one mod per
            // component. A coefficient only meets mulmod, and the stage checked every public word.

            // (a0 + a1 u)(b0 + b1 u), canonical operands.
            function f2mul(a0, a1, b0, b1) -> r0, r1 {
                r0 := mod(add(mul(a0, b0), mul(NON_RESIDUE, mul(a1, b1))), P)
                r1 := mod(add(mul(a0, b1), mul(a1, b0)), P)
            }

            function sqn(x, n) -> r {
                r := x
                for {} n { n := sub(n, 1) } { r := mulmod(r, r, P) }
            }

            // a^(P - 2), P - 2 = (2^31 - 1) 2^33 + (2^32 - 1), and x_k below is a^(2^k - 1).
            function fpinv(a) -> r {
                let x2 := mulmod(mulmod(a, a, P), a, P)
                let x3 := mulmod(mulmod(x2, x2, P), a, P)
                let x6 := mulmod(sqn(x3, 3), x3, P)
                let x12 := mulmod(sqn(x6, 6), x6, P)
                let x24 := mulmod(sqn(x12, 12), x12, P)
                let x30 := mulmod(sqn(x24, 6), x6, P)
                let x31 := mulmod(mulmod(x30, x30, P), a, P)
                let x32 := mulmod(mulmod(x31, x31, P), a, P)
                r := mulmod(sqn(x31, 33), x32, P)
            }

            // 1 / (a0 + a1 u) = (a0 - a1 u) / (a0^2 - 7 a1^2). Fp2 is a field, so a zero norm is a zero
            // element: refused with no data, the way the reference evaluator refuses it.
            function f2inv(a0, a1) -> r0, r1 {
                let n := mod(add(mul(a0, a0), sub(BIG, mul(NON_RESIDUE, mul(a1, a1)))), P)
                if iszero(n) { revert(0, 0) }
                let i := fpinv(n)
                r0 := mulmod(a0, i, P)
                r1 := mulmod(sub(P, a1), i, P)
            }

            // The image's constant table into the constant cells, one u64 c0, u64 c1 per cell.
            function constants(ih) {
                let p := add(ih, mload(add(ih, H_CONSTS_AT)))
                let cell := mload(add(ih, H_CONST_CELL))
                let end := add(cell, shl(6, mload(add(ih, H_N_CONST))))
                for {} lt(cell, end) { cell := add(cell, CELL) } {
                    let w := mload(p)
                    mstore(cell, shr(POINT_SHIFT, w))
                    mstore(add(cell, WORD), and(shr(CONST_C1_SHIFT, w), MASK64))
                    p := add(p, CONST_LEN)
                }
            }

            // The rest of an I_DOT's sum: the pairs of u24 cell addresses in [q, end), added to s0, s1
            // unreduced. A term is below 2^131 and there are at most 255, so the sums stay below 2^140.
            function dotTail(q, end, s0, s1) -> r0, r1 {
                for {} lt(q, end) { q := add(q, DOT_PAIR_LEN) } {
                    let v := mload(q)
                    let e := shr(DOT_A_SHIFT, v)
                    let f := and(shr(DOT_B_SHIFT, v), MASK24)
                    let e0 := mload(e)
                    let e1 := mload(add(e, WORD))
                    let f0 := mload(f)
                    let f1 := mload(add(f, WORD))
                    s0 := add(s0, add(mul(e0, f0), mul(NON_RESIDUE, mul(e1, f1))))
                    s1 := add(s1, add(mul(e0, f1), mul(e1, f0)))
                }
                r0 := s0
                r1 := s1
            }

            // The instruction stream, from pp to its END. Layout of the word an instruction starts:
            // kind at bits 248.., then the u24 cell addresses a, b, d and, fused, x. The compile checked
            // every address and kind, so none is checked here. Each instruction loads its operands before
            // it stores, so d may be the cell of an operand it consumes, x included.
            function stream(pp) {
                for {} 1 {} {
                    let w := mload(pp)
                    let a := and(shr(INS_A_SHIFT, w), MASK24)
                    let b := and(shr(INS_B_SHIFT, w), MASK24)
                    let a0 := mload(a)
                    let a1 := mload(add(a, WORD))
                    let b0 := mload(b)
                    let b1 := mload(add(b, WORD))
                    let d := and(shr(INS_D_SHIFT, w), MASK24)
                    switch shr(INS_KIND_SHIFT, w)
                    case 1 {
                        // I_MAC: d = x + a b
                        let x := and(shr(INS_X_SHIFT, w), MASK24)
                        let x1 := mload(add(x, WORD))
                        mstore(d, mod(add(add(mul(a0, b0), mul(NON_RESIDUE, mul(a1, b1))), mload(x)), P))
                        mstore(add(d, WORD), mod(add(add(mul(a0, b1), mul(a1, b0)), x1), P))
                        pp := add(pp, INS_FUSED_LEN)
                    }
                    case 2 {
                        // I_MUL: d = a b
                        mstore(d, mod(add(mul(a0, b0), mul(NON_RESIDUE, mul(a1, b1))), P))
                        mstore(add(d, WORD), mod(add(mul(a0, b1), mul(a1, b0)), P))
                        pp := add(pp, INS_LEN)
                    }
                    case 3 {
                        // I_SUB: d = a - b
                        mstore(d, addmod(a0, sub(P, b0), P))
                        mstore(add(d, WORD), addmod(a1, sub(P, b1), P))
                        pp := add(pp, INS_LEN)
                    }
                    case 8 {
                        // I_DOT: d = x + a b + sum of the pairs after it, one reduction at the end
                        let x := and(shr(INS_X_SHIFT, w), MASK24)
                        let s0 := add(add(mul(a0, b0), mul(NON_RESIDUE, mul(a1, b1))), mload(x))
                        let s1 := add(add(mul(a0, b1), mul(a1, b0)), mload(add(x, WORD)))
                        let q := add(pp, DOT_HEAD_LEN)
                        pp := add(q, mul(DOT_PAIR_LEN, sub(and(shr(DOT_N_SHIFT, w), MASK8), 1)))
                        s0, s1 := dotTail(q, pp, s0, s1)
                        mstore(d, mod(s0, P))
                        mstore(add(d, WORD), mod(s1, P))
                    }
                    case 4 {
                        // I_MSUB: d = x - a b, the product lifted by BIG, a multiple of P above it
                        let x := and(shr(INS_X_SHIFT, w), MASK24)
                        let x1 := mload(add(x, WORD))
                        mstore(d, mod(add(mload(x), sub(BIG, add(mul(a0, b0), mul(NON_RESIDUE, mul(a1, b1))))), P))
                        mstore(add(d, WORD), mod(add(x1, sub(BIG, add(mul(a0, b1), mul(a1, b0)))), P))
                        pp := add(pp, INS_FUSED_LEN)
                    }
                    case 5 {
                        // I_ADD: d = a + b
                        mstore(d, addmod(a0, b0, P))
                        mstore(add(d, WORD), addmod(a1, b1, P))
                        pp := add(pp, INS_LEN)
                    }
                    case 6 {
                        // I_MSUBR: d = a b - x
                        let x := and(shr(INS_X_SHIFT, w), MASK24)
                        let x1 := mload(add(x, WORD))
                        mstore(d, mod(add(add(mul(a0, b0), mul(NON_RESIDUE, mul(a1, b1))), sub(P, mload(x))), P))
                        mstore(add(d, WORD), mod(add(add(mul(a0, b1), mul(a1, b0)), sub(P, x1)), P))
                        pp := add(pp, INS_FUSED_LEN)
                    }
                    case 7 {
                        // I_INV: d = 1 / a
                        let r0, r1 := f2inv(a0, a1)
                        mstore(d, r0)
                        mstore(add(d, WORD), r1)
                        pp := add(pp, INS_LEN)
                    }
                    default {
                        // I_END
                        leave
                    }
                }
            }

            // sum_i alpha_i C_i, C_i the cell output i names. Each term is below 8 P and there are at
            // most 2^16, so the sums are reduced once, at the end.
            function transitions(ih, ca) -> s0, s1 {
                let p := add(ih, mload(add(ih, H_OUTS_AT)))
                let end := add(p, mul(OUT_LEN, mload(add(ih, H_N_OUT))))
                for {} lt(p, end) { p := add(p, OUT_LEN) } {
                    let v := shr(OUT_SHIFT, mload(p))
                    let v0 := mload(v)
                    let v1 := mload(add(v, WORD))
                    let a0 := calldataload(ca)
                    let a1 := calldataload(add(ca, WORD))
                    ca := add(ca, CELL)
                    s0 := add(s0, add(mulmod(a0, v0, P), mul(NON_RESIDUE, mulmod(a1, v1, P))))
                    s1 := add(s1, add(mulmod(a0, v1, P), mulmod(a1, v0, P)))
                }
                s0 := mod(s0, P)
                s1 := mod(s1, P)
            }

            // The transition part's pieces into the registers: reg holds H = z^t - 1, t = 2^logT, and
            // reg + CELL holds S E, S the transition sum and E = prod_k (z - e_k) over the exempt points.
            function transitionTerm(ih, ca, zc, reg) {
                let z0 := mload(zc)
                let z1 := mload(add(zc, WORD))
                let t0 := z0
                let t1 := z1
                for { let k := mload(add(ih, H_LOG_T)) } k { k := sub(k, 1) } {
                    let q0 := mod(add(mul(t0, t0), mul(NON_RESIDUE, mul(t1, t1))), P)
                    t1 := mulmod(add(t1, t1), t0, P)
                    t0 := q0
                }
                mstore(reg, addmod(t0, sub(P, 1), P))
                mstore(add(reg, WORD), t1)
                let e0 := 1
                let e1 := 0
                let p := add(ih, mload(add(ih, H_EXEMPT_AT)))
                let end := add(p, mul(POINT_LEN, mload(add(ih, H_N_EXEMPT))))
                for {} lt(p, end) { p := add(p, POINT_LEN) } {
                    e0, e1 := f2mul(e0, e1, addmod(z0, sub(P, shr(POINT_SHIFT, mload(p))), P), z1)
                }
                let s0, s1 := transitions(ih, ca)
                s0, s1 := f2mul(s0, s1, e0, e1)
                mstore(add(reg, CELL), s0)
                mstore(add(reg, add(CELL, WORD)), s1)
            }

            // One row group's sum S = sum_j alpha_j (f_j - v_j) over its constant entries, then its pin
            // entries. f - v is f0 + P - v in c0, below 2 P, and alpha meets it through mulmod. Returns S
            // reduced and the next group's start.
            function rowSum(p, ca, pw) -> s0, s1, q {
                let e := add(p, ROW_HEAD_LEN)
                let ce := add(e, mul(ENT_CONST_LEN, and(shr(ROW_NC_SHIFT, mload(p)), MASK8)))
                q := add(ce, mul(ENT_PIN_LEN, and(shr(ROW_NP_SHIFT, mload(p)), MASK8)))
                for {} lt(e, ce) { e := add(e, ENT_CONST_LEN) } {
                    let w := mload(e)
                    let f := shr(ENT_CELL_SHIFT, w)
                    let x0 := add(mload(f), sub(P, and(shr(ENT_VALUE_SHIFT, w), MASK64)))
                    let f1 := mload(add(f, WORD))
                    let al := add(ca, and(shr(ENT_ALPHA_SHIFT, w), MASK16))
                    let a0 := calldataload(al)
                    let a1 := calldataload(add(al, WORD))
                    s0 := add(s0, add(mulmod(a0, x0, P), mul(NON_RESIDUE, mulmod(a1, f1, P))))
                    s1 := add(s1, add(mulmod(a0, f1, P), mulmod(a1, x0, P)))
                }
                for {} lt(e, q) { e := add(e, ENT_PIN_LEN) } {
                    let w := mload(e)
                    let f := shr(ENT_CELL_SHIFT, w)
                    let x0 := add(mload(f), sub(P, calldataload(add(pw, and(shr(ENT_PUB_SHIFT, w), MASK16)))))
                    let f1 := mload(add(f, WORD))
                    let al := add(ca, and(shr(ENT_ALPHA_SHIFT, w), MASK16))
                    let a0 := calldataload(al)
                    let a1 := calldataload(add(al, WORD))
                    s0 := add(s0, add(mulmod(a0, x0, P), mul(NON_RESIDUE, mulmod(a1, f1, P))))
                    s1 := add(s1, add(mulmod(a0, f1, P), mulmod(a1, x0, P)))
                }
                s0 := mod(s0, P)
                s1 := mod(s1, P)
            }

            // One row's S conj(d) and n, where d = z - x = d0 + z1 u, conj(d) = d0 - z1 u and
            // n = d conj(d) = d0^2 - 7 z1^2, so S / d = S conj(d) / n. Scratch word 0x00 holds 7 z1^2.
            function rowTerm(p, ca, pw, zc) -> p0, p1, n, q {
                let s0, s1
                s0, s1, q := rowSum(p, ca, pw)
                let z1 := mload(add(zc, WORD))
                let d0 := addmod(mload(zc), sub(P, shr(POINT_SHIFT, mload(p))), P)
                n := mod(add(mul(d0, d0), sub(P, mload(0x00))), P)
                p0 := mod(add(mul(s0, d0), sub(BIG, mul(NON_RESIDUE, mul(s1, z1)))), P)
                p1 := mod(add(mul(s1, d0), sub(BIG, mul(s0, z1))), P)
            }

            // sum_r S_r / (z - x_r) as one fraction N / D, D in Fp: per row N <- N n + S conj(d) D and
            // D <- D n. D is zero when some z - x_r is, and the final inversion refuses it.
            function boundaries(ih, ca, pw, zc) -> n0, n1, dd {
                let z1 := mload(add(zc, WORD))
                mstore(0x00, mulmod(NON_RESIDUE, mulmod(z1, z1, P), P))
                let p := add(ih, mload(add(ih, H_ROWS_AT)))
                dd := 1
                for { let r := mload(add(ih, H_N_ROWS)) } r { r := sub(r, 1) } {
                    let p0, p1, n, q := rowTerm(p, ca, pw, zc)
                    p := q
                    n0 := mod(add(mul(n0, n), mul(p0, dd)), P)
                    n1 := mod(add(mul(n1, n), mul(p1, dd)), P)
                    dd := mulmod(dd, n, P)
                }
            }

            // comp_z = S E / H + N / D = (S E D + N H) / (H D), one inversion for both parts.
            function combine(reg, n0, n1, dd) -> r0, r1 {
                let u0, u1 := f2mul(n0, n1, mload(reg), mload(add(reg, WORD)))
                let v0 := addmod(mulmod(mload(add(reg, CELL)), dd, P), u0, P)
                let v1 := addmod(mulmod(mload(add(reg, add(CELL, WORD))), dd, P), u1, P)
                let i0, i1 := f2inv(mulmod(mload(reg), dd, P), mulmod(mload(add(reg, WORD)), dd, P))
                r0, r1 := f2mul(v0, v1, i0, i1)
            }

            constants(img)
            stream(add(img, mload(add(img, H_STREAM_AT))))
            let zc := mload(add(img, H_Z_CELL))
            let reg := mload(add(img, H_REG_CELL))
            transitionTerm(img, alphas, zc, reg)
            let n0, n1, dd := boundaries(img, alphas, publics, zc)
            c0, c1 := combine(reg, n0, n1, dd)
        }
    }

    // ------------------------------------------------------------------ run, memory

    /// @notice The composition of `prog` with every input in memory: compiled here, then run.
    /// @dev For tests and tools. Reverts as the evaluator does. frame is 2 * window * width words,
    ///      periodic 2 * nPer, alphas 2 * (nOut + nBnd), and point [beta0, beta1, gamma0, gamma1, z0, z1].
    function composition(
        bytes memory prog,
        uint256[] memory frame,
        uint256[] memory periodic,
        uint256[] memory alphas,
        uint256[] memory publics,
        uint256[6] memory point
    ) internal pure returns (uint256 c0, uint256 c1) {
        uint256 arena;
        uint256 bound = arenaBound(prog);
        assembly {
            arena := mload(0x40)
            mstore(0x40, add(arena, bound))
        }
        bytes memory image = compile(prog, "", arena);
        uint256 img;
        assembly {
            img := add(image, WORD)
        }
        if (
            frame.length != 2 * _hdr(img, H_N_FRAME) || periodic.length != 2 * _hdr(img, H_N_PER)
                || alphas.length != 2 * _hdr(img, H_N_ALPHA) || publics.length < _hdr(img, H_N_PUB)
        ) revert();
        if (!_stageMemory(img, frame, periodic, point, publics)) revert NonCanonical();
        uint256 al;
        uint256 pu;
        assembly {
            al := add(alphas, WORD)
            pu := add(publics, WORD)
        }
        (c0, c1) = _runMemory(img, al, pu);
    }

    function _hdr(uint256 img, uint256 field) private pure returns (uint256 v) {
        assembly {
            v := mload(add(img, field))
        }
    }

    /// @dev stageCalldata with the inputs in memory arrays.
    function _stageMemory(
        uint256 img,
        uint256[] memory frame,
        uint256[] memory periodic,
        uint256[6] memory point,
        uint256[] memory publics
    ) private pure returns (bool ok) {
        assembly {
            function copy(dst, src, n) {
                for { let i := 0 } lt(i, n) { i := add(i, WORD) } { mstore(add(dst, i), mload(add(src, i))) }
            }
            let arena := mload(add(img, H_ARENA))
            let per := add(arena, shl(6, mload(add(img, H_N_FRAME))))
            let beta := add(per, shl(6, mload(add(img, H_N_PER))))
            copy(arena, add(frame, WORD), sub(per, arena))
            copy(per, add(periodic, WORD), sub(beta, per))
            copy(beta, point, POINT_BYTES)
            ok := 1
            let end := add(beta, POINT_BYTES)
            for { let p := arena } lt(p, end) { p := add(p, CELL) } {
                ok := and(ok, and(lt(mload(p), P), lt(mload(add(p, WORD)), P)))
            }
            let n := mload(publics)
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                ok := and(ok, lt(mload(add(publics, shl(5, add(i, 1)))), P))
            }
        }
    }

    /// @dev runCalldata with the coefficients and public words in memory.
    function _runMemory(uint256 img, uint256 alphas, uint256 publics) private pure returns (uint256 c0, uint256 c1) {
        assembly {
            // ih is the image, ca the coefficients, pw the public words. Writes only arena cells and
            // scratch 0x00. Every cell word is below P, so an Fp2 product takes mul and one mod per
            // component. A coefficient only meets mulmod, and the stage checked every public word.

            // (a0 + a1 u)(b0 + b1 u), canonical operands.
            function f2mul(a0, a1, b0, b1) -> r0, r1 {
                r0 := mod(add(mul(a0, b0), mul(NON_RESIDUE, mul(a1, b1))), P)
                r1 := mod(add(mul(a0, b1), mul(a1, b0)), P)
            }

            function sqn(x, n) -> r {
                r := x
                for {} n { n := sub(n, 1) } { r := mulmod(r, r, P) }
            }

            // a^(P - 2), P - 2 = (2^31 - 1) 2^33 + (2^32 - 1), and x_k below is a^(2^k - 1).
            function fpinv(a) -> r {
                let x2 := mulmod(mulmod(a, a, P), a, P)
                let x3 := mulmod(mulmod(x2, x2, P), a, P)
                let x6 := mulmod(sqn(x3, 3), x3, P)
                let x12 := mulmod(sqn(x6, 6), x6, P)
                let x24 := mulmod(sqn(x12, 12), x12, P)
                let x30 := mulmod(sqn(x24, 6), x6, P)
                let x31 := mulmod(mulmod(x30, x30, P), a, P)
                let x32 := mulmod(mulmod(x31, x31, P), a, P)
                r := mulmod(sqn(x31, 33), x32, P)
            }

            // 1 / (a0 + a1 u) = (a0 - a1 u) / (a0^2 - 7 a1^2). Fp2 is a field, so a zero norm is a zero
            // element: refused with no data, the way the reference evaluator refuses it.
            function f2inv(a0, a1) -> r0, r1 {
                let n := mod(add(mul(a0, a0), sub(BIG, mul(NON_RESIDUE, mul(a1, a1)))), P)
                if iszero(n) { revert(0, 0) }
                let i := fpinv(n)
                r0 := mulmod(a0, i, P)
                r1 := mulmod(sub(P, a1), i, P)
            }

            // The image's constant table into the constant cells, one u64 c0, u64 c1 per cell.
            function constants(ih) {
                let p := add(ih, mload(add(ih, H_CONSTS_AT)))
                let cell := mload(add(ih, H_CONST_CELL))
                let end := add(cell, shl(6, mload(add(ih, H_N_CONST))))
                for {} lt(cell, end) { cell := add(cell, CELL) } {
                    let w := mload(p)
                    mstore(cell, shr(POINT_SHIFT, w))
                    mstore(add(cell, WORD), and(shr(CONST_C1_SHIFT, w), MASK64))
                    p := add(p, CONST_LEN)
                }
            }

            // The rest of an I_DOT's sum: the pairs of u24 cell addresses in [q, end), added to s0, s1
            // unreduced. A term is below 2^131 and there are at most 255, so the sums stay below 2^140.
            function dotTail(q, end, s0, s1) -> r0, r1 {
                for {} lt(q, end) { q := add(q, DOT_PAIR_LEN) } {
                    let v := mload(q)
                    let e := shr(DOT_A_SHIFT, v)
                    let f := and(shr(DOT_B_SHIFT, v), MASK24)
                    let e0 := mload(e)
                    let e1 := mload(add(e, WORD))
                    let f0 := mload(f)
                    let f1 := mload(add(f, WORD))
                    s0 := add(s0, add(mul(e0, f0), mul(NON_RESIDUE, mul(e1, f1))))
                    s1 := add(s1, add(mul(e0, f1), mul(e1, f0)))
                }
                r0 := s0
                r1 := s1
            }

            // The instruction stream, from pp to its END. Layout of the word an instruction starts:
            // kind at bits 248.., then the u24 cell addresses a, b, d and, fused, x. The compile checked
            // every address and kind, so none is checked here. Each instruction loads its operands before
            // it stores, so d may be the cell of an operand it consumes, x included.
            function stream(pp) {
                for {} 1 {} {
                    let w := mload(pp)
                    let a := and(shr(INS_A_SHIFT, w), MASK24)
                    let b := and(shr(INS_B_SHIFT, w), MASK24)
                    let a0 := mload(a)
                    let a1 := mload(add(a, WORD))
                    let b0 := mload(b)
                    let b1 := mload(add(b, WORD))
                    let d := and(shr(INS_D_SHIFT, w), MASK24)
                    switch shr(INS_KIND_SHIFT, w)
                    case 1 {
                        // I_MAC: d = x + a b
                        let x := and(shr(INS_X_SHIFT, w), MASK24)
                        let x1 := mload(add(x, WORD))
                        mstore(d, mod(add(add(mul(a0, b0), mul(NON_RESIDUE, mul(a1, b1))), mload(x)), P))
                        mstore(add(d, WORD), mod(add(add(mul(a0, b1), mul(a1, b0)), x1), P))
                        pp := add(pp, INS_FUSED_LEN)
                    }
                    case 2 {
                        // I_MUL: d = a b
                        mstore(d, mod(add(mul(a0, b0), mul(NON_RESIDUE, mul(a1, b1))), P))
                        mstore(add(d, WORD), mod(add(mul(a0, b1), mul(a1, b0)), P))
                        pp := add(pp, INS_LEN)
                    }
                    case 3 {
                        // I_SUB: d = a - b
                        mstore(d, addmod(a0, sub(P, b0), P))
                        mstore(add(d, WORD), addmod(a1, sub(P, b1), P))
                        pp := add(pp, INS_LEN)
                    }
                    case 8 {
                        // I_DOT: d = x + a b + sum of the pairs after it, one reduction at the end
                        let x := and(shr(INS_X_SHIFT, w), MASK24)
                        let s0 := add(add(mul(a0, b0), mul(NON_RESIDUE, mul(a1, b1))), mload(x))
                        let s1 := add(add(mul(a0, b1), mul(a1, b0)), mload(add(x, WORD)))
                        let q := add(pp, DOT_HEAD_LEN)
                        pp := add(q, mul(DOT_PAIR_LEN, sub(and(shr(DOT_N_SHIFT, w), MASK8), 1)))
                        s0, s1 := dotTail(q, pp, s0, s1)
                        mstore(d, mod(s0, P))
                        mstore(add(d, WORD), mod(s1, P))
                    }
                    case 4 {
                        // I_MSUB: d = x - a b, the product lifted by BIG, a multiple of P above it
                        let x := and(shr(INS_X_SHIFT, w), MASK24)
                        let x1 := mload(add(x, WORD))
                        mstore(d, mod(add(mload(x), sub(BIG, add(mul(a0, b0), mul(NON_RESIDUE, mul(a1, b1))))), P))
                        mstore(add(d, WORD), mod(add(x1, sub(BIG, add(mul(a0, b1), mul(a1, b0)))), P))
                        pp := add(pp, INS_FUSED_LEN)
                    }
                    case 5 {
                        // I_ADD: d = a + b
                        mstore(d, addmod(a0, b0, P))
                        mstore(add(d, WORD), addmod(a1, b1, P))
                        pp := add(pp, INS_LEN)
                    }
                    case 6 {
                        // I_MSUBR: d = a b - x
                        let x := and(shr(INS_X_SHIFT, w), MASK24)
                        let x1 := mload(add(x, WORD))
                        mstore(d, mod(add(add(mul(a0, b0), mul(NON_RESIDUE, mul(a1, b1))), sub(P, mload(x))), P))
                        mstore(add(d, WORD), mod(add(add(mul(a0, b1), mul(a1, b0)), sub(P, x1)), P))
                        pp := add(pp, INS_FUSED_LEN)
                    }
                    case 7 {
                        // I_INV: d = 1 / a
                        let r0, r1 := f2inv(a0, a1)
                        mstore(d, r0)
                        mstore(add(d, WORD), r1)
                        pp := add(pp, INS_LEN)
                    }
                    default {
                        // I_END
                        leave
                    }
                }
            }

            // sum_i alpha_i C_i, C_i the cell output i names. Each term is below 8 P and there are at
            // most 2^16, so the sums are reduced once, at the end.
            function transitions(ih, ca) -> s0, s1 {
                let p := add(ih, mload(add(ih, H_OUTS_AT)))
                let end := add(p, mul(OUT_LEN, mload(add(ih, H_N_OUT))))
                for {} lt(p, end) { p := add(p, OUT_LEN) } {
                    let v := shr(OUT_SHIFT, mload(p))
                    let v0 := mload(v)
                    let v1 := mload(add(v, WORD))
                    let a0 := mload(ca)
                    let a1 := mload(add(ca, WORD))
                    ca := add(ca, CELL)
                    s0 := add(s0, add(mulmod(a0, v0, P), mul(NON_RESIDUE, mulmod(a1, v1, P))))
                    s1 := add(s1, add(mulmod(a0, v1, P), mulmod(a1, v0, P)))
                }
                s0 := mod(s0, P)
                s1 := mod(s1, P)
            }

            // The transition part's pieces into the registers: reg holds H = z^t - 1, t = 2^logT, and
            // reg + CELL holds S E, S the transition sum and E = prod_k (z - e_k) over the exempt points.
            function transitionTerm(ih, ca, zc, reg) {
                let z0 := mload(zc)
                let z1 := mload(add(zc, WORD))
                let t0 := z0
                let t1 := z1
                for { let k := mload(add(ih, H_LOG_T)) } k { k := sub(k, 1) } {
                    let q0 := mod(add(mul(t0, t0), mul(NON_RESIDUE, mul(t1, t1))), P)
                    t1 := mulmod(add(t1, t1), t0, P)
                    t0 := q0
                }
                mstore(reg, addmod(t0, sub(P, 1), P))
                mstore(add(reg, WORD), t1)
                let e0 := 1
                let e1 := 0
                let p := add(ih, mload(add(ih, H_EXEMPT_AT)))
                let end := add(p, mul(POINT_LEN, mload(add(ih, H_N_EXEMPT))))
                for {} lt(p, end) { p := add(p, POINT_LEN) } {
                    e0, e1 := f2mul(e0, e1, addmod(z0, sub(P, shr(POINT_SHIFT, mload(p))), P), z1)
                }
                let s0, s1 := transitions(ih, ca)
                s0, s1 := f2mul(s0, s1, e0, e1)
                mstore(add(reg, CELL), s0)
                mstore(add(reg, add(CELL, WORD)), s1)
            }

            // One row group's sum S = sum_j alpha_j (f_j - v_j) over its constant entries, then its pin
            // entries. f - v is f0 + P - v in c0, below 2 P, and alpha meets it through mulmod. Returns S
            // reduced and the next group's start.
            function rowSum(p, ca, pw) -> s0, s1, q {
                let e := add(p, ROW_HEAD_LEN)
                let ce := add(e, mul(ENT_CONST_LEN, and(shr(ROW_NC_SHIFT, mload(p)), MASK8)))
                q := add(ce, mul(ENT_PIN_LEN, and(shr(ROW_NP_SHIFT, mload(p)), MASK8)))
                for {} lt(e, ce) { e := add(e, ENT_CONST_LEN) } {
                    let w := mload(e)
                    let f := shr(ENT_CELL_SHIFT, w)
                    let x0 := add(mload(f), sub(P, and(shr(ENT_VALUE_SHIFT, w), MASK64)))
                    let f1 := mload(add(f, WORD))
                    let al := add(ca, and(shr(ENT_ALPHA_SHIFT, w), MASK16))
                    let a0 := mload(al)
                    let a1 := mload(add(al, WORD))
                    s0 := add(s0, add(mulmod(a0, x0, P), mul(NON_RESIDUE, mulmod(a1, f1, P))))
                    s1 := add(s1, add(mulmod(a0, f1, P), mulmod(a1, x0, P)))
                }
                for {} lt(e, q) { e := add(e, ENT_PIN_LEN) } {
                    let w := mload(e)
                    let f := shr(ENT_CELL_SHIFT, w)
                    let x0 := add(mload(f), sub(P, mload(add(pw, and(shr(ENT_PUB_SHIFT, w), MASK16)))))
                    let f1 := mload(add(f, WORD))
                    let al := add(ca, and(shr(ENT_ALPHA_SHIFT, w), MASK16))
                    let a0 := mload(al)
                    let a1 := mload(add(al, WORD))
                    s0 := add(s0, add(mulmod(a0, x0, P), mul(NON_RESIDUE, mulmod(a1, f1, P))))
                    s1 := add(s1, add(mulmod(a0, f1, P), mulmod(a1, x0, P)))
                }
                s0 := mod(s0, P)
                s1 := mod(s1, P)
            }

            // One row's S conj(d) and n, where d = z - x = d0 + z1 u, conj(d) = d0 - z1 u and
            // n = d conj(d) = d0^2 - 7 z1^2, so S / d = S conj(d) / n. Scratch word 0x00 holds 7 z1^2.
            function rowTerm(p, ca, pw, zc) -> p0, p1, n, q {
                let s0, s1
                s0, s1, q := rowSum(p, ca, pw)
                let z1 := mload(add(zc, WORD))
                let d0 := addmod(mload(zc), sub(P, shr(POINT_SHIFT, mload(p))), P)
                n := mod(add(mul(d0, d0), sub(P, mload(0x00))), P)
                p0 := mod(add(mul(s0, d0), sub(BIG, mul(NON_RESIDUE, mul(s1, z1)))), P)
                p1 := mod(add(mul(s1, d0), sub(BIG, mul(s0, z1))), P)
            }

            // sum_r S_r / (z - x_r) as one fraction N / D, D in Fp: per row N <- N n + S conj(d) D and
            // D <- D n. D is zero when some z - x_r is, and the final inversion refuses it.
            function boundaries(ih, ca, pw, zc) -> n0, n1, dd {
                let z1 := mload(add(zc, WORD))
                mstore(0x00, mulmod(NON_RESIDUE, mulmod(z1, z1, P), P))
                let p := add(ih, mload(add(ih, H_ROWS_AT)))
                dd := 1
                for { let r := mload(add(ih, H_N_ROWS)) } r { r := sub(r, 1) } {
                    let p0, p1, n, q := rowTerm(p, ca, pw, zc)
                    p := q
                    n0 := mod(add(mul(n0, n), mul(p0, dd)), P)
                    n1 := mod(add(mul(n1, n), mul(p1, dd)), P)
                    dd := mulmod(dd, n, P)
                }
            }

            // comp_z = S E / H + N / D = (S E D + N H) / (H D), one inversion for both parts.
            function combine(reg, n0, n1, dd) -> r0, r1 {
                let u0, u1 := f2mul(n0, n1, mload(reg), mload(add(reg, WORD)))
                let v0 := addmod(mulmod(mload(add(reg, CELL)), dd, P), u0, P)
                let v1 := addmod(mulmod(mload(add(reg, add(CELL, WORD))), dd, P), u1, P)
                let i0, i1 := f2inv(mulmod(mload(reg), dd, P), mulmod(mload(add(reg, WORD)), dd, P))
                r0, r1 := f2mul(v0, v1, i0, i1)
            }

            constants(img)
            stream(add(img, mload(add(img, H_STREAM_AT))))
            let zc := mload(add(img, H_Z_CELL))
            let reg := mload(add(img, H_REG_CELL))
            transitionTerm(img, alphas, zc, reg)
            let n0, n1, dd := boundaries(img, alphas, publics, zc)
            c0, c1 := combine(reg, n0, n1, dd)
        }
    }
}

/// @notice The slot map of the program in `spec/program-form`, from `gen_program_air.py`.
library ProfSlots {
    /// @notice keccak256 of the transition part the slots were assigned for.
    bytes32 internal constant TAPE_HASH = 0x5a953e9d83271782ca673a7ac5b2d8f8e278dcad780ef74b62a2a9b3065a08e6;
    /// @notice Slot cells the program takes: the most computed values live at once.
    uint256 internal constant N_SLOTS = 64;
    /// @notice One byte per op: the slot of the value it writes, 0xff where it writes none.
    bytes internal constant SLOTS =
        hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        hex"ffffffffffffffffffffffffff00010203ff04ff050600ff06ff070801ff08ff090a02ff0aff0b0c03ff0cff0d0e0eff"
        hex"0fff101111ff12ff131414ff15ff161717ffff18ffff18ffff18ffff18ffff18ffff18ffff18ffff18ffffffffffffff"
        hex"ffffffffffffffffff19ffffffffffffffffffffffffffffffff1affffffffffffffffffffffffffffffff1bffffffff"
        hex"ffffffffffffffffffffffff1cffffffffffffffffffffffffffffffff1dffffffffffffffffffffffffffffffff1eff"
        hex"ffffffffffffffffffffffffffffff1718191a1b1c1d1e17141411110e0e0303ff18ff19ff1aff1bff1cff1dff1eff17"
        hex"ff04ff06ff08ff0aff0cff0fff12ff15ff05ff07ff09ff0bff0dff10ff13ff16ff14ff11ff0eff03ff02020101010000"
        hex"00ff1f1f2020ff18ff19ff1aff1bff1cff201fff201fff1f201f0001ff18ff19ff1aff1b0100ff0100ff0001001f20ff"
        hex"18ff19ff1aff1b201f0001ff02ff212220ff22ff23241fff24ff252600ff26ff272801ff28ff292a2aff2bff2c2d2dff"
        hex"2eff2f3030ff31ff323333ffffffffffffffffffffffffffffff34ffffffffffffffffffffffffffffff35ffffffffff"
        hex"ffffffffffffffffffff36ffffffffffffffffffffffffffffff37ffffffffffffffffffffffffffffff38ffffffffff"
        hex"ffffffffffffffffffff39ffffffffffffffffffffffffffffff3affffffffffffffffffffffffffffff333435363738"
        hex"393a3330302d2d2a2a0101ff18ff19ff1aff1bff1cff1dff1eff17ff04ff06ff08ff0aff0cff0fff12ff15ff05ff07ff"
        hex"09ff0bff0dff10ff13ff16ff14ff11ff0eff03012a012a2d30ff2d2aff2a0130322fff322fff2f010130302aff2a32ff"
        hex"322f2f2d2d2c292725ff18ff19ff1aff1bff1cff1dff1eff17ff04ff06ff252527272929292c2c2c2d2fff2d2cff2c2d"
        hex"2c2727ff272525ff2527272525ff2c2cff2d2d29ff2fff2f2fff2929ff18ff19ff1aff1bff1cff1dff29ff2f2d2dff2c"
        hex"ff252727ff32ff2a3030ff01ff232121ff31ff2e2b2bff28ff262424ff22ff023333ff3aff393838ffffffffffffffff"
        hex"ffffffffffffff37ffffffffffffffffffffffffffffff36ffffffffffffffffffffffffffffff35ffffffffffffffff"
        hex"ffffffffffffff34ffffffffffffffffffffffffffffff00ffffffffffffffffffffffffffffff1fffffffffffffffff"
        hex"ffffffffffffff20ffffffffffffffffffffffffffffff383333ff3324ff243333ff24243333ff332bff2b3333ff2b2b"
        hex"3333ff3321ff213333ff21213333ff3330ff303333ff30303333ff3337ff373333ff37370000ff0036ff360000ff3636"
        hex"1f1fff1f35ff351f1fff35352020ff2034ff342020ff34343838201f1f2020ff2020200000ff0000003333ff33333327"
        hex"27ff2727272d3b3b2d2dff2d2d2d3c3cff3c3c3cff18ff19ff1aff1bff1cff1dff1eff17ff04ff06ff08ff0aff0cff0f"
        hex"ff12ff15ff05ff07ff09ff0bff0dff10ff13ff16ff14ff11ff0eff03ff33ff27ff3bff2dff3cff00ff201f1fff39ff02"
        hex"2626ff2eff232a2aff25ff2f3a3aff22ff283131ff01ff322c2cff29ff383434ff35ff363737ffffffffffffffffffff"
        hex"ffffffffff30ffffffffffffffffffffffffffffff21ffffffffffffffffffffffffffffff2bffffffffffffffffffff"
        hex"ffffffffff24ffffffffffffffffffffffffffffff3dffffffffffffffffffffffffffffff3effffffffffffffffffff"
        hex"ffffffffff3fffffffffffffffffffffffffffffff373434ff342cff2c3434ff2c2c3434ff3431ff313434ff31313434"
        hex"ff343aff3a3434ff3a3a3434ff342aff2a3434ff2a2a3434ff3430ff303434ff30303d3dff3d21ff213d3dff21213e3e"
        hex"ff3e2bff2b3e3eff2b2b3f3fff3f24ff243f3fff24243737ff18ff19ff1aff1bff1cff1dff1eff17ff04ff06ff08ff0a"
        hex"ff0cff0fff12ff15ff05ff07ff09ff0bff0dff10ff13ff16ff14ff36ff383232ff28ff2f2323ff02ff203535ff29ff01"
        hex"2222ff25ff2e3939ff00ff372424ff2bff213030ff2aff3a3131ffffffffffffffffffffffffffffff2cffffffffffff"
        hex"ffffffffffffffffff3fffffffffffffffffffffffffffffff3effffffffffffffffffffffffffffff3dffffffffffff"
        hex"ffffffffffffffffff34ffffffffffffffffffffffffffffff26ffffffffffffffffffffffffffffff1fffffffffffff"
        hex"ffffffffffffffffff313030ff3024ff243030ff24243030ff3039ff393030ff39393030ff3022ff223030ff22223030"
        hex"ff3035ff353030ff35353030ff302cff2c3030ff2c2c3434ff343fff3f3434ff3f3f2626ff263eff3e2626ff3e3e1f1f"
        hex"ff1f3dff3d1f1fff3d3d3131ff18ff19ff1aff1bff1cff1dff1eff17ff04ff06ff08ff0aff0cff0fff12ff15ff05ff07"
        hex"ff09ff0bff0dff10ff13ff16ff14ff3aff213737ff2eff012020ff2fff382a2aff2bff002525ff29ff022828ff36ff31"
        hex"3d3dff3eff3f2c2cff35ff223939ffffffffffffffffffffffffffffff24ffffffffffffffffffffffffffffff1fffff"
        hex"ffffffffffffffffffffffffff26ffffffffffffffffffffffffffffff34ffffffffffffffffffffffffffffff30ffff"
        hex"ffffffffffffffffffffffffff23ffffffffffffffffffffffffffffff32ffffffffffffffffffffffffffffff392c2c"
        hex"ff2c3dff3d2c2cff3d3d2c2cff2c28ff282c2cff28282c2cff2c25ff252c2cff25252c2cff2c2aff2a2c2cff2a2a2c2c"
        hex"ff2c24ff242c2cff24243030ff301fff1f3030ff1f1f2323ff2326ff262323ff26263232ff3234ff343232ff34343939"
        hex"ff18ff19ff1aff1bff1cff1dff1eff17ff04ff06ff08ff0aff0cff0fff12ff15ff05ff07ff09ff0bff0dff10ff13ff16"
        hex"ff14223fff223fff3f2222223f3f3f3102ff18ff19ff1aff1b02ff023131ff3fff02ff222200ff000038ff38ff380101"
        hex"ff18ff19ff1aff1bff1cff1dff1e01ff013838ff00ff01ff222202ff02023fff3fff3f3131ff18ff19ff1aff1bff1cff"
        hex"1dff1effff31ff3fff0222ff2201ff0100ff00ff313131ff383838ff3f3f3fff313131ff020202ff3f3f3fff222222ff"
        hex"020202ff010101ff222222ff000000ff01010122ff22ff023fff3f31ff3138ff3821ff21ff222222ff353535ff020202"
        hex"ff222222ff3f3f3fff020202ff313131ff3f3f3fff383838ff313131ff212121ff38383831ff313fff3f02ff0222ff22"
        hex"35ff353eff3eff313131ff363636ff3f3f3fff313131ff020202ff3f3f3fff222222ff020202ff353535ff222222ff3e"
        hex"3e3eff35353522ff2202ff02ff222222ff3f3f3fff020202ff22222201ff010138ff383835ff353522ff2202223eff22";
}
