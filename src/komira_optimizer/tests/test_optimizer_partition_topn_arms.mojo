# =============================================================================
# fuse_partition_topn: the ancestor walk, the recursion arms, the
# Project-identity check and the K extractor.
# =============================================================================
#
# The moved partition-topN tests pin the firing shape at the top of a plan
# (with Project and Sort ancestors). This file covers the rest:
#
#   * `_collect_unsafe_window_cols` for each ancestor kind that can name the
#     window column (Aggregate group keys and aggregate arguments, Join keys on
#     either side, Distinct columns, TopN keys) and for ones that do not name
#     it (Limit, a Filter over a Filter on another column). An ancestor that names
#     the window column makes the fused node EMIT it; one that does not, does
#     not. Each case also proves `fuse_partition_topn_inplace` descends through
#     that node kind (the Filter under it became a PartitionTopN).
#   * the node kinds neither walk descends into (ASOF join, Union);
#   * the Project-over-PartitionTopN identity check, one case per way a
#     Project fails to be the identity;
#   * `_try_extract_k`, one case per return, and both ends of the K range.
#
# Every plan is built in memory; no file is read.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType

from komira_plan_expr.expr import Expr, BIN_LE, BIN_LT, BIN_GT
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_COUNT
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.partition_expr import PartitionExpr, PF_ROW_NUMBER, PF_RANK
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    AsofTolerance,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
    PLAN_UNION,
    JOIN_INNER,
    ASOF_BACKWARD,
)

from komira_optimizer.optimizer_partition_topn import fuse_partition_topn


# =============================================================================
# Builders
# =============================================================================


def _scan3(p: String, s: String, v: String) raises -> LogicalPlan:
    """An in-memory Scan(p INT64, s FLOAT64, v INT64)."""
    var sb = SchemaBuilder()
    sb.add_field(Field(p, ArrowType.INT64, False))
    sb.add_field(Field(s, ArrowType.FLOAT64, False))
    sb.add_field(Field(v, ArrowType.INT64, False))
    return LogicalPlan.scan(String("__test"), UInt8(3), sb.build())


def _pb(func: UInt8, var child: LogicalPlan, p: String, s: String) raises -> LogicalPlan:
    """PartitionBy(func) PARTITION BY p ORDER BY s DESC over `child`."""
    var exprs = List[PartitionExpr]()
    if func == PF_RANK:
        exprs.append(PartitionExpr.rank())
    else:
        exprs.append(PartitionExpr.row_number())
    var pk: List[String] = [p.copy()]
    var ok: List[String] = [s.copy()]
    var desc: List[Bool] = [True]
    return LogicalPlan.partition_by(pk^, ok^, desc^, exprs^, child^)


def _rank_pb() raises -> LogicalPlan:
    """PartitionBy(RANK) over Scan(pid, score, val)."""
    return _pb(PF_RANK, _scan3("pid", "score", "val"), "pid", "score")


def _rn_pb() raises -> LogicalPlan:
    """PartitionBy(ROW_NUMBER) over Scan(pid, score, val)."""
    return _pb(PF_ROW_NUMBER, _scan3("pid", "score", "val"), "pid", "score")


def _win(plan: LogicalPlan) -> String:
    """The window column a PartitionBy appends (its last column)."""
    return plan.output_schema.field_name(plan.output_schema.num_columns() - 1)


def _cmp(op: UInt8, name: String, var lit: ScalarValue) -> Expr:
    """`col(name) <op> lit`."""
    return Expr.binary(op, Expr.col_ref(name), Expr.literal(lit^))


def _le(name: String, k: Int) -> Expr:
    """`col(name) <= k` with an INT64 literal."""
    return _cmp(BIN_LE, name, ScalarValue.from_int(k))


def _fused_filter(var pb: LogicalPlan, k: Int) raises -> LogicalPlan:
    """Filter(window_col <= k) over `pb`: the shape the rule fuses."""
    var name = _win(pb)
    return LogicalPlan.filter(_le(name, k), pb^)


def _assert_fused(plan: LogicalPlan, emits: Bool, what: String) raises:
    """`plan` is a fused PartitionTopN, emitting its window column or not."""
    assert_equal(Int(plan.tag), Int(PLAN_PARTITION_TOPN), what)
    assert_equal(
        Bool(plan._partition_topn.value()[].output_rank_col_name), emits, what
    )


# =============================================================================
# Ancestors that name the window column, and ones that do not
# =============================================================================


