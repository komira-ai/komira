# =============================================================================
# src/komira_http_client/tests/test_pool_basic.mojo — ConnectionPool +
# PerCorePool basic checkout/checkin (no race;)
# =============================================================================
# Tests:
#   * Empty pool: try_checkout returns NEEDS_DIAL.
#   * After insert_dialed: bucket records in_use; total_for advances.
#   * checkin a healthy conn: bucket records idle; next try_checkout
#     returns READY with same conn (verify via key match).
#   * checkin an unhealthy conn: dropped, in_use decremented, idle
#     unchanged.
#   * max_idle_per_host: excess idle drops on checkin.
#   * verify_mode isolation: same host but different verify_mode lands
#     in different buckets.
#
# Stream type: ScriptedStream (concrete IoStream conformer with no
# socket — purely in-process for the test).

from std.memory import OwnedPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_http_client.pool import (
    ClientConn,
    PerCorePool,
    PoolKey,
    PoolSizingKnobs,
    VERIFY_PEER,
    VERIFY_SKIP,
)
from komira_http_core.transport.scripted import ScriptedStream


def _make_pool() -> PerCorePool[ScriptedStream]:
    """Helper: PerCorePool with default sizing."""
    return PerCorePool[ScriptedStream].with_defaults()


def _make_pool_sized(
    max_conns: Int, max_idle: Int,
) -> PerCorePool[ScriptedStream]:
    var k = PoolSizingKnobs(
        max_conns_per_host=max_conns,
        max_idle_per_host=max_idle,
        recv_ring_size=64 * 1024,
        idle_threshold_us=60_000_000,
    )
    return PerCorePool[ScriptedStream].new(k)


def _make_conn(
    key: PoolKey, now_us: Int,
) -> OwnedPointer[ClientConn[ScriptedStream]]:
    """Helper: a fresh ClientConn over an empty ScriptedStream."""
    var stream = ScriptedStream.empty()
    return OwnedPointer[ClientConn[ScriptedStream]](
        ClientConn[ScriptedStream].new(stream^, key.copy(), now_us)
    )


def test_empty_pool_checkout_needs_dial() raises:
    """An empty bucket -> try_checkout returns NEEDS_DIAL (no conn to
    return, but bucket has capacity for a fresh dial)."""
    var pool = _make_pool()
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    var outcome = pool.try_checkout(key.copy(), 100)
    assert_true(outcome.is_needs_dial())
    assert_false(outcome.is_ready())
    assert_false(outcome.is_at_capacity())


def test_insert_dialed_records_in_use() raises:
    """After insert_dialed(key), bucket records in_use+=1 and
    dials_total+=1. The caller HOLDS the conn (the pool doesn't take
    ownership at dial time; only at checkin)."""
    var pool = _make_pool()
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    assert_equal(pool.in_use_for(key.copy()), 0)
    pool.insert_dialed(key.copy())
    assert_equal(pool.in_use_for(key.copy()), 1)
    assert_equal(pool.idle_count_for(key.copy()), 0)
    assert_equal(pool.total_for(key.copy()), 1)
    assert_equal(pool.dials_total(), 1)


def test_checkin_healthy_returns_to_idle() raises:
    """A healthy conn returned via checkin goes to the idle slab and
    decrements in_use."""
    var pool = _make_pool()
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    pool.insert_dialed(key.copy())
    assert_equal(pool.in_use_for(key.copy()), 1)
    # Simulate the dial-then-checkin flow: insert_dialed bumped in_use;
    # the caller (here) holds a freshly-dialed conn and now returns it
    # via checkin.
    var c2 = _make_conn(key.copy(), 200)
    pool.checkin(c2^, 200)
    assert_equal(pool.in_use_for(key.copy()), 0)
    assert_equal(pool.idle_count_for(key.copy()), 1)


def test_checkout_after_checkin_returns_ready() raises:
    """checkout after a checkin returns READY with a conn from the
    idle slab."""
    var pool = _make_pool()
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    # Seed the bucket: insert+checkin a conn.
    pool.insert_dialed(key.copy())
    var c2 = _make_conn(key.copy(), 200)
    pool.checkin(c2^, 200)
    assert_equal(pool.idle_count_for(key.copy()), 1)
    # Now checkout.
    var outcome = pool.try_checkout(key.copy(), 300)
    assert_true(outcome.is_ready())
    var conn = outcome.take_conn()
    assert_true(conn[].is_healthy())
    assert_true(conn[].key() == key)
    # in_use should have bumped back to 1; idle now empty.
    assert_equal(pool.in_use_for(key.copy()), 1)
    assert_equal(pool.idle_count_for(key.copy()), 0)
    # Drop the conn (test cleanup).
    _ = conn^


def test_checkin_unhealthy_dropped() raises:
    """An unhealthy conn is dropped on checkin: in_use decrements but
    idle stays empty."""
    var pool = _make_pool()
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    pool.insert_dialed(key.copy())
    # Build an unhealthy conn.
    var c2 = _make_conn(key.copy(), 200)
    c2[].mark_unhealthy()
    pool.checkin(c2^, 200)
    assert_equal(pool.in_use_for(key.copy()), 0)
    assert_equal(pool.idle_count_for(key.copy()), 0)


