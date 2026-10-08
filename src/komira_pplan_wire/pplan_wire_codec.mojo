# =============================================================================
# pplan_wire_codec.mojo — a PHYSICAL collect plan to BYTES and back.
# =============================================================================
#
# THE ASSERTION THIS EXISTS TO MAKE TRUE:
#
#     (ParquetSourceData, Slab[MorselOp]) -> bytes -> (ParquetSourceData', Slab[MorselOp]')
#
# FIELD FOR FIELD, not "it decoded". `pplan_fields_equal` compares every field
# of both sides and is what the round-trip test asserts on.
#
# WHAT IT COVERS
# --------------
# The codec handles one physical plan shape:
#
#     PROJECT? -> FILTER* -> SCAN(parquet)
#
# which is a `(ParquetSourceData, Slab[MorselOp])` pair: the Parquet source
# description plus the morsel operators that run over it. The physical plan for
# this shape is therefore not a new IR; this file gives that pair a wire form.
#
# NO PROTOBUF. This package depends on the core packages alone, so a consumer that
# decodes a physical plan does not pull a protobuf runtime into its closure. A
# hand-rolled length-prefixed format costs a few hundred lines and adds one
# package to the closure.
#
# ============================ THE COVERAGE LEDGER ============================
#
# EVERY UNSUPPORTED SHAPE RAISES BY NAME. NOTHING IS SILENTLY DROPPED.
# A codec that quietly drops a field round-trips a SMALLER plan and passes its
# own test.
#
# --- ParquetSourceData: 10 of 10 fields modelled ------------------------------
#   ENCODED    file_path, projection, pushed_filter, fs_descriptor,
#              preserve_numeric_dict, explicit_paths, row_window,
#              preserve_string_dict
#   REFUSED    hive_partition_cols (non-empty) -> PPLAN_WIRE_UNSUPPORTED_HIVE_COLS
#              hive_predicate (present)        -> PPLAN_WIRE_UNSUPPORTED_HIVE_PRED
#   ⚠ The two refusals are the LAZY dir-scan Hive path. They are refused rather
#   than dropped because a dropped `hive_predicate` is a plan that scans EVERY
#   partition and still returns rows — a silent 100x, not a crash.
#
# --- MorselOp: 3 of 13+ variants modelled -------------------------------------
#   ENCODED    OP_FILTER, OP_PROJECT, OP_LIMIT
#   REFUSED    every other tag -> PPLAN_WIRE_UNSUPPORTED_OP_TAG
#   The collect shape emits only these three; a plan carrying OP_JOIN_PROBE
#   is a DIFFERENT shape and must not be silently flattened into this one.
#
# --- Expr: 5 of 24 tags modelled ----------------------------------------------
#   ENCODED    COL_REF, LITERAL, BINARY_OP, UNARY_OP, ALIAS
#   REFUSED    every other tag -> PPLAN_WIRE_UNSUPPORTED_EXPR_TAG
#   ⚠ CAST is REFUSED, not encoded. Rebuilding one needs all six `CastData`
#   parts including an `ArrowType`, and encoding an ArrowType is the logical
#   codec's `_arrow_type_{to,from}_wire` pair — real work this shape has not
#   yet been shown to need. The refusal names the tag, so the first plan that
#   needs it says so out loud instead of losing the cast.
#
# --- ScalarValue: ALL fields encoded ------------------------------------------
#   Every one of the 19 fields, unconditionally. `ScalarValue` is flat POD +
#   one String, so there is no shape to refuse — encoding all of it is both
#   cheaper than a per-kind case analysis and total by construction.
#
# --- CODES AND COUNTS: checked on BOTH sides ----------------------------------
#   A byte that names a member of a closed vocabulary is checked against it,
#   by the encoder and the decoder alike, and refused as PPLAN_WIRE_BAD_ENUM:
#   a bool byte (0 or 1), a binary operator (BIN_ADD..BIN_MOD, BIN_EQ..BIN_GE,
#   BIN_AND, BIN_OR), a unary operator (UN_NOT..UN_BIT_COUNT), an fs scheme
#   (FS_SCHEME_FILE..FS_SCHEME_AZURE), a scalar kind (..SCALAR_KIND_BINARY)
#   and time unit (..SCALAR_TIME_UNIT_NANO).
#   A negative count (LIMIT, row-window offset/length, and on decode a string,
#   list, op or project length) is PPLAN_WIRE_NEGATIVE_COUNT. A PROJECT whose
#   name count differs from its expression count is
#   PPLAN_WIRE_PROJECT_MISMATCH. Every identifier string (paths, names,
#   bucket) must be UTF-8 or the encode/decode is PPLAN_WIRE_BAD_UTF8; a
#   scalar's `string_val` is exempt, because a BINARY scalar carries opaque
#   bytes there. A scalar's Int32 fields (date32, interval months/days)
#   travel as Int64 and a decoded value outside Int32 is
#   PPLAN_WIRE_OUT_OF_RANGE.
#   NOT checked: whether a ScalarValue's fields are coherent with its kind.
#   That is value admission, which lives with the plan's consumers.
# =============================================================================

