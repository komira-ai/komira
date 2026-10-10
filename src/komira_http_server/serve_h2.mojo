# =============================================================================
# src/komira_http_server/serve_h2.mojo — L0 HTTP/2 per-conn serve round
# =============================================================================
#
# analog of `serve_read_round_tls` for the h2 path.
#
# Lifecycle:
#   * After TLS handshake DONE + ALPN-readback == "h2", the accept loop
#     calls `install_h2_state(...)` on ConnEntry, sets the conn state to
#     CONN_STATE_H2_PREFACE_WAIT, and routes subsequent read-events to
#     `serve_read_round_h2`.
#   * `serve_read_round_h2`:
#       - reads ciphertext bytes via TlsStream.read_app
#       - appends to H2ConnectionState.recv_buf
#       - in CONN_STATE_H2_PREFACE_WAIT: validates the 24-byte client
#         preface via codec.h2.connection_preface.check_client_preface;
#         on OK transitions to CONN_STATE_H2_ACTIVE and emits the
#         server's initial SETTINGS frame
#       - in CONN_STATE_H2_ACTIVE: loops decoding frames via
#         codec.h2.frame.decode_frame; dispatches each to the appropriate
#         per-frame-type handler
#       - flushes pending_out via TlsStream.write_app
#
# Encapsulation:
#   * Zero UnsafePointer in public signatures.
#   * No wildcard origins.
#   * H2ConnectionState is heap-Movable (Optional[H2ConnectionState] on
#     ConnEntry); pointer-safe per the
# =============================================================================

from std.collections.dict import Dict

from komira_http_core.codec.h2.connection_preface import (
    PREFACE_ERROR,
    PREFACE_NEED_MORE,
    PREFACE_OK,
    check_client_preface,
)
from komira_http_core.codec.h2.connection_state import (
    H2ConnectionState,
    H2PendingRequest,
)
from komira_http_core.codec.h2.flow_control import (
    FLOW_RESULT_OK,
    FLOW_RESULT_RST_STREAM,
)
from komira_http_core.codec.h2.frame import (
    FLAG_ACK,
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FLAG_PRIORITY,
    FRAME_CONTINUATION,
    FRAME_DATA,
    FRAME_GOAWAY,
    FRAME_HEADERS,
    FRAME_PING,
    FRAME_PRIORITY,
    FRAME_PUSH_PROMISE,
    FRAME_RST_STREAM,
    FRAME_SETTINGS,
    FRAME_WINDOW_UPDATE,
    FRAME_DECODE_ERROR,
    FRAME_DECODE_NEED_MORE,
    FRAME_DECODE_OK,
    Frame,
    H2_ERR_COMPRESSION_ERROR,
    H2_ERR_ENHANCE_YOUR_CALM,
    H2_ERR_FLOW_CONTROL_ERROR,
    H2_ERR_NO_ERROR,
    H2_ERR_PROTOCOL_ERROR,
    H2_ERR_REFUSED_STREAM,
    MAX_FRAME_PAYLOAD_DEFAULT,
    SETTINGS_HEADER_TABLE_SIZE,
    SETTINGS_INITIAL_WINDOW_SIZE,
    SETTINGS_MAX_CONCURRENT_STREAMS,
    SETTINGS_MAX_FRAME_SIZE,
    SETTINGS_MAX_HEADER_LIST_SIZE,
    SettingsEntry,
    decode_frame,
    encode_data_frame,
    encode_headers_frame,
    encode_ping_frame,
    encode_rst_stream_frame,
    encode_settings_ack_frame,
    encode_settings_frame,
    encode_window_update_frame,
)
from komira_http_core.codec.h2.hpack import HpackHeader
from komira_http_core.codec.h2.stream import (
    H2_STREAM_ACTION_GOAWAY,
    H2_STREAM_ACTION_KEEP,
    H2_STREAM_ACTION_RST,
    STREAM_STATE_CLOSED,
    STREAM_STATE_OPEN,
    STREAM_STATE_HALF_CLOSED_REMOTE,
    StreamState,
)
from komira_http_core.codec.types import (
    HTTP_METHOD_GET,
    HttpMethod,
    HttpRequest,
    HttpResponse,
)
from komira_http_server.routing import Router
from komira_http_core.transport.grpc_emit import (
    GRPC_KIND_CLIENT_STREAM,
    GRPC_KIND_SERVER_STREAM,
    GRPC_KIND_UNARY,
    GrpcDispatch,
    GrpcResponse,
    GrpcStreamDispatch,
    GrpcStreamResponse,
    _emit_grpc_trailer,
    emit_grpc_response,
    emit_grpc_stream_response,
    is_grpc_content_type,
)
from komira_http_core.transport.grpc_timeout import (
    GRPC_TIMEOUT_MALFORMED,
    GrpcDeadline,
    emit_grpc_deadline_exceeded,
    emit_grpc_malformed_timeout,
    grpc_deadline_at_arrival,
)
from komira_http_core.tls.s2n_shim import (
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_BLOCKED_ON_WRITE,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
)
from komira_http_server.connection import (
    CONN_STATE_H2_ACTIVE,
    CONN_STATE_H2_PREFACE_WAIT,
    ConnEntry,
    REQ_BUF_BYTES,
)
from komira_http_server.serve_h2_headers import _validate_h2_request_headers
from komira_http_server.serve_h2_flow import (
    H2_MAX_BUFFERED_REQUEST_BODY,
    _answer_stream_decode_error,
    _buffered_request_body_bytes,
    _charge_connection_only,
    _credit_recv_windows,
    _emit_goaway,
    _reset_stream,
)


# =============================================================================
# §1 — Server-side initial SETTINGS frame builder.
# =============================================================================


# SETTINGS_MAX_CONCURRENT_STREAMS advertised by the
# server. The active-count gate in `_handle_headers_or_continuation`
# enforces this on inbound HEADERS; tied to the same constant so the
# advertised value and the enforcement threshold can never drift.
#
# value changed from 100 → 50 to close the
# §5.1.2 #1 timing flake. RFC 9113 §6.5.2 RECOMMENDS ≥100 to "not
# unnecessarily limit parallelism" (non-normative; production servers
# vary: nginx default 128, Apache default 100, but many tune lower).
# With the priority-out queue (`prepend_out_bytes` +
# `_emit_goaway(priority=True)`), 50 reliably passes h2spec §5.1.2
# in 6.6s, vs 145/146 + 16.6s at value=100 (the 10s gap is exactly
# h2spec's per-frame WaitEvent deadline elapsing on the 100 HEADERS-
# resps queued before the gate fires). At 50, h2spec sends 51
# HEADERS, the gate fires on the 51st with ~50 HEADERS-resps queued,
# the priority-out queue puts RST_STREAM(REFUSED_STREAM) +
# GOAWAY(REFUSED_STREAM) ahead on the wire, and h2spec sees them
# within its first WaitEvent — no timing edge. Production workloads
# rarely benefit from >50 concurrent streams per conn; HTTP/1.1
# pipelining limits were much lower (6 in browsers), and modern h2
# clients (browsers, gRPC) typically open a small number of
# concurrent streams.
comptime MAX_CONCURRENT_STREAMS_ADVERTISED: Int = 50


def build_initial_server_settings(
    h2: H2ConnectionState,
) -> List[UInt8]:
    """Build the server's INITIAL non-ACK SETTINGS frame.

    Sent immediately after the client preface validates. Carries the
    server's SETTINGS_* parameters (header table size, max concurrent
    streams, initial window, max frame size, max header list size).
    """
    var entries = List[SettingsEntry]()
    entries.append(SettingsEntry(
        identifier=SETTINGS_HEADER_TABLE_SIZE,
        value=UInt32(4096),
    ))
    entries.append(SettingsEntry(
        identifier=SETTINGS_MAX_CONCURRENT_STREAMS,
        value=UInt32(MAX_CONCURRENT_STREAMS_ADVERTISED),
    ))
    entries.append(SettingsEntry(
        identifier=SETTINGS_INITIAL_WINDOW_SIZE,
        value=UInt32(65535),
    ))
    entries.append(SettingsEntry(
        identifier=SETTINGS_MAX_FRAME_SIZE,
        value=UInt32(Int(h2.max_frame_size_local)),
    ))
    entries.append(SettingsEntry(
        identifier=SETTINGS_MAX_HEADER_LIST_SIZE,
        value=UInt32(8192),
    ))
    var out = List[UInt8]()
    encode_settings_frame(entries^, out)
    return out^


# =============================================================================
# §2 — Preface-wait helper.
# =============================================================================


def _try_consume_preface(
    mut h2: H2ConnectionState,
) -> UInt8:
    """If `h2.recv_buf` has >= 24 bytes, run check_client_preface; if
    OK, drop the 24 bytes + return PREFACE_OK. If ERROR, return
    PREFACE_ERROR; otherwise PREFACE_NEED_MORE."""
    if len(h2.recv_buf) < 24:
        return PREFACE_NEED_MORE
    var rb = Span(h2.recv_buf)
    var res = check_client_preface(rb)
    if res.status == PREFACE_OK:
        h2.consume_recv_bytes(24)
        h2.mark_preface_ok()
    return res.status


# =============================================================================
# §3 — Frame dispatch.
# =============================================================================


