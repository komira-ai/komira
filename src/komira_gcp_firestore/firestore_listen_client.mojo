# =============================================================================
# komira_gcp_firestore/firestore_listen_client.mojo — the Firestore `Listen`
#   gRPC-over-HTTP/2 BIDI client + the additive h2 incremental-recv drive.
# =============================================================================
#
# WHAT THIS IS. The Firestore change-stream transport: a client that
# opens the SERVER-PUSHED gRPC bidi stream `google.firestore.v1.Firestore/Listen`
# and keeps receiving pushed `ListenResponse` frames WITHOUT a WINDOW_UPDATE
# flow-control stall. Two pieces live here:
#
#   1. `drive_h2_recv_until_progress[Self.S, RT]` — the ADDITIVE h2 drive Listen
#      needs. Every EXISTING h2 driver (`drive_h2_streams_to_completion`) runs to
#      END_STREAM — a request/response shape. A Listen stream NEVER ends: the
#      request half stays open (the client MAY send more ListenRequests) and the
#      server pushes DATA frames indefinitely. This drive returns after receiving
#      NEW response-body bytes on the awaited stream (or after a bounded park with
#      no progress) — WITHOUT requiring END_STREAM. It reuses the SAME
#      `process_received_frames` (so the SAME `_replenish_recv_window_after_data`
#      WINDOW_UPDATE-at-drain-watermark logic fires on every pushed DATA frame),
#      the SAME bounded park, and the SAME encapsulated H2ClientConnectionState —
#      NO change to h2_client.mojo, NO UnsafePointer, NO wildcard origin.
#
#   2. `FirestoreListenClient[S]` — the gRPC Listen wiring over that drive: build
#      the `:path` (`/google.firestore.v1.Firestore/Listen`) + the gRPC request
#      headers (`content-type: application/grpc`, `te: trailers`,
#      `authorization: Bearer <token>`, and the REQUIRED Firestore routing header
#      `google-cloud-resource-prefix: projects/{p}/databases/{d}` — WITHOUT which
#      the frontend rejects the RPC with grpc-status 3 and pushes zero DATA; this
#      was the root cause of a zero-bytes stream), send the HEADERS
#      *without* END_STREAM
#      (keep the request half open), send the FIRST `ListenRequest` as a gRPC
#      length-prefixed DATA frame (also without END_STREAM), then pump: drive the
#      recv, drain complete gRPC envelopes out of the accumulated response body
#      via the shipped `ClientFramer`, and decode each envelope's protobuf into a
#      `ListenEvent` (firestore_listen_proto).
#
# WHY IT REUSES, NOT REWRITES. The h2 codec (frame encode/decode, HPACK, the
# two-level flow control, the WINDOW_UPDATE-at-drain-watermark replenishment) is
# komira_http_client's. The gRPC 5-byte framing is komira_grpc's
# (`ClientFramer`, `encode_stream_message`). The Firestore value model is FsValue.
# This module adds ONLY the "receive an unbounded server push without END_STREAM"
# drive shape + the Firestore-specific proto/headers.
#
# AUTH. A GCP OAuth2 access token (from ADC / `gcloud auth application-default
# print-access-token`) is passed as the gRPC `authorization: Bearer <token>`
# metadata header. No token minting here — the caller supplies the token string.
#
# ENCAPSULATION. ZERO UnsafePointer in any signature; ZERO wildcard
# origins; ZERO unsafe_from_address. The h2 internals stay behind
# H2ClientConnectionState's public API + the IoStream trait; the gRPC framing
# stays behind ClientFramer; the proto stays behind firestore_listen_proto.
# `def`-based (Mojo 1.0.0b2).
# =============================================================================


from komira_clock import now_ns as _mono_now_ns

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_http_client.header_map import HeaderMap
from komira_http_core.transport.stream_park import park_on_pending
from komira_http_core.transport.io_stream import (
    IoStream,
    STREAM_IO_EOF,
    STREAM_IO_ERROR,
    STREAM_IO_PENDING,
    STREAM_IO_READY,
)
from komira_http_client.h2_client import (
    H2ClientConnectionState,
    allocate_client_stream_id_or_raise,
    encode_request_data_frame,
    encode_request_headers_to_frames,
    extract_trailers_for_stream,
    h2_goaway_context,
    process_received_frames,
    queue_client_preface_and_settings,
)
from komira_http_core.codec.h2.frame import (
    H2_ERR_CANCEL,
    H2_ERR_ENHANCE_YOUR_CALM,
    H2_ERR_FLOW_CONTROL_ERROR,
    H2_ERR_HTTP_1_1_REQUIRED,
    H2_ERR_INADEQUATE_SECURITY,
    H2_ERR_REFUSED_STREAM,
)

