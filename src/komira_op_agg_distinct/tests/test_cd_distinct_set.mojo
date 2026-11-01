# =============================================================================
# CdDistinctSet: count(DISTINCT) dedups at INSERT
# =============================================================================
#
# `agg_cd_distinct_set.CdDistinctSet` is the per-worker set of (aggregate
# slot, group, value) pairs the grouped COUNT(DISTINCT) driver probes at
# insert, keeping a running counter per group (a level-1 GROUP BY with no
# aggregate function, one table row per DISTINCT PAIR).
#
# What each test proves:
#   * `admit` must answer True exactly once per distinct pair, and the pair
#     key carries the aggregate slot (two COUNT(DISTINCT)s over two columns
#     cannot share a pair);
#   * the set stores PAIRS, not rows: `count()` is asserted strictly below the
#     rows offered, which a buffer-then-sort implementation (it stores every
#     row) cannot pass, while a distinct-count assertion cannot tell them apart;
#   * `reserve_hint` allocates nothing (the driver calls it serially for every
#     worker; the first `admit` allocates, on the worker);
#   * collisions and growth swallow no pair (an exact count after 200K pairs);
#   * a value whose bit pattern equals the empty-slot sentinel, and the other
#     extreme values, are admitted as ordinary values.
#
# The same set through the driver (NULL rows, all-NULL groups, two aggregates,
# the output row count) is tested with the driver.
#
# The oracle is computed in the test from the raw values, never from another
# kernel.
# =============================================================================

from std.collections import Dict, List, Set
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_op_agg_distinct.agg_cd_distinct_set import (
    CdDistinctSet,
    cd_pair_tag,
)


# Rows at or above this take the PARALLEL driver (`_PARALLEL_CD_MIN_ROWS` is
# 65_536). Asserted, never assumed — see `_run_parallel`.
comptime _ABOVE: Int = 70_000
comptime _WORKERS: Int = 4

# The payload stored in the DATA word of a NULL row. Appears nowhere else in
# any value column built here, so a null-blind kernel would answer EXACTLY one
# too high rather than coincidentally right.
comptime _NULL_PAYLOAD: Int64 = -777_777


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


# =============================================================================
# 1. THE ROUTE WITNESS — the set stores PAIRS, and a buffer stores ROWS
# =============================================================================


def test_admit_returns_true_exactly_once_per_distinct_pair() raises:
    """The whole contract of `CdDistinctSet`, stated directly."""
    var s = CdDistinctSet()
    var t = cd_pair_tag(0, 7)
    assert_true(s.admit(t, Int64(42)), "first insert of (0,7,42)")
    assert_false(s.admit(t, Int64(42)), "repeat of (0,7,42)")
    assert_false(s.admit(t, Int64(42)), "repeat again")
    assert_true(s.admit(t, Int64(43)), "different VALUE, same group")
    assert_true(
        s.admit(cd_pair_tag(0, 8), Int64(42)),
        "different GROUP, same value",
    )
    assert_true(
        s.admit(cd_pair_tag(1, 7), Int64(42)),
        "different AGG SLOT, same group and value — the slot is part of the"
        " key, or two aggregates over two columns would share one set",
    )
    assert_equal(s.count(), 4, "four distinct pairs, six admit calls")


def test_stored_pairs_are_strictly_fewer_than_rows_offered() raises:
    """★ THE MECHANISM WITNESS, and the only assertion in this file that the
    OLD buffer-then-sort implementation could not pass.

    100,000 rows drawn from 250 distinct values in one group. A shape that
    buffers every row stores 100,000 Ints; this one stores 250 pairs. The
    assertion is on the STORED COUNT, so it is RED for any implementation that
    defers the dedup — a distinct-count assertion is not, because both shapes
    return 250.
    """
    var s = CdDistinctSet()
    var t = cd_pair_tag(0, 0)
    var rows = 100_000
    var distinct_vals = 250
    for i in range(rows):
        _ = s.admit(t, Int64(i % distinct_vals))
    assert_equal(
        s.count(), distinct_vals,
        "the set must hold one slot per DISTINCT PAIR, not one per row",
    )
    assert_true(
        s.count() * 100 < rows,
        "★ stored pairs (" + String(s.count()) + ") must be far below rows"
        " offered (" + String(rows) + ") — if this ever reads `== rows` the"
        " dedup has moved back out of the insert path",
    )


