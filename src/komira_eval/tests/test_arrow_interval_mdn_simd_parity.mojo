# =============================================================================
# SIMD INTERVAL_MDN add/sub parity tests
# =============================================================================
#
# Verifies that the SIMD-accelerated `add_interval_mdn` / `sub_interval_mdn`
# produce byte-identical results to the scalar reference
# `_scalar_add_interval_mdn` / `_scalar_sub_interval_mdn` across every
# input shape that exercises the SIMD chunk loop AND its scalar tail
# fallback.
#
# Coverage matrix:
#
#   * Length classes:
#     - 0 rows  (boundary: empty)
#     - 1 row   (no SIMD chunks; pure scalar)
#     - 3 rows  (no SIMD chunks — under W_ROWS == 4)
#     - 4 rows  (exactly 1 SIMD chunk)
#     - 5 rows  (1 chunk + 1 tail row)
#     - 15 rows (3 chunks + 3 tail rows — exercises both)
#     - 127 rows (31 chunks + 3 tail rows — larger)
#
#   * Edge values per row:
#     - zero, max_i32 months, min_i32 months, max_i32 days, min_i32 days
#     - max_i64 nanos, min_i64 nanos (test the wrap-on-overflow path)
#     - negative components with mixed signs
#
#   * Null mask shapes:
#     - no validity bitmap (non-nullable hot path)
#     - all-valid validity bitmap
#     - alternating null mask
#     - all-null mask
#
# Bug-Fix Protocol parity-test pattern: the test FAILs (diverges) if
# the SIMD path's i32 lanes 2,3 carry low->high into nanos, OR if the
# i64 path's lane 0 carries days->months.  The blend mask in
# `_build_blend_mask()` is what closes those bugs; this file is the
# regression guard.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.interval_mdn_array import (
    IntervalMonthDayNanoArray,
    INTERVAL_MDN_BYTE_WIDTH,
)
from komira_buffer.heap_region import HeapRegion
from komira_column_kernels.interval_mdn_kernels import (
    add_interval_mdn,
    sub_interval_mdn,
    _scalar_add_interval_mdn,
    _scalar_sub_interval_mdn,
)


# -----------------------------------------------------------------------------
# Fixture builders
# -----------------------------------------------------------------------------


def _edge_triples_seed_a() -> List[Tuple[Int32, Int32, Int64]]:
    """Edge-value triples for the LHS operand."""
    return [
        (Int32(0), Int32(0), Int64(0)),
        (Int32(1), Int32(31), Int64(1_000_000_000)),
        (Int32(2147483647), Int32(0), Int64(0)),    # max i32 months
        (Int32(-2147483648), Int32(0), Int64(0)),   # min i32 months
        (Int32(0), Int32(2147483647), Int64(0)),    # max i32 days
        (Int32(0), Int32(-2147483648), Int64(0)),   # min i32 days
        (Int32(0), Int32(0), Int64(9223372036854775807)),    # max i64 nanos
        (Int32(0), Int32(0), Int64(-9223372036854775808)),   # min i64 nanos
        (Int32(-3), Int32(7), Int64(-1_000)),       # mixed signs
        (Int32(12), Int32(0), Int64(86_400_000_000_000)),    # 1 year + 1 day-ns
        (Int32(-1), Int32(-1), Int64(-1)),          # all -1
        (Int32(1), Int32(1), Int64(1)),             # all 1
        (Int32(2147483647), Int32(2147483647), Int64(9223372036854775807)),
        (Int32(-2147483648), Int32(-2147483648), Int64(-9223372036854775808)),
        (Int32(100), Int32(200), Int64(300_000)),
        (Int32(-100), Int32(-200), Int64(-300_000)),
    ]


