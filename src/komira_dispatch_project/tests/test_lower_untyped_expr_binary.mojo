# =============================================================================
# test_lower_untyped_expr_binary.mojo: the translator's binary operators and
# the runtime family inference
# =============================================================================
#
# SUBJECT: `lower_untyped_expr_ops._translate_binary` (reached through
# `translate_expr`) and `lower_untyped_expr_dtype._infer_runtime_dtype`.
#
# The binary cases run a table: for each operator and each operand family
# (I64, F64, DECIMAL128, STRING, and a family with no node), the expected
# node kind or the expected refusal. The oracle is the kind of the root node.
# The inference cases assert the family of each tag.
#
# Each test names in its docstring the mutant that turns it red.
# =============================================================================

from std.collections import Dict
from std.testing import TestSuite, assert_true, assert_equal, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_eval.expression_executor import DecimalSpec
from komira_kernels.runtime_expr import (
    RuntimeExpr,
    EXPR_ADD_DECIMAL128,
    EXPR_ADD_F64,
    EXPR_ADD_I64,
    EXPR_AND,
    EXPR_DIV_F64,
    EXPR_DIV_I64,
    EXPR_EQ_DECIMAL128,
    EXPR_EQ_F64,
    EXPR_EQ_F64_MIXED,
    EXPR_EQ_I64,
    EXPR_EQ_STRING,
    EXPR_GE_DECIMAL128,
    EXPR_GE_F64,
    EXPR_GE_F64_MIXED,
    EXPR_GE_I64,
    EXPR_GE_STRING,
    EXPR_GT_DECIMAL128,
    EXPR_GT_F64,
    EXPR_GT_F64_MIXED,
    EXPR_GT_I64,
    EXPR_GT_STRING,
    EXPR_LE_DECIMAL128,
    EXPR_LE_F64,
    EXPR_LE_F64_MIXED,
    EXPR_LE_I64,
    EXPR_LE_STRING,
    EXPR_LT_DECIMAL128,
    EXPR_LT_F64,
    EXPR_LT_F64_MIXED,
    EXPR_LT_I64,
    EXPR_LT_STRING,
    EXPR_MUL_DECIMAL128,
    EXPR_MUL_F64,
    EXPR_MUL_I64,
    EXPR_NE_F64,
    EXPR_NE_I64,
    EXPR_NEQ_DECIMAL128,
    EXPR_NEQ_STRING,
    EXPR_OR,
    EXPR_SUB_DECIMAL128,
    EXPR_SUB_F64,
    EXPR_SUB_I64,
)
from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    BIN_ADD,
    BIN_AND,
    BIN_DIV,
    BIN_EQ,
    BIN_GE,
    BIN_GT,
    BIN_LE,
    BIN_LT,
    BIN_MOD,
    BIN_MUL,
    BIN_NE,
    BIN_OR,
    BIN_SUB,
    STR_LIKE,
    UN_IS_NOT_NULL,
    UN_IS_NULL,
    UN_NEGATE,
    UN_NOT,
)
from komira_plan_expr.scalar_value import ScalarValue

from komira_dispatch_project.lower_untyped_expr import (
    translate_expr,
    RUNTIME_DTYPE_BOOL,
    RUNTIME_DTYPE_BOOL_COL,
    RUNTIME_DTYPE_DECIMAL128,
    RUNTIME_DTYPE_F64,
    RUNTIME_DTYPE_I32,
    RUNTIME_DTYPE_I64,
    RUNTIME_DTYPE_STRING,
    RUNTIME_DTYPE_UNSUPPORTED,
)
from komira_dispatch_project.lower_untyped_expr_dtype import _infer_runtime_dtype


def _idx() -> Dict[String, Int]:
    var m = Dict[String, Int]()
    m["i"] = 0
    m["j"] = 1
    m["f"] = 2
    m["g"] = 3
    m["d"] = 4
    m["e"] = 5
    m["s"] = 6
    m["t"] = 7
    m["b"] = 8
    m["c"] = 9
    m["n"] = 10
    m["m"] = 11
    return m^


