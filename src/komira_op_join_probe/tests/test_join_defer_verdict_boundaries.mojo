# The edges of the deferral rule's inequalities: the footprint cap refuses only
# a strictly larger probe, the traffic rule admits only strictly less traffic,
# a tie between admits and declines reads "mixed", and a three-argument call is
# the memory rule with its defaults (equal cost admits).

from std.testing import TestSuite, assert_equal

from komira_op_join_probe.join_defer_verdict import (
    DEFER_ADMIT,
    DEFER_FOOTPRINT_CAP,
    DEFER_TRAFFIC,
    DEFER_MEMORY,
    defer_verdict_why,
    defer_verdict_note,
    reset_defer_verdict_counters,
    deferral_verdict,
)


def test_cap_boundary_is_inclusive() raises:
    # matches * out_row_width = 6400; the cap refuses only a strictly larger probe.
    assert_equal(deferral_verdict(6400, 100, 64, False, 1, True, 16, 4), DEFER_ADMIT, "probe == staged output admits")
    assert_equal(deferral_verdict(6401, 100, 64, False, 1, True, 16, 4), DEFER_FOOTPRINT_CAP, "one byte over refuses")


def test_traffic_boundary_is_exclusive() raises:
    # 2 * matches * out_row_width = 12800; deferring must move strictly fewer bytes.
    assert_equal(deferral_verdict(6400, 100, 64, False, 16, True, 16, 4), DEFER_TRAFFIC, "equal traffic stays staged")
    assert_equal(deferral_verdict(6400, 100, 64, False, 15, True, 16, 4), DEFER_ADMIT, "one column fewer admits")


def test_why_tie_is_mixed() raises:
    reset_defer_verdict_counters()
    for _ in range(2):
        defer_verdict_note(DEFER_ADMIT)
    for _ in range(2):
        defer_verdict_note(DEFER_TRAFFIC)
    assert_equal(String(defer_verdict_why()), String("mixed"), "50/50 is not a majority")
    reset_defer_verdict_counters()


def test_three_argument_call_is_the_memory_rule() raises:
    # retained cost = probe_bytes + 16 * matches, against matches * width.
    assert_equal(deferral_verdict(100, 10, 26), DEFER_ADMIT, "260 == 260 admits")
    assert_equal(deferral_verdict(100, 10, 25), DEFER_MEMORY, "260 > 250 declines")
    assert_equal(deferral_verdict(100, 10, 30), DEFER_ADMIT, "260 < 300 admits")


def main() raises:
    var suite = TestSuite()
    suite.test[test_cap_boundary_is_inclusive]()
    suite.test[test_traffic_boundary_is_exclusive]()
    suite.test[test_why_tie_is_mixed]()
    suite.test[test_three_argument_call_is_the_memory_rule]()
    suite^.run()
