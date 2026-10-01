"""INTEGER DIVIDE/MODULO BY ZERO MUST NOT KILL THE PROCESS.

★ THE DEFECT, MEASURED OUT OF PROCESS BEFORE THIS FILE EXISTED.
`=qty / 0` typed into the sheet formula bar lowers cleanly (`/` is in
sheetFormulaIvp's BIN table, `0` is an int64 literal), reaches the engine's
projection kernel, and on the farm's x86-64 executor the `idiv` instruction
raises #DE -> SIGFPE. The process DIES. That is availability, not a wrong
answer: one keystroke from any of the four authoring surfaces takes down a
shared engine.

⚠ THE FAILURE IS ARCHITECTURE-DEPENDENT, WHICH IS WHY IT MUST BE MEASURED ON
THE FARM AND NOT ON A DEVELOPER MAC. ARM64 `sdiv` by zero does NOT trap -- it
returns 0. So the SAME source produces:
    x86-64 (the farm, and every Linux deployment)  -> SIGFPE, process kill
    arm64  (a developer's mac)                     -> silent 0, wrong answer
Both are defects and this file asserts against BOTH: the process surviving is
necessary but NOT sufficient, so every case grades the VALUE and the VALIDITY,
never merely "it did not crash". A test that only checked for the absence of a
signal would pass on arm64 today, against the unfixed engine.

============================ THE ORACLE, MEASURED ============================
DuckDB v1.5.3:

    create table t(qty BIGINT, z BIGINT);
    insert into t values (10,0),(20,0),(-30,0),(0,0);
    select qty, qty/z, qty//z, qty%z from t;

    qty | qty/z (DOUBLE) | qty//z (BIGINT) | qty%z (BIGINT)
     10 |            inf |            NULL |           NULL
     20 |            inf |            NULL |           NULL
    -30 |           -inf |            NULL |           NULL
      0 |            nan |            NULL |           NULL

So the oracle's answer for INTEGER division and modulo by a zero divisor is
NULL, per row, with the other rows unaffected. That is what this file asserts.

⚠ ONE ORACLE DIVERGENCE IS DELIBERATELY *NOT* CLOSED HERE, AND IS RECORDED SO
IT IS NOT MISTAKEN FOR AGREEMENT: DuckDB's `/` on two BIGINTs returns DOUBLE
(`7/2` = 3.5), while this engine's BIN_DIV on I64 returns I64 (`7/2` = 3).
Changing the RESULT TYPE of `/` is a separate, much wider change (it moves
every TPC-H expression's type) and is NOT in this fix's scope. What is closed
here is that the INTEGER division this engine does perform is total -- it
answers NULL where the divisor is zero instead of trapping. `test_div_
truncates_toward_zero_control` below PINS the divergence so a future author
who changes it must come here and say so.

=========================== WHAT EACH CASE CATCHES ===========================
The cases are organised so that no single wrong fix passes them all:

  * ZERO DIVISOR      -> NULL. The headline.
  * NON-ZERO DIVISOR  -> the arithmetic answer, still VALID. This is the
                         load-bearing control in the other direction: a "fix"
                         that returns NULL for every row, or that nulls the
                         whole column when any row divides by zero, satisfies
                         every zero-divisor assertion above and silently
                         deletes working queries.
  * MIXED column      -> per-ROW nulling, asserted position by position. A
                         whole-column fallback passes a mixed test that only
                         counts nulls.
  * NEGATIVE dividend -> the sign is not what makes it safe.
  * ZERO dividend     -> `0 / 0` is a zero divisor like any other; it is NOT
                         "0, so fine".
  * PRE-EXISTING NULL -> a row already null must STAY null, and must not be
                         resurrected as a value by a validity mask that is
                         overwritten rather than merged. That exact overwrite
                         is what `clone_array_validity` does at the call site.
  * FLOAT             -> IEEE 754 already gives +-inf / nan and already never
                         traps, and DuckDB agrees. Float must be left ALONE:
                         these cases fail if the integer fix leaks into the
                         float path and starts nulling infinities.
  * INT32 as well as INT64 -- because the property is "an INTEGRAL dtype has
                         no answer for a zero divisor", not "int64 division is
                         special". A guard written for one width leaves the
                         other trapping.
  * MODULO             -> ★ THE TRIPWIRE FIRED, EXACTLY AS
                         DESIGNED. The previous revision of this bullet said
                         `%` "does not reach an integer kernel on this route
                         at all" -- `_eval_binary_col_scalar` implemented
                         ADD/SUB/MUL/DIV and `qty % 0` raised "unsupported
                         int64 scalar binary op: 4", issuing no `idiv` -- and
                         it was recorded WITH a `% 5` control precisely so
                         that the day somebody implemented modulo this file
                         would go RED rather than a fresh trap shipping.
                         `BIN_MOD` now HAS a projection arm, built on
                         `eval_div` so that the zero-divisor guard is
                         inherited rather than re-derived, and the case below
                         asserts the VALUES instead of the refusal. See its
                         docstring for why `% 3` and not `% 5`.
"""

from std.testing import assert_true, assert_false, assert_equal

from komira_core.arrow import PrimitiveArray
from komira_core.arrow.schema import (
    Schema, SchemaBuilder, Field, RecordBatch, RecordBatchBuilder,
)
from komira_core.arrow.column import Column
from komira_core.arrow.arrow_types import ArrowType
from komira_core.plan.expr import Expr, BIN_DIV, BIN_MOD
from komira_core.plan.col_expr import col
from komira_core.plan.scalar_value import ScalarValue
from komira_core.eval.arithmetic import eval_div, eval_div_scalar
from komira_compiler.compiler_eval_column import _eval_column_expr
from komira_eval.expr_interpreter import (
    interpret_expr,
    RowContext,
    EVAL_KIND_NULL,
    EVAL_KIND_INT,
    EVAL_KIND_FLOAT,
)


# =============================================================================
# Helpers
# =============================================================================


def _i64_arr(vals: List[Int64]) raises -> PrimitiveArray[DType.int64]:
    var out: List[Scalar[DType.int64]] = []
    for i in range(len(vals)):
        out.append(Scalar[DType.int64](vals[i]))
    return PrimitiveArray[DType.int64].from_list(out)


def _i32_arr(vals: List[Int32]) raises -> PrimitiveArray[DType.int32]:
    var out: List[Scalar[DType.int32]] = []
    for i in range(len(vals)):
        out.append(Scalar[DType.int32](vals[i]))
    return PrimitiveArray[DType.int32].from_list(out)


def _f64_arr(vals: List[Float64]) raises -> PrimitiveArray[DType.float64]:
    var out: List[Scalar[DType.float64]] = []
    for i in range(len(vals)):
        out.append(Scalar[DType.float64](vals[i]))
    return PrimitiveArray[DType.float64].from_list(out)


