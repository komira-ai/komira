"""The projection rules of `komira_optimizer.optimizer_projection` over
UDF-carrying nodes.

A typed UDF rides on a Project (`map_udf`), a Filter (`filter_udf`) or an
Aggregate (`agg_udf`) as a `UdfData` payload. Its `input_columns` are the
columns the function reads: its read set, present in this IR on every UDF
(an empty list reads no column). The node's own expressions are the
placeholders the UDF path stamps; the UDF fixes the node's output columns.

So every projection rule must (1) keep the payload on the node, (2) keep the
UDF's input columns live below it, and (3) never reshape a UDF Project's
output (narrow, merge or eliminate it). Each test names the rule site it
pins and the defect it catches.
"""

from std.collections import Set
from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import SchemaBuilder, Field, Schema
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_GT
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.udf_data import (
    UdfData,
    UDF_KIND_MAP,
    UDF_KIND_FILTER,
    UDF_KIND_AGG,
)
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    SOURCE_PARQUET,
)

from komira_optimizer.optimizer_projection import (
    push_projections_down,
    eliminate_identity_projects,
    merge_projects,
    late_materialize,
    _collect_referenced_columns,
)


# =============================================================================
# Fixtures
# =============================================================================


def _scan(csv: String) raises -> LogicalPlan:
    var sb = SchemaBuilder()
    for part in csv.split(","):
        sb.add_field(Field(String(part), ArrowType.INT64, nullable=False))
    return LogicalPlan.scan("t.parquet", SOURCE_PARQUET, sb.build())


def _cols(*names: String) -> ExprArray:
    var e = ExprArray()
    for n in names:
        e.append(Expr.col_ref(n))
    return e^


def _udf(kind: UInt8, *reads: String) -> OwnedPointer[UdfData]:
    var ic = List[Tuple[String, UInt8]]()
    for r in reads:
        ic.append((String(r), UInt8(2)))
    var oc = List[Tuple[String, UInt8]]()
    oc.append(("y", UInt8(2)))
    return OwnedPointer(
        UdfData(
            kind=kind,
            name=String("f"),
            input_columns=ic^,
            output_columns=oc^,
            operator_factory_id=UInt32(7101),
            call_site_salt=UInt32(3),
            registered_handle_id=Optional(Int(4)),
        )
    )


def _count_star() -> AggExprArray:
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_COUNT, None, Optional(String("n"))))
    return aggs^


def _gt(col: String, v: Int) -> Expr:
    return Expr.binary(BIN_GT, Expr.col_ref(col), Expr.literal(ScalarValue.from_int(v)))


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


def _count_udfs(plan: LogicalPlan) raises -> Int:
    """UDF-carrying nodes in a tree of Filter / Project / Aggregate / Scan."""
    var n = 1 if plan.has_udf() else 0
    if plan.tag == PLAN_FILTER:
        n += _count_udfs(plan._filter.value()[].child[])
    elif plan.tag == PLAN_PROJECT:
        n += _count_udfs(plan._project.value()[].child[])
    elif plan.tag == PLAN_AGGREGATE:
        n += _count_udfs(plan._aggregate.value()[].child[])
    return n


# =============================================================================
# push_projections_down: the Project arm (komira#1462)
# =============================================================================


def test_udf_project_keeps_its_udf_and_its_read_set_reaches_the_scan() raises:
    """Project(a) over Project[udf reads d,f](a, b) over Scan(a..h).

    The scan reads a,b,d,f (the UDF's read set plus the Project's other
    columns) and the UDF Project survives with both exprs.

    Catches: the UDF's input columns left out of what the child must supply
    (the scan reads a,b and the UDF's d,f are pruned); the parent's `needed`
    narrowing a UDF Project, which rebuilds it with the non-UDF factory (the
    UDF is gone and the Project keeps 1 expr)."""
    var inner = LogicalPlan.project_with_udf(_cols("a", "b"), _scan("a,b,c,d,e,f,g,h"), _udf(UDF_KIND_MAP, "d", "f"))
    assert_equal(_count_udfs(inner), 1, "VACUOUS: the fixture carries no UDF")
    var out = push_projections_down(LogicalPlan.project(_cols("a"), inner^))
    assert_equal(_count_udfs(out), 1, "the UDF was dropped from the Project")
    ref udf_proj = out._project.value()[].child[]
    assert_true(udf_proj.has_udf())
    assert_equal(len(udf_proj._project.value()[].exprs), 2, "a UDF Project's output was narrowed")
    assert_equal(_proj(udf_proj._project.value()[].child[]), String("a,b,d,f"))


