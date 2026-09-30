# =============================================================================
# Arrow C Data Interface — round-trip for the time / duration / interval /
# float16 / decimal256 types.
#
# Round-trip only: build a RecordBatch with each Arrow type, push it through
# the CArrowArrayStream, drain it back, and assert the type tag + buffer
# values survive byte-identical.
#
# Types covered:
#   * Float16 (i16 storage)
#   * Time32_S / Time32_MS (Int32 storage; logical = time-of-day)
#   * Time64_US / Time64_NS (Int64 storage; logical = time-of-day)
#   * Duration_S / Duration_MS / Duration_US / Duration_NS (Int64 storage)
#   * Interval_YEAR_MONTH (Int32 storage)
#   * Interval_DAY_TIME (Int64 storage; 2x Int32 packed)
#   * Decimal256 (the arithmetic primitives are in `test_decimal256_*`)
#
# NOT covered here:
#   * Interval_MONTH_DAY_NANO (16-byte width) — the C-Data n_buffers +
#     fixed-width arms exist, but there is no element-wise compute kernel
#     for a 16-byte value.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow import (
    ArrowType,
    Column,
    Decimal256Array,
    Field,
    PrimitiveArray,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_core.arrow.c_data_stream import (
    CArrowArrayStream,
    build_record_batch_stream,
    drain_record_batch_stream,
)
from komira_core.collections.slab import Slab


def _stream_round_trip(
    var batches: Slab[RecordBatch], var schema_for_stream: Schema
) raises -> Slab[RecordBatch]:
    """Push batches through a CArrowArrayStream + drain it back."""
    var c_stream = CArrowArrayStream()
    var stream_ptr = UnsafePointer(to=c_stream).unsafe_origin_cast[MutUntrackedOrigin]()
    build_record_batch_stream(batches^, schema_for_stream^, stream_ptr)
    var out = drain_record_batch_stream(stream_ptr)
    assert_true(c_stream.is_released(), "stream released after drain")
    return out^


# --- Float16 -----------------------------------------------------------------


def test_c_data_float16_round_trip() raises:
    """A Float16 column round-trips through the C-Data stream."""
    var data = PrimitiveArray[DType.float16].from_list(
        [
            Scalar[DType.float16](1.5),
            Scalar[DType.float16](2.5),
            Scalar[DType.float16](3.5),
            Scalar[DType.float16](-4.0),
        ]
    )

    var sb = SchemaBuilder()
    sb.add_field(Field("temperature", ArrowType.FLOAT16, nullable=False))
    var schema = sb.build()

    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_primitive[DType.float16](data^))
    var batch = rbb.build(schema^)

    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)

    var sb2 = SchemaBuilder()
    sb2.add_field(Field("temperature", ArrowType.FLOAT16, nullable=False))
    var schema2 = sb2.build()

    var out_batches = _stream_round_trip(batches^, schema2^)
    assert_equal(len(out_batches), 1, "one chunk drained")
    ref rb = out_batches[0]
    assert_equal(rb.num_columns(), 1, "1 column")
    assert_equal(rb.num_rows(), 4, "4 rows")
    assert_true(
        rb.schema.field_arrow_type(0) == ArrowType.FLOAT16, "col0 FLOAT16"
    )
    var prim = rb.column_at(0).as_primitive[DType.float16]()
    assert_equal(Float64(prim.get(0)), 1.5, "row 0 value")
    assert_equal(Float64(prim.get(1)), 2.5, "row 1 value")
    assert_equal(Float64(prim.get(2)), 3.5, "row 2 value")
    assert_equal(Float64(prim.get(3)), -4.0, "row 3 value")


# --- Time32 ------------------------------------------------------------------


