# =============================================================================
# Tests for `ExpressionExecutor.select_expression_from_view[bo]`.
#
# Covers the additive sibling method on ExpressionExecutor that takes a
# `BatchView[bo]` (read-only typed borrow) instead of a `mut batch:
# RecordBatch`. The body shape mirrors `select_expression_adaptive`
# verbatim; the only delta is the input parameter type. This test
# verifies the byte-identical contract: same survivor count + selection
# indices against the same input data.
#
# Test coverage (4 cases):
#   1. Single-predicate parity — fresh from-view call matches fresh
#      adaptive call (same RecordBatch built twice).
#   2. AND-chain parity (2 conjuncts) — same survivor selection.
#   3. AND-chain parity (4 conjuncts, Q6-shape) — same survivor count
#      under typical TPC-H filter shape.
#   4. Empty-batch — both methods return 0 survivors.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_arrow.batch_view import BatchView, batch_view_over
from komira_eval.expression_executor import ExpressionExecutor
from komira_kernels.runtime_expr import (
    RuntimeExpr,
    make_and,
    make_col,
    make_ge_i64,
    make_lit_i64,
    make_lt_i64,
)
from komira_eval.filter_state import FilterState
from komira_arrow.selection_vector_row import RowSelectionVector


# -----------------------------------------------------------------------------
# Helpers (mirror existing test_expression_executor_adaptive.mojo)
# -----------------------------------------------------------------------------


def _names1(s0: String) -> List[String]:
    var out = List[String]()
    out.append(s0)
    return out^


def _build_single_col_batch(n: Int) raises -> RecordBatch:
    """Single-column Int64 batch with values [0, 1, ..., n-1] named 'c0'."""
    var vals0 = List[Scalar[DType.int64]]()
    for i in range(n):
        vals0.append(Scalar[DType.int64](Int64(i)))
    var arr0 = PrimitiveArray[DType.int64].from_list(vals0^)
    var schema = Schema.from_fields_1(Field("c0", DType.int64, True))
    var col0 = Column.from_primitive[DType.int64](arr0^)
    return RecordBatch.from_typed_columns_1(schema^, col0^)


# -----------------------------------------------------------------------------
# Test 1 — Single-predicate parity vs select_expression_adaptive.
# -----------------------------------------------------------------------------


def test_single_predicate_parity() raises:
    """Single predicate `c0 >= 500` over 1024 rows.

    Both `select_expression_adaptive(mut batch, ...)` and
    `select_expression_from_view[bo](batch_view, ...)` must produce the
    same survivor count + selection indices when given the same input.
    """
    # Build TWO identical executors (the executor's column_names is moved
    # into the constructor; we need two so each call has its own state).
    var pool_a = List[RuntimeExpr]()
    pool_a.append(make_col(0))
    pool_a.append(make_lit_i64(Int64(500)))
    pool_a.append(make_ge_i64(0, 1))
    var exec_a = ExpressionExecutor(pool_a^, 2, _names1("c0"))

    var pool_b = List[RuntimeExpr]()
    pool_b.append(make_col(0))
    pool_b.append(make_lit_i64(Int64(500)))
    pool_b.append(make_ge_i64(0, 1))
    var exec_b = ExpressionExecutor(pool_b^, 2, _names1("c0"))

    # Build two identical RecordBatches (one for each executor invocation).
    var batch_for_adaptive = _build_single_col_batch(1024)
    var batch_for_view = _build_single_col_batch(1024)

    var fs_adaptive = FilterState.with_conjunction(
        n_predicates=1, worker_id=0
    )
    var fs_view = FilterState.with_conjunction(n_predicates=1, worker_id=0)

    var n_adaptive = exec_a.select_expression_adaptive(
        batch_for_adaptive, fs_adaptive
    )

    var view = batch_view_over(batch_for_view)
    var n_view = exec_b.select_expression_from_view(view, fs_view)

    # Survivor counts must match.
    assert_equal(
        n_adaptive, n_view,
        "single-pred: survivor count parity",
    )
    assert_equal(n_view, 524, "single-pred: expected 524 survivors")

    # Selection vectors must match index-by-index.
    for k in range(n_view):
        assert_equal(
            fs_adaptive.sel.get(k), fs_view.sel.get(k),
            "single-pred: survivor index " + String(k) + " parity",
        )


# -----------------------------------------------------------------------------
# Test 2 — AND-chain parity (2 conjuncts).
# -----------------------------------------------------------------------------


