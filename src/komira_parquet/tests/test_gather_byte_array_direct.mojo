# Direct tests of `gather_byte_array.mojo` beside the welded
# test_gather_byte_array: what both PLAIN BYTE_ARRAY gathers refuse. A page is
# a run of [4-byte little-endian length][bytes] values (parquet-format's
# Encodings.md, PLAIN). Each malformed prefix is refused on the leg of the walk
# that steps over unselected rows and on the leg that reads selected ones,
# with the full PLAIN decode's message naming the VALUE index (which the
# nullable gather counts apart from the row index); a `num_selected` that is
# not the intervals' total, intervals past the last page, def levels shorter
# than the walk, and selected bytes past the Int32 offsets are refused too.
from std.testing import TestSuite, assert_equal, assert_true

from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_parquet_api.types import Encoding

from komira_parquet.gather_byte_array import (
    _gather_plain_byte_array,
    _gather_plain_byte_array_nullable,
)
from komira_parquet.gather_common import _PageDefLevels, _PageExtent
from komira_parquet.selection_vector import SelectionInterval


def _le(mut out: List[UInt8], v: Int, width: Int):
    for k in range(width):
        out.append(UInt8((v >> (8 * k)) & 0xFF))


def _plain(values: List[String]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(values)):
        var b = values[i].as_bytes()
        _le(out, len(b), 4)
        for k in range(len(b)):
            out.append(b[k])
    return out^


def _buf(bytes: List[UInt8]) -> SharedAlignedBuffer[HeapRegion]:
    var buf = OwnedAlignedBuffer(max(len(bytes), 1))
    for i in range(len(bytes)):
        buf.set_typed[UInt8](i, bytes[i])
    buf.set_length(Int64(len(bytes)))
    return SharedAlignedBuffer.from_owned(buf^)


def _ivls(pairs: List[Int]) -> List[SelectionInterval]:
    var out = List[SelectionInterval]()
    for i in range(0, len(pairs), 2):
        out.append(SelectionInterval(UInt32(pairs[i]), UInt32(pairs[i + 1])))
    return out^


struct _Pages(Movable):
    var pages: Slab[SharedAlignedBuffer[HeapRegion]]
    var extents: List[_PageExtent]
    var dl: Slab[_PageDefLevels]

    def __init__(out self):
        self.pages = Slab[SharedAlignedBuffer[HeapRegion]]()
        self.extents = List[_PageExtent]()
        self.dl = Slab[_PageDefLevels]()

    def add(mut self, var page: SharedAlignedBuffer[HeapRegion], defs: List[UInt8]):
        """One page of `len(defs)` rows; `page` holds its non-null values."""
        var nn = 0
        for i in range(len(defs)):
            if defs[i] != 0:
                nn += 1
        self.pages.append(page^)
        self.extents.append(_PageExtent(len(defs), Encoding.PLAIN))
        self.dl.append(_PageDefLevels(defs.copy(), nn))


def _non_null_raises(
    want: String, p: _Pages, intervals: List[SelectionInterval], n: Int
) raises:
    var raised = False
    try:
        _ = _gather_plain_byte_array(p.pages, Span(p.extents), Span(intervals), n)
    except e:
        raised = True
        assert_true(want in String(e), "expected '" + want + "' in: " + String(e))
    assert_true(raised, "no raise; expected: " + want)


def _nullable_raises(
    want: String, p: _Pages, intervals: List[SelectionInterval], n: Int
) raises:
    var raised = False
    try:
        _ = _gather_plain_byte_array_nullable(
            p.pages, Span(p.extents), p.dl, Span(intervals), n
        )
    except e:
        raised = True
        assert_true(want in String(e), "expected '" + want + "' in: " + String(e))
    assert_true(raised, "no raise; expected: " + want)


def _ones(n: Int) -> List[UInt8]:
    return List[UInt8](length=n, fill=UInt8(1))


def _three() -> List[UInt8]:
    return _plain(["ab", "cd", "ef"])  # 18 bytes: values at 0, 6, 12


def _negative(var bytes: List[UInt8], at: Int) -> List[UInt8]:
    bytes[at + 3] = UInt8(0x80)
    return bytes^


def _overrun(var bytes: List[UInt8], at: Int) -> List[UInt8]:
    bytes[at] = UInt8(9)
    return bytes^


