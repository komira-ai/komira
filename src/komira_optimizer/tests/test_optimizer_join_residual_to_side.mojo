# =============================================================================
# TPC-H q13 join ON-residual-to-side pushdown guard
# =============================================================================
#
# Rule under test: `optimizer_filter.push_join_residual_to_side` — a JOIN whose
# ON clause carries a residual predicate `R` (its non-equi part, already lifted
# to plain joined-schema col-refs by `join_predicate_decompose`) has each
# single-side AND-conjunct of `R` lowered to a FILTER on the owning child, so a
# residual-carrying equi-join becomes a plain equi-join above a child filter.
#
# TPC-H q13: `customer LEFT JOIN orders ON c_custkey = o_custkey AND o_comment
# NOT LIKE '%special%requests%'`. The residual references only `o_comment`
# (orders = right/inner side), so it must lower to a FILTER on the orders scan —
# turning a residual join (the `NOT LIKE` evaluated per equi-candidate pair) into
# a plain LEFT equi-join over a pre-filtered orders side.
#
# FAILS ON PRE-RULE CODE: without `push_join_residual_to_side`, the residual
# stays on the JOIN node (`has_residual()` True) and the right child stays a
# bare SCAN. The guards below assert the residual is lowered off the join AND the right child
# is a FILTER. The LEFT left-only case is the load-bearing CORRECTNESS boundary:
# a left-only ON conjunct on a LEFT join is NOT a WHERE filter (an unmatched
# left row still null-extends), so it MUST stay on the residual — a rule that
# pushed it would silently drop preserved rows.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    Expr, UN_NOT, STR_LIKE, BIN_AND, BIN_GT,
)
from komira_plan_ir.logical_plan import (
    JOIN_INNER,
    JOIN_LEFT,
    LogicalPlan,
    PLAN_JOIN,
    PLAN_SCAN,
    SOURCE_PARQUET,
)
from komira_plan_ir.logical_plan import PLAN_FILTER, JOIN_ALGO_AUTO
from komira_plan_expr.scalar_value import ScalarValue
from komira_optimizer.optimizer_filter import push_join_residual_to_side
from std.memory import OwnedPointer


def _customer_schema() -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field("c_custkey", ArrowType.INT64, False))
    return b.build()


def _orders_schema() -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field("o_orderkey", ArrowType.INT64, False))
    b.add_field(Field("o_custkey", ArrowType.INT64, False))
    b.add_field(Field("o_comment", ArrowType.STRING, False))
    return b.build()


def _scan(path: String, var schema: Schema) -> LogicalPlan:
    var none_proj: Optional[List[String]] = None
    var none_filt: Optional[Expr] = None
    var none_rc: Optional[Int] = None
    return LogicalPlan.scan(
        path, SOURCE_PARQUET, schema^, none_proj^, none_filt^, none_rc^
    )


def _not_like_o_comment() -> Expr:
    # `o_comment NOT LIKE '%special%requests%'` — the q13 residual, right-only.
    return Expr.unary(
        UN_NOT,
        Expr.string_op(STR_LIKE, Expr.col_ref("o_comment"), "%special%requests%"),
    )


def _left_join_with_residual(var residual: Expr, join_type: UInt8) -> LogicalPlan:
    var customer = _scan("customer.parquet", _customer_schema())
    var orders = _scan("orders.parquet", _orders_schema())
    var lk = List[String]()
    lk.append("c_custkey")
    var rk = List[String]()
    rk.append("o_custkey")
    var res_opt = Optional[OwnedPointer[Expr]](OwnedPointer(residual^))
    return LogicalPlan.join(
        customer^, orders^, lk^, rk^, join_type, JOIN_ALGO_AUTO, res_opt^
    )


def test_left_join_right_only_residual_pushes_to_right_child() raises:
    """q13 shape: LEFT join whose ON residual (`o_comment NOT LIKE ...`)
    references only the right (orders) side. After the rule the residual is
    lowered off the join and the right child is a FILTER carrying it; the left
    (customer) child is untouched."""
    var plan = _left_join_with_residual(_not_like_o_comment(), JOIN_LEFT)
    plan = push_join_residual_to_side(plan^)

    assert_true(plan.is_join(), "top must stay a JOIN")
    ref jd = plan.join_data_ref()
    assert_true(
        not jd.has_residual(),
        "the right-only residual must be lowered OFF the join (plain equi-join)",
    )
    assert_equal(
        Int(jd.right[].tag),
        Int(PLAN_FILTER),
        "the right (orders) child must now be a FILTER carrying the NOT LIKE",
    )
    assert_equal(
        Int(jd.left[].tag),
        Int(PLAN_SCAN),
        "the left (customer) child must be untouched (a bare SCAN)",
    )


def test_left_join_left_only_residual_stays_on_residual() raises:
    """CORRECTNESS boundary: a LEFT join whose ON residual references only the
    LEFT (preserved) side MUST keep the conjunct on the residual — an unmatched
    left row still null-extends, so it is NOT a WHERE filter and must not be
    pushed to filter the left side (that would drop preserved rows)."""
    # `c_custkey > 100` — left-only conjunct on a LEFT join.
    var left_only = Expr.binary(BIN_GT, Expr.col_ref("c_custkey"), Expr.literal(ScalarValue.from_int(100)))
    var plan = _left_join_with_residual(left_only^, JOIN_LEFT)
    plan = push_join_residual_to_side(plan^)

    assert_true(plan.is_join(), "top must stay a JOIN")
    ref jd = plan.join_data_ref()
    assert_true(
        jd.has_residual(),
        "a LEFT-join LEFT-only ON conjunct must STAY on the residual (never"
        " pushed to filter the preserved side)",
    )
    assert_equal(
        Int(jd.left[].tag),
        Int(PLAN_SCAN),
        "the left child must be untouched (no FILTER wrapper)",
    )


def test_inner_join_both_side_conjuncts_push_to_owning_children() raises:
    """INNER variant: both a left-only (`c_custkey > 100`) and a right-only
    (`o_comment NOT LIKE ...`) ON conjunct push to their owning children (both
    children are 'inner' for INNER), leaving the join residual empty."""
    var left_only = Expr.binary(BIN_GT, Expr.col_ref("c_custkey"), Expr.literal(ScalarValue.from_int(100)))
    var combined = Expr.binary(BIN_AND, left_only^, _not_like_o_comment())
    var plan = _left_join_with_residual(combined^, JOIN_INNER)
    plan = push_join_residual_to_side(plan^)

    assert_true(plan.is_join(), "top must stay a JOIN")
    ref jd = plan.join_data_ref()
    assert_true(
        not jd.has_residual(),
        "both single-side conjuncts must lower off an INNER join's residual",
    )
    assert_equal(
        Int(jd.left[].tag),
        Int(PLAN_FILTER),
        "the left child must now be a FILTER (c_custkey > 100 pushed)",
    )
    assert_equal(
        Int(jd.right[].tag),
        Int(PLAN_FILTER),
        "the right child must now be a FILTER (NOT LIKE pushed)",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
