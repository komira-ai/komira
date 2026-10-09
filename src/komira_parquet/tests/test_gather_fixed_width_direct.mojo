# Direct tests of the PLAIN fixed-width selection gathers of `gather.mojo`:
# `_gather_plain_fixed_width` and `_gather_plain_fixed_width_nullable`, through
# their physical-type dispatchers, for INT32, INT64, FLOAT and DOUBLE. Pages
# are PLAIN (parquet-format Encodings.md: little-endian values back to back);
# a nullable page holds the values of its non-null rows only. Expected values
# come from the definition of the gather: walk the (skip, select) intervals
# over the concatenated pages; a selected row's value is that row's value, or
# null where its definition level is 0.
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_parquet_api.types import Encoding, ParquetType

from komira_parquet.gather import (
    _PageDefLevels,
    _PageExtent,
    _gather_plain_fixed_width,
    _gather_plain_fixed_width_dispatch,
    _gather_plain_fixed_width_nullable,
    _gather_plain_fixed_width_nullable_dispatch,
)
from komira_parquet.selection_vector import SelectionInterval


# --- pages ---------------------------------------------------------------------


def _le(mut out: List[UInt8], v: Int, width: Int):
    for k in range(width):
        out.append(UInt8((v >> (8 * k)) & 0xFF))


def _value(r: Int) -> Int:
    """Row r's value: distinct and never 0 (a 0 would hide an unwritten slot)."""
    return r * 7 + 3


def _encode(ptype: ParquetType, v: Int, mut out: List[UInt8]):
    """PLAIN encoding of row value `v` for `ptype` (INT64 in its high bits)."""
    if ptype == ParquetType.INT32:
        _le(out, v, 4)
    elif ptype == ParquetType.INT64:
        _le(out, v << 33, 8)
    elif ptype == ParquetType.FLOAT:
        _le(out, Int(Float32(v).to_bits()), 4)
    else:
        _le(out, Int(Float64(v).to_bits()), 8)


def _buf(bytes: List[UInt8]) -> SharedAlignedBuffer[HeapRegion]:
    var n = len(bytes)
    var buf = OwnedAlignedBuffer(max(n, 1))
    for i in range(n):
        buf.set_typed[UInt8](i, bytes[i])
    buf.set_length(Int64(n))
    return SharedAlignedBuffer.from_owned(buf^)


def _types() -> List[ParquetType]:
    return [
        ParquetType.INT32,
        ParquetType.INT64,
        ParquetType.FLOAT,
        ParquetType.DOUBLE,
    ]


def _ivls(pairs: List[Int]) -> List[SelectionInterval]:
    var out = List[SelectionInterval]()
    for i in range(0, len(pairs), 2):
        out.append(SelectionInterval(UInt32(pairs[i]), UInt32(pairs[i + 1])))
    return out^


def _total(intervals: List[SelectionInterval]) -> Int:
    var t = 0
    for i in range(len(intervals)):
        t += Int(intervals[i].select)
    return t


# --- the reference gather ------------------------------------------------------


@fieldwise_init
struct _Row(Copyable, Movable):
    var is_null: Bool
    var value: Int


def _reference(
    rows: List[_Row], intervals: List[SelectionInterval]
) -> List[_Row]:
    var out = List[_Row]()
    var pos = 0
    for i in range(len(intervals)):
        pos += Int(intervals[i].skip)
        for _ in range(Int(intervals[i].select)):
            out.append(rows[pos].copy())
            pos += 1
    return out^


def _check(ptype: ParquetType, col: Column[HeapRegion], want: List[_Row]) raises:
    """`col` holds each wanted row's value or null, and a validity bitmap
    only when a null was selected."""
    var n = len(want)
    var nulls = 0
    for i in range(n):
        if want[i].is_null:
            nulls += 1
    assert_equal(col.length(), n)
    for i in range(n):
        assert_equal(col.is_null_at(i), want[i].is_null, "row " + String(i))
    if ptype == ParquetType.INT32:
        var a = col.as_primitive[DType.int32]()
        assert_equal(a.null_count, nulls)
        assert_equal(Bool(a.validity), nulls > 0)
        for i in range(n):
            if not want[i].is_null:
                assert_equal(Int(a.get(i)), want[i].value, "row " + String(i))
    elif ptype == ParquetType.INT64:
        var a = col.as_primitive[DType.int64]()
        assert_equal(a.null_count, nulls)
        assert_equal(Bool(a.validity), nulls > 0)
        for i in range(n):
            if not want[i].is_null:
                assert_equal(Int(a.get(i)), want[i].value << 33)
    elif ptype == ParquetType.FLOAT:
        var a = col.as_primitive[DType.float32]()
        assert_equal(a.null_count, nulls)
        assert_equal(Bool(a.validity), nulls > 0)
        for i in range(n):
            if not want[i].is_null:
                assert_equal(a.get(i), Float32(want[i].value))
    else:
        var a = col.as_primitive[DType.float64]()
        assert_equal(a.null_count, nulls)
        assert_equal(Bool(a.validity), nulls > 0)
        for i in range(n):
            if not want[i].is_null:
                assert_equal(a.get(i), Float64(want[i].value))


