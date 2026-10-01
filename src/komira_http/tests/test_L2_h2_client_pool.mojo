"""L2 H2ClientPool multiplex + GOAWAY draining tests.

Validates the sibling h2 pool's behavior:
  1. try_checkout on empty bucket → NEEDS_DIAL.
  2. insert_dialed_h2 → FOUND for next checkout (stream multiplex).
  3. Second checkout on same bucket-with-1-conn → FOUND (multiplexing
     a second stream on the existing conn).
  4. When the conn reaches max_concurrent_streams_peer (simulated by
     creating that many streams on it) → next try_checkout → NEEDS_DIAL.
  5. Conn marked draining after server GOAWAY → next checkout skips it
     → NEEDS_DIAL (or AT_CAPACITY if bucket at max_conns).
  6. release_drained_conn removes a drained conn from the slab.
"""

from komira_http.client.h2_client import H2ClientConnectionState
from komira_http.client.h2_pool import (
    H2_CHECKOUT_AT_CAPACITY,
    H2_CHECKOUT_FOUND,
    H2_CHECKOUT_NEEDS_DIAL,
    H2ClientPool,
    H2PooledConn,
)
from komira_http.client.pool import (
    ClientConn,
    PoolKey,
    PoolSizingKnobs,
    SCHEME_HTTPS,
    VERIFY_PEER,
)
from komira_http.transport.scripted import ScriptedStream


def _new_pool_default() -> H2ClientPool[ScriptedStream]:
    return H2ClientPool[ScriptedStream].with_defaults()


def _new_pool_small_max_conns() -> H2ClientPool[ScriptedStream]:
    """A pool with max_conns_per_host = 2 — to drive the AT_CAPACITY
    state from try_checkout."""
    var knobs = PoolSizingKnobs(
        max_conns_per_host=2,
        max_idle_per_host=2,
        recv_ring_size=65536,
        idle_threshold_us=60_000_000,
    )
    return H2ClientPool[ScriptedStream].new(knobs)


def _new_dialed_conn(
    key: PoolKey, max_concurrent: UInt32 = UInt32(100),
) -> Tuple[ClientConn[ScriptedStream], H2ClientConnectionState]:
    """Synthesize a "freshly dialed" ScriptedStream + h2_state for tests.

    The ScriptedStream has empty script (no read bytes); the h2_state has
    max_concurrent_streams_peer set per arg. This simulates what
    `connector.connect[RT]` + handshake + initial-SETTINGS exchange
    would produce in production."""
    var stream = ScriptedStream.empty()
    var now_us = 1000000
    var key2 = PoolKey(
        scheme=key.scheme,
        host=String(key.host),
        port=key.port,
        verify_mode=key.verify_mode,
    )
    var client_conn = ClientConn[ScriptedStream].new(
        stream^, key2^, now_us,
    )
    var h2_state = H2ClientConnectionState()
    h2_state.max_concurrent_streams_peer = max_concurrent
    return (client_conn^, h2_state^)


def test_empty_pool_checkout_returns_needs_dial() raises:
    """Fresh pool + try_checkout on a new key → NEEDS_DIAL."""
    print("  test_empty_pool_checkout_returns_needs_dial...")

    var pool = _new_pool_default()
    var key = PoolKey.https(String("example.com"), UInt16(443), VERIFY_PEER)
    var key_for_checkout = PoolKey(
        scheme=key.scheme,
        host=String(key.host),
        port=key.port,
        verify_mode=key.verify_mode,
    )
    var out = pool.try_checkout(key_for_checkout^)
    if not out.is_needs_dial():
        raise Error(
            "expected NEEDS_DIAL on empty pool; got state="
            + String(Int(out.state))
        )
    if pool.dials_total() != 0:
        raise Error("dials_total should be 0 before insert_dialed")
    print("    OK")


def test_insert_dialed_h2_then_checkout_finds_same_conn() raises:
    """After insert_dialed_h2, the next try_checkout on the same key
    returns FOUND with the same conn (multiplexing a second stream)."""
    print("  test_insert_dialed_h2_then_checkout_finds_same_conn...")

    var pool = _new_pool_default()
    var key = PoolKey.https(String("example.com"), UInt16(443), VERIFY_PEER)
    var pair = _new_dialed_conn(key)
    var cc = ClientConn[ScriptedStream].new(
        ScriptedStream.empty(), PoolKey.https(String("x"), UInt16(0), VERIFY_PEER), 0,
    )
    var hs = H2ClientConnectionState()
    swap(cc, pair[0])
    swap(hs, pair[1])
    var key_for_insert = PoolKey(
        scheme=key.scheme,
        host=String(key.host),
        port=key.port,
        verify_mode=key.verify_mode,
    )
    var inserted = pool.insert_dialed_h2(
        key_for_insert^, cc^, hs^,
    )
    if not inserted.is_found():
        raise Error(
            "insert_dialed_h2 should return FOUND for the new conn"
        )
    if pool.dials_total() != 1:
        raise Error(
            "dials_total should be 1; got " + String(pool.dials_total())
        )

    # Second checkout for same key → FOUND (the conn has 0 open streams).
    var key_for_checkout = PoolKey(
        scheme=key.scheme,
        host=String(key.host),
        port=key.port,
        verify_mode=key.verify_mode,
    )
    var out = pool.try_checkout(key_for_checkout^)
    if not out.is_found():
        raise Error("second checkout should FIND the conn")
    if out.bucket_idx != 0:
        raise Error("bucket_idx should be 0")
    if out.conn_idx != 0:
        raise Error("conn_idx should be 0 (single conn so far)")
    print("    OK")


