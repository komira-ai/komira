# =============================================================================
# test_hot_shard_metrics.mojo
# =============================================================================
# HotShardMetrics. Per-worker counter for work completed.
# Aggregator (free fn) computes coefficient of variation across N
# worker-counter samples; alert if CV > 0.3 (sustained for K consecutive
# ticks — that K-of-K logic is; 1.26 ships single-snapshot CV).
#
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false
from std.collections import List

from komira_async.observability.hot_shard_metrics import (
    HotShardMetrics,
    DEFAULT_IMBALANCE_CV_THRESHOLD,
    compute_cv,
    is_imbalanced,
)


# ---------------------------------------------------------------------------
# HotShardMetrics tests — per-worker counter
# ---------------------------------------------------------------------------

def test_metrics_construct() raises:
    """Ctor with worker_id; counter at 0; worker_id() reflects ctor arg."""
    var m = HotShardMetrics(worker_id=UInt16(5))
    assert_equal(Int(m.worker_id()), 5)
    assert_equal(Int(m.work_completed()), 0)


def test_metrics_record_increments() raises:
    """record_task_completed × 100 → work_completed == 100."""
    var m = HotShardMetrics(worker_id=UInt16(0))
    var i = 0
    while i < 100:
        m.record_task_completed()
        i = i + 1
    assert_equal(Int(m.work_completed()), 100)


def test_metrics_record_n_tasks() raises:
    """record_n_tasks_completed(50) → work_completed == 50."""
    var m = HotShardMetrics(worker_id=UInt16(0))
    m.record_n_tasks_completed(Int64(50))
    assert_equal(Int(m.work_completed()), 50)


def test_metrics_snapshot_delta() raises:
    """snapshot returns work_completed; delta tracks the difference
    between successive snapshots."""
    var m = HotShardMetrics(worker_id=UInt16(0))
    m.record_n_tasks_completed(Int64(100))
    var s1 = m.snapshot()
    assert_equal(Int(s1), 100)
    assert_equal(Int(m.delta_since_last_snapshot()), 0)  # immediately after snapshot
    m.record_n_tasks_completed(Int64(50))
    var d = m.delta_since_last_snapshot()
    assert_equal(Int(d), 50)
    var s2 = m.snapshot()
    assert_equal(Int(s2), 150)


def test_metrics_record_zero_n() raises:
    """Recording zero tasks is a no-op."""
    var m = HotShardMetrics(worker_id=UInt16(0))
    m.record_n_tasks_completed(Int64(0))
    assert_equal(Int(m.work_completed()), 0)


# ---------------------------------------------------------------------------
# CV aggregator tests — free fn `compute_cv` over List[Int64] samples
# ---------------------------------------------------------------------------

def test_cv_default_threshold_alias() raises:
    """DEFAULT_IMBALANCE_CV_THRESHOLD alias matches(CV > 0.3)."""
    # Float comparison via abs-delta tolerance.
    var diff = DEFAULT_IMBALANCE_CV_THRESHOLD - Float64(0.3)
    if diff < Float64(0.0):
        diff = -diff
    assert_true(diff < Float64(0.0001))


def test_cv_balanced_zero() raises:
    """Identical samples → CV ≈ 0.0; not imbalanced."""
    var samples = List[Int64]()
    samples.append(Int64(100))
    samples.append(Int64(100))
    samples.append(Int64(100))
    samples.append(Int64(100))
    var cv = compute_cv(samples)
    # CV should be very close to 0 (epsilon for float arithmetic).
    var abs_cv = cv
    if abs_cv < Float64(0.0):
        abs_cv = -abs_cv
    assert_true(abs_cv < Float64(0.001))
    assert_false(is_imbalanced(samples))


def test_cv_balanced_low() raises:
    """Slight variation → CV < 0.1; not imbalanced."""
    var samples = List[Int64]()
    samples.append(Int64(100))
    samples.append(Int64(105))
    samples.append(Int64(95))
    samples.append(Int64(102))
    var cv = compute_cv(samples)
    assert_true(cv < Float64(0.1))
    assert_false(is_imbalanced(samples))


def test_cv_skewed_one_hot() raises:
    """One worker has 10× others' work → CV > 0.3; imbalanced."""
    var samples = List[Int64]()
    samples.append(Int64(1000))
    samples.append(Int64(100))
    samples.append(Int64(100))
    samples.append(Int64(100))
    var cv = compute_cv(samples)
    assert_true(cv > Float64(0.3))
    assert_true(is_imbalanced(samples))


def test_cv_skewed_90_10() raises:
    """One worker at 900 vs three at 100 → CV > 0.3; imbalanced."""
    var samples = List[Int64]()
    samples.append(Int64(900))
    samples.append(Int64(100))
    samples.append(Int64(100))
    samples.append(Int64(100))
    var cv = compute_cv(samples)
    assert_true(cv > Float64(0.3))
    assert_true(is_imbalanced(samples))


