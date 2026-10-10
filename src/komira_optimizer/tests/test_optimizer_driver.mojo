# =============================================================================
# test_optimizer_driver -- the pass order, the config flags and the refusals of
# `optimizer_driver.optimize`
# =============================================================================
#
# Every plan here is built so that its optimized form depends on one decision
# of the driver: which of two passes runs first, whether a node-kind gate sees
# a node an earlier pass created, whether a config flag is read, and what a
# refusal returns. Each test names the driver defect it catches; a defect in a
# rule itself belongs to that rule's own tests.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT, AGG_SUM, sum as agg_sum
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_SUB, BIN_EQ, BIN_GT, BIN_AND, BIN_OR, UN_NOT
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_stats.table_stats import (
    ColumnStats, TableStats, STATS_SOURCE_PARQUET_METADATA,
)
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    CORR_KIND_SCALAR,
    JOIN_INNER,
    JOIN_SEMI,
    JOIN_CROSS,
    JOIN_ALGO_AUTO,
    PLAN_SCAN,
    PLAN_JOIN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
)
from komira_optimizer.optimizer_config import OptimizerConfig
from komira_optimizer.optimizer_result import OPTIMIZE_ERR_PASS_REFUSED
from komira_optimizer.optimizer_scalar_deps import ScalarDepTable
from komira_optimizer.optimizer_driver import optimize, optimize_status


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


def _eq(c: String, v: Int) -> Expr:
    return Expr.binary(BIN_EQ, Expr.col_ref(c), _lit(v))


def _l1(a: String) -> List[String]:
    var o = List[String]()
    o.append(a)
    return o^


def _render(p: LogicalPlan) -> String:
    var s = String("")
    p.write_to(s)
    return s


def _names(p: LogicalPlan) -> String:
    var s = String("")
    for i in range(p.output_schema.num_columns()):
        s += p.output_schema.field_name(i) + ","
    return s


def _run(var p: LogicalPlan, config: OptimizerConfig = OptimizerConfig()) raises -> LogicalPlan:
    var deps = ScalarDepTable()
    return optimize(p^, config, deps)


def _shared_conjunct_or() -> LogicalPlan:
    """Filter(((a+1) > 5 AND b = 2) OR ((a+1) > 5 AND c = 3)) over t(a, b, c, k)."""
    var c = Expr.binary(BIN_GT, Expr.binary(BIN_ADD, Expr.col_ref("a"), _lit(1)), _lit(5))
    var pred = Expr.binary(
        BIN_OR,
        Expr.binary(BIN_AND, c.copy(), _eq("b", 2)),
        Expr.binary(BIN_AND, c.copy(), _eq("c", 3)),
    )
    var t_names: List[String] = ["a", "b", "c", "k"]
    return LogicalPlan.filter(pred^, _scan("t.parquet", t_names))


def _global_agg() -> LogicalPlan:
    """SELECT SUM(o_total) AS v FROM orders: one row, one column."""
    var on: List[String] = ["o_total"]
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("o_total")), Optional(String("v"))))
    return LogicalPlan.aggregate(ExprArray(), aggs^, _scan("orders.parquet", on))


def _grouped_agg() -> LogicalPlan:
    """Project [v] over SUM(o_total) AS v GROUP BY o_total: one row per group."""
    var on: List[String] = ["o_total"]
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("o_total")), Optional(String("v"))))
    var gb = ExprArray()
    gb.append(Expr.col_ref("o_total"))
    var agg = LogicalPlan.aggregate(gb^, aggs^, _scan("orders.parquet", on))
    var pe = ExprArray()
    pe.append(Expr.col_ref("v"))
    return LogicalPlan.project(pe^, agg^)


def _scalar_subquery_filter(var inner: LogicalPlan) -> LogicalPlan:
    """Filter(c_acctbal > (uncorrelated scalar subquery over `inner`)) over customer."""
    var cn: List[String] = ["c_custkey", "c_acctbal"]
    var pred = Expr.binary(
        BIN_GT,
        Expr.col_ref("c_acctbal"),
        Expr.correlated_subquery(inner^, List[String](), CORR_KIND_SCALAR),
    )
    return LogicalPlan.filter(pred^, _scan("customer.parquet", cn))


