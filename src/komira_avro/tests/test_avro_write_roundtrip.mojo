# =============================================================================
# test_avro_write_roundtrip.mojo — writer self-round-trip.
# =============================================================================
#
# THE KEY ACCEPTANCE TESTS: write a RecordBatch -> Avro OCF
# bytes (write_avro_bytes) -> read it back via the reader
# (read_avro_bytes) -> assert equality. Fully self-contained (no external
# arrow-avro / avro-tools needed). Exercises the varint
# encoder, the Arrow->Avro schema walker (whole-schema from_arrow), the OCF
# header + block emit, the OS-entropy sync marker, the codec compress matrix,
# the bytes-OR-rows block-flush trigger, and nullable union encoding, against
# the known-correct reader.
#
# Tests:
#   - test_write_avro_roundtrip            — core self-round-trip
#   - test_write_codecs_all_6              — all 6 codecs
#   - test_write_arrow_logicals_emit       — lossy arrow.* survive round-trip
#   - test_write_strict_mode_raise         — strict-mode validation raises
#   - test_write_sync_marker_entropy_source — markers come from OS entropy
#   - test_write_block_size_trigger_or_first — bytes-OR-rows flush trigger
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field

from komira_avro import (
    AvroWriterOptions,
    write_avro_bytes,
    read_avro_bytes,
    decode_ocf_header,
    generate_sync_marker,
    AVRO_CODEC_NULL,
    AVRO_CODEC_DEFLATE,
    AVRO_CODEC_SNAPPY,
    AVRO_CODEC_BZIP2,
    AVRO_CODEC_XZ,
    AVRO_CODEC_ZSTANDARD,
    OCF_SYNC_LEN,
)


# =============================================================================
# Fixture builders.
# =============================================================================


def _i64s(*vals: Int) -> List[Int64]:
    var out = List[Int64]()
    for v in vals:
        out.append(Int64(v))
    return out^


def _build_mixed_batch() raises -> RecordBatch:
    """A 6-row RecordBatch of mixed primitive types (no nulls)."""
    var n = 6
    var schema = SchemaBuilder()
    schema.add_field(Field("a_long", ArrowType.INT64, True))
    schema.add_field(Field("b_int", ArrowType.INT32, True))
    schema.add_field(Field("c_dbl", ArrowType.FLOAT64, True))
    schema.add_field(Field("d_str", ArrowType.STRING, True))
    schema.add_field(Field("e_bool", ArrowType.BOOL, True))
    schema.add_field(Field("f_flt", ArrowType.FLOAT32, True))

    var a = PrimitiveArray[DType.int64].allocate(n)
    var longs = _i64s(1, 1, 1, 7, -42, 100000)
    for i in range(n):
        a.set(i, Int64(longs[i]))

    var b = PrimitiveArray[DType.int32].allocate(n)
    var ints = _i64s(10, 20, 30, 30, 30, -5)
    for i in range(n):
        b.set(i, Int32(ints[i]))

    var c = PrimitiveArray[DType.float64].allocate(n)
    c.set(0, 1.5)
    c.set(1, 2.5)
    c.set(2, -3.25)
    c.set(3, 0.0)
    c.set(4, 99.125)
    c.set(5, -1000.0)

    var ss = List[String]()
    ss.append(String("apple"))
    ss.append(String("banana"))
    ss.append(String(""))
    ss.append(String("cherry"))
    ss.append(String("date"))
    ss.append(String("elderberry"))
    var d = StringArray.from_strings(ss)

    var e = BooleanArray.allocate(n)
    e.set(0, True)
    e.set(1, False)
    e.set(2, True)
    e.set(3, True)
    e.set(4, False)
    e.set(5, False)

    var f = PrimitiveArray[DType.float32].allocate(n)
    f.set(0, 0.5)
    f.set(1, 1.25)
    f.set(2, -2.0)
    f.set(3, 3.5)
    f.set(4, -4.75)
    f.set(5, 6.0)

    var builder = RecordBatchBuilder.with_capacity(6)
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](a^, ArrowType.INT64)
    )
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](b^, ArrowType.INT32)
    )
    builder.add_column(Column.from_primitive[DType.float64](c^))
    builder.add_column(Column.from_string(d^))
    builder.add_column(Column.from_boolean(e^))
    builder.add_column(Column.from_primitive[DType.float32](f^))
    return builder.build(schema.build())


