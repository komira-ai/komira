"""PLAN-SIDE GROUP-CARDINALITY ESTIMATOR — the ACCURACY INSTRUMENT, and the
assertions that keep it from quietly becoming a producer.

⛔ WHAT THIS MODULE IS NOT. It does not write `AggregateData.estimated_groups`
and nothing routes on it. The gate it would otherwise feed is a DISJUNCTION
(`n_rows >= 100_000 OR group_est >= 5_000`), so an estimate can only widen
FLAT -> RADIX and never decline one; against measured per-cell deltas a perfect
oracle moves 2 of 82 cells, flips zero verdicts, and its one win still fails,
while a merely plausible one risks `tpch/q4` crossing 1.00. The consuming
decision is deliberately absent, so these tests assert the NUMBER and its
PROVENANCE, never a strategy.

⚠ THE PROVENANCE ASSERTIONS ARE THE LOAD-BEARING HALF. A predicted group count
is not one measurement, it is three with wildly different trustworthiness:

  `hll`     merged HyperLogLog registers — an honest distinct count. Requires a
            engine-specific footer extension; ZERO columns of
            the DuckDB-written TPC-H SF1 fixtures carry it.
  `dcsum`   standard-Parquet `distinct_count` SUMMED across row groups.
            OVER-COUNTS by roughly the row-group count — measured
            `o_orderpriority` 65 against a truth of 5 over 13 row groups,
            `l_shipmode` 343 against 7 over 49.
  `domain`  a bare integer min/max span. An UPPER BOUND, not an estimate —
            measured `o_orderkey` spanning 6,000,000 in a 1,500,000-row table.

A `pred` reported without its `prov` is not a measurement, so several tests
below exist purely to prove the tag cannot be laundered upward.

⚠ THE PRE-FIX ARM CANNOT COMPILE, so "it failed before" is not the evidence
here — the symbols are new. The falsification is MUTANT-directed instead: drop
the all-or-nothing rule and `test_one_unresolvable_key_poisons_the_whole_estimate`
goes red; drop the resolution-time row cap and
`test_a_wide_domain_is_capped_at_the_scans_own_row_count` goes red; check the
domain before the distinct count and `test_distinct_count_outranks_the_domain`
goes red; let a join hand back the other side's stronger tag and
`test_provenance_travels_with_the_value_that_won` goes red.
"""


from std.testing import assert_equal, assert_true, assert_false

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.plan.agg_expr import AggExpr, AGG_COUNT
from komira_core.plan.expr import Expr, BIN_ADD, BIN_GT
from komira_core.plan.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    PLAN_AGGREGATE,
    SOURCE_PARQUET,
    SOURCE_IN_MEMORY,
    JOIN_INNER,
)
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.table_stats import (
    ColumnStats,
    TableStats,
    STATS_SOURCE_PARQUET_METADATA,
)

from komira_compiler.plan_group_estimate import (
    GROUP_EST_WHY_OK,
    GROUP_EST_WHY_COMPUTED_KEY,
    GROUP_EST_WHY_NO_STATS,
    GROUP_EST_WHY_NO_COLUMN,
    GROUP_EST_WHY_NO_SIGNAL,
    GROUP_EST_WHY_UNWALKABLE,
    GROUP_EST_WHY_NO_FOOTER_SOURCE,
    group_est_why_name,
    GROUP_EST_PROV_NONE,
    GROUP_EST_PROV_HLL,
    GROUP_EST_PROV_DCSUM,
    GROUP_EST_PROV_DOMAIN,
    GroupEstimate,
    estimate_group_count,
    group_est_prov_name,
    plan_row_upper_bound,
)


# =============================================================================
# Fixtures
# =============================================================================


def _stats(
    row_count: Int,
    var names: List[String],
    var ndvs: List[Optional[Int]],
    var mins: List[Optional[Int]],
    var maxs: List[Optional[Int]],
    var from_hll: List[Bool] = List[Bool](),
) -> TableStats:
    """A `TableStats` with per-column NDV and (optionally) an INT min/max
    domain — the exact two signals `_ndv_from_scan_stats` reads, and nothing
    else, so a test cannot accidentally pass through a third channel."""
    var cols = List[ColumnStats]()
    for i in range(len(names)):
        var mn: Optional[ScalarValue] = None
        var mx: Optional[ScalarValue] = None
        if mins[i]:
            mn = Optional[ScalarValue](ScalarValue.from_int(mins[i].value()))
        if maxs[i]:
            mx = Optional[ScalarValue](ScalarValue.from_int(maxs[i].value()))
        var dc: Optional[Int] = None
        if ndvs[i]:
            dc = Optional[Int](ndvs[i].value())
        cols.append(ColumnStats(dc^, mn^, mx^, None, None))
    return TableStats(
        row_count, names^, cols^, STATS_SOURCE_PARQUET_METADATA, from_hll^
    )


