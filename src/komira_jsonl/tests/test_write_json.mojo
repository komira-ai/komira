# =============================================================================
# Integration test for the JSON writer: per-type formatters + batch writers
# =============================================================================
#
# Coverage:
#   T1  write_i64_dec — positive / negative / zero / INT64_MIN edge.
#   T2  write_f64_dtoa — finite / NaN / +Inf / -Inf (NaN/Inf -> null).
#   T3  write_string_escaped — `"` `\\` `\\n` `\\r` `\\t` `\\b` `\\f` +
#       control char -> `\\u00XX` form.
#   T4  write_date32 — epoch / Y2000 / pre-epoch / far-future year.
#   T5  write_decimal128 — positive / negative / zero / scale > digits.
#   T6  Round-trip Int64 column: write_batch_jsonl -> materialize_jsonl_to_batch
#       -> bit-exact column equality.
#   T7  Round-trip Float64 column: write -> read -> bit-exact (NaN/Inf -> null).
#   T8  Round-trip String column: write -> read -> bit-exact (escape lattice
#       full round-trip).
#   T9  Round-trip Bool column: write -> read -> bit-exact.
#   T10 write_batch_json_pretty — byte-identical to Python json.dumps golden.
#   T11 Empty batch: 0 rows -> empty bytes / pretty mode -> `[]`.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Schema, SchemaBuilder, Field
from komira_core.arrow.string_array import StringArray

from komira_jsonl.columnar_materializer import materialize_jsonl_to_batch
from komira_jsonl.encode import write_batch_jsonl
from komira_jsonl.json_writer import (
    write_i64_dec,
    write_f64_dtoa,
    write_string_escaped,
    write_date32,
    write_decimal128,
    write_batch_json_pretty,
    write_batch_jsonl_fused,
    write_batch_jsonl_fused_range,
)


# =============================================================================
# Small helpers
# =============================================================================


def _buf_to_string(buf: List[UInt8]) -> String:
    """Convert a buffer to String without UTF-8 re-encoding."""
    return String(unsafe_from_utf8=Span(buf))


# =============================================================================
# T1: write_i64_dec
# =============================================================================


def test_write_i64_dec() raises:
    print("T1: write_i64_dec")
    var buf = List[UInt8]()

    write_i64_dec(buf, Int64(0))
    assert_equal(_buf_to_string(buf), String("0"))

    buf.clear()
    write_i64_dec(buf, Int64(42))
    assert_equal(_buf_to_string(buf), String("42"))

    buf.clear()
    write_i64_dec(buf, Int64(-42))
    assert_equal(_buf_to_string(buf), String("-42"))

    buf.clear()
    write_i64_dec(buf, Int64(9223372036854775807))  # INT64_MAX
    assert_equal(_buf_to_string(buf), String("9223372036854775807"))

    buf.clear()
    write_i64_dec(buf, Int64(-9223372036854775808))  # INT64_MIN
    assert_equal(_buf_to_string(buf), String("-9223372036854775808"))

    print("  PASS")


# =============================================================================
# T2: write_f64_dtoa  (NaN/Inf -> null per RFC 8259 §6)
# =============================================================================


def test_write_f64_dtoa() raises:
    print("T2: write_f64_dtoa")
    var buf = List[UInt8]()

    write_f64_dtoa(buf, Float64(0.0))
    assert_equal(_buf_to_string(buf), String(Float64(0.0)))

    buf.clear()
    write_f64_dtoa(buf, Float64(1.5))
    assert_equal(_buf_to_string(buf), String("1.5"))

    buf.clear()
    write_f64_dtoa(buf, Float64(-1.5))
    assert_equal(_buf_to_string(buf), String("-1.5"))

    # NaN -> null.
    buf.clear()
    var nan = Float64(0.0) / Float64(0.0)
    write_f64_dtoa(buf, nan)
    assert_equal(_buf_to_string(buf), String("null"))

    # +Inf -> null.
    buf.clear()
    var pinf = Float64(1.0) / Float64(0.0)
    write_f64_dtoa(buf, pinf)
    assert_equal(_buf_to_string(buf), String("null"))

    # -Inf -> null.
    buf.clear()
    var ninf = Float64(-1.0) / Float64(0.0)
    write_f64_dtoa(buf, ninf)
    assert_equal(_buf_to_string(buf), String("null"))

    # Round-trip Pi shortest form.
    buf.clear()
    var pi = Float64(3.14159265358979323846)
    write_f64_dtoa(buf, pi)
    assert_equal(_buf_to_string(buf), String(pi))

    print("  PASS")


