# =============================================================================
# test_row_projection_mathfn_kerneldirect.mojo — row PROJECT math-fn projection
# VERIFICATION (kernel-direct).
# =============================================================================
#
# VERIFIES the row PROJECT walker's math functions:
#   * sqrt / sin / cos / asin / radians (EXPR_MATH_FN, unary, FLOAT64) +
#     atan2 (EXPR_MATH_FN2, binary, FLOAT64) self-serve the row PROJECT
#     walker. The column oracle (`compiler_eval_column` EXPR_MATH_FN arm)
#     coerces the child to FLOAT64 and applies the scalar kernel element-wise;
#     the row walker mirrors that per-cell via `_eval_f64_from_source` over a
#     `RowCellSource` borrowing the input RowBlock.
#
# CONSTRUCTIBILITY: the IR carries ONLY
# MATH_SIN/COS/SQRT/ASIN/RADIANS (unary) + MATH2_ATAN2 (binary). ABS / ROUND /
# CEIL / FLOOR are UNCONSTRUCTIBLE (no op code, no SDK builder, no column
# evaluator) — so they are NOT in this batch.
#
# WHY KERNEL-DIRECT (the whole point):
# ------------------------------------
# `ctx.materialize` / `ctx.read_csv` + `collect` compile the full plan dispatch tree, a large comptime instantiation this test
# avoids. It is
# FULLY kernel-direct: hand-build a RowBlock, run the math-fn evaluator over a
# borrowed `RowCellSource`, assert each output cell vs a HAND-COMPUTED oracle —
# NO `ctx`, NO `read_csv*`, NO `collect`, NO `materialize`.
#
# The seam exercised is the EXACT production project-walker kernel
# (the row-streaming project walker calls this evaluator per
# computed F64 cell):
#   * `ExpressionExecutor._eval_f64_from_source[RowCellSource]`  (EXPR_*_F64)
# The walker's only additional work over this seam is the cell byte-write + the
# `_dt_list_to_cell_dt` tag mapping (covered by the F64 row-projection tests);
# the math-fn LOGIC under test lives entirely in the f64 evaluator arm.
#
# Encapsulation: NO UnsafePointer / wildcard origins /
# unsafe_from_address / take_pointee. eval surface only. `fn` style.
# =============================================================================

from std.math import sqrt, sin, cos, asin, atan2, pi

from std.testing import TestSuite, assert_true

from komira_row_format.row_block import RowBlock
from komira_row_format.cell_source import (
    RowCellSource,
    CELL_DT_F64,
    CELL_DT_I64,
)
from komira_eval.expression_executor import ExpressionExecutor
from komira_kernels.runtime_expr import (
    RuntimeExpr,
    make_col,
    make_sqrt_f64,
    make_sin_f64,
    make_cos_f64,
    make_asin_f64,
    make_radians_f64,
    make_atan2_f64,
    make_mul_f64,
    make_add_f64,
)


# =============================================================================
# Fixture: a 2-column input row layout — col0 = F64 @ 0, col1 = F64 @ 8,
# stride 16 (no validity). Both CELL_DT_F64. The walker reads F64 cells via
# RowCellSource.read_f64.
# =============================================================================

comptime _OFF_A: Int = 0
comptime _OFF_B: Int = 8
comptime _STRIDE: Int = 16


def _build_block(a: List[Float64], b: List[Float64]) raises -> RowBlock:
    """Hand-build a RowBlock: col0 = F64 @ 0, col1 = F64 @ 8, stride 16."""
    var n = len(a)
    var rb = RowBlock.with_capacity(n, 0, _STRIDE)
    for i in range(n):
        rb.write_fixed[DType.float64](i, _OFF_A, a[i])
        rb.write_fixed[DType.float64](i, _OFF_B, b[i])
    rb.set_n_rows(n)
    return rb^


def _offsets() -> List[Int]:
    """Logical col 0 -> F64 @ 0, col 1 -> F64 @ 8."""
    var offs = List[Int]()
    offs.append(_OFF_A)
    offs.append(_OFF_B)
    return offs^


def _dtypes() -> List[UInt8]:
    """CELL_DT space — both F64 (mirrors the project walker's
    `_dt_list_to_cell_dt` seam: DT_F64 -> CELL_DT_F64)."""
    var dts = List[UInt8]()
    dts.append(CELL_DT_F64)
    dts.append(CELL_DT_F64)
    return dts^


def _approx(got: Float64, want: Float64, msg: String) raises:
    assert_true(
        (got - want) < 1e-9 and (want - got) < 1e-9,
        msg + ": got " + String(got) + " want " + String(want),
    )


