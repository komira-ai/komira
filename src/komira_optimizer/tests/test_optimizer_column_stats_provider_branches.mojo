# =============================================================================
# Branch tests for optimizer_column_stats_provider.mojo
# =============================================================================
#
# The welded provider tests build every relation as a bare Scan whose
# row_count equals its cardinality; their Parquet-metadata (Tier-1) stats are
# all HLL-backed. These tests reach the remaining arms:
#   * `_leaf_raw_row_count` through Filter and Project, on a Scan with no
#     row_count, on a non-scan leaf, and on a node whose tag names a payload
#     the node does not carry.
#   * The Tier-2 domain proxy: a filtered leaf reports its RAW scan row_count,
#     not the post-filter cardinality.
#   * Tier-1 provenance when the writer recorded a SUM fallback
#     (`from_hll=False`).
#   * `ColumnStatsValue.copy()`.
# Each test names the defect it catches.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import Expr
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    SOURCE_PARQUET,
)
from komira_plan_stats.table_stats import (
    TableStats,
    ColumnStats,
    STATS_SOURCE_PARQUET_METADATA,
)
from komira_optimizer.optimizer_reorder import JoinRelation, JoinChain
from komira_optimizer.optimizer_column_stats_provider import (
    ColumnStatsValue,
    DefaultColumnStatsProvider,
    TIER_PARQUET_METADATA,
    TIER_ROW_COUNT_HEURISTIC,
    _leaf_raw_row_count,
)


def _schema(name: String) -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(name, ArrowType.INT64, False))
    return b.build()


def _scan(key: String, var rc: Optional[Int]) -> LogicalPlan:
    var none_proj: Optional[List[String]] = None
    var none_filt: Optional[Expr] = None
    return LogicalPlan.scan(
        "r.parquet", SOURCE_PARQUET, _schema(key), none_proj^, none_filt^, rc^
    )


def _filter_over(var child: LogicalPlan, key: String) -> LogicalPlan:
    return LogicalPlan.filter(Expr.col_ref(String(key)), child^)


def _project_over(var child: LogicalPlan, key: String) -> LogicalPlan:
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String(key)))
    return LogicalPlan.project(exprs^, child^)


def _ndv_for_leaf(var leaf: LogicalPlan, cardinality: Int) -> ColumnStatsValue:
    """Tier-2 answer for a one-relation chain whose leaf plan is `leaf`."""
    var chain = JoinChain()
    var no_stats: Optional[TableStats] = None
    chain.relations.append(JoinRelation(0, leaf^, cardinality, no_stats^))
    var provider = DefaultColumnStatsProvider(chain.relations)
    return provider.distinct_count_for(0, "k")


def test_tier2_filtered_leaf_reports_raw_scan_domain() raises:
    """Filter(Scan row_count=1000) with post-filter cardinality 135 answers
    1000: the join-key domain is the unfiltered row count.
    Catches: the PLAN_FILTER arm of `_leaf_raw_row_count` dropped or
    returning -1 (the answer would collapse to 135 and cancel the filter's
    reduction in the cost model)."""
    var v = _ndv_for_leaf(_filter_over(_scan("k", 1000), "k"), 135)
    assert_equal(v.ndv, 1000)
    assert_false(v.from_hll)
    assert_equal(v.source, TIER_ROW_COUNT_HEURISTIC)


def test_tier2_projected_leaf_reports_raw_scan_domain() raises:
    """Project(Filter(Scan row_count=800)) with cardinality 50 answers 800.
    Catches: the PLAN_PROJECT arm dropped, or the walk not recursing through
    a Project into a Filter."""
    var leaf = _project_over(_filter_over(_scan("k", 800), "k"), "k")
    var v = _ndv_for_leaf(leaf^, 50)
    assert_equal(v.ndv, 800)