# =============================================================================
# T3: write_string_escaped
# =============================================================================


def test_write_string_escaped() raises:
    print("T3: write_string_escaped")
    var buf = List[UInt8]()

    write_string_escaped(buf, String("hello"))
    assert_equal(_buf_to_string(buf), String('"hello"'))

    buf.clear()
    write_string_escaped(buf, String('a"b'))
    assert_equal(_buf_to_string(buf), String('"a\\"b"'))

    buf.clear()
    write_string_escaped(buf, String("a\\b"))
    assert_equal(_buf_to_string(buf), String('"a\\\\b"'))

    buf.clear()
    write_string_escaped(buf, String("a\nb"))
    assert_equal(_buf_to_string(buf), String('"a\\nb"'))

    buf.clear()
    write_string_escaped(buf, String("a\tb"))
    assert_equal(_buf_to_string(buf), String('"a\\tb"'))

    # Control char 0x01 -> .
    buf.clear()
    var s = String()
    s += chr(0x01)
    write_string_escaped(buf, s)
    assert_equal(_buf_to_string(buf), String('"\\u0001"'))

    # Empty string -> `""`.
    buf.clear()
    write_string_escaped(buf, String(""))
    assert_equal(_buf_to_string(buf), String('""'))

    print("  PASS")


# =============================================================================
# T4: write_date32  (ISO-8601)
# =============================================================================


def test_write_date32() raises:
    print("T4: write_date32")
    var buf = List[UInt8]()

    # Epoch.
    write_date32(buf, Int32(0))
    assert_equal(_buf_to_string(buf), String('"1970-01-01"'))

    # 2000-01-01: (date(2000,1,1) - date(1970,1,1)).days = 10957.
    buf.clear()
    write_date32(buf, Int32(10957))
    assert_equal(_buf_to_string(buf), String('"2000-01-01"'))

    # 2020-03-15: (date(2020,3,15) - date(1970,1,1)).days = 18336.
    buf.clear()
    write_date32(buf, Int32(18336))
    assert_equal(_buf_to_string(buf), String('"2020-03-15"'))

    # Pre-epoch: 1969-12-31 = -1 days.
    buf.clear()
    write_date32(buf, Int32(-1))
    assert_equal(_buf_to_string(buf), String('"1969-12-31"'))

    # Far future: 9999-12-31. (date(9999,12,31) - date(1970,1,1)).days = 2932896.
    buf.clear()
    write_date32(buf, Int32(2932896))
    assert_equal(_buf_to_string(buf), String('"9999-12-31"'))

    print("  PASS")


# =============================================================================
# T5: write_decimal128  (lossless JSON string)
# =============================================================================


def test_write_decimal128() raises:
    print("T5: write_decimal128")
    var buf = List[UInt8]()

    # 0 with scale=2  -> "0.00"
    write_decimal128(buf, Int64(0), Int64(0), 2)
    assert_equal(_buf_to_string(buf), String('"0.00"'))

    # 12345 with scale=2  -> "123.45"
    buf.clear()
    write_decimal128(buf, Int64(12345), Int64(0), 2)
    assert_equal(_buf_to_string(buf), String('"123.45"'))

    # -12345 as i128 (low=-12345 low-bits, high=-1 due to sign-extension).
    # We pass the SIGNED Int64 values for low/high; the writer reinterprets
    # via UInt64(low) and detects negative via the SIGNED high.
    buf.clear()
    write_decimal128(buf, Int64(-12345), Int64(-1), 2)
    assert_equal(_buf_to_string(buf), String('"-123.45"'))

    # 1 with scale=4 -> "0.0001" (leading zeros pad).
    buf.clear()
    write_decimal128(buf, Int64(1), Int64(0), 4)
    assert_equal(_buf_to_string(buf), String('"0.0001"'))

    # scale=0 -> integer.
    buf.clear()
    write_decimal128(buf, Int64(42), Int64(0), 0)
    assert_equal(_buf_to_string(buf), String('"42"'))

    # 2^64 = (low=0, high=1). Scale=0 -> "18446744073709551616".
    buf.clear()
    write_decimal128(buf, Int64(0), Int64(1), 0)
    assert_equal(_buf_to_string(buf), String('"18446744073709551616"'))

    print("  PASS")