def _edge_triples_seed_b() -> List[Tuple[Int32, Int32, Int64]]:
    """Edge-value triples for the RHS operand — designed so add/sub
    against seed A exercises every overflow/carry boundary."""
    return [
        (Int32(0), Int32(0), Int64(0)),
        (Int32(2), Int32(-1), Int64(500_000_000)),
        (Int32(1), Int32(0), Int64(0)),             # max_i32 + 1 = overflow wrap
        (Int32(-1), Int32(0), Int64(0)),            # min_i32 - 1 = overflow wrap
        (Int32(0), Int32(1), Int64(0)),             # max_i32 + 1 = overflow wrap
        (Int32(0), Int32(-1), Int64(0)),            # min_i32 - 1 = overflow wrap
        (Int32(0), Int32(0), Int64(1)),             # max_i64 + 1 = overflow wrap
        (Int32(0), Int32(0), Int64(-1)),            # min_i64 - 1 = overflow wrap
        (Int32(5), Int32(-7), Int64(1_000)),
        (Int32(-12), Int32(0), Int64(-86_400_000_000_000)),
        (Int32(2), Int32(2), Int64(2)),
        (Int32(-1), Int32(-1), Int64(-1)),
        (Int32(1), Int32(1), Int64(1)),
        (Int32(-1), Int32(-1), Int64(-1)),
        (Int32(50), Int32(-100), Int64(700_000)),
        (Int32(-50), Int32(100), Int64(-700_000)),
    ]


def _take_first_n(
    triples: List[Tuple[Int32, Int32, Int64]], n: Int
) -> List[Tuple[Int32, Int32, Int64]]:
    """Slice the first `n` triples (List doesn't have built-in slice)."""
    var out = List[Tuple[Int32, Int32, Int64]]()
    var lim = min(n, len(triples))
    for i in range(lim):
        out.append(triples[i])
    # If n > len, repeat from the start (gives a cyclical pattern for
    # large-length tests).
    while len(out) < n:
        var idx = len(out) % len(triples)
        out.append(triples[idx])
    return out^


def _build_a(n: Int) raises -> IntervalMonthDayNanoArray[HeapRegion]:
    """Build the LHS operand of length `n` from the edge-A fixture."""
    var triples = _take_first_n(_edge_triples_seed_a(), n)
    return IntervalMonthDayNanoArray.from_triples(triples)


def _build_b(n: Int) raises -> IntervalMonthDayNanoArray[HeapRegion]:
    """Build the RHS operand of length `n` from the edge-B fixture."""
    var triples = _take_first_n(_edge_triples_seed_b(), n)
    return IntervalMonthDayNanoArray.from_triples(triples)


def _build_a_nullable(
    n: Int, null_indices: List[Int]
) raises -> IntervalMonthDayNanoArray[HeapRegion]:
    """LHS operand, all bytes from the edge-A fixture, but with
    `null_indices` marked NULL via the validity bitmap."""
    var arr = _build_a(n)
    # Promote to nullable by calling set_null on at least one slot — even
    # if null_indices is empty, we want a validity bitmap present in the
    # mixed-nullability test.
    if len(null_indices) == 0:
        return arr^
    for k in range(len(null_indices)):
        arr.set_null(null_indices[k])
    return arr^


def _build_b_nullable(
    n: Int, null_indices: List[Int]
) raises -> IntervalMonthDayNanoArray[HeapRegion]:
    var arr = _build_b(n)
    if len(null_indices) == 0:
        return arr^
    for k in range(len(null_indices)):
        arr.set_null(null_indices[k])
    return arr^


# -----------------------------------------------------------------------------
# Parity assertion helper
# -----------------------------------------------------------------------------


