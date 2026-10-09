# =============================================================================
# Regression tests for EXPR_WHEN handling in optimizer helpers (the Q8 fix).
# =============================================================================
#
# Root bug: `_collect_expr_columns`, `_expr_fingerprint` (both now in
# `komira_plan_ir.plan_helpers`) and `_substitute_col_refs` did NOT have
# EXPR_WHEN arms — a projection-pushdown pass would silently prune
# any column referenced ONLY inside a `when_then_else(...)` expression, and
# Rule 13 (absorb-expr-into-agg) would silently leave un-substituted
# col_refs inside CASE/WHEN children. This regression test pins the fix.
#
# Surfaced by the TPC-H Q8 plan shape:
#   `with_column(when_then_else(col("n_name") == "BRAZIL", l_disc_price, 0))`
#   over a 7-way-join chain caused projection-pushdown to drop `n_name`
#   from the upstream join chain, and a later lookup of `n_name` failed at
#   `Schema.column_index: no field named 'n_name'`.
#
# Each helper has a paired test:
#   1. test_collect_expr_columns_when_then_else
#       — verifies condition + then-branch + else-branch column refs are
#         all collected.
#   2. test_collect_expr_columns_when_multi_case
#       — multi-case CASE/WHEN: every condition + result + default contributes.
#   3. test_expr_fingerprint_when_then_else
#       — fingerprint includes condition / result / default identifiers.
#   4. test_expr_fingerprint_when_distinguishes_branches
#       — different branches produce distinct fingerprints (ordering matters).
#   5. test_substitute_col_refs_when_then_else
#       — substitution reaches into condition and both branches.
#   6. test_projection_pushdown_preserves_when_columns_e2e
#       — `_collect_expr_columns` over a Project's expression list keeps a
#         column referenced only inside the WHEN. This is the expression
#         shape that broke TPC-H Q8.
# =============================================================================

from std.collections import Set
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.expr import (
    Expr,
    EXPR_COL_REF,
    EXPR_WHEN,
    WhenCaseData,
)
from komira_plan_expr.col_expr import col, lit, when_then_else
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    SOURCE_PARQUET,
    PLAN_SCAN,
    PLAN_PROJECT,
    PLAN_FILTER,
)
from komira_plan_ir.plan_helpers import (
    _collect_expr_columns,
    _expr_fingerprint,
)
# Rule 13's substitution is now `substitute_project_refs`:
# the old `plan_helpers._substitute_col_refs`
# copy returned a MathFn / string / window node as built and is deleted.
from komira_optimizer.optimizer_project_merge_guard import (
    substitute_project_refs,
)


# =============================================================================
# Helpers
# =============================================================================

def _make_when_three_cols() -> Expr:
    """Build `when_then_else(col(c) == "BRAZIL", col(t), col(e))`.

    All three sub-expressions reference distinct column names so we can
    verify that every recursion arm fires.
    """
    var cond = Expr.binary(
        2,  # BIN_EQ
        Expr.col_ref("c"),
        Expr.literal(ScalarValue.from_string("BRAZIL")),
    )
    var then_branch = Expr.col_ref("t")
    var else_branch = Expr.col_ref("e")
    return when_then_else(cond^, then_branch^, else_branch^)


def _make_when_multi_case() -> Expr:
    """Build a multi-case CASE/WHEN: 2 cases + default, all with col refs.

    Shape:
        WHEN col(a) > col(b) THEN col(t1)
        WHEN col(c) > 0      THEN col(t2)
        ELSE col(d)

    Each case condition + result and the default branch references a
    distinct column, so we can verify all 6 columns surface.
    """
    var cases = List[WhenCaseData]()
    var c1_cond = Expr.binary(  # BIN_GT
        4,
        Expr.col_ref("a"),
        Expr.col_ref("b"),
    )
    cases.append(WhenCaseData(c1_cond^, Expr.col_ref("t1")))
    var c2_cond = Expr.binary(
        4,
        Expr.col_ref("c"),
        Expr.literal(ScalarValue.from_int(0)),
    )
    cases.append(WhenCaseData(c2_cond^, Expr.col_ref("t2")))
    return Expr.when(cases^, Expr.col_ref("d"))


def _make_q8_shape_schema() -> Schema:
    """Mimic the post-7-join Q8 schema: includes n_name + volume + ..."""
    var b = SchemaBuilder()
    b.add_field(Field("n_name", ArrowType.STRING, False))
    b.add_field(Field("volume", ArrowType.FLOAT64, False))
    b.add_field(Field("order_year", ArrowType.INT32, False))
    return b.build()


# =============================================================================
# _collect_expr_columns tests
# =============================================================================

def test_collect_expr_columns_when_then_else() raises:
    """when_then_else(col("c") == "BRAZIL", col("t"), col("e")) — all three
    column refs must surface from `_collect_expr_columns`. Pre-fix this
    returned an empty set."""
    var expr = _make_when_three_cols()
    var cols = Set[String]()
    _collect_expr_columns(expr, cols)
    assert_true("c" in cols, msg="condition col ref 'c' must be collected")
    assert_true("t" in cols, msg="then-branch col ref 't' must be collected")
    assert_true("e" in cols, msg="else-branch col ref 'e' must be collected")
    assert_equal(len(cols), 3)


