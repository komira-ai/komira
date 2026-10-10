# =============================================================================
# Tests for the decode-gather: PLAIN ByteArray (string) gather
# =============================================================================
#
# Covers:
#   - malformed pages: a truncated prefix, a body overrunning the page, and a
#     negative length all RAISE (same messages as the full decode) on both the
#     SKIP and the SELECT legs of the walk — never clamped to a silent
#     zero-length row.
#   - a pseudo-random differential over mixed empty / short / >64-byte values,
#     several pages, and selections {none, all, every k-th, one-per-page, LCG}
#     against a positional reference gather, non-null AND nullable.
#   - _gather_plain_byte_array: non-null path with empty, short, long strings,
#     selection intervals (sorted, repeated, single-row, empty,
#     spanning-multiple-pages).
#   - _gather_plain_byte_array_nullable: all-non-null fast-equiv, all-null,
#     alternating, random ratios, cross-page.
#   - Cross-page byte-exact comparison vs full-decode reference (Python-style
#     gather over a fully-decoded Vec<String>).
# =============================================================================

from std.testing import (
    TestSuite, assert_equal, assert_true, assert_false, assert_raises,
)

from komira_arrow.string_array import StringArray
from komira_arrow.column import Column
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab

from komira_parquet.gather_common import _PageExtent, _PageDefLevels
from komira_parquet.gather_byte_array import (
    _gather_plain_byte_array,
    _gather_plain_byte_array_nullable,
)
from komira_parquet_api.types import (
    Encoding,
    ParquetType,
)
from komira_parquet.selection_vector import SelectionInterval


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _build_byte_array_page(
    values: List[String],
) -> SharedAlignedBuffer[HeapRegion]:
    """Build a PLAIN ByteArray page: each value is [4-byte LE len][bytes].

    Returns a SharedAlignedBuffer[HeapRegion] — the gather APIs migrated
    page_buffers from Owned→Shared aligned buffer, so
    the page builder promotes its owned builder buffer before returning.
    """
    var total_bytes = 0
    for i in range(len(values)):
        total_bytes += 4 + values[i].byte_length()
    var buf = OwnedAlignedBuffer(max(total_bytes, 1))
    var ptr = buf.view_typed_mut[DType.uint8]()
    var pos: Int = 0
    for i in range(len(values)):
        var s = values[i]
        var n = s.byte_length()
        ptr[pos] = UInt8(n & 0xFF)
        ptr[pos + 1] = UInt8((n >> 8) & 0xFF)
        ptr[pos + 2] = UInt8((n >> 16) & 0xFF)
        ptr[pos + 3] = UInt8((n >> 24) & 0xFF)
        pos += 4
        if n > 0:
            var src = s.unsafe_ptr().bitcast[UInt8]()
            for b in range(n):
                ptr[pos + b] = src[b]
        pos += n
    buf.set_length(Int64(total_bytes))

    return SharedAlignedBuffer.from_owned(buf^)


def _string_at(arr: StringArray, idx: Int) raises -> String:
    return arr.get(idx)


def _full_decode(values: List[String]) -> List[String]:
    """Identity reference — for non-null pages, full-decode just returns
    the input. We use this name to mirror the 'full-decode-then-gather'
    reference path used in fixed-width tests."""
    var out = List[String]()
    for i in range(len(values)):
        out.append(values[i])
    return out^


def _gather_reference_non_null(
    pages: List[List[String]],
    intervals: List[SelectionInterval],
) -> List[String]:
    """Reference gather: concat all pages, then walk intervals positionally."""
    var flat = List[String]()
    for p in range(len(pages)):
        ref page = pages[p]
        for i in range(len(page)):
            flat.append(page[i])
    var out = List[String]()
    var pos: Int = 0
    for ivl_i in range(len(intervals)):
        ref ivl = intervals[ivl_i]
        pos += Int(ivl.skip)
        for r in range(Int(ivl.select)):
            if pos + r < len(flat):
                out.append(flat[pos + r])
        pos += Int(ivl.select)
    return out^


# ---------------------------------------------------------------------------
# Malformed pages RAISE — on the SKIP leg and on the SELECT leg
# ---------------------------------------------------------------------------