def _int64_batch(name: String, vals: List[Int64]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    var rbb = RecordBatchBuilder()
    sb.add_field(Field(name, ArrowType.INT64, True))
    rbb.add_column(Column.from_primitive[DType.int64](_i64_arr(vals)))
    return rbb.build(sb.build())


# =============================================================================
# 1. THE HEADLINE -- the plan route, which is what `=qty / 0` actually reaches.
#
# `_eval_column_expr` is the engine's OP_PROJECT evaluator. It is called from
# `komira_engine_operators/map_op.mojo`, `.../unified/op_chain_adapter.mojo`
# and `komira_engine_dispatch/streaming_ops.mojo`, so this is the route a
# serialized plan's PROJECT node takes -- not a kernel reached only in theory.
# =============================================================================


def test_plan_route_project_qty_div_zero_is_null_not_a_crash() raises:
    """`col("qty") / 0` through the PROJECT evaluator. THE REPRODUCTION.

    Pre-fix on x86-64 this call never returns: SIGFPE inside
    `eval_div_scalar[int64]`. Pre-fix on arm64 it returns 0 for every row.
    Post-fix every row is NULL.
    """
    var batch = _int64_batch("qty", [Int64(10), Int64(-20), Int64(0)])
    var e = Expr.binary(
        BIN_DIV,
        Expr.col_ref("qty"),
        Expr.literal(ScalarValue.from_int(0)),
    )
    var out = _eval_column_expr(e, batch)
    assert_equal(out.length(), 3)
    var arr = out.as_primitive[DType.int64]()
    assert_true(arr.is_null(0), "10 / 0 must be NULL")
    assert_true(arr.is_null(1), "-20 / 0 must be NULL")
    assert_true(arr.is_null(2), "0 / 0 must be NULL")


def test_mojo_dataframe_surface_col_div_zero_is_null() raises:
    """THE SAME DEFECT REACHED THROUGH THE MOJO DATAFRAME OPERATOR, not a
    hand-built Expr.

    BLAST RADIUS. Four authoring surfaces converge on ONE evaluator, so this
    was never an Excel bug:

      Excel   the formula BIN table maps `/` -> BIN_DIV
      Mojo DF `ColExpr.__floordiv__(Int)` -> Expr.binary(BIN_DIV, ..., literal)
              -- EXECUTED HERE, through the operator itself. (Until
              this was `__truediv__`; `/` is TRUE division now,
              `CAST(qty AS DOUBLE) / 0` = +-inf / NaN as in DuckDB, and `//`
              is the integer division that reaches this kernel.)
      SQL     `sql_binder._map_binop`: SXOP_DIV -> BIN_DIV
      Python  the plan route is the default; its wire BIN_DIV decodes to the
              same Expr

    and all four land in `_eval_column_expr`. Using `col("qty") // 0` rather
    than `Expr.binary(BIN_DIV, ...)` is the point: it proves the surface's own
    operator produces the shape that crashed, instead of asserting it from a
    reading of `col_expr.mojo`.
    """
    var batch = _int64_batch("qty", [Int64(10), Int64(-20), Int64(0)])
    var e = (col("qty") // 0).copy_expr()
    var out = _eval_column_expr(e, batch)
    assert_equal(out.length(), 3)
    var arr = out.as_primitive[DType.int64]()
    assert_true(arr.is_null(0), "col('qty') // 0 must be NULL at row 0")
    assert_true(arr.is_null(1), "col('qty') // 0 must be NULL at row 1")
    assert_true(arr.is_null(2), "col('qty') // 0 must be NULL at row 2")


def test_mojo_dataframe_surface_truediv_is_duckdb_slash() raises:
    """`/` on the Mojo surface is DuckDB's TRUE division :
    `CAST(qty AS DOUBLE) / d`, so a zero divisor is IEEE, NOT the integer
    kernel's NULL. DuckDB v1.5.3, measured over BIGINT [10, -20, 0]:
    `qty / 4` = [2.5, -5.0, 0.0], `qty / 0` = [inf, -inf, nan] (DOUBLE).
    Until then `col("qty") / 4` answered [2, -5, 0] (int64)."""
    var batch = _int64_batch("qty", [Int64(10), Int64(-20), Int64(0)])
    var q = _eval_column_expr((col("qty") / 4).copy_expr(), batch)
    assert_true(q.arrow_type == ArrowType.FLOAT64, "qty / 4 is DOUBLE")
    var qa = q.as_primitive[DType.float64]()
    assert_equal(qa.get(0), 2.5)
    assert_equal(qa.get(1), -5.0)
    assert_equal(qa.get(2), 0.0)
    var z = _eval_column_expr((col("qty") / 0).copy_expr(), batch)
    var za = z.as_primitive[DType.float64]()
    assert_false(za.is_null(0), "qty / 0 is not NULL (that is `//`)")
    assert_true(za.get(0) > 1.0e308, "10 / 0 = +inf")
    assert_true(za.get(1) < -1.0e308, "-20 / 0 = -inf")
    assert_true(za.get(2) != za.get(2), "0 / 0 = nan")


def _mod_col(divisor: Int) raises -> PrimitiveArray[DType.int64]:
    """`col("qty") % <divisor>` through the PROJECT evaluator, as an array."""
    var batch = _int64_batch("qty", [Int64(10), Int64(-20), Int64(0)])
    var e = Expr.binary(
        BIN_MOD,
        Expr.col_ref("qty"),
        Expr.literal(ScalarValue.from_int(divisor)),
    )
    var out = _eval_column_expr(e, batch)
    return out.as_primitive[DType.int64]()


def test_plan_route_mod_by_zero_is_NULL_and_a_nonzero_divisor_computes() raises:
    """★ THE TRIPWIRE THIS FILE ARMED, NOW DISCHARGED.

    Its previous revision asserted that BOTH `% 0` and `% 5` RAISE
    "unsupported int64 scalar binary op: 4", with the nonzero divisor as a
    deliberate CONTROL so that "the zero divisor is handled" could never be
    read off a file that actually meant "modulo is not implemented here at
    all". `BIN_MOD` now has a projection arm, so the control went green, this
    case went red, and the obligation it recorded -- come back and prove the
    zero-divisor guard, do not ship a fresh trap -- is discharged HERE.

    ⛔ THE GUARD IS INHERITED, NOT RE-DERIVED. The arm computes
    `a - trunc(a/b)*b` out of `eval_div` / `eval_mul` / `eval_sub`, so the
    zero-divisor row is NULLed by the SAME `eval_div_scalar` code path the
    division cases above pin, and no second `idiv` site exists to guard. A
    hand-written `%` kernel is what would have needed its own guard.

    ⛔ `% 3`, NOT `% 5`, AND THAT IS THE DISCRIMINATOR. This fixture is
    [10, -20, 0]; every one of those is divisible by 5, so a `% 5` control
    answers [0, 0, 0] under EVERY convention and could not tell a correct
    implementation from a broken one. Over `% 3`:

        DuckDB v1.5.3 / C  (TRUNCATED, sign of the DIVIDEND) -> 1, **-2**, 0
        Python / Mojo `%`  (FLOOR-mod, sign of the DIVISOR)  -> 1, **+1**, 0

    Mojo's `%` is floor-mod (--
    `komira_eval/temporal_extract._dayofweek_from_days`), so row 1 is the row
    that says which rule the engine implements, and the naive spelling is the
    WRONG one by 3.
    """
    var by_zero = _mod_col(0)
    assert_equal(by_zero.length, 3)
    assert_true(by_zero.is_null(0), "10 % 0 must be NULL, not a trap")
    assert_true(by_zero.is_null(1), "-20 % 0 must be NULL, not a trap")
    assert_true(by_zero.is_null(2), "0 % 0 must be NULL, not a trap")

    var by_three = _mod_col(3)
    assert_equal(by_three.length, 3)
    assert_false(by_three.is_null(0), "10 % 3 is a value, not NULL")
    assert_false(by_three.is_null(1), "-20 % 3 is a value, not NULL")
    assert_false(by_three.is_null(2), "0 % 3 is a value, not NULL")
    assert_equal(by_three.get(0), Scalar[DType.int64](1), "10 % 3 == 1")
    assert_equal(
        by_three.get(1),
        Scalar[DType.int64](-2),
        "-20 % 3 == -2 (DuckDB v1.5.3, TRUNCATED). A floor-mod implementation"
        " -- which is what Mojo's own `%` operator gives -- answers +1 here,"
        " and this row is the only one in the fixture that can tell them"
        " apart",
    )
    assert_equal(by_three.get(2), Scalar[DType.int64](0), "0 % 3 == 0")


def test_plan_route_project_div_nonzero_still_computes() raises:
    """LOAD-BEARING CONTROL. A fix that refuses/nulls everything passes every
    assertion above and deletes every working division in the corpus."""
    var batch = _int64_batch("qty", [Int64(10), Int64(-20), Int64(7)])
    var e = Expr.binary(
        BIN_DIV,
        Expr.col_ref("qty"),
        Expr.literal(ScalarValue.from_int(2)),
    )
    var out = _eval_column_expr(e, batch)
    var arr = out.as_primitive[DType.int64]()
    assert_false(arr.is_null(0), "10 / 2 must stay VALID")
    assert_false(arr.is_null(1), "-20 / 2 must stay VALID")
    assert_false(arr.is_null(2), "7 / 2 must stay VALID")
    assert_equal(arr.get(0), Scalar[DType.int64](5))
    assert_equal(arr.get(1), Scalar[DType.int64](-10))


def test_div_truncates_toward_zero_control() raises:
    """PINS the one oracle divergence this fix deliberately does NOT close.

    DuckDB v1.5.3 `7::BIGINT / 2::BIGINT` is DOUBLE 3.5. This engine's
    BIN_DIV on I64 is truncating integer division -> 3. Changing that is a
    result-TYPE change across every arithmetic expression in the corpus and
    is out of scope for a crash fix. If a future author closes it, this
    assertion goes red and they must update the divergence note in this
    file's header rather than discovering it in a benchmark.
    """
    var batch = _int64_batch("qty", [Int64(7)])
    var e = Expr.binary(
        BIN_DIV, Expr.col_ref("qty"), Expr.literal(ScalarValue.from_int(2))
    )
    var out = _eval_column_expr(e, batch)
    var arr = out.as_primitive[DType.int64]()
    assert_equal(arr.get(0), Scalar[DType.int64](3))


# =============================================================================
# 2. THE KERNELS -- column/scalar and column/column, INT64 and INT32.
#
# The property being asserted is "an INTEGRAL dtype has no answer for a zero
# divisor", so it is asserted on more than one integral dtype. A guard written
# for int64 alone leaves int32 trapping, and int32 is reachable: a plan whose
# scan schema declares INT32 lands in `_eval_binary_col_scalar`'s INT32 arm.
# =============================================================================


def test_eval_div_scalar_i64_zero_scalar_all_null() raises:
    var arr = _i64_arr([Int64(10), Int64(-20), Int64(0), Int64(9223372036854775807)])
    var res = eval_div_scalar[DType.int64](arr, Scalar[DType.int64](0))
    assert_equal(res.length, 4)
    for i in range(4):
        assert_true(res.is_null(i), "every row / 0 must be NULL")


def test_eval_div_scalar_i32_zero_scalar_all_null() raises:
    var arr = _i32_arr([Int32(10), Int32(-20), Int32(0)])
    var res = eval_div_scalar[DType.int32](arr, Scalar[DType.int32](0))
    assert_equal(res.length, 3)
    for i in range(3):
        assert_true(res.is_null(i), "every int32 row / 0 must be NULL")


def test_eval_div_scalar_i64_nonzero_scalar_no_nulls() raises:
    """CONTROL in the other direction, at the kernel level."""
    var arr = _i64_arr([Int64(10), Int64(-20), Int64(0)])
    var res = eval_div_scalar[DType.int64](arr, Scalar[DType.int64](5))
    assert_equal(res.null_count, 0)
    assert_equal(res.get(0), Scalar[DType.int64](2))
    assert_equal(res.get(1), Scalar[DType.int64](-4))
    assert_equal(res.get(2), Scalar[DType.int64](0))


def test_eval_div_colcol_i64_mixed_divisor_nulls_only_zero_rows() raises:
    """PER-ROW, asserted position by position.

    A whole-column fallback ("if any divisor is zero, null the column") passes
    a test that only counts nulls, and is wrong: rows 0, 2 and 4 have perfectly
    good answers. This is the case that separates a real mask from a bail-out.
    """
    var left = _i64_arr([Int64(10), Int64(20), Int64(-30), Int64(40), Int64(0)])
    var right = _i64_arr([Int64(2), Int64(0), Int64(3), Int64(0), Int64(5)])
    var res = eval_div[DType.int64](left, right)
    assert_equal(res.length, 5)
    assert_false(res.is_null(0), "10 / 2 is 5, not NULL")
    assert_true(res.is_null(1), "20 / 0 must be NULL")
    assert_false(res.is_null(2), "-30 / 3 is -10, not NULL")
    assert_true(res.is_null(3), "40 / 0 must be NULL")
    assert_false(res.is_null(4), "0 / 5 is 0, not NULL")
    assert_equal(res.get(0), Scalar[DType.int64](5))
    assert_equal(res.get(2), Scalar[DType.int64](-10))
    assert_equal(res.get(4), Scalar[DType.int64](0))
    assert_equal(res.null_count, 2)


def test_eval_div_colcol_i64_no_zero_divisor_is_untouched() raises:
    """CONTROL: with no zero divisor anywhere the result must carry NO
    validity bitmap at all -- the guard must not manufacture a null mask on
    every division in the engine."""
    var left = _i64_arr([Int64(10), Int64(20), Int64(-30)])
    var right = _i64_arr([Int64(2), Int64(4), Int64(3)])
    var res = eval_div[DType.int64](left, right)
    assert_equal(res.null_count, 0)
    assert_equal(res.get(0), Scalar[DType.int64](5))
    assert_equal(res.get(1), Scalar[DType.int64](5))
    assert_equal(res.get(2), Scalar[DType.int64](-10))


# =============================================================================
# 3. FLOAT MUST BE LEFT ALONE.
#
# IEEE 754 division by zero is already total and already agrees with DuckDB
# v1.5.3 (inf / -inf / nan). These cases go RED if the integer guard leaks
# into the float path and starts nulling infinities -- which would be a
# regression introduced BY the fix, in a shape nobody would think to check.
# =============================================================================


def test_float64_div_by_zero_keeps_ieee_semantics_not_null() raises:
    var arr = _f64_arr([Float64(10.0), Float64(-20.0), Float64(0.0)])
    var res = eval_div_scalar[DType.float64](arr, Scalar[DType.float64](0.0))
    assert_equal(res.null_count, 0)
    var a = Float64(res.get(0))
    var b = Float64(res.get(1))
    var c = Float64(res.get(2))
    assert_true(a > Float64(1.0e300), "10.0 / 0.0 must be +inf, per DuckDB")
    assert_true(b < Float64(-1.0e300), "-20.0 / 0.0 must be -inf, per DuckDB")
    assert_true(c != c, "0.0 / 0.0 must be NaN, per DuckDB")


def test_float64_div_colcol_by_zero_keeps_ieee_semantics() raises:
    var left = _f64_arr([Float64(10.0), Float64(-20.0), Float64(0.0)])
    var right = _f64_arr([Float64(0.0), Float64(0.0), Float64(0.0)])
    var res = eval_div[DType.float64](left, right)
    assert_equal(res.null_count, 0)
    assert_true(Float64(res.get(0)) > Float64(1.0e300))
    assert_true(Float64(res.get(1)) < Float64(-1.0e300))
    var c = Float64(res.get(2))
    assert_true(c != c, "0.0 / 0.0 must be NaN")


# =============================================================================
# 4. PRE-EXISTING NULLS MUST SURVIVE.
#
# `_eval_binary_col_scalar` finishes with `clone_array_validity(arr, result)`,
# which OVERWRITES the result's validity with the input's. A guard that writes
# its zero-divisor mask into the result and then lets that call overwrite it
# produces a column that is valid everywhere -- the fix silently undone by the
# line after it. This case is what makes that visible.
# =============================================================================


def _int64_batch_with_null_at(name: String, vals: List[Int64], null_idx: Int) raises -> RecordBatch:
    var sb = SchemaBuilder()
    var rbb = RecordBatchBuilder()
    var arr = PrimitiveArray[DType.int64].allocate_nullable(len(vals))
    for i in range(len(vals)):
        arr.set(i, Scalar[DType.int64](vals[i]))
    arr._set_null(null_idx)
    sb.add_field(Field(name, ArrowType.INT64, True))
    rbb.add_column(Column.from_primitive[DType.int64](arr^))
    return rbb.build(sb.build())


def test_preexisting_null_survives_div_by_zero_guard() raises:
    """Row 1 is already NULL; rows 0 and 2 divide by zero. All three NULL."""
    var batch = _int64_batch_with_null_at(
        "qty", [Int64(10), Int64(20), Int64(30)], 1
    )
    var e = Expr.binary(
        BIN_DIV, Expr.col_ref("qty"), Expr.literal(ScalarValue.from_int(0))
    )
    var out = _eval_column_expr(e, batch)
    var arr = out.as_primitive[DType.int64]()
    assert_true(arr.is_null(0), "10 / 0 -> NULL")
    assert_true(arr.is_null(1), "already-NULL row stays NULL")
    assert_true(arr.is_null(2), "30 / 0 -> NULL")


def test_preexisting_null_survives_nonzero_div() raises:
    """The same shape with a SAFE divisor: the pre-existing null must still be
    the ONLY null. This is what proves the case above is not passing merely
    because everything became null."""
    var batch = _int64_batch_with_null_at(
        "qty", [Int64(10), Int64(20), Int64(30)], 1
    )
    var e = Expr.binary(
        BIN_DIV, Expr.col_ref("qty"), Expr.literal(ScalarValue.from_int(10))
    )
    var out = _eval_column_expr(e, batch)
    var arr = out.as_primitive[DType.int64]()
    assert_false(arr.is_null(0), "10 / 10 stays VALID")
    assert_true(arr.is_null(1), "already-NULL row stays NULL")
    assert_false(arr.is_null(2), "30 / 10 stays VALID")
    assert_equal(arr.get(0), Scalar[DType.int64](1))
    assert_equal(arr.get(2), Scalar[DType.int64](3))


# =============================================================================
# 4b. THE SAME QUESTION, ASKED OF THE **COLUMN / COLUMN** ROUTE.
#
# ★ SECTION 4's HEADER NAMES THE MECHANISM AND SECTION 4 ONLY CLOSED HALF OF
#   IT. It says `_eval_binary_col_scalar` finishes with `clone_array_validity`,
#   "which OVERWRITES the result's validity ... the fix silently undone by the
#   line after it". True -- and `_eval_binary_col_col`'s INT64 arm
#   (`compiler_eval_column.mojo:1556`) finishes with a DIFFERENT merger,
#   `merge_binary_arith_validity`, which did the IDENTICAL overwrite and was
#   not touched. A fix made in one of two copies is the shape this repo keeps
#   paying for -- see `streaming_concat.mojo`'s `field_at` note landed the same
#   day, where the sibling copy of a loop had carried the fix
#   and the original never got it.
#
# WHY NO EXISTING CASE CAUGHT IT: every case in sections 1-4 that goes through
# `_eval_column_expr` divides by an `Expr.literal` -- the col/SCALAR route. The
# only col/col cases (`test_eval_div_colcol_*`) call `eval_div` DIRECTLY at the
# kernel level, so they never reach the merger that discards its answer.
#
# ⚠ THE DISCRIMINATOR IS "AN OPERAND COLUMN ACTUALLY CONTAINS A NULL", AND
#   THAT WAS MEASURED, NOT ASSUMED. The first cut of this section built its
#   operands with `allocate_nullable` and set NO nulls, expecting the bitmap
#   alone to trip it. All four such cells PASSED on the farm against the
#   unfixed engine: a null-FREE nullable array does not surface a Column-level
#   `_validity`, so `merge_binary_arith_validity` takes its both-operands-clean
#   early return and the kernel's mask survives. The cells below therefore put
#   a REAL null in the operand, which is what selects each of the merger's
#   three arms. The null-free case is kept as an explicit control precisely
#   because it passes in both directions and would otherwise read as coverage.
#
# THE FAILURE IS CAMPAIGN REGIME 3 -- SILENT REPAIR. The merger clones or ANDs
# the operands' masks and ASSIGNS, throwing the zero-divisor NULLs away. The
# row then reads back VALID holding the allocated 0, i.e. `x / 0 == 0`, with no
# raise and no warning. DuckDB v1.5.3 answers NULL.
# =============================================================================


def _ab_batch(
    a_vals: List[Int64],
    a_nulls: List[Int],
    b_vals: List[Int64],
    b_nulls: List[Int],
) raises -> RecordBatch:
    """Two INT64 columns `a` and `b`, each optionally carrying REAL nulls.

    `*_nulls` empty means the column is built without a validity bitmap at
    all -- which is what selects `merge_binary_arith_validity`'s early return
    and is the property this section turns on."""
    var sb = SchemaBuilder()
    var rbb = RecordBatchBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.INT64, True))
    if len(a_nulls) == 0:
        rbb.add_column(Column.from_primitive[DType.int64](_i64_arr(a_vals)))
    else:
        var aa = PrimitiveArray[DType.int64].allocate_nullable(len(a_vals))
        for i in range(len(a_vals)):
            aa.set(i, Scalar[DType.int64](a_vals[i]))
        for j in range(len(a_nulls)):
            aa._set_null(a_nulls[j])
        rbb.add_column(Column.from_primitive[DType.int64](aa^))
    if len(b_nulls) == 0:
        rbb.add_column(Column.from_primitive[DType.int64](_i64_arr(b_vals)))
    else:
        var bb = PrimitiveArray[DType.int64].allocate_nullable(len(b_vals))
        for i in range(len(b_vals)):
            bb.set(i, Scalar[DType.int64](b_vals[i]))
        for j in range(len(b_nulls)):
            bb._set_null(b_nulls[j])
        rbb.add_column(Column.from_primitive[DType.int64](bb^))
    return rbb.build(sb.build())


