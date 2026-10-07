# komira_counters/tests/test_join_index_window_counter.mojo -- note, read and
# reset through the public functions of `join_index_window_counter`.

from std.testing import TestSuite, assert_equal

from komira_join_assembly.join_index_window_counter import (
    join_index_window_aliased_rows,
    join_index_window_calls,
    join_index_window_copy_bytes,
    join_index_window_note_copy,
    join_index_window_note_gather,
    join_index_window_windowed_calls,
    reset_join_index_window_counters,
)


def test_copying_driver_reads_zero_aliasing() raises:
    reset_join_index_window_counters()
    # index_span == count and base 0: a per-chunk copy of exactly `count`.
    join_index_window_note_gather(8, 8, 0)
    assert_equal(join_index_window_calls(), 1)
    assert_equal(join_index_window_windowed_calls(), 0)
    assert_equal(join_index_window_aliased_rows(), 0)
    assert_equal(join_index_window_copy_bytes(), 0)


def test_windowed_driver_reads_the_window() raises:
    reset_join_index_window_counters()
    join_index_window_note_gather(8, 32, 16)
    join_index_window_note_gather(8, 32, 24)
    assert_equal(join_index_window_calls(), 2)
    assert_equal(join_index_window_windowed_calls(), 2)
    # (32 - 8) twice: the rows visible beyond each output window.
    assert_equal(join_index_window_aliased_rows(), 48)


def test_copy_bytes_and_reset() raises:
    reset_join_index_window_counters()
    join_index_window_note_copy(64)
    join_index_window_note_copy(36)
    assert_equal(join_index_window_copy_bytes(), 100)
    join_index_window_note_gather(4, 12, 4)
    reset_join_index_window_counters()
    assert_equal(join_index_window_calls(), 0)
    assert_equal(join_index_window_windowed_calls(), 0)
    assert_equal(join_index_window_aliased_rows(), 0)
    assert_equal(join_index_window_copy_bytes(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
