# =============================================================================
# test_row_filter_nullable_3vl_skip — 3VL null-skip in the row-native FILTER
# comparison path.
#
# A row-native `WHERE nullable_col <op> X` must EXCLUDE rows where the column
# cell is SQL-NULL — `NULL <op> X` is UNKNOWN, and a WHERE drops UNKNOWN. The
# per-cell comparison walker (`_eval_bool_from_source`) reads the NULL cell's
# stored value (garbage / a default) and compares it directly; without a 3VL
# guard at the `select_filter_from_source` seam a NULL row whose stored value
# happens to satisfy the predicate is WRONGLY KEPT.
#
# This drives `ExpressionExecutor.select_filter_from_source[RowCellSource]`
# directly over a hand-built nullable RowBlock (FORM-ii validity bitmap) — the
# exact production path the row-streaming filter walker calls. The
# oracle is hand-computed SQL 3VL: NULL rows EXCLUDED for every operator.
#
# Subtests (each: a NULL cell whose STORED value would satisfy the predicate
#            if read directly — proving the read-the-garbage bug, not just a
#            value that happens to fail):
#   1. col0 <  X   NULL stored 0  (0 < 50 would keep)   -> NULL excluded
#   2. col0 >  X   NULL stored 99 (99 > 50 would keep)  -> NULL excluded
#   3. col0 <= X   NULL stored 0                         -> NULL excluded
#   4. col0 >= X   NULL stored 99                        -> NULL excluded
#   5. col0 == X   NULL stored 50 (== literal)           -> NULL excluded
#   6. col0 != X   NULL stored 0  (0 != 50 would keep)   -> NULL excluded
#   7. F64 col1 < X NULL stored 0.0                       -> NULL excluded
#   8. AND chain: col0 < X AND col1 < Y, NULL in col0     -> NULL excluded
#   9. non-nullable layout (has_validity=False) byte-identical: present rows
#      keep, no spurious change.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

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
    make_le_i64,
    make_eq_i64,
    make_ne_i64,
    make_lt_f64,
    make_and,
)


# -----------------------------------------------------------------------------
# Helpers — a nullable 2-column block (col0 i64 @0, col1 f64 @8), validity
# bitmap @ offset 16 (1 byte covers 2 cols), stride 17.
# -----------------------------------------------------------------------------

comptime _STRIDE = 17
comptime _VALIDITY_OFFSET = 16


def _offsets_two() -> List[Int]:
    var o = List[Int]()
    o.append(0)
    o.append(8)
    return o^


def _dtypes_two() -> List[UInt8]:
    var d = List[UInt8]()
    d.append(CELL_DT_I64)
    d.append(CELL_DT_F64)
    return d^


def _names_two() -> List[String]:
    var n = List[String]()
    n.append(String("col0"))
    n.append(String("col1"))
    return n^


# Build a nullable block. `c0` / `c1` are the STORED cell values; `c0_null` /
# `c1_null` mark which rows have a NULL bit set (the stored value is then the
# garbage the comparison would read if there were no 3VL guard).
def _nullable_block(
    c0: List[Int64],
    c1: List[Float64],
    c0_null: List[Bool],
    c1_null: List[Bool],
) raises -> RowBlock:
    var n = len(c0)
    var rb = RowBlock.with_capacity(n, 0, _STRIDE)
    rb.reserve_rows(n)
    for r in range(n):
        rb.write_fixed[DType.int64](r, 0, c0[r])
        rb.write_fixed[DType.float64](r, 8, c1[r])
        if c0_null[r]:
            rb.set_cell_null(r, _VALIDITY_OFFSET, 0)
        if c1_null[r]:
            rb.set_cell_null(r, _VALIDITY_OFFSET, 1)
    rb.set_n_rows(n)
    return rb^


