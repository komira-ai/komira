# =============================================================================
# test_avro_data_level_decode.mojo — byte-level value-decode tests for the
#   arrow.* logical types that round-trip via the writer + reader.
# =============================================================================
#
# `test_avro_arrow_logical_round_trip.mojo` covers the SCHEMA-LEVEL
# type-lattice round-trip for the 16 lossy arrow.* types, and the writer's own
# round-trip test asserts values only for DATE64. This test covers the value
# bytes: for each in-scope arrow.* type, write a column carrying a small
# fixture (including edge values: 0, MAX, MIN, NULL, negative for signed) via
# write_avro_bytes -> read it back via read_avro_bytes -> assert byte-exact
# values + null bitmap survive the round-trip.
#
# Scope (9 of 16 arrow.* types) — those that can be value-asserted
# through the existing public Column accessors:
#   INT-backed (1): TIME32_S
#     (INT32 storage; allowlisted in Column.as_primitive[DType.int32].)
#   LONG-backed (8): DATE64, TIMESTAMP_S, TIMESTAMP_NS, TIME64_NS,
#                    DURATION_S, DURATION_MS, DURATION_US, DURATION_NS
#     (INT64 storage; DATE64+TIME64_NS+DURATION_*+TIMESTAMP_* are all
#     allowlisted in Column.as_primitive[DType.int64].)
#
# Not covered yet:
#   - INT8, INT16, UINT8, UINT16: the reader emits Int32 PHYSICAL storage with
#     the narrow arrow.* stamp, but Column.as_primitive[DType.int32] only
#     allowlists the temporal int32-stored types
#     (DATE32/TIME32_*/INTERVAL_YEAR_MONTH). The narrow lossy ints need to be
#     added to that allowlist (or dedicated narrow accessors added) before
#     value-bytes can be asserted.
#   - UINT32: same shape — the reader emits Int64 PHYSICAL with a UINT32
#     stamp; the int64 allowlist must add UINT32 first.
#   - UINT64, FLOAT16 (FIXED-backed): the writer raises in strict_mode on
#     these (see test_avro_write_roundtrip.test_write_strict_mode_raise).
#     Writer FIXED-backed support comes first.
#
# Reader-side reinterpretation note: the Avro reader's typed accumulator
# (action_table._I32Acc / _I64Acc) stamps the recovered arrow.* type on the
# output Column over the underlying Int32 / Int64 physical storage. So we
# fetch values through column_as_primitive_int32 / column_as_primitive_int64
# regardless of the logical type — the value bits are the bits we wrote. The
# arrow_type stamp is asserted separately (schema_field_arrow_type).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field

from komira_avro import (
    AvroWriterOptions,
    write_avro_bytes,
    read_avro_bytes,
    AVRO_CODEC_NULL,
)
from komira_buffer.heap_region import HeapRegion


# =============================================================================
# Builders for INT32-backed and INT64-backed RecordBatches with arrow.* stamps.
# =============================================================================
#
# All 14 in-scope types lower to either an INT32 or an INT64 physical storage
# with the lossy Arrow type stamped via from_primitive_with_arrow_type. The
# Avro write path uses encode_int / encode_long; the read path materializes
# back through _I32Acc / _I64Acc which re-stamp the recovered arrow.* type.


def _i32_col_from_values(
    imm values: List[Int32], imm null_idx: List[Int], at: ArrowType
) raises -> Column[HeapRegion]:
    """Build a NULLABLE INT32-backed Column[HeapRegion] stamped with `at`. `null_idx` lists
    the row indices that should carry a null (value at that slot is ignored).

    Uses the canonical test-side null pattern (cf. test_simd_gapfills_s1):
    allocate_nullable -> set value -> clear validity bit + bump null_count.
    Borrows the input lists so the caller can re-use them for assertion."""
    var n = len(values)
    var arr = PrimitiveArray[DType.int32].allocate_nullable(n)
    for i in range(n):
        arr.set(i, values[i])
    var nc = 0
    for nk in range(len(null_idx)):
        var idx = null_idx[nk]
        arr.validity.value().clear(idx)
        nc += 1
    arr.null_count = nc
    return Column.from_primitive_with_arrow_type[DType.int32](arr^, at)


def _i64_col_from_values(
    imm values: List[Int64], imm null_idx: List[Int], at: ArrowType
) raises -> Column[HeapRegion]:
    """Build a NULLABLE INT64-backed Column[HeapRegion] stamped with `at`. Borrows inputs."""
    var n = len(values)
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        arr.set(i, values[i])
    var nc = 0
    for nk in range(len(null_idx)):
        var idx = null_idx[nk]
        arr.validity.value().clear(idx)
        nc += 1
    arr.null_count = nc
    return Column.from_primitive_with_arrow_type[DType.int64](arr^, at)


def _single_col_batch(
    fname: String, at: ArrowType, var col: Column[HeapRegion]
) raises -> RecordBatch:
    var schema = SchemaBuilder()
    schema.add_field(Field(fname, at, True))
    var builder = RecordBatchBuilder.with_capacity(1)
    builder.add_column(col^)
    return builder.build(schema.build())