# =============================================================================
# T6: Round-trip Int64 column
# =============================================================================


def _build_batch_int64(name: String, values: List[Int64]) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int64].allocate(len(values))
    for i in range(len(values)):
        arr.set(i, values[i])
    var col = Column.from_primitive[DType.int64](arr^)
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.INT64, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(col^)
    return rbb.build(sb.build())


def test_roundtrip_int64() raises:
    print("T6: round-trip Int64 column")
    var values = List[Int64]()
    values.append(Int64(1))
    values.append(Int64(-2))
    values.append(Int64(0))
    values.append(Int64(9223372036854775807))
    var batch = _build_batch_int64(String("v"), values)

    # Write to JSONL bytes.
    var buf = List[UInt8]()
    write_batch_jsonl(buf, batch)

    # Build read-back schema.
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), ArrowType.INT64, True))
    var read_schema = sb.build()
    var rb2 = materialize_jsonl_to_batch(Span(buf), read_schema^)
    ref col2 = rb2.column_at(0)
    var arr2 = col2.as_primitive[DType.int64]()
    assert_equal(rb2.num_rows(), 4)
    assert_equal(arr2.get(0), Int64(1))
    assert_equal(arr2.get(1), Int64(-2))
    assert_equal(arr2.get(2), Int64(0))
    assert_equal(arr2.get(3), Int64(9223372036854775807))
    print("  PASS")


# =============================================================================
# T7: Round-trip Float64 column (NaN/Inf -> null on write)
# =============================================================================


def _build_batch_float64(name: String, values: List[Float64]) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.float64].allocate_nullable(len(values))
    for i in range(len(values)):
        arr.set(i, values[i])
    var col = Column.from_primitive[DType.float64](arr^)
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.FLOAT64, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(col^)
    return rbb.build(sb.build())


def test_roundtrip_float64() raises:
    print("T7: round-trip Float64 column (finite values)")
    # Finite-only round-trip: bit-exact via Mojo stdlib Grisu3/Ryu dtoa.
    # NaN/Inf -> null on write is verified by T2 (write_f64_dtoa); this
    # test covers finite values only.
    var values = List[Float64]()
    values.append(Float64(1.5))
    values.append(Float64(-2.25))
    values.append(Float64(0.0))
    values.append(Float64(3.14159265358979323846))
    var batch = _build_batch_float64(String("v"), values)

    var buf = List[UInt8]()
    write_batch_jsonl(buf, batch)

    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), ArrowType.FLOAT64, True))
    var read_schema = sb.build()
    var rb2 = materialize_jsonl_to_batch(Span(buf), read_schema^)
    var arr2 = rb2.column_at(0).as_primitive[DType.float64]()
    assert_equal(rb2.num_rows(), 4)
    assert_equal(arr2.get(0), Float64(1.5))
    assert_equal(arr2.get(1), Float64(-2.25))
    assert_equal(arr2.get(2), Float64(0.0))
    assert_equal(arr2.get(3), Float64(3.14159265358979323846))
    print("  PASS")


# =============================================================================
# T8: Round-trip String column (escape lattice)
# =============================================================================


