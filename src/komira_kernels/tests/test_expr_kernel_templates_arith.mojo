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
# The integer rows are chosen so every answer is the same under the query
# semantics (docs/design/query_semantics.md, under review in pull request
# 770) and under what the templates do today. Where the two differ the
# behaviour is NOT pinned here (#937): a mixed-sign division or modulo with a
# remainder (the templates floor, section 5.1 and 5.2 truncate) and an
# overflowing add, sub, mul or negate (the templates wrap, section 5.5 says
# error). Mixed-sign rows divide exactly; every result is in range.
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
    """Signed rows on which truncating and floor semantics agree, no overflow.

    Same-sign pairs carry the remainders (7 % 2, -7 % -2, 100 % 7, -100 % -7);
    mixed-sign pairs divide exactly (-8 / 2, 9 / -3). Rows 5 and 6 hold
    +-big (2^62 - 1 for I64, 2^30 - 1 for I32) with 1, row 8 is 46340 squared
    (fits I32). Not pinned (#937): floor vs truncation on a mixed-sign
    remainder and wrap on overflow.
    """
    comptime S = Scalar[dt]
    var big: S
    comptime if dt == DType.int64:
        big = S(4611686018427387903)
    else:
        big = S(1073741823)
    var a: List[S] = [S(7), S(-7), S(-8), S(9), S(0), big, -big, S(6), S(46340), S(100), S(-100)]
    var b: List[S] = [S(2), S(-2), S(2), S(-3), S(5), S(1), S(1), S(3), S(46340), S(7), S(-7)]
    var add: List[S] = [S(9), S(-9), S(-6), S(6), S(5), big + S(1), -big + S(1), S(9), S(92680), S(107), S(-107)]
    var sub: List[S] = [S(5), S(-5), S(-10), S(12), S(-5), big - S(1), -big - S(1), S(3), S(0), S(93), S(-93)]
    var mul: List[S] = [S(14), S(14), S(-16), S(-27), S(0), big, -big, S(18), S(2147395600), S(700), S(700)]
    var div: List[S] = [S(3), S(3), S(-4), S(-3), S(0), big, -big, S(2), S(1), S(14), S(14)]
    var mod: List[S] = [S(1), S(-1), S(0), S(0), S(0), S(0), S(0), S(0), S(0), S(2), S(-2)]
    var neg: List[S] = [S(-7), S(7), S(8), S(-9), S(0), -big, big, S(-6), S(-46340), S(-100), S(100)]
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
    """Literal -3: negative rows divide with the same sign, positive rows are
    multiples of 3, and +-m (m = 3074457345618258600, a multiple of 3) times -3
    stays in range. Not pinned (#937): floor vs truncation on a mixed-sign
    remainder and wrap on overflow."""
    comptime S = Int64
    var m = S(3074457345618258600)
    var a: List[S] = [S(-7), S(-8), S(9), S(0), S(6), S(-100), S(300), S(-1), S(-2), m, -m]
    var lit = S(-3)
    var add: List[S] = [S(-10), S(-11), S(6), S(-3), S(3), S(-103), S(297), S(-4), S(-5), S(3074457345618258597), S(-3074457345618258603)]
    var sub: List[S] = [S(-4), S(-5), S(12), S(3), S(9), S(-97), S(303), S(2), S(1), S(3074457345618258603), S(-3074457345618258597)]
    var mul: List[S] = [S(21), S(24), S(-27), S(0), S(-18), S(300), S(-900), S(3), S(6), S(-9223372036854775800), S(9223372036854775800)]
    var div: List[S] = [S(2), S(2), S(-3), S(0), S(-2), S(33), S(-100), S(0), S(0), S(-1024819115206086200), S(1024819115206086200)]
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
    """IDs 5..8, 64 and 62: in-range rows only (#937)."""
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
    """IDs 21..24: a negative literal, in-range rows only (#937)."""
    _run_i64_collit[1]()
    _run_i64_collit[4]()
    _run_i64_collit[8]()
    _run_i64_collit[16]()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
