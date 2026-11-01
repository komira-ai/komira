# =============================================================================
# test_computed_project_int_division_cast.mojo: `CAST(<i64> AS DOUBLE)` as, or
# inside, a projection output over a resident post-aggregate batch
# =============================================================================
#
# SUBJECT: `compute_project.eval_project_exprs_over_batch` and, under it,
# `lower_untyped_expr.translate_expr`'s EXPR_CAST arm.
#
# The shape: `sum(num) / sum(den)` per group. Integer `/` truncates in this
# engine, so a front end that wants SQL division wraps the left operand:
# `CAST(num AS DOUBLE) / den`. The aggregate below it is a breaker, so the
# ratio is a computed projection evaluated here.
#
# 1. CONTROL: the same projection with no cast is served and truncates (37
#    where 37.875 is right): dropping the cast is not a fix.
# 2-5. The widening cast (I64 -> F64) is served, nested on either side of the
#    division and as a no-op over a FLOAT64 operand.
# 3. A cast at the root (or one alias down) takes another route: the column
#    evaluator (`_is_cast_output`), which serves widening and narrowing casts.
#    Every boundary case below is written against the NESTED form, which is
#    the one the translator lowers; at the root it would measure the other
#    route.
# 6-8. The translator admits the widening direction only: a nested narrowing
#    cast, a nested non-FLOAT64 target and a nested STRING operand decline.
# 9. A NULL input stays NULL through a nested FLOAT64 cast (a strict
#    expression over a batch holding a NULL takes the column evaluator, which
#    keeps validity).
#
# The oracle is closed-form and exact: every denominator is a power of two,
# so each quotient is exact in float64 and the assertions are equalities. A
# tolerance would accept the truncated answer, which is off by less than 1.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.string_array import StringArray
from komira_plan_expr.expr import Expr, BIN_ADD, BIN_DIV
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_ir.logical_plan import ExprArray

from komira_dispatch_project.compute_project import (
    eval_project_exprs_over_batch,
)


# =============================================================================
# FIXTURE: the batch an aggregate hands its parent projection: the group key
# (`region`, STRING), the two integer sums, and a float column for the no-op
# cast case. Every `den` is a power of two and no `num` is a multiple of it,
# so the exact and the truncated quotient differ on every row.
# =============================================================================

comptime _N_ROWS: Int = 4


def _num() -> List[Int64]:
    var v = List[Int64](capacity=4)
    v.append(Int64(303))
    v.append(Int64(75))
    v.append(Int64(9))
    v.append(Int64(1001))
    return v^


def _den() -> List[Int64]:
    var v = List[Int64](capacity=4)
    v.append(Int64(8))
    v.append(Int64(32))
    v.append(Int64(2))
    v.append(Int64(16))
    return v^


def _exact() -> List[Float64]:
    """303/8 = 37.875, 75/32 = 2.34375, 9/2 = 4.5, 1001/16 = 62.5625: each
    exact in float64 because each denominator is a power of two."""
    var v = List[Float64](capacity=4)
    v.append(Float64(37.875))
    v.append(Float64(2.34375))
    v.append(Float64(4.5))
    v.append(Float64(62.5625))
    return v^


def _trunc() -> List[Int64]:
    """What a truncating `BIN_DIV` answers instead."""
    var v = List[Int64](capacity=4)
    v.append(Int64(37))
    v.append(Int64(2))
    v.append(Int64(4))
    v.append(Int64(62))
    return v^


def _agg_out_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("region"), ArrowType.STRING, False))
    sb.add_field(Field(String("num"), ArrowType.INT64, False))
    sb.add_field(Field(String("den"), ArrowType.INT64, False))
    sb.add_field(Field(String("amount"), ArrowType.FLOAT64, False))
    return sb.build()


def _agg_out_batch() raises -> RecordBatch:
    var n = _N_ROWS
    var nv = _num()
    var dv = _den()
    var ev = _exact()
    var regions = List[String](capacity=n)
    var nums = PrimitiveArray[DType.int64].allocate(n)
    var dens = PrimitiveArray[DType.int64].allocate(n)
    var amts = PrimitiveArray[DType.float64].allocate(n)
    for i in range(n):
        regions.append(String("r") + String(i))
        nums.store[1](i, SIMD[DType.int64, 1](nv[i]))
        dens.store[1](i, SIMD[DType.int64, 1](dv[i]))
        amts.store[1](i, SIMD[DType.float64, 1](ev[i]))
    var rbb = RecordBatchBuilder.with_capacity(4)
    rbb.add_column(Column.from_string(StringArray.from_strings(regions)))
    rbb.add_column(Column.from_primitive[DType.int64](nums))
    rbb.add_column(Column.from_primitive[DType.int64](dens))
    rbb.add_column(Column.from_primitive[DType.float64](amts))
    return rbb.build(_agg_out_schema())


