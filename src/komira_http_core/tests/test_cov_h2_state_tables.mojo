# =============================================================================
# src/komira_http_core/tests/test_cov_h2_state_tables.mojo
# =============================================================================
#
# State tables of the h2 codec and the TLS handshake mapping, the arms their
# own tests do not take:
#
#   * StreamState.advance_on_recv_frame: HEADERS after the peer's
#     END_STREAM and on a closed stream (RST_STREAM(STREAM_CLOSED)), HEADERS
#     on an open stream without END_HEADERS (a CONTINUATION is then owed),
#     PRIORITY in every state, a frame kind the stream does not route;
#   * RecvFlowController.on_data_received when the STREAM window overruns:
#     a stream id gets RST_STREAM(FLOW_CONTROL_ERROR) and the connection is
#     still charged (RFC 9113 §6.9.1); stream id 0 gets the connection error
#     and nothing is charged; on_conn_data_received charges the connection
#     only;
#   * split_header_block_into_frames with a max frame size of 0 or less
#     framing at the 16384 default;
#   * outcome_to_interest / outcome_to_conn_state over outcomes known only
#     at run time.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.reactor.completion_queue import INTEREST_READ, INTEREST_WRITE

from komira_http_core.codec.h2.continuation_splitter import (
    split_header_block_into_frames,
)
from komira_http_core.codec.h2.flow_control import (
    FLOW_RESULT_FLOW_CONTROL_ERROR,
    FLOW_RESULT_OK,
    FLOW_RESULT_RST_STREAM,
    RecvFlowController,
)
from komira_http_core.codec.h2.frame import (
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FRAME_CONTINUATION,
    FRAME_DATA,
    FRAME_GOAWAY,
    FRAME_HEADERS,
    FRAME_PRIORITY,
    FRAME_RST_STREAM,
    FRAME_SETTINGS,
    H2_ERR_FLOW_CONTROL_ERROR,
    H2_ERR_STREAM_CLOSED,
    MAX_FRAME_PAYLOAD_DEFAULT,
)
from komira_http_core.codec.h2.stream import (
    H2_STREAM_ACTION_KEEP,
    H2_STREAM_ACTION_RST,
    STREAM_STATE_CLOSED,
    STREAM_STATE_HALF_CLOSED_REMOTE,
    STREAM_STATE_IDLE,
    STREAM_STATE_OPEN,
    StreamState,
)
from komira_http_core.tls import (
    CONN_STATE_TLS_HANDSHAKE_IN,
    CONN_STATE_TLS_HANDSHAKE_OUT,
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_BLOCKED_ON_WRITE,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    outcome_to_conn_state,
    outcome_to_interest,
)


def _open_stream() -> StreamState:
    var s = StreamState(UInt32(1), Int32(65535))
    var a = s.advance_on_recv_frame(FRAME_HEADERS, FLAG_END_HEADERS)
    _ = a
    return s


def test_headers_after_end_stream_and_on_closed() raises:
    """HEADERS once the peer sent END_STREAM, and on a closed stream, is
    RST_STREAM(STREAM_CLOSED); the stream's state does not move."""
    var s = StreamState(UInt32(3), Int32(65535))
    var a0 = s.advance_on_recv_frame(FRAME_HEADERS, FLAG_END_HEADERS | FLAG_END_STREAM)
    assert_equal(Int(a0.kind), Int(H2_STREAM_ACTION_KEEP))
    assert_equal(Int(s.state), Int(STREAM_STATE_HALF_CLOSED_REMOTE))
    var a1 = s.advance_on_recv_frame(FRAME_HEADERS, FLAG_END_HEADERS)
    assert_equal(Int(a1.kind), Int(H2_STREAM_ACTION_RST))
    assert_equal(Int(a1.error_code), Int(H2_ERR_STREAM_CLOSED))
    assert_equal(Int(s.state), Int(STREAM_STATE_HALF_CLOSED_REMOTE))

    var c = _open_stream()
    var r = c.advance_on_recv_frame(FRAME_RST_STREAM, UInt8(0))
    assert_equal(Int(r.kind), Int(H2_STREAM_ACTION_KEEP))
    assert_equal(Int(c.state), Int(STREAM_STATE_CLOSED))
    assert_true(c.is_terminal())
    var a2 = c.advance_on_recv_frame(FRAME_HEADERS, FLAG_END_HEADERS)
    assert_equal(Int(a2.kind), Int(H2_STREAM_ACTION_RST))
    assert_equal(Int(a2.error_code), Int(H2_ERR_STREAM_CLOSED))
    assert_equal(Int(c.state), Int(STREAM_STATE_CLOSED))


