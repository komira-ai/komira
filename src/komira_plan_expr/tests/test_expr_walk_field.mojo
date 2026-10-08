# =============================================================================
# test_expr_walk_field.mojo: `walk_expr_field`, the output-Field inference of
# every Expr tag, under both column-reference policies.
#
# Each test builds one expression over a fixed schema and checks the Field's
# name, Arrow type, nullability and (for DECIMAL128) precision and scale. The
# expected values are worked out from komira's own documented rules (the
# function's comments and `decimal_arith`: `+ -` give scale max(s1, s2) and
# precision min(max(p1-s1, p2-s2) + scale + 1, 38), `*` gives scale s1+s2 and
# precision min(p1+p2+1, 38), `%` keeps the left operand's (p, s)). These
# tests pin komira's rules; for `*` and `%` they differ from DuckDB, which
# gives DECIMAL(22,6) and DECIMAL(14,4) for the D(12,2), D(10,4) pair here.
# =============================================================================

from std.collections import Optional
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.dtype_sentinel import DTYPE_NONE
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.agg_expr import AGG_SUM
from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    EXPR_BETWEEN,
    EXPR_SORT_KEY,
    BIN_ADD, BIN_SUB, BIN_MUL, BIN_DIV, BIN_MOD,
    BIN_EQ, BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE, BIN_AND, BIN_OR,
    UN_NOT, UN_NEGATE, UN_IS_NULL, UN_IS_NOT_NULL, UN_ABS, UN_SIGN,
    UN_BIT_COUNT, UN_TRUNC, UN_ROUND,
    STR_LIKE,
    REGEXP_LIKE, REGEXP_MATCH, REGEXP_REPLACE, REGEXP_EXTRACT,
    REGEXP_SPLIT_TO_ARRAY, REGEXP_EXTRACT_ALL, REGEXP_COUNT, REGEXP_INSTR,
    REGEXP_SUBSTR, REGEXP_FULL_MATCH,
    EXTRACT_YEAR, EXTRACT_TRUNC_MONTH,
    STRFNN_STRPOS, STRFNN_JARO,
)
from komira_plan_expr.expr_walk import (
    walk_expr_field,
    ExecColRefFields,
    PlanColRefFields,
)


