# =============================================================================
# test_compute_project_routes.mojo: the route predicates of the projection
# evaluator, one by one
# =============================================================================
#
# SUBJECT: every function of `compute_project_routes`, called directly: the
# column type to runtime family map, the passthrough storage checks, the
# column maps, the `_is_*_output` predicates (each at the top of the
# expression, one alias down, and not deeper), the strict-arithmetic
# predicates and the input scan.
#
# The oracle is the predicate's answer for an expression built to sit on
# each side of each of its tests. Each test names the mutant that turns it
# red.
# =============================================================================

from std.collections import Dict
from std.testing import TestSuite, assert_true, assert_equal, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import SchemaBuilder, Field
from komira_arrow.string_array import StringArray
from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    BIN_ADD,
    BIN_DIV,
    BIN_EQ,
    BIN_MUL,
    BIN_SUB,
    MATH_ACOS,
    MATH_ASIN,
    MATH_ATANH,
    MATH_COT,
    MATH_EXP,
    MATH_GAMMA,
    MATH_LN,
    MATH_LOG10,
    MATH_LOG2,
    MATH_SQRT,
    MATH2_POW,
    STR_LIKE,
    UN_ABS,
    UN_BIT_COUNT,
    UN_IS_NOT_NULL,
    UN_IS_NULL,
    UN_NEGATE,
    UN_NOT,
    UN_ROUND,
    UN_SIGN,
    UN_TRUNC,
)
from komira_plan_expr.scalar_value import ScalarValue

from komira_dispatch_project.compute_project_routes import (
    _arrow_to_runtime_dtype_local,
    _build_col_maps,
    _expr_has_domain_checked_math,
    _expr_is_strict_null_propagating,
    _is_cast_output,
    _is_extract_output,
    _is_nested_extract_output,
    _is_null_test_output,
    _is_num_typepres_output,
    _is_regexp_output,
    _is_string_fn_output,
    _is_substring_output,
    _passthrough_col_index,
    _passthrough_storage_compatible,
    _strict_overlay_input_scan,
    _varlen_offset_width_alias,
    _when_expr_ref,
    is_literal_output_expr,
)
from komira_dispatch_project.lower_untyped_expr import (
    RUNTIME_DTYPE_F64,
    RUNTIME_DTYPE_I32,
    RUNTIME_DTYPE_I64,
    RUNTIME_DTYPE_UNSUPPORTED,
)


def _c(name: StaticString) -> Expr:
    return Expr.col_ref(String(name))


def _a(var e: Expr) -> Expr:
    return Expr.alias(e^, String("o"))


def _two_s() -> List[Expr]:
    var args = List[Expr]()
    args.append(_c("s"))
    args.append(_c("s"))
    return args^


