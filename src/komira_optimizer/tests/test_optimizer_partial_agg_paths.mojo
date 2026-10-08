# =============================================================================
# optimizer_partial_agg: the rewrite shape, the walks, and the name helpers
# =============================================================================
#
# test_optimizer_agg_pushdown covers the gate and each soundness clause of
# `_classify_push_inner`. This file reaches the rest: the clause checks of the
# test-only `_classify_push_unchecked` (each with its own verdict), the shape
# `push_aggregate_below_join_force` builds on both sides, the recursion of both
# entry points through every node kind (with each wrapper's own fields), and
# the alias / output-name helpers. Each test names the defect it catches.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import (
    AggExpr,
    sum as agg_sum,
    count as agg_count,
    min as agg_min,
    max as agg_max,
    mean as agg_mean,
    count_distinct,
    AGG_SUM,
    AGG_COUNT,
    AGG_MIN,
    AGG_MAX,
    AGG_MEAN,
)
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_GT, EXPR_COL_REF
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    AggExprArray,
    ExprArray,
    LogicalPlan,
    SOURCE_PARQUET,
    JOIN_ALGO_HASH,
    JOIN_INNER,
    JOIN_LEFT,
    PLAN_AGGREGATE,
    PLAN_DISTINCT,
    PLAN_FILTER,
    PLAN_JOIN,
    PLAN_LIMIT,
    PLAN_PROJECT,
    PLAN_SCAN,
    PLAN_SORT,
    PLAN_TOPN,
)
from komira_optimizer.optimizer_partial_agg import (
    push_aggregate_below_join,
    push_aggregate_below_join_force,
    _agg_output_name,
    _build_partial_and_merge,
    _classify_push_inner,
    _classify_push_unchecked,
    _merge_func_for,
    _partial_alias,
    _PUSH_NONE,
    _PUSH_LEFT,
    _PUSH_RIGHT,
)


# -----------------------------------------------------------------------------
# fixtures
# -----------------------------------------------------------------------------


def _schema(var names: List[String]) -> Schema:
    var sb = SchemaBuilder()
    for i in range(len(names)):
        sb.add_field(Field(names[i], ArrowType.INT64, False))
    return sb.build()


def _l1(a: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    return out^


def _l2(a: String, b: String) -> List[String]:
    var out = _l1(a)
    out.append(b)
    return out^


def _l3(a: String, b: String, c: String) -> List[String]:
    var out = _l2(a, b)
    out.append(c)
    return out^


def _scan(path: String, var names: List[String]) -> LogicalPlan:
    return LogicalPlan.scan(path, SOURCE_PARQUET, _schema(names^))


def _orders() -> LogicalPlan:
    var n = _l3("order_id", "customer_id", "region")
    n.append("price")
    return _scan("orders.parquet", n^)


def _customers() -> LogicalPlan:
    return _scan("customers.parquet", _l2("customer_id", "country"))


def _dim() -> LogicalPlan:
    return _scan("dim.parquet", _l2("dim_id", "attr"))


def _fact() -> LogicalPlan:
    return _scan("fact.parquet", _l2("fk_id", "measure"))


def _gb1(name: String) -> ExprArray:
    var gb = ExprArray()
    gb.append(Expr.col_ref(name))
    return gb^


def _oc_join(jt: UInt8 = JOIN_INNER) -> LogicalPlan:
    return LogicalPlan.join(
        _orders(), _customers(), _l1("customer_id"), _l1("customer_id"), jt
    )


def _df_join() -> LogicalPlan:
    return LogicalPlan.join(_dim(), _fact(), _l1("dim_id"), _l1("fk_id"), JOIN_INNER)


def _left_fire() -> LogicalPlan:
    """Aggregate(customer_id; sum, count, min, max of price) over orders JOIN
    customers: every referenced column is on the left, key in group_by."""
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("price")).alias("total_price"))
    aggs.append(agg_count(col("price")).alias("n"))
    aggs.append(agg_min(col("price")).alias("lo"))
    aggs.append(agg_max(col("price")).alias("hi"))
    return LogicalPlan.aggregate(_gb1("customer_id"), aggs^, _oc_join())


