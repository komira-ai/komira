# =============================================================================
# src/komira_http_core/transport/grpc_emit.mojo — gRPC-over-HTTP/2 response emit
# =============================================================================
#
# The live gRPC server tier:
#   1. `GrpcDispatch` — a PLAIN-TYPES trait seam the h2 serve loop calls to
#      route a gRPC request to an application handler. The conformer
#      (`ConnectService` lives in `komira_connect`) does the per-method
#      lookup + codec decode/encode and returns a `GrpcResponse`.
#   2. `GrpcResponse` — the plain-data result a `GrpcDispatch` returns. Body
#      is the wire-framed response (one 5-byte gRPC envelope for unary);
#      grpc_status / grpc_message close the call as h2 TRAILERS.
#   3. `emit_grpc_response` — THE trailer-emission mechanism. A gRPC call
#      closes with a trailing HEADERS frame carrying `grpc-status` (+ optional
#      `grpc-message`). The full response shape on the wire is:
#         HEADERS  (:status 200, content-type application/grpc+proto)  [no END_STREAM]
#         DATA     (the framed response message bytes)                 [no END_STREAM]
#         HEADERS  (grpc-status: <code> [, grpc-message: <text>])      [END_STREAM]
#      An erroring handler still returns HTTP :status 200 + a non-zero
#      grpc-status trailer — never an h2 stream error (per the gRPC spec).
#
# WHY this lives in `komira_http` and operates on PLAIN TYPES only:
#   `komira_connect` depends on `komira_http` (HttpServer + Router + h2
#   codec). So `komira_http` MUST NOT import `komira_connect` (cycle). The
#   `GrpcDispatch` trait + `GrpcResponse` are therefore defined here with
#   ZERO komira_connect types — `ConnectService` (komira_connect side)
#   conforms to `GrpcDispatch` and translates its own `DispatchResult` into a
#   `GrpcResponse`. This is the cycle-free seam that lets the live serve loop
#   route to a ConnectService without `komira_http` ever naming it.
#
# STREAMING: `GrpcResponse` is unary — one
#   buffered body. Server-streaming (DoGet) and client-streaming (DoPut) slot
#   in via a sibling `GrpcStreamDispatch` trait whose method takes a request-
#   message iterator + a response-message SINK (a callback that flushes one
#   DATA frame per message). The trailer-emission tail here (`_emit_grpc_trailer`)
#   is the REUSABLE close: the streaming path emits N DATA frames first, then
#   the SAME trailing-HEADERS(grpc-status). See the comment on
#   `_emit_grpc_trailer` for the exact split. Do NOT fold streaming into the
#   unary GrpcResponse — keep them sibling traits so the unary fast-path stays
#   a single buffered emit.
#
# Encapsulation: NO UnsafePointer in any public sig; ZERO wildcard origins;
# ZERO `unsafe_from_address`; ZERO ArcPointer. GrpcResponse is plain data
# (List[UInt8] + String + scalars).
# =============================================================================

from komira_clock import now_ns

from komira_http_core.codec.h2.connection_state import H2ConnectionState
from komira_http_core.codec.h2.frame import (
    encode_data_frame,
    encode_headers_frame,
)
from komira_http_core.codec.h2.hpack import HpackHeader
from komira_http_core.codec.h2.stream import STREAM_STATE_CLOSED


# =============================================================================
# §1 — gRPC content-type constants (the SUBSET komira_http needs to detect a
#      gRPC request without importing komira_connect's codec module).
# =============================================================================
#
# These mirror komira_connect/codec_grpc.mojo's GRPC_CONTENT_TYPE* +
# codec_grpc_web/connect content-types. We re-declare the prefixes here (not
# import them) to keep komira_http free of any komira_connect dependency.
# `is_grpc_content_type` matches the base (params stripped) against this set.

comptime _CT_GRPC: String = "application/grpc"
comptime _CT_GRPC_PROTO: String = "application/grpc+proto"
comptime _CT_GRPC_WEB: String = "application/grpc-web"
comptime _CT_GRPC_WEB_PROTO: String = "application/grpc-web+proto"
comptime _CT_CONNECT_JSON: String = "application/json"
comptime _CT_CONNECT_PROTO: String = "application/proto"
comptime _CT_CONNECT_STREAM_JSON: String = "application/connect+json"
comptime _CT_CONNECT_STREAM_PROTO: String = "application/connect+proto"


