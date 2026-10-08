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

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal

from komira_arrow.schema import SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType

from komira_plan_expr.expr import Expr, BIN_LE, BIN_GE, BIN_GT
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    JOIN_INNER,
    JOIN_ALGO_AUTO,
    PLAN_FILTER,
    PLAN_JOIN,
    PLAN_PARTITION_BY,
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


# =============================================================================
# A PartitionBy or PartitionTopN above the fused Filter
# =============================================================================


def _fusable(rk: String, var pb: LogicalPlan) -> LogicalPlan:
    """`Filter(rk <= 3)` over `pb`."""
    return LogicalPlan.filter(_cmp(BIN_LE, rk, 3), pb^)


def _outer_pb(
    var pk: List[String], var ok: List[String], arg: String,
    var child: LogicalPlan,
) raises -> LogicalPlan:
    """PartitionBy(pk; ok ASC; running_sum(arg) AS rs) over `child`."""
    var desc = List[Bool]()
    for _ in range(len(ok)):
        desc.append(False)
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.running_sum(arg).with_alias(String("rs")))
    return LogicalPlan.partition_by(pk^, ok^, desc^, exprs^, child^)


def test_outer_partition_by_keyed_on_the_rank_emits_it() raises:
    """`PartitionBy(PARTITION BY rk)` over the fusable Filter. Catches the
    PartitionBy arm skipping its own partition keys."""
    var pb = _rank_pb()
    var rk = _win(pb)
    var pk: List[String] = [rk.copy()]
    var ok: List[String] = ["score"]
    var plan = _outer_pb(pk^, ok^, "val", _fusable(rk, pb^))
    var out = fuse_partition_topn(plan^)
    assert_equal(Int(out.tag), Int(PLAN_PARTITION_BY))
    _assert_emits(out._partition_by.value()[].child[], rk, "partition key")


def test_outer_partition_by_ordered_on_the_rank_emits_it() raises:
    """`PartitionBy(PARTITION BY pid ORDER BY rk)` over the fusable Filter.
    Catches the PartitionBy arm skipping its own order keys."""
    var pb = _rank_pb()
    var rk = _win(pb)
    var pk: List[String] = ["pid"]
    var ok: List[String] = [rk.copy()]
    var plan = _outer_pb(pk^, ok^, "val", _fusable(rk, pb^))
    var out = fuse_partition_topn(plan^)
    assert_equal(Int(out.tag), Int(PLAN_PARTITION_BY))
    _assert_emits(out._partition_by.value()[].child[], rk, "order key")


def test_outer_partition_by_summing_the_rank_emits_it() raises:
    """`PartitionBy(... running_sum(rk))` over the fusable Filter. Catches
    the PartitionBy arm skipping its partition expressions' argument
    column."""
    var pb = _rank_pb()
    var rk = _win(pb)
    var pk: List[String] = ["pid"]
    var ok: List[String] = ["score"]
    var plan = _outer_pb(pk^, ok^, rk, _fusable(rk, pb^))
    var out = fuse_partition_topn(plan^)
    assert_equal(Int(out.tag), Int(PLAN_PARTITION_BY))
    _assert_emits(out._partition_by.value()[].child[], rk, "argument")


def test_outer_partition_topn_keyed_on_the_rank_emits_it() raises:
    """`PartitionTopN(PARTITION BY rk)` over the fusable Filter. Catches
    the PartitionTopN arm skipping its own partition keys."""
    var pb = _rank_pb()
    var rk = _win(pb)
    var pk: List[String] = [rk.copy()]
    var sk: List[String] = ["score"]
    var desc: List[Bool] = [False]
    var plan = LogicalPlan.partition_topn(pk^, sk^, desc^, 2, _fusable(rk, pb^))
    var out = fuse_partition_topn(plan^)
    assert_equal(Int(out.tag), Int(PLAN_PARTITION_TOPN))
    _assert_emits(out._partition_topn.value()[].child[], rk, "topn partition key")


def test_outer_partition_topn_sorted_on_the_rank_emits_it() raises:
    """`PartitionTopN(PARTITION BY pid ORDER BY rk)` over the fusable
    Filter. Catches the PartitionTopN arm skipping its own sort keys."""
    var pb = _rank_pb()
    var rk = _win(pb)
    var pk: List[String] = ["pid"]
    var sk: List[String] = [rk.copy()]
    var desc: List[Bool] = [False]
    var plan = LogicalPlan.partition_topn(pk^, sk^, desc^, 2, _fusable(rk, pb^))
    var out = fuse_partition_topn(plan^)
    assert_equal(Int(out.tag), Int(PLAN_PARTITION_TOPN))
    _assert_emits(out._partition_topn.value()[].child[], rk, "topn sort key")


# =============================================================================
# A Join whose residual predicate reads the window column
# =============================================================================


def _other_side() raises -> LogicalPlan:
    """An in-memory Scan(q INT64, w INT64)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("q", ArrowType.INT64, False))
    sb.add_field(Field("w", ArrowType.INT64, False))
    return LogicalPlan.scan(String("__other"), UInt8(3), sb.build())


def _residual(rk: String) -> Optional[OwnedPointer[Expr]]:
    """`rk > w`."""
    return Optional(
        OwnedPointer(Expr.binary(BIN_GT, Expr.col_ref(rk), Expr.col_ref("w")))
    )


def test_join_residual_on_the_rank_left_emits_it() raises:
    """`Join(on pid = q, residual rk > w)` with the fusable Filter on the
    left. Catches the Join arm adding only `left_on` / `right_on`."""
    var pb = _rank_pb()
    var rk = _win(pb)
    var lo: List[String] = ["pid"]
    var ro: List[String] = ["q"]
    var plan = LogicalPlan.join(
        _fusable(rk, pb^), _other_side(), lo^, ro^, JOIN_INNER,
        JOIN_ALGO_AUTO, _residual(rk),
    )
    var out = fuse_partition_topn(plan^)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    _assert_emits(out._join.value()[].left[], rk, "join left")


def test_join_residual_on_the_rank_right_emits_it() raises:
    """The same Join with the fusable Filter on the right. Catches a
    residual's columns reaching one side only."""
    var pb = _rank_pb()
    var rk = _win(pb)
    var lo: List[String] = ["q"]
    var ro: List[String] = ["pid"]
    var plan = LogicalPlan.join(
        _other_side(), _fusable(rk, pb^), lo^, ro^, JOIN_INNER,
        JOIN_ALGO_AUTO, _residual(rk),
    )
    var out = fuse_partition_topn(plan^)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    _assert_emits(out._join.value()[].right[], rk, "join right")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
