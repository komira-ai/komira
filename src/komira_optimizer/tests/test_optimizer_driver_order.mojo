# =============================================================================
# test_optimizer_driver_order -- the order of adjacent passes in
# `optimizer_driver.optimize`, pinned pair by pair
# =============================================================================
#
# `test_optimizer_driver_passes.mojo` and `_passes_late.mojo` show that each
# pass changes the plan at its step. This file shows, for a pair of adjacent
# pass calls, that running them in the other order gives a different plan:
# each test is one plan that the two orders optimize differently, compared as
# a whole render (and, where the render omits the field, the field itself).
#
# Some pairs pin the reference pipeline's order where the other order would
# make a better plan (an attached Hive predicate, a SEMI join, an inferred
# IN list). The test says so; changing the order is then a visible edit, as
# for the two positions komira#1293 records.
#
# Pairs whose two orders give the same plan on every plan tried are argued in
# the pull request that added this file, not tested here.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder, RecordBatch
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT, AGG_SUM, AGG_MAX
from komira_plan_expr.expr import (
    Expr, WhenCaseData, BIN_ADD, BIN_SUB, BIN_MUL, BIN_EQ, BIN_GT, BIN_AND, BIN_OR, UN_NOT,
)
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan, ExprArray, AggExprArray, SOURCE_PARQUET, CORR_KIND_SCALAR, CORR_KIND_EXISTS,
    JOIN_INNER, JOIN_SEMI, JOIN_CROSS, JOIN_ALGO_AUTO,
)
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.source_variant import SourceVariant
from komira_scan_source.in_memory_source import InMemorySource
from komira_optimizer.optimizer_config import OptimizerConfig
from komira_optimizer.optimizer_scalar_deps import ScalarDepTable
from komira_optimizer.optimizer_driver import optimize


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------


def _schema(names: List[String]) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], ArrowType.INT64, False))
    return sb.build()


def _scan(path: String, names: List[String], rows: Optional[Int] = None) -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema(names), None, None, rows)


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _c(n: String) -> Expr:
    return Expr.col_ref(n)


def _eq(c: String, v: Int) -> Expr:
    return Expr.binary(BIN_EQ, _c(c), _lit(v))


def _gt(c: String, v: Int) -> Expr:
    return Expr.binary(BIN_GT, _c(c), _lit(v))


def _ceq(a: String, b: String) -> Expr:
    return Expr.binary(BIN_EQ, _c(a), _c(b))


def _and(var a: Expr, var b: Expr) -> Expr:
    return Expr.binary(BIN_AND, a^, b^)


def _or(var a: Expr, var b: Expr) -> Expr:
    return Expr.binary(BIN_OR, a^, b^)


def _l1(a: String) -> List[String]:
    var o = List[String]()
    o.append(a)
    return o^


def _cols(var names: List[String]) -> ExprArray:
    var pe = ExprArray()
    for i in range(len(names)):
        pe.append(Expr.col_ref(names[i]))
    return pe^


def _lines(l: List[String]) -> String:
    """A render: one line per node, each ending in a newline."""
    var s = String("")
    for i in range(len(l)):
        s += l[i] + "\n"
    return s^


def _render(p: LogicalPlan) -> String:
    var s = String("")
    p.write_to(s)
    return s^


def _run(var p: LogicalPlan) raises -> LogicalPlan:
    var deps = ScalarDepTable()
    return optimize(p^, OptimizerConfig(), deps)


def _when_eq_1(c: String) -> Expr:
    """(CASE WHEN c > 1 THEN 1 ELSE 0 END) = 1: a predicate that halts OR
    factoring and that CSE can hoist."""
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(_gt(c, 1), _lit(1)))
    return Expr.binary(BIN_EQ, Expr.when(cases^, _lit(0)), _lit(1))


def _sum(key: String, var arg: Expr, oname: String, var child: LogicalPlan) -> LogicalPlan:
    """SUM(arg) AS oname, grouped by `key` (no grouping when `key` is empty)."""
    var gb = ExprArray()
    if key != "":
        gb.append(_c(key))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(arg^), Optional(oname)))
    return LogicalPlan.aggregate(gb^, aggs^, child^)


def _unique_c() -> LogicalPlan:
    """SUM(cy) AS s_cx GROUP BY cx over C(cx, cy), 10 rows: unique on cx."""
    var n: List[String] = ["cx", "cy"]
    return _sum("cx", _c("cy"), "s_cx", _scan("C", n, 10))


