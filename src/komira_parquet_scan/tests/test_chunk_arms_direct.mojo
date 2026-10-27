# The chunk arms over a file written by komira_test_parquet_file: two row
# groups (6,000 and 4,000 rows) of a (INT64 PLAIN, row, pages of 1,000),
# b (DOUBLE PLAIN, row / 4, pages of 700), c (INT32 PLAIN, -row, pages of
# 1,500), d (INT64 dictionary, 7 * (row % 9)), e (INT32 dictionary, row % 4)
# and n (OPTIONAL INT64 PLAIN, row, NULL at row 2,345).
#   - FlatViewChunk: every row once, in order, grain by grain; each page
#     decoded once; a view goes stale on the next pull; a dictionary column
#     is refused;
#   - CodeViewChunk: the driver's grains and a second key filled to the same
#     row count resolve to the values written;
#   - FlatMorselChunk: three columns with different page boundaries come out
#     row aligned, each grain ending at the next boundary of any column, each
#     page decoded once, read through a fold written over MorselView; a
#     dictionary column or an actual null is refused;
#   - a view goes stale on the next pull or `set_grain_n` (all three arms);
#   - a drained chunk has emitted all its footer values and a truncated one
#     fewer (FlatViewChunk, FlatMorselChunk); a morsel view held across the
#     pull that returns 0 is stale;
#   - over a footer with a timestamp-only LogicalType, UINT_32 / UINT_64
#     annotations and a zero dictionary offset: every arm declines the
#     relabelled columns with no grain out, and a zero-offset PLAIN column
#     streams every row.

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.morsel_view import MorselView
from komira_async.ops.waker_sink import NoopSink
from komira_collections.slab import Slab
from komira_fs.local_fs import LocalFs
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.subrg_column_cursor import ResumableColumnCursor
from komira_parquet_api.metadata import FileMetaData
from komira_parquet_scan.code_view_chunk import CodeViewChunk, code_view_over
from komira_parquet_scan.flat_morsel_chunk import FlatMorselChunk, flat_morsel_view_over
from komira_parquet_scan.flat_view_chunk import FlatViewChunk, flat_view_over
from komira_parquet_scan.parquet_reader import ParquetReader
from komira_parquet_scan.subrg_agg_plan import resolve_reader_col_idx
from komira_parquet_scan.subrg_cursor_feed import open_subrg_cursor
from komira_runtime_paths import test_tmpdir
from komira_test_parquet_file import TestColumn, TestFileLayout, write_parquet_file

comptime _FS = LocalFs[NoopSink]
comptime _NULL_ROW = 2_345


def _rgs() -> List[Int]:
    return [6_000, 4_000]


def _reader() raises -> ParquetReader[_FS]:
    var path = test_tmpdir() + "/chunk_arms.parquet"
    var a = List[Int]()
    var b = List[Float64]()
    var c = List[Int]()
    var d = List[Int]()
    var e = List[Int]()
    var nn = List[Bool]()
    for r in range(10_000):
        a.append(r)
        b.append(Float64(r) / 4.0)
        c.append(-r)
        d.append(7 * (r % 9))
        e.append(r % 4)
        nn.append(r == _NULL_ROW)
    var cols = List[TestColumn]()
    cols.append(TestColumn.int64("a", a.copy()).with_page_rows(1_000))
    cols.append(TestColumn.float64("b", b^).with_page_rows(700))
    cols.append(TestColumn.int32("c", c^).with_page_rows(1_500))
    cols.append(TestColumn.int64("d", d^).dict_encoded())
    cols.append(TestColumn.int32("e", e^).dict_encoded())
    cols.append(TestColumn.int64("n", a^).with_nulls(nn^).with_page_rows(1_000))
    write_parquet_file(path, cols, TestFileLayout(_rgs(), 0, False))
    var file = ParquetFileReader[_FS].open(path)
    var meta = parse_full_metadata(file.metadata_bytes.view_range_ro(0, file.metadata_length))
    return ParquetReader[_FS](_file=file^, _meta=ArcPointer[FileMetaData](meta^))


def _cursor(reader: ParquetReader[_FS], rg: Int, name: String) raises -> ResumableColumnCursor:
    return open_subrg_cursor(
        reader._file, reader._meta[].row_groups[rg], reader._meta[].schema, resolve_reader_col_idx(reader, name)
    )


def _first_row(rg: Int) -> Int:
    return 0 if rg == 0 else _rgs()[0]


def _pages(rows: Int, page: Int) -> Int:
    return (rows + page - 1) // page


