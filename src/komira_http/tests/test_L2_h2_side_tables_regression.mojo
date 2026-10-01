# =============================================================================
# tests/test_L2_h2_side_tables_regression.mojo
# =============================================================================
#
# Regression tests for the h2 server's deferred-response and pending-request
# side tables, the content-length validation fields and the concurrent-stream
# gate, so a future refactor that re-introduces eager whole-body emit OR drops
# the content-length validation OR weakens the concurrent-stream gate fails
# the suite. These tests exercise the H2ConnectionState side-table primitives
# directly + the StreamState scalar-field extensions, not an external
# conformance run.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http.codec.h2.connection_state import (
    H2ConnectionState,
    H2DeferredResponse,
    H2PendingRequest,
)
from komira_http.codec.h2.hpack import HpackHeader
from komira_http.codec.h2.stream import (
    STREAM_STATE_CLOSED,
    STREAM_STATE_HALF_CLOSED_REMOTE,
    STREAM_STATE_IDLE,
    STREAM_STATE_OPEN,
    StreamState,
)


# =============================================================================
# §1 — StreamState scalar-field defaults (Copyable-safe).
# =============================================================================


def test_stream_state_deferral_field_defaults() raises:
    """Added 4 new scalar fields to StreamState:
    expected_content_length / recv_data_bytes / has_deferred_response_body /
    has_pending_request. All must initialize to sentinel-safe defaults."""
    var ss = StreamState(stream_id=UInt32(1), initial_window=Int32(65535))
    assert_equal(Int(ss.expected_content_length), -1)
    assert_equal(Int(ss.recv_data_bytes), 0)
    assert_false(ss.has_deferred_response_body)
    assert_false(ss.has_pending_request)


def test_stream_state_remains_copyable_after_field_extension() raises:
    """StreamState must stay Copyable+ImplicitlyCopyable for
    `List[StreamState]` storage on `H2ConnectionState.streams`. Hard
    constraint per Mojo 1.0.0b1's `List V: Copyable` bound. This test
    is the canary for a regression that adds a non-Copyable field
    (List/String/OwnedPointer) and breaks List storage."""
    var a = StreamState(stream_id=UInt32(1), initial_window=Int32(65535))
    a.recv_data_bytes = Int64(42)
    a.has_pending_request = True
    var b = a  # implicit copy — must compile.
    assert_equal(Int(b.recv_data_bytes), 42)
    assert_true(b.has_pending_request)
    # Independence: mutating b must not touch a (deep value copy).
    b.recv_data_bytes = Int64(100)
    assert_equal(Int(a.recv_data_bytes), 42)


# =============================================================================
# §2 — Deferred-response side-table CRUD.
# =============================================================================


def _build_body(n: Int) -> List[UInt8]:
    var b = List[UInt8]()
    var i = 0
    while i < n:
        b.append(UInt8(i & 0xFF))
        i = i + 1
    return b^


def test_deferred_response_push_and_drop() raises:
    """`push_deferred_response` + `drop_deferred_response` round
    trip. find_idx returns -1 after drop."""
    var h2 = H2ConnectionState()
    var body = _build_body(128)
    h2.push_deferred_response(
        stream_id=UInt32(1),
        body=body^,
        offset=0,
        send_end_stream_on_drain=True,
    )
    assert_equal(h2.find_deferred_response_idx(UInt32(1)), 0)
    assert_equal(h2.deferred_response_body_len(UInt32(1)), 128)
    assert_true(h2.deferred_response_sends_end_stream(UInt32(1)))
    h2.drop_deferred_response(UInt32(1))
    assert_equal(h2.find_deferred_response_idx(UInt32(1)), -1)
    assert_equal(h2.deferred_response_body_len(UInt32(1)), 0)


def test_deferred_response_take_chunk_truncates_residual() raises:
    """`take_deferred_response_body_chunk(sid, n)` returns the
    first n bytes; the residual stays in the side-table entry. Key
    invariant for outbound DATA chunking respecting flow-control
    windows."""
    var h2 = H2ConnectionState()
    var body = _build_body(100)
    h2.push_deferred_response(
        stream_id=UInt32(1),
        body=body^,
        offset=0,
        send_end_stream_on_drain=True,
    )
    var chunk = h2.take_deferred_response_body_chunk(UInt32(1), 30)
    assert_equal(len(chunk), 30)
    # Residual is 100 - 30 = 70 bytes.
    assert_equal(h2.deferred_response_body_len(UInt32(1)), 70)
    # Chunk content: first 30 bytes match the original ramp.
    var ok = True
    var ci = 0
    while ci < 30:
        if chunk[ci] != UInt8(ci & 0xFF):
            ok = False
            break
        ci = ci + 1
    assert_true(ok)


