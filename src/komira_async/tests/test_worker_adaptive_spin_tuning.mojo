# =============================================================================
# test_worker_adaptive_spin_tuning.mojo
# =============================================================================
# Regression test for the adaptive park-on-empty spin heuristic.
#
# What the fix does
# -----------------
# Replaces the comptime `SPIN_LIMIT=8192` constant with a per-worker
# adaptive `_spin_limit` field that tracks observed spin-window walls
# (time-from-spin-start-to-catching-work) via an EWMA + a
# consecutive-empty-window counter. The 3-tier classifier maps:
#   < 1 µs       spin → SPIN_LIMIT_MIN (256)  — back-to-back compute
#   < 100 µs     spin → SPIN_LIMIT_MID (2048) — mixed
#   >= 100 µs    spin → SPIN_LIMIT_MAX (8192) — IO-bound scans / HTTP
#
# Workers that NEVER observe work in a run (e.g. the idle workers of a
# narrow fan-out) cannot adapt via
# EWMA — they have no sample. The empty-window-counter path force-
# tier-downs after EMPTY_WINDOW_K=3 consecutive empty windows.
#
# This test asserts both adaptation paths converge correctly without
# disturbing the IO-class default.
#
# Why this is the load-bearing regression test
# --------------------------------------------
# The bug being fixed is a PERFORMANCE bug (idle workers each burning
# ~720 µs of sched_yield per spin window during a narrow fan-out); the
# symptom is idle workers contending for CPU with the active ones.
# on both workload classes + correct initial state + reset semantics —
# are the cheapest empirical probes of the fix without resorting to a
# microbenchmark.
#
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.worker import Worker


# =============================================================================
# Helpers
# =============================================================================


def _make_worker() raises -> Worker[NoopSink]:
    """Construct a Worker with BACKEND_MOCK — the tests below do not
    enter any spin-loop syscalls, they only drive the adaptive state
    mutators directly via the `_test_simulate_*` helpers, so the IO
    backend is irrelevant.
    """
    return Worker[NoopSink](
        worker_id=UInt16(0),
        sink=NoopSink(_placeholder=UInt8(0)),
        backend=BACKEND_MOCK,
    )


# =============================================================================
# Initial-state tests
# =============================================================================


def test_initial_spin_limit_is_max() raises:
    """Cold-start invariant — every Worker starts at SPIN_LIMIT_MAX
    (8192). Preserves the IO-class 390 µs inter-dispatch coverage
    until the first observation overrides it.
    """
    var w = _make_worker()
    assert_equal(w.spin_limit_current(), 8192)


def test_initial_consecutive_empty_windows_is_zero() raises:
    """Cold-start invariant — counter starts at 0."""
    var w = _make_worker()
    assert_equal(Int(w.consecutive_empty_windows()), 0)


def test_initial_avg_spin_ns_is_io_class() raises:
    """Cold-start invariant — EWMA seeded at INITIAL_AVG_SPIN_NS
    (400_000 ns = IO class). This preserves SPIN_LIMIT_MAX when
    `_tier_for_spin` is consulted before any observation lands.
    """
    var w = _make_worker()
    assert_equal(Int(w.avg_spin_ns()), 400_000)


# =============================================================================
# EWMA convergence — compute-class (sub-µs spin walls)
# =============================================================================


def test_compute_class_converges_to_min_spin_limit() raises:
    """Convergence on COMPUTE workload (parquet-write per-col fanout
    style, sub-µs spin walls): after a burst of observed work events
    with 100 ns spin walls, the EWMA should converge below
    SPIN_THRESHOLD_FAST_NS (1000 ns) and spin_limit should reach
    SPIN_LIMIT_MIN (256).

    EWMA: new = (old * 7 + sample) / 8.
    Starting from 400_000 (cold seed) with sample = 100:
      After  8 samples ≈ ~140K
      After 16 samples ≈ ~36K
      After 24 samples ≈ ~9K
      After 32 samples ≈ ~2K
      After 40 samples ≈ ~600
      After 48 samples ≈ ~200
    By 64 samples we are very close to the asymptote (100 ns).
    """
    var w = _make_worker()
    for _ in range(64):
        w._test_simulate_found_work_with_spin(Int64(100))
    # EWMA should be well below SPIN_THRESHOLD_FAST_NS=1000.
    assert_true(w.avg_spin_ns() < Int64(1_000))
    # Tier should be SPIN_LIMIT_MIN.
    assert_equal(w.spin_limit_current(), 256)
    # Observed work resets empty-window counter.
    assert_equal(Int(w.consecutive_empty_windows()), 0)


