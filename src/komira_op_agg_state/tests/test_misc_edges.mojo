# =============================================================================
# test_misc_edges.mojo — refusals and rarely-taken paths of the accumulator
# set, the UDF aggregate adapter, the string-keyed composite aggregator, the
# statistical accumulators and the top-2 struct aggregator
# =============================================================================
#
#   MonomorphicKernel / AccumulatorSet
#       an unwired kernel refuses by name; a row count past the gid buffer (or
#       negative) is refused before the kernel runs; an accumulator index out
#       of range is refused by the set.
#   AggFnAcc
#       merge_aligned of two different lengths, a batch shorter than its gids,
#       an input column of the wrong Arrow type and a gid past ensure_capacity
#       are each refused with their own message, and nothing is folded.
#   CompositeKeyAggregator
#       insert_count and insert_multi_agg over 40 keys from a 2-slot table:
#       every group is found again after each resize and through probe
#       collisions, with the right count / sums.
#   StddevAccumulator / CovarianceAccumulator / PercentileAccumulator
#       population and sample variance and standard deviation on a known set;
#       the documented 0.0 sentinels on too few rows; an empty percentile
#       refuses by name.
#   LargestKAggregator
#       combine with an empty donor and finalize of an empty state, on a state
#       the compiler cannot fold (it comes out of a runtime list).
# =============================================================================

from std.math import sqrt
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, SchemaBuilder, RecordBatch, RecordBatchBuilder
from komira_agg.builtin_agg_fns_sum import SumF64
from komira_op_agg_state.agg_fn_acc import AggFnAcc
from komira_op_agg_state.accumulator_set import (
    AccumulatorSet, MonomorphicKernel, resolve_row_thunk,
)
from komira_agg_api.agg_layout import ACC_COUNT_NONNULL
from komira_op_agg_state.dyn_accumulator import DynAccumulator
from komira_op_agg_state.columnar_acc_typed import SumI64Acc
from komira_op_agg_state.aggregate import CompositeKeyAggregator
from komira_op_agg_state.statistical_accumulators import (
    StddevAccumulator, CovarianceAccumulator, PercentileAccumulator,
)
from komira_op_agg_state.aggregators_struct_builtin import (
    LargestKAggregator, LargestKState,
)


def _bytes_i64(mut vals: List[Int64]) -> Span[UInt8, origin_of(vals)]:
    return Span[UInt8, origin_of(vals)](
        unsafe_ptr=vals.unsafe_ptr().bitcast[UInt8](), length=len(vals) * 8
    )


def _expect(raised: Bool, got: String, want: String) raises:
    assert_true(raised, "expected a refusal: " + want)
    assert_equal(got, want)


# =============================================================================
# MonomorphicKernel / AccumulatorSet
# =============================================================================


def test_unwired_kernel_refuses() raises:
    var k = MonomorphicKernel(0)
    var acc = DynAccumulator.create[SumI64Acc](SumI64Acc())
    acc.ensure_capacity(1)
    var g: List[Int] = [0]
    var v: List[Int64] = [Int64(5)]
    var msg = String("")
    var raised = False
    try:
        k.call(acc, Span(g), _bytes_i64(v), 0, 1)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MonomorphicKernel: not wired to an accumulator type")


def test_kernel_refuses_a_row_count_past_the_gids() raises:
    var k = MonomorphicKernel.for_accumulator[SumI64Acc](0)
    var acc = DynAccumulator.create[SumI64Acc](SumI64Acc())
    acc.ensure_capacity(1)
    var g: List[Int] = [0, 0]
    var v: List[Int64] = [Int64(5), Int64(6), Int64(7)]
    var msg = String("")
    var raised = False
    try:
        k.call(acc, Span(g), _bytes_i64(v), 0, 3)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MonomorphicKernel.call: n exceeds the gid buffer")
    raised = False
    try:
        k.call(acc, Span(g), _bytes_i64(v), 0, -1)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "MonomorphicKernel.call: n exceeds the gid buffer")
    # Nothing was folded; n == len(gids) is accepted.
    k.call(acc, Span(g), _bytes_i64(v), 1, 2)
    assert_equal(acc.as_mut[SumI64Acc]().state[0], Int64(13))


def test_accumulator_set_refuses_an_index_out_of_range() raises:
    var s = AccumulatorSet()
    s.add[SumI64Acc](SumI64Acc(), value_col_index=0, output_field_index=0, acc_kind=UInt8(0))
    s.dyn_accs[0].ensure_capacity(1)
    var g: List[Int] = [0]
    var v: List[Int64] = [Int64(5)]
    for bad in [1, -1]:
        var msg = String("")
        var raised = False
        try:
            s.update(bad, Span(g), _bytes_i64(v), 0, 1)
        except e:
            raised = True
            msg = String(e)
        _expect(raised, msg, "AccumulatorSet.update: accumulator index out of range")
    s.update(0, Span(g), _bytes_i64(v), 0, 1)
    assert_equal(s.dyn_accs[0].as_mut[SumI64Acc]().state[0], Int64(5))


