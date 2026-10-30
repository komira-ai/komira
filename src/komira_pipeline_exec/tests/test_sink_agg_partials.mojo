# =============================================================================
# The aggregation sink with data in several workers' slots
# =============================================================================
#
# The driver's dispatchers that run on one thread let the first worker drain a
# shared source, so a run through them merges empty partials only. These tests
# hand the sink morsels directly, a different worker for each, so every slot is
# non-empty when `combine` merges them. What they prove:
#
#   * COUNT, COUNT(*), SUM, MIN, MAX and AVG over three non-empty partials equal
#     the row oracle, whichever worker holds which rows: with the rows dealt in
#     order and in reverse (so the least and the greatest value each sit in the
#     first and in the last partial) and the AVG is the same bit pattern.
#   * Two DECIMAL(38,0) values of 10^38 - 1, one in each of two workers, each
#     fold fine alone and the merge refuses their sum.
#   * A worker's reservation is drawn on its first morsel and returned by
#     `combine`, and by dropping the sink when the query fails or is cancelled
#     (the driver never combines then): with a large budget, a run in which one
#     worker raises after another has reserved, and a sink dropped with
#     reservations held, both leave the pool with nothing granted.

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.string_array import StringArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_async_api.token import CancellationToken
from komira_collections.slab import Slab
from komira_morsel.morsel import Morsel
from komira_morsel.pipeline_execution import PipelineExecution
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_physical_plan.physical_plan import MorselOp
from komira_pipeline_exec.fake_dispatch import InlineDispatch
from komira_pipeline_exec.plan_harness import (
    agg_list,
    b_is_null,
    batch_segment,
    sample_batch,
    ungrouped_agg_data,
    with_agg_sink,
)
from komira_pipeline_exec.real_builder import RealBuilder
from komira_pipeline_exec.run_plan import run_plan
from komira_pipeline_exec.segment_pool import SegmentPool
from komira_pipeline_exec.sink_agg import AggSink
from komira_plan_expr.agg_expr import (
    AGG_COUNT,
    AGG_MAX,
    AGG_MEAN,
    AGG_MIN,
    AGG_SUM,
    AggExpr,
)
from komira_plan_expr.expr import Expr
from komira_plan_expr.expr_pool import ExprPool
from komira_physical_plan.physical_plan import SegmentDescPod
from komira_scalar_arithmetic.decimal_arith import I128


def _agg(func: UInt8, col: String) -> AggExpr:
    return AggExpr(func, Optional(Expr.col_ref(col)), None)


def _six_aggs() -> Slab[AggExpr]:
    var aggs = Slab[AggExpr]()
    aggs.append(_agg(AGG_SUM, "b"))
    aggs.append(_agg(AGG_COUNT, "b"))
    aggs.append(AggExpr(AGG_COUNT, None, None))
    aggs.append(_agg(AGG_MIN, "b"))
    aggs.append(_agg(AGG_MAX, "b"))
    aggs.append(_agg(AGG_MEAN, "b"))
    return aggs^


def _six_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.INT64, True))
    sb.add_field(Field("cb", ArrowType.INT64, False))
    sb.add_field(Field("cs", ArrowType.INT64, False))
    sb.add_field(Field("mn", ArrowType.INT64, True))
    sb.add_field(Field("mx", ArrowType.INT64, True))
    sb.add_field(Field("av", ArrowType.FLOAT64, True))
    return sb.build()


def _i64(ref batch: RecordBatch, col: Int) raises -> Int:
    return Int(batch.column_at(col).as_primitive[DType.int64]().get(0))


def _f64(ref batch: RecordBatch, col: Int) raises -> Float64:
    return batch.column_at(col).as_primitive[DType.float64]().get(0)


def _combine_and_take(mut sink: AggSink, workers: Int) raises -> RecordBatch:
    var pipeline = PipelineExecution(workers, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _deal(reverse: Bool) raises -> RecordBatch:
    """Rows 0..29 of the sample table in three morsels of ten, the morsel of
    rows 10 * k going to worker k (or to worker 2 - k when `reverse`)."""
    var data = ungrouped_agg_data(_six_aggs(), _six_schema())
    var sink = AggSink(data, SegmentPool(), 0)
    sink.resize_worker_state(3)
    for k in range(3):
        var w = 2 - k if reverse else k
        sink.consume(w, Morsel(sample_batch(10 * k, 10), k, 0))
    return _combine_and_take(sink, 3)


def _check(ref batch: RecordBatch, want: List[Int], avg: Float64) raises:
    for c in range(5):
        assert_equal(_i64(batch, c), want[c], "column " + String(c))
    assert_equal(_f64(batch, 5), avg)


def test_partials_merge_to_the_row_oracle_in_any_dealing() raises:
    var sum_b = 0
    var count_b = 0
    var least = 0
    var greatest = 0
    var first = True
    for r in range(30):
        if b_is_null(r):
            continue
        sum_b += r * 10
        count_b += 1
        if first:
            least = r * 10
            first = False
        greatest = r * 10
    var want = List[Int]()
    want.append(sum_b)
    want.append(count_b)
    want.append(30)
    want.append(least)
    want.append(greatest)
    var avg = Float64(sum_b) / Float64(count_b)
    # In order, the least value is in the first partial and the greatest in
    # the last; reversed, the other way round.
    var forward = _deal(False)
    var backward = _deal(True)
    _check(forward, want, avg)
    _check(backward, want, avg)
    assert_equal(_f64(forward, 5), _f64(backward, 5))


def _nines_batch() raises -> RecordBatch:
    var nines = I128(1)
    for _ in range(38):
        nines = nines * I128(10)
    nines = nines - I128(1)
    var arr = Decimal128Array.allocate_nullable(1, 38, 0)
    arr.set_i128(0, nines)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field.decimal128("d", 38, 0, True))
    rb.add_column(Column.from_decimal128(arr^))
    return rb.build(sb.build())