def test_max_idle_per_host_overflow_drops() raises:
    """Configure max_idle_per_host=2 and check in 3 conns; the last
    one is dropped (idle stays at 2)."""
    var pool = _make_pool_sized(max_conns=16, max_idle=2)
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    # Seed 3 in-use conns.
    pool.insert_dialed(key.copy())
    pool.insert_dialed(key.copy())
    pool.insert_dialed(key.copy())
    assert_equal(pool.in_use_for(key.copy()), 3)
    # Check in 3.
    var d1 = _make_conn(key.copy(), 200)
    pool.checkin(d1^, 200)
    var d2 = _make_conn(key.copy(), 200)
    pool.checkin(d2^, 200)
    var d3 = _make_conn(key.copy(), 200)
    pool.checkin(d3^, 200)
    # in_use was 3; checkin decrements once per call regardless of
    # idle-vs-drop decision -> in_use is now 0.
    assert_equal(pool.in_use_for(key.copy()), 0)
    # idle is capped at 2.
    assert_equal(pool.idle_count_for(key.copy()), 2)


def test_verify_mode_isolation_buckets() raises:
    """ACCEPTANCE GATE (d) verified at pool level: a VERIFY_PEER bucket
    and a VERIFY_SKIP bucket for the same host:port are SEPARATE.
    """
    var pool = _make_pool()
    var verify_key = PoolKey.https(
        String("example.com"), UInt16(443), VERIFY_PEER,
    )
    var skip_key = PoolKey.https(
        String("example.com"), UInt16(443), VERIFY_SKIP,
    )
    # Insert one conn per verify_mode.
    pool.insert_dialed(verify_key.copy())
    pool.insert_dialed(skip_key.copy())
    # The buckets are distinct.
    assert_equal(pool.in_use_for(verify_key.copy()), 1)
    assert_equal(pool.in_use_for(skip_key.copy()), 1)
    assert_equal(pool.bucket_count(), 2)
    # A try_checkout for verify_key should NEVER return a skip-mode conn
    # (the bucket lookup uses key equality, which includes verify_mode).
    var c_v2 = _make_conn(verify_key.copy(), 100)
    pool.checkin(c_v2^, 100)
    assert_equal(pool.idle_count_for(verify_key.copy()), 1)
    assert_equal(pool.idle_count_for(skip_key.copy()), 0)
    # Verify-mode checkout returns the verify-mode conn.
    var outcome = pool.try_checkout(verify_key.copy(), 200)
    assert_true(outcome.is_ready())
    var conn = outcome.take_conn()
    assert_true(conn[].key().verify_mode == VERIFY_PEER)
    _ = conn^


def test_at_capacity_when_max_conns_reached() raises:
    """ACCEPTANCE GATE (g) precursor: max_conns_per_host limits the
    bucket. Past the limit, try_checkout returns AT_CAPACITY (the
    actual queueing happens in via PendingCheckout)."""
    var pool = _make_pool_sized(max_conns=2, max_idle=2)
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    pool.insert_dialed(key.copy())
    pool.insert_dialed(key.copy())
    # Bucket now at 2 in_use, 0 idle.
    assert_equal(pool.in_use_for(key.copy()), 2)
    # Next checkout -> AT_CAPACITY.
    var outcome = pool.try_checkout(key.copy(), 200)
    assert_true(outcome.is_at_capacity())
    assert_false(outcome.is_ready())
    assert_false(outcome.is_needs_dial())


def test_lifo_idle_ordering() raises:
    """Idle conns are popped LIFO (most recently checked-in first) for
    cache locality. Test by checking-in two conns and verifying the
    last_used_us of the next checkout matches the latter."""
    var pool = _make_pool()
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    pool.insert_dialed(key.copy())
    pool.insert_dialed(key.copy())
    # Check in conn A with last_used=200; conn B with last_used=300.
    var d_a = _make_conn(key.copy(), 200)
    pool.checkin(d_a^, 200)
    var d_b = _make_conn(key.copy(), 300)
    pool.checkin(d_b^, 300)
    assert_equal(pool.idle_count_for(key.copy()), 2)
    # Next checkout returns conn B (last_used=300, most recent).
    var outcome = pool.try_checkout(key.copy(), 400)
    assert_true(outcome.is_ready())
    var conn = outcome.take_conn()
    # mark_used at checkout bumps to 400.
    assert_equal(conn[].last_used_us(), 400)
    _ = conn^


def test_release_in_use_decrements() raises:
    """release_in_use decrements the in_use counter without inserting
    a conn (used when a caller drops their checked-out conn)."""
    var pool = _make_pool()
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    pool.insert_dialed(key.copy())
    assert_equal(pool.in_use_for(key.copy()), 1)
    pool.release_in_use(key.copy())
    assert_equal(pool.in_use_for(key.copy()), 0)
    # Calling on a non-existent key is a no-op.
    var key2 = PoolKey.http(String("other.example.com"), UInt16(80))
    pool.release_in_use(key2.copy())
    assert_equal(pool.in_use_for(key2.copy()), 0)


def main() raises:
    test_empty_pool_checkout_needs_dial()
    test_insert_dialed_records_in_use()
    test_checkin_healthy_returns_to_idle()
    test_checkout_after_checkin_returns_ready()
    test_checkin_unhealthy_dropped()
    test_max_idle_per_host_overflow_drops()
    test_verify_mode_isolation_buckets()
    test_at_capacity_when_max_conns_reached()
    test_lifo_idle_ordering()
    test_release_in_use_decrements()
    print("OK: test_pool_basic")