def _or_of_equalities_residual_join() -> LogicalPlan:
    """customer INNER JOIN orders ON c_custkey = o_custkey, residual
    `o_orderkey = 1 OR o_orderkey = 2 OR o_orderkey = 3` (orders only). The
    input has no Filter node."""
    var c_names: List[String] = ["c_custkey", "c_name"]
    var o_names: List[String] = ["o_orderkey", "o_custkey", "o_total"]
    var res = Expr.binary(
        BIN_OR,
        Expr.binary(BIN_OR, _eq("o_orderkey", 1), _eq("o_orderkey", 2)),
        _eq("o_orderkey", 3),
    )
    return LogicalPlan.join(
        _scan("customer.parquet", c_names),
        _scan("orders.parquet", o_names),
        _l1("c_custkey"),
        _l1("o_custkey"),
        JOIN_INNER,
        JOIN_ALGO_AUTO,
        Optional[OwnedPointer[Expr]](OwnedPointer(res^)),
    )


def _minus(c: String, k: Int) -> Expr:
    return Expr.binary(BIN_SUB, Expr.col_ref(c), _lit(k))


def _fd_group_keys() -> LogicalPlan:
    """Project [ip, k0 AS c1, k1 AS c2, c]
         Aggregate [ip, k0, k1; COUNT(*) AS c]
           Project [ip, ip-1 AS k0, ip-2 AS k1]
             Scan hits(ip)"""
    var inner = ExprArray()
    inner.append(Expr.col_ref("ip"))
    inner.append(Expr.alias(_minus("ip", 1), "k0"))
    inner.append(Expr.alias(_minus("ip", 2), "k1"))
    var ip: List[String] = ["ip"]
    var inner_proj = LogicalPlan.project(inner^, _scan("hits.parquet", ip))
    var gb = ExprArray()
    gb.append(Expr.col_ref("ip"))
    gb.append(Expr.col_ref("k0"))
    gb.append(Expr.col_ref("k1"))
    var aggs = AggExprArray()
    var no_child: Optional[Expr] = None
    aggs.append(AggExpr(AGG_COUNT, no_child^, Optional(String("c"))))
    var agg = LogicalPlan.aggregate(gb^, aggs^, inner_proj^)
    var outer = ExprArray()
    outer.append(Expr.col_ref("ip"))
    outer.append(Expr.alias(Expr.col_ref("k0"), "c1"))
    outer.append(Expr.alias(Expr.col_ref("k1"), "c2"))
    outer.append(Expr.col_ref("c"))
    return LogicalPlan.project(outer^, agg^)


def _side_stats(key: String, payload: String, extra: String, hi: Int64) raises -> TableStats:
    """Footer statistics: key in [0, 24999999], payload in [1, hi], extra in [0, 7]."""
    var names = List[String]()
    var stats = List[ColumnStats]()
    names.append(key)
    stats.append(ColumnStats(
        None,
        Optional[ScalarValue](ScalarValue.from_int64(0)),
        Optional[ScalarValue](ScalarValue.from_int64(24999999)),
        Optional[Int](0),
    ))
    names.append(payload)
    stats.append(ColumnStats(
        None,
        Optional[ScalarValue](ScalarValue.from_int64(1)),
        Optional[ScalarValue](ScalarValue.from_int64(hi)),
        Optional[Int](0),
    ))
    names.append(extra)
    stats.append(ColumnStats(
        None,
        Optional[ScalarValue](ScalarValue.from_int64(0)),
        Optional[ScalarValue](ScalarValue.from_int64(7)),
        Optional[Int](0),
    ))
    return TableStats(1000, names^, stats^, STATS_SOURCE_PARQUET_METADATA)


def _stamped_side(path: String, payload: String, extra: String, hi: Int64) raises -> LogicalPlan:
    var n = List[String]()
    n.append("key")
    n.append(payload)
    n.append(extra)
    return LogicalPlan.scan(
        path, SOURCE_PARQUET, _schema(n), None, None, None,
        Optional[TableStats](_side_stats("key", payload, extra, hi)),
    )