def test_max_concurrent_streams_enforces_dial_for_next() raises:
    """A conn at its max_concurrent_streams_peer should be skipped on
    next checkout; pool returns NEEDS_DIAL (if bucket below capacity).
    Go-#34944 avoidance.
    """
    print("  test_max_concurrent_streams_enforces_dial_for_next...")

    var pool = _new_pool_default()
    var key = PoolKey.https(String("max-test.example"), UInt16(443), VERIFY_PEER)
    # Insert a conn with max_concurrent_streams_peer = 2.
    var pair = _new_dialed_conn(key, max_concurrent=UInt32(2))
    var cc = ClientConn[ScriptedStream].new(
        ScriptedStream.empty(), PoolKey.https(String("x"), UInt16(0), VERIFY_PEER), 0,
    )
    var hs = H2ClientConnectionState()
    swap(cc, pair[0])
    swap(hs, pair[1])
    var key_for_insert = PoolKey(
        scheme=key.scheme,
        host=String(key.host),
        port=key.port,
        verify_mode=key.verify_mode,
    )
    var inserted = pool.insert_dialed_h2(
        key_for_insert^, cc^, hs^,
    )
    var b_idx = inserted.bucket_idx
    var c_idx = inserted.conn_idx
    # Open 2 streams on it via the h2_state. After that, can_accept_new_stream
    # should be False.
    ref h2 = pool.h2_state_at(b_idx, c_idx)
    var sid1 = h2.allocate_client_stream_id()
    _ = h2.create_stream(sid1)
    var sid2 = h2.allocate_client_stream_id()
    _ = h2.create_stream(sid2)
    if h2.open_streams_count() != UInt32(2):
        raise Error(
            "open_streams_count should be 2; got "
            + String(Int(h2.open_streams_count()))
        )
    # Now try_checkout — bucket has 1 conn at its limit; pool should
    # NEEDS_DIAL (bucket has room for another conn).
    var key_for_checkout = PoolKey(
        scheme=key.scheme,
        host=String(key.host),
        port=key.port,
        verify_mode=key.verify_mode,
    )
    var out = pool.try_checkout(key_for_checkout^)
    if not out.is_needs_dial():
        raise Error(
            "with conn at max_concurrent_streams + bucket below "
            "max_conns: expected NEEDS_DIAL; got state="
            + String(Int(out.state))
        )
    print("    OK — Go-#34944 stream-cap avoidance")


def test_max_conns_per_host_returns_at_capacity() raises:
    """When all conns are at max_concurrent_streams AND bucket is at
    max_conns_per_host: try_checkout returns AT_CAPACITY."""
    print("  test_max_conns_per_host_returns_at_capacity...")

    var pool = _new_pool_small_max_conns()  # max_conns_per_host = 2
    var key = PoolKey.https(String("at-cap.example"), UInt16(443), VERIFY_PEER)
    # Insert 2 conns each at max_concurrent=1; fill each to its max.
    var pair1 = _new_dialed_conn(key, max_concurrent=UInt32(1))
    var cc1 = ClientConn[ScriptedStream].new(
        ScriptedStream.empty(), PoolKey.https(String("x"), UInt16(0), VERIFY_PEER), 0,
    )
    var hs1 = H2ClientConnectionState()
    swap(cc1, pair1[0])
    swap(hs1, pair1[1])
    var key_for_insert1 = PoolKey(
        scheme=key.scheme, host=String(key.host),
        port=key.port, verify_mode=key.verify_mode,
    )
    var ins1 = pool.insert_dialed_h2(key_for_insert1^, cc1^, hs1^)
    ref h2_1 = pool.h2_state_at(ins1.bucket_idx, ins1.conn_idx)
    _ = h2_1.create_stream(h2_1.allocate_client_stream_id())

    var pair2 = _new_dialed_conn(key, max_concurrent=UInt32(1))
    var cc2 = ClientConn[ScriptedStream].new(
        ScriptedStream.empty(), PoolKey.https(String("x"), UInt16(0), VERIFY_PEER), 0,
    )
    var hs2 = H2ClientConnectionState()
    swap(cc2, pair2[0])
    swap(hs2, pair2[1])
    var key_for_insert2 = PoolKey(
        scheme=key.scheme, host=String(key.host),
        port=key.port, verify_mode=key.verify_mode,
    )
    var ins2 = pool.insert_dialed_h2(key_for_insert2^, cc2^, hs2^)
    ref h2_2 = pool.h2_state_at(ins2.bucket_idx, ins2.conn_idx)
    _ = h2_2.create_stream(h2_2.allocate_client_stream_id())

    # Both at their max + bucket at max_conns_per_host=2 → AT_CAPACITY.
    var key_for_checkout = PoolKey(
        scheme=key.scheme, host=String(key.host),
        port=key.port, verify_mode=key.verify_mode,
    )
    var out = pool.try_checkout(key_for_checkout^)
    if not out.is_at_capacity():
        raise Error(
            "expected AT_CAPACITY when all conns full + bucket full; "
            "got state=" + String(Int(out.state))
        )
    print("    OK")


