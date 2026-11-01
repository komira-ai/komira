# =============================================================================
# test_optimizer_driver_passes -- each pass of `optimizer_driver.optimize`
# steps 1-10 (and the step-16 re-runs they feed), pinned at its position
# =============================================================================
#
# One plan per pass, built so that the pass changes the optimized plan at the
# position the driver runs it. Each test compares the whole render (or, where
# the render does not show the field, the field itself) with what the driver
# produces, so dropping the pass, or moving it to the position named in the
# test, changes the result. The defect each test catches is the driver's, not
# the rule's: a rule's own behaviour belongs to that rule's tests.
#
# Steps 11-19 are pinned in `test_optimizer_driver_passes_late.mojo`.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder, RecordBatch
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_MAX
from komira_plan_expr.expr import (
    Expr, WhenCaseData, BIN_ADD, BIN_MUL, BIN_EQ, BIN_GT, BIN_LT, BIN_AND, BIN_OR,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan, ExprArray, AggExprArray, SOURCE_PARQUET, JOIN_INNER, JOIN_CROSS, JOIN_ALGO_AUTO,
    PLAN_SCAN, PLAN_FILTER, PLAN_PROJECT,
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


def _names(p: LogicalPlan) -> String:
    var s = String("")
    for i in range(p.output_schema.num_columns()):
        s += p.output_schema.field_name(i) + ","
    return s^


def _run(var p: LogicalPlan) raises -> LogicalPlan:
    var deps = ScalarDepTable()
    return optimize(p^, OptimizerConfig(), deps)


def _year_scan() raises -> LogicalPlan:
    """Eagerly listed Hive scan over year=2022..2025, one file each."""
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
    return LogicalPlan.scan_from_source(SourceVariant(src^), _schema(full))


def _hive_scan() raises -> LogicalPlan:
    """Lazily listed (dir-scan) Hive scan over d/, partition column p."""
    var pc = List[Field]()
    pc.append(Field("p", ArrowType.INT64, nullable=False))
    var data: List[String] = ["v"]
    var full: List[String] = ["v", "p"]
    var src = ParquetSource.dir_scan_hive("d/", _schema(data), pc^)
    return LogicalPlan.scan_from_source(SourceVariant(src^), _schema(full))


def _scan_paths(p: LogicalPlan) -> Int:
    """Path count of the parquet scan at or below a chain of Filters/Projects."""
    if p.tag == PLAN_FILTER:
        return _scan_paths(p._filter.value()[].child[])
    if p.tag == PLAN_PROJECT:
        return _scan_paths(p._project.value()[].child[])
    if p.tag != PLAN_SCAN or not p._scan.value()[].source._parquet:
        return -1
    return len(p._scan.value()[].source._parquet.value().paths)


def _hive_constraints(p: LogicalPlan) -> Int:
    """Constraint count of the scan's attached Hive predicate; -1 when none."""
    if p.tag == PLAN_FILTER:
        return _hive_constraints(p._filter.value()[].child[])
    if p.tag != PLAN_SCAN or not p._scan.value()[].source._parquet:
        return -2
    ref ps = p._scan.value()[].source._parquet.value()
    if not ps.hive_predicate:
        return -1
    return ps.hive_predicate.value().num_constraints()


def _agg_sum(key: String, val: String, oname: String, var child: LogicalPlan) -> LogicalPlan:
    """SUM(val) AS oname GROUP BY key."""
    var gb = ExprArray()
    gb.append(_c(key))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(_c(val)), Optional(oname)))
    return LogicalPlan.aggregate(gb^, aggs^, child^)


def _per_group() -> LogicalPlan:
    """SUM(v) AS total GROUP BY g over sales(g, v)."""
    var n: List[String] = ["g", "v"]
    return _agg_sum("g", "v", "total", _scan("sales.parquet", n))


def _per_group_computed() -> LogicalPlan:
    """SUM(v2) AS total GROUP BY g over Project[g, v*2 AS v2] over sales."""
    var n: List[String] = ["g", "v"]
    var pe = ExprArray()
    pe.append(_c("g"))
    pe.append(Expr.alias(Expr.binary(BIN_MUL, _c("v"), _lit(2)), "v2"))
    return _agg_sum("g", "v2", "total", LogicalPlan.project(pe^, _scan("sales.parquet", n)))