def _build_byte_array_page_cut(
    values: List[String], keep_bytes: Int,
) -> SharedAlignedBuffer[HeapRegion]:
    """A PLAIN ByteArray page whose readable length is cut to `keep_bytes`."""
    var total_bytes = 0
    for i in range(len(values)):
        total_bytes += 4 + values[i].byte_length()
    var buf = OwnedAlignedBuffer(max(total_bytes, 1))
    var ptr = buf.view_typed_mut[DType.uint8]()
    var pos: Int = 0
    for i in range(len(values)):
        var s = values[i]
        var n = s.byte_length()
        ptr[pos] = UInt8(n & 0xFF)
        ptr[pos + 1] = UInt8((n >> 8) & 0xFF)
        ptr[pos + 2] = UInt8((n >> 16) & 0xFF)
        ptr[pos + 3] = UInt8((n >> 24) & 0xFF)
        pos += 4
        var src = s.unsafe_ptr().bitcast[UInt8]()
        for b in range(n):
            ptr[pos + b] = src[b]
        pos += n
    buf.set_length(Int64(keep_bytes))
    return SharedAlignedBuffer.from_owned(buf^)


def test_gather_byte_array_body_overrun_raises_on_select() raises:
    """Value 0 says 5 bytes but the page holds 7 (4 prefix + 3 body)."""
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_byte_array_page_cut(List[String](["hello", "world"]), 7))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(2, Encoding.PLAIN))
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(0), UInt32(1)))
    with assert_raises(contains="declares length 5 but only 3 bytes remain"):
        _ = _gather_plain_byte_array(pages, Span(extents), Span(intervals), 1)


def test_gather_byte_array_body_overrun_raises_on_skip() raises:
    """The corrupt value is only STEPPED OVER — the skip leg must still
    validate it, or a later selected row would be read from garbage."""
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_byte_array_page_cut(List[String](["hello", "world"]), 7))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(2, Encoding.PLAIN))
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(1), UInt32(1)))
    with assert_raises(contains="declares length 5 but only 3 bytes remain"):
        _ = _gather_plain_byte_array(pages, Span(extents), Span(intervals), 1)


def test_gather_byte_array_truncated_prefix_raises() raises:
    """The page ends inside value 1's length prefix (9 + 2 bytes)."""
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_byte_array_page_cut(List[String](["hello", "world"]), 11))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(2, Encoding.PLAIN))
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(0), UInt32(2)))
    with assert_raises(contains="truncated PLAIN BYTE_ARRAY"):
        _ = _gather_plain_byte_array(pages, Span(extents), Span(intervals), 2)


def test_gather_byte_array_negative_length_raises() raises:
    """A length prefix with the sign bit set is corrupt, not a huge value."""
    var page = _build_byte_array_page(List[String](["abcd", "efgh"]))
    var buf = OwnedAlignedBuffer(page.len())
    var dst = buf.view_typed_mut[DType.uint8]()
    var src = page.view_ro()
    for i in range(page.len()):
        dst[i] = src.get_typed[UInt8](i)
    dst[3] = UInt8(0x80)  # value 0's prefix -> negative Int32
    buf.set_length(Int64(page.len()))
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(SharedAlignedBuffer.from_owned(buf^))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(2, Encoding.PLAIN))
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(0), UInt32(1)))
    with assert_raises(contains="declares a negative length"):
        _ = _gather_plain_byte_array(pages, Span(extents), Span(intervals), 1)


def test_gather_byte_array_intervals_past_last_page_raise() raises:
    """Asking for more rows than the pages hold is an error, never a row of
    uninitialised offsets."""
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_byte_array_page(List[String](["a", "b"])))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(2, Encoding.PLAIN))
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(1), UInt32(3)))
    with assert_raises(contains="overrun the column's pages"):
        _ = _gather_plain_byte_array(pages, Span(extents), Span(intervals), 3)


# ---------------------------------------------------------------------------
# Pseudo-random differential against the positional reference
# ---------------------------------------------------------------------------


def _lcg(mut state: UInt64) -> UInt64:
    state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
    return state >> 33


def _diff_value(i: Int, mut state: UInt64) -> String:
    """Empty, short, and >64-byte values (the copy primitive's size arms)."""
    var kind = Int(_lcg(state) % 5)
    if kind == 0:
        return String("")
    var n = 1 + Int(_lcg(state) % 7)
    if kind == 4:
        n = 60 + Int(_lcg(state) % 90)
    var out = String("r") + String(i) + "_"
    for j in range(n):
        out += chr(Int(97 + (i + j) % 26))
    return out^


