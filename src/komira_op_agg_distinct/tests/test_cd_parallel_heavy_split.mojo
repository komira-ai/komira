# =============================================================================
# test_cd_parallel_heavy_split -- the grouped COUNT(DISTINCT) driver splits a
# HEAVY group across workers by distinct pair and folds it back exactly, and
# its owner map keys every row on one worker
# =============================================================================
#
# The driver owns a row by its GROUP hash, so a group holding 90% of the rows
# would be one worker's job. When every aggregate is COUNT(DISTINCT), a group
# whose sampled share passes 1/(4K) is owned per distinct PAIR instead, and the
# per-worker partial counts are folded back into one row by full key
# (`agg_cd_heavy_split`, `cd_parallel_state`).
#
# The oracle (`_oracle`) is a linear scan with `Set`s over the raw fixture
# lists. What each test catches:
#   * `test_a_heavy_group_is_spread_across_workers_and_folded_back`: no split
#     (the busiest worker owns the whole heavy group), an unfolded partial (a
#     group emitted twice), a double-counted pair;
#   * `test_a_heavy_composite_group_over_two_int_keys`: a fold that compares
#     only the first key column;
#   * `test_a_light_group_colliding_with_the_heavy_hash_folds_only_with_itself`:
#     a fold by hash alone (a constructed hash collision with the heavy group
#     would be added into it);
#   * `test_an_all_null_heavy_group_is_emitted_with_zero`: NULL rows owned by
#     pair hash (no worker would create the group, and it would vanish);
#   * `test_two_distinct_aggregates_on_a_heavy_group`: ownership decided once
#     per row instead of per aggregate;
#   * `test_a_non_distinct_aggregate_declines_the_split` and
#     `test_uniform_groups_are_not_split`: a split taken where it cannot fold
#     exactly, or where nothing is heavy;
#   * the owner-map tests: every worker keying every row again (the AGG pass's
#     keyed-row total is K x N instead of N), a heavy row under two aggregates
#     not examined by every worker, and a row-range split that leaves the
#     owner bytes of a remainder (N % K != 0) unwritten.
#
# Mutants run while porting: the fold comparing the hash only (the
# collision test went red); the AGG pass ignoring the owner byte and keying
# every row (the keyed-row tests went red).
# =============================================================================

from std.collections import Dict, List, Set
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)
from komira_plan_expr.agg_expr import count_distinct, sum
from komira_plan_expr.col_expr import col
from komira_plan_ir.logical_plan import AggExprArray, ExprArray
from komira_physical_plan.physical_plan import AggSinkData

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_op_agg_distinct.agg_cd_heavy_split import (
    cd_heavy_groups_count,
    cd_heavy_merged_count,
    cd_worker_max_rows_last,
    cd_worker_rows_scanned_total_last,
    cd_worker_rows_total_last,
    reset_cd_heavy_counters,
)
from komira_op_agg_distinct.agg_count_distinct_parallel import (
    _execute_count_distinct_agg_parallel,
    _should_use_parallel_count_distinct,
)


comptime _N: Int = 80_000
comptime _WORKERS: Int = 4
comptime _NULL_PAYLOAD: Int64 = -777_777


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


# =============================================================================
# Fixture + oracle (two INT64 keys, two INT64 value columns)
# =============================================================================


struct _Fx(Movable):
    """The raw arrays the batch is built from. The oracle reads THESE."""

    var k1: List[Int64]
    var k2: List[Int64]
    var v: List[Int64]
    var vnull: List[Bool]
    var w: List[Int64]

    def __init__(
        out self,
        var k1: List[Int64],
        var k2: List[Int64],
        var v: List[Int64],
        var vnull: List[Bool],
        var w: List[Int64],
    ):
        self.k1 = k1^
        self.k2 = k2^
        self.v = v^
        self.vnull = vnull^
        self.w = w^

    def n(self) -> Int:
        return len(self.k1)


