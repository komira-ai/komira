# =============================================================================
# Integer division in the BatchView walkers of `ExpressionExecutor`: a zero
# divisor answers NULL (docs/design/query_semantics.md §5.3), and in the
# Int64 and Int32 walkers signed MIN / -1 raises an overflow error (§5.4)
# unless an operand is NULL (§5.0). The Float64 walker answers MIN / -1 with
# 2^63 (komira-ai/komira#1478; its section below says why).
#
# The numeric project walkers return values only. A NULL row holds a
# placeholder value there, and `_mark_value_nulls_from_view` (the channel the
# filters read) reports it NULL; these tests check both. A filter over the
# quotient is the public proof: a NULL quotient is UNKNOWN, so the row
# survives neither `p` nor `NOT p`, and a placeholder read as a value would
# make `quotient = 0` TRUE.
#
# Zero fixture (N = NULL, stored value after the slash):
#
# | row | a (i64) | z (i64) | c (i32) | y (i32) |
# |-----|---------|---------|---------|---------|
# | 0   | 7       | 2       | 7       | 2       |
# | 1   | -7      | 0       | -7      | 0       |
# | 2   | 0       | 0       | 0       | 0       |
# | 3   | 9       | N/0     | 9       | N/0     |
# | 4   | -9      | -2      | -9      | -2      |
#
# MIN fixture:
#
# | row | a (i64)  | z (i64) | c (i32)  | y (i32) |
# |-----|----------|---------|----------|---------|
# | 0   | MIN      | -1      | MIN      | -1      |
# | 1   | N/MIN    | -1      | N/MIN    | -1      |
# | 2   | MIN      | N/-1    | MIN      | N/-1    |
# | 3   | MIN      | 1       | MIN      | 1       |
# | 4   | 6        | -1      | 6        | -1      |
#
# Wide fixture (values the Float64 walker cannot hold exactly):
#
# | row | a (i64)  | z (i64) |
# |-----|----------|---------|
# | 0   | 2^62 + 1 | 2^62    |
# | 1   | 5        | 5       |
#
# Read through the Int64 walker, (a - z) is 1 and 0; widened to Float64 first,
# both rows give 0.0, since 2^62 + 1 rounds to 2^62.
#
# Refs komira-ai/komira#1276.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.batch_view import batch_view_over
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.selection_vector_row import RowSelectionVector
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_eval.expression_executor import ExpressionExecutor
from komira_eval.filter_state import FilterState
from komira_kernels.runtime_expr import (
    EXPR_ADD_I32,
    EXPR_DIV_I32,
    EXPR_DIV_I64,
    EXPR_EQ_F64_MIXED,
    EXPR_EQ_I64,
    EXPR_GE_F64_MIXED,
    EXPR_GE_I64,
    EXPR_GT_F64_MIXED,
    EXPR_LT_F64_MIXED,
    EXPR_SUB_I64,
    RuntimeExpr,
    make_case_f64,
    make_case_i64,
    make_col,
    make_i64_to_f64,
    make_lit_f64,
    make_lit_i32,
    make_lit_i64,
    make_not_bool,
    make_or,
)


comptime A = 0
comptime Z = 1
comptime C = 2
comptime Y = 3

comptime I64_MIN = Scalar[DType.int64].MIN
comptime I32_MIN = Scalar[DType.int32].MIN


def _names() -> List[String]:
    var names: List[String] = ["a", "z", "c", "y"]
    return names^