# -----------------------------------------------------------------------------
# 1. col0 < 50 ; row1 col0 is NULL, stored 0 (0 < 50 would WRONGLY keep).
# -----------------------------------------------------------------------------
def test_lt_excludes_null() raises:
    # col0 = [10, 0(NULL), 60, 5], -> present rows that pass: 10, 5 (rows 0, 3).
    var c0 = List[Int64]()
    c0.append(10)
    c0.append(0)  # NULL row, stored 0
    c0.append(60)
    c0.append(5)
    var c1 = List[Float64]()
    for _ in range(4):
        c1.append(0.0)
    var c0n = List[Bool]()
    c0n.append(False)
    c0n.append(True)  # row1 col0 NULL
    c0n.append(False)
    c0n.append(False)
    var c1n = List[Bool]()
    for _ in range(4):
        c1n.append(False)
    var rb = _nullable_block(c0, c1, c0n, c1n)

    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    pool.append(make_lit_i64(50))
    pool.append(make_lt_i64(0, 1))  # col0 < 50
    var exec = ExpressionExecutor(pool^, 2, _names_two())
    var src = RowCellSource(
        rb,
        _offsets_two(),
        _dtypes_two(),
        col_scales=List[Int](),
        has_validity=True,
        validity_offset=_VALIDITY_OFFSET,
    )
    var sel = exec.select_filter_from_source(src)

    # Oracle: NULL row excluded. Pass rows: 0 (10), 3 (5). NOT row1 (NULL).
    assert_equal(sel.len(), 2)
    assert_equal(Int(sel.get(0)), 0)
    assert_equal(Int(sel.get(1)), 3)


# -----------------------------------------------------------------------------
# 2. col0 > 50 ; row1 col0 NULL stored 99 (99 > 50 would WRONGLY keep).
# -----------------------------------------------------------------------------
def test_gt_excludes_null() raises:
    var c0 = List[Int64]()
    c0.append(60)
    c0.append(99)  # NULL row, stored 99
    c0.append(10)
    c0.append(70)
    var c1 = List[Float64]()
    for _ in range(4):
        c1.append(0.0)
    var c0n = List[Bool]()
    c0n.append(False)
    c0n.append(True)
    c0n.append(False)
    c0n.append(False)
    var c1n = List[Bool]()
    for _ in range(4):
        c1n.append(False)
    var rb = _nullable_block(c0, c1, c0n, c1n)

    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    pool.append(make_lit_i64(50))
    pool.append(make_gt_i64(0, 1))  # col0 > 50
    var exec = ExpressionExecutor(pool^, 2, _names_two())
    var src = RowCellSource(
        rb,
        _offsets_two(),
        _dtypes_two(),
        col_scales=List[Int](),
        has_validity=True,
        validity_offset=_VALIDITY_OFFSET,
    )
    var sel = exec.select_filter_from_source(src)

    # Pass rows: 0 (60), 3 (70). NOT row1 (NULL stored 99).
    assert_equal(sel.len(), 2)
    assert_equal(Int(sel.get(0)), 0)
    assert_equal(Int(sel.get(1)), 3)


# -----------------------------------------------------------------------------
# 3. col0 <= 50 ; NULL stored 0 (0 <= 50 would WRONGLY keep).
# -----------------------------------------------------------------------------
def test_le_excludes_null() raises:
    var c0 = List[Int64]()
    c0.append(50)
    c0.append(0)  # NULL
    c0.append(51)
    var c1 = List[Float64]()
    for _ in range(3):
        c1.append(0.0)
    var c0n = List[Bool]()
    c0n.append(False)
    c0n.append(True)
    c0n.append(False)
    var c1n = List[Bool]()
    for _ in range(3):
        c1n.append(False)
    var rb = _nullable_block(c0, c1, c0n, c1n)

    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    pool.append(make_lit_i64(50))
    pool.append(make_le_i64(0, 1))  # col0 <= 50
    var exec = ExpressionExecutor(pool^, 2, _names_two())
    var src = RowCellSource(
        rb,
        _offsets_two(),
        _dtypes_two(),
        col_scales=List[Int](),
        has_validity=True,
        validity_offset=_VALIDITY_OFFSET,
    )
    var sel = exec.select_filter_from_source(src)

    # Pass: row0 (50). NOT row1 (NULL), NOT row2 (51>50).
    assert_equal(sel.len(), 1)
    assert_equal(Int(sel.get(0)), 0)


# -----------------------------------------------------------------------------
# 4. col0 >= 50 ; NULL stored 99 (99 >= 50 would WRONGLY keep).
# -----------------------------------------------------------------------------
def test_ge_excludes_null() raises:
    var c0 = List[Int64]()
    c0.append(49)
    c0.append(99)  # NULL
    c0.append(50)
    var c1 = List[Float64]()
    for _ in range(3):
        c1.append(0.0)
    var c0n = List[Bool]()
    c0n.append(False)
    c0n.append(True)
    c0n.append(False)
    var c1n = List[Bool]()
    for _ in range(3):
        c1n.append(False)
    var rb = _nullable_block(c0, c1, c0n, c1n)

    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    pool.append(make_lit_i64(50))
    pool.append(make_ge_i64(0, 1))  # col0 >= 50
    var exec = ExpressionExecutor(pool^, 2, _names_two())
    var src = RowCellSource(
        rb,
        _offsets_two(),
        _dtypes_two(),
        col_scales=List[Int](),
        has_validity=True,
        validity_offset=_VALIDITY_OFFSET,
    )
    var sel = exec.select_filter_from_source(src)

    # Pass: row2 (50). NOT row1 (NULL), NOT row0 (49<50).
    assert_equal(sel.len(), 1)
    assert_equal(Int(sel.get(0)), 2)


