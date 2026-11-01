# =============================================================================
# test_optimizer_driver_corpus -- properties of `optimizer_driver.optimize`
# over a corpus of plans
# =============================================================================
#
# The corpus covers every node-kind gate of the driver: filters over a scan and
# over a join, a join residual, functionally dependent group keys, a join of
# scans that carry column statistics, SEMI over INNER, eager aggregation,
# decorrelated and unbound scalar subqueries, a correlated EXISTS, a window
# with a rank filter, consecutive filters under Sort + Limit, and joins in
# both size orders.
#
# Six properties, each the design's promise:
#   * idempotence: optimize(optimize(p)) renders exactly as optimize(p);
#   * the output schema (names, order, types) is the input's;
#   * the config fields the driver does not read do not change the result;
#   * every join in the output carries a recorded build side, on the corpus
#     and on joins below a window, a Union, a CastToVarchar and an as-of join
#     (docs/design/optimized_plan.md §5.2: `build_side` is required);
#   * each recorded build side is the one `select_join_build_side` decides
#     for the output plan, and no join is marked `adaptive_allowed` (nothing
#     in the driver sets it);
#   * an UNBOUNDED scan is still UNBOUNDED in the output (§5.2: boundedness
#     is a stated property of the source, and it selects streaming).
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT, AGG_SUM, sum as agg_sum
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_SUB, BIN_EQ, BIN_GT, BIN_LE, BIN_AND, BIN_OR
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_stats.table_stats import (
    ColumnStats, TableStats, STATS_SOURCE_PARQUET_METADATA,
)
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    AsofTolerance,
    ASOF_BACKWARD,
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
    PLAN_ASOF_JOIN,
    PLAN_UNION,
    PLAN_VIEW_REF,
    PLAN_CSE_REF,
    PLAN_CAST_TO_VARCHAR,
    PLAN_EXCHANGE,
    JOIN_BUILD_SIDE_UNSET,
    SCAN_BOUNDED,
    SCAN_UNBOUNDED,
    SOURCE_PARQUET,
    CORR_KIND_SCALAR,
    CORR_KIND_EXISTS,
    JOIN_INNER,
    JOIN_SEMI,
    JOIN_ALGO_AUTO,
)
from komira_optimizer.optimizer_config import OptimizerConfig
from komira_optimizer.optimizer_scalar_deps import ScalarDepTable
from komira_optimizer.optimizer_driver import optimize
from komira_optimizer.optimizer_join import select_join_build_side


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


def _gt(c: String, v: Int) -> Expr:
    return Expr.binary(BIN_GT, Expr.col_ref(c), _lit(v))


def _l1(a: String) -> List[String]:
    var o = List[String]()
    o.append(a)
    return o^


def _cols(var names: List[String]) -> ExprArray:
    var pe = ExprArray()
    for i in range(len(names)):
        pe.append(Expr.col_ref(names[i]))
    return pe^


def _render(p: LogicalPlan) -> String:
    var s = String("")
    p.write_to(s)
    return s


def _schema_sig(p: LogicalPlan) -> String:
    """`name:type_id;` per output column, in order."""
    var s = String("")
    for i in range(p.output_schema.num_columns()):
        s += p.output_schema.field_name(i) + ":"
        s += String(Int(p.output_schema.field_arrow_type(i).type_id)) + ";"
    return s


def _shared_conjunct_or(with_join: Bool) -> LogicalPlan:
    var c = Expr.binary(BIN_GT, Expr.binary(BIN_ADD, Expr.col_ref("a"), _lit(1)), _lit(5))
    var pred = Expr.binary(
        BIN_OR,
        Expr.binary(BIN_AND, c.copy(), _eq("b", 2)),
        Expr.binary(BIN_AND, c.copy(), _eq("c", 3)),
    )
    var t_names: List[String] = ["a", "b", "c", "k"]
    var t = _scan("t.parquet", t_names)
    if with_join:
        var u_names: List[String] = ["k2", "u"]
        var j = LogicalPlan.join(t^, _scan("u.parquet", u_names), _l1("k"), _l1("k2"), JOIN_INNER)
        return LogicalPlan.filter(pred^, j^)
    return LogicalPlan.filter(pred^, t^)


