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
# Every threshold is clamped to +-10^38. A DECIMAL128 value has at most 38
# digits, so |c| < 10^38 and the clamp changes no answer; it only keeps T in
# 128 bits when V * 10^(s - t) is not.
#
# Then the kernel. A column of precision <= 18 holds |c| < 10^18 < 2^63, so
# its low 64-bit word IS the value: the kernel reads eight rows at a time,
# keeps the low words (the even 64-bit lanes of the 16-byte values) and
# compares them to the int64 threshold with one SIMD compare, packing the eight
# results into a byte of the result bitmap. A wider column compares 128-bit
# values to the 128-bit threshold. Both kernels return the raw bits of every
# row; the caller finalizes NULLs (`kleene_cmp_finalize_scalar`).
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


def _clamp_to_decimal128(v: I256) raises -> I128:
    var bound = pow10_i256(38)
    if v > bound:
        return bound.cast[DType.int128]()
    if v < -bound:
        return (-bound).cast[DType.int128]()
    return v.cast[DType.int128]()


def decimal_threshold(
    value: I128, literal_scale: Int, column_scale: Int, op: UInt8
) raises -> DecimalThreshold:
    """The threshold on a column of scale `column_scale` that answers
    `column <op> value / 10^literal_scale` exactly. `op` is a DEC_CMP_* code.

    Raises:
        If a scale is outside [0, 38].
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
    if literal_scale <= column_scale:
        return DecimalThreshold(
            op, _clamp_to_decimal128(v * pow10_i256(column_scale - literal_scale))
        )
    var d = pow10_i256(literal_scale - column_scale)
    # Mojo's integer `/` truncates toward zero: fix it up to the floor.
    var q = v / d
    var r = v - q * d
    if r < I256(0):
        q = q - I256(1)
        r = r + d
    if r == I256(0):
        return DecimalThreshold(op, _clamp_to_decimal128(q))
    # The literal lies strictly between the steps q and q + 1.
    if op == DEC_CMP_LT or op == DEC_CMP_LE:
        return DecimalThreshold(DEC_CMP_LE, _clamp_to_decimal128(q))
    if op == DEC_CMP_GT or op == DEC_CMP_GE:
        return DecimalThreshold(DEC_CMP_GE, _clamp_to_decimal128(q + I256(1)))
    # No step equals the literal: `=` keeps nothing, `<>` keeps every row.
    var below_all = -pow10_i256(38).cast[DType.int128]()
    if op == DEC_CMP_EQ:
        return DecimalThreshold(DEC_CMP_LT, below_all)
    return DecimalThreshold(DEC_CMP_GT, below_all)


def check_decimal_column_widens(
    arr: Decimal128Array[HeapRegion],
    precision: Int,
    scale: Int,
    literal_scale: Int,
) raises:
    pass


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


def _compare_int64[op: UInt8](
    arr: Decimal128Array[HeapRegion], threshold: Int64
) -> BooleanArray:
    """`low word <op> threshold` for every row, eight rows to an output byte.
    SAFETY of the loads: the block loop runs only while 8 whole rows (128
    bytes) remain, and the tail reads one row at a time."""
    var n = arr.length
    var bm = Bitmap.create(n)
    var out = bm.buffer.view_mut()
    var t = SIMD[DType.int64, _LANES](threshold)
    var weights = SIMD[DType.uint8, _LANES](1, 2, 4, 8, 16, 32, 64, 128)
    var blocks = n >> 3
    for b in range(blocks):
        var words = arr.data.load_simd[DType.int64, 2 * _LANES](
            b * _LANES * DECIMAL128_BYTE_WIDTH
        )
        var low = words.deinterleave()[0]
        var mask = _holds[op, _LANES](low, t)
        out.write_u8_at(b, (mask.cast[DType.uint8]() * weights).reduce_add())
    var rest = n - (blocks << 3)
    if rest > 0:
        var byte_val = UInt8(0)
        for k in range(rest):
            var v = arr.data.read_i64_le_at(((blocks << 3) + k) * DECIMAL128_BYTE_WIDTH)
            if _holds_scalar[op, DType.int64](v, threshold):
                byte_val = byte_val | (UInt8(1) << UInt8(k))
        out.write_u8_at(blocks, byte_val)
    return BooleanArray.from_bitmap(bm^)


def _compare_int128[op: UInt8](
    arr: Decimal128Array[HeapRegion], threshold: I128
) -> BooleanArray:
    """`value <op> threshold` for every row, on the full 128-bit values."""
    var n = arr.length
    var bm = Bitmap.create(n)
    var out = bm.buffer.view_mut()
    var total_bytes = (n + 7) >> 3
    for b in range(total_bytes):
        var byte_val = UInt8(0)
        var lanes = min(8, n - (b << 3))
        for k in range(lanes):
            var v = arr.data.read_i128_le_at(((b << 3) + k) * DECIMAL128_BYTE_WIDTH)
            if _holds_scalar[op, DType.int128](v, threshold):
                byte_val = byte_val | (UInt8(1) << UInt8(k))
        out.write_u8_at(b, byte_val)
    return BooleanArray.from_bitmap(bm^)


def eval_decimal_threshold(
    arr: Decimal128Array[HeapRegion], precision: Int, plan: DecimalThreshold
) -> BooleanArray:
    """The raw result bits of `column <op> threshold` over every row of `arr`,
    a column of `precision` digits. NULL rows hold whatever the compare of their
    stored bytes gives; the caller masks them (`kleene_cmp_finalize_scalar`).

    A column of precision <= 18 is compared as int64 with SIMD: its values are
    below 10^18 < 2^63, so the low word of each is the value, and the threshold
    is clamped to the int64 range (every value is strictly inside it, so the
    clamp changes no answer). A wider column is compared as int128.
    """
    if precision <= DECIMAL_INT64_MAX_PRECISION:
        var t = plan.threshold
        var lo = I128(Int(Int64.MIN))
        var hi = I128(Int(Int64.MAX))
        if t < lo:
            t = lo
        elif t > hi:
            t = hi
        var t64 = t.cast[DType.int64]()
        if plan.op == DEC_CMP_LT:
            return _compare_int64[DEC_CMP_LT](arr, t64)
        elif plan.op == DEC_CMP_LE:
            return _compare_int64[DEC_CMP_LE](arr, t64)
        elif plan.op == DEC_CMP_GT:
            return _compare_int64[DEC_CMP_GT](arr, t64)
        elif plan.op == DEC_CMP_GE:
            return _compare_int64[DEC_CMP_GE](arr, t64)
        elif plan.op == DEC_CMP_EQ:
            return _compare_int64[DEC_CMP_EQ](arr, t64)
        return _compare_int64[DEC_CMP_NE](arr, t64)
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
