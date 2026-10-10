# =============================================================================
# test_optimizer_driver_corpus -- properties of `optimizer_driver.optimize`
# over a corpus of plans
# =============================================================================
#
# The corpus covers every node-kind gate of the driver: filters over a scan and
# over a join, a join residual, functionally dependent group keys, payload
# narrowing, SEMI over INNER, eager aggregation, decorrelated and unbound
# scalar subqueries, a correlated EXISTS, a window with a rank filter,
# consecutive filters under Sort + Limit, and joins in both size orders.
#
# Three properties, each the design's promise:
#   * idempotence: optimize(optimize(p)) renders exactly as optimize(p);
#   * the output schema (names, order, types) is the input's;
#   * the config fields the driver does not read do not change the result.
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


def _narrowable_join() raises -> LogicalPlan:
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
        return _narrowable_join()
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

    Defects caught: a gate that reads a stale node-kind scan (a second call
    then finds work the first skipped), and the identity Project that the
    reorder / build-side swap leaves above a join when a Project already sat
    there (removed by the `eliminate_identity_projects` after step 16; without
    it the second call stacks a second Project on corpus plans 1, 5 and 12)."""
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
