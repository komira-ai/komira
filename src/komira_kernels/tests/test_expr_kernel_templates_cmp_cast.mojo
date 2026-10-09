# =============================================================================
# Comparison, cast, when, is_null and id templates of expr_kernel_templates.mojo:
# ColLit comparisons over F64 and I64 (ids 25..36), casts (ids 37..44),
# when/otherwise (ids 45..48), is_null / is_not_null (ids 49..56), the
# InterpretedExprKernel sentinel (id 0) and the id table itself.
#
# Every template is driven as an engine drives it: an eleven-row column cut
# into chunks of W lanes (`eval[W]`), the rest through the scalar oracle
# (`eval_row`), with W over 1, 4, 8 and 16 (16: every row scalar); when is
# driven at 4, 8 and 16 (see its section). Each lane
# is checked against a written-out answer; floats bit for bit.
#
# Float rows follow IEEE 754: a NaN row is FALSE for every ordered operator
# and for =, TRUE for <>, and F64 -> F32 turns a finite out-of-range value
# into inf. (Section 4.5 of the query semantics, docs/design/query_semantics.md
# under review in pull request 770, proposes NaN = NaN and NaN > x; it is
# undecided.)
#
# The NaN row of template 30 (`<>`) is pinned TRUE on both paths: eval[W]
# used `.ne()`, an ordered compare that answered FALSE where eval_row
# answered TRUE (#937).
#
# Not pinned here (#937), because today's answer is believed wrong:
#   - I64 -> I32 of an out-of-range value keeps its low 32 bits (section 6.2
#     says error); only in-range values are cast.
# Float -> I64 casts are driven inside the I64 range only: the templates
# check no range, and a NaN, inf or out-of-range input has no defined
# machine answer.
# =============================================================================

from std.math import inf, isnan
from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_true

from komira_kernels.simd_of import SimdOf
from komira_kernels.expr_kernel_templates import *


# -----------------------------------------------------------------------------
# Lane helpers
# -----------------------------------------------------------------------------


def _vec[dt: DType, W: Int](xs: List[Scalar[dt]], off: Int) -> SIMD[dt, W]:
    var v = SIMD[dt, W](xs[off])
    for l in range(W):
        v[l] = xs[off + l]
    return v


def _bvec[W: Int](xs: List[Bool], off: Int) -> SIMD[DType.bool, W]:
    var v = SIMD[DType.bool, W](fill=xs[off])
    for l in range(W):
        v[l] = xs[off + l]
    return v


def _same[dt: DType](got: Scalar[dt], want: Scalar[dt], what: String) raises:
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


def _blanes[W: Int](
    got: SIMD[DType.bool, W], want: List[Bool], off: Int, what: String
) raises:
    for l in range(W):
        assert_equal(Bool(got[l]), want[off + l], what + " row " + String(off + l))


struct _Load[W: Int]:
    """SimdOf-returning helpers live in a struct: test discovery instantiates
    every module-level function, and a SimdOf in a signature with W unbound
    cannot be sized."""

    @staticmethod
    def f64(xs: List[Float64], off: Int) -> SimdOf[F64Row, Self.W]:
        var s = SimdOf[F64Row, Self.W].zero()
        s.set_f64[0](_vec[DType.float64, Self.W](xs, off))
        return s^

    @staticmethod
    def i64(xs: List[Int64], off: Int) -> SimdOf[I64Row, Self.W]:
        var s = SimdOf[I64Row, Self.W].zero()
        s.set_i64[0](_vec[DType.int64, Self.W](xs, off))
        return s^

    @staticmethod
    def f32(xs: List[Float32], off: Int) -> SimdOf[F32Row, Self.W]:
        var s = SimdOf[F32Row, Self.W].zero()
        s.set_f32[0](_vec[DType.float32, Self.W](xs, off))
        return s^

    @staticmethod
    def i32(xs: List[Int32], off: Int) -> SimdOf[I32Row, Self.W]:
        var s = SimdOf[I32Row, Self.W].zero()
        s.set_i32[0](_vec[DType.int32, Self.W](xs, off))
        return s^


