# komira_counters/tests/test_gather_width_counter.mojo -- the public functions
# of `gather_width_counter`: note, read, reset, and the width classification
# that picks which counter a fallback lands in.

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_column_kernels.gather_width_counter import (
    gather_narrow_fallback_colrows,
    gather_narrow_typed_colrows,
    gather_note_narrow_typed,
    gather_note_width_fallback,
    gather_wide_fallback_colrows,
    gather_width_has_typed_arm,
    reset_gather_width_counters,
)


def test_width_classification() raises:
    assert_true(gather_width_has_typed_arm(1))
    assert_true(gather_width_has_typed_arm(2))
    assert_true(gather_width_has_typed_arm(4))
    assert_true(gather_width_has_typed_arm(8))
    assert_false(gather_width_has_typed_arm(0))
    assert_false(gather_width_has_typed_arm(3))
    assert_false(gather_width_has_typed_arm(16))
    assert_false(gather_width_has_typed_arm(32))


def test_typed_note_reads_back_and_resets() raises:
    reset_gather_width_counters()
    assert_equal(gather_narrow_typed_colrows(), 0)
    gather_note_narrow_typed(100)
    gather_note_narrow_typed(23)
    assert_equal(gather_narrow_typed_colrows(), 123)
    reset_gather_width_counters()
    assert_equal(gather_narrow_typed_colrows(), 0)


def test_fallback_is_routed_by_width() raises:
    reset_gather_width_counters()
    # A width WITH a typed arm lands in the narrow-fallback (defect) counter.
    gather_note_width_fallback(10, 2)
    gather_note_width_fallback(5, 1)
    # A width without one lands in the wide-fallback counter.
    gather_note_width_fallback(7, 16)
    gather_note_width_fallback(1, 32)
    assert_equal(gather_narrow_fallback_colrows(), 15)
    assert_equal(gather_wide_fallback_colrows(), 8)
    assert_equal(gather_narrow_typed_colrows(), 0)
    reset_gather_width_counters()
    assert_equal(gather_narrow_fallback_colrows(), 0)
    assert_equal(gather_wide_fallback_colrows(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
