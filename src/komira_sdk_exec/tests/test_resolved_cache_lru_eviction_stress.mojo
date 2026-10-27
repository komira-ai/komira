# =============================================================================
# Tests for Layer 2 LRU eviction at the cap (64) as a stress test.
#
# This stresses the cap by inserting RESOLVED_CACHE_CAP+1 distinct
# (factory_hash, stats_hash) tuples through the public cache API and
# verifies that the oldest unpinned entry is evicted.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
)

from komira_sdk_exec.plan_compile_cache import (
    PlanCompileCache,
    ResolvedCacheEntry,
    RESOLVED_CACHE_CAP,
)


def test_resolved_cache_evicts_oldest_at_cap_plus_one() raises:
    """Fill the cache to cap; inserting one more evicts entry 0 (FIFO at
    this point, since no entry was touched after insert).
    """
    var cache = PlanCompileCache()
    # Fill to cap.
    for i in range(RESOLVED_CACHE_CAP):
        var entry = ResolvedCacheEntry(
            factory_hash=UInt64(100),
            stats_hash=UInt64(i),
            placeholder=String("v") + String(i),
            last_access=UInt64(0),
        )
        cache.resolved_insert(UInt64(100), UInt64(i), entry^)
    assert_equal(cache.resolved_len(), RESOLVED_CACHE_CAP)

    # The 65th insert (i.e. one past cap) must evict the oldest.
    var extra = ResolvedCacheEntry(
        factory_hash=UInt64(100),
        stats_hash=UInt64(9999),
        placeholder=String("evicted-the-oldest"),
        last_access=UInt64(0),
    )
    cache.resolved_insert(UInt64(100), UInt64(9999), extra^)
    # Size stays at cap.
    assert_equal(cache.resolved_len(), RESOLVED_CACHE_CAP)
    # The newest is reachable.
    assert_true(cache.resolved_lookup(UInt64(100), UInt64(9999)))
    # The oldest (i=0) is GONE.
    assert_false(cache.resolved_lookup(UInt64(100), UInt64(0)))


def test_resolved_cache_eviction_walks_chronologically() raises:
    """Insert cap entries; touch the first 5 mid-loop; insert one more.

    The LRU victim must be the smallest last_access entry whose
    ref_count == 0. Since we touched entries 0..4 after insert, their
    last_access values are larger than entries 5..63's. The next eviction
    must fire on entry 5 (the oldest UNtouched one), NOT entry 0.
    """
    var cache = PlanCompileCache()
    for i in range(RESOLVED_CACHE_CAP):
        var entry = ResolvedCacheEntry(
            factory_hash=UInt64(200),
            stats_hash=UInt64(i),
            placeholder=String(""),
            last_access=UInt64(0),
        )
        cache.resolved_insert(UInt64(200), UInt64(i), entry^)
    # Touch entries 0..4 (bumps their last_access to a value past inserts).
    for i in range(5):
        _ = cache.resolved_lookup(UInt64(200), UInt64(i))

    # Now insert one more. The eviction must pick the smallest unpinned
    # last_access — that's entry 5 (oldest untouched), NOT entry 0.
    var extra = ResolvedCacheEntry(
        factory_hash=UInt64(200),
        stats_hash=UInt64(8888),
        placeholder=String(""),
        last_access=UInt64(0),
    )
    cache.resolved_insert(UInt64(200), UInt64(8888), extra^)
    assert_equal(cache.resolved_len(), RESOLVED_CACHE_CAP)

    # Touched entries 0..4 survive.
    for i in range(5):
        assert_true(cache.resolved_lookup(UInt64(200), UInt64(i)))

    # Entry 5 (oldest untouched) is gone.
    assert_false(cache.resolved_lookup(UInt64(200), UInt64(5)))

    # Entries 6..63 survive (still in the cache; just have small
    # last_access values).
    for i in range(6, RESOLVED_CACHE_CAP):
        assert_true(cache.resolved_lookup(UInt64(200), UInt64(i)))


def main() raises:
    var suite = TestSuite()
    suite.test[test_resolved_cache_evicts_oldest_at_cap_plus_one]()
    suite.test[test_resolved_cache_eviction_walks_chronologically]()
    suite^.run()
