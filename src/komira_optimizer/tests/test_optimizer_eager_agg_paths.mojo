# =============================================================================
# optimizer_eager_agg: cost gate, classifier gates, rewrite details, the walk
# =============================================================================
#
# test_optimizer_eager_agg pins the headline fires and a few declines. This
# file reaches every remaining branch: each clause of the cost gate (including
# the fail-closed multi-way arm and the stats-free arm), each classifier gate,
# the details of the rewritten tree (partial aliases, merge functions, the LEFT
# COUNT coalesce, the partial group-by), the helpers, and the recursion of
# `_eager_rec` through every node kind. Each test names the defect it catches.
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
    AGG_SUM,
    AGG_COUNT,
    AGG_MIN,
    AGG_MAX,
    AGG_MEAN,
)
from komira_plan_expr.col_expr import col
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_EQ, BIN_GT, EXPR_COL_REF, EXPR_WHEN
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    AggExprArray,
    ExprArray,
    LogicalPlan,
    SOURCE_PARQUET,
    JOIN_ALGO_HASH,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_RIGHT,
    JOIN_SEMI,
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
from komira_optimizer.optimizer_eager_agg import (
    eager_aggregate_pushdown,
    EAGER_BASE_MULTI_WAY,
    EAGER_BASE_NO_STATS,
    _EAGER_NONE,
    _EAGER_LEFT,
    _EAGER_RIGHT,
    _build_eager_partial_and_merge,
    _classify_eager_push,
    _eager_op_tag,
    _is_fireable_join,
    _is_pure_narrowing_project,
    _is_reducible_leaf,
    _leaf_base_rows,
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


def _lit(k: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(k))


def _fact(rows: Optional[Int] = None) -> LogicalPlan:
    return LogicalPlan.scan(
        String("fact.parquet"), SOURCE_PARQUET, _schema(_l2("fk_id", "measure")),
        row_count=rows,
    )


def _dim(rows: Optional[Int] = None) -> LogicalPlan:
    return LogicalPlan.scan(
        String("dim.parquet"), SOURCE_PARQUET, _schema(_l2("dim_id", "dim_attr")),
        row_count=rows,
    )


def _big() -> Optional[Int]:
    return Optional[Int](1_500_000)


def _mid() -> Optional[Int]:
    return Optional[Int](150_000)


def _join_fd(var l: LogicalPlan, var r: LogicalPlan, jt: UInt8 = JOIN_INNER) -> LogicalPlan:
    """fact-side child first: keys fk_id = dim_id."""
    return LogicalPlan.join(l^, r^, _l1("fk_id"), _l1("dim_id"), jt)


def _join_df(var l: LogicalPlan, var r: LogicalPlan, jt: UInt8 = JOIN_INNER) -> LogicalPlan:
    """dim-side child first: keys dim_id = fk_id."""
    return LogicalPlan.join(l^, r^, _l1("dim_id"), _l1("fk_id"), jt)


def _gb1(name: String) -> ExprArray:
    var gb = ExprArray()
    gb.append(Expr.col_ref(name))
    return gb^


def _sum_measure() -> AggExprArray:
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("measure")).alias("total"))
    return aggs^


def _agg_attr(var child: LogicalPlan) -> LogicalPlan:
    """Aggregate(dim_attr; sum(measure) AS total) over `child`."""
    return LogicalPlan.aggregate(_gb1("dim_attr"), _sum_measure(), child^)


def _fire_left() -> LogicalPlan:
    """No row counts: stats-free, fires onto the fact (left) side."""
    return _agg_attr(_join_fd(_fact(), _dim()))


def _verdict(plan: LogicalPlan) -> Int:
    ref child = plan._aggregate.value()[].child[]
    return Int(_classify_eager_push(plan, child).kind)


def _partial_left(imm out: LogicalPlan) raises -> Int:
    """Tag of the join's left child under the root aggregate."""
    return Int(out._aggregate.value()[].child[]._join.value()[].left[].tag)