def _build(
    av: List[Int], zv: List[Int], cv: List[Int], yv: List[Int], null_a: Int, null_z: Int
) raises -> RecordBatch:
    """Columns a, z (Int64) and c, y (Int32); row `null_a` of a and c and
    row `null_z` of z and y are NULL (-1: none)."""
    var n = len(av)
    var a = PrimitiveArray[DType.int64].allocate_nullable(n)
    var z = PrimitiveArray[DType.int64].allocate_nullable(n)
    var c = PrimitiveArray[DType.int32].allocate_nullable(n)
    var y = PrimitiveArray[DType.int32].allocate_nullable(n)
    for r in range(n):
        a.set(r, Scalar[DType.int64](Int64(av[r])))
        z.set(r, Scalar[DType.int64](Int64(zv[r])))
        c.set(r, Scalar[DType.int32](Int32(cv[r])))
        y.set(r, Scalar[DType.int32](Int32(yv[r])))
    if null_a >= 0:
        a._set_null(null_a)
        c._set_null(null_a)
    if null_z >= 0:
        z._set_null(null_z)
        y._set_null(null_z)
    var sb = SchemaBuilder()
    sb.add_field(Field("a", DType.int64, True))
    sb.add_field(Field("z", DType.int64, True))
    sb.add_field(Field("c", DType.int32, True))
    sb.add_field(Field("y", DType.int32, True))
    var cols = Slab[Column[HeapRegion]]()
    cols.append(Column.from_primitive[DType.int64](a^))
    cols.append(Column.from_primitive[DType.int64](z^))
    cols.append(Column.from_primitive[DType.int32](c^))
    cols.append(Column.from_primitive[DType.int32](y^))
    return RecordBatch.from_typed_columns_slab(sb.build(), cols^)


def _zero_batch() raises -> RecordBatch:
    return _build([7, -7, 0, 9, -9], [2, 0, 0, 0, -2], [7, -7, 0, 9, -9], [2, 0, 0, 0, -2], -1, 3)


def _min_batch() raises -> RecordBatch:
    var m64 = Int(I64_MIN)
    var m32 = Int(I32_MIN)
    return _build(
        [m64, m64, m64, m64, 6], [-1, -1, -1, 1, -1], [m32, m32, m32, m32, 6], [-1, -1, -1, 1, -1], 1, 2
    )


def _wide_batch() raises -> RecordBatch:
    var big = 1 << 62
    return _build([big + 1, 5], [big, 5], [0, 0], [1, 1], -1, -1)


def _sel(rows: List[Int]) -> RowSelectionVector:
    var sel = RowSelectionVector(8)
    for r in rows:
        sel.append(UInt32(r))
    return sel^


def _node(kind: Int, left: Int, right: Int) -> RuntimeExpr:
    return RuntimeExpr(kind, Int64(0), 0.0, False, 0, left, right)


def _exec(var pool: List[RuntimeExpr], var when: List[List[Int]] = List[List[Int]]()) -> ExpressionExecutor:
    """Root is the last slot."""
    var root = len(pool) - 1
    return ExpressionExecutor(pool^, root, _names(), when_pool=when^)


def _div(kind: Int, l: Int, r: Int) -> ExpressionExecutor:
    """Pool [col l, col r, l / r]."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(l))
    pool.append(make_col(r))
    pool.append(_node(kind, 0, 1))
    return _exec(pool^)


def _i64(exec: ExpressionExecutor, batch: RecordBatch, rows: List[Int]) raises -> List[Int]:
    var out = List[Scalar[DType.int64]]()
    exec.eval_to_list_i64_from_view(batch_view_over(batch), exec.root_idx, _sel(rows), out)
    var got = List[Int]()
    for v in out:
        got.append(Int(v))
    return got^


def _f64(exec: ExpressionExecutor, batch: RecordBatch, rows: List[Int]) raises -> List[Float64]:
    var out = List[Scalar[DType.float64]]()
    exec.eval_to_list_f64_from_view(batch_view_over(batch), exec.root_idx, _sel(rows), out)
    var got = List[Float64]()
    for v in out:
        got.append(Float64(v))
    return got^


def _i32(exec: ExpressionExecutor, batch: RecordBatch, rows: List[Int]) raises -> List[Int]:
    var out = List[Scalar[DType.int32]]()
    exec.eval_to_list_i32_from_view(batch_view_over(batch), exec.root_idx, _sel(rows), out)
    var got = List[Int]()
    for v in out:
        got.append(Int(v))
    return got^


def _nulls(exec: ExpressionExecutor, batch: RecordBatch, rows: List[Int], f64_ctx: Bool) raises -> List[Bool]:
    """The NULL channel for the root over `rows`."""
    var sel = _sel(rows)
    var null_at = List[Bool](length=len(rows), fill=False)
    exec._mark_value_nulls_from_view(batch, exec.root_idx, sel, null_at, f64_ctx=f64_ctx)
    return null_at^


def _run(exec: ExpressionExecutor, batch: RecordBatch) raises -> List[Int]:
    var fs = FilterState.with_conjunction(n_predicates=1, worker_id=0)
    var k = exec.select_expression_from_view(batch_view_over(batch), fs)
    var out = List[Int]()
    for i in range(k):
        out.append(Int(fs.sel.get(i)))
    return out^


def _expect(got: List[Int], want: List[Int], what: String) raises:
    var g = String("[")
    for v in got:
        g += String(v) + " "
    g += "]"
    assert_equal(len(got), len(want), what + ": count, got " + g)
    for k in range(len(want)):
        assert_equal(got[k], want[k], what + ": item " + String(k) + ", got " + g)


def _expect_bools(got: List[Bool], want: List[Bool], what: String) raises:
    assert_equal(len(got), len(want), what + ": count")
    for k in range(len(want)):
        assert_equal(got[k], want[k], what + ": item " + String(k))


def _cmp_pool(cmp_kind: Int, cast_to_f64: Bool, rhs: Float64, negate: Bool) -> ExpressionExecutor:
    """`[NOT] (a / z) <cmp> rhs` through a `*_F64_MIXED` compare; with
    `cast_to_f64` the quotient is `CAST(a / z AS DOUBLE)`, so the Int64 walker
    divides instead of the Float64 one."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(A))                  # 0
    pool.append(make_col(Z))                  # 1
    pool.append(_node(EXPR_DIV_I64, 0, 1))    # 2: a / z
    var q = 2
    if cast_to_f64:
        pool.append(make_i64_to_f64(2))       # 3
        q = 3
    pool.append(make_lit_f64(rhs))
    pool.append(_node(cmp_kind, q, len(pool) - 1))
    if negate:
        pool.append(make_not_bool(len(pool) - 1))
    return _exec(pool^)


