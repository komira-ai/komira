# =============================================================================
# The CSE fingerprint: `plan_helpers._expr_fingerprint` / `_scalar_fingerprint`
# =============================================================================
#
# The fingerprint is the key the optimizer's whole-expression dedup groups by:
# two expressions with one fingerprint are treated as one value. So the
# property that matters is that a field which changes an expression's value
# reaches its fingerprint, and the two ladders that spell a literal (the
# `EXPR_LITERAL` arm and `_write_scalar_fingerprint`) agree byte for byte.
#
# Every case asserts the exact fingerprint, worked out from the code: the
# arm's prefix, each field it folds in, in order, and its children's
# fingerprints. Op codes are written as the constants the expression was
# built with.
#
# Test groups:
#   1. Every literal kind, through both ladders.
#   2. Every expression arm: each field it folds, the two commutative
#      operators' canonical order, a non-commutative one kept as built, the
#      IN list's value sort, and the fallback for a tag with no arm.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.dtype_sentinel import DTYPE_NONE
from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    BIN_AND,
    BIN_OR,
    BIN_EQ,
    EXTRACT_YEARWEEK,
    MATH_SQRT,
    MATH2_ATAN2,
    REGEXP_EXTRACT,
    REGEXP_REPLACE,
    STR_ENDS_WITH,
    STRFN_LOWER,
    STRFNN_CONCAT_WS,
    UN_IS_NULL,
)
from komira_plan_expr.scalar_value import (
    ScalarValue,
    SCALAR_TIME_UNIT_MICRO,
    SCALAR_TIME_UNIT_NANO,
)
from komira_plan_ir.plan_helpers import _expr_fingerprint, _scalar_fingerprint


def _c(name: String) -> Expr:
    return Expr.col_ref(name)


def _op(code: UInt8) -> String:
    return String(Int(code))


# =============================================================================
# 1. Literals
# =============================================================================


def _lit(sv: ScalarValue, expected: String) raises:
    """Both ladders give `expected` for `sv`."""
    assert_equal(_scalar_fingerprint(sv), expected)
    assert_equal(_expr_fingerprint(Expr.literal(sv.copy())), expected)


def _lit_kind(sv: ScalarValue) raises:
    """Both ladders give one literal key for `sv`: non-empty, `L:`-prefixed,
    and equal to each other."""
    var a = _scalar_fingerprint(sv)
    assert_true(a.startswith("L:") and a.byte_length() > 2, a)
    assert_equal(_expr_fingerprint(Expr.literal(sv.copy())), a)


def test_integer_float_bool_and_string_literals() raises:
    _lit(ScalarValue.from_int(-42), "L:i-42")
    # int32 and float32: the key carries no dtype today, so each collides with
    # the 64-bit literal of the same value (komira-ai/komira#960). Only what
    # holds with or without a dtype in the key is asserted.
    _lit_kind(ScalarValue.from_int32(Int32(7)))
    _lit(ScalarValue.from_float(1.5), "L:f1.5")
    _lit_kind(ScalarValue.from_float32(Float32(0.5)))
    _lit(ScalarValue.from_bool(True), "L:b1")
    _lit(ScalarValue.from_bool(False), "L:b0")
    _lit(ScalarValue.from_string(String("xy")), "L:sxy")
    _lit(ScalarValue.from_string(String("")), "L:s")


def test_temporal_literals_carry_their_value() raises:
    _lit(ScalarValue.date32(Int32(100)), "L:d100")
    _lit(ScalarValue.timestamp_micros(Int64(-7)), "L:ts-7")
    _lit(
        ScalarValue.interval_month_day_nano(Int32(1), Int32(2), Int64(3)),
        "L:iv:1:2:3",
    )
    _lit(
        ScalarValue.time_of_day(Int64(5), SCALAR_TIME_UNIT_MICRO),
        "L:tod:2:5",
    )
    _lit(ScalarValue.duration(Int64(6), SCALAR_TIME_UNIT_NANO), "L:dur:3:6")


def test_decimal_literals_carry_every_limb_precision_and_scale() raises:
    _lit(ScalarValue.decimal128(Int64(1), Int64(2), 12, 2), "L:dec128:1:2:12:2")
    # decimal256(low_low, low_high, high_low, high_high): the key is written
    # most significant limb first.
    _lit(
        ScalarValue.decimal256(Int64(1), Int64(2), Int64(3), Int64(4), 40, 3),
        "L:dec256:4:3:2:1:40:3",
    )


def test_binary_narrow_and_unsigned_literals() raises:
    _lit(ScalarValue.from_binary(String("ab")), "L:bin:ab")
    # Keyed with the dtype: an int8 5 is not an int64 5.
    _lit(ScalarValue.from_int8(Int8(-5)), "L:in:int8:-5")
    _lit(ScalarValue.from_int16(Int16(300)), "L:in:int16:300")
    _lit(ScalarValue.from_uint8(UInt8(5)), "L:in:uint8:5")
    _lit(ScalarValue.from_uint64(UInt64(9)), "L:in:uint64:9")