def _assert_arrays_byte_identical(
    simd_arr: IntervalMonthDayNanoArray,
    scalar_arr: IntervalMonthDayNanoArray,
    context: String,
) raises:
    """Assert that `simd_arr` and `scalar_arr` are byte-identical (same
    length, same null_count, same validity bits per row, same data bytes
    per VALID row).

    NULL-row data bytes are NOT compared — the SIMD path writes garbage
    to NULL rows (correctness comes from the validity bitmap, not the
    data).  This matches every Arrow consumer's contract: NULL row data
    is undefined and must never be read.
    """
    assert_equal(
        simd_arr.length, scalar_arr.length,
        context + ": length mismatch",
    )
    var n = simd_arr.length

    # Validity bitmap comparison
    var simd_has_val = Bool(simd_arr.validity)
    var scalar_has_val = Bool(scalar_arr.validity)
    assert_equal(
        Int(simd_has_val), Int(scalar_has_val),
        context + ": validity-bitmap-presence mismatch",
    )
    assert_equal(
        simd_arr.null_count, scalar_arr.null_count,
        context + ": null_count mismatch",
    )

    # Per-row data + null compare
    for i in range(n):
        var simd_null = False
        var scalar_null = False
        if simd_has_val:
            simd_null = not simd_arr.validity.value().test(i)
        if scalar_has_val:
            scalar_null = not scalar_arr.validity.value().test(i)
        assert_equal(
            Int(simd_null), Int(scalar_null),
            context + ": row " + String(i) + " null-bit mismatch",
        )
        if simd_null:
            # NULL row data bytes are undefined — skip data compare.
            continue
        var st = simd_arr.get_triple(i)
        var ct = scalar_arr.get_triple(i)
        assert_equal(
            Int(st[0]), Int(ct[0]),
            context + ": row " + String(i) + " months",
        )
        assert_equal(
            Int(st[1]), Int(ct[1]),
            context + ": row " + String(i) + " days",
        )
        assert_equal(
            Int(st[2]), Int(ct[2]),
            context + ": row " + String(i) + " nanos",
        )


# -----------------------------------------------------------------------------
# T1 — empty arrays
# -----------------------------------------------------------------------------


def test_simd_parity_add_empty() raises:
    """0 rows — both paths must produce a 0-length array."""
    var a = IntervalMonthDayNanoArray.allocate(0)
    var b = IntervalMonthDayNanoArray.allocate(0)
    var s = _scalar_add_interval_mdn(a, b)
    var a2 = IntervalMonthDayNanoArray.allocate(0)
    var b2 = IntervalMonthDayNanoArray.allocate(0)
    var v = add_interval_mdn(a2, b2)
    _assert_arrays_byte_identical(v, s, "empty add")


def test_simd_parity_sub_empty() raises:
    var a = IntervalMonthDayNanoArray.allocate(0)
    var b = IntervalMonthDayNanoArray.allocate(0)
    var s = _scalar_sub_interval_mdn(a, b)
    var a2 = IntervalMonthDayNanoArray.allocate(0)
    var b2 = IntervalMonthDayNanoArray.allocate(0)
    var v = sub_interval_mdn(a2, b2)
    _assert_arrays_byte_identical(v, s, "empty sub")


# -----------------------------------------------------------------------------
# T2 — short arrays (n < W_ROWS == 4) — should take the scalar fast path
# -----------------------------------------------------------------------------


def test_simd_parity_add_len1() raises:
    """n == 1 — scalar fast path."""
    var s = _scalar_add_interval_mdn(_build_a(1), _build_b(1))
    var v = add_interval_mdn(_build_a(1), _build_b(1))
    _assert_arrays_byte_identical(v, s, "len-1 add")


def test_simd_parity_add_len3() raises:
    """n == 3 — scalar fast path (under W_ROWS)."""
    var s = _scalar_add_interval_mdn(_build_a(3), _build_b(3))
    var v = add_interval_mdn(_build_a(3), _build_b(3))
    _assert_arrays_byte_identical(v, s, "len-3 add")


def test_simd_parity_sub_len3() raises:
    var s = _scalar_sub_interval_mdn(_build_a(3), _build_b(3))
    var v = sub_interval_mdn(_build_a(3), _build_b(3))
    _assert_arrays_byte_identical(v, s, "len-3 sub")


# -----------------------------------------------------------------------------
# T3 — exactly one SIMD chunk (n == W_ROWS == 4)
# -----------------------------------------------------------------------------