from komira_plan_expr.expr import (
    Expr,
    BIN_MOD,
    BIN_EQ,
    BIN_GE,
    BIN_AND,
    BIN_OR,
    UN_BIT_COUNT,
    COL_SIDE_LEFT,
    COL_SIDE_RIGHT,
    EXPR_COL_REF,
    EXPR_LITERAL,
    EXPR_BINARY_OP,
    EXPR_UNARY_OP,
    EXPR_ALIAS,
    COL_SIDE_NONE,
)
from komira_plan_expr.scalar_value import (
    ScalarValue,
    SCALAR_KIND_BINARY,
    SCALAR_TIME_UNIT_NANO,
)
from komira_plan_ir.logical_plan import ExprArray
from komira_plan_ir.physical_plan import (
    ParquetSourceData,
    ParquetRowWindow,
    MorselOp,
    OP_FILTER,
    OP_PROJECT,
    OP_LIMIT,
)
from komira_plan_expr.fs_descriptor_pod import FsDescriptorPod, FS_SCHEME_AZURE
from komira_collections.slab import Slab
from komira_arrow.schema import Field
from std.memory import bitcast
from komira_arrow.dtype_sentinel import DTYPE_NONE


# =============================================================================
# Format constants + refusal tokens
# =============================================================================

comptime PPLAN_WIRE_MAGIC_0: UInt8 = 0x50  # 'P'
comptime PPLAN_WIRE_MAGIC_1: UInt8 = 0x50  # 'P'
comptime PPLAN_WIRE_MAGIC_2: UInt8 = 0x57  # 'W'
comptime PPLAN_WIRE_MAGIC_3: UInt8 = 0x31  # '1'

comptime PPLAN_WIRE_FORMAT_VERSION: UInt32 = 2
"""The only version `pplan_from_bytes` reads; every other one is refused by
`PPLAN_WIRE_BAD_VERSION` before the body is read. Version 1 is refused: its
scalar carried an error-code byte that this layout does not have."""

comptime PPLAN_WIRE_BAD_MAGIC: String = "PPLAN_WIRE_BAD_MAGIC"
comptime PPLAN_WIRE_BAD_VERSION: String = "PPLAN_WIRE_BAD_VERSION"
comptime PPLAN_WIRE_TRUNCATED: String = "PPLAN_WIRE_TRUNCATED"
comptime PPLAN_WIRE_TRAILING_BYTES: String = "PPLAN_WIRE_TRAILING_BYTES"
comptime PPLAN_WIRE_UNSUPPORTED_HIVE_COLS: String = "PPLAN_WIRE_UNSUPPORTED_HIVE_COLS"
comptime PPLAN_WIRE_UNSUPPORTED_HIVE_PRED: String = "PPLAN_WIRE_UNSUPPORTED_HIVE_PRED"
comptime PPLAN_WIRE_UNSUPPORTED_OP_TAG: String = "PPLAN_WIRE_UNSUPPORTED_OP_TAG"
comptime PPLAN_WIRE_UNSUPPORTED_EXPR_TAG: String = "PPLAN_WIRE_UNSUPPORTED_EXPR_TAG"
comptime PPLAN_WIRE_UNSUPPORTED_DTYPE: String = "PPLAN_WIRE_UNSUPPORTED_DTYPE"
comptime PPLAN_WIRE_UNSUPPORTED_COL_SIDE: String = "PPLAN_WIRE_UNSUPPORTED_COL_SIDE"
comptime PPLAN_WIRE_BAD_ENUM: String = "PPLAN_WIRE_BAD_ENUM"
comptime PPLAN_WIRE_NEGATIVE_COUNT: String = "PPLAN_WIRE_NEGATIVE_COUNT"
comptime PPLAN_WIRE_BAD_UTF8: String = "PPLAN_WIRE_BAD_UTF8"
comptime PPLAN_WIRE_OUT_OF_RANGE: String = "PPLAN_WIRE_OUT_OF_RANGE"
comptime PPLAN_WIRE_PROJECT_MISMATCH: String = "PPLAN_WIRE_PROJECT_MISMATCH"