def _sort(var child: LogicalPlan) -> LogicalPlan:
    var d = List[Bool]()
    d.append(True)
    var nf = List[Bool]()
    nf.append(True)
    return LogicalPlan.sort(_l1("dim_attr"), d^, child^, Optional(nf^))


def _plain_project(var child: LogicalPlan, var names: List[String]) -> LogicalPlan:
    var ex = ExprArray()
    for i in range(len(names)):
        ex.append(Expr.col_ref(names[i]))
    return LogicalPlan.project(ex^, child^)


# -----------------------------------------------------------------------------
# the cost gate
# -----------------------------------------------------------------------------


def test_cost_gate_declines_a_smaller_pushed_side() raises:
    """S (60k) smaller than the other side (100k): pre-aggregating the
    dimension-like side does not reduce it. Catches a removed clause 2."""
    var p = _agg_attr(_join_fd(_fact(Optional[Int](60_000)), _dim(Optional[Int](100_000))))
    assert_equal(_verdict(p), Int(_EAGER_NONE))


def test_cost_gate_fails_closed_on_a_multi_way_other_side() raises:
    """The other side is a Distinct: no scan base to measure cover against.
    Catches the old skip-instead-of-decline (the pass fired unguarded)."""
    var nc: Optional[List[String]] = None
    var other = LogicalPlan.distinct(nc^, _dim(_mid()))
    assert_equal(_verdict(_agg_attr(_join_fd(_fact(_big()), other^))), Int(_EAGER_NONE))


def test_cost_gate_declines_a_selectively_filtered_other_side() raises:
    """Filter(dim_attr = 3) keeps ~10% of 150k: the join discards most of S
    cheaply. Catches a removed cover-ratio clause."""
    var pred = Expr.binary(BIN_EQ, Expr.col_ref("dim_attr"), _lit(3))
    var other = LogicalPlan.filter(pred^, _dim(_mid()))
    assert_equal(_verdict(_agg_attr(_join_fd(_fact(_big()), other^))), Int(_EAGER_NONE))


def test_cost_gate_measures_through_sort_and_project() raises:
    """A Sort or plain Project over the other scan keeps its base row count,
    so full cover fires. Catches a base walk that stops at either (it would
    report multi-way and decline)."""
    var s = _agg_attr(_join_fd(_fact(_big()), _sort(_dim(_mid()))))
    assert_equal(_verdict(s), Int(_EAGER_LEFT), "sort")
    var p = _agg_attr(_join_fd(_fact(_big()), _plain_project(_dim(_mid()), _l2("dim_id", "dim_attr"))))
    assert_equal(_verdict(p), Int(_EAGER_LEFT), "project")


def test_leaf_base_rows_sentinels() raises:
    """Catches a base walk that collapses the two sentinels, or loses a row
    count through a wrapper."""
    assert_equal(_leaf_base_rows(_dim(_mid())), 150_000)
    assert_equal(_leaf_base_rows(_dim()), EAGER_BASE_NO_STATS)
    var pred = Expr.binary(BIN_GT, Expr.col_ref("dim_id"), _lit(0))
    assert_equal(_leaf_base_rows(LogicalPlan.filter(pred^, _dim(_mid()))), 150_000)
    assert_equal(_leaf_base_rows(_join_fd(_fact(_big()), _dim(_mid()))), EAGER_BASE_MULTI_WAY)
    assert_true(EAGER_BASE_NO_STATS != EAGER_BASE_MULTI_WAY)


# -----------------------------------------------------------------------------
# the classifier gates
# -----------------------------------------------------------------------------