def test_cv_zero_mean() raises:
    """All-zero samples → CV defined as 0.0 (no work, not imbalanced)."""
    var samples = List[Int64]()
    samples.append(Int64(0))
    samples.append(Int64(0))
    samples.append(Int64(0))
    samples.append(Int64(0))
    var cv = compute_cv(samples)
    assert_equal(cv, Float64(0.0))
    assert_false(is_imbalanced(samples))


def test_cv_single_worker() raises:
    """Single sample → CV == 0.0 (no variation across 1 worker)."""
    var samples = List[Int64]()
    samples.append(Int64(100))
    var cv = compute_cv(samples)
    assert_equal(cv, Float64(0.0))
    assert_false(is_imbalanced(samples))


def test_cv_empty_samples() raises:
    """Empty samples list → CV == 0.0 (defined; not imbalanced)."""
    var samples = List[Int64]()
    var cv = compute_cv(samples)
    assert_equal(cv, Float64(0.0))
    assert_false(is_imbalanced(samples))


def test_cv_realistic_8_workers_balanced() raises:
    """Realistic 8-worker balanced workload — CV stays low; not imbalanced."""
    var samples = List[Int64]()
    samples.append(Int64(200))
    samples.append(Int64(195))
    samples.append(Int64(205))
    samples.append(Int64(198))
    samples.append(Int64(202))
    samples.append(Int64(210))
    samples.append(Int64(196))
    samples.append(Int64(203))
    var cv = compute_cv(samples)
    assert_true(cv < Float64(0.05))
    assert_false(is_imbalanced(samples))


def test_cv_realistic_8_workers_skewed() raises:
    """Realistic 8-worker skewed workload (one hot shard) — CV > 0.3; imbalanced."""
    var samples = List[Int64]()
    samples.append(Int64(800))
    samples.append(Int64(50))
    samples.append(Int64(60))
    samples.append(Int64(55))
    samples.append(Int64(50))
    samples.append(Int64(60))
    samples.append(Int64(50))
    samples.append(Int64(55))
    var cv = compute_cv(samples)
    assert_true(cv > Float64(0.3))
    assert_true(is_imbalanced(samples))


def test_cv_threshold_configurable() raises:
    """is_imbalanced takes a configurable threshold."""
    var samples = List[Int64]()
    samples.append(Int64(200))
    samples.append(Int64(220))
    samples.append(Int64(180))
    samples.append(Int64(210))
    # CV ~0.07; imbalanced @ 0.05 threshold; not imbalanced @ 0.5.
    assert_true(is_imbalanced(samples, threshold_cv=Float64(0.05)))
    assert_false(is_imbalanced(samples, threshold_cv=Float64(0.5)))


def test_metrics_concurrent_pattern_via_separate_workers() raises:
    """Aggregator pattern: per-worker metrics; collect work_completed
    into a stack-local List[Int64]; compute CV.

    This is the canonical use pattern — HotShardMetrics is
    NOT Copyable (OwnedPointer field), so the aggregator can't take
    `List[HotShardMetrics]`. Instead the caller materializes
    `List[Int64]` from each metric's work_completed() and feeds it to
    compute_cv().
    """
    var w0 = HotShardMetrics(worker_id=UInt16(0))
    var w1 = HotShardMetrics(worker_id=UInt16(1))
    var w2 = HotShardMetrics(worker_id=UInt16(2))
    var w3 = HotShardMetrics(worker_id=UInt16(3))
    w0.record_n_tasks_completed(Int64(800))
    w1.record_n_tasks_completed(Int64(50))
    w2.record_n_tasks_completed(Int64(60))
    w3.record_n_tasks_completed(Int64(55))
    var samples = List[Int64]()
    samples.append(w0.work_completed())
    samples.append(w1.work_completed())
    samples.append(w2.work_completed())
    samples.append(w3.work_completed())
    assert_true(is_imbalanced(samples))


def main() raises:
    test_metrics_construct()
    test_metrics_record_increments()
    test_metrics_record_n_tasks()
    test_metrics_snapshot_delta()
    test_metrics_record_zero_n()
    test_cv_default_threshold_alias()
    test_cv_balanced_zero()
    test_cv_balanced_low()
    test_cv_skewed_one_hot()
    test_cv_skewed_90_10()
    test_cv_zero_mean()
    test_cv_single_worker()
    test_cv_empty_samples()
    test_cv_realistic_8_workers_balanced()
    test_cv_realistic_8_workers_skewed()
    test_cv_threshold_configurable()
    test_metrics_concurrent_pattern_via_separate_workers()
    print("[PASS] HotShardMetrics + CV aggregator — 17/17 tests")