def _broadcast_site(var inner: LogicalPlan) -> LogicalPlan:
    """Filter(total > max(total)) over `inner`: the scalar-broadcast site."""
    var pred = Expr.binary(BIN_GT, _c("total"), Expr.agg_fn(AGG_MAX, _c("total")))
    return LogicalPlan.filter(pred^, inner^)


def _bound(inner_hash: UInt64) raises -> ScalarDepTable:
    """A table with the broadcast of the Aggregate hashed `inner_hash` bound
    to 7 over an empty in-memory batch of (g, total)."""
    var deps = ScalarDepTable()
    var on: List[String] = ["g", "total"]
    var src = InMemorySource.from_record_batch(RecordBatch.empty_from_schema(_schema(on)))
    deps.bind_broadcast(inner_hash, ScalarValue.from_int(7), src^, _schema(on), String("cache0"))
    return deps^


def _when_eq_1(c: String) -> Expr:
    """(CASE WHEN c > 1 THEN 1 ELSE 0 END) = 1: a predicate that halts OR
    factoring and that CSE can hoist."""
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(_gt(c, 1), _lit(1)))
    return Expr.binary(BIN_EQ, Expr.when(cases^, _lit(0)), _lit(1))


def _or_with_when(w: String, var x: Expr, var y: Expr, var z: Expr) -> Expr:
    """(W AND x AND y) OR (W AND x AND z), W = `_when_eq_1(w)`."""
    return _or(
        _and(_when_eq_1(w), _and(x.copy(), y^)),
        _and(_when_eq_1(w), _and(x^, z^)),
    )




# -----------------------------------------------------------------------------
# Step 1: scans
# -----------------------------------------------------------------------------


def test_partitioned_scan_is_pruned_before_pushdown() raises:
    """`year = 2024 AND id > 3` over the four-file year scan: one file is
    left, the `year` conjunct is gone and `id > 3` is in the scan.

    Defects caught: `partition_prune_scans` dropped (all four files stay and
    `year = 2024` lands in the scan filter), or moved after
    `push_predicates_down` (the Filter it reads has already been folded into
    the scan, so nothing is pruned)."""
    var pred = _and(_eq("year", 2024), _gt("id", 3))
    var out = _run(LogicalPlan.filter(pred^, _year_scan()))
    var r = _render(out)
    assert_equal(_scan_paths(out), 1, r)
    assert_equal(r, _want_prune_amt())


def test_hive_dir_scan_gets_its_partition_predicate_before_pushdown() raises:
    """`p = 1 AND v > 3` over the dir-scan Hive scan: the scan carries a
    one-constraint partition predicate and `v > 3` as its filter. A bare
    dir-scan Hive scan gets an empty predicate (zero constraints).

    Defects caught: `attach_hive_predicate` dropped (no predicate is attached,
    -1), or moved after `push_predicates_down` (the partition conjunct is
    already in the scan filter, so the attached predicate is empty)."""
    var pred = _and(_eq("p", 1), _gt("v", 3))
    var out = _run(LogicalPlan.filter(pred^, _hive_scan()))
    var r = _render(out)
    assert_equal(_hive_constraints(out), 1, r)
    assert_equal(r, _want_hive())
    assert_equal(_hive_constraints(_run(_hive_scan())), 0)


# -----------------------------------------------------------------------------
# Step 4: join predicates
# -----------------------------------------------------------------------------


def test_side_qualified_join_predicate_becomes_keys() raises:
    """An INNER join with no keys and `left.a = right.b AND left.ta >
    right.ub` as its predicate: `a = b` becomes the key, the range test the
    residual.

    Defect caught: `join_predicate_decompose` dropped. The side-qualified
    predicate stays whole and the join keeps no key."""
    var jt: List[String] = ["a", "ta"]
    var ju: List[String] = ["b", "ub"]
    var res = _and(
        Expr.binary(BIN_EQ, Expr.left("a"), Expr.right("b")),
        Expr.binary(BIN_GT, Expr.left("ta"), Expr.right("ub")),
    )
    var out = _run(LogicalPlan.join(
        _scan("t.parquet", jt), _scan("u.parquet", ju), List[String](), List[String](),
        JOIN_INNER, JOIN_ALGO_AUTO, Optional[OwnedPointer[Expr]](OwnedPointer(res^)),
    ))
    assert_equal(_render(out), _want_jpd2())


