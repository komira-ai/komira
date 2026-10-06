# =============================================================================
# Unit tests for range_mask_int64 + in_list_mask_int64 (q11 REC 3 wiring)
# =============================================================================
#
# v0.3 spec source: komira-engine/src/bloom_filter.rs:759-770 (range eval)
# + 241-246 (in-list eval). Phase 3.4 ported the bloom path
# (Tier 3); q11 REC 3 ports the range (Tier 2) and in-list
# (Tier 1) paths so the parquet source can consume all three tiers.
#
# Per-batch mask helpers: take (PrimitiveArray[INT64] keys, RangeFilter|
# InListFilter) and produce a BooleanArray of membership results, with
# v0.3 null semantics (`null -> false`).
#
# These functions did not exist before q11 REC 3; this test file is the
# regression gate. Pre-fix the test FAILS TO BUILD (symbols absent).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.collections.in_list_filter import InListFilter
from komira_core.collections.range_filter import RangeFilter
from komira_morsel.bloom_mask import (
    in_list_mask_int64,
    range_mask_int64,
)


# -----------------------------------------------------------------------------
# range_mask_int64: rows inside [min, max] -> True; outside -> False.
# -----------------------------------------------------------------------------
def test_range_mask_all_inside() raises:
    var rf = RangeFilter.new_int64(0, 999)

    var keys = PrimitiveArray[DType.int64].allocate(1024)
    var ptr = keys._typed_ptr_mut()
    # First 1000 keys [0, 999] all in range; last 24 [1000, 1023] outside.
    for i in range(1024):
        ptr[i] = Scalar[DType.int64](Int64(i))

    var mask = range_mask_int64(keys, rf)
    assert_equal(mask.length, 1024)
    # 1000 rows in [0, 999] survive; 24 fail.
    assert_equal(mask.true_count(), 1000)
    assert_true(mask.get(0))
    assert_true(mask.get(999))
    assert_false(mask.get(1000))
    assert_false(mask.get(1023))


def test_range_mask_all_outside() raises:
    var rf = RangeFilter.new_int64(10_000, 20_000)

    var keys = PrimitiveArray[DType.int64].allocate(256)
    var ptr = keys._typed_ptr_mut()
    for i in range(256):
        ptr[i] = Scalar[DType.int64](Int64(i))

    var mask = range_mask_int64(keys, rf)
    assert_equal(mask.length, 256)
    assert_equal(mask.true_count(), 0)


def test_range_mask_degenerate_single() raises:
    # min == max: only key == min passes.
    var rf = RangeFilter.new_int64(42, 42)

    var keys = PrimitiveArray[DType.int64].allocate(100)
    var ptr = keys._typed_ptr_mut()
    for i in range(100):
        ptr[i] = Scalar[DType.int64](Int64(i))

    var mask = range_mask_int64(keys, rf)
    assert_equal(mask.length, 100)
    assert_equal(mask.true_count(), 1)
    assert_true(mask.get(42))
    assert_false(mask.get(41))
    assert_false(mask.get(43))


def test_range_mask_negative_range() raises:
    var rf = RangeFilter.new_int64(-50, 50)

    var keys = PrimitiveArray[DType.int64].allocate(201)
    var ptr = keys._typed_ptr_mut()
    # Keys [-100, 100].
    for i in range(201):
        ptr[i] = Scalar[DType.int64](Int64(i - 100))

    var mask = range_mask_int64(keys, rf)
    assert_equal(mask.length, 201)
    # 101 rows in [-50, 50].
    assert_equal(mask.true_count(), 101)
    assert_true(mask.get(50))   # value -50
    assert_true(mask.get(150))  # value +50
    assert_false(mask.get(49))  # value -51
    assert_false(mask.get(151)) # value +51


def test_range_mask_simd_tail() raises:
    # Length not a multiple of native SIMD width (NEON int64 W=2,
    # AVX-2 W=4, AVX-512 W=8). Use length 17 to exercise tail on
    # every supported arch.
    var rf = RangeFilter.new_int64(5, 12)

    var keys = PrimitiveArray[DType.int64].allocate(17)
    var ptr = keys._typed_ptr_mut()
    for i in range(17):
        ptr[i] = Scalar[DType.int64](Int64(i))

    var mask = range_mask_int64(keys, rf)
    assert_equal(mask.length, 17)
    # [5, 12] inclusive -> 8 rows.
    assert_equal(mask.true_count(), 8)
    assert_true(mask.get(5))
    assert_true(mask.get(12))
    assert_false(mask.get(4))
    assert_false(mask.get(13))


def test_range_mask_empty() raises:
    var rf = RangeFilter.new_int64(0, 100)
    var keys = PrimitiveArray[DType.int64].allocate(0)
    var mask = range_mask_int64(keys, rf)
    assert_equal(mask.length, 0)
    assert_equal(mask.true_count(), 0)