def _strip_ct_params(ct: String) -> String:
    """Return the base content-type (text before any `; param=value`).

    `ct` is the peer's header value and may hold any byte, so it is read
    through `as_bytes()`: indexing `ct[byte=i]` asserts on a UTF-8
    continuation byte and aborts the process. The cut is at an ASCII `;`, so
    the prefix of a valid UTF-8 string is valid UTF-8.
    """
    var bytes = ct.as_bytes()
    for i in range(len(bytes)):
        if bytes[i] == UInt8(ord(";")):
            return String(StringSlice(unsafe_from_utf8=bytes[:i]))
    return ct


def is_grpc_content_type(ct: String) -> Bool:
    """True iff `ct` names a gRPC / gRPC-Web / Connect RPC content-type.

    The live h2 serve loop calls this on the request's `content-type` header
    to decide whether to route to the `GrpcDispatch` seam (vs. the ordinary
    Router path). Connect-JSON (`application/json`) is included because a
    Connect-RPC unary call over h2 uses it; the dispatcher resolves the exact
    codec downstream.
    """
    var base = _strip_ct_params(ct)
    return (
        base == _CT_GRPC
        or base == _CT_GRPC_PROTO
        or base == _CT_GRPC_WEB
        or base == _CT_GRPC_WEB_PROTO
        or base == _CT_CONNECT_JSON
        or base == _CT_CONNECT_PROTO
        or base == _CT_CONNECT_STREAM_JSON
        or base == _CT_CONNECT_STREAM_PROTO
    )


# =============================================================================
# §2 — GrpcResponse — the plain-data result a GrpcDispatch returns.
# =============================================================================


struct GrpcResponse(Movable, Deinitable):
    """The unary gRPC response material a `GrpcDispatch` returns.

    Fields:
        body: The wire-framed response body (one 5-byte gRPC envelope for a
              unary gRPC/gRPC-Web success; the JSON bytes for Connect-JSON).
              Empty for a gRPC error (status goes in the trailer).
        http_status: The HTTP :status to set (always 200 for gRPC — status
              rides the trailer; the Connect-JSON-mapped status for Connect
              errors).
        grpc_status: The gRPC canonical code (0 == OK). Emitted as the
              `grpc-status` trailer for gRPC/gRPC-Web.
        grpc_message: Human-readable error text (empty for OK). Percent-encoded
              by the conformer before it reaches here (this layer emits the
              value verbatim into the trailer).
        content_type: The response content-type header value (e.g.
              `application/grpc+proto`). Set by the conformer from the codec.
        emit_trailer: True iff this response closes with a gRPC trailer
              (`grpc-status`). gRPC/gRPC-Web → True; a non-gRPC fallback
              (Connect-JSON error body) sets False and uses an ordinary
              HEADERS+DATA(END_STREAM) close.
    """

    var body: List[UInt8]
    var http_status: UInt16
    var grpc_status: UInt8
    var grpc_message: String
    var content_type: String
    var emit_trailer: Bool

    def __init__(
        out self,
        var body: List[UInt8],
        http_status: UInt16,
        grpc_status: UInt8,
        var grpc_message: String,
        var content_type: String,
        emit_trailer: Bool,
    ):
        self.body = body^
        self.http_status = http_status
        self.grpc_status = grpc_status
        self.grpc_message = grpc_message^
        self.content_type = content_type^
        self.emit_trailer = emit_trailer

    @staticmethod
    def unimplemented() -> GrpcResponse:
        """The default `NoopGrpcDispatch` outcome: UNIMPLEMENTED (code 12),
        empty body, 200 + trailer (so even the no-op server speaks valid
        gRPC: a client gets `grpc-status: 12`, not a protocol violation)."""
        return GrpcResponse(
            List[UInt8](),
            UInt16(200),
            UInt8(12),  # GRPC_STATUS_UNIMPLEMENTED
            String("grpc dispatch not configured"),
            String("application/grpc+proto"),
            True,
        )


# =============================================================================
# §3 — GrpcDispatch — the plain-types dispatch seam (cycle-free).
# =============================================================================