def _zeroed(n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(UInt8(0))
    return out^


def test_row_thunk_count_nonnull_and_unknown_tag() raises:
    """COUNT(col) counts one per call at its slot and ignores the value; an
    unknown tag resolves to the 32-byte SUM/COUNT/MIN/MAX quartet."""
    var c = _zeroed(16)
    var nn = resolve_row_thunk(ACC_COUNT_NONNULL)
    nn.call(Span(c), 8, 99.0)
    nn.call(Span(c), 8, -1.0)
    nn.call(Span(c), 8, 0.0)
    assert_equal((c.unsafe_ptr() + 8).bitcast[Int64]()[], Int64(3))
    assert_equal((c.unsafe_ptr()).bitcast[Int64]()[], Int64(0))

    var q = _zeroed(32)
    (q.unsafe_ptr() + 16).bitcast[Float64]()[] = Float64(1.0e300)
    (q.unsafe_ptr() + 24).bitcast[Float64]()[] = Float64(-1.0e300)
    var fallback = resolve_row_thunk(UInt8(200))
    fallback.call(Span(q), 0, 4.0)
    fallback.call(Span(q), 0, -2.0)
    assert_equal((q.unsafe_ptr()).bitcast[Float64]()[], Float64(2.0))
    assert_equal((q.unsafe_ptr() + 8).bitcast[Int64]()[], Int64(2))
    assert_equal((q.unsafe_ptr() + 16).bitcast[Float64]()[], Float64(-2.0))
    assert_equal((q.unsafe_ptr() + 24).bitcast[Float64]()[], Float64(4.0))


# =============================================================================
# AggFnAcc refusals
# =============================================================================


def _batch_f64(vals: List[Float64]) raises -> RecordBatch:
    var arr = PrimitiveArray[DType.float64].allocate(len(vals))
    for i in range(len(vals)):
        arr.set(i, vals[i])
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.from_dtype(DType.float64), False))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[DType.float64](arr^))
    return b.build(sb.build())


def _batch_i64_named_v() raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int64].allocate(2)
    arr.set(0, Int64(1))
    arr.set(1, Int64(2))
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.from_dtype(DType.int64), False))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[DType.int64](arr^))
    return b.build(sb.build())


def test_agg_fn_acc_merge_aligned_refuses_a_length_mismatch() raises:
    var a = AggFnAcc[SumF64](SumF64())
    var b = AggFnAcc[SumF64](SumF64())
    a.ensure_capacity(3)
    b.ensure_capacity(2)
    var msg = String("")
    var raised = False
    try:
        a.merge_aligned(b)
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "AggFnAcc.merge_aligned: length mismatch (self=3, src=2)")


def test_agg_fn_acc_refuses_a_batch_shorter_than_its_gids() raises:
    var a = AggFnAcc[SumF64](SumF64())
    a.ensure_capacity(1)
    var gids: List[Int] = [0, 0, 0]
    var vals: List[Float64] = [Float64(1.0), Float64(2.0)]
    var msg = String("")
    var raised = False
    try:
        a.update_record_batch(gids, _batch_f64(vals))
    except e:
        raised = True
        msg = String(e)
    _expect(
        raised, msg,
        "AggFnAcc.update_record_batch: gids has 3 entries but the batch has only 2 rows",
    )
    var col = a.finalize_to_column()
    assert_equal(col._data.view_typed_ro[DType.float64]()[0], Float64(0.0))


def test_agg_fn_acc_refuses_a_column_of_the_wrong_type() raises:
    var a = AggFnAcc[SumF64](SumF64())
    a.ensure_capacity(1)
    var gids: List[Int] = [0, 0]
    var msg = String("")
    var raised = False
    try:
        a.update_record_batch(gids, _batch_i64_named_v())
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "an INT64 column for a FLOAT64 input must be refused")
    assert_true(
        msg.startswith("AggFnAcc: input column 'v' has Arrow type code "), msg
    )
    assert_true(" but the UDF declared dtype " in msg, msg)


def test_agg_fn_acc_record_batch_refuses_a_gid_out_of_range() raises:
    var a = AggFnAcc[SumF64](SumF64())
    a.ensure_capacity(2)
    var vals: List[Float64] = [Float64(1.0), Float64(2.0)]
    for bad in [2, -1]:
        var gids: List[Int] = [0, bad]
        var msg = String("")
        var raised = False
        try:
            a.update_record_batch(gids, _batch_f64(vals))
        except e:
            raised = True
            msg = String(e)
        _expect(
            raised, msg,
            "AggFnAcc.update_record_batch: gid out of range — caller must ensure_capacity first",
        )


