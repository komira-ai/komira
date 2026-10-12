# =============================================================================
# test_optimizer_portable_order -- `optimize_portable` runs the driver's
# passes in the driver's order (komira-ai/komira#1094, §5.3)
# =============================================================================
#
# `test_optimizer_portable_parity.mojo` catches a pass the portable entry
# skips. This file catches a pass the portable entry runs at another place:
# two adjacent pass calls, or two adjacent steps, exchanged only for the
# portable entry. No pass is skipped by such a change, so the
# parity file's table need not see it; on each plan below the two orders give
# different plans, and the portable render then differs from `optimize`'s.
#
# The table at the end names, for each plan, the exchanges it shows. The
# plans follow the same rules as the parity file: no scan carries
# statistics, and `optimize` records no request on any of them. Some
# exchanges are shown by a plan of the parity file or of
# `test_optimizer_portable.mojo` instead (three of them by the window and
# Limit plans the parity file names "before").
#
# The exchanges no plan shows, and why each gives the same plan in both
# orders on every plan tried, are listed in the pull request that added this
# file; that is what was measured, not a proof for every plan.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_COUNT
from komira_plan_expr.expr import (
    Expr, WhenCaseData, BIN_ADD, BIN_SUB, BIN_MUL, BIN_EQ, BIN_GT, BIN_AND, BIN_OR, UN_NOT,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan, ExprArray, AggExprArray, SOURCE_PARQUET, CORR_KIND_SCALAR,
    CORR_KIND_EXISTS, JOIN_INNER, JOIN_SEMI, JOIN_CROSS, JOIN_ALGO_AUTO,
)
from komira_scan_source.parquet_source import ParquetSource
from komira_scan_source.source_variant import SourceVariant
from komira_optimizer.optimizer_config import OptimizerConfig
from komira_optimizer.optimizer_scalar_deps import ScalarDepTable
from komira_optimizer.optimizer_driver import (
    optimize,
    optimize_portable,
    PortableProfile,
    PORTABLE_PROFILE_V1,
)


# -----------------------------------------------------------------------------
# Helpers
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
        pe.append(_c(names[i]))
    return pe^


def _render(p: LogicalPlan) -> String:
    var s = String("")
    p.write_to(s)
    return s


def _sum(key: String, var arg: Expr, oname: String, var child: LogicalPlan) -> LogicalPlan:
    """SUM(arg) AS oname, grouped by `key` (no grouping when `key` is empty)."""
    var gb = ExprArray()
    if key != "":
        gb.append(_c(key))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(arg^), Optional(oname)))
    return LogicalPlan.aggregate(gb^, aggs^, child^)


def _when_eq_1(c: String) -> Expr:
    """(CASE WHEN c > 1 THEN 1 ELSE 0 END) = 1: a predicate OR factoring
    stops at and CSE hoists."""
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(_gt(c, 1), _lit(1)))
    return Expr.binary(BIN_EQ, Expr.when(cases^, _lit(0)), _lit(1))


def _unique_c() -> LogicalPlan:
    """SUM(cy) AS s_cx GROUP BY cx over C(cx, cy), 10 rows: unique on cx."""
    var n: List[String] = ["cx", "cy"]
    return _sum("cx", _c("cy"), "s_cx", _scan("C", n, 10))


def _a_join_unique_c() -> LogicalPlan:
    """A(ax, ay), 1000 rows, INNER JOIN `_unique_c()` ON ax = cx."""
    var an: List[String] = ["ax", "ay"]
    return LogicalPlan.join(_scan("A", an, 1000), _unique_c(), _l1("ax"), _l1("cx"), JOIN_INNER)


def _side_join(var residual: Expr, var left_on: List[String], var right_on: List[String]) -> LogicalPlan:
    """t(a, ta) INNER JOIN u(b, ub) with `residual` as its `predicate=`."""
    var jt: List[String] = ["a", "ta"]
    var ju: List[String] = ["b", "ub"]
    return LogicalPlan.join(
        _scan("t.parquet", jt), _scan("u.parquet", ju), left_on^, right_on^,
        JOIN_INNER, JOIN_ALGO_AUTO, Optional[OwnedPointer[Expr]](OwnedPointer(residual^)),
    )


