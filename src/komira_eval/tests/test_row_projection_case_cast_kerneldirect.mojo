# =============================================================================
# test_row_projection_case_cast_kerneldirect.mojo — row-typed CASE/WHEN + numeric
# CAST projection VERIFICATION (kernel-direct).
# =============================================================================
#
# VERIFIES the row-typed projection:
#   * CASE/WHEN — EXPR_CASE_I64 / EXPR_CASE_F64 with the `when_pool` side-pool;
#     conditions reuse the per-cell bool walker; THEN/ELSE recurse the value
#     walker; EXPR_NULL marker leaf -> output validity bit.
#   * Numeric CAST — EXPR_I64_TO_F64 (widen) / EXPR_F64_TO_I64 (truncate).
#
# WHY KERNEL-DIRECT (the whole point):
# ------------------------------------
# A verification through `ctx.materialize` / `ctx.read_csv` + `collect` pays a
# large comptime instantiation. This test is FULLY kernel-direct: hand-build a RowBlock, run
# the CASE/CAST evaluator over a borrowed `RowCellSource`, and assert each output
# cell vs a HAND-COMPUTED oracle — NO `ctx`, NO `read_csv*`, NO `collect`, NO
# `materialize`.
#
# The seam exercised is the EXACT production project-walker kernel
# (the row-streaming project walker calls these three evaluators per
# computed cell):
#   * `ExpressionExecutor._eval_i64_from_source[RowCellSource]`  (CASE_I64 / CAST f64->i64)
#   * `ExpressionExecutor._eval_f64_from_source[RowCellSource]`  (CASE_F64 / CAST i64->f64)
#   * `ExpressionExecutor._cell_is_null_from_source[RowCellSource]` (CASE NULL-branch validity)
# over a `RowCellSource` borrowing a hand-built `RowBlock` — exactly the conformer
# the row-streaming project walker constructs. The
# walker's only additional work over this seam is the cell byte-write + the
# `_dt_list_to_cell_dt` tag mapping (both already covered by the F64 / passthrough
# row-projection tests); the CASE/CAST/NULL LOGIC under test lives entirely in
# these three evaluator arms.
#
# Encapsulation: NO UnsafePointer / wildcard origins /
# unsafe_from_address / take_pointee. eval + arrow surface only. `fn` style.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal

from komira_row_format.row_block import RowBlock
from komira_row_format.cell_source import (
    RowCellSource,
    CELL_DT_I64,
    CELL_DT_F64,
)
from komira_eval.expression_executor import ExpressionExecutor
from komira_kernels.runtime_expr import (
    RuntimeExpr,
    make_col,
    make_lit_i64,
    make_lit_f64,
    make_lt_i64,
    make_ge_i64,
    make_case_i64,
    make_case_f64,
    make_null,
    make_i64_to_f64,
    make_f64_to_i64,
)


# =============================================================================
# Fixture: a 2-column input row layout — col0 = I64 @ 0, col1 = F64 @ 8, stride
# 16 (no validity). The nullable variant (NULL-branch CASE) adds a 1-byte
# validity region at offset 16 (stride 17). Logical col_idx 0 -> I64, 1 -> F64.
# =============================================================================

comptime _OFF_I64: Int = 0
comptime _OFF_F64: Int = 8
comptime _STRIDE: Int = 16


def _build_block(i_vals: List[Int64], f_vals: List[Float64]) raises -> RowBlock:
    """Hand-build a RowBlock: col0 = I64 @ 0, col1 = F64 @ 8, stride 16."""
    var n = len(i_vals)
    var rb = RowBlock.with_capacity(n, 0, _STRIDE)
    for i in range(n):
        rb.write_fixed[DType.int64](i, _OFF_I64, i_vals[i])
        rb.write_fixed[DType.float64](i, _OFF_F64, f_vals[i])
    rb.set_n_rows(n)
    return rb^


