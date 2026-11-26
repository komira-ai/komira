# =============================================================================
# The ungrouped aggregation sink over FLOAT64 and FLOAT32 arguments
# =============================================================================
#
# The tests hand the sink morsels directly, naming the worker of each, so the
# rows a worker folds and the order of the merge are known. The expected
# answers are written here from the values alone: a plain loop that adds them
# from +0.0, which is the fold `agg_fold` documents (row order within a worker,
# then the workers' sums in worker order). What they prove:
#
#   * SUM, AVG, MIN, MAX, COUNT and COUNT(*) of a FLOAT64 column with NULLs on
#     one worker equal the plain loop, SUM and AVG bit for bit.
#   * Over three and seven workers, with morsels dealt in order and in
#     reverse, SUM is the workers' loop sums added in worker order, bit for
#     bit, and AVG that sum over the count; MIN, MAX and the counts do not
#     depend on the dealing; the sum stays within 1e-12 relative of the
#     one-worker sum on these well-conditioned values.
#   * A FLOAT32 column is summed in double: three values of 2^127 sum to
#     3 * 2^127, past the FLOAT32 range, and MIN and MAX come back as FLOAT32
#     holding the input's value.
#   * NaN is above every value for MIN and MAX (query_semantics 2.7) on every
#     rotation of the rows and every cut of them between two workers: MAX is
#     NaN, MIN is the least other value, MIN of only NaNs is NaN; SUM and AVG
#     of a set with a NaN are NaN.
#   * Infinities: +inf in a sum is +inf, +inf with -inf is NaN, two values of
#     2^1023 sum to +inf (no overflow is refused), -inf is MIN.
#   * A sum of -0.0 values is +0.0 (DuckDB starts its sum at +0.0) on one and
#     two workers, while MIN and MAX keep -0.0.
#   * -0.0 and 0.0 tie for MIN and MAX: the zero of the first row stays within
#     a worker, and the lower worker's in the merge.
#   * Over only NULLs, over no morsel and over a morsel of no row: SUM, AVG,
#     MIN and MAX are NULL, COUNT is zero, COUNT(*) counts the rows.
#   * The declared output types: SUM into FLOAT64 and MIN and MAX into the
#     input's float type are built; SUM or AVG into FLOAT32 is refused when
#     the sink is built; a float SUM into INT64 or DECIMAL128, a FLOAT64 MIN
#     into FLOAT32, a FLOAT32 MAX into FLOAT64 and an integer SUM into FLOAT64
#     are refused by name when the output is built.
#   * A FLOAT32 column after a FLOAT64 one for the same aggregate is refused,
#     in one worker and across two.
#
# The grouped sinks' float folds are tested in test_sink_group_float_agg.

from std.math import inf, nan
from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from arrow.arrow_types import ArrowType
from arrow.column_builder import ColumnBuilder
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from containers.slab import Slab
from morsel.morsel import Morsel
from morsel.pipeline_execution import PipelineExecution
from pipeline_exec.plan_harness import agg_list, ungrouped_agg_data
from pipeline_exec.segment_pool import SegmentPool
from pipeline_exec.sink_agg import AggSink
from plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_MAX,
    AGG_MEAN,
    AGG_MIN,
    AGG_SUM,
    AggExpr,
)
from plan_expr.expr import Expr


# -----------------------------------------------------------------------------
# Inputs and the sink
# -----------------------------------------------------------------------------


def _nan() -> Float64:
    return nan[DType.float64]()


def _inf() -> Float64:
    return inf[DType.float64]()


def _bits(x: Float64) -> UInt64:
    return bitcast[DType.uint64](x)


def _vals(*xs: Float64) -> List[Optional[Float64]]:
    var out = List[Optional[Float64]]()
    for i in range(len(xs)):
        out.append(Optional[Float64](xs[i]))
    return out^


def _batch(ref d: List[Optional[Float64]]) raises -> RecordBatch:
    """Column `d` (FLOAT64) holding `d`, and column `f` (FLOAT32) holding each
    value rounded to FLOAT32; None is NULL in both."""
    var dc = ColumnBuilder[DType.float64].with_capacity(len(d))
    var fc = ColumnBuilder[DType.float32].with_capacity(len(d))
    for i in range(len(d)):
        if d[i]:
            dc.append(d[i].value())
            fc.append(d[i].value().cast[DType.float32]())
        else:
            dc.append_null()
            fc.append_null()
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("d", ArrowType.FLOAT64, True))
    rb.add_column(dc^.materialize())
    sb.add_field(Field("f", ArrowType.FLOAT32, True))
    rb.add_column(fc^.materialize())
    return rb.build(sb.build())