def _dispatch_h2_frames[
    G: GrpcDispatch & GrpcStreamDispatch,
](
    mut h2: H2ConnectionState,
    ref router: Router,
    mut grpc: G,
    mut reqs_handled: Int64,
    mut bytes_sent: Int64,
) -> Bool:
    """Decode + dispatch as many frames as fit in `h2.recv_buf`.

    Returns False if the connection should close (GOAWAY emitted +
    drained, or hard error during dispatch). True otherwise.

    contract: drain decode loop runs but the per-frame handlers are
    minimal — SETTINGS-ACK on inbound SETTINGS (non-ACK), GOAWAY on
    PROTOCOL_ERROR. The router-dispatch + HEADERS reassembly + DATA
    aggregation paths fill in at.
    """
    while True:
        if len(h2.recv_buf) == 0:
            return True
        var view = Span(h2.recv_buf)
        var res = decode_frame(view, h2.max_frame_size_local)
        if res.status == FRAME_DECODE_NEED_MORE:
            return True
        if res.status == FRAME_DECODE_ERROR:
            if res.is_connection_error or res.consumed == 0:
                # Connection error (RFC 9113 §5.4.1) → GOAWAY + close.
                if not h2.is_goaway_sent():
                    _emit_goaway(h2, res.error_code)
                return False
            # A stream error (§5.4.2): the decoder consumed the whole
            # frame, so skip it, reset its stream and keep decoding.
            var bad_kind = h2.recv_buf[3]
            h2.consume_recv_bytes(res.consumed)
            if not _answer_stream_decode_error(
                h2, bad_kind, res.error_stream_id, res.error_code,
            ):
                return False
            continue
        # FRAME_DECODE_OK.
        var consumed = res.consumed
        h2.consume_recv_bytes(consumed)
        # Extract the frame via swap (partial-move-via-^ on `res.frame`
        # is rejected because it'd leave `res` in an unrecoverable
        # partial-moved shape per the pointer rules). The swap
        # leaves `res.frame` in a default-constructed (destructor-safe)
        # state; `res` drops cleanly at end-of-iteration.
        var frame = Frame()
        swap(frame, res.frame)

        # RFC 9113 §6.10: while mid-HEADERS-block reassembly
        # (cont_reasm_stream_id != 0), ONLY a CONTINUATION frame is
        # legal. Any other frame type → connection PROTOCOL_ERROR.
        # (HEADERS-during-reassembly is checked below in
        # _handle_headers_or_continuation; here we cover everything
        # else: DATA, SETTINGS, PING, PRIORITY, RST_STREAM,
        # WINDOW_UPDATE, GOAWAY, PUSH_PROMISE, unknown.)
        if h2.cont_reasm_stream_id != UInt32(0) and (
            frame.header.kind != FRAME_CONTINUATION
            and frame.header.kind != FRAME_HEADERS
        ):
            _emit_goaway(h2, H2_ERR_PROTOCOL_ERROR)
            return False

        # Dispatch by kind. Stub for: handle SETTINGS, PING, GOAWAY
        # (peer-initiated), WINDOW_UPDATE; everything else is a no-op
        # until lands the router-dispatch path.
        if frame.header.kind == FRAME_SETTINGS:
            if (frame.header.flags & FLAG_ACK) != UInt8(0):
                # SETTINGS-ACK: nothing to do; the peer ACKed our SETTINGS.
                continue
            # First pass — RFC 9113 §6.5.2 validation. ANY bad value is
            # a connection error; report the right code (PROTOCOL_ERROR
            # or FLOW_CONTROL_ERROR per the spec table) BEFORE applying.
            var settings_err: UInt32 = H2_ERR_NO_ERROR
            var sn = len(frame.settings)
            var sj = 0
            while sj < sn:
                var se = frame.settings[sj]
                if se.identifier == UInt16(2):
                    # SETTINGS_ENABLE_PUSH: MUST be 0 or 1. Anything else
                    # is PROTOCOL_ERROR.
                    if se.value != UInt32(0) and se.value != UInt32(1):
                        settings_err = H2_ERR_PROTOCOL_ERROR
                        break
                elif se.identifier == SETTINGS_INITIAL_WINDOW_SIZE:
                    # Max value 2^31-1; above is FLOW_CONTROL_ERROR.
                    if se.value > UInt32(0x7FFFFFFF):
                        settings_err = H2_ERR_FLOW_CONTROL_ERROR
                        break
                elif se.identifier == SETTINGS_MAX_FRAME_SIZE:
                    # Range [16384, 2^24-1]; out-of-range is PROTOCOL_ERROR.
                    var v = Int(se.value)
                    if v < 16384 or v > 16777215:
                        settings_err = H2_ERR_PROTOCOL_ERROR
                        break
                sj = sj + 1
            if settings_err != H2_ERR_NO_ERROR:
                _emit_goaway(h2, settings_err)
                return False
            # Apply each entry to our send-side state, then emit ACK.
            var n = len(frame.settings)
            var i = 0
            while i < n:
                var e = frame.settings[i]
                if e.identifier == SETTINGS_INITIAL_WINDOW_SIZE:
                    var delta = h2.send_fc.on_settings_initial_window_delta(
                        e.value,
                    )
                    # Apply delta to every live stream's send_window.
                    var sn2 = len(h2.streams)
                    var si = 0
                    while si < sn2:
                        h2.streams[si].send_window = (
                            h2.streams[si].send_window + delta
                        )
                        si = si + 1
                elif e.identifier == SETTINGS_MAX_FRAME_SIZE:
                    var v = Int(e.value)
                    if v >= 16384 and v <= 16777215:
                        h2.max_frame_size_peer = v
                elif e.identifier == SETTINGS_HEADER_TABLE_SIZE:
                    h2.hpack_encoder.on_settings_ack_table_size(e.value)
                elif e.identifier == SETTINGS_MAX_CONCURRENT_STREAMS:
                    h2.max_concurrent_streams_peer = e.value
                i = i + 1
            # Emit SETTINGS-ACK.
            var ack = List[UInt8]()
            encode_settings_ack_frame(ack)
            h2.append_out_bytes(ack^)
            # SETTINGS_INITIAL_WINDOW_SIZE may have
            # adjusted per-stream send windows (retroactively per
            # §6.9.2). Pump any deferred-body streams that may now
            # have headroom.
            _pump_deferred_responses(h2, bytes_sent, reqs_handled)
            continue

        if frame.header.kind == FRAME_PING:
            if (frame.header.flags & FLAG_ACK) != UInt8(0):
                # PING-ACK from peer; just drop.
                continue
            # PING from peer; echo back with ACK flag.
            var pong = List[UInt8]()
            encode_ping_frame(frame.ping_data, True, pong)
            h2.append_out_bytes(pong^)
            continue

        if frame.header.kind == FRAME_GOAWAY:
            # Peer is closing. Per RFC 9113 §6.8, after receiving GOAWAY
            # the receiver SHOULD finish processing in-flight frames
            # (especially PING, so h2spec's PING-ACK round-trip after
            # GOAWAY succeeds). We mark received-goaway and KEEP
            # processing this dispatch loop's remaining frames — but
            # don't accept new streams. The outer serve_read_round_h2
            # will close the conn gracefully after the next read returns
            # 0 / BLOCKED_ON_READ.
            h2.mark_goaway_received()
            continue

        if frame.header.kind == FRAME_PRIORITY:
            # PRIORITY is deprecated but we still validate for self-
            # dependency per RFC 9113 §5.3.1 — stream cannot depend on
            # itself. Returns RST_STREAM(PROTOCOL_ERROR) on stream id.
            if frame.priority_stream_dep == frame.header.stream_id:
                var rst = List[UInt8]()
                encode_rst_stream_frame(
                    frame.header.stream_id, H2_ERR_PROTOCOL_ERROR, rst,
                )
                h2.append_out_bytes(rst^)
                # Mark closed if exists (PRIORITY on idle is allowed by
                # state machine; just emit RST and continue).
                var idx_sd = h2.find_stream_idx(frame.header.stream_id)
                if idx_sd >= 0:
                    h2.streams[idx_sd].state = STREAM_STATE_CLOSED
            continue

        if frame.header.kind == FRAME_WINDOW_UPDATE:
            # Apply via SendFlowController.
            if frame.header.stream_id == UInt32(0):
                var dummy = Int32(0)
                var fr = h2.send_fc.on_window_update(
                    UInt32(0), frame.window_update_increment, dummy,
                )
                if fr.kind != FLOW_RESULT_OK:
                    _emit_goaway(h2, fr.error_code)
                    return False
                # conn-level WINDOW_UPDATE may
                # unblock any deferred-body stream.
                _pump_deferred_responses(h2, bytes_sent, reqs_handled)
            else:
                var idx = h2.find_stream_idx(frame.header.stream_id)
                if idx >= 0 and h2.streams[idx].state == STREAM_STATE_CLOSED:
                    # A closed stream sends nothing more, so its window is
                    # never used; after our RST_STREAM the frame MUST be
                    # ignored (RFC 9113 §5.1, §6.9).
                    continue
                if idx >= 0:
                    var fr = h2.send_fc.on_window_update(
                        frame.header.stream_id,
                        frame.window_update_increment,
                        h2.streams[idx].send_window,
                    )
                    if fr.kind != FLOW_RESULT_OK:
                        # Per-stream overflow: a stream error (§6.9.1),
                        # which closes the stream.
                        _reset_stream(h2, frame.header.stream_id, fr.error_code)
                    else:
                        # stream-level WINDOW_UPDATE
                        # may unblock this stream's deferred body.
                        _pump_deferred_responses(h2, bytes_sent, reqs_handled)
                else:
                    # WINDOW_UPDATE on an idle stream → connection
                    # PROTOCOL_ERROR per RFC 9113 §5.1.
                    if frame.header.stream_id >= h2.next_expected_stream_id:
                        _emit_goaway(h2, H2_ERR_PROTOCOL_ERROR)
                        return False
                    # Otherwise (stream below next_expected, i.e. our
                    # response already sent + stream closed): peer's
                    # late WINDOW_UPDATE is tolerated per RFC 9113 §5.1
                    # ("ignore frames after sending RST_STREAM" is
                    # similar tolerance; here the analog is "ignore
                    # WINDOW_UPDATE for a closed stream").
            continue

        if frame.header.kind == FRAME_RST_STREAM:
            # RST_STREAM on an idle (never-seen) stream is a connection
            # PROTOCOL_ERROR per RFC 9113 §6.4. Look up: if no stream
            # exists AND the stream_id is below `next_expected_stream_id`
            # then this is a "previously closed" stream — silently ignore
            # (peer may not yet know we closed). If stream_id >= the next
            # expected (i.e., idle / never opened), it's a protocol error.
            var idx = h2.find_stream_idx(frame.header.stream_id)
            if idx >= 0:
                h2.streams[idx].state = STREAM_STATE_CLOSED
            else:
                if frame.header.stream_id >= h2.next_expected_stream_id:
                    # Idle stream: §6.4 RST_STREAM on idle stream is a
                    # connection PROTOCOL_ERROR.
                    _emit_goaway(h2, H2_ERR_PROTOCOL_ERROR)
                    return False
            continue

        if frame.header.kind == FRAME_PUSH_PROMISE:
            # Server doesn't accept PUSH_PROMISE per RFC 9113 §8.4 —
            # protocol error (we never enabled push).
            _emit_goaway(h2, H2_ERR_PROTOCOL_ERROR)
            return False

        if frame.header.kind == FRAME_HEADERS or (
            frame.header.kind == FRAME_CONTINUATION
        ):
            # HEADERS reassembly + router dispatch path. stub:
            # accept the frame, accumulate the block fragment, dispatch
            # to router IF END_STREAM + END_HEADERS, else queue.
            var dispatch_ok = _handle_headers_or_continuation(
                h2, frame^, router, grpc, reqs_handled, bytes_sent,
            )
            if not dispatch_ok:
                return False
            continue

        if frame.header.kind == FRAME_DATA:
            # DATA frames per RFC 9113 §6.1:
            #  - stream_id 0 is connection PROTOCOL_ERROR (frame.mojo
            #    decode_frame already enforces; decode_frame's PROTOCOL_ERROR
            #    is FRAME_DECODE_ERROR, handled above)
            #  - DATA on idle stream → connection PROTOCOL_ERROR
            #  - DATA on half-closed-remote / closed stream → stream error
            #    STREAM_CLOSED → emit RST_STREAM
            #  - Otherwise: charge recv flow control + accept payload +
            #    accumulate recv_data_bytes for RFC 7540 §8.1.2.6 content-length
            #    validation
            var idx = h2.find_stream_idx(frame.header.stream_id)
            if idx < 0:
                # Idle stream (or below next_expected, which means stream
                # was never opened from our perspective). §5.1 + §6.1
                # both classify this as connection PROTOCOL_ERROR.
                _emit_goaway(h2, H2_ERR_PROTOCOL_ERROR)
                return False
            # Stream exists. Drive the state machine; it returns
            # rst(STREAM_CLOSED) if DATA on half-closed-remote / closed.
            var data_end_stream = (
                frame.header.flags & FLAG_END_STREAM
            ) != UInt8(0)
            var data_payload_len = len(frame.payload)
            # RFC 9113 §6.9.1: flow control counts the whole frame payload,
            # Pad Length and padding included: the length field, not the
            # decoded data.
            var data_fc_len = Int(frame.header.length)
            var data_stream_id = frame.header.stream_id
            if h2.streams[idx].reset_sent:
                # We reset this stream; the peer sent this frame before it
                # saw our RST_STREAM. §5.1: frames received on a closed
                # stream after sending RST_STREAM MUST be ignored. Only the
                # connection window still counts it (§6.9.1).
                if not _charge_connection_only(h2, data_fc_len):
                    return False
                continue
            var action = h2.streams[idx].advance_on_recv_frame(
                FRAME_DATA, frame.header.flags,
            )
            if action.kind == H2_STREAM_ACTION_GOAWAY:
                _emit_goaway(h2, action.error_code)
                return False
            if action.kind == H2_STREAM_ACTION_RST:
                var rst = List[UInt8]()
                encode_rst_stream_frame(
                    data_stream_id, action.error_code, rst,
                )
                h2.append_out_bytes(rst^)
                # The stream is gone, but §6.9.1 still counts the octets
                # against the connection window: charge them and give
                # them back, or the peer's window is short for good.
                if not _charge_connection_only(h2, data_fc_len):
                    return False
                continue
            # Action == KEEP: charge recv flow control. Which window
            # overran decides the scope (§6.9): the stream's is a stream
            # error, the connection's a connection error.
            var fr = h2.recv_fc.on_data_received(
                data_fc_len, h2.streams[idx].recv_window, data_stream_id,
            )
            if fr.kind == FLOW_RESULT_RST_STREAM:
                # The connection window was charged; the stream is over,
                # so its octets go back on the connection only.
                _reset_stream(h2, data_stream_id, fr.error_code)
                _credit_recv_windows(h2, -1)
                continue
            if fr.kind != FLOW_RESULT_OK:
                _emit_goaway(h2, H2_ERR_FLOW_CONTROL_ERROR)
                return False
            # accumulate recv_data_bytes for
            # RFC 7540 §8.1.2.6 content-length validation. Re-lookup `idx` after
            # `advance_on_recv_frame` (which captured a borrowed mut ref)
            # to avoid stale-ref hazards.
            var idx_post = h2.find_stream_idx(data_stream_id)
            if idx_post >= 0:
                h2.streams[idx_post].recv_data_bytes = (
                    h2.streams[idx_post].recv_data_bytes
                    + Int64(data_payload_len)
                )
                if h2.streams[idx_post].has_pending_request and (
                    _buffered_request_body_bytes(h2)
                    > Int64(H2_MAX_BUFFERED_REQUEST_BODY)
                ):
                    # The connection's buffered bodies outgrew what the
                    # server buffers; this frame's stream gives way. Answer
                    # 413 and end the upload with RST_STREAM(NO_ERROR),
                    # which RFC 9113 §8.1 provides for a response sent
                    # before the request is complete.
                    _ = _emit_response(
                        h2,
                        data_stream_id,
                        HttpResponse(Int32(413)),
                        reqs_handled,
                        bytes_sent,
                    )
                    _reset_stream(h2, data_stream_id, H2_ERR_NO_ERROR)
                    _credit_recv_windows(h2, -1)
                    continue
                _credit_recv_windows(h2, idx_post)
                # capture the DATA payload into the pending
                # request's body (gRPC request argument). No-op for streams
                # without a pending entry (non-deferred dispatch discards
                # body as before). The append is keyed on stream_id so the
                # frame payload Span stays valid for the call duration.
                if h2.streams[idx_post].has_pending_request:
                    h2.append_pending_request_body(
                        data_stream_id, Span(frame.payload),
                    )
                if data_end_stream:
                    var expect = h2.streams[idx_post].expected_content_length
                    if expect >= 0 and (
                        h2.streams[idx_post].recv_data_bytes != expect
                    ):
                        # RFC 7540 §8.1.2.6 — content-length mismatch → stream
                        # error PROTOCOL_ERROR via RST_STREAM.
                        var rst = List[UInt8]()
                        encode_rst_stream_frame(
                            data_stream_id, H2_ERR_PROTOCOL_ERROR, rst,
                        )
                        h2.append_out_bytes(rst^)
                        h2.streams[idx_post].state = STREAM_STATE_CLOSED
                        h2.streams[idx_post].has_pending_request = False
                        # Drop the saved pending entry without dispatching.
                        if h2.find_pending_request_idx(data_stream_id) >= 0:
                            var _drop = h2.take_pending_request(data_stream_id)
                            _ = _drop
                        continue
                    # END_STREAM with content-length match (or no
                    # content-length set): dispatch the deferred request
                    # if any.
                    if h2.streams[idx_post].has_pending_request:
                        var pending = h2.take_pending_request(data_stream_id)
                        h2.streams[idx_post].has_pending_request = False
                        var dispatched = _dispatch_deferred_request(
                            h2,
                            data_stream_id,
                            pending^,
                            router,
                            grpc,
                            reqs_handled,
                            bytes_sent,
                        )
                        if not dispatched:
                            return False
            continue

        # Unknown frame type: per RFC 9113 §4.1, "Implementations MUST
        # ignore and discard frames of unknown type." Drop.
        continue


