# =============================================================================
# test_delta_codec_refusal.mojo -- framed delta objects are read from object
#   storage, so a damaged one is refused with an error and never allocates what
#   its header claims.
# =============================================================================
#
#   truncation    a valid framed object cut to any shorter length is refused,
#                 including inside a string cell and after the last column's
#                 header; the whole object decodes.
#   trailing      one byte after the last column is refused.
#   tag, version  an empty body, a Parquet object and an unknown tag are not
#                 framed bodies; a codec version other than 1 is refused.
#   dimensions    no column, a negative column or row count, and counts that the
#                 bytes present cannot hold (up to 2^63 - 1 and a product of two
#                 counts that would overflow a multiplication) are refused
#                 before any buffer is sized from them: were one allocated, the
#                 test would exhaust memory instead of passing.
#   cells         an unknown column type code, a string length that is negative,
#                 larger than the body, or large enough to wrap an offset sum is
#                 refused.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_kg_format import (
    FRAME_TAG_FRAMED,
    FRAME_TAG_PARQUET,
    FRAMED_CODEC_VERSION,
    FRAMED_MAX_ROWS,
    decode_framed_delta_to_batch,
    encode_delta_table_object,
)


def _i64(mut out: List[UInt8], v: Int64):
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8(Int((u >> UInt64(8 * i)) & UInt64(0xFF))))


def _header(version: Int64, ncols: Int64, nrows: Int64) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(FRAME_TAG_FRAMED)
    _i64(out, version)
    _i64(out, ncols)
    _i64(out, nrows)
    return out^


def _refused(body: List[UInt8]) -> Bool:
    try:
        _ = decode_framed_delta_to_batch(body)
    except:
        return True
    return False


def _valid() raises -> List[UInt8]:
    var ids: List[Int64] = [11, 22, 33]
    var names: List[String] = ["a", "bcd", ""]
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(ids^)
        )
    )
    rb.add_column(Column.from_string(StringArray.from_strings(names^)))
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("name", ArrowType.STRING, False))
    return encode_delta_table_object(rb.build(sb.build()))


def test_every_truncation_is_refused_and_the_whole_object_decodes() raises:
    var full = _valid()
    for n in range(len(full)):
        var cut = List[UInt8](capacity=n)
        for i in range(n):
            cut.append(full[i])
        assert_true(_refused(cut), "an object cut to " + String(n) + " bytes was accepted")
    var back = decode_framed_delta_to_batch(full)
    assert_equal(back.num_rows(), 3)


def test_trailing_bytes_are_refused() raises:
    var full = _valid()
    full.append(0)
    with assert_raises(contains="1 trailing bytes"):
        _ = decode_framed_delta_to_batch(full)


def test_a_body_that_is_not_framed_is_refused() raises:
    with assert_raises(contains="not a framed body"):
        _ = decode_framed_delta_to_batch(List[UInt8]())
    var parquet_tag: List[UInt8] = [FRAME_TAG_PARQUET, 1, 2, 3]
    with assert_raises(contains="not a framed body"):
        _ = decode_framed_delta_to_batch(parquet_tag)
    var unknown: List[UInt8] = [9, 1, 2, 3]
    with assert_raises(contains="not a framed body"):
        _ = decode_framed_delta_to_batch(unknown)


def test_a_codec_version_other_than_one_is_refused() raises:
    assert_equal(FRAMED_CODEC_VERSION, 1)
    var a = _header(2, 1, 0)
    _i64(a, 5)
    with assert_raises(contains="unsupported framed codec version 2"):
        _ = decode_framed_delta_to_batch(a)
    var b = _header(0, 1, 0)
    with assert_raises(contains="unsupported framed codec version 0"):
        _ = decode_framed_delta_to_batch(b)


def test_no_column_and_negative_dimensions_are_refused() raises:
    with assert_raises(contains="invalid dimensions"):
        _ = decode_framed_delta_to_batch(_header(1, 0, 0))
    with assert_raises(contains="invalid dimensions"):
        _ = decode_framed_delta_to_batch(_header(1, -1, 0))
    var neg_rows = _header(1, 1, -1)
    _i64(neg_rows, 5)
    with assert_raises(contains="invalid dimensions"):
        _ = decode_framed_delta_to_batch(neg_rows)


def test_dimensions_the_bytes_cannot_hold_are_refused_without_allocating() raises:
    var counts: List[Int64] = [
        Int64.MAX,
        Int64(1) << 40,
        Int64(1) << 31,
        1000000,
        100,
    ]
    for k in range(len(counts)):
        var rows = _header(1, 1, counts[k])
        _i64(rows, Int64(ArrowType.INT64.type_id))
        _i64(rows, 7)
        assert_true(_refused(rows), "rows " + String(counts[k]))
        var cols = _header(1, counts[k], 0)
        for _ in range(4):
            _i64(cols, Int64(ArrowType.INT64.type_id))
        assert_true(_refused(cols), "columns " + String(counts[k]))
    # Each count alone fits the bytes; their product does not and, for these,
    # would also overflow a multiplication of the raw values.
    var both = _header(1, Int64(1) << 31, Int64(1) << 31)
    for _ in range(64):
        _i64(both, 0)
    assert_true(_refused(both))


def test_an_unknown_column_type_is_refused() raises:
    var b = _header(1, 1, 1)
    _i64(b, 999)
    _i64(b, 5)
    with assert_raises(contains="unframable column type code 999"):
        _ = decode_framed_delta_to_batch(b)


def test_bad_string_cell_lengths_are_refused() raises:
    var lengths: List[Int64] = [-1, 1000, Int64.MAX, Int64.MAX - 7]
    for k in range(len(lengths)):
        var b = _header(1, 1, 1)
        _i64(b, Int64(ArrowType.STRING.type_id))
        _i64(b, lengths[k])
        for _ in range(8):
            b.append(65)
        with assert_raises(contains="truncated string cell"):
            _ = decode_framed_delta_to_batch(b)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
