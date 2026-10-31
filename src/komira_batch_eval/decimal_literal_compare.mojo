# =============================================================================
# decimal_literal_compare: a DECIMAL column against a decimal or integer
# literal, as an exact compare on the column's own integers
# =============================================================================
#
# A DECIMAL(p, s) column stores each value as the integer c = value * 10^s. The
# literal is a decimal V / 10^t (an integer literal has t = 0). The comparison
# `value <op> V / 10^t` is decided on the column's integers, with one threshold
# computed once for the whole column and no per-row rescale:
#
#   * t <= s: V * 10^(s - t) is an integer T, and `c <op> T` is the answer.
#   * t >  s: the literal falls between two column steps. With d = 10^(t - s),
#     q = floor(V / d) and r = V - q * d:
#       r = 0 (the literal is a step): `c <op> q`, as above;
#       r > 0 (V / 10^t lies strictly between q and q + 1):
#         c <  literal  <=>  c <= q            c <= literal  <=>  c <= q
#         c >  literal  <=>  c >= q + 1        c >= literal  <=>  c >= q + 1
#         c =  literal  is false for every row, c <> literal true.
#     So `x < 0.065` on a scale-2 column is `c <= 6`, and `x = 0.065` keeps
#     nothing. The literal is NEVER rounded to the column's scale.
#
# WHAT DUCKDB DOES BEFORE IT COMPARES, and where this module raises with it. It
# compares a DECIMAL(p, s) column with a literal V / 10^t in the one type
# DECIMAL(38, c) with c the larger of s and t (when the two widths fit in fewer
# than 38 digits it uses a narrower type, in which nothing can overflow). The
# literal is cast to it, and so is every row of the column: a literal with 39
# or more digits at scale c is a "Could not cast value" error that does not
# depend on the data, and a stored value of the column with 39 or more digits at
# scale c is a "value is out of range" error for the whole query, so the
# literal `0.0000000001` against a DECIMAL(38, 0) column holding 10^37 raises
# and `1` does not. Both are raised here (`decimal_threshold` for the literal,
# `check_decimal_column_widens` for the rows); nothing else about the column
# widens it, so a literal with at most the column's scale never raises. That the
# rows are read is a cost paid only when the literal has more scale than the
# column and the column's declared precision leaves less than that much room
# (p + t - s > 38).
#
# After the literal has been checked, every number below fits 128 bits: the
# literal at scale c is below 10^38 in absolute value, so is T = V * 10^(s - t)
# (t <= s: c = s) and so are floor(V / 10^(t - s)) and one more than it
# (t > s: c = t, and 10^38 < 2^127).
#
# Then the kernel. A column of precision <= 18 holds |c| < 10^18 < 2^63, so its
# low 64-bit word IS the value: the kernel reads eight rows at a time, keeps
# the low words (the even 64-bit lanes of the 16-byte values) and compares them
# to the int64 threshold with one SIMD compare, packing the eight results into
# a byte of the result bitmap. It does not trust the declared precision: a
# FIXED_LEN_BYTE_ARRAY Parquet column or an Arrow IPC buffer can hold a value
# wider than the precision it is declared with, and the low word of such a
# value is not the value. Each block therefore also checks that every high word
# is the sign extension of its low word (one shift-free compare and a
# reduction) and compares a block that fails the check, row by row, on the full
# 128-bit values against the full threshold. A wider column compares 128-bit
# values to the 128-bit threshold, one row at a time: that path is deliberately
# not vectorized (these are the columns whose values may not fit 64 bits, and
# the machine has no 128-bit SIMD compare). Both kernels return the raw bits of
# every row; the caller finalizes NULLs (`kleene_cmp_finalize_scalar`).
#
# "No row" and "every row" are thresholds too (`c < -10^38`, `c > -10^38`), so
# the kernels have no special case for an impossible equality.
# =============================================================================

from komira_arrow.bitmap import Bitmap
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.decimal_array import DECIMAL128_BYTE_WIDTH, Decimal128Array
from komira_buffer.heap_region import HeapRegion
from komira_scalar_arithmetic.decimal_arith import I128, I256, pow10_i256
from komira_scalar_arithmetic.decimal_compare import (
    DEC_CMP_EQ,
    DEC_CMP_GE,
    DEC_CMP_GT,
    DEC_CMP_LE,
    DEC_CMP_LT,
    DEC_CMP_NE,
)

# The widest DECIMAL whose unscaled value always fits an int64.
comptime DECIMAL_INT64_MAX_PRECISION = 18

comptime _LANES = 8


