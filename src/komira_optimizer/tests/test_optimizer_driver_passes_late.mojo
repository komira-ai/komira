# =============================================================================
# test_optimizer_driver_passes_late -- each pass of `optimizer_driver.optimize`
# steps 10-19, pinned at its position
# =============================================================================
#
# One plan per pass, built so that the pass changes the optimized plan at the
# position the driver runs it. Each test compares the whole render with what
# the driver produces, so dropping the pass, or moving it to the position
# named in the test, changes the result. Two tests pin a position of the
# reference order that blocks a rewrite (komira#1293), so a change of order is
# a visible edit. Steps 1-10 are pinned in `test_optimizer_driver_passes.mojo`.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_MUL, BIN_EQ, BIN_LE
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan, ExprArray, AggExprArray, SOURCE_PARQUET, JOIN_INNER, JOIN_CROSS,
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


def _c(n: String) -> Expr:
    return Expr.col_ref(n)


def _eq(c: String, v: Int) -> Expr:
    return Expr.binary(BIN_EQ, _c(c), _lit(v))


def _ceq(a: String, b: String) -> Expr:
    return Expr.binary(BIN_EQ, _c(a), _c(b))


def _l1(a: String) -> List[String]:
    var o = List[String]()
    o.append(a)
    return o^


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


def _cols(var names: List[String]) -> ExprArray:
    var pe = ExprArray()
    for i in range(len(names)):
        pe.append(Expr.col_ref(names[i]))
    return pe^


def _agg_sum(key: String, val: String, oname: String, var child: LogicalPlan) -> LogicalPlan:
    """SUM(val) AS oname GROUP BY key."""
    var gb = ExprArray()
    gb.append(_c(key))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(_c(val)), Optional(oname)))
    return LogicalPlan.aggregate(gb^, aggs^, child^)


def _no_keys() -> List[String]:
    return List[String]()


def _pb(f: PartitionExpr, var child: LogicalPlan) raises -> LogicalPlan:
    """PartitionBy(partition=[a], order=[b DESC], funcs=[f])."""
    var exprs = List[PartitionExpr]()
    exprs.append(f.copy())
    var desc = List[Bool]()
    desc.append(True)
    return LogicalPlan.partition_by(_l1("a"), _l1("b"), desc^, exprs^, child^)


def _last_col(p: LogicalPlan) -> String:
    return p.output_schema.field_name(p.output_schema.num_columns() - 1)


# -----------------------------------------------------------------------------
# Steps 10 and 13-16: joins, projects, aggregates
# -----------------------------------------------------------------------------


def test_a_cross_join_equality_becomes_a_semi_join() raises:
    """`Project[ax, ay](Filter(ax = cx, A CROSS JOIN Aggregate(cx)))`: step 10
    makes the cross join an INNER join on `ax = cx`, and step 14 turns it into
    a SEMI join (no right column is read and the right side is unique on cx).

    Defect caught: the step-10 `eliminate_cross_join` dropped. Step 16 still
    makes the INNER join, but after the semi conversion, so it stays INNER
    under two Projects."""
    var an: List[String] = ["ax", "ay"]
    var cn: List[String] = ["cx", "cy"]
    var cross = LogicalPlan.join(
        _scan("A", an, 100), _agg_sum("cx", "cy", "s", _scan("C", cn, 10)), _no_keys(), _no_keys(), JOIN_CROSS
    )
    var keep: List[String] = ["ax", "ay"]
    var out = _run(LogicalPlan.project(_cols(keep^), LogicalPlan.filter(_ceq("ax", "cx"), cross^)))
    assert_equal(_render(out), _want_cross_semi())


def test_an_inner_join_over_a_unique_right_side_becomes_semi() raises:
    """`Project[lk, lv](l JOIN Aggregate(rk))` becomes `l SEMI JOIN ...` with
    no Project; `DISTINCT(Project[lk](l JOIN r))` becomes a SEMI join under the
    Distinct.

    Defects caught: `convert_inner_to_semi` dropped (both stay INNER), and the
    `eliminate_identity_projects` after step 16 dropped (an identity
    `Project[lk, lv]` stays over the SEMI join)."""
    var ln: List[String] = ["lk", "lv"]
    var rn: List[String] = ["rk", "rv"]
    var keep: List[String] = ["lk", "lv"]
    var j = LogicalPlan.join(
        _scan("l.parquet", ln, 1000), _agg_sum("rk", "rv", "s", _scan("r.parquet", rn, 100)),
        _l1("lk"), _l1("rk"), JOIN_INNER,
    )
    assert_equal(_render(_run(LogicalPlan.project(_cols(keep^), j^))), _want_semi_unique())
    var k1: List[String] = ["lk"]
    var j2 = LogicalPlan.join(_scan("l.parquet", ln), _scan("r.parquet", rn), _l1("lk"), _l1("rk"), JOIN_INNER)
    var d = LogicalPlan.distinct(None, LogicalPlan.project(_cols(k1^), j2^))
    assert_equal(_render(_run(d^)), _want_semi_distinct())


