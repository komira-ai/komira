# =============================================================================
# test_optimizer_scalar_broadcast_sites -- Filter(agg_fn) over Aggregate
# =============================================================================
#
# `scalar_broadcast_rewrite` finds `Filter(<pred with one agg_fn>,
# Aggregate(...))`, asks the dependency table for the inner Aggregate's batch
# and the reduced scalar, and once bound replaces the agg_fn with the literal
# and the Aggregate with an in-memory scan of the bound batch. These tests pin
# the request, the bind, the walk through Sort / Limit / Filter, the refusals,
# and every arm of the three expression walkers.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
)

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.record_batch import RecordBatch
from komira_collections.slab import Slab
from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    EXPR_LITERAL,
    EXPR_COL_REF,
    EXPR_AGG_FN,
    BIN_GT,
    BIN_EQ,
    BIN_AND,
    UN_NEGATE,
    STR_LIKE,
    MATH_SQRT,
    MATH2_POW,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.agg_expr import AggExpr, AGG_SUM, AGG_MAX, AGG_MIN
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    SOURCE_IN_MEMORY,
    PLAN_FILTER,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_SCAN,
    PLAN_AGGREGATE,
    PLAN_PROJECT,
)
from komira_scan_source.in_memory_source import InMemorySource

from komira_optimizer.optimizer_scalar_deps import (
    ScalarDepTable,
    DEP_SCALAR_BROADCAST,
)
from komira_optimizer.optimizer_scalar_broadcast import (
    scalar_broadcast_rewrite,
    ScalarBroadcastSite,
    _expr_has_agg_fn,
    _substitute_agg_fn,
    _resolve_child_col_name,
    _build_inner_sub_plan,
    _extract_single_agg_fn,
    _rewrite_scalar_broadcast_sites,
)


# =============================================================================
# Fixtures
# =============================================================================


def _sales() -> LogicalPlan:
    var b = SchemaBuilder()
    b.add_field(Field(String("g"), ArrowType.INT64, False))
    b.add_field(Field(String("v"), ArrowType.INT64, False))
    return LogicalPlan.scan(String("sales.parquet"), SOURCE_PARQUET, b.build())


def _per_group() -> LogicalPlan:
    """`SELECT g, sum(v) AS total FROM sales GROUP BY g`."""
    var gb = ExprArray()
    gb.append(Expr.col_ref(String("g")))
    var aggs = AggExprArray()
    aggs.append(AggExpr(AGG_SUM, Optional(Expr.col_ref(String("v"))), Optional(String("total"))))
    return LogicalPlan.aggregate(gb^, aggs^, _sales())


def _total() -> Expr:
    return Expr.col_ref(String("total"))


def _max_total() -> Expr:
    return Expr.agg_fn(AGG_MAX, _total())


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _gt(var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(BIN_GT, l^, r^)


def _site() -> LogicalPlan:
    """`Filter(total > max(total), per_group)`: the one shape that triggers."""
    return LogicalPlan.filter(_gt(_total(), _max_total()), _per_group())


def _out_schema() -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(String("g"), ArrowType.INT64, False))
    b.add_field(Field(String("total"), ArrowType.INT64, False))
    return b.build()


def _bound(v: Int) raises -> ScalarDepTable:
    var deps = ScalarDepTable()
    var src = InMemorySource.from_record_batch(RecordBatch.empty_from_schema(_out_schema()))
    deps.bind_broadcast(
        _per_group().structural_hash(), ScalarValue.from_int(v), src^,
        _out_schema(), String("cache0"),
    )
    return deps^


def _assert_folded(imm f: LogicalPlan, v: Int) raises:
    """`f` is Filter(total > <v>, Scan(in-memory, [g, total]))."""
    assert_equal(f.tag, PLAN_FILTER)
    ref pred = f.filter_data_ref().predicate
    assert_false(_expr_has_agg_fn(pred))
    assert_equal(pred.binary_right_ref().tag, EXPR_LITERAL)
    assert_equal(Int(pred.binary_right_ref().literal_value().int_val), v)
    ref scan = f.filter_data_ref().child[]
    assert_equal(scan.tag, PLAN_SCAN)
    assert_equal(Int(scan.scan_data_ref().source_type), Int(SOURCE_IN_MEMORY))
    assert_equal(scan.output_schema.num_columns(), 2)
    assert_equal(scan.output_schema.field_name(1), String("total"))