def _a_join_unique_c() -> LogicalPlan:
    """A(ax, ay) 1000 rows INNER JOIN `_unique_c()` ON ax = cx."""
    var an: List[String] = ["ax", "ay"]
    return LogicalPlan.join(_scan("A", an, 1000), _unique_c(), _l1("ax"), _l1("cx"), JOIN_INNER)


def _hive_scan() raises -> LogicalPlan:
    """Lazily listed (dir-scan) Hive scan over d/, partition column p."""
    var pc = List[Field]()
    pc.append(Field("p", ArrowType.INT64, nullable=False))
    var data: List[String] = ["v"]
    var full: List[String] = ["v", "p"]
    var src = ParquetSource.dir_scan_hive("d/", _schema(data), pc^)
    return LogicalPlan.scan_from_source(SourceVariant(src^), _schema(full))


def _side_join(var residual: Expr, var left_on: List[String], var right_on: List[String]) -> LogicalPlan:
    """t(a, ta) INNER JOIN u(b, ub) with `residual` as its `predicate=`."""
    var jt: List[String] = ["a", "ta"]
    var ju: List[String] = ["b", "ub"]
    return LogicalPlan.join(
        _scan("t.parquet", jt), _scan("u.parquet", ju), left_on^, right_on^,
        JOIN_INNER, JOIN_ALGO_AUTO, Optional[OwnedPointer[Expr]](OwnedPointer(residual^)),
    )


# -----------------------------------------------------------------------------
# Steps 1-5: scans, subqueries, join predicates
# -----------------------------------------------------------------------------


def test_hive_predicates_attach_before_scalar_decorrelation() raises:
    """`c_acctbal > (SELECT SUM(v) FROM d/ WHERE p = 1)` over customer, with
    d/ a dir-scan Hive scan: the subquery's scan is inside an expression when
    `attach_hive_predicate` runs, so it gets no partition predicate and keeps
    `p = 1` as its filter after decorrelation makes it a CROSS join's side.
    This pins the reference order: the other order attaches the predicate.

    Defect caught: `attach_hive_predicate` moved after
    `scalar_subquery_decorrelate`. The decorrelated scan then carries a
    one-constraint Hive predicate and `projection=[v]` instead of the filter."""
    var inner = _sum("", _c("v"), "hv", LogicalPlan.filter(_eq("p", 1), _hive_scan()))
    var cn: List[String] = ["c_custkey", "c_acctbal"]
    var pred = Expr.binary(BIN_GT, _c("c_acctbal"), Expr.correlated_subquery(inner^, List[String](), CORR_KIND_SCALAR))
    assert_equal(_render(_run(LogicalPlan.filter(pred^, _scan("customer.parquet", cn)))), _want_hive_in_subquery())


def test_flattened_side_qualified_residuals_are_decomposed() raises:
    """`EXISTS (orders WHERE o_custkey = outer.c_custkey AND o_v > outer.c_v)`
    with the outer references side-qualified, as the binder marks them:
    flattening makes a SEMI join keyed on the equality with a side-qualified
    residual, and `join_predicate_decompose` rewrites that residual to plain
    column names.

    Defect caught: `join_predicate_decompose` before
    `flatten_dependent_joins`. The residual keeps `right.o_v` and `left.c_v`,
    names no joined row has."""
    var cn: List[String] = ["c_custkey", "c_v"]
    var on: List[String] = ["o_orderkey", "o_custkey", "o_v"]
    var inner = LogicalPlan.filter(
        _and(Expr.binary(BIN_EQ, _c("o_custkey"), Expr.left("c_custkey")), Expr.binary(BIN_GT, _c("o_v"), Expr.left("c_v"))),
        _scan("orders.parquet", on, 100000),
    )
    var corr: List[String] = ["c_custkey", "c_v"]
    var pred = Expr.correlated_subquery(inner^, corr^, CORR_KIND_EXISTS)
    assert_equal(_render(_run(LogicalPlan.filter(pred^, _scan("customer.parquet", cn, 10)))), _want_exists_residual())