def _narrowable_join() raises -> LogicalPlan:
    """Project [key, probe_val, build_val] over
    probe(key, probe_val, p_extra) INNER JOIN build(key, build_val, b_extra).
    The unused `*_extra` columns make projection pushdown rewrite both scans."""
    var j = LogicalPlan.join(
        _stamped_side("probe.parquet", "probe_val", "p_extra", 999),
        _stamped_side("build.parquet", "build_val", "b_extra", 9999),
        _l1("key"),
        _l1("key"),
        JOIN_INNER,
    )
    var pe = ExprArray()
    pe.append(Expr.col_ref("key"))
    pe.append(Expr.col_ref("probe_val"))
    pe.append(Expr.col_ref("build_val"))
    return LogicalPlan.project(pe^, j^)


def _narrow_specs(p: LogicalPlan) -> String:
    """`path:column:bytes;` for every payload-narrow stamp, depth first."""
    var out = String("")
    if p.tag == PLAN_SCAN:
        ref sd = p._scan.value()[]
        for i in range(len(sd.payload_narrow)):
            out += sd.source_path + ":" + sd.payload_narrow[i].column_name + ":"
            out += String(Int(sd.payload_narrow[i].target_bytes)) + ";"
    elif p.tag == PLAN_JOIN:
        out += _narrow_specs(p._join.value()[].left[])
        out += _narrow_specs(p._join.value()[].right[])
    elif p.tag == PLAN_PROJECT:
        out += _narrow_specs(p._project.value()[].child[])
    return out^


def _big_small_join() -> LogicalPlan:
    """big(b_k, b_v) 100000 rows INNER JOIN small(s_k, s_v) 10 rows:
    output [b_k, b_v, s_k, s_v]."""
    var bn: List[String] = ["b_k", "b_v"]
    var sn: List[String] = ["s_k", "s_v"]
    return LogicalPlan.join(
        _scan("big", bn, 100000), _scan("small", sn, 10), _l1("b_k"), _l1("s_k"), JOIN_INNER
    )


def _semi_over_inner() -> LogicalPlan:
    """SEMI(INNER(a, b), c) on ak = ck, with c (10 rows) smaller than b (1000)."""
    var an: List[String] = ["ak", "av"]
    var bn: List[String] = ["bk", "bv"]
    var cn: List[String] = ["ck", "cv"]
    var inner = LogicalPlan.join(
        _scan("a", an, 1000), _scan("b", bn, 1000), _l1("ak"), _l1("bk"), JOIN_INNER
    )
    return LogicalPlan.join(inner^, _scan("c", cn, 10), _l1("ak"), _l1("ck"), JOIN_SEMI)


def _star_aggregate() -> LogicalPlan:
    """SUM(measure) AS total GROUP BY dim_attr over fact INNER JOIN dim."""
    var fnames: List[String] = ["fk_id", "measure"]
    var dnames: List[String] = ["dim_id", "dim_attr"]
    var j = LogicalPlan.join(
        _scan("fact.parquet", fnames), _scan("dim.parquet", dnames),
        _l1("fk_id"), _l1("dim_id"), JOIN_INNER,
    )
    var gb = ExprArray()
    gb.append(col("dim_attr").copy_expr())
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("measure")).alias("total"))
    return LogicalPlan.aggregate(gb^, aggs^, j^)


def _correlated_subquery_in_project() -> LogicalPlan:
    """Project [c_custkey, (correlated scalar subquery on c_custkey) AS s]:
    a shape `flatten_dependent_joins` refuses."""
    var cn: List[String] = ["c_custkey", "c_acctbal"]
    var pe = ExprArray()
    pe.append(Expr.col_ref("c_custkey"))
    pe.append(Expr.alias(
        Expr.correlated_subquery(_global_agg(), _l1("c_custkey"), CORR_KIND_SCALAR), "s"
    ))
    return LogicalPlan.project(pe^, _scan("customer.parquet", cn))