def _div_ab(
    a_vals: List[Int64],
    a_nulls: List[Int],
    b_vals: List[Int64],
    b_nulls: List[Int],
) raises -> PrimitiveArray[DType.int64]:
    """`a / b` through the PROJECT evaluator — the col/COLUMN route."""
    var batch = _ab_batch(a_vals, a_nulls, b_vals, b_nulls)
    var e = Expr.binary(BIN_DIV, Expr.col_ref("a"), Expr.col_ref("b"))
    var out = _eval_column_expr(e, batch)
    return out.as_primitive[DType.int64]()


def test_plan_route_colcol_div_by_zero_when_the_DIVIDEND_holds_a_null() raises:
    """★ THE REPRODUCTION. `merge_binary_arith_validity`'s LEFT-ONLY arm.

    a = [NULL, 20, 30]   b = [5, 0, 3]  (b has no nulls, so left-only)
    Oracle, DuckDB v1.5.3 on the same values: NULL, NULL, 10.

    Pre-fix row 1 came back VALID holding 0 -- the kernel's divide-by-zero NULL
    cloned away by the operand mask. Graded position by position AND on
    null_count, so neither a whole-column bail-out nor a single-cell fix
    passes."""
    var arr = _div_ab(
        [Int64(10), Int64(20), Int64(30)], [0],
        [Int64(5), Int64(0), Int64(3)], [],
    )
    assert_true(arr.is_null(0), "a is NULL -> NULL (operand mask must survive)")
    assert_true(
        arr.is_null(1),
        "20 / 0 must be NULL. A VALID 0 here is the kernel's guard being"
        " overwritten by merge_binary_arith_validity's left-only arm",
    )
    assert_false(arr.is_null(2), "30 / 3 must stay VALID")
    assert_equal(arr.get(2), Scalar[DType.int64](10))
    assert_equal(arr.null_count, 2, "EXACTLY two nulls")


