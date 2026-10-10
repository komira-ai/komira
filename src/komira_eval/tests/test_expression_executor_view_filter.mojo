# =============================================================================
# The BatchView filter walker of `ExpressionExecutor`: every numeric
# comparison kind, the Bool leaves, NOT, OR, a nested AND, the mixed
# Float64-vs-Int64 compares, the IN-list probe per column type, and the two
# conjunction entry points (`select_expression_from_view` and its range
# sibling).
#
# Each case states its rows and the exact survivor list, worked by hand from
# the fixture, so a wrong operator, a dropped arm or a lost row shows as a
# different list. Columns hold no NULL except the IN-list fixture, whose NULL
# rows store a value the list matches, so a probe that skipped the validity
# check would keep them.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import batch_view_over
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_eval.expression_executor import ExpressionExecutor
from komira_eval.filter_state import FilterState
from komira_kernels.runtime_expr import (
    EXPR_EQ_F64,
    EXPR_EQ_F64_MIXED,
    EXPR_EQ_I64,
    EXPR_GE_F64,
    EXPR_GE_F64_MIXED,
    EXPR_GE_I64,
    EXPR_GT_F64,
    EXPR_GT_F64_MIXED,
    EXPR_GT_I64,
    EXPR_LE_F64,
    EXPR_LE_F64_MIXED,
    EXPR_LE_I64,
    EXPR_LT_F64,
    EXPR_LT_F64_MIXED,
    EXPR_LT_I64,
    EXPR_NE_F64,
    EXPR_NE_I64,
    RuntimeExpr,
    make_and,
    make_col,
    make_col_bool,
    make_col_decimal128,
    make_col_string,
    make_eq_i64,
    make_ge_i64,
    make_gt_i64,
    make_in_list,
    make_le_i64,
    make_lit_bool,
    make_lit_f64,
    make_lit_i64,
    make_lt_i64,
    make_not_bool,
    make_or,
)
from komira_plan_expr.scalar_value import ScalarValue


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------


def _i64(vals: List[Int]) -> Column[HeapRegion]:
    var l = List[Scalar[DType.int64]]()
    for v in vals:
        l.append(Scalar[DType.int64](Int64(v)))
    return Column.from_primitive[DType.int64](
        PrimitiveArray[DType.int64].from_list(l^)
    )


def _i32(vals: List[Int], arrow_type: ArrowType) -> Column[HeapRegion]:
    var l = List[Scalar[DType.int32]]()
    for v in vals:
        l.append(Scalar[DType.int32](Int32(v)))
    return Column.from_primitive_with_arrow_type[DType.int32](
        PrimitiveArray[DType.int32].from_list(l^), arrow_type
    )


def _f64(vals: List[Float64]) -> Column[HeapRegion]:
    var l = List[Scalar[DType.float64]]()
    for v in vals:
        l.append(Scalar[DType.float64](v))
    return Column.from_primitive[DType.float64](
        PrimitiveArray[DType.float64].from_list(l^)
    )


def _bools(vals: List[Bool]) -> Column[HeapRegion]:
    var a = BooleanArray.allocate(len(vals))
    for i in range(len(vals)):
        a.set(i, vals[i])
    return Column.from_boolean(a^)


