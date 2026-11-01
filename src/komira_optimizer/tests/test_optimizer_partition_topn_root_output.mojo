# =============================================================================
# fuse_partition_topn: a window column that reaches the plan's output
# =============================================================================
#
# The plan's root is a reader of every column it outputs. A fusable
# `Filter(rk <= K)` over `PartitionBy(ROW_NUMBER | RANK)` whose window column
# reaches the root without passing through a Project or an Aggregate that
# drops it must fuse into a PartitionTopN that emits the column
# (`output_rank_col_name` set). Otherwise the optimized plan answers with
# fewer columns than the query asked for (komira#1290).
#
# Each case puts the fusable Filter at the root or under one pass-through node
# (Filter, Limit, Sort, TopN, Distinct, Join, PartitionBy, PartitionTopN) whose
# own keys do not name the window column, and checks that the output schema
# (names, order, types) is the input's. Two controls (a Project and an
# Aggregate that drop the column) check that the column is still not emitted
# when nothing above reads it. The last case runs the whole driver
# (`optimize`, where `fuse_partition_topn` is step 19) on the plan from the
# issue.
#
# Every plan is built in memory; no file is read.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.schema import SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType

from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.expr import Expr, BIN_LE, BIN_GT
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.partition_expr import PartitionExpr, PF_ROW_NUMBER, PF_RANK
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    JOIN_INNER,
    PLAN_AGGREGATE,
    PLAN_DISTINCT,
    PLAN_FILTER,
    PLAN_JOIN,
    PLAN_LIMIT,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_SORT,
    PLAN_TOPN,
)

from komira_optimizer.optimizer_config import OptimizerConfig
from komira_optimizer.optimizer_driver import optimize
from komira_optimizer.optimizer_partition_topn import fuse_partition_topn
from komira_optimizer.optimizer_scalar_deps import ScalarDepTable


# =============================================================================
# Builders
# =============================================================================


def _pb(func: UInt8) raises -> LogicalPlan:
    """PartitionBy(func) PARTITION BY pid ORDER BY score DESC over an
    in-memory Scan(pid INT64, score FLOAT64, val INT64)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("pid", ArrowType.INT64, False))
    sb.add_field(Field("score", ArrowType.FLOAT64, False))
    sb.add_field(Field("val", ArrowType.INT64, False))
    var scan = LogicalPlan.scan(String("__test"), UInt8(3), sb.build())
    var exprs = List[PartitionExpr]()
    if func == PF_RANK:
        exprs.append(PartitionExpr.rank())
    else:
        exprs.append(PartitionExpr.row_number())
    var pk: List[String] = ["pid"]
    var ok: List[String] = ["score"]
    var desc: List[Bool] = [True]
    return LogicalPlan.partition_by(pk^, ok^, desc^, exprs^, scan^)


def _win(plan: LogicalPlan) -> String:
    """The window column a PartitionBy appends (its last column)."""
    return plan.output_schema.field_name(plan.output_schema.num_columns() - 1)


def _fusable(func: UInt8) raises -> LogicalPlan:
    """`Filter(win <= 3)` over `_pb(func)`: the shape the rule fuses."""
    var pb = _pb(func)
    var win = _win(pb)
    var pred = Expr.binary(
        BIN_LE, Expr.col_ref(win), Expr.literal(ScalarValue.from_int(3))
    )
    return LogicalPlan.filter(pred^, pb^)


def _sig(p: LogicalPlan) -> String:
    """`name:type_id;` per output column, in order."""
    var s = String("")
    for i in range(p.output_schema.num_columns()):
        s += p.output_schema.field_name(i) + ":"
        s += String(Int(p.output_schema.field_arrow_type(i).type_id)) + ";"
    return s


def _assert_emits(plan: LogicalPlan, win: String, what: String) raises:
    """`plan` is a fused PartitionTopN that emits `win`."""
    assert_equal(Int(plan.tag), Int(PLAN_PARTITION_TOPN), what)
    ref name = plan._partition_topn.value()[].output_rank_col_name
    assert_equal(Bool(name), True, what + ": window column not emitted")
    assert_equal(name.value(), win, what)


def _fuse_keeps_schema(var plan: LogicalPlan) raises -> LogicalPlan:
    """fuse_partition_topn(plan), checking that the output schema is the
    input's."""
    var want = _sig(plan)
    var out = fuse_partition_topn(plan^)
    assert_equal(_sig(out), want, "output schema changed by the fusion")
    return out^


# =============================================================================
# The fusable Filter at the root
# =============================================================================


def test_root_filter_keeps_the_row_number_column() raises:
    """`Filter(rn <= 3)` over `PartitionBy(ROW_NUMBER)` as the whole plan
    (komira#1290). Catches the ancestor walk starting from an empty set, so
    the root's own output never counts as a reader: the fused node then drops
    `rn` and the plan answers `pid, score, val`."""
    var win = _win(_pb(PF_ROW_NUMBER))
    var out = _fuse_keeps_schema(_fusable(PF_ROW_NUMBER))
    _assert_emits(out, win, "root filter, row_number")
    assert_equal(out._partition_topn.value()[].k, 3)