def _scan_with_stats(
    path: String,
    var names: List[String],
    var stats: TableStats,
    row_count: Int,
) -> LogicalPlan:
    var b = SchemaBuilder()
    for i in range(len(names)):
        b.add_field(Field(names[i], ArrowType.INT64, False))
    return LogicalPlan.scan(
        path,
        SOURCE_PARQUET,
        b.build(),
        None,
        None,
        Optional[Int](row_count),
        Optional[TableStats](stats^),
    )


def _one_col_scan(
    name: String, ndv: Optional[Int], row_count: Int
) -> LogicalPlan:
    var names = List[String]()
    names.append(name)
    var ndvs = List[Optional[Int]]()
    ndvs.append(ndv)
    var mins = List[Optional[Int]]()
    mins.append(None)
    var maxs = List[Optional[Int]]()
    maxs.append(None)
    var names2 = List[String]()
    names2.append(name)
    return _scan_with_stats(
        String("t.parquet"),
        names2^,
        _stats(row_count, names^, ndvs^, mins^, maxs^),
        row_count,
    )


def _group_by_one(name: String, var child: LogicalPlan) -> LogicalPlan:
    var gb = ExprArray()
    gb.append(Expr.col_ref(name))
    var ax = AggExprArray()
    ax.append(
        AggExpr(AGG_COUNT, Optional[Expr](), None)
    )
    return LogicalPlan.aggregate(gb^, ax^, child^)


# =============================================================================
# 1. THE CORPUS CELLS the group arm was built for — the numbers, and the tags.
# =============================================================================


def test_q11_shape_resolves_above_the_group_floor() raises:
    """Q11: 31,680 rows / 29,818 groups. RADIX wins by 1.95 ms here and the
    rows arm declines it (31,680 < 100,000 min_rows), so this cell is only
    reachable through the group arm."""
    var plan = _group_by_one(
        String("ps_partkey"), _one_col_scan(String("ps_partkey"), 29_818, 31_680)
    )
    var est = estimate_group_count(plan)
    assert_true(est.is_known())
    assert_equal(est.groups, 29_818)
    # 5,000 is `_INMEM_AGG_RADIX_MIN_GROUPS_DEFAULT`. Compared as a plain band,
    # not by importing the constant: this package cannot see operators, and
    # ⛔ NOTHING ROUTES ON THIS — the comparison records where the number falls
    # relative to a threshold nothing feeds, which is the whole point of the
    # instrument.
    assert_true(est.groups >= 5_000)
    # ⚠ AND ON THE REAL FIXTURE THIS CELL DOES NOT RESOLVE THIS WAY AT ALL.
    # `ps_partkey` carries NO `distinct_count` in `partsupp.parquet` (measured
    # 7 row groups, none with the field), so in production it
    # reaches only the `domain` tier. The fixture supplies an NDV so the
    # ARITHMETIC is testable; `test_provenance_is_domain_when_only_minmax_
    # reaches` covers what actually happens.
    assert_equal(est.provenance, GROUP_EST_PROV_DCSUM)


def test_q4_shape_resolves_below_the_group_floor() raises:
    """Q4: 52,523 rows / 5 groups on `o_orderpriority`. RADIX LOSES 2.93 ms
    here. This is the cell that kills `estimate_cardinality`'s `child // 10`
    heuristic, which would say 5,252 and ADMIT the regression."""
    var plan = _group_by_one(
        String("o_orderpriority"),
        _one_col_scan(String("o_orderpriority"), 5, 52_523),
    )
    var est = estimate_group_count(plan)
    assert_true(est.is_known())
    assert_equal(est.groups, 5)
    assert_true(est.groups < 5_000)
    assert_equal(est.provenance, GROUP_EST_PROV_DCSUM)
    # The falsifier for the heuristic this module deliberately does NOT use.
    assert_true(
        52_523 // 10 >= 5_000,
        "the //10 heuristic no longer crosses the floor on q4 — if this "
        "fires, re-read the module header's argument, it may have gone stale",
    )


def test_q12_shape_resolves_below_the_group_floor() raises:
    """Q12: 30,988 rows / 2 groups on `l_shipmode`. RADIX loses 1.14 ms."""
    var plan = _group_by_one(
        String("l_shipmode"), _one_col_scan(String("l_shipmode"), 2, 30_988)
    )
    var est = estimate_group_count(plan)
    assert_true(est.is_known())
    assert_equal(est.groups, 2)
    assert_equal(est.provenance, GROUP_EST_PROV_DCSUM)


# =============================================================================
# 3. THE SAFETY CONTRACT — every way the estimator is allowed to give up.
# =============================================================================


