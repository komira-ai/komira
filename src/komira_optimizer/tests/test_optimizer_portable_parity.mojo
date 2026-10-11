# =============================================================================
# test_optimizer_portable_parity -- `optimize_portable` runs every pass of the
# driver's order (komira-ai/komira#1094, §5.3)
# =============================================================================
#
# `optimize` and `optimize_portable` share one pass list,
# `optimizer_driver._run_pass_order`; the only difference is its
# `narrow_payload` flag, which turns step 20 off for the portable entry. A pass
# made conditional on that flag would vanish from the portable profile and
# nothing else would change. One check catches it: on a plan where that pass
# changes the result, the portable render differs from `optimize`'s.
#
# Each plan below is a small plan on which one pass (or one arm of a driver
# gate) changes the render; the table at the end names it. Three, named
# "... before ..." there, show an order instead: on them, `fuse_sort_limit`
# (17) run after `optimize_window_rewrite` (18), or the window rewrite run
# after `fuse_partition_topn` (19), gives a different plan
# (`test_optimizer_portable_order.mojo` holds the other steps' orders). No
# scan carries statistics, so step 20 stamps nothing, and no plan holds a
# scalar site, so no request is recorded and the portable entry refuses none
# of them.
#
# The passes these plans do not reach are reached in
# `test_optimizer_portable.mojo`: by its seven-plan parity test (scalar
# decorrelation, the join residual to side, the first OR factoring, the
# IN-list rewrite, eager aggregation, SEMI reducer pushdown, the join reorder,
# build-side selection and the order restore), and by its refusal tests for
# scalar resolution and the broadcast rewrite (skipped, either records no
# request, so a plan that needs an execution is not refused).
# Two calls are left with no plan that tells them apart. `prune_columns` is
# `push_projections_down` called again: either one alone is equivalent, and
# the pair is caught.
# The window gates (18, 19) scan the current plan. Step 15 can create the
# first Project, so `window_fn_as_aggregate_input` catches a Project arm that
# reads the `has_project` flag scanned after step 4 instead. Step 18 can
# create the first PartitionBy, and `fuse_partition_topn` fires on two
# patterns: a Filter directly over a PartitionBy, and an identity Project
# directly over a PartitionTopN, including one already in the input that
# steps 5-17 leave in place (they do not descend into a PartitionTopN). So
# `identity_project_under_a_partition_topn` catches a step-19 gate that
# reads PartitionBy from a scan after step 4. The opposite case, a
# PartitionBy at step 4 and none at steps 18-19, does not occur under
# `optimize_portable`: only a bound broadcast site (step 9) removes a
# PartitionBy, with its whole Aggregate subtree, and the portable entry has
# no binding (an unbound site records a request, which it refuses). So the
# step-18 PartitionBy arm reading that flag changes no plan the portable
# entry returns, and no plan here is for it.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_COUNT
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import (
    Expr, WhenCaseData, BIN_ADD, BIN_SUB, BIN_MUL, BIN_EQ, BIN_GT, BIN_LT, BIN_LE,
    BIN_AND, BIN_OR, UN_NOT,
)
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan, ExprArray, AggExprArray, SOURCE_PARQUET, CORR_KIND_EXISTS,
    JOIN_INNER, JOIN_CROSS, JOIN_ALGO_AUTO,
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


def _agg_sum(key: String, val: String, oname: String, var child: LogicalPlan) -> LogicalPlan:
    """SUM(val) AS oname GROUP BY key over `child`."""
    var gb = ExprArray()
    gb.append(_c(key))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(_c(val)), Optional(oname)))
    return LogicalPlan.aggregate(gb^, aggs^, child^)


def _when_eq_1(c: String) -> Expr:
    """(CASE WHEN c > 1 THEN 1 ELSE 0 END) = 1: a predicate OR factoring
    stops at and CSE hoists."""
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(_gt(c, 1), _lit(1)))
    return Expr.binary(BIN_EQ, Expr.when(cases^, _lit(0)), _lit(1))


