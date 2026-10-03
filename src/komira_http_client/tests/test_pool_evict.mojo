# =============================================================================
# src/komira_http_client/tests/test_pool_evict.mojo — idle eviction via MockClock
#
# =============================================================================
# Asserts:
# "idle-eviction tested via the injectable clock (no sleeping)".
#
# Tests use MockClock + pool.evict_idle(now_us, threshold_us) — no
# sleep(); no real time elapses. The pattern is:
#
#   var clk = MockClock.starting_at(1_000_000)
#   pool.checkin(conn, clk.now_us())     # last_used = 1s
#   clk.advance_us(61_000_000)           # mock t = 62s
#   var n = pool.evict_idle(clk.now_us(), 60_000_000)
#   assert n == 1                         # conn evicted (60s threshold)

from std.memory import OwnedPointer
from std.testing import assert_equal, assert_true

from komira_http_client.clock import MockClock
from komira_http_client.pool import (
    ClientConn,
    PerCorePool,
    PoolKey,
    PoolSizingKnobs,
)
from komira_http_core.transport.scripted import ScriptedStream


def _make_pool() -> PerCorePool[ScriptedStream]:
    return PerCorePool[ScriptedStream].with_defaults()


def _make_pool_idle_threshold(
    idle_threshold_us: Int,
) -> PerCorePool[ScriptedStream]:
    var k = PoolSizingKnobs(
        max_conns_per_host=16,
        max_idle_per_host=16,
        recv_ring_size=64 * 1024,
        idle_threshold_us=idle_threshold_us,
    )
    return PerCorePool[ScriptedStream].new(k)


def _make_conn(
    key: PoolKey, now_us: Int,
) -> OwnedPointer[ClientConn[ScriptedStream]]:
    var stream = ScriptedStream.empty()
    return OwnedPointer[ClientConn[ScriptedStream]](
        ClientConn[ScriptedStream].new(stream^, key.copy(), now_us)
    )


def test_evict_idle_no_conns_returns_zero() raises:
    """No conns in any bucket -> evict_idle returns 0."""
    var pool = _make_pool()
    var n = pool.evict_idle(1_000_000_000, 60_000_000)
    assert_equal(n, 0)


def test_evict_idle_fresh_conn_not_evicted() raises:
    """A conn checked in just now is not evicted (last_used == now)."""
    var pool = _make_pool()
    var clk = MockClock.starting_at(1_000_000)
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    pool.insert_dialed(key.copy())
    var c2 = _make_conn(key.copy(), clk.now_us())
    pool.checkin(c2^, clk.now_us())
    assert_equal(pool.idle_count_for(key.copy()), 1)
    # No time passed.
    var n = pool.evict_idle(clk.now_us(), 60_000_000)
    assert_equal(n, 0)
    assert_equal(pool.idle_count_for(key.copy()), 1)


def test_evict_idle_past_threshold_one_conn() raises:
    """ACCEPTANCE GATE (e): idle eviction via MockClock — advance past
    threshold, conn evicted."""
    var pool = _make_pool_idle_threshold(60_000_000)
    var clk = MockClock.starting_at(1_000_000)
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    pool.insert_dialed(key.copy())
    var c2 = _make_conn(key.copy(), clk.now_us())
    pool.checkin(c2^, clk.now_us())
    assert_equal(pool.idle_count_for(key.copy()), 1)
    # Advance past threshold.
    clk.advance_us(61_000_000)
    var n = pool.evict_idle(clk.now_us(), 60_000_000)
    assert_equal(n, 1)
    assert_equal(pool.idle_count_for(key.copy()), 0)


def test_evict_idle_just_at_threshold_not_evicted() raises:
    """Exactly at threshold (last_used + threshold == now) is NOT
    evicted — strict `>` per the implementation. Off-by-one boundary."""
    var pool = _make_pool_idle_threshold(60_000_000)
    var clk = MockClock.starting_at(1_000_000)
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    pool.insert_dialed(key.copy())
    var c2 = _make_conn(key.copy(), clk.now_us())
    pool.checkin(c2^, clk.now_us())
    clk.advance_us(60_000_000)
    # Diff == threshold exactly -> not evicted.
    var n = pool.evict_idle(clk.now_us(), 60_000_000)
    assert_equal(n, 0)
    assert_equal(pool.idle_count_for(key.copy()), 1)


