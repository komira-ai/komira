# =============================================================================
# test_cd_radix_grouped_byte_equiv.mojo
#   — the across-groups parallel COUNT(DISTINCT) of a grouped drain
#     (`cd_radix_grouped.radix_distinct_count_grouped`) is EXACT, per group,
#     against an independent per-group serial dedup.
# =============================================================================

from std.collections import List
from std.testing import TestSuite, assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime
from komira_op_agg_distinct.cd_radix_parallel import radix_distinct_count
from komira_op_agg_distinct.cd_radix_grouped import (
    radix_distinct_count_grouped,
    _cd_grouped_count_serial,
)


comptime _N = 300_000


def _make_noop_sink() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


def _make_runtime(n_workers: Int) raises -> PerCoreAsyncRuntime[NoopSink]:
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(n_workers, _make_noop_sink, BACKEND_MOCK)
    rt.start()
    return rt^

# =============================================================================
# PERF-CB-COUNTDISTINCT-GROUPED: the ACROSS-groups parallel emit.
#
# `radix_distinct_count_grouped` fans the typed COUNT(DISTINCT) GROUP BY drain over
# the pool: it SPLITS big groups into value-hash sub-cells and dedups every cell
# in ONE parallel dispatch (one task per cell), reducing sub-cells back into
# their group. The per-group result MUST be byte-identical to the
# independent per-group serial oracle (`_cd_grouped_count_serial`) — the distinct
# count of a group is invariant to (a) the value-hash split of its own values and
# (b) which worker deduped it. These fixtures exercise the group-size shapes the
# grouped COUNT(DISTINCT) queries hit: a "staircase" (many tiny groups + a few
# very large groups) and "few huge groups", plus the split-group falsifiers (a value
# duplicated across sub-cells, or a sub-cell double-counted, would INFLATE the count).
# =============================================================================


def _parallel_count_grouped(imm groups_runs: List[List[List[Int64]]]) raises -> List[Int64]:
    """Drive `radix_distinct_count_grouped` over a real multi-worker dispatcher."""
    var rt = _make_runtime(8)
    ref disp = rt.dispatcher()
    var copy = List[List[List[Int64]]]()
    for g in range(len(groups_runs)):
        var runs = List[List[Int64]]()
        for r in range(len(groups_runs[g])):
            runs.append(groups_runs[g][r].copy())
        copy.append(runs^)
    return radix_distinct_count_grouped(copy^, disp, CancellationToken.new())


def _one_run(imm vals: List[Int64]) -> List[List[Int64]]:
    """Wrap a single value buffer as a one-run group."""
    var runs = List[List[Int64]]()
    runs.append(vals.copy())
    return runs^


def _assert_grouped_equals_oracle(
    imm groups_runs: List[List[List[Int64]]]
) raises:
    """The parallel grouped driver == the independent per-group serial oracle, per
    group, EXACTLY."""
    var oracle = _cd_grouped_count_serial(groups_runs)
    var got = _parallel_count_grouped(groups_runs)
    assert_equal(len(got), len(oracle))
    for g in range(len(oracle)):
        assert_equal(got[g], oracle[g])


