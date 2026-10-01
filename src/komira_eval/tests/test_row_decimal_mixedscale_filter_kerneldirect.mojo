# =============================================================================
# test_row_decimal_mixedscale_filter_kerneldirect.mojo — MIXED-SCALE DECIMAL128
# row-native FILTER walker. Kernel-direct.
#
# WHAT THIS GUARDS: SAME-scale DECIMAL128 filters compare raw int128 values;
# MIXED-scale filters need a SCALE-AWARE compare. The per-cell ROW walker has it, so mixed-scale
# DECIMAL128 filters serve ROW-native (4-path invariant: a row plan must NOT
# demote for capability reasons). The walker threads per-column scale (a
# `col_scales` side-table on RowCellSource) and resolves each operand's scale
# (column -> col_scales; literal -> decimal_pool.scale), passing both to the
# column oracle `_compare_decimal128` (which rescales the smaller-scale operand
# UP via an i256 intermediate). The result must be VALUE-IDENTICAL to the column
# demote target it replaces.
#
# THE MIXED-SCALE STRADDLE (the discriminator a buggy raw-int128 compare fails):
#   * col `d` @ SCALE 2 vs literal 100 @ SCALE 0 (100.0):
#       9999  @ s2 = 99.99  : raw 9999 > 100 would KEEP; scale-aware 99.99 > 100.0
#                             is FALSE -> DROP. (the discriminator)
#       10001 @ s2 = 100.01 : 100.01 > 100.0 -> KEEP.
#       12345 @ s2 = 123.45 : 123.45 > 100.0 -> KEEP.
#       5000  @ s2 = 50.00  : 50.00 > 100.0 -> DROP.
#   * col-vs-col: `a` @ SCALE 2 vs `b` @ SCALE 3 (the col-vs-col case that can
#     NEVER be normalized away by a literal-scale rewrite — genuinely reachable):
#       a=12345 @ s2 (123.45) vs b=123450 @ s3 (123.450): EQUAL (raw 12345<123450
#                             would say a<b WRONG). a < b is FALSE.
#       a=99990 @ s2 (999.90) vs b=999900 @ s3 (999.900): EQUAL. a < b FALSE.
#       a=10000 @ s2 (100.00) vs b=200000 @ s3 (200.000): 100.0 < 200.0 -> TRUE.
#
# WHY KERNEL-DIRECT: `ctx.materialize` would compile the full plan dispatch
# tree, a large comptime instantiation this test avoids. It drives the production
# per-cell walker `_eval_bool_from_source[RowCellSource]` over a hand-built
# RowBlock with a `col_scales` side-table; assert vs a SQL hand oracle. NO ctx,
# NO read_csv, NO collect, NO materialize.
#
# Encapsulation: NO UnsafePointer / wildcard origins /
# unsafe_from_address / take_pointee. Public eval surface + RowBlock public reads
# only. `fn` style (match surrounding code).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_eval.row_format import RowBlock
from komira_eval.cell_source import (
    RowCellSource,
    CELL_DT_DECIMAL128,
)
from komira_eval.expression_executor import (
    ExpressionExecutor,
    DecimalSpec,
)
from komira_eval.runtime_expr import (
    RuntimeExpr,
    make_col_decimal128,
    make_lit_decimal128,
    make_gt_decimal128,
    make_lt_decimal128,
    make_eq_decimal128,
)


# -----------------------------------------------------------------------------
# A single DECIMAL128 column `d` @ scale 2 (16-byte cell @ offset 0; stride 16).
# -----------------------------------------------------------------------------
comptime _D_OFF: Int = 0
comptime _D_STRIDE: Int = 16


def _d_offsets() -> List[Int]:
    var offs = List[Int]()
    offs.append(_D_OFF)
    return offs^


def _d_dtypes() -> List[UInt8]:
    var dts = List[UInt8]()
    dts.append(CELL_DT_DECIMAL128)
    return dts^


def _d_scales(scale: Int) -> List[Int]:
    var sc = List[Int]()
    sc.append(scale)
    return sc^


def _i128s(*vals: Int) -> List[SIMD[DType.int128, 1]]:
    var out = List[SIMD[DType.int128, 1]]()
    for v in vals:
        out.append(SIMD[DType.int128, 1](v))
    return out^


def _build_dec_block(vals: List[SIMD[DType.int128, 1]]) raises -> RowBlock:
    var n = len(vals)
    var rb = RowBlock.with_capacity(n, 0, _D_STRIDE)
    for i in range(n):
        rb.write_fixed[DType.int128](i, _D_OFF, vals[i])
    rb.set_n_rows(n)
    return rb^


# =============================================================================
# (1) col-vs-literal MIXED-scale: col `d` @ s2 vs literal 100 @ s0 (100.0).
#     Predicate `d > 100.0`. SQL-correct (scale-aware) keeps {10001, 12345};
#     drops {9999, 5000}. A raw-int128 compare bug would WRONGLY keep 9999.
# =============================================================================
def test_mixedscale_col_vs_literal_gt() raises:
    var vals = _i128s(9999, 12345, 5000, 10001)  # 99.99, 123.45, 50.00, 100.01
    var rb = _build_dec_block(vals)
    var cs = RowCellSource(
        rb, _d_offsets(), _d_dtypes(), col_scales=_d_scales(2),
    )

    # pool: [0: COL(d)] [1: LIT(100 @ s0)] [2: GT(0, 1)] ROOT=2.
    var pool = List[RuntimeExpr]()
    pool.append(make_col_decimal128(0))
    pool.append(make_lit_decimal128(0))
    pool.append(make_gt_decimal128(0, 1))
    var dpool = List[DecimalSpec]()
    dpool.append(DecimalSpec(SIMD[DType.int128, 1](100), 38, 0))  # 100.0 @ s0
    var exec = ExpressionExecutor(
        pool^, 2, List[String](), List[String](), decimal_pool=dpool^,
    )

    # SQL oracle: d > 100.0 -> keep rows 1 (123.45), 3 (100.01); drop 0, 2.
    var want = List[Bool]()
    want.append(False)  # 99.99 > 100.0 ? no
    want.append(True)   # 123.45 > 100.0 ? yes
    want.append(False)  # 50.00 > 100.0 ? no
    want.append(True)   # 100.01 > 100.0 ? yes
    for r in range(rb.n_rows):
        var got = exec._eval_bool_from_source(cs, 2, r)
        assert_equal(
            got, want[r],
            "mixed-scale col>lit: d[" + String(r) + "] > 100.0 (scale-aware)",
        )


