# =============================================================================
# SIMD kernel gap-fills — correctness cluster regression tests
# =============================================================================
#
# Covers the four S1 items (audit memo §3 #3/#6/#7):
#   1. Kleene three-valued logic in eval_and / eval_or / eval_not
#   2. Nullable-arithmetic validity-merge on +/-/*//  (col-col and col-scalar)
#   3. eval_cast validity-drop fix (the cast keeps the input null mask)
#   4. EXPR_CAST temporal bit-reinterpret (date32 -> int32, timestamp -> int64)
#
# Each test below FAILS on pre-S1 code (the kernels dropped validity / used
# non-Kleene and/or) and PASSES after.  References for the semantics:
#   Arrow-rs `arrow-arith/src/boolean.rs` and_kleene/or_kleene;
#   DuckDB `execution/expression_executor/execute_conjunction.cpp`;
#   DuckDB `common/operator/cast_operators.hpp` (cast validity propagation).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow import PrimitiveArray, BooleanArray, Bitmap
from komira_core.arrow.column import Column
from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import Schema, SchemaBuilder, Field, RecordBatch, RecordBatchBuilder
from komira_eval import eval_and, eval_or, eval_not, eval_cast
from komira_core.plan.expr import Expr, BIN_ADD, BIN_MUL
from komira_core.plan.scalar_value import ScalarValue
from komira_compiler.compiler_eval_column import _eval_column_expr


# =============================================================================
# Helpers
# =============================================================================


def _nullable_bool(vals: List[Bool], nulls: List[Bool]) raises -> BooleanArray:
    """Build a nullable BooleanArray: vals[i] is the data bit, nulls[i]=True
    marks the slot NULL."""
    var n = len(vals)
    var arr = BooleanArray.allocate_nullable(n)
    var nc = 0
    for i in range(n):
        arr.set(i, vals[i])
        if nulls[i]:
            arr.validity.value().clear(i)
            nc += 1
    arr.null_count = nc
    return arr^


def _bool(vals: List[Bool]) raises -> BooleanArray:
    """Build a non-nullable BooleanArray."""
    var n = len(vals)
    var arr = BooleanArray.allocate(n)
    for i in range(n):
        arr.set(i, vals[i])
    return arr^


def _nullable_i64_batch(
    vals: List[Int64], nulls: List[Bool], name: String = "a"
) raises -> RecordBatch:
    """One-column nullable INT64 RecordBatch."""
    var n = len(vals)
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        arr.set(i, Scalar[DType.int64](vals[i]))
        if nulls[i]:
            arr.validity.value().clear(i)
            nc += 1
    arr.null_count = nc
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.INT64, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](arr^))
    return rbb.build(sb.build())


def _two_nullable_i64_batch(
    a_vals: List[Int64], a_nulls: List[Bool],
    b_vals: List[Int64], b_nulls: List[Bool],
) raises -> RecordBatch:
    var n = len(a_vals)
    var a_arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    var b_arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    var anc = 0
    var bnc = 0
    for i in range(n):
        a_arr.set(i, Scalar[DType.int64](a_vals[i]))
        b_arr.set(i, Scalar[DType.int64](b_vals[i]))
        if a_nulls[i]:
            a_arr.validity.value().clear(i)
            anc += 1
        if b_nulls[i]:
            b_arr.validity.value().clear(i)
            bnc += 1
    a_arr.null_count = anc
    b_arr.null_count = bnc
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    sb.add_field(Field("b", ArrowType.INT64, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](a_arr^))
    rbb.add_column(Column.from_primitive[DType.int64](b_arr^))
    return rbb.build(sb.build())


# =============================================================================
# Item 1 — Kleene three-valued AND / OR / NOT
# =============================================================================


def test_kleene_and_false_and_null_is_false() raises:
    """false AND null = false (NOT null) — the determined-false short-circuit."""
    # left:  [F,   T,   N(0)]   right: [N(0), N(0), N(0)]
    var left = _nullable_bool([False, True, False], [False, False, True])
    var right = _nullable_bool([False, False, False], [True, True, True])
    var r = eval_and(left, right)
    # row 0: false AND null -> false (valid, data=false)
    assert_false(r.is_null(0))
    assert_false(r.get(0))
    # row 1: true AND null -> null
    assert_true(r.is_null(1))
    # row 2: null AND null -> null
    assert_true(r.is_null(2))
    assert_equal(r.null_count, 2)