def _offsets() -> List[Int]:
    """Logical col 0 -> I64 @ 0, col 1 -> F64 @ 8."""
    var offs = List[Int]()
    offs.append(_OFF_I64)
    offs.append(_OFF_F64)
    return offs^


def _dtypes() -> List[UInt8]:
    """CELL_DT space (mirrors the project walker's `_dt_list_to_cell_dt`
    seam — read_{i64,f64} key on CELL_DT tags)."""
    var dts = List[UInt8]()
    dts.append(CELL_DT_I64)
    dts.append(CELL_DT_F64)
    return dts^


# =============================================================================
# §1 — CASE I64 (multi-branch + ELSE). col0 = I64 grade buckets.
#
#   CASE WHEN col0 < 10 THEN 1
#        WHEN col0 < 20 THEN 2
#        ELSE 3 END
#
# Pool layout (slot indices):
#   0: EXPR_COL(col0)        (the condition LHS)
#   1: EXPR_LIT_I64(10)
#   2: EXPR_LIT_I64(20)
#   3: EXPR_LT_I64(0, 1)     cond0: col0 < 10
#   4: EXPR_LT_I64(0, 2)     cond1: col0 < 20
#   5: EXPR_LIT_I64(1)       then0
#   6: EXPR_LIT_I64(2)       then1
#   7: EXPR_LIT_I64(3)       else
#   8: EXPR_CASE_I64(when_pool_idx=0)   ROOT
# when_pool[0] = [3,5, 4,6, 7]  (cond0,then0, cond1,then1, else)
# =============================================================================
def test_case_i64_multibranch_else() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))         # 0
    pool.append(make_lit_i64(10))    # 1
    pool.append(make_lit_i64(20))    # 2
    pool.append(make_lt_i64(0, 1))   # 3 cond0
    pool.append(make_lt_i64(0, 2))   # 4 cond1
    pool.append(make_lit_i64(1))     # 5 then0
    pool.append(make_lit_i64(2))     # 6 then1
    pool.append(make_lit_i64(3))     # 7 else
    pool.append(make_case_i64(0))    # 8 ROOT
    var when_pool = List[List[Int]]()
    var slots = List[Int]()
    slots.append(3); slots.append(5)   # cond0, then0
    slots.append(4); slots.append(6)   # cond1, then1
    slots.append(7)                    # else
    when_pool.append(slots^)

    var i_vals = List[Int64]()
    i_vals.append(5); i_vals.append(10); i_vals.append(15); i_vals.append(20)
    i_vals.append(99)
    var f_vals = List[Float64]()
    for _ in range(len(i_vals)):
        f_vals.append(0.0)

    var rb = _build_block(i_vals, f_vals)
    var cs = RowCellSource(rb, _offsets(), _dtypes())
    var exec = ExpressionExecutor(
        pool^, 8, List[String](), when_pool=when_pool^
    )

    # Hand oracle: 5->1, 10->2, 15->2, 20->3, 99->3.
    var want = List[Int64]()
    want.append(1); want.append(2); want.append(2); want.append(3)
    want.append(3)
    for r in range(rb.n_rows):
        var got = exec._eval_i64_from_source(cs, 8, r)
        assert_equal(
            got, want[r],
            "CASE I64 row " + String(r) + " (col0=" + String(i_vals[r]) + ")",
        )