def _schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, True))
    sb.add_field(Field("f", ArrowType.FLOAT64, True))
    sb.add_field(Field("i", ArrowType.INT32, False))
    sb.add_field(Field("i16", ArrowType.INT16, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("flag", ArrowType.BOOL, True))
    sb.add_field(Field.decimal128("d1", 12, 2, True))
    sb.add_field(Field.decimal128("d2", 10, 4, False))
    sb.add_field(Field("iv", ArrowType.INTERVAL_MONTH_DAY_NANO, True))
    sb.add_field(Field.timestamp("ts", ArrowType.TIMESTAMP_US, "UTC", True))
    var st = Field("st", ArrowType.STRUCT, True)
    st.add_child("x", ArrowType.INT32, False)
    st.add_child("y", ArrowType.STRING, True)
    sb.add_field(st^)
    var m = Field("m", ArrowType.MAP, True)
    m.add_child("key", ArrowType.STRING, False)
    m.add_child("value", ArrowType.INT64, True)
    sb.add_field(m^)
    var m1 = Field("m1", ArrowType.MAP, True)
    m1.add_child("key", ArrowType.STRING, False)
    sb.add_field(m1^)
    var meta = Field("meta", ArrowType.INT64, True)
    meta.set_metadata("origin", "sensor")
    sb.add_field(meta^)
    return sb.build()


def _x(e: Expr) raises -> Field:
    """The Field under the execution policy; no column may be missing."""
    var missing = String("")
    var f = walk_expr_field[ExecColRefFields](e, _schema(), missing)
    assert_equal(missing, "")
    return f^


def _p(e: Expr) raises -> Field:
    """The Field under the plan policy; no column may be missing."""
    var missing = String("")
    var f = walk_expr_field[PlanColRefFields](e, _schema(), missing)
    assert_equal(missing, "")
    return f^


def _c(name: String) -> Expr:
    return Expr.col_ref(name)


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _bin(op: UInt8, var l: Expr, var r: Expr) -> Expr:
    return Expr.binary(op, l^, r^)


def _is(f: Field, name: String, at: ArrowType, nullable: Bool) raises:
    assert_equal(f.name, name)
    assert_true(f.arrow_type == at, String("arrow type of ") + name + ": " + String(f.arrow_type))
    assert_equal(f.nullable, nullable)


def _dec(f: Field, p: Int, s: Int) raises:
    assert_true(f.arrow_type == ArrowType.DECIMAL128, String(f.arrow_type))
    assert_equal(f.decimal_precision, p)
    assert_equal(f.decimal_scale, s)


def test_col_ref_exec_policy_full_clone() raises:
    """Execution policy: the schema's Field with every slot, field metadata
    included; a column past the first is found."""
    var f = _x(_c("meta"))
    _is(f, "meta", ArrowType.INT64, True)
    assert_equal(f.metadata_count(), 1)
    var d = _x(_c("d2"))
    _is(d, "d2", ArrowType.DECIMAL128, False)
    _dec(d, 10, 4)
    assert_equal(_x(_c("ts")).timezone(), "UTC")


def test_col_ref_plan_policy_narrow_clone() raises:
    """Plan policy: name, type, nullability, decimal (p, s), timezone and
    children are carried; field metadata is not."""
    var f = _p(_c("meta"))
    _is(f, "meta", ArrowType.INT64, True)
    assert_equal(f.metadata_count(), 0)
    _dec(_p(_c("d1")), 12, 2)
    assert_equal(_p(_c("ts")).timezone(), "UTC")
    var st = _p(_c("st"))
    assert_equal(st.num_children(), 2)
    assert_equal(st.child_name(1), "y")
    assert_true(st.child_arrow_type(1) == ArrowType.STRING)
    assert_true(st.child_nullable(1))
    assert_false(st.child_nullable(0))
    assert_equal(_p(_c("a")).num_children(), 0)


def test_missing_column_both_policies_first_miss_wins() raises:
    """A missing column is a nullable NULL-typed Field named after it, and
    `missing` reports the FIRST (leftmost) miss, under either policy."""
    var e = _bin(BIN_ADD, _c("gone1"), _bin(BIN_ADD, _c("a"), _c("gone2")))
    var miss = String("")
    var f = walk_expr_field[ExecColRefFields](_c("gone1"), _schema(), miss)
    _is(f, "gone1", ArrowType.NULL, True)
    assert_equal(miss, "gone1")
    var miss_x = String("")
    _ = walk_expr_field[ExecColRefFields](e, _schema(), miss_x)
    assert_equal(miss_x, "gone1")
    var miss_p = String("")
    var g = walk_expr_field[PlanColRefFields](_c("gone2"), _schema(), miss_p)
    _is(g, "gone2", ArrowType.NULL, True)
    assert_equal(miss_p, "gone2")
    var miss_p2 = String("")
    _ = walk_expr_field[PlanColRefFields](e, _schema(), miss_p2)
    assert_equal(miss_p2, "gone1")


def test_alias_renames_and_keeps_metadata() raises:
    """An alias renames the child's Field and keeps the rest of it: decimal
    (p, s), timezone, key-value field metadata (execution policy, which
    carries it) and STRUCT children."""
    var d = _x(Expr.alias(_c("d1"), "price"))
    _is(d, "price", ArrowType.DECIMAL128, True)
    _dec(d, 12, 2)
    var t = _p(Expr.alias(_c("ts"), "when_utc"))
    _is(t, "when_utc", ArrowType.TIMESTAMP_US, True)
    assert_equal(t.timezone(), "UTC")
    var m = _x(Expr.alias(_c("meta"), "tagged"))
    _is(m, "tagged", ArrowType.INT64, True)
    assert_equal(m.metadata_count(), 1)
    assert_equal(m.get_metadata("origin").value(), "sensor")
    var st = _p(Expr.alias(_c("st"), "point"))
    _is(st, "point", ArrowType.STRUCT, True)
    assert_equal(st.num_children(), 2)
    assert_equal(st.child_name(0), "x")
    assert_true(st.child_arrow_type(0) == ArrowType.INT32)
    assert_false(st.child_nullable(0))
    assert_equal(st.child_name(1), "y")
    assert_true(st.child_nullable(1))


def test_literals() raises:
    """Every literal is a non-null Field named `literal`: DECIMAL128 with its
    (p, s) (precision 0 reads as 38), STRING, DATE32, TIMESTAMP_US, a typed
    NULL as its declared type, an untyped NULL as NULL, and the numeric and
    boolean kinds as their own type."""
    var d = _x(Expr.literal(ScalarValue.decimal128(0, 12345, 9, 3)))
    _is(d, "literal", ArrowType.DECIMAL128, False)
    _dec(d, 9, 3)
    _dec(_x(Expr.literal(ScalarValue.decimal128(0, 1, 0, 0))), 38, 0)
    _is(_x(Expr.literal(ScalarValue.from_string("x"))), "literal", ArrowType.STRING, False)
    _is(_x(Expr.literal(ScalarValue.from_string(""))), "literal", ArrowType.STRING, False)
    _is(_x(Expr.literal(ScalarValue.date32(20734))), "literal", ArrowType.DATE32, False)
    _is(_x(Expr.literal(ScalarValue.timestamp_micros(1791417600000000))), "literal", ArrowType.TIMESTAMP_US, False)
    _is(_x(Expr.literal(ScalarValue.null(DType.int32))), "literal", ArrowType.INT32, False)
    _is(_x(Expr.literal(ScalarValue())), "literal", ArrowType.NULL, False)
    _is(_x(_lit(7)), "literal", ArrowType.INT64, False)
    _is(_x(Expr.literal(ScalarValue.from_float32(1.5))), "literal", ArrowType.FLOAT32, False)
    _is(_x(Expr.literal(ScalarValue.from_bool(True))), "literal", ArrowType.BOOL, False)


def test_comparisons_and_logic_are_bool() raises:
    """Every comparison and AND/OR is a nullable BOOL whatever its operands
    (a string column compared is BOOL, not STRING)."""
    var ops: List[UInt8] = [BIN_EQ, BIN_NE, BIN_LT, BIN_LE, BIN_GT, BIN_GE, BIN_AND, BIN_OR]
    for k in range(len(ops)):
        _is(_x(_bin(ops[k], _c("s"), _c("s"))), "expr", ArrowType.BOOL, True)


def test_interval_arithmetic() raises:
    """INTERVAL +/- INTERVAL is INTERVAL_MONTH_DAY_NANO. The last two rows
    (INTERVAL * INTERVAL, INTERVAL + INT64) only pin the generic fall-through
    (the left operand's type): evaluation raises for both, so the declared
    type is not a contract, and a change that declared something else for
    them would be legitimate."""
    _is(_x(_bin(BIN_ADD, _c("iv"), _c("iv"))), "expr", ArrowType.INTERVAL_MONTH_DAY_NANO, True)
    _is(_x(_bin(BIN_SUB, _c("iv"), _c("iv"))), "expr", ArrowType.INTERVAL_MONTH_DAY_NANO, True)
    _is(_x(_bin(BIN_MUL, _c("iv"), _c("iv"))), "expr", ArrowType.INTERVAL_MONTH_DAY_NANO, True)
    _is(_x(_bin(BIN_ADD, _c("iv"), _c("a"))), "expr", ArrowType.INTERVAL_MONTH_DAY_NANO, True)


def test_decimal_with_decimal() raises:
    """D(12,2) op D(10,4): + and - give (15, 4); * gives (23, 6); / is
    FLOAT64; % keeps the left operand's (12, 2)."""
    var add = _x(_bin(BIN_ADD, _c("d1"), _c("d2")))
    _is(add, "expr", ArrowType.DECIMAL128, True)
    _dec(add, 15, 4)
    _dec(_x(_bin(BIN_SUB, _c("d1"), _c("d2"))), 15, 4)
    _dec(_x(_bin(BIN_MUL, _c("d1"), _c("d2"))), 23, 6)
    _is(_x(_bin(BIN_DIV, _c("d1"), _c("d2"))), "expr", ArrowType.FLOAT64, True)
    _dec(_x(_bin(BIN_MOD, _c("d1"), _c("d2"))), 12, 2)
    _dec(_x(_bin(BIN_MOD, _c("d2"), _c("d1"))), 10, 4)


def test_decimal_with_float_is_float64() raises:
    """A decimal with a FLOAT64, on either side, is FLOAT64."""
    _is(_x(_bin(BIN_ADD, _c("d1"), _c("f"))), "expr", ArrowType.FLOAT64, True)
    _is(_x(_bin(BIN_MUL, _c("f"), _c("d1"))), "expr", ArrowType.FLOAT64, True)


def test_decimal_with_int64_per_op() raises:
    """D(12,2) with an INT64 (taken as D(19, 0)), on either side: / is
    FLOAT64; * is (min(12+19+1, 38), 2+0) = (32, 2); + and - align at scale
    2 with 19 integer digits: (min(19+2+1, 38), 2) = (22, 2); % keeps the
    decimal side's (12, 2)."""
    _is(_x(_bin(BIN_DIV, _c("d1"), _c("a"))), "expr", ArrowType.FLOAT64, True)
    _is(_x(_bin(BIN_DIV, _c("a"), _c("d1"))), "expr", ArrowType.FLOAT64, True)
    _dec(_x(_bin(BIN_MUL, _c("d1"), _c("a"))), 32, 2)
    _dec(_x(_bin(BIN_MUL, _c("a"), _c("d1"))), 32, 2)
    _dec(_x(_bin(BIN_ADD, _c("d1"), _c("a"))), 22, 2)
    _dec(_x(_bin(BIN_SUB, _c("a"), _c("d1"))), 22, 2)
    _dec(_x(_bin(BIN_MOD, _c("d1"), _c("a"))), 12, 2)
    _dec(_x(_bin(BIN_ADD, _c("d2"), _c("b"))), 24, 4)


def test_decimal_with_other_int_keeps_decimal_side() raises:
    """A decimal with a non-INT64 integer keeps the decimal side's (p, s),
    whichever side it is on."""
    _dec(_x(_bin(BIN_ADD, _c("d1"), _c("i"))), 12, 2)
    _dec(_x(_bin(BIN_MUL, _c("i"), _c("d2"))), 10, 4)


def test_generic_arithmetic_promotion() raises:
    """Left type wins, FLOAT64 on either side promotes to FLOAT64."""
    _is(_x(_bin(BIN_ADD, _c("a"), _c("b"))), "expr", ArrowType.INT64, True)
    _is(_x(_bin(BIN_ADD, _c("a"), _c("f"))), "expr", ArrowType.FLOAT64, True)
    _is(_x(_bin(BIN_SUB, _c("f"), _c("a"))), "expr", ArrowType.FLOAT64, True)
    _is(_x(_bin(BIN_ADD, _c("i"), _c("b"))), "expr", ArrowType.INT32, True)


def test_int32_with_out_of_range_literal_widens() raises:
    """INT32 (arith) int literal: INT64 when the literal does not fit in
    int32 (one past either bound), INT32 when it does (the bounds
    themselves); not for %, not for a non-integer literal, not for a
    non-INT32 left operand."""
    _is(_x(_bin(BIN_ADD, _c("i"), _lit(2147483648))), "expr", ArrowType.INT64, True)
    _is(_x(_bin(BIN_SUB, _c("i"), _lit(-2147483649))), "expr", ArrowType.INT64, True)
    _is(_x(_bin(BIN_MUL, _c("i"), _lit(3000000000))), "expr", ArrowType.INT64, True)
    _is(_x(_bin(BIN_DIV, _c("i"), _lit(3000000000))), "expr", ArrowType.INT64, True)
    _is(_x(_bin(BIN_ADD, _c("i"), _lit(2147483647))), "expr", ArrowType.INT32, True)
    _is(_x(_bin(BIN_SUB, _c("i"), _lit(-2147483648))), "expr", ArrowType.INT32, True)
    _is(_x(_bin(BIN_MOD, _c("i"), _lit(3000000000))), "expr", ArrowType.INT32, True)
    _is(
        _x(_bin(BIN_ADD, _c("i"), Expr.literal(ScalarValue.from_bool(True)))),
        "expr", ArrowType.INT32, True,
    )
    _is(_x(_bin(BIN_ADD, _c("i16"), _lit(3000000000))), "expr", ArrowType.INT16, True)


def test_unary_ops() raises:
    """NOT, SIGN, BIT_COUNT and the null tests have fixed types (the null
    tests non-nullable); NEGATE, ABS, TRUNC and ROUND keep the operand's type
    and nullability."""
    _is(_x(Expr.unary(UN_NOT, _c("flag"))), "not", ArrowType.BOOL, True)
    _is(_x(Expr.unary(UN_SIGN, _c("f"))), "sign", ArrowType.INT8, True)
    _is(_x(Expr.unary(UN_BIT_COUNT, _c("a"))), "bit_count", ArrowType.INT8, True)
    _is(_x(Expr.unary(UN_IS_NULL, _c("b"))), "is_null", ArrowType.BOOL, False)
    _is(_x(Expr.unary(UN_IS_NOT_NULL, _c("b"))), "is_not_null", ArrowType.BOOL, False)
    _is(_x(Expr.unary(UN_ABS, _c("i"))), "abs", ArrowType.INT32, False)
    _is(_x(Expr.unary(UN_TRUNC, _c("f"))), "trunc", ArrowType.FLOAT64, True)
    _is(_x(Expr.unary(UN_ROUND, _c("i16"))), "round", ArrowType.INT16, True)
    _is(_x(Expr.unary(UN_NEGATE, _c("a"))), "neg", ArrowType.INT64, False)


def test_casts() raises:
    """A cast keeps the child's name and nullability with the target type; a
    TRY cast is nullable over a non-null child; a DECIMAL cast carries its
    (p, s) and its child's nullability, and a TRY DECIMAL cast is nullable
    over a non-null child too."""
    _is(_x(Expr.cast(_c("a"), DType.float64)), "a", ArrowType.FLOAT64, False)
    _is(_x(Expr.cast(_c("b"), DType.int32)), "b", ArrowType.INT32, True)
    _is(_x(Expr.try_cast(_c("a"), DType.int32)), "a", ArrowType.INT32, True)
    var d = _x(Expr.cast_to_decimal(_c("a"), 10, 3))
    _is(d, "a", ArrowType.DECIMAL128, False)
    _dec(d, 10, 3)
    var dn = _x(Expr.cast_to_decimal(_c("b"), 18, 0))
    _is(dn, "b", ArrowType.DECIMAL128, True)
    _dec(dn, 18, 0)
    var t = _x(Expr.cast_from_parts(_c("a"), DTYPE_NONE, ArrowType.DECIMAL128, 9, 2, True))
    _is(t, "a", ArrowType.DECIMAL128, True)
    _dec(t, 9, 2)


def test_regexp_ops() raises:
    """Each regexp op's documented output: BOOL for the two matches, a
    LIST<STRING> for the three list-producing ops, STRING for replace and
    substr, INT64 for count and instr, and STRING for extract (the tail)."""
    _is(_x(Expr.regexp(REGEXP_LIKE, _c("s"), "p")), "regexp_like", ArrowType.BOOL, True)
    _is(_x(Expr.regexp(REGEXP_FULL_MATCH, _c("s"), "p")), "regexp_full_match", ArrowType.BOOL, True)
    var m = _x(Expr.regexp(REGEXP_MATCH, _c("s"), "p"))
    _is(m, "regexp_match", ArrowType.LIST, True)
    assert_equal(m.num_children(), 1)
    assert_true(m.child_arrow_type(0) == ArrowType.STRING)
    _is(_x(Expr.regexp(REGEXP_SPLIT_TO_ARRAY, _c("s"), "p")), "regexp_split", ArrowType.LIST, True)
    _is(_x(Expr.regexp(REGEXP_EXTRACT_ALL, _c("s"), "p")), "regexp_extract_all", ArrowType.LIST, True)
    _is(_x(Expr.regexp(REGEXP_REPLACE, _c("s"), "p", "q")), "regexp_replace", ArrowType.STRING, True)
    _is(_x(Expr.regexp(REGEXP_SUBSTR, _c("s"), "p")), "regexp_substr", ArrowType.STRING, True)
    _is(_x(Expr.regexp(REGEXP_COUNT, _c("s"), "p")), "regexp_count", ArrowType.INT64, True)
    _is(_x(Expr.regexp(REGEXP_INSTR, _c("s"), "p")), "regexp_instr", ArrowType.INT64, True)
    _is(_x(Expr.regexp(REGEXP_EXTRACT, _c("s"), "p")), "regexp", ArrowType.STRING, True)


def test_when_first_case_result_or_default() raises:
    """CASE takes the FIRST case's result type (not a later one's, not the
    default's); with no case, the default's."""
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(_c("flag"), _c("f")))
    cases.append(WhenCaseData(_c("flag"), _c("s")))
    _is(_x(Expr.when(cases^, _c("a"))), "case", ArrowType.FLOAT64, True)
    _is(_x(Expr.when(List[WhenCaseData](), _c("i16"))), "case", ArrowType.INT16, True)