def _residual_join() -> LogicalPlan:
    var c_names: List[String] = ["c_custkey", "c_name"]
    var o_names: List[String] = ["o_orderkey", "o_custkey", "o_total"]
    var res = Expr.binary(
        BIN_OR, Expr.binary(BIN_OR, _eq("o_orderkey", 1), _eq("o_orderkey", 2)), _eq("o_orderkey", 3)
    )
    return LogicalPlan.join(
        _scan("customer.parquet", c_names), _scan("orders.parquet", o_names),
        _l1("c_custkey"), _l1("o_custkey"), JOIN_INNER, JOIN_ALGO_AUTO,
        Optional[OwnedPointer[Expr]](OwnedPointer(res^)),
    )


def _fd_group_keys() -> LogicalPlan:
    var inner = ExprArray()
    inner.append(Expr.col_ref("ip"))
    inner.append(Expr.alias(Expr.binary(BIN_SUB, Expr.col_ref("ip"), _lit(1)), "k0"))
    var ip: List[String] = ["ip"]
    var inner_proj = LogicalPlan.project(inner^, _scan("hits.parquet", ip))
    var gb: List[String] = ["ip", "k0"]
    var aggs = AggExprArray()
    var no_child: Optional[Expr] = None
    aggs.append(AggExpr(AGG_COUNT, no_child^, Optional(String("c"))))
    var agg = LogicalPlan.aggregate(_cols(gb^), aggs^, inner_proj^)
    var outer = ExprArray()
    outer.append(Expr.col_ref("ip"))
    outer.append(Expr.alias(Expr.col_ref("k0"), "c1"))
    outer.append(Expr.col_ref("c"))
    return LogicalPlan.project(outer^, agg^)


def _stats(payload: String, extra: String, hi: Int64) raises -> TableStats:
    var names = List[String]()
    var stats = List[ColumnStats]()
    names.append("key")
    stats.append(ColumnStats(None, Optional[ScalarValue](ScalarValue.from_int64(0)),
        Optional[ScalarValue](ScalarValue.from_int64(24999999)), Optional[Int](0)))
    names.append(payload)
    stats.append(ColumnStats(None, Optional[ScalarValue](ScalarValue.from_int64(1)),
        Optional[ScalarValue](ScalarValue.from_int64(hi)), Optional[Int](0)))
    names.append(extra)
    stats.append(ColumnStats(None, Optional[ScalarValue](ScalarValue.from_int64(0)),
        Optional[ScalarValue](ScalarValue.from_int64(7)), Optional[Int](0)))
    return TableStats(1000, names^, stats^, STATS_SOURCE_PARQUET_METADATA)


def _join_with_stats() raises -> LogicalPlan:
    var pn: List[String] = ["key", "probe_val", "p_extra"]
    var bn: List[String] = ["key", "build_val", "b_extra"]
    var p = LogicalPlan.scan("probe.parquet", SOURCE_PARQUET, _schema(pn), None, None, None,
        Optional[TableStats](_stats("probe_val", "p_extra", 999)))
    var b = LogicalPlan.scan("build.parquet", SOURCE_PARQUET, _schema(bn), None, None, None,
        Optional[TableStats](_stats("build_val", "b_extra", 9999)))
    var j = LogicalPlan.join(p^, b^, _l1("key"), _l1("key"), JOIN_INNER)
    var keep: List[String] = ["key", "probe_val", "build_val"]
    return LogicalPlan.project(_cols(keep^), j^)


def _semi_over_inner() -> LogicalPlan:
    var an: List[String] = ["ak", "av"]
    var bn: List[String] = ["bk", "bv"]
    var cn: List[String] = ["ck", "cv"]
    var inner = LogicalPlan.join(_scan("a", an, 1000), _scan("b", bn, 1000), _l1("ak"), _l1("bk"), JOIN_INNER)
    return LogicalPlan.join(inner^, _scan("c", cn, 10), _l1("ak"), _l1("ck"), JOIN_SEMI)


def _star_aggregate() -> LogicalPlan:
    var fnames: List[String] = ["fk_id", "measure"]
    var dnames: List[String] = ["dim_id", "dim_attr"]
    var j = LogicalPlan.join(_scan("fact.parquet", fnames), _scan("dim.parquet", dnames),
        _l1("fk_id"), _l1("dim_id"), JOIN_INNER)
    var gb = ExprArray()
    gb.append(col("dim_attr").copy_expr())
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("measure")).alias("total"))
    return LogicalPlan.aggregate(gb^, aggs^, j^)