from komira_grpc import (
    ClientFramer,
    GrpcError,
    ProtocolGrpcProto,
    encode_stream_message,
    format_grpc_error_message,
    grpc_error_for_missing_status,
    grpc_error_from_http_non_200,
    parse_grpc_status_initial_headers,
    parse_grpc_status_trailers,
    GRPC_STATUS_ABORTED,
    GRPC_STATUS_ALREADY_EXISTS,
    GRPC_STATUS_CANCELLED,
    GRPC_STATUS_DATA_LOSS,
    GRPC_STATUS_FAILED_PRECONDITION,
    GRPC_STATUS_INTERNAL,
    GRPC_STATUS_INVALID_ARGUMENT,
    GRPC_STATUS_NOT_FOUND,
    GRPC_STATUS_OUT_OF_RANGE,
    GRPC_STATUS_PERMISSION_DENIED,
    GRPC_STATUS_RESOURCE_EXHAUSTED,
    GRPC_STATUS_UNAVAILABLE,
    GRPC_STATUS_UNIMPLEMENTED,
    GRPC_STATUS_UNKNOWN,
)

from komira_gcp_firestore.firestore_listen_proto import (
    ListenEvent,
    decode_listen_response,
    encode_listen_request_documents,
    encode_listen_request_documents_after,
)


# =============================================================================
# §1 — gRPC envelope framing, from komira_grpc.
#
# Both directions use komira_grpc's classic-gRPC framing: the request is one
# envelope written by `encode_stream_message[ProtocolGrpcProto]`, and the
# pushed response bytes are split by `ClientFramer`, which also refuses an
# envelope whose declared length exceeds the receive limit. The Listen stream
# never negotiates compression (`grpc-accept-encoding: identity`), so a
# compressed envelope is a protocol error, raised rather than decoded.
# =============================================================================


def encode_grpc_envelope(var payload: List[UInt8]) -> List[UInt8]:
    """Wrap `payload` (a serialized protobuf message) in a classic-gRPC
    length-prefixed envelope: [compressed-flag:1=0][length:4-BE][payload]."""
    var out = List[UInt8]()
    encode_stream_message[ProtocolGrpcProto](out, Span[UInt8](payload))
    return out^


# =============================================================================
# §2 — the ADDITIVE h2 incremental-recv drive (server-push bidi shape).
# =============================================================================

# Bounded per-park deadline (mirrors h2_client._H2_PARK_DEADLINE_US): a stuck
# park returns to the loop so the wall-clock budget can terminate a wedged conn.
comptime _LISTEN_PARK_DEADLINE_US: Int32 = 250_000


# =============================================================================
# ONE PARK PRIMITIVE.
# =============================================================================
#
# The receive loop below parks with
# `komira_http_core.transport.stream_park.park_on_pending` and never with a
# park of its own. That primitive asks the transport which direction its
# pending op waits in (a call site's guess can be the wrong one), and it
# re-polls the remainder of its slice until THIS op is ready, so a reactor
# event for another fd, or an empty wake-channel completion, is not taken as
# this stream's readiness (which would be a busy loop).
# =============================================================================


struct RecvProgress(Copyable, Movable, Deinitable):
    """Outcome of one `drive_h2_recv_until_progress` call.

    Fields:
      got_bytes       — new response-body bytes arrived on the awaited stream.
      end_stream_seen — the stream is over: END_STREAM (a DATA frame or
                        trailers), RST_STREAM, a GOAWAY that excludes it, or
                        the connection closed (`_stream_over`). It says
                        nothing about the outcome: the client reads that
                        with `_listen_terminal_status`.
      timed_out       — the wall budget elapsed with no new bytes (a stall — the
                        de-risk FAIL signal).
    """

    var got_bytes: Bool
    var end_stream_seen: Bool
    var timed_out: Bool

    def __init__(
        out self, got_bytes: Bool, end_stream_seen: Bool, timed_out: Bool
    ):
        self.got_bytes = got_bytes
        self.end_stream_seen = end_stream_seen
        self.timed_out = timed_out