# -----------------------------------------------------------------------------
# Steps 8-9: CSE and the filter rules
# -----------------------------------------------------------------------------


def test_cse_hoists_a_repeated_projection_subtree() raises:
    """`Project[(a+1)*2 AS x, (a+1)*3 AS y]`: CSE names `a+1` `_cse_*` in a
    Project below, and step 13's `merge_projects` folds that Project back in,
    leaving the named subtree inside both expressions.

    Defect caught: `eliminate_common_subexpressions` dropped (no `_cse_*`
    name), or `merge_projects` dropped (two Projects)."""
    var n: List[String] = ["a", "b"]
    var a1 = Expr.binary(BIN_ADD, _c("a"), _lit(1))
    var ce = ExprArray()
    ce.append(Expr.alias(Expr.binary(BIN_MUL, a1.copy(), _lit(2)), "x"))
    ce.append(Expr.alias(Expr.binary(BIN_MUL, a1.copy(), _lit(3)), "y"))
    assert_equal(_render(_run(LogicalPlan.project(ce^, _scan("s.parquet", n)))), _want_cse_proj())


def test_consecutive_filters_over_an_aggregate_are_fused() raises:
    """Two HAVING-style Filters over an Aggregate: neither can move below it,
    so the result is one Filter holding both conjuncts.

    Defect caught: `fuse_filters` dropped. Two Filters stay stacked over the
    Aggregate."""
    var inner = LogicalPlan.filter(_gt("total", 5), _per_group())
    var out = _run(LogicalPlan.filter(Expr.binary(BIN_LT, _c("total"), _lit(100)), inner^))
    assert_equal(_render(out), _want_fuse_having())


def test_symmetric_or_is_decomposed_before_pushdown() raises:
    """`(a = 1 AND b = 2) OR (a = 2 AND b = 1)` over t JOIN u: `a IN (1, 2)`
    lands on the t side, `b IN (1, 2)` on the u side, and the OR stays above.

    Defects caught: `decompose_symmetric_or` dropped, or moved after
    `push_predicates_down` (the inferred ORs then sit above the join, not on
    its sides)."""
    var tn: List[String] = ["a", "ta"]
    var un: List[String] = ["b", "ub"]
    var sym = _or(_and(_eq("a", 1), _eq("b", 2)), _and(_eq("a", 2), _eq("b", 1)))
    var j = LogicalPlan.join(_scan("t.parquet", tn), _scan("u.parquet", un), _l1("ta"), _l1("ub"), JOIN_INNER)
    assert_equal(_render(_run(LogicalPlan.filter(sym^, j^))), _want_symor())


def test_an_or_held_back_by_a_when_factors_after_cse() raises:
    """`(W AND k = 1 AND b = 2) OR (W AND k = 1 AND c = 3)` with W a CASE/WHEN
    comparison: the first factoring stops at the WHEN, CSE replaces W with a
    `_cse_*` column, and the second factoring hoists `_cse_* AND k = 1`.

    Defect caught: the second `factor_or_conjuncts` (step 9) dropped. The
    Filter keeps the unfactored OR."""
    var n: List[String] = ["a", "b", "c", "k"]
    var pred = _or_with_when("a", _eq("k", 1), _eq("b", 2), _eq("c", 3))
    assert_equal(_render(_run(LogicalPlan.filter(pred^, _scan("t.parquet", n)))), _want_or2_when())