def test_flat_view_reads_every_row_in_place_once_per_page() raises:
    var reader = _reader()
    for rg in range(2):
        var rows = _rgs()[rg]
        var chunk = FlatViewChunk(_cursor(reader, rg, "a"), 256)
        assert_true(chunk.supported())
        var r = _first_row(rg)
        var seen = 0
        while True:
            var n = chunk.fill_next_grain()
            if n == 0:
                break
            assert_true(n <= 256)
            var view = flat_view_over(chunk)
            for i in range(n):
                assert_equal(Int(view.load[DType.int64, 1](i)[0]), r)
                r += 1
            seen += n
        assert_equal(seen, rows)
        assert_equal(chunk.page_decompress_count(), _pages(rows, 1_000))
        # DOUBLE in place, and a view that outlives a pull is stale.
        var fb = FlatViewChunk(_cursor(reader, rg, "b"), 4_096)
        assert_true(fb.fill_next_grain() > 0)
        var v0 = flat_view_over(fb)
        assert_equal(v0.load_f64(1), Float64(_first_row(rg) + 1) / 4.0)
        assert_true(v0.is_valid())
        _ = fb.fill_next_grain()
        assert_false(v0.is_valid())
    # A dictionary column cannot be read in place.
    var fd = FlatViewChunk(_cursor(reader, 0, "d"), 256)
    assert_equal(fd.fill_next_grain(), 0)
    assert_false(fd.supported())


def test_code_view_grains_and_a_lockstep_second_key() raises:
    var reader = _reader()
    for rg in range(2):
        var rows = _rgs()[rg]
        var driver = CodeViewChunk(_cursor(reader, rg, "d"), 1_000)
        var other = CodeViewChunk(_cursor(reader, rg, "e"), 1_000)
        assert_true(driver.supported() and other.supported())
        var dd = driver.dict_i64_copy()
        var ed = other.dict_i64_copy()
        var r = _first_row(rg)
        while True:
            var n = driver.open_next_codes_grain()
            if n == 0:
                break
            var got = 0
            while got < n:
                var k = other.fill_codes_at(n - got, got)
                if k == 0:
                    break
                got += k
            assert_equal(got, n)
            other.set_grain_n(n)
            var dv = code_view_over(driver)
            var ev = code_view_over(other)
            assert_equal(ev.n_rows(), n)
            for i in range(n):
                assert_equal(Int(dd[Int(dv.load_code_scalar(i))]), 7 * (r % 9))
                assert_equal(Int(ed[Int(ev.load_code_scalar(i))]), r % 4)
                r += 1
        assert_equal(driver.rows_emitted(), rows)
        assert_equal(other.rows_emitted(), rows)
        assert_equal(driver.num_values(), rows)


def _sum_col[V: MorselView](view: V, idx: Int, is_float: Bool) -> Float64:
    """A fold written over the seam: the column's sum."""
    var s = 0.0
    for i in range(view.n_rows()):
        if view.has_selection_mask() or view.col_is_null(idx, i):
            continue
        if is_float:
            s += view.col_scalar_nonraising[DType.float64](idx, i)
        elif idx == 2:
            s += Float64(view.col_scalar_nonraising[DType.int32](idx, i))
        else:
            s += Float64(view.col_scalar_nonraising[DType.int64](idx, i))
    return s


def _boundaries(rows: Int) -> List[Int]:
    """Every row index in (0, rows] at which a, b or c starts a page, plus
    `rows`, ascending: where the aligned grains must end."""
    var out = List[Int]()
    for r in range(1, rows + 1):
        if r == rows or r % 1_000 == 0 or r % 700 == 0 or r % 1_500 == 0:
            out.append(r)
    return out^


