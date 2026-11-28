# =============================================================================
# test_round_digits_expr — `EXPR_ROUND_DIGITS`: tag, node, render and type rule
# =============================================================================
#
# The render is plan identity (`structural_hash` hashes it), so nodes that
# differ only in the rule or in the digit count must render differently. The
# type rule is the one `walk_expr_field` answers for every projection.

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_expr.expr import (
    EXPR_ROUND_DIGITS,
    EXPR_TAG_COUNT,
    Expr,
    RDG_OP_COUNT,
    RDG_ROUND,
    RDG_ROUND_HALF_EVEN,
    RDG_TRUNC,
    expr_tag_name,
)
from plan_expr.expr_walk import (
    PlanColRefFields,
    ordered_name_sink,
    walk_expr_column_refs,
    walk_expr_field,
)
from plan_expr.round_digits_type import (
    round_digits_decimal_all_zero,
    round_digits_decimal_scale,
)


def _text(e: Expr) -> String:
    var s = String("")
    e.write_to(s)
    return s^


def _schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("i8", ArrowType.INT8, False))
    sb.add_field(Field("i32", ArrowType.INT32, True))
    sb.add_field(Field("i64", ArrowType.INT64, True))
    sb.add_field(Field("f32", ArrowType.FLOAT32, False))
    sb.add_field(Field("f64", ArrowType.FLOAT64, True))
    sb.add_field(Field.decimal128("d", 12, 4, True))
    sb.add_field(Field.decimal128("dn", 12, 4, False))
    sb.add_field(Field.decimal128("small", 4, 1, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("b", ArrowType.BOOL, True))
    return sb.build()


def _field(op: UInt8, col: String, digits: Int) raises -> Field:
    var e = Expr.round_digits(op, Expr.col_ref(col), Int32(digits))
    var missing = String("")
    var f = walk_expr_field[PlanColRefFields](e, _schema(), missing)
    assert_equal(missing, "", "no column is missing")
    return f^


# ---- tag, node, accessors ---------------------------------------------------


def test_tag_value_count_and_name() raises:
    assert_equal(Int(EXPR_ROUND_DIGITS), 28)
    assert_equal(EXPR_TAG_COUNT, 29)
    assert_equal(expr_tag_name(EXPR_ROUND_DIGITS), "EXPR_ROUND_DIGITS")
    assert_equal(RDG_OP_COUNT, 3)


def test_accessors_return_the_constructed_parts() raises:
    var e = Expr.round_digits(RDG_TRUNC, Expr.col_ref("x"), Int32(-3))
    assert_equal(Int(e.tag), 28)
    assert_equal(Int(e.round_digits_op()), Int(RDG_TRUNC))
    assert_equal(Int(e.round_digits_count()), -3)
    assert_equal(e.round_digits_child_ref().col_ref_name(), "x")


def test_copy_preserves_op_digits_and_child() raises:
    var e = Expr.round_digits(RDG_ROUND_HALF_EVEN, Expr.col_ref("x"), Int32(7))
    var c = e.copy()
    assert_equal(Int(c.round_digits_op()), Int(RDG_ROUND_HALF_EVEN))
    assert_equal(Int(c.round_digits_count()), 7)
    assert_equal(c.round_digits_child_ref().col_ref_name(), "x")
    assert_equal(_text(c), _text(e))


# ---- render is plan identity -----------------------------------------------


def test_render_includes_op_digits_and_child() raises:
    var s = _text(Expr.round_digits(RDG_TRUNC, Expr.col_ref("x"), Int32(-2)))
    assert_true(s.startswith("RoundDigits(op=1, digits=-2, "))
    assert_true("x" in s)


def test_render_differs_when_only_the_digits_differ() raises:
    var a = _text(Expr.round_digits(RDG_ROUND, Expr.col_ref("x"), Int32(1)))
    var b = _text(Expr.round_digits(RDG_ROUND, Expr.col_ref("x"), Int32(2)))
    assert_true(a != b)


def test_render_differs_when_only_the_op_differs() raises:
    var a = _text(Expr.round_digits(RDG_ROUND, Expr.col_ref("x"), Int32(1)))
    var b = _text(Expr.round_digits(RDG_TRUNC, Expr.col_ref("x"), Int32(1)))
    var c = _text(
        Expr.round_digits(RDG_ROUND_HALF_EVEN, Expr.col_ref("x"), Int32(1))
    )
    assert_true(a != b)
    assert_true(a != c)
    assert_true(b != c)


def test_column_refs_come_from_the_child() raises:
    var e = Expr.round_digits(RDG_ROUND, Expr.col_ref("price"), Int32(2))
    var names = List[String]()
    var sink = ordered_name_sink(names)
    walk_expr_column_refs(e, sink)
    assert_equal(len(names), 1)
    assert_equal(names[0], "price")


# ---- type rule: INT and FLOAT keep the input type ---------------------------


def test_int_and_float_keep_type_and_nullability() raises:
    var f8 = _field(RDG_ROUND, "i8", -1)
    assert_true(f8.arrow_type == ArrowType.INT8)
    assert_true(not f8.nullable)
    var f32 = _field(RDG_TRUNC, "i32", 2)
    assert_true(f32.arrow_type == ArrowType.INT32)
    assert_true(f32.nullable)
    assert_true(_field(RDG_ROUND, "i64", -30).arrow_type == ArrowType.INT64)
    assert_true(_field(RDG_ROUND, "f32", 1).arrow_type == ArrowType.FLOAT32)
    var ff = _field(RDG_ROUND_HALF_EVEN, "f64", 1)
    assert_true(ff.arrow_type == ArrowType.FLOAT64)
    assert_true(ff.nullable)


def test_output_name_is_trunc_for_trunc_else_round() raises:
    assert_equal(_field(RDG_TRUNC, "f64", 1).name, "trunc")
    assert_equal(_field(RDG_ROUND, "f64", 1).name, "round")
    assert_equal(_field(RDG_ROUND_HALF_EVEN, "f64", 1).name, "round")
    assert_equal(_field(RDG_TRUNC, "d", 1).name, "trunc")
    assert_equal(_field(RDG_ROUND, "d", 1).name, "round")


# ---- type rule: DECIMAL128 --------------------------------------------------


def test_decimal_digits_at_or_above_scale_keep_precision_and_scale() raises:
    var f = _field(RDG_ROUND, "d", 4)
    assert_true(f.arrow_type == ArrowType.DECIMAL128)
    assert_equal(f.decimal_precision, 12)
    assert_equal(f.decimal_scale, 4)
    assert_equal(_field(RDG_TRUNC, "d", 9).decimal_scale, 4)


def test_decimal_digits_between_zero_and_scale_set_the_scale() raises:
    var f = _field(RDG_ROUND, "d", 2)
    assert_equal(f.decimal_precision, 12)
    assert_equal(f.decimal_scale, 2)
    assert_equal(_field(RDG_TRUNC, "d", 0).decimal_scale, 0)


def test_decimal_negative_digits_give_scale_zero() raises:
    var f = _field(RDG_ROUND, "d", -1)
    assert_equal(f.decimal_precision, 12)
    assert_equal(f.decimal_scale, 0)
    assert_true(f.nullable)


def test_decimal_all_zero_case_is_non_nullable() raises:
    var f = _field(RDG_ROUND, "d", -8)
    assert_equal(f.decimal_scale, 0)
    assert_true(not f.nullable)
    assert_true(_field(RDG_ROUND, "d", -7).nullable)
    assert_true(not _field(RDG_TRUNC, "small", -3).nullable)
    assert_true(_field(RDG_TRUNC, "small", -2).nullable)


def test_decimal_half_even_keeps_the_input_type() raises:
    var f = _field(RDG_ROUND_HALF_EVEN, "d", -8)
    assert_equal(f.decimal_precision, 12)
    assert_equal(f.decimal_scale, 4)
    assert_true(f.nullable)


def test_decimal_helpers_state_the_rule() raises:
    assert_equal(round_digits_decimal_scale(RDG_ROUND, 4, 9), 4)
    assert_equal(round_digits_decimal_scale(RDG_ROUND, 4, 2), 2)
    assert_equal(round_digits_decimal_scale(RDG_TRUNC, 4, -5), 0)
    assert_equal(round_digits_decimal_scale(RDG_ROUND_HALF_EVEN, 4, 2), 4)
    assert_true(round_digits_decimal_all_zero(RDG_ROUND, 12, 4, -8))
    assert_true(not round_digits_decimal_all_zero(RDG_ROUND, 12, 4, -7))
    assert_true(not round_digits_decimal_all_zero(RDG_ROUND, 12, 4, 8))
    assert_true(not round_digits_decimal_all_zero(RDG_ROUND_HALF_EVEN, 12, 4, -8))


def test_types_without_a_rounding_rule_keep_their_own_type() raises:
    assert_true(_field(RDG_ROUND, "s", 1).arrow_type == ArrowType.STRING)
    assert_true(_field(RDG_ROUND, "b", 1).arrow_type == ArrowType.BOOL)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
