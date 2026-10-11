# =============================================================================
# test_compute_project_walker_arms.mojo: the projection evaluator's contract
# checks, the strict-arithmetic arm and the walker channels
# =============================================================================
#
# SUBJECT: `compute_project.eval_project_exprs_over_batch` outside the
# column-evaluator families: the declines taken before any expression (an
# empty list, a schema of another width), a selection mask applied first, a
# bare literal, the strict-arithmetic arm (a NULL in the input, a
# domain-checked math op), and the walker route (each channel, each decline,
# the overflow raise on the F64 channel).
#
# The oracle is closed-form over a four-row batch. Each test names the mutant
# that turns it red.
# =============================================================================

from std.collections import Optional
from std.testing import TestSuite, assert_true, assert_equal, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.string_array import StringArray
from komira_plan_expr.expr import (
    Expr,
    WhenCaseData,
    BIN_ADD,
    BIN_GT,
    BIN_MUL,
)
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import ExprArray

from komira_dispatch_project.compute_project import (
    eval_project_exprs_over_batch,
)


def _c(name: StaticString) -> Expr:
    return Expr.col_ref(String(name))


def _li(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _lf(v: Float64) -> Expr:
    return Expr.literal(ScalarValue.from_float(v))


def _batch() raises -> RecordBatch:
    """Four rows: `k` INT64 1..4, `v` INT64 [10, -20, NULL, 40], `x` FLOAT64
    [1.5, 4.0, 9.0, 0.25], `n` INT32 1..4, `s` STRING, `m` INT32
    [7, NULL, 9, 10]."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("k"), ArrowType.INT64, False))
    sb.add_field(Field(String("v"), ArrowType.INT64, True))
    sb.add_field(Field(String("x"), ArrowType.FLOAT64, False))
    sb.add_field(Field(String("n"), ArrowType.INT32, False))
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    sb.add_field(Field(String("m"), ArrowType.INT32, True))
    var k = List[Scalar[DType.int64]]()
    var n = List[Scalar[DType.int32]]()
    var s = List[String]()
    for r in range(4):
        k.append(Scalar[DType.int64](r + 1))
        n.append(Scalar[DType.int32](r + 1))
        s.append(String("s") + String(r))
    var x = List[Scalar[DType.float64]]()
    x.append(1.5)
    x.append(4.0)
    x.append(9.0)
    x.append(0.25)
    var v = PrimitiveArray[DType.int64].allocate_nullable(4)
    v.set(0, Scalar[DType.int64](10))
    v.set(1, Scalar[DType.int64](-20))
    v.set(3, Scalar[DType.int64](40))
    v._set_null(2)
    var m = PrimitiveArray[DType.int32].allocate_nullable(4)
    m.set(0, Scalar[DType.int32](7))
    m.set(2, Scalar[DType.int32](9))
    m.set(3, Scalar[DType.int32](10))
    m._set_null(1)
    var rbb = RecordBatchBuilder.with_capacity(6)
    rbb.add_column(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(k)))
    rbb.add_column(Column.from_primitive[DType.int64](v^))
    rbb.add_column(Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(x)))
    rbb.add_column(Column.from_primitive[DType.int32](PrimitiveArray[DType.int32].from_list(n)))
    rbb.add_column(Column.from_string(StringArray.from_strings(s)))
    rbb.add_column(Column.from_primitive[DType.int32](m^))
    return rbb.build(sb.build())


def _schema1(declared: ArrowType) raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("o"), declared, True))
    return sb.build()


def _run(var e: Expr, declared: ArrowType) raises -> Optional[RecordBatch]:
    var exprs = ExprArray()
    exprs.append(e^)
    return eval_project_exprs_over_batch(_batch(), exprs, _schema1(declared))


def _served(var e: Expr, declared: ArrowType) raises -> RecordBatch:
    var out = _run(e^, declared)
    assert_true(Bool(out), "the output is served")
    var b = out.take()
    assert_equal(b.num_rows(), 4, "one value per row")
    assert_true(b.schema.field_arrow_type(0) == declared, "the declared type")
    return b^


# =============================================================================
# Before any expression
# =============================================================================


def test_an_empty_list_and_a_schema_of_another_width_decline() raises:
    """Mutant: the width check removed (two declared columns for one
    expression then produce a one-column batch)."""
    assert_false(
        Bool(eval_project_exprs_over_batch(_batch(), ExprArray(), _schema1(ArrowType.INT64)))
    )
    var exprs = ExprArray()
    exprs.append(_c("k"))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), ArrowType.INT64, False))
    sb.add_field(Field(String("b"), ArrowType.INT64, False))
    assert_false(Bool(eval_project_exprs_over_batch(_batch(), exprs, sb.build())))


def test_a_selection_mask_is_applied_before_evaluation() raises:
    """A batch whose mask keeps rows 1 and 3 projects two rows. Mutant: the
    `materialize_selection_if_present` call removed (four rows come out)."""
    var b = _batch()
    var mask = BooleanArray.allocate(4)
    mask.set(1, True)
    mask.set(3, True)
    b._selection_mask = Optional[BooleanArray](mask^)
    var exprs = ExprArray()
    exprs.append(Expr.binary(BIN_MUL, _c("k"), _li(10)))
    var out = eval_project_exprs_over_batch(b^, exprs, _schema1(ArrowType.INT64))
    assert_true(Bool(out))
    var col = out.take().column_as_primitive_int64(0)
    assert_equal(col.length, 2)
    assert_equal(Int(col.get(0)), 20)
    assert_equal(Int(col.get(1)), 40)


def test_a_bare_literal_is_broadcast() raises:
    """A literal not under an alias takes the literal arm's direct branch.
    Mutant: that branch reading `e.alias_child_ref()` (a bare literal has no
    child)."""
    var out = _served(_lf(2.5), ArrowType.FLOAT64)
    assert_equal(out.column_as_primitive_float64(0).get(3), 2.5)
    assert_false(out.schema.field_nullable(0), "a broadcast literal has no NULL")


# =============================================================================
# The strict-arithmetic arm
# =============================================================================


def test_a_null_in_the_input_keeps_its_null_through_arithmetic() raises:
    """`v + 1` over a batch whose `v` holds a NULL takes the column evaluator
    and keeps the NULL (the walkers would answer the payload plus one).
    Mutant: the `nz_saw_null` operand of the gate removed (the walker then
    answers a valid row 2)."""
    var out = _served(Expr.binary(BIN_ADD, _c("v"), _li(1)), ArrowType.INT64)
    var col = out.column_as_primitive_int64(0)
    assert_equal(Int(col.get(0)), 11)
    assert_true(col.is_null(2), "NULL + 1 is NULL")
    assert_true(out.schema.field_nullable(0))
    assert_false(
        Bool(_run(Expr.binary(BIN_ADD, _c("v"), _li(1)), ArrowType.FLOAT64)),
        "a declared type the column evaluator does not produce declines",
    )


def test_a_domain_checked_op_takes_the_column_evaluator_without_a_null() raises:
    """`sqrt(x)` over a NULL-free input takes the column evaluator, whose
    kernel checks the domain: `sqrt(-x)` raises rather than answering NaN.
    Mutant: the `_expr_has_domain_checked_math` operand of the gate removed
    (the walker then answers NaN and the raise is gone)."""
    var out = _served(Expr.sqrt(_c("x")), ArrowType.FLOAT64)
    assert_equal(out.column_as_primitive_float64(0).get(2), 3.0)
    var msg = String("")
    try:
        _ = _run(
            Expr.sqrt(Expr.binary(BIN_MUL, _c("x"), _lf(-1.0))), ArrowType.FLOAT64
        )
    except err:
        msg = String(err)
    assert_true(msg != "", "sqrt of a negative number is refused, not NaN")


# =============================================================================
# The walker route
# =============================================================================


def test_each_walker_channel_and_its_declines() raises:
    """I64 (`k * 3`) and F64 (`x * 2.0`) are served; a type other than the
    channel's declines; an I32 expression (`n + n`) declines, since the
    evaluator serves no I32 channel; an INT64 expression the translator
    refuses (`k + n`, an INT64/INT32 pair) declines; an expression with no
    family (`s + s`) declines. Mutants: the declared-type check of the
    walker tail removed (`k * 3` declared FLOAT64 is then served with an
    INT64 column); the translator refusal's `return None` made a raise
    (`k + n` then raises)."""
    var out = _served(Expr.binary(BIN_MUL, _c("k"), _li(3)), ArrowType.INT64)
    assert_equal(Int(out.column_as_primitive_int64(0).get(3)), 12)
    out = _served(Expr.binary(BIN_MUL, _c("x"), _lf(2.0)), ArrowType.FLOAT64)
    assert_equal(out.column_as_primitive_float64(0).get(1), 8.0)
    assert_false(Bool(_run(Expr.binary(BIN_MUL, _c("k"), _li(3)), ArrowType.FLOAT64)))
    assert_false(Bool(_run(Expr.binary(BIN_ADD, _c("n"), _c("n")), ArrowType.INT32)))
    assert_false(Bool(_run(Expr.binary(BIN_ADD, _c("k"), _c("n")), ArrowType.INT64)))
    assert_false(Bool(_run(Expr.binary(BIN_ADD, _c("s"), _c("s")), ArrowType.STRING)))


def _aliased(var e: Expr, depth: Int) -> Expr:
    """`e` under `depth` aliases."""
    var out = e^
    for d in range(depth):
        out = Expr.alias(out^, String("a") + String(d))
    return out^


def test_a_column_under_nested_aliases_is_copied_with_its_nulls() raises:
    """`m` (INT32, row 1 NULL) under two and three aliases is the column
    itself, as in DuckDB: row 1 stays NULL and the other values are kept.
    The INT32 walker reads values only, so a route that reaches it answers
    a valid row 1. Mutant: `_passthrough_col_index` unwrapping one alias
    only (two aliases then reach the walker, which answered a valid row 1
    while it had an INT32 channel; without the channel it declines)."""
    for depth in range(2, 4):
        var out = _served(_aliased(_c("m"), depth), ArrowType.INT32)
        var col = out.column_as_primitive_int32(0)
        assert_equal(Int(col.get(0)), 7)
        assert_true(col.is_null(1), "a NULL under nested aliases is NULL")
        assert_equal(Int(col.get(2)), 9)
        assert_equal(Int(col.get(3)), 10)
        assert_true(out.schema.field_nullable(0))
    # A NULL-free INT64 column under two aliases is copied the same way.
    var k_out = _served(_aliased(_c("k"), 2), ArrowType.INT64)
    assert_equal(Int(k_out.column_as_primitive_int64(0).get(3)), 4)


def _case_with_a_string_branch(var else_: Expr) -> Expr:
    """`CASE WHEN k > 2 THEN 'a' ELSE <else_> END`: the translator lowers the
    string THEN, and the numeric walkers refuse it when they evaluate."""
    var cases = List[WhenCaseData]()
    cases.append(
        WhenCaseData(
            Expr.binary(BIN_GT, _c("k"), _li(2)),
            Expr.literal(ScalarValue.from_string(String("a"))),
        )
    )
    return Expr.when(cases^, else_^)


def test_a_walker_refusal_is_a_decline_on_both_channels() raises:
    """A CASE with a string branch inside arithmetic: the translator lowers it
    and the walker raises when it evaluates, which declines, on the I64 and
    the F64 channel. Mutant: the I64 channel's `return None` made `raise e^`
    (the refusal then propagates)."""
    assert_false(
        Bool(
            _run(
                Expr.binary(BIN_ADD, _case_with_a_string_branch(_li(1)), _c("k")),
                ArrowType.INT64,
            )
        )
    )
    assert_false(
        Bool(
            _run(
                Expr.binary(BIN_ADD, _case_with_a_string_branch(_lf(1.5)), _c("x")),
                ArrowType.FLOAT64,
            )
        )
    )


def test_an_integer_overflow_under_a_float_cast_raises_on_the_f64_channel() raises:
    """`CAST(k * 2^62 AS DOUBLE) + x`: the F64 walker evaluates the cast's
    operand on the I64 walker, which raises on the overflow, and the F64
    channel propagates it. Mutant: the F64 channel's overflow test removed
    (the overflow then declines)."""
    var big = Expr.literal(ScalarValue.from_int64(Int64(4611686018427387904)))
    var e = Expr.binary(
        BIN_ADD,
        Expr.cast(Expr.binary(BIN_MUL, _c("k"), big^), DType.float64),
        _c("x"),
    )
    var msg = String("")
    try:
        _ = _run(e^, ArrowType.FLOAT64)
    except err:
        msg = String(err)
    assert_true(
        msg.find("Overflow in multiplication of INT64") >= 0,
        "the overflow propagates: " + msg,
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