def _or_with_when(w: String, var x: Expr, var y: Expr, var z: Expr) -> Expr:
    """(W AND x AND y) OR (W AND x AND z), W = `_when_eq_1(w)`."""
    return _or(
        _and(_when_eq_1(w), _and(x.copy(), y^)),
        _and(_when_eq_1(w), _and(x^, z^)),
    )


def _pb(f: PartitionExpr, var child: LogicalPlan) raises -> LogicalPlan:
    """PartitionBy(partition=[a], order=[b DESC], funcs=[f]) over `child`."""
    var exprs = List[PartitionExpr]()
    exprs.append(f.copy())
    var desc = List[Bool]()
    desc.append(True)
    return LogicalPlan.partition_by(_l1("a"), _l1("b"), desc^, exprs^, child^)


def _asc() -> List[Bool]:
    var d = List[Bool]()
    d.append(False)
    return d^


# -----------------------------------------------------------------------------
# Plans
# -----------------------------------------------------------------------------


# --- Step 1: scans ---


def _year_scan_filter() raises -> LogicalPlan:
    """Filter(year = 2024 AND id > 3) over an eagerly listed Hive scan of
    year=2022..2025, one file each: partition pruning keeps one file."""
    var paths: List[String] = [
        "d/year=2022/f0.parquet", "d/year=2023/f1.parquet",
        "d/year=2024/f2.parquet", "d/year=2025/f3.parquet",
    ]
    var pvals = List[List[String]]()
    for y in range(2022, 2026):
        pvals.append(_l1(String(y)))
    var pcols = List[Field]()
    pcols.append(Field("year", ArrowType.INT64, nullable=False))
    var data: List[String] = ["id", "amount"]
    var full: List[String] = ["id", "amount", "year"]
    var src = ParquetSource.partitioned(paths^, _schema(data), pcols^, pvals^, None, 0)
    var scan = LogicalPlan.scan_from_source(SourceVariant(src^), _schema(full))
    return LogicalPlan.filter(_and(_eq("year", 2024), _gt("id", 3)), scan^)


def _hive_dir_scan_filter() raises -> LogicalPlan:
    """Filter(p = 1 AND v > 3) over a lazily listed (dir-scan) Hive scan of
    d/, partition column p: the partition conjunct becomes the scan's Hive
    predicate."""
    var pc = List[Field]()
    pc.append(Field("p", ArrowType.INT64, nullable=False))
    var data: List[String] = ["v"]
    var full: List[String] = ["v", "p"]
    var src = ParquetSource.dir_scan_hive("d/", _schema(data), pc^)
    var scan = LogicalPlan.scan_from_source(SourceVariant(src^), _schema(full))
    return LogicalPlan.filter(_and(_eq("p", 1), _gt("v", 3)), scan^)


# --- Step 4: subqueries and join predicates ---


def _exists_filter() -> LogicalPlan:
    """Filter(EXISTS (orders correlated on c_custkey)) over customer: lowered
    to a SEMI join."""
    var cn: List[String] = ["c_custkey", "c_acctbal"]
    var on: List[String] = ["c_custkey", "o_total"]
    var corr = Expr.correlated_subquery(
        _scan("orders.parquet", on), _l1("c_custkey"), CORR_KIND_EXISTS
    )
    return LogicalPlan.filter(corr^, _scan("customer.parquet", cn))


def _side_qualified_join() -> LogicalPlan:
    """t(a, ta) JOIN u(b, ub) with no keys and `left.a = right.b AND left.ta >
    right.ub` as its predicate: `a = b` becomes the key."""
    var jt: List[String] = ["a", "ta"]
    var ju: List[String] = ["b", "ub"]
    var res = _and(
        Expr.binary(BIN_EQ, Expr.left("a"), Expr.right("b")),
        Expr.binary(BIN_GT, Expr.left("ta"), Expr.right("ub")),
    )
    return LogicalPlan.join(
        _scan("t.parquet", jt), _scan("u.parquet", ju), List[String](), List[String](),
        JOIN_INNER, JOIN_ALGO_AUTO, Optional[OwnedPointer[Expr]](OwnedPointer(res^)),
    )