def test_adjacent_projects_merge_and_an_identity_project_goes() raises:
    """`Project[x+1 AS y, b](Project[a*2 AS x, b](s))` becomes one Project
    over the scan; `Project[a, b](s(a, b))` becomes the scan.

    Defects caught: `merge_projects` dropped (two Projects), and the step-13
    `eliminate_identity_projects` dropped (the identity Project stays)."""
    var n: List[String] = ["a", "b"]
    var m1 = ExprArray()
    m1.append(Expr.alias(Expr.binary(BIN_MUL, _c("a"), _lit(2)), "x"))
    m1.append(_c("b"))
    var m2 = ExprArray()
    m2.append(Expr.alias(Expr.binary(BIN_ADD, _c("x"), _lit(1)), "y"))
    m2.append(_c("b"))
    var out = _run(LogicalPlan.project(m2^, LogicalPlan.project(m1^, _scan("s.parquet", n))))
    assert_equal(_render(out), _want_merge())
    var ab: List[String] = ["a", "b"]
    var just_scan: List[String] = ['Scan(path="s.parquet", type=PARQUET, source_kind=COLUMNAR)']
    assert_equal(_render(_run(LogicalPlan.project(_cols(ab^), _scan("s.parquet", n)))), _lines(just_scan))


def test_projections_are_pushed_into_both_join_scans() raises:
    """`Project[a, u](t JOIN u)`: each scan reads only its output column and
    its join key.

    Defect caught: both projection calls of step 11 dropped (the scans read
    every column). `prune_columns` is `push_projections_down` called again,
    so dropping either one alone changes nothing on these plans."""
    var pt: List[String] = ["a", "k", "te"]
    var pu: List[String] = ["u", "k2", "ue"]
    var keep: List[String] = ["a", "u"]
    var j = LogicalPlan.join(_scan("t.parquet", pt), _scan("u.parquet", pu), _l1("k"), _l1("k2"), JOIN_INNER)
    assert_equal(_render(_run(LogicalPlan.project(_cols(keep^), j^))), _want_projpush_join())


def test_a_computed_aggregate_input_is_materialized_after_absorb() raises:
    """`SUM(x)` over `Project[g, a*b AS x](t JOIN u)`: absorb folds `a*b`
    into the aggregate, then `materialize_agg_input` puts it back as
    `__agg_in_0` in one Project under the Aggregate.

    Defects caught: `materialize_agg_input` dropped or moved before step 14
    (the Aggregate is left summing an expression), and
    `absorb_expression_into_aggregate` dropped (`x` keeps its own Project)."""
    var mt: List[String] = ["g", "a", "k"]
    var mu: List[String] = ["k2", "b"]
    var mp = ExprArray()
    mp.append(_c("g"))
    mp.append(Expr.alias(Expr.binary(BIN_MUL, _c("a"), _c("b")), "x"))
    var j = LogicalPlan.join(_scan("t.parquet", mt), _scan("u.parquet", mu), _l1("k"), _l1("k2"), JOIN_INNER)
    assert_equal(_render(_run(_agg_sum("g", "x", "s", LogicalPlan.project(mp^, j^)))), _want_matagg())


def test_eager_aggregation_runs_before_absorb() raises:
    """`SUM(x)` over `Project[dim_attr, measure*2 AS x](fact JOIN dim)`:
    eager aggregation sees an Aggregate over a Project and declines, so no
    partial aggregate goes below the join. This pins the reference order
    (komira#1293), not a property the order needs.

    Defect caught: eager aggregation moved after
    `absorb_expression_into_aggregate`, which changes the plan (a partial
    `__eager_sum_total` aggregate appears on the fact side)."""
    var fnm: List[String] = ["fk_id", "measure"]
    var dnm: List[String] = ["dim_id", "dim_attr"]
    var j = LogicalPlan.join(_scan("fact.parquet", fnm), _scan("dim.parquet", dnm), _l1("fk_id"), _l1("dim_id"), JOIN_INNER)
    var ep = ExprArray()
    ep.append(_c("dim_attr"))
    ep.append(Expr.alias(Expr.binary(BIN_MUL, _c("measure"), _lit(2)), "x"))
    assert_equal(_render(_run(_agg_sum("dim_attr", "x", "total", LogicalPlan.project(ep^, j^)))), _want_eager_computed())