def _li(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _batch() raises -> RecordBatch:
    """`k` INT64 (no NULL), `v` INT64 (row 1 NULL), `x` FLOAT64, `n` INT32,
    `s` STRING."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("v"), ArrowType.INT64, True))
    sb.add_field(Field(String("x"), ArrowType.FLOAT64, False))
    sb.add_field(Field(String("n"), ArrowType.INT32, False))
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    var k = List[Scalar[DType.int64]]()
    var x = List[Scalar[DType.float64]]()
    var n = List[Scalar[DType.int32]]()
    var s = List[String]()
    for r in range(3):
        k.append(Scalar[DType.int64](r))
        x.append(Scalar[DType.float64](r) + 0.5)
        n.append(Scalar[DType.int32](r))
        s.append(String("s") + String(r))
    var v = PrimitiveArray[DType.int64].allocate_nullable(3)
    v.set(0, Scalar[DType.int64](7))
    v.set(2, Scalar[DType.int64](9))
    v._set_null(1)
    var rbb = RecordBatchBuilder.with_capacity(5)
    rbb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(k)))
    rbb.add_column(Column.from_primitive[DType.int64](v^))
    rbb.add_column(Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(x)))
    rbb.add_column(Column.from_primitive[DType.int32](PrimitiveArray[DType.int32].from_list(n)))
    rbb.add_column(Column.from_string(StringArray.from_strings(s)))
    return rbb.build(sb.build())


# =============================================================================
# Types and storage
# =============================================================================


def test_the_runtime_family_of_each_column_type() raises:
    """INT64, DATE32 and the five TIMESTAMP types are I64; INT32 is I32;
    FLOAT64 and FLOAT32 are F64; anything else is UNSUPPORTED. Mutant: the
    DATE32 arm removed (DATE32 then answers UNSUPPORTED)."""
    assert_equal(_arrow_to_runtime_dtype_local(ArrowType.INT64), RUNTIME_DTYPE_I64)
    assert_equal(_arrow_to_runtime_dtype_local(ArrowType.INT32), RUNTIME_DTYPE_I32)
    assert_equal(_arrow_to_runtime_dtype_local(ArrowType.FLOAT64), RUNTIME_DTYPE_F64)
    assert_equal(_arrow_to_runtime_dtype_local(ArrowType.FLOAT32), RUNTIME_DTYPE_F64)
    assert_equal(_arrow_to_runtime_dtype_local(ArrowType.DATE32), RUNTIME_DTYPE_I64)
    var ts = List[ArrowType]()
    ts.append(ArrowType.TIMESTAMP)
    ts.append(ArrowType.TIMESTAMP_S)
    ts.append(ArrowType.TIMESTAMP_MS)
    ts.append(ArrowType.TIMESTAMP_US)
    ts.append(ArrowType.TIMESTAMP_NS)
    for i in range(len(ts)):
        assert_equal(_arrow_to_runtime_dtype_local(ts[i]), RUNTIME_DTYPE_I64)
    assert_equal(_arrow_to_runtime_dtype_local(ArrowType.STRING), RUNTIME_DTYPE_UNSUPPORTED)
    assert_equal(_arrow_to_runtime_dtype_local(ArrowType.DATE64), RUNTIME_DTYPE_UNSUPPORTED)


def test_storage_compatibility_and_the_offset_width_alias() raises:
    """Same type; DATE32 with INT32; DATE64 and TIMESTAMP with INT64 are
    compatible; INT32 with INT64 and INT64 with FLOAT64 are not. The offset
    alias admits both variable-length pairs both ways and nothing else.
    Mutant: the BINARY -> LARGE_BINARY arm of the alias removed."""
    assert_true(_passthrough_storage_compatible(ArrowType.STRING, ArrowType.STRING))
    assert_true(_passthrough_storage_compatible(ArrowType.INT32, ArrowType.DATE32))
    assert_true(_passthrough_storage_compatible(ArrowType.DATE64, ArrowType.INT64))
    var ts = List[ArrowType]()
    ts.append(ArrowType.TIMESTAMP_S)
    ts.append(ArrowType.TIMESTAMP_MS)
    ts.append(ArrowType.TIMESTAMP_US)
    ts.append(ArrowType.TIMESTAMP_NS)
    for i in range(len(ts)):
        assert_true(_passthrough_storage_compatible(ts[i], ArrowType.TIMESTAMP))
        assert_true(_passthrough_storage_compatible(ArrowType.INT64, ts[i]))
    assert_false(_passthrough_storage_compatible(ArrowType.INT32, ArrowType.INT64))
    assert_false(_passthrough_storage_compatible(ArrowType.INT64, ArrowType.FLOAT64))
    assert_true(_varlen_offset_width_alias(ArrowType.STRING, ArrowType.LARGE_STRING))
    assert_true(_varlen_offset_width_alias(ArrowType.LARGE_STRING, ArrowType.STRING))
    assert_true(_varlen_offset_width_alias(ArrowType.BINARY, ArrowType.LARGE_BINARY))
    assert_true(_varlen_offset_width_alias(ArrowType.LARGE_BINARY, ArrowType.BINARY))
    assert_false(_varlen_offset_width_alias(ArrowType.STRING, ArrowType.BINARY))
    assert_false(_varlen_offset_width_alias(ArrowType.LARGE_STRING, ArrowType.LARGE_BINARY))
    assert_false(_varlen_offset_width_alias(ArrowType.BINARY, ArrowType.STRING))
    assert_false(_varlen_offset_width_alias(ArrowType.LARGE_BINARY, ArrowType.STRING))
    assert_false(_varlen_offset_width_alias(ArrowType.STRING, ArrowType.STRING))


def test_the_column_maps_and_the_passthrough_index() raises:
    """`_build_col_maps` maps every column (a STRING one to UNSUPPORTED);
    `_passthrough_col_index` finds a column by reference or alias, and answers
    -1 for an absent name or a computed expression. Mutant: the alias arm of
    `_passthrough_col_index` removed."""
    var b = _batch()
    var idx = Dict[String, Int]()
    var dt = Dict[String, Int]()
    assert_true(_build_col_maps(b, idx, dt))
    assert_equal(idx["s"], 4)
    assert_equal(dt["n"], RUNTIME_DTYPE_I32)
    assert_equal(dt["s"], RUNTIME_DTYPE_UNSUPPORTED)
    assert_equal(_passthrough_col_index(b, _c("x")), 2)
    assert_equal(_passthrough_col_index(b, _a(_c("n"))), 3)
    assert_equal(_passthrough_col_index(b, _c("zz")), -1)
    assert_equal(_passthrough_col_index(b, _a(_li(1))), -1)
    assert_equal(_passthrough_col_index(b, Expr.binary(BIN_ADD, _c("k"), _li(1))), -1)


# =============================================================================
# The top-or-one-alias-down predicates
# =============================================================================


def _case() -> Expr:
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(Expr.binary(BIN_EQ, _c("k"), _li(1)), _li(2)))
    return Expr.when(cases^, _li(3))


def test_case_and_literal_outputs() raises:
    """A CASE and an alias of one are matched by `_when_expr_ref`; a literal
    and an alias of one by `is_literal_output_expr`; neither matches deeper.
    Mutant: the alias arm of `_when_expr_ref` removed."""
    assert_true(Bool(_when_expr_ref(_case())))
    assert_true(Bool(_when_expr_ref(_a(_case()))))
    assert_false(Bool(_when_expr_ref(Expr.binary(BIN_ADD, _case(), _li(1)))))
    assert_true(is_literal_output_expr(_li(1)))
    assert_true(is_literal_output_expr(_a(_li(1))))
    assert_false(is_literal_output_expr(Expr.binary(BIN_ADD, _li(1), _c("k"))))


def test_regexp_substring_and_string_function_outputs() raises:
    """Each at the top and one alias down, both string function tags, and not
    deeper. Mutant: the alias arm of `_is_string_fn_output` for
    EXPR_STRING_FN_N removed."""
    var rx = Expr.regexp_like(_c("s"), String("a"))
    assert_true(_is_regexp_output(rx))
    assert_true(_is_regexp_output(_a(Expr.regexp_like(_c("s"), String("a")))))
    assert_false(_is_regexp_output(_c("s")))
    assert_true(_is_substring_output(Expr.substring(_c("s"), 1, 2)))
    assert_true(_is_substring_output(_a(Expr.substring(_c("s"), 1, 2))))
    assert_false(_is_substring_output(_c("s")))
    assert_true(_is_string_fn_output(Expr.upper(_c("s"))))
    assert_true(_is_string_fn_output(_a(Expr.upper(_c("s")))))
    assert_true(_is_string_fn_output(Expr.concat(_two_s())))
    assert_true(_is_string_fn_output(_a(Expr.concat(_two_s()))))
    assert_false(_is_string_fn_output(_c("s")))


def test_null_test_cast_and_numeric_function_outputs() raises:
    """IS [NOT] NULL (not NOT); CAST; abs, sign, trunc, round and bit_count
    (not negation); each at the top and one alias down. Mutant: UN_BIT_COUNT
    removed from the alias arm of `_is_num_typepres_output`."""
    assert_true(_is_null_test_output(Expr.unary(UN_IS_NULL, _c("k"))))
    assert_true(_is_null_test_output(_a(Expr.unary(UN_IS_NOT_NULL, _c("k")))))
    assert_false(_is_null_test_output(Expr.unary(UN_NOT, _c("k"))))
    assert_false(_is_null_test_output(_a(Expr.unary(UN_NOT, _c("k")))))
    assert_false(_is_null_test_output(_c("k")))
    assert_true(_is_cast_output(Expr.cast(_c("k"), DType.float64)))
    assert_true(_is_cast_output(_a(Expr.cast(_c("k"), DType.float64))))
    assert_false(_is_cast_output(_c("k")))
    var ops = List[UInt8]()
    ops.append(UN_ABS)
    ops.append(UN_SIGN)
    ops.append(UN_TRUNC)
    ops.append(UN_ROUND)
    ops.append(UN_BIT_COUNT)
    for i in range(len(ops)):
        assert_true(_is_num_typepres_output(Expr.unary(ops[i], _c("k"))))
        assert_true(_is_num_typepres_output(_a(Expr.unary(ops[i], _c("k")))))
    assert_false(_is_num_typepres_output(Expr.unary(UN_NEGATE, _c("k"))))
    assert_false(_is_num_typepres_output(_a(Expr.unary(UN_NEGATE, _c("k")))))
    assert_false(_is_num_typepres_output(_c("k")))


def test_nested_and_temporal_extract_outputs() raises:
    """The four nested extracts at the top and one alias down, EXTRACT at the
    top and one alias down, and neither over a plain column. Mutant:
    EXPR_MAP_GET removed from the alias arm of `_is_nested_extract_output`."""
    var nested = List[Expr]()
    nested.append(Expr.struct_field(_c("s"), String("a")))
    nested.append(Expr.struct_field_idx(_c("s"), 0))
    nested.append(Expr.map_get(_c("s"), _li(1)))
    nested.append(Expr.json_extract_string(_c("s"), String("$.a")))
    for i in range(len(nested)):
        assert_true(_is_nested_extract_output(nested[i]))
        assert_true(_is_nested_extract_output(_a(nested[i].copy())))
    assert_false(_is_nested_extract_output(_c("s")))
    assert_false(_is_nested_extract_output(_a(_c("s"))))
    assert_true(_is_extract_output(Expr.year(_c("k"))))
    assert_true(_is_extract_output(_a(Expr.year(_c("k")))))
    assert_false(_is_extract_output(_c("k")))


# =============================================================================
# The strict-arithmetic arm
# =============================================================================


def test_the_strict_shapes() raises:
    """Columns (by name and by index), literals, the four arithmetic operators,
    unary and binary math and a FLOAT64 cast are strict, through aliases; a
    comparison, a non-FLOAT64 cast, a CASE and a strict node over a non-strict
    operand (on either side) are not. Mutant: the right-operand check of
    EXPR_MATH_FN2 removed (`pow(k, k = 1)` then answers True)."""
    assert_true(_expr_is_strict_null_propagating(_a(_c("k"))))
    assert_true(_expr_is_strict_null_propagating(Expr.col_idx(0)))
    var ar = List[UInt8]()
    ar.append(BIN_ADD)
    ar.append(BIN_SUB)
    ar.append(BIN_MUL)
    ar.append(BIN_DIV)
    for i in range(len(ar)):
        assert_true(_expr_is_strict_null_propagating(Expr.binary(ar[i], _c("k"), _li(2))))
    assert_true(_expr_is_strict_null_propagating(Expr.ln(_c("x"))))
    assert_true(
        _expr_is_strict_null_propagating(Expr.math_fn2(MATH2_POW, _c("x"), _li(2)))
    )
    assert_true(_expr_is_strict_null_propagating(Expr.cast(_c("k"), DType.float64)))
    assert_false(_expr_is_strict_null_propagating(Expr.cast(_c("k"), DType.int32)))
    assert_false(
        _expr_is_strict_null_propagating(
            Expr.cast_from_parts(_c("k"), DType.float64, ArrowType.FLOAT32, 0, 0, False)
        ),
        "a float64 DType over a FLOAT32 Arrow target is not the FLOAT64 cast",
    )
    assert_false(_expr_is_strict_null_propagating(Expr.binary(BIN_EQ, _c("k"), _li(2))))
    assert_false(_expr_is_strict_null_propagating(_case()))
    var cmp = Expr.binary(BIN_EQ, _c("k"), _li(1))
    assert_false(
        _expr_is_strict_null_propagating(Expr.binary(BIN_ADD, cmp.copy(), _li(1)))
    )
    assert_false(
        _expr_is_strict_null_propagating(Expr.binary(BIN_ADD, _li(1), cmp.copy()))
    )
    assert_false(
        _expr_is_strict_null_propagating(Expr.math_fn2(MATH2_POW, cmp.copy(), _li(1)))
    )
    assert_false(
        _expr_is_strict_null_propagating(Expr.math_fn2(MATH2_POW, _li(1), cmp.copy()))
    )


def test_the_domain_checked_math_ops() raises:
    """The nine ops whose kernel can refuse are found at the top, under an
    alias, under a unary math op, either side of a binary math op and either
    side of an arithmetic operator; EXP is not one of them, and a leaf holds
    none. Mutant: MATH_COT removed from the list."""
    var ops = List[UInt8]()
    ops.append(MATH_LN)
    ops.append(MATH_LOG10)
    ops.append(MATH_LOG2)
    ops.append(MATH_SQRT)
    ops.append(MATH_ASIN)
    ops.append(MATH_ACOS)
    ops.append(MATH_ATANH)
    ops.append(MATH_COT)
    ops.append(MATH_GAMMA)
    for i in range(len(ops)):
        assert_true(_expr_has_domain_checked_math(Expr.math_fn(ops[i], _c("x"))))
    var ln = Expr.ln(_c("x"))
    assert_true(_expr_has_domain_checked_math(_a(ln.copy())))
    assert_true(_expr_has_domain_checked_math(Expr.exp(ln.copy())))
    assert_false(_expr_has_domain_checked_math(Expr.exp(_c("x"))))
    assert_true(_expr_has_domain_checked_math(Expr.math_fn2(MATH2_POW, ln.copy(), _c("x"))))
    assert_true(_expr_has_domain_checked_math(Expr.math_fn2(MATH2_POW, _c("x"), ln.copy())))
    assert_false(_expr_has_domain_checked_math(Expr.math_fn2(MATH2_POW, _c("x"), _c("x"))))
    assert_true(_expr_has_domain_checked_math(Expr.binary(BIN_MUL, ln.copy(), _c("x"))))
    assert_true(_expr_has_domain_checked_math(Expr.binary(BIN_MUL, _c("x"), ln.copy())))
    assert_false(_expr_has_domain_checked_math(Expr.binary(BIN_MUL, _c("x"), _c("x"))))
    assert_false(_expr_has_domain_checked_math(_c("x")))


def test_the_input_scan() raises:
    """INT64 and FLOAT64 leaves (by name and by index, through every strict
    node) are admitted and report a NULL when their column holds one; an
    INT32 or STRING leaf, an absent name, an index out of range and a
    non-leaf tag are refused, on either side of a binary node. Mutant: the
    INT64 / FLOAT64 type check removed (the INT32 leaf then passes)."""
    var b = _batch()
    var saw = False
    assert_true(_strict_overlay_input_scan(_a(Expr.binary(BIN_ADD, _c("k"), _li(1))), b, saw))
    assert_false(saw, "k holds no NULL")
    assert_true(_strict_overlay_input_scan(Expr.ln(Expr.cast(_c("v"), DType.float64)), b, saw))
    assert_true(saw, "v holds a NULL")
    saw = False
    assert_true(_strict_overlay_input_scan(Expr.math_fn2(MATH2_POW, _c("x"), Expr.col_idx(1)), b, saw))
    assert_true(saw, "column 1 is v")
    saw = False
    assert_false(_strict_overlay_input_scan(_c("n"), b, saw), "INT32")
    assert_false(_strict_overlay_input_scan(_c("s"), b, saw), "STRING")
    assert_false(_strict_overlay_input_scan(_c("zz"), b, saw), "absent")
    assert_false(_strict_overlay_input_scan(Expr.col_idx(9), b, saw), "index past the end")
    assert_false(_strict_overlay_input_scan(Expr.col_idx(-1), b, saw), "negative index")
    assert_false(_strict_overlay_input_scan(Expr.upper(_c("s")), b, saw), "not a leaf")
    assert_false(_strict_overlay_input_scan(Expr.binary(BIN_ADD, _c("n"), _c("k")), b, saw))
    assert_false(_strict_overlay_input_scan(Expr.binary(BIN_ADD, _c("k"), _c("n")), b, saw))
    assert_false(_strict_overlay_input_scan(Expr.math_fn2(MATH2_POW, _c("n"), _c("k")), b, saw))
    assert_false(_strict_overlay_input_scan(Expr.math_fn2(MATH2_POW, _c("k"), _c("n")), b, saw))
    assert_false(saw, "no refused scan reported a NULL")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
