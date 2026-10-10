# =============================================================================
# Ceil correction in NDV math
# =============================================================================
#
# This replaces floor-semantics post-filter cardinality (card * sel truncated
# via Int(...)) with ceil semantics — matching DuckDB's InspectTableFilter
# at `relation_statistics_helper.cpp`. Sites updated in
# `optimizer_stats.mojo`:
#   - PLAN_SCAN with filter: `base = _apply_selectivity_ceil(base, sel)`
#   - PLAN_FILTER (generic):  `filter_card = _apply_selectivity_ceil(...)`
#   - PLAN_FILTER (HAVING):   `_ceil_div(card * NUM, DEN)`
#
# Q9 and Q5 cardinalities are unaffected at SF1: 200K * 0.20 = 40000 (exact),
# 1.5M * 0.09 = 135000 (exact). Ceil bites only on small fractional
# remainders — which the explicit tests below exercise.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    SOURCE_PARQUET,
)
from komira_optimizer.optimizer_stats import estimate_cardinality
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_stats.table_stats import (
    TableStats,
    ColumnStats,
    STATS_SOURCE_PARQUET_METADATA,
)


def _one_col_schema(name: String) -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(name, ArrowType.INT64, False))
    return b.build()


def _stats_with_ndv(name: String, ndv: Int, row_count: Int) -> TableStats:
    var names = List[String]()
    names.append(name)
    var stats = List[ColumnStats]()
    stats.append(ColumnStats(Optional[Int](ndv)))
    return TableStats(row_count, names^, stats^, STATS_SOURCE_PARQUET_METADATA)


# =============================================================================
# Test 1 — Ceil-vs-floor at small fractional sel*card products
# =============================================================================


def test_b5_ceil_lifts_small_fraction_above_floor() raises:
    """`card=10, eq with NDV=3` -> sel=1/3, card*sel = 3.333.

    Floor: Int(3.333) = 3.
    Ceil:  4 (lifted above floor for fractional remainder).
    """
    var pred = Expr.binary(
        10,  # BIN_EQ
        Expr.col_ref("c"),
        Expr.literal(ScalarValue.from_int(7)),
    )
    var rc: Optional[Int] = Optional[Int](10)
    var ts: Optional[TableStats] = Optional[TableStats](
        _stats_with_ndv("c", 3, 10)
    )
    var filt: Optional[Expr] = Optional[Expr](pred^)
    var proj: Optional[List[String]] = None
    var scan = LogicalPlan.scan(
        "/x.parquet", SOURCE_PARQUET, _one_col_schema("c"),
        proj^, filt^, rc^, ts^,
    )
    var card = estimate_cardinality(scan^)
    # 10 * (1/3) = 3.3333 -> ceil = 4.
    assert_equal(card, 4)


def test_b5_floor_path_preserved_when_product_integral() raises:
    """`card=200000, sel=0.20 (LIKE %pat%)` -> 40000 exact.

    Q9-shape regression-guard: when card*sel is exactly integral, ceil
    must NOT lift above floor (no off-by-one for exact products).
    """
    var pred = Expr.string_op(3, Expr.col_ref("c"), "%pat%")  # STR_LIKE contains
    var rc: Optional[Int] = Optional[Int](200_000)
    var ts: Optional[TableStats] = Optional[TableStats](
        _stats_with_ndv("c", 200_000, 200_000)
    )
    var filt: Optional[Expr] = Optional[Expr](pred^)
    var proj: Optional[List[String]] = None
    var scan = LogicalPlan.scan(
        "/x.parquet", SOURCE_PARQUET, _one_col_schema("c"),
        proj^, filt^, rc^, ts^,
    )
    var card = estimate_cardinality(scan^)
    # 200000 * 0.20 = 40000 exact (no fractional remainder, no lift).
    assert_equal(card, 40_000)


# =============================================================================
# Test 2 — Sub-1 product (selectivity * card < 1) is clamped to 1
# =============================================================================


def test_b5_subone_product_clamps_to_one() raises:
    """`card=5, NDV=100` -> sel=1/100, card*sel = 0.05.

    Both floor and ceil hit the clamp-to-1 (no rows would survive an
    NDV-100 eq on a 5-row table in reality, but the cost model needs at
    least one row to keep join-order costing non-degenerate). This pins the
    clamp-to-1 contract under the ceil path.
    """
    var pred = Expr.binary(
        10,  # BIN_EQ
        Expr.col_ref("c"),
        Expr.literal(ScalarValue.from_int(7)),
    )
    var rc: Optional[Int] = Optional[Int](5)
    var ts: Optional[TableStats] = Optional[TableStats](
        _stats_with_ndv("c", 100, 5)
    )
    var filt: Optional[Expr] = Optional[Expr](pred^)
    var proj: Optional[List[String]] = None
    var scan = LogicalPlan.scan(
        "/x.parquet", SOURCE_PARQUET, _one_col_schema("c"),
        proj^, filt^, rc^, ts^,
    )
    var card = estimate_cardinality(scan^)
    # 5 * 0.01 = 0.05 -> clamped to 1.
    assert_equal(card, 1)


# =============================================================================
# Test 3 — Range selectivity at fractional card
# =============================================================================


def test_b5_range_at_seven_rows_ceils_to_three() raises:
    """`card=7, sel=0.30 (range)` -> 7 * 0.30 = 2.1.

    Floor: Int(2.1) = 2.
    Ceil:  3 (lifted).
    """
    var pred = Expr.binary(
        14,  # BIN_GT
        Expr.col_ref("c"),
        Expr.literal(ScalarValue.from_int(5)),
    )
    var rc: Optional[Int] = Optional[Int](7)
    var stats: Optional[TableStats] = None
    var filt: Optional[Expr] = Optional[Expr](pred^)
    var proj: Optional[List[String]] = None
    var scan = LogicalPlan.scan(
        "/x.parquet", SOURCE_PARQUET, _one_col_schema("c"),
        proj^, filt^, rc^, stats^,
    )
    var card = estimate_cardinality(scan^)
    # 7 * 0.30 = 2.1 -> ceil = 3.
    assert_equal(card, 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
