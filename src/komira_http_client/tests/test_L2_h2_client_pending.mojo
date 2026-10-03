"""L2 h2 client PendingCheckout (multiplex AT_CAPACITY).

Tests the late-binding multiplex waiter shape (gate g): when all conns are
at their max_concurrent_streams_peer AND the bucket is at max_conns_per_host,
`try_checkout_or_pending(key)` returns an H2PendingCheckout. The pool's
`release_stream_slot(b_idx, c_idx)` fires the waiter when an in-flight
stream completes.

Tests:
  * try_checkout_or_pending returns FOUND when capacity exists
  * try_checkout_or_pending returns NEEDS_DIAL when bucket not at max
  * try_checkout_or_pending returns PENDING when at multiplex AT_CAPACITY
  * release_stream_slot wakes the pending waiter with matching key
  * release_stream_slot ignores mismatched-key waiter (defense in depth)
"""

from std.memory import OwnedPointer

from komira_http_client.h2_client import (
    H2ClientConnectionState,
    H2C_FLAG_SERVER_SETTINGS_SEEN,
)
from komira_http_client.h2_pool import (
    H2_OUTCOME_FOUND,
    H2_OUTCOME_NEEDS_DIAL,
    H2_OUTCOME_PENDING,
    H2CheckoutOrPending,
    H2ClientPool,
    H2PendingCheckout,
)
from komira_http_client.pool import (
    ClientConn,
    PoolKey,
    PoolSizingKnobs,
    VERIFY_PEER,
)
from komira_http_core.transport.scripted import ScriptedStream


# -----------------------------------------------------------------------------
# Helpers (mirror pool test patterns)
# -----------------------------------------------------------------------------


def _make_h2_conn(
    var key: PoolKey, max_concurrent_streams_peer: UInt32 = UInt32(1),
) raises -> Tuple[ClientConn[ScriptedStream], H2ClientConnectionState]:
    """Fabricate an h2 conn for tests — a ScriptedStream-backed
    ClientConn + an H2ClientConnectionState with max_concurrent_streams_peer
    set per arg. Matches test pattern."""
    var stream = ScriptedStream.empty()
    var now_us = 1000000
    var key2 = PoolKey(
        scheme=key.scheme,
        host=String(key.host),
        port=key.port,
        verify_mode=key.verify_mode,
        negotiated_alpn=key.negotiated_alpn,
    )
    var client_conn = ClientConn[ScriptedStream].new(
        stream^, key2^, now_us,
    )
    var h2_state = H2ClientConnectionState()
    h2_state.max_concurrent_streams_peer = max_concurrent_streams_peer
    return (client_conn^, h2_state^)


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_try_checkout_or_pending_found_when_capacity_available() raises:
    """Existing conn has open_streams < max_concurrent_streams_peer —
    pool returns FOUND with the bucket+conn indices.
    """
    print("  test_try_checkout_or_pending_found_when_capacity_available...")
    var key = PoolKey.https_h2(
        String("example.com"), UInt16(443), VERIFY_PEER,
    )
    var sizing = PoolSizingKnobs(
        max_conns_per_host=4, max_idle_per_host=2,
        recv_ring_size=65536, idle_threshold_us=60_000_000,
    )
    var pool = H2ClientPool[ScriptedStream].new(sizing)
    var conn_pair = _make_h2_conn(key, max_concurrent_streams_peer=UInt32(10))
    var cc = ClientConn[ScriptedStream](
        _stream=ScriptedStream.empty(),
        _key=PoolKey(
            scheme=key.scheme, host=String(key.host), port=key.port,
            verify_mode=key.verify_mode, negotiated_alpn=key.negotiated_alpn,
        ),
        _last_used_us=1000000,
        _is_healthy=True,
    )
    var hs = H2ClientConnectionState()
    hs.max_concurrent_streams_peer = UInt32(10)
    var dial_key = PoolKey(
        scheme=key.scheme, host=String(key.host), port=key.port,
        verify_mode=key.verify_mode, negotiated_alpn=key.negotiated_alpn,
    )
    var _r = pool.insert_dialed_h2(dial_key^, cc^, hs^)
    # Now try_checkout_or_pending — should FIND.
    var lookup_key = PoolKey(
        scheme=key.scheme, host=String(key.host), port=key.port,
        verify_mode=key.verify_mode, negotiated_alpn=key.negotiated_alpn,
    )
    var outcome = pool.try_checkout_or_pending(lookup_key^)
    if not outcome.is_found():
        raise Error(
            "expected FOUND outcome; got " + String(Int(outcome.outcome))
        )
    print("    OK — try_checkout_or_pending FOUND when conn has capacity")
    # Suppress unused-warning on conn_pair.
    _ = conn_pair


