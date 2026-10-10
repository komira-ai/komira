"""Projection pushdown tests of `komira_optimizer.optimizer_projection`.

`push_projections_down` narrows every scan to the columns its consumers read.
Each test builds a small plan over Parquet scans, runs the pass and reads the
projection the scan ends up with. Each test names the defect it catches.
"""

from std.collections import Set
from std.memory import OwnedPointer
from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.schema import SchemaBuilder, Field, Schema
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_AND, BIN_GT, BIN_LT
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_COUNT, AGG_CORR
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_stats.table_stats import TableStats, ColumnStats
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ScanData,
    ExprArray,
    AggExprArray,
    PLAN_SCAN,
    PLAN_PROJECT,
    SOURCE_PARQUET,
    SOURCE_KIND_ROW,
    JOIN_INNER,
    JOIN_SEMI,
    JOIN_ANTI,
    JOIN_CROSS,
)
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.source_variant import SourceVariant

from komira_optimizer.optimizer_projection import (
    push_projections_down,
    prune_columns,
    _strip_right_suffix_nr,
    _collect_referenced_columns,
)


# =============================================================================
# Fixtures
# =============================================================================


def _schema(names: List[String]) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], ArrowType.INT64, nullable=False))
    return sb.build()


def _names(csv: String) raises -> List[String]:
    var out = List[String]()
    for part in csv.split(","):
        out.append(String(part))
    return out^


def _scan(cols: String, var filter: Optional[Expr] = None) raises -> LogicalPlan:
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema(_names(cols)), None, filter^)


def _gt(col: String, v: Int) -> Expr:
    return Expr.binary(BIN_GT, Expr.col_ref(col), Expr.literal(ScalarValue.from_int(v)))


def _cols(*names: String) -> ExprArray:
    var e = ExprArray()
    for n in names:
        e.append(Expr.col_ref(n))
    return e^


def _keys(*names: String) -> List[String]:
    var out = List[String]()
    for n in names:
        out.append(n)
    return out^


def _proj(scan: LogicalPlan) raises -> String:
    """The scan's projection as `a,b`, or `*` when it has none."""
    assert_equal(scan.tag, PLAN_SCAN)
    if not scan._scan.value()[].projection:
        return "*"
    var s = String("")
    ref p = scan._scan.value()[].projection.value()
    for i in range(len(p)):
        if i > 0:
            s += ","
        s += p[i]
    return s


def _under_project(plan: LogicalPlan) -> LogicalPlan:
    return plan._project.value()[].child[].copy()


# =============================================================================
# Project, Filter, Scan
# =============================================================================


def test_project_keeps_only_needed_exprs_and_their_columns() raises:
    """Project(s) over Project(a, b, c, d, a + b AS s) over Scan(a,b,c,d):
    the inner Project keeps only `a + b AS s` and the scan reads [a,b].

    Catches: the narrowing branch collecting columns from every expr (the
    scan keeps a,b,c,d); the dead pass-through exprs left in place (the
    inner Project keeps 5 exprs)."""
    var inner_exprs = _cols("a", "b", "c", "d")
    inner_exprs.append(Expr.alias(Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.col_ref("b")), "s"))
    var plan = LogicalPlan.project(_cols("s"), LogicalPlan.project(inner_exprs^, _scan("a,b,c,d")))
    var out = push_projections_down(plan^)
    var inner = _under_project(out)
    assert_equal(inner.tag, PLAN_PROJECT)
    assert_equal(len(inner._project.value()[].exprs), 1)
    assert_equal(inner.output_schema.field_name(0), String("s"))
    assert_equal(_proj(_under_project(inner)), String("a,b"))


def test_project_needed_by_nothing_keeps_every_expr() raises:
    """COUNT(*) over Project(a, b) over Scan(a,b,c): the aggregate needs no
    column, so the Project keeps both exprs and the scan reads [a,b].

    Catches: the empty-`needed` case taking the narrowing branch (an empty
    Project)."""
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, None, Optional(String("n"))))
    var plan = LogicalPlan.aggregate(ExprArray(), aggs^, LogicalPlan.project(_cols("a", "b"), _scan("a,b,c")))
    var out = push_projections_down(plan^)
    ref proj = out._aggregate.value()[].child[]
    assert_equal(len(proj._project.value()[].exprs), 2)
    assert_equal(_proj(proj._project.value()[].child[]), String("a,b"))


def test_filter_keeps_its_predicate_columns() raises:
    """Project(a) over Filter(c > 1) over Scan(a,b,c,d): the scan reads [a,c].

    Catches: the Filter arm passing only the parent's `needed` down (c is
    pruned and the predicate names a column the scan no longer reads)."""
    var plan = LogicalPlan.project(_cols("a"), LogicalPlan.filter(_gt("c", 1), _scan("a,b,c,d")))
    var out = push_projections_down(plan^)
    assert_equal(_proj(_under_project(out)._filter.value()[].child[]), String("a,c"))