def test_trailing_headers_on_open_stream() raises:
    """HEADERS on an OPEN stream (trailers) keeps the stream; without
    END_HEADERS a CONTINUATION is owed and is then accepted, with it none is
    and a CONTINUATION is a connection error."""
    var s = _open_stream()
    assert_false(s.is_terminal())
    assert_false(s.continuation_pending)
    var a = s.advance_on_recv_frame(FRAME_HEADERS, UInt8(0))
    assert_equal(Int(a.kind), Int(H2_STREAM_ACTION_KEEP))
    assert_equal(Int(s.state), Int(STREAM_STATE_OPEN))
    assert_true(s.continuation_pending)
    var c = s.advance_on_recv_frame(FRAME_CONTINUATION, FLAG_END_HEADERS)
    assert_equal(Int(c.kind), Int(H2_STREAM_ACTION_KEEP))
    assert_false(s.continuation_pending)

    var t = _open_stream()
    var b = t.advance_on_recv_frame(FRAME_HEADERS, FLAG_END_HEADERS)
    assert_equal(Int(b.kind), Int(H2_STREAM_ACTION_KEEP))
    assert_false(t.continuation_pending)
    var g = t.advance_on_recv_frame(FRAME_CONTINUATION, FLAG_END_HEADERS)
    assert_true(Int(g.kind) != Int(H2_STREAM_ACTION_KEEP))


def test_priority_and_unrouted_kinds_keep() raises:
    """PRIORITY is tolerated in IDLE, OPEN and CLOSED and moves nothing; a
    kind the stream does not route (SETTINGS, GOAWAY) is KEEP too."""
    var idle = StreamState(UInt32(5), Int32(65535))
    var p0 = idle.advance_on_recv_frame(FRAME_PRIORITY, UInt8(0))
    assert_equal(Int(p0.kind), Int(H2_STREAM_ACTION_KEEP))
    assert_equal(Int(idle.state), Int(STREAM_STATE_IDLE))
    var open = _open_stream()
    var p1 = open.advance_on_recv_frame(FRAME_PRIORITY, FLAG_END_STREAM)
    assert_equal(Int(p1.kind), Int(H2_STREAM_ACTION_KEEP))
    assert_equal(Int(open.state), Int(STREAM_STATE_OPEN))
    assert_false(open.end_stream_seen)
    var closed = _open_stream()
    _ = closed.advance_on_recv_frame(FRAME_RST_STREAM, UInt8(0))
    var p2 = closed.advance_on_recv_frame(FRAME_PRIORITY, UInt8(0))
    assert_equal(Int(p2.kind), Int(H2_STREAM_ACTION_KEEP))
    var k1 = idle.advance_on_recv_frame(FRAME_SETTINGS, UInt8(0))
    assert_equal(Int(k1.kind), Int(H2_STREAM_ACTION_KEEP))
    var k2 = open.advance_on_recv_frame(FRAME_GOAWAY, FLAG_END_STREAM)
    assert_equal(Int(k2.kind), Int(H2_STREAM_ACTION_KEEP))
    assert_equal(Int(idle.state), Int(STREAM_STATE_IDLE))
    assert_equal(Int(open.state), Int(STREAM_STATE_OPEN))


def test_stream_window_overrun_charges_connection() raises:
    """A DATA frame that fits the connection window but not the stream's:
    RST_STREAM(FLOW_CONTROL_ERROR) naming the stream, the connection window
    charged by the whole length, the stream window untouched."""
    var fc = RecvFlowController()
    var before = Int(fc.conn_recv_window)
    var sw = Int32(10)
    var r = fc.on_data_received(11, sw, UInt32(7))
    assert_equal(Int(r.kind), Int(FLOW_RESULT_RST_STREAM))
    assert_equal(Int(r.stream_id), 7)
    assert_equal(Int(r.error_code), Int(H2_ERR_FLOW_CONTROL_ERROR))
    assert_equal(Int(fc.conn_recv_window), before - 11)
    assert_equal(Int(sw), 10)
    # Exactly the stream window is no overrun.
    var ok = fc.on_data_received(10, sw, UInt32(7))
    assert_equal(Int(ok.kind), Int(FLOW_RESULT_OK))
    assert_equal(Int(sw), 0)
    assert_equal(Int(fc.conn_recv_window), before - 21)


def test_stream_window_overrun_without_stream_id() raises:
    """With no stream id the overrun is the connection error and nothing is
    charged."""
    var fc = RecvFlowController()
    var before = Int(fc.conn_recv_window)
    var sw = Int32(4)
    var r = fc.on_data_received(5, sw)
    assert_equal(Int(r.kind), Int(FLOW_RESULT_FLOW_CONTROL_ERROR))
    assert_equal(Int(r.stream_id), 0)
    assert_equal(Int(r.error_code), Int(H2_ERR_FLOW_CONTROL_ERROR))
    assert_equal(Int(fc.conn_recv_window), before)
    assert_equal(Int(sw), 4)


