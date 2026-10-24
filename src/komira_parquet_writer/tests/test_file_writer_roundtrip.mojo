# ParquetFileWriter's bytes, decoded by komira_parquet's reader.
#
# The reader is a different implementation from the writer (it shares no code
# with it), so a value, null or footer field that round-trips here is what
# the format says, not what the writer assumes. Each test writes a file in
# memory with `close_to_bytes`, parses its footer with `parse_full_metadata`
# and decodes row group 0 with `decode_row_group_from_bytes`.
#
# What each test proves, and the defect it catches:
#   * test_every_type_roundtrips_under_every_codec: INT32, INT64, FLOAT,
#     DOUBLE, BOOLEAN and string columns (REQUIRED and OPTIONAL, plain and
#     dictionary) come back value-for-value and null-for-null under
#     UNCOMPRESSED, SNAPPY, GZIP and ZSTD. Catches a page whose definition
#     levels disagree with the schema's repetition type (an OPTIONAL column
#     written without levels reads back shifted).
#   * test_footer_describes_the_file: PAR1 at both ends, the footer length
#     word, num_rows, the schema, created_by, one chunk per leaf in schema
#     order, offsets that point at each chunk's first page, chunk sizes that
#     tile the file, RowGroup.total_byte_size as the uncompressed sum. Catches a footer that places a chunk
#     wrongly or reports the codec's savings as the uncompressed size.
#   * test_chunk_sizes_tell_compressed_from_raw: a compressible column reports
#     a small total_compressed_size and a raw-sized total_uncompressed_size.
#   * test_chunks_follow_schema_order_not_write_order: columns written in a
#     different order than the schema still read back under their own names.
#   * test_dictionary_and_plain_strings_pick_by_cardinality: a low-cardinality
#     column is dictionary encoded (dictionary_page_offset set, RLE_DICTIONARY
#     listed), a unique one is PLAIN.
#   * test_statistics_reach_the_footer: min, max, null_count of an OPTIONAL
#     column skip its null slots.
#   * test_a_page_from_another_builder_is_placed: a DELTA_BINARY_PACKED page
#     added through write_column_page decodes.
#   * test_empty_column_file: zero rows is a valid file.
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.string_array import StringArray
from komira_buffer.byte_view import ByteView
from komira_parquet.bytes_decode import (
    decode_row_group_from_bytes,
    row_group_byte_range,
)
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.morsel_reader import ColumnProjection
from komira_parquet_api.metadata import FileMetaData, SchemaElement
from komira_parquet_api.types import (
    CompressionCodec,
    Encoding,
    FieldRepetitionType,
    ParquetType,
)
from komira_parquet_writer import (
    ParquetFileWriter,
    encode_dbp_column_page,
    make_schema_elements_nullable,
)

comptime N: Int = 500


def _view[
    mut: Bool, //, o: Origin[mut=mut]
](data: Span[UInt8, o]) -> ByteView[o]:
    return ByteView[o](data.unsafe_ptr(), len(data))


def _footer(file: List[UInt8]) raises -> FileMetaData:
    var n = len(file)
    var flen = 0
    for k in range(4):
        flen |= Int(file[n - 8 + k]) << (8 * k)
    return parse_full_metadata(_view(Span(file)[n - 8 - flen : n - 8]))


def _read(file: List[UInt8], md: FileMetaData) raises -> RecordBatch:
    ref rg = md.row_groups[0]
    var br = row_group_byte_range(rg)
    return decode_row_group_from_bytes(
        _view(Span(file)[br.start : br.end]),
        br,
        rg,
        md.schema,
        ColumnProjection.all(),
    )


# The columns, by leaf index:
#   0 i32  REQUIRED         v = i * 3 - 700
#   1 i64  OPTIONAL         null when i % 7 == 2, else i * 1000003
#   2 f64  OPTIONAL         null when i % 11 == 5, else i / 8.0
#   3 f32  REQUIRED         -i / 4.0
#   4 bool OPTIONAL         null when i % 5 == 4, else i % 3 == 0
#   5 bool REQUIRED         i % 2 == 0
#   6 str  OPTIONAL         unique "row-i", null when i % 13 == 3 (PLAIN)
#   7 str  REQUIRED         "k" + (i % 5)                         (dictionary)


