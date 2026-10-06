"""The arms of `plan_group_estimate` that `test_plan_group_estimate` does not
reach: every plan node the row bound and the key walk pass through, the
statistics shapes that carry no usable signal, the join tie-breaks, the
DISTINCT entry point, and the saturation helper.

`test_plan_group_estimate` proves the estimator's headline rules (all or
nothing, the resolution-time row cap, the provenance ordering) on AGGREGATE
over SCAN, PROJECT, AGGREGATE and JOIN. This file proves the rest of the walk,
one arm per test, each with the mutant it catches named in its docstring.
"""

from std.memory import OwnedPointer
from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_GT
from komira_plan_expr.partition_expr import PartitionExpr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    AsofTolerance,
    ASOF_BACKWARD,
    JOIN_INNER,
    PLAN_AGGREGATE,
    PLAN_ASOF_JOIN,
    PLAN_DISTINCT,
    PLAN_FILTER,
    PLAN_JOIN,
    PLAN_LIMIT,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_PROJECT,
    PLAN_SCAN,
    PLAN_SORT,
    PLAN_TOPN,
    SOURCE_BINDING,
    SOURCE_PARQUET,
)
from komira_plan_stats.table_stats import (
    ColumnStats,
    TableStats,
    STATS_SOURCE_PARQUET_METADATA,
)

from komira_dispatch_agg_exec.plan_group_estimate import (
    GROUP_EST_PROV_DCSUM,
    GROUP_EST_PROV_DOMAIN,
    GROUP_EST_PROV_HLL,
    GROUP_EST_PROV_NONE,
    GROUP_EST_WHY_COMPUTED_KEY,
    GROUP_EST_WHY_NO_COLUMN,
    GROUP_EST_WHY_NO_FOOTER_SOURCE,
    GROUP_EST_WHY_NO_SIGNAL,
    GROUP_EST_WHY_NO_STATS,
    GROUP_EST_WHY_OK,
    GROUP_EST_WHY_UNWALKABLE,
    GroupEstimate,
    _saturating_mul,
    _tighter,
    estimate_group_count,
    estimate_groups_for_distinct,
    group_est_why_name,
    plan_row_upper_bound,
)


# =============================================================================
# Fixtures
# =============================================================================


def _int_schema(var names: List[String]) -> Schema:
    var b = SchemaBuilder()
    for i in range(len(names)):
        b.add_field(Field(names[i], ArrowType.INT64, False))
    return b.build()


def _col_stats(
    ndv: Optional[Int], var lo: Optional[ScalarValue], var hi: Optional[ScalarValue]
) -> ColumnStats:
    var dc: Optional[Int] = None
    if ndv:
        dc = Optional[Int](ndv.value())
    return ColumnStats(dc^, lo^, hi^, None, None)


def _scan(
    name: String,
    var cs: ColumnStats,
    stats_rows: Int,
    row_count: Optional[Int],
) -> LogicalPlan:
    """A one-column parquet scan of `name` whose `TableStats` holds `cs` and
    `stats_rows`, with `row_count` as the scan's own row count (or none)."""
    var names = List[String]()
    names.append(name)
    var cols = List[ColumnStats]()
    cols.append(cs^)
    var stats = TableStats(
        stats_rows, names.copy(), cols^, STATS_SOURCE_PARQUET_METADATA, List[Bool]()
    )
    return LogicalPlan.scan(
        String("t.parquet"),
        SOURCE_PARQUET,
        _int_schema(names^),
        None,
        None,
        row_count,
        Optional[TableStats](stats^),
    )


def _ndv_scan(name: String, ndv: Int, rows: Int) -> LogicalPlan:
    """A scan whose stats give `name` a distinct count of `ndv` over `rows`."""
    return _scan(name, _col_stats(Optional[Int](ndv), None, None), rows, Optional[Int](rows))


def _domain_scan(
    name: String, var lo: ScalarValue, var hi: ScalarValue, stats_rows: Int
) -> LogicalPlan:
    """A scan whose stats give `name` only a min/max, and no scan row count."""
    return _scan(
        name,
        _col_stats(None, Optional[ScalarValue](lo^), Optional[ScalarValue](hi^)),
        stats_rows,
        None,
    )


