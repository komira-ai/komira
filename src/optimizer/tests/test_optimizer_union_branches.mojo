# =============================================================================
# test_optimizer_union_branches -- the driver's pass order runs on every branch
# of a UNION ALL
# =============================================================================
#
# No rewrite rule looks inside a Union, so the driver runs the whole pass order
# on each branch before its own passes (`optimizer_driver._optimize_union_
# branches`). Each test names the behaviour it holds. Plans are built in memory;
# no file is read.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_expr.agg_expr import AggExpr, AGG_SUM
from plan_expr.expr import Expr, BIN_EQ, BIN_MUL
from plan_expr.partition_expr import PartitionExpr
from plan_expr.scalar_value import ScalarValue
from plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    JOIN_INNER,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_UNION,
)
from optimizer.optimizer_config import OptimizerConfig
from optimizer.optimizer_scalar_deps import ScalarDepTable
from optimizer.optimizer_driver import (
    optimize,
    optimize_portable,
    PortableProfile,
    PORTABLE_PROFILE_V1,
    _optimize_union_branches,
)


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------


def _schema(names: List[String]) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], ArrowType.INT64, False))
    return sb.build()


def _scan(path: String, names: List[String]) -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema(names))


def _filtered(path: String, c0: String, c1: String) -> LogicalPlan:
    """Filter(c0 = 1) over a two-column scan of `path`."""
    var names: List[String] = [c0.copy(), c1.copy()]
    var pred = Expr.binary(
        BIN_EQ, Expr.col_ref(c0), Expr.literal(ScalarValue.from_int(1))
    )
    return LogicalPlan.filter(pred^, _scan(path, names))


def _union_of(var a: LogicalPlan, var b: LogicalPlan) -> LogicalPlan:
    var schema = a.output_schema.copy()
    var kids = List[OwnedPointer[LogicalPlan]]()
    kids.append(OwnedPointer(a^))
    kids.append(OwnedPointer(b^))
    return LogicalPlan.union(kids^, schema^)


def _filtered_union(c0: String, c1: String) -> LogicalPlan:
    return _union_of(
        _filtered("x.parquet", c0, c1), _filtered("y.parquet", c0, c1)
    )


def _render(p: LogicalPlan) -> String:
    var s = String("")
    p.write_to(s)
    return s


def _names(p: LogicalPlan) -> String:
    var s = String("")
    for i in range(p.output_schema.num_columns()):
        s += p.output_schema.field_name(i) + ","
    return s


def _count(p: LogicalPlan, what: Int) -> Int:
    """Over every node below `p`, through union branches and both join sides:
    `what` 0 counts Filter nodes, 1 counts scans that carry a pushed filter."""
    var here = 0
    if p.tag == PLAN_FILTER:
        if what == 0:
            here = 1
        return here + _count(p._filter.value()[].child[], what)
    if p.tag == PLAN_SCAN:
        if what == 1 and Bool(p._scan.value()[].filter):
            here = 1
        return here
    if p.tag == PLAN_PROJECT:
        return _count(p._project.value()[].child[], what)
    if p.tag == PLAN_AGGREGATE:
        return _count(p._aggregate.value()[].child[], what)
    if p.tag == PLAN_SORT:
        return _count(p._sort.value()[].child[], what)
    if p.tag == PLAN_LIMIT:
        return _count(p._limit.value()[].child[], what)
    if p.tag == PLAN_DISTINCT:
        return _count(p._distinct.value()[].child[], what)
    if p.tag == PLAN_TOPN:
        return _count(p._topn.value()[].child[], what)
    if p.tag == PLAN_PARTITION_BY:
        return _count(p._partition_by.value()[].child[], what)
    if p.tag == PLAN_PARTITION_TOPN:
        return _count(p._partition_topn.value()[].child[], what)
    if p.tag == PLAN_JOIN:
        return _count(p._join.value()[].left[], what) + _count(
            p._join.value()[].right[], what
        )
    if p.tag == PLAN_UNION:
        var n = len(p._union.value()[].children)
        for i in range(n):
            here += _count(p._union.value()[].children[i][], what)
        return here
    return 0


