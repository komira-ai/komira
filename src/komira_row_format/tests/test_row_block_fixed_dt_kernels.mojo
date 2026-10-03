# =============================================================================
# Tests for komira_row_format.RowBlock — per-DType cell kernels
# =============================================================================
#
# Round-trip byte-identity for each of the 11 fixed-width DTypes through
# the RowBlock per-DType encoder + decoder pair.
#
# DType coverage (one test fn per DType, all are batch round-trips):
#   1. I64  — write_i64_batch  + read_i64_batch  (W=8 SIMD-staged)
#   2. F64  — write_f64_batch  + read_f64_batch  (W=8 SIMD-staged)
#   3. I32  — write_i32_batch  + read_i32_batch  (W=16 SIMD-staged)
#   4. F32  — write_f32_batch  + read_f32_batch  (W=16 SIMD-staged)
#   5. I16  — write_i16_batch  + read_i16_batch  (W=32 SIMD-staged)
#   6. U16  — write_u16_batch  + read_u16_batch  (W=32 SIMD-staged)
#   7. I8   — write_i8_batch   + read_i8_batch   (W=64 SIMD-staged)
#   8. U8   — write_u8_batch   + read_u8_batch   (W=64 SIMD-staged)
#   9. U32  — write_u32_batch  + read_u32_batch  (W=16 SIMD-staged)
#  10. U64  — write_u64_batch  + read_u64_batch  (W=8 SIMD-staged)
#  11. Date32 — write_date32_batch + read_date32_batch (W=16; i32 storage)
#  12. Date64 — write_date64_batch + read_date64_batch (W=8;  i64 storage)
#  13. Timestamp_ns/us/ms/s — i64 storage; W=8 SIMD-staged
#  14. Bool   — write_bool_batch + read_bool_batch (W=64 chunked; 1 byte/cell)
#  15. Decimal128 — write_decimal128_batch + read_decimal128_batch
#                  (16 bytes/cell = 2× u64 LO+HI; W=8 each)
#
# Test pattern (each fn):
#   1. Construct a RecordBatch from a known input List[Scalar[DT]].
#   2. Wrap via batch_view_over; get ColView[DT, _].
#   3. Pre-allocate RowBlock with capacity n, fixed_row_stride = sizeof(DT).
#   4. Encode via write_<dt>_batch(col, col_offset_in_row=0).
#   5. Decode via read_<dt>_batch(0).
#   6. Assert read-back list == original input (byte-identity).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Field, SchemaBuilder
from komira_core.arrow.decimal_array import Decimal128Array
from komira_core.collections.batch_view import batch_view_over

from komira_row_format.row_block import RowBlock


# -----------------------------------------------------------------------------
# Helpers — build one-column RecordBatches per DType
# -----------------------------------------------------------------------------

def _make_i64_rb(values: List[Scalar[DType.int64]]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("c"), ArrowType.INT64, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(values)
        )
    )
    return rbb.build(schema^)


def _make_f64_rb(values: List[Scalar[DType.float64]]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("c"), ArrowType.FLOAT64, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].from_list(values)
        )
    )
    return rbb.build(schema^)


def _make_i32_rb(values: List[Scalar[DType.int32]]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("c"), ArrowType.INT32, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive[DType.int32](
            PrimitiveArray[DType.int32].from_list(values)
        )
    )
    return rbb.build(schema^)


def _make_f32_rb(values: List[Scalar[DType.float32]]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("c"), ArrowType.FLOAT32, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive[DType.float32](
            PrimitiveArray[DType.float32].from_list(values)
        )
    )
    return rbb.build(schema^)


def _make_i16_rb(values: List[Scalar[DType.int16]]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("c"), ArrowType.INT16, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive[DType.int16](
            PrimitiveArray[DType.int16].from_list(values)
        )
    )
    return rbb.build(schema^)


def _make_u16_rb(values: List[Scalar[DType.uint16]]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("c"), ArrowType.UINT16, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive[DType.uint16](
            PrimitiveArray[DType.uint16].from_list(values)
        )
    )
    return rbb.build(schema^)


def _make_i8_rb(values: List[Scalar[DType.int8]]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("c"), ArrowType.INT8, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive[DType.int8](
            PrimitiveArray[DType.int8].from_list(values)
        )
    )
    return rbb.build(schema^)


def _make_u8_rb(values: List[Scalar[DType.uint8]]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("c"), ArrowType.UINT8, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive[DType.uint8](
            PrimitiveArray[DType.uint8].from_list(values)
        )
    )
    return rbb.build(schema^)