def test_roundtrip_string() raises:
    print("T8: round-trip String column")
    var values = List[String]()
    values.append(String("hello"))
    values.append(String('a"b\\c\nd'))  # contains ", \\, \n
    var sa = StringArray.from_strings(values)
    var col = Column.from_string(sa^)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), ArrowType.STRING, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(col^)
    var batch = rbb.build(sb.build())

    var buf = List[UInt8]()
    write_batch_jsonl(buf, batch)

    var sb2 = SchemaBuilder()
    sb2.add_field(Field(String("v"), ArrowType.STRING, True))
    var read_schema = sb2.build()
    var rb2 = materialize_jsonl_to_batch(Span(buf), read_schema^)
    var sarr2 = rb2.column_as_string(0)
    assert_equal(rb2.num_rows(), 2)
    assert_equal(sarr2.get(0), String("hello"))
    assert_equal(sarr2.get(1), String('a"b\\c\nd'))
    print("  PASS")


# =============================================================================
# T9: Round-trip Bool column
# =============================================================================


def test_roundtrip_bool() raises:
    print("T9: round-trip Bool column")
    var arr = BooleanArray.allocate(3)
    arr.set(0, True)
    arr.set(1, False)
    arr.set(2, True)
    var col = Column.from_boolean(arr^)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), ArrowType.BOOL, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(col^)
    var batch = rbb.build(sb.build())

    var buf = List[UInt8]()
    write_batch_jsonl(buf, batch)

    var sb2 = SchemaBuilder()
    sb2.add_field(Field(String("v"), ArrowType.BOOL, True))
    var read_schema = sb2.build()
    var rb2 = materialize_jsonl_to_batch(Span(buf), read_schema^)
    var barr2 = rb2.column_at(0).as_boolean()
    assert_equal(rb2.num_rows(), 3)
    assert_equal(barr2.get(0), True)
    assert_equal(barr2.get(1), False)
    assert_equal(barr2.get(2), True)
    print("  PASS")


# =============================================================================
# T10: write_batch_json_pretty — Python json.dumps golden
# =============================================================================
#
# Fixed input: 2 rows × 2 cols (Int64 + String).
# Expected bytes computed via Python:
#   >>> import json
#   >>> json.dumps([{"a":1,"b":"x"},{"a":2,"b":"y"}], indent=2)
# yields the multi-line ARRAY form below (no trailing newline).