def test_fixed_type_tags() raises:
    """The tags whose type does not depend on the operand."""
    _is(_x(Expr.string_op(STR_LIKE, _c("s"), "p%")), "str_op", ArrowType.BOOL, True)
    var vals: List[ScalarValue] = [ScalarValue.from_int(1)]
    _is(_x(Expr.in_list_node(_c("a"), vals^)), "in_list", ArrowType.BOOL, True)
    _is(_x(Expr(EXPR_BETWEEN)), "between", ArrowType.BOOL, True)
    _is(_x(Expr.substring(_c("s"), 1, 2)), "substring", ArrowType.STRING, True)
    _is(_x(Expr.sqrt(_c("a"))), "math_fn", ArrowType.FLOAT64, True)
    _is(_x(Expr.atan2(_c("a"), _c("b"))), "math_fn", ArrowType.FLOAT64, True)
    _is(_x(Expr.extract(EXTRACT_YEAR, _c("ts"))), "extract", ArrowType.INT64, True)


def test_string_functions() raises:
    """One-argument string functions are STRING or, for the counting ones,
    INT64; the variadic family is STRING, INT64 (strpos) or FLOAT64 (jaro)."""
    _is(_x(Expr.upper(_c("s"))), "string_fn", ArrowType.STRING, True)
    _is(_x(Expr.length(_c("s"))), "string_fn", ArrowType.INT64, True)
    var a1: List[Expr] = [_c("s"), _c("s")]
    _is(_x(Expr.concat(a1^)), "string_fn_n", ArrowType.STRING, True)
    var a2: List[Expr] = [_c("s"), _c("s")]
    _is(_x(Expr.string_fn_n(STRFNN_STRPOS, a2^)), "string_fn_n", ArrowType.INT64, True)
    var a3: List[Expr] = [_c("s"), _c("s")]
    _is(_x(Expr.string_fn_n(STRFNN_JARO, a3^)), "string_fn_n", ArrowType.FLOAT64, True)


