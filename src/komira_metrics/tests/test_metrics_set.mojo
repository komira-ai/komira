# =============================================================================
# test_metrics_set.mojo — unit tests for the MetricsSet data model
# =============================================================================
#
# Checks exercised:
#   * POD audit — `size_of[T]()` elaborates for Counter, Time,
#     Gauge, NamedCounter/Time/Gauge, MetricsSet, MetricsSnapshot.
#
# Functional coverage:
#   * Counter / Time / Gauge — in-pipeline + out-of-pipeline accumulation
#     produce the expected reduce() value.
#   * MetricsSet.register_*  — unique names, dup-rejection, capacity drop.
#   * MetricsSet.counter[name]() lookup → ref → inc_in_pipeline path.
#   * `@parameter parallelize` over 8 workers writing disjoint slots
#     reduces to the correct total (the canonical worker-disjoint
#     pattern).
#   * `MetricsSnapshot.lookup` exposes registered values back to callers.
#   * `TimeScope` records monotonic-non-negative elapsed time.
# =============================================================================

from std.memory import Pointer
from std.sys import size_of
from std.testing import assert_equal, assert_true, assert_false

from komira_metrics.metrics_set import (
    Counter,
    Time,
    Gauge,
    NamedCounter,
    NamedTime,
    NamedGauge,
    TimeScope,
    MetricsSet,
    MetricsSnapshot,
    MetricsSnapshotEntry,
    METRIC_KIND_COUNTER,
    METRIC_KIND_TIME,
    METRIC_KIND_GAUGE,
    MAX_WORKERS,
    MAX_COUNTERS,
    MAX_TIMES,
    MAX_GAUGES,
)
from komira_name_registry import name_id as _literal_name_id
from komira_spawn_join import SpawnJoinBody, spawn_join


# -----------------------------------------------------------------------------
# Constants & POD audit
# -----------------------------------------------------------------------------


def test_counter_pod_size() raises:
    """Counter must elaborate via size_of (proves POD-shape). Exact
    bytes: InlineArray[Int64, 64] = 512 + Atomic[Int64] = 8 → 520
    nominal; alignment may pad to 528.
    """
    var s = size_of[Counter]()
    assert_true(
        s >= 512 and s <= 576,
        "Counter size out of expected range: " + String(s),
    )
    print("  test_counter_pod_size PASS, size=", s)


def test_time_pod_size() raises:
    """Same shape as Counter."""
    var s = size_of[Time]()
    assert_true(
        s >= 512 and s <= 576,
        "Time size out of expected range: " + String(s),
    )
    print("  test_time_pod_size PASS, size=", s)


def test_gauge_pod_size() raises:
    """Same shape as Counter."""
    var s = size_of[Gauge]()
    assert_true(
        s >= 512 and s <= 576,
        "Gauge size out of expected range: " + String(s),
    )
    print("  test_gauge_pod_size PASS, size=", s)


def test_metrics_snapshot_pod_size() raises:
    """MetricsSnapshot is POD; must cross thread boundaries safely."""
    var s = size_of[MetricsSnapshot]()
    # 16 entries * 16 bytes/entry = 256 + 1 (n_entries) → ~272 with
    # alignment padding. Range [256, 320] is generous.
    assert_true(
        s >= 256 and s <= 320,
        "MetricsSnapshot size out of expected range: " + String(s),
    )
    print("  test_metrics_snapshot_pod_size PASS, size=", s)


def test_max_workers_constant() raises:
    """The bounded-by-construction ceilings are the documented values."""
    assert_equal(MAX_WORKERS, Int(64), "MAX_WORKERS = 64")
    assert_equal(MAX_COUNTERS, Int(8), "MAX_COUNTERS = 8")
    assert_equal(MAX_TIMES, Int(4), "MAX_TIMES = 4")
    assert_equal(MAX_GAUGES, Int(4), "MAX_GAUGES = 4")
    print("  test_max_workers_constant PASS")


# -----------------------------------------------------------------------------
# Single-threaded primitive correctness
# -----------------------------------------------------------------------------