def test_and_chain_2_parity() raises:
    """`c0 >= 100 AND c0 < 200` over 1024 rows. Survivors: 100 rows."""
    var pool_a = List[RuntimeExpr]()
    pool_a.append(make_col(0))               # 0
    pool_a.append(make_lit_i64(Int64(100)))  # 1
    pool_a.append(make_ge_i64(0, 1))         # 2: c0 >= 100
    pool_a.append(make_lit_i64(Int64(200)))  # 3
    pool_a.append(make_lt_i64(0, 3))         # 4: c0 < 200
    pool_a.append(make_and(2, 4))            # 5: root AND
    var exec_a = ExpressionExecutor(pool_a^, 5, _names1("c0"))

    var pool_b = List[RuntimeExpr]()
    pool_b.append(make_col(0))
    pool_b.append(make_lit_i64(Int64(100)))
    pool_b.append(make_ge_i64(0, 1))
    pool_b.append(make_lit_i64(Int64(200)))
    pool_b.append(make_lt_i64(0, 3))
    pool_b.append(make_and(2, 4))
    var exec_b = ExpressionExecutor(pool_b^, 5, _names1("c0"))

    var batch_for_adaptive = _build_single_col_batch(1024)
    var batch_for_view = _build_single_col_batch(1024)

    var fs_a = FilterState.with_conjunction(n_predicates=2, worker_id=0)
    var fs_b = FilterState.with_conjunction(n_predicates=2, worker_id=0)

    var n_a = exec_a.select_expression_adaptive(batch_for_adaptive, fs_a)
    var view = batch_view_over(batch_for_view)
    var n_b = exec_b.select_expression_from_view(view, fs_b)

    assert_equal(n_a, n_b, "AND-2: survivor count parity")
    assert_equal(n_b, 100, "AND-2: expected 100 survivors")

    for k in range(n_b):
        assert_equal(
            fs_a.sel.get(k), fs_b.sel.get(k),
            "AND-2: survivor index " + String(k) + " parity",
        )


# -----------------------------------------------------------------------------
# Test 3 — AND-chain parity (4 conjuncts, Q6-shape).
# -----------------------------------------------------------------------------


def test_and_chain_4_q6_shape_parity() raises:
    """4-conjunct AND chain. Mirrors Q6-style filter.

    `c0 >= 100 AND c0 < 800 AND c0 >= 300 AND c0 < 600`
    -> effective range [300, 600), 300 survivors.
    """
    def _build_pool() raises -> List[RuntimeExpr]:
        var pool = List[RuntimeExpr]()
        pool.append(make_col(0))               # 0
        pool.append(make_lit_i64(Int64(100)))  # 1
        pool.append(make_ge_i64(0, 1))         # 2: c0 >= 100
        pool.append(make_lit_i64(Int64(800)))  # 3
        pool.append(make_lt_i64(0, 3))         # 4: c0 < 800
        pool.append(make_lit_i64(Int64(300)))  # 5
        pool.append(make_ge_i64(0, 5))         # 6: c0 >= 300
        pool.append(make_lit_i64(Int64(600)))  # 7
        pool.append(make_lt_i64(0, 7))         # 8: c0 < 600
        # AND-left-leaning: ((((p1 AND p2) AND p3) AND p4))
        pool.append(make_and(2, 4))            # 9
        pool.append(make_and(9, 6))            # 10
        pool.append(make_and(10, 8))           # 11 (root)
        return pool^

    var exec_a = ExpressionExecutor(_build_pool(), 11, _names1("c0"))
    var exec_b = ExpressionExecutor(_build_pool(), 11, _names1("c0"))

    var batch_for_adaptive = _build_single_col_batch(1024)
    var batch_for_view = _build_single_col_batch(1024)

    var fs_a = FilterState.with_conjunction(n_predicates=4, worker_id=0)
    var fs_b = FilterState.with_conjunction(n_predicates=4, worker_id=0)

    var n_a = exec_a.select_expression_adaptive(batch_for_adaptive, fs_a)
    var view = batch_view_over(batch_for_view)
    var n_b = exec_b.select_expression_from_view(view, fs_b)

    assert_equal(n_a, n_b, "AND-4: survivor count parity")
    assert_equal(n_b, 300, "AND-4: expected 300 survivors (c0 in [300, 600))")

    # Spot-check first / middle / last survivor indices.
    assert_equal(
        fs_b.sel.get(0), UInt32(300),
        "AND-4: first survivor = row 300",
    )
    assert_equal(
        fs_b.sel.get(150), UInt32(450),
        "AND-4: middle survivor (k=150) = row 450",
    )
    assert_equal(
        fs_b.sel.get(299), UInt32(599),
        "AND-4: last survivor (k=299) = row 599",
    )

    for k in range(n_b):
        assert_equal(
            fs_a.sel.get(k), fs_b.sel.get(k),
            "AND-4: survivor index " + String(k) + " parity",
        )


