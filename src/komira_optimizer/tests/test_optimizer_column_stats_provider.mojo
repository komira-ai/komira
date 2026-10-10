# =============================================================================
# Tests for the ColumnStatsProvider three-tier dispatch
# (optimizer_column_stats_provider.mojo)
# =============================================================================
#
# Acceptance tests. Verifies the load-bearing
# behavioral contract: `distinct_count_for` ALWAYS returns a value, with three-tier
# dispatch in priority order (Parquet metadata → row-count heuristic; the
# sampled Tier 3 is declared but unreachable).
#
# Coverage:
#   * Tier 1 hit  — JoinRelation with table_stats populated returns
#     `from_hll=True, source=TIER_PARQUET_METADATA, ndv=<hit>`.
#   * Tier 2 fallback — JoinRelation with table_stats=None returns
#     `from_hll=False, source=TIER_ROW_COUNT_HEURISTIC,
#     ndv=relation.cardinality`.
#   * Tier 2 fallback (column-not-in-stats) — JoinRelation HAS
#     table_stats but the queried column is not in it: tier 2 fires.
#   * Tier dispatch determinism — Tier 1 wins when both data sources
#     exist; Tier 2 fires only on Tier 1 miss.
#   * SyntheticColumnStatsProvider basic round-trip (test-injection
#     mechanism for cost-model tests).
#   * ColumnStatsValue field round-trip + ImplicitlyCopyable semantics.
#   * Cost-model safety: ndv clamped to >= 1.
#   * Out-of-range relation_id returns the defensive sentinel.
#   * STATS_SOURCE_SYNTHETIC_ROW_COUNT-tagged TableStats falls through
#     to Tier 2 (treated as row-count fallback in a different wrapper).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_SCAN,
    SOURCE_PARQUET,
)
from komira_optimizer.optimizer_reorder import (
    JoinRelation,
    JoinChain,
)
from komira_plan_stats.table_stats import (
    TableStats,
    ColumnStats,
    STATS_SOURCE_PARQUET_METADATA,
    STATS_SOURCE_SYNTHETIC_ROW_COUNT,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_optimizer.optimizer_column_stats_provider import (
    ColumnStatsValue,
    ColumnStatsProvider,
    DefaultColumnStatsProvider,
    SyntheticColumnStatsProvider,
    TIER_PARQUET_METADATA,
    TIER_ROW_COUNT_HEURISTIC,
    TIER_SAMPLED,
)


# =============================================================================
# Helpers
# =============================================================================


def _single_int_schema(name: String) -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(name, ArrowType.INT64, False))
    return b.build()


def _scan(path: String, key: String, n: Int) -> LogicalPlan:
    var s = _single_int_schema(key)
    var rc: Optional[Int] = n
    var none_proj: Optional[List[String]] = None
    var none_filt: Optional[Expr] = None
    return LogicalPlan.scan(
        path, SOURCE_PARQUET, s^, none_proj^, none_filt^, rc^
    )


def _table_stats_with_ndv(
    key: String, ndv: Int, row_count: Int, from_hll: Bool = True
) -> TableStats:
    """Build a Parquet-flavored TableStats with one distinct_count entry.

    from_hll provenance: default
    `from_hll=True` matches the earlier semantics of these
    fixtures (they tested Tier-1 wins assuming HLL-backed signal).
    Tests can pass `from_hll=False` to model the SUM-fallback case
    (explicit provenance-discrimination assertion).
    """
    var names = List[String]()
    names.append(key)
    var stats_list = List[ColumnStats]()
    var dc: Optional[Int] = ndv
    var min_v: Optional[ScalarValue] = None
    var max_v: Optional[ScalarValue] = None
    var nc: Optional[Int] = None
    stats_list.append(ColumnStats(dc^, min_v^, max_v^, nc^))
    var fh = List[Bool]()
    fh.append(from_hll)
    return TableStats(
        row_count, names^, stats_list^, STATS_SOURCE_PARQUET_METADATA, fh^
    )