# =============================================================================
# Helpers: write -> read -> per-cell assert.
# =============================================================================


def _roundtrip(rb: RecordBatch) raises -> RecordBatch:
    var opts = AvroWriterOptions(AVRO_CODEC_NULL)
    var bytes = write_avro_bytes(rb, opts)
    return read_avro_bytes(Span(bytes))


def _assert_i32_values(
    imm back: RecordBatch,
    expect_at: ArrowType,
    imm values: List[Int32],
    imm null_idx: List[Int],
    label: String,
) raises:
    """Per-cell value + null + arrow_type assertions for an INT32-backed
    arrow.* round-trip."""
    var n = len(values)
    assert_equal(back.num_rows(), n, label + ": num_rows")
    assert_equal(back.num_columns(), 1, label + ": num_columns")
    assert_true(
        back.schema.field_arrow_type(0) == expect_at,
        label + ": stamped arrow_type round-trips",
    )

    var arr = back.column_as_primitive_int32(0)
    # Build a quick lookup for which rows were written as null.
    var is_null_set = List[Bool]()
    for _ in range(n):
        is_null_set.append(False)
    for k in range(len(null_idx)):
        is_null_set[null_idx[k]] = True

    for i in range(n):
        var expect_null = is_null_set[i]
        var got_null = arr.is_null(i)
        assert_equal(
            got_null,
            expect_null,
            label + ": row " + String(i) + " null marker",
        )
        if not expect_null:
            assert_equal(
                Int(arr.get(i)),
                Int(values[i]),
                label + ": row " + String(i) + " value",
            )


def _assert_i64_values(
    imm back: RecordBatch,
    expect_at: ArrowType,
    imm values: List[Int64],
    imm null_idx: List[Int],
    label: String,
) raises:
    var n = len(values)
    assert_equal(back.num_rows(), n, label + ": num_rows")
    assert_equal(back.num_columns(), 1, label + ": num_columns")
    assert_true(
        back.schema.field_arrow_type(0) == expect_at,
        label + ": stamped arrow_type round-trips",
    )

    var arr = back.column_as_primitive_int64(0)
    var is_null_set = List[Bool]()
    for _ in range(n):
        is_null_set.append(False)
    for k in range(len(null_idx)):
        is_null_set[null_idx[k]] = True

    for i in range(n):
        var expect_null = is_null_set[i]
        var got_null = arr.is_null(i)
        assert_equal(
            got_null,
            expect_null,
            label + ": row " + String(i) + " null marker",
        )
        if not expect_null:
            assert_equal(
                Int(arr.get(i)),
                Int(values[i]),
                label + ": row " + String(i) + " value",
            )


# =============================================================================
# Per-type fixture builders & tests.
# =============================================================================


def _i32_vals(*vals: Int) -> List[Int32]:
    var out = List[Int32]()
    for v in vals:
        out.append(Int32(v))
    return out^


def _i64_vals(*vals: Int) -> List[Int64]:
    var out = List[Int64]()
    for v in vals:
        out.append(Int64(v))
    return out^


def _nulls(*vals: Int) -> List[Int]:
    var out = List[Int]()
    for v in vals:
        out.append(Int(v))
    return out^


# =============================================================================
# INT-backed in scope: TIME32_S.
# =============================================================================


def test_data_level_time32_s() raises:
    # TIME32_S range: seconds since midnight, [0, 86399].
    var values = _i32_vals(0, 86399, 3600, 43200, 86400, 1)
    # Note: 86400 is out-of-range for TIME32_S spec-wise but the codec is
    # int-passthrough; round-trip preserves the bits.
    var null_idx = _nulls(4)
    var col = _i32_col_from_values(values, null_idx, ArrowType.TIME32_S)
    var rb = _single_col_batch(String("v"), ArrowType.TIME32_S, col^)
    var back = _roundtrip(rb)
    _assert_i32_values(
        back, ArrowType.TIME32_S, values, null_idx, "TIME32_S"
    )


# =============================================================================
# LONG-backed in scope: DATE64, TIMESTAMP_S, TIMESTAMP_NS, TIME64_NS,
#                       DURATION_S, DURATION_MS, DURATION_US, DURATION_NS.
# UINT32 deferred — see header.
# =============================================================================


def test_data_level_date64() raises:
    # DATE64: milliseconds since epoch (Int64). Pre-epoch values are valid.
    var values = _i64_vals(
        0,                  # 1970-01-01
        86400000,           # 1970-01-02
        -86400000,          # 1969-12-31
        1609459200000,      # 2021-01-01
        1700000000000,      # ~2023-11
        9223372036854775000  # near INT64 MAX
    )
    var null_idx = _nulls(2)
    var col = _i64_col_from_values(values, null_idx, ArrowType.DATE64)
    var rb = _single_col_batch(String("v"), ArrowType.DATE64, col^)
    var back = _roundtrip(rb)
    _assert_i64_values(back, ArrowType.DATE64, values, null_idx, "DATE64")


