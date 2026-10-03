# =============================================================================
# test_orc_write_roundtrip.mojo — ORC writer self-round-trip.
# =============================================================================
#
# THE KEY ACCEPTANCE TEST: write a RecordBatch -> ORC
# bytes (write_orc_bytes) -> read it back via the reader
# (read_orc_bytes) -> assert equality. Fully self-contained (no external
# orc-cpp / orc-tools / pyarrow.orc needed). Exercises the
# protobuf encoder, the RLEv2 (Short Repeat + Direct) encoder, the boolean RLE
# encoder, per-column stats, the codec compress matrix, and the file-tail
# assembly all at once, against the known-correct reader.
#
# The codec matrix here is FIVE arms, not six: ORC's deprecated LZO is
# read-only in this implementation (see `test_orc_write_lzo_is_refused`, and
# `lzo1x_decompress.mojo` for why).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Schema, SchemaBuilder, Field

from komira_orc import (
    OrcWriterOptions,
    write_orc_bytes,
    read_orc_bytes,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZLIB,
    ORC_COMPRESSION_SNAPPY,
    ORC_COMPRESSION_LZO,
    ORC_COMPRESSION_LZ4,
    ORC_COMPRESSION_ZSTD,
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

    var builder = RecordBatchBuilder.with_capacity(5)
    builder.add_column(Column.from_primitive_with_arrow_type[DType.int64](a^, ArrowType.INT64))
    builder.add_column(Column.from_primitive_with_arrow_type[DType.int32](b^, ArrowType.INT32))
    builder.add_column(Column.from_primitive[DType.float64](c^))
    builder.add_column(Column.from_string(d^))
    builder.add_column(Column.from_boolean(e^))
    return builder.build(schema.build())


def _assert_mixed_roundtrip(rb: RecordBatch) raises:
    assert_equal(rb.num_columns(), 5, "5 columns")
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


def _roundtrip_one_codec(codec: Int, label: String) raises:
    var rb = _build_mixed_batch()
    var opts = OrcWriterOptions(codec, 10000, String("UTC"))
    var bytes = write_orc_bytes(rb, opts)
    assert_true(len(bytes) > 4, label + ": non-empty output")
    # Leading + trailing-ish magic sanity.
    assert_true(
        bytes[0] == UInt8(ord("O"))
        and bytes[1] == UInt8(ord("R"))
        and bytes[2] == UInt8(ord("C")),
        label + ": leading ORC magic",
    )
    var back = read_orc_bytes(Span(bytes))
    _assert_mixed_roundtrip(back)


# =============================================================================
# Tests — one per codec.
# =============================================================================


def test_orc_write_roundtrip_none() raises:
    _roundtrip_one_codec(ORC_COMPRESSION_NONE, "NONE")


def test_orc_write_roundtrip_zstd() raises:
    _roundtrip_one_codec(ORC_COMPRESSION_ZSTD, "ZSTD")


def test_orc_write_roundtrip_zlib() raises:
    _roundtrip_one_codec(ORC_COMPRESSION_ZLIB, "ZLIB")


def test_orc_write_roundtrip_snappy() raises:
    _roundtrip_one_codec(ORC_COMPRESSION_SNAPPY, "SNAPPY")


def test_orc_write_roundtrip_lz4() raises:
    _roundtrip_one_codec(ORC_COMPRESSION_LZ4, "LZ4")


def test_orc_write_lzo_is_refused() raises:
    """LZO IS NOT A WRITE CODEC HERE, AND THAT IS THE ASSERTION.

    The only LZO1X encoder available is GPL-2.0-or-later liblzo2, which is
    not part of the build, and the write half is deliberately absent rather
    than reimplemented — the ORC spec marks the codec deprecated, so there is
    no case in which we would choose to emit it. Apache's own orc-cpp made the
    same call: pyarrow 24 answers `Unknown CompressionKind: LZO` to a write
    request.

    ⚠ THIS IS NOT A COVERAGE GAP, and the reason is worth stating so nobody
    "adds" an LZO round-trip. A write round-trip exercises the writer's CHUNK
    FRAMING and file-tail assembly, which are codec-independent — one shared
    `compress_stream` loop — and the five codec round-trips exercise exactly
    that. The only thing unique to an LZO arm would be "liblzo2 can decode
    what liblzo2 encoded", which is not a property of this package. The READ
    half is covered by golden vectors: `test_orc_lzo1x_decompress.mojo` holds
    twelve golden vectors from the reference encoder, chosen for opcode
    coverage, plus a truncation sweep.
    """
    var rb = _build_mixed_batch()
    var opts = OrcWriterOptions(ORC_COMPRESSION_LZO, 10000, String("UTC"))
    var raised = False
    try:
        var _bytes = write_orc_bytes(rb, opts)
    except:
        raised = True
    assert_true(
        raised, "writing ORC with CompressionKind.LZO must be refused"
    )


def main() raises:
    test_orc_write_roundtrip_none()  # raises-aware (main is def -> can raise)
    test_orc_write_roundtrip_zstd()
    test_orc_write_roundtrip_zlib()
    test_orc_write_roundtrip_snappy()
    test_orc_write_roundtrip_lz4()
    test_orc_write_lzo_is_refused()
    print("test_orc_write_roundtrip: ALL PASS")
