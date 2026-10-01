"""SessionCache unit tests.

Tests the per-PoolKey LRU bounded TLS session-ticket cache in isolation
(no TLS handshake, no network, no s2n FFI). Exercises:

  1. Empty cache: lookup returns None for any key.
  2. Store + lookup roundtrip: bytes preserved exactly.
  3. Multiple distinct keys coexist.
  4. Same-key re-store REPLACES in place (same slot, new blob).
  5. LRU eviction: insert past capacity evicts the least-recently-used.
  6. Lookup-hit bumps last_used (prevents premature LRU eviction).
  7. PoolKey isolation by verify_mode.
  8. PoolKey isolation by port / scheme / host / negotiated_alpn.
  9. Empty-blob store raises.
 10. Clear empties the cache.

The session-resumption-via-handshake test (with real TLS handshake
through socketpair) lives at test_L1_tls_session_resumption.mojo —
that's the end-to-end resumption test.
"""

from std.testing import assert_equal, assert_false, assert_true

from komira_http.client.pool import (
    ALPN_H1,
    ALPN_H2,
    ALPN_UNKNOWN,
    PoolKey,
    SCHEME_HTTP,
    SCHEME_HTTPS,
    VERIFY_PEER,
    VERIFY_SKIP,
)
from komira_http.client.session_cache import (
    DEFAULT_MAX_SESSION_CACHE_ENTRIES,
    SessionCache,
)


# -----------------------------------------------------------------------------
# Test helpers
# -----------------------------------------------------------------------------


def _key(host: String, port: UInt16, verify: UInt8 = VERIFY_PEER) -> PoolKey:
    """Construct a PoolKey for HTTPS with the given host/port/verify_mode."""
    return PoolKey(
        scheme=SCHEME_HTTPS,
        host=host,
        port=port,
        verify_mode=verify,
        negotiated_alpn=ALPN_UNKNOWN,
    )


def _blob(byte_val: UInt8, n: Int) -> List[UInt8]:
    """Construct a List[UInt8] of length n filled with `byte_val`."""
    var b = List[UInt8](capacity=n)
    var i = 0
    while i < n:
        b.append(byte_val)
        i = i + 1
    return b^


