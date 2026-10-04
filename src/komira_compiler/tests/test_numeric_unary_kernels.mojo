# =============================================================================
# test_numeric_unary_kernels — `abs` / `sign` / `trunc` / `round` EXECUTED,
# cell for cell against DuckDB v1.5.3
# =============================================================================
#
# The four TYPE-PRESERVING numeric members of
# `EXPR_UNARY_OP`, driven through `_eval_column_expr` — the projection-context
# DATA ladder — and through `field_for_expr`, the TYPE ladder, ON THE SAME
# NODE. Both, every case, because the whole reason these did not ride
# `EXPR_MATH_FN` is a TYPE claim, and a test that checked only values would be
# blind to exactly the thing being fixed.
#
# ⛔ EVERY EXPECTED VALUE BELOW WAS MEASURED, not reasoned. They came out of
# DuckDB v1.5.3 over these exact rows on
# transcribed. Do not "correct" one by reading the kernel.
#
# ── THE THREE ANSWERS A PLAUSIBLE-LOOKING KERNEL GETS WRONG ─────────────────
#
# ⭐ (1) SIGNED ZERO, AND IT IS INVISIBLE TO `=`. `abs(-0.0)` is `+0.0` and
# `trunc(-0.5)` is `-0.0`; `-0.0 == 0.0` is TRUE, so an assertion written as
# `assert_equal(v, 0.0)` PASSES for both signs and proves nothing. This file
# asserts on `1.0 / v` instead — `inf` for `+0.0`, `-inf` for `-0.0` — which
# is exactly how the DuckDB oracle was read (`printf('%.17g', 1/abs(f))`).
#   * `abs(x) = (x < 0 ? -x : x)` answers `-0.0`, because `-0.0 < 0` is FALSE.
#     THIS IS THE DESUGAR ROUTE THAT WAS PRICED AND REJECTED.
#   * `trunc(x) = Float64(Int(x))` answers `+0.0`, losing the sign.
#
# ⭐ (2) `abs(INT64_MIN)` HAS NO ANSWER. Two's-complement negation WRAPS to
# INT64_MIN itself — a NEGATIVE absolute value, silently, with no trap on any
# platform this builds for. DuckDB RAISES `Out of Range Error: Overflow on
# abs(-9223372036854775808)` and so must this. `test_abs_int64_min_raises`
# is the whole reason the integer kernel is not three lines.
#
# ⭐ (3) `round` IS HALF AWAY FROM ZERO, NOT BANKER'S. Measured: `round(0.5)`
# =1, `round(1.5)`=2, `round(2.5)`=3, `round(-2.5)`=-3. `nearbyint` under the
# default rounding mode answers 0, 2, 2 for the first three — right twice out
# of four, which is the kind of near-miss a spot check misses.
# And `sign(-0.0)` and `sign(nan)` are BOTH `0`, so `copysign(1, x)` (which
# answers -1 and 1) is not the kernel either.
#
# ── THE FIXTURE ─────────────────────────────────────────────────────────────
#
#   row   f64     i64   why the row is there
#    0   -0.0     -7    signed zero — the row assertion (1) is about
#    1    0.0      0    positive zero, so the two are distinguishable
#    2    2.5      9    round-half UP away from zero
#    3   -2.5     -9    round-half DOWN away from zero (banker's says -2)
#    4    0.5      1    the smallest half, positive
#    5   -0.5     -1    trunc -> `-0.0`; round -> -1
#    6   -2.7     -2    a non-half negative: trunc and round DISAGREE (-2/-3),
#                       which is the pair that separates the two kernels
#    7   NULL   NULL    null in -> null out, on all four ops
#
# ⚠ THE NULL ROW'S STORED VALUE IS `-9.0` / `-9`, NOT ZERO. If a kernel read
# the value instead of the validity bit it would answer 9 for `abs`, and no
# other row answers 9 for `abs` on the f64 column — so the confusion cannot be
# silent. It also proves the INT overflow guard SKIPS null lanes: a garbage
# byte pattern under a null bit must not fail a query DuckDB answers.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.schema import (
    SchemaBuilder,
    Field,
    RecordBatch,
    RecordBatchBuilder,
)
from komira_core.io.heap_region import HeapRegion
from komira_core.helpers.compiler_helpers import field_for_expr
from komira_core.plan.expr import (
    Expr,
    UN_ABS,
    UN_SIGN,
    UN_TRUNC,
    UN_ROUND,
    UN_NEGATE,
)
from komira_core.eval.numeric_unary import (
    numeric_unary_kernel_tag,
    KNUM_ABS,
    KNUM_SIGN,
    KNUM_TRUNC,
    KNUM_ROUND,
)
from komira_compiler.compiler_eval_column import _eval_column_expr