def test_join_shape_gates() raises:
    """RIGHT join, a residual, no equi-keys: each declines. Catches a removed
    join-type, residual or key check."""
    assert_equal(_verdict(_agg_attr(_join_fd(_fact(), _dim(), JOIN_RIGHT))), Int(_EAGER_NONE))
    var resid: Optional[OwnedPointer[Expr]] = OwnedPointer(
        Expr.binary(BIN_GT, Expr.col_ref("measure"), _lit(0))
    )
    var rj = LogicalPlan.join(
        _fact(), _dim(), _l1("fk_id"), _l1("dim_id"), JOIN_INNER, JOIN_ALGO_HASH, resid^
    )
    assert_equal(_verdict(_agg_attr(rj^)), Int(_EAGER_NONE), "residual")
    var nk = LogicalPlan.join(_fact(), _dim(), List[String](), List[String](), JOIN_INNER)
    assert_equal(_verdict(_agg_attr(nk^)), Int(_EAGER_NONE), "no keys")


def test_aggregate_shape_gates() raises:
    """No aggregate, only COUNT(*), an input on both sides by name, a group
    key spanning both sides: each declines."""
    var none = LogicalPlan.aggregate(_gb1("dim_attr"), AggExprArray(), _join_fd(_fact(), _dim()))
    assert_equal(_verdict(none), Int(_EAGER_NONE), "no aggregates")
    var star = AggExprArray()
    star.append(agg_count())
    var cs = LogicalPlan.aggregate(_gb1("dim_attr"), star^, _join_fd(_fact(), _dim()))
    assert_equal(_verdict(cs), Int(_EAGER_NONE), "count(*) anchors no side")
    var dimm = LogicalPlan.scan(
        String("dimm.parquet"), SOURCE_PARQUET, _schema(_l2("dim_id", "measure"))
    )
    var amb = LogicalPlan.aggregate(_gb1("dim_id"), _sum_measure(), _join_fd(_fact(), dimm^))
    assert_equal(_verdict(amb), Int(_EAGER_NONE), "input name on both sides")
    var gb = ExprArray()
    gb.append(Expr.binary(BIN_ADD, Expr.col_ref("dim_attr"), Expr.col_ref("fk_id")))
    var span = LogicalPlan.aggregate(gb^, _sum_measure(), _join_fd(_fact(), _dim()))
    assert_equal(_verdict(span), Int(_EAGER_NONE), "group key spans both sides")


def test_pushed_side_must_be_a_reducible_leaf() raises:
    """S behind a Sort (left) or a Distinct (right) is not a single scan.
    Catches a leaf check that admits any subtree; Filter and Project over the
    scan stay admissible."""
    assert_equal(_verdict(_agg_attr(_join_fd(_sort(_fact()), _dim()))), Int(_EAGER_NONE))
    var nc: Optional[List[String]] = None
    var r = _agg_attr(_join_df(_dim(), LogicalPlan.distinct(nc^, _fact())))
    assert_equal(_verdict(r), Int(_EAGER_NONE))
    var pred = Expr.binary(BIN_GT, Expr.col_ref("measure"), _lit(0))
    var fp = LogicalPlan.filter(pred^, _plain_project(_fact(_big()), _l2("fk_id", "measure")))
    assert_equal(_verdict(_agg_attr(_join_fd(fp^, _dim(_mid())))), Int(_EAGER_LEFT))
    assert_false(_is_reducible_leaf(_join_fd(_fact(), _dim())))


def test_constant_group_key_is_side_agnostic() raises:
    """A literal group key names no column. Catches a gate that treats it as
    spanning both sides (both directions decline)."""
    var gb = ExprArray()
    gb.append(_lit(1))
    gb.append(Expr.col_ref("dim_attr"))
    var l = LogicalPlan.aggregate(gb^, _sum_measure(), _join_fd(_fact(), _dim()))
    assert_equal(_verdict(l), Int(_EAGER_LEFT))
    var gb2 = ExprArray()
    gb2.append(_lit(1))
    gb2.append(Expr.col_ref("dim_attr"))
    var r = LogicalPlan.aggregate(gb2^, _sum_measure(), _join_df(_dim(), _fact()))
    assert_equal(_verdict(r), Int(_EAGER_RIGHT))