def _right_fire() -> LogicalPlan:
    """Aggregate(fk_id; sum(measure)) over dim JOIN fact: all on the right."""
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("measure")).alias("m"))
    return LogicalPlan.aggregate(_gb1("fk_id"), aggs^, _df_join())


def _verdict_unchecked(plan: LogicalPlan) -> Int:
    return Int(_classify_push_unchecked(plan, plan._aggregate.value()[].child[]).kind)


def _verdict_inner(plan: LogicalPlan) -> Int:
    return Int(_classify_push_inner(plan, plan._aggregate.value()[].child[]).kind)


# -----------------------------------------------------------------------------
# _classify_push_unchecked: one verdict per clause
# -----------------------------------------------------------------------------


def test_unchecked_fires_left_and_right() raises:
    """Catches a classifier that never fires, or picks the wrong side."""
    assert_equal(_verdict_unchecked(_left_fire()), Int(_PUSH_LEFT))
    assert_equal(_verdict_unchecked(_right_fire()), Int(_PUSH_RIGHT))


def test_unchecked_declines_each_clause() raises:
    """Each shape violates exactly one clause. Catches a removed check: the
    shape would then be classified LEFT or RIGHT."""
    var a1 = AggExprArray()
    a1.append(agg_sum(col("price")).alias("s"))
    assert_equal(
        _verdict_unchecked(LogicalPlan.aggregate(_gb1("customer_id"), a1^, _oc_join(JOIN_LEFT))),
        Int(_PUSH_NONE), "LEFT join",
    )
    var a2 = AggExprArray()
    a2.append(count_distinct(col("price")).alias("d"))
    assert_equal(
        _verdict_unchecked(LogicalPlan.aggregate(_gb1("customer_id"), a2^, _oc_join())),
        Int(_PUSH_NONE), "COUNT DISTINCT",
    )
    var a3 = AggExprArray()
    a3.append(agg_count())
    assert_equal(
        _verdict_unchecked(LogicalPlan.aggregate(ExprArray(), a3^, _oc_join())),
        Int(_PUSH_NONE), "no column referenced",
    )
    var gb4 = ExprArray()
    gb4.append(Expr.col_ref("region"))
    gb4.append(Expr.col_ref("country"))
    var a4 = AggExprArray()
    a4.append(agg_sum(col("price")).alias("s"))
    assert_equal(
        _verdict_unchecked(LogicalPlan.aggregate(gb4^, a4^, _oc_join())),
        Int(_PUSH_NONE), "columns on both sides",
    )
    var a5 = AggExprArray()
    a5.append(agg_sum(col("price")).alias("s"))
    assert_equal(
        _verdict_unchecked(LogicalPlan.aggregate(_gb1("region"), a5^, _oc_join())),
        Int(_PUSH_NONE), "left key not grouped",
    )
    var a6 = AggExprArray()
    a6.append(agg_sum(col("measure")).alias("s"))
    assert_equal(
        _verdict_unchecked(LogicalPlan.aggregate(ExprArray(), a6^, _df_join())),
        Int(_PUSH_NONE), "right key not grouped",
    )
    var gb7 = ExprArray()
    gb7.append(Expr.binary(BIN_ADD, Expr.col_ref("customer_id"), Expr.literal(ScalarValue.from_int(0))))
    var a7 = AggExprArray()
    a7.append(agg_sum(col("price")).alias("s"))
    assert_equal(
        _verdict_unchecked(LogicalPlan.aggregate(gb7^, a7^, _oc_join())),
        Int(_PUSH_NONE), "computed group key never names the join key",
    )


def _collision_plan_raw() -> LogicalPlan:
    """dim2(dim_id, attr) JOIN fact2(fk_id, measure, attr), grouped by
    (fk_id, attr): every column resolves on the right, but `attr` also exists
    on the left, so the join output would suffix the right one."""
    var fact2 = _scan("fact2.parquet", _l3("fk_id", "measure", "attr"))
    var dim2 = _scan("dim2.parquet", _l2("dim_id", "attr"))
    var join = LogicalPlan.join(dim2^, fact2^, _l1("dim_id"), _l1("fk_id"), JOIN_INNER)
    var gb = ExprArray()
    gb.append(Expr.col_ref("fk_id"))
    gb.append(Expr.col_ref("attr"))
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("measure")).alias("s"))
    return LogicalPlan.aggregate(gb^, aggs^, join^)


