# =============================================================================
# The per-cell walker of `ExpressionExecutor` (`select_filter_from_source`
# and the `_eval_*_from_source` arms it calls) over a `CellSource` this file
# defines: a table of per-column Lists, so each case states its cells
# directly and nothing else (no row layout, no Arrow arrays) is under test.
#
# Covered: the unsigned comparisons (a value above Int64.MAX must compare
# above a small one, which a signed compare gets wrong), the Float64 and
# mixed comparisons, the String comparisons, IS [NOT] NULL, NOT over a NULL
# comparison, the sub-second and weekday EXTRACT fields, the sub-day
# DATE_TRUNC units per tick width, the Int64 and Float64 arithmetic arms,
# and every operand refusal.
#
# EXTRACT follows DuckDB's field definitions: `millisecond` and
# `microsecond` count from the start of the minute (seconds included),
# `dayofweek` is 0 for Sunday, `isodow` 7 for Sunday.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_column_kernels.scalar_math import KMATH_CEIL
from komira_eval.expression_executor import ExpressionExecutor
from komira_kernels.runtime_expr import (
    EXPR_EQ_F64,
    EXPR_EQ_F64_MIXED,
    EXPR_EQ_STRING,
    EXPR_EQ_U64,
    EXPR_GE_F64,
    EXPR_GE_F64_MIXED,
    EXPR_GE_STRING,
    EXPR_GE_U64,
    EXPR_GT_F64,
    EXPR_GT_F64_MIXED,
    EXPR_GT_STRING,
    EXPR_GT_U64,
    EXPR_LE_F64,
    EXPR_LE_F64_MIXED,
    EXPR_LE_STRING,
    EXPR_LE_U64,
    EXPR_LT_F64,
    EXPR_LT_F64_MIXED,
    EXPR_LT_STRING,
    EXPR_LT_U64,
    EXPR_NE_F64,
    EXPR_NE_U64,
    EXPR_NEQ_STRING,
    EXPR_SUB_F64,
    EXPR_DIV_F64,
    EXPR_SUB_I64,
    EXPR_MUL_I64,
    EXPR_DIV_I64,
    EXPR_EQ_DECIMAL128,
    RT_EXTRACT_DAYOFWEEK,
    RT_EXTRACT_ISODOW,
    RT_EXTRACT_MICROSECOND,
    RT_EXTRACT_MILLISECOND,
    RT_TRUNC_HOUR,
    RT_TRUNC_MICROSECOND,
    RT_TRUNC_MILLISECOND,
    RT_TRUNC_MINUTE,
    RT_TRUNC_MONTH,
    RT_TRUNC_QUARTER,
    RT_TRUNC_SECOND,
    RuntimeExpr,
    make_col,
    make_col_decimal128,
    make_col_string,
    make_date_trunc_i64,
    make_extract_i64,
    make_gt_i64,
    make_is_not_null_cell,
    make_is_null_cell,
    make_lit_f64,
    make_lit_i64,
    make_lit_string,
    make_math_unary_f64,
    make_not_bool,
    make_null,
    make_pow_f64,
)
from komira_row_format.cell_source import CellSource


# -----------------------------------------------------------------------------
# A CellSource over per-column Lists
# -----------------------------------------------------------------------------