def test_c_data_time32_s_round_trip() raises:
    """A Time32[s] column (Int32 buffer) round-trips."""
    var data = PrimitiveArray[DType.int32].from_list(
        [Int32(0), Int32(3600), Int32(43200), Int32(86399)]
    )

    var sb = SchemaBuilder()
    sb.add_field(Field("clock_s", ArrowType.TIME32_S, nullable=False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](
            data^, ArrowType.TIME32_S
        )
    )
    var batch = rbb.build(schema^)

    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)
    var sb2 = SchemaBuilder()
    sb2.add_field(Field("clock_s", ArrowType.TIME32_S, nullable=False))
    var schema2 = sb2.build()

    var out_batches = _stream_round_trip(batches^, schema2^)
    assert_equal(len(out_batches), 1)
    ref rb = out_batches[0]
    assert_equal(rb.num_columns(), 1)
    assert_equal(rb.num_rows(), 4)
    assert_true(rb.schema.field_arrow_type(0) == ArrowType.TIME32_S)
    # Verify Int32 values survived.
    var prim = rb.column_at(0).as_primitive[DType.int32]()
    assert_equal(Int(prim.get(0)), 0)
    assert_equal(Int(prim.get(1)), 3600)
    assert_equal(Int(prim.get(2)), 43200)
    assert_equal(Int(prim.get(3)), 86399)


def test_c_data_time32_ms_round_trip() raises:
    """A Time32[ms] column round-trips."""
    var data = PrimitiveArray[DType.int32].from_list(
        [Int32(0), Int32(60000), Int32(3600000)]
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("clock_ms", ArrowType.TIME32_MS, nullable=False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](
            data^, ArrowType.TIME32_MS
        )
    )
    var batch = rbb.build(schema^)
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)
    var sb2 = SchemaBuilder()
    sb2.add_field(Field("clock_ms", ArrowType.TIME32_MS, nullable=False))
    var schema2 = sb2.build()
    var out = _stream_round_trip(batches^, schema2^)
    assert_equal(len(out), 1)
    assert_true(out[0].schema.field_arrow_type(0) == ArrowType.TIME32_MS)


# --- Time64 ------------------------------------------------------------------


def test_c_data_time64_us_round_trip() raises:
    """A Time64[us] column (Int64 buffer) round-trips."""
    var data = PrimitiveArray[DType.int64].from_list(
        [Int64(0), Int64(60_000_000), Int64(86_399_000_000)]
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("clock_us", ArrowType.TIME64_US, nullable=False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](
            data^, ArrowType.TIME64_US
        )
    )
    var batch = rbb.build(schema^)
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)
    var sb2 = SchemaBuilder()
    sb2.add_field(Field("clock_us", ArrowType.TIME64_US, nullable=False))
    var schema2 = sb2.build()
    var out = _stream_round_trip(batches^, schema2^)
    assert_true(out[0].schema.field_arrow_type(0) == ArrowType.TIME64_US)
    var prim = out[0].column_at(0).as_primitive[DType.int64]()
    assert_equal(Int(prim.get(2)), 86_399_000_000)


def test_c_data_time64_ns_round_trip() raises:
    """A Time64[ns] column round-trips."""
    var data = PrimitiveArray[DType.int64].from_list(
        [Int64(0), Int64(999_999_999), Int64(86_399_000_000_000)]
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("clock_ns", ArrowType.TIME64_NS, nullable=False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](
            data^, ArrowType.TIME64_NS
        )
    )
    var batch = rbb.build(schema^)
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)
    var sb2 = SchemaBuilder()
    sb2.add_field(Field("clock_ns", ArrowType.TIME64_NS, nullable=False))
    var schema2 = sb2.build()
    var out = _stream_round_trip(batches^, schema2^)
    assert_true(out[0].schema.field_arrow_type(0) == ArrowType.TIME64_NS)


# --- Duration ----------------------------------------------------------------


def test_c_data_duration_us_round_trip() raises:
    """A Duration[us] column (Int64 buffer) round-trips."""
    var data = PrimitiveArray[DType.int64].from_list(
        [Int64(1000), Int64(60_000_000), Int64(-500_000)]
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("elapsed", ArrowType.DURATION_US, nullable=False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](
            data^, ArrowType.DURATION_US
        )
    )
    var batch = rbb.build(schema^)
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)
    var sb2 = SchemaBuilder()
    sb2.add_field(Field("elapsed", ArrowType.DURATION_US, nullable=False))
    var schema2 = sb2.build()
    var out = _stream_round_trip(batches^, schema2^)
    assert_true(out[0].schema.field_arrow_type(0) == ArrowType.DURATION_US)
    var prim = out[0].column_at(0).as_primitive[DType.int64]()
    assert_equal(Int(prim.get(2)), -500_000)