def test_udf_project_needed_by_nothing_keeps_its_exprs_and_read_set() raises:
    """COUNT(*) over Project[udf reads c](a) over Scan(a,b,c,d).

    The aggregate needs no column, yet the UDF Project keeps its expr and its
    UDF, and the scan reads a,c.

    Catches: the empty-`needed` prune applied to a UDF Project (its exprs go
    to zero and the UDF is rebuilt away)."""
    var udf_proj = LogicalPlan.project_with_udf(_cols("a"), _scan("a,b,c,d"), _udf(UDF_KIND_MAP, "c"))
    var out = push_projections_down(LogicalPlan.aggregate(ExprArray(), _count_star(), udf_proj^))
    assert_equal(_count_udfs(out), 1, "the UDF was dropped from the Project")
    ref p = out._aggregate.value()[].child[]
    assert_equal(len(p._project.value()[].exprs), 1)
    assert_equal(_proj(p._project.value()[].child[]), String("a,c"))


def test_udf_with_an_empty_read_set_takes_zero_columns_from_its_child() raises:
    """Project[udf reads nothing](lit(1) AS y) over Project(a, b) over
    Scan(a,b,c).

    The UDF reads no column, so the Project below it supplies zero columns:
    it is pruned to zero exprs (a zero-column output whose rows still carry
    the row count). The scan reads one column, `a`: a scan cannot express a
    zero-column read (a source reads an empty projection as every column),
    so it keeps the narrowest. The same holds with the UDF straight over the
    scan.

    Catches: an empty `needed` set treated as keep-every-column (the inner
    Project keeps a, b, so an empty read set cannot be expressed); the scan
    left unprojected (`*`, every column read) below or right under the
    UDF."""
    var placeholder = ExprArray()
    placeholder.append(Expr.alias(Expr.literal(ScalarValue.from_int(1)), "y"))
    var plan = LogicalPlan.project_with_udf(
        placeholder^, LogicalPlan.project(_cols("a", "b"), _scan("a,b,c")), _udf(UDF_KIND_MAP)
    )
    var out = push_projections_down(plan^)
    assert_equal(_count_udfs(out), 1)
    ref below = out._project.value()[].child[]
    assert_equal(below.tag, PLAN_PROJECT)
    assert_equal(len(below._project.value()[].exprs), 0, "the empty read set kept columns")
    assert_equal(below.output_schema.num_columns(), 0)
    assert_equal(_proj(below._project.value()[].child[]), String("a"))
    var direct_placeholder = ExprArray()
    direct_placeholder.append(Expr.alias(Expr.literal(ScalarValue.from_int(1)), "y"))
    var direct = push_projections_down(
        LogicalPlan.project_with_udf(direct_placeholder^, _scan("a,b,c"), _udf(UDF_KIND_MAP))
    )
    assert_equal(_count_udfs(direct), 1)
    assert_equal(_proj(direct._project.value()[].child[]), String("a"))


def test_narrowed_project_keeps_its_cse_flag() raises:
    """Project(s) over a CSE-introduced Project(a, b, a + b AS s) over
    Scan(a,b,c): the narrowed Project keeps `is_cse_introduced`.

    Catches: the narrowing rebuild dropping the Project's other payload
    fields (predicate pushdown would then push a `_cse_*` reference below the
    Project that materializes it)."""
    var exprs = _cols("a", "b")
    exprs.append(Expr.alias(Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.col_ref("b")), "s"))
    var inner = LogicalPlan.project(exprs^, _scan("a,b,c"), is_cse_introduced=True)
    var out = push_projections_down(LogicalPlan.project(_cols("s"), inner^))
    ref narrowed = out._project.value()[].child[]
    assert_equal(len(narrowed._project.value()[].exprs), 1, "VACUOUS: the narrowing path did not run")
    assert_true(narrowed._project.value()[].is_cse_introduced, "the narrowing rebuild dropped is_cse_introduced")


def test_narrowed_plain_project_stays_not_cse_introduced() raises:
    """Project(s) over a plain Project(a, b, a + b AS s) over Scan(a,b,c):
    the narrowed Project keeps `is_cse_introduced` False.

    Catches: the narrowing rebuild setting the flag regardless of the
    source (every narrowed plain Project would become a predicate-pushdown
    barrier)."""
    var exprs = _cols("a", "b")
    exprs.append(Expr.alias(Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.col_ref("b")), "s"))
    var inner = LogicalPlan.project(exprs^, _scan("a,b,c"))
    var out = push_projections_down(LogicalPlan.project(_cols("s"), inner^))
    ref narrowed = out._project.value()[].child[]
    assert_equal(len(narrowed._project.value()[].exprs), 1, "VACUOUS: the narrowing path did not run")
    assert_false(narrowed._project.value()[].is_cse_introduced, "the narrowing rebuild set is_cse_introduced")