def test_one_unresolvable_key_poisons_the_whole_estimate() raises:
    """ALL-OR-NOTHING. Two keys, one with NDV and one without: the answer is
    UNKNOWN, never the product of the half we understand.

    MUTANT: skip the unresolvable key instead of returning None and this
    returns 29,818 — a confident number for a cardinality that could be
    29,818 x anything. Over-confidence above the floor is the ONE failure
    direction that costs, because the consumer is an admission."""
    var names = List[String]()
    names.append(String("ps_partkey"))
    names.append(String("ps_comment"))
    var ndvs = List[Optional[Int]]()
    ndvs.append(Optional[Int](29_818))
    ndvs.append(None)  # a writer that emitted no distinct_count
    var mins = List[Optional[Int]]()
    mins.append(None)
    mins.append(None)
    var maxs = List[Optional[Int]]()
    maxs.append(None)
    maxs.append(None)
    var cols = List[String]()
    cols.append(String("ps_partkey"))
    cols.append(String("ps_comment"))
    var scan = _scan_with_stats(
        String("partsupp.parquet"),
        cols^,
        _stats(800_000, names^, ndvs^, mins^, maxs^),
        800_000,
    )
    var gb = ExprArray()
    gb.append(Expr.col_ref(String("ps_partkey")))
    gb.append(Expr.col_ref(String("ps_comment")))
    var ax = AggExprArray()
    ax.append(
        AggExpr(AGG_COUNT, Optional[Expr](), None)
    )
    var plan = LogicalPlan.aggregate(gb^, ax^, scan^)
    assert_false(estimate_group_count(plan).is_known(), "a partially-resolvable key set produced a number")


def test_a_stats_less_scan_produces_nothing() raises:
    """No `TableStats` at all — the common case for a CSV / in-memory / newly
    registered source. There is no default NDV to fall back to and there must
    never be one."""
    var b = SchemaBuilder()
    b.add_field(Field(String("k"), ArrowType.INT64, False))
    var scan = LogicalPlan.scan(
        String("x.parquet"), SOURCE_PARQUET, b.build()
    )
    var plan = _group_by_one(String("k"), scan^)
    var est = estimate_group_count(plan)
    assert_false(est.is_known())
    assert_equal(
        est.why,
        GROUP_EST_WHY_NO_STATS,
        "a stats-less scan must be reported as a `precompute_scan_stats` REACH "
        "problem, not lumped in with a footer that lacks the signal",
    )


def test_a_zero_distinct_count_is_absent_not_zero() raises:
    """A writer that recorded `distinct_count = 0` said nothing useful. It must
    read as UNKNOWN, not as "one group" — the latter would decline RADIX with
    total confidence on a column we know nothing about."""
    var plan = _group_by_one(
        String("k"), _one_col_scan(String("k"), 0, 1_000_000)
    )
    var est = estimate_group_count(plan)
    assert_false(est.is_known())
    assert_equal(est.why, GROUP_EST_WHY_NO_SIGNAL)


def test_a_computed_group_key_produces_nothing() raises:
    """`GROUP BY <expr>` where the key is not a plain column reference: no
    writer statistic describes a derived value."""
    var gb = ExprArray()
    gb.append(
        Expr.binary(
            BIN_ADD,
            Expr.col_ref(String("k")),
            Expr.literal(ScalarValue.from_int(1)),
        )
    )
    var ax = AggExprArray()
    ax.append(
        AggExpr(AGG_COUNT, Optional[Expr](), None)
    )
    var plan = LogicalPlan.aggregate(
        gb^, ax^, _one_col_scan(String("k"), 29_818, 31_680)
    )
    var est = estimate_group_count(plan)
    assert_false(est.is_known())
    assert_equal(est.why, GROUP_EST_WHY_COMPUTED_KEY)


def test_grouping_on_an_aggregate_output_produces_nothing() raises:
    """Q13's second dispatch, structurally: GROUP BY a column that a lower
    AGGREGATE computed (`c_count`). The correct answer is UNKNOWN — q13's two
    dispatches have identical rows/workers/byte_stable and want opposite
    strategies, and getting the second one WRONG is exactly the 69-us combine
    being handed a 64-way partition fan."""
    var inner = _group_by_one(
        String("o_custkey"), _one_col_scan(String("o_custkey"), 150_000, 1_500_000)
    )
    # The inner aggregate's output column for COUNT is not `o_custkey`.
    var gb = ExprArray()
    gb.append(Expr.col_ref(String("count")))
    var ax = AggExprArray()
    ax.append(
        AggExpr(AGG_COUNT, Optional[Expr](), None)
    )
    var outer = LogicalPlan.aggregate(gb^, ax^, inner^)
    var est = estimate_group_count(outer)
    assert_false(est.is_known())
    assert_equal(
        est.why,
        GROUP_EST_WHY_COMPUTED_KEY,
        "grouping on an aggregate OUTPUT is a derived value, and must be "
        "reported as such rather than as a missing statistic",
    )


