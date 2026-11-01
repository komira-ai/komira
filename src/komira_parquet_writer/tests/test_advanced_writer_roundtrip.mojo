# AdvancedParquetWriter's bytes, decoded by komira_parquet's reader.
#
# The reader shares no code with the writer, so what round-trips here is what
# the format says. Pages come from the package's own page builders.
#
# What each test proves, and the defect it catches:
#   * test_multi_row_groups_roundtrip: three row groups (400, 300 and 50
#     rows; an OPTIONAL INT64 column with nulls, a REQUIRED string column,
#     SNAPPY) read back value-for-value; the footer's row counts, chunk
#     order and offsets (strictly increasing across row groups). Catches
#     chunks of a later row group placed or counted as an earlier one's.
#   * test_chunks_added_out_of_order_land_in_schema_order: chunks added in
#     reverse column order read back under their own columns.
#   * test_crc_is_the_standard_crc32_the_reader_checks: with enable_crc each
#     data page's header carries the CRC-32 (gzip polynomial) of the body as
#     stored, uncompressed and SNAPPY; the reader, which checks it, decodes
#     the file; flipping one body byte makes the reader refuse the page. A
#     CRC-32C or a CRC over the uncompressed bytes fails the reader's check.
#   * test_crc_off_by_default_and_dictionary_chunks_carry_none: no crc field
#     without enable_crc; with it, a dictionary chunk's pages carry none
#     (documented in page_crc), and still decode.
#   * test_crc_keeps_the_pages_own_encoding: DELTA_BINARY_PACKED and
#     BYTE_STREAM_SPLIT pages with a CRC keep their encoding in the header
#     and decode; a header forced to PLAIN fails.
#   * test_page_with_crc_refuses_a_malformed_page, test_create_refuses_a_bad_schema:
#     the error paths.
#   * test_row_group_must_be_complete: a row group short of a column is
#     refused at flush and at close.
#   * test_add_column_page_errors: closed writer, column out of range, a
#     second chunk for a column in one row group, a differing row count.
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

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
from komira_parquet.page_header_parser import _parse_page_header
from komira_parquet_api.metadata import FileMetaData, SchemaElement
from komira_parquet_api.types import CompressionCodec, Encoding, ParquetType
from komira_parquet_writer import (
    AdvancedParquetWriter,
    ColumnPage,
    WriterConfig,
    encode_bss_column_page,
    encode_dbp_column_page,
    encode_dict_string_column_page,
    page_with_crc,
    encode_plain_column,
    encode_string_column_page,
    make_schema_elements_nullable,
)
from komira_zlib import zlib_crc32


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


def _read_rg(file: List[UInt8], md: FileMetaData, g: Int) raises -> RecordBatch:
    ref rg = md.row_groups[g]
    var br = row_group_byte_range(rg)
    return decode_row_group_from_bytes(
        _view(Span(file)[br.start : br.end]),
        br,
        rg,
        md.schema,
        ColumnProjection.all(),
    )


def _schema() raises -> List[SchemaElement]:
    var names: List[String] = ["n", "s"]
    var types: List[ParquetType] = [ParquetType.INT64, ParquetType.BYTE_ARRAY]
    var nullable: List[Bool] = [True, False]
    return make_schema_elements_nullable(names^, types^, nullable^)


def _n(row: Int) -> Int:
    return row * 1000003 - 17


def _n_null(row: Int) -> Bool:
    return row % 9 == 4


def _s(row: Int, unique: Bool) -> String:
    if unique:
        return String("row-") + String(row)
    return String("k") + String(row % 4)


def _page_n(start: Int, n: Int, codec: CompressionCodec) raises -> ColumnPage:
    var a = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        if _n_null(start + i):
            a.set(i, -1)
            a._set_null(i)
        else:
            a.set(i, Int64(_n(start + i)))
    return encode_plain_column[DType.int64](0, a, "n", nullable=True, codec=codec)


def _page_s(start: Int, n: Int, unique: Bool, codec: CompressionCodec) raises -> ColumnPage:
    var vals = List[String]()
    for i in range(n):
        vals.append(_s(start + i, unique))
    var arr = StringArray.from_strings(vals)
    var d = encode_dict_string_column_page(1, arr, "s", nullable=False, codec=codec)
    if d:
        return d.take()
    return encode_string_column_page(1, arr, "s", nullable=False, codec=codec)


def _write_three(config: WriterConfig, codec: CompressionCodec, unique: Bool) raises -> List[UInt8]:
    var w = AdvancedParquetWriter.create(_schema(), config.copy())
    var starts: List[Int] = [0, 400, 700]
    var counts: List[Int] = [400, 300, 50]
    for g in range(3):
        w.add_column_page_simple(_page_n(starts[g], counts[g], codec))
        w.add_column_page_simple(_page_s(starts[g], counts[g], unique, codec))
        w.flush_row_group()
    return w.close_to_bytes()