def test_counter_in_pipeline_reduce_sum() raises:
    """Counter.inc_in_pipeline across distinct worker slots sums."""
    var c = Counter()
    # Three different workers contribute 10 + 20 + 30.
    c.inc_in_pipeline(Int64(10), worker_id=0)
    c.inc_in_pipeline(Int64(20), worker_id=3)
    c.inc_in_pipeline(Int64(30), worker_id=7)
    assert_equal(c.reduce(), Int64(60), "reduce sums all worker slots")
    print("  test_counter_in_pipeline_reduce_sum PASS")


def test_counter_out_of_pipeline_reduce_sum() raises:
    """Counter.inc_out_of_pipeline accumulates into the atomic."""
    var c = Counter()
    c.inc_out_of_pipeline(Int64(7))
    c.inc_out_of_pipeline(Int64(13))
    assert_equal(c.reduce(), Int64(20), "atomic adds round-trip")
    print("  test_counter_out_of_pipeline_reduce_sum PASS")


def test_counter_mixed_paths_reduce_sum() raises:
    """Both in-pipeline and out-of-pipeline contribute to reduce."""
    var c = Counter()
    c.inc_in_pipeline(Int64(100), worker_id=2)
    c.inc_out_of_pipeline(Int64(50))
    assert_equal(c.reduce(), Int64(150), "in + out merge in reduce")
    print("  test_counter_mixed_paths_reduce_sum PASS")


def test_counter_reset_clears_all_slots() raises:
    var c = Counter()
    c.inc_in_pipeline(Int64(99), worker_id=5)
    c.inc_out_of_pipeline(Int64(11))
    assert_equal(c.reduce(), Int64(110), "pre-reset value")
    c.reset()
    assert_equal(c.reduce(), Int64(0), "reset clears every slot")
    print("  test_counter_reset_clears_all_slots PASS")


def test_time_records_nanoseconds() raises:
    """Time accumulates nanoseconds via record_ns_in_pipeline."""
    var t = Time()
    t.record_ns_in_pipeline(Int64(1_000), worker_id=0)
    t.record_ns_in_pipeline(Int64(2_000), worker_id=1)
    assert_equal(t.reduce(), Int64(3_000), "ns sums across workers")
    print("  test_time_records_nanoseconds PASS")


def test_gauge_reduce_returns_max() raises:
    """Gauge.reduce returns the maximum across slots (last-write-wins
    per slot, max-across-slots for the aggregate).
    """
    var g = Gauge()
    g.set_in_pipeline(Int64(50), worker_id=0)
    g.set_in_pipeline(Int64(120), worker_id=1)
    g.set_in_pipeline(Int64(30), worker_id=2)
    assert_equal(g.reduce(), Int64(120), "max across worker slots")
    # peek_slot returns the per-worker last-write.
    assert_equal(g.peek_slot(2), Int64(30), "peek_slot returns slot value")
    print("  test_gauge_reduce_returns_max PASS")


# -----------------------------------------------------------------------------
# MetricsSet registration + lookup
# -----------------------------------------------------------------------------


def test_metrics_set_construct_empty() raises:
    var ms = MetricsSet()
    assert_equal(ms.num_counters(), Int(0), "no counters initially")
    assert_equal(ms.num_times(), Int(0), "no times initially")
    assert_equal(ms.num_gauges(), Int(0), "no gauges initially")
    assert_equal(
        ms.num_dropped_registrations(), Int(0), "no drops initially"
    )
    print("  test_metrics_set_construct_empty PASS")


def test_register_counter_unique_names() raises:
    var ms = MetricsSet()
    assert_true(
        ms.register_counter["rows_consumed"](),
        "first register succeeds",
    )
    assert_true(
        ms.register_counter["groups_built"](),
        "second register succeeds",
    )
    assert_equal(ms.num_counters(), Int(2), "two counters registered")
    # Dup is benign (returns False, no slot consumed).
    assert_false(
        ms.register_counter["rows_consumed"](),
        "duplicate name returns False",
    )
    assert_equal(ms.num_counters(), Int(2), "still two slots after dup")
    print("  test_register_counter_unique_names PASS")