struct _Cells(CellSource, Movable):
    """Column `c` reads `ints[c]`, `uints[c]`, `floats[c]`, `strs[c]` or
    `decs[c]` (at scale `scales[c]`) by the reader called; `nulls[c][r]`
    marks a NULL cell. `validity` is what `has_validity` reports."""

    var n: Int
    var ints: List[List[Int]]
    var uints: List[List[UInt64]]
    var floats: List[List[Float64]]
    var strs: List[List[String]]
    var decs: List[List[Int]]
    var scales: List[Int]
    var nulls: List[List[Bool]]
    var validity: Bool

    def __init__(out self, n: Int, n_cols: Int, validity: Bool):
        self.n = n
        self.ints = List[List[Int]]()
        self.uints = List[List[UInt64]]()
        self.floats = List[List[Float64]]()
        self.strs = List[List[String]]()
        self.decs = List[List[Int]]()
        self.scales = List[Int]()
        self.nulls = List[List[Bool]]()
        for _ in range(n_cols):
            self.ints.append(List[Int]())
            self.uints.append(List[UInt64]())
            self.floats.append(List[Float64]())
            self.strs.append(List[String]())
            self.decs.append(List[Int]())
            self.scales.append(0)
            var none = List[Bool]()
            for _ in range(n):
                none.append(False)
            self.nulls.append(none^)
        self.validity = validity

    def num_rows(self) -> Int:
        return self.n

    def read_i64(self, row: Int, col_idx: Int) raises -> Int64:
        return Int64(self.ints[col_idx][row])

    def read_u64(self, row: Int, col_idx: Int) raises -> UInt64:
        return self.uints[col_idx][row]

    def read_i128(self, row: Int, col_idx: Int) raises -> SIMD[DType.int128, 1]:
        return SIMD[DType.int128, 1](self.decs[col_idx][row])

    def decimal_scale_of(self, col_idx: Int) raises -> Int:
        return self.scales[col_idx]

    def read_f64(self, row: Int, col_idx: Int) raises -> Float64:
        return self.floats[col_idx][row]

    def read_i32(self, row: Int, col_idx: Int) raises -> Int32:
        return Int32(self.ints[col_idx][row])

    def read_f32(self, row: Int, col_idx: Int) raises -> Float32:
        return Float32(self.floats[col_idx][row])

    def read_string(self, row: Int, col_idx: Int) raises -> String:
        return self.strs[col_idx][row].copy()

    def is_null(self, row: Int, col_idx: Int) raises -> Bool:
        return self.nulls[col_idx][row]

    def has_validity(self) -> Bool:
        return self.validity


comptime K = 0   # Int64: [10, -3, 7, 0]
comptime U = 1   # UInt64: [2^63 + 5, 1, 2^63 + 5, 9]
comptime FL = 2  # Float64: [1.5, 2.5, -1.0, 2.5]
comptime ST = 3  # String: ["ab", "abc", "b", "ab"]
comptime DC = 4  # Decimal (scale 2): [1.50, 2.50, -0.05, 0.00]
comptime NL = 5  # Int64 with NULLs: [1, NULL, 3, NULL]


def _cells(validity: Bool = False) -> _Cells:
    var c = _Cells(4, 6, validity)
    c.ints[K] = [10, -3, 7, 0]
    var big = (UInt64(1) << 63) + 5
    c.uints[U] = [big, UInt64(1), big, UInt64(9)]
    c.floats[FL] = [1.5, 2.5, -1.0, 2.5]
    c.strs[ST] = ["ab", "abc", "b", "ab"]
    c.decs[DC] = [150, 250, -5, 0]
    c.scales[DC] = 2
    c.ints[NL] = [1, 0, 3, 0]
    c.nulls[NL] = [False, True, False, True]
    return c^


def _names() -> List[String]:
    var names: List[String] = ["k", "u", "fl", "st", "dc", "nl"]
    return names^