def test_aggregate_grouping_on_the_rank_emits_it() raises:
    """Catches the Aggregate arm skipping its group keys: GROUP BY rk above
    the Filter needs rk after fusion. The COUNT(*) slot (no argument) takes
    the no-child branch of the argument loop."""
    var pb = _rank_pb()
    var rk = _win(pb)
    var gb = ExprArray()
    gb.append(Expr.col_ref(rk))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, None, Optional(String("n"))))
    var plan = LogicalPlan.aggregate(gb^, aggs^, _fused_filter(pb^, 3))
    var out = fuse_partition_topn(plan^)
    assert_equal(Int(out.tag), Int(PLAN_AGGREGATE))
    ref fused = out._aggregate.value()[].child[]
    _assert_fused(fused, True, "aggregate child")
    assert_equal(fused._partition_topn.value()[].output_rank_col_name.value(), rk)


def test_aggregate_argument_on_the_rank_emits_it() raises:
    """Catches the Aggregate arm skipping aggregate arguments: SUM(rk)."""
    var pb = _rank_pb()
    var rk = _win(pb)
    var gb = ExprArray()
    gb.append(Expr.col_ref("pid"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref(rk)), Optional(String("s"))))
    var plan = LogicalPlan.aggregate(gb^, aggs^, _fused_filter(pb^, 3))
    var out = fuse_partition_topn(plan^)
    _assert_fused(out._aggregate.value()[].child[], True, "aggregate child")


def test_aggregate_not_naming_the_rank_does_not_emit_it() raises:
    """CONTROL for the two above: an Aggregate over other columns fuses
    without the extra column. Catches an arm that marks every window column
    unsafe."""
    var gb = ExprArray()
    gb.append(Expr.col_ref("pid"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("val")), Optional(String("s"))))
    var plan = LogicalPlan.aggregate(gb^, aggs^, _fused_filter(_rank_pb(), 3))
    var out = fuse_partition_topn(plan^)
    _assert_fused(out._aggregate.value()[].child[], False, "aggregate child")


def test_join_keys_on_either_side_emit_and_both_sides_fuse() raises:
    """Catches the Join arm skipping `left_on` or `right_on`, or descending
    into one side only (in either walk): each side has its own fusable
    Filter, and each side's window column is a join key."""
    var lpb = _rank_pb()
    var lrk = _win(lpb)
    var rpb = _pb(PF_ROW_NUMBER, _scan3("rpid", "rscore", "rval"), "rpid", "rscore")
    var rrn = _win(rpb)
    var lo: List[String] = [lrk.copy()]
    var ro: List[String] = [rrn.copy()]
    var plan = LogicalPlan.join(
        _fused_filter(lpb^, 3), _fused_filter(rpb^, 2), lo^, ro^, JOIN_INNER,
    )
    var out = fuse_partition_topn(plan^)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    _assert_fused(out._join.value()[].left[], True, "join left")
    _assert_fused(out._join.value()[].right[], True, "join right")


def test_limit_passes_the_ancestors_down() raises:
    """Catches the Limit arm passing an empty set down (or not descending):
    Sort(rk) above Limit above the Filter still names rk."""
    var pb = _rank_pb()
    var rk = _win(pb)
    var keys: List[String] = [rk.copy()]
    var desc: List[Bool] = [False]
    var plan = LogicalPlan.sort(
        keys^, desc^, LogicalPlan.limit(10, _fused_filter(pb^, 3))
    )
    var out = fuse_partition_topn(plan^)
    assert_equal(Int(out.tag), Int(PLAN_SORT))
    ref lim = out._sort.value()[].child[]
    assert_equal(Int(lim.tag), Int(PLAN_LIMIT))
    _assert_fused(lim._limit.value()[].child[], True, "limit child")


def test_distinct_on_the_rank_emits_it() raises:
    """Catches the Distinct arm skipping its column list: DISTINCT ON (rk)."""
    var pb = _rank_pb()
    var rk = _win(pb)
    var cols: List[String] = [rk.copy()]
    var plan = LogicalPlan.distinct(
        Optional[List[String]](cols^), _fused_filter(pb^, 3)
    )
    var out = fuse_partition_topn(plan^)
    assert_equal(Int(out.tag), Int(PLAN_DISTINCT))
    _assert_fused(out._distinct.value()[].child[], True, "distinct child")