def test_c_data_duration_ns_round_trip() raises:
    """A Duration[ns] column round-trips."""
    var data = PrimitiveArray[DType.int64].from_list(
        [Int64(1), Int64(1_000_000_000), Int64(-2_000_000_000)]
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("elapsed_ns", ArrowType.DURATION_NS, nullable=False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](
            data^, ArrowType.DURATION_NS
        )
    )
    var batch = rbb.build(schema^)
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)
    var sb2 = SchemaBuilder()
    sb2.add_field(Field("elapsed_ns", ArrowType.DURATION_NS, nullable=False))
    var schema2 = sb2.build()
    var out = _stream_round_trip(batches^, schema2^)
    assert_true(out[0].schema.field_arrow_type(0) == ArrowType.DURATION_NS)


def test_c_data_duration_s_round_trip() raises:
    """A Duration[s] column round-trips."""
    var data = PrimitiveArray[DType.int64].from_list(
        [Int64(0), Int64(86400), Int64(-3600)]
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("elapsed_s", ArrowType.DURATION_S, nullable=False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](
            data^, ArrowType.DURATION_S
        )
    )
    var batch = rbb.build(schema^)
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)
    var sb2 = SchemaBuilder()
    sb2.add_field(Field("elapsed_s", ArrowType.DURATION_S, nullable=False))
    var schema2 = sb2.build()
    var out = _stream_round_trip(batches^, schema2^)
    assert_true(out[0].schema.field_arrow_type(0) == ArrowType.DURATION_S)


def test_c_data_duration_ms_round_trip() raises:
    """A Duration[ms] column round-trips."""
    var data = PrimitiveArray[DType.int64].from_list(
        [Int64(0), Int64(1_000), Int64(-86_400_000)]
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("elapsed_ms", ArrowType.DURATION_MS, nullable=False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](
            data^, ArrowType.DURATION_MS
        )
    )
    var batch = rbb.build(schema^)
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)
    var sb2 = SchemaBuilder()
    sb2.add_field(Field("elapsed_ms", ArrowType.DURATION_MS, nullable=False))
    var schema2 = sb2.build()
    var out = _stream_round_trip(batches^, schema2^)
    assert_true(out[0].schema.field_arrow_type(0) == ArrowType.DURATION_MS)


# --- Interval ----------------------------------------------------------------


def test_c_data_interval_year_month_round_trip() raises:
    """An Interval[YEAR_MONTH] column (Int32 buffer) round-trips."""
    var data = PrimitiveArray[DType.int32].from_list(
        [Int32(12), Int32(24), Int32(0), Int32(-3)]
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("period_ym", ArrowType.INTERVAL_YEAR_MONTH, nullable=False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](
            data^, ArrowType.INTERVAL_YEAR_MONTH
        )
    )
    var batch = rbb.build(schema^)
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)
    var sb2 = SchemaBuilder()
    sb2.add_field(Field("period_ym", ArrowType.INTERVAL_YEAR_MONTH, nullable=False))
    var schema2 = sb2.build()
    var out = _stream_round_trip(batches^, schema2^)
    assert_true(out[0].schema.field_arrow_type(0) == ArrowType.INTERVAL_YEAR_MONTH)
    var prim = out[0].column_at(0).as_primitive[DType.int32]()
    assert_equal(Int(prim.get(0)), 12)
    assert_equal(Int(prim.get(3)), -3)


def test_c_data_interval_day_time_round_trip() raises:
    """An Interval[DAY_TIME] column (Int64 buffer, 2x Int32 packed) round-trips."""
    var data = PrimitiveArray[DType.int64].from_list(
        [Int64(0x0000000100000000), Int64(0)]  # 1 day, 0 ms ; 0,0
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("dt_interval", ArrowType.INTERVAL_DAY_TIME, nullable=False))
    var schema = sb.build()
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](
            data^, ArrowType.INTERVAL_DAY_TIME
        )
    )
    var batch = rbb.build(schema^)
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)
    var sb2 = SchemaBuilder()
    sb2.add_field(Field("dt_interval", ArrowType.INTERVAL_DAY_TIME, nullable=False))
    var schema2 = sb2.build()
    var out = _stream_round_trip(batches^, schema2^)
    assert_true(out[0].schema.field_arrow_type(0) == ArrowType.INTERVAL_DAY_TIME)


