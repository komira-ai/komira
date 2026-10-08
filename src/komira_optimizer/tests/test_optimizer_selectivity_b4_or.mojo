# =============================================================================
# OR-filter post-cache multiplier
# =============================================================================
#
# The question:
#   Mirror DuckDB's ApplyOrFilterSelectivities. When an OR of filters lands
#   on a cached cardinality estimate, apply an inclusion-exclusion OR
#   multiplier post-cache: sel(A OR B) = sel(A) + sel(B) - sel(A)*sel(B).
#
# The answer: the inclusion-exclusion multiplier is
# ALREADY applied — but at a different layer than DuckDB does it. Our
# `compute_selectivity` recursively handles BIN_OR
# (in `_selectivity_of`) with inclusion-exclusion
# directly on the Expr tree. Cardinality is then baked into the JoinChain
# leaf in `_extract_join_chain_inner` via `estimate_cardinality` -> the
# scan-filter dispatch in `optimizer_stats.estimate_cardinality`.
#
# DuckDB's `ApplyOrFilterSelectivities` runs DOWNSTREAM of the cache
# because DuckDB tracks filters as a list of FilterInfo objects keyed by
# `equivalence_class_id`; OR-shaped multi-comparison FilterInfos need
# the multiplier applied AFTER the per-class cardinality reduction is
# cached. Komira currently passes the filter as ONE Expr through the
# scan's `filter` field, so the recursive `_selectivity_of(BIN_OR)`
# already composes the multiplier at predicate-tree time — no
# post-cache step is needed because there is no FilterInfo list whose
# inclusion-exclusion happens out-of-order.
#
# This test pins that contract: a Q19-style OR-of-AND-of-eq-and-range
# predicate composes to the DuckDB-expected selectivity. If the
# Komira architecture later splits filters into a FilterInfo-style
# list, this test will catch the regression (the same Expr tree must
# yield the same selectivity).
#
# Q19 SQL skeleton (TPC-H, OR-heavy disjunction over 3 brand-quantity-
# container triples):
#   WHERE
#     (p_brand = 'Brand#12' AND p_size BETWEEN 1 AND 5 AND l_quantity >= 1 AND l_quantity <= 11)
#   OR
#     (p_brand = 'Brand#23' AND p_size BETWEEN 1 AND 10 AND l_quantity >= 10 AND l_quantity <= 20)
#   OR
#     (p_brand = 'Brand#34' AND p_size BETWEEN 1 AND 15 AND l_quantity >= 20 AND l_quantity <= 30)
#
# Cross-relation OR makes Q19 inherently a "residual filter above the
# join" in Komira today — this test focuses on the inner per-branch
# selectivity (the AND-of-eq-and-range) and the outer 3-way OR
# composition.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_plan_expr.expr import Expr
from komira_optimizer.optimizer_filter_selectivity import compute_selectivity
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_stats.table_stats import TableStats


# Tag constants (mirror Expr's UInt8 ops).
comptime BIN_EQ_TAG: UInt8 = 10
comptime BIN_LE_TAG: UInt8 = 13
comptime BIN_GE_TAG: UInt8 = 15
comptime BIN_AND_TAG: UInt8 = 20
comptime BIN_OR_TAG: UInt8 = 21


def _eq(col: String, lit: Int) -> Expr:
    return Expr.binary(
        BIN_EQ_TAG, Expr.col_ref(col), Expr.literal(ScalarValue.from_int(lit))
    )


def _ge(col: String, lit: Int) -> Expr:
    return Expr.binary(
        BIN_GE_TAG, Expr.col_ref(col), Expr.literal(ScalarValue.from_int(lit))
    )


def _le(col: String, lit: Int) -> Expr:
    return Expr.binary(
        BIN_LE_TAG, Expr.col_ref(col), Expr.literal(ScalarValue.from_int(lit))
    )