def _make_u32_rb(values: List[Scalar[DType.uint32]]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("c"), ArrowType.UINT32, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive[DType.uint32](
            PrimitiveArray[DType.uint32].from_list(values)
        )
    )
    return rbb.build(schema^)


def _make_u64_rb(values: List[Scalar[DType.uint64]]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("c"), ArrowType.UINT64, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive[DType.uint64](
            PrimitiveArray[DType.uint64].from_list(values)
        )
    )
    return rbb.build(schema^)


def _make_date32_rb(values: List[Scalar[DType.int32]]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("c"), ArrowType.DATE32, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive[DType.int32](
            PrimitiveArray[DType.int32].from_list(values)
        )
    )
    return rbb.build(schema^)


def _make_bool_rb(values: List[Bool]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("c"), ArrowType.BOOL, False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    var n = len(values)
    var ba = BooleanArray.allocate(n)
    for i in range(n):
        ba.set(i, values[i])
    rbb.add_column(Column.from_boolean(ba))
    return rbb.build(schema^)


def _make_decimal128_rb(
    lo_vals: List[Scalar[DType.uint64]],
    hi_vals: List[Scalar[DType.uint64]],
) raises -> RecordBatch:
    """Build a 1-column RecordBatch: a real 16-byte-per-row DECIMAL128 column.

    Each row's 128-bit cell is `[lo u64 @ +0 | hi u64 @ +8]` (little-endian),
    the canonical Arrow Decimal128 layout that `BatchView.col_decimal128_lo/hi`
    read at a **16-byte stride**. A fixture of two SEPARATE plain-u64 columns
    at an 8-byte stride would mis-read every row >= 1 through the
    `Decimal128CellView`s (`col_lo.load(1)` lands on row 2's lo half). Building one
    genuine 16-byte cell column is the production shape (the same
    `Column.from_decimal128` the join/agg/sort untyped paths read via
    `col_decimal128_lo`).
    """
    var n = len(lo_vals)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("dec"), ArrowType.DECIMAL128, False))
    var schema = sb.build()
    var arr = Decimal128Array.allocate(n, precision=38, scale=0)
    for i in range(n):
        # set_raw writes low @ (i*16 + 0) and high @ (i*16 + 8) as LE 64-bit
        # words. The u64 halves reinterpret to i64 bits (same-width cast is a
        # bit-preserving reinterpret), so the stored bytes are byte-identical to
        # the input u64 halves.
        arr.set_raw(
            i, lo_vals[i].cast[DType.int64](), hi_vals[i].cast[DType.int64]()
        )
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_decimal128(arr^))
    return rbb.build(schema^)


# -----------------------------------------------------------------------------
# DType-specific round-trip tests (one fn per DType)
# -----------------------------------------------------------------------------


def test_row_block_i64_batch_round_trip() raises:
    """I64 round-trip: write_i64_batch → read_i64_batch byte-identity.

    Input: n=10 values including extremes + mid-range (covers the full
    chunk+tail path: W=8 SIMD chunk for 0..8, scalar tail for 8..10).
    """
    var input = List[Scalar[DType.int64]]()
    input.append(Scalar[DType.int64](0))
    input.append(Scalar[DType.int64](-1))
    input.append(Scalar[DType.int64](1))
    input.append(Scalar[DType.int64](9223372036854775807))   # INT64_MAX
    input.append(Scalar[DType.int64](-9223372036854775807 - 1))  # INT64_MIN
    input.append(Scalar[DType.int64](42))
    input.append(Scalar[DType.int64](-42))
    input.append(Scalar[DType.int64](1024))
    input.append(Scalar[DType.int64](-1024))
    input.append(Scalar[DType.int64](7))

    var rb_in = _make_i64_rb(input)
    var bv = batch_view_over(rb_in)
    var col = bv.col_i64(0)

    var rb = RowBlock(8)
    rb.write_i64_batch(col, 0)

    assert_equal(rb.n_rows, 10)
    var out = rb.read_i64_batch(0)
    assert_equal(out.__len__(), 10)
    for i in range(10):
        assert_equal(out[i], input[i])