def test_join_predicates_are_decomposed_before_residual_pushdown() raises:
    """`left.a = right.b AND left.ta > 5` as a join's `predicate=`: decomposed
    first, `a = b` becomes the key and the plain `ta > 5` moves into the t
    scan. With keys `ta = ub` and `left.a = right.b AND right.ub > 5`, the
    `ub > 5` conjunct moves into the u scan.

    Defect caught: `join_predicate_decompose` after
    `push_join_residual_to_side`. The first join keeps `ta > 5` as its
    residual; the second pushes a Filter on `right.ub`, a name the u scan does
    not have."""
    var r1 = _and(Expr.binary(BIN_EQ, Expr.left("a"), Expr.right("b")), Expr.binary(BIN_GT, Expr.left("ta"), _lit(5)))
    assert_equal(_render(_run(_side_join(r1^, List[String](), List[String]()))), _want_residual_left())
    var r2 = _and(Expr.binary(BIN_EQ, Expr.left("a"), Expr.right("b")), Expr.binary(BIN_GT, Expr.right("ub"), _lit(5)))
    assert_equal(_render(_run(_side_join(r2^, _l1("ta"), _l1("ub")))), _want_residual_right())


# -----------------------------------------------------------------------------
# Steps 6-9: expressions and filters
# -----------------------------------------------------------------------------


def test_constants_fold_before_predicates_are_simplified() raises:
    """`NOT ((1 = 1) AND NOT (a = 1))`: folding turns it into
    `NOT NOT (a = 1)`, and simplification then removes the double negation,
    so the scan filter is `a = 1`.

    Defect caught: `simplify_predicates` before `fold_constants`. The
    simplification gate finds nothing to do on the input, folding then leaves
    `NOT NOT (a = 1)` as the scan's Filter."""
    var x = Expr.unary(UN_NOT, _and(Expr.binary(BIN_EQ, _lit(1), _lit(1)), Expr.unary(UN_NOT, _eq("a", 1))))
    var n: List[String] = ["a", "b"]
    assert_equal(_render(_run(LogicalPlan.filter(x^, _scan("s.parquet", n)))), _want_not_fold())


def test_cse_runs_before_the_in_list_rewrite() raises:
    """`Project[a, (a + b) = 1 OR (a + b) = 2 AS x]`: CSE names `a + b`, and
    the IN rewrite then sees a chain of equalities on one named column and
    makes it `InList(_cse_*, [1, 2])`.

    Defect caught: `rewrite_in_clauses` before
    `eliminate_common_subexpressions` (the verifier's o7). The IN rewrite
    sees `(a + b) = 1`, not a column equality, and the OR of two EQs stays."""
    var n: List[String] = ["a", "b"]
    var ab = Expr.binary(BIN_ADD, _c("a"), _c("b"))
    var pe = ExprArray()
    pe.append(_c("a"))
    pe.append(Expr.alias(_or(Expr.binary(BIN_EQ, ab.copy(), _lit(1)), Expr.binary(BIN_EQ, ab.copy(), _lit(2))), "x"))
    assert_equal(_render(_run(LogicalPlan.project(pe^, _scan("s.parquet", n)))), _want_cse_in())


def test_symmetric_or_runs_before_the_second_or_factoring() raises:
    """`(W AND a = 1 AND b = 2) OR (W AND a = 2 AND b = 1)`, W a CASE/WHEN
    comparison: in step 9 each branch has three conjuncts, so symmetric-OR
    inference finds no swap; the second factoring then hoists the `_cse_*`
    column. This pins the reference order: the other order infers the IN
    lists.

    Defect caught: the second `factor_or_conjuncts` before
    `decompose_symmetric_or`. The factored OR is a two-conjunct swap, and
    `a IN (1, 2)` and `b IN (1, 2)` (as ORs) are added to the Filter."""
    var cases_or = _or(
        _and(_when_eq_1("c"), _and(_eq("a", 1), _eq("b", 2))),
        _and(_when_eq_1("c"), _and(_eq("a", 2), _eq("b", 1))),
    )
    var n: List[String] = ["a", "b", "c"]
    assert_equal(_render(_run(LogicalPlan.filter(cases_or^, _scan("t.parquet", n)))), _want_symor_when())