def test_compute_class_reaches_min_within_50_samples() raises:
    """Empirical convergence-speed gate — within 50 samples of 100 ns
    spin walls, the worker MUST have reached SPIN_LIMIT_MIN. Guards
    against a future EWMA window change that would slow adaptation
    pathologically.
    """
    var w = _make_worker()
    var reached_min_at = -1
    for i in range(50):
        w._test_simulate_found_work_with_spin(Int64(100))
        if w.spin_limit_current() == 256 and reached_min_at < 0:
            reached_min_at = i
    assert_true(reached_min_at >= 0)
    assert_true(reached_min_at < 50)


# =============================================================================
# EWMA convergence — IO-class (IO-bound scans / HTTP, spin walls >= 100 µs)
# =============================================================================


def test_io_class_stays_at_max_spin_limit() raises:
    """Convergence on IO workload (IO-class ~390 µs spin wall):
    after a burst of observed work events with 390_000 ns spin walls,
    the EWMA should stay >= SPIN_THRESHOLD_MID_NS (100_000 ns) and
    spin_limit should remain SPIN_LIMIT_MAX (8192).

    Starts at 400_000 (seed); 390_000 samples drive the EWMA close to
    390_000 (asymptote) — both well above the IO threshold.
    """
    var w = _make_worker()
    for _ in range(32):
        w._test_simulate_found_work_with_spin(Int64(390_000))
    # EWMA stays in IO tier.
    assert_true(w.avg_spin_ns() >= Int64(100_000))
    # spin_limit stays at MAX.
    assert_equal(w.spin_limit_current(), 8192)


def test_mid_class_converges_to_mid_spin_limit() raises:
    """Convergence on MID workload (10 µs spin walls, between FAST and
    MID thresholds): EWMA should land between SPIN_THRESHOLD_FAST_NS
    and SPIN_THRESHOLD_MID_NS, and spin_limit should reach
    SPIN_LIMIT_MID (2048).
    """
    var w = _make_worker()
    for _ in range(64):
        w._test_simulate_found_work_with_spin(Int64(10_000))
    assert_true(w.avg_spin_ns() >= Int64(1_000))
    assert_true(w.avg_spin_ns() < Int64(100_000))
    assert_equal(w.spin_limit_current(), 2048)


# =============================================================================
# Force-tier-down on consecutive empty windows
# =============================================================================


def test_empty_window_below_threshold_does_not_tier_down() raises:
    """With EMPTY_WINDOW_K=3, fewer than 3 consecutive empty windows
    must NOT force tier-down — spin_limit stays at SPIN_LIMIT_MAX.
    """
    var w = _make_worker()
    w._test_simulate_empty_window()
    assert_equal(w.spin_limit_current(), 8192)
    assert_equal(Int(w.consecutive_empty_windows()), 1)
    w._test_simulate_empty_window()
    assert_equal(w.spin_limit_current(), 8192)
    assert_equal(Int(w.consecutive_empty_windows()), 2)


def test_empty_window_at_threshold_forces_tier_down() raises:
    """At exactly EMPTY_WINDOW_K=3 consecutive empty windows,
    spin_limit FORCES down to SPIN_LIMIT_MIN regardless of EWMA.
    This is the path that catches the parquet-write idle-cohort
    case (workers that NEVER observe work and therefore can't update
    their EWMA).
    """
    var w = _make_worker()
    w._test_simulate_empty_window()
    w._test_simulate_empty_window()
    w._test_simulate_empty_window()
    assert_equal(Int(w.consecutive_empty_windows()), 3)
    assert_equal(w.spin_limit_current(), 256)
    # EWMA was NOT updated — still at the initial IO-class seed.
    assert_equal(Int(w.avg_spin_ns()), 400_000)


def test_observed_work_resets_empty_window_counter() raises:
    """Reset semantics — after the worker has tier-down'd from empty
    windows, the first observed work event must reset the counter
    AND recompute spin_limit from EWMA.
    """
    var w = _make_worker()
    # Get tier-down'd via the empty path.
    w._test_simulate_empty_window()
    w._test_simulate_empty_window()
    w._test_simulate_empty_window()
    assert_equal(w.spin_limit_current(), 256)
    # Observe an IO-class spin wall — counter resets, EWMA still IO-seeded.
    w._test_simulate_found_work_with_spin(Int64(390_000))
    assert_equal(Int(w.consecutive_empty_windows()), 0)
    # spin_limit recomputed from EWMA: starts at 400K, sample 390K →
    # new EWMA = (400_000 * 7 + 390_000) / 8 = 398_750 → still IO tier.
    assert_equal(w.spin_limit_current(), 8192)


# =============================================================================
# Interleaved patterns (realistic workload shapes)
# =============================================================================


