# =============================================================================
# test_compute_project_column_arms.mojo: each output family the projection
# evaluator hands to the column evaluator
# =============================================================================
#
# SUBJECT: `compute_project.eval_project_exprs_over_batch`'s arms for CASE,
# REGEXP, SUBSTRING, the string functions, the type-preserving numeric
# functions, a UDF call, EXTRACT, the null tests, the nested extracts and a
# root CAST. Each arm is driven three ways: the expression at the top, under
# an alias, and declared with a type the evaluator does not produce (a
# decline).
#
# The oracle is closed-form: the values of a four-row batch under each
# function. The output field must state the declared type and the
# nullability of the produced column.
#
# Each test names the mutant that turns it red.
# =============================================================================

from std.collections import Optional
from std.testing import TestSuite, assert_true, assert_equal, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.string_array import StringArray
from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    BIN_GT,
    BIN_MUL,
    UN_ABS,
    UN_IS_NULL,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.expr_udf_sites import udf_call_column_key
from komira_plan_ir.logical_plan import ExprArray

from komira_dispatch_project.compute_project import (
    eval_project_exprs_over_batch,
)


# =============================================================================
# Fixture
# =============================================================================


def _c(name: StaticString) -> Expr:
    return Expr.col_ref(String(name))


def _a(var e: Expr) -> Expr:
    return Expr.alias(e^, String("o"))


def _two_s() -> List[Expr]:
    var args = List[Expr]()
    args.append(_c("s"))
    args.append(_c("s"))
    return args^


def _udf() -> Expr:
    """A UDF call over `k`. The evaluator calls nothing: it reads the call's
    output column, which `_batch` holds under `udf_call_column_key`."""
    return Expr.udf_call(
        String("plus_half"), Optional[Int](None), ArrowType.INT64,
        ArrowType.FLOAT64, _c("k"),
    )