trait GrpcDispatch(Movable, Deinitable):
    """The application gRPC request→response surface the h2 serve loop calls.

    A conformer (canonically `komira_connect.ConnectService`) inspects
    `path` + `content_type`, looks up the registered method, decodes the
    request `body`, invokes the handler, and returns a `GrpcResponse`. The
    trait operates on PLAIN TYPES (String + List[UInt8]) so `komira_http`
    can name it without importing `komira_connect` (which would cycle).

    `mut self` so a stateful service (a registry that mutates, a backend
    handle) can drive its state per request.
    """

    def dispatch_grpc(
        mut self,
        path: String,
        content_type: String,
        request_body: List[UInt8],
    ) -> GrpcResponse:
        ...

    def grpc_now_ns(self) -> UInt64:
        """The monotonic nanosecond clock the serve loop enforces
        `grpc-timeout` against: read when a request's HEADERS block completes
        (the arrival instant the deadline is computed from), before the
        handler runs and after it returns. The default is
        `komira_clock.now_ns()`; a conformer overrides it to supply another
        clock (a test drives a manual one)."""
        return now_ns()


struct NoopGrpcDispatch(GrpcDispatch, GrpcStreamDispatch):
    """The default `GrpcDispatch` (+ `GrpcStreamDispatch`) for a server with no
    gRPC service wired.

    Every gRPC request — unary OR streaming — resolves to UNIMPLEMENTED, so the
    server still speaks valid gRPC (200 + `grpc-status: 12` trailer) rather than
    emitting a protocol violation. This is the default `G` for `HttpServer[G]`,
    so all existing non-gRPC `HttpServer` call sites are unchanged. It conforms
    to BOTH the unary and streaming seams so the serve loop's
    `G: GrpcDispatch & GrpcStreamDispatch` bound is satisfied by the default.
    """

    def __init__(out self):
        pass

    def dispatch_grpc(
        mut self,
        path: String,
        content_type: String,
        request_body: List[UInt8],
    ) -> GrpcResponse:
        return GrpcResponse.unimplemented()

    def dispatch_grpc_stream(
        mut self,
        path: String,
        content_type: String,
        kind: UInt8,
        request_body: List[UInt8],
    ) -> GrpcStreamResponse:
        return GrpcStreamResponse.unimplemented()

    def grpc_stream_kind(self, path: String) -> UInt8:
        # No streaming methods registered; everything is unary (the unary
        # path then answers UNIMPLEMENTED via dispatch_grpc).
        return GRPC_KIND_UNARY


# =============================================================================
# §4 — emit_grpc_response — THE trailer-emission mechanism (net-new).
# =============================================================================


