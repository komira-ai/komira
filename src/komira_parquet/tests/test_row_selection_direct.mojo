# =============================================================================
# RowSelection, RowInterval, IntervalCursor.
#
# The oracle is a per-row bitmap: a selection expands to one Bool per row,
# and every operation is checked against the same operation on bitmaps,
# over a sweep of generated selections (a fixed LCG, so the cases are the
# same on every run) as well as hand-written cases.
#
# What each test proves:
#   * intersect equals the AND of the two bitmaps, and its result keeps the
#     merge invariant (no interval after the first has skip 0);
#   * intersect_mask keeps exactly the selected rows whose mask bit is set,
#     and a null mask entry deselects its row, as does a missing one;
#   * from_mask selects the set, non-null rows; a null whose data bit is
#     set does not select its row (a filter keeps only TRUE);
#   * to_column_intervals clipped to a page equals the page's slice of the
#     bitmap, for pages that start and end inside skips and selects;
#   * from_page_mask adds skipped pages into the next skip and drops
#     trailing ones; it refuses spans of different lengths;
#   * selects_all(num_rows) is True only for one interval covering every
#     row: a selection with unselected trailing rows is not "all";
#   * the cursor walks skip then select phases, caps at n, and settles
#     past empty phases.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.boolean_array import BooleanArray
from komira_parquet.row_selection import IntervalCursor, RowInterval, RowSelection


def _bits(sel: RowSelection, n: Int) -> List[Bool]:
    var out = List[Bool]()
    for _ in range(n):
        out.append(False)
    var pos = 0
    for i in range(len(sel.intervals)):
        pos += Int(sel.intervals[i].skip)
        for _ in range(Int(sel.intervals[i].select)):
            if pos < n:
                out[pos] = True
            pos += 1
    return out^


def _merged(sel: RowSelection) -> Bool:
    for i in range(1, len(sel.intervals)):
        if sel.intervals[i].skip == 0:
            return False
    return True


struct _Lcg(Movable):
    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed

    def next(mut self, bound: Int) -> Int:
        self.state = self.state * 6364136223846793005 + 1442695040888963407
        return Int((self.state >> 33) % UInt64(bound))


def _random_selection(mut rng: _Lcg, n: Int) -> RowSelection:
    var ivls = List[RowInterval]()
    var pos = 0
    while pos < n:
        var skip = rng.next(5)
        var sel = rng.next(5)
        if pos + skip + sel > n:
            break
        ivls.append(RowInterval(UInt64(skip), UInt64(sel)))
        pos += skip + sel
    return RowSelection.from_intervals(ivls^)


def _mask(bits: List[Bool]) -> BooleanArray:
    var arr = BooleanArray.allocate(len(bits))
    for i in range(len(bits)):
        arr.set(i, bits[i])
    return arr^


def test_intersect_matches_the_bitmap_and() raises:
    var rng = _Lcg(7)
    var n = 40
    for _ in range(200):
        var a = _random_selection(rng, n)
        var b = _random_selection(rng, n)
        var c = a.intersect(b)
        var ba = _bits(a, n)
        var bb = _bits(b, n)
        var bc = _bits(c, n)
        for r in range(n):
            assert_equal(bc[r], ba[r] and bb[r], "row " + String(r))
        assert_true(_merged(c))


def test_intersect_hand_cases() raises:
    var a = RowSelection.from_intervals([RowInterval(0, 6)])
    var b = RowSelection.from_intervals([RowInterval(3, 6)])
    var c = a.intersect(b)
    assert_equal(len(c.intervals), 1)
    assert_equal(Int(c.intervals[0].skip), 3)
    assert_equal(Int(c.intervals[0].select), 3)
    var disjoint = RowSelection.from_intervals([RowInterval(0, 3)]).intersect(
        RowSelection.from_intervals([RowInterval(3, 3)])
    )
    assert_equal(Int(disjoint.num_selected()), 0)
    assert_equal(Int(a.intersect(RowSelection.none()).num_selected()), 0)


def test_intersect_mask_keeps_the_selected_rows_whose_bit_is_set() raises:
    var rng = _Lcg(11)
    var n = 30
    for _ in range(100):
        var sel = _random_selection(rng, n)
        var k = Int(sel.num_selected())
        var mbits = List[Bool]()
        for _ in range(k):
            mbits.append(rng.next(2) == 1)
        var out = sel.intersect_mask(_mask(mbits))
        var before = _bits(sel, n)
        var after = _bits(out, n)
        var j = 0
        for r in range(n):
            var want = False
            if before[r]:
                want = mbits[j]
                j += 1
            assert_equal(after[r], want, "row " + String(r))
        assert_true(_merged(out))


def test_intersect_mask_nulls_and_a_short_mask_deselect() raises:
    var sel = RowSelection.from_intervals([RowInterval(1, 4)])
    var m = BooleanArray.allocate_nullable(3)
    m.set(0, True)
    m.set(1, True)  # data bit set, but null below
    m.set(2, True)
    m.validity.value().clear(1)
    var out = sel.intersect_mask(m)
    # Selected rows 1..4 take mask bits T, null, T, (missing).
    var got = _bits(out, 6)
    assert_false(got[0])
    assert_true(got[1])
    assert_false(got[2])
    assert_true(got[3])
    assert_false(got[4])


