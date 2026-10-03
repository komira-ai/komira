# =============================================================================
# Tests for arithmetic eval — imports from komira_arrow and komira_core.eval
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false


from komira_core.arrow import PrimitiveArray, BooleanArray
from komira_core.eval import eval_add, eval_sub, eval_mul, eval_div
from komira_core.eval import eval_add_scalar, eval_mul_scalar
from komira_core.eval import eval_and, eval_or, eval_not
from komira_core.eval import filtered_sum
from komira_core.eval.arithmetic import eval_revenue_sum, eval_filtered_revenue_sum
from komira_core.arrow.bitmap import Bitmap


# =============================================================================
# Column vs Column arithmetic
# =============================================================================


def test_eval_add() raises:
    """eval_add performs element-wise addition."""
    var left_vals: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](2),
        Scalar[DType.int32](3),
    ]
    var right_vals: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](10),
        Scalar[DType.int32](20),
        Scalar[DType.int32](30),
    ]
    var left = PrimitiveArray[DType.int32].from_list(left_vals)
    var right = PrimitiveArray[DType.int32].from_list(right_vals)
    var result = eval_add[DType.int32](left, right)
    assert_equal(result.get(0), Scalar[DType.int32](11))
    assert_equal(result.get(1), Scalar[DType.int32](22))
    assert_equal(result.get(2), Scalar[DType.int32](33))


def test_eval_sub() raises:
    """eval_sub performs element-wise subtraction."""
    var left_vals: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](10),
        Scalar[DType.int32](20),
        Scalar[DType.int32](30),
    ]
    var right_vals: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](5),
        Scalar[DType.int32](10),
    ]
    var left = PrimitiveArray[DType.int32].from_list(left_vals)
    var right = PrimitiveArray[DType.int32].from_list(right_vals)
    var result = eval_sub[DType.int32](left, right)
    assert_equal(result.get(0), Scalar[DType.int32](9))
    assert_equal(result.get(1), Scalar[DType.int32](15))
    assert_equal(result.get(2), Scalar[DType.int32](20))


def test_eval_mul() raises:
    """eval_mul performs element-wise multiplication."""
    var left_vals: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](2),
        Scalar[DType.int32](3),
        Scalar[DType.int32](4),
    ]
    var right_vals: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](5),
        Scalar[DType.int32](6),
        Scalar[DType.int32](7),
    ]
    var left = PrimitiveArray[DType.int32].from_list(left_vals)
    var right = PrimitiveArray[DType.int32].from_list(right_vals)
    var result = eval_mul[DType.int32](left, right)
    assert_equal(result.get(0), Scalar[DType.int32](10))
    assert_equal(result.get(1), Scalar[DType.int32](18))
    assert_equal(result.get(2), Scalar[DType.int32](28))


def test_eval_div() raises:
    """eval_div performs element-wise integer division."""
    var left_vals: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](10),
        Scalar[DType.int32](20),
        Scalar[DType.int32](30),
    ]
    var right_vals: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](2),
        Scalar[DType.int32](5),
        Scalar[DType.int32](10),
    ]
    var left = PrimitiveArray[DType.int32].from_list(left_vals)
    var right = PrimitiveArray[DType.int32].from_list(right_vals)
    var result = eval_div[DType.int32](left, right)
    assert_equal(result.get(0), Scalar[DType.int32](5))
    assert_equal(result.get(1), Scalar[DType.int32](4))
    assert_equal(result.get(2), Scalar[DType.int32](3))


def test_eval_div_float64() raises:
    """eval_div works with float64 values."""
    var left_vals: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](10.0),
        Scalar[DType.float64](7.0),
    ]
    var right_vals: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](4.0),
        Scalar[DType.float64](2.0),
    ]
    var left = PrimitiveArray[DType.float64].from_list(left_vals)
    var right = PrimitiveArray[DType.float64].from_list(right_vals)
    var result = eval_div[DType.float64](left, right)
    assert_equal(result.get(0), Scalar[DType.float64](2.5))
    assert_equal(result.get(1), Scalar[DType.float64](3.5))


# =============================================================================
# Column vs Scalar
# =============================================================================


