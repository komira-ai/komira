# =============================================================================
# read_raw_column_chunk.
#
# A file holds known bytes at known offsets; the footer metadata is built as
# structs. What each test proves:
#   * the chunk's bytes are returned exactly, from its first data page for
#     total_compressed_size bytes, with the sizes, type and codec copied
#     from its ColumnMetaData;
#   * a dictionary page before the first data page is where the chunk
#     starts; one after it is not;
#   * the column name is the leaf's: after a group in the schema, the
#     schema position named another element (the group's child);
#   * out-of-range indices, a negative offset and a range past the end of
#     the file are refused.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_runtime_paths import test_tmpdir
from komira_fs.local_fs import LocalFs
from komira_async.ops.waker_sink import NoopSink
from komira_parquet_api.metadata import (
    ColumnChunk,
    ColumnMetaData,
    FileMetaData,
    RowGroup,
    SchemaElement,
)
from komira_parquet_api.types import CompressionCodec, Encoding, ParquetType
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.bypass import read_raw_column_chunk

comptime _Fs = LocalFs[NoopSink]


def _write(name: String, body_len: Int) raises -> String:
    """PAR1, `body_len` bytes where byte i of the body is (i * 7 + 3) % 256,
    an 8-byte footer, its length and PAR1."""
    var out: List[UInt8] = [0x50, 0x41, 0x52, 0x31]
    for i in range(body_len):
        out.append(UInt8((i * 7 + 3) % 256))
    for _ in range(8):
        out.append(0x00)
    out.append(8)
    out.append(0)
    out.append(0)
    out.append(0)
    out.append(0x50)
    out.append(0x41)
    out.append(0x52)
    out.append(0x31)
    var path = test_tmpdir() + "/" + name
    var fh = open(path, "w")
    fh.write_bytes(Span(out))
    fh.close()
    return path^


def _body_byte(file_offset: Int) -> UInt8:
    return UInt8(((file_offset - 4) * 7 + 3) % 256)


def _chunk(data_off: Int, dict_off: Optional[Int], size: Int, t: ParquetType, codec: CompressionCodec) -> ColumnChunk:
    var meta = ColumnMetaData(
        type=t,
        encodings=List[Encoding](),
        path_in_schema=List[String](),
        codec=codec,
        num_values=17,
        total_uncompressed_size=size * 2,
        total_compressed_size=size,
        data_page_offset=data_off,
        dictionary_page_offset=dict_off,
    )
    return ColumnChunk(file_offset=0, meta_data=meta^)


def _md() -> FileMetaData:
    # schema: g { x }, a, b. Leaves (chunks): x, a, b.
    var schema: List[SchemaElement] = [
        SchemaElement(name="schema", num_children=3),
        SchemaElement(name="g", num_children=1),
        SchemaElement(name="x", type=ParquetType.INT32),
        SchemaElement(name="a", type=ParquetType.INT64),
        SchemaElement(name="b", type=ParquetType.BYTE_ARRAY),
    ]
    var columns: List[ColumnChunk] = [
        _chunk(10, None, 20, ParquetType.INT32, CompressionCodec.UNCOMPRESSED),
        # Dictionary page at 30, first data page at 50.
        _chunk(50, 30, 40, ParquetType.INT64, CompressionCodec.SNAPPY),
        # A dictionary offset after the data page does not move the start.
        _chunk(70, 90, 10, ParquetType.BYTE_ARRAY, CompressionCodec.ZSTD),
    ]
    var groups = List[RowGroup]()
    groups.append(RowGroup(columns=columns^, total_byte_size=0, num_rows=17))
    return FileMetaData(version=2, schema=schema^, num_rows=17, row_groups=groups^)


def test_reads_the_chunk_bytes_as_stored() raises:
    var path = _write("bypass_a.parquet", 120)
    var reader = ParquetFileReader[_Fs].open(path)
    var md = _md()
    var c = read_raw_column_chunk(reader, md, 0, 0)
    assert_equal(len(c.raw_bytes), 20)
    for i in range(20):
        assert_equal(c.raw_bytes[i], _body_byte(10 + i))
    assert_equal(c.column_index, 0)
    assert_equal(c.column_name, "x")
    assert_equal(c.num_values, 17)
    assert_equal(c.compressed_size, 20)
    assert_equal(c.uncompressed_size, 40)
    assert_true(c.parquet_type == ParquetType.INT32)
    assert_true(c.codec == CompressionCodec.UNCOMPRESSED)


def test_a_dictionary_page_first_is_the_start() raises:
    var path = _write("bypass_b.parquet", 120)
    var reader = ParquetFileReader[_Fs].open(path)
    var md = _md()
    var a = read_raw_column_chunk(reader, md, 0, 1)
    assert_equal(len(a.raw_bytes), 40)
    assert_equal(a.raw_bytes[0], _body_byte(30))
    assert_equal(a.raw_bytes[39], _body_byte(69))
    assert_equal(a.column_name, "a")
    assert_true(a.codec == CompressionCodec.SNAPPY)
    var b = read_raw_column_chunk(reader, md, 0, 2)
    assert_equal(b.raw_bytes[0], _body_byte(70))
    assert_equal(b.column_name, "b")


def test_refusals() raises:
    var path = _write("bypass_c.parquet", 50)
    var reader = ParquetFileReader[_Fs].open(path)
    var md = _md()
    with assert_raises(contains="rg_index 1 out of range"):
        _ = read_raw_column_chunk(reader, md, 1, 0)
    with assert_raises(contains="rg_index -1 out of range"):
        _ = read_raw_column_chunk(reader, md, -1, 0)
    with assert_raises(contains="col_index 3 out of range"):
        _ = read_raw_column_chunk(reader, md, 0, 3)
    # The file is 70 bytes: chunk 2 (bytes 70..80) runs past its end.
    with assert_raises(contains="out of bounds"):
        _ = read_raw_column_chunk(reader, md, 0, 2)
    md.row_groups[0].columns[0].meta_data.data_page_offset = -4
    with assert_raises(contains="offset -4"):
        _ = read_raw_column_chunk(reader, md, 0, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