def test_row_block_f64_batch_round_trip() raises:
    """F64 round-trip — bit-exact through bitcast (no fp comparison)."""
    var input = List[Scalar[DType.float64]]()
    input.append(Scalar[DType.float64](0.0))
    input.append(Scalar[DType.float64](-0.0))
    input.append(Scalar[DType.float64](3.141592653589793))
    input.append(Scalar[DType.float64](-2.718281828459045))
    input.append(Scalar[DType.float64](1.0))
    input.append(Scalar[DType.float64](-1.0))
    input.append(Scalar[DType.float64](1.7976931348623157e308))   # F64_MAX
    input.append(Scalar[DType.float64](2.2250738585072014e-308))  # F64_MIN_POS_NORMAL
    input.append(Scalar[DType.float64](42.0))
    input.append(Scalar[DType.float64](-42.5))

    var rb_in = _make_f64_rb(input)
    var bv = batch_view_over(rb_in)
    var col = bv.col_f64(0)

    var rb = RowBlock(8)
    rb.write_f64_batch(col, 0)

    assert_equal(rb.n_rows, 10)
    var out = rb.read_f64_batch(0)
    assert_equal(out.__len__(), 10)
    for i in range(10):
        assert_equal(out[i], input[i])


def test_row_block_i32_batch_round_trip() raises:
    """I32 round-trip: W=16 SIMD chunk + tail."""
    var input = List[Scalar[DType.int32]]()
    input.append(Scalar[DType.int32](0))
    input.append(Scalar[DType.int32](-1))
    input.append(Scalar[DType.int32](2147483647))     # INT32_MAX
    input.append(Scalar[DType.int32](-2147483648))    # INT32_MIN
    input.append(Scalar[DType.int32](42))
    input.append(Scalar[DType.int32](-42))
    input.append(Scalar[DType.int32](1024))
    input.append(Scalar[DType.int32](-1024))
    input.append(Scalar[DType.int32](7))
    input.append(Scalar[DType.int32](-7))

    var rb_in = _make_i32_rb(input)
    var bv = batch_view_over(rb_in)
    var col = bv.col_i32(0)

    var rb = RowBlock(4)
    rb.write_i32_batch(col, 0)

    assert_equal(rb.n_rows, 10)
    var out = rb.read_i32_batch(0)
    assert_equal(out.__len__(), 10)
    for i in range(10):
        assert_equal(out[i], input[i])


def test_row_block_f32_batch_round_trip() raises:
    """F32 round-trip."""
    var input = List[Scalar[DType.float32]]()
    input.append(Scalar[DType.float32](0.0))
    input.append(Scalar[DType.float32](3.14159))
    input.append(Scalar[DType.float32](-2.71828))
    input.append(Scalar[DType.float32](1.0))
    input.append(Scalar[DType.float32](-1.0))
    input.append(Scalar[DType.float32](42.0))
    input.append(Scalar[DType.float32](-42.5))
    input.append(Scalar[DType.float32](100.0))
    input.append(Scalar[DType.float32](-100.0))
    input.append(Scalar[DType.float32](1.5))

    var rb_in = _make_f32_rb(input)
    var bv = batch_view_over(rb_in)
    var col = bv.col_f32(0)

    var rb = RowBlock(4)
    rb.write_f32_batch(col, 0)

    assert_equal(rb.n_rows, 10)
    var out = rb.read_f32_batch(0)
    assert_equal(out.__len__(), 10)
    for i in range(10):
        assert_equal(out[i], input[i])


def test_row_block_i16_batch_round_trip() raises:
    """I16 round-trip — SIMD-staged W=32.

    Input: 40 rows = 1 full W=32 chunk + 8-row tail. Verifies both the
    @parameter for lane in range(32) chunk path AND the scalar tail loop.
    """
    var input = List[Scalar[DType.int16]]()
    # Chunk: 32 rows
    for i in range(32):
        input.append(Scalar[DType.int16](i * 100 - 1000))
    # Tail: 8 rows
    input.append(Scalar[DType.int16](32767))    # INT16_MAX
    input.append(Scalar[DType.int16](-32768))   # INT16_MIN
    input.append(Scalar[DType.int16](0))
    input.append(Scalar[DType.int16](-1))
    input.append(Scalar[DType.int16](1))
    input.append(Scalar[DType.int16](256))
    input.append(Scalar[DType.int16](-256))
    input.append(Scalar[DType.int16](42))

    var rb_in = _make_i16_rb(input)
    var bv = batch_view_over(rb_in)
    var col = bv.col_i16(0)

    var rb = RowBlock(2)
    rb.write_i16_batch(col, 0)

    assert_equal(rb.n_rows, 40)
    var out = rb.read_i16_batch(0)
    assert_equal(out.__len__(), 40)
    for i in range(40):
        assert_equal(out[i], input[i])


