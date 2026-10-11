# =============================================================================
# The BatchView project walkers of `ExpressionExecutor`
# (`eval_to_list_{i64,f64,i32,bool,string,decimal128}_from_view`): every
# arm, over a selection that skips rows, so a walker that read row k instead
# of the k-th selected row gives a different list.
#
# Integer division truncates toward zero (docs/design/query_semantics.md
# §5.1, DuckDB's `//`: -7 // 2 is -3), over negative quotients too, in the
# Float64 walker as well. A zero divisor raises here, as standard SQL does (a
# division-by-zero exception), where DuckDB answers NULL; the tests pin the
# raise as what the code does today. Decimal result types follow the code's
# rules (`decimal_*_result_ps`).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.batch_view import batch_view_over
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.selection_vector_row import RowSelectionVector
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_column_kernels.scalar_math import KMATH_CEIL, KMATH_FLOOR
from komira_eval.expression_executor import DecimalSpec, ExpressionExecutor
from komira_plan_expr.scalar_value import ScalarValue
from komira_kernels.runtime_expr import (
    EXPR_ADD_DECIMAL128,
    EXPR_ADD_F64,
    EXPR_ADD_I32,
    EXPR_ADD_I64,
    EXPR_ASIN_F64,
    EXPR_COS_F64,
    EXPR_DIV_DECIMAL128,
    EXPR_DIV_F64,
    EXPR_DIV_I32,
    EXPR_DIV_I64,
    EXPR_MUL_DECIMAL128,
    EXPR_MUL_F64,
    EXPR_MUL_I32,
    EXPR_MUL_I64,
    EXPR_RADIANS_F64,
    EXPR_SIN_F64,
    EXPR_SUB_DECIMAL128,
    EXPR_SUB_F64,
    EXPR_SUB_I32,
    EXPR_SUB_I64,
    RuntimeExpr,
    make_atan2_f64,
    make_case_f64,
    make_case_i64,
    make_col,
    make_col_bool,
    make_col_decimal128,
    make_col_string,
    make_f64_to_i64,
    make_gt_i64,
    make_i64_to_f64,
    make_in_list,
    make_lit_bool,
    make_lit_decimal128,
    make_lit_f64,
    make_lit_i32,
    make_lit_i64,
    make_lit_string,
    make_math_unary_f64,
    make_not_bool,
    make_null,
    make_pow_f64,
    make_sqrt_f64,
)


# -----------------------------------------------------------------------------
# Fixture
# -----------------------------------------------------------------------------


