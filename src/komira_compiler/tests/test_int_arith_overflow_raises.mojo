"""INTEGER `+ - *` RAISE ON OVERFLOW; FLOAT `%` IS C `fmod`.

★ THE DEFECT THIS PINS (fixture a = [MAX, MIN, 5, -7], b = [1, -1, 7, 3],
against DuckDB 1.5.3), as a wrapping engine answers it:

    SELECT a + b            wraps [MIN, MAX, 12, -4]      DuckDB  Out of Range Error
    SELECT a * 2            wraps [-2, 0, 10, -14]        DuckDB  Out of Range Error
    SELECT i + 1  (INT32)   wraps [-2147483648, ...]      DuckDB  Out of Range Error
    SELECT x % y  (DOUBLE)  mod(-0.0, 1.0) = +0.0         DuckDB  -0.0
                            mod(DBL_MAX, 10.0) = 0.0      DuckDB  8.0

The same wrap answered through WHERE (`count(*) WHERE a + b > 0` = 2 where
DuckDB raises), CASE, a computed aggregand (`sum(a * 2)` = -2) and a
post-aggregate projection (`max(a) + 1` = MIN).

★ THE ORACLE. DuckDB 1.5.3 raises, and names the operation, the physical type
and both operands:

    Out of Range Error: Overflow in addition of INT64 (9223372036854775807 + 1)!

polars 1.44.2 and pandas 3.0.6 WRAP (measured). The SQL and untyped-Mojo doors
answer like DuckDB; a skin that cannot wrap refuses by name — this raise.

★ WHAT EACH SECTION CATCHES, so no single wrong fix passes them all:
  §1 the PROJECT route (`_eval_column_expr`), col-col, every op, the sentence.
  §2 col-LITERAL (the scalar kernels) and the literal on the LEFT (`-1 - MAX`
     is MIN, a VALID answer: a `-(col - lit)` rewrite raises there).
  §3 CONTROLS — in-range values, products that FIT but trip the Float64 screen
     (3037000499^2, MIN * 1), and MIN / MAX themselves pass through untouched.
     A fix that raised on "large" instead of "overflowed" passes §1 and dies here.
  §4 NULL — a row whose payload overflows under a NULL bit is NULL, not a raise.
  §5 a 1000-row column: the overflow in the SIMD body (not only the tail), and
     the sentence names THAT row's operands.
  §6 every width through the kernel (INT8/16/32, UINT64): the predicates are
     written once over the dtype, and a width-specific slip shows here.
  §7 FLOAT `%` is `fmod`, bit for bit (sign of zero, DBL_MAX), and float `+`
     never raises (IEEE inf is an answer).
  §8 CASE — an arm is evaluated only over the rows it ANSWERS (DuckDB's rule):
     `CASE WHEN a < 100 THEN a + b ELSE 0 END` answers where `a + b` overflows
     on a row the WHEN excludes, and still raises for a row it includes. ⚠ The
     skins' floor `%` (`CASE WHEN <wrong sign> THEN tm + r ELSE tm END`) is this
     shape; `proj_int_divmod_wide` moved PASS -> REFUSED at polars / pandas
     before the arm-selection retry.
  §9 AND / OR — the right side is asked only of the rows the left has not
     decided: `WHERE a < 100 AND a + b > 0` answers (DuckDB does), through
     `_eval_predicate`'s short-circuit AND / OR and through the filter funnel's
     three-valued descent (an AND nested under an OR).
"""

from std.memory import bitcast
from std.testing import assert_true, assert_false, assert_equal, TestSuite

from komira_core.arrow import PrimitiveArray
from komira_core.arrow.schema import (
    Schema, SchemaBuilder, Field, RecordBatch, RecordBatchBuilder,
)
from komira_core.arrow.column import Column
from komira_core.arrow.arrow_types import ArrowType
from komira_core.plan.expr import Expr, WhenCaseData, BIN_ADD, BIN_SUB, BIN_MUL, BIN_MOD, BIN_LT, BIN_GT, BIN_AND, BIN_OR, BIN_EQ, UN_NEGATE
from komira_core.plan.scalar_value import ScalarValue
from komira_core.eval.arithmetic import (
    eval_add,
    eval_sub,
    eval_mul,
    eval_add_scalar,
    eval_mul_scalar,
)
from komira_compiler.compiler_eval_column import _eval_column_expr
from komira_compiler.compiler_eval_predicate import _eval_predicate
from komira_compiler.conjunction import evaluate_filter_narrowed


