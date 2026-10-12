# `decode_column_pages` (column_decoder) on every column chunk of Parquet
# files pyarrow wrote: komira_parquet_codec's fixtures (its
# tests/fixtures/parquet, staged at parquet/; gen_pyarrow_fixtures.py there
# is their provenance and says what each holds). The footer is read with
# `parse_full_metadata`; each chunk's bytes run from its first page
# (dictionary_page_offset when there is one, else data_page_offset) for
# total_compressed_size bytes.
#
#   - pyarrow_page_crc_zstd_v2: ZSTD DATA_PAGE_V2 pages, every page with a
#     CRC-32; id INT64 == row (PLAIN, level bytes in front), label STRING
#     NULL when row % 7 == 0 else "k" + str(row % 13) (dictionary), 2 row
#     groups of 600. Also: one flipped byte in a page is refused by its CRC.
#   - pyarrow_multi_dict_page: SNAPPY, 6 row groups of 500, id INT64
#     0..2999 and label alpha..echo cycling, both dictionary-encoded over
#     several data pages; decoded flat, as dictionary columns, and with the
#     codes in one context buffer reused across the row groups.
#   - pyarrow_gzip_plain: GZIP PLAIN pages, id 1..5 and value 10.5..50.5.
#   - pyarrow_int96_ts: INT96 timestamps 0, one day and one second.
#   - pyarrow_zero_row: chunks with no page decode to empty columns.
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_buffer.byte_view import ByteView
from komira_buffer.heap_region import HeapRegion
from komira_parquet_api.metadata import FileMetaData
from komira_parquet_api.types import (
    CompressionCodec,
    FieldRepetitionType,
    ParquetType,
)

from komira_parquet.column_decode_context import ColumnDecodeContext
from komira_parquet.column_decoder import (
    NumericDictCodesHolder,
    decode_column_pages,
)
from komira_parquet.metadata_parser import parse_full_metadata

comptime _DIR = "parquet/"


struct _File(Movable):
    var bytes: List[UInt8]
    var meta: FileMetaData

    def __init__(out self, name: String) raises:
        self.bytes = Path(_DIR + name).read_bytes()
        var n = len(self.bytes)
        var flen = (
            Int(self.bytes[n - 8])
            | (Int(self.bytes[n - 7]) << 8)
            | (Int(self.bytes[n - 6]) << 16)
            | (Int(self.bytes[n - 5]) << 24)
        )
        var view = ByteView(self.bytes.unsafe_ptr() + (n - 8 - flen), flen)
        self.meta = parse_full_metadata(view)

    def chunk(self, rg: Int, col: Int) -> List[UInt8]:
        ref md = self.meta.row_groups[rg].columns[col].meta_data
        var start = md.data_page_offset
        if md.dictionary_page_offset:
            start = md.dictionary_page_offset.value()
        var out = List[UInt8](capacity=md.total_compressed_size)
        for i in range(start, start + md.total_compressed_size):
            out.append(self.bytes[i])
        return out^

    def decode(
        self,
        rg: Int,
        col: Int,
        mut ctx: ColumnDecodeContext,
        preserve_dict: Bool = True,
        bytes: Optional[List[UInt8]] = None,
    ) raises -> Column[HeapRegion]:
        ref md = self.meta.row_groups[rg].columns[col].meta_data
        ref leaf = self.meta.schema[col + 1]
        var nullable = Bool(leaf.repetition_type) and (
            leaf.repetition_type.value() == FieldRepetitionType.OPTIONAL
        )
        var ct = leaf.converted_type.value() if leaf.converted_type else -1
        var chunk = bytes.value().copy() if bytes else self.chunk(rg, col)
        var holder = NumericDictCodesHolder()
        return decode_column_pages(
            Span(chunk),
            md.type,
            md.codec,
            md.num_values,
            nullable,
            False,
            holder,
            ctx,
            0,
            ct,
            0,
            preserve_dict,
            0,
        )


def _dict_str(c: Column[HeapRegion], row: Int) raises -> String:
    var bv = c.string_dict_value_at(c.string_dict_code_at(row))
    var buf = List[UInt8](capacity=bv.len())
    for k in range(bv.len()):
        buf.append(bv.read_u8_at(k))
    return String(StringSlice(unsafe_from_utf8=Span(buf)))


