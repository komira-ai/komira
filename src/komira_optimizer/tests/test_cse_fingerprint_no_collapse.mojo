# =============================================================================
# Tests for CSE fingerprint completeness
# =============================================================================
#
# Regression guard for the SYSTEMIC silent-wrong bug class where
# `_expr_fingerprint` let DISTINCT
# expressions of the same tag fingerprint-collide via the bare `?:<tag>`
# fallback, after which the optimizer's CSE Phase A whole-expression dedup
# (optimizer_expr.mojo `_cse_rewrite_project_axis1`, which does NOT gate on
# `_is_cse_eligible`) silently collapsed the later columns to the first.
#
# Headline scenario: `SELECT year(d), month(d), day(d)` returned the YEAR
# value for all three columns because EXPR_EXTRACT had no fingerprint arm.
#
# These tests work at the PLAN level (no `ctx.materialize`): build a
# LogicalPlan Project with 2+ distinct same-tag exprs, run the CSE rule, and
# assert the output columns are NOT collapsed (each retains its own
# discriminator). Plus a POSITIVE regression that GENUINELY-identical exprs
# (x+1, x+1) STILL dedup — the salt must not over-suppress real CSE.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    BIN_ADD,
    EXPR_ALIAS,
    EXPR_BINARY_OP,
    EXPR_CAST,
    EXPR_COL_REF,
    EXPR_STRING_OP,
    Expr,
)
from komira_plan_ir.logical_plan import (
    ExprArray,
    LogicalPlan,
    PLAN_PROJECT,
    PLAN_SCAN,
    SOURCE_PARQUET,
)
from komira_plan_expr.expr import (
    EXPR_EXTRACT,
    EXTRACT_YEAR,
    EXTRACT_MONTH,
    EXTRACT_DAY,
    STR_CONTAINS,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_optimizer.optimizer_expr import eliminate_common_subexpressions
from komira_plan_ir.plan_helpers import _expr_fingerprint


# =============================================================================
# Schema helpers
# =============================================================================

def _date_schema() -> Schema:
    var builder = SchemaBuilder()
    builder.add_field(Field("d", ArrowType.DATE32, False))
    builder.add_field(Field("x", ArrowType.INT64, False))
    return builder.build()


def _string_schema() -> Schema:
    var builder = SchemaBuilder()
    builder.add_field(Field("s", ArrowType.STRING, False))
    builder.add_field(Field("x", ArrowType.INT64, False))
    return builder.build()


# Unwrap an EXPR_ALIAS chain and return the underlying expr's tag. When CSE
# collapses a column, the output becomes `Alias(ColRef("<sibling>"), name)` —
# i.e. the underlying tag is EXPR_COL_REF, NOT the original (EXTRACT / etc.).
def _underlying_tag(expr: Expr) raises -> UInt8:
    if expr.tag == EXPR_ALIAS:
        return _underlying_tag(expr.alias_child_ref())
    return expr.tag


# Count how many of a Project's output exprs have the given underlying tag.
def _count_underlying_tag(plan: LogicalPlan, tag: UInt8) raises -> Int:
    var n = 0
    ref pd = plan._project.value()[]
    for i in range(len(pd.exprs)):
        if _underlying_tag(pd.exprs[i]) == tag:
            n += 1
    return n


# Count how many of a Project's output exprs collapsed to a bare ColRef.
# ⚠ THIS USED TO BE DESCRIBED AS "the silent-collapse signature:
# `Alias(ColRef(sibling))`". A ColRef to a SIBLING output was never a
# legitimate collapse — a Project's exprs resolve against its CHILD's schema,
# so it was unresolvable (the earlier Phase A, deleted
# 2026-09-01). A bare ColRef here now names a `_cse_*` column materialized in
# the Project spliced BELOW, which the child really provides.
def _count_underlying_col_ref(plan: LogicalPlan) raises -> Int:
    return _count_underlying_tag(plan, EXPR_COL_REF)


# The NAME under output expr `i`, alias unwrapped. "" when it is not a ColRef.
def _underlying_col_ref_name(plan: LogicalPlan, i: Int) raises -> String:
    ref e = plan._project.value()[].exprs[i]
    if e.tag == EXPR_ALIAS:
        if e.alias_child_ref().tag == EXPR_COL_REF:
            return e.alias_child_ref().col_ref_name()
        return String("")
    if e.tag == EXPR_COL_REF:
        return e.col_ref_name()
    return String("")


# =============================================================================
# EXPR_EXTRACT: the headline year/month/day collapse
# =============================================================================

def test_extract_year_month_day_not_collapsed() raises:
    """SELECT year(d), month(d), day(d) — all three MUST survive CSE.

    RED before fix: EXPR_EXTRACT had no fingerprint arm, all three
    fingerprinted `"?:20"`, Phase A collapsed month/day to year ->
    only ONE EXPR_EXTRACT survives (2 became Alias(ColRef("y"))).
    GREEN after fix: the `unit` discriminator keeps them distinct ->
    all THREE EXPR_EXTRACT survive.
    """
    var scan = LogicalPlan.scan("dates.parquet", SOURCE_PARQUET, _date_schema())
    var exprs = ExprArray()
    exprs.append(Expr.alias(Expr.extract(EXTRACT_YEAR, Expr.col_ref("d")), "y"))
    exprs.append(Expr.alias(Expr.extract(EXTRACT_MONTH, Expr.col_ref("d")), "m"))
    exprs.append(Expr.alias(Expr.extract(EXTRACT_DAY, Expr.col_ref("d")), "dd"))
    var proj = LogicalPlan.project(exprs^, scan^)

    var result = eliminate_common_subexpressions(proj^)

    assert_true(result.tag == PLAN_PROJECT, "expected Project")
    assert_equal(len(result._project.value()[].exprs), 3,
                 "all 3 output columns must be preserved")
    # All three EXTRACT columns must SURVIVE (not collapse to ColRef).
    assert_equal(_count_underlying_tag(result, EXPR_EXTRACT), 3,
                 "all 3 extract(year/month/day) columns must survive CSE distinctly")
    assert_equal(_count_underlying_col_ref(result), 0,
                 "no extract column may collapse to a bare ColRef (silent-wrong)")


# =============================================================================
# EXPR_STRING_OP: contains("foo") vs contains("bar")
# =============================================================================

def test_string_op_distinct_patterns_not_collapsed() raises:
    """SELECT s.contains("foo"), s.contains("bar") — both MUST survive.

    RED before fix: both fingerprinted `"?:7"`, has_bar collapsed to
    has_foo. GREEN after fix: the pattern discriminator keeps them
    distinct.
    """
    var scan = LogicalPlan.scan("s.parquet", SOURCE_PARQUET, _string_schema())
    var exprs = ExprArray()
    exprs.append(Expr.alias(
        Expr.string_op(STR_CONTAINS, Expr.col_ref("s"), String("foo")), "has_foo"))
    exprs.append(Expr.alias(
        Expr.string_op(STR_CONTAINS, Expr.col_ref("s"), String("bar")), "has_bar"))
    var proj = LogicalPlan.project(exprs^, scan^)

    var result = eliminate_common_subexpressions(proj^)

    assert_true(result.tag == PLAN_PROJECT, "expected Project")
    assert_equal(len(result._project.value()[].exprs), 2, "both columns preserved")
    assert_equal(_count_underlying_tag(result, EXPR_STRING_OP), 2,
                 "both contains(foo)/contains(bar) must survive CSE distinctly")
    assert_equal(_count_underlying_col_ref(result), 0,
                 "neither string-op column may collapse to a bare ColRef")


# =============================================================================
# EXPR_CAST: DECIMAL(10,2) vs DECIMAL(18,4)
# =============================================================================

def test_cast_distinct_decimal_precision_not_collapsed() raises:
    """SELECT cast(x AS DECIMAL(10,2)), cast(x AS DECIMAL(18,4)) — distinct.

    RED before fix: the CAST arm keyed only on the numeric `cast_target()`
    DType, identical across (p,s); both fingerprinted equal and the 2nd
    collapsed. GREEN after fix: target_arrow + decimal p/s in the key.
    """
    var scan = LogicalPlan.scan("d.parquet", SOURCE_PARQUET, _date_schema())
    var exprs = ExprArray()
    exprs.append(Expr.alias(
        Expr.cast_to_decimal(Expr.col_ref("x"), 10, 2), "dec_a"))
    exprs.append(Expr.alias(
        Expr.cast_to_decimal(Expr.col_ref("x"), 18, 4), "dec_b"))
    var proj = LogicalPlan.project(exprs^, scan^)

    var result = eliminate_common_subexpressions(proj^)

    assert_true(result.tag == PLAN_PROJECT, "expected Project")
    assert_equal(len(result._project.value()[].exprs), 2, "both columns preserved")
    assert_equal(_count_underlying_tag(result, EXPR_CAST), 2,
                 "both DECIMAL(10,2)/DECIMAL(18,4) casts must survive distinctly")
    assert_equal(_count_underlying_col_ref(result), 0,
                 "neither cast column may collapse to a bare ColRef")


# =============================================================================
# Fingerprint-level unit checks (direct, no CSE driver)
# =============================================================================

def test_fingerprints_are_distinct_per_discriminator() raises:
    """Direct fingerprint inequality for the discriminated tags."""
    var ey = Expr.extract(EXTRACT_YEAR, Expr.col_ref("d"))
    var em = Expr.extract(EXTRACT_MONTH, Expr.col_ref("d"))
    var ed = Expr.extract(EXTRACT_DAY, Expr.col_ref("d"))
    assert_true(_expr_fingerprint(ey) != _expr_fingerprint(em),
                "year vs month fingerprint must differ")
    assert_true(_expr_fingerprint(em) != _expr_fingerprint(ed),
                "month vs day fingerprint must differ")

    var sf = Expr.string_op(STR_CONTAINS, Expr.col_ref("s"), String("foo"))
    var sb = Expr.string_op(STR_CONTAINS, Expr.col_ref("s"), String("bar"))
    assert_true(_expr_fingerprint(sf) != _expr_fingerprint(sb),
                "contains(foo) vs contains(bar) fingerprint must differ")

    var ca = Expr.cast_to_decimal(Expr.col_ref("x"), 10, 2)
    var cb = Expr.cast_to_decimal(Expr.col_ref("x"), 18, 4)
    assert_true(_expr_fingerprint(ca) != _expr_fingerprint(cb),
                "DECIMAL(10,2) vs DECIMAL(18,4) fingerprint must differ")


# =============================================================================
# ★ POSITIVE regression — genuinely-identical exprs STILL dedup
# =============================================================================

def test_identical_exprs_still_dedup() raises:
    """SELECT x+1 AS p1, x+1 AS p2 — the salt must NOT suppress real CSE.

    Genuinely-identical binary subtrees must still fingerprint EQUAL so the
    duplicate is materialized ONCE.

    ⚠ THIS CASE ASSERTED "one BINARY_OP survives, one collapsed to a ColRef"
    UNTIL 2026-09-01 — the shape Phase A produced, in which the SURVIVING
    ColRef named this Project's own first output ("p1") and could not be
    resolved against the child's schema. Phase A is
    deleted. The dedup is STRONGER now, which is why the numbers moved: the
    shared `x+1` moves into a Project spliced BELOW and BOTH outputs become
    ColRefs to the one synthetic there. Zero BINARY_OPs remain at this level;
    the arithmetic did not vanish, it moved one node down and is computed once.
    """
    var scan = LogicalPlan.scan("d.parquet", SOURCE_PARQUET, _date_schema())
    var e1 = Expr.binary(BIN_ADD, Expr.col_ref("x"), Expr.literal(ScalarValue.from_int(1)))
    var e2 = Expr.binary(BIN_ADD, Expr.col_ref("x"), Expr.literal(ScalarValue.from_int(1)))
    var exprs = ExprArray()
    exprs.append(Expr.alias(e1^, "p1"))
    exprs.append(Expr.alias(e2^, "p2"))
    var proj = LogicalPlan.project(exprs^, scan^)

    # The two identical exprs MUST fingerprint equal (real CSE possible).
    var f1 = _expr_fingerprint(proj._project.value()[].exprs[0])
    var f2 = _expr_fingerprint(proj._project.value()[].exprs[1])
    assert_equal(f1, f2, "identical x+1 exprs must fingerprint equal (real CSE)")

    var result = eliminate_common_subexpressions(proj^)

    assert_true(result.tag == PLAN_PROJECT, "expected Project")
    # BOTH outputs collapse to a ColRef of the one synthetic; the arithmetic
    # lives in the Project spliced below.
    assert_equal(_count_underlying_tag(result, EXPR_BINARY_OP), 0,
                 "identical exprs: no BINARY_OP remains at the user's Project —"
                 " the shared computation moved one node DOWN")
    assert_equal(_count_underlying_col_ref(result), 2,
                 "identical exprs: BOTH outputs reference the single"
                 " materialization")
    # ...and it really is ONE materialization, in scope for both.
    var n0 = _underlying_col_ref_name(result, 0)
    var n1 = _underlying_col_ref_name(result, 1)
    assert_equal(n0, n1, "both outputs name the SAME synthetic")
    assert_true(n0.startswith("_cse_"),
                "the shared value is a CSE synthetic, not a sibling output"
                " name (got '" + n0 + "')")
    assert_true(result._project.value()[].child[].tag == PLAN_PROJECT,
                "the synthetic is materialized in a Project spliced below")
    var below_ncols = result._project.value()[].child[].output_schema.num_columns()
    var in_scope = False
    for i in range(below_ncols):
        if result._project.value()[].child[].output_schema.field_name(i) == n0:
            in_scope = True
    assert_true(in_scope,
                "'" + n0 + "' must be a column of the child's schema — a"
                " Project's exprs resolve against its CHILD, never against a"
                " sibling")


# =============================================================================
# Entry point
# =============================================================================

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