comptime I64_MAX = Int64(9223372036854775807)
comptime I64_MIN = Int64(-9223372036854775807) - 1


# =============================================================================
# Helpers
# =============================================================================


def _i64_nullable(vals: List[Int64], nulls: List[Int]) raises -> PrimitiveArray[DType.int64]:
    if len(nulls) == 0:
        var out: List[Scalar[DType.int64]] = []
        for i in range(len(vals)):
            out.append(Scalar[DType.int64](vals[i]))
        return PrimitiveArray[DType.int64].from_list(out)
    var arr = PrimitiveArray[DType.int64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr.set(i, Scalar[DType.int64](vals[i]))
    for j in range(len(nulls)):
        arr._set_null(nulls[j])
    return arr^


def _ab_batch(
    a: List[Int64], a_nulls: List[Int], b: List[Int64], b_nulls: List[Int]
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    var rbb = RecordBatchBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.INT64, True))
    rbb.add_column(Column.from_primitive[DType.int64](_i64_nullable(a, a_nulls)))
    rbb.add_column(Column.from_primitive[DType.int64](_i64_nullable(b, b_nulls)))
    return rbb.build(sb.build())


def _i32_batch(vals: List[Int32]) raises -> RecordBatch:
    var out: List[Scalar[DType.int32]] = []
    for i in range(len(vals)):
        out.append(Scalar[DType.int32](vals[i]))
    var sb = SchemaBuilder()
    var rbb = RecordBatchBuilder()
    sb.add_field(Field("i", ArrowType.INT32, True))
    rbb.add_column(
        Column.from_primitive[DType.int32](PrimitiveArray[DType.int32].from_list(out))
    )
    return rbb.build(sb.build())


def _f64_batch(x: List[Float64], y: List[Float64]) raises -> RecordBatch:
    var xo: List[Scalar[DType.float64]] = []
    var yo: List[Scalar[DType.float64]] = []
    for i in range(len(x)):
        xo.append(Scalar[DType.float64](x[i]))
        yo.append(Scalar[DType.float64](y[i]))
    var sb = SchemaBuilder()
    var rbb = RecordBatchBuilder()
    sb.add_field(Field("x", ArrowType.FLOAT64, True))
    sb.add_field(Field("y", ArrowType.FLOAT64, True))
    rbb.add_column(Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(xo)))
    rbb.add_column(Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(yo)))
    return rbb.build(sb.build())


def _col(name: String) -> Expr:
    return Expr.col_ref(name)


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _raise_text(e: Expr, batch: RecordBatch) raises -> String:
    """Evaluate `e`; return the raise's text, or "" if it ANSWERED."""
    try:
        _ = _eval_column_expr(e, batch)
    except err:
        return String(err)
    return String("")


def _assert_raises_exactly(e: Expr, batch: RecordBatch, want: String) raises:
    var got = _raise_text(e, batch)
    assert_true(
        got.find(want) >= 0,
        String("want a raise containing `") + want + "`, got `" + got + "`",
    )


def _bits(v: Float64) -> UInt64:
    return bitcast[DType.uint64, 1](SIMD[DType.float64, 1](v))[0]


# =============================================================================
# §1 THE PROJECT ROUTE, col vs col — THE REPRODUCTION
# =============================================================================


def test_colcol_add_overflow_raises_duckdb_sentence() raises:
    var batch = _ab_batch([I64_MAX, Int64(5)], [], [Int64(1), Int64(7)], [])
    _assert_raises_exactly(
        Expr.binary(BIN_ADD, _col("a"), _col("b")),
        batch,
        "Out of Range Error: Overflow in addition of INT64 (9223372036854775807 + 1)!",
    )


def test_colcol_add_negative_overflow_raises() raises:
    var batch = _ab_batch([Int64(5), I64_MIN], [], [Int64(7), Int64(-1)], [])
    _assert_raises_exactly(
        Expr.binary(BIN_ADD, _col("a"), _col("b")),
        batch,
        "Overflow in addition of INT64 (-9223372036854775808 + -1)!",
    )


def test_colcol_sub_overflow_raises() raises:
    var batch = _ab_batch([I64_MIN], [], [Int64(1)], [])
    _assert_raises_exactly(
        Expr.binary(BIN_SUB, _col("a"), _col("b")),
        batch,
        "Overflow in subtraction of INT64 (-9223372036854775808 - 1)!",
    )


