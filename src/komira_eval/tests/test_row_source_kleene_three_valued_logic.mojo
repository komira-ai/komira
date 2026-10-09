# =============================================================================
# SQL three-valued logic in the per-cell walker over a nullable row source
# (`ExpressionExecutor.select_filter_from_source` and the CASE condition of
# `_eval_i64_from_source`).
#
# A WHERE keeps a row only when its predicate is TRUE. Kleene's tables:
# `TRUE OR UNKNOWN = TRUE`, `FALSE AND UNKNOWN = FALSE`, `NOT UNKNOWN =
# UNKNOWN`. A value operand is NULL when any column it reads is NULL,
# including an operand computed by arithmetic.
#
# Fixture: a RowBlock with validity, three columns.
#
# | row | x (i64) | y (i64) | d (decimal128, scale 0) |
# |-----|---------|---------|-------------------------|
# | 0   | 5       | N/0     | 1                       |
# | 1   | -1      | N/0     | N/0                     |
# | 2   | 5       | 3       | 0                       |
#
# Every NULL cell stores 0, the value a walker blind to validity reads.
#
# Refs komira-ai/komira#932.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_eval.expression_executor import DecimalSpec, ExpressionExecutor
from komira_kernels.runtime_expr import (
    RuntimeExpr,
    make_add_i64,
    make_and,
    make_atan2_f64,
    make_date_trunc_i64,
    make_extract_i64,
    make_case_i64,
    make_ge_f64,
    make_ge_i64,
    make_i64_to_f64,
    make_lit_f64,
    make_null,
    make_col,
    make_col_decimal128,
    make_gt_decimal128,
    make_gt_i64,
    make_lit_decimal128,
    make_lit_i64,
    make_lt_i64,
    make_not_bool,
    make_or,
    make_pow_f64,
)
from komira_kernels.runtime_expr import (
    EXPR_DIV_I64,
    RT_EXTRACT_DAY,
    RT_TRUNC_MONTH,
)
from komira_row_format.cell_source import (
    CELL_DT_DECIMAL128,
    CELL_DT_I64,
    RowCellSource,
)
from komira_row_format.row_block import RowBlock


comptime _VALIDITY_OFFSET = 32
comptime _STRIDE = 33
comptime X = 0
comptime Y = 1
comptime D = 2


def _block() raises -> RowBlock:
    """The fixture in the file header."""
    var xs: List[Int] = [5, -1, 5]
    var ys: List[Int] = [0, 0, 3]
    var ds: List[Int] = [1, 0, 0]
    var rb = RowBlock.with_capacity(3, 0, _STRIDE)
    rb.reserve_rows(3)
    for r in range(3):
        rb.write_fixed[DType.int64](r, 0, Int64(xs[r]))
        rb.write_fixed[DType.int64](r, 8, Int64(ys[r]))
        rb.write_fixed[DType.int128](r, 16, SIMD[DType.int128, 1](ds[r]))
    rb.set_cell_null(0, _VALIDITY_OFFSET, Y)
    rb.set_cell_null(1, _VALIDITY_OFFSET, Y)
    rb.set_cell_null(1, _VALIDITY_OFFSET, D)
    rb.set_n_rows(3)
    return rb^


def _offsets() -> List[Int]:
    var o: List[Int] = [0, 8, 16]
    return o^


def _dtypes() -> List[UInt8]:
    var d = List[UInt8]()
    d.append(CELL_DT_I64)
    d.append(CELL_DT_I64)
    d.append(CELL_DT_DECIMAL128)
    return d^


def _names() -> List[String]:
    var n: List[String] = ["x", "y", "d"]
    return n^


def _exec(var pool: List[RuntimeExpr], root: Int = -1) -> ExpressionExecutor:
    """Decimal pool: 0 = 0 (scale 0)."""
    var r = root if root >= 0 else len(pool) - 1
    var decs = List[DecimalSpec]()
    decs.append(DecimalSpec(SIMD[DType.int128, 1](0), 38, 0))
    return ExpressionExecutor(pool^, r, _names(), List[String](), decs^)


def _filter(exec: ExpressionExecutor) raises -> List[Int]:
    var rb = _block()
    var src = RowCellSource(
        rb,
        _offsets(),
        _dtypes(),
        col_scales=[0, 0, 0],
        has_validity=True,
        validity_offset=_VALIDITY_OFFSET,
    )
    var sel = exec.select_filter_from_source(src)
    var out = List[Int]()
    for k in range(sel.len()):
        out.append(Int(sel.get(k)))
    return out^