def _batch() raises -> RecordBatch:
    """Four rows (N = NULL).

    | row | a  | b  | c (i32) | x    | w     | s | flag  | d (s=2) | e (s=1) |
    |-----|----|----|---------|------|-------|---|-------|---------|---------|
    | 0   | 7  | 2  | 1       | 1.5  | 3.0   | p | true  | 1.50    | 1.0     |
    | 1   | -7 | 2  | 2       | -2.5 | -2.0  | N | false | -0.25   | 2.0     |
    | 2   | 0  | 3  | 3       | 4.0  | 8.0   | r | true  | 0.00    | 3.0     |
    | 3   | 10 | -3 | 4       | 0.25 | 1e15  | s | false | 10.00   | 0.5     |
    """
    var a = List[Scalar[DType.int64]]()
    var b = List[Scalar[DType.int64]]()
    var c = List[Scalar[DType.int32]]()
    var x = List[Scalar[DType.float64]]()
    var w = List[Scalar[DType.float64]]()
    var av: List[Int] = [7, -7, 0, 10]
    var bv: List[Int] = [2, 2, 3, -3]
    var xv: List[Float64] = [1.5, -2.5, 4.0, 0.25]
    var wv: List[Float64] = [3.0, -2.0, 8.0, 1.0e15]
    for r in range(4):
        a.append(Scalar[DType.int64](Int64(av[r])))
        b.append(Scalar[DType.int64](Int64(bv[r])))
        c.append(Scalar[DType.int32](Int32(r + 1)))
        x.append(Scalar[DType.float64](xv[r]))
        w.append(Scalar[DType.float64](wv[r]))
    var flag = BooleanArray.allocate(4)
    flag.set(0, True)
    flag.set(2, True)
    var sv: List[String] = ["p", "", "r", "s"]
    var sok: List[Bool] = [True, False, True, True]
    var d = List[SIMD[DType.int128, 1]]()
    var e = List[SIMD[DType.int128, 1]]()
    var dv: List[Int] = [150, -25, 0, 1000]
    var ev: List[Int] = [10, 20, 30, 5]
    for r in range(4):
        d.append(SIMD[DType.int128, 1](dv[r]))
        e.append(SIMD[DType.int128, 1](ev[r]))
    var sb = SchemaBuilder()
    sb.add_field(Field("a", DType.int64, False))
    sb.add_field(Field("b", DType.int64, False))
    sb.add_field(Field("c", DType.int32, False))
    sb.add_field(Field("x", DType.float64, False))
    sb.add_field(Field("w", DType.float64, False))
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("flag", ArrowType.BOOL, False))
    sb.add_field(Field.decimal128("d", 10, 2, False))
    sb.add_field(Field.decimal128("e", 10, 1, False))
    var cols = Slab[Column[HeapRegion]]()
    cols.append(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(a^)))
    cols.append(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(b^)))
    cols.append(Column.from_primitive[DType.int32](PrimitiveArray[DType.int32].from_list(c^)))
    cols.append(Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(x^)))
    cols.append(Column.from_primitive[DType.float64](PrimitiveArray[DType.float64].from_list(w^)))
    cols.append(Column.from_string(StringArray.from_strings_with_validity(sv, sok)))
    cols.append(Column.from_boolean(flag^))
    cols.append(Column.from_decimal128(Decimal128Array.from_i128_list(d, 10, 2)))
    cols.append(Column.from_decimal128(Decimal128Array.from_i128_list(e, 10, 1)))
    return RecordBatch.from_typed_columns_slab(sb.build(), cols^)


comptime A = 0
comptime B = 1
comptime C = 2
comptime X = 3
comptime W = 4
comptime S = 5
comptime FLAG = 6
comptime D = 7
comptime E = 8


def _names() -> List[String]:
    var names: List[String] = ["a", "b", "c", "x", "w", "s", "flag", "d", "e"]
    return names^


def _sel(rows: List[Int]) -> RowSelectionVector:
    var sel = RowSelectionVector(4)
    for r in rows:
        sel.append(UInt32(r))
    return sel^


