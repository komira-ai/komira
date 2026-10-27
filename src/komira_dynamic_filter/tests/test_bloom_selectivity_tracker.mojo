# =============================================================================
# Unit tests for SelectivityTracker (bloom pushdown)
# =============================================================================
#
# Scenarios: immediate pause on 100% pass, pause after a partially
# unselective window, staying active when selective, exponential backoff,
# resuming when selective, zero-input batches, multiplier saturation (on
# the fast path and on window-decided pauses), the one-row fast path.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_dynamic_filter.selectivity_tracker import SelectivityTracker


# -----------------------------------------------------------------------------
# Scenario `selectivity_tracker_pauses_immediately_on_100_percent_pass`.
# Fast path: first batch shows 100% pass rate -> immediate pause.
# -----------------------------------------------------------------------------
def test_pauses_immediately_on_100_percent_pass() raises:
    var tracker = SelectivityTracker(0.50)
    # First batch: all rows pass (100% pass rate).
    # Should pause immediately (fast path).
    assert_true(tracker.should_apply())
    tracker.record(100, 100)
    assert_true(tracker.is_paused())
    assert_false(tracker.should_apply())


# -----------------------------------------------------------------------------
# Scenario `selectivity_tracker_pauses_after_window_when_partially_unselective`.
# 60% pass rate after 6 batches -> pauses (above threshold 0.50).
# -----------------------------------------------------------------------------
def test_pauses_after_window_when_partially_unselective() raises:
    var tracker = SelectivityTracker(0.50)
    # Feed batches where 60% pass (pass_rate = 0.60 > 0.50 threshold).
    # First batch: 60% pass, NOT 100% so no immediate pause.
    for _ in range(6):
        assert_true(tracker.should_apply())
        tracker.record(100, 60)
    # After window: should be paused (0.60 > 0.50).
    assert_true(tracker.is_paused())


# -----------------------------------------------------------------------------
# Scenario `selectivity_tracker_stays_active_when_selective`.
# 20% pass rate stays active.
# -----------------------------------------------------------------------------
def test_stays_active_when_selective() raises:
    var tracker = SelectivityTracker(0.50)
    # Feed 6 batches where 20% pass (pass_rate = 0.20 < 0.50).
    for _ in range(6):
        assert_true(tracker.should_apply())
        tracker.record(100, 20)
    # Should NOT be paused.
    assert_false(tracker.is_paused())
    assert_true(tracker.should_apply())


# -----------------------------------------------------------------------------
# Scenario `selectivity_tracker_exponential_backoff`.
# After first pause (10 skips), second pause is 20 skips (multiplier=2).
# -----------------------------------------------------------------------------
def test_exponential_backoff() raises:
    var tracker = SelectivityTracker(0.50)
    # First batch: 100% pass -> immediate pause with multiplier=1 -> skip 10 batches.
    assert_true(tracker.should_apply())
    tracker.record(100, 100)
    assert_true(tracker.is_paused())

    # Skip 10 batches.
    for _ in range(10):
        assert_false(tracker.should_apply())
    # Pause expired, should re-check.
    assert_true(tracker.should_apply())

    # Second window: first batch all pass again -> immediate pause with multiplier=2 -> skip 20.
    tracker.record(100, 100)
    assert_true(tracker.is_paused())

    # Count how many batches are skipped.
    var skipped = 0
    while not tracker.should_apply():
        skipped += 1
    assert_equal(skipped, 20)


# -----------------------------------------------------------------------------
# Scenario `selectivity_tracker_resumes_when_selective`.
# Pause expires -> selective batches resume tracking, backoff resets.
# -----------------------------------------------------------------------------
def test_resumes_when_selective() raises:
    var tracker = SelectivityTracker(0.50)
    # First batch: 100% pass -> immediate pause.
    assert_true(tracker.should_apply())
    tracker.record(100, 100)
    assert_true(tracker.is_paused())

    # Skip through pause.
    while not tracker.should_apply():
        pass

    # Re-check: now selective (20% pass) -> resumes, backoff resets.
    for _ in range(6):
        assert_true(tracker.should_apply())
        tracker.record(100, 20)
    assert_false(tracker.is_paused())