def _expect(got: List[Int], want: List[Int], what: String) raises:
    var g = String("[")
    for v in got:
        g += String(v) + " "
    g += "]"
    assert_equal(len(got), len(want), what + ": survivor count, got " + g)
    for k in range(len(want)):
        assert_equal(got[k], want[k], what + ": survivor " + String(k) + ", got " + g)


def _x_gt0_y_gt0(var pool: List[RuntimeExpr]) -> List[RuntimeExpr]:
    """Appends slots 0..5: x, 0, x > 0 (2), y, 0, y > 0 (5)."""
    pool.append(make_col(X))
    pool.append(make_lit_i64(0))
    pool.append(make_gt_i64(0, 1))
    pool.append(make_col(Y))
    pool.append(make_lit_i64(0))
    pool.append(make_gt_i64(3, 4))
    return pool^


def test_true_or_null_is_true() raises:
    """`x > 0 OR y > 0` = T OR N, F OR N, T OR T -> [0, 2]. (#932 item 5)
    `y > 0 OR x > 0` puts the UNKNOWN side first: N OR T, N OR F, T OR T
    -> [0, 2]."""
    var pool = _x_gt0_y_gt0(List[RuntimeExpr]())
    pool.append(make_or(2, 5))
    _expect(_filter(_exec(pool^)), [0, 2], "x > 0 OR y > 0")
    var swapped = _x_gt0_y_gt0(List[RuntimeExpr]())
    swapped.append(make_or(5, 2))
    _expect(_filter(_exec(swapped^)), [0, 2], "y > 0 OR x > 0")