def test_row_block_u16_batch_round_trip() raises:
    """U16 round-trip — SIMD-staged W=32."""
    var input = List[Scalar[DType.uint16]]()
    for i in range(32):
        input.append(Scalar[DType.uint16](i * 200))
    input.append(Scalar[DType.uint16](65535))   # UINT16_MAX
    input.append(Scalar[DType.uint16](0))
    input.append(Scalar[DType.uint16](1))
    input.append(Scalar[DType.uint16](256))
    input.append(Scalar[DType.uint16](512))
    input.append(Scalar[DType.uint16](1024))
    input.append(Scalar[DType.uint16](2048))
    input.append(Scalar[DType.uint16](42))

    var rb_in = _make_u16_rb(input)
    var bv = batch_view_over(rb_in)
    var col = bv.col_u16(0)

    var rb = RowBlock(2)
    rb.write_u16_batch(col, 0)

    assert_equal(rb.n_rows, 40)
    var out = rb.read_u16_batch(0)
    assert_equal(out.__len__(), 40)
    for i in range(40):
        assert_equal(out[i], input[i])


def test_row_block_i8_batch_round_trip() raises:
    """I8 round-trip — SIMD-staged W=64.

    Input: 80 rows = 1 full W=64 chunk + 16-row tail.
    """
    var input = List[Scalar[DType.int8]]()
    # Chunk: 64 rows with cycle of values
    for i in range(64):
        # Map i ∈ [0, 64) onto [-128, 127] sparse.
        var v = (i * 4 - 128) % 256
        if v > 127:
            v = v - 256
        input.append(Scalar[DType.int8](v))
    # Tail: 16 rows
    input.append(Scalar[DType.int8](127))    # INT8_MAX
    input.append(Scalar[DType.int8](-128))   # INT8_MIN
    input.append(Scalar[DType.int8](0))
    input.append(Scalar[DType.int8](-1))
    input.append(Scalar[DType.int8](1))
    input.append(Scalar[DType.int8](42))
    input.append(Scalar[DType.int8](-42))
    input.append(Scalar[DType.int8](100))
    input.append(Scalar[DType.int8](-100))
    input.append(Scalar[DType.int8](64))
    input.append(Scalar[DType.int8](-64))
    input.append(Scalar[DType.int8](32))
    input.append(Scalar[DType.int8](-32))
    input.append(Scalar[DType.int8](16))
    input.append(Scalar[DType.int8](-16))
    input.append(Scalar[DType.int8](8))

    var rb_in = _make_i8_rb(input)
    var bv = batch_view_over(rb_in)
    var col = bv.col_i8(0)

    var rb = RowBlock(1)
    rb.write_i8_batch(col, 0)

    assert_equal(rb.n_rows, 80)
    var out = rb.read_i8_batch(0)
    assert_equal(out.__len__(), 80)
    for i in range(80):
        assert_equal(out[i], input[i])


def test_row_block_u8_batch_round_trip() raises:
    """U8 round-trip — SIMD-staged W=64."""
    var input = List[Scalar[DType.uint8]]()
    for i in range(64):
        input.append(Scalar[DType.uint8]((i * 4) % 256))
    input.append(Scalar[DType.uint8](255))   # UINT8_MAX
    input.append(Scalar[DType.uint8](0))
    input.append(Scalar[DType.uint8](128))
    input.append(Scalar[DType.uint8](42))
    input.append(Scalar[DType.uint8](200))
    input.append(Scalar[DType.uint8](100))
    input.append(Scalar[DType.uint8](50))
    input.append(Scalar[DType.uint8](25))
    input.append(Scalar[DType.uint8](12))
    input.append(Scalar[DType.uint8](6))
    input.append(Scalar[DType.uint8](3))
    input.append(Scalar[DType.uint8](1))
    input.append(Scalar[DType.uint8](7))
    input.append(Scalar[DType.uint8](15))
    input.append(Scalar[DType.uint8](31))
    input.append(Scalar[DType.uint8](63))

    var rb_in = _make_u8_rb(input)
    var bv = batch_view_over(rb_in)
    var col = bv.col_u8(0)

    var rb = RowBlock(1)
    rb.write_u8_batch(col, 0)

    assert_equal(rb.n_rows, 80)
    var out = rb.read_u8_batch(0)
    assert_equal(out.__len__(), 80)
    for i in range(80):
        assert_equal(out[i], input[i])