def test_deferred_response_take_chunk_clamps_to_avail() raises:
    """take_deferred_response_body_chunk requesting more than
    available returns what's there (no overrun)."""
    var h2 = H2ConnectionState()
    var body = _build_body(20)
    h2.push_deferred_response(
        stream_id=UInt32(3),
        body=body^,
        offset=0,
        send_end_stream_on_drain=False,
    )
    var chunk = h2.take_deferred_response_body_chunk(UInt32(3), 100)
    assert_equal(len(chunk), 20)
    assert_equal(h2.deferred_response_body_len(UInt32(3)), 0)


def test_deferred_response_multiple_streams_isolated() raises:
    """Per-stream entries don't bleed into each other. find_idx returns
    distinct slot per stream_id."""
    var h2 = H2ConnectionState()
    var b1 = _build_body(50)
    var b2 = _build_body(75)
    h2.push_deferred_response(
        stream_id=UInt32(1),
        body=b1^,
        offset=0,
        send_end_stream_on_drain=True,
    )
    h2.push_deferred_response(
        stream_id=UInt32(3),
        body=b2^,
        offset=0,
        send_end_stream_on_drain=True,
    )
    assert_equal(h2.deferred_response_body_len(UInt32(1)), 50)
    assert_equal(h2.deferred_response_body_len(UInt32(3)), 75)
    # Drop sid=1; sid=3 unaffected.
    h2.drop_deferred_response(UInt32(1))
    assert_equal(h2.find_deferred_response_idx(UInt32(1)), -1)
    assert_equal(h2.deferred_response_body_len(UInt32(3)), 75)


# =============================================================================
# §3 — Pending-request side-table CRUD.
# =============================================================================


def test_pending_request_push_and_take() raises:
    """`push_pending_request` saves headers + method + path keyed
    by stream_id; `take_pending_request` moves them out (Movable-not-
    Copyable contract). Used in the content-length aggregation gate."""
    var h2 = H2ConnectionState()
    var headers = List[HpackHeader]()
    headers.append(HpackHeader(String(":method"), String("POST")))
    headers.append(HpackHeader(String(":path"), String("/upload")))
    headers.append(HpackHeader(String("content-length"), String("128")))
    h2.push_pending_request(
        stream_id=UInt32(5),
        headers=headers^,
        method_str=String("POST"),
        path_str=String("/upload"),
    )
    assert_equal(h2.find_pending_request_idx(UInt32(5)), 0)
    var taken = h2.take_pending_request(UInt32(5))
    # After take, the entry is gone.
    assert_equal(h2.find_pending_request_idx(UInt32(5)), -1)
    # Taken entry holds the saved fields.
    assert_equal(Int(taken.stream_id), 5)
    assert_equal(String(taken.method_str), String("POST"))
    assert_equal(String(taken.path_str), String("/upload"))
    assert_equal(len(taken.headers), 3)


def test_pending_request_take_absent_returns_stub() raises:
    """take_pending_request on an absent stream_id returns the stub
    (stream_id=0, empty fields). This is the contract for the
    DATA-handler END_STREAM dispatch path — caller checks
    has_pending_request before calling, but the defensive stub
    must be safe."""
    var h2 = H2ConnectionState()
    var taken = h2.take_pending_request(UInt32(99))
    assert_equal(Int(taken.stream_id), 0)
    assert_equal(len(taken.headers), 0)


# =============================================================================
# §4 — Concurrent-stream gate semantics.
# =============================================================================


def test_max_concurrent_streams_advertised_is_load_bearing() raises:
    """The alias `MAX_CONCURRENT_STREAMS_ADVERTISED` ties the
    SETTINGS_MAX_CONCURRENT_STREAMS we advertise to the active-count
    gate threshold. If a future refactor lets these drift, the
    h2spec §5.1.2 test fails (we'd accept more streams than promised
    OR refuse legitimate streams)."""
    from komira_http.transport.serve_h2 import (
        MAX_CONCURRENT_STREAMS_ADVERTISED,
    )
    # Lock the current value (50 — see serve_h2.mojo for the rationale).
    # changed this from 100 → 50 to close the
    # §5.1.2 #1 h2spec timing flake. RFC 9113 §6.5.2 RECOMMENDS ≥100
    # but this is non-normative; 50 is within production-server norm.
    # If we ever raise this back to ≥100, the §5.1.2 timing flake
    # returns unless we also implement an emit rate limiter or a
    # direct-write of RST/GOAWAY at the gate-fire site (both deferred
    # to a future architectural improvement).
    assert_equal(MAX_CONCURRENT_STREAMS_ADVERTISED, 50)


# =============================================================================
# §5 — Priority-out queue.
# =============================================================================