def drive_h2_recv_until_progress[S: IoStream, RT: Runtime](
    mut h2: H2ClientConnectionState,
    mut stream: S,
    mut reactor: Reactor[RT.Sink],
    stream_id: UInt32,
    max_wall_us: Int64 = 30_000_000,
    max_iterations: Int = 100_000,
) raises -> RecvProgress:
    """ADDITIVE server-push drive. Interleaves outbound flush (SETTINGS-ACK,
    WINDOW_UPDATE, PING-ACK, any queued request DATA) + inbound read, feeding
    inbound bytes into `process_received_frames`, and RETURNS as soon as NEW
    response-body bytes have landed on `stream_id` — WITHOUT requiring
    END_STREAM. This is the shape a Listen stream needs: the server pushes DATA
    frames forever; each call to this drive collects the next push.

    The KEY de-risk: because inbound DATA flows through the SAME
    `process_received_frames`, the SAME `_replenish_recv_window_after_data`
    WINDOW_UPDATE-at-drain-watermark logic fires as bytes are consumed — so the
    recv window is replenished on a LONG-LIVED push stream exactly as it is on a
    request/response body, and the server never stalls at ~64KB.

    Returns a RecvProgress: got_bytes on new data, end_stream_seen on server
    close, timed_out if the wall budget elapsed with no progress (a STALL — the
    signal the flow-control de-risk is watching for). The pending pending_out is
    always fully flushed before returning on any new data, so WINDOW_UPDATE
    frames are on the wire promptly.

    Encapsulation: no UnsafePointer, no wildcard; only IoStream methods +
    H2ClientConnectionState's public accessors."""
    var scratch = List[UInt8]()
    for _i in range(4096):
        scratch.append(UInt8(0))

    var start_body_len = _response_body_len(h2, stream_id)
    var iters = 0
    var wall_start_ns = Int64(_mono_now_ns())
    var wall_budget_ns = max_wall_us * Int64(1000)

    while True:
        iters += 1
        if iters > max_iterations:
            return RecvProgress(False, False, True)
        if wall_budget_ns > Int64(0):
            var elapsed = Int64(_mono_now_ns()) - wall_start_ns
            if elapsed > wall_budget_ns:
                return RecvProgress(False, False, True)

        # Step 1: fully drain pending_out (SETTINGS-ACK / WINDOW_UPDATE / request
        # DATA / PING-ACK). Draining WINDOW_UPDATE promptly is the load-bearing
        # half of the de-risk — the server keeps its send window replenished.
        if len(h2.pending_out) > 0:
            var out_view = Span[UInt8](h2.pending_out).as_imm()
            var wres = stream.try_write[RT](reactor, out_view)
            if wres._state == STREAM_IO_READY:
                h2.consume_out_bytes_prefix(Int(wres._payload))
                continue
            if wres._state == STREAM_IO_PENDING:
                # The direction is the STREAM's answer, not "this was a
                # write" — see `park_on_pending`. The slice bound keeps a
                # stuck park returning to this loop's wall budget.
                _ = park_on_pending[S, RT](
                    stream, reactor,
                    pending_token=wres._payload, call_is_write=True,
                    slice_us=_LISTEN_PARK_DEADLINE_US,
                )
                continue
            if wres._state == STREAM_IO_ERROR:
                raise Error(
                    "FirestoreListen: h2 recv-drive write errno="
                    + String(Int(wres._payload))
                )
            raise Error("FirestoreListen: h2 recv-drive write returned EOF")

        # Step 2: did new body bytes / END_STREAM already arrive?
        var cur_body_len = _response_body_len(h2, stream_id)
        var ended = _stream_over(h2, stream_id)
        if cur_body_len > start_body_len:
            return RecvProgress(True, ended, False)
        if ended:
            return RecvProgress(cur_body_len > start_body_len, True, False)

        # Step 3: read a chunk + feed the codec.
        var rres = stream.try_read[RT](reactor, Span[UInt8](scratch))
        if rres._state == STREAM_IO_PENDING:
            _ = park_on_pending[S, RT](
                stream, reactor,
                pending_token=rres._payload, call_is_write=False,
                slice_us=_LISTEN_PARK_DEADLINE_US,
            )
            continue
        if rres._state == STREAM_IO_ERROR:
            raise Error(
                "FirestoreListen: h2 recv-drive read errno="
                + String(Int(rres._payload))
            )
        if rres._state == STREAM_IO_EOF:
            # Peer closed. Surface as end_stream (the stream is over).
            return RecvProgress(
                _response_body_len(h2, stream_id) > start_body_len, True, False
            )
        var n_read = Int(rres._payload)
        h2.append_recv_bytes(Span(scratch)[:n_read])
        _ = process_received_frames(h2)
        continue


def _response_body_len(
    h2: H2ClientConnectionState, stream_id: UInt32
) -> Int:
    """Bytes accumulated in the awaited stream's response-body buffer so far
    (a public read through H2ClientConnectionState's accessors)."""
    var idx = h2.find_stream_idx(stream_id)
    if idx < 0:
        return 0
    var slot = h2.streams[idx].response_body_idx
    if slot < 0:
        return 0
    return len(h2.response_body_buffers[slot])


