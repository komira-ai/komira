# =============================================================================
# Tests for `builtin_match_fns`: the INT64 / FLOAT64 comparison MatchFn cells
# (LT, LE, GT, GE, EQ, NE), the four validity cells of LtI64, and the IS NULL /
# IS NOT NULL UnaryMatchFn cells.
#
# THE ORACLE IS WRITTEN OUT, NOT RECOMPUTED. Each row's right-hand side is
# built from its left-hand side and a hand-chosen relation `d` (+1: lhs < rhs,
# 0: equal, -1: lhs > rhs), so the expected bit of every operator follows from
# `d` alone (LT is d == +1, LE is d >= 0, ...), never from the comparison
# operator under test. Null handling follows the documented PROPAGATE model
# (`match_fn.mojo`): a row with a NULL on a side whose validity the cell reads
# is a non-match. IEEE 754 and SQL agree on every float row here (-0.0 equals
# 0.0; infinities order at the ends; subnormals order by value); NaN rows are
# deliberately absent, because SQL engines order NaN while IEEE 754 does not,
# and this file pins no answer the two disagree on.
#
# The lengths are chosen for the kernel's two shapes: 21 rows give two full
# bitmap bytes and a ragged tail of 5 (for any SIMD width 2, 4 or 8), 16 rows
# give no tail, 3 rows give a tail only, 0 rows give nothing to write.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.bitmap import Bitmap, bytes_for_bits
from komira_arrow.primitive_array import PrimitiveArray
from komira_plan_expr.expr import (
    BIN_LT,
    BIN_LE,
    BIN_GT,
    BIN_GE,
    BIN_EQ,
    BIN_NE,
    UN_IS_NULL,
    UN_IS_NOT_NULL,
)
from komira_kernels.builtin_match_fns import (
    LtI64,
    LtI64_LV,
    LtI64_RV,
    LtI64_LRV,
    LeI64,
    GtI64,
    GeI64,
    EqI64,
    NeI64,
    LtF64,
    LeF64,
    GtF64,
    GeF64,
    EqF64,
    NeF64,
    IsNullI64,
    IsNotNullI64,
    IsNullF64,
    IsNotNullF64,
)


# -----------------------------------------------------------------------------
# Fixtures
# -----------------------------------------------------------------------------


def _d() -> List[Int]:
    """The relation of row i: +1 lhs < rhs, 0 equal, -1 lhs > rhs. The tail
    (rows 16..20) holds true and false rows for every operator."""
    return [1, 0, -1, 1, 1, 0, -1, -1, 0, 0, 1, -1, 1, 0, 0, -1, 1, 1, 0, 1, -1]


def _want(op: UInt8, d: Int) -> Bool:
    if op == BIN_LT:
        return d == 1
    if op == BIN_LE:
        return d >= 0
    if op == BIN_GT:
        return d == -1
    if op == BIN_GE:
        return d <= 0
    if op == BIN_EQ:
        return d == 0
    return d != 0


def _i64_pair(n: Int) -> Tuple[PrimitiveArray[DType.int64], PrimitiveArray[DType.int64]]:
    var d = _d()
    var l = List[Scalar[DType.int64]]()
    var r = List[Scalar[DType.int64]]()
    for i in range(n):
        var lv = Int64((i - 10) * 1_000_003)
        if i == 3:
            lv = Int64.MAX - 1  # rhs is Int64.MAX
        elif i == 7:
            lv = Int64.MIN + 1  # rhs is Int64.MIN
        l.append(lv)
        r.append(lv + Int64(d[i]))
    return (
        PrimitiveArray[DType.int64].from_list(l),
        PrimitiveArray[DType.int64].from_list(r),
    )


def _f64_pair(n: Int) -> Tuple[PrimitiveArray[DType.float64], PrimitiveArray[DType.float64]]:
    var d = _d()
    var inf = Float64.MAX_FINITE * 2.0
    var l = List[Scalar[DType.float64]]()
    var r = List[Scalar[DType.float64]]()
    for i in range(n):
        # Multiples of 0.25 are exact in binary, so lhs + d * 0.25 is exact.
        var lv = Float64(i - 10) * 0.75
        var rv = lv + Float64(d[i]) * 0.25
        if i == 1:
            lv = -0.0  # d = 0: -0.0 equals 0.0
            rv = 0.0
        elif i == 4:
            lv = -inf  # d = +1
            rv = -Float64.MAX_FINITE
        elif i == 6:
            lv = inf  # d = -1
            rv = Float64.MAX_FINITE
        elif i == 12:
            lv = 4.9406564584124654e-324  # d = +1, the smallest subnormal
            rv = 9.8813129168249309e-324
        elif i == 18:
            lv = inf  # d = 0
            rv = inf
        l.append(lv)
        r.append(rv)
    return (
        PrimitiveArray[DType.float64].from_list(l),
        PrimitiveArray[DType.float64].from_list(r),
    )


