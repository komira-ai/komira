# =============================================================================
# tag-12 (EXPR_AGG_FN) projection-eval lowering tests.
# =============================================================================
#
# Locks the typed-frame lowering for `col == col.agg` (the post-agg
# scalar-broadcast shape, TPC-H Q15). Without this lowering the
# projection evaluator `_eval_column_expr` raised
#   `PipelineCompiler: unsupported projection expression tag: 12`
# on an EXPR_AGG_FN node in a projection / filter RHS — the broadcast-MAX-over-
# the-agg-breaker was a DataFrame[O]-only feature (resolved by the optimizer's
# `optimizer_scalar_broadcast` eager-fold). The typed frame path does NOT run
# that rewrite, so the EXPR_AGG_FN survives to eval; the lowering folds the
# aggregated child column over the WHOLE resident batch to a scalar and
# broadcasts it.
#
# The resident batch here IS the full agg-breaker output (the walker's
# POST-BREAKER FILTER arm decodes the breaker to one RecordBatch before applying
# the predicate), so the fold is a correct GLOBAL aggregate — byte-equivalent
# to the generic path's folded literal.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow import PrimitiveArray
from komira_core.arrow.column import Column
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_core.plan.expr import Expr, BIN_EQ
from komira_core.plan.agg_expr import (
    AGG_SUM,
    AGG_COUNT,
    AGG_MIN,
    AGG_MAX,
    AGG_MEAN,
)
from komira_compiler.compiler_eval_column import _eval_column_expr
from komira_compiler.compiler_eval_predicate import _eval_predicate


# -----------------------------------------------------------------------------
# Fixtures — the shape of the agg-breaker OUTPUT: (l_suppkey, total_revenue).
# Matches the TPC-H Q15 post-group_by
# revenue view:  suppkey 1 -> 150, 2 -> 200 (global max), 3 -> 150, 4 -> 40.
# -----------------------------------------------------------------------------


def _revenue_view_f64() raises -> RecordBatch:
    """(l_suppkey INT64, total_revenue FLOAT64) — the q15 grouped-agg output."""
    var sk: List[Int] = [1, 2, 3, 4]
    var rev: List[Float64] = [150.0, 200.0, 150.0, 40.0]
    var n = len(sk)
    var sk_arr = PrimitiveArray[DType.int64].allocate(n)
    var rev_arr = PrimitiveArray[DType.float64].allocate(n)
    var skp = sk_arr._typed_ptr_mut()
    var rp = rev_arr._typed_ptr_mut()
    for i in range(n):
        (skp + i)[] = Scalar[DType.int64](sk[i])
        (rp + i)[] = Scalar[DType.float64](rev[i])
    var sb = SchemaBuilder()
    sb.add_field(Field("l_suppkey", ArrowType.INT64, False))
    sb.add_field(Field("total_revenue", ArrowType.FLOAT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](sk_arr^))
    rbb.add_column(Column.from_primitive[DType.float64](rev_arr^))
    return rbb.build(sb.build())


def _revenue_view_i64() raises -> RecordBatch:
    """(l_suppkey INT64, total_revenue INT64) — int-family variant."""
    var sk: List[Int] = [1, 2, 3, 4]
    var rev: List[Int] = [150, 200, 150, 40]
    var n = len(sk)
    var sk_arr = PrimitiveArray[DType.int64].allocate(n)
    var rev_arr = PrimitiveArray[DType.int64].allocate(n)
    var skp = sk_arr._typed_ptr_mut()
    var rp = rev_arr._typed_ptr_mut()
    for i in range(n):
        (skp + i)[] = Scalar[DType.int64](sk[i])
        (rp + i)[] = Scalar[DType.int64](rev[i])
    var sb = SchemaBuilder()
    sb.add_field(Field("l_suppkey", ArrowType.INT64, False))
    sb.add_field(Field("total_revenue", ArrowType.INT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](sk_arr^))
    rbb.add_column(Column.from_primitive[DType.int64](rev_arr^))
    return rbb.build(sb.build())


def _agg(op: UInt8) -> Expr:
    return Expr.agg_fn(op, Expr.col_ref(String("total_revenue")))


# -----------------------------------------------------------------------------
# Test 1: EXPR_AGG_FN(MAX) in a projection broadcasts the global max (no raise).
# -----------------------------------------------------------------------------


def test_agg_max_broadcasts_global_scalar_f64() raises:
    var batch = _revenue_view_f64()
    var out = _eval_column_expr(_agg(AGG_MAX), batch)
    assert_equal(out.length(), 4, "broadcast column spans every row")
    assert_true(out.arrow_type == ArrowType.FLOAT64, "MAX-of-float -> FLOAT64")
    var arr = out.as_primitive[DType.float64]()
    for r in range(4):
        assert_equal(arr.get(r), 200.0, "every row carries the global max 200")


# -----------------------------------------------------------------------------
# Test 2: the FULL q15 predicate `total_revenue == total_revenue.max` masks
# exactly the max-revenue row — byte-equiv to the generic DataFrame[O] result.
# -----------------------------------------------------------------------------