def _fact_join_dim() -> LogicalPlan:
    """fact(fk_id, measure) INNER JOIN dim(dim_id, dim_attr) ON fk_id = dim_id."""
    var fnm: List[String] = ["fk_id", "measure"]
    var dnm: List[String] = ["dim_id", "dim_attr"]
    return LogicalPlan.join(
        _scan("fact.parquet", fnm), _scan("dim.parquet", dnm), _l1("fk_id"), _l1("dim_id"), JOIN_INNER
    )


# -----------------------------------------------------------------------------
# Plans
# -----------------------------------------------------------------------------


# --- Steps 1-5: scans, subqueries, join predicates ---


def _scalar_subquery_over_hive() raises -> LogicalPlan:
    """Filter(c_acctbal > (SELECT SUM(v) FROM d/ WHERE p = 1)) over customer,
    d/ a lazily listed Hive scan. The subquery's scan is inside an expression
    when `attach_hive_predicate` runs, so it gets no partition predicate; run
    after decorrelation, it gets one."""
    var pc = List[Field]()
    pc.append(Field("p", ArrowType.INT64, nullable=False))
    var data: List[String] = ["v"]
    var full: List[String] = ["v", "p"]
    var src = ParquetSource.dir_scan_hive("d/", _schema(data), pc^)
    var hive = LogicalPlan.scan_from_source(SourceVariant(src^), _schema(full))
    var inner = _sum("", _c("v"), "hv", LogicalPlan.filter(_eq("p", 1), hive^))
    var cn: List[String] = ["c_custkey", "c_acctbal"]
    var sub = Expr.correlated_subquery(inner^, List[String](), CORR_KIND_SCALAR)
    var pred = Expr.binary(BIN_GT, _c("c_acctbal"), sub^)
    return LogicalPlan.filter(pred^, _scan("customer.parquet", cn))


def _exists_with_side_qualified_residual() -> LogicalPlan:
    """EXISTS (orders WHERE o_custkey = outer.c_custkey AND o_v > outer.c_v)
    over customer, outer references side-qualified: flattening makes a SEMI
    join whose residual `join_predicate_decompose` then rewrites."""
    var cn: List[String] = ["c_custkey", "c_v"]
    var on: List[String] = ["o_orderkey", "o_custkey", "o_v"]
    var inner = LogicalPlan.filter(
        _and(
            Expr.binary(BIN_EQ, _c("o_custkey"), Expr.left("c_custkey")),
            Expr.binary(BIN_GT, _c("o_v"), Expr.left("c_v")),
        ),
        _scan("orders.parquet", on, 100000),
    )
    var corr: List[String] = ["c_custkey", "c_v"]
    var pred = Expr.correlated_subquery(inner^, corr^, CORR_KIND_EXISTS)
    return LogicalPlan.filter(pred^, _scan("customer.parquet", cn, 10))


def _side_residual() -> LogicalPlan:
    """A join whose `predicate=` is `left.a = right.b AND left.ta > 5`, no
    keys: decomposed first, `a = b` becomes the key and the plain `ta > 5`
    then moves into the t scan."""
    var r1 = _and(
        Expr.binary(BIN_EQ, Expr.left("a"), Expr.right("b")),
        Expr.binary(BIN_GT, Expr.left("ta"), _lit(5)),
    )
    return _side_join(r1^, List[String](), List[String]())


def _residual_to_fold() -> LogicalPlan:
    """t(a, ta) JOIN u(b, ub) ON a = b with residual `ta > 1 + 2`: step 5
    makes it a Filter on t, which step 6 then folds."""
    var res = Expr.binary(BIN_GT, _c("ta"), Expr.binary(BIN_ADD, _lit(1), _lit(2)))
    return _side_join(res^, _l1("a"), _l1("b"))


# --- Steps 6-9: expressions and filters ---


def _not_fold_then_simplify() -> LogicalPlan:
    """Filter(NOT ((1 = 1) AND NOT (a = 1))) over s(a, b): folding leaves a
    double negation that simplification then removes."""
    var x = Expr.unary(
        UN_NOT, _and(Expr.binary(BIN_EQ, _lit(1), _lit(1)), Expr.unary(UN_NOT, _eq("a", 1)))
    )
    var n: List[String] = ["a", "b"]
    return LogicalPlan.filter(x^, _scan("s.parquet", n))