def test_distinct_over_all_columns_emits_it() raises:
    """A Distinct with no column list reads every column of its child, the
    window column included (its own output schema was built over the
    PartitionBy's columns, rank included), so the fused node emits it.
    Catches the arm adding nothing when `columns` is None."""
    var plan = LogicalPlan.distinct(None, _fused_filter(_rank_pb(), 3))
    var out = fuse_partition_topn(plan^)
    _assert_fused(out._distinct.value()[].child[], True, "distinct child")


def test_topn_on_the_rank_emits_it() raises:
    """Catches the TopN arm skipping its keys (or not descending)."""
    var pb = _rank_pb()
    var rk = _win(pb)
    var keys: List[String] = [rk.copy()]
    var desc: List[Bool] = [False]
    var plan = LogicalPlan.topn(keys^, desc^, 5, _fused_filter(pb^, 3))
    var out = fuse_partition_topn(plan^)
    assert_equal(Int(out.tag), Int(PLAN_TOPN))
    _assert_fused(out._topn.value()[].child[], True, "topn child")


def test_a_filter_over_the_fused_filter_keeps_itself() raises:
    """A Filter whose child is a Filter (not a PartitionBy): the ancestor walk
    passes through it and the fuse descends first, so the inner Filter fuses
    and the outer one stays. Catches the Filter arm checking its child before
    descending, or returning without descending."""
    var pred = _cmp(BIN_GT, "val", ScalarValue.from_int(0))
    var plan = LogicalPlan.filter(pred^, _fused_filter(_rn_pb(), 3))
    var out = fuse_partition_topn(plan^)
    assert_equal(Int(out.tag), Int(PLAN_FILTER))
    _assert_fused(out._filter.value()[].child[], False, "inner filter")


# =============================================================================
# Node kinds neither walk descends into
# =============================================================================


def test_an_asof_join_is_not_descended() raises:
    """Pins what the code does: neither walk has an ASOF-join arm that
    descends, so a fusable Filter under one stays a Filter. Catches the
    ASOF arm of the ancestor walk being given a recursion without the fuse
    getting one (or the reverse) unnoticed."""
    var lk: List[String] = ["pid"]
    var rk: List[String] = ["rpid"]
    var plan = LogicalPlan.asof_join(
        _fused_filter(_rank_pb(), 3),
        _scan3("rpid", "rscore", "rval"),
        lk^, rk^,
        String("val"), String("rval"),
        ASOF_BACKWARD, AsofTolerance.none(),
    )
    var out = fuse_partition_topn(plan^)
    assert_equal(Int(out.tag), Int(PLAN_ASOF_JOIN))
    assert_equal(Int(out._asof_join.value()[].left[].tag), Int(PLAN_FILTER))


def test_a_union_is_not_descended() raises:
    """Pins what the code does with a node kind it has no arm for (a Union):
    both walks leave it and its branches unchanged."""
    var pb = _rn_pb()
    var schema = pb.output_schema.copy()
    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(_fused_filter(pb^, 3)))
    var plan = LogicalPlan.union(children^, schema^)
    var out = fuse_partition_topn(plan^)
    assert_equal(Int(out.tag), Int(PLAN_UNION))
    assert_equal(Int(out.union_data_ref().children[0][].tag), Int(PLAN_FILTER))


# =============================================================================
# Project over a fused node: only the identity Project is removed
# =============================================================================


def _project_over_fused(var exprs: ExprArray) raises -> LogicalPlan:
    """fuse(Project(exprs) over Filter(rn <= 3) over PartitionBy(ROW_NUMBER)).
    The fused node's columns are (pid, score, val)."""
    var plan = LogicalPlan.project(exprs^, _fused_filter(_rn_pb(), 3))
    return fuse_partition_topn(plan^)


def test_a_narrower_project_is_kept() raises:
    """Catches the column-count check being dropped: Project(pid, score)
    drops `val`, so removing it would add a column to the output."""
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("pid"))
    exprs.append(Expr.col_ref("score"))
    var out = _project_over_fused(exprs^)
    assert_equal(Int(out.tag), Int(PLAN_PROJECT))
    _assert_fused(out._project.value()[].child[], False, "project child")


def test_a_project_with_a_computed_expr_is_kept() raises:
    """Catches the col-ref check being dropped: the third entry is an Alias,
    not a column reference, even though it keeps the name `val`."""
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("pid"))
    exprs.append(Expr.col_ref("score"))
    exprs.append(Expr.alias(Expr.col_ref("val"), "val"))
    var out = _project_over_fused(exprs^)
    assert_equal(Int(out.tag), Int(PLAN_PROJECT))