def test_the_smaller_relation_is_the_build_side() raises:
    """`Filter(ax = bx)` over A (100 rows) CROSS JOIN B (1000 rows): the INNER
    join keeps A on the left and B on the right, in the query's order, and
    records `build=left`: A, the smaller relation, is built. No Project is
    added.

    Defect caught: `select_join_build_side` dropped (the join renders with no
    `build=`), and the old operand exchange restored (B on the left under a
    Project restoring the column order)."""
    var an: List[String] = ["ax", "ay"]
    var bn: List[String] = ["bx", "by"]
    var cross = LogicalPlan.join(_scan("A", an, 100), _scan("B", bn, 1000), _no_keys(), _no_keys(), JOIN_CROSS)
    assert_equal(_render(_run(LogicalPlan.filter(_ceq("ax", "bx"), cross^))), _want_cross_2())


# -----------------------------------------------------------------------------
# Steps 17-19: limits and windows
# -----------------------------------------------------------------------------


def test_a_limit_moves_below_a_computing_project() raises:
    """`Limit 10` over `Project[a+1 AS x](s)` becomes the Project over the
    Limit.

    Defect caught: `push_limit_down` dropped (the Limit stays on top)."""
    var n: List[String] = ["a", "b"]
    var pe = ExprArray()
    pe.append(Expr.alias(Expr.binary(BIN_ADD, _c("a"), _lit(1)), "x"))
    assert_equal(_render(_run(LogicalPlan.limit(10, LogicalPlan.project(pe^, _scan("s.parquet", n))))), _want_limit_proj_computed())


def test_a_limit_is_pushed_before_sort_limit_fusion() raises:
    """`Limit 10` over `Project[a+1 AS x, a](Sort(a))`: the Limit moves below
    the Project onto the Sort, and the two fuse into `TopN(n=10)`.

    Defects caught: `fuse_sort_limit` dropped, `push_limit_down` dropped, or
    the two swapped (the fusion then sees the Limit over the Project and no
    TopN is made)."""
    var n: List[String] = ["a", "b"]
    var desc = List[Bool]()
    desc.append(False)
    var lp = ExprArray()
    lp.append(Expr.alias(Expr.binary(BIN_ADD, _c("a"), _lit(1)), "x"))
    lp.append(_c("a"))
    var p = LogicalPlan.project(lp^, LogicalPlan.sort(_l1("a"), desc^, _scan("s.parquet", n)))
    assert_equal(_render(_run(LogicalPlan.limit(10, p^))), _want_limit_sort_proj())


def test_window_rewrite_fuses_partition_bys_and_elides_a_sort() raises:
    """Two adjacent PartitionBy nodes over the same window become one with two
    functions; `Sort(a)` over a PartitionBy partitioned on `a` is dropped.

    Defect caught: `optimize_window_rewrite` dropped (both PartitionBy nodes
    and the Sort stay)."""
    var wn: List[String] = ["a", "b", "c"]
    var two = _pb(PartitionExpr.rank(), _pb(PartitionExpr.row_number(), _scan("w.parquet", wn)))
    assert_equal(_render(_run(two^)), _want_win_fuse())
    var desc = List[Bool]()
    desc.append(False)
    var s = LogicalPlan.sort(_l1("a"), desc^, _pb(PartitionExpr.row_number(), _scan("w.parquet", wn)))
    assert_equal(_render(_run(s^)), _want_win_sort())


def test_window_fusion_runs_before_partition_topn() raises:
    """`Project[a, b, c](Filter(rn <= 5))` over PartitionBy(row_number) over
    PartitionBy(rank): window rewriting fuses the two into one PartitionBy
    with two functions, which `fuse_partition_topn` declines, so the Filter
    stays. This pins the reference order (komira#1293).

    Defect caught: the two window passes swapped. PartitionTopN fusion then
    takes the row_number PartitionBy first and the plan becomes
    PartitionTopN(k=5) over PartitionBy(rank)."""
    var wn: List[String] = ["a", "b", "c"]
    var upper = _pb(PartitionExpr.row_number(), _pb(PartitionExpr.rank(), _scan("w.parquet", wn)))
    var rn = _last_col(upper)
    var keep: List[String] = ["a", "b", "c"]
    var f = LogicalPlan.filter(Expr.binary(BIN_LE, _c(rn), _lit(5)), upper^)
    assert_equal(_render(_run(LogicalPlan.project(_cols(keep^), f^))), _want_win_topn_order())


# -----------------------------------------------------------------------------
# Expected renders
# -----------------------------------------------------------------------------