# =============================================================================
# `scalar_broadcast_rewrite`
# =============================================================================


def test_no_site_passes_through() raises:
    # A Filter over a scan and a Project are not sites. Catches: a rewrite or a
    # request with nothing to do.
    var pe = ExprArray()
    pe.append(Expr.col_ref(String("g")))
    var plan = LogicalPlan.project(
        pe^, LogicalPlan.filter(_gt(Expr.col_ref(String("v")), _lit(1)), _sales())
    )
    var before = plan.structural_hash()
    var deps = ScalarDepTable()
    var out = scalar_broadcast_rewrite(plan^, deps)
    assert_equal(out.structural_hash(), before)
    assert_equal(deps.num_requests(), 0)


def test_a_miss_requests_the_aggregate_with_its_op_and_column() raises:
    # Catches: a request without the (op, column) the caller needs for the
    # second, ungrouped execution; a key other than the Aggregate's hash; a
    # rewrite on a miss.
    var plan = _site()
    var before = plan.structural_hash()
    var deps = ScalarDepTable()
    var out = scalar_broadcast_rewrite(plan^, deps)
    assert_equal(out.structural_hash(), before)
    assert_equal(deps.num_requests(), 1)
    var h = _per_group().structural_hash()
    assert_equal(Int(deps.request_kind(0)), Int(DEP_SCALAR_BROADCAST))
    assert_equal(deps.request_key(0), h)
    assert_equal(Int(deps.request_op(0)), Int(AGG_MAX))
    assert_equal(deps.request_col(0), String("total"))
    assert_equal(deps.request_plan(0).structural_hash(), h)


def test_a_bound_site_folds_and_scans_the_bound_batch() raises:
    # Catches: the literal not substituted; the Aggregate re-emitted instead
    # of the in-memory scan of the bound batch (the group-by would run twice).
    var deps = _bound(42)
    var out = scalar_broadcast_rewrite(_site(), deps)
    assert_equal(deps.num_requests(), 0)
    _assert_folded(out, 42)


def test_the_walk_passes_through_limit_sort_and_filter() raises:
    # Limit(offset) -> Sort(NULLS FIRST) -> Filter(g > 0) -> site. Catches: an
    # arm dropped from the collector or the rewriter, a lost LIMIT offset, or
    # a lost explicit NULLS FIRST on the rebuilt Sort.
    var keys = List[String]()
    keys.append(String("g"))
    var desc = List[Bool]()
    desc.append(True)
    var nf = List[Bool]()
    nf.append(True)
    var f = LogicalPlan.filter(_gt(Expr.col_ref(String("g")), _lit(0)), _site())
    var s = LogicalPlan.sort(keys^, desc^, f^, Optional(nf^))
    var plan = LogicalPlan.limit(10, s^, offset=4)

    var miss = ScalarDepTable()
    _ = scalar_broadcast_rewrite(plan.copy(), miss)
    assert_equal(miss.num_requests(), 1)

    var deps = _bound(7)
    var out = scalar_broadcast_rewrite(plan^, deps)
    assert_equal(out.tag, PLAN_LIMIT)
    assert_equal(out.limit_data_ref().n, 10)
    assert_equal(out.limit_data_ref().offset, 4)
    ref so = out.limit_data_ref().child[]
    assert_equal(so.tag, PLAN_SORT)
    assert_true(so.sort_data_ref().nulls_first[0])
    assert_true(so.sort_data_ref().descending[0])
    ref fo = so.sort_data_ref().child[]
    assert_equal(fo.tag, PLAN_FILTER)
    assert_equal(fo.filter_data_ref().predicate.binary_left_ref().col_ref_name(), String("g"))
    _assert_folded(fo.filter_data_ref().child[], 7)


def test_a_filter_on_an_aggregate_without_an_agg_fn_is_not_a_site() raises:
    # Catches: a site recorded for any Filter(Aggregate), which would request
    # an execution the predicate never uses.
    var plan = LogicalPlan.filter(_gt(_total(), _lit(1)), _per_group())
    var before = plan.structural_hash()
    var deps = ScalarDepTable()
    var out = scalar_broadcast_rewrite(plan^, deps)
    assert_equal(out.structural_hash(), before)
    assert_equal(deps.num_requests(), 0)