def test_plan_route_colcol_div_by_zero_when_the_DIVISOR_holds_a_null() raises:
    """The RIGHT-ONLY arm. Three arms are three separate code paths, so one
    assertion cannot stand for all of them.

    a = [10, 20, 30]   b = [NULL, 0, 3]   ->  NULL, NULL, 10"""
    var arr = _div_ab(
        [Int64(10), Int64(20), Int64(30)], [],
        [Int64(5), Int64(0), Int64(3)], [0],
    )
    assert_true(arr.is_null(0), "b is NULL -> NULL (operand mask must survive)")
    assert_true(arr.is_null(1), "20 / 0 must be NULL (right-only arm)")
    assert_false(arr.is_null(2), "30 / 3 must stay VALID")
    assert_equal(arr.get(2), Scalar[DType.int64](10))
    assert_equal(arr.null_count, 2, "EXACTLY two nulls")


def test_plan_route_colcol_div_by_zero_when_BOTH_operands_hold_nulls() raises:
    """The `bitmap_and` arm -- a third code path again.

    a = [NULL, 10, 20, 30]   b = [5, NULL, 0, 3]  ->  NULL, NULL, NULL, 10"""
    var arr = _div_ab(
        [Int64(10), Int64(10), Int64(20), Int64(30)], [0],
        [Int64(5), Int64(5), Int64(0), Int64(3)], [1],
    )
    assert_true(arr.is_null(0), "a is NULL -> NULL")
    assert_true(arr.is_null(1), "b is NULL -> NULL")
    assert_true(arr.is_null(2), "20 / 0 must be NULL (bitmap_and arm)")
    assert_false(arr.is_null(3), "30 / 3 must stay VALID")
    assert_equal(arr.get(3), Scalar[DType.int64](10))
    assert_equal(arr.null_count, 3, "EXACTLY three nulls")


