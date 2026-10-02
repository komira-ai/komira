# =============================================================================
# test_metrics_set_unregistered_lookup_quarantine.mojo
#   AN UNREGISTERED METRIC NAME MUST NOT INCREMENT A REGISTERED ONE.
# =============================================================================
#
# WHAT THIS GUARDS. `MetricsSet.counter[name]()` / `.time[name]()` /
# `.gauge[name]()` resolve a comptime name against a linear scan of registered
# slots. A MISS that returned SLOT 0 — the FIRST REGISTERED metric of that
# kind — would not lose its write; it would apply that write to an unrelated,
# real, reported metric.
#
# ⛔ A `debug_assert` CANNOT CATCH THIS. Its DEFAULT `assert_mode="none"` is
# live only at `ASSERT=all`; under `ASSERT=safe` or `ASSERT=none` it is dead in
# EVERY build configuration, TESTS INCLUDED. Without the quarantine these cases
# would not abort: they would run to completion and report a corrupted slot-0
# value.
#
# WHY IT MATTERS. Once metric values leave the process, a counter that
# silently absorbs a different metric's writes is corrupt data in a dashboard,
# indistinguishable from a real measurement.
#
# THE DESIGN: a miss is a COUNTED DROP. It is recorded in
# `num_unregistered_lookups()` and returns the QUARANTINE slot — an extra slot
# past `MAX_*` that no registration can claim and no read path
# (`reduce`, snapshot, EXPLAIN ANALYZE) iterates far enough to see.
#
# Encapsulation: pure value/ref flow — a local `MetricsSet`. No
# `UnsafePointer`, no wildcard origin introduced here.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_metrics.metrics_set import (
    MetricsSet,
    MAX_COUNTERS,
    MAX_TIMES,
    MAX_GAUGES,
)


comptime _REAL = "rows_scanned"
comptime _REAL_TIME = "scan_ns"
comptime _REAL_GAUGE = "queue_depth"
# A name NOTHING registers. This is the typo case, spelled out.
comptime _TYPO = "rows_scaned"
comptime _TYPO_TIME = "scan_n"
comptime _TYPO_GAUGE = "queue_dept"


# -----------------------------------------------------------------------------
# THE CORRUPTION CASE, one per instrument kind.
# -----------------------------------------------------------------------------


def test_unregistered_counter_lookup_does_not_touch_slot_zero() raises -> None:
    var m = MetricsSet()
    assert_true(m.register_counter[_REAL](), "the real counter registered")
    # `_REAL` is now slot 0 — the slot the old fallback returned.
    m.counter[_REAL]().inc_in_pipeline(Int64(5), 0)
    assert_equal(Int(m.counter[_REAL]().reduce()), 5, "baseline")

    # The typo. Before the fix this incremented `_REAL`.
    m.counter[_TYPO]().inc_in_pipeline(Int64(100), 0)

    assert_equal(
        Int(m.counter[_REAL]().reduce()),
        5,
        "the REGISTERED counter is UNCHANGED by the unregistered write",
    )
    assert_equal(
        m.num_unregistered_lookups(),
        1,
        "and the lost write was counted, not silently discarded",
    )


def test_unregistered_time_lookup_does_not_touch_slot_zero() raises -> None:
    var m = MetricsSet()
    assert_true(m.register_time[_REAL_TIME](), "the real time registered")
    m.time[_REAL_TIME]().record_ns_in_pipeline(Int64(7), 0)
    assert_equal(Int(m.time[_REAL_TIME]().reduce()), 7, "baseline")

    m.time[_TYPO_TIME]().record_ns_in_pipeline(Int64(999), 0)

    assert_equal(
        Int(m.time[_REAL_TIME]().reduce()),
        7,
        "the REGISTERED time is UNCHANGED",
    )
    assert_equal(m.num_unregistered_lookups(), 1, "the miss was counted")


def test_unregistered_gauge_lookup_does_not_touch_slot_zero() raises -> None:
    """The gauge case is the nastiest of the three: a gauge SETS rather than
    adds, so an unregistered write does not merely inflate slot 0, it
    OVERWRITES it with an unrelated reading."""
    var m = MetricsSet()
    assert_true(m.register_gauge[_REAL_GAUGE](), "the real gauge registered")
    m.gauge[_REAL_GAUGE]().set_in_pipeline(Int64(3), 0)
    assert_equal(Int(m.gauge[_REAL_GAUGE]().reduce()), 3, "baseline")

    m.gauge[_TYPO_GAUGE]().set_in_pipeline(Int64(4242), 0)

    assert_equal(
        Int(m.gauge[_REAL_GAUGE]().reduce()),
        3,
        "the REGISTERED gauge is NOT overwritten",
    )
    assert_equal(m.num_unregistered_lookups(), 1, "the miss was counted")