# Recursion bound on the Expr tree. The logical codec learned this the hard way
# (a 901-byte nest SIGSEGV'd `decode_proto` before any refusal could fire), and
# the lesson generalises: the guarantee has to live ON THE RECURSION, not in a
# prescan that a single appended byte can talk out of descending.
comptime PPLAN_WIRE_MAX_EXPR_DEPTH: Int = 64
comptime PPLAN_WIRE_EXPR_TOO_DEEP: String = "PPLAN_WIRE_EXPR_TOO_DEEP"


# =============================================================================
# The decoded pair
# =============================================================================


struct PhysicalCollectPlan(Movable):
    """The physical plan for `PROJECT? -> FILTER* -> SCAN(parquet)`: the
    Parquet source description plus its morsel operators. This is the decode
    target."""

    var pq_data: ParquetSourceData
    var ops: Slab[MorselOp]

    def __init__(out self, var pq_data: ParquetSourceData, var ops: Slab[MorselOp]):
        self.pq_data = pq_data^
        self.ops = ops^


# =============================================================================
# Primitive writers / readers — little-endian, length-prefixed
# =============================================================================


struct _Cursor(Movable):
    """Read cursor over the encoded buffer. Every read is bounds-checked and
    refuses by name; there is no unchecked read anywhere in this file."""

    var buf: List[UInt8]
    var pos: Int

    def __init__(out self, var buf: List[UInt8]):
        self.buf = buf^
        self.pos = 0

    def _need(mut self, n: Int) raises:
        # ⚠ `n > len - pos`, NEVER `pos + n > len`: `n` can come off the wire
        # (a string length), and `pos + INT64_MAX` wraps negative, passes the
        # check, and the copy loop then reads past the buffer.
        if n < 0 or n > len(self.buf) - self.pos:
            raise Error(PPLAN_WIRE_TRUNCATED, ": need ", n, " at ", self.pos)


def _put_u8(mut out: List[UInt8], v: UInt8):
    out.append(v)


def _get_u8(mut c: _Cursor) raises -> UInt8:
    c._need(1)
    var v = c.buf[c.pos]
    c.pos += 1
    return v


def _put_bool(mut out: List[UInt8], v: Bool):
    out.append(UInt8(1) if v else UInt8(0))


def _get_bool(mut c: _Cursor) raises -> Bool:
    # Only the two bytes `_put_bool` writes. "Non-zero is True" would accept
    # 254 spellings of every plan.
    var v = _get_u8(c)
    if v > 1:
        raise Error(PPLAN_WIRE_BAD_ENUM, ": bool byte ", Int(v), " at ", c.pos - 1)
    return v == 1


def _put_i64(mut out: List[UInt8], v: Int64):
    var u = UInt64(Int(v))
    for i in range(8):
        out.append(UInt8((u >> UInt64(8 * i)) & UInt64(0xFF)))


def _get_i64(mut c: _Cursor) raises -> Int64:
    c._need(8)
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(c.buf[c.pos + i])) << UInt64(8 * i)
    c.pos += 8
    return Int64(Int(u))


def _put_int(mut out: List[UInt8], v: Int):
    _put_i64(out, Int64(v))


def _get_int(mut c: _Cursor) raises -> Int:
    return Int(_get_i64(c))


def _put_u32(mut out: List[UInt8], v: UInt32):
    for i in range(4):
        out.append(UInt8((Int(v) >> (8 * i)) & 0xFF))


def _get_u32(mut c: _Cursor) raises -> UInt32:
    c._need(4)
    var u = 0
    for i in range(4):
        u |= Int(c.buf[c.pos + i]) << (8 * i)
    c.pos += 4
    return UInt32(u)


def _put_f64(mut out: List[UInt8], v: Float64):
    # Bit-exact: reinterpret the IEEE-754 payload as an integer and write the
    # 8 bytes. A decimal render would not round-trip a NaN payload or a -0.0.
    _put_i64(out, Int64(Int(bitcast[DType.uint64](v))))


