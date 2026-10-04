# =============================================================================
# Tests for Phase 1B Stage 1B per-op SoA accumulator variants
# =============================================================================
#
# Covers the 4 missing fixed-width variants needed for the per-op SoA path:
#   - CountStarAcc      (count rows ignoring nulls)
#   - MinF64Acc         (min on Float64 columns)
#   - MaxF64Acc         (max on Float64 columns)
#   - AvgAcc            (sum + count Kahan, returns Float64 = sum/count)
#
# v0.3 references:
#   - aggregate/columnar_accumulator.rs::CountStarColumnarAcc (line 550)
#   - aggregate/columnar_accumulator.rs::MinF64ColumnarAcc    (line 571)
#   - aggregate/columnar_accumulator.rs::MaxF64ColumnarAcc    (line 579)
#   - aggregate/columnar_accumulator.rs::AvgColumnarAcc       (line 597)
#
# Each test exercises update_batch + merge_at + ensure_capacity + finalize
# in isolation. No sink, no HT, no flush.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_op_agg_state.columnar_acc_typed_extra import (
    CountStarAcc,
    MinF64Acc,
    MaxF64Acc,
    AvgAcc,
)


# =============================================================================
# CountStarAcc
# =============================================================================

def test_count_star_happy_path() raises:
    var acc = CountStarAcc.new()
    acc.ensure_capacity(3)
    var gids = List[UInt32]()
    gids.append(UInt32(0)); gids.append(UInt32(1)); gids.append(UInt32(0))
    gids.append(UInt32(0)); gids.append(UInt32(2))
    acc.update_batch(gids.unsafe_ptr(), 5)
    var out = acc.finalize()
    assert_equal(Int(out[0]), 3)
    assert_equal(Int(out[1]), 1)
    assert_equal(Int(out[2]), 1)


def test_count_star_merge_at() raises:
    var a = CountStarAcc.new()
    var b = CountStarAcc.new()
    a.ensure_capacity(2)
    b.ensure_capacity(2)
    var gids_a = List[UInt32]()
    gids_a.append(UInt32(0)); gids_a.append(UInt32(1))
    a.update_batch(gids_a.unsafe_ptr(), 2)
    var gids_b = List[UInt32]()
    gids_b.append(UInt32(0)); gids_b.append(UInt32(0)); gids_b.append(UInt32(1))
    b.update_batch(gids_b.unsafe_ptr(), 3)
    a.merge_at(0, b, 0)
    a.merge_at(1, b, 1)
    var out = a.finalize()
    assert_equal(Int(out[0]), 3)  # 1 + 2
    assert_equal(Int(out[1]), 2)  # 1 + 1


def test_count_star_ensure_capacity_monotonic() raises:
    var acc = CountStarAcc.new()
    acc.ensure_capacity(8)
    assert_equal(acc.num_groups(), 8)
    acc.ensure_capacity(4)
    assert_equal(acc.num_groups(), 8)


# =============================================================================
# MinF64Acc
# =============================================================================

def test_min_f64_happy_path() raises:
    var acc = MinF64Acc.new()
    acc.ensure_capacity(3)
    var gids = List[UInt32]()
    gids.append(UInt32(0)); gids.append(UInt32(1)); gids.append(UInt32(0))
    gids.append(UInt32(2)); gids.append(UInt32(1))
    var vals = List[Float64]()
    vals.append(Float64(3.5)); vals.append(Float64(2.0)); vals.append(Float64(1.5))
    vals.append(Float64(7.0)); vals.append(Float64(5.0))
    acc.update_batch(gids.unsafe_ptr(), vals.unsafe_ptr(), 5)
    var out = acc.finalize()
    assert_true(out[0])
    assert_equal(out[0].value(), Float64(1.5))
    assert_true(out[1])
    assert_equal(out[1].value(), Float64(2.0))
    assert_true(out[2])
    assert_equal(out[2].value(), Float64(7.0))


def test_min_f64_unseen_groups_are_none() raises:
    var acc = MinF64Acc.new()
    acc.ensure_capacity(3)
    var gids = List[UInt32]()
    gids.append(UInt32(0))
    var vals = List[Float64]()
    vals.append(Float64(42.0))
    acc.update_batch(gids.unsafe_ptr(), vals.unsafe_ptr(), 1)
    var out = acc.finalize()
    assert_true(out[0])
    assert_false(out[1])
    assert_false(out[2])


def test_min_f64_merge_at() raises:
    var a = MinF64Acc.new()
    var b = MinF64Acc.new()
    a.ensure_capacity(2)
    b.ensure_capacity(2)
    var gids_a = List[UInt32]()
    gids_a.append(UInt32(0)); gids_a.append(UInt32(1))
    var vals_a = List[Float64]()
    vals_a.append(Float64(10.0)); vals_a.append(Float64(50.0))
    a.update_batch(gids_a.unsafe_ptr(), vals_a.unsafe_ptr(), 2)
    var gids_b = List[UInt32]()
    gids_b.append(UInt32(0)); gids_b.append(UInt32(1))
    var vals_b = List[Float64]()
    vals_b.append(Float64(5.0)); vals_b.append(Float64(99.0))
    b.update_batch(gids_b.unsafe_ptr(), vals_b.unsafe_ptr(), 2)
    a.merge_at(0, b, 0)
    a.merge_at(1, b, 1)
    var out = a.finalize()
    assert_equal(out[0].value(), Float64(5.0))
    assert_equal(out[1].value(), Float64(50.0))


