# =============================================================================
# src/komira_http_server/serve_h2_flow.mojo: receive flow control and the
# scope of an error for the h2 serve loop
# =============================================================================
#
# The pieces of `serve_h2._dispatch_h2_frames` that decide how much the peer
# may send and how far a refusal reaches:
#   * `_credit_recv_windows`: WINDOW_UPDATE for DATA the server has taken in
#     (RFC 9113 §6.9). Without it the receive windows only shrink and a
#     compliant client stalls after 65,535 bytes on one connection.
#   * `_reset_stream`: a stream error (RFC 9113 §5.4.2). RST_STREAM, and the
#     stream is closed (§5.1) with its pending request and unsent response
#     dropped; the connection carries on.
#   * `_charge_connection_only`: DATA on a closed stream still counts
#     against the connection window (§6.9.1).
#   * `_answer_stream_decode_error`: a decode error the frame decoder scoped
#     to one stream (a PRIORITY of the wrong length, §6.3; a zero WINDOW_UPDATE
#     increment on a stream, §6.9) is a stream error, not a GOAWAY.
#   * `_buffered_request_body_bytes`: the request body bytes buffered on the
#     connection, which `H2_MAX_BUFFERED_REQUEST_BODY` bounds.
#   * `_emit_goaway`: a connection error (§5.4.1).
#
# No pointer in any signature. No wildcard origin.
# =============================================================================

from komira_http_core.codec.h2.connection_state import H2ConnectionState
from komira_http_core.codec.h2.flow_control import FLOW_RESULT_OK
from komira_http_core.codec.h2.frame import (
    FRAME_PRIORITY,
    FRAME_WINDOW_UPDATE,
    H2_ERR_FLOW_CONTROL_ERROR,
    H2_ERR_FRAME_SIZE_ERROR,
    H2_ERR_PROTOCOL_ERROR,
    encode_goaway_frame,
    encode_rst_stream_frame,
    encode_window_update_frame,
)
from komira_http_core.codec.h2.stream import (
    STREAM_STATE_CLOSED,
    STREAM_STATE_HALF_CLOSED_LOCAL,
    STREAM_STATE_OPEN,
)


comptime H2_MAX_BUFFERED_REQUEST_BODY: Int = 10 * 1024 * 1024
"""Ceiling on the request body bytes the server buffers on one connection,
summed over every deferred request (one whose dispatch waits for END_STREAM:
a declared content-length or a gRPC call). The same 10 MiB as the h1 codec's
default `max_body_bytes`, which an h1 connection buffers at most once.
Crediting the receive windows back (`_credit_recv_windows`) removes the
accidental 65,535-byte bound the connection window used to impose, so this
is now the bound. It is per connection, not per stream: per stream it would
allow MAX_CONCURRENT_STREAMS times as much on one connection. The DATA frame
that would take the total over it is refused on its own stream (413, then
RST_STREAM(NO_ERROR)); the other streams keep their bodies."""


def _buffered_request_body_bytes(h2: H2ConnectionState) -> Int64:
    """The request body bytes buffered on the connection: the DATA payload
    received so far on every stream that still holds a deferred request
    (`recv_data_bytes`, which the serve loop appends to that request's body
    as it counts it). Streams number at most the advertised
    MAX_CONCURRENT_STREAMS, so the scan is short."""
    var total = Int64(0)
    for i in range(len(h2.streams)):
        if h2.streams[i].has_pending_request:
            total += h2.streams[i].recv_data_bytes
    return total


def _emit_goaway(
    mut h2: H2ConnectionState, error_code: UInt32, priority: Bool = False,
):
    """Emit a GOAWAY frame to the outbound queue + mark the conn drained.

    `priority=True` puts the GOAWAY at the front of `pending_out`, behind
    only the pinned prefix (`H2ConnectionState.pin_out_bytes`), so it
    overtakes queued normal-path frames on the wire. Used by the §5.1.2
    concurrent-stream-limit gate, where a backlog of queued HEADERS-resps
    would otherwise delay the GOAWAY past h2spec's per-frame WaitEvent
    timeout. Normal-path callers leave `priority=False` (FIFO order).
    """
    if h2.is_goaway_sent():
        return
    var dbg = List[UInt8]()
    var buf = List[UInt8]()
    encode_goaway_frame(
        h2.last_processed_stream_id, error_code, dbg^, buf,
    )
    if priority:
        h2.prepend_out_bytes(buf^)
    else:
        h2.append_out_bytes(buf^)
    h2.mark_goaway_sent(error_code)


def _reset_stream(
    mut h2: H2ConnectionState, stream_id: UInt32, error_code: UInt32,
):
    """Answer a stream error on `stream_id` (RFC 9113 §5.4.2).

    Queues RST_STREAM(`error_code`). Sending RST_STREAM closes the stream
    (§5.1, "closed"), so a known stream is moved to CLOSED and loses its
    deferred request (never dispatched) and its unsent response body (the
    deferred pump would otherwise keep sending DATA on a reset stream). The
    stream is marked `reset_sent`: a DATA frame the peer had in flight
    before it saw the RST_STREAM is then ignored (§5.1): the serve loop
    sends nothing back and only charges the connection window
    (`_charge_connection_only`)."""
    var rst = List[UInt8]()
    encode_rst_stream_frame(stream_id, error_code, rst)
    h2.append_out_bytes(rst^)
    var idx = h2.find_stream_idx(stream_id)
    if idx < 0:
        return
    h2.streams[idx].state = STREAM_STATE_CLOSED
    h2.streams[idx].reset_sent = True
    if h2.streams[idx].has_pending_request:
        h2.streams[idx].has_pending_request = False
        if h2.find_pending_request_idx(stream_id) >= 0:
            var _drop = h2.take_pending_request(stream_id)
            _ = _drop
    if h2.streams[idx].has_deferred_response_body:
        h2.streams[idx].has_deferred_response_body = False
        h2.drop_deferred_response(stream_id)


