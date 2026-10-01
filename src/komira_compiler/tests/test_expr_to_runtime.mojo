# =============================================================================
# Tests for the Expr -> RuntimeExpr translator.
#
# Coverage:
#   1. Col-vs-Lit Int64 comparison.
#   2. Col-vs-Lit Float64 comparison.
#   3. AND chain with mixed Int64/Float64 conjuncts (Q6-like shape).
#   4. Lit-on-LEFT canonicalization (mirroring).
#   5. Unsupported shapes return None:
#      - String literal in comparison.
#      - BIN_OR (disjunction).
#      - Mixed-DType comparison.
#      - Column not in schema.
#   6. n_conjuncts counting for AND chains.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_compiler.expr_to_runtime import (
    TranslatedExpr,
    translate_filter_predicate,
)
from komira_core.dtype_sentinel import DTYPE_NONE
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.plan.expr import (
    Expr,
    BIN_AND,
    BIN_OR,
    BIN_GE,
    BIN_GT,
    BIN_LT,
    BIN_LE,
    BIN_EQ,
)
from komira_core.plan.scalar_value import ScalarValue
from komira_eval.runtime_expr import (
    EXPR_AND,
    EXPR_COL,
    EXPR_EQ_I64,
    EXPR_GE_F64,
    EXPR_GE_I64,
    EXPR_GT_F64,
    EXPR_GT_I64,
    EXPR_LE_F64,
    EXPR_LIT_F64,
    EXPR_LIT_I64,
    EXPR_LT_F64,
    EXPR_LT_I64,
)


# -----------------------------------------------------------------------------
# Schema helpers.
# -----------------------------------------------------------------------------


def _build_q6_schema() raises -> Schema:
    """Schema mirroring the Q6 lineitem projection (4 cols):
    l_shipdate (int64), l_discount (float64), l_quantity (float64),
    l_extendedprice (float64).
    """
    var builder = SchemaBuilder()
    builder.add_field(Field("l_shipdate", DType.int64, True))
    builder.add_field(Field("l_discount", DType.float64, True))
    builder.add_field(Field("l_quantity", DType.float64, True))
    builder.add_field(Field("l_extendedprice", DType.float64, True))
    return builder.build()


def _build_int_only_schema() raises -> Schema:
    """Schema with one Int64 column for simple-comparison tests."""
    return Schema.from_fields_1(Field("x", DType.int64, True))


def _build_string_schema() raises -> Schema:
    """Schema with one string column for unsupported-DType tests.

    DTYPE_NONE is the sentinel for Utf8 in ScalarValue / Schema by
    convention.
    """
    return Schema.from_fields_1(Field("name", DTYPE_NONE, True))


# -----------------------------------------------------------------------------
# Test 1 — Col-vs-Lit Int64 (>=).
# -----------------------------------------------------------------------------


def test_translate_col_ge_lit_i64() raises:
    """`x >= 5` over an Int64 column translates to:
       pool = [Col(0), Lit_I64(5), GE_I64(0, 1)]
       root_idx = 2, n_conjuncts = 1.
    """
    var schema = _build_int_only_schema()
    var pred = Expr.binary(
        BIN_GE,
        Expr.col_ref(String("x")),
        Expr.literal(ScalarValue.from_int64(Int64(5))),
    )
    var result = translate_filter_predicate(pred, schema)
    assert_true(result.__bool__())
    ref te = result.value()
    assert_equal(len(te.pool), 3)
    assert_equal(te.root_idx, 2)
    assert_equal(te.n_conjuncts, 1)
    assert_equal(te.pool[0].kind, EXPR_COL)
    assert_equal(te.pool[0].col_idx, 0)
    assert_equal(te.pool[1].kind, EXPR_LIT_I64)
    assert_equal(te.pool[1].i64, Int64(5))
    assert_equal(te.pool[2].kind, EXPR_GE_I64)
    assert_equal(te.pool[2].left, 0)
    assert_equal(te.pool[2].right, 1)


