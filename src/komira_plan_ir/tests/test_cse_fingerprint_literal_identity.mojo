# =============================================================================
# `_expr_fingerprint` is an IDENTITY: two expressions that compute different
# values (or values of different TYPES) must fingerprint differently.
# =============================================================================
#
# The fingerprint is the CSE key (Phase A whole-expression dedup rewrites the
# second of two equal-fingerprint project columns into an alias of the first),
# the OR-factoring equality key, and the UDF scratch-column name
# (`udf_call_column_key`). An equal fingerprint for two different expressions
# is a silent wrong answer, not a missed optimisation.
#
# Each test names the defect it catches:
#
#   * int32/int64 (and int8/int16) and float32/float64 literals of the same
#     value: `is_int()` / `is_float()` are true for BOTH widths, so the old
#     ladder keyed `from_int32(7)` and `from_int64(7)` as `L:i7`. Collapsing
#     them changes the output column's TYPE.
#   * typed NULLs of different types: the old ladder had no NULL arm, so
#     `null(int64)` and `null(utf8)` both keyed `L:?`.
#   * raw strings concatenated with separators the strings may contain: the
#     IN-list joined value keys with `,`, so `x IN ('a,L:sb')` and
#     `x IN ('a', 'b')` keyed the same; column names, string-op patterns,
#     regexp fields, struct-field names and JSON path segments had the same
#     shape.
#   * a side-qualified column (`Expr.left("x")`) and a plain one keyed the
#     same `C:x`.
#   * TRY_CAST and CAST of one child to one type: the CAST arm did not fold
#     `cast_is_try()`, so both keyed `T:int64:a5:p0:s0(C:1:s)` and a strict
#     CAST (raises on a bad value) could become an alias of a TRY_CAST (NULL).
#
# Controls: equal expressions still fingerprint equal (CSE still fires), and an
# IN list is still order-insensitive.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal

from komira_plan_expr.expr import Expr, BIN_EQ, BIN_ADD, BIN_OR
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.plan_helpers import _expr_fingerprint, _scalar_fingerprint


def _fp(e: Expr) -> String:
    return _expr_fingerprint(e)


def _lit(var v: ScalarValue) -> Expr:
    return Expr.literal(v^)


def _strs(a: String) -> List[ScalarValue]:
    var out = List[ScalarValue]()
    out.append(ScalarValue.from_string(a))
    return out^


def _strs2(a: String, b: String) -> List[ScalarValue]:
    var out = List[ScalarValue]()
    out.append(ScalarValue.from_string(a))
    out.append(ScalarValue.from_string(b))
    return out^


def _in(var vals: List[ScalarValue]) -> Expr:
    return Expr.in_list_node(Expr.col_ref("x"), vals^)


def _distinct(a: String, b: String, what: String) raises:
    assert_true(a != b, what + " (both fingerprinted " + a + ")")


# --- integer and float widths -------------------------------------------------


def test_the_issue_probe_int32_vs_int64() raises:
    _distinct(
        _fp(_lit(ScalarValue.from_int32(7))),
        _fp(_lit(ScalarValue.from_int64(7))),
        "int32(7) and int64(7) are different column types",
    )


def test_every_signed_integer_width_is_distinct() raises:
    var fps = List[String]()
    fps.append(_scalar_fingerprint(ScalarValue.from_int8(7)))
    fps.append(_scalar_fingerprint(ScalarValue.from_int16(7)))
    fps.append(_scalar_fingerprint(ScalarValue.from_int32(7)))
    fps.append(_scalar_fingerprint(ScalarValue.from_int64(7)))
    fps.append(_scalar_fingerprint(ScalarValue.from_uint32(7)))
    for i in range(len(fps)):
        for j in range(i + 1, len(fps)):
            _distinct(fps[i], fps[j], "integer widths " + String(i) + "/" + String(j))


def test_negative_integer_widths_are_distinct() raises:
    _distinct(
        _scalar_fingerprint(ScalarValue.from_int32(-1)),
        _scalar_fingerprint(ScalarValue.from_int64(-1)),
        "int32(-1) vs int64(-1)",
    )


def test_the_issue_probe_float32_vs_float64() raises:
    _distinct(
        _fp(_lit(ScalarValue.from_float32(1.5))),
        _fp(_lit(ScalarValue.from_float(1.5))),
        "float32(1.5) and float64(1.5) are different column types",
    )


def test_width_survives_inside_an_expression() raises:
    # `x + int32(1)` vs `x + int64(1)`: the CSE key of the whole expression.
    _distinct(
        _fp(Expr.binary(BIN_ADD, Expr.col_ref("x"), _lit(ScalarValue.from_int32(1)))),
        _fp(Expr.binary(BIN_ADD, Expr.col_ref("x"), _lit(ScalarValue.from_int64(1)))),
        "x + int32(1) vs x + int64(1)",
    )


