# =============================================================================
# SUM over an integer column, declared DECIMAL(38, 0)
# =============================================================================
#
# The cutter lowers SUM(CAST(<integer> AS DECIMAL(38, 0))) (the SQL integer
# sum) to SUM(<integer>) and leaves the declared output DECIMAL(38, 0). The
# sinks fold the integer column in 128 bits, as they always have, and write the
# total as a DECIMAL128 of the declared precision and scale instead of
# narrowing it to INT64. What these tests prove:
#
#   * a total past the INT64 range, positive and negative, over INT64 and over
#     INT32, with the rows dealt over several workers, is exact;
#   * the answers are the same values, and the same NULLs, as the unlowered
#     form SUM(CAST(col AS DECIMAL(38, 0))) gives over the same morsels (the
#     DECIMAL fold), including a column with NULLs, an all-NULL column and no
#     morsel at all;
#   * the grouped sink does the same per group;
#   * an integer sum is still refused by name when the declared output is a
#     DECIMAL of another scale, so the widened emit is exactly the HUGEINT
#     carrier DECIMAL(38, 0) and nothing looser.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.column_builder import ColumnBuilder
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    Schema,
    SchemaBuilder,
)
from komira_collections.slab import Slab
from komira_morsel.morsel import Morsel
from komira_morsel.pipeline_execution import PipelineExecution
from komira_physical_plan.physical_plan import KEY_DTYPE_I64
from komira_pipeline_exec.plan_harness import (
    agg_list,
    grouped_agg_data,
    ungrouped_agg_data,
)
from komira_pipeline_exec.segment_pool import SegmentPool
from komira_pipeline_exec.sink_agg import AggSink
from komira_pipeline_exec.sink_group_agg import GroupAggSink
from komira_plan_expr.agg_expr import AGG_SUM, AggExpr
from komira_plan_expr.expr import Expr
from komira_scalar_arithmetic.decimal_arith import I128


def _plain(col: String) -> AggExpr:
    return AggExpr(AGG_SUM, Optional(Expr.col_ref(col)), None)


def _cast(col: String) raises -> AggExpr:
    return AggExpr(
        AGG_SUM,
        Optional(Expr.cast_to_decimal(Expr.col_ref(col), 38, 0)),
        None,
    )


def _hugeint_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field.decimal128("s", 38, 0, True))
    return sb.build()


def _int_batch(
    ref values: List[Int64], ref nulls: List[Bool], narrow: Bool
) raises -> RecordBatch:
    """One nullable column `v`: INT64, or INT32 when `narrow` (the values must
    then fit 32 bits)."""
    var rb = RecordBatchBuilder()
    var sb = SchemaBuilder()
    if narrow:
        var b = ColumnBuilder[DType.int32].with_capacity(len(values))
        for i in range(len(values)):
            if nulls[i]:
                b.append_null()
            else:
                b.append(Int32(values[i]))
        sb.add_field(Field("v", ArrowType.INT32, True))
        rb.add_column(b^.materialize())
    else:
        var b = ColumnBuilder[DType.int64].with_capacity(len(values))
        for i in range(len(values)):
            if nulls[i]:
                b.append_null()
            else:
                b.append(values[i])
        sb.add_field(Field("v", ArrowType.INT64, True))
        rb.add_column(b^.materialize())
    return rb.build(sb.build())


def _repeat(v: Int64, n: Int) -> List[Int64]:
    var out = List[Int64]()
    for _ in range(n):
        out.append(v)
    return out^


def _no_nulls(n: Int) -> List[Bool]:
    var out = List[Bool]()
    for _ in range(n):
        out.append(False)
    return out^


