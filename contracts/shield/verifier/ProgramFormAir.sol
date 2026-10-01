// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.24;

/// @notice The composition of a program-form circuit at z:
///         sum_i alpha_i C_i(z) E(z) / (z^t - 1) + sum_j alpha_{nOut+j} (frame[col_j] - v_j) / (z - g^row_j).
/// @dev `compile` checks a program blob once and lowers it to an image, and `stage*` and `run*` run
///      it in Fp2 = Fp[u]/(u^2 - 7), every kept value below P. The calldata and memory interpreters
///      differ only in how they load coefficients and public words. Blob format: docs/07-constraints.md.
library ProgramFormAir {
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
    /// @dev The same two challenges limb by limb: beta.c0, beta.c1, gamma.c0, gamma.c1, each an
    ///      Fp2 with c1 zero, for a circuit whose product constraint is written in pair arithmetic.
    uint256 internal constant N_CHALLENGES_SPLIT = 4;

    // ------------------------------------------------------------------ arena
    // One 64-byte cell per value, c0 then c1: frame | periodic | beta | gamma | z | 2 registers |
    // constants | slots. A split program has four challenge cells, one point word and a zero each,
    // before z. A slot cell is reused once its value is read for the last time.

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
    /// @notice A program may read two challenge inputs or four, no other count.
    error BadChallengeCount();
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
        uint256 nChal; // challenge inputs: N_CHALLENGES or N_CHALLENGES_SPLIT
        uint256 opsAt;
        uint256 outsAt;
        uint256 rowsAt;
        uint256 bndAt;
    }

    /// @dev Per op, packed: kind | a << 8 | b << 24 | blob offset << 40. For a constant `a` is its
    ///      ordinal among the constants, for an input the input index.
    uint256 private constant OPK_A = 8;
    uint256 private constant OPK_B = 24;
    uint256 private constant OPK_AT = 40;

    /// @dev Per op, packed: live reads | last reader << 16 | slot << 32 | fused << 48 |
    ///      chained << 49. A last reader of `nOps` is the output list. A slot of NO_SLOT is none.
    uint256 private constant INF_LAST = 16;
    uint256 private constant INF_SLOT = 32;
    uint256 private constant INF_FUSED = 48;
    uint256 private constant INF_CHAINED = 49;

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

    /// @notice Check `prog` and lower it to an image whose arena starts at `arena`.
    /// @param slots one byte per op, the slot of each value that needs one and NO_SLOT for the rest,
    ///        as `gen_program_air.py` assigns them, or empty to assign them here by the same rule.
    function compile(bytes memory prog, bytes memory slots, uint256 arena) internal pure returns (bytes memory image) {
        return compile(prog, slots, arena, N_CHALLENGES);
    }

    /// @notice {compile} for a program reading `nChal` challenge inputs, N_CHALLENGES or N_CHALLENGES_SPLIT.
    function compile(bytes memory prog, bytes memory slots, uint256 arena, uint256 nChal)
        internal
        pure
        returns (bytes memory image)
    {
        if (nChal != N_CHALLENGES && nChal != N_CHALLENGES_SPLIT) revert BadChallengeCount();
        (Blob memory b, uint256[] memory op) = _parse(prog, nChal);
        uint256[] memory inf = _liveness(prog, b, op);
        Layout memory l = _slots(b, op, inf, slots);
        _place(b, l, arena);
        image = _emit(prog, b, op, inf, l);
    }

    /// @notice Bytes the arena of `prog` can take at most, for a caller that must reserve it first.
    function arenaBound(bytes memory prog) internal pure returns (uint256) {
        uint256 nOps = _rd(prog, 0, 2);
        return CELL * (_rd(prog, 8, 2) + _rd(prog, 10, 2) + N_CHALLENGES + 1 + N_REGISTERS + nOps);
    }

    function _parse(bytes memory prog, uint256 nChal) private pure returns (Blob memory b, uint256[] memory op) {
        b.nChal = nChal;
        b.nOps = _rd(prog, 0, 2);
        b.nOut = _rd(prog, 2, 2);
        b.nBnd = _rd(prog, 4, 2);
        b.nRows = _rd(prog, 6, 2);
        b.nFrame = _rd(prog, 8, 2);
        b.nPer = _rd(prog, 10, 2);
        b.logT = _rd(prog, 12, 1);
        b.nEx = _rd(prog, 13, 1);
        b.opsAt = BLOB_HEADER + POINT_LEN * b.nEx;
        uint256 nIn = b.nFrame + b.nPer + nChal;
        op = new uint256[](b.nOps);
        uint256 p = b.opsAt;
        for (uint256 i = 0; i < b.nOps; ++i) {
            uint256 k = _rd(prog, p, 1);
            uint256 x;
            uint256 y;
            if (k == OP_CONST) {
                if (_rd(prog, p + 1, 8) >= P || _rd(prog, p + 9, 8) >= P) revert ConstantNotCanonical(i);
                x = b.nConst++;
                p += OP_CONST_LEN;
            } else if (k == OP_INPUT) {
                x = _rd(prog, p + 1, 2);
                if (x >= nIn) revert BadOperand(i);
                p += OP_UNARY_LEN;
            } else if (k == OP_INV) {
                x = _rd(prog, p + 1, 2);
                y = x;
                if (x >= i) revert BadOperand(i);
                p += OP_UNARY_LEN;
            } else if (k == OP_ADD || k == OP_SUB || k == OP_MUL) {
                x = _rd(prog, p + 1, 2);
                y = _rd(prog, p + 3, 2);
                if (x >= i || y >= i) revert BadOperand(i);
                p += OP_BINARY_LEN;
            } else {
                revert BadOp(i);
            }
            op[i] = k | (x << OPK_A) | (y << OPK_B) | ((p - _len(k)) << OPK_AT);
        }
        b.outsAt = p;
        b.rowsAt = p + 2 * b.nOut;
        b.bndAt = b.rowsAt + POINT_LEN * b.nRows;
        p = b.bndAt;
        for (uint256 j = 0; j < b.nBnd; ++j) {
            uint256 src = _rd(prog, p + 3, 1);
            if (src == 0) p += BND_CONST_SRC_LEN;
            else if (src == 1) p += BND_PIN_SRC_LEN;
            else revert BadBoundary(j);
        }
        if (p > prog.length) revert BlobTruncated();
        if (p != prog.length) revert BlobTrailing();
        if (b.nOut + b.nBnd > ALPHA_LIMIT) revert TooManyCoefficients();
    }

    function _len(uint256 k) private pure returns (uint256) {
        if (k == OP_CONST) return OP_CONST_LEN;
        if (k == OP_INPUT || k == OP_INV) return OP_UNARY_LEN;
        return OP_BINARY_LEN;
    }

    /// @dev Walks the ops backward: counts the reads of each live value and its last reader, marks a
    ///      multiply read once by the add or subtract right after it as fused, and marks runs of fused
    ///      adds as chained, one I_DOT each.
    function _liveness(bytes memory prog, Blob memory b, uint256[] memory op) private pure returns (uint256[] memory inf) {
        uint256 n = b.nOps;
        inf = new uint256[](n);
        for (uint256 i = 0; i < b.nOut; ++i) {
            uint256 o = _rd(prog, b.outsAt + 2 * i, 2);
            if (o >= n) revert BadOutput(i);
            inf[o] = _read(inf[o], n);
        }
        for (uint256 i = n; i > 0;) {
            --i;
            uint256 k = op[i] & MASK8;
            if (k < OP_ADD) continue;
            if (inf[i] & MASK16 == 0 && k != OP_INV) continue;
            uint256 a = (op[i] >> OPK_A) & MASK16;
            inf[a] = _read(inf[a], i);
            if (k != OP_INV) {
                uint256 c = (op[i] >> OPK_B) & MASK16;
                inf[c] = _read(inf[c], i);
            }
        }
        for (uint256 i = 0; i + 1 < n; ++i) {
            if (op[i] & MASK8 != OP_MUL || inf[i] & MASK16 != 1) continue;
            uint256 nx = op[i + 1];
            uint256 k = nx & MASK8;
            if ((k != OP_ADD && k != OP_SUB) || inf[i + 1] & MASK16 == 0) continue;
            if ((nx >> OPK_A) & MASK16 == i || (nx >> OPK_B) & MASK16 == i) inf[i] |= 1 << INF_FUSED;
        }
        for (uint256 i = 1; i + 2 < n; ++i) {
            if (!_mac(op, inf, i) || !_mac(op, inf, i + 2) || inf[i] & MASK16 != 1) continue;
            uint256 nx = op[i + 2];
            if ((nx >> OPK_A) & MASK16 == i || (nx >> OPK_B) & MASK16 == i) inf[i] |= 1 << INF_CHAINED;
        }
    }

    /// @dev Op i is x + a b: an add the multiply right before it is fused into.
    function _mac(uint256[] memory op, uint256[] memory inf, uint256 i) private pure returns (bool) {
        return op[i] & MASK8 == OP_ADD && _fused(inf[i - 1]);
    }

    /// @dev One more live read of a value. The first one seen walking backward is its last reader.
    function _read(uint256 w, uint256 reader) private pure returns (uint256) {
        if (w & MASK16 == 0) w |= reader << INF_LAST;
        return w + 1;
    }

    function _live(uint256 w, uint256 kind) private pure returns (bool) {
        return w & MASK16 != 0 || kind == OP_INV;
    }

    function _fused(uint256 w) private pure returns (bool) {
        return (w >> INF_FUSED) & 1 == 1;
    }

    function _chained(uint256 w) private pure returns (bool) {
        return (w >> INF_CHAINED) & 1 == 1;
    }

    /// @dev Op i ends an instruction: a live add, subtract, multiply or inversion, not folded into
    ///      the next op.
    function _ends(uint256[] memory op, uint256[] memory inf, uint256 i) private pure returns (bool) {
        uint256 k = op[i] & MASK8;
        return k >= OP_ADD && _live(inf[i], k) && !_fused(inf[i]) && !_chained(inf[i]);
    }

    function _lastReader(uint256 w) private pure returns (uint256) {
        return (w >> INF_LAST) & MASK16;
    }

    /// @dev A slot for every value an instruction writes, by the rule of `gen_program_air.py`: free the
    ///      slots of operands read for the last time, then take the most recently freed slot or a new
    ///      one. The map is not trusted: `_emit` checks every read against the owner of its cell.
    function _slots(Blob memory b, uint256[] memory op, uint256[] memory inf, bytes memory map)
        private
        pure
        returns (Layout memory l)
    {
        uint256 n = b.nOps;
        bool given = map.length != 0;
        if (given && map.length != n) revert BadSlot(n);
        uint256[] memory free = new uint256[](n);
        uint256 top;
        for (uint256 i = 0; i < n; ++i) {
            if (!_ends(op, inf, i)) {
                inf[i] |= NO_SLOT << INF_SLOT;
                continue;
            }
            uint256 s;
            if (given) {
                s = uint8(map[i]);
                if (s == NO_SLOT) revert BadSlot(i);
            } else {
                uint256[] memory rd = _operands(op, inf, i);
                for (uint256 r = 0; r < rd.length; ++r) {
                    uint256 v = rd[r];
                    if (_seen(rd, r) || (inf[v] >> INF_SLOT) & MASK16 == NO_SLOT) continue;
                    if (_lastReader(inf[v]) <= i) free[top++] = (inf[v] >> INF_SLOT) & MASK16;
                }
                s = top > 0 ? free[--top] : l.nSlots;
                if (s == NO_SLOT) revert BadSlot(i);
                if (inf[i] & MASK16 == 0) free[top++] = s; // an inversion nothing reads
            }
            if (s >= l.nSlots) l.nSlots = s + 1;
            inf[i] |= s << INF_SLOT;
        }
    }

    /// @dev The values the instruction ending at op i reads. Plain: a, b (b = a for an
    ///      inversion). Fused or chained: each multiply's a and b in program order, then x, the
    ///      addend of the run's first add.
    function _operands(uint256[] memory op, uint256[] memory inf, uint256 i) private pure returns (uint256[] memory rd) {
        if (i == 0 || !_fused(inf[i - 1])) {
            rd = new uint256[](2);
            rd[0] = (op[i] >> OPK_A) & MASK16;
            rd[1] = (op[i] >> OPK_B) & MASK16;
            return rd;
        }
        uint256 head = i;
        while (head >= 3 && _chained(inf[head - 2])) head -= 2;
        uint256 n = (i - head) / 2 + 1;
        rd = new uint256[](2 * n + 1);
        for (uint256 t = 0; t < n; ++t) {
            uint256 m = head + 2 * t - 1;
            rd[2 * t] = (op[m] >> OPK_A) & MASK16;
            rd[2 * t + 1] = (op[m] >> OPK_B) & MASK16;
        }
        uint256 x = (op[head] >> OPK_A) & MASK16;
        rd[2 * n] = x == head - 1 ? (op[head] >> OPK_B) & MASK16 : x;
    }

    /// @dev rd[r] appears earlier in rd.
    function _seen(uint256[] memory rd, uint256 r) private pure returns (bool) {
        for (uint256 q = 0; q < r; ++q) {
            if (rd[q] == rd[r]) return true;
        }
        return false;
    }

    function _place(Blob memory b, Layout memory l, uint256 arena) private pure {
        l.arena = arena;
        l.zCell = arena + CELL * (b.nFrame + b.nPer + b.nChal);
        l.regCell = l.zCell + CELL;
        l.constCell = l.regCell + CELL * N_REGISTERS;
        l.slotCell = l.constCell + CELL * b.nConst;
        l.end = l.slotCell + CELL * l.nSlots;
        if (l.end > ADDRESS_LIMIT) revert ArenaTooLarge();
    }

    /// @dev The cell value v lives in once written, or zero for a value that never has one.
    function _cell(Blob memory b, Layout memory l, uint256[] memory op, uint256[] memory inf, uint256 v)
        private
        pure
        returns (uint256)
    {
        uint256 k = op[v] & MASK8;
        uint256 a = (op[v] >> OPK_A) & MASK16;
        if (k == OP_INPUT) return a < b.nFrame + b.nPer + b.nChal ? l.arena + CELL * a : 0;
        if (k == OP_CONST) return l.constCell + CELL * a;
        uint256 s = (inf[v] >> INF_SLOT) & MASK16;
        return s == NO_SLOT ? 0 : l.slotCell + CELL * s;
    }

    /// @dev Emit state: the image, the write cursor, and who owns each slot cell (value + 1).
    struct Out {
        bytes image;
        uint256 at;
        uint256[] owner;
    }

    function _emit(bytes memory prog, Blob memory b, uint256[] memory op, uint256[] memory inf, Layout memory l)
        private
        pure
        returns (bytes memory)
    {
        Out memory o;
        uint256 bound = HEADER_BYTES + CONST_LEN * b.nConst + INS_FUSED_LEN * b.nOps + INS_END_LEN + OUT_LEN * b.nOut
            + POINT_LEN * b.nEx + ROW_HEAD_LEN * b.nRows + ENT_CONST_LEN * b.nBnd;
        o.image = new bytes(bound + WORD);
        o.owner = new uint256[](l.nSlots);
        o.at = HEADER_BYTES;

        _word(o, H_N_FRAME, b.nFrame);
        _word(o, H_N_PER, b.nPer);
        _word(o, H_N_ALPHA, b.nOut + b.nBnd);
        _word(o, H_LOG_T, b.logT);
        _word(o, H_ARENA, l.arena);
        _word(o, H_Z_CELL, l.zCell);
        _word(o, H_REG_CELL, l.regCell);
        _word(o, H_CONST_CELL, l.constCell);
        _word(o, H_ARENA_END, l.end);

        _word(o, H_CONSTS_AT, o.at);
        _word(o, H_N_CONST, b.nConst);
        for (uint256 i = 0; i < b.nOps; ++i) {
            if (op[i] & MASK8 != OP_CONST) continue;
            uint256 at = op[i] >> OPK_AT;
            _put(o, _rd(prog, at + 1, 8), 8);
            _put(o, _rd(prog, at + 9, 8), 8);
        }

        _word(o, H_STREAM_AT, o.at);
        for (uint256 i = 0; i < b.nOps; ++i) {
            if (_ends(op, inf, i)) _instruction(o, b, l, op, inf, i);
        }
        _put(o, I_END, 1);

        _word(o, H_OUTS_AT, o.at);
        _word(o, H_N_OUT, b.nOut);
        for (uint256 i = 0; i < b.nOut; ++i) {
            uint256 v = _rd(prog, b.outsAt + 2 * i, 2);
            _put(o, _resident(o, b, l, op, inf, v, i), 3);
        }

        _word(o, H_EXEMPT_AT, o.at);
        _word(o, H_N_EXEMPT, b.nEx);
        for (uint256 i = 0; i < b.nEx; ++i) {
            uint256 x = _rd(prog, BLOB_HEADER + POINT_LEN * i, 8);
            if (x >= P) revert PointNotCanonical();
            _put(o, x, 8);
        }

        _word(o, H_ROWS_AT, o.at);
        _word(o, H_N_ROWS, b.nRows);
        (uint256 nPub, uint256 pins) = _rows(o, prog, b, l);
        _word(o, H_N_PUB, nPub);
        _word(o, H_PINS, pins);
        _word(o, H_SIZE, o.at);
        bytes memory image = o.image;
        uint256 size = o.at;
        assembly {
            mstore(image, size)
        }
        return image;
    }

    /// @dev One instruction, its operands checked resident and its result's slot taken.
    function _instruction(Out memory o, Blob memory b, Layout memory l, uint256[] memory op, uint256[] memory inf, uint256 i)
        private
        pure
    {
        uint256[] memory rd = _operands(op, inf, i);
        uint256 n = (rd.length - 1) / 2; // multiplies: 0 plain (2 operands), 1 fused, more a dot
        if (n > DOT_LIMIT) revert BadOp(i);
        uint256 k = op[i] & MASK8;
        uint256 kind;
        if (n > 1) kind = I_DOT;
        else if (n == 1 && k == OP_ADD) kind = I_MAC;
        else if (n == 1) kind = ((op[i] >> OPK_B) & MASK16) == i - 1 ? I_MSUB : I_MSUBR;
        else if (k == OP_MUL) kind = I_MUL;
        else if (k == OP_SUB) kind = I_SUB;
        else if (k == OP_ADD) kind = I_ADD;
        else kind = I_INV;
        uint256[] memory cell = new uint256[](rd.length);
        for (uint256 r = 0; r < rd.length; ++r) {
            cell[r] = _resident(o, b, l, op, inf, rd[r], i);
        }
        uint256 s = (inf[i] >> INF_SLOT) & MASK16;
        if (s >= l.nSlots) revert BadSlot(i);
        o.owner[s] = i + 1;
        _put(o, kind, 1);
        _put(o, cell[0], 3);
        _put(o, cell[1], 3);
        _put(o, l.slotCell + CELL * s, 3);
        if (n == 0) return;
        _put(o, cell[2 * n], 3);
        if (n == 1) return;
        _put(o, n, 1);
        for (uint256 t = 1; t < n; ++t) {
            _put(o, cell[2 * t], 3);
            _put(o, cell[2 * t + 1], 3);
        }
    }

    /// @dev The cell of value v, which instruction `at` reads. Reverts unless v is still in it.
    function _resident(Out memory o, Blob memory b, Layout memory l, uint256[] memory op, uint256[] memory inf, uint256 v, uint256 at)
        private
        pure
        returns (uint256 c)
    {
        c = _cell(b, l, op, inf, v);
        if (c == 0) revert NotResident(at);
        if (c >= l.slotCell && o.owner[(c - l.slotCell) / CELL] != v + 1) revert NotResident(at);
    }

    /// @dev The boundaries grouped by row, rows in the blob's order and each row's constants then
    ///      its pins, each in draw order. Returns the count of public words the pins need and the
    ///      set of words they pin, bit k for word k.
    function _rows(Out memory o, bytes memory prog, Blob memory b, Layout memory l)
        private
        pure
        returns (uint256 nPub, uint256 pins)
    {
        uint256[] memory nc = new uint256[](b.nRows);
        uint256[] memory np = new uint256[](b.nRows);
        uint256 p = b.bndAt;
        for (uint256 j = 0; j < b.nBnd; ++j) {
            uint256 col = _rd(prog, p, 1);
            uint256 r = _rd(prog, p + 1, 2);
            if (col >= b.nFrame || r >= b.nRows) revert BadBoundary(j);
            if (_rd(prog, p + 3, 1) == 0) {
                if (_rd(prog, p + 4, 8) >= P) revert BadBoundary(j);
                ++nc[r];
                p += BND_CONST_SRC_LEN;
            } else {
                uint256 k = _rd(prog, p + 4, 1);
                if (k + 1 > nPub) nPub = k + 1;
                pins |= 1 << k;
                ++np[r];
                p += BND_PIN_SRC_LEN;
            }
        }
        // group heads, and the cursor each row's constants and pins are written at
        for (uint256 r = 0; r < b.nRows; ++r) {
            if (nc[r] > ROW_ENTRY_LIMIT || np[r] > ROW_ENTRY_LIMIT) revert RowTooWide(r);
            uint256 x = _rd(prog, b.rowsAt + POINT_LEN * r, 8);
            if (x >= P) revert PointNotCanonical();
            _put(o, x, 8);
            _put(o, nc[r], 1);
            _put(o, np[r], 1);
            uint256 c = o.at;
            o.at += ENT_CONST_LEN * nc[r] + ENT_PIN_LEN * np[r];
            np[r] = c + ENT_CONST_LEN * nc[r];
            nc[r] = c;
        }
        uint256 end = o.at;
        p = b.bndAt;
        for (uint256 j = 0; j < b.nBnd; ++j) {
            uint256 cell = l.arena + CELL * _rd(prog, p, 1);
            uint256 r = _rd(prog, p + 1, 2);
            uint256 alpha = CELL * (b.nOut + j);
            if (_rd(prog, p + 3, 1) == 0) {
                o.at = nc[r];
                _put(o, cell, 3);
                _put(o, alpha, 2);
                _put(o, _rd(prog, p + 4, 8), 8);
                nc[r] = o.at;
                p += BND_CONST_SRC_LEN;
            } else {
                o.at = np[r];
                _put(o, cell, 3);
                _put(o, alpha, 2);
                _put(o, WORD * _rd(prog, p + 4, 1), 2);
                np[r] = o.at;
                p += BND_PIN_SRC_LEN;
            }
        }
        o.at = end;
    }

    /// @dev Big-endian unsigned read of n <= 32 bytes at `at`.
    function _rd(bytes memory s, uint256 at, uint256 n) private pure returns (uint256 v) {
        if (at + n > s.length) revert BlobTruncated();
        assembly {
            v := shr(sub(256, shl(3, n)), mload(add(add(s, WORD), at)))
        }
    }

    /// @dev Big-endian write of the low n bytes of v at the cursor. The image has a word of slack
    ///      past its bound, so the read-modify-write of one word never leaves the allocation.
    function _put(Out memory o, uint256 v, uint256 n) private pure {
        bytes memory img = o.image;
        uint256 at = o.at;
        assembly {
            let ptr := add(add(img, WORD), at)
            let bits := shl(3, n)
            mstore(ptr, or(and(mload(ptr), shr(bits, not(0))), shl(sub(256, bits), v)))
        }
        o.at = at + n;
    }

    function _word(Out memory o, uint256 field, uint256 v) private pure {
        bytes memory img = o.image;
        assembly {
            mstore(add(add(img, WORD), field), v)
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
            let zc := mload(add(img, H_Z_CELL))
            switch sub(zc, beta)
            case 0x80 { calldatacopy(beta, point, POINT_BYTES) }
            default {
                // split: four cells of one point word and a zero, then z from words 4 and 5
                for { let i := 0 } lt(i, 4) { i := add(i, 1) } {
                    mstore(add(beta, shl(6, i)), calldataload(add(point, shl(5, i))))
                    mstore(add(add(beta, shl(6, i)), WORD), 0)
                }
                calldatacopy(zc, add(point, 0x80), CELL)
            }
            // invariant: every cell word is compared, two per step, over a whole number of cells
            ok := 1
            let end := add(zc, CELL)
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
            let zc := mload(add(img, H_Z_CELL))
            switch sub(zc, beta)
            case 0x80 { copy(beta, point, POINT_BYTES) }
            default {
                for { let i := 0 } lt(i, 4) { i := add(i, 1) } {
                    mstore(add(beta, shl(6, i)), mload(add(point, shl(5, i))))
                    mstore(add(add(beta, shl(6, i)), WORD), 0)
                }
                copy(zc, add(point, 0x80), CELL)
            }
            ok := 1
            let end := add(zc, CELL)
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
library ProgramFormSlots {
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