def test_scan_keeps_its_pushed_filter_columns_and_fields() raises:
    """A scan with a pushed-down filter on d, a row count, table stats and a
    ROW source kind, under Project(a): the scan reads [a,d] and keeps its
    filter, row count, table stats and source kind.

    Catches: the scan's own filter columns ignored (d pruned); the rebuild
    dropping any of the other fields."""
    var stats = TableStats(40, List[String](), List[ColumnStats]())
    var src = ParquetSource("t.parquet", _schema(_names("a,b,c,d")))
    var scan = LogicalPlan.scan_from_source(
        SourceVariant(src^), _schema(_names("a,b,c,d")), None, Optional(_gt("d", 0)),
        Optional(40), Optional(stats^), SOURCE_KIND_ROW,
    )
    var out = push_projections_down(LogicalPlan.project(_cols("a"), scan^))
    var s = _under_project(out)
    assert_equal(_proj(s), String("a,d"))
    ref sd = s._scan.value()[]
    assert_true(Bool(sd.filter))
    assert_equal(sd.row_count.value(), 40)
    assert_equal(sd.table_stats.value().row_count, 40)
    assert_equal(sd.source_kind, SOURCE_KIND_ROW)


def test_scan_left_alone_when_all_or_none_needed() raises:
    """Project(a, b, c) over Scan(a,b,c) and COUNT(*) over Scan(a,b,c): both
    scans keep no projection (`*`).

    Catches: an all-columns projection written (a needless rebuild); an
    empty projection written (a scan that reads nothing)."""
    var all_needed = push_projections_down(LogicalPlan.project(_cols("a", "b", "c"), _scan("a,b,c")))
    assert_equal(_proj(_under_project(all_needed)), String("*"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, None, Optional(String("n"))))
    var none_needed = push_projections_down(LogicalPlan.aggregate(ExprArray(), aggs^, _scan("a,b,c")))
    assert_equal(_proj(none_needed._aggregate.value()[].child[]), String("*"))


def test_scan_without_a_schema_uses_its_output_schema() raises:
    """A scan node whose ScanData has no schema, under Project(a): it is
    rebuilt from its output schema and reads [a].

    Catches: the no-schema case reading an empty Optional."""
    var bare = LogicalPlan(PLAN_SCAN, _schema(_names("a,b")))
    bare._scan = OwnedPointer(
        ScanData(SourceVariant(ParquetSource("t.parquet", _schema(_names("a,b")))), None, None, None)
    )
    var out = push_projections_down(LogicalPlan.project(_cols("a"), bare^))
    assert_equal(_proj(_under_project(out)), String("a"))


# =============================================================================
# Sort, TopN, Limit, Distinct, Aggregate
# =============================================================================


def test_sort_topn_limit_distinct_keep_their_keys() raises:
    """Project(a) over Sort(b) / TopN(c) / Limit / Distinct([b]) /
    Distinct(*) over Scan(a,b,c,d): the scans read [a,b], [a,c], [a], [a,b]
    and `*`.

    Catches: the sort keys, the TopN keys or the Distinct columns not added
    (the key is pruned); DISTINCT * not keeping every child column."""
    var desc = List[Bool]()
    desc.append(False)
    var sort = push_projections_down(LogicalPlan.project(_cols("a"), LogicalPlan.sort(_keys("b"), desc.copy(), _scan("a,b,c,d"))))
    assert_equal(_proj(_under_project(sort)._sort.value()[].child[]), String("a,b"))
    var topn = push_projections_down(LogicalPlan.project(_cols("a"), LogicalPlan.topn(_keys("c"), desc.copy(), 3, _scan("a,b,c,d"))))
    assert_equal(_proj(_under_project(topn)._topn.value()[].child[]), String("a,c"))
    var limit = push_projections_down(LogicalPlan.project(_cols("a"), LogicalPlan.limit(3, _scan("a,b,c,d"))))
    assert_equal(_proj(_under_project(limit)._limit.value()[].child[]), String("a"))
    var dist = push_projections_down(LogicalPlan.project(_cols("a"), LogicalPlan.distinct(Optional(_keys("b")), _scan("a,b,c,d"))))
    assert_equal(_proj(_under_project(dist)._distinct.value()[].child[]), String("a,b"))
    var star = push_projections_down(LogicalPlan.project(_cols("a"), LogicalPlan.distinct(None, _scan("a,b,c,d"))))
    assert_equal(_proj(_under_project(star)._distinct.value()[].child[]), String("*"))


