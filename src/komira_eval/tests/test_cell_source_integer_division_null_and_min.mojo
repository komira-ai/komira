# =============================================================================
# Integer division in the per-cell walkers of `ExpressionExecutor`
# (`_eval_i64_from_source`, `select_filter_from_source`): a zero divisor
# answers NULL (docs/design/query_semantics.md §5.3) and signed MIN / -1
# raises an overflow error (§5.4) unless an operand is NULL (§5.0).
#
# The value walker returns the placeholder 0 for a NULL quotient and
# `_value_is_null_from_source` reports it NULL. A filter is the public proof:
# a NULL quotient is UNKNOWN, so the row survives neither `p` nor `NOT p`,
# also on a source with no validity region (whose `is_null` this fixture
# refuses, as `ColumnCellSource` does for a numeric column).
#
# Zero source: k = [7, -7, 0, -9], d = [2, 0, 0, -2].
# MIN source: k = [MIN, N/MIN, 6, MIN, MIN], d = [-1, -1, -1, 1, N/-1] (k row
# 1 and d row 4 NULL when the source carries validity).
#
# The probe sections build their own sources; each says what it holds.
#
# Refs komira-ai/komira#1276.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_eval.expression_executor import ExpressionExecutor
from komira_kernels.runtime_expr import (
    EXPR_ADD_I64,
    EXPR_DIV_I64,
    EXPR_EQ_F64_MIXED,
    EXPR_GE_I64,
    EXPR_GT_I64,
    EXPR_MUL_I64,
    RuntimeExpr,
    make_and,
    make_case_i64,
    make_col,
    make_i64_to_f64,
    make_lit_f64,
    make_lit_i64,
    make_not_bool,
    make_null,
)
from komira_row_format.cell_source import CellSource


struct _Cells(CellSource, Movable):
    """Int64 columns `ints[c]`; `nulls[c][r]` marks a NULL cell. A source
    without validity refuses `is_null`."""

    var n: Int
    var ints: List[List[Int]]
    var nulls: List[List[Bool]]
    var validity: Bool

    def __init__(out self, var ints: List[List[Int]], var nulls: List[List[Bool]], validity: Bool):
        self.n = len(ints[0])
        self.ints = ints^
        self.nulls = nulls^
        self.validity = validity

    def num_rows(self) -> Int:
        return self.n

    def read_i64(self, row: Int, col_idx: Int) raises -> Int64:
        return Int64(self.ints[col_idx][row])

    def read_u64(self, row: Int, col_idx: Int) raises -> UInt64:
        raise Error("_Cells.read_u64: not served")

    def read_i128(self, row: Int, col_idx: Int) raises -> SIMD[DType.int128, 1]:
        raise Error("_Cells.read_i128: not served")

    def decimal_scale_of(self, col_idx: Int) raises -> Int:
        raise Error("_Cells.decimal_scale_of: not served")

    def read_f64(self, row: Int, col_idx: Int) raises -> Float64:
        return Float64(self.ints[col_idx][row])

    def read_i32(self, row: Int, col_idx: Int) raises -> Int32:
        return Int32(self.ints[col_idx][row])

    def read_f32(self, row: Int, col_idx: Int) raises -> Float32:
        return Float32(self.ints[col_idx][row])

    def read_string(self, row: Int, col_idx: Int) raises -> String:
        raise Error("_Cells.read_string: not served")

    def is_null(self, row: Int, col_idx: Int) raises -> Bool:
        if not self.validity:
            raise Error("_Cells.is_null: the source has no validity region")
        return self.nulls[col_idx][row]

    def has_validity(self) -> Bool:
        return self.validity


comptime K = 0
comptime D = 1
comptime I64_MIN = Int(Scalar[DType.int64].MIN)


def _zero_cells(validity: Bool) -> _Cells:
    var ints: List[List[Int]] = [[7, -7, 0, -9], [2, 0, 0, -2]]
    var nulls: List[List[Bool]] = [[False, False, False, False], [False, False, False, False]]
    return _Cells(ints^, nulls^, validity)


def _min_cells(validity: Bool) -> _Cells:
    var ints: List[List[Int]] = [[I64_MIN, I64_MIN, 6, I64_MIN, I64_MIN], [-1, -1, -1, 1, -1]]
    var nulls: List[List[Bool]] = [[False, True, False, False, False], [False, False, False, False, True]]
    return _Cells(ints^, nulls^, validity)