def test_realistic_parquet_write_idle_worker_pattern() raises:
    """Realistic shape — 11 idle workers during parquet-write's 32-way
    fanout: they NEVER observe work, only see empty windows. After the
    3-window force-tier-down they sit at SPIN_LIMIT_MIN for the
    duration of the run. The next park happens 32x faster
    (256 vs 8192 iters), freeing CPU for the 21 active workers.
    """
    var w = _make_worker()
    for _ in range(20):
        w._test_simulate_empty_window()
    assert_equal(w.spin_limit_current(), 256)
    assert_equal(Int(w.consecutive_empty_windows()), 20)
    # EWMA untouched — still at the initial seed.
    assert_equal(Int(w.avg_spin_ns()), 400_000)


def test_realistic_parquet_write_active_worker_pattern() raises:
    """Realistic shape — active workers during parquet-write's column
    encode: rapid back-to-back batched dispatch with sub-µs spin walls
    between observations. The EWMA converges to compute-class
    quickly; the empty-window counter never accumulates.
    """
    var w = _make_worker()
    for _ in range(64):
        w._test_simulate_found_work_with_spin(Int64(200))
    assert_equal(w.spin_limit_current(), 256)
    assert_equal(Int(w.consecutive_empty_windows()), 0)


def test_io_to_compute_workload_switch() raises:
    """Workload switch — start IO-class (IO-bound scans / HTTP), then
    pivot to compute-class (parquet-write). Spin_limit must adapt
    DOWN (8192 → 256) as the EWMA absorbs the new sample distribution.
    """
    var w = _make_worker()
    # IO class, spin_limit stays at MAX.
    for _ in range(16):
        w._test_simulate_found_work_with_spin(Int64(390_000))
    assert_equal(w.spin_limit_current(), 8192)
    # pivot to compute class.
    for _ in range(64):
        w._test_simulate_found_work_with_spin(Int64(100))
    assert_equal(w.spin_limit_current(), 256)
    assert_true(w.avg_spin_ns() < Int64(1_000))


def test_compute_to_io_workload_switch() raises:
    """Reverse workload switch — start compute-class, then pivot to
    IO-class. Spin_limit must adapt UP (256 → 8192) as the EWMA
    absorbs the larger samples. This protects IO-bound scans / HTTP from
    a prior compute-class workload tainting their dispatch gaps.
    """
    var w = _make_worker()
    # compute class, drive down to MIN.
    for _ in range(64):
        w._test_simulate_found_work_with_spin(Int64(100))
    assert_equal(w.spin_limit_current(), 256)
    # pivot to IO class.
    for _ in range(64):
        w._test_simulate_found_work_with_spin(Int64(390_000))
    assert_equal(w.spin_limit_current(), 8192)
    assert_true(w.avg_spin_ns() >= Int64(100_000))


# =============================================================================
# Sample-clamp invariant — outlier resistance
# =============================================================================


def test_outlier_sample_is_clamped() raises:
    """The EWMA must resist a single huge outlier (e.g. ~1 s warm-up
    pause before first dispatch). The sample clamp caps any spin wall
    at 2_000_000 ns (2 ms). Without the clamp, one outlier would
    skew the EWMA into a stable-IO-class state that subsequent
    sub-µs samples could not drag down quickly.
    """
    var w = _make_worker()
    # Simulate a single 1-second outlier.
    w._test_simulate_found_work_with_spin(Int64(1_000_000_000))
    # EWMA = (400_000 * 7 + clamp(2_000_000)) / 8 = ( 2_800_000 +
    # 2_000_000 ) / 8 = 600_000. Without clamp it would be ~125_350_000.
    assert_true(w.avg_spin_ns() < Int64(1_000_000))


def main() raises:
    # Initial-state tests
    test_initial_spin_limit_is_max()
    test_initial_consecutive_empty_windows_is_zero()
    test_initial_avg_spin_ns_is_io_class()
    # EWMA convergence — compute class
    test_compute_class_converges_to_min_spin_limit()
    test_compute_class_reaches_min_within_50_samples()
    # EWMA convergence — IO + MID class
    test_io_class_stays_at_max_spin_limit()
    test_mid_class_converges_to_mid_spin_limit()
    # Empty-window force-tier-down
    test_empty_window_below_threshold_does_not_tier_down()
    test_empty_window_at_threshold_forces_tier_down()
    test_observed_work_resets_empty_window_counter()
    # Realistic patterns
    test_realistic_parquet_write_idle_worker_pattern()
    test_realistic_parquet_write_active_worker_pattern()
    test_io_to_compute_workload_switch()
    test_compute_to_io_workload_switch()
    # Sample-clamp invariant
    test_outlier_sample_is_clamped()
    print("PASS test_worker_adaptive_spin_tuning")