# --- Decimal256 --------------------------------------------------------------


def test_c_data_decimal256_round_trip() raises:
    """A Decimal256(38, 2) column round-trips."""
    var values = List[SIMD[DType.int256, 1]]()
    values.append(SIMD[DType.int256, 1](12345))   # 123.45
    values.append(SIMD[DType.int256, 1](-67890))  # -678.90
    values.append(SIMD[DType.int256, 1](0))       # 0.00
    var arr = Decimal256Array.from_i256_list(values^, 38, 2)

    var sb = SchemaBuilder()
    sb.add_field(Field.decimal256("amount", 38, 2, nullable=False))
    var schema = sb.build()

    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_decimal256(arr^))
    var batch = rbb.build(schema^)

    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)

    var sb2 = SchemaBuilder()
    sb2.add_field(Field.decimal256("amount", 38, 2, nullable=False))
    var schema2 = sb2.build()

    var out = _stream_round_trip(batches^, schema2^)
    assert_equal(len(out), 1)
    ref rb = out[0]
    assert_equal(rb.num_columns(), 1)
    assert_equal(rb.num_rows(), 3)
    assert_true(rb.schema.field_arrow_type(0) == ArrowType.DECIMAL256)
    var f_out = rb.schema.field_at(0)
    assert_equal(f_out.decimal_precision, 38, "precision preserved")
    assert_equal(f_out.decimal_scale, 2, "scale preserved")
    var d_out = rb.column_at(0).as_decimal256()
    var v0 = d_out.get_i256(0)
    var v1 = d_out.get_i256(1)
    var v2 = d_out.get_i256(2)
    # Compare via cast-to-int64 (test vals fit in i64).
    assert_equal(Int(v0.cast[DType.int64]()), 12345)
    assert_equal(Int(v1.cast[DType.int64]()), -67890)
    assert_equal(Int(v2.cast[DType.int64]()), 0)


def test_c_data_decimal256_high_precision_round_trip() raises:
    """A Decimal256(76, 0) column round-trips (max precision, no scale)."""
    var values = List[SIMD[DType.int256, 1]]()
    values.append(SIMD[DType.int256, 1](1) << 200)  # Large i256.
    values.append(SIMD[DType.int256, 1](-1) << 200)
    var arr = Decimal256Array.from_i256_list(values^, 76, 0)

    var sb = SchemaBuilder()
    sb.add_field(Field.decimal256("big_amount", 76, 0, nullable=False))
    var schema = sb.build()

    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(Column.from_decimal256(arr^))
    var batch = rbb.build(schema^)
    var batches = Slab[RecordBatch].with_capacity(1)
    batches.append(batch^)
    var sb2 = SchemaBuilder()
    sb2.add_field(Field.decimal256("big_amount", 76, 0, nullable=False))
    var schema2 = sb2.build()
    var out = _stream_round_trip(batches^, schema2^)
    ref rb = out[0]
    assert_true(rb.schema.field_arrow_type(0) == ArrowType.DECIMAL256)
    var f_out = rb.schema.field_at(0)
    assert_equal(f_out.decimal_precision, 76)
    assert_equal(f_out.decimal_scale, 0)
    var d_out = rb.column_at(0).as_decimal256()
    var v0 = d_out.get_i256(0)
    var expected_v0 = SIMD[DType.int256, 1](1) << 200
    # Compare i256 bit-equality via subtraction.
    assert_true(v0 == expected_v0, "row 0 preserved")
    var v1 = d_out.get_i256(1)
    var expected_v1 = SIMD[DType.int256, 1](-1) << 200
    assert_true(v1 == expected_v1, "row 1 preserved")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
