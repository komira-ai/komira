# =============================================================================
# Tests for ColumnarAccumulator (Slice 3a of G4 ColumnarAggMap port)
# =============================================================================
#
# Scope: the tagged-union accumulator in isolation. No sink, no HT, no flush.
# Covers: MinUtf8, MaxUtf8, SumInt64, CountInt64 — update, ensure_capacity,
# merge, finalize.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_engine_operators.columnar_agg_accumulator import (
    ColumnarAccumulator,
    ACC_MIN_UTF8,
    ACC_MAX_UTF8,
    ACC_SUM_INT64,
    ACC_COUNT_INT64,
)


# -----------------------------------------------------------------------------
# Construction + tag identity
# -----------------------------------------------------------------------------

def test_new_min_utf8_has_correct_tag() raises:
    var acc = ColumnarAccumulator.new_min_utf8()
    assert_equal(Int(acc.tag), Int(ACC_MIN_UTF8))
    assert_equal(acc.num_groups(), 0)


def test_new_max_utf8_has_correct_tag() raises:
    var acc = ColumnarAccumulator.new_max_utf8()
    assert_equal(Int(acc.tag), Int(ACC_MAX_UTF8))
    assert_equal(acc.num_groups(), 0)


def test_new_sum_int64_has_correct_tag() raises:
    var acc = ColumnarAccumulator.new_sum_int64()
    assert_equal(Int(acc.tag), Int(ACC_SUM_INT64))
    assert_equal(acc.num_groups(), 0)


def test_new_count_int64_has_correct_tag() raises:
    var acc = ColumnarAccumulator.new_count_int64()
    assert_equal(Int(acc.tag), Int(ACC_COUNT_INT64))
    assert_equal(acc.num_groups(), 0)


# -----------------------------------------------------------------------------
# ensure_capacity
# -----------------------------------------------------------------------------

def test_ensure_capacity_utf8_fills_with_none() raises:
    var acc = ColumnarAccumulator.new_min_utf8()
    acc.ensure_capacity(5)
    assert_equal(acc.num_groups(), 5)
    for i in range(5):
        var got = acc.finalize_utf8(i)
        assert_false(Bool(got), "slot " + String(i) + " should be None")


def test_ensure_capacity_int64_fills_with_zero() raises:
    var acc = ColumnarAccumulator.new_sum_int64()
    acc.ensure_capacity(4)
    assert_equal(acc.num_groups(), 4)
    for i in range(4):
        assert_equal(Int(acc.finalize_int64(i)), 0)


def test_ensure_capacity_is_monotonic_grow() raises:
    # Shrinking is disallowed (matches v0.3 invariant: group IDs are dense and
    # only ever grow). ensure_capacity(smaller) must be a no-op.
    var acc = ColumnarAccumulator.new_count_int64()
    acc.ensure_capacity(10)
    acc.update_int64(5, 42)
    acc.ensure_capacity(3)  # no-op (already larger)
    assert_equal(acc.num_groups(), 10)
    assert_equal(Int(acc.finalize_int64(5)), 42)


# -----------------------------------------------------------------------------
# MinUtf8
# -----------------------------------------------------------------------------

def test_min_utf8_first_write_wins_when_none() raises:
    var acc = ColumnarAccumulator.new_min_utf8()
    acc.ensure_capacity(3)
    acc.update_utf8(1, "banana")
    var got = acc.finalize_utf8(1)
    assert_true(Bool(got))
    assert_equal(got.value(), "banana")


def test_min_utf8_tracks_lexicographic_min() raises:
    var acc = ColumnarAccumulator.new_min_utf8()
    acc.ensure_capacity(1)
    acc.update_utf8(0, "cherry")
    acc.update_utf8(0, "apple")
    acc.update_utf8(0, "banana")
    acc.update_utf8(0, "date")
    var got = acc.finalize_utf8(0)
    assert_true(Bool(got))
    assert_equal(got.value(), "apple")


