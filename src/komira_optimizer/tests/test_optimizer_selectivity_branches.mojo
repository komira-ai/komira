# =============================================================================
# optimizer_filter_selectivity: every predicate arm and the NDV cap
# =============================================================================
#
# The welded selectivity tests cover the LIKE shapes, ranges, AND, OR and
# NOT. This file reaches the remaining arms of `_selectivity_of`
# (literals, NE, both sides of an equality, the NDV guards, IN-lists,
# REGEXP, BETWEEN, bare column references, arithmetic and unknown tags),
# the floor clamp of `compute_selectivity`, and every field copy of
# `scale_table_stats_for_selectivity`.
#
# Each test names the defect it catches. Values that are products of
# non-dyadic constants are compared with a 1e-12 tolerance.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_plan_expr.expr import (
    Expr,
    EXPR_BETWEEN,
    BIN_ADD,
    BIN_EQ,
    BIN_NE,
    BIN_LT,
    BIN_AND,
    UN_NEGATE,
    UN_IS_NULL,
    UN_IS_NOT_NULL,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_stats.table_stats import (
    TableStats,
    ColumnStats,
    STATS_SOURCE_PARQUET_METADATA,
)
from komira_optimizer.optimizer_filter_selectivity import (
    compute_selectivity,
    scale_table_stats_for_selectivity,
    MIN_SELECTIVITY,
)


# =============================================================================
# Helpers
# =============================================================================


def _near(a: Float64, b: Float64) -> Bool:
    var d = a - b
    if d < 0.0:
        d = -d
    return d < 1.0e-12


def _no_stats() -> Optional[TableStats]:
    return Optional[TableStats]()


def _stats_one(name: String, var dc: Optional[Int]) -> Optional[TableStats]:
    """Stats for one column `name` whose distinct_count is `dc`."""
    var names = List[String]()
    names.append(name)
    var cols = List[ColumnStats]()
    cols.append(ColumnStats(dc^))
    return Optional[TableStats](
        TableStats(1000, names^, cols^, STATS_SOURCE_PARQUET_METADATA)
    )