comptime T = True
comptime F = False


# -----------------------------------------------------------------------------
# Comparisons (ids 25..36)
# -----------------------------------------------------------------------------


def _run_cmp_f64[W: Int]() raises:
    """Literal 2.0 against both neighbours of 2.0, signed zero, infinities, NaN."""
    var lit = Float64(2.0)
    var a: List[Float64] = [
        1.0, 2.0, 3.0, -inf[DType.float64](), inf[DType.float64](),
        Float64(0.0) / Float64(0.0), -0.0, 2.0000000000000004,
        1.9999999999999998, -2.0, 0.0,
    ]
    var gt: List[Bool] = [F, F, T, F, T, F, F, T, F, F, F]
    var ge: List[Bool] = [F, T, T, F, T, F, F, T, F, F, F]
    var lt: List[Bool] = [T, F, F, T, F, F, T, F, T, T, T]
    var le: List[Bool] = [T, T, F, T, F, F, T, F, T, T, T]
    var eq: List[Bool] = [F, T, F, F, F, F, F, F, F, F, F]
    var ne: List[Bool] = [T, F, T, T, T, T, T, T, T, T, T]
    # Row 5 (NaN) of `<>` is TRUE on eval[W] as on eval_row (#937).
    var n = len(a)
    var i = 0
    while i + W <= n:
        var s = _Load[W].f64(a, i)
        _blanes(GenBinaryCmpGt_F64_ColLit.eval[W](s, lit).get_bool[0](), gt, i, "gt f64")
        _blanes(GenBinaryCmpGe_F64_ColLit.eval[W](s, lit).get_bool[0](), ge, i, "ge f64")
        _blanes(GenBinaryCmpLt_F64_ColLit.eval[W](s, lit).get_bool[0](), lt, i, "lt f64")
        _blanes(GenBinaryCmpLe_F64_ColLit.eval[W](s, lit).get_bool[0](), le, i, "le f64")
        _blanes(GenBinaryCmpEq_F64_ColLit.eval[W](s, lit).get_bool[0](), eq, i, "eq f64")
        _blanes(GenBinaryCmpNe_F64_ColLit.eval[W](s, lit).get_bool[0](), ne, i, "ne f64")
        i += W
    while i < n:
        var r = F64Row(a=a[i])
        var t = " f64 row " + String(i)
        assert_equal(GenBinaryCmpGt_F64_ColLit.eval_row(r, lit).a, gt[i], "gt" + t)
        assert_equal(GenBinaryCmpGe_F64_ColLit.eval_row(r, lit).a, ge[i], "ge" + t)
        assert_equal(GenBinaryCmpLt_F64_ColLit.eval_row(r, lit).a, lt[i], "lt" + t)
        assert_equal(GenBinaryCmpLe_F64_ColLit.eval_row(r, lit).a, le[i], "le" + t)
        assert_equal(GenBinaryCmpEq_F64_ColLit.eval_row(r, lit).a, eq[i], "eq" + t)
        assert_equal(GenBinaryCmpNe_F64_ColLit.eval_row(r, lit).a, ne[i], "ne" + t)
        i += 1