def _batch(fields: List[Field], var cols: Slab[Column[HeapRegion]]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    for i in range(len(fields)):
        sb.add_field(fields[i])
    return RecordBatch.from_typed_columns_slab(sb.build(), cols^)


def _numeric_batch() raises -> RecordBatch:
    """Five rows.

    | row | i | j | f   | g   | h (int32) | dt (date32) | b     |
    |-----|---|---|-----|-----|-----------|-------------|-------|
    | 0   | 5 | 5 | 0.5 | 0.5 | 5         | 5           | true  |
    | 1   | 1 | 2 | 1.5 | 2.0 | 1         | 2           | false |
    | 2   | 4 | 3 | 2.5 | 2.0 | 4         | 3           | true  |
    | 3   | 2 | 2 | 3.5 | 3.5 | 2         | 2           | false |
    | 4   | 3 | 9 | 4.5 | 1.0 | 3         | 9           | true  |
    """
    var fields = List[Field]()
    fields.append(Field("i", DType.int64, True))
    fields.append(Field("j", DType.int64, True))
    fields.append(Field("f", DType.float64, True))
    fields.append(Field("g", DType.float64, True))
    fields.append(Field("h", ArrowType.INT32, True))
    fields.append(Field("dt", ArrowType.DATE32, True))
    fields.append(Field("b", ArrowType.BOOL, True))
    var cols = Slab[Column[HeapRegion]]()
    cols.append(_i64([5, 1, 4, 2, 3]))
    cols.append(_i64([5, 2, 3, 2, 9]))
    cols.append(_f64([0.5, 1.5, 2.5, 3.5, 4.5]))
    cols.append(_f64([0.5, 2.0, 2.0, 3.5, 1.0]))
    cols.append(_i32([5, 1, 4, 2, 3], ArrowType.INT32))
    cols.append(_i32([5, 2, 3, 2, 9], ArrowType.DATE32))
    cols.append(_bools([True, False, True, False, True]))
    return _batch(fields, cols^)


def _numeric_names() -> List[String]:
    var names: List[String] = ["i", "j", "f", "g", "h", "dt", "b"]
    return names^


# Column slots of `_numeric_names`.
comptime I = 0
comptime J = 1
comptime F = 2
comptime G = 3
comptime H = 4
comptime DT = 5
comptime B = 6


def _run(
    exec: ExpressionExecutor, batch: RecordBatch, n_pred: Int = 1
) raises -> List[Int]:
    """Survivors of `select_expression_from_view`, in order."""
    var fs = FilterState.with_conjunction(n_predicates=n_pred, worker_id=0)
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


def _cmp_exec(kind: Int, var lhs: RuntimeExpr, var rhs: RuntimeExpr) -> ExpressionExecutor:
    """Pool [lhs, rhs, kind(0, 1)], root 2, over the numeric names."""
    var pool = List[RuntimeExpr]()
    pool.append(lhs)
    pool.append(rhs)
    pool.append(_node(kind, 0, 1))
    return ExpressionExecutor(pool^, 2, _numeric_names())


# -----------------------------------------------------------------------------
# Numeric comparisons through `_dispatch_comparison_from_view`
# -----------------------------------------------------------------------------


def test_int64_column_against_literal_every_operator() raises:
    """`i <op> 3` over i = [5, 1, 4, 2, 3]."""
    var batch = _numeric_batch()
    var kinds: List[Int] = [
        EXPR_GT_I64, EXPR_GE_I64, EXPR_LT_I64, EXPR_LE_I64, EXPR_EQ_I64, EXPR_NE_I64
    ]
    var want: List[List[Int]] = [
        [0, 2], [0, 2, 4], [1, 3], [1, 3, 4], [4], [0, 1, 2, 3]
    ]
    for k in range(len(kinds)):
        var exec = _cmp_exec(kinds[k], make_col(I), make_lit_i64(3))
        _expect(_run(exec, batch), want[k], "i op 3, kind " + String(kinds[k]))


def test_int64_column_against_column() raises:
    """i = [5, 1, 4, 2, 3], j = [5, 2, 3, 2, 9]."""
    var batch = _numeric_batch()
    _expect(_run(_cmp_exec(EXPR_LT_I64, make_col(I), make_col(J)), batch), [1, 4], "i < j")
    _expect(_run(_cmp_exec(EXPR_EQ_I64, make_col(I), make_col(J)), batch), [0, 3], "i = j")


def test_float64_column_against_literal_every_operator() raises:
    """`f <op> 2.5` over f = [0.5, 1.5, 2.5, 3.5, 4.5]."""
    var batch = _numeric_batch()
    var kinds: List[Int] = [
        EXPR_GT_F64, EXPR_GE_F64, EXPR_LT_F64, EXPR_LE_F64, EXPR_EQ_F64, EXPR_NE_F64
    ]
    var want: List[List[Int]] = [
        [3, 4], [2, 3, 4], [0, 1], [0, 1, 2], [2], [0, 1, 3, 4]
    ]
    for k in range(len(kinds)):
        var exec = _cmp_exec(kinds[k], make_col(F), make_lit_f64(2.5))
        _expect(_run(exec, batch), want[k], "f op 2.5, kind " + String(kinds[k]))


def test_float64_column_against_column() raises:
    """f = [0.5, 1.5, 2.5, 3.5, 4.5], g = [0.5, 2.0, 2.0, 3.5, 1.0]."""
    var batch = _numeric_batch()
    _expect(_run(_cmp_exec(EXPR_GT_F64, make_col(F), make_col(G)), batch), [2, 4], "f > g")
    _expect(_run(_cmp_exec(EXPR_EQ_F64, make_col(F), make_col(G)), batch), [0, 3], "f = g")


def test_int32_and_date32_left_columns_compare_as_int32() raises:
    """An Int64 comparison whose left column is INT32 or DATE32 reads it as
    Int32: h = [5, 1, 4, 2, 3], dt = [5, 2, 3, 2, 9]."""
    var batch = _numeric_batch()
    _expect(_run(_cmp_exec(EXPR_GT_I64, make_col(H), make_lit_i64(3)), batch), [0, 2], "h > 3")
    _expect(_run(_cmp_exec(EXPR_GE_I64, make_col(DT), make_lit_i64(3)), batch), [0, 2, 4], "dt >= 3")
    _expect(_run(_cmp_exec(EXPR_LT_I64, make_col(H), make_col(DT)), batch), [1, 4], "h < dt")
    _expect(_run(_cmp_exec(EXPR_EQ_I64, make_col(H), make_col(H)), batch), [0, 1, 2, 3, 4], "h = h")


def test_int32_left_against_int64_right_column_is_refused() raises:
    var batch = _numeric_batch()
    var exec = _cmp_exec(EXPR_LT_I64, make_col(H), make_col(I))
    with assert_raises(contains="mixed-width int32-vs-int64 column-vs-column"):
        _ = _run(exec, batch)


def test_comparison_shape_refusals() raises:
    var batch = _numeric_batch()
    var lit_left = _cmp_exec(EXPR_GT_I64, make_lit_i64(3), make_col(I))
    with assert_raises(contains="comparison at pool slot 2 expects EXPR_COL on the LEFT"):
        _ = _run(lit_left, batch)
    var f64_lit_for_i64 = _cmp_exec(EXPR_GT_I64, make_col(I), make_lit_f64(3.0))
    with assert_raises(contains="expects EXPR_LIT_I64 (or EXPR_COL) on the RIGHT for an Int64/Int32 comparison; got kind 2"):
        _ = _run(f64_lit_for_i64, batch)
    var i64_lit_for_f64 = _cmp_exec(EXPR_GT_F64, make_col(F), make_lit_i64(3))
    with assert_raises(contains="expects EXPR_LIT_F64 (or EXPR_COL) on the RIGHT for a Float64 comparison; got kind 1"):
        _ = _run(i64_lit_for_f64, batch)


# -----------------------------------------------------------------------------
# Bool leaves, NOT, OR, nested AND
# -----------------------------------------------------------------------------


def test_bool_column_and_bool_literals() raises:
    var batch = _numeric_batch()
    var p1 = List[RuntimeExpr]()
    p1.append(make_col_bool(B))
    _expect(_run(ExpressionExecutor(p1^, 0, _numeric_names()), batch), [0, 2, 4], "b")
    var p2 = List[RuntimeExpr]()
    p2.append(make_lit_bool(True))
    _expect(_run(ExpressionExecutor(p2^, 0, _numeric_names()), batch), [0, 1, 2, 3, 4], "TRUE")
    var p3 = List[RuntimeExpr]()
    p3.append(make_lit_bool(False))
    _expect(_run(ExpressionExecutor(p3^, 0, _numeric_names()), batch), List[Int](), "FALSE")


def test_bool_leaves_as_a_later_conjunct() raises:
    """i <= 3 AND b, and i <= 3 AND TRUE: the Bool leaf sees the first
    conjunct's survivors [1, 3, 4] (i = [5, 1, 4, 2, 3]), not [0..n).
    b = [T, F, T, F, T] keeps only row 4 of them; TRUE keeps all three."""
    var batch = _numeric_batch()
    var p1 = List[RuntimeExpr]()
    p1.append(make_col(I))
    p1.append(make_lit_i64(3))
    p1.append(make_le_i64(0, 1))
    p1.append(make_col_bool(B))
    p1.append(make_and(2, 3))
    _expect(_run(ExpressionExecutor(p1^, 4, _numeric_names()), batch, 2), [4], "i <= 3 AND b")
    var p2 = List[RuntimeExpr]()
    p2.append(make_col(I))
    p2.append(make_lit_i64(3))
    p2.append(make_le_i64(0, 1))
    p2.append(make_lit_bool(True))
    p2.append(make_and(2, 3))
    _expect(_run(ExpressionExecutor(p2^, 4, _numeric_names()), batch, 2), [1, 3, 4], "i <= 3 AND TRUE")


def test_not_is_the_complement_within_the_input() raises:
    """NOT (i > 3): i > 3 keeps [0, 2]; the complement in [0..4] is [1, 3, 4]."""
    var batch = _numeric_batch()
    var pool = List[RuntimeExpr]()
    pool.append(make_col(I))
    pool.append(make_lit_i64(3))
    pool.append(make_gt_i64(0, 1))
    pool.append(make_not_bool(2))
    _expect(_run(ExpressionExecutor(pool^, 3, _numeric_names()), batch), [1, 3, 4], "NOT i > 3")


def _or_exec(lk: Int, lv: Int, rk: Int, rv: Int, r_col: Int = I) -> ExpressionExecutor:
    """(i <lk> lv) OR (r_col <rk> rv)."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(I))
    pool.append(make_lit_i64(Int64(lv)))
    pool.append(_node(lk, 0, 1))
    pool.append(make_col(r_col))
    pool.append(make_lit_i64(Int64(rv)))
    pool.append(_node(rk, 3, 4))
    pool.append(make_or(2, 5))
    return ExpressionExecutor(pool^, 6, _numeric_names())


def test_or_merges_both_sides_in_row_order() raises:
    """i = [5, 1, 4, 2, 3], j = [5, 2, 3, 2, 9]."""
    var batch = _numeric_batch()
    # left [0, 2, 4], right [1, 3]: interleaved, left tail 4.
    _expect(_run(_or_exec(EXPR_GE_I64, 3, EXPR_EQ_I64, 2, J), batch), [0, 1, 2, 3, 4], "i >= 3 OR j = 2")
    # left [0, 2], right [0]: a shared row once, left tail 2.
    _expect(_run(_or_exec(EXPR_GE_I64, 4, EXPR_GE_I64, 5), batch), [0, 2], "i >= 4 OR i >= 5")
    # left [0], right [1, 3, 4]: right tail.
    _expect(_run(_or_exec(EXPR_EQ_I64, 5, EXPR_LE_I64, 3), batch), [0, 1, 3, 4], "i = 5 OR i <= 3")
    # left [1], right [0, 2]: right first, then left.
    _expect(_run(_or_exec(EXPR_LT_I64, 2, EXPR_GT_I64, 3), batch), [0, 1, 2], "i < 2 OR i > 3")


def test_and_nested_under_or() raises:
    """(i > 1 AND j > 2) OR i = 1: the AND keeps [0, 2, 4], the OR adds 1."""
    var batch = _numeric_batch()
    var pool = List[RuntimeExpr]()
    pool.append(make_col(I))          # 0
    pool.append(make_lit_i64(1))      # 1
    pool.append(make_gt_i64(0, 1))    # 2: i > 1
    pool.append(make_col(J))          # 3
    pool.append(make_lit_i64(2))      # 4
    pool.append(make_gt_i64(3, 4))    # 5: j > 2
    pool.append(make_and(2, 5))       # 6
    pool.append(make_eq_i64(0, 1))    # 7: i = 1
    pool.append(make_or(6, 7))        # 8
    _expect(_run(ExpressionExecutor(pool^, 8, _numeric_names()), batch), [0, 1, 2, 4], "AND under OR")


def test_mixed_float64_against_int64_every_operator() raises:
    """`i <op> 3.0` with i an Int64 column widened to Float64."""
    var batch = _numeric_batch()
    var kinds: List[Int] = [
        EXPR_LT_F64_MIXED, EXPR_LE_F64_MIXED, EXPR_GT_F64_MIXED,
        EXPR_GE_F64_MIXED, EXPR_EQ_F64_MIXED,
    ]
    var want: List[List[Int]] = [[1, 3], [1, 3, 4], [0, 2], [0, 2, 4], [4]]
    for k in range(len(kinds)):
        var exec = _cmp_exec(kinds[k], make_col(I), make_lit_f64(3.0))
        _expect(_run(exec, batch), want[k], "i op 3.0, kind " + String(kinds[k]))


def test_unsupported_root_kind_is_refused() raises:
    var batch = _numeric_batch()
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_i64(7))
    var exec = ExpressionExecutor(pool^, 0, _numeric_names())
    with assert_raises(contains="_eval_bool_from_view: unsupported node kind 1 at pool slot 0"):
        _ = _run(exec, batch)


# -----------------------------------------------------------------------------
# IN-list per column type
# -----------------------------------------------------------------------------


def _in_batch() raises -> RecordBatch:
    """Five rows; row 1 is NULL in every column but `f32`, its stored value
    the zero (or empty string) the lists below include.

    | row | a64 | a32 | af  | as | ab    | f32 | dec  |
    |-----|-----|-----|-----|----|-------|-----|------|
    | 0   | 1   | 5   | 0.5 | x  | true  | 1   | 1.00 |
    | 1   | N/0 | N/0 | N/0 | N  | N/F   | 2   | 2.00 |
    | 2   | 3   | 4   | 2.0 | y  | false | 3   | 3.00 |
    | 3   | 1   | 2   | 3.0 | z  | true  | 4   | 4.00 |
    | 4   | 7   | 3   | 2.0 | x  | false | 5   | 5.00 |
    """
    var a64 = PrimitiveArray[DType.int64].allocate_nullable(5)
    var a32 = PrimitiveArray[DType.int32].allocate_nullable(5)
    var af = PrimitiveArray[DType.float64].allocate_nullable(5)
    var ab = BooleanArray.allocate_nullable(5)
    var v64: List[Int] = [1, 0, 3, 1, 7]
    var v32: List[Int] = [5, 0, 4, 2, 3]
    var vf: List[Float64] = [0.5, 0.0, 2.0, 3.0, 2.0]
    var vb: List[Bool] = [True, False, False, True, False]
    for r in range(5):
        a64.set(r, Scalar[DType.int64](Int64(v64[r])))
        a32.set(r, Scalar[DType.int32](Int32(v32[r])))
        af.set(r, Scalar[DType.float64](vf[r]))
        ab.set(r, vb[r])
    a64._set_null(1)
    a32._set_null(1)
    af._set_null(1)
    ab._set_null(1)
    var sv: List[String] = ["x", "", "y", "z", "x"]
    var sok: List[Bool] = [True, False, True, True, True]
    var f32l = List[Scalar[DType.float32]]()
    for r in range(5):
        f32l.append(Scalar[DType.float32](Float32(r + 1)))
    var dl = List[SIMD[DType.int128, 1]]()
    for r in range(5):
        dl.append(SIMD[DType.int128, 1]((r + 1) * 100))
    var fields = List[Field]()
    fields.append(Field("a64", DType.int64, True))
    fields.append(Field("a32", DType.int32, True))
    fields.append(Field("af", DType.float64, True))
    fields.append(Field("as", ArrowType.STRING, True))
    fields.append(Field("ab", ArrowType.BOOL, True))
    fields.append(Field("f32", DType.float32, True))
    fields.append(Field.decimal128("dec", 10, 2, True))
    var cols = Slab[Column[HeapRegion]]()
    cols.append(Column.from_primitive[DType.int64](a64^))
    cols.append(Column.from_primitive[DType.int32](a32^))
    cols.append(Column.from_primitive[DType.float64](af^))
    cols.append(Column.from_string(StringArray.from_strings_with_validity(sv, sok)))
    cols.append(Column.from_boolean(ab^))
    cols.append(Column.from_primitive[DType.float32](
        PrimitiveArray[DType.float32].from_list(f32l^)
    ))
    cols.append(Column.from_decimal128(Decimal128Array.from_i128_list(dl, 10, 2)))
    return _batch(fields, cols^)


def _in_exec(var leaf: RuntimeExpr, var values: List[ScalarValue]) -> ExpressionExecutor:
    var pool = List[RuntimeExpr]()
    pool.append(leaf)
    pool.append(make_in_list(0, 0))
    var lists = List[List[ScalarValue]]()
    lists.append(values^)
    var names: List[String] = ["a64", "a32", "af", "as", "ab", "f32", "dec"]
    return ExpressionExecutor(pool^, 1, names^, in_list_pool=lists^)


def test_in_list_int64_skips_null_and_non_integer_values() raises:
    """a64 IN (0, 1, 2.5): 2.5 is no Int64 value; row 1 stores 0 but is NULL."""
    var batch = _in_batch()
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int(0))
    vals.append(ScalarValue.from_int(1))
    vals.append(ScalarValue.from_float(2.5))
    _expect(_run(_in_exec(make_col(0), vals^), batch), [0, 3], "a64 IN (0, 1, 2.5)")
    # A list of non-integral floats only: no Int64 value equals 3.5, no row
    # matches. Whole-number floats are test_in_list_int_column_*_float_entry.
    var only_float = List[ScalarValue]()
    only_float.append(ScalarValue.from_float(3.5))
    _expect(_run(_in_exec(make_col(0), only_float^), batch), List[Int](), "a64 IN (3.5)")


def test_in_list_int32_skips_null_and_non_integer_values() raises:
    """a32 IN (0, 4, 'x', 3) over [5, N/0, 4, 2, 3]."""
    var batch = _in_batch()
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int(0))
    vals.append(ScalarValue.from_int(4))
    vals.append(ScalarValue.from_string("x"))
    vals.append(ScalarValue.from_int(3))
    _expect(_run(_in_exec(make_col(1), vals^), batch), [2, 4], "a32 IN (0, 4, 'x', 3)")


def test_in_list_int_column_matches_a_whole_number_float_entry() raises:
    """`x IN (v, ...)` is `x = v OR ...` (query_semantics.md §1), and an
    integer column compared with a float compares as Float64, so a
    whole-number float entry matches the equal integer (DuckDB agrees).
    a64 = [1, N/0, 3, 1, 7], a32 = [5, N/0, 4, 2, 3] (komira-ai/komira#932)."""
    var batch = _in_batch()
    var three = List[ScalarValue]()
    three.append(ScalarValue.from_float(3.0))
    _expect(_run(_in_exec(make_col(0), three^), batch), [2], "a64 IN (3.0)")
    var mixed = List[ScalarValue]()
    mixed.append(ScalarValue.from_float(2.5))
    mixed.append(ScalarValue.from_float(7.0))
    _expect(_run(_in_exec(make_col(0), mixed^), batch), [4], "a64 IN (2.5, 7.0)")
    # Row 1 is NULL and stores 0: a float 0.0 entry does not reach it.
    var zero = List[ScalarValue]()
    zero.append(ScalarValue.from_float(0.0))
    _expect(_run(_in_exec(make_col(0), zero^), batch), List[Int](), "a64 IN (0.0)")
    # A float far outside the Int64 range matches nothing and is not converted.
    var huge = List[ScalarValue]()
    huge.append(ScalarValue.from_float(1.0e300))
    huge.append(ScalarValue.from_float(-1.0e300))
    _expect(_run(_in_exec(make_col(0), huge^), batch), List[Int](), "a64 IN (1e300, -1e300)")
    var four = List[ScalarValue]()
    four.append(ScalarValue.from_float(4.0))
    four.append(ScalarValue.from_float(3.5))
    _expect(_run(_in_exec(make_col(1), four^), batch), [2], "a32 IN (4.0, 3.5)")


def test_in_list_int32_column_does_not_wrap_a_wide_integer_entry() raises:
    """2^32 + 4 and 2^32 + 3 are no Int32 value: no row of
    a32 = [5, N/0, 4, 2, 3] equals either. Narrowed to Int32 they would be
    4 and 3 and keep rows 2 and 4."""
    var batch = _in_batch()
    var wide = List[ScalarValue]()
    wide.append(ScalarValue.from_int(4294967300))
    wide.append(ScalarValue.from_int(4294967299))
    _expect(_run(_in_exec(make_col(1), wide^), batch), List[Int](), "a32 IN (2^32 + 4, 2^32 + 3)")
    var neg = List[ScalarValue]()
    neg.append(ScalarValue.from_int(-4294967294))
    _expect(_run(_in_exec(make_col(1), neg^), batch), List[Int](), "a32 IN (-(2^32) + 2)")


def test_in_list_float64_takes_floats_and_widened_integers() raises:
    """af IN (0.0, 2.0, 3, 'x') over [0.5, N/0.0, 2.0, 3.0, 2.0]."""
    var batch = _in_batch()
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_float(0.0))
    vals.append(ScalarValue.from_float(2.0))
    vals.append(ScalarValue.from_int(3))
    vals.append(ScalarValue.from_string("x"))
    _expect(_run(_in_exec(make_col(2), vals^), batch), [2, 3, 4], "af IN (0.0, 2.0, 3, 'x')")


def test_in_list_string_skips_null_and_non_string_values() raises:
    """as IN (7, '', 'x') over [x, NULL, y, z, x]: the NULL row's empty slot
    does not match ''."""
    var batch = _in_batch()
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int(7))
    vals.append(ScalarValue.from_string(""))
    vals.append(ScalarValue.from_string("x"))
    _expect(_run(_in_exec(make_col_string(3), vals^), batch), [0, 4], "as IN (7, '', 'x')")