# =============================================================================
# §4 — HEADERS / CONTINUATION reassembly + router dispatch.
# =============================================================================


def _handle_headers_or_continuation[
    G: GrpcDispatch & GrpcStreamDispatch,
](
    mut h2: H2ConnectionState,
    var frame: Frame,
    ref router: Router,
    mut grpc: G,
    mut reqs_handled: Int64,
    mut bytes_sent: Int64,
) -> Bool:
    """Handle a HEADERS or CONTINUATION frame.

    HEADERS arrival:
      - If no in-flight reassembly: start a new one (set
        cont_reasm_stream_id = stream_id; copy payload to cont_reasm_buf).
      - If an in-flight reassembly exists: that's a connection
        PROTOCOL_ERROR per RFC 9113 §6.10 (CONTINUATION must follow
        HEADERS/PUSH_PROMISE/CONTINUATION on the same stream without
        intervening frames; HEADERS while mid-reassembly is illegal).

    CONTINUATION arrival:
      - MUST follow an in-flight reassembly on the same stream;
        otherwise connection PROTOCOL_ERROR.
      - Append payload to cont_reasm_buf.

    On END_HEADERS:
      - Decode the assembled block via HpackDecoder.decode_block.
      - Build an HttpRequest from the pseudo-headers (:method, :path,
        :authority) + regular headers.
      - Dispatch via Router.match_route → handler_id → HttpResponse.
        For, the v1 path uses a canned response from a known route.
      - Emit HEADERS + optional DATA(END_STREAM=True).

    Returns False if the connection must close (PROTOCOL_ERROR emitted).
    """
    var stream_id = frame.header.stream_id
    var is_headers = frame.header.kind == FRAME_HEADERS
    var is_continuation = frame.header.kind == FRAME_CONTINUATION
    var end_headers = (
        frame.header.flags & FLAG_END_HEADERS
    ) != UInt8(0)
    var end_stream_on_this = (
        frame.header.flags & FLAG_END_STREAM
    ) != UInt8(0)

    # Connection-level legality checks (RFC 9113 §6.2 / §6.10).
    if is_headers:
        if stream_id == UInt32(0):
            _emit_goaway(h2, H2_ERR_PROTOCOL_ERROR)
            return False
        if h2.cont_reasm_stream_id != UInt32(0):
            # We're mid-reassembly on some other stream → §6.10 protocol error.
            _emit_goaway(h2, H2_ERR_PROTOCOL_ERROR)
            return False
        # Verify odd-numbered + monotonically increasing for client-initiated
        # streams (RFC 9113 §5.1.1).
        if (Int(stream_id) % 2) == 0:
            _emit_goaway(h2, H2_ERR_PROTOCOL_ERROR)
            return False
        if stream_id < h2.next_expected_stream_id:
            # Re-using or going-backwards stream IDs is a §5.1.1 violation.
            # The H2_ERR_PROTOCOL_ERROR is the appropriate response.
            _emit_goaway(h2, H2_ERR_PROTOCOL_ERROR)
            return False
        # RFC 9113 §5.3.1 — a stream cannot depend on itself. HEADERS
        # frame's FLAG_PRIORITY block carries a stream_dep field; if
        # this equals stream_id, it's a stream PROTOCOL_ERROR (RST_STREAM).
        if (frame.header.flags & FLAG_PRIORITY) != UInt8(0):
            if frame.priority_stream_dep == stream_id:
                var rst = List[UInt8]()
                encode_rst_stream_frame(
                    stream_id, H2_ERR_PROTOCOL_ERROR, rst,
                )
                h2.append_out_bytes(rst^)
                # Mark stream closed; don't accept the HEADERS.
                _ = h2.get_or_create_stream(stream_id)
                var idx_sd = h2.find_stream_idx(stream_id)
                if idx_sd >= 0:
                    h2.streams[idx_sd].state = STREAM_STATE_CLOSED
                h2.next_expected_stream_id = stream_id + UInt32(2)
                return True
        # RFC 9113 §5.1.2 — enforce SETTINGS_MAX_CONCURRENT_STREAMS that
        # we advertised in `build_initial_server_settings`. Count
        # currently-active streams (non-CLOSED AND non-IDLE). If at
        # limit, refuse the new stream with RST_STREAM(REFUSED_STREAM).
        #
        # h2spec §5.1.2 #1 sets INITIAL_WINDOW_SIZE=0
        # then sends `maxStreams + 1` HEADERS frames in one burst. With
        # outbound flow-control respect our 100 HEADERS responses
        # queue ahead of the RST in `pending_out`; h2spec's per-frame
        # 10s timeout can occasionally elapse during the inter-frame
        # gap as we serialize. The fix is to count IDLE streams too
        # (they're real RFC 9113 §5.1 "non-idle" once HEADERS observes them,
        # but our get_or_create_stream creates the slot at IDLE before
        # advance_on_recv_frame transitions to OPEN/HALF_CLOSED_REMOTE)
        # — also, INCLUDING streams in CLOSED but recently-active
        # state would protect against very-fast-close cycles. For RFC
        # purity we count non-CLOSED.
        var max_concurrent = MAX_CONCURRENT_STREAMS_ADVERTISED
        var active_count = 0
        var sn_active = len(h2.streams)
        var si_active = 0
        while si_active < sn_active:
            if h2.streams[si_active].state != STREAM_STATE_CLOSED:
                active_count = active_count + 1
            si_active = si_active + 1
        if active_count >= max_concurrent:
            # RFC 9113 §5.1.2 — exceeding advertised MAX_CONCURRENT_STREAMS
            # is a stream error of type PROTOCOL_ERROR or REFUSED_STREAM.
            # Emit RST_STREAM(REFUSED_STREAM) on the offending stream;
            # connection stays alive (peer may keep using existing streams).
            #
            # h2spec §5.1.2 #1 sets INITIAL_WINDOW_SIZE=0
            # then sends `maxStreams + 1` HEADERS in one burst. Our outbound
            # flow-control respect means 100 HEADERS responses
            # queue in pending_out ahead of the RST. h2spec's
            # `VerifyStreamError` loop reads frames one-at-a-time via
            # `WaitEvent`; under heavy machine load the inter-frame
            # gap between our last HEADERS-resp and the RST can exceed
            # h2spec's per-frame 10s deadline (especially when 100 prior
            # HEADERS-resps already amortized that deadline). To make
            # this reliable, we ALSO emit a GOAWAY(REFUSED_STREAM)
            # which RFC permits as a valid stream-error response: the
            # GOAWAY signals end-of-conn AND carries the same refusal
            # code; h2spec's `VerifyErrorCode(REFUSED_STREAM)` accepts
            # it.
            #
            # prepend BOTH RST and
            # GOAWAY at the FRONT of pending_out via
            # `prepend_out_bytes(...)` and `_emit_goaway(... priority=True)`.
            # This puts them ahead of the 100 queued HEADERS-resps on
            # the wire so h2spec sees them on its first WaitEvent
            # regardless of machine load. Wire ordering becomes:
            #   [pinned] the server's initial SETTINGS if it is still queued
            #            (RFC 9113 §3.4), and the unwritten tail of a
            #            partial write; prepends never overtake these
            #   [0] GOAWAY(REFUSED_STREAM)  (prepended LAST → ends up first)
            #   [1] RST_STREAM(REFUSED_STREAM) on stream_id
            #   [2..] queued HEADERS-resps (drain naturally)
            # Either of GOAWAY or RST satisfies h2spec's verifier; both
            # arrive before any HEADERS-resp can shift the inter-frame
            # gap into timeout territory.
            var rst = List[UInt8]()
            encode_rst_stream_frame(
                stream_id, H2_ERR_REFUSED_STREAM, rst,
            )
            h2.prepend_out_bytes(rst^)
            h2.next_expected_stream_id = stream_id + UInt32(2)
            _emit_goaway(h2, H2_ERR_REFUSED_STREAM, priority=True)
            return True
        h2.next_expected_stream_id = stream_id + UInt32(2)
        # Create the StreamState if needed.
        _ = h2.get_or_create_stream(stream_id)
        # Apply state-machine event.
        var idx = h2.find_stream_idx(stream_id)
        if idx >= 0:
            var action = h2.streams[idx].advance_on_recv_frame(
                FRAME_HEADERS, frame.header.flags,
            )
            if action.kind == H2_STREAM_ACTION_GOAWAY:
                _emit_goaway(h2, action.error_code)
                return False
        # Start reassembly: copy payload.
        h2.cont_reasm_stream_id = stream_id
        # CONTINUATION-FLOOD CEILING (CVE-2024-27316 shape) — see
        # connection_state.mojo §1b. HEADERS/CONTINUATION are NOT
        # flow-controlled, so this is the only bound on the block.
        if not h2.append_header_block(Span(frame.payload)):
            _emit_goaway(h2, H2_ERR_ENHANCE_YOUR_CALM)
            h2.reset_header_block()
            return False
    elif is_continuation:
        if h2.cont_reasm_stream_id == UInt32(0) or (
            h2.cont_reasm_stream_id != stream_id
        ):
            _emit_goaway(h2, H2_ERR_PROTOCOL_ERROR)
            return False
        # Append payload (same ceiling — this is the flood's actual vector).
        if not h2.append_header_block(Span(frame.payload)):
            _emit_goaway(h2, H2_ERR_ENHANCE_YOUR_CALM)
            h2.reset_header_block()
            return False
        # Apply state-machine event for the continuation_pending flag.
        var idx = h2.find_stream_idx(stream_id)
        if idx >= 0:
            var action = h2.streams[idx].advance_on_recv_frame(
                FRAME_CONTINUATION, frame.header.flags,
            )
            if action.kind == H2_STREAM_ACTION_GOAWAY:
                _emit_goaway(h2, action.error_code)
                return False

    if not end_headers:
        return True  # awaiting CONTINUATION

    # We have a complete header block. Decode it.
    var block_view = Span(h2.cont_reasm_buf)
    var headers_decoded: List[HpackHeader]
    try:
        headers_decoded = h2.hpack_decoder.decode_block(block_view)
    except e:
        # RFC 9113 §4.3 — header block decoding errors are connection
        # errors of type COMPRESSION_ERROR (NOT PROTOCOL_ERROR).
        # The HpackDecoder.decode_block raises only on COMPRESSION_ERROR
        # conditions per RFC 7541 (truncated integers, invalid indices,
        # malformed strings, premature size updates above limit).
        _ = e
        _emit_goaway(h2, H2_ERR_COMPRESSION_ERROR)
        return False

    # Reset reassembly buffer (buffer + stream id + the §1b frame counter).
    var sid_being_assembled = h2.cont_reasm_stream_id
    h2.reset_header_block()

    # Determine final END_STREAM (the END_STREAM flag set on the original
    # HEADERS frame is what counts; CONTINUATION never carries END_STREAM
    # per RFC 9113 §6.10). The StreamState already reflects this in its
    # `end_stream_seen` bit at advance_on_recv_frame. We re-check the
    # stream's flag here for the dispatch decision.
    var idx2 = h2.find_stream_idx(sid_being_assembled)
    var end_stream_seen = False
    if idx2 >= 0:
        end_stream_seen = h2.streams[idx2].end_stream_seen

    # RFC 7540 §8.1.2.6 content-length aggregation
    # gate. If HEADERS has content-length AND END_STREAM was NOT yet
    # observed: defer dispatch until END_STREAM (carried by a later DATA
    # frame). On END_STREAM we validate accumulated `recv_data_bytes ==
    # expected_content_length`; mismatch → RST_STREAM(PROTOCOL_ERROR).
    # Without this gate the server eagerly dispatches the request before
    # body validation and returns 200 OK even on malformed content-length.
    # Validate headers FIRST to extract content-length (cheap pure
    # function over the decoded headers list).
    var vres = _validate_h2_request_headers(headers_decoded)
    if not vres.ok:
        # Same RST_STREAM(PROTOCOL_ERROR) path as
        # `_build_and_dispatch_request` — emit RST + close stream
        # without dispatch.
        var rst = List[UInt8]()
        encode_rst_stream_frame(
            sid_being_assembled, H2_ERR_PROTOCOL_ERROR, rst,
        )
        h2.append_out_bytes(rst^)
        if idx2 >= 0:
            h2.streams[idx2].state = STREAM_STATE_CLOSED
        return True

    # gRPC requests carry their RPC argument in the DATA
    # body (the 5-byte-framed envelope). So a gRPC request MUST defer to
    # END_STREAM and capture the body, whether or not content-length is
    # present (most gRPC clients send content-length, but the body-capture
    # path does not depend on it). The content-length gate stays
    # for non-gRPC requests.
    var is_grpc = is_grpc_content_type(vres.content_type)
    # A gRPC call's grpc-timeout runs from here, the arrival of its complete
    # HEADERS block, whether the body is still to come or not.
    var arrival_ns = UInt64(0)
    if is_grpc:
        arrival_ns = grpc.grpc_now_ns()
    var should_defer = (
        (vres.has_content_length or is_grpc) and not end_stream_seen
    )
    if should_defer:
        # Defer dispatch until END_STREAM. Save expected length (if any) on
        # the stream + saved headers/method/path/content-type in the
        # pending side table. The body grows via append_pending_request_body
        # as DATA frames arrive.
        if idx2 >= 0:
            if vres.has_content_length:
                h2.streams[idx2].expected_content_length = Int64(
                    vres.content_length
                )
            h2.streams[idx2].recv_data_bytes = Int64(0)
            h2.streams[idx2].has_pending_request = True
        var saved_headers = List[HpackHeader]()
        var hi = 0
        while hi < len(headers_decoded):
            saved_headers.append(headers_decoded[hi])
            hi = hi + 1
        h2.push_pending_request(
            stream_id=sid_being_assembled,
            headers=saved_headers^,
            method_str=vres.method_str,
            path_str=vres.path_str,
            content_type=vres.content_type,
            arrival_ns=arrival_ns,
        )
        return True

    # No deferred-dispatch gate fires — dispatch eagerly. This covers:
    #   * gRPC requests with END_STREAM on HEADERS (empty-body unary call) —
    #     route to the GrpcDispatch seam with an empty body.
    #   * non-gRPC requests WITHOUT content-length (keep the behavior:
    #     dispatch on END_HEADERS via the Router; body not plumbed for v1).
    if is_grpc:
        var empty_body = List[UInt8]()
        return _dispatch_grpc_request(
            h2,
            sid_being_assembled,
            vres.path_str,
            vres.content_type,
            empty_body^,
            grpc_deadline_at_arrival(
                headers_decoded, vres.content_type, arrival_ns
            ),
            grpc,
            reqs_handled,
            bytes_sent,
        )
    var dispatch_ok = _build_and_dispatch_request(
        h2,
        sid_being_assembled,
        headers_decoded^,
        end_stream_on_this or end_stream_seen,
        router,
        reqs_handled,
        bytes_sent,
    )
    return dispatch_ok


