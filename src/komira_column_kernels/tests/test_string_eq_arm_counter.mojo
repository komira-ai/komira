# komira_counters/tests/test_string_eq_arm_counter.mojo -- the runtime-ladder
# call counter: the non-raising increment, the read, and the reset.

from std.testing import TestSuite, assert_equal

from komira_column_kernels.string_eq_arm_counter import (
    reset_string_eq_ladder_call_count,
    string_eq_ladder_call_count,
    string_eq_ladder_counter_incr,
)


def test_incr_read_reset() raises:
    reset_string_eq_ladder_call_count()
    assert_equal(string_eq_ladder_call_count(), 0)
    string_eq_ladder_counter_incr()
    string_eq_ladder_counter_incr()
    string_eq_ladder_counter_incr()
    assert_equal(string_eq_ladder_call_count(), 3)
    reset_string_eq_ladder_call_count()
    assert_equal(string_eq_ladder_call_count(), 0)
    # Counting resumes from zero after a reset.
    string_eq_ladder_counter_incr()
    assert_equal(string_eq_ladder_call_count(), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
