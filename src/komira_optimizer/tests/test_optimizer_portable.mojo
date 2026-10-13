# =============================================================================
# test_optimizer_portable -- `optimizer_driver.optimize_portable`, the
# portable profile of komira-ai/komira#1094 (§5.3)
# =============================================================================
#
# What the profile promises, one test per promise:
#
#   * It runs the driver's pass order: on plans where payload narrowing has
#     nothing to stamp and no scalar needs binding, its output renders exactly
#     as `optimize`'s (seven plans here; `test_optimizer_portable_parity.mojo`
#     has one plan for each pass these seven do not reach).
#   * It turns off payload narrowing (a host-local rule) and folds no value
#     from an execution; a plan that needs one is refused by name with its
#     site count, and the decorrelated broadcast shape (which needs none) is
#     kept. A pass's own refusal is raised unchanged.
#   * It refuses a profile version it does not implement before any pass
#     runs.
#   * It reads `OptimizerConfig` from its argument only.
#   * Its output is the same bytes for the same input: across repeated runs on
#     separately built copies of one plan, and when the order of the columns
#     inside each scan's `TableStats` is permuted (a lookup is by name).
#
# The render (`LogicalPlan.write_to`) is the comparison: it is the plan's
# identity (`structural_hash` hashes it).
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_MAX, sum as agg_sum
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_EQ, BIN_GT, BIN_AND, BIN_OR
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
    JOIN_ALGO_AUTO,
    PLAN_SCAN,
    PLAN_JOIN,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
)
from komira_optimizer.optimizer_config import OptimizerConfig
from komira_optimizer.optimizer_scalar_deps import ScalarDepTable
from komira_optimizer.optimizer_driver import (
    optimize,
    optimize_portable,
    PortableProfile,
    PORTABLE_PROFILE_V1,
    PORTABLE_REFUSAL_UNKNOWN_PROFILE,
    PORTABLE_REFUSAL_NEEDS_EXECUTION,
)


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


def _v1() -> PortableProfile:
    return PortableProfile(PORTABLE_PROFILE_V1)


def _portable(var p: LogicalPlan, config: OptimizerConfig = OptimizerConfig()) raises -> LogicalPlan:
    return optimize_portable(p^, config, _v1())


def _in_process(var p: LogicalPlan, config: OptimizerConfig = OptimizerConfig()) raises -> LogicalPlan:
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


def _grouped_agg(path: String = "orders.parquet") -> LogicalPlan:
    """Project [v] over SUM(o_total) AS v GROUP BY o_total over `path`: one
    row per group."""
    var on: List[String] = ["o_total"]
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("o_total")), Optional(String("v"))))
    var gb = ExprArray()
    gb.append(Expr.col_ref("o_total"))
    var agg = LogicalPlan.aggregate(gb^, aggs^, _scan(path, on))
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


def _two_scalar_subquery_filters() -> LogicalPlan:
    """Filter(c_custkey > (scalar subquery over grouped lineitem)) over
    Filter(c_acctbal > (scalar subquery over grouped orders)) over customer:
    two sites, each needing an executed sub-plan. The inner plans differ, so
    the two requests are not de-duplicated into one. (One Filter ANDing the
    two comparisons is refused by `flatten_dependent_joins` instead: it lowers
    no scalar comparison from an AND chain.)"""
    var cn: List[String] = ["c_custkey", "c_acctbal"]
    var lower = Expr.binary(
        BIN_GT,
        Expr.col_ref("c_acctbal"),
        Expr.correlated_subquery(
            _grouped_agg("orders.parquet"), List[String](), CORR_KIND_SCALAR
        ),
    )
    var upper = Expr.binary(
        BIN_GT,
        Expr.col_ref("c_custkey"),
        Expr.correlated_subquery(
            _grouped_agg("lineitem.parquet"), List[String](), CORR_KIND_SCALAR
        ),
    )
    return LogicalPlan.filter(
        upper^, LogicalPlan.filter(lower^, _scan("customer.parquet", cn))
    )


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