def _dt() -> Dict[String, Int]:
    """Two columns per family: I64 (i, j), F64 (f, g), DECIMAL128 (d, e),
    STRING (s, t), BOOL_COL (b, c), I32 (n, m)."""
    var m = Dict[String, Int]()
    m["i"] = RUNTIME_DTYPE_I64
    m["j"] = RUNTIME_DTYPE_I64
    m["f"] = RUNTIME_DTYPE_F64
    m["g"] = RUNTIME_DTYPE_F64
    m["d"] = RUNTIME_DTYPE_DECIMAL128
    m["e"] = RUNTIME_DTYPE_DECIMAL128
    m["s"] = RUNTIME_DTYPE_STRING
    m["t"] = RUNTIME_DTYPE_STRING
    m["b"] = RUNTIME_DTYPE_BOOL_COL
    m["c"] = RUNTIME_DTYPE_BOOL_COL
    m["n"] = RUNTIME_DTYPE_I32
    m["m"] = RUNTIME_DTYPE_I32
    return m^


def _root_kind(imm e: Expr) raises -> Int:
    var pool = List[RuntimeExpr]()
    var strings = List[String]()
    var decimals = List[DecimalSpec]()
    var in_lists = List[List[ScalarValue]]()
    var whens = List[List[Int]]()
    var root = translate_expr(
        e, pool, _idx(), _dt(), strings, decimals, in_lists, whens
    )
    return pool[root].kind


def _outcome(op: UInt8, l: StaticString, r: StaticString) -> String:
    """`kind=<n>` for the root of `l op r`, or the refusal's text."""
    try:
        var k = _root_kind(
            Expr.binary(op, Expr.col_ref(String(l)), Expr.col_ref(String(r)))
        )
        return String("kind=") + String(k)
    except err:
        return String(err)


def _kind(k: Int) -> String:
    return String("kind=") + String(k)


def _expect(op: UInt8, l: StaticString, r: StaticString, want: String) raises:
    var got = _outcome(op, l, r)
    assert_true(
        got == want or (not want.startswith("kind=") and got.find(want) >= 0),
        String(l) + " op " + String(Int(op)) + " " + String(r) + ": want `"
        + want + "`, got `" + got + "`",
    )


# =============================================================================
# The per-family table
# =============================================================================


def test_each_comparison_lowers_per_operand_family() raises:
    """GT, GE, LT, LE and EQ over I64, F64, DECIMAL128 and STRING operands,
    and the refusal over BOOL columns (a family with no comparison node).
    Mutant: the STRING arm of GE appending `make_gt_string` turns the
    `s >= t` row red."""
    var ops = List[UInt8]()
    ops.append(BIN_GT)
    ops.append(BIN_GE)
    ops.append(BIN_LT)
    ops.append(BIN_LE)
    ops.append(BIN_EQ)
    var i64 = List[Int]()
    var f64 = List[Int]()
    var dec = List[Int]()
    var st = List[Int]()
    var names = List[String]()
    i64.append(EXPR_GT_I64)
    f64.append(EXPR_GT_F64)
    dec.append(EXPR_GT_DECIMAL128)
    st.append(EXPR_GT_STRING)
    names.append("BIN_GT")
    i64.append(EXPR_GE_I64)
    f64.append(EXPR_GE_F64)
    dec.append(EXPR_GE_DECIMAL128)
    st.append(EXPR_GE_STRING)
    names.append("BIN_GE")
    i64.append(EXPR_LT_I64)
    f64.append(EXPR_LT_F64)
    dec.append(EXPR_LT_DECIMAL128)
    st.append(EXPR_LT_STRING)
    names.append("BIN_LT")
    i64.append(EXPR_LE_I64)
    f64.append(EXPR_LE_F64)
    dec.append(EXPR_LE_DECIMAL128)
    st.append(EXPR_LE_STRING)
    names.append("BIN_LE")
    i64.append(EXPR_EQ_I64)
    f64.append(EXPR_EQ_F64)
    dec.append(EXPR_EQ_DECIMAL128)
    st.append(EXPR_EQ_STRING)
    names.append("BIN_EQ")
    for k in range(len(ops)):
        _expect(ops[k], "i", "j", _kind(i64[k]))
        _expect(ops[k], "f", "g", _kind(f64[k]))
        _expect(ops[k], "d", "e", _kind(dec[k]))
        _expect(ops[k], "s", "t", _kind(st[k]))
        _expect(ops[k], "b", "c", names[k] + " on dtype-family 3")