def test_push_right_collision_guard() raises:
    """dimc(dim_id, shared) JOIN factc(fk_id, measure, shared), grouped by
    fk_id + shared: the join would rename the right `shared`. Catches a
    missing collision guard."""
    var dimc = LogicalPlan.scan(
        String("dimc.parquet"), SOURCE_PARQUET, _schema(_l2("dim_id", "shared"))
    )
    var factc = LogicalPlan.scan(
        String("factc.parquet"), SOURCE_PARQUET, _schema(_l3("fk_id", "measure", "shared"))
    )
    var gb = ExprArray()
    gb.append(Expr.binary(BIN_ADD, Expr.col_ref("fk_id"), Expr.col_ref("shared")))
    var p = LogicalPlan.aggregate(gb^, _sum_measure(), _join_df(dimc^, factc^))
    assert_equal(_verdict(p), Int(_EAGER_NONE))


# -----------------------------------------------------------------------------
# the rewritten tree
# -----------------------------------------------------------------------------


def test_partial_aliases_and_merge_functions() raises:
    """SUM/COUNT/MIN/MAX partials are `__eager_<op>_<name>`; the merge of
    COUNT is SUM, the others keep their op, and an INNER COUNT merge reads the
    partial directly. Catches a swapped op tag or merge function."""
    var aggs = AggExprArray()
    aggs.append(agg_sum(col("measure")).alias("total"))
    aggs.append(agg_count(col("measure")).alias("n"))
    aggs.append(agg_min(col("measure")).alias("lo"))
    aggs.append(agg_max(col("measure")).alias("hi"))
    var plan = LogicalPlan.aggregate(_gb1("dim_attr"), aggs^, _join_fd(_fact(), _dim()))
    var out = eager_aggregate_pushdown(plan^)
    ref partial = out._aggregate.value()[].child[]._join.value()[].left[]._aggregate.value()[].agg_exprs
    assert_equal(partial[0].alias_name.value(), String("__eager_sum_total"))
    assert_equal(partial[1].alias_name.value(), String("__eager_count_n"))
    assert_equal(partial[2].alias_name.value(), String("__eager_min_lo"))
    assert_equal(partial[3].alias_name.value(), String("__eager_max_hi"))
    ref merge = out._aggregate.value()[].agg_exprs
    assert_equal(Int(merge[0].func), Int(AGG_SUM))
    assert_equal(Int(merge[1].func), Int(AGG_SUM))
    assert_equal(Int(merge[2].func), Int(AGG_MIN))
    assert_equal(Int(merge[3].func), Int(AGG_MAX))
    assert_equal(Int(merge[1].child.value().tag), Int(EXPR_COL_REF))
    assert_equal(merge[1].alias_name.value(), String("n"))


def test_left_join_count_merge_coalesces_and_sum_does_not() raises:
    """dim LEFT JOIN fact: the merged COUNT maps a NULL partial to 0, a merged
    SUM does not. Catches a missing coalesce (the q13 zero bin disappears) or
    one applied to SUM."""
    var aggs = AggExprArray()
    aggs.append(agg_count(col("measure")).alias("cnt"))
    aggs.append(agg_sum(col("measure")).alias("total"))
    var plan = LogicalPlan.aggregate(
        _gb1("dim_id"), aggs^, _join_df(_dim(_mid()), _fact(_big()), JOIN_LEFT)
    )
    var out = eager_aggregate_pushdown(plan^)
    ref merge = out._aggregate.value()[].agg_exprs
    assert_equal(Int(merge[0].func), Int(AGG_SUM))
    assert_equal(Int(merge[0].child.value().tag), Int(EXPR_WHEN))
    assert_equal(Int(merge[1].child.value().tag), Int(EXPR_COL_REF))
    ref j = out._aggregate.value()[].child[]
    assert_equal(Int(j._join.value()[].join_type), Int(JOIN_LEFT))
    assert_equal(Int(j._join.value()[].right[].tag), Int(PLAN_AGGREGATE))


