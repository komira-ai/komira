# =============================================================================
# SUM and AVG over CAST(<boolean> AS <integer or float>)
# =============================================================================
#
# pandas and polars sum a boolean column as the number of trues and average it
# as the share of trues; the plan for that is SUM or AVG over a CAST of the
# column to an integer or a float. The aggregate sinks evaluate the argument
# through the column evaluator and fold the result. The expected answers are
# DuckDB's for the same SQL over the same rows, written out here:
#
#   SUM(CAST(b AS BIGINT)) over true, false, NULL, true      -> 2 (HUGEINT)
#   AVG(CAST(b AS BIGINT)) and AVG(CAST(b AS DOUBLE)) there   -> 0.6666666666666666
#   SUM and AVG over only false                               -> 0 and 0.0
#   SUM and AVG over only NULL, or over no rows               -> NULL and NULL
#
# What each test proves:
#   * test_sum_of_cast_bool_counts_the_trues_over_several_workers: SUM of
#     CAST(b AS BIGINT) and of CAST(b AS INTEGER), rows dealt over two
#     workers with a NULL among them, is the count of trues, declared
#     DECIMAL(38, 0) as DuckDB's HUGEINT.
#   * test_avg_of_cast_bool_is_the_share_of_trues: AVG of CAST(b AS BIGINT)
#     and of CAST(b AS DOUBLE) is 2/3, the NULL not counted.
#   * test_only_false_rows_sum_to_zero_and_average_zero: 0 and 0.0, not NULL.
#   * test_only_null_rows_and_no_rows_give_null: SUM and AVG are NULL for an
#     all-NULL column and when no morsel arrives.
#   * test_a_grouped_sum_of_cast_bool_counts_the_trues_per_group: the grouped
#     sink gives each key its own count of trues.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

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
from physical_plan.physical_plan import KEY_DTYPE_I64
from pipeline_exec.plan_harness import (
    agg_list,
    grouped_agg_data,
    ungrouped_agg_data,
)
from pipeline_exec.segment_pool import SegmentPool
from pipeline_exec.sink_agg import AggSink
from pipeline_exec.sink_group_agg import GroupAggSink
from plan_expr.agg_expr import AGG_MEAN, AGG_SUM, AggExpr
from plan_expr.expr import Expr
from scalar_arithmetic.decimal_arith import I128


# Row values: 1 true, 0 false, -1 NULL.
comptime _T = 1
comptime _F = 0
comptime _N = -1


def _over_cast(func: UInt8, to: DType) -> AggExpr:
    return AggExpr(func, Optional(Expr.cast(Expr.col_ref("b"), to)), None)


def _bool_batch(ref rows: List[Int]) raises -> RecordBatch:
    var b = ColumnBuilder[DType.bool].with_capacity(len(rows))
    for i in range(len(rows)):
        if rows[i] == _N:
            b.append_null()
        else:
            b.append(rows[i] == _T)
    var sb = SchemaBuilder()
    sb.add_field(Field("b", ArrowType.BOOL, True))
    var rb = RecordBatchBuilder()
    rb.add_column(b^.materialize())
    return rb.build(sb.build())


def _sum_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field.decimal128("s", 38, 0, True))
    return sb.build()


def _avg_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("m", ArrowType.FLOAT64, True))
    return sb.build()