def test_udf_and_json_take_their_declared_type() raises:
    """A UDF call is its declared output type; a JSON extract its stored
    output type (STRING from the string factory, whatever a decoder rebuilt
    it with otherwise)."""
    _is(
        _x(Expr.udf_call(String("f"), Optional[Int](None), ArrowType.INT64, ArrowType.INT32, _c("a"))),
        "udf", ArrowType.INT32, True,
    )
    _is(_x(Expr.json_extract_string(_c("s"), "$.a")), "json_extract", ArrowType.STRING, True)
    var segs: List[String] = ["a"]
    _is(
        _x(Expr.json_extract_from_parts(_c("s"), segs^, ArrowType.INT64, False)),
        "json_extract", ArrowType.INT64, True,
    )


def test_date_trunc_keeps_child_type() raises:
    """date_trunc is the child's Field (type, nullability, timezone) renamed
    `date_trunc`."""
    var t = _x(Expr.date_trunc(EXTRACT_TRUNC_MONTH, _c("ts")))
    _is(t, "date_trunc", ArrowType.TIMESTAMP_US, True)
    assert_equal(t.timezone(), "UTC")


def test_struct_field_by_name() raises:
    """The named child's type and nullability (the second child, so a lookup
    that stops at the first fails); NULL for an absent child and for a parent
    that is not a STRUCT."""
    _is(_x(Expr.struct_field(_c("st"), "y")), "y", ArrowType.STRING, True)
    _is(_x(Expr.struct_field(_c("st"), "x")), "x", ArrowType.INT32, False)
    _is(_x(Expr.struct_field(_c("st"), "z")), "z", ArrowType.NULL, True)
    _is(_x(Expr.struct_field(_c("a"), "y")), "struct_field", ArrowType.NULL, True)