def test_plan_route_colcol_div_by_zero_with_NO_operand_nulls_is_the_control() raises:
    """★ THE DISCRIMINATOR, AND IT PASSED BEFORE THE FIX TOO -- stated, not
    quietly counted as coverage.

    Neither operand carries a validity bitmap, so
    `merge_binary_arith_validity` early-returns and the kernel's mask is never
    touched. Keeping this beside the three cells above is what names the
    property as "an operand holds a NULL" rather than "col / col" -- without
    it a reader would conclude the whole col/col ROUTE was broken, which is
    the wrong repair."""
    var arr = _div_ab(
        [Int64(10), Int64(20), Int64(30)], [],
        [Int64(5), Int64(0), Int64(3)], [],
    )
    assert_false(arr.is_null(0), "10 / 5 stays VALID")
    assert_true(arr.is_null(1), "20 / 0 is NULL on the no-bitmap path already")
    assert_false(arr.is_null(2), "30 / 3 stays VALID")
    assert_equal(arr.null_count, 1, "EXACTLY one null")


def test_plan_route_colcol_operand_nulls_alone_still_propagate() raises:
    """★ MUST STILL WORK -- the direction a lazy fix deletes.

    `merge_binary_arith_validity` exists to make `a / b` NULL wherever EITHER
    operand is NULL. A fix that simply declined to write whenever the kernel
    had already established validity would keep the zero-divisor NULL and LOSE
    this one, trading a silent-wrong for a different silent-wrong. Divisor is
    CLEAN here, so the only nulls that may appear are the operands' own."""
    var arr = _div_ab(
        [Int64(10), Int64(20), Int64(30)], [0],
        [Int64(5), Int64(2), Int64(3)], [1],
    )
    assert_true(arr.is_null(0), "a is NULL -> NULL")
    assert_true(arr.is_null(1), "b is NULL -> NULL")
    assert_false(arr.is_null(2), "30 / 3 stays VALID")
    assert_equal(arr.get(2), Scalar[DType.int64](10))
    assert_equal(arr.null_count, 2, "EXACTLY two nulls -- no over-reach")


def test_plan_route_colcol_nullfree_clean_divisor_is_byte_identical() raises:
    """★ MUST STILL WORK -- the shape every real query has. No operand nulls,
    no zero divisor: every row valid, correct quotients, null_count 0. A fix
    that manufactured a null mask on this would be a capability deletion the
    zero-divisor assertions could not see."""
    var arr = _div_ab(
        [Int64(10), Int64(20), Int64(30)], [],
        [Int64(5), Int64(2), Int64(3)], [],
    )
    assert_equal(arr.null_count, 0, "a clean divisor must produce NO nulls")
    assert_equal(arr.get(0), Scalar[DType.int64](2))
    assert_equal(arr.get(1), Scalar[DType.int64](10))
    assert_equal(arr.get(2), Scalar[DType.int64](10))


def test_plan_route_colcol_float_div_by_zero_stays_IEEE() raises:
    """★ MUST STILL WORK -- the FLOAT col/col arm goes through the SAME merger.
    A merge that started intersecting a kernel mask into float results would
    turn `10.0 / 0.0` from `+inf` into NULL. One operand holds a real null so
    the merger takes a live arm rather than its early return; the OTHER rows
    must keep IEEE semantics."""
    var sb = SchemaBuilder()
    var rbb = RecordBatchBuilder()
    sb.add_field(Field("a", ArrowType.FLOAT64, True))
    sb.add_field(Field("b", ArrowType.FLOAT64, True))
    var aa = PrimitiveArray[DType.float64].allocate_nullable(3)
    aa.set(0, Scalar[DType.float64](1.0))
    aa.set(1, Scalar[DType.float64](10.0))
    aa.set(2, Scalar[DType.float64](-20.0))
    aa._set_null(0)
    rbb.add_column(Column.from_primitive[DType.float64](aa^))
    var bb = PrimitiveArray[DType.float64].allocate_nullable(3)
    bb.set(0, Scalar[DType.float64](1.0))
    bb.set(1, Scalar[DType.float64](0.0))
    bb.set(2, Scalar[DType.float64](0.0))
    rbb.add_column(Column.from_primitive[DType.float64](bb^))
    var batch = rbb.build(sb.build())
    var e = Expr.binary(BIN_DIV, Expr.col_ref("a"), Expr.col_ref("b"))
    var out = _eval_column_expr(e, batch)
    var arr = out.as_primitive[DType.float64]()
    assert_true(arr.is_null(0), "the operand NULL still propagates on FLOAT")
    assert_false(arr.is_null(1), "10.0 / 0.0 is +inf, not NULL")
    assert_false(arr.is_null(2), "-20.0 / 0.0 is -inf, not NULL")
    assert_equal(arr.null_count, 1, "float division stays total -- ONE null")