# -----------------------------------------------------------------------------
# §5.3: a zero divisor answers NULL
# -----------------------------------------------------------------------------


def test_i64_zero_divisor_is_null_not_a_raise() raises:
    """a / z over all rows: 3, NULL, NULL, NULL (z NULL), 4. Rows 1 and 2
    hold the placeholder 0 and the NULL channel marks them."""
    var batch = _zero_batch()
    var got = _i64(_div(EXPR_DIV_I64, A, Z), batch, [0, 1, 2, 3, 4])
    _expect(got, [3, 0, 0, 0, 4], "a / z")
    var want: List[Bool] = [False, True, True, True, False]
    _expect_bools(_nulls(_div(EXPR_DIV_I64, A, Z), batch, [0, 1, 2, 3, 4], False), want, "a / z nulls, Int64 walker")
    _expect_bools(_nulls(_div(EXPR_DIV_I64, A, Z), batch, [0, 1, 2, 3, 4], True), want, "a / z nulls, Float64 walker")


def test_f64_walker_zero_divisor_is_null_not_inf() raises:
    """The Float64 walker's EXPR_DIV_I64 arm: -7 / 0 and 0 / 0 hold the
    placeholder 0.0, not -Inf and NaN."""
    var got = _f64(_div(EXPR_DIV_I64, A, Z), _zero_batch(), [0, 1, 2, 4])
    assert_equal(len(got), 4)
    assert_equal(got[0], 3.0)
    assert_equal(got[1], 0.0)
    assert_equal(got[2], 0.0)
    assert_equal(got[3], 4.0)


def test_i32_zero_divisor_is_null_not_a_raise() raises:
    """c / y at the Int32 root and `(c / y) + 0` (the scalar helper)."""
    var batch = _zero_batch()
    _expect(_i32(_div(EXPR_DIV_I32, C, Y), batch, [0, 1, 2, 4]), [3, 0, 0, 4], "c / y")
    var pool = List[RuntimeExpr]()
    pool.append(make_col(C))                  # 0
    pool.append(make_col(Y))                  # 1
    pool.append(_node(EXPR_DIV_I32, 0, 1))    # 2: c / y
    pool.append(make_lit_i32(0))              # 3
    pool.append(_node(EXPR_ADD_I32, 2, 3))    # 4: (c / y) + 0
    _expect(_i32(_exec(pool^), batch, [0, 1, 2, 4]), [3, 0, 0, 4], "(c / y) + 0")
    var want: List[Bool] = [False, True, True, True, False]
    _expect_bools(_nulls(_div(EXPR_DIV_I32, C, Y), batch, [0, 1, 2, 3, 4], False), want, "c / y nulls")