def test_kleene_and_both_valid_unchanged() raises:
    """When both inputs are valid, AND is the ordinary bitwise AND, no nulls."""
    var left = _nullable_bool([True, True, False, False], [False, False, False, False])
    var right = _nullable_bool([True, False, True, False], [False, False, False, False])
    var r = eval_and(left, right)
    assert_equal(r.null_count, 0)
    assert_true(r.get(0))
    assert_false(r.get(1))
    assert_false(r.get(2))
    assert_false(r.get(3))


def test_kleene_and_no_validity_fastpath() raises:
    """No validity on either input -> result is non-nullable (fast path)."""
    var left = _bool([True, True, False])
    var right = _bool([True, False, False])
    var r = eval_and(left, right)
    assert_false(r.validity)  # no validity bitmap
    assert_equal(r.null_count, 0)
    assert_true(r.get(0))
    assert_false(r.get(1))
    assert_false(r.get(2))


def test_kleene_and_one_side_nullable() raises:
    """left valid (no bitmap), right nullable: false&* known, true&null -> null."""
    var left = _bool([True, False, True])          # no validity bitmap
    var right = _nullable_bool([True, True, False], [True, False, True])
    var r = eval_and(left, right)
    # row 0: true AND null -> null
    assert_true(r.is_null(0))
    # row 1: false AND true -> false (false determines it; left valid)
    assert_false(r.is_null(1))
    assert_false(r.get(1))
    # row 2: true AND null -> null
    assert_true(r.is_null(2))
    assert_equal(r.null_count, 2)


def test_kleene_or_true_or_null_is_true() raises:
    """true OR null = true (NOT null) — the determined-true short-circuit."""
    var left = _nullable_bool([True, False, False], [False, False, True])
    var right = _nullable_bool([False, False, False], [True, True, True])
    var r = eval_or(left, right)
    # row 0: true OR null -> true
    assert_false(r.is_null(0))
    assert_true(r.get(0))
    # row 1: false OR null -> null
    assert_true(r.is_null(1))
    # row 2: null OR null -> null
    assert_true(r.is_null(2))
    assert_equal(r.null_count, 2)


def test_kleene_or_both_valid_unchanged() raises:
    var left = _nullable_bool([True, True, False, False], [False, False, False, False])
    var right = _nullable_bool([True, False, True, False], [False, False, False, False])
    var r = eval_or(left, right)
    assert_equal(r.null_count, 0)
    assert_true(r.get(0))
    assert_true(r.get(1))
    assert_true(r.get(2))
    assert_false(r.get(3))


def test_kleene_not_propagates_null() raises:
    """NOT null = null; NOT true = false; NOT false = true."""
    var col = _nullable_bool([True, False, True], [False, False, True])
    var r = eval_not(col)
    assert_false(r.is_null(0))
    assert_false(r.get(0))  # NOT true
    assert_false(r.is_null(1))
    assert_true(r.get(1))   # NOT false
    assert_true(r.is_null(2))  # NOT null -> null
    assert_equal(r.null_count, 1)


def test_kleene_not_no_validity_fastpath() raises:
    var col = _bool([True, False, True])
    var r = eval_not(col)
    assert_false(r.validity)
    assert_equal(r.null_count, 0)
    assert_false(r.get(0))
    assert_true(r.get(1))
    assert_false(r.get(2))


def test_kleene_and_trailing_bits_masked() raises:
    """A length not a multiple of 8: trailing bits past `length` stay 0 in
    both data and validity (no phantom true / phantom-valid)."""
    # 5 rows: [F, T, N, T, F] AND [N, N, N, T, F]
    var left = _nullable_bool([False, True, False, True, False], [False, False, True, False, False])
    var right = _nullable_bool([False, False, False, True, False], [True, True, True, False, False])
    var r = eval_and(left, right)
    assert_equal(len(r), 5)
    # row0: F AND N -> F valid; row1: T AND N -> null; row2: N AND N -> null
    # row3: T AND T -> T valid; row4: F AND F -> F valid
    assert_false(r.is_null(0))
    assert_false(r.get(0))
    assert_true(r.is_null(1))
    assert_true(r.is_null(2))
    assert_false(r.is_null(3))
    assert_true(r.get(3))
    assert_false(r.is_null(4))
    assert_false(r.get(4))
    assert_equal(r.null_count, 2)


# =============================================================================
# Item 2 — nullable-arithmetic validity merge
# =============================================================================