def test_pretty_print_python_golden() raises:
    print("T10: write_batch_json_pretty matches Python json.dumps(..., indent=2)")

    var int_arr = PrimitiveArray[DType.int64].allocate(2)
    int_arr.set(0, Int64(1))
    int_arr.set(1, Int64(2))
    var int_col = Column.from_primitive[DType.int64](int_arr^)

    var values = List[String]()
    values.append(String("x"))
    values.append(String("y"))
    var str_arr = StringArray.from_strings(values)
    var str_col = Column.from_string(str_arr^)

    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), ArrowType.INT64, True))
    sb.add_field(Field(String("b"), ArrowType.STRING, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(int_col^)
    rbb.add_column(str_col^)
    var batch = rbb.build(sb.build())

    var buf = List[UInt8]()
    write_batch_json_pretty(buf, batch, indent=2)

    var actual = _buf_to_string(buf)
    var expected = String(
        "[\n"
        + '  {\n'
        + '    "a": 1,\n'
        + '    "b": "x"\n'
        + "  },\n"
        + '  {\n'
        + '    "a": 2,\n'
        + '    "b": "y"\n'
        + "  }\n"
        + "]"
    )
    assert_equal(actual, expected)
    print("  PASS")


# =============================================================================
# T11: Empty batch handling
# =============================================================================


def test_empty_batch() raises:
    print("T11: empty batch")
    var arr = PrimitiveArray[DType.int64].allocate(0)
    var col = Column.from_primitive[DType.int64](arr^)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), ArrowType.INT64, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(col^)
    var batch = rbb.build(sb.build())

    # JSONL writer emits nothing for 0-row batches.
    var buf = List[UInt8]()
    write_batch_jsonl(buf, batch)
    assert_equal(len(buf), 0)

    # Pretty-print emits `[]` for 0 rows.
    var buf2 = List[UInt8]()
    write_batch_json_pretty(buf2, batch, indent=2)
    assert_equal(_buf_to_string(buf2), String("[]"))
    print("  PASS")


# =============================================================================
# T12: Byte-identity write_batch_jsonl_fused vs write_batch_jsonl
# =============================================================================
#
# Critical correctness gate: the fused-encode path must produce
# byte-identical output to `encode.write_batch_jsonl` across the full
# ArrowType lattice. Fixture shape: a typical write benchmark table
# (3 Int64 + 3 Float64 + 2 String + 1 Bool + 1 Date32 across 100
# rows; small enough to keep test wall <1s, large enough to exercise all
# the per-column encoder paths at scale).


def _build_bench_like_fixture(num_rows: Int) raises -> RecordBatch:
    """Build a 10-column fixture (3 Int64 + 3 Float64 + 2 String + 1 Bool
    + 1 Date32), the shape of a typical write benchmark table. Small row
    count for fast test wall."""
    var rbb = RecordBatchBuilder()

    # 3 Int64 columns.
    for c in range(3):
        var arr = PrimitiveArray[DType.int64].allocate(num_rows)
        for i in range(num_rows):
            arr.set(i, Int64(i + c * 1000))
        rbb.add_column(Column.from_primitive[DType.int64](arr^))

    # 3 Float64 columns.
    for c in range(3):
        var arr = PrimitiveArray[DType.float64].allocate(num_rows)
        for i in range(num_rows):
            arr.set(i, Float64(i) * 1.5 + Float64(c) * 0.25)
        rbb.add_column(Column.from_primitive[DType.float64](arr^))

    # 2 String columns.
    for c in range(2):
        var values = List[String]()
        for i in range(num_rows):
            values.append(String("row_") + String(i) + String("_c") + String(c))
        var sa = StringArray.from_strings(values)
        rbb.add_column(Column.from_string(sa^))

    # 1 Bool column.
    var barr = BooleanArray.allocate(num_rows)
    for i in range(num_rows):
        barr.set(i, (i & 1) == 1)
    rbb.add_column(Column.from_boolean(barr^))

    # 1 Date32 column.
    var darr = PrimitiveArray[DType.int32].allocate(num_rows)
    for i in range(num_rows):
        darr.set(i, Int32(i))
    rbb.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](darr^, ArrowType.DATE32)
    )

    var sb = SchemaBuilder()
    sb.add_field(Field(String("i0"), ArrowType.INT64, True))
    sb.add_field(Field(String("i1"), ArrowType.INT64, True))
    sb.add_field(Field(String("i2"), ArrowType.INT64, True))
    sb.add_field(Field(String("f0"), ArrowType.FLOAT64, True))
    sb.add_field(Field(String("f1"), ArrowType.FLOAT64, True))
    sb.add_field(Field(String("f2"), ArrowType.FLOAT64, True))
    sb.add_field(Field(String("s0"), ArrowType.STRING, True))
    sb.add_field(Field(String("s1"), ArrowType.STRING, True))
    sb.add_field(Field(String("b0"), ArrowType.BOOL, True))
    sb.add_field(Field(String("d0"), ArrowType.DATE32, True))

    return rbb.build(sb.build())


def test_byte_identity_fused_vs_legacy() raises:
    """Critical correctness gate for the fused encoder: ensure
    `write_batch_jsonl_fused` produces BYTE-IDENTICAL output to
    `encode.write_batch_jsonl` on the fixture (covers Int64, Float64,
    String, Bool, Date32)."""
    print("T12: byte-identity write_batch_jsonl_fused vs write_batch_jsonl")

    # 100 rows is plenty to exercise per-column dispatch + offset arithmetic
    # without bloating test wall.
    var batch = _build_bench_like_fixture(100)

    var buf_legacy = List[UInt8]()
    write_batch_jsonl(buf_legacy, batch)

    var buf_fused = List[UInt8]()
    write_batch_jsonl_fused(buf_fused, batch)

    assert_equal(len(buf_legacy), len(buf_fused))
    # Compare byte-for-byte. Print first divergence index on failure.
    var n = len(buf_legacy)
    for i in range(n):
        if buf_legacy[i] != buf_fused[i]:
            print(
                "MISMATCH at byte ", i,
                " legacy=", Int(buf_legacy[i]),
                " fused=", Int(buf_fused[i]),
            )
            assert_equal(buf_legacy[i], buf_fused[i])

    print("  PASS (", n, "bytes byte-identical)")