def _group_by(name: String, var child: LogicalPlan) -> LogicalPlan:
    var gb = ExprArray()
    gb.append(Expr.col_ref(name))
    var ax = AggExprArray()
    ax.append(AggExpr(AGG_COUNT, Optional[Expr](), None))
    return LogicalPlan.aggregate(gb^, ax^, child^)


def _keys(a: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    return out^


def _desc() -> List[Bool]:
    var out = List[Bool]()
    out.append(False)
    return out^


def _empty() -> Schema:
    var b = SchemaBuilder()
    return b.build()


# =============================================================================
# plan_row_upper_bound: every arm
# =============================================================================


def test_row_bound_falls_back_to_the_stats_row_count() raises:
    """A scan with no row count of its own is bounded by its `TableStats` row
    count; a stats row count of 0 is no bound.
    MUTANT: drop the `rc > 0` guard and the second scan reports a bound of 0,
    which would clamp every estimate over it to one group."""
    var with_rows = _domain_scan(
        String("k"), ScalarValue.from_int(1), ScalarValue.from_int(9), 7_000
    )
    var b = plan_row_upper_bound(with_rows)
    assert_true(Bool(b))
    assert_equal(b.value(), 7_000)
    var zero_rows = _domain_scan(
        String("k"), ScalarValue.from_int(1), ScalarValue.from_int(9), 0
    )
    assert_false(Bool(plan_row_upper_bound(zero_rows)))


def test_row_bound_passes_through_sort_distinct_and_partition_by() raises:
    """SORT, DISTINCT and PARTITION BY never add rows, so the child's bound is
    theirs.
    MUTANT: any of the three arms returning None (or falling to the end)
    turns its assertion red."""
    var s = LogicalPlan.sort(_keys(String("k")), _desc(), _ndv_scan(String("k"), 5, 300))
    assert_equal(plan_row_upper_bound(s).value(), 300)
    var d = LogicalPlan.distinct(None, _ndv_scan(String("k"), 5, 301))
    assert_equal(plan_row_upper_bound(d).value(), 301)
    var p = LogicalPlan.partition_by(
        _keys(String("k")),
        _keys(String("k")),
        _desc(),
        List[PartitionExpr](),
        _ndv_scan(String("k"), 5, 302),
    )
    assert_equal(plan_row_upper_bound(p).value(), 302)


def test_row_bound_of_limit_and_topn_is_the_smaller_side() raises:
    """LIMIT n and TOP n are bounded by min(n, child bound), and by n alone
    when the child has no bound.
    MUTANT: return `n` unconditionally and the 40-row child under LIMIT 100
    reports 100; return the child unconditionally and the unbounded child
    reports nothing."""
    var small = LogicalPlan.limit(100, _ndv_scan(String("k"), 5, 40))
    assert_equal(plan_row_upper_bound(small).value(), 40)
    var big = LogicalPlan.limit(100, _ndv_scan(String("k"), 5, 4_000))
    assert_equal(plan_row_upper_bound(big).value(), 100)
    var unbounded = LogicalPlan.limit(
        100, LogicalPlan.scan(String("x.parquet"), SOURCE_PARQUET, _int_schema(_keys(String("k"))))
    )
    assert_equal(plan_row_upper_bound(unbounded).value(), 100)

    var t_small = LogicalPlan.topn(_keys(String("k")), _desc(), 100, _ndv_scan(String("k"), 5, 40))
    assert_equal(plan_row_upper_bound(t_small).value(), 40)
    var t_big = LogicalPlan.topn(_keys(String("k")), _desc(), 100, _ndv_scan(String("k"), 5, 4_000))
    assert_equal(plan_row_upper_bound(t_big).value(), 100)


def test_row_bound_gives_up_on_a_partition_topn() raises:
    """A per-partition N over an unknown partition count bounds nothing.
    MUTANT: bound it by `k` and this reports 3."""
    var pt = LogicalPlan.partition_topn(
        _keys(String("k")), _keys(String("k")), _desc(), 3, _ndv_scan(String("k"), 5, 300)
    )
    assert_false(Bool(plan_row_upper_bound(pt)))


def test_a_node_without_its_data_has_no_bound_and_no_estimate() raises:
    """Each walk checks the tag AND the variant payload. A node whose payload
    is absent (the bare constructor) is not walked: no bound, no key
    resolution, no estimate, and no crash.
    MUTANT: drop the payload check of any arm and the walk dereferences an
    empty Optional (the test aborts)."""
    var tags = List[UInt8]()
    tags.append(PLAN_SCAN)
    tags.append(PLAN_FILTER)
    tags.append(PLAN_PROJECT)
    tags.append(PLAN_SORT)
    tags.append(PLAN_DISTINCT)
    tags.append(PLAN_AGGREGATE)
    tags.append(PLAN_PARTITION_BY)
    tags.append(PLAN_LIMIT)
    tags.append(PLAN_TOPN)
    tags.append(PLAN_PARTITION_TOPN)
    tags.append(PLAN_JOIN)
    tags.append(PLAN_ASOF_JOIN)
    for i in range(len(tags)):
        var bare = LogicalPlan(tags[i], _int_schema(_keys(String("k"))))
        assert_false(Bool(plan_row_upper_bound(bare)))
        var est = estimate_group_count(bare)
        assert_false(est.is_known())
        assert_equal(est.why, GROUP_EST_WHY_UNWALKABLE)
        var over = estimate_group_count(_group_by(String("k"), bare^))
        assert_false(over.is_known())
        assert_equal(over.why, GROUP_EST_WHY_UNWALKABLE)


# =============================================================================
# _ndv_from_scan_stats: the shapes with no usable signal, and no row cap
# =============================================================================


def test_no_row_cap_leaves_the_distinct_count_and_the_domain_alone() raises:
    """With a stats row count of 0 there is nothing to cap at: the distinct
    count and the domain span are reported as they are.
    MUTANT: cap at `row_cap` without the `row_cap > 0` guard and both report
    0, which is not even a group count."""
    var dc_scan = _scan(
        String("k"), _col_stats(Optional[Int](77), None, None), 0, Optional[Int](1_000)
    )
    var e1 = estimate_group_count(_group_by(String("k"), dc_scan^))
    assert_equal(e1.groups, 77)
    assert_equal(e1.provenance, GROUP_EST_PROV_DCSUM)
    var dom = _domain_scan(
        String("k"), ScalarValue.from_int(10), ScalarValue.from_int(49), 0
    )
    var e2 = estimate_group_count(_group_by(String("k"), dom^))
    assert_equal(e2.groups, 40)
    assert_equal(e2.provenance, GROUP_EST_PROV_DOMAIN)


def test_a_half_domain_or_a_float_domain_is_no_signal() raises:
    """A min without a max, or a min/max that is not an integer on either
    side, says nothing about a distinct count.
    MUTANT: test only `min_value` (or only the min's type) and one of the
    three columns resolves to a made-up span."""
    var half = _scan(
        String("k"),
        _col_stats(None, Optional[ScalarValue](ScalarValue.from_int(1)), None),
        100,
        Optional[Int](100),
    )
    assert_equal(estimate_group_count(_group_by(String("k"), half^)).why, GROUP_EST_WHY_NO_SIGNAL)
    var float_lo = _domain_scan(
        String("k"), ScalarValue.from_float(1.5), ScalarValue.from_int(9), 100
    )
    assert_equal(
        estimate_group_count(_group_by(String("k"), float_lo^)).why, GROUP_EST_WHY_NO_SIGNAL
    )
    var float_hi = _domain_scan(
        String("k"), ScalarValue.from_int(1), ScalarValue.from_float(9.5), 100
    )
    assert_equal(
        estimate_group_count(_group_by(String("k"), float_hi^)).why, GROUP_EST_WHY_NO_SIGNAL
    )


def test_an_inverted_or_overflowing_domain_is_no_signal() raises:
    """max < min is a corrupt statistic, and the full Int64 range has a span
    that does not fit an Int (it wraps to 0). Neither is a group count.
    The two checks overlap on a small inverted domain (10..5 gives a span of
    -4, which `span < 1` also refuses), so the inverted case is also tested at
    the extremes: min = Int64.MAX, max = Int64.MIN wraps to a span of 2.
    MUTANT: drop the `hi < lo` check and the extreme inverted domain reports
    2 groups; drop the `span < 1` check and the full range reports 0 groups
    as a resolved estimate."""
    var inverted = _domain_scan(
        String("k"), ScalarValue.from_int(10), ScalarValue.from_int(5), 100
    )
    var e1 = estimate_group_count(_group_by(String("k"), inverted^))
    assert_false(e1.is_known())
    assert_equal(e1.why, GROUP_EST_WHY_NO_SIGNAL)
    var wrapped = _domain_scan(
        String("k"), ScalarValue.from_int64(Int64.MAX), ScalarValue.from_int64(Int64.MIN), 0
    )
    var e3 = estimate_group_count(_group_by(String("k"), wrapped^))
    assert_false(e3.is_known(), "an inverted domain wrapped into a span")
    assert_equal(e3.why, GROUP_EST_WHY_NO_SIGNAL)
    var full = _domain_scan(
        String("k"), ScalarValue.from_int64(Int64.MIN), ScalarValue.from_int64(Int64.MAX), 0
    )
    var e2 = estimate_group_count(_group_by(String("k"), full^))
    assert_false(e2.is_known())
    assert_equal(e2.why, GROUP_EST_WHY_NO_SIGNAL)


# =============================================================================
# _project_source_name and _resolve_key_ndv: every pass-through node
# =============================================================================


def test_a_bare_column_in_a_projection_resolves_and_a_bare_expression_does_not() raises:
    """A projection lists `other` (a plain column), `k` (a plain column) and an
    unaliased computed expression. Grouping on `k` resolves past the first
    plain column to the second; grouping on a name no expression produces is a
    computed key.
    MUTANT: return on the first plain column whatever its name and `k`
    resolves to `other`'s 9 distinct values; treat a bare expression as a
    match and the unknown name resolves."""
    var names = List[String]()
    names.append(String("other"))
    names.append(String("k"))
    var cols = List[ColumnStats]()
    cols.append(_col_stats(Optional[Int](9), None, None))
    cols.append(_col_stats(Optional[Int](33), None, None))
    var stats = TableStats(
        1_000, names.copy(), cols^, STATS_SOURCE_PARQUET_METADATA, List[Bool]()
    )
    var scan = LogicalPlan.scan(
        String("t.parquet"),
        SOURCE_PARQUET,
        _int_schema(names^),
        None,
        None,
        Optional[Int](1_000),
        Optional[TableStats](stats^),
    )
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("other")))
    exprs.append(Expr.col_ref(String("k")))
    exprs.append(
        Expr.binary(BIN_ADD, Expr.col_ref(String("k")), Expr.literal(ScalarValue.from_int(1)))
    )
    var proj = LogicalPlan.project(exprs^, scan^)
    var k = estimate_group_count(_group_by(String("k"), proj.copy()))
    assert_equal(k.groups, 33)
    var missing = estimate_group_count(_group_by(String("nowhere"), proj^))
    assert_false(missing.is_known())
    assert_equal(missing.why, GROUP_EST_WHY_COMPUTED_KEY)


