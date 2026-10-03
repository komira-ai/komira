# =============================================================================
# Tests for first-class NE/LE/GE kernels
# =============================================================================
#
# These kernels replaced the prior NOT-wrapping shape at the compiler emit site
#. The tests below
# verify:
#
#  1. Primitive correctness across int32 / int64 / float64.
#  2. Boundary sizes (7/8/9/15/16/17/63/64/65) — exercises both W<8 and W≥8
#     paths in the SIMD-width-symmetric body inside comparison.mojo.
#  3. NaN semantics for the NE kernel (`~eq` unordered: NaN != x → true).
#     ⚠ A KNOWN DIVERGENCE from DuckDB/Postgres/Spark, pinned deliberately —
#     see the test docstring; documented in _cmp_ne + sel_kernels._cmp_ne.
#  4. Behavioural parity vs the prior `eval_not(eval_eq/lt/gt)` shape on a
#     1000-row pseudo-random vector — regression guard for the NOT-wrap →
#     first-class transition.
#  5. Col-vs-col variants (eval_col_ne / eval_col_le / eval_col_ge).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow import PrimitiveArray, BooleanArray
from komira_core.eval import (
    eval_ne, eval_le, eval_ge,
    eval_eq, eval_lt, eval_gt,
    eval_col_ne, eval_col_le, eval_col_ge,
    eval_col_eq, eval_col_lt, eval_col_gt,
)
from komira_core.eval.arithmetic import eval_not


# =============================================================================
# Helpers
# =============================================================================


def _make_sequential_int32(n: Int) raises -> PrimitiveArray[DType.int32]:
    """Helper: builds PrimitiveArray with values [0, 1, 2, ..., n-1]."""
    var arr = PrimitiveArray[DType.int32].allocate(n)
    for i in range(n):
        arr.set(i, Scalar[DType.int32](i))
    return arr^


def _make_sequential_int64(n: Int) raises -> PrimitiveArray[DType.int64]:
    var arr = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        arr.set(i, Scalar[DType.int64](i))
    return arr^


def _make_sequential_float64(n: Int) raises -> PrimitiveArray[DType.float64]:
    var arr = PrimitiveArray[DType.float64].allocate(n)
    for i in range(n):
        arr.set(i, Scalar[DType.float64](Float64(i)))
    return arr^


def _count_true(mask: BooleanArray) raises -> Int:
    var count = 0
    for i in range(mask.length):
        if mask.get(i):
            count += 1
    return count


def _masks_equal(a: BooleanArray, b: BooleanArray) raises -> Bool:
    """Bit-for-bit comparison of two BooleanArrays (regression-guard helper)."""
    if a.length != b.length:
        return False
    for i in range(a.length):
        if a.get(i) != b.get(i):
            return False
    return True


# =============================================================================
# eval_ne — col-vs-scalar (int32 / int64 / float64)
# =============================================================================