def test_filter_over_a_zero_divisor_quotient_is_unknown() raises:
    """`(a / z) < 0` keeps nothing: -7 / 0 is NULL, not -Inf. `NOT ((a / z)
    >= 0)` keeps nothing: rows 1-3 are UNKNOWN and rows 0, 4 are FALSE.
    `(a / z) = 0` keeps nothing: the placeholder 0 is not a value."""
    var batch = _zero_batch()
    _expect(_run(_cmp_pool(EXPR_GE_F64_MIXED, False, 0.0, False), batch), [0, 4], "(a / z) >= 0")
    _expect(_run(_cmp_pool(EXPR_GE_F64_MIXED, False, 0.0, True), batch), List[Int](), "NOT ((a / z) >= 0)")
    _expect(_run(_cmp_pool(EXPR_LT_F64_MIXED, False, 0.0, False), batch), List[Int](), "(a / z) < 0")
    _expect(_run(_cmp_pool(EXPR_EQ_F64_MIXED, False, 0.0, False), batch), List[Int](), "(a / z) = 0")


def test_filter_over_a_cast_zero_divisor_quotient_is_unknown() raises:
    """`CAST(a / z AS DOUBLE)`: the Int64 walker divides, and the NULL
    channel re-reads the divisor through it."""
    var batch = _zero_batch()
    _expect(_run(_cmp_pool(EXPR_EQ_F64_MIXED, True, 0.0, False), batch), List[Int](), "CAST(a / z) = 0")
    _expect(_run(_cmp_pool(EXPR_EQ_F64_MIXED, True, 0.0, True), batch), [0, 4], "NOT (CAST(a / z) = 0)")


# -----------------------------------------------------------------------------
# §5.4: signed MIN / -1 raises, unless an operand is NULL
# -----------------------------------------------------------------------------


def test_i64_min_over_minus_one_raises() raises:
    var batch = _min_batch()
    with assert_raises(contains="Out of Range Error: Overflow in division of INT64 (-9223372036854775808 / -1)!"):
        _ = _i64(_div(EXPR_DIV_I64, A, Z), batch, [3, 0])
    var got = _i64(_div(EXPR_DIV_I64, A, Z), batch, [3, 4, 1, 2])
    assert_equal(len(got), 4)
    assert_equal(got[0], Int(I64_MIN), "MIN / 1")
    assert_equal(got[1], -6, "6 / -1")
    var want: List[Bool] = [False, False, True, True]
    _expect_bools(_nulls(_div(EXPR_DIV_I64, A, Z), batch, [3, 4, 1, 2], False), want, "rows 1, 2 are NULL")


def test_i32_min_over_minus_one_raises() raises:
    var batch = _min_batch()
    with assert_raises(contains="Out of Range Error: Overflow in division of INT32 (-2147483648 / -1)!"):
        _ = _i32(_div(EXPR_DIV_I32, C, Y), batch, [0])
    var got = _i32(_div(EXPR_DIV_I32, C, Y), batch, [3, 4, 1, 2])
    assert_equal(len(got), 4)
    assert_equal(got[0], Int(I32_MIN), "MIN / 1")
    assert_equal(got[1], -6, "6 / -1")
    var pool = List[RuntimeExpr]()
    pool.append(make_col(C))                  # 0
    pool.append(make_col(Y))                  # 1
    pool.append(_node(EXPR_DIV_I32, 0, 1))    # 2: c / y
    pool.append(make_lit_i32(0))              # 3
    pool.append(_node(EXPR_ADD_I32, 2, 3))    # 4: (c / y) + 0
    var nested = _exec(pool^)
    with assert_raises(contains="Out of Range Error: Overflow in division of INT32 (-2147483648 / -1)!"):
        _ = _i32(nested, batch, [0])
    var got_nested = _i32(nested, batch, [4, 1, 2])
    assert_equal(len(got_nested), 3, "NULL rows do not raise")
    assert_equal(got_nested[0], -6, "(6 / -1) + 0")