def test_struct_field_by_index() raises:
    """The indexed child; NULL for a negative index, an index equal to the
    child count, and a parent that is not a STRUCT."""
    _is(_x(Expr.struct_field_idx(_c("st"), 1)), "y", ArrowType.STRING, True)
    _is(_x(Expr.struct_field_idx(_c("st"), 0)), "x", ArrowType.INT32, False)
    _is(_x(Expr.struct_field_idx(_c("st"), -1)), "struct_field", ArrowType.NULL, True)
    _is(_x(Expr.struct_field_idx(_c("st"), 2)), "struct_field", ArrowType.NULL, True)
    _is(_x(Expr.struct_field_idx(_c("a"), 0)), "struct_field", ArrowType.NULL, True)


def test_map_get() raises:
    """The MAP's value child (child 1); NULL for a non-MAP parent and for a
    MAP with fewer than two children."""
    var k = Expr.literal(ScalarValue.from_string("k"))
    _is(_x(Expr.map_get(_c("m"), k.copy())), "value", ArrowType.INT64, True)
    _is(_x(Expr.map_get(_c("a"), k.copy())), "map_get", ArrowType.NULL, True)
    _is(_x(Expr.map_get(_c("m1"), k.copy())), "map_get", ArrowType.NULL, True)


def test_unarmed_tags_are_null() raises:
    """A column by index, a sort key and an aggregate call (the residual the
    docstring names) fall to the nullable NULL placeholder."""
    _is(_x(Expr.col_idx(0)), "expr", ArrowType.NULL, True)
    _is(_x(Expr(EXPR_SORT_KEY)), "expr", ArrowType.NULL, True)
    _is(_x(Expr.agg_fn(AGG_SUM, _c("a"))), "expr", ArrowType.NULL, True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