def test_allocation_is_lazy_until_the_first_admit() raises:
    """`init()` runs in the driver's SERIAL `htinit` loop over K workers
    so `reserve_hint` must allocate nothing. An eager table there
    would add a serial allocation per worker to pay for a table filled in
    parallel."""
    var s = CdDistinctSet()
    s.reserve_hint(1_000_000)
    assert_equal(s.capacity(), 0, "reserve_hint must allocate NOTHING")
    _ = s.admit(cd_pair_tag(0, 0), Int64(1))
    assert_true(s.capacity() > 0, "the first admit allocates")


def test_many_pairs_survive_collisions_and_growth() raises:
    """At 200K pairs the table has grown many times and linear-probe collisions
    are dense. A slot hit that compared only the hash, or only the tag, would
    merge two distinct values and UNDER-count — silently, with no exception and
    no schema violation. The exact expected count is what catches it."""
    var s = CdDistinctSet()
    var groups = 400
    var per_group = 500
    for g in range(groups):
        var t = cd_pair_tag(0, g)
        for v in range(per_group):
            _ = s.admit(t, Int64(v))
    assert_equal(
        s.count(), groups * per_group,
        "every (group, value) pair is distinct, so none may be swallowed",
    )
    # Re-offering every pair must admit nothing.
    for g in range(groups):
        var t = cd_pair_tag(0, g)
        for v in range(per_group):
            assert_false(
                s.admit(t, Int64(v)),
                "re-offered pair was admitted twice at g=" + String(g),
            )
    assert_equal(s.count(), groups * per_group, "count must not have moved")


# 6. NEGATIVE AND EXTREME VALUES — the sentinel's own bit pattern as a VALUE
# =============================================================================
#
# `CdDistinctSet` marks an empty slot with `_CD_EMPTY_TAG = -1` in the TAG word
# and never inspects the VALUE for occupancy, so a negative value is safe BY
# INSPECTION. Until this section no fixture in the tree offered one: every
# value column above is `i % span >= 0`. The values below include -1 (the
# sentinel's exact bit pattern, in the other word), Int64.MIN / Int64.MAX
# (the two ends a signed hash mix or a `>>` can mishandle) and 0.


def _extreme_values() -> List[Int64]:
    var v = List[Int64]()
    v.append(Int64(-1))
    v.append(Int64.MIN)
    v.append(Int64.MAX)
    v.append(Int64(0))
    v.append(Int64(-2))
    v.append(Int64.MIN + 1)
    v.append(Int64.MAX - 1)
    v.append(_NULL_PAYLOAD)
    return v^


def test_the_set_admits_negative_and_extreme_values_as_distinct_pairs() raises:
    """§6a. Set level: each extreme value is its own pair, exactly once, in two
    groups, and a re-offer admits nothing."""
    var vals = _extreme_values()
    var s = CdDistinctSet()
    for g in range(2):
        var t = cd_pair_tag(0, g)
        for i in range(len(vals)):
            assert_true(
                s.admit(t, vals[i]),
                "§6a first offer of value " + String(vals[i]) + " in group "
                + String(g) + " must be admitted",
            )
    for g in range(2):
        var t = cd_pair_tag(0, g)
        for i in range(len(vals)):
            assert_false(
                s.admit(t, vals[i]),
                "§6a re-offer of value " + String(vals[i]) + " in group "
                + String(g) + " was admitted twice",
            )
    assert_equal(
        s.count(), 2 * len(vals),
        "§6a one pair per (group, extreme value) — a value equal to the EMPTY"
        " sentinel's bit pattern must not be mistaken for an empty slot",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