def test_row_block_u32_batch_round_trip() raises:
    """U32 round-trip — W=16 SIMD chunk + tail."""
    var input = List[Scalar[DType.uint32]]()
    for i in range(16):
        input.append(Scalar[DType.uint32](i * 1000))
    input.append(Scalar[DType.uint32](4294967295))  # UINT32_MAX
    input.append(Scalar[DType.uint32](0))
    input.append(Scalar[DType.uint32](1))
    input.append(Scalar[DType.uint32](42))

    var rb_in = _make_u32_rb(input)
    var bv = batch_view_over(rb_in)
    var col = bv.col_u32(0)

    var rb = RowBlock(4)
    rb.write_u32_batch(col, 0)

    assert_equal(rb.n_rows, 20)
    var out = rb.read_u32_batch(0)
    assert_equal(out.__len__(), 20)
    for i in range(20):
        assert_equal(out[i], input[i])


def test_row_block_u64_batch_round_trip() raises:
    """U64 round-trip — W=8 SIMD chunk + tail."""
    var input = List[Scalar[DType.uint64]]()
    for i in range(8):
        input.append(Scalar[DType.uint64](i * 1000000))
    input.append(Scalar[DType.uint64](18446744073709551615))  # UINT64_MAX
    input.append(Scalar[DType.uint64](0))
    input.append(Scalar[DType.uint64](1))
    input.append(Scalar[DType.uint64](42))

    var rb_in = _make_u64_rb(input)
    var bv = batch_view_over(rb_in)
    var col = bv.col_u64(0)

    var rb = RowBlock(8)
    rb.write_u64_batch(col, 0)

    assert_equal(rb.n_rows, 12)
    var out = rb.read_u64_batch(0)
    assert_equal(out.__len__(), 12)
    for i in range(12):
        assert_equal(out[i], input[i])


def test_row_block_date32_batch_round_trip() raises:
    """Date32 round-trip — i32 storage; W=16 SIMD."""
    var input = List[Scalar[DType.int32]]()
    # Days since 1970-01-01 — example dates
    input.append(Scalar[DType.int32](0))           # 1970-01-01
    input.append(Scalar[DType.int32](1))           # 1970-01-02
    input.append(Scalar[DType.int32](-1))          # 1969-12-31
    input.append(Scalar[DType.int32](18628))       # 2020-12-12 (approx)
    input.append(Scalar[DType.int32](20000))
    input.append(Scalar[DType.int32](21000))
    input.append(Scalar[DType.int32](22000))
    input.append(Scalar[DType.int32](23000))
    input.append(Scalar[DType.int32](-365))        # 1969-01-01
    input.append(Scalar[DType.int32](-730))        # 1968-01-02

    var rb_in = _make_date32_rb(input)
    var bv = batch_view_over(rb_in)
    var col = bv.col_date32(0)

    var rb = RowBlock(4)
    rb.write_date32_batch(col, 0)

    assert_equal(rb.n_rows, 10)
    var out = rb.read_date32_batch(0)
    assert_equal(out.__len__(), 10)
    for i in range(10):
        assert_equal(out[i], input[i])


def test_row_block_date64_batch_round_trip() raises:
    """Date64 round-trip — i64 storage (ms since epoch); W=8 SIMD."""
    var input = List[Scalar[DType.int64]]()
    input.append(Scalar[DType.int64](0))                     # epoch
    input.append(Scalar[DType.int64](86400000))              # +1 day
    input.append(Scalar[DType.int64](-86400000))             # -1 day
    input.append(Scalar[DType.int64](1609459200000))         # 2021-01-01 (~ms)
    input.append(Scalar[DType.int64](-31536000000))          # -1 year ms
    input.append(Scalar[DType.int64](1000000000))            # 1B ms
    input.append(Scalar[DType.int64](500000000))             # 500M ms
    input.append(Scalar[DType.int64](250000000))             # 250M ms
    input.append(Scalar[DType.int64](125000000))             # 125M ms
    input.append(Scalar[DType.int64](42000000))              # 42M ms

    # Use INT64 Arrow schema — Date64 is stored as i64 internally; we route
    # via the i64 col accessor for the input fixture, since these
    # tests round-trip the BYTE-IDENTITY through RowBlock.
    var rb_in = _make_i64_rb(input)
    var bv = batch_view_over(rb_in)
    var col = bv.col_date64(0)  # semantic-tagged i64 col accessor

    var rb = RowBlock(8)
    rb.write_date64_batch(col, 0)

    assert_equal(rb.n_rows, 10)
    var out = rb.read_date64_batch(0)
    assert_equal(out.__len__(), 10)
    for i in range(10):
        assert_equal(out[i], input[i])