def _check(mask: Bitmap, count: Int, want: List[Bool], what: String) raises:
    """Every row's bit, the returned match count, and zero bits after the
    last row up to the end of the last byte."""
    var n = len(want)
    var expect = 0
    for i in range(n):
        assert_equal(mask.test(i), want[i], what + " row " + String(i))
        if want[i]:
            expect += 1
    assert_equal(count, expect, what + " count")
    for i in range(n, bytes_for_bits(n) * 8):
        assert_false(mask.test(i), what + " bit past the end " + String(i))


def _ops_want(op: UInt8, n: Int) -> List[Bool]:
    var d = _d()
    var w = List[Bool]()
    for i in range(n):
        w.append(_want(op, d[i]))
    return w^


def _lengths() -> List[Int]:
    return [21, 16, 3, 0]


# -----------------------------------------------------------------------------
# INT64 / FLOAT64 comparison cells, non-nullable
# -----------------------------------------------------------------------------


def test_i64_every_op_every_length() raises:
    for n in _lengths():
        var p = _i64_pair(n)
        var m = Bitmap.create(n)
        _check(m, LtI64().eval_chunk(p[0], p[1], m), _ops_want(BIN_LT, n), "LtI64")
        m = Bitmap.create(n)
        _check(m, LeI64().eval_chunk(p[0], p[1], m), _ops_want(BIN_LE, n), "LeI64")
        m = Bitmap.create(n)
        _check(m, GtI64().eval_chunk(p[0], p[1], m), _ops_want(BIN_GT, n), "GtI64")
        m = Bitmap.create(n)
        _check(m, GeI64().eval_chunk(p[0], p[1], m), _ops_want(BIN_GE, n), "GeI64")
        m = Bitmap.create(n)
        _check(m, EqI64().eval_chunk(p[0], p[1], m), _ops_want(BIN_EQ, n), "EqI64")
        m = Bitmap.create(n)
        _check(m, NeI64().eval_chunk(p[0], p[1], m), _ops_want(BIN_NE, n), "NeI64")


def test_f64_every_op_every_length() raises:
    for n in _lengths():
        var p = _f64_pair(n)
        var m = Bitmap.create(n)
        _check(m, LtF64().eval_chunk(p[0], p[1], m), _ops_want(BIN_LT, n), "LtF64")
        m = Bitmap.create(n)
        _check(m, LeF64().eval_chunk(p[0], p[1], m), _ops_want(BIN_LE, n), "LeF64")
        m = Bitmap.create(n)
        _check(m, GtF64().eval_chunk(p[0], p[1], m), _ops_want(BIN_GT, n), "GtF64")
        m = Bitmap.create(n)
        _check(m, GeF64().eval_chunk(p[0], p[1], m), _ops_want(BIN_GE, n), "GeF64")
        m = Bitmap.create(n)
        _check(m, EqF64().eval_chunk(p[0], p[1], m), _ops_want(BIN_EQ, n), "EqF64")
        m = Bitmap.create(n)
        _check(m, NeF64().eval_chunk(p[0], p[1], m), _ops_want(BIN_NE, n), "NeF64")


def test_all_rows_match_and_no_row_matches() raises:
    """A full mask (every bit of both bytes set) and an empty one: the
    count is the popcount of what was written, at both extremes."""
    var l = List[Scalar[DType.int64]]()
    var r = List[Scalar[DType.int64]]()
    for i in range(21):
        l.append(Int64(i))
        r.append(Int64(i + 1))
    var a = PrimitiveArray[DType.int64].from_list(l)
    var b = PrimitiveArray[DType.int64].from_list(r)
    var all_true = List[Bool]()
    var all_false = List[Bool]()
    for _ in range(21):
        all_true.append(True)
        all_false.append(False)
    var m = Bitmap.create(21)
    _check(m, LtI64().eval_chunk(a, b, m), all_true, "all match")
    m = Bitmap.create(21)
    _check(m, GeI64().eval_chunk(a, b, m), all_false, "none match")


# -----------------------------------------------------------------------------
# LtI64 validity cells
# -----------------------------------------------------------------------------