def test_not_equal_lowers_per_operand_family() raises:
    """NE over STRING, DECIMAL128, I64 and F64, and the refusal over BOOL
    columns. Mutant: the I64 arm of NE removed (the I64 case then reaches the
    F64 test and the refusal)."""
    _expect(BIN_NE, "s", "t", _kind(EXPR_NEQ_STRING))
    _expect(BIN_NE, "d", "e", _kind(EXPR_NEQ_DECIMAL128))
    _expect(BIN_NE, "i", "j", _kind(EXPR_NE_I64))
    _expect(BIN_NE, "f", "g", _kind(EXPR_NE_F64))
    _expect(BIN_NE, "b", "c", "BIN_NE on dtype-family 3")


def test_each_arithmetic_operator_lowers_per_operand_family() raises:
    """ADD, SUB and MUL over I64, F64 and DECIMAL128, and the refusal over
    STRING operands. Mutant: the DECIMAL128 arm of SUB appending
    `make_add_decimal128`."""
    _expect(BIN_ADD, "i", "j", _kind(EXPR_ADD_I64))
    _expect(BIN_ADD, "f", "g", _kind(EXPR_ADD_F64))
    _expect(BIN_ADD, "d", "e", _kind(EXPR_ADD_DECIMAL128))
    _expect(BIN_ADD, "s", "t", "BIN_ADD on dtype-family 4")
    _expect(BIN_SUB, "i", "j", _kind(EXPR_SUB_I64))
    _expect(BIN_SUB, "f", "g", _kind(EXPR_SUB_F64))
    _expect(BIN_SUB, "d", "e", _kind(EXPR_SUB_DECIMAL128))
    _expect(BIN_SUB, "s", "t", "BIN_SUB on dtype-family 4")
    _expect(BIN_MUL, "i", "j", _kind(EXPR_MUL_I64))
    _expect(BIN_MUL, "f", "g", _kind(EXPR_MUL_F64))
    _expect(BIN_MUL, "d", "e", _kind(EXPR_MUL_DECIMAL128))
    _expect(BIN_MUL, "s", "t", "BIN_MUL on dtype-family 4")


def test_division_lowers_for_i64_and_f64_and_refuses_decimal() raises:
    """I64 / I64 is EXPR_DIV_I64, F64 / F64 is EXPR_DIV_F64; DECIMAL /
    DECIMAL is refused by name (its result type is DOUBLE and there is no
    DECIMAL -> DOUBLE node), and STRING operands are refused. Mutant: the
    DECIMAL128 arm appending `make_div_decimal128` instead of raising."""
    _expect(BIN_DIV, "i", "j", _kind(EXPR_DIV_I64))
    _expect(BIN_DIV, "f", "g", _kind(EXPR_DIV_F64))
    _expect(BIN_DIV, "d", "e", "DECIMAL / DECIMAL divides as DOUBLE")
    _expect(BIN_DIV, "s", "t", "BIN_DIV on dtype-family 4")


def test_modulo_is_refused() raises:
    """Mutant: a MOD arm appending `make_div_i64` would lower it."""
    _expect(BIN_MOD, "i", "j", "binary-op code 4 not in")


# =============================================================================
# Logical operators and mixed families
# =============================================================================