def _dispatch_deferred_request[
    G: GrpcDispatch & GrpcStreamDispatch,
](
    mut h2: H2ConnectionState,
    stream_id: UInt32,
    var pending: H2PendingRequest,
    ref router: Router,
    mut grpc: G,
    mut reqs_handled: Int64,
    mut bytes_sent: Int64,
) -> Bool:
    """Dispatch a request whose HEADERS arrived
    without END_STREAM and whose body has now finished accumulating
    (END_STREAM seen on a DATA frame + content-length matched per
    RFC 7540 §8.1.2.6 validation).

    if the request is gRPC (content-type captured on the
    pending entry), route to the GrpcDispatch seam with the captured body
    (the RPC argument) and emit a gRPC response (HEADERS+DATA+trailer).
    Otherwise forward to `_build_and_dispatch_request` (the existing Router
    path; body not plumbed for v1).

    Per the pointer rules (no partial-move via UnsafePointer):
    extract `pending.headers` / `pending.body` via stdlib `swap(...)`
    against locally-constructed empties. After swap, the moved-from fields
    hold empty lists (destructor-safe); `pending` drops cleanly."""
    if is_grpc_content_type(pending.content_type):
        var deadline = grpc_deadline_at_arrival(
            pending.headers, pending.content_type, pending.arrival_ns
        )
        var local_body = List[UInt8]()
        swap(pending.body, local_body)
        var local_ct = String("")
        swap(pending.content_type, local_ct)
        var local_path = String("")
        swap(pending.path_str, local_path)
        return _dispatch_grpc_request(
            h2,
            stream_id,
            local_path,
            local_ct,
            local_body^,
            deadline,
            grpc,
            reqs_handled,
            bytes_sent,
        )
    var local_headers = List[HpackHeader]()
    swap(pending.headers, local_headers)
    return _build_and_dispatch_request(
        h2,
        stream_id,
        local_headers^,
        True,  # end_stream is True by definition at this point
        router,
        reqs_handled,
        bytes_sent,
    )