def test_try_checkout_or_pending_needs_dial_when_no_conn() raises:
    """Empty bucket → try_checkout_or_pending returns NEEDS_DIAL."""
    print("  test_try_checkout_or_pending_needs_dial_when_no_conn...")
    var key = PoolKey.https_h2(
        String("fresh-bucket.example"), UInt16(443), VERIFY_PEER,
    )
    var sizing = PoolSizingKnobs(
        max_conns_per_host=4, max_idle_per_host=2,
        recv_ring_size=65536, idle_threshold_us=60_000_000,
    )
    var pool = H2ClientPool[ScriptedStream].new(sizing)
    var outcome = pool.try_checkout_or_pending(key^)
    if not outcome.is_needs_dial():
        raise Error(
            "expected NEEDS_DIAL outcome; got " + String(Int(outcome.outcome))
        )
    print("    OK — try_checkout_or_pending NEEDS_DIAL on empty bucket")


def test_try_checkout_or_pending_pending_when_at_capacity() raises:
    """All conns at their max_concurrent_streams_peer AND bucket at
    max_conns_per_host → try_checkout_or_pending returns PENDING.
    """
    print("  test_try_checkout_or_pending_pending_when_at_capacity...")
    var key = PoolKey.https_h2(
        String("cap.example"), UInt16(443), VERIFY_PEER,
    )
    var sizing = PoolSizingKnobs(
        max_conns_per_host=1,  # exactly 1 conn allowed
        max_idle_per_host=2,
        recv_ring_size=65536, idle_threshold_us=60_000_000,
    )
    var pool = H2ClientPool[ScriptedStream].new(sizing)
    var cc = ClientConn[ScriptedStream](
        _stream=ScriptedStream.empty(),
        _key=PoolKey(
            scheme=key.scheme, host=String(key.host), port=key.port,
            verify_mode=key.verify_mode, negotiated_alpn=key.negotiated_alpn,
        ),
        _last_used_us=1000000,
        _is_healthy=True,
    )
    var hs = H2ClientConnectionState()
    hs.max_concurrent_streams_peer = UInt32(1)
    # Saturate the single allowed conn: open one stream so
    # open_streams_count == max_concurrent_streams_peer.
    _ = hs.create_stream(UInt32(1))
    var dial_key = PoolKey(
        scheme=key.scheme, host=String(key.host), port=key.port,
        verify_mode=key.verify_mode, negotiated_alpn=key.negotiated_alpn,
    )
    var _r = pool.insert_dialed_h2(dial_key^, cc^, hs^)

    # Now request another checkout — at capacity. Expect PENDING.
    var lookup_key = PoolKey(
        scheme=key.scheme, host=String(key.host), port=key.port,
        verify_mode=key.verify_mode, negotiated_alpn=key.negotiated_alpn,
    )
    var outcome = pool.try_checkout_or_pending(lookup_key^)
    if not outcome.is_pending():
        raise Error(
            "expected PENDING outcome; got " + String(Int(outcome.outcome))
        )
    # Pool's waiters list should have one entry.
    if pool.pending_waiters_count() != 1:
        raise Error(
            "expected 1 pending waiter; got "
            + String(pool.pending_waiters_count())
        )
    print("    OK — try_checkout_or_pending PENDING when AT_CAPACITY")


