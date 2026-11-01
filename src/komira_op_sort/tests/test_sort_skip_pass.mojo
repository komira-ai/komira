# ---
# Test: Radix sort skip-pass optimization correctness
#
# Verifies that the radix sort skip-pass optimization produces identical
# results to the merge sort reference implementation for various key ranges.
#
# The skip-pass optimization skips radix passes where all keys share the
# same byte value (histogram max_count == n). This test covers:
#   1. Small key range (0-100) -- most passes skippable
#   2. Medium key range (0-100K) -- some passes skippable
#   3. Full Int64 range -- no passes skippable
#   4. Negative keys -- sign bit handling after XOR
#   5. Single key -- all passes trivially skippable
#   6. Already sorted input
#   7. Reverse sorted input
# ---

from std.testing import TestSuite, assert_equal, assert_true
from komira_arrow.primitive_array import PrimitiveArray
from komira_op_sort.sort import sort_indices_int64
from komira_op_sort.sort_radix import radix_sort_int64


def lcg_next(state: UInt64) -> UInt64:
    return state * 6364136223846793005 + 1442695040888963407


def make_keys(n: Int, seed: Int, lo: Int, hi: Int) -> PrimitiveArray[DType.int64]:
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var s = UInt64(seed)
    var w = hi - lo
    var p = arr._typed_ptr_mut()
    for i in range(n):
        s = lcg_next(s)
        var v = Int(s >> 32) % w
        (p + i)[] = Scalar[DType.int64](lo + v)
    return arr^


def verify_sorted(keys: PrimitiveArray[DType.int64], perm: PrimitiveArray[DType.int32]) raises:
    """Verify that keys[perm[i]] is in ascending order."""
    var key_ptr = keys._typed_ptr_ro()
    var perm_ptr = perm._typed_ptr_ro()
    var n = perm.length
    for i in range(1, n):
        var prev = (key_ptr + Int((perm_ptr + i - 1)[]))[]
        var curr = (key_ptr + Int((perm_ptr + i)[]))[]
        assert_true(
            prev <= curr,
            "Sort order violation at position " + String(i),
        )


def verify_radix_matches_merge(keys: PrimitiveArray[DType.int64], label: String) raises:
    """Compare radix sort against merge sort reference."""
    var radix_perm = radix_sort_int64(keys)
    var merge_perm = sort_indices_int64(keys)

    assert_equal(radix_perm.length, merge_perm.length)

    # Both must produce sorted output
    verify_sorted(keys, radix_perm)
    verify_sorted(keys, merge_perm)

    # With identical input, both stable sorts should produce the same permutation
    var rp = radix_perm._typed_ptr_mut()
    var mp = merge_perm._typed_ptr_mut()
    for i in range(radix_perm.length):
        assert_equal(
            Int((rp + i)[]),
            Int((mp + i)[]),
        )

    print("  ", label, ": PASS (", keys.length, "keys)")


def test_small_key_range() raises:
    """Keys in [0, 100] -- most radix passes should be skipped."""
    var keys = make_keys(10000, 42, 0, 100)
    verify_radix_matches_merge(keys, "small_range [0,100]")


def test_medium_key_range() raises:
    """Keys in [0, 100K] -- some passes skipped."""
    var keys = make_keys(10000, 43, 0, 100000)
    verify_radix_matches_merge(keys, "medium_range [0,100K]")


def test_full_int64_range() raises:
    """Keys spanning full Int64 range -- no passes skipped."""
    var n = 1000
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    var s = UInt64(99)
    for i in range(n):
        s = lcg_next(s)
        # Full range: both positive and large negatives
        (p + i)[] = Scalar[DType.int64](Int(Int64(s)))
    verify_radix_matches_merge(arr, "full_int64_range")


def test_negative_keys() raises:
    """Keys with negative values -- sign bit XOR must work."""
    var keys = make_keys(5000, 44, -50000, 50000)
    verify_radix_matches_merge(keys, "negative_keys [-50K,50K]")


def test_single_key_value() raises:
    """All keys identical -- all passes should be skipped."""
    var n = 1000
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = Scalar[DType.int64](42)

    var perm = radix_sort_int64(arr)
    verify_sorted(arr, perm)
    # All keys are 42, so stable sort preserves original order
    var pp = perm._typed_ptr_mut()
    for i in range(n):
        assert_equal(Int((pp + i)[]), i)
    print("  single_key_value: PASS")


def test_already_sorted() raises:
    """Pre-sorted input."""
    var n = 1000
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = Scalar[DType.int64](i)
    verify_radix_matches_merge(arr, "already_sorted")


def test_reverse_sorted() raises:
    """Reverse-sorted input."""
    var n = 1000
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = Scalar[DType.int64](n - i)
    verify_radix_matches_merge(arr, "reverse_sorted")


def test_empty_and_single() raises:
    """Edge cases: empty and single-element arrays."""
    var empty = PrimitiveArray[DType.int64].allocate(0)
    var perm_empty = radix_sort_int64(empty)
    assert_equal(perm_empty.length, 0)

    var single = PrimitiveArray[DType.int64].allocate(1)
    single._typed_ptr_mut()[] = Scalar[DType.int64](999)
    var perm_single = radix_sort_int64(single)
    assert_equal(perm_single.length, 1)
    assert_equal(Int(perm_single._typed_ptr_mut()[]), 0)
    print("  empty_and_single: PASS")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