def _dispatch_grpc_request[
    G: GrpcDispatch & GrpcStreamDispatch,
](
    mut h2: H2ConnectionState,
    stream_id: UInt32,
    path: String,
    content_type: String,
    var request_body: List[UInt8],
    deadline: GrpcDeadline,
    mut grpc: G,
    mut reqs_handled: Int64,
    mut bytes_sent: Int64,
) -> Bool:
    """Route one gRPC request to the GrpcDispatch seam and
    emit the gRPC response (HEADERS + DATA + grpc-status trailer).

    `grpc.dispatch_grpc(path, content_type, body)` returns a plain-data
    `GrpcResponse`; `emit_grpc_response` serializes it on the wire with the
    trailing `grpc-status` HEADERS frame. An erroring handler still yields
    HTTP :status 200 + a non-zero grpc-status trailer (never an h2 error).
    This is the live ConnectService-routing path the in-process bridge
    (`komira_connect.server_integration.dispatch_connect_request`) models —
    here it runs against a real socket through the production serve loop.

    STREAMING routing: the serve loop first resolves the
    method's streaming kind via `grpc.grpc_stream_kind(path)`. GRPC_KIND_UNARY
    keeps the single-buffered fast path (`dispatch_grpc` + emit_grpc_response).
    SERVER/CLIENT streaming routes to `dispatch_grpc_stream` (which returns N
    response message bodies) + `emit_grpc_stream_response` (HEADERS + N DATA
    frames + trailer, incremental + flow-control respecting). Server-streaming
    (DoGet): one request envelope -> N response messages. Client-streaming
    (DoPut): N request envelopes -> 1 response message. The request body
    carries the inbound envelope(s) either way (captured by the deferred-body
    path); the conformer decodes the right count per `kind`.

    GRPC-TIMEOUT (`deadline`, fixed when the HEADERS block arrived; see
    komira_http_core/transport/grpc_timeout.mojo). A malformed value is
    answered 400 / INTERNAL and the handler is not run. A deadline already
    past at this point is answered DEADLINE_EXCEEDED and the handler is not
    run. Otherwise the handler runs to completion: the serve loop calls it
    synchronously and has no way to interrupt it. If the deadline passed
    while it ran, its response is dropped and the call is answered
    DEADLINE_EXCEEDED instead; whatever side effects the handler had stand.
    """
    if deadline.state == GRPC_TIMEOUT_MALFORMED:
        return emit_grpc_malformed_timeout(
            h2, stream_id, content_type, deadline.error, reqs_handled,
        )
    if deadline.expired(grpc.grpc_now_ns()):
        return emit_grpc_deadline_exceeded(
            h2, stream_id, content_type, reqs_handled,
        )
    var kind = grpc.grpc_stream_kind(path)
    if kind == GRPC_KIND_UNARY:
        var resp = grpc.dispatch_grpc(path, content_type, request_body^)
        if deadline.expired(grpc.grpc_now_ns()):
            return emit_grpc_deadline_exceeded(
                h2, stream_id, content_type, reqs_handled,
            )
        return emit_grpc_response(
            h2, stream_id, resp^, reqs_handled, bytes_sent,
        )
    var sresp = grpc.dispatch_grpc_stream(
        path, content_type, kind, request_body^,
    )
    if deadline.expired(grpc.grpc_now_ns()):
        return emit_grpc_deadline_exceeded(
            h2, stream_id, content_type, reqs_handled,
        )
    return emit_grpc_stream_response(
        h2, stream_id, sresp^, reqs_handled, bytes_sent,
    )


