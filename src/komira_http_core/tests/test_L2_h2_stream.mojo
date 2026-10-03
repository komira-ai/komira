# =============================================================================
# tests/test_L2_h2_stream.mojo — RFC 9113 §5.1 stream-state tests
# =============================================================================
#
# L2 unit tests. Covers:
#   * State transitions: IDLE → OPEN → HALF_CLOSED_REMOTE → CLOSED
#   * Illegal transitions emit StreamAction.rst / .goaway
#   * CONTINUATION reassembly: HEADERS-without-END_HEADERS sets
#     continuation_pending; CONTINUATION with END_HEADERS clears it
#   * RST_STREAM in IDLE → connection PROTOCOL_ERROR (RFC 9113 §6.4)
#   * WINDOW_UPDATE in IDLE → PROTOCOL_ERROR
#   * continuation_pending flag lifecycle (POD; per-conn byte buffer
#     lives on H2ConnectionState per RFC 9113 §6.10 — at most ONE
#     in-flight HEADERS sequence per connection)
#
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http_core.codec.h2 import (
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FRAME_CONTINUATION,
    FRAME_DATA,
    FRAME_HEADERS,
    FRAME_RST_STREAM,
    FRAME_WINDOW_UPDATE,
    H2_ERR_PROTOCOL_ERROR,
    H2_ERR_STREAM_CLOSED,
    H2_STREAM_ACTION_GOAWAY,
    H2_STREAM_ACTION_KEEP,
    H2_STREAM_ACTION_RST,
    STREAM_STATE_CLOSED,
    STREAM_STATE_HALF_CLOSED_LOCAL,
    STREAM_STATE_HALF_CLOSED_REMOTE,
    STREAM_STATE_IDLE,
    STREAM_STATE_OPEN,
    StreamState,
)


# =============================================================================
# §1 — IDLE → OPEN on HEADERS.
# =============================================================================


def test_headers_idle_to_open() raises:
    var s = StreamState(stream_id=UInt32(1), initial_window=Int32(65535))
    assert_equal(Int(s.state), Int(STREAM_STATE_IDLE))
    var action = s.advance_on_recv_frame(FRAME_HEADERS, FLAG_END_HEADERS)
    assert_equal(Int(action.kind), Int(H2_STREAM_ACTION_KEEP))
    assert_equal(Int(s.state), Int(STREAM_STATE_OPEN))
    assert_false(s.continuation_pending)


def test_headers_idle_to_half_closed_remote_on_end_stream() raises:
    """HEADERS with END_STREAM in IDLE → HALF_CLOSED_REMOTE (peer sent
    all data in headers, e.g. GET request with no body)."""
    var s = StreamState(stream_id=UInt32(1), initial_window=Int32(65535))
    var action = s.advance_on_recv_frame(
        FRAME_HEADERS, FLAG_END_STREAM | FLAG_END_HEADERS,
    )
    assert_equal(Int(action.kind), Int(H2_STREAM_ACTION_KEEP))
    assert_equal(Int(s.state), Int(STREAM_STATE_HALF_CLOSED_REMOTE))
    assert_true(s.end_stream_seen)


# =============================================================================
# §2 — CONTINUATION reassembly.
# =============================================================================


def test_headers_without_end_headers_sets_continuation_pending() raises:
    var s = StreamState(stream_id=UInt32(1), initial_window=Int32(65535))
    var action = s.advance_on_recv_frame(FRAME_HEADERS, UInt8(0))
    assert_equal(Int(action.kind), Int(H2_STREAM_ACTION_KEEP))
    assert_true(s.continuation_pending)


def test_continuation_with_end_headers_clears_pending() raises:
    var s = StreamState(stream_id=UInt32(1), initial_window=Int32(65535))
    _ = s.advance_on_recv_frame(FRAME_HEADERS, UInt8(0))
    assert_true(s.continuation_pending)
    var action = s.advance_on_recv_frame(
        FRAME_CONTINUATION, FLAG_END_HEADERS,
    )
    assert_equal(Int(action.kind), Int(H2_STREAM_ACTION_KEEP))
    assert_false(s.continuation_pending)