def test_unchecked_collision_guard() raises:
    """A right-pushed group column that the left also has would be renamed by
    the join. Catches a missing collision guard (RIGHT would be returned)."""
    var p = _collision_plan_raw()
    # `attr` is on both sides, `fk_id` only right: the columns resolve right.
    assert_equal(_verdict_unchecked(p), Int(_PUSH_NONE))


def test_inner_reaches_every_clause_and_clause_c_rejects() raises:
    """The production classifier sees the same shapes: no column, a right
    push, a right collision, a left push. Clause (c) rejects every one that
    survives. Catches a clause-(c) bypass on either side."""
    var a = AggExprArray()
    a.append(agg_count())
    assert_equal(
        _verdict_inner(LogicalPlan.aggregate(ExprArray(), a^, _oc_join())), Int(_PUSH_NONE)
    )
    assert_equal(_verdict_inner(_right_fire()), Int(_PUSH_NONE))
    assert_equal(_verdict_inner(_collision_plan_raw()), Int(_PUSH_NONE))
    var a2 = AggExprArray()
    a2.append(agg_sum(col("measure")).alias("s"))
    assert_equal(
        _verdict_inner(LogicalPlan.aggregate(ExprArray(), a2^, _df_join())), Int(_PUSH_NONE)
    )
    assert_equal(_verdict_inner(_left_fire()), Int(_PUSH_NONE))


# -----------------------------------------------------------------------------
# the rewrite shape (force entry)
# -----------------------------------------------------------------------------


def test_force_left_builds_partial_and_merge() raises:
    """Catches a rewrite that puts the partial on the wrong side, drops the
    join keys, or merges COUNT with COUNT instead of SUM."""
    var out = push_aggregate_below_join_force(_left_fire())
    assert_equal(Int(out.tag), Int(PLAN_AGGREGATE))
    ref top = out._aggregate.value()[]
    assert_equal(Int(top.agg_exprs[1].func), Int(AGG_SUM), "merge of COUNT is SUM")
    assert_equal(top.agg_exprs[1].alias_name.value(), String("n"))
    assert_equal(top.agg_exprs[1].child.value().col_ref_name(), String("__partial_count_n"))
    ref j = top.child[]
    assert_equal(Int(j.tag), Int(PLAN_JOIN))
    assert_equal(j._join.value()[].left_on[0], String("customer_id"))
    assert_equal(Int(j._join.value()[].join_type), Int(JOIN_INNER))
    ref partial = j._join.value()[].left[]
    assert_equal(Int(partial.tag), Int(PLAN_AGGREGATE))
    assert_equal(len(partial._aggregate.value()[].group_by), 1)
    assert_equal(Int(partial._aggregate.value()[].agg_exprs[1].func), Int(AGG_COUNT))
    assert_equal(Int(j._join.value()[].right[].tag), Int(PLAN_SCAN))


def test_force_right_builds_partial_on_the_right() raises:
    """Catches a rewrite that ignores `push_to_left=False`."""
    var out = push_aggregate_below_join_force(_right_fire())
    ref j = out._aggregate.value()[].child[]
    assert_equal(Int(j._join.value()[].left[].tag), Int(PLAN_SCAN))
    assert_equal(Int(j._join.value()[].right[].tag), Int(PLAN_AGGREGATE))
    assert_equal(j._join.value()[].right_on[0], String("fk_id"))