def test_two_agg_fns_in_one_predicate_are_refused() raises:
    # Catches: folding only the first of two aggregates (the second would
    # reach the evaluator as an agg_fn).
    var pred = Expr.binary(
        BIN_AND, _gt(_total(), _max_total()), _gt(Expr.agg_fn(AGG_MIN, _total()), _lit(0))
    )
    var deps = ScalarDepTable()
    with assert_raises():
        _ = scalar_broadcast_rewrite(LogicalPlan.filter(pred^, _per_group()), deps)


def test_a_compound_agg_fn_child_is_refused() raises:
    # Catches: a broadcast of `max(total + 1)` under the name of a column it
    # is not.
    var pred = _gt(
        _total(),
        Expr.agg_fn(AGG_MAX, Expr.binary(BIN_EQ, _total(), _lit(1))),
    )
    var deps = ScalarDepTable()
    with assert_raises():
        _ = scalar_broadcast_rewrite(LogicalPlan.filter(pred^, _per_group()), deps)
    assert_equal(_resolve_child_col_name(_total()), String("total"))


# =============================================================================
# The expression walkers, called directly
# =============================================================================


def _when(var cond: Expr, var result: Expr, var default: Expr) -> Expr:
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(cond^, result^))
    return Expr.when(cases^, default^)


def test_has_agg_fn_sees_every_walked_container() raises:
    # Catches: an arm dropped from `_expr_has_agg_fn` (an aggregate under
    # that container is left in the plan unrewritten).
    var t = _total()
    assert_true(_expr_has_agg_fn(_max_total()))
    assert_true(_expr_has_agg_fn(_gt(_max_total(), _lit(1))))
    assert_true(_expr_has_agg_fn(_gt(_lit(1), _max_total())))
    assert_true(_expr_has_agg_fn(Expr.unary(UN_NEGATE, _max_total())))
    assert_true(_expr_has_agg_fn(Expr.cast(_max_total(), DType.float64)))
    assert_true(_expr_has_agg_fn(Expr.alias(_max_total(), String("m"))))
    assert_true(_expr_has_agg_fn(Expr.string_op(STR_LIKE, _max_total(), String("1%"))))
    assert_true(_expr_has_agg_fn(Expr.math_fn(MATH_SQRT, _max_total())))
    assert_true(_expr_has_agg_fn(Expr.math_fn2(MATH2_POW, _max_total(), _lit(2))))
    assert_true(_expr_has_agg_fn(Expr.math_fn2(MATH2_POW, _lit(2), _max_total())))
    assert_true(_expr_has_agg_fn(_when(_max_total(), _lit(1), _lit(0))))
    assert_true(_expr_has_agg_fn(_when(_lit(1), _max_total(), _lit(0))))
    assert_true(_expr_has_agg_fn(_when(_lit(1), _lit(0), _max_total())))
    # No aggregate anywhere: every arm answers False.
    assert_false(_expr_has_agg_fn(t))
    assert_false(_expr_has_agg_fn(_gt(_total(), _lit(1))))
    assert_false(_expr_has_agg_fn(Expr.math_fn2(MATH2_POW, _lit(2), _lit(3))))
    assert_false(_expr_has_agg_fn(_when(_lit(1), _lit(0), _lit(2))))


def _every_container(var inner: Expr) -> Expr:
    """`inner` nested under every container the walkers know, with plain
    leaves beside it: when(cond, result, default=pow(sqrt(like(alias(cast(
    -inner)))), 2))."""
    var e = Expr.unary(UN_NEGATE, inner^)
    e = Expr.cast(e^, DType.float64)
    e = Expr.alias(e^, String("m"))
    e = Expr.string_op(STR_LIKE, e^, String("1%"))
    e = Expr.math_fn(MATH_SQRT, e^)
    e = Expr.math_fn2(MATH2_POW, e^, _lit(2))
    return _when(_gt(_total(), _lit(0)), _total(), _gt(e^, _lit(0)))


