# =============================================================================
# Arithmetic kernel templates of expr_kernel_templates.mojo: ColCol add, sub,
# mul, div over F64, I64, F32 and I32 (ids 1..16), ColLit add, sub, mul, div
# over F64 and I64 (ids 17..24), integer mod (ids 64, 65) and negate (ids
# 60..63).
#
# Every template is driven the way an engine drives it: a column of eleven
# rows is cut into SIMD chunks of W lanes (`eval[W]`) and the rows left over
# go through the scalar oracle (`eval_row`). W runs over 1 (every row a
# one-lane chunk), 4 (two chunks and a 3-row tail), 8 (one chunk and a 3-row
# tail) and 16 (no chunk: every row scalar), so both paths answer every row
# and each lane of a chunk is checked on its own.
#
# Every expected value is written out. Floats are compared bit for bit
# (so -0.0 is not +0.0); a NaN expectation accepts any NaN.
#
# The integer rows pin what the templates do today where it departs from the
# query semantics (docs/design/query_semantics.md, under review in pull
# request 770):
#   - division floors (`-7 / 2` answers -4; section 5.1 says -3), in the
#     ColCol and ColLit templates alike;
#   - modulo is the floored remainder, with the divisor's sign (`-7 % 2`
#     answers 1; section 5.2 says -1);
#   - add, sub, mul and negate wrap on overflow (section 5.5 says error).
# Zero divisors and MIN / -1 are left out: the templates do not guard them
# (their docstrings say so), and a machine division traps there.
# =============================================================================

from std.math import inf, isnan
from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_true

from komira_kernels.simd_of import SimdOf
from komira_kernels.expr_kernel_templates import (
    F32PairRow,
    F32Row,
    F64PairRow,
    F64Row,
    GenBinaryArithAdd_F32_ColCol,
    GenBinaryArithAdd_F64_ColCol,
    GenBinaryArithAdd_F64_ColLit,
    GenBinaryArithAdd_I32_ColCol,
    GenBinaryArithAdd_I64_ColCol,
    GenBinaryArithAdd_I64_ColLit,
    GenBinaryArithDiv_F32_ColCol,
    GenBinaryArithDiv_F64_ColCol,
    GenBinaryArithDiv_F64_ColLit,
    GenBinaryArithDiv_I32_ColCol,
    GenBinaryArithDiv_I64_ColCol,
    GenBinaryArithDiv_I64_ColLit,
    GenBinaryArithMul_F32_ColCol,
    GenBinaryArithMul_F64_ColCol,
    GenBinaryArithMul_F64_ColLit,
    GenBinaryArithMul_I32_ColCol,
    GenBinaryArithMul_I64_ColCol,
    GenBinaryArithMul_I64_ColLit,
    GenBinaryArithSub_F32_ColCol,
    GenBinaryArithSub_F64_ColCol,
    GenBinaryArithSub_F64_ColLit,
    GenBinaryArithSub_I32_ColCol,
    GenBinaryArithSub_I64_ColCol,
    GenBinaryArithSub_I64_ColLit,
    GenBinaryMod_I32_ColCol,
    GenBinaryMod_I64_ColCol,
    GenNegate_F32,
    GenNegate_F64,
    GenNegate_I32,
    GenNegate_I64,
    I32PairRow,
    I32Row,
    I64PairRow,
    I64Row,
)


# -----------------------------------------------------------------------------
# Lane helpers
# -----------------------------------------------------------------------------


def _vec[dt: DType, W: Int](xs: List[Scalar[dt]], off: Int) -> SIMD[dt, W]:
    """Rows off .. off+W-1 of `xs` as one W-lane vector."""
    var v = SIMD[dt, W](xs[off])
    for l in range(W):
        v[l] = xs[off + l]
    return v


def _same[dt: DType](got: Scalar[dt], want: Scalar[dt], what: String) raises:
    """Exact equality; floats bit for bit, any NaN matching a NaN."""
    comptime if dt.is_floating_point():
        if isnan(want):
            assert_true(isnan(got), what + ": want NaN, got " + String(got))
            return
        assert_equal(
            bitcast[DType.uint64](got.cast[DType.float64]()),
            bitcast[DType.uint64](want.cast[DType.float64]()),
            what + ": want " + String(want) + ", got " + String(got),
        )
    else:
        assert_equal(got, want, what)


