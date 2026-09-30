# =============================================================================
# Tests for AggLayout -- plan-time per-query accumulator slot layout
# =============================================================================
#
# Verifies:
# 1. default_quartet produces the 32B/slot quartet layout.
# 2. sum_count_f64 produces 16B/slot narrow layout.
# 3. offsets + widths + total_width are consistent.
# 4. acc_slot_width table matches AccTag alias values.
# 5. agg_layout_is_quartet returns True only for all-quartet layouts.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_core.agg_layout import (
    ACC_SUM_F64,
    ACC_COUNT_STAR,
    ACC_SUM_COUNT_F64,
    ACC_SUM_COUNT_MIN_MAX_F64,
    AggLayout,
    acc_slot_width,
    agg_layout_is_quartet,
    select_agg_layout,
)


def test_acc_slot_widths() raises:
    """Every AccTag maps to its documented slot width."""
    print("test_acc_slot_widths...")
    assert_equal(acc_slot_width(ACC_SUM_F64), 8)
    assert_equal(acc_slot_width(ACC_COUNT_STAR), 8)
    assert_equal(acc_slot_width(ACC_SUM_COUNT_F64), 16)
    assert_equal(acc_slot_width(ACC_SUM_COUNT_MIN_MAX_F64), 32)
    print("  ok")


def test_default_quartet_layout() raises:
    """default_quartet(N) matches the 32B * N quartet stride."""
    print("test_default_quartet_layout...")
    var layout = AggLayout.default_quartet(3)
    assert_equal(layout.num_aggs, 3)
    assert_equal(layout.total_width, 96)  # 3 * 32
    for i in range(3):
        assert_equal(Int(layout.tags[i]), Int(ACC_SUM_COUNT_MIN_MAX_F64))
        assert_equal(layout.offsets[i], i * 32)
        assert_equal(layout.widths[i], 32)
    assert_true(agg_layout_is_quartet(layout))
    print("  ok")


def test_sum_count_f64_layout() raises:
    """sum_count_f64(N) produces 16B * N stride with paired fields."""
    print("test_sum_count_f64_layout...")
    var layout = AggLayout.sum_count_f64(2)
    assert_equal(layout.num_aggs, 2)
    assert_equal(layout.total_width, 32)  # 2 * 16
    for i in range(2):
        assert_equal(Int(layout.tags[i]), Int(ACC_SUM_COUNT_F64))
        assert_equal(layout.offsets[i], i * 16)
        assert_equal(layout.widths[i], 16)
    assert_false(agg_layout_is_quartet(layout))
    print("  ok")


def test_offsets_are_cumulative() raises:
    """offsets[i] = sum(widths[0..i]) for any mix of tags."""
    print("test_offsets_are_cumulative...")
    var tags = List[UInt8]()
    tags.append(ACC_SUM_COUNT_F64)  # 16
    tags.append(ACC_COUNT_STAR)  # 8
    tags.append(ACC_SUM_COUNT_MIN_MAX_F64)  # 32
    tags.append(ACC_SUM_F64)  # 8
    var layout = AggLayout(tags^)
    assert_equal(layout.num_aggs, 4)
    assert_equal(layout.offsets[0], 0)
    assert_equal(layout.offsets[1], 16)
    assert_equal(layout.offsets[2], 24)
    assert_equal(layout.offsets[3], 56)
    assert_equal(layout.total_width, 64)
    assert_false(agg_layout_is_quartet(layout))
    print("  ok")


def test_slot_accessors() raises:
    """slot_tag / slot_offset / slot_width accessors match internal lists."""
    print("test_slot_accessors...")
    var layout = AggLayout.sum_count_f64(3)
    for i in range(3):
        assert_equal(Int(layout.slot_tag(i)), Int(ACC_SUM_COUNT_F64))
        assert_equal(layout.slot_offset(i), i * 16)
        assert_equal(layout.slot_width(i), 16)
    print("  ok")


def test_select_layout_sum_count_only() raises:
    """select_agg_layout returns sum_count_f64 for SUM+COUNT + f64 values."""
    print("test_select_layout_sum_count_only...")
    var funcs = List[UInt8]()
    funcs.append(UInt8(0))  # AGG_SUM
    funcs.append(UInt8(1))  # AGG_COUNT
    var layout = select_agg_layout(funcs^, True)
    assert_equal(layout.num_aggs, 2)
    assert_equal(layout.total_width, 32)  # 2 * 16B
    for i in range(2):
        assert_equal(Int(layout.tags[i]), Int(ACC_SUM_COUNT_F64))
    print("  ok")


def test_select_layout_with_min() raises:
    """select_agg_layout falls back to quartet when MIN present."""
    print("test_select_layout_with_min...")
    var funcs = List[UInt8]()
    funcs.append(UInt8(0))  # AGG_SUM
    funcs.append(UInt8(2))  # AGG_MIN
    var layout = select_agg_layout(funcs^, True)
    assert_equal(layout.num_aggs, 2)
    assert_equal(layout.total_width, 64)  # 2 * 32B
    assert_true(agg_layout_is_quartet(layout))
    print("  ok")


def test_select_layout_non_f64_values() raises:
    """Non-f64 values force quartet even for SUM+COUNT."""
    print("test_select_layout_non_f64_values...")
    var funcs = List[UInt8]()
    funcs.append(UInt8(0))
    funcs.append(UInt8(1))
    var layout = select_agg_layout(funcs^, False)
    assert_equal(layout.total_width, 64)
    assert_true(agg_layout_is_quartet(layout))
    print("  ok")


def test_select_layout_empty() raises:
    """Empty agg list defaults to quartet with 0 aggs."""
    print("test_select_layout_empty...")
    var funcs = List[UInt8]()
    var layout = select_agg_layout(funcs^, True)
    assert_equal(layout.num_aggs, 0)
    assert_equal(layout.total_width, 0)
    print("  ok")


def main() raises:
    test_acc_slot_widths()
    test_default_quartet_layout()
    test_sum_count_f64_layout()
    test_offsets_are_cumulative()
    test_slot_accessors()
    test_select_layout_sum_count_only()
    test_select_layout_with_min()
    test_select_layout_non_f64_values()
    test_select_layout_empty()
    print("All AggLayout tests passed!")