def _sum(
    var agg: AggExpr, ref deal: List[List[Int64]], narrow: Bool
) raises -> RecordBatch:
    """The one-row `SUM` of `agg` over `deal[w]` folded by worker `w`."""
    var data = ungrouped_agg_data(agg_list(agg^), _hugeint_schema())
    var sink = AggSink(data, SegmentPool(), 0)
    sink.resize_worker_state(len(deal))
    for w in range(len(deal)):
        sink.consume(
            w,
            Morsel(
                _int_batch(deal[w], _no_nulls(len(deal[w])), narrow), w, 0
            ),
        )
    var pipeline = PipelineExecution(len(deal), 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _value(ref out: RecordBatch) raises -> I128:
    return out.column_at(0).as_decimal128().get_i128(0)


def _three_workers_of(v: Int64) -> List[List[Int64]]:
    var deal = List[List[Int64]]()
    for _ in range(3):
        deal.append(_repeat(v, 4))
    return deal^


def test_int64_max_rows_sum_past_int64_exactly() raises:
    var deal = _three_workers_of(Int64.MAX)
    var out = _sum(_plain("v"), deal, False)
    assert_equal(out.column_at(0).decimal_precision(), 38)
    assert_equal(out.column_at(0).decimal_scale(), 0)
    assert_true(_value(out) == I128(12) * I128(Int(Int64.MAX)))


def test_int64_min_rows_sum_past_int64_exactly() raises:
    var deal = _three_workers_of(Int64.MIN)
    var out = _sum(_plain("v"), deal, False)
    assert_true(_value(out) == I128(12) * I128(Int(Int64.MIN)))


def test_int32_rows_sum_past_int32_and_int64_exactly() raises:
    var deal = List[List[Int64]]()
    for _ in range(2):
        deal.append(_repeat(Int64(Int32.MAX), 5))
    var out = _sum(_plain("v"), deal, True)
    assert_true(_value(out) == I128(10) * I128(Int(Int32.MAX)))


def test_the_integer_fold_equals_the_decimal_fold_over_the_same_morsels() raises:
    var deal = List[List[Int64]]()
    deal.append(_repeat(Int64.MAX, 3))
    deal.append(_repeat(Int64.MIN, 2))
    deal.append(_repeat(Int64(7), 1))
    var plain = _sum(_plain("v"), deal, False)
    var cast = _sum(_cast("v"), deal, False)
    assert_true(_value(plain) == _value(cast))
    # 3 * MAX + 2 * MIN + 7, computed in 128 bits.
    var want = I128(3) * I128(Int(Int64.MAX)) + I128(2) * I128(
        Int(Int64.MIN)
    ) + I128(7)
    assert_true(_value(plain) == want)


def _sum_with_nulls(
    var agg: AggExpr, narrow: Bool, all_null: Bool, no_morsel: Bool
) raises -> RecordBatch:
    var data = ungrouped_agg_data(agg_list(agg^), _hugeint_schema())
    var sink = AggSink(data, SegmentPool(), 0)
    sink.resize_worker_state(2)
    if not no_morsel:
        var values = List[Int64]()
        var nulls = List[Bool]()
        for i in range(6):
            values.append(Int64(i) + Int64(1))
            nulls.append(all_null or i % 2 == 0)
        sink.consume(0, Morsel(_int_batch(values, nulls, narrow), 0, 0))
    var pipeline = PipelineExecution(2, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def test_nulls_are_skipped_and_all_null_and_empty_are_null_in_both_forms() raises:
    for narrow in range(2):
        # Rows 1, 3, 5 are non-NULL: 2 + 4 + 6.
        var some_plain = _sum_with_nulls(_plain("v"), narrow == 1, False, False)
        var some_cast = _sum_with_nulls(_cast("v"), narrow == 1, False, False)
        assert_true(not some_plain.column_at(0).is_null_at(0))
        assert_true(_value(some_plain) == I128(12))
        assert_true(_value(some_cast) == I128(12))
        var nil_plain = _sum_with_nulls(_plain("v"), narrow == 1, True, False)
        var nil_cast = _sum_with_nulls(_cast("v"), narrow == 1, True, False)
        assert_true(nil_plain.column_at(0).is_null_at(0))
        assert_true(nil_cast.column_at(0).is_null_at(0))
    var none_plain = _sum_with_nulls(_plain("v"), False, False, True)
    var none_cast = _sum_with_nulls(_cast("v"), False, False, True)
    assert_equal(none_plain.num_rows(), 1)
    assert_true(none_plain.column_at(0).is_null_at(0))
    assert_true(none_cast.column_at(0).is_null_at(0))


def test_an_integer_sum_declared_with_another_scale_is_refused() raises:
    var sb = SchemaBuilder()
    sb.add_field(Field.decimal128("s", 38, 2, True))
    var data = ungrouped_agg_data(agg_list(_plain("v")), sb.build())
    var sink = AggSink(data, SegmentPool(), 0)
    sink.resize_worker_state(1)
    var values = _repeat(Int64(1), 2)
    sink.consume(
        0, Morsel(_int_batch(values, _no_nulls(2), False), 0, 0)
    )
    var pipeline = PipelineExecution(1, 0)
    sink.combine(pipeline)
    sink.finalize()
    with assert_raises(contains="cannot fill the declared output type"):
        _ = sink.take_output()


def _group_batch(
    ref keys: List[Int64], ref values: List[Int64]
) raises -> RecordBatch:
    var k = ColumnBuilder[DType.int64].with_capacity(len(keys))
    var v = ColumnBuilder[DType.int64].with_capacity(len(keys))
    for i in range(len(keys)):
        k.append(keys[i])
        v.append(values[i])
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    rb.add_column(k^.materialize())
    sb.add_field(Field("v", ArrowType.INT64, True))
    rb.add_column(v^.materialize())
    return rb.build(sb.build())


def _grouped(var agg: AggExpr) raises -> RecordBatch:
    var keys = Slab[Expr]()
    keys.append(Expr.col_ref("k"))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field.decimal128("s", 38, 0, True))
    var sink = GroupAggSink(
        grouped_agg_data(keys^, agg_list(agg^), sb.build()),
        KEY_DTYPE_I64,
        SegmentPool(),
        0,
    )
    sink.resize_worker_state(3)
    # Key 1: four MAX in each of three workers. Key 2: two MAX in worker 0 and
    # two MIN in worker 1, which cancel to -2.
    for w in range(3):
        sink.consume(
            w,
            Morsel(
                _group_batch(_repeat(Int64(1), 4), _repeat(Int64.MAX, 4)),
                w,
                0,
            ),
        )
    sink.consume(
        0,
        Morsel(_group_batch(_repeat(Int64(2), 2), _repeat(Int64.MAX, 2)), 3, 0),
    )
    sink.consume(
        1,
        Morsel(_group_batch(_repeat(Int64(2), 2), _repeat(Int64.MIN, 2)), 4, 0),
    )
    var pipeline = PipelineExecution(3, 0)
    sink.combine(pipeline)
    sink.finalize()
    return sink.take_output()


def _sum_of_key(ref out: RecordBatch, key: Int) raises -> I128:
    var keys = out.column_at(0).as_primitive[DType.int64]()
    for r in range(out.num_rows()):
        if keys.get(r) == Int64(key):
            return out.column_at(1).as_decimal128().get_i128(r)
    assert_true(False, "no group " + String(key))
    return I128(0)


def test_a_grouped_integer_sum_is_exact_per_group_and_equals_the_cast_form() raises:
    var plain = _grouped(_plain("v"))
    var cast = _grouped(_cast("v"))
    assert_equal(plain.num_rows(), 2)
    assert_equal(plain.column_at(1).decimal_precision(), 38)
    assert_equal(plain.column_at(1).decimal_scale(), 0)
    assert_true(_sum_of_key(plain, 1) == I128(12) * I128(Int(Int64.MAX)))
    assert_true(_sum_of_key(plain, 2) == I128(-2))
    assert_true(_sum_of_key(cast, 1) == _sum_of_key(plain, 1))
    assert_true(_sum_of_key(cast, 2) == _sum_of_key(plain, 2))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