def _get_f64(mut c: _Cursor) raises -> Float64:
    var bits = _get_i64(c)
    return bitcast[DType.float64](UInt64(Int(bits)))


def _put_str(mut out: List[UInt8], s: String, utf8: Bool = True) raises:
    """The encoder twin of `_get_str`: an identifier that is not UTF-8 (a
    String built with `unsafe_from_utf8` over unchecked bytes) is refused
    here, at the offset its payload would occupy, rather than written as
    bytes the decoder refuses."""
    var b = s.as_bytes()
    if utf8 and not _is_utf8(b):
        raise Error(PPLAN_WIRE_BAD_UTF8, ": string at ", len(out) + 8)
    _put_int(out, len(b))
    for i in range(len(b)):
        out.append(b[i])


def _is_utf8(b: Span[UInt8, _]) -> Bool:
    """RFC 3629 well-formedness of `b`: no overlong form, no surrogate,
    nothing above U+10FFFF, no truncated sequence."""
    var n = len(b)
    var i = 0
    while i < n:
        var c0 = Int(b[i])
        if c0 < 0x80:
            i += 1
            continue
        if c0 < 0xC2 or c0 > 0xF4:
            return False
        var need = 1
        var lo = 0x80
        var hi = 0xBF
        if c0 == 0xE0:
            need = 2
            lo = 0xA0
        elif c0 == 0xED:
            need = 2
            hi = 0x9F
        elif c0 >= 0xE1 and c0 <= 0xEF:
            need = 2
        elif c0 == 0xF0:
            need = 3
            lo = 0x90
        elif c0 == 0xF4:
            need = 3
            hi = 0x8F
        elif c0 >= 0xF1 and c0 <= 0xF3:
            need = 3
        if i + need >= n:
            return False
        var c1 = Int(b[i + 1])
        if c1 < lo or c1 > hi:
            return False
        for k in range(2, need + 1):
            var ck = Int(b[i + k])
            if ck < 0x80 or ck > 0xBF:
                return False
        i += need + 1
    return True


def _get_str(mut c: _Cursor, utf8: Bool = True) raises -> String:
    """A length-prefixed string. `utf8=True` (every identifier) refuses
    bytes that are not UTF-8; only a scalar's `string_val`, which carries a
    BINARY value's opaque bytes, reads with `utf8=False`."""
    var n = _get_int(c)
    _check_count("string length", n)
    c._need(n)
    var start = c.pos
    var bytes = List[UInt8]()
    for i in range(n):
        bytes.append(c.buf[c.pos + i])
    c.pos += n
    if utf8 and not _is_utf8(Span(bytes)):
        raise Error(PPLAN_WIRE_BAD_UTF8, ": string at ", start)
    bytes.append(UInt8(0))
    return String(StringSlice(unsafe_from_utf8=Span(bytes)[0:n]))


def _put_strs(mut out: List[UInt8], s: List[String]) raises:
    _put_int(out, len(s))
    for i in range(len(s)):
        _put_str(out, s[i])


def _get_strs(mut c: _Cursor) raises -> List[String]:
    var n = _get_int(c)
    _check_count("list length", n)
    var res = List[String]()
    for _ in range(n):
        res.append(_get_str(c))
    return res^


# =============================================================================
# DType <-> wire code
# =============================================================================
#
# ⚠ AN EXPLICIT TABLE, NOT `DType`'s INTERNAL VALUE. `DType` exposes no stable
# integer and the codec must not invent one: a code derived from an
# implementation detail
# changes meaning when the stdlib reorders, and a plan encoded yesterday then
# decodes to a different type today with nothing raising.

comptime _DT_INVALID: UInt32 = 0
comptime _DT_BOOL: UInt32 = 1
comptime _DT_INT8: UInt32 = 2
comptime _DT_INT16: UInt32 = 3
comptime _DT_INT32: UInt32 = 4
comptime _DT_INT64: UInt32 = 5
comptime _DT_UINT8: UInt32 = 6
comptime _DT_UINT16: UInt32 = 7
comptime _DT_UINT32: UInt32 = 8
comptime _DT_UINT64: UInt32 = 9
comptime _DT_FLOAT16: UInt32 = 10
comptime _DT_FLOAT32: UInt32 = 11
comptime _DT_FLOAT64: UInt32 = 12