def test_a_binding_source_without_stats_is_not_a_footer() raises:
    """A scan whose source is a binding (an engine-provided source, not a
    file) has no footer to describe it, like an in-memory one.
    MUTANT: check only SOURCE_IN_MEMORY and this reports `no_stats`, blaming
    the statistics pass for a plan-shape fact."""
    var scan = LogicalPlan.scan(String("bound"), SOURCE_PARQUET, _int_schema(_keys(String("k"))))
    # The binding arm of the source variant derives this field; the estimator
    # reads only the field, so set it directly.
    scan._scan.value()[].source_type = SOURCE_BINDING
    var est = estimate_group_count(_group_by(String("k"), scan^))
    assert_false(est.is_known())
    assert_equal(est.why, GROUP_EST_WHY_NO_FOOTER_SOURCE)


def _passes_the_key_walk(var node: LogicalPlan) raises:
    var est = estimate_group_count(_group_by(String("k"), node^))
    assert_true(est.is_known(), "a pass-through node stopped the key walk")
    assert_equal(est.groups, 25)
    assert_equal(est.why, GROUP_EST_WHY_OK)


def test_the_key_walk_passes_through_every_row_removing_node() raises:
    """FILTER, SORT, LIMIT, TOPN, DISTINCT and PARTITION BY keep or remove
    rows, so a key's distinct count below them is still a bound above them.
    Each wraps a 25-distinct-value scan of 1,000 rows (the LIMIT and TOPN keep
    500 rows, above 25, so the clamp does not hide the walk).
    MUTANT: any of the six arms missing turns its estimate unknown."""
    _passes_the_key_walk(
        LogicalPlan.filter(
            Expr.binary(BIN_GT, Expr.col_ref(String("k")), Expr.literal(ScalarValue.from_int(1))),
            _ndv_scan(String("k"), 25, 1_000),
        )
    )
    _passes_the_key_walk(
        LogicalPlan.sort(_keys(String("k")), _desc(), _ndv_scan(String("k"), 25, 1_000))
    )
    _passes_the_key_walk(LogicalPlan.limit(500, _ndv_scan(String("k"), 25, 1_000)))
    _passes_the_key_walk(
        LogicalPlan.topn(_keys(String("k")), _desc(), 500, _ndv_scan(String("k"), 25, 1_000))
    )
    _passes_the_key_walk(LogicalPlan.distinct(None, _ndv_scan(String("k"), 25, 1_000)))
    _passes_the_key_walk(
        LogicalPlan.partition_by(
            _keys(String("k")),
            _keys(String("k")),
            _desc(),
            List[PartitionExpr](),
            _ndv_scan(String("k"), 25, 1_000),
        )
    )