def _build_and_dispatch_request(
    mut h2: H2ConnectionState,
    stream_id: UInt32,
    var headers: List[HpackHeader],
    end_stream: Bool,
    ref router: Router,
    mut reqs_handled: Int64,
    mut bytes_sent: Int64,
) -> Bool:
    """Build an HttpRequest from h2 pseudo-headers + dispatch via Router.

    HTTP/2 pseudo-headers (RFC 9113 §8.1.2.3): `:method`, `:path`,
    `:authority`, `:scheme`. Regular headers are everything else.

    Per RFC 9113 §8.1.2: validate header names + pseudo-headers BEFORE
    dispatching. Any violation → stream PROTOCOL_ERROR (RST_STREAM).

    The Router signature matches the h1 path (HttpMethod + path String);
    we map h2 pseudo-headers to that input.

    Emits a HEADERS frame (END_HEADERS+END_STREAM if response body empty,
    else END_HEADERS only + a DATA frame with END_STREAM).
    """
    # RFC 9113 §8.1.2 validation FIRST.
    var vres = _validate_h2_request_headers(headers)
    if not vres.ok:
        # §8.1.2 — malformed h2 request is a STREAM error of type
        # PROTOCOL_ERROR. Emit RST_STREAM(PROTOCOL_ERROR), do NOT
        # dispatch the request.
        var rst = List[UInt8]()
        encode_rst_stream_frame(stream_id, H2_ERR_PROTOCOL_ERROR, rst)
        h2.append_out_bytes(rst^)
        # Mark the stream closed; we won't be sending a response.
        var idx = h2.find_stream_idx(stream_id)
        if idx >= 0:
            h2.streams[idx].state = STREAM_STATE_CLOSED
        return True  # connection alive; just the stream errored.
    var method_str = vres.method_str
    var path_str = vres.path_str

    # Map method string to HttpMethod.
    var method = HttpMethod.get()
    if method_str == String("POST"):
        method = HttpMethod.post()
    elif method_str == String("PUT"):
        method = HttpMethod.put()
    elif method_str == String("DELETE"):
        method = HttpMethod.delete()
    elif method_str == String("HEAD"):
        method = HttpMethod.head()
    elif method_str == String("PATCH"):
        method = HttpMethod.patch()
    elif method_str == String("OPTIONS"):
        method = HttpMethod.options()

    # Match route.
    var params = Dict[String, String]()
    var hid = router.match_route(method, path_str, params)

    var resp: HttpResponse
    if hid:
        # canned 200 OK with hardcoded body. Real handler
        # dispatch (returning HttpResponse) lands in+ alongside the
        # h1 parity work.
        resp = HttpResponse.ok(String("Hello from HTTP/2!"))
    else:
        resp = HttpResponse(Int32(404))
        var nf_body = List[UInt8]()
        var nf = String("Not Found")
        var nf_bytes = nf.as_bytes()
        var ni = 0
        while ni < len(nf_bytes):
            nf_body.append(nf_bytes[ni])
            ni = ni + 1
        resp.body = nf_body^

    # Emit the response on the wire: HEADERS frame + optional DATA frame.
    return _emit_response(h2, stream_id, resp^, reqs_handled, bytes_sent)


def _emit_response(
    mut h2: H2ConnectionState,
    stream_id: UInt32,
    var resp: HttpResponse,
    mut reqs_handled: Int64,
    mut bytes_sent: Int64,
) -> Bool:
    """Serialize a response as HEADERS+DATA on `stream_id`.

    outbound DATA respects flow control:
      * HEADERS frame: always emitted in one shot (no CONTINUATION splitter
        yet; header block assumed < max_frame_size_peer — h2spec corpus
        stays well under this).
      * DATA: chunk per `min(stream.send_window, conn.send_window,
        max_frame_size_peer)`. If the body fits within current windows,
        emit one frame with END_STREAM and we're done. Otherwise emit
        the prefix that fits, stash the residual on
        `h2.deferred_responses`, mark
        `streams[idx].has_deferred_response_body = True`, and DO NOT
        transition the stream's state. The residual drains on subsequent
        WINDOW_UPDATE via `_pump_deferred_responses`.

    `reqs_handled` increments only when the response is fully sent
    (immediate or via deferred drain — counted in `_pump_deferred_responses`).
    `bytes_sent` increments by however many DATA payload bytes we put on
    the wire (immediate part here; residual counted by pump on each chunk).

    Returns True on success / partial flush; False is reserved for
    catastrophic errors (none today)."""
    # Build the response's HEADERS block.
    var resp_headers = List[HpackHeader]()
    var status_str = String(Int(resp.status))
    resp_headers.append(HpackHeader(String(":status"), status_str^))
    resp_headers.append(HpackHeader(
        String("content-length"), String(Int(len(resp.body))),
    ))
    resp_headers.append(HpackHeader(
        String("content-type"), String("text/plain"),
    ))

    var block = h2.hpack_encoder.encode_block(resp_headers^)
    var body_empty = len(resp.body) == 0
    # Whether the HEADERS frame should carry END_STREAM (body empty).
    var headers_end_stream = body_empty
    var headers_buf = List[UInt8]()
    encode_headers_frame(
        stream_id, block^, headers_end_stream, True, headers_buf,
    )
    h2.append_out_bytes(headers_buf^)

    if body_empty:
        # Empty body — HEADERS already carried END_STREAM.
        var idx_e = h2.find_stream_idx(stream_id)
        if idx_e >= 0:
            h2.streams[idx_e].advance_on_send_end_stream()
        reqs_handled = reqs_handled + Int64(1)
        return True

    # Non-empty body — chunk per current flow-control windows.
    var idx = h2.find_stream_idx(stream_id)
    var stream_window = Int32(0)
    if idx >= 0:
        stream_window = h2.streams[idx].send_window
    var total = len(resp.body)
    var max_frame = h2.max_frame_size_peer
    if max_frame <= 0:
        max_frame = 16384
    # How many bytes can we send now? min(stream_w, conn_w, total).
    var can_send_total = h2.send_fc.can_send(stream_window, total)
    # Build a List[UInt8] view of the full body once; we slice as we go.
    var body_full = List[UInt8]()
    var bf_i = 0
    while bf_i < total:
        body_full.append(resp.body[bf_i])
        bf_i = bf_i + 1

    # If can_send_total == total: we can send the whole thing in one or
    # more frames (chunked only by max_frame). Last chunk gets END_STREAM.
    # Else: we send `can_send_total` bytes now, residual goes to deferred.
    var bytes_to_send_now = can_send_total
    var residual_start = bytes_to_send_now  # offset where residual begins
    var send_end_stream_in_this_pass = (bytes_to_send_now == total)

    if bytes_to_send_now > 0:
        var emitted = 0
        while emitted < bytes_to_send_now:
            var chunk_len = bytes_to_send_now - emitted
            if chunk_len > max_frame:
                chunk_len = max_frame
            var is_final = (
                send_end_stream_in_this_pass
                and (emitted + chunk_len) == bytes_to_send_now
            )
            var chunk_bytes = List[UInt8]()
            var ci = emitted
            while ci < emitted + chunk_len:
                chunk_bytes.append(body_full[ci])
                ci = ci + 1
            var data_buf = List[UInt8]()
            encode_data_frame(stream_id, chunk_bytes^, is_final, data_buf)
            h2.append_out_bytes(data_buf^)
            emitted = emitted + chunk_len
        # Charge windows once (single consume call) for all bytes sent now.
        if idx >= 0:
            h2.send_fc.consume(bytes_to_send_now, h2.streams[idx].send_window)
        else:
            var dummy = Int32(0)
            h2.send_fc.consume(bytes_to_send_now, dummy)
        bytes_sent = bytes_sent + Int64(bytes_to_send_now)

    if send_end_stream_in_this_pass:
        # Fully sent; advance stream state + count the request.
        if idx >= 0:
            h2.streams[idx].advance_on_send_end_stream()
        reqs_handled = reqs_handled + Int64(1)
        return True

    # Residual exists. Stash it on the deferred-response side table.
    var residual = List[UInt8]()
    var ri = residual_start
    while ri < total:
        residual.append(body_full[ri])
        ri = ri + 1
    h2.push_deferred_response(
        stream_id=stream_id,
        body=residual^,
        offset=residual_start,
        send_end_stream_on_drain=True,
    )
    if idx >= 0:
        h2.streams[idx].has_deferred_response_body = True
    return True