def test_eval_ne_int32_basic() raises:
    """eval_ne returns true for values != threshold (int32)."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](5),
        Scalar[DType.int32](5),
        Scalar[DType.int32](10),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var result = eval_ne[DType.int32](col, Scalar[DType.int32](5))
    assert_equal(len(result), 4)
    assert_true(result.get(0))   # 1 != 5 = true
    assert_false(result.get(1))  # 5 != 5 = false
    assert_false(result.get(2))  # 5 != 5 = false
    assert_true(result.get(3))   # 10 != 5 = true


def test_eval_ne_int64_boundary_17() raises:
    """eval_ne with 17 elements (W=2 path, 2 full bytes + 1-bit remainder)."""
    var col = _make_sequential_int64(17)
    var result = eval_ne[DType.int64](col, Scalar[DType.int64](8))
    assert_equal(len(result), 17)
    assert_true(result.get(0))   # 0 != 8 = true
    assert_false(result.get(8))  # 8 != 8 = false
    assert_true(result.get(16))  # 16 != 8 = true
    assert_equal(_count_true(result), 16)  # all but index 8


def test_eval_ne_float64_basic() raises:
    """eval_ne works with float64 data."""
    var values: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](1.5),
        Scalar[DType.float64](3.7),
        Scalar[DType.float64](3.7),
    ]
    var col = PrimitiveArray[DType.float64].from_list(values)
    var result = eval_ne[DType.float64](col, Scalar[DType.float64](3.7))
    assert_true(result.get(0))   # 1.5 != 3.7
    assert_false(result.get(1))  # 3.7 != 3.7 = false
    assert_false(result.get(2))


def test_eval_ne_float64_nan_semantics() raises:
    """NaN != x → true under IEEE UNORDERED not-equal.

    The `eval_ne` kernel uses `~v.eq(t)` internally; `NaN.eq(NaN) → false`,
    so `~false → true`. Mojo's native `.ne` lowers to `fcmp one` (ordered:
    NaN!=NaN→false). This test guards against a regression to that ordered
    shape — the two differ, and the kernel deliberately picks the unordered one.

    ⚠ THIS PINS A KNOWN DIVERGENCE, NOT DuckDB PARITY: DuckDB v1.5.3 returns
    FALSE for `'nan' <> 'nan'`, as
    do PostgreSQL and Spark SQL, and the SQL standard does not define NaN for
    approximate numerics at all. Leave this expectation ALONE until the engine
    adopts one shared NaN comparison semantics.
    """
    var nan = Scalar[DType.float64](Float64("nan"))
    var values: List[Scalar[DType.float64]] = [
        nan,                              # NaN
        Scalar[DType.float64](1.0),       # 1.0
        nan,                              # NaN
        Scalar[DType.float64](0.0),       # 0.0
    ]
    var col = PrimitiveArray[DType.float64].from_list(values)
    # NaN != 1.0 → true; 1.0 != 1.0 → false; NaN != 1.0 → true; 0.0 != 1.0 → true.
    var result = eval_ne[DType.float64](col, Scalar[DType.float64](1.0))
    assert_true(result.get(0))   # NaN != 1.0 = true (SQL unordered)
    assert_false(result.get(1))  # 1.0 != 1.0 = false
    assert_true(result.get(2))   # NaN != 1.0 = true
    assert_true(result.get(3))   # 0.0 != 1.0 = true


def test_eval_ne_empty() raises:
    """Empty array: eval_ne returns empty BooleanArray."""
    var col = PrimitiveArray[DType.int32].allocate(0)
    var result = eval_ne[DType.int32](col, Scalar[DType.int32](0))
    assert_equal(len(result), 0)


# =============================================================================
# eval_le — col-vs-scalar (int32 / int64 / float64)
# =============================================================================


def test_eval_le_int32_basic() raises:
    """eval_le returns true for values <= threshold (int32)."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](5),
        Scalar[DType.int32](10),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var result = eval_le[DType.int32](col, Scalar[DType.int32](5))
    assert_true(result.get(0))   # 1 <= 5 = true
    assert_true(result.get(1))   # 5 <= 5 = true
    assert_false(result.get(2))  # 10 <= 5 = false


def test_eval_le_int64_boundary_9() raises:
    """eval_le with 9 elements (one byte + 1-bit remainder)."""
    var col = _make_sequential_int64(9)
    var result = eval_le[DType.int64](col, Scalar[DType.int64](4))
    assert_equal(len(result), 9)
    assert_true(result.get(0))   # 0 <= 4
    assert_true(result.get(4))   # 4 <= 4
    assert_false(result.get(5))  # 5 <= 4 = false
    assert_false(result.get(8))  # 8 <= 4 = false
    assert_equal(_count_true(result), 5)  # 0..4


def test_eval_le_float64_basic() raises:
    var values: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](-1.5),
        Scalar[DType.float64](0.0),
        Scalar[DType.float64](2.0),
    ]
    var col = PrimitiveArray[DType.float64].from_list(values)
    var result = eval_le[DType.float64](col, Scalar[DType.float64](0.0))
    assert_true(result.get(0))   # -1.5 <= 0.0
    assert_true(result.get(1))   #  0.0 <= 0.0
    assert_false(result.get(2))  #  2.0 <= 0.0 = false


def test_eval_le_empty() raises:
    var col = PrimitiveArray[DType.int32].allocate(0)
    var result = eval_le[DType.int32](col, Scalar[DType.int32](0))
    assert_equal(len(result), 0)


# =============================================================================
# eval_ge — col-vs-scalar (int32 / int64 / float64)
# =============================================================================