def _i32(i: Int) -> Int:
    return i * 3 - 700


def _i64_null(i: Int) -> Bool:
    return i % 7 == 2


def _f64_null(i: Int) -> Bool:
    return i % 11 == 5


def _b_null(i: Int) -> Bool:
    return i % 5 == 4


def _s_null(i: Int) -> Bool:
    return i % 13 == 3


def _schema() raises -> List[SchemaElement]:
    var names: List[String] = ["i32", "i64", "f64", "f32", "b_opt", "b_req", "s_opt", "s_req"]
    var types: List[ParquetType] = [
        ParquetType.INT32,
        ParquetType.INT64,
        ParquetType.DOUBLE,
        ParquetType.FLOAT,
        ParquetType.BOOLEAN,
        ParquetType.BOOLEAN,
        ParquetType.BYTE_ARRAY,
        ParquetType.BYTE_ARRAY,
    ]
    var nullable: List[Bool] = [False, True, True, False, True, False, True, False]
    return make_schema_elements_nullable(names^, types^, nullable^)


def _write_all(codec: CompressionCodec) raises -> List[UInt8]:
    var w = ParquetFileWriter.create(_schema(), codec)
    var a0 = PrimitiveArray[DType.int32].allocate(N)
    var a1 = PrimitiveArray[DType.int64].allocate_nullable(N)
    var a2 = PrimitiveArray[DType.float64].allocate_nullable(N)
    var a3 = PrimitiveArray[DType.float32].allocate(N)
    var a4 = BooleanArray.allocate_nullable(N)
    var a5 = BooleanArray.allocate(N)
    var s6 = List[String]()
    var v6 = List[Bool]()
    var s7 = List[String]()
    for i in range(N):
        a0.set(i, Int32(_i32(i)))
        a1.set(i, Int64(-5) if _i64_null(i) else Int64(i * 1000003))
        if _i64_null(i):
            a1._set_null(i)
        a2.set(i, Float64(-1.0) if _f64_null(i) else Float64(i) / 8.0)
        if _f64_null(i):
            a2._set_null(i)
        a3.set(i, Float32(-i) / 4.0)
        a4.set(i, i % 3 == 0)
        if _b_null(i):
            a4._set_null(i)
        a5.set(i, i % 2 == 0)
        s6.append(String("row-") + String(i))
        v6.append(not _s_null(i))
        s7.append(String("k") + String(i % 5))
    w.write_batch[DType.int32](0, a0)
    w.write_batch[DType.int64](1, a1)
    w.write_batch[DType.float64](2, a2)
    w.write_batch[DType.float32](3, a3)
    w.write_boolean_batch(4, a4)
    w.write_boolean_batch(5, a5)
    w.write_string_batch(6, StringArray.from_strings_with_validity(s6, v6))
    w.write_string_batch_dict(7, StringArray.from_strings(s7))
    return w.close_to_bytes()


def _check_values(b: RecordBatch) raises:
    assert_equal(b.num_rows(), N)
    assert_equal(b.num_columns(), 8)
    for i in range(N):
        var w = "row " + String(i)
        assert_equal(Int(b.column_at(0).as_primitive[DType.int32]().get(i)), _i32(i), w)
        assert_equal(b.column_at(1).is_null_at(i), _i64_null(i), w)
        if not _i64_null(i):
            assert_equal(Int(b.column_at(1).as_primitive[DType.int64]().get(i)), i * 1000003, w)
        assert_equal(b.column_at(2).is_null_at(i), _f64_null(i), w)
        if not _f64_null(i):
            assert_equal(b.column_at(2).as_primitive[DType.float64]().get(i), Float64(i) / 8.0, w)
        assert_equal(b.column_at(3).as_primitive[DType.float32]().get(i), Float32(-i) / 4.0, w)
        assert_equal(b.column_at(4).is_null_at(i), _b_null(i), w)
        if not _b_null(i):
            assert_equal(b.column_at(4).as_boolean().get(i), i % 3 == 0, w)
        assert_equal(b.column_at(5).as_boolean().get(i), i % 2 == 0, w)
        assert_equal(b.column_at(6).is_null_at(i), _s_null(i), w)
        if not _s_null(i):
            assert_equal(b.column_at(6).as_string().get(i), String("row-") + String(i), w)
        assert_equal(b.column_at(7).as_string().get(i), String("k") + String(i % 5), w)


