# =============================================================================
# decode_arm_trace: the counters count, each counter is its own slot, the
# gates default ON, a setter turns its gate on and off without touching the
# others, `reset_decode_arm_gates` restores the defaults, and
# `take_delta_page_arm` both selects the arm its gate names and counts it.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_parquet.decode_arm_trace import (
    delta_page_bytecopy_count,
    delta_page_memcpy_count,
    delta_page_memcpy_enabled,
    dict_resolve_fused_count,
    dict_resolve_fused_enabled,
    dict_resolve_legacy_count,
    dict_string_copy_count,
    dict_string_share_count,
    dict_string_share_enabled,
    flat_gather_fused_count,
    flat_gather_legacy_count,
    incr_delta_page_bytecopy,
    incr_delta_page_memcpy,
    incr_dict_resolve_fused,
    incr_dict_resolve_legacy,
    incr_dict_string_copy,
    incr_dict_string_share,
    incr_flat_gather_fused,
    incr_flat_gather_legacy,
    reset_decode_arm_counts,
    reset_decode_arm_gates,
    set_delta_page_memcpy_enabled,
    set_dict_resolve_fused_enabled,
    set_dict_string_share_enabled,
    set_string_dict_column_move_enabled,
    string_dict_column_move_enabled,
    take_delta_page_arm,
)


def _counts() raises -> List[Int]:
    var c: List[Int] = [
        delta_page_memcpy_count(),
        delta_page_bytecopy_count(),
        dict_resolve_fused_count(),
        dict_resolve_legacy_count(),
        flat_gather_fused_count(),
        flat_gather_legacy_count(),
        dict_string_share_count(),
        dict_string_copy_count(),
    ]
    return c^


def test_each_counter_is_its_own_slot() raises:
    """Bumping counter k by k+1 moves counter k only; reset zeroes all."""
    reset_decode_arm_counts()
    var zero = _counts()
    for i in range(len(zero)):
        assert_equal(zero[i], 0)
    incr_delta_page_memcpy()
    for _ in range(2):
        incr_delta_page_bytecopy()
    for _ in range(3):
        incr_dict_resolve_fused()
    for _ in range(4):
        incr_dict_resolve_legacy()
    for _ in range(5):
        incr_flat_gather_fused()
    for _ in range(6):
        incr_flat_gather_legacy()
    for _ in range(7):
        incr_dict_string_share()
    for _ in range(8):
        incr_dict_string_copy()
    var c = _counts()
    for i in range(len(c)):
        assert_equal(c[i], i + 1, "counter " + String(i))
    reset_decode_arm_counts()
    c = _counts()
    for i in range(len(c)):
        assert_equal(c[i], 0, "counter " + String(i))


def test_gates_default_on_and_setters_are_independent() raises:
    reset_decode_arm_gates()
    assert_true(delta_page_memcpy_enabled())
    assert_true(dict_resolve_fused_enabled())
    assert_true(dict_string_share_enabled())
    assert_true(string_dict_column_move_enabled())

    set_delta_page_memcpy_enabled(False)
    assert_false(delta_page_memcpy_enabled())
    assert_true(dict_resolve_fused_enabled())
    set_dict_resolve_fused_enabled(False)
    assert_false(dict_resolve_fused_enabled())
    assert_true(dict_string_share_enabled())
    set_dict_string_share_enabled(False)
    assert_false(dict_string_share_enabled())
    assert_true(string_dict_column_move_enabled())
    set_string_dict_column_move_enabled(False)
    assert_false(string_dict_column_move_enabled())

    set_delta_page_memcpy_enabled(True)
    set_dict_resolve_fused_enabled(True)
    set_dict_string_share_enabled(True)
    set_string_dict_column_move_enabled(True)
    assert_true(delta_page_memcpy_enabled())
    assert_true(dict_resolve_fused_enabled())
    assert_true(dict_string_share_enabled())
    assert_true(string_dict_column_move_enabled())

    set_delta_page_memcpy_enabled(False)
    set_dict_resolve_fused_enabled(False)
    set_dict_string_share_enabled(False)
    set_string_dict_column_move_enabled(False)
    reset_decode_arm_gates()
    assert_true(delta_page_memcpy_enabled())
    assert_true(dict_resolve_fused_enabled())
    assert_true(dict_string_share_enabled())
    assert_true(string_dict_column_move_enabled())


def test_take_delta_page_arm_follows_its_gate_and_counts() raises:
    reset_decode_arm_counts()
    reset_decode_arm_gates()
    assert_true(take_delta_page_arm())
    set_delta_page_memcpy_enabled(False)
    assert_false(take_delta_page_arm())
    assert_false(take_delta_page_arm())
    reset_decode_arm_gates()
    assert_equal(delta_page_memcpy_count(), 1)
    assert_equal(delta_page_bytecopy_count(), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