# =============================================================================
# (2) col-vs-col MIXED-scale: col `a` @ s2 vs col `b` @ s3. This case can NEVER
#     be normalized away by a literal-scale rewrite (both are columns) — the
#     genuinely-reachable mixed-scale shape. Predicate `a < b`.
# =============================================================================
comptime _AB_OFF_A: Int = 0
comptime _AB_OFF_B: Int = 16
comptime _AB_STRIDE: Int = 32


def _ab_offsets() -> List[Int]:
    var offs = List[Int]()
    offs.append(_AB_OFF_A)
    offs.append(_AB_OFF_B)
    return offs^


def _ab_dtypes() -> List[UInt8]:
    var dts = List[UInt8]()
    dts.append(CELL_DT_DECIMAL128)
    dts.append(CELL_DT_DECIMAL128)
    return dts^


def _ab_scales() -> List[Int]:
    var sc = List[Int]()
    sc.append(2)  # col a @ s2
    sc.append(3)  # col b @ s3
    return sc^


def _build_ab_block(
    a: List[SIMD[DType.int128, 1]], b: List[SIMD[DType.int128, 1]]
) raises -> RowBlock:
    var n = len(a)
    var rb = RowBlock.with_capacity(n, 0, _AB_STRIDE)
    for i in range(n):
        rb.write_fixed[DType.int128](i, _AB_OFF_A, a[i])
        rb.write_fixed[DType.int128](i, _AB_OFF_B, b[i])
    rb.set_n_rows(n)
    return rb^


def test_mixedscale_col_vs_col_lt() raises:
    # a @ s2 logical; b @ s3 logical.
    var a = _i128s(12345, 99990, 10000)   # 123.45, 999.90, 100.00
    var b = _i128s(123450, 999900, 200000)  # 123.450, 999.900, 200.000
    var rb = _build_ab_block(a, b)
    var cs = RowCellSource(
        rb, _ab_offsets(), _ab_dtypes(), col_scales=_ab_scales(),
    )

    # pool: [0: COL(a)] [1: COL(b)] [2: LT(0, 1)] ROOT=2.
    var pool = List[RuntimeExpr]()
    pool.append(make_col_decimal128(0))
    pool.append(make_col_decimal128(1))
    pool.append(make_lt_decimal128(0, 1))
    var exec = ExpressionExecutor(
        pool^, 2, List[String](), List[String](),
    )

    # SQL oracle (scale-aware): 123.45 < 123.450 ? equal -> False;
    #                           999.90 < 999.900 ? equal -> False;
    #                           100.00 < 200.000 ? -> True.
    # A raw int128 compare (12345 < 123450) would WRONGLY say row0 True.
    var want = List[Bool]()
    want.append(False)
    want.append(False)
    want.append(True)
    for r in range(rb.n_rows):
        var got = exec._eval_bool_from_source(cs, 2, r)
        assert_equal(
            got, want[r],
            "mixed-scale col<col: a[" + String(r) + "] < b (scale-aware)",
        )


# =============================================================================
# (3) col-vs-col MIXED-scale EQ: the EQUAL-after-rescale straddle. a @ s2 vs
#     b @ s3, a == b iff logical values match. Confirms EQ rescales too.
# =============================================================================
def test_mixedscale_col_vs_col_eq() raises:
    var a = _i128s(12345, 50000, 10001)   # 123.45, 500.00, 100.01
    var b = _i128s(123450, 500001, 100010)  # 123.450, 500.001, 100.010
    var rb = _build_ab_block(a, b)
    var cs = RowCellSource(
        rb, _ab_offsets(), _ab_dtypes(), col_scales=_ab_scales(),
    )

    var pool = List[RuntimeExpr]()
    pool.append(make_col_decimal128(0))
    pool.append(make_col_decimal128(1))
    pool.append(make_eq_decimal128(0, 1))
    var exec = ExpressionExecutor(
        pool^, 2, List[String](), List[String](),
    )

    # 123.45 == 123.450 -> True; 500.00 == 500.001 -> False;
    # 100.01 == 100.010 -> True.
    var want = List[Bool]()
    want.append(True)
    want.append(False)
    want.append(True)
    for r in range(rb.n_rows):
        var got = exec._eval_bool_from_source(cs, 2, r)
        assert_equal(
            got, want[r],
            "mixed-scale col==col: a[" + String(r) + "] == b (scale-aware)",
        )


def main() raises:
    var suite = TestSuite()
    suite.test[test_mixedscale_col_vs_literal_gt]()
    suite.test[test_mixedscale_col_vs_col_lt]()
    suite.test[test_mixedscale_col_vs_col_eq]()
    suite^.run()