def _broadcast_site() -> LogicalPlan:
    """Filter(total > max(total)) over SUM(v) AS total GROUP BY g over sales:
    the shape `scalar_broadcast_rewrite` folds from a bound value."""
    var sn: List[String] = ["g", "v"]
    var gb = ExprArray()
    gb.append(Expr.col_ref("g"))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("v")), Optional(String("total"))))
    var per_group = LogicalPlan.aggregate(gb^, aggs^, _scan("sales.parquet", sn))
    var pred = Expr.binary(
        BIN_GT, Expr.col_ref("total"), Expr.agg_fn(AGG_MAX, Expr.col_ref("total"))
    )
    return LogicalPlan.filter(pred^, per_group^)


def _or_of_equalities_residual_join() -> LogicalPlan:
    """customer INNER JOIN orders ON c_custkey = o_custkey, residual
    `o_orderkey = 1 OR o_orderkey = 2 OR o_orderkey = 3`."""
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


def _big_small_join() -> LogicalPlan:
    """big(b_k, b_v) 100000 rows INNER JOIN small(s_k, s_v) 10 rows."""
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


def _key_stats(key: String, payload: String, hi: Int64) raises -> TableStats:
    """key in [0, 24999999], payload in [1, hi]: both narrowable."""
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
    return TableStats(1000, names^, stats^, STATS_SOURCE_PARQUET_METADATA)


def _stamped_side(path: String, payload: String, hi: Int64) raises -> LogicalPlan:
    var n = List[String]()
    n.append("key")
    n.append(payload)
    return LogicalPlan.scan(
        path, SOURCE_PARQUET, _schema(n), None, None, None,
        Optional[TableStats](_key_stats("key", payload, hi)),
    )


def _narrowable_join() raises -> LogicalPlan:
    """probe(key, probe_val) INNER JOIN build(key, build_val), both payloads
    in two bytes: `optimize` stamps both scans."""
    return LogicalPlan.join(
        _stamped_side("probe.parquet", "probe_val", 999),
        _stamped_side("build.parquet", "build_val", 9999),
        _l1("key"),
        _l1("key"),
        JOIN_INNER,
    )


def _narrow_stamps(p: LogicalPlan) -> Int:
    """The number of payload-narrow stamps on the scans under joins."""
    if p.tag == PLAN_SCAN:
        return len(p._scan.value()[].payload_narrow)
    if p.tag == PLAN_JOIN:
        return _narrow_stamps(p._join.value()[].left[]) + _narrow_stamps(
            p._join.value()[].right[]
        )
    if p.tag == PLAN_PROJECT:
        return _narrow_stamps(p._project.value()[].child[])
    return 0


# --- A four-relation star DPccp reorders, with per-column NDV statistics. ---


def _ndv_stats(names: List[String], ndvs: List[Int], rows: Int, reverse: Bool) -> TableStats:
    """TableStats with one NDV per column, in `names` order or reversed."""
    var out_names = List[String]()
    var out_stats = List[ColumnStats]()
    for k in range(len(names)):
        var i = len(names) - 1 - k if reverse else k
        out_names.append(names[i])
        out_stats.append(ColumnStats(Optional[Int](ndvs[i])))
    return TableStats(rows, out_names^, out_stats^, STATS_SOURCE_PARQUET_METADATA)


def _stat_scan(
    path: String, names: List[String], ndvs: List[Int], rows: Int, reverse: Bool
) -> LogicalPlan:
    return LogicalPlan.scan(
        path, SOURCE_PARQUET, _schema(names), None, None, Optional[Int](rows),
        Optional[TableStats](_ndv_stats(names, ndvs, rows, reverse)),
    )


