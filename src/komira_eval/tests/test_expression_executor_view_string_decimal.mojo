# =============================================================================
# The BatchView filter walker's String and Decimal128 arms: equality,
# lexicographic order, IS [NOT] NULL and LIKE over strings, and the six
# Decimal128 comparisons, each in its four operand shapes (column-column,
# column-literal, literal-column, literal-literal), with the shape refusals.
#
# Strings compare by their UTF-8 bytes, a prefix sorting first (binary
# collation, as DuckDB's default). A comparison with a NULL string is NULL in
# SQL, so the row is dropped.
# Decimals compare by value across scales: 1.00 at scale 2 equals 1.0 at
# scale 1. Expected survivor lists are worked by hand from the fixtures.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import batch_view_over
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_eval.expression_executor import DecimalSpec, ExpressionExecutor
from komira_eval.filter_state import FilterState
from komira_kernels.runtime_expr import (
    EXPR_EQ_DECIMAL128,
    EXPR_EQ_STRING,
    EXPR_GE_DECIMAL128,
    EXPR_GE_STRING,
    EXPR_GT_DECIMAL128,
    EXPR_GT_STRING,
    EXPR_LE_DECIMAL128,
    EXPR_LE_STRING,
    EXPR_LT_DECIMAL128,
    EXPR_LT_STRING,
    EXPR_NEQ_DECIMAL128,
    EXPR_NEQ_STRING,
    RuntimeExpr,
    make_col_decimal128,
    make_col_string,
    make_is_not_null_string,
    make_is_null_string,
    make_like_string,
    make_lit_decimal128,
    make_lit_i64,
    make_lit_string,
)


# -----------------------------------------------------------------------------
# Fixture
# -----------------------------------------------------------------------------


def _dec(vals: List[Int], scale: Int) raises -> Column[HeapRegion]:
    var l = List[SIMD[DType.int128, 1]]()
    for v in vals:
        l.append(SIMD[DType.int128, 1](v))
    return Column.from_decimal128(Decimal128Array.from_i128_list(l, 10, scale))


def _batch() raises -> RecordBatch:
    """Five rows (N = NULL).

    | row | s      | t       | d1 (s=2) | d2 (s=1) | d3 (s=2) |
    |-----|--------|---------|----------|----------|----------|
    | 0   | apple  | apple   | 1.00     | 1.0      | 1.00     |
    | 1   | banana | apricot | 2.50     | 3.0      | 2.50     |
    | 2   | N      | x       | -0.05    | 0.0      | 9.99     |
    | 3   | cherry | N       | 0.00     | -0.1     | 0.00     |
    | 4   | banana | cherry  | 3.00     | 3.0      | 3.00     |
    """
    var sv: List[String] = ["apple", "banana", "", "cherry", "banana"]
    var sok: List[Bool] = [True, True, False, True, True]
    var tv: List[String] = ["apple", "apricot", "x", "", "cherry"]
    var tok: List[Bool] = [True, True, True, False, True]
    var sb = SchemaBuilder()
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("t", ArrowType.STRING, True))
    sb.add_field(Field.decimal128("d1", 10, 2, False))
    sb.add_field(Field.decimal128("d2", 10, 1, False))
    sb.add_field(Field.decimal128("d3", 10, 2, False))
    var cols = Slab[Column[HeapRegion]]()
    cols.append(Column.from_string(StringArray.from_strings_with_validity(sv, sok)))
    cols.append(Column.from_string(StringArray.from_strings_with_validity(tv, tok)))
    cols.append(_dec([100, 250, -5, 0, 300], 2))
    cols.append(_dec([10, 30, 0, -1, 30], 1))
    cols.append(_dec([100, 250, 999, 0, 300], 2))
    return RecordBatch.from_typed_columns_slab(sb.build(), cols^)


comptime S = 0
comptime T = 1
comptime D1 = 2
comptime D2 = 3
comptime D3 = 4


def _names() -> List[String]:
    var names: List[String] = ["s", "t", "d1", "d2", "d3"]
    return names^


def _run(exec: ExpressionExecutor, batch: RecordBatch) raises -> List[Int]:
    var fs = FilterState.with_conjunction(n_predicates=1, worker_id=0)
    var n = exec.select_expression_from_view(batch_view_over(batch), fs)
    var out = List[Int]()
    for k in range(n):
        out.append(Int(fs.sel.get(k)))
    return out^