comptime N_ROWS: Int = 8
comptime NULL_ROW: Int = 7


def _f64_col(vals: List[Float64], null_at: Int) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.float64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr.set(i, Scalar[DType.float64](vals[i]))
    if null_at >= 0:
        arr._set_null(null_at)
    return Column.from_primitive[DType.float64](arr^)


def _f32_col(vals: List[Float64], null_at: Int) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.float32].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr.set(i, Scalar[DType.float32](Float32(vals[i])))
    if null_at >= 0:
        arr._set_null(null_at)
    return Column.from_primitive[DType.float32](arr^)


def _i64_col(vals: List[Int64], null_at: Int) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr.set(i, Scalar[DType.int64](vals[i]))
    if null_at >= 0:
        arr._set_null(null_at)
    return Column.from_primitive[DType.int64](arr^)


def _i32_col(vals: List[Int64], null_at: Int) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int32].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr.set(i, Scalar[DType.int32](Int32(Int(vals[i]))))
    if null_at >= 0:
        arr._set_null(null_at)
    return Column.from_primitive[DType.int32](arr^)


def _f_vals() -> List[Float64]:
    return [
        Float64(-0.0), Float64(0.0), Float64(2.5), Float64(-2.5),
        Float64(0.5), Float64(-0.5), Float64(-2.7), Float64(-9.0),
    ]


def _i_vals() -> List[Int64]:
    return [
        Int64(-7), Int64(0), Int64(9), Int64(-9),
        Int64(1), Int64(-1), Int64(-2), Int64(-9),
    ]


def _batch(name: String, ftype: ArrowType, var c0: Column[HeapRegion]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ftype, True))
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(c0^)
    return rbb.build(sb.build())


def _assert_declared(
    label: String, imm e: Expr, imm batch: RecordBatch, want: ArrowType
) raises:
    """★ THE TYPE LADDER, CHECKED ON THE SAME NODE AS THE DATA.

    `MapOp.execute` pairs `_eval_column_expr` (the data) with
    `walk_expr_field` (the type). A node the DATA ladder evaluates while the
    TYPE ladder answers `null` computes RIGHT values under an unexportable
    schema (an `UnsupportedArrowCABIType: Arrow type 'null'` at export).
    And a node whose two ladders disagree on WIDTH is the specific
    failure this whole change exists to prevent."""
    var fld = field_for_expr(e, batch.schema)
    assert_equal(
        fld.arrow_type, want,
        label + ": DECLARED output type (walk_expr_field) is wrong",
    )


# =============================================================================
# FLOAT64 — the family's hardest cases live here
# =============================================================================


def _f64_result(op: UInt8) raises -> Column[HeapRegion]:
    var batch = _batch(String("f"), ArrowType.FLOAT64, _f64_col(_f_vals(), NULL_ROW))
    var e = Expr.unary(op, Expr.col_ref(String("f")))
    var want = ArrowType.INT8 if op == UN_SIGN else ArrowType.FLOAT64
    _assert_declared(String("f64/op") + String(Int(op)), e, batch, want)
    return _eval_column_expr(e, batch)