# --- Steps 6-9: expressions and filters ---


def _fold_in_a_project() -> LogicalPlan:
    """Project[a, 1 + 2 AS x] over s(a, b), no Filter anywhere."""
    var n: List[String] = ["a", "b"]
    var pe = ExprArray()
    pe.append(_c("a"))
    pe.append(Expr.alias(Expr.binary(BIN_ADD, _lit(1), _lit(2)), "x"))
    return LogicalPlan.project(pe^, _scan("s.parquet", n))


def _double_negation_filter() -> LogicalPlan:
    """Filter(NOT NOT (a > 3)) over s(a, b)."""
    var n: List[String] = ["a", "b"]
    var pred = Expr.unary(UN_NOT, Expr.unary(UN_NOT, _gt("a", 3)))
    return LogicalPlan.filter(pred^, _scan("s.parquet", n))


def _cse_in_aggregate_args() -> LogicalPlan:
    """SUM(a + b) AS s1, SUM((a + b) * c) AS s2 directly over s(a, b, c)."""
    var n: List[String] = ["a", "b", "c"]
    var ab = Expr.binary(BIN_ADD, _c("a"), _c("b"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(ab.copy()), Optional(String("s1"))))
    aggs.append(AggExpr(
        AGG_SUM, Optional(Expr.binary(BIN_MUL, ab.copy(), _c("c"))), Optional(String("s2"))
    ))
    return LogicalPlan.aggregate(ExprArray(), aggs^, _scan("s.parquet", n))


def _cse_in_a_project() -> LogicalPlan:
    """Project[(a + 1) * 2 AS x, (a + 1) * 3 AS y] over s(a, b)."""
    var n: List[String] = ["a", "b"]
    var a1 = Expr.binary(BIN_ADD, _c("a"), _lit(1))
    var ce = ExprArray()
    ce.append(Expr.alias(Expr.binary(BIN_MUL, a1.copy(), _lit(2)), "x"))
    ce.append(Expr.alias(Expr.binary(BIN_MUL, a1.copy(), _lit(3)), "y"))
    return LogicalPlan.project(ce^, _scan("s.parquet", n))


def _stacked_having() -> LogicalPlan:
    """Filter(total < 100) over Filter(total > 5) over SUM(v) AS total GROUP
    BY g over sales(g, v)."""
    var n: List[String] = ["g", "v"]
    var inner = LogicalPlan.filter(
        _gt("total", 5), _agg_sum("g", "v", "total", _scan("sales.parquet", n))
    )
    return LogicalPlan.filter(Expr.binary(BIN_LT, _c("total"), _lit(100)), inner^)


def _symmetric_or_over_join() -> LogicalPlan:
    """Filter((a = 1 AND b = 2) OR (a = 2 AND b = 1)) over t(a, ta) JOIN
    u(b, ub) ON ta = ub."""
    var tn: List[String] = ["a", "ta"]
    var un: List[String] = ["b", "ub"]
    var sym = _or(_and(_eq("a", 1), _eq("b", 2)), _and(_eq("a", 2), _eq("b", 1)))
    var j = LogicalPlan.join(
        _scan("t.parquet", tn), _scan("u.parquet", un), _l1("ta"), _l1("ub"), JOIN_INNER
    )
    return LogicalPlan.filter(sym^, j^)


def _or_held_back_by_a_when() -> LogicalPlan:
    """Filter((W AND k = 1 AND b = 2) OR (W AND k = 1 AND c = 3)) over
    t(a, b, c, k), W a CASE comparison."""
    var n: List[String] = ["a", "b", "c", "k"]
    var pred = _or_with_when("a", _eq("k", 1), _eq("b", 2), _eq("c", 3))
    return LogicalPlan.filter(pred^, _scan("t.parquet", n))