def test_force_declines_leave_the_aggregate_over_the_join() raises:
    """A failing clause, a LEFT join, a residual, a non-join child: the
    aggregate is rebuilt unchanged. Catches a fall-through that rewrites."""
    var a1 = AggExprArray()
    a1.append(agg_sum(col("price")).alias("s"))
    var no_key = push_aggregate_below_join_force(
        LogicalPlan.aggregate(_gb1("region"), a1^, _oc_join())
    )
    assert_equal(Int(no_key._aggregate.value()[].child[]._join.value()[].left[].tag), Int(PLAN_SCAN))
    var a2 = AggExprArray()
    a2.append(agg_sum(col("price")).alias("s"))
    var left = push_aggregate_below_join_force(
        LogicalPlan.aggregate(_gb1("customer_id"), a2^, _oc_join(JOIN_LEFT))
    )
    assert_equal(Int(left._aggregate.value()[].child[]._join.value()[].left[].tag), Int(PLAN_SCAN))
    var resid: Optional[OwnedPointer[Expr]] = OwnedPointer(
        Expr.binary(BIN_GT, Expr.col_ref("price"), Expr.literal(ScalarValue.from_int(1)))
    )
    var rj = LogicalPlan.join(
        _orders(), _customers(), _l1("customer_id"), _l1("customer_id"), JOIN_INNER,
        JOIN_ALGO_HASH, resid^,
    )
    var a3 = AggExprArray()
    a3.append(agg_sum(col("price")).alias("s"))
    var with_resid = push_aggregate_below_join_force(
        LogicalPlan.aggregate(_gb1("customer_id"), a3^, rj^)
    )
    assert_equal(
        Int(with_resid._aggregate.value()[].child[]._join.value()[].left[].tag), Int(PLAN_SCAN)
    )
    var a4 = AggExprArray()
    a4.append(agg_sum(col("price")).alias("s"))
    var over_scan = push_aggregate_below_join_force(
        LogicalPlan.aggregate(_gb1("customer_id"), a4^, _orders())
    )
    assert_equal(Int(over_scan._aggregate.value()[].child[].tag), Int(PLAN_SCAN))


# -----------------------------------------------------------------------------
# the walks: every wrapper keeps its own fields
# -----------------------------------------------------------------------------


def _wrapped(var core: LogicalPlan) -> LogicalPlan:
    """TopN(n=4) / Distinct([customer_id]) / Limit(5, offset 1) / Sort(DESC,
    NULLS FIRST) / Filter / Project / core."""
    var pe = ExprArray()
    pe.append(Expr.col_ref("customer_id"))
    pe.append(Expr.col_ref("total_price"))
    var proj = LogicalPlan.project(pe^, core^)
    var pred = Expr.binary(BIN_GT, Expr.col_ref("total_price"), Expr.literal(ScalarValue.from_int(0)))
    var filt = LogicalPlan.filter(pred^, proj^)
    var d = List[Bool]()
    d.append(True)
    var nf = List[Bool]()
    nf.append(True)
    var srt = LogicalPlan.sort(_l1("customer_id"), d.copy(), filt^, Optional(nf.copy()))
    var lim = LogicalPlan.limit(5, srt^, offset=1)
    var dis = LogicalPlan.distinct(Optional(_l1("customer_id")), lim^)
    return LogicalPlan.topn(_l1("customer_id"), d^, 4, dis^, Optional(nf^))


def _core_of(imm out: LogicalPlan) raises -> Int:
    """Tag of the join's left child under the wrapper stack."""
    ref dis = out._topn.value()[].child[]
    ref lim = dis._distinct.value()[].child[]
    ref srt = lim._limit.value()[].child[]
    ref filt = srt._sort.value()[].child[]
    ref proj = filt._filter.value()[].child[]
    ref agg = proj._project.value()[].child[]
    return Int(agg._aggregate.value()[].child[]._join.value()[].left[].tag)


def _assert_wrappers_kept(imm out: LogicalPlan) raises:
    assert_equal(Int(out.tag), Int(PLAN_TOPN))
    assert_equal(out._topn.value()[].n, 4)
    assert_true(out._topn.value()[].nulls_first[0], "topn NULLS FIRST")
    ref dis = out._topn.value()[].child[]
    assert_equal(Int(dis.tag), Int(PLAN_DISTINCT))
    assert_equal(dis._distinct.value()[].columns.value()[0], String("customer_id"))
    ref lim = dis._distinct.value()[].child[]
    assert_equal(Int(lim.tag), Int(PLAN_LIMIT))
    assert_equal(lim._limit.value()[].n, 5)
    assert_equal(lim._limit.value()[].offset, 1, "limit offset survives")
    ref srt = lim._limit.value()[].child[]
    assert_equal(Int(srt.tag), Int(PLAN_SORT))
    assert_true(srt._sort.value()[].nulls_first[0], "sort NULLS FIRST")
    assert_true(srt._sort.value()[].descending[0], "sort DESC")
    ref filt = srt._sort.value()[].child[]
    assert_equal(Int(filt.tag), Int(PLAN_FILTER))
    assert_equal(Int(filt._filter.value()[].child[].tag), Int(PLAN_PROJECT))


