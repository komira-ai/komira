# =============================================================================
# FUSED DECODE-FILTER — a NULLABLE conjunct column must REFUSE the fused path
# =============================================================================
#
# ⛔ THE DEFECT (2026-09-11, measured through the shipped `.so`).
# `komira_column_kernels/fused_predicate.mojo` is 622 lines in which the words
# "validity" and "null" do not appear: the kernel walks the DATA plane at byte
# granularity and never reads a validity bitmap. `fused_filter.
# _try_collect_conjuncts_from_expr` — the gate that decides whether a
# decode-filter stage may use it — checked the op, the operand shapes and the
# column TYPE, and never the column's NULLABILITY.
#
# So over a NULLABLE INT64/FLOAT64 column the fused path compared WHATEVER
# BYTES THE DECODER LEFT IN THE NULL LANE against the threshold. A null lane
# that reads as 0.0 satisfies `v > -inf AND v < inf`, and the row SURVIVED a
# filter that under SQL 3VL must reject it — UNKNOWN is not TRUE.
#
# ⚠ HOW IT SURFACED, AND WHY IT LOOKED LIKE A ONE-FUNCTION BUG:
# an internal Bazel target, cell
# `filter_isfinite` — `SELECT k FROM F WHERE isfinite(v)` returned survivors
# [0, 4, 5, 6] where DuckDB v1.5.3 gives [0, 4, 5]; row 6 is the NULL. The two
# SIBLING cells in the same fixture were both CORRECT, because `isinf(v)`
# desugars to an OR and `isnan(v)` to a NOT and this collector accepts
# neither, so both fell back to the validity-honouring `_eval_predicate` loop.
# ⇒ only the pure AND-of-comparisons shape reaches the kernel, and of the three
# classifiers only `isfinite` answers TRUE on a 0.0 payload.
#
# ⛔ THE SCOPE IS NOT `isfinite`. ANY `WHERE a > x AND a < y` over a NULLABLE
# INT64/FLOAT64 column on the late-mat path had the same silent wrong row set.
# TPC-H q6/q11/q15 — the benches this lever was built for — declare their
# columns NOT NULL, which is exactly why a validity-blind kernel could ship and
# stay green unnoticed.
#
# THE FIX is a REFUSAL, not a validity-aware kernel: a nullable conjunct column
# falls back to `_eval_predicate`, which already owns the null policy
# (`kleene_cmp_finalize`). Teaching the byte loop 3VL would be a SECOND
# implementation of that policy for a case the hot path does not have.
#
# ⚠ AND THE REFUSAL MUST BE NARROW, which is the second half of this file:
# a NON-nullable column must STILL take the fused path, or the guard has
# quietly deleted the lever it is protecting.
#
# ⭐ `try_fused_eval` HAD NO TEST ANYWHERE IN THE TREE before this file — the
# two `test_fused_predicate*.mojo` files drive the KERNEL directly and never
# the gate that decides to call it. The kernel was not wrong; the decision to
# use it was.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.column import Column
from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import (
    Schema, SchemaBuilder, Field, RecordBatch, RecordBatchBuilder,
)
from komira_plan_expr.expr import Expr, BIN_AND, BIN_GT, BIN_LT
from komira_plan_expr.expr_pool import ExprPool
from komira_plan_expr.scalar_value import ScalarValue
from komira_plan_expr.expr_id import ExprId

from komira_morsel.fused_filter import try_fused_eval


# =============================================================================
# Fixture — the seven float values, with and without a validity bitmap
# =============================================================================


def _values() raises -> List[Float64]:
    """[1.5, nan, inf, -inf, 0.0, -1e308, 0.0].

    The last element is the NULL lane's PAYLOAD in the nullable build — the
    value a decoder leaves behind. It is the whole subject: 0.0 passes both
    conjuncts of `isfinite`.
    """
    var vals = List[Float64]()
    vals.append(1.5)
    vals.append(Float64("nan"))
    vals.append(Float64("inf"))
    vals.append(Float64("-inf"))
    vals.append(0.0)
    vals.append(-1e308)
    vals.append(0.0)
    return vals^


def _batch(nullable: Bool) raises -> RecordBatch:
    var vals = _values()
    var n = len(vals)
    var arr: PrimitiveArray[DType.float64]
    if nullable:
        arr = PrimitiveArray[DType.float64].allocate_nullable(n)
    else:
        arr = PrimitiveArray[DType.float64].allocate(n)
    for i in range(n):
        arr.set(i, Scalar[DType.float64](vals[i]))
    if nullable:
        # `set` marks a lane VALID, so the null is imposed after the writes.
        arr._set_null(6)

    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.FLOAT64, nullable))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.float64](arr^))
    return rbb.build(sb.build())