# =============================================================================
# MaxF64Acc
# =============================================================================

def test_max_f64_happy_path() raises:
    var acc = MaxF64Acc.new()
    acc.ensure_capacity(3)
    var gids = List[UInt32]()
    gids.append(UInt32(0)); gids.append(UInt32(1)); gids.append(UInt32(0))
    gids.append(UInt32(2)); gids.append(UInt32(1))
    var vals = List[Float64]()
    vals.append(Float64(3.5)); vals.append(Float64(2.0)); vals.append(Float64(1.5))
    vals.append(Float64(7.0)); vals.append(Float64(5.0))
    acc.update_batch(gids.unsafe_ptr(), vals.unsafe_ptr(), 5)
    var out = acc.finalize()
    assert_equal(out[0].value(), Float64(3.5))
    assert_equal(out[1].value(), Float64(5.0))
    assert_equal(out[2].value(), Float64(7.0))


def test_max_f64_merge_at() raises:
    var a = MaxF64Acc.new()
    var b = MaxF64Acc.new()
    a.ensure_capacity(2)
    b.ensure_capacity(2)
    var gids_a = List[UInt32]()
    gids_a.append(UInt32(0)); gids_a.append(UInt32(1))
    var vals_a = List[Float64]()
    vals_a.append(Float64(10.0)); vals_a.append(Float64(50.0))
    a.update_batch(gids_a.unsafe_ptr(), vals_a.unsafe_ptr(), 2)
    var gids_b = List[UInt32]()
    gids_b.append(UInt32(0)); gids_b.append(UInt32(1))
    var vals_b = List[Float64]()
    vals_b.append(Float64(99.0)); vals_b.append(Float64(5.0))
    b.update_batch(gids_b.unsafe_ptr(), vals_b.unsafe_ptr(), 2)
    a.merge_at(0, b, 0)
    a.merge_at(1, b, 1)
    var out = a.finalize()
    assert_equal(out[0].value(), Float64(99.0))
    assert_equal(out[1].value(), Float64(50.0))


# =============================================================================
# AvgAcc -- sum + count, finalize returns sum/count as Float64
# =============================================================================

def test_avg_happy_path() raises:
    var acc = AvgAcc.new()
    acc.ensure_capacity(2)
    var gids = List[UInt32]()
    gids.append(UInt32(0)); gids.append(UInt32(0)); gids.append(UInt32(1))
    gids.append(UInt32(1)); gids.append(UInt32(0))
    var vals = List[Float64]()
    vals.append(Float64(10.0)); vals.append(Float64(20.0)); vals.append(Float64(5.0))
    vals.append(Float64(15.0)); vals.append(Float64(30.0))
    acc.update_batch(gids.unsafe_ptr(), vals.unsafe_ptr(), 5)
    var out = acc.finalize()
    # gid 0: sum=60, count=3, avg=20.0
    assert_true(out[0])
    assert_equal(out[0].value(), Float64(20.0))
    # gid 1: sum=20, count=2, avg=10.0
    assert_true(out[1])
    assert_equal(out[1].value(), Float64(10.0))


def test_avg_unseen_group_is_none() raises:
    var acc = AvgAcc.new()
    acc.ensure_capacity(3)
    var gids = List[UInt32]()
    gids.append(UInt32(0))
    var vals = List[Float64]()
    vals.append(Float64(42.0))
    acc.update_batch(gids.unsafe_ptr(), vals.unsafe_ptr(), 1)
    var out = acc.finalize()
    assert_true(out[0])
    assert_false(out[1])
    assert_false(out[2])


def test_avg_merge_at() raises:
    var a = AvgAcc.new()
    var b = AvgAcc.new()
    a.ensure_capacity(1)
    b.ensure_capacity(1)
    var gids_a = List[UInt32]()
    gids_a.append(UInt32(0)); gids_a.append(UInt32(0))
    var vals_a = List[Float64]()
    vals_a.append(Float64(10.0)); vals_a.append(Float64(20.0))
    a.update_batch(gids_a.unsafe_ptr(), vals_a.unsafe_ptr(), 2)
    var gids_b = List[UInt32]()
    gids_b.append(UInt32(0)); gids_b.append(UInt32(0))
    var vals_b = List[Float64]()
    vals_b.append(Float64(40.0)); vals_b.append(Float64(50.0))
    b.update_batch(gids_b.unsafe_ptr(), vals_b.unsafe_ptr(), 2)
    a.merge_at(0, b, 0)
    var out = a.finalize()
    # combined: sum=120, count=4, avg=30.0
    assert_true(out[0])
    assert_equal(out[0].value(), Float64(30.0))


# =============================================================================
# Test driver
# =============================================================================

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