def emit_grpc_response(
    mut h2: H2ConnectionState,
    stream_id: UInt32,
    var resp: GrpcResponse,
    mut reqs_handled: Int64,
    mut bytes_sent: Int64,
) -> Bool:
    """Serialize a gRPC response on `stream_id` as HEADERS + DATA + trailer.

    On-wire shape (the piece that was missing before):
        HEADERS  (:status 200, content-type <grpc>)        [END_HEADERS, no END_STREAM]
        DATA     (resp.body — the framed response message) [no END_STREAM]
        HEADERS  (grpc-status: <code> [, grpc-message])    [END_HEADERS, END_STREAM]

    The trailing HEADERS frame is a normal HPACK block (it continues the
    connection's outbound dynamic table) carrying ONLY the trailer fields.
    Setting END_STREAM on the trailing HEADERS (NOT on the DATA) is what makes
    this a valid gRPC stream close — clients (grpcio, pyarrow.flight) read the
    `grpc-status` off this trailing block.

    For a non-gRPC fallback (`resp.emit_trailer == False`, e.g. a Connect-JSON
    error body) we emit the ordinary HEADERS+DATA(END_STREAM) close with no
    trailer.

    NOTE: this emit is single-shot (no outbound flow-control deferral). gRPC
    unary response bodies are small (a single envelope); the deferred-body
    flow-control machinery in `_emit_response` is for large h1-parity bodies.
    If a future streaming/large-message path needs windowed trailer emission,
    factor `_emit_grpc_trailer` (already split out below) into the drain loop.

    Returns True on success; False is reserved for catastrophic errors (none
    today).
    """
    # ---- 1) Response HEADERS: :status + content-type. ----
    var resp_headers = List[HpackHeader]()
    resp_headers.append(
        HpackHeader(String(":status"), String(Int(resp.http_status)))
    )
    resp_headers.append(
        HpackHeader(String("content-type"), resp.content_type)
    )

    var body_len = len(resp.body)

    if not resp.emit_trailer:
        # Non-gRPC fallback close: HEADERS + (optional DATA) with END_STREAM,
        # no trailer. (Connect-JSON unary error/result rides this path.)
        resp_headers.append(
            HpackHeader(String("content-length"), String(Int(body_len)))
        )
        var block_f = h2.hpack_encoder.encode_block(resp_headers^)
        var hbuf_f = List[UInt8]()
        encode_headers_frame(
            stream_id, block_f^, body_len == 0, True, hbuf_f,
        )
        h2.append_out_bytes(hbuf_f^)
        if body_len > 0:
            # Swap the body out (the pointer rules: no UnsafePointer partial move).
            var body_f = List[UInt8]()
            swap(resp.body, body_f)
            var data_f = List[UInt8]()
            encode_data_frame(stream_id, body_f^, True, data_f)
            h2.append_out_bytes(data_f^)
            bytes_sent = bytes_sent + Int64(body_len)
        var idx_f = h2.find_stream_idx(stream_id)
        if idx_f >= 0:
            h2.streams[idx_f].advance_on_send_end_stream()
        reqs_handled = reqs_handled + Int64(1)
        return True

    # ---- gRPC close: HEADERS (no END_STREAM) -> DATA (no END_STREAM) -> trailer. ----
    # The response HEADERS NEVER carries END_STREAM for gRPC: the stream stays
    # open through the DATA frame(s) and only the trailing HEADERS closes it.
    var block = h2.hpack_encoder.encode_block(resp_headers^)
    var hbuf = List[UInt8]()
    encode_headers_frame(stream_id, block^, False, True, hbuf)
    h2.append_out_bytes(hbuf^)

    # Extract the trailer fields + body BEFORE consuming the body (so `resp`
    # is not used after a partial-move of `resp.body`). Per the pointer
    # rules: pull the body out via stdlib swap (no UnsafePointer partial
    # move); the moved-from field holds an empty list (destructor-safe).
    var grpc_status = resp.grpc_status
    var grpc_message = resp.grpc_message
    var resp_body = List[UInt8]()
    swap(resp.body, resp_body)

    # ---- 2) DATA frame: the framed response body (no END_STREAM). ----
    # On a pure error (empty body) we skip DATA and go straight to the
    # trailer. On success we emit the single framed message.
    if body_len > 0:
        var data_buf = List[UInt8]()
        encode_data_frame(stream_id, resp_body^, False, data_buf)
        h2.append_out_bytes(data_buf^)
        bytes_sent = bytes_sent + Int64(body_len)

    # ---- 3) Trailing HEADERS: grpc-status [+ grpc-message], END_STREAM. ----
    _emit_grpc_trailer(
        h2, stream_id, grpc_status, grpc_message, reqs_handled,
    )
    return True


# =============================================================================
# §5 — GrpcStreamResponse + GrpcStreamDispatch — the streaming sibling seam.
# =============================================================================
#
# server-streaming (DoGet) + client-streaming
# (DoPut). The unary seam above (`GrpcResponse` / `GrpcDispatch`) stays the
# single-buffered fast path; streaming slots in via these SIBLING types so the
# unary path never pays the per-message-list cost.
#
# WHY a "produce a List of messages" sink, NOT a callback that holds an h2
# pointer:  the streaming handler lives in `komira_connect` (or user code)
# and the h2 frame machinery lives here in `komira_http`. A response-sink
# callback would have to receive an `H2ConnectionState` ref or an
# UnsafePointer across the module boundary — banned (encapsulation rule). So
# the cycle-free seam is: the conformer RETURNS a `GrpcStreamResponse` (a plain
# List of already-framed-or-raw message bodies + the close status), and THIS
# module frames + emits each message as its own h2 DATA frame. The sink is a
# plain owned value crossing the boundary, never a pointer.
#
# Both streaming directions collapse onto the SAME return shape:
#   * Server-streaming (DoGet): one request message in -> N response messages
#     out. The conformer decodes the single inbound envelope, runs the
#     handler, and returns N `messages`.
#   * Client-streaming (DoPut): N request messages in -> one response message
#     out. The conformer decodes the N inbound envelopes (the request body is
#     a concatenation of gRPC envelopes), folds them, and returns 1 `message`.
# Either way the wire close is identical: HEADERS -> DATA*N -> trailer.