def test_root_filter_keeps_the_rank_column() raises:
    """The same plan with RANK. Catches a seed applied to the ROW_NUMBER
    path only."""
    var win = _win(_pb(PF_RANK))
    var out = _fuse_keeps_schema(_fusable(PF_RANK))
    _assert_emits(out, win, "root filter, rank")
    assert_equal(Int(out._partition_topn.value()[].func), Int(PF_RANK))


# =============================================================================
# Pass-through nodes at the root whose keys do not name the window column
# =============================================================================


def test_root_filter_on_another_column_keeps_it() raises:
    """`Filter(val > 0)` over the fusable Filter. Catches a seed applied only
    when the root is the fusable Filter itself."""
    var win = _win(_pb(PF_RANK))
    var pred = Expr.binary(
        BIN_GT, Expr.col_ref("val"), Expr.literal(ScalarValue.from_int(0))
    )
    var out = _fuse_keeps_schema(LogicalPlan.filter(pred^, _fusable(PF_RANK)))
    assert_equal(Int(out.tag), Int(PLAN_FILTER))
    _assert_emits(out._filter.value()[].child[], win, "under a filter")


def test_root_limit_keeps_it() raises:
    """`Limit 10` over the fusable Filter. Catches a seed that reaches only
    nodes that read columns (a Limit reads none and passes its set down)."""
    var win = _win(_pb(PF_RANK))
    var out = _fuse_keeps_schema(LogicalPlan.limit(10, _fusable(PF_RANK)))
    assert_equal(Int(out.tag), Int(PLAN_LIMIT))
    _assert_emits(out._limit.value()[].child[], win, "under a limit")


def test_root_sort_on_another_column_keeps_it() raises:
    """`Sort(pid)` over the fusable Filter. Catches a root seeded with its
    own keys instead of its output."""
    var win = _win(_pb(PF_RANK))
    var keys: List[String] = ["pid"]
    var desc: List[Bool] = [False]
    var out = _fuse_keeps_schema(LogicalPlan.sort(keys^, desc^, _fusable(PF_RANK)))
    assert_equal(Int(out.tag), Int(PLAN_SORT))
    _assert_emits(out._sort.value()[].child[], win, "under a sort")


def test_root_topn_on_another_column_keeps_it() raises:
    """`TopN(pid, 5)` over the fusable Filter."""
    var win = _win(_pb(PF_RANK))
    var keys: List[String] = ["pid"]
    var desc: List[Bool] = [False]
    var out = _fuse_keeps_schema(
        LogicalPlan.topn(keys^, desc^, 5, _fusable(PF_RANK))
    )
    assert_equal(Int(out.tag), Int(PLAN_TOPN))
    _assert_emits(out._topn.value()[].child[], win, "under a topn")


def test_root_distinct_on_another_column_keeps_it() raises:
    """`DISTINCT ON (pid)` over the fusable Filter: its output keeps every
    child column, the window column included."""
    var win = _win(_pb(PF_RANK))
    var cols: List[String] = ["pid"]
    var out = _fuse_keeps_schema(
        LogicalPlan.distinct(Optional[List[String]](cols^), _fusable(PF_RANK))
    )
    assert_equal(Int(out.tag), Int(PLAN_DISTINCT))
    _assert_emits(out._distinct.value()[].child[], win, "under a distinct")


def test_root_join_on_another_column_keeps_it() raises:
    """`Join(on pid = q)` with the fusable Filter on the left: the join
    outputs both sides' columns. Catches the Join arm's left input not
    inheriting from above."""
    var win = _win(_pb(PF_RANK))
    var sb = SchemaBuilder()
    sb.add_field(Field("q", ArrowType.INT64, False))
    sb.add_field(Field("w", ArrowType.INT64, False))
    var other = LogicalPlan.scan(String("__other"), UInt8(3), sb.build())
    var lo: List[String] = ["pid"]
    var ro: List[String] = ["q"]
    var out = _fuse_keeps_schema(
        LogicalPlan.join(_fusable(PF_RANK), other^, lo^, ro^, JOIN_INNER)
    )
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    _assert_emits(out._join.value()[].left[], win, "under a join")


def test_root_join_with_the_fusable_on_the_right_keeps_it() raises:
    """`Join(on q = pid)` with the fusable Filter on the right: the window
    column is the last of six root columns (`q, w, pid, score, val, rk`).
    Catches the Join arm giving its right input a set that does not inherit
    from above (only the keys and the residual), and a seed that takes only
    the root's first few columns."""
    var win = _win(_pb(PF_RANK))
    var sb = SchemaBuilder()
    sb.add_field(Field("q", ArrowType.INT64, False))
    sb.add_field(Field("w", ArrowType.INT64, False))
    var other = LogicalPlan.scan(String("__other"), UInt8(3), sb.build())
    var lo: List[String] = ["q"]
    var ro: List[String] = ["pid"]
    var plan = LogicalPlan.join(other^, _fusable(PF_RANK), lo^, ro^, JOIN_INNER)
    assert_equal(plan.output_schema.num_columns(), 6)
    assert_equal(plan.output_schema.field_name(5), win)
    var out = _fuse_keeps_schema(plan^)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    _assert_emits(out._join.value()[].right[], win, "right of a join")