def _star4(reverse_stats: Bool) -> LogicalPlan:
    """Project [a_x, b_y, c_z, f_v] over
    ((fact JOIN a ON f_a = a_k) JOIN b ON f_b = b_k) JOIN c ON f_c = c_k.

    Four relations with statistics: `reorder_joins_with_dp` takes DPccp.
    `reverse_stats` lists every scan's TableStats columns in reverse order;
    the values per column name are the same."""
    var fnames: List[String] = ["f_a", "f_b", "f_c", "f_v"]
    var fv: List[Int] = [1000, 50000, 200, 999999]
    var an: List[String] = ["a_k", "a_x"]
    var av: List[Int] = [1000, 7]
    var bn: List[String] = ["b_k", "b_y"]
    var bv: List[Int] = [50000, 300]
    var cn: List[String] = ["c_k", "c_z"]
    var cv: List[Int] = [200, 3]
    var fa = LogicalPlan.join(
        _stat_scan("fact.parquet", fnames, fv, 1000000, reverse_stats),
        _stat_scan("a.parquet", an, av, 1000, reverse_stats),
        _l1("f_a"), _l1("a_k"), JOIN_INNER,
    )
    var fab = LogicalPlan.join(
        fa^, _stat_scan("b.parquet", bn, bv, 50000, reverse_stats),
        _l1("f_b"), _l1("b_k"), JOIN_INNER,
    )
    var fabc = LogicalPlan.join(
        fab^, _stat_scan("c.parquet", cn, cv, 200, reverse_stats),
        _l1("f_c"), _l1("c_k"), JOIN_INNER,
    )
    var pe = ExprArray()
    pe.append(Expr.col_ref("a_x"))
    pe.append(Expr.col_ref("b_y"))
    pe.append(Expr.col_ref("c_z"))
    pe.append(Expr.col_ref("f_v"))
    return LogicalPlan.project(pe^, fabc^)


comptime _N_FIXTURES = 7


def _plan_at(i: Int) raises -> LogicalPlan:
    """Plan `i` of the plans on which `optimize` stamps no narrowing and
    records no request."""
    if i == 0:
        return _shared_conjunct_or()
    if i == 1:
        return _star_aggregate()
    if i == 2:
        return _semi_over_inner()
    if i == 3:
        return _big_small_join()
    if i == 4:
        return _or_of_equalities_residual_join()
    if i == 5:
        return _scalar_subquery_filter(_global_agg())
    return _star4(False)


# -----------------------------------------------------------------------------
# The pass order is the driver's
# -----------------------------------------------------------------------------


def test_portable_output_renders_as_optimize_where_no_host_rule_applies() raises:
    """On seven plans (OR factoring, eager aggregation, SEMI pushdown, the
    reorder and build-side recording, the IN-list rewrite, a decorrelated scalar
    subquery, a DPccp star) where `optimize` stamps no narrowing and records no
    request, `optimize_portable` renders byte for byte as `optimize`.

    Defect caught: one of these passes made conditional on `narrow_payload`,
    so the portable entry skips it: scalar decorrelation (step 2), the join
    residual to side, the first OR factoring and the IN-list rewrite (steps
    5-8), eager aggregation, SEMI reducer pushdown, the join reorder,
    build-side selection and the order restore (steps 14-16).
    `test_optimizer_portable_parity.mojo` covers the other passes."""
    for i in range(_N_FIXTURES):
        var deps = ScalarDepTable()
        var want = optimize(_plan_at(i), OptimizerConfig(), deps)
        assert_equal(deps.num_requests(), 0, "fixture " + String(i))
        assert_equal(_narrow_stamps(want), 0, "fixture " + String(i))
        var got = _portable(_plan_at(i))
        assert_equal(_render(got), _render(want), "fixture " + String(i))


def test_portable_does_not_narrow_join_payload() raises:
    """`optimize` stamps both scans of the narrowable join; the portable
    profile stamps none: payload narrowing is a host-local rule.

    Defect caught: the portable entry running step 20."""
    var in_process = _in_process(_narrowable_join())
    assert_equal(_narrow_stamps(in_process), 2, _render(in_process))
    var portable = _portable(_narrowable_join())
    assert_equal(_narrow_stamps(portable), 0, _render(portable))