def _double_negated_shared_or() -> LogicalPlan:
    """Filter(NOT NOT ((a + b > 1 AND c = 2) OR (a + b > 1 AND c = 3))) over
    t(a, b, c): step 6 removes the double negation, step 7 factors the shared
    conjunct before CSE can hoist it."""
    var sh = Expr.binary(BIN_GT, Expr.binary(BIN_ADD, _c("a"), _c("b")), _lit(1))
    var o = _or(_and(sh.copy(), _eq("c", 2)), _and(sh.copy(), _eq("c", 3)))
    var pred = Expr.unary(UN_NOT, Expr.unary(UN_NOT, o^))
    var n: List[String] = ["a", "b", "c"]
    return LogicalPlan.filter(pred^, _scan("t.parquet", n))


def _cse_then_in_list() -> LogicalPlan:
    """Project[a, (a + b) = 1 OR (a + b) = 2 AS x] over s(a, b): CSE names
    `a + b`, then the IN rewrite sees equalities on one column."""
    var n: List[String] = ["a", "b"]
    var ab = Expr.binary(BIN_ADD, _c("a"), _c("b"))
    var pe = ExprArray()
    pe.append(_c("a"))
    var x = _or(Expr.binary(BIN_EQ, ab.copy(), _lit(1)), Expr.binary(BIN_EQ, ab.copy(), _lit(2)))
    pe.append(Expr.alias(x^, "x"))
    return LogicalPlan.project(pe^, _scan("s.parquet", n))


def _symmetric_or_behind_a_when() -> LogicalPlan:
    """Filter((W AND a = 1 AND b = 2) OR (W AND a = 2 AND b = 1)) over
    t(a, b, c), W a CASE comparison: symmetric-OR inference finds no swap in
    three-conjunct branches; factored first, it infers two IN lists."""
    var p = _or(
        _and(_when_eq_1("c"), _and(_eq("a", 1), _eq("b", 2))),
        _and(_when_eq_1("c"), _and(_eq("a", 2), _eq("b", 1))),
    )
    var n: List[String] = ["a", "b", "c"]
    return LogicalPlan.filter(p^, _scan("t.parquet", n))


def _split_before_pushdown() -> LogicalPlan:
    """Project[ax, ay] over Filter(ax = cx AND ay = 1) over A CROSS JOIN a side
    unique on cx: split first, `Filter(ax = cx)` lands on the cross join,
    which becomes an INNER and then a SEMI join."""
    var an: List[String] = ["ax", "ay"]
    var cross = LogicalPlan.join(_scan("A", an, 100), _unique_c(), List[String](), List[String](), JOIN_CROSS)
    var keep: List[String] = ["ax", "ay"]
    var f = LogicalPlan.filter(_and(_ceq("ax", "cx"), _eq("ay", 1)), cross^)
    return LogicalPlan.project(_cols(keep^), f^)


def _equality_above_a_project_over_cross_join() -> LogicalPlan:
    """Project[ax, ay] over Filter(ax = cx) over Project[ax, ay, cx] over A
    CROSS JOIN a side unique on cx: step 9 pushes the Filter onto the cross
    join, step 10 makes it an INNER join and step 14 a SEMI join. Run before
    step 9, step 10 finds no Filter on the cross join, and the INNER join
    step 16 makes comes after the SEMI conversion."""
    var an: List[String] = ["ax", "ay"]
    var cross = LogicalPlan.join(_scan("A", an, 100), _unique_c(), List[String](), List[String](), JOIN_CROSS)
    var mid: List[String] = ["ax", "ay", "cx"]
    var keep: List[String] = ["ax", "ay"]
    var f = LogicalPlan.filter(_ceq("ax", "cx"), LogicalPlan.project(_cols(mid^), cross^))
    return LogicalPlan.project(_cols(keep^), f^)


# --- Steps 10-16: joins, projects, aggregates ---