def test_and_and_or_lower_over_any_operands() raises:
    """AND and OR translate both operands and append EXPR_AND / EXPR_OR; they
    do not compare families. Mutant: the OR arm appending `make_and`."""
    _expect(BIN_AND, "b", "c", _kind(EXPR_AND))
    _expect(BIN_OR, "b", "c", _kind(EXPR_OR))


def test_a_mixed_f64_i64_pair_lowers_to_the_f64_node_both_ways_round() raises:
    """The five comparisons other than NE take their `_mixed` node, and the
    four arithmetic operators their F64 node, with either operand order.
    Mutant: the `is_mixed_f64_i64` test reduced to its first disjunct turns
    every `i op f` case red."""
    var ops = List[UInt8]()
    var kinds = List[Int]()
    ops.append(BIN_LT)
    kinds.append(EXPR_LT_F64_MIXED)
    ops.append(BIN_LE)
    kinds.append(EXPR_LE_F64_MIXED)
    ops.append(BIN_GT)
    kinds.append(EXPR_GT_F64_MIXED)
    ops.append(BIN_GE)
    kinds.append(EXPR_GE_F64_MIXED)
    ops.append(BIN_EQ)
    kinds.append(EXPR_EQ_F64_MIXED)
    ops.append(BIN_ADD)
    kinds.append(EXPR_ADD_F64)
    ops.append(BIN_SUB)
    kinds.append(EXPR_SUB_F64)
    ops.append(BIN_MUL)
    kinds.append(EXPR_MUL_F64)
    ops.append(BIN_DIV)
    kinds.append(EXPR_DIV_F64)
    for k in range(len(ops)):
        _expect(ops[k], "f", "i", _kind(kinds[k]))
        _expect(ops[k], "i", "f", _kind(kinds[k]))


def test_every_other_family_mismatch_is_refused() raises:
    """NE over a mixed pair, I64 against DECIMAL128, I64 against I32, and an
    operand with no family at all. Mutant: the mismatch refusal removed (I64
    against DECIMAL128 then lowers by the left family)."""
    _expect(BIN_NE, "f", "i", "runtime-dtype mismatch")
    _expect(BIN_ADD, "i", "d", "runtime-dtype mismatch")
    _expect(BIN_ADD, "i", "n", "runtime-dtype mismatch")
    _expect(BIN_ADD, "f", "d", "runtime-dtype mismatch")
    var msg = String("")
    try:
        _ = _root_kind(
            Expr.binary(BIN_ADD, Expr.col_ref(String("i")), Expr.col_idx(0))
        )
    except err:
        msg = String(err)
    assert_true(
        msg.find("operand has unsupported runtime-dtype-family") >= 0,
        "an operand with no family is refused: " + msg,
    )
    msg = String("")
    try:
        _ = _root_kind(
            Expr.binary(BIN_ADD, Expr.col_idx(0), Expr.col_ref(String("i")))
        )
    except err:
        msg = String(err)
    assert_true(
        msg.find("operand has unsupported runtime-dtype-family") >= 0,
        "a left operand with no family is refused: " + msg,
    )


# =============================================================================
# _infer_runtime_dtype
# =============================================================================


def _fam(imm e: Expr) raises -> Int:
    return _infer_runtime_dtype(e, _dt())


def _lit(var sv: ScalarValue) -> Expr:
    return Expr.literal(sv^)