def test_filters_are_split_before_the_step_9_pushdown() raises:
    """`Project[ax, ay](Filter(ax = cx AND ay = 1))` over A CROSS JOIN a side
    unique on cx: split first, `ay = 1` goes into the A scan and
    `Filter(ax = cx)` lands on the cross join, which step 10 makes the INNER
    join that step 14 turns into a SEMI join.

    Defect caught: `decompose_filters` after the step-9
    `push_predicates_down`. The step-14 semi conversion does not fire, and the
    join ends INNER under two Projects."""
    var an: List[String] = ["ax", "ay"]
    var cross = LogicalPlan.join(_scan("A", an, 100), _unique_c(), List[String](), List[String](), JOIN_CROSS)
    var keep: List[String] = ["ax", "ay"]
    var f = LogicalPlan.filter(_and(_ceq("ax", "cx"), _eq("ay", 1)), cross^)
    assert_equal(_render(_run(LogicalPlan.project(_cols(keep^), f^))), _want_cross_eq_side())


def test_a_broadcast_site_folds_before_step_10() raises:
    """`Filter(total > max(total))` over `SUM(by) AS total GROUP BY ay` over
    `Filter(ax = bx)` over A CROSS JOIN B, bound on that Aggregate as written:
    the fold runs in step 9, while the cross join is still as written, so it
    folds to a filtered in-memory scan with no request.

    Defect caught: `scalar_broadcast_rewrite` after the step-10
    `eliminate_cross_join`. The Aggregate's input is then an INNER join, its
    hash misses the binding, one request is recorded and the site stays."""
    var an: List[String] = ["ax", "ay"]
    var bn: List[String] = ["bx", "by"]
    var cross = LogicalPlan.join(_scan("A", an, 100), _scan("B", bn, 1000), List[String](), List[String](), JOIN_CROSS)
    var agg = _sum("ay", _c("by"), "total", LogicalPlan.filter(_ceq("ax", "bx"), cross^))
    var deps = ScalarDepTable()
    var on: List[String] = ["ay", "total"]
    var src = InMemorySource.from_record_batch(RecordBatch.empty_from_schema(_schema(on)))
    deps.bind_broadcast(agg.structural_hash(), ScalarValue.from_int(7), src^, _schema(on), String("cache0"))
    var site = LogicalPlan.filter(Expr.binary(BIN_GT, _c("total"), Expr.agg_fn(AGG_MAX, _c("total"))), agg^)
    var r = _render(optimize(site^, OptimizerConfig(), deps))
    assert_equal(deps.num_requests(), 0, r)
    assert_true(r.startswith("Scan(path=\"__in_memory__\", type=IN_MEMORY,"), r)
    assert_true(r.endswith(
        "filter=BinaryOp(GT, ColRef(total), Literal(ScalarValue(int64, 7))))\n"
    ), r)


# -----------------------------------------------------------------------------
# Steps 12-16: projects, aggregates, joins
# -----------------------------------------------------------------------------


def test_fd_key_elision_runs_before_merge_projects() raises:
    """`Project[ip, c1 + 1 AS c2, c](Project[ip, k0 AS c1, c](Aggregate[ip,
    k0; COUNT(*)](Project[ip, ip - 1 AS k0](hits))))`: `k0` is elided and
    recomputed above the Aggregate, and step 13 merges the recomputing
    Project into the two above it.

    Defect caught: FD key elision moved after `merge_projects` (still before
    identity elimination). The merge first leaves one Project above the
    Aggregate that reads `k0` inside `(k0 AS c1) + 1`, and the elision then
    leaves `k0` a group key."""
    var inner = ExprArray()
    inner.append(_c("ip"))
    inner.append(Expr.alias(Expr.binary(BIN_SUB, _c("ip"), _lit(1)), "k0"))
    var ipn: List[String] = ["ip", "other"]
    var gb: List[String] = ["ip", "k0"]
    var aggs = AggExprArray()
    var no_child: Optional[Expr] = None
    aggs.append(AggExpr(AGG_COUNT, no_child^, Optional(String("c"))))
    var agg = LogicalPlan.aggregate(_cols(gb^), aggs^, LogicalPlan.project(inner^, _scan("hits.parquet", ipn)))
    var o1 = ExprArray()
    o1.append(_c("ip"))
    o1.append(Expr.alias(_c("k0"), "c1"))
    o1.append(_c("c"))
    var o2 = ExprArray()
    o2.append(_c("ip"))
    o2.append(Expr.alias(Expr.binary(BIN_ADD, _c("c1"), _lit(1)), "c2"))
    o2.append(_c("c"))
    assert_equal(_render(_run(LogicalPlan.project(o2^, LogicalPlan.project(o1^, agg^)))), _want_fd_two_projects())