# =============================================================================
# §1 — sqrt(col0). EXPR_SQRT_F64 over an F64 leaf.
#
# Pool:
#   0: EXPR_COL(col0)            F64 leaf
#   1: EXPR_SQRT_F64(child=0)    ROOT
# =============================================================================
def test_sqrt_f64() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))          # 0
    pool.append(make_sqrt_f64(0))     # 1 ROOT

    var a = List[Float64]()
    a.append(4.0); a.append(2.0); a.append(0.0); a.append(100.0)
    var b = List[Float64]()
    for _ in range(len(a)):
        b.append(Float64(0))

    var rb = _build_block(a, b)
    var cs = RowCellSource(rb, _offsets(), _dtypes())
    var exec = ExpressionExecutor(pool^, 1, List[String]())

    for r in range(rb.n_rows):
        _approx(
            exec._eval_f64_from_source(cs, 1, r), sqrt(a[r]),
            "sqrt row " + String(r),
        )


# =============================================================================
# §2 — sin / cos / asin / radians(col0). Four unary roots over the F64 leaf.
# =============================================================================
def test_unary_trig_f64() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))             # 0 col
    pool.append(make_sin_f64(0))         # 1 sin
    pool.append(make_cos_f64(0))         # 2 cos
    pool.append(make_asin_f64(0))        # 3 asin
    pool.append(make_radians_f64(0))     # 4 radians

    var a = List[Float64]()
    a.append(0.0); a.append(0.5); a.append(1.0); a.append(-0.25)
    var b = List[Float64]()
    for _ in range(len(a)):
        b.append(Float64(0))

    var rb = _build_block(a, b)
    var cs = RowCellSource(rb, _offsets(), _dtypes())
    var exec = ExpressionExecutor(pool^, 1, List[String]())

    for r in range(rb.n_rows):
        _approx(exec._eval_f64_from_source(cs, 1, r), sin(a[r]),
                "sin row " + String(r))
        _approx(exec._eval_f64_from_source(cs, 2, r), cos(a[r]),
                "cos row " + String(r))
        _approx(exec._eval_f64_from_source(cs, 3, r), asin(a[r]),
                "asin row " + String(r))
        _approx(
            exec._eval_f64_from_source(cs, 4, r),
            a[r] * Float64(pi / 180.0),
            "radians row " + String(r),
        )


# =============================================================================
# §3 — atan2(col0, col1). EXPR_ATAN2_F64 binary over two F64 leaves.
#
# Pool:
#   0: EXPR_COL(col0)                  y leaf
#   1: EXPR_COL(col1)                  x leaf
#   2: EXPR_ATAN2_F64(left=0,right=1)  ROOT
# =============================================================================
def test_atan2_f64() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))           # 0 y
    pool.append(make_col(1))           # 1 x
    pool.append(make_atan2_f64(0, 1))  # 2 ROOT

    var a = List[Float64]()
    a.append(1.0); a.append(0.0); a.append(-1.0); a.append(3.0)
    var b = List[Float64]()
    b.append(1.0); b.append(1.0); b.append(2.0); b.append(-4.0)

    var rb = _build_block(a, b)
    var cs = RowCellSource(rb, _offsets(), _dtypes())
    var exec = ExpressionExecutor(pool^, 2, List[String]())

    for r in range(rb.n_rows):
        _approx(
            exec._eval_f64_from_source(cs, 2, r), atan2(a[r], b[r]),
            "atan2 row " + String(r),
        )


# =============================================================================
# §4 — sqrt of an arithmetic sub-tree: sqrt(col0 * col0 + col1 * col1) — the
# haversine-shaped composition. Proves the math-fn arm composes with the
# existing ADD/MUL_F64 arms.
# =============================================================================
def test_sqrt_of_arith_f64() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))      # 0 a
    pool.append(make_col(1))      # 1 b
    # a*a
    pool.append(make_mul_f64(0, 0))   # 2 a*a
    pool.append(make_mul_f64(1, 1))   # 3 b*b
    pool.append(make_add_f64(2, 3))   # 4 a*a + b*b
    pool.append(make_sqrt_f64(4))     # 5 ROOT

    var a = List[Float64]()
    a.append(3.0); a.append(5.0); a.append(0.0)
    var b = List[Float64]()
    b.append(4.0); b.append(12.0); b.append(0.0)

    var rb = _build_block(a, b)
    var cs = RowCellSource(rb, _offsets(), _dtypes())
    var exec = ExpressionExecutor(pool^, 5, List[String]())

    for r in range(rb.n_rows):
        _approx(
            exec._eval_f64_from_source(cs, 5, r),
            sqrt(a[r] * a[r] + b[r] * b[r]),
            "sqrt(arith) row " + String(r),
        )


def main() raises:
    var suite = TestSuite()
    suite.test[test_sqrt_f64]()
    suite.test[test_unary_trig_f64]()
    suite.test[test_atan2_f64]()
    suite.test[test_sqrt_of_arith_f64]()
    suite^.run()