struct DecimalThreshold(Copyable, Movable):
    """`c <op> threshold`, on the column's unscaled integers."""

    var op: UInt8
    var threshold: I128

    def __init__(out self, op: UInt8, threshold: I128):
        self.op = op
        self.threshold = threshold


def _decimal_text(unscaled: I256, scale: Int) -> String:
    """`unscaled / 10^scale` as DuckDB prints a DECIMAL: digits, a point before
    the last `scale` of them, a leading minus when negative."""
    var negative = unscaled < I256(0)
    var n = unscaled
    if negative:
        n = -n
    var ten = I256(10)
    var digits = List[UInt8]()
    while n > I256(0) or len(digits) <= scale:
        digits.append(UInt8(ord("0") + Int((n % ten).cast[DType.int64]())))
        n = n / ten
    var out = String("-") if negative else String("")
    for i in range(len(digits) - 1, -1, -1):
        out += chr(Int(digits[i]))
        if i == scale and scale > 0:
            out += "."
    return out^


def decimal_threshold(
    value: I128, literal_scale: Int, column_scale: Int, op: UInt8
) raises -> DecimalThreshold:
    """The threshold on a column of scale `column_scale` that answers
    `column <op> value / 10^literal_scale` exactly. `op` is a DEC_CMP_* code.

    Raises:
        If a scale is outside [0, 38], or if the literal has 39 digits or more
        at the larger of the two scales (DuckDB: "Could not cast value").
    """
    if literal_scale < 0 or literal_scale > 38 or column_scale < 0 or column_scale > 38:
        raise Error(
            "decimal_threshold: scales ("
            + String(literal_scale)
            + ", "
            + String(column_scale)
            + ") are outside [0, 38]"
        )
    var v = value.cast[DType.int256]()
    var common = max(literal_scale, column_scale)
    var limit = pow10_i256(38)
    var at_common = v * pow10_i256(common - literal_scale)
    if at_common >= limit or at_common <= -limit:
        raise Error(
            "Conversion Error: Could not cast value "
            + _decimal_text(v, literal_scale)
            + " to DECIMAL(38,"
            + String(common)
            + ")"
        )
    if literal_scale <= column_scale:
        # `at_common` is the literal at the column's scale, below 10^38.
        return DecimalThreshold(op, at_common.cast[DType.int128]())
    var d = pow10_i256(literal_scale - column_scale)
    # Mojo's integer `/` truncates toward zero: fix it up to the floor.
    var q = v / d
    var r = v - q * d
    if r < I256(0):
        q = q - I256(1)
        r = r + d
    if r == I256(0):
        return DecimalThreshold(op, q.cast[DType.int128]())
    # The literal lies strictly between the steps q and q + 1.
    if op == DEC_CMP_LT or op == DEC_CMP_LE:
        return DecimalThreshold(DEC_CMP_LE, q.cast[DType.int128]())
    if op == DEC_CMP_GT or op == DEC_CMP_GE:
        return DecimalThreshold(DEC_CMP_GE, (q + I256(1)).cast[DType.int128]())
    # No step equals the literal: `=` keeps nothing, `<>` keeps every row.
    var below_all = -limit.cast[DType.int128]()
    if op == DEC_CMP_EQ:
        return DecimalThreshold(DEC_CMP_LT, below_all)
    return DecimalThreshold(DEC_CMP_GT, below_all)


def check_decimal_buffer(arr: Decimal128Array[HeapRegion]) raises:
    """Raise unless the buffer holds `arr.length` whole rows. The rows are read
    by index from `arr.length`, which a buffer can disagree with (the reads are
    checked in debug builds only)."""
    if arr.data.len() < arr.length * DECIMAL128_BYTE_WIDTH:
        raise Error(
            "Decimal128 compare: the buffer holds "
            + String(arr.data.len())
            + " bytes, fewer than the "
            + String(arr.length)
            + " rows of "
            + String(DECIMAL128_BYTE_WIDTH)
            + " bytes it declares"
        )