def test_a_key_grouped_through_a_lower_aggregate_does_resolve() raises:
    """The POSITIVE CONTROL for the case above: without it, the previous test
    passes for the trivial reason that nothing ever resolves through an
    AGGREGATE. Grouping again on a column the inner aggregate GROUPED BY
    preserves its distinct values exactly, so it must resolve."""
    var inner = _group_by_one(
        String("o_custkey"), _one_col_scan(String("o_custkey"), 150_000, 1_500_000)
    )
    var outer = _group_by_one(String("o_custkey"), inner^)
    var est = estimate_group_count(outer)
    assert_true(est.is_known(), "a re-grouped GROUP BY key failed to resolve")
    assert_equal(est.groups, 150_000)


def test_computed_projection_does_not_resolve() raises:
    """A PROJECT that RENAMES resolves; a PROJECT that COMPUTES does not. The
    two are adjacent in the projection list, so a positional match would
    silently resolve the computed column to the renamed one's NDV.

    MUTANT: match `exprs[i]` against `output_schema.field_name(i)` and the
    computed column picks up 29,818 — a wrong-but-confident number."""
    var scan = _one_col_scan(String("k"), 29_818, 31_680)
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("k")).alias(String("renamed")))
    exprs.append(
        Expr.binary(
            BIN_ADD,
            Expr.col_ref(String("k")),
            Expr.literal(ScalarValue.from_int(1)),
        ).alias(String("derived"))
    )
    var proj = LogicalPlan.project(exprs^, scan^)
    var renamed_plan = _group_by_one(String("renamed"), proj.copy())
    var derived_plan = _group_by_one(String("derived"), proj^)
    var r = estimate_group_count(renamed_plan)
    assert_true(r.is_known(), "a pure rename failed to resolve through PROJECT")
    assert_equal(r.groups, 29_818)
    assert_false(estimate_group_count(derived_plan).is_known(), "a COMPUTED projection resolved to a base column's NDV")


def test_multi_key_product_is_clamped_by_the_row_bound() raises:
    """Two keys of 10,000 NDV each over a 6,000-row table. The independence
    product says 100,000,000; there are 6,000 rows, so there are at most 6,000
    groups.

    MUTANT: drop the clamp and this returns 100,000,000 — 16,667x high, and
    over the floor by four orders of magnitude on a table that cannot fill
    one."""
    var names = List[String]()
    names.append(String("a"))
    names.append(String("b"))
    var ndvs = List[Optional[Int]]()
    ndvs.append(Optional[Int](10_000))
    ndvs.append(Optional[Int](10_000))
    var mins = List[Optional[Int]]()
    mins.append(None)
    mins.append(None)
    var maxs = List[Optional[Int]]()
    maxs.append(None)
    maxs.append(None)
    var cols = List[String]()
    cols.append(String("a"))
    cols.append(String("b"))
    var scan = _scan_with_stats(
        String("t.parquet"),
        cols^,
        _stats(6_000, names^, ndvs^, mins^, maxs^),
        6_000,
    )
    var gb = ExprArray()
    gb.append(Expr.col_ref(String("a")))
    gb.append(Expr.col_ref(String("b")))
    var ax = AggExprArray()
    ax.append(
        AggExpr(AGG_COUNT, Optional[Expr](), None)
    )
    var plan = LogicalPlan.aggregate(gb^, ax^, scan^)
    var est = estimate_group_count(plan)
    assert_true(est.is_known())
    assert_equal(est.groups, 6_000)


def test_single_key_ndv_is_also_clamped_by_rows() raises:
    """The SUM-across-row-groups NDV fallback can exceed the row count outright
    (49 row groups x 7 distinct = 343 is small, but 500 row groups x 200 is
    not). Groups can never exceed rows."""
    var plan = _group_by_one(
        String("k"), _one_col_scan(String("k"), 100_000, 6_000)
    )
    var est = estimate_group_count(plan)
    assert_true(est.is_known())
    assert_equal(est.groups, 6_000)


def test_scalar_aggregate_is_exactly_one_group() raises:
    """No GROUP BY keys means one output row. That is arithmetic, so it is
    answered even though no statistic was consulted."""
    var gb = ExprArray()
    var ax = AggExprArray()
    ax.append(
        AggExpr(AGG_COUNT, Optional[Expr](), None)
    )
    var plan = LogicalPlan.aggregate(
        gb^, ax^, _one_col_scan(String("k"), None, 6_000_000)
    )
    var est = estimate_group_count(plan)
    assert_true(est.is_known())
    assert_equal(est.groups, 1)


# =============================================================================
# 4. TIER 2 — the min/max DOMAIN fallback, and its bounded reach.
# =============================================================================


