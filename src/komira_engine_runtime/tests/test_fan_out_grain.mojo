# =============================================================================
# test_fan_out_grain -- the dispatch-time fan-out cap
# =============================================================================
#
# What each test proves, and the defect it catches:
#   * a pool of at most one worker, or an unknown working-set size, is
#     returned unchanged (a cap that shrank a pool it knew nothing about);
#   * a working set below the per-worker threshold uses one worker, and a
#     larger one uses the ceiling of rows over the threshold (an off-by-one at
#     the threshold);
#   * the per-call threshold replaces the default, and a value below 1 falls
#     back to it;
#   * a large working set keeps the full pool (the cap never reduces a big
#     scan).
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_engine_runtime.fan_out_grain import (
    FANOUT_MIN_ROWS_PER_WORKER_DEFAULT,
    capped_worker_count,
)


def test_fanout_passthrough_when_max_workers_le_1() raises:
    """max_workers <= 1 is returned unchanged (nothing to cap)."""
    assert_equal(capped_worker_count(1_000_000, 1), 1)
    assert_equal(capped_worker_count(1_000_000, 0), 0)


def test_fanout_passthrough_when_rows_unknown() raises:
    """working_set_rows <= 0 (unknown cardinality) -> keep the full pool."""
    assert_equal(capped_worker_count(0, 20), 20)
    assert_equal(capped_worker_count(-1, 20), 20)


def test_fanout_tiny_set_collapses_to_one_worker() raises:
    """A working set below the per-worker threshold uses exactly 1 worker.

    A nation(25) / region(5) dim build must not fan across the whole pool.
    """
    assert_equal(capped_worker_count(25, 20), 1)
    assert_equal(capped_worker_count(1, 20), 1)
    # Exactly one full threshold's worth of rows is still one worker.
    assert_equal(capped_worker_count(FANOUT_MIN_ROWS_PER_WORKER_DEFAULT, 20), 1)


def test_fanout_ceils_to_min_rows_per_worker() raises:
    """capped == ceil(rows / MIN_ROWS_PER_WORKER), clamped to max_workers.

    rows = 3 * threshold  -> 3 workers.
    rows = 3 * threshold + 1 -> 4 workers (ceil).
    """
    var t = FANOUT_MIN_ROWS_PER_WORKER_DEFAULT
    assert_equal(capped_worker_count(t * 3, 20), 3)
    assert_equal(capped_worker_count(t * 3 + 1, 20), 4)
    assert_equal(capped_worker_count(t + 1, 20), 2)


def test_fanout_min_rows_per_worker_override() raises:
    """`min_rows_per_worker` replaces the default threshold for one call; a value
    below 1 falls back to `FANOUT_MIN_ROWS_PER_WORKER_DEFAULT`."""
    assert_equal(capped_worker_count(5_000, 20, 1_000), 5)
    assert_equal(capped_worker_count(5_001, 20, 1_000), 6)
    assert_equal(capped_worker_count(25, 20, 0), 1)
    assert_equal(
        capped_worker_count(FANOUT_MIN_ROWS_PER_WORKER_DEFAULT * 3, 20, -7),
        3,
    )


def test_fanout_large_set_keeps_full_pool() raises:
    """A large working set exceeds max_workers * threshold -> no reduction.

    This is the LARGE-QUERY no-regression guard: a 6M-lineitem / 100M scan
    keeps the full pool (the clamp is a no-op above max_workers * threshold).
    """
    var t = FANOUT_MIN_ROWS_PER_WORKER_DEFAULT
    # rows well above 20 * threshold -> clamps to max_workers.
    assert_equal(capped_worker_count(t * 20 * 5, 20), 20)
    # exactly max_workers * threshold -> exactly max_workers (no reduction).
    assert_equal(capped_worker_count(t * 20, 20), 20)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