def test_a_reordering_project_is_kept() raises:
    """Catches the name check being dropped: Project(score, pid, val) has the
    right width and only column references, but reorders the columns."""
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("score"))
    exprs.append(Expr.col_ref("pid"))
    exprs.append(Expr.col_ref("val"))
    var out = _project_over_fused(exprs^)
    assert_equal(Int(out.tag), Int(PLAN_PROJECT))
    assert_equal(out.output_schema.field_name(0), String("score"))


def test_a_project_over_a_scan_is_untouched() raises:
    """Catches the identity removal firing on a child that is not a
    PartitionTopN: Project(pid, score, val) over the Scan is the identity
    too, but only a Project over a fused node is removed."""
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("pid"))
    exprs.append(Expr.col_ref("score"))
    exprs.append(Expr.col_ref("val"))
    var plan = LogicalPlan.project(exprs^, _scan3("pid", "score", "val"))
    var out = fuse_partition_topn(plan^)
    assert_equal(Int(out.tag), Int(PLAN_PROJECT))
    assert_equal(Int(out._project.value()[].child[].tag), Int(PLAN_SCAN))


# =============================================================================
# The K extractor
# =============================================================================


def _fuse_with(var pred: Expr) raises -> LogicalPlan:
    """fuse(Filter(pred) over PartitionBy(ROW_NUMBER))."""
    var plan = LogicalPlan.filter(pred^, _rn_pb())
    return fuse_partition_topn(plan^)


def test_a_non_binary_predicate_does_not_fuse() raises:
    """Catches the binary check being dropped (the extractor would then read
    an operator off a literal)."""
    var out = _fuse_with(Expr.literal(ScalarValue.from_bool(True)))
    assert_equal(Int(out.tag), Int(PLAN_FILTER))


def test_a_literal_on_the_left_does_not_fuse() raises:
    """Catches the left-side col-ref check being dropped: `3 <= rn` is not
    `rn <= 3`."""
    var name = _win(_rn_pb())
    var pred = Expr.binary(
        BIN_LE, Expr.literal(ScalarValue.from_int(3)), Expr.col_ref(name)
    )
    var out = _fuse_with(pred^)
    assert_equal(Int(out.tag), Int(PLAN_FILTER))


def test_a_non_int64_non_int32_literal_does_not_fuse() raises:
    """Catches the literal-type check being dropped: an INT16 literal carries
    its value in the same slot, so without the check `rn <= 5::int16` would
    fuse with K=5."""
    var name = _win(_rn_pb())
    var out = _fuse_with(_cmp(BIN_LE, name, ScalarValue.from_int16(5)))
    assert_equal(Int(out.tag), Int(PLAN_FILTER))


def test_an_int32_literal_fuses() raises:
    """Catches the INT32 arm of the literal-type check being dropped:
    `rn <= 5::int32` fuses with K=5."""
    var name = _win(_rn_pb())
    var out = _fuse_with(_cmp(BIN_LE, name, ScalarValue.from_int32(5)))
    _assert_fused(out, False, "int32 K")
    assert_equal(out._partition_topn.value()[].k, 5)


def test_less_than_bounds() raises:
    """`rn < 2` is K=1; `rn < 1` keeps no row and does not fuse. Catches the
    `< K` -> `K - 1` mapping being off by one in either direction."""
    var name = _win(_rn_pb())
    var two = _fuse_with(_cmp(BIN_LT, name, ScalarValue.from_int(2)))
    _assert_fused(two, False, "rn < 2")
    assert_equal(two._partition_topn.value()[].k, 1)
    var one = _fuse_with(_cmp(BIN_LT, name, ScalarValue.from_int(1)))
    assert_equal(Int(one.tag), Int(PLAN_FILTER))


def test_k_upper_bound() raises:
    """K = 1,000,000 fuses and K = 1,000,001 does not. Catches the cap being
    dropped (an unbounded per-partition heap) or made exclusive."""
    var name = _win(_rn_pb())
    var at = _fuse_with(_le(name, 1_000_000))
    _assert_fused(at, False, "K at the cap")
    assert_equal(at._partition_topn.value()[].k, 1_000_000)
    var over = _fuse_with(_le(name, 1_000_001))
    assert_equal(Int(over.tag), Int(PLAN_FILTER))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