def test_distinct_count_outranks_the_domain() raises:
    """When both signals are present the real NDV wins. A domain of 1,000,000
    over a column the writer says has 12 distinct values must not admit RADIX.

    MUTANT: check the domain first and this returns 1,000,000 — the exact
    wrong-but-confident over-estimate the module header warns about."""
    var names = List[String]()
    names.append(String("k"))
    var ndvs = List[Optional[Int]]()
    ndvs.append(Optional[Int](12))
    var mins = List[Optional[Int]]()
    mins.append(Optional[Int](1))
    var maxs = List[Optional[Int]]()
    maxs.append(Optional[Int](1_000_000))
    var cols = List[String]()
    cols.append(String("k"))
    var scan = _scan_with_stats(
        String("t.parquet"),
        cols^,
        _stats(2_000_000, names^, ndvs^, mins^, maxs^),
        2_000_000,
    )
    var plan = _group_by_one(String("k"), scan^)
    assert_equal(estimate_group_count(plan).groups, 12)


# =============================================================================
# 5. The row bound itself.
# =============================================================================


def test_row_bound_gives_up_on_a_join() raises:
    """A join can FAN OUT, so neither side's row count bounds the output. The
    bound must be absent rather than optimistic — an under-tight clamp would
    saw a correct NDV product down."""
    var l = _one_col_scan(String("a"), 10, 100)
    var r = _one_col_scan(String("b"), 10, 100)
    var lk = List[String]()
    lk.append(String("a"))
    var rk = List[String]()
    rk.append(String("b"))
    var j = LogicalPlan.join(l^, r^, lk^, rk^, JOIN_INNER)
    assert_false(Bool(plan_row_upper_bound(j)))


def test_row_bound_survives_a_filter() raises:
    """A filter only removes rows, so the child's bound is still a bound."""
    var scan = _one_col_scan(String("k"), 10, 4_242)
    var f = LogicalPlan.filter(
        Expr.binary(
            BIN_GT,
            Expr.col_ref(String("k")),
            Expr.literal(ScalarValue.from_int(3)),
        ),
        scan^,
    )
    var b = plan_row_upper_bound(f)
    assert_true(Bool(b))
    assert_equal(b.value(), 4_242)


# =============================================================================
# 4. PROVENANCE — the half that decides whether a number may be believed.
# =============================================================================


def _scan_two_signals(
    name: String,
    ndv: Optional[Int],
    lo: Optional[Int],
    hi: Optional[Int],
    row_count: Int,
    var from_hll: List[Bool],
) -> LogicalPlan:
    var n1 = List[String]()
    n1.append(name)
    var n2 = List[String]()
    n2.append(name)
    var ndvs = List[Optional[Int]]()
    ndvs.append(ndv)
    var mins = List[Optional[Int]]()
    mins.append(lo)
    var maxs = List[Optional[Int]]()
    maxs.append(hi)
    return _scan_with_stats(
        String("t.parquet"),
        n2^,
        _stats(row_count, n1^, ndvs^, mins^, maxs^, from_hll^),
        row_count,
    )


def test_provenance_is_dcsum_when_the_array_is_absent() raises:
    """⛔ THE FAIL-OPEN, CLOSED. `TableStats.column_distinct_count_from_hll`
    returns **True** when its `from_hll` array is EMPTY — a documented
    backward-compat rule ("assume HLL-backed") that is a defensible tie-break
    for a JOIN-ORDER cost model and a falsehood for an accuracy measurement.

    An unverified provenance must degrade to the WEAKER claim. Without this the
    instrument stamps `hll` — "an honest distinct count" — on what is really a
    per-row-group SUM, and every reader of the table over-trusts it.

    MUTANT: call the accessor without the length guard and this returns
    `hll`."""
    var scan = _scan_two_signals(
        String("k"), Optional[Int](500), None, None, 10_000, List[Bool]()
    )
    var est = estimate_group_count(_group_by_one(String("k"), scan^))
    assert_true(est.is_known())
    assert_equal(est.groups, 500)
    assert_equal(
        est.provenance,
        GROUP_EST_PROV_DCSUM,
        "an UNVERIFIED provenance was laundered up to `hll`",
    )


def test_provenance_is_hll_only_when_explicitly_recorded() raises:
    """The POSITIVE CONTROL for the case above. Without it, that test passes
    for the trivial reason that `hll` is unreachable.

    ⚠ On the corpus this arm is currently unreachable in PRODUCTION:
    `hll_registers` is an engine-specific footer extension, and measured
    zero columns of the DuckDB-written TPC-H SF1 fixtures carry it."""
    var hll = List[Bool]()
    hll.append(True)
    var scan = _scan_two_signals(
        String("k"), Optional[Int](500), None, None, 10_000, hll^
    )
    var est = estimate_group_count(_group_by_one(String("k"), scan^))
    assert_equal(est.provenance, GROUP_EST_PROV_HLL)


