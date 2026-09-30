# =============================================================================
# `col_expr_bind` — the unbound `ColExpr` choices re-decided over a SCHEMA
# for a division, a floor division or a `fill_null`.
#
# DuckDB v1.5.3 over a parquet of [k int64, v int64, f float32, x float64,
# y float64, d decimal(12,2)] answers:
#   f / 3 FLOAT, 120 / f FLOAT, f / x DOUBLE, x / y DOUBLE, d / 4 DOUBLE,
#   d // 4 DOUBLE 0.375, x // 0 NULL, f // 2 FLOAT, v // 2 BIGINT (truncates),
#   coalesce(x, 0) DOUBLE, coalesce(f, 0) FLOAT.
#
# This file pins the TYPE each bound tree declares (`walk_expr_field`, the one
# output-field inference) and the SHAPE where the shape is the point (no
# identity CAST over a DOUBLE ratio; the builder's tree kept where nothing can
# be typed). The VALUES are graded end-to-end against DuckDB elsewhere.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import Schema, SchemaBuilder, Field
from komira_core.plan.expr import (
    Expr, EXPR_CAST, EXPR_COL_REF, EXPR_WHEN, EXPR_LITERAL, EXPR_BINARY_OP,
    BIN_DIV,
)
from komira_core.plan.scalar_value import ScalarValue
from komira_core.plan.expr_walk import walk_expr_field, PlanColRefFields
from komira_core.plan.plan_helpers import _expr_fingerprint
from komira_core.plan.col_expr import col, lit, sum_horizontal
from komira_core.plan.col_expr_bind import bind_unbound_expr


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("v"), ArrowType.INT64, True))
    sb.add_field(Field(String("f"), ArrowType.FLOAT32, True))
    sb.add_field(Field(String("x"), ArrowType.FLOAT64, True))
    sb.add_field(Field(String("y"), ArrowType.FLOAT64, True))
    var d = Field(String("d"), ArrowType.DECIMAL128, True)
    d.decimal_precision = 12
    d.decimal_scale = 2
    sb.add_field(d^)
    return sb.build()


def _type(e: Expr) -> ArrowType:
    var missing = String("")
    return walk_expr_field[PlanColRefFields](e, _schema(), missing).arrow_type


def _out(e: Expr) -> Expr:
    """Bound as an OUTPUT column's value (select / with_columns)."""
    return bind_unbound_expr(e, _schema(), True)


# ---- `/` ---------------------------------------------------------------------


def test_float32_over_an_int_literal_is_FLOAT() raises:
    var e = _out((col("f") / 3).alias("q"))
    assert_equal(_type(e), ArrowType.FLOAT32, "f32 / 3 is FLOAT (DuckDB)")


def test_int_literal_over_float32_is_FLOAT() raises:
    # The builder's `CAST(120 AS DOUBLE) / f` was REFUSED by the engine
    # ("float64 and float32"); DuckDB answers FLOAT.
    var e = _out((lit(120) / col("f")).alias("rq"))
    assert_equal(_type(e), ArrowType.FLOAT32, "120 / f32 is FLOAT")


def test_float32_over_float32_is_FLOAT() raises:
    assert_equal(_type(_out((col("f") / col("f")).copy_expr())), ArrowType.FLOAT32, "f / f")


def test_float32_over_a_double_is_DOUBLE() raises:
    assert_equal(_type(_out((col("f") / col("x")).copy_expr())), ArrowType.FLOAT64, "f / x")


def test_a_double_ratio_carries_no_identity_cast() raises:
    # The q8 shape: `brazil_sum / total_sum` over DOUBLE columns. The builder
    # wrapped the left operand in CAST(.. AS DOUBLE); bound, it is gone.
    var e = _out((col("x") / col("y")).copy_expr())
    assert_equal(
        _expr_fingerprint(e),
        _expr_fingerprint(Expr.binary(BIN_DIV, Expr.col_ref("x"), Expr.col_ref("y"))),
        "x / y over DOUBLEs is the bare BIN_DIV",
    )


def test_an_integer_ratio_keeps_the_builders_tree() raises:
    var built = col("v") / 2
    var e = _out(built.copy_expr())
    assert_equal(_expr_fingerprint(e), _expr_fingerprint(built.copy_expr()), "v / 2")
    assert_equal(_type(e), ArrowType.FLOAT64, "int / int is DOUBLE")


