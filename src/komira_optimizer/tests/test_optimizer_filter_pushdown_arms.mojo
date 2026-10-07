# =============================================================================
# test_optimizer_filter_pushdown_arms.mojo -- Rules 1, 8 and 2 of
# optimizer_filter, arm by arm.
# =============================================================================
#
# `push_predicates_down` has one arm per child kind under a FILTER (Project,
# Scan, Filter, Inner/Cross Join, anything else) and one recursion arm per
# non-FILTER parent. The welded tests cover the UDF barrier, the replacing-
# Project guard and the string / regexp descents; these cover the rest:
#   * the Scan arm: a ROW-kind scan keeps its Filter; nothing pushable keeps
#     the whole predicate; everything pushable folds into the scan filter
#     (merging an existing one, keeping projection / row count / stats / kind);
#     a split keeps the rest above;
#   * the CSE-Project barrier;
#   * Filter over Filter: the inner collapses (re-push), or both park (the
#     original order is kept);
#   * Inner and Cross joins: left-only, right-only, both-sides; a residual
#     join and an outer join are barriers; an Aggregate is a barrier;
#   * every non-FILTER parent recursing into its child.
# `fuse_filters` and `decompose_filters` get the same treatment.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT
from komira_plan_expr.expr import (
    Expr,
    EXPR_BINARY_OP,
    BIN_AND,
    BIN_OR,
    BIN_EQ,
    BIN_GT,
    BIN_LT,
    STR_LIKE,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_stats.table_stats import TableStats, ColumnStats
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    JOIN_INNER,
    JOIN_CROSS,
    JOIN_LEFT,
    JOIN_ALGO_AUTO,
    SOURCE_PARQUET,
    SOURCE_NDJSON,
    SOURCE_KIND_ROW,
)
from komira_optimizer.optimizer_filter import (
    push_predicates_down,
    fuse_filters,
    decompose_filters,
)


# -----------------------------------------------------------------------------
# fixtures
# -----------------------------------------------------------------------------


def _t_schema() -> Schema:
    """t: a, b, c INT64; s STRING."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.INT64, True))
    sb.add_field(Field("c", ArrowType.INT64, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    return sb.build()


def _r_schema() -> Schema:
    """r: ra, rb INT64."""
    var sb = SchemaBuilder()
    sb.add_field(Field("ra", ArrowType.INT64, True))
    sb.add_field(Field("rb", ArrowType.INT64, True))
    return sb.build()


def _t() -> LogicalPlan:
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _t_schema())


def _r() -> LogicalPlan:
    return LogicalPlan.scan("r.parquet", SOURCE_PARQUET, _r_schema())


def _lit(n: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int64(Int64(n)))


def _gt(name: String, n: Int) -> Expr:
    return Expr.binary(BIN_GT, Expr.col_ref(name), _lit(n))


def _lt(name: String, n: Int) -> Expr:
    return Expr.binary(BIN_LT, Expr.col_ref(name), _lit(n))


def _eq(l: String, r: String) -> Expr:
    return Expr.binary(BIN_EQ, Expr.col_ref(l), Expr.col_ref(r))


def _and(var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(BIN_AND, l^, r^)


def _like_s() -> Expr:
    """Not pushable into a parquet scan (a string op)."""
    return Expr.string_op(STR_LIKE, Expr.col_ref("s"), "%x%")


def _or_ab() -> Expr:
    """Not pushable into a parquet scan (an OR-tree)."""
    return Expr.binary(BIN_OR, _gt("a", 1), _gt("b", 1))


def _render(e: Expr) -> String:
    var s = String("")
    e.write_to(s)
    return s


def _scan_filter(p: LogicalPlan) -> String:
    """The scan's pushed filter rendered; "" when it has none."""
    if p.tag != PLAN_SCAN or not p._scan.value()[].filter:
        return String("")
    return _render(p._scan.value()[].filter.value())


def _join(var l: LogicalPlan, var r: LogicalPlan, jt: UInt8) -> LogicalPlan:
    var lk = List[String]()
    var rk = List[String]()
    if jt != JOIN_CROSS:
        lk.append("a")
        rk.append("ra")
    return LogicalPlan.join(l^, r^, lk^, rk^, jt)


def _pushed_into_scan(p: LogicalPlan, needle: String) -> Bool:
    return _scan_filter(p).find(needle) >= 0


# -----------------------------------------------------------------------------
# the Scan arm
# -----------------------------------------------------------------------------


