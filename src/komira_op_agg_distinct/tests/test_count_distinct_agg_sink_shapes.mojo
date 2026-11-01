# =============================================================================
# CountDistinctAggSink — the plan shapes it accepts and the ones it refuses
# =============================================================================
#
# `init_local` checks the shape of the plan before any batch is consumed, so a
# plan outside the sink's envelope fails loudly instead of producing a batch
# whose columns disagree with the declared schema. Each test builds one plan
# and asserts what `init_local` does with it.
#
# What each test asserts:
#   * two group keys raise;
#   * a group key declared as neither INT32 nor INT64 raises;
#   * an aggregate function outside COUNT(DISTINCT) / SUM / COUNT / MIN / MAX /
#     MEAN raises;
#   * a SUM / COUNT / MIN / MAX / MEAN beside COUNT(DISTINCT) without a group
#     key raises;
#   * an output schema whose field count is not the key and aggregate count
#     raises;
#   * a MEAN declared INT64, a COUNT declared FLOAT64 and a MIN declared
#     STRING raise;
#   * the supported grouped shapes, INT32 and INT64 keys, are accepted.
# =============================================================================

from std.testing import TestSuite, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, SchemaBuilder
from komira_collections.slab import Slab
from komira_physical_plan.physical_plan import (
    AggSinkData,
    MorselOp,
    ParquetSourceData,
)
from komira_plan_expr.agg_expr import (
    count,
    count_distinct,
    first,
    max,
    mean,
    min,
    sum,
)
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import AggExprArray, ExprArray

from komira_op_agg_distinct.agg_sink_count_distinct import (
    CountDistinctAggSink,
)


def _pq() raises -> ParquetSourceData:
    return ParquetSourceData(
        String(""), Optional[List[String]](None), Optional[Expr](None)
    )


def _sink(
    var group_by: ExprArray, var aggs: AggExprArray, var fields: List[Field]
) raises -> CountDistinctAggSink:
    var osb = SchemaBuilder()
    for i in range(len(fields)):
        osb.add_field(fields[i].copy())
    return CountDistinctAggSink.new(
        AggSinkData(group_by^, aggs^, osb.build()), _pq(), Slab[MorselOp]()
    )


def _fields3(
    t0: ArrowType, t1: ArrowType, t2: ArrowType
) -> List[Field]:
    var fs = List[Field]()
    fs.append(Field("a", t0, True))
    fs.append(Field("b", t1, True))
    fs.append(Field("c", t2, True))
    return fs^