def _dtype_to_wire(d: DType) raises -> UInt32:
    if d == DTYPE_NONE:
        return _DT_INVALID
    if d == DType.bool:
        return _DT_BOOL
    if d == DType.int8:
        return _DT_INT8
    if d == DType.int16:
        return _DT_INT16
    if d == DType.int32:
        return _DT_INT32
    if d == DType.int64:
        return _DT_INT64
    if d == DType.uint8:
        return _DT_UINT8
    if d == DType.uint16:
        return _DT_UINT16
    if d == DType.uint32:
        return _DT_UINT32
    if d == DType.uint64:
        return _DT_UINT64
    if d == DType.float16:
        return _DT_FLOAT16
    if d == DType.float32:
        return _DT_FLOAT32
    if d == DType.float64:
        return _DT_FLOAT64
    raise Error(PPLAN_WIRE_UNSUPPORTED_DTYPE, ": no wire code for ", String(d))


def _dtype_from_wire(w: UInt32) raises -> DType:
    if w == _DT_INVALID:
        return DTYPE_NONE
    if w == _DT_BOOL:
        return DType.bool
    if w == _DT_INT8:
        return DType.int8
    if w == _DT_INT16:
        return DType.int16
    if w == _DT_INT32:
        return DType.int32
    if w == _DT_INT64:
        return DType.int64
    if w == _DT_UINT8:
        return DType.uint8
    if w == _DT_UINT16:
        return DType.uint16
    if w == _DT_UINT32:
        return DType.uint32
    if w == _DT_UINT64:
        return DType.uint64
    if w == _DT_FLOAT16:
        return DType.float16
    if w == _DT_FLOAT32:
        return DType.float32
    if w == _DT_FLOAT64:
        return DType.float64
    raise Error(PPLAN_WIRE_UNSUPPORTED_DTYPE, ": unknown wire code ", Int(w))


# =============================================================================
# Closed vocabularies — checked by the encoder AND the decoder
# =============================================================================


def _check_code(what: String, v: UInt8, valid: Bool) raises:
    if not valid:
        raise Error(PPLAN_WIRE_BAD_ENUM, ": ", what, " ", Int(v))


def _check_bin_op(op: UInt8) raises:
    _check_code(
        "binary op", op,
        op <= BIN_MOD or (op >= BIN_EQ and op <= BIN_GE) or op == BIN_AND
        or op == BIN_OR,
    )


def _check_un_op(op: UInt8) raises:
    _check_code("unary op", op, op <= UN_BIT_COUNT)


def _check_fs_scheme(s: UInt8) raises:
    _check_code("fs scheme", s, s <= FS_SCHEME_AZURE)


def _check_scalar_codes(v: ScalarValue) raises:
    _check_code("scalar kind", v._kind, v._kind <= SCALAR_KIND_BINARY)
    _check_code(
        "scalar time unit", v.time_unit, v.time_unit <= SCALAR_TIME_UNIT_NANO
    )


def _check_count(what: String, n: Int) raises:
    if n < 0:
        raise Error(PPLAN_WIRE_NEGATIVE_COUNT, ": ", what, " ", n)


def _check_project_arity(n_exprs: Int, n_names: Int) raises:
    """One output name per PROJECT expression, on both sides."""
    if n_exprs != n_names:
        raise Error(
            PPLAN_WIRE_PROJECT_MISMATCH, ": ", n_exprs, " exprs, ", n_names,
            " names",
        )


# =============================================================================
# ScalarValue — every field, unconditionally
# =============================================================================


def _put_scalar(mut out: List[UInt8], v: ScalarValue) raises:
    _check_scalar_codes(v)
    _put_u32(out, _dtype_to_wire(v.dtype))
    _put_i64(out, v.int_val)
    _put_f64(out, v.float_val)
    _put_str(out, v.string_val, utf8=False)
    _put_bool(out, v.bool_val)
    _put_u8(out, v._kind)
    _put_i64(out, v.dec128_high)
    _put_i64(out, v.dec128_low)
    _put_int(out, v.dec128_precision)
    _put_int(out, v.dec128_scale)
    _put_i64(out, Int64(Int(v.date32_val)))
    _put_i64(out, v.ts_micros)
    _put_u32(out, _dtype_to_wire(v.null_dtype))
    _put_i64(out, Int64(Int(v.iv_months)))
    _put_i64(out, Int64(Int(v.iv_days)))
    _put_i64(out, v.iv_nanos)
    _put_u8(out, v.time_unit)
    _put_i64(out, v.dec256_high_lo)
    _put_i64(out, v.dec256_high_hi)