def test_row_kind_scan_keeps_the_filter_above() raises:
    # Defect: the ROW-kind early return drops the predicate or the scan.
    var scan = LogicalPlan.scan("t.ndjson", SOURCE_NDJSON, _t_schema())
    assert_equal(Int(scan._scan.value()[].source_kind), Int(SOURCE_KIND_ROW))
    var out = push_predicates_down(LogicalPlan.filter(_gt("a", 1), scan^))
    assert_equal(Int(out.tag), Int(PLAN_FILTER))
    assert_true(_render(out._filter.value()[].predicate).find("ColRef(a)") >= 0)
    ref child = out._filter.value()[].child[]
    assert_equal(Int(child.tag), Int(PLAN_SCAN))
    assert_false(Bool(child._scan.value()[].filter))


def test_nothing_pushable_keeps_every_conjunct_above() raises:
    # LIKE and an OR-tree are refused by a parquet source. Defect: a refused
    # conjunct is lost, or the scan gains a filter it cannot use.
    var pred = _and(_like_s(), _or_ab())
    var out = push_predicates_down(LogicalPlan.filter(pred^, _t()))
    assert_equal(Int(out.tag), Int(PLAN_FILTER))
    var r = _render(out._filter.value()[].predicate)
    assert_true(r.find("ColRef(s)") >= 0 and r.find("ColRef(b)") >= 0, r)
    assert_equal(_scan_filter(out._filter.value()[].child[]), "")


def test_all_pushable_merges_into_the_scan_and_keeps_its_metadata() raises:
    # The scan already carries `c > 0`, a projection, a row count, table
    # stats. Defect: the old scan filter overwritten instead of AND-merged; a
    # second conjunct dropped; projection / row count / stats / kind reset by
    # the rebuild; or a Filter left above when nothing remains.
    var proj = List[String]()
    proj.append("a")
    proj.append("b")
    proj.append("c")
    var stats = TableStats(100, List[String](), List[ColumnStats]())
    var scan = LogicalPlan.scan(
        "t.parquet",
        SOURCE_PARQUET,
        _t_schema(),
        Optional(proj^),
        Optional(_gt("c", 0)),
        Optional(Int(100)),
        Optional(stats^),
    )
    var kind = scan._scan.value()[].source_kind
    var out = push_predicates_down(
        LogicalPlan.filter(_and(_gt("a", 1), _lt("b", 5)), scan^)
    )
    assert_equal(Int(out.tag), Int(PLAN_SCAN), "nothing left to keep above")
    var f = _scan_filter(out)
    assert_true(f.find("ColRef(c)") >= 0, "old scan filter kept: " + f)
    assert_true(f.find("ColRef(a)") >= 0 and f.find("ColRef(b)") >= 0, f)
    ref sd = out._scan.value()[]
    assert_true(Bool(sd.projection))
    assert_equal(len(sd.projection.value()), 3)
    assert_equal(sd.row_count.value(), 100)
    assert_true(Bool(sd.table_stats))
    assert_equal(sd.table_stats.value().row_count, 100)
    assert_equal(Int(sd.source_kind), Int(kind))
    assert_equal(out.output_schema.num_columns(), 3)


def test_a_split_pushes_some_and_keeps_the_rest_above() raises:
    # a > 1 and b > 2 fold into the (filter-less) scan; LIKE and the OR stay
    # above. Defect: the first pushable conjunct counted twice or skipped; a
    # kept conjunct after the first lost.
    var pred = _and(_and(_gt("a", 1), _like_s()), _and(_gt("b", 2), _or_ab()))
    var out = push_predicates_down(LogicalPlan.filter(pred^, _t()))
    assert_equal(Int(out.tag), Int(PLAN_FILTER))
    var kept = _render(out._filter.value()[].predicate)
    assert_true(kept.find("ColRef(s)") >= 0, kept)
    # ColRef(b) above can only come from the OR-tree (b > 2 was pushed).
    assert_true(kept.find("ColRef(b)") >= 0, kept)
    ref scan = out._filter.value()[].child[]
    var f = _scan_filter(scan)
    assert_true(f.find("ColRef(a)") >= 0 and f.find("ColRef(b)") >= 0, f)
    assert_false(f.find("ColRef(s)") >= 0, f)


# -----------------------------------------------------------------------------
# the Project arm: the CSE barrier
# -----------------------------------------------------------------------------