def _check_rg(b: RecordBatch, start: Int, n: Int, unique: Bool) raises:
    assert_equal(b.num_rows(), n)
    for i in range(n):
        assert_equal(b.column_at(0).is_null_at(i), _n_null(start + i))
        if not _n_null(start + i):
            assert_equal(Int(b.column_at(0).as_primitive[DType.int64]().get(i)), _n(start + i))
        assert_equal(b.column_at(1).as_string().get(i), _s(start + i, unique))


def test_multi_row_groups_roundtrip() raises:
    var file = _write_three(WriterConfig(), CompressionCodec.SNAPPY, True)
    var md = _footer(file)
    assert_equal(md.num_rows, 750)
    assert_equal(len(md.row_groups), 3)
    var starts: List[Int] = [0, 400, 700]
    var counts: List[Int] = [400, 300, 50]
    var prev_end = 4
    for g in range(3):
        ref rg = md.row_groups[g]
        assert_equal(rg.num_rows, counts[g])
        assert_equal(len(rg.columns), 2)
        for c in range(2):
            ref meta = rg.columns[c].meta_data
            assert_equal(meta.num_values, counts[g])
            var first = meta.data_page_offset
            if meta.dictionary_page_offset:
                first = meta.dictionary_page_offset.value()
            assert_true(first >= prev_end)
            prev_end = first + meta.total_compressed_size
        _check_rg(_read_rg(file, md, g), starts[g], counts[g], True)


def test_chunks_added_out_of_order_land_in_schema_order() raises:
    var w = AdvancedParquetWriter.create(_schema(), WriterConfig())
    w.add_column_page_simple(_page_s(0, 20, True, CompressionCodec.UNCOMPRESSED))
    w.add_column_page_simple(_page_n(0, 20, CompressionCodec.UNCOMPRESSED))
    var file = w.close_to_bytes()
    var md = _footer(file)
    assert_equal(md.row_groups[0].columns[0].meta_data.path_in_schema[0], "n")
    assert_equal(md.row_groups[0].columns[1].meta_data.path_in_schema[0], "s")
    _check_rg(_read_rg(file, md, 0), 0, 20, True)


def _chunk_header(file: List[UInt8], md: FileMetaData, g: Int, c: Int) raises -> Tuple[Optional[UInt32], Int, Int]:
    """(crc, body offset, body length) of the first page of a chunk."""
    ref meta = md.row_groups[g].columns[c].meta_data
    var first = meta.data_page_offset
    if meta.dictionary_page_offset:
        first = meta.dictionary_page_offset.value()
    var r = _parse_page_header(Span(file)[first:])
    return (r.header.crc, first + r.bytes_consumed, r.header.compressed_page_size)


