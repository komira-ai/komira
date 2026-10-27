# =============================================================================
# The single INT64 key route of the sort sink at and above the radix threshold
# =============================================================================
#
# `_execute_sort_sink` on one INT64 key radix-sorts a batch of
# `RADIX_SORT_ROW_THRESHOLD` rows or more and merge-sorts a smaller one. The
# sink tests run both sides of that boundary, ascending and descending, and
# check the payload column too: equal keys keep their input order in both
# directions, so the payload order does not depend on the row count.
#
# The kernel tests check that `radix_sort_int64` and `sort_indices_int64`
# agree on ascending order, that negative keys sort correctly, and that the
# threshold is 500_000 rows.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_physical_plan.physical_plan import SortSinkData
from komira_op_sort.sort import sort_indices_int64, gather_by_indices_int64
from komira_op_sort.sort_radix import radix_sort_int64
from komira_op_sort.sort_topn_sink import (
    RADIX_SORT_ROW_THRESHOLD,
    _execute_sort_sink,
)


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
    # Every adjacent pair is ordered.
    for i in range(sorted_data.length - 1):
        assert_true(Int((p + i)[]) <= Int((p + i + 1)[]))


def test_radix_threshold_is_500000() raises:
    """The radix threshold is 500_000 rows."""
    assert_equal(RADIX_SORT_ROW_THRESHOLD, 500_000)


def _tied_fixture(n: Int) raises -> RecordBatch:
    """`[k INT64, id INT64]`: `k` takes 1000 distinct values in -500..499
    spread over all `n` rows (so every value repeats), `id` is the input row
    number."""
    var ks = PrimitiveArray[DType.int64].allocate(n)
    var ids = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        ks.set_typed[Scalar[DType.int64]](i, Int64((i * 7919) % 1000) - 500)
        ids.set_typed[Scalar[DType.int64]](i, Int64(i))
    var builder = RecordBatchBuilder.with_capacity(2)
    builder.add_column(Column.from_primitive[DType.int64](ks^))
    builder.add_column(Column.from_primitive[DType.int64](ids^))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("id", ArrowType.INT64, False))
    return builder.build(sb.build())


def _sort_tied(n: Int, descending: Bool) raises -> RecordBatch:
    var keys = List[String]()
    keys.append(String("k"))
    var desc = List[Bool]()
    desc.append(descending)
    return _execute_sort_sink(_tied_fixture(n), SortSinkData(keys^, desc^))


def _key_at(rb: RecordBatch, row: Int) raises -> Int:
    return Int(rb.column_as_primitive_int64(0).get_typed[Scalar[DType.int64]](row))


def _id_at(rb: RecordBatch, row: Int) raises -> Int:
    return Int(rb.column_as_primitive_int64(1).get_typed[Scalar[DType.int64]](row))


def _assert_sorted_and_stable(
    rb: RecordBatch, n: Int, descending: Bool
) raises:
    """Keys are ordered in the requested direction; within a run of equal
    keys the payload (input row number) ascends; no row is lost."""
    assert_equal(rb.num_rows(), n)
    var id_sum = 0
    for i in range(n):
        id_sum += _id_at(rb, i)
        if i == 0:
            continue
        var prev = _key_at(rb, i - 1)
        var cur = _key_at(rb, i)
        if descending:
            assert_true(prev >= cur, "keys not descending at row " + String(i))
        else:
            assert_true(prev <= cur, "keys not ascending at row " + String(i))
        if prev == cur:
            assert_true(
                _id_at(rb, i - 1) < _id_at(rb, i),
                "equal keys left input order at row " + String(i),
            )
    assert_equal(id_sum, n * (n - 1) // 2, "payload is a permutation")


def test_sink_ascending_at_threshold_is_sorted_and_stable() raises:
    var n = RADIX_SORT_ROW_THRESHOLD
    _assert_sorted_and_stable(_sort_tied(n, False), n, False)


def test_sink_descending_at_threshold_is_sorted_and_stable() raises:
    var n = RADIX_SORT_ROW_THRESHOLD
    _assert_sorted_and_stable(_sort_tied(n, True), n, True)


def test_sink_descending_below_threshold_is_sorted_and_stable() raises:
    var n = RADIX_SORT_ROW_THRESHOLD - 1
    _assert_sorted_and_stable(_sort_tied(n, True), n, True)


def test_sink_at_threshold_puts_the_extreme_keys_first() raises:
    """Ascending starts at the smallest key (-500), descending at the largest
    (499)."""
    var n = RADIX_SORT_ROW_THRESHOLD
    assert_equal(_key_at(_sort_tied(n, False), 0), -500)
    assert_equal(_key_at(_sort_tied(n, True), 0), 499)


def main() raises:
    var suite = TestSuite()
    suite.test[test_radix_threshold_is_500000]()
    suite.test[test_radix_matches_merge_small]()
    suite.test[test_radix_handles_negatives]()
    suite.test[test_radix_matches_merge_at_threshold]()
    suite.test[test_radix_above_threshold_monotone]()
    suite.test[test_sink_ascending_at_threshold_is_sorted_and_stable]()
    suite.test[test_sink_descending_at_threshold_is_sorted_and_stable]()
    suite.test[test_sink_descending_below_threshold_is_sorted_and_stable]()
    suite.test[test_sink_at_threshold_puts_the_extreme_keys_first]()
    suite^.run()