# =============================================================================
# §2 — CASE F64 (THE F64 BRANCH — not I64-only). col1 = F64 price.
#
#   CASE WHEN col0 >= 100 THEN 9.5
#        ELSE col1 * 0.0 ... (use a literal ELSE for determinism) 1.5 END
#
# Pool:
#   0: EXPR_COL(col0)            int condition LHS
#   1: EXPR_LIT_I64(100)
#   2: EXPR_GE_I64(0, 1)         cond0: col0 >= 100
#   3: EXPR_LIT_F64(9.5)         then0  (F64 value)
#   4: EXPR_LIT_F64(1.5)         else   (F64 value)
#   5: EXPR_CASE_F64(when_pool_idx=0)  ROOT
# when_pool[0] = [2,3, 4]
# =============================================================================
def test_case_f64_branch() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))         # 0
    pool.append(make_lit_i64(100))   # 1
    pool.append(make_ge_i64(0, 1))   # 2 cond0
    pool.append(make_lit_f64(9.5))   # 3 then0
    pool.append(make_lit_f64(1.5))   # 4 else
    pool.append(make_case_f64(0))    # 5 ROOT
    var when_pool = List[List[Int]]()
    var slots = List[Int]()
    slots.append(2); slots.append(3)   # cond0, then0
    slots.append(4)                    # else
    when_pool.append(slots^)

    var i_vals = List[Int64]()
    i_vals.append(50); i_vals.append(100); i_vals.append(150); i_vals.append(99)
    var f_vals = List[Float64]()
    for _ in range(len(i_vals)):
        f_vals.append(0.0)

    var rb = _build_block(i_vals, f_vals)
    var cs = RowCellSource(rb, _offsets(), _dtypes())
    var exec = ExpressionExecutor(
        pool^, 5, List[String](), when_pool=when_pool^
    )

    # Hand oracle: 50->1.5, 100->9.5, 150->9.5, 99->1.5.
    var want = List[Float64]()
    want.append(1.5); want.append(9.5); want.append(9.5); want.append(1.5)
    for r in range(rb.n_rows):
        var got = exec._eval_f64_from_source(cs, 5, r)
        assert_true(
            (got - want[r]) < 1e-9 and (want[r] - got) < 1e-9,
            "CASE F64 row " + String(r) + " (col0=" + String(i_vals[r])
            + "): got " + String(got) + " want " + String(want[r]),
        )


# =============================================================================
# §3 — CASE with a NULL ELSE branch (validity). col0 = I64.
#
#   CASE WHEN col0 < 10 THEN 7
#        ELSE NULL END
#
# The selected branch determines nullity: rows where col0 < 10 yield a non-null
# value 7; rows where col0 >= 10 select the EXPR_NULL else -> SQL NULL (the
# project walker would set the output validity bit). We assert BOTH:
#   * `_eval_i64_from_source` returns 7 (non-null branch) / 0-sentinel (NULL branch)
#   * `_cell_is_null_from_source` returns False (non-null branch) / True (NULL branch)
#
# Pool:
#   0: EXPR_COL(col0)
#   1: EXPR_LIT_I64(10)
#   2: EXPR_LT_I64(0, 1)   cond0
#   3: EXPR_LIT_I64(7)     then0
#   4: EXPR_NULL           else (NULL marker)
#   5: EXPR_CASE_I64(0)    ROOT
# when_pool[0] = [2,3, 4]
# =============================================================================
def test_case_null_else_validity() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))         # 0
    pool.append(make_lit_i64(10))    # 1
    pool.append(make_lt_i64(0, 1))   # 2 cond0
    pool.append(make_lit_i64(7))     # 3 then0
    pool.append(make_null())         # 4 else (NULL)
    pool.append(make_case_i64(0))    # 5 ROOT
    var when_pool = List[List[Int]]()
    var slots = List[Int]()
    slots.append(2); slots.append(3)   # cond0, then0
    slots.append(4)                    # else (NULL)
    when_pool.append(slots^)

    var i_vals = List[Int64]()
    i_vals.append(3); i_vals.append(10); i_vals.append(7); i_vals.append(50)
    var f_vals = List[Float64]()
    for _ in range(len(i_vals)):
        f_vals.append(0.0)

    var rb = _build_block(i_vals, f_vals)
    var cs = RowCellSource(rb, _offsets(), _dtypes())
    var exec = ExpressionExecutor(
        pool^, 5, List[String](), when_pool=when_pool^
    )

    # Hand oracle: col0 < 10 -> value 7, non-null; else -> NULL (0 sentinel).
    var want_null = List[Bool]()
    want_null.append(False)  # 3 < 10
    want_null.append(True)   # 10 >= 10 -> NULL
    want_null.append(False)  # 7 < 10
    want_null.append(True)   # 50 >= 10 -> NULL
    for r in range(rb.n_rows):
        var is_null = exec._cell_is_null_from_source(cs, 5, r)
        assert_equal(
            is_null, want_null[r],
            "CASE NULL-else validity row " + String(r)
            + " (col0=" + String(i_vals[r]) + ")",
        )
        var v = exec._eval_i64_from_source(cs, 5, r)
        if want_null[r]:
            # NULL branch yields the dtype-zero sentinel.
            assert_equal(v, Int64(0), "NULL branch sentinel row " + String(r))
        else:
            assert_equal(v, Int64(7), "non-null THEN value row " + String(r))


