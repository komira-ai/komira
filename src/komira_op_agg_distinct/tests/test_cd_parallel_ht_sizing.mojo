# =============================================================================
# test_cd_parallel_ht_sizing -- through the grouped COUNT(DISTINCT) driver,
# each worker's group table is sized from a GROUP bound, not from the rows,
# and grows correctly when there is no bound
# =============================================================================
#
# The sizing rule itself (`cd_groups_upper_bound`, `cd_group_ht_initial_cap`)
# is tested in `test_cd_group_ht_sizing_rule.mojo`. Here the driver runs and
# the process-wide witnesses (`cd_group_ht_slots_count`, slots every worker
# allocated; `cd_group_ht_resizes_count`, doublings) are read beside the
# answers, which a linear oracle over the raw arrays checks.
#
# What each test catches:
#   * few groups, many rows (STRING and INT keys): a table sized from the rows
#     (doubling the rows would double the slots);
#   * many STRING groups: a table not presized from the dictionary bound
#     (it would double inside the workers);
#   * many INT groups: doublings that lose, duplicate or mis-count a group
#     while probes for already-inserted groups keep arriving.
# =============================================================================

from std.collections import Dict, List
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_plan_expr.agg_expr import count_distinct
from komira_plan_expr.col_expr import col
from komira_plan_ir.logical_plan import AggExprArray, ExprArray
from komira_physical_plan.physical_plan import AggSinkData

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_op_agg_distinct.agg_cd_group_ht_sizing import (
    CD_GROUP_HT_MAX_INITIAL_CAP,
    CD_GROUP_HT_MIN_CAP,
    cd_group_ht_initial_cap,
    cd_group_ht_resizes_count,
    cd_group_ht_slots_count,
    cd_groups_upper_bound,
    reset_cd_group_ht_counters,
)
from komira_op_agg_distinct.agg_count_distinct_parallel import (
    _execute_count_distinct_agg_parallel,
    _should_use_parallel_count_distinct,
)
from komira_op_agg_distinct.cd_parallel_state import (
    _PARALLEL_CD_MIN_ROWS_PER_WORKER,
)


comptime _WORKERS: Int = 4


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


# =============================================================================
# Fixtures — keys are either STRING (dictionary-encoded by the driver) or INT64
# =============================================================================
#
# The sizes are the smallest that still separate a row-sized table from a
# group-sized one: the driver needs n >= 65,536 and n // 16,384 >= 4 for K = 4.
# Each row count is derived in its test's docstring against both sizings.


struct _Fx(Movable):
    """The raw arrays a batch is built from. The oracle reads THESE: `grp[i]`
    is row i's group NUMBER, and the key a group carries is derived from that
    number (`_key_of`), never read back out of the batch."""

    var grp: List[Int]
    var vals: List[Int64]
    var num_groups: Int
    var string_key: Bool

    def __init__(
        out self, var grp: List[Int], var vals: List[Int64], num_groups: Int,
        string_key: Bool,
    ):
        self.grp = grp^
        self.vals = vals^
        self.num_groups = num_groups
        self.string_key = string_key

    def n(self) -> Int:
        return len(self.vals)


def _key_name(g: Int) -> String:
    """Distinct, varied-length names; group 3 is the EMPTY string."""
    if g == 3:
        return String("")
    return String("model-") + String(g) + String("-") + String(g * 7919)