def _run_cmp_i64[W: Int]() raises:
    """Literal -3 against its neighbours, both extremes, both signs."""
    var lit = Int64(-3)
    var a: List[Int64] = [-4, -3, -2, Int64.MIN, Int64.MAX, 0, 3, -3, 5, -100, 100]
    var gt: List[Bool] = [F, F, T, F, T, T, T, F, T, F, T]
    var ge: List[Bool] = [F, T, T, F, T, T, T, T, T, F, T]
    var lt: List[Bool] = [T, F, F, T, F, F, F, F, F, T, F]
    var le: List[Bool] = [T, T, F, T, F, F, F, T, F, T, F]
    var eq: List[Bool] = [F, T, F, F, F, F, F, T, F, F, F]
    var ne: List[Bool] = [T, F, T, T, T, T, T, F, T, T, T]
    var n = len(a)
    var i = 0
    while i + W <= n:
        var s = _Load[W].i64(a, i)
        _blanes(GenBinaryCmpGt_I64_ColLit.eval[W](s, lit).get_bool[0](), gt, i, "gt i64")
        _blanes(GenBinaryCmpGe_I64_ColLit.eval[W](s, lit).get_bool[0](), ge, i, "ge i64")
        _blanes(GenBinaryCmpLt_I64_ColLit.eval[W](s, lit).get_bool[0](), lt, i, "lt i64")
        _blanes(GenBinaryCmpLe_I64_ColLit.eval[W](s, lit).get_bool[0](), le, i, "le i64")
        _blanes(GenBinaryCmpEq_I64_ColLit.eval[W](s, lit).get_bool[0](), eq, i, "eq i64")
        _blanes(GenBinaryCmpNe_I64_ColLit.eval[W](s, lit).get_bool[0](), ne, i, "ne i64")
        i += W
    while i < n:
        var r = I64Row(a=a[i])
        var t = " i64 row " + String(i)
        assert_equal(GenBinaryCmpGt_I64_ColLit.eval_row(r, lit).a, gt[i], "gt" + t)
        assert_equal(GenBinaryCmpGe_I64_ColLit.eval_row(r, lit).a, ge[i], "ge" + t)
        assert_equal(GenBinaryCmpLt_I64_ColLit.eval_row(r, lit).a, lt[i], "lt" + t)
        assert_equal(GenBinaryCmpLe_I64_ColLit.eval_row(r, lit).a, le[i], "le" + t)
        assert_equal(GenBinaryCmpEq_I64_ColLit.eval_row(r, lit).a, eq[i], "eq" + t)
        assert_equal(GenBinaryCmpNe_I64_ColLit.eval_row(r, lit).a, ne[i], "ne" + t)
        i += 1


# -----------------------------------------------------------------------------
# Casts (ids 37..44)
# -----------------------------------------------------------------------------


def _run_cast_from_f64[W: Int]() raises:
    """F64 -> F32 (rounding, overflow to inf) and F64 -> I64 (half to even)."""
    var nan = Float64(0.0) / Float64(0.0)
    var pinf = inf[DType.float64]()
    var a: List[Float64] = [1.5, -0.0, 0.1, 1.0e300, -1.0e300, nan, pinf, 3.4028234663852886e38, 16777217.0, 2.0, -7.25]
    var f32: List[Float32] = [1.5, -0.0, Float32(0.1), inf[DType.float32](), -inf[DType.float32](), Float32(0.0) / Float32(0.0), inf[DType.float32](), Float32.MAX_FINITE, 16777216.0, 2.0, -7.25]
    var r: List[Float64] = [2.5, 3.5, -2.5, -3.5, 0.5, -0.5, 1.4999999999999998, 2.6, -2.6, 4503599627370495.5, 1.0e18]
    var i64: List[Int64] = [2, 4, -2, -4, 0, 0, 1, 3, -3, 4503599627370496, 1000000000000000000]
    var n = len(a)
    var i = 0
    while i + W <= n:
        _lanes(GenCast_F64_To_F32.eval[W](_Load[W].f64(a, i)).get_f32[0](), f32, i, "f64->f32")
        _lanes(GenCast_F64_To_I64.eval[W](_Load[W].f64(r, i)).get_i64[0](), i64, i, "f64->i64")
        i += W
    while i < n:
        _same(GenCast_F64_To_F32.eval_row(F64Row(a=a[i])).a, f32[i], "f64->f32 row " + String(i))
        _same(GenCast_F64_To_I64.eval_row(F64Row(a=r[i])).a, i64[i], "f64->i64 row " + String(i))
        i += 1


