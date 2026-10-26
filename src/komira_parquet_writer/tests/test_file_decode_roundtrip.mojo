# decode_parquet_file_from_bytes (komira_parquet) on files written by this
# package's record-batch writer, a separate implementation of the format:
#   - int64, float64, float32, bool, utf8 string, timestamp(us) and int32
#     columns, nullable and not, every value and every null, under each codec;
#   - several row groups come back concatenated in file order, equal to the
#     rows written, and equal to the same rows written as one row group;
#   - a projection returns only the listed columns, in the listed order;
#   - a table of zero rows decodes to zero rows with its schema;
#   - refusals built by rewriting a real file's footer: no row group, a nested
#     column, and a chunk that names bytes outside the data region: a size
#     near the Int maximum (which wraps when added to an offset), a negative
#     size or offset, a page offset past the footer, one byte past the footer;
#     and a chunk ending exactly at the footer is accepted.
# This package has no BINARY or fixed-size-list encoder, so those two shapes
# are not here.

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.byte_view import ByteView
from komira_parquet.file_decode import decode_parquet_file_from_bytes
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.morsel_reader import ColumnProjection
from komira_parquet_api.metadata import FileMetaData
from komira_parquet_api.types import CompressionCodec
from komira_parquet_writer import (
    serialize_file_metadata,
    write_record_batch_to_parquet_bytes,
)


def _view[
    mut: Bool, //, o: Origin[mut=mut]
](data: Span[UInt8, o]) -> ByteView[o]:
    # SAFETY: the view borrows `data`'s buffer under the origin `o`; the list
    # it came from outlives every use of the view in this file.
    return ByteView[o](data.unsafe_ptr(), len(data))


def _decode(file: List[UInt8]) raises -> RecordBatch:
    return decode_parquet_file_from_bytes(_view(Span(file)))


# Column      type          null when
#  0 id       INT64         never          r * 1000003 - 5
#  1 score    FLOAT64       r % 7 == 2     r / 8
#  2 weight   FLOAT32       never          -r / 4
#  3 flag     BOOL          r % 5 == 4     r % 3 == 0
#  4 name     STRING        r % 11 == 3    "row-r"
#  5 at       TIMESTAMP_US  r % 13 == 9    r * 1000
#  6 rank     INT32         never          r * 3 - 700


def _score_null(r: Int) -> Bool:
    return r % 7 == 2


def _flag_null(r: Int) -> Bool:
    return r % 5 == 4


def _name_null(r: Int) -> Bool:
    return r % 11 == 3


def _at_null(r: Int) -> Bool:
    return r % 13 == 9


def _batch(start: Int, n: Int) raises -> RecordBatch:
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder()
    var id = PrimitiveArray[DType.int64].allocate(n)
    var score = PrimitiveArray[DType.float64].allocate_nullable(n)
    var weight = PrimitiveArray[DType.float32].allocate(n)
    var flag = BooleanArray.allocate_nullable(n)
    var names = List[String]()
    var name_ok = List[Bool]()
    var at = PrimitiveArray[DType.int64].allocate_nullable(n)
    var rank = PrimitiveArray[DType.int32].allocate(n)
    for i in range(n):
        var r = start + i
        id.set(i, Int64(r * 1000003 - 5))
        score.set(i, Float64(r) / 8.0)
        if _score_null(r):
            score._set_null(i)
        weight.set(i, Float32(-r) / 4.0)
        flag.set(i, r % 3 == 0)
        if _flag_null(r):
            flag._set_null(i)
        names.append(String("row-") + String(r))
        name_ok.append(not _name_null(r))
        at.set(i, Int64(r * 1000))
        if _at_null(r):
            at._set_null(i)
        rank.set(i, Int32(r * 3 - 700))
    sb.add_field(Field("id", ArrowType.INT64, False))
    b.add_column(Column.from_primitive[DType.int64](id))
    sb.add_field(Field("score", ArrowType.FLOAT64, True))
    b.add_column(Column.from_primitive[DType.float64](score))
    sb.add_field(Field("weight", ArrowType.FLOAT32, False))
    b.add_column(Column.from_primitive[DType.float32](weight))
    sb.add_field(Field("flag", ArrowType.BOOL, True))
    b.add_column(Column.from_boolean(flag))
    sb.add_field(Field("name", ArrowType.STRING, True))
    b.add_column(
        Column.from_string(StringArray.from_strings_with_validity(names, name_ok))
    )
    sb.add_field(Field("at", ArrowType.TIMESTAMP_US, True))
    b.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](
            at, ArrowType.TIMESTAMP_US
        )
    )
    sb.add_field(Field("rank", ArrowType.INT32, False))
    b.add_column(Column.from_primitive[DType.int32](rank))
    return b.build(sb.build())