def _roundtrip(codec: CompressionCodec) raises:
    var file = _write_all(codec)
    var md = _footer(file)
    _check_values(_read(file, md))


def test_every_type_roundtrips_under_every_codec() raises:
    _roundtrip(CompressionCodec.UNCOMPRESSED)
    _roundtrip(CompressionCodec.SNAPPY)
    _roundtrip(CompressionCodec.GZIP)
    _roundtrip(CompressionCodec.ZSTD)


def test_footer_describes_the_file() raises:
    var file = _write_all(CompressionCodec.SNAPPY)
    var n = len(file)
    assert_equal(Int(file[0]), 0x50)
    assert_equal(Int(file[1]), 0x41)
    assert_equal(Int(file[2]), 0x52)
    assert_equal(Int(file[3]), 0x31)
    for k in range(4):
        assert_equal(Int(file[n - 4 + k]), Int(file[k]))
    var md = _footer(file)
    assert_equal(md.version, 2)
    assert_equal(md.num_rows, N)
    assert_equal(md.created_by.value(), "komira-parquet-writer")
    assert_equal(len(md.schema), 9)
    assert_equal(md.schema[0].num_children, 8)
    assert_equal(len(md.row_groups), 1)
    ref rg = md.row_groups[0]
    assert_equal(rg.num_rows, N)
    assert_equal(len(rg.columns), 8)
    var names: List[String] = ["i32", "i64", "f64", "f32", "b_opt", "b_req", "s_opt", "s_req"]
    var pos = 4
    var total_compressed = 0
    var total_uncompressed = 0
    for c in range(8):
        ref meta = rg.columns[c].meta_data
        assert_equal(meta.path_in_schema[0], names[c])
        assert_equal(meta.num_values, N)
        assert_true(meta.codec == CompressionCodec.SNAPPY)
        var first = meta.data_page_offset
        if meta.dictionary_page_offset:
            first = meta.dictionary_page_offset.value()
        if first != pos:
            raise Error(
                "chunk " + String(c) + " starts at " + String(first)
                + ", the previous ended at " + String(pos)
                + "; dict=" + String(Bool(meta.dictionary_page_offset))
                + " data_off=" + String(meta.data_page_offset)
            )
        pos += meta.total_compressed_size
        total_compressed += meta.total_compressed_size
        total_uncompressed += meta.total_uncompressed_size
    assert_equal(pos, 4 + total_compressed)
    # parquet.thrift: RowGroup.total_byte_size counts the UNCOMPRESSED column
    # data, so it is not the bytes between the magics.
    assert_equal(rg.total_byte_size, total_uncompressed)
    assert_true(total_uncompressed != total_compressed)


def test_chunk_sizes_tell_compressed_from_raw() raises:
    var names: List[String] = ["z"]
    var types: List[ParquetType] = [ParquetType.INT64]
    var nullable: List[Bool] = [False]
    var w = ParquetFileWriter.create(
        make_schema_elements_nullable(names^, types^, nullable^), CompressionCodec.SNAPPY
    )
    var a = PrimitiveArray[DType.int64].allocate(4000)  # zeros: compress well
    w.write_batch[DType.int64](0, a)
    var file = w.close_to_bytes()
    ref meta = _footer(file).row_groups[0].columns[0].meta_data
    # The body is 32000 bytes raw plus a header; Snappy of zeros is tiny.
    assert_true(meta.total_uncompressed_size > 32000)
    assert_true(meta.total_compressed_size < 2000)