# =============================================================================
# 5. THE SCALAR INTERPRETER -- the OTHER integer-division site in the engine.
#
# ★ THIS IS A DIFFERENT DEFECT FROM THE ONE ABOVE, AND MEASURING IT IS WHAT
# REVEALED THE ACTUAL MECHANISM. These cases were written expecting a second
# SIGFPE. The farm returned `kind=1 int_val=0` instead -- probed, printed, and
# recorded here rather than assumed. `17 // 0` came back as INT **0**.
#
# THE DISCRIMINATOR IS THE OPERATOR, not the dtype and not the route:
#
#   `/`  (__truediv__) on an INTEGRAL SIMD -> raw hardware divide, NO guard
#                                             -> SIGFPE, process kill
#   `//` (__floordiv__) and `%`            -> Mojo's stdlib guards them
#                                             -> returns 0, NO trap
#
# `komira_core/eval/arithmetic.mojo` used `/` at both its division sites,
# which is why it took the process down; every `//`/`%` site in the engine
# quietly answered 0. Same expression, same dtype, same binary, same farm --
# only the operator differs. That A/B is the evidence for the root cause.
#
# So the engine had TWO defects in one kernel family: a process kill on `/`
# and a SILENT WRONG ANSWER on `//`/`%`. The second is the quieter and, per
# the easier one to score as "working":
# a probe looking for an exception marks it PASS. DuckDB v1.5.3 answers NULL.
#
# ⚠ REACHABILITY, MEASURED WITH A POSITIVE CONTROL. `interpret_expr` has ZERO
# production callers: `grep -rn` over `src/` returns only comments. The
# zero-hit is not trusted on its own -- the same grep over the template
# structs AND over `_match_expr_to_kernel_template` (optimizer_expr.mojo:1609)
# also returns zero, so the whole 3.b template/interpreter layer is dormant
# rather than merely un-grepped. This is therefore NOT user-typeable today and
# NOT what killed the process; it is fixed anyway because it costs two
# branches, and because a silent 0 that arms itself the day someone wires the
# interpreter is exactly how this class of defect gets found -- in production.
# =============================================================================


def test_interpreter_int_div_by_zero_is_null() raises:
    var e = Expr.binary(
        BIN_DIV,
        Expr.literal(ScalarValue.from_int64(17)),
        Expr.literal(ScalarValue.from_int64(0)),
    )
    var ctx = RowContext.empty()
    var r = interpret_expr(e, ctx)
    assert_equal(r.kind, EVAL_KIND_NULL, "17 / 0 must interpret to NULL")


def test_interpreter_int_mod_by_zero_is_null() raises:
    var e = Expr.binary(
        BIN_MOD,
        Expr.literal(ScalarValue.from_int64(17)),
        Expr.literal(ScalarValue.from_int64(0)),
    )
    var ctx = RowContext.empty()
    var r = interpret_expr(e, ctx)
    assert_equal(r.kind, EVAL_KIND_NULL, "17 % 0 must interpret to NULL")


def test_interpreter_int_div_mod_nonzero_still_computes() raises:
    """CONTROL. `17 / 5` = 3 and `17 % 5` = 2 must keep working and must NOT
    become NULL -- the same both-directions requirement as the column path."""
    var ctx = RowContext.empty()
    var d = interpret_expr(
        Expr.binary(
            BIN_DIV,
            Expr.literal(ScalarValue.from_int64(17)),
            Expr.literal(ScalarValue.from_int64(5)),
        ),
        ctx,
    )
    assert_equal(d.kind, EVAL_KIND_INT)
    assert_equal(d.int_val, 3)
    var m = interpret_expr(
        Expr.binary(
            BIN_MOD,
            Expr.literal(ScalarValue.from_int64(17)),
            Expr.literal(ScalarValue.from_int64(5)),
        ),
        ctx,
    )
    assert_equal(m.kind, EVAL_KIND_INT)
    assert_equal(m.int_val, 2)


def test_interpreter_float_div_by_zero_is_not_null() raises:
    """CONTROL: the interpreter's FLOAT arm must keep IEEE semantics. `1.0/0.0`
    is +inf, which is a VALUE -- if the integer guard leaked into the float
    arm this would come back NULL."""
    var e = Expr.binary(
        BIN_DIV,
        Expr.literal(ScalarValue.from_float(1.0)),
        Expr.literal(ScalarValue.from_float(0.0)),
    )
    var ctx = RowContext.empty()
    var r = interpret_expr(e, ctx)
    assert_equal(r.kind, EVAL_KIND_FLOAT, "float / 0.0 must stay a FLOAT value")
    assert_true(r.float_val > Float64(1.0e300), "1.0 / 0.0 must be +inf")


# =============================================================================
# 6. ★ A NARROWING CAST COULD MANUFACTURE A ZERO DIVISOR out of a divisor the
#    user never wrote. This section pins the REAL QUOTIENT.
#
# Truncating an INT64 literal outside int32 range to its low 32 bits, as
#
#     var scalar = Scalar[DType.int32](Int32(Int(sv.int_val)))
#
# would, turns `Int32(Int(4294967296))` into **0**. So on an INT32 column,
# `qty / 4294967296` -- an ordinary divisor, nowhere near zero -- would become
# a division by zero the user never typed: a PROCESS KILL without the div-guard,
# a SILENT NULL with it.
#
# `_eval_binary_col_scalar` asks `int_literal_fits[DType.int32]`
# (`komira_core/plan/literal_domain.mojo`) and PROMOTES the operation to INT64
# when the literal does not fit, instead of narrowing the literal to the
# column. So the divisor reaching the kernel is 4294967296, and the answer is
# the quotient.
#
# THE ORACLE:
#     select 40::INTEGER // 4294967296;          -> 0     (BIGINT)
#     select (-80)::INTEGER // 4294967296;       -> 0     (BIGINT)
#     select typeof(40::INTEGER // 4294967296);  -> BIGINT
# so both the VALUE and the promoted RESULT TYPE are asserted below. DuckDB's
# `/` on the same operands returns DOUBLE 9.313225746154785e-09 — the separate,
# deliberate result-type divergence pinned above; `//` is the column that
# describes the integer division this engine performs.
#
# ⛔ THE GUARD ITSELF IS UNTOUCHED, AND MUST STAY THAT WAY. A genuine `/ 0`
# still answers NULL (`test_int32_divisor_literal_zero_still_null` below is the
# control that keeps this section honest). Fixing the composition by relaxing
# the divide-by-zero guard would reopen a process kill; the fix belongs at the
# truncation.
# =============================================================================


