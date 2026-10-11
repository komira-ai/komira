# Direct tests of the sub-row-group counters: `subrg_dbp_trace` (the
# resumable DELTA_BINARY_PACKED arm) and `subrg_scan_route_trace` (the scan
# route). Each counter adds what it is given and resets to 0; the grains
# divide the right pair and are 0 with nothing to divide; the milestone test
# is "a power of two"; the print gate is off until a setter turns it on, and
# printing with it on leaves the counts unchanged.
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_parquet.subrg_dbp_trace import (
    add_dbp_values,
    dbp_note_armed,
    dbp_open_admit_count,
    dbp_open_decline_count,
    dbp_page_count,
    dbp_page_is_milestone,
    dbp_stall_count,
    dbp_trace_dump,
    dbp_value_count,
    incr_dbp_open_admit,
    incr_dbp_open_decline,
    incr_dbp_page,
    incr_dbp_stall,
    reset_dbp_counts,
    set_subrg_dbp_trace_enabled,
    subrg_dbp_trace_enabled,
)
from komira_parquet.subrg_scan_route_trace import (
    add_scan_fallback,
    add_scan_retracted,
    add_scan_streamed,
    incr_scan_open_decline,
    reset_scan_route_counts,
    scan_chunks_streamed_count,
    scan_fallback_count,
    scan_grain_streamed,
    scan_grain_whole,
    scan_open_decline_count,
    scan_retracted_rows_count,
    scan_rows_streamed_count,
    scan_rows_whole_count,
)


def test_dbp_counters_add_and_reset() raises:
    reset_dbp_counts()
    incr_dbp_open_admit()
    incr_dbp_open_admit()
    incr_dbp_open_decline()
    for _ in range(5):
        incr_dbp_page()
    add_dbp_values(300)
    add_dbp_values(157)
    incr_dbp_stall()
    assert_equal(dbp_open_admit_count(), 2)
    assert_equal(dbp_open_decline_count(), 1)
    assert_equal(dbp_page_count(), 5)
    assert_equal(dbp_value_count(), 457)
    assert_equal(dbp_stall_count(), 1)
    reset_dbp_counts()
    assert_equal(dbp_open_admit_count(), 0)
    assert_equal(dbp_open_decline_count(), 0)
    assert_equal(dbp_page_count(), 0)
    assert_equal(dbp_value_count(), 0)
    assert_equal(dbp_stall_count(), 0)


def test_milestones_are_the_powers_of_two() raises:
    var hits = List[Int]()
    for n in range(0, 70):
        if dbp_page_is_milestone(n):
            hits.append(n)
    var want: List[Int] = [1, 2, 4, 8, 16, 32, 64]
    assert_equal(len(hits), len(want))
    for i in range(len(want)):
        assert_equal(hits[i], want[i])


def test_the_print_gate_is_set_and_printing_counts_nothing() raises:
    set_subrg_dbp_trace_enabled(False)
    assert_false(subrg_dbp_trace_enabled())
    reset_dbp_counts()
    set_subrg_dbp_trace_enabled(True)
    assert_true(subrg_dbp_trace_enabled())
    dbp_note_armed(8)
    dbp_note_armed(8)
    incr_dbp_page()
    dbp_trace_dump(StaticString("test"))
    assert_equal(dbp_page_count(), 1, "printing does not count")
    assert_equal(dbp_open_admit_count(), 0, "the ARMED line does not count")
    set_subrg_dbp_trace_enabled(False)
    assert_false(subrg_dbp_trace_enabled())


def test_route_counters_and_grains() raises:
    reset_scan_route_counts()
    assert_equal(scan_grain_streamed(), 0, "nothing streamed")
    assert_equal(scan_grain_whole(), 0, "nothing fell back")
    add_scan_streamed(90000, 3)
    add_scan_streamed(30000, 1)
    add_scan_fallback(122880)
    add_scan_fallback(122880)
    incr_scan_open_decline()
    add_scan_retracted(1024)
    add_scan_retracted(76)
    assert_equal(scan_rows_streamed_count(), 120000)
    assert_equal(scan_chunks_streamed_count(), 4)
    assert_equal(scan_grain_streamed(), 30000)
    assert_equal(scan_rows_whole_count(), 245760)
    assert_equal(scan_fallback_count(), 2)
    assert_equal(scan_grain_whole(), 122880)
    assert_equal(scan_open_decline_count(), 1)
    assert_equal(scan_retracted_rows_count(), 1100)
    reset_scan_route_counts()
    assert_equal(scan_rows_streamed_count(), 0)
    assert_equal(scan_chunks_streamed_count(), 0)
    assert_equal(scan_rows_whole_count(), 0)
    assert_equal(scan_fallback_count(), 0)
    assert_equal(scan_open_decline_count(), 0)
    assert_equal(scan_retracted_rows_count(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
