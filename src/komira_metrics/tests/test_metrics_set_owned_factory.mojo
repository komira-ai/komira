# =============================================================================
# test_metrics_set_owned_factory -- the OwnedPointer[MetricsSet] shape
# =============================================================================
#
# Validates new_owned_metrics_set() factory + the OwnedPointer[MetricsSet]
# field shape that every MorselOperatorImpl conformer adopts.
#
# Two-axis coverage:
#   1. Lifetime / alloc / dealloc — the OwnedPointer drops cleanly on
#      scope exit (no leak, no double-free), including under repeated
#      destroy-recreate cycles.
#   2. Hot-path API — register + record + reduce roundtrip works through
#      the OwnedPointer indirection, matching the real MapOp.execute()
#      shape.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import assert_equal, assert_true

from komira_metrics.metrics_set import (
    MetricsSet,
    MetricsSnapshot,
    METRIC_KIND_COUNTER,
    METRIC_KIND_TIME,
    new_owned_metrics_set,
)
from komira_name_registry import name_id as _literal_name_id


def test_factory_constructs_empty_metrics_set() raises:
    """Factory yields an OwnedPointer wrapping a fresh, empty MetricsSet.

    Validates that the alloc + in-place __init__ path produces a
    MetricsSet with zero registered entries (the canonical post-__init__
    state).
    """
    var ms_ptr = new_owned_metrics_set()
    assert_equal(
        ms_ptr[].num_counters(),
        0,
        "factory: new MetricsSet has 0 counters",
    )
    assert_equal(
        ms_ptr[].num_times(),
        0,
        "factory: new MetricsSet has 0 times",
    )
    assert_equal(
        ms_ptr[].num_gauges(),
        0,
        "factory: new MetricsSet has 0 gauges",
    )
    assert_equal(
        ms_ptr[].num_dropped_registrations(),
        0,
        "factory: no dropped registrations on a fresh MetricsSet",
    )


def test_factory_register_record_reduce_roundtrip() raises:
    """Validate the full hot-path: register at construction,
    record from a parallelize-style worker context, reduce for snapshot.

    Mirrors MapOp.__init__ + MapOp.execute + EXPLAIN ANALYZE walk.
    """
    var ms_ptr = new_owned_metrics_set()
    assert_true(
        ms_ptr[].register_counter["rows_processed"](),
        "register_counter rows_processed succeeds",
    )
    assert_true(
        ms_ptr[].register_time["elapsed_compute"](),
        "register_time elapsed_compute succeeds",
    )

    # Hot-path: record from a single worker (worker_id=0 — the
    # MapOp-instance-per-worker shape).
    ms_ptr[].counter["rows_processed"]().inc_in_pipeline(
        Int64(64), worker_id=0
    )
    ms_ptr[].counter["rows_processed"]().inc_in_pipeline(
        Int64(128), worker_id=0
    )
    ms_ptr[].time["elapsed_compute"]().record_ns_in_pipeline(
        Int64(500), worker_id=0
    )
    ms_ptr[].time["elapsed_compute"]().record_ns_in_pipeline(
        Int64(1500), worker_id=0
    )

    # Reduce — what EXPLAIN ANALYZE will read.
    var snap = ms_ptr[].reduce()
    assert_equal(
        snap.count(),
        2,
        "snapshot has 2 entries (counter + time)",
    )

    var rows_id = _literal_name_id["rows_processed"]()
    var rows_v = snap.lookup(rows_id)
    assert_true(rows_v.__bool__(), "rows_processed in snapshot")
    assert_equal(
        rows_v.value(),
        Int64(64 + 128),
        "rows_processed reduces to sum",
    )

    var elapsed_id = _literal_name_id["elapsed_compute"]()
    var elapsed_v = snap.lookup(elapsed_id)
    assert_true(elapsed_v.__bool__(), "elapsed_compute in snapshot")
    assert_equal(
        elapsed_v.value(),
        Int64(500 + 1500),
        "elapsed_compute reduces to sum",
    )


def test_factory_disjoint_worker_writes() raises:
    """Validate the MetricsSet's per-worker disjoint-write contract via
    the OwnedPointer.

    Three workers (0, 1, 2) each write to their own slot; reduce()
    sums across all slots. This is the shape that PIPELINE-LEVEL
    MetricsSets would use (a MetricsSet shared across workers via Arc /
    borrow). A per-instance MetricsSet uses only worker_id=0; this test still validates the underlying
    primitive holds the disjointness contract.
    """
    var ms_ptr = new_owned_metrics_set()
    _ = ms_ptr[].register_counter["rows_processed"]()

    ms_ptr[].counter["rows_processed"]().inc_in_pipeline(
        Int64(10), worker_id=0
    )
    ms_ptr[].counter["rows_processed"]().inc_in_pipeline(
        Int64(20), worker_id=1
    )
    ms_ptr[].counter["rows_processed"]().inc_in_pipeline(
        Int64(30), worker_id=2
    )

    var snap = ms_ptr[].reduce()
    var rows_id = _literal_name_id["rows_processed"]()
    var v = snap.lookup(rows_id)
    assert_true(v.__bool__(), "rows_processed reduced")
    assert_equal(
        v.value(),
        Int64(10 + 20 + 30),
        "reduce sums across worker slots",
    )


def test_factory_owned_pointer_drops_cleanly() raises:
    """Drop the OwnedPointer in a scope and confirm the program does
    not crash / leak.

    The factory's `unsafe_from_raw_pointer=` path is where a destructor
    that doesn't clean up correctly would show: a destroy-recreate cycle
    surfaces an allocator use-after-free. This test exercises construct + drop in a
    tight loop to surface those.
    """
    for _i in range(64):
        var ms_ptr = new_owned_metrics_set()
        _ = ms_ptr[].register_counter["rows_processed"]()
        _ = ms_ptr[].register_time["elapsed_compute"]()
        ms_ptr[].counter["rows_processed"]().inc_in_pipeline(
            Int64(1), worker_id=0
        )
        # ms_ptr drops here — frees backing MetricsSet + Slabs + atomics.
        _ = ms_ptr^

    # If we reach here without crashing, the destroy-recreate loop is
    # clean.
    assert_true(True, "destroy-recreate cycle clean")


def main() raises:
    test_factory_constructs_empty_metrics_set()
    test_factory_register_record_reduce_roundtrip()
    test_factory_disjoint_worker_writes()
    test_factory_owned_pointer_drops_cleanly()
    print("PASS")