def _lanes[dt: DType, W: Int](
    got: SIMD[dt, W], want: List[Scalar[dt]], off: Int, what: String
) raises:
    for l in range(W):
        _same[dt](got[l], want[off + l], what + " row " + String(off + l))


# -----------------------------------------------------------------------------
# Cases: eleven rows, operands and every expected answer
# -----------------------------------------------------------------------------


@fieldwise_init
struct BinCases[dt: DType](Movable):
    var a: List[Scalar[Self.dt]]
    var b: List[Scalar[Self.dt]]
    var add: List[Scalar[Self.dt]]
    var sub: List[Scalar[Self.dt]]
    var mul: List[Scalar[Self.dt]]
    var div: List[Scalar[Self.dt]]
    var mod: List[Scalar[Self.dt]]
    var neg: List[Scalar[Self.dt]]


def _float_cases[dt: DType]() -> BinCases[dt]:
    """IEEE rows: signed zeros, overflow to inf, inf and NaN operands.

    Row 6 holds a large `big` in both operands: big + big is 2 * big (exact),
    big * big overflows to inf, big / big is 1.
    """
    comptime S = Scalar[dt]
    var big: S
    comptime if dt == DType.float64:
        big = S(1.0e300)
    else:
        big = S(1.0e38)
    var nan = S(0.0) / S(0.0)
    var pinf = inf[dt]()
    var two_big = big * S(2.0)
    var a: List[S] = [S(1.5), S(-2.0), S(0.0), S(6.0), S(-0.0), S(7.0), big, pinf, nan, S(3.0), S(-4.5)]
    var b: List[S] = [S(0.5), S(4.0), S(-3.0), S(0.25), S(-0.0), S(-7.0), big, S(1.0), S(1.0), S(0.0), S(-1.5)]
    var add: List[S] = [S(2.0), S(2.0), S(-3.0), S(6.25), S(-0.0), S(0.0), two_big, pinf, nan, S(3.0), S(-6.0)]
    var sub: List[S] = [S(1.0), S(-6.0), S(3.0), S(5.75), S(0.0), S(14.0), S(0.0), pinf, nan, S(3.0), S(-3.0)]
    var mul: List[S] = [S(0.75), S(-8.0), S(-0.0), S(1.5), S(0.0), S(-49.0), pinf, pinf, nan, S(0.0), S(6.75)]
    var div: List[S] = [S(3.0), S(-0.5), S(-0.0), S(24.0), nan, S(-1.0), S(1.0), pinf, nan, pinf, S(3.0)]
    var neg: List[S] = [S(-1.5), S(2.0), S(-0.0), S(-6.0), S(0.0), S(-7.0), -big, -pinf, nan, S(-3.0), S(4.5)]
    return BinCases[dt](a^, b^, add^, sub^, mul^, div^, List[S](), neg^)


def _int_cases[dt: DType]() -> BinCases[dt]:
    """Signed rows: every sign pairing of 7 and 2, MAX and MIN, wrap rows.

    Row 8 holds k = 2^h + 1 in both operands (h = 32 for I64, 16 for I32):
    k * k = 2^2h + 2^(h+1) + 1 wraps to 2^(h+1) + 1.
    """
    comptime S = Scalar[dt]
    var mx = S.MAX
    var mn = S.MIN
    var k: S
    var k2: S
    var kk: S
    comptime if dt == DType.int64:
        k = S(4294967297)
        k2 = S(8589934594)
        kk = S(8589934593)
    else:
        k = S(65537)
        k2 = S(131074)
        kk = S(131073)
    var a: List[S] = [S(7), S(-7), S(7), S(-7), S(0), mx, mn, S(6), k, S(100), S(-100)]
    var b: List[S] = [S(2), S(2), S(-2), S(-2), S(5), S(1), S(1), S(3), k, S(7), S(7)]
    var add: List[S] = [S(9), S(-5), S(5), S(-9), S(5), mn, mn + S(1), S(9), k2, S(107), S(-93)]
    var sub: List[S] = [S(5), S(-9), S(9), S(-5), S(-5), mx - S(1), mx, S(3), S(0), S(93), S(-107)]
    var mul: List[S] = [S(14), S(-14), S(-14), S(14), S(0), mx, mn, S(18), kk, S(700), S(-700)]
    var div: List[S] = [S(3), S(-4), S(-4), S(3), S(0), mx, mn, S(2), S(1), S(14), S(-15)]
    var mod: List[S] = [S(1), S(1), S(-1), S(-1), S(0), S(0), S(0), S(0), S(0), S(2), S(5)]
    var neg: List[S] = [S(-7), S(7), S(-7), S(7), S(0), mn + S(1), mn, S(-6), -k, S(-100), S(100)]
    return BinCases[dt](a^, b^, add^, sub^, mul^, div^, mod^, neg^)