def _check_rows(b: RecordBatch, start: Int, n: Int) raises:
    assert_equal(b.num_rows(), n)
    assert_equal(b.num_columns(), 7)
    assert_equal(b.schema.field_name(0), "id")
    assert_equal(b.schema.field_name(6), "rank")
    for i in range(n):
        var r = start + i
        var w = "row " + String(r)
        assert_equal(
            Int(b.column_at(0).as_primitive[DType.int64]().get(i)),
            r * 1000003 - 5,
            w,
        )
        assert_equal(b.column_at(1).is_null_at(i), _score_null(r), w)
        if not _score_null(r):
            assert_equal(
                b.column_at(1).as_primitive[DType.float64]().get(i),
                Float64(r) / 8.0,
                w,
            )
        assert_equal(
            b.column_at(2).as_primitive[DType.float32]().get(i),
            Float32(-r) / 4.0,
            w,
        )
        assert_equal(b.column_at(3).is_null_at(i), _flag_null(r), w)
        if not _flag_null(r):
            assert_equal(b.column_at(3).as_boolean().get(i), r % 3 == 0, w)
        assert_equal(b.column_at(4).is_null_at(i), _name_null(r), w)
        if not _name_null(r):
            assert_equal(
                b.column_at(4).as_string().get(i), String("row-") + String(r), w
            )
        assert_equal(b.column_at(5).is_null_at(i), _at_null(r), w)
        if not _at_null(r):
            assert_equal(
                Int(b.column_at(5).as_primitive[DType.int64]().get(i)),
                r * 1000,
                w,
            )
        assert_equal(
            Int(b.column_at(6).as_primitive[DType.int32]().get(i)),
            r * 3 - 700,
            w,
        )


def _footer_of(file: List[UInt8]) raises -> FileMetaData:
    var n = len(file)
    var flen = 0
    for k in range(4):
        flen |= Int(file[n - 8 + k]) << (8 * k)
    return parse_full_metadata(_view(Span(file)[n - 8 - flen : n - 8]))


def _with_footer(file: List[UInt8], md: FileMetaData) raises -> List[UInt8]:
    """`file`'s data region followed by `md` as its footer."""
    var n = len(file)
    var old = 0
    for k in range(4):
        old |= Int(file[n - 8 + k]) << (8 * k)
    var out = List[UInt8]()
    for i in range(n - 8 - old):
        out.append(file[i])
    var footer = serialize_file_metadata(md)
    var flen = len(footer)
    for i in range(flen):
        out.append(footer[i])
    for k in range(4):
        out.append(UInt8((flen >> (8 * k)) & 0xFF))
    for c in [0x50, 0x41, 0x52, 0x31]:
        out.append(UInt8(c))
    return out^


def test_every_column_type_round_trips_under_each_codec() raises:
    for codec in [
        CompressionCodec.UNCOMPRESSED,
        CompressionCodec.SNAPPY,
        CompressionCodec.ZSTD,
    ]:
        var file = write_record_batch_to_parquet_bytes(_batch(0, 500), codec)
        _check_rows(_decode(file), 0, 500)


def test_row_groups_concatenate_in_file_order() raises:
    var file = write_record_batch_to_parquet_bytes(
        _batch(0, 250), CompressionCodec.UNCOMPRESSED, 100
    )
    assert_equal(len(_footer_of(file).row_groups), 3)
    var many = _decode(file)
    _check_rows(many, 0, 250)
    var one_file = write_record_batch_to_parquet_bytes(
        _batch(0, 250), CompressionCodec.UNCOMPRESSED
    )
    assert_equal(len(_footer_of(one_file).row_groups), 1)
    var one = _decode(one_file)
    assert_equal(many.num_rows(), one.num_rows())
    for i in range(250):
        assert_equal(
            many.column_at(0).as_primitive[DType.int64]().get(i),
            one.column_at(0).as_primitive[DType.int64]().get(i),
        )


def test_a_projection_returns_the_listed_columns_in_order() raises:
    var file = write_record_batch_to_parquet_bytes(_batch(0, 40))
    var picked = decode_parquet_file_from_bytes(
        _view(Span(file)), ColumnProjection.columns([6, 0])
    )
    assert_equal(picked.num_columns(), 2)
    assert_equal(picked.num_rows(), 40)
    assert_equal(picked.schema.field_name(0), "rank")
    assert_equal(picked.schema.field_name(1), "id")
    for i in range(40):
        assert_equal(
            Int(picked.column_at(0).as_primitive[DType.int32]().get(i)),
            i * 3 - 700,
        )
        assert_equal(
            Int(picked.column_at(1).as_primitive[DType.int64]().get(i)),
            i * 1000003 - 5,
        )


def test_a_table_of_zero_rows_decodes_to_zero_rows() raises:
    var file = write_record_batch_to_parquet_bytes(_batch(0, 0))
    var b = _decode(file)
    assert_equal(b.num_rows(), 0)
    assert_equal(b.num_columns(), 7)
    assert_equal(b.schema.field_name(4), "name")


def test_a_footer_with_no_row_group_is_refused() raises:
    var file = write_record_batch_to_parquet_bytes(_batch(0, 10))
    var md = _footer_of(file)
    md.row_groups.clear()
    with assert_raises(contains="the file has no row group"):
        _ = _decode(_with_footer(file, md))