def test_cse_project_is_a_barrier_but_its_subtree_is_still_pushed() raises:
    # A CSE-introduced Project materializes synthetic columns only above
    # itself. Defect: the barrier removed (the Filter goes below it), the
    # flag lost by the rebuild, or the subtree below it not pushed.
    var e = ExprArray()
    e.append(Expr.col_ref("a"))
    e.append(Expr.col_ref("b"))
    var inner = LogicalPlan.filter(_gt("b", 2), _t())
    var proj = LogicalPlan.project(e^, inner^, True)
    var out = push_predicates_down(LogicalPlan.filter(_gt("a", 1), proj^))
    assert_equal(Int(out.tag), Int(PLAN_FILTER), "kept above the CSE Project")
    ref p = out._filter.value()[].child[]
    assert_equal(Int(p.tag), Int(PLAN_PROJECT))
    assert_true(p._project.value()[].is_cse_introduced)
    assert_true(_pushed_into_scan(p._project.value()[].child[], "ColRef(b)"))


# -----------------------------------------------------------------------------
# the Filter-over-Filter arm
# -----------------------------------------------------------------------------


def test_inner_filter_that_collapses_lets_the_outer_one_follow() raises:
    # Filter(a > 1, Filter(b > 2, Scan)): the inner folds into the scan, then
    # the outer is re-pushed. Defect: the re-push skipped (a > 1 left above).
    var inner = LogicalPlan.filter(_gt("b", 2), _t())
    var out = push_predicates_down(LogicalPlan.filter(_gt("a", 1), inner^))
    assert_equal(Int(out.tag), Int(PLAN_SCAN))
    assert_true(_pushed_into_scan(out, "ColRef(a)"))
    assert_true(_pushed_into_scan(out, "ColRef(b)"))


def test_two_parked_filters_keep_their_order_and_terminate() raises:
    # Both conjuncts span both join sides, so neither descends: the trial
    # fails and the original order is kept. Defect: the swap applied anyway
    # (or an unbounded re-recursion, which hangs this test).
    var cross = _join(_t(), _r(), JOIN_CROSS)
    var inner = LogicalPlan.filter(_eq("b", "rb"), cross^)
    var out = push_predicates_down(LogicalPlan.filter(_eq("a", "ra"), inner^))
    assert_equal(Int(out.tag), Int(PLAN_FILTER))
    assert_true(_render(out._filter.value()[].predicate).find("ColRef(ra)") >= 0)
    ref f2 = out._filter.value()[].child[]
    assert_equal(Int(f2.tag), Int(PLAN_FILTER))
    assert_true(_render(f2._filter.value()[].predicate).find("ColRef(rb)") >= 0)
    assert_equal(Int(f2._filter.value()[].child[].tag), Int(PLAN_JOIN))


def test_outer_filter_descends_past_a_parked_inner_one() raises:
    # Filter(a > 1, Filter(b = rb, CROSS)): b = rb parks above the join; a > 1
    # reaches the t scan, and the parked one is re-wrapped on top. Defect:
    # the outer predicate stranded above the join.
    var cross = _join(_t(), _r(), JOIN_CROSS)
    var inner = LogicalPlan.filter(_eq("b", "rb"), cross^)
    var out = push_predicates_down(LogicalPlan.filter(_gt("a", 1), inner^))
    assert_equal(Int(out.tag), Int(PLAN_FILTER))
    assert_true(_render(out._filter.value()[].predicate).find("ColRef(rb)") >= 0)
    ref j = out._filter.value()[].child[]
    assert_equal(Int(j.tag), Int(PLAN_JOIN))
    assert_true(_pushed_into_scan(j._join.value()[].left[], "ColRef(a)"))


# -----------------------------------------------------------------------------
# the Join arm
# -----------------------------------------------------------------------------


def test_left_only_predicate_goes_to_the_left_child_and_keeps_the_join() raises:
    # Defect: pushed to the wrong side, or the rebuild loses keys / type.
    var out = push_predicates_down(
        LogicalPlan.filter(_gt("a", 1), _join(_t(), _r(), JOIN_INNER))
    )
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    ref jd = out._join.value()[]
    assert_equal(Int(jd.join_type), Int(JOIN_INNER))
    assert_equal(len(jd.left_on), 1)
    assert_equal(jd.right_on[0], "ra")
    assert_true(_pushed_into_scan(jd.left[], "ColRef(a)"))
    assert_equal(_scan_filter(jd.right[]), "")