def _table_stats_synthetic(
    key: String, ndv: Int, row_count: Int
) -> TableStats:
    """Build a SYNTHETIC-source TableStats. Provider should treat the
    distinct_count as Tier 2 (row-count fallback) rather than Tier 1."""
    var names = List[String]()
    names.append(key)
    var stats_list = List[ColumnStats]()
    var dc: Optional[Int] = ndv
    var min_v: Optional[ScalarValue] = None
    var max_v: Optional[ScalarValue] = None
    var nc: Optional[Int] = None
    stats_list.append(ColumnStats(dc^, min_v^, max_v^, nc^))
    return TableStats(
        row_count, names^, stats_list^, STATS_SOURCE_SYNTHETIC_ROW_COUNT
    )


def _make_relation(
    id: Int,
    key: String,
    cardinality: Int,
    var stats: Optional[TableStats],
) -> JoinRelation:
    var plan = _scan("r" + String(id) + ".parquet", key, cardinality)
    return JoinRelation(id, plan^, cardinality, stats^)


# =============================================================================
# ColumnStatsValue POD tests
# =============================================================================


def test_column_stats_value_field_roundtrip() raises:
    """All three fields survive a construct + read cycle."""
    var v = ColumnStatsValue(25, True, TIER_PARQUET_METADATA)
    assert_equal(v.ndv, 25)
    assert_true(v.from_hll)
    assert_equal(v.source, TIER_PARQUET_METADATA)


def test_column_stats_value_clamps_ndv_to_one() raises:
    """Cost-model safety: ndv < 1 is clamped to 1 to avoid div-by-zero
    in `(L*R)/max(NDV(lk), NDV(rk))`."""
    var zero = ColumnStatsValue(0, False, TIER_ROW_COUNT_HEURISTIC)
    assert_equal(zero.ndv, 1)
    var neg = ColumnStatsValue(-7, False, TIER_ROW_COUNT_HEURISTIC)
    assert_equal(neg.ndv, 1)
    var one = ColumnStatsValue(1, False, TIER_ROW_COUNT_HEURISTIC)
    assert_equal(one.ndv, 1)
    var two = ColumnStatsValue(2, False, TIER_ROW_COUNT_HEURISTIC)
    assert_equal(two.ndv, 2)


def test_column_stats_value_implicitly_copyable() raises:
    """ImplicitlyCopyable conformance: the trait surface allows
    bare-value returns out of a Dict.get() / direct assignment.

    Compile-pass on this test is the load-bearing assertion;
    implicit copy is what the trait bound is for.
    """
    var src = ColumnStatsValue(42, True, TIER_PARQUET_METADATA)
    var dst = src   # implicit copy — no `^`, no `.copy()`
    assert_equal(src.ndv, 42)
    assert_equal(dst.ndv, 42)
    assert_true(dst.from_hll)


def test_tier_constants_distinct() raises:
    """The three tier constants are distinct UInt8 values."""
    assert_true(TIER_PARQUET_METADATA != TIER_ROW_COUNT_HEURISTIC)
    assert_true(TIER_PARQUET_METADATA != TIER_SAMPLED)
    assert_true(TIER_ROW_COUNT_HEURISTIC != TIER_SAMPLED)


# =============================================================================
# DefaultColumnStatsProvider — three-tier dispatch tests
# =============================================================================


def test_tier1_hit_returns_parquet_metadata_signal() raises:
    """Tier 1: writer-emitted NDV present, provider returns
    `from_hll=True, source=TIER_PARQUET_METADATA, ndv=<hit>`."""
    var chain = JoinChain()
    var ts = Optional[TableStats](_table_stats_with_ndv("c_nationkey", 25, 150_000))
    chain.relations.append(_make_relation(0, "c_nationkey", 150_000, ts^))

    var provider = DefaultColumnStatsProvider(chain.relations)
    var result = provider.distinct_count_for(0, "c_nationkey")

    assert_equal(result.ndv, 25)
    assert_true(result.from_hll)
    assert_equal(result.source, TIER_PARQUET_METADATA)


def test_tier2_fallback_no_table_stats() raises:
    """Tier 2: JoinRelation has table_stats=None. Provider falls through
    to `relation.cardinality` with `from_hll=False`."""
    var chain = JoinChain()
    var no_stats: Optional[TableStats] = None
    chain.relations.append(_make_relation(0, "s_nationkey", 10_000, no_stats^))

    var provider = DefaultColumnStatsProvider(chain.relations)
    var result = provider.distinct_count_for(0, "s_nationkey")

    assert_equal(result.ndv, 10_000)
    assert_false(result.from_hll)
    assert_equal(result.source, TIER_ROW_COUNT_HEURISTIC)


