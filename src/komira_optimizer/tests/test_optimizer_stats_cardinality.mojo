# =============================================================================
# optimizer_stats: every plan arm of estimate_cardinality, every width class
# of estimate_row_width, and the two ceil helpers
# =============================================================================
#
# The welded `test_optimizer_stats_b5_ceil` covers the filtered-scan arm.
# This file reaches the other arms (unfiltered scans, HAVING and generic
# filters, project, scalar and grouped aggregates, every join type, sort,
# limit, distinct, topn, and an unknown tag), each clamp-to-1, and the
# guards of `_ceil_div` and `_apply_selectivity_ceil` that no plan reaches
# (they are called directly).
#
# Each test names the defect it catches.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import Expr, BIN_GT
from komira_plan_expr.agg_expr import AggExpr, AGG_COUNT
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    SOURCE_PARQUET,
    JOIN_INNER,
    JOIN_LEFT,
    JOIN_SEMI,
    JOIN_ANTI,
    JOIN_CROSS,
)
from komira_optimizer.optimizer_stats import (
    estimate_cardinality,
    estimate_row_width,
    _apply_selectivity_ceil,
    _ceil_div,
    DEFAULT_ROW_COUNT,
)


# =============================================================================
# Helpers
# =============================================================================


def _schema1(name: String) -> Schema:
    var b = SchemaBuilder()
    b.add_field(Field(name, ArrowType.INT64, False))
    return b.build()


def _scan(name: String, var rows: Optional[Int]) -> LogicalPlan:
    """One INT64 column `name`, no filter, no stats."""
    var proj: Optional[List[String]] = None
    var filt: Optional[Expr] = None
    return LogicalPlan.scan(
        name + ".parquet", SOURCE_PARQUET, _schema1(name), proj^, filt^, rows^
    )


def _scan_n(name: String, n: Int) -> LogicalPlan:
    return _scan(name, Optional[Int](n))


def _gt(name: String) -> Expr:
    """A range predicate: 30% with no stats."""
    return Expr.binary(BIN_GT, Expr.col_ref(name), Expr.literal(ScalarValue.from_int(5)))


def _agg(var child: LogicalPlan, grouped: Bool) -> LogicalPlan:
    """COUNT(*) over `child`, grouped by its column `a` when `grouped`."""
    var keys = ExprArray()
    if grouped:
        keys.append(Expr.col_ref("a"))
    var aggs = AggExprArray()
    var none_child: Optional[Expr] = None
    aggs.append(AggExpr(AGG_COUNT, none_child^, Optional[String](String("n"))))
    return LogicalPlan.aggregate(keys^, aggs^, child^)


def _join(var l: LogicalPlan, var r: LogicalPlan, jt: UInt8) -> LogicalPlan:
    var lk = List[String]()
    var rk = List[String]()
    if jt != JOIN_CROSS:
        lk.append("a")
        rk.append("b")
    return LogicalPlan.join(l^, r^, lk^, rk^, jt)


def _zero_rows(name: String) -> LogicalPlan:
    """`LIMIT 0` is the one plan shape whose estimate is 0."""
    return LogicalPlan.limit(0, _scan_n(name, 10))


def _keys_a() -> List[String]:
    var k = List[String]()
    k.append("a")
    return k^


def _desc1() -> List[Bool]:
    var d = List[Bool]()
    d.append(False)
    return d^


# =============================================================================
# Scans
# =============================================================================


def test_scan_without_row_count_uses_default() raises:
    """Catches: the default changed or an unset row_count read as 0."""
    assert_equal(estimate_cardinality(_scan("a", None)), DEFAULT_ROW_COUNT)
    assert_equal(DEFAULT_ROW_COUNT, 1_000_000)


def test_empty_scan_is_clamped_to_one() raises:
    """row_count 0 with no filter. Catches: the scan's `base < 1` clamp
    removed (a 0-row leaf makes every join product 0)."""
    assert_equal(estimate_cardinality(_scan_n("a", 0)), 1)


def test_empty_filtered_scan_is_one() raises:
    """row_count 0 with a pushed filter goes through the card<1 arm of
    `_apply_selectivity_ceil`. Catches: a filtered empty scan estimated
    as 0."""
    var proj: Optional[List[String]] = None
    var filt: Optional[Expr] = Optional[Expr](_gt("a"))
    var rows: Optional[Int] = Optional[Int](0)
    var s = LogicalPlan.scan("a.parquet", SOURCE_PARQUET, _schema1("a"), proj^, filt^, rows^)
    assert_equal(estimate_cardinality(s), 1)


# =============================================================================
# Filters
# =============================================================================


def test_having_filter_is_one_percent_ceil() raises:
    """Filter over a grouped Aggregate of 1050 rows: groups 105, HAVING
    ceil(105 / 100) = 2. Catches: HAVING treated as a generic filter
    (ceil(105 * 0.3) = 32) and floor division (1)."""
    var f = LogicalPlan.filter(_gt("n"), _agg(_scan_n("a", 1050), True))
    assert_equal(estimate_cardinality(f), 2)


