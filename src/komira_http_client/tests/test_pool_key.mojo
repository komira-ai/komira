# =============================================================================
# src/komira_http_client/tests/test_pool_key.mojo — PoolKey 4-field bucket id
# =============================================================================
# Asserts:
# verify_mode pool-key isolation.

from std.testing import assert_equal, assert_false, assert_true

from komira_http_client.pool import (
    ALPN_H1,
    ALPN_H2,
    ALPN_UNKNOWN,
    PoolKey,
    PoolSizingKnobs,
    SCHEME_HTTP,
    SCHEME_HTTPS,
    VERIFY_PEER,
    VERIFY_SKIP,
)


def test_construct_via_http_factory() raises:
    var k = PoolKey.http(String("127.0.0.1"), UInt16(8080))
    assert_equal(Int(k.scheme), Int(SCHEME_HTTP))
    assert_equal(k.host, String("127.0.0.1"))
    assert_equal(Int(k.port), 8080)
    assert_equal(Int(k.verify_mode), Int(VERIFY_PEER))


def test_construct_via_https_factory() raises:
    var k = PoolKey.https(String("api.example.com"), UInt16(443), VERIFY_PEER)
    assert_equal(Int(k.scheme), Int(SCHEME_HTTPS))
    assert_equal(k.host, String("api.example.com"))
    assert_equal(Int(k.port), 443)
    assert_equal(Int(k.verify_mode), Int(VERIFY_PEER))


def test_eq_all_fields_match() raises:
    var a = PoolKey.https(String("example.com"), UInt16(443), VERIFY_PEER)
    var b = PoolKey.https(String("example.com"), UInt16(443), VERIFY_PEER)
    assert_true(a == b)
    assert_false(a != b)


def test_ne_scheme_differs() raises:
    var http = PoolKey.http(String("example.com"), UInt16(80))
    var https = PoolKey.https(String("example.com"), UInt16(80), VERIFY_PEER)
    assert_false(http == https)
    assert_true(http != https)


def test_ne_host_differs() raises:
    var a = PoolKey.http(String("a.example.com"), UInt16(80))
    var b = PoolKey.http(String("b.example.com"), UInt16(80))
    assert_false(a == b)
    assert_true(a != b)


def test_ne_port_differs() raises:
    var a = PoolKey.http(String("example.com"), UInt16(80))
    var b = PoolKey.http(String("example.com"), UInt16(8080))
    assert_false(a == b)
    assert_true(a != b)


def test_ne_verify_mode_isolation() raises:
    """ACCEPTANCE GATE (d): verify_mode separates pool buckets.

    A connection opened with VERIFY_PEER MUST NEVER share a bucket
    with one opened with VERIFY_SKIP — that is a silent security
    downgrade.
    """
    var verify = PoolKey.https(String("example.com"), UInt16(443), VERIFY_PEER)
    var skip = PoolKey.https(String("example.com"), UInt16(443), VERIFY_SKIP)
    assert_false(verify == skip)
    assert_true(verify != skip)


def test_hash_all_fields_match() raises:
    """Same 4-field PoolKey -> same hash. Equal-hash is necessary but
    NOT sufficient (linear-probe pool resolves via hash + __eq__).
    """
    var a = PoolKey.https(String("example.com"), UInt16(443), VERIFY_PEER)
    var b = PoolKey.https(String("example.com"), UInt16(443), VERIFY_PEER)
    assert_equal(a.hash_u64(), b.hash_u64())


def test_hash_verify_mode_differs() raises:
    """A different verify_mode produces a different hash (the bucket
    map sees them as separate buckets up front, not just on __eq__
    tiebreak).
    """
    var verify = PoolKey.https(String("example.com"), UInt16(443), VERIFY_PEER)
    var skip = PoolKey.https(String("example.com"), UInt16(443), VERIFY_SKIP)
    # FNV-1a is good enough that single-bit input change produces a
    # different output for our 4-field shape (verified manually).
    assert_true(verify.hash_u64() != skip.hash_u64())


def test_hash_host_differs() raises:
    var a = PoolKey.http(String("a.example.com"), UInt16(80))
    var b = PoolKey.http(String("z.example.com"), UInt16(80))
    assert_true(a.hash_u64() != b.hash_u64())


def test_pool_sizing_defaults() raises:
    var k = PoolSizingKnobs.defaults()
    assert_equal(k.max_conns_per_host, 32)
    assert_equal(k.max_idle_per_host, 16)
    assert_equal(k.recv_ring_size, 64 * 1024)
    assert_equal(k.idle_threshold_us, 60_000_000)


