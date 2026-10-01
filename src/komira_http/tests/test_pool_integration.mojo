# =============================================================================
# src/komira_http/tests/test_pool_integration.mojo — full flow over
# ScriptedConnector
# =============================================================================
# End-to-end smoke that exercises:
#   1. HttpClientConfig carries PoolSizingKnobs.
#   2. PerCorePool wraps the ScriptedConnector.Stream type.
#   3. checkout_or_pending NEEDS_DIAL flow: caller dials via the
#      ScriptedConnector, wraps in ClientConn, inserts_dialed for the
#      bucket bookkeeping.
#   4. checkin returns the conn to idle.
#   5. Subsequent checkout_or_pending returns READY from idle.
#   6. MockClock-driven idle eviction integrated with the dial flow.
#
# This is NOT a full end-to-end HTTP request roundtrip (that requires
# threading the OutboundDriver + request bytes — the HTTPS tests
# exercise that). This test's responsibility is to PROVE the pool
# orchestrates correctly with a real Connector + ClientConn substrate;
# this test does that.

from std.memory import OwnedPointer
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_http.client.client import HttpClientConfig
from komira_http.client.clock import MockClock
from komira_http.client.pool import (
    ClientConn,
    PerCorePool,
    PoolKey,
    PoolSizingKnobs,
)
from komira_http.transport.scripted import (
    ScriptedConnector,
    ScriptedStream,
)


def _build_test_reactor() raises -> Reactor[NoopSink]:
    """Construct a BACKEND_MOCK reactor — no fd allocation. The
    scripted connector / scripted stream ignore the reactor; this
    just gives the trait method a typed argument."""
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_MOCK,
    )


def test_http_client_config_carries_pool_sizing() raises:
    """HttpClientConfig.defaults() includes PoolSizingKnobs.defaults()."""
    var cfg = HttpClientConfig.defaults()
    assert_equal(cfg.tcp_nodelay, True)
    assert_equal(cfg.max_response_body_bytes, 100 * 1024 * 1024)
    assert_equal(cfg.pool_sizing.max_conns_per_host, 32)
    assert_equal(cfg.pool_sizing.max_idle_per_host, 16)
    assert_equal(cfg.pool_sizing.recv_ring_size, 64 * 1024)
    assert_equal(cfg.pool_sizing.idle_threshold_us, 60_000_000)


def test_pool_with_config_sizing() raises:
    """PerCorePool can be constructed from HttpClientConfig.pool_sizing."""
    var cfg = HttpClientConfig.defaults()
    var pool = PerCorePool[ScriptedStream].new(cfg.pool_sizing)
    assert_equal(pool.sizing().max_conns_per_host, 32)
    assert_equal(pool.sizing().idle_threshold_us, 60_000_000)


def test_dial_via_connector_then_pool_records() raises:
    """End-to-end orchestration: NEEDS_DIAL -> connector.connect ->
    wrap in ClientConn -> insert_dialed -> checkin -> next checkout
    returns READY from idle."""
    var clk = MockClock.starting_at(1_000_000)
    var pool = PerCorePool[ScriptedStream].with_defaults()
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))

    # First checkout: NEEDS_DIAL.
    var o1 = pool.checkout_or_pending(key.copy(), clk.now_us())
    assert_true(o1.is_needs_dial())

    # Caller dials via the ScriptedConnector + wraps in ClientConn.
    var connector = ScriptedConnector.with_stream(ScriptedStream.empty())
    var reactor = _build_test_reactor()
    var stream = connector.connect[PerCoreAsyncRuntime[NoopSink]](
        reactor, UInt32(0x0100007F), UInt16(80),
    )
    var conn = OwnedPointer[ClientConn[ScriptedStream]](
        ClientConn[ScriptedStream].new(stream^, key.copy(), clk.now_us())
    )
    pool.insert_dialed(key.copy())
    assert_equal(pool.in_use_for(key.copy()), 1)
    assert_equal(pool.dials_total(), 1)

    # Caller does the request (simulated -- doesn't drive the
    # OutboundDriver here; that's territory).

    # Caller returns the conn.
    clk.advance_us(1_000_000)  # 1s elapsed during the request.
    pool.checkin(conn^, clk.now_us())
    assert_equal(pool.in_use_for(key.copy()), 0)
    assert_equal(pool.idle_count_for(key.copy()), 1)

    # Subsequent checkout: READY from idle.
    var o2 = pool.checkout_or_pending(key.copy(), clk.now_us())
    assert_true(o2.is_ready())
    var conn2 = o2.take_conn()
    # Reuse: dials_total still 1.
    assert_equal(pool.dials_total(), 1)
    _ = conn2^


def test_idle_eviction_with_real_clock_pattern() raises:
    """Integration test: pool + MockClock + simulated idle period ->
    evict_idle removes the stale conn."""
    var clk = MockClock.starting_at(1_000_000)
    var pool = PerCorePool[ScriptedStream].new(
        PoolSizingKnobs(
            max_conns_per_host=4,
            max_idle_per_host=4,
            recv_ring_size=64 * 1024,
            idle_threshold_us=60_000_000,
        )
    )
    var key = PoolKey.http(String("127.0.0.1"), UInt16(80))

    # Dial + checkin + leave idle for 90s.
    var connector = ScriptedConnector.with_stream(ScriptedStream.empty())
    var reactor = _build_test_reactor()
    var stream = connector.connect[PerCoreAsyncRuntime[NoopSink]](
        reactor, UInt32(0x0100007F), UInt16(80),
    )
    var conn = OwnedPointer[ClientConn[ScriptedStream]](
        ClientConn[ScriptedStream].new(stream^, key.copy(), clk.now_us())
    )
    pool.insert_dialed(key.copy())
    pool.checkin(conn^, clk.now_us())
    assert_equal(pool.idle_count_for(key.copy()), 1)

    # Advance 90s -- past the 60s idle threshold.
    clk.advance_us(90_000_000)
    var n_evicted = pool.evict_idle(clk.now_us(), 60_000_000)
    assert_equal(n_evicted, 1)
    assert_equal(pool.idle_count_for(key.copy()), 0)


def main() raises:
    test_http_client_config_carries_pool_sizing()
    test_pool_with_config_sizing()
    test_dial_via_connector_then_pool_records()
    test_idle_eviction_with_real_clock_pattern()
    print("OK: test_pool_integration")
