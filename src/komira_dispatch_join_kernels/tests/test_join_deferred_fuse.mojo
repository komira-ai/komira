"""`plan_deferred_work_items`: the work items of the deferred join assembly, item
for item, and the two numbers it reports (`idx_passes`, `fused_pairs`).

Each case writes the expected item list out in full (kind, columns, row range,
in emission order), so a change to the pairing rule, the validity-first order
or the tile arithmetic is a red assertion that names the item.
"""

from std.testing import assert_equal

from komira_dispatch_join_kernels.join_deferred_fuse import (
    DeferredFusePlan,
    _DeferredWork,
    _same_index_list,
    plan_deferred_work_items,
)


comptime V: UInt8 = 0
"""A value tile."""
comptime B: UInt8 = 2
"""A whole-column validity item."""


def _w(col: Int, col_b: Int, kind: UInt8, rs: Int, re: Int) -> _DeferredWork:
    return _DeferredWork(Int32(col), Int32(col_b), kind, rs, re)


def _ints(*vals: Int) -> List[Int]:
    var out = List[Int]()
    for v in vals:
        out.append(v)
    return out^


def _check(
    imm got: List[_DeferredWork],
    imm want: List[_DeferredWork],
    imm tag: String,
) raises:
    assert_equal(len(got), len(want), tag + " item count")
    for i in range(len(want)):
        var t = tag + " item " + String(i)
        assert_equal(Int(got[i].col_idx), Int(want[i].col_idx), t + " col")
        assert_equal(Int(got[i].col_b), Int(want[i].col_b), t + " col_b")
        assert_equal(Int(got[i].kind), Int(want[i].kind), t + " kind")
        assert_equal(got[i].row_start, want[i].row_start, t + " row_start")
        assert_equal(got[i].row_end, want[i].row_end, t + " row_end")


def test_same_index_list_is_the_side() raises:
    """Columns below `probe_ncols` share the probe index, the rest the build
    index, and the boundary column is on the build side.
    MUTANT: `<` changed to `<=` in `_same_index_list`: column 2 of 2 probe
    columns reads as probe-side."""
    assert_equal(_same_index_list(0, 1, 2), True)
    assert_equal(_same_index_list(2, 3, 2), True)
    assert_equal(_same_index_list(1, 2, 2), False)
    assert_equal(_same_index_list(2, 1, 2), False)
    assert_equal(_same_index_list(0, 0, 0), True)


def test_two_columns_per_side_make_two_pairs() raises:
    """Two probe and two build columns of one width: one fused pair per side,
    two index passes, each pair's two validity items before its value tiles.
    MUTANT: the partner's own validity item dropped: items 1 and 5 are
    missing."""
    var items = List[_DeferredWork]()
    var plan = plan_deferred_work_items(
        _ints(-1, -1, -1, -1), _ints(8, 8, 8, 8), 2, 100, 2, items
    )
    assert_equal(plan.idx_passes, 2)
    assert_equal(plan.fused_pairs, 2)
    var want = List[_DeferredWork]()
    want.append(_w(0, -1, B, 0, 100))
    want.append(_w(1, -1, B, 0, 100))
    want.append(_w(0, 1, V, 0, 50))
    want.append(_w(0, 1, V, 50, 100))
    want.append(_w(2, -1, B, 0, 100))
    want.append(_w(3, -1, B, 0, 100))
    want.append(_w(2, 3, V, 0, 50))
    want.append(_w(2, 3, V, 50, 100))
    _check(items, want, "2+2")


def test_no_pair_across_sides() raises:
    """One probe and one build column of one width read different index
    lists, so they are two single-column passes.
    MUTANT: the `_same_index_list(c, e, probe_ncols)` operand dropped from
    the pairing test: columns 0 and 1 fuse."""
    var items = List[_DeferredWork]()
    var plan = plan_deferred_work_items(
        _ints(-1, -1), _ints(8, 8), 1, 10, 1, items
    )
    assert_equal(plan.idx_passes, 2)
    assert_equal(plan.fused_pairs, 0)
    var want = List[_DeferredWork]()
    want.append(_w(0, -1, B, 0, 10))
    want.append(_w(0, -1, V, 0, 10))
    want.append(_w(1, -1, B, 0, 10))
    want.append(_w(1, -1, V, 0, 10))
    _check(items, want, "cross-side")