def _fold(
    var agg: AggExpr, var schema: Schema, ref deal: List[List[Int]]
) raises -> RecordBatch:
    """The one-row aggregate of `agg` over `deal[w]` folded by worker `w`; an
    empty `deal[w]` sends that worker no morsel."""
    var data = ungrouped_agg_data(agg_list(agg^), schema^)
    var sink = AggSink(data, SegmentPool(), 0)
    sink.resize_worker_state(len(deal))
    for w in range(len(deal)):
        if len(deal[w]) > 0:
            sink.consume(w, Morsel(_bool_batch(deal[w]), w, 0))
    var pipeline = PipelineExecution(len(deal), 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _sum(to: DType, ref deal: List[List[Int]]) raises -> RecordBatch:
    return _fold(_over_cast(AGG_SUM, to), _sum_schema(), deal)


def _avg(to: DType, ref deal: List[List[Int]]) raises -> RecordBatch:
    return _fold(_over_cast(AGG_MEAN, to), _avg_schema(), deal)


def _sum_value(ref out: RecordBatch) raises -> I128:
    return out.column_at(0).as_decimal128().get_i128(0)


def _avg_value(ref out: RecordBatch) raises -> Float64:
    return out.column_at(0).as_primitive[DType.float64]().get(0)


def test_sum_of_cast_bool_counts_the_trues_over_several_workers() raises:
    var deal: List[List[Int]] = [[_T, _F, _N, _T], [_T, _T, _F]]
    for to in [DType.int64, DType.int32]:
        var out = _sum(to, deal)
        assert_equal(out.num_rows(), 1)
        assert_equal(out.column_at(0).decimal_precision(), 38)
        assert_equal(out.column_at(0).decimal_scale(), 0)
        assert_true(not out.column_at(0).is_null_at(0))
        assert_true(_sum_value(out) == I128(4), String(to))


def test_avg_of_cast_bool_is_the_share_of_trues() raises:
    var deal: List[List[Int]] = [[_T, _F, _N, _T]]
    for to in [DType.int64, DType.float64]:
        var out = _avg(to, deal)
        assert_true(not out.column_at(0).is_null_at(0))
        assert_equal(_avg_value(out), Float64(2.0) / Float64(3.0), String(to))


def test_only_false_rows_sum_to_zero_and_average_zero() raises:
    var deal: List[List[Int]] = [[_F, _F], [_F]]
    var s = _sum(DType.int64, deal)
    assert_true(not s.column_at(0).is_null_at(0))
    assert_true(_sum_value(s) == I128(0))
    var m = _avg(DType.float64, deal)
    assert_true(not m.column_at(0).is_null_at(0))
    assert_equal(_avg_value(m), Float64(0.0))


def test_only_null_rows_and_no_rows_give_null() raises:
    var all_null: List[List[Int]] = [[_N, _N], [_N]]
    var no_rows: List[List[Int]] = [[], []]
    assert_true(_sum(DType.int64, all_null).column_at(0).is_null_at(0))
    assert_true(_avg(DType.float64, all_null).column_at(0).is_null_at(0))
    var s = _sum(DType.int64, no_rows)
    assert_equal(s.num_rows(), 1)
    assert_true(s.column_at(0).is_null_at(0))
    assert_true(_avg(DType.int64, no_rows).column_at(0).is_null_at(0))


def _group_batch(ref keys: List[Int64], ref rows: List[Int]) raises -> RecordBatch:
    var k = ColumnBuilder[DType.int64].with_capacity(len(keys))
    var b = ColumnBuilder[DType.bool].with_capacity(len(rows))
    for i in range(len(keys)):
        k.append(keys[i])
        if rows[i] == _N:
            b.append_null()
        else:
            b.append(rows[i] == _T)
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    rb.add_column(k^.materialize())
    sb.add_field(Field("b", ArrowType.BOOL, True))
    rb.add_column(b^.materialize())
    return rb.build(sb.build())


def test_a_grouped_sum_of_cast_bool_counts_the_trues_per_group() raises:
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref("k"))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field.decimal128("s", 38, 0, True))
    var sink = GroupAggSink(
        grouped_agg_data(keys^, agg_list(_over_cast(AGG_SUM, DType.int64)), sb.build()),
        KEY_DTYPE_I64,
        SegmentPool(),
        0,
    )
    sink.resize_worker_state(2)
    # Key 1: true, false, true, NULL -> 2. Key 2: false, false -> 0.
    # Key 3: true -> 1. The rows of key 1 are split over both workers.
    var k0: List[Int64] = [Int64(1), Int64(2), Int64(1), Int64(3)]
    var r0: List[Int] = [_T, _F, _F, _T]
    var k1: List[Int64] = [Int64(1), Int64(2), Int64(1)]
    var r1: List[Int] = [_T, _F, _N]
    sink.consume(0, Morsel(_group_batch(k0, r0), 0, 0))
    sink.consume(1, Morsel(_group_batch(k1, r1), 1, 0))
    var pipeline = PipelineExecution(2, 0)
    sink.combine(pipeline)
    sink.finalize()
    var out = sink.take_output()
    assert_equal(out.num_rows(), 3)
    var got_keys = out.column_at(0).as_primitive[DType.int64]()
    var sums = out.column_at(1).as_decimal128()
    for r in range(3):
        var key = got_keys.get(r)
        var want = I128(2) if key == Int64(1) else (
            I128(0) if key == Int64(2) else I128(1)
        )
        assert_true(sums.get_i128(r) == want, "group " + String(key))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