def _run_cast_from_f32[W: Int]() raises:
    """F32 -> F64 (exact widening) and F32 -> I64 (half to even)."""
    var a: List[Float32] = [Float32(0.1), -0.0, inf[DType.float32](), Float32(0.0) / Float32(0.0), 1.5, -2.5, Float32.MAX_FINITE, 16777216.0, bitcast[DType.float32](UInt32(1)), 0.0, -7.25]
    var f64: List[Float64] = [0.10000000149011612, -0.0, inf[DType.float64](), Float64(0.0) / Float64(0.0), 1.5, -2.5, 3.4028234663852886e38, 16777216.0, 1.401298464324817e-45, 0.0, -7.25]
    var r: List[Float32] = [2.5, 3.5, -2.5, -3.5, 0.5, 1.5, -1.5, 16777216.0, 1.0e10, 0.25, 0.75]
    var i64: List[Int64] = [2, 4, -2, -4, 0, 2, -2, 16777216, 10000000000, 0, 1]
    var n = len(a)
    var i = 0
    while i + W <= n:
        _lanes(GenCast_F32_To_F64.eval[W](_Load[W].f32(a, i)).get_f64[0](), f64, i, "f32->f64")
        _lanes(GenCast_F32_To_I64.eval[W](_Load[W].f32(r, i)).get_i64[0](), i64, i, "f32->i64")
        i += W
    while i < n:
        _same(GenCast_F32_To_F64.eval_row(F32Row(a=a[i])).a, f64[i], "f32->f64 row " + String(i))
        _same(GenCast_F32_To_I64.eval_row(F32Row(a=r[i])).a, i64[i], "f32->i64 row " + String(i))
        i += 1


def _run_cast_from_i64[W: Int]() raises:
    """I64 -> I32 over in-range values, both I32 extremes included, and
    I64 -> F64 (ties to even). An out-of-range I64 -> I32 is not pinned
    (#937): the template keeps the low bits, section 6.2 says error."""
    var a: List[Int64] = [5, -5, 70000, -70000, 1, 2147483647, -2147483648, 0, 123456789, -123456789, -1]
    var i32: List[Int32] = [5, -5, 70000, -70000, 1, Int32.MAX, Int32.MIN, 0, 123456789, -123456789, -1]
    var b: List[Int64] = [0, 1, -1, 9007199254740992, 9007199254740993, 9007199254740995, Int64.MAX, Int64.MIN, 123, -123, 4611686018427387904]
    var f64: List[Float64] = [0.0, 1.0, -1.0, 9007199254740992.0, 9007199254740992.0, 9007199254740996.0, 9223372036854775808.0, -9223372036854775808.0, 123.0, -123.0, 4611686018427387904.0]
    var n = len(a)
    var i = 0
    while i + W <= n:
        _lanes(GenCast_I64_To_I32.eval[W](_Load[W].i64(a, i)).get_i32[0](), i32, i, "i64->i32")
        _lanes(GenCast_I64_To_F64.eval[W](_Load[W].i64(b, i)).get_f64[0](), f64, i, "i64->f64")
        i += W
    while i < n:
        _same(GenCast_I64_To_I32.eval_row(I64Row(a=a[i])).a, i32[i], "i64->i32 row " + String(i))
        _same(GenCast_I64_To_F64.eval_row(I64Row(a=b[i])).a, f64[i], "i64->f64 row " + String(i))
        i += 1