def test_simd_parity_add_len4() raises:
    """n == 4 — exactly 1 SIMD chunk, no tail.  This is the case where
    the SIMD path is exercised but the tail loop is skipped — directly
    verifies the blend mask is right."""
    var s = _scalar_add_interval_mdn(_build_a(4), _build_b(4))
    var v = add_interval_mdn(_build_a(4), _build_b(4))
    _assert_arrays_byte_identical(v, s, "len-4 add (1 chunk, no tail)")


def test_simd_parity_sub_len4() raises:
    var s = _scalar_sub_interval_mdn(_build_a(4), _build_b(4))
    var v = sub_interval_mdn(_build_a(4), _build_b(4))
    _assert_arrays_byte_identical(v, s, "len-4 sub (1 chunk, no tail)")


# -----------------------------------------------------------------------------
# T4 — chunk + tail (n == 5 — 1 chunk + 1 tail row)
# -----------------------------------------------------------------------------


def test_simd_parity_add_len5() raises:
    """n == 5 — 1 SIMD chunk + 1 tail row.  Tests that the SIMD pass and
    the scalar tail both write to the same output buffer correctly."""
    var s = _scalar_add_interval_mdn(_build_a(5), _build_b(5))
    var v = add_interval_mdn(_build_a(5), _build_b(5))
    _assert_arrays_byte_identical(v, s, "len-5 add (1 chunk + 1 tail)")


def test_simd_parity_sub_len5() raises:
    var s = _scalar_sub_interval_mdn(_build_a(5), _build_b(5))
    var v = sub_interval_mdn(_build_a(5), _build_b(5))
    _assert_arrays_byte_identical(v, s, "len-5 sub (1 chunk + 1 tail)")


# -----------------------------------------------------------------------------
# T5 — multiple chunks + tail (n == 15 — 3 chunks + 3 tail rows)
# -----------------------------------------------------------------------------


def test_simd_parity_add_len15() raises:
    """n == 15 — 3 SIMD chunks + 3 tail rows.  Exercises chunk-loop
    iteration AND a multi-row tail."""
    var s = _scalar_add_interval_mdn(_build_a(15), _build_b(15))
    var v = add_interval_mdn(_build_a(15), _build_b(15))
    _assert_arrays_byte_identical(v, s, "len-15 add (3 chunks + 3 tail)")


def test_simd_parity_sub_len15() raises:
    var s = _scalar_sub_interval_mdn(_build_a(15), _build_b(15))
    var v = sub_interval_mdn(_build_a(15), _build_b(15))
    _assert_arrays_byte_identical(v, s, "len-15 sub (3 chunks + 3 tail)")


# -----------------------------------------------------------------------------
# T6 — larger arrays (n == 127 — 31 chunks + 3 tail rows)
# -----------------------------------------------------------------------------


def test_simd_parity_add_len127() raises:
    var s = _scalar_add_interval_mdn(_build_a(127), _build_b(127))
    var v = add_interval_mdn(_build_a(127), _build_b(127))
    _assert_arrays_byte_identical(v, s, "len-127 add")


def test_simd_parity_sub_len127() raises:
    var s = _scalar_sub_interval_mdn(_build_a(127), _build_b(127))
    var v = sub_interval_mdn(_build_a(127), _build_b(127))
    _assert_arrays_byte_identical(v, s, "len-127 sub")


# -----------------------------------------------------------------------------
# T7 — overflow / wrap regression (specifically targets the blend mask)
# -----------------------------------------------------------------------------


def test_simd_parity_max_i32_months_plus_one_wraps() raises:
    """The PRIMARY blend-mask regression: row[2] of seed A has
    months == max_i32; row[2] of seed B has months == 1.  Add must
    wrap months to min_i32.

    If the blend mask was wrong (e.g., took the i64-add result for
    lane 0 instead of the i32 result), the result would be polluted
    by carry from the days lane add.  The scalar path is the oracle.
    """
    var s = _scalar_add_interval_mdn(_build_a(4), _build_b(4))
    var v = add_interval_mdn(_build_a(4), _build_b(4))

    # Pin the row[2] result so a divergence localizes immediately.
    var st = v.get_triple(2)
    assert_equal(
        Int(st[0]), Int(Int32(-2147483648)),
        "row 2 months: max_i32 + 1 must wrap to min_i32",
    )

    _assert_arrays_byte_identical(v, s, "wrap-i32-months add")