def test_nullable_arith_col_col_add_merges_validity() raises:
    """nullable_a + nullable_b -> result NULL wherever either input is NULL,
    null_count == popcount of the merged mask's zero bits."""
    # a: [10, N, 30, N]   b: [1, 2, N, N]
    var batch = _two_nullable_i64_batch(
        [Int64(10), Int64(0), Int64(30), Int64(0)], [False, True, False, True],
        [Int64(1), Int64(2), Int64(0), Int64(0)], [False, False, True, True],
    )
    var expr = Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.col_ref("b"))
    var out = _eval_column_expr(expr, batch)
    assert_equal(out.length(), 4)
    var arr = out.as_primitive[DType.int64]()
    # row 0: both valid -> 11
    assert_false(arr.is_null(0))
    assert_equal(arr.get(0), Scalar[DType.int64](11))
    # row 1: a NULL -> NULL
    assert_true(arr.is_null(1))
    # row 2: b NULL -> NULL
    assert_true(arr.is_null(2))
    # row 3: both NULL -> NULL
    assert_true(arr.is_null(3))
    assert_equal(arr.null_count, 3)
    assert_equal(out.null_count(), 3)


def test_nullable_arith_col_col_mul_merges_validity() raises:
    var batch = _two_nullable_i64_batch(
        [Int64(2), Int64(3), Int64(0)], [False, False, True],
        [Int64(5), Int64(0), Int64(7)], [False, True, False],
    )
    var expr = Expr.binary(BIN_MUL, Expr.col_ref("a"), Expr.col_ref("b"))
    var out = _eval_column_expr(expr, batch)
    var arr = out.as_primitive[DType.int64]()
    assert_false(arr.is_null(0))
    assert_equal(arr.get(0), Scalar[DType.int64](10))
    assert_true(arr.is_null(1))  # b NULL
    assert_true(arr.is_null(2))  # a NULL
    assert_equal(arr.null_count, 2)


def test_nullable_arith_col_scalar_keeps_validity() raises:
    """nullable_a + 5 -> result keeps a's null mask (a literal is never NULL)."""
    var batch = _nullable_i64_batch([Int64(10), Int64(0), Int64(30)], [False, True, False])
    var expr = Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.literal(ScalarValue.from_int(5)))
    var out = _eval_column_expr(expr, batch)
    var arr = out.as_primitive[DType.int64]()
    assert_false(arr.is_null(0))
    assert_equal(arr.get(0), Scalar[DType.int64](15))
    assert_true(arr.is_null(1))
    assert_false(arr.is_null(2))
    assert_equal(arr.get(2), Scalar[DType.int64](35))
    assert_equal(arr.null_count, 1)
    assert_equal(out.null_count(), 1)


def test_nonnullable_arith_unchanged() raises:
    """Non-nullable inputs -> non-nullable result, no validity bitmap added."""
    var a_arr = PrimitiveArray[DType.int64].allocate(3)
    var b_arr = PrimitiveArray[DType.int64].allocate(3)
    a_arr.set(0, Scalar[DType.int64](1)); a_arr.set(1, Scalar[DType.int64](2)); a_arr.set(2, Scalar[DType.int64](3))
    b_arr.set(0, Scalar[DType.int64](10)); b_arr.set(1, Scalar[DType.int64](20)); b_arr.set(2, Scalar[DType.int64](30))
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    sb.add_field(Field("b", ArrowType.INT64, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](a_arr^))
    rbb.add_column(Column.from_primitive[DType.int64](b_arr^))
    var batch = rbb.build(sb.build())
    var expr = Expr.binary(BIN_ADD, Expr.col_ref("a"), Expr.col_ref("b"))
    var out = _eval_column_expr(expr, batch)
    assert_equal(out.null_count(), 0)
    var arr = out.as_primitive[DType.int64]()
    assert_false(arr.validity)
    assert_equal(arr.get(0), Scalar[DType.int64](11))
    assert_equal(arr.get(2), Scalar[DType.int64](33))


# =============================================================================
# Item 3 — eval_cast validity-drop fix
# =============================================================================


def test_eval_cast_preserves_validity() raises:
    """eval_cast(nullable int32 -> float64) keeps the null mask + null_count."""
    var col = PrimitiveArray[DType.int32].allocate_nullable(4)
    col.set(0, Scalar[DType.int32](10))
    col.set(1, Scalar[DType.int32](20))
    col.set(2, Scalar[DType.int32](30))
    col.set(3, Scalar[DType.int32](40))
    col.validity.value().clear(1)
    col.validity.value().clear(3)
    col.null_count = 2
    var r = eval_cast[DType.int32, DType.float64](col)
    assert_equal(r.length, 4)
    assert_equal(r.null_count, 2)
    assert_false(r.is_null(0))
    assert_equal(r.get(0), Scalar[DType.float64](10.0))
    assert_true(r.is_null(1))
    assert_false(r.is_null(2))
    assert_equal(r.get(2), Scalar[DType.float64](30.0))
    assert_true(r.is_null(3))