def test_data_level_timestamp_s() raises:
    # TIMESTAMP_S: seconds since epoch.
    var values = _i64_vals(0, 1, -1, 1609459200, 1700000000, 86400)
    var null_idx = _nulls(5)
    var col = _i64_col_from_values(values, null_idx, ArrowType.TIMESTAMP_S)
    var rb = _single_col_batch(String("v"), ArrowType.TIMESTAMP_S, col^)
    var back = _roundtrip(rb)
    _assert_i64_values(
        back, ArrowType.TIMESTAMP_S, values, null_idx, "TIMESTAMP_S"
    )


def test_data_level_timestamp_ns() raises:
    # TIMESTAMP_NS: nanoseconds since epoch.
    var values = _i64_vals(
        0,
        1,
        -1,
        1000000000,             # 1s in ns
        1609459200000000000,    # 2021-01-01 in ns
        9223372036854775000     # near INT64 MAX
    )
    var null_idx = _nulls(0)
    var col = _i64_col_from_values(values, null_idx, ArrowType.TIMESTAMP_NS)
    var rb = _single_col_batch(String("v"), ArrowType.TIMESTAMP_NS, col^)
    var back = _roundtrip(rb)
    _assert_i64_values(
        back, ArrowType.TIMESTAMP_NS, values, null_idx, "TIMESTAMP_NS"
    )


def test_data_level_time64_ns() raises:
    # TIME64_NS: nanoseconds since midnight, [0, 86399999999999].
    var values = _i64_vals(
        0,
        1,
        86399999999999,         # 23:59:59.999999999
        43200000000000,         # noon
        3600000000000,          # 1h
        1000000000              # 1s
    )
    var null_idx = _nulls(4)
    var col = _i64_col_from_values(values, null_idx, ArrowType.TIME64_NS)
    var rb = _single_col_batch(String("v"), ArrowType.TIME64_NS, col^)
    var back = _roundtrip(rb)
    _assert_i64_values(
        back, ArrowType.TIME64_NS, values, null_idx, "TIME64_NS"
    )


def test_data_level_duration_s() raises:
    # DURATION_S: seconds. Negative durations are allowed (signed int64).
    var values = _i64_vals(0, 1, -1, 3600, -3600, 86400)
    var null_idx = _nulls(1)
    var col = _i64_col_from_values(values, null_idx, ArrowType.DURATION_S)
    var rb = _single_col_batch(String("v"), ArrowType.DURATION_S, col^)
    var back = _roundtrip(rb)
    _assert_i64_values(
        back, ArrowType.DURATION_S, values, null_idx, "DURATION_S"
    )


def test_data_level_duration_ms() raises:
    var values = _i64_vals(0, 1, -1, 1000, -1000, 86400000)
    var null_idx = _nulls(3)
    var col = _i64_col_from_values(values, null_idx, ArrowType.DURATION_MS)
    var rb = _single_col_batch(String("v"), ArrowType.DURATION_MS, col^)
    var back = _roundtrip(rb)
    _assert_i64_values(
        back, ArrowType.DURATION_MS, values, null_idx, "DURATION_MS"
    )


def test_data_level_duration_us() raises:
    var values = _i64_vals(0, 1, -1, 1000000, -1000000, 86400000000)
    var null_idx = _nulls(0)
    var col = _i64_col_from_values(values, null_idx, ArrowType.DURATION_US)
    var rb = _single_col_batch(String("v"), ArrowType.DURATION_US, col^)
    var back = _roundtrip(rb)
    _assert_i64_values(
        back, ArrowType.DURATION_US, values, null_idx, "DURATION_US"
    )


def test_data_level_duration_ns() raises:
    var values = _i64_vals(
        0, 1, -1, 1000000000, -1000000000, 86400000000000
    )
    var null_idx = _nulls(5)
    var col = _i64_col_from_values(values, null_idx, ArrowType.DURATION_NS)
    var rb = _single_col_batch(String("v"), ArrowType.DURATION_NS, col^)
    var back = _roundtrip(rb)
    _assert_i64_values(
        back, ArrowType.DURATION_NS, values, null_idx, "DURATION_NS"
    )


# =============================================================================
# Deferred (FIXED-backed): UINT64 -> fixed(8), FLOAT16 -> fixed(2).
# =============================================================================
#
# The writer raises in strict_mode on these (see
# test_avro_write_roundtrip.test_write_strict_mode_raise). Value-decode tests
# for them need writer FIXED-backed support first.


def main() raises:
    test_data_level_time32_s()
    test_data_level_date64()
    test_data_level_timestamp_s()
    test_data_level_timestamp_ns()
    test_data_level_time64_ns()
    test_data_level_duration_s()
    test_data_level_duration_ms()
    test_data_level_duration_us()
    test_data_level_duration_ns()
    print("test_avro_data_level_decode: ALL 9 PASS")
