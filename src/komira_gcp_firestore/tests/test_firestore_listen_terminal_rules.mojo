# =============================================================================
# test_firestore_listen_terminal_rules.mojo — the Listen client's end-of-stream
#   rules on h2 connection state built by hand.
# =============================================================================
#
# test_firestore_listen_terminal_status.mojo drives the client over scripted
# server bytes. Some states no server script can produce, so they are built
# here directly on an `H2ClientConnectionState`:
#
#   * a reset THIS client sent (h2_client's stream-scoped FLOW_CONTROL_ERROR:
#     a frame can overrun the stream window only if it is larger than the
#     window, and the client's maximum frame size is smaller than it), which
#     grpc-go reports as INTERNAL whatever its code;
#   * a stream id the state does not hold, and a stream with no head slot;
#   * every row of the RST_STREAM-to-gRPC table;
#   * every way `_stream_over` answers.
#
# Each assertion names the rule it pins; a wrong row, a dropped branch or a
# swapped precedence fails it.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http_client.h2_client import (
    H2ClientConnectionState,
    H2_MALFORMED_SCOPE_HEAD,
    H2_MALFORMED_SCOPE_TRAILER,
)
from komira_http_core.codec.h2.frame import (
    H2_ERR_CANCEL,
    H2_ERR_COMPRESSION_ERROR,
    H2_ERR_ENHANCE_YOUR_CALM,
    H2_ERR_FLOW_CONTROL_ERROR,
    H2_ERR_HTTP_1_1_REQUIRED,
    H2_ERR_INADEQUATE_SECURITY,
    H2_ERR_NO_ERROR,
    H2_ERR_PROTOCOL_ERROR,
    H2_ERR_REFUSED_STREAM,
)

from komira_grpc import (
    GRPC_STATUS_CANCELLED,
    GRPC_STATUS_INTERNAL,
    GRPC_STATUS_PERMISSION_DENIED,
    GRPC_STATUS_RESOURCE_EXHAUSTED,
    GRPC_STATUS_UNAVAILABLE,
    GRPC_STATUS_UNKNOWN,
)

from komira_gcp_firestore.firestore_listen_client import (
    _grpc_code_for_rst,
    _listen_terminal_status,
    _stream_over,
)

comptime _SID = UInt32(1)


def _state_with_stream() -> H2ClientConnectionState:
    """Connection state holding stream 1 with a `:status 200` head applied."""
    var h2 = H2ClientConnectionState()
    var idx = h2.create_stream(_SID)
    h2.streams[idx].response_status = UInt16(200)
    h2.streams[idx].response_head_seen = True
    return h2^


def test_rst_code_table_is_grpc_gos() raises:
    """grpc-go `http2ErrConvTab`, row by row, and UNKNOWN past it."""
    assert_equal(_grpc_code_for_rst(H2_ERR_REFUSED_STREAM), GRPC_STATUS_UNAVAILABLE)
    assert_equal(_grpc_code_for_rst(H2_ERR_CANCEL), GRPC_STATUS_CANCELLED)
    assert_equal(
        _grpc_code_for_rst(H2_ERR_FLOW_CONTROL_ERROR),
        GRPC_STATUS_RESOURCE_EXHAUSTED,
    )
    assert_equal(
        _grpc_code_for_rst(H2_ERR_ENHANCE_YOUR_CALM),
        GRPC_STATUS_RESOURCE_EXHAUSTED,
    )
    assert_equal(
        _grpc_code_for_rst(H2_ERR_INADEQUATE_SECURITY),
        GRPC_STATUS_PERMISSION_DENIED,
    )
    assert_equal(_grpc_code_for_rst(H2_ERR_NO_ERROR), GRPC_STATUS_INTERNAL)
    assert_equal(_grpc_code_for_rst(H2_ERR_PROTOCOL_ERROR), GRPC_STATUS_INTERNAL)
    assert_equal(
        _grpc_code_for_rst(H2_ERR_COMPRESSION_ERROR), GRPC_STATUS_INTERNAL
    )
    assert_equal(
        _grpc_code_for_rst(H2_ERR_HTTP_1_1_REQUIRED), GRPC_STATUS_INTERNAL
    )
    assert_equal(
        _grpc_code_for_rst(H2_ERR_HTTP_1_1_REQUIRED + 1), GRPC_STATUS_UNKNOWN
    )