def test_register_counter_capacity_drop() raises:
    """Registering a 9th counter increments dropped_registrations."""
    var ms = MetricsSet()
    # Fill to capacity (8). Each name is comptime-different so
    # registrations succeed.
    assert_true(ms.register_counter["c0"]())
    assert_true(ms.register_counter["c1"]())
    assert_true(ms.register_counter["c2"]())
    assert_true(ms.register_counter["c3"]())
    assert_true(ms.register_counter["c4"]())
    assert_true(ms.register_counter["c5"]())
    assert_true(ms.register_counter["c6"]())
    assert_true(ms.register_counter["c7"]())
    assert_equal(ms.num_counters(), Int(MAX_COUNTERS), "filled to capacity")
    # 9th registration drops.
    assert_false(
        ms.register_counter["c8_overflow"](),
        "9th counter rejected",
    )
    assert_equal(
        ms.num_dropped_registrations(),
        Int(1),
        "dropped_registrations incremented",
    )
    print("  test_register_counter_capacity_drop PASS")


def test_register_time_capacity_drop() raises:
    """5th Time registration drops (capacity = 4)."""
    var ms = MetricsSet()
    assert_true(ms.register_time["t0"]())
    assert_true(ms.register_time["t1"]())
    assert_true(ms.register_time["t2"]())
    assert_true(ms.register_time["t3"]())
    assert_equal(ms.num_times(), Int(MAX_TIMES))
    assert_false(ms.register_time["t4_overflow"]())
    assert_equal(ms.num_dropped_registrations(), Int(1))
    print("  test_register_time_capacity_drop PASS")


def test_register_gauge_capacity_drop() raises:
    """5th Gauge registration drops (capacity = 4)."""
    var ms = MetricsSet()
    assert_true(ms.register_gauge["g0"]())
    assert_true(ms.register_gauge["g1"]())
    assert_true(ms.register_gauge["g2"]())
    assert_true(ms.register_gauge["g3"]())
    assert_equal(ms.num_gauges(), Int(MAX_GAUGES))
    assert_false(ms.register_gauge["g4_overflow"]())
    assert_equal(ms.num_dropped_registrations(), Int(1))
    print("  test_register_gauge_capacity_drop PASS")


def test_metrics_set_counter_lookup_inc() raises:
    """MetricsSet.counter[name]() returns a ref usable on the hot path."""
    var ms = MetricsSet()
    _ = ms.register_counter["rows_consumed"]()
    # Lookup returns ref → inc_in_pipeline.
    ref c = ms.counter["rows_consumed"]()
    c.inc_in_pipeline(Int64(5), worker_id=0)
    c.inc_in_pipeline(Int64(7), worker_id=3)
    # Re-lookup and verify reduce.
    assert_equal(
        ms.counter["rows_consumed"]().reduce(),
        Int64(12),
        "lookup-then-inc round-trips",
    )
    print("  test_metrics_set_counter_lookup_inc PASS")


def test_metrics_set_reduce_snapshot() raises:
    """MetricsSet.reduce() flattens every registered metric."""
    var ms = MetricsSet()
    _ = ms.register_counter["rows_consumed"]()
    _ = ms.register_time["elapsed_compute"]()
    _ = ms.register_gauge["peak_groups"]()

    # Populate.
    ms.counter["rows_consumed"]().inc_in_pipeline(Int64(42), worker_id=0)
    ms.time["elapsed_compute"]().record_ns_in_pipeline(
        Int64(1_500_000), worker_id=0
    )
    ms.gauge["peak_groups"]().set_in_pipeline(Int64(99), worker_id=0)

    var snap = ms.reduce()
    assert_equal(snap.count(), Int(3), "snapshot has 3 entries")

    # Verify by name_id.
    comptime rows_id = _literal_name_id["rows_consumed"]()
    comptime elapsed_id = _literal_name_id["elapsed_compute"]()
    comptime peak_id = _literal_name_id["peak_groups"]()

    var rows_v = snap.lookup(rows_id)
    var elapsed_v = snap.lookup(elapsed_id)
    var peak_v = snap.lookup(peak_id)
    assert_true(rows_v, "rows snapshot present")
    assert_true(elapsed_v, "elapsed snapshot present")
    assert_true(peak_v, "peak snapshot present")
    assert_equal(rows_v.value(), Int64(42))
    assert_equal(elapsed_v.value(), Int64(1_500_000))
    assert_equal(peak_v.value(), Int64(99))
    print("  test_metrics_set_reduce_snapshot PASS")