def _run(var p: LogicalPlan) raises -> LogicalPlan:
    var deps = ScalarDepTable()
    return optimize(p^, OptimizerConfig(), deps)


def _wrap(kind: Int, var child: LogicalPlan) raises -> LogicalPlan:
    """One single-child node of kind `kind` over `child`, whose columns are
    `a` and `b`."""
    var keys: List[String] = ["a"]
    var desc: List[Bool] = [False]
    if kind == 0:
        return LogicalPlan.filter(
            Expr.binary(
                BIN_EQ, Expr.col_ref("b"), Expr.literal(ScalarValue.from_int(2))
            ),
            child^,
        )
    if kind == 1:
        var pe = ExprArray()
        pe.append(Expr.col_ref("a"))
        return LogicalPlan.project(pe^, child^)
    if kind == 2:
        var gb = ExprArray()
        gb.append(Expr.col_ref("a"))
        var aggs = AggExprArray()
        aggs.append(
            AggExpr(AGG_SUM, Optional(Expr.col_ref("b")), Optional(String("s")))
        )
        return LogicalPlan.aggregate(gb^, aggs^, child^)
    if kind == 3:
        return LogicalPlan.sort(keys^, desc^, child^)
    if kind == 4:
        return LogicalPlan.limit(5, child^)
    if kind == 5:
        return LogicalPlan.distinct(None, child^)
    if kind == 6:
        return LogicalPlan.topn(keys^, desc^, 3, child^)
    if kind == 7:
        var pexprs = List[PartitionExpr]()
        pexprs.append(PartitionExpr.row_number())
        var pk: List[String] = ["a"]
        var ok: List[String] = ["b"]
        return LogicalPlan.partition_by(pk^, ok^, desc^, pexprs^, child^)
    var pk2: List[String] = ["a"]
    var sk: List[String] = ["b"]
    return LogicalPlan.partition_topn(pk2^, sk^, desc^, 2, child^)


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_a_filter_in_each_union_branch_is_pushed_into_its_scan() raises:
    """`optimize` over `Union(Filter(x), Filter(y))`: each branch ends as a
    scan carrying the predicate, the Union keeps its two branches and its
    column names."""
    var out = _run(_filtered_union("a", "b"))
    assert_true(out.tag == PLAN_UNION, "the root is still a Union")
    assert_equal(len(out._union.value()[].children), 2)
    assert_equal(_names(out), "a,b,")
    assert_equal(_count(out, 0), 0, _render(out))
    assert_equal(_count(out, 1), 2, _render(out))
    for i in range(2):
        var kid = out._union.value()[].children[i][].copy()
        assert_true(kid.tag == PLAN_SCAN, _render(kid))
        assert_equal(_names(kid), "a,b,")


def test_a_computed_aggregate_input_in_a_union_branch_is_materialized() raises:
    """`Union(SUM(a * b) GROUP BY g, ...)`: each branch's Aggregate sums a
    column `__agg_in_0` produced by a Project under it, so the branch can run
    on its own."""
    var kids = List[OwnedPointer[LogicalPlan]]()
    for p in range(2):
        var names: List[String] = ["g", "a", "b"]
        var gb = ExprArray()
        gb.append(Expr.col_ref("g"))
        var aggs = AggExprArray()
        aggs.append(
            AggExpr(
                AGG_SUM,
                Optional(Expr.binary(BIN_MUL, Expr.col_ref("a"), Expr.col_ref("b"))),
                Optional(String("s")),
            )
        )
        kids.append(
            OwnedPointer(
                LogicalPlan.aggregate(
                    gb^, aggs^, _scan("t" + String(p) + ".parquet", names)
                )
            )
        )
    var schema = kids[0][].output_schema.copy()
    var out = _run(LogicalPlan.union(kids^, schema^))
    assert_true(out.tag == PLAN_UNION)
    assert_equal(len(out._union.value()[].children), 2)
    assert_equal(_names(out), "g,s,")
    for i in range(2):
        var kid = out._union.value()[].children[i][].copy()
        assert_true(kid.tag == PLAN_AGGREGATE, _render(kid))
        assert_true(
            kid._aggregate.value()[].child[].tag == PLAN_PROJECT, _render(kid)
        )
        assert_true(_render(kid).find("__agg_in_0") >= 0, _render(kid))


