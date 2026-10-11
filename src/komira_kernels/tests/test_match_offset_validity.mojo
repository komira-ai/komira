# =============================================================================
# builtin_match_fns: the validity of a SLICED input, IS NOT NULL padding
# bits, and float `<>` on a NaN row.
#
# A sliced `PrimitiveArray` keeps its validity bitmap indexed ABSOLUTELY:
# logical row i is bit `offset + i`. The match cells load values through the
# offset-aware `load`, so a validity read without the offset pairs row i's
# value with row (i - offset)'s null bit (komira issue 950, items 2 and 3).
# Every expected bit below follows from a relation chosen by hand (every
# value is below the other side, or every row of a window is null), never
# from the operator under test.
#
# Length 20 drives both halves of every kernel at every SIMD width the farm
# builds for: whole bytes / whole SIMD chunks over rows 0..15 and the scalar
# tail over rows 16..19.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.bitmap import Bitmap
from komira_arrow.primitive_array import PrimitiveArray
from komira_kernels.builtin_match_fns import (
    LtI64_LV,
    LtI64_RV,
    LtI64_LRV,
    NeF64,
    IsNullI64,
    IsNotNullI64,
    IsNullF64,
    IsNotNullF64,
)


comptime N = 20


def _nullable[dt: DType](
    values: List[Scalar[dt]], nulls: List[Int]
) raises -> PrimitiveArray[dt]:
    var n = len(values)
    var arr = PrimitiveArray[dt].allocate_nullable(n)
    for i in range(n):
        arr.set(i, values[i])
    for j in range(len(nulls)):
        arr._set_null(nulls[j])
    arr.null_count = len(nulls)
    return arr^


def _i64_slice(value: Int64, null_abs: List[Int], offset: Int) raises -> PrimitiveArray[DType.int64]:
    """A length-N window at `offset` of a parent whose every row is `value`
    and whose null rows are `null_abs` (ABSOLUTE parent rows)."""
    var v = List[Int64]()
    for _ in range(offset + N):
        v.append(value)
    return _nullable[DType.int64](v, null_abs).slice(offset, N)


def _has(xs: List[Int], x: Int) -> Bool:
    for k in range(len(xs)):
        if xs[k] == x:
            return True
    return False