def test_right_only_predicate_goes_to_the_right_child_of_a_cross_join() raises:
    # A CROSS join stays CROSS (eliminate_cross_join folds it later). Defect:
    # the right arm pushes left, or rewrites the join type.
    var out = push_predicates_down(
        LogicalPlan.filter(_gt("rb", 1), _join(_t(), _r(), JOIN_CROSS))
    )
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    ref jd = out._join.value()[]
    assert_equal(Int(jd.join_type), Int(JOIN_CROSS))
    assert_true(_pushed_into_scan(jd.right[], "ColRef(rb)"))
    assert_equal(_scan_filter(jd.left[]), "")


def test_both_sides_predicate_stays_above_and_the_join_is_still_walked() raises:
    # Defect: a both-sides conjunct pushed into one side (dangling ref), or
    # the join below not walked (its own child filter left unpushed).
    var left = LogicalPlan.filter(_gt("c", 3), _t())
    var join = _join(left^, _r(), JOIN_INNER)
    var out = push_predicates_down(LogicalPlan.filter(_eq("b", "rb"), join^))
    assert_equal(Int(out.tag), Int(PLAN_FILTER))
    ref j = out._filter.value()[].child[]
    assert_equal(Int(j.tag), Int(PLAN_JOIN))
    assert_true(_pushed_into_scan(j._join.value()[].left[], "ColRef(c)"))


def test_residual_join_outer_join_and_aggregate_are_barriers() raises:
    # A residual-carrying INNER join (the rebuild would drop the residual), a
    # LEFT join, and an Aggregate keep the Filter above. Defect: any of them
    # admitted by the join arm, or the else arm not recursing.
    var lk = List[String]()
    lk.append("a")
    var rk = List[String]()
    rk.append("ra")
    var res = Optional[OwnedPointer[Expr]](OwnedPointer(_gt("rb", 0)))
    var rj = LogicalPlan.join(_t(), _r(), lk^, rk^, JOIN_INNER, JOIN_ALGO_AUTO, res^)
    var o1 = push_predicates_down(LogicalPlan.filter(_gt("a", 1), rj^))
    assert_equal(Int(o1.tag), Int(PLAN_FILTER))
    assert_true(o1._filter.value()[].child[]._join.value()[].has_residual())
    var o2 = push_predicates_down(
        LogicalPlan.filter(_gt("a", 1), _join(_t(), _r(), JOIN_LEFT))
    )
    assert_equal(Int(o2.tag), Int(PLAN_FILTER))
    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    var aggs = AggExprArray()
    var none: Optional[Expr] = None
    aggs.append(AggExpr(AGG_COUNT, none^, Optional(String("n"))))
    var under = LogicalPlan.filter(_gt("b", 2), _t())
    var agg = LogicalPlan.aggregate(gb^, aggs^, under^)
    var o3 = push_predicates_down(LogicalPlan.filter(_gt("a", 1), agg^))
    assert_equal(Int(o3.tag), Int(PLAN_FILTER))
    ref a = o3._filter.value()[].child[]
    assert_equal(Int(a.tag), Int(PLAN_AGGREGATE))
    assert_true(_pushed_into_scan(a._aggregate.value()[].child[], "ColRef(b)"))


# -----------------------------------------------------------------------------
# the non-FILTER recursion arms
# -----------------------------------------------------------------------------


def _site() -> LogicalPlan:
    """Filter(a > 1, Scan(t)): pushdown folds it into the scan."""
    return LogicalPlan.filter(_gt("a", 1), _t())


def _site_done(p: LogicalPlan) -> Bool:
    return _pushed_into_scan(p, "ColRef(a)")


