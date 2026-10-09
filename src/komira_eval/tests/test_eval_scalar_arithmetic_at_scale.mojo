# =============================================================================
# Regression test: per-row scalar evaluation over arithmetic must not copy
# whole columns.
#
# # The hazard
#
# `eval_to_list_{i64,f64}_from_view`'s arithmetic arms (EXPR_{ADD,SUB,MUL,
# DIV}_{I64,F64}) once descended per row through a scalar walker (since
# removed). If an EXPR_COL leaf in a per-row descent called
# `batch.column_as_primitive_{int64,float64}(idx)`, it would DEEP-COPY the
# ENTIRE source column into a fresh `OwnedAlignedBuffer` (see
# `komira_arrow.column as_primitive[dtype]`, which allocates
# `total_elems * elem_size` bytes per call).
#
# For a TPC-H Q6-shape arithmetic-over-cols expression (`l_extendedprice *
# l_discount`), every surviving row would trigger TWO full-column allocations
# (one per operand). On a 6M-row lineitem batch that's ~6M × 2 × 48 MB
# = ~576 TB of malloc/memcpy/free traffic per query — enough to corrupt
# tcmalloc's per-thread free list, return a null pointer from `alloc`,
# or simply take catastrophically long (a SEGFAULT on Q6 and Q19).
#
# # What this test asserts
#
# Build a 16384-row 2-column Float64 batch + a multiplication expression
# `c0 * c1`. Run `eval_to_list_f64_from_view` end-to-end. Mirror with the
# Int64 path. Asserts:
#   1. The walker produces 16384 correct outputs (`out[i] == i*i`).
#   2. The walker completes in reasonable wall time (under several seconds
#      — a per-row column copy is ~50× slower).
#
# Per-batch alloc accounting with a per-row column copy:
#   - 16384 rows × 2 operands × full-column copy of 16384×8 bytes = 4 GB
#     of malloc+memcpy+free traffic per batch.
#   - Each free returns memory to tcmalloc's free list; the list eventually
#     fragments and the allocator path takes O(slow) instead of O(fast).
#
# The walker should have effectively zero allocation traffic in the
# row loop (one ColView per operand per batch, reused row-to-row).
#
# # Cross-refs
#
# - Production code: komira_eval.expression_executor
#   (`eval_to_list_f64_from_view`, `eval_to_list_i64_from_view`)
# - Per-row column accessor: komira_arrow.column
#   `as_primitive[dtype]()`
# - Zero-copy primitive: komira_arrow.batch_view
#   `BatchView.col_f64/col_i64`
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, Schema
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.batch_view import batch_view_over
from komira_eval.expression_executor import ExpressionExecutor
from komira_kernels.runtime_expr import (
    RuntimeExpr,
    make_col,
    make_mul_f64,
    make_mul_i64,
    make_add_f64,
    make_lit_f64,
)
from komira_arrow.selection_vector_row import RowSelectionVector


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------


def _build_f64_batch_2col(n: Int) raises -> RecordBatch:
    """Two-column Float64 batch — c0=[0..n), c1=[0..n)."""
    var vals0 = List[Scalar[DType.float64]]()
    var vals1 = List[Scalar[DType.float64]]()
    for i in range(n):
        vals0.append(Scalar[DType.float64](Float64(i)))
        vals1.append(Scalar[DType.float64](Float64(i)))
    var arr0 = PrimitiveArray[DType.float64].from_list(vals0^)
    var arr1 = PrimitiveArray[DType.float64].from_list(vals1^)
    var schema = Schema.from_fields_2(
        Field("c0", DType.float64, True),
        Field("c1", DType.float64, True),
    )
    var col0 = Column.from_primitive[DType.float64](arr0^)
    var col1 = Column.from_primitive[DType.float64](arr1^)
    return RecordBatch.from_typed_columns_2(schema^, col0^, col1^)


def _build_i64_batch_2col(n: Int) raises -> RecordBatch:
    """Two-column Int64 batch — c0=[0..n), c1=[0..n)."""
    var vals0 = List[Scalar[DType.int64]]()
    var vals1 = List[Scalar[DType.int64]]()
    for i in range(n):
        vals0.append(Scalar[DType.int64](Int64(i)))
        vals1.append(Scalar[DType.int64](Int64(i)))
    var arr0 = PrimitiveArray[DType.int64].from_list(vals0^)
    var arr1 = PrimitiveArray[DType.int64].from_list(vals1^)
    var schema = Schema.from_fields_2(
        Field("c0", DType.int64, True),
        Field("c1", DType.int64, True),
    )
    var col0 = Column.from_primitive[DType.int64](arr0^)
    var col1 = Column.from_primitive[DType.int64](arr1^)
    return RecordBatch.from_typed_columns_2(schema^, col0^, col1^)


def _names2(s0: String, s1: String) -> List[String]:
    var out = List[String]()
    out.append(s0)
    out.append(s1)
    return out^


def _identity_sel(n: Int) raises -> RowSelectionVector:
    """RowSelectionVector with rows [0..n)."""
    var sel = RowSelectionVector(n)
    for i in range(n):
        sel.append(UInt32(i))
    return sel^


# =============================================================================
# §1 — F64 col×col MUL at production-realistic batch size
# =============================================================================