# -----------------------------------------------------------------------------
# ColCol drivers: chunks of W through eval[W], the tail through eval_row
# -----------------------------------------------------------------------------


def _run_f64_colcol[W: Int]() raises:
    var c = _float_cases[DType.float64]()
    var n = len(c.a)
    var i = 0
    while i + W <= n:
        var s = SimdOf[F64PairRow, W].zero()
        s.set_f64[0](_vec[DType.float64, W](c.a, i))
        s.set_f64[1](_vec[DType.float64, W](c.b, i))
        _lanes(GenBinaryArithAdd_F64_ColCol.eval[W](s).get_f64[0](), c.add, i, "add f64")
        _lanes(GenBinaryArithSub_F64_ColCol.eval[W](s).get_f64[0](), c.sub, i, "sub f64")
        _lanes(GenBinaryArithMul_F64_ColCol.eval[W](s).get_f64[0](), c.mul, i, "mul f64")
        _lanes(GenBinaryArithDiv_F64_ColCol.eval[W](s).get_f64[0](), c.div, i, "div f64")
        _lanes(GenNegate_F64.eval[W](_Load[W].f64(c.a, i)).get_f64[0](), c.neg, i, "neg f64")
        i += W
    while i < n:
        var r = F64PairRow(a=c.a[i], b=c.b[i])
        var t = "f64 row " + String(i)
        _same(GenBinaryArithAdd_F64_ColCol.eval_row(r).a, c.add[i], "add " + t)
        _same(GenBinaryArithSub_F64_ColCol.eval_row(r).a, c.sub[i], "sub " + t)
        _same(GenBinaryArithMul_F64_ColCol.eval_row(r).a, c.mul[i], "mul " + t)
        _same(GenBinaryArithDiv_F64_ColCol.eval_row(r).a, c.div[i], "div " + t)
        _same(GenNegate_F64.eval_row(F64Row(a=c.a[i])).a, c.neg[i], "neg " + t)
        i += 1


struct _Load[W: Int]:
    """A SimdOf-returning helper lives in a struct: test discovery
    instantiates every module-level function, and a SimdOf in a signature
    with W unbound cannot be sized."""

    @staticmethod
    def f64(xs: List[Float64], off: Int) -> SimdOf[F64Row, Self.W]:
        var s = SimdOf[F64Row, Self.W].zero()
        s.set_f64[0](_vec[DType.float64, Self.W](xs, off))
        return s^


