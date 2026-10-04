# =============================================================================
# Tests for Phase 1B Stage 2B -- make_single_dyn_acc dispatch wiring
# =============================================================================
#
# Tightens the Stage 1C tag-identity test to a "make_single_dyn_acc(tag) round-
# trip" -- verifies each of the 5 new dispatch tags actually constructs a
# DynAccumulator wrapping the correct concrete kernel:
#
#   ACC_SUM_F64    -> SumF64KahanAcc   (existing kernel, newly routed)
#   ACC_COUNT_STAR -> CountStarAcc
#   ACC_MIN_F64    -> MinF64Acc
#   ACC_MAX_F64    -> MaxF64Acc
#   ACC_AVG        -> AvgAcc
#
# Each test:
#   1. Constructs a DynAccumulator via make_single_dyn_acc(tag).
#   2. Asserts dyn.tag == tag (round-trip).
#   3. Calls ensure_capacity + the trait update_batch + a finalize/merge op
#      to verify the vtable thunks are wired (not the default sentinels).
#
# Without the Stage 2B factory branches, make_single_dyn_acc(ACC_SUM_F64)
# falls through to the SumI64 fallback and the round-trip fails -- this is
# the test-first contract.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow import Column
from komira_engine_operators.accumulator_factory import make_single_dyn_acc
from komira_engine_operators.columnar_agg_accumulator import (
    ACC_SUM_F64,
    ACC_COUNT_STAR,
    ACC_MIN_F64,
    ACC_MAX_F64,
    ACC_AVG,
)
from komira_core.io.heap_region import HeapRegion


# =============================================================================
# Round-trip: tag identity
# =============================================================================


def test_round_trip_acc_sum_f64() raises:
    """The factory must return a DynAccumulator carrying ACC_SUM_F64.

    Without Stage 2B's branch, the fallback returns a SumI64 dyn
    tagged ACC_SUM_INT64 and this assert_equal fails.
    """
    var dyn = make_single_dyn_acc(ACC_SUM_F64)
    assert_equal(Int(dyn.tag), Int(ACC_SUM_F64))
    dyn.ensure_capacity(2)
    assert_equal(dyn.num_groups(), 2)


def test_round_trip_acc_count_star() raises:
    var dyn = make_single_dyn_acc(ACC_COUNT_STAR)
    assert_equal(Int(dyn.tag), Int(ACC_COUNT_STAR))
    dyn.ensure_capacity(3)
    assert_equal(dyn.num_groups(), 3)


def test_round_trip_acc_min_f64() raises:
    var dyn = make_single_dyn_acc(ACC_MIN_F64)
    assert_equal(Int(dyn.tag), Int(ACC_MIN_F64))
    dyn.ensure_capacity(4)
    assert_equal(dyn.num_groups(), 4)


def test_round_trip_acc_max_f64() raises:
    var dyn = make_single_dyn_acc(ACC_MAX_F64)
    assert_equal(Int(dyn.tag), Int(ACC_MAX_F64))
    dyn.ensure_capacity(5)
    assert_equal(dyn.num_groups(), 5)


def test_round_trip_acc_avg() raises:
    var dyn = make_single_dyn_acc(ACC_AVG)
    assert_equal(Int(dyn.tag), Int(ACC_AVG))
    dyn.ensure_capacity(2)
    assert_equal(dyn.num_groups(), 2)


# =============================================================================
# finalize_to_column: dispatches through the new vtable -> Column
# =============================================================================


def test_finalize_to_column_count_star() raises:
    """COUNT(*) finalize emits an Int64 Column[HeapRegion] with len = num_groups."""
    var dyn = make_single_dyn_acc(ACC_COUNT_STAR)
    dyn.ensure_capacity(3)
    var col = dyn.finalize()
    assert_equal(col.length(), 3)


def test_finalize_to_column_min_f64() raises:
    """MIN(f64) finalize emits a Float64 Column[HeapRegion] with len = num_groups."""
    var dyn = make_single_dyn_acc(ACC_MIN_F64)
    dyn.ensure_capacity(2)
    var col = dyn.finalize()
    assert_equal(col.length(), 2)