def test_force_walk_rewrites_below_every_wrapper() raises:
    """Catches a wrapper arm that does not recurse (the inner aggregate stays
    un-pushed) or rebuilds without its own fields."""
    var out = push_aggregate_below_join_force(_wrapped(_left_fire()))
    _assert_wrappers_kept(out)
    assert_equal(_core_of(out), Int(PLAN_AGGREGATE), "pushed below all wrappers")
    var nc: Optional[List[String]] = None
    var d = push_aggregate_below_join_force(LogicalPlan.distinct(nc^, _left_fire()))
    assert_false(Bool(d._distinct.value()[].columns), "no columns stays None")
    assert_equal(
        Int(d._distinct.value()[].child[]._aggregate.value()[].child[]._join.value()[].left[].tag),
        Int(PLAN_AGGREGATE),
    )


def test_force_walk_through_a_join_keeps_residual_and_hint() raises:
    """Catches a Join arm that drops the residual predicate or the algorithm
    hint while recursing into both children."""
    var resid: Optional[OwnedPointer[Expr]] = OwnedPointer(
        Expr.binary(BIN_GT, Expr.col_ref("total_price"), Expr.literal(ScalarValue.from_int(0)))
    )
    var j = LogicalPlan.join(
        _left_fire(), _right_fire(), _l1("customer_id"), _l1("fk_id"), JOIN_INNER,
        JOIN_ALGO_HASH, resid^,
    )
    var out = push_aggregate_below_join_force(j^)
    ref jd = out._join.value()[]
    assert_true(jd.has_residual())
    assert_equal(Int(jd.algo_hint), Int(JOIN_ALGO_HASH))
    assert_equal(
        Int(jd.left[]._aggregate.value()[].child[]._join.value()[].left[].tag), Int(PLAN_AGGREGATE)
    )
    assert_equal(
        Int(jd.right[]._aggregate.value()[].child[]._join.value()[].right[].tag), Int(PLAN_AGGREGATE)
    )
    var plain = LogicalPlan.join(
        _left_fire(), _customers(), _l1("customer_id"), _l1("customer_id"), JOIN_INNER
    )
    var out2 = push_aggregate_below_join_force(plain^)
    assert_false(out2._join.value()[].has_residual())


def test_gated_walk_through_a_join_keeps_residual_and_hint() raises:
    """The production entry's Join arm rebuilds the join after recursing into
    both children. Catches a rebuild that drops the residual predicate (a lost
    join condition, wrong rows) or resets the algorithm hint to the default."""
    var resid: Optional[OwnedPointer[Expr]] = OwnedPointer(
        Expr.binary(BIN_GT, Expr.col_ref("x"), Expr.col_ref("y"))
    )
    var j = LogicalPlan.join(
        _scan("a.parquet", _l2("k", "x")), _scan("b.parquet", _l2("k", "y")),
        _l1("k"), _l1("k"), JOIN_INNER, JOIN_ALGO_HASH, resid^,
    )
    var out = push_aggregate_below_join(j^)
    assert_equal(Int(out.tag), Int(PLAN_JOIN))
    ref jd = out._join.value()[]
    assert_true(jd.has_residual(), "gated walk keeps the join residual")
    assert_equal(Int(jd.algo_hint), Int(JOIN_ALGO_HASH), "gated walk keeps the algo hint")