# =============================================================================
# CompositeKeyAggregator: insert_count and insert_multi_agg through resizes
# =============================================================================


def _key(i: Int) -> List[String]:
    return [String("g") + String(i), String(i % 3)]


def test_composite_insert_count_through_resizes_and_collisions() raises:
    var agg = CompositeKeyAggregator.create(num_aggs=2, initial_capacity=2)
    for rep in range(2):
        for i in range(40):
            agg.insert_count(_key(i), 1)
    assert_equal(agg.num_groups, 40)
    assert_true(agg.capacity >= 64)
    for g in range(agg.num_groups):
        assert_equal(agg.accumulators[g].counts[1], 2)
        assert_equal(agg.accumulators[g].counts[0], 0)
        var keys = agg.get_group_keys(g)
        assert_equal(len(keys), 2)
        assert_equal(keys[0], String("g") + String(g))


def test_composite_insert_multi_agg_through_resizes_and_collisions() raises:
    var agg = CompositeKeyAggregator.create(num_aggs=2, initial_capacity=2)
    for rep in range(3):
        for i in range(40):
            var vals: List[Float64] = [Float64(i), Float64(rep)]
            agg.insert_multi_agg(_key(i), vals)
    assert_equal(agg.num_groups, 40)
    for g in range(agg.num_groups):
        assert_equal(agg.accumulators[g].sums[0], Float64(3 * g))
        assert_equal(agg.accumulators[g].sums[1], Float64(3))
        assert_equal(agg.accumulators[g].counts[1], 3)


# =============================================================================
# Statistical accumulators
# =============================================================================


def test_stddev_population_and_sample() raises:
    var s = StddevAccumulator.create()
    var xs: List[Float64] = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]
    for i in range(len(xs)):
        s.update(xs[i])
    assert_equal(s.variance_pop(), Float64(4.0))
    assert_equal(s.stddev_pop(), Float64(2.0))
    assert_true(abs(s.variance_sample() - Float64(32.0) / Float64(7.0)) < 1e-12)
    assert_true(abs(s.stddev_sample() - sqrt(Float64(32.0) / Float64(7.0))) < 1e-12)


def test_stddev_and_covariance_sentinels_on_too_few_rows() raises:
    # Pins what the code returns on too few rows: 0.0 (variance_pop and
    # covar_pop guard count == 0, variance_sample guards count < 2). No
    # docstring promises this value; the test records current behaviour.
    var s = StddevAccumulator.create()
    assert_equal(s.variance_pop(), Float64(0.0))
    s.update(3.0)
    assert_equal(s.variance_sample(), Float64(0.0))
    assert_equal(s.variance_pop(), Float64(0.0))
    var c = CovarianceAccumulator.create()
    assert_equal(c.count, 0)
    assert_equal(c.covar_pop(), Float64(0.0))
    c.update(1.0, 2.0)
    c.update(3.0, 6.0)
    # cov_pop of {(1,2), (3,6)} = ((1-2)(2-4) + (3-2)(6-4)) / 2 = 2.
    assert_equal(c.covar_pop(), Float64(2.0))


def test_percentile_accumulator_refuses_an_empty_input() raises:
    var p = PercentileAccumulator.create(0.5)
    var msg = String("")
    var raised = False
    try:
        _ = p.result()
    except e:
        raised = True
        msg = String(e)
    _expect(raised, msg, "PercentileAccumulator.result: no values")
    p.insert(4.0)
    assert_equal(p.result(), Float64(4.0))


# =============================================================================
# LargestKAggregator on runtime states
# =============================================================================


def test_largestk_empty_donor_and_empty_finalize_at_runtime() raises:
    # Pick the states out of a runtime list so neither branch can be decided
    # at compile time.
    var vals: List[Float64] = [Float64(3.0), Float64(8.0)]
    var states = List[LargestKState]()
    for n in range(len(vals) + 1):
        var s = LargestKAggregator.init()
        for i in range(n):
            LargestKAggregator.update(s, vals[i])
        states.append(s^)
    for n in range(len(states)):
        # An empty donor leaves every accumulator state as it was, an empty
        # or a one-value one included (a push of the donor's unused slot
        # would raise its count).
        var accum = states[n].copy()
        LargestKAggregator.combine(accum, states[0])
        assert_equal(accum.count, states[n].count)
        assert_true(accum.heap[0] == states[n].heap[0])
        assert_true(accum.heap[1] == states[n].heap[1])
    for n in range(len(states)):
        var r = LargestKAggregator.finalize(states[n])
        if states[n].count == Int32(0):
            assert_true(r != r, "an empty state finalizes to NaN")
        else:
            assert_equal(r, vals[Int(states[n].count) - 1])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
