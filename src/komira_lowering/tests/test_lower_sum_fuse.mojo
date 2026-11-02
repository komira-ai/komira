# =============================================================================
# test_lower_sum_fuse: which integer sums are lowered to the 128-bit integer fold
# =============================================================================
#
# SQL `sum()` over an integer is bound as SUM(CAST(<integer expr> AS
# DECIMAL(38, 0))). The cutter lowers that exact shape to SUM(<integer expr>)
# in the sink's data, so the sink folds the integer column in 128 bits without
# first writing a DECIMAL128 column; the node's declared output stays
# DECIMAL(38, 0). Each test lowers a plan and reads the aggregate list the sink
# will be built from:
#
#   * a signed integer column, an integer expression and an INT32 column are
#     fused, and the declared output type is unchanged;
#   * a cast to another scale or precision, a TRY_CAST, a cast of a FLOAT64, a
#     DECIMAL128 or an unsigned column, a cast to another type, a plain SUM and
#     a SUM of a COUNT-style argument-less aggregate are not touched;
#   * grouped aggregates are fused too, and an aggregate list mixing fused and
#     untouched sums keeps its order and its output names.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.dtype_sentinel import DTYPE_NONE
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_host_profile.host_profile import HostProfile, reference_host_profile
from komira_lowering.lower import lower
from komira_lowering.lowered_plan import LoweredPlan, LoweringInputs
from komira_physical_plan.physical_plan import AggSinkData
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT, AGG_SUM
from komira_plan_expr.expr import (
    Expr,
    EXPR_BINARY_OP,
    EXPR_CAST,
    EXPR_COL_REF,
    BIN_ADD,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
)
from komira_plan_stats.table_stats import (
    ColumnStats,
    TableStats,
    STATS_SOURCE_PARQUET_METADATA,
)


def _table() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    sb.add_field(Field("big", ArrowType.INT64, True))
    sb.add_field(Field("mid", ArrowType.INT32, True))
    sb.add_field(Field("small", ArrowType.INT8, True))
    sb.add_field(Field("unsigned", ArrowType.UINT32, True))
    sb.add_field(Field("price", ArrowType.FLOAT64, True))
    sb.add_field(Field.decimal128("dec", 10, 0, True))
    return sb.build()


def _scan() raises -> LogicalPlan:
    return LogicalPlan.scan(
        String("t.parquet"),
        SOURCE_PARQUET,
        _table(),
        Optional[List[String]](),
        Optional[Expr](),
    )


def _inputs() -> LoweringInputs:
    var inputs = LoweringInputs()
    inputs.add_scan(
        Optional[TableStats](
            TableStats(
                1000,
                List[String](),
                List[ColumnStats](),
                STATS_SOURCE_PARQUET_METADATA,
            )
        )
    )
    return inputs^


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _hugeint_sum(var arg: Expr, name: String) raises -> AggExpr:
    return AggExpr(
        AGG_SUM,
        Optional[Expr](Expr.cast_to_decimal(arg^, 38, 0)),
        Optional[String](name),
    )


def _lower_agg(
    var aggs: AggExprArray, var keys: ExprArray
) raises -> LoweredPlan:
    var plan = LogicalPlan.aggregate(keys^, aggs^, _scan())
    return lower(plan, reference_host_profile("test-build"), _inputs())


def _lower_ungrouped(var aggs: AggExprArray) raises -> LoweredPlan:
    return _lower_agg(aggs^, ExprArray())


def _is_col(ref agg: AggExpr, name: String) -> Bool:
    return (
        Bool(agg.child)
        and agg.child.value().tag == EXPR_COL_REF
        and agg.child.value().col_ref_name() == name
    )


def _is_cast(ref agg: AggExpr) -> Bool:
    return Bool(agg.child) and agg.child.value().tag == EXPR_CAST


def test_a_hugeint_sum_of_an_int64_column_is_lowered_to_the_integer_fold() raises:
    var aggs = AggExprArray()
    aggs.append(_hugeint_sum(_col("big"), "s"))
    var lowered = _lower_ungrouped(aggs^)
    assert_equal(len(lowered.params.agg[0].agg_exprs), 1)
    ref data = lowered.params.agg[0]
    assert_true(data.agg_exprs[0].func == AGG_SUM)
    assert_true(_is_col(data.agg_exprs[0], "big"), "the cast is stripped")
    # The declared output is still DECIMAL(38, 0): the sink widens at its emit.
    assert_equal(data.output_schema.field_arrow_type(0), ArrowType.DECIMAL128)
    assert_equal(data.output_schema.field_decimal_precision(0), 38)
    assert_equal(data.output_schema.field_decimal_scale(0), 0)
    assert_equal(
        String(data.agg_exprs[0].alias_name.value()), String("s")
    )


def test_int32_and_int8_columns_are_lowered_to_the_integer_fold() raises:
    var aggs = AggExprArray()
    aggs.append(_hugeint_sum(_col("mid"), "a"))
    aggs.append(_hugeint_sum(_col("small"), "b"))
    var lowered = _lower_ungrouped(aggs^)
    ref data = lowered.params.agg[0]
    assert_true(_is_col(data.agg_exprs[0], "mid"))
    assert_true(_is_col(data.agg_exprs[1], "small"))