# -----------------------------------------------------------------------------
# Pass order
# -----------------------------------------------------------------------------


def test_or_factoring_runs_before_cse() raises:
    """`(a+1) > 5` is shared by both OR branches. Factored first, it occurs
    once (`(a+1) > 5 AND (b = 2 OR c = 3)`) and CSE leaves it alone, so the
    result is a Filter straight over the scan.

    Defect caught: CSE before the first OR factoring. CSE then sees the
    conjunct twice and hoists it into a synthesized `_cse_*` column of a
    Project under the Filter, which no pushdown can route into a scan."""
    var out = _run(_shared_conjunct_or())
    var r = _render(out)
    assert_equal(r.find("_cse_"), -1, r)
    assert_equal(Int(out.tag), Int(PLAN_FILTER), r)
    assert_equal(Int(out._filter.value()[].child[].tag), Int(PLAN_SCAN), r)
    assert_true(r.startswith("Filter(predicate=BinaryOp(AND, BinaryOp(GT, BinaryOp(ADD, ColRef(a)"), r)


def test_decorrelation_runs_before_scalar_resolution() raises:
    """A subquery over a global aggregate is provably one row, so
    decorrelation turns it into a CROSS join and nothing is left to bind: one
    call, no request.

    Defect caught: `resolve_scalar_subqueries_rewrite` before
    `scalar_subquery_decorrelate`. It records a request for the unbound site
    first, and the caller would execute a sub-plan the rewrite did not need."""
    var deps = ScalarDepTable()
    var out = optimize(_scalar_subquery_filter(_global_agg()), OptimizerConfig(), deps)
    var r = _render(out)
    assert_equal(deps.num_requests(), 0, r)
    assert_true(r.find("Join(type=CROSS") >= 0, r)
    assert_true(r.find("__scalar_subq_0") >= 0, r)


def test_an_unbound_subquery_records_one_request_and_returns_a_plan() raises:
    """A subquery that is not provably one row is left for the caller: the
    call returns a plan and `deps` holds one request. The driver does not loop
    and does not refuse.

    Defect caught: a driver that refuses (or loops on) an unbound round
    instead of handing the request back."""
    var deps = ScalarDepTable()
    var r = optimize_status(_scalar_subquery_filter(_grouped_agg()), OptimizerConfig(), deps)
    assert_true(r.is_ok(), r.message())
    assert_equal(deps.num_requests(), 1)


def test_node_kinds_are_scanned_after_subquery_lowering() raises:
    """The grouped subquery's inner plan holds an identity `Project [v]`. It
    is inside an expression until `flatten_dependent_joins` lowers it into a
    LEFT join; the Project passes must see it in the same call.

    Defect caught: the node-kind scan taken on the input plan (before the
    subquery passes). `has_project` is then False, step 13 is skipped and the
    identity Project survives until a second call removes it."""
    var deps = ScalarDepTable()
    var out = optimize(_scalar_subquery_filter(_grouped_agg()), OptimizerConfig(), deps)
    var r = _render(out)
    assert_equal(r.find("Project("), -1, r)
    assert_true(r.find("Join(type=LEFT") >= 0, r)


def _filter_over_scan(var pred: Expr) -> LogicalPlan:
    var n: List[String] = ["a", "b"]
    return LogicalPlan.filter(pred^, _scan("s.parquet", n))


def test_constants_are_folded_before_pushdown() raises:
    """`a > 1 + 2` folds to `a > 3`, which pushdown then moves into the scan.

    Defect caught: the driver skipping `fold_constants` (or gating it on the
    wrong check). The literal sum survives into the scan filter."""
    var pred = Expr.binary(BIN_GT, Expr.col_ref("a"), Expr.binary(BIN_ADD, _lit(1), _lit(2)))
    var out = _run(_filter_over_scan(pred^))
    var r = _render(out)
    assert_equal(Int(out.tag), Int(PLAN_SCAN), r)
    assert_true(r.find("filter=BinaryOp(GT, ColRef(a), Literal(ScalarValue(int64, 3)))") >= 0, r)