def test_not_of_false_and_null_is_true() raises:
    """`NOT (x < 0 AND y > 0)`: x < 0 = F, T, F; y > 0 = N, N, T.
    AND = F, N, F -> NOT = T, N, T -> [0, 2]. (#932 item 6)
    `NOT (x > 0 OR y > 0)`: OR = T, N, T -> NOT = F, N, F -> []."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(X))
    pool.append(make_lit_i64(0))
    pool.append(make_lt_i64(0, 1))   # 2: x < 0
    pool.append(make_col(Y))
    pool.append(make_lit_i64(0))
    pool.append(make_gt_i64(3, 4))   # 5: y > 0
    pool.append(make_and(2, 5))      # 6
    pool.append(make_not_bool(6))    # 7
    _expect(_filter(_exec(pool^)), [0, 2], "NOT (x < 0 AND y > 0)")
    var q = _x_gt0_y_gt0(List[RuntimeExpr]())
    q.append(make_or(2, 5))
    q.append(make_not_bool(6))
    _expect(_filter(_exec(q^)), List[Int](), "NOT (x > 0 OR y > 0)")


def test_decimal_operand_null_under_not() raises:
    """`NOT (d > 0)`: d > 0 = T, N, F -> NOT = F, N, T -> [2].
    Row 1 stores 0, so a walker that does not see the NULL keeps it.
    (#932 item 7)"""
    var pool = List[RuntimeExpr]()
    pool.append(make_col_decimal128(D))
    pool.append(make_lit_decimal128(0))
    pool.append(make_gt_decimal128(0, 1))
    pool.append(make_not_bool(2))
    _expect(_filter(_exec(pool^)), [2], "NOT (d > 0)")


def test_arithmetic_operand_over_a_null_column() raises:
    """`(y + 1) > 0`: y is NULL at rows 0 and 1, stored 0, so 0 + 1 > 0 would
    pass. SQL: [2]. (#932 item 8)
    `(x / y) > 0`: the NULL divisors store 0; the row is UNKNOWN and is not
    evaluated, so no division-by-zero error. SQL: [2]."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(Y))
    pool.append(make_lit_i64(1))
    pool.append(make_add_i64(0, 1))  # 2
    pool.append(make_lit_i64(0))
    pool.append(make_gt_i64(2, 3))
    _expect(_filter(_exec(pool^)), [2], "(y + 1) > 0")
    var q = List[RuntimeExpr]()
    q.append(make_col(X))
    q.append(make_col(Y))
    q.append(RuntimeExpr(EXPR_DIV_I64, Int64(0), 0.0, False, 0, 0, 1))  # 2
    q.append(make_lit_i64(0))
    q.append(make_gt_i64(2, 3))
    _expect(_filter(_exec(q^)), [2], "(x / y) > 0")


def test_null_operand_on_the_right() raises:
    """The NULL operand on the right of a compare and of a two-operand
    math function. y is NULL at rows 0 and 1, stored 0.
    `0 >= y`: 0 >= 0 would pass; row 2 is 0 >= 3. SQL: [].
    `pow(x, y) >= 0`: pow(5, 0) = pow(-1, 0) = 1 would pass. SQL: [2].
    `atan2(y, x) >= 0`, NULL on the left of atan2: atan2(0, 5) = 0 and
    atan2(0, -1) = pi would pass. SQL: [2]."""
    var p = List[RuntimeExpr]()
    p.append(make_lit_i64(0))
    p.append(make_col(Y))
    p.append(make_ge_i64(0, 1))      # 2: 0 >= y
    _expect(_filter(_exec(p^)), List[Int](), "0 >= y")
    var q = List[RuntimeExpr]()
    q.append(make_col(X))            # 0
    q.append(make_col(Y))            # 1
    q.append(make_pow_f64(0, 1))     # 2: pow(x, y)
    q.append(make_lit_f64(0.0))      # 3
    q.append(make_ge_f64(2, 3))
    _expect(_filter(_exec(q^)), [2], "pow(x, y) >= 0")
    var r = List[RuntimeExpr]()
    r.append(make_col(Y))            # 0
    r.append(make_col(X))            # 1
    r.append(make_atan2_f64(0, 1))   # 2: atan2(y, x)
    r.append(make_lit_f64(0.0))      # 3
    r.append(make_ge_f64(2, 3))
    _expect(_filter(_exec(r^)), [2], "atan2(y, x) >= 0")


def test_cast_case_and_null_operands() raises:
    """Operands NULL through a cast, a CASE branch and the NULL literal.

    `CAST(y AS double) >= 0.0`: y is NULL at rows 0, 1 (stored 0). SQL: [2].
    `(CASE WHEN x > 0 THEN y ELSE 1 END) >= 0`: rows 0 and 2 take y (NULL,
    3), row 1 takes 1. SQL: [1, 2]; a stored 0 for row 0 would pass.
    `(CASE WHEN x < 0 THEN NULL ELSE x END) >= 0`: row 1 takes NULL, whose
    value reads 0. SQL: [0, 2]."""
    var c = List[RuntimeExpr]()
    c.append(make_col(Y))
    c.append(make_i64_to_f64(0))
    c.append(make_lit_f64(0.0))
    c.append(make_ge_f64(1, 2))
    _expect(_filter(_exec(c^)), [2], "CAST(y AS double) >= 0.0")

    var p = List[RuntimeExpr]()
    p.append(make_col(X))            # 0
    p.append(make_lit_i64(0))        # 1
    p.append(make_gt_i64(0, 1))      # 2: x > 0
    p.append(make_col(Y))            # 3
    p.append(make_lit_i64(1))        # 4
    p.append(make_case_i64(0))       # 5
    p.append(make_lit_i64(0))        # 6
    p.append(make_ge_i64(5, 6))      # 7
    var slots: List[Int] = [2, 3, 4]
    var when = List[List[Int]]()
    when.append(slots^)
    _expect(
        _filter(ExpressionExecutor(p^, 7, _names(), when_pool=when^)),
        [1, 2],
        "CASE WHEN x > 0 THEN y ELSE 1 END >= 0",
    )

    var q = List[RuntimeExpr]()
    q.append(make_col(X))            # 0
    q.append(make_lit_i64(0))        # 1
    q.append(make_lt_i64(0, 1))      # 2: x < 0
    q.append(make_null())            # 3
    q.append(make_col(X))            # 4
    q.append(make_case_i64(0))       # 5
    q.append(make_lit_i64(0))        # 6
    q.append(make_ge_i64(5, 6))      # 7
    var slots2: List[Int] = [2, 3, 4]
    var when2 = List[List[Int]]()
    when2.append(slots2^)
    _expect(
        _filter(ExpressionExecutor(q^, 7, _names(), when_pool=when2^)),
        [0, 2],
        "CASE WHEN x < 0 THEN NULL ELSE x END >= 0",
    )


def test_extract_and_date_trunc_over_a_null_column() raises:
    """y read as Date32 days (ticks per day 1); NULL at rows 0, 1, stored 0
    (1970-01-01). Row 2 is day 3, 1970-01-04.
    `EXTRACT(day FROM y) >= 1`: the stored day is 1, which would pass.
    SQL: [2].
    `date_trunc('month', y) >= 0`: the stored day truncates to 0, which would
    pass. SQL: [2]."""
    var p = List[RuntimeExpr]()
    p.append(make_col(Y))                                # 0
    p.append(make_extract_i64(0, RT_EXTRACT_DAY, 1))     # 1
    p.append(make_lit_i64(1))                            # 2
    p.append(make_ge_i64(1, 2))
    _expect(_filter(_exec(p^)), [2], "EXTRACT(day FROM y) >= 1")
    var q = List[RuntimeExpr]()
    q.append(make_col(Y))                                # 0
    q.append(make_date_trunc_i64(0, RT_TRUNC_MONTH, 1))  # 1
    q.append(make_lit_i64(0))                            # 2
    q.append(make_ge_i64(1, 2))
    _expect(_filter(_exec(q^)), [2], "date_trunc('month', y) >= 0")


def test_case_condition_over_a_null_operand_is_not_true() raises:
    """CASE WHEN y < 1 THEN 1 ELSE 0: y < 1 = N, N, F -> [0, 0, 0].
    The NULL rows store 0, and 0 < 1 would take the THEN branch."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(Y))         # 0
    pool.append(make_lit_i64(1))     # 1
    pool.append(make_lt_i64(0, 1))   # 2
    pool.append(make_lit_i64(1))     # 3
    pool.append(make_lit_i64(0))     # 4
    pool.append(make_case_i64(0))    # 5
    var slots: List[Int] = [2, 3, 4]
    var when = List[List[Int]]()
    when.append(slots^)
    var exec = ExpressionExecutor(pool^, 5, _names(), when_pool=when^)
    var rb = _block()
    var src = RowCellSource(
        rb,
        _offsets(),
        _dtypes(),
        col_scales=[0, 0, 0],
        has_validity=True,
        validity_offset=_VALIDITY_OFFSET,
    )
    for r in range(3):
        assert_equal(
            Int(exec._eval_i64_from_source(src, 5, r)), 0, "CASE at row " + String(r)
        )


def test_non_nullable_source_keeps_two_valued_answers() raises:
    """The same block read without validity: every cell is present and the
    stored zeros are values. `x > 0 OR y > 0` -> [0, 2];
    `NOT (x < 0 AND y > 0)` -> [0, 1, 2]; `NOT (d > 0)` -> [1, 2]."""
    var rb = _block()
    var src = RowCellSource(rb, _offsets(), _dtypes(), col_scales=[0, 0, 0])
    var p = _x_gt0_y_gt0(List[RuntimeExpr]())
    p.append(make_or(2, 5))
    var sel = _exec(p^).select_filter_from_source(src)
    var got = List[Int]()
    for k in range(sel.len()):
        got.append(Int(sel.get(k)))
    _expect(got, [0, 2], "2VL x > 0 OR y > 0")
    var q = List[RuntimeExpr]()
    q.append(make_col(X))
    q.append(make_lit_i64(0))
    q.append(make_lt_i64(0, 1))
    q.append(make_col(Y))
    q.append(make_lit_i64(0))
    q.append(make_gt_i64(3, 4))
    q.append(make_and(2, 5))
    q.append(make_not_bool(6))
    var sel2 = _exec(q^).select_filter_from_source(src)
    var got2 = List[Int]()
    for k in range(sel2.len()):
        got2.append(Int(sel2.get(k)))
    _expect(got2, [0, 1, 2], "2VL NOT (x < 0 AND y > 0)")
    var d = List[RuntimeExpr]()
    d.append(make_col_decimal128(D))
    d.append(make_lit_decimal128(0))
    d.append(make_gt_decimal128(0, 1))
    d.append(make_not_bool(2))
    var sel3 = _exec(d^).select_filter_from_source(src)
    var got3 = List[Int]()
    for k in range(sel3.len()):
        got3.append(Int(sel3.get(k)))
    _expect(got3, [1, 2], "2VL NOT (d > 0)")


def main() raises:
    var suite = TestSuite()
    suite.test[test_true_or_null_is_true]()
    suite.test[test_not_of_false_and_null_is_true]()
    suite.test[test_decimal_operand_null_under_not]()
    suite.test[test_arithmetic_operand_over_a_null_column]()
    suite.test[test_null_operand_on_the_right]()
    suite.test[test_cast_case_and_null_operands]()
    suite.test[test_extract_and_date_trunc_over_a_null_column]()
    suite.test[test_case_condition_over_a_null_operand_is_not_true]()
    suite.test[test_non_nullable_source_keeps_two_valued_answers]()
    suite^.run()