def _factored_conjunct_over_join() -> LogicalPlan:
    """The WHEN-held OR over t(a, b, c, k) JOIN u(k2, u) ON k = k2."""
    var tn: List[String] = ["a", "b", "c", "k"]
    var un: List[String] = ["k2", "u"]
    var w = _when_eq_1("a")
    var pred = _or(
        _and(_eq("k", 1), _and(_eq("b", 2), w.copy())),
        _and(_eq("k", 1), _and(_eq("c", 3), w.copy())),
    )
    var j = LogicalPlan.join(
        _scan("t.parquet", tn), _scan("u.parquet", un), _l1("k"), _l1("k2"), JOIN_INNER
    )
    return LogicalPlan.filter(pred^, j^)


# --- Steps 10-16: joins, projects, aggregates ---


def _projection_into_join_scans() -> LogicalPlan:
    """Project[a, u] over t(a, k, te) JOIN u(u, k2, ue) ON k = k2."""
    var pt: List[String] = ["a", "k", "te"]
    var pu: List[String] = ["u", "k2", "ue"]
    var keep: List[String] = ["a", "u"]
    var j = LogicalPlan.join(
        _scan("t.parquet", pt), _scan("u.parquet", pu), _l1("k"), _l1("k2"), JOIN_INNER
    )
    return LogicalPlan.project(_cols(keep^), j^)


def _cross_join_equality_under_cse() -> LogicalPlan:
    """Filter((W AND ax = bx AND by = 2) OR (W AND ax = bx AND ay = 3)) over
    A(100 rows) CROSS JOIN B(1000 rows): step 16 makes it an INNER join."""
    var an: List[String] = ["ax", "ay"]
    var bn: List[String] = ["bx", "by"]
    var pred = _or_with_when("ay", _ceq("ax", "bx"), _eq("by", 2), _eq("ay", 3))
    var cross = LogicalPlan.join(
        _scan("A", an, 100), _scan("B", bn, 1000), List[String](), List[String](), JOIN_CROSS
    )
    return LogicalPlan.filter(pred^, cross^)


def _cross_join_to_semi() -> LogicalPlan:
    """Project[ax, ay] over Filter(ax = cx) over A CROSS JOIN (SUM(cy) GROUP
    BY cx over C): an INNER join, then a SEMI join."""
    var an: List[String] = ["ax", "ay"]
    var cn: List[String] = ["cx", "cy"]
    var cross = LogicalPlan.join(
        _scan("A", an, 100), _agg_sum("cx", "cy", "s", _scan("C", cn, 10)),
        List[String](), List[String](), JOIN_CROSS,
    )
    var keep: List[String] = ["ax", "ay"]
    return LogicalPlan.project(_cols(keep^), LogicalPlan.filter(_ceq("ax", "cx"), cross^))


def _identity_project() -> LogicalPlan:
    """Project[a, b] over s(a, b)."""
    var n: List[String] = ["a", "b"]
    var ab: List[String] = ["a", "b"]
    return LogicalPlan.project(_cols(ab^), _scan("s.parquet", n))


def _fd_group_keys() -> LogicalPlan:
    """Project[ip, k0 AS c1, k1 AS c2, c] over COUNT(*) AS c GROUP BY ip, k0,
    k1 over Project[ip, ip - 1 AS k0, ip - 2 AS k1] over hits(ip)."""
    var inner = ExprArray()
    inner.append(_c("ip"))
    inner.append(Expr.alias(Expr.binary(BIN_SUB, _c("ip"), _lit(1)), "k0"))
    inner.append(Expr.alias(Expr.binary(BIN_SUB, _c("ip"), _lit(2)), "k1"))
    var ip: List[String] = ["ip"]
    var inner_proj = LogicalPlan.project(inner^, _scan("hits.parquet", ip))
    var gb = ExprArray()
    gb.append(_c("ip"))
    gb.append(_c("k0"))
    gb.append(_c("k1"))
    var aggs = AggExprArray()
    var no_child: Optional[Expr] = None
    aggs.append(AggExpr(AGG_COUNT, no_child^, Optional(String("c"))))
    var agg = LogicalPlan.aggregate(gb^, aggs^, inner_proj^)
    var outer = ExprArray()
    outer.append(_c("ip"))
    outer.append(Expr.alias(_c("k0"), "c1"))
    outer.append(Expr.alias(_c("k1"), "c2"))
    outer.append(_c("c"))
    return LogicalPlan.project(outer^, agg^)