def _sum_v(grouped: Bool) -> LogicalPlan:
    var on: List[String] = ["o_total"]
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref("o_total")), Optional(String("v"))))
    var gb = ExprArray()
    if grouped:
        gb.append(Expr.col_ref("o_total"))
    var agg = LogicalPlan.aggregate(gb^, aggs^, _scan("orders.parquet", on))
    if not grouped:
        return agg^
    var v: List[String] = ["v"]
    return LogicalPlan.project(_cols(v^), agg^)


def _scalar_subquery_filter(grouped: Bool) -> LogicalPlan:
    var cn: List[String] = ["c_custkey", "c_acctbal"]
    var pred = Expr.binary(BIN_GT, Expr.col_ref("c_acctbal"),
        Expr.correlated_subquery(_sum_v(grouped), List[String](), CORR_KIND_SCALAR))
    return LogicalPlan.filter(pred^, _scan("customer.parquet", cn))


def _exists() -> LogicalPlan:
    """Filter(EXISTS(orders WHERE o_custkey = c_custkey)) over customer."""
    var cn: List[String] = ["c_custkey", "c_acctbal"]
    var on: List[String] = ["o_orderkey", "o_custkey"]
    var inner = LogicalPlan.filter(
        Expr.binary(BIN_EQ, Expr.col_ref("o_custkey"), Expr.col_ref("c_custkey")),
        _scan("orders.parquet", on, 100000),
    )
    var pred = Expr.correlated_subquery(inner^, _l1("c_custkey"), CORR_KIND_EXISTS)
    return LogicalPlan.filter(pred^, _scan("customer.parquet", cn, 10))


def _rank_filter() raises -> LogicalPlan:
    """Project [a, b, c] over Filter(rn <= 5) over PartitionBy(row_number)."""
    var n: List[String] = ["a", "b", "c"]
    var exprs = List[PartitionExpr]()
    exprs.append(PartitionExpr.row_number())
    var desc = List[Bool]()
    desc.append(True)
    var pb = LogicalPlan.partition_by(_l1("a"), _l1("b"), desc^, exprs^, _scan("w.parquet", n))
    var rn = pb.output_schema.field_name(pb.output_schema.num_columns() - 1)
    var f = LogicalPlan.filter(Expr.binary(BIN_LE, Expr.col_ref(rn), _lit(5)), pb^)
    var keep: List[String] = ["a", "b", "c"]
    return LogicalPlan.project(_cols(keep^), f^)


def _sort_limit() -> LogicalPlan:
    """Limit 10 over Sort(a) over Filter(b > 2) over Filter(a > 1) over s(a, b)."""
    var n: List[String] = ["a", "b"]
    var f1 = LogicalPlan.filter(_gt("a", 1), _scan("s.parquet", n))
    var f2 = LogicalPlan.filter(_gt("b", 2), f1^)
    var desc = List[Bool]()
    desc.append(False)
    return LogicalPlan.limit(10, LogicalPlan.sort(_l1("a"), desc^, f2^))


def _two_way_join(small_first: Bool) -> LogicalPlan:
    var sn: List[String] = ["s_k", "s_v"]
    var bn: List[String] = ["b_k", "b_v"]
    if small_first:
        return LogicalPlan.join(_scan("small", sn, 10), _scan("big", bn, 100000),
            _l1("s_k"), _l1("b_k"), JOIN_INNER)
    return LogicalPlan.join(_scan("big", bn, 100000), _scan("small", sn, 10),
        _l1("b_k"), _l1("s_k"), JOIN_INNER)


comptime CORPUS_SIZE: Int = 15


def _corpus(i: Int) raises -> LogicalPlan:
    if i == 0:
        return _shared_conjunct_or(False)
    if i == 1:
        return _shared_conjunct_or(True)
    if i == 2:
        return _residual_join()
    if i == 3:
        return _fd_group_keys()
    if i == 4:
        return _join_with_stats()
    if i == 5:
        return _semi_over_inner()
    if i == 6:
        return _star_aggregate()
    if i == 7:
        return _scalar_subquery_filter(False)
    if i == 8:
        return _scalar_subquery_filter(True)
    if i == 9:
        return _exists()
    if i == 10:
        return _rank_filter()
    if i == 11:
        return _sort_limit()
    if i == 12:
        return _two_way_join(True)
    if i == 13:
        return _two_way_join(False)
    return _scan("plain.parquet", _l1("x"))


def _run(var p: LogicalPlan, config: OptimizerConfig) raises -> LogicalPlan:
    var deps = ScalarDepTable()
    return optimize(p^, config, deps)