def _slice(
    ref d: List[Optional[Float64]], start: Int, end: Int
) -> List[Optional[Float64]]:
    var out = List[Optional[Float64]]()
    for i in range(start, end):
        out.append(d[i])
    return out^


def _agg(func: UInt8, col: String) -> AggExpr:
    return AggExpr(func, Optional(Expr.col_ref(col)), None)


def _six(col: String) -> Slab[AggExpr]:
    var aggs = Slab[AggExpr]()
    aggs.append(_agg(AGG_SUM, col))
    aggs.append(_agg(AGG_MEAN, col))
    aggs.append(_agg(AGG_MIN, col))
    aggs.append(_agg(AGG_MAX, col))
    aggs.append(_agg(AGG_COUNT, col))
    aggs.append(AggExpr(AGG_COUNT, None, None))
    return aggs^


def _six_schema(minmax: ArrowType) raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.FLOAT64, True))
    sb.add_field(Field("a", ArrowType.FLOAT64, True))
    sb.add_field(Field("mn", minmax, True))
    sb.add_field(Field("mx", minmax, True))
    sb.add_field(Field("c", ArrowType.INT64, False))
    sb.add_field(Field("n", ArrowType.INT64, False))
    return sb.build()


def _sink(col: String) raises -> AggSink:
    var minmax = ArrowType.FLOAT64 if col == "d" else ArrowType.FLOAT32
    return AggSink(
        ungrouped_agg_data(_six(col), _six_schema(minmax)), SegmentPool(), 0
    )


def _take(mut sink: AggSink, workers: Int) raises -> RecordBatch:
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _dealt(
    col: String,
    ref d: List[Optional[Float64]],
    morsel_rows: Int,
    workers: Int,
    reverse: Bool,
) raises -> RecordBatch:
    """The six aggregates of `col` over `d` cut into morsels of `morsel_rows`,
    morsel k going to worker k % workers (or workers - 1 - k % workers)."""
    var sink = _sink(col)
    sink.resize_worker_state(workers)
    var k = 0
    var start = 0
    while start < len(d):
        var end = min(start + morsel_rows, len(d))
        var w = k % workers
        if reverse:
            w = workers - 1 - w
        sink.consume(w, Morsel(_batch(_slice(d, start, end)), k, 0))
        k += 1
        start = end
    return _take(sink, workers)