def test_tier2_fallback_column_not_in_stats() raises:
    """Tier 2: JoinRelation has table_stats populated, but the queried
    column is not in it. Provider falls through to cardinality."""
    var chain = JoinChain()
    # Stats know about "c_nationkey", we query "n_nationkey".
    var ts = Optional[TableStats](
        _table_stats_with_ndv("c_nationkey", 25, 150_000)
    )
    chain.relations.append(_make_relation(0, "c_nationkey", 150_000, ts^))

    var provider = DefaultColumnStatsProvider(chain.relations)
    var result = provider.distinct_count_for(0, "n_nationkey")

    # Cardinality 150_000 → from_hll=False, TIER_ROW_COUNT_HEURISTIC.
    assert_equal(result.ndv, 150_000)
    assert_false(result.from_hll)
    assert_equal(result.source, TIER_ROW_COUNT_HEURISTIC)


def test_tier_dispatch_determinism_tier1_wins_over_tier2() raises:
    """Tier 1 wins when both data sources exist. Build a relation
    with cardinality 150_000 AND table_stats.distinct_count(c_nationkey)=25;
    provider MUST return 25 (Tier 1), not 150_000 (Tier 2).

    This is the load-bearing Q5 invariant: for the Q5
    {customer.c_nationkey, supplier.s_nationkey, nation.n_nationkey}
    equivalence class, the cost model needs the per-column NDV (25),
    not the row count of customer (150_000), to produce the correct
    TDOM ceiling of 25.
    """
    var chain = JoinChain()
    var ts = Optional[TableStats](
        _table_stats_with_ndv("c_nationkey", 25, 150_000)
    )
    chain.relations.append(_make_relation(0, "c_nationkey", 150_000, ts^))

    var provider = DefaultColumnStatsProvider(chain.relations)
    var result = provider.distinct_count_for(0, "c_nationkey")

    assert_equal(result.ndv, 25)
    assert_equal(result.source, TIER_PARQUET_METADATA)
    assert_true(result.from_hll)


def test_multi_relation_independent_dispatch() raises:
    """Provider dispatches per-relation independently. r0 has Tier 1
    stats, r1 has Tier 2 fallback. Each query returns its own tier."""
    var chain = JoinChain()
    var ts0 = Optional[TableStats](_table_stats_with_ndv("c_nationkey", 25, 150_000))
    chain.relations.append(_make_relation(0, "c_nationkey", 150_000, ts0^))
    var no_stats: Optional[TableStats] = None
    chain.relations.append(_make_relation(1, "s_nationkey", 10_000, no_stats^))

    var provider = DefaultColumnStatsProvider(chain.relations)

    var r0 = provider.distinct_count_for(0, "c_nationkey")
    assert_equal(r0.ndv, 25)
    assert_equal(r0.source, TIER_PARQUET_METADATA)
    assert_true(r0.from_hll)

    var r1 = provider.distinct_count_for(1, "s_nationkey")
    assert_equal(r1.ndv, 10_000)
    assert_equal(r1.source, TIER_ROW_COUNT_HEURISTIC)
    assert_false(r1.from_hll)


def test_synthetic_row_count_stats_treated_as_tier2() raises:
    """A TableStats tagged STATS_SOURCE_SYNTHETIC_ROW_COUNT is a
    row-count fallback (`optimizer_dpccp._synth_row_count_table_stats`).
    Provider must skip Tier 1 for these — the distinct_count field
    is synthesized from row_count, NOT a real NDV signal.

    This pins the load-bearing invariant: ColumnStatsProvider
    distinguishes real Parquet stats from synthesized stats."""
    var chain = JoinChain()
    var ts = Optional[TableStats](
        _table_stats_synthetic("s_nationkey", 9_500, 10_000)
    )
    chain.relations.append(_make_relation(0, "s_nationkey", 10_000, ts^))

    var provider = DefaultColumnStatsProvider(chain.relations)
    var result = provider.distinct_count_for(0, "s_nationkey")

    # Tier 1 skipped because source==SYNTHETIC; falls through to
    # relation.cardinality=10_000 with from_hll=False.
    assert_equal(result.ndv, 10_000)
    assert_false(result.from_hll)
    assert_equal(result.source, TIER_ROW_COUNT_HEURISTIC)