# -----------------------------------------------------------------------------
# Edge case: zero-input batches do not crash and do not push the window.
# (Defensive: the "if window_input > 0 else 1.0" branch must be safe.)
# -----------------------------------------------------------------------------
def test_zero_input_batches() raises:
    var tracker = SelectivityTracker(0.50)
    # Six batches with input=0, output=0. The tracker increments batches_in_window
    # regardless, so after 6 the window evaluates with pass_rate=1.0 (the
    # else branch) and pauses.
    for _ in range(6):
        assert_true(tracker.should_apply())
        tracker.record(0, 0)
    # Empty windows treated as 100% pass -> paused.
    assert_true(tracker.is_paused())


# -----------------------------------------------------------------------------
# Multiplier saturates at 64.
# `(self.pause_multiplier * 2).min(64)`.
# -----------------------------------------------------------------------------
def test_multiplier_saturates_at_64() raises:
    var tracker = SelectivityTracker(0.50)
    # Force ~10 consecutive immediate pauses to saturate multiplier.
    for _ in range(10):
        # Skip through previous pause.
        while not tracker.should_apply():
            pass
        # Trigger pause again with 100% pass.
        tracker.record(100, 100)
        assert_true(tracker.is_paused())
    # After saturation, the next pause should be 64 * BACKOFF_BASE = 640.
    while not tracker.should_apply():
        pass
    tracker.record(100, 100)
    var skipped = 0
    while not tracker.should_apply():
        skipped += 1
    assert_equal(skipped, 640)


# -----------------------------------------------------------------------------
# A 100% pass batch that is not the first of its window takes no fast path:
# only the window evaluation can pause the filter.
# -----------------------------------------------------------------------------
def test_full_pass_after_first_batch_is_no_fast_path() raises:
    var tracker = SelectivityTracker(0.50)
    tracker.record(100, 0)
    for _ in range(4):
        tracker.record(100, 100)
        assert_false(tracker.is_paused(), "batches 2..5 do not pause")
        assert_true(tracker.should_apply())
    # Batch 6 closes the window: 400 of 600 passed, 0.67 >= 0.50.
    tracker.record(100, 100)
    assert_true(tracker.is_paused())
    var skipped = 0
    while not tracker.should_apply():
        skipped += 1
    assert_equal(skipped, 10)


# -----------------------------------------------------------------------------
# The window closes on its sixth batch, not before; a pass rate exactly at the
# threshold pauses; one row under it does not.
# -----------------------------------------------------------------------------
def test_window_boundary_and_threshold_equality() raises:
    var at = SelectivityTracker(0.50)
    for b in range(6):
        assert_false(at.is_paused(), "not paused before batch " + String(b + 1))
        at.record(100, 50)
    assert_true(at.is_paused(), "pass rate 0.50 equals the threshold")

    var under = SelectivityTracker(0.50)
    for _ in range(5):
        under.record(100, 50)
    under.record(100, 49)
    assert_false(under.is_paused(), "pass rate 299/600 is under 0.50")

    var custom = SelectivityTracker(0.90)
    for _ in range(6):
        custom.record(100, 89)
    assert_false(custom.is_paused(), "0.89 is under the 0.90 threshold")


# -----------------------------------------------------------------------------
# After a window is evaluated its counters start again from zero: the next
# window is judged on its own six batches.
# -----------------------------------------------------------------------------
def test_window_counters_reset_after_evaluation() raises:
    var tracker = SelectivityTracker(0.50)
    for _ in range(6):
        tracker.record(100, 0)
    assert_false(tracker.is_paused())
    # Second window: 99% pass. With stale counters it would close after one
    # batch, or average down to 594/1200 and stay active.
    tracker.record(100, 99)
    for b in range(4):
        assert_false(tracker.is_paused(), "second window batch " + String(b + 2))
        tracker.record(100, 99)
    assert_false(tracker.is_paused())
    tracker.record(100, 99)
    assert_true(tracker.is_paused(), "second window alone: 0.99")