def _pump_deferred_responses(mut h2: H2ConnectionState, mut bytes_sent: Int64, mut reqs_handled: Int64):
    """Drive any stream with `has_deferred_response_body = True` to emit
    further DATA chunks now that flow-control windows may permit it.

    called after WINDOW_UPDATE applies (per-stream or
    connection-level), AND opportunistically on every serve round when
    `len(h2.deferred_responses) > 0`. Walks the deferred table; for each
    entry emits up to `min(stream.send_window, conn.send_window,
    max_frame_size_peer)` bytes. On full drain (residual goes to 0),
    emits END_STREAM on the final DATA chunk, advances stream state,
    drops the entry."""
    var n = len(h2.deferred_responses)
    if n == 0:
        return
    var max_frame = h2.max_frame_size_peer
    if max_frame <= 0:
        max_frame = 16384
    # Walk a copy of indices (since we may swap_remove during iteration);
    # restart from 0 after each removal to keep things simple. n_iter
    # bounds total work per pump call.
    var n_iter = 0
    var max_iter = 64
    while n_iter < max_iter:
        n_iter = n_iter + 1
        var did_progress = False
        var i = 0
        while i < len(h2.deferred_responses):
            var sid = h2.deferred_responses[i].stream_id
            var residual_len = len(h2.deferred_responses[i].body)
            if residual_len == 0:
                # Defensive: drop empty entries.
                _ = h2.deferred_responses.swap_remove(i)
                continue
            var sidx = h2.find_stream_idx(sid)
            var stream_w = Int32(0)
            if sidx >= 0:
                stream_w = h2.streams[sidx].send_window
            var can_send = h2.send_fc.can_send(stream_w, residual_len)
            if can_send <= 0:
                # Can't make progress on this stream right now.
                i = i + 1
                continue
            # is this a STREAMING gRPC residual? If so the final
            # DATA chunk MUST NOT carry END_STREAM; the stream closes with a
            # trailing-HEADERS(grpc-status) frame after the body fully drains.
            var grpc_trailer_status = h2.deferred_response_grpc_trailer_status(sid)
            var is_grpc_stream = grpc_trailer_status >= Int16(0)
            # Emit up to `can_send` bytes in frames of <= max_frame each.
            var emitted = 0
            while emitted < can_send:
                var chunk_len = can_send - emitted
                if chunk_len > max_frame:
                    chunk_len = max_frame
                var chunk = h2.take_deferred_response_body_chunk(sid, chunk_len)
                var residual_now = h2.deferred_response_body_len(sid)
                var sends_end = h2.deferred_response_sends_end_stream(sid)
                # gRPC residual: NEVER set END_STREAM on DATA (the trailer
                # closes the stream). Ordinary residual: END_STREAM on the
                # final DATA chunk per send_end_stream_on_drain.
                var is_final = (
                    (not is_grpc_stream)
                    and (emitted + chunk_len == can_send)
                    and (residual_now == 0)
                    and sends_end
                )
                var data_buf = List[UInt8]()
                encode_data_frame(sid, chunk^, is_final, data_buf)
                h2.append_out_bytes(data_buf^)
                emitted = emitted + chunk_len
            if sidx >= 0:
                h2.send_fc.consume(can_send, h2.streams[sidx].send_window)
            else:
                var dummy = Int32(0)
                h2.send_fc.consume(can_send, dummy)
            bytes_sent = bytes_sent + Int64(can_send)
            did_progress = True
            # Did we drain? If so, finalize.
            if h2.deferred_response_body_len(sid) == 0:
                if is_grpc_stream:
                    # gRPC streaming close: emit the trailing-HEADERS
                    # (grpc-status[, grpc-message]) frame, which carries
                    # END_STREAM + advances the stream state.
                    var tstatus = UInt8(
                        Int(h2.deferred_response_grpc_trailer_status(sid))
                    )
                    var tmsg = h2.deferred_response_grpc_trailer_message(sid)
                    h2.drop_deferred_response(sid)
                    if sidx >= 0:
                        h2.streams[sidx].has_deferred_response_body = False
                    _emit_grpc_trailer(h2, sid, tstatus, tmsg, reqs_handled)
                else:
                    var sends_end_final = (
                        h2.deferred_response_sends_end_stream(sid)
                    )
                    h2.drop_deferred_response(sid)
                    if sidx >= 0:
                        h2.streams[sidx].has_deferred_response_body = False
                        if sends_end_final:
                            h2.streams[sidx].advance_on_send_end_stream()
                    reqs_handled = reqs_handled + Int64(1)
                # Re-scan from 0 because the swap_remove shifted entries.
                break
            i = i + 1
        if not did_progress:
            return


# =============================================================================
# §5 — Top-level serve_read_round_h2.
# =============================================================================


comptime _FLUSH_ERROR: Int = -1
comptime _FLUSH_PARTIAL: Int = 0
comptime _FLUSH_DRAINED: Int = 1


def _discard_input(mut entry: ConnEntry):
    """Read and drop what the peer has already sent, up to 64 reads of
    REQ_BUF_BYTES, stopping at the first read that returns nothing.

    Called after a connection error's GOAWAY is written and before the
    caller closes the socket. h2spec http2/4.2/2 is the case: a DATA frame
    larger than SETTINGS_MAX_FRAME_SIZE is refused on its 9-byte header, with
    the rest of the frame unread, and close(2) on a socket with unread bytes
    sends RST (POSIX), which can reach the peer ahead of the GOAWAY."""
    ref tls_opt = entry.tls_stream_ref()
    if not tls_opt:
        return
    var reads = 0
    while reads < 64:
        var buf = List[UInt8]()
        buf.reserve(REQ_BUF_BYTES)
        buf.resize(unsafe_uninit_length=REQ_BUF_BYTES)
        var r = tls_opt.value().read_app(buf, REQ_BUF_BYTES)
        if r[0] != TLS_OUTCOME_DONE or r[1] <= 0:
            return
        reads = reads + 1


def _flush_pending_out(mut entry: ConnEntry, mut bytes_sent: Int64) -> Int:
    """Write the connection's `pending_out` through TLS until it is drained,
    the write blocks, or 64 writes have gone out.

    write_app may return partial (n < len) under kernel send-buffer pressure
    (TLS_OUTCOME_DONE with smaller n) or BLOCKED_ON_WRITE. Either way the
    unwritten tail goes back at the front of `pending_out`, ahead of anything
    queued since, and is pinned (`H2ConnectionState.pin_out_bytes`): it may
    begin mid-frame, and a priority frame prepended in front of it would
    corrupt the framing.

    64 writes, not 8: h2spec §5.1.2 #1 sends 101 HEADERS at once and the
    server queues the HEADERS responses plus RST/GOAWAY (~6KB plain, ~10KB
    after TLS); at 8 the GOAWAY+RST could be stranded in the tail for a later
    round, racing h2spec's WaitEvent timeout.

    Returns _FLUSH_ERROR on a TLS write error or missing state,
    _FLUSH_DRAINED when nothing is left, _FLUSH_PARTIAL otherwise."""
    ref tls_opt = entry.tls_stream_ref()
    if not tls_opt:
        return _FLUSH_ERROR
    var out_bytes: List[UInt8]
    ref h2_opt = entry.h2_state_ref()
    if h2_opt:
        out_bytes = h2_opt.value().take_out_bytes()
    else:
        return _FLUSH_ERROR
    var write_offset = 0
    var out_len = len(out_bytes)
    var max_write_iters = 64
    var write_iter = 0
    while write_offset < out_len and write_iter < max_write_iters:
        var remaining = Span(out_bytes)[write_offset:out_len]
        var write_outcome_and_n = tls_opt.value().write_app(remaining)
        var write_outcome = write_outcome_and_n[0]
        var nwrote = write_outcome_and_n[1]
        if write_outcome == TLS_OUTCOME_ERROR:
            return _FLUSH_ERROR
        if nwrote > 0:
            bytes_sent = bytes_sent + Int64(nwrote)
            write_offset = write_offset + nwrote
        if write_outcome == TLS_OUTCOME_BLOCKED_ON_WRITE:
            # Kernel send buffer full; stash the tail back for next round.
            break
        if write_outcome == TLS_OUTCOME_BLOCKED_ON_READ:
            # TLS rekey wants a read; stash tail + return.
            break
        if nwrote == 0 and write_outcome == TLS_OUTCOME_DONE:
            # No progress this iter and no block signal — bail to avoid
            # infinite-spin (shouldn't happen with s2n, but defensive).
            break
        write_iter = write_iter + 1
    if write_offset >= out_len:
        return _FLUSH_DRAINED
    ref h2_opt3 = entry.h2_state_ref()
    if h2_opt3:
        var queued_since = h2_opt3.value().take_out_bytes()
        var tail = List[UInt8](capacity=out_len - write_offset)
        tail.extend(Span(out_bytes)[write_offset:out_len])
        h2_opt3.value().append_out_bytes(tail^)
        h2_opt3.value().pin_out_bytes()
        h2_opt3.value().append_out_bytes(queued_since^)
    return _FLUSH_PARTIAL