# The walk shapes, over pages of 5, 0, 4 and 6 rows (15 rows): no interval; a
# select inside a page; a skip to a page end, then a select across the empty
# page into the next; the whole column; a select ending at the last page's
# end; several intervals, each moving to a later page; a zero select past the
# last page after a select.
def _shapes() -> List[List[Int]]:
    return [
        List[Int](),
        [1, 3],
        [3, 4],
        [0, 15],
        [9, 6],
        [4, 1, 4, 1, 0, 2],
        [2, 2, 20, 0],
    ]


def _page_rows() -> List[Int]:
    return [5, 0, 4, 6]


# --- non-null ------------------------------------------------------------------


@fieldwise_init
struct _NonNull(Movable):
    var pages: Slab[SharedAlignedBuffer[HeapRegion]]
    var extents: List[_PageExtent]
    var rows: List[_Row]


def _non_null_pages(ptype: ParquetType, page_rows: List[Int]) -> _NonNull:
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    var extents = List[_PageExtent]()
    var rows = List[_Row]()
    var r = 0
    for p in range(len(page_rows)):
        var bytes = List[UInt8]()
        for _ in range(page_rows[p]):
            _encode(ptype, _value(r), bytes)
            rows.append(_Row(False, _value(r)))
            r += 1
        pages.append(_buf(bytes))
        extents.append(_PageExtent(page_rows[p], Encoding.PLAIN))
    return _NonNull(pages^, extents^, rows^)


def test_non_null_every_type_every_walk_shape() raises:
    """Catches: a wrong page advance (the skip across a page end or an empty
    page), a wrong byte offset in a page, a select cut at a page end, a
    type dispatched to the wrong width."""
    var types = _types()
    var shapes = _shapes()
    for t in range(len(types)):
        var c = _non_null_pages(types[t], _page_rows())
        for s in range(len(shapes)):
            var ivls = _ivls(shapes[s])
            var col = _gather_plain_fixed_width_dispatch(
                types[t], c.pages, Span(c.extents), Span(ivls), _total(ivls)
            )
            _check(types[t], col, _reference(c.rows, ivls))


def test_non_null_first_page_empty_and_no_pages() raises:
    """Catches: a walk that reads the first page's end before advancing, and
    an empty column that is not an empty array."""
    var c = _non_null_pages(ParquetType.INT32, [0, 3, 2])
    var ivls = _ivls([1, 3])
    var col = _gather_plain_fixed_width_dispatch(
        ParquetType.INT32, c.pages, Span(c.extents), Span(ivls), 3
    )
    _check(ParquetType.INT32, col, _reference(c.rows, ivls))
    var none = _non_null_pages(ParquetType.INT64, List[Int]())
    var empty = List[SelectionInterval]()
    var arr = _gather_plain_fixed_width[DType.int64](
        none.pages, Span(none.extents), Span(empty), 0
    )
    assert_equal(arr.length, 0)
    assert_false(Bool(arr.validity))


def _raises_with(
    ptype: ParquetType,
    c: _NonNull,
    ivls: List[SelectionInterval],
    num_selected: Int,
    needle: String,
) raises:
    var raised = False
    try:
        _ = _gather_plain_fixed_width_dispatch(
            ptype, c.pages, Span(c.extents), Span(ivls), num_selected
        )
    except e:
        raised = True
        assert_true(String(e).find(needle) >= 0, String(e))
    assert_true(raised, "no error; wanted: " + needle)


def test_non_null_num_selected_must_be_the_intervals_total() raises:
    """Catches: the up-front num_selected check removed. The output is sized
    from num_selected and the walk writes one slot per selected row, so one
    fewer wrote past the buffer and one more returned an unwritten slot."""
    var types = _types()
    for t in range(len(types)):
        var c = _non_null_pages(types[t], _page_rows())
        var ivls = _ivls([1, 3, 2, 6])
        _raises_with(types[t], c, ivls, 8, "select 9 rows, not num_selected = 8")
        _raises_with(types[t], c, ivls, 10, "select 9 rows, not num_selected = 10")