def test_an_explicit_false_flag_is_dcsum() raises:
    """A populated array recording False is the honest SUM case."""
    var hll = List[Bool]()
    hll.append(False)
    var scan = _scan_two_signals(
        String("k"), Optional[Int](500), None, None, 10_000, hll^
    )
    assert_equal(
        estimate_group_count(_group_by_one(String("k"), scan^)).provenance,
        GROUP_EST_PROV_DCSUM,
    )


def test_provenance_is_domain_when_only_minmax_reaches() raises:
    """What ACTUALLY happens to every high-cardinality group key in the corpus.
    Measured on the TPC-H SF1 fixtures: `ps_partkey`,
    `c_custkey`, `l_orderkey` and `o_orderkey` carry NO `distinct_count` at
    all, only a min/max span — which is an UPPER BOUND on the distinct count,
    not an estimate of it."""
    var scan = _scan_two_signals(
        String("ps_partkey"),
        None,
        Optional[Int](1),
        Optional[Int](200_000),
        800_000,
        List[Bool](),
    )
    var est = estimate_group_count(_group_by_one(String("ps_partkey"), scan^))
    assert_true(est.is_known())
    assert_equal(est.groups, 200_000)
    assert_equal(est.provenance, GROUP_EST_PROV_DOMAIN)
    # Truth for q11 is 29,818, so the bound is 6.7x high. Recorded, not
    # asserted as acceptable — this is the number the estimator is about.
    assert_true(est.groups > 29_818)


def test_a_wide_domain_is_capped_at_the_scans_own_row_count() raises:
    """⭐ `o_orderkey` spans 1..6,000,000 in a 1,500,000-row `orders.parquet`
    (measured). Four times more distinct values than there are rows.

    The cap has to be applied AT RESOLUTION, against the scan's own row count,
    because when the aggregate sits over a JOIN `plan_row_upper_bound`
    correctly refuses to bound the output at all — so there is no later clamp.

    MUTANT: drop the per-scan cap and this reports 6,000,000."""
    var scan = _scan_two_signals(
        String("o_orderkey"),
        None,
        Optional[Int](1),
        Optional[Int](6_000_000),
        1_500_000,
        List[Bool](),
    )
    var est = estimate_group_count(_group_by_one(String("o_orderkey"), scan^))
    assert_equal(est.groups, 1_500_000)
    assert_equal(est.provenance, GROUP_EST_PROV_DOMAIN)


def test_provenance_travels_with_the_value_that_won() raises:
    """A join resolving the same name on both sides takes the TIGHTER bound —
    and must report THAT side's tag. Reporting the loser's stronger tag would
    stamp `hll` on a number no HLL sketch produced, which is the laundering
    this module exists to refuse.

    MUTANT: return the tighter VALUE with the stronger PROVENANCE and this
    reports `hll` for a domain-derived 50."""
    var hll = List[Bool]()
    hll.append(True)
    var l = _scan_two_signals(
        String("k"), Optional[Int](100), None, None, 1_000, hll^
    )
    var r = _scan_two_signals(
        String("k"), None, Optional[Int](1), Optional[Int](50), 1_000,
        List[Bool](),
    )
    var lk = List[String]()
    lk.append(String("k"))
    var rk = List[String]()
    rk.append(String("k"))
    var j = LogicalPlan.join(l^, r^, lk^, rk^, JOIN_INNER)
    var est = estimate_group_count(_group_by_one(String("k"), j^))
    assert_equal(est.groups, 50, "the join did not take the tighter bound")
    assert_equal(
        est.provenance,
        GROUP_EST_PROV_DOMAIN,
        "provenance was taken from the side whose value LOST",
    )


def test_the_weakest_key_sets_the_whole_estimates_provenance() raises:
    """Multi-key: one key with a recorded HLL NDV, one reaching only a domain.
    The product is only as trustworthy as its weakest contributor.

    ⚠ THE ODD COLUMN IS IN THE MIDDLE of the three deliberately — a two-column
    fixture with the odd one at an end lets a mutant that reads only the first
    or only the last key survive."""
    var names = List[String]()
    names.append(String("a"))
    names.append(String("b"))
    names.append(String("c"))
    var ndvs = List[Optional[Int]]()
    ndvs.append(Optional[Int](10))
    ndvs.append(None)           # <- the odd one, in the MIDDLE
    ndvs.append(Optional[Int](10))
    var mins = List[Optional[Int]]()
    mins.append(None)
    mins.append(Optional[Int](1))
    mins.append(None)
    var maxs = List[Optional[Int]]()
    maxs.append(None)
    maxs.append(Optional[Int](10))
    maxs.append(None)
    var hll = List[Bool]()
    hll.append(True)
    hll.append(True)
    hll.append(True)
    var cols = List[String]()
    cols.append(String("a"))
    cols.append(String("b"))
    cols.append(String("c"))
    var scan = _scan_with_stats(
        String("t.parquet"),
        cols^,
        _stats(1_000_000, names^, ndvs^, mins^, maxs^, hll^),
        1_000_000,
    )
    var gb = ExprArray()
    gb.append(Expr.col_ref(String("a")))
    gb.append(Expr.col_ref(String("b")))
    gb.append(Expr.col_ref(String("c")))
    var ax = AggExprArray()
    ax.append(AggExpr(AGG_COUNT, Optional[Expr](), None))
    var plan = LogicalPlan.aggregate(gb^, ax^, scan^)
    var est = estimate_group_count(plan)
    assert_equal(est.groups, 1_000)
    assert_equal(
        est.provenance,
        GROUP_EST_PROV_DOMAIN,
        "a strong key masked a weak one — the tag must be the WEAKEST used",
    )