def _run_f32_colcol[W: Int]() raises:
    var c = _float_cases[DType.float32]()
    var n = len(c.a)
    var i = 0
    while i + W <= n:
        var s = SimdOf[F32PairRow, W].zero()
        s.set_f32[0](_vec[DType.float32, W](c.a, i))
        s.set_f32[1](_vec[DType.float32, W](c.b, i))
        _lanes(GenBinaryArithAdd_F32_ColCol.eval[W](s).get_f32[0](), c.add, i, "add f32")
        _lanes(GenBinaryArithSub_F32_ColCol.eval[W](s).get_f32[0](), c.sub, i, "sub f32")
        _lanes(GenBinaryArithMul_F32_ColCol.eval[W](s).get_f32[0](), c.mul, i, "mul f32")
        _lanes(GenBinaryArithDiv_F32_ColCol.eval[W](s).get_f32[0](), c.div, i, "div f32")
        var u = SimdOf[F32Row, W].zero()
        u.set_f32[0](_vec[DType.float32, W](c.a, i))
        _lanes(GenNegate_F32.eval[W](u).get_f32[0](), c.neg, i, "neg f32")
        i += W
    while i < n:
        var r = F32PairRow(a=c.a[i], b=c.b[i])
        var t = "f32 row " + String(i)
        _same(GenBinaryArithAdd_F32_ColCol.eval_row(r).a, c.add[i], "add " + t)
        _same(GenBinaryArithSub_F32_ColCol.eval_row(r).a, c.sub[i], "sub " + t)
        _same(GenBinaryArithMul_F32_ColCol.eval_row(r).a, c.mul[i], "mul " + t)
        _same(GenBinaryArithDiv_F32_ColCol.eval_row(r).a, c.div[i], "div " + t)
        _same(GenNegate_F32.eval_row(F32Row(a=c.a[i])).a, c.neg[i], "neg " + t)
        i += 1


def _run_i64_colcol[W: Int]() raises:
    var c = _int_cases[DType.int64]()
    var n = len(c.a)
    var i = 0
    while i + W <= n:
        var s = SimdOf[I64PairRow, W].zero()
        s.set_i64[0](_vec[DType.int64, W](c.a, i))
        s.set_i64[1](_vec[DType.int64, W](c.b, i))
        _lanes(GenBinaryArithAdd_I64_ColCol.eval[W](s).get_i64[0](), c.add, i, "add i64")
        _lanes(GenBinaryArithSub_I64_ColCol.eval[W](s).get_i64[0](), c.sub, i, "sub i64")
        _lanes(GenBinaryArithMul_I64_ColCol.eval[W](s).get_i64[0](), c.mul, i, "mul i64")
        _lanes(GenBinaryArithDiv_I64_ColCol.eval[W](s).get_i64[0](), c.div, i, "div i64")
        _lanes(GenBinaryMod_I64_ColCol.eval[W](s).get_i64[0](), c.mod, i, "mod i64")
        var u = SimdOf[I64Row, W].zero()
        u.set_i64[0](_vec[DType.int64, W](c.a, i))
        _lanes(GenNegate_I64.eval[W](u).get_i64[0](), c.neg, i, "neg i64")
        i += W
    while i < n:
        var r = I64PairRow(a=c.a[i], b=c.b[i])
        var t = "i64 row " + String(i)
        _same(GenBinaryArithAdd_I64_ColCol.eval_row(r).a, c.add[i], "add " + t)
        _same(GenBinaryArithSub_I64_ColCol.eval_row(r).a, c.sub[i], "sub " + t)
        _same(GenBinaryArithMul_I64_ColCol.eval_row(r).a, c.mul[i], "mul " + t)
        _same(GenBinaryArithDiv_I64_ColCol.eval_row(r).a, c.div[i], "div " + t)
        _same(GenBinaryMod_I64_ColCol.eval_row(r).a, c.mod[i], "mod " + t)
        _same(GenNegate_I64.eval_row(I64Row(a=c.a[i])).a, c.neg[i], "neg " + t)
        i += 1