def _one_expr(var e: Expr, out_name: String) raises -> ExprArray:
    """One computed output beside the group key: the post-aggregate
    projection's shape."""
    var exprs = ExprArray()
    exprs.append(Expr.col_ref(String("region")))
    exprs.append(Expr.alias(e^, out_name))
    return exprs^


def _out_schema(out_name: String, out_at: ArrowType) raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("region"), ArrowType.STRING, False))
    sb.add_field(Field(out_name, out_at, True))
    return sb.build()


def _cast_f64(var child: Expr) raises -> Expr:
    return Expr.cast(child^, DType.float64)


def _ratio_expr_with_cast() raises -> Expr:
    """`CAST(num AS DOUBLE) / den`: the cast on the left only, the shape a
    front end emits for an all-integral `/`."""
    return Expr.binary(
        BIN_DIV, _cast_f64(Expr.col_ref(String("num"))), Expr.col_ref(String("den"))
    )


def _assert_key_intact(imm out: RecordBatch) raises:
    """The passthrough group key is unchanged."""
    assert_equal(out.num_columns(), 2, "two output columns")
    assert_equal(out.num_rows(), _N_ROWS, "a Project is ROW-PRESERVING")
    var regions = out.column_as_string(0)
    for i in range(_N_ROWS):
        assert_equal(regions.get(i), String("r") + String(i))


# =============================================================================
# 1. CONTROL: an uncast integer division truncates.
# =============================================================================


def test_an_uncast_integer_division_is_served_and_TRUNCATES() raises:
    """`num / den` over two int64 columns is served on the I64 channel and
    answers the truncated quotient: 37 where 37.875 is right. This is what
    dropping the cast would answer."""
    var out_opt = eval_project_exprs_over_batch(
        _agg_out_batch(),
        _one_expr(
            Expr.binary(
                BIN_DIV,
                Expr.col_ref(String("num")),
                Expr.col_ref(String("den")),
            ),
            String("ratio"),
        ),
        _out_schema(String("ratio"), ArrowType.INT64),
    )
    assert_true(Bool(out_opt), "an uncast i64/i64 was already served")
    var out = out_opt.take()
    _assert_key_intact(out)
    var got = out.column_as_primitive_int64(1)
    for i in range(_N_ROWS):
        assert_equal(
            Int(got.get(i)),
            Int(_trunc()[i]),
            "uncast integer division truncates — this is the WRONG answer the"
            " FLOAT64 cast exists to prevent",
        )


# =============================================================================
# 2. A nested widening cast is served exactly.
# =============================================================================


def test_a_float64_cast_inside_an_integer_division_is_served_EXACTLY() raises:
    """`CAST(num AS DOUBLE) / den` is translated (EXPR_I64_TO_F64 under
    EXPR_DIV_F64) and answers the exact quotient. Without the translator's
    cast arm it raises, and the projection declines.

    `assert_equal` on FLOAT64, not a tolerance: each quotient is exact."""
    var out_opt = eval_project_exprs_over_batch(
        _agg_out_batch(),
        _one_expr(_ratio_expr_with_cast(), String("ratio")),
        _out_schema(String("ratio"), ArrowType.FLOAT64),
    )
    assert_true(
        Bool(out_opt),
        "CAST(num AS DOUBLE) / den must be served",
    )
    var out = out_opt.take()
    _assert_key_intact(out)
    assert_true(
        out.schema.field_arrow_type(1) == ArrowType.FLOAT64,
        "the ratio column is FLOAT64, the type the plan declared",
    )
    var got = out.column_as_primitive_float64(1)
    assert_equal(got.length, _N_ROWS, "ONE value per row of THIS batch")
    for i in range(_N_ROWS):
        assert_equal(
            Float64(got.get(i)),
            _exact()[i],
            "the quotient must be the EXACT float64 value, not the floor",
        )


# =============================================================================
# 3. A root cast takes the column-evaluator route (a control).
# =============================================================================


def test_a_ROOT_level_cast_was_already_served_by_the_overlay_arm() raises:
    """`_is_cast_output` matches an `EXPR_CAST` at the root (or one alias
    down) and hands it to the column evaluator, whose cast ladder serves
    INT64 -> FLOAT64. The translator's cast arm is reached only by a cast
    nested deeper, as in case 2."""
    var out_opt = eval_project_exprs_over_batch(
        _agg_out_batch(),
        _one_expr(_cast_f64(Expr.col_ref(String("num"))), String("n")),
        _out_schema(String("n"), ArrowType.FLOAT64),
    )
    assert_true(
        Bool(out_opt),
        "a root widening cast is served by the column-evaluator arm",
    )
    var out = out_opt.take()
    _assert_key_intact(out)
    var got = out.column_as_primitive_float64(1)
    for i in range(_N_ROWS):
        assert_equal(Float64(got.get(i)), Float64(_num()[i]))