def test_an_asof_join_takes_the_tighter_side() raises:
    """An as-of join resolves the key on both sides and keeps the smaller
    bound, with that side's provenance, like an inner join.
    MUTANT: return the left side and this reports 80 instead of 12."""
    var l = _ndv_scan(String("k"), 80, 1_000)
    var r = _domain_scan(String("k"), ScalarValue.from_int(1), ScalarValue.from_int(12), 1_000)
    var aj = LogicalPlan.asof_join(
        l^, r^, List[String](), List[String](), String("k"), String("k"),
        ASOF_BACKWARD, AsofTolerance.none(),
    )
    var est = estimate_group_count(_group_by(String("k"), aj^))
    assert_equal(est.groups, 12)
    assert_equal(est.provenance, GROUP_EST_PROV_DOMAIN)


def test_a_union_is_unwalkable() raises:
    """A union's distinct set is the union of its inputs', which neither input
    bounds, so the walk stops with `unwalkable`.
    MUTANT: walk the first child and this reports 7."""
    var children = List[OwnedPointer[LogicalPlan]]()
    children.append(OwnedPointer(_ndv_scan(String("k"), 7, 100)))
    children.append(OwnedPointer(_ndv_scan(String("k"), 7, 100)))
    var u = LogicalPlan.union(children^, _int_schema(_keys(String("k"))))
    var est = estimate_group_count(_group_by(String("k"), u^))
    assert_false(est.is_known())
    assert_equal(est.why, GROUP_EST_WHY_UNWALKABLE)
    assert_equal(String(group_est_why_name(est.why)), String("unwalkable"))