def test_an_unknown_estimate_carries_the_none_tag() raises:
    """`groups == -1` and `prov == none` travel together, and the trace's tag
    for it says so rather than printing an empty field."""
    var b = SchemaBuilder()
    b.add_field(Field(String("k"), ArrowType.INT64, False))
    var plan = _group_by_one(
        String("k"),
        LogicalPlan.scan(String("x.parquet"), SOURCE_PARQUET, b.build()),
    )
    var est = estimate_group_count(plan)
    assert_false(est.is_known())
    assert_equal(est.groups, -1)
    assert_equal(est.provenance, GROUP_EST_PROV_NONE)
    assert_equal(String(group_est_prov_name(est.provenance)), String("none"))


def test_every_provenance_tag_has_a_distinct_name() raises:
    """A tag vocabulary whose members print the same string cannot be read out
    of a trace, and the trace is this module's entire output."""
    assert_equal(String(group_est_prov_name(GROUP_EST_PROV_NONE)), String("none"))
    assert_equal(String(group_est_prov_name(GROUP_EST_PROV_HLL)), String("hll"))
    assert_equal(String(group_est_prov_name(GROUP_EST_PROV_DCSUM)), String("dcsum"))
    assert_equal(
        String(group_est_prov_name(GROUP_EST_PROV_DOMAIN)), String("domain")
    )
    # And the ORDER is load-bearing: `_estimate_over` takes the MAX code as the
    # weakest link, so weaker must sort higher.
    assert_true(GROUP_EST_PROV_DOMAIN > GROUP_EST_PROV_DCSUM)
    assert_true(GROUP_EST_PROV_DCSUM > GROUP_EST_PROV_HLL)




# =============================================================================
# 5. DECLINE REASONS — "it returned nothing" localises nothing.
# =============================================================================


def test_a_missing_column_is_distinguished_from_a_missing_signal() raises:
    """⭐ THE DISTINCTION THE FIRST LIVE RUN NEEDED. Every corpus cell printed
    `pred=-1 prov=none`, and those two words cover five causes with five
    different owners. These two are the pair most easily confused: stats
    present but the COLUMN is absent (a projection-provenance question) versus
    stats present, column present, and the FOOTER carries no usable signal (a
    writer question, unfixable in this module).

    MUTANT: collapse both to a bare unknown and this goes red, and the live
    measurement stops being able to say who owns the gap."""
    # (a) column absent from otherwise-populated stats.
    var absent = _scan_two_signals(
        String("other_col"), Optional[Int](5), None, None, 100, List[Bool]()
    )
    var est_a = estimate_group_count(_group_by_one(String("k"), absent^))
    assert_false(est_a.is_known())
    assert_equal(est_a.why, GROUP_EST_WHY_NO_COLUMN)
    # (b) column present, no distinct_count and no int min/max.
    var present = _scan_two_signals(
        String("k"), None, None, None, 100, List[Bool]()
    )
    var est_b = estimate_group_count(_group_by_one(String("k"), present^))
    assert_false(est_b.is_known())
    assert_equal(est_b.why, GROUP_EST_WHY_NO_SIGNAL)
    assert_true(
        est_a.why != est_b.why,
        "two different owners collapsed into one reason code",
    )


def test_a_join_reports_the_more_specific_side() raises:
    """The key lives on ONE side of a join. The other side truthfully answers
    `no_column`, which is expected and says nothing — reporting it would point
    a reader at the wrong table.

    MUTANT: report the LEFT side unconditionally and this returns `no_column`
    for a key whose real problem is on the right."""
    var l = _scan_two_signals(
        String("unrelated"), Optional[Int](5), None, None, 100, List[Bool]()
    )
    var r = _scan_two_signals(String("k"), None, None, None, 100, List[Bool]())
    var lk = List[String]()
    lk.append(String("unrelated"))
    var rk = List[String]()
    rk.append(String("k"))
    var j = LogicalPlan.join(l^, r^, lk^, rk^, JOIN_INNER)
    var est = estimate_group_count(_group_by_one(String("k"), j^))
    assert_false(est.is_known())
    assert_equal(
        est.why,
        GROUP_EST_WHY_NO_SIGNAL,
        "the join reported the side the key does not live on",
    )