def _charge_connection_only(mut h2: H2ConnectionState, octets: Int) -> Bool:
    """Charge a DATA frame's `octets` to the connection window alone and
    give them back once the watermark is reached: the frame's stream is
    closed, but §6.9.1 still counts it against the connection. Returns False
    when the connection window is overrun (a GOAWAY(FLOW_CONTROL_ERROR) is
    queued and the connection must close)."""
    var fr = h2.recv_fc.on_conn_data_received(octets)
    if fr.kind != FLOW_RESULT_OK:
        _emit_goaway(h2, H2_ERR_FLOW_CONTROL_ERROR)
        return False
    _credit_recv_windows(h2, -1)
    return True


def _credit_recv_windows(mut h2: H2ConnectionState, stream_idx: Int):
    """Send WINDOW_UPDATE for received DATA the server has taken in (RFC
    9113 §6.9).

    The serve loop takes every DATA payload out of the receive buffer in
    the frame that carries it (into a deferred request's body, or counted
    and discarded), so receipt is the point at which the octets are
    consumed. A window that has given up at least `recv_fc.drain_watermark`
    octets (half the initial window) is topped back up to the initial
    window with one WINDOW_UPDATE of exactly what it gave up, so the peer's
    view and ours stay equal.

    `stream_idx < 0` credits the connection only: the octets belong to a
    stream that has ended or was refused, and §6.9.1 still counts them
    against the connection window. A stream is credited only while the
    peer may still send on it (open or half-closed (local)); a window on a
    stream the peer has ended is never used again.

    The stream's update is queued before the connection's."""
    var initial = Int(h2.recv_fc.initial_recv_window)
    var watermark = Int(h2.recv_fc.drain_watermark)
    if stream_idx >= 0:
        var st = h2.streams[stream_idx].state
        if st == STREAM_STATE_OPEN or st == STREAM_STATE_HALF_CLOSED_LOCAL:
            var spent = initial - Int(h2.streams[stream_idx].recv_window)
            if spent >= watermark:
                var su = List[UInt8]()
                encode_window_update_frame(
                    h2.streams[stream_idx].stream_id, UInt32(spent), su,
                )
                h2.append_out_bytes(su^)
                h2.streams[stream_idx].recv_window = Int32(initial)
    var conn_spent = initial - Int(h2.recv_fc.conn_recv_window)
    if conn_spent >= watermark:
        var cu = List[UInt8]()
        encode_window_update_frame(UInt32(0), UInt32(conn_spent), cu)
        h2.append_out_bytes(cu^)
        h2.recv_fc.conn_recv_window = Int32(initial)


def _answer_stream_decode_error(
    mut h2: H2ConnectionState,
    kind: UInt8,
    stream_id: UInt32,
    error_code: UInt32,
) -> Bool:
    """Answer a decode error the frame decoder scoped to `stream_id`
    (`FrameDecodeResult.is_connection_error == False`; the caller has
    already skipped the frame's bytes). Returns False when the connection
    must close (a GOAWAY is queued).

    Only two faults are stream errors (RFC 9113 §5.4.2), answered with
    RST_STREAM(`error_code`) while the connection carries on: a PRIORITY of
    the wrong length (FRAME_SIZE_ERROR, §6.3) and a zero WINDOW_UPDATE
    increment (PROTOCOL_ERROR, §6.9). Everything else is a connection error,
    a GOAWAY:
      * stream 0: there is no stream to reset, so the decoder's code goes in
        a GOAWAY;
      * inside a header block: only CONTINUATION may follow HEADERS without
        END_HEADERS (§6.10), so PROTOCOL_ERROR;
      * any other fault the decoder scoped to a stream, with the decoder's
        code. A WINDOW_UPDATE whose length is not 4 is the case in point: it
        is a connection FRAME_SIZE_ERROR on any stream (§6.9). This server
        keeps that answer whatever scope the decoder reports for it;
      * an idle stream (never opened: absent and at or above
        `next_expected_stream_id`), with the decoder's code. RST_STREAM must
        not name an idle stream (§6.4), and neither PRIORITY nor a refused
        WINDOW_UPDATE opens it (§5.1), so the stream error is treated as a
        connection error, which §5.4 allows. For a zero increment the code is
        PROTOCOL_ERROR, the answer any WINDOW_UPDATE on an idle stream gets
        (§5.1)."""
    if stream_id == UInt32(0):
        _emit_goaway(h2, error_code)
        return False
    if h2.cont_reasm_stream_id != UInt32(0):
        _emit_goaway(h2, H2_ERR_PROTOCOL_ERROR)
        return False
    var stream_fault = (
        kind == FRAME_PRIORITY and error_code == H2_ERR_FRAME_SIZE_ERROR
    ) or (kind == FRAME_WINDOW_UPDATE and error_code == H2_ERR_PROTOCOL_ERROR)
    if not stream_fault:
        _emit_goaway(h2, error_code)
        return False
    if (
        h2.find_stream_idx(stream_id) < 0
        and stream_id >= h2.next_expected_stream_id
    ):
        _emit_goaway(h2, error_code)
        return False
    _reset_stream(h2, stream_id, error_code)
    return True