def _key_int(g: Int, num_groups: Int) -> Int64:
    """Wide, non-contiguous, negative-including INT64 keys."""
    return Int64((g - num_groups // 2) * 104_729)


def _few_groups(n: Int, string_key: Bool) -> _Fx:
    """5 groups, one holding ~90% of the rows. Group g draws
    from `2g + 3` distinct values, so every group's answer differs."""
    var grp = List[Int](capacity=n)
    var v = List[Int64](capacity=n)
    for i in range(n):
        var g = 0 if i % 10 != 0 else 1 + (i // 10) % 4
        grp.append(g)
        v.append(Int64(1000 * g + (i % (2 * g + 3))))
    return _Fx(grp^, v^, 5, string_key)


def _many_groups(num_groups: Int, rows_per_group: Int, string_key: Bool) -> _Fx:
    """`num_groups` groups, rows interleaved (row i -> group i % num_groups) so
    every worker's groups arrive throughout the scan, i.e. its table grows
    while probes for already-inserted groups are still arriving. Group g's
    rows take `g % 5 + 1` distinct values (capped by `rows_per_group`)."""
    var n = num_groups * rows_per_group
    var grp = List[Int](capacity=n)
    var v = List[Int64](capacity=n)
    for i in range(n):
        var g = i % num_groups
        grp.append(g)
        v.append(Int64((i // num_groups) % (g % 5 + 1)))
    return _Fx(grp^, v^, num_groups, string_key)


def _build_batch(imm f: _Fx) raises -> RecordBatch:
    var n = f.n()
    var rbb = RecordBatchBuilder.with_capacity(2)
    var sb = SchemaBuilder()
    if f.string_key:
        var names = List[String](capacity=f.num_groups)
        for g in range(f.num_groups):
            names.append(
                _key_name(g) if f.num_groups <= 5 else String("k") + String(g)
            )
        var rows = List[String](capacity=n)
        for i in range(n):
            rows.append(names[f.grp[i]].copy())
        rbb.add_column(Column.from_string(StringArray.from_strings(rows)))
        sb.add_field(Field("k", ArrowType.STRING, False))
    else:
        var karr = PrimitiveArray[DType.int64].allocate(n)
        for i in range(n):
            karr.store[1](
                i, Scalar[DType.int64](_key_int(f.grp[i], f.num_groups))
            )
        rbb.add_column(Column.from_primitive[DType.int64](karr^))
        sb.add_field(Field("k", ArrowType.INT64, False))
    var varr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        varr.store[1](i, Scalar[DType.int64](f.vals[i]))
    rbb.add_column(Column.from_primitive[DType.int64](varr^))
    sb.add_field(Field("v", ArrowType.INT64, False))
    return rbb.build(sb.build())


def _sink(string_key: Bool) raises -> AggSinkData:
    """SELECT k, COUNT(DISTINCT v) FROM t GROUP BY k."""
    var group_by = ExprArray()
    group_by.append(col("k").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")))
    var osb = SchemaBuilder()
    osb.add_field(
        Field("k", ArrowType.STRING if string_key else ArrowType.INT64, False)
    )
    osb.add_field(Field("cd", ArrowType.INT64, False))
    return AggSinkData(group_by^, aggs^, osb.build())


def _oracle(imm f: _Fx) -> List[Int]:
    """Distinct-value count per group NUMBER, from the raw arrays.

    Sort-based on purpose: a `Set[Int64]` per group is too slow for 36,000
    groups. Every fixture value is in [0, 2^31), so
    `g * 2^32 + v` orders by (group, value) and a group's distinct count is its
    number of value changes in that order."""
    var n = f.n()
    var packed = List[Int](capacity=n)
    for i in range(n):
        packed.append(f.grp[i] * (1 << 32) + Int(f.vals[i]))
    sort(packed)
    var out = List[Int](length=f.num_groups, fill=0)
    for i in range(n):
        if i == 0 or packed[i] != packed[i - 1]:
            out[packed[i] >> 32] += 1
    return out^


struct _Run(Movable):
    """One driver run: the count per group NUMBER (-1 = never emitted), how
    many output rows named each group, the output row count, and the counter
    deltas the run produced."""

    var got: List[Int]
    var hits: List[Int]
    var out_rows: Int
    var slots: Int
    var resizes: Int

    def __init__(
        out self, var got: List[Int], var hits: List[Int], out_rows: Int,
        slots: Int, resizes: Int,
    ):
        self.got = got^
        self.hits = hits^
        self.out_rows = out_rows
        self.slots = slots
        self.resizes = resizes


def _run(imm f: _Fx) raises -> _Run:
    var n = f.n()
    assert_true(
        _should_use_parallel_count_distinct(n, _WORKERS),
        "PRECONDITION: n=" + String(n) + " must route to the PARALLEL driver,"
        " or this case re-tests the serial twin and is vacuous",
    )
    assert_true(
        n // _PARALLEL_CD_MIN_ROWS_PER_WORKER >= _WORKERS,
        "PRECONDITION: n=" + String(n) + " must give K = " + String(_WORKERS)
        + " workers, which every slot figure below is stated in",
    )
    var batch = _build_batch(f)
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(_WORKERS, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var ct = CancellationToken.new()
    reset_cd_group_ht_counters()
    var out = _execute_count_distinct_agg_parallel(
        disp, ct.clone(), batch, _sink(f.string_key), 1, 1, n
    )
    var slots = cd_group_ht_slots_count()
    var resizes = cd_group_ht_resizes_count()

    # Decode each output key back to its group NUMBER through a key -> g map
    # built from the fixture's own key function (num_groups entries).
    var got = List[Int](length=f.num_groups, fill=-1)
    var hits = List[Int](length=f.num_groups, fill=0)
    var counts = out.column_as_primitive_int64(1)
    if f.string_key:
        var g_of = Dict[String, Int]()
        for g in range(f.num_groups):
            g_of[
                _key_name(g) if f.num_groups <= 5 else String("k") + String(g)
            ] = g
        var keys = out.column_as_string(0)
        for r in range(out.num_rows()):
            var k = keys.get(r)
            assert_true(k in g_of, "output names a key no row carried: " + k)
            var g = g_of[k]
            got[g] = Int(counts.get(r))
            hits[g] += 1
    else:
        var g_of = Dict[Int64, Int]()
        for g in range(f.num_groups):
            g_of[_key_int(g, f.num_groups)] = g
        var keys = out.column_as_primitive_int64(0)
        for r in range(out.num_rows()):
            var k = Int64(keys.get(r))
            assert_true(
                k in g_of, "output names a key no row carried: " + String(k)
            )
            var g = g_of[k]
            got[g] = Int(counts.get(r))
            hits[g] += 1
    return _Run(got^, hits^, out.num_rows(), slots, resizes)


def _assert_values(imm r: _Run, imm f: _Fx, imm msg: String) raises:
    var want = _oracle(f)
    assert_equal(
        r.out_rows, f.num_groups,
        msg + ": OUTPUT ROWS == distinct keys (a duplicated group is invisible"
        " to a per-key comparison)",
    )
    for g in range(f.num_groups):
        assert_equal(
            r.hits[g], 1, msg + ": group " + String(g) + " emitted exactly once"
        )
        assert_equal(
            r.got[g], want[g], msg + ": distinct count for group " + String(g)
        )


# =============================================================================
# FEW GROUPS, MANY ROWS — the table does not scale with the rows
# =============================================================================


def test_few_groups_many_rows_string_key_is_not_row_sized() raises:
    """5 STRING groups at 70,000 and at 140,000 rows, K = 4
    both times. The dictionary bound is 6, so each worker sits at the floor.
    A row-sized table: next_pow2(2 * ceil(n / 4)) per worker = 65,536 and 131,072,
    i.e. 262,144 vs 524,288 slots -> RED on the equality.
    Group-sized: 4 x 4,096 = 16,384 slots both times, no doubling."""
    var f1 = _few_groups(70_000, True)
    var r1 = _run(f1)
    _assert_values(r1, f1, "STRING key 70k rows")
    var f2 = _few_groups(140_000, True)
    var r2 = _run(f2)
    _assert_values(r2, f2, "STRING key 140k rows")

    assert_true(r1.slots > 0, "VACUITY — the driver allocated no table")
    assert_equal(
        r2.slots, r1.slots,
        "5 groups at 140k rows allocated a DIFFERENT number of table slots"
        " than at 70k — the table is sized from ROWS",
    )
    assert_equal(
        r1.slots, _WORKERS * CD_GROUP_HT_MIN_CAP,
        "5 groups over " + String(_WORKERS) + " workers must sit at the"
        " floor, one table per worker",
    )
    assert_equal(r1.resizes, 0, "5 groups never fill a floor table")
    assert_equal(r2.resizes, 0, "nor at 140k rows")


def test_few_groups_many_rows_int_key_starts_at_the_floor() raises:
    """An INT key has no dictionary, so no bound — the table
    starts at the floor rather than at the row-derived size, and 5 groups
    never grow it. One row count suffices here: a row-sized table gives 65,536
    per worker at 70,000 rows (262,144 slots), the floor is 16,384 -> RED."""
    var f = _few_groups(70_000, False)
    var r = _run(f)
    _assert_values(r, f, "INT64 key 70k rows")
    assert_equal(
        r.slots, _WORKERS * CD_GROUP_HT_MIN_CAP,
        "an unbounded key must START at the floor, not at a row-derived size",
    )
    assert_equal(r.resizes, 0, "5 groups never fill a floor table")


# =============================================================================
# A DICTIONARY KEY IS PRE-SIZED FROM THE DICTIONARY — no growth needed
# =============================================================================


def test_many_string_groups_are_presized_from_the_dictionary() raises:
    """20,000 distinct strings x 4 rows = 80,000 rows, K = 4. The encode's
    dictionary holds 20,000 ids, so the bound is 20,001: 5,001 per worker,
    +1/8 +64 = 5,690, x2 = 11,380 -> 16,384 slots per worker. Each worker holds
    ~5,000 groups (a doubling needs 8,193), so NO doubling.
    A row-sized table: 20,000 rows per worker -> 65,536 slots -> 262,144 -> RED."""
    var f = _many_groups(20_000, 4, True)
    var r = _run(f)
    _assert_values(r, f, "20,000 string groups")
    assert_equal(r.resizes, 0, "pre-sized from the dictionary: no doubling")
    assert_equal(r.slots, _WORKERS * 16_384, "4 tables of 16,384 slots")


# =============================================================================
# AN INT KEY HAS NO BOUND — the table starts small and DOUBLES, repeatedly
# =============================================================================


def test_many_int_groups_force_several_doublings_and_stay_exact() raises:
    """36,000 distinct INT64 keys x 2 rows = 72,000 rows, K = 4 -> ~9,000
    groups per worker. From 4,096 slots at load <= 0.5 a worker doubles at its
    2,049th, 4,097th and 8,193rd group: 3 doublings per worker, 12 in all,
    while probes for already-inserted groups keep arriving (rows interleave).
    Every group must come back exactly once with the oracle's count.
    A row-sized table: 18,000 rows per worker -> 65,536 slots -> 0 doublings -> RED on
    the vacuity assertion."""
    var f = _many_groups(36_000, 2, False)
    var r = _run(f)
    assert_true(
        r.resizes >= 3 * _WORKERS,
        "VACUITY: expected >= " + String(3 * _WORKERS) + " doublings, got "
        + String(r.resizes) + " — the growth path under test did not run",
    )
    _assert_values(r, f, "36,000 int groups across repeated doublings")
    # Each doubling allocates a table twice the previous one, so the slots
    # allocated are bounded by 2x the final tables (a geometric sum).
    assert_true(
        r.slots <= 2 * _WORKERS * 32_768,
        "slots allocated " + String(r.slots) + " exceed the geometric bound",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