def test_i64_walker_min_over_minus_one_of_a_wide_quotient_raises() raises:
    """`(MIN / (a - z)) / -1` through the Int64 walker, a = 2^62 + 1, z = 2^62:
    a - z is 1, so the inner quotient is MIN and the outer division is
    MIN / -1, which raises. The operand NULL check reads the inner division's
    divisor through the Int64 walker; read through the Float64 one, a - z
    widens to 0.0, the inner quotient looks NULL and the raise is lost."""
    var pool = List[RuntimeExpr]()
    pool.append(make_lit_i64(I64_MIN))        # 0
    pool.append(make_col(A))                  # 1
    pool.append(make_col(Z))                  # 2
    pool.append(_node(EXPR_SUB_I64, 1, 2))    # 3: a - z
    pool.append(_node(EXPR_DIV_I64, 0, 3))    # 4: MIN / (a - z)
    pool.append(make_lit_i64(-1))             # 5
    pool.append(_node(EXPR_DIV_I64, 4, 5))    # 6: (MIN / (a - z)) / -1
    var exec = _exec(pool^)
    with assert_raises(contains="Out of Range Error: Overflow in division of INT64 (-9223372036854775808 / -1)!"):
        _ = _i64(exec, _wide_batch(), [0])


# -----------------------------------------------------------------------------
# The Float64 walker's EXPR_DIV_I64 answers MIN / -1 as it did before
# (komira-ai/komira#1478). CASE branches and the right side of an OR are
# evaluated over every selected row, so a raise there would fire on rows that
# never use the quotient. Fixture: a = [MIN, 6], z = [-1, -2].
# -----------------------------------------------------------------------------


def _untaken_min_batch() raises -> RecordBatch:
    return _build([Int(I64_MIN), 6], [-1, -2], [0, 0], [1, 1], -1, -1)