# =============================================================================
# push_projections_down: the Filter and Aggregate arms (same family)
# =============================================================================


def test_udf_filter_read_set_reaches_the_scan() raises:
    """Project(b) over Filter[udf reads c](lit(true)) over Scan(a,b,c,d): the
    scan reads b,c and the Filter keeps its UDF.

    Catches: the Filter arm passing only its predicate's columns down (the
    placeholder `lit(true)` reads none, so the UDF's c is pruned)."""
    var f = LogicalPlan.filter_with_udf(
        Expr.literal(ScalarValue.from_bool(True)), _scan("a,b,c,d"), _udf(UDF_KIND_FILTER, "c")
    )
    var out = push_projections_down(LogicalPlan.project(_cols("b"), f^))
    assert_equal(_count_udfs(out), 1)
    assert_equal(_proj(out._project.value()[].child[]._filter.value()[].child[]), String("b,c"))


def test_udf_aggregate_read_set_reaches_the_scan() raises:
    """Aggregate[udf reads c](group a; COUNT(*)) over Scan(a,b,c,d): the
    scan reads a,c and the Aggregate keeps its UDF.

    Catches: the Aggregate arm collecting only group keys and builtin agg
    arguments (the UDF's c is pruned)."""
    var agg = LogicalPlan.aggregate_with_udf(_cols("a"), _count_star(), _scan("a,b,c,d"), _udf(UDF_KIND_AGG, "c"))
    var out = push_projections_down(agg^)
    assert_equal(_count_udfs(out), 1)
    assert_equal(_proj(out._aggregate.value()[].child[]), String("a,c"))


# =============================================================================
# eliminate_identity_projects, merge_projects, late_materialize
# =============================================================================


def test_identity_shaped_udf_project_is_not_eliminated() raises:
    """Project[udf reads a](a, b) over Scan(a,b): its placeholders match the
    child's columns position by position, yet the node stays.

    Catches: identity elimination replacing a UDF Project by its child (the
    UDF is gone and the plan returns the scan's rows unchanged)."""
    var plan = LogicalPlan.project_with_udf(_cols("a", "b"), _scan("a,b"), _udf(UDF_KIND_MAP, "a"))
    var out = eliminate_identity_projects(plan^)
    assert_equal(out.tag, PLAN_PROJECT)
    assert_equal(_count_udfs(out), 1, "identity elimination dropped the UDF Project")


def test_identity_project_below_a_udf_project_is_eliminated() raises:
    """Project[udf reads a](a, b) over an identity Project(a, b) over
    Scan(a,b): the identity Project goes, the UDF Project stays on the scan.

    Catches: the UDF guard returning before the recursion into the child (a
    UDF Project would stop identity elimination anywhere below it)."""
    var plan = LogicalPlan.project_with_udf(
        _cols("a", "b"), LogicalPlan.project(_cols("a", "b"), _scan("a,b")), _udf(UDF_KIND_MAP, "a")
    )
    var out = eliminate_identity_projects(plan^)
    assert_equal(_count_udfs(out), 1)
    assert_equal(out._project.value()[].child[].tag, PLAN_SCAN, "the identity Project below the UDF stayed")


def test_merge_leaves_a_udf_project_below_a_plain_project() raises:
    """Project(a) over Project[udf reads b](a, b) over Scan(a,b): no merge.

    Catches: the merge folding the inner UDF Project away (the UDF is gone)."""
    var inner = LogicalPlan.project_with_udf(_cols("a", "b"), _scan("a,b"), _udf(UDF_KIND_MAP, "b"))
    var out = merge_projects(LogicalPlan.project(_cols("a"), inner^))
    assert_equal(_count_udfs(out), 1, "the merge dropped the inner UDF Project")
    assert_equal(out._project.value()[].child[].tag, PLAN_PROJECT)