def _run_cast_from_i32[W: Int]() raises:
    """I32 -> I64 (sign extension) and I32 -> F64 (exact)."""
    var a: List[Int32] = [5, -5, Int32.MAX, Int32.MIN, 0, -1, 1, 100, -100, 65536, -65536]
    var i64: List[Int64] = [5, -5, 2147483647, -2147483648, 0, -1, 1, 100, -100, 65536, -65536]
    var f64: List[Float64] = [5.0, -5.0, 2147483647.0, -2147483648.0, 0.0, -1.0, 1.0, 100.0, -100.0, 65536.0, -65536.0]
    var n = len(a)
    var i = 0
    while i + W <= n:
        var s = _Load[W].i32(a, i)
        _lanes(GenCast_I32_To_I64.eval[W](s).get_i64[0](), i64, i, "i32->i64")
        _lanes(GenCast_I32_To_F64.eval[W](s).get_f64[0](), f64, i, "i32->f64")
        i += W
    while i < n:
        var r = I32Row(a=a[i])
        _same(GenCast_I32_To_I64.eval_row(r).a, i64[i], "i32->i64 row " + String(i))
        _same(GenCast_I32_To_F64.eval_row(r).a, f64[i], "i32->f64 row " + String(i))
        i += 1


# -----------------------------------------------------------------------------
# when / otherwise (ids 45..48): then_v = 10 + row, else_v = -(10 + row)
# -----------------------------------------------------------------------------


def _when_pred() -> List[Bool]:
    return [T, F, T, T, F, F, T, F, T, F, F]


def _when_then[dt: DType]() -> List[Scalar[dt]]:
    var out = List[Scalar[dt]]()
    for i in range(11):
        out.append(Scalar[dt](10 + i))
    return out^


def _when_else[dt: DType]() -> List[Scalar[dt]]:
    var out = List[Scalar[dt]]()
    for i in range(11):
        out.append(Scalar[dt](-10 - i))
    return out^


def _when_want[dt: DType]() -> List[Scalar[dt]]:
    comptime S = Scalar[dt]
    return [S(10), S(-11), S(12), S(13), S(-14), S(-15), S(16), S(-17), S(18), S(-19), S(-20)]


def _run_when[W: Int]() raises:
    var p = _when_pred()
    var n = len(p)
    var i = 0
    while i + W <= n:
        var m = _bvec[W](p, i)
        var sf64 = SimdOf[WhenF64Row, W].zero()
        sf64.set_bool[0](m)
        sf64.set_f64[1](_vec[DType.float64, W](_when_then[DType.float64](), i))
        sf64.set_f64[2](_vec[DType.float64, W](_when_else[DType.float64](), i))
        _lanes(GenWhen_F64.eval[W](sf64).get_f64[0](), _when_want[DType.float64](), i, "when f64")
        var sf32 = SimdOf[WhenF32Row, W].zero()
        sf32.set_bool[0](m)
        sf32.set_f32[1](_vec[DType.float32, W](_when_then[DType.float32](), i))
        sf32.set_f32[2](_vec[DType.float32, W](_when_else[DType.float32](), i))
        _lanes(GenWhen_F32.eval[W](sf32).get_f32[0](), _when_want[DType.float32](), i, "when f32")
        var si64 = SimdOf[WhenI64Row, W].zero()
        si64.set_bool[0](m)
        si64.set_i64[1](_vec[DType.int64, W](_when_then[DType.int64](), i))
        si64.set_i64[2](_vec[DType.int64, W](_when_else[DType.int64](), i))
        _lanes(GenWhen_I64.eval[W](si64).get_i64[0](), _when_want[DType.int64](), i, "when i64")
        var si32 = SimdOf[WhenI32Row, W].zero()
        si32.set_bool[0](m)
        si32.set_i32[1](_vec[DType.int32, W](_when_then[DType.int32](), i))
        si32.set_i32[2](_vec[DType.int32, W](_when_else[DType.int32](), i))
        _lanes(GenWhen_I32.eval[W](si32).get_i32[0](), _when_want[DType.int32](), i, "when i32")
        i += W
    while i < n:
        var t = " row " + String(i)
        var tv = Float64(10 + i)
        var ev = Float64(-10 - i)
        _same(GenWhen_F64.eval_row(WhenF64Row(pred=p[i], then_v=tv, else_v=ev)).a, _when_want[DType.float64]()[i], "when f64" + t)
        _same(GenWhen_F32.eval_row(WhenF32Row(pred=p[i], then_v=Float32(tv), else_v=Float32(ev))).a, _when_want[DType.float32]()[i], "when f32" + t)
        _same(GenWhen_I64.eval_row(WhenI64Row(pred=p[i], then_v=Int64(10 + i), else_v=Int64(-10 - i))).a, _when_want[DType.int64]()[i], "when i64" + t)
        _same(GenWhen_I32.eval_row(WhenI32Row(pred=p[i], then_v=Int32(10 + i), else_v=Int32(-10 - i))).a, _when_want[DType.int32]()[i], "when i32" + t)
        i += 1