def test_fused_empty_batch() raises:
    """Edge case: 0-row batch -> fused emits empty buffer, same as write_batch_jsonl."""
    print("T13: fused empty batch")
    var arr = PrimitiveArray[DType.int64].allocate(0)
    var col = Column.from_primitive[DType.int64](arr^)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), ArrowType.INT64, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(col^)
    var batch = rbb.build(sb.build())

    var buf = List[UInt8]()
    write_batch_jsonl_fused(buf, batch)
    assert_equal(len(buf), 0)
    print("  PASS")


# =============================================================================
# T14: write_batch_jsonl_fused_range — whole-batch equivalence
# =============================================================================


def test_fused_range_whole_batch_equals_fused() raises:
    """Byte-identity invariant for the row-bounded fused entry. Calling
    `write_batch_jsonl_fused_range(buf, batch, 0, num_rows)` MUST
    produce the EXACT same bytes as `write_batch_jsonl_fused(buf,
    batch)`. This is the unit-level statement of the contract that
    `write_batch_jsonl_fused` is now defined as the whole-batch
    specialization of `_range`."""
    print("T14: fused-range whole-batch equals fused")

    var batch = _build_bench_like_fixture(100)

    var buf_fused = List[UInt8]()
    write_batch_jsonl_fused(buf_fused, batch)

    var buf_range = List[UInt8]()
    write_batch_jsonl_fused_range(buf_range, batch, 0, batch.num_rows())

    assert_equal(len(buf_fused), len(buf_range))
    var n = len(buf_fused)
    for i in range(n):
        if buf_fused[i] != buf_range[i]:
            print(
                "MISMATCH at byte ", i,
                " fused=", Int(buf_fused[i]),
                " range=", Int(buf_range[i]),
            )
            assert_equal(buf_fused[i], buf_range[i])

    print("  PASS (", n, "bytes byte-identical)")


# =============================================================================
# T15: write_batch_jsonl_fused_range — partition concat equals whole
# =============================================================================


def test_fused_range_partition_concat_equals_whole() raises:
    """The load-bearing parallel-WRITE byte-identity gate. Partition the rows
    into multiple `[lo, hi)` ranges, encode each range via
    `write_batch_jsonl_fused_range`, concatenate the resulting buffers
    in partition order — the result MUST be byte-for-byte identical to
    the whole-batch `write_batch_jsonl_fused` output.

    This guards the byte-identity contract that
    `FileSink[Jsonl].accept_jsonl` relies on when its workers fork-join
    over per-tid partitions and concat the per-worker buffers in tid
    order. If THIS invariant ever breaks, the parallel writer would
    silently produce diverged-output files vs the serial writer.

    Tests two partition shapes: (a) 3-way balanced split, (b) 7-way
    uneven split (remainder rows). Both must concat to the same bytes."""
    print("T15: fused-range partition concat equals whole")

    var batch = _build_bench_like_fixture(100)
    var num_rows = batch.num_rows()

    # Baseline: whole-batch encode.
    var buf_whole = List[UInt8]()
    write_batch_jsonl_fused(buf_whole, batch)

    # Shape (a): 3-way balanced split.
    var part_a_lo = [0, 33, 66]
    var part_a_hi = [33, 66, num_rows]
    var buf_a = List[UInt8]()
    for w in range(3):
        var part_buf = List[UInt8]()
        write_batch_jsonl_fused_range(
            part_buf, batch, part_a_lo[w], part_a_hi[w]
        )
        buf_a.extend(Span(part_buf))
    assert_equal(len(buf_whole), len(buf_a))
    var n_a = len(buf_whole)
    for i in range(n_a):
        if buf_whole[i] != buf_a[i]:
            print(
                "3-WAY MISMATCH at byte ", i,
                " whole=", Int(buf_whole[i]),
                " concat=", Int(buf_a[i]),
            )
            assert_equal(buf_whole[i], buf_a[i])

    # Shape (b): 7-way uneven split (100 // 7 = 14 rem 2; the lo+hi
    # arrays mirror the balanced-partition contract of accept_jsonl,
    # where the first `rem` workers get one extra row).
    var part_b_lo = [0, 15, 30, 45, 59, 73, 87]
    var part_b_hi = [15, 30, 45, 59, 73, 87, num_rows]
    var buf_b = List[UInt8]()
    for w in range(7):
        var part_buf = List[UInt8]()
        write_batch_jsonl_fused_range(
            part_buf, batch, part_b_lo[w], part_b_hi[w]
        )
        buf_b.extend(Span(part_buf))
    assert_equal(len(buf_whole), len(buf_b))
    var n_b = len(buf_whole)
    for i in range(n_b):
        if buf_whole[i] != buf_b[i]:
            print(
                "7-WAY MISMATCH at byte ", i,
                " whole=", Int(buf_whole[i]),
                " concat=", Int(buf_b[i]),
            )
            assert_equal(buf_whole[i], buf_b[i])

    print(
        "  PASS (3-way:", n_a, "bytes; 7-way:", n_b, "bytes; both byte-identical)"
    )


