# =============================================================================
# bloom_mask_int64 / range_mask_int64 / in_list_mask_int64: null rows, sliced
# (offset) key arrays, the SIMD body plus tail, and the empty / inverted range.
# =============================================================================
#
# What these tests prove (oracles from the docstrings of `bloom_mask.mojo`,
# worked out by hand):
#
#   * Every null row is False in all three masks, even when its value would
#     pass (the null rows below hold values that are in the range, in the
#     list and in the bloom filter).
#   * The kernels read a sliced key array at its offset: the keys are a view
#     starting one row into a larger array whose first and last values (100,
#     200) pass no filter, so a read that ignores the offset changes the mask.
#   * Range bounds are inclusive at both ends (6 and 11 below).
#   * The non-null range path gives the same answer over 11 rows (not a
#     multiple of any SIMD width, so the tail runs) as the scalar definition.
#   * An inverted range (min > max) and an empty key array give all-False /
#     empty masks.
#   * Bloom: no false negatives (every inserted non-null key is True); the
#     test asserts nothing about keys that were not inserted (a bloom filter
#     may answer True for them).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.boolean_array import BooleanArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_dynamic_filter.bloom_filter import BloomFilter
from komira_dynamic_filter.in_list_filter import InListFilter
from komira_dynamic_filter.range_filter import RangeFilter
from komira_morsel.bloom_mask import (
    bloom_mask_int64,
    in_list_mask_int64,
    range_mask_int64,
)


def _keys(nullable: Bool) raises -> PrimitiveArray[DType.int64]:
    """Base [100, 5, 6, ..., 13, 200]; the result is the view at rows 1..9,
    so window row r holds 5 + r. With `nullable`, window rows 2 (value 7) and
    5 (value 10) are null."""
    var base = PrimitiveArray[DType.int64].allocate_nullable(11) if nullable else (
        PrimitiveArray[DType.int64].allocate(11)
    )
    base.set(0, Int64(100))
    for r in range(9):
        base.set(1 + r, Int64(5 + r))
    base.set(10, Int64(200))
    if nullable:
        base._set_null(1 + 2)
        base._set_null(1 + 5)
    return base.slice(1, 9)


def _il(keys: List[Int64]) -> InListFilter:
    var o = InListFilter.try_from_int64(keys)
    return o.take()


def _bits(m: BooleanArray) raises -> String:
    var s = String("")
    for i in range(m.length):
        s += "1" if m.get(i) else "0"
    return s


def test_range_mask_nulls_and_offset() raises:
    var rf = RangeFilter(Int64(6), Int64(11))
    # Values 5..13; rows 2 and 5 null; [6, 11] inclusive.
    assert_equal(_bits(range_mask_int64(_keys(True), rf)), "010110100")
    assert_equal(_bits(range_mask_int64(_keys(False), rf)), "011111100")


def test_in_list_mask_nulls_and_offset() raises:
    var il = _il([Int64(6), Int64(7), Int64(10), Int64(13), Int64(999)])
    assert_equal(_bits(in_list_mask_int64(_keys(True), il)), "010000001")
    assert_equal(_bits(in_list_mask_int64(_keys(False), il)), "011001001")


def test_bloom_mask_nulls_and_offset() raises:
    var bf = BloomFilter.with_ndv_fpp(64, 0.01)
    bf.insert_int64(Int64(6))
    bf.insert_int64(Int64(7))
    bf.insert_int64(Int64(10))
    bf.insert_int64(Int64(13))
    var m = bloom_mask_int64(_keys(True), bf)
    assert_equal(m.length, 9)
    # Inserted, non-null: rows 1 (6) and 8 (13) must be True.
    assert_true(m.get(1))
    assert_true(m.get(8))
    # Null rows are False although 7 and 10 were inserted.
    assert_true(not m.get(2))
    assert_true(not m.get(5))
    var plain = bloom_mask_int64(_keys(False), bf)
    for r in [1, 2, 5, 8]:
        assert_true(plain.get(r), "inserted key row " + String(r))


def test_range_mask_simd_body_and_tail() raises:
    # 11 rows: value 3*i - 4 -> -4, -1, 2, 5, 8, 11, 14, 17, 20, 23, 26.
    var keys = PrimitiveArray[DType.int64].allocate(11)
    for i in range(11):
        keys.set(i, Int64(3 * i - 4))
    assert_equal(_bits(range_mask_int64(keys, RangeFilter(Int64(-1), Int64(20)))), "01111111100")
    # A range ending on the last row (the tail on every SIMD width).
    assert_equal(_bits(range_mask_int64(keys, RangeFilter(Int64(23), Int64(26)))), "00000000011")
    # A single-value range.
    assert_equal(_bits(range_mask_int64(keys, RangeFilter(Int64(2), Int64(2)))), "00100000000")


def test_inverted_range_and_empty_keys() raises:
    var keys = PrimitiveArray[DType.int64].allocate(4)
    for i in range(4):
        keys.set(i, Int64(i * 5))
    assert_equal(_bits(range_mask_int64(keys, RangeFilter(Int64(10), Int64(5)))), "0000")
    var empty = PrimitiveArray[DType.int64].allocate(0)
    assert_equal(range_mask_int64(empty, RangeFilter(Int64(0), Int64(9))).length, 0)
    var il = _il([Int64(1)])
    assert_equal(in_list_mask_int64(empty, il).length, 0)
    var bf = BloomFilter.with_ndv_fpp(8, 0.01)
    assert_equal(bloom_mask_int64(empty, bf).length, 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