def _run_i32_colcol[W: Int]() raises:
    var c = _int_cases[DType.int32]()
    var n = len(c.a)
    var i = 0
    while i + W <= n:
        var s = SimdOf[I32PairRow, W].zero()
        s.set_i32[0](_vec[DType.int32, W](c.a, i))
        s.set_i32[1](_vec[DType.int32, W](c.b, i))
        _lanes(GenBinaryArithAdd_I32_ColCol.eval[W](s).get_i32[0](), c.add, i, "add i32")
        _lanes(GenBinaryArithSub_I32_ColCol.eval[W](s).get_i32[0](), c.sub, i, "sub i32")
        _lanes(GenBinaryArithMul_I32_ColCol.eval[W](s).get_i32[0](), c.mul, i, "mul i32")
        _lanes(GenBinaryArithDiv_I32_ColCol.eval[W](s).get_i32[0](), c.div, i, "div i32")
        _lanes(GenBinaryMod_I32_ColCol.eval[W](s).get_i32[0](), c.mod, i, "mod i32")
        var u = SimdOf[I32Row, W].zero()
        u.set_i32[0](_vec[DType.int32, W](c.a, i))
        _lanes(GenNegate_I32.eval[W](u).get_i32[0](), c.neg, i, "neg i32")
        i += W
    while i < n:
        var r = I32PairRow(a=c.a[i], b=c.b[i])
        var t = "i32 row " + String(i)
        _same(GenBinaryArithAdd_I32_ColCol.eval_row(r).a, c.add[i], "add " + t)
        _same(GenBinaryArithSub_I32_ColCol.eval_row(r).a, c.sub[i], "sub " + t)
        _same(GenBinaryArithMul_I32_ColCol.eval_row(r).a, c.mul[i], "mul " + t)
        _same(GenBinaryArithDiv_I32_ColCol.eval_row(r).a, c.div[i], "div " + t)
        _same(GenBinaryMod_I32_ColCol.eval_row(r).a, c.mod[i], "mod " + t)
        _same(GenNegate_I32.eval_row(I32Row(a=c.a[i])).a, c.neg[i], "neg " + t)
        i += 1


# -----------------------------------------------------------------------------
# ColLit drivers: the literal is a runtime argument broadcast to every lane
# -----------------------------------------------------------------------------


def _run_f64_collit[W: Int]() raises:
    """Column `_float_cases` a, literal -2.0."""
    comptime S = Float64
    var a = _float_cases[DType.float64]().a.copy()
    var lit = S(-2.0)
    var nan = S(0.0) / S(0.0)
    var pinf = inf[DType.float64]()
    var add: List[S] = [S(-0.5), S(-4.0), S(-2.0), S(4.0), S(-2.0), S(5.0), S(1.0e300), pinf, nan, S(1.0), S(-6.5)]
    var sub: List[S] = [S(3.5), S(0.0), S(2.0), S(8.0), S(2.0), S(9.0), S(1.0e300), pinf, nan, S(5.0), S(-2.5)]
    var mul: List[S] = [S(-3.0), S(4.0), S(-0.0), S(-12.0), S(0.0), S(-14.0), S(-2.0e300), -pinf, nan, S(-6.0), S(9.0)]
    var div: List[S] = [S(-0.75), S(1.0), S(-0.0), S(-3.0), S(0.0), S(-3.5), S(-5.0e299), -pinf, nan, S(-1.5), S(2.25)]
    var n = len(a)
    var i = 0
    while i + W <= n:
        var s = _Load[W].f64(a, i)
        _lanes(GenBinaryArithAdd_F64_ColLit.eval[W](s, lit).get_f64[0](), add, i, "add f64 lit")
        _lanes(GenBinaryArithSub_F64_ColLit.eval[W](s, lit).get_f64[0](), sub, i, "sub f64 lit")
        _lanes(GenBinaryArithMul_F64_ColLit.eval[W](s, lit).get_f64[0](), mul, i, "mul f64 lit")
        _lanes(GenBinaryArithDiv_F64_ColLit.eval[W](s, lit).get_f64[0](), div, i, "div f64 lit")
        i += W
    while i < n:
        var r = F64Row(a=a[i])
        var t = "f64 lit row " + String(i)
        _same(GenBinaryArithAdd_F64_ColLit.eval_row(r, lit).a, add[i], "add " + t)
        _same(GenBinaryArithSub_F64_ColLit.eval_row(r, lit).a, sub[i], "sub " + t)
        _same(GenBinaryArithMul_F64_ColLit.eval_row(r, lit).a, mul[i], "mul " + t)
        _same(GenBinaryArithDiv_F64_ColLit.eval_row(r, lit).a, div[i], "div " + t)
        i += 1


