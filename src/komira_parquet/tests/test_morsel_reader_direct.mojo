# ParquetMorselReader on files written by komira_test_parquet_file (an
# encoder independent of this reader), with every value checked against the
# rows the file was written from:
#   - morsels: one per row group when it fits, windows cut across row
#     groups and pages at unaligned row offsets (validity rebased), one-row
#     morsels, reset, a file of no rows;
#   - a dictionary column kept as DICTIONARY through morsel windows (the
#     window shares the dictionary; a window that dropped it is caught);
#   - projections (order, the decode census counting one chunk per row
#     group and projected column, never per morsel), decode_columns_for_rg,
#     decode_row_group_shared with and without the buffer move;
#   - the one-pass selection decode, raw chunk reads, the footer cache;
#   - the refusals (morsel size, projection, row group).

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch
from komira_buffer.heap_region import HeapRegion
from komira_counters.parquet_read_counter import parquet_column_chunks_decoded
from komira_parquet.morsel_reader import ColumnProjection, ParquetMorselReader
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_parquet.selection_vector import SelectionInterval
from komira_runtime_paths import test_tmpdir
from komira_test_parquet_file import (
    TestColumn,
    TestFileLayout,
    parquet_file_bytes,
    write_parquet_file,
)

comptime _ROWS = 100
comptime _NCOLS = 5


# Column a: INT64 REQUIRED; b: INT32 OPTIONAL; s: UTF8 OPTIONAL;
# d: UTF8 REQUIRED, dictionary-encoded; f: DOUBLE REQUIRED.
def _a(r: Int) -> Int:
    return r * 10 - 7


def _b_null(r: Int) -> Bool:
    return r % 7 == 3


def _b(r: Int) -> Int:
    return r * r - 1000


def _s_null(r: Int) -> Bool:
    return r % 11 == 5


def _s(r: Int) -> String:
    return "v" + String(r % 13) + "_" + String(r)


def _d(r: Int) -> String:
    return "key" + String(r % 4)


def _f(r: Int) -> Float64:
    return Float64(r) * 0.5 - 3.0


def _columns() -> List[TestColumn]:
    var a = List[Int]()
    var b = List[Int]()
    var bn = List[Bool]()
    var s = List[String]()
    var sn = List[Bool]()
    var d = List[String]()
    var f = List[Float64]()
    for r in range(_ROWS):
        a.append(_a(r))
        b.append(_b(r))
        bn.append(_b_null(r))
        s.append(_s(r))
        sn.append(_s_null(r))
        d.append(_d(r))
        f.append(_f(r))
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("a", a^))
    cols.append(TestColumn.int32("b", b^).with_nulls(bn^))
    cols.append(TestColumn.string("s", s^).with_nulls(sn^))
    cols.append(TestColumn.string("d", d^).dict_encoded())
    cols.append(TestColumn.float64("f", f^))
    return cols^


def _layout() -> TestFileLayout:
    return TestFileLayout([40, 35, 25], 16, False)


def _file(name: String) raises -> String:
    var path = test_tmpdir() + "/" + name
    write_parquet_file(path, _columns(), _layout())
    return path^


def _dict_str(c: Column[HeapRegion], row: Int) raises -> String:
    var bv = c.string_dict_value_at(c.string_dict_code_at(row))
    var buf = List[UInt8](capacity=bv.len())
    for k in range(bv.len()):
        buf.append(bv.read_u8_at(k))
    return String(StringSlice(unsafe_from_utf8=Span(buf)))


def _check_col(c: Column[HeapRegion], col: Int, first: Int, n: Int) raises:
    """Column `col` of the file holds rows [first, first + n)."""
    assert_equal(c.length(), n, "length")
    if col == 0:
        assert_equal(c.null_count(), 0)
        var p = c.as_primitive[DType.int64]()
        for i in range(n):
            assert_equal(Int(p.get(i)), _a(first + i), "a row " + String(first + i))
    elif col == 1:
        var p = c.as_primitive[DType.int32]()
        var nulls = 0
        for i in range(n):
            var r = first + i
            assert_equal(c.is_null_at(i), _b_null(r), "b null row " + String(r))
            if _b_null(r):
                nulls += 1
            else:
                assert_equal(Int(p.get(i)), _b(r), "b row " + String(r))
        assert_equal(c.null_count(), nulls, "b null count")
    elif col == 2:
        assert_true(c.arrow_type == ArrowType.STRING)
        var sa = c.as_string()
        var nulls = 0
        for i in range(n):
            var r = first + i
            assert_equal(c.is_null_at(i), _s_null(r), "s null row " + String(r))
            if _s_null(r):
                nulls += 1
            else:
                assert_equal(sa.get(i), _s(r), "s row " + String(r))
        assert_equal(c.null_count(), nulls, "s null count")
    elif col == 3:
        if c.arrow_type == ArrowType.DICTIONARY:
            for i in range(n):
                assert_equal(_dict_str(c, i), _d(first + i), "d row " + String(first + i))
        else:
            assert_true(c.arrow_type == ArrowType.STRING)
            var sa = c.as_string()
            for i in range(n):
                assert_equal(sa.get(i), _d(first + i), "d row " + String(first + i))
    else:
        var p = c.as_primitive[DType.float64]()
        for i in range(n):
            assert_equal(p.get(i), _f(first + i), "f row " + String(first + i))


