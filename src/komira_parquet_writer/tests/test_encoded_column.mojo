# EncodedColumn and the column-parallel assembly.
#
#   * test_encoded_column_matches_the_writers_page: header + body of
#     encode_column_to_buffer are, byte for byte, the page ParquetFileWriter
#     writes for the same column (the two paths must not drift), under
#     UNCOMPRESSED and SNAPPY; the sizes distinguish compressed from raw.
#   * test_parallel_assembly_decodes: columns encoded separately, put into
#     a file, decode through komira_parquet's reader with every value.
#   * test_parallel_assembly_is_the_writers_file: the assembled file is byte
#     for byte the one ParquetFileWriter produces.
#   * test_homogeneous_names_must_match: a name count that differs from the
#     column count is refused.
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.byte_view import ByteView
from komira_parquet.bytes_decode import (
    decode_row_group_from_bytes,
    row_group_byte_range,
)
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.morsel_reader import ColumnProjection
from komira_parquet_api.types import CompressionCodec, ParquetType
from komira_parquet_writer import (
    EncodedColumn,
    ParquetFileWriter,
    encode_column_to_buffer,
    make_schema_elements,
    write_batch_parallel_homogeneous,
    write_parquet_file_from_encoded,
)


def _view[
    mut: Bool, //, o: Origin[mut=mut]
](data: Span[UInt8, o]) -> ByteView[o]:
    return ByteView[o](data.unsafe_ptr(), len(data))


def _col(n: Int) raises -> PrimitiveArray[DType.int64]:
    var a = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        a.set(i, Int64((i % 17) * 1000))
    return a^


def test_encoded_column_matches_the_writers_page() raises:
    var names: List[String] = ["x"]
    var types: List[ParquetType] = [ParquetType.INT64]
    for codec in [CompressionCodec.UNCOMPRESSED, CompressionCodec.SNAPPY]:
        var enc = encode_column_to_buffer[DType.int64](0, _col(2000), "x", codec)
        var w = ParquetFileWriter.create(make_schema_elements(names.copy(), types.copy()), codec)
        w.write_batch[DType.int64](0, _col(2000))
        var page = w.column_pages[0].copy()
        var joined = List[UInt8]()
        joined.extend(enc.page_header_bytes.copy())
        joined.extend(enc.data_bytes.copy())
        assert_equal(len(joined), len(page.data))
        for i in range(len(joined)):
            assert_equal(Int(joined[i]), Int(page.data[i]), "byte " + String(i))
        assert_equal(enc.data_size, 2000 * 8)
        assert_equal(enc.compressed_size, len(enc.data_bytes))
        if codec == CompressionCodec.SNAPPY:
            assert_true(enc.compressed_size < enc.data_size)
        else:
            assert_equal(enc.compressed_size, enc.data_size)


def _two(codec: CompressionCodec) raises -> List[EncodedColumn]:
    var cols = List[EncodedColumn]()
    cols.append(encode_column_to_buffer[DType.int64](0, _col(300), "p", codec))
    cols.append(encode_column_to_buffer[DType.int64](1, _col(300), "q", codec))
    return cols^


def test_parallel_assembly_decodes() raises:
    var names: List[String] = ["p", "q"]
    var file = write_batch_parallel_homogeneous[DType.int64](names^, _two(CompressionCodec.SNAPPY))
    var n = len(file)
    var flen = 0
    for k in range(4):
        flen |= Int(file[n - 8 + k]) << (8 * k)
    var md = parse_full_metadata(_view(Span(file)[n - 8 - flen : n - 8]))
    ref rg = md.row_groups[0]
    var br = row_group_byte_range(rg)
    var b = decode_row_group_from_bytes(
        _view(Span(file)[br.start : br.end]),
        br,
        rg,
        md.schema,
        ColumnProjection.all(),
    )
    assert_equal(b.num_rows(), 300)
    for i in range(300):
        assert_equal(Int(b.column_at(0).as_primitive[DType.int64]().get(i)), (i % 17) * 1000)
        assert_equal(Int(b.column_at(1).as_primitive[DType.int64]().get(i)), (i % 17) * 1000)


def test_parallel_assembly_is_the_writers_file() raises:
    var names: List[String] = ["p", "q"]
    var types: List[ParquetType] = [ParquetType.INT64, ParquetType.INT64]
    var assembled = write_parquet_file_from_encoded(
        make_schema_elements(names.copy(), types.copy()), _two(CompressionCodec.UNCOMPRESSED)
    )
    var w = ParquetFileWriter.create(make_schema_elements(names^, types^))
    w.write_batch[DType.int64](0, _col(300))
    w.write_batch[DType.int64](1, _col(300))
    var direct = w.close_to_bytes()
    assert_equal(len(assembled), len(direct))
    for i in range(len(direct)):
        assert_equal(Int(assembled[i]), Int(direct[i]), "byte " + String(i))


def test_homogeneous_names_must_match() raises:
    var names: List[String] = ["only"]
    with assert_raises(contains="column_names length (1) != encoded_columns length (2)"):
        _ = write_batch_parallel_homogeneous[DType.int64](names^, _two(CompressionCodec.UNCOMPRESSED))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