def test_colcol_mul_overflow_raises_both_signs() raises:
    var b1 = _ab_batch([I64_MIN], [], [Int64(-1)], [])
    _assert_raises_exactly(
        Expr.binary(BIN_MUL, _col("a"), _col("b")),
        b1,
        "Overflow in multiplication of INT64 (-9223372036854775808 * -1)!",
    )
    var b2 = _ab_batch([Int64(3037000500)], [], [Int64(-3037000500)], [])
    _assert_raises_exactly(
        Expr.binary(BIN_MUL, _col("a"), _col("b")),
        b2,
        "Overflow in multiplication of INT64 (3037000500 * -3037000500)!",
    )


# =============================================================================
# §2 col vs LITERAL, and the literal on the LEFT
# =============================================================================


def test_col_times_literal_overflow_raises() raises:
    var batch = _ab_batch([Int64(5), I64_MAX], [], [Int64(0), Int64(0)], [])
    _assert_raises_exactly(
        Expr.binary(BIN_MUL, _col("a"), _lit(2)),
        batch,
        "Overflow in multiplication of INT64 (9223372036854775807 * 2)!",
    )
    _assert_raises_exactly(
        Expr.binary(BIN_ADD, _col("a"), _lit(1)),
        batch,
        "Overflow in addition of INT64 (9223372036854775807 + 1)!",
    )


def test_col_minus_literal_overflow_raises() raises:
    var batch = _ab_batch([I64_MIN], [], [Int64(0)], [])
    _assert_raises_exactly(
        Expr.binary(BIN_SUB, _col("a"), _lit(1)),
        batch,
        "Overflow in subtraction of INT64 (-9223372036854775808 - 1)!",
    )


def test_literal_minus_col_overflow_names_the_literal_first() raises:
    """`0 - a` over MIN: DuckDB `(0 - -9223372036854775808)`."""
    var batch = _ab_batch([I64_MIN], [], [Int64(0)], [])
    _assert_raises_exactly(
        Expr.binary(BIN_SUB, _lit(0), _col("a")),
        batch,
        "Overflow in subtraction of INT64 (0 - -9223372036854775808)!",
    )


def test_literal_minus_col_whose_answer_is_MIN_is_ANSWERED() raises:
    """`-1 - MAX` = MIN, which EXISTS. The old `-(MAX - (-1))` spelling would
    have raised here — the true-answer-at-the-boundary control for the literal
    on the left."""
    var batch = _ab_batch([I64_MAX, Int64(10)], [], [Int64(0), Int64(0)], [])
    var out = _eval_column_expr(Expr.binary(BIN_SUB, _lit(-1), _col("a")), batch)
    var arr = out.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(0)), Int(I64_MIN), "-1 - MAX is MIN")
    assert_equal(Int(arr.get(1)), -11, "-1 - 10")


def test_literal_minus_col_keeps_nulls() raises:
    """`100 - a` over a NULL row stays NULL ('s contract,
    re-asserted on the new rsub kernel)."""
    var batch = _ab_batch([Int64(1), Int64(0)], [1], [Int64(0), Int64(0)], [])
    var out = _eval_column_expr(Expr.binary(BIN_SUB, _lit(100), _col("a")), batch)
    var arr = out.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(0)), 99)
    assert_true(arr.is_null(1), "100 - NULL is NULL")


def test_int32_col_plus_literal_overflow_raises_as_INT32() raises:
    var batch = _i32_batch([Int32(5), Int32(2147483647)])
    _assert_raises_exactly(
        Expr.binary(BIN_ADD, _col("i"), _lit(1)),
        batch,
        "Overflow in addition of INT32 (2147483647 + 1)!",
    )
    _assert_raises_exactly(
        Expr.binary(BIN_MUL, _col("i"), _lit(2)),
        batch,
        "Overflow in multiplication of INT32 (2147483647 * 2)!",
    )


def test_int32_literal_minus_col() raises:
    """`-1 - i` over INT32: -1 - 2147483647 = -2147483648 fits; 0 - (-2^31)
    does not."""
    var ok = _eval_column_expr(
        Expr.binary(BIN_SUB, _lit(-1), _col("i")), _i32_batch([Int32(2147483647)])
    )
    assert_equal(Int(ok.as_primitive[DType.int32]().get(0)), -2147483648)
    _assert_raises_exactly(
        Expr.binary(BIN_SUB, _lit(0), _col("i")),
        _i32_batch([Int32(-2147483648)]),
        "Overflow in subtraction of INT32 (0 - -2147483648)!",
    )