def test_projects_merge_before_identity_elimination() raises:
    """`Project[a, b](Project[b, a](s(a, b)))`: neither Project is an
    identity, but merged they are, and identity elimination then removes the
    merged one, leaving the scan.

    Defect caught: `eliminate_identity_projects` before `merge_projects` in
    step 13. Nothing is an identity yet, and the merged `Project[a, b]` stays
    over the scan."""
    var n: List[String] = ["a", "b"]
    var ba: List[String] = ["b", "a"]
    var ab: List[String] = ["a", "b"]
    var out = _run(LogicalPlan.project(_cols(ab^), LogicalPlan.project(_cols(ba^), _scan("s.parquet", n))))
    var just_scan: List[String] = ['Scan(path="s.parquet", type=PARQUET, source_kind=COLUMNAR)']
    assert_equal(_render(out), _lines(just_scan))


def test_absorb_runs_before_inner_to_semi() raises:
    """`SUM(x) GROUP BY ax` over `Project[ax, ax * ay AS x]` over A JOIN a side
    unique on cx: absorb folds the Project into the Aggregate, so the join's
    parent is the Aggregate, which `convert_inner_to_semi` does not convert
    under. The join stays INNER. This pins the reference order: the other
    order makes a SEMI join.

    Defect caught: `convert_inner_to_semi` before
    `absorb_expression_into_aggregate`. The Project over the join reads only A
    columns, so the join becomes SEMI first."""
    var pe = ExprArray()
    pe.append(_c("ax"))
    pe.append(Expr.alias(Expr.binary(BIN_MUL, _c("ax"), _c("ay")), "x"))
    assert_equal(_render(_run(_sum("ax", _c("x"), "s", LogicalPlan.project(pe^, _a_join_unique_c())))), _want_agg_proj_unique())


def test_inner_to_semi_runs_before_aggregate_input_materialization() raises:
    """`SUM(ax * ay) GROUP BY ax` over A JOIN a side unique on cx: at step 14
    the join's parent is the Aggregate, so it stays INNER; step 15 then puts
    `ax * ay` in a Project under the Aggregate. This pins the reference order:
    the other order makes a SEMI join.

    Defect caught: `materialize_agg_input` before `convert_inner_to_semi`. The
    materialized Project over the join reads only A columns, so the join
    becomes SEMI."""
    var plan = _sum("ax", Expr.binary(BIN_MUL, _c("ax"), _c("ay")), "s", _a_join_unique_c())
    assert_equal(_render(_run(plan^)), _want_agg_expr_unique())


def test_semi_reducers_are_pushed_before_the_reorder() raises:
    """`SEMI((a JOIN b) JOIN d, c)` with a 100000 rows, b 10, d 1000, c 10:
    on the chain as written the reducer pushdown declines, and the SEMI stays
    above the joins the reorder then builds.

    Defect caught: `push_semi_reducers_down` after `reorder_joins_with_dp`.
    The reducer then lands on the reordered chain, as `SEMI(a, c)` under the
    top INNER join."""
    var an: List[String] = ["ak", "av"]
    var bn: List[String] = ["bk", "bv"]
    var cn: List[String] = ["ck", "cv"]
    var dn: List[String] = ["dk", "dv"]
    var ab = LogicalPlan.join(_scan("a", an, 100000), _scan("b", bn, 10), _l1("ak"), _l1("bk"), JOIN_INNER)
    var abd = LogicalPlan.join(ab^, _scan("d", dn, 1000), _l1("bk"), _l1("dk"), JOIN_INNER)
    var semi = LogicalPlan.join(abd^, _scan("c", cn, 10), _l1("ak"), _l1("ck"), JOIN_SEMI)
    assert_equal(_render(_run(semi^)), _want_semi_three_way())


# -----------------------------------------------------------------------------
# Steps 17-19: limits and windows
# -----------------------------------------------------------------------------


def test_sort_limit_fusion_runs_before_the_window_rewrite() raises:
    """`Limit 10` over `Sort(a)` over a PartitionBy partitioned on `a`: step
    17 fuses the Sort and Limit into `TopN(n=10)`, so the window rewrite finds
    no Sort to elide.

    Defect caught: `fuse_sort_limit` after `optimize_window_rewrite`. The
    window rewrite elides the Sort first and the plan is `Limit(n=10)` over
    the PartitionBy."""
    var wn: List[String] = ["a", "b", "c"]
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.row_number())
    var desc = List[Bool]()
    desc.append(True)
    var pb = LogicalPlan.partition_by(_l1("a"), _l1("b"), desc^, exprs^, _scan("w.parquet", wn))
    var asc = List[Bool]()
    asc.append(False)
    assert_equal(_render(_run(LogicalPlan.limit(10, LogicalPlan.sort(_l1("a"), asc^, pb^)))), _want_limit_sort_window())