struct GrpcStreamResponse(Movable, Deinitable):
    """The streaming gRPC response material a `GrpcStreamDispatch` returns.

    Fields:
        messages: The per-message response bodies, each ALREADY gRPC-envelope
                  framed (5-byte header + payload) by the conformer. Each
                  element becomes its own h2 DATA frame on the wire (flow
                  control permitting; the residual that doesn't fit the send
                  window is concatenated and drained on WINDOW_UPDATE via the
                  per-stream deferred-response machinery). For server-streaming
                  this is N>=0 elements; for client-streaming exactly 1.
        http_status: The HTTP :status (always 200 for gRPC — status rides the
                  trailer).
        grpc_status: The gRPC canonical close code (0 == OK). Emitted as the
                  `grpc-status` trailer AFTER all DATA frames drain.
        grpc_message: Percent-encoded error text (empty for OK). Verbatim into
                  the trailer.
        content_type: The response content-type (e.g. application/grpc+proto).
    """

    var messages: List[List[UInt8]]
    var http_status: UInt16
    var grpc_status: UInt8
    var grpc_message: String
    var content_type: String

    def __init__(
        out self,
        var messages: List[List[UInt8]],
        http_status: UInt16,
        grpc_status: UInt8,
        var grpc_message: String,
        var content_type: String,
    ):
        self.messages = messages^
        self.http_status = http_status
        self.grpc_status = grpc_status
        self.grpc_message = grpc_message^
        self.content_type = content_type^

    @staticmethod
    def unimplemented() -> GrpcStreamResponse:
        """The default streaming outcome: UNIMPLEMENTED, no messages, 200 +
        trailer (the no-op server still speaks valid gRPC)."""
        return GrpcStreamResponse(
            List[List[UInt8]](),
            UInt16(200),
            UInt8(12),  # GRPC_STATUS_UNIMPLEMENTED
            String("grpc stream dispatch not configured"),
            String("application/grpc+proto"),
        )


# The streaming-kind marker the serve loop carries per gRPC request so it can
# route to the unary `dispatch_grpc` vs the streaming `dispatch_grpc_stream`.
# UNARY is the default (the fast path); SERVER / CLIENT select streaming.
comptime GRPC_KIND_UNARY: UInt8 = 0
comptime GRPC_KIND_SERVER_STREAM: UInt8 = 1
comptime GRPC_KIND_CLIENT_STREAM: UInt8 = 2


trait GrpcStreamDispatch(Movable, Deinitable):
    """The streaming gRPC request->response surface (sibling of GrpcDispatch).

    A conformer (canonically `komira_connect.ConnectService`) inspects `path`
    + `content_type`, looks up the registered streaming method, decodes the
    request `body` (one envelope for server-streaming; N envelopes for
    client-streaming), runs the streaming handler, and returns a
    `GrpcStreamResponse` carrying the per-message response bodies + close
    status. Plain types only (String + List[UInt8]) so `komira_http` names it
    without importing `komira_connect`.

    `kind` tells the conformer which streaming shape applies (the serve loop
    resolves it from the method registry before calling). `mut self` so a
    stateful service can drive its state per request.
    """

    def dispatch_grpc_stream(
        mut self,
        path: String,
        content_type: String,
        kind: UInt8,
        request_body: List[UInt8],
    ) -> GrpcStreamResponse:
        ...

    def grpc_stream_kind(self, path: String) -> UInt8:
        """Resolve the streaming kind for `path`: GRPC_KIND_UNARY (route to the
        unary `dispatch_grpc`), GRPC_KIND_SERVER_STREAM, or
        GRPC_KIND_CLIENT_STREAM. The serve loop calls this FIRST to decide
        whether the request takes the unary fast path or the streaming path."""
        ...


