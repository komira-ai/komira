# rg_prune_counter: each of the four process-global counters moves by exactly
# what its recorder is given and by nothing else, and the reset zeroes all
# four. The counters are read as deltas from a reset, so the test does not
# depend on what ran before it in the process.

from std.testing import TestSuite, assert_equal

from komira_parquet_scan.rg_prune_counter import (
    reset_rg_prune_counters,
    rg_prune_bloom_pruned,
    rg_prune_bloom_record,
    rg_prune_perclaim_evals,
    rg_prune_perclaim_incr,
    rg_prune_setup_evals,
    rg_prune_setup_pruned,
    rg_prune_setup_record,
)


def _expect(setup_evals: Int, setup_pruned: Int, perclaim: Int, bloom: Int) raises:
    assert_equal(rg_prune_setup_evals(), setup_evals, "setup evals")
    assert_equal(rg_prune_setup_pruned(), setup_pruned, "setup pruned")
    assert_equal(rg_prune_perclaim_evals(), perclaim, "per-claim evals")
    assert_equal(rg_prune_bloom_pruned(), bloom, "bloom pruned")


def test_each_counter_moves_alone() raises:
    reset_rg_prune_counters()
    _expect(0, 0, 0, 0)
    rg_prune_setup_record(3)
    _expect(1, 3, 0, 0)
    rg_prune_setup_record(0)
    _expect(2, 3, 0, 0)
    rg_prune_perclaim_incr()
    rg_prune_perclaim_incr()
    rg_prune_perclaim_incr()
    _expect(2, 3, 3, 0)
    rg_prune_bloom_record(5)
    rg_prune_bloom_record(2)
    _expect(2, 3, 3, 7)


def test_reset_zeroes_all_four() raises:
    rg_prune_setup_record(4)
    rg_prune_perclaim_incr()
    rg_prune_bloom_record(1)
    reset_rg_prune_counters()
    _expect(0, 0, 0, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