def test_from_mask_selects_set_non_null_rows() raises:
    var bits: List[Bool] = [True, True, True, False, False, True, True]
    var sel = RowSelection.from_mask(_mask(bits))
    assert_equal(len(sel.intervals), 2)
    assert_equal(Int(sel.intervals[0].skip), 0)
    assert_equal(Int(sel.intervals[0].select), 3)
    assert_equal(Int(sel.intervals[1].skip), 2)
    assert_equal(Int(sel.intervals[1].select), 2)

    var m = BooleanArray.allocate_nullable(4)
    m.set(0, True)
    m.set(1, True)
    m.set(3, True)
    m.validity.value().clear(1)  # NULL: its row is not selected
    var got = _bits(RowSelection.from_mask(m), 4)
    assert_true(got[0])
    assert_false(got[1])
    assert_false(got[2])
    assert_true(got[3])


def test_to_column_intervals_matches_the_page_slice() raises:
    var rng = _Lcg(23)
    var n = 36
    for _ in range(120):
        var sel = _random_selection(rng, n)
        var all_bits = _bits(sel, n)
        var first = rng.next(n)
        var count = rng.next(n - first) + 1
        var out = List[RowInterval]()
        sel.to_column_intervals(UInt64(first), UInt64(count), out)
        var page = RowSelection.from_intervals(out^)
        assert_true(Int(page.total_rows()) <= count)
        var got = _bits(page, count)
        for r in range(count):
            assert_equal(got[r], all_bits[first + r], "page row " + String(r))


def test_to_column_intervals_hand_cases() raises:
    var sel = RowSelection.from_intervals([RowInterval(5, 5)])
    var out = List[RowInterval]()
    sel.to_column_intervals(UInt64(3), UInt64(10), out)
    assert_equal(len(out), 1)
    assert_equal(Int(out[0].skip), 2)
    assert_equal(Int(out[0].select), 5)
    var none_out = List[RowInterval]()
    RowSelection.from_intervals([RowInterval(10, 5)]).to_column_intervals(UInt64(0), UInt64(3), none_out)
    assert_equal(len(none_out), 0)


def test_from_page_mask() raises:
    var inc: List[Bool] = [True, False, True]
    var counts: List[UInt64] = [100, 200, 300]
    var sel = RowSelection.from_page_mask(Span(inc), Span(counts))
    assert_equal(len(sel.intervals), 2)
    assert_equal(Int(sel.intervals[1].skip), 200)
    assert_equal(Int(sel.intervals[1].select), 300)
    var all_in: List[Bool] = [True, True, True]
    assert_equal(len(RowSelection.from_page_mask(Span(all_in), Span(counts)).intervals), 1)
    var edges: List[Bool] = [False, True, False]
    var e = RowSelection.from_page_mask(Span(edges), Span(counts))
    assert_equal(len(e.intervals), 1)
    assert_equal(Int(e.intervals[0].skip), 100)
    assert_equal(Int(e.intervals[0].select), 200)
    var short: List[Bool] = [True]
    with assert_raises(contains="same length"):
        _ = RowSelection.from_page_mask(Span(short), Span(counts))


def test_selects_all_needs_every_row() raises:
    assert_true(RowSelection.all(UInt64(100)).selects_all(UInt64(100)))
    assert_false(RowSelection.none().selects_all(UInt64(100)))
    # Page 2 of 2 skipped: one interval from row 0, but not every row.
    var inc: List[Bool] = [True, False]
    var counts: List[UInt64] = [100, 100]
    var sel = RowSelection.from_page_mask(Span(inc), Span(counts))
    assert_equal(len(sel.intervals), 1)
    assert_false(sel.selects_all(UInt64(200)))
    assert_true(sel.selects_all(UInt64(100)))


def test_cursor_phases() raises:
    var ivls: List[RowInterval] = [RowInterval(10, 5), RowInterval(0, 0), RowInterval(1, 2)]
    var cur = IntervalCursor(Span(ivls))
    var consumed: UInt64 = 0
    var selecting = False
    cur.consume_phase(UInt64(3), consumed, selecting)
    assert_equal(Int(consumed), 3)
    assert_false(selecting)
    cur.consume_phase(UInt64(100), consumed, selecting)
    assert_equal(Int(consumed), 7)
    assert_false(selecting)
    cur.consume_phase(UInt64(100), consumed, selecting)
    assert_equal(Int(consumed), 5)
    assert_true(selecting)
    # The empty (0, 0) interval is passed over.
    cur.consume_phase(UInt64(100), consumed, selecting)
    assert_equal(Int(consumed), 1)
    assert_false(selecting)
    cur.consume_phase(UInt64(100), consumed, selecting)
    assert_equal(Int(consumed), 2)
    assert_true(selecting)
    cur.consume_phase(UInt64(100), consumed, selecting)
    assert_equal(Int(consumed), 0)
    assert_true(cur.exhausted())
    var empty = List[RowInterval]()
    var cur2 = IntervalCursor(Span(empty))
    assert_true(cur2.exhausted())
    assert_false(cur2.is_selecting())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