def test_merge_leaves_a_udf_project_above_a_plain_project() raises:
    """Project[udf reads c](c) over Project(a, a + b AS c) over Scan(a,b): no
    merge.

    Catches: the merge substituting the outer UDF Project's exprs and moving
    it onto the scan, where the UDF's read set names a column `c` that only
    the folded Project computed."""
    var inner_exprs = _cols("a")
    inner_exprs.append(Expr.alias(Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.col_ref("b")), "c"))
    var inner = LogicalPlan.project(inner_exprs^, _scan("a,b"))
    var out = merge_projects(LogicalPlan.project_with_udf(_cols("c"), inner^, _udf(UDF_KIND_MAP, "c")))
    assert_true(out.has_udf())
    assert_equal(out._project.value()[].child[].tag, PLAN_PROJECT, "the merge moved a UDF Project onto the scan")


def test_plain_projects_below_a_udf_project_merge() raises:
    """Project[udf reads a](a) over Project(a, b) over Project(a, b, c) over
    Scan(a,b,c,d): the two plain Projects merge into one on the scan.

    Catches: the UDF guard returning before the recursion into the child (a
    UDF Project would stop Project merging anywhere below it)."""
    var lower = LogicalPlan.project(_cols("a", "b", "c"), _scan("a,b,c,d"))
    var mid = LogicalPlan.project(_cols("a", "b"), lower^)
    var out = merge_projects(LogicalPlan.project_with_udf(_cols("a"), mid^, _udf(UDF_KIND_MAP, "a")))
    assert_true(out.has_udf())
    ref merged = out._project.value()[].child[]
    assert_equal(merged.tag, PLAN_PROJECT)
    assert_equal(merged._project.value()[].child[].tag, PLAN_SCAN, "the plain Projects below the UDF did not merge")


def test_late_materialize_keeps_a_udf_filters_read_set() raises:
    """Filter[udf reads c](a > 1) over a Parquet Scan(a,b,c,d): the scan
    projection becomes a,c.

    Catches: late materialization narrowing the scan to the predicate's
    columns alone (the UDF's c is pruned)."""
    var f = LogicalPlan.filter_with_udf(_gt("a", 1), _scan("a,b,c,d"), _udf(UDF_KIND_FILTER, "c"))
    var out = late_materialize(f^)
    assert_equal(_proj(out._filter.value()[].child[]), String("a,c"))


def test_collect_referenced_columns_reads_every_udf_carrier() raises:
    """Aggregate[udf reads g](group a) over Project[udf reads p](a) over
    Filter[udf reads q](lit(true)) over Scan(a,g,p,q,z): the collected set is
    {a, g, p, q}.

    Catches: any of the three carriers' input columns left out."""
    var f = LogicalPlan.filter_with_udf(
        Expr.literal(ScalarValue.from_bool(True)), _scan("a,g,p,q,z"), _udf(UDF_KIND_FILTER, "q")
    )
    var p = LogicalPlan.project_with_udf(_cols("a"), f^, _udf(UDF_KIND_MAP, "p"))
    var agg = LogicalPlan.aggregate_with_udf(_cols("a"), AggExprArray(), p^, _udf(UDF_KIND_AGG, "g"))
    var cols = Set[String]()
    _collect_referenced_columns(agg, cols)
    var want = List[String]()
    want.append("a")
    want.append("g")
    want.append("p")
    want.append("q")
    for i in range(len(want)):
        assert_true(want[i] in cols, String("missing ") + want[i])
    assert_equal(len(cols), 4)


def main() raises:
    var suite = TestSuite()
    suite.test[test_udf_project_keeps_its_udf_and_its_read_set_reaches_the_scan]()
    suite.test[test_udf_project_needed_by_nothing_keeps_its_exprs_and_read_set]()
    suite.test[test_udf_with_an_empty_read_set_takes_zero_columns_from_its_child]()
    suite.test[test_narrowed_project_keeps_its_cse_flag]()
    suite.test[test_narrowed_plain_project_stays_not_cse_introduced]()
    suite.test[test_udf_filter_read_set_reaches_the_scan]()
    suite.test[test_udf_aggregate_read_set_reaches_the_scan]()
    suite.test[test_identity_shaped_udf_project_is_not_eliminated]()
    suite.test[test_identity_project_below_a_udf_project_is_eliminated]()
    suite.test[test_merge_leaves_a_udf_project_below_a_plain_project]()
    suite.test[test_merge_leaves_a_udf_project_above_a_plain_project]()
    suite.test[test_plain_projects_below_a_udf_project_merge]()
    suite.test[test_late_materialize_keeps_a_udf_filters_read_set]()
    suite.test[test_collect_referenced_columns_reads_every_udf_carrier]()
    suite^.run()