# -----------------------------------------------------------------------------
# Properties
# -----------------------------------------------------------------------------


def test_optimize_is_idempotent_on_the_corpus() raises:
    """optimize(optimize(p)) renders exactly as optimize(p), for every plan.

    Defect caught: a gate that reads a stale node-kind scan (a second call
    then finds work the first skipped). The identity Project the old
    build-side operand exchange left above a join is gone with the exchange:
    removing the `eliminate_identity_projects` after step 16 no longer breaks
    this property on the corpus."""
    for i in range(CORPUS_SIZE):
        var once = _run(_corpus(i), OptimizerConfig())
        var r1 = _render(once)
        var twice = _run(once^, OptimizerConfig())
        var r2 = _render(twice)
        assert_equal(r2, r1, "corpus plan " + String(i) + " is not a fixed point")


def test_output_schema_is_the_input_schema_on_the_corpus() raises:
    """Names, order and types of the output columns equal the input's, for
    every plan whose call completed (no outstanding scalar request).

    Defects caught: the output-order restore around the join reorder dropped
    (corpus plan 13 answers `[s_k, s_v, b_k, b_v]`), and any pass order that
    leaves a helper column (`__scalar_subq_*`, `__eager_*`) in the output."""
    for i in range(CORPUS_SIZE):
        var p = _corpus(i)
        var want = _schema_sig(p)
        var deps = ScalarDepTable()
        var out = optimize(p^, OptimizerConfig(), deps)
        if deps.has_requests():
            # A request round is a draft the caller re-plans from the original
            # once the request is bound; only corpus plan 8 is one.
            assert_equal(i, 8, "unexpected request round\n" + _render(out))
            continue
        assert_equal(_schema_sig(out), want, "corpus plan " + String(i) + "\n" + _render(out))


def test_config_fields_the_driver_does_not_read_do_not_change_the_plan() raises:
    """The agg-CSE switches, the scan-dedup switches and the two row
    thresholds belong to rules outside this pass order; setting every one away
    from its default gives the same plan as the default config.

    Defect caught: the driver reading one of those fields (for example
    skipping passes when `disable_scan_dedup` is set)."""
    var odd = OptimizerConfig()
    odd.agg_cse_gate = False
    odd.agg_cse_cheapkey = False
    odd.disable_scan_dedup = True
    odd.disable_scan_dedup_for_agg = True
    odd.fact_stream_protect_rows = 1
    odd.agg_inmem_max_rows = 1
    for i in range(CORPUS_SIZE):
        var want = _render(_run(_corpus(i), OptimizerConfig()))
        var got = _render(_run(_corpus(i), odd))
        assert_equal(got, want, "corpus plan " + String(i))


# -----------------------------------------------------------------------------
# Decisions: every join decided, every UNBOUNDED mark kept
# -----------------------------------------------------------------------------


def _count(p: LogicalPlan, what: Int) raises -> Int:
    """Over every node reachable through plan children: `what` = 0 counts
    joins, 1 joins with no recorded build side, 2 scans, 3 scans that are
    BOUNDED. RAISES on a tag with no arm, so a node kind the corpus grows
    cannot hide a join or a scan from the count."""
    var here = 0
    if p.tag == PLAN_JOIN:
        if what == 0 or (
            what == 1 and p._join.value()[].build_side == JOIN_BUILD_SIDE_UNSET
        ):
            here = 1
        return here + _count(p._join.value()[].left[], what) + _count(
            p._join.value()[].right[], what
        )
    if p.tag == PLAN_SCAN:
        if what == 2 or (
            what == 3 and p._scan.value()[].boundedness == SCAN_BOUNDED
        ):
            here = 1
        return here
    if p.tag == PLAN_FILTER:
        return _count(p._filter.value()[].child[], what)
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
    if p.tag == PLAN_ASOF_JOIN:
        return _count(p._asof_join.value()[].left[], what) + _count(
            p._asof_join.value()[].right[], what
        )
    if p.tag == PLAN_UNION:
        var n = 0
        for i in range(p._union.value()[].num_children()):
            n += _count(p._union.value()[].children[i][], what)
        return n
    if p.tag == PLAN_CAST_TO_VARCHAR:
        return _count(p._cast_to_varchar.value()[].child[], what)
    if p.tag == PLAN_EXCHANGE:
        return _count(p._exchange.value()[].child[], what)
    if p.tag == PLAN_VIEW_REF or p.tag == PLAN_CSE_REF:
        return 0
    raise Error("_count: no arm for plan tag " + String(Int(p.tag)))