def test_substitute_rebuilds_every_container_around_the_literal() raises:
    # Catches: an arm dropped from `_substitute_agg_fn` (the agg_fn survives
    # under it), a container rebuilt with the wrong op, pattern or name.
    var out = _substitute_agg_fn(_every_container(_max_total()), ScalarValue.from_int(9))
    assert_false(_expr_has_agg_fn(out))
    assert_equal(out.when_num_cases(), 1)
    assert_equal(out.when_case_result_ref(0).col_ref_name(), String("total"))
    ref pow2 = out.when_default_ref().binary_left_ref()
    assert_equal(Int(pow2.math_fn2_op()), Int(MATH2_POW))
    ref sq = pow2.math_fn2_left_ref()
    assert_equal(Int(sq.math_fn_op()), Int(MATH_SQRT))
    ref like = sq.math_fn_child_ref()
    assert_equal(like.string_op_pattern(), String("1%"))
    ref al = like.string_op_child_ref()
    assert_equal(al.alias_name(), String("m"))
    ref ca = al.alias_child_ref()
    assert_true(ca.cast_target() == DType.float64)
    ref neg = ca.cast_child_ref()
    assert_equal(Int(neg.unary_op()), Int(UN_NEGATE))
    assert_equal(neg.unary_child_ref().tag, EXPR_LITERAL)
    assert_equal(Int(neg.unary_child_ref().literal_value().int_val), 9)
    # A leaf is copied as built.
    assert_equal(_substitute_agg_fn(_total(), ScalarValue.from_int(9)).tag, EXPR_COL_REF)


def test_extract_walks_every_container_and_counts() raises:
    # Catches: an arm dropped from `_walk_for_agg_fn` (no agg found: raises),
    # a count that stops at the first hit (two aggs pass as one), and the
    # empty case not refused.
    var one = _extract_single_agg_fn(_every_container(_max_total()))
    assert_equal(Int(one[0]), Int(AGG_MAX))
    assert_equal(one[1], String("total"))
    with assert_raises():
        _ = _extract_single_agg_fn(_gt(_total(), _lit(1)))
    var two = Expr.math_fn2(
        MATH2_POW, _max_total(), Expr.agg_fn(AGG_MIN, _total())
    )
    with assert_raises():
        _ = _extract_single_agg_fn(two^)
    var in_when = _when(_max_total(), Expr.agg_fn(AGG_MIN, _total()), _lit(0))
    with assert_raises():
        _ = _extract_single_agg_fn(in_when^)


def test_the_inner_sub_plan_is_an_ungrouped_reduction() raises:
    # Catches: a reduction that keeps the group-by (N rows, not one), the
    # wrong op or column, or a child other than the original Aggregate.
    var inner = _per_group()
    var h = inner.structural_hash()
    var sub = _build_inner_sub_plan(inner^, AGG_MAX, String("total"))
    assert_equal(sub.tag, PLAN_AGGREGATE)
    ref ad = sub.aggregate_data_ref()
    assert_equal(len(ad.group_by), 0)
    assert_equal(len(ad.agg_exprs), 1)
    assert_equal(Int(ad.agg_exprs[0].func), Int(AGG_MAX))
    assert_equal(ad.agg_exprs[0].child.value().col_ref_name(), String("total"))
    assert_equal(ad.child[].structural_hash(), h)


def test_the_rewriter_recurses_under_a_non_site_filter_on_an_aggregate() raises:
    # `scalar_broadcast_rewrite` never reaches this arm (a Filter(Aggregate)
    # without an agg_fn ends the collection walk, so no site sits below it);
    # the rewriter still handles it. Catches: that arm dropping the predicate
    # or replacing the Aggregate.
    var plan = LogicalPlan.filter(_gt(_total(), _lit(1)), _per_group())
    var sites = Slab[ScalarBroadcastSite]()
    var next_idx = 0
    var out = _rewrite_scalar_broadcast_sites(
        plan^, sites, List[ScalarValue](), List[String](), Slab[Schema](),
        Slab[InMemorySource](), next_idx,
    )
    assert_equal(next_idx, 0)
    assert_equal(out.tag, PLAN_FILTER)
    assert_equal(out.filter_data_ref().child[].tag, PLAN_AGGREGATE)
    assert_equal(
        out.filter_data_ref().child[].structural_hash(), _per_group().structural_hash()
    )
    assert_equal(
        Int(out.filter_data_ref().predicate.binary_right_ref().literal_value().int_val), 1
    )
    # A node kind off the walk is returned as-is.
    var pe = ExprArray()
    pe.append(_total())
    var proj = LogicalPlan.project(pe^, _per_group())
    var ph = proj.structural_hash()
    var pout = _rewrite_scalar_broadcast_sites(
        proj^, sites, List[ScalarValue](), List[String](), Slab[Schema](),
        Slab[InMemorySource](), next_idx,
    )
    assert_equal(pout.tag, PLAN_PROJECT)
    assert_equal(pout.structural_hash(), ph)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
