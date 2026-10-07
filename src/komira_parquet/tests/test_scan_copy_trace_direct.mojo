# Direct tests of `scan_copy_trace.mojo`: every counter is its own slot and
# resets; every gate has its stated default, follows its setter independently
# of the others and returns to the default on reset; the readahead mode takes
# exactly its three values; and the trace dump runs both with the trace off
# (prints nothing) and on (prints its four lines).
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_parquet.scan_copy_trace import (
    PREFETCH_MODE_LEGACY,
    PREFETCH_MODE_NONE,
    PREFETCH_MODE_PROJ,
    add_plain_ba_fused_alloc,
    add_plain_ba_slack,
    bss_decode_copy_count,
    bss_decode_into_count,
    bss_decode_into_enabled,
    dict_resolve_copy_count,
    dict_resolve_move_count,
    dict_resolve_move_enabled,
    incr_bss_decode_copy,
    incr_bss_decode_into,
    incr_dict_resolve_copy,
    incr_dict_resolve_move,
    incr_plain_ba_fused,
    incr_plain_ba_two_pass,
    incr_prefetch_advise,
    incr_proj_copy,
    incr_proj_copy_other,
    incr_proj_share,
    incr_string_copy,
    incr_string_page_concat,
    incr_string_page_move,
    incr_string_share,
    plain_ba_fused_alloc_bytes,
    plain_ba_fused_count,
    plain_ba_fused_enabled,
    plain_ba_slack_bytes,
    plain_ba_two_pass_count,
    prefetch_advise_bytes,
    prefetch_advise_calls,
    prefetch_mode,
    proj_copy_count,
    proj_copy_other_count,
    proj_share_count,
    proj_share_enabled,
    reset_scan_copy_counts,
    reset_scan_copy_gates,
    scan_copy_trace_dump,
    scan_copy_trace_enabled,
    set_bss_decode_into_enabled,
    set_dict_resolve_move_enabled,
    set_plain_ba_fused_enabled,
    set_prefetch_mode,
    set_proj_share_enabled,
    set_scan_copy_trace_enabled,
    set_string_page_move_enabled,
    set_string_share_enabled,
    string_copy_count,
    string_page_concat_count,
    string_page_move_count,
    string_share_count,
    string_share_enabled,
    string_page_move_enabled,
)


def _counts() raises -> List[Int]:
    return [
        dict_resolve_move_count(),
        dict_resolve_copy_count(),
        proj_share_count(),
        proj_copy_count(),
        proj_copy_other_count(),
        bss_decode_into_count(),
        bss_decode_copy_count(),
        string_share_count(),
        string_copy_count(),
        plain_ba_fused_count(),
        plain_ba_two_pass_count(),
        plain_ba_slack_bytes(),
        plain_ba_fused_alloc_bytes(),
        string_page_move_count(),
        string_page_concat_count(),
        prefetch_advise_calls(),
        prefetch_advise_bytes(),
    ]


def _bump(k: Int) raises:
    """Fire counter slot `k` (the order of `_counts`) once; the two byte
    counters and the readahead pair add k + 1."""
    if k == 0:
        incr_dict_resolve_move()
    elif k == 1:
        incr_dict_resolve_copy()
    elif k == 2:
        incr_proj_share()
    elif k == 3:
        incr_proj_copy()
    elif k == 4:
        incr_proj_copy_other()
    elif k == 5:
        incr_bss_decode_into()
    elif k == 6:
        incr_bss_decode_copy()
    elif k == 7:
        incr_string_share()
    elif k == 8:
        incr_string_copy()
    elif k == 9:
        incr_plain_ba_fused()
    elif k == 10:
        incr_plain_ba_two_pass()
    elif k == 11:
        add_plain_ba_slack(k + 1)
    elif k == 12:
        add_plain_ba_fused_alloc(k + 1)
    elif k == 13:
        incr_string_page_move()
    elif k == 14:
        incr_string_page_concat()