def _goaway_excludes(h2: H2ClientConnectionState, stream_id: UInt32) -> Bool:
    """True iff the server sent GOAWAY with a Last-Stream-ID below this
    stream: RFC 9113 §6.8 says it was not and will not be processed."""
    return h2.is_goaway_received() and h2.goaway_last_stream_id < stream_id


def _stream_over(h2: H2ClientConnectionState, stream_id: UInt32) -> Bool:
    """True once no more bytes will come on the awaited stream: the peer sent
    END_STREAM, the stream was reset (either side), or a GOAWAY excludes it.

    A reset does not set `end_stream_seen` (h2_client keeps the two apart, see
    `H2ClientStream.reset_error_code`), so it is checked on its own; without
    it a reset Listen stream sat in the receive loop until the wall budget,
    and every later poll did the same, so the source never reconnected."""
    var idx = h2.find_stream_idx(stream_id)
    if idx < 0:
        return False
    if h2.streams[idx].end_stream_seen:
        return True
    if h2.streams[idx].reset_error_code >= Int64(0):
        return True
    return _goaway_excludes(h2, stream_id)


def _take_response_body_bytes(
    mut h2: H2ClientConnectionState, stream_id: UInt32
) -> List[UInt8]:
    """Drain the awaited stream's accumulated response body bytes and reset its
    buffer to empty — so the next drive's `start_body_len` starts from zero and
    the gRPC framer only sees each byte once. Encapsulated: reads/writes go
    through H2ClientConnectionState's public fields, no pointer crosses out."""
    var idx = h2.find_stream_idx(stream_id)
    if idx < 0:
        return List[UInt8]()
    var slot = h2.streams[idx].response_body_idx
    if slot < 0:
        return List[UInt8]()
    var out = List[UInt8]()
    swap(out, h2.response_body_buffers[slot])
    return out^


# =============================================================================
# §2b — How the stream ended: its gRPC status.
#
# komira_grpc's `GrpcClient` decides the terminal status of a call it drove;
# this loop is not GrpcClient's, so it applies the same rules here with the
# same komira_grpc helpers (`parse_grpc_status_trailers` percent-decodes
# `grpc-message` and reads bytes, never `chr()`-widened characters;
# `grpc_error_from_http_non_200` is the spec's HTTP-to-gRPC table;
# `grpc_error_for_missing_status` is the reference clients' code for a
# response with no status). What GrpcClient never sees and a long-lived
# stream does: a reset, a GOAWAY, a closed connection and a half-received
# message, each given the code grpc-go gives it.
# =============================================================================


def _grpc_code_for_rst(rst_code: UInt32) -> UInt8:
    """The gRPC code for an RST_STREAM error code: grpc-go's
    `http2ErrConvTab` (internal/transport/http_util.go). A code outside the
    table is UNKNOWN, as there."""
    if rst_code == H2_ERR_REFUSED_STREAM:
        return GRPC_STATUS_UNAVAILABLE
    if rst_code == H2_ERR_CANCEL:
        return GRPC_STATUS_CANCELLED
    if (
        rst_code == H2_ERR_FLOW_CONTROL_ERROR
        or rst_code == H2_ERR_ENHANCE_YOUR_CALM
    ):
        return GRPC_STATUS_RESOURCE_EXHAUSTED
    if rst_code == H2_ERR_INADEQUATE_SECURITY:
        return GRPC_STATUS_PERMISSION_DENIED
    if rst_code <= H2_ERR_HTTP_1_1_REQUIRED:
        return GRPC_STATUS_INTERNAL
    return GRPC_STATUS_UNKNOWN


def _head_headers(h2: H2ClientConnectionState, idx: Int) raises -> HeaderMap:
    """The response head's fields (the trailers-only status lives here)."""
    var hdrs = HeaderMap()
    var slot = h2.streams[idx].response_header_idx
    if slot < 0:
        return hdrs^
    ref hlist = h2.response_header_lists[slot]
    for i in range(len(hlist)):
        hdrs.append(String(hlist[i].name), String(hlist[i].value))
    return hdrs^