# =============================================================================
# §6 — emit_grpc_stream_response — incremental per-message DATA + trailer.
# =============================================================================


def emit_grpc_stream_response(
    mut h2: H2ConnectionState,
    stream_id: UInt32,
    var resp: GrpcStreamResponse,
    mut reqs_handled: Int64,
    mut bytes_sent: Int64,
) -> Bool:
    """Serialize a streaming gRPC response: HEADERS + N DATA frames + trailer.

    On-wire shape:
        HEADERS  (:status 200, content-type <grpc>)   [END_HEADERS, no END_STREAM]
        DATA     (message[0] bytes)                    [no END_STREAM]
        DATA     (message[1] bytes)                    [no END_STREAM]
        ...                                            (one DATA frame per msg)
        HEADERS  (grpc-status [, grpc-message])        [END_HEADERS, END_STREAM]

    INCREMENTAL FLUSH + FLOW CONTROL: each message is emitted as its own DATA
    frame in this pass UP TO the available send window (per-stream + connection,
    via `send_fc.can_send`). The messages (or partial message) that exceed the
    window are concatenated into a per-stream DEFERRED-RESPONSE entry tagged
    with the gRPC close trailer; `_pump_deferred_responses` drains them on each
    WINDOW_UPDATE and emits the trailing-HEADERS(grpc-status) only AFTER the
    body fully drains. This reuses the deferred-body machinery wholesale —
    the only net-new piece is the "emit a gRPC trailer instead of END_STREAM on
    the final DATA" close, carried on the deferred entry's `grpc_trailer_status`.

    For server-streaming with a large DoGet result this is exactly the
    incremental behavior Flight needs: the first batches go out immediately,
    the rest stream out as the client's flow-control window opens.

    Returns True on success / partial flush.
    """
    # ---- 1) Response HEADERS: :status + content-type, NO END_STREAM. ----
    var resp_headers = List[HpackHeader]()
    resp_headers.append(
        HpackHeader(String(":status"), String(Int(resp.http_status)))
    )
    resp_headers.append(
        HpackHeader(String("content-type"), resp.content_type)
    )
    var block = h2.hpack_encoder.encode_block(resp_headers^)
    var hbuf = List[UInt8]()
    encode_headers_frame(stream_id, block^, False, True, hbuf)
    h2.append_out_bytes(hbuf^)

    # Extract the close status + the messages BEFORE consuming (per the
    # pointer rules: no partial-move via UnsafePointer; swap the messages out).
    var grpc_status = resp.grpc_status
    var grpc_message = resp.grpc_message
    var messages = List[List[UInt8]]()
    swap(resp.messages, messages)

    # ---- 2) Resolve the current send window. ----
    var idx = h2.find_stream_idx(stream_id)
    var stream_window = Int32(0)
    if idx >= 0:
        stream_window = h2.streams[idx].send_window
    var max_frame = h2.max_frame_size_peer
    if max_frame <= 0:
        max_frame = 16384

    # ---- 3) Emit one DATA frame per message, up to the send window. ----
    # `emitted_now` accumulates the byte count actually put on the wire this
    # pass (charged to flow control once). `residual` accumulates the message
    # bytes that did NOT fit (concatenated; framing is already in the bytes).
    var n_msgs = len(messages)
    var window_remaining = Int(h2.send_fc.can_send(stream_window, 1 << 30))
    var emitted_now = 0
    var residual = List[UInt8]()
    var mi = 0
    while mi < n_msgs:
        var mlen = len(messages[mi])
        if window_remaining >= mlen and mlen <= max_frame:
            # Fits the window AND a single frame: emit as its own DATA frame.
            var local_msg = List[UInt8]()
            swap(messages[mi], local_msg)
            var data_buf = List[UInt8]()
            encode_data_frame(stream_id, local_msg^, False, data_buf)
            h2.append_out_bytes(data_buf^)
            emitted_now = emitted_now + mlen
            window_remaining = window_remaining - mlen
        else:
            # Doesn't fit this pass (window exhausted OR message exceeds a
            # single frame): push this + all remaining messages onto the
            # residual (concatenated; the deferred drain chunks by max_frame).
            var rj = mi
            while rj < n_msgs:
                var inner = 0
                var ilen = len(messages[rj])
                while inner < ilen:
                    residual.append(messages[rj][inner])
                    inner = inner + 1
                rj = rj + 1
            break
        mi = mi + 1

    # Charge the bytes we put on the wire this pass to flow control.
    if emitted_now > 0:
        if idx >= 0:
            h2.send_fc.consume(emitted_now, h2.streams[idx].send_window)
        else:
            var dummy = Int32(0)
            h2.send_fc.consume(emitted_now, dummy)
        bytes_sent = bytes_sent + Int64(emitted_now)

    # ---- 4) Close. ----
    if len(residual) == 0:
        # Everything fit: emit the gRPC trailer now.
        _emit_grpc_trailer(h2, stream_id, grpc_status, grpc_message, reqs_handled)
        return True

    # Residual exists: defer it tagged with the gRPC trailer. The trailer is
    # emitted by `_pump_deferred_responses` after the residual fully drains.
    h2.push_deferred_grpc_response(
        stream_id=stream_id,
        body=residual^,
        grpc_status=grpc_status,
        grpc_message=grpc_message,
    )
    if idx >= 0:
        h2.streams[idx].has_deferred_response_body = True
    return True