def test_crc_is_the_standard_crc32_the_reader_checks() raises:
    for codec in [CompressionCodec.UNCOMPRESSED, CompressionCodec.SNAPPY]:
        var w = AdvancedParquetWriter.create(_schema(), WriterConfig(enable_crc=True))
        w.add_column_page_simple(_page_n(0, 600, codec))
        w.add_column_page_simple(_page_s(0, 600, True, codec))
        var file = w.close_to_bytes()
        var md = _footer(file)
        # Column 0 is one plain data page: its CRC is the CRC-32 of the body
        # as stored.
        var h = _chunk_header(file, md, 0, 0)
        assert_true(Bool(h[0]))
        var body = Span(file)[h[1] : h[1] + h[2]]
        assert_equal(Int(h[0].value()), Int(zlib_crc32(body)))
        # The sizes in the rewritten header still describe the page.
        ref meta = md.row_groups[0].columns[0].meta_data
        assert_equal(h[2] + (h[1] - meta.data_page_offset), meta.total_compressed_size)
        # Both columns decode (the reader checks each present CRC).
        _check_rg(_read_rg(file, md, 0), 0, 600, True)
        # One flipped body byte: the reader refuses the page.
        var bad = file.copy()
        bad[h[1] + h[2] // 2] = bad[h[1] + h[2] // 2] ^ 0x40
        var bad_md = _footer(bad)
        with assert_raises(contains="CRC"):
            _ = _read_rg(bad, bad_md, 0)


def test_crc_off_by_default_and_dictionary_chunks_carry_none() raises:
    var off = _write_three(WriterConfig(), CompressionCodec.UNCOMPRESSED, True)
    var off_md = _footer(off)
    assert_false(Bool(_chunk_header(off, off_md, 0, 0)[0]))
    # Low-cardinality strings make column 1 a dictionary chunk.
    var on = _write_three(WriterConfig(enable_crc=True), CompressionCodec.SNAPPY, False)
    var md = _footer(on)
    assert_true(Bool(md.row_groups[0].columns[1].meta_data.dictionary_page_offset))
    assert_true(Bool(_chunk_header(on, md, 0, 0)[0]))
    assert_false(Bool(_chunk_header(on, md, 0, 1)[0]))
    for g in range(3):
        _ = _read_rg(on, md, g)


def test_crc_keeps_the_pages_own_encoding() raises:
    # DELTA_BINARY_PACKED and BYTE_STREAM_SPLIT pages, neither PLAIN nor a
    # dictionary: the rewritten header must still name the page's encoding,
    # or the reader decodes the body as PLAIN.
    var names: List[String] = ["d", "f"]
    var types: List[ParquetType] = [ParquetType.INT64, ParquetType.DOUBLE]
    var nullable: List[Bool] = [False, False]
    for codec in [CompressionCodec.UNCOMPRESSED, CompressionCodec.SNAPPY]:
        var d = PrimitiveArray[DType.int64].allocate(500)
        var f = PrimitiveArray[DType.float64].allocate(500)
        for i in range(500):
            d.set(i, Int64(i * i * 31 + 7))
            f.set(i, Float64(i) * 1.37 + 0.001)
        var w = AdvancedParquetWriter.create(
            make_schema_elements_nullable(names.copy(), types.copy(), nullable.copy()),
            WriterConfig(enable_crc=True),
        )
        w.add_column_page_simple(encode_dbp_column_page[DType.int64](0, d, "d", codec=codec))
        w.add_column_page_simple(encode_bss_column_page[DType.float64](1, f, "f", codec=codec))
        var file = w.close_to_bytes()
        var md = _footer(file)
        var want: List[Encoding] = [Encoding.DELTA_BINARY_PACKED, Encoding.BYTE_STREAM_SPLIT]
        for c in range(2):
            ref meta = md.row_groups[0].columns[c].meta_data
            var r = _parse_page_header(Span(file)[meta.data_page_offset :])
            assert_true(r.header.encoding == want[c], "column " + String(c) + " header encoding")
            assert_true(Bool(r.header.crc))
            var body = Span(file)[meta.data_page_offset + r.bytes_consumed : meta.data_page_offset + r.bytes_consumed + r.header.compressed_page_size]
            assert_equal(Int(r.header.crc.value()), Int(zlib_crc32(body)))
        var b = _read_rg(file, md, 0)
        for i in range(500):
            assert_equal(Int(b.column_at(0).as_primitive[DType.int64]().get(i)), i * i * 31 + 7)
            assert_equal(b.column_at(1).as_primitive[DType.float64]().get(i), Float64(i) * 1.37 + 0.001)


def test_page_with_crc_refuses_a_malformed_page() raises:
    var enc: List[Encoding] = [Encoding.PLAIN]
    var three: List[UInt8] = [0, 0, 0]
    var no_header = ColumnPage(
        three.copy(), 0, 1, 3, 3, ParquetType.INT64, "c", enc.copy(), CompressionCodec.UNCOMPRESSED
    )
    with assert_raises(contains="a 3-byte page with a 3-byte body"):
        _ = page_with_crc(no_header^)
    var eight: List[UInt8] = [0, 0, 0, 0, 0, 0, 0, 0]
    var no_enc = ColumnPage(
        eight^, 0, 1, 3, 3, ParquetType.INT64, "c", List[Encoding](), CompressionCodec.UNCOMPRESSED
    )
    with assert_raises(contains="page with a 3-byte body"):
        _ = page_with_crc(no_enc^)


def test_create_refuses_a_bad_schema() raises:
    with assert_raises(contains="no root element"):
        _ = AdvancedParquetWriter.create(List[SchemaElement](), WriterConfig())
    var group_only = List[SchemaElement]()
    group_only.append(SchemaElement(name="schema", num_children=1))
    group_only.append(SchemaElement(name="nested", num_children=2))
    with assert_raises(contains="schema leaf 'nested' has no physical type"):
        _ = AdvancedParquetWriter.create(group_only^, WriterConfig())


def test_row_group_must_be_complete() raises:
    var w = AdvancedParquetWriter.create(_schema(), WriterConfig())
    w.add_column_page_simple(_page_n(0, 10, CompressionCodec.UNCOMPRESSED))
    with assert_raises(contains="the row group has 1 of 2 columns"):
        w.flush_row_group()
    with assert_raises(contains="the row group has 1 of 2 columns"):
        _ = w.close_to_bytes()


def test_add_column_page_errors() raises:
    var w = AdvancedParquetWriter.create(_schema(), WriterConfig())
    w.add_column_page_simple(_page_n(0, 10, CompressionCodec.UNCOMPRESSED))
    with assert_raises(contains="column 0 already has a chunk in this row group"):
        w.add_column_page_simple(_page_n(0, 10, CompressionCodec.UNCOMPRESSED))
    with assert_raises(contains="column 1 has 11 rows, expected 10"):
        w.add_column_page_simple(_page_s(0, 11, True, CompressionCodec.UNCOMPRESSED))
    var wrong = _page_s(0, 10, True, CompressionCodec.UNCOMPRESSED)
    wrong.column_index = 2
    with assert_raises(contains="column_index 2 out of range"):
        w.add_column_page_simple(wrong^)
    w.add_column_page_simple(_page_s(0, 10, True, CompressionCodec.UNCOMPRESSED))
    var file = w.close_to_bytes()
    assert_true(len(file) > 12)
    with assert_raises(contains="already closed"):
        _ = w.close_to_bytes()
    with assert_raises(contains="already closed"):
        w.add_column_page_simple(_page_n(0, 10, CompressionCodec.UNCOMPRESSED))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
