# komira_counters/tests/test_planner_scale_counter.mojo -- every recorder,
# every reader and the reset of `planner_scale_counter`, through the public
# functions.

from std.testing import TestSuite, assert_equal

from komira_counters.planner_scale_counter import (
    planner_scale_agg_cse_calls,
    planner_scale_agg_cse_cheap_calls,
    planner_scale_agg_cse_folds,
    planner_scale_agg_cse_gate_skips,
    planner_scale_agg_cse_grouped_nodes,
    planner_scale_agg_cse_hash_bytes,
    planner_scale_agg_cse_hash_calls,
    planner_scale_content_hash_bytes,
    planner_scale_inline_copy_bytes,
    planner_scale_inline_scans,
    planner_scale_inline_share_bytes,
    planner_scale_note_agg_cse,
    planner_scale_note_agg_cse_cheap,
    planner_scale_note_agg_cse_fold,
    planner_scale_note_agg_cse_hash,
    planner_scale_note_agg_cse_hash_bytes,
    planner_scale_note_content_hash_bytes,
    planner_scale_note_inline,
    reset_planner_scale_counters,
)


def test_inline_resolution() raises:
    reset_planner_scale_counters()
    planner_scale_note_inline(100, 0)
    planner_scale_note_inline(0, 40)
    planner_scale_note_inline(0, 0)
    assert_equal(planner_scale_inline_scans(), 3)
    assert_equal(planner_scale_inline_copy_bytes(), 100)
    assert_equal(planner_scale_inline_share_bytes(), 40)


def test_agg_cse_pass_and_gate() raises:
    reset_planner_scale_counters()
    planner_scale_note_agg_cse(5, False)
    planner_scale_note_agg_cse(0, True)
    assert_equal(planner_scale_agg_cse_calls(), 2)
    assert_equal(planner_scale_agg_cse_grouped_nodes(), 5)
    assert_equal(planner_scale_agg_cse_gate_skips(), 1)


def test_agg_cse_hash_cheap_fold_and_bytes() raises:
    reset_planner_scale_counters()
    planner_scale_note_agg_cse_hash()
    planner_scale_note_agg_cse_hash()
    planner_scale_note_agg_cse_cheap()
    planner_scale_note_agg_cse_fold()
    planner_scale_note_agg_cse_hash_bytes(0)
    planner_scale_note_agg_cse_hash_bytes(4096)
    planner_scale_note_content_hash_bytes(512)
    assert_equal(planner_scale_agg_cse_hash_calls(), 2)
    assert_equal(planner_scale_agg_cse_cheap_calls(), 1)
    assert_equal(planner_scale_agg_cse_folds(), 1)
    assert_equal(planner_scale_agg_cse_hash_bytes(), 4096)
    assert_equal(planner_scale_content_hash_bytes(), 512)


def test_reset_clears_every_counter() raises:
    planner_scale_note_inline(1, 1)
    planner_scale_note_agg_cse(1, True)
    planner_scale_note_agg_cse_hash()
    planner_scale_note_agg_cse_cheap()
    planner_scale_note_agg_cse_fold()
    planner_scale_note_agg_cse_hash_bytes(1)
    planner_scale_note_content_hash_bytes(1)
    reset_planner_scale_counters()
    assert_equal(planner_scale_inline_scans(), 0)
    assert_equal(planner_scale_inline_copy_bytes(), 0)
    assert_equal(planner_scale_inline_share_bytes(), 0)
    assert_equal(planner_scale_agg_cse_calls(), 0)
    assert_equal(planner_scale_agg_cse_grouped_nodes(), 0)
    assert_equal(planner_scale_agg_cse_gate_skips(), 0)
    assert_equal(planner_scale_agg_cse_hash_calls(), 0)
    assert_equal(planner_scale_agg_cse_cheap_calls(), 0)
    assert_equal(planner_scale_agg_cse_folds(), 0)
    assert_equal(planner_scale_agg_cse_hash_bytes(), 0)
    assert_equal(planner_scale_content_hash_bytes(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