def _computed_aggregate_input_over_join() -> LogicalPlan:
    """SUM(x) AS s GROUP BY g over Project[g, a * b AS x] over t(g, a, k)
    JOIN u(k2, b) ON k = k2."""
    var mt: List[String] = ["g", "a", "k"]
    var mu: List[String] = ["k2", "b"]
    var mp = ExprArray()
    mp.append(_c("g"))
    mp.append(Expr.alias(Expr.binary(BIN_MUL, _c("a"), _c("b")), "x"))
    var j = LogicalPlan.join(
        _scan("t.parquet", mt), _scan("u.parquet", mu), _l1("k"), _l1("k2"), JOIN_INNER
    )
    return _agg_sum("g", "x", "s", LogicalPlan.project(mp^, j^))


# --- Steps 17-19: limits and windows ---


def _limit_over_sort_under_project() -> LogicalPlan:
    """Limit 10 over Project[a + 1 AS x, a] over Sort(a ASC) over s(a, b):
    the Limit moves below the Project and fuses with the Sort into TopN."""
    var n: List[String] = ["a", "b"]
    var lp = ExprArray()
    lp.append(Expr.alias(Expr.binary(BIN_ADD, _c("a"), _lit(1)), "x"))
    lp.append(_c("a"))
    var p = LogicalPlan.project(lp^, LogicalPlan.sort(_l1("a"), _asc(), _scan("s.parquet", n)))
    return LogicalPlan.limit(10, p^)


def _limit_over_sort_over_filter() -> LogicalPlan:
    """Limit 10 over Sort(a ASC) over Filter(b > 3) over s(a, b)."""
    var n: List[String] = ["a", "b"]
    var f = LogicalPlan.filter(_gt("b", 3), _scan("s.parquet", n))
    return LogicalPlan.limit(10, LogicalPlan.sort(_l1("a"), _asc(), f^))


def _two_partition_bys() raises -> LogicalPlan:
    """PartitionBy(rank) over PartitionBy(row_number) over w(a, b, c), both
    partitioned on a and ordered on b DESC: fused into one."""
    var wn: List[String] = ["a", "b", "c"]
    return _pb(PartitionExpr.rank(), _pb(PartitionExpr.row_number(), _scan("w.parquet", wn)))


def _window_function_in_a_project() -> LogicalPlan:
    """Project[g, v, rank() OVER (PARTITION BY g) AS r] over w(g, v): no
    PartitionBy yet."""
    var n: List[String] = ["g", "v"]
    var pe = ExprArray()
    pe.append(_c("g"))
    pe.append(_c("v"))
    pe.append(col("v").rank().over("g").alias("r"))
    return LogicalPlan.project(pe^, _scan("w.parquet", n))


def _window_fn_as_aggregate_input() -> LogicalPlan:
    """SUM(rank() OVER (PARTITION BY g)) AS s GROUP BY g over w(g, v): the
    input holds no Project. Step 15 moves the window function into a new
    Project below the Aggregate, so the window gate's Project arm is true
    only on the current plan; a flag scanned after step 4 is false. The
    window expression carries no alias of its own: the rewrite matches a
    single Alias over the WindowFn, which step 15 adds."""
    var n: List[String] = ["g", "v"]
    var aggs = AggExprArray()
    aggs.append(AggExpr(
        AGG_SUM, Optional(col("v").rank().over("g")), Optional(String("s"))
    ))
    return LogicalPlan.aggregate(_cols(_l1("g")), aggs^, _scan("w.parquet", n))