def test_a_computed_key_of_a_lower_aggregate_is_not_matched() raises:
    """The lower aggregate groups by `k + 1`, not by a column. Grouping above
    it on `k` must not match that computed key as if it were `k`.
    MUTANT: drop the `is_col_ref` check and the walk reads a column name off
    a binary expression."""
    var gb = ExprArray()
    gb.append(
        Expr.binary(BIN_ADD, Expr.col_ref(String("k")), Expr.literal(ScalarValue.from_int(1)))
    )
    var ax = AggExprArray()
    ax.append(AggExpr(AGG_COUNT, Optional[Expr](), None))
    var inner = LogicalPlan.aggregate(gb^, ax^, _ndv_scan(String("k"), 25, 1_000))
    var est = estimate_group_count(_group_by(String("k"), inner^))
    assert_false(est.is_known())
    assert_equal(est.why, GROUP_EST_WHY_COMPUTED_KEY)


# =============================================================================
# _tighter: every combination
# =============================================================================


def test_tighter_covers_every_known_unknown_combination() raises:
    """Both unknown: the first side's reason unless it is `no_column`. One
    known: that one, whichever side. Both known: the smaller, ties to the
    first, with the winner's provenance.
    MUTANT: swap the `a.groups <= b.groups` comparison to `<` and the tie
    reports the second side's provenance; return `a` when only `b` is known
    and the unknown side wins."""
    var unk_signal = GroupEstimate(-1, GROUP_EST_PROV_NONE, GROUP_EST_WHY_NO_SIGNAL)
    var unk_stats = GroupEstimate(-1, GROUP_EST_PROV_NONE, GROUP_EST_WHY_NO_STATS)
    var unk_col = GroupEstimate(-1, GROUP_EST_PROV_NONE, GROUP_EST_WHY_NO_COLUMN)
    var k9_hll = GroupEstimate(9, GROUP_EST_PROV_HLL, GROUP_EST_WHY_OK)
    var k9_dom = GroupEstimate(9, GROUP_EST_PROV_DOMAIN, GROUP_EST_WHY_OK)
    var k4_dcs = GroupEstimate(4, GROUP_EST_PROV_DCSUM, GROUP_EST_WHY_OK)

    assert_equal(_tighter(unk_signal, unk_stats).why, GROUP_EST_WHY_NO_SIGNAL)
    assert_equal(_tighter(unk_col, unk_stats).why, GROUP_EST_WHY_NO_STATS)
    assert_false(_tighter(unk_signal, unk_stats).is_known())

    var right_known = _tighter(unk_signal, k9_dom)
    assert_equal(right_known.groups, 9)
    assert_equal(right_known.provenance, GROUP_EST_PROV_DOMAIN)
    var left_known = _tighter(k9_hll, unk_signal)
    assert_equal(left_known.groups, 9)
    assert_equal(left_known.provenance, GROUP_EST_PROV_HLL)

    var left_smaller = _tighter(k4_dcs, k9_hll)
    assert_equal(left_smaller.groups, 4)
    assert_equal(left_smaller.provenance, GROUP_EST_PROV_DCSUM)
    var tie = _tighter(k9_hll, k9_dom)
    assert_equal(tie.groups, 9)
    assert_equal(tie.provenance, GROUP_EST_PROV_HLL)