def test_the_ROOT_narrowing_cast_is_ALSO_served_by_the_overlay() raises:
    """`CAST(amount AS BIGINT)` at the root is served by the column
    evaluator's FLOAT64 -> INT64 arm. Case 6's decline is about the nested
    form only."""
    var out_opt = eval_project_exprs_over_batch(
        _agg_out_batch(),
        _one_expr(
            Expr.cast(Expr.col_ref(String("amount")), DType.int64),
            String("t"),
        ),
        _out_schema(String("t"), ArrowType.INT64),
    )
    assert_true(
        Bool(out_opt),
        "the root narrowing cast goes through the column evaluator",
    )


# =============================================================================
# 4. A nested no-op cast: the F64-operand branch of the cast arm.
# =============================================================================


def test_a_nested_float64_cast_over_a_FLOAT_child_is_served() raises:
    """`CAST(amount AS DOUBLE) + amount`: the cast is nested and its operand
    is already F64. The arm emits the operand itself rather than a widening
    node, so the values are the plain sum. (Without the F64 answer for the
    cast in `_infer_runtime_dtype`, `_translate_binary` raises on the
    UNSUPPORTED operand.)"""
    var expr = Expr.binary(
        BIN_ADD,
        _cast_f64(Expr.col_ref(String("amount"))),
        Expr.col_ref(String("amount")),
    )
    var out_opt = eval_project_exprs_over_batch(
        _agg_out_batch(),
        _one_expr(expr^, String("a")),
        _out_schema(String("a"), ArrowType.FLOAT64),
    )
    assert_true(Bool(out_opt), "a nested FLOAT64->FLOAT64 cast must be served")
    var out = out_opt.take()
    var got = out.column_as_primitive_float64(1)
    for i in range(_N_ROWS):
        assert_equal(Float64(got.get(i)), _exact()[i] + _exact()[i])


# =============================================================================
# 5. The cast on the right operand.
# =============================================================================


def test_the_cast_is_served_on_either_side_of_the_division() raises:
    """`num / CAST(den AS DOUBLE)`: the mixed-family widening in
    `_translate_binary` is symmetric. The quotients are case 2's."""
    var expr = Expr.binary(
        BIN_DIV,
        Expr.col_ref(String("num")),
        _cast_f64(Expr.col_ref(String("den"))),
    )
    var out_opt = eval_project_exprs_over_batch(
        _agg_out_batch(),
        _one_expr(expr^, String("ratio")),
        _out_schema(String("ratio"), ArrowType.FLOAT64),
    )
    assert_true(Bool(out_opt), "a right-side widening cast must be served")
    var out = out_opt.take()
    var got = out.column_as_primitive_float64(1)
    for i in range(_N_ROWS):
        assert_equal(Float64(got.get(i)), _exact()[i])


# =============================================================================
# 6-8. The boundary: the translator lowers the widening cast only. All three
# cases use the nested form; the root form takes the column evaluator (3).
# =============================================================================


def test_a_nested_NARROWING_cast_still_declines() raises:
    """`CAST(amount AS BIGINT) + num` declines. The narrowing direction has a
    rounding rule, an overflow rule and a TRY_CAST rule the widening one does
    not, and the column evaluator already answers the root form with its own;
    a second implementation in the translator could disagree with it."""
    var expr = Expr.binary(
        BIN_ADD,
        Expr.cast(Expr.col_ref(String("amount")), DType.int64),
        Expr.col_ref(String("num")),
    )
    var out_opt = eval_project_exprs_over_batch(
        _agg_out_batch(),
        _one_expr(expr^, String("t")),
        _out_schema(String("t"), ArrowType.INT64),
    )
    assert_false(
        Bool(out_opt),
        "the narrowing f64->i64 cast is outside the translator's cast arm",
    )


def test_a_nested_non_float64_cast_target_still_declines() raises:
    """`CAST(num AS INT32) + num`. The arm matches a FLOAT64 target only;
    every other target is refused, so the walker is never handed a sub-tree
    whose family it has no channel for."""
    var expr = Expr.binary(
        BIN_ADD,
        Expr.cast(Expr.col_ref(String("num")), DType.int32),
        Expr.col_ref(String("num")),
    )
    var out_opt = eval_project_exprs_over_batch(
        _agg_out_batch(),
        _one_expr(expr^, String("t")),
        _out_schema(String("t"), ArrowType.INT64),
    )
    assert_false(Bool(out_opt), "an INT32 cast target is still out of envelope")