def _heavy_fixture(n: Int, heavy_all_null: Bool = False) raises -> _Fx:
    """Group (0, 0) holds 90% of the rows with THOUSANDS of
    distinct values (so a double-counted pair moves its answer); 30 light
    groups share the rest, each with a different value span. `w` is a
    different function of the row than `v`. With `heavy_all_null`, EVERY row
    of the heavy group has a NULL `v` — it must still be emitted, with 0."""
    var k1 = List[Int64](capacity=n)
    var k2 = List[Int64](capacity=n)
    var v = List[Int64](capacity=n)
    var vn = List[Bool](capacity=n)
    var w = List[Int64](capacity=n)
    for i in range(n):
        var heavy = (i % 10) != 0
        var a = 0
        var b = 0
        if not heavy:
            var g = (i // 10) % 30
            a = 1 + g % 5
            b = g // 5
        k1.append(Int64(a))
        k2.append(Int64(b))
        var span = 5003 if heavy else (3 + a * 7 + b)
        # Every 13th row of a light group is NULL, so no group is right by
        # never having seen a NULL.
        var is_null = (heavy and heavy_all_null) or (not heavy and i % 13 == 0)
        v.append(_NULL_PAYLOAD if is_null else Int64((i * 7919) % span - 50))
        vn.append(is_null)
        w.append(Int64(i % (11 + a)))
    return _Fx(k1^, k2^, v^, vn^, w^)


def _build_batch(imm f: _Fx) raises -> RecordBatch:
    var n = f.n()
    var a1 = PrimitiveArray[DType.int64].allocate(n)
    var a2 = PrimitiveArray[DType.int64].allocate(n)
    var aw = PrimitiveArray[DType.int64].allocate(n)
    var av = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        a1.store[1](i, Scalar[DType.int64](f.k1[i]))
        a2.store[1](i, Scalar[DType.int64](f.k2[i]))
        aw.store[1](i, Scalar[DType.int64](f.w[i]))
        av.store[1](i, Scalar[DType.int64](f.v[i]))
    for i in range(n):
        if f.vnull[i]:
            av._set_null(i)
    var rbb = RecordBatchBuilder.with_capacity(4)
    rbb.add_column(Column.from_primitive[DType.int64](a1^))
    rbb.add_column(Column.from_primitive[DType.int64](a2^))
    rbb.add_column(Column.from_primitive[DType.int64](av^))
    rbb.add_column(Column.from_primitive[DType.int64](aw^))
    var sb = SchemaBuilder()
    sb.add_field(Field("k1", ArrowType.INT64, False))
    sb.add_field(Field("k2", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT64, True))
    sb.add_field(Field("w", ArrowType.INT64, False))
    return rbb.build(sb.build())


def _sink(two_keys: Bool, second: Int) raises -> AggSinkData:
    """GROUP BY k1 [, k2]: COUNT(DISTINCT v) and, per `second`, nothing (0),
    COUNT(DISTINCT w) (1) or SUM(w) (2)."""
    var group_by = ExprArray()
    group_by.append(col("k1").copy_expr())
    if two_keys:
        group_by.append(col("k2").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")))
    if second == 1:
        aggs.append(count_distinct(col("w")))
    elif second == 2:
        aggs.append(sum(col("w")))
    var osb = SchemaBuilder()
    osb.add_field(Field("k1", ArrowType.INT64, False))
    if two_keys:
        osb.add_field(Field("k2", ArrowType.INT64, False))
    osb.add_field(Field("cdv", ArrowType.INT64, False))
    if second == 1:
        osb.add_field(Field("cdw", ArrowType.INT64, False))
    elif second == 2:
        osb.add_field(Field("sw", ArrowType.INT64, False))
    return AggSinkData(group_by^, aggs^, osb.build())


def _gkey(imm f: _Fx, i: Int, two_keys: Bool) -> Int64:
    """One Int64 per group: k1 alone, or k1 and k2 packed (both < 1000)."""
    if two_keys:
        return f.k1[i] * 1000 + f.k2[i]
    return f.k1[i]


def _oracle(imm f: _Fx, two_keys: Bool, which: Int) raises -> Dict[Int64, Int]:
    """which 0: COUNT(DISTINCT v); 1: COUNT(DISTINCT w); 2: SUM(w)."""
    var sets = Dict[Int64, Set[Int64]]()
    var sums = Dict[Int64, Int]()
    for i in range(f.n()):
        var g = _gkey(f, i, two_keys)
        if g not in sets:
            sets[g] = Set[Int64]()
            sums[g] = 0
        if which == 0 and not f.vnull[i]:
            sets[g].add(f.v[i])
        elif which == 1:
            sets[g].add(f.w[i])
        sums[g] = sums[g] + Int(f.w[i])
    var out = Dict[Int64, Int]()
    for e in sets.items():
        out[e.key] = len(e.value) if which != 2 else sums[e.key]
    return out^


def _result(
    imm b: RecordBatch, two_keys: Bool, agg: Int
) raises -> Dict[Int64, Int]:
    var m = Dict[Int64, Int]()
    var nk = 2 if two_keys else 1
    var c1 = b.column_as_primitive_int64(0)
    var cv = b.column_as_primitive_int64(nk + agg)
    if two_keys:
        var c2 = b.column_as_primitive_int64(1)
        for r in range(b.num_rows()):
            m[c1.get(r) * 1000 + c2.get(r)] = Int(cv.get(r))
    else:
        for r in range(b.num_rows()):
            m[c1.get(r)] = Int(cv.get(r))
    return m^


def _assert_matches(
    imm got: Dict[Int64, Int], imm want: Dict[Int64, Int], imm msg: String
) raises:
    assert_equal(len(got), len(want), msg + ": group COUNT")
    for e in want.items():
        assert_true(e.key in got, msg + ": missing group " + String(e.key))
        assert_equal(got[e.key], e.value, msg + ": group " + String(e.key))


def _run(imm f: _Fx, two_keys: Bool, second: Int) raises -> RecordBatch:
    var n = f.n()
    assert_true(
        _should_use_parallel_count_distinct(n, _WORKERS),
        "PRECONDITION: n=" + String(n) + " must select the PARALLEL driver",
    )
    var batch = _build_batch(f)
    var rt = PerCoreAsyncRuntime[NoopSink](placement=PLACEMENT_FIXED)
    rt.attach_workers(_WORKERS, _noop_sink_factory, BACKEND_MOCK)
    rt.start()
    ref disp = rt.dispatcher()
    var ct = CancellationToken.new()
    var nk = 2 if two_keys else 1
    var na = 1 if second == 0 else 2
    return _execute_count_distinct_agg_parallel(
        disp, ct.clone(), batch, _sink(two_keys, second), nk, na, n
    )


def _heavy_rows(imm f: _Fx) -> Int:
    var h = 0
    for i in range(f.n()):
        if f.k1[i] == 0 and f.k2[i] == 0:
            h += 1
    return h


# =============================================================================
# the heavy group is split and folded back
# =============================================================================


def test_a_heavy_group_is_spread_across_workers_and_folded_back() raises:
    """The busiest worker must own under half of the rows; without the split
    it owns the whole heavy group (~90%). Plus the fold
    itself (heavy groups split, partials folded), the ROW COUNT (an unfolded
    partial emits its group twice), and every per-group value."""
    var f = _heavy_fixture(_N)
    var hr = _heavy_rows(f)
    assert_true(
        hr * 10 >= _N * 8,
        "FIXTURE: the heavy group must hold >= 80% of the rows, has "
        + String(hr),
    )
    reset_cd_heavy_counters()
    var got = _run(f, two_keys=False, second=0)
    var want = _oracle(f, False, 0)
    assert_equal(
        got.num_rows(), len(want),
        "one output row per group — an unfolded partial emits a group twice",
    )
    _assert_matches(_result(got, False, 0), want, "heavy count(DISTINCT v)")
    assert_equal(cd_heavy_groups_count(), 1, "exactly one heavy group split")
    assert_true(
        cd_heavy_merged_count() >= 1,
        "the heavy group's partials were folded (" + String(
            cd_heavy_merged_count()
        ) + ")",
    )
    assert_equal(
        cd_worker_rows_total_last(), _N,
        "with ONE distinct aggregate every row is owned exactly once",
    )
    var busiest = cd_worker_max_rows_last()
    assert_true(
        busiest * 2 < _N,
        "the busiest worker owned " + String(busiest) + " of " + String(_N)
        + " rows. Under the group partition that is the whole heavy group ("
        + String(hr) + "): the split did not happen",
    )


def test_a_heavy_composite_group_over_two_int_keys() raises:
    """Two keys, one composite group at 90%. The fold compares EVERY key column."""
    var f = _heavy_fixture(_N)
    reset_cd_heavy_counters()
    var got = _run(f, two_keys=True, second=0)
    var want = _oracle(f, True, 0)
    assert_equal(got.num_rows(), len(want), "one output row per (k1, k2)")
    _assert_matches(_result(got, True, 0), want, "two-key heavy group")
    assert_equal(cd_heavy_groups_count(), 1, "the (0, 0) group was split")
    assert_true(
        cd_worker_max_rows_last() * 2 < _N,
        "the busiest worker still owns the whole heavy group",
    )


def _fnv2(a: Int, b: Int) -> Int:
    """The worker loop's composite hash for two keys, restated (FNV-1a basis
    0x811C9DC5, prime 0x01000193, keys in order)."""
    var h: Int = 0x811C9DC5
    h = (h ^ a) * 0x01000193
    h = (h ^ b) * 0x01000193
    return h


def test_a_light_group_colliding_with_the_heavy_hash_folds_only_with_itself(
) raises:
    """The fold keys on the FULL group, not the hash. Ownership keys on
    the composite HASH being heavy, so a light group that shares the heavy
    group's hash is split too, and its partials sit in the same workers as the
    heavy group's. Folding by hash alone would ADD them into the heavy group:
    one group vanishes and the other is over-counted.

    The collision is constructed, not hoped for: the two-key FNV fold is
    `((B ^ k1) * P ^ k2) * P`, and multiplication by the odd prime is a
    bijection, so `k2 = ((B ^ 1) * P) ^ (B * P)` puts `(1, k2)` on exactly
    `(0, 0)`'s hash — asserted before anything runs."""
    var b: Int = 0x811C9DC5
    var p: Int = 0x01000193
    var k2c = ((b ^ 1) * p) ^ (b * p)
    assert_equal(_fnv2(1, k2c), _fnv2(0, 0), "FIXTURE: the hashes collide")
    var n = _N
    var k1 = List[Int64](capacity=n)
    var k2 = List[Int64](capacity=n)
    var v = List[Int64](capacity=n)
    var vn = List[Bool](capacity=n)
    var w = List[Int64](capacity=n)
    for i in range(n):
        var r = i % 20
        if r == 0:
            k1.append(Int64(1))  # the COLLIDING light group, 5% of rows
            k2.append(Int64(k2c))
            v.append(Int64(i % 37))
        elif r == 1:
            k1.append(Int64(2))  # an ordinary light group
            k2.append(Int64(3))
            v.append(Int64(i % 11))
        else:
            k1.append(Int64(0))  # the heavy group, 90%
            k2.append(Int64(0))
            v.append(Int64((i * 7919) % 4001))
        vn.append(False)
        w.append(Int64(0))
    var f = _Fx(k1^, k2^, v^, vn^, w^)
    # Oracle over the FULL pair of keys (k2c does not fit `_gkey`'s packing).
    var sets = Dict[String, Set[Int64]]()
    for i in range(n):
        var g = String(f.k1[i]) + "," + String(f.k2[i])
        if g not in sets:
            sets[g] = Set[Int64]()
        sets[g].add(f.v[i])
    reset_cd_heavy_counters()
    var got = _run(f, two_keys=True, second=0)
    assert_equal(got.num_rows(), 3, "three groups: heavy, colliding, light")
    var c1 = got.column_as_primitive_int64(0)
    var c2 = got.column_as_primitive_int64(1)
    var cv = got.column_as_primitive_int64(2)
    for r in range(got.num_rows()):
        var g = String(c1.get(r)) + "," + String(c2.get(r))
        assert_true(g in sets, "an emitted group that does not exist: " + g)
        assert_equal(
            Int(cv.get(r)), len(sets[g]),
            "group " + g + " — a hash-only fold adds the colliding group's"
            " partials into the heavy one",
        )
    assert_true(
        cd_heavy_merged_count() >= 2,
        "both the heavy group AND its hash twin were split and folded",
    )


# =============================================================================
# 3. NULL — the all-NULL heavy group, and a heavy group beside NULL rows
# =============================================================================


def test_an_all_null_heavy_group_is_emitted_with_zero() raises:
    """A NULL value admits nothing, so if NULL rows were owned by pair hash
    (or dropped before ownership) an all-NULL heavy group would be created by
    NO worker and would VANISH. They are owned by the group's own bucket, so
    the group exists and reads 0 — not dropped, and not counted as one."""
    var f = _heavy_fixture(_N, heavy_all_null=True)
    reset_cd_heavy_counters()
    var got = _run(f, two_keys=False, second=0)
    var want = _oracle(f, False, 0)
    assert_equal(got.num_rows(), len(want), "one row per group, heavy included")
    var m = _result(got, False, 0)
    _assert_matches(m, want, "all-NULL heavy group")
    assert_true(Int64(0) in m, "the all-NULL heavy group must be EMITTED")
    assert_equal(m[Int64(0)], 0, "an all-NULL group counts 0 distinct values")
    assert_equal(cd_heavy_groups_count(), 1, "it was still detected as heavy")


# =============================================================================
# 4. TWO DISTINCT AGGREGATES — ownership is PER AGGREGATE
# =============================================================================


def test_two_distinct_aggregates_on_a_heavy_group() raises:
    """A heavy row's `v` pair and `w` pair are owned by DIFFERENT workers in
    general, so one row is processed by up to two workers, each for its own
    aggregate. Both counts must be exact, and every row owned at least once."""
    var f = _heavy_fixture(_N)
    reset_cd_heavy_counters()
    var got = _run(f, two_keys=False, second=1)
    var want_v = _oracle(f, False, 0)
    var want_w = _oracle(f, False, 1)
    assert_equal(got.num_rows(), len(want_v), "one output row per group")
    _assert_matches(_result(got, False, 0), want_v, "count(DISTINCT v)")
    _assert_matches(_result(got, False, 1), want_w, "count(DISTINCT w)")
    assert_equal(cd_heavy_groups_count(), 1, "the heavy group was split")
    assert_true(
        cd_worker_rows_total_last() >= _N,
        "every row is owned by at least one worker",
    )


# =============================================================================
# 5. ADMISSION — a non-distinct aggregate, and uniform groups, decline
# =============================================================================


def test_a_non_distinct_aggregate_declines_the_split() raises:
    """A split group's rows reach several workers, and a non-distinct
    accumulator would be folded in a different order than one worker would fold it. The split is declined for the WHOLE query: the busiest worker
    owns the heavy group, exactly as before, and every value is still right."""
    var f = _heavy_fixture(_N)
    var hr = _heavy_rows(f)
    reset_cd_heavy_counters()
    var got = _run(f, two_keys=False, second=2)
    _assert_matches(_result(got, False, 0), _oracle(f, False, 0), "cd(v)")
    _assert_matches(_result(got, False, 1), _oracle(f, False, 2), "sum(w)")
    assert_equal(cd_heavy_groups_count(), 0, "declined: nothing split")
    assert_true(
        cd_worker_max_rows_last() >= hr,
        "declined: the heavy group is ONE worker's, as before",
    )


def test_uniform_groups_are_not_split() raises:
    """64 equal groups: none reaches 2/K, so nothing is split and the merge is
    the plain concat. The split must not fire on a shape it cannot help."""
    var n = _N
    var k1 = List[Int64](capacity=n)
    var k2 = List[Int64](capacity=n)
    var v = List[Int64](capacity=n)
    var vn = List[Bool](capacity=n)
    var w = List[Int64](capacity=n)
    for i in range(n):
        k1.append(Int64(i % 64))
        k2.append(Int64(0))
        v.append(Int64(i % (5 + i % 64)))
        vn.append(False)
        w.append(Int64(0))
    var f = _Fx(k1^, k2^, v^, vn^, w^)
    reset_cd_heavy_counters()
    var got = _run(f, two_keys=False, second=0)
    var want = _oracle(f, False, 0)
    assert_equal(got.num_rows(), len(want), "64 rows")
    _assert_matches(_result(got, False, 0), want, "uniform groups")
    assert_equal(cd_heavy_groups_count(), 0, "no group is heavy")
    assert_equal(cd_heavy_merged_count(), 0, "nothing folded")


# =============================================================================
# The owner map: each row is keyed by one worker
# =============================================================================



def test_each_row_is_keyed_by_exactly_one_worker() raises:
    """Uniform groups, one aggregate: every row is keyed once."""
    var n = _N
    var k1 = List[Int64](capacity=n)
    var k2 = List[Int64](capacity=n)
    var v = List[Int64](capacity=n)
    var vn = List[Bool](capacity=n)
    var w = List[Int64](capacity=n)
    for i in range(n):
        k1.append(Int64(i % 64))
        k2.append(Int64(0))
        v.append(Int64(i % (5 + i % 64)))
        vn.append(False)
        w.append(Int64(0))
    var f = _Fx(k1^, k2^, v^, vn^, w^)
    reset_cd_heavy_counters()
    var got = _run(f, two_keys=False, second=0)
    _assert_matches(_result(got, False, 0), _oracle(f, False, 0), "uniform")
    assert_equal(
        cd_worker_rows_scanned_total_last(), n,
        "the AGG pass keyed " + String(cd_worker_rows_scanned_total_last())
        + " rows for " + String(n) + " — " + String(_WORKERS) + " x N means"
        " every worker walked every row again",
    )


def test_a_heavy_row_under_one_aggregate_is_keyed_once() raises:
    """The heavy group's pair owner is decided in the OWNER pass too."""
    var f = _heavy_fixture(_N)
    reset_cd_heavy_counters()
    var got = _run(f, two_keys=False, second=0)
    _assert_matches(_result(got, False, 0), _oracle(f, False, 0), "heavy, 1 agg")
    assert_equal(cd_heavy_groups_count(), 1, "the heavy group was split")
    assert_equal(
        cd_worker_rows_scanned_total_last(), _N,
        "a single-aggregate heavy row has ONE owner and is keyed once",
    )


def test_a_heavy_row_under_two_aggregates_is_examined_by_every_worker(
) raises:
    """The designed exception, counted EXACTLY: a heavy row with two
    COUNT(DISTINCT)s has a pair owner PER aggregate, so its owner byte is
    `_CDP_OWNER_EVERY` and all K workers key it; every light row is keyed
    once. Both counts are right."""
    var f = _heavy_fixture(_N)
    var hr = 0
    for i in range(f.n()):
        if f.k1[i] == 0:
            hr += 1
    reset_cd_heavy_counters()
    var got = _run(f, two_keys=False, second=1)
    _assert_matches(_result(got, False, 0), _oracle(f, False, 0), "cd(v)")
    _assert_matches(_result(got, False, 1), _oracle(f, False, 1), "cd(w)")
    assert_equal(
        cd_worker_rows_scanned_total_last(), (_N - hr) + _WORKERS * hr,
        "light rows once, heavy rows once per worker",
    )


def test_a_row_count_that_k_does_not_divide() raises:
    """The OWNER pass splits [0, N) into K contiguous ranges with integer
    division; a tail the ranges missed would leave owner bytes UNWRITTEN
    (the buffer is uninitialised), and those rows would be lost or doubled.
    80,003 rows at K=4 leaves a remainder of 3."""
    var n = _N + 3
    var f = _heavy_fixture(n)
    reset_cd_heavy_counters()
    var got = _run(f, two_keys=True, second=0)
    var want = _oracle(f, True, 0)
    assert_equal(got.num_rows(), len(want), "one row per group")
    _assert_matches(_result(got, True, 0), want, "N % K != 0")
    assert_equal(cd_worker_rows_scanned_total_last(), n, "every row keyed once")
    assert_equal(cd_worker_rows_total_last(), n, "every row owned once")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