def test_pool_sizing_field_assign() raises:
    var k = PoolSizingKnobs(
        max_conns_per_host=4,
        max_idle_per_host=2,
        recv_ring_size=16384,
        idle_threshold_us=1_000_000,
    )
    assert_equal(k.max_conns_per_host, 4)
    assert_equal(k.max_idle_per_host, 2)
    assert_equal(k.recv_ring_size, 16384)
    assert_equal(k.idle_threshold_us, 1_000_000)


def test_default_alpn_unknown_via_factory() raises:
    """Existing factories default negotiated_alpn to
    ALPN_UNKNOWN so h1 callers stay backward-compatible.
    """
    var k1 = PoolKey.http(String("example.com"), UInt16(80))
    assert_equal(Int(k1.negotiated_alpn), Int(ALPN_UNKNOWN))
    var k2 = PoolKey.https(
        String("example.com"), UInt16(443), VERIFY_PEER,
    )
    assert_equal(Int(k2.negotiated_alpn), Int(ALPN_UNKNOWN))


def test_https_h2_factory_sets_alpn_h2() raises:
    """`https_h2` factory tags the bucket with ALPN_H2 so the
    h2 multiplex pool's keys never collide with the h1 PerCorePool's keys
    at the same origin.
    """
    var k = PoolKey.https_h2(
        String("example.com"), UInt16(443), VERIFY_PEER,
    )
    assert_equal(Int(k.scheme), Int(SCHEME_HTTPS))
    assert_equal(Int(k.negotiated_alpn), Int(ALPN_H2))


def test_ne_alpn_isolation_h1_vs_h2() raises:
    """Same (scheme, host, port,
    verify_mode) but different negotiated_alpn => DIFFERENT bucket.

    This is the load-bearing safety property: an h1 connection can
    NEVER be returned to a checkout that expected an h2 multiplex
    conn, and vice versa.
    """
    var k_h1 = PoolKey.https(
        String("example.com"), UInt16(443), VERIFY_PEER,
    )  # defaults to ALPN_UNKNOWN
    var k_h2 = PoolKey.https_h2(
        String("example.com"), UInt16(443), VERIFY_PEER,
    )
    assert_false(k_h1 == k_h2)
    assert_true(k_h1 != k_h2)


def test_hash_alpn_isolation_h1_vs_h2() raises:
    """ALPN discriminator changes the hash so the bucket-map's
    linear probe sees them as separate buckets up front.
    """
    var k_h1 = PoolKey.https(
        String("example.com"), UInt16(443), VERIFY_PEER,
    )
    var k_h2 = PoolKey.https_h2(
        String("example.com"), UInt16(443), VERIFY_PEER,
    )
    assert_true(k_h1.hash_u64() != k_h2.hash_u64())


def test_explicit_alpn_h1_constructor() raises:
    """The 5-arg constructor accepts ALPN_H1 explicitly. Used
    by callers that want to force-segment h1 buckets when the same
    origin also serves h2 conns elsewhere in the same process."""
    var k = PoolKey(
        scheme=SCHEME_HTTPS,
        host=String("example.com"),
        port=UInt16(443),
        verify_mode=VERIFY_PEER,
        negotiated_alpn=ALPN_H1,
    )
    assert_equal(Int(k.negotiated_alpn), Int(ALPN_H1))
    # h1-explicit and h2-explicit are also disjoint buckets.
    var k_h2 = PoolKey.https_h2(
        String("example.com"), UInt16(443), VERIFY_PEER,
    )
    assert_false(k == k_h2)


def main() raises:
    test_construct_via_http_factory()
    test_construct_via_https_factory()
    test_eq_all_fields_match()
    test_ne_scheme_differs()
    test_ne_host_differs()
    test_ne_port_differs()
    test_ne_verify_mode_isolation()
    test_hash_all_fields_match()
    test_hash_verify_mode_differs()
    test_hash_host_differs()
    test_pool_sizing_defaults()
    test_pool_sizing_field_assign()
    # negotiated_alpn discriminator
    test_default_alpn_unknown_via_factory()
    test_https_h2_factory_sets_alpn_h2()
    test_ne_alpn_isolation_h1_vs_h2()
    test_hash_alpn_isolation_h1_vs_h2()
    test_explicit_alpn_h1_constructor()
    print("OK: test_pool_key")