def test_negation_of_MIN_raises_duckdbs_negation_sentence() raises:
    """`-a` is spelled `a * -1`; DuckDB 1.5.3 names the NEGATION:
    `Out of Range Error: Overflow in negation of numeric value!`."""
    var batch = _ab_batch([Int64(5), I64_MIN], [], [Int64(0), Int64(0)], [])
    _assert_raises_exactly(
        Expr.unary(UN_NEGATE, _col("a")),
        batch,
        "Out of Range Error: Overflow in negation of numeric value!",
    )
    var ok = _eval_column_expr(
        Expr.unary(UN_NEGATE, _col("a")),
        _ab_batch([I64_MAX, Int64(-7)], [], [Int64(0), Int64(0)], []),
    )
    assert_equal(Int(ok.as_primitive[DType.int64]().get(0)), -9223372036854775807)
    assert_equal(Int(ok.as_primitive[DType.int64]().get(1)), 7)


# =============================================================================
# §3 CONTROLS — nothing that FITS may raise
# =============================================================================


def test_in_range_values_answer_exactly() raises:
    var batch = _ab_batch(
        [Int64(10), Int64(-20), Int64(5), Int64(-7)],
        [],
        [Int64(1), Int64(-1), Int64(7), Int64(3)],
        [],
    )
    var add = _eval_column_expr(Expr.binary(BIN_ADD, _col("a"), _col("b")), batch)
    var sub = _eval_column_expr(Expr.binary(BIN_SUB, _col("a"), _col("b")), batch)
    var mul = _eval_column_expr(Expr.binary(BIN_MUL, _col("a"), _col("b")), batch)
    var want_add: List[Int] = [11, -21, 12, -4]
    var want_sub: List[Int] = [9, -19, -2, -10]
    var want_mul: List[Int] = [10, 20, 35, -21]
    for i in range(4):
        assert_equal(Int(add.as_primitive[DType.int64]().get(i)), want_add[i])
        assert_equal(Int(sub.as_primitive[DType.int64]().get(i)), want_sub[i])
        assert_equal(Int(mul.as_primitive[DType.int64]().get(i)), want_mul[i])


def test_the_boundary_values_themselves_pass_through() raises:
    """MAX + 0, MIN - 0, MAX - 1, MIN + 1, MAX * 1, MIN * 1, MAX * -1."""
    var batch = _ab_batch([I64_MAX, I64_MIN], [], [Int64(0), Int64(0)], [])
    var p0 = _eval_column_expr(Expr.binary(BIN_ADD, _col("a"), _col("b")), batch)
    assert_equal(Int(p0.as_primitive[DType.int64]().get(0)), Int(I64_MAX))
    assert_equal(Int(p0.as_primitive[DType.int64]().get(1)), Int(I64_MIN))
    var m1 = _eval_column_expr(Expr.binary(BIN_MUL, _col("a"), _lit(1)), batch)
    assert_equal(Int(m1.as_primitive[DType.int64]().get(0)), Int(I64_MAX))
    assert_equal(Int(m1.as_primitive[DType.int64]().get(1)), Int(I64_MIN))
    var only_max = _ab_batch([I64_MAX], [], [Int64(0)], [])
    var mn = _eval_column_expr(Expr.binary(BIN_MUL, _col("a"), _lit(-1)), only_max)
    assert_equal(Int(mn.as_primitive[DType.int64]().get(0)), -9223372036854775807)
    var s1 = _eval_column_expr(Expr.binary(BIN_SUB, _col("a"), _lit(1)), only_max)
    assert_equal(Int(s1.as_primitive[DType.int64]().get(0)), 9223372036854775806)


def test_a_product_that_FITS_but_trips_the_float_screen_is_answered() raises:
    """3037000499^2 = 9223372030926249001 < MAX: above the 2^62 screen, so the
    exact 128-bit re-walk runs — and must find NO overflow."""
    var batch = _ab_batch(
        [Int64(3037000499), Int64(-3037000499), Int64(4611686018427387904)],
        [],
        [Int64(3037000499), Int64(3037000499), Int64(-2)],
        [],
    )
    var out = _eval_column_expr(Expr.binary(BIN_MUL, _col("a"), _col("b")), batch)
    var arr = out.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(0)), 9223372030926249001)
    assert_equal(Int(arr.get(1)), -9223372030926249001)
    assert_equal(Int(arr.get(2)), Int(I64_MIN), "2^62 * -2 is exactly MIN")