def check_decimal_column_widens(
    arr: Decimal128Array[HeapRegion],
    precision: Int,
    scale: Int,
    literal_scale: Int,
) raises:
    """Raise when DuckDB could not widen the column to compare it with a
    literal of scale `literal_scale`: a stored non-NULL value that has 39
    digits or more once it is at that scale.

    Nothing happens when the literal has at most the column's scale (the column
    is not widened), and when the column's declared `precision` leaves room for
    the widening (`precision + literal_scale - scale <= 38`): then no value of
    that precision can overflow and the rows are not read.

    Raises:
        "Casting value ... to type DECIMAL(38,c) failed: value is out of
        range!", DuckDB's words, for the first such value.
    """
    check_decimal_buffer(arr)
    if literal_scale <= scale:
        return
    var shift = literal_scale - scale
    if precision + shift <= 38:
        return
    # |value| * 10^shift < 10^38 exactly when |value| < 10^(38 - shift).
    var limit = pow10_i256(38 - shift).cast[DType.int128]()
    for i in range(arr.length):
        if arr.is_null(i):
            continue
        var v = arr.get_i128(i)
        if v >= limit or v <= -limit:
            raise Error(
                'Conversion Error: Casting value "'
                + _decimal_text(v.cast[DType.int256](), scale)
                + '" to type DECIMAL(38,'
                + String(literal_scale)
                + ") failed: value is out of range! when comparing a DECIMAL("
                + String(precision)
                + ","
                + String(scale)
                + ") column with a literal of scale "
                + String(literal_scale)
            )


@always_inline
def _holds[op: UInt8, W: Int](
    lo: SIMD[DType.int64, W], t: SIMD[DType.int64, W]
) -> SIMD[DType.bool, W]:
    comptime if op == DEC_CMP_LT:
        return lo.lt(t)
    elif op == DEC_CMP_LE:
        return lo.le(t)
    elif op == DEC_CMP_GT:
        return lo.gt(t)
    elif op == DEC_CMP_GE:
        return lo.ge(t)
    elif op == DEC_CMP_EQ:
        return lo.eq(t)
    else:
        return lo.ne(t)


@always_inline
def _holds_scalar[op: UInt8, T: DType](v: Scalar[T], t: Scalar[T]) -> Bool:
    comptime if op == DEC_CMP_LT:
        return v < t
    elif op == DEC_CMP_LE:
        return v <= t
    elif op == DEC_CMP_GT:
        return v > t
    elif op == DEC_CMP_GE:
        return v >= t
    elif op == DEC_CMP_EQ:
        return v == t
    else:
        return v != t


def _block_i128[op: UInt8](
    arr: Decimal128Array[HeapRegion],
    first_row: Int,
    lanes: Int,
    threshold: I128,
) -> UInt8:
    """The result bits (bit k for row `first_row + k`) of `lanes` rows, at most
    8, compared on their full 128-bit values to the full threshold.
    SAFETY: the caller keeps `first_row + lanes <= arr.length`, and
    `eval_decimal_threshold` has checked that the buffer holds `arr.length`
    whole rows."""
    var byte_val = UInt8(0)
    for k in range(lanes):
        var v = arr.data.read_i128_le_at((first_row + k) * DECIMAL128_BYTE_WIDTH)
        if _holds_scalar[op, DType.int128](v, threshold):
            byte_val = byte_val | (UInt8(1) << UInt8(k))
    return byte_val


def _compare_int64[op: UInt8](
    arr: Decimal128Array[HeapRegion],
    threshold: Int64,
    wide: I128,
    forced: Int,
) -> BooleanArray:
    """`value <op> wide` for every row, eight rows to an output byte, the
    values read through their low 64-bit words where that is the value.

    `threshold` is `wide` clamped to the int64 range and `forced` says what the
    clamp lost: 0 nothing; 1 every row that fits an int64 compares false (the
    threshold was beyond the range on the side where `op` cannot hold); 2 every
    such row compares true. A block of eight rows whose high words are all the
    sign extension of their low words fits (one SIMD compare of the high words
    with the sign of the low words) and is compared as int64; any other block,
    and the tail, is compared row by row on the full 128-bit values, so the
    answer is right whatever the buffer holds, whatever precision declares it.
    SAFETY of the loads: the block loop runs only while 8 whole rows (128
    bytes) remain inside `arr.length` rows, and `eval_decimal_threshold` has
    checked that the buffer holds `arr.length` whole rows."""
    var n = arr.length
    var bm = Bitmap.create(n)
    var out = bm.buffer.view_mut()
    var t = SIMD[DType.int64, _LANES](threshold)
    var zero = SIMD[DType.int64, _LANES](0)
    var minus_one = SIMD[DType.int64, _LANES](-1)
    var weights = SIMD[DType.uint8, _LANES](1, 2, 4, 8, 16, 32, 64, 128)
    var blocks = n >> 3
    for b in range(blocks):
        var words = arr.data.load_simd[DType.int64, 2 * _LANES](
            b * _LANES * DECIMAL128_BYTE_WIDTH
        )
        var halves = words.deinterleave()
        var low = halves[0]
        var high = halves[1]
        var extension = low.lt(zero).select(minus_one, zero)
        if high.eq(extension).reduce_and():
            if forced == 0:
                var mask = _holds[op, _LANES](low, t)
                out.write_u8_at(
                    b, (mask.cast[DType.uint8]() * weights).reduce_add()
                )
            elif forced == 1:
                out.write_u8_at(b, UInt8(0))
            else:
                out.write_u8_at(b, UInt8(255))
        else:
            out.write_u8_at(b, _block_i128[op](arr, b << 3, _LANES, wide))
    var rest = n - (blocks << 3)
    if rest > 0:
        out.write_u8_at(blocks, _block_i128[op](arr, blocks << 3, rest, wide))
    return BooleanArray.from_bitmap(bm^)


