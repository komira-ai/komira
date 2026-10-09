"""Identity elimination, project merge, bypass detection and late
materialization tests of `komira_optimizer.optimizer_projection`.

Each test names the defect it catches.
"""

from std.collections import Set
from std.memory import OwnedPointer
from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.schema import SchemaBuilder, Field, Schema
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    Expr,
    EXPR_ALIAS,
    EXPR_BINARY_OP,
    EXPR_COL_REF,
    BIN_ADD,
    BIN_MUL,
    BIN_GT,
)
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ScanData,
    ExprArray,
    AggExprArray,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    SOURCE_PARQUET,
    SOURCE_CSV,
    SOURCE_IN_MEMORY,
    JOIN_INNER,
)
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.source_variant import SourceVariant

from komira_optimizer.optimizer_projection import (
    eliminate_identity_projects,
    merge_projects,
    detect_bypass_columns,
    _collect_bypass_columns,
    late_materialize,
)


# =============================================================================
# Fixtures
# =============================================================================


def _schema(*names: String) -> Schema:
    var sb = SchemaBuilder()
    for n in names:
        sb.add_field(Field(n, ArrowType.INT64, nullable=False))
    return sb.build()


def _scan_ab() -> LogicalPlan:
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema("a", "b"))


def _scan_abc(source_type: UInt8 = SOURCE_PARQUET) -> LogicalPlan:
    return LogicalPlan.scan("t.parquet", source_type, _schema("a", "b", "c"))


def _cols(*names: String) -> ExprArray:
    var e = ExprArray()
    for n in names:
        e.append(Expr.col_ref(n))
    return e^


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _render(e: Expr) -> String:
    var s = String("")
    e.write_to(s)
    return s


def _one(a: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    return out^


def _wrap(kind: Int, var child: LogicalPlan) raises -> LogicalPlan:
    """Wrap `child` in one node of each kind the rules walk."""
    var desc = List[Bool]()
    desc.append(False)
    if kind == 0:
        return LogicalPlan.filter(Expr.binary(BIN_GT, Expr.col_ref("a"), _lit(0)), child^)
    if kind == 1:
        var aggs = AggExprArray()
        aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("b")), Optional(String("sb"))))
        return LogicalPlan.aggregate(_cols("a"), aggs^, child^)
    if kind == 2:
        return LogicalPlan.sort(_one("a"), desc^, child^)
    if kind == 3:
        return LogicalPlan.limit(5, child^)
    if kind == 4:
        return LogicalPlan.distinct(None, child^)
    if kind == 5:
        return LogicalPlan.topn(_one("a"), desc^, 5, child^)
    if kind == 6:
        return LogicalPlan.join(child^, _scan_ab(), _one("a"), _one("a"), JOIN_INNER)
    if kind == 7:
        return LogicalPlan.join(_scan_ab(), child^, _one("a"), _one("a"), JOIN_INNER)
    raise Error("test: unknown wrapper kind " + String(kind))


def _child_of(plan: LogicalPlan, kind: Int) -> LogicalPlan:
    if kind == 0:
        return plan._filter.value()[].child[].copy()
    if kind == 1:
        return plan._aggregate.value()[].child[].copy()
    if kind == 2:
        return plan._sort.value()[].child[].copy()
    if kind == 3:
        return plan._limit.value()[].child[].copy()
    if kind == 4:
        return plan._distinct.value()[].child[].copy()
    if kind == 5:
        return plan._topn.value()[].child[].copy()
    if kind == 6:
        return plan._join.value()[].left[].copy()
    return plan._join.value()[].right[].copy()


# =============================================================================
# eliminate_identity_projects
# =============================================================================


def test_identity_project_is_removed() raises:
    """Project(a, b) over Scan(a,b), and Project(a, b) over Project(a, b)
    over Scan(a,b), become the scan.

    Catches: the identity check rejecting an identity (nothing removed); the
    child not handled first (one Project of the two stays)."""
    var out = eliminate_identity_projects(LogicalPlan.project(_cols("a", "b"), _scan_ab()))
    assert_equal(out.tag, PLAN_SCAN)
    var nested = LogicalPlan.project(_cols("a", "b"), LogicalPlan.project(_cols("a", "b"), _scan_ab()))
    assert_equal(eliminate_identity_projects(nested^).tag, PLAN_SCAN)


def test_non_identity_projects_are_kept() raises:
    """Kept: Project(b, a) (order differs); Project(a, a + 1 AS b) (an expr
    that is not a column reference); Project(a) (fewer columns).

    Catches: the identity check ignoring column order, ignoring the
    expression kind, or ignoring the arity."""
    var swapped = eliminate_identity_projects(LogicalPlan.project(_cols("b", "a"), _scan_ab()))
    assert_equal(swapped.tag, PLAN_PROJECT)
    var exprs = _cols("a")
    exprs.append(Expr.alias(Expr.binary(BIN_ADD, Expr.col_ref("a"), _lit(1)), "b"))
    var computed = eliminate_identity_projects(LogicalPlan.project(exprs^, _scan_ab()))
    assert_equal(computed.tag, PLAN_PROJECT)
    var narrower = eliminate_identity_projects(LogicalPlan.project(_cols("a"), _scan_ab()))
    assert_equal(narrower.tag, PLAN_PROJECT)