def test_eval_cast_no_validity_unchanged() raises:
    """eval_cast on a non-nullable input -> still non-nullable (no bitmap)."""
    var values: List[Scalar[DType.int32]] = [Scalar[DType.int32](1), Scalar[DType.int32](2)]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var r = eval_cast[DType.int32, DType.float64](col)
    assert_false(r.validity)
    assert_equal(r.null_count, 0)
    assert_equal(r.get(0), Scalar[DType.float64](1.0))


def test_expr_cast_preserves_validity_via_column_eval() raises:
    """cast(nullable_col AS f64) through _eval_column_expr keeps the null mask."""
    var batch = _nullable_i64_batch([Int64(7), Int64(0), Int64(9)], [False, True, False])
    var expr = Expr.cast(Expr.col_ref("a"), DType.float64)
    var out = _eval_column_expr(expr, batch)
    assert_equal(out.length(), 3)
    assert_equal(out.null_count(), 1)
    var arr = out.as_primitive[DType.float64]()
    assert_false(arr.is_null(0))
    assert_equal(arr.get(0), Scalar[DType.float64](7.0))
    assert_true(arr.is_null(1))
    assert_false(arr.is_null(2))
    assert_equal(arr.get(2), Scalar[DType.float64](9.0))


# =============================================================================
# Item 4 — EXPR_CAST temporal bit-reinterpret
# =============================================================================


def _date32_batch(vals: List[Int32], nulls: List[Bool]) raises -> RecordBatch:
    var n = len(vals)
    var arr = PrimitiveArray[DType.int32].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        arr.set(i, Scalar[DType.int32](vals[i]))
        if nulls[i]:
            arr.validity.value().clear(i)
            nc += 1
    arr.null_count = nc
    var c = Column.from_primitive[DType.int32](arr^)
    c.arrow_type = ArrowType.DATE32
    var sb = SchemaBuilder()
    sb.add_field(Field("d", ArrowType.DATE32, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(c^)
    return rbb.build(sb.build())


def test_expr_cast_date32_to_int32_reinterpret() raises:
    """cast(date32_col AS int32): same bits, same null mask, ArrowType -> INT32."""
    # 19000, 19001, NULL, 19003 (days since epoch — values are arbitrary).
    var batch = _date32_batch([Int32(19000), Int32(19001), Int32(0), Int32(19003)], [False, False, True, False])
    var expr = Expr.cast(Expr.col_ref("d"), DType.int32)
    var out = _eval_column_expr(expr, batch)
    assert_true(out.arrow_type == ArrowType.INT32)
    assert_equal(out.length(), 4)
    assert_equal(out.null_count(), 1)
    var arr = out.as_primitive[DType.int32]()
    assert_false(arr.is_null(0))
    assert_equal(arr.get(0), Scalar[DType.int32](19000))
    assert_equal(arr.get(1), Scalar[DType.int32](19001))
    assert_true(arr.is_null(2))
    assert_equal(arr.get(3), Scalar[DType.int32](19003))


def _timestamp_us_batch(vals: List[Int64], nulls: List[Bool]) raises -> RecordBatch:
    var n = len(vals)
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    var nc = 0
    for i in range(n):
        arr.set(i, Scalar[DType.int64](vals[i]))
        if nulls[i]:
            arr.validity.value().clear(i)
            nc += 1
    arr.null_count = nc
    var c = Column.from_primitive[DType.int64](arr^)
    c.arrow_type = ArrowType.TIMESTAMP_US
    var sb = SchemaBuilder()
    sb.add_field(Field("ts", ArrowType.TIMESTAMP_US, True))
    var rbb = RecordBatchBuilder()
    rbb.add_column(c^)
    return rbb.build(sb.build())


def test_expr_cast_timestamp_to_int64_reinterpret() raises:
    """cast(timestamp[us]_col AS int64): same bits, same null mask, type -> INT64."""
    var batch = _timestamp_us_batch(
        [Int64(1700000000000000), Int64(0), Int64(1700000003000000)], [False, True, False]
    )
    var expr = Expr.cast(Expr.col_ref("ts"), DType.int64)
    var out = _eval_column_expr(expr, batch)
    assert_true(out.arrow_type == ArrowType.INT64)
    assert_equal(out.length(), 3)
    assert_equal(out.null_count(), 1)
    var arr = out.as_primitive[DType.int64]()
    assert_false(arr.is_null(0))
    assert_equal(arr.get(0), Scalar[DType.int64](1700000000000000))
    assert_true(arr.is_null(1))
    assert_equal(arr.get(2), Scalar[DType.int64](1700000003000000))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