def test_two_group_keys_are_refused() raises:
    var gb = ExprArray()
    gb.append(col("k1").copy_expr())
    gb.append(col("k2").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")).alias("dv"))
    var sink = _sink(
        gb^, aggs^, _fields3(ArrowType.INT64, ArrowType.INT64, ArrowType.INT64)
    )
    with assert_raises(contains="at most one group key"):
        _ = sink.init_local()


def test_group_key_declared_float_is_refused() raises:
    var gb = ExprArray()
    gb.append(col("k").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")).alias("dv"))
    var fs = List[Field]()
    fs.append(Field("k", ArrowType.FLOAT64, False))
    fs.append(Field("dv", ArrowType.INT64, False))
    var sink = _sink(gb^, aggs^, fs^)
    with assert_raises(contains="group key must be INT32 or INT64"):
        _ = sink.init_local()


def test_unknown_aggregate_function_is_refused() raises:
    var gb = ExprArray()
    gb.append(col("k").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")).alias("dv"))
    aggs.append(first(col("v")).alias("fv"))
    var sink = _sink(
        gb^, aggs^, _fields3(ArrowType.INT64, ArrowType.INT64, ArrowType.INT64)
    )
    with assert_raises(contains="unsupported aggregate function"):
        _ = sink.init_local()


def test_fixed_aggregate_without_group_key_is_refused() raises:
    var gb = ExprArray()
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")).alias("dv"))
    aggs.append(sum(col("v")).alias("s"))
    var fs = List[Field]()
    fs.append(Field("dv", ArrowType.INT64, False))
    fs.append(Field("s", ArrowType.INT64, True))
    var sink = _sink(gb^, aggs^, fs^)
    with assert_raises(contains="need a group key"):
        _ = sink.init_local()


def test_output_schema_field_count_mismatch_is_refused() raises:
    var gb = ExprArray()
    gb.append(col("k").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")).alias("dv"))
    aggs.append(sum(col("v")).alias("s"))
    var fs = List[Field]()
    fs.append(Field("k", ArrowType.INT64, False))
    fs.append(Field("dv", ArrowType.INT64, False))
    var sink = _sink(gb^, aggs^, fs^)
    with assert_raises(contains="output schema has 2 fields"):
        _ = sink.init_local()


def test_mean_declared_integer_is_refused() raises:
    var gb = ExprArray()
    gb.append(col("k").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")).alias("dv"))
    aggs.append(mean(col("v")).alias("av"))
    var sink = _sink(
        gb^, aggs^, _fields3(ArrowType.INT64, ArrowType.INT64, ArrowType.INT64)
    )
    with assert_raises(contains="MEAN must be declared FLOAT64"):
        _ = sink.init_local()


def test_count_declared_float_is_refused() raises:
    var gb = ExprArray()
    gb.append(col("k").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")).alias("dv"))
    aggs.append(count().alias("c"))
    var sink = _sink(
        gb^,
        aggs^,
        _fields3(ArrowType.INT64, ArrowType.INT64, ArrowType.FLOAT64),
    )
    with assert_raises(contains="COUNT must be declared INT64"):
        _ = sink.init_local()


def test_min_declared_string_is_refused() raises:
    var gb = ExprArray()
    gb.append(col("k").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")).alias("dv"))
    aggs.append(min(col("s")).alias("mn"))
    var sink = _sink(
        gb^, aggs^, _fields3(ArrowType.INT64, ArrowType.INT64, ArrowType.STRING)
    )
    with assert_raises(contains="MIN / MAX must be declared"):
        _ = sink.init_local()


def _supported_grouped(key: ArrowType) raises -> CountDistinctAggSink:
    var gb = ExprArray()
    gb.append(col("k").copy_expr())
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")).alias("dv"))
    aggs.append(sum(col("v")).alias("s"))
    aggs.append(count().alias("c"))
    aggs.append(min(col("v")).alias("mn"))
    aggs.append(max(col("f")).alias("mx"))
    aggs.append(mean(col("f")).alias("av"))
    var fs = List[Field]()
    fs.append(Field("k", key, True))
    fs.append(Field("dv", ArrowType.INT64, False))
    fs.append(Field("s", ArrowType.INT64, True))
    fs.append(Field("c", ArrowType.INT64, False))
    fs.append(Field("mn", ArrowType.INT64, True))
    fs.append(Field("mx", ArrowType.FLOAT64, True))
    fs.append(Field("av", ArrowType.FLOAT64, True))
    return _sink(gb^, aggs^, fs^)


def test_supported_grouped_shapes_are_accepted() raises:
    var s64 = _supported_grouped(ArrowType.INT64)
    _ = s64.init_local()
    var s32 = _supported_grouped(ArrowType.INT32)
    _ = s32.init_local()


def test_ungrouped_count_distinct_only_is_accepted() raises:
    var gb = ExprArray()
    var aggs = AggExprArray()
    aggs.append(count_distinct(col("v")).alias("a"))
    aggs.append(count_distinct(col("w")).alias("b"))
    var fs = List[Field]()
    fs.append(Field("a", ArrowType.INT64, False))
    fs.append(Field("b", ArrowType.INT64, False))
    var sink = _sink(gb^, aggs^, fs^)
    _ = sink.init_local()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
