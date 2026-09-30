# =============================================================================
# Bloom-filter primitive unit tests
# =============================================================================
#
# Direct correctness + FPR tests on `komira_core.collections.bloom_filter
# .BloomFilter`, independent of the parquet integration tests; this is the
# primitive coverage the bloom-pushdown feature relies on.
#
# Five properties verified:
#   1. No false negatives -- every inserted key is reported as
#      `might_contain == True`.
#   2. False-positive rate is within 2x of the configured 1% FPP for
#      with_ndv_fpp-sized filters.
#   3. Sizing helpers respect the documented bounds (32 B floor, power-of-2,
#      block-aligned).
#   4. Sparse-key inserts round-trip correctly.
#   5. Disjoint-set rejection (sanity).
#
# These guard the bloom primitive that bloom-filter pushdown depends on.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal

from komira_core.collections.bloom_filter import BloomFilter, HashFamily


# Replica of `join._hash_join_key` / bloom `_join_fib_hash` — the caller-side
# hash the JOIN-BLOOM-FIB reuse path passes to `might_contain_join_key` /
# `insert_join_key`. If this drifts from the module-internal `_join_fib_hash`,
# `test_fibonacci_join_reuse_equals_dispatch` will fail (a probe key would
# disagree between the reuse path and the family-dispatch path).
comptime _FIB_HASH_CONST: UInt64 = 0x9E3779B97F4A7C15


def _fib(key: Int64) -> UInt64:
    var h = UInt64(key) * _FIB_HASH_CONST
    h = h ^ (h >> 32)
    return h


def test_no_false_negatives_dense() raises:
    """Every key inserted into a small filter must report `might_contain == True`."""
    var bf = BloomFilter.with_ndv_fpp(1024, 0.01)
    for i in range(1024):
        bf.insert_int64(Int64(i + 1))
    for i in range(1024):
        assert_true(
            bf.might_contain_int64(Int64(i + 1)),
            "inserted key " + String(i + 1) + " must be present",
        )


def test_no_false_negatives_sparse() raises:
    """Every inserted key in a sparse 100K filter must round-trip."""
    var bf = BloomFilter.with_ndv_fpp(100_000, 0.01)
    for i in range(100):
        # Keys spaced by 1 << 16 to exercise diverse hash distributions.
        bf.insert_int64(Int64(i << 16))
    for i in range(100):
        assert_true(
            bf.might_contain_int64(Int64(i << 16)),
            "sparse inserted key must be present",
        )


def test_fpr_within_2x_of_target() raises:
    """1% FPP filter on 10K NDVs: probe 100K non-inserted keys, expect <= 2% FP."""
    var bf = BloomFilter.with_ndv_fpp(10_000, 0.01)
    for i in range(10_000):
        bf.insert_int64(Int64(i + 1))
    var fp_count = 0
    var probes = 100_000
    for j in range(probes):
        var k = Int64(j + 100_000_000)  # non-overlapping range
        if bf.might_contain_int64(k):
            fp_count += 1
    var fpr = Float64(fp_count) / Float64(probes)
    # Allow up to 2x the configured FPP (FNV-1a is weaker than xxhash; we
    # accept some looseness while keeping the test deterministic). On a
    # well-tuned bloom this is typically <1%.
    assert_true(
        fpr < 0.02,
        "FPR " + String(fpr) + " exceeded 2x of 1% target",
    )


def test_create_rounds_up_to_power_of_two() raises:
    """`BloomFilter.create(n)` rounds n up to the next power of two,
    clamped to [32 B, 128 MiB], block-size aligned."""
    # Tiny request -> floor of 32 B.
    var bf32 = BloomFilter.create(1)
    assert_equal(bf32.num_bytes, 32)
    assert_equal(bf32.num_blocks, 1)

    # Mid-range -> next power of two.
    var bf256 = BloomFilter.create(200)  # 200 -> 256
    assert_equal(bf256.num_bytes, 256)
    assert_equal(bf256.num_blocks, 8)

    # Already power of two -> unchanged.
    var bf512 = BloomFilter.create(512)
    assert_equal(bf512.num_bytes, 512)


def test_disjoint_filters_dont_collide() raises:
    """Two filters with disjoint key ranges should report no overlap."""
    var bf_a = BloomFilter.with_ndv_fpp(1000, 0.01)
    var bf_b = BloomFilter.with_ndv_fpp(1000, 0.01)
    for i in range(1000):
        bf_a.insert_int64(Int64(i))
        bf_b.insert_int64(Int64(i + 1_000_000))
    # bf_a should NOT contain B's keys (with high probability — 1% FPR).
    var fp = 0
    for i in range(1000):
        if bf_a.might_contain_int64(Int64(i + 1_000_000)):
            fp += 1
    var rate = Float64(fp) / 1000.0
    assert_true(
        rate < 0.05,  # 5x slack -- 1% target on 1K probes is noisy
        "A's filter false-positive rate on B's keys: " + String(rate),
    )