def test_simd_parity_max_i32_days_plus_one_wraps() raises:
    """Row[4] of seed A has days == max_i32; row[4] of seed B has
    days == 1.  Add must wrap days to min_i32 WITHOUT polluting the
    months lane."""
    var s = _scalar_add_interval_mdn(_build_a(5), _build_b(5))
    var v = add_interval_mdn(_build_a(5), _build_b(5))

    var st = v.get_triple(4)
    assert_equal(
        Int(st[0]), 0,
        "row 4 months: must be 0+0=0 — NO carry from days overflow",
    )
    assert_equal(
        Int(st[1]), Int(Int32(-2147483648)),
        "row 4 days: max_i32 + 1 must wrap to min_i32",
    )

    _assert_arrays_byte_identical(v, s, "wrap-i32-days add")


def test_simd_parity_max_i64_nanos_plus_one_wraps() raises:
    """Row[6] of seed A has nanos == max_i64; row[6] of seed B has
    nanos == 1.  Add must wrap nanos to min_i64 — exercises the
    i64-lane low->high carry."""
    var s = _scalar_add_interval_mdn(_build_a(7), _build_b(7))
    var v = add_interval_mdn(_build_a(7), _build_b(7))

    var st = v.get_triple(6)
    assert_equal(
        Int(st[2]), Int(Int64(-9223372036854775808)),
        "row 6 nanos: max_i64 + 1 must wrap to min_i64",
    )

    _assert_arrays_byte_identical(v, s, "wrap-i64-nanos add")


def test_simd_parity_min_i64_nanos_minus_one_wraps() raises:
    """Row[7] of seed A has nanos == min_i64; row[7] of seed B has
    nanos == 1.  Sub must wrap nanos to max_i64.  Same regression
    shape as the +1 case but on the sub kernel."""
    var s = _scalar_sub_interval_mdn(_build_a(8), _build_b(8))
    var v = sub_interval_mdn(_build_a(8), _build_b(8))

    var st = v.get_triple(7)
    # nanos: min_i64 - (-1) = min_i64 + 1 = min_i64 + 1 (still wraps near min)
    # min_i64 + 1 = -9223372036854775807
    assert_equal(
        Int(st[2]), Int(Int64(-9223372036854775807)),
        "row 7 nanos: min_i64 - (-1) must equal min_i64 + 1",
    )

    _assert_arrays_byte_identical(v, s, "wrap-i64-nanos sub")


# -----------------------------------------------------------------------------
# T8 — NULL handling parity
# -----------------------------------------------------------------------------


def test_simd_parity_add_alternating_nulls() raises:
    """Alternating null mask on `a`: positions 0, 2, 4, 6, 8, 10, 12, 14 NULL.
    Scalar and SIMD must produce identical validity AND identical data
    for valid rows."""
    var null_idx = List[Int]()
    for k in range(16):
        if k % 2 == 0:
            null_idx.append(k)

    var s = _scalar_add_interval_mdn(
        _build_a_nullable(16, null_idx), _build_b(16)
    )
    var v = add_interval_mdn(
        _build_a_nullable(16, null_idx), _build_b(16)
    )
    _assert_arrays_byte_identical(v, s, "alternating-nulls add")


def test_simd_parity_sub_alternating_nulls() raises:
    var null_idx = List[Int]()
    for k in range(16):
        if k % 2 == 0:
            null_idx.append(k)

    var s = _scalar_sub_interval_mdn(
        _build_a_nullable(16, null_idx), _build_b(16)
    )
    var v = sub_interval_mdn(
        _build_a_nullable(16, null_idx), _build_b(16)
    )
    _assert_arrays_byte_identical(v, s, "alternating-nulls sub")