def _row_number_filter() raises -> LogicalPlan:
    """Project[a, b, c] over Filter(rn <= 5) over PartitionBy(row_number AS
    rn) over w(a, b, c): a per-partition top-N."""
    var wn: List[String] = ["a", "b", "c"]
    var pb = _pb(PartitionExpr.row_number(), _scan("w.parquet", wn))
    var rn = pb.output_schema.field_name(pb.output_schema.num_columns() - 1)
    var keep: List[String] = ["a", "b", "c"]
    var f = LogicalPlan.filter(Expr.binary(BIN_LE, _c(rn), _lit(5)), pb^)
    return LogicalPlan.project(_cols(keep^), f^)


def _limit_over_sort_over_partition_by(two_keys: Bool) raises -> LogicalPlan:
    """Limit 10 over Sort(a ASC), or Sort(a ASC, b DESC) if `two_keys`, over
    PartitionBy(row_number) over w(a, b, c). `fuse_sort_limit` makes the
    Limit and the Sort one TopN before the window rewrite runs; run after it,
    the rewrite has removed the Sort (the PartitionBy's order satisfies it)
    and a plain Limit is left."""
    var wn: List[String] = ["a", "b", "c"]
    var keys = _l1("a")
    var desc = _asc()
    if two_keys:
        keys.append("b")
        desc.append(True)
    var pb = _pb(PartitionExpr.row_number(), _scan("w.parquet", wn))
    return LogicalPlan.limit(10, LogicalPlan.sort(keys^, desc^, pb^))


def _row_number_filter_over_two_partition_bys() raises -> LogicalPlan:
    """Project[a, b, c] over Filter(rn <= 5) over PartitionBy(row_number AS
    rn) over PartitionBy(rank) over w(a, b, c). The window rewrite fuses the
    two PartitionBys into one with both functions, which `fuse_partition_topn`
    then leaves alone; run before the rewrite, it makes the upper one a
    PartitionTopN."""
    var wn: List[String] = ["a", "b", "c"]
    var pb = _pb(PartitionExpr.row_number(), _pb(PartitionExpr.rank(), _scan("w.parquet", wn)))
    var rn = pb.output_schema.field_name(pb.output_schema.num_columns() - 1)
    var keep: List[String] = ["a", "b", "c"]
    var f = LogicalPlan.filter(Expr.binary(BIN_LE, _c(rn), _lit(5)), pb^)
    return LogicalPlan.project(_cols(keep^), f^)


def _identity_project_under_a_partition_topn() raises -> LogicalPlan:
    """Project[g, v, rank() OVER (PARTITION BY g) AS r] over PartitionTopN(g;
    v; k=1) over Project[g, v] over PartitionTopN(g; v; k=2) over w(g, v).
    The input holds no PartitionBy; step 18 makes one from the window
    function, and step 19 then absorbs the identity Project over the inner
    PartitionTopN. A step-19 gate reading PartitionBy from a scan after
    step 4 skips the step and leaves that Project."""
    var n: List[String] = ["g", "v"]
    var inner = LogicalPlan.partition_topn(
        _l1("g"), _l1("v"), _asc(), 2, _scan("w.parquet", n)
    )
    var ident: List[String] = ["g", "v"]
    var mid = LogicalPlan.project(_cols(ident^), inner^)
    var outer = LogicalPlan.partition_topn(_l1("g"), _l1("v"), _asc(), 1, mid^)
    var pe = ExprArray()
    pe.append(_c("g"))
    pe.append(_c("v"))
    pe.append(col("v").rank().over("g").alias("r"))
    return LogicalPlan.project(pe^, outer^)


# -----------------------------------------------------------------------------
# The table: plan i, and the pass (driver step) whose drop it shows
# -----------------------------------------------------------------------------


comptime _N_PLANS = 28