def _fd_key_under_two_projects() -> LogicalPlan:
    """Project[ip, c1 + 1 AS c2, c] over Project[ip, k0 AS c1, c] over
    COUNT(*) AS c GROUP BY ip, k0 over Project[ip, ip - 1 AS k0] over
    hits(ip, other): `k0` is elided before the Projects above merge."""
    var inner = ExprArray()
    inner.append(_c("ip"))
    inner.append(Expr.alias(Expr.binary(BIN_SUB, _c("ip"), _lit(1)), "k0"))
    var ipn: List[String] = ["ip", "other"]
    var gb: List[String] = ["ip", "k0"]
    var aggs = AggExprArray()
    var no_child: Optional[Expr] = None
    aggs.append(AggExpr(AGG_COUNT, no_child^, Optional(String("c"))))
    var agg = LogicalPlan.aggregate(
        _cols(gb^), aggs^, LogicalPlan.project(inner^, _scan("hits.parquet", ipn))
    )
    var o1 = ExprArray()
    o1.append(_c("ip"))
    o1.append(Expr.alias(_c("k0"), "c1"))
    o1.append(_c("c"))
    var o2 = ExprArray()
    o2.append(_c("ip"))
    o2.append(Expr.alias(Expr.binary(BIN_ADD, _c("c1"), _lit(1)), "c2"))
    o2.append(_c("c"))
    return LogicalPlan.project(o2^, LogicalPlan.project(o1^, agg^))


def _two_projects_that_merge_to_an_identity() -> LogicalPlan:
    """Project[a, b] over Project[b, a] over s(a, b)."""
    var n: List[String] = ["a", "b"]
    var ba: List[String] = ["b", "a"]
    var ab: List[String] = ["a", "b"]
    return LogicalPlan.project(_cols(ab^), LogicalPlan.project(_cols(ba^), _scan("s.parquet", n)))


def _merged_projects_then_eager() -> LogicalPlan:
    """SUM(measure) AS total GROUP BY dim_attr over Project[dim_attr,
    measure] over Project[measure, dim_attr, fk_id] over fact JOIN dim: merged
    first, eager aggregation pushes a partial sum to the fact side."""
    var inner: List[String] = ["measure", "dim_attr", "fk_id"]
    var outer: List[String] = ["dim_attr", "measure"]
    var p = LogicalPlan.project(_cols(outer^), LogicalPlan.project(_cols(inner^), _fact_join_dim()))
    return _sum("dim_attr", _c("measure"), "total", p^)


def _eager_over_a_computing_project() -> LogicalPlan:
    """SUM(x) AS total GROUP BY dim_attr over Project[dim_attr, measure * 2
    AS x] over fact JOIN dim: eager aggregation declines an Aggregate over a
    Project; absorbed first, it would not."""
    var ep = ExprArray()
    ep.append(_c("dim_attr"))
    ep.append(Expr.alias(Expr.binary(BIN_MUL, _c("measure"), _lit(2)), "x"))
    return _sum("dim_attr", _c("x"), "total", LogicalPlan.project(ep^, _fact_join_dim()))


def _sum_of_project_over_unique_join() -> LogicalPlan:
    """SUM(x) GROUP BY ax over Project[ax, ax * ay AS x] over A JOIN a side
    unique on cx: absorbed first, the join stays INNER."""
    var pe = ExprArray()
    pe.append(_c("ax"))
    pe.append(Expr.alias(Expr.binary(BIN_MUL, _c("ax"), _c("ay")), "x"))
    return _sum("ax", _c("x"), "s", LogicalPlan.project(pe^, _a_join_unique_c()))


def _semi_over_three_way_chain() -> LogicalPlan:
    """SEMI((a JOIN b) JOIN d, c), a 100000 rows, b 10, d 1000, c 10: the
    reducer pushdown declines the chain as written, before the reorder."""
    var an: List[String] = ["ak", "av"]
    var bn: List[String] = ["bk", "bv"]
    var cn: List[String] = ["ck", "cv"]
    var dn: List[String] = ["dk", "dv"]
    var ab = LogicalPlan.join(_scan("a", an, 100000), _scan("b", bn, 10), _l1("ak"), _l1("bk"), JOIN_INNER)
    var abd = LogicalPlan.join(ab^, _scan("d", dn, 1000), _l1("bk"), _l1("dk"), JOIN_INNER)
    return LogicalPlan.join(abd^, _scan("c", cn, 10), _l1("ak"), _l1("ck"), JOIN_SEMI)


# --- Steps 16-17: join order and limits ---


