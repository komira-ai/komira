# =============================================================================
# Q1-MULTIAGG-SINGLE-GROUP-AVG-UNINIT-READ kernel isolation.
#
#
# integration_test_tpch_q1_e2e::test_single_group_sum_only (single STRING
# key, SUM-only, EXACTLY 1 group) emits a denormal instead of 60.0. The
# eval-div, agg-finalize-emit, and 1-element column build/read have all
# been shown CORRECT in isolation (eval_test_div_f64_single_row_tail). This
# test drives the LIVE ByteHashAggTableF64[SumF64] kernel for exactly 1
# group (3 update_scalar feeds, same byte key) and asserts finalize_at(0)
# returns the true sum. If THIS denormals, the bug is in the live kernel's
# n_groups==1 path; if it returns 60.0, the bug is in the runtime
# breaker-state drain / morsel glue, not the kernel.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_op_agg_state.byte_hash_agg_table import (
    ByteHashAggTableF64,
)
from komira_op_agg_state.agg_state_slab import SumF64


def _key_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def test_live_byte_agg_single_group_sum() raises:
    """1 group, 3 feeds of key 'X' with [10, 20, 30] -> finalize == 60.0."""
    var tbl = ByteHashAggTableF64[SumF64]()
    var kb = _key_bytes(String("X"))
    tbl.update_scalar(Span(kb), Float64(10.0))
    tbl.update_scalar(Span(kb), Float64(20.0))
    tbl.update_scalar(Span(kb), Float64(30.0))

    assert_equal(tbl.size(), 1)
    assert_equal(tbl.finalize_at(0), 60.0)


def test_live_byte_agg_two_groups_sum() raises:
    """2 groups control (the multi-group shape that already PASSES e2e)."""
    var tbl = ByteHashAggTableF64[SumF64]()
    var ka = _key_bytes(String("A"))
    var kb = _key_bytes(String("B"))
    tbl.update_scalar(Span(ka), Float64(10.0))
    tbl.update_scalar(Span(ka), Float64(20.0))
    tbl.update_scalar(Span(kb), Float64(100.0))

    assert_equal(tbl.size(), 2)
    assert_equal(tbl.finalize_at(0), 30.0)
    assert_equal(tbl.finalize_at(1), 100.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