# -----------------------------------------------------------------------------
# in_list_mask_int64: rows whose value is in the build-side set -> True.
# Zero false positives.
# -----------------------------------------------------------------------------
def test_in_list_mask_all_present() raises:
    var build = List[Int64]()
    for i in range(50):
        build.append(Int64(i * 10))   # {0, 10, 20, ..., 490}
    var il_opt = InListFilter.try_from_int64(build)
    assert_true(il_opt.__bool__())
    var il = il_opt.take()

    # Probe with the same multiples of 10.
    var keys = PrimitiveArray[DType.int64].allocate(50)
    var ptr = keys._typed_ptr_mut()
    for i in range(50):
        ptr[i] = Scalar[DType.int64](Int64(i * 10))

    var mask = in_list_mask_int64(keys, il)
    assert_equal(mask.length, 50)
    assert_equal(mask.true_count(), 50)


def test_in_list_mask_disjoint() raises:
    var build = List[Int64]()
    build.append(1)
    build.append(2)
    build.append(3)
    var il_opt = InListFilter.try_from_int64(build)
    assert_true(il_opt.__bool__())
    var il = il_opt.take()

    var keys = PrimitiveArray[DType.int64].allocate(100)
    var ptr = keys._typed_ptr_mut()
    # Probe values 100..199 — disjoint from {1, 2, 3}.
    for i in range(100):
        ptr[i] = Scalar[DType.int64](Int64(100 + i))

    var mask = in_list_mask_int64(keys, il)
    assert_equal(mask.length, 100)
    # Zero false positives.
    assert_equal(mask.true_count(), 0)


def test_in_list_mask_partial_overlap() raises:
    # Build has 5 keys; probe has 1024 rows where every 100th matches.
    var build = List[Int64]()
    build.append(0)
    build.append(100)
    build.append(200)
    build.append(300)
    build.append(400)
    var il_opt = InListFilter.try_from_int64(build)
    assert_true(il_opt.__bool__())
    var il = il_opt.take()

    var keys = PrimitiveArray[DType.int64].allocate(1024)
    var ptr = keys._typed_ptr_mut()
    for i in range(1024):
        ptr[i] = Scalar[DType.int64](Int64(i))

    var mask = in_list_mask_int64(keys, il)
    assert_equal(mask.length, 1024)
    # Exactly 5 rows match (0, 100, 200, 300, 400).
    assert_equal(mask.true_count(), 5)
    assert_true(mask.get(0))
    assert_true(mask.get(100))
    assert_true(mask.get(200))
    assert_true(mask.get(300))
    assert_true(mask.get(400))


def test_in_list_mask_empty_keys() raises:
    var build = List[Int64]()
    build.append(7)
    var il_opt = InListFilter.try_from_int64(build)
    assert_true(il_opt.__bool__())

    var keys = PrimitiveArray[DType.int64].allocate(0)
    var il = il_opt.take()
    var mask = in_list_mask_int64(keys, il)
    assert_equal(mask.length, 0)
    assert_equal(mask.true_count(), 0)


# -----------------------------------------------------------------------------
# Composability: chaining range -> in-list -> bloom (the production
# tier order in `parquet_source.mojo:1374-1412`) does not over-prune.
# We don't run bloom here (separate test file); we verify range + in-list
# composition via an `eval_and`-equivalent intersection.
# -----------------------------------------------------------------------------
def test_range_plus_in_list_no_over_prune() raises:
    # Build keys = {10, 20, 30}. Range = [10, 30]. Probe = [0, 50).
    var build = List[Int64]()
    build.append(10)
    build.append(20)
    build.append(30)
    var il_opt = InListFilter.try_from_int64(build)
    assert_true(il_opt.__bool__())
    var il = il_opt.take()
    var rf = RangeFilter.new_int64(10, 30)

    var keys = PrimitiveArray[DType.int64].allocate(50)
    var ptr = keys._typed_ptr_mut()
    for i in range(50):
        ptr[i] = Scalar[DType.int64](Int64(i))

    var r_mask = range_mask_int64(keys, rf)
    var il_mask = in_list_mask_int64(keys, il)

    # Range admits 21 rows (10..30 inclusive); in-list admits 3 rows
    # ({10, 20, 30}). Intersection: 3 rows.
    assert_equal(r_mask.true_count(), 21)
    assert_equal(il_mask.true_count(), 3)

    # Manual AND: only the 3 in-list keys survive.
    for i in range(50):
        var both = r_mask.get(i) and il_mask.get(i)
        var expected = (i == 10) or (i == 20) or (i == 30)
        assert_equal(both, expected)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