def test_f64_case_with_min_over_minus_one_in_the_untaken_branch_answers() raises:
    """`CASE WHEN z = -1 THEN 0.5 ELSE a / z END` is [0.5, -3.0]: row 0 takes
    the THEN branch, so MIN / -1 is not part of the answer."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(A))                  # 0
    pool.append(make_col(Z))                  # 1
    pool.append(make_lit_i64(-1))             # 2
    pool.append(_node(EXPR_EQ_I64, 1, 2))     # 3: z = -1
    pool.append(make_lit_f64(0.5))            # 4
    pool.append(_node(EXPR_DIV_I64, 0, 1))    # 5: a / z
    pool.append(make_case_f64(0))             # 6
    var slots: List[Int] = [3, 4, 5]
    var when = List[List[Int]]()
    when.append(slots^)
    var got = _f64(_exec(pool^, when^), _untaken_min_batch(), [0, 1])
    assert_equal(len(got), 2)
    assert_equal(got[0], 0.5)
    assert_equal(got[1], -3.0)


def test_f64_or_with_min_over_minus_one_on_a_true_row_keeps_it() raises:
    """`z = -1 OR (a / z) > 0.5` keeps row 0 (TRUE from the left side) and
    drops row 1 (-3 > 0.5 is FALSE)."""
    var pool = List[RuntimeExpr]()
    pool.append(make_col(A))                       # 0
    pool.append(make_col(Z))                       # 1
    pool.append(make_lit_i64(-1))                  # 2
    pool.append(_node(EXPR_EQ_I64, 1, 2))          # 3: z = -1
    pool.append(_node(EXPR_DIV_I64, 0, 1))         # 4: a / z
    pool.append(make_lit_f64(0.5))                 # 5
    pool.append(_node(EXPR_GT_F64_MIXED, 4, 5))    # 6: (a / z) > 0.5
    pool.append(make_or(3, 6))                     # 7
    _expect(_run(_exec(pool^), _untaken_min_batch()), [0], "z = -1 OR (a / z) > 0.5")


def test_probe_f64_walker_min_plus_one_over_minus_one_no_raise() raises:
    """(MIN + 1) / -1 is MAX, which fits: §5.4 refuses only MIN / -1. The
    Float64 walker widens MIN + 1 to -2^63, the same Float64 as MIN, so a
    MIN / -1 check there must look at the Int64 dividend. MAX widens to
    2^63."""
    var batch = _build([Int(I64_MIN) + 1], [-1], [0], [-1], -1, -1)
    var got = _f64(_div(EXPR_DIV_I64, A, Z), batch, [0])
    assert_equal(len(got), 1)
    assert_equal(got[0], Float64(Int64.MAX))


def _diff_over_diff(mut pool: List[RuntimeExpr]) -> Int:
    """Append `(a - z) / (a - z)` to `pool`; return its slot."""
    var base = len(pool)
    pool.append(make_col(A))                          # base
    pool.append(make_col(Z))                          # base + 1
    pool.append(_node(EXPR_SUB_I64, base, base + 1))  # base + 2: a - z
    pool.append(_node(EXPR_DIV_I64, base + 2, base + 2))
    return base + 3


def _eq_one(var pool: List[RuntimeExpr], value: Int, negate: Bool, var when: List[List[Int]] = List[List[Int]]()) -> ExpressionExecutor:
    """`[NOT] (CAST(<value> AS DOUBLE) = 1)` over `pool`."""
    pool.append(make_i64_to_f64(value))
    var cast = len(pool) - 1
    pool.append(make_lit_f64(1.0))
    pool.append(_node(EXPR_EQ_F64_MIXED, cast, cast + 1))
    if negate:
        pool.append(make_not_bool(cast + 2))
    return _exec(pool^, when^)


def test_cast_quotient_null_channel_reads_the_int64_divisor() raises:
    """`CAST((a - z) / (a - z) AS DOUBLE) = 1`: the Int64 walker divides 1 / 1
    on row 0, so the row is TRUE, not NULL. Row 1 is 0 / 0, NULL. A NULL
    channel that read the divisor through the Float64 walker would see 0.0 on
    row 0 too."""
    var batch = _wide_batch()
    var pool = List[RuntimeExpr]()
    var q = _diff_over_diff(pool)
    _expect(_run(_eq_one(pool.copy(), q, False), batch), [0], "CAST(q) = 1")
    _expect(_run(_eq_one(pool^, q, True), batch), List[Int](), "NOT (CAST(q) = 1)")


def test_int64_case_branch_null_channel_reads_the_int64_divisor() raises:
    """`CAST(CASE WHEN a >= 0 THEN (a - z) / (a - z) ELSE 0 END AS DOUBLE) =
    1`: an Int64 CASE evaluates its branches through the Int64 walker, so the
    NULL channel reads the branch's divisor there (1 on row 0, 0 on row 1)."""
    var batch = _wide_batch()
    var pool = List[RuntimeExpr]()
    var q = _diff_over_diff(pool)
    pool.append(make_col(A))
    pool.append(make_lit_i64(0))
    pool.append(_node(EXPR_GE_I64, len(pool) - 2, len(pool) - 1))
    var cond = len(pool) - 1
    pool.append(make_lit_i64(0))
    var else_slot = len(pool) - 1
    pool.append(make_case_i64(0))
    var case_slot = len(pool) - 1
    var slots: List[Int] = [cond, q, else_slot]
    var when = List[List[Int]]()
    when.append(slots^)
    _expect(_run(_eq_one(pool.copy(), case_slot, False, when.copy()), batch), [0], "CAST(CASE) = 1")
    _expect(_run(_eq_one(pool^, case_slot, True, when^), batch), List[Int](), "NOT (CAST(CASE) = 1)")


def main() raises:
    var suite = TestSuite()
    suite.test[test_i64_zero_divisor_is_null_not_a_raise]()
    suite.test[test_f64_walker_zero_divisor_is_null_not_inf]()
    suite.test[test_i32_zero_divisor_is_null_not_a_raise]()
    suite.test[test_filter_over_a_zero_divisor_quotient_is_unknown]()
    suite.test[test_filter_over_a_cast_zero_divisor_quotient_is_unknown]()
    suite.test[test_i64_min_over_minus_one_raises]()
    suite.test[test_i32_min_over_minus_one_raises]()
    suite.test[test_i64_walker_min_over_minus_one_of_a_wide_quotient_raises]()
    suite.test[test_f64_case_with_min_over_minus_one_in_the_untaken_branch_answers]()
    suite.test[test_f64_or_with_min_over_minus_one_on_a_true_row_keeps_it]()
    suite.test[test_probe_f64_walker_min_plus_one_over_minus_one_no_raise]()
    suite.test[test_cast_quotient_null_channel_reads_the_int64_divisor]()
    suite.test[test_int64_case_branch_null_channel_reads_the_int64_divisor]()
    suite^.run()