def _listen_terminal_status(
    mut h2: H2ClientConnectionState,
    stream_id: UInt32,
    body_bytes_seen: Int,
    partial_message_bytes: Int,
) raises -> GrpcError:
    """The gRPC status a Listen stream ended with (or, for `open`, the
    failure its response head states). In order:

      1. a stated `grpc-status`, trailers first, then a trailers-only head
         (komira_grpc's `_grpc_status_from_sections` order), if not OK;
      2. an HTTP status other than 200: the spec's table;
      3. a stated OK with a partial gRPC message left over: INTERNAL (the
         message was cut; grpc-java: "Encountered end-of-stream mid-frame");
      4. a stated OK: OK;
      5. RST_STREAM: grpc-go's code for the reset code (INTERNAL when this
         client reset it);
      6. a GOAWAY that excludes the stream: UNAVAILABLE (not processed);
      7. no END_STREAM at all, so the connection closed: UNAVAILABLE;
      8. ended with no status: `grpc_error_for_missing_status` (UNKNOWN
         after trailers, INTERNAL after a body, UNKNOWN with neither).
    """
    var idx = h2.find_stream_idx(stream_id)
    if idx < 0:
        return GrpcError.simple(
            GRPC_STATUS_INTERNAL,
            String("FirestoreListen: the h2 state has no stream ")
            + String(Int(stream_id)),
        )
    var head = _head_headers(h2, idx)
    var trailers = extract_trailers_for_stream(h2, stream_id)
    var stated = Optional[GrpcError]()
    if trailers.contains_static("grpc-status"):
        stated = Optional(parse_grpc_status_trailers(trailers))
    else:
        stated = parse_grpc_status_initial_headers(head)
    if stated.__bool__() and not stated.value().is_ok():
        return stated.take()
    var http_status = h2.streams[idx].response_status
    if http_status != UInt16(0) and http_status != UInt16(200):
        return grpc_error_from_http_non_200(http_status)
    if stated.__bool__():
        if partial_message_bytes > 0:
            return GrpcError.simple(
                GRPC_STATUS_INTERNAL,
                String("FirestoreListen: the stream ended with grpc-status 0")
                + String(" but ")
                + String(partial_message_bytes)
                + String(
                    " bytes of a gRPC message were left over: the last"
                    " message was truncated"
                ),
            )
        return stated.take()
    var rst = h2.streams[idx].reset_error_code
    if rst >= Int64(0):
        var who = String("the server")
        if h2.streams[idx].reset_is_local:
            who = String("this client")
        return GrpcError.simple(
            _grpc_code_for_rst(UInt32(Int(rst))),
            who
            + String(" sent RST_STREAM(")
            + String(Int(rst))
            + String(") on the Listen stream before any grpc-status"),
        )
    if _goaway_excludes(h2, stream_id):
        return GrpcError.simple(
            GRPC_STATUS_UNAVAILABLE,
            String(
                "FirestoreListen: the server sent GOAWAY excluding the Listen"
                " stream (not processed)"
            )
            + h2_goaway_context(h2),
        )
    if not h2.streams[idx].end_stream_seen:
        var why = String(
            "FirestoreListen: the connection closed before the Listen stream"
            " ended (no END_STREAM, no grpc-status)"
        )
        if h2.is_goaway_received():
            why += h2_goaway_context(h2)
        return GrpcError.simple(GRPC_STATUS_UNAVAILABLE, why)
    return grpc_error_for_missing_status(
        trailers.len() > 0, body_bytes_seen
    )


def listen_end_is_permanent(code: Int) -> Bool:
    """True iff a Listen stream that ended with gRPC status `code` must not be
    reopened: the watch has failed and the caller must be told.

    The table is the Firestore SDKs' own (`isPermanentError`, firebase-js-sdk
    packages/firestore/src/remote/rpc_error.ts): CANCELLED, UNKNOWN,
    DEADLINE_EXCEEDED, RESOURCE_EXHAUSTED, INTERNAL, UNAVAILABLE and
    UNAUTHENTICATED restart the stream (the next dial fetches a fresh token);
    INVALID_ARGUMENT, NOT_FOUND, ALREADY_EXISTS, PERMISSION_DENIED,
    FAILED_PRECONDITION, ABORTED, OUT_OF_RANGE, UNIMPLEMENTED and DATA_LOSS do
    not. OK and -1 (not ended) are not failures; a code outside 0..16 reads as
    UNKNOWN, which restarts."""
    return (
        code == Int(GRPC_STATUS_INVALID_ARGUMENT)
        or code == Int(GRPC_STATUS_NOT_FOUND)
        or code == Int(GRPC_STATUS_ALREADY_EXISTS)
        or code == Int(GRPC_STATUS_PERMISSION_DENIED)
        or code == Int(GRPC_STATUS_FAILED_PRECONDITION)
        or code == Int(GRPC_STATUS_ABORTED)
        or code == Int(GRPC_STATUS_OUT_OF_RANGE)
        or code == Int(GRPC_STATUS_UNIMPLEMENTED)
        or code == Int(GRPC_STATUS_DATA_LOSS)
    )