def test_a_nested_float64_cast_over_a_STRING_child_still_declines() raises:
    """`CAST(region AS DOUBLE) / den`: an admitted target over a STRING
    operand. `_infer_runtime_dtype` checks the operand too and answers
    UNSUPPORTED for the cast, so the division's family is UNSUPPORTED and the
    projection declines."""
    var expr = Expr.binary(
        BIN_DIV,
        _cast_f64(Expr.col_ref(String("region"))),
        Expr.col_ref(String("den")),
    )
    var out_opt = eval_project_exprs_over_batch(
        _agg_out_batch(),
        _one_expr(expr^, String("t")),
        _out_schema(String("t"), ArrowType.FLOAT64),
    )
    assert_false(
        Bool(out_opt), "a STRING source is outside the widening arm"
    )


# =============================================================================
# 9. A NULL aggregate stays NULL through the cast.
# =============================================================================
# `sum(v)` over an all-NULL group is NULL, and `CAST(NULL AS DOUBLE) / 2` is
# NULL in DuckDB. The walker's EXPR_I64_TO_F64 reads values only, so on the
# walker route the NULL row would come back as a valid 0.0. A FLOAT64-target
# cast is strict, so it is in `_expr_is_strict_null_propagating`, and a batch
# that holds a NULL takes the column evaluator, whose cast keeps validity. A
# NULL-free batch keeps the walker route.


def _num_with_null() raises -> RecordBatch:
    """`_agg_out_batch` with row 2's `num` NULL: an aggregate over an all-NULL
    group."""
    var n = _N_ROWS
    var nv = _num()
    var dv = _den()
    var ev = _exact()
    var regions = List[String](capacity=n)
    var nums = PrimitiveArray[DType.int64].allocate_nullable(n)
    var dens = PrimitiveArray[DType.int64].allocate(n)
    var amts = PrimitiveArray[DType.float64].allocate(n)
    for i in range(n):
        regions.append(String("r") + String(i))
        nums.store[1](i, SIMD[DType.int64, 1](nv[i]))
        dens.store[1](i, SIMD[DType.int64, 1](dv[i]))
        amts.store[1](i, SIMD[DType.float64, 1](ev[i]))
    nums._set_null(2)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("region"), ArrowType.STRING, False))
    sb.add_field(Field(String("num"), ArrowType.INT64, True))
    sb.add_field(Field(String("den"), ArrowType.INT64, False))
    sb.add_field(Field(String("amount"), ArrowType.FLOAT64, False))
    var rbb = RecordBatchBuilder.with_capacity(4)
    rbb.add_column(Column.from_string(StringArray.from_strings(regions)))
    rbb.add_column(Column.from_primitive[DType.int64](nums))
    rbb.add_column(Column.from_primitive[DType.int64](dens))
    rbb.add_column(Column.from_primitive[DType.float64](amts))
    return rbb.build(sb.build())


def test_a_NULL_input_stays_NULL_through_a_nested_float64_cast() raises:
    """Row 2 is NULL; on the walker route it would be a valid 0.0. The other
    three rows are case 2's exact quotients."""
    var out_opt = eval_project_exprs_over_batch(
        _num_with_null(),
        _one_expr(_ratio_expr_with_cast(), String("ratio")),
        _out_schema(String("ratio"), ArrowType.FLOAT64),
    )
    assert_true(Bool(out_opt), "CAST(num AS DOUBLE) / den is served")
    var out = out_opt.take()
    _assert_key_intact(out)
    var got = out.column_as_primitive_float64(1)
    assert_true(
        got.is_null(2),
        "CAST(NULL AS DOUBLE) / 8 is NULL, not 0.0 (the walker drops validity)",
    )
    for i in range(_N_ROWS):
        if i == 2:
            continue
        assert_false(got.is_null(i), "a non-NULL input row stays valid")
        assert_equal(Float64(got.get(i)), _exact()[i], "the exact quotient")


def test_a_NULL_input_stays_NULL_through_a_float64_cast_with_a_LITERAL_divisor() raises:
    """`sum(v) / 2`: the divisor is a literal."""
    var out_opt = eval_project_exprs_over_batch(
        _num_with_null(),
        _one_expr(
            Expr.binary(
                BIN_DIV,
                _cast_f64(Expr.col_ref(String("num"))),
                Expr.literal(ScalarValue.from_int64(2)),
            ),
            String("half"),
        ),
        _out_schema(String("half"), ArrowType.FLOAT64),
    )
    assert_true(Bool(out_opt), "CAST(num AS DOUBLE) / 2 is served")
    var out = out_opt.take()
    var got = out.column_as_primitive_float64(1)
    assert_true(got.is_null(2), "CAST(NULL AS DOUBLE) / 2 is NULL")
    assert_equal(Float64(got.get(0)), Float64(151.5), "303 / 2 = 151.5")
    assert_equal(Float64(got.get(1)), Float64(37.5), "75 / 2 = 37.5")
    assert_equal(Float64(got.get(3)), Float64(500.5), "1001 / 2 = 500.5")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