def test_a_resolved_estimate_reports_ok() raises:
    """The POSITIVE CONTROL. Without it every reason test passes for the
    trivial reason that `ok` is unreachable."""
    var est = estimate_group_count(
        _group_by_one(String("k"), _one_col_scan(String("k"), 500, 10_000))
    )
    assert_true(est.is_known())
    assert_equal(est.why, GROUP_EST_WHY_OK)


def test_a_non_file_source_is_not_reported_as_missing_stats() raises:
    """⭐ THE SPLIT THE LIVE RUN FORCED. Five of six corpus in-mem sites printed
    `why=no_stats`, and that one tag covered two findings with opposite owners:
    a PARQUET scan without stats is a `precompute_scan_stats` REACH gap
    (fixable), while an IN-MEMORY scan never had a footer at all — the sub-plan
    was already executed and replaced by its resident batch, so no plan-time
    estimator of any design could describe it.

    MUTANT: collapse them and the measurement blames the stats pass for a fact
    about plan shape."""
    var b = SchemaBuilder()
    b.add_field(Field(String("k"), ArrowType.INT64, False))
    var scan = LogicalPlan.scan(
        String("resident"), SOURCE_IN_MEMORY, b.build()
    )
    var est = estimate_group_count(_group_by_one(String("k"), scan^))
    assert_false(est.is_known())
    assert_equal(est.why, GROUP_EST_WHY_NO_FOOTER_SOURCE)
    # And the PARQUET control, so the split is a discrimination and not a
    # rename: same missing stats, different tag.
    var b2 = SchemaBuilder()
    b2.add_field(Field(String("k"), ArrowType.INT64, False))
    var pq = LogicalPlan.scan(String("f.parquet"), SOURCE_PARQUET, b2.build())
    assert_equal(
        estimate_group_count(_group_by_one(String("k"), pq^)).why,
        GROUP_EST_WHY_NO_STATS,
    )


def test_every_reason_tag_has_a_distinct_name() raises:
    """The tags are the instrument's output; two that print alike cannot be
    counted out of a log."""
    assert_equal(String(group_est_why_name(GROUP_EST_WHY_OK)), String("ok"))
    assert_equal(
        String(group_est_why_name(GROUP_EST_WHY_COMPUTED_KEY)),
        String("computed_key"),
    )
    assert_equal(
        String(group_est_why_name(GROUP_EST_WHY_NO_STATS)), String("no_stats")
    )
    assert_equal(
        String(group_est_why_name(GROUP_EST_WHY_NO_COLUMN)), String("no_column")
    )
    assert_equal(
        String(group_est_why_name(GROUP_EST_WHY_NO_SIGNAL)), String("no_signal")
    )
    assert_equal(
        String(group_est_why_name(GROUP_EST_WHY_NO_FOOTER_SOURCE)),
        String("no_footer_source"),
    )
    assert_equal(
        String(group_est_why_name(GROUP_EST_WHY_UNWALKABLE)),
        String("unwalkable"),
    )



def main() raises:
    test_q11_shape_resolves_above_the_group_floor()
    test_q4_shape_resolves_below_the_group_floor()
    test_q12_shape_resolves_below_the_group_floor()
    test_one_unresolvable_key_poisons_the_whole_estimate()
    test_a_stats_less_scan_produces_nothing()
    test_a_zero_distinct_count_is_absent_not_zero()
    test_a_computed_group_key_produces_nothing()
    test_grouping_on_an_aggregate_output_produces_nothing()
    test_a_key_grouped_through_a_lower_aggregate_does_resolve()
    test_computed_projection_does_not_resolve()
    test_multi_key_product_is_clamped_by_the_row_bound()
    test_single_key_ndv_is_also_clamped_by_rows()
    test_scalar_aggregate_is_exactly_one_group()
    test_distinct_count_outranks_the_domain()
    test_row_bound_gives_up_on_a_join()
    test_row_bound_survives_a_filter()
    test_provenance_is_dcsum_when_the_array_is_absent()
    test_provenance_is_hll_only_when_explicitly_recorded()
    test_an_explicit_false_flag_is_dcsum()
    test_provenance_is_domain_when_only_minmax_reaches()
    test_a_wide_domain_is_capped_at_the_scans_own_row_count()
    test_provenance_travels_with_the_value_that_won()
    test_the_weakest_key_sets_the_whole_estimates_provenance()
    test_an_unknown_estimate_carries_the_none_tag()
    test_every_provenance_tag_has_a_distinct_name()
    test_a_missing_column_is_distinguished_from_a_missing_signal()
    test_a_join_reports_the_more_specific_side()
    test_a_resolved_estimate_reports_ok()
    test_a_non_file_source_is_not_reported_as_missing_stats()
    test_every_reason_tag_has_a_distinct_name()
    print("All 30 plan_group_estimate instrument tests passed.")