def test_a_union_under_every_single_child_node_has_its_branches_optimized() raises:
    """A Union below a Filter, Project, Aggregate, Sort, Limit, Distinct, TopN,
    PartitionBy or PartitionTopN is reached: both its branch Filters end in
    scans. Only the Filter wrapper itself remains a Filter."""
    for kind in range(9):
        var plan = _wrap(kind, _filtered_union("a", "b"))
        var deps = ScalarDepTable()
        _optimize_union_branches(plan, OptimizerConfig(), deps)
        var r = _render(plan)
        assert_equal(_count(plan, 1), 2, String(kind) + ": " + r)
        if kind == 0:
            assert_equal(_count(plan, 0), 1, r)
        else:
            assert_equal(_count(plan, 0), 0, String(kind) + ": " + r)


def test_a_union_on_each_join_side_has_its_branches_optimized() raises:
    """A Join whose left and right inputs are both Unions: the four branch
    Filters end in scans."""
    var plan = LogicalPlan.join(
        _filtered_union("a", "b"),
        _filtered_union("c", "d"),
        ["a"],
        ["c"],
        JOIN_INNER,
    )
    var deps = ScalarDepTable()
    _optimize_union_branches(plan, OptimizerConfig(), deps)
    assert_equal(_count(plan, 1), 4, _render(plan))
    assert_equal(_count(plan, 0), 0, _render(plan))


def test_a_union_nested_in_a_branch_has_its_branches_optimized() raises:
    """`Union(Filter(x), Sort(Union(Filter(y), Filter(z))))`: the inner Union
    is inside an outer branch and its Filters are pushed too."""
    var inner = _union_of(
        _filtered("y.parquet", "a", "b"), _filtered("z.parquet", "a", "b")
    )
    var keys: List[String] = ["a"]
    var desc: List[Bool] = [False]
    var sorted_inner = LogicalPlan.sort(keys^, desc^, inner^)
    var out = _run(_union_of(_filtered("x.parquet", "a", "b"), sorted_inner^))
    assert_true(out.tag == PLAN_UNION)
    assert_equal(len(out._union.value()[].children), 2)
    assert_equal(_count(out, 0), 0, _render(out))
    assert_equal(_count(out, 1), 3, _render(out))


def test_the_portable_entry_optimizes_union_branches_too() raises:
    """`optimize_portable` shares the pass order, so a Union's branches are
    optimized there as well."""
    var out = optimize_portable(
        _filtered_union("a", "b"),
        OptimizerConfig(),
        PortableProfile(PORTABLE_PROFILE_V1),
    )
    assert_equal(_count(out, 0), 0, _render(out))
    assert_equal(_count(out, 1), 2, _render(out))


def test_a_plan_with_no_union_is_left_as_it_was() raises:
    """A scan and a Sort over a scan, neither holding a Union, come back with
    the same rendering and schema."""
    var names: List[String] = ["a", "b"]
    var keys: List[String] = ["a"]
    var desc: List[Bool] = [False]
    var plan = LogicalPlan.sort(keys^, desc^, _scan("t.parquet", names))
    var before = _render(plan)
    var out = _run(plan^)
    assert_equal(_render(out), before)
    assert_equal(_names(out), "a,b,")

    var lone = _scan("u.parquet", names)
    var lone_before = _render(lone)
    assert_equal(_render(_run(lone^)), lone_before)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