def test_identity_projects_removed_under_every_node_kind() raises:
    """An identity Project under Filter, Aggregate, Sort, Limit, Distinct,
    TopN and either side of a Join is removed.

    Catches: any one recursion arm removed (that Project stays)."""
    for kind in range(8):
        var plan = _wrap(kind, LogicalPlan.project(_cols("a", "b"), _scan_ab()))
        var out = eliminate_identity_projects(plan^)
        assert_equal(_child_of(out, kind).tag, PLAN_SCAN, "kind " + String(kind))


# =============================================================================
# merge_projects
# =============================================================================


def test_stacked_projects_merge_into_one() raises:
    """Project(x * 2 AS y) over Project(a + 1 AS x) over Scan(a,b) becomes one
    Project `((a + 1) * 2) AS y` over the scan.

    Catches: the inner Project node kept (two Projects remain); the outer
    reference not substituted (the merged Project still reads x)."""
    var inner = ExprArray()
    inner.append(Expr.alias(Expr.binary(BIN_ADD, Expr.col_ref("a"), _lit(1)), "x"))
    var outer = ExprArray()
    outer.append(Expr.alias(Expr.binary(BIN_MUL, Expr.col_ref("x"), _lit(2)), "y"))
    var plan = LogicalPlan.project(outer^, LogicalPlan.project(inner^, _scan_ab()))
    var out = merge_projects(plan^)
    assert_equal(out.tag, PLAN_PROJECT)
    assert_equal(out._project.value()[].child[].tag, PLAN_SCAN)
    ref e = out._project.value()[].exprs[0]
    assert_equal(e.tag, EXPR_ALIAS)
    assert_equal(e.alias_name(), String("y"))
    ref mul = e.alias_child_ref()
    assert_equal(mul.tag, EXPR_BINARY_OP)
    assert_equal(mul.binary_op(), BIN_MUL)
    var rendered = _render(mul.binary_left_ref())
    assert_true(rendered.find("ColRef(a)") >= 0, rendered)
    assert_true(rendered.find("ColRef(x)") < 0, rendered)


def test_unsafe_merge_is_left_standing() raises:
    """Project(regexp_like(v)) over Project(s AS v) over Scan(s): the outer
    expression is one the substitution returns as built, reading a column the
    inner Project replaces, so both Projects stay.

    Catches: the merge done without asking `projects_merge_safely` (the
    merged Project would read `v`, which the scan does not have)."""
    var inner = ExprArray()
    inner.append(Expr.alias(Expr.col_ref("s"), "v"))
    var outer = ExprArray()
    outer.append(Expr.alias(Expr.regexp_like(Expr.col_ref("v"), "^Z"), "m"))
    var scan = LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema("s"))
    var out = merge_projects(LogicalPlan.project(outer^, LogicalPlan.project(inner^, scan^)))
    assert_equal(out._project.value()[].child[].tag, PLAN_PROJECT)


def test_projects_merge_under_every_node_kind() raises:
    """Project(a, b) over Project(a, b) under Filter, Aggregate, Sort, Limit,
    Distinct, TopN and either side of a Join merges into one Project.

    Catches: any one recursion arm removed (two Projects stay)."""
    for kind in range(8):
        var stacked = LogicalPlan.project(_cols("a", "b"), LogicalPlan.project(_cols("a", "b"), _scan_ab()))
        var out = merge_projects(_wrap(kind, stacked^))
        var proj = _child_of(out, kind)
        assert_equal(proj.tag, PLAN_PROJECT)
        assert_equal(proj._project.value()[].child[].tag, PLAN_SCAN, "kind " + String(kind))


# =============================================================================
# detect_bypass_columns
# =============================================================================


def test_detect_bypass_columns_returns_the_plan_unchanged() raises:
    """`detect_bypass_columns` returns the same plan; its collector finds the
    pass-through columns of every Project under every node kind: a bare
    column and a same-name alias of a column, but not a renaming alias or an
    alias of a computed expression."""
    var exprs = _cols("a")
    exprs.append(Expr.alias(Expr.col_ref("b"), "b"))
    exprs.append(Expr.alias(Expr.col_ref("c"), "z"))
    exprs.append(Expr.alias(Expr.binary(BIN_ADD, Expr.col_ref("a"), _lit(1)), "w"))
    var plan = LogicalPlan.project(exprs^, _scan_abc())
    var before = plan.structural_hash()
    var out = detect_bypass_columns(plan^)
    assert_equal(out.structural_hash(), before)
    var cols = Set[String]()
    _collect_bypass_columns(out, cols)
    assert_equal(len(cols), 2)
    assert_true(String("a") in cols and String("b") in cols)

    for kind in range(8):
        var wrapped = _wrap(kind, LogicalPlan.project(_cols("a", "b"), _scan_ab()))
        var found = Set[String]()
        _collect_bypass_columns(wrapped, found)
        assert_equal(len(found), 2, "kind " + String(kind))