def _node(kind: Int, left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(kind, Int64(0), 0.0, False, 0, left, right)


def _exec(var pool: List[RuntimeExpr]) -> ExpressionExecutor:
    var root = len(pool) - 1
    var strings: List[String] = ["abc", "x%"]
    return ExpressionExecutor(pool^, root, _names(), string_pool=strings^)


def _cmp(kind: Int, var lhs: RuntimeExpr, var rhs: RuntimeExpr) -> ExpressionExecutor:
    var pool = List[RuntimeExpr]()
    pool.append(lhs)
    pool.append(rhs)
    pool.append(_node(kind, 0, 1))
    return _exec(pool^)


def _filter(exec: ExpressionExecutor, validity: Bool = False) raises -> List[Int]:
    var sel = exec.select_filter_from_source(_cells(validity))
    var out = List[Int]()
    for k in range(sel.len()):
        out.append(Int(sel.get(k)))
    return out^


def _expect(got: List[Int], want: List[Int], what: String) raises:
    assert_equal(len(got), len(want), what + ": survivor count")
    for k in range(len(want)):
        assert_equal(got[k], want[k], what + ": survivor " + String(k))


def _none() -> List[Int]:
    return List[Int]()


# -----------------------------------------------------------------------------
# Comparisons
# -----------------------------------------------------------------------------


def test_unsigned_comparisons_order_values_above_int64_max() raises:
    """u = [2^63 + 5, 1, 2^63 + 5, 9] against 9. Read as signed, 2^63 + 5
    would be negative and sort below 9."""
    var kinds: List[Int] = [EXPR_GT_U64, EXPR_GE_U64, EXPR_LT_U64, EXPR_LE_U64, EXPR_EQ_U64, EXPR_NE_U64]
    var want: List[List[Int]] = [[0, 2], [0, 2, 3], [1], [1, 3], [3], [0, 1, 2]]
    for k in range(6):
        _expect(_filter(_cmp(kinds[k], make_col(U), make_lit_i64(9))), want[k], "u op 9, kind " + String(kinds[k]))


def test_unsigned_operand_refusal() raises:
    with assert_raises(contains="_eval_u64_from_source: unsupported node kind 2 at pool slot 1 (U64 operand must be EXPR_COL / EXPR_LIT_I64)"):
        _ = _filter(_cmp(EXPR_GT_U64, make_col(U), make_lit_f64(9.0)))


def test_float_comparisons_and_their_mixed_twins() raises:
    """fl = [1.5, 2.5, -1.0, 2.5] against 2.5."""
    var kinds: List[Int] = [
        EXPR_GT_F64, EXPR_GE_F64, EXPR_LT_F64, EXPR_LE_F64, EXPR_EQ_F64, EXPR_NE_F64,
        EXPR_GT_F64_MIXED, EXPR_GE_F64_MIXED, EXPR_LT_F64_MIXED, EXPR_LE_F64_MIXED, EXPR_EQ_F64_MIXED,
    ]
    var want: List[List[Int]] = [
        _none(), [1, 3], [0, 2], [0, 1, 2, 3], [1, 3], [0, 2],
        _none(), [1, 3], [0, 2], [0, 1, 2, 3], [1, 3],
    ]
    for k in range(len(kinds)):
        _expect(_filter(_cmp(kinds[k], make_col(FL), make_lit_f64(2.5))), want[k], "fl op 2.5, kind " + String(kinds[k]))
    # An Int64 literal widens: fl > 2 keeps the two 2.5 rows.
    _expect(_filter(_cmp(EXPR_GT_F64_MIXED, make_col(FL), make_lit_i64(2))), [1, 3], "fl > 2")


def test_string_comparisons() raises:
    """st = ["ab", "abc", "b", "ab"] against "abc": "ab" is a prefix of
    "abc" and sorts first; "b" sorts after."""
    var kinds: List[Int] = [EXPR_EQ_STRING, EXPR_NEQ_STRING, EXPR_GT_STRING, EXPR_LT_STRING, EXPR_GE_STRING, EXPR_LE_STRING]
    var want: List[List[Int]] = [[1], [0, 2, 3], [2], [0, 3], [1, 2], [0, 1, 3]]
    for k in range(6):
        _expect(_filter(_cmp(kinds[k], make_col_string(ST), make_lit_string(0))), want[k], "st op 'abc', kind " + String(kinds[k]))


def test_string_operand_refusal() raises:
    with assert_raises(contains="_eval_string_from_source: unsupported node kind 1 at pool slot 1 (string operand must be EXPR_COL_STRING / EXPR_LIT_STRING)"):
        _ = _filter(_cmp(EXPR_EQ_STRING, make_col_string(ST), make_lit_i64(1)))


def test_is_null_and_is_not_null() raises:
    """nl = [1, NULL, 3, NULL]; IS [NOT] NULL is never NULL itself."""
    var p1 = List[RuntimeExpr]()
    p1.append(make_is_null_cell(NL))
    _expect(_filter(_exec(p1^), True), [1, 3], "nl IS NULL")
    var p2 = List[RuntimeExpr]()
    p2.append(make_is_not_null_cell(NL))
    _expect(_filter(_exec(p2^), True), [0, 2], "nl IS NOT NULL")


def test_not_over_null_drops_the_row() raises:
    """NOT (nl > 2): row 0 (1 > 2 false) is kept, row 2 (true) is not, and
    the NULL rows are UNKNOWN under NOT as well (NOT NULL is NULL)."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(NL))
    pool.append(make_lit_i64(2))
    pool.append(make_gt_i64(0, 1))
    pool.append(make_not_bool(2))
    _expect(_filter(_exec(pool^), True), [0], "NOT nl > 2")


def test_not_over_is_null() raises:
    """NOT (nl IS NULL) keeps the non-NULL rows: IS NULL is never UNKNOWN."""
    var pool = List[RuntimeExpr]()
    pool.append(make_is_null_cell(NL))
    pool.append(make_not_bool(0))
    _expect(_filter(_exec(pool^), True), [0, 2], "NOT nl IS NULL")


def test_unsupported_bool_root_is_refused() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_i64(1))
    with assert_raises(contains="_eval_bool_present_from_source: unsupported node kind 1 at pool slot 0"):
        _ = _filter(_exec(pool^))


def test_decimal_operand_refusals() raises:
    with assert_raises(contains="_eval_i128_from_source: unsupported node kind 1 at pool slot 1"):
        _ = _filter(_cmp(EXPR_EQ_DECIMAL128, make_col_decimal128(DC), make_lit_i64(1)))
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_i64(1))
    var exec = _exec(pool^)
    with assert_raises(contains="_eval_decimal_scale_from_source: unsupported node kind 1 at pool slot 0"):
        _ = exec._eval_decimal_scale_from_source(_cells(), 0)


# -----------------------------------------------------------------------------
# Int64 values: EXTRACT, DATE_TRUNC, arithmetic
# -----------------------------------------------------------------------------


comptime US_PER_DAY: Int64 = 86_400_000_000
comptime NS_PER_DAY: Int64 = 86_400_000_000_000


def _i64_of(var root: RuntimeExpr, epoch: Int) raises -> Int:
    """`root` over the literal `epoch` (root.left = 0)."""
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_i64(Int64(epoch)))
    pool.append(root)
    return Int(_exec(pool^)._eval_i64_from_source(_cells(), 1, 0))


def test_extract_sub_second_fields_count_from_the_minute() raises:
    """Day 1 of the epoch at 03:04:05.678901, in microseconds: millisecond
    5678, microsecond 5678901. One microsecond before the epoch
    (23:59:59.999999): 59999 and 59999999."""
    var t = 86_400_000_000 + (3 * 3600 + 4 * 60 + 5) * 1_000_000 + 678_901
    assert_equal(_i64_of(make_extract_i64(0, RT_EXTRACT_MILLISECOND, US_PER_DAY), t), 5678)
    assert_equal(_i64_of(make_extract_i64(0, RT_EXTRACT_MICROSECOND, US_PER_DAY), t), 5678901)
    assert_equal(_i64_of(make_extract_i64(0, RT_EXTRACT_MILLISECOND, US_PER_DAY), -1), 59999)
    assert_equal(_i64_of(make_extract_i64(0, RT_EXTRACT_MICROSECOND, US_PER_DAY), -1), 59999999)


def test_extract_weekday_fields() raises:
    """Day counts since the epoch: day 0 was a Thursday, day 3 a Sunday,
    day -1 a Wednesday."""
    assert_equal(_i64_of(make_extract_i64(0, RT_EXTRACT_DAYOFWEEK, 1), 0), 4)
    assert_equal(_i64_of(make_extract_i64(0, RT_EXTRACT_ISODOW, 1), 0), 4)
    assert_equal(_i64_of(make_extract_i64(0, RT_EXTRACT_DAYOFWEEK, 1), 3), 0)
    assert_equal(_i64_of(make_extract_i64(0, RT_EXTRACT_ISODOW, 1), 3), 7)
    assert_equal(_i64_of(make_extract_i64(0, RT_EXTRACT_DAYOFWEEK, 1), -1), 3)


def test_extract_and_trunc_refuse_an_unknown_unit() raises:
    with assert_raises(contains="EXPR_EXTRACT_I64 unsupported unit 99"):
        _ = _i64_of(make_extract_i64(0, 99, 1), 0)
    with assert_raises(contains="EXPR_DATE_TRUNC_I64 unsupported unit 99"):
        _ = _i64_of(make_date_trunc_i64(0, 99, 1), 0)


def test_sub_day_trunc_of_a_day_count_is_the_value() raises:
    """A day-count epoch (1 tick per day) has no hour, minute or second."""
    assert_equal(_i64_of(make_date_trunc_i64(0, RT_TRUNC_HOUR, 1), 5), 5)
    assert_equal(_i64_of(make_date_trunc_i64(0, RT_TRUNC_MINUTE, 1), 5), 5)
    assert_equal(_i64_of(make_date_trunc_i64(0, RT_TRUNC_SECOND, 1), 5), 5)


def test_month_and_quarter_trunc_in_january_and_february() raises:
    """Day counts since the epoch: day 14 is 15 January, day 40 is 10
    February, day 423 is 28 February of the next year. Their month starts
    are days 0, 31 and 396 (1 February of the next year); the quarter
    starts of days 40 and 423 are days 0 and 365 (1 January)."""
    assert_equal(_i64_of(make_date_trunc_i64(0, RT_TRUNC_MONTH, 1), 14), 0)
    assert_equal(_i64_of(make_date_trunc_i64(0, RT_TRUNC_MONTH, 1), 40), 31)
    assert_equal(_i64_of(make_date_trunc_i64(0, RT_TRUNC_QUARTER, 1), 40), 0)
    assert_equal(_i64_of(make_date_trunc_i64(0, RT_TRUNC_MONTH, 1), 423), 396)
    assert_equal(_i64_of(make_date_trunc_i64(0, RT_TRUNC_QUARTER, 1), 423), 365)


def test_filter_over_no_rows() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(K))
    pool.append(make_lit_i64(0))
    pool.append(make_gt_i64(0, 1))
    var exec = _exec(pool^)
    assert_equal(exec.select_filter_from_source(_Cells(0, 6, False)).len(), 0)


def test_sub_second_trunc_per_tick_width() raises:
    """1.234567891 s in nanoseconds truncates to 1.234 s (millisecond) and
    1.234567 s (microsecond); a seconds epoch has neither."""
    var ns = 1_234_567_891
    assert_equal(_i64_of(make_date_trunc_i64(0, RT_TRUNC_MILLISECOND, NS_PER_DAY), ns), 1_234_000_000)
    assert_equal(_i64_of(make_date_trunc_i64(0, RT_TRUNC_MICROSECOND, NS_PER_DAY), ns), 1_234_567_000)
    assert_equal(_i64_of(make_date_trunc_i64(0, RT_TRUNC_MILLISECOND, 86_400), 77), 77)


def test_int64_arithmetic() raises:
    """k = [10, -3, 7, 0], row 0."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(K))                  # 0
    pool.append(make_lit_i64(3))              # 1
    pool.append(_node(EXPR_SUB_I64, 0, 1))    # 2: k - 3
    pool.append(_node(EXPR_MUL_I64, 0, 1))    # 3: k * 3
    pool.append(_node(EXPR_DIV_I64, 0, 1))    # 4: k / 3
    pool.append(make_lit_i64(0))              # 5
    pool.append(_node(EXPR_DIV_I64, 0, 5))    # 6: k / 0
    pool.append(make_lit_string(0))           # 7
    var exec = _exec(pool^)
    var c = _cells()
    assert_equal(Int(exec._eval_i64_from_source(c, 2, 0)), 7)
    assert_equal(Int(exec._eval_i64_from_source(c, 3, 0)), 30)
    assert_equal(Int(exec._eval_i64_from_source(c, 4, 0)), 3)
    assert_equal(Int(exec._eval_i64_from_source(c, 2, 1)), -6)
    with assert_raises(contains="_eval_i64_from_source: EXPR_DIV_I64 division by zero at row 2"):
        _ = exec._eval_i64_from_source(c, 6, 2)
    with assert_raises(contains="_eval_i64_from_source: unsupported node kind 31 at pool slot 7"):
        _ = exec._eval_i64_from_source(c, 7, 0)


def test_int64_division_truncates_toward_zero() raises:
    """k = [10, -3, 7, 0]: k / -3 is [-3, 1, -2] on rows 0..2 and k / 2 on
    row 1 is -1 (§5.1, DuckDB's `//`); a floor gives -4, 1, -3 and -2
    (komira-ai/komira#932)."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(K))                  # 0
    pool.append(make_lit_i64(-3))             # 1
    pool.append(_node(EXPR_DIV_I64, 0, 1))    # 2: k / -3
    pool.append(make_lit_i64(2))              # 3
    pool.append(_node(EXPR_DIV_I64, 0, 3))    # 4: k / 2
    var exec = _exec(pool^)
    var c = _cells()
    assert_equal(Int(exec._eval_i64_from_source(c, 2, 0)), -3, "10 / -3")
    assert_equal(Int(exec._eval_i64_from_source(c, 2, 1)), 1, "-3 / -3")
    assert_equal(Int(exec._eval_i64_from_source(c, 2, 2)), -2, "7 / -3")
    assert_equal(Int(exec._eval_i64_from_source(c, 4, 1)), -1, "-3 / 2")


# -----------------------------------------------------------------------------
# Float64 values and computed nullity
# -----------------------------------------------------------------------------


def test_float64_arithmetic_and_functions() raises:
    """fl = [1.5, 2.5, -1.0, 2.5]."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(FL))                         # 0
    pool.append(make_lit_f64(0.5))                    # 1
    pool.append(_node(EXPR_SUB_F64, 0, 1))            # 2: fl - 0.5
    pool.append(_node(EXPR_DIV_F64, 0, 1))            # 3: fl / 0.5
    pool.append(make_lit_f64(2.0))                    # 4
    pool.append(make_pow_f64(4, 0))                   # 5: 2 ** fl
    pool.append(make_math_unary_f64(Int(KMATH_CEIL), 0))  # 6: ceil(fl)
    pool.append(make_null())                          # 7
    pool.append(make_lit_string(0))                   # 8
    var exec = _exec(pool^)
    var c = _cells()
    assert_equal(exec._eval_f64_from_source(c, 2, 0), 1.0)
    assert_equal(exec._eval_f64_from_source(c, 3, 1), 5.0)
    assert_equal(exec._eval_f64_from_source(c, 5, 2), 0.5)
    assert_equal(exec._eval_f64_from_source(c, 6, 0), 2.0)
    assert_equal(exec._eval_f64_from_source(c, 7, 0), 0.0)
    with assert_raises(contains="_eval_f64_from_source: unsupported node kind 31 at pool slot 8"):
        _ = exec._eval_f64_from_source(c, 8, 0)


def test_null_literal_is_a_null_cell() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_null())
    pool.append(make_col(K))
    var exec = _exec(pool^)
    assert_true(exec._cell_is_null_from_source(_cells(), 0, 0))
    assert_false(exec._cell_is_null_from_source(_cells(), 1, 0))