def _check_batch(b: RecordBatch, cols: List[Int], first: Int) raises:
    assert_equal(b.num_columns(), len(cols))
    for k in range(len(cols)):
        _check_col(b.column_at(k), cols[k], first, b.num_rows())


def _all_cols() -> List[Int]:
    return [0, 1, 2, 3, 4]


def _drain(mut r: ParquetMorselReader, cols: List[Int]) raises -> List[Int]:
    """Every morsel's row count, each morsel checked against the rows it
    should hold."""
    var sizes = List[Int]()
    var first = 0
    while True:
        var m = r.next_morsel()
        if not m:
            break
        var b = m.take()
        _check_batch(b, cols, first)
        first += b.num_rows()
        sizes.append(b.num_rows())
    assert_equal(first, _ROWS)
    assert_true(r.is_exhausted())
    return sizes^


def _assert_sizes(got: List[Int], want: List[Int]) raises:
    assert_equal(len(got), len(want), "morsel count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], "morsel " + String(i))


def test_one_morsel_per_row_group_when_it_fits() raises:
    var r = ParquetMorselReader.open(_file("fits.parquet"), 64)
    assert_equal(r.num_row_groups(), 3)
    assert_equal(r.num_rows(), _ROWS)
    assert_equal(r.num_columns(), _NCOLS)
    _assert_sizes(_drain(r, _all_cols()), [40, 35, 25])
    assert_false(r.next_morsel().__bool__())


def test_morsels_cut_row_groups_at_unaligned_rows() raises:
    var r = ParquetMorselReader.open(_file("cut.parquet"), 13)
    _assert_sizes(
        _drain(r, _all_cols()), [13, 13, 13, 1, 13, 13, 9, 13, 12]
    )


def test_one_row_morsels() raises:
    var r = ParquetMorselReader.open(_file("one.parquet"), 1)
    var sizes = _drain(r, _all_cols())
    assert_equal(len(sizes), _ROWS)


def test_reset_reads_the_file_again() raises:
    var r = ParquetMorselReader.open(_file("reset.parquet"), 30)
    _ = _drain(r, _all_cols())
    r.reset()
    assert_false(r.is_exhausted())
    _assert_sizes(_drain(r, _all_cols()), [30, 10, 30, 5, 25])


def test_a_file_of_no_rows() raises:
    var path = test_tmpdir() + "/empty.parquet"
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("a", List[Int]()))
    write_parquet_file(path, cols, TestFileLayout.single())
    var r = ParquetMorselReader.open(path)
    assert_equal(r.num_row_groups(), 0)
    assert_true(r.is_exhausted())
    assert_false(r.next_morsel().__bool__())


def test_a_kept_dictionary_survives_morsel_windows() raises:
    var r = ParquetMorselReader.open(_file("dict.parquet"), 13)
    r.set_preserve_dict(True)
    var first = 0
    while True:
        var m = r.next_morsel()
        if not m:
            break
        var b = m.take()
        ref d = b.column_at(3)
        assert_true(d.arrow_type == ArrowType.DICTIONARY, "d stays a dictionary")
        _check_col(d, 3, first, b.num_rows())
        first += b.num_rows()
    assert_equal(first, _ROWS)


def test_a_projection_decodes_only_its_columns_in_its_order() raises:
    var path = _file("proj.parquet")
    var before = parquet_column_chunks_decoded()
    var r = ParquetMorselReader.open_projected(
        path, ColumnProjection.columns([4, 0, 2]), 7
    )
    _ = _drain(r, [4, 0, 2])
    # One chunk per row group and projected column, however many morsels
    # each row group was cut into.
    assert_equal(parquet_column_chunks_decoded() - before, 3 * 3)
    r.set_projection(ColumnProjection.columns([1]))
    r.reset()
    _ = _drain(r, [1])