def _mark_unbounded(mut p: LogicalPlan):
    """Mark every scan reachable through Filter, Project, Aggregate, Sort,
    Limit, Join and PartitionBy UNBOUNDED (the node kinds of the corpus plans
    the boundedness test uses)."""
    if p.tag == PLAN_SCAN:
        p._scan.value()[].boundedness = SCAN_UNBOUNDED
    elif p.tag == PLAN_JOIN:
        _mark_unbounded(p._join.value()[].left[])
        _mark_unbounded(p._join.value()[].right[])
    elif p.tag == PLAN_FILTER:
        _mark_unbounded(p._filter.value()[].child[])
    elif p.tag == PLAN_PROJECT:
        _mark_unbounded(p._project.value()[].child[])
    elif p.tag == PLAN_AGGREGATE:
        _mark_unbounded(p._aggregate.value()[].child[])
    elif p.tag == PLAN_SORT:
        _mark_unbounded(p._sort.value()[].child[])
    elif p.tag == PLAN_LIMIT:
        _mark_unbounded(p._limit.value()[].child[])
    elif p.tag == PLAN_PARTITION_BY:
        _mark_unbounded(p._partition_by.value()[].child[])


comptime BELOW_KINDS: Int = 4


def _join_below(kind: Int) raises -> LogicalPlan:
    """A join (two, for the Union and the as-of join) below a node the
    driver's `has_join` scan does or does not descend: 0 a window
    (PartitionBy, descended), 1 a Union, 2 a CastToVarchar, 3 an as-of join
    (none of the three descended)."""
    if kind == 0:
        var n: List[String] = ["a", "b", "c"]
        var exprs = List[PartitionExpr]()
        exprs.append(PartitionExpr.row_number())
        var desc = List[Bool]()
        desc.append(True)
        return LogicalPlan.partition_by(
            _l1("a"), _l1("b"), desc^, exprs^, _two_way_join(True)
        )
    if kind == 1:
        var a = _two_way_join(True)
        var schema = a.output_schema.copy()
        var kids = List[OwnedPointer[LogicalPlan]]()
        kids.append(OwnedPointer(a^))
        kids.append(OwnedPointer(_two_way_join(True)))
        return LogicalPlan.union(kids^, schema^)
    if kind == 2:
        return LogicalPlan.cast_to_varchar(_two_way_join(False))
    return LogicalPlan.asof_join(
        _two_way_join(True), _two_way_join(False), List[String](),
        List[String](), String("s_k"), String("s_k"), ASOF_BACKWARD,
        AsofTolerance.none(),
    )


def test_every_join_is_decided_on_the_corpus() raises:
    """After `optimize`, no join in any corpus plan carries
    `JOIN_BUILD_SIDE_UNSET`, and the corpus holds joins to check (at least
    one per join plan: 1, 2, 4, 5, 6, 9, 12, 13).

    Defects caught: `select_join_build_side` dropped from the driver or
    gated so that it skips a plan; and a pass after it that rebuilds a join
    without carrying the field (`optimize_window_rewrite` rebuilt every join
    it recursed through with none, on any plan holding a Project)."""
    var joins = 0
    for i in range(CORPUS_SIZE):
        var out = _run(_corpus(i), OptimizerConfig())
        joins += _count(out, 0)
        assert_equal(
            _count(out, 1), 0, "corpus plan " + String(i) + "\n" + _render(out)
        )
    assert_true(joins >= 8, String(joins))


def test_a_join_below_any_node_is_decided() raises:
    """A join below a window, in each branch of a Union, below a
    CastToVarchar and on both inputs of an as-of join comes out decided.

    Defects caught: the build-side walk with no arm for a node kind (it had
    none for PartitionBy, PartitionTopN, AsofJoin, Union, CastToVarchar or
    Exchange), and the rule gated on the driver's `has_join` scan, which does
    not descend a Union, a CastToVarchar or an as-of join."""
    for k in range(BELOW_KINDS):
        var out = _run(_join_below(k), OptimizerConfig())
        assert_true(_count(out, 0) >= 1, "kind " + String(k) + "\n" + _render(out))
        assert_equal(_count(out, 1), 0, "kind " + String(k) + "\n" + _render(out))