def test_prepend_out_bytes_orders_before_appended() raises:
    """`prepend_out_bytes` puts bytes at the FRONT of
    `pending_out`. Used by the §5.1.2 concurrent-stream gate to make
    RST_STREAM(REFUSED_STREAM) + GOAWAY(REFUSED_STREAM) overtake the
    queue of 100 HEADERS-resps that would otherwise delay them past
    h2spec's per-frame WaitEvent deadline.

    Contract:
    - append followed by prepend → prepended bytes appear FIRST.
    - prepend followed by append → prepended bytes still appear FIRST.
    - take_out_bytes returns the full sequence in wire order.
    """
    var h2 = H2ConnectionState()
    # Step 1: append two bytes.
    var a = List[UInt8]()
    a.append(UInt8(0x01))
    a.append(UInt8(0x02))
    h2.append_out_bytes(a^)
    # Step 2: prepend two more bytes (these should land at the FRONT).
    var p = List[UInt8]()
    p.append(UInt8(0x09))
    p.append(UInt8(0x0A))
    h2.prepend_out_bytes(p^)
    # Step 3: append another byte (lands at the tail).
    var t = List[UInt8]()
    t.append(UInt8(0xFF))
    h2.append_out_bytes(t^)
    # Drain.
    var wire = h2.take_out_bytes()
    assert_equal(len(wire), 5)
    # Order: [0x09, 0x0A, 0x01, 0x02, 0xFF] — prepended bytes first
    # (in their original order), then originally-appended bytes, then
    # post-prepend tail-appended byte.
    assert_equal(Int(wire[0]), 0x09)
    assert_equal(Int(wire[1]), 0x0A)
    assert_equal(Int(wire[2]), 0x01)
    assert_equal(Int(wire[3]), 0x02)
    assert_equal(Int(wire[4]), 0xFF)
    # Post-drain: pending_out is empty.
    assert_equal(h2._slab_len_deferred(), 0)
    var wire2 = h2.take_out_bytes()
    assert_equal(len(wire2), 0)


def test_prepend_into_empty_pending_out() raises:
    """Bounds-safe edge case: prepend into an empty `pending_out`
    behaves identically to append (FIFO of one)."""
    var h2 = H2ConnectionState()
    var p = List[UInt8]()
    p.append(UInt8(0xAB))
    p.append(UInt8(0xCD))
    h2.prepend_out_bytes(p^)
    var wire = h2.take_out_bytes()
    assert_equal(len(wire), 2)
    assert_equal(Int(wire[0]), 0xAB)
    assert_equal(Int(wire[1]), 0xCD)


def test_prepend_empty_bytes_noop() raises:
    """Bounds-safe edge case: prepend an empty List has no effect on
    pending_out (no zero-length insert, no buffer corruption)."""
    var h2 = H2ConnectionState()
    var a = List[UInt8]()
    a.append(UInt8(0x42))
    h2.append_out_bytes(a^)
    var empty = List[UInt8]()
    h2.prepend_out_bytes(empty^)
    var wire = h2.take_out_bytes()
    assert_equal(len(wire), 1)
    assert_equal(Int(wire[0]), 0x42)


# =============================================================================
# §6 — Test runner.
# =============================================================================


def main() raises:
    print("== regression tests ==")
    print("§1 StreamState deferral fields:")
    test_stream_state_deferral_field_defaults()
    print("  field_defaults PASS")
    test_stream_state_remains_copyable_after_field_extension()
    print("  remains_copyable PASS")
    print("§2 Deferred-response side-table CRUD:")
    test_deferred_response_push_and_drop()
    print("  push_and_drop PASS")
    test_deferred_response_take_chunk_truncates_residual()
    print("  take_chunk_truncates_residual PASS")
    test_deferred_response_take_chunk_clamps_to_avail()
    print("  take_chunk_clamps_to_avail PASS")
    test_deferred_response_multiple_streams_isolated()
    print("  multiple_streams_isolated PASS")
    print("§3 Pending-request side-table CRUD:")
    test_pending_request_push_and_take()
    print("  push_and_take PASS")
    test_pending_request_take_absent_returns_stub()
    print("  take_absent_returns_stub PASS")
    print("§4 Concurrent-stream gate semantics:")
    test_max_concurrent_streams_advertised_is_load_bearing()
    print("  max_concurrent_load_bearing PASS")
    print("§5 Priority-out queue:")
    test_prepend_out_bytes_orders_before_appended()
    print("  prepend_out_bytes_orders_before_appended PASS")
    test_prepend_into_empty_pending_out()
    print("  prepend_into_empty_pending_out PASS")
    test_prepend_empty_bytes_noop()
    print("  prepend_empty_bytes_noop PASS")
    print("test_L2_h2_side_tables_regression: ALL 12 TESTS PASS")