def main() raises:
    var suite = TestSuite()
    suite.test[test_unsigned_comparisons_order_values_above_int64_max]()
    suite.test[test_unsigned_operand_refusal]()
    suite.test[test_float_comparisons_and_their_mixed_twins]()
    suite.test[test_string_comparisons]()
    suite.test[test_string_operand_refusal]()
    suite.test[test_is_null_and_is_not_null]()
    suite.test[test_not_over_null_drops_the_row]()
    suite.test[test_not_over_is_null]()
    suite.test[test_unsupported_bool_root_is_refused]()
    suite.test[test_decimal_operand_refusals]()
    suite.test[test_extract_sub_second_fields_count_from_the_minute]()
    suite.test[test_extract_weekday_fields]()
    suite.test[test_extract_and_trunc_refuse_an_unknown_unit]()
    suite.test[test_sub_day_trunc_of_a_day_count_is_the_value]()
    suite.test[test_month_and_quarter_trunc_in_january_and_february]()
    suite.test[test_filter_over_no_rows]()
    suite.test[test_sub_second_trunc_per_tick_width]()
    suite.test[test_int64_arithmetic]()
    suite.test[test_int64_division_truncates_toward_zero]()
    suite.test[test_float64_arithmetic_and_functions]()
    suite.test[test_null_literal_is_a_null_cell]()
    suite^.run()