# =============================================================================
# §4 NULL — a row's payload is not an operand when the row is NULL
# =============================================================================


def test_an_overflowing_payload_under_a_NULL_bit_is_NULL_not_a_raise() raises:
    var batch = _ab_batch(
        [I64_MAX, Int64(5), Int64(-7)], [0], [Int64(1), Int64(7), I64_MIN], [2]
    )
    var out = _eval_column_expr(Expr.binary(BIN_ADD, _col("a"), _col("b")), batch)
    var arr = out.as_primitive[DType.int64]()
    assert_true(arr.is_null(0), "NULL + 1 is NULL (payload MAX)")
    assert_false(arr.is_null(1))
    assert_equal(Int(arr.get(1)), 12)
    assert_true(arr.is_null(2), "-7 + NULL is NULL (payload MIN)")
    var outs = _eval_column_expr(Expr.binary(BIN_MUL, _col("a"), _lit(2)), batch)
    assert_true(outs.as_primitive[DType.int64]().is_null(0), "NULL * 2 is NULL")


def test_a_VALID_overflow_beside_a_NULL_one_still_raises() raises:
    var batch = _ab_batch(
        [I64_MAX, I64_MAX], [0], [Int64(1), Int64(2)], []
    )
    _assert_raises_exactly(
        Expr.binary(BIN_ADD, _col("a"), _col("b")),
        batch,
        "Overflow in addition of INT64 (9223372036854775807 + 2)!",
    )


# =============================================================================
# §5 THE SIMD BODY — 1000 rows, the overflow deep inside
# =============================================================================


def test_overflow_in_the_vector_body_names_that_rows_operands() raises:
    var a = List[Int64](capacity=1000)
    var b = List[Int64](capacity=1000)
    for i in range(1000):
        a.append(Int64(i))
        b.append(Int64(1000 - i))
    a[777] = I64_MAX - 5
    b[777] = Int64(6)
    var batch = _ab_batch(a, [], b, [])
    _assert_raises_exactly(
        Expr.binary(BIN_ADD, _col("a"), _col("b")),
        batch,
        "Overflow in addition of INT64 (9223372036854775802 + 6)!",
    )
    # the same column with row 777 in range answers every row
    b[777] = Int64(5)
    var ok = _eval_column_expr(
        Expr.binary(BIN_ADD, _col("a"), _col("b")), _ab_batch(a, [], b, [])
    )
    var arr = ok.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(777)), Int(I64_MAX))
    assert_equal(Int(arr.get(0)), 1000)
    assert_equal(Int(arr.get(999)), 1000)


# =============================================================================
# §6 EVERY WIDTH, through the kernels
# =============================================================================


def _kernel_raise[dt: DType](l: List[Scalar[dt]], r: List[Scalar[dt]], op: Int) -> String:
    try:
        var la = PrimitiveArray[dt].from_list(l)
        var ra = PrimitiveArray[dt].from_list(r)
        if op == 0:
            _ = eval_add[dt](la, ra)
        elif op == 1:
            _ = eval_sub[dt](la, ra)
        else:
            _ = eval_mul[dt](la, ra)
    except err:
        return String(err)
    return String("")