def test_decode_columns_for_rg_and_the_shared_decode() raises:
    var r = ParquetMorselReader.open(_file("shared.parquet"))
    var before = parquet_column_chunks_decoded()
    var b = r.decode_columns_for_rg(1, [3, 1])
    assert_equal(parquet_column_chunks_decoded() - before, 2)
    assert_equal(b.num_rows(), 35)
    _check_batch(b, [3, 1], 40)
    assert_equal(b.schema.field_name(0), "d")
    var moved = r.decode_row_group_shared(2)
    var copied = r.decode_row_group_shared(2, decode_move=False)
    _check_batch(moved, _all_cols(), 75)
    _check_batch(copied, _all_cols(), 75)
    # The shared decode leaves the iterator where it was.
    _assert_sizes(_drain(r, _all_cols()), [40, 35, 25])


def _expect_selected(
    c: Column[HeapRegion], col: Int, first: Int, sel: List[Int]
) raises:
    """`c` holds rows `first + sel[k]`, in order."""
    assert_equal(c.length(), len(sel))
    for k in range(len(sel)):
        var r = first + sel[k]
        if col == 0:
            assert_equal(Int(c.as_primitive[DType.int64]().get(k)), _a(r))
        else:
            assert_equal(c.is_null_at(k), _b_null(r), "b null row " + String(r))
            if not _b_null(r):
                assert_equal(Int(c.as_primitive[DType.int32]().get(k)), _b(r))


def test_the_one_pass_selection_decode() raises:
    var r = ParquetMorselReader.open(_file("sel.parquet"))
    # Rows 3..7 and 20..25 of row group 1 (which starts at row 40): one
    # interval in each of its first two pages (16 rows each).
    var ivls = List[SelectionInterval]()
    ivls.append(SelectionInterval(UInt32(3), UInt32(5)))
    ivls.append(SelectionInterval(UInt32(12), UInt32(6)))
    var sel: List[Int] = [3, 4, 5, 6, 7, 20, 21, 22, 23, 24, 25]
    var cols: List[Int] = [0, 1]
    for k in range(len(cols)):
        var col = cols[k]
        var got = r.try_decode_column_with_selection(1, col, Span(ivls), len(sel))
        assert_true(got.__bool__(), "the gather takes a PLAIN chunk")
        _expect_selected(got.value(), col, 40, sel)


def test_raw_chunks_are_the_bytes_as_stored() raises:
    var path = _file("raw.parquet")
    var file_bytes = parquet_file_bytes(_columns(), _layout())
    var r = ParquetMorselReader.open(path)
    var raws = r.read_raw_chunks_for_rg(1, [0, 3])
    assert_equal(len(raws), 2)
    var cols: List[Int] = [0, 3]
    for k in range(2):
        var col = cols[k]
        ref meta = r.metadata_ref().row_groups[1].columns[col].meta_data
        var start = meta.data_page_offset
        if meta.dictionary_page_offset:
            start = min(start, meta.dictionary_page_offset.value())
        ref raw = raws[k].raw_bytes
        assert_equal(len(raw), meta.total_compressed_size)
        for i in range(len(raw)):
            assert_equal(Int(raw[i]), Int(file_bytes[start + i]))


def test_open_with_the_footer_cache() raises:
    var path = _file("cache.parquet")
    var cache = ParquetMetadataCache()
    var r1 = ParquetMorselReader.open_with_cache(path, cache, 50)
    var r2 = ParquetMorselReader.open_with_cache(path, cache, 50)
    _assert_sizes(_drain(r1, _all_cols()), [40, 35, 25])
    _assert_sizes(_drain(r2, _all_cols()), [40, 35, 25])


def test_refusals() raises:
    var path = _file("refuse.parquet")
    with assert_raises(contains="morsel_size must be at least 1"):
        _ = ParquetMorselReader.open(path, 0)
    with assert_raises(contains="is not a leaf"):
        _ = ParquetMorselReader.open_projected(path, ColumnProjection.columns([5]))
    var r = ParquetMorselReader.open(path)
    with assert_raises(contains="is out of range"):
        _ = r.decode_columns_for_rg(3, [0])
    with assert_raises(contains="is not a leaf"):
        _ = r.decode_columns_for_rg(0, [-1])
    with assert_raises(contains="is not a leaf"):
        r.set_projection(ColumnProjection.columns([0, 9]))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