def _expect(got: List[Int], want: List[Int], what: String) raises:
    assert_equal(len(got), len(want), what + ": survivor count")
    for k in range(len(want)):
        assert_equal(got[k], want[k], what + ": survivor " + String(k))


def _node(kind: Int, left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(kind, Int64(0), 0.0, False, 0, left, right)


def _str_exec(kind: Int, var lhs: RuntimeExpr, var rhs: RuntimeExpr) -> ExpressionExecutor:
    """Pool [lhs, rhs, kind(0, 1)]; string pool 0 'banana', 1 'apricot',
    2 'b%', 3 'ab', 4 'abc', 5 'a', 6 'b'."""
    var pool = List[RuntimeExpr]()
    pool.append(lhs)
    pool.append(rhs)
    pool.append(_node(kind, 0, 1))
    var strings: List[String] = ["banana", "apricot", "b%", "ab", "abc", "a", "b"]
    return ExpressionExecutor(pool^, 2, _names(), string_pool=strings^)


comptime BANANA = 0
comptime APRICOT = 1
comptime B_PCT = 2
comptime AB = 3
comptime ABC = 4
comptime A = 5
comptime B = 6

def _all() -> List[Int]:
    var rows: List[Int] = [0, 1, 2, 3, 4]
    return rows^


def _none() -> List[Int]:
    return List[Int]()


# -----------------------------------------------------------------------------
# String equality
# -----------------------------------------------------------------------------


def test_string_equality_column_column() raises:
    """s vs t: row 0 equal, rows 1 and 4 differ, rows 2 and 3 hold a NULL."""
    var b = _batch()
    _expect(_run(_str_exec(EXPR_EQ_STRING, make_col_string(S), make_col_string(T)), b), [0], "s = t")
    _expect(_run(_str_exec(EXPR_NEQ_STRING, make_col_string(S), make_col_string(T)), b), [1, 4], "s <> t")


def test_string_equality_column_literal() raises:
    var b = _batch()
    _expect(_run(_str_exec(EXPR_EQ_STRING, make_col_string(S), make_lit_string(BANANA)), b), [1, 4], "s = 'banana'")
    _expect(_run(_str_exec(EXPR_NEQ_STRING, make_col_string(S), make_lit_string(BANANA)), b), [0, 3], "s <> 'banana'")


def test_string_equality_literal_column() raises:
    var b = _batch()
    _expect(_run(_str_exec(EXPR_EQ_STRING, make_lit_string(APRICOT), make_col_string(T)), b), [1], "'apricot' = t")
    _expect(_run(_str_exec(EXPR_NEQ_STRING, make_lit_string(APRICOT), make_col_string(T)), b), [0, 2, 4], "'apricot' <> t")


def test_string_equality_literal_literal() raises:
    var b = _batch()
    _expect(_run(_str_exec(EXPR_EQ_STRING, make_lit_string(A), make_lit_string(A)), b), _all(), "'a' = 'a'")
    _expect(_run(_str_exec(EXPR_EQ_STRING, make_lit_string(A), make_lit_string(B)), b), _none(), "'a' = 'b'")
    _expect(_run(_str_exec(EXPR_NEQ_STRING, make_lit_string(A), make_lit_string(B)), b), _all(), "'a' <> 'b'")
    _expect(_run(_str_exec(EXPR_NEQ_STRING, make_lit_string(A), make_lit_string(A)), b), _none(), "'a' <> 'a'")


def test_string_equality_refuses_other_operands() raises:
    var b = _batch()
    with assert_raises(contains="EXPR_EQ_STRING/EXPR_NEQ_STRING left operand must be EXPR_COL_STRING or EXPR_LIT_STRING (kind=1)"):
        _ = _run(_str_exec(EXPR_EQ_STRING, make_lit_i64(1), make_col_string(T)), b)
    with assert_raises(contains="EXPR_EQ_STRING/EXPR_NEQ_STRING right operand must be EXPR_COL_STRING or EXPR_LIT_STRING (kind=1)"):
        _ = _run(_str_exec(EXPR_NEQ_STRING, make_col_string(S), make_lit_i64(1)), b)


# -----------------------------------------------------------------------------
# IS NULL / IS NOT NULL
# -----------------------------------------------------------------------------


def _null_exec(want_null: Bool, var child: RuntimeExpr) -> ExpressionExecutor:
    var pool = List[RuntimeExpr]()
    pool.append(child)
    if want_null:
        pool.append(make_is_null_string(0))
    else:
        pool.append(make_is_not_null_string(0))
    return ExpressionExecutor(pool^, 1, _names())


def test_string_is_null_and_is_not_null() raises:
    var b = _batch()
    _expect(_run(_null_exec(True, make_col_string(S)), b), [2], "s IS NULL")
    _expect(_run(_null_exec(False, make_col_string(S)), b), [0, 1, 3, 4], "s IS NOT NULL")
    with assert_raises(contains="EXPR_IS_NULL_STRING/EXPR_IS_NOT_NULL_STRING child must be EXPR_COL_STRING (kind=1)"):
        _ = _run(_null_exec(True, make_lit_i64(1)), b)


# -----------------------------------------------------------------------------
# String order
# -----------------------------------------------------------------------------


def test_string_order_column_column() raises:
    """s vs t: apple = apple, banana > apricot (b > a at byte 0), banana <
    cherry; rows 2 and 3 hold a NULL."""
    var b = _batch()
    var kinds: List[Int] = [EXPR_GT_STRING, EXPR_LT_STRING, EXPR_GE_STRING, EXPR_LE_STRING]
    var want: List[List[Int]] = [[1], [4], [0, 1], [0, 4]]
    for k in range(4):
        var e = _str_exec(kinds[k], make_col_string(S), make_col_string(T))
        _expect(_run(e, b), want[k], "s op t, kind " + String(kinds[k]))


def test_string_order_column_literal() raises:
    """s vs 'banana': apple <, banana =, NULL, cherry >, banana =."""
    var b = _batch()
    var kinds: List[Int] = [EXPR_GT_STRING, EXPR_LT_STRING, EXPR_GE_STRING, EXPR_LE_STRING]
    var want: List[List[Int]] = [[3], [0], [1, 3, 4], [0, 1, 4]]
    for k in range(4):
        var e = _str_exec(kinds[k], make_col_string(S), make_lit_string(BANANA))
        _expect(_run(e, b), want[k], "s op 'banana', kind " + String(kinds[k]))


def test_string_order_literal_column() raises:
    """'apricot' vs t: apple <, apricot =, x >, NULL, cherry >; the literal
    is the left operand."""
    var b = _batch()
    var kinds: List[Int] = [EXPR_GT_STRING, EXPR_LT_STRING, EXPR_GE_STRING, EXPR_LE_STRING]
    var want: List[List[Int]] = [[0], [2, 4], [0, 1], [1, 2, 4]]
    for k in range(4):
        var e = _str_exec(kinds[k], make_lit_string(APRICOT), make_col_string(T))
        _expect(_run(e, b), want[k], "'apricot' op t, kind " + String(kinds[k]))


def test_string_order_literal_literal_prefix_sorts_first() raises:
    """'ab' < 'abc': the shorter of two strings sharing a prefix sorts first."""
    var b = _batch()
    var kinds: List[Int] = [EXPR_GT_STRING, EXPR_LT_STRING, EXPR_GE_STRING, EXPR_LE_STRING]
    var want_ab_abc: List[List[Int]] = [_none(), _all(), _none(), _all()]
    var want_abc_ab: List[List[Int]] = [_all(), _none(), _all(), _none()]
    var want_ab_ab: List[List[Int]] = [_none(), _none(), _all(), _all()]
    for k in range(4):
        _expect(_run(_str_exec(kinds[k], make_lit_string(AB), make_lit_string(ABC)), b), want_ab_abc[k], "'ab' op 'abc', kind " + String(kinds[k]))
        _expect(_run(_str_exec(kinds[k], make_lit_string(ABC), make_lit_string(AB)), b), want_abc_ab[k], "'abc' op 'ab', kind " + String(kinds[k]))
        _expect(_run(_str_exec(kinds[k], make_lit_string(AB), make_lit_string(AB)), b), want_ab_ab[k], "'ab' op 'ab', kind " + String(kinds[k]))


def test_string_order_refuses_other_operands() raises:
    var b = _batch()
    with assert_raises(contains="EXPR_*_STRING (lexicographic compare) left operand must be EXPR_COL_STRING or EXPR_LIT_STRING (kind=1)"):
        _ = _run(_str_exec(EXPR_GT_STRING, make_lit_i64(1), make_col_string(T)), b)
    with assert_raises(contains="EXPR_*_STRING (lexicographic compare) right operand must be EXPR_COL_STRING or EXPR_LIT_STRING (kind=1)"):
        _ = _run(_str_exec(EXPR_LE_STRING, make_col_string(S), make_lit_i64(1)), b)


# -----------------------------------------------------------------------------
# LIKE
# -----------------------------------------------------------------------------


def test_like_column_against_pattern() raises:
    """s LIKE 'b%' keeps the two bananas; the NULL row is dropped."""
    var b = _batch()
    var pool = List[RuntimeExpr]()
    pool.append(make_col_string(S))
    pool.append(make_lit_string(B_PCT))
    pool.append(make_like_string(0, 1))
    var strings: List[String] = ["banana", "apricot", "b%"]
    _expect(_run(ExpressionExecutor(pool^, 2, _names(), string_pool=strings^), b), [1, 4], "s LIKE 'b%'")


def test_like_refuses_other_operands() raises:
    var b = _batch()
    var p1 = List[RuntimeExpr]()
    p1.append(make_lit_string(0))
    p1.append(make_lit_string(0))
    p1.append(make_like_string(0, 1))
    var s1: List[String] = ["x"]
    with assert_raises(contains="EXPR_LIKE_STRING left operand must be EXPR_COL_STRING (kind=31)"):
        _ = _run(ExpressionExecutor(p1^, 2, _names(), string_pool=s1^), b)
    var p2 = List[RuntimeExpr]()
    p2.append(make_col_string(S))
    p2.append(make_col_string(T))
    p2.append(make_like_string(0, 1))
    with assert_raises(contains="EXPR_LIKE_STRING right operand must be EXPR_LIT_STRING (kind=32)"):
        _ = _run(ExpressionExecutor(p2^, 2, _names()), b)


# -----------------------------------------------------------------------------
# Decimal128
# -----------------------------------------------------------------------------


def _dec_exec(kind: Int, var lhs: RuntimeExpr, var rhs: RuntimeExpr) -> ExpressionExecutor:
    """Decimal pool: 0 = 1.00 (100 @ 2), 1 = 2.50 (250 @ 2),
    2 = 3.00 (300 @ 2), 3 = 5 (5 @ 0), 4 = 5.0 (50 @ 1), 5 = 4.9 (49 @ 1)."""
    var pool = List[RuntimeExpr]()
    pool.append(lhs)
    pool.append(rhs)
    pool.append(_node(kind, 0, 1))
    var dp = List[DecimalSpec]()
    dp.append(DecimalSpec(SIMD[DType.int128, 1](100), 10, 2))
    dp.append(DecimalSpec(SIMD[DType.int128, 1](250), 10, 2))
    dp.append(DecimalSpec(SIMD[DType.int128, 1](300), 10, 2))
    dp.append(DecimalSpec(SIMD[DType.int128, 1](5), 10, 0))
    dp.append(DecimalSpec(SIMD[DType.int128, 1](50), 10, 1))
    dp.append(DecimalSpec(SIMD[DType.int128, 1](49), 10, 1))
    return ExpressionExecutor(pool^, 2, _names(), decimal_pool=dp^)


def _dec_kinds() -> List[Int]:
    var kinds: List[Int] = [
        EXPR_EQ_DECIMAL128, EXPR_NEQ_DECIMAL128, EXPR_GT_DECIMAL128,
        EXPR_LT_DECIMAL128, EXPR_GE_DECIMAL128, EXPR_LE_DECIMAL128,
    ]
    return kinds^


def _dec_case(
    b: RecordBatch, var lhs: RuntimeExpr, var rhs: RuntimeExpr,
    want: List[List[Int]], what: String,
) raises:
    var kinds = _dec_kinds()
    for k in range(6):
        _expect(_run(_dec_exec(kinds[k], lhs, rhs), b), want[k], what + ", kind " + String(kinds[k]))


def test_decimal_column_column_across_scales() raises:
    """d1 (scale 2) vs d2 (scale 1): 1.00 = 1.0, 2.50 < 3.0, -0.05 < 0.0,
    0.00 > -0.1, 3.00 = 3.0. The left scale is the larger one."""
    var b = _batch()
    var want: List[List[Int]] = [[0, 4], [1, 2, 3], [3], [1, 2], [0, 3, 4], [0, 1, 2, 4]]
    _dec_case(b, make_col_decimal128(D1), make_col_decimal128(D2), want, "d1 op d2")


def test_decimal_column_column_same_scale() raises:
    """d1 vs d3, both scale 2: equal but in row 2 (-0.05 < 9.99)."""
    var b = _batch()
    var want: List[List[Int]] = [[0, 1, 3, 4], [2], _none(), [2], [0, 1, 3, 4], _all()]
    _dec_case(b, make_col_decimal128(D1), make_col_decimal128(D3), want, "d1 op d3")


def test_decimal_column_literal_smaller_column_scale() raises:
    """d2 (scale 1) vs 1.00 (scale 2): the column side is rescaled.
    d2 = [1.0, 3.0, 0.0, -0.1, 3.0]."""
    var b = _batch()
    var want: List[List[Int]] = [[0], [1, 2, 3, 4], [1, 4], [2, 3], [0, 1, 4], [0, 2, 3]]
    _dec_case(b, make_col_decimal128(D2), make_lit_decimal128(0), want, "d2 op 1.00")


def test_decimal_literal_column_larger_literal_scale() raises:
    """3.00 (scale 2) vs d2 (scale 1): 3.00 vs [1.0, 3.0, 0.0, -0.1, 3.0]."""
    var b = _batch()
    var want: List[List[Int]] = [[1, 4], [0, 2, 3], [0, 2, 3], _none(), _all(), [1, 4]]
    _dec_case(b, make_lit_decimal128(2), make_col_decimal128(D2), want, "3.00 op d2")


def test_decimal_literal_literal() raises:
    """5 (scale 0) vs 5.0 (scale 1) are equal; 2.50 vs 1.00 at one scale;
    4.9 vs 5 across scales."""
    var b = _batch()
    var eq: List[List[Int]] = [_all(), _none(), _none(), _none(), _all(), _all()]
    _dec_case(b, make_lit_decimal128(3), make_lit_decimal128(4), eq, "5 op 5.0")
    var gt: List[List[Int]] = [_none(), _all(), _all(), _none(), _all(), _none()]
    _dec_case(b, make_lit_decimal128(1), make_lit_decimal128(0), gt, "2.50 op 1.00")
    var lt: List[List[Int]] = [_none(), _all(), _none(), _all(), _none(), _all()]
    _dec_case(b, make_lit_decimal128(5), make_lit_decimal128(3), lt, "4.9 op 5")


def test_decimal_refuses_other_operands() raises:
    var b = _batch()
    with assert_raises(contains="EXPR_*_DECIMAL128 left operand must be EXPR_COL_DECIMAL128 or EXPR_LIT_DECIMAL128 (kind=1)"):
        _ = _run(_dec_exec(EXPR_EQ_DECIMAL128, make_lit_i64(1), make_col_decimal128(D1)), b)
    with assert_raises(contains="EXPR_*_DECIMAL128 right operand must be EXPR_COL_DECIMAL128 or EXPR_LIT_DECIMAL128 (kind=1)"):
        _ = _run(_dec_exec(EXPR_LT_DECIMAL128, make_col_decimal128(D1), make_lit_i64(1)), b)


def main() raises:
    var suite = TestSuite()
    suite.test[test_string_equality_column_column]()
    suite.test[test_string_equality_column_literal]()
    suite.test[test_string_equality_literal_column]()
    suite.test[test_string_equality_literal_literal]()
    suite.test[test_string_equality_refuses_other_operands]()
    suite.test[test_string_is_null_and_is_not_null]()
    suite.test[test_string_order_column_column]()
    suite.test[test_string_order_column_literal]()
    suite.test[test_string_order_literal_column]()
    suite.test[test_string_order_literal_literal_prefix_sorts_first]()
    suite.test[test_string_order_refuses_other_operands]()
    suite.test[test_like_column_against_pattern]()
    suite.test[test_like_refuses_other_operands]()
    suite.test[test_decimal_column_column_across_scales]()
    suite.test[test_decimal_column_column_same_scale]()
    suite.test[test_decimal_column_literal_smaller_column_scale]()
    suite.test[test_decimal_literal_column_larger_literal_scale]()
    suite.test[test_decimal_literal_literal]()
    suite.test[test_decimal_refuses_other_operands]()
    suite^.run()