def test_zstd_v2_pages_with_crcs_and_nulls() raises:
    var f = _File("pyarrow_page_crc_zstd_v2.parquet")
    assert_equal(len(f.meta.row_groups), 2)
    var ctx = ColumnDecodeContext()
    for rg in range(2):
        assert_true(
            f.meta.row_groups[rg].columns[0].meta_data.codec
            == CompressionCodec.ZSTD
        )
        var ids = f.decode(rg, 0, ctx)
        assert_equal(ids.length(), 600)
        assert_equal(ids.null_count(), 0)
        var a = ids.as_primitive[DType.int64]()
        for i in range(600):
            assert_equal(Int(a.get(i)), rg * 600 + i)
        var dense = f.decode(rg, 1, ctx, preserve_dict=False)
        var kept = f.decode(rg, 1, ctx)
        assert_true(kept.is_string_dict())
        assert_equal(dense.length(), 600)
        assert_equal(kept.length(), 600)
        var nulls = 0
        for i in range(600):
            var row = rg * 600 + i
            var is_null = row % 7 == 0
            assert_equal(dense.is_null_at(i), is_null, "row " + String(row))
            assert_equal(kept.is_null_at(i), is_null, "row " + String(row))
            if is_null:
                nulls += 1
            else:
                var want = "k" + String(row % 13)
                assert_equal(dense.utf8_value_at(i), want, "row " + String(row))
                assert_equal(_dict_str(kept, i), want, "row " + String(row))
        assert_equal(dense.null_count(), nulls)


def test_a_flipped_byte_in_a_real_page_fails_its_crc() raises:
    var f = _File("pyarrow_page_crc_zstd_v2.parquet")
    var ctx = ColumnDecodeContext()
    var chunk = f.chunk(0, 0)
    chunk[len(chunk) - 1] ^= UInt8(0x01)
    with assert_raises(contains="page CRC mismatch"):
        _ = f.decode(0, 0, ctx, bytes=chunk^)


def test_dictionary_chunks_over_several_pages() raises:
    var f = _File("pyarrow_multi_dict_page.parquet")
    assert_equal(len(f.meta.row_groups), 6)
    var labels: List[String] = ["alpha", "bravo", "charlie", "delta", "echo"]
    var flat_ctx = ColumnDecodeContext()
    var vec_ctx = ColumnDecodeContext(
        numeric_dict_vec_enabled=True, recycle_codes_enabled=True
    )
    for rg in range(6):
        var flat = f.decode(rg, 0, flat_ctx)
        var vec = f.decode(rg, 0, vec_ctx)
        assert_true(vec.is_numeric_dict())
        assert_equal(flat.length(), 500)
        assert_equal(vec.length(), 500)
        var a = flat.as_primitive[DType.int64]()
        for i in range(500):
            assert_equal(Int(a.get(i)), rg * 500 + i)
            assert_equal(Int(vec.dict_value_i64(vec.dict_code_at(i))), rg * 500 + i)
        var dense = f.decode(rg, 1, flat_ctx, preserve_dict=False)
        assert_equal(dense.length(), 500)
        for i in range(500):
            assert_equal(dense.utf8_value_at(i), labels[(rg * 500 + i) % 5])


def test_gzip_plain_pages() raises:
    var f = _File("pyarrow_gzip_plain.parquet")
    var ctx = ColumnDecodeContext()
    var ids = f.decode(0, 0, ctx).as_primitive[DType.int64]()
    var vals = f.decode(0, 1, ctx).as_primitive[DType.float64]()
    for i in range(5):
        assert_equal(Int(ids.get(i)), i + 1)
        assert_equal(vals.get(i), Float64(10.5 + 10.0 * Float64(i)))


def test_int96_timestamps() raises:
    var f = _File("pyarrow_int96_ts.parquet")
    var ctx = ColumnDecodeContext()
    var c = f.decode(0, 0, ctx)
    assert_true(c.arrow_type == ArrowType.INT64)
    var a = c.as_primitive[DType.int64]()
    var want: List[Int] = [0, 86400 * 1000000000, 1000000000]
    for i in range(3):
        assert_equal(Int(a.get(i)), want[i])


def test_zero_row_chunks() raises:
    var f = _File("pyarrow_zero_row.parquet")
    var ctx = ColumnDecodeContext()
    for col in range(2):
        assert_equal(f.decode(0, col, ctx).length(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