def test_aggregate_reads_group_keys_and_every_agg_slot() raises:
    """Aggregate(group a, sum(b)) over Scan(a,b,c,d) reads [a,b];
    Aggregate(corr(c, d), sum(e) with slot 2 = a and slot 3 = b) over
    Scan(a,b,c,d,e,f) reads [a,b,c,d,e].

    Catches: a slot (1, 2 or 3) not walked (its column is pruned)."""
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("b")), Optional(String("sb"))))
    var out = push_projections_down(LogicalPlan.aggregate(_cols("a"), aggs^, _scan("a,b,c,d")))
    assert_equal(_proj(out._aggregate.value()[].child[]), String("a,b"))

    var aggs2 = AggExprArray()
    aggs2.append(AggExpr(AGG_CORR, Optional(Expr.col_ref("c")), Optional(Expr.col_ref("d")), Optional(String("r"))))
    var wide = AggExpr(AGG_SUM, Optional(Expr.col_ref("e")), Optional(String("se")))
    wide.child2 = Optional(Expr.col_ref("a"))
    wide.child3 = Optional(Expr.col_ref("b"))
    aggs2.append(wide^)
    var out2 = push_projections_down(LogicalPlan.aggregate(ExprArray(), aggs2^, _scan("a,b,c,d,e,f")))
    assert_equal(_proj(out2._aggregate.value()[].child[]), String("a,b,c,d,e"))


# =============================================================================
# Join
# =============================================================================


def test_join_residual_columns_reach_each_side() raises:
    """Project(id) over Join(L(id,k,w_right,x), R(rid,k,w,z,y), id = rid,
    residual `k < k_right AND w_right > 0 AND z > 0`): L reads [id,k,w_right]
    and R reads [rid,k,w,z].

    Catches: the `_right` strip returning its input (R loses k and w); a
    residual column routed to the wrong side."""
    var residual = Expr.binary(
        BIN_AND,
        Expr.binary(BIN_AND, Expr.binary(BIN_LT, Expr.col_ref("k"), Expr.col_ref("k_right")), _gt("w_right", 0)),
        _gt("z", 0),
    )
    var join = LogicalPlan.join(
        _scan("id,k,w_right,x"), _scan("rid,k,w,z,y"), _keys("id"), _keys("rid"), JOIN_INNER,
        residual=Optional(OwnedPointer(residual^)),
    )
    var out = push_projections_down(LogicalPlan.project(_cols("id"), join^))
    ref jd = out._project.value()[].child[]._join.value()[]
    assert_equal(_proj(jd.left[]), String("id,k,w_right"))
    assert_equal(_proj(jd.right[]), String("rid,k,w,z"))


def test_join_collision_names_invert_and_keep_the_left_twin() raises:
    """Project(b_right, r, q_right) over Join(L(a,b,c,e), R(a,b,c,r,e), a = a):
    R reads [a,b,r] (`b_right` is R's `b`, `r` is R's own, `q_right` names
    nothing) and L reads [a,b] (b is kept on the left so R's b still collides
    and is still spelled `b_right`).

    Catches: the rename not inverted (R loses b); the collision twin not
    kept on the left (the join would spell R's column `b`)."""
    var join = LogicalPlan.join(_scan("a,b,c,e"), _scan("a,b,c,r,e"), _keys("a"), _keys("a"), JOIN_INNER)
    var out = push_projections_down(LogicalPlan.project(_cols("b_right", "r", "q_right"), join^))
    ref jd = out._project.value()[].child[]._join.value()[]
    assert_equal(_proj(jd.left[]), String("a,b"))
    assert_equal(_proj(jd.right[]), String("a,b,r"))


def test_semi_and_anti_joins_keep_no_twin() raises:
    """Project(a) over a SEMI and an ANTI Join(L(a,b,c), R(a,b,c), a = b): L
    reads [a] and R reads [b]; the INNER join of the same shape keeps the
    twin b on the left ([a,b]).

    Catches: the twin rule applied to SEMI or ANTI (their output is the left
    side only, so no right column can be renamed)."""
    var kinds = List[UInt8]()
    kinds.append(JOIN_SEMI)
    kinds.append(JOIN_ANTI)
    kinds.append(JOIN_INNER)
    for i in range(3):
        var join = LogicalPlan.join(_scan("a,b,c"), _scan("a,b,c"), _keys("a"), _keys("b"), kinds[i])
        var out = push_projections_down(LogicalPlan.project(_cols("a"), join^))
        ref jd = out._project.value()[].child[]._join.value()[]
        assert_equal(_proj(jd.right[]), String("b"))
        if kinds[i] == JOIN_INNER:
            assert_equal(_proj(jd.left[]), String("a,b"))
        else:
            assert_equal(_proj(jd.left[]), String("a"))