def _cut(bytes: List[UInt8], n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(bytes[i])
    return out^


def test_malformed_prefixes_on_both_legs() raises:
    """Value 1 (bytes 6..11) truncated, negative or overrunning: refused
    when value 1 is skipped (select row 2) and when it is selected."""
    var trunc = _cut(_three(), 8)
    var neg = _negative(_three(), 6)
    var over = _overrun(_cut(_three(), 14), 6)
    var msgs: List[String] = [
        "length prefix for value 1 starts at byte 6 but the page holds only 8",
        "value 1 declares a negative length",
        "value 1 declares length 9 but only 4 bytes remain",
    ]
    var pages: List[List[UInt8]] = [trunc^, neg^, over^]
    for k in range(3):
        for leg in range(2):
            # leg 0: skip rows 0-1, select row 2; leg 1: select rows 1-2.
            var iv = _ivls([2, 1]) if leg == 0 else _ivls([1, 2])
            var n = 1 if leg == 0 else 2
            var p = _Pages()
            p.add(_buf(pages[k]), _ones(3))
            _non_null_raises(msgs[k], p, iv, n)
            _nullable_raises(msgs[k], p, iv, n)


def test_nullable_messages_name_the_value_not_the_row() raises:
    """Rows 0 and 2 are null, so row 3 is value 1: its malformed prefix is
    reported as value 1 on both legs."""
    var defs: List[UInt8] = [0, 1, 0, 1, 1]
    var neg = _negative(_three(), 6)
    for leg in range(2):
        var iv = _ivls([4, 1]) if leg == 0 else _ivls([3, 2])
        var n = 1 if leg == 0 else 2
        var p = _Pages()
        p.add(_buf(neg), defs)
        _nullable_raises("value 1 declares a negative length", p, iv, n)


def test_num_selected_must_be_the_intervals_total() raises:
    var p = _Pages()
    p.add(_buf(_three()), _ones(3))
    var iv = _ivls([0, 1, 1, 1])
    for n in range(1, 4, 2):
        var tail = "select 2 rows, not num_selected = " + String(n)
        _non_null_raises("gather byte_array: the selection intervals " + tail, p, iv, n)
        _nullable_raises(
            "gather byte_array nullable: the selection intervals " + tail, p, iv, n
        )


def test_parallel_list_mismatches_are_refused() raises:
    var p = _Pages()
    p.add(_buf(_three()), _ones(3))
    p.add(_buf(_three()), _ones(3))
    _ = p.pages.pop()
    var iv = _ivls([0, 1])
    _non_null_raises("page_buffers/page_extents length mismatch: 1 vs 2", p, iv, 1)
    _nullable_raises("page_buffers/page_extents mismatch: 1 vs 2", p, iv, 1)
    var q = _Pages()
    q.add(_buf(_three()), _ones(3))
    q.add(_buf(_three()), _ones(3))
    _ = q.dl.pop()
    _nullable_raises("page_buffers/page_def_levels mismatch: 2 vs 1", q, iv, 1)


def test_intervals_past_the_last_page_are_refused() raises:
    """A skip past every page stops the walk at the top of its loop; a select
    off the end stops it after the last page; no pages at all."""
    var p = _Pages()
    p.add(_buf(_three()), _ones(3))
    _non_null_raises("0 of 1 selected rows exist", p, _ivls([4, 1]), 1)
    _nullable_raises("0 of 1 selected rows exist", p, _ivls([4, 1]), 1)
    _nullable_raises("1 of 2 selected rows exist", p, _ivls([2, 2]), 2)
    var none = _Pages()
    _non_null_raises("0 of 1 selected rows exist", none, _ivls([0, 1]), 1)
    _nullable_raises("0 of 1 selected rows exist", none, _ivls([0, 1]), 1)


def test_a_skip_past_a_page_end_moves_to_the_next_page() raises:
    """Pages ["ab", "cd", "ef"] and ["gh", "ij", "kl"]: select row 0, then
    skip 3, which lands past the end of page 0, so the walk moves to page 1 at
    the top of its loop (its byte cursor back to 0) and selects page 1's row 1,
    "ij". Nullable, with page 1's row 0 null, the same row is page 1's value 0,
    "gh"."""
    var p = _Pages()
    p.add(_buf(_three()), _ones(3))
    p.add(_buf(_plain(["gh", "ij", "kl"])), _ones(3))
    var iv = _ivls([0, 1, 3, 1])
    var col = _gather_plain_byte_array(p.pages, Span(p.extents), Span(iv), 2)
    assert_equal(col.as_string().get(0), "ab")
    assert_equal(col.as_string().get(1), "ij")
    var q = _Pages()
    q.add(_buf(_three()), _ones(3))
    q.add(_buf(_plain(["gh", "ij"])), [0, 1, 1])
    var col2 = _gather_plain_byte_array_nullable(
        q.pages, Span(q.extents), q.dl, Span(iv), 2
    )
    var arr = col2.as_string()
    assert_equal(arr.get(0), "ab")
    assert_equal(arr.get(1), "gh")
    assert_equal(arr.null_count, 0)


def test_def_levels_shorter_than_the_walk_are_refused() raises:
    var p = _Pages()
    p.add(_buf(_three()), _ones(3))
    p.extents[0] = _PageExtent(5, Encoding.PLAIN)
    _nullable_raises(
        "page 0 carries 3 def levels, the walk needs row 3", p, _ivls([1, 3]), 3
    )


def test_selected_bytes_past_int32_offsets_are_refused() raises:
    """Three pages that share one 768 MiB buffer holding one value of
    768 MiB - 4 bytes: two selected values fit the Int32 offsets
    (1,610,612,728 bytes), the third (2,415,919,092) does not and is refused
    before any body is copied. The buffer's body is never written."""
    comptime L = 768 << 20
    var owned = OwnedAlignedBuffer(L)
    var prefix = List[UInt8]()
    _le(prefix, L - 4, 4)
    for i in range(4):
        owned.set_typed[UInt8](i, prefix[i])
    owned.set_length(Int64(L))
    var shared = SharedAlignedBuffer.from_owned(owned^)
    var p = _Pages()
    for _ in range(3):
        p.add(shared.share(), _ones(1))
    var want = "selected values total 2415919092 bytes, past the Int32"
    _non_null_raises(want, p, _ivls([0, 3]), 3)
    _nullable_raises(want, p, _ivls([0, 3]), 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
