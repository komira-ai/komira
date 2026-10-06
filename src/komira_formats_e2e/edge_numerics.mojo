# =============================================================================
# The numeric edge dataset: integer limits and IEEE-754 binary64 edge values.
# =============================================================================
#
# A separate dataset from `dataset.mojo` (whose expectations stay as they
# are). Two batches, every column NON-nullable so a writer's bytes for a row
# are exactly the value's encoding (no union tag, no PRESENT stream):
#
#   int batch (6 rows):   i64 INT64, i32 INT32
#     row  i64                     i32
#     0    INT64_MIN               INT32_MIN
#     1    INT64_MAX               INT32_MAX
#     2    -1                      -1
#     3    0                       0
#     4    2^53 + 1                2^24 + 1
#     5    -(2^53 + 1)             -(2^24 + 1)
#   2^53 + 1 is the first integer a double cannot hold (a reader that goes
#   through Float64 returns 2^53); 2^24 + 1 is the same edge for Float32.
#
#   float batch (16 rows): f64 FLOAT64, each value given by its BIT PATTERN
#   (`float_edge_bits`), so -0.0, the NaN payloads and the subnormals are
#   exactly what the test means, not what a decimal literal parses to. The
#   expected text spellings (`float_edge_text`) are the shortest decimal that
#   reads back to the same bits under round-half-even, in the layout Python's
#   repr uses (exponent when the decimal exponent is < -4 or >= 16, a
#   two-digit minimum exponent with an explicit sign, `.0` on an integral
#   value), spelled here by hand, not produced by komira. Row 15 (2^54 + 4)
#   is the case a formatter that treats the rounding boundary as inclusive
#   gets wrong: `1.801439850948199e+16` is the exact midpoint to 2^54 + 8.
#
# Comparisons in the tests are on the bit pattern (`bits_of`), so -0.0 and
# 0.0 differ and each NaN payload is its own value.
# =============================================================================

from std.memory import bitcast

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder


comptime NUM_INT_EDGE_ROWS: Int = 6
comptime NUM_FLOAT_EDGE_ROWS: Int = 16

# Row indices of the float batch with a special role in the tests.
comptime F_NEG_ZERO: Int = 0
comptime F_POS_INF: Int = 8
comptime F_NEG_INF: Int = 9
comptime F_NAN: Int = 10
comptime F_NAN_PAYLOAD: Int = 11
comptime F_NEG_NAN: Int = 12


def int64_edges() -> List[Int64]:
    var out = List[Int64]()
    out.append(Int64(-9223372036854775807) - Int64(1))  # INT64_MIN
    out.append(Int64(9223372036854775807))  # INT64_MAX
    out.append(Int64(-1))
    out.append(Int64(0))
    out.append(Int64(9007199254740993))  # 2^53 + 1
    out.append(Int64(-9007199254740993))
    return out^


def int32_edges() -> List[Int32]:
    var out = List[Int32]()
    out.append(Int32(-2147483647) - Int32(1))  # INT32_MIN
    out.append(Int32(2147483647))  # INT32_MAX
    out.append(Int32(-1))
    out.append(Int32(0))
    out.append(Int32(16777217))  # 2^24 + 1
    out.append(Int32(-16777217))
    return out^


def int64_edge_text() -> List[String]:
    """The decimal spelling of each `int64_edges` value."""
    return [
        String("-9223372036854775808"),
        String("9223372036854775807"),
        String("-1"),
        String("0"),
        String("9007199254740993"),
        String("-9007199254740993"),
    ]


def int32_edge_text() -> List[String]:
    return [
        String("-2147483648"),
        String("2147483647"),
        String("-1"),
        String("0"),
        String("16777217"),
        String("-16777217"),
    ]


