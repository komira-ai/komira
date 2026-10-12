# The I/O-free decode entry points (bytes_decode) on files written by
# komira_test_parquet_file, decoding out of the file's own bytes:
#   - row_group_byte_range is exactly the row group's chunks (no byte
#     short, none extra), and (0, 0) for a row group of no columns;
#   - decode_row_group_from_bytes / decode_row_group_columns_subset: every
#     value of every row group against the rows written, in projection
#     order, a kept dictionary, and one census count per chunk decoded;
#   - decode_column_chunk_from_bytes out of a view of the whole file;
#   - decode_numeric_dict_codes_from_bytes: the codes of an INT64 and of a
#     nullable INT32 dictionary chunk map back to the rows' values; PLAIN
#     and BYTE_ARRAY chunks get None;
#   - the refusals: a view and range of different lengths, a chunk one byte
#     outside the range, an index that is not a leaf.

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch
from komira_buffer.byte_view import ByteView
from komira_buffer.heap_region import HeapRegion
from komira_counters.parquet_read_counter import parquet_column_chunks_decoded
from komira_parquet.bytes_decode import (
    ByteRange,
    decode_column_chunk_from_bytes,
    decode_numeric_dict_codes_from_bytes,
    decode_row_group_columns_subset,
    decode_row_group_from_bytes,
    row_group_byte_range,
)
from komira_parquet.column_decode_context import ColumnDecodeContext
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.morsel_reader import ColumnProjection
from komira_parquet_api.metadata import ColumnChunk, FileMetaData, RowGroup
from komira_test_parquet_file import TestColumn, TestFileLayout, parquet_file_bytes

comptime _ROWS = 90


# a: INT64 REQUIRED; b: INT32 OPTIONAL; d: UTF8 dictionary; n: INT64
# dictionary; m: INT32 dictionary OPTIONAL.
def _a(r: Int) -> Int:
    return 1000 - r * 3


def _b_null(r: Int) -> Bool:
    return r % 6 == 1


def _b(r: Int) -> Int:
    return r * 7


def _d(r: Int) -> String:
    return "d" + String(r % 5)


def _n(r: Int) -> Int:
    return (r % 3) * 1_000_000_007


def _m_null(r: Int) -> Bool:
    return r % 4 == 0


def _m(r: Int) -> Int:
    return -(r % 6)


def _file() raises -> List[UInt8]:
    var a = List[Int]()
    var b = List[Int]()
    var bn = List[Bool]()
    var d = List[String]()
    var n = List[Int]()
    var m = List[Int]()
    var mn = List[Bool]()
    for r in range(_ROWS):
        a.append(_a(r))
        b.append(_b(r))
        bn.append(_b_null(r))
        d.append(_d(r))
        n.append(_n(r))
        m.append(_m(r))
        mn.append(_m_null(r))
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("a", a^))
    cols.append(TestColumn.int32("b", b^).with_nulls(bn^))
    cols.append(TestColumn.string("d", d^).dict_encoded())
    cols.append(TestColumn.int64("n", n^).dict_encoded())
    cols.append(TestColumn.int32("m", m^).with_nulls(mn^).dict_encoded())
    return parquet_file_bytes(cols, TestFileLayout([50, 40], 12, False))


def _view[
    mut: Bool, //, o: Origin[mut=mut]
](data: Span[UInt8, o]) -> ByteView[o]:
    return ByteView[o](data.unsafe_ptr(), len(data))


def _footer(file: List[UInt8]) raises -> FileMetaData:
    var n = len(file)
    var flen = 0
    for k in range(4):
        flen |= Int(file[n - 8 + k]) << (8 * k)
    var start = n - 8 - flen
    return parse_full_metadata(_view(Span(file)[start : n - 8]))


def _rg_first(rg: Int) -> Int:
    return 0 if rg == 0 else 50


def _dict_str(c: Column[HeapRegion], row: Int) raises -> String:
    var bv = c.string_dict_value_at(c.string_dict_code_at(row))
    var buf = List[UInt8](capacity=bv.len())
    for k in range(bv.len()):
        buf.append(bv.read_u8_at(k))
    return String(StringSlice(unsafe_from_utf8=Span(buf)))


def _check_col(c: Column[HeapRegion], col: Int, first: Int, n: Int) raises:
    assert_equal(c.length(), n)
    for i in range(n):
        var r = first + i
        var where = "col " + String(col) + " row " + String(r)
        if col == 0:
            assert_equal(Int(c.as_primitive[DType.int64]().get(i)), _a(r), where)
        elif col == 1:
            assert_equal(c.is_null_at(i), _b_null(r), where)
            if not _b_null(r):
                assert_equal(Int(c.as_primitive[DType.int32]().get(i)), _b(r), where)
        elif col == 2:
            if c.arrow_type == ArrowType.DICTIONARY:
                assert_equal(_dict_str(c, i), _d(r), where)
            else:
                assert_equal(c.as_string().get(i), _d(r), where)
        elif col == 3:
            assert_equal(Int(c.as_primitive[DType.int64]().get(i)), _n(r), where)
        else:
            assert_equal(c.is_null_at(i), _m_null(r), where)
            if not _m_null(r):
                assert_equal(Int(c.as_primitive[DType.int32]().get(i)), _m(r), where)


def _check_batch(b: RecordBatch, cols: List[Int], first: Int) raises:
    assert_equal(b.num_columns(), len(cols))
    for k in range(len(cols)):
        _check_col(b.column_at(k), cols[k], first, b.num_rows())


def _chunk_lo(c: ColumnChunk) -> Int:
    var lo = c.meta_data.data_page_offset
    if c.meta_data.dictionary_page_offset:
        lo = min(lo, c.meta_data.dictionary_page_offset.value())
    return lo