def test_eval_add_scalar() raises:
    """eval_add_scalar adds a constant to every element."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](2),
        Scalar[DType.int32](3),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var result = eval_add_scalar[DType.int32](col, Scalar[DType.int32](100))
    assert_equal(result.get(0), Scalar[DType.int32](101))
    assert_equal(result.get(1), Scalar[DType.int32](102))
    assert_equal(result.get(2), Scalar[DType.int32](103))


def test_eval_mul_scalar() raises:
    """eval_mul_scalar multiplies every element by a constant."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](2),
        Scalar[DType.int32](3),
        Scalar[DType.int32](4),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var result = eval_mul_scalar[DType.int32](col, Scalar[DType.int32](10))
    assert_equal(result.get(0), Scalar[DType.int32](20))
    assert_equal(result.get(1), Scalar[DType.int32](30))
    assert_equal(result.get(2), Scalar[DType.int32](40))


# =============================================================================
# Boolean logical operations (now using BooleanArray)
# =============================================================================


def test_eval_and() raises:
    """eval_and performs element-wise logical AND on BooleanArrays."""
    var left = BooleanArray.allocate(4)
    left.set(0, True)
    left.set(1, True)
    left.set(2, False)
    left.set(3, False)

    var right = BooleanArray.allocate(4)
    right.set(0, True)
    right.set(1, False)
    right.set(2, True)
    right.set(3, False)

    var result = eval_and(left, right)
    assert_true(result.get(0))   # T & T = T
    assert_false(result.get(1))  # T & F = F
    assert_false(result.get(2))  # F & T = F
    assert_false(result.get(3))  # F & F = F


def test_eval_or() raises:
    """eval_or performs element-wise logical OR on BooleanArrays."""
    var left = BooleanArray.allocate(4)
    left.set(0, True)
    left.set(1, True)
    left.set(2, False)
    left.set(3, False)

    var right = BooleanArray.allocate(4)
    right.set(0, True)
    right.set(1, False)
    right.set(2, True)
    right.set(3, False)

    var result = eval_or(left, right)
    assert_true(result.get(0))   # T | T = T
    assert_true(result.get(1))   # T | F = T
    assert_true(result.get(2))   # F | T = T
    assert_false(result.get(3))  # F | F = F


def test_eval_not() raises:
    """eval_not performs element-wise logical NOT on BooleanArray."""
    var col = BooleanArray.allocate(3)
    col.set(0, True)
    col.set(1, False)
    col.set(2, True)

    var result = eval_not(col)
    assert_false(result.get(0))  # ~T = F
    assert_true(result.get(1))   # ~F = T
    assert_false(result.get(2))  # ~T = F


# =============================================================================
# filtered_sum tests
# =============================================================================


def test_filtered_sum_basic() raises:
    """filtered_sum sums only elements where mask bit is True."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](10),
        Scalar[DType.int32](20),
        Scalar[DType.int32](30),
        Scalar[DType.int32](40),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var mask = BooleanArray.allocate(4)
    mask.set(0, True)
    mask.set(1, False)
    mask.set(2, True)
    mask.set(3, False)
    var result = filtered_sum[DType.int32](col, mask)
    assert_equal(result, Scalar[DType.int32](40))  # 10 + 30


def test_filtered_sum_all_true() raises:
    """filtered_sum with all-true mask returns total sum."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](2),
        Scalar[DType.int32](3),
        Scalar[DType.int32](4),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var mask = BooleanArray.allocate(4)
    mask.set(0, True)
    mask.set(1, True)
    mask.set(2, True)
    mask.set(3, True)
    var result = filtered_sum[DType.int32](col, mask)
    assert_equal(result, Scalar[DType.int32](10))


def test_filtered_sum_all_false() raises:
    """filtered_sum with all-false mask returns 0."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](100),
        Scalar[DType.int32](200),
        Scalar[DType.int32](300),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var mask = BooleanArray.allocate(3)
    # All bits default to False (0)
    var result = filtered_sum[DType.int32](col, mask)
    assert_equal(result, Scalar[DType.int32](0))


def test_filtered_sum_mixed_mask() raises:
    """filtered_sum with alternating true/false mask on 8 elements."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](2),
        Scalar[DType.int32](3),
        Scalar[DType.int32](4),
        Scalar[DType.int32](5),
        Scalar[DType.int32](6),
        Scalar[DType.int32](7),
        Scalar[DType.int32](8),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var mask = BooleanArray.allocate(8)
    # Even indices only: 1+3+5+7 = 16
    mask.set(0, True)
    mask.set(2, True)
    mask.set(4, True)
    mask.set(6, True)
    var result = filtered_sum[DType.int32](col, mask)
    assert_equal(result, Scalar[DType.int32](16))


def test_filtered_sum_empty_array() raises:
    """filtered_sum on empty arrays returns 0."""
    var col = PrimitiveArray[DType.int32].allocate(0)
    var mask = BooleanArray.allocate(0)
    var result = filtered_sum[DType.int32](col, mask)
    assert_equal(result, Scalar[DType.int32](0))