def test_a_factored_conjunct_reaches_its_join_side_in_step_16() raises:
    """The same OR over t JOIN u: after factoring, `k = 1` and `b = 2 OR
    c = 3` sit above the CSE Project in step 9. The step-16 pushdown moves
    them onto the t side (`k = 1` into the t scan).

    Defects caught: the step-16 `push_predicates_down` dropped (both stay
    above the join), and the second factoring moved after the step-9 pushdown
    (nothing factored reaches the t side)."""
    var tn: List[String] = ["a", "b", "c", "k"]
    var un: List[String] = ["k2", "u"]
    var w = _when_eq_1("a")
    var pred = _or(
        _and(_eq("k", 1), _and(_eq("b", 2), w.copy())),
        _and(_eq("k", 1), _and(_eq("c", 3), w.copy())),
    )
    var j = LogicalPlan.join(_scan("t.parquet", tn), _scan("u.parquet", un), _l1("k"), _l1("k2"), JOIN_INNER)
    assert_equal(_render(_run(LogicalPlan.filter(pred^, j^))), _want_or2_when_join())


def test_step_16_folds_a_pushed_equality_into_cross_join_keys() raises:
    """`(W AND ax = bx AND by = 2) OR (W AND ax = bx AND ay = 3)` over
    A CROSS JOIN B: `ax = bx` is factored out above the CSE Project, so steps
    9-10 cannot reach the cross join. Step 16 pushes it down and folds it
    into an INNER join on `bx = ax`.

    Defect caught: the step-16 `eliminate_cross_join` dropped. The plan
    keeps `Filter(ax = bx)` over `Join(type=CROSS)`."""
    var an: List[String] = ["ax", "ay"]
    var bn: List[String] = ["bx", "by"]
    var pred = _or_with_when("ay", _ceq("ax", "bx"), _eq("by", 2), _eq("ay", 3))
    var cross = LogicalPlan.join(_scan("A", an, 100), _scan("B", bn, 1000), List[String](), List[String](), JOIN_CROSS)
    assert_equal(_render(_run(LogicalPlan.filter(pred^, cross^))), _want_cross_cse())


def test_an_unbound_broadcast_site_records_a_request() raises:
    """`Filter(total > max(total))` over a grouped Aggregate with nothing
    bound: the plan is returned unchanged and `deps` holds one request.

    Defect caught: `scalar_broadcast_rewrite` dropped. No request is recorded
    and the caller never learns that the site needs a value."""
    var deps = ScalarDepTable()
    var out = optimize(_broadcast_site(_per_group()), OptimizerConfig(), deps)
    var r = _render(out)
    assert_equal(deps.num_requests(), 1, r)
    assert_equal(r, _want_bcast_unbound())


def test_a_broadcast_binding_on_the_written_aggregate_folds_before_step_11() raises:
    """A bound site over `SUM(v) AS total GROUP BY g` on sales(g, v, extra),
    bound on that Aggregate as written: the site folds to `total > 7` over
    the in-memory scan, with no request. It folds because the pass runs at
    step 9, before step 11 narrows the sales scan to (g, v) and so changes
    the Aggregate the binding is keyed on.

    Defect caught: `scalar_broadcast_rewrite` moved after step 14 (after
    `convert_inner_to_semi`). The narrowed Aggregate misses the binding, a
    request is recorded and the site stays unfolded."""
    var n: List[String] = ["g", "v", "extra"]
    var deps = _bound(_agg_sum("g", "v", "total", _scan("sales.parquet", n)).structural_hash())
    var out = optimize(_broadcast_site(_agg_sum("g", "v", "total", _scan("sales.parquet", n))), OptimizerConfig(), deps)
    var r = _render(out)
    assert_equal(deps.num_requests(), 0, r)
    assert_true(r.startswith(
        "Filter(predicate=BinaryOp(GT, ColRef(total), Literal(ScalarValue(int64, 7))))\n"
        + "  Scan(path=\"__in_memory__\", type=IN_MEMORY,"
    ), r)


def test_broadcast_fold_keeps_every_column_of_the_in_memory_scan() raises:
    """The same site over an Aggregate whose input is a Project, with the
    broadcast bound to 7: the Aggregate becomes an in-memory scan of
    (g, total) under `Filter(total > 7)`, and that scan reads both columns.

    Defect caught (komira#1292): `late_materialize` run after the fold, as the
    reference ran it at step 13 (the Project below the Aggregate is what turns
    step 13 on). It narrowed the in-memory scan to `projection=[total]`, the
    Filter's own column, while the plan still outputs `g, total`."""
    var deps = _bound(_per_group_computed().structural_hash())
    var out = optimize(_broadcast_site(_per_group_computed()), OptimizerConfig(), deps)
    var r = _render(out)
    assert_equal(deps.num_requests(), 0, r)
    assert_equal(_names(out), "g,total,", r)
    assert_true(r.startswith(
        "Filter(predicate=BinaryOp(GT, ColRef(total), Literal(ScalarValue(int64, 7))))\n"
        + "  Scan(path=\"__in_memory__\", type=IN_MEMORY,"
    ), r)
    assert_equal(r.find("projection="), -1, r)