def _limit_over_swapped_join() -> LogicalPlan:
    """Limit 5 over a(10 rows) JOIN b(100000 rows): step 16 swaps the operands
    and restores the column order with a Project, which step 17 then pushes
    the Limit below."""
    var an: List[String] = ["ak", "av"]
    var bn: List[String] = ["bk", "bv"]
    var j = LogicalPlan.join(_scan("a", an, 10), _scan("b", bn, 100000), _l1("ak"), _l1("bk"), JOIN_INNER)
    return LogicalPlan.limit(5, j^)


# -----------------------------------------------------------------------------
# The table: plan i, and the exchange it shows
# -----------------------------------------------------------------------------


comptime _N_PLANS = 17


def _plan_name(i: Int) -> String:
    var names: List[String] = [
        "attach_hive_predicate (1) before scalar_subquery_decorrelate (2): scalar_subquery_over_hive",
        "flatten_dependent_joins before join_predicate_decompose (4): exists_with_side_qualified_residual",
        "join_predicate_decompose (4) before push_join_residual_to_side (5): side_residual",
        "push_join_residual_to_side (5) before step 6: residual_to_fold",
        "fold_constants before simplify_predicates (6): not_fold_then_simplify",
        "steps 6, 7 and 8 in that order, and step 8 before step 9: double_negated_shared_or",
        "eliminate_common_subexpressions before rewrite_in_clauses (8): cse_then_in_list",
        "decompose_symmetric_or before the second factor_or_conjuncts (9): symmetric_or_behind_a_when",
        "decompose_filters before push_predicates_down (9): split_before_pushdown",
        "step 9 before step 10: equality_above_a_project_over_cross_join",
        "elide_functionally_dependent_group_keys (12) before merge_projects (13): fd_key_under_two_projects",
        "merge_projects before eliminate_identity_projects (13): two_projects_that_merge_to_an_identity",
        "step 13 before step 14: merged_projects_then_eager",
        "eager_aggregate_pushdown before absorb_expression_into_aggregate (14), step 14 before step 15: eager_over_a_computing_project",
        "absorb_expression_into_aggregate before convert_inner_to_semi (14), convert_inner_to_semi before materialize_agg_input (15), step 15 before step 16: sum_of_project_over_unique_join",
        "push_semi_reducers_down before reorder_joins_with_dp (16): semi_over_three_way_chain",
        "step 16 before step 17: limit_over_swapped_join",
    ]
    return names[i]


def _plan_at(i: Int) raises -> LogicalPlan:
    if i == 0:
        return _scalar_subquery_over_hive()
    if i == 1:
        return _exists_with_side_qualified_residual()
    if i == 2:
        return _side_residual()
    if i == 3:
        return _residual_to_fold()
    if i == 4:
        return _not_fold_then_simplify()
    if i == 5:
        return _double_negated_shared_or()
    if i == 6:
        return _cse_then_in_list()
    if i == 7:
        return _symmetric_or_behind_a_when()
    if i == 8:
        return _split_before_pushdown()
    if i == 9:
        return _equality_above_a_project_over_cross_join()
    if i == 10:
        return _fd_key_under_two_projects()
    if i == 11:
        return _two_projects_that_merge_to_an_identity()
    if i == 12:
        return _merged_projects_then_eager()
    if i == 13:
        return _eager_over_a_computing_project()
    if i == 14:
        return _sum_of_project_over_unique_join()
    if i == 15:
        return _semi_over_three_way_chain()
    return _limit_over_swapped_join()


def test_portable_runs_the_passes_in_the_driver_order() raises:
    """On each plan of the table, `optimize_portable` (v1) renders byte for
    byte as `optimize`, and `optimize` records no request on it.

    Defect caught: two adjacent pass calls, or two adjacent steps, of the
    driver's order exchanged only for the portable entry, for every exchange
    the table names."""
    for i in range(_N_PLANS):
        var deps = ScalarDepTable()
        var want = optimize(_plan_at(i), OptimizerConfig(), deps)
        assert_equal(deps.num_requests(), 0, _plan_name(i))
        var got = optimize_portable(
            _plan_at(i), OptimizerConfig(), PortableProfile(PORTABLE_PROFILE_V1)
        )
        assert_equal(_render(got), _render(want), _plan_name(i))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