# =============================================================================
# _saturating_mul and _estimate_over's floor
# =============================================================================


def test_saturating_mul_saturates_and_ignores_a_non_positive_factor() raises:
    """A factor of 0 or less leaves the product alone; a product past the
    bound (or the fixed ceiling of 1,000,000,000 when there is no bound) is
    the bound.
    MUTANT: drop the `b <= 0` guard and `ceiling // 0` aborts; use the bound
    when there is none and the unbounded case aborts on an empty Optional."""
    assert_equal(_saturating_mul(5, 0, None), 5)
    assert_equal(_saturating_mul(5, -3, Optional[Int](100)), 5)
    assert_equal(_saturating_mul(100_000, 100_000, None), 1_000_000_000)
    assert_equal(_saturating_mul(30, 40, Optional[Int](1_000)), 1_000)
    assert_equal(_saturating_mul(30, 3, Optional[Int](1_000)), 90)
    assert_equal(_saturating_mul(30, 3, None), 90)


def test_an_estimate_is_never_below_one_group() raises:
    """LIMIT 0 bounds the rows at 0, so the saturated product is 0; the
    estimate floors it at one group rather than reporting zero.
    MUTANT: drop the `product < 1` floor and this reports 0 groups."""
    var lim = LogicalPlan.limit(0, _ndv_scan(String("k"), 5, 100))
    var est = estimate_group_count(_group_by(String("k"), lim^))
    assert_true(est.is_known())
    assert_equal(est.groups, 1)


# =============================================================================
# estimate_groups_for_distinct and estimate_group_count's dispatch
# =============================================================================