# -----------------------------------------------------------------------------
# TimeScope correctness
# -----------------------------------------------------------------------------


def test_time_scope_records_monotonic_elapsed() raises:
    """TimeScope.stop returns a non-negative elapsed value.

    The exact ns is platform-dependent — we only assert monotonicity
    (elapsed >= 0) and that stop() is idempotent.
    """
    var ts = TimeScope(worker_id=0)
    # Burn a few iterations so the platform clock can tick.
    var dummy: Int64 = 0
    for i in range(1_000):
        dummy = dummy + Int64(i)
    var elapsed = ts.stop()
    assert_true(
        elapsed >= UInt64(0),
        "elapsed >= 0 (platform clock is monotonic)",
    )
    # Idempotent — second stop returns 0.
    assert_equal(ts.stop(), UInt64(0), "second stop() returns 0")
    _ = dummy  # keepalive
    print("  test_time_scope_records_monotonic_elapsed PASS")


def test_time_scope_worker_id_round_trip() raises:
    var ts = TimeScope(worker_id=5)
    assert_equal(ts.worker_id(), Int(5))
    print("  test_time_scope_worker_id_round_trip PASS")


# -----------------------------------------------------------------------------
# parallelize — worker-disjoint write pattern
# -----------------------------------------------------------------------------


comptime N_WORKERS = 8
comptime INCS_PER_WORKER = 1_000


# =============================================================================
# THE FORK-JOIN -- real threads, via `komira_spawn_join`.
#
# A SERIAL LOOP WAS NOT TAKEN: all three arms below assert that N CONCURRENT
# workers writing byte-disjoint `per_worker` slots reduce to the exact total.
# Serialised, every one of them passes without ever exercising the
# disjointness they are named for.
#
# Each arm's body holds a safe `Pointer[T, o]` to the shared object and writes
# only the slot named by its `tid`. `spawn_join` joins every thread before it
# returns (or raises), so the object outlives every worker.
#
# The test names keep the word "parallelize": it names the SHAPE under test
# (N concurrent workers on one metric), which is unchanged.
# =============================================================================


struct _IncBody[o: MutOrigin](SpawnJoinBody):
    var obj: Pointer[Counter, Self.o]

    def __init__(out self, obj: Pointer[Counter, Self.o]):
        self.obj = obj

    def run(self, tid: Int) raises:
        for _i in range(INCS_PER_WORKER):
            self.obj[].inc_in_pipeline(Int64(1), worker_id=tid)


struct _EmitBody[o: MutOrigin](SpawnJoinBody):
    """The same disjoint write, routed through the `MetricsSet.counter[name]()`
    lookup that operators actually call."""

    var obj: Pointer[MetricsSet, Self.o]

    def __init__(out self, obj: Pointer[MetricsSet, Self.o]):
        self.obj = obj

    def run(self, tid: Int) raises:
        for _i in range(INCS_PER_WORKER):
            self.obj[].counter["rows_consumed"]().inc_in_pipeline(
                Int64(1), worker_id=tid
            )


struct _RecordBody[o: MutOrigin](SpawnJoinBody):
    """The recorded value is `i + 1`, so each worker contributes
    1+2+...+INCS_PER_WORKER -- the sum the arm asserts."""

    var obj: Pointer[Time, Self.o]

    def __init__(out self, obj: Pointer[Time, Self.o]):
        self.obj = obj

    def run(self, tid: Int) raises:
        for i in range(INCS_PER_WORKER):
            self.obj[].record_ns_in_pipeline(Int64(i + 1), worker_id=tid)