def _assert_f64(
    label: String, op: UInt8, expect: List[Float64], expect_recip: List[Float64]
) raises:
    """Compare every row BY VALUE and, at the zero rows, BY RECIPROCAL.

    ⚠ `expect_recip` IS NOT REDUNDANT WITH `expect`. `-0.0 == 0.0` is TRUE in
    IEEE-754, so the value column alone cannot distinguish the two, and both
    `abs(-0.0)` (must be `+0.0`) and `trunc(-0.5)` (must be `-0.0`) are cases
    where the SIGN is the entire assertion. `1.0/v` is `inf` vs `-inf`, which
    is also how the DuckDB oracle was read."""
    var col = _f64_result(op)
    assert_equal(col.arrow_type, ArrowType.FLOAT64, label + ": column type")
    var arr = col.as_primitive[DType.float64]()
    for i in range(N_ROWS):
        if i == NULL_ROW:
            assert_true(arr.is_null(i), label + ": row " + String(i) + " must be NULL")
            continue
        assert_true(
            not arr.is_null(i),
            label + ": row " + String(i) + " must NOT be NULL",
        )
        var got = Float64(arr.get(i))
        assert_equal(
            got, expect[i],
            label + ": row " + String(i) + " value",
        )
        var recip = 1.0 / got
        assert_equal(
            recip, expect_recip[i],
            label + ": row " + String(i) + " SIGNED-ZERO check — 1/v. A value"
            + " that compares equal can still have the wrong sign of zero;"
            + " this is the assertion that sees it.",
        )


def test_abs_float64_matches_duckdb() raises:
    """`abs(-0.0)` IS `+0.0`. Measured: `1/abs(-0.0)` = `inf` on v1.5.3."""
    _assert_f64(
        String("abs(f64)"), UN_ABS,
        [Float64(0.0), Float64(0.0), Float64(2.5), Float64(2.5),
         Float64(0.5), Float64(0.5), Float64(2.7), Float64(0.0)],
        # Row 0 is the finding: `inf`, i.e. +0.0, NOT the `-inf` the
        # `CASE WHEN x < 0 THEN -x ELSE x END` desugar would produce.
        [Float64("inf"), Float64("inf"),
         1.0 / 2.5, 1.0 / 2.5, 1.0 / 0.5, 1.0 / 0.5, 1.0 / 2.7, Float64(0.0)],
    )


def test_trunc_float64_matches_duckdb() raises:
    """`trunc(-0.5)` IS `-0.0` — measured `1/trunc(-0.5)` = `-inf`."""
    _assert_f64(
        String("trunc(f64)"), UN_TRUNC,
        [Float64(-0.0), Float64(0.0), Float64(2.0), Float64(-2.0),
         Float64(0.0), Float64(-0.0), Float64(-2.0), Float64(0.0)],
        [Float64("-inf"), Float64("inf"), 0.5, -0.5,
         Float64("inf"), Float64("-inf"), -0.5, Float64(0.0)],
    )


def test_round_float64_is_half_away_from_zero() raises:
    """`round(2.5)`=3 and `round(-2.5)`=-3, NOT the banker's 2 and -2."""
    _assert_f64(
        String("round(f64)"), UN_ROUND,
        [Float64(-0.0), Float64(0.0), Float64(3.0), Float64(-3.0),
         Float64(1.0), Float64(-1.0), Float64(-3.0), Float64(0.0)],
        [Float64("-inf"), Float64("inf"), 1.0 / 3.0, -1.0 / 3.0,
         Float64(1.0), Float64(-1.0), -1.0 / 3.0, Float64(0.0)],
    )


def test_sign_float64_is_int8_and_zero_for_negative_zero() raises:
    """`sign` is the ONE member whose output type is not the operand's: INT8
    (DuckDB TINYINT) for every overload. And `sign(-0.0)` is `0`, which
    `copysign(1.0, x)` would answer `-1` for."""
    var col = _f64_result(UN_SIGN)
    assert_equal(
        col.arrow_type, ArrowType.INT8,
        "sign(f64): the COLUMN must be INT8 — DuckDB declares TINYINT for all"
        " twelve of `sign`'s overloads, and the declared field says INT8, so"
        " an INT64 column here is a schema/data disagreement.",
    )
    var arr = col.as_primitive[DType.int8]()
    var expect: List[Int64] = [
        Int64(0), Int64(0), Int64(1), Int64(-1),
        Int64(1), Int64(-1), Int64(-1), Int64(0),
    ]
    for i in range(N_ROWS):
        if i == NULL_ROW:
            assert_true(arr.is_null(i), "sign(f64): row 7 must be NULL")
            continue
        assert_equal(
            Int64(Int(arr.get(i))), expect[i],
            "sign(f64): row " + String(i),
        )