def _intervals_from_flags(flags: List[Bool]) -> List[SelectionInterval]:
    var out = List[SelectionInterval]()
    var skip = 0
    var i = 0
    while i < len(flags):
        if not flags[i]:
            skip += 1
            i += 1
            continue
        var run = 0
        while i < len(flags) and flags[i]:
            run += 1
            i += 1
        out.append(SelectionInterval(UInt32(skip), UInt32(run)))
        skip = 0
    return out^


def _selection_patterns(total: Int, page_rows: Int) -> List[List[Bool]]:
    var pats = List[List[Bool]]()
    var none = List[Bool]()
    var all_ = List[Bool]()
    var third = List[Bool]()
    var one_per_page = List[Bool]()
    var lcg = List[Bool]()
    var state = UInt64(0x9E3779B97F4A7C15)
    for r in range(total):
        none.append(False)
        all_.append(True)
        third.append(r % 3 == 1)
        one_per_page.append(r % page_rows == page_rows - 1)
        lcg.append(_lcg(state) % 8 == 0)  # ~12.5%, a selective filter
    pats.append(none^)
    pats.append(all_^)
    pats.append(third^)
    pats.append(one_per_page^)
    pats.append(lcg^)
    return pats^


def test_gather_byte_array_differential_matches_reference() raises:
    comptime NPAGES = 3
    comptime PAGE_ROWS = 97
    var state = UInt64(12345)
    var flat = List[String]()
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    var extents = List[_PageExtent]()
    for p in range(NPAGES):
        var vals = List[String]()
        for r in range(PAGE_ROWS):
            var v = _diff_value(p * PAGE_ROWS + r, state)
            vals.append(v)
            flat.append(v)
        pages.append(_build_byte_array_page(vals))
        extents.append(_PageExtent(PAGE_ROWS, Encoding.PLAIN))
    var pats = _selection_patterns(NPAGES * PAGE_ROWS, PAGE_ROWS)
    for pi in range(len(pats)):
        ref flags = pats[pi]
        var intervals = _intervals_from_flags(flags)
        var want = List[String]()
        for r in range(len(flags)):
            if flags[r]:
                want.append(flat[r])
        var col = _gather_plain_byte_array(
            pages, Span(extents), Span(intervals), len(want),
        )
        var arr = col.as_string()
        assert_equal(arr.length, len(want))
        assert_equal(arr.null_count, 0)
        for i in range(len(want)):
            assert_equal(arr.get(i), want[i])


def test_gather_byte_array_nullable_differential_matches_reference() raises:
    comptime NPAGES = 3
    comptime PAGE_ROWS = 89
    var state = UInt64(777)
    var flat = List[String]()
    var flat_null = List[Bool]()
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    var extents = List[_PageExtent]()
    var dl = Slab[_PageDefLevels]()
    for p in range(NPAGES):
        var defs = List[UInt8]()
        var non_null = List[String]()
        for r in range(PAGE_ROWS):
            var is_null = _lcg(state) % 4 == 0
            var v = _diff_value(p * PAGE_ROWS + r, state)
            flat.append(v)
            flat_null.append(is_null)
            if is_null:
                defs.append(UInt8(0))
            else:
                defs.append(UInt8(1))
                non_null.append(v)
        pages.append(_build_byte_array_page(non_null))
        extents.append(_PageExtent(PAGE_ROWS, Encoding.PLAIN))
        dl.append(_build_def_levels(defs))
    var pats = _selection_patterns(NPAGES * PAGE_ROWS, PAGE_ROWS)
    for pi in range(len(pats)):
        ref flags = pats[pi]
        var intervals = _intervals_from_flags(flags)
        var want_rows = List[Int]()
        for r in range(len(flags)):
            if flags[r]:
                want_rows.append(r)
        var col = _gather_plain_byte_array_nullable(
            pages, Span(extents), dl, Span(intervals), len(want_rows),
        )
        var arr = col.as_string()
        assert_equal(arr.length, len(want_rows))
        var nulls = 0
        for i in range(len(want_rows)):
            var r = want_rows[i]
            if flat_null[r]:
                nulls += 1
                assert_true(arr.is_null(i))
                assert_equal(arr.get_length(i), 0)
            else:
                assert_false(arr.is_null(i))
                assert_equal(arr.get(i), flat[r])
        assert_equal(arr.null_count, nulls)