def _assert_mixed_roundtrip(rb: RecordBatch) raises:
    assert_equal(rb.num_columns(), 6, "6 columns")
    assert_equal(rb.num_rows(), 6, "6 rows")

    var a = rb.column_as_primitive_int64(0)
    var expect_a = _i64s(1, 1, 1, 7, -42, 100000)
    for i in range(6):
        assert_equal(Int(a.get(i)), Int(expect_a[i]), "a_long row " + String(i))

    var b = rb.column_as_primitive_int32(1)
    var expect_b = _i64s(10, 20, 30, 30, 30, -5)
    for i in range(6):
        assert_equal(Int(b.get(i)), Int(expect_b[i]), "b_int row " + String(i))

    var c = rb.column_as_primitive_float64(2)
    assert_true(c.get(0) == 1.5, "c row0")
    assert_true(c.get(4) == 99.125, "c row4")
    assert_true(c.get(5) == -1000.0, "c row5")

    var d = rb.column_as_string(3)
    assert_equal(d.get(0), String("apple"), "d row0")
    assert_equal(d.get(2), String(""), "d row2 empty")
    assert_equal(d.get(5), String("elderberry"), "d row5")

    var e = rb.column_as_boolean(4)
    assert_true(e.get(0), "e row0 true")
    assert_true(not e.get(1), "e row1 false")
    assert_true(e.get(3), "e row3 true")

    var f = rb.column_as_primitive_float32(5)
    assert_true(f.get(0) == Float32(0.5), "f row0")
    assert_true(f.get(5) == Float32(6.0), "f row5")


def _roundtrip_one_codec(codec: Int, label: String) raises:
    var rb = _build_mixed_batch()
    var opts = AvroWriterOptions(codec)
    var bytes = write_avro_bytes(rb, opts)
    assert_true(len(bytes) > 4, label + ": non-empty output")
    # Leading "Obj" 0x01 magic sanity.
    assert_true(
        bytes[0] == UInt8(ord("O"))
        and bytes[1] == UInt8(ord("b"))
        and bytes[2] == UInt8(ord("j"))
        and bytes[3] == UInt8(0x01),
        label + ": leading Obj magic",
    )
    var back = read_avro_bytes(Span(bytes))
    _assert_mixed_roundtrip(back)


# =============================================================================
# test_write_avro_roundtrip — core self-round-trip (null codec).
# =============================================================================


def test_write_avro_roundtrip() raises:
    _roundtrip_one_codec(AVRO_CODEC_NULL, "NULL")


# =============================================================================
# test_write_codecs_all_6 — round-trip through each of the 6 codecs.
# =============================================================================


def test_write_codecs_all_6() raises:
    _roundtrip_one_codec(AVRO_CODEC_NULL, "null")
    _roundtrip_one_codec(AVRO_CODEC_DEFLATE, "deflate")
    _roundtrip_one_codec(AVRO_CODEC_SNAPPY, "snappy")
    _roundtrip_one_codec(AVRO_CODEC_BZIP2, "bzip2")
    _roundtrip_one_codec(AVRO_CODEC_XZ, "xz")
    _roundtrip_one_codec(AVRO_CODEC_ZSTANDARD, "zstandard")


# =============================================================================
# test_write_arrow_logicals_emit — lossy arrow.* types survive round-trip.
# =============================================================================
#
# A long-backed lossy type (DATE64) + an int-backed lossy type (UINT16) get
# arrow.* annotations on the schema and round-trip back to their exact Arrow
# types via the reader's override-table consult.