def test_partial_group_by_is_s_keys_plus_join_keys() raises:
    """Push left with keys [dim_attr (other side), measure+0 (S, computed),
    1 (constant)]: the partial groups by [measure+0, fk_id]. Catches a partial
    group-by that takes the other side's key, drops the computed S key, or
    skips the join key."""
    var gb = ExprArray()
    gb.append(Expr.col_ref("dim_attr"))
    gb.append(Expr.binary(BIN_ADD, Expr.col_ref("measure"), _lit(0)))
    gb.append(_lit(1))
    var plan = LogicalPlan.aggregate(gb^, _sum_measure(), _join_fd(_fact(), _dim()))
    var out = eager_aggregate_pushdown(plan^)
    assert_equal(len(out._aggregate.value()[].group_by), 3, "merge keeps every key")
    ref partial = out._aggregate.value()[].child[]._join.value()[].left[]._aggregate.value()[]
    assert_equal(len(partial.group_by), 2)
    assert_equal(partial.group_by[1].col_ref_name(), String("fk_id"))


def test_join_key_already_grouped_is_not_repeated() raises:
    """Push right grouped by fk_id (the S join key itself): the partial groups
    by [fk_id] once. Catches a dedup that appends the key again."""
    var plan = LogicalPlan.aggregate(_gb1("fk_id"), _sum_measure(), _join_df(_dim(), _fact()))
    var out = eager_aggregate_pushdown(plan^)
    ref j = out._aggregate.value()[].child[]
    assert_equal(Int(j._join.value()[].left[].tag), Int(PLAN_SCAN))
    ref partial = j._join.value()[].right[]._aggregate.value()[]
    assert_equal(len(partial.group_by), 1)
    assert_equal(partial.group_by[0].col_ref_name(), String("fk_id"))


def test_rewrite_keeps_join_keys_type_and_hint() raises:
    """Catches a rebuilt join that loses its keys or algorithm hint."""
    var j = LogicalPlan.join(_fact(), _dim(), _l1("fk_id"), _l1("dim_id"), JOIN_INNER, JOIN_ALGO_HASH)
    var out = eager_aggregate_pushdown(_agg_attr(j^))
    ref jd = out._aggregate.value()[].child[]._join.value()[]
    assert_equal(jd.left_on[0], String("fk_id"))
    assert_equal(jd.right_on[0], String("dim_id"))
    assert_equal(Int(jd.join_type), Int(JOIN_INNER))
    assert_equal(Int(jd.algo_hint), Int(JOIN_ALGO_HASH))


# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------


def test_op_tags_and_input_less_partials() raises:
    """Catches an op-tag ladder that confuses two ops or lacks the fallback,
    and a partial builder that invents a child for COUNT(*)."""
    assert_equal(_eager_op_tag(AGG_SUM), String("sum"))
    assert_equal(_eager_op_tag(AGG_COUNT), String("count"))
    assert_equal(_eager_op_tag(AGG_MIN), String("min"))
    assert_equal(_eager_op_tag(AGG_MAX), String("max"))
    assert_equal(_eager_op_tag(AGG_MEAN), String("agg"))
    var aggs = AggExprArray()
    aggs.append(agg_count().alias("c"))
    var partials = AggExprArray()
    var merges = AggExprArray()
    _build_eager_partial_and_merge(aggs, True, partials, merges)
    assert_false(Bool(partials[0].child))
    assert_equal(partials[0].alias_name.value(), String("__eager_count_c"))
    assert_equal(Int(merges[0].child.value().tag), Int(EXPR_WHEN))