def _batch() raises -> RecordBatch:
    """Four rows: `k` INT64 1..4, `v` INT64 [10, -20, NULL, 40], `s` STRING
    ["ab", "Cd", "", "xyz"], `dt` DATE32 [0, 31, 365, 9204] (1970-01-01,
    1970-02-01, 1971-01-01, 1995-03-15), `j` STRING JSON with key `a`, and
    the UDF's output column (`k + 0.5`)."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("v"), ArrowType.INT64, True))
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    sb.add_field(Field(String("dt"), ArrowType.DATE32, False))
    sb.add_field(Field(String("j"), ArrowType.STRING, False))
    sb.add_field(Field(udf_call_column_key(_udf()), ArrowType.FLOAT64, False))
    var k = List[Scalar[DType.int64]]()
    var u = List[Scalar[DType.float64]]()
    for r in range(4):
        k.append(Scalar[DType.int64](r + 1))
        u.append(Scalar[DType.float64](r + 1) + 0.5)
    var v = PrimitiveArray[DType.int64].allocate_nullable(4)
    v.set(0, Scalar[DType.int64](10))
    v.set(1, Scalar[DType.int64](-20))
    v.set(3, Scalar[DType.int64](40))
    v._set_null(2)
    var s = List[String]()
    s.append(String("ab"))
    s.append(String("Cd"))
    s.append(String(""))
    s.append(String("xyz"))
    var dt = List[Scalar[DType.int32]]()
    dt.append(Scalar[DType.int32](0))
    dt.append(Scalar[DType.int32](31))
    dt.append(Scalar[DType.int32](365))
    dt.append(Scalar[DType.int32](9204))
    var j = List[String]()
    for r in range(4):
        j.append(String('{"a": "v') + String(r) + String('"}'))
    var rbb = RecordBatchBuilder.with_capacity(6)
    rbb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(k)))
    rbb.add_column(Column.from_primitive[DType.int64](v^))
    rbb.add_column(Column.from_string(StringArray.from_strings(s)))
    rbb.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](
            PrimitiveArray[DType.int32].from_list(dt), ArrowType.DATE32
        )
    )
    rbb.add_column(Column.from_string(StringArray.from_strings(j)))
    rbb.add_column(Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(u)))
    return rbb.build(sb.build())


def _run(var e: Expr, declared: ArrowType) raises -> Optional[RecordBatch]:
    """Project the single output `e` (named `o`) declared `declared`."""
    var exprs = ExprArray()
    exprs.append(e^)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("o"), declared, True))
    return eval_project_exprs_over_batch(_batch(), exprs, sb.build())


def _served(var e: Expr, declared: ArrowType) raises -> RecordBatch:
    var out = _run(e^, declared)
    assert_true(Bool(out), "the output is served")
    var b = out.take()
    assert_equal(b.num_rows(), 4, "one value per row")
    assert_equal(b.schema.field_name(0), String("o"))
    assert_true(b.schema.field_arrow_type(0) == declared, "the declared type")
    return b^


def _declined(var e: Expr, declared: ArrowType) raises:
    assert_false(Bool(_run(e^, declared)), "a type the arm does not produce declines")


def _case() -> Expr:
    var cases = List[WhenCaseData]()
    cases.append(
        WhenCaseData(
            Expr.binary(BIN_GT, _c("k"), Expr.literal(ScalarValue.from_int(2))),
            _c("s"),
        )
    )
    return Expr.when(cases^, Expr.literal(ScalarValue.from_string(String("-"))))


# =============================================================================
# The arms
# =============================================================================


def test_a_case_output_goes_to_the_case_evaluator() raises:
    """`CASE WHEN k > 2 THEN s ELSE '-' END`, a STRING result the walkers
    cannot build. Mutant: the arm's alias branch evaluating `e` instead of
    its child (the CASE evaluator then raises on the alias node)."""
    var out = _served(_case(), ArrowType.STRING)
    var col = out.column_as_string(0)
    assert_equal(col.get(0), String("-"))
    assert_equal(col.get(3), String("xyz"))
    out = _served(_a(_case()), ArrowType.STRING)
    assert_equal(out.column_as_string(0).get(2), String(""))
    _declined(_case(), ArrowType.INT64)


def test_a_regexp_output_goes_to_the_column_evaluator() raises:
    """`regexp_like(s, '^[a-z]')` is BOOL. Mutant: the declared-type check of
    the arm removed (the STRING declaration is then served with a BOOL
    column)."""
    var out = _served(Expr.regexp_like(_c("s"), String("^[a-z]")), ArrowType.BOOL)
    var col = out.column_as_boolean(0)
    assert_true(col.get(0))
    assert_false(col.get(1))
    assert_true(col.get(3))
    out = _served(_a(Expr.regexp_like(_c("s"), String("^[a-z]"))), ArrowType.BOOL)
    assert_false(out.column_as_boolean(0).get(2))
    _declined(Expr.regexp_like(_c("s"), String("^[a-z]")), ArrowType.STRING)


def test_a_substring_output_goes_to_the_column_evaluator() raises:
    """`substring(s, 1, 1)`. Mutant: the arm's alias branch evaluating `e`."""
    var out = _served(Expr.substring(_c("s"), 1, 1), ArrowType.STRING)
    assert_equal(out.column_as_string(0).get(1), String("C"))
    out = _served(_a(Expr.substring(_c("s"), 1, 1)), ArrowType.STRING)
    assert_equal(out.column_as_string(0).get(3), String("x"))
    _declined(Expr.substring(_c("s"), 1, 1), ArrowType.INT64)


def test_the_string_functions_go_to_the_column_evaluator() raises:
    """`upper(s)` (EXPR_STRING_FN), `concat(s, s)` (EXPR_STRING_FN_N), and an
    alias of each. Mutant: EXPR_STRING_FN_N dropped from the arm's direct
    test (the concat node is then evaluated as if it were an alias)."""
    var out = _served(Expr.upper(_c("s")), ArrowType.STRING)
    assert_equal(out.column_as_string(0).get(1), String("CD"))
    out = _served(_a(Expr.upper(_c("s"))), ArrowType.STRING)
    assert_equal(out.column_as_string(0).get(0), String("AB"))
    out = _served(Expr.concat(_two_s()), ArrowType.STRING)
    assert_equal(out.column_as_string(0).get(3), String("xyzxyz"))
    out = _served(_a(Expr.concat(_two_s())), ArrowType.STRING)
    assert_equal(out.column_as_string(0).get(0), String("abab"))
    _declined(Expr.upper(_c("s")), ArrowType.INT64)