# ---------------------------------------------------------------------------
# Non-null gather tests
# ---------------------------------------------------------------------------


def test_gather_byte_array_select_all_single_page() raises:
    """All rows selected in one page -> output == input strings."""
    var values = List[String](["alpha", "beta", "gamma", "delta"])
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_byte_array_page(values))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(4, Encoding.PLAIN))
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(0), UInt32(4)))

    var col = _gather_plain_byte_array(pages, Span(extents), Span(intervals), 4)
    assert_equal(col.length(), 4)
    var arr = col.as_string()
    assert_equal(arr.get(0), String("alpha"))
    assert_equal(arr.get(1), String("beta"))
    assert_equal(arr.get(2), String("gamma"))
    assert_equal(arr.get(3), String("delta"))


def test_gather_byte_array_skip_then_select() raises:
    """skip=2 select=3 from a 6-row page."""
    var values = List[String](["a0", "a1", "a2", "a3", "a4", "a5"])
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_byte_array_page(values))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(6, Encoding.PLAIN))
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(2), UInt32(3)))

    var col = _gather_plain_byte_array(pages, Span(extents), Span(intervals), 3)
    var arr = col.as_string()
    assert_equal(arr.get(0), String("a2"))
    assert_equal(arr.get(1), String("a3"))
    assert_equal(arr.get(2), String("a4"))


def test_gather_byte_array_empty_intervals() raises:
    """Zero intervals -> length-0 StringArray."""
    var values = List[String](["a", "b"])
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_byte_array_page(values))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(2, Encoding.PLAIN))
    var intervals = List[SelectionInterval]()

    var col = _gather_plain_byte_array(pages, Span(extents), Span(intervals), 0)
    assert_equal(col.length(), 0)


def test_gather_byte_array_single_row_at_page_boundary() raises:
    """Pick exactly the last row of page 0."""
    var p1 = List[String](["p1a", "p1b", "p1c"])
    var p2 = List[String](["p2a", "p2b"])
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_byte_array_page(p1))
    pages.append(_build_byte_array_page(p2))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(3, Encoding.PLAIN))
    extents.append(_PageExtent(2, Encoding.PLAIN))
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(2), UInt32(1)))

    var col = _gather_plain_byte_array(pages, Span(extents), Span(intervals), 1)
    var arr = col.as_string()
    assert_equal(arr.get(0), String("p1c"))


def test_gather_byte_array_cross_page_interval() raises:
    """One interval spans two pages — page-advance code path."""
    var p1 = List[String](["aa", "bb", "cc"])
    var p2 = List[String](["dd", "ee", "ff"])
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_byte_array_page(p1))
    pages.append(_build_byte_array_page(p2))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(3, Encoding.PLAIN))
    extents.append(_PageExtent(3, Encoding.PLAIN))
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(1), UInt32(4)))  # rows 1..4

    var col = _gather_plain_byte_array(pages, Span(extents), Span(intervals), 4)
    var arr = col.as_string()
    assert_equal(arr.get(0), String("bb"))
    assert_equal(arr.get(1), String("cc"))
    assert_equal(arr.get(2), String("dd"))
    assert_equal(arr.get(3), String("ee"))


def test_gather_byte_array_long_strings() raises:
    """Mix of long (1K+) and short strings — tests data buffer sizing."""
    var long_s = String("")
    for _ in range(1500):
        long_s += "L"
    var values = List[String](["short", long_s, "tiny", "x"])
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_byte_array_page(values))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(4, Encoding.PLAIN))
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(1), UInt32(2)))  # long_s, "tiny"

    var col = _gather_plain_byte_array(pages, Span(extents), Span(intervals), 2)
    var arr = col.as_string()
    assert_equal(arr.get_length(0), 1500)
    assert_equal(arr.get(0), long_s)
    assert_equal(arr.get(1), String("tiny"))


def test_gather_byte_array_empty_strings_mixed() raises:
    """Empty values interleaved with non-empty; ensure offsets advance correctly."""
    var values = List[String](["", "a", "", "bb", ""])
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_byte_array_page(values))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(5, Encoding.PLAIN))
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(0), UInt32(5)))

    var col = _gather_plain_byte_array(pages, Span(extents), Span(intervals), 5)
    var arr = col.as_string()
    assert_equal(arr.get_length(0), 0)
    assert_equal(arr.get(1), String("a"))
    assert_equal(arr.get_length(2), 0)
    assert_equal(arr.get(3), String("bb"))
    assert_equal(arr.get_length(4), 0)


