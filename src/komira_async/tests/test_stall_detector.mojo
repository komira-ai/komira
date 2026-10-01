# =============================================================================
# test_stall_detector.mojo
# =============================================================================
# ReactorStallDetector. Per-worker watchdog that emits a
# structured event when a single task runs > threshold without yielding.
# Default threshold: 20ms.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false
from std.time import perf_counter_ns

from komira_async.observability.reactor_stall_detector import (
    ReactorStallDetector,
    DEFAULT_STALL_THRESHOLD_NS,
)


def test_stall_detector_construct() raises:
    """Default ctor: threshold=20ms; counters at zero."""
    var d = ReactorStallDetector()
    assert_equal(Int(d.threshold_ns()), 20_000_000)
    assert_equal(Int(d.stall_count()), 0)
    assert_false(d.has_recorded_stall())
    assert_false(d.need_preempt())


def test_stall_detector_default_threshold_alias() raises:
    """DEFAULT_STALL_THRESHOLD_NS alias matches the ctor default."""
    assert_equal(Int(DEFAULT_STALL_THRESHOLD_NS), 20_000_000)


def test_stall_detector_under_threshold_no_stall() raises:
    """A 10ms task is under the 20ms threshold — no stall emitted."""
    var d = ReactorStallDetector()
    d.task_started(Int64(1), Int64(0))
    d.task_finished(Int64(1), Int64(10_000_000))  # 10ms
    assert_equal(Int(d.stall_count()), 0)
    assert_false(d.has_recorded_stall())
    assert_false(d.need_preempt())


def test_stall_detector_above_threshold_emits_stall() raises:
    """A 25ms task exceeds the 20ms threshold — stall recorded; flag set."""
    var d = ReactorStallDetector()
    d.task_started(Int64(7), Int64(0))
    d.task_finished(Int64(7), Int64(25_000_000))  # 25ms
    assert_equal(Int(d.stall_count()), 1)
    assert_true(d.has_recorded_stall())
    assert_equal(Int(d.last_stall_task_id()), 7)
    assert_equal(Int(d.last_stall_elapsed_ns()), 25_000_000)
    assert_true(d.need_preempt())


def test_stall_detector_multiple_stalls() raises:
    """Three above-threshold tasks; counter reflects all 3; last_* reflects most recent."""
    var d = ReactorStallDetector()
    d.task_started(Int64(1), Int64(0))
    d.task_finished(Int64(1), Int64(30_000_000))  # 30ms — stall 1
    d.task_started(Int64(2), Int64(100_000_000))
    d.task_finished(Int64(2), Int64(125_000_000))  # 25ms — stall 2
    d.task_started(Int64(3), Int64(200_000_000))
    d.task_finished(Int64(3), Int64(250_000_000))  # 50ms — stall 3
    assert_equal(Int(d.stall_count()), 3)
    assert_equal(Int(d.last_stall_task_id()), 3)
    assert_equal(Int(d.last_stall_elapsed_ns()), 50_000_000)


def test_stall_detector_under_then_over() raises:
    """Under-threshold task does not poison bookkeeping for the next over-threshold task."""
    var d = ReactorStallDetector()
    d.task_started(Int64(11), Int64(0))
    d.task_finished(Int64(11), Int64(5_000_000))  # 5ms — no stall
    d.task_started(Int64(12), Int64(10_000_000))
    d.task_finished(Int64(12), Int64(40_000_000))  # 30ms — stall
    assert_equal(Int(d.stall_count()), 1)
    assert_equal(Int(d.last_stall_task_id()), 12)
    assert_equal(Int(d.last_stall_elapsed_ns()), 30_000_000)


def test_stall_detector_configurable_threshold() raises:
    """Threshold of 5ms; a 10ms task triggers stall (which would not at the default 20ms)."""
    var d = ReactorStallDetector(threshold_ns=Int64(5_000_000))
    assert_equal(Int(d.threshold_ns()), 5_000_000)
    d.task_started(Int64(99), Int64(0))
    d.task_finished(Int64(99), Int64(10_000_000))  # 10ms > 5ms
    assert_equal(Int(d.stall_count()), 1)
    assert_true(d.need_preempt())


def test_stall_detector_clear_need_preempt() raises:
    """clear_need_preempt() clears the flag but preserves the counter."""
    var d = ReactorStallDetector()
    d.task_started(Int64(1), Int64(0))
    d.task_finished(Int64(1), Int64(25_000_000))  # stall
    assert_true(d.need_preempt())
    assert_equal(Int(d.stall_count()), 1)
    d.clear_need_preempt()
    assert_false(d.need_preempt())
    assert_equal(Int(d.stall_count()), 1)  # counter survives flag clear


def test_stall_detector_realtime_25ms_synthetic() raises:
    """Use perf_counter_ns to synthesize a 25ms-busy-loop task; assert
    real-clock-driven stall detection works."""
    var d = ReactorStallDetector()
    var t0 = Int64(perf_counter_ns())
    d.task_started(Int64(42), t0)
    # Busy-loop for ~25ms via perf_counter_ns polling. NOTE: not
    # cycle-accurate but well above the 20ms threshold so jitter doesn't
    # falsify the assertion.
    var deadline_ns = t0 + Int64(25_000_000)
    while Int64(perf_counter_ns()) < deadline_ns:
        pass
    var t1 = Int64(perf_counter_ns())
    d.task_finished(Int64(42), t1)
    assert_equal(Int(d.stall_count()), 1)
    assert_equal(Int(d.last_stall_task_id()), 42)
    # Elapsed must be >= 20ms threshold; allow generous upper bound for
    # CI jitter (busy-loop overshoot common in containers).
    assert_true(d.last_stall_elapsed_ns() >= Int64(20_000_000))


def test_stall_detector_zero_threshold_every_task_stalls() raises:
    """Threshold = 0 means every non-instantaneous task is a stall.
    Useful for diagnostic / forced-stall test harnesses."""
    var d = ReactorStallDetector(threshold_ns=Int64(0))
    d.task_started(Int64(1), Int64(0))
    d.task_finished(Int64(1), Int64(1))  # 1ns task
    assert_equal(Int(d.stall_count()), 1)


def main() raises:
    test_stall_detector_construct()
    test_stall_detector_default_threshold_alias()
    test_stall_detector_under_threshold_no_stall()
    test_stall_detector_above_threshold_emits_stall()
    test_stall_detector_multiple_stalls()
    test_stall_detector_under_then_over()
    test_stall_detector_configurable_threshold()
    test_stall_detector_clear_need_preempt()
    test_stall_detector_realtime_25ms_synthetic()
    test_stall_detector_zero_threshold_every_task_stalls()
    print("[PASS] ReactorStallDetector — 10/10 tests")