def test_a_reset_this_client_sent_is_internal() raises:
    """grpc-go closes a stream it reset itself with INTERNAL, not the code of
    its own RST_STREAM (FLOW_CONTROL_ERROR would read RESOURCE_EXHAUSTED)."""
    var s = _state_with_stream()
    var idx = s.find_stream_idx(_SID)
    s.streams[idx].reset_error_code = Int64(Int(H2_ERR_FLOW_CONTROL_ERROR))
    s.streams[idx].reset_is_local = True
    var ge = _listen_terminal_status(s, _SID, 0, 0)
    assert_equal(ge.code, GRPC_STATUS_INTERNAL)
    assert_true(String("this client reset") in ge.message, ge.message)


def test_a_peer_reset_reads_through_the_table() raises:
    var s = _state_with_stream()
    var idx = s.find_stream_idx(_SID)
    s.streams[idx].reset_error_code = Int64(Int(H2_ERR_FLOW_CONTROL_ERROR))
    var ge = _listen_terminal_status(s, _SID, 0, 0)
    assert_equal(ge.code, GRPC_STATUS_RESOURCE_EXHAUSTED)
    assert_true(String("RST_STREAM(3)") in ge.message, ge.message)


def test_an_unknown_stream_is_internal() raises:
    var h2 = H2ClientConnectionState()
    var ge = _listen_terminal_status(h2, _SID, 0, 0)
    assert_equal(ge.code, GRPC_STATUS_INTERNAL)
    assert_true(String("has no stream 1") in ge.message, ge.message)


def test_a_stream_with_no_head_slot_still_reads() raises:
    """No head slot: no trailers-only status to read; a closed connection."""
    var s = _state_with_stream()
    var idx = s.find_stream_idx(_SID)
    s.streams[idx].response_header_idx = -1
    var ge = _listen_terminal_status(s, _SID, 0, 0)
    assert_equal(ge.code, GRPC_STATUS_UNAVAILABLE)


def test_a_malformed_trailer_is_internal() raises:
    var s = _state_with_stream()
    var idx = s.find_stream_idx(_SID)
    s.streams[idx].malformed_scope = H2_MALFORMED_SCOPE_TRAILER
    s.streams[idx].end_stream_seen = True
    var ge = _listen_terminal_status(s, _SID, 0, 0)
    assert_equal(ge.code, GRPC_STATUS_INTERNAL)
    assert_true(String("malformed") in ge.message, ge.message)


def test_stream_over_answers() raises:
    # A stream the state does not hold is not over (nothing to wait for).
    var empty = H2ClientConnectionState()
    assert_false(_stream_over(empty, _SID))
    # Open, nothing received: not over.
    var a = _state_with_stream()
    assert_false(_stream_over(a, _SID))
    # END_STREAM.
    var b = _state_with_stream()
    var bi = b.find_stream_idx(_SID)
    b.streams[bi].end_stream_seen = True
    assert_true(_stream_over(b, _SID))
    # Reset (either side).
    var c = _state_with_stream()
    var ci = c.find_stream_idx(_SID)
    c.streams[ci].reset_error_code = Int64(Int(H2_ERR_CANCEL))
    assert_true(_stream_over(c, _SID))
    # Refused as malformed by this client.
    var d = _state_with_stream()
    var di = d.find_stream_idx(_SID)
    d.streams[di].malformed_scope = H2_MALFORMED_SCOPE_HEAD
    assert_true(_stream_over(d, _SID))
    # GOAWAY below the stream: over. GOAWAY at or above it: still open.
    var e = _state_with_stream()
    e.mark_goaway_received(UInt32(0), H2_ERR_NO_ERROR)
    assert_true(_stream_over(e, _SID))
    var f = _state_with_stream()
    f.mark_goaway_received(_SID, H2_ERR_NO_ERROR)
    assert_false(_stream_over(f, _SID))


def main() raises:
    print("test_firestore_listen_terminal_rules")
    test_rst_code_table_is_grpc_gos()
    test_a_reset_this_client_sent_is_internal()
    test_a_peer_reset_reads_through_the_table()
    test_an_unknown_stream_is_internal()
    test_a_stream_with_no_head_slot_still_reads()
    test_a_malformed_trailer_is_internal()
    test_stream_over_answers()
    print("ALL PASS")