def _int32_batch(name: String, vals: List[Int32]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    var rbb = RecordBatchBuilder()
    sb.add_field(Field(name, ArrowType.INT32, True))
    rbb.add_column(Column.from_primitive[DType.int32](_i32_arr(vals)))
    return rbb.build(sb.build())


def test_int32_divisor_truncated_to_zero_does_not_crash() raises:
    """`int32_col / 4294967296` — the divisor that USED to be zero only after
    narrowing. It no longer narrows, so this is now an ordinary division."""
    var batch = _int32_batch("qty", [Int32(40), Int32(-80)])
    var e = Expr.binary(
        BIN_DIV,
        Expr.col_ref("qty"),
        Expr.literal(ScalarValue.from_int(4294967296)),
    )
    var out = _eval_column_expr(e, batch)
    assert_equal(out.length(), 2)
    # PROMOTED to INT64 — the operand domain that holds both sides, and the
    # type DuckDB reports for the same expression (BIGINT).
    assert_true(
        out.arrow_type == ArrowType.INT64,
        "int32 col / out-of-range int literal promotes to INT64",
    )
    var arr = out.as_primitive[DType.int64]()
    assert_false(arr.is_null(0), "not NULL — the divisor is 2^32, not 0")
    assert_false(arr.is_null(1), "not NULL — the divisor is 2^32, not 0")
    assert_equal(arr.get(0), Scalar[DType.int64](0), "40 // 2^32 == 0")
    assert_equal(arr.get(1), Scalar[DType.int64](0), "-80 // 2^32 == 0")


def test_int32_divisor_literal_zero_still_null() raises:
    """THE CONTROL FOR THE SECTION ABOVE. A divisor the user really did write as
    zero must still answer NULL rather than kill the process — the widening must
    not have been mistaken for a licence to relax the guard."""
    var batch = _int32_batch("qty", [Int32(40), Int32(-80)])
    var e = Expr.binary(
        BIN_DIV, Expr.col_ref("qty"), Expr.literal(ScalarValue.from_int(0))
    )
    var out = _eval_column_expr(e, batch)
    var arr = out.as_primitive[DType.int32]()
    assert_true(arr.is_null(0), "qty / 0 row 0 must be NULL")
    assert_true(arr.is_null(1), "qty / 0 row 1 must be NULL")


def test_int32_divisor_in_range_is_unaffected_control() raises:
    """CONTROL: an in-range int32 divisor must still divide normally, so the
    case above is about the TRUNCATION and not about int32 division at all."""
    var batch = _int32_batch("qty", [Int32(40), Int32(-80)])
    var e = Expr.binary(
        BIN_DIV, Expr.col_ref("qty"), Expr.literal(ScalarValue.from_int(4))
    )
    var out = _eval_column_expr(e, batch)
    var arr = out.as_primitive[DType.int32]()
    assert_false(arr.is_null(0))
    assert_false(arr.is_null(1))
    assert_equal(arr.get(0), Scalar[DType.int32](10))
    assert_equal(arr.get(1), Scalar[DType.int32](-20))


# =============================================================================
# A NULL ROW'S PAYLOAD IS NOT AN OPERAND. `_scan_int_divisor` classifies the
# divisor column BEFORE any
# division runs, and it read the divisor's DATA WORD at every row — including
# rows whose validity bit is 0. Arrow leaves a null slot's payload
# unspecified, and an arithmetic result / a join-carried column / an Arrow-IPC
# input can all put a real value under a null bit. A null divisor holding -1
# beside a dividend of Int64.MIN is therefore not a MIN / -1 division at all —
# both rows are NULL by null-propagation — but the scan saw the pair and
# raised "Out of Range Error", killing the whole query.
#
# MEASURED at trunk before this fix: `eval_div: Out of Range Error: Overflow in
# division of MIN / -1 at row 0`, where DuckDB (and this engine's own
# null-propagation everywhere else) answers NULL.
# =============================================================================


def _i64_pair_batch_with_validity(
    lvals: List[Int64], lvalid: List[Bool],
    rvals: List[Int64], rvalid: List[Bool],
) raises -> RecordBatch:
    """Two nullable INT64 columns `a`, `b` whose NULL rows keep a REAL payload
    under the cleared validity bit — which is what a null slot may hold."""
    var la = PrimitiveArray[DType.int64].allocate_nullable(len(lvals))
    for i in range(len(lvals)):
        la.set(i, Scalar[DType.int64](lvals[i]))
    for i in range(len(lvals)):
        if not lvalid[i]:
            la._set_null(i)
    var ra = PrimitiveArray[DType.int64].allocate_nullable(len(rvals))
    for i in range(len(rvals)):
        ra.set(i, Scalar[DType.int64](rvals[i]))
    for i in range(len(rvals)):
        if not rvalid[i]:
            ra._set_null(i)
    var sb = SchemaBuilder()
    var rbb = RecordBatchBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.INT64, True))
    rbb.add_column(Column.from_primitive[DType.int64](la^))
    rbb.add_column(Column.from_primitive[DType.int64](ra^))
    return rbb.build(sb.build())


def test_null_divisor_payload_minus_one_is_null_not_an_overflow_raise() raises:
    """THE REPRODUCTION. b[0] is NULL and its payload is -1; a[0] is Int64.MIN.
    Row 0's answer is NULL because b is NULL, and row 1 must still compute.
    Before the fix this raised `Out of Range Error` for a division that the
    engine is not asked to perform."""
    var lvals = List[Int64]()
    lvals.append(Int64.MIN)
    lvals.append(Int64(10))
    var lvalid = List[Bool]()
    lvalid.append(True)
    lvalid.append(True)
    var rvals = List[Int64]()
    rvals.append(Int64(-1))
    rvals.append(Int64(2))
    var rvalid = List[Bool]()
    rvalid.append(False)
    rvalid.append(True)
    var batch = _i64_pair_batch_with_validity(lvals, lvalid, rvals, rvalid)
    var e = Expr.binary(BIN_DIV, Expr.col_ref("a"), Expr.col_ref("b"))
    var out = _eval_column_expr(e, batch)
    var arr = out.as_primitive[DType.int64]()
    assert_equal(arr.length, 2)
    assert_true(arr.is_null(0), "a NULL divisor makes the row NULL, not a raise")
    assert_false(arr.is_null(1), "the non-null row must still compute")
    assert_equal(arr.get(1), Scalar[DType.int64](5), "10 / 2 == 5")


def test_null_dividend_payload_min_is_null_not_an_overflow_raise() raises:
    """The OTHER operand order. a[0] is NULL with payload Int64.MIN; b[0] is a
    genuine -1. Row 0 is NULL because a is NULL. A guard that only skipped the
    DIVISOR's null rows still raises here."""
    var lvals = List[Int64]()
    lvals.append(Int64.MIN)
    lvals.append(Int64(10))
    var lvalid = List[Bool]()
    lvalid.append(False)
    lvalid.append(True)
    var rvals = List[Int64]()
    rvals.append(Int64(-1))
    rvals.append(Int64(2))
    var rvalid = List[Bool]()
    rvalid.append(True)
    rvalid.append(True)
    var batch = _i64_pair_batch_with_validity(lvals, lvalid, rvals, rvalid)
    var e = Expr.binary(BIN_DIV, Expr.col_ref("a"), Expr.col_ref("b"))
    var out = _eval_column_expr(e, batch)
    var arr = out.as_primitive[DType.int64]()
    assert_true(arr.is_null(0), "a NULL dividend makes the row NULL")
    assert_false(arr.is_null(1), "the non-null row must still compute")
    assert_equal(arr.get(1), Scalar[DType.int64](5), "10 / 2 == 5")


def test_a_GENUINE_min_over_minus_one_still_raises() raises:
    """★ THE CONTROL FOR THE REFUSAL THIS MUST NOT DELETE. Both operands VALID:
    MIN / -1 overflows the signed range and must still raise, exactly as
    DuckDB's "Out of Range Error" does. A fix that skipped the scan entirely,
    or that skipped rows by payload rather than by validity, passes the two
    tests above and silently re-opens the trap this guard exists to close."""
    var lvals = List[Int64]()
    lvals.append(Int64.MIN)
    lvals.append(Int64(10))
    var lvalid = List[Bool]()
    lvalid.append(True)
    lvalid.append(True)
    var rvals = List[Int64]()
    rvals.append(Int64(-1))
    rvals.append(Int64(2))
    var rvalid = List[Bool]()
    rvalid.append(True)
    rvalid.append(True)
    var batch = _i64_pair_batch_with_validity(lvals, lvalid, rvals, rvalid)
    var e = Expr.binary(BIN_DIV, Expr.col_ref("a"), Expr.col_ref("b"))
    var raised = False
    try:
        _ = _eval_column_expr(e, batch)
    except:
        raised = True
    assert_true(
        raised,
        "a VALID Int64.MIN / -1 must still raise — the overflow refusal is not"
        " what the null-payload fix removes",
    )