def test_fibonacci_join_no_false_negatives() raises:
    """JOIN-BLOOM-FIB: a FIBONACCI_JOIN bloom must never reject an inserted key.

    Guards the build/probe hash agreement: `insert_int64` writes bits with
    `_join_fib_hash` (family dispatch) and `might_contain_int64` reads them
    with the same hash. If they drifted, an inserted key could be rejected —
    a silent-wrong-result semi-join bug.
    """
    var bf = BloomFilter.with_ndv_fpp(4096, 0.01, HashFamily.fibonacci_join())
    for i in range(4096):
        bf.insert_int64(Int64(i * 2654435761 + 7))
    for i in range(4096):
        assert_true(
            bf.might_contain_int64(Int64(i * 2654435761 + 7)),
            "fib-join inserted key must be present",
        )


def test_fibonacci_join_reuse_equals_dispatch() raises:
    """The reuse path (`might_contain_join_key` with the precomputed fib hash)
    must be byte-identical to the family-dispatch path (`might_contain_int64`)
    for EVERY probe key — members and non-members alike. This is the core
    correctness invariant of the lever: a converted probe site and an
    unconverted probe site on the SAME fib bloom always agree.
    """
    var bf = BloomFilter.with_ndv_fpp(8192, 0.01, HashFamily.fibonacci_join())
    for i in range(8192):
        var k = Int64(i * 1000003 + 1)
        bf.insert_join_key(k, _fib(k))  # build via the reuse path
    # Members must round-trip; every probe (member or not) must agree between
    # the reuse and dispatch paths.
    for j in range(50_000):
        var k = Int64(j * 7919 - 123456789)
        assert_equal(
            bf.might_contain_join_key(k, _fib(k)),
            bf.might_contain_int64(k),
            "reuse vs dispatch disagreed on key " + String(k),
        )


def test_insert_join_key_matches_insert_int64() raises:
    """`insert_join_key(k, _fib(k))` and `insert_int64(k)` on a FIBONACCI_JOIN
    bloom must write identical bits, so a serial-build (reuse) bloom and a
    dispatch-build bloom are indistinguishable to any probe.
    """
    var a = BloomFilter.with_ndv_fpp(4096, 0.01, HashFamily.fibonacci_join())
    var b = BloomFilter.with_ndv_fpp(4096, 0.01, HashFamily.fibonacci_join())
    for i in range(4096):
        var k = Int64(i * 2246822519 + 13)
        a.insert_int64(k)
        b.insert_join_key(k, _fib(k))
    for j in range(20_000):
        var k = Int64(j * 6151 + 99)
        assert_equal(
            a.might_contain_int64(k),
            b.might_contain_int64(k),
            "insert_int64 vs insert_join_key produced different bits",
        )


def test_fibonacci_join_fpr_within_2x() raises:
    """FIBONACCI_JOIN bloom FPR on 10K NDVs must stay within 2x of the 1%
    target — guards the Fibonacci-hash avalanche quality (the FPP risk of the
    lever: a multiplicative hash could have worse block/bit selection than
    xxHash64 and blow up the false-positive rate)."""
    var bf = BloomFilter.with_ndv_fpp(10_000, 0.01, HashFamily.fibonacci_join())
    for i in range(10_000):
        bf.insert_int64(Int64(i + 1))
    var fp_count = 0
    var probes = 100_000
    for j in range(probes):
        var k = Int64(j + 100_000_000)  # non-overlapping range
        if bf.might_contain_int64(k):
            fp_count += 1
    var fpr = Float64(fp_count) / Float64(probes)
    assert_true(
        fpr < 0.02,
        "fib-join FPR " + String(fpr) + " exceeded 2x of 1% target",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_no_false_negatives_dense]()
    suite.test[test_no_false_negatives_sparse]()
    suite.test[test_fpr_within_2x_of_target]()
    suite.test[test_create_rounds_up_to_power_of_two]()
    suite.test[test_disjoint_filters_dont_collide]()
    suite.test[test_fibonacci_join_no_false_negatives]()
    suite.test[test_fibonacci_join_reuse_equals_dispatch]()
    suite.test[test_insert_join_key_matches_insert_int64]()
    suite.test[test_fibonacci_join_fpr_within_2x]()
    suite^.run()