def _blobs_equal(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    var i = 0
    while i < len(a):
        if a[i] != b[i]:
            return False
        i = i + 1
    return True


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_empty_lookup_returns_none() raises:
    """Brand-new cache: lookup of any key returns None."""
    print("  test_empty_lookup_returns_none...")
    var cache = SessionCache.with_defaults()
    var k = _key(String("example.com"), UInt16(443))
    var result = cache.lookup(k, 100)
    assert_false(result.__bool__())
    assert_equal(cache.len(), 0)
    print("    OK")


def test_store_lookup_roundtrip() raises:
    """Store a blob, look it up — bytes preserved exactly."""
    print("  test_store_lookup_roundtrip...")
    var cache = SessionCache.with_defaults()
    var k = _key(String("example.com"), UInt16(443))
    var b = _blob(UInt8(0xAB), 32)
    cache.store(k.copy(), b^, 100)
    assert_equal(cache.len(), 1)
    var fetched = cache.lookup(k, 200)
    assert_true(fetched.__bool__())
    var got = fetched.take()
    assert_equal(len(got), 32)
    var i = 0
    while i < 32:
        assert_equal(got[i], UInt8(0xAB))
        i = i + 1
    print("    OK")


def test_lookup_hit_returns_copy_not_reference() raises:
    """The cache's blob persists across multiple lookups — the returned
    bytes are a copy. Repeated lookup of the same key returns valid bytes
    every time."""
    print("  test_lookup_hit_returns_copy_not_reference...")
    var cache = SessionCache.with_defaults()
    var k = _key(String("a.test"), UInt16(443))
    var b = _blob(UInt8(0x42), 16)
    cache.store(k.copy(), b^, 100)
    # First lookup: should hit.
    var r1 = cache.lookup(k, 200)
    assert_true(r1.__bool__())
    _ = r1.take()
    # Second lookup of the same key: should ALSO hit (cache retained
    # original; resumption tickets are NOT single-use).
    var r2 = cache.lookup(k, 300)
    assert_true(r2.__bool__())
    var got2 = r2.take()
    assert_equal(len(got2), 16)
    assert_equal(cache.len(), 1)
    print("    OK")


def test_distinct_keys_coexist() raises:
    """Multiple distinct PoolKeys each get their own entry."""
    print("  test_distinct_keys_coexist...")
    var cache = SessionCache.with_defaults()
    var k1 = _key(String("a.example.com"), UInt16(443))
    var k2 = _key(String("b.example.com"), UInt16(443))
    var k3 = _key(String("c.example.com"), UInt16(443))
    cache.store(k1.copy(), _blob(UInt8(1), 8)^, 100)
    cache.store(k2.copy(), _blob(UInt8(2), 8)^, 200)
    cache.store(k3.copy(), _blob(UInt8(3), 8)^, 300)
    assert_equal(cache.len(), 3)
    var r1 = cache.lookup(k1, 400)
    var r2 = cache.lookup(k2, 500)
    var r3 = cache.lookup(k3, 600)
    assert_true(r1.__bool__())
    assert_true(r2.__bool__())
    assert_true(r3.__bool__())
    var b1 = r1.take()
    var b2 = r2.take()
    var b3 = r3.take()
    assert_equal(b1[0], UInt8(1))
    assert_equal(b2[0], UInt8(2))
    assert_equal(b3[0], UInt8(3))
    print("    OK")


def test_same_key_restore_replaces_in_place() raises:
    """Re-storing the same key replaces the existing blob (newest wins).
    The cache size stays at 1, and the lookup returns the new bytes.
    """
    print("  test_same_key_restore_replaces_in_place...")
    var cache = SessionCache.with_defaults()
    var k = _key(String("same.example"), UInt16(443))
    cache.store(k.copy(), _blob(UInt8(0xAA), 8)^, 100)
    assert_equal(cache.len(), 1)
    cache.store(k.copy(), _blob(UInt8(0xBB), 8)^, 200)
    assert_equal(cache.len(), 1)  # NOT 2 — replaced in place.
    var fetched = cache.lookup(k, 300)
    assert_true(fetched.__bool__())
    var got = fetched.take()
    assert_equal(got[0], UInt8(0xBB))  # newest wins
    print("    OK")


def test_lru_evicts_oldest_at_capacity() raises:
    """Insert 4 entries with capacity 3 — the LRU entry is evicted."""
    print("  test_lru_evicts_oldest_at_capacity...")
    var cache = SessionCache.new(3)
    var k1 = _key(String("a.test"), UInt16(443))
    var k2 = _key(String("b.test"), UInt16(443))
    var k3 = _key(String("c.test"), UInt16(443))
    var k4 = _key(String("d.test"), UInt16(443))
    # Store 3 entries with increasing last_used.
    cache.store(k1.copy(), _blob(UInt8(1), 8)^, 100)
    cache.store(k2.copy(), _blob(UInt8(2), 8)^, 200)
    cache.store(k3.copy(), _blob(UInt8(3), 8)^, 300)
    assert_equal(cache.len(), 3)
    # Insert a 4th — k1 (oldest) should be evicted.
    cache.store(k4.copy(), _blob(UInt8(4), 8)^, 400)
    assert_equal(cache.len(), 3)
    # k1 should now miss.
    var r1 = cache.lookup(k1, 500)
    assert_false(r1.__bool__())
    # k2, k3, k4 should still hit.
    assert_true(cache.contains(k2))
    assert_true(cache.contains(k3))
    assert_true(cache.contains(k4))
    print("    OK")


def test_lookup_bumps_last_used_prevents_eviction() raises:
    """Recently-used entries survive eviction; the eviction picks the
    actual LRU entry. After lookup-hit on k1 (bumping its last_used),
    inserting a new entry over capacity evicts k2 (the now-oldest) not k1.
    """
    print("  test_lookup_bumps_last_used_prevents_eviction...")
    var cache = SessionCache.new(3)
    var k1 = _key(String("a.test"), UInt16(443))
    var k2 = _key(String("b.test"), UInt16(443))
    var k3 = _key(String("c.test"), UInt16(443))
    var k4 = _key(String("d.test"), UInt16(443))
    cache.store(k1.copy(), _blob(UInt8(1), 8)^, 100)
    cache.store(k2.copy(), _blob(UInt8(2), 8)^, 200)
    cache.store(k3.copy(), _blob(UInt8(3), 8)^, 300)
    # Bump k1's last_used by looking it up.
    var _r = cache.lookup(k1, 350)
    assert_true(_r.__bool__())
    # Now insert k4 — should evict k2 (now the oldest at 200).
    cache.store(k4.copy(), _blob(UInt8(4), 8)^, 400)
    assert_true(cache.contains(k1))  # bumped — survived
    assert_false(cache.contains(k2))  # evicted (oldest after bump)
    assert_true(cache.contains(k3))
    assert_true(cache.contains(k4))
    print("    OK")


def test_verify_mode_isolation() raises:
    """Entries stored under VERIFY_PEER MUST NOT match a lookup under
    VERIFY_SKIP for the same host:port. Mirror of
    pool.mojo's bucket isolation invariant."""
    print("  test_verify_mode_isolation...")
    var cache = SessionCache.with_defaults()
    var k_peer = _key(String("h.test"), UInt16(443), VERIFY_PEER)
    var k_skip = _key(String("h.test"), UInt16(443), VERIFY_SKIP)
    cache.store(k_peer.copy(), _blob(UInt8(0x77), 16)^, 100)
    # Lookup under VERIFY_PEER hits.
    var hit = cache.lookup(k_peer, 200)
    assert_true(hit.__bool__())
    _ = hit.take()
    # Lookup under VERIFY_SKIP MISSES — different bucket.
    var miss = cache.lookup(k_skip, 300)
    assert_false(miss.__bool__())
    print("    OK")


def test_port_isolation() raises:
    """Same host, different port → distinct cache entries."""
    print("  test_port_isolation...")
    var cache = SessionCache.with_defaults()
    var k_443 = _key(String("h.test"), UInt16(443))
    var k_8443 = _key(String("h.test"), UInt16(8443))
    cache.store(k_443.copy(), _blob(UInt8(0x10), 8)^, 100)
    assert_true(cache.contains(k_443))
    assert_false(cache.contains(k_8443))
    var miss = cache.lookup(k_8443, 200)
    assert_false(miss.__bool__())
    print("    OK")


def test_host_isolation() raises:
    """Different host strings → distinct cache entries even on same
    port + verify_mode."""
    print("  test_host_isolation...")
    var cache = SessionCache.with_defaults()
    var ka = _key(String("a.example.com"), UInt16(443))
    var kb = _key(String("b.example.com"), UInt16(443))
    cache.store(ka.copy(), _blob(UInt8(1), 8)^, 100)
    assert_true(cache.contains(ka))
    assert_false(cache.contains(kb))
    print("    OK")


def test_alpn_isolation_distinct_keys() raises:
    """PoolKeys with different negotiated_alpn discriminator are
    distinct cache buckets — though the TlsConnector uses ALPN_UNKNOWN
    uniformly, the isolation is preserved if a caller uses the API with
    explicit ALPN values."""
    print("  test_alpn_isolation_distinct_keys...")
    var cache = SessionCache.with_defaults()
    var k_unknown = PoolKey(
        scheme=SCHEME_HTTPS,
        host=String("h.test"),
        port=UInt16(443),
        verify_mode=VERIFY_PEER,
        negotiated_alpn=ALPN_UNKNOWN,
    )
    var k_h1 = PoolKey(
        scheme=SCHEME_HTTPS,
        host=String("h.test"),
        port=UInt16(443),
        verify_mode=VERIFY_PEER,
        negotiated_alpn=ALPN_H1,
    )
    var k_h2 = PoolKey(
        scheme=SCHEME_HTTPS,
        host=String("h.test"),
        port=UInt16(443),
        verify_mode=VERIFY_PEER,
        negotiated_alpn=ALPN_H2,
    )
    cache.store(k_unknown.copy(), _blob(UInt8(0xCC), 8)^, 100)
    assert_true(cache.contains(k_unknown))
    assert_false(cache.contains(k_h1))
    assert_false(cache.contains(k_h2))
    print("    OK")


def test_scheme_isolation() raises:
    """SCHEME_HTTP and SCHEME_HTTPS are distinct buckets (defensive —
    the connector only stores HTTPS, but the cache MUST honor the
    isolation invariant)."""
    print("  test_scheme_isolation...")
    var cache = SessionCache.with_defaults()
    var k_https = _key(String("h.test"), UInt16(443))
    var k_http = PoolKey(
        scheme=SCHEME_HTTP,
        host=String("h.test"),
        port=UInt16(443),
        verify_mode=VERIFY_PEER,
        negotiated_alpn=ALPN_UNKNOWN,
    )
    cache.store(k_https.copy(), _blob(UInt8(0x55), 8)^, 100)
    assert_true(cache.contains(k_https))
    assert_false(cache.contains(k_http))
    print("    OK")


def test_empty_blob_raises() raises:
    """Storing an empty blob raises — a 0-byte session blob is
    nonsensical (s2n_connection_get_session never returns 0 if length
    > 0; this is a defensive lint)."""
    print("  test_empty_blob_raises...")
    var cache = SessionCache.with_defaults()
    var k = _key(String("h.test"), UInt16(443))
    var threw = False
    try:
        var empty = List[UInt8]()
        cache.store(k.copy(), empty^, 100)
    except:
        threw = True
    assert_true(threw)
    assert_equal(cache.len(), 0)
    print("    OK")


def test_clear_empties_cache() raises:
    """clear() drops all entries; len() returns to 0; subsequent lookup
    misses."""
    print("  test_clear_empties_cache...")
    var cache = SessionCache.with_defaults()
    var k1 = _key(String("a.test"), UInt16(443))
    var k2 = _key(String("b.test"), UInt16(443))
    cache.store(k1.copy(), _blob(UInt8(1), 8)^, 100)
    cache.store(k2.copy(), _blob(UInt8(2), 8)^, 200)
    assert_equal(cache.len(), 2)
    cache.clear()
    assert_equal(cache.len(), 0)
    var miss = cache.lookup(k1, 300)
    assert_false(miss.__bool__())
    print("    OK")


def test_capacity_clamp() raises:
    """SessionCache.new(0) clamps to 1; new(negative) also clamps to 1."""
    print("  test_capacity_clamp...")
    var c1 = SessionCache.new(0)
    assert_equal(c1.capacity(), 1)
    var c2 = SessionCache.new(-5)
    assert_equal(c2.capacity(), 1)
    var c3 = SessionCache.new(100)
    assert_equal(c3.capacity(), 100)
    print("    OK")


def test_default_capacity() raises:
    """with_defaults() uses DEFAULT_MAX_SESSION_CACHE_ENTRIES (1024)."""
    print("  test_default_capacity...")
    var c = SessionCache.with_defaults()
    assert_equal(c.capacity(), DEFAULT_MAX_SESSION_CACHE_ENTRIES)
    assert_equal(c.capacity(), 1024)
    print("    OK")


def test_evict_one_returns_false_on_empty() raises:
    """evict_one on an empty cache returns False (nothing to evict)."""
    print("  test_evict_one_returns_false_on_empty...")
    var cache = SessionCache.with_defaults()
    assert_false(cache.evict_one(0))
    assert_equal(cache.len(), 0)
    print("    OK")


def test_evict_one_removes_lru() raises:
    """evict_one removes the LRU entry; subsequent contains() returns
    False for it."""
    print("  test_evict_one_removes_lru...")
    var cache = SessionCache.with_defaults()
    var k1 = _key(String("a.test"), UInt16(443))
    var k2 = _key(String("b.test"), UInt16(443))
    cache.store(k1.copy(), _blob(UInt8(1), 8)^, 100)
    cache.store(k2.copy(), _blob(UInt8(2), 8)^, 200)
    assert_equal(cache.len(), 2)
    assert_true(cache.evict_one(300))
    assert_equal(cache.len(), 1)
    # k1 (oldest) was evicted.
    assert_false(cache.contains(k1))
    assert_true(cache.contains(k2))
    print("    OK")


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------


def main() raises:
    print("== SessionCache unit tests ==")
    test_empty_lookup_returns_none()
    test_store_lookup_roundtrip()
    test_lookup_hit_returns_copy_not_reference()
    test_distinct_keys_coexist()
    test_same_key_restore_replaces_in_place()
    test_lru_evicts_oldest_at_capacity()
    test_lookup_bumps_last_used_prevents_eviction()
    test_verify_mode_isolation()
    test_port_isolation()
    test_host_isolation()
    test_alpn_isolation_distinct_keys()
    test_scheme_isolation()
    test_empty_blob_raises()
    test_clear_empties_cache()
    test_capacity_clamp()
    test_default_capacity()
    test_evict_one_returns_false_on_empty()
    test_evict_one_removes_lru()
    print("== SessionCache unit tests PASSED (18 tests) ==")