def test_float64_nan_and_infinity() raises:
    """Measured on v1.5.3: abs(nan)=nan, abs(-inf)=inf, sign(nan)=0.

    ⚠ `nan != nan`, so the NaN rows are asserted with `!=` against themselves
    rather than with `assert_equal`, which would fail on a CORRECT answer."""
    var vals: List[Float64] = [
        Float64("nan"), Float64("inf"), Float64("-inf"),
    ]
    var batch = _batch(
        String("f"), ArrowType.FLOAT64, _f64_col(vals, -1)
    )
    var abs_col = _eval_column_expr(
        Expr.unary(UN_ABS, Expr.col_ref(String("f"))), batch
    )
    var a = abs_col.as_primitive[DType.float64]()
    var a0 = Float64(a.get(0))
    assert_true(a0 != a0, "abs(nan) must be NaN")
    assert_equal(Float64(a.get(1)), Float64("inf"), "abs(inf)")
    assert_equal(Float64(a.get(2)), Float64("inf"), "abs(-inf) must be +inf")

    var sign_col = _eval_column_expr(
        Expr.unary(UN_SIGN, Expr.col_ref(String("f"))), batch
    )
    var s = sign_col.as_primitive[DType.int8]()
    assert_equal(Int64(Int(s.get(0))), Int64(0), "sign(nan) is 0, not 1")
    assert_equal(Int64(Int(s.get(1))), Int64(1), "sign(inf)")
    assert_equal(Int64(Int(s.get(2))), Int64(-1), "sign(-inf)")


# =============================================================================
# THE INTEGER WIDTHS — the type-PRESERVATION claim, and the overflow guard
# =============================================================================


def test_abs_round_trunc_preserve_int64() raises:
    """`abs(BIGINT)` is BIGINT on DuckDB v1.5.3, and `round`/`trunc` of an
    integer are the IDENTITY there. Both the COLUMN and the DECLARED field
    must be INT64 — if either came back FLOAT64 this whole change would have
    bought nothing over `EXPR_MATH_FN`."""
    var ops: List[UInt8] = [UN_ABS, UN_TRUNC, UN_ROUND]
    var expects: List[List[Int64]] = [
        [Int64(7), Int64(0), Int64(9), Int64(9), Int64(1), Int64(1), Int64(2), Int64(0)],
        [Int64(-7), Int64(0), Int64(9), Int64(-9), Int64(1), Int64(-1), Int64(-2), Int64(0)],
        [Int64(-7), Int64(0), Int64(9), Int64(-9), Int64(1), Int64(-1), Int64(-2), Int64(0)],
    ]
    for k in range(len(ops)):
        var batch = _batch(
            String("i"), ArrowType.INT64, _i64_col(_i_vals(), NULL_ROW)
        )
        var e = Expr.unary(ops[k], Expr.col_ref(String("i")))
        _assert_declared(
            String("int64/op") + String(Int(ops[k])), e, batch, ArrowType.INT64
        )
        var col = _eval_column_expr(e, batch)
        assert_equal(
            col.arrow_type, ArrowType.INT64,
            "op " + String(Int(ops[k])) + " over INT64 must stay INT64",
        )
        var arr = col.as_primitive[DType.int64]()
        for i in range(N_ROWS):
            if i == NULL_ROW:
                assert_true(
                    arr.is_null(i),
                    "op " + String(Int(ops[k])) + ": row 7 must be NULL",
                )
                continue
            assert_equal(
                Int64(arr.get(i)), expects[k][i],
                "op " + String(Int(ops[k])) + " int64 row " + String(i),
            )