def test_gather_byte_array_multiple_intervals_multi_page() raises:
    """Three pages, four intervals — byte-exact vs reference."""
    var p1 = List[String](["a", "b", "c", "d"])
    var p2 = List[String](["e", "f", "g", "h"])
    var p3 = List[String](["i", "j", "k", "l"])
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_byte_array_page(p1))
    pages.append(_build_byte_array_page(p2))
    pages.append(_build_byte_array_page(p3))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(4, Encoding.PLAIN))
    extents.append(_PageExtent(4, Encoding.PLAIN))
    extents.append(_PageExtent(4, Encoding.PLAIN))
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(1), UInt32(1)))  # b
    intervals.append(SelectionInterval(UInt32(1), UInt32(2)))  # d, e
    intervals.append(SelectionInterval(UInt32(1), UInt32(1)))  # g
    intervals.append(SelectionInterval(UInt32(2), UInt32(2)))  # j, k

    var col = _gather_plain_byte_array(pages, Span(extents), Span(intervals), 6)
    var arr = col.as_string()
    var page_groups = List[List[String]]()
    page_groups.append(p1.copy())
    page_groups.append(p2.copy())
    page_groups.append(p3.copy())
    var ref_out = _gather_reference_non_null(page_groups, intervals)
    assert_equal(arr.length, len(ref_out))
    for i in range(len(ref_out)):
        assert_equal(arr.get(i), ref_out[i])


# ---------------------------------------------------------------------------
# Nullable gather tests
# ---------------------------------------------------------------------------


def _build_def_levels(defs: List[UInt8]) -> _PageDefLevels:
    var num_non_null = 0
    for i in range(len(defs)):
        if defs[i] != 0:
            num_non_null += 1
    return _PageDefLevels(defs.copy(), num_non_null)


def _build_byte_array_value_stream(
    non_null_values: List[String],
) -> SharedAlignedBuffer[HeapRegion]:
    """Helper: build a value stream containing ONLY the non-null values
    (as the nullable gather expects after def-level stripping)."""
    return _build_byte_array_page(non_null_values)


def test_gather_nullable_all_valid_no_nulls_emitted() raises:
    """def_levels all 1: result is bit-equal to non-null gather and has no validity."""
    var values = List[String](["a", "b", "c"])
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_byte_array_value_stream(values))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(3, Encoding.PLAIN))
    var defs = List[UInt8]([UInt8(1), UInt8(1), UInt8(1)])
    var dl = Slab[_PageDefLevels]()
    dl.append(_build_def_levels(defs))
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(0), UInt32(3)))

    var col = _gather_plain_byte_array_nullable(
        pages, Span(extents), dl, Span(intervals), 3,
    )
    assert_equal(col.length(), 3)
    var arr = col.as_string()
    assert_false(arr.validity.__bool__())
    assert_equal(arr.get(0), String("a"))
    assert_equal(arr.get(1), String("b"))
    assert_equal(arr.get(2), String("c"))


def test_gather_nullable_all_null() raises:
    """Every def_level == 0 -> all-empty strings, all validity bits cleared."""
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_byte_array_value_stream(List[String]()))  # empty stream
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(4, Encoding.PLAIN))
    var defs = List[UInt8]([UInt8(0), UInt8(0), UInt8(0), UInt8(0)])
    var dl = Slab[_PageDefLevels]()
    dl.append(_build_def_levels(defs))
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(0), UInt32(4)))

    var col = _gather_plain_byte_array_nullable(
        pages, Span(extents), dl, Span(intervals), 4,
    )
    assert_equal(col.length(), 4)
    var arr = col.as_string()
    assert_true(arr.validity.__bool__())
    assert_equal(arr.null_count, 4)
    for i in range(4):
        assert_true(arr.is_null(i))
        assert_equal(arr.get_length(i), 0)


