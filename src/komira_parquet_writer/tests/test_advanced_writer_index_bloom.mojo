# The page index and bloom filters of AdvancedParquetWriter, read back from
# the file's bytes.
#
# The ColumnIndex and OffsetIndex blobs are decoded by a Thrift compact
# decoder written in this file from parquet.thrift (not from the writer), and
# the page locations are checked against page headers the reader's parser
# decodes. Bloom filters are read through komira_parquet's header parser and
# probed through komira_dynamic_filter.
#
#   * test_offset_index_locates_the_data_page: per chunk, the OffsetIndex has
#     one location whose offset is a DATA_PAGE header and whose size ends at
#     the chunk's end, for a plain chunk and for a dictionary chunk (where it
#     must skip the dictionary page: parquet.thrift's index describes data
#     pages only). Catches a location pointing at the chunk start.
#   * test_column_index_carries_the_page_range: min, max, null_count and the
#     null-page flag from the page statistics; an all-null chunk is a null
#     page.
#   * test_a_chunk_without_a_range_gets_an_offset_index_only: min/max empty
#     and not all-null -> no ColumnIndex for that column (an empty min/max
#     would read as a real range), the OffsetIndex is still written.
#   * test_page_index_off: no index offsets in the footer.
#   * test_bloom_filter_is_written_and_probes: bloom_filter_offset/length in
#     the footer, a header with SPLIT_BLOCK, XXHASH, UNCOMPRESSED and the
#     bitset size, a bitset equal to the filter's, and a filter loaded back
#     from the file's bytes has no false negative over the inserted values
#     and rejects a value that was never inserted.
#   * test_bloom_filter_errors: disabled, out of range, repeated, a filter of
#     another hash family.
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.byte_view import ByteView
from komira_dynamic_filter.bloom_filter import BloomFilter, HashFamily
from komira_parquet.bloom_reader import parse_bloom_filter_header
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.page_header_parser import _parse_page_header
from komira_parquet.thrift_compact import ThriftCompactReader
from komira_parquet_api.metadata import FileMetaData, SchemaElement
from komira_parquet_api.types import CompressionCodec, PageType, ParquetType
from komira_parquet_writer import (
    AdvancedParquetWriter,
    ColumnPage,
    WriterConfig,
    encode_dict_string_column_page,
    encode_plain_column,
    make_schema_elements_nullable,
)
from komira_arrow.string_array import StringArray


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


# --- a Thrift compact decoder for the two index structs ---------------------


struct _Cur(Movable):
    var b: List[UInt8]
    var pos: Int

    def __init__(out self, var b: List[UInt8]):
        self.b = b^
        self.pos = 0

    def byte(mut self) raises -> Int:
        if self.pos >= len(self.b):
            raise Error("index blob ends early")
        var v = Int(self.b[self.pos])
        self.pos += 1
        return v

    def uvar(mut self) raises -> Int:
        var shift = 0
        var v = 0
        while True:
            var x = self.byte()
            v |= (x & 0x7F) << shift
            if x & 0x80 == 0:
                return v
            shift += 7

    def zig(mut self) raises -> Int:
        var u = self.uvar()
        return (u >> 1) ^ -(u & 1)

    def list_header(mut self) raises -> Tuple[Int, Int]:
        var h = self.byte()
        var n = h >> 4
        if n == 15:
            n = self.uvar()
        return (n, h & 0xF)

    def binary(mut self) raises -> List[UInt8]:
        var n = self.uvar()
        var out = List[UInt8]()
        for _ in range(n):
            out.append(UInt8(self.byte()))
        return out^


struct _ColumnIndex(Movable):
    var null_pages: List[Bool]
    var mins: List[List[UInt8]]
    var maxs: List[List[UInt8]]
    var boundary_order: Int
    var null_counts: List[Int]

    def __init__(out self):
        self.null_pages = List[Bool]()
        self.mins = List[List[UInt8]]()
        self.maxs = List[List[UInt8]]()
        self.boundary_order = -1
        self.null_counts = List[Int]()


def _read_column_index(blob: List[UInt8]) raises -> _ColumnIndex:
    var c = _Cur(blob.copy())
    var out = _ColumnIndex()
    var field = 0
    while True:
        var h = c.byte()
        if h == 0:
            break
        var delta = h >> 4
        field = field + delta if delta != 0 else c.zig()
        if field == 1:
            var lh = c.list_header()
            for _ in range(lh[0]):
                out.null_pages.append(c.byte() == 1)
        elif field == 2 or field == 3:
            var lh = c.list_header()
            for _ in range(lh[0]):
                if field == 2:
                    out.mins.append(c.binary())
                else:
                    out.maxs.append(c.binary())
        elif field == 4:
            out.boundary_order = c.zig()
        elif field == 5:
            var lh = c.list_header()
            for _ in range(lh[0]):
                out.null_counts.append(c.zig())
        else:
            raise Error("unexpected ColumnIndex field " + String(field))
    return out^