def test_flat_morsel_grains_are_row_aligned_and_end_at_page_boundaries() raises:
    var reader = _reader()
    for rg in range(2):
        var rows = _rgs()[rg]
        var cursors = Slab[ResumableColumnCursor].create(3)
        cursors.append(_cursor(reader, rg, "a"))
        cursors.append(_cursor(reader, rg, "b"))
        cursors.append(_cursor(reader, rg, "c"))
        var chunk = FlatMorselChunk(cursors^, 4_096)
        assert_true(chunk.supported())
        assert_true(chunk.col_dtype(0) == DType.int64)
        assert_true(chunk.col_dtype(1) == DType.float64)
        assert_true(chunk.col_dtype(2) == DType.int32)
        var ends = _boundaries(rows)
        var at = 0
        var g = 0
        var r0 = _first_row(rg)
        var sums: List[Float64] = [0.0, 0.0, 0.0]
        while True:
            var n = chunk.fill_next_grain()
            if n == 0:
                break
            at += n
            assert_equal(at, ends[g])
            g += 1
            var view = flat_morsel_view_over(chunk)
            assert_equal(view.num_columns(), 3)
            for i in range(n):
                var r = r0 + at - n + i
                assert_equal(Int(view.col_scalar_nonraising[DType.int64](0, i)), r)
                assert_equal(view.col_scalar_nonraising[DType.float64](1, i), Float64(r) / 4.0)
                assert_equal(Int(view.col_scalar_nonraising[DType.int32](2, i)), -r)
            sums[0] += _sum_col(view, 0, False)
            sums[1] += _sum_col(view, 1, True)
            sums[2] += _sum_col(view, 2, False)
        assert_equal(g, len(ends))
        assert_equal(at, rows)
        var want = 0.0
        for r in range(r0, r0 + rows):
            want += Float64(r)
        assert_equal(sums[0], want)
        assert_equal(sums[1], want / 4.0)
        assert_equal(sums[2], -want)
        assert_equal(chunk.page_decompress_count(0), _pages(rows, 1_000))
        assert_equal(chunk.page_decompress_count(1), _pages(rows, 700))
        assert_equal(chunk.page_decompress_count(2), _pages(rows, 1_500))


def test_flat_morsel_refuses_a_dictionary_column_and_an_actual_null() raises:
    var reader = _reader()
    var with_dict = Slab[ResumableColumnCursor].create(2)
    with_dict.append(_cursor(reader, 0, "a"))
    with_dict.append(_cursor(reader, 0, "d"))
    var cd = FlatMorselChunk(with_dict^, 512)
    assert_false(cd.supported())
    assert_equal(cd.fill_next_grain(), 0)
    # n is NULL at row 2,345: the grains before its page come out, then the
    # pull returns 0 and the cursor is refused.
    var with_null = Slab[ResumableColumnCursor].create(2)
    with_null.append(_cursor(reader, 0, "a"))
    with_null.append(_cursor(reader, 0, "n"))
    var cn = FlatMorselChunk(with_null^, 512)
    var total = 0
    while True:
        var n = cn.fill_next_grain()
        if n == 0:
            break
        total += n
    assert_equal(total, 2_000)
    assert_false(cn.supported())
    var empty = FlatMorselChunk(Slab[ResumableColumnCursor](), 512)
    assert_false(empty.supported())
    assert_equal(empty.fill_next_grain(), 0)


def test_views_go_stale_on_the_next_pull() raises:
    var reader = _reader()
    var driver = CodeViewChunk(_cursor(reader, 0, "d"), 500)
    var other = CodeViewChunk(_cursor(reader, 0, "e"), 500)
    var n = driver.open_next_codes_grain()
    assert_true(n > 0)
    var d0 = code_view_over(driver)
    assert_true(d0.is_valid())
    assert_equal(other.fill_codes_at(n, 0), n)
    var e0 = code_view_over(other)
    other.set_grain_n(n)
    # The view taken before `set_grain_n` is stale, the one taken after is not.
    assert_false(e0.is_valid())
    assert_true(code_view_over(other).is_valid())
    _ = driver.open_next_codes_grain()
    assert_false(d0.is_valid())
    var cols = Slab[ResumableColumnCursor].create(2)
    cols.append(_cursor(reader, 0, "a"))
    cols.append(_cursor(reader, 0, "b"))
    var m = FlatMorselChunk(cols^, 512)
    assert_true(m.fill_next_grain() > 0)
    var m0 = flat_morsel_view_over(m)
    assert_true(m0.is_valid())
    assert_equal(m0.generation(), m.gen())
    assert_true(m.fill_next_grain() > 0)
    assert_false(m0.is_valid())