def test_an_integer_expression_argument_is_lowered_and_kept_whole() raises:
    var aggs = AggExprArray()
    aggs.append(
        _hugeint_sum(
            Expr.binary(BIN_ADD, _col("mid"), _col("mid")), String("e")
        )
    )
    var lowered = _lower_ungrouped(aggs^)
    ref data = lowered.params.agg[0]
    assert_false(_is_cast(data.agg_exprs[0]))
    assert_true(data.agg_exprs[0].child.value().tag == EXPR_BINARY_OP)


def test_a_grouped_hugeint_sum_is_lowered_to_the_integer_fold() raises:
    var aggs = AggExprArray()
    aggs.append(_hugeint_sum(_col("big"), "s"))
    var keys = ExprArray()
    keys.append(_col("k"))
    var lowered = _lower_agg(aggs^, keys^)
    ref data = lowered.params.agg[0]
    assert_true(_is_col(data.agg_exprs[0], "big"))
    assert_equal(data.output_schema.field_arrow_type(1), ArrowType.DECIMAL128)


def test_a_cast_to_another_scale_or_precision_is_left_alone() raises:
    var aggs = AggExprArray()
    aggs.append(
        AggExpr(
            AGG_SUM,
            Optional[Expr](Expr.cast_to_decimal(_col("big"), 38, 2)),
            Optional[String]("scaled"),
        )
    )
    aggs.append(
        AggExpr(
            AGG_SUM,
            Optional[Expr](Expr.cast_to_decimal(_col("big"), 18, 0)),
            Optional[String]("narrow"),
        )
    )
    var lowered = _lower_ungrouped(aggs^)
    ref data = lowered.params.agg[0]
    assert_true(_is_cast(data.agg_exprs[0]), "DECIMAL(38, 2) is not fused")
    assert_true(_is_cast(data.agg_exprs[1]), "DECIMAL(18, 0) is not fused")


def test_a_try_cast_is_left_alone() raises:
    var aggs = AggExprArray()
    var c = Expr.cast_from_parts(
        _col("big"),
        DTYPE_NONE,
        ArrowType.DECIMAL128,
        38,
        0,
        True,
    )
    aggs.append(AggExpr(AGG_SUM, Optional[Expr](c^), Optional[String]("t")))
    var lowered = _lower_ungrouped(aggs^)
    assert_true(_is_cast(lowered.params.agg[0].agg_exprs[0]))


def test_a_cast_of_a_non_signed_integer_argument_is_left_alone() raises:
    var aggs = AggExprArray()
    aggs.append(_hugeint_sum(_col("price"), "f"))
    aggs.append(_hugeint_sum(_col("dec"), "d"))
    aggs.append(_hugeint_sum(_col("unsigned"), "u"))
    var lowered = _lower_ungrouped(aggs^)
    ref data = lowered.params.agg[0]
    assert_true(_is_cast(data.agg_exprs[0]), "FLOAT64 rounds on the cast")
    assert_true(_is_cast(data.agg_exprs[1]), "DECIMAL128 is not an integer")
    assert_true(_is_cast(data.agg_exprs[2]), "the sinks fold signed integers")


def test_a_cast_to_another_type_and_a_plain_sum_are_left_alone() raises:
    var aggs = AggExprArray()
    aggs.append(
        AggExpr(
            AGG_SUM,
            Optional[Expr](Expr.cast(_col("mid"), DType.int64)),
            Optional[String]("widened"),
        )
    )
    aggs.append(
        AggExpr(AGG_SUM, Optional[Expr](_col("big")), Optional[String]("plain"))
    )
    var lowered = _lower_ungrouped(aggs^)
    ref data = lowered.params.agg[0]
    assert_true(_is_cast(data.agg_exprs[0]), "a cast to INT64 stays")
    assert_true(_is_col(data.agg_exprs[1], "big"))


def test_a_cast_under_another_aggregate_function_is_left_alone() raises:
    var aggs = AggExprArray()
    aggs.append(
        AggExpr(
            AGG_COUNT,
            Optional[Expr](Expr.cast_to_decimal(_col("big"), 38, 0)),
            Optional[String]("n"),
        )
    )
    var lowered = _lower_ungrouped(aggs^)
    assert_true(_is_cast(lowered.params.agg[0].agg_exprs[0]))


def test_a_mixed_list_keeps_its_order_and_names() raises:
    var aggs = AggExprArray()
    aggs.append(_hugeint_sum(_col("big"), "first"))
    aggs.append(AggExpr(AGG_COUNT, Optional[Expr](), Optional[String]("n")))
    aggs.append(_hugeint_sum(_col("price"), "third"))
    aggs.append(_hugeint_sum(_col("mid"), "fourth"))
    var lowered = _lower_ungrouped(aggs^)
    ref data = lowered.params.agg[0]
    assert_equal(len(data.agg_exprs), 4)
    assert_true(_is_col(data.agg_exprs[0], "big"))
    assert_true(data.agg_exprs[1].func == AGG_COUNT)
    assert_true(_is_cast(data.agg_exprs[2]))
    assert_true(_is_col(data.agg_exprs[3], "mid"))
    assert_equal(String(data.agg_exprs[0].alias_name.value()), String("first"))
    assert_equal(String(data.agg_exprs[3].alias_name.value()), String("fourth"))
    assert_equal(data.output_schema.num_columns(), 4)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
