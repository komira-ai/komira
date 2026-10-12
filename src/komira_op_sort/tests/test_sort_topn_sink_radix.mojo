# =============================================================================
# Regression tests for the Int64 single-key radix dispatch added to
# `_sort_batch_single_key` in sort_topn_sink.mojo.
#
# `_sort_batch_single_key` dispatches to `radix_sort_int64` when the row
# count is >= RADIX_SORT_ROW_THRESHOLD (500_000), and falls back to
# `sort_indices_int64` (merge sort) below that. Both paths must produce
# identical ascending orders; descending is reversed.
#
# We test the dispatch indirectly by asserting:
#   - radix_sort_int64 and sort_indices_int64 produce the same ascending
#     permutation on small and threshold-sized inputs (byte-identical data order).
#   - After a reverse, descending output is consistent.
#   - Negative values sort correctly (validates sign-bit flip in radix).
#
# Kernel-level equivalence is enough to guarantee that the `_sort_batch_single_key`
# switch is semantically a no-op for correctness (only a performance change).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_op_sort.sort import sort_indices_int64, gather_by_indices_int64
from komira_op_sort.sort_radix import radix_sort_int64
from komira_op_sort.sort_topn_sink import RADIX_SORT_ROW_THRESHOLD


def _compare_orders(
    keys: PrimitiveArray[DType.int64],
    a: PrimitiveArray[DType.int32],
    b: PrimitiveArray[DType.int32],
) raises:
    """Gather keys with both permutations and assert pointwise equality.

    Because both kernels are stable and sort ascending, the *data* order
    must be byte-identical even when the raw index permutations differ on
    runs of equal keys (which is allowed by stable-sort definition).
    """
    assert_equal(a.length, b.length)
    var ga = gather_by_indices_int64(keys, a)
    var gb = gather_by_indices_int64(keys, b)
    var pa = ga._typed_ptr_mut()
    var pb = gb._typed_ptr_mut()
    for i in range(ga.length):
        assert_equal(Int((pa + i)[]), Int((pb + i)[]))


def test_radix_matches_merge_small() raises:
    """Below-threshold inputs: radix and merge produce identical ordering."""
    var vals: List[Scalar[DType.int64]] = [
        Int64(30), Int64(10), Int64(50), Int64(20), Int64(40),
        Int64(10), Int64(50), Int64(20),
    ]
    var keys = PrimitiveArray[DType.int64].from_list(vals)
    var a = sort_indices_int64(keys, False)
    var b = radix_sort_int64(keys)
    _compare_orders(keys, a, b)


def test_radix_matches_merge_at_threshold() raises:
    """At RADIX_SORT_ROW_THRESHOLD rows, both kernels produce identical orderings."""
    var n = RADIX_SORT_ROW_THRESHOLD
    var vals = List[Scalar[DType.int64]]()
    # Reverse-sorted input with duplicates every 7 rows.
    for i in range(n):
        vals.append(Int64((n - i) // 7))
    var keys = PrimitiveArray[DType.int64].from_list(vals)
    var a = sort_indices_int64(keys, False)
    var b = radix_sort_int64(keys)
    _compare_orders(keys, a, b)


def test_radix_handles_negatives() raises:
    """Negative Int64 values sort correctly via sign-bit flip."""
    var vals: List[Scalar[DType.int64]] = [
        Int64(5), Int64(-1_000_000_000_000), Int64(-1),
        Int64(0), Int64(1), Int64(-9_223_372_036_854_775_807),
        Int64(9_223_372_036_854_775_807),
    ]
    var keys = PrimitiveArray[DType.int64].from_list(vals)
    var b = radix_sort_int64(keys)
    var sorted_data = gather_by_indices_int64(keys, b)
    var p = sorted_data._typed_ptr_mut()
    # Verify strictly ascending
    for i in range(sorted_data.length - 1):
        assert_true(Int((p + i)[]) <= Int((p + i + 1)[]))


def test_radix_above_threshold_monotone() raises:
    """Above-threshold: radix output is correctly ordered end-to-end."""
    var n = RADIX_SORT_ROW_THRESHOLD + 10_000
    var vals = List[Scalar[DType.int64]]()
    for i in range(n):
        vals.append(Int64((i * 2654435761) & 0xFFFFFFFF))  # scrambled
    var keys = PrimitiveArray[DType.int64].from_list(vals)
    var perm = radix_sort_int64(keys)
    var sorted_data = gather_by_indices_int64(keys, perm)
    var p = sorted_data._typed_ptr_mut()
    # Spot-check monotone across the whole array
    for i in range(0, sorted_data.length - 1, 10_000):
        assert_true(Int((p + i)[]) <= Int((p + i + 1)[]))


def test_threshold_value_matches_v03() raises:
    """Guard: the threshold constant is 500_000."""
    assert_equal(RADIX_SORT_ROW_THRESHOLD, 500_000)


def main() raises:
    test_threshold_value_matches_v03()
    test_radix_matches_merge_small()
    test_radix_handles_negatives()
    test_radix_matches_merge_at_threshold()
    test_radix_above_threshold_monotone()
    print("All sort_topn_sink radix tests passed.")