def test_min_utf8_per_group_isolation() raises:
    var acc = ColumnarAccumulator.new_min_utf8()
    acc.ensure_capacity(3)
    acc.update_utf8(0, "z")
    acc.update_utf8(1, "m")
    acc.update_utf8(2, "a")
    acc.update_utf8(0, "y")
    acc.update_utf8(1, "n")  # larger, should NOT overwrite
    acc.update_utf8(2, "b")  # larger, should NOT overwrite
    assert_equal(acc.finalize_utf8(0).value(), "y")
    assert_equal(acc.finalize_utf8(1).value(), "m")
    assert_equal(acc.finalize_utf8(2).value(), "a")


def test_min_utf8_unseen_group_returns_none() raises:
    var acc = ColumnarAccumulator.new_min_utf8()
    acc.ensure_capacity(3)
    acc.update_utf8(1, "hello")
    assert_false(Bool(acc.finalize_utf8(0)))
    assert_true(Bool(acc.finalize_utf8(1)))
    assert_false(Bool(acc.finalize_utf8(2)))


# -----------------------------------------------------------------------------
# MaxUtf8
# -----------------------------------------------------------------------------

def test_max_utf8_tracks_lexicographic_max() raises:
    var acc = ColumnarAccumulator.new_max_utf8()
    acc.ensure_capacity(1)
    acc.update_utf8(0, "apple")
    acc.update_utf8(0, "cherry")
    acc.update_utf8(0, "banana")
    assert_equal(acc.finalize_utf8(0).value(), "cherry")


def test_max_utf8_per_group_isolation() raises:
    var acc = ColumnarAccumulator.new_max_utf8()
    acc.ensure_capacity(2)
    acc.update_utf8(0, "aa")
    acc.update_utf8(1, "zz")
    acc.update_utf8(0, "ab")
    acc.update_utf8(1, "yy")  # smaller, should NOT overwrite
    assert_equal(acc.finalize_utf8(0).value(), "ab")
    assert_equal(acc.finalize_utf8(1).value(), "zz")


# -----------------------------------------------------------------------------
# SumInt64
# -----------------------------------------------------------------------------

def test_sum_int64_accumulates() raises:
    var acc = ColumnarAccumulator.new_sum_int64()
    acc.ensure_capacity(2)
    acc.update_int64(0, 10)
    acc.update_int64(0, 20)
    acc.update_int64(0, 30)
    acc.update_int64(1, 5)
    assert_equal(Int(acc.finalize_int64(0)), 60)
    assert_equal(Int(acc.finalize_int64(1)), 5)


def test_sum_int64_handles_negatives() raises:
    var acc = ColumnarAccumulator.new_sum_int64()
    acc.ensure_capacity(1)
    acc.update_int64(0, 100)
    acc.update_int64(0, -40)
    acc.update_int64(0, -10)
    assert_equal(Int(acc.finalize_int64(0)), 50)


# -----------------------------------------------------------------------------
# CountInt64
# -----------------------------------------------------------------------------

def test_count_int64_accumulates_increment() raises:
    var acc = ColumnarAccumulator.new_count_int64()
    acc.ensure_capacity(2)
    # Typical usage: caller passes 1 per non-null row.
    for _ in range(5):
        acc.update_int64(0, 1)
    for _ in range(3):
        acc.update_int64(1, 1)
    assert_equal(Int(acc.finalize_int64(0)), 5)
    assert_equal(Int(acc.finalize_int64(1)), 3)


# -----------------------------------------------------------------------------
# merge
# -----------------------------------------------------------------------------

def test_merge_min_utf8_combines_elementwise() raises:
    var a = ColumnarAccumulator.new_min_utf8()
    a.ensure_capacity(3)
    a.update_utf8(0, "bb")
    a.update_utf8(1, "mm")
    # gid 2 never seen in `a`

    var b = ColumnarAccumulator.new_min_utf8()
    b.ensure_capacity(3)
    b.update_utf8(0, "aa")   # smaller — should win
    b.update_utf8(1, "nn")   # larger — should NOT win
    b.update_utf8(2, "zz")   # only source — should be taken

    a.merge(b)

    assert_equal(a.finalize_utf8(0).value(), "aa")
    assert_equal(a.finalize_utf8(1).value(), "mm")
    assert_equal(a.finalize_utf8(2).value(), "zz")