def test_continuation_without_pending_goaway() raises:
    """RFC 9113 §6.10 — CONTINUATION with no preceding non-END_HEADERS
    HEADERS/PUSH_PROMISE/CONTINUATION → connection PROTOCOL_ERROR."""
    var s = StreamState(stream_id=UInt32(1), initial_window=Int32(65535))
    var action = s.advance_on_recv_frame(
        FRAME_CONTINUATION, FLAG_END_HEADERS,
    )
    assert_equal(Int(action.kind), Int(H2_STREAM_ACTION_GOAWAY))
    assert_equal(Int(action.error_code), Int(H2_ERR_PROTOCOL_ERROR))


# =============================================================================
# §3 — DATA on illegal state → RST_STREAM(STREAM_CLOSED).
# =============================================================================


def test_data_on_idle_rst_stream() raises:
    var s = StreamState(stream_id=UInt32(1), initial_window=Int32(65535))
    var action = s.advance_on_recv_frame(FRAME_DATA, UInt8(0))
    assert_equal(Int(action.kind), Int(H2_STREAM_ACTION_RST))
    assert_equal(Int(action.error_code), Int(H2_ERR_STREAM_CLOSED))


def test_data_open_to_half_closed_remote_on_end_stream() raises:
    var s = StreamState(stream_id=UInt32(1), initial_window=Int32(65535))
    _ = s.advance_on_recv_frame(FRAME_HEADERS, FLAG_END_HEADERS)
    assert_equal(Int(s.state), Int(STREAM_STATE_OPEN))
    var action = s.advance_on_recv_frame(FRAME_DATA, FLAG_END_STREAM)
    assert_equal(Int(action.kind), Int(H2_STREAM_ACTION_KEEP))
    assert_equal(Int(s.state), Int(STREAM_STATE_HALF_CLOSED_REMOTE))


# =============================================================================
# §4 — RST_STREAM behavior.
# =============================================================================


def test_rst_stream_in_idle_goaway() raises:
    """RFC 9113 §6.4 — RST_STREAM on IDLE stream → connection
    PROTOCOL_ERROR."""
    var s = StreamState(stream_id=UInt32(1), initial_window=Int32(65535))
    var action = s.advance_on_recv_frame(FRAME_RST_STREAM, UInt8(0))
    assert_equal(Int(action.kind), Int(H2_STREAM_ACTION_GOAWAY))
    assert_equal(Int(action.error_code), Int(H2_ERR_PROTOCOL_ERROR))


def test_rst_stream_in_open_closes() raises:
    var s = StreamState(stream_id=UInt32(1), initial_window=Int32(65535))
    _ = s.advance_on_recv_frame(FRAME_HEADERS, FLAG_END_HEADERS)
    var action = s.advance_on_recv_frame(FRAME_RST_STREAM, UInt8(0))
    assert_equal(Int(action.kind), Int(H2_STREAM_ACTION_KEEP))
    assert_equal(Int(s.state), Int(STREAM_STATE_CLOSED))


# =============================================================================
# §5 — WINDOW_UPDATE state checks.
# =============================================================================


def test_window_update_in_idle_goaway() raises:
    var s = StreamState(stream_id=UInt32(1), initial_window=Int32(65535))
    var action = s.advance_on_recv_frame(FRAME_WINDOW_UPDATE, UInt8(0))
    assert_equal(Int(action.kind), Int(H2_STREAM_ACTION_GOAWAY))
    assert_equal(Int(action.error_code), Int(H2_ERR_PROTOCOL_ERROR))


def test_window_update_in_open_keep() raises:
    var s = StreamState(stream_id=UInt32(1), initial_window=Int32(65535))
    _ = s.advance_on_recv_frame(FRAME_HEADERS, FLAG_END_HEADERS)
    var action = s.advance_on_recv_frame(FRAME_WINDOW_UPDATE, UInt8(0))
    assert_equal(Int(action.kind), Int(H2_STREAM_ACTION_KEEP))