def test_every_width_raises_with_its_own_type_name() raises:
    var u = _kernel_raise[DType.uint64]([UInt64(18446744073709551615)], [UInt64(1)], 0)
    assert_true(u.find("Overflow in addition of UINT64 (18446744073709551615 + 1)!") >= 0, u)
    var us = _kernel_raise[DType.uint64]([UInt64(0)], [UInt64(1)], 1)
    assert_true(us.find("Overflow in subtraction of UINT64 (0 - 1)!") >= 0, us)
    var um = _kernel_raise[DType.uint32]([UInt32(4294967295)], [UInt32(2)], 2)
    assert_true(um.find("Overflow in multiplication of UINT32 (4294967295 * 2)!") >= 0, um)
    var i8 = _kernel_raise[DType.int8]([Int8(127)], [Int8(1)], 0)
    assert_true(i8.find("Overflow in addition of INT8 (127 + 1)!") >= 0, i8)
    var i16 = _kernel_raise[DType.int16]([Int16(32767)], [Int16(2)], 2)
    assert_true(i16.find("Overflow in multiplication of INT16 (32767 * 2)!") >= 0, i16)
    var i32m = _kernel_raise[DType.int32]([Int32(-2147483648)], [Int32(-1)], 2)
    assert_true(i32m.find("Overflow in multiplication of INT32 (-2147483648 * -1)!") >= 0, i32m)
    # controls: the same widths at their bounds, in range
    assert_equal(_kernel_raise[DType.uint64]([UInt64(18446744073709551614)], [UInt64(1)], 0), "")
    assert_equal(_kernel_raise[DType.int8]([Int8(-64)], [Int8(2)], 2), "")
    assert_equal(_kernel_raise[DType.int16]([Int16(-32768)], [Int16(1)], 2), "")
    assert_equal(_kernel_raise[DType.uint32]([UInt32(65536)], [UInt32(65535)], 2), "")


def test_scalar_kernels_raise() raises:
    var col = PrimitiveArray[DType.int64].from_list([Scalar[DType.int64](I64_MAX)])
    var t1 = String("")
    try:
        _ = eval_add_scalar[DType.int64](col, Scalar[DType.int64](1))
    except err:
        t1 = String(err)
    assert_true(t1.find("(9223372036854775807 + 1)!") >= 0, t1)
    var t2 = String("")
    try:
        _ = eval_mul_scalar[DType.int64](col, Scalar[DType.int64](-2))
    except err:
        t2 = String(err)
    assert_true(t2.find("(9223372036854775807 * -2)!") >= 0, t2)


# =============================================================================
# §7 FLOAT — `%` is fmod, and `+ - *` never raise
# =============================================================================


def test_float_mod_is_fmod_bit_for_bit() raises:
    """DuckDB 1.5.3 (`numeric_domain_oracle.tsv` f64_mod@k3 / @k9, and a
    156-pair grid measured against C fmod): -0.0 % 1.0 = -0.0,
    DBL_MAX % 10.0 = 8.0, -17 % 5 = -2, 17 % -5 = 2, 5.5 % 0 = NaN,
    5.0 % inf = 5.0."""
    # ⚠ Mojo's `Float64.MAX` IS +inf; the largest FINITE double is MAX_FINITE.
    var inf = Float64.MAX
    var batch = _f64_batch(
        [Float64(-0.0), Float64.MAX_FINITE, Float64(-17.0), Float64(17.0), Float64(5.5), Float64(5.0)],
        [Float64(1.0), Float64(10.0), Float64(5.0), Float64(-5.0), Float64(0.0), inf],
    )
    var out = _eval_column_expr(Expr.binary(BIN_MOD, _col("x"), _col("y")), batch)
    var arr = out.as_primitive[DType.float64]()
    assert_equal(_bits(Float64(arr.get(0))), _bits(Float64(-0.0)), "-0.0 % 1.0 keeps the sign")
    assert_equal(Float64(arr.get(1)), Float64(8.0), "DBL_MAX % 10.0 = 8.0")
    assert_equal(Float64(arr.get(2)), Float64(-2.0))
    assert_equal(Float64(arr.get(3)), Float64(2.0))
    assert_true(Float64(arr.get(4)) != Float64(arr.get(4)), "x % 0.0 is NaN")
    assert_equal(Float64(arr.get(5)), Float64(5.0), "5 % inf = 5 (the identity answered NaN)")
    # the col-vs-LITERAL twin
    var lit = _eval_column_expr(
        Expr.binary(BIN_MOD, _col("x"), Expr.literal(ScalarValue.from_float(10.0))),
        batch,
    )
    var la = lit.as_primitive[DType.float64]()
    assert_equal(_bits(Float64(la.get(0))), _bits(Float64(-0.0)))
    assert_equal(Float64(la.get(1)), Float64(8.0))


def test_float_arithmetic_never_raises() raises:
    var batch = _f64_batch([Float64.MAX_FINITE], [Float64.MAX_FINITE])
    var out = _eval_column_expr(Expr.binary(BIN_ADD, _col("x"), _col("y")), batch)
    var v = Float64(out.as_primitive[DType.float64]().get(0))
    assert_true(v > Float64.MAX_FINITE, "DBL_MAX + DBL_MAX is +inf, an ANSWER")