def test_identical_scans_are_narrowed_each_to_its_own_consumer() raises:
    """CROSS Join(sum(a) over Scan(t), sum(b) over Scan(t)): the two scans
    are the same subtree, and each reads only its own column: [a] and [b].

    Catches: identical subtrees widened to the union of their consumers'
    columns (both scans read [a,b])."""
    var la = AggExprArray()
    la.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("a")), Optional(String("sa"))))
    var ra = AggExprArray()
    ra.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("b")), Optional(String("sb"))))
    var join = LogicalPlan.join(
        LogicalPlan.aggregate(ExprArray(), la^, _scan("a,b,c")),
        LogicalPlan.aggregate(ExprArray(), ra^, _scan("a,b,c")),
        List[String](), List[String](), JOIN_CROSS,
    )
    var out = prune_columns(join^)
    ref jd = out._join.value()[]
    assert_equal(_proj(jd.left[]._aggregate.value()[].child[]), String("a"))
    assert_equal(_proj(jd.right[]._aggregate.value()[].child[]), String("b"))


# =============================================================================
# Helpers
# =============================================================================


def test_strip_right_suffix() raises:
    """`x_right` -> `x`; `_right` (6 bytes), `abc`, `x_rightz` and `x_Right`
    are returned unchanged.

    Catches: the length guard admitting a 6-byte name (`_right` -> ``); a
    suffix check that ignores a byte."""
    assert_equal(_strip_right_suffix_nr("x_right"), String("x"))
    assert_equal(_strip_right_suffix_nr("_right"), String("_right"))
    assert_equal(_strip_right_suffix_nr("abc"), String("abc"))
    assert_equal(_strip_right_suffix_nr("x_rightz"), String("x_rightz"))
    assert_equal(_strip_right_suffix_nr("x_Right"), String("x_Right"))
    assert_equal(_strip_right_suffix_nr("x_rigHt"), String("x_rigHt"))


def test_collect_referenced_columns_walks_every_node() raises:
    """`_collect_referenced_columns` (no caller in this package) over a plan
    with every node kind collects each operator's columns and both spellings
    of a `_right` residual name, and no scan output column."""
    var all = _names("s,dc,tk,lk,rk,r,fp,sf,g,c0,c1,x2,x3,pe,unused")
    var aggs = AggExprArray()
    var corr = AggExpr(AGG_CORR, Optional(Expr.col_ref("c0")), Optional(Expr.col_ref("c1")), Optional(String("k")))
    corr.child2 = Optional(Expr.col_ref("x2"))
    corr.child3 = Optional(Expr.col_ref("x3"))
    aggs.append(corr^)
    var right = LogicalPlan.aggregate(
        _cols("g"), aggs^, LogicalPlan.project(_cols("pe"), LogicalPlan.scan("t", SOURCE_PARQUET, _schema(all)))
    )
    var left = LogicalPlan.filter(
        _gt("fp", 0), LogicalPlan.scan("t", SOURCE_PARQUET, _schema(all), None, Optional(_gt("sf", 0)))
    )
    var join = LogicalPlan.join(
        left^, right^, _keys("lk"), _keys("rk"), JOIN_INNER,
        residual=Optional(OwnedPointer(_gt("r_right", 0))),
    )
    var desc = List[Bool]()
    desc.append(False)
    var plan = LogicalPlan.sort(
        _keys("s"), desc.copy(),
        LogicalPlan.limit(5, LogicalPlan.distinct(Optional(_keys("dc")), LogicalPlan.distinct(
            None, LogicalPlan.topn(_keys("tk"), desc.copy(), 2, join^)
        ))),
    )
    var cols = Set[String]()
    _collect_referenced_columns(plan, cols)
    var want = _names("s,dc,tk,lk,rk,r_right,r,fp,sf,g,c0,c1,x2,x3,pe")
    for i in range(len(want)):
        assert_true(want[i] in cols, "missing " + want[i])
    assert_equal(len(cols), len(want))
    assert_false(String("unused") in cols)


def main() raises:
    test_project_keeps_only_needed_exprs_and_their_columns()
    test_project_needed_by_nothing_keeps_every_expr()
    test_filter_keeps_its_predicate_columns()
    test_scan_keeps_its_pushed_filter_columns_and_fields()
    test_scan_left_alone_when_all_or_none_needed()
    test_scan_without_a_schema_uses_its_output_schema()
    test_sort_topn_limit_distinct_keep_their_keys()
    test_aggregate_reads_group_keys_and_every_agg_slot()
    test_join_residual_columns_reach_each_side()
    test_join_collision_names_invert_and_keep_the_left_twin()
    test_identical_scans_are_narrowed_each_to_its_own_consumer()
    test_semi_and_anti_joins_keep_no_twin()
    test_strip_right_suffix()
    test_collect_referenced_columns_walks_every_node()
    print("All optimizer_projection pushdown tests passed.")