def test_collect_expr_columns_when_multi_case() raises:
    """Multi-case CASE/WHEN: 6 distinct cols across 2 conditions, 2 results,
    and the default branch — all must surface."""
    var expr = _make_when_multi_case()
    var cols = Set[String]()
    _collect_expr_columns(expr, cols)
    assert_true("a" in cols)
    assert_true("b" in cols)
    assert_true("t1" in cols)
    assert_true("c" in cols)
    assert_true("t2" in cols)
    assert_true("d" in cols)
    assert_equal(len(cols), 6)


# =============================================================================
# _expr_fingerprint tests
# =============================================================================

def test_expr_fingerprint_when_then_else() raises:
    """Fingerprint must include every sub-expression. Pre-fix this returned
    `?:8` (the unknown-tag fallback), so two semantically-different WHEN
    expressions would collide as identical."""
    var expr = _make_when_three_cols()
    var fp = _expr_fingerprint(expr)
    # The fingerprint must contain markers for every child column.
    assert_true("c" in fp, msg="fingerprint must reference condition column")
    assert_true("t" in fp, msg="fingerprint must reference then-branch column")
    assert_true("e" in fp, msg="fingerprint must reference else-branch column")
    # Must not be the unknown-tag fallback.
    assert_false(fp == "?:8", msg="fingerprint regressed to unknown-tag fallback")


def test_expr_fingerprint_when_distinguishes_branches() raises:
    """Two WHEN expressions with the same condition but different
    then/else branches must fingerprint differently — order matters in
    CASE/WHEN semantics."""
    var fp_a = _expr_fingerprint(_make_when_three_cols())
    # Build the swapped-branches variant: same condition, then/else flipped.
    var cond2 = Expr.binary(
        2,
        Expr.col_ref("c"),
        Expr.literal(ScalarValue.from_string("BRAZIL")),
    )
    var swapped = when_then_else(
        cond2^,
        Expr.col_ref("e"),  # was 't'
        Expr.col_ref("t"),  # was 'e'
    )
    var fp_b = _expr_fingerprint(swapped)
    assert_false(
        fp_a == fp_b,
        msg="swapped then/else must produce different fingerprints",
    )


# =============================================================================
# _substitute_col_refs tests
# =============================================================================

def test_substitute_col_refs_when_then_else() raises:
    """Rule 13's substitution replaces col_refs by name. Pre-fix the WHEN arm was
    missing, so the substitution (then `_substitute_col_refs`, now
    `substitute_project_refs`) returned the input unchanged when
    the col_ref to substitute was inside a WHEN expression — silently
    leaving stale references in the rewritten plan."""
    var expr = _make_when_three_cols()
    # Substitute "t" -> col("t_renamed").
    var names: List[String] = ["t"]
    var replacement = Expr.col_ref("t_renamed")
    var replacements = ExprArray()
    replacements.append(replacement^)
    var rewritten = substitute_project_refs(expr^, names, replacements)
    # Verify: the rewritten expression's collected cols should now
    # contain "t_renamed" (and not "t").
    var cols = Set[String]()
    _collect_expr_columns(rewritten, cols)
    assert_true("t_renamed" in cols, msg="substitution must reach then-branch")
    assert_false("t" in cols, msg="original 't' must be substituted away")
    # The other refs ('c', 'e') survive unchanged.
    assert_true("c" in cols)
    assert_true("e" in cols)


# =============================================================================
# End-to-end: projection-pushdown preserves columns referenced only inside
# a `when_then_else(...)`.
# =============================================================================

def test_projection_pushdown_preserves_when_columns_e2e() raises:
    """Q8-shape regression: a Project node containing a `when_then_else`
    over a Scan must NOT cause `n_name` to be pruned from the upstream
    scan. Pre-fix `_collect_expr_columns` skipped EXPR_WHEN, projection
    pushdown concluded that `n_name` was unused, pruned it, and a later
    lookup of `n_name` failed with
    `Schema.column_index: no field named 'n_name'`.

    This test exercises the helper directly on a Q8-shape Project's
    expression list — the failing pattern reduces to: `_collect_expr_columns`
    over a list including a `with_column(when_then_else(col("n_name") == ...,
    volume, 0))` aliased Expr."""
    # Build the Q8 with_column expression: n_name reference lives ONLY
    # inside the WHEN condition.
    var market_share_when = when_then_else(
        Expr.binary(
            2,  # BIN_EQ
            Expr.col_ref("n_name"),
            Expr.literal(ScalarValue.from_string("BRAZIL")),
        ),
        Expr.col_ref("volume"),
        Expr.literal(ScalarValue.from_float(0.0)),
    )
    var aliased = Expr.alias(market_share_when^, "brazil_volume")
    # Build a project's expr list as the optimizer sees it.
    var project_exprs = ExprArray()
    project_exprs.append(aliased^)
    project_exprs.append(Expr.col_ref("volume"))
    project_exprs.append(Expr.col_ref("order_year"))
    # Walk the projection's expressions and collect required columns —
    # this is the walk a projection-pushdown pass (`optimizer_projection`,
    # not in this tree) is designed to use for the upstream column
    # requirement set.
    var required = Set[String]()
    for i in range(len(project_exprs)):
        _collect_expr_columns(project_exprs[i], required)
    # n_name MUST surface — pre-fix it would not.
    assert_true(
        "n_name" in required,
        msg="n_name (referenced only inside WHEN condition) was pruned"
        " — projection-pushdown bug not fixed",
    )
    assert_true("volume" in required)
    assert_true("order_year" in required)


# =============================================================================
# Test runner
# =============================================================================

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
