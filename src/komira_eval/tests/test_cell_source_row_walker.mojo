# =============================================================================
# test_cell_source_row_walker — the CellSource-parametric
# per-cell walker on ExpressionExecutor evaluates a runtime Expr over a
# row-major RowBlock via RowCellSource.
#
# Proves the row orientation works through the SHARED walker body. The
# column orientation is
# unaffected (its production path is the untouched _*_from_view SIMD walker;
# this test exercises the per-cell shape against in-memory RowBlocks).
#
# Subtests:
#   1. Single I64 comparison      col0 > 50
#   2. I64 AND chain              col0 >= 10 AND col1 < 100
#   3. F64 comparison             col2 <= 5.0   (F64 cell, widened read)
#   4. OR combinator              col0 < 5 OR col0 > 95
#   5. I64 arithmetic in predicate (col0 + col1) > 100
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_eval.cell_source import (
    RowCellSource,
    CELL_DT_I64,
    CELL_DT_F64,
)
from komira_eval.expression_executor import ExpressionExecutor
from komira_eval.row_format import RowBlock
from komira_eval.runtime_expr import (
    RuntimeExpr,
    make_col,
    make_lit_i64,
    make_lit_f64,
    make_gt_i64,
    make_ge_i64,
    make_lt_i64,
    make_le_f64,
    make_and,
    make_or,
    make_add_i64,
)


# -----------------------------------------------------------------------------
# Helpers — build an in-memory RowBlock + a RowCellSource over it.
# -----------------------------------------------------------------------------
#
# Layout for tests 1/2/4/5: two I64 columns at offsets 0 and 8, stride 16.
# Layout for test 3:        one I64 col (off 0) + one F64 col (off 8), stride 16.


def _two_col_i64_block(
    a_vals: List[Int64], b_vals: List[Int64]
) raises -> RowBlock:
    var n = len(a_vals)
    var stride = 16
    var rb = RowBlock.with_capacity(n, 0, stride)
    rb.reserve_rows(n)
    for r in range(n):
        rb.write_fixed[DType.int64](r, 0, a_vals[r])
        rb.write_fixed[DType.int64](r, 8, b_vals[r])
    rb.set_n_rows(n)
    return rb^


def _i64_f64_block(a_vals: List[Int64], c_vals: List[Float64]) raises -> RowBlock:
    var n = len(a_vals)
    var stride = 16
    var rb = RowBlock.with_capacity(n, 0, stride)
    rb.reserve_rows(n)
    for r in range(n):
        rb.write_fixed[DType.int64](r, 0, a_vals[r])
        rb.write_fixed[DType.float64](r, 8, c_vals[r])
    rb.set_n_rows(n)
    return rb^


def _offsets_two_i64() -> List[Int]:
    var o = List[Int]()
    o.append(0)
    o.append(8)
    return o^


def _dtypes_two_i64() -> List[UInt8]:
    var d = List[UInt8]()
    d.append(CELL_DT_I64)
    d.append(CELL_DT_I64)
    return d^


def _names_two() -> List[String]:
    var n = List[String]()
    n.append(String("col0"))
    n.append(String("col1"))
    return n^


# -----------------------------------------------------------------------------
# 1. Single I64 comparison: col0 > 50
# -----------------------------------------------------------------------------


def test_single_i64_gt() raises:
    # Rows: col0 = [10, 60, 50, 99, 51], col1 unused (zeros).
    var a = List[Int64]()
    a.append(10)
    a.append(60)
    a.append(50)
    a.append(99)
    a.append(51)
    var b = List[Int64]()
    for _ in range(5):
        b.append(0)
    var rb = _two_col_i64_block(a, b)

    # Pool: [col(0), lit(50), gt(0,1)]
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))  # slot 0: col0
    pool.append(make_lit_i64(50))  # slot 1: 50
    pool.append(make_gt_i64(0, 1))  # slot 2: col0 > 50
    var exec = ExpressionExecutor(pool^, 2, _names_two())

    var src = RowCellSource(rb, _offsets_two_i64(), _dtypes_two_i64())
    var sel = exec.select_filter_from_source(src)

    # col0 > 50 -> rows 1 (60), 3 (99), 4 (51).
    assert_equal(sel.len(), 3)
    assert_equal(Int(sel.get(0)), 1)
    assert_equal(Int(sel.get(1)), 3)
    assert_equal(Int(sel.get(2)), 4)


# -----------------------------------------------------------------------------
# 2. I64 AND chain: col0 >= 10 AND col1 < 100
# -----------------------------------------------------------------------------