def test_the_family_of_each_leaf() raises:
    """A column's family is its map entry (UNSUPPORTED when absent); a literal's
    follows its kind: DATE32 and TIMESTAMP I64, DECIMAL128, STRING, integer
    I64, float F64, bool BOOL, and NULL, uint64 and an interval UNSUPPORTED.
    Mutant: the DATE32 arm answering F64."""
    assert_equal(_fam(Expr.col_ref(String("d"))), RUNTIME_DTYPE_DECIMAL128)
    assert_equal(_fam(Expr.col_ref(String("zz"))), RUNTIME_DTYPE_UNSUPPORTED)
    assert_equal(_fam(_lit(ScalarValue.date32(Int32(1)))), RUNTIME_DTYPE_I64)
    assert_equal(
        _fam(_lit(ScalarValue.timestamp_micros(Int64(1)))), RUNTIME_DTYPE_I64
    )
    assert_equal(
        _fam(_lit(ScalarValue.decimal128(Int64(0), Int64(1), 5, 1))),
        RUNTIME_DTYPE_DECIMAL128,
    )
    assert_equal(_fam(_lit(ScalarValue.from_string(String("")))), RUNTIME_DTYPE_STRING)
    assert_equal(_fam(_lit(ScalarValue.from_int32(Int32(3)))), RUNTIME_DTYPE_I64)
    assert_equal(_fam(_lit(ScalarValue.from_float32(Float32(1.0)))), RUNTIME_DTYPE_F64)
    assert_equal(_fam(_lit(ScalarValue.from_float(1.0))), RUNTIME_DTYPE_F64)
    assert_equal(_fam(_lit(ScalarValue.from_bool(False))), RUNTIME_DTYPE_BOOL)
    assert_equal(_fam(_lit(ScalarValue.null(DType.int64))), RUNTIME_DTYPE_UNSUPPORTED)
    assert_equal(_fam(_lit(ScalarValue.from_uint64(UInt64(1)))), RUNTIME_DTYPE_UNSUPPORTED)
    assert_equal(
        _fam(_lit(ScalarValue.interval_month_day_nano(Int32(1), Int32(0), Int64(0)))),
        RUNTIME_DTYPE_UNSUPPORTED,
    )


def test_the_family_of_each_operator() raises:
    """Every comparison and AND / OR is BOOL; arithmetic is F64 when either
    operand is F64 (either side), else the left family; MOD is UNSUPPORTED;
    NOT and the null tests are BOOL, negation UNSUPPORTED; a string op BOOL;
    an alias its child's. Mutant: the right operand's F64 test removed from
    the arithmetic rule (`i * f` then answers I64)."""
    var cmp = List[UInt8]()
    cmp.append(BIN_EQ)
    cmp.append(BIN_NE)
    cmp.append(BIN_LT)
    cmp.append(BIN_LE)
    cmp.append(BIN_GT)
    cmp.append(BIN_GE)
    cmp.append(BIN_AND)
    cmp.append(BIN_OR)
    for k in range(len(cmp)):
        assert_equal(
            _fam(Expr.binary(cmp[k], Expr.col_ref(String("i")), Expr.col_ref(String("j")))),
            RUNTIME_DTYPE_BOOL,
        )
    var ar = List[UInt8]()
    ar.append(BIN_ADD)
    ar.append(BIN_SUB)
    ar.append(BIN_MUL)
    ar.append(BIN_DIV)
    for k in range(len(ar)):
        assert_equal(
            _fam(Expr.binary(ar[k], Expr.col_ref(String("i")), Expr.col_ref(String("f")))),
            RUNTIME_DTYPE_F64,
        )
        assert_equal(
            _fam(Expr.binary(ar[k], Expr.col_ref(String("f")), Expr.col_ref(String("i")))),
            RUNTIME_DTYPE_F64,
        )
        assert_equal(
            _fam(Expr.binary(ar[k], Expr.col_ref(String("n")), Expr.col_ref(String("i")))),
            RUNTIME_DTYPE_I32,
            "neither side F64: the left family",
        )
    assert_equal(
        _fam(Expr.binary(BIN_MOD, Expr.col_ref(String("i")), Expr.col_ref(String("j")))),
        RUNTIME_DTYPE_UNSUPPORTED,
    )
    assert_equal(_fam(Expr.unary(UN_NOT, Expr.col_ref(String("b")))), RUNTIME_DTYPE_BOOL)
    assert_equal(_fam(Expr.unary(UN_IS_NULL, Expr.col_ref(String("i")))), RUNTIME_DTYPE_BOOL)
    assert_equal(
        _fam(Expr.unary(UN_IS_NOT_NULL, Expr.col_ref(String("i")))), RUNTIME_DTYPE_BOOL
    )
    assert_equal(_fam(Expr.unary(UN_NEGATE, Expr.col_ref(String("i")))), RUNTIME_DTYPE_UNSUPPORTED)
    assert_equal(
        _fam(Expr.string_op(STR_LIKE, Expr.col_ref(String("s")), String("a%"))),
        RUNTIME_DTYPE_BOOL,
    )
    assert_equal(_fam(Expr.alias(Expr.col_ref(String("s")), String("x"))), RUNTIME_DTYPE_STRING)


