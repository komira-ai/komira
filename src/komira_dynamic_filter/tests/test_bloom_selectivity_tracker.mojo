# =============================================================================
# Unit tests for SelectivityTracker (bloom pushdown)
# =============================================================================
#
# Scenarios: immediate pause on 100% pass, pause after a partially
# unselective window, staying active when selective, exponential backoff,
# resuming when selective, zero-input batches, multiplier saturation.
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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