def _node(kind: Int, left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(kind, Int64(0), 0.0, False, 0, left, right)


def _names() -> List[String]:
    var names: List[String] = ["k", "d"]
    return names^


def _div_pool() -> List[RuntimeExpr]:
    """[k, d, k / d]."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(K))                  # 0
    pool.append(make_col(D))                  # 1
    pool.append(_node(EXPR_DIV_I64, 0, 1))    # 2: k / d
    return pool^


def _exec(var pool: List[RuntimeExpr], var when: List[List[Int]] = List[List[Int]]()) -> ExpressionExecutor:
    var root = len(pool) - 1
    return ExpressionExecutor(pool^, root, _names(), when_pool=when^)


def _filter(exec: ExpressionExecutor, validity: Bool) raises -> List[Int]:
    var sel = exec.select_filter_from_source(_zero_cells(validity))
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


def _ge_zero(negate: Bool) -> ExpressionExecutor:
    """`[NOT] ((k / d) >= 0)`."""
    var pool = _div_pool()
    pool.append(make_lit_i64(0))              # 3
    pool.append(_node(EXPR_GE_I64, 2, 3))     # 4
    if negate:
        pool.append(make_not_bool(4))         # 5
    return _exec(pool^)


# -----------------------------------------------------------------------------
# §5.3: a zero divisor answers NULL
# -----------------------------------------------------------------------------


def test_zero_divisor_is_null_not_a_raise() raises:
    var exec = _exec(_div_pool())
    for validity in [False, True]:
        var c = _zero_cells(validity)
        assert_equal(Int(exec._eval_i64_from_source(c, 2, 0)), 3)
        assert_equal(Int(exec._eval_i64_from_source(c, 2, 1)), 0, "placeholder")
        assert_equal(Int(exec._eval_i64_from_source(c, 2, 3)), 4)
        assert_false(exec._value_is_null_from_source(c, 2, 0))
        assert_true(exec._value_is_null_from_source(c, 2, 1))
        assert_true(exec._value_is_null_from_source(c, 2, 2))


def test_filter_over_a_zero_divisor_quotient_is_unknown() raises:
    """`(k / d) >= 0` keeps [0, 3] and its NOT keeps nothing, with and
    without a validity region: rows 1 and 2 are UNKNOWN, not 0 >= 0."""
    for validity in [False, True]:
        var tag = " (validity " + String(validity) + ")"
        _expect(_filter(_ge_zero(False), validity), [0, 3], "(k / d) >= 0" + tag)
        _expect(_filter(_ge_zero(True), validity), List[Int](), "NOT ((k / d) >= 0)" + tag)


def test_filter_over_a_cast_zero_divisor_quotient_is_unknown() raises:
    """`CAST(k / d AS DOUBLE) = 0` keeps nothing: the Float64 compare reaches
    the division through the cast."""
    var pool = _div_pool()
    pool.append(make_i64_to_f64(2))                   # 3
    pool.append(make_lit_f64(0.0))                    # 4
    pool.append(_node(EXPR_EQ_F64_MIXED, 3, 4))       # 5
    var exec = _exec(pool^)
    _expect(_filter(exec, False), List[Int](), "CAST(k / d) = 0")


def test_case_condition_over_a_zero_divisor_takes_the_else() raises:
    """CASE WHEN (k / d) >= 0 THEN 1 ELSE 2 END: an UNKNOWN condition is not
    TRUE, so rows 1 and 2 take the ELSE."""
    var pool = _div_pool()
    pool.append(make_lit_i64(0))              # 3
    pool.append(_node(EXPR_GE_I64, 2, 3))     # 4: (k / d) >= 0
    pool.append(make_lit_i64(1))              # 5
    pool.append(make_lit_i64(2))              # 6
    pool.append(make_case_i64(0))             # 7
    var slots: List[Int] = [4, 5, 6]
    var when = List[List[Int]]()
    when.append(slots^)
    var exec = _exec(pool^, when^)
    var c = _zero_cells(False)
    var want: List[Int] = [1, 2, 2, 1]
    for r in range(4):
        assert_equal(Int(exec._eval_i64_from_source(c, 7, r)), want[r], "CASE row " + String(r))


# -----------------------------------------------------------------------------
# §5.4: signed MIN / -1 raises, unless an operand is NULL
# -----------------------------------------------------------------------------


def test_min_over_minus_one_raises() raises:
    var exec = _exec(_div_pool())
    var c = _min_cells(True)
    with assert_raises(contains="Out of Range Error: Overflow in division of INT64 (-9223372036854775808 / -1)!"):
        _ = exec._eval_i64_from_source(c, 2, 0)
    assert_equal(Int(exec._eval_i64_from_source(c, 2, 1)), 0, "NULL dividend: no raise")
    assert_true(exec._value_is_null_from_source(c, 2, 1))
    assert_equal(Int(exec._eval_i64_from_source(c, 2, 4)), 0, "NULL divisor: no raise")
    assert_true(exec._value_is_null_from_source(c, 2, 4))
    assert_equal(Int(exec._eval_i64_from_source(c, 2, 2)), -6)
    assert_equal(Int(exec._eval_i64_from_source(c, 2, 3)), I64_MIN, "MIN / 1")
    # Without a validity region every cell is present: row 1 is MIN / -1.
    with assert_raises(contains="Out of Range Error: Overflow in division of INT64 (-9223372036854775808 / -1)!"):
        _ = exec._eval_i64_from_source(_min_cells(False), 2, 1)


def test_min_over_minus_two_and_two_answers() raises:
    """MIN / -2 is 2^62 and MIN / 2 is -2^62: only -1 overflows."""
    var ints: List[List[Int]] = [[I64_MIN, I64_MIN], [-2, 2]]
    var nulls: List[List[Bool]] = [[False, False], [False, False]]
    var c = _Cells(ints^, nulls^, True)
    var exec = _exec(_div_pool())
    assert_equal(Int(exec._eval_i64_from_source(c, 2, 0)), 1 << 62, "MIN / -2")
    assert_equal(Int(exec._eval_i64_from_source(c, 2, 1)), -(1 << 62), "MIN / 2")


# -----------------------------------------------------------------------------
# A divisor is evaluated only once no operand of the compare is NULL
#
# Source with validity, one row: k = 7, m = 4 (or MIN), n = 2^62 (or -1),
# x = N/0. Each compare has the NULL x as an operand, so it is UNKNOWN and the
# row is dropped. The other operand divides by a divisor whose evaluation
# raises (4 * 2^62 overflows; MIN / -1 overflows): evaluating it before the
# NULL x is seen would raise on a row whose answer is UNKNOWN.
# -----------------------------------------------------------------------------


comptime PK = 0
comptime PM = 1
comptime PN = 2
comptime PX = 3


def _probe_names() -> List[String]:
    var names: List[String] = ["k", "m", "n", "x"]
    return names^


def _probe_filter(var pool: List[RuntimeExpr], m: Int, n: Int) raises -> List[Int]:
    var ints: List[List[Int]] = [[7], [m], [n], [0]]
    var nulls: List[List[Bool]] = [[False], [False], [False], [True]]
    var root = len(pool) - 1
    var exec = ExpressionExecutor(pool^, root, _probe_names())
    var sel = exec.select_filter_from_source(_Cells(ints^, nulls^, True))
    var out = List[Int]()
    for k in range(sel.len()):
        out.append(Int(sel.get(k)))
    return out^


def _k_over(divisor_kind: Int) -> List[RuntimeExpr]:
    """[k, m, n, x, m <op> n, k / (m <op> n)]."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(PK))                     # 0
    pool.append(make_col(PM))                     # 1
    pool.append(make_col(PN))                     # 2
    pool.append(make_col(PX))                     # 3
    pool.append(_node(divisor_kind, 1, 2))        # 4: m <op> n
    pool.append(_node(EXPR_DIV_I64, 0, 4))        # 5: k / (m <op> n)
    return pool^


def test_probe_quotient_of_an_overflowing_divisor_over_a_null_compare_is_unknown() raises:
    """`(k / (m * n)) > x`: x is NULL, so the row is dropped; m * n is not
    evaluated."""
    var pool = _k_over(EXPR_MUL_I64)
    pool.append(_node(EXPR_GT_I64, 5, 3))         # 6
    _expect(_probe_filter(pool^, 4, 1 << 62), List[Int](), "(k / (m * n)) > x")


def test_probe_sum_with_a_null_over_an_overflowing_divisor_is_unknown() raises:
    """`((k / (m * n)) + x) > 0`: the sum has a NULL operand."""
    var pool = _k_over(EXPR_MUL_I64)
    pool.append(_node(EXPR_ADD_I64, 5, 3))        # 6: (k / (m * n)) + x
    pool.append(make_lit_i64(0))                  # 7
    pool.append(_node(EXPR_GT_I64, 6, 7))         # 8
    _expect(_probe_filter(pool^, 4, 1 << 62), List[Int](), "((k / (m * n)) + x) > 0")


def test_probe_min_over_minus_one_divisor_over_a_null_compare_is_unknown() raises:
    """`(k / (m / n)) > x` with m = MIN, n = -1: m / n is not evaluated."""
    var pool = _k_over(EXPR_DIV_I64)
    pool.append(_node(EXPR_GT_I64, 5, 3))         # 6
    _expect(_probe_filter(pool^, I64_MIN, -1), List[Int](), "(k / (m / n)) > x")


# -----------------------------------------------------------------------------
# A division in the pool keeps the answers of a source without validity
#
# k = [-5, 1], d = [1, 1], no validity region.
# `(k > CASE WHEN k > 100 THEN k ELSE NULL END) AND (((k * 2^62) / d) > 0)`.
# Without validity EXPR_NULL reads as 0, as the two-valued walker reads it:
# row 0's left side is -5 > 0, FALSE, so its right side, where -5 * 2^62
# overflows, is not evaluated; row 1 is 1 > 0 AND 2^62 > 0 and is kept.
# -----------------------------------------------------------------------------


def test_probe_and_over_a_null_case_without_validity_keeps_the_two_valued_answer() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(K))                      # 0: k
    pool.append(make_col(D))                      # 1: d
    pool.append(make_lit_i64(100))                # 2
    pool.append(_node(EXPR_GT_I64, 0, 2))         # 3: k > 100
    pool.append(make_null())                      # 4: NULL
    pool.append(make_case_i64(0))                 # 5: CASE WHEN k > 100 THEN k ELSE NULL END
    pool.append(_node(EXPR_GT_I64, 0, 5))         # 6: k > CASE
    pool.append(make_lit_i64(Int64(1 << 62)))    # 7
    pool.append(_node(EXPR_MUL_I64, 0, 7))        # 8: k * 2^62
    pool.append(_node(EXPR_DIV_I64, 8, 1))        # 9: (k * 2^62) / d
    pool.append(make_lit_i64(0))                  # 10
    pool.append(_node(EXPR_GT_I64, 9, 10))        # 11
    pool.append(make_and(6, 11))                  # 12
    var slots: List[Int] = [3, 0, 4]
    var when = List[List[Int]]()
    when.append(slots^)
    var exec = _exec(pool^, when^)
    var ints: List[List[Int]] = [[-5, 1], [1, 1]]
    var nulls: List[List[Bool]] = [[False, False], [False, False]]
    var sel = exec.select_filter_from_source(_Cells(ints^, nulls^, False))
    var got = List[Int]()
    for k in range(sel.len()):
        got.append(Int(sel.get(k)))
    _expect(got, [1], "(k > CASE ... ELSE NULL) AND (((k * 2^62) / d) > 0)")


def main() raises:
    var suite = TestSuite()
    suite.test[test_zero_divisor_is_null_not_a_raise]()
    suite.test[test_filter_over_a_zero_divisor_quotient_is_unknown]()
    suite.test[test_filter_over_a_cast_zero_divisor_quotient_is_unknown]()
    suite.test[test_case_condition_over_a_zero_divisor_takes_the_else]()
    suite.test[test_min_over_minus_one_raises]()
    suite.test[test_min_over_minus_two_and_two_answers]()
    suite.test[test_probe_quotient_of_an_overflowing_divisor_over_a_null_compare_is_unknown]()
    suite.test[test_probe_sum_with_a_null_over_an_overflowing_divisor_is_unknown]()
    suite.test[test_probe_min_over_minus_one_divisor_over_a_null_compare_is_unknown]()
    suite.test[test_probe_and_over_a_null_case_without_validity_keeps_the_two_valued_answer]()
    suite^.run()