def _node(kind: Int, left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(kind, Int64(0), 0.0, False, 0, left, right)


def _exec(var pool: List[RuntimeExpr]) -> ExpressionExecutor:
    """Root is the last slot."""
    var root = len(pool) - 1
    return ExpressionExecutor(pool^, root, _names())


def _i64(exec: ExpressionExecutor, rows: List[Int]) raises -> List[Int]:
    var batch = _batch()
    var out = List[Scalar[DType.int64]]()
    exec.eval_to_list_i64_from_view(batch_view_over(batch), exec.root_idx, _sel(rows), out)
    var got = List[Int]()
    for v in out:
        got.append(Int(v))
    return got^


def _f64(exec: ExpressionExecutor, rows: List[Int]) raises -> List[Float64]:
    var batch = _batch()
    var out = List[Scalar[DType.float64]]()
    exec.eval_to_list_f64_from_view(batch_view_over(batch), exec.root_idx, _sel(rows), out)
    var got = List[Float64]()
    for v in out:
        got.append(Float64(v))
    return got^


def _i32(exec: ExpressionExecutor, rows: List[Int]) raises -> List[Int]:
    var batch = _batch()
    var out = List[Scalar[DType.int32]]()
    exec.eval_to_list_i32_from_view(batch_view_over(batch), exec.root_idx, _sel(rows), out)
    var got = List[Int]()
    for v in out:
        got.append(Int(v))
    return got^


def _ints(got: List[Int], want: List[Int], what: String) raises:
    assert_equal(len(got), len(want), what + ": length")
    for k in range(len(want)):
        assert_equal(got[k], want[k], what + ": value " + String(k))


def _floats(got: List[Float64], want: List[Float64], what: String) raises:
    assert_equal(len(got), len(want), what + ": length")
    for k in range(len(want)):
        assert_equal(got[k], want[k], what + ": value " + String(k))


def _binary(kind: Int, var lhs: RuntimeExpr, var rhs: RuntimeExpr) -> ExpressionExecutor:
    var pool = List[RuntimeExpr]()
    pool.append(lhs)
    pool.append(rhs)
    pool.append(_node(kind, 0, 1))
    return _exec(pool^)


def _unary(var root: RuntimeExpr, var child: RuntimeExpr) -> ExpressionExecutor:
    """Pool [child, root]; `root.left` must be 0."""
    var pool = List[RuntimeExpr]()
    pool.append(child)
    pool.append(root)
    return _exec(pool^)


def _leaf(var leaf: RuntimeExpr) -> ExpressionExecutor:
    var pool = List[RuntimeExpr]()
    pool.append(leaf)
    return _exec(pool^)


# -----------------------------------------------------------------------------
# Int64
# -----------------------------------------------------------------------------


def test_i64_leaves() raises:
    """Over rows [0, 2, 3]: a = [7, 0, 10], c = [1, 3, 4]."""
    _ints(_i64(_leaf(make_col(A)), [0, 2, 3]), [7, 0, 10], "a")
    _ints(_i64(_leaf(make_col(C)), [0, 2, 3]), [1, 3, 4], "c widened from int32")
    _ints(_i64(_leaf(make_lit_i64(9)), [0, 2, 3]), [9, 9, 9], "9")
    _ints(_i64(_leaf(make_lit_f64(4.0)), [0, 2, 3]), [4, 4, 4], "4.0 as int64")


def test_i64_arithmetic() raises:
    """Over rows [0, 2, 3]: a = [7, 0, 10], b = [2, 3, -3], c = [1, 3, 4]."""
    _ints(_i64(_binary(EXPR_ADD_I64, make_col(A), make_col(B)), [0, 2, 3]), [9, 3, 7], "a + b")
    _ints(_i64(_binary(EXPR_SUB_I64, make_col(A), make_col(B)), [0, 2, 3]), [5, -3, 13], "a - b")
    _ints(_i64(_binary(EXPR_MUL_I64, make_col(A), make_col(B)), [0, 2, 3]), [14, 0, -30], "a * b")
    _ints(_i64(_binary(EXPR_DIV_I64, make_col(A), make_col(C)), [0, 2, 3]), [7, 0, 2], "a / c")


def test_integer_division_truncates_toward_zero() raises:
    """BIN_DIV on integers truncates (§5.1): a / b over rows [0, 1, 3] is
    7 / 2, -7 / 2, 10 / -3 = [3, -3, -3]; a floor gives [3, -4, -4].
    c / -2 over c = [1, 2, 3, 4] is [0, -1, -1, -2] (floor: [-1, -1, -2, -2]),
    at the I32 root and nested under `+ 0` (komira-ai/komira#932)."""
    _ints(_i64(_binary(EXPR_DIV_I64, make_col(A), make_col(B)), [0, 1, 3]), [3, -3, -3], "a / b")
    _ints(_i32(_binary(EXPR_DIV_I32, make_col(C), make_lit_i32(-2)), [0, 1, 2, 3]), [0, -1, -1, -2], "c / -2")
    var pool = List[RuntimeExpr]()
    pool.append(make_col(C))                 # 0
    pool.append(make_lit_i32(-2))            # 1
    pool.append(_node(EXPR_DIV_I32, 0, 1))   # 2: c / -2
    pool.append(make_lit_i32(0))             # 3
    pool.append(_node(EXPR_ADD_I32, 2, 3))   # 4: (c / -2) + 0
    _ints(_i32(_exec(pool^), [0, 1, 2, 3]), [0, -1, -1, -2], "(c / -2) + 0")


def test_i64_division_by_zero_raises() raises:
    with assert_raises(contains="eval_to_list_i64_from_view: EXPR_DIV_I64 division by zero at sel index 0"):
        _ = _i64(_binary(EXPR_DIV_I64, make_col(A), make_lit_i64(0)), [0, 2, 3])


def test_i64_from_whole_float64() raises:
    """w = [3.0, -2.0, 8.0, 1e15]: whole numbers, so truncation is exact."""
    _ints(_i64(_unary(make_f64_to_i64(0), make_col(W)), [0, 1, 3]), [3, -2, 1000000000000000], "w as int64")


def _case_pool(var then0: RuntimeExpr, var then1: RuntimeExpr, var else_: RuntimeExpr, f64: Bool) -> ExpressionExecutor:
    """CASE WHEN a > 5 THEN then0 WHEN flag THEN then1 ELSE else_ END."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(A))         # 0
    pool.append(make_lit_i64(5))     # 1
    pool.append(make_gt_i64(0, 1))   # 2: a > 5
    pool.append(then0)               # 3
    pool.append(make_col_bool(FLAG)) # 4: flag
    pool.append(then1)               # 5
    pool.append(else_)               # 6
    var slots: List[Int] = [2, 3, 4, 5, 6]
    var when = List[List[Int]]()
    when.append(slots^)
    if f64:
        pool.append(make_case_f64(0))
    else:
        pool.append(make_case_i64(0))
    var root = len(pool) - 1
    return ExpressionExecutor(pool^, root, _names(), when_pool=when^)


def test_i64_case_takes_the_first_true_branch() raises:
    """a = [7, -7, 0, 10], flag = [T, F, T, F]. Over rows [1, 2, 3]:
    row 1 neither (ELSE -1), row 2 flag (b = 3), row 3 a > 5 (100)."""
    var exec = _case_pool(make_lit_i64(100), make_col(B), make_lit_i64(-1), False)
    _ints(_i64(exec, [1, 2, 3]), [-1, 3, 100], "CASE over [1, 2, 3]")
    # Row 0 meets both conditions: the first WHEN wins.
    var exec0 = _case_pool(make_lit_i64(100), make_col(B), make_lit_i64(-1), False)
    _ints(_i64(exec0, [0]), [100], "CASE over [0]")


def test_i64_unsupported_kind_raises() raises:
    with assert_raises(contains="eval_to_list_i64_from_view: unsupported node kind 3 at pool slot 0"):
        _ = _i64(_leaf(make_lit_bool(True)), [0])


# -----------------------------------------------------------------------------
# Float64
# -----------------------------------------------------------------------------


def test_f64_leaves() raises:
    """Over rows [0, 2, 3]: a = [7, 0, 10], c = [1, 3, 4], x = [1.5, 4.0, 0.25]."""
    _floats(_f64(_leaf(make_col(A)), [0, 2, 3]), [7.0, 0.0, 10.0], "a widened")
    _floats(_f64(_leaf(make_col(C)), [0, 2, 3]), [1.0, 3.0, 4.0], "c widened")
    _floats(_f64(_leaf(make_col(X)), [0, 2, 3]), [1.5, 4.0, 0.25], "x")
    _floats(_f64(_leaf(make_lit_f64(2.5)), [0, 2]), [2.5, 2.5], "2.5")
    _floats(_f64(_leaf(make_lit_i64(3)), [0, 2]), [3.0, 3.0], "3 widened")
    _floats(_f64(_leaf(make_null()), [0, 2]), [0.0, 0.0], "NULL's value placeholder")


def test_f64_arithmetic() raises:
    """x = [1.5, 4.0, 0.25] over rows [0, 2, 3], against 0.5."""
    _floats(_f64(_binary(EXPR_ADD_F64, make_col(X), make_lit_f64(0.5)), [0, 2, 3]), [2.0, 4.5, 0.75], "x + 0.5")
    _floats(_f64(_binary(EXPR_SUB_F64, make_col(X), make_lit_f64(0.5)), [0, 2, 3]), [1.0, 3.5, -0.25], "x - 0.5")
    _floats(_f64(_binary(EXPR_MUL_F64, make_col(X), make_lit_f64(0.5)), [0, 2, 3]), [0.75, 2.0, 0.125], "x * 0.5")
    _floats(_f64(_binary(EXPR_DIV_F64, make_col(X), make_lit_f64(0.5)), [0, 2, 3]), [3.0, 8.0, 0.5], "x / 0.5")


def test_f64_integer_arithmetic_widens() raises:
    """Int64 arithmetic nodes in the Float64 walker: a = [7, 0, 10],
    b = [2, 3, -3] over rows [0, 2, 3]; the quotient a / 5 is exact."""
    _floats(_f64(_binary(EXPR_ADD_I64, make_col(A), make_col(B)), [0, 2, 3]), [9.0, 3.0, 7.0], "a + b")
    _floats(_f64(_binary(EXPR_SUB_I64, make_col(A), make_col(B)), [0, 2, 3]), [5.0, -3.0, 13.0], "a - b")
    _floats(_f64(_binary(EXPR_MUL_I64, make_col(A), make_col(B)), [0, 2, 3]), [14.0, 0.0, -30.0], "a * b")
    _floats(_f64(_binary(EXPR_DIV_I64, make_col(A), make_lit_i64(5)), [2, 3]), [0.0, 2.0], "a / 5")
    _floats(_f64(_unary(make_i64_to_f64(0), make_col(A)), [0, 1, 3]), [7.0, -7.0, 10.0], "CAST(a AS DOUBLE)")


def test_f64_integer_division_truncates_toward_zero() raises:
    """An Int64 division read through the Float64 walker (the value of a
    `*_F64_MIXED` compare side) is still integer division (§5.1): a / b over
    rows [0, 1, 3] is 7 / 2, -7 / 2, 10 / -3 = [3.0, -3.0, -3.0], not the
    true quotients [3.5, -3.5, -3.33...]. 7 / -20 truncates to the integer 0,
    which widens to +0.0, not the -0.0 that truncating -0.35 gives
    (komira-ai/komira#932)."""
    _floats(_f64(_binary(EXPR_DIV_I64, make_col(A), make_col(B)), [0, 1, 3]), [3.0, -3.0, -3.0], "a / b")
    var zero = _f64(_binary(EXPR_DIV_I64, make_col(A), make_lit_i64(-20)), [0])
    _floats(zero, [0.0], "a / -20")
    assert_true(1.0 / zero[0] > 0.0, "a / -20 is +0.0, not -0.0")


def test_f64_math_functions() raises:
    _floats(_f64(_unary(make_sqrt_f64(0), make_col(X)), [2]), [2.0], "sqrt(4.0)")
    _floats(_f64(_unary(_node(EXPR_SIN_F64, 0, 0), make_lit_f64(0.0)), [0]), [0.0], "sin(0)")
    _floats(_f64(_unary(_node(EXPR_COS_F64, 0, 0), make_lit_f64(0.0)), [0]), [1.0], "cos(0)")
    _floats(_f64(_unary(_node(EXPR_ASIN_F64, 0, 0), make_lit_f64(1.0)), [0]), [1.5707963267948966], "asin(1)")
    var rad = _f64(_unary(_node(EXPR_RADIANS_F64, 0, 0), make_lit_f64(180.0)), [0])
    assert_true(abs(rad[0] - 3.141592653589793) < 1.0e-12, "radians(180) is pi")
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_f64(1.0))
    pool.append(make_lit_f64(0.0))
    pool.append(make_atan2_f64(0, 1))
    var at = _f64(_exec(pool^), [0])
    assert_true(abs(at[0] - 1.5707963267948966) < 1.0e-12, "atan2(1, 0) is pi/2 (y first)")
    var pp = List[RuntimeExpr]()
    pp.append(make_lit_f64(2.0))
    pp.append(make_lit_f64(10.0))
    pp.append(make_pow_f64(0, 1))
    _floats(_f64(_exec(pp^), [0, 1]), [1024.0, 1024.0], "pow(2, 10)")
    _floats(_f64(_unary(make_math_unary_f64(Int(KMATH_CEIL), 0), make_lit_f64(1.2)), [0]), [2.0], "ceil(1.2)")
    _floats(_f64(_unary(make_math_unary_f64(Int(KMATH_FLOOR), 0), make_lit_f64(-1.2)), [0]), [-2.0], "floor(-1.2)")


def test_f64_case_takes_the_first_true_branch() raises:
    """Over rows [1, 2, 3]: ELSE -1.0, flag -> x[2] = 4.0, a > 5 -> 1.5."""
    var exec = _case_pool(make_lit_f64(1.5), make_col(X), make_lit_f64(-1.0), True)
    _floats(_f64(exec, [1, 2, 3]), [-1.0, 4.0, 1.5], "CASE over [1, 2, 3]")


def test_f64_unsupported_kind_raises() raises:
    with assert_raises(contains="eval_to_list_f64_from_view: unsupported node kind 3 at pool slot 0"):
        _ = _f64(_leaf(make_lit_bool(True)), [0])


# -----------------------------------------------------------------------------
# Int32
# -----------------------------------------------------------------------------


def test_i32_division_and_nested_arithmetic() raises:
    """c = [1, 3, 4] over rows [0, 2, 3]."""
    _ints(_i32(_binary(EXPR_DIV_I32, make_col(C), make_lit_i32(2)), [0, 2, 3]), [0, 1, 2], "c / 2")
    # c * 3 + (c - 1) / 2 = [3 + 0, 9 + 1, 12 + 1]
    var pool = List[RuntimeExpr]()
    pool.append(make_col(C))                 # 0
    pool.append(make_lit_i32(3))             # 1
    pool.append(_node(EXPR_MUL_I32, 0, 1))   # 2: c * 3
    pool.append(make_lit_i32(1))             # 3
    pool.append(_node(EXPR_SUB_I32, 0, 3))   # 4: c - 1
    pool.append(make_lit_i32(2))             # 5
    pool.append(_node(EXPR_DIV_I32, 4, 5))   # 6: (c - 1) / 2
    pool.append(_node(EXPR_ADD_I32, 2, 6))   # 7
    _ints(_i32(_exec(pool^), [0, 2, 3]), [3, 10, 13], "c * 3 + (c - 1) / 2")
    # (c + 10) - 1
    var p2 = List[RuntimeExpr]()
    p2.append(make_col(C))
    p2.append(make_lit_i32(10))
    p2.append(_node(EXPR_ADD_I32, 0, 1))
    p2.append(make_lit_i32(1))
    p2.append(_node(EXPR_SUB_I32, 2, 3))
    _ints(_i32(_exec(p2^), [0, 2, 3]), [10, 12, 13], "(c + 10) - 1")


def test_i32_nested_refusals() raises:
    var pool = List[RuntimeExpr]()
    pool.append(make_col(C))
    pool.append(make_lit_i32(0))
    pool.append(_node(EXPR_DIV_I32, 0, 1))
    pool.append(make_lit_i32(1))
    pool.append(_node(EXPR_ADD_I32, 2, 3))
    with assert_raises(contains="_eval_scalar_i32_from_view: EXPR_DIV_I32 division by zero at row 2"):
        _ = _i32(_exec(pool^), [2])
    var p2 = List[RuntimeExpr]()
    p2.append(make_lit_f64(1.0))
    p2.append(make_lit_i32(1))
    p2.append(_node(EXPR_MUL_I32, 0, 1))
    with assert_raises(contains="_eval_scalar_i32_from_view: unsupported node kind 2 at pool slot 0"):
        _ = _i32(_exec(p2^), [0])


# -----------------------------------------------------------------------------
# Bool, String
# -----------------------------------------------------------------------------


def _bools(exec: ExpressionExecutor, rows: List[Int]) raises -> List[Bool]:
    var batch = _batch()
    var out = List[Scalar[DType.bool]]()
    exec.eval_to_list_bool_from_view(batch_view_over(batch), exec.root_idx, _sel(rows), out)
    var got = List[Bool]()
    for v in out:
        got.append(Bool(v))
    return got^


def test_bool_leaves_and_not() raises:
    """flag = [T, F, T, F] over rows [1, 2, 3]."""
    var got = _bools(_leaf(make_col_bool(FLAG)), [1, 2, 3])
    assert_equal(len(got), 3)
    assert_false(got[0])
    assert_true(got[1])
    assert_false(got[2])
    var lit = _bools(_leaf(make_lit_bool(True)), [1, 2])
    assert_equal(len(lit), 2)
    assert_true(lit[0] and lit[1])
    var neg = _bools(_unary(make_not_bool(0), make_col_bool(FLAG)), [1, 2, 3])
    assert_equal(len(neg), 3)
    assert_true(neg[0])
    assert_false(neg[1])
    assert_true(neg[2])
    with assert_raises(contains="eval_to_list_bool_from_view: unsupported node kind 1 at pool slot 0"):
        _ = _bools(_leaf(make_lit_i64(1)), [0])


def _in_list_exec() -> ExpressionExecutor:
    """a IN (7, 10) over a = [7, -7, 0, 10]."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(A))
    pool.append(make_in_list(0, 0))
    var vals = List[ScalarValue]()
    vals.append(ScalarValue.from_int(7))
    vals.append(ScalarValue.from_int(10))
    var lists = List[List[ScalarValue]]()
    lists.append(vals^)
    return ExpressionExecutor(pool^, 1, _names(), in_list_pool=lists^)


def test_in_list_as_a_bool_column() raises:
    """Over rows [0, 1, 2] only row 0 matches, so the rows after the last
    match read false; over rows [1, 3] the match is last."""
    var exec = _in_list_exec()
    var got = _bools(exec, [0, 1, 2])
    assert_equal(len(got), 3)
    assert_true(got[0])
    assert_false(got[1])
    assert_false(got[2])
    var batch = _batch()
    var plain = List[Bool]()
    exec.eval_to_list_bool_from_view(batch_view_over(batch), 1, _sel([1, 3]), plain)
    assert_equal(len(plain), 2)
    assert_false(plain[0])
    assert_true(plain[1])


def test_in_list_as_a_bool_column_over_no_rows() raises:
    var exec = _in_list_exec()
    assert_equal(len(_bools(exec, List[Int]())), 0)
    var batch = _batch()
    var plain = List[Bool]()
    exec.eval_to_list_bool_from_view(batch_view_over(batch), 1, _sel(List[Int]()), plain)
    assert_equal(len(plain), 0)


def _empty_batch() raises -> RecordBatch:
    """The CASE fixture's columns a, b, flag with no rows, under the names
    the CASE pool resolves."""
    var sb = SchemaBuilder()
    sb.add_field(Field("a", DType.int64, False))
    sb.add_field(Field("b", DType.int64, False))
    sb.add_field(Field("flag", ArrowType.BOOL, False))
    var cols = Slab[Column[HeapRegion]]()
    cols.append(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(List[Scalar[DType.int64]]())))
    cols.append(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(List[Scalar[DType.int64]]())))
    cols.append(Column.from_boolean(BooleanArray.allocate(0)))
    return RecordBatch.from_typed_columns_slab(sb.build(), cols^)


def test_case_over_no_rows() raises:
    var batch = _empty_batch()
    var exec = _case_pool(make_lit_i64(100), make_col(B), make_lit_i64(-1), False)
    var out = List[Scalar[DType.int64]]()
    exec.eval_to_list_i64_from_view(batch_view_over(batch), exec.root_idx, _sel(List[Int]()), out)
    assert_equal(len(out), 0)


def test_string_column_marks_null_rows_invalid() raises:
    """s = [p, NULL, r, s] over rows [0, 1, 2]."""
    var batch = _batch()
    var exec = _leaf(make_col_string(S))
    var out = List[String]()
    var valid = List[Bool]()
    exec.eval_to_list_string_from_view(batch_view_over(batch), 0, _sel([0, 1, 2]), out, valid)
    assert_equal(len(out), 3)
    assert_equal(out[0], "p")
    assert_equal(out[1], "")
    assert_equal(out[2], "r")
    assert_true(valid[0])
    assert_false(valid[1])
    assert_true(valid[2])


def test_string_literal_broadcasts() raises:
    var batch = _batch()
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_string(0))
    var strings: List[String] = ["q"]
    var exec = ExpressionExecutor(pool^, 0, _names(), string_pool=strings^)
    var out = List[String]()
    exec.eval_to_list_string_from_view(batch_view_over(batch), 0, _sel([1, 3]), out)
    assert_equal(len(out), 2)
    assert_equal(out[0], "q")
    assert_equal(out[1], "q")


# -----------------------------------------------------------------------------
# Decimal128
# -----------------------------------------------------------------------------


def _dec(exec: ExpressionExecutor, rows: List[Int], want: List[Int], p: Int, s: Int, what: String) raises:
    var batch = _batch()
    var out = List[SIMD[DType.int128, 1]]()
    var ps = exec.eval_to_list_decimal128_from_view(batch_view_over(batch), exec.root_idx, _sel(rows), out)
    assert_equal(ps[0], p, what + ": precision")
    assert_equal(ps[1], s, what + ": scale")
    assert_equal(len(out), len(want), what + ": length")
    for k in range(len(want)):
        assert_true(out[k] == SIMD[DType.int128, 1](want[k]), what + ": value " + String(k))


def test_decimal_leaves() raises:
    """d = [1.50, -0.25, 0.00, 10.00] (10, 2) over rows [0, 1, 3]."""
    _dec(_leaf(make_col_decimal128(D)), [0, 1, 3], [150, -25, 1000], 10, 2, "d")
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_decimal128(0))
    var dp = List[DecimalSpec]()
    dp.append(DecimalSpec(SIMD[DType.int128, 1](5), 3, 1))
    var lit = ExpressionExecutor(pool^, 0, _names(), decimal_pool=dp^)
    _dec(lit, [0, 1, 3], [5, 5, 5], 3, 1, "0.5 as DECIMAL(3, 1)")


def test_decimal_arithmetic() raises:
    """d (10, 2) = [1.50, -0.25, 10.00], e (10, 1) = [1.0, 2.0, 0.5] over
    rows [0, 1, 3]. Sum and difference: scale 2, precision 9 + 2 + 1 = 12.
    Product: scale 3, precision 21. Quotient: scale 2 + 4 = 6, precision
    5 + 10 = 15; 1.50 / 1.0 = 1.5, -0.25 / 2.0 = -0.125, 10.00 / 0.5 = 20."""
    _dec(_binary(EXPR_ADD_DECIMAL128, make_col_decimal128(D), make_col_decimal128(E)), [0, 1, 3], [250, 175, 1050], 12, 2, "d + e")
    _dec(_binary(EXPR_SUB_DECIMAL128, make_col_decimal128(D), make_col_decimal128(E)), [0, 1, 3], [50, -225, 950], 12, 2, "d - e")
    _dec(_binary(EXPR_MUL_DECIMAL128, make_col_decimal128(D), make_col_decimal128(E)), [0, 1, 3], [1500, -500, 5000], 21, 3, "d * e")
    _dec(_binary(EXPR_DIV_DECIMAL128, make_col_decimal128(D), make_col_decimal128(E)), [0, 1, 3], [1500000, -125000, 20000000], 15, 6, "d / e")


def test_decimal_unsupported_kind_raises() raises:
    with assert_raises(contains="eval_to_list_decimal128_from_view: unsupported node kind 1 at pool slot 0"):
        _dec(_leaf(make_lit_i64(1)), [0], List[Int](), 0, 0, "unsupported")


def main() raises:
    var suite = TestSuite()
    suite.test[test_i64_leaves]()
    suite.test[test_i64_arithmetic]()
    suite.test[test_integer_division_truncates_toward_zero]()
    suite.test[test_i64_division_by_zero_raises]()
    suite.test[test_i64_from_whole_float64]()
    suite.test[test_i64_case_takes_the_first_true_branch]()
    suite.test[test_i64_unsupported_kind_raises]()
    suite.test[test_f64_leaves]()
    suite.test[test_f64_arithmetic]()
    suite.test[test_f64_integer_arithmetic_widens]()
    suite.test[test_f64_integer_division_truncates_toward_zero]()
    suite.test[test_f64_math_functions]()
    suite.test[test_f64_case_takes_the_first_true_branch]()
    suite.test[test_f64_unsupported_kind_raises]()
    suite.test[test_i32_division_and_nested_arithmetic]()
    suite.test[test_i32_nested_refusals]()
    suite.test[test_bool_leaves_and_not]()
    suite.test[test_in_list_as_a_bool_column]()
    suite.test[test_in_list_as_a_bool_column_over_no_rows]()
    suite.test[test_case_over_no_rows]()
    suite.test[test_string_column_marks_null_rows_invalid]()
    suite.test[test_string_literal_broadcasts]()
    suite.test[test_decimal_leaves]()
    suite.test[test_decimal_arithmetic]()
    suite.test[test_decimal_unsupported_kind_raises]()
    suite^.run()