def test_row_block_timestamp_ns_batch_round_trip() raises:
    """Timestamp_ns round-trip — i64 storage (ns since epoch)."""
    var input = List[Scalar[DType.int64]]()
    input.append(Scalar[DType.int64](0))
    input.append(Scalar[DType.int64](1000000000))           # 1 second
    input.append(Scalar[DType.int64](-1000000000))
    input.append(Scalar[DType.int64](1609459200000000000))  # 2021-01-01 ns
    input.append(Scalar[DType.int64](500000000000))
    input.append(Scalar[DType.int64](1000))
    input.append(Scalar[DType.int64](1))
    input.append(Scalar[DType.int64](-1))
    input.append(Scalar[DType.int64](42))
    input.append(Scalar[DType.int64](999999999))

    var rb_in = _make_i64_rb(input)
    var bv = batch_view_over(rb_in)
    var col = bv.col_timestamp_ns(0)

    var rb = RowBlock(8)
    rb.write_timestamp_ns_batch(col, 0)

    assert_equal(rb.n_rows, 10)
    var out = rb.read_timestamp_ns_batch(0)
    assert_equal(out.__len__(), 10)
    for i in range(10):
        assert_equal(out[i], input[i])


def test_row_block_timestamp_us_batch_round_trip() raises:
    """Timestamp_us round-trip — i64 storage (us since epoch)."""
    var input = List[Scalar[DType.int64]]()
    input.append(Scalar[DType.int64](0))
    input.append(Scalar[DType.int64](1000000))     # 1 second
    input.append(Scalar[DType.int64](-1000000))
    input.append(Scalar[DType.int64](1609459200000000))   # 2021-01-01 us
    input.append(Scalar[DType.int64](500000))
    input.append(Scalar[DType.int64](100))
    input.append(Scalar[DType.int64](1))
    input.append(Scalar[DType.int64](-1))
    input.append(Scalar[DType.int64](42))
    input.append(Scalar[DType.int64](999999))

    var rb_in = _make_i64_rb(input)
    var bv = batch_view_over(rb_in)
    var col = bv.col_timestamp_us(0)

    var rb = RowBlock(8)
    rb.write_timestamp_us_batch(col, 0)

    assert_equal(rb.n_rows, 10)
    var out = rb.read_timestamp_us_batch(0)
    assert_equal(out.__len__(), 10)
    for i in range(10):
        assert_equal(out[i], input[i])


def test_row_block_timestamp_ms_batch_round_trip() raises:
    """Timestamp_ms round-trip — i64 storage (ms since epoch)."""
    var input = List[Scalar[DType.int64]]()
    input.append(Scalar[DType.int64](0))
    input.append(Scalar[DType.int64](1000))          # 1 second
    input.append(Scalar[DType.int64](-1000))
    input.append(Scalar[DType.int64](1609459200000))   # 2021-01-01 ms
    input.append(Scalar[DType.int64](500))
    input.append(Scalar[DType.int64](100))
    input.append(Scalar[DType.int64](1))
    input.append(Scalar[DType.int64](-1))
    input.append(Scalar[DType.int64](42))
    input.append(Scalar[DType.int64](999))

    var rb_in = _make_i64_rb(input)
    var bv = batch_view_over(rb_in)
    var col = bv.col_timestamp_ms(0)

    var rb = RowBlock(8)
    rb.write_timestamp_ms_batch(col, 0)

    assert_equal(rb.n_rows, 10)
    var out = rb.read_timestamp_ms_batch(0)
    assert_equal(out.__len__(), 10)
    for i in range(10):
        assert_equal(out[i], input[i])