def _compare_int128[op: UInt8](
    arr: Decimal128Array[HeapRegion], threshold: I128
) -> BooleanArray:
    """`value <op> threshold` for every row, on the full 128-bit values, one
    row at a time. Deliberately not vectorized: these are the columns whose
    values may not fit 64 bits, and the machine has no 128-bit SIMD compare."""
    var n = arr.length
    var bm = Bitmap.create(n)
    var out = bm.buffer.view_mut()
    var total_bytes = (n + 7) >> 3
    for b in range(total_bytes):
        out.write_u8_at(
            b, _block_i128[op](arr, b << 3, min(8, n - (b << 3)), threshold)
        )
    return BooleanArray.from_bitmap(bm^)


def eval_decimal_threshold(
    arr: Decimal128Array[HeapRegion], precision: Int, plan: DecimalThreshold
) raises -> BooleanArray:
    """The raw result bits of `column <op> threshold` over every row of `arr`,
    a column of `precision` digits. NULL rows hold whatever the compare of their
    stored bytes gives; the caller masks them (`kleene_cmp_finalize_scalar`).

    A column of precision <= 18 holds values below 10^18 < 2^63, so the low
    word of each is the value, and it is compared as int64 with SIMD, eight
    rows at a time; blocks whose words say otherwise (a buffer is untrusted
    input) fall back to 128 bits, so the answer never depends on the declared
    precision being true. A wider column is compared as int128, row by row.

    Raises:
        If the buffer holds fewer bytes than `arr.length` rows need.
    """
    check_decimal_buffer(arr)
    if precision <= DECIMAL_INT64_MAX_PRECISION:
        var t = plan.threshold
        var forced = 0
        var hi = I128(Int(Int64.MAX))
        var lo = I128(Int(Int64.MIN))
        if t > hi:
            t = hi
            forced = 1
            if plan.op == DEC_CMP_LT or plan.op == DEC_CMP_LE or plan.op == DEC_CMP_NE:
                forced = 2
        elif t < lo:
            t = lo
            forced = 1
            if plan.op == DEC_CMP_GT or plan.op == DEC_CMP_GE or plan.op == DEC_CMP_NE:
                forced = 2
        var t64 = t.cast[DType.int64]()
        var wide = plan.threshold
        if plan.op == DEC_CMP_LT:
            return _compare_int64[DEC_CMP_LT](arr, t64, wide, forced)
        elif plan.op == DEC_CMP_LE:
            return _compare_int64[DEC_CMP_LE](arr, t64, wide, forced)
        elif plan.op == DEC_CMP_GT:
            return _compare_int64[DEC_CMP_GT](arr, t64, wide, forced)
        elif plan.op == DEC_CMP_GE:
            return _compare_int64[DEC_CMP_GE](arr, t64, wide, forced)
        elif plan.op == DEC_CMP_EQ:
            return _compare_int64[DEC_CMP_EQ](arr, t64, wide, forced)
        return _compare_int64[DEC_CMP_NE](arr, t64, wide, forced)
    if plan.op == DEC_CMP_LT:
        return _compare_int128[DEC_CMP_LT](arr, plan.threshold)
    elif plan.op == DEC_CMP_LE:
        return _compare_int128[DEC_CMP_LE](arr, plan.threshold)
    elif plan.op == DEC_CMP_GT:
        return _compare_int128[DEC_CMP_GT](arr, plan.threshold)
    elif plan.op == DEC_CMP_GE:
        return _compare_int128[DEC_CMP_GE](arr, plan.threshold)
    elif plan.op == DEC_CMP_EQ:
        return _compare_int128[DEC_CMP_EQ](arr, plan.threshold)
    return _compare_int128[DEC_CMP_NE](arr, plan.threshold)