def test_chunks_follow_schema_order_not_write_order() raises:
    var names: List[String] = ["a", "b"]
    var types: List[ParquetType] = [ParquetType.INT32, ParquetType.INT64]
    var nullable: List[Bool] = [False, False]
    var w = ParquetFileWriter.create(make_schema_elements_nullable(names^, types^, nullable^))
    w.write_batch[DType.int64](1, PrimitiveArray[DType.int64].from_list([10, 20, 30]))
    w.write_batch[DType.int32](0, PrimitiveArray[DType.int32].from_list([1, 2, 3]))
    var file = w.close_to_bytes()
    var md = _footer(file)
    assert_equal(md.row_groups[0].columns[0].meta_data.path_in_schema[0], "a")
    assert_equal(md.row_groups[0].columns[1].meta_data.path_in_schema[0], "b")
    # `b` was written first, so it sits first in the file.
    assert_true(
        md.row_groups[0].columns[1].meta_data.data_page_offset
        < md.row_groups[0].columns[0].meta_data.data_page_offset
    )
    var b = _read(file, md)
    assert_equal(Int(b.column_at(0).as_primitive[DType.int32]().get(2)), 3)
    assert_equal(Int(b.column_at(1).as_primitive[DType.int64]().get(2)), 30)


def test_dictionary_and_plain_strings_pick_by_cardinality() raises:
    var md = _footer(_write_all(CompressionCodec.UNCOMPRESSED))
    ref plain = md.row_groups[0].columns[6].meta_data
    ref dict = md.row_groups[0].columns[7].meta_data
    assert_false(Bool(plain.dictionary_page_offset))
    assert_true(Bool(dict.dictionary_page_offset))
    var has_dict = False
    for e in dict.encodings:
        if e == Encoding.RLE_DICTIONARY or e == Encoding.PLAIN_DICTIONARY:
            has_dict = True
    assert_true(has_dict)
    assert_true(dict.data_page_offset > dict.dictionary_page_offset.value())


def test_statistics_reach_the_footer() raises:
    var md = _footer(_write_all(CompressionCodec.UNCOMPRESSED))
    ref s = md.row_groups[0].columns[1].meta_data.statistics.value()
    var nulls = 0
    for i in range(N):
        if _i64_null(i):
            nulls += 1
    assert_equal(s.null_count.value(), nulls)
    var lo = Int64(0)
    var hi = Int64(0)
    for k in range(8):
        lo |= Int64(s.min_value.value()[k]) << Int64(8 * k)
        hi |= Int64(s.max_value.value()[k]) << Int64(8 * k)
    # Row 0 is the smallest non-null value (0); the largest is the last
    # non-null row. Null slots hold -5, which must not be the minimum.
    assert_equal(Int(lo), 0)
    var last = N - 1
    while _i64_null(last):
        last -= 1
    assert_equal(Int(hi), last * 1000003)


def test_a_page_from_another_builder_is_placed() raises:
    var names: List[String] = ["a", "d"]
    var types: List[ParquetType] = [ParquetType.INT32, ParquetType.INT64]
    var nullable: List[Bool] = [False, False]
    var w = ParquetFileWriter.create(make_schema_elements_nullable(names^, types^, nullable^))
    w.write_batch[DType.int32](0, PrimitiveArray[DType.int32].from_list([5, 6, 7, 8]))
    var d = PrimitiveArray[DType.int64].from_list([100, 90, 95, 1000000000000])
    w.write_column_page(encode_dbp_column_page[DType.int64](1, d, "d"))
    var file = w.close_to_bytes()
    var md = _footer(file)
    var b = _read(file, md)
    assert_equal(Int(b.column_at(1).as_primitive[DType.int64]().get(3)), 1000000000000)
    assert_equal(Int(b.column_at(1).as_primitive[DType.int64]().get(1)), 90)
    var has_delta = False
    for e in md.row_groups[0].columns[1].meta_data.encodings:
        if e == Encoding.DELTA_BINARY_PACKED:
            has_delta = True
    assert_true(has_delta)


def test_empty_column_file() raises:
    var names: List[String] = ["a"]
    var types: List[ParquetType] = [ParquetType.INT32]
    var nullable: List[Bool] = [True]
    var w = ParquetFileWriter.create(make_schema_elements_nullable(names^, types^, nullable^))
    w.write_batch[DType.int32](0, PrimitiveArray[DType.int32].allocate(0))
    var file = w.close_to_bytes()
    var md = _footer(file)
    assert_equal(md.num_rows, 0)
    var b = _read(file, md)
    assert_equal(b.num_rows(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