def _model_sum(
    ref d: List[Optional[Float64]],
    morsel_rows: Int,
    workers: Int,
    reverse: Bool,
) -> Float64:
    """The documented float fold for `_dealt`'s dealing: each worker adds its
    rows from +0.0 in row order, then the workers' sums are added from +0.0
    in worker order."""
    var partial = List[Float64]()
    for _ in range(workers):
        partial.append(0.0)
    for i in range(len(d)):
        var w = (i // morsel_rows) % workers
        if reverse:
            w = workers - 1 - w
        if d[i]:
            partial[w] += d[i].value()
    var total = 0.0
    for w in range(workers):
        total += partial[w]
    return total


def _f(ref b: RecordBatch, col: Int) raises -> Float64:
    return b.column_at(col).as_primitive[DType.float64]().get(0)


def _f32(ref b: RecordBatch, col: Int) raises -> Float32:
    return b.column_at(col).as_primitive[DType.float32]().get(0)


def _i(ref b: RecordBatch, col: Int) raises -> Int:
    return Int(b.column_at(col).as_primitive[DType.int64]().get(0))


def _null(ref b: RecordBatch, col: Int) -> Bool:
    return b.column_at(col).is_null_at(0)


def _is_nan(x: Float64) -> Bool:
    return x != x


def _table(rows: Int) -> List[Optional[Float64]]:
    """Row r: NULL where r % 6 == 4, else ((r * 7919) % 10007 - 2000) / 7.
    Not dyadic, so the order of the additions shows in the last bits."""
    var out = List[Optional[Float64]]()
    for r in range(rows):
        if r % 6 == 4:
            out.append(None)
        else:
            out.append(
                Optional[Float64](Float64((r * 7919) % 10007 - 2000) / 7.0)
            )
    return out^


# -----------------------------------------------------------------------------
# Folds and merges
# -----------------------------------------------------------------------------


def test_float64_aggregates_equal_the_row_fold_on_one_worker() raises:
    var d = _table(1000)
    var s = 0.0
    var c = 0
    var least = _inf()
    var greatest = -_inf()
    for i in range(len(d)):
        if d[i]:
            var v = d[i].value()
            s += v
            c += 1
            least = min(least, v)
            greatest = max(greatest, v)
    var b = _dealt("d", d, 1000, 1, False)
    assert_equal(b.num_rows(), 1)
    assert_equal(_bits(_f(b, 0)), _bits(s))
    assert_equal(_bits(_f(b, 1)), _bits(s / Float64(c)))
    assert_equal(_f(b, 2), least)
    assert_equal(_f(b, 3), greatest)
    assert_equal(_i(b, 4), c)
    assert_equal(_i(b, 5), 1000)


def test_dealt_partials_add_in_worker_order() raises:
    var d = _table(1000)
    var one = _dealt("d", d, 1000, 1, False)
    var shapes = List[Int]()
    shapes.append(3)
    shapes.append(100)
    shapes.append(7)
    shapes.append(13)
    for k in range(2):
        var workers = shapes[2 * k]
        var rows = shapes[2 * k + 1]
        for rev in range(2):
            var reverse = rev == 1
            var b = _dealt("d", d, rows, workers, reverse)
            var want = _model_sum(d, rows, workers, reverse)
            var label = (
                String(workers) + " workers, reverse " + String(reverse)
            )
            assert_equal(_bits(_f(b, 0)), _bits(want), label)
            assert_equal(
                _bits(_f(b, 1)), _bits(want / Float64(_i(one, 4))), label
            )
            assert_equal(_f(b, 2), _f(one, 2), label)
            assert_equal(_f(b, 3), _f(one, 3), label)
            assert_equal(_i(b, 4), _i(one, 4), label)
            assert_equal(_i(b, 5), 1000, label)
            var diff = abs(_f(b, 0) - _f(one, 0))
            assert_true(diff <= 1e-12 * abs(_f(one, 0)), label)


def test_a_float32_column_sums_in_double_and_keeps_float32_min_max() raises:
    var big = bitcast[DType.float64](UInt64(0x47E0000000000000))  # 2^127
    var d = _vals(big, big, big)
    for workers in range(1, 3):
        var b = _dealt("f", d, 1, workers, False)
        assert_equal(_f(b, 0), 3.0 * big, String(workers))
        assert_equal(_f(b, 1), big, String(workers))
        assert_equal(b.schema.field_arrow_type(2), ArrowType.FLOAT32)
        assert_equal(_f32(b, 2), big.cast[DType.float32]())
        assert_equal(_f32(b, 3), big.cast[DType.float32]())
    var small = _vals(-1.25, 0.5, 2.75)
    var b = _dealt("f", small, 2, 2, False)
    assert_equal(_f(b, 0), 2.0)
    assert_equal(_f32(b, 2), Float32(-1.25))
    assert_equal(_f32(b, 3), Float32(2.75))


def test_nan_is_above_every_value_in_every_order_and_cut() raises:
    var base = _vals(1.0, _nan(), 2.0, _inf(), _nan(), -1.0)
    for col in range(2):
        var name = "d" if col == 0 else "f"
        for rot in range(len(base)):
            var d = List[Optional[Float64]]()
            for i in range(len(base)):
                d.append(base[(i + rot) % len(base)])
            for cut in range(len(d) + 1):
                var sink = _sink(name)
                sink.resize_worker_state(2)
                if cut > 0:
                    sink.consume(0, Morsel(_batch(_slice(d, 0, cut)), 0, 0))
                if cut < len(d):
                    sink.consume(
                        1, Morsel(_batch(_slice(d, cut, len(d))), 1, 0)
                    )
                var b = _take(sink, 2)
                var label = name + " rotation " + String(rot) + " cut " + String(cut)
                assert_true(_is_nan(_f(b, 0)), label)
                assert_true(_is_nan(_f(b, 1)), label)
                if col == 0:
                    assert_equal(_f(b, 2), -1.0, label)
                    assert_true(_is_nan(_f(b, 3)), label)
                else:
                    assert_equal(_f32(b, 2), Float32(-1.0), label)
                    var mx = _f32(b, 3)
                    assert_true(mx != mx, label)
    var only = List[Optional[Float64]]()
    only.append(Optional[Float64](_nan()))
    only.append(None)
    only.append(Optional[Float64](_nan()))
    var b = _dealt("d", only, 1, 3, False)
    assert_true(_is_nan(_f(b, 2)))
    assert_true(_is_nan(_f(b, 3)))
    assert_equal(_i(b, 4), 2)


def test_infinities_and_a_sum_past_the_double_range() raises:
    var b = _dealt("d", _vals(1.0, _inf(), 2.0), 1, 2, False)
    assert_equal(_f(b, 0), _inf())
    assert_equal(_f(b, 1), _inf())
    assert_equal(_f(b, 2), 1.0)
    assert_equal(_f(b, 3), _inf())
    b = _dealt("d", _vals(_inf(), -_inf(), 3.0), 3, 1, False)
    assert_true(_is_nan(_f(b, 0)))
    assert_true(_is_nan(_f(b, 1)))
    assert_equal(_f(b, 2), -_inf())
    assert_equal(_f(b, 3), _inf())
    var top = bitcast[DType.float64](UInt64(0x7FE0000000000000))  # 2^1023
    b = _dealt("d", _vals(top, top, 1.0), 1, 3, False)
    assert_equal(_f(b, 0), _inf())
    assert_equal(_f(b, 1), _inf())
    assert_equal(_f(b, 3), top)
    b = _dealt("f", _vals(-_inf(), -1.0), 1, 2, True)
    assert_equal(_f(b, 0), -_inf())
    assert_equal(_f32(b, 2), -inf[DType.float32]())
    assert_equal(_f32(b, 3), Float32(-1.0))


def test_a_sum_of_negative_zeros_is_positive_zero() raises:
    var d = _vals(-0.0, -0.0, -0.0)
    for workers in range(1, 3):
        var b = _dealt("d", d, 2, workers, False)
        assert_equal(_bits(_f(b, 0)), _bits(0.0), String(workers))
        assert_equal(_bits(_f(b, 1)), _bits(0.0), String(workers))
        assert_equal(_bits(_f(b, 2)), _bits(-0.0), String(workers))
        assert_equal(_bits(_f(b, 3)), _bits(-0.0), String(workers))
        var g = _dealt("f", d, 2, workers, False)
        assert_equal(_bits(_f(g, 0)), _bits(0.0), String(workers))
        assert_equal(
            bitcast[DType.uint32](_f32(g, 2)), UInt32(0x80000000)
        )


def test_min_and_max_keep_the_zero_met_first() raises:
    # -0.0 and 0.0 tie: a value replaces the one kept only when strictly less
    # or greater, so within a worker the first row's zero stays, and in the
    # merge the lower worker's (DuckDB on one thread keeps its first row's).
    var pos_first = _vals(0.0, -0.0)
    var neg_first = _vals(-0.0, 0.0)
    for col in range(2):
        var name = "d" if col == 0 else "f"
        for workers in range(1, 3):
            var label = name + " on " + String(workers) + " workers"
            var p = _dealt(name, pos_first, 1, workers, False)
            var n = _dealt(name, neg_first, 1, workers, False)
            for c in range(2, 4):
                var p_neg: Bool
                var n_neg: Bool
                if col == 0:
                    p_neg = (_bits(_f(p, c)) >> 63) == 1
                    n_neg = (_bits(_f(n, c)) >> 63) == 1
                else:
                    p_neg = (bitcast[DType.uint32](_f32(p, c)) >> 31) == 1
                    n_neg = (bitcast[DType.uint32](_f32(n, c)) >> 31) == 1
                assert_true(not p_neg, label + " column " + String(c))
                assert_true(n_neg, label + " column " + String(c))


def test_only_null_and_no_row_give_null_and_a_zero_count() raises:
    var nulls = List[Optional[Float64]]()
    for _ in range(4):
        nulls.append(None)
    for col in range(2):
        var name = "d" if col == 0 else "f"
        var b = _dealt(name, nulls, 2, 2, False)
        for c in range(4):
            assert_true(_null(b, c), name + " column " + String(c))
        assert_equal(_i(b, 4), 0)
        assert_equal(_i(b, 5), 4)
        # No morsel at all, and a morsel of no row.
        var none = _sink(name)
        none.resize_worker_state(2)
        var empty = _take(none, 2)
        var zero = _sink(name)
        zero.resize_worker_state(1)
        zero.consume(0, Morsel(_batch(List[Optional[Float64]]()), 0, 0))
        var no_rows = _take(zero, 1)
        for c in range(4):
            assert_true(_null(empty, c), name)
            assert_true(_null(no_rows, c), name)
        assert_equal(_i(empty, 4), 0)
        assert_equal(_i(empty, 5), 0)
        assert_equal(_i(no_rows, 5), 0)


# -----------------------------------------------------------------------------
# Declared types and refusals
# -----------------------------------------------------------------------------


def _one(t: ArrowType) raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("x", t, True))
    return sb.build()