def test_merge_max_utf8_combines_elementwise() raises:
    var a = ColumnarAccumulator.new_max_utf8()
    a.ensure_capacity(2)
    a.update_utf8(0, "mm")
    # gid 1 unseen in `a`

    var b = ColumnarAccumulator.new_max_utf8()
    b.ensure_capacity(2)
    b.update_utf8(0, "zz")   # bigger — wins
    b.update_utf8(1, "hello")

    a.merge(b)

    assert_equal(a.finalize_utf8(0).value(), "zz")
    assert_equal(a.finalize_utf8(1).value(), "hello")


def test_merge_sum_int64_adds() raises:
    var a = ColumnarAccumulator.new_sum_int64()
    a.ensure_capacity(3)
    a.update_int64(0, 10)
    a.update_int64(1, 20)

    var b = ColumnarAccumulator.new_sum_int64()
    b.ensure_capacity(3)
    b.update_int64(0, 5)
    b.update_int64(1, 7)
    b.update_int64(2, 99)

    a.merge(b)

    assert_equal(Int(a.finalize_int64(0)), 15)
    assert_equal(Int(a.finalize_int64(1)), 27)
    assert_equal(Int(a.finalize_int64(2)), 99)


def test_merge_count_int64_adds() raises:
    var a = ColumnarAccumulator.new_count_int64()
    a.ensure_capacity(2)
    a.update_int64(0, 4)
    a.update_int64(1, 2)

    var b = ColumnarAccumulator.new_count_int64()
    b.ensure_capacity(2)
    b.update_int64(0, 3)
    b.update_int64(1, 6)

    a.merge(b)

    assert_equal(Int(a.finalize_int64(0)), 7)
    assert_equal(Int(a.finalize_int64(1)), 8)


def test_merge_grows_self_when_other_is_larger() raises:
    var a = ColumnarAccumulator.new_sum_int64()
    a.ensure_capacity(2)
    a.update_int64(0, 1)
    a.update_int64(1, 2)

    var b = ColumnarAccumulator.new_sum_int64()
    b.ensure_capacity(5)
    b.update_int64(0, 10)
    b.update_int64(4, 50)

    a.merge(b)

    # a must have grown to cover 5 groups, with unseen slots staying zero
    # before being folded with b.
    assert_equal(a.num_groups(), 5)
    assert_equal(Int(a.finalize_int64(0)), 11)
    assert_equal(Int(a.finalize_int64(1)), 2)
    assert_equal(Int(a.finalize_int64(2)), 0)
    assert_equal(Int(a.finalize_int64(3)), 0)
    assert_equal(Int(a.finalize_int64(4)), 50)


def test_merge_tag_mismatch_raises() raises:
    var a = ColumnarAccumulator.new_sum_int64()
    var b = ColumnarAccumulator.new_min_utf8()
    var raised = False
    try:
        a.merge(b)
    except:
        raised = True
    assert_true(raised, "merge across tags must raise")


# -----------------------------------------------------------------------------
# finalize safety
# -----------------------------------------------------------------------------

def test_finalize_out_of_range_utf8_returns_none() raises:
    var acc = ColumnarAccumulator.new_min_utf8()
    acc.ensure_capacity(2)
    assert_false(Bool(acc.finalize_utf8(99)))


def test_finalize_out_of_range_int64_returns_zero() raises:
    var acc = ColumnarAccumulator.new_sum_int64()
    acc.ensure_capacity(2)
    assert_equal(Int(acc.finalize_int64(99)), 0)


# =============================================================================
# Main
# =============================================================================

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