# -----------------------------------------------------------------------------
# Test 2 — Col-vs-Lit Float64 (<).
# -----------------------------------------------------------------------------


def test_translate_col_lt_lit_f64() raises:
    """`l_discount < 0.07` -> EXPR_LT_F64 with EXPR_COL + EXPR_LIT_F64.

    `col_idx` is a
    SLOT INDEX into the `column_names` sidecar (allocated fresh per
    EXPR_COL_REF), NOT a position in the LogicalPlan child schema.
    For this single-col-ref predicate, the col_idx is 0 (first/only
    name in the sidecar), and `column_names[0]` carries "l_discount".
    The walker resolves "l_discount" to the runtime batch position
    via `batch.column_by_name` at evaluation time.
    """
    var schema = _build_q6_schema()
    var pred = Expr.binary(
        BIN_LT,
        Expr.col_ref(String("l_discount")),
        Expr.literal(ScalarValue.from_float(0.07)),
    )
    var result = translate_filter_predicate(pred, schema)
    assert_true(result.__bool__())
    ref te = result.value()
    assert_equal(len(te.pool), 3)
    assert_equal(te.root_idx, 2)
    assert_equal(te.pool[0].kind, EXPR_COL)
    # col_idx is a sidecar slot, not a schema position.
    assert_equal(te.pool[0].col_idx, 0)
    # The name "l_discount" is at sidecar slot 0.
    assert_equal(len(te.column_names), 1)
    assert_equal(te.column_names[0], String("l_discount"))
    assert_equal(te.pool[1].kind, EXPR_LIT_F64)
    assert_true(te.pool[1].f64 > 0.0)
    assert_equal(te.pool[2].kind, EXPR_LT_F64)


# -----------------------------------------------------------------------------
# Test 3 — AND chain (Q6-shape).
# -----------------------------------------------------------------------------


def test_translate_q6_and_chain() raises:
    """Q6-like AND chain:
       l_shipdate >= 1994
       AND l_shipdate < 1995
       AND l_discount >= 0.05
       AND l_discount <= 0.07.

    n_conjuncts == 4. Root is an EXPR_AND.
    """
    var schema = _build_q6_schema()
    var p1 = Expr.binary(
        BIN_GE,
        Expr.col_ref(String("l_shipdate")),
        Expr.literal(ScalarValue.from_int64(Int64(1994))),
    )
    var p2 = Expr.binary(
        BIN_LT,
        Expr.col_ref(String("l_shipdate")),
        Expr.literal(ScalarValue.from_int64(Int64(1995))),
    )
    var p3 = Expr.binary(
        BIN_GE,
        Expr.col_ref(String("l_discount")),
        Expr.literal(ScalarValue.from_float(0.05)),
    )
    var p4 = Expr.binary(
        BIN_LE,
        Expr.col_ref(String("l_discount")),
        Expr.literal(ScalarValue.from_float(0.07)),
    )
    # Build the left-leaning AND chain like the planner emits.
    var pred = Expr.binary(
        BIN_AND,
        Expr.binary(BIN_AND, Expr.binary(BIN_AND, p1^, p2^), p3^),
        p4^,
    )

    var result = translate_filter_predicate(pred, schema)
    assert_true(result.__bool__())
    ref te = result.value()
    assert_equal(te.n_conjuncts, 4)
    assert_equal(te.pool[te.root_idx].kind, EXPR_AND)


# -----------------------------------------------------------------------------
# Test 4 — Lit-on-LEFT mirroring.
# -----------------------------------------------------------------------------