# -----------------------------------------------------------------------------
# The quarantine slot must be unreachable from every path that PUBLISHES.
# -----------------------------------------------------------------------------


def test_quarantine_slot_is_past_every_registration_ceiling() raises -> None:
    """Registration caps at `MAX_*` and every read path iterates `0 ..< n_*`.
    So filling a `MetricsSet` to its ceiling must still leave the quarantine
    slot unclaimed — otherwise a full set would resume corrupting a REAL
    metric, which is the original bug with extra steps."""
    var m = MetricsSet()
    # Fill counters to the ceiling with distinct comptime names.
    assert_true(m.register_counter["c0"](), "c0")
    assert_true(m.register_counter["c1"](), "c1")
    assert_true(m.register_counter["c2"](), "c2")
    assert_true(m.register_counter["c3"](), "c3")
    assert_true(m.register_counter["c4"](), "c4")
    assert_true(m.register_counter["c5"](), "c5")
    assert_true(m.register_counter["c6"](), "c6")
    assert_true(m.register_counter["c7"](), "c7")
    assert_equal(m.num_counters(), MAX_COUNTERS, "the set is FULL")
    # The 9th is refused, not quarantined — that is `dropped_registrations`.
    assert_true(not m.register_counter["c8"](), "the 9th is refused")
    assert_equal(m.num_dropped_registrations(), 1, "and counted as a drop")

    # Every registered counter holds its own value...
    m.counter["c0"]().inc_in_pipeline(Int64(10), 0)
    m.counter["c7"]().inc_in_pipeline(Int64(70), 0)
    # ...and an unregistered lookup against a FULL set still touches none.
    m.counter["c8"]().inc_in_pipeline(Int64(88), 0)

    assert_equal(Int(m.counter["c0"]().reduce()), 10, "c0 intact")
    assert_equal(Int(m.counter["c7"]().reduce()), 70, "c7 intact")
    assert_equal(m.num_unregistered_lookups(), 1, "the miss was counted")


def test_misses_accumulate_across_kinds() raises -> None:
    """One counter, shared by all three instruments — so a single reading
    answers "did this process emit to a metric it never registered"."""
    var m = MetricsSet()
    assert_true(m.register_counter[_REAL](), "registered")
    m.counter[_TYPO]().inc_in_pipeline(Int64(1), 0)
    m.time[_TYPO_TIME]().record_ns_in_pipeline(Int64(1), 0)
    m.gauge[_TYPO_GAUGE]().set_in_pipeline(Int64(1), 0)
    assert_equal(m.num_unregistered_lookups(), 3, "all three kinds counted")


# -----------------------------------------------------------------------------
# The negative control. Without it, a lookup that quarantined EVERYTHING —
# registered names included — would satisfy every case above.
# -----------------------------------------------------------------------------


def test_registered_lookups_still_resolve_and_count_no_misses() raises -> None:
    var m = MetricsSet()
    assert_true(m.register_counter[_REAL](), "counter registered")
    assert_true(m.register_time[_REAL_TIME](), "time registered")
    assert_true(m.register_gauge[_REAL_GAUGE](), "gauge registered")

    m.counter[_REAL]().inc_in_pipeline(Int64(11), 0)
    m.counter[_REAL]().inc_out_of_pipeline(Int64(1))
    m.time[_REAL_TIME]().record_ns_in_pipeline(Int64(22), 0)
    m.gauge[_REAL_GAUGE]().set_in_pipeline(Int64(33), 0)

    assert_equal(Int(m.counter[_REAL]().reduce()), 12, "counter resolved")
    assert_equal(Int(m.time[_REAL_TIME]().reduce()), 22, "time resolved")
    assert_equal(Int(m.gauge[_REAL_GAUGE]().reduce()), 33, "gauge resolved")
    assert_equal(
        m.num_unregistered_lookups(),
        0,
        "a REGISTERED lookup is NOT counted as a miss",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