def _projected_join(small_first: Bool) -> LogicalPlan:
    """A Project over a two-way join: the shape on which
    `optimize_window_rewrite` (steps 17-20, after the decision) rebuilds the
    join below it."""
    var names: List[String] = ["s_k", "b_v"]
    return LogicalPlan.project(_cols(names^), _two_way_join(small_first))


def test_every_recorded_build_side_is_the_rules_own_decision() raises:
    """On every corpus plan, every below-a-node plan and a Project over a join
    in each size order, the output of `optimize` renders exactly as
    `select_join_build_side` run once more on that output: each recorded side
    is the one the rule decides for the plan the driver returns. Across them
    both sides occur (`build=left` and `build=right` each render at least
    once), so a check that holds only for one side cannot pass.

    Defects caught: a pass after the decision that rebuilds a join with a
    constant side or `adaptive_allowed` (an `optimize_window_rewrite` Join
    arm writing LEFT, or `adaptive_allowed = True`, on every join it
    recursed through), and a pass after it that changes a join's inputs
    without re-deciding."""
    var lefts = 0
    var rights = 0
    for i in range(CORPUS_SIZE + BELOW_KINDS + 2):
        var p: LogicalPlan
        if i < CORPUS_SIZE:
            p = _corpus(i)
        elif i < CORPUS_SIZE + BELOW_KINDS:
            p = _join_below(i - CORPUS_SIZE)
        else:
            p = _projected_join(i == CORPUS_SIZE + BELOW_KINDS)
        var out = _run(p^, OptimizerConfig())
        var got = _render(out)
        var again = _render(select_join_build_side(out.copy()))
        assert_equal(got, again, "plan " + String(i))
        if "build=left" in got:
            lefts += 1
        if "build=right" in got:
            rights += 1
        assert_true("adaptive" not in got, "plan " + String(i) + "\n" + got)
    assert_true(lefts >= 1, "no plan built left")
    assert_true(rights >= 1, "no plan built right")


def test_an_unbounded_scan_stays_unbounded() raises:
    """Every scan of each corpus plan with no subquery (all but 7, 8, 9,
    whose inner scans are inside an expression) is marked UNBOUNDED; after
    `optimize` no scan is BOUNDED, and there are scans to check.

    Defects caught: a pass that rebuilds a scan without carrying the mark.
    Filter pushdown into a scan (corpus plan 11) and projection pushdown
    (plan 4) each rebuild the scan through `scan_from_source`, which defaults
    the mark to BOUNDED: a streaming plan would come out a batch plan."""
    var scans = 0
    for i in range(CORPUS_SIZE):
        if i == 7 or i == 8 or i == 9:
            continue
        var p = _corpus(i)
        _mark_unbounded(p)
        var before = _count(p, 2)
        assert_equal(_count(p, 3), 0, "corpus plan " + String(i) + " not marked")
        var out = _run(p^, OptimizerConfig())
        scans += _count(out, 2)
        assert_equal(
            _count(out, 3), 0, "corpus plan " + String(i) + "\n" + _render(out)
        )
        assert_true(before >= 1, String(i))
    assert_true(scans >= 12, String(scans))


def test_the_corpus_reaches_every_gated_pass() raises:
    """The corpus is only evidence for the gates it reaches. This pins, per
    gate, the plan whose result shows the gated pass ran: consecutive filters
    fused and folded into the scan with Sort + Limit as TopN (11), the rank
    filter fused into PartitionTopN (10), the join-side filter split (1), the
    EXISTS lowered to a SEMI join (9).

    Defect caught: a corpus edit that silently stops exercising a gate, which
    would leave the idempotence and schema properties above vacuous for it."""
    var r11 = _render(_run(_corpus(11), OptimizerConfig()))
    assert_true(r11.startswith("TopN(n=10"), r11)
    assert_true(r11.find("filter=BinaryOp(AND") >= 0, r11)
    var r10 = _render(_run(_corpus(10), OptimizerConfig()))
    assert_true(r10.find("PartitionTopN(k=5") >= 0, r10)
    assert_equal(r10.find("PartitionBy("), -1, r10)
    var r1 = _render(_run(_corpus(1), OptimizerConfig()))
    assert_true(r1.find("Filter(predicate=BinaryOp(GT, BinaryOp(ADD") >= 0, r1)
    var r9 = _render(_run(_corpus(9), OptimizerConfig()))
    assert_true(r9.startswith("Join(type=SEMI"), r9)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