def test_abs_preserves_int32_and_sign_is_still_int8() raises:
    """The narrower integer width, and the asymmetry that makes the point:
    `abs(INTEGER)` is INTEGER (so the output follows the operand) while
    `sign(INTEGER)` is TINYINT (so it does not). One fixture, both rules."""
    var batch = _batch(
        String("i"), ArrowType.INT32, _i32_col(_i_vals(), NULL_ROW)
    )
    var e_abs = Expr.unary(UN_ABS, Expr.col_ref(String("i")))
    _assert_declared(String("int32/abs"), e_abs, batch, ArrowType.INT32)
    var abs_col = _eval_column_expr(e_abs, batch)
    assert_equal(abs_col.arrow_type, ArrowType.INT32, "abs(int32) column type")
    var a = abs_col.as_primitive[DType.int32]()
    assert_equal(Int64(Int(a.get(0))), Int64(7), "abs(int32) row 0")
    assert_equal(Int64(Int(a.get(3))), Int64(9), "abs(int32) row 3")
    assert_true(a.is_null(NULL_ROW), "abs(int32) null row")

    var batch2 = _batch(
        String("i"), ArrowType.INT32, _i32_col(_i_vals(), NULL_ROW)
    )
    var e_sign = Expr.unary(UN_SIGN, Expr.col_ref(String("i")))
    _assert_declared(String("int32/sign"), e_sign, batch2, ArrowType.INT8)
    var s_col = _eval_column_expr(e_sign, batch2)
    assert_equal(s_col.arrow_type, ArrowType.INT8, "sign(int32) column type")
    var s = s_col.as_primitive[DType.int8]()
    assert_equal(Int64(Int(s.get(0))), Int64(-1), "sign(int32) row 0")
    assert_equal(Int64(Int(s.get(1))), Int64(0), "sign(int32) row 1")
    assert_equal(Int64(Int(s.get(2))), Int64(1), "sign(int32) row 2")


def test_abs_preserves_float32() raises:
    """`abs(FLOAT)` is FLOAT on v1.5.3, not DOUBLE — measured. The kernel does
    its arithmetic in Float64 and narrows back, which is EXACT for these three
    ops (see the note on `eval_numeric_unary_float`); this pins that the
    NARROWING happens rather than the widening being kept."""
    var batch = _batch(
        String("f"), ArrowType.FLOAT32, _f32_col(_f_vals(), NULL_ROW)
    )
    var e = Expr.unary(UN_ABS, Expr.col_ref(String("f")))
    _assert_declared(String("float32/abs"), e, batch, ArrowType.FLOAT32)
    var col = _eval_column_expr(e, batch)
    assert_equal(
        col.arrow_type, ArrowType.FLOAT32,
        "abs(float32) must stay FLOAT32 — a FLOAT64 column here would"
        " contradict the field walk_expr_field just declared.",
    )
    var arr = col.as_primitive[DType.float32]()
    assert_equal(Float64(arr.get(2)), Float64(2.5), "abs(float32) row 2")
    assert_equal(Float64(arr.get(3)), Float64(2.5), "abs(float32) row 3")
    assert_true(arr.is_null(NULL_ROW), "abs(float32) null row")


def test_abs_int64_min_raises() raises:
    """⛔ THE ANSWER THAT DOES NOT EXIST. `-INT64_MIN` WRAPS to INT64_MIN — a
    NEGATIVE absolute value, with no trap on any platform here. DuckDB v1.5.3
    raises `Out of Range Error: Overflow on abs(-9223372036854775808)`
    (measured), so a wrapped negative would be a silent wrong answer against a
    query that HAS a defined outcome."""
    var vals: List[Int64] = [Int64(1), Int64.MIN, Int64(3)]
    var batch = _batch(String("i"), ArrowType.INT64, _i64_col(vals, -1))
    var raised = False
    try:
        var _c = _eval_column_expr(
            Expr.unary(UN_ABS, Expr.col_ref(String("i"))), batch
        )
    except e:
        raised = True
        assert_true(
            "Out of Range" in String(e),
            "abs(INT64_MIN) must raise an OUT-OF-RANGE error naming the"
            " overflow; got: " + String(e),
        )
    assert_true(
        raised,
        "abs(INT64_MIN) RETURNED A VALUE. Two's-complement negation wraps to"
        " INT64_MIN itself, so the answer would be a NEGATIVE absolute value."
        " DuckDB raises; so must this.",
    )