def _nullable_i64(
    src: PrimitiveArray[DType.int64], nulls: List[Int]
) raises -> PrimitiveArray[DType.int64]:
    """A copy of `src` with a validity bitmap and the given rows NULL. The
    data under a NULL row keeps its value, so only the bitmap can hide it."""
    var a = PrimitiveArray[DType.int64].allocate_nullable(src.length)
    for i in range(src.length):
        a.set(i, src.get(i))
    for i in nulls:
        a._set_null(i)
    return a^


def _lhs_nulls() -> List[Int]:
    # 2: a false row; 3: a true full-byte row; 4: null on both sides;
    # 17: a true tail row; 20: a false tail row.
    return [2, 3, 4, 17, 20]


def _rhs_nulls() -> List[Int]:
    # 4: null on both sides; 10: a true full-byte row; 19: a true tail row
    # whose lhs is valid.
    return [4, 10, 19]


def _in(i: Int, xs: List[Int]) -> Bool:
    for x in xs:
        if x == i:
            return True
    return False


def test_lt_i64_validity_cells() raises:
    """Each cell ANDs exactly the validity it names: LV the lhs bitmap, RV
    the rhs bitmap, LRV both. Nulls sit in the full bytes and in the tail."""
    var n = 21
    var p = _i64_pair(n)
    var ln = _lhs_nulls()
    var rn = _rhs_nulls()
    var l = _nullable_i64(p[0], ln)
    var r = _nullable_i64(p[1], rn)
    var d = _d()
    var w_lv = List[Bool]()
    var w_rv = List[Bool]()
    var w_lrv = List[Bool]()
    for i in range(n):
        var lt = d[i] == 1
        w_lv.append(lt and not _in(i, ln))
        w_rv.append(lt and not _in(i, rn))
        w_lrv.append(lt and not _in(i, ln) and not _in(i, rn))
    var m = Bitmap.create(n)
    _check(m, LtI64_LV().eval_chunk(l, r, m), w_lv, "LtI64_LV")
    m = Bitmap.create(n)
    _check(m, LtI64_RV().eval_chunk(l, r, m), w_rv, "LtI64_RV")
    m = Bitmap.create(n)
    _check(m, LtI64_LRV().eval_chunk(l, r, m), w_lrv, "LtI64_LRV")


def test_lt_i64_validity_cells_short_input() raises:
    """Three rows: everything is the scalar tail. Row 1 is equal (false),
    row 0 lt with an lhs null, row 2 lt with an rhs null."""
    var l0 = List[Scalar[DType.int64]]()
    var r0 = List[Scalar[DType.int64]]()
    l0.append(Int64(-5))
    r0.append(Int64(5))
    l0.append(Int64(7))
    r0.append(Int64(7))
    l0.append(Int64(1))
    r0.append(Int64(2))
    var l = _nullable_i64(PrimitiveArray[DType.int64].from_list(l0), [0])
    var r = _nullable_i64(PrimitiveArray[DType.int64].from_list(r0), [2])
    var m = Bitmap.create(3)
    _check(m, LtI64_LV().eval_chunk(l, r, m), [False, False, True], "LV short")
    m = Bitmap.create(3)
    _check(m, LtI64_RV().eval_chunk(l, r, m), [True, False, False], "RV short")
    m = Bitmap.create(3)
    _check(m, LtI64_LRV().eval_chunk(l, r, m), [False, False, False], "LRV short")


# -----------------------------------------------------------------------------
# Unary IS NULL / IS NOT NULL
# -----------------------------------------------------------------------------


def _with_nulls_i64(n: Int, nulls: List[Int]) raises -> PrimitiveArray[DType.int64]:
    var a = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        a.set(i, Scalar[DType.int64](Int64(i * 3)))
    for i in nulls:
        a._set_null(i)
    return a^


def _with_nulls_f64(n: Int, nulls: List[Int]) raises -> PrimitiveArray[DType.float64]:
    var a = PrimitiveArray[DType.float64].allocate_nullable(n)
    for i in range(n):
        a.set(i, Scalar[DType.float64](Float64(i) * 0.5))
    for i in nulls:
        a._set_null(i)
    return a^


def _null_want(n: Int, nulls: List[Int], is_null: Bool) -> List[Bool]:
    var w = List[Bool]()
    for i in range(n):
        w.append(_in(i, nulls) == is_null)
    return w^


def _unary_cases() -> List[Tuple[Int, List[Int]]]:
    """(length, null rows): a ragged last byte with nulls in both bytes, a
    ragged last byte with no null (the bits past the end of the negated
    byte are the only ones set and must not count), whole bytes, nothing."""
    var c = List[Tuple[Int, List[Int]]]()
    var ragged: List[Int] = [0, 5, 9, 10]
    var whole: List[Int] = [7, 8, 15]
    c.append((11, ragged^))
    c.append((11, List[Int]()))
    c.append((16, whole^))
    c.append((0, List[Int]()))
    return c^