def test_q15_predicate_keeps_only_max_f64() raises:
    var batch = _revenue_view_f64()
    var pred = Expr.binary(
        BIN_EQ, Expr.col_ref(String("total_revenue")), _agg(AGG_MAX)
    )
    var mask = _eval_predicate(pred, batch)
    assert_equal(mask.length, 4)
    assert_false(mask.get(0), "suppkey 1 (150) filtered out")
    assert_true(mask.get(1), "suppkey 2 (200 == max) survives")
    assert_false(mask.get(2), "suppkey 3 (150) filtered out")
    assert_false(mask.get(3), "suppkey 4 (40) filtered out")


def test_q15_predicate_keeps_only_max_i64() raises:
    var batch = _revenue_view_i64()
    var pred = Expr.binary(
        BIN_EQ, Expr.col_ref(String("total_revenue")), _agg(AGG_MAX)
    )
    var mask = _eval_predicate(pred, batch)
    assert_false(mask.get(0))
    assert_true(mask.get(1), "suppkey 2 (200 == max) survives")
    assert_false(mask.get(2))
    assert_false(mask.get(3))


# -----------------------------------------------------------------------------
# Test 3: a TIE for the max keeps BOTH rows (value-equality, not arg-max).
# -----------------------------------------------------------------------------


def test_q15_predicate_tie_keeps_all() raises:
    # Drop suppkey 2 (200): the new max is 150, shared by suppkeys 1 and 3.
    var sk: List[Int] = [1, 3, 4]
    var rev: List[Float64] = [150.0, 150.0, 40.0]
    var n = len(sk)
    var sk_arr = PrimitiveArray[DType.int64].allocate(n)
    var rev_arr = PrimitiveArray[DType.float64].allocate(n)
    var skp = sk_arr._typed_ptr_mut()
    var rp = rev_arr._typed_ptr_mut()
    for i in range(n):
        (skp + i)[] = Scalar[DType.int64](sk[i])
        (rp + i)[] = Scalar[DType.float64](rev[i])
    var sb = SchemaBuilder()
    sb.add_field(Field("l_suppkey", ArrowType.INT64, False))
    sb.add_field(Field("total_revenue", ArrowType.FLOAT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](sk_arr^))
    rbb.add_column(Column.from_primitive[DType.float64](rev_arr^))
    var batch = rbb.build(sb.build())

    var pred = Expr.binary(
        BIN_EQ, Expr.col_ref(String("total_revenue")), _agg(AGG_MAX)
    )
    var mask = _eval_predicate(pred, batch)
    assert_true(mask.get(0), "suppkey 1 (150 == max) survives")
    assert_true(mask.get(1), "suppkey 3 (150 == max) survives")
    assert_false(mask.get(2), "suppkey 4 (40) filtered out")


# -----------------------------------------------------------------------------
# Test 4: the other reductions (MIN / SUM / MEAN / COUNT) fold + broadcast right.
# -----------------------------------------------------------------------------


def test_agg_min_sum_mean_count_f64() raises:
    var batch = _revenue_view_f64()  # 150, 200, 150, 40 -> sum 540, mean 135

    var mn = _eval_column_expr(_agg(AGG_MIN), batch).as_primitive[DType.float64]()
    assert_equal(mn.get(0), 40.0, "global min is 40")

    var sm = _eval_column_expr(_agg(AGG_SUM), batch).as_primitive[DType.float64]()
    assert_equal(sm.get(0), 540.0, "global sum is 540")

    var mean_col = _eval_column_expr(_agg(AGG_MEAN), batch)
    assert_true(mean_col.arrow_type == ArrowType.FLOAT64, "MEAN -> FLOAT64")
    assert_equal(
        mean_col.as_primitive[DType.float64]().get(3), 135.0, "mean is 135"
    )

    var cnt_col = _eval_column_expr(_agg(AGG_COUNT), batch)
    assert_true(cnt_col.arrow_type == ArrowType.INT64, "COUNT -> INT64")
    assert_equal(
        cnt_col.as_primitive[DType.int64]().get(0), 4, "count of non-null is 4"
    )


# -----------------------------------------------------------------------------
# Test 5: int-family MAX preserves the INT64 output-dtype contract.
# -----------------------------------------------------------------------------


def test_agg_max_i64_output_dtype() raises:
    var batch = _revenue_view_i64()
    var out = _eval_column_expr(_agg(AGG_MAX), batch)
    assert_true(out.arrow_type == ArrowType.INT64, "MAX-of-int -> INT64")
    assert_equal(out.as_primitive[DType.int64]().get(0), 200, "global max 200")


def main() raises:
    var suite = TestSuite()
    suite.test[test_agg_max_broadcasts_global_scalar_f64]()
    suite.test[test_q15_predicate_keeps_only_max_f64]()
    suite.test[test_q15_predicate_keeps_only_max_i64]()
    suite.test[test_q15_predicate_tie_keeps_all]()
    suite.test[test_agg_min_sum_mean_count_f64]()
    suite.test[test_agg_max_i64_output_dtype]()
    suite^.run()