# -----------------------------------------------------------------------------
# Expected renders
# -----------------------------------------------------------------------------


def _want_hive_in_subquery() -> String:
    var l: List[String] = [
        "Project(exprs=[ColRef(c_custkey), ColRef(c_acctbal)])",
        "  Filter(predicate=BinaryOp(GT, ColRef(c_acctbal), ColRef(__scalar_subq_0)))",
        "    Join(type=CROSS, on=[])",
        "      Scan(path=\"customer.parquet\", type=PARQUET, source_kind=COLUMNAR)",
        "      Project(exprs=[Alias(ColRef(hv), \"__scalar_subq_0\")])",
        "        Aggregate(group_by=[], aggs=[SUM(ColRef(v)).alias(\"hv\")])",
        "          Scan(path=\"d/\", type=PARQUET, source_kind=COLUMNAR, filter=BinaryOp(EQ, ColRef(p), Literal(ScalarValue(int64, 1))))",
    ]
    return _lines(l)


def _want_residual_left() -> String:
    var l: List[String] = [
        "Project(exprs=[ColRef(a), ColRef(ta), ColRef(b), ColRef(ub)])",
        "  Join(type=INNER, on=[b=a])",
        "    Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)",
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR, filter=BinaryOp(GT, ColRef(ta), Literal(ScalarValue(int64, 5))))",
    ]
    return _lines(l)


def _want_residual_right() -> String:
    var l: List[String] = [
        "Project(exprs=[ColRef(a), ColRef(ta), ColRef(b), ColRef(ub)])",
        "  Project(exprs=[ColRef(b), ColRef(ub), ColRef(a), ColRef(ta)])",
        "    Join(type=INNER, on=[ta=ub, a=b])",
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)",
        "      Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR, filter=BinaryOp(GT, ColRef(ub), Literal(ScalarValue(int64, 5))))",
    ]
    return _lines(l)


def _want_exists_residual() -> String:
    var l: List[String] = [
        "Join(type=SEMI, on=[c_custkey=o_custkey], residual=BinaryOp(GT, ColRef(o_v), ColRef(c_v)))",
        "  Scan(path=\"customer.parquet\", type=PARQUET, source_kind=COLUMNAR)",
        "  Scan(path=\"orders.parquet\", type=PARQUET, source_kind=COLUMNAR, projection=[o_custkey, o_v])",
    ]
    return _lines(l)


def _want_not_fold() -> String:
    var l: List[String] = [
        "Scan(path=\"s.parquet\", type=PARQUET, source_kind=COLUMNAR, filter=BinaryOp(EQ, ColRef(a), Literal(ScalarValue(int64, 1))))",
    ]
    return _lines(l)


