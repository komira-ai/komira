# Direct tests of the two leaf trace modules the scan copy dump prints:
# `payload_sel_trace` (the payload-selection mode and its five counters) and
# `staged_filter_trace` (the staged filter gate and its six counters). Each
# counter is its own slot and resets; each gate has its stated default,
# follows its setter and returns to the default on reset.
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_parquet.payload_sel_trace import (
    PAYLOAD_SEL_ALL,
    PAYLOAD_SEL_OFF,
    PAYLOAD_SEL_VAR_WIDTH,
    incr_payload_sel_decline,
    incr_payload_sel_hit,
    incr_payload_sel_policy_skip,
    incr_payload_sel_skip,
    payload_sel_decline_count,
    payload_sel_decode_enabled,
    payload_sel_decode_mode,
    payload_sel_hit_count,
    payload_sel_policy_skip_count,
    payload_sel_rows_decoded,
    payload_sel_rows_total,
    payload_sel_skip_count,
    reset_payload_sel_counts,
    reset_payload_sel_gate,
    set_payload_sel_decode_mode,
)
from komira_parquet.staged_filter_trace import (
    incr_staged_filter_declined,
    incr_staged_filter_gather,
    incr_staged_filter_rg,
    incr_staged_filter_sel,
    reset_staged_filter_counts,
    reset_staged_filter_gate,
    set_staged_filter_enabled,
    staged_filter_declined_count,
    staged_filter_enabled,
    staged_filter_gather_count,
    staged_filter_rg_count,
    staged_filter_rows_full,
    staged_filter_rows_sel,
    staged_filter_sel_count,
)


def _assert_list(got: List[Int], want: List[Int]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i], "slot " + String(i))


def _psel() raises -> List[Int]:
    return [
        payload_sel_hit_count(),
        payload_sel_decline_count(),
        payload_sel_skip_count(),
        payload_sel_policy_skip_count(),
        payload_sel_rows_decoded(),
        payload_sel_rows_total(),
    ]


def test_payload_sel_counters() raises:
    reset_payload_sel_counts()
    incr_payload_sel_hit(3, 10)
    incr_payload_sel_hit(4, 20)
    _assert_list(_psel(), [2, 0, 0, 0, 7, 30])
    incr_payload_sel_decline()
    _assert_list(_psel(), [2, 1, 0, 0, 7, 30])
    incr_payload_sel_skip()
    incr_payload_sel_skip()
    _assert_list(_psel(), [2, 1, 2, 0, 7, 30])
    incr_payload_sel_policy_skip()
    _assert_list(_psel(), [2, 1, 2, 1, 7, 30])
    reset_payload_sel_counts()
    _assert_list(_psel(), [0, 0, 0, 0, 0, 0])


def test_payload_sel_mode() raises:
    reset_payload_sel_gate()
    assert_equal(payload_sel_decode_mode(), PAYLOAD_SEL_OFF)
    assert_false(payload_sel_decode_enabled())
    var modes: List[Int] = [PAYLOAD_SEL_VAR_WIDTH, PAYLOAD_SEL_ALL, PAYLOAD_SEL_OFF]
    var enabled: List[Bool] = [True, True, False]
    for i in range(len(modes)):
        set_payload_sel_decode_mode(modes[i])
        assert_equal(payload_sel_decode_mode(), modes[i])
        assert_equal(payload_sel_decode_enabled(), enabled[i])
    set_payload_sel_decode_mode(PAYLOAD_SEL_ALL)
    var bad: List[Int] = [-1, 3]
    for i in range(len(bad)):
        var msg = String("")
        try:
            set_payload_sel_decode_mode(bad[i])
        except e:
            msg = String(e)
        assert_equal(msg, "parquet: unknown payload selection mode " + String(bad[i]))
    assert_equal(payload_sel_decode_mode(), PAYLOAD_SEL_ALL, "a refused mode changes nothing")
    reset_payload_sel_gate()
    assert_equal(payload_sel_decode_mode(), PAYLOAD_SEL_OFF)


def _sf() raises -> List[Int]:
    return [
        staged_filter_rg_count(),
        staged_filter_sel_count(),
        staged_filter_gather_count(),
        staged_filter_rows_sel(),
        staged_filter_rows_full(),
        staged_filter_declined_count(),
    ]


def test_staged_filter_counters() raises:
    reset_staged_filter_counts()
    incr_staged_filter_rg()
    _assert_list(_sf(), [1, 0, 0, 0, 0, 0])
    incr_staged_filter_sel(5, 50)
    incr_staged_filter_sel(1, 9)
    _assert_list(_sf(), [1, 2, 0, 6, 59, 0])
    incr_staged_filter_gather()
    _assert_list(_sf(), [1, 2, 1, 6, 59, 0])
    incr_staged_filter_declined()
    incr_staged_filter_declined()
    _assert_list(_sf(), [1, 2, 1, 6, 59, 2])
    reset_staged_filter_counts()
    _assert_list(_sf(), [0, 0, 0, 0, 0, 0])


def test_staged_filter_gate() raises:
    reset_staged_filter_gate()
    assert_true(staged_filter_enabled(), "the staged filter defaults on")
    set_staged_filter_enabled(False)
    assert_false(staged_filter_enabled())
    set_staged_filter_enabled(True)
    assert_true(staged_filter_enabled())
    set_staged_filter_enabled(False)
    reset_staged_filter_gate()
    assert_true(staged_filter_enabled(), "reset restores the default")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
