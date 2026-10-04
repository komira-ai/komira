# =============================================================================
# `Expr.write_to` IS plan identity: `LogicalPlan.structural_hash` hashes the
# plan render and EngineContext caches compiled plans on it. Two expressions
# that differ must render differently.
# =============================================================================
#
# If they render the same, a second query reuses the first query's compiled
# plan: `sum(v).over("k")` after `sum(v).over("g")`, `row_number().over(g, [k],
# DESC)` after the same ASC, order key `x` after `k`, and `when(v > 8, 1, 0)`
# after `when(v > 5, 1, 0)` each answer the FIRST query's values when run in
# ONE EngineContext. A render-level unit test is the cheap falsifier; an
# end-to-end window-plan-cache identity test is the SDK-level one.
#
# ★ CAST, same class: `CAST(x AS DECIMAL(10, 2))` vs `DECIMAL(12, 4)`, and
# `TRY_CAST` vs `CAST`, must render DIFFERENTLY -- a render that prints the
# DType alone makes them equal.
# =============================================================================

from std.testing import TestSuite, assert_true
from komira_plan_expr.expr import Expr, BIN_GT
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.col_expr import col, when_then_else
from komira_plan_expr.partition_frame import PartitionFrame


def _i(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int64(Int64(v)))


def _r(e: Expr) -> String:
    var s = String("")
    e.write_to(s)
    return s


def test_window_partition_key_is_rendered() raises:
    assert_true(_r(col("v").sum().over("g")) != _r(col("v").sum().over("k")))


def test_window_order_direction_is_rendered() raises:
    var pa: List[String] = ["g"]
    var oa: List[String] = ["k"]
    var da: List[Bool] = [False]
    var pb: List[String] = ["g"]
    var ob: List[String] = ["k"]
    var db: List[Bool] = [True]
    assert_true(
        _r(col("k").row_number().over(pa^, oa^, da^))
        != _r(col("k").row_number().over(pb^, ob^, db^))
    )


def test_window_order_key_is_rendered() raises:
    var pa: List[String] = ["g"]
    var oa: List[String] = ["k"]
    var pb: List[String] = ["g"]
    var ob: List[String] = ["x"]
    assert_true(
        _r(col("k").row_number().over(pa^, oa^))
        != _r(col("k").row_number().over(pb^, ob^))
    )


def test_when_condition_is_rendered() raises:
    var a = when_then_else(Expr.binary(BIN_GT, Expr.col_ref("v"), _i(5)), _i(1), _i(0))
    var b = when_then_else(Expr.binary(BIN_GT, Expr.col_ref("v"), _i(8)), _i(1), _i(0))
    assert_true(_r(a) != _r(b))


def test_when_default_is_rendered() raises:
    var a = when_then_else(Expr.binary(BIN_GT, Expr.col_ref("v"), _i(5)), _i(1), _i(0))
    var b = when_then_else(Expr.binary(BIN_GT, Expr.col_ref("v"), _i(5)), _i(1), _i(2))
    assert_true(_r(a) != _r(b))


def test_in_list_values_are_rendered() raises:
    var a: List[Int] = [7, 0]
    var b: List[Int] = [10, 0]
    assert_true(_r(col("v").is_in(a)) != _r(col("v").is_in(b)))


def test_cast_decimal_precision_and_scale_are_rendered() raises:
    var a = Expr.cast_from_parts(
        Expr.col_ref("v"), DType.float64, ArrowType.DECIMAL128, 10, 2, False
    )
    var b = Expr.cast_from_parts(
        Expr.col_ref("v"), DType.float64, ArrowType.DECIMAL128, 12, 4, False
    )
    assert_true(_r(a) != _r(b), _r(a))


def test_try_cast_is_rendered() raises:
    var a = Expr.cast(Expr.col_ref("v"), DType.int32)
    var b = Expr.try_cast(Expr.col_ref("v"), DType.int32)
    assert_true(_r(a) != _r(b), _r(b))


def test_a_plain_cast_renders_as_before_the_control() raises:
    assert_true(_r(Expr.cast(Expr.col_ref("v"), DType.int32)) == "Cast(ColRef(v), int32)")


def test_the_same_expression_renders_the_same_the_control() raises:
    assert_true(_r(col("v").sum().over("g")) == _r(col("v").sum().over("g")))


def test_an_EXPR_IN_LIST_nodes_values_are_rendered() raises:
    # `col(v).is_in([..])` folds to an OR chain (<= 64 values), so the test
    # above never reaches the EXPR_IN_LIST arm (dropping the values from that
    # arm would leave every other case green). Build the node.
    var a = List[ScalarValue]()
    a.append(ScalarValue.from_int64(7))
    var b = List[ScalarValue]()
    b.append(ScalarValue.from_int64(10))
    assert_true(
        _r(Expr.in_list_node(Expr.col_ref("v"), a^))
        != _r(Expr.in_list_node(Expr.col_ref("v"), b^))
    )


def test_window_frame_is_rendered() raises:
    # Same func / column / offset / keys, frames differ (whole vs ordered
    # default): only the frame can tell them apart.
    var pa: List[String] = ["g"]
    var oa: List[String] = ["k"]
    var pb: List[String] = ["g"]
    var ob: List[String] = ["k"]
    var a = Expr.window_fn(
        UInt8(20), String("v"), 0, PartitionFrame.default_unordered()
    ).over(pa^, oa^)
    var b = Expr.window_fn(
        UInt8(20), String("v"), 0, PartitionFrame.default_ordered()
    ).over(pb^, ob^)
    assert_true(_r(a) != _r(b), _r(a))

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
