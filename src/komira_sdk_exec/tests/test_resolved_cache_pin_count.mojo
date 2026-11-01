# =============================================================================
# Tests for the resolved cache's pin count: a pinned entry is protected from
# LRU eviction.
#
# The pin/unpin API is the contract an open paginated result relies on. Tests:
#   1. Pin survives an eviction wave at cap+1.
#   2. Multiple pins (refcount > 1) require matching unpins.
#   3. If EVERY entry is pinned, the next insert raises.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
)

from komira_sdk_exec.plan_compile_cache import (
    PlanCompileCache,
    ResolvedCacheEntry,
    RESOLVED_CACHE_CAP,
)


def _push(mut cache: PlanCompileCache, factory_h: UInt64, stats_h: UInt64) raises:
    var e = ResolvedCacheEntry(
        factory_hash=factory_h,
        stats_hash=stats_h,
        placeholder=String(""),
        last_access=UInt64(0),
    )
    cache.resolved_insert(factory_h, stats_h, e^)


def test_pin_survives_eviction_at_cap_plus_one() raises:
    """Pinned entry stays alive when cap+1 inserts force an eviction."""
    var cache = PlanCompileCache()
    for i in range(RESOLVED_CACHE_CAP):
        _push(cache, UInt64(7), UInt64(i))
    assert_equal(cache.resolved_len(), RESOLVED_CACHE_CAP)
    # Pin entry 0 (factory=7, stats=0).
    cache.pin_resolved(0)
    assert_true(cache.is_pinned(0))

    # Trigger eviction. Entry 0 is pinned; the LRU must pick entry 1
    # instead (the oldest unpinned).
    _push(cache, UInt64(7), UInt64(9001))
    assert_equal(cache.resolved_len(), RESOLVED_CACHE_CAP)

    # The pinned entry MUST still be reachable.
    assert_true(cache.resolved_lookup(UInt64(7), UInt64(0)))
    # Entry 1 (oldest unpinned) is gone.
    assert_false(cache.resolved_lookup(UInt64(7), UInt64(1)))


def test_pin_unpin_balance() raises:
    """Double-pin requires double-unpin before LRU can evict the entry."""
    var cache = PlanCompileCache()
    _push(cache, UInt64(11), UInt64(0))
    assert_false(cache.is_pinned(0))
    cache.pin_resolved(0)
    cache.pin_resolved(0)
    assert_true(cache.is_pinned(0))
    cache.unpin_resolved(0)
    # Still pinned (refcount went 2 -> 1, still > 0).
    assert_true(cache.is_pinned(0))
    cache.unpin_resolved(0)
    # Now unpinned.
    assert_false(cache.is_pinned(0))


def test_all_pinned_raises_on_overflow() raises:
    """If every entry is pinned, the next insert past cap raises."""
    var cache = PlanCompileCache()
    for i in range(RESOLVED_CACHE_CAP):
        _push(cache, UInt64(42), UInt64(i))
    # Pin every entry.
    for i in range(RESOLVED_CACHE_CAP):
        cache.pin_resolved(i)
    # The next insert must raise: nothing is evictable.
    with assert_raises(contains="all"):
        var e = ResolvedCacheEntry(
            factory_hash=UInt64(42),
            stats_hash=UInt64(9999),
            placeholder=String(""),
            last_access=UInt64(0),
        )
        cache.resolved_insert(UInt64(42), UInt64(9999), e^)


def main() raises:
    var suite = TestSuite()
    suite.test[test_pin_survives_eviction_at_cap_plus_one]()
    suite.test[test_pin_unpin_balance]()
    suite.test[test_all_pinned_raises_on_overflow]()
    suite^.run()