def test_float_literal_minus_col_is_positive_zero() raises:
    """`1.0 - x` over 1.0 is +0.0 (the old `-(x - 1.0)` answered -0.0)."""
    var batch = _f64_batch([Float64(1.0)], [Float64(0.0)])
    var out = _eval_column_expr(
        Expr.binary(BIN_SUB, Expr.literal(ScalarValue.from_float(1.0)), _col("x")),
        batch,
    )
    assert_equal(_bits(Float64(out.as_primitive[DType.float64]().get(0))), UInt64(0))


# =============================================================================
# §8 CASE — an arm answers only its own rows
# =============================================================================


def _case1(var cond: Expr, var then_e: Expr, var else_e: Expr) -> Expr:
    var cases = List[WhenCaseData]()
    cases.append(WhenCaseData(cond^, then_e^))
    return Expr.when(cases^, else_e^)


def _a_lt_100() -> Expr:
    return Expr.binary(BIN_LT, _col("a"), _lit(100))


def test_case_then_arm_overflow_on_an_EXCLUDED_row_answers() raises:
    """The binary-CASE fast path: row 0 (a = MAX) is excluded by `a < 100`."""
    var batch = _ab_batch([I64_MAX, Int64(5)], [], [Int64(1), Int64(7)], [])
    var out = _eval_column_expr(
        _case1(_a_lt_100(), Expr.binary(BIN_ADD, _col("a"), _col("b")), _lit(0)), batch
    )
    var arr = out.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(0)), 0, "the ELSE row")
    assert_equal(Int(arr.get(1)), 12, "5 + 7")


def test_case_else_arm_overflow_on_an_EXCLUDED_row_answers() raises:
    """The ELSE arm: `CASE WHEN a > 100 THEN 0 ELSE a * 2 END` — the MAX row is
    claimed by the WHEN, so `MAX * 2` is never asked."""
    var batch = _ab_batch([I64_MAX, Int64(5)], [], [Int64(1), Int64(7)], [])
    var out = _eval_column_expr(
        _case1(
            Expr.binary(BIN_GT, _col("a"), _lit(100)),
            _lit(0),
            Expr.binary(BIN_MUL, _col("a"), _lit(2)),
        ),
        batch,
    )
    var arr = out.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(0)), 0)
    assert_equal(Int(arr.get(1)), 10)


def test_case_overflow_on_a_row_the_arm_ANSWERS_still_raises() raises:
    var batch = _ab_batch([I64_MAX, Int64(5)], [], [Int64(1), Int64(7)], [])
    _assert_raises_exactly(
        _case1(
            Expr.binary(BIN_GT, _col("a"), _lit(0)),
            Expr.binary(BIN_ADD, _col("a"), _col("b")),
            _lit(0),
        ),
        batch,
        "Overflow in addition of INT64 (9223372036854775807 + 1)!",
    )


def test_multi_case_overlay_arms_answer_only_their_rows() raises:
    """Two WHENs (the overlay path, not the binary fast path), and EACH arm
    overflows on a row the OTHER arm answers:

        a     b    WHEN#1 a > 100 -> a + b     WHEN#2 a < 100 -> a - b
        MAX   -1   MAX - 1  (answered)         MAX + 1  (overflow, not asked)
        5      7   12       (not asked)        -2       (answered)
        MIN   -1   MIN - 1  (overflow, not asked)  MIN + 1  (answered)
    """
    var batch = _ab_batch(
        [I64_MAX, Int64(5), I64_MIN], [], [Int64(-1), Int64(7), Int64(-1)], []
    )
    var cases = List[WhenCaseData]()
    cases.append(
        WhenCaseData(
            Expr.binary(BIN_GT, _col("a"), _lit(100)),
            Expr.binary(BIN_ADD, _col("a"), _col("b")),
        )
    )
    cases.append(
        WhenCaseData(_a_lt_100(), Expr.binary(BIN_SUB, _col("a"), _col("b")))
    )
    var out = _eval_column_expr(Expr.when(cases^, _lit(0)), batch)
    var arr = out.as_primitive[DType.int64]()
    assert_equal(Int(arr.get(0)), 9223372036854775806, "MAX + -1 (WHEN#1)")
    assert_equal(Int(arr.get(1)), -2, "5 - 7 (WHEN#2)")
    assert_equal(Int(arr.get(2)), -9223372036854775807, "MIN - -1 (WHEN#2)")