def test_every_counter_is_its_own_slot_and_resets() raises:
    reset_scan_copy_counts()
    for k in range(15):
        _bump(k)
        _bump(k)
        var c = _counts()
        var expect = 2 * (k + 1) if k == 11 or k == 12 else 2
        assert_equal(c[k], expect, "slot " + String(k))
        for j in range(len(c)):
            if j != k:
                assert_equal(c[j], 0, "slot " + String(j) + " moved with " + String(k))
        reset_scan_copy_counts()
    # The readahead pair counts calls and bytes together.
    incr_prefetch_advise(4096)
    incr_prefetch_advise(100)
    var c = _counts()
    assert_equal(c[15], 2)
    assert_equal(c[16], 4196)
    for j in range(15):
        assert_equal(c[j], 0)
    reset_scan_copy_counts()
    var z = _counts()
    for j in range(len(z)):
        assert_equal(z[j], 0)


def _gates() raises -> List[Bool]:
    return [
        dict_resolve_move_enabled(),
        proj_share_enabled(),
        scan_copy_trace_enabled(),
        bss_decode_into_enabled(),
        string_share_enabled(),
        plain_ba_fused_enabled(),
        string_page_move_enabled(),
    ]


def _set_gate(k: Int, on: Bool) raises:
    if k == 0:
        set_dict_resolve_move_enabled(on)
    elif k == 1:
        set_proj_share_enabled(on)
    elif k == 2:
        set_scan_copy_trace_enabled(on)
    elif k == 3:
        set_bss_decode_into_enabled(on)
    elif k == 4:
        set_string_share_enabled(on)
    elif k == 5:
        set_plain_ba_fused_enabled(on)
    else:
        set_string_page_move_enabled(on)


def test_gates_defaults_setters_and_reset() raises:
    reset_scan_copy_gates()
    # The dict-resolve move gate and the trace default off; the five
    # promoted gates on.
    var defaults: List[Bool] = [False, True, False, True, True, True, True]
    var g = _gates()
    for k in range(len(defaults)):
        assert_equal(g[k], defaults[k], "default of gate " + String(k))
    for k in range(len(defaults)):
        for on in range(2):
            _set_gate(k, on == 1)
            var now = _gates()
            for j in range(len(defaults)):
                var want = (on == 1) if j == k else defaults[j]
                assert_equal(now[j], want, "gate " + String(j) + " after setting " + String(k))
        reset_scan_copy_gates()
        var back = _gates()
        for j in range(len(defaults)):
            assert_equal(back[j], defaults[j], "reset of gate " + String(j))


def test_prefetch_mode_values_and_refusals() raises:
    reset_scan_copy_gates()
    assert_equal(prefetch_mode(), PREFETCH_MODE_NONE)
    var modes: List[Int] = [PREFETCH_MODE_LEGACY, PREFETCH_MODE_PROJ, PREFETCH_MODE_NONE]
    for i in range(len(modes)):
        set_prefetch_mode(modes[i])
        assert_equal(prefetch_mode(), modes[i])
    var bad: List[Int] = [-1, 3]
    for i in range(len(bad)):
        var msg = String("")
        try:
            set_prefetch_mode(bad[i])
        except e:
            msg = String(e)
        assert_equal(msg, "parquet: unknown readahead mode " + String(bad[i]))
    assert_equal(prefetch_mode(), PREFETCH_MODE_NONE, "a refused mode changes nothing")
    set_prefetch_mode(PREFETCH_MODE_PROJ)
    reset_scan_copy_gates()
    assert_equal(prefetch_mode(), PREFETCH_MODE_NONE, "reset restores NONE")


def test_dump_off_and_on() raises:
    # Off: returns before printing. On: prints the four lines (their text is
    # read by people, not parsed; this runs both arms of the gate).
    reset_scan_copy_gates()
    scan_copy_trace_dump("test/off")
    set_scan_copy_trace_enabled(True)
    scan_copy_trace_dump("test/on")
    reset_scan_copy_gates()
    assert_false(scan_copy_trace_enabled())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