# -----------------------------------------------------------------------------
# Execution: nothing folded, a plan that needs it refused
# -----------------------------------------------------------------------------


def test_portable_keeps_the_decorrelated_broadcast_shape() raises:
    """A scalar subquery over a global aggregate is provably one row: the
    portable profile keeps the broadcast CROSS join and does not refuse.

    Defect caught: a portable entry that refuses every scalar subquery
    instead of only the ones that need an executed sub-plan."""
    var out = _portable(_scalar_subquery_filter(_global_agg()))
    var r = _render(out)
    assert_true(r.find("Join(type=CROSS") >= 0, r)
    assert_true(r.find("__scalar_subq_0") >= 0, r)


def _refusal(var p: LogicalPlan, profile: PortableProfile) -> String:
    try:
        var out = optimize_portable(p^, OptimizerConfig(), profile)
        return "no refusal: " + _render(out)
    except e:
        return String(e)


def test_portable_refuses_a_scalar_subquery_that_needs_execution() raises:
    """A scalar subquery over a grouped aggregate is not provably one row;
    only executing it gives the value. The portable profile refuses with
    `PORTABLE_REFUSAL_NEEDS_EXECUTION` and the site count.

    Defect caught: a portable entry that returns the plan of an unbound round
    (in-process `optimize` returns it with a request; flattening has lowered
    the subquery into a LEFT join that answers a mean instead of raising on
    more than one row)."""
    var msg = _refusal(_scalar_subquery_filter(_grouped_agg()), _v1())
    assert_equal(
        msg,
        PORTABLE_REFUSAL_NEEDS_EXECUTION + ": 1 scalar site(s) need an executed sub-plan",
    )


def test_portable_refuses_a_scalar_broadcast_site() raises:
    """`Filter(total > max(total))` over a grouped aggregate needs the
    executed maximum. The portable profile refuses it the same way.

    Defect caught: a portable entry that skips `scalar_broadcast_rewrite`
    instead of running it with no bindings; the site is then never recorded
    and a Filter holding an aggregate function reaches the host."""
    var msg = _refusal(_broadcast_site(), _v1())
    assert_equal(
        msg,
        PORTABLE_REFUSAL_NEEDS_EXECUTION + ": 1 scalar site(s) need an executed sub-plan",
    )


def test_portable_refusal_counts_every_site_that_needs_execution() raises:
    """Two scalar subqueries over different grouped aggregates, in two
    stacked Filters: the refusal says 2 sites.

    Defect caught: a refusal that reports a fixed or wrong count (a constant
    1, a Bool) instead of `deps.num_requests()`; every other refusal fixture
    has exactly one site."""
    var msg = _refusal(_two_scalar_subquery_filters(), _v1())
    assert_equal(
        msg,
        PORTABLE_REFUSAL_NEEDS_EXECUTION + ": 2 scalar site(s) need an executed sub-plan",
    )


def test_portable_raises_a_refusing_pass_error_unchanged() raises:
    """`flatten_dependent_joins` refuses a correlated subquery in a Project;
    under the v1 profile `optimize_portable` raises that pass's own message.

    Defect caught: a portable entry that swallows a pass's refusal or
    rewords it (as a needs-execution refusal, say)."""
    assert_equal(
        _refusal(_correlated_subquery_in_project(), _v1()),
        "correlated subquery in Project not yet supported",
    )