def float_edge_bits() -> List[UInt64]:
    """IEEE-754 binary64 bit patterns, one per float row."""
    var out = List[UInt64]()
    out.append(UInt64(0x8000000000000000))  # 0  -0.0
    out.append(UInt64(0x0000000000000000))  # 1  +0.0
    out.append(UInt64(0x0000000000000001))  # 2  smallest subnormal 4.9e-324
    out.append(UInt64(0x8000000000000001))  # 3  its negation
    out.append(UInt64(0x000FFFFFFFFFFFFF))  # 4  largest subnormal
    out.append(UInt64(0x0010000000000000))  # 5  DBL_MIN (smallest normal)
    out.append(UInt64(0x7FEFFFFFFFFFFFFF))  # 6  DBL_MAX
    out.append(UInt64(0xFFEFFFFFFFFFFFFF))  # 7  -DBL_MAX
    out.append(UInt64(0x7FF0000000000000))  # 8  +Inf
    out.append(UInt64(0xFFF0000000000000))  # 9  -Inf
    out.append(UInt64(0x7FF8000000000000))  # 10 quiet NaN, default payload
    out.append(UInt64(0x7FF80000DEADBEEF))  # 11 quiet NaN, payload DEADBEEF
    out.append(UInt64(0xFFF8000000000000))  # 12 quiet NaN, sign bit set
    out.append(UInt64(0x3FD3333333333334))  # 13 0.1 + 0.2 (17 digits)
    out.append(UInt64(0x3FF0000000000001))  # 14 1 + 2^-52 (17 digits)
    out.append(UInt64(0x4350000000000001))  # 15 2^54 + 4 (17 digits, e+16)
    return out^


def float_edge_text() -> List[String]:
    """The shortest round-trip decimal of each finite float row; "" for the
    non-finite rows (8..12), which have no JSON number spelling."""
    return [
        String("-0.0"),
        String("0.0"),
        String("5e-324"),
        String("-5e-324"),
        String("2.225073858507201e-308"),
        String("2.2250738585072014e-308"),
        String("1.7976931348623157e+308"),
        String("-1.7976931348623157e+308"),
        String(""),
        String(""),
        String(""),
        String(""),
        String(""),
        String("0.30000000000000004"),
        String("1.0000000000000002"),
        String("1.8014398509481988e+16"),
    ]


def is_finite_row(r: Int) -> Bool:
    return r < F_POS_INF or r > F_NEG_NAN


def f64_of(bits: UInt64) -> Float64:
    return bitcast[DType.float64, 1](bits)


def bits_of(v: Float64) -> UInt64:
    return bitcast[DType.uint64, 1](v)


def int_edge_batch() raises -> RecordBatch:
    """(i64 INT64, i32 INT32), non-nullable, the `int64_edges` /
    `int32_edges` rows."""
    var a = int64_edges()
    var b = int32_edges()
    var i64 = PrimitiveArray[DType.int64].allocate(len(a))
    var i32 = PrimitiveArray[DType.int32].allocate(len(b))
    for r in range(len(a)):
        i64.set(r, a[r])
        i32.set(r, b[r])
    var sb = SchemaBuilder()
    sb.add_field(Field("i64", ArrowType.INT64, False))
    sb.add_field(Field("i32", ArrowType.INT32, False))
    var builder = RecordBatchBuilder.with_capacity(2)
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](i64^, ArrowType.INT64)
    )
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](i32^, ArrowType.INT32)
    )
    return builder.build(sb.build())


def float_batch_of_bits(bits: List[UInt64]) raises -> RecordBatch:
    """One non-nullable FLOAT64 column `f64` holding `bits` row by row."""
    var f = PrimitiveArray[DType.float64].allocate(len(bits))
    for r in range(len(bits)):
        f.set(r, f64_of(bits[r]))
    var sb = SchemaBuilder()
    sb.add_field(Field("f64", ArrowType.FLOAT64, False))
    var builder = RecordBatchBuilder.with_capacity(1)
    builder.add_column(Column.from_primitive[DType.float64](f^))
    return builder.build(sb.build())


def float_edge_batch() raises -> RecordBatch:
    return float_batch_of_bits(float_edge_bits())