def test_goaway_received_marks_conn_draining() raises:
    """When the server emits GOAWAY (we simulate via mark_goaway_received
    on the h2_state), the conn's can_accept_new_stream returns False and
    try_checkout skips it."""
    print("  test_goaway_received_marks_conn_draining...")

    var pool = _new_pool_default()
    var key = PoolKey.https(String("drain.example"), UInt16(443), VERIFY_PEER)
    var pair = _new_dialed_conn(key)
    var cc = ClientConn[ScriptedStream].new(
        ScriptedStream.empty(), PoolKey.https(String("x"), UInt16(0), VERIFY_PEER), 0,
    )
    var hs = H2ClientConnectionState()
    swap(cc, pair[0])
    swap(hs, pair[1])
    var key_for_insert = PoolKey(
        scheme=key.scheme, host=String(key.host),
        port=key.port, verify_mode=key.verify_mode,
    )
    var ins = pool.insert_dialed_h2(key_for_insert^, cc^, hs^)
    # Simulate server GOAWAY: mark_goaway_received on the h2_state.
    ref h2 = pool.h2_state_at(ins.bucket_idx, ins.conn_idx)
    from komira_http.codec.h2.frame import H2_ERR_NO_ERROR
    h2.mark_goaway_received(UInt32(0), H2_ERR_NO_ERROR)
    # Next try_checkout should skip this conn → NEEDS_DIAL (bucket below max_conns).
    var key_for_checkout = PoolKey(
        scheme=key.scheme, host=String(key.host),
        port=key.port, verify_mode=key.verify_mode,
    )
    var out = pool.try_checkout(key_for_checkout^)
    if not out.is_needs_dial():
        raise Error(
            "after GOAWAY-received: expected NEEDS_DIAL (conn draining); "
            "got state=" + String(Int(out.state))
        )
    print("    OK — §6.5 GOAWAY drain behavior")


def test_release_drained_conn_removes_from_bucket() raises:
    """A draining conn with 0 open streams can be released; the bucket's
    conn_count drops."""
    print("  test_release_drained_conn_removes_from_bucket...")

    var pool = _new_pool_default()
    var key = PoolKey.https(String("release.example"), UInt16(443), VERIFY_PEER)
    var pair = _new_dialed_conn(key)
    var cc = ClientConn[ScriptedStream].new(
        ScriptedStream.empty(), PoolKey.https(String("x"), UInt16(0), VERIFY_PEER), 0,
    )
    var hs = H2ClientConnectionState()
    swap(cc, pair[0])
    swap(hs, pair[1])
    var key_for_insert = PoolKey(
        scheme=key.scheme, host=String(key.host),
        port=key.port, verify_mode=key.verify_mode,
    )
    var ins = pool.insert_dialed_h2(key_for_insert^, cc^, hs^)
    var b_idx = ins.bucket_idx
    if pool.conn_count_at(b_idx) != 1:
        raise Error("bucket should have 1 conn after insert")
    # Mark draining + release.
    pool.mark_conn_draining(b_idx, ins.conn_idx)
    pool.release_drained_conn(b_idx, ins.conn_idx)
    if pool.conn_count_at(b_idx) != 0:
        raise Error(
            "bucket conn_count should be 0 after release_drained_conn; got "
            + String(pool.conn_count_at(b_idx))
        )
    print("    OK")


def main() raises:
    print("== L2 H2ClientPool ==")
    test_empty_pool_checkout_returns_needs_dial()
    test_insert_dialed_h2_then_checkout_finds_same_conn()
    test_max_concurrent_streams_enforces_dial_for_next()
    test_max_conns_per_host_returns_at_capacity()
    test_goaway_received_marks_conn_draining()
    test_release_drained_conn_removes_from_bucket()
    print("== L2 H2ClientPool PASSED (6 tests, gates (a)+(f) GREEN) ==")