def test_conn_only_charge() raises:
    """on_conn_data_received charges the connection window, and refuses
    (charging nothing) one octet past it."""
    var fc = RecvFlowController()
    var before = Int(fc.conn_recv_window)
    var r = fc.on_conn_data_received(100)
    assert_equal(Int(r.kind), Int(FLOW_RESULT_OK))
    assert_equal(Int(fc.conn_recv_window), before - 100)
    var all = fc.on_conn_data_received(before - 100)
    assert_equal(Int(all.kind), Int(FLOW_RESULT_OK))
    assert_equal(Int(fc.conn_recv_window), 0)
    var over = fc.on_conn_data_received(1)
    assert_equal(Int(over.kind), Int(FLOW_RESULT_FLOW_CONTROL_ERROR))
    assert_equal(Int(over.stream_id), 0)
    assert_equal(Int(fc.conn_recv_window), 0)


def _block(n: Int) -> List[UInt8]:
    var b = List[UInt8]()
    for i in range(n):
        b.append(UInt8(i % 251))
    return b^


def test_splitter_nonpositive_frame_size_uses_default() raises:
    """max_frame_size 0 and -1 frame exactly as MAX_FRAME_PAYLOAD_DEFAULT
    does: a block of default + 1 bytes is HEADERS(16384) + CONTINUATION(1)."""
    var n = MAX_FRAME_PAYLOAD_DEFAULT + 1
    var want = List[UInt8]()
    split_header_block_into_frames(UInt32(1), _block(n), MAX_FRAME_PAYLOAD_DEFAULT, True, want)
    assert_equal(len(want), n + 18)
    # HEADERS length field = 16384 (0x004000), no END_HEADERS.
    assert_equal(Int(want[0]), 0x00)
    assert_equal(Int(want[1]), 0x40)
    assert_equal(Int(want[2]), 0x00)
    assert_equal(Int(want[3]), Int(FRAME_HEADERS))
    assert_equal(Int(want[4]), Int(FLAG_END_STREAM))
    var cont = 9 + MAX_FRAME_PAYLOAD_DEFAULT
    assert_equal(Int(want[cont + 2]), 1)
    assert_equal(Int(want[cont + 3]), Int(FRAME_CONTINUATION))
    assert_equal(Int(want[cont + 4]), Int(FLAG_END_HEADERS))
    var sizes = List[Int]()
    sizes.append(0)
    sizes.append(-1)
    for k in range(len(sizes)):
        var mfs = sizes[k]
        var got = List[UInt8]()
        split_header_block_into_frames(UInt32(1), _block(n), mfs, True, got)
        assert_equal(len(got), len(want))
        for i in range(len(want)):
            assert_equal(Int(got[i]), Int(want[i]))


def test_handshake_mapping_runtime_outcomes() raises:
    """The four outcomes and an unknown one, read from a list so neither
    mapping can be folded at compile time."""
    var outs = List[UInt8]()
    outs.append(TLS_OUTCOME_BLOCKED_ON_READ)
    outs.append(TLS_OUTCOME_BLOCKED_ON_WRITE)
    outs.append(TLS_OUTCOME_DONE)
    outs.append(TLS_OUTCOME_ERROR)
    outs.append(UInt8(250))
    var masks = List[UInt8]()
    masks.append(INTEREST_READ)
    masks.append(INTEREST_WRITE)
    masks.append(INTEREST_READ)
    masks.append(UInt8(0))
    masks.append(UInt8(0))
    var states = List[UInt8]()
    states.append(CONN_STATE_TLS_HANDSHAKE_IN)
    states.append(CONN_STATE_TLS_HANDSHAKE_OUT)
    states.append(UInt8(0))
    states.append(UInt8(255))
    states.append(UInt8(255))
    for i in range(len(outs)):
        assert_equal(Int(outcome_to_interest(outs[i])), Int(masks[i]), String(i))
        assert_equal(
            Int(outcome_to_conn_state(outs[i], UInt8(i))), Int(states[i]), String(i),
        )


def main() raises:
    test_headers_after_end_stream_and_on_closed()
    test_trailing_headers_on_open_stream()
    test_priority_and_unrouted_kinds_keep()
    test_stream_window_overrun_charges_connection()
    test_stream_window_overrun_without_stream_id()
    test_conn_only_charge()
    test_splitter_nonpositive_frame_size_uses_default()
    test_handshake_mapping_runtime_outcomes()
    print("PASS test_cov_h2_state_tables")