def test_a_null_literal_has_no_value_in_its_key() raises:
    """Two NULLs are one value; the dtype is deliberately left out."""
    _lit(ScalarValue.null(DType.int64), "L:?")
    _lit(ScalarValue.null(DType.float64), "L:?")


# =============================================================================
# 2. Expression arms
# =============================================================================


def test_col_ref_unary_and_alias() raises:
    assert_equal(_expr_fingerprint(_c("a")), "C:a")
    assert_equal(
        _expr_fingerprint(Expr.unary(UN_IS_NULL, _c("a"))),
        "U:" + _op(UN_IS_NULL) + "(C:a)",
    )
    # An alias is its child: the name is not part of the value.
    assert_equal(_expr_fingerprint(Expr.alias(_c("a"), String("x"))), "C:a")


def test_and_or_are_canonicalized_and_other_operators_are_not() raises:
    var and_key = "B:" + _op(BIN_AND) + "(C:a,C:b)"
    assert_equal(_expr_fingerprint(Expr.binary(BIN_AND, _c("b"), _c("a"))), and_key)
    assert_equal(_expr_fingerprint(Expr.binary(BIN_AND, _c("a"), _c("b"))), and_key)
    var or_key = "B:" + _op(BIN_OR) + "(C:a,C:b)"
    assert_equal(_expr_fingerprint(Expr.binary(BIN_OR, _c("b"), _c("a"))), or_key)
    assert_equal(_expr_fingerprint(Expr.binary(BIN_OR, _c("a"), _c("b"))), or_key)
    # Equal children: nothing to swap.
    assert_equal(
        _expr_fingerprint(Expr.binary(BIN_AND, _c("a"), _c("a"))),
        "B:" + _op(BIN_AND) + "(C:a,C:a)",
    )
    # EQ is kept as built.
    assert_equal(
        _expr_fingerprint(Expr.binary(BIN_EQ, _c("b"), _c("a"))),
        "B:" + _op(BIN_EQ) + "(C:b,C:a)",
    )


def test_cast_folds_target_arrow_type_precision_and_scale() raises:
    assert_equal(
        _expr_fingerprint(Expr.cast(_c("a"), DType.int64)), "T:int64:a5:p0:s0(C:a)"
    )
    assert_equal(
        _expr_fingerprint(Expr.cast_to_arrow(_c("a"), ArrowType.DATE32)),
        "T:int32:a15:p0:s0(C:a)",
    )
    assert_equal(
        _expr_fingerprint(Expr.cast_to_decimal(_c("a"), 10, 2)),
        "T:" + String(DTYPE_NONE) + ":a18:p10:s2(C:a)",
    )


def test_when_keeps_case_order_and_the_default() raises:
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(_c("a"), _c("b")))
    cases.append(WhenCaseData(_c("c"), _c("d")))
    assert_equal(
        _expr_fingerprint(Expr.when(cases^, _c("e"))), "W:[C:a=>C:b,C:c=>C:d];C:e"
    )
    var one = List[WhenCaseData]()
    one.append(WhenCaseData(_c("a"), _c("b")))
    assert_equal(_expr_fingerprint(Expr.when(one^, _c("e"))), "W:[C:a=>C:b];C:e")


def test_in_list_values_are_sorted() raises:
    """Set membership: the values' order does not reach the key."""
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int(3))
    vals.append(ScalarValue.from_int(1))
    vals.append(ScalarValue.from_int(2))
    assert_equal(
        _expr_fingerprint(Expr.in_list_node(_c("a"), vals^)),
        "I:C:a[L:i1,L:i2,L:i3]",
    )
    var sorted = List[ScalarValue]()
    sorted.append(ScalarValue.from_int(1))
    sorted.append(ScalarValue.from_int(2))
    sorted.append(ScalarValue.from_int(3))
    assert_equal(
        _expr_fingerprint(Expr.in_list_node(_c("a"), sorted^)),
        "I:C:a[L:i1,L:i2,L:i3]",
    )
    # Reversed: every element moves, the last one all the way to the front.
    var rev = List[ScalarValue]()
    rev.append(ScalarValue.from_string(String("c")))
    rev.append(ScalarValue.from_string(String("b")))
    rev.append(ScalarValue.from_string(String("a")))
    assert_equal(
        _expr_fingerprint(Expr.in_list_node(_c("x"), rev^)),
        "I:C:x[L:sa,L:sb,L:sc]",
    )
    var one = List[ScalarValue]()
    one.append(ScalarValue.date32(Int32(4)))
    assert_equal(_expr_fingerprint(Expr.in_list_node(_c("a"), one^)), "I:C:a[L:d4]")