def _read_offset_index(blob: List[UInt8]) raises -> List[Tuple[Int, Int, Int]]:
    """(offset, compressed_page_size, first_row_index) per page location."""
    var c = _Cur(blob.copy())
    var out = List[Tuple[Int, Int, Int]]()
    var h = c.byte()
    if (h >> 4) != 1:
        raise Error("OffsetIndex does not start with field 1")
    var lh = c.list_header()
    for _ in range(lh[0]):
        var off = 0
        var size = 0
        var row = 0
        var field = 0
        while True:
            var fh = c.byte()
            if fh == 0:
                break
            var delta = fh >> 4
            field = field + delta if delta != 0 else c.zig()
            if field == 1:
                off = c.zig()
            elif field == 2:
                size = c.zig()
            elif field == 3:
                row = c.zig()
            else:
                raise Error("unexpected PageLocation field")
        out.append((off, size, row))
    return out^


def _blob(file: List[UInt8], offset: Int, length: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(length):
        out.append(file[offset + i])
    return out^


# --- fixtures ---------------------------------------------------------------


def _schema() raises -> List[SchemaElement]:
    var names: List[String] = ["n", "s", "z"]
    var types: List[ParquetType] = [ParquetType.INT64, ParquetType.BYTE_ARRAY, ParquetType.INT32]
    var nullable: List[Bool] = [True, False, True]
    return make_schema_elements_nullable(names^, types^, nullable^)


def _page_n(n: Int) raises -> ColumnPage:
    var a = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        if i % 5 == 3:
            a.set(i, -999)
            a._set_null(i)
        else:
            a.set(i, Int64(1000 + i * 7))
    return encode_plain_column[DType.int64](0, a, "n", nullable=True)


def _page_s(n: Int) raises -> ColumnPage:
    var vals = List[String]()
    for i in range(n):
        vals.append(String("k") + String(i % 3))
    var d = encode_dict_string_column_page(1, StringArray.from_strings(vals), "s", nullable=False)
    return d.take()


def _page_z_all_null(n: Int) raises -> ColumnPage:
    var a = PrimitiveArray[DType.int32].allocate_nullable(n)
    for i in range(n):
        a.set(i, 5)
        a._set_null(i)
    return encode_plain_column[DType.int32](2, a, "z", nullable=True)


def _write(config: WriterConfig) raises -> List[UInt8]:
    var w = AdvancedParquetWriter.create(_schema(), config.copy())
    w.add_column_page_simple(_page_n(100))
    w.add_column_page_simple(_page_s(100))
    w.add_column_page_simple(_page_z_all_null(100))
    return w.close_to_bytes()


def _le(b: List[UInt8]) -> Int:
    var v = 0
    for i in range(len(b)):
        v |= Int(b[i]) << (8 * i)
    return v


def test_offset_index_locates_the_data_page() raises:
    var file = _write(WriterConfig())
    var md = _footer(file)
    for c in range(3):
        ref chunk = md.row_groups[0].columns[c]
        assert_true(Bool(chunk.offset_index_offset))
        var locs = _read_offset_index(
            _blob(file, chunk.offset_index_offset.value(), chunk.offset_index_length.value())
        )
        assert_equal(len(locs), 1)
        var off = locs[0][0]
        var h = _parse_page_header(Span(file)[off:])
        assert_true(h.header.type == PageType.DATA_PAGE, "column " + String(c) + " location is a data page")
        var chunk_start = chunk.meta_data.data_page_offset
        if chunk.meta_data.dictionary_page_offset:
            chunk_start = chunk.meta_data.dictionary_page_offset.value()
            assert_true(off > chunk_start, "a dictionary chunk's location skips the dictionary page")
        assert_equal(off + locs[0][1], chunk_start + chunk.meta_data.total_compressed_size)
        assert_equal(locs[0][2], 0)
    assert_true(Bool(md.row_groups[0].columns[1].meta_data.dictionary_page_offset))


def test_column_index_carries_the_page_range() raises:
    var file = _write(WriterConfig())
    var md = _footer(file)
    ref c0 = md.row_groups[0].columns[0]
    var ci = _read_column_index(_blob(file, c0.column_index_offset.value(), c0.column_index_length.value()))
    assert_equal(len(ci.null_pages), 1)
    assert_false(ci.null_pages[0])
    assert_equal(_le(ci.mins[0]), 1000)
    # Rows 0..99 minus i % 5 == 3: the last valid row is 99 -> 1000 + 99 * 7.
    assert_equal(_le(ci.maxs[0]), 1000 + 99 * 7)
    assert_equal(ci.null_counts[0], 20)
    # The all-null INT32 column is a null page with no bounds.
    ref c2 = md.row_groups[0].columns[2]
    var ci2 = _read_column_index(_blob(file, c2.column_index_offset.value(), c2.column_index_length.value()))
    assert_true(ci2.null_pages[0])
    assert_equal(ci2.null_counts[0], 100)
    assert_equal(len(ci2.mins[0]), 0)
    assert_equal(len(ci2.maxs[0]), 0)


def test_a_chunk_without_a_range_gets_an_offset_index_only() raises:
    var w = AdvancedParquetWriter.create(_schema(), WriterConfig())
    var empty_min = List[UInt8]()
    var empty_max = List[UInt8]()
    w.add_column_page(_page_n(100), empty_min^, empty_max^, null_count=20)
    w.add_column_page_simple(_page_s(100))
    w.add_column_page_simple(_page_z_all_null(100))
    var md = _footer(w.close_to_bytes())
    ref c0 = md.row_groups[0].columns[0]
    assert_false(Bool(c0.column_index_offset))
    assert_true(Bool(c0.offset_index_offset))
    # The dictionary string chunk carries no statistics either (the encoder
    # computes none), so it too has an OffsetIndex and no ColumnIndex.
    ref c1 = md.row_groups[0].columns[1]
    assert_false(Bool(c1.column_index_offset))
    assert_true(Bool(c1.offset_index_offset))
    # The all-null chunk has statistics (a null count) and so a ColumnIndex.
    assert_true(Bool(md.row_groups[0].columns[2].column_index_offset))


def test_page_index_off() raises:
    var md = _footer(_write(WriterConfig(enable_page_index=False)))
    for c in range(3):
        ref chunk = md.row_groups[0].columns[c]
        assert_false(Bool(chunk.column_index_offset))
        assert_false(Bool(chunk.offset_index_offset))


def test_bloom_filter_is_written_and_probes() raises:
    var bf = BloomFilter.with_ndv_fpp(200, 0.01)
    for i in range(100):
        bf.insert_int64(Int64(1000 + i * 7))
    var expect_bits = List[UInt8]()
    bf.data.view_range_ro(0, bf.num_bytes).copy_to(expect_bits, 0, bf.num_bytes)
    var nbytes = bf.num_bytes
    var w = AdvancedParquetWriter.create(_schema(), WriterConfig(enable_bloom_filters=True))
    w.add_column_page_simple(_page_n(100))
    w.add_column_page_simple(_page_s(100))
    w.add_column_page_simple(_page_z_all_null(100))
    w.set_bloom_filter(0, bf^)
    var file = w.close_to_bytes()
    var md = _footer(file)
    ref meta = md.row_groups[0].columns[0].meta_data
    assert_true(Bool(meta.bloom_filter_offset))
    assert_false(Bool(md.row_groups[0].columns[1].meta_data.bloom_filter_offset))
    var off = meta.bloom_filter_offset.value()
    var reader = ThriftCompactReader(_view(Span(file)[off : off + meta.bloom_filter_length.value()]))
    var info = parse_bloom_filter_header(reader)
    assert_true(info.algorithm_ok and info.hash_ok and info.compression_ok)
    assert_equal(info.num_bytes, nbytes)
    assert_equal(info.header_byte_length + info.num_bytes, meta.bloom_filter_length.value())
    var bits_at = off + info.header_byte_length
    for i in range(nbytes):
        assert_equal(Int(file[bits_at + i]), Int(expect_bits[i]), "bitset byte " + String(i))
    var loaded = BloomFilter.from_bytes(Span(file)[bits_at:].unsafe_ptr(), nbytes)
    for i in range(100):
        assert_true(loaded.might_contain_int64(Int64(1000 + i * 7)), "no false negative at " + String(i))
    var absent = 0
    for i in range(100):
        if not loaded.might_contain_int64(Int64(500000 + i)):
            absent += 1
    assert_true(absent > 90, "a filter at 1% fpp rejects almost every value it never saw")


def test_bloom_filter_errors() raises:
    var off = AdvancedParquetWriter.create(_schema(), WriterConfig())
    with assert_raises(contains="needs WriterConfig(enable_bloom_filters=True)"):
        off.set_bloom_filter(0, BloomFilter.create(64))
    var w = AdvancedParquetWriter.create(_schema(), WriterConfig(enable_bloom_filters=True))
    with assert_raises(contains="column_index 3 out of range"):
        w.set_bloom_filter(3, BloomFilter.create(64))
    w.set_bloom_filter(0, BloomFilter.create(64))
    with assert_raises(contains="column 0 already has a bloom filter"):
        w.set_bloom_filter(0, BloomFilter.create(64))
    with assert_raises(contains="declares XXHASH"):
        w.set_bloom_filter(1, BloomFilter.create(64, HashFamily.fnv1a()))
    # An incomplete row group is refused at close, whatever was set on it.
    w.add_column_page_simple(_page_n(10))
    with assert_raises(contains="the row group has 1 of 3 columns"):
        _ = w.close_to_bytes()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