# -----------------------------------------------------------------------------
# Test 4 — Empty batch parity.
# -----------------------------------------------------------------------------


def test_empty_batch_parity() raises:
    """Empty RecordBatch (0 rows). Both methods return 0 survivors."""
    var pool_a = List[RuntimeExpr]()
    pool_a.append(make_col(0))
    pool_a.append(make_lit_i64(Int64(50)))
    pool_a.append(make_ge_i64(0, 1))
    var exec_a = ExpressionExecutor(pool_a^, 2, _names1("c0"))

    var pool_b = List[RuntimeExpr]()
    pool_b.append(make_col(0))
    pool_b.append(make_lit_i64(Int64(50)))
    pool_b.append(make_ge_i64(0, 1))
    var exec_b = ExpressionExecutor(pool_b^, 2, _names1("c0"))

    var batch_a = _build_single_col_batch(0)
    var batch_b = _build_single_col_batch(0)

    var fs_a = FilterState.with_conjunction(n_predicates=1, worker_id=0)
    var fs_b = FilterState.with_conjunction(n_predicates=1, worker_id=0)

    var n_a = exec_a.select_expression_adaptive(batch_a, fs_a)
    var view = batch_view_over(batch_b)
    var n_b = exec_b.select_expression_from_view(view, fs_b)

    assert_equal(n_a, n_b, "empty: survivor count parity")
    assert_equal(n_b, 0, "empty: 0 survivors")


# -----------------------------------------------------------------------------
# Test 5 — F64-channel EXPR_COL walker WIDENS an INT64 source column.
#
# REGRESSION GUARD: `eval_to_list_f64_from_view`'s EXPR_COL arm
# is the val-expr feed for the F64-channel aggregators (COUNT/SUM/MIN/MAX/AVG
# → RUNTIME_AGG_*_F64). For an INT64 / INT32 source column (e.g.
# `count(int_col)`, `min(int64_col)`) it MUST numerically widen the integer
# values to float64 — NOT bit-reinterpret via `as_primitive[float64]`, which
# raises "column is int64 but requested float64". This was the single shared
# root cause of a 17-test failure batch (the throw fired inside the runtime
# breaker's SIMD col-ref fast-path AND this walker). The gate that re-routes
# integer-val SIMD shapes to this widening walker lives in
# the runtime hash-agg feed for a single i64 key + f64 value.
# -----------------------------------------------------------------------------


def test_f64_walker_widens_int64_column() raises:
    """`eval_to_list_f64_from_view` over an INT64 column must produce the
    numerically-widened float64 values (50.0, 51.0, ...), not throw and not
    bit-reinterpret. Selects rows [50, 100) of a [0..1024) int64 column."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))  # EXPR_COL leaf over the int64 column 'c0'
    var executor = ExpressionExecutor(pool^, 0, _names1("c0"))

    var batch = _build_single_col_batch(1024)
    var view = batch_view_over(batch)

    # Select rows 50..99 inclusive.
    var sel = RowSelectionVector(2048)
    for r in range(50, 100):
        sel.append(UInt32(r))

    var out = List[Scalar[DType.float64]]()
    executor.eval_to_list_f64_from_view(view, 0, sel, out)

    assert_equal(len(out), 50, "f64-widen: appended one value per survivor")
    # The int64 column holds value == row index; widened to float64 the first
    # survivor (row 50) must be exactly 50.0, not the bit-reinterpret garbage.
    assert_equal(out[0], Scalar[DType.float64](50.0), "f64-widen: row 50 -> 50.0")
    assert_equal(out[49], Scalar[DType.float64](99.0), "f64-widen: row 99 -> 99.0")


# -----------------------------------------------------------------------------
# TestSuite registration
# -----------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()

    suite.test[test_single_predicate_parity]()
    suite.test[test_and_chain_2_parity]()
    suite.test[test_and_chain_4_q6_shape_parity]()
    suite.test[test_empty_batch_parity]()
    suite.test[test_f64_walker_widens_int64_column]()

    suite^.run()