def test_pushdown_walks_every_non_filter_parent() raises:
    # Defect: a parent arm that does not recurse leaves its child unpushed.
    var e = ExprArray()
    e.append(Expr.col_ref("a"))
    var p = push_predicates_down(LogicalPlan.project(e^, _site()))
    assert_true(_site_done(p._project.value()[].child[]), "Project arm")
    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    var a = push_predicates_down(LogicalPlan.aggregate(gb^, AggExprArray(), _site()))
    assert_true(_site_done(a._aggregate.value()[].child[]), "Aggregate arm")
    var lk = List[String]()
    lk.append("a")
    var rk = List[String]()
    rk.append("ra")
    var right = LogicalPlan.filter(_gt("ra", 1), _r())
    var j = push_predicates_down(LogicalPlan.join(_site(), right^, lk^, rk^, JOIN_INNER))
    assert_true(_site_done(j._join.value()[].left[]), "Join left")
    assert_true(_pushed_into_scan(j._join.value()[].right[], "ColRef(ra)"), "Join right")
    var keys = List[String]()
    keys.append("a")
    var desc = List[Bool]()
    desc.append(False)
    var s = push_predicates_down(LogicalPlan.sort(keys.copy(), desc.copy(), _site()))
    assert_true(_site_done(s._sort.value()[].child[]), "Sort arm")
    var l = push_predicates_down(LogicalPlan.limit(3, _site()))
    assert_true(_site_done(l._limit.value()[].child[]), "Limit arm")
    var none: Optional[List[String]] = None
    var d = push_predicates_down(LogicalPlan.distinct(none^, _site()))
    assert_true(_site_done(d._distinct.value()[].child[]), "Distinct arm")
    var t = push_predicates_down(LogicalPlan.topn(keys^, desc^, 2, _site()))
    assert_true(_site_done(t._topn.value()[].child[]), "TopN arm")
    var sc = push_predicates_down(_t())
    assert_equal(Int(sc.tag), Int(PLAN_SCAN))
    assert_equal(_scan_filter(sc), "")


# -----------------------------------------------------------------------------
# Rule 1: fuse_filters
# -----------------------------------------------------------------------------


def _ff() -> LogicalPlan:
    """Filter(a > 1, Filter(b > 2, Scan))."""
    return LogicalPlan.filter(_gt("a", 1), LogicalPlan.filter(_gt("b", 2), _t()))


def _fused(p: LogicalPlan) -> Bool:
    """One Filter of (inner AND outer) directly over the scan."""
    if p.tag != PLAN_FILTER or p._filter.value()[].child[].tag != PLAN_SCAN:
        return False
    ref pred = p._filter.value()[].predicate
    if pred.tag != EXPR_BINARY_OP or pred.binary_op() != BIN_AND:
        return False
    return (
        _render(pred.binary_left_ref()).find("ColRef(b)") >= 0
        and _render(pred.binary_right_ref()).find("ColRef(a)") >= 0
    )


def test_fuse_two_filters_into_one_and() raises:
    # Defect: no fusion, a predicate dropped, or the inner/outer order swapped.
    assert_true(_fused(fuse_filters(_ff())))


def test_fuse_three_filters_bottom_up() raises:
    # The inner pair fuses first, then the outer one onto it. Defect: the
    # recursion into the child skipped (only the top pair fuses).
    var out = fuse_filters(LogicalPlan.filter(_gt("c", 3), _ff()))
    assert_equal(Int(out.tag), Int(PLAN_FILTER))
    assert_equal(Int(out._filter.value()[].child[].tag), Int(PLAN_SCAN))
    var r = _render(out._filter.value()[].predicate)
    assert_true(r.find("ColRef(a)") >= 0 and r.find("ColRef(b)") >= 0)
    assert_true(r.find("ColRef(c)") >= 0)


def test_a_single_filter_is_not_fused() raises:
    var out = fuse_filters(_site())
    assert_equal(Int(out.tag), Int(PLAN_FILTER))
    assert_equal(_render(out._filter.value()[].predicate), _render(_gt("a", 1)))


def test_fuse_walks_every_parent_kind() raises:
    # Defect: a parent arm that does not recurse.
    var e = ExprArray()
    e.append(Expr.col_ref("a"))
    var p = fuse_filters(LogicalPlan.project(e^, _ff()))
    assert_true(_fused(p._project.value()[].child[]), "Project arm")
    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    var a = fuse_filters(LogicalPlan.aggregate(gb^, AggExprArray(), _ff()))
    assert_true(_fused(a._aggregate.value()[].child[]), "Aggregate arm")
    var lk = List[String]()
    lk.append("a")
    var rk = List[String]()
    rk.append("a")
    var j = fuse_filters(LogicalPlan.join(_t(), _ff(), lk^, rk^, JOIN_INNER))
    assert_true(_fused(j._join.value()[].right[]), "Join right")
    var lk2 = List[String]()
    lk2.append("a")
    var rk2 = List[String]()
    rk2.append("a")
    var j2 = fuse_filters(LogicalPlan.join(_ff(), _t(), lk2^, rk2^, JOIN_INNER))
    assert_true(_fused(j2._join.value()[].left[]), "Join left")
    var keys = List[String]()
    keys.append("a")
    var desc = List[Bool]()
    desc.append(False)
    var s = fuse_filters(LogicalPlan.sort(keys.copy(), desc.copy(), _ff()))
    assert_true(_fused(s._sort.value()[].child[]), "Sort arm")
    var l = fuse_filters(LogicalPlan.limit(3, _ff()))
    assert_true(_fused(l._limit.value()[].child[]), "Limit arm")
    var none: Optional[List[String]] = None
    var d = fuse_filters(LogicalPlan.distinct(none^, _ff()))
    assert_true(_fused(d._distinct.value()[].child[]), "Distinct arm")
    var t = fuse_filters(LogicalPlan.topn(keys^, desc^, 2, _ff()))
    assert_true(_fused(t._topn.value()[].child[]), "TopN arm")
    assert_equal(Int(fuse_filters(_t()).tag), Int(PLAN_SCAN))