def test_typed_nulls_of_different_types_are_distinct() raises:
    _distinct(
        _scalar_fingerprint(ScalarValue.null(DType.int64)),
        _scalar_fingerprint(ScalarValue.null(DType.float64)),
        "null(int64) vs null(float64)",
    )


def test_equal_literals_still_share_a_key() raises:
    # Control: CSE must still fire on genuinely equal literals.
    assert_equal(
        _scalar_fingerprint(ScalarValue.from_int32(7)),
        _scalar_fingerprint(ScalarValue.from_int32(7)),
    )
    assert_equal(
        _scalar_fingerprint(ScalarValue.from_float32(1.5)),
        _scalar_fingerprint(ScalarValue.from_float32(1.5)),
    )
    assert_equal(
        _scalar_fingerprint(ScalarValue.null(DType.int64)),
        _scalar_fingerprint(ScalarValue.null(DType.int64)),
    )
    assert_equal(
        _scalar_fingerprint(ScalarValue.from_string("a,b")),
        _scalar_fingerprint(ScalarValue.from_string("a,b")),
    )


# --- strings that contain the separators and the type tags --------------------


def test_the_issue_probe_in_list_comma() raises:
    _distinct(
        _fp(_in(_strs("a,L:sb"))),
        _fp(_in(_strs2("a", "b"))),
        "x IN ('a,L:sb') vs x IN ('a', 'b')",
    )


def test_in_list_split_point_moves() raises:
    _distinct(
        _fp(_in(_strs2("a,L:sb", "c"))),
        _fp(_in(_strs2("a", "b,L:sc"))),
        "x IN ('a,L:sb', 'c') vs x IN ('a', 'b,L:sc')",
    )


def test_string_op_pattern_containing_a_child_key() raises:
    # `S:<op>:<pattern>(<child>)`: a pattern that spells `(<child>)` lets the
    # split between pattern and child move.
    _distinct(
        _fp(Expr.string_op(UInt8(1), Expr.col_ref("c"), "a(C:b)")),
        _fp(Expr.string_op(UInt8(1), Expr.col_ref("b)(C:c"), "a")),
        "contains(c, 'a(C:b)') vs contains(`b)(C:c`, 'a')",
    )


def test_in_list_order_is_still_irrelevant() raises:
    # Control: IN is set membership.
    assert_equal(_fp(_in(_strs2("a", "b"))), _fp(_in(_strs2("b", "a"))))


def test_string_vs_binary_of_the_same_bytes() raises:
    _distinct(
        _scalar_fingerprint(ScalarValue.from_string("ab")),
        _scalar_fingerprint(ScalarValue.from_binary(String("ab"))),
        "utf8 'ab' vs binary 'ab'",
    )


def test_string_literal_spelling_another_literal_key() raises:
    # A string whose bytes are another literal's whole key.
    _distinct(
        _fp(Expr.binary(BIN_EQ, _lit(ScalarValue.from_string("a,L:sb")), _lit(ScalarValue.from_string("c")))),
        _fp(Expr.binary(BIN_EQ, _lit(ScalarValue.from_string("a")), _lit(ScalarValue.from_string("b,L:sc")))),
        "binary op whose split point moves across a literal",
    )


def test_column_names_containing_the_separator() raises:
    _distinct(
        _fp(Expr.binary(BIN_ADD, Expr.col_ref("a,C:b"), Expr.col_ref("c"))),
        _fp(Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.col_ref("b,C:c"))),
        "a,C:b + c vs a + b,C:c",
    )


def test_or_of_column_names_containing_the_separator() raises:
    # AND/OR sort their child keys; the sort must not reopen the split.
    _distinct(
        _fp(Expr.binary(BIN_OR, Expr.col_ref("a,C:b"), Expr.col_ref("c"))),
        _fp(Expr.binary(BIN_OR, Expr.col_ref("a"), Expr.col_ref("b,C:c"))),
        "OR over separator-bearing names",
    )


def test_side_qualified_column_is_not_the_plain_column() raises:
    _distinct(_fp(Expr.left("x")), _fp(Expr.col_ref("x")), "left.x vs x")
    _distinct(_fp(Expr.left("x")), _fp(Expr.right("x")), "left.x vs right.x")


def test_try_cast_is_not_cast() raises:
    _distinct(
        _fp(Expr.try_cast(Expr.col_ref("s"), DType.int64)),
        _fp(Expr.cast(Expr.col_ref("s"), DType.int64)),
        "TRY_CAST(s AS int64) vs CAST(s AS int64)",
    )
    # The flag is appended only for TRY_CAST, so a plain CAST keeps its key.
    assert_equal(
        _fp(Expr.try_cast(Expr.col_ref("s"), DType.int64)), "T:int64:a5:p0:s0:t1(C:1:s)"
    )
    # Control: two TRY_CASTs of the same child and type still share a key.
    assert_equal(
        _fp(Expr.try_cast(Expr.col_ref("s"), DType.int64)),
        _fp(Expr.try_cast(Expr.col_ref("s"), DType.int64)),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