# -----------------------------------------------------------------------------
# 5. col0 == 50 ; NULL stored 50 (50 == 50 would WRONGLY keep).
# -----------------------------------------------------------------------------
def test_eq_excludes_null() raises:
    var c0 = List[Int64]()
    c0.append(50)
    c0.append(50)  # NULL stored 50
    c0.append(40)
    var c1 = List[Float64]()
    for _ in range(3):
        c1.append(0.0)
    var c0n = List[Bool]()
    c0n.append(False)
    c0n.append(True)
    c0n.append(False)
    var c1n = List[Bool]()
    for _ in range(3):
        c1n.append(False)
    var rb = _nullable_block(c0, c1, c0n, c1n)

    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    pool.append(make_lit_i64(50))
    pool.append(make_eq_i64(0, 1))  # col0 == 50
    var exec = ExpressionExecutor(pool^, 2, _names_two())
    var src = RowCellSource(
        rb,
        _offsets_two(),
        _dtypes_two(),
        col_scales=List[Int](),
        has_validity=True,
        validity_offset=_VALIDITY_OFFSET,
    )
    var sel = exec.select_filter_from_source(src)

    # Pass: row0 (50). NOT row1 (NULL stored 50), NOT row2 (40).
    assert_equal(sel.len(), 1)
    assert_equal(Int(sel.get(0)), 0)


# -----------------------------------------------------------------------------
# 6. col0 != 50 ; NULL stored 0 (0 != 50 would WRONGLY keep). SQL: NULL != X
#    is UNKNOWN -> excluded (NOT kept as "different").
# -----------------------------------------------------------------------------
def test_ne_excludes_null() raises:
    var c0 = List[Int64]()
    c0.append(40)
    c0.append(0)  # NULL stored 0 (0 != 50 true if read)
    c0.append(50)
    var c1 = List[Float64]()
    for _ in range(3):
        c1.append(0.0)
    var c0n = List[Bool]()
    c0n.append(False)
    c0n.append(True)
    c0n.append(False)
    var c1n = List[Bool]()
    for _ in range(3):
        c1n.append(False)
    var rb = _nullable_block(c0, c1, c0n, c1n)

    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    pool.append(make_lit_i64(50))
    pool.append(make_ne_i64(0, 1))  # col0 != 50
    var exec = ExpressionExecutor(pool^, 2, _names_two())
    var src = RowCellSource(
        rb,
        _offsets_two(),
        _dtypes_two(),
        col_scales=List[Int](),
        has_validity=True,
        validity_offset=_VALIDITY_OFFSET,
    )
    var sel = exec.select_filter_from_source(src)

    # Pass: row0 (40 != 50). NOT row1 (NULL), NOT row2 (50 == 50).
    assert_equal(sel.len(), 1)
    assert_equal(Int(sel.get(0)), 0)


# -----------------------------------------------------------------------------
# 7. F64 col1 < 5.0 ; NULL stored 0.0 (0.0 < 5.0 would WRONGLY keep).
# -----------------------------------------------------------------------------
def test_f64_lt_excludes_null() raises:
    var c0 = List[Int64]()
    for _ in range(3):
        c0.append(0)
    var c1 = List[Float64]()
    c1.append(3.0)
    c1.append(0.0)  # NULL stored 0.0
    c1.append(9.0)
    var c0n = List[Bool]()
    for _ in range(3):
        c0n.append(False)
    var c1n = List[Bool]()
    c1n.append(False)
    c1n.append(True)  # row1 col1 NULL
    c1n.append(False)
    var rb = _nullable_block(c0, c1, c0n, c1n)

    var pool = List[RuntimeExpr]()
    pool.append(make_col(1))  # col1 (the f64 col)
    pool.append(make_lit_f64(5.0))
    pool.append(make_lt_f64(0, 1))  # col1 < 5.0
    var exec = ExpressionExecutor(pool^, 2, _names_two())
    var src = RowCellSource(
        rb,
        _offsets_two(),
        _dtypes_two(),
        col_scales=List[Int](),
        has_validity=True,
        validity_offset=_VALIDITY_OFFSET,
    )
    var sel = exec.select_filter_from_source(src)

    # Pass: row0 (3.0). NOT row1 (NULL stored 0.0), NOT row2 (9.0).
    assert_equal(sel.len(), 1)
    assert_equal(Int(sel.get(0)), 0)