def test_row_block_timestamp_s_batch_round_trip() raises:
    """Timestamp_s round-trip — i64 storage (s since epoch)."""
    var input = List[Scalar[DType.int64]]()
    input.append(Scalar[DType.int64](0))
    input.append(Scalar[DType.int64](1))
    input.append(Scalar[DType.int64](-1))
    input.append(Scalar[DType.int64](1609459200))   # 2021-01-01 s
    input.append(Scalar[DType.int64](500))
    input.append(Scalar[DType.int64](100))
    input.append(Scalar[DType.int64](42))
    input.append(Scalar[DType.int64](-42))
    input.append(Scalar[DType.int64](999))
    input.append(Scalar[DType.int64](-999))

    var rb_in = _make_i64_rb(input)
    var bv = batch_view_over(rb_in)
    var col = bv.col_timestamp_s(0)

    var rb = RowBlock(8)
    rb.write_timestamp_s_batch(col, 0)

    assert_equal(rb.n_rows, 10)
    var out = rb.read_timestamp_s_batch(0)
    assert_equal(out.__len__(), 10)
    for i in range(10):
        assert_equal(out[i], input[i])


def test_row_block_bool_batch_round_trip() raises:
    """Bool round-trip — 1 byte per cell unpacked from bit-packed Arrow.

    Input: 80 rows = 1 full W=64 chunk + 16-row tail. Verifies both the
    @parameter for lane in range(64) bit-unpack path AND the scalar tail.
    """
    var input = List[Bool]()
    # Chunk: 64 alternating rows
    for i in range(64):
        input.append((i % 3) != 0)   # mix of True/False
    # Tail: 16 rows
    input.append(True)
    input.append(False)
    input.append(True)
    input.append(True)
    input.append(False)
    input.append(False)
    input.append(True)
    input.append(False)
    input.append(True)
    input.append(False)
    input.append(True)
    input.append(True)
    input.append(False)
    input.append(True)
    input.append(False)
    input.append(False)

    var rb_in = _make_bool_rb(input)
    var bv = batch_view_over(rb_in)
    var col = bv.col_bool(0)

    var rb = RowBlock(1)
    rb.write_bool_batch(col, 0)

    assert_equal(rb.n_rows, 80)
    var out = rb.read_bool_batch(0)
    assert_equal(out.__len__(), 80)
    for i in range(80):
        assert_equal(out[i], input[i])


def test_row_block_decimal128_batch_round_trip() raises:
    """Decimal128 round-trip — 16-byte cells = 2× u64 LO+HI pair.

    Input: n=10 values; each represented as (lo, hi) U64 pair. Encoder
    writes LO at offset 0 and HI at offset 8 (16-byte stride).
    """
    var lo = List[Scalar[DType.uint64]]()
    var hi = List[Scalar[DType.uint64]]()
    # Easy 128-bit test values (lo, hi pairs).
    lo.append(Scalar[DType.uint64](0));                   hi.append(Scalar[DType.uint64](0))
    lo.append(Scalar[DType.uint64](1));                   hi.append(Scalar[DType.uint64](0))
    lo.append(Scalar[DType.uint64](18446744073709551615));  hi.append(Scalar[DType.uint64](0))  # 2^64 - 1
    lo.append(Scalar[DType.uint64](0));                   hi.append(Scalar[DType.uint64](1))    # 2^64
    lo.append(Scalar[DType.uint64](42));                  hi.append(Scalar[DType.uint64](100))
    lo.append(Scalar[DType.uint64](18446744073709551615));  hi.append(Scalar[DType.uint64](18446744073709551615))  # 2^128 - 1
    lo.append(Scalar[DType.uint64](7));                   hi.append(Scalar[DType.uint64](0))
    lo.append(Scalar[DType.uint64](1024));                hi.append(Scalar[DType.uint64](2048))
    lo.append(Scalar[DType.uint64](999999));              hi.append(Scalar[DType.uint64](42))
    lo.append(Scalar[DType.uint64](500));                 hi.append(Scalar[DType.uint64](500))

    var rb_in = _make_decimal128_rb(lo, hi)
    var bv = batch_view_over(rb_in)
    # Both halves now come from the SAME 16-byte DECIMAL128 cell in column 0
    # (lo half at cell byte +0, hi half at cell byte +8) — the single-column
    # Decimal128CellView contract. The prior fixture split lo/hi across two
    # 8-byte columns and read col_hi from column 1.
    var col_lo = bv.col_decimal128_lo(0)
    var col_hi = bv.col_decimal128_hi(0)

    # Decimal128 cell width = 16 bytes (2 × 8).
    var rb = RowBlock(16)
    rb.write_decimal128_batch(col_lo, col_hi, 0)

    assert_equal(rb.n_rows, 10)
    var out_lo = rb.read_decimal128_batch_lo(0)
    var out_hi = rb.read_decimal128_batch_hi(0)
    assert_equal(out_lo.__len__(), 10)
    assert_equal(out_hi.__len__(), 10)
    for i in range(10):
        assert_equal(out_lo[i], lo[i])
        assert_equal(out_hi[i], hi[i])