def test_math_functions_fold_op_and_children_in_order() raises:
    assert_equal(
        _expr_fingerprint(Expr.sqrt(_c("a"))), "M:" + _op(MATH_SQRT) + "(C:a)"
    )
    # atan2 is not commutative: (b, a) stays (b, a).
    assert_equal(
        _expr_fingerprint(Expr.atan2(_c("b"), _c("a"))),
        "M2:" + _op(MATH2_ATAN2) + "(C:b,C:a)",
    )


def test_string_op_folds_op_and_pattern() raises:
    assert_equal(
        _expr_fingerprint(Expr.string_op(STR_ENDS_WITH, _c("a"), String("pq"))),
        "S:" + _op(STR_ENDS_WITH) + ":pq(C:a)",
    )


def test_extract_folds_its_unit() raises:
    assert_equal(
        _expr_fingerprint(Expr.extract(EXTRACT_YEARWEEK, _c("d"))),
        "X:" + _op(EXTRACT_YEARWEEK) + "(C:d)",
    )


def test_regexp_folds_op_pattern_replacement_flags_and_group() raises:
    assert_equal(
        _expr_fingerprint(
            Expr.regexp_replace(_c("s"), String("p+"), String("r"), String("g"))
        ),
        "R:" + _op(REGEXP_REPLACE) + ":p+:r:g:0:(C:s)",
    )
    # Empty replacement and flags, group 1.
    assert_equal(
        _expr_fingerprint(Expr.regexp_extract(_c("s"), String("(x)"), 1)),
        "R:" + _op(REGEXP_EXTRACT) + ":(x):::1:(C:s)",
    )


def test_substring_folds_start_and_length() raises:
    assert_equal(_expr_fingerprint(Expr.substring(_c("s"), 3, 2)), "SUB:3:2(C:s)")


def test_string_fn_and_n_ary_string_fn() raises:
    assert_equal(
        _expr_fingerprint(Expr.string_fn(STRFN_LOWER, _c("s"))),
        "STRFN:" + _op(STRFN_LOWER) + "(C:s)",
    )
    var args = List[Expr]()
    args.append(_c("a"))
    args.append(_c("b"))
    args.append(_c("c"))
    # The argument count is folded, and the arguments in order.
    assert_equal(
        _expr_fingerprint(Expr.concat_ws(args^)),
        "STRFNN:" + _op(STRFNN_CONCAT_WS) + ":3(C:a,C:b,C:c)",
    )
    var one = List[Expr]()
    one.append(_c("ab"))
    assert_equal(
        _expr_fingerprint(Expr.concat_ws(one^)),
        "STRFNN:" + _op(STRFNN_CONCAT_WS) + ":1(C:ab)",
    )


def test_udf_call_folds_name_handle_and_output_type() raises:
    assert_equal(
        _expr_fingerprint(
            Expr.udf_call(
                String("f"), Optional[Int](7), ArrowType.INT64, ArrowType.FLOAT64, _c("a")
            )
        ),
        "UDF:f:7:12(C:a)",
    )
    # No handle: a `-` in its place.
    assert_equal(
        _expr_fingerprint(
            Expr.udf_call(
                String("f"), Optional[Int](), ArrowType.INT64, ArrowType.INT64, _c("a")
            )
        ),
        "UDF:f:-:5(C:a)",
    )


def test_json_extract_folds_path_output_type_and_flavour() raises:
    assert_equal(
        _expr_fingerprint(Expr.json_extract_json(_c("j"), String("$.user.id"))),
        "J:user.id:13:1(C:j)",
    )
    assert_equal(
        _expr_fingerprint(Expr.json_extract_string(_c("j"), String("$.k"))),
        "J:k:13:0(C:j)",
    )


def test_struct_and_map_access() raises:
    assert_equal(
        _expr_fingerprint(Expr.struct_field(_c("s"), String("city"))), "SF:city(C:s)"
    )
    assert_equal(_expr_fingerprint(Expr.struct_field_idx(_c("s"), 2)), "SFI:2(C:s)")
    assert_equal(
        _expr_fingerprint(
            Expr.map_get(_c("m"), Expr.literal(ScalarValue.from_string(String("k"))))
        ),
        "MG:(C:m)[L:sk]",
    )


def test_a_tag_with_no_arm_is_keyed_by_its_full_render() raises:
    """The fallback can only lose a dedup, never merge two values."""
    assert_equal(_expr_fingerprint(Expr.col_idx(3)), "?:1:ColIdx(3)")
    assert_equal(_expr_fingerprint(Expr.col_idx(4)), "?:1:ColIdx(4)")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