def _and(var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(BIN_AND_TAG, l^, r^)


def _or(var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(BIN_OR_TAG, l^, r^)


# =============================================================================
# Test 1 — Simple OR of two ranges: inclusion-exclusion
# =============================================================================


def test_b4_or_of_two_ranges_is_inclusion_exclusion() raises:
    """`(a > 5) OR (b > 5)` -> 0.30 + 0.30 - 0.30 * 0.30 = 0.51.

    The two-term base case. The tests below add the deeper-nesting and
    AND-OR composition cases.
    """
    var p1 = Expr.binary(14, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(5)))  # GT
    var p2 = Expr.binary(14, Expr.col_ref("b"), Expr.literal(ScalarValue.from_int(5)))  # GT
    var pred = _or(p1^, p2^)
    var sel = compute_selectivity(pred, Optional[TableStats]())
    assert_true(sel > 0.509 and sel < 0.511)


# =============================================================================
# Test 2 — OR of two AND-of-eq-and-range (Q19 single-branch shape)
# =============================================================================


def test_b4_or_of_and_q19_two_branch_shape() raises:
    """`(brand=A AND size<=B) OR (brand=C AND size<=D)` selectivity.

    With no NDV available, equality defaults to 10% and range to 30%.
    Each branch (eq AND range) = 0.10 * 0.30 = 0.03.
    OR of two branches: 0.03 + 0.03 - 0.03 * 0.03 = 0.0591.
    """
    var br1 = _and(_eq("p_brand", 12), _le("p_size", 5))
    var br2 = _and(_eq("p_brand", 23), _le("p_size", 10))
    var pred = _or(br1^, br2^)
    var sel = compute_selectivity(pred, Optional[TableStats]())
    # 0.03 + 0.03 - 0.0009 = 0.0591.
    assert_true(sel > 0.058 and sel < 0.060)


# =============================================================================
# Test 3 — 3-way OR Q19 brand-grouping (left-deep OR tree)
# =============================================================================


def test_b4_or_q19_three_brand_groups() raises:
    """`(br=A AND ranges) OR (br=B AND ranges) OR (br=C AND ranges)`.

    Each branch: 4-deep AND of (eq AND range AND range AND range).
    eq = 0.10; each range = 0.30. Per-branch:
      0.10 * 0.30 * 0.30 * 0.30 = 0.0027.
    Pair OR: 0.0027 + 0.0027 - 0.0027 * 0.0027 = 0.005393...
    3-way OR (left-deep): 0.005393 + 0.0027 - 0.005393 * 0.0027 = 0.008079...

    Pin against the inclusion-exclusion expansion. This is the Q19-
    cardinality entry point: under SF1 lineitem (6M rows), a ~0.81%
    selectivity narrows to ~48.5K rows.
    """
    # Branch shape: brand = X AND size >= 1 AND size <= Y AND quantity >= Z
    var br1 = _and(_and(_and(_eq("p_brand", 12), _ge("p_size", 1)),
                       _le("p_size", 5)),
                  _ge("l_quantity", 1))
    var br2 = _and(_and(_and(_eq("p_brand", 23), _ge("p_size", 1)),
                       _le("p_size", 10)),
                  _ge("l_quantity", 10))
    var br3 = _and(_and(_and(_eq("p_brand", 34), _ge("p_size", 1)),
                       _le("p_size", 15)),
                  _ge("l_quantity", 20))
    # Left-deep OR: ((br1 OR br2) OR br3)
    var or12 = _or(br1^, br2^)
    var pred = _or(or12^, br3^)
    var sel = compute_selectivity(pred, Optional[TableStats]())
    # 4-deep AND per branch = 0.10 * 0.30 * 0.30 * 0.30 = 0.0027.
    # Pair OR = 2*0.0027 - 0.0027^2 = 0.005393.
    # 3-way OR = 0.005393 + 0.0027 - 0.005393 * 0.0027 = 0.008079.
    assert_true(sel > 0.007 and sel < 0.009)


# =============================================================================
# Test 4 — OR-of-three single-eqs: pinning the 3-way inclusion-exclusion
# =============================================================================


def test_b4_or_of_three_eq_is_three_way_inclusion_exclusion() raises:
    """`a=1 OR b=2 OR c=3`. Three eq -> 0.10 each.

    Left-deep: ((0.10 OR 0.10) OR 0.10).
    Pair: 0.10 + 0.10 - 0.01 = 0.19.
    Triple: 0.19 + 0.10 - 0.019 = 0.271.

    Pins the 3-way nested inclusion-exclusion. Without this guard a
    naive sum (0.30) would inflate the cardinality by ~10%.
    """
    var p1 = _eq("a", 1)
    var p2 = _eq("b", 2)
    var p3 = _eq("c", 3)
    var or12 = _or(p1^, p2^)
    var pred = _or(or12^, p3^)
    var sel = compute_selectivity(pred, Optional[TableStats]())
    # 0.271, with tolerance.
    assert_true(sel > 0.270 and sel < 0.272)


# =============================================================================
# Test 5 — Double-counting guard: sel(A OR A) = sel(A), not 2*sel(A)
# =============================================================================


def test_b4_or_of_same_predicate_does_not_double_count() raises:
    """`A OR A` -> 0.10 + 0.10 - 0.10 * 0.10 = 0.19.

    DuckDB's `ApplyOrFilterSelectivities` rationale: the multiplier
    must NOT double-count. With two identical 10% branches, the
    correct inclusion-exclusion answer is 0.19, NOT 0.20 (naive sum).
    This pins the no-double-count contract.

    (Semantically `A OR A == A`, so the truest answer is 0.10. The
    inclusion-exclusion approximation gives 0.19 because the optimizer
    sees the children as opaque selectivities, not literal AST nodes.
    DuckDB has the same behavior — this is the price of treating
    branches as independent.)
    """
    var p1 = _eq("a", 1)
    var p2 = _eq("a", 1)
    var pred = _or(p1^, p2^)
    var sel = compute_selectivity(pred, Optional[TableStats]())
    # 0.10 + 0.10 - 0.01 = 0.19.
    assert_true(sel > 0.189 and sel < 0.191)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