# =============================================================================
# §6 — Header reassembly buffer.
# =============================================================================


def test_continuation_pending_flag_lifecycle() raises:
    """StreamState is Copyable (POD); the actual
    HEADERS/CONTINUATION byte-reassembly buffer lives on
    H2ConnectionState (RFC 9113 §6.10 — at most ONE in-flight HEADERS
    sequence per CONNECTION, not per stream). This test verifies the
    flag-only state-machine contract that survives on StreamState."""
    var s = StreamState(stream_id=UInt32(1), initial_window=Int32(65535))
    # HEADERS without END_HEADERS → continuation_pending becomes True.
    _ = s.advance_on_recv_frame(FRAME_HEADERS, UInt8(0))
    assert_equal(s.continuation_pending, True)
    # CONTINUATION with END_HEADERS clears continuation_pending.
    _ = s.advance_on_recv_frame(FRAME_CONTINUATION, FLAG_END_HEADERS)
    assert_equal(s.continuation_pending, False)
    # State is OPEN (HEADERS without END_STREAM, no END_STREAM yet).
    assert_equal(Int(s.state), Int(STREAM_STATE_OPEN))


# =============================================================================
# §7 — Sending END_STREAM transitions state.
# =============================================================================


def test_send_end_stream_open_to_half_closed_local() raises:
    var s = StreamState(stream_id=UInt32(1), initial_window=Int32(65535))
    _ = s.advance_on_recv_frame(FRAME_HEADERS, FLAG_END_HEADERS)
    assert_equal(Int(s.state), Int(STREAM_STATE_OPEN))
    s.advance_on_send_end_stream()
    assert_equal(Int(s.state), Int(STREAM_STATE_HALF_CLOSED_LOCAL))


def test_send_end_stream_half_closed_remote_to_closed() raises:
    var s = StreamState(stream_id=UInt32(1), initial_window=Int32(65535))
    _ = s.advance_on_recv_frame(
        FRAME_HEADERS, FLAG_END_STREAM | FLAG_END_HEADERS,
    )
    assert_equal(Int(s.state), Int(STREAM_STATE_HALF_CLOSED_REMOTE))
    s.advance_on_send_end_stream()
    assert_equal(Int(s.state), Int(STREAM_STATE_CLOSED))


# =============================================================================
# §8 — main.
# =============================================================================


def main() raises:
    print("test_L2_h2_stream: start")
    test_headers_idle_to_open()
    print(" headers_idle_to_open PASS")
    test_headers_idle_to_half_closed_remote_on_end_stream()
    print(" headers_idle_to_half_closed_remote PASS")
    test_headers_without_end_headers_sets_continuation_pending()
    print(" headers_without_end_headers_sets_pending PASS")
    test_continuation_with_end_headers_clears_pending()
    print(" continuation_with_end_headers_clears_pending PASS")
    test_continuation_without_pending_goaway()
    print(" continuation_without_pending_goaway PASS")
    test_data_on_idle_rst_stream()
    print(" data_on_idle_rst_stream PASS")
    test_data_open_to_half_closed_remote_on_end_stream()
    print(" data_open_to_half_closed_remote PASS")
    test_rst_stream_in_idle_goaway()
    print(" rst_stream_in_idle_goaway PASS")
    test_rst_stream_in_open_closes()
    print(" rst_stream_in_open_closes PASS")
    test_window_update_in_idle_goaway()
    print(" window_update_in_idle_goaway PASS")
    test_window_update_in_open_keep()
    print(" window_update_in_open_keep PASS")
    test_continuation_pending_flag_lifecycle()
    print(" continuation_pending_flag_lifecycle PASS")
    test_send_end_stream_open_to_half_closed_local()
    print(" send_end_stream_open_to_half_closed_local PASS")
    test_send_end_stream_half_closed_remote_to_closed()
    print(" send_end_stream_half_closed_remote_to_closed PASS")
    print("test_L2_h2_stream: ALL 14 TESTS PASS")