# -----------------------------------------------------------------------------
# Expected renders
# -----------------------------------------------------------------------------


def _want_prune_amt() -> String:
    var l: List[String] = [
        "Scan(path=\"d/year=2024/f2.parquet\", type=PARQUET, source_kind=COLUMNAR, filter=BinaryOp(GT, ColRef(id), Literal(ScalarValue(int64, 3))))",
    ]
    return _lines(l)


def _want_hive() -> String:
    var l: List[String] = [
        "Scan(path=\"d/\", type=PARQUET, source_kind=COLUMNAR, filter=BinaryOp(GT, ColRef(v), Literal(ScalarValue(int64, 3))))",
    ]
    return _lines(l)


def _want_symor() -> String:
    var l: List[String] = [
        "Filter(predicate=BinaryOp(OR, BinaryOp(AND, BinaryOp(EQ, ColRef(a), Literal(ScalarValue(int64, 1))), BinaryOp(EQ, ColRef(b), Literal(ScalarValue(int64, 2)))), BinaryOp(AND, BinaryOp(EQ, ColRef(a), Literal(ScalarValue(int64, 2))), BinaryOp(EQ, ColRef(b), Literal(ScalarValue(int64, 1))))))",
        "  Join(type=INNER, on=[ta=ub], build=right)",
        "    Filter(predicate=BinaryOp(OR, BinaryOp(EQ, ColRef(a), Literal(ScalarValue(int64, 1))), BinaryOp(EQ, ColRef(a), Literal(ScalarValue(int64, 2)))))",
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)",
        "    Filter(predicate=BinaryOp(OR, BinaryOp(EQ, ColRef(b), Literal(ScalarValue(int64, 1))), BinaryOp(EQ, ColRef(b), Literal(ScalarValue(int64, 2)))))",
        "      Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_fuse_having() -> String:
    var l: List[String] = [
        "Filter(predicate=BinaryOp(AND, BinaryOp(GT, ColRef(total), Literal(ScalarValue(int64, 5))), BinaryOp(LT, ColRef(total), Literal(ScalarValue(int64, 100)))))",
        "  Aggregate(group_by=[ColRef(g)], aggs=[SUM(ColRef(v)).alias(\"total\")])",
        "    Scan(path=\"sales.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_or2_when() -> String:
    var l: List[String] = [
        "Project(exprs=[Alias(ColRef(a), \"a\"), Alias(ColRef(b), \"b\"), Alias(ColRef(c), \"c\"), Alias(ColRef(k), \"k\")])",
        "  Filter(predicate=BinaryOp(AND, BinaryOp(AND, ColRef(_cse_0c3f27f6_0), BinaryOp(EQ, ColRef(k), Literal(ScalarValue(int64, 1)))), BinaryOp(OR, BinaryOp(EQ, ColRef(b), Literal(ScalarValue(int64, 2))), BinaryOp(EQ, ColRef(c), Literal(ScalarValue(int64, 3))))))",
        "    Project(exprs=[Alias(ColRef(a), \"a\"), Alias(ColRef(b), \"b\"), Alias(ColRef(c), \"c\"), Alias(ColRef(k), \"k\"), Alias(BinaryOp(EQ, When(WHEN BinaryOp(GT, ColRef(a), Literal(ScalarValue(int64, 1))) THEN Literal(ScalarValue(int64, 1)), ELSE Literal(ScalarValue(int64, 0))), Literal(ScalarValue(int64, 1))), \"_cse_0c3f27f6_0\")])",
        "      Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_or2_when_join() -> String:
    var l: List[String] = [
        "Project(exprs=[Alias(ColRef(a), \"a\"), Alias(ColRef(b), \"b\"), Alias(ColRef(c), \"c\"), Alias(ColRef(k), \"k\"), Alias(ColRef(k2), \"k2\"), Alias(ColRef(u), \"u\")])",
        "  Filter(predicate=ColRef(_cse_0c3f27f6_0))",
        "    Project(exprs=[Alias(ColRef(a), \"a\"), Alias(ColRef(b), \"b\"), Alias(ColRef(c), \"c\"), Alias(ColRef(k), \"k\"), Alias(ColRef(k2), \"k2\"), Alias(ColRef(u), \"u\"), Alias(BinaryOp(EQ, When(WHEN BinaryOp(GT, ColRef(a), Literal(ScalarValue(int64, 1))) THEN Literal(ScalarValue(int64, 1)), ELSE Literal(ScalarValue(int64, 0))), Literal(ScalarValue(int64, 1))), \"_cse_0c3f27f6_0\")])",
        "      Join(type=INNER, on=[k=k2], build=left)",
        "        Filter(predicate=BinaryOp(OR, BinaryOp(EQ, ColRef(b), Literal(ScalarValue(int64, 2))), BinaryOp(EQ, ColRef(c), Literal(ScalarValue(int64, 3)))))",
        "          Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR, filter=BinaryOp(EQ, ColRef(k), Literal(ScalarValue(int64, 1))))",
        "        Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_cross_cse() -> String:
    var l: List[String] = [
        "Project(exprs=[Alias(ColRef(ax), \"ax\"), Alias(ColRef(ay), \"ay\"), Alias(ColRef(bx), \"bx\"), Alias(ColRef(by), \"by\")])",
        "  Filter(predicate=ColRef(_cse_0a156842_0))",
        "    Project(exprs=[Alias(ColRef(ax), \"ax\"), Alias(ColRef(ay), \"ay\"), Alias(ColRef(bx), \"bx\"), Alias(ColRef(by), \"by\"), Alias(BinaryOp(EQ, When(WHEN BinaryOp(GT, ColRef(ay), Literal(ScalarValue(int64, 1))) THEN Literal(ScalarValue(int64, 1)), ELSE Literal(ScalarValue(int64, 0))), Literal(ScalarValue(int64, 1))), \"_cse_0a156842_0\")])",
        "      Filter(predicate=BinaryOp(OR, BinaryOp(EQ, ColRef(by), Literal(ScalarValue(int64, 2))), BinaryOp(EQ, ColRef(ay), Literal(ScalarValue(int64, 3)))))",
        "        Join(type=INNER, on=[ax=bx], build=left)",
        "          Scan(path=\"A\", type=PARQUET, source_kind=COLUMNAR)",
        "          Scan(path=\"B\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_bcast_unbound() -> String:
    var l: List[String] = [
        "Filter(predicate=BinaryOp(GT, ColRef(total), AggFn(3, ColRef(total))))",
        "  Aggregate(group_by=[ColRef(g)], aggs=[SUM(ColRef(v)).alias(\"total\")])",
        "    Scan(path=\"sales.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_jpd2() -> String:
    var l: List[String] = [
        "Join(type=INNER, on=[a=b], residual=BinaryOp(GT, ColRef(ta), ColRef(ub)), build=right)",
        "  Scan(path=\"t.parquet\", type=PARQUET, source_kind=COLUMNAR)",
        "  Scan(path=\"u.parquet\", type=PARQUET, source_kind=COLUMNAR)",
    ]
    return _lines(l)


def _want_cse_proj() -> String:
    var l: List[String] = [
        "Project(exprs=[Alias(BinaryOp(MUL, Alias(BinaryOp(ADD, ColRef(a), Literal(ScalarValue(int64, 1))), \"_cse_8ce13a39_0\"), Literal(ScalarValue(int64, 2))), \"x\"), Alias(BinaryOp(MUL, Alias(BinaryOp(ADD, ColRef(a), Literal(ScalarValue(int64, 1))), \"_cse_8ce13a39_0\"), Literal(ScalarValue(int64, 3))), \"y\")])",
        "  Scan(path=\"s.parquet\", type=PARQUET, source_kind=COLUMNAR, projection=[a])",
    ]
    return _lines(l)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