def _plan_name(i: Int) -> String:
    var names: List[String] = [
        "partition_prune_scans (1): year_scan_filter",
        "attach_hive_predicate (1): hive_dir_scan_filter",
        "flatten_dependent_joins (4): exists_filter",
        "join_predicate_decompose (4): side_qualified_join",
        "fold_constants (6): fold_in_a_project",
        "simplify_predicates (6): double_negation_filter",
        "eliminate_common_subexpressions (8), materialize_agg_input (15): cse_in_aggregate_args",
        "eliminate_common_subexpressions (8), merge_projects (13): cse_in_a_project",
        "fuse_filters (9): stacked_having",
        "decompose_symmetric_or, decompose_filters (9): symmetric_or_over_join",
        "second factor_or_conjuncts (9): or_held_back_by_a_when",
        "push_predicates_down (16): factored_conjunct_over_join",
        "eliminate_cross_join (16): cross_join_equality_under_cse",
        "eliminate_cross_join (10), convert_inner_to_semi (14), eliminate_identity_projects (16): cross_join_to_semi",
        "eliminate_identity_projects (13): identity_project",
        "elide_functionally_dependent_group_keys (12): fd_group_keys",
        "push_projections_down with prune_columns (11): projection_into_join_scans",
        "absorb_expression_into_aggregate (14): computed_aggregate_input_over_join",
        "push_limit_down (17): limit_over_sort_under_project",
        "fuse_sort_limit (17): limit_over_sort_over_filter",
        "optimize_window_rewrite (18): two_partition_bys",
        "the window gate's Project arm (18): window_function_in_a_project",
        "the window gate's Project arm reads the current plan (18): window_fn_as_aggregate_input",
        "fuse_partition_topn (19): row_number_filter",
        "fuse_sort_limit (17) before optimize_window_rewrite (18): limit_over_sort_over_partition_by",
        "fuse_sort_limit (17) before optimize_window_rewrite (18): limit_over_two_key_sort_over_partition_by",
        "optimize_window_rewrite (18) before fuse_partition_topn (19): row_number_filter_over_two_partition_bys",
        "the step-19 gate reads the current plan (19): identity_project_under_a_partition_topn",
    ]
    return names[i]


def _plan_at(i: Int) raises -> LogicalPlan:
    if i == 0:
        return _year_scan_filter()
    if i == 1:
        return _hive_dir_scan_filter()
    if i == 2:
        return _exists_filter()
    if i == 3:
        return _side_qualified_join()
    if i == 4:
        return _fold_in_a_project()
    if i == 5:
        return _double_negation_filter()
    if i == 6:
        return _cse_in_aggregate_args()
    if i == 7:
        return _cse_in_a_project()
    if i == 8:
        return _stacked_having()
    if i == 9:
        return _symmetric_or_over_join()
    if i == 10:
        return _or_held_back_by_a_when()
    if i == 11:
        return _factored_conjunct_over_join()
    if i == 12:
        return _cross_join_equality_under_cse()
    if i == 13:
        return _cross_join_to_semi()
    if i == 14:
        return _identity_project()
    if i == 15:
        return _fd_group_keys()
    if i == 16:
        return _projection_into_join_scans()
    if i == 17:
        return _computed_aggregate_input_over_join()
    if i == 18:
        return _limit_over_sort_under_project()
    if i == 19:
        return _limit_over_sort_over_filter()
    if i == 20:
        return _two_partition_bys()
    if i == 21:
        return _window_function_in_a_project()
    if i == 22:
        return _window_fn_as_aggregate_input()
    if i == 23:
        return _row_number_filter()
    if i == 24:
        return _limit_over_sort_over_partition_by(False)
    if i == 25:
        return _limit_over_sort_over_partition_by(True)
    if i == 26:
        return _row_number_filter_over_two_partition_bys()
    return _identity_project_under_a_partition_topn()


def test_portable_renders_as_optimize_on_a_plan_per_pass() raises:
    """On each plan of the table, `optimize_portable` (v1) renders byte for
    byte as `optimize`, and `optimize` records no request on it.

    Defect caught: a pass of the driver's order made conditional on
    `narrow_payload` (so `optimize` runs it and `optimize_portable` does not),
    for every pass call but the two named in the header. A Limit block gated
    that way, for one, leaves `Limit(n=10)` where `optimize` has
    `TopN(n=10, keys=[a ASC])`."""
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