def _isfinite_stage(mut pool: ExprPool) raises -> List[ExprId]:
    """`v > -inf AND v < inf` — the exact desugar `sql_binder._bind_float_class`
    emits for `isfinite(v)`, and a flat two-conjunct AND-chain on ONE FLOAT64
    column, i.e. precisely the shape the fused collector accepts."""
    var e = Expr.binary(
        BIN_AND,
        Expr.binary(
            BIN_GT,
            Expr.col_ref("v"),
            Expr.literal(ScalarValue.from_float(Float64("-inf"))),
        ),
        Expr.binary(
            BIN_LT,
            Expr.col_ref("v"),
            Expr.literal(ScalarValue.from_float(Float64("inf"))),
        ),
    )
    var stages = List[ExprId]()
    stages.append(pool.register(e^))
    return stages^


# =============================================================================
# THE REFUSAL
# =============================================================================


def test_a_nullable_conjunct_column_refuses_the_fused_path() raises:
    """RED-before: the fused kernel ran and its mask KEPT row 6."""
    var pool = ExprPool()
    var stages = _isfinite_stage(pool)
    var batch = _batch(True)
    var got = try_fused_eval(pool, stages, batch)
    assert_false(
        Bool(got),
        "a nullable conjunct column must fall back to _eval_predicate",
    )


def test_a_non_nullable_column_still_takes_the_fused_path() raises:
    """⭐ THE GUARD MUST BE NARROW — this is the half that proves it.

    Same values, same expression, no validity bitmap. The fused path must
    still fire, or the refusal above has deleted the lever (TPC-H q6/q11/q15)
    instead of correcting it.
    """
    var pool = ExprPool()
    var stages = _isfinite_stage(pool)
    var batch = _batch(False)
    var got = try_fused_eval(pool, stages, batch)
    assert_true(
        Bool(got),
        "a NON-nullable column must still take the fused path",
    )


def test_the_fused_mask_over_a_non_nullable_column_is_unchanged() raises:
    """The values the lever produces are what they were: {0, 4, 5, 6}.

    ⚠ ROW 6 IS IN THIS SET ON PURPOSE. Over a NON-nullable column its 0.0 is a
    REAL zero and `isfinite(0.0)` is TRUE, so keeping it is correct. The whole
    defect was that the kernel could not tell this batch from the nullable one
    above — and this arm is what says the fix did not change the answer for
    the case the kernel is actually entitled to.
    """
    var pool = ExprPool()
    var stages = _isfinite_stage(pool)
    var batch = _batch(False)
    var got = try_fused_eval(pool, stages, batch)
    assert_true(Bool(got), "fused path must fire")
    var res = got.take()
    var mask = res.take_mask()
    assert_equal(len(mask), 7)
    assert_true(mask.get(0), "1.5 is finite")
    assert_false(mask.get(1), "nan is not finite")
    assert_false(mask.get(2), "+inf is not finite")
    assert_false(mask.get(3), "-inf is not finite")
    assert_true(mask.get(4), "0.0 is finite")
    assert_true(mask.get(5), "-1e308 is finite")
    assert_true(mask.get(6), "a REAL 0.0 is finite")


# =============================================================================
# ⛔⛔ THE PLAIN SHAPE — AND IT IS THE POINT. `isfinite` IS NOT REQUIRED.
# =============================================================================
#
# Everything above reaches the kernel through `isfinite(v)`, which desugars to
# `v > -inf AND v < inf`. A reader could conclude the defect needs a classifier,
# or an infinity, or the SQL float-class family at all. IT DOES NOT.
#
# `v > 0.0 AND v < 100.0` is a flat two-conjunct AND-chain of col-vs-literal
# comparisons on ONE FLOAT64 column — the SAME shape, written by hand, with no
# builtin anywhere near it. It is the most ordinary predicate in SQL, and over
# a NULLABLE column the pre-fix collector accepted it and the validity-blind
# kernel answered on the null lane's PAYLOAD.
#
# ⚠ THE NULL LANE'S PAYLOAD HERE IS 42.0, WHICH IS IN RANGE. That is the whole
# construction: a decoder that leaves a real-looking value behind produces a
# row that passes both conjuncts and is emitted by a query that must reject it.
# A payload OUT of range would hide the defect, which is why the fixture picks
# one inside.
#
# ⭐ AND IT IS NOT FLOAT-SPECIFIC — the INT64 arm below is the same statement
# over the other type the fused kernel serves.


def _range_values() -> List[Float64]:
    """[5.0, 50.0, 150.0, -1.0, 99.0, 0.0, 42.0] — index 6 is the NULL lane."""
    var vals = List[Float64]()
    vals.append(5.0)
    vals.append(50.0)
    vals.append(150.0)
    vals.append(-1.0)
    vals.append(99.0)
    vals.append(0.0)
    vals.append(42.0)
    return vals^