def test_filtered_sum_single_element_true() raises:
    """filtered_sum with single element and true mask."""
    var values: List[Scalar[DType.int32]] = [Scalar[DType.int32](42)]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var mask = BooleanArray.allocate(1)
    mask.set(0, True)
    var result = filtered_sum[DType.int32](col, mask)
    assert_equal(result, Scalar[DType.int32](42))


def test_filtered_sum_single_element_false() raises:
    """filtered_sum with single element and false mask returns 0."""
    var values: List[Scalar[DType.int32]] = [Scalar[DType.int32](42)]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var mask = BooleanArray.allocate(1)
    var result = filtered_sum[DType.int32](col, mask)
    assert_equal(result, Scalar[DType.int32](0))


def test_filtered_sum_float64() raises:
    """filtered_sum works with float64 data."""
    var values: List[Scalar[DType.float64]] = [
        Scalar[DType.float64](1.5),
        Scalar[DType.float64](2.5),
        Scalar[DType.float64](3.5),
    ]
    var col = PrimitiveArray[DType.float64].from_list(values)
    var mask = BooleanArray.allocate(3)
    mask.set(0, True)
    mask.set(2, True)
    var result = filtered_sum[DType.float64](col, mask)
    assert_equal(result, Scalar[DType.float64](5.0))


def test_filtered_sum_non_8_aligned_length() raises:
    """filtered_sum handles lengths not aligned to 8 (exercises remainder path)."""
    var values: List[Scalar[DType.int32]] = [
        Scalar[DType.int32](1),
        Scalar[DType.int32](2),
        Scalar[DType.int32](3),
        Scalar[DType.int32](4),
        Scalar[DType.int32](5),
    ]
    var col = PrimitiveArray[DType.int32].from_list(values)
    var mask = BooleanArray.allocate(5)
    mask.set(0, True)
    mask.set(1, True)
    mask.set(2, True)
    mask.set(3, True)
    mask.set(4, True)
    var result = filtered_sum[DType.int32](col, mask)
    assert_equal(result, Scalar[DType.int32](15))


# =============================================================================
# Empty array tests for eval_add, eval_and
# =============================================================================


def test_eval_add_empty() raises:
    """eval_add on empty arrays returns empty result."""
    var left = PrimitiveArray[DType.int32].allocate(0)
    var right = PrimitiveArray[DType.int32].allocate(0)
    var result = eval_add[DType.int32](left, right)
    assert_equal(result.length, 0)


def test_eval_and_empty() raises:
    """eval_and on empty BooleanArrays returns empty result."""
    var left = BooleanArray.allocate(0)
    var right = BooleanArray.allocate(0)
    var result = eval_and(left, right)
    assert_equal(len(result), 0)


# =============================================================================
# reduce_add() horizontal SIMD reduction tests
# =============================================================================
# Tree-reduction changes FP rounding order vs lane-serial sum. These tests
# enforce: integer paths bit-identical, Float64 paths within 1e-14 relative
# error vs a sequential reference computed from the same inputs.


def _ulp_close(a: Float64, b: Float64, tol: Float64) raises -> None:
    """Assert |a - b| / max(|b|, 1.0) < tol."""
    var denom = abs(b)
    if denom < 1.0:
        denom = 1.0
    var rel = abs(a - b) / denom
    assert_true(rel < tol, "rel err " + String(rel) + " not < " + String(tol)
        + " (a=" + String(a) + " b=" + String(b) + ")")


def test_filtered_sum_bit_identical_int32_all_set() raises:
    """Int32 filtered_sum with all-set mask must be bit-identical to ref sum.
    Exercises the all-bits-set fast path (its reduce_add)."""
    var n = 1024
    var vals = List[Scalar[DType.int32]]()
    var ref_sum = Scalar[DType.int32](0)
    for i in range(n):
        var v = Scalar[DType.int32](i - 500)
        vals.append(v)
        ref_sum += v
    var col = PrimitiveArray[DType.int32].from_list(vals)
    var mask = BooleanArray.allocate(n)
    for i in range(n):
        mask.set(i, True)
    var got = filtered_sum[DType.int32](col, mask)
    assert_equal(got, ref_sum)