def test_the_row_group_range_is_exactly_its_chunks() raises:
    var file = _file()
    var md = _footer(file)
    assert_equal(len(md.row_groups), 2)
    for g in range(2):
        ref rg = md.row_groups[g]
        var br = row_group_byte_range(rg)
        var lo = _chunk_lo(rg.columns[0])
        var hi = 0
        for i in range(len(rg.columns)):
            lo = min(lo, _chunk_lo(rg.columns[i]))
            hi = max(hi, _chunk_lo(rg.columns[i]) + rg.columns[i].meta_data.total_compressed_size)
        assert_equal(br.start, lo)
        assert_equal(br.end, hi)
        # The writer lays a row group's chunks end to end.
        assert_equal(br.length(), rg.total_byte_size)
    var empty = RowGroup(columns=List[ColumnChunk](), total_byte_size=0, num_rows=0)
    var none = row_group_byte_range(empty)
    assert_equal(none.start, 0)
    assert_equal(none.end, 0)


def test_every_row_group_decodes_from_its_own_bytes() raises:
    var file = _file()
    var md = _footer(file)
    var all_cols: List[Int] = [0, 1, 2, 3, 4]
    for g in range(2):
        ref rg = md.row_groups[g]
        var br = row_group_byte_range(rg)
        var before = parquet_column_chunks_decoded()
        var b = decode_row_group_from_bytes(
            _view(Span(file)[br.start : br.end]),
            br,
            rg,
            md.schema,
            ColumnProjection.all(),
        )
        assert_equal(parquet_column_chunks_decoded() - before, 5)
        assert_equal(b.num_rows(), rg.num_rows)
        _check_batch(b, all_cols, _rg_first(g))
        assert_true(b.column_at(2).arrow_type == ArrowType.STRING)


def test_a_projection_and_a_kept_dictionary() raises:
    var file = _file()
    var md = _footer(file)
    ref rg = md.row_groups[1]
    var br = row_group_byte_range(rg)
    var cols: List[Int] = [4, 2, 0]
    var b = decode_row_group_from_bytes(
        _view(Span(file)[br.start : br.end]),
        br,
        rg,
        md.schema,
        ColumnProjection.columns(cols.copy()),
        preserve_dict=True,
    )
    _check_batch(b, cols, 50)
    assert_true(b.column_at(1).arrow_type == ArrowType.DICTIONARY)
    assert_equal(b.schema.field_name(0), "m")
    var sub = decode_row_group_columns_subset(
        _view(Span(file)[br.start : br.end]), br, rg, md.schema, [3]
    )
    _check_batch(sub, [3], 50)


def test_one_chunk_out_of_a_view_of_the_whole_file() raises:
    var file = _file()
    var md = _footer(file)
    var whole = ByteRange(0, len(file))
    var ctx = ColumnDecodeContext()
    for col in range(5):
        var c = decode_column_chunk_from_bytes(
            _view(Span(file)), whole, md.row_groups[0].columns[col],
            md.schema[col + 1], False, ctx,
        )
        _check_col(c, col, 0, 50)


def test_numeric_dictionary_codes() raises:
    var file = _file()
    var md = _footer(file)
    var whole = ByteRange(0, len(file))
    for g in range(2):
        ref rg = md.row_groups[g]
        var first = _rg_first(g)
        var n_codes = decode_numeric_dict_codes_from_bytes(
            _view(Span(file)), whole, rg.columns[3], md.schema[4]
        )
        assert_true(n_codes.__bool__(), "an INT64 dictionary chunk")
        ref nc = n_codes.value()
        assert_equal(nc.codes.length, rg.num_rows)
        for i in range(rg.num_rows):
            assert_equal(Int(nc.dict_values[Int(nc.codes.get(i))]), _n(first + i))
        var m_codes = decode_numeric_dict_codes_from_bytes(
            _view(Span(file)), whole, rg.columns[4], md.schema[5]
        )
        assert_true(m_codes.__bool__(), "a nullable INT32 dictionary chunk")
        ref mc = m_codes.value()
        # Only the non-null rows have a code, in row order.
        var k = 0
        for i in range(rg.num_rows):
            if _m_null(first + i):
                continue
            assert_equal(Int(mc.dict_values[Int(mc.codes.get(k))]), _m(first + i))
            k += 1
        assert_equal(mc.codes.length, k)
        assert_false(
            decode_numeric_dict_codes_from_bytes(
                _view(Span(file)), whole, rg.columns[0], md.schema[1]
            ).__bool__(),
            "a PLAIN chunk",
        )
        assert_false(
            decode_numeric_dict_codes_from_bytes(
                _view(Span(file)), whole, rg.columns[2], md.schema[3]
            ).__bool__(),
            "a BYTE_ARRAY dictionary chunk",
        )


def test_refusals() raises:
    var file = _file()
    var md = _footer(file)
    ref rg = md.row_groups[0]
    var br = row_group_byte_range(rg)
    with assert_raises(contains="does not match byte_range length"):
        _ = decode_row_group_from_bytes(
            _view(Span(file)[br.start : br.end - 1]), br, rg, md.schema,
            ColumnProjection.all(),
        )
    # A range one byte short of the last chunk.
    var short = ByteRange(br.start, br.end - 1)
    with assert_raises(contains="is not contained in byte_range"):
        _ = decode_row_group_from_bytes(
            _view(Span(file)[short.start : short.end]), short, rg, md.schema,
            ColumnProjection.all(),
        )
    with assert_raises(contains="is not a leaf"):
        _ = decode_row_group_columns_subset(
            _view(Span(file)[br.start : br.end]), br, rg, md.schema, [5]
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
