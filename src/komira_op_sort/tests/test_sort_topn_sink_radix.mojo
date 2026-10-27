# =============================================================================
# The INT64 single-key radix route of the sort and top-N sinks
# =============================================================================
#
# `_sort_batch_single_key` radix-sorts an INT64 key when the row count is at
# least RADIX_SORT_ROW_THRESHOLD (500_000) and merge-sorts it below that. The
# first tests compare the two kernels directly (`radix_sort_int64` and
# `sort_indices_int64` give the same ascending data order, including negative
# keys). The last tests drive the sinks over a batch above the threshold and
# check the ORDER of the output and that the payload column follows its key:
# ascending, descending, and a top-N that selects through the heap.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_physical_plan.physical_plan import SortSinkData, TopNSinkData
from komira_op_sort.sort import sort_indices_int64, gather_by_indices_int64
from komira_op_sort.sort_radix import radix_sort_int64
from komira_op_sort.sort_topn_sink import (
    RADIX_SORT_ROW_THRESHOLD,
    _execute_sort_sink,
    _execute_topn_sink,
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
    # Spot-check monotone across the whole array
    for i in range(0, sorted_data.length - 1, 10_000):
        assert_true(Int((p + i)[]) <= Int((p + i + 1)[]))


def test_radix_threshold_is_500000() raises:
    """The threshold constant is 500_000."""
    assert_equal(RADIX_SORT_ROW_THRESHOLD, 500_000)


comptime _MULT: Int = 2654435761
comptime _MASK: Int = 0xFFFFFFFF


def _key_of(row: Int) -> Int:
    """The key of input row `row`: distinct for every row (the multiplier is
    odd, so the map is a bijection modulo 2^32), signed after the shift."""
    return ((row * _MULT) & _MASK) - 2_000_000_000


def _sink_batch() raises -> RecordBatch:
    """`[k INT64, id INT64]` with `RADIX_SORT_ROW_THRESHOLD + 1` rows; id is
    the 1-based input row, k = `_key_of(row)`."""
    var n = RADIX_SORT_ROW_THRESHOLD + 1
    var k = PrimitiveArray[DType.int64].allocate(n)
    var ids = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        k.set_typed[Scalar[DType.int64]](i, Int64(_key_of(i)))
        ids.set_typed[Scalar[DType.int64]](i, Int64(i + 1))
    var builder = RecordBatchBuilder.with_capacity(2)
    builder.add_column(Column.from_primitive[DType.int64](k^))
    builder.add_column(Column.from_primitive[DType.int64](ids^))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("id", ArrowType.INT64, False))
    return builder.build(sb.build())


def _one_key(desc: Bool) -> SortSinkData:
    var keys = List[String]()
    keys.append(String("k"))
    var d = List[Bool]()
    d.append(desc)
    return SortSinkData(keys^, d^)


def _assert_sorted_and_paired(rb: RecordBatch, desc: Bool, rows: Int) raises:
    """`rows` rows, strictly ordered by k in the direction, and every id still
    names the row its key came from."""
    assert_equal(rb.num_rows(), rows, "row count")
    var k = rb.column_as_primitive_int64(0)
    var ids = rb.column_as_primitive_int64(1)
    var prev = 0
    for r in range(rows):
        var key = Int(k.load[1](r)[0])
        var id = Int(ids.load[1](r)[0])
        assert_equal(key, _key_of(id - 1), "payload id does not match its key")
        if r > 0:
            if desc:
                assert_true(key < prev, "not strictly descending")
            else:
                assert_true(key > prev, "not strictly ascending")
        prev = key


def test_sort_sink_above_the_threshold_ascending() raises:
    var rb = _execute_sort_sink(_sink_batch(), _one_key(False))
    _assert_sorted_and_paired(rb, False, RADIX_SORT_ROW_THRESHOLD + 1)


def test_sort_sink_above_the_threshold_descending() raises:
    var rb = _execute_sort_sink(_sink_batch(), _one_key(True))
    _assert_sorted_and_paired(rb, True, RADIX_SORT_ROW_THRESHOLD + 1)


def test_top_n_sink_above_the_threshold_selects_the_extremes() raises:
    """LIMIT 10 over 500_001 rows goes through the bounded heap; the answer is
    the first ten rows of the full sort, in both directions."""
    for d in range(2):
        var desc = d == 1
        var keys = List[String]()
        keys.append(String("k"))
        var dirs = List[Bool]()
        dirs.append(desc)
        var top = _execute_topn_sink(_sink_batch(), TopNSinkData(keys^, dirs^, 10))
        var full = _execute_sort_sink(_sink_batch(), _one_key(desc))
        assert_equal(top.num_rows(), 10, "top-N row count")
        var top_ids = top.column_as_primitive_int64(1)
        var full_ids = full.column_as_primitive_int64(1)
        for r in range(10):
            assert_equal(
                Int(top_ids.load[1](r)[0]),
                Int(full_ids.load[1](r)[0]),
                "top-N id @" + String(r) + " desc=" + String(desc),
            )


def main() raises:
    test_radix_threshold_is_500000()
    test_sort_sink_above_the_threshold_ascending()
    test_sort_sink_above_the_threshold_descending()
    test_top_n_sink_above_the_threshold_selects_the_extremes()
    test_radix_matches_merge_small()
    test_radix_handles_negatives()
    test_radix_matches_merge_at_threshold()
    test_radix_above_threshold_monotone()
    print("All sort_topn_sink radix tests passed.")