def test_filtered_sum_bit_identical_int32_partial_byte() raises:
    """Int32 filtered_sum with sparse mask must be bit-identical.
    Exercises the partial-byte SIMD select path (its reduce_add)."""
    var n = 1024
    var vals = List[Scalar[DType.int32]]()
    for i in range(n):
        vals.append(Scalar[DType.int32](i + 1))
    var col = PrimitiveArray[DType.int32].from_list(vals)
    var mask = BooleanArray.allocate(n)
    var ref_sum = Scalar[DType.int32](0)
    # alternating odd-bit pattern -> forces partial-byte path (not 0x00, not 0xFF)
    for i in range(n):
        var sel = (i % 3) != 0
        mask.set(i, sel)
        if sel:
            ref_sum += Scalar[DType.int32](i + 1)
    var got = filtered_sum[DType.int32](col, mask)
    assert_equal(got, ref_sum)


def test_filtered_sum_bit_identical_int64_partial() raises:
    """Int64 filtered_sum exercises width=2/4 lane reduction; bit-identical."""
    var n = 2048
    var vals = List[Scalar[DType.int64]]()
    for i in range(n):
        vals.append(Scalar[DType.int64](i * 7 - 1000))
    var col = PrimitiveArray[DType.int64].from_list(vals)
    var mask = BooleanArray.allocate(n)
    var ref_sum = Scalar[DType.int64](0)
    for i in range(n):
        var sel = ((i >> 1) & 1) == 1  # 0011 0011 ... pattern -> partial bytes
        mask.set(i, sel)
        if sel:
            ref_sum += vals[i]
    var got = filtered_sum[DType.int64](col, mask)
    assert_equal(got, ref_sum)


def test_eval_revenue_sum_ulp_bounded() raises:
    """eval_revenue_sum tree-reduction within 1e-14 of sequential reference."""
    var n = 8192
    var price_vals = List[Scalar[DType.float64]]()
    var disc_vals = List[Scalar[DType.float64]]()
    var ref_total = Float64(0.0)
    for i in range(n):
        var p = Float64(i + 1) * 1.5
        var d = Float64(i % 11) * 0.01  # 0..0.10
        price_vals.append(Scalar[DType.float64](p))
        disc_vals.append(Scalar[DType.float64](d))
        ref_total += p * (1.0 - d)
    var price = PrimitiveArray[DType.float64].from_list(price_vals)
    var discount = PrimitiveArray[DType.float64].from_list(disc_vals)
    var got = eval_revenue_sum(price, discount)
    _ulp_close(got, ref_total, 1e-14)


def test_eval_filtered_revenue_sum_ulp_bounded_dense() raises:
    """eval_filtered_revenue_sum dense (all-set) ULP-bounded vs reference.
    Exercises the all-bits-set SIMD fast path (its reduce_add)."""
    var n = 8192
    var price_vals = List[Scalar[DType.float64]]()
    var disc_vals = List[Scalar[DType.float64]]()
    var ref_total = Float64(0.0)
    for i in range(n):
        var p = 100.0 + Float64(i) * 0.25
        var d = Float64(i % 7) * 0.01
        price_vals.append(Scalar[DType.float64](p))
        disc_vals.append(Scalar[DType.float64](d))
        ref_total += p * (1.0 - d)
    var price = PrimitiveArray[DType.float64].from_list(price_vals)
    var discount = PrimitiveArray[DType.float64].from_list(disc_vals)
    var mask = BooleanArray.allocate(n)
    for i in range(n):
        mask.set(i, True)
    var got = eval_filtered_revenue_sum(price, discount, mask)
    _ulp_close(got, ref_total, 1e-14)


def test_eval_filtered_revenue_sum_sparse_matches_reference() raises:
    """eval_filtered_revenue_sum sparse mask: scalar-bit fallback path.
    Sparse path is unchanged by reduce_add edit, but verifies behavior."""
    var n = 4096
    var price_vals = List[Scalar[DType.float64]]()
    var disc_vals = List[Scalar[DType.float64]]()
    for i in range(n):
        price_vals.append(Scalar[DType.float64](Float64(i + 1)))
        disc_vals.append(Scalar[DType.float64](Float64(i % 5) * 0.02))
    var price = PrimitiveArray[DType.float64].from_list(price_vals)
    var discount = PrimitiveArray[DType.float64].from_list(disc_vals)
    var mask = BooleanArray.allocate(n)
    var ref_total = Float64(0.0)
    for i in range(n):
        var sel = (i % 5) == 0  # ~20% selectivity, partial bytes
        mask.set(i, sel)
        if sel:
            ref_total += Float64(i + 1) * (1.0 - Float64(i % 5) * 0.02)
    var got = eval_filtered_revenue_sum(price, discount, mask)
    _ulp_close(got, ref_total, 1e-14)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