def test_generic_filter_through_project_ceils() raises:
    """Filter(range) over Project over 7 rows: ceil(7 * 0.3) = 3; the
    Project passes 7 through. Catches: Project changing the count and
    the generic filter flooring (2)."""
    var exprs = ExprArray()
    exprs.append(Expr.col_ref("a"))
    var p = LogicalPlan.project(exprs^, _scan_n("a", 7))
    var f = LogicalPlan.filter(_gt("a"), p^)
    assert_equal(estimate_cardinality(f), 3)


def test_filter_over_empty_child_is_one() raises:
    """Filter over LIMIT 0. Catches: a 0-row child estimated as 0 rows."""
    var f = LogicalPlan.filter(_gt("a"), _zero_rows("a"))
    assert_equal(estimate_cardinality(f), 1)


# =============================================================================
# Aggregates
# =============================================================================


def test_scalar_aggregate_is_one_row() raises:
    """No group-by: one row. Catches: the scalar arm using the 10% rule
    (100)."""
    assert_equal(estimate_cardinality(_agg(_scan_n("a", 1000), False)), 1)


def test_grouped_aggregate_is_ten_percent() raises:
    """Catches: AGG_REDUCTION_FACTOR changed or the grouped arm passing
    the input count through."""
    assert_equal(estimate_cardinality(_agg(_scan_n("a", 1000), True)), 100)


def test_grouped_aggregate_of_few_rows_is_one() raises:
    """5 // 10 = 0 is clamped. Catches: the grouped clamp removed."""
    assert_equal(estimate_cardinality(_agg(_scan_n("a", 5), True)), 1)


# =============================================================================
# Joins
# =============================================================================


def test_semi_and_anti_joins_are_thirty_percent_of_left() raises:
    """Catches: SEMI or ANTI using the inner max rule (200), or the
    right side's count."""
    var semi = _join(_scan_n("a", 100), _scan_n("b", 200), JOIN_SEMI)
    var anti = _join(_scan_n("a", 100), _scan_n("b", 200), JOIN_ANTI)
    assert_equal(estimate_cardinality(semi), 30)
    assert_equal(estimate_cardinality(anti), 30)


def test_semi_join_of_one_row_is_one() raises:
    """1 * 3 // 10 = 0 is clamped. Catches: the semi/anti clamp removed."""
    var semi = _join(_scan_n("a", 1), _scan_n("b", 200), JOIN_SEMI)
    assert_equal(estimate_cardinality(semi), 1)


def test_cross_join_is_the_product() raises:
    """Catches: CROSS estimated by the inner max rule (20)."""
    var c = _join(_scan_n("a", 10), _scan_n("b", 20), JOIN_CROSS)
    assert_equal(estimate_cardinality(c), 200)


def test_cross_join_with_empty_side_is_one() raises:
    """Catches: the CROSS clamp removed (0 * 20 = 0)."""
    var c = _join(_zero_rows("a"), _scan_n("b", 20), JOIN_CROSS)
    assert_equal(estimate_cardinality(c), 1)


def test_inner_join_is_the_larger_side_either_way() raises:
    """Catches: the max taken from one side only."""
    var j1 = _join(_scan_n("a", 10), _scan_n("b", 20), JOIN_INNER)
    var j2 = _join(_scan_n("a", 20), _scan_n("b", 10), JOIN_INNER)
    assert_equal(estimate_cardinality(j1), 20)
    assert_equal(estimate_cardinality(j2), 20)


def test_outer_join_of_empty_sides_is_one() raises:
    """LEFT join of two LIMIT 0 inputs. Catches: the equi-join clamp
    removed."""
    var j = _join(_zero_rows("a"), _zero_rows("b"), JOIN_LEFT)
    assert_equal(estimate_cardinality(j), 1)


# =============================================================================
# Sort, limit, distinct, topn, unknown
# =============================================================================


def test_sort_and_distinct_pass_the_count_through() raises:
    """Catches: either arm missing (falling to the 1M default)."""
    var s = LogicalPlan.sort(_keys_a(), _desc1(), _scan_n("a", 42))
    var none_cols: Optional[List[String]] = None
    var d = LogicalPlan.distinct(none_cols^, _scan_n("a", 42))
    assert_equal(estimate_cardinality(s), 42)
    assert_equal(estimate_cardinality(d), 42)


def test_limit_takes_the_smaller_of_n_and_child() raises:
    """Catches: the limit comparison inverted."""
    var small = LogicalPlan.limit(5, _scan_n("a", 42))
    var big = LogicalPlan.limit(100, _scan_n("a", 42))
    assert_equal(estimate_cardinality(small), 5)
    assert_equal(estimate_cardinality(big), 42)