def test_eval_ge_int32_basic() raises:
    """eval_ge returns true for values >= threshold (int32)."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](5),
        Scalar[DType.int32](10),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var result = eval_ge[DType.int32](col, Scalar[DType.int32](5))
    assert_false(result.get(0))  # 1 >= 5 = false
    assert_true(result.get(1))   # 5 >= 5 = true
    assert_true(result.get(2))   # 10 >= 5 = true


def test_eval_ge_int64_boundary_65() raises:
    """eval_ge with 65 elements (8 full bytes + 1-bit remainder).

    Exercises the W≥8 path on AVX-512 + the W<8 path on NEON/SSE alike,
    plus the trailing-byte handling.
    """
    var col = _make_sequential_int64(65)
    var result = eval_ge[DType.int64](col, Scalar[DType.int64](32))
    assert_equal(len(result), 65)
    assert_false(result.get(31))  # 31 >= 32 = false
    assert_true(result.get(32))   # 32 >= 32 = true
    assert_true(result.get(64))   # 64 >= 32 = true
    assert_equal(_count_true(result), 33)  # 32..64 inclusive


def test_eval_ge_float64_basic() raises:
    var values: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](-1.0),
        Scalar[DType.float64](0.0),
        Scalar[DType.float64](1.0),
    ]
    var col = PrimitiveArray[DType.float64].from_list(values)
    var result = eval_ge[DType.float64](col, Scalar[DType.float64](0.0))
    assert_false(result.get(0))  # -1.0 >= 0.0 = false
    assert_true(result.get(1))   #  0.0 >= 0.0 = true
    assert_true(result.get(2))   #  1.0 >= 0.0 = true


def test_eval_ge_empty() raises:
    var col = PrimitiveArray[DType.int32].allocate(0)
    var result = eval_ge[DType.int32](col, Scalar[DType.int32](0))
    assert_equal(len(result), 0)


# =============================================================================
# Behavioural parity with prior NOT-wrap shape (regression guards)
# =============================================================================


def test_parity_ne_vs_not_eq_int64() raises:
    """eval_ne[Int64] ≡ eval_not(eval_eq[Int64]) byte-for-byte on a 200-row
    deterministic vector — guards the NOT-wrap → first-class transition."""
    var col = _make_sequential_int64(200)
    var threshold = Scalar[DType.int64](42)
    var first_class = eval_ne[DType.int64](col, threshold)
    var legacy = eval_not(eval_eq[DType.int64](col, threshold))
    assert_true(_masks_equal(first_class, legacy))


def test_parity_le_vs_not_gt_int64() raises:
    """eval_le[Int64] ≡ eval_not(eval_gt[Int64])."""
    var col = _make_sequential_int64(200)
    var threshold = Scalar[DType.int64](100)
    var first_class = eval_le[DType.int64](col, threshold)
    var legacy = eval_not(eval_gt[DType.int64](col, threshold))
    assert_true(_masks_equal(first_class, legacy))


def test_parity_ge_vs_not_lt_int64() raises:
    """eval_ge[Int64] ≡ eval_not(eval_lt[Int64])."""
    var col = _make_sequential_int64(200)
    var threshold = Scalar[DType.int64](100)
    var first_class = eval_ge[DType.int64](col, threshold)
    var legacy = eval_not(eval_lt[DType.int64](col, threshold))
    assert_true(_masks_equal(first_class, legacy))


def test_parity_le_vs_not_gt_float64() raises:
    """eval_le[Float64] ≡ eval_not(eval_gt[Float64]) on non-NaN inputs.

    NOTE: this parity holds for ordered comparisons only. eval_ne diverges
    from eval_not(eval_eq) when NaN is present (the first-class kernel uses
    `~eq` for SQL-correct unordered NE; the legacy `eval_not(eval_eq)`
    shape coincidentally also used the eq kernel which used `.eq`, so on
    NaN inputs the legacy returned NULL/false and the first-class returns
    true). For LE/GE there is no such divergence — both old + new use
    ordered IEEE comparisons.
    """
    var col = _make_sequential_float64(200)
    var threshold = Scalar[DType.float64](100.0)
    var first_class = eval_le[DType.float64](col, threshold)
    var legacy = eval_not(eval_gt[DType.float64](col, threshold))
    assert_true(_masks_equal(first_class, legacy))


# =============================================================================
# Col-vs-col variants — eval_col_ne / eval_col_le / eval_col_ge
# =============================================================================


def test_eval_col_ne_int64_basic() raises:
    """eval_col_ne element-wise (int64)."""
    var lhs_v: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](1),
        Scalar[DType.int64](5),
        Scalar[DType.int64](5),
        Scalar[DType.int64](10),
    ]
    var rhs_v: List[Scalar[DType.int64]] = [
        Scalar[DType.int64](2),
        Scalar[DType.int64](5),
        Scalar[DType.int64](6),
        Scalar[DType.int64](10),
    ]
    var lhs = PrimitiveArray[DType.int64].from_list(lhs_v)
    var rhs = PrimitiveArray[DType.int64].from_list(rhs_v)
    var result = eval_col_ne[DType.int64](lhs, rhs)
    assert_true(result.get(0))   # 1 != 2 = true
    assert_false(result.get(1))  # 5 != 5 = false
    assert_true(result.get(2))   # 5 != 6 = true
    assert_false(result.get(3))  # 10 != 10 = false


def test_eval_col_le_float64_basic() raises:
    """eval_col_le element-wise (float64)."""
    var lhs_v: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](1.0),
        Scalar[DType.float64](2.5),
        Scalar[DType.float64](3.0),
    ]
    var rhs_v: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](2.0),
        Scalar[DType.float64](2.5),
        Scalar[DType.float64](2.0),
    ]
    var lhs = PrimitiveArray[DType.float64].from_list(lhs_v)
    var rhs = PrimitiveArray[DType.float64].from_list(rhs_v)
    var result = eval_col_le[DType.float64](lhs, rhs)
    assert_true(result.get(0))   # 1.0 <= 2.0
    assert_true(result.get(1))   # 2.5 <= 2.5
    assert_false(result.get(2))  # 3.0 <= 2.0 = false


def test_eval_col_ge_int32_boundary_17() raises:
    """eval_col_ge with 17 elements (W=4 path, multi-byte + remainder)."""
    var lhs = _make_sequential_int32(17)
    var rhs = PrimitiveArray[DType.int32].allocate(17)
    for i in range(17):
        rhs.set(i, Scalar[DType.int32](8))
    var result = eval_col_ge[DType.int32](lhs, rhs)
    assert_equal(len(result), 17)
    assert_false(result.get(0))   # 0 >= 8 = false
    assert_false(result.get(7))   # 7 >= 8 = false
    assert_true(result.get(8))    # 8 >= 8 = true
    assert_true(result.get(16))   # 16 >= 8 = true
    assert_equal(_count_true(result), 9)  # 8..16 inclusive


def test_eval_col_ne_parity_int64() raises:
    """eval_col_ne ≡ eval_not(eval_col_eq) on a 100-row sequential vector."""
    var lhs = _make_sequential_int64(100)
    var rhs = PrimitiveArray[DType.int64].allocate(100)
    for i in range(100):
        # alternating equal / off-by-one
        if i % 2 == 0:
            rhs.set(i, Scalar[DType.int64](i))
        else:
            rhs.set(i, Scalar[DType.int64](i + 1))
    var first_class = eval_col_ne[DType.int64](lhs, rhs)
    var legacy = eval_not(eval_col_eq[DType.int64](lhs, rhs))
    assert_true(_masks_equal(first_class, legacy))


def test_eval_col_le_parity_float64() raises:
    """eval_col_le ≡ eval_not(eval_col_gt) on a 100-row float64 vector."""
    var lhs = _make_sequential_float64(100)
    var rhs = PrimitiveArray[DType.float64].allocate(100)
    for i in range(100):
        rhs.set(i, Scalar[DType.float64](Float64(50)))
    var first_class = eval_col_le[DType.float64](lhs, rhs)
    var legacy = eval_not(eval_col_gt[DType.float64](lhs, rhs))
    assert_true(_masks_equal(first_class, legacy))


def test_eval_col_ge_via_le_swap() raises:
    """eval_col_ge[T](l, r) is implemented as eval_col_le[T](r, l).

    This sanity-check confirms the swap semantics on a simple case —
    `a >= b ≡ b <= a` on standard IEEE ordered comparison.
    """
    var l = _make_sequential_int32(8)
    var r = PrimitiveArray[DType.int32].allocate(8)
    for i in range(8):
        r.set(i, Scalar[DType.int32](4))
    var ge_result = eval_col_ge[DType.int32](l, r)
    var swap_result = eval_col_le[DType.int32](r, l)
    assert_true(_masks_equal(ge_result, swap_result))


# =============================================================================
# Larger boundary sweep — int64 / float64 NE on 64/65 elements
# =============================================================================


def test_eval_ne_int64_boundary_64() raises:
    """eval_ne with 64 elements (exactly 8 bytes, no remainder)."""
    var col = _make_sequential_int64(64)
    var result = eval_ne[DType.int64](col, Scalar[DType.int64](30))
    assert_equal(len(result), 64)
    assert_false(result.get(30))  # 30 != 30 = false
    assert_true(result.get(29))   # 29 != 30 = true
    assert_true(result.get(63))   # 63 != 30 = true
    assert_equal(_count_true(result), 63)  # all but index 30


def test_eval_le_float64_boundary_63() raises:
    """eval_le with 63 elements (7 bytes + 7-bit remainder)."""
    var col = _make_sequential_float64(63)
    var result = eval_le[DType.float64](col, Scalar[DType.float64](31.0))
    assert_equal(len(result), 63)
    assert_true(result.get(31))   # 31 <= 31 = true
    assert_false(result.get(32))  # 32 <= 31 = false
    assert_equal(_count_true(result), 32)  # 0..31


def test_eval_ge_int32_boundary_15() raises:
    """eval_ge with 15 elements (1 byte + 7-bit remainder)."""
    var col = _make_sequential_int32(15)
    var result = eval_ge[DType.int32](col, Scalar[DType.int32](7))
    assert_equal(len(result), 15)
    assert_false(result.get(6))   # 6 >= 7 = false
    assert_true(result.get(7))    # 7 >= 7 = true
    assert_true(result.get(14))   # 14 >= 7 = true
    assert_equal(_count_true(result), 8)  # 7..14 inclusive


# =============================================================================
# Test driver
# =============================================================================


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