def _two_col_scan() -> LogicalPlan:
    var names = List[String]()
    names.append(String("a"))
    names.append(String("b"))
    var cols = List[ColumnStats]()
    cols.append(_col_stats(Optional[Int](6), None, None))
    cols.append(_col_stats(Optional[Int](7), None, None))
    var stats = TableStats(
        10_000, names.copy(), cols^, STATS_SOURCE_PARQUET_METADATA, List[Bool]()
    )
    return LogicalPlan.scan(
        String("t.parquet"),
        SOURCE_PARQUET,
        _int_schema(names^),
        None,
        None,
        Optional[Int](10_000),
        Optional[TableStats](stats^),
    )


def test_distinct_on_named_columns_multiplies_only_those() raises:
    """DISTINCT ON (b) has as many rows as `b` has distinct values.
    MUTANT: ignore `columns` and use the child schema and this reports 42."""
    var d = LogicalPlan.distinct(Optional[List[String]](_keys(String("b"))), _two_col_scan())
    var est = estimate_group_count(d)
    assert_equal(est.groups, 7)
    assert_equal(est.provenance, GROUP_EST_PROV_DCSUM)


def test_distinct_on_every_column_multiplies_all_of_them() raises:
    """DISTINCT with no column list is distinct over every child column.
    MUTANT: take only the first column and this reports 6."""
    var d = LogicalPlan.distinct(None, _two_col_scan())
    var est = estimate_group_count(d)
    assert_equal(est.groups, 42)
    assert_equal(est.why, GROUP_EST_WHY_OK)


def test_distinct_over_no_columns_is_unknown() raises:
    """A DISTINCT whose child has no columns has no key to estimate, and that
    is unknown, not one group.
    MUTANT: drop the `nc == 0` check and this reports the scalar answer, 1."""
    var child = LogicalPlan.scan(String("x.parquet"), SOURCE_PARQUET, _empty())
    var d = LogicalPlan.distinct(None, child^)
    var est = estimate_groups_for_distinct(d._distinct.value()[])
    assert_false(est.is_known())
    assert_equal(est.why, GROUP_EST_WHY_UNWALKABLE)


def test_a_node_that_is_neither_aggregate_nor_distinct_is_unknown() raises:
    """`estimate_group_count` answers only for AGGREGATE and DISTINCT.
    MUTANT: walk any plan as if it were its own key set and this scan
    resolves."""
    var est = estimate_group_count(_ndv_scan(String("k"), 5, 100))
    assert_false(est.is_known())
    assert_equal(est.groups, -1)
    assert_equal(est.provenance, GROUP_EST_PROV_NONE)
    assert_equal(est.why, GROUP_EST_WHY_UNWALKABLE)


def main() raises:
    test_row_bound_falls_back_to_the_stats_row_count()
    test_row_bound_passes_through_sort_distinct_and_partition_by()
    test_row_bound_of_limit_and_topn_is_the_smaller_side()
    test_row_bound_gives_up_on_a_partition_topn()
    test_a_node_without_its_data_has_no_bound_and_no_estimate()
    test_no_row_cap_leaves_the_distinct_count_and_the_domain_alone()
    test_a_half_domain_or_a_float_domain_is_no_signal()
    test_an_inverted_or_overflowing_domain_is_no_signal()
    test_a_bare_column_in_a_projection_resolves_and_a_bare_expression_does_not()
    test_a_binding_source_without_stats_is_not_a_footer()
    test_the_key_walk_passes_through_every_row_removing_node()
    test_an_asof_join_takes_the_tighter_side()
    test_a_union_is_unwalkable()
    test_a_computed_key_of_a_lower_aggregate_is_not_matched()
    test_tighter_covers_every_known_unknown_combination()
    test_saturating_mul_saturates_and_ignores_a_non_positive_factor()
    test_an_estimate_is_never_below_one_group()
    test_distinct_on_named_columns_multiplies_only_those()
    test_distinct_on_every_column_multiplies_all_of_them()
    test_distinct_over_no_columns_is_unknown()
    test_a_node_that_is_neither_aggregate_nor_distinct_is_unknown()
    print("All 21 plan_group_estimate walk tests passed.")