def _sum_d_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field.decimal128("sum", 38, 0, True))
    return sb.build()


def test_two_values_that_fit_alone_are_refused_by_the_merge() raises:
    var data = ungrouped_agg_data(
        agg_list(_agg(AGG_SUM, "d")), _sum_d_schema()
    )
    var sink = AggSink(data, SegmentPool(), 0)
    sink.resize_worker_state(2)
    # Each worker folds one value, so no fold sees an overflow.
    sink.consume(0, Morsel(_nines_batch(), 0, 0))
    sink.consume(1, Morsel(_nines_batch(), 1, 0))
    with assert_raises(contains="left the 128-bit range"):
        _ = _combine_and_take(sink, 2)


def _string_batch() raises -> RecordBatch:
    var names = List[String]()
    names.append("x")
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("b", ArrowType.STRING, False))
    rb.add_column(Column.from_string(StringArray.from_strings(names)))
    return rb.build(sb.build())


def _fail_after_another_worker_reserved(ref pool: SegmentPool) raises:
    var data = ungrouped_agg_data(_six_aggs(), _six_schema())
    var sink = AggSink(data, pool.share(), 0)
    sink.resize_worker_state(2)
    sink.consume(0, Morsel(sample_batch(0, 10), 0, 0))
    assert_true(pool.granted() > 0, "worker 0 reserved nothing")
    # SUM over a string column: worker 1 raises, the query fails, and the
    # driver drops the sink without a combine.
    with assert_raises(contains="is not served over this column type"):
        sink.consume(1, Morsel(_string_batch(), 1, 0))


def _hold_reservations_and_drop(ref pool: SegmentPool) raises:
    var data = ungrouped_agg_data(_six_aggs(), _six_schema())
    var sink = AggSink(data, pool.share(), 0)
    sink.resize_worker_state(3)
    for w in range(3):
        sink.consume(w, Morsel(sample_batch(10 * w, 10), w, 0))
    assert_true(pool.granted() > 0, "no worker reserved anything")
    # A cancelled query is dropped after this, never combined.
    sink.finalize()


def test_a_failed_or_cancelled_query_returns_what_its_workers_reserved() raises:
    var pool = SegmentPool(1 << 20)
    _fail_after_another_worker_reserved(pool)
    assert_equal(pool.granted(), 0)
    _hold_reservations_and_drop(pool)
    assert_equal(pool.granted(), 0)


def test_a_run_that_fails_after_a_worker_reserved_returns_the_pool() raises:
    var cache = ParquetMetadataCache()
    var expr_pool = ExprPool()
    var nf = 0
    var builder = RealBuilder[
        origin_of(cache), origin_of(expr_pool), origin_of(nf)
    ](cache, expr_pool)
    builder.set_memory_budget(1 << 20)
    var handle = builder.add_resident(_two_nines())
    var id = builder.add_agg_sink(
        ungrouped_agg_data(agg_list(_agg(AGG_SUM, "d")), _sum_d_schema())
    )
    var descs = List[SegmentDescPod]()
    # One row a morsel: the first worker folds the first value, reserves, and
    # fails on the second.
    descs.append(
        with_agg_sink(batch_segment(0, handle, Slab[MorselOp](), 1), id)
    )
    var dispatch = InlineDispatch()
    with assert_raises(contains="left the 128-bit range"):
        _ = run_plan(descs, builder, dispatch, 2, CancellationToken.new())
    assert_equal(builder.pool_granted(), 0)


def _two_nines() raises -> RecordBatch:
    var nines = I128(1)
    for _ in range(38):
        nines = nines * I128(10)
    nines = nines - I128(1)
    var arr = Decimal128Array.allocate_nullable(2, 38, 0)
    arr.set_i128(0, nines)
    arr.set_i128(1, nines)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field.decimal128("d", 38, 0, True))
    rb.add_column(Column.from_decimal128(arr^))
    return rb.build(sb.build())


def main() raises:
    var suite = TestSuite()
    suite.test[test_partials_merge_to_the_row_oracle_in_any_dealing]()
    suite.test[test_two_values_that_fit_alone_are_refused_by_the_merge]()
    suite.test[test_a_failed_or_cancelled_query_returns_what_its_workers_reserved]()
    suite.test[test_a_run_that_fails_after_a_worker_reserved_returns_the_pool]()
    suite^.run()