def test_predicates_are_simplified_before_pushdown() raises:
    """`NOT NOT (a > 3)` simplifies to `a > 3`, which pushdown then moves into
    the scan.

    Defect caught: the driver skipping `simplify_predicates` (or gating it on
    the wrong check). The double negation survives into the plan."""
    var pred = Expr.unary(UN_NOT, Expr.unary(UN_NOT, Expr.binary(BIN_GT, Expr.col_ref("a"), _lit(3))))
    var out = _run(_filter_over_scan(pred^))
    var r = _render(out)
    assert_equal(r.find("NOT"), -1, r)
    assert_true(r.find("filter=BinaryOp(GT, ColRef(a), Literal(ScalarValue(int64, 3)))") >= 0, r)


def test_filter_gate_is_rescanned_after_join_residual_pushdown() raises:
    """The input has no Filter. `push_join_residual_to_side` turns the
    orders-only residual into a Filter on the orders scan, and the IN-list
    rewrite (gated on a Filter, Project or Aggregate) must then collapse the
    OR of equalities before pushdown folds it into the scan.

    Defect caught: `has_filter` not re-scanned after step 5. The IN-list
    rewrite is skipped and the scan filter stays an OR chain."""
    var out = _run(_or_of_equalities_residual_join())
    var r = _render(out)
    assert_true(r.find("filter=InList(ColRef(o_orderkey)") >= 0, r)
    assert_equal(r.find("BinaryOp(OR"), -1, r)


def test_fd_key_elision_runs_before_identity_project_elimination() raises:
    """Eliding `ip-1` and `ip-2` from the grouping leaves the aggregate's child
    `Project [ip]` an identity over the scan, and step 13 removes it: the
    Aggregate reads the scan directly with one key.

    Defect caught: the elision moved after step 13. The one-column identity
    Project stays between the Aggregate and its scan."""
    var out = _run(_fd_group_keys())
    var r = _render(out)
    assert_equal(Int(out.tag), Int(PLAN_PROJECT), r)
    ref agg = out._project.value()[].child[]
    assert_equal(Int(agg.tag), Int(PLAN_AGGREGATE), r)
    assert_equal(len(agg._aggregate.value()[].group_by), 1, r)
    assert_equal(Int(agg._aggregate.value()[].child[].tag), Int(PLAN_SCAN), r)
    assert_equal(_names(out), "ip,c1,c2,c,", r)


def test_payload_narrowing_runs_last() raises:
    """Both payload columns fit in two bytes and both scans are rewritten by
    projection pushdown (each drops its unused `*_extra` column). The stamps
    survive only because narrowing runs after every pass that rebuilds a scan.

    Defect caught: `narrow_join_payload` moved earlier. A later scan rebuild
    starts the stamp list empty and the rule looks wired but stamps nothing."""
    var out = _run(_narrowable_join())
    var r = _render(out)
    var specs = _narrow_specs(out)
    assert_true(specs.find("probe.parquet:probe_val:2;") >= 0, specs + "\n" + r)
    assert_true(specs.find("build.parquet:build_val:2;") >= 0, specs + "\n" + r)
    assert_true(r.find("projection=[") >= 0, r)


def test_join_reorder_output_order_is_restored() raises:
    """`big JOIN small`: the reorder puts `small` first and build-side
    selection swaps it back with its own order-restoring Project, which
    restores the REORDERED order. The query's order `[b_k, b_v, s_k, s_v]` is
    put back by the capture taken before both rules.

    Defect caught: the `restore_join_reorder_output_columns` call dropped (or
    the capture taken after the reorder). The plan answers with
    `[s_k, s_v, b_k, b_v]`."""
    var out = _run(_big_small_join())
    var r = _render(out)
    assert_equal(_names(out), "b_k,b_v,s_k,s_v,", r)


# -----------------------------------------------------------------------------
# Config flags
# -----------------------------------------------------------------------------


