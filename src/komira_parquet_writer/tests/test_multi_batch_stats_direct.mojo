# Chunk statistics across several RecordBatches (`writer_multi_batch_stats`).
#
# The oracle is the single-array encoder: the statistics folded across
# batches must equal `encode_plain_column`'s for the batches' concatenation
# (field for field, HLL registers included), so a batch boundary can never
# change what a footer says.
#
#   * test_int_stats_equal_the_concatenations: INT32 and INT64 columns, split
#     in three batches (one sliced, so its offset is not 0; one with nulls
#     whose null slots hold hostile values) match the concatenation's min,
#     max, null_count, distinct_count and registers. Catches a scan that
#     reads a batch from offset 0, includes null slots in min/max, or drops a
#     batch's nulls from the count.
#   * test_float_stats_equal_the_concatenations: DOUBLE and FLOAT with NaN,
#     -0.0/+0.0 and nulls: NaN never in min/max, nan_count summed, a zero
#     bound written as -0.0 / +0.0. Catches the integer scan being reused
#     for floats (a NaN lane taken as the minimum).
#   * test_all_null_and_all_nan_publish_no_bounds: only nulls -> null_count
#     alone; only NaN -> nan_count alone.
#   * test_empty_and_other_types_give_none: no rows, an UNSIGNED or narrow
#     dtype -> None (its signed order is not its own).
from std.math import nan
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_collections.slab import Slab
from komira_parquet_api.metadata import Statistics
from komira_parquet_writer import encode_plain_column
from komira_parquet_writer.writer_multi_batch_stats import (
    _compute_stats_across_batches,
)


def _batch[
    dtype: DType
](var arr: PrimitiveArray[dtype]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("c", ArrowType.from_dtype(dtype), True))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[dtype](arr))
    return b.build(sb.build())


def _same_bytes(a: Optional[List[UInt8]], b: Optional[List[UInt8]], what: String) raises:
    assert_equal(Bool(a), Bool(b), what + ": present")
    if a:
        assert_equal(len(a.value()), len(b.value()), what + ": length")
        for i in range(len(a.value())):
            assert_equal(Int(a.value()[i]), Int(b.value()[i]), what + " byte " + String(i))


def _same_stats(got: Optional[Statistics], want: Optional[Statistics], what: String) raises:
    assert_equal(Bool(got), Bool(want), what + ": statistics present")
    if not got:
        return
    ref g = got.value()
    ref w = want.value()
    assert_equal(Bool(g.null_count), Bool(w.null_count), what + ": null_count present")
    if g.null_count:
        assert_equal(g.null_count.value(), w.null_count.value(), what + ": null_count")
    assert_equal(Bool(g.distinct_count), Bool(w.distinct_count), what + ": distinct present")
    if g.distinct_count:
        assert_equal(g.distinct_count.value(), w.distinct_count.value(), what + ": distinct")
    assert_equal(Bool(g.nan_count), Bool(w.nan_count), what + ": nan_count present")
    if g.nan_count:
        assert_equal(g.nan_count.value(), w.nan_count.value(), what + ": nan_count")
    _same_bytes(g.min_value, w.min_value, what + " min")
    _same_bytes(g.max_value, w.max_value, what + " max")
    _same_bytes(g.hll_registers, w.hll_registers, what + " registers")


def _int_value(i: Int) -> Int:
    return (i * 7919) % 1009 - 300


def _int_array[
    dtype: DType
](start: Int, n: Int, null_every: Int) raises -> PrimitiveArray[dtype]:
    """Rows start..start+n-1 of the sequence; every `null_every`-th is null
    (0 for none) and holds a value below every real one."""
    var a = PrimitiveArray[dtype].allocate_nullable(n) if null_every > 0 else PrimitiveArray[dtype].allocate(n)
    for i in range(n):
        if null_every > 0 and (start + i) % null_every == 1:
            a.set(i, Scalar[dtype](-100000))
            a._set_null(i)
        else:
            a.set(i, Scalar[dtype](_int_value(start + i)))
    return a^