def test_topn_takes_the_smaller_of_n_and_child() raises:
    """Catches: the topn comparison inverted or topn ignoring n."""
    var small = LogicalPlan.topn(_keys_a(), _desc1(), 5, _scan_n("a", 42))
    var big = LogicalPlan.topn(_keys_a(), _desc1(), 100, _scan_n("a", 42))
    assert_equal(estimate_cardinality(small), 5)
    assert_equal(estimate_cardinality(big), 42)


def test_unknown_tag_uses_default() raises:
    """A view reference has no arm. Catches: the fallback changed."""
    var v = LogicalPlan.view_ref("v", _schema1("a"))
    assert_equal(estimate_cardinality(v), DEFAULT_ROW_COUNT)


# =============================================================================
# Ceil helpers (guards no plan reaches)
# =============================================================================


def test_apply_selectivity_ceil() raises:
    """10 * 0.25 = 2.5 lifts to 3; 10 * 0.5 = 5 stays; card 0 gives 1.
    Catches: the ceil lift removed, a lift on exact products, and the
    card<1 guard returning 0."""
    assert_equal(_apply_selectivity_ceil(10, 0.25), 3)
    assert_equal(_apply_selectivity_ceil(10, 0.5), 5)
    assert_equal(_apply_selectivity_ceil(0, 0.5), 1)


def test_ceil_div_guards() raises:
    """250/100 ceils to 3; a zero denominator and a zero numerator give
    1. Catches: floor division, a division by zero, and the raw<1 clamp
    removed."""
    assert_equal(_ceil_div(250, 100), 3)
    assert_equal(_ceil_div(5, 0), 1)
    assert_equal(_ceil_div(0, 100), 1)


# =============================================================================
# estimate_row_width: one column per width class
# =============================================================================


def _width_of(t: ArrowType) -> Int:
    var b = SchemaBuilder()
    b.add_field(Field("c", t, True))
    return estimate_row_width(b.build())


def test_row_width_one_byte_types() raises:
    """col 1 + overhead 1 + HT entry 32. Catches: any of BOOL/INT8/UINT8
    dropped from the 1-byte class (it would become 8)."""
    assert_equal(_width_of(ArrowType.BOOL), 34)
    assert_equal(_width_of(ArrowType.INT8), 34)
    assert_equal(_width_of(ArrowType.UINT8), 34)


def test_row_width_two_byte_types() raises:
    """Catches: INT16 or UINT16 dropped from the 2-byte class."""
    assert_equal(_width_of(ArrowType.INT16), 35)
    assert_equal(_width_of(ArrowType.UINT16), 35)


def test_row_width_four_byte_types() raises:
    """Catches: any of INT32/UINT32/FLOAT32/DATE32 dropped from the
    4-byte class."""
    assert_equal(_width_of(ArrowType.INT32), 37)
    assert_equal(_width_of(ArrowType.UINT32), 37)
    assert_equal(_width_of(ArrowType.FLOAT32), 37)
    assert_equal(_width_of(ArrowType.DATE32), 37)


def test_row_width_eight_byte_types() raises:
    """Every member of the 8-byte class. These equal the fallback width,
    so this test reaches each `or` term rather than distinguishing it;
    the fallback test below pins the else arm."""
    assert_equal(_width_of(ArrowType.INT64), 41)
    assert_equal(_width_of(ArrowType.UINT64), 41)
    assert_equal(_width_of(ArrowType.FLOAT64), 41)
    assert_equal(_width_of(ArrowType.DATE64), 41)
    assert_equal(_width_of(ArrowType.TIMESTAMP), 41)
    assert_equal(_width_of(ArrowType.TIMESTAMP_S), 41)
    assert_equal(_width_of(ArrowType.TIMESTAMP_MS), 41)
    assert_equal(_width_of(ArrowType.TIMESTAMP_US), 41)
    assert_equal(_width_of(ArrowType.TIMESTAMP_NS), 41)


def test_row_width_variable_length_types() raises:
    """Catches: any of STRING/BINARY/LARGE_STRING/LARGE_BINARY dropped
    from the 16-byte class."""
    assert_equal(_width_of(ArrowType.STRING), 49)
    assert_equal(_width_of(ArrowType.BINARY), 49)
    assert_equal(_width_of(ArrowType.LARGE_STRING), 49)
    assert_equal(_width_of(ArrowType.LARGE_BINARY), 49)


def test_row_width_dictionary_and_fallback() raises:
    """DICTIONARY is its 4-byte index; DECIMAL128 takes the 8-byte
    fallback. Catches: the dictionary arm removed (8) and the fallback
    width changed."""
    assert_equal(_width_of(ArrowType.DICTIONARY), 37)
    assert_equal(_width_of(ArrowType.DECIMAL128), 41)


def test_row_width_sums_columns() raises:
    """BOOL + STRING: (1+1) + (16+1) + 32. Catches: the width taken from
    one column only, or the per-column overhead dropped."""
    var b = SchemaBuilder()
    b.add_field(Field("x", ArrowType.BOOL, True))
    b.add_field(Field("y", ArrowType.STRING, True))
    assert_equal(estimate_row_width(b.build()), 51)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