def test_a_numeric_function_goes_to_the_column_evaluator() raises:
    """`abs(v)` keeps INT64 and the NULL. Mutant: the arm's alias branch
    evaluating `e`."""
    var out = _served(Expr.unary(UN_ABS, _c("v")), ArrowType.INT64)
    var col = out.column_as_primitive_int64(0)
    assert_equal(Int(col.get(1)), 20)
    assert_true(col.is_null(2), "abs(NULL) is NULL")
    out = _served(_a(Expr.unary(UN_ABS, _c("v"))), ArrowType.INT64)
    assert_equal(Int(out.column_as_primitive_int64(0).get(3)), 40)
    _declined(Expr.unary(UN_ABS, _c("v")), ArrowType.FLOAT64)


def test_a_udf_call_anywhere_goes_to_the_column_evaluator() raises:
    """The call alone, under an alias, and inside arithmetic (`f(k) * 2`,
    which no top-level predicate matches). Mutant: the arm's test made "is
    a UDF node" (the product then reaches the walkers and declines)."""
    var out = _served(_udf(), ArrowType.FLOAT64)
    assert_equal(out.column_as_primitive_float64(0).get(0), 1.5)
    out = _served(_a(_udf()), ArrowType.FLOAT64)
    assert_equal(out.column_as_primitive_float64(0).get(3), 4.5)
    out = _served(
        Expr.binary(BIN_MUL, _udf(), Expr.literal(ScalarValue.from_float(2.0))),
        ArrowType.FLOAT64,
    )
    assert_equal(out.column_as_primitive_float64(0).get(1), 5.0)
    _declined(_udf(), ArrowType.INT64)


def test_an_extract_output_carries_the_declared_field() raises:
    """`year(dt)` is INT64 and its field is carried from the declaration.
    Mutant: the arm's alias branch evaluating `e`."""
    var out = _served(Expr.year(_c("dt")), ArrowType.INT64)
    var col = out.column_as_primitive_int64(0)
    assert_equal(Int(col.get(0)), 1970)
    assert_equal(Int(col.get(2)), 1971)
    out = _served(_a(Expr.year(_c("dt"))), ArrowType.INT64)
    assert_equal(Int(out.column_as_primitive_int64(0).get(3)), 1995)
    _declined(Expr.year(_c("dt")), ArrowType.INT32)


def test_a_null_test_reads_any_columns_validity() raises:
    """`v IS NULL` over an INT64 column (the translator's null test takes a
    STRING only). Mutant: the arm removed (the expression then reaches the
    walkers, whose translator refuses it, and declines)."""
    var out = _served(Expr.unary(UN_IS_NULL, _c("v")), ArrowType.BOOL)
    var col = out.column_as_boolean(0)
    assert_false(col.get(0))
    assert_true(col.get(2))
    out = _served(_a(Expr.unary(UN_IS_NULL, _c("v"))), ArrowType.BOOL)
    assert_true(out.column_as_boolean(0).get(2))
    _declined(Expr.unary(UN_IS_NULL, _c("v")), ArrowType.INT64)


def test_a_nested_extract_goes_to_the_column_evaluator() raises:
    """`json_extract_string(j, '$.a')`. Mutant: the arm's alias branch
    evaluating `e`."""
    var out = _served(Expr.json_extract_string(_c("j"), String("$.a")), ArrowType.STRING)
    assert_equal(out.column_as_string(0).get(2), String("v2"))
    out = _served(_a(Expr.json_extract_string(_c("j"), String("$.a"))), ArrowType.STRING)
    assert_equal(out.column_as_string(0).get(0), String("v0"))
    _declined(Expr.json_extract_string(_c("j"), String("$.a")), ArrowType.INT64)


def test_a_root_cast_goes_to_the_column_evaluator() raises:
    """`CAST(v AS DOUBLE)` keeps the NULL. Mutant: the arm's alias branch
    evaluating `e`."""
    var out = _served(Expr.cast(_c("v"), DType.float64), ArrowType.FLOAT64)
    var col = out.column_as_primitive_float64(0)
    assert_equal(col.get(1), -20.0)
    assert_true(col.is_null(2))
    out = _served(_a(Expr.cast(_c("k"), DType.float64)), ArrowType.FLOAT64)
    assert_equal(out.column_as_primitive_float64(0).get(3), 4.0)
    _declined(Expr.cast(_c("k"), DType.float64), ArrowType.INT64)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