def _assert_mask(
    got: Bitmap, count: Int, length: Int, cleared: List[Int], what: String
) raises:
    """Bits 0..length-1 are set except `cleared`; the count is the popcount
    of those bits; the padding bits of the last byte are zero."""
    for i in range(length):
        assert_equal(got.test(i), not _has(cleared, i), what + " row " + String(i))
    assert_equal(count, length - len(cleared), what + " count")
    var pad_end = ((length + 7) // 8) * 8
    for i in range(length, pad_end):
        assert_false(got.test(i), what + " padding bit " + String(i))


def test_lt_lv_reads_the_lhs_window_validity() raises:
    """LHS = 1 everywhere, RHS = 2: every non-null row matches. LHS nulls at
    absolute rows 0, 4, 13, 19 of a window at offset 1 are logical rows 3,
    12, 18 (row 18 is in the scalar tail). An offset-blind read clears
    logical rows 0, 4, 13, 19 instead."""
    var lhs = _i64_slice(1, [0, 4, 13, 19], 1)
    var rhs = _i64_slice(2, List[Int](), 0)
    var out = Bitmap.create(N)
    var c = LtI64_LV().eval_chunk(lhs, rhs, out)
    _assert_mask(out, c, N, [3, 12, 18], "LtI64_LV offset 1")


def test_lt_rv_reads_the_rhs_window_validity() raises:
    """RHS window at offset 3, nulls at absolute rows 2 (before the window),
    5 and 22 -> logical 2 and 19 (row 19 is in the scalar tail)."""
    var lhs = _i64_slice(1, List[Int](), 0)
    var rhs = _i64_slice(2, [2, 5, 22], 3)
    var out = Bitmap.create(N)
    var c = LtI64_RV().eval_chunk(lhs, rhs, out)
    _assert_mask(out, c, N, [2, 19], "LtI64_RV offset 3")


def test_lt_lrv_reads_each_side_at_its_own_offset() raises:
    """LHS at offset 1 (null logical 3, 17), RHS at offset 6 (null logical 0,
    9, 18): the result clears the union. RHS row 18 is in the scalar tail,
    so a tail that reads the RHS bit at the LHS offset (absolute 19, valid)
    leaves it set."""
    var lhs = _i64_slice(1, [4, 18], 1)
    var rhs = _i64_slice(2, [6, 15, 24], 6)
    var out = Bitmap.create(N)
    var c = LtI64_LRV().eval_chunk(lhs, rhs, out)
    _assert_mask(out, c, N, [0, 3, 9, 17, 18], "LtI64_LRV offsets 1/6")


def test_is_null_reads_the_window_validity() raises:
    """The issue's shape: the parent's only null is row 0, so IS NULL over
    slice(1, 8) matches nothing and IS NOT NULL matches all 8."""
    var s = _i64_slice(7, [0], 1)
    var w = s.slice(0, 8)
    var out = Bitmap.create(8)
    assert_equal(IsNullI64().eval_chunk(w, out), 0, "IsNull slice(1,8)")
    var out2 = Bitmap.create(8)
    var c = IsNotNullI64().eval_chunk(w, out2)
    _assert_mask(out2, c, 8, List[Int](), "IsNotNull slice(1,8)")


def test_is_null_and_is_not_null_at_unaligned_and_aligned_offsets() raises:
    """A window at offset 3 over nulls at absolute rows 0, 5, 9, 22 sees
    logical 2, 6, 19; one at offset 8 (byte-aligned) over nulls at 0, 5, 9,
    22, 26 sees 1, 14, 18. Rows 0 and 5 sit before both windows."""
    for which in range(2):
        var offset = 3
        var nulls_abs: List[Int] = [0, 5, 9, 22]
        var want: List[Int] = [2, 6, 19]
        if which == 1:
            offset = 8
            nulls_abs = [0, 5, 9, 22, 26]
            want = [1, 14, 18]
        var what = " offset " + String(offset)
        var v = List[Float64]()
        for i in range(offset + N):
            v.append(Float64(i))
        var s = _nullable[DType.float64](v, nulls_abs).slice(offset, N)
        var valid = Bitmap.create(N)
        var cv = IsNotNullF64().eval_chunk(s, valid)
        _assert_mask(valid, cv, N, want, "IsNotNullF64" + what)
        var nulls = Bitmap.create(N)
        var cn = IsNullF64().eval_chunk(s, nulls)
        assert_equal(cn, len(want), "IsNullF64 count" + what)
        for i in range(N):
            assert_equal(nulls.test(i), _has(want, i), "IsNullF64" + what + " row " + String(i))
        for i in range(N, 24):
            assert_false(nulls.test(i), "IsNullF64 padding bit " + String(i) + what)


def test_is_not_null_does_not_count_padding_bits() raises:
    """Length 5 with padding bit 6 of the input bitmap SET (Arrow does not
    require padding to be zero): the count is 5, the bits written."""
    var a = PrimitiveArray[DType.int64].allocate_nullable(5)
    a.validity.value().set(6)
    var out = Bitmap.create(5)
    var c = IsNotNullI64().eval_chunk(a, out)
    _assert_mask(out, c, 5, List[Int](), "IsNotNull padding")


def test_ne_f64_nan_row_is_true_in_the_simd_body_and_the_tail() raises:
    """`<>` follows IEEE: a NaN row is TRUE (NaN <> 1 and NaN <> NaN). Rows 0
    and 9 sit in whole SIMD chunks, row 18 in the scalar tail; all three must
    agree. Every other row is 1 <> 1, FALSE."""
    var nan = Float64(0.0) / Float64(0.0)
    var l = List[Float64]()
    var r = List[Float64]()
    for i in range(N):
        l.append(nan if (i == 0 or i == 9 or i == 18) else 1.0)
        r.append(nan if i == 9 else 1.0)
    var lhs = PrimitiveArray[DType.float64].from_list(l)
    var rhs = PrimitiveArray[DType.float64].from_list(r)
    var out = Bitmap.create(N)
    var c = NeF64().eval_chunk(lhs, rhs, out)
    var want: List[Int] = [0, 9, 18]
    for i in range(N):
        assert_equal(out.test(i), _has(want, i), "NeF64 row " + String(i))
    assert_equal(c, 3, "NeF64 count")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