def test_fireable_join_and_narrowing_project_predicates() raises:
    """Catches predicates that admit a non-join, a SEMI join, a residual, a
    non-project, an empty project or a computed column."""
    assert_false(_is_fireable_join(_fact()))
    assert_false(_is_fireable_join(_join_fd(_fact(), _dim(), JOIN_SEMI)))
    var resid: Optional[OwnedPointer[Expr]] = OwnedPointer(
        Expr.binary(BIN_GT, Expr.col_ref("measure"), _lit(0))
    )
    var rj = LogicalPlan.join(
        _fact(), _dim(), _l1("fk_id"), _l1("dim_id"), JOIN_INNER, JOIN_ALGO_HASH, resid^
    )
    assert_false(_is_fireable_join(rj))
    assert_true(_is_fireable_join(_join_fd(_fact(), _dim(), JOIN_LEFT)))
    assert_false(_is_pure_narrowing_project(_fact()))
    assert_false(_is_pure_narrowing_project(LogicalPlan.project(ExprArray(), _fact())))
    var ex = ExprArray()
    ex.append(Expr.alias(Expr.binary(BIN_ADD, Expr.col_ref("measure"), _lit(1)), "m1"))
    assert_false(_is_pure_narrowing_project(LogicalPlan.project(ex^, _fact())))
    assert_true(_is_pure_narrowing_project(_plain_project(_fact(), _l1("measure"))))


# -----------------------------------------------------------------------------
# the walk
# -----------------------------------------------------------------------------


def test_walk_fires_below_every_wrapper_and_keeps_its_fields() raises:
    """Catches a wrapper arm that does not recurse, or rebuilds without its
    own fields (predicate, exprs, sort direction and NULL placement, limit
    offset, distinct columns, TopN n)."""
    var pred = Expr.binary(BIN_GT, Expr.col_ref("total"), _lit(0))
    var f = eager_aggregate_pushdown(LogicalPlan.filter(pred^, _fire_left()))
    assert_equal(Int(f.tag), Int(PLAN_FILTER))
    assert_equal(_partial_left(f._filter.value()[].child[]), Int(PLAN_AGGREGATE))

    var p = eager_aggregate_pushdown(_plain_project(_fire_left(), _l1("total")))
    assert_equal(Int(p.tag), Int(PLAN_PROJECT))
    assert_equal(p._project.value()[].exprs[0].col_ref_name(), String("total"))
    assert_equal(_partial_left(p._project.value()[].child[]), Int(PLAN_AGGREGATE))

    var s = eager_aggregate_pushdown(_sort(_fire_left()))
    assert_true(s._sort.value()[].descending[0])
    assert_true(s._sort.value()[].nulls_first[0])
    assert_equal(_partial_left(s._sort.value()[].child[]), Int(PLAN_AGGREGATE))

    var l = eager_aggregate_pushdown(LogicalPlan.limit(9, _fire_left(), offset=3))
    assert_equal(l._limit.value()[].n, 9)
    assert_equal(l._limit.value()[].offset, 3)
    assert_equal(_partial_left(l._limit.value()[].child[]), Int(PLAN_AGGREGATE))

    var d = eager_aggregate_pushdown(LogicalPlan.distinct(Optional(_l1("dim_attr")), _fire_left()))
    assert_equal(d._distinct.value()[].columns.value()[0], String("dim_attr"))
    assert_equal(_partial_left(d._distinct.value()[].child[]), Int(PLAN_AGGREGATE))
    var nc: Optional[List[String]] = None
    var d2 = eager_aggregate_pushdown(LogicalPlan.distinct(nc^, _fire_left()))
    assert_false(Bool(d2._distinct.value()[].columns))

    var dd = List[Bool]()
    dd.append(False)
    var nf = List[Bool]()
    nf.append(True)
    var t = eager_aggregate_pushdown(
        LogicalPlan.topn(_l1("dim_attr"), dd^, 6, _fire_left(), Optional(nf^))
    )
    assert_equal(t._topn.value()[].n, 6)
    assert_true(t._topn.value()[].nulls_first[0])
    assert_equal(_partial_left(t._topn.value()[].child[]), Int(PLAN_AGGREGATE))