def test_tier2_scan_without_row_count_uses_cardinality() raises:
    """A Scan with no footer row_count falls back to the relation's
    cardinality (77). Catches: the no-row_count arm returning a value >= 1
    instead of -1 (that value would replace the cardinality), or the
    `domain < 1` fallback to the cardinality dropped (the answer would be
    the -1 sentinel, clamped to 1)."""
    var none_rc: Optional[Int] = None
    var v = _ndv_for_leaf(_scan("k", none_rc^), 77)
    assert_equal(v.ndv, 77)
    assert_equal(v.source, TIER_ROW_COUNT_HEURISTIC)


def test_tier2_non_scan_leaf_uses_cardinality() raises:
    """A leaf that is neither Scan, Filter nor Project (a view reference)
    falls back to cardinality 33. Catches: the final `return -1` changed to
    a count, or the walk treating any node as a scan."""
    var v = _ndv_for_leaf(LogicalPlan.view_ref("v", _schema("k")), 33)
    assert_equal(v.ndv, 33)


def test_leaf_raw_row_count_direct() raises:
    """Direct answers of the walk, including the defensive arms where a
    node's tag names a payload the node does not carry.
    Catches: a payload-absent node dereferenced (crash) instead of
    answering -1; the scan arm returning the row_count of a scan that has
    none."""
    assert_equal(_leaf_raw_row_count(_scan("k", 42)), 42)
    var none_rc: Optional[Int] = None
    assert_equal(_leaf_raw_row_count(_scan("k", none_rc^)), -1)
    assert_equal(
        _leaf_raw_row_count(_project_over(_filter_over(_scan("k", 9), "k"), "k")),
        9,
    )

    var scan_no_payload = _scan("k", 42)
    scan_no_payload._scan = None
    assert_equal(_leaf_raw_row_count(scan_no_payload), -1)

    var filter_no_payload = _filter_over(_scan("k", 42), "k")
    filter_no_payload._filter = None
    assert_equal(_leaf_raw_row_count(filter_no_payload), -1)

    var project_no_payload = _project_over(_scan("k", 42), "k")
    project_no_payload._project = None
    assert_equal(_leaf_raw_row_count(project_no_payload), -1)


def test_tier1_sum_fallback_reports_from_hll_false() raises:
    """Tier-1 stats whose writer recorded a SUM fallback (`from_hll=False`)
    still win Tier 1 (ndv 25, TIER_PARQUET_METADATA) but report
    `from_hll=False`. Catches: `from_hll` hard-coded True on a Tier-1 hit,
    which would let the cost model trust a low-confidence NDV as HLL."""
    var names = List[String]()
    names.append("k")
    var cols = List[ColumnStats]()
    var dc: Optional[Int] = 25
    var mn: Optional[ScalarValue] = None
    var mx: Optional[ScalarValue] = None
    var nc: Optional[Int] = None
    cols.append(ColumnStats(dc^, mn^, mx^, nc^))
    var fh = List[Bool]()
    fh.append(False)
    var ts = Optional[TableStats](
        TableStats(1000, names^, cols^, STATS_SOURCE_PARQUET_METADATA, fh^)
    )
    var chain = JoinChain()
    chain.relations.append(JoinRelation(0, _scan("k", 1000), 1000, ts^))
    var provider = DefaultColumnStatsProvider(chain.relations)
    var v = provider.distinct_count_for(0, "k")
    assert_equal(v.ndv, 25)
    assert_false(v.from_hll)
    assert_equal(v.source, TIER_PARQUET_METADATA)


def test_column_stats_value_explicit_copy() raises:
    """`copy()` carries all three fields. Catches: a field dropped or
    swapped in the hand-written copy."""
    var v = ColumnStatsValue(12, True, TIER_ROW_COUNT_HEURISTIC)
    var c = v.copy()
    assert_equal(c.ndv, 12)
    assert_true(c.from_hll)
    assert_equal(c.source, TIER_ROW_COUNT_HEURISTIC)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