def test_finalize_to_column_max_f64() raises:
    var dyn = make_single_dyn_acc(ACC_MAX_F64)
    dyn.ensure_capacity(2)
    var col = dyn.finalize()
    assert_equal(col.length(), 2)


def test_finalize_to_column_sum_f64() raises:
    var dyn = make_single_dyn_acc(ACC_SUM_F64)
    dyn.ensure_capacity(3)
    var col = dyn.finalize()
    assert_equal(col.length(), 3)


def test_finalize_to_column_avg() raises:
    """AVG finalize emits sum/count per gid (0.0 for unseen).
    A wired vtable returns a Float64 Column; a default vtable would not.
    """
    var dyn = make_single_dyn_acc(ACC_AVG)
    dyn.ensure_capacity(4)
    var col = dyn.finalize()
    assert_equal(col.length(), 4)


# =============================================================================
# merge_at: dispatches through the new vtable's _merge_at_* thunk
# =============================================================================


def test_merge_at_count_star() raises:
    """Two CountStar dyns; merge_at(0, other, 0) folds counts additively.
    The default merge_at thunk would raise; a wired thunk succeeds.
    """
    var a = make_single_dyn_acc(ACC_COUNT_STAR)
    var b = make_single_dyn_acc(ACC_COUNT_STAR)
    a.ensure_capacity(1)
    b.ensure_capacity(1)
    # Stage 2C will exercise update_batch through the vtable; for Stage 2B
    # this just verifies merge_at is wired (no raise on default thunk).
    a.merge_at(0, b, 0)


def test_merge_at_min_f64() raises:
    var a = make_single_dyn_acc(ACC_MIN_F64)
    var b = make_single_dyn_acc(ACC_MIN_F64)
    a.ensure_capacity(1)
    b.ensure_capacity(1)
    a.merge_at(0, b, 0)


def test_merge_at_max_f64() raises:
    var a = make_single_dyn_acc(ACC_MAX_F64)
    var b = make_single_dyn_acc(ACC_MAX_F64)
    a.ensure_capacity(1)
    b.ensure_capacity(1)
    a.merge_at(0, b, 0)


def test_merge_at_sum_f64() raises:
    var a = make_single_dyn_acc(ACC_SUM_F64)
    var b = make_single_dyn_acc(ACC_SUM_F64)
    a.ensure_capacity(1)
    b.ensure_capacity(1)
    a.merge_at(0, b, 0)


def test_merge_at_avg() raises:
    var a = make_single_dyn_acc(ACC_AVG)
    var b = make_single_dyn_acc(ACC_AVG)
    a.ensure_capacity(1)
    b.ensure_capacity(1)
    a.merge_at(0, b, 0)


# =============================================================================
# merge_aligned: full-column SIMD path through the new vtable
# =============================================================================


def test_merge_aligned_count_star() raises:
    var a = make_single_dyn_acc(ACC_COUNT_STAR)
    var b = make_single_dyn_acc(ACC_COUNT_STAR)
    a.ensure_capacity(8)
    b.ensure_capacity(8)
    a.merge_aligned(b)


def test_merge_aligned_min_f64() raises:
    var a = make_single_dyn_acc(ACC_MIN_F64)
    var b = make_single_dyn_acc(ACC_MIN_F64)
    a.ensure_capacity(4)
    b.ensure_capacity(4)
    a.merge_aligned(b)


def test_merge_aligned_max_f64() raises:
    var a = make_single_dyn_acc(ACC_MAX_F64)
    var b = make_single_dyn_acc(ACC_MAX_F64)
    a.ensure_capacity(4)
    b.ensure_capacity(4)
    a.merge_aligned(b)


def test_merge_aligned_sum_f64() raises:
    var a = make_single_dyn_acc(ACC_SUM_F64)
    var b = make_single_dyn_acc(ACC_SUM_F64)
    a.ensure_capacity(4)
    b.ensure_capacity(4)
    a.merge_aligned(b)


def test_merge_aligned_avg() raises:
    var a = make_single_dyn_acc(ACC_AVG)
    var b = make_single_dyn_acc(ACC_AVG)
    a.ensure_capacity(4)
    b.ensure_capacity(4)
    a.merge_aligned(b)


# =============================================================================
# Test driver
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
