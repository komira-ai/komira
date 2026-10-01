# =============================================================================
# test_row_decimal_filter_kerneldirect.mojo — row-typed DECIMAL128 numeric
# filter VERIFICATION (kernel-direct).
# =============================================================================
#
# VERIFIES the row-typed FILTER DECIMAL128 int128 cell read:
#   * `dec_col > lit` / `dec_col < lit` / `dec_col = lit` over a 16-byte
#     DECIMAL128 fixed cell. The per-cell walker reads the full SIGNED Int128
#     unscaled value (`CS.read_i128`) and compares it against the literal's
#     interned i128 (decimal_pool). A walker that reads only the low 8 bytes would
#     misread the 16-byte cell as its low-8-bytes
#     i64 (silently wrong). The walker uses a native int128 read so decimal
#     filters self-serve the row path.
#
# THE int128-STRADDLE PROOF (the whole point):
# --------------------------------------------
# The fixture stores DECIMAL128 values whose LOW 64 bits, reinterpreted as an
# Int64, compare WRONG vs the literal — only a correct full-width int128 read
# selects the right rows. Concretely:
#   * 2^64 (= 18446744073709551616): low-64 bits == 0. As i64-low it reads 0
#     (< 5), but as int128 it is huge (> 5). A buggy i64-low read drops it from
#     `dec > 5`; the int128 read keeps it.
#   * 2^63 (= 9223372036854775808): low-64 bits == 0x8000_0000_0000_0000, which
#     as a SIGNED Int64 is Int64.MIN (hugely negative), but as int128 it is a
#     large POSITIVE value. A buggy i64-low read would mis-order it.
# These straddle values make the test FAIL if the walker reads i64-low (RED with
# the int128 arm neutralized) and PASS with the native int128 read.
#
# WHY KERNEL-DIRECT: `ctx.materialize` / `read_csv` + `collect`
# compile the full plan dispatch tree, a large comptime instantiation this test
# avoids. It is FULLY kernel-direct: hand-build a
# RowBlock with a DECIMAL128 column, run the bool evaluator over a borrowed
# RowCellSource, assert the selected rows vs a HAND oracle — NO ctx, NO read_csv,
# NO collect, NO materialize.
#
# The seam exercised is the EXACT production filter-walker kernel
# (the row-streaming filter walker calls this evaluator per row):
#   * `ExpressionExecutor._eval_bool_from_source[RowCellSource]`
# over a `RowCellSource` borrowing a hand-built `RowBlock`.
#
# Encapsulation: NO UnsafePointer / wildcard origins /
# unsafe_from_address / take_pointee. eval surface only. `fn` style.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal

from komira_eval.row_format import RowBlock
from komira_eval.cell_source import (
    RowCellSource,
    CELL_DT_DECIMAL128,
)
from komira_eval.expression_executor import ExpressionExecutor, DecimalSpec
from komira_eval.runtime_expr import (
    RuntimeExpr,
    make_col_decimal128,
    make_lit_decimal128,
    make_gt_decimal128,
    make_lt_decimal128,
    make_eq_decimal128,
)


# =============================================================================
# Fixture: a single DECIMAL128 column — col0 @ 0, stride 16 (one 16-byte cell).
# Scale is uniform (== the literal's scale), so a raw signed-int128 compare is
# the correct decimal ordering (the same assumption the SORT/DISTINCT path uses).
# =============================================================================

comptime _OFF0: Int = 0
comptime _STRIDE_1DEC: Int = 16


def _build_dec_block(vals: List[SIMD[DType.int128, 1]]) raises -> RowBlock:
    var n = len(vals)
    var rb = RowBlock.with_capacity(n, 0, _STRIDE_1DEC)
    for i in range(n):
        rb.write_fixed[DType.int128](i, _OFF0, vals[i])
    rb.set_n_rows(n)
    return rb^


def _dec_offsets() -> List[Int]:
    var offs = List[Int]()
    offs.append(_OFF0)
    return offs^


def _dec_dtypes() -> List[UInt8]:
    var dts = List[UInt8]()
    dts.append(CELL_DT_DECIMAL128)
    return dts^


# The int128-straddle value set (precision/scale = 0 for the test; the compare
# is scale-uniform so the raw int128 ordering == decimal ordering).
#   row 0:  3                 (small, < 5)
#   row 1:  5                 (== 5)
#   row 2:  8                 (small, > 5)
#   row 3:  2^64              (STRADDLE: low-64 == 0; i64-low read => 0 < 5,
#                              int128 read => huge > 5)
#   row 4:  2^63              (STRADDLE: low-64 == Int64.MIN as i64,
#                              int128 read => large positive)
#   row 5:  -7                (negative, < 5)
def _straddle_vals() -> List[SIMD[DType.int128, 1]]:
    var two_64: SIMD[DType.int128, 1] = SIMD[DType.int128, 1](1) << 64
    var two_63: SIMD[DType.int128, 1] = SIMD[DType.int128, 1](1) << 63
    var vals = List[SIMD[DType.int128, 1]]()
    vals.append(SIMD[DType.int128, 1](3))
    vals.append(SIMD[DType.int128, 1](5))
    vals.append(SIMD[DType.int128, 1](8))
    vals.append(two_64)
    vals.append(two_63)
    vals.append(SIMD[DType.int128, 1](-7))
    return vals^