def test_null_divisor_payload_zero_still_yields_null_control() raises:
    """CONTROL: the same shape whose NULL divisor payload is 0 — the case that
    already worked, because 0 took the guarded path rather than the raise. It
    must keep working, and row 1 must keep computing."""
    var lvals = List[Int64]()
    lvals.append(Int64.MIN)
    lvals.append(Int64(10))
    var lvalid = List[Bool]()
    lvalid.append(True)
    lvalid.append(True)
    var rvals = List[Int64]()
    rvals.append(Int64(0))
    rvals.append(Int64(2))
    var rvalid = List[Bool]()
    rvalid.append(False)
    rvalid.append(True)
    var batch = _i64_pair_batch_with_validity(lvals, lvalid, rvals, rvalid)
    var e = Expr.binary(BIN_DIV, Expr.col_ref("a"), Expr.col_ref("b"))
    var out = _eval_column_expr(e, batch)
    var arr = out.as_primitive[DType.int64]()
    assert_true(arr.is_null(0), "NULL divisor -> NULL")
    assert_false(arr.is_null(1), "10 / 2 stays VALID")
    assert_equal(arr.get(1), Scalar[DType.int64](5))


def test_a_zero_divisor_under_a_null_bit_does_not_null_its_neighbours() raises:
    """A NULL divisor whose payload is 0 must not be counted as "the column
    contains a zero" for the VALID rows. Rows 1 and 2 have real divisors and
    must stay VALID with real quotients — a scan that skips null rows and a
    scan that folds their payloads answer the same here, so this cell exists to
    keep the per-row answers pinned while the classification changes."""
    var lvals = List[Int64]()
    lvals.append(Int64(99))
    lvals.append(Int64(10))
    lvals.append(Int64(20))
    var lvalid = List[Bool]()
    lvalid.append(False)
    lvalid.append(True)
    lvalid.append(True)
    var rvals = List[Int64]()
    rvals.append(Int64(0))
    rvals.append(Int64(2))
    rvals.append(Int64(4))
    var rvalid = List[Bool]()
    rvalid.append(False)
    rvalid.append(True)
    rvalid.append(True)
    var batch = _i64_pair_batch_with_validity(lvals, lvalid, rvals, rvalid)
    var e = Expr.binary(BIN_DIV, Expr.col_ref("a"), Expr.col_ref("b"))
    var out = _eval_column_expr(e, batch)
    var arr = out.as_primitive[DType.int64]()
    assert_true(arr.is_null(0), "the NULL row stays NULL")
    assert_false(arr.is_null(1), "10 / 2 stays VALID")
    assert_false(arr.is_null(2), "20 / 4 stays VALID")
    assert_equal(arr.get(1), Scalar[DType.int64](5))
    assert_equal(arr.get(2), Scalar[DType.int64](5))


def test_null_row_holding_MIN_divided_by_scalar_minus_one_is_null() raises:
    """The SCALAR twin of the reproduction. `col / -1` where the only MIN in
    the column sits under a cleared validity bit. The row's answer is NULL;
    raising for it refuses a query over an overflow that is not performed."""
    var vals = List[Int64]()
    vals.append(Int64.MIN)
    vals.append(Int64(10))
    var valid = List[Bool]()
    valid.append(False)
    valid.append(True)
    var rvals = List[Int64]()
    rvals.append(Int64(-1))
    rvals.append(Int64(-1))
    var rvalid = List[Bool]()
    rvalid.append(True)
    rvalid.append(True)
    var batch = _i64_pair_batch_with_validity(vals, valid, rvals, rvalid)
    var e = Expr.binary(
        BIN_DIV, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(-1))
    )
    var out = _eval_column_expr(e, batch)
    var arr = out.as_primitive[DType.int64]()
    assert_true(arr.is_null(0), "the NULL row is NULL, not an overflow raise")
    assert_false(arr.is_null(1), "10 / -1 stays VALID")
    assert_equal(arr.get(1), Scalar[DType.int64](-10))


def test_a_VALID_MIN_divided_by_scalar_minus_one_still_raises() raises:
    """★ THE CONTROL. The same shape with the MIN row VALID must still raise —
    the scalar refusal is not what the null-payload fix removes."""
    var vals = List[Int64]()
    vals.append(Int64.MIN)
    vals.append(Int64(10))
    var valid = List[Bool]()
    valid.append(True)
    valid.append(True)
    var rvals = List[Int64]()
    rvals.append(Int64(-1))
    rvals.append(Int64(-1))
    var rvalid = List[Bool]()
    rvalid.append(True)
    rvalid.append(True)
    var batch = _i64_pair_batch_with_validity(vals, valid, rvals, rvalid)
    var e = Expr.binary(
        BIN_DIV, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(-1))
    )
    var raised = False
    try:
        _ = _eval_column_expr(e, batch)
    except:
        raised = True
    assert_true(raised, "a VALID Int64.MIN / -1 scalar must still raise")


def main() raises:
    test_int32_divisor_truncated_to_zero_does_not_crash()
    test_int32_divisor_literal_zero_still_null()
    test_int32_divisor_in_range_is_unaffected_control()
    test_plan_route_project_qty_div_zero_is_null_not_a_crash()
    test_mojo_dataframe_surface_col_div_zero_is_null()
    test_mojo_dataframe_surface_truediv_is_duckdb_slash()
    test_plan_route_mod_by_zero_is_NULL_and_a_nonzero_divisor_computes()
    test_plan_route_project_div_nonzero_still_computes()
    test_div_truncates_toward_zero_control()
    test_eval_div_scalar_i64_zero_scalar_all_null()
    test_eval_div_scalar_i32_zero_scalar_all_null()
    test_eval_div_scalar_i64_nonzero_scalar_no_nulls()
    test_eval_div_colcol_i64_mixed_divisor_nulls_only_zero_rows()
    test_eval_div_colcol_i64_no_zero_divisor_is_untouched()
    test_float64_div_by_zero_keeps_ieee_semantics_not_null()
    test_float64_div_colcol_by_zero_keeps_ieee_semantics()
    test_preexisting_null_survives_div_by_zero_guard()
    test_preexisting_null_survives_nonzero_div()
    test_plan_route_colcol_div_by_zero_when_the_DIVIDEND_holds_a_null()
    test_plan_route_colcol_div_by_zero_when_the_DIVISOR_holds_a_null()
    test_plan_route_colcol_div_by_zero_when_BOTH_operands_hold_nulls()
    test_plan_route_colcol_div_by_zero_with_NO_operand_nulls_is_the_control()
    test_plan_route_colcol_operand_nulls_alone_still_propagate()
    test_plan_route_colcol_nullfree_clean_divisor_is_byte_identical()
    test_plan_route_colcol_float_div_by_zero_stays_IEEE()
    test_interpreter_int_div_by_zero_is_null()
    test_interpreter_int_mod_by_zero_is_null()
    test_interpreter_int_div_mod_nonzero_still_computes()
    test_interpreter_float_div_by_zero_is_not_null()
    test_null_divisor_payload_minus_one_is_null_not_an_overflow_raise()
    test_null_dividend_payload_min_is_null_not_an_overflow_raise()
    test_a_GENUINE_min_over_minus_one_still_raises()
    test_null_divisor_payload_zero_still_yields_null_control()
    test_a_zero_divisor_under_a_null_bit_does_not_null_its_neighbours()
    test_null_row_holding_MIN_divided_by_scalar_minus_one_is_null()
    test_a_VALID_MIN_divided_by_scalar_minus_one_still_raises()
    print("OK test_integer_div_zero_no_trap")