def test_a_nested_column_is_refused() raises:
    var file = write_record_batch_to_parquet_bytes(_batch(0, 10))
    var md = _footer_of(file)
    md.schema[2].num_children = 1
    with assert_raises(contains="is nested"):
        _ = _decode(_with_footer(file, md))


def test_a_chunk_outside_the_data_region_is_refused() raises:
    var file = write_record_batch_to_parquet_bytes(_batch(0, 10))
    var md = _footer_of(file)
    md.row_groups[0].columns[1].meta_data.total_compressed_size = len(file) + 100
    with assert_raises(contains="outside the data region"):
        _ = _decode(_with_footer(file, md))
    var md2 = _footer_of(file)
    md2.row_groups[0].columns[0].meta_data.dictionary_page_offset = None
    md2.row_groups[0].columns[0].meta_data.data_page_offset = 0
    with assert_raises(contains="outside the data region"):
        _ = _decode(_with_footer(file, md2))


def _data_end(file: List[UInt8]) -> Int:
    """Where the footer starts: the end of the data region."""
    var n = len(file)
    var flen = 0
    for k in range(4):
        flen |= Int(file[n - 8 + k]) << (8 * k)
    return n - 8 - flen


def test_a_chunk_size_near_the_int_maximum_is_refused() raises:
    # The first column stays valid. A size this large added to its offset
    # wraps negative; it must be refused, not passed as in range.
    var file = write_record_batch_to_parquet_bytes(_batch(0, 10))
    # The footer's zigzag varints reach Int.MAX // 2 at most; larger values
    # are refused by the footer parser (the footer-parser test below).
    var sizes = [Int.MAX // 2, Int.MAX // 2 - 1, Int.MAX // 2 - 100, 1 << 40]
    for size in sizes:
        var md = _footer_of(file)
        md.row_groups[0].columns[1].meta_data.total_compressed_size = size
        with assert_raises(contains="outside the data region"):
            _ = _decode(_with_footer(file, md))


def test_the_footer_parser_refuses_values_past_the_int_range_of_a_varint() raises:
    # Sizes and offsets of 2^62 and more do not fit the footer's signed
    # varints: the parser refuses the footer before any range is computed.
    var file = write_record_batch_to_parquet_bytes(_batch(0, 10))
    var md = _footer_of(file)
    md.row_groups[0].columns[1].meta_data.total_compressed_size = Int.MAX
    with assert_raises(contains="malformed varint"):
        _ = _decode(_with_footer(file, md))
    var md2 = _footer_of(file)
    md2.row_groups[0].columns[1].meta_data.data_page_offset = Int.MIN
    with assert_raises(contains="malformed varint"):
        _ = _decode(_with_footer(file, md2))


def test_a_negative_chunk_size_or_offset_is_refused() raises:
    var file = write_record_batch_to_parquet_bytes(_batch(0, 10))
    var md = _footer_of(file)
    md.row_groups[0].columns[1].meta_data.total_compressed_size = -1
    with assert_raises(contains="outside the data region"):
        _ = _decode(_with_footer(file, md))
    var md2 = _footer_of(file)
    md2.row_groups[0].columns[2].meta_data.dictionary_page_offset = None
    md2.row_groups[0].columns[2].meta_data.data_page_offset = -4
    with assert_raises(contains="outside the data region"):
        _ = _decode(_with_footer(file, md2))
    var md3 = _footer_of(file)
    md3.row_groups[0].columns[2].meta_data.dictionary_page_offset = -(Int.MAX // 2)
    with assert_raises(contains="outside the data region"):
        _ = _decode(_with_footer(file, md3))


def test_a_page_offset_past_the_data_region_is_refused() raises:
    var file = write_record_batch_to_parquet_bytes(_batch(0, 10))
    var end = _data_end(file)
    var md = _footer_of(file)
    md.row_groups[0].columns[1].meta_data.dictionary_page_offset = None
    md.row_groups[0].columns[1].meta_data.data_page_offset = Int.MAX // 2
    with assert_raises(contains="outside the data region"):
        _ = _decode(_with_footer(file, md))
    var md2 = _footer_of(file)
    md2.row_groups[0].columns[1].meta_data.dictionary_page_offset = None
    md2.row_groups[0].columns[1].meta_data.data_page_offset = end + 1
    with assert_raises(contains="outside the data region"):
        _ = _decode(_with_footer(file, md2))


def test_a_chunk_that_ends_exactly_at_the_footer_is_accepted() raises:
    var file = write_record_batch_to_parquet_bytes(_batch(0, 10))
    var end = _data_end(file)
    var md = _footer_of(file)
    ref meta = md.row_groups[0].columns[6].meta_data
    var lo = meta.data_page_offset
    if meta.dictionary_page_offset:
        lo = min(lo, meta.dictionary_page_offset.value())
    meta.total_compressed_size = end - lo
    _check_rows(_decode(_with_footer(file, md)), 0, 10)
    var md2 = _footer_of(file)
    ref meta2 = md2.row_groups[0].columns[6].meta_data
    meta2.total_compressed_size = end - lo + 1
    with assert_raises(contains="outside the data region"):
        _ = _decode(_with_footer(file, md2))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