def test_non_null_intervals_past_the_last_page_are_refused() raises:
    """Catches: the short-walk check removed; the gather returned slots it
    never wrote (a select off the end, a skip past every page, no pages)."""
    var c = _non_null_pages(ParquetType.DOUBLE, _page_rows())
    _raises_with(
        ParquetType.DOUBLE, c, _ivls([10, 10]), 10, "5 of 10 selected rows exist"
    )
    _raises_with(
        ParquetType.DOUBLE, c, _ivls([20, 1]), 1, "0 of 1 selected rows exist"
    )
    var none = _non_null_pages(ParquetType.INT32, List[Int]())
    _raises_with(
        ParquetType.INT32, none, _ivls([0, 1]), 1, "0 of 1 selected rows exist"
    )


def test_non_null_page_shorter_than_its_extent_is_refused() raises:
    """Catches: the per-copy bound on the page buffer removed (a read past
    the page)."""
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    var bytes = List[UInt8]()
    for r in range(3):
        _encode(ParquetType.INT32, _value(r), bytes)
    pages.append(_buf(bytes))
    var extents: List[_PageExtent] = [_PageExtent(5, Encoding.PLAIN)]
    var c = _NonNull(pages^, extents^, List[_Row]())
    _raises_with(ParquetType.INT32, c, _ivls([1, 3]), 3, "read past page end 16 > 12")


def test_non_null_mismatch_and_unsupported_type_are_refused() raises:
    """Catches: the parallel-list check removed, and a dispatcher that
    gathers a type it has no width for."""
    var c = _non_null_pages(ParquetType.INT32, [2, 2])
    _ = c.extents.pop()
    _raises_with(ParquetType.INT32, c, _ivls([0, 1]), 1, "length mismatch: 2 vs 1")
    var d = _non_null_pages(ParquetType.INT32, [2])
    _raises_with(
        ParquetType.BYTE_ARRAY,
        d,
        _ivls([0, 1]),
        1,
        "unsupported fixed-width physical type",
    )


# --- nullable ------------------------------------------------------------------


@fieldwise_init
struct _Nullable(Movable):
    var pages: Slab[SharedAlignedBuffer[HeapRegion]]
    var extents: List[_PageExtent]
    var defs: Slab[_PageDefLevels]
    var rows: List[_Row]


def _is_null(p: Int, r: Int) -> Bool:
    """Page 0: every third row null; page 2: none; others: every other row."""
    if p == 0:
        return r % 3 == 0
    if p == 2:
        return False
    return r % 2 == 1


def _nullable_pages(ptype: ParquetType, page_rows: List[Int]) -> _Nullable:
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    var extents = List[_PageExtent]()
    var defs = Slab[_PageDefLevels]()
    var rows = List[_Row]()
    var r = 0
    for p in range(len(page_rows)):
        var bytes = List[UInt8]()
        var levels = List[UInt8]()
        var non_null = 0
        for _ in range(page_rows[p]):
            if _is_null(p, r):
                levels.append(UInt8(0))
                rows.append(_Row(True, 0))
            else:
                levels.append(UInt8(1))
                _encode(ptype, _value(r), bytes)
                rows.append(_Row(False, _value(r)))
                non_null += 1
            r += 1
        pages.append(_buf(bytes))
        extents.append(_PageExtent(page_rows[p], Encoding.PLAIN))
        defs.append(_PageDefLevels(levels^, non_null))
    return _Nullable(pages^, extents^, defs^, rows^)


def test_nullable_every_type_every_walk_shape() raises:
    """Catches: a value read at the row index instead of its rank among the
    non-null rows, a null row whose bit is not cleared, a page with no null
    (whose rank table is skipped) read through the wrong index, and the
    walk faults of the non-null test."""
    var types = _types()
    var shapes = _shapes()
    for t in range(len(types)):
        var c = _nullable_pages(types[t], _page_rows())
        for s in range(len(shapes)):
            var ivls = _ivls(shapes[s])
            var col = _gather_plain_fixed_width_nullable_dispatch(
                types[t],
                c.pages,
                Span(c.extents),
                c.defs,
                Span(ivls),
                _total(ivls),
            )
            _check(types[t], col, _reference(c.rows, ivls))


def test_nullable_selection_without_a_null_carries_no_bitmap() raises:
    """Catches: a bitmap kept (or a null counted) when no selected row is
    null; rows 5 to 8 are page 2, which has none."""
    var c = _nullable_pages(ParquetType.INT64, _page_rows())
    var ivls = _ivls([5, 4])
    var arr = _gather_plain_fixed_width_nullable[DType.int64](
        c.pages, Span(c.extents), c.defs, Span(ivls), 4
    )
    assert_false(Bool(arr.validity))
    assert_equal(arr.null_count, 0)
    for i in range(4):
        assert_equal(Int(arr.get(i)), _value(5 + i) << 33)