def test_decimal_true_division_is_DOUBLE() raises:
    assert_equal(_type(_out((col("d") / 4).copy_expr())), ArrowType.FLOAT64, "d / 4")


def test_an_explicit_cast_to_double_stays_DOUBLE() raises:
    # `col("f").cast(float64) / 2` builds the SAME tree the unbound `/` builds
    # for `col("f") / 2`; only the recorded intent tells them apart, and the
    # user's cast asked for DOUBLE.
    var e = _out((col("f").cast(DType.float64) / 2).copy_expr())
    assert_equal(_type(e), ArrowType.FLOAT64, "CAST(f AS DOUBLE) / 2")


def test_a_quotient_inside_a_predicate_stays_DOUBLE() raises:
    var e = bind_unbound_expr((col("f") / 3).copy_expr(), _schema(), False)
    assert_equal(_type(e), ArrowType.FLOAT64, "f / 3 under a predicate")


def test_a_quotient_nested_in_arithmetic_stays_DOUBLE() raises:
    var e = _out(((col("f") / 3) * 2).copy_expr())
    assert_equal(_type(e), ArrowType.FLOAT64, "(f / 3) * 2 (residual)")


# ---- `//` --------------------------------------------------------------------


def test_integer_floordiv_is_the_bare_truncating_div() raises:
    var e = _out((col("v") // 2).copy_expr())
    assert_equal(
        _expr_fingerprint(e),
        _expr_fingerprint(
            Expr.binary(BIN_DIV, Expr.col_ref("v"), Expr.literal(ScalarValue.from_int(2)))
        ),
        "v // 2",
    )
    assert_equal(_type(e), ArrowType.INT64, "v // 2 is BIGINT")


def test_decimal_floordiv_is_DOUBLE() raises:
    # The builder's bare BIN_DIV raised `_eval_binary_col_scalar: unsupported
    # type 18`; DuckDB's `//` on a non-integer IS `/` (0.375 for 1.50 // 4).
    var e = _out((col("d") // 4).copy_expr())
    assert_equal(_type(e), ArrowType.FLOAT64, "d // 4")
    assert_equal(Int(e.tag), Int(EXPR_BINARY_OP), "a division")
    assert_equal(Int(e.binary_left_ref().tag), Int(EXPR_CAST), "the decimal is cast")


def test_a_double_floordiv_by_zero_literal_divides_by_a_NULL_column() raises:
    # DuckDB: `x // 0` is NULL (where `x / 0` is +-inf). The divisor is
    # `NULLIF(0.0, 0)` as a CASE — a NULL LITERAL divisor was measured
    # answering +-inf (the column-by-scalar kernel reads its zero payload).
    var e = _out((col("x") // 0).copy_expr())
    assert_equal(Int(e.tag), Int(EXPR_BINARY_OP), "still the division")
    assert_equal(Int(e.binary_right_ref().tag), Int(EXPR_WHEN), "NULLIF(0.0, 0)")
    assert_equal(_type(e), ArrowType.FLOAT64, "typed DOUBLE")


def test_a_double_floordiv_by_a_nonzero_literal_is_the_bare_division() raises:
    var e = _out((col("x") // 4).copy_expr())
    assert_equal(
        _expr_fingerprint(e),
        _expr_fingerprint(Expr.binary(
            BIN_DIV, Expr.col_ref("x"), Expr.literal(ScalarValue.from_int(4))
        )),
        "x // 4 needs no guard",
    )


def test_a_float32_floordiv_by_zero_literal_is_a_NULL_float() raises:
    var e = _out((col("f") // 0).copy_expr())
    assert_equal(Int(e.tag), Int(EXPR_CAST), "CAST(NULL AS FLOAT)")
    assert_equal(_type(e), ArrowType.FLOAT32, "typed FLOAT")


def test_a_double_floordiv_by_a_column_guards_the_zero() raises:
    var e = _out((col("x") // col("v")).copy_expr())
    assert_equal(_type(e), ArrowType.FLOAT64, "x // v")
    assert_equal(Int(e.binary_right_ref().tag), Int(EXPR_WHEN), "NULLIF(v, 0)")


def test_float32_floordiv_is_FLOAT() raises:
    assert_equal(_type(_out((col("f") // 2).copy_expr())), ArrowType.FLOAT32, "f // 2")


# ---- CASE unification --------------------------------------------------------


def test_fill_null_int_literal_over_a_double_takes_the_double() raises:
    var e = _out(col("x").fill_null(0).alias("c"))
    assert_equal(_type(e), ArrowType.FLOAT64, "coalesce(x, 0)")
    ref when = e.alias_child_ref()
    ref dflt = when.when_default_ref()
    assert_true(dflt.literal_value().is_float(), "the 0 is a float literal")
    assert_equal(dflt.literal_value().dtype, DType.float64, "float64 0.0")


def test_fill_null_int_literal_over_a_float32_is_FLOAT() raises:
    # The CASE executor has no float32 output, so the CASE runs in DOUBLE over
    # binary32 values and is narrowed once: CAST(CASE .. AS FLOAT).
    var e = _out(col("f").fill_null(0).alias("c"))
    assert_equal(_type(e), ArrowType.FLOAT32, "coalesce(f, 0)")
    ref c = e.alias_child_ref()
    assert_equal(Int(c.tag), Int(EXPR_CAST), "narrowed once")
    ref when = c.cast_child_ref()
    assert_equal(Int(when.when_case_result_ref(0).tag), Int(EXPR_CAST), "f widened")
    assert_equal(when.when_default_ref().literal_value().dtype, DType.float64, "0.0")


def test_fill_null_float_literal_over_a_float32_rounds_it_to_binary32() raises:
    # DuckDB casts the literal to FLOAT: 0.1 is 0.100000001490116...
    var e = _out(col("f").fill_null(0.1).copy_expr())
    ref d = e.cast_child_ref().when_default_ref()
    assert_equal(d.literal_value().float_val, Float64(Float32(0.1)), "binary32(0.1)")


def test_a_nested_float32_case_is_left_as_built() raises:
    # sum_horizontal over a FLOAT: the CASEs sit under `+`; the engine refuses
    # a float32 CASE by name, as it did before — never a DOUBLE answer.
    var e = _out(sum_horizontal(col("f"), col("f")).copy_expr())
    assert_equal(Int(e.binary_left_ref().tag), Int(EXPR_WHEN), "no narrowing CAST")


def test_a_nested_float32_quotient_is_left_as_built() raises:
    # `(120 / f) * 2`: the builder's tree (the engine's refusal), not a new
    # DOUBLE answer where DuckDB answers FLOAT.
    var built = (lit(120) / col("f")) * 2
    var e = _out(built.copy_expr())
    assert_equal(_expr_fingerprint(e), _expr_fingerprint(built.copy_expr()), "as built")


def test_a_float32_quotient_rounds_a_float_literal_to_binary32() raises:
    var e = _out((col("f") / 0.1).copy_expr())
    ref r = e.cast_child_ref().binary_right_ref()
    assert_equal(r.literal_value().float_val, Float64(Float32(0.1)), "binary32(0.1)")


def test_fill_null_over_an_int_is_unchanged() raises:
    var built = col("v").fill_null(0)
    var e = _out(built.copy_expr())
    assert_equal(_expr_fingerprint(e), _expr_fingerprint(built.copy_expr()), "coalesce(v, 0)")
    assert_equal(_type(e), ArrowType.INT64, "BIGINT")


# ---- what cannot be typed is left as built -----------------------------------


def test_an_unknown_column_keeps_the_builders_tree() raises:
    var built = col("nope") / 2
    var e = _out(built.copy_expr())
    assert_equal(_expr_fingerprint(e), _expr_fingerprint(built.copy_expr()), "nope / 2")
    assert_equal(Int(e.binary_left_ref().tag), Int(EXPR_CAST), "the builder's cast")


def test_a_division_no_unbound_builder_made_is_untouched() raises:
    # `Expr.binary(BIN_DIV, ..)` records no intent: a bound plan's division
    # (the SQL binder's, the optimizer's) is never re-decided.
    var built = Expr.binary(BIN_DIV, Expr.col_ref("f"), Expr.literal(ScalarValue.from_int(3)))
    var e = _out(built.copy())
    assert_equal(_expr_fingerprint(e), _expr_fingerprint(built), "bare f / 3")
    assert_equal(Int(e.binary_left_ref().tag), Int(EXPR_COL_REF), "no cast added")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
