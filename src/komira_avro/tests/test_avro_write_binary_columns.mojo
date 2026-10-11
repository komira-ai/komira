# =============================================================================
# test_avro_write_binary_columns.mojo -- the OCF writer encodes BINARY and
# LARGE_BINARY columns as Avro `bytes`, read back through the independent
# reader as the oracle.
# =============================================================================
#
# What each case proves, and the defect it catches:
#   B1  a batch of a nullable BINARY, a nullable LARGE_BINARY and a
#       non-nullable BINARY column (values include an empty value, 0x00,
#       0xFF and bytes that are not UTF-8; a null in each nullable column)
#       is written through the null codec (the inline null-codec path) and
#       through deflate (the block path), two rows per block, and reads back
#       value for value and null for null as BINARY columns. Catches the
#       writer that fetched a binary column through the string accessor
#       (`Column.as_string: arrow_type is binary, expected string`), and an
#       encode arm that reads the wrong column or drops a byte. Mutant: the
#       LARGE_BINARY arm encodes the value without its last byte: red on
#       the read-back value.
#   B2  the emitted schema names both binary columns "bytes" (["null",
#       "bytes"] for the nullable ones). Catches a writer whose schema and
#       value encoders disagree on the Avro type.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.binary_array import BinaryArray
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.large_binary_array import LargeBinaryArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import SchemaBuilder, Field

from komira_avro import (
    AvroWriterOptions,
    write_avro_bytes,
    read_avro_bytes,
    decode_ocf_header,
    scan_ocf_blocks,
    AVRO_CODEC_NULL,
    AVRO_CODEC_DEFLATE,
)


comptime _N = 4


def _values() -> List[List[UInt8]]:
    var v = List[List[UInt8]]()
    v.append([0x00, 0xFF, 0x80])
    v.append([])
    v.append([0xC3, 0x28])  # not UTF-8
    v.append([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17])
    return v^


def _validity(null_row: Int) -> Bitmap[]:
    var bm = Bitmap.create_all_valid(_N)
    bm.clear(null_row)
    return bm^


def _batch() raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("b", ArrowType.BINARY, True))
    sb.add_field(Field("lb", ArrowType.LARGE_BINARY, True))
    sb.add_field(Field("b2", ArrowType.BINARY, False))
    var b = BinaryArray.from_bytes_list(_values())
    b.validity = _validity(1)
    b.null_count = 1
    var lb = LargeBinaryArray.from_bytes_list(_values())
    lb.validity = _validity(2)
    lb.null_count = 1
    var b2 = BinaryArray.from_bytes_list(_values())
    var bb = RecordBatchBuilder.with_capacity(3)
    bb.add_column(Column.from_binary(b^))
    bb.add_column(Column.from_large_binary(lb^))
    bb.add_column(Column.from_binary(b2^))
    return bb.build(sb.build())


def _opts(codec: Int) -> AvroWriterOptions:
    return AvroWriterOptions(
        codec, 1 << 20, 2, False, String("R"), True, False
    )


def _check_column(
    rb: RecordBatch, col: Int, null_row: Int, label: String
) raises:
    assert_true(
        rb.schema.field_arrow_type(col) == ArrowType.BINARY,
        label + " reads back as BINARY",
    )
    var arr = rb.column_as_binary(col)
    var want = _values()
    assert_equal(len(arr), _N, label + " length")
    for r in range(_N):
        var l = label + " row " + String(r)
        if r == null_row:
            assert_true(arr.is_null(r), l + " is null")
            continue
        assert_true(not arr.is_null(r), l + " is not null")
        var got = arr.get(r)
        assert_equal(len(got), len(want[r]), l + " length")
        for i in range(len(got)):
            assert_equal(got[i], want[r][i], l + " byte " + String(i))


def test_binary_columns_round_trip() raises:
    """B1."""
    var rb = _batch()
    var codecs: List[Int] = [AVRO_CODEC_NULL, AVRO_CODEC_DEFLATE]
    for c in codecs:
        var bytes = write_avro_bytes(rb, _opts(c))
        assert_equal(len(scan_ocf_blocks(Span(bytes))), 2, "two blocks")
        var back = read_avro_bytes(Span(bytes))
        assert_equal(back.num_rows(), _N)
        var label = "codec " + String(c)
        _check_column(back, 0, 1, label + " b")
        _check_column(back, 1, 2, label + " lb")
        _check_column(back, 2, -1, label + " b2")


def test_binary_schema_json() raises:
    """B2."""
    var bytes = write_avro_bytes(_batch(), _opts(AVRO_CODEC_NULL))
    assert_equal(
        decode_ocf_header(Span(bytes)).schema_json,
        String('{"type":"record","name":"R","fields":[')
        + '{"name":"b","type":["null","bytes"]},'
        + '{"name":"lb","type":["null","bytes"]},'
        + '{"name":"b2","type":"bytes"}]}',
    )


def main() raises:
    test_binary_columns_round_trip()
    test_binary_schema_json()
    print("test_avro_write_binary_columns: ALL PASS")