def test_grouped_uniform_many_groups() raises:
    """Many uniform groups (each ~equal size, each a distinct value block) -> per-
    group distinct == oracle. The clean load-balanced case; every group is one
    cell (below the split cap)."""
    comptime NG = 500
    comptime PER = 4_000
    var groups = List[List[List[Int64]]]()
    for g in range(NG):
        var buf = List[Int64](capacity=PER)
        for d in range(PER):
            # group g owns [g*PER, g*PER+PER) with each value repeated ~2x
            buf.append(Int64(g * PER + (d % (PER // 2))))
        groups.append(_one_run(buf))
    _assert_grouped_equals_oracle(groups)
    # Spot the invariant: each group has PER/2 distinct.
    var got = _parallel_count_grouped(groups)
    for g in range(NG):
        assert_equal(got[g], Int64(PER // 2))


def test_grouped_staircase_big_and_small() raises:
    """Staircase shape: MANY tiny groups + a FEW big groups that cross the split cap ->
    per-group distinct == oracle. The big groups are split into value-hash sub-cells
    and reduced back; a broken split (a value in two sub-cells, or a double-counted
    sub-cell) would INFLATE those groups above the oracle."""
    var groups = List[List[List[Int64]]]()
    # 400 tiny groups (100 distinct each, repeated 3x).
    for g in range(400):
        var buf = List[Int64](capacity=300)
        for k in range(3):
            _ = k
            for d in range(100):
                buf.append(Int64(g) * Int64(1_000_003) + Int64(d))
        groups.append(_one_run(buf))
    # 3 big groups that cross the split cap (500K, 900K, 1.5M values), each with a
    # known distinct count and heavy duplication (must dedup, not inflate).
    var big_sizes = List[Int]()
    big_sizes.append(500_000)
    big_sizes.append(900_000)
    big_sizes.append(1_500_000)
    var big_distinct = List[Int]()
    big_distinct.append(120_000)
    big_distinct.append(200_000)
    big_distinct.append(400_000)
    for b in range(len(big_sizes)):
        var sz = big_sizes[b]
        var dd = big_distinct[b]
        var buf = List[Int64](capacity=sz)
        for i in range(sz):
            # dd distinct values (offset per group so groups are disjoint), each
            # repeated sz/dd times -> distinct MUST be dd, not sz.
            buf.append(Int64(50_000_000) * Int64(b + 1) + Int64(i % dd))
        groups.append(_one_run(buf))
    _assert_grouped_equals_oracle(groups)
    var got = _parallel_count_grouped(groups)
    for b in range(len(big_sizes)):
        assert_equal(got[400 + b], Int64(big_distinct[b]))


def test_grouped_few_huge_groups() raises:
    """Few-huge-groups shape: a FEW huge groups (each > the split cap) -> per-group distinct
    == oracle. Every group is split across workers; the reduce must sum the sub-cells
    exactly."""
    var groups = List[List[List[Int64]]]()
    comptime HUGE = 1_200_000
    for g in range(6):
        var buf = List[Int64](capacity=HUGE)
        for i in range(HUGE):
            # ~600K distinct (i % 600000), each repeated ~2x, disjoint per group.
            buf.append(Int64(g) * Int64(10_000_000) + Int64(i % 600_000))
        groups.append(_one_run(buf))
    _assert_grouped_equals_oracle(groups)
    var got = _parallel_count_grouped(groups)
    for g in range(6):
        assert_equal(got[g], Int64(600_000))


def test_grouped_multi_run_per_group() raises:
    """Groups whose values arrive as SEVERAL per-worker runs (the concat-free
    combine shape) -> the cross-run union within a group is deduped once. A value in
    two runs of the same group MUST count once (not per run)."""
    var groups = List[List[List[Int64]]]()
    for g in range(50):
        var runs = List[List[Int64]]()
        # 3 runs, all holding the SAME 20K distinct values -> distinct MUST be 20K.
        for _w in range(3):
            var buf = List[Int64](capacity=20_000)
            for d in range(20_000):
                buf.append(Int64(g) * Int64(1_000_003) + Int64(d) * Int64(7))
            runs.append(buf^)
        groups.append(runs^)
    _assert_grouped_equals_oracle(groups)
    var got = _parallel_count_grouped(groups)
    for g in range(50):
        assert_equal(got[g], Int64(20_000))


def test_grouped_big_all_same_no_inflation() raises:
    """A big group full of the SAME single value (crosses the split cap) -> distinct
    MUST be 1, not the split-cell count. The sharpest split falsifier: a value
    duplicated into two sub-cells, or a sub-cell counted twice, would inflate this."""
    var groups = List[List[List[Int64]]]()
    var buf = List[Int64](capacity=2_000_000)
    for _ in range(2_000_000):
        buf.append(Int64(777))
    groups.append(_one_run(buf))
    # A second (tiny) group so ng > 1 and the parallel path engages.
    var b2 = List[Int64]()
    for d in range(100):
        b2.append(Int64(d))
    groups.append(_one_run(b2))
    _assert_grouped_equals_oracle(groups)
    var got = _parallel_count_grouped(groups)
    assert_equal(got[0], Int64(1))
    assert_equal(got[1], Int64(100))


def test_grouped_empty_and_mixed_groups() raises:
    """Empty groups interleaved with non-empty (a group that received no rows) ->
    empty groups count 0; non-empty groups match the oracle. Total crosses the
    parallel-path threshold via the one big group."""
    var groups = List[List[List[Int64]]]()
    groups.append(List[List[Int64]]())  # empty group
    var big = List[Int64](capacity=400_000)
    for i in range(400_000):
        big.append(Int64(i % 250_000))
    groups.append(_one_run(big))
    groups.append(List[List[Int64]]())  # another empty group
    var small = List[Int64](capacity=5_000)
    for d in range(5_000):
        small.append(Int64(9_000_000 + d))
    groups.append(_one_run(small))
    _assert_grouped_equals_oracle(groups)
    var got = _parallel_count_grouped(groups)
    assert_equal(got[0], Int64(0))
    assert_equal(got[1], Int64(250_000))
    assert_equal(got[2], Int64(0))
    assert_equal(got[3], Int64(5_000))


def test_grouped_single_group_matches_multi() raises:
    """A ONE-group list == the single-group `radix_distinct_count_multi` driver
    (the ng==1 fallback path), EXACTLY."""
    var vals = List[Int64](capacity=_N)
    for i in range(_N):
        vals.append(Int64(i % 50_000))
    var groups = List[List[List[Int64]]]()
    groups.append(_one_run(vals))
    var got = _parallel_count_grouped(groups)
    assert_equal(len(got), 1)
    assert_equal(got[0], Int64(50_000))
    var rt = _make_runtime(8)
    ref disp = rt.dispatcher()
    assert_equal(
        got[0], radix_distinct_count(vals.copy(), disp, CancellationToken.new())
    )


def test_grouped_empty_list() raises:
    """An empty group list -> empty result (no groups, no dispatch)."""
    var groups = List[List[List[Int64]]]()
    var got = _parallel_count_grouped(groups)
    assert_equal(len(got), 0)


# =============================================================================
# Phase 2 dispatches one task per CELL.
#
# `_make_runtime(8)` against hundreds of cells means `run_with_state` is handed
# a task count far above the worker count, so the tasks are claimed off its
# shared cursor. A sub-cell dispatched twice inflates its group; one never
# dispatched leaves `counts[c]` at its initial 0 and the group reads LOW. Both
# are caught per group, against `_cd_grouped_count_serial`, which shares no
# code with the parallel driver. (A per-worker range split of the same cells
# would answer identically: the dispatch shape itself is not observable here.)
# =============================================================================


def test_per_cell_dispatch_staircase_equals_oracle() raises:
    """The staircase shape (many tiny groups + big groups that cross the split cap):
    per-group distinct == the independent serial oracle, exactly.

    403 groups clears `_CD_GROUPED_MIN_GROUPS`, the big groups are value-hash
    split into sub-cells, and the driver hands EVERY cell out as its own task
    over 8 workers -- so `run_with_state` is asked for hundreds of tasks against
    8 shards, which is the claim-off-a-shared-cursor shape the deleted per-worker
    split could never produce. A sub-cell dispatched twice inflates its group;
    one never dispatched leaves `counts[c]` at its initialised 0 and the group
    reads LOW."""
    var groups = List[List[List[Int64]]]()
    for g in range(400):
        var buf = List[Int64](capacity=300)
        for k in range(3):
            _ = k
            for d in range(100):
                buf.append(Int64(g) * Int64(1_000_003) + Int64(d))
        groups.append(_one_run(buf))
    var big_sizes = List[Int]()
    big_sizes.append(500_000)
    big_sizes.append(900_000)
    big_sizes.append(1_500_000)
    var big_distinct = List[Int]()
    big_distinct.append(120_000)
    big_distinct.append(200_000)
    big_distinct.append(400_000)
    for b in range(len(big_sizes)):
        var sz = big_sizes[b]
        var dd = big_distinct[b]
        var buf = List[Int64](capacity=sz)
        for i in range(sz):
            buf.append(Int64(50_000_000) * Int64(b + 1) + Int64(i % dd))
        groups.append(_one_run(buf))
    var got = _parallel_count_grouped(groups)
    var oracle = _cd_grouped_count_serial(groups)
    assert_equal(len(got), len(oracle))
    for g in range(len(oracle)):
        assert_equal(got[g], oracle[g])
    for b in range(len(big_sizes)):
        assert_equal(got[400 + b], Int64(big_distinct[b]))


def test_per_cell_dispatch_all_same_and_mixed_equals_oracle() raises:
    """THE SUB-CELL SPLIT, AGAINST AN INDEPENDENT ORACLE.

    The all-same big group is the sharpest falsifier of the sub-cell split: a
    value duplicated across sub-cells, or a sub-cell double-counted, inflates it
    above 1. The literal expectations (`1` and `333_333`) are kept alongside the
    oracle so the case still says what the right answer IS, not only that two
    computations agree."""
    var groups = List[List[List[Int64]]]()
    for g in range(300):
        var buf = List[Int64](capacity=600)
        for k in range(2):
            _ = k
            for d in range(300):
                buf.append(Int64(g) * Int64(7_919) + Int64(d))
        groups.append(_one_run(buf))
    var same = List[Int64](capacity=1_200_000)
    for _ in range(1_200_000):
        same.append(Int64(424_242))
    groups.append(_one_run(same))
    var mixed = List[Int64](capacity=800_000)
    for i in range(800_000):
        mixed.append(Int64(90_000_000) + Int64(i % 333_333))
    groups.append(_one_run(mixed))

    var got = _parallel_count_grouped(groups)
    var oracle = _cd_grouped_count_serial(groups)

    assert_equal(len(got), len(oracle))
    for g in range(len(oracle)):
        assert_equal(got[g], oracle[g])
    assert_equal(got[300], Int64(1))  # the all-same group: 1, not the cell count
    assert_equal(got[301], Int64(333_333))


def test_per_cell_dispatch_few_huge_groups_equals_oracle() raises:
    """The few-huge-groups shape (a few huge groups, every one split across cells). Here the
    task count is dominated by SUB-cells rather than by whole small groups, which
    is the other end of the cell-population range and the case where a per-cell
    dispatch could in principle hand one group's sub-cells to workers that then
    race on the reduce. They do not — the reduce is serial in the driver, after
    the drain barrier — and this pins it."""
    var groups = List[List[List[Int64]]]()
    comptime HUGE = 1_200_000
    for g in range(6):
        var buf = List[Int64](capacity=HUGE)
        for i in range(HUGE):
            buf.append(Int64(g) * Int64(10_000_000) + Int64(i % 600_000))
        groups.append(_one_run(buf))
    # Below _CD_GROUPED_MIN_GROUPS on its own, so pad with small groups to reach
    # the grouped parallel path -- the arm this lever lives on.
    for g in range(300):
        var buf = List[Int64](capacity=200)
        for d in range(200):
            buf.append(Int64(800_000_000) + Int64(g) * Int64(1_009) + Int64(d))
        groups.append(_one_run(buf))
    var got = _parallel_count_grouped(groups)
    var oracle = _cd_grouped_count_serial(groups)
    assert_equal(len(got), len(oracle))
    for g in range(len(oracle)):
        assert_equal(got[g], oracle[g])
    for g in range(6):
        assert_equal(got[g], Int64(600_000))



def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