def test_walk_through_a_join_keeps_residual_and_hint() raises:
    """Catches a Join arm that drops the residual or the hint, or recurses
    into one child only."""
    var resid: Optional[OwnedPointer[Expr]] = OwnedPointer(
        Expr.binary(BIN_GT, Expr.col_ref("total"), _lit(0))
    )
    var j = LogicalPlan.join(
        _fire_left(), _fire_left(), _l1("dim_attr"), _l1("dim_attr"), JOIN_INNER,
        JOIN_ALGO_HASH, resid^,
    )
    var out = eager_aggregate_pushdown(j^)
    ref jd = out._join.value()[]
    assert_true(jd.has_residual())
    assert_equal(Int(jd.algo_hint), Int(JOIN_ALGO_HASH))
    assert_equal(_partial_left(jd.left[]), Int(PLAN_AGGREGATE))
    assert_equal(_partial_left(jd.right[]), Int(PLAN_AGGREGATE))
    var plain = eager_aggregate_pushdown(
        LogicalPlan.join(_fire_left(), _dim(), _l1("dim_attr"), _l1("dim_id"), JOIN_INNER)
    )
    assert_false(plain._join.value()[].has_residual())


def test_walk_declines_rebuild_the_aggregate_unchanged() raises:
    """A declined join, a declined peel, a computed project and a scan child
    leave the aggregate over the same child kind, with COUNT(*) and an
    unaliased SUM keeping their output names. Catches a fall-through that
    drops the peeled Project, or a copy that loses a child or alias."""
    var small = _agg_attr(_join_fd(_fact(Optional[Int](1000)), _dim()))
    var a = eager_aggregate_pushdown(small^)
    assert_equal(Int(a._aggregate.value()[].child[].tag), Int(PLAN_JOIN))
    assert_equal(_partial_left(a), Int(PLAN_SCAN))

    var proj = _plain_project(
        _join_fd(_fact(Optional[Int](1000)), _dim()), _l2("measure", "dim_attr")
    )
    var b = eager_aggregate_pushdown(_agg_attr(proj^))
    assert_equal(Int(b._aggregate.value()[].child[].tag), Int(PLAN_PROJECT), "peel declined")

    var ex = ExprArray()
    ex.append(Expr.col_ref("dim_attr"))
    ex.append(Expr.alias(Expr.binary(BIN_ADD, Expr.col_ref("measure"), _lit(0)), "measure"))
    var cproj = LogicalPlan.project(ex^, _join_fd(_fact(), _dim()))
    var c = eager_aggregate_pushdown(_agg_attr(cproj^))
    assert_equal(Int(c._aggregate.value()[].child[].tag), Int(PLAN_PROJECT), "computed: no peel")

    var aggs = AggExprArray()
    aggs.append(agg_count())
    aggs.append(agg_sum(col("measure")))
    var over_scan = LogicalPlan.aggregate(_gb1("fk_id"), aggs^, _fact())
    var names_before = String(over_scan.output_schema.field_name(1)) + "," + over_scan.output_schema.field_name(2)
    var d = eager_aggregate_pushdown(over_scan^)
    assert_equal(Int(d._aggregate.value()[].child[].tag), Int(PLAN_SCAN))
    assert_false(Bool(d._aggregate.value()[].agg_exprs[0].child), "count(*) stays input-less")
    assert_true(Bool(d._aggregate.value()[].agg_exprs[1].child), "sum keeps its input")
    assert_false(Bool(d._aggregate.value()[].agg_exprs[1].alias_name), "no alias invented")
    assert_equal(
        String(d.output_schema.field_name(1)) + "," + d.output_schema.field_name(2), names_before
    )

    var leaf = eager_aggregate_pushdown(_fact())
    assert_equal(Int(leaf.tag), Int(PLAN_SCAN))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