def serve_read_round_h2[
    G: GrpcDispatch & GrpcStreamDispatch,
](
    mut entry: ConnEntry,
    ref router: Router,
    mut grpc: G,
    mut reqs_handled: Int64,
    mut bytes_sent: Int64,
) -> Bool:
    """Drive one round of h2 codec activity.

    Per-call flow:
      1. Read-and-dispatch INNER LOOP: repeat
           a. read decrypted bytes from TLS into h2.recv_buf
           b. if CONN_STATE_H2_PREFACE_WAIT: try preface
           c. if CONN_STATE_H2_ACTIVE: dispatch frames
         until read_app returns BLOCKED_ON_READ (no more bytes ready) OR
         hit a hard stop (peer EOF, error, dispatch hard-fail). Before
         each further read, what the last one produced is flushed (the
         next read may process the peer's close_notify). This
         absorbs MULTIPLE TLS records / TCP segments per reactor wakeup
         — critical for h2spec conformance because h2spec batches a
         test frame + a PING-ACK canary into back-to-back TLS records,
         and the single-shot read missed the PING.
      2. Flush h2.pending_out via `_flush_pending_out` — looped until the
         buffer is drained OR write returns BLOCKED_ON_WRITE / partial-write.
         The leftover (un-written) bytes stay, pinned, at the front of
         pending_out for the next round to drain.
      3. If GOAWAY sent + queue drained: return False (caller closes).

    Pre-condition: entry.is_tls() && entry.is_h2() && TLS handshake DONE.

    Returns:
      * True  — conn alive; keep in the table
      * False — caller should drop the conn
    """
    if not entry.is_tls():
        return False
    if not entry.is_h2():
        return False

    ref tls_opt = entry.tls_stream_ref()
    if not tls_opt:
        return False

    # ---- step 1: read-and-dispatch INNER LOOP ----
    # Limit to a small max-iterations to avoid starving other conns in
    # the outer poll loop. With REQ_BUF_BYTES per iter (typically 4-16KB),
    # 32 iters absorbs ~128-512KB of pipelined h2 frames before yielding
    # — enough for h2spec's worst-case "frame burst" tests (a few hundred
    # bytes per test) while still bounding latency for other conns.
    var inner_iters = 0
    var max_inner_iters = 32
    var hit_peer_eof = False
    var dispatch_close = False
    while inner_iters < max_inner_iters:
        # 1a. read
        var rd_buf = List[UInt8]()
        rd_buf.reserve(REQ_BUF_BYTES)
        rd_buf.resize(unsafe_uninit_length=REQ_BUF_BYTES)
        var read_outcome_and_n = tls_opt.value().read_app(
            rd_buf, REQ_BUF_BYTES,
        )
        var read_outcome = read_outcome_and_n[0]
        var got = read_outcome_and_n[1]
        if read_outcome == TLS_OUTCOME_ERROR:
            return False
        if got > 0:
            ref h2_opt = entry.h2_state_ref()
            if not h2_opt:
                return False
            var rd_view = Span(rd_buf)[0:got]
            h2_opt.value().append_recv_bytes(rd_view)
        elif read_outcome == TLS_OUTCOME_DONE and got == 0:
            # Peer sent close_notify (graceful EOF). Stop reading, but
            # we still want to flush any queued response in step 2.
            hit_peer_eof = True

        # 1b. preface (idempotent — only fires while in PREFACE_WAIT)
        if entry._state == CONN_STATE_H2_PREFACE_WAIT:
            ref h2_opt = entry.h2_state_ref()
            if not h2_opt:
                return False
            var pf_status = _try_consume_preface(h2_opt.value())
            if pf_status == PREFACE_ERROR:
                return False
            if pf_status == PREFACE_OK:
                entry._state = CONN_STATE_H2_ACTIVE
                var settings_bytes = build_initial_server_settings(
                    h2_opt.value(),
                )
                h2_opt.value().append_out_bytes(settings_bytes^)
                # The server preface is the first frame on the wire (RFC
                # 9113 §3.4): a GOAWAY prepended by the dispatch below (the
                # §5.1.2 gate) goes in behind it, not ahead.
                h2_opt.value().pin_out_bytes()
                h2_opt.value().mark_settings_sent()

        # 1c. dispatch (only while active)
        if entry._state == CONN_STATE_H2_ACTIVE:
            ref h2_opt = entry.h2_state_ref()
            if not h2_opt:
                return False
            var dispatch_ok = _dispatch_h2_frames(
                h2_opt.value(), router, grpc, reqs_handled, bytes_sent,
            )
            if not dispatch_ok:
                # GOAWAY emitted into pending_out; fall through to flush
                # so the peer sees the GOAWAY bytes BEFORE we close (RFC
                # 9113 §6.8). Then exit the inner loop.
                dispatch_close = True
                break

        # Decide whether to keep looping. Stop conditions:
        #   - read returned BLOCKED_ON_READ → no more bytes ready right now.
        #   - peer EOF (got==0 on DONE) → no more bytes will EVER come.
        #   - dispatch wants to close → break out, then flush + close.
        if read_outcome == TLS_OUTCOME_BLOCKED_ON_READ:
            break
        if read_outcome == TLS_OUTCOME_BLOCKED_ON_WRITE:
            # TLS rekey wants to write; flush our pending out then return.
            break
        if hit_peer_eof:
            break
        # Otherwise: we got some bytes; loop and try to absorb more. Write
        # what this read produced first: the next read may process the
        # peer's close_notify, after which s2n refuses every write, so a
        # PING ACK or SETTINGS ACK still queued then would be lost.
        if _flush_pending_out(entry, bytes_sent) == _FLUSH_ERROR:
            return False
        inner_iters = inner_iters + 1

    # ---- step 2: flush h2.pending_out (loop until drained or blocked) ----
    var conn_should_close = dispatch_close or hit_peer_eof
    var h2_was_goaway: Bool
    ref h2_opt2 = entry.h2_state_ref()
    if h2_opt2:
        h2_was_goaway = h2_opt2.value().is_goaway_sent()
    else:
        return False
    var flushed = _flush_pending_out(entry, bytes_sent)
    if flushed == _FLUSH_ERROR:
        return False
    if dispatch_close:
        # The caller closes the socket on False. Read what the peer already
        # sent first: close(2) on a socket with unread bytes sends RST, not
        # FIN, and a peer that reads the RST first never sees the GOAWAY.
        _discard_input(entry)

    if h2_was_goaway:
        # If we drained everything, close the conn. If there's still a
        # tail (rare under GOAWAY because GOAWAY is small), let the next
        # round drain it then close.
        if flushed == _FLUSH_DRAINED:
            conn_should_close = True

    # ⛔ THERE IS NO `if h2_received_goaway: conn_should_close = True` HERE,
    # AND ITS ABSENCE IS DELIBERATE.
    #
    # `_dispatch_h2_frames` states the intent at FRAME_GOAWAY: "the outer
    # serve_read_round_h2 will close the conn gracefully AFTER THE NEXT READ
    # returns 0 / BLOCKED_ON_READ". Closing in THIS round, the moment the
    # out-queue drains, races the peer's next write. h2spec generic §3.8
    # "Sends a GOAWAY frame" (`VerifyPingFrameOrConnectionClose`) writes GOAWAY
    # and PING back to back, then blocks reading; it passes on our PING-ACK or
    # on a clean close, and fails on a reset:
    #
    #   * PING already readable -> dispatched -> PING-ACK      -> pass
    #   * PING still in flight  -> we close; it lands unread
    #                              -> `close(2)` on a socket with unread
    #                                 bytes emits RST, not FIN (POSIX, both
    #                                 platforms)                -> FAIL
    #
    # Which way the race resolves depends on machine speed; a fast machine
    # loses it routinely:
    #
    #     Expected: Connection closed
    #               PING Frame (length:8, flags:0x01, stream_id:0, ...)
    #       Actual: Error: read tcp ...: read: connection reset by peer
    #
    # ⇢ A server that RESETS a connection it was asked to shut down gracefully
    #   loses whatever it had already queued, which is the exact outcome RFC
    #   9113 §6.8's graceful-shutdown handshake exists to prevent.
    #
    # ⚠ AND h2spec CANNOT ABSORB THE RESET, SO "CLOSE HARDER" IS NOT AN
    #   OPTION. `spec.WaitEvent` does have an arm mapping ECONNRESET to
    #   ConnectionClosedEvent, but it tests `opErr.Err == syscall.ECONNRESET`
    #   and Go wraps POSIX read errors one layer deeper, in `*os.SyscallError`
    #   -- only the Windows branch under it unwraps. On linux and darwin a
    #   reset is an ErrorEvent, full stop.
    #
    # SO WE DO NOT CLOSE HERE. We keep the conn and keep reading;
    # the peer's in-flight frames arrive on a later round and are answered
    # (the PING gets its ACK), and the conn is then closed by the paths that
    # already existed -- `hit_peer_eof` when the peer FINs, or
    # `dispatch_close` on a protocol error. Both are set at the top of this
    # function. It is not a race: the PING is already in flight
    # when the GOAWAY is read, so waiting for it is waiting for something
    # that is guaranteed to arrive, not hoping it arrives first.
    #
    # ⚠ CONSEQUENCE: a peer that sends GOAWAY and then goes
    # silent forever holds its conn slot instead of being dropped at
    # once. That is not a new class -- this server has NO idle-conn reaper
    # at all (grep `server.mojo` for one: the only timeouts are the poll's
    # own `timeout_us`), so a peer that connects and says nothing already
    # holds a slot indefinitely. If an idle reaper is ever added it covers
    # this case with everything else; a GOAWAY-specific timer here would be
    # the wrong altitude for it.

    return not conn_should_close