def emit_grpc_trailers_only(
    mut h2: H2ConnectionState,
    stream_id: UInt32,
    http_status: UInt16,
    content_type: String,
    grpc_status: UInt8,
    grpc_message: String,
    mut reqs_handled: Int64,
) -> Bool:
    """Close `stream_id` with one HEADERS frame (END_HEADERS + END_STREAM)
    carrying `:status`, `content-type`, `grpc-status` and, when non-empty,
    `grpc-message`: the gRPC "Trailers-Only" response, with no DATA.

    `grpc_message` is emitted verbatim; the caller percent-encodes it.
    """
    var hs = List[HpackHeader]()
    hs.append(HpackHeader(String(":status"), String(Int(http_status))))
    hs.append(HpackHeader(String("content-type"), content_type))
    hs.append(HpackHeader(String("grpc-status"), String(Int(grpc_status))))
    if len(grpc_message.as_bytes()) > 0:
        hs.append(HpackHeader(String("grpc-message"), grpc_message))
    var block = h2.hpack_encoder.encode_block(hs^)
    var buf = List[UInt8]()
    encode_headers_frame(stream_id, block^, True, True, buf)
    h2.append_out_bytes(buf^)
    var idx = h2.find_stream_idx(stream_id)
    if idx >= 0:
        h2.streams[idx].advance_on_send_end_stream()
    reqs_handled = reqs_handled + Int64(1)
    return True


def _emit_grpc_trailer(
    mut h2: H2ConnectionState,
    stream_id: UInt32,
    grpc_status: UInt8,
    grpc_message: String,
    mut reqs_handled: Int64,
):
    """Emit the trailing HEADERS frame that closes a gRPC stream.

    REUSABLE CLOSE: the unary path (`emit_grpc_response`) calls this after one
    DATA frame; the streaming path calls this after N DATA frames.
    Either way the trailer is identical: a HEADERS block carrying `grpc-status`
    (always) + `grpc-message` (only when non-empty / non-OK), with both
    END_HEADERS and END_STREAM set.

    `grpc_message` is emitted VERBATIM — the conformer percent-encodes it (per
    the gRPC HTTP/2 spec) before it reaches here.
    """
    var trailer_headers = List[HpackHeader]()
    trailer_headers.append(
        HpackHeader(String("grpc-status"), String(Int(grpc_status)))
    )
    if len(grpc_message.as_bytes()) > 0:
        trailer_headers.append(
            HpackHeader(String("grpc-message"), grpc_message)
        )
    var tblock = h2.hpack_encoder.encode_block(trailer_headers^)
    var tbuf = List[UInt8]()
    # END_STREAM + END_HEADERS on the trailing block: this is the stream close.
    encode_headers_frame(stream_id, tblock^, True, True, tbuf)
    h2.append_out_bytes(tbuf^)

    var idx = h2.find_stream_idx(stream_id)
    if idx >= 0:
        h2.streams[idx].advance_on_send_end_stream()
    reqs_handled = reqs_handled + Int64(1)