# =============================================================================
# late_materialize
# =============================================================================


def _scan_proj(plan: LogicalPlan) -> Int:
    """Projection length of the scan under the Filter at `plan`, -1 if none."""
    ref sd = plan._filter.value()[].child[]._scan.value()[]
    if not sd.projection:
        return -1
    return len(sd.projection.value())


def test_late_materialize_narrows_a_pushable_filter_scan() raises:
    """Filter(a > 1) over a Parquet Scan(a,b,c): the scan projection becomes
    [a].

    Catches: the projection built from every schema column (stays
    [a,b,c]) or not written at all."""
    var out = late_materialize(LogicalPlan.filter(Expr.binary(BIN_GT, Expr.col_ref("a"), _lit(1)), _scan_abc()))
    assert_equal(_scan_proj(out), 1)
    assert_equal(out._filter.value()[].child[]._scan.value()[].projection.value()[0], String("a"))


def test_late_materialize_leaves_other_filters_alone() raises:
    """Unchanged: a CSV scan (its source rejects the push); a scan already
    projected to at most the filter columns; an in-memory scan under a
    predicate with no column; a scan whose only column is the filter column;
    a Filter over a Project.

    Catches: each guard removed."""
    var pred = Expr.binary(BIN_GT, Expr.col_ref("a"), _lit(1))
    var csv = late_materialize(LogicalPlan.filter(pred.copy(), _scan_abc(SOURCE_CSV)))
    assert_equal(_scan_proj(csv), -1)

    var projected = LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema("a", "b", "c"), Optional(_one("b")))
    var out2 = late_materialize(LogicalPlan.filter(pred.copy(), projected^))
    assert_equal(out2._filter.value()[].child[]._scan.value()[].projection.value()[0], String("b"))

    var mem = LogicalPlan.scan("m", SOURCE_IN_MEMORY, _schema("a", "b"))
    var out3 = late_materialize(LogicalPlan.filter(Expr.literal(ScalarValue.from_bool(True)), mem^))
    assert_equal(_scan_proj(out3), -1)

    var only_a = LogicalPlan.scan("t.parquet", SOURCE_PARQUET, _schema("a"))
    var out4 = late_materialize(LogicalPlan.filter(pred.copy(), only_a^))
    assert_equal(_scan_proj(out4), -1)

    var over_project = late_materialize(LogicalPlan.filter(pred.copy(), LogicalPlan.project(_cols("a", "b"), _scan_abc())))
    assert_equal(over_project._filter.value()[].child[].tag, PLAN_PROJECT)
    assert_false(Bool(over_project._filter.value()[].child[]._project.value()[].child[]._scan.value()[].projection))


def test_late_materialize_scan_without_a_schema() raises:
    """A Parquet scan node whose ScanData has no schema, under Filter(a > 1):
    the projection is built from the node's output schema, [a]."""
    var bare = LogicalPlan(PLAN_SCAN, _schema("a", "b"))
    bare._scan = OwnedPointer(ScanData(SourceVariant(ParquetSource("t.parquet", _schema("a", "b"))), None, None, None))
    var out = late_materialize(LogicalPlan.filter(Expr.binary(BIN_GT, Expr.col_ref("a"), _lit(1)), bare^))
    assert_equal(_scan_proj(out), 1)


def test_late_materialize_under_every_node_kind() raises:
    """Filter(a > 1) over a Parquet Scan(a,b,c) under Project, Filter,
    Aggregate, Sort, Limit, Distinct, TopN and either side of a Join is
    narrowed to [a].

    Catches: any one recursion arm removed."""
    var p = late_materialize(LogicalPlan.project(_cols("a"), LogicalPlan.filter(Expr.binary(BIN_GT, Expr.col_ref("a"), _lit(1)), _scan_abc())))
    assert_equal(_scan_proj(p._project.value()[].child[]), 1)
    for kind in range(8):
        var plan = _wrap(kind, LogicalPlan.filter(Expr.binary(BIN_GT, Expr.col_ref("a"), _lit(1)), _scan_abc()))
        var out = late_materialize(plan^)
        assert_equal(_scan_proj(_child_of(out, kind)), 1, "kind " + String(kind))


def main() raises:
    test_identity_project_is_removed()
    test_non_identity_projects_are_kept()
    test_identity_projects_removed_under_every_node_kind()
    test_stacked_projects_merge_into_one()
    test_unsafe_merge_is_left_standing()
    test_projects_merge_under_every_node_kind()
    test_detect_bypass_columns_returns_the_plan_unchanged()
    test_late_materialize_narrows_a_pushable_filter_scan()
    test_late_materialize_leaves_other_filters_alone()
    test_late_materialize_scan_without_a_schema()
    test_late_materialize_under_every_node_kind()
    print("All optimizer_projection merge/identity tests passed.")