def _range_batch_f64(nullable: Bool) raises -> RecordBatch:
    var vals = _range_values()
    var n = len(vals)
    var arr: PrimitiveArray[DType.float64]
    if nullable:
        arr = PrimitiveArray[DType.float64].allocate_nullable(n)
    else:
        arr = PrimitiveArray[DType.float64].allocate(n)
    for i in range(n):
        arr.set(i, Scalar[DType.float64](vals[i]))
    if nullable:
        arr._set_null(6)
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.FLOAT64, nullable))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.float64](arr^))
    return rbb.build(sb.build())


def _range_batch_i64(nullable: Bool) raises -> RecordBatch:
    var vals = _range_values()
    var n = len(vals)
    var arr: PrimitiveArray[DType.int64]
    if nullable:
        arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    else:
        arr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        arr.set(i, Scalar[DType.int64](Int64(Int(vals[i]))))
    if nullable:
        arr._set_null(6)
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, nullable))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](arr^))
    return rbb.build(sb.build())


def _range_stage_f64(mut pool: ExprPool) raises -> List[ExprId]:
    """`v > 0.0 AND v < 100.0` — no builtin, no infinity, no desugar."""
    var e = Expr.binary(
        BIN_AND,
        Expr.binary(
            BIN_GT, Expr.col_ref("v"), Expr.literal(ScalarValue.from_float(0.0))
        ),
        Expr.binary(
            BIN_LT,
            Expr.col_ref("v"),
            Expr.literal(ScalarValue.from_float(100.0)),
        ),
    )
    var stages = List[ExprId]()
    stages.append(pool.register(e^))
    return stages^


def _range_stage_i64(mut pool: ExprPool) raises -> List[ExprId]:
    """`v > 0 AND v < 100` over an INT64 column."""
    var e = Expr.binary(
        BIN_AND,
        Expr.binary(
            BIN_GT, Expr.col_ref("v"), Expr.literal(ScalarValue.from_int64(0))
        ),
        Expr.binary(
            BIN_LT, Expr.col_ref("v"), Expr.literal(ScalarValue.from_int64(100))
        ),
    )
    var stages = List[ExprId]()
    stages.append(pool.register(e^))
    return stages^


def test_a_PLAIN_float_range_over_a_nullable_column_refuses_the_fused_path() raises:
    """`WHERE v > 0.0 AND v < 100.0`, nullable column, NULL payload 42.0.

    RED-before: the fused path was taken and its mask KEPT row 6 — a NULL row
    emitted by an ordinary range predicate, with nothing downstream able to
    tell. No builtin is involved.
    """
    var pool = ExprPool()
    var stages = _range_stage_f64(pool)
    var batch = _range_batch_f64(True)
    var got = try_fused_eval(pool, stages, batch)
    assert_false(
        Bool(got),
        "a PLAIN range predicate over a nullable FLOAT64 column must fall back",
    )


def test_a_PLAIN_int_range_over_a_nullable_column_refuses_the_fused_path() raises:
    """The same statement over INT64 — the defect is not float-specific."""
    var pool = ExprPool()
    var stages = _range_stage_i64(pool)
    var batch = _range_batch_i64(True)
    var got = try_fused_eval(pool, stages, batch)
    assert_false(
        Bool(got),
        "a PLAIN range predicate over a nullable INT64 column must fall back",
    )


def test_the_PLAIN_range_over_a_NON_nullable_column_is_unchanged() raises:
    """⭐ NARROWNESS, and the measurement of what the null lane WOULD have done.

    Same seven values with no validity bitmap: the fused path fires and row 6
    (42.0) is KEPT — correctly, because there it is a real 42.0. That is
    precisely the mask the nullable batch used to get, which is what made the
    NULL row survive.
    """
    var pool = ExprPool()
    var stages = _range_stage_f64(pool)
    var batch = _range_batch_f64(False)
    var got = try_fused_eval(pool, stages, batch)
    assert_true(Bool(got), "a NON-nullable column must still fuse")
    var res = got.take()
    var mask = res.take_mask()
    assert_equal(len(mask), 7)
    assert_true(mask.get(0), "5.0 in range")
    assert_true(mask.get(1), "50.0 in range")
    assert_false(mask.get(2), "150.0 above")
    assert_false(mask.get(3), "-1.0 below")
    assert_true(mask.get(4), "99.0 in range")
    assert_false(mask.get(5), "0.0 is not > 0.0")
    assert_true(mask.get(6), "42.0 in range — the null lane's payload")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