def test_the_family_of_math_cast_case_and_other_tags() raises:
    """Unary and binary math are F64. A FLOAT64 cast is F64 over an I64 or F64
    operand and UNSUPPORTED over any other, and every other target is
    UNSUPPORTED. A CASE is F64 when a THEN or the ELSE is F64, else I64. Any
    other tag is UNSUPPORTED. Mutant: the cast's operand check removed (the
    STRING operand then answers F64)."""
    assert_equal(_fam(Expr.sqrt(Expr.col_ref(String("i")))), RUNTIME_DTYPE_F64)
    assert_equal(
        _fam(Expr.atan2(Expr.col_ref(String("i")), Expr.col_ref(String("j")))),
        RUNTIME_DTYPE_F64,
    )
    assert_equal(_fam(Expr.cast(Expr.col_ref(String("i")), DType.float64)), RUNTIME_DTYPE_F64)
    assert_equal(_fam(Expr.cast(Expr.col_ref(String("f")), DType.float64)), RUNTIME_DTYPE_F64)
    assert_equal(
        _fam(Expr.cast(Expr.col_ref(String("s")), DType.float64)), RUNTIME_DTYPE_UNSUPPORTED
    )
    assert_equal(
        _fam(Expr.cast(Expr.col_ref(String("i")), DType.int32)), RUNTIME_DTYPE_UNSUPPORTED
    )
    assert_equal(
        _fam(Expr.cast_to_arrow(Expr.col_ref(String("i")), ArrowType.FLOAT32)),
        RUNTIME_DTYPE_UNSUPPORTED,
    )
    assert_equal(
        _fam(
            Expr.cast_from_parts(
                Expr.col_ref(String("i")), DType.float64, ArrowType.FLOAT32, 0, 0, False
            )
        ),
        RUNTIME_DTYPE_UNSUPPORTED,
        "a float64 DType over a FLOAT32 Arrow target",
    )

    var c1 = List[WhenCaseData]()
    c1.append(WhenCaseData(Expr.col_ref(String("b")), Expr.col_ref(String("i"))))
    c1.append(WhenCaseData(Expr.col_ref(String("c")), Expr.col_ref(String("f"))))
    assert_equal(
        _fam(Expr.when(c1^, Expr.col_ref(String("j")))),
        RUNTIME_DTYPE_F64,
        "a F64 THEN in the second case",
    )
    var c2 = List[WhenCaseData]()
    c2.append(WhenCaseData(Expr.col_ref(String("b")), Expr.col_ref(String("i"))))
    assert_equal(
        _fam(Expr.when(c2^, Expr.col_ref(String("g")))),
        RUNTIME_DTYPE_F64,
        "a F64 ELSE",
    )
    var c3 = List[WhenCaseData]()
    c3.append(WhenCaseData(Expr.col_ref(String("b")), Expr.col_ref(String("i"))))
    assert_equal(
        _fam(Expr.when(c3^, Expr.col_ref(String("j")))), RUNTIME_DTYPE_I64
    )
    assert_equal(_fam(Expr.col_idx(0)), RUNTIME_DTYPE_UNSUPPORTED)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