def test_evict_idle_mixed_ages() raises:
    """Idle slab with mixed ages: old conns evicted, fresh ones kept."""
    var pool = _make_pool_idle_threshold(60_000_000)
    var clk = MockClock.starting_at(1_000_000)
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    # Insert and checkin 3 conns at t=1s.
    pool.insert_dialed(key.copy())
    pool.insert_dialed(key.copy())
    pool.insert_dialed(key.copy())
    var d1 = _make_conn(key.copy(), clk.now_us())
    pool.checkin(d1^, clk.now_us())
    var d2 = _make_conn(key.copy(), clk.now_us())
    pool.checkin(d2^, clk.now_us())
    # Advance 30s; check in one more (this one will be FRESH).
    clk.advance_us(30_000_000)
    var d3 = _make_conn(key.copy(), clk.now_us())
    pool.checkin(d3^, clk.now_us())
    assert_equal(pool.idle_count_for(key.copy()), 3)
    # Advance another 35s -> total 65s since first 2 checkins, 35s
    # since third.
    clk.advance_us(35_000_000)
    # 60s threshold -> first 2 conns evicted (65s > 60s), 3rd kept
    # (35s < 60s).
    var n = pool.evict_idle(clk.now_us(), 60_000_000)
    assert_equal(n, 2)
    assert_equal(pool.idle_count_for(key.copy()), 1)


def test_evict_idle_across_buckets() raises:
    """Eviction sweeps all buckets in one call."""
    var pool = _make_pool_idle_threshold(60_000_000)
    var clk = MockClock.starting_at(1_000_000)
    var k1 = PoolKey.http(String("a.example.com"), UInt16(80))
    var k2 = PoolKey.http(String("b.example.com"), UInt16(80))
    # Seed each bucket with one conn at t=1s.
    pool.insert_dialed(k1.copy())
    pool.insert_dialed(k2.copy())
    var d1 = _make_conn(k1.copy(), clk.now_us())
    pool.checkin(d1^, clk.now_us())
    var d2 = _make_conn(k2.copy(), clk.now_us())
    pool.checkin(d2^, clk.now_us())
    assert_equal(pool.idle_count_for(k1.copy()), 1)
    assert_equal(pool.idle_count_for(k2.copy()), 1)
    # Advance past threshold.
    clk.advance_us(61_000_000)
    var n = pool.evict_idle(clk.now_us(), 60_000_000)
    assert_equal(n, 2)
    assert_equal(pool.idle_count_for(k1.copy()), 0)
    assert_equal(pool.idle_count_for(k2.copy()), 0)


def test_evict_idle_does_not_touch_in_use() raises:
    """Eviction only sweeps the idle slab; in_use conns are
    untouched (by definition — the caller holds them, not the pool)."""
    var pool = _make_pool_idle_threshold(60_000_000)
    var clk = MockClock.starting_at(1_000_000)
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    pool.insert_dialed(key.copy())
    # in_use = 1, idle = 0.
    clk.advance_us(120_000_000)
    var n = pool.evict_idle(clk.now_us(), 60_000_000)
    # Idle is empty; in_use unchanged.
    assert_equal(n, 0)
    assert_equal(pool.in_use_for(key.copy()), 1)
    assert_equal(pool.idle_count_for(key.copy()), 0)


def test_evict_idle_does_not_touch_waiters() raises:
    """Eviction does NOT cancel pending waiters."""
    var pool = _make_pool_idle_threshold(60_000_000)
    var clk = MockClock.starting_at(1_000_000)
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))
    # Use a pool with max_conns=1 to force the second checkout to pend.
    var k = PoolSizingKnobs(
        max_conns_per_host=1,
        max_idle_per_host=16,
        recv_ring_size=64 * 1024,
        idle_threshold_us=60_000_000,
    )
    var pool2 = PerCorePool[ScriptedStream].new(k)
    pool2.insert_dialed(key.copy())
    var outcome = pool2.checkout_or_pending(key.copy(), clk.now_us())
    var pending = outcome.take_pending()
    assert_equal(pool2.waiter_count_for(key.copy()), 1)
    # Advance past threshold + evict.
    clk.advance_us(120_000_000)
    var n = pool2.evict_idle(clk.now_us(), 60_000_000)
    assert_equal(n, 0)  # idle empty
    assert_equal(pool2.waiter_count_for(key.copy()), 1)
    # Cleanup: fulfill the waiter.
    var good = _make_conn(key.copy(), clk.now_us())
    pool2.checkin(good^, clk.now_us())
    var conn = pending.await_conn()
    _ = conn^


def main() raises:
    test_evict_idle_no_conns_returns_zero()
    test_evict_idle_fresh_conn_not_evicted()
    test_evict_idle_past_threshold_one_conn()
    test_evict_idle_just_at_threshold_not_evicted()
    test_evict_idle_mixed_ages()
    test_evict_idle_across_buckets()
    test_evict_idle_does_not_touch_in_use()
    test_evict_idle_does_not_touch_waiters()
    print("OK: test_pool_evict")