# -----------------------------------------------------------------------------
# Cross-DType structural test — verifies col_offset_in_row is honored
# for non-zero offsets across multi-DType packed rows.
# -----------------------------------------------------------------------------


def test_row_block_multi_dtype_packed_offsets() raises:
    """Multi-DType packed row: I64 @ 0, F64 @ 8, I32 @ 16, BOOL @ 20.

    Stride = 24. Verifies write_*_batch with explicit col_offset_in_row
    threads the offset correctly through the SIMD-staged kernel for each
    DType simultaneously (mirroring the real HAG/JBT slow-path body
    where multiple key+payload cols share a row).
    """
    var i64_vals = List[Scalar[DType.int64]]()
    var f64_vals = List[Scalar[DType.float64]]()
    var i32_vals = List[Scalar[DType.int32]]()
    var bool_vals = List[Bool]()
    var n = 12
    for i in range(n):
        i64_vals.append(Scalar[DType.int64](i * 1000 + 7))
        f64_vals.append(Scalar[DType.float64](Float64(i) + 0.5))
        i32_vals.append(Scalar[DType.int32](-(i * 100)))
        bool_vals.append((i & 1) == 0)

    var rb_i64 = _make_i64_rb(i64_vals)
    var rb_f64 = _make_f64_rb(f64_vals)
    var rb_i32 = _make_i32_rb(i32_vals)
    var rb_b = _make_bool_rb(bool_vals)

    var bv_i64 = batch_view_over(rb_i64)
    var bv_f64 = batch_view_over(rb_f64)
    var bv_i32 = batch_view_over(rb_i32)
    var bv_b = batch_view_over(rb_b)

    # Row layout: [i64 @ 0..8 | f64 @ 8..16 | i32 @ 16..20 | bool @ 20..21]
    # Total = 21 bytes; round up to 24 for natural alignment.
    var rb = RowBlock(24)
    rb.write_i64_batch(bv_i64.col_i64(0), 0)
    rb.write_f64_batch(bv_f64.col_f64(0), 8)
    rb.write_i32_batch(bv_i32.col_i32(0), 16)
    rb.write_bool_batch(bv_b.col_bool(0), 20)

    assert_equal(rb.n_rows, n)

    # Decode each col back from its offset.
    var out_i64 = rb.read_i64_batch(0)
    var out_f64 = rb.read_f64_batch(8)
    var out_i32 = rb.read_i32_batch(16)
    var out_b = rb.read_bool_batch(20)

    assert_equal(out_i64.__len__(), n)
    assert_equal(out_f64.__len__(), n)
    assert_equal(out_i32.__len__(), n)
    assert_equal(out_b.__len__(), n)
    for i in range(n):
        assert_equal(out_i64[i], i64_vals[i])
        assert_equal(out_f64[i], f64_vals[i])
        assert_equal(out_i32[i], i32_vals[i])
        assert_equal(out_b[i], bool_vals[i])


# -----------------------------------------------------------------------------
# Driver
# -----------------------------------------------------------------------------


def main() raises:
    var s = TestSuite()
    s.test[test_row_block_i64_batch_round_trip]()
    s.test[test_row_block_f64_batch_round_trip]()
    s.test[test_row_block_i32_batch_round_trip]()
    s.test[test_row_block_f32_batch_round_trip]()
    s.test[test_row_block_i16_batch_round_trip]()
    s.test[test_row_block_u16_batch_round_trip]()
    s.test[test_row_block_i8_batch_round_trip]()
    s.test[test_row_block_u8_batch_round_trip]()
    s.test[test_row_block_u32_batch_round_trip]()
    s.test[test_row_block_u64_batch_round_trip]()
    s.test[test_row_block_date32_batch_round_trip]()
    s.test[test_row_block_date64_batch_round_trip]()
    s.test[test_row_block_timestamp_ns_batch_round_trip]()
    s.test[test_row_block_timestamp_us_batch_round_trip]()
    s.test[test_row_block_timestamp_ms_batch_round_trip]()
    s.test[test_row_block_timestamp_s_batch_round_trip]()
    s.test[test_row_block_bool_batch_round_trip]()
    s.test[test_row_block_decimal128_batch_round_trip]()
    s.test[test_row_block_multi_dtype_packed_offsets]()
    s^.run()