def _get_i32(mut c: _Cursor, what: String) raises -> Int32:
    """An Int32 field, which travels as Int64. A value outside Int32 is
    REFUSED: narrowing it would map 2^32 spellings onto one plan, and the
    plan would not re-encode to the bytes it came from."""
    var v = _get_i64(c)
    if v < Int64(-2147483648) or v > Int64(2147483647):
        raise Error(PPLAN_WIRE_OUT_OF_RANGE, ": scalar ", what, " ", v)
    return Int32(Int(v))


def _get_scalar(mut c: _Cursor) raises -> ScalarValue:
    var s = ScalarValue()
    s.dtype = _dtype_from_wire(_get_u32(c))
    s.int_val = _get_i64(c)
    s.float_val = _get_f64(c)
    s.string_val = _get_str(c, utf8=False)
    s.bool_val = _get_bool(c)
    s._kind = _get_u8(c)
    s.dec128_high = _get_i64(c)
    s.dec128_low = _get_i64(c)
    s.dec128_precision = _get_int(c)
    s.dec128_scale = _get_int(c)
    s.date32_val = _get_i32(c, "date32")
    s.ts_micros = _get_i64(c)
    s.null_dtype = _dtype_from_wire(_get_u32(c))
    s.iv_months = _get_i32(c, "interval months")
    s.iv_days = _get_i32(c, "interval days")
    s.iv_nanos = _get_i64(c)
    s.time_unit = _get_u8(c)
    s.dec256_high_lo = _get_i64(c)
    s.dec256_high_hi = _get_i64(c)
    _check_scalar_codes(s)
    return s^


# =============================================================================
# Expr — 5 tags modelled, every other tag REFUSED BY NAME
# =============================================================================


def _put_expr(mut out: List[UInt8], e: Expr, depth: Int) raises:
    if depth > PPLAN_WIRE_MAX_EXPR_DEPTH:
        raise Error(PPLAN_WIRE_EXPR_TOO_DEEP, ": depth ", depth)
    if e.is_col_ref():
        _put_u8(out, EXPR_COL_REF)
        _put_str(out, e.col_ref_name())
        _put_u8(out, e.col_ref_side())
    elif e.is_literal():
        _put_u8(out, EXPR_LITERAL)
        _put_scalar(out, e.literal_value())
    elif e.is_binary():
        _put_u8(out, EXPR_BINARY_OP)
        _check_bin_op(e.binary_op())
        _put_u8(out, e.binary_op())
        _put_expr(out, e.binary_left_ref(), depth + 1)
        _put_expr(out, e.binary_right_ref(), depth + 1)
    elif e.is_unary():
        _put_u8(out, EXPR_UNARY_OP)
        _check_un_op(e.unary_op())
        _put_u8(out, e.unary_op())
        _put_expr(out, e.unary_child_ref(), depth + 1)
    elif e.is_alias():
        _put_u8(out, EXPR_ALIAS)
        _put_str(out, e.alias_name())
        _put_expr(out, e.alias_child_ref(), depth + 1)
    else:
        raise Error(PPLAN_WIRE_UNSUPPORTED_EXPR_TAG, ": tag ", Int(e.tag))


def _get_expr(mut c: _Cursor, depth: Int) raises -> Expr:
    if depth > PPLAN_WIRE_MAX_EXPR_DEPTH:
        raise Error(PPLAN_WIRE_EXPR_TOO_DEEP, ": depth ", depth)
    var tag = _get_u8(c)
    if tag == EXPR_COL_REF:
        var name = _get_str(c)
        var side = _get_u8(c)
        # ⚠ THE `else` ARM MUST NOT BE "RIGHT". The vocabulary is exactly
        # {NONE=0, LEFT=1, RIGHT=2}; an unknown side is a byte this codec did
        # not write, and decoding it AS RIGHT would bind the column to the
        # other relation -- a silent wrong answer.
        # Refuse by name instead.
        if side == COL_SIDE_NONE:
            return Expr.col_ref(name)
        if side == COL_SIDE_LEFT:
            return Expr.left(name)
        if side == COL_SIDE_RIGHT:
            return Expr.right(name)
        raise Error(PPLAN_WIRE_UNSUPPORTED_COL_SIDE, ": ", Int(side))
    elif tag == EXPR_LITERAL:
        return Expr.literal(_get_scalar(c))
    elif tag == EXPR_BINARY_OP:
        var op = _get_u8(c)
        _check_bin_op(op)
        var l = _get_expr(c, depth + 1)
        var r = _get_expr(c, depth + 1)
        return Expr.binary(op, l^, r^)
    elif tag == EXPR_UNARY_OP:
        var op2 = _get_u8(c)
        _check_un_op(op2)
        var ch = _get_expr(c, depth + 1)
        return Expr.unary(op2, ch^)
    elif tag == EXPR_ALIAS:
        var nm = _get_str(c)
        var ch2 = _get_expr(c, depth + 1)
        return Expr.alias(ch2^, nm)
    else:
        raise Error(PPLAN_WIRE_UNSUPPORTED_EXPR_TAG, ": tag ", Int(tag))


