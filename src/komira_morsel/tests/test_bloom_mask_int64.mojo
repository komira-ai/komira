# =============================================================================
# Unit tests for _bloom_mask_int64 (bloom-pushdown Phase 3.4)
# =============================================================================
#
# v0.3 spec source: komira-engine/src/bloom_filter.rs:441-450 (Int64 path
# in BloomRowFilter::evaluate_single_column).
#
# Per-batch mask helper: takes (PrimitiveArray[INT64] keys, BloomFilter)
# and produces a BooleanArray of `might_contain` results, with v0.3 null
# semantics (`null -> false`).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_dynamic_filter.bloom_filter import BloomFilter
from komira_morsel.bloom_mask import bloom_mask_int64


# -----------------------------------------------------------------------------
# All inserted keys present -> no false negatives.
# -----------------------------------------------------------------------------
def test_all_inserted_keys_present() raises:
    var bf = BloomFilter.with_ndv_fpp(1024, 0.01)
    for i in range(0, 1024):
        bf.insert_int64(Int64(i))

    # Probe with the same keys.
    var keys = PrimitiveArray[DType.int64].allocate(1024)
    var ptr = keys._typed_ptr_mut()
    for i in range(1024):
        ptr[i] = Scalar[DType.int64](Int64(i))

    var mask = bloom_mask_int64(keys, bf)
    # No false negatives -> all bits should be True.
    assert_equal(mask.length, 1024)
    assert_equal(mask.true_count(), 1024)


# -----------------------------------------------------------------------------
# Zero matches -> sparse bloom mask.
# -----------------------------------------------------------------------------
def test_disjoint_probe_keys() raises:
    var bf = BloomFilter.with_ndv_fpp(1024, 0.01)
    for i in range(0, 1024):
        bf.insert_int64(Int64(i))

    # Probe with disjoint range [10000, 11023].
    var keys = PrimitiveArray[DType.int64].allocate(1024)
    var ptr = keys._typed_ptr_mut()
    for i in range(1024):
        ptr[i] = Scalar[DType.int64](Int64(10000 + i))

    var mask = bloom_mask_int64(keys, bf)
    # FPR <= 1% -> at most ~10 hits expected.
    assert_equal(mask.length, 1024)
    var hits = mask.true_count()
    # Allow generous slack: 5% upper bound.
    assert_true(hits < 50)


# -----------------------------------------------------------------------------
# Empty input -> empty output.
# -----------------------------------------------------------------------------
def test_empty_keys() raises:
    var bf = BloomFilter.with_ndv_fpp(1024, 0.01)
    bf.insert_int64(Int64(7))

    var keys = PrimitiveArray[DType.int64].allocate(0)
    var mask = bloom_mask_int64(keys, bf)
    assert_equal(mask.length, 0)
    assert_equal(mask.true_count(), 0)


# -----------------------------------------------------------------------------
# Mixed: half inserted, half not -> ~50% hits + tiny FPR contribution.
# -----------------------------------------------------------------------------
def test_partial_overlap() raises:
    var bf = BloomFilter.with_ndv_fpp(2048, 0.01)
    for i in range(0, 1024):
        bf.insert_int64(Int64(i))

    var keys = PrimitiveArray[DType.int64].allocate(2048)
    var ptr = keys._typed_ptr_mut()
    # First 1024: inserted (all True), second 1024: disjoint (mostly False).
    for i in range(1024):
        ptr[i] = Scalar[DType.int64](Int64(i))
    for i in range(1024):
        ptr[1024 + i] = Scalar[DType.int64](Int64(20000 + i))

    var mask = bloom_mask_int64(keys, bf)
    assert_equal(mask.length, 2048)
    var hits = mask.true_count()
    # Expected ~1024 + ~10 (FPR) = 1024..1075.
    assert_true(hits >= 1024)
    assert_true(hits < 1100)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