# -----------------------------------------------------------------------------
# is_null / is_not_null (ids 49..56): value-blind placeholders, the engine
# reads validity. Every row answers is_null FALSE and is_not_null TRUE,
# whatever its value (NaN included).
#
# Driven at W = 1, 4 and 8, with the rows past the last whole chunk through
# eval_row. Each `eval[W]` body used to splat with `SIMD[DType.bool, W](<Bool>)`,
# which the compiler refuses for every W > 1 ("must be a scalar; use the
# `fill` keyword"), so W = 4 and 8 here did not compile (#937).
# -----------------------------------------------------------------------------


def _run_nulls[W: Int]() raises:
    var nan = Float64(0.0) / Float64(0.0)
    var f: List[Float64] = [0.0, -0.0, nan, 1.0, -1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0]
    var f32 = List[Float32]()
    var i64 = List[Int64]()
    var i32 = List[Int32]()
    for k in range(len(f)):
        f32.append(Float32(f[k]))
        i64.append(Int64(k))
        i32.append(Int32(-k))
    var n = len(f)
    var i = 0
    while i + W <= n:
        var t = " lanes from row " + String(i)
        var s64 = _Load[W].f64(f, i)
        var s32 = _Load[W].f32(f32, i)
        var sl = _Load[W].i64(i64, i)
        var si = _Load[W].i32(i32, i)
        for l in range(W):
            var r = t + " lane " + String(l)
            assert_equal(Bool(GenIsNull_F64.eval[W](s64).get_bool[0]()[l]), F, "is_null f64" + r)
            assert_equal(Bool(GenIsNotNull_F64.eval[W](s64).get_bool[0]()[l]), T, "is_not_null f64" + r)
            assert_equal(Bool(GenIsNull_F32.eval[W](s32).get_bool[0]()[l]), F, "is_null f32" + r)
            assert_equal(Bool(GenIsNotNull_F32.eval[W](s32).get_bool[0]()[l]), T, "is_not_null f32" + r)
            assert_equal(Bool(GenIsNull_I64.eval[W](sl).get_bool[0]()[l]), F, "is_null i64" + r)
            assert_equal(Bool(GenIsNotNull_I64.eval[W](sl).get_bool[0]()[l]), T, "is_not_null i64" + r)
            assert_equal(Bool(GenIsNull_I32.eval[W](si).get_bool[0]()[l]), F, "is_null i32" + r)
            assert_equal(Bool(GenIsNotNull_I32.eval[W](si).get_bool[0]()[l]), T, "is_not_null i32" + r)
        i += W
    while i < n:
        var t = " row " + String(i)
        assert_equal(GenIsNull_F64.eval_row(F64Row(a=f[i])).a, F, "is_null f64" + t)
        assert_equal(GenIsNotNull_F64.eval_row(F64Row(a=f[i])).a, T, "is_not_null f64" + t)
        assert_equal(GenIsNull_F32.eval_row(F32Row(a=f32[i])).a, F, "is_null f32" + t)
        assert_equal(GenIsNotNull_F32.eval_row(F32Row(a=f32[i])).a, T, "is_not_null f32" + t)
        assert_equal(GenIsNull_I64.eval_row(I64Row(a=i64[i])).a, F, "is_null i64" + t)
        assert_equal(GenIsNotNull_I64.eval_row(I64Row(a=i64[i])).a, T, "is_not_null i64" + t)
        assert_equal(GenIsNull_I32.eval_row(I32Row(a=i32[i])).a, F, "is_null i32" + t)
        assert_equal(GenIsNotNull_I32.eval_row(I32Row(a=i32[i])).a, T, "is_not_null i32" + t)
        i += 1


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_cmp_f64_collit() raises:
    """IDs 25..30: IEEE comparisons against a literal, NaN FALSE except <>."""
    _run_cmp_f64[1]()
    _run_cmp_f64[4]()
    _run_cmp_f64[8]()
    _run_cmp_f64[16]()