def _want_cse_in() -> String:
    var l: List[String] = [
        "Project(exprs=[Alias(ColRef(a), \"a\"), Alias(InList(Alias(BinaryOp(ADD, ColRef(a), ColRef(b)), \"_cse_ce64410d_0\"), [ScalarValue(int64, 1), ScalarValue(int64, 2)]), \"x\")])",
        "  Scan(path=\"s.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_symor_when() -> String:
    var l: List[String] = [
        "Project(exprs=[Alias(ColRef(a), \"a\"), Alias(ColRef(b), \"b\"), Alias(ColRef(c), \"c\")])",
        "  Filter(predicate=BinaryOp(AND, ColRef(_cse_c8b6dc30_0), BinaryOp(OR, BinaryOp(AND, BinaryOp(EQ, ColRef(a), Literal(ScalarValue(int64, 1))), BinaryOp(EQ, ColRef(b), Literal(ScalarValue(int64, 2)))), BinaryOp(AND, BinaryOp(EQ, ColRef(a), Literal(ScalarValue(int64, 2))), BinaryOp(EQ, ColRef(b), Literal(ScalarValue(int64, 1)))))))",
        "    Project(exprs=[Alias(ColRef(a), \"a\"), Alias(ColRef(b), \"b\"), Alias(ColRef(c), \"c\"), Alias(BinaryOp(EQ, When(WHEN BinaryOp(GT, ColRef(c), Literal(ScalarValue(int64, 1))) THEN Literal(ScalarValue(int64, 1)), ELSE Literal(ScalarValue(int64, 0))), Literal(ScalarValue(int64, 1))), \"_cse_c8b6dc30_0\")])",
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_cross_eq_side() -> String:
    var l: List[String] = [
        "Join(type=SEMI, on=[ax=cx])",
        "  Scan(path=\"A\", type=PARQUET, source_kind=COLUMNAR, filter=BinaryOp(EQ, ColRef(ay), Literal(ScalarValue(int64, 1))))",
        "  Aggregate(group_by=[ColRef(cx)], aggs=[SUM(ColRef(cy)).alias(\"s_cx\")])",
        "    Scan(path=\"C\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_fd_two_projects() -> String:
    var l: List[String] = [
        "Project(exprs=[ColRef(ip), Alias(BinaryOp(ADD, Alias(BinaryOp(SUB, ColRef(ip), Literal(ScalarValue(int64, 1))), \"c1\"), Literal(ScalarValue(int64, 1))), \"c2\"), ColRef(c)])",
        "  Aggregate(group_by=[ColRef(ip)], aggs=[COUNT(*).alias(\"c\")])",
        "    Scan(path=\"hits.parquet\", type=PARQUET, source_kind=COLUMNAR, projection=[ip])",
    ]
    return _lines(l)


def _want_agg_proj_unique() -> String:
    var l: List[String] = [
        "Aggregate(group_by=[ColRef(ax)], aggs=[SUM(ColRef(__agg_in_0)).alias(\"s\")])",
        "  Project(exprs=[ColRef(ax), Alias(Alias(BinaryOp(MUL, ColRef(ax), ColRef(ay)), \"x\"), \"__agg_in_0\")])",
        "    Project(exprs=[ColRef(cx), ColRef(s_cx), ColRef(ax), ColRef(ay)])",
        "      Join(type=INNER, on=[ax=cx])",
        "        Scan(path=\"A\", type=PARQUET, source_kind=COLUMNAR)",
        "        Aggregate(group_by=[ColRef(cx)], aggs=[SUM(ColRef(cy)).alias(\"s_cx\")])",
        "          Scan(path=\"C\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_agg_expr_unique() -> String:
    var l: List[String] = [
        "Aggregate(group_by=[ColRef(ax)], aggs=[SUM(ColRef(__agg_in_0)).alias(\"s\")])",
        "  Project(exprs=[ColRef(ax), Alias(BinaryOp(MUL, ColRef(ax), ColRef(ay)), \"__agg_in_0\")])",
        "    Project(exprs=[ColRef(cx), ColRef(s_cx), ColRef(ax), ColRef(ay)])",
        "      Join(type=INNER, on=[ax=cx])",
        "        Scan(path=\"A\", type=PARQUET, source_kind=COLUMNAR)",
        "        Aggregate(group_by=[ColRef(cx)], aggs=[SUM(ColRef(cy)).alias(\"s_cx\")])",
        "          Scan(path=\"C\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_semi_three_way() -> String:
    var l: List[String] = [
        "Project(exprs=[ColRef(ak), ColRef(av), ColRef(bk), ColRef(bv), ColRef(dk), ColRef(dv)])",
        "  Join(type=SEMI, on=[ak=ck])",
        "    Project(exprs=[ColRef(bk), ColRef(bv), ColRef(dk), ColRef(dv), ColRef(ak), ColRef(av)])",
        "      Join(type=INNER, on=[ak=bk, ak=dk])",
        "        Scan(path=\"a\", type=PARQUET, source_kind=COLUMNAR)",
        "        Project(exprs=[ColRef(bk), ColRef(bv), ColRef(dk), ColRef(dv)])",
        "          Join(type=INNER, on=[dk=bk])",
        "            Scan(path=\"d\", type=PARQUET, source_kind=COLUMNAR)",
        "            Scan(path=\"b\", type=PARQUET, source_kind=COLUMNAR)",
        "    Scan(path=\"c\", type=PARQUET, source_kind=COLUMNAR, projection=[ck])",
    ]
    return _lines(l)


def _want_limit_sort_window() -> String:
    var l: List[String] = [
        "TopN(n=10, keys=[a ASC])",
        "  PartitionBy(partition=[a], order=[b DESC], funcs=[ROW_NUMBER(, offset=0, frame=ROWS[0:0..2:0])])",
        "    Scan(path=\"w.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