def _lit_int(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _in_list(var child: Expr, n: Int) -> Expr:
    var values = List[ScalarValue]()
    for i in range(n):
        values.append(ScalarValue.from_int(i))
    return Expr.in_list_node(child^, values^)


# =============================================================================
# Literals and the clamp
# =============================================================================


def test_literal_true_keeps_every_row() raises:
    """Catches: the bool-literal arm inverted or falling to the 50% default."""
    var p = Expr.literal(ScalarValue.from_bool(True))
    assert_true(_near(compute_selectivity(p, _no_stats()), 1.0))


def test_literal_false_is_clamped_to_min_selectivity() raises:
    """`WHERE false` gives raw 0.0; compute_selectivity lifts it to
    MIN_SELECTIVITY. Catches: the false arm returning 1.0, and the floor
    clamp removed (a 0.0 selectivity floors downstream cardinalities to 0).
    """
    var p = Expr.literal(ScalarValue.from_bool(False))
    var s = compute_selectivity(p, _no_stats())
    assert_true(_near(s, MIN_SELECTIVITY))
    assert_true(s > 0.0)


def test_non_bool_literal_is_unknown() raises:
    """Catches: a non-bool literal read as a bool gate (0.0 or 1.0)."""
    assert_true(_near(compute_selectivity(_lit_int(7), _no_stats()), 0.5))


# =============================================================================
# Equality, inequality and the NDV guards
# =============================================================================


def test_ne_without_stats_is_ninety_percent() raises:
    """Catches: BIN_NE not complementing the 10% equality default."""
    var p = Expr.binary(BIN_NE, Expr.col_ref("c"), _lit_int(1))
    assert_true(_near(compute_selectivity(p, _no_stats()), 0.9))


def test_ne_with_ndv_is_one_minus_inverse_ndv() raises:
    """NDV 4: 1 - 1/4. Catches: NE ignoring the NDV path."""
    var p = Expr.binary(BIN_NE, Expr.col_ref("c"), _lit_int(1))
    var s = compute_selectivity(p, _stats_one("c", Optional[Int](4)))
    assert_true(_near(s, 0.75))


def test_eq_literal_on_left_uses_ndv() raises:
    """`5 == c` with NDV 5 gives 1/5. Catches: only the col-on-left
    shape detected (the mirrored shape would fall to 10%)."""
    var p = Expr.binary(BIN_EQ, _lit_int(5), Expr.col_ref("c"))
    var s = compute_selectivity(p, _stats_one("c", Optional[Int](5)))
    assert_true(_near(s, 0.2))


def test_eq_between_two_columns_is_default() raises:
    """`a == c` names no literal side. Catches: a col-col equality read
    as `col == lit` and divided by NDV(c) = 5 (0.2)."""
    var p = Expr.binary(BIN_EQ, Expr.col_ref("a"), Expr.col_ref("c"))
    var s = compute_selectivity(p, _stats_one("c", Optional[Int](5)))
    assert_true(_near(s, 0.1))


def test_eq_column_absent_from_stats_is_default() raises:
    """Catches: a missing column read as NDV 1 or 0 instead of None."""
    var p = Expr.binary(BIN_EQ, Expr.col_ref("c"), _lit_int(1))
    var s = compute_selectivity(p, _stats_one("other", Optional[Int](5)))
    assert_true(_near(s, 0.1))


def test_eq_column_without_distinct_count_is_default() raises:
    """Catches: an unset distinct_count unwrapped as a value."""
    var p = Expr.binary(BIN_EQ, Expr.col_ref("c"), _lit_int(1))
    var s = compute_selectivity(p, _stats_one("c", Optional[Int]()))
    assert_true(_near(s, 0.1))


def test_eq_zero_ndv_is_default() raises:
    """NDV 0 must not divide. Catches: the `ndv < 1` guard removed
    (1/0 is inf, clamped to 1.0)."""
    var p = Expr.binary(BIN_EQ, Expr.col_ref("c"), _lit_int(1))
    var s = compute_selectivity(p, _stats_one("c", Optional[Int](0)))
    assert_true(_near(s, 0.1))


# =============================================================================
# Other binary and unary operators
# =============================================================================


def test_arithmetic_binary_op_is_unknown() raises:
    """Catches: arithmetic in predicate position taken as a range (30%)."""
    var p = Expr.binary(BIN_ADD, Expr.col_ref("c"), _lit_int(1))
    assert_true(_near(compute_selectivity(p, _no_stats()), 0.5))


def test_is_null_and_is_not_null() raises:
    """Catches: the IS NULL / IS NOT NULL arms swapped."""
    var p1 = Expr.unary(UN_IS_NULL, Expr.col_ref("c"))
    var p2 = Expr.unary(UN_IS_NOT_NULL, Expr.col_ref("c"))
    assert_true(_near(compute_selectivity(p1, _no_stats()), 0.05))
    assert_true(_near(compute_selectivity(p2, _no_stats()), 0.95))


def test_other_unary_op_is_unknown() raises:
    """Catches: a non-boolean unary op (negate) taken as NOT."""
    var p = Expr.unary(UN_NEGATE, Expr.col_ref("c"))
    assert_true(_near(compute_selectivity(p, _no_stats()), 0.5))


# =============================================================================
# REGEXP, IN-list, BETWEEN, bare columns, unknown tags
# =============================================================================


def test_regexp_is_string_pattern_default() raises:
    """Catches: REGEXP falling through to the 50% default."""
    var p = Expr.regexp_like(Expr.col_ref("c"), "a.*b")
    assert_true(_near(compute_selectivity(p, _no_stats()), 0.2))


def test_in_list_without_stats_is_ten_percent_per_value() raises:
    """Catches: the per-value default not multiplied by the list size."""
    var p = _in_list(Expr.col_ref("c"), 2)
    assert_true(_near(compute_selectivity(p, _no_stats()), 0.2))


def test_in_list_with_ndv_uses_inverse_ndv() raises:
    """3 values, NDV 20: 3/20. Catches: IN ignoring NDV."""
    var p = _in_list(Expr.col_ref("c"), 3)
    var s = compute_selectivity(p, _stats_one("c", Optional[Int](20)))
    assert_true(_near(s, 0.15))


def test_in_list_is_capped_before_and_composes() raises:
    """3 values over NDV 2 is 1.5 before the cap. Under AND with a 30%
    range the result is 1.0 * 0.3. Catches: the IN-list cap removed
    (1.5 * 0.3 = 0.45; the outer clamp alone cannot hide it under AND)."""
    var inl = _in_list(Expr.col_ref("c"), 3)
    var rng = Expr.binary(BIN_LT, Expr.col_ref("c"), _lit_int(9))
    var p = Expr.binary(BIN_AND, inl^, rng^)
    var s = compute_selectivity(p, _stats_one("c", Optional[Int](2)))
    assert_true(_near(s, 0.3))


def test_in_list_non_column_child_is_default() raises:
    """A positional child has no name to look up. Catches: the
    `child.tag != EXPR_COL_REF` guard removed."""
    var p = _in_list(Expr.col_idx(0), 2)
    var s = compute_selectivity(p, _stats_one("c", Optional[Int](20)))
    assert_true(_near(s, 0.2))


def test_in_list_ndv_guards() raises:
    """Absent column, unset distinct_count and NDV 0 all give the 10%
    per-value default. Catches: any of the three guards removed (NDV 0
    would give inf, capped to 1.0)."""
    var p1 = _in_list(Expr.col_ref("c"), 2)
    var p2 = _in_list(Expr.col_ref("c"), 2)
    var p3 = _in_list(Expr.col_ref("c"), 2)
    var s1 = compute_selectivity(p1, _stats_one("other", Optional[Int](20)))
    var s2 = compute_selectivity(p2, _stats_one("c", Optional[Int]()))
    var s3 = compute_selectivity(p3, _stats_one("c", Optional[Int](0)))
    assert_true(_near(s1, 0.2))
    assert_true(_near(s2, 0.2))
    assert_true(_near(s3, 0.2))


def test_between_is_twenty_five_percent() raises:
    """Catches: BETWEEN falling to the 50% default."""
    var p = Expr(EXPR_BETWEEN)
    assert_true(_near(compute_selectivity(p, _no_stats()), 0.25))


def test_bare_column_references_are_not_null_like() raises:
    """`WHERE bool_col` by name and by index. Catches: either tag of the
    `EXPR_COL_REF or EXPR_COL_IDX` test dropped."""
    var p1 = Expr.col_ref("flag")
    var p2 = Expr.col_idx(0)
    assert_true(_near(compute_selectivity(p1, _no_stats()), 0.95))
    assert_true(_near(compute_selectivity(p2, _no_stats()), 0.95))


def test_unmodelled_tag_is_unknown() raises:
    """A CAST in predicate position. Catches: the final fallback changed."""
    var p = Expr.cast(Expr.col_ref("c"), DType.bool)
    assert_true(_near(compute_selectivity(p, _no_stats()), 0.5))


# =============================================================================
# scale_table_stats_for_selectivity
# =============================================================================


def _three_column_stats() -> TableStats:
    """a: every field set, NDV 100. b: NDV 5 only. c: nothing set."""
    var names = List[String]()
    names.append("a")
    names.append("b")
    names.append("c")
    var regs = List[UInt8]()
    regs.append(1)
    regs.append(2)
    regs.append(3)
    var cols = List[ColumnStats]()
    cols.append(
        ColumnStats(
            Optional[Int](100),
            Optional[ScalarValue](ScalarValue.from_int(1)),
            Optional[ScalarValue](ScalarValue.from_int(9)),
            Optional[Int](3),
            Optional[List[UInt8]](regs^),
        )
    )
    cols.append(ColumnStats(Optional[Int](5)))
    cols.append(ColumnStats())
    return TableStats(1000, names^, cols^, STATS_SOURCE_PARQUET_METADATA)


def test_scale_caps_only_ndv_above_the_card() raises:
    """card 10: a's NDV 100 becomes 10, b's NDV 5 stays, c stays unset.
    Catches: the cap skipped, applied to every column (b would become
    10), or an unset NDV turned into the card."""
    var s = scale_table_stats_for_selectivity(_three_column_stats(), 10)
    assert_equal(s.column_distinct_count("a").value(), 10)
    assert_equal(s.column_distinct_count("b").value(), 5)
    assert_false(Bool(s.column_distinct_count("c")))


def test_scale_preserves_other_fields() raises:
    """min/max/null_count/hll_registers, names, row_count and source are
    copied unchanged. Catches: any of the four optional copies dropped
    or filled for a column that had none, and row_count overwritten by
    the post-filter card."""
    var s = scale_table_stats_for_selectivity(_three_column_stats(), 10)
    assert_equal(s.row_count, 1000)
    assert_equal(s.source, STATS_SOURCE_PARQUET_METADATA)
    assert_equal(len(s.column_names), 3)
    assert_equal(s.column_names[2], String("c"))
    ref a = s.column_stats[0]
    assert_equal(a.min_value.value().int_val, Int64(1))
    assert_equal(a.max_value.value().int_val, Int64(9))
    assert_equal(a.null_count.value(), 3)
    ref h = a.hll_registers.value()
    assert_equal(len(h), 3)
    assert_equal(h[0], UInt8(1))
    assert_equal(h[2], UInt8(3))
    ref c = s.column_stats[2]
    assert_false(Bool(c.min_value))
    assert_false(Bool(c.max_value))
    assert_false(Bool(c.null_count))
    assert_false(Bool(c.hll_registers))


def test_scale_degenerate_card_keeps_stats() raises:
    """card 0 violates the caller contract; the stats come back as they
    were. Catches: the guard removed (every NDV would be capped to 0)."""
    var s = scale_table_stats_for_selectivity(_three_column_stats(), 0)
    assert_equal(s.column_distinct_count("a").value(), 100)
    assert_equal(s.column_distinct_count("b").value(), 5)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