def test_parallelize_disjoint_counter_inc() raises:
    """8 workers × 1000 increments each into disjoint per_worker slots
    of a single Counter → reduce should equal 8000 exactly.

    SAFETY (parallelize block):
      * Disjointness — worker `tid` writes only to slot `tid` via
        `inc_in_pipeline(_, worker_id=tid)`. Each per_worker slot is
        an Int64 inside an InlineArray; slot writes are byte-disjoint.
      * Liveness — each worker holds a `Pointer(to=c)` carrying `c`'s own
        origin; `c` is a local of this frame and outlives the fork-join
        (synchronous), which the compiler tracks.
      * No-realloc — Counter has no resize / append surface; the
        InlineArray is fixed-size by construction.
    """
    var c = Counter()
    var body = _IncBody(Pointer(to=c))
    spawn_join(body, N_WORKERS)

    var expected = Int64(N_WORKERS * INCS_PER_WORKER)
    assert_equal(
        c.reduce(),
        expected,
        "parallelize sum: " + String(c.reduce()) + " expected " + String(expected),
    )
    print("  test_parallelize_disjoint_counter_inc PASS, total=", c.reduce())


def test_parallelize_metrics_set_lookup_path() raises:
    """Same shape, but routed through MetricsSet.counter[name]() lookup.

    Verifies the hot-path API surface (the one operators actually use)
    is parallelize-safe.
    """
    var ms = MetricsSet()
    _ = ms.register_counter["rows_consumed"]()
    var body = _EmitBody(Pointer(to=ms))
    spawn_join(body, N_WORKERS)

    var snap = ms.reduce()
    comptime rows_id = _literal_name_id["rows_consumed"]()
    var v = snap.lookup(rows_id)
    assert_true(v, "rows_consumed present in snapshot")
    var expected = Int64(N_WORKERS * INCS_PER_WORKER)
    assert_equal(v.value(), expected, "MetricsSet route sums identically")
    print("  test_parallelize_metrics_set_lookup_path PASS, total=", v.value())


def test_parallelize_time_record_ns() raises:
    """Time.record_ns_in_pipeline under parallelize sums correctly."""
    var t = Time()
    var body = _RecordBody(Pointer(to=t))
    spawn_join(body, N_WORKERS)

    # Each worker contributes 1+2+...+1000 = 500_500. Across 8 workers:
    # 8 * 500_500 = 4_004_000.
    var expected = Int64(8) * Int64(500_500)
    assert_equal(t.reduce(), expected)
    print("  test_parallelize_time_record_ns PASS, total=", t.reduce())


# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------


def main() raises:
    print("test_metrics_set")
    print("================")
    # POD audit
    test_counter_pod_size()
    test_time_pod_size()
    test_gauge_pod_size()
    test_metrics_snapshot_pod_size()
    test_max_workers_constant()
    # Primitive correctness
    test_counter_in_pipeline_reduce_sum()
    test_counter_out_of_pipeline_reduce_sum()
    test_counter_mixed_paths_reduce_sum()
    test_counter_reset_clears_all_slots()
    test_time_records_nanoseconds()
    test_gauge_reduce_returns_max()
    # MetricsSet
    test_metrics_set_construct_empty()
    test_register_counter_unique_names()
    test_register_counter_capacity_drop()
    test_register_time_capacity_drop()
    test_register_gauge_capacity_drop()
    test_metrics_set_counter_lookup_inc()
    test_metrics_set_reduce_snapshot()
    # TimeScope
    test_time_scope_records_monotonic_elapsed()
    test_time_scope_worker_id_round_trip()
    # parallelize
    test_parallelize_disjoint_counter_inc()
    test_parallelize_metrics_set_lookup_path()
    test_parallelize_time_record_ns()
    print()
    print("ALL TESTS PASS")