def test_write_arrow_logicals_emit() raises:
    var n = 4
    var schema = SchemaBuilder()
    schema.add_field(Field("d64", ArrowType.DATE64, True))
    schema.add_field(Field("u16", ArrowType.UINT16, True))

    var d = PrimitiveArray[DType.int64].allocate(n)
    d.set(0, Int64(1609459200000))  # 2021-01-01 in ms
    d.set(1, Int64(0))
    d.set(2, Int64(-86400000))
    d.set(3, Int64(1700000000000))

    var u = PrimitiveArray[DType.uint16].allocate(n)
    u.set(0, UInt16(0))
    u.set(1, UInt16(65535))
    u.set(2, UInt16(42))
    u.set(3, UInt16(30000))

    var builder = RecordBatchBuilder.with_capacity(2)
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](d^, ArrowType.DATE64)
    )
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.uint16](
            u^, ArrowType.UINT16
        )
    )
    var rb = builder.build(schema.build())

    var opts = AvroWriterOptions(AVRO_CODEC_NULL)
    opts.emit_arrow_logicals = True
    var bytes = write_avro_bytes(rb, opts)

    # The emitted schema must carry the arrow.* annotations.
    var header = decode_ocf_header(Span(bytes))
    assert_true(
        header.schema_json.find("arrow.date64") >= 0,
        "schema carries arrow.date64 annotation",
    )
    assert_true(
        header.schema_json.find("arrow.uint16") >= 0,
        "schema carries arrow.uint16 annotation",
    )

    var back = read_avro_bytes(Span(bytes))
    assert_equal(back.num_rows(), 4, "4 rows")
    # The reader's override table must map these back to DATE64 / UINT16.
    assert_true(
        back.schema.field_arrow_type(0) == ArrowType.DATE64,
        "col0 round-trips to DATE64",
    )
    assert_true(
        back.schema.field_arrow_type(1) == ArrowType.UINT16,
        "col1 round-trips to UINT16",
    )

    # The DATE64 column is Int64-backed; its values decode exactly through the
    # int64 accessor (which tolerates the DATE64 stamp). This proves the lossy
    # arrow.* annotation recovers BOTH the column type (asserted above) AND the
    # underlying values round-trip byte-exact. The UINT16 column carries its
    # arrow.* type as Column metadata over Int32 physical storage (Avro `int`
    # wire) — type recovery is asserted above; value-store reinterpretation
    # through a typed accessor would mismatch widths, so we assert the type.
    var d_back = back.column_as_primitive_int64(0)
    assert_equal(Int(d_back.get(0)), 1609459200000, "d64 row0")
    assert_equal(Int(d_back.get(2)), -86400000, "d64 row2")


# =============================================================================
# test_write_strict_mode_raise — strict-mode validation raises on bad type.
# =============================================================================
#
# A FIXED-backed lossy type (UINT64 -> fixed(8)) is NOT in the writer set
# yet. The writer must raise (no half-written OCF).


def test_write_strict_mode_raise() raises:
    var n = 2
    var schema = SchemaBuilder()
    schema.add_field(Field("u64", ArrowType.UINT64, True))
    var u = PrimitiveArray[DType.uint64].allocate(n)
    u.set(0, UInt64(1))
    u.set(1, UInt64(2))
    var builder = RecordBatchBuilder.with_capacity(1)
    builder.add_column(
        Column.from_primitive_with_arrow_type[DType.uint64](
            u^, ArrowType.UINT64
        )
    )
    var rb = builder.build(schema.build())

    var opts = AvroWriterOptions(AVRO_CODEC_NULL)
    var raised = False
    try:
        var _bytes = write_avro_bytes(rb, opts)
    except e:
        raised = True
        assert_true(
            String(e).find("UNSUPPORTED_TYPE") >= 0,
            "raises AvroWriteError.UNSUPPORTED_TYPE",
        )
    assert_true(raised, "strict-mode write of an unsupported type must raise")


# =============================================================================
# test_write_sync_marker_entropy_source — markers come from OS entropy.
# =============================================================================
#
# Two independent writes (and two raw generate_sync_marker calls) must produce
# DIFFERENT 16-byte markers — a fixed/PRNG-seeded value would collide. A
# 128-bit CSPRNG collision is astronomically improbable.