def _lit_spec(v: Int) -> List[DecimalSpec]:
    # scale 0, precision 38 — the literal's scale matches the column scale
    # (the gate enforces this; the walker does a raw same-scale int128 compare).
    var dp = List[DecimalSpec]()
    dp.append(DecimalSpec(SIMD[DType.int128, 1](v), 38, 0))
    return dp^


# =============================================================================
# §1 — dec_col > 5. Pool:
#   0: EXPR_COL_DECIMAL128(col0)
#   1: EXPR_LIT_DECIMAL128(decimal_pool 0 = 5)
#   2: EXPR_GT_DECIMAL128(0, 1)   ROOT
# Oracle: row selected iff (int128 value) > 5. The 2^64 and 2^63 rows are
# selected by the int128 read (both huge positive) but DROPPED by a buggy
# i64-low read (which reads them as 0 / Int64.MIN respectively).
# =============================================================================
def test_dec_gt() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col_decimal128(0))   # 0
    pool.append(make_lit_decimal128(0))   # 1
    pool.append(make_gt_decimal128(0, 1))  # 2 ROOT

    var vals = _straddle_vals()
    var rb = _build_dec_block(vals)
    var cs = RowCellSource(rb, _dec_offsets(), _dec_dtypes())
    var exec = ExpressionExecutor(
        pool^, 2, List[String](), List[String](), _lit_spec(5)
    )

    var lit5: SIMD[DType.int128, 1] = SIMD[DType.int128, 1](5)
    for r in range(rb.n_rows):
        var got = exec._eval_bool_from_source(cs, 2, r)
        var want = Bool(vals[r] > lit5)
        assert_equal(
            got, want,
            "dec>5 row " + String(r),
        )


# =============================================================================
# §2 — dec_col < 5. Mirror of §1.
# Oracle: row selected iff value < 5. The straddle rows (2^64, 2^63) are NOT
# selected by the int128 read (huge positive), but a buggy i64-low read would
# WRONGLY include them (low-64 reads 0 < 5 and Int64.MIN < 5).
# =============================================================================
def test_dec_lt() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col_decimal128(0))   # 0
    pool.append(make_lit_decimal128(0))   # 1
    pool.append(make_lt_decimal128(0, 1))  # 2 ROOT

    var vals = _straddle_vals()
    var rb = _build_dec_block(vals)
    var cs = RowCellSource(rb, _dec_offsets(), _dec_dtypes())
    var exec = ExpressionExecutor(
        pool^, 2, List[String](), List[String](), _lit_spec(5)
    )

    var lit5: SIMD[DType.int128, 1] = SIMD[DType.int128, 1](5)
    for r in range(rb.n_rows):
        var got = exec._eval_bool_from_source(cs, 2, r)
        var want = Bool(vals[r] < lit5)
        assert_equal(
            got, want,
            "dec<5 row " + String(r),
        )


# =============================================================================
# §3 — dec_col = 2^64. EQ against a STRADDLE literal: only a full int128 read
# matches the 2^64 row (its low-64 bits are 0, so a buggy i64-low read would
# match it against a literal whose low-64 is also 0 — but the int128 read
# distinguishes 2^64 from any value sharing its low word).
#   0: EXPR_COL_DECIMAL128(col0)
#   1: EXPR_LIT_DECIMAL128(decimal_pool 0 = 2^64)
#   2: EXPR_EQ_DECIMAL128(0, 1)   ROOT
# Oracle: row selected iff value == 2^64 (only row 3).
# =============================================================================
def test_dec_eq_straddle() raises:
    var two_64: SIMD[DType.int128, 1] = SIMD[DType.int128, 1](1) << 64
    var pool = List[RuntimeExpr]()
    pool.append(make_col_decimal128(0))   # 0
    pool.append(make_lit_decimal128(0))   # 1
    pool.append(make_eq_decimal128(0, 1))  # 2 ROOT

    var dp = List[DecimalSpec]()
    dp.append(DecimalSpec(two_64, 38, 0))

    var vals = _straddle_vals()
    var rb = _build_dec_block(vals)
    var cs = RowCellSource(rb, _dec_offsets(), _dec_dtypes())
    var exec = ExpressionExecutor(
        pool^, 2, List[String](), List[String](), dp^
    )

    for r in range(rb.n_rows):
        var got = exec._eval_bool_from_source(cs, 2, r)
        var want = Bool(vals[r] == two_64)
        assert_equal(
            got, want,
            "dec=2^64 row " + String(r),
        )


def main() raises:
    var suite = TestSuite()
    suite.test[test_dec_gt]()
    suite.test[test_dec_lt]()
    suite.test[test_dec_eq_straddle]()
    suite^.run()