def _nullable_raises_with(
    ptype: ParquetType,
    c: _Nullable,
    ivls: List[SelectionInterval],
    num_selected: Int,
    needle: String,
) raises:
    var raised = False
    try:
        _ = _gather_plain_fixed_width_nullable_dispatch(
            ptype, c.pages, Span(c.extents), c.defs, Span(ivls), num_selected
        )
    except e:
        raised = True
        assert_true(String(e).find(needle) >= 0, String(e))
    assert_true(raised, "no error; wanted: " + needle)


def test_nullable_num_selected_must_be_the_intervals_total() raises:
    """Catches: the nullable gather's up-front num_selected check removed."""
    var types = _types()
    for t in range(len(types)):
        var c = _nullable_pages(types[t], _page_rows())
        var ivls = _ivls([0, 4, 5, 2])
        _nullable_raises_with(
            types[t], c, ivls, 5, "select 6 rows, not num_selected = 5"
        )
        _nullable_raises_with(
            types[t], c, ivls, 7, "select 6 rows, not num_selected = 7"
        )


def test_nullable_intervals_past_the_last_page_are_refused() raises:
    """Catches: the nullable short-walk check removed (the unwritten slots
    came back as valid zeros)."""
    var c = _nullable_pages(ParquetType.FLOAT, _page_rows())
    _nullable_raises_with(
        ParquetType.FLOAT, c, _ivls([12, 4]), 4, "3 of 4 selected rows exist"
    )
    _nullable_raises_with(
        ParquetType.FLOAT, c, _ivls([15, 1]), 1, "0 of 1 selected rows exist"
    )


def test_nullable_def_levels_shorter_than_the_walk_are_refused() raises:
    """Catches: the def-level length check removed; the walk indexed past
    the page's def levels."""
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    var bytes = List[UInt8]()
    for r in range(2):
        _encode(ParquetType.INT32, _value(r), bytes)
    pages.append(_buf(bytes))
    var extents: List[_PageExtent] = [_PageExtent(5, Encoding.PLAIN)]
    var defs = Slab[_PageDefLevels]()
    defs.append(_PageDefLevels([UInt8(1), UInt8(0), UInt8(1)], 2))
    var c = _Nullable(pages^, extents^, defs^, List[_Row]())
    _nullable_raises_with(
        ParquetType.INT32,
        c,
        _ivls([1, 3]),
        3,
        "page 0 carries 3 def levels, the walk needs row 3",
    )


def test_nullable_value_stream_shorter_than_its_rows_is_refused() raises:
    """Catches: the per-value bound removed, on both index paths: a page
    whose record counts every row non-null (the row is the value index) and
    one whose record does not (the rank is)."""
    for ranked in range(2):
        var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
        var bytes = List[UInt8]()
        for r in range(2):
            _encode(ParquetType.INT32, _value(r), bytes)
        pages.append(_buf(bytes))
        var extents: List[_PageExtent] = [_PageExtent(4, Encoding.PLAIN)]
        var defs = Slab[_PageDefLevels]()
        if ranked == 1:
            # Ranks [0, 1, 1, 2]: row 3 reads value 2 of a 2-value stream.
            defs.append(
                _PageDefLevels([UInt8(1), UInt8(0), UInt8(1), UInt8(1)], 2)
            )
        else:
            # Recorded as all non-null: row 2 reads value 2.
            defs.append(
                _PageDefLevels([UInt8(1), UInt8(1), UInt8(1), UInt8(1)], 4)
            )
        var c = _Nullable(pages^, extents^, defs^, List[_Row]())
        _nullable_raises_with(
            ParquetType.INT32, c, _ivls([0, 4]), 4, "value stream read OOB 12 > 8"
        )


def test_nullable_mismatches_and_unsupported_type_are_refused() raises:
    """Catches: either parallel-list check removed, and a dispatcher that
    gathers a type it has no width for."""
    var a = _nullable_pages(ParquetType.INT32, [2, 2])
    _ = a.extents.pop()
    _nullable_raises_with(
        ParquetType.INT32, a, _ivls([0, 1]), 1, "page_extents length mismatch"
    )
    var b = _nullable_pages(ParquetType.INT32, [2, 2])
    _ = b.defs.pop()
    _nullable_raises_with(
        ParquetType.INT32, b, _ivls([0, 1]), 1, "page_def_levels length mismatch"
    )
    var d = _nullable_pages(ParquetType.INT32, [2])
    _nullable_raises_with(
        ParquetType.BOOLEAN,
        d,
        _ivls([0, 1]),
        1,
        "unsupported fixed-width physical type",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