# =============================================================================
# §3 — FirestoreListenClient — the gRPC Listen wiring over the recv-drive.
# =============================================================================


struct FirestoreListenClient[S: IoStream](Movable, Deinitable):
    """A Firestore `Listen` bidi client bound to one h2 stream `S`.

    Lifecycle:
      1. `FirestoreListenClient(stream^, host, access_token)` — take the dialed,
         ALPN-h2 (or h2c) stream + the GCP OAuth2 access token.
      2. `open(reactor, database, document_names, target_id)` — send the h2
         preface + SETTINGS, the Listen request HEADERS (no END_STREAM — the
         request half stays open), and the first ListenRequest as a gRPC DATA
         frame (no END_STREAM). Drives the recv until the response HEADERS
         (`:status 200`) land.
      3. `poll(reactor)` repeatedly — drive the recv for the next server push,
         drain complete gRPC envelopes, decode each into a ListenEvent. Returns
         the events collected this poll (possibly empty on a bounded no-progress
         park; the caller keeps polling).

    Fields (all encapsulated; NO UnsafePointer, NO wildcard):
      _h2        — the h2 connection state (single-owner).
      _stream    — the dialed h2 IoStream (single-owner).
      _framer    — komira_grpc's envelope framer (`ClientFramer`).
      _host      — :authority.
      _token     — the OAuth2 access token (attached as authorization: Bearer).
      _stream_id — the odd h2 stream id the Listen call runs on.
      _status    — the response :status (0 until open() sees the response head).
      _bytes_seen — cumulative pushed response-body bytes (the de-risk counter).
      _ended_seen — the last poll saw the stream end.
      _terminal_code    — the gRPC status the stream ended with, or -1 while
                          it is open (`_listen_terminal_status`).
      _terminal_message — that status's message (percent-decoded).
    """

    var _h2: H2ClientConnectionState
    var _stream: Self.S
    var _framer: ClientFramer
    var _host: String
    var _token: String
    var _stream_id: UInt32
    var _status: UInt16
    var _bytes_seen: Int
    var _ended_seen: Bool
    var _terminal_code: Int
    var _terminal_message: String

    def __init__(
        out self, var stream: Self.S, var host: String, var access_token: String
    ):
        self._h2 = H2ClientConnectionState()
        self._stream = stream^
        self._framer = ClientFramer()
        self._host = host^
        self._token = access_token^
        self._stream_id = UInt32(0)
        self._status = UInt16(0)
        self._bytes_seen = 0
        self._ended_seen = False
        self._terminal_code = -1
        self._terminal_message = String("")

    @always_inline
    def bytes_seen(self) -> Int:
        """Cumulative bytes of pushed response DATA drained so far — the metric
        the flow-control stress driver asserts crosses >64KB / >128KB."""
        return self._bytes_seen

    @always_inline
    def status(self) -> UInt16:
        return self._status

    @always_inline
    def terminal_code(self) -> Int:
        """The gRPC status the stream ended with (0 is OK), or -1 while it is
        open. Set by the poll that first sees the end; see
        `_listen_terminal_status` for how a reset, a GOAWAY, a closed
        connection, a missing status and a cut message are read."""
        return self._terminal_code

    def terminal_message(self) -> String:
        """The message of `terminal_code` (percent-decoded `grpc-message`, or
        this client's description of the end)."""
        return self._terminal_message

    def terminal_error_text(self) -> String:
        """`[grpc:N] message` for `terminal_code`, the form komira_grpc
        raises (read back with `parse_grpc_status_code`)."""
        return format_grpc_error_message(
            UInt8(self._terminal_code), self._terminal_message
        )

    def _record_end(mut self) raises:
        """Read and keep the terminal status, once, after the last complete
        envelopes were popped (so the framer holds only a partial one)."""
        if self._terminal_code >= 0:
            return
        var ge = _listen_terminal_status(
            self._h2,
            self._stream_id,
            self._bytes_seen,
            self._framer.unconsumed_len(),
        )
        self._terminal_code = Int(ge.code)
        self._terminal_message = String(ge.message)

    def open[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        database: String,
        document_names: List[String],
        target_id: Int,
    ) raises:
        """COLD-START the Listen bidi stream: emit preface+SETTINGS, the Listen
        HEADERS (no END_STREAM), the first ListenRequest DATA (no END_STREAM),
        and drive the recv until the response HEADERS (:status) arrive. A
        cold-start documents-target has NO read_time, so Firestore sends the
        initial snapshot.

        Raises `[grpc:N] ...` when the answer is a failure rather than an open
        stream: a trailers-only response with a non-OK `grpc-status` (what
        Firestore sends for a request it rejects), an HTTP status other than
        200 (through the spec's HTTP-to-gRPC table), or a stream that ended
        during the open with any other non-OK status."""
        var req_proto = encode_listen_request_documents(
            database, document_names, target_id
        )
        self._open_with_request[RT](reactor, database, req_proto^)

    def open_after[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        database: String,
        document_names: List[String],
        target_id: Int,
        resume_seconds: Int64,
        resume_nanos: Int64,
    ) raises:
        """RESUME the Listen bidi stream AFTER a committed `read_time` watermark
        (`Target.read_time`, the resume_type oneof). Firestore re-delivers ONLY
        changes with read_time > the watermark (never a NEW change stamped <=
        it), so there is NO full-snapshot re-read on resume — exactly the
        exactly-once resume contract. Any re-delivered boundary duplicate is
        dropped by the apply's strict-`>` idempotence guard. A zero watermark
        (both fields 0) is treated as a cold start by the encoder."""
        var req_proto = encode_listen_request_documents_after(
            database, document_names, target_id, resume_seconds, resume_nanos
        )
        self._open_with_request[RT](reactor, database, req_proto^)

    def _open_with_request[RT: Runtime](
        mut self,
        mut reactor: Reactor[RT.Sink],
        database: String,
        var req_proto: List[UInt8],
    ) raises:
        """Shared open path: emit preface+SETTINGS, the Listen HEADERS (no
        END_STREAM), the given (cold or resuming) ListenRequest DATA (no
        END_STREAM), and drive the recv until the response HEADERS arrive."""
        queue_client_preface_and_settings(self._h2)
        var sid = allocate_client_stream_id_or_raise(self._h2)
        _ = self._h2.create_stream(sid)
        self._stream_id = sid

        # gRPC-over-h2 request headers (RFC 7540 + the gRPC HTTP/2 spec).
        var hdrs = HeaderMap()
        hdrs.append(String("content-type"), String("application/grpc"))
        hdrs.append(String("te"), String("trailers"))
        hdrs.append(String("grpc-accept-encoding"), String("identity"))
        hdrs.append(
            String("authorization"), String("Bearer ") + String(self._token)
        )
        # REQUIRED Firestore routing header (root cause of a
        # zero-DATA-frame bug). The Firestore frontend routes the
        # Listen RPC to the correct database backend by the
        # `google-cloud-resource-prefix` header (value = the database resource
        # name `projects/{p}/databases/{d}`). WITHOUT it, Firestore accepts the
        # h2 HEADERS (`:status 200`) but immediately closes the stream with a
        # Trailers-Only response carrying `grpc-status: 3` (INVALID_ARGUMENT,
        # "Missing required http header ('google-cloud-resource-prefix' or
        # 'x-goog-request-params') or query param 'database'.") and pushes ZERO
        # DATA frames — the exact 200-then-0-bytes symptom. The equivalent
        # `x-goog-request-params: database=<url-encoded resource>` also
        # satisfies the router; the resource-prefix header is what the official
        # Firestore client libraries send, so we send that. `database` here is
        # exactly `projects/{p}/databases/{d}`.
        hdrs.append(
            String("google-cloud-resource-prefix"), String(database)
        )

        # HEADERS without END_STREAM — the request half stays OPEN so we can send
        # the ListenRequest DATA (and, later, more ListenRequests).
        encode_request_headers_to_frames(
            self._h2, sid,
            String("POST"),
            String("https"),
            String(self._host),
            String("/google.firestore.v1.Firestore/Listen"),
            hdrs^,
            end_stream=False,
        )

        # The (cold or resuming) ListenRequest as a gRPC-framed DATA frame — also
        # NO END_STREAM (the stream stays open for the server's unbounded push).
        var envelope = encode_grpc_envelope(req_proto^)
        encode_request_data_frame(self._h2, sid, envelope^, end_stream=False)

        # Drive the recv until the response :status is set (the response HEADERS
        # frame arrives before any pushed DATA). We loop the recv-drive because
        # the head may land across several reads; each iteration also flushes any
        # pending_out (SETTINGS-ACK / WINDOW_UPDATE).
        var head_iters = 0
        while self._status == UInt16(0):
            head_iters += 1
            if head_iters > 10_000:
                raise Error(
                    "FirestoreListen.open: response head not seen within budget"
                )
            var prog = drive_h2_recv_until_progress[Self.S, RT](
                self._h2, self._stream, reactor, sid,
                max_wall_us=30_000_000,
            )
            self._status = _response_status(self._h2, sid)
            if prog.timed_out and self._status == UInt16(0):
                raise Error(
                    "FirestoreListen.open: stalled before response head (no"
                    " :status within the wall budget)"
                )
            if prog.end_stream_seen and self._status == UInt16(0):
                self._record_end()
                raise Error(
                    "FirestoreListen.open: stream ended before response head: "
                    + self.terminal_error_text()
                )
            # Collect any body bytes already pushed with the head.
            self._drain_body_into_framer(sid)
            if prog.end_stream_seen and self._bytes_seen == 0:
                # Ended with no message at all: a trailers-only response (or
                # a reset or close right after the head). That is the RPC's
                # answer, so a failure is raised here. A stream that delivered
                # messages first is an open stream that ended: the polls hand
                # its messages over and then report the end.
                self._record_end()
                if self._terminal_code != 0:
                    raise Error(self.terminal_error_text())
        if self._status != UInt16(200) and self._terminal_code < 0:
            # A non-200 head on a stream still open: classic gRPC answers
            # every RPC with 200, so something in front of Firestore
            # answered. grpc-go fails the call on this head; so does this.
            var ge = _listen_terminal_status(
                self._h2, sid, self._bytes_seen, 0
            )
            raise Error(format_grpc_error_message(ge.code, ge.message))

    def poll[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], max_wall_us: Int64 = 30_000_000
    ) raises -> List[ListenEvent]:
        """Drive the recv for the next server push, drain complete gRPC
        envelopes, decode each into a ListenEvent. Returns the events collected
        this poll (may be empty on a bounded no-progress park; the caller keeps
        polling — an empty poll is NORMAL for a live-but-idle watch)."""
        return self.poll_progress[RT](reactor, max_wall_us=max_wall_us)

    def poll_progress[RT: Runtime](
        mut self, mut reactor: Reactor[RT.Sink], max_wall_us: Int64 = 30_000_000
    ) raises -> List[ListenEvent]:
        """Like `poll`, but ALSO records (on `self`) whether the server closed
        the stream this poll — read it via `last_poll_ended()`. That flag is the
        signal the LIVE source uses to trigger a reconnect: a live Listen stream
        normally never ends; an END_STREAM / peer-close (a server-side reset, an
        UNAVAILABLE, a DEADLINE) means the session dropped and the source must
        re-open AFTER the committed watermark.

        When the stream ends, its gRPC status is read and kept
        (`terminal_code` / `terminal_message`): a stream that ends is never
        reported as a clean end unless it stated `grpc-status: 0` after whole
        messages. Whether to reopen is the caller's (`listen_end_is_permanent`).

        (We record the flag on `self` rather than returning a (events, flag)
        struct so the caller can move the returned `List[ListenEvent]` freely —
        a two-field return struct forces a partial-move of one field out of the
        middle of the struct, which Mojo b2 rejects.)"""
        var prog = drive_h2_recv_until_progress[Self.S, RT](
            self._h2, self._stream, reactor, self._stream_id,
            max_wall_us=max_wall_us,
        )
        if prog.got_bytes:
            self._drain_body_into_framer(self._stream_id)
        var events = self._pop_all_events()
        self._ended_seen = prog.end_stream_seen
        if prog.end_stream_seen:
            self._record_end()
        return events^

    @always_inline
    def last_poll_ended(self) -> Bool:
        """True iff the most recent `poll_progress` observed the server closing
        the stream (END_STREAM / peer close) — the reconnect trigger."""
        return self._ended_seen

    def _drain_body_into_framer(mut self, sid: UInt32):
        """Move the awaited stream's accumulated response body bytes into the
        gRPC framer (and reset the stream buffer to empty) + bump the de-risk
        byte counter."""
        var body = _take_response_body_bytes(self._h2, sid)
        var n = len(body)
        if n > 0:
            self._bytes_seen += n
            self._framer.feed_owned(body^)

    def _pop_all_events(mut self) raises -> List[ListenEvent]:
        """Drain every complete gRPC envelope currently buffered in the framer,
        decoding each into a ListenEvent."""
        var events = List[ListenEvent]()
        while True:
            var popped = self._framer.try_pop_envelope()
            if not popped.__bool__():
                break
            var envelope = popped.take()
            if envelope.is_compressed():
                raise Error(
                    "FirestoreListen: the server sent a compressed gRPC"
                    " message, but the call only accepts identity encoding"
                )
            var view = Span[UInt8](envelope.payload).as_imm()
            events.append(decode_listen_response(view))
        return events^


def _response_status(
    h2: H2ClientConnectionState, stream_id: UInt32
) -> UInt16:
    var idx = h2.find_stream_idx(stream_id)
    if idx < 0:
        return UInt16(0)
    return h2.streams[idx].response_status