def _check_ints[dtype: DType]() raises:
    # Three batches: [0, 700) plain, [700, 1500) with nulls, and the middle of
    # [1500, 3500) sliced to [1600, 3000) so its offset is 100.
    var whole = List[Scalar[dtype]]()
    var whole_valid = List[Bool]()
    var a1 = _int_array[dtype](0, 700, 0)
    var a2 = _int_array[dtype](700, 800, 5)
    var a3_full = _int_array[dtype](1500, 2000, 0)
    var a3 = a3_full.slice(100, 1400)
    var batches = Slab[RecordBatch]()
    batches.append(_batch[dtype](a1.slice(0, 700)))
    batches.append(_batch[dtype](a2.slice(0, 800)))
    batches.append(_batch[dtype](a3.slice(0, 1400)))
    # The reference: one nullable array holding the same 2900 rows.
    var ref_arr = PrimitiveArray[dtype].allocate_nullable(2900)
    for i in range(700):
        ref_arr.set(i, Scalar[dtype](_int_value(i)))
    for i in range(800):
        if (700 + i) % 5 == 1:
            ref_arr.set(700 + i, Scalar[dtype](-100000))
            ref_arr._set_null(700 + i)
        else:
            ref_arr.set(700 + i, Scalar[dtype](_int_value(700 + i)))
    for i in range(1400):
        ref_arr.set(1500 + i, Scalar[dtype](_int_value(1600 + i)))
    var want = encode_plain_column[dtype](0, ref_arr, "c", nullable=True).statistics.copy()
    var got = _compute_stats_across_batches[dtype](batches, 3, 0)
    _same_stats(got, want, "ints")
    assert_equal(got.value().null_count.value(), 160)


def test_int_stats_equal_the_concatenations() raises:
    _check_ints[DType.int32]()
    _check_ints[DType.int64]()


def _f(i: Int) -> Float64:
    if i % 97 == 3:
        return nan[DType.float64]()
    if i % 89 == 5:
        return -0.0
    return Float64((i * 31) % 211) / 4.0 - 20.0


def _check_floats[dtype: DType]() raises:
    var parts: List[Int] = [0, 500, 1300, 2000]
    var batches = Slab[RecordBatch]()
    var ref_arr = PrimitiveArray[dtype].allocate_nullable(2000)
    for p in range(3):
        var n = parts[p + 1] - parts[p]
        var a = PrimitiveArray[dtype].allocate_nullable(n)
        for i in range(n):
            var r = parts[p] + i
            if r % 13 == 4:
                a.set(i, Scalar[dtype](1e30))
                a._set_null(i)
                ref_arr.set(r, Scalar[dtype](1e30))
                ref_arr._set_null(r)
            else:
                a.set(i, Scalar[dtype](_f(r)))
                ref_arr.set(r, Scalar[dtype](_f(r)))
        batches.append(_batch[dtype](a^))
    var want = encode_plain_column[dtype](0, ref_arr, "c", nullable=True).statistics.copy()
    var got = _compute_stats_across_batches[dtype](batches, 3, 0)
    _same_stats(got, want, "floats")
    assert_true(got.value().nan_count.value() > 0)
    assert_true(got.value().null_count.value() > 0)


def test_float_stats_equal_the_concatenations() raises:
    _check_floats[DType.float64]()
    _check_floats[DType.float32]()


def test_all_null_and_all_nan_publish_no_bounds() raises:
    var nulls = PrimitiveArray[DType.int64].allocate_nullable(4)
    for i in range(4):
        nulls.set(i, 9)
        nulls._set_null(i)
    var b1 = Slab[RecordBatch]()
    b1.append(_batch[DType.int64](nulls^))
    var s1 = _compute_stats_across_batches[DType.int64](b1, 1, 0).value().copy()
    assert_equal(s1.null_count.value(), 4)
    assert_false(Bool(s1.min_value))
    assert_false(Bool(s1.max_value))
    var all_nan = PrimitiveArray[DType.float64].allocate(3)
    for i in range(3):
        all_nan.set(i, nan[DType.float64]())
    var b2 = Slab[RecordBatch]()
    b2.append(_batch[DType.float64](all_nan^))
    var s2 = _compute_stats_across_batches[DType.float64](b2, 1, 0).value().copy()
    assert_equal(s2.nan_count.value(), 3)
    assert_false(Bool(s2.min_value))
    assert_false(Bool(s2.max_value))


def test_empty_and_other_types_give_none() raises:
    var empty = Slab[RecordBatch]()
    empty.append(_batch[DType.int32](PrimitiveArray[DType.int32].allocate(0)))
    assert_false(Bool(_compute_stats_across_batches[DType.int32](empty, 1, 0)))
    var empty_f = Slab[RecordBatch]()
    empty_f.append(_batch[DType.float64](PrimitiveArray[DType.float64].allocate(0)))
    assert_false(Bool(_compute_stats_across_batches[DType.float64](empty_f, 1, 0)))
    var u = Slab[RecordBatch]()
    u.append(_batch[DType.uint32](PrimitiveArray[DType.uint32].from_list([1, 2, 3])))
    assert_false(Bool(_compute_stats_across_batches[DType.uint32](u, 1, 0)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