def _markers_differ(
    a: Array[UInt8, OCF_SYNC_LEN], b: Array[UInt8, OCF_SYNC_LEN]
) -> Bool:
    for i in range(OCF_SYNC_LEN):
        if a[i] != b[i]:
            return True
    return False


def test_write_sync_marker_entropy_source() raises:
    var m1 = generate_sync_marker()
    var m2 = generate_sync_marker()
    assert_true(
        _markers_differ(m1, m2),
        "two OS-entropy sync markers must differ (not fixed/PRNG)",
    )

    # And the markers embedded by two full writes differ too.
    var rb = _build_mixed_batch()
    var opts = AvroWriterOptions(AVRO_CODEC_NULL)
    var b1 = write_avro_bytes(rb, opts)
    var rb2 = _build_mixed_batch()
    var b2 = write_avro_bytes(rb2, opts)
    var h1 = decode_ocf_header(Span(b1))
    var h2 = decode_ocf_header(Span(b2))
    assert_true(
        _markers_differ(h1.sync_marker, h2.sync_marker),
        "two writes embed different sync markers",
    )


# =============================================================================
# test_write_block_size_trigger_or_first — bytes-OR-rows flush trigger.
# =============================================================================
#
# A tiny block_size_rows forces multiple blocks; a tiny block_size_bytes does
# likewise on the byte axis. We verify (a) >1 block is emitted when the trigger
# is set small, (b) the round-trip is still byte-correct across the multi-block
# layout, and (c) the rows-trigger and bytes-trigger each fire independently
# (whichever-first).


def _count_blocks(bytes: Span[UInt8, _]) raises -> Int:
    """Count OCF blocks by chained-walk after the header."""
    from komira_avro import scan_ocf_blocks
    var blocks = scan_ocf_blocks(bytes)
    return len(blocks)


def test_write_block_size_trigger_or_first() raises:
    var rb = _build_mixed_batch()  # 6 rows

    # ---- Rows trigger: flush every 2 rows -> 3 blocks. ----
    var opts_rows = AvroWriterOptions(
        AVRO_CODEC_NULL,
        1 << 30,  # huge byte budget so the row trigger dominates
        2,        # block_size_rows = 2
        True,
        String("topLevelRecord"),
        True,
    )
    var b_rows = write_avro_bytes(rb, opts_rows)
    assert_equal(_count_blocks(Span(b_rows)), 3, "rows-trigger: 3 blocks of 2")
    _assert_mixed_roundtrip(read_avro_bytes(Span(b_rows)))

    # ---- Bytes trigger: a tiny byte budget flushes after each row. ----
    var rb2 = _build_mixed_batch()
    var opts_bytes = AvroWriterOptions(
        AVRO_CODEC_NULL,
        1,          # block_size_bytes = 1 -> flush after every row
        1 << 30,    # huge row budget so the byte trigger dominates
        True,
        String("topLevelRecord"),
        True,
    )
    var b_bytes = write_avro_bytes(rb2, opts_bytes)
    assert_equal(
        _count_blocks(Span(b_bytes)), 6, "bytes-trigger: 6 single-row blocks"
    )
    _assert_mixed_roundtrip(read_avro_bytes(Span(b_bytes)))

    # ---- Default (large budgets) -> a single block. ----
    var rb3 = _build_mixed_batch()
    var b_default = write_avro_bytes(rb3, AvroWriterOptions(AVRO_CODEC_NULL))
    assert_equal(
        _count_blocks(Span(b_default)), 1, "default budgets: single block"
    )
    _assert_mixed_roundtrip(read_avro_bytes(Span(b_default)))


def main() raises:
    test_write_avro_roundtrip()
    test_write_codecs_all_6()
    test_write_arrow_logicals_emit()
    test_write_strict_mode_raise()
    test_write_sync_marker_entropy_source()
    test_write_block_size_trigger_or_first()
    print("test_avro_write_roundtrip: ALL PASS")