def test_in_list_bool_per_truth_value() raises:
    """ab = [true, N/false, false, true, false]."""
    var batch = _in_batch()
    var t = List[ScalarValue]()
    t.append(ScalarValue.from_bool(True))
    _expect(_run(_in_exec(make_col_bool(4), t^), batch), [0, 3], "ab IN (true)")
    var f = List[ScalarValue]()
    f.append(ScalarValue.from_int(1))
    f.append(ScalarValue.from_bool(False))
    _expect(_run(_in_exec(make_col_bool(4), f^), batch), [2, 4], "ab IN (1, false)")
    var both = List[ScalarValue]()
    both.append(ScalarValue.from_bool(False))
    both.append(ScalarValue.from_bool(True))
    _expect(_run(_in_exec(make_col_bool(4), both^), batch), [0, 2, 3, 4], "ab IN (false, true)")


def test_in_list_empty_list_matches_nothing() raises:
    var batch = _in_batch()
    _expect(_run(_in_exec(make_col(0), List[ScalarValue]()), batch), List[Int](), "a64 IN ()")


def test_in_list_refusals() raises:
    var batch = _in_batch()
    var one = List[ScalarValue]()
    one.append(ScalarValue.from_int(1))
    with assert_raises(contains="EXPR_IN_LIST at pool slot 1 has unsupported column ArrowType"):
        _ = _run(_in_exec(make_col(5), one.copy()), batch)
    with assert_raises(contains="EXPR_IN_LIST at pool slot 1 has unsupported column ArrowType"):
        _ = _run(_in_exec(make_col_decimal128(6), one.copy()), batch)
    with assert_raises(contains="EXPR_IN_LIST child at pool slot 1 must be a column-leaf"):
        _ = _run(_in_exec(make_lit_i64(1), one.copy()), batch)