# =============================================================================
# §9 AND / OR — the right side answers only the undecided rows
# =============================================================================


def _ab3() raises -> RecordBatch:
    """a = [MAX, 5, -7], b = [1, 7, 3]: `a + b` overflows ONLY on row 0."""
    return _ab_batch([I64_MAX, Int64(5), Int64(-7)], [], [Int64(1), Int64(7), Int64(3)], [])


def _a_plus_b_gt0() -> Expr:
    return Expr.binary(BIN_GT, Expr.binary(BIN_ADD, _col("a"), _col("b")), _lit(0))


def test_and_right_side_skips_the_rows_left_rejected() raises:
    var m = _eval_predicate(Expr.binary(BIN_AND, _a_lt_100(), _a_plus_b_gt0()), _ab3())
    assert_false(m.get(0), "MAX: a < 100 is FALSE, so a + b is never asked")
    assert_true(m.get(1), "5 + 7 > 0")
    assert_false(m.get(2), "-7 + 3 > 0 is FALSE")


def test_or_right_side_skips_the_rows_left_accepted() raises:
    var m = _eval_predicate(
        Expr.binary(BIN_OR, Expr.binary(BIN_GT, _col("a"), _lit(100)), _a_plus_b_gt0()),
        _ab3(),
    )
    assert_true(m.get(0), "MAX: a > 100 is TRUE, so a + b is never asked")
    assert_true(m.get(1))
    assert_false(m.get(2))


def test_and_right_side_overflow_on_an_UNDECIDED_row_still_raises() raises:
    var text = String("")
    try:
        _ = _eval_predicate(
            Expr.binary(BIN_AND, Expr.binary(BIN_GT, _col("a"), _lit(0)), _a_plus_b_gt0()),
            _ab3(),
        )
    except err:
        text = String(err)
    assert_true(
        text.find("Overflow in addition of INT64 (9223372036854775807 + 1)!") >= 0,
        String("a > 0 selects MAX, so MAX + 1 is asked and raises; got `") + text + "`",
    )


def test_filter_funnel_and_nested_under_or_is_lazy_too() raises:
    """`(a < 100 AND a + b > 0) OR a = -7` through `evaluate_filter_narrowed`:
    the top-level OR is not a flattened conjunction, so the AND inside it runs
    in the three-valued descent (`_predicate_3vl`)."""
    var pred = Expr.binary(
        BIN_OR,
        Expr.binary(BIN_AND, _a_lt_100(), _a_plus_b_gt0()),
        Expr.binary(BIN_EQ, _col("a"), _lit(-7)),
    )
    var sel = evaluate_filter_narrowed(_ab3(), pred)
    assert_equal(sel.length(), 2, "rows 1 and 2 survive")


# ---------------------------------------------------------------------------
# ★ EACH EXTREME, PINNED ALONE. The col-vs-literal
# kernel checks the column's MIN and MAX after the loop (`_int_arith_cs`). Every
# single-row test above has cmin == cmax, so a kernel that checked only ONE
# extreme passed all of them except the negation cell. Here the overflowing
# value sits at one extreme and an in-range value at the other.
# ---------------------------------------------------------------------------


def test_col_minus_literal_overflow_at_the_column_min_with_a_benign_max() raises:
    var batch = _ab_batch([Int64(5), I64_MIN], [], [Int64(0), Int64(0)], [])
    _assert_raises_exactly(
        Expr.binary(BIN_SUB, _col("a"), _lit(1)),
        batch,
        "Overflow in subtraction of INT64 (-9223372036854775808 - 1)!",
    )


def test_col_plus_literal_overflow_at_the_column_max_with_a_benign_min() raises:
    var batch = _ab_batch([Int64(-5), I64_MAX], [], [Int64(0), Int64(0)], [])
    _assert_raises_exactly(
        Expr.binary(BIN_ADD, _col("a"), _lit(1)),
        batch,
        "Overflow in addition of INT64 (9223372036854775807 + 1)!",
    )


def test_literal_minus_col_overflow_at_the_column_min_with_a_benign_max() raises:
    var batch = _ab_batch([Int64(5), I64_MIN], [], [Int64(0), Int64(0)], [])
    _assert_raises_exactly(
        Expr.binary(BIN_SUB, _lit(0), _col("a")),
        batch,
        "Overflow in subtraction of INT64 (0 - -9223372036854775808)!",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
