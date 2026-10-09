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

from komira_agg_api.agg_layout import (
    ACC_TAG_INVALID,
    ACC_SUM_F64,
    ACC_SUM_I64,
    ACC_COUNT_STAR,
    ACC_COUNT_NONNULL,
    ACC_SUM_COUNT_I64,
    ACC_MIN_F64,
    ACC_MAX_F64,
    ACC_COUNT_DISTINCT_I64,
    ACC_SUM_COUNT_F64,
    ACC_SUM_COUNT_MIN_MAX_F64,
    AggLayout,
    acc_slot_width,
    agg_layout_is_quartet,
    layout_for_funcs,
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


def test_acc_slot_width_every_tag() raises:
    """Each declared AccTag maps to its documented width; ACC_TAG_INVALID and
    an undeclared tag map to 0. Pins the full table, so an arm returning the
    wrong width or dropping to the 0 fallback goes red."""
    print("test_acc_slot_width_every_tag...")
    assert_equal(acc_slot_width(ACC_TAG_INVALID), 0)
    assert_equal(acc_slot_width(ACC_SUM_F64), 8)
    assert_equal(acc_slot_width(ACC_SUM_I64), 8)
    assert_equal(acc_slot_width(ACC_COUNT_STAR), 8)
    assert_equal(acc_slot_width(ACC_COUNT_NONNULL), 8)
    assert_equal(acc_slot_width(ACC_SUM_COUNT_F64), 16)
    assert_equal(acc_slot_width(ACC_SUM_COUNT_I64), 16)
    assert_equal(acc_slot_width(ACC_MIN_F64), 8)
    assert_equal(acc_slot_width(ACC_MAX_F64), 8)
    assert_equal(acc_slot_width(ACC_SUM_COUNT_MIN_MAX_F64), 32)
    assert_equal(acc_slot_width(ACC_COUNT_DISTINCT_I64), 8)
    assert_equal(acc_slot_width(UInt8(11)), 0)
    assert_equal(acc_slot_width(UInt8(255)), 0)
    print("  ok")


def test_mixed_tag_layout_offsets() raises:
    """A layout of every narrow tag: offsets are the running sum of the
    per-tag widths, in tag order."""
    print("test_mixed_tag_layout_offsets...")
    var tags: List[UInt8] = [
        ACC_SUM_I64, ACC_COUNT_NONNULL, ACC_SUM_COUNT_I64, ACC_MIN_F64,
        ACC_MAX_F64, ACC_COUNT_DISTINCT_I64,
    ]
    var layout = AggLayout(tags^)
    var want_w: List[Int] = [8, 8, 16, 8, 8, 8]
    var want_o: List[Int] = [0, 8, 16, 32, 40, 48]
    assert_equal(layout.num_aggs, 6)
    for i in range(6):
        assert_equal(layout.slot_width(i), want_w[i])
        assert_equal(layout.slot_offset(i), want_o[i])
    assert_equal(layout.total_width, 56)
    assert_false(agg_layout_is_quartet(layout))
    print("  ok")


def test_layout_for_funcs() raises:
    """layout_for_funcs routes through select_agg_layout with f64 values: all
    SUM/COUNT -> narrow 16B slots; any other func -> 32B quartet."""
    print("test_layout_for_funcs...")
    var narrow = layout_for_funcs([UInt8(0), UInt8(1), UInt8(0)])
    assert_equal(narrow.num_aggs, 3)
    assert_equal(narrow.total_width, 48)
    assert_equal(Int(narrow.slot_tag(2)), Int(ACC_SUM_COUNT_F64))
    var wide = layout_for_funcs([UInt8(1), UInt8(3)])
    assert_equal(wide.num_aggs, 2)
    assert_equal(wide.total_width, 64)
    assert_true(agg_layout_is_quartet(wide))
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
    test_acc_slot_width_every_tag()
    test_mixed_tag_layout_offsets()
    test_layout_for_funcs()
    print("All AggLayout tests passed!")