def test_gather_nullable_alternating() raises:
    """def_levels = [1,0,1,0,1] -> values stream has 3 entries, gather all 5."""
    var non_null = List[String](["v0", "v2", "v4"])
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_byte_array_value_stream(non_null))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(5, Encoding.PLAIN))
    var defs = List[UInt8]([UInt8(1), UInt8(0), UInt8(1), UInt8(0), UInt8(1)])
    var dl = Slab[_PageDefLevels]()
    dl.append(_build_def_levels(defs))
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(0), UInt32(5)))

    var col = _gather_plain_byte_array_nullable(
        pages, Span(extents), dl, Span(intervals), 5,
    )
    var arr = col.as_string()
    assert_equal(arr.null_count, 2)
    assert_equal(arr.get(0), String("v0"))
    assert_true(arr.is_null(1))
    assert_equal(arr.get(2), String("v2"))
    assert_true(arr.is_null(3))
    assert_equal(arr.get(4), String("v4"))


def test_gather_nullable_partial_select() raises:
    """Skip into a page and select across nulls."""
    var non_null = List[String](["x0", "x2", "x3"])
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_byte_array_value_stream(non_null))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(5, Encoding.PLAIN))
    # row: 0=x0 (non-null), 1=null, 2=x2, 3=x3, 4=null
    var defs = List[UInt8]([UInt8(1), UInt8(0), UInt8(1), UInt8(1), UInt8(0)])
    var dl = Slab[_PageDefLevels]()
    dl.append(_build_def_levels(defs))
    # Select rows 1..4: null, x2, x3, null
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(1), UInt32(4)))

    var col = _gather_plain_byte_array_nullable(
        pages, Span(extents), dl, Span(intervals), 4,
    )
    var arr = col.as_string()
    assert_equal(arr.null_count, 2)
    assert_true(arr.is_null(0))
    assert_equal(arr.get(1), String("x2"))
    assert_equal(arr.get(2), String("x3"))
    assert_true(arr.is_null(3))


def test_gather_nullable_cross_page() raises:
    """Two pages with mixed nulls — interval spans both."""
    var p1_nn = List[String](["p1_0", "p1_2"])             # rows 0,2 valid in p1
    var p2_nn = List[String](["p2_1"])                      # row 1 valid in p2
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_byte_array_value_stream(p1_nn))
    pages.append(_build_byte_array_value_stream(p2_nn))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(3, Encoding.PLAIN))   # p1 has 3 rows
    extents.append(_PageExtent(3, Encoding.PLAIN))   # p2 has 3 rows
    var defs1 = List[UInt8]([UInt8(1), UInt8(0), UInt8(1)])
    var defs2 = List[UInt8]([UInt8(0), UInt8(1), UInt8(0)])
    var dl = Slab[_PageDefLevels]()
    dl.append(_build_def_levels(defs1))
    dl.append(_build_def_levels(defs2))
    # Select all 6 rows
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(0), UInt32(6)))

    var col = _gather_plain_byte_array_nullable(
        pages, Span(extents), dl, Span(intervals), 6,
    )
    var arr = col.as_string()
    assert_equal(arr.null_count, 3)
    assert_equal(arr.get(0), String("p1_0"))
    assert_true(arr.is_null(1))
    assert_equal(arr.get(2), String("p1_2"))
    assert_true(arr.is_null(3))
    assert_equal(arr.get(4), String("p2_1"))
    assert_true(arr.is_null(5))


def test_gather_nullable_random_50pct() raises:
    """50% null density, 32 rows. Checks rank table sweep."""
    var defs = List[UInt8]()
    var non_null = List[String]()
    for i in range(32):
        if i % 2 == 0:
            defs.append(UInt8(1))
            non_null.append(String("v") + String(i))
        else:
            defs.append(UInt8(0))
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_build_byte_array_value_stream(non_null))
    var extents = List[_PageExtent]()
    extents.append(_PageExtent(32, Encoding.PLAIN))
    var dl = Slab[_PageDefLevels]()
    dl.append(_build_def_levels(defs))
    var intervals = List[SelectionInterval]()
    intervals.append(SelectionInterval(UInt32(0), UInt32(32)))

    var col = _gather_plain_byte_array_nullable(
        pages, Span(extents), dl, Span(intervals), 32,
    )
    var arr = col.as_string()
    assert_equal(arr.null_count, 16)
    for i in range(32):
        if i % 2 == 0:
            assert_equal(arr.get(i), String("v") + String(i))
        else:
            assert_true(arr.is_null(i))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