def _put_opt_expr(mut out: List[UInt8], e: Optional[Expr]) raises:
    if e:
        _put_bool(out, True)
        _put_expr(out, e.value(), 0)
    else:
        _put_bool(out, False)


def _get_opt_expr(mut c: _Cursor) raises -> Optional[Expr]:
    if _get_bool(c):
        return Optional[Expr](_get_expr(c, 0))
    return Optional[Expr](None)


# =============================================================================
# MorselOp — OP_FILTER / OP_PROJECT / OP_LIMIT
# =============================================================================


def _put_op(mut out: List[UInt8], op: MorselOp) raises:
    _put_u8(out, op.tag)
    if op.tag == OP_FILTER:
        if not op.filter_predicate:
            raise Error(PPLAN_WIRE_UNSUPPORTED_OP_TAG, ": OP_FILTER with no predicate")
        _put_expr(out, op.filter_predicate.value(), 0)
    elif op.tag == OP_PROJECT:
        if not op.project_exprs or not op.project_names:
            raise Error(PPLAN_WIRE_UNSUPPORTED_OP_TAG, ": OP_PROJECT with no exprs/names")
        ref exprs = op.project_exprs.value()
        _check_project_arity(len(exprs), len(op.project_names.value()))
        _put_int(out, len(exprs))
        for i in range(len(exprs)):
            _put_expr(out, exprs[i], 0)
        _put_strs(out, op.project_names.value())
        _put_bool(out, op.project_reorders_only)
    elif op.tag == OP_LIMIT:
        _check_count("limit", op.limit_count)
        _put_int(out, op.limit_count)
    else:
        raise Error(PPLAN_WIRE_UNSUPPORTED_OP_TAG, ": tag ", Int(op.tag))


def _get_op(mut c: _Cursor) raises -> MorselOp:
    var tag = _get_u8(c)
    if tag == OP_FILTER:
        return MorselOp.filter(_get_expr(c, 0))
    elif tag == OP_PROJECT:
        var n = _get_int(c)
        _check_count("project expr count", n)
        var exprs = ExprArray()
        for _ in range(n):
            exprs.append(_get_expr(c, 0))
        var names = _get_strs(c)
        _check_project_arity(n, len(names))
        var reorders = _get_bool(c)
        var op = MorselOp.project(exprs^, names^)
        op.project_reorders_only = reorders
        return op^
    elif tag == OP_LIMIT:
        var n_lim = _get_int(c)
        _check_count("limit", n_lim)
        return MorselOp.limit(n_lim)
    else:
        raise Error(PPLAN_WIRE_UNSUPPORTED_OP_TAG, ": tag ", Int(tag))


# =============================================================================
# THE PUBLIC SURFACE
# =============================================================================