# -----------------------------------------------------------------------------
# Rule 8: decompose_filters
# -----------------------------------------------------------------------------


def _abc() -> LogicalPlan:
    """Filter((a > 1 AND b > 2) AND c > 3, Scan)."""
    return LogicalPlan.filter(_and(_and(_gt("a", 1), _gt("b", 2)), _gt("c", 3)), _t())


def _decomposed(p: LogicalPlan) -> Bool:
    """Filter(c, Filter(b, Filter(a, Scan))): conjuncts flattened in order."""
    if p.tag != PLAN_FILTER:
        return False
    ref f1 = p._filter.value()[]
    if f1.child[].tag != PLAN_FILTER:
        return False
    ref f2 = f1.child[]._filter.value()[]
    if f2.child[].tag != PLAN_FILTER:
        return False
    ref f3 = f2.child[]._filter.value()[]
    return (
        f3.child[].tag == PLAN_SCAN
        and _render(f1.predicate) == _render(_gt("c", 3))
        and _render(f2.predicate) == _render(_gt("b", 2))
        and _render(f3.predicate) == _render(_gt("a", 1))
    )


def test_decompose_flattens_a_nested_and_into_a_chain() raises:
    # Defect: the AND tree flattened only one level, conjuncts reordered or
    # lost, or the child replaced.
    assert_true(_decomposed(decompose_filters(_abc())))


def test_decompose_leaves_a_single_conjunct_alone() raises:
    # An OR is one conjunct. Defect: a non-AND binary split.
    var out = decompose_filters(LogicalPlan.filter(_or_ab(), _t()))
    assert_equal(Int(out.tag), Int(PLAN_FILTER))
    assert_equal(Int(out._filter.value()[].child[].tag), Int(PLAN_SCAN))


def test_decompose_walks_every_parent_kind() raises:
    # Defect: a parent arm that does not recurse.
    var e = ExprArray()
    e.append(Expr.col_ref("a"))
    var p = decompose_filters(LogicalPlan.project(e^, _abc()))
    assert_true(_decomposed(p._project.value()[].child[]), "Project arm")
    var gb = ExprArray()
    gb.append(Expr.col_ref("a"))
    var a = decompose_filters(LogicalPlan.aggregate(gb^, AggExprArray(), _abc()))
    assert_true(_decomposed(a._aggregate.value()[].child[]), "Aggregate arm")
    var lk = List[String]()
    lk.append("a")
    var rk = List[String]()
    rk.append("a")
    var j = decompose_filters(LogicalPlan.join(_abc(), _abc(), lk^, rk^, JOIN_INNER))
    assert_true(_decomposed(j._join.value()[].left[]), "Join left")
    assert_true(_decomposed(j._join.value()[].right[]), "Join right")
    var keys = List[String]()
    keys.append("a")
    var desc = List[Bool]()
    desc.append(False)
    var s = decompose_filters(LogicalPlan.sort(keys.copy(), desc.copy(), _abc()))
    assert_true(_decomposed(s._sort.value()[].child[]), "Sort arm")
    var l = decompose_filters(LogicalPlan.limit(3, _abc()))
    assert_true(_decomposed(l._limit.value()[].child[]), "Limit arm")
    var none: Optional[List[String]] = None
    var d = decompose_filters(LogicalPlan.distinct(none^, _abc()))
    assert_true(_decomposed(d._distinct.value()[].child[]), "Distinct arm")
    var t = decompose_filters(LogicalPlan.topn(keys^, desc^, 2, _abc()))
    assert_true(_decomposed(t._topn.value()[].child[]), "TopN arm")
    var inner = decompose_filters(LogicalPlan.filter(_gt("c", 9), _abc()))
    assert_equal(Int(inner.tag), Int(PLAN_FILTER), "Filter arm recurses first")
    assert_true(_decomposed(inner._filter.value()[].child[]))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