def test_gated_walk_keeps_every_wrapper_and_does_not_push() raises:
    """The production entry walks the same kinds while the gate is off.
    Catches a wrapper arm that loses its fields, and any push below a join."""
    var out = push_aggregate_below_join(_wrapped(_left_fire()))
    _assert_wrappers_kept(out)
    assert_equal(_core_of(out), Int(PLAN_SCAN), "gated: no partial aggregate")
    var nc: Optional[List[String]] = None
    var d = push_aggregate_below_join(LogicalPlan.distinct(nc^, _left_fire()))
    assert_false(Bool(d._distinct.value()[].columns))
    var j = push_aggregate_below_join(
        LogicalPlan.join(_left_fire(), _customers(), _l1("customer_id"), _l1("customer_id"), JOIN_INNER)
    )
    assert_equal(Int(j.tag), Int(PLAN_JOIN))
    assert_equal(j._join.value()[].left_on[0], String("customer_id"))
    var a = AggExprArray()
    a.append(agg_sum(col("price")).alias("s"))
    var over_left = push_aggregate_below_join(
        LogicalPlan.aggregate(_gb1("customer_id"), a^, _oc_join(JOIN_LEFT))
    )
    assert_equal(Int(over_left._aggregate.value()[].child[].tag), Int(PLAN_JOIN))
    var a2 = AggExprArray()
    a2.append(agg_sum(col("price")).alias("s"))
    var over_scan = push_aggregate_below_join(
        LogicalPlan.aggregate(_gb1("customer_id"), a2^, _orders())
    )
    assert_equal(Int(over_scan._aggregate.value()[].child[].tag), Int(PLAN_SCAN))
    var leaf = push_aggregate_below_join(_orders())
    assert_equal(Int(leaf.tag), Int(PLAN_SCAN))


# -----------------------------------------------------------------------------
# names and merge functions
# -----------------------------------------------------------------------------


def _unaliased(func: UInt8) -> AggExpr:
    return AggExpr(func, Optional(Expr.col_ref("x")), Optional[String](None))


def test_output_name_arms() raises:
    """Catches an output-name ladder that confuses two functions, or ignores
    the alias (the merge would then produce a different column name)."""
    assert_equal(_agg_output_name(agg_sum(col("x")).alias("t")), String("t"))
    assert_equal(_agg_output_name(_unaliased(AGG_SUM)), String("sum"))
    assert_equal(_agg_output_name(_unaliased(AGG_COUNT)), String("count"))
    assert_equal(_agg_output_name(_unaliased(AGG_MIN)), String("min"))
    assert_equal(_agg_output_name(_unaliased(AGG_MAX)), String("max"))
    assert_equal(_agg_output_name(_unaliased(AGG_MEAN)), String("mean"))
    var cd = count_distinct(col("x"))
    cd.alias_name = None
    assert_equal(_agg_output_name(cd), String("agg"))


def test_partial_alias_and_merge_func_arms() raises:
    """Catches an alias ladder that mints the same alias for two functions,
    and a merge function other than SUM for COUNT."""
    assert_equal(_partial_alias(AGG_SUM, "o"), String("__partial_sum_o"))
    assert_equal(_partial_alias(AGG_COUNT, "o"), String("__partial_count_o"))
    assert_equal(_partial_alias(AGG_MIN, "o"), String("__partial_min_o"))
    assert_equal(_partial_alias(AGG_MAX, "o"), String("__partial_max_o"))
    assert_equal(_partial_alias(AGG_MEAN, "o"), String("__partial_mean_o"))
    assert_equal(_partial_alias(count_distinct(col("x")).func, "o"), String("__partial_agg_o"))
    assert_equal(Int(_merge_func_for(AGG_COUNT)), Int(AGG_SUM))
    assert_equal(Int(_merge_func_for(AGG_MIN)), Int(AGG_MIN))
    assert_equal(Int(_merge_func_for(AGG_MAX)), Int(AGG_MAX))


def test_partials_without_an_input_column() raises:
    """COUNT(*) and an input-less MEAN carry no child into their partials.
    Catches a builder that invents a child or dereferences a missing one."""
    var aggs = AggExprArray()
    aggs.append(agg_count())
    aggs.append(AggExpr(AGG_MEAN, Optional[Expr](None), Optional(String("m"))))
    var partials = AggExprArray()
    var merges = AggExprArray()
    _build_partial_and_merge(aggs, partials, merges)
    assert_equal(len(partials), 3, "count -> 1, mean -> 2")
    assert_false(Bool(partials[0].child), "count(*) partial has no child")
    assert_false(Bool(partials[1].child), "mean partial sum has no child")
    assert_false(Bool(partials[2].child), "mean partial count has no child")
    assert_equal(partials[0].alias_name.value(), String("__partial_count_count"))
    assert_equal(Int(merges[0].func), Int(AGG_SUM))
    assert_equal(Int(merges[0].child.value().tag), Int(EXPR_COL_REF))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