def _built(func: UInt8, col: String, declared: ArrowType) raises -> String:
    """The message the sink is refused with when it is built, or ""."""
    try:
        _ = AggSink(
            ungrouped_agg_data(agg_list(_agg(func, col)), _one(declared)),
            SegmentPool(),
            0,
        )
    except e:
        return String(e)
    return ""


def _ran(
    func: UInt8, var batch: RecordBatch, col: String, declared: ArrowType
) raises -> String:
    """The message a one-morsel run is refused with, or ""."""
    try:
        var sink = AggSink(
            ungrouped_agg_data(agg_list(_agg(func, col)), _one(declared)),
            SegmentPool(),
            0,
        )
        sink.resize_worker_state(1)
        sink.consume(0, Morsel(batch^, 0, 0))
        _ = _take(sink, 1)
    except e:
        return String(e)
    return ""


def _int_batch() raises -> RecordBatch:
    var ic = ColumnBuilder[DType.int64].with_capacity(2)
    ic.append(Int64(3))
    ic.append(Int64(4))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("i", ArrowType.INT64, True))
    rb.add_column(ic^.materialize())
    return rb.build(sb.build())


def test_the_declared_output_types_of_float_aggregates() raises:
    assert_equal(_built(AGG_SUM, "d", ArrowType.FLOAT64), "")
    assert_equal(_built(AGG_MIN, "d", ArrowType.FLOAT64), "")
    assert_equal(_built(AGG_MAX, "f", ArrowType.FLOAT32), "")
    var sum32 = _built(AGG_SUM, "f", ArrowType.FLOAT32)
    assert_true("cannot produce the declared output type" in sum32, sum32)
    var avg32 = _built(AGG_MEAN, "f", ArrowType.FLOAT32)
    assert_true("cannot produce the declared output type" in avg32, avg32)
    var v = _vals(1.5, 2.5)
    var fill = "cannot fill the declared output type"
    var cases = List[String]()
    cases.append(_ran(AGG_SUM, _batch(v), "d", ArrowType.INT64))
    cases.append(_ran(AGG_SUM, _batch(v), "f", ArrowType.DECIMAL128))
    cases.append(_ran(AGG_MIN, _batch(v), "d", ArrowType.FLOAT32))
    cases.append(_ran(AGG_MAX, _batch(v), "f", ArrowType.FLOAT64))
    cases.append(_ran(AGG_SUM, _int_batch(), "i", ArrowType.FLOAT64))
    for i in range(len(cases)):
        assert_true(fill in cases[i], String(i) + ": " + cases[i])
    assert_equal(_ran(AGG_SUM, _batch(v), "f", ArrowType.FLOAT64), "")
    assert_equal(_ran(AGG_MEAN, _batch(v), "f", ArrowType.FLOAT64), "")