def test_out_of_range_relation_id_returns_safe_sentinel() raises:
    """Defensive: out-of-range relation_id returns
    ColumnStatsValue(1, False, TIER_ROW_COUNT_HEURISTIC). ndv=1 is the
    cost-model identity (no multiplicative effect on intermediate sizes)."""
    var chain = JoinChain()
    var no_stats: Optional[TableStats] = None
    chain.relations.append(_make_relation(0, "k", 100, no_stats^))

    var provider = DefaultColumnStatsProvider(chain.relations)

    var neg = provider.distinct_count_for(-1, "k")
    assert_equal(neg.ndv, 1)
    assert_false(neg.from_hll)
    assert_equal(neg.source, TIER_ROW_COUNT_HEURISTIC)

    var oob = provider.distinct_count_for(42, "k")
    assert_equal(oob.ndv, 1)
    assert_false(oob.from_hll)
    assert_equal(oob.source, TIER_ROW_COUNT_HEURISTIC)


def test_tier2_cardinality_safely_clamped() raises:
    """Tier 2 falls through `relation.cardinality`. If a malformed
    chain has cardinality=0, the ColumnStatsValue constructor clamps
    to 1 (cost-model safety)."""
    var chain = JoinChain()
    var no_stats: Optional[TableStats] = None
    chain.relations.append(_make_relation(0, "k", 0, no_stats^))

    var provider = DefaultColumnStatsProvider(chain.relations)
    var result = provider.distinct_count_for(0, "k")

    assert_equal(result.ndv, 1)
    assert_false(result.from_hll)


# =============================================================================
# SyntheticColumnStatsProvider tests
# =============================================================================


def test_synthetic_provider_echoes_injected_value() raises:
    """SyntheticColumnStatsProvider returns the injected ColumnStatsValue
    verbatim. Used by cost-model unit tests."""
    var p = SyntheticColumnStatsProvider()
    p.inject(0, "c_nationkey", 25, True, TIER_PARQUET_METADATA)
    p.inject(1, "s_nationkey", 10_000, False, TIER_ROW_COUNT_HEURISTIC)

    var r0 = p.distinct_count_for(0, "c_nationkey")
    assert_equal(r0.ndv, 25)
    assert_true(r0.from_hll)
    assert_equal(r0.source, TIER_PARQUET_METADATA)

    var r1 = p.distinct_count_for(1, "s_nationkey")
    assert_equal(r1.ndv, 10_000)
    assert_false(r1.from_hll)
    assert_equal(r1.source, TIER_ROW_COUNT_HEURISTIC)


def test_synthetic_provider_miss_returns_safe_sentinel() raises:
    """Unknown key falls back to ColumnStatsValue(1, False,
    TIER_ROW_COUNT_HEURISTIC) — matches Default provider's defensive
    out-of-range behavior so test wiring degrades the same way as
    production wiring."""
    var p = SyntheticColumnStatsProvider()
    p.inject(0, "c_nationkey", 25)

    # Unknown column.
    var miss_col = p.distinct_count_for(0, "x_unknown")
    assert_equal(miss_col.ndv, 1)
    assert_false(miss_col.from_hll)
    assert_equal(miss_col.source, TIER_ROW_COUNT_HEURISTIC)

    # Unknown relation_id.
    var miss_rel = p.distinct_count_for(99, "c_nationkey")
    assert_equal(miss_rel.ndv, 1)
    assert_false(miss_rel.from_hll)
    assert_equal(miss_rel.source, TIER_ROW_COUNT_HEURISTIC)


def test_synthetic_provider_inject_overrides_existing() raises:
    """Re-injecting the same key replaces the existing entry."""
    var p = SyntheticColumnStatsProvider()
    p.inject(0, "k", 100)
    var first = p.distinct_count_for(0, "k")
    assert_equal(first.ndv, 100)
    p.inject(0, "k", 25)
    var second = p.distinct_count_for(0, "k")
    assert_equal(second.ndv, 25)


# =============================================================================
# main()
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