def test_abs_int64_min_under_a_null_bit_does_not_raise() raises:
    """⭐ THE GUARD MUST NOT READ A NULL LANE. A null row's payload is
    arbitrary — nothing zeroes it — so a guard that inspected every slot would
    turn a query DuckDB answers into an error, dependent on garbage bytes.
    Same INT64_MIN, this time with its validity bit clear."""
    var vals: List[Int64] = [Int64(1), Int64.MIN, Int64(3)]
    var batch = _batch(String("i"), ArrowType.INT64, _i64_col(vals, 1))
    var col = _eval_column_expr(
        Expr.unary(UN_ABS, Expr.col_ref(String("i"))), batch
    )
    var arr = col.as_primitive[DType.int64]()
    assert_true(arr.is_null(1), "the INT64_MIN row must come back NULL")
    assert_equal(Int64(arr.get(0)), Int64(1), "row 0 survives")
    assert_equal(Int64(arr.get(2)), Int64(3), "row 2 survives")


def test_negate_still_preserves_type_beside_the_new_members() raises:
    """A CONTROL. `UN_NEGATE` shares the type-preserving tail these four were
    added to; if a refactor of that tail broke it, every arm above could still
    pass while `-x` silently changed type."""
    var batch = _batch(
        String("i"), ArrowType.INT64, _i64_col(_i_vals(), NULL_ROW)
    )
    var e = Expr.unary(UN_NEGATE, Expr.col_ref(String("i")))
    _assert_declared(String("int64/negate"), e, batch, ArrowType.INT64)
    var col = _eval_column_expr(e, batch)
    assert_equal(col.arrow_type, ArrowType.INT64, "-int64 stays INT64")
    var arr = col.as_primitive[DType.int64]()
    assert_equal(Int64(arr.get(0)), Int64(7), "-(-7)")


def test_kernel_tag_mapping_is_a_ladder_not_a_subtraction() raises:
    """The plan-space values and the kernel-space values are DIFFERENT sets,
    and `numeric_unary_kernel_tag` is the only translation.

    ⚠ THIS IS THE COUPLING NO OTHER TEST CAN SEE. `numeric_unary.mojo` is a
    LEAF module that deliberately imports nothing from the plan layer and
    spells the `UN_*` values as bare integers; this file imports BOTH spaces,
    so it is the one place the pairing is checkable at all."""
    assert_equal(numeric_unary_kernel_tag(UN_ABS), KNUM_ABS, "abs")
    assert_equal(numeric_unary_kernel_tag(UN_SIGN), KNUM_SIGN, "sign")
    assert_equal(numeric_unary_kernel_tag(UN_TRUNC), KNUM_TRUNC, "trunc")
    assert_equal(numeric_unary_kernel_tag(UN_ROUND), KNUM_ROUND, "round")
    var raised = False
    try:
        var _t = numeric_unary_kernel_tag(UN_NEGATE)
    except:
        raised = True
    assert_true(
        raised,
        "a UnaryOp with NO type-preserving kernel must RAISE here, not map to"
        " a default. A default would compute some other function's answer.",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_abs_float64_matches_duckdb]()
    suite.test[test_trunc_float64_matches_duckdb]()
    suite.test[test_round_float64_is_half_away_from_zero]()
    suite.test[test_sign_float64_is_int8_and_zero_for_negative_zero]()
    suite.test[test_float64_nan_and_infinity]()
    suite.test[test_abs_round_trunc_preserve_int64]()
    suite.test[test_abs_preserves_int32_and_sign_is_still_int8]()
    suite.test[test_abs_preserves_float32]()
    suite.test[test_abs_int64_min_raises]()
    suite.test[test_abs_int64_min_under_a_null_bit_does_not_raise]()
    suite.test[test_negate_still_preserves_type_beside_the_new_members]()
    suite.test[test_kernel_tag_mapping_is_a_ladder_not_a_subtraction]()
    suite^.run()