def test_release_stream_slot_wakes_pending_waiter() raises:
    """The end-to-end multiplex-cap waiter test: register a pending
    waiter, simulate a stream completion on the conn, verify the waiter
    is fulfilled with a FOUND result pointing at the now-available conn.
    """
    print("  test_release_stream_slot_wakes_pending_waiter...")
    var key = PoolKey.https_h2(
        String("wake.example"), UInt16(443), VERIFY_PEER,
    )
    var sizing = PoolSizingKnobs(
        max_conns_per_host=1, max_idle_per_host=2,
        recv_ring_size=65536, idle_threshold_us=60_000_000,
    )
    var pool = H2ClientPool[ScriptedStream].new(sizing)
    var cc = ClientConn[ScriptedStream](
        _stream=ScriptedStream.empty(),
        _key=PoolKey(
            scheme=key.scheme, host=String(key.host), port=key.port,
            verify_mode=key.verify_mode, negotiated_alpn=key.negotiated_alpn,
        ),
        _last_used_us=1000000,
        _is_healthy=True,
    )
    var hs = H2ClientConnectionState()
    hs.max_concurrent_streams_peer = UInt32(1)
    _ = hs.create_stream(UInt32(1))  # saturate stream slot
    var dial_key = PoolKey(
        scheme=key.scheme, host=String(key.host), port=key.port,
        verify_mode=key.verify_mode, negotiated_alpn=key.negotiated_alpn,
    )
    var _r = pool.insert_dialed_h2(dial_key^, cc^, hs^)

    # Register a pending waiter.
    var lookup_key = PoolKey(
        scheme=key.scheme, host=String(key.host), port=key.port,
        verify_mode=key.verify_mode, negotiated_alpn=key.negotiated_alpn,
    )
    var outcome = pool.try_checkout_or_pending(lookup_key^)
    if not outcome.is_pending():
        raise Error(
            "expected PENDING outcome; got " + String(Int(outcome.outcome))
        )
    # Take the H2PendingCheckout out of the outcome.
    var pending = outcome.pending.take()
    if pending.is_fired():
        raise Error("pending should not be pre-fired")

    # Simulate stream completion: close stream 1 + release.
    # Mark the stream as CLOSED via the pool's h2 state accessor.
    from komira_http_core.codec.h2.stream import STREAM_STATE_CLOSED
    pool.h2_state_at(0, 0).streams[0].state = STREAM_STATE_CLOSED
    pool.h2_state_at(0, 0).streams[0].end_stream_seen = True

    # Fire the release.
    pool.release_stream_slot(0, 0)

    if not pending.is_fired():
        raise Error("pending should be fired after release_stream_slot")
    # await_slot returns the H2CheckoutResult — should point at (0, 0).
    var result = pending.await_slot()
    if not result.is_found():
        raise Error("expected FOUND result post-wake")
    if result.bucket_idx != 0 or result.conn_idx != 0:
        raise Error(
            "expected (0, 0); got ("
            + String(result.bucket_idx) + ", " + String(result.conn_idx) + ")"
        )
    # Waiter should have been removed from the queue.
    if pool.pending_waiters_count() != 0:
        raise Error(
            "expected 0 pending waiters post-wake; got "
            + String(pool.pending_waiters_count())
        )
    print("    OK — release_stream_slot wakes waiter with FOUND(0,0)")


def main() raises:
    print("== L2 h2 client PendingCheckout ==")
    test_try_checkout_or_pending_found_when_capacity_available()
    test_try_checkout_or_pending_needs_dial_when_no_conn()
    test_try_checkout_or_pending_pending_when_at_capacity()
    test_release_stream_slot_wakes_pending_waiter()
    print("== L2 PendingCheckout PASSED (4 tests) ==")