# =============================================================================
# T15B: write_string_escaped — SIMD chunk-boundary correctness
# =============================================================================


def test_write_string_escaped_simd_chunk_boundaries() raises:
    """Exercise the 16-byte SIMD escape fast-path at every boundary case
    T3 does not cover.

    SIMD scan operates in 16-byte chunks; bugs from the fast-path
    typically show up:
      - At lengths just above 16 (one SIMD chunk + 1-byte tail).
      - When an escape byte sits at the FINAL byte of a SIMD chunk.
      - When an escape byte sits at the FIRST byte of a SIMD chunk.
      - In a multi-chunk no-escape run (must memcpy multiple chunks
        in sequence and the running cursor must not drift).
      - In a multi-chunk run with one escape mid-second-chunk (the
        bulk-copy-then-escape-then-resume path).
      - In a tail that contains an escape byte (< 16 trailing bytes
        falling through to the scalar branch).
    """
    print("T15B: write_string_escaped SIMD chunk boundaries")

    # Helper: compute the expected output via the same scalar
    # branch that the fast path delegates to (using a tiny scalar
    # reference implementation in test code — keeps the oracle
    # independent of any production code paths).
    def _ref_escape(s: String) -> String:
        var out = String('"')
        var n = s.byte_length()
        for i in range(n):
            var b = UInt8(ord(s[byte=i]))
            if b == UInt8(0x22):
                out += String('\\"')
            elif b == UInt8(0x5C):
                out += String("\\\\")
            elif b == UInt8(0x0A):
                out += String("\\n")
            elif b == UInt8(0x0D):
                out += String("\\r")
            elif b == UInt8(0x09):
                out += String("\\t")
            elif b == UInt8(0x08):
                out += String("\\b")
            elif b == UInt8(0x0C):
                out += String("\\f")
            elif b < UInt8(0x20):
                out += String("\\u00")
                var hi_n = Int((b >> UInt8(4)) & UInt8(0xF))
                var lo_n = Int(b & UInt8(0xF))
                var hexd = String("0123456789abcdef")
                out += hexd[byte=hi_n]
                out += hexd[byte=lo_n]
            else:
                out += s[byte=i]
        out += String('"')
        return out

    def _check(s: String) raises:
        var buf = List[UInt8]()
        write_string_escaped(buf, s)
        var got = _buf_to_string(buf)
        var want = _ref_escape(s)
        if got != want:
            print("  MISMATCH on input len=", s.byte_length())
            print("    got = ", got)
            print("    want = ", want)
        assert_equal(got, want)

    # 1. Exactly 16 bytes, no escape (single SIMD chunk, mask == 0).
    _check(String("aaaaaaaaaaaaaaaa"))
    # 2. 15 bytes, no escape (no SIMD chunk; scalar tail only).
    _check(String("aaaaaaaaaaaaaaa"))
    # 3. 17 bytes, no escape (one SIMD chunk + 1-byte scalar tail).
    _check(String("aaaaaaaaaaaaaaaab"))
    # 4. 32 bytes, no escape (two SIMD chunks).
    _check(String("aaaaaaaaaaaaaaaabbbbbbbbbbbbbbbb"))
    # 5. 64 bytes, no escape (four SIMD chunks — multi-chunk run).
    var s64 = String("")
    for _ in range(4):
        s64 += String("0123456789abcdef")
    _check(s64)

    # 6. Escape at byte 0 of a 16-byte chunk.
    _check(String('"aaaaaaaaaaaaaaa'))
    # 7. Escape at byte 15 of a 16-byte chunk (the LAST byte).
    _check(String('aaaaaaaaaaaaaaa"'))
    # 8. Escape at byte 7 (middle of chunk).
    _check(String('aaaaaaa"aaaaaaaa'))
    # 9. Escape at byte 15 of FIRST chunk + escape at byte 0 of SECOND
    #    chunk + escape at byte 15 of SECOND chunk (covers all 3
    #    chunk-boundary positions in one shot).
    _check(String('aaaaaaaaaaaaaaa""aaaaaaaaaaaaaa"'))

    # 10. Multiple escape bytes in one 16-byte chunk.
    _check(String('a"b\\c\nd\re\tf'))

    # 11. Control character (< 0x20) at byte 0 of chunk.
    var s_ctl = String()
    s_ctl += chr(0x01)
    s_ctl += String("aaaaaaaaaaaaaaa")
    _check(s_ctl)

    # 12. Control character at byte 15 of chunk.
    var s_ctl2 = String("aaaaaaaaaaaaaaa")
    s_ctl2 += chr(0x05)
    _check(s_ctl2)

    # 13. Mixed escape types across multiple chunks (covers ctz-walk).
    var s_mixed = String('hello "world" with \\backslash\n and tab\there\r')
    _check(s_mixed)

    # 14. Pure ASCII 100-byte run with one escape near the end.
    var s_run = String()
    for _ in range(10):
        s_run += String("abcdefghij")
    s_run += String('"')  # escape at byte 100
    _check(s_run)

    # 15. Very long pure-safe run (the SIMD fast-path's headline win
    #     case — multi-chunk memcpy-only).
    var s_long = String()
    for _ in range(50):
        s_long += String("the quick brown fox jumps")  # 25 bytes × 50
    _check(s_long)

    # 16. Backslash at boundary (different escape byte; covers byte_find_eq_2).
    _check(String("aaaaaaaaaaaaaaa\\bbbbbbbbbbbbbbb"))

    # 17. Tail-only escape (string < 16 bytes with escape).
    _check(String('ab"cd'))

    # 18. Empty.
    _check(String(""))

    print("  PASS")