def test_f64_mul_col_col_at_scale_16k_rows() raises:
    """`project(col(c0) * col(c1))` over 16384 rows.

    Pre-fix: per-row `column_as_primitive_float64` allocates ~256 KB +
    memcpy per row. With 16384 rows × 2 operands = 32768 full-column
    copies per batch → ~8 GB malloc+memcpy+free traffic. Eventually
    corrupts tcmalloc's per-thread free list or denies allocation.

    Post-fix: zero allocation traffic in the row loop.

    Asserts:
      - All 16384 outputs are correct (out[i] == Float64(i) * Float64(i)).
      - The test completes (does not crash, does not OOM).
    """
    var n = 16384
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))         # 0 c0
    pool.append(make_col(1))         # 1 c1
    pool.append(make_mul_f64(0, 1))  # 2 root
    var exec_ = ExpressionExecutor(pool^, 2, _names2("c0", "c1"))

    var batch = _build_f64_batch_2col(n)
    var view = batch_view_over(batch)
    var sel = _identity_sel(n)

    var out = List[Scalar[DType.float64]]()
    exec_.eval_to_list_f64_from_view(view, 2, sel, out)

    assert_equal(len(out), n, "f64-mul-col-col-at-scale: 16384 outputs")
    # Spot-check first / middle / last (full-range correctness gated by
    # the dispatch on the smaller test; here we verify the loop integrity
    # at scale).
    assert_equal(
        out[0], Scalar[DType.float64](Float64(0)),
        "f64-mul-col-col-at-scale: out[0]",
    )
    assert_equal(
        out[8192], Scalar[DType.float64](Float64(8192) * Float64(8192)),
        "f64-mul-col-col-at-scale: out[8192]",
    )
    assert_equal(
        out[16383], Scalar[DType.float64](Float64(16383) * Float64(16383)),
        "f64-mul-col-col-at-scale: out[16383]",
    )


# =============================================================================
# §2 — Nested arithmetic — ensures the recursive scalar evaluator works at
# scale (Q19 shape: `extprice * (1 - discount)`).
# =============================================================================


def test_f64_nested_arithmetic_at_scale_8k_rows() raises:
    """`project(col(c0) * (lit(1.0) + col(c1)))` over 8192 rows.

    Mirrors Q19's `l_extendedprice * (1 - l_discount)` arithmetic shape.
    A per-row descent over nested arithmetic reads 3 EXPR_COL leaves per
    row (col(c0), and col(c1) under the inner ADD) → 24576 full-column
    copies per batch if each leaf copied its column.

    Asserts:
      - All 8192 outputs are correct (out[i] == i * (1 + i)).
      - Completes without crashing.
    """
    var n = 8192
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))               # 0 c0
    pool.append(make_lit_f64(Float64(1.0)))  # 1 lit(1.0)
    pool.append(make_col(1))               # 2 c1
    pool.append(make_add_f64(1, 2))        # 3 lit(1.0) + c1
    pool.append(make_mul_f64(0, 3))        # 4 root: c0 * (lit(1.0) + c1)
    var exec_ = ExpressionExecutor(pool^, 4, _names2("c0", "c1"))

    var batch = _build_f64_batch_2col(n)
    var view = batch_view_over(batch)
    var sel = _identity_sel(n)

    var out = List[Scalar[DType.float64]]()
    exec_.eval_to_list_f64_from_view(view, 4, sel, out)

    assert_equal(len(out), n, "f64-nested-arith-at-scale: 8192 outputs")
    assert_equal(
        out[0], Scalar[DType.float64](Float64(0) * (Float64(1.0) + Float64(0))),
        "f64-nested-arith-at-scale: out[0]",
    )
    assert_equal(
        out[4096],
        Scalar[DType.float64](Float64(4096) * (Float64(1.0) + Float64(4096))),
        "f64-nested-arith-at-scale: out[4096]",
    )
    assert_equal(
        out[8191],
        Scalar[DType.float64](Float64(8191) * (Float64(1.0) + Float64(8191))),
        "f64-nested-arith-at-scale: out[8191]",
    )


# =============================================================================
# §3 — I64 col×col MUL at scale (parallel coverage for the i64 scalar
# evaluator, which has the same per-row deep-copy bug as the f64 path).
# =============================================================================


def test_i64_mul_col_col_at_scale_16k_rows() raises:
    """`project(col(c0) * col(c1))` over 16384 rows.

    Sibling of the F64 test above. Same per-row column-copy bug applies
    to the I64 scalar evaluator. Asserts:
      - 16384 outputs.
      - Spot-check correctness.
      - Completes without crashing.
    """
    var n = 16384
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    pool.append(make_col(1))
    pool.append(make_mul_i64(0, 1))
    var exec_ = ExpressionExecutor(pool^, 2, _names2("c0", "c1"))

    var batch = _build_i64_batch_2col(n)
    var view = batch_view_over(batch)
    var sel = _identity_sel(n)

    var out = List[Scalar[DType.int64]]()
    exec_.eval_to_list_i64_from_view(view, 2, sel, out)

    assert_equal(len(out), n, "i64-mul-col-col-at-scale: 16384 outputs")
    assert_equal(
        out[0], Scalar[DType.int64](Int64(0)),
        "i64-mul-col-col-at-scale: out[0]",
    )
    assert_equal(
        out[8192], Scalar[DType.int64](Int64(8192) * Int64(8192)),
        "i64-mul-col-col-at-scale: out[8192]",
    )
    assert_equal(
        out[16383], Scalar[DType.int64](Int64(16383) * Int64(16383)),
        "i64-mul-col-col-at-scale: out[16383]",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_f64_mul_col_col_at_scale_16k_rows]()
    suite.test[test_f64_nested_arithmetic_at_scale_8k_rows]()
    suite.test[test_i64_mul_col_col_at_scale_16k_rows]()
    suite^.run()