# -----------------------------------------------------------------------------
# 8. AND chain: col0 < 50 AND col1 < 5.0, NULL in col0 (stored 0). A NULL in
#    EITHER operand makes the whole predicate UNKNOWN -> excluded.
# -----------------------------------------------------------------------------
def test_and_chain_excludes_null() raises:
    var c0 = List[Int64]()
    c0.append(10)
    c0.append(0)  # NULL col0, stored 0
    c0.append(20)
    var c1 = List[Float64]()
    c1.append(3.0)
    c1.append(3.0)  # col1 present and would pass
    c1.append(9.0)
    var c0n = List[Bool]()
    c0n.append(False)
    c0n.append(True)  # row1 col0 NULL
    c0n.append(False)
    var c1n = List[Bool]()
    for _ in range(3):
        c1n.append(False)
    var rb = _nullable_block(c0, c1, c0n, c1n)

    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))  # 0
    pool.append(make_lit_i64(50))  # 1
    pool.append(make_lt_i64(0, 1))  # 2: col0 < 50
    pool.append(make_col(1))  # 3
    pool.append(make_lit_f64(5.0))  # 4
    pool.append(make_lt_f64(3, 4))  # 5: col1 < 5.0
    pool.append(make_and(2, 5))  # 6
    var exec = ExpressionExecutor(pool^, 6, _names_two())
    var src = RowCellSource(
        rb,
        _offsets_two(),
        _dtypes_two(),
        col_scales=List[Int](),
        has_validity=True,
        validity_offset=_VALIDITY_OFFSET,
    )
    var sel = exec.select_filter_from_source(src)

    # row0: 10<50 T, 3.0<5 T -> keep. row1: col0 NULL -> UNKNOWN -> drop.
    # row2: 20<50 T, 9.0<5 F -> drop.
    assert_equal(sel.len(), 1)
    assert_equal(Int(sel.get(0)), 0)


# -----------------------------------------------------------------------------
# 9. Non-nullable layout (has_validity=False): the 3VL guard is skipped, the
#    path is byte-identical. Every present row that satisfies the predicate is
#    kept (no spurious exclusion).
# -----------------------------------------------------------------------------
def test_non_nullable_byte_identical() raises:
    var c0 = List[Int64]()
    c0.append(10)
    c0.append(60)
    c0.append(5)
    var c1 = List[Float64]()
    for _ in range(3):
        c1.append(0.0)
    var rb = RowBlock.with_capacity(3, 0, 16)  # NO validity region, stride 16
    rb.reserve_rows(3)
    for r in range(3):
        rb.write_fixed[DType.int64](r, 0, c0[r])
        rb.write_fixed[DType.float64](r, 8, c1[r])
    rb.set_n_rows(3)

    var pool = List[RuntimeExpr]()
    pool.append(make_col(0))
    pool.append(make_lit_i64(50))
    pool.append(make_lt_i64(0, 1))  # col0 < 50
    var exec = ExpressionExecutor(pool^, 2, _names_two())
    var src = RowCellSource(
        rb,
        _offsets_two(),
        _dtypes_two(),
        col_scales=List[Int](),
        has_validity=False,
        validity_offset=0,
    )
    var sel = exec.select_filter_from_source(src)

    # Pass: row0 (10), row2 (5). NOT row1 (60).
    assert_equal(sel.len(), 2)
    assert_equal(Int(sel.get(0)), 0)
    assert_equal(Int(sel.get(1)), 2)


def main() raises:
    test_lt_excludes_null()
    test_gt_excludes_null()
    test_le_excludes_null()
    test_ge_excludes_null()
    test_eq_excludes_null()
    test_ne_excludes_null()
    test_f64_lt_excludes_null()
    test_and_chain_excludes_null()
    test_non_nullable_byte_identical()
    print("test_row_filter_nullable_3vl_skip: ALL 9 subtests PASS")