def _renamed_f_as_d() raises -> RecordBatch:
    """One FLOAT32 row in a column named `d`."""
    var fc = ColumnBuilder[DType.float32].with_capacity(1)
    fc.append(Float32(1.0))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("d", ArrowType.FLOAT32, True))
    rb.add_column(fc^.materialize())
    return rb.build(sb.build())


def test_float32_after_float64_for_one_aggregate_is_refused() raises:
    var one = _sink("d")
    one.resize_worker_state(1)
    one.consume(0, Morsel(_batch(_vals(1.0)), 0, 0))
    with assert_raises(contains="saw a column of another type"):
        one.consume(0, Morsel(_renamed_f_as_d(), 1, 0))
    var two = _sink("d")
    two.resize_worker_state(2)
    two.consume(0, Morsel(_batch(_vals(1.0)), 0, 0))
    two.consume(1, Morsel(_renamed_f_as_d(), 1, 0))
    var pipeline = PipelineExecution(2, 0)
    with assert_raises(contains="saw columns of different types on different workers"):
        two.combine(pipeline)


def main() raises:
    var suite = TestSuite()
    suite.test[test_float64_aggregates_equal_the_row_fold_on_one_worker]()
    suite.test[test_dealt_partials_add_in_worker_order]()
    suite.test[test_a_float32_column_sums_in_double_and_keeps_float32_min_max]()
    suite.test[test_nan_is_above_every_value_in_every_order_and_cut]()
    suite.test[test_infinities_and_a_sum_past_the_double_range]()
    suite.test[test_a_sum_of_negative_zeros_is_positive_zero]()
    suite.test[test_min_and_max_keep_the_zero_met_first]()
    suite.test[test_only_null_and_no_row_give_null_and_a_zero_count]()
    suite.test[test_the_declared_output_types_of_float_aggregates]()
    suite.test[test_float32_after_float64_for_one_aggregate_is_refused]()
    suite^.run()
