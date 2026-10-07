# =============================================================================
# fuse_partition_topn: ancestors that read the window column through a node
# other than the Filter the rule fuses.
# =============================================================================
#
# Each case puts a fusable `Filter(rk <= 3)` over `PartitionBy(RANK ... AS rk)`
# under an ancestor that still reads `rk` after fusion. The fused
# PartitionTopN must then emit `rk` (`output_rank_col_name` set), or the
# ancestor names a column its child no longer produces.
#
# Every plan is built in memory; no file is read.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_arrow.schema import SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType

from komira_plan_expr.expr import Expr, BIN_LE, BIN_GE
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_FILTER,
    PLAN_PARTITION_TOPN,
)

from komira_optimizer.optimizer_partition_topn import fuse_partition_topn


# =============================================================================
# Builders
# =============================================================================


def _rank_pb() raises -> LogicalPlan:
    """PartitionBy(RANK) PARTITION BY pid ORDER BY score DESC over an
    in-memory Scan(pid INT64, score FLOAT64, val INT64)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("pid", ArrowType.INT64, False))
    sb.add_field(Field("score", ArrowType.FLOAT64, False))
    sb.add_field(Field("val", ArrowType.INT64, False))
    var scan = LogicalPlan.scan(String("__test"), UInt8(3), sb.build())
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.rank())
    var pk: List[String] = ["pid"]
    var ok: List[String] = ["score"]
    var desc: List[Bool] = [True]
    return LogicalPlan.partition_by(pk^, ok^, desc^, exprs^, scan^)


def _win(plan: LogicalPlan) -> String:
    """The window column a PartitionBy appends (its last column)."""
    return plan.output_schema.field_name(plan.output_schema.num_columns() - 1)


def _cmp(op: UInt8, name: String, k: Int) -> Expr:
    """`col(name) <op> k` with an INT64 literal."""
    return Expr.binary(
        op, Expr.col_ref(name), Expr.literal(ScalarValue.from_int(k))
    )


def _assert_emits(plan: LogicalPlan, rk: String, what: String) raises:
    """`plan` is a fused PartitionTopN that emits `rk`."""
    assert_equal(Int(plan.tag), Int(PLAN_PARTITION_TOPN), what)
    ref name = plan._partition_topn.value()[].output_rank_col_name
    assert_equal(Bool(name), True, what + ": rank column not emitted")
    assert_equal(name.value(), rk, what)


# =============================================================================
# A Filter above the fused Filter
# =============================================================================


def test_outer_filter_on_the_rank_emits_it() raises:
    """`Filter(rk >= 2)` over `Filter(rk <= 3)` over `PartitionBy(RANK)`.
    The inner Filter fuses; the outer one reads rk, so the fused node must
    emit it. Catches the Filter arm passing its ancestors down without its
    own predicate columns when its child is not the PartitionBy it
    consumes."""
    var pb = _rank_pb()
    var rk = _win(pb)
    var inner = LogicalPlan.filter(_cmp(BIN_LE, rk, 3), pb^)
    var plan = LogicalPlan.filter(_cmp(BIN_GE, rk, 2), inner^)
    var out = fuse_partition_topn(plan^)
    assert_equal(Int(out.tag), Int(PLAN_FILTER))
    _assert_emits(out._filter.value()[].child[], rk, "inner filter")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