def test_translate_lit_on_left_mirrors_op() raises:
    """`5 < x` translates as `x > 5` (mirror swap + flip GT<->LT)."""
    var schema = _build_int_only_schema()
    var pred = Expr.binary(
        BIN_LT,
        Expr.literal(ScalarValue.from_int64(Int64(5))),
        Expr.col_ref(String("x")),
    )
    var result = translate_filter_predicate(pred, schema)
    assert_true(result.__bool__())
    ref te = result.value()
    # After mirroring, the comparison should be EXPR_GT_I64 with col-on-left.
    assert_equal(te.pool[te.root_idx].kind, EXPR_GT_I64)
    # Left points at the column ref; right at the literal.
    var cmp_node = te.pool[te.root_idx]
    assert_equal(te.pool[cmp_node.left].kind, EXPR_COL)
    assert_equal(te.pool[cmp_node.right].kind, EXPR_LIT_I64)
    assert_equal(te.pool[cmp_node.right].i64, Int64(5))


# -----------------------------------------------------------------------------
# Test 5 — Unsupported shapes return None.
# -----------------------------------------------------------------------------


def test_translate_or_returns_none() raises:
    """BIN_OR is unsupported by the walker."""
    var schema = _build_int_only_schema()
    var pred = Expr.binary(
        BIN_OR,
        Expr.binary(
            BIN_GT,
            Expr.col_ref(String("x")),
            Expr.literal(ScalarValue.from_int64(Int64(5))),
        ),
        Expr.binary(
            BIN_LT,
            Expr.col_ref(String("x")),
            Expr.literal(ScalarValue.from_int64(Int64(0))),
        ),
    )
    var result = translate_filter_predicate(pred, schema)
    assert_true(not result.__bool__())


def test_translate_string_literal_returns_none() raises:
    """Comparison against a string literal is unsupported by the
    row-mode walker (DTYPE_NONE is the string sentinel)."""
    var schema = _build_string_schema()
    var pred = Expr.binary(
        BIN_EQ,
        Expr.col_ref(String("name")),
        Expr.literal(ScalarValue.from_string(String("hello"))),
    )
    var result = translate_filter_predicate(pred, schema)
    assert_true(not result.__bool__())


def test_translate_mixed_dtype_returns_none() raises:
    """Int64 col vs Float64 lit is unsupported (mixed DType)."""
    var schema = _build_int_only_schema()
    var pred = Expr.binary(
        BIN_GT,
        Expr.col_ref(String("x")),
        Expr.literal(ScalarValue.from_float(3.14)),
    )
    var result = translate_filter_predicate(pred, schema)
    assert_true(not result.__bool__())


def test_translate_unknown_column_returns_none() raises:
    """Column name not in schema yields None (the predicate is
    structurally unsound; planner should have rejected, but be
    defensive)."""
    var schema = _build_int_only_schema()
    var pred = Expr.binary(
        BIN_GT,
        Expr.col_ref(String("nonexistent")),
        Expr.literal(ScalarValue.from_int64(Int64(5))),
    )
    var result = translate_filter_predicate(pred, schema)
    assert_true(not result.__bool__())


# -----------------------------------------------------------------------------
# Test 6 — n_conjuncts on single comparison.
# -----------------------------------------------------------------------------


def test_translate_n_conjuncts_single_compare() raises:
    """A bare comparison (not an AND) reports n_conjuncts = 1."""
    var schema = _build_int_only_schema()
    var pred = Expr.binary(
        BIN_GT,
        Expr.col_ref(String("x")),
        Expr.literal(ScalarValue.from_int64(Int64(5))),
    )
    var result = translate_filter_predicate(pred, schema)
    assert_true(result.__bool__())
    assert_equal(result.value().n_conjuncts, 1)


def main() raises:
    var suite = TestSuite()
    suite.test[test_translate_col_ge_lit_i64]()
    suite.test[test_translate_col_lt_lit_f64]()
    suite.test[test_translate_q6_and_chain]()
    suite.test[test_translate_lit_on_left_mirrors_op]()
    suite.test[test_translate_or_returns_none]()
    suite.test[test_translate_string_literal_returns_none]()
    suite.test[test_translate_mixed_dtype_returns_none]()
    suite.test[test_translate_unknown_column_returns_none]()
    suite.test[test_translate_n_conjuncts_single_compare]()
    suite^.run()