def test_portable_refuses_a_profile_version_it_does_not_implement() raises:
    """Versions 0 and 2 are refused by name before any pass runs: on a plan
    every pass accepts, on two plans whose passes record a request (which
    would otherwise be refused as needing execution), and on a plan a pass
    refuses (which would otherwise raise that pass's message).

    Defect caught: a portable entry that ignores the profile version and runs
    the v1 pass set for any version a producer asks for; and a version check
    that runs after the passes (before or after the needs-execution check),
    so an unknown profile still runs the v1 passes and is reported as
    whatever they raise."""
    for v in range(0, 3, 2):
        var want = (
            PORTABLE_REFUSAL_UNKNOWN_PROFILE + ": version " + String(v)
            + ", this build implements 1"
        )
        var tag = "version " + String(v)
        assert_equal(_refusal(_big_small_join(), PortableProfile(v)), want, tag)
        assert_equal(_refusal(_broadcast_site(), PortableProfile(v)), want, tag)
        assert_equal(
            _refusal(_scalar_subquery_filter(_grouped_agg()), PortableProfile(v)),
            want,
            tag,
        )
        assert_equal(
            _refusal(_correlated_subquery_in_project(), PortableProfile(v)), want, tag
        )


# -----------------------------------------------------------------------------
# Config comes from the argument (komira-ai/komira#1094, stage 7 mutant)
# -----------------------------------------------------------------------------


def test_portable_reads_eager_agg_from_its_argument() raises:
    """The star aggregate gets a partial `SUM` below the join with
    `eager_agg = True` and none with `eager_agg = False`.

    Defect caught: a portable entry that builds its config from anywhere but
    its argument (the environment, a fresh `OptimizerConfig()`): one of the
    two calls then gets the other's plan."""
    var on = _render(_portable(_star_aggregate()))
    assert_true(on.find("__eager_sum_total") >= 0, on)
    var config = OptimizerConfig()
    config.eager_agg = False
    var off_plan = _portable(_star_aggregate(), config)
    var off = _render(off_plan)
    assert_equal(off.find("__eager"), -1, off)
    assert_equal(Int(off_plan.tag), Int(PLAN_AGGREGATE), off)


def test_portable_reads_semi_pushdown_from_its_argument() raises:
    """`SEMI(INNER(a, b), c)`: the SEMI moves below the INNER join with
    `semi_pushdown = True` and stays the root with False.

    Defect caught: the same as above, for the second field the passes read."""
    var on = _render(_portable(_semi_over_inner()))
    assert_true(on.find("Join(type=INNER") < on.find("Join(type=SEMI"), on)
    var config = OptimizerConfig()
    config.semi_pushdown = False
    var off = _portable(_semi_over_inner(), config)
    assert_equal(Int(off.tag), Int(PLAN_JOIN), _render(off))
    assert_equal(Int(off._join.value()[].join_type), Int(JOIN_SEMI), _render(off))


# -----------------------------------------------------------------------------
# Same input, same bytes
# -----------------------------------------------------------------------------


def test_portable_output_is_identical_across_runs_on_separate_copies() raises:
    """Five consecutive runs on freshly built copies of the star aggregate,
    then five of the DPccp star: each run renders as the first of its kind.
    The runs of one plan are consecutive calls, so state that changes from
    one call to the next changes every other render.

    Defect caught: output that depends on state outside the arguments (a
    counter carried across calls, an allocation address used as a key)."""
    var agg = _render(_portable(_star_aggregate()))
    for i in range(4):
        assert_equal(_render(_portable(_star_aggregate())), agg, "run " + String(i + 2))
    var star = _render(_portable(_star4(False)))
    for i in range(4):
        assert_equal(_render(_portable(_star4(False))), star, "run " + String(i + 2))


def test_portable_output_ignores_the_column_order_of_table_stats() raises:
    """The DPccp star with every scan's TableStats columns reversed renders
    exactly as with them in schema order: statistics are looked up by column
    name.

    Defect caught: a statistics lookup by position (the first column's NDV
    for any column), which makes the join order follow the order a footer
    reader happened to list the columns in."""
    var forward = _render(_portable(_star4(False)))
    var reversed = _render(_portable(_star4(True)))
    assert_equal(reversed, forward)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