def test_is_null_and_is_not_null_i64() raises:
    for c in _unary_cases():
        var n = c[0]
        var a = _with_nulls_i64(n, c[1])
        var m = Bitmap.create(n)
        _check(m, IsNullI64().eval_chunk(a, m), _null_want(n, c[1], True), "IsNullI64 n=" + String(n))
        m = Bitmap.create(n)
        _check(m, IsNotNullI64().eval_chunk(a, m), _null_want(n, c[1], False), "IsNotNullI64 n=" + String(n))


def test_is_null_and_is_not_null_f64() raises:
    for c in _unary_cases():
        var n = c[0]
        var a = _with_nulls_f64(n, c[1])
        var m = Bitmap.create(n)
        _check(m, IsNullF64().eval_chunk(a, m), _null_want(n, c[1], True), "IsNullF64 n=" + String(n))
        m = Bitmap.create(n)
        _check(m, IsNotNullF64().eval_chunk(a, m), _null_want(n, c[1], False), "IsNotNullF64 n=" + String(n))


# -----------------------------------------------------------------------------
# Identity: names, op tags and validity flags the operator dispatches on
# -----------------------------------------------------------------------------


def test_names() raises:
    assert_equal(LtI64().name(), "LtI64")
    assert_equal(LtI64_LV().name(), "LtI64_LV")
    assert_equal(LtI64_RV().name(), "LtI64_RV")
    assert_equal(LtI64_LRV().name(), "LtI64_LRV")
    assert_equal(LeI64().name(), "LeI64")
    assert_equal(GtI64().name(), "GtI64")
    assert_equal(GeI64().name(), "GeI64")
    assert_equal(EqI64().name(), "EqI64")
    assert_equal(NeI64().name(), "NeI64")
    assert_equal(LtF64().name(), "LtF64")
    assert_equal(LeF64().name(), "LeF64")
    assert_equal(GtF64().name(), "GtF64")
    assert_equal(GeF64().name(), "GeF64")
    assert_equal(EqF64().name(), "EqF64")
    assert_equal(NeF64().name(), "NeF64")
    assert_equal(IsNullI64().name(), "IsNullI64")
    assert_equal(IsNotNullI64().name(), "IsNotNullI64")
    assert_equal(IsNullF64().name(), "IsNullF64")
    assert_equal(IsNotNullF64().name(), "IsNotNullF64")


def test_op_tags_and_validity_flags() raises:
    """The operator picks a cell by these comptime members; a cell whose tag
    or flags disagree with its body is dispatched to the wrong rows."""
    assert_equal(Int(LtI64.OP_TAG), Int(BIN_LT))
    assert_equal(Int(LeI64.OP_TAG), Int(BIN_LE))
    assert_equal(Int(GtI64.OP_TAG), Int(BIN_GT))
    assert_equal(Int(GeI64.OP_TAG), Int(BIN_GE))
    assert_equal(Int(EqI64.OP_TAG), Int(BIN_EQ))
    assert_equal(Int(NeI64.OP_TAG), Int(BIN_NE))
    assert_equal(Int(LtF64.OP_TAG), Int(BIN_LT))
    assert_equal(Int(LeF64.OP_TAG), Int(BIN_LE))
    assert_equal(Int(GtF64.OP_TAG), Int(BIN_GT))
    assert_equal(Int(GeF64.OP_TAG), Int(BIN_GE))
    assert_equal(Int(EqF64.OP_TAG), Int(BIN_EQ))
    assert_equal(Int(NeF64.OP_TAG), Int(BIN_NE))
    assert_equal(Int(IsNullI64.OP_TAG), Int(UN_IS_NULL))
    assert_equal(Int(IsNotNullI64.OP_TAG), Int(UN_IS_NOT_NULL))
    assert_equal(Int(IsNullF64.OP_TAG), Int(UN_IS_NULL))
    assert_equal(Int(IsNotNullF64.OP_TAG), Int(UN_IS_NOT_NULL))
    assert_false(LtI64.LHS_VALID)
    assert_false(LtI64.RHS_VALID)
    assert_true(LtI64_LV.LHS_VALID)
    assert_false(LtI64_LV.RHS_VALID)
    assert_false(LtI64_RV.LHS_VALID)
    assert_true(LtI64_RV.RHS_VALID)
    assert_true(LtI64_LRV.LHS_VALID)
    assert_true(LtI64_LRV.RHS_VALID)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