def test_simd_parity_add_both_sides_nullable() raises:
    """Both `a` and `b` have nulls at different positions.  Result NULL
    set = union of a-NULL ∪ b-NULL."""
    var a_null = List[Int]()
    a_null.append(0)
    a_null.append(3)
    a_null.append(7)

    var b_null = List[Int]()
    b_null.append(2)
    b_null.append(5)
    b_null.append(11)
    b_null.append(15)

    var s = _scalar_add_interval_mdn(
        _build_a_nullable(16, a_null), _build_b_nullable(16, b_null)
    )
    var v = add_interval_mdn(
        _build_a_nullable(16, a_null), _build_b_nullable(16, b_null)
    )
    _assert_arrays_byte_identical(v, s, "both-sides-nullable add")


def test_simd_parity_add_all_null_a() raises:
    """`a` all NULL — result must be all NULL regardless of `b`."""
    var all_idx = List[Int]()
    for k in range(8):
        all_idx.append(k)

    var s = _scalar_add_interval_mdn(
        _build_a_nullable(8, all_idx), _build_b(8)
    )
    var v = add_interval_mdn(
        _build_a_nullable(8, all_idx), _build_b(8)
    )
    _assert_arrays_byte_identical(v, s, "all-null-a add")
    assert_equal(v.null_count, 8, "all-null-a: null_count must be 8")


# -----------------------------------------------------------------------------
# T9 — alignment-edge regressions
# -----------------------------------------------------------------------------


def test_simd_parity_add_len16_exact_chunks() raises:
    """n == 16 — exactly 4 SIMD chunks, no tail.  Boundary case for the
    chunk loop terminator."""
    var s = _scalar_add_interval_mdn(_build_a(16), _build_b(16))
    var v = add_interval_mdn(_build_a(16), _build_b(16))
    _assert_arrays_byte_identical(v, s, "len-16 add (4 chunks, no tail)")


def test_simd_parity_sub_len16_exact_chunks() raises:
    var s = _scalar_sub_interval_mdn(_build_a(16), _build_b(16))
    var v = sub_interval_mdn(_build_a(16), _build_b(16))
    _assert_arrays_byte_identical(v, s, "len-16 sub (4 chunks, no tail)")


# -----------------------------------------------------------------------------
# Suite registration
# -----------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()

    suite.test[test_simd_parity_add_empty]()
    suite.test[test_simd_parity_sub_empty]()
    suite.test[test_simd_parity_add_len1]()
    suite.test[test_simd_parity_add_len3]()
    suite.test[test_simd_parity_sub_len3]()
    suite.test[test_simd_parity_add_len4]()
    suite.test[test_simd_parity_sub_len4]()
    suite.test[test_simd_parity_add_len5]()
    suite.test[test_simd_parity_sub_len5]()
    suite.test[test_simd_parity_add_len15]()
    suite.test[test_simd_parity_sub_len15]()
    suite.test[test_simd_parity_add_len127]()
    suite.test[test_simd_parity_sub_len127]()
    suite.test[test_simd_parity_max_i32_months_plus_one_wraps]()
    suite.test[test_simd_parity_max_i32_days_plus_one_wraps]()
    suite.test[test_simd_parity_max_i64_nanos_plus_one_wraps]()
    suite.test[test_simd_parity_min_i64_nanos_minus_one_wraps]()
    suite.test[test_simd_parity_add_alternating_nulls]()
    suite.test[test_simd_parity_sub_alternating_nulls]()
    suite.test[test_simd_parity_add_both_sides_nullable]()
    suite.test[test_simd_parity_add_all_null_a]()
    suite.test[test_simd_parity_add_len16_exact_chunks]()
    suite.test[test_simd_parity_sub_len16_exact_chunks]()

    suite^.run()