def test_i64_and_chain() raises:
    # col0 = [5, 10, 20, 30], col1 = [50, 99, 100, 80]
    var a = List[Int64]()
    a.append(5)
    a.append(10)
    a.append(20)
    a.append(30)
    var b = List[Int64]()
    b.append(50)
    b.append(99)
    b.append(100)
    b.append(80)
    var rb = _two_col_i64_block(a, b)

    # Pool: col0(0) lit10(1) ge(0,1)=2 ; col1(3) lit100(4) lt(3,4)=5 ; and(2,5)=6
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))  # 0
    pool.append(make_lit_i64(10))  # 1
    pool.append(make_ge_i64(0, 1))  # 2: col0 >= 10
    pool.append(make_col(1))  # 3
    pool.append(make_lit_i64(100))  # 4
    pool.append(make_lt_i64(3, 4))  # 5: col1 < 100
    pool.append(make_and(2, 5))  # 6
    var exec = ExpressionExecutor(pool^, 6, _names_two())

    var src = RowCellSource(rb, _offsets_two_i64(), _dtypes_two_i64())
    var sel = exec.select_filter_from_source(src)

    # row0: 5>=10 F. row1: 10>=10 T, 99<100 T -> keep. row2: 20>=10 T, 100<100 F.
    # row3: 30>=10 T, 80<100 T -> keep.
    assert_equal(sel.len(), 2)
    assert_equal(Int(sel.get(0)), 1)
    assert_equal(Int(sel.get(1)), 3)


# -----------------------------------------------------------------------------
# 3. F64 comparison: col1 <= 5.0  (F64 cell read)
# -----------------------------------------------------------------------------


def test_f64_le() raises:
    var a = List[Int64]()
    for _ in range(4):
        a.append(0)
    var c = List[Float64]()
    c.append(3.0)
    c.append(5.0)
    c.append(5.5)
    c.append(1.0)
    var rb = _i64_f64_block(a, c)

    # Pool: col1(0) lit5.0(1) le(0,1)=2.  col_idx 1 in source = the F64 col.
    var pool = List[RuntimeExpr]()
    pool.append(make_col(1))  # 0: references col_idx 1 (the F64 col)
    pool.append(make_lit_f64(5.0))  # 1
    pool.append(make_le_f64(0, 1))  # 2
    var exec = ExpressionExecutor(pool^, 2, _names_two())

    var offs = _offsets_two_i64()
    var dts = List[UInt8]()
    dts.append(CELL_DT_I64)  # col0 = i64
    dts.append(CELL_DT_F64)  # col1 = f64
    var src = RowCellSource(rb, offs^, dts^)
    var sel = exec.select_filter_from_source(src)

    # <= 5.0 -> rows 0 (3.0), 1 (5.0), 3 (1.0)
    assert_equal(sel.len(), 3)
    assert_equal(Int(sel.get(0)), 0)
    assert_equal(Int(sel.get(1)), 1)
    assert_equal(Int(sel.get(2)), 3)


# -----------------------------------------------------------------------------
# 4. OR combinator: col0 < 5 OR col0 > 95
# -----------------------------------------------------------------------------


def test_or_combinator() raises:
    var a = List[Int64]()
    a.append(2)
    a.append(50)
    a.append(96)
    a.append(5)
    a.append(99)
    var b = List[Int64]()
    for _ in range(5):
        b.append(0)
    var rb = _two_col_i64_block(a, b)

    # col0(0) lit5(1) lt(0,1)=2 ; col0(3) lit95(4) gt(3,4)=5 ; or(2,5)=6
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))  # 0
    pool.append(make_lit_i64(5))  # 1
    pool.append(make_lt_i64(0, 1))  # 2: col0 < 5
    pool.append(make_col(0))  # 3
    pool.append(make_lit_i64(95))  # 4
    pool.append(make_gt_i64(3, 4))  # 5: col0 > 95
    pool.append(make_or(2, 5))  # 6
    var exec = ExpressionExecutor(pool^, 6, _names_two())

    var src = RowCellSource(rb, _offsets_two_i64(), _dtypes_two_i64())
    var sel = exec.select_filter_from_source(src)

    # row0: 2<5 T. row1: 50 neither. row2: 96>95 T. row3: 5 neither (5<5 F,
    # 5>95 F). row4: 99>95 T.
    assert_equal(sel.len(), 3)
    assert_equal(Int(sel.get(0)), 0)
    assert_equal(Int(sel.get(1)), 2)
    assert_equal(Int(sel.get(2)), 4)


# -----------------------------------------------------------------------------
# 5. I64 arithmetic in predicate: (col0 + col1) > 100
# -----------------------------------------------------------------------------


def test_i64_arith_predicate() raises:
    var a = List[Int64]()
    a.append(40)
    a.append(60)
    a.append(50)
    var b = List[Int64]()
    b.append(50)
    b.append(50)
    b.append(51)
    var rb = _two_col_i64_block(a, b)

    # col0(0) col1(1) add(0,1)=2 ; lit100(3) ; gt(2,3)=4
    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))  # 0
    pool.append(make_col(1))  # 1
    pool.append(make_add_i64(0, 1))  # 2: col0 + col1
    pool.append(make_lit_i64(100))  # 3
    pool.append(make_gt_i64(2, 3))  # 4: (col0+col1) > 100
    var exec = ExpressionExecutor(pool^, 4, _names_two())

    var src = RowCellSource(rb, _offsets_two_i64(), _dtypes_two_i64())
    var sel = exec.select_filter_from_source(src)

    # row0: 90 > 100 F. row1: 110 > 100 T. row2: 101 > 100 T.
    assert_equal(sel.len(), 2)
    assert_equal(Int(sel.get(0)), 1)
    assert_equal(Int(sel.get(1)), 2)


def main() raises:
    test_single_i64_gt()
    test_i64_and_chain()
    test_f64_le()
    test_or_combinator()
    test_i64_arith_predicate()
    print("test_cell_source_row_walker: ALL 5 subtests PASS")