def test_root_partition_by_on_other_columns_keeps_it() raises:
    """`PartitionBy(pid; score; running_sum(val))` over the fusable Filter:
    its output is its child's columns plus its own."""
    var win = _win(_pb(PF_RANK))
    var pk: List[String] = ["pid"]
    var ok: List[String] = ["score"]
    var desc: List[Bool] = [False]
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.running_sum("val").with_alias(String("rs")))
    var out = _fuse_keeps_schema(
        LogicalPlan.partition_by(pk^, ok^, desc^, exprs^, _fusable(PF_RANK))
    )
    assert_equal(Int(out.tag), Int(PLAN_PARTITION_BY))
    _assert_emits(out._partition_by.value()[].child[], win, "under a partition by")


def test_root_partition_topn_on_other_columns_keeps_it() raises:
    """`PartitionTopN(pid; score; k=2)` over the fusable Filter."""
    var win = _win(_pb(PF_RANK))
    var pk: List[String] = ["pid"]
    var sk: List[String] = ["score"]
    var desc: List[Bool] = [False]
    var out = _fuse_keeps_schema(
        LogicalPlan.partition_topn(pk^, sk^, desc^, 2, _fusable(PF_RANK))
    )
    assert_equal(Int(out.tag), Int(PLAN_PARTITION_TOPN))
    _assert_emits(
        out._partition_topn.value()[].child[], win, "under a partition topn"
    )


# =============================================================================
# Controls: a root that drops the window column
# =============================================================================


def test_root_project_dropping_it_does_not_emit_it() raises:
    """`Project(pid, score, val)` over the fusable Filter: the column is read
    by nothing, the fused node does not emit it, and the identity Project is
    absorbed. Catches a seed that marks every window column as read."""
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("pid"))
    exprs.append(Expr.col_ref("score"))
    exprs.append(Expr.col_ref("val"))
    var out = _fuse_keeps_schema(LogicalPlan.project(exprs^, _fusable(PF_RANK)))
    assert_equal(Int(out.tag), Int(PLAN_PARTITION_TOPN))
    assert_equal(
        Bool(out._partition_topn.value()[].output_rank_col_name), False
    )


def test_root_aggregate_dropping_it_does_not_emit_it() raises:
    """`SUM(val) GROUP BY pid` over the fusable Filter. Catches a seed taken
    from the fused Filter's schema instead of the root's."""
    var gb = ExprArray()
    gb.append(Expr.col_ref("pid"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("val")), Optional(String("s"))))
    var out = _fuse_keeps_schema(
        LogicalPlan.aggregate(gb^, aggs^, _fusable(PF_ROW_NUMBER))
    )
    assert_equal(Int(out.tag), Int(PLAN_AGGREGATE))
    ref fused = out._aggregate.value()[].child[]
    assert_equal(Int(fused.tag), Int(PLAN_PARTITION_TOPN))
    assert_equal(
        Bool(fused._partition_topn.value()[].output_rank_col_name), False
    )


# =============================================================================
# The whole driver on the plan from komira#1290
# =============================================================================


def test_optimize_keeps_the_root_row_number_column() raises:
    """`Filter(rn <= 5)` over `PartitionBy(partition=[a], order=[b DESC],
    ROW_NUMBER)` over `Scan(w.parquet: a, b, c)`, all INT64, through
    `optimize`. Catches the defect at the level a caller sees it: the
    optimized plan's output schema is the input's (`a, b, c, rn`)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    sb.add_field(Field("c", ArrowType.INT64, False))
    var scan = LogicalPlan.scan(String("w.parquet"), SOURCE_PARQUET, sb.build())
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.row_number())
    var pk: List[String] = ["a"]
    var ok: List[String] = ["b"]
    var desc: List[Bool] = [True]
    var pb = LogicalPlan.partition_by(pk^, ok^, desc^, exprs^, scan^)
    var rn = _win(pb)
    var pred = Expr.binary(
        BIN_LE, Expr.col_ref(rn), Expr.literal(ScalarValue.from_int(5))
    )
    var plan = LogicalPlan.filter(pred^, pb^)
    var want = _sig(plan)
    var deps = ScalarDepTable()
    var out = optimize(plan^, OptimizerConfig(), deps)
    assert_equal(_sig(out), want, "optimize changed the output schema")
    assert_true(not deps.has_requests())
    _assert_emits(out, rn, "optimized root")
    assert_equal(out._partition_topn.value()[].k, 5)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