# =============================================================================
# §4 — Numeric CAST i64 -> f64 (widen). CAST(col0 AS double).
#
# Pool:
#   0: EXPR_COL(col0)
#   1: EXPR_I64_TO_F64(child=0)   ROOT
# =============================================================================
def test_cast_i64_to_f64() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))          # 0
    pool.append(make_i64_to_f64(0))   # 1 ROOT
    var when_pool = List[List[Int]]()

    var i_vals = List[Int64]()
    i_vals.append(0); i_vals.append(3); i_vals.append(-7); i_vals.append(1000000)
    var f_vals = List[Float64]()
    for _ in range(len(i_vals)):
        f_vals.append(0.0)

    var rb = _build_block(i_vals, f_vals)
    var cs = RowCellSource(rb, _offsets(), _dtypes())
    var exec = ExpressionExecutor(
        pool^, 1, List[String](), when_pool=when_pool^
    )

    for r in range(rb.n_rows):
        var got = exec._eval_f64_from_source(cs, 1, r)
        var want = Float64(i_vals[r])
        assert_true(
            (got - want) < 1e-9 and (want - got) < 1e-9,
            "CAST i64->f64 row " + String(r) + " (col0=" + String(i_vals[r])
            + "): got " + String(got),
        )


# =============================================================================
# §5 — Numeric CAST f64 -> i64 (truncate toward zero). CAST(col1 AS bigint).
#
# Pool:
#   0: EXPR_COL(col1)            col_idx 1 -> F64 @ 8
#   1: EXPR_F64_TO_I64(child=0)  ROOT
# =============================================================================
def test_cast_f64_to_i64() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(1))          # 0  (col_idx 1 -> F64)
    pool.append(make_f64_to_i64(0))   # 1 ROOT
    var when_pool = List[List[Int]]()

    var i_vals = List[Int64]()
    var f_vals = List[Float64]()
    f_vals.append(3.9); f_vals.append(-2.7); f_vals.append(0.0); f_vals.append(99.999)
    for _ in range(len(f_vals)):
        i_vals.append(0)

    var rb = _build_block(i_vals, f_vals)
    var cs = RowCellSource(rb, _offsets(), _dtypes())
    var exec = ExpressionExecutor(
        pool^, 1, List[String](), when_pool=when_pool^
    )

    # Truncate toward zero: 3.9->3, -2.7->-2, 0.0->0, 99.999->99.
    var want = List[Int64]()
    want.append(3); want.append(-2); want.append(0); want.append(99)
    for r in range(rb.n_rows):
        var got = exec._eval_i64_from_source(cs, 1, r)
        assert_equal(
            got, want[r],
            "CAST f64->i64 row " + String(r) + " (col1=" + String(f_vals[r])
            + ")",
        )


def main() raises:
    var suite = TestSuite()
    suite.test[test_case_i64_multibranch_else]()
    suite.test[test_case_f64_branch]()
    suite.test[test_case_null_else_validity]()
    suite.test[test_cast_i64_to_f64]()
    suite.test[test_cast_f64_to_i64]()
    suite^.run()