def test_a_drained_chunk_is_told_from_a_truncated_one() raises:
    var whole = _reader()
    var cut_meta = whole._meta[].copy()
    cut_meta.row_groups[0].columns[0].meta_data.total_compressed_size //= 2
    var cut = ParquetReader[_FS](
        _file=ParquetFileReader[_FS].open(test_tmpdir() + "/chunk_arms.parquet"),
        _meta=ArcPointer[FileMetaData](cut_meta^),
    )
    var v = FlatViewChunk(_cursor(whole, 0, "a"), 512)
    while v.fill_next_grain() > 0:
        pass
    assert_equal(v.rows_emitted(), v.num_values())
    assert_equal(v.num_values(), _rgs()[0])
    var vc = FlatViewChunk(_cursor(cut, 0, "a"), 512)
    while vc.fill_next_grain() > 0:
        pass
    assert_equal(vc.num_values(), _rgs()[0])
    assert_true(vc.rows_emitted() < vc.num_values())
    var cols = Slab[ResumableColumnCursor].create(2)
    cols.append(_cursor(whole, 0, "a"))
    cols.append(_cursor(whole, 0, "b"))
    var m = FlatMorselChunk(cols^, 512)
    while m.fill_next_grain() > 0:
        pass
    assert_equal(m.rows_emitted(0), m.num_values(0))
    assert_equal(m.rows_emitted(1), m.num_values(1))
    var cols2 = Slab[ResumableColumnCursor].create(2)
    cols2.append(_cursor(cut, 0, "a"))
    cols2.append(_cursor(whole, 0, "b"))
    var mc = FlatMorselChunk(cols2^, 512)
    while mc.fill_next_grain() > 0:
        pass
    assert_true(mc.rows_emitted(0) < mc.num_values(0))


def test_a_morsel_view_taken_before_a_zero_pull_goes_stale() raises:
    var reader = _reader()
    var cols = Slab[ResumableColumnCursor].create(1)
    cols.append(_cursor(reader, 0, "a"))
    var m = FlatMorselChunk(cols^, 4_096)
    var last = flat_morsel_view_over(m)
    while True:
        var n = m.fill_next_grain()
        if n == 0:
            break
        last = flat_morsel_view_over(m)
    assert_false(last.is_valid())
    var cols2 = Slab[ResumableColumnCursor].create(1)
    cols2.append(_cursor(reader, 0, "a"))
    var m2 = FlatMorselChunk(cols2^, 100_000)
    assert_true(m2.fill_next_grain() > 0)
    var held = flat_morsel_view_over(m2)
    assert_true(held.is_valid())
    while m2.fill_next_grain() > 0:
        pass
    assert_false(held.is_valid())
    assert_equal(held.n_rows(), 0)


def _patched() raises -> ParquetReader[_FS]:
    """The `_reader()` footer with a (schema 1) carrying only the LogicalType
    TIMESTAMP, c (schema 3) annotated UINT_32, d (schema 4) UINT_64 and b's
    chunks storing dictionary offset 0."""
    var base = _reader()
    var meta = base._meta[].copy()
    meta.schema[1].logical_timestamp_unit = Optional[Int](2)
    meta.schema[3].converted_type = Optional[Int](13)
    meta.schema[4].converted_type = Optional[Int](14)
    for rg in range(2):
        meta.row_groups[rg].columns[1].meta_data.dictionary_page_offset = Optional[Int](0)
    return ParquetReader[_FS](
        _file=ParquetFileReader[_FS].open(test_tmpdir() + "/chunk_arms.parquet"), _meta=ArcPointer[FileMetaData](meta^)
    )


def test_every_arm_declines_what_the_cursors_refuse() raises:
    var reader = _patched()
    # A timestamp, an unsigned INT32 and an unsigned dictionary are refused
    # by every arm, with no grain out.
    var ts = FlatViewChunk(_cursor(reader, 0, "a"), 256)
    assert_false(ts.supported())
    assert_equal(ts.fill_next_grain(), 0)
    var u32 = FlatViewChunk(_cursor(reader, 0, "c"), 256)
    assert_equal(u32.fill_next_grain(), 0)
    var u64 = CodeViewChunk(_cursor(reader, 0, "d"), 256)
    assert_false(u64.supported())
    assert_equal(u64.open_next_codes_grain(), 0)
    var cols = Slab[ResumableColumnCursor].create(2)
    cols.append(_cursor(reader, 0, "b"))
    cols.append(_cursor(reader, 0, "a"))
    var m = FlatMorselChunk(cols^, 256)
    assert_false(m.supported())
    assert_equal(m.fill_next_grain(), 0)
    # A zero dictionary offset is no dictionary page: b streams every row.
    var b = FlatViewChunk(_cursor(reader, 0, "b"), 1_000)
    var seen = 0
    while True:
        var n = b.fill_next_grain()
        if n == 0:
            break
        var v = flat_view_over(b)
        for i in range(n):
            assert_equal(v.load_f64(i), Float64(seen + i) / 4.0)
        seen += n
    assert_equal(seen, _rgs()[0])
    # The column the footer leaves alone still streams beside them.
    var e = CodeViewChunk(_cursor(reader, 0, "e"), 1_000)
    assert_true(e.supported())
    assert_equal(e.open_next_codes_grain(), 1_000)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