def test_widths_must_match_and_a_claimed_column_is_skipped() raises:
    """Widths 8, 4, 8, 4 on one side: column 0 pairs with 2, then column 1
    passes over the claimed column 2 and pairs with 3; column 2 and 3 are
    claimed and emit nothing of their own.
    MUTANT: `col_width[c] == col_width[e]` dropped: 0 pairs with 1."""
    var items = List[_DeferredWork]()
    var plan = plan_deferred_work_items(
        _ints(-1, -1, -1, -1), _ints(8, 4, 8, 4), 4, 6, 1, items
    )
    assert_equal(plan.idx_passes, 2)
    assert_equal(plan.fused_pairs, 2)
    var want = List[_DeferredWork]()
    want.append(_w(0, -1, B, 0, 6))
    want.append(_w(2, -1, B, 0, 6))
    want.append(_w(0, 2, V, 0, 6))
    want.append(_w(1, -1, B, 0, 6))
    want.append(_w(3, -1, B, 0, 6))
    want.append(_w(1, 3, V, 0, 6))
    _check(items, want, "widths")


def test_an_aliased_column_emits_nothing_and_an_odd_one_stays_single() raises:
    """Column 1 is a key share of column 0 (`alias_out[1] = 0`): it appears in
    no item and is never a partner. Of the three remaining same-side columns
    the first two pair and the last stays single.
    MUTANT: the `alias_out[e] >= 0` test dropped from the partner search:
    column 0 pairs with the aliased column 1."""
    var items = List[_DeferredWork]()
    var plan = plan_deferred_work_items(
        _ints(-1, 0, -1, -1), _ints(8, 8, 8, 8), 4, 4, 1, items
    )
    assert_equal(plan.idx_passes, 2)
    assert_equal(plan.fused_pairs, 1)
    var want = List[_DeferredWork]()
    want.append(_w(0, -1, B, 0, 4))
    want.append(_w(2, -1, B, 0, 4))
    want.append(_w(0, 2, V, 0, 4))
    want.append(_w(3, -1, B, 0, 4))
    want.append(_w(3, -1, V, 0, 4))
    _check(items, want, "alias")


def test_empty_tiles_are_skipped_and_the_last_tile_ends_the_column() raises:
    """5 rows over 4 tiles: boundaries 0, 1, 2, 3, 5 (the last tile takes the
    remainder). 2 rows over 4 tiles: tiles 0 and 2 are empty and skipped.
    0 rows: no value tile at all, the validity item still emitted.
    MUTANT: `if re <= rs: continue` dropped: empty tiles are emitted."""
    var items = List[_DeferredWork]()
    _ = plan_deferred_work_items(_ints(-1), _ints(8), 1, 5, 4, items)
    var want = List[_DeferredWork]()
    want.append(_w(0, -1, B, 0, 5))
    want.append(_w(0, -1, V, 0, 1))
    want.append(_w(0, -1, V, 1, 2))
    want.append(_w(0, -1, V, 2, 3))
    want.append(_w(0, -1, V, 3, 5))
    _check(items, want, "5 over 4")

    var items2 = List[_DeferredWork]()
    _ = plan_deferred_work_items(_ints(-1), _ints(8), 1, 2, 4, items2)
    var want2 = List[_DeferredWork]()
    want2.append(_w(0, -1, B, 0, 2))
    want2.append(_w(0, -1, V, 0, 1))
    want2.append(_w(0, -1, V, 1, 2))
    _check(items2, want2, "2 over 4")

    var items3 = List[_DeferredWork]()
    var plan3 = plan_deferred_work_items(_ints(-1), _ints(8), 1, 0, 3, items3)
    assert_equal(plan3.idx_passes, 1)
    var want3 = List[_DeferredWork]()
    want3.append(_w(0, -1, B, 0, 0))
    _check(items3, want3, "0 rows")


def test_items_append_after_what_is_there() raises:
    """The planner appends: an item already in the list stays first, and only
    the new items count. An all-aliased plan adds nothing.
    MUTANT: `work_items` cleared on entry: the first item is lost."""
    var items = List[_DeferredWork]()
    items.append(_w(9, -1, V, 7, 8))
    var plan = plan_deferred_work_items(_ints(0), _ints(8), 1, 3, 1, items)
    assert_equal(plan.idx_passes, 0)
    assert_equal(plan.fused_pairs, 0)
    var want = List[_DeferredWork]()
    want.append(_w(9, -1, V, 7, 8))
    _check(items, want, "append")


def main() raises:
    test_same_index_list_is_the_side()
    test_two_columns_per_side_make_two_pairs()
    test_no_pair_across_sides()
    test_widths_must_match_and_a_claimed_column_is_skipped()
    test_an_aliased_column_emits_nothing_and_an_odd_one_stays_single()
    test_empty_tiles_are_skipped_and_the_last_tile_ends_the_column()
    test_items_append_after_what_is_there()
    print("All 7 deferred fuse tests passed.")