def pplan_to_bytes(
    pq_data: ParquetSourceData, ops: Slab[MorselOp],
) raises -> List[UInt8]:
    """Encode a physical collect plan. Raises by name on any shape the coverage ledger
    at the top of this file marks REFUSED."""
    var out = List[UInt8]()
    out.append(PPLAN_WIRE_MAGIC_0)
    out.append(PPLAN_WIRE_MAGIC_1)
    out.append(PPLAN_WIRE_MAGIC_2)
    out.append(PPLAN_WIRE_MAGIC_3)
    _put_u32(out, PPLAN_WIRE_FORMAT_VERSION)

    # ---- ParquetSourceData ----
    # ⚠ THE TWO REFUSALS COME FIRST, BEFORE ANY BYTE OF THE SOURCE IS WRITTEN.
    # A hive-carrying source that got half-encoded and then raised would leave
    # a caller holding a prefix it might be tempted to use.
    if len(pq_data.hive_partition_cols) != 0:
        raise Error(
            PPLAN_WIRE_UNSUPPORTED_HIVE_COLS, ": ",
            len(pq_data.hive_partition_cols), " partition cols",
        )
    if pq_data.hive_predicate:
        raise Error(PPLAN_WIRE_UNSUPPORTED_HIVE_PRED, ": predicate present")

    _put_str(out, pq_data.file_path)
    if pq_data.projection:
        _put_bool(out, True)
        _put_strs(out, pq_data.projection.value())
    else:
        _put_bool(out, False)
    _put_opt_expr(out, pq_data.pushed_filter)
    _check_fs_scheme(pq_data.fs_descriptor.scheme)
    _put_u8(out, pq_data.fs_descriptor.scheme)
    _put_str(out, pq_data.fs_descriptor.bucket)
    _put_int(out, pq_data.fs_descriptor.node_id)
    _put_bool(out, pq_data.preserve_numeric_dict)
    _put_strs(out, pq_data.explicit_paths)
    if pq_data.row_window:
        _check_count("row window offset", pq_data.row_window.value().offset)
        _check_count("row window length", pq_data.row_window.value().length)
        _put_bool(out, True)
        _put_int(out, pq_data.row_window.value().offset)
        _put_int(out, pq_data.row_window.value().length)
    else:
        _put_bool(out, False)
    _put_bool(out, pq_data.preserve_string_dict)

    # ---- ops ----
    _put_int(out, len(ops))
    for i in range(len(ops)):
        _put_op(out, ops[i])
    return out^


def pplan_from_bytes(var raw: List[UInt8]) raises -> PhysicalCollectPlan:
    """Decode a physical collect plan. Refuses by name on bad magic, an
    unsupported version, truncation, trailing bytes, any refused shape, a code
    outside its vocabulary, a negative count or a non-UTF-8 identifier (the
    coverage ledger at the top of this file).

    ⚠ TRAILING BYTES ARE A REFUSAL, NOT AN IGNORE. The logical codec's prescan
    was beaten by ONE APPENDED BYTE; a decoder that stops when it has what it
    wants cannot tell a well-formed plan from a well-formed prefix of something
    else."""
    var c = _Cursor(raw^)
    c._need(4)
    if (
        c.buf[0] != PPLAN_WIRE_MAGIC_0 or c.buf[1] != PPLAN_WIRE_MAGIC_1
        or c.buf[2] != PPLAN_WIRE_MAGIC_2 or c.buf[3] != PPLAN_WIRE_MAGIC_3
    ):
        raise Error(PPLAN_WIRE_BAD_MAGIC)
    c.pos = 4
    var ver = _get_u32(c)
    if ver != PPLAN_WIRE_FORMAT_VERSION:
        raise Error(PPLAN_WIRE_BAD_VERSION, ": ", Int(ver))

    var file_path = _get_str(c)
    var projection: Optional[List[String]] = None
    if _get_bool(c):
        projection = Optional[List[String]](_get_strs(c))
    var pushed = _get_opt_expr(c)
    var scheme = _get_u8(c)
    _check_fs_scheme(scheme)
    var bucket = _get_str(c)
    var node_id = _get_int(c)
    var preserve_numeric = _get_bool(c)
    var explicit_paths = _get_strs(c)
    var row_window: Optional[ParquetRowWindow] = None
    if _get_bool(c):
        var off = _get_int(c)
        _check_count("row window offset", off)
        var ln = _get_int(c)
        _check_count("row window length", ln)
        row_window = Optional[ParquetRowWindow](ParquetRowWindow(off, ln))
    var preserve_string = _get_bool(c)

    var n_ops = _get_int(c)
    _check_count("op count", n_ops)
    var ops = Slab[MorselOp]()
    for _ in range(n_ops):
        ops.append(_get_op(c))

    if c.pos != len(c.buf):
        raise Error(
            PPLAN_WIRE_TRAILING_BYTES, ": ", len(c.buf) - c.pos, " unread",
        )

    var pq = ParquetSourceData(
        file_path,
        projection^,
        pushed^,
        List[Field](),
        None,
        FsDescriptorPod(scheme=scheme, bucket=bucket, node_id=node_id),
        preserve_numeric,
        explicit_paths^,
        row_window^,
        preserve_string,
    )
    return PhysicalCollectPlan(pq^, ops^)