def test_eager_agg_on_pushes_a_partial_aggregate_below_the_join() raises:
    """Default config: the fact side gets a partial `SUM` grouped by `fk_id`.

    Defect caught: the driver never running `eager_aggregate_pushdown` (flag
    read inverted, or the call dropped)."""
    var out = _run(_star_aggregate())
    var r = _render(out)
    assert_true(r.find("__eager_sum_total") >= 0, r)
    assert_equal(_names(out), "dim_attr,total,", r)


def test_eager_agg_off_leaves_the_aggregate_above_the_join() raises:
    """`eager_agg = False`: one Aggregate, directly over the join.

    Defect caught: the driver ignoring `config.eager_agg`."""
    var config = OptimizerConfig()
    config.eager_agg = False
    var out = _run(_star_aggregate(), config)
    var r = _render(out)
    assert_equal(r.find("__eager"), -1, r)
    assert_equal(Int(out.tag), Int(PLAN_AGGREGATE), r)
    assert_equal(Int(out._aggregate.value()[].child[].tag), Int(PLAN_JOIN), r)


def test_semi_pushdown_on_moves_the_semi_below_the_inner_join() raises:
    """Default config: `SEMI(INNER(a, b), c)` becomes an INNER join over
    `SEMI(a, c)`.

    Defect caught: the driver not running `push_semi_reducers_down`, or
    running it after the reorder."""
    var out = _run(_semi_over_inner())
    var r = _render(out)
    assert_true(r.find("Join(type=INNER") >= 0, r)
    assert_true(r.find("Join(type=INNER") < r.find("Join(type=SEMI"), r)
    assert_equal(_names(out), "ak,av,bk,bv,", r)


def test_semi_pushdown_off_keeps_the_semi_on_top() raises:
    """`semi_pushdown = False`: the SEMI join stays the root.

    Defect caught: the driver handing the rule a config other than the
    caller's (for example a fresh `OptimizerConfig()`)."""
    var config = OptimizerConfig()
    config.semi_pushdown = False
    var out = _run(_semi_over_inner(), config)
    var r = _render(out)
    assert_equal(Int(out.tag), Int(PLAN_JOIN), r)
    assert_equal(Int(out._join.value()[].join_type), Int(JOIN_SEMI), r)


# -----------------------------------------------------------------------------
# Refusals
# -----------------------------------------------------------------------------


def test_a_refusing_pass_error_is_raised_unchanged() raises:
    """`flatten_dependent_joins` refuses a correlated subquery in a Project;
    `optimize` raises that pass's own message.

    Defect caught: the driver swallowing a refusal (returning a partly
    rewritten plan) or rewording the message."""
    var raised = False
    try:
        _ = _run(_correlated_subquery_in_project())
    except e:
        raised = True
        assert_equal(String(e), "correlated subquery in Project not yet supported")
    assert_true(raised, "optimize must raise the refusing pass's error")


def test_status_twin_classifies_a_refusal_and_carries_no_plan() raises:
    """`optimize_status` on the same plan: PASS_REFUSED, the pass's message
    verbatim, no plan.

    Defect caught: an `except` arm that drops the message, picks another
    status, or returns a plan."""
    var deps = ScalarDepTable()
    var r = optimize_status(_correlated_subquery_in_project(), OptimizerConfig(), deps)
    assert_false(r.is_ok())
    assert_equal(r.status(), OPTIMIZE_ERR_PASS_REFUSED)
    assert_equal(r.message(), "correlated subquery in Project not yet supported")
    assert_false(r.has_plan())


def test_status_twin_returns_the_same_plan_as_optimize() raises:
    """On a plan no pass refuses, `optimize_status` is OK and its plan renders
    exactly as `optimize`'s, under a non-default config.

    Defect caught: a status twin that runs a different pass list or does not
    pass the caller's config on (eager aggregation would then fire)."""
    var config = OptimizerConfig()
    config.eager_agg = False
    var expect = _render(_run(_star_aggregate(), config))
    var deps = ScalarDepTable()
    var r = optimize_status(_star_aggregate(), config, deps)
    assert_true(r.is_ok(), r.message())
    var got = r.take_plan()
    assert_true(Bool(got))
    assert_equal(_render(got.value()), expect)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