def test_cmp_i64_collit() raises:
    """IDs 31..36: comparisons against a negative literal, MIN and MAX rows."""
    _run_cmp_i64[1]()
    _run_cmp_i64[4]()
    _run_cmp_i64[8]()
    _run_cmp_i64[16]()


def test_casts_from_float() raises:
    """IDs 37, 41, 38, 44: narrowing, widening, half to even on ties."""
    _run_cast_from_f64[1]()
    _run_cast_from_f64[4]()
    _run_cast_from_f64[8]()
    _run_cast_from_f64[16]()
    _run_cast_from_f32[1]()
    _run_cast_from_f32[4]()
    _run_cast_from_f32[8]()
    _run_cast_from_f32[16]()


def test_casts_from_int() raises:
    """IDs 39, 42, 40, 43: in-range narrowing, ties-to-even to F64, widening."""
    _run_cast_from_i64[1]()
    _run_cast_from_i64[4]()
    _run_cast_from_i64[8]()
    _run_cast_from_i64[16]()
    _run_cast_from_i32[1]()
    _run_cast_from_i32[4]()
    _run_cast_from_i32[8]()
    _run_cast_from_i32[16]()


def test_when() raises:
    """IDs 45..48: each lane takes then_v exactly where its predicate holds.

    W = 1 is left out: a one-lane `m.select(t, e)` lowers to a scalar select
    the branch classifier cannot place (it refuses the whole test). It is a
    lane-wise data select, no source decision; W = 4 and 8 drive the lanes and
    the tails and W = 16 drive `eval_row` on every row."""
    _run_when[4]()
    _run_when[8]()
    _run_when[16]()


def test_is_null_placeholders() raises:
    """IDs 49..56: is_null all FALSE, is_not_null all TRUE, any value, at
    W = 1, 4 and 8."""
    _run_nulls[1]()
    _run_nulls[4]()
    _run_nulls[8]()