def _want_cross_semi() -> String:
    var l: List[String] = [
        "Join(type=SEMI, on=[ax=cx], build=right)",
        "  Scan(path=\"A\", type=PARQUET, source_kind=COLUMNAR)",
        "  Aggregate(group_by=[ColRef(cx)], aggs=[SUM(ColRef(cy)).alias(\"s\")])",
        "    Scan(path=\"C\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_semi_unique() -> String:
    var l: List[String] = [
        "Join(type=SEMI, on=[lk=rk], build=right)",
        "  Scan(path=\"l.parquet\", type=PARQUET, source_kind=COLUMNAR)",
        "  Aggregate(group_by=[ColRef(rk)], aggs=[SUM(ColRef(rv)).alias(\"s\")])",
        "    Scan(path=\"r.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_semi_distinct() -> String:
    var l: List[String] = [
        "Distinct(all)",
        "  Join(type=SEMI, on=[lk=rk], build=right)",
        "    Scan(path=\"l.parquet\", type=PARQUET, source_kind=COLUMNAR, projection=[lk])",
        "    Scan(path=\"r.parquet\", type=PARQUET, source_kind=COLUMNAR, projection=[rk])",
    ]
    return _lines(l)


def _want_merge() -> String:
    var l: List[String] = [
        "Project(exprs=[Alias(BinaryOp(ADD, Alias(BinaryOp(MUL, ColRef(a), Literal(ScalarValue(int64, 2))), \"x\"), Literal(ScalarValue(int64, 1))), \"y\"), ColRef(b)])",
        "  Scan(path=\"s.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_projpush_join() -> String:
    var l: List[String] = [
        "Project(exprs=[ColRef(a), ColRef(u)])",
        "  Join(type=INNER, on=[k=k2], build=right)",
        "    Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR, projection=[a, k])",
        "    Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR, projection=[u, k2])",
    ]
    return _lines(l)


def _want_matagg() -> String:
    var l: List[String] = [
        "Aggregate(group_by=[ColRef(g)], aggs=[SUM(ColRef(__agg_in_0)).alias(\"s\")])",
        "  Project(exprs=[ColRef(g), Alias(Alias(BinaryOp(MUL, ColRef(a), ColRef(b)), \"x\"), \"__agg_in_0\")])",
        "    Join(type=INNER, on=[k=k2], build=right)",
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)",
        "      Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_eager_computed() -> String:
    var l: List[String] = [
        "Aggregate(group_by=[ColRef(dim_attr)], aggs=[SUM(ColRef(__agg_in_0)).alias(\"total\")])",
        "  Project(exprs=[ColRef(dim_attr), Alias(Alias(BinaryOp(MUL, ColRef(measure), Literal(ScalarValue(int64, 2))), \"x\"), \"__agg_in_0\")])",
        "    Join(type=INNER, on=[fk_id=dim_id], build=right)",
        "      Scan(path=\"fact.parquet\", type=PARQUET, source_kind=COLUMNAR)",
        "      Scan(path=\"dim.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_limit_proj_computed() -> String:
    var l: List[String] = [
        "Project(exprs=[Alias(BinaryOp(ADD, ColRef(a), Literal(ScalarValue(int64, 1))), \"x\")])",
        "  Limit(n=10)",
        "    Scan(path=\"s.parquet\", type=PARQUET, source_kind=COLUMNAR, projection=[a])",
    ]
    return _lines(l)


def _want_limit_sort_proj() -> String:
    var l: List[String] = [
        "Project(exprs=[Alias(BinaryOp(ADD, ColRef(a), Literal(ScalarValue(int64, 1))), \"x\"), ColRef(a)])",
        "  TopN(n=10, keys=[a ASC])",
        "    Scan(path=\"s.parquet\", type=PARQUET, source_kind=COLUMNAR, projection=[a])",
    ]
    return _lines(l)


def _want_win_fuse() -> String:
    var l: List[String] = [
        "PartitionBy(partition=[a], order=[b DESC], funcs=[ROW_NUMBER(, offset=0, frame=ROWS[0:0..2:0]), RANK(, offset=0, frame=ROWS[0:0..2:0])])",
        "  Scan(path=\"w.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_win_sort() -> String:
    var l: List[String] = [
        "PartitionBy(partition=[a], order=[b DESC], funcs=[ROW_NUMBER(, offset=0, frame=ROWS[0:0..2:0])])",
        "  Scan(path=\"w.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_win_topn_order() -> String:
    var l: List[String] = [
        "Project(exprs=[ColRef(a), ColRef(b), ColRef(c)])",
        "  Filter(predicate=BinaryOp(LE, ColRef(_w0_row_number), Literal(ScalarValue(int64, 5))))",
        "    PartitionBy(partition=[a], order=[b DESC], funcs=[RANK(, offset=0, frame=ROWS[0:0..2:0]), ROW_NUMBER(, offset=0, frame=ROWS[0:0..2:0])])",
        "      Scan(path=\"w.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_cross_2() -> String:
    var l: List[String] = [
        "Join(type=INNER, on=[ax=bx], build=left)",
        "  Scan(path=\"A\", type=PARQUET, source_kind=COLUMNAR)",
        "  Scan(path=\"B\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