# =============================================================================
# T16: write_batch_jsonl_fused_range — empty range produces no bytes
# =============================================================================


def test_fused_range_empty_range() raises:
    """The empty-range case (`row_start == row_end`) must be a no-op (no bytes
    appended). This protects callers that allocate per-worker buffers
    upfront and may dispatch a 0-row worker when num_rows < n_workers
    (e.g. 3 rows on a 7-worker fork-join would not occur in
    accept_jsonl due to its row-cap, but a defensive caller might)."""
    print("T16: fused-range empty range")

    var batch = _build_bench_like_fixture(10)

    var buf = List[UInt8]()
    write_batch_jsonl_fused_range(buf, batch, 5, 5)
    assert_equal(len(buf), 0)

    var buf2 = List[UInt8]()
    write_batch_jsonl_fused_range(buf2, batch, 0, 0)
    assert_equal(len(buf2), 0)

    print("  PASS")


# =============================================================================
# Driver
# =============================================================================


def main() raises:
    print("=== test_write_json ===")
    test_write_i64_dec()
    test_write_f64_dtoa()
    test_write_string_escaped()
    test_write_date32()
    test_write_decimal128()
    test_roundtrip_int64()
    test_roundtrip_float64()
    test_roundtrip_string()
    test_roundtrip_bool()
    test_pretty_print_python_golden()
    test_empty_batch()
    test_byte_identity_fused_vs_legacy()
    test_fused_empty_batch()
    test_fused_range_whole_batch_equals_fused()
    test_fused_range_partition_concat_equals_whole()
    test_write_string_escaped_simd_chunk_boundaries()
    test_fused_range_empty_range()
    print("=== ALL PASSED ===")