def _run_i64_collit[W: Int]() raises:
    """Column `_int_cases` a, literal -3: floor division and wrap rows."""
    comptime S = Int64
    var a = _int_cases[DType.int64]().a.copy()
    var lit = S(-3)
    var mx = S.MAX
    var mn = S.MIN
    var add: List[S] = [S(4), S(-10), S(4), S(-10), S(-3), mx - S(3), mx - S(2), S(3), S(4294967294), S(97), S(-103)]
    var sub: List[S] = [S(10), S(-4), S(10), S(-4), S(3), mn + S(2), mn + S(3), S(9), S(4294967300), S(103), S(-97)]
    var mul: List[S] = [S(-21), S(21), S(-21), S(21), S(0), mn + S(3), mn, S(-18), S(-12884901891), S(-300), S(300)]
    var div: List[S] = [S(-3), S(2), S(-3), S(2), S(0), S(-3074457345618258603), S(3074457345618258602), S(-2), S(-1431655766), S(-34), S(33)]
    var n = len(a)
    var i = 0
    while i + W <= n:
        var s = SimdOf[I64Row, W].zero()
        s.set_i64[0](_vec[DType.int64, W](a, i))
        _lanes(GenBinaryArithAdd_I64_ColLit.eval[W](s, lit).get_i64[0](), add, i, "add i64 lit")
        _lanes(GenBinaryArithSub_I64_ColLit.eval[W](s, lit).get_i64[0](), sub, i, "sub i64 lit")
        _lanes(GenBinaryArithMul_I64_ColLit.eval[W](s, lit).get_i64[0](), mul, i, "mul i64 lit")
        _lanes(GenBinaryArithDiv_I64_ColLit.eval[W](s, lit).get_i64[0](), div, i, "div i64 lit")
        i += W
    while i < n:
        var r = I64Row(a=a[i])
        var t = "i64 lit row " + String(i)
        _same(GenBinaryArithAdd_I64_ColLit.eval_row(r, lit).a, add[i], "add " + t)
        _same(GenBinaryArithSub_I64_ColLit.eval_row(r, lit).a, sub[i], "sub " + t)
        _same(GenBinaryArithMul_I64_ColLit.eval_row(r, lit).a, mul[i], "mul " + t)
        _same(GenBinaryArithDiv_I64_ColLit.eval_row(r, lit).a, div[i], "div " + t)
        i += 1


# -----------------------------------------------------------------------------
# Tests: each family at W = 1, 4, 8 and 16
# -----------------------------------------------------------------------------


def test_f64_colcol_and_negate() raises:
    """IDs 1..4 and 60: IEEE answers, -0.0 kept, inf and NaN carried."""
    _run_f64_colcol[1]()
    _run_f64_colcol[4]()
    _run_f64_colcol[8]()
    _run_f64_colcol[16]()


def test_f32_colcol_and_negate() raises:
    """IDs 9..12 and 61: the same rows in single precision."""
    _run_f32_colcol[1]()
    _run_f32_colcol[4]()
    _run_f32_colcol[8]()
    _run_f32_colcol[16]()


def test_i64_colcol_mod_and_negate() raises:
    """IDs 5..8, 64 and 62: floor division, floored modulo, wrap on overflow."""
    _run_i64_colcol[1]()
    _run_i64_colcol[4]()
    _run_i64_colcol[8]()
    _run_i64_colcol[16]()


def test_i32_colcol_mod_and_negate() raises:
    """IDs 13..16, 65 and 63: the same rows at 32 bits."""
    _run_i32_colcol[1]()
    _run_i32_colcol[4]()
    _run_i32_colcol[8]()
    _run_i32_colcol[16]()


def test_f64_collit() raises:
    """IDs 17..20: the literal is the right operand on every lane."""
    _run_f64_collit[1]()
    _run_f64_collit[4]()
    _run_f64_collit[8]()
    _run_f64_collit[16]()


def test_i64_collit() raises:
    """IDs 21..24: floor division by a negative literal, wrap rows."""
    _run_i64_collit[1]()
    _run_i64_collit[4]()
    _run_i64_collit[8]()
    _run_i64_collit[16]()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