# -----------------------------------------------------------------------------
# The conjunction entry points
# -----------------------------------------------------------------------------


def _chain(k: Int) -> ExpressionExecutor:
    """The first `k` of: i >= 2, i <= 4, j >= 3, h < 4, left-leaning AND."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(I))          # 0
    pool.append(make_lit_i64(2))      # 1
    pool.append(make_ge_i64(0, 1))    # 2
    pool.append(make_lit_i64(4))      # 3
    pool.append(make_le_i64(0, 3))    # 4
    pool.append(make_col(J))          # 5
    pool.append(make_lit_i64(3))      # 6
    pool.append(make_ge_i64(5, 6))    # 7
    pool.append(make_col(H))          # 8
    pool.append(make_lit_i64(4))      # 9
    pool.append(make_lt_i64(8, 9))    # 10
    var preds: List[Int] = [2, 4, 7, 10]
    var root = preds[0]
    for p in range(1, k):
        pool.append(make_and(root, preds[p]))
        root = len(pool) - 1
    return ExpressionExecutor(pool^, root, _numeric_names())


def test_from_view_chains_of_three_and_four() raises:
    """i = [5, 1, 4, 2, 3], j = [5, 2, 3, 2, 9], h = i.
    i >= 2 -> [0, 2, 3, 4]; i <= 4 -> [2, 3, 4]; j >= 3 -> [2, 4]; h < 4 -> [4]."""
    var batch = _numeric_batch()
    _expect(_run(_chain(2), batch, 2), [2, 3, 4], "two conjuncts")
    _expect(_run(_chain(3), batch, 3), [2, 4], "three conjuncts")
    _expect(_run(_chain(4), batch, 4), [4], "four conjuncts")


def test_from_view_refuses_a_conjunction_state_of_another_length() raises:
    var batch = _numeric_batch()
    with assert_raises(contains="select_expression_from_view: conjunction state n_predicates=2 does not match flattened chain length 3"):
        _ = _run(_chain(3), batch, 2)


def _big_batch(n: Int) raises -> RecordBatch:
    var vals = List[Int]()
    for r in range(n):
        vals.append(r)
    var fields = List[Field]()
    fields.append(Field("i", DType.int64, True))
    var cols = Slab[Column[HeapRegion]]()
    cols.append(_i64(vals))
    return _batch(fields, cols^)


def test_not_and_or_over_an_empty_batch() raises:
    """Zero rows: NOT, OR and a nested AND keep nothing."""
    var batch = _big_batch(0)
    var p1 = List[RuntimeExpr]()
    p1.append(make_col(I))
    p1.append(make_lit_i64(3))
    p1.append(make_gt_i64(0, 1))
    p1.append(make_not_bool(2))
    _expect(_run(ExpressionExecutor(p1^, 3, _numeric_names()), batch), List[Int](), "NOT over no rows")
    var p2 = List[RuntimeExpr]()
    p2.append(make_col(I))          # 0
    p2.append(make_lit_i64(3))      # 1
    p2.append(make_gt_i64(0, 1))    # 2
    p2.append(make_lt_i64(0, 1))    # 3
    p2.append(make_and(2, 3))       # 4
    p2.append(make_eq_i64(0, 1))    # 5
    p2.append(make_or(4, 5))        # 6
    _expect(_run(ExpressionExecutor(p2^, 6, _numeric_names()), batch), List[Int](), "AND under OR over no rows")


def test_from_view_grows_a_default_capacity_selection() raises:
    """3000 rows exceed the default 2048-slot `fs.sel`; i >= 1000 keeps 2000."""
    var batch = _big_batch(3000)
    var exec = _cmp_exec(EXPR_GE_I64, make_col(0), make_lit_i64(1000))
    var fs = FilterState.with_conjunction(n_predicates=1, worker_id=0)
    assert_equal(fs.sel.capacity(), 2048)
    var n = exec.select_expression_from_view(batch_view_over(batch), fs)
    assert_equal(n, 2000)
    assert_equal(Int(fs.sel.get(0)), 1000)
    assert_equal(Int(fs.sel.get(1999)), 2999)


def _run_range(
    exec: ExpressionExecutor, batch: RecordBatch, start: Int, length: Int, n_pred: Int = 1
) raises -> List[Int]:
    var fs = FilterState.with_conjunction(n_predicates=n_pred, worker_id=0)
    var n = exec.select_expression_from_view_range(
        batch_view_over(batch), fs, start, length
    )
    var out = List[Int]()
    for k in range(n):
        out.append(Int(fs.sel.get(k)))
    return out^


def test_from_view_range_reports_absolute_rows() raises:
    """Over rows [1, 4): i = [1, 4, 2], j = [2, 3, 2], h = i."""
    var batch = _numeric_batch()
    _expect(_run_range(_chain(1), batch, 1, 3), [2, 3], "i >= 2 in [1, 4)")
    _expect(_run_range(_chain(2), batch, 1, 3, 2), [2, 3], "two conjuncts in [1, 4)")
    _expect(_run_range(_chain(3), batch, 1, 3, 3), [2], "three conjuncts in [1, 4)")
    _expect(_run_range(_chain(4), batch, 0, 5, 4), [4], "four conjuncts in [0, 5)")


def test_from_view_range_clamps_to_the_batch() raises:
    var batch = _numeric_batch()
    # [-2, 3) clamps to [0, 3): i = [5, 1, 4] -> i >= 2 keeps [0, 2].
    _expect(_run_range(_chain(1), batch, -2, 5), [0, 2], "negative start")
    # [3, 10) clamps to [3, 5): i = [2, 3] -> both.
    _expect(_run_range(_chain(1), batch, 3, 7), [3, 4], "length past the end")
    # [7, 9) is past the end: no row.
    _expect(_run_range(_chain(1), batch, 7, 2), List[Int](), "start past the end")


def test_from_view_range_refuses_a_conjunction_state_of_another_length() raises:
    var batch = _numeric_batch()
    with assert_raises(contains="select_expression_from_view_range: conjunction state n_predicates=1 does not match flattened chain length 2"):
        _ = _run_range(_chain(2), batch, 0, 5, 1)


def test_from_view_range_grows_a_default_capacity_selection() raises:
    """A 2500-row range of 3000 rows: more than the default 2048 slots."""
    var batch = _big_batch(3000)
    var exec = _cmp_exec(EXPR_GE_I64, make_col(0), make_lit_i64(0))
    var got = _run_range(exec, batch, 500, 2500)
    assert_equal(len(got), 2500)
    assert_equal(got[0], 500)
    assert_equal(got[2499], 2999)


def main() raises:
    var suite = TestSuite()
    suite.test[test_int64_column_against_literal_every_operator]()
    suite.test[test_int64_column_against_column]()
    suite.test[test_float64_column_against_literal_every_operator]()
    suite.test[test_float64_column_against_column]()
    suite.test[test_int32_and_date32_left_columns_compare_as_int32]()
    suite.test[test_int32_left_against_int64_right_column_is_refused]()
    suite.test[test_comparison_shape_refusals]()
    suite.test[test_bool_column_and_bool_literals]()
    suite.test[test_bool_leaves_as_a_later_conjunct]()
    suite.test[test_not_is_the_complement_within_the_input]()
    suite.test[test_or_merges_both_sides_in_row_order]()
    suite.test[test_and_nested_under_or]()
    suite.test[test_mixed_float64_against_int64_every_operator]()
    suite.test[test_unsupported_root_kind_is_refused]()
    suite.test[test_in_list_int64_skips_null_and_non_integer_values]()
    suite.test[test_in_list_int32_skips_null_and_non_integer_values]()
    suite.test[test_in_list_int_column_matches_a_whole_number_float_entry]()
    suite.test[test_in_list_int32_column_does_not_wrap_a_wide_integer_entry]()
    suite.test[test_in_list_float64_takes_floats_and_widened_integers]()
    suite.test[test_in_list_string_skips_null_and_non_string_values]()
    suite.test[test_in_list_bool_per_truth_value]()
    suite.test[test_in_list_empty_list_matches_nothing]()
    suite.test[test_in_list_refusals]()
    suite.test[test_from_view_chains_of_three_and_four]()
    suite.test[test_from_view_refuses_a_conjunction_state_of_another_length]()
    suite.test[test_not_and_or_over_an_empty_batch]()
    suite.test[test_from_view_grows_a_default_capacity_selection]()
    suite.test[test_from_view_range_reports_absolute_rows]()
    suite.test[test_from_view_range_clamps_to_the_batch]()
    suite.test[test_from_view_range_refuses_a_conjunction_state_of_another_length]()
    suite.test[test_from_view_range_grows_a_default_capacity_selection]()
    suite^.run()