# -----------------------------------------------------------------------------
# A selective window resets the backoff: the next pause is the base 10
# batches again, not the doubled 20.
# -----------------------------------------------------------------------------
def test_selective_window_resets_backoff() raises:
    var tracker = SelectivityTracker(0.50)
    tracker.record(100, 100)  # fast path: pause 10, multiplier 2
    while not tracker.should_apply():
        pass
    for _ in range(6):
        tracker.record(100, 10)  # selective: multiplier back to 1
    assert_false(tracker.is_paused())
    tracker.record(100, 100)  # first batch of a new window: fast path
    var skipped = 0
    while not tracker.should_apply():
        skipped += 1
    assert_equal(skipped, 10)


# -----------------------------------------------------------------------------
# A pause from the window evaluation (not the fast path) lasts BACKOFF_BASE
# batches at multiplier 1; the selective window after it closes on its sixth
# batch, stays active and leaves the multiplier at 1.
# -----------------------------------------------------------------------------
def test_window_pause_then_selective_window() raises:
    var tracker = SelectivityTracker(0.50)
    for _ in range(5):
        tracker.record(100, 60)
    tracker.record(100, 60)  # window closes at 0.60: pause 10
    assert_true(tracker.is_paused())
    var skipped = 0
    while not tracker.should_apply():
        skipped += 1
    assert_equal(skipped, 10)
    assert_false(tracker.is_paused())
    # A window of 0.10 must stay active, and needs all six batches to close.
    tracker.record(100, 10)
    for _ in range(4):
        tracker.record(100, 10)
        assert_false(tracker.is_paused())
    tracker.record(100, 10)
    assert_false(tracker.is_paused())
    assert_equal(tracker.pause_multiplier, 1)


# -----------------------------------------------------------------------------
# The passed-row count starts again from zero with each window: a selective
# window after a near-threshold one is judged on its own rows.
# -----------------------------------------------------------------------------
def test_window_passed_rows_reset_after_evaluation() raises:
    var tracker = SelectivityTracker(0.50)
    for _ in range(6):
        tracker.record(100, 45)
    assert_false(tracker.is_paused(), "0.45 is selective")
    # With 270 stale passed rows this window would read 330/600 = 0.55.
    for _ in range(6):
        tracker.record(100, 10)
    assert_false(tracker.is_paused(), "second window alone: 0.10")


# -----------------------------------------------------------------------------
# Pauses decided by the window evaluation back off too, and saturate at 64x:
# eight unselective windows in a row pause 10, 20, 40, 80, 160, 320, 640 and
# again 640 batches.
# -----------------------------------------------------------------------------
def test_window_pauses_back_off() raises:
    var tracker = SelectivityTracker(0.50)
    var want: List[Int] = [10, 20, 40, 80, 160, 320, 640, 640]
    for p in range(len(want)):
        for _ in range(6):
            assert_true(tracker.should_apply())
            tracker.record(100, 60)
        assert_true(tracker.is_paused(), "window " + String(p + 1))
        var skipped = 0
        while not tracker.should_apply():
            skipped += 1
        assert_equal(skipped, want[p], "pause after window " + String(p + 1))
    assert_equal(tracker.pause_multiplier, 64, "multiplier saturated")


# -----------------------------------------------------------------------------
# The fast path's smallest batch: one row in, one row out is a 100% pass on
# the window's first batch, so it pauses at once for BACKOFF_BASE batches.
# -----------------------------------------------------------------------------
def test_one_row_full_pass_takes_fast_path() raises:
    var tracker = SelectivityTracker(0.50)
    assert_true(tracker.should_apply())
    tracker.record(1, 1)
    assert_true(tracker.is_paused(), "1 of 1 rows is a full pass")
    var skipped = 0
    while not tracker.should_apply():
        skipped += 1
    assert_equal(skipped, 10)
    assert_equal(tracker.pause_multiplier, 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