def test_template_ids_are_stable() raises:
    """The ids are a wire contract ("never renumber"): 0 for the interpreter,
    then 1..65 in declaration order, and the two phase maxima."""
    _ = InterpretedExprKernel()
    var ids: List[Int] = [
        EXPR_TEMPLATE_INTERPRETED,
        EXPR_TEMPLATE_ADD_F64_COLCOL, EXPR_TEMPLATE_SUB_F64_COLCOL, EXPR_TEMPLATE_MUL_F64_COLCOL, EXPR_TEMPLATE_DIV_F64_COLCOL,
        EXPR_TEMPLATE_ADD_I64_COLCOL, EXPR_TEMPLATE_SUB_I64_COLCOL, EXPR_TEMPLATE_MUL_I64_COLCOL, EXPR_TEMPLATE_DIV_I64_COLCOL,
        EXPR_TEMPLATE_ADD_F32_COLCOL, EXPR_TEMPLATE_SUB_F32_COLCOL, EXPR_TEMPLATE_MUL_F32_COLCOL, EXPR_TEMPLATE_DIV_F32_COLCOL,
        EXPR_TEMPLATE_ADD_I32_COLCOL, EXPR_TEMPLATE_SUB_I32_COLCOL, EXPR_TEMPLATE_MUL_I32_COLCOL, EXPR_TEMPLATE_DIV_I32_COLCOL,
        EXPR_TEMPLATE_ADD_F64_COLLIT, EXPR_TEMPLATE_SUB_F64_COLLIT, EXPR_TEMPLATE_MUL_F64_COLLIT, EXPR_TEMPLATE_DIV_F64_COLLIT,
        EXPR_TEMPLATE_ADD_I64_COLLIT, EXPR_TEMPLATE_SUB_I64_COLLIT, EXPR_TEMPLATE_MUL_I64_COLLIT, EXPR_TEMPLATE_DIV_I64_COLLIT,
        EXPR_TEMPLATE_GT_F64_COLLIT, EXPR_TEMPLATE_GE_F64_COLLIT, EXPR_TEMPLATE_LT_F64_COLLIT,
        EXPR_TEMPLATE_LE_F64_COLLIT, EXPR_TEMPLATE_EQ_F64_COLLIT, EXPR_TEMPLATE_NE_F64_COLLIT,
        EXPR_TEMPLATE_GT_I64_COLLIT, EXPR_TEMPLATE_GE_I64_COLLIT, EXPR_TEMPLATE_LT_I64_COLLIT,
        EXPR_TEMPLATE_LE_I64_COLLIT, EXPR_TEMPLATE_EQ_I64_COLLIT, EXPR_TEMPLATE_NE_I64_COLLIT,
        EXPR_TEMPLATE_CAST_F64_TO_F32, EXPR_TEMPLATE_CAST_F32_TO_F64, EXPR_TEMPLATE_CAST_I64_TO_I32, EXPR_TEMPLATE_CAST_I32_TO_I64,
        EXPR_TEMPLATE_CAST_F64_TO_I64, EXPR_TEMPLATE_CAST_I64_TO_F64, EXPR_TEMPLATE_CAST_I32_TO_F64, EXPR_TEMPLATE_CAST_F32_TO_I64,
        EXPR_TEMPLATE_WHEN_F64, EXPR_TEMPLATE_WHEN_F32, EXPR_TEMPLATE_WHEN_I64, EXPR_TEMPLATE_WHEN_I32,
        EXPR_TEMPLATE_IS_NULL_F64, EXPR_TEMPLATE_IS_NOT_NULL_F64, EXPR_TEMPLATE_IS_NULL_F32, EXPR_TEMPLATE_IS_NOT_NULL_F32,
        EXPR_TEMPLATE_IS_NULL_I64, EXPR_TEMPLATE_IS_NOT_NULL_I64, EXPR_TEMPLATE_IS_NULL_I32, EXPR_TEMPLATE_IS_NOT_NULL_I32,
        EXPR_TEMPLATE_AND_BOOL, EXPR_TEMPLATE_OR_BOOL, EXPR_TEMPLATE_NOT_BOOL,
        EXPR_TEMPLATE_NEGATE_F64, EXPR_TEMPLATE_NEGATE_F32, EXPR_TEMPLATE_NEGATE_I64, EXPR_TEMPLATE_NEGATE_I32,
        EXPR_TEMPLATE_MOD_I64_COLCOL, EXPR_TEMPLATE_MOD_I32_COLCOL,
    ]
    assert_equal(len(ids), 66)
    for i in range(len(ids)):
        assert_equal(ids[i], i, "template id at position " + String(i))
    assert_equal(EXPR_TEMPLATE_MAX_ID_PHASE_3A, EXPR_TEMPLATE_NE_I64_COLLIT)
    assert_equal(EXPR_TEMPLATE_MAX_ID_PHASE_3B, EXPR_TEMPLATE_MOD_I32_COLCOL)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
