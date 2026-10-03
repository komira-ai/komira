# =============================================================================
# src/komira_http/client/h2_client.mojo — HTTP/2 client driver
# =============================================================================
#
# An HTTP/2 client driver
# consuming the codec library (src/komira_http/codec/h2/). This module
# is the CLIENT-SIDE analog of `transport/serve_h2.mojo` (server-side)
# — same primitives, opposite direction.
#
# Architecture§3:
#   1. `H2ClientConnectionState` — per-conn state composing HpackEncoder +
#      HpackDecoder + SendFlowController + RecvFlowController + a list of
#      `H2ClientStream` (POD per-stream) + recv_buf/pending_out byte
#      accumulators + flags bitset + max_frame_size + max_concurrent_streams
#      + odd-stream-id allocator + GOAWAY accounting.
#   2. `H2ClientStream` — POD per-stream state. Heap-owning per-stream
#      response data (headers, body) is held in conn-level Slabs with
#      stream→index references (pointer-safe).
#   3. `start_h2_client_session[S, RT]` — emit 24-byte preface + client's
#      initial SETTINGS; await server's SETTINGS; ack.
#   4. `send_request_on_h2_conn[S, RT, B]` — allocate odd stream_id;
#      encode HEADERS via HpackEncoder; split into HEADERS+CONTINUATION*
#      per RFC 9113 §6.10; emit DATA respecting flow control; frame-drain
#      until the response END_STREAM arrives; return ClientResponse.
#
# Encapsulation:
#   * ZERO `UnsafePointer` in any public sig.
#   * ZERO wildcard origins (no MutAnyOrigin / ImmutAnyOrigin / MutExternalOrigin).
#   * ZERO `unsafe_from_address`.
#   * ZERO `take_pointee()` — `Optional.take()` / `swap(local, field)` per
#     the pointer rules.
#   * ZERO new ArcPointer (H2ClientConnectionState is single-owner; held
#     via Optional on the pooled H2PooledConn per the pool sibling
#     decision).
#   * ZERO additive parallel API (h1 path stays as-is; h2 is a NEW
#     dispatch branch).
#
# Pointer audit:
#   * `H2ClientConnectionState` — heap-Movable; safe in Optional/OwnedPointer.
#   * `H2ClientStream` — POD (Copyable); safe in `List[H2ClientStream]`.
#   * Per-stream heap-owning response data lives in conn-level lists with
#     stream→index references (same shape as `cont_reasm_buf`).
# =============================================================================


from komira_clock import now_ns as _mono_now_ns

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_http.client.header_map import (
    HeaderMap,
    ci_byte_eq_sab_static,
    sab_to_string,
    sab_to_string_lower,
)
from komira_http.transport.stream_park import park_on_pending
from komira_http.transport.io_stream import (
    IoStream,
    STREAM_IO_EOF,
    STREAM_IO_ERROR,
    STREAM_IO_PENDING,
    STREAM_IO_READY,
)
from komira_http.codec.h2.connection_preface import (
    H2_CLIENT_PREFACE,
    H2_CLIENT_PREFACE_LEN,
)
from komira_http.codec.h2.continuation_splitter import (
    split_header_block_into_frames,
)
from komira_http.codec.h2.flow_control import (
    H2_INITIAL_WINDOW_SIZE_DEFAULT,
    FLOW_RESULT_OK,
    FLOW_RESULT_RST_STREAM,
    RecvFlowController,
    SendFlowController,
)
from komira_http.codec.h2.frame import (
    FLAG_ACK,
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
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
    H2_ERR_ENHANCE_YOUR_CALM,
    H2_ERR_FLOW_CONTROL_ERROR,
    H2_ERR_NO_ERROR,
    H2_ERR_PROTOCOL_ERROR,
    H2_ERR_REFUSED_STREAM,
    H2_ERR_STREAM_CLOSED,
    MAX_FRAME_PAYLOAD_DEFAULT,
    SETTINGS_ENABLE_PUSH,
    SETTINGS_HEADER_TABLE_SIZE,
    SETTINGS_INITIAL_WINDOW_SIZE,
    SETTINGS_MAX_CONCURRENT_STREAMS,
    SETTINGS_MAX_FRAME_SIZE,
    SETTINGS_MAX_HEADER_LIST_SIZE,
    SettingsEntry,
    decode_frame,
    encode_data_frame,
    encode_goaway_frame,
    encode_ping_frame,
    encode_rst_stream_frame,
    encode_settings_ack_frame,
    encode_settings_frame,
    encode_window_update_frame,
)
from komira_http.codec.h2.connection_state import (
    H2_MAX_HEADER_BLOCK_BYTES,
    H2_MAX_HEADER_BLOCK_FRAMES,
)
from komira_http.codec.h2.hpack import (
    HpackDecoder,
    HpackEncoder,
    HpackHeader,
)
from komira_http.codec.h2.response_validation import (
    H2_MALFORMED_CONTENT_LENGTH_MISMATCH,
    H2_MALFORMED_DATA_BEFORE_HEAD,
    H2_MALFORMED_OK,
    H2_MALFORMED_TRAILER_NOT_END_STREAM,
    h2_malformed_reason_text,
    h2_status_has_no_content,
    h2_status_is_informational,
    h2_validate_response_head,
    h2_validate_response_trailers,
)
from komira_http.codec.h2.stream import (
    STREAM_STATE_CLOSED,
    STREAM_STATE_HALF_CLOSED_LOCAL,
    STREAM_STATE_HALF_CLOSED_REMOTE,
    STREAM_STATE_IDLE,
    STREAM_STATE_OPEN,
)


# =============================================================================
# §1 — H2 client conn lifecycle flags.
# =============================================================================

comptime H2C_FLAG_PREFACE_SENT: UInt8 = 1 << 0
"""Set after the 24-byte preface is queued in pending_out."""

comptime H2C_FLAG_SETTINGS_SENT: UInt8 = 1 << 1
"""Set after the client's initial non-ACK SETTINGS frame is queued."""

comptime H2C_FLAG_SERVER_SETTINGS_SEEN: UInt8 = 1 << 2
"""Set after the server's initial non-ACK SETTINGS frame has arrived."""

comptime H2C_FLAG_GOAWAY_RECEIVED: UInt8 = 1 << 3
"""Set if the server emitted a GOAWAY frame. The connection is draining."""

comptime H2C_FLAG_HEADER_BLOCK_ABANDONED: UInt8 = 1 << 4
"""RFC 9113 §6.10 — set when the client refused a frame that interrupted an
open header block and staged its own GOAWAY(PROTOCOL_ERROR). ⛔ IT IS A LATCH
AND IT IS NEVER CLEARED.

⚠ This is NOT `H2C_FLAG_GOAWAY_RECEIVED`, which records the PEER's GOAWAY. This
one records that WE tore the connection down, and the distinction is the whole
point: a peer GOAWAY leaves in-flight streams decodable, whereas an abandoned
header block does not. HPACK's dynamic table is per-connection and strictly
ordered, so the moment a block is abandoned mid-decode every subsequent header
block on the connection decodes against a table the peer does not have.

⛔ THE LATCH IS WHAT MAKES THE REFUSAL STICK ACROSS CALLS. Both production
drivers (`drive_h2_streams_to_completion` here, `_drive_recv` in
`komira_gcp_firestore/firestore_listen_client.mojo`) call
`process_received_frames` in a loop and `continue` without consulting
`pending_out` for a staged GOAWAY. Without the latch, the refusal returns, the
loop appends more bytes, and the CONTINUATION that was going to complete the
abandoned block — CONTINUATION being the one frame type the §6.10 guard must
exempt — completes it on the very next call, delivering the response. That is
the same silent desync one call later.
"""

comptime _H2_GOAWAY_DEBUG_RENDER_MAX: Int = 256
"""Cap on how many GOAWAY debug-data bytes are rendered into an error string.

The payload is peer-controlled and RFC 9113 §6.8 puts no bound on its length
beyond the frame size, so an un-capped render would let an origin choose the
size of every one of our log lines."""

def _h2_debug_byte_is_renderable(b: Int) -> Bool:
    """The ALLOWLIST for peer-controlled GOAWAY debug bytes. See
    `H2ClientConnectionState.goaway_debug_data_text`, which states why this is
    a retry-safety control and not typography.

    Letters, digits, space, and `._:/,` — enough for the one-line explanations
    servers actually send. ⛔ EVERY OTHER PRINTABLE BYTE IS EXCLUDED ON
    PURPOSE, and the load-bearing exclusions are `-` (both
    `h2-goaway-*` retry tokens are spelled with it) and `[` `]` (every
    `HttpError[...]` class token in this tree is). `'` `;` `=` are excluded
    too: they are `h2_goaway_context`'s own field punctuation, so a peer
    cannot close our quote and forge a second structured field.

    ⛔ DO NOT WIDEN THIS WITHOUT RE-READING
    `test_peer_debug_data_cannot_forge_a_retry_classifier_token`. Re-admitting
    `-` alone is enough to let a peer have a non-idempotent request executed
    twice."""
    if b >= 0x30 and b <= 0x39:
        return True  # 0-9
    if b >= 0x41 and b <= 0x5A:
        return True  # A-Z
    if b >= 0x61 and b <= 0x7A:
        return True  # a-z
    if b == 0x20:
        return True  # space
    if b == 0x2E:
        return True  # .
    if b == 0x2C:
        return True  # ,
    if b == 0x3A:
        return True  # :
    if b == 0x2F:
        return True  # /
    if b == 0x5F:
        return True  # _
    return False


# ⚠ BIT 5, NOT 4. Bit 4 is `H2C_FLAG_HEADER_BLOCK_ABANDONED` (RFC 9113
# §6.10, landed separately). The two flags are unrelated and both live on
# `H2ClientConnectionState.flags`, so they must not share a bit — an
# abandoned header block would otherwise read as an outstanding keepalive
# PING, and clearing the PING on its ACK would silently release the §6.10
# latch that is documented above as NEVER CLEARED.
comptime H2C_FLAG_KEEPALIVE_PING_OUTSTANDING: UInt8 = 1 << 5
"""Set while a CLIENT-ORIGINATED keepalive PING is awaiting its ACK.

★ THE LIVENESS PROBE. A client whose only PINGs are the passive echo of a
PING the PEER sent never ASKS a peer whether it is
still there. A connection that is UP and SILENT could then only be given up
on by the driver's 120s wall
clock, which is a budget expiring, not a verdict: it cannot say whether the peer
was slow, dead, or the loop was spinning.

A PING is the one frame whose ACK proves the peer's H2 LAYER is alive, not just
its TCP stack, and it is what every other client uses for this (Go's
`Transport.ReadIdleTimeout`/`PingTimeout`, hyper's `http2_keep_alive_interval`,
gRPC keepalive). `keepalive_ping_data` holds the 8 opaque bytes of the
outstanding probe so an arriving ACK can be MATCHED to it — an ACK carrying
anything else belongs to somebody else's probe and must not clear ours."""


# =============================================================================
# §1b — Malformed-response SCOPE (RFC 9113 §8.1.1).
# =============================================================================
#
# ⛔ THE SCOPE IS NOT DECORATION — IT DECIDES WHETHER THE CALLER GETS A
# RESPONSE AT ALL. Both scopes refuse the peer identically
# (RST_STREAM(PROTOCOL_ERROR), §8.1.1's "stream error") and both stop the
# driver. They part on ONE question: was there ever a complete, well-formed
# response?
#
#   * HEAD    — the response head itself broke a rule, or the content it
#               framed contradicted that head. There is no message to deliver,
#               so `extract_response_for_stream` REFUSES. Anything else would
#               hand a caller a status it must not trust, which is the class of
#               defect this whole layer exists to end.
#   * TRAILER — the head was well-formed, was validated, and its status and
#               fields were delivered BEFORE the trailer section arrived. The
#               trailer is dropped and the peer is told; the head response
#               stays extractable, because a trailer cannot retroactively
#               unmake a message the origin already committed to. This is the
#               exact shape of the defect that motivated the split: a trailer
#               carrying `:status: 200` turning an already-delivered 500 into
#               a 200.

comptime H2_MALFORMED_SCOPE_NONE: UInt8 = 0
"""No RFC 9113 §8.1.1 violation has been seen on this stream."""

comptime H2_MALFORMED_SCOPE_HEAD: UInt8 = 1
"""The response head (or the content it framed) is malformed — there is no
response to deliver."""

comptime H2_MALFORMED_SCOPE_TRAILER: UInt8 = 2
"""The trailer section is malformed — the head response stands."""


# =============================================================================
# §2 — H2ClientStream — POD per-stream state.
# =============================================================================


struct H2ClientStream(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    """One client-initiated stream's state.

    POD (Copyable). Heap-owning per-stream response data lives in
    conn-level Slabs; this struct only holds index references.

    Fields:
      stream_id           — RFC 9113 §5.1.1: client-initiated streams are
                            odd-numbered, monotonically increasing.
      state               — STREAM_STATE_* discriminator from
                            `codec/h2/stream.mojo`. The driver advances on
                            send/recv events.
      send_window         — signed Int32; can go
                            negative after retroactive SETTINGS decrease.
      recv_window         — server-side window for this stream's response
                            DATA; the driver decrements on each DATA frame
                            received + emits WINDOW_UPDATE on ring-drain.
      continuation_pending — true between a HEADERS-without-END_HEADERS
                            and its END_HEADERS-carrying CONTINUATION.
      end_stream_seen     — true once the server has sent a frame with
                            END_STREAM on this stream; signals response
                            body is complete.
      response_status     — 0 if not yet seen; the driver fills from the
                            :status pseudo-header on response HEADERS.
      response_body_idx   — index into the conn's `response_body_buffers`
                            List; -1 if this stream has no body bytes yet.
      response_header_count — number of caller-visible (non-pseudo)
                            response header pairs collected so far.
      response_header_idx — index into the conn's
                            `response_header_lists` List of List[HpackHeader];
                            -1 if not yet allocated. (One List per stream.)
    """

    var stream_id: UInt32
    var state: UInt8
    var send_window: Int32
    var recv_window: Int32
    var continuation_pending: Bool
    var end_stream_seen: Bool
    var response_status: UInt16
    var response_body_idx: Int
    var response_header_count: UInt32
    var response_header_idx: Int
    # bytes of inbound DATA consumed
    # on this stream since the last stream-level WINDOW_UPDATE we emitted. The
    # buffered drive (`drive_h2_streams_to_completion`) consumes DATA
    # synchronously, so receipt == drain; we accumulate here and emit a
    # WINDOW_UPDATE(stream_id) once it crosses the recv-FC drain watermark,
    # restoring `recv_window`. WITHOUT this, the per-stream recv window
    # monotonically depletes and a flow-control-respecting server (GCS) stops
    # sending once it is exhausted -> the h2 drive parks on a fd that never
    # wakes -> 120s wall-deadline (a GCS ReadObject wedge). POD field;
    # pointer-safe (H2ClientStream stays Copyable POD).
    var recv_pending_update: UInt32
    # request-body bytes this
    # stream charged against the CONNECTION-level send window
    # (`send_fc.conn_send_window`). Accumulated as DATA frames are pumped
    # (`pump_pending_request_bodies`). On `retire_stream` — reached only after
    # the server sent END_STREAM on the RESPONSE, which proves it received the
    # whole request body — we credit these bytes BACK to the connection send
    # window so a long sequence of small POSTs on ONE reused connection cannot
    # drift `conn_send_window` to <=0 and wedge (the per-stream window is
    # discarded on retire; only the shared connection window needs healing). POD
    # field; H2ClientStream stays Copyable POD (pointer-safe).
    var send_body_charged: UInt32
    # ★ H2-RST-IS-NOT-A-COMPLETE-RESPONSE. The RST_STREAM error
    # code the SERVER sent for this stream, or -1 if it was never reset.
    #
    # WHY IT IS A SEPARATE FIELD FROM `end_stream_seen`, AND WHY IT WAS FOUND
    # BY A THIRD-PARTY ORACLE. Until this landed, `process_received_frames`
    # answered an inbound RST_STREAM with `end_stream_seen = True` — the same
    # bit an END_STREAM sets. `drive_h2_streams_to_completion` returns when
    # every awaited stream has that bit, and `extract_response_for_stream`
    # then hands the caller `(status, headers, body)`. So a server that RESET
    # a stream mid-response was reported to the caller as a SUCCESSFUL,
    # SILENTLY TRUNCATED response — for a GCS ReadObject, a short object with
    # no error — and the RST error code was discarded entirely, collapsing
    # REFUSED_STREAM (definitively not processed, RFC 9113 §8.7) and CANCEL
    # and INTERNAL_ERROR into "200 OK".
    #
    # The bit was OVERLOADED: it meant both "the peer finished sending" (the
    # driver's stop condition) and "the response is complete"
    # (`extract_response_for_stream`'s precondition). Those come apart exactly
    # on RST. Splitting them is the fix; setting `end_stream_seen` was the
    # defect, and simply removing it without this field would have replaced a
    # wrong answer with a HANG.
    #
    # A differential test against python-hyper `h2` pins this: `h2` reads the
    # same bytes as `StreamReset`, END_STREAM false. POD Int64; H2ClientStream stays Copyable
    # POD (pointer-safe).
    var reset_error_code: Int64
    # TRUE when `reset_error_code` records a reset WE issued (today: a
    # stream-scoped FLOW_CONTROL_ERROR under RFC 9113 §6.9) rather than one
    # the peer sent. Both dispositions are "this response is incomplete", but
    # they are DIFFERENT FACTS and the driver must not report ours as the
    # peer's — a diagnostic that names the wrong party sends every reader
    # to the wrong place. POD Bool; H2ClientStream stays
    # Copyable POD (pointer-safe).
    var reset_is_local: Bool
    # ★★. The six fields below exist
    # because `_handle_inbound_headers_or_cont` used to apply EVERY decoded
    # header block to this stream identically — it could not tell a response
    # head from an interim 1xx from a trailer section, so a trailer's
    # `:status` overwrote an already-delivered one (500 -> 200) and a 1xx's
    # fields leaked into the final response's header map. All six are POD;
    # `H2ClientStream` stays Copyable POD (pointer-safe).
    #
    # response_head_seen — a FINAL (non-1xx) response head has been applied.
    #   This, not "is this the second block", is what makes the NEXT header
    #   block a TRAILER section: an interim 1xx does not set it, so a 1xx
    #   followed by the real head is two heads, not a head plus trailers.
    var response_head_seen: Bool
    # malformed_scope — H2_MALFORMED_SCOPE_*; which PART of the message broke
    #   RFC 9113 §8.1.1. The distinction is load-bearing at extraction time:
    #   a malformed HEAD means there is no response to hand the caller, while
    #   a malformed TRAILER leaves an already-complete head response whose
    #   status was fixed before the trailer arrived.
    var malformed_scope: UInt8
    # malformed_reason — the H2_MALFORMED_* code, rendered by
    #   `h2_malformed_reason_text` at the raise site. A code rather than a
    #   String precisely so this struct stays POD.
    var malformed_reason: UInt16
    # declared_content_length — the head's content-length, or -1 if absent.
    #   Compared against the summed DATA payload lengths at END_STREAM
    #   (RFC 9113 §8.1.1); -1 disables the comparison.
    var declared_content_length: Int64
    # request_method_is_head — the request this stream carries used HEAD, so
    #   RFC 9110 §6.4.1 exempts the response from the content-length/DATA
    #   comparison. WITHOUT this every HEAD response is a stream error.
    var request_method_is_head: Bool
    # response_trailer_idx — slot in the conn's `response_trailer_lists`, or
    #   -1 if this stream has carried no trailer field. Allocated LAZILY: the
    #   overwhelming majority of responses have no trailer section, and a
    #   per-stream allocation for all of them is the cost this avoids.
    var response_trailer_idx: Int

    @staticmethod
    def new(stream_id: UInt32, initial_window: Int32) -> H2ClientStream:
        return H2ClientStream(
            stream_id=stream_id,
            state=STREAM_STATE_IDLE,
            send_window=initial_window,
            recv_window=initial_window,
            continuation_pending=False,
            end_stream_seen=False,
            response_status=UInt16(0),
            response_body_idx=-1,
            response_header_count=UInt32(0),
            response_header_idx=-1,
            recv_pending_update=UInt32(0),
            send_body_charged=UInt32(0),
            reset_error_code=Int64(-1),
            reset_is_local=False,
            response_head_seen=False,
            malformed_scope=H2_MALFORMED_SCOPE_NONE,
            malformed_reason=H2_MALFORMED_OK,
            declared_content_length=Int64(-1),
            request_method_is_head=False,
            response_trailer_idx=-1,
        )

    def __init__(
        out self,
        stream_id: UInt32,
        state: UInt8,
        send_window: Int32,
        recv_window: Int32,
        continuation_pending: Bool,
        end_stream_seen: Bool,
        response_status: UInt16,
        response_body_idx: Int,
        response_header_count: UInt32,
        response_header_idx: Int,
        recv_pending_update: UInt32 = UInt32(0),
        send_body_charged: UInt32 = UInt32(0),
        reset_error_code: Int64 = Int64(-1),
        reset_is_local: Bool = False,
        response_head_seen: Bool = False,
        malformed_scope: UInt8 = H2_MALFORMED_SCOPE_NONE,
        malformed_reason: UInt16 = H2_MALFORMED_OK,
        declared_content_length: Int64 = Int64(-1),
        request_method_is_head: Bool = False,
        response_trailer_idx: Int = -1,
    ):
        self.stream_id = stream_id
        self.state = state
        self.send_window = send_window
        self.recv_window = recv_window
        self.continuation_pending = continuation_pending
        self.end_stream_seen = end_stream_seen
        self.response_status = response_status
        self.response_body_idx = response_body_idx
        self.response_header_count = response_header_count
        self.response_header_idx = response_header_idx
        self.recv_pending_update = recv_pending_update
        self.send_body_charged = send_body_charged
        self.reset_error_code = reset_error_code
        self.reset_is_local = reset_is_local
        self.response_head_seen = response_head_seen
        self.malformed_scope = malformed_scope
        self.malformed_reason = malformed_reason
        self.declared_content_length = declared_content_length
        self.request_method_is_head = request_method_is_head
        self.response_trailer_idx = response_trailer_idx


# =============================================================================
# §3 — H2ClientConnectionState — per-conn state for h2 multiplexing.
# =============================================================================

comptime H2_CLIENT_DEFAULT_MAX_RESPONSE_BODY: Int = 100 * 1024 * 1024
"""Default per-stream response-body ceiling, matching the h1 lane's
`_RECV_RING_DEFAULT_MAX_BODY` (client/response_body.mojo). Settable per
connection via `H2ClientConnectionState.max_response_body_bytes`."""

comptime H2_LAST_CLIENT_STREAM_ID: UInt32 = UInt32(0x7fffffff)
"""RFC 9113 §5.1.1 -- the stream identifier is 31 bits, so this is the last
one a client can legally use. Odd, as every client-initiated id must be."""

comptime H2_STREAM_ID_EXHAUSTED: UInt32 = UInt32(0)
"""`allocate_client_stream_id`'s refusal value. 0 is reserved for
connection-level frames and is not a legal STREAM id in either direction, so
it cannot be mistaken for a usable one on the wire."""


struct H2ClientConnectionState(Movable, Deinitable):
    """Per-connection HTTP/2 client state.

    Symmetric to the server-side `H2ConnectionState`, but with
    client-initiated semantics: client allocates odd stream IDs, client
    sends preface, client sends initial SETTINGS, client receives
    response HEADERS+DATA (not request HEADERS+DATA).

    Heap-owning per-stream response data (header lists, body bytes) is
    stored in conn-level Lists with stream→index references. This is
    the pointer-safe shape (`H2ClientStream` itself is POD).

    Fields:
      hpack_encoder       — outbound (request) header encoder
      hpack_decoder       — inbound (response) header decoder
      send_fc             — connection-level send-window controller
      recv_fc             — connection-level recv-window controller
      streams             — POD per-stream state (List, Copyable, pointer-safe)
      recv_buf            — bytes pulled from stream.try_read awaiting decode
      pending_out         — bytes to flush to stream.try_write
      response_header_lists — List of List[HpackHeader]; per-stream
                            response headers accumulated during decode
                            (the buffered shape).
      response_body_buffers — List of List[UInt8]; per-stream response
                            body bytes.
      max_frame_size_peer — server's advertised SETTINGS_MAX_FRAME_SIZE.
      max_frame_size_local — what we advertise; bounds our outbound frames.
      max_concurrent_streams_peer — server's advertised limit.
      next_client_stream_id — next odd stream_id to allocate; starts at 1.
      flags               — H2C_FLAG_* bitset.
      goaway_last_stream_id — set if server emitted GOAWAY; streams with
                            id > this are rejected (server WILL NOT
                            process them).
      goaway_error_code   — server's GOAWAY error code, if received.
      goaway_debug_data   — server's GOAWAY Additional Debug Data, if any.
      keepalive_ping_data — opaque bytes of an outstanding liveness probe.
      keepalive_ping_sent_ns — monotonic ns that probe was staged at.
      cont_reasm_stream_id — RFC 9113 §6.10: at most one in-flight HEADERS
                            reassembly per connection.
      cont_reasm_buf      — bytes of an in-flight HEADERS+CONTINUATION
                            reassembly.
    """

    var hpack_encoder: HpackEncoder
    var hpack_decoder: HpackDecoder
    var send_fc: SendFlowController
    var recv_fc: RecvFlowController
    var streams: List[H2ClientStream]
    var recv_buf: List[UInt8]
    var pending_out: List[UInt8]
    var response_header_lists: List[List[HpackHeader]]
    var response_body_buffers: List[List[UInt8]]
    var max_frame_size_peer: Int
    var max_frame_size_local: Int
    var max_concurrent_streams_peer: UInt32
    var next_client_stream_id: UInt32
    var flags: UInt8
    var goaway_last_stream_id: UInt32
    var goaway_error_code: UInt32
    # RFC 9113 §6.8 "Additional Debug Data" — the bytes after the 8-byte fixed
    # part of a GOAWAY payload. This is the SERVER'S OWN EXPLANATION for the
    # teardown ("max_age", "too_many_streams", a request id); dropping it with
    # the `Frame` loses the best diagnostic there is. Go surfaces it through `GoAwayError.DebugData`
    # (`TestTransportUsesGoAwayDebugError_RoundTrip`), and it is exactly the
    # diagnostic that shortens an investigation.
    var goaway_debug_data: List[UInt8]
    # The 8 opaque bytes of the keepalive PING currently awaiting an ACK, valid
    # only while H2C_FLAG_KEEPALIVE_PING_OUTSTANDING is set. See that flag.
    var keepalive_ping_data: SIMD[DType.uint8, 8]
    # Monotonic ns at which that probe was staged. CONNECTION-scoped, not
    # drive-scoped, so a probe staged by one `drive_h2_streams_to_completion`
    # call is still on the clock in the next one.
    var keepalive_ping_sent_ns: Int64
    var cont_reasm_stream_id: UInt32
    var cont_reasm_buf: List[UInt8]
    # Frames seen in the CURRENT HEADERS+CONTINUATION sequence. See
    # `codec/h2/connection_state.mojo` §1b — the CVE-2024-27316 ceilings are
    # SHARED with the server; a hostile ORIGIN floods our client the same way a
    # hostile client floods our server.
    var cont_reasm_frames: Int
    # Ceiling on the accumulated RESPONSE BODY of one stream. The h1 lane has
    # `_RECV_RING_DEFAULT_MAX_BODY` (100 MiB, client/response_body.mojo);
    # without this the h2 lane would have NOTHING — and `_replenish_recv_window`
    # actively refills both recv windows on every DATA frame, so flow control
    # is not a backpressure ceiling either. This client talks to S3-compatible /
    # Azure / arbitrary object-store endpoints (client/objectstore_http.mojo),
    # i.e. a hostile or compromised origin could stream us to death.
    var max_response_body_bytes: Int
    # connection-level analogue of
    # H2ClientStream.recv_pending_update — bytes of inbound DATA consumed across
    # ALL streams since the last connection-level (stream_id=0) WINDOW_UPDATE we
    # emitted. Emit + reset when it crosses the recv-FC drain watermark.
    var recv_conn_pending_update: UInt32
    # pending OUTBOUND request bodies,
    # staged flow-control-aware. Each pending entry is a (stream_id, body-bytes,
    # cursor) triple held at CONNECTION level (pointer-safe: parallel Lists, no
    # heap-owning field on the POD H2ClientStream). `stage_request_body` appends
    # here; `pump_pending_request_bodies` frames the next
    # min(stream_send_window, conn_send_window, max_frame_size, remaining) bytes
    # into `pending_out` as a DATA frame (END_STREAM only on the final chunk) and
    # advances the cursor, until the body is fully sent OR the send window is
    # exhausted (in which case the driver waits for a server WINDOW_UPDATE that
    # reopens the window, then pumps again). WITHOUT this streaming refill a body
    # larger than the initial 65535-byte send window would be staged as ONE oversized
    # DATA frame (violating both SETTINGS_MAX_FRAME_SIZE and the send window); the
    # driver would flush the first window's worth, `pending_out` would empty, no further
    # body would be queued, END_STREAM would never be observed, and the loop would spin reads to
    # its iteration cap (`HttpError[TIMEOUT]: h2 driver iteration cap
    # exceeded` — the large-upload signature).
    var pending_body_stream_ids: List[UInt32]
    var pending_body_buffers: List[List[UInt8]]
    var pending_body_cursors: List[Int]
    # free-lists of retired slot indices in
    # `response_header_lists` / `response_body_buffers`, so a completed stream's
    # heap-owning header/body Lists are FREED (swapped to empty) and their slots
    # RECYCLED by the next `create_stream`. WITHOUT this, `create_stream` appends
    # a new slot on every request and NEVER frees the old one, so a long-lived
    # REUSED h2 connection (the `GcpWebFrontend._publish` ~1867-`rewrite_object`
    # web-publish mirror) accumulates O(N) retained per-stream state, `streams`
    # grows to N entries (making `find_stream_idx` O(N) and the run O(N^2)), and
    # per-request servicing time climbs superlinearly until one
    # `drive_h2_streams_to_completion` call crosses the 120s wall bound and
    # raises `HttpError[TIMEOUT]` (the reported connection-longevity wedge). The
    # POD `H2ClientStream` entry itself is removed from `streams` on retire
    # (swap-remove); these free-lists recycle the two heap-owning parallel-List
    # slots it referenced. pointer-safe: `List[Int]` of plain indices, no wildcard.
    var free_header_slots: List[Int]
    var free_body_slots: List[Int]
    # ★ THE TRAILER SECTION IS A SEPARATE MESSAGE PART, AND IT USED TO BE
    # MERGED. Until landed, a second
    # HEADERS block on a stream was appended to the SAME
    # `response_header_lists` slot as the response head, so a caller could not
    # tell a field the origin committed to BEFORE the body from one it
    # appended AFTER — which is the entire reason RFC 9110 §6.5 separates
    # them, and why a `grpc-status` trailer means something a header does not.
    # Per-stream slots, allocated LAZILY on the first trailer field and
    # recycled through `free_trailer_slots` exactly as the header/body slots
    # are.
    var response_trailer_lists: List[List[HpackHeader]]
    var free_trailer_slots: List[Int]

    def __init__(out self):
        self.hpack_encoder = HpackEncoder(max_table_size=4096)
        self.hpack_decoder = HpackDecoder(max_table_size=4096)
        self.send_fc = SendFlowController()
        self.recv_fc = RecvFlowController()
        self.streams = List[H2ClientStream]()
        self.recv_buf = List[UInt8]()
        self.pending_out = List[UInt8]()
        self.response_header_lists = List[List[HpackHeader]]()
        self.response_body_buffers = List[List[UInt8]]()
        self.max_frame_size_peer = MAX_FRAME_PAYLOAD_DEFAULT
        self.max_frame_size_local = MAX_FRAME_PAYLOAD_DEFAULT
        self.max_concurrent_streams_peer = UInt32(100)
        self.next_client_stream_id = UInt32(1)
        self.flags = UInt8(0)
        self.goaway_last_stream_id = UInt32(0)
        self.goaway_error_code = UInt32(0)
        self.goaway_debug_data = List[UInt8]()
        self.keepalive_ping_data = SIMD[DType.uint8, 8](0)
        self.keepalive_ping_sent_ns = Int64(0)
        self.cont_reasm_stream_id = UInt32(0)
        self.cont_reasm_buf = List[UInt8]()
        self.cont_reasm_frames = 0
        self.max_response_body_bytes = H2_CLIENT_DEFAULT_MAX_RESPONSE_BODY
        self.recv_conn_pending_update = UInt32(0)
        self.pending_body_stream_ids = List[UInt32]()
        self.pending_body_buffers = List[List[UInt8]]()
        self.pending_body_cursors = List[Int]()
        self.free_header_slots = List[Int]()
        self.free_body_slots = List[Int]()
        self.response_trailer_lists = List[List[HpackHeader]]()
        self.free_trailer_slots = List[Int]()

    # ----- Flag accessors --------------------------------------------------

    def is_preface_sent(self) -> Bool:
        return (self.flags & H2C_FLAG_PREFACE_SENT) != UInt8(0)

    def mark_preface_sent(mut self):
        self.flags = self.flags | H2C_FLAG_PREFACE_SENT

    def is_settings_sent(self) -> Bool:
        return (self.flags & H2C_FLAG_SETTINGS_SENT) != UInt8(0)

    def mark_settings_sent(mut self):
        self.flags = self.flags | H2C_FLAG_SETTINGS_SENT

    def is_server_settings_seen(self) -> Bool:
        return (self.flags & H2C_FLAG_SERVER_SETTINGS_SEEN) != UInt8(0)

    def mark_server_settings_seen(mut self):
        self.flags = self.flags | H2C_FLAG_SERVER_SETTINGS_SEEN

    def is_goaway_received(self) -> Bool:
        return (self.flags & H2C_FLAG_GOAWAY_RECEIVED) != UInt8(0)

    def mark_goaway_received(
        mut self, last_stream_id: UInt32, error_code: UInt32,
    ):
        """Record a GOAWAY that carried no Additional Debug Data."""
        var no_debug = List[UInt8]()
        self.mark_goaway_received_with_debug(
            last_stream_id, error_code, no_debug^,
        )

    def mark_goaway_received_with_debug(
        mut self,
        last_stream_id: UInt32,
        error_code: UInt32,
        var debug_data: List[UInt8],
    ):
        """Record a peer GOAWAY. ★ `last_stream_id` MAY ONLY EVER SHRINK.

        RFC 9113 §6.8: "Endpoints MUST NOT increase the value they send in the
        last stream identifier, since the peers might already have retried
        unprocessed requests on another connection."

        That is stated as a constraint on the SENDER. A method that simply believed
        whatever the last GOAWAY said would let a peer that sent
        GOAWAY(last=1) and then GOAWAY(last=9) RETROACTIVELY convert
        stream 5 from "definitively not processed, safe to re-issue on a fresh
        connection even for a non-idempotent verb" (RFC 9113 §8.7) into "may
        have been processed" — the one direction that can turn a correct retry
        this client has ALREADY PERFORMED into a duplicate execution. A receiver
        cannot un-send that retry, so it must not accept the widening: we clamp
        to the minimum, which is the only value that keeps the not-processed set
        monotone. (hyper `recv_goaway_with_higher_last_processed_id`.)

        The LEGAL second GOAWAY — the two-frame graceful shutdown every major
        server uses, GOAWAY(2^31-1, NO_ERROR) to announce draining and then a
        final GOAWAY naming the real last processed stream — is a DECREASE, and
        it wins, which is the whole point of the clamp being a minimum rather
        than a refusal to update at all.

        The ERROR CODE and the DEBUG DATA come from the LATEST frame, because
        that is the "circumstances change" case §6.8 describes: a graceful
        NO_ERROR drain that is subsequently escalated to a real error is telling
        us something newer and more specific. ⚠ An EMPTY debug payload does not
        erase an explanation we already have — dropping a diagnostic because a
        later frame carried none is a pure loss, and the final GOAWAY of a
        graceful shutdown routinely carries none.
        """
        var already = self.is_goaway_received()
        self.flags = self.flags | H2C_FLAG_GOAWAY_RECEIVED
        if not already or last_stream_id < self.goaway_last_stream_id:
            self.goaway_last_stream_id = last_stream_id
        self.goaway_error_code = error_code
        if len(debug_data) > 0:
            swap(self.goaway_debug_data, debug_data)

    def goaway_debug_data_text(self) -> String:
        """The GOAWAY Additional Debug Data rendered for an error message.

        RFC 9113 §6.8 makes the payload OPAQUE — "Endpoints MUST NOT assume any
        semantics" — and it arrives from a peer, so it is rendered defensively:
        the rendering is truncated, and only an ALLOWLISTED alphabet survives
        (`_h2_debug_byte_is_renderable`). Every other byte — non-printable AND
        printable-but-excluded alike — becomes `.`. An error string is read by
        a human and shipped to a log aggregator; a raw peer-controlled byte run
        in it is a control-character injection into both.

        ⛔⛔ AND THE ALLOWLIST IS A RETRY-SAFETY CONTROL, NOT TYPOGRAPHY —
        RE-ADMITTING ONE CHARACTER CAN GET A NON-IDEMPOTENT REQUEST EXECUTED
        TWICE. This text is interpolated into the driver's GOAWAY raise by
        `h2_goaway_context`, and the faults this repo re-dials on are
        classified by SUBSTRING MATCH ON THE MESSAGE: `is_h2_goaway_unprocessed`
        keys on `H2_GOAWAY_UNPROCESSED_TOKEN`, `is_h2_retryable_transport` on
        `H2_RETRYABLE_TRANSPORT_TOKEN`, and `komira_grpc.client` re-issues the
        request on either — for ANY verb, idempotent or not.

        The proof those predicates rest on is stated in
        `is_h2_goaway_unprocessed`'s own docstring: "a message can only carry
        the token by having made the comparison." Rendering peer bytes verbatim
        FALSIFIES exactly that. A server that answers
        GOAWAY(last_stream_id = our stream) — the AT-OR-BELOW class, whose raise
        says in so many words that the request "MUST NOT be auto-retried" — and
        puts the 21 printable-ASCII bytes `h2-goaway-unprocessed` in its debug
        data would have had that request re-issued on a fresh connection.

        So the allowlist excludes every character those tokens are spelled with
        beyond letters and digits: `-` (both goaway tokens) and `[` `]` (every
        `HttpError[...]` class token). It also excludes `'` `;` `=`, this
        context's own field punctuation, so a peer cannot close our quote and
        forge a second structured field. What survives is letters, digits,
        space and `._:/,` — "max_age", "too_many_streams",
        "server_shutting_down: max_connection_age", a request id. A hyphen
        inside a UUID renders as `.`; that is the stated price of the control.

        Falsifier: `test_peer_debug_data_cannot_forge_a_retry_classifier_token`
        in `test_L2_h2_goaway_ping_liveness.mojo`."""
        var out = String()
        var n = len(self.goaway_debug_data)
        var cap = n
        if cap > _H2_GOAWAY_DEBUG_RENDER_MAX:
            cap = _H2_GOAWAY_DEBUG_RENDER_MAX
        var i = 0
        while i < cap:
            var b = Int(self.goaway_debug_data[i])
            if _h2_debug_byte_is_renderable(b):
                out += chr(b)
            else:
                out += String(".")
            i = i + 1
        if n > cap:
            out += String("...(") + String(n) + String(" bytes)")
        return out^

    # ----- Keepalive PING (liveness probe) ---------------------------------

    def is_keepalive_ping_outstanding(self) -> Bool:
        return (
            self.flags & H2C_FLAG_KEEPALIVE_PING_OUTSTANDING
        ) != UInt8(0)

    def stage_keepalive_ping(mut self, data: SIMD[DType.uint8, 8], now_ns: Int64):
        """Queue a client-originated PING (no ACK flag) and start its deadline.

        No-op if one is already outstanding: a client that keeps stacking
        unanswered probes onto a dead connection is generating the flood it is
        trying to detect, and RFC 9113 §6.7 gives the ACK no way to say which of
        several identical probes it answers beyond the opaque data itself."""
        if self.is_keepalive_ping_outstanding():
            return
        var out = List[UInt8]()
        encode_ping_frame(data, False, out)
        self.append_out_bytes(out^)
        self.keepalive_ping_data = data
        self.keepalive_ping_sent_ns = now_ns
        self.flags = self.flags | H2C_FLAG_KEEPALIVE_PING_OUTSTANDING

    def clear_keepalive_ping(mut self):
        """Drop any outstanding probe WITHOUT treating it as answered.

        ⛔ CALLED AT THE START OF EVERY DRIVE, AND THE MECHANISM IS BROKEN
        WITHOUT IT. The probe's deadline is only meaningful INSIDE the drive
        that armed it, but the flag lives on the CONNECTION — so a drive that
        returns normally with a probe still in flight (the peer answered the
        REQUEST on the same trip its PING ACK was still on the wire; the drive
        sees `all_done` and stops reading) hands the pool a connection carrying
        a live deadline and an old timestamp. That connection then sits idle in
        the pool for minutes, and the NEXT request's very first trip computes an
        elapsed far past the ping timeout and declares a perfectly healthy
        connection dead before sending anything.

        `firestore_listen_client` is the worked example: it re-drives ONE
        long-lived watch stream that is idle by design, so it would have hit
        this on essentially every call. Dropping the probe costs nothing — if
        the peer really is dead, the new drive re-arms within its own read-idle
        budget and reaches the same verdict on its own evidence."""
        self.flags = self.flags & ~H2C_FLAG_KEEPALIVE_PING_OUTSTANDING

    def note_ping_ack(mut self, data: SIMD[DType.uint8, 8]):
        """Clear the outstanding probe iff `data` echoes ITS opaque bytes.

        RFC 9113 §6.7 requires an ACK to carry "an identical opaque data
        payload", and that identity is the ONLY thing that binds an ACK to the
        probe that produced it. Clearing on any inbound ACK would let an
        unsolicited or stale ACK — one answering a probe from a previous drive,
        or a peer echoing garbage — certify a connection nobody proved alive."""
        if not self.is_keepalive_ping_outstanding():
            return
        var i = 0
        while i < 8:
            if data[i] != self.keepalive_ping_data[i]:
                return
            i = i + 1
        self.flags = self.flags & ~H2C_FLAG_KEEPALIVE_PING_OUTSTANDING

    # ----- Recv/send buffer helpers ----------------------------------------

    def append_recv_bytes(mut self, bytes_view: Span[UInt8, _]):
        """Append freshly-read bytes from the stream's try_read into the
        recv accumulator. Subsequent decode_frame calls consume the front."""
        var n = len(bytes_view)
        var i = 0
        while i < n:
            self.recv_buf.append(bytes_view[i])
            i = i + 1

    def consume_recv_bytes(mut self, n: Int):
        """Pop the first `n` bytes off the recv buffer."""
        if n <= 0:
            return
        var sz = len(self.recv_buf)
        if n >= sz:
            self.recv_buf = List[UInt8]()
            return
        var new_buf = List[UInt8]()
        var i = n
        while i < sz:
            new_buf.append(self.recv_buf[i])
            i = i + 1
        swap(self.recv_buf, new_buf)

    def append_out_bytes(mut self, var bytes: List[UInt8]):
        """Stage encoded frame bytes into the outbound queue."""
        var n = len(bytes)
        var i = 0
        while i < n:
            self.pending_out.append(bytes[i])
            i = i + 1

    def take_out_bytes(mut self) -> List[UInt8]:
        """Move-out the outbound staging buffer."""
        var out = List[UInt8]()
        swap(out, self.pending_out)
        return out^

    def consume_out_bytes_prefix(mut self, n: Int):
        """Drop the first `n` bytes from `pending_out`. Used by the
        production driver after a partial `stream.try_write` acceptance —
        bytes that the kernel/peer has taken should be removed from the
        outbound staging buffer, but any remaining tail must stay queued
        for the next write attempt."""
        if n <= 0:
            return
        var sz = len(self.pending_out)
        if n >= sz:
            self.pending_out = List[UInt8]()
            return
        var new_buf = List[UInt8]()
        var i = n
        while i < sz:
            new_buf.append(self.pending_out[i])
            i = i + 1
        swap(self.pending_out, new_buf)

    # ----- Stream allocation + lookup --------------------------------------

    def allocate_client_stream_id(mut self) -> UInt32:
        """Allocate the NEXT client-initiated stream id (odd, monotonically
        increasing). Bumps `next_client_stream_id` by 2.

        ★ RETURNS `H2_STREAM_ID_EXHAUSTED` (0) ONCE THE SPACE IS SPENT, AND
        THAT REFUSAL IS THE POINT. RFC 9113 §5.1.1: "Stream identifiers
        cannot be reused. ... A client that is unable to establish a new
        stream identifier can establish a new connection for new streams."
        The identifier is 31 bits, so `H2_LAST_CLIENT_STREAM_ID`
        (2147483647) is the last legal one.

        An unguarded `next + 2` does NOT fail loudly past that point -- it
        hands back 2147483649, whose reserved high bit is set, and
        `encode_frame_header` masks the id with 0x7fffffff on the way out.
        The request therefore goes on the wire as stream 1: a LIVE, DIFFERENT
        request on this same long-lived pooled connection. Two requests share
        one identifier, each sees the other's frames, and nothing anywhere
        reports an error. The sentinel is chosen as 0 precisely because 0 is
        not a legal stream id in either direction, so a caller that forgets
        to check still fails loudly instead of crossing two requests over.
        """
        var sid = self.next_client_stream_id
        if sid == H2_STREAM_ID_EXHAUSTED or sid > H2_LAST_CLIENT_STREAM_ID:
            return H2_STREAM_ID_EXHAUSTED
        if sid > H2_LAST_CLIENT_STREAM_ID - UInt32(2):
            # Saturate into the exhausted state rather than WRAPPING past the
            # 31-bit space -- the wrap is the defect above.
            self.next_client_stream_id = H2_STREAM_ID_EXHAUSTED
        else:
            self.next_client_stream_id = sid + UInt32(2)
        return sid

    def is_stream_id_space_exhausted(self) -> Bool:
        """True once `allocate_client_stream_id` can only refuse. The caller's
        remedy is RFC 9113 §5.1.1's: open a NEW connection."""
        return self.next_client_stream_id == H2_STREAM_ID_EXHAUSTED

    def find_stream_idx(self, stream_id: UInt32) -> Int:
        """Linear-scan lookup. Returns -1 if not present."""
        var n = len(self.streams)
        var i = 0
        while i < n:
            if self.streams[i].stream_id == stream_id:
                return i
            i = i + 1
        return -1

    def create_stream(
        mut self, stream_id: UInt32,
    ) -> Int:
        """Create a new H2ClientStream for `stream_id`, allocate its
        response-header-list + response-body-buffer slots, transition to
        OPEN. Returns the streams[] index of the new entry.

        Caller is responsible for ensuring the stream_id is odd + > any
        previous client-initiated id (i.e. produced by
        allocate_client_stream_id)."""
        var initial_send = Int32(Int(self.send_fc.initial_window_size))
        var initial_recv = Int32(Int(self.recv_fc.initial_recv_window))
        var ss = H2ClientStream.new(
            stream_id=stream_id, initial_window=initial_send,
        )
        ss.recv_window = initial_recv
        ss.state = STREAM_STATE_OPEN  # client sending HEADERS implies OPEN
        # Allocate the response-header list slot — RECYCLE a retired slot if one
        # is free, else append. A recycled slot was swapped
        # to an empty List on retire, so it is ready to reuse.
        if len(self.free_header_slots) > 0:
            var hslot = self.free_header_slots.pop()
            ss.response_header_idx = hslot
        else:
            ss.response_header_idx = len(self.response_header_lists)
            self.response_header_lists.append(List[HpackHeader]())
        # Allocate the response-body buffer slot — same recycle-or-append policy.
        if len(self.free_body_slots) > 0:
            var bslot = self.free_body_slots.pop()
            ss.response_body_idx = bslot
        else:
            ss.response_body_idx = len(self.response_body_buffers)
            self.response_body_buffers.append(List[UInt8]())
        self.streams.append(ss)
        return len(self.streams) - 1

    def open_streams_count(self) -> UInt32:
        """Number of streams not yet in STREAM_STATE_CLOSED. Used by the
        pool's Go-#34944 stream-cap check."""
        var n = len(self.streams)
        var count = UInt32(0)
        var i = 0
        while i < n:
            if self.streams[i].state != STREAM_STATE_CLOSED:
                count = count + UInt32(1)
            i = i + 1
        return count

    def retire_stream(mut self, stream_id: UInt32):
        """Retire a COMPLETED stream's
        per-connection state so a long-lived REUSED h2 connection does not
        accumulate O(N) closed-stream state (the `GcpWebFrontend._publish`
        ~1867-`rewrite_object` web-publish wedge).

        Caller invariant: `stream_id` has reached END_STREAM on the RESPONSE
        (`end_stream_seen == True`) and the caller has already extracted the
        response (`extract_response_for_stream`). Idempotent + safe if the
        stream is absent (already retired) — a no-op.

        Two things happen:
          1. The heap-owning response-header + response-body Lists this stream
             referenced are FREED (swapped to empty Lists) and their slot
             indices pushed onto the free-lists for `create_stream` to recycle —
             so `response_header_lists` / `response_body_buffers` stay BOUNDED
             (their length never exceeds the peak concurrent stream count, not
             the lifetime request count).
          2. The POD `H2ClientStream` entry is removed from `streams`
             (swap-remove) so `find_stream_idx` scans only LIVE streams, not the
             full request history — restoring O(active) lookup, not O(N).

        Plus the connection SEND-window heal: the bytes this stream charged
        against `send_fc.conn_send_window` are credited BACK (the peer received
        the whole request body — proven by the RESPONSE END_STREAM — so the
        connection send window can be safely restored locally without waiting on
        a server WINDOW_UPDATE(0) that a server is not obligated to send for
        small bodies). This keeps `conn_send_window` positive across an
        arbitrarily long sequence of sequential requests.
        """
        var idx = self.find_stream_idx(stream_id)
        if idx < 0:
            return

        # ---- 1. Free + recycle the heap-owning response slots. ----
        var hslot = self.streams[idx].response_header_idx
        if hslot >= 0 and hslot < len(self.response_header_lists):
            var empty_h = List[HpackHeader]()
            swap(self.response_header_lists[hslot], empty_h)
            self.free_header_slots.append(hslot)
        var bslot = self.streams[idx].response_body_idx
        if bslot >= 0 and bslot < len(self.response_body_buffers):
            var empty_b = List[UInt8]()
            swap(self.response_body_buffers[bslot], empty_b)
            self.free_body_slots.append(bslot)
        # The trailer slot is allocated lazily, so most streams never hold one;
        # when they do it is freed and recycled on exactly the same terms.
        var tslot = self.streams[idx].response_trailer_idx
        if tslot >= 0 and tslot < len(self.response_trailer_lists):
            var empty_t = List[HpackHeader]()
            swap(self.response_trailer_lists[tslot], empty_t)
            self.free_trailer_slots.append(tslot)

        # ---- 2. Heal the connection send window by this stream's charge. ----
        var charged = self.streams[idx].send_body_charged
        if charged > UInt32(0):
            var restored = Int64(Int(self.send_fc.conn_send_window)) + Int64(
                Int(charged)
            )
            # Clamp at the RFC 2^31-1 ceiling (never grow past a legal window).
            var ceiling = Int64(0x7fffffff)
            if restored > ceiling:
                restored = ceiling
            self.send_fc.conn_send_window = Int32(Int(restored))

        # ---- 3. Swap-remove the POD stream entry (keeps `streams` bounded). ----
        var last = len(self.streams) - 1
        if idx != last:
            self.streams[idx] = self.streams[last]
        _ = self.streams.pop()


# =============================================================================
# §4 — Initial SETTINGS frame builder (client-side).
# =============================================================================


def build_initial_client_settings(
    h2: H2ClientConnectionState,
) -> List[UInt8]:
    """Build the client's INITIAL non-ACK SETTINGS frame.

    Sent IMMEDIATELY after the 24-byte preface per RFC 9113 §3.4 (the
    preface is the magic + a SETTINGS frame). Carries the client's
    SETTINGS_* parameters; the server applies them to its outbound
    flow-control / encoder state.

    Defaults:
      * SETTINGS_HEADER_TABLE_SIZE = 4096
      * SETTINGS_INITIAL_WINDOW_SIZE = 65535 (per RFC default)
      * SETTINGS_MAX_FRAME_SIZE = 16384 (per RFC default)
      * SETTINGS_MAX_CONCURRENT_STREAMS = 100
      * SETTINGS_MAX_HEADER_LIST_SIZE = 8192

    declines SETTINGS_ENABLE_PUSH (servers don't push for our
    server; sending the default = 1 is fine, sending 0 explicitly disables
    PUSH_PROMISE — we send 0 defensively).
    """
    var entries = List[SettingsEntry]()
    entries.append(SettingsEntry(
        identifier=SETTINGS_HEADER_TABLE_SIZE,
        value=UInt32(4096),
    ))
    entries.append(SettingsEntry(
        identifier=SETTINGS_MAX_CONCURRENT_STREAMS,
        value=UInt32(100),
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
# §5 — Preface + initial SETTINGS emit helper.
# =============================================================================


def queue_client_preface_and_settings(mut h2: H2ClientConnectionState):
    """Stage the 24-byte client preface + the initial SETTINGS frame in
    `pending_out`. Idempotent: returns immediately if PREFACE_SENT is
    already set.

    Per RFC 9113 §3.4: "The client connection preface starts with a
    sequence of 24 octets [...] followed by a SETTINGS frame which MAY
    be empty." We emit a NON-empty initial SETTINGS as per modern
    convention (browsers, nghttp2, Go's net/http2).
    """
    if h2.is_preface_sent():
        return
    # Emit the 24-byte magic.
    var preface = H2_CLIENT_PREFACE()
    var preface_n = len(preface)
    var i = 0
    while i < preface_n:
        h2.pending_out.append(preface[i])
        i = i + 1
    h2.mark_preface_sent()
    # Emit the initial SETTINGS frame.
    var settings = build_initial_client_settings(h2)
    h2.append_out_bytes(settings^)
    h2.mark_settings_sent()


# =============================================================================
# §6 — SETTINGS-ack on receiving server's non-ACK SETTINGS.
# =============================================================================


def apply_peer_settings_and_ack(
    mut h2: H2ClientConnectionState,
    var settings: List[SettingsEntry],
) -> Bool:
    """Apply each entry of the server's non-ACK SETTINGS to our send-side
    state, then queue a SETTINGS-ACK frame.

    Returns True on success; False on a SETTINGS protocol error (the
    caller emits GOAWAY + closes).

    Per RFC 9113 §6.5.2:
      * SETTINGS_INITIAL_WINDOW_SIZE > 2^31-1: FLOW_CONTROL_ERROR
        (handled by SendFlowController.on_settings_initial_window_delta
        — caller checks the delta value for invalid magnitudes).
      * SETTINGS_MAX_FRAME_SIZE outside [16384, 16777215]: PROTOCOL_ERROR.
      * SETTINGS_ENABLE_PUSH != 0 or 1: PROTOCOL_ERROR.
    """
    var n = len(settings)
    var i = 0
    while i < n:
        var e = settings[i]
        if e.identifier == SETTINGS_INITIAL_WINDOW_SIZE:
            if e.value > UInt32(0x7fffffff):
                return False
            var delta = h2.send_fc.on_settings_initial_window_delta(e.value)
            # Apply delta to every live stream's send_window.
            var sn = len(h2.streams)
            var si = 0
            while si < sn:
                h2.streams[si].send_window = (
                    h2.streams[si].send_window + delta
                )
                si = si + 1
        elif e.identifier == SETTINGS_MAX_FRAME_SIZE:
            var v = Int(e.value)
            if v < 16384 or v > 16777215:
                return False
            h2.max_frame_size_peer = v
        elif e.identifier == SETTINGS_HEADER_TABLE_SIZE:
            # — hand off to the HPACK encoder's two-field pipeline.
            h2.hpack_encoder.on_settings_ack_table_size(e.value)
        elif e.identifier == SETTINGS_MAX_CONCURRENT_STREAMS:
            h2.max_concurrent_streams_peer = e.value
        elif e.identifier == SETTINGS_ENABLE_PUSH:
            # RFC 9113 §6.5.2: "The initial value of SETTINGS_ENABLE_PUSH is 1.
            # ... Any value other than 0 or 1 MUST be treated as a connection
            # error (Section 5.4.1) of type PROTOCOL_ERROR."
            #
            # ⚠ THE DOCSTRING ABOVE PROMISED THIS CHECK SINCE THE FUNCTION WAS
            # WRITTEN AND THE LADDER DID NOT PERFORM IT: the
            # identifier fell through to the "advisory" comment and 2 /
            # 0xFFFFFFFF were accepted AND ACKed. A stated check the body does
            # not do is worse than no check — it is what a reader trusts
            # instead of reading the ladder.
            #
            # There is nothing to STORE. This client never accepts push
            # (PUSH_PROMISE is answered with GOAWAY(PROTOCOL_ERROR) further
            # down), so the value is validated and discarded; §6.5.2 makes the
            # validation itself the obligation.
            if e.value > UInt32(1):
                return False
        # SETTINGS_MAX_HEADER_LIST_SIZE advisory.
        i = i + 1
    h2.mark_server_settings_seen()
    # Queue SETTINGS-ACK.
    var ack = List[UInt8]()
    encode_settings_ack_frame(ack)
    h2.append_out_bytes(ack^)
    return True


# =============================================================================
# §7 — GOAWAY emission helper (client-side).
# =============================================================================


def emit_goaway_for_client(
    mut h2: H2ClientConnectionState, error_code: UInt32,
):
    """Encode a GOAWAY frame indicating the client is closing the
    connection. `last_stream_id` here is the highest server-initiated
    stream we've processed; for the client side that means even-numbered
    pushed streams.

    client emits GOAWAY when the SERVER violates protocol — defensive
    shutdown — even though most h2 stacks let the client just close the
    TCP. Symmetric to the server-side `_emit_goaway` in serve_h2.mojo.
    """
    var debug = List[UInt8]()
    var out = List[UInt8]()
    encode_goaway_frame(UInt32(0), error_code, debug^, out)
    h2.append_out_bytes(out^)


def emit_rst_stream_for_client(
    mut h2: H2ClientConnectionState, stream_id: UInt32, error_code: UInt32,
):
    """Stage RST_STREAM on `stream_id` — the stream-scoped refusal used when
    ONE response misbehaves (e.g. an over-ceiling body) and the connection
    itself is still usable."""
    var out = List[UInt8]()
    encode_rst_stream_frame(stream_id, error_code, out)
    h2.append_out_bytes(out^)


def _append_client_header_block(
    mut h2: H2ClientConnectionState, payload: Span[UInt8, _]
) -> Bool:
    """Append one HEADERS/CONTINUATION payload to the client-side reassembly
    buffer, enforcing the §1b ceilings shared with the server. Returns False
    if a ceiling was exceeded; the buffer is left untouched on refusal."""
    h2.cont_reasm_frames = h2.cont_reasm_frames + 1
    if h2.cont_reasm_frames > H2_MAX_HEADER_BLOCK_FRAMES:
        return False
    if len(h2.cont_reasm_buf) + len(payload) > H2_MAX_HEADER_BLOCK_BYTES:
        return False
    h2.cont_reasm_buf.extend(payload)
    return True


def _reset_client_header_block(mut h2: H2ClientConnectionState):
    """Drop the reassembly buffer + its frame counter."""
    h2.cont_reasm_stream_id = UInt32(0)
    h2.cont_reasm_buf = List[UInt8]()
    h2.cont_reasm_frames = 0


# =============================================================================
# §8 — Request encoding (HEADERS + DATA emission with continuation split).
# =============================================================================


def encode_request_headers_to_frames(
    mut h2: H2ClientConnectionState,
    stream_id: UInt32,
    var pseudo_method: String,
    var pseudo_scheme: String,
    var pseudo_authority: String,
    var pseudo_path: String,
    var headers: HeaderMap,
    end_stream: Bool,
):
    """Encode an outbound request's HEADERS block via HpackEncoder, split
    across HEADERS+CONTINUATION* frames per RFC 9113 §6.10, stage in
    `h2.pending_out`. Caller has already allocated the stream via
    `allocate_client_stream_id` + `create_stream`.

    `pseudo_*` are the four HTTP/2 pseudo-headers (RFC 9113 §8.1.2.3):
      * :method      — GET / POST / PUT / etc.
      * :scheme      — http / https.
      * :authority   — host[:port]; replaces h1 Host header.
      * :path        — request-target (path + ?query).

    `headers` carries regular (non-pseudo) headers. Caller-supplied Host
    header is ignored in h2 (:authority is the equivalent); Connection,
    Proxy-Connection, Keep-Alive, Transfer-Encoding, Upgrade headers MUST
    be omitted per RFC 9113 §8.1.2.2.

    `end_stream` — set if there's no request body to follow (e.g. GET).

    Encapsulation: no UnsafePointer / wildcard. All buffers are
    owned-Movable.
    """
    # RFC 9110 §6.4.1: a response to HEAD "is defined as having no content",
    # so its non-zero content-length is NOT compared against the (zero) DATA
    # frames it frames. Record the verb HERE — at the only place the client
    # knows it — because the inbound path that performs that comparison
    # (`_check_content_length_at_end`) sees frames, not requests. WITHOUT this
    # every HEAD response becomes an RFC 9113 §8.1.1 stream error.
    var method_is_head = pseudo_method == String("HEAD")
    var method_idx = h2.find_stream_idx(stream_id)
    if method_idx >= 0:
        h2.streams[method_idx].request_method_is_head = method_is_head

    var hdrs_block = List[HpackHeader]()
    # Pseudo-headers MUST appear before regular headers per RFC 9113 §8.1.2.1.
    hdrs_block.append(HpackHeader(String(":method"), pseudo_method^))
    hdrs_block.append(HpackHeader(String(":scheme"), pseudo_scheme^))
    hdrs_block.append(HpackHeader(String(":authority"), pseudo_authority^))
    hdrs_block.append(HpackHeader(String(":path"), pseudo_path^))

    # Regular headers — skip h1-only / connection-specific.
    #
    # Option C migration: walk via `entry_at_view(i)` +
    # byte-direct `ci_byte_eq_sab_static` skip-list compare. We only
    # materialize Strings on the keep-path (when the header is NOT
    # filtered), saving one name-String + one value-String materialization
    # per filtered header (six potential skips per request).
    var n_entries = headers.len()
    var i = 0
    while i < n_entries:
        var entry_view = headers.entry_at_view(i)
        # RFC 9113 §8.1.2.2: forbid connection-specific headers.
        if (
            ci_byte_eq_sab_static(entry_view.name, "connection")
            or ci_byte_eq_sab_static(entry_view.name, "proxy-connection")
            or ci_byte_eq_sab_static(entry_view.name, "keep-alive")
            or ci_byte_eq_sab_static(entry_view.name, "transfer-encoding")
            or ci_byte_eq_sab_static(entry_view.name, "upgrade")
            or ci_byte_eq_sab_static(entry_view.name, "host")
        ):
            i = i + 1
            continue
        # Keep-path: materialize name (lowercased to match h2 canonical
        # form) + value as Strings — HpackHeader fields are String.
        var nm = sab_to_string_lower(entry_view.name)
        var vl = sab_to_string(entry_view.value)
        hdrs_block.append(HpackHeader(nm^, vl^))
        i = i + 1

    var block_bytes = h2.hpack_encoder.encode_block(hdrs_block^)
    var out = List[UInt8]()
    split_header_block_into_frames(
        stream_id,
        block_bytes^,
        h2.max_frame_size_peer,
        end_stream,
        out,
    )
    h2.append_out_bytes(out^)

    # If end_stream was set, advance the stream's state — we sent END_STREAM
    # on this stream so we transition OPEN → HALF_CLOSED_LOCAL.
    if end_stream:
        var idx = h2.find_stream_idx(stream_id)
        if idx >= 0:
            if h2.streams[idx].state == STREAM_STATE_OPEN:
                h2.streams[idx].state = STREAM_STATE_HALF_CLOSED_LOCAL


def encode_request_data_frame(
    mut h2: H2ClientConnectionState,
    stream_id: UInt32,
    var data: List[UInt8],
    end_stream: Bool,
):
    """Stage an outbound request body on `stream_id`, sent flow-control-aware.

    this no longer frames the whole
    body as ONE DATA frame. It registers the body as a pending send buffer
    (`stage_request_body`), then immediately pumps as many DATA-frame chunks as
    the CURRENT send window + SETTINGS_MAX_FRAME_SIZE allow into `pending_out`.
    Any body remaining after the window is exhausted stays queued; the driver
    (`drive_h2_streams_to_completion`) pumps the rest as the server reopens the
    window via WINDOW_UPDATE, until END_STREAM.

    `end_stream=True` (the only value callers pass for a buffered request body)
    means END_STREAM rides the FINAL body chunk; the stream flips
    OPEN → HALF_CLOSED_LOCAL only once the whole body has been framed.

    Correctness for arbitrarily large bodies (the fix): a body larger than the
    initial 65535-byte send window used to be staged as a single oversized DATA
    frame — violating both the peer's SETTINGS_MAX_FRAME_SIZE and the send
    window — after which the driver flushed only the first window's worth,
    `pending_out` drained, no further body was queued, END_STREAM was never
    observed, and the loop spun reads to the 100k iteration cap.
    """
    stage_request_body(h2, stream_id, data^, end_stream)
    pump_pending_request_bodies(h2)


def stage_request_body(
    mut h2: H2ClientConnectionState,
    stream_id: UInt32,
    var data: List[UInt8],
    end_stream: Bool,
):
    """Register an outbound request body for flow-controlled streaming.

    Appends a (stream_id, body, cursor=0) pending entry at connection level.
    `end_stream` is implicit: a buffered request body always carries END_STREAM
    on its final chunk (the only shape our callers use). An empty body is not
    staged — the caller sets END_STREAM on HEADERS in that case.
    """
    _ = end_stream  # END_STREAM is implicit on the final chunk of a body.
    if len(data) == 0:
        return
    h2.pending_body_stream_ids.append(stream_id)
    h2.pending_body_buffers.append(data^)
    h2.pending_body_cursors.append(0)


def has_pending_request_bodies(h2: H2ClientConnectionState) -> Bool:
    """True if any registered request body still has unsent bytes."""
    var n = len(h2.pending_body_stream_ids)
    var i = 0
    while i < n:
        if h2.pending_body_cursors[i] < len(h2.pending_body_buffers[i]):
            return True
        i = i + 1
    return False


def pump_pending_request_bodies(mut h2: H2ClientConnectionState):
    """Frame as much of every pending request body as the send windows +
    SETTINGS_MAX_FRAME_SIZE currently allow, staging DATA frames into
    `pending_out` and charging flow control.

    For each pending body, while there is remaining body AND positive
    per-stream + connection send window, emit a DATA frame of
    `min(stream_send_window, conn_send_window, max_frame_size_peer, remaining)`
    bytes. END_STREAM rides the frame that carries the LAST body byte; when a
    body is fully framed the stream flips OPEN → HALF_CLOSED_LOCAL and the entry
    is removed. A body whose window is currently 0 is left in place — the driver
    re-pumps after the next WINDOW_UPDATE reopens it. This is the forward-
    progress engine for arbitrarily large uploads under flow control.
    """
    var i = 0
    while i < len(h2.pending_body_stream_ids):
        var sid = h2.pending_body_stream_ids[i]
        var idx = h2.find_stream_idx(sid)
        if idx < 0:
            # Stream vanished (reset) — drop the pending body.
            _ = h2.pending_body_buffers.pop(i)
            _ = h2.pending_body_cursors.pop(i)
            _ = h2.pending_body_stream_ids.pop(i)
            continue

        var body_len = len(h2.pending_body_buffers[i])
        # Emit as many frames as the window currently permits.
        while h2.pending_body_cursors[i] < body_len:
            var remaining = body_len - h2.pending_body_cursors[i]
            # send_fc.can_send clamps to min(stream_window, conn_window,
            # requested) — the flow-control gate. Cap the request at the peer's
            # max frame size so a single DATA frame never exceeds it.
            var req = remaining
            if req > h2.max_frame_size_peer:
                req = h2.max_frame_size_peer
            var allowed = h2.send_fc.can_send(
                h2.streams[idx].send_window, req
            )
            if allowed <= 0:
                # Window exhausted for now — leave the rest queued; the driver
                # re-pumps after the server sends a WINDOW_UPDATE.
                break
            # Slice the next `allowed` bytes out of the body buffer.
            var chunk = List[UInt8]()
            var start = h2.pending_body_cursors[i]
            var k = 0
            while k < allowed:
                chunk.append(h2.pending_body_buffers[i][start + k])
                k = k + 1
            var is_last = (start + allowed) == body_len
            var frame = List[UInt8]()
            encode_data_frame(sid, chunk^, is_last, frame)
            h2.append_out_bytes(frame^)
            # Charge both send windows.
            h2.send_fc.consume(allowed, h2.streams[idx].send_window)
            # record the bytes charged against the
            # CONNECTION send window so `retire_stream` can credit them back once
            # the peer ACKs the request via RESPONSE END_STREAM.
            h2.streams[idx].send_body_charged = (
                h2.streams[idx].send_body_charged + UInt32(allowed)
            )
            h2.pending_body_cursors[i] = start + allowed
            if is_last:
                if h2.streams[idx].state == STREAM_STATE_OPEN:
                    h2.streams[idx].state = STREAM_STATE_HALF_CLOSED_LOCAL

        if h2.pending_body_cursors[i] >= body_len:
            # Fully sent — remove the entry (swap-free stable removal).
            _ = h2.pending_body_buffers.pop(i)
            _ = h2.pending_body_cursors.pop(i)
            _ = h2.pending_body_stream_ids.pop(i)
            continue
        i = i + 1


# =============================================================================
# §9 — Inbound frame dispatch (client-side).
# =============================================================================


def process_received_frames(
    mut h2: H2ClientConnectionState,
) raises -> UInt32:
    """Decode + dispatch as many frames as fit in `h2.recv_buf`. Returns
    the highest stream_id processed in this call (caller uses this to
    poll which streams advanced — useful when single-stream blocking).

    On peer protocol error: stages a GOAWAY in pending_out + returns 0.
    Raises on FRAME_SIZE_ERROR / FLOW_CONTROL_ERROR violations the client
    must surface to the caller.

    Side effects on h2:
      * SETTINGS (non-ACK): apply + stage ACK
      * SETTINGS (ACK): no-op
      * PING (non-ACK): echo with ACK
      * GOAWAY: mark_goaway_received + record last_stream_id + error
      * WINDOW_UPDATE: apply via SendFlowController
      * RST_STREAM: mark stream CLOSED
      * HEADERS / CONTINUATION: reassemble + decode into per-stream
        response_header_lists[idx]; set response_status from :status
      * DATA: append to per-stream response_body_buffers[idx]; charge
        recv flow control; on END_STREAM mark stream half-closed-remote
        / closed.
      * PUSH_PROMISE: stage GOAWAY(PROTOCOL_ERROR) — This version doesn't accept
        push (we sent SETTINGS_ENABLE_PUSH = ... actually we didn't
        explicitly disable; defensive PROTOCOL_ERROR per peer behavior).
    """
    var max_sid_processed = UInt32(0)
    while True:
        # RFC 9113 §6.10 latch — see `H2C_FLAG_HEADER_BLOCK_ABANDONED`. Once a
        # header block has been abandoned the connection's HPACK state is
        # unrecoverable, so nothing further on it is decodable. Drain rather
        # than accumulate: the driver loops on this function and a buffer that
        # only grows is the shape of a multi-minute stall.
        if (h2.flags & H2C_FLAG_HEADER_BLOCK_ABANDONED) != UInt8(0):
            h2.consume_recv_bytes(len(h2.recv_buf))
            return max_sid_processed
        if len(h2.recv_buf) == 0:
            return max_sid_processed
        var view = Span(h2.recv_buf)
        var res = decode_frame(view, h2.max_frame_size_local)
        if res.status == FRAME_DECODE_NEED_MORE:
            return max_sid_processed
        if res.status == FRAME_DECODE_ERROR:
            # ★ THE DECODER ALREADY ANSWERED "STREAM OR CONNECTION?" -- ASK IT.
            # `FrameDecodeResult` carries `is_connection_error` +
            # `error_stream_id`, computed per RFC 9113 on every error path.
            # Answering EVERY decode error with GOAWAY is a severity
            # inversion, and it bites hardest exactly where h2 earns its keep:
            # on a POOLED connection multiplexing N requests, one malformed
            # frame belonging to ONE stream tore down all N.
            #
            # RFC 9113 §5.4.2: a stream error is answered with RST_STREAM and
            # "the connection is not affected"; §5.4.1 reserves GOAWAY for a
            # fault that leaves the connection itself unusable.
            var scoped_sid = res.error_stream_id
            var err_code = res.error_code
            var skip = res.consumed
            if (
                res.is_connection_error
                or scoped_sid == UInt32(0)
                or skip <= 0
            ):
                # `skip <= 0` joins the connection arm on purpose: without a
                # frame length we cannot find the next frame boundary, so the
                # connection is unusable whatever the decoder called it.
                emit_goaway_for_client(h2, err_code)
                return max_sid_processed
            h2.consume_recv_bytes(skip)
            emit_rst_stream_for_client(h2, scoped_sid, err_code)
            var bad_idx = h2.find_stream_idx(scoped_sid)
            if bad_idx >= 0:
                # We have just refused this stream, so it is closed and its
                # response will never arrive. Record the code the way an
                # INBOUND RST_STREAM is recorded (see the FRAME_RST_STREAM arm
                # below) so `drive_h2_streams_to_completion` RAISES for this
                # one request instead of waiting out the wall deadline for a
                # response we ourselves cancelled.
                h2.streams[bad_idx].state = STREAM_STATE_CLOSED
                if h2.streams[bad_idx].reset_error_code < Int64(0):
                    h2.streams[bad_idx].reset_error_code = Int64(
                        Int(err_code)
                    )
            if scoped_sid > max_sid_processed:
                max_sid_processed = scoped_sid
            continue
        var consumed = res.consumed
        h2.consume_recv_bytes(consumed)
        var frame = Frame()
        swap(frame, res.frame)

        var kind = frame.header.kind
        var sid = frame.header.stream_id
        if sid > max_sid_processed:
            max_sid_processed = sid

        # ─── RFC 9113 §6.10 — A HEADER BLOCK IS THE ONE PLACE THE FRAME
        # SEQUENCE IS NOT FREE-FORM, AND THIS IS WHERE THAT IS ENFORCED. ───
        #
        #   "A HEADERS frame without the END_HEADERS flag set MUST be followed
        #    by a CONTINUATION frame for the same stream. A receiver MUST treat
        #    the receipt of any other type of frame or a frame on a different
        #    stream as a connection error (Section 5.4.1) of type
        #    PROTOCOL_ERROR."
        #
        # ⛔ THIS CHECK MUST STAY AT THE TOP OF THE DISPATCH LOOP, ABOVE EVERY
        # `if kind == ...` ARM. The guard this codebase HAD lived inside
        # `_handle_inbound_headers_or_cont`, which is only ever reached for
        # HEADERS and CONTINUATION — so all EIGHT of the other arms (SETTINGS,
        # PING, GOAWAY, PRIORITY, WINDOW_UPDATE, RST_STREAM, DATA and the
        # unknown-type fallthrough) ran to completion against a half-decoded
        # header block, and the trailing CONTINUATION then completed it and the
        # response was DELIVERED as if nothing had happened. That is a SILENT
        # desync, not a loud one: HPACK's dynamic table is per-connection and
        # strictly ordered, so every later request on the connection decodes
        # against a table the peer does not have.
        #
        # It is a CONNECTION error, not a stream error, for exactly that reason
        # — there is no recovery short of tearing the connection down.
        #
        # ⚠ `FRAME_CONTINUATION` is the ONLY exemption, and it is not a blanket
        # one: `_handle_inbound_headers_or_cont` still rejects a CONTINUATION
        # that names a DIFFERENT stream than the block in flight (the "or a
        # frame on a different stream" half of the same sentence).
        #
        # ⚠ AND THE EXEMPTION IS NOT "IGNORE, PER §4.1". §4.1 says an UNKNOWN
        # frame type MUST be ignored, and §5.5 states the exception explicitly:
        # "Extension frames ... MUST NOT be sent in the middle of a header
        # block." So the unknown-type fallthrough at the bottom of this loop is
        # correct OUTSIDE a block and wrong INSIDE one — which is why the test
        # for that case (A7) sits next to the positive control (D2) that pins
        # the ignore behaviour outside a block. Do not "simplify" this by
        # making the client strict about extension frames generally; that is a
        # self-inflicted outage against any server that ships one.
        #
        # Covered by `test_L2_h2_continuation_interleaving.mojo` groups A (the
        # eight interleaved types), B (CONTINUATION identity) and D (the
        # positive controls that must stay green through this check).
        if h2.cont_reasm_stream_id != UInt32(0) and (
            kind != FRAME_CONTINUATION
        ):
            emit_goaway_for_client(h2, H2_ERR_PROTOCOL_ERROR)
            # ⛔ LATCH, DO NOT `_reset_client_header_block`. Clearing the slot
            # would work for the replay hazard, but it also erases WHICH stream
            # was abandoned — and `cont_reasm_stream_id` going to 0 is
            # indistinguishable from the slot having been released normally.
            # The latch is strictly stronger (it refuses the replay AND every
            # later frame) and it leaves the abandoned stream id readable.
            h2.flags = h2.flags | H2C_FLAG_HEADER_BLOCK_ABANDONED
            h2.consume_recv_bytes(len(h2.recv_buf))
            return max_sid_processed

        if kind == FRAME_SETTINGS:
            if (frame.header.flags & FLAG_ACK) != UInt8(0):
                continue
            var apply_settings = List[SettingsEntry]()
            swap(apply_settings, frame.settings)
            var ok = apply_peer_settings_and_ack(h2, apply_settings^)
            if not ok:
                emit_goaway_for_client(h2, H2_ERR_PROTOCOL_ERROR)
                return max_sid_processed
            continue

        if kind == FRAME_PING:
            if (frame.header.flags & FLAG_ACK) != UInt8(0):
                # An ACK is never answered (RFC 9113 §6.7) — two peers doing
                # that build a PING storm that never terminates. It IS the
                # answer to our own liveness probe, though, and this is the one
                # place that can bind the two: `note_ping_ack` clears the
                # outstanding probe only if these 8 opaque bytes echo it.
                h2.note_ping_ack(frame.ping_data)
                continue
            # Echo with ACK flag.
            var pong = List[UInt8]()
            encode_ping_frame(frame.ping_data, True, pong)
            h2.append_out_bytes(pong^)
            continue

        if kind == FRAME_GOAWAY:
            # RFC 9113 §6.8 Additional Debug Data: `decode_frame` put the bytes
            # after the 8-byte fixed part into `frame.payload`, and they used to
            # die here with the `Frame`. They are the server's own explanation
            # for the teardown, so they are moved onto the connection state and
            # rendered into the driver's raise.
            var goaway_debug = List[UInt8]()
            swap(goaway_debug, frame.payload)
            h2.mark_goaway_received_with_debug(
                frame.goaway_last_stream_id,
                frame.goaway_error_code,
                goaway_debug^,
            )
            # Per RFC 9113 §6.8: streams with id > last_stream_id are
            # rejected; in-flight streams with id <= last_stream_id are
            # still processed. Caller's send_request_on_h2_conn loop
            # checks is_goaway_received on each iteration.
            continue

        if kind == FRAME_PRIORITY:
            # Deprecated; ignore.
            continue

        if kind == FRAME_WINDOW_UPDATE:
            if sid == UInt32(0):
                var dummy = Int32(0)
                var fr = h2.send_fc.on_window_update(
                    UInt32(0), frame.window_update_increment, dummy,
                )
                if fr.kind != FLOW_RESULT_OK:
                    emit_goaway_for_client(h2, fr.error_code)
                    return max_sid_processed
            else:
                var idx = h2.find_stream_idx(sid)
                if idx >= 0:
                    var fr = h2.send_fc.on_window_update(
                        sid,
                        frame.window_update_increment,
                        h2.streams[idx].send_window,
                    )
                    if fr.kind != FLOW_RESULT_OK:
                        # Per-stream: emit RST_STREAM.
                        var rst = List[UInt8]()
                        encode_rst_stream_frame(sid, fr.error_code, rst)
                        h2.append_out_bytes(rst^)
            continue

        if kind == FRAME_RST_STREAM:
            var idx = h2.find_stream_idx(sid)
            if idx >= 0:
                h2.streams[idx].state = STREAM_STATE_CLOSED
                # ⛔ `end_stream_seen` IS NOT SET HERE, AND SETTING IT WAS A
                # SILENT DATA-TRUNCATION BUG. See `H2ClientStream
                # .reset_error_code` for the whole story: that bit is the
                # driver's "response complete" signal, so an RST landed on the
                # caller as a successful short response with the RST error code
                # thrown away. The reset is recorded instead, and
                # `drive_h2_streams_to_completion` raises on it — which is what
                # RFC 9113 §5.1 means by a stream entering "closed" via
                # RST_STREAM rather than via END_STREAM.
                h2.streams[idx].reset_error_code = Int64(
                    Int(frame.rst_error_code)
                )
                # The PEER sent this one. Clear any local-reset marking so the
                # driver's diagnostic names the party that actually reset the
                # stream (a peer RST can cross a local one on the wire).
                h2.streams[idx].reset_is_local = False
            continue

        if kind == FRAME_PUSH_PROMISE:
            # server push not supported. PROTOCOL_ERROR per §8.4.
            emit_goaway_for_client(h2, H2_ERR_PROTOCOL_ERROR)
            return max_sid_processed

        if kind == FRAME_HEADERS or kind == FRAME_CONTINUATION:
            var ok = _handle_inbound_headers_or_cont(h2, frame^)
            if not ok:
                return max_sid_processed
            continue

        if kind == FRAME_DATA:
            var ok = _handle_inbound_data(h2, frame^)
            if not ok:
                return max_sid_processed
            continue

        # Unknown frame type: per RFC 9113 §4.1, ignore.
        continue


def _handle_inbound_headers_or_cont(
    mut h2: H2ClientConnectionState,
    var frame: Frame,
) -> Bool:
    """Apply an inbound HEADERS or CONTINUATION (server's RESPONSE
    headers) per RFC 9113 §6.10 reassembly. Returns False on connection
    protocol error (caller emits GOAWAY)."""
    var sid = frame.header.stream_id
    var is_headers = frame.header.kind == FRAME_HEADERS
    var is_continuation = frame.header.kind == FRAME_CONTINUATION
    var end_headers = (
        frame.header.flags & FLAG_END_HEADERS
    ) != UInt8(0)
    var end_stream_on_this = (
        frame.header.flags & FLAG_END_STREAM
    ) != UInt8(0)

    if is_headers:
        if sid == UInt32(0):
            emit_goaway_for_client(h2, H2_ERR_PROTOCOL_ERROR)
            return False
        # Server-initiated streams are EVEN; client-initiated are ODD.
        # Response HEADERS arrive on the client-initiated stream the
        # client opened with the matching odd sid.
        # RFC 9113 §6.10, inner restatement. Belt-and-braces: while
        # `process_received_frames` is the only caller, its dispatch-loop guard
        # has already refused a HEADERS that arrives inside an open block, so
        # this arm is not reached today. It is retained so the invariant still
        # holds if this helper is ever driven from another path — ⛔ do NOT
        # treat it as the enforcing check; that one is at the dispatch site,
        # because a guard reachable only for HEADERS/CONTINUATION is what let
        # eight other frame types through in the first place.
        if h2.cont_reasm_stream_id != UInt32(0):
            emit_goaway_for_client(h2, H2_ERR_PROTOCOL_ERROR)
            return False
        var idx = h2.find_stream_idx(sid)
        if idx < 0:
            # HEADERS on a stream we never opened — protocol error.
            emit_goaway_for_client(h2, H2_ERR_PROTOCOL_ERROR)
            return False
        # State machine: response HEADERS on our open / half-closed-local
        # stream. We're the client; HALF_CLOSED_LOCAL means we sent
        # END_STREAM on the request; this HEADERS is the response head.
        var state = h2.streams[idx].state
        if state == STREAM_STATE_CLOSED:
            # Late HEADERS on a closed stream — server out-of-spec; ignore
            # the frame but don't error (peer may have already RST'd).
            return True
        # Flag continuation_pending if END_HEADERS not set.
        if not end_headers:
            h2.streams[idx].continuation_pending = True
        if end_stream_on_this:
            h2.streams[idx].end_stream_seen = True
            # Server sent END_STREAM on HEADERS → no body to come.
            if state == STREAM_STATE_OPEN:
                h2.streams[idx].state = STREAM_STATE_HALF_CLOSED_REMOTE
            elif state == STREAM_STATE_HALF_CLOSED_LOCAL:
                h2.streams[idx].state = STREAM_STATE_CLOSED
        h2.cont_reasm_stream_id = sid
        # CONTINUATION-FLOOD CEILING (CVE-2024-27316 shape) — see
        # connection_state.mojo §1b. A hostile ORIGIN can flood our client
        # exactly as a hostile client floods our server; HEADERS/CONTINUATION
        # are not flow-controlled in either direction.
        if not _append_client_header_block(h2, Span(frame.payload)):
            emit_goaway_for_client(h2, H2_ERR_ENHANCE_YOUR_CALM)
            _reset_client_header_block(h2)
            return False
    elif is_continuation:
        if h2.cont_reasm_stream_id == UInt32(0) or (
            h2.cont_reasm_stream_id != sid
        ):
            emit_goaway_for_client(h2, H2_ERR_PROTOCOL_ERROR)
            return False
        if not _append_client_header_block(h2, Span(frame.payload)):
            emit_goaway_for_client(h2, H2_ERR_ENHANCE_YOUR_CALM)
            _reset_client_header_block(h2)
            return False
        var idx = h2.find_stream_idx(sid)
        if idx >= 0 and end_headers:
            h2.streams[idx].continuation_pending = False

    if not end_headers:
        return True

    # We have a complete header block; decode it.
    var sid_assembled = h2.cont_reasm_stream_id
    var block_view = Span(h2.cont_reasm_buf)
    var decoded: List[HpackHeader]
    try:
        decoded = h2.hpack_decoder.decode_block(block_view)
    except e:
        _ = e
        emit_goaway_for_client(h2, H2_ERR_PROTOCOL_ERROR)
        return False
    # Reset reassembly state.
    _reset_client_header_block(h2)

    # Find target stream's response-header-list slot.
    var idx = h2.find_stream_idx(sid_assembled)
    if idx < 0:
        return True
    # ★★. Everything below this
    # line replaces a loop that pulled `:status` by string compare and
    # appended every other decoded header VERBATIM — no validation of the
    # status value, of pseudo-header placement, of field-name or field-value
    # syntax, of connection-specific fields, or of a SECOND block re-entering
    # the same branch. Two of those were silent wrong answers rather than
    # errors, which is worse than a raise: `:status: 0200` reached the caller
    # as 200, and a trailer's `:status` rewrote an already-delivered 500.
    #
    # THE STREAM IS REFUSED ONCE. A stream already carrying a §8.1.1 verdict
    # has been RST; a further header block on it is the peer racing our reset
    # and is dropped without re-refusing (a second RST_STREAM would be noise,
    # and re-entering the state machine on a refused stream is how a partial
    # message gets half-applied).
    if h2.streams[idx].malformed_scope != H2_MALFORMED_SCOPE_NONE:
        return True

    if h2.streams[idx].response_head_seen:
        # ---- TRAILER SECTION (RFC 9113 §8.1). ----
        var tv = h2_validate_response_trailers(decoded)
        if tv.is_malformed():
            _refuse_malformed_response(
                h2, sid_assembled, idx,
                H2_MALFORMED_SCOPE_TRAILER, tv.reason_code,
            )
            return True
        # "Trailers MUST NOT be followed by anything" — the section is the
        # last thing on the stream, so the frame that ends it carries
        # END_STREAM. `end_stream_seen` is set from the HEADERS frame of this
        # block (above), before its CONTINUATIONs arrive, so this reads the
        # flag of the block being applied and not of some earlier one.
        if not h2.streams[idx].end_stream_seen:
            _refuse_malformed_response(
                h2, sid_assembled, idx,
                H2_MALFORMED_SCOPE_TRAILER,
                H2_MALFORMED_TRAILER_NOT_END_STREAM,
            )
            return True
        _append_response_trailers(h2, idx, decoded)
        return True

    # ---- RESPONSE HEAD (first block, or an interim 1xx). ----
    var hv = h2_validate_response_head(decoded)
    if hv.is_malformed():
        _refuse_malformed_response(
            h2, sid_assembled, idx,
            H2_MALFORMED_SCOPE_HEAD, hv.reason_code,
        )
        return True

    if h2_status_is_informational(hv.status):
        # RFC 9110 §15.2 — an INTERIM response is a message of its own,
        # followed by the real one on the same stream. Dropping it here is
        # what stops its fields from arriving in the final response's header
        # map and its status from being the one the caller reads; a 1xx
        # deliberately does NOT set `response_head_seen`, so the block that
        # follows is still a HEAD and not a trailer section.
        return True

    h2.streams[idx].response_status = UInt16(hv.status)
    h2.streams[idx].declared_content_length = hv.content_length
    h2.streams[idx].response_head_seen = True

    var hdr_slot = h2.streams[idx].response_header_idx
    var nd = len(decoded)
    var di = 0
    while di < nd:
        # The head's `:status` is already applied; every remaining field is a
        # regular one (the validator refused any other pseudo), so the slot
        # the caller reads carries exactly the response's own fields.
        if String(decoded[di].name) != String(":status"):
            if hdr_slot >= 0:
                var n_copy = String(decoded[di].name)
                var v_copy = String(decoded[di].value)
                h2.response_header_lists[hdr_slot].append(
                    HpackHeader(n_copy^, v_copy^),
                )
                h2.streams[idx].response_header_count = (
                    h2.streams[idx].response_header_count + UInt32(1)
                )
        di = di + 1

    # A head that itself ends the stream frames ZERO content, so the
    # content-length comparison is due now — there will be no DATA frame to
    # trigger it.
    if h2.streams[idx].end_stream_seen:
        _check_content_length_at_end(h2, sid_assembled, idx)
    return True


def _append_response_trailers(
    mut h2: H2ClientConnectionState,
    idx: Int,
    ref decoded: List[HpackHeader],
):
    """Store a VALIDATED trailer section in its own per-stream slot.

    The slot is allocated lazily — an empty trailer section (legal, and the
    shape a header block with no fields takes) allocates nothing."""
    var n = len(decoded)
    if n == 0:
        return
    var tslot = h2.streams[idx].response_trailer_idx
    if tslot < 0:
        if len(h2.free_trailer_slots) > 0:
            tslot = h2.free_trailer_slots.pop()
        else:
            tslot = len(h2.response_trailer_lists)
            h2.response_trailer_lists.append(List[HpackHeader]())
        h2.streams[idx].response_trailer_idx = tslot
    var i = 0
    while i < n:
        var n_copy = String(decoded[i].name)
        var v_copy = String(decoded[i].value)
        h2.response_trailer_lists[tslot].append(HpackHeader(n_copy^, v_copy^))
        i = i + 1


def _refuse_malformed_response(
    mut h2: H2ClientConnectionState,
    stream_id: UInt32,
    idx: Int,
    scope: UInt8,
    reason: UInt16,
):
    """RFC 9113 §8.1.1: "An endpoint that receives a malformed request or
    response MUST treat it as a stream error (Section 5.4.2) of type
    PROTOCOL_ERROR."

    STREAM error, not connection error, and that is the RFC's choice rather
    than ours: one bad response from an origin must not tear down a
    multiplexed connection carrying other callers' in-flight streams. The
    stream is marked CLOSED so nothing further is applied to it, and
    `malformed_scope` is what makes the refusal visible to
    `extract_response_for_stream` and to the drive loop — WITHOUT which the
    peer would be told and the caller would not, and a refused stream that
    never reaches END_STREAM would park the drive to its wall deadline.
    """
    if h2.streams[idx].malformed_scope != H2_MALFORMED_SCOPE_NONE:
        return
    h2.streams[idx].malformed_scope = scope
    h2.streams[idx].malformed_reason = reason
    h2.streams[idx].state = STREAM_STATE_CLOSED
    emit_rst_stream_for_client(h2, stream_id, H2_ERR_PROTOCOL_ERROR)


def _check_content_length_at_end(
    mut h2: H2ClientConnectionState,
    stream_id: UInt32,
    idx: Int,
) -> Bool:
    """RFC 9113 §8.1.1: "A response is also malformed if the value of a
    content-length header field does not equal the sum of the DATA frame
    payload lengths that form the content."

    Returns False (and refuses the stream) on a mismatch.

    ⛔ THIS IS THE h2 TWIN OF THE h1 CHUNKED-EOF TRUNCATION, and the worse of
    the two: that one at least raises. A
    client that does not compare these hands the caller a SHORT body with a
    200 and no error at all.
    """
    var declared = h2.streams[idx].declared_content_length
    if declared < Int64(0):
        return True
    if h2_status_has_no_content(
        Int(h2.streams[idx].response_status),
        h2.streams[idx].request_method_is_head,
    ):
        return True
    var body_slot = h2.streams[idx].response_body_idx
    var received = Int64(0)
    if body_slot >= 0:
        received = Int64(len(h2.response_body_buffers[body_slot]))
    if received == declared:
        return True
    _refuse_malformed_response(
        h2, stream_id, idx,
        H2_MALFORMED_SCOPE_HEAD,
        H2_MALFORMED_CONTENT_LENGTH_MISMATCH,
    )
    return False


def _replenish_recv_window_after_data(
    mut h2: H2ClientConnectionState,
    idx: Int,
    n_consumed: Int,
    credit_stream: Bool = True,
):
    """Accumulate `n_consumed`
    DATA bytes into the per-stream + per-connection pending-update counters and,
    when either crosses the recv-FC drain watermark, stage a WINDOW_UPDATE frame
    (restoring the corresponding recv window) into `pending_out` so the server
    can keep streaming.

    RFC 9113 §6.9: WINDOW_UPDATE(stream_id) replenishes that stream's window;
    WINDOW_UPDATE(0) replenishes the connection window. We emit BOTH when their
    respective accumulators cross the watermark (the standard "refill at half
    the window" policy `RecvFlowController` already encodes via `drain_watermark`
    and `on_ring_drain`). The increment we send == the bytes accumulated since
    the last update, which is exactly what we restore to the window — so the
    advertised window returns to its initial size and never depletes.

    Called from `_handle_inbound_data` on every DATA frame in the buffered
    drive path.

    ★ `idx < 0` MEANS "NO STREAM TO CREDIT, BUT THE CONNECTION IS STILL OWED".
    The per-stream half is SKIPPED and the connection half still runs. That is
    not a defensive nicety: `retire_stream` prunes a completed stream from the
    table, so a DATA frame the server was still flushing when we finished the
    request lands here with no stream slot at all -- routine, not hostile. The
    stream's window died with the stream; the CONNECTION's did not, and RFC
    9113 §6.9.1 charges the bytes against it regardless of the stream's fate.
    """
    if n_consumed <= 0:
        return
    var watermark = h2.recv_fc.drain_watermark

    # ---- Per-stream window ------------------------------------------------
    # `credit_stream=False` is the RFC 9113 §6.9.1 case: the frame overran
    # THIS stream's window, so we refuse the stream but still owe its octets
    # back on the CONNECTION window. Crediting the window of a stream we are
    # simultaneously resetting would be pointless (the peer discards
    # WINDOW_UPDATE on a closed stream, §6.9) and would advertise capacity on
    # a stream we have just told the peer to stop using.
    if not credit_stream:
        h2.recv_conn_pending_update = (
            h2.recv_conn_pending_update + UInt32(n_consumed)
        )
        if h2.recv_conn_pending_update >= watermark:
            var inc_only = h2.recv_conn_pending_update
            h2.recv_conn_pending_update = UInt32(0)
            h2.recv_fc.conn_recv_window = (
                h2.recv_fc.conn_recv_window + Int32(Int(inc_only))
            )
            var cu_only = List[UInt8]()
            encode_window_update_frame(UInt32(0), inc_only, cu_only)
            h2.append_out_bytes(cu_only^)
        return

    # `idx < 0` is the OTHER reason there is no stream half to do:
    # the slot is gone entirely (`retire_stream` pruned it), rather
    # than present-but-refused. Same obligation, different cause.
    if idx >= 0:
        h2.streams[idx].recv_pending_update = (
            h2.streams[idx].recv_pending_update + UInt32(n_consumed)
        )
        if h2.streams[idx].recv_pending_update >= watermark:
            var inc = h2.streams[idx].recv_pending_update
            h2.streams[idx].recv_pending_update = UInt32(0)
            # Restore the stream's recv window by the bytes we credit back.
            h2.streams[idx].recv_window = (
                h2.streams[idx].recv_window + Int32(Int(inc))
            )
            var sid = h2.streams[idx].stream_id
            var su = List[UInt8]()
            encode_window_update_frame(sid, inc, su)
            h2.append_out_bytes(su^)

    # ---- Connection window ------------------------------------------------
    h2.recv_conn_pending_update = (
        h2.recv_conn_pending_update + UInt32(n_consumed)
    )
    if h2.recv_conn_pending_update >= watermark:
        var inc = h2.recv_conn_pending_update
        h2.recv_conn_pending_update = UInt32(0)
        # Restore the connection's recv window (tracked on recv_fc).
        h2.recv_fc.conn_recv_window = (
            h2.recv_fc.conn_recv_window + Int32(Int(inc))
        )
        var cu = List[UInt8]()
        encode_window_update_frame(UInt32(0), inc, cu)
        h2.append_out_bytes(cu^)


def _return_connection_capacity(
    mut h2: H2ClientConnectionState, fc_len: Int,
) -> Bool:
    """Charge `fc_len` DATA octets against the CONNECTION recv window and put
    them straight back, for a frame whose STREAM is gone or no longer
    receiving. Returns False (caller GOAWAYs) only on a genuine connection
    flow-control violation.

    ★ WHY A DROPPED FRAME STILL COSTS AND STILL PAYS. Flow control is a
    two-party agreement about ONE number, and the peer has already spent
    `fc_len` of its connection send window putting these bytes on the wire.
    Our opinion of the stream does not reach the peer's accounting. If we
    simply return without charging and without crediting, we never emit the
    WINDOW_UPDATE(0) that gives the capacity back, so the peer's send window
    is permanently `fc_len` smaller -- and a long-lived pooled connection
    walks it to zero and stops sending, with both ends believing they are
    behaving. RFC 9113 §6.9.1 states the obligation directly: the contribution
    is accounted against the connection flow-control window regardless.

    Hyper asserts the same thing from the other side in
    `goaway_ignores_data_but_returns_connection_capacity` and
    `padded_data_on_forgotten_stream_releases_connection_capacity`.

    The charge and the credit are BOTH required. Charging alone leaves us
    consistent with the peer and stalls it anyway; crediting alone
    double-counts. `_replenish_recv_window_after_data(h2, -1, ...)` runs the
    connection half only -- there is no stream window to restore."""
    if fc_len <= 0:
        return True
    var fr = h2.recv_fc.on_conn_data_received(fc_len)
    if fr.kind != FLOW_RESULT_OK:
        # The peer overran the CONNECTION window -- genuinely connection-scoped
        # (RFC 9113 §6.9.1), and the one case here that is not the peer's
        # ordinary timing.
        emit_goaway_for_client(h2, H2_ERR_FLOW_CONTROL_ERROR)
        return False
    _replenish_recv_window_after_data(h2, -1, fc_len)
    return True


def _handle_inbound_data(
    mut h2: H2ClientConnectionState,
    var frame: Frame,
) raises -> Bool:
    """Apply an inbound DATA frame on a client stream (server's response
    body). Charges recv flow control + appends bytes to the stream's
    response_body_buffers slot. Updates state machine on END_STREAM.

    ★ THE BYTES ARE OWED WHATEVER THE STREAM'S FATE (RFC 9113 §6.9.1).
    Both early-return paths below -- stream retired, and stream not in a
    receiving state -- charge and credit the CONNECTION window before
    dropping the frame."""
    var sid = frame.header.stream_id
    var idx = h2.find_stream_idx(sid)
    var payload_len = len(frame.payload)
    # ── RFC 9113 §6.1 — FLOW CONTROL COUNTS THE **LENGTH FIELD** ───────────
    # "The entire DATA frame payload is included in flow control, including
    # the Pad Length and Padding fields if present."
    #
    # `decode_frame` has ALREADY stripped the Pad Length octet and the padding
    # octets out of `frame.payload` (codec/h2/frame.mojo §DATA: `po = po + 1;
    # pe = pe - pad_len`), so `len(frame.payload)` is the DECODED count and is
    # SHORT of what the peer debited from its send windows by exactly
    # `pad_len + 1` — on every padded frame, permanently, and in the direction
    # that ends at zero. The peer then stops sending and this client parks with
    # no error on either side: a silent stall that ends in a 504. `frame.header.length` is the untouched wire
    # LENGTH, which is what both peers must agree on.
    #
    # ⚠ The two lengths are DIFFERENT QUANTITIES and both are needed here:
    # `fc_len` is what flow control owes, `payload_len` is what the body is.
    # On an UNPADDED frame they are equal, so this is not "payload_len + 1".
    var fc_len = Int(frame.header.length)
    if idx < 0:
        # ★★ TWO DIFFERENT STREAM STATES ARRIVE HERE AND RFC 9113 SCOPES THEM
        # OPPOSITELY. `find_stream_idx` cannot tell them apart — both are
        # simply "not in the table" — but the STREAM ID can, because
        # `next_client_stream_id` is this connection's allocation high-water
        # mark and only ever moves forward (h2_client §allocate).
        #
        #   sid >= next_client_stream_id — WE NEVER OPENED IT. The stream is
        #     **idle**, and §5.1 idle is explicit: "Receiving any frame other
        #     than HEADERS or PRIORITY on a stream in this state MUST be
        #     treated as a connection error (Section 5.4.1) of type
        #     PROTOCOL_ERROR." A peer sending body for a stream nobody asked
        #     for is not a timing race — it is a broken or hostile peer, and
        #     nothing on the connection is worth preserving.
        #
        #   sid <  next_client_stream_id — WE OPENED IT AND RETIRED IT.
        #     `retire_stream` prunes a completed stream on
        #     every request, so a server still flushing DATA when we finished
        #     lands here as ORDINARY timing. The stream is **closed**, and
        #     §6.1 scopes DATA in the wrong stream state to the STREAM:
        #     STREAM_CLOSED. GOAWAYing this case tore down the pooled
        #     connection and every OTHER caller's in-flight request on it.
        #
        # ⛔ CONFLATING THEM IS WRONG IN BOTH DIRECTIONS, and this function has
        # now shipped each mistake. GOAWAY-for-everything is the pooled-conn
        # teardown above. STREAM_CLOSED-for-everything lets a peer stream bytes
        # at stream IDs that were never negotiated and be answered with a
        # polite per-stream reset, forever. nghttp2 keeps exactly this
        # discrimination through its idle/closed bookkeeping.
        #
        # ⚠ EVEN (server-initiated) IDs DELIBERATELY TAKE THE CLOSED ARM. They
        # are idle too — we never allocate one — but we have never enabled
        # push, so the conservative per-stream refusal is the smaller blast
        # radius and matches the behaviour that shipped. A push that reaches
        # this client is refused at PUSH_PROMISE, not here.
        if sid >= h2.next_client_stream_id:
            emit_goaway_for_client(h2, H2_ERR_PROTOCOL_ERROR)
            return False
        if not _return_connection_capacity(h2, fc_len):
            return False
        emit_rst_stream_for_client(h2, sid, H2_ERR_STREAM_CLOSED)
        return True
    # ── DATA ON A STREAM THAT IS NOT RECEIVING ──────────────────────────
    # RFC 9113 §6.1: "If a DATA frame is received whose stream is not in
    # 'open' or 'half-closed (local)' state, the recipient MUST respond with
    # a stream error of type STREAM_CLOSED." The bytes belong to a response
    # that no longer exists -- appending them to `response_body_buffers`
    # surfaced post-RST body to the caller, and an END_STREAM on such a frame
    # marked the RESET stream complete, which is exactly the truncation
    # `H2ClientStream.reset_error_code` exists to stop.
    #
    # We do not RST back, matching `_handle_inbound_headers_or_cont`'s
    # long-standing treatment of late HEADERS on a CLOSED stream: we are here
    # because the PEER already reset the stream (or already ended it), so an
    # RST of our own is pure amplification on a race the peer started.
    # `_return_connection_capacity` still runs -- §6.9.1 does not care why the
    # stream stopped receiving.
    var st = h2.streams[idx].state
    if st != STREAM_STATE_OPEN and st != STREAM_STATE_HALF_CLOSED_LOCAL:
        if not _return_connection_capacity(h2, fc_len):
            return False
        return True
    # ── THE TWO MALFORMED-RESPONSE ARMS (RFC 9113 §8.1.1) ───────────────
    # ⚠ BOTH SIT **BELOW** THE `idx < 0` AND "NOT RECEIVING" ARMS ABOVE, AND
    # BOTH CREDIT THE CONNECTION WINDOW, ON PURPOSE. They were authored
    # against a revision of this function whose only `idx < 0` handling was
    # `emit_goaway(PROTOCOL_ERROR)` and which had no §6.9.1 obligation on its
    # drop paths. Both of those are now wrong: a retired stream is ORDINARY
    # timing rather than a connection error, and every early return that drops
    # a frame owes the octets back (see `_return_connection_capacity` and this
    # function's docstring). Re-adding them at the top would have restored the
    # GOAWAY and opened two uncredited drop paths — a connection-window leak
    # that walks a long-lived pooled connection to a silent stall.
    #
    # Already refused under §8.1.1 — the peer is racing our RST_STREAM. Drop
    # the frame rather than appending it to a body no caller will ever be
    # given. Reached only while the stream is still nominally receiving;
    # `_refuse_malformed_response` sets STREAM_STATE_CLOSED, so the ordinary
    # repeat lands in the "not receiving" arm above.
    if h2.streams[idx].malformed_scope != H2_MALFORMED_SCOPE_NONE:
        if not _return_connection_capacity(h2, fc_len):
            return False
        return True
    # RFC 9113 §8.1: an HTTP/2 message is a HEADERS frame, then zero or more
    # CONTINUATIONs, and only THEN content. DATA on a stream that has not
    # carried a FINAL response head is not body — there is no message for it
    # to belong to, and a 1xx interim response is explicitly a message with no
    # content (RFC 9110 §15.2), so DATA between a 1xx and the real head lands
    # here too. Buffering it is how the bytes ended up prepended to the next
    # response's body.
    if not h2.streams[idx].response_head_seen:
        _refuse_malformed_response(
            h2, sid, idx,
            H2_MALFORMED_SCOPE_HEAD, H2_MALFORMED_DATA_BEFORE_HEAD,
        )
        if not _return_connection_capacity(h2, fc_len):
            return False
        return True
    # Charge recv flow control.
    if fc_len > 0:
        var fr = h2.recv_fc.on_data_received(
            fc_len, h2.streams[idx].recv_window, sid,
        )
        if fr.kind == FLOW_RESULT_RST_STREAM:
            # ── RFC 9113 §6.9 — A STREAM OVERRUN IS A STREAM ERROR ─────────
            # The frame fits the CONNECTION window but overran THIS stream's.
            # "A receiver MAY respond with a stream error ... of type
            # FLOW_CONTROL_ERROR". Tearing the connection down instead (the
            # previous behaviour) destroys every unrelated in-flight stream on
            # it — head-of-line destruction that hyper, Go http2 and nghttp2
            # all avoid by scoping the refusal to the offending stream.
            # ONE RST per stream, not one per frame: a peer that keeps
            # streaming a body it has no window for would otherwise draw an
            # RST_STREAM for every frame — we would be the amplifier. The
            # connection accounting below still runs on every frame, which is
            # what §6.9.1 actually requires.
            if not h2.streams[idx].reset_is_local:
                emit_rst_stream_for_client(h2, sid, fr.error_code)
            h2.streams[idx].state = STREAM_STATE_CLOSED
            # Give the stream a TERMINAL disposition. Without one the driver
            # has no completion signal for it and the caller hangs — which is
            # the very failure class this refusal exists to avoid.
            h2.streams[idx].reset_error_code = Int64(Int(fr.error_code))
            h2.streams[idx].reset_is_local = True
            # §6.9.1: the octets were charged to the connection window by
            # `on_data_received` and are being discarded here, so they must be
            # credited back or the connection window leaks for its lifetime.
            _replenish_recv_window_after_data(h2, idx, fc_len, False)
            # True, not False: the connection is healthy and the rest of the
            # receive buffer (other streams' frames) must still be processed.
            return True
        if fr.kind != FLOW_RESULT_OK:
            emit_goaway_for_client(h2, H2_ERR_FLOW_CONTROL_ERROR)
            return False
        # the buffered drive consumes
        # DATA synchronously here, so receipt IS the ring-drain. Replenish the
        # depleted recv windows + stage WINDOW_UPDATE frames once the consumed
        # bytes cross the recv-FC watermark, so a flow-control-respecting server
        # keeps streaming the rest of the body. WITHOUT this, the per-stream +
        # connection recv windows deplete to 0 after ~64KB and the server STOPS
        # sending, wedging the h2 drive on a park that never wakes -> the 120s
        # wall-deadline (a GCS ReadObject stall). (The
        # buffered-plaintext fix is a real-but-secondary mechanic; THIS is the
        # main one.)
        _replenish_recv_window_after_data(h2, idx, fc_len)
    # Append to response body buffer.
    var body_slot = h2.streams[idx].response_body_idx
    if body_slot >= 0:
        # ── RESPONSE-BODY CEILING ──
        # Checked ONCE per DATA frame against the length the frame decoder
        # already parsed — never per byte. `_replenish_recv_window_after_data`
        # (below/above) refills both recv windows on every frame, so flow
        # control provides no ceiling of its own; this is the only one.
        if (
            len(h2.response_body_buffers[body_slot]) + payload_len
            > h2.max_response_body_bytes
        ):
            emit_rst_stream_for_client(h2, sid, H2_ERR_ENHANCE_YOUR_CALM)
            raise Error(
                "h2 client: response body on stream "
                + String(Int(sid))
                + " exceeds the "
                + String(h2.max_response_body_bytes)
                + "-byte ceiling (hostile or misbehaving origin?)"
            )
        h2.response_body_buffers[body_slot].extend(Span(frame.payload))
        # RFC 9113 §8.1.1, caught EARLY: a peer that has already sent more
        # content than it declared cannot end up matching, so there is no
        # reason to keep buffering it. The equality case is still checked at
        # END_STREAM below — this arm only catches the overrun.
        var declared_now = h2.streams[idx].declared_content_length
        if declared_now >= Int64(0) and not h2_status_has_no_content(
            Int(h2.streams[idx].response_status),
            h2.streams[idx].request_method_is_head,
        ):
            if Int64(len(h2.response_body_buffers[body_slot])) > declared_now:
                _refuse_malformed_response(
                    h2, sid, idx,
                    H2_MALFORMED_SCOPE_HEAD,
                    H2_MALFORMED_CONTENT_LENGTH_MISMATCH,
                )
                return True
    # END_STREAM transitions.
    var flags = frame.header.flags
    if (flags & FLAG_END_STREAM) != UInt8(0):
        h2.streams[idx].end_stream_seen = True
        var state = h2.streams[idx].state
        if state == STREAM_STATE_OPEN:
            h2.streams[idx].state = STREAM_STATE_HALF_CLOSED_REMOTE
        elif state == STREAM_STATE_HALF_CLOSED_LOCAL:
            h2.streams[idx].state = STREAM_STATE_CLOSED
        # The content is complete: compare it against what the head declared.
        _ = _check_content_length_at_end(h2, sid, idx)
    return True


# =============================================================================
# §10 — Response extraction.
# =============================================================================


def extract_response_for_stream(
    mut h2: H2ClientConnectionState,
    stream_id: UInt32,
) raises -> Tuple[UInt16, HeaderMap, List[UInt8]]:
    """Build a response tuple (status, headers, body) from h2 state for
    the stream identified by `stream_id`. Caller has confirmed
    `streams[idx].end_stream_seen == True`.

    Returns:
      (response_status, response_headers, response_body)

    Raises if the stream is not present or the response is incomplete
    (no :status seen yet)."""
    var idx = h2.find_stream_idx(stream_id)
    if idx < 0:
        raise Error(
            "extract_response_for_stream: stream " + String(Int(stream_id))
            + " not present"
        )
    # ★ A MALFORMED HEAD HAS NO RESPONSE TO HAND UP (RFC 9113 §8.1.1). The
    # peer was already told with RST_STREAM(PROTOCOL_ERROR); this is the half
    # that tells the CALLER, and without it the refusal would be invisible
    # above the codec — the exact shape of the two silent wrong answers this
    # validation layer was written to end.
    #
    # ⚠ A malformed TRAILER is deliberately NOT refused here: the head was
    # validated and delivered before the trailer arrived, so the response the
    # caller reads is the one the origin committed to. See
    # `H2_MALFORMED_SCOPE_*`. The drive loop still raises, so nobody driving
    # this connection silently loses the trailer section.
    if h2.streams[idx].malformed_scope == H2_MALFORMED_SCOPE_HEAD:
        raise Error(
            "extract_response_for_stream: stream " + String(Int(stream_id))
            + " carried a MALFORMED response — "
            + h2_malformed_reason_text(h2.streams[idx].malformed_reason)
            + ". RFC 9113 §8.1.1 makes this a stream error of type"
            " PROTOCOL_ERROR; the client sent RST_STREAM and there is no"
            " response to deliver."
        )
    var status = h2.streams[idx].response_status
    if Int(status) == 0:
        raise Error(
            "extract_response_for_stream: stream "
            + String(Int(stream_id)) + " has no :status"
        )

    # Build the HeaderMap from the slot.
    var hdr_slot = h2.streams[idx].response_header_idx
    var hdrs = HeaderMap()
    if hdr_slot >= 0:
        ref hlist = h2.response_header_lists[hdr_slot]
        var n = len(hlist)
        var i = 0
        while i < n:
            var nm = String(hlist[i].name)
            var vl = String(hlist[i].value)
            hdrs.append(nm^, vl^)
            i = i + 1

    # Body bytes.
    var body_slot = h2.streams[idx].response_body_idx
    var body = List[UInt8]()
    if body_slot >= 0:
        ref bsrc = h2.response_body_buffers[body_slot]
        var nb = len(bsrc)
        var bi = 0
        while bi < nb:
            body.append(bsrc[bi])
            bi = bi + 1

    return (status, hdrs^, body^)


def extract_trailers_for_stream(
    mut h2: H2ClientConnectionState,
    stream_id: UInt32,
) raises -> HeaderMap:
    """The stream's VALIDATED trailer section (RFC 9113 §8.1), or an empty
    map if the response carried none.

    ⚠ SEPARATE FROM `extract_response_for_stream` ON PURPOSE. Were trailer
    fields appended to the SAME slot as the response head's, a caller reading
    `grpc-status` beside `content-type` could not tell which half of the message the origin had committed to
    before it sent the body. RFC 9110 §6.5 separates them precisely because
    that distinction is the only thing a trailer is FOR.
    """
    var idx = h2.find_stream_idx(stream_id)
    if idx < 0:
        raise Error(
            "extract_trailers_for_stream: stream " + String(Int(stream_id))
            + " not present"
        )
    var trailers = HeaderMap()
    var tslot = h2.streams[idx].response_trailer_idx
    if tslot < 0:
        return trailers^
    ref tlist = h2.response_trailer_lists[tslot]
    var n = len(tlist)
    var i = 0
    while i < n:
        var nm = String(tlist[i].name)
        var vl = String(tlist[i].value)
        trailers.append(nm^, vl^)
        i = i + 1
    return trailers^


# =============================================================================
# §11 — Driver: drive a multiplex conn to completion
# =============================================================================
#
# `drive_h2_streams_to_completion[S, RT]` is the production-wired analog of
# `OutboundDriver._drive_read_head` / `_drive_write` — it interleaves
# `stream.try_write(pending_out)` and `stream.try_read(scratch)` calls,
# feeding inbound bytes into `process_received_frames`, until ALL of the
# `await_stream_ids` have `end_stream_seen == True`.
#
# Reactor parking: on `StreamIo.pending`, the driver returns to its caller's
# loop. In the production HttpClient.send path, that caller's loop is the
# reactor's poll_completions cycle — exactly the same shape as
# OutboundDriver._drive_read_head. Single-threaded structural concurrency:
# one fiber drives N multiplex streams interleaved in one event loop, NOT
# N OS threads.


# the per-park BOUNDED wait. This is the
# load-bearing constant that closes the pgstore-on-GCS multi-chunk open HANG.
# A single park MUST NOT block indefinitely on the reactor — see
# `transport.stream_park.park_on_pending` for the full root-cause narrative.
#
# Sizing: 250ms is long enough that the park almost never fires its bound on a
# healthy RPC (a level-triggered fd that has bytes wakes in µs; even a slow
# in-DC GCP round-trip is single-digit ms), so the spin-cost of re-parking is
# negligible. It is short enough that a wedged park returns control to the
# driver loop promptly, so the loop's `max_iterations` cap (the REAL overall
# deadline) is reached in bounded wall-time instead of never. The bound is a
# SAFETY NET, not the normal wake path: a healthy slow RPC re-parks across
# multiple bounds and only ever surfaces TIMEOUT if the driver's whole
# iteration budget is exhausted — never from one slow-but-progressing read.
comptime _H2_PARK_DEADLINE_US: Int32 = 250_000

# the DEFAULT overall wall-clock budget for one
# `drive_h2_streams_to_completion` call. 120s matches the conservative end of
# the HTTP client's request-timeout range — long enough that no healthy RPC
# (µs..single-digit-ms to END_STREAM, even in-DC GCP) ever false-trips it, short
# enough that a wedged conn surfaces a typed HttpError[TIMEOUT] in bounded
# wall-time instead of hanging until a 5-min Cloud-Run startup probe kills the
# process. Callers (e.g. a deadline-carrying RPC) may pass a tighter bound.
# <= 0 disables the wall bound (iteration cap still applies).
comptime _H2_DRIVE_DEFAULT_WALL_US: Int64 = 120_000_000


def h2_drive_wall_us(request_timeout_us: Int) -> Int64:
    """★ THE ONE PLACE AN AUTHORED `HttpClientConfig.request_timeout_us`
    BECOMES AN h2 DRIVE WALL. Returns the `max_wall_us` one
    `drive_h2_streams_to_completion` call gets for a client carrying that
    budget.

    ### WHY THIS FUNCTION EXISTS AT ALL (the defect it closes)

    As an **H1-BUFFERED-ONLY** bound (consumed by
    `OutboundDriver.set_request_timeout_us`, which only the BUFFERED h1 arms
    call) `request_timeout_us` would leave every h2 arm on
    `_H2_DRIVE_DEFAULT_WALL_US` (120s) and the STREAMING h1 arm
    (`_run_one_request_streaming`) on
    `_HEAD_DRIVE_DEFAULT_TIMEOUT_US` (600s). One authored number would mean THREE
    different walls depending on which protocol the peer negotiated: against a
    2s authored budget, ~120s on the pooled-h2 arm and ~600s on the
    streaming-h1 arm. `test_request_timeout_binds_on_h2_and_h1` and
    `test_client_send_buffered_honors_request_timeout` pin all three.

    ### WHY `min` AND NOT ASSIGNMENT — AN AUTHORED BUDGET MAY ONLY TIGHTEN

    The two numbers answer different questions and only one of them is the
    caller's to relax:
      * `request_timeout_us` is the CALLER's ceiling — "past this, my answer is
        unusable" (a unit budget, a hosted request ceiling).
      * `_H2_DRIVE_DEFAULT_WALL_US` is the TRANSPORT's liveness net — "past
        this, no correct peer is still working on it".
    A bare assignment would let a LOOSER authored value (e.g. the 295s a Cloud
    Run `for_serving_ceiling` derives) RAISE the h2 wall from 120s to 295s, which is a
    caller silently widening a safety net it does not own. `min` makes this
    change a pure tightening: no existing caller's h2 bound can grow.

    `0` (the unauthored default, and what every `with_defaults` client outside a
    request-scoped process carries) means "state nothing", and returns the
    driver's own default UNCHANGED.

    ⛔ IT NEVER RETURNS `<= 0`. `drive_h2_streams_to_completion` reads a
    non-positive `max_wall_us` as **DISABLE THE WALL BOUND** — the exact
    opposite of a budget — so the one spelling that would turn this knob into an
    unbounded drive is unreachable through this function. That is why the pooled
    arms take `request_timeout_us` and resolve HERE rather than taking a
    `max_wall_us` they could pass a 0 to.
    """
    if request_timeout_us <= 0:
        return _H2_DRIVE_DEFAULT_WALL_US
    var authored = Int64(request_timeout_us)
    if authored < _H2_DRIVE_DEFAULT_WALL_US:
        return authored
    return _H2_DRIVE_DEFAULT_WALL_US


# CPU brake on the inner park loop below.
# If `poll_completions` returns WITHOUT our op_id becoming ready (a drained
# wake-eventfd, a foreign fd's completion) the park RE-POLLS for the remainder
# of its slice rather than handing control back to the driver — that is the
# whole point, since the stream already said Pending and nothing has changed.
# This cap bounds the pathological case where such a return happens with no
# measurable time elapsed, so the park cannot pin a core between clock ticks;
# on hitting it we fall back to the driver loop, which is still wall-bounded.
# Mirrors `_HANDSHAKE_POLLS_PER_SLICE_CAP` (tls_connector.mojo).
comptime _H2_POLLS_PER_SLICE_CAP: Int = 4096

# the LIVELOCK detector's budget —
# consecutive drive-loop trips on which a park reported the fd READY and the
# retried I/O still returned Pending, with ZERO bytes moved in either
# direction. Any progress (bytes read, bytes written) or any IDLE park (a park
# that waited out its whole slice, i.e. the loop really is waiting) resets it.
#
# WHY A SEPARATE BUDGET WHEN AN ITERATION CAP ALREADY EXISTS: the cap is 100_000
# and a spin trip costs ~7.5us, so the cap needs ~0.75s to fire and — this is
# the part that misleads — it fires with a message that says TIMEOUT.
# This budget fires in ~30ms and says LIVELOCK. It cannot false-trip on a
# healthy conn: a spurious readiness is followed by a productive retry (reset),
# and a genuinely waiting drive parks IDLE (reset). 4096 consecutive
# zero-progress ready-wakes is not a state a correct peer can produce.
#
# ⚠ IT DIAGNOSES THE SHAPE, NOT THE CAUSE. The state it detects — a park that
# wakes READY and a retry that moves nothing — has several producers:
#   (a) a wait on the wrong DIRECTION. Real in principle, and what
#       `pending_wait_is_write` prevents — but UNREACHABLE on s2n-tls v1.5.6.
#   (b) an I/O that is Pending but can NEVER become ready: an abrupt
#       peer close, which s2n reports as BLOCKED_ON_READ forever, laundered
#       into Pending on a socket that is permanently
#       read-ready. `s2n_shim._recv_outcome_and_n` reports the close instead;
#       falsifier `test_L2_h2_over_tls_abrupt_close_no_spin`.
#   (c) an I/O that IS progressing, at the WIRE layer, while reporting zero
#       APPLICATION bytes — the producer
#       that makes this detector fire on a connection that never spun. See
#       `_H2_WIRE_PROGRESS_IS_PROGRESS` immediately below: `ready_no_progress`
#       is no longer incremented while `stream.wire_bytes_moved()` is rising.
comptime _H2_READY_NO_PROGRESS_CAP: Int = 4096


# =============================================================================
# ★★ _H2_WIRE_PROGRESS_IS_PROGRESS — the layer the detector was measuring at,
#    and why it was the wrong one.
# =============================================================================
#
# ⛔ THIS IS NOT A WIDENED BUDGET. `_H2_READY_NO_PROGRESS_CAP` is unchanged at
# 4096 and no deadline moved. What changed is the PREDICATE: a trip counts
# toward the cap only if the connection moved NO BYTES AT ALL — application or
# wire. Raising the cap would have made a real spin last longer; this makes a
# real spin trip at exactly the same count while a healthy transfer never does.
#
# THE DEFECT. `ready_no_progress` counted "the retried I/O returned Pending",
# which is an APPLICATION-layer fact. On a TLS stream that fact is routinely
# true while real bytes cross the wire, in BOTH directions:
#
#   WRITE. `s2n_sendv_with_offset_impl` (tls/s2n_send.c:146) opens with
#          `POSIX_GUARD(s2n_flush(conn, blocked));` — an EARLY RETURN. It
#          bypasses the `s2n_errno == S2N_ERR_IO_BLOCKED && user_data_sent > 0`
#          partial-acknowledge arm 80 lines further down (:223-230), which is
#          the ONLY path that reports a positive partial. So once `conn->out`
#          holds an undrained record, EVERY subsequent `s2n_send` answers
#          `(-1, S2N_BLOCKED_ON_WRITE)` with ZERO plaintext accepted, however
#          many bytes that leading flush just pushed onto the socket. A peer
#          that drains slowly — a small receive window, a congested link, an
#          overloaded middlebox — holds the connection in that state for the
#          whole transfer, and the run is UNBOUNDED in the peer's slowness.
#
#   READ.  `s2n_recv` returns `-1 / BLOCKED_ON_READ` whenever it cannot
#          complete a whole record with nothing already decrypted; a 16 KiB
#          record arriving across many TCP segments produces one such call per
#          segment.
#
# In both shapes the fd genuinely becomes ready every trip (`idle_parks == 0`,
# the fingerprint this detector reads as proof of a spin) and the loop
# genuinely advances the transfer. Pre-fix it raised
# `HttpError[LIVELOCK]` — which IS in the connection-level retry set — so the
# request was abandoned and re-issued on a fresh connection, where the same
# congestion produced the same verdict.
#
# THE DISCRIMINATOR IS EXACT, NOT HEURISTIC. `IoStream.wire_bytes_moved()` is
# s2n's own `wire_bytes_in + wire_bytes_out`, and both counters are incremented
# only AFTER the I/O check that a failed syscall bails at:
#
#   tls/s2n_send.c:88-91  w = send_stuffer(...); GUARD(check_write(w));
#                         conn->wire_bytes_out += w;
#   tls/s2n_recv.c:67-71  r = recv_stuffer(...); GUARD(check_read(r));
#                         conn->wire_bytes_in += r;
#
# ⇒ a departed peer (EPIPE/ECONNRESET) and a closed peer (read 0) BOTH freeze
# it, so the two real spins trip the cap exactly as they did before. There is
# no threshold and no timing input, so nothing here can drift with a machine's
# syscall cost — which matters, because that cost is precisely what makes
# trip counters unreadable on their own.
#
# ⚠ NO NEW COST ON THE HOT PATH. The sample is taken ONLY on a branch that was
# about to increment the counter, never on a trip that moved application bytes.
# =============================================================================


# Which branch last declined to make progress, for the give-up message. A
# give-up message that prints `parks` / `idle_parks` and NOTHING about the
# SIDE cannot attribute an `HttpError[LIVELOCK]` to the read half or the write
# half even in principle. A counter that cannot name the branch it counted is
# an unattributable counter.
# =============================================================================
# ★★ THE LIVENESS PROBE — "is this peer up, or just open?"
# =============================================================================
#
# THE PROBLEM. A request can sit on a connection that is UP and SILENT. Every
# other bound this driver has is a BUDGET — the
# iteration cap, the wall clock, the zero-progress detector — and a budget
# expiring cannot say whether the peer was slow, dead, or the loop was
# spinning. Without a probe each such request burns the full 120s wall and
# 504s at the platform's ceiling, and the message at the end names no cause.
#
# A PING is the fix every other client already ships (Go's
# `Transport.ReadIdleTimeout` + `PingTimeout` ->
# `TestTransportCloseAfterLostPing` / `TestTransportConnBecomesUnresponsive`;
# hyper's `http2_keep_alive_interval`; gRPC keepalive). It is the ONLY frame
# whose ACK proves the peer's H2 LAYER is alive rather than just its TCP stack,
# and RFC 9113 §6.7 makes answering one mandatory — "the recipient MUST send a
# PING frame with the ACK flag set in response". A peer that does not answer
# inside the deadline is therefore BROKEN BY DEFINITION, which is what makes
# "unanswered keepalive" a VERDICT where "budget exhausted" was a shrug.
#
# ⛔ THE PROBE COSTS A HEALTHY-BUT-SLOW PEER NOTHING, AND THAT IS THE WHOLE
# REASON IT IS SAFE TO ARM BY DEFAULT. A long-running RPC that produces no
# bytes for a minute is ordinary; it answers the PING immediately, the ACK
# resets the read-idle clock, and the drive carries on. Only SILENCE THAT
# EXTENDS TO THE PING is fatal.
#
# ⚠ TWO BUDGETS, BECAUSE THE TRANSPORTS ADVANCE DIFFERENT CLOCKS. On a real
# socket a park is bounded at `_H2_PARK_DEADLINE_US`, so trips cost real time
# and the WALL budget is the one that fires. On a transport whose park returns
# immediately (fd < 0: the scripted streams, the h2c emulator, socketpairs
# under a wake storm) a drive can make thousands of trips in under a
# millisecond, and a purely time-based probe would never arm at all while the
# loop burned to the zero-progress cap — which is precisely the shape the
# `ScriptedStream` liveness fixture reproduces. So the probe arms on WHICHEVER
# budget the transport actually advances, and neither one alone is sufficient.
#
# ⛔ THE TRIP BUDGETS MUST STAY WELL UNDER `_H2_READY_NO_PROGRESS_CAP` (4096),
# or the zero-progress detector reaches its verdict first and the probe is
# dead code on exactly the transports it was added for. 512 + 512 = 1024
# leaves a 4x margin.
comptime _H2_KEEPALIVE_READ_IDLE_US: Int64 = 15_000_000
"""Silence (no inbound application bytes) that arms a keepalive PING, while an
awaited stream is outstanding and we have nothing queued to send. 15s matches
the value Go's h2 transport is conventionally configured with."""

comptime _H2_KEEPALIVE_PING_TIMEOUT_US: Int64 = 15_000_000
"""How long an unanswered keepalive PING may stand before the connection is
declared dead. 15s is Go's `http2.Transport.PingTimeout` default. Worst case
this turns a 120s wall-clock give-up into a 30s ATTRIBUTABLE one."""

comptime _H2_KEEPALIVE_READ_IDLE_TRIPS: Int = 512
"""The free-park transport's analogue of `_H2_KEEPALIVE_READ_IDLE_US`.

⛔ ADMISSIBLE ONLY UNDER THE TWO GUARDS BELOW. A trip count is not a duration:
what it is worth in real time is set by the driver's TRIP RATE, a property of
the machine and its load, never of the peer."""

comptime _H2_KEEPALIVE_PING_TIMEOUT_TRIPS: Int = 512
"""The free-park transport's analogue of `_H2_KEEPALIVE_PING_TIMEOUT_US`.
Same admissibility rule as `_H2_KEEPALIVE_READ_IDLE_TRIPS`."""

# =============================================================================
# ⛔⛔ A TRIP ANALOGUE IS NOT A DURATION, AND UNGUARDED IT OUTRANKS THE WALL
# BUDGET IT CLAIMS TO STAND IN FOR
# =============================================================================
# `test_h2_park_wake_storm_no_iteration_burn` case B — a silent peer under a
# client-side wake storm, caller wall budget 2600 ms — shows it. Trip rates
# differ several-fold between machines (roughly 0.2 to 0.6 trips/ms): on a
# slower one 1024 trips take ~5 s and the caller's 2600 ms wall wins; on a
# faster one 512 + 512 trips burn in ~1.8 s and the LIVENESS VERDICT preempts
# the caller. A loaded machine may never reach 512 trips at all. THE VERDICT'S
# ARRIVAL TIME IS A FUNCTION OF MACHINE LOAD, WHICH IS WHAT DISQUALIFIES IT AS A
# DEADLINE: a constant documented as standing in for 15 s can be worth under
# 1 s. And ordering this block after the budget checks does not mean it "can
# never mask one of them": WITHIN-TRIP ordering cannot help when the trip
# deadline is reached EARLIER IN WALL TIME than the caller's budget.
#
# ⚠ THE FALSE POSITIVE IS THE DANGEROUS DIRECTION — see the no-false-positive
# controls in `test_L2_h2_goaway_ping_liveness` §3. Declaring a LIVE connection
# dead turns a quiet peer into a re-dial storm, and a wake storm on a real
# socket (a busy reactor carrying many fds) is an ordinary production shape.
#
# TWO GUARDS, BOTH DERIVED FROM CONSTANTS ALREADY IN THIS FILE. Neither adds a
# rate, a threshold, or any per-trip timing input beyond the one clock read the
# wall arms already take.
#
#  (A) DEFERENCE TO THE CALLER. A liveness deadline of D cannot inform a caller
#      whose ENTIRE budget is shorter than D — any verdict it reaches inside
#      that window asserts silence that has not happened yet. So a TRIP-based
#      verdict is admissible only when the caller's wall budget exceeds the
#      real-time window the verdict claims (read-idle + ping-timeout = 30 s),
#      or when the caller stated no wall budget at all.
#  (B) PROOF THAT THE TRANSPORT HAS NO CLOCK. The analogues exist for parks
#      that return instantly (fd < 0: the scripted streams, the h2c emulator).
#      Require that per drive rather than assume it: a transport that HAS a
#      clock spends up to `_H2_PARK_DEADLINE_US` per trip, so 512 of them cost
#      ~128 s. A whole trip budget that burned in less than ONE park slice is a
#      clockless transport by a factor of 512.
#
# Either guard alone closes that failure. Both are here because they
# close DIFFERENT holes: (A) the caller whose budget is short (the test above,
# on both platforms), (B) the caller whose budget is long — 120 s is the
# default — on a transport that spins fast but does keep time.
# =============================================================================
comptime _H2_KEEPALIVE_TRIP_VERDICT_MIN_WALL_US: Int64 = (
    _H2_KEEPALIVE_READ_IDLE_US + _H2_KEEPALIVE_PING_TIMEOUT_US
)
"""Guard (A): the smallest caller wall budget a TRIP-based liveness verdict may
preempt. At or below it the caller's own deadline is the only honest answer."""

comptime _H2_KEEPALIVE_FREE_PARK_PROOF_US: Int64 = Int64(_H2_PARK_DEADLINE_US)
"""Guard (B): the wall-time ceiling a whole trip budget must have burned inside
for that budget to count as evidence. ONE bounded park — a clock-bearing
transport spends `_H2_KEEPALIVE_*_TRIPS` of them."""


comptime _H2_SIDE_NONE: Int = 0
comptime _H2_SIDE_WRITE_READY_ZERO: Int = 1
comptime _H2_SIDE_WRITE_PARK: Int = 2
comptime _H2_SIDE_READ_PARK: Int = 3
comptime _H2_SIDE_READ_READY_ZERO: Int = 4


def _h2_side_name(side: Int) -> StaticString:
    """Name of the `_H2_SIDE_*` ordinal that last incremented
    `ready_no_progress`, for the give-up messages.

    ⚠ `-> StaticString`, NOT `-> String` — the standard shape."""
    if side == _H2_SIDE_WRITE_READY_ZERO:
        return "write(ready,0-bytes-accepted)"
    if side == _H2_SIDE_WRITE_PARK:
        return "write(pending->park-ready)"
    if side == _H2_SIDE_READ_PARK:
        return "read(pending->park-ready)"
    if side == _H2_SIDE_READ_READY_ZERO:
        return "read(ready,0-bytes)"
    return "none"


# =============================================================================
# GOAWAY disposition tokens — the retry-safety discriminator (RFC 9113 §6.8)
# =============================================================================
#
# A GOAWAY is NOT one condition; it is TWO, and they have OPPOSITE remedies.
# The frame carries `Last-Stream-ID`, and RFC 9113 §6.8 states the guarantee
# in terms of it:
#
#   "The GOAWAY frame ... contains the stream identifier of the last stream
#    that the sender ... might have taken some action on ... Receivers of a
#    GOAWAY frame MUST NOT open additional streams ... although a new
#    connection can be established for new streams. ... Activity on streams
#    numbered lower or equal to the last stream identifier might still
#    complete successfully."
#
# So:
#   * stream id  >  Last-Stream-ID  — the peer DEFINITIVELY did not process
#     it. Re-issuing on a NEW connection is safe **even for a non-idempotent
#     verb**: that not-processed guarantee is the entire point of the field.
#   * stream id <= Last-Stream-ID  — the peer MIGHT have processed it. There
#     is NO guarantee either way, so an automatic retry of a non-idempotent
#     verb here is a correctness hazard (a duplicate CreateJob, a double
#     charge). This class must surface to the caller, which is the only layer
#     that knows whether its verb is replayable.
#
# The two are made distinguishable by a MACHINE-READABLE token in the message,
# emitted ONLY by the branch that established the corresponding comparison.
# `is_h2_goaway_unprocessed()` below is the ONLY sanctioned way to test for the
# retry-safe class — do not re-derive it by grepping for "GOAWAY", which
# matches BOTH (and is why a deliberately WIDER transport-interrupted
# classifier is not usable as a retry gate).
#
# ⚠ Neither token may be a substring of the other, or the discriminator
# collapses into the bug it exists to prevent.
comptime H2_GOAWAY_UNPROCESSED_TOKEN: String = "h2-goaway-unprocessed"
"""Emitted iff the awaited stream id is STRICTLY GREATER than the GOAWAY's
`Last-Stream-ID` — the peer did not process it, so re-issue on a new
connection is safe for ANY verb."""

comptime H2_GOAWAY_MAYBE_PROCESSED_TOKEN: String = "h2-goaway-maybe-processed"
"""Emitted iff the connection ended while an awaited stream was AT-OR-BELOW the
GOAWAY's `Last-Stream-ID` — the peer may have acted on it. NOT auto-retryable."""


def is_h2_goaway_unprocessed(ref msg: String) -> Bool:
    """True iff `msg` is the h2 GOAWAY class whose stream was DEFINITIVELY NOT
    processed by the peer (RFC 9113 §6.8), i.e. safe to re-issue on a new
    connection even for a non-idempotent verb.

    Keys on `H2_GOAWAY_UNPROCESSED_TOKEN`, which is emitted by exactly ONE
    raise site — the `sid > goaway_last_stream_id` branch of
    `drive_h2_streams_to_completion`. That single-site property is what makes
    this predicate a proof of the not-processed guarantee rather than a guess
    about it: a message can only carry the token by having made the comparison.

    Returns False for EVERY other error, including the at-or-below GOAWAY class
    (`H2_GOAWAY_MAYBE_PROCESSED_TOKEN`), EOF_MID_RESPONSE, TIMEOUT, IO_ERROR,
    and any server status — none of those carry a not-processed guarantee.

    ⛔ "ONLY BY HAVING MADE THE COMPARISON" IS A PROPERTY OF THE WHOLE MESSAGE,
    NOT JUST OF THE RAISE SITES, AND IT HAS TO BE DEFENDED WHEREVER PEER BYTES
    ENTER ONE. A substring predicate cannot tell OUR token from the PEER'S copy
    of it, so any peer-controlled span interpolated into a message this reads is
    a forgery surface: the at-or-below GOAWAY — the class that must NOT be
    retried — would read as retry-safe if its raise quoted a debug payload that
    spelled the token. That is why `goaway_debug_data_text` renders peer bytes
    through an ALLOWLIST that cannot spell `-` or `[`; read it before adding any
    other peer-derived text to a driver raise.
    """
    return H2_GOAWAY_UNPROCESSED_TOKEN in msg


# =============================================================================
# ★ THE SECOND NOT-PROCESSED CLASS — `RETRYABLE_TRANSPORT`.
# =============================================================================
#
# GOAWAY-above-Last-Stream-ID is not the only transport event that carries a
# PROOF the peer took no action. `HttpError[RETRYABLE_TRANSPORT]` is the class
# every driver in this repo emits for exactly that, and it is emitted ONLY from
# a branch that has already established the proof:
#
#   * `h2_client._drive_*`, write side  — `total_read == 0`
#   * `h2_client._drive_*`, read side   — `total_read == 0`
#   * `h2_client`, RST_STREAM branch    — RFC 9113 §8.7 REFUSED_STREAM
#   * `h2_client.allocate_client_stream_id_or_raise` — the 31-bit stream-id
#     space is spent, so NOTHING was encoded and no byte left this process
#   * `state_machine._write_error`      — `len(self._recv_buf) == 0`
#   * `state_machine._drive_read_head`  — `len(self._recv_buf) == 0`  (x2)
#
# ZERO RESPONSE BYTES means the peer never answered, so the request got no
# verdict and re-issuing it on a fresh connection cannot duplicate an effect
# this peer reported. REFUSED_STREAM is §8.7's explicit statement of the same
# thing. Every sibling branch that has seen even ONE response byte raises
# `IO_ERROR` / `EOF_MID_RESPONSE` instead, deliberately — those MAY have been
# executed, and they are in no retry set.
#
# ⚠ SO THE CLASS NAME IS A PROOF, NOT A LABEL, AND THAT IS WHAT LICENSES THE
# PREDICATE. It is safe to re-issue a NON-IDEMPOTENT verb on this class for the
# same reason it is safe on `is_h2_goaway_unprocessed`: the peer has stated, by
# construction of the emitting branch, that it took no action. A retry keyed on
# the WORD "retryable" rather than on that property would be a guess; this one
# is not. ⛔ If a new raise site ever emits this class WITHOUT the zero-bytes /
# §8.7 discriminator, it breaks that contract and this predicate with it.
comptime H2_RETRYABLE_TRANSPORT_TOKEN: String = "HttpError[RETRYABLE_TRANSPORT]"
"""The class token every not-processed transport fault carries. A SUBSTRING
match, not a prefix one: the message is re-raised by message through
`send_grpc_pooled` / `apply_graph` / `place_job` and arrives wrapped.

⛔ BEING A SUBSTRING MATCH IS ALSO WHY NO PEER-CONTROLLED TEXT MAY BE RENDERED
VERBATIM INTO ANY MESSAGE THAT REACHES THIS PREDICATE. See
`H2ClientConnectionState.goaway_debug_data_text` — the allowlist there exists
to make this token, and `H2_GOAWAY_UNPROCESSED_TOKEN`, unspellable by a peer."""


def h2_goaway_error_name(code: UInt32) -> StaticString:
    """RFC 9113 §7 registry name for a GOAWAY/RST_STREAM error code.

    An UNREGISTERED code is rendered as its number and nothing else — §7 says
    "Unknown or unsupported error codes MUST NOT trigger any special behavior",
    and inventing a name for one would be inventing a semantic.

    ⚠ `-> StaticString`, NOT `-> String` — the standard shape for a
    literal-return ladder: a
    `-> String` ladder is exposed to the crossed-constant-table
    hazard whether or not this particular one ever hits it."""
    if code == UInt32(0x0):
        return "NO_ERROR"
    if code == UInt32(0x1):
        return "PROTOCOL_ERROR"
    if code == UInt32(0x2):
        return "INTERNAL_ERROR"
    if code == UInt32(0x3):
        return "FLOW_CONTROL_ERROR"
    if code == UInt32(0x4):
        return "SETTINGS_TIMEOUT"
    if code == UInt32(0x5):
        return "STREAM_CLOSED"
    if code == UInt32(0x6):
        return "FRAME_SIZE_ERROR"
    if code == UInt32(0x7):
        return "REFUSED_STREAM"
    if code == UInt32(0x8):
        return "CANCEL"
    if code == UInt32(0x9):
        return "COMPRESSION_ERROR"
    if code == UInt32(0xa):
        return "CONNECT_ERROR"
    if code == UInt32(0xb):
        return "ENHANCE_YOUR_CALM"
    if code == UInt32(0xc):
        return "INADEQUATE_SECURITY"
    if code == UInt32(0xd):
        return "HTTP_1_1_REQUIRED"
    return "UNREGISTERED"


def h2_goaway_context(mut h2: H2ClientConnectionState) -> String:
    """The WHY half of a GOAWAY raise: the peer's error code and its own
    Additional Debug Data.

    ★ DROPPING EITHER COSTS something different. Without the CODE, GOAWAY(NO_ERROR) — a routine max-connection-age
    recycle, "re-dial, nothing is wrong" — and GOAWAY(ENHANCE_YOUR_CALM) — the
    peer saying WE are the problem, "stop doing what you are doing" — would produce a
    BYTE-IDENTICAL error string, so an operator reading the logs
    could not tell two opposite remedies apart. Without the DEBUG DATA, the
    server's own one-line explanation for the teardown never leaves this process.

    Rendered by BOTH GOAWAY raise sites in the driver, so the two dispositions
    (`H2_GOAWAY_UNPROCESSED_TOKEN` / `H2_GOAWAY_MAYBE_PROCESSED_TOKEN`) cannot
    drift apart on what they explain."""
    var out = String("; goaway_error=")
    out += String(h2_goaway_error_name(h2.goaway_error_code))
    out += String("(") + String(Int(h2.goaway_error_code)) + String(")")
    if len(h2.goaway_debug_data) > 0:
        out += String("; goaway_debug='")
        out += h2.goaway_debug_data_text()
        out += String("'")
    return out^


def is_h2_retryable_transport(ref msg: String) -> Bool:
    """True iff `msg` is the transport class whose emitting branch PROVED the
    peer did not process the request (zero response bytes, or RFC 9113 §8.7
    REFUSED_STREAM) — safe to re-issue on a new connection even for a
    non-idempotent verb.

    The sibling of `is_h2_goaway_unprocessed`, and the ONLY sanctioned way to
    test for this class. ⛔ Do NOT re-derive it by grepping for "RETRYABLE":
    that also matches `H2_GOAWAY_RETRY_EXHAUSTED` and
    `H2_TRANSPORT_RETRY_EXHAUSTED` — the GIVE-UPS — so a retry gate written that
    way would loop on its own exhaustion message forever.

    Returns False for `IO_ERROR`, `EOF_MID_RESPONSE`, `H2_STREAM_RESET`,
    `TIMEOUT` and every server status: none of those carry the guarantee."""
    return H2_RETRYABLE_TRANSPORT_TOKEN in msg


def allocate_client_stream_id_or_raise(
    mut h2: H2ClientConnectionState,
) raises -> UInt32:
    """`allocate_client_stream_id`, turned into a REFUSAL at the call site.

    RFC 9113 §5.1.1: "Stream identifiers cannot be reused. ... A client that
    is unable to establish a new stream identifier can establish a new
    connection for new streams." The allocator answers exhaustion with
    `H2_STREAM_ID_EXHAUSTED`; every site that is about to build a REQUEST
    must turn that into an error rather than open a stream numbered 0.

    ⚠ THE CLASS IS A PROOF, NOT A LABEL (see `is_h2_retryable_transport`).
    This branch raises BEFORE a single request byte is encoded, so the peer
    has provably taken no action and re-issuing on a NEW connection — which
    is precisely §5.1.1's own remedy — is safe even for a non-idempotent
    verb. That is what licenses the token here."""
    var sid = h2.allocate_client_stream_id()
    if sid == H2_STREAM_ID_EXHAUSTED:
        raise Error(
            H2_RETRYABLE_TRANSPORT_TOKEN
            + ": this h2 connection has spent its 31-bit client stream-id"
            " space (RFC 9113 §5.1.1 — identifiers cannot be reused); nothing"
            " was sent, so re-issue on a NEW connection"
        )
    return sid


# =============================================================================
# `_park_on_fd_readiness` is DELETED.
# =============================================================================
#
# Its body — the bounded slice, invariant (ii)'s re-poll, the buffered-
# plaintext guard, the `ready` vs idle return, and asking the stream for the
# wait direction — IS `komira_http.transport.stream_park.park_on_pending`,
# which is now the only way any driver in this repo waits on a stream. It was
# the ONE of the four park helpers that already asked the conformer; the
# collapse moved that property to the other two rather than copying it.
#
# Two things this file used to own are now DERIVED inside the primitive and no
# longer expressible at a call site:
#   * the wait DIRECTION — there is no parameter for it; it is
#     `stream.pending_wait_is_write(token, call_is_write)`, computed there.
#   * `buffered_shortcut_ok` — it was never a free parameter. This file's own
#     docstring said its only correct value is "the pending I/O itself was a
#     read", i.e. `not call_is_write`, which is what the primitive computes.
#
# The slice budget stays a parameter, because it is genuinely per-driver:
# `_H2_PARK_DEADLINE_US` / `_H2_POLLS_PER_SLICE_CAP` are passed below.
# =============================================================================


def drive_h2_streams_to_completion[
    S: IoStream, RT: Runtime,
](
    mut h2: H2ClientConnectionState,
    mut stream: S,
    mut reactor: Reactor[RT.Sink],
    var await_stream_ids: List[UInt32],
    max_iterations: Int = 100_000,
    max_wall_us: Int64 = _H2_DRIVE_DEFAULT_WALL_US,
) raises:
    """Drive `stream` + `h2` together until every stream-id in
    `await_stream_ids` has `streams[idx].end_stream_seen == True`.

    Loop body per iteration:
      1. If `h2.pending_out` has bytes, try to write a chunk via
         `stream.try_write[RT]`. On Pending: PARK on write-readiness (bounded)
         then re-attempt.
      2. Else if any awaited stream is not yet complete, try to read a
         chunk via `stream.try_read[RT]`. On Pending: PARK on read-readiness
         (bounded) then re-attempt. On Ready(n): append to h2.recv_buf + call
         process_received_frames.
      3. Check completion: if every await_stream_ids[i] now has
         end_stream_seen, return.

    the drive is bounded by BOTH an iteration cap
    AND a WALL-CLOCK deadline (`max_wall_us`, monotonic). The wall-clock bound is
    the load-bearing addition that closes the multi-chunk object-store read
    hang: each Pending now parks on a BOUNDED reactor wait (see
    `transport.stream_park.park_on_pending`), so control always returns to this
    loop; the loop
    then checks elapsed wall-time and RAISES `HttpError[TIMEOUT]` on a wedged /
    unresponsive conn instead of hanging forever. WITHOUT the wall-clock bound,
    a conn that parks-then-repolls-Pending in a tight cycle would burn the
    iteration cap at ~one park-deadline per iter (cap × park_deadline of total
    wall-time) — the wall-clock check makes the overall deadline a real,
    configurable wall bound independent of the per-park granularity.

    NO FALSE TIMEOUT: a healthy RPC reaches END_STREAM in µs..ms — orders of
    magnitude under the default wall bound (120s); a slow-but-progressing RPC
    keeps making read progress and resets nothing it needs. The wall bound only
    fires on a conn that produces NO progress for the whole interval — i.e. the
    wedge this fix targets.

    Errors:
      * On EOF mid-response: raises HttpError[EOF_MID_RESPONSE].
      * On STREAM_IO_ERROR reading: raises HttpError[IO_ERROR].
      * On STREAM_IO_ERROR **writing, before any response byte has arrived**:
        raises **HttpError[RETRYABLE_TRANSPORT]** — see the write branch. The
        peer went away while the request was still going out, which is the
        reaped-pooled-connection race and is exactly the disposition h1 already
        gives it (`state_machine._drive_read_head`: "peer closed before any
        response byte"). A write error AFTER response bytes have arrived stays
        HttpError[IO_ERROR]: the request may have been executed.
      * On GOAWAY received with awaited stream_id > goaway_last_stream_id:
        raises HttpError[H2_PROTOCOL] (stream will not be processed).
      * On RST_STREAM received for an awaited stream: raises
        **HttpError[RETRYABLE_TRANSPORT]** for REFUSED_STREAM (RFC 9113 §8.7 —
        definitively not processed) and **HttpError[H2_STREAM_RESET]** for
        every other code. An inbound RST recorded as `end_stream_seen` would make
        this function RETURN, handing the caller a silently truncated 200; see
        `H2ClientStream.reset_error_code`.
      * On the wall-clock deadline: raises HttpError[TIMEOUT] — the drive
        genuinely WAITED and the peer produced nothing.
      * On the iteration cap, or on `_H2_READY_NO_PROGRESS_CAP` consecutive
        zero-progress READY parks: raises **HttpError[LIVELOCK]** (not
        `[TIMEOUT]`, which would read as a slow peer). Both mean the loop SPUN; neither is a wall-clock event.
        `HttpError[LIVELOCK]` is connection-level and re-dialable — it is in
        the GCS client's retryable-connection set in `komira_gcp_bridge`.

    Encapsulation: no UnsafePointer; no wildcard; uses only IoStream
    methods + h2's public API.
    """
    # H2-TLS-WHOLE-RECORD-READ: the per-read scratch MUST be at
    # least one max TLS record (16 KiB plaintext, RFC 8446 §5.1) — we size it to a
    # few records so `stream.try_read` drains whole decrypted records per call,
    # never a sub-record fragment.
    #
    # WHY: a
    # 4096-byte scratch makes the driver read the TLS conn in sub-record chunks. On
    # a REUSED HTTP/2 conn, once cumulative traffic crosses ~1 MiB (2^20) — the
    # point at which Google's frontend performs a TLS 1.3 key update / sends a
    # post-handshake record interleaved with application data — the s2n layer
    # delivers a MISALIGNED application byte stream under the sub-record read
    # pattern (the returned bytes depend on the read chunk size, which a correct
    # TLS byte stream must not). The h2 frame parser then reads response-body
    # payload as a frame header, decodes a bogus multi-MB frame length, trips
    # FRAME_SIZE_ERROR, emits a client GOAWAY — the server stops sending and the
    # stream hangs to the 120s wall deadline. The bug NEVER fires on a FRESH conn
    # (a single small response is below the rekey threshold), so small reads
    # succeed while a later large response on the reused conn (several hundred
    # KiB after many earlier reads) stalls. Reading whole records sidesteps the s2n
    # sub-record path entirely.
    var scratch_size: Int = 64 * 1024
    var scratch = List[UInt8]()
    scratch.resize(unsafe_uninit_length=scratch_size)
    var iters = 0
    # park bookkeeping, so a give-up can say
    # WHY. `idle_parks` vs `parks` is the discriminator:
    # idle_parks ~= parks means the loop genuinely WAITED
    # and the peer produced nothing (a peer/network fault); idle_parks << parks
    # means it was woken repeatedly without this fd becoming ready (a
    # reactor-side wake storm, the defect invariant (ii) closes). Neither is
    # recoverable from a bare "iteration cap exceeded".
    var parks = 0
    var idle_parks = 0
    # the LIVELOCK detector.
    # `ready_no_progress` is the CONSECUTIVE run of trips on which a park said
    # READY and the retried I/O moved zero bytes; `ready_no_progress_max` is the
    # high-water mark, kept for the give-up message so a WALL-CLOCK give-up can
    # also say whether the loop spun on its way there.
    var ready_no_progress = 0
    var ready_no_progress_max = 0
    # H2-SEND-TO-DEPARTED-PEER: total plaintext bytes this drive
    # has taken off the wire. The ONLY use is classifying a WRITE-side
    # transport error: zero means the peer went away before it answered
    # anything, which is a request that got no verdict and is therefore
    # re-issuable on a fresh connection. Mirrors h1's
    # `self._recv_buf.__len__() == 0` discriminator exactly
    # (`state_machine._drive_read_head`).
    var total_read = 0
    # ★★ WIRE-LAYER PROGRESS. `last_wire` is the last sample of
    # `stream.wire_bytes_moved()` taken on a would-be no-progress trip. The
    # counter is s2n's own `wire_bytes_in + wire_bytes_out`, so a trip on which
    # it MOVED advanced the transfer even though the application-layer I/O
    # reported nothing — see `_H2_WIRE_PROGRESS_IS_PROGRESS` above. Sampled
    # ONLY on the branches that were about to increment `ready_no_progress`,
    # never on a trip that moved application bytes.
    var last_wire = stream.wire_bytes_moved()
    # How many times wire progress vetoed a no-progress increment, and which
    # branch last incremented one. Both are printed by every give-up message:
    # `wire_resets > 0` says the connection was MOVING and the give-up is about
    # rate, not liveness; `side=` says which half to look at.
    var wire_resets = 0
    var last_no_progress_side = _H2_SIDE_NONE
    # ★★ LIVENESS-PROBE bookkeeping. See the `_H2_KEEPALIVE_*` block above.
    # `read_idle_trips` is the run of consecutive trips on which the peer
    # produced NO application bytes and the wire did not move; it is reset by
    # any inbound byte. `read_idle_since_ns` is the same fact on the wall
    # clock. `keepalive_idle_trips` is the run accumulated SINCE an unanswered
    # probe was staged — deliberately a separate counter, so a peer that
    # dribbles unrelated bytes without ever ACKing does not keep resetting its
    # own deadline via `read_idle_trips`.
    var read_idle_trips = 0
    var read_idle_since_ns = Int64(_mono_now_ns())
    var keepalive_idle_trips = 0
    # ⛔ A PROBE IS DRIVE-SCOPED EVEN THOUGH ITS FLAG IS CONNECTION-SCOPED.
    # See `clear_keepalive_ping` — without this line a pooled connection can
    # arrive carrying a live ping deadline stamped minutes ago and be declared
    # dead on this drive's FIRST trip, having sent nothing.
    h2.clear_keepalive_ping()
    # capture the monotonic start for the wall-clock bound.
    # max_wall_us <= 0 disables the wall bound (the iteration cap still applies).
    var wall_start_ns = Int64(_mono_now_ns())
    var wall_budget_ns = max_wall_us * Int64(1000)
    # ⛔ GUARD (A), loop-invariant — see "A TRIP ANALOGUE IS NOT A DURATION"
    # above. The trip analogues may not preempt a caller whose whole budget is
    # shorter than the silence a trip-based verdict would be claiming.
    var ka_trip_analogue_admissible = (
        wall_budget_ns <= Int64(0)
        or wall_budget_ns
        > _H2_KEEPALIVE_TRIP_VERDICT_MIN_WALL_US * Int64(1000)
    )
    while True:
        iters = iters + 1
        if ready_no_progress >= _H2_READY_NO_PROGRESS_CAP:
            # THE DEFECT NAMED, NOT THE SYMPTOM COUNTED. Every one of these
            # trips was told the fd was ready in the direction the driver
            # waited on, and the I/O it then retried still could not proceed.
            # That is not a slow peer and not a small cap: it is a WAIT ON THE
            # WRONG DIRECTION (a `try_write` blocked on READ parked on write
            # readiness, or the mirror image), and it is the only condition
            # under which a bounded park can wake instantly forever.
            raise Error(
                "HttpError[LIVELOCK]: h2 driver made no progress across "
                + String(ready_no_progress)
                + " consecutive READY parks — the fd reported ready in the"
                " direction the driver waited on and the retried I/O returned"
                " Pending again, moving zero bytes. NOT a timeout and NOT a cap"
                " that is too small. Either the I/O is waiting on something"
                " this fd's readiness can never deliver (e.g. a peer that"
                " CLOSED, reported as would-block), or the wait direction is"
                " inverted."
                + " (iters=" + String(iters)
                + ", elapsed_ms=" + String(
                    (Int64(_mono_now_ns()) - wall_start_ns) // Int64(1_000_000)
                )
                + ", parks=" + String(parks)
                + ", idle_parks=" + String(idle_parks)
                # ★ ATTRIBUTION. Without these fields THIS
                # message cannot be assigned to the read half or the write
                # half. `side=` is the
                # branch that incremented the run; `total_read=` says whether
                # the peer had answered at all; `wire_resets=` says whether the
                # connection ever moved bytes on this drive.
                + ", side=" + String(_h2_side_name(last_no_progress_side))
                + ", total_read=" + String(total_read)
                + ", wire_resets=" + String(wire_resets)
                + ")"
            )
        if iters > max_iterations:
            # The evidence is the point. A bare count cannot distinguish a loop
            # that waited from one that spun, and those have opposite fixes.
            # Reaching this cap while `elapsed_ms` is small IS the spin: with
            # invariant (ii) in force an unwoken park costs real time, so a
            # genuinely waiting drive surfaces the wall-clock message below
            # instead.
            var burn_ms = (Int64(_mono_now_ns()) - wall_start_ns) // Int64(
                1_000_000
            )
            # ⚠ THE CLASS IS **NOT** `TIMEOUT`. A loop that
            # exhausts an ITERATION budget while leaving nearly all of its WALL
            # budget unspent did not time out — it spun, and reporting a
            # timeout sends every reader of this message looking for a slow
            # peer that does not exist. With the
            # park bounded at `_H2_PARK_DEADLINE_US` a genuinely waiting drive
            # completes at most ~`wall/park_deadline` trips and CANNOT reach
            # `max_iterations`, so arriving here is itself proof of a spin.
            # The substring "iteration cap exceeded" is preserved verbatim
            # because several transport-fault classifiers match on it.
            raise Error(
                "HttpError[LIVELOCK]: h2 driver iteration cap exceeded"
                " — NOT a timeout: "
                + String(burn_ms) + "ms elapsed of a "
                + String(max_wall_us // Int64(1000))
                + "ms wall budget, so these trips did not wait"
                + " (iters=" + String(iters)
                + ", elapsed_ms=" + String(burn_ms)
                + ", wall_budget_ms=" + String(max_wall_us // Int64(1000))
                + ", parks=" + String(parks)
                + ", idle_parks=" + String(idle_parks)
                + ", max_ready_no_progress_run="
                + String(ready_no_progress_max)
                + ", side=" + String(_h2_side_name(last_no_progress_side))
                + ", total_read=" + String(total_read)
                + ", wire_resets=" + String(wire_resets)
                + ")"
            )
        # wall-clock deadline. A wedged / unresponsive conn
        # parks (bounded) + re-polls Pending each iter; this check terminates
        # the drive with a typed TIMEOUT once the wall budget elapses — the
        # antithesis of the prior infinite poll_completions(-1) hang.
        if wall_budget_ns > Int64(0):
            var elapsed_ns = Int64(_mono_now_ns()) - wall_start_ns
            if elapsed_ns > wall_budget_ns:
                raise Error(
                    "HttpError[TIMEOUT]: h2 driver wall-clock deadline"
                    " exceeded (no progress to END_STREAM within "
                    + String(max_wall_us) + "us)"
                    + " (iters=" + String(iters)
                    + ", elapsed_ms=" + String(elapsed_ns // Int64(1_000_000))
                    + ", parks=" + String(parks)
                    + ", idle_parks=" + String(idle_parks)
                    + ", max_ready_no_progress_run="
                    + String(ready_no_progress_max)
                    + ", side=" + String(_h2_side_name(last_no_progress_side))
                    + ", total_read=" + String(total_read)
                    + ", wire_resets=" + String(wire_resets)
                    + ")"
                )
        # ★★ STEP 0 — THE LIVENESS PROBE. Ordered BEFORE the write drain so a
        # probe staged on this trip is flushed by Step 1 on this trip, and
        # AFTER the three budget checks.
        #
        # ⛔ THAT ORDERING IS NOT WHAT KEEPS THIS BLOCK FROM MASKING A BUDGET,
        # AND THE COMMENT THAT SAID SO WAS WRONG. Within-trip ordering decides
        # nothing when this block's deadline is reached EARLIER IN WALL TIME
        # than the caller's: the budget check above simply has not fired yet.
        # What keeps it honest is that the TRIP arms below defer to the
        # caller's wall budget — see "A TRIP ANALOGUE IS NOT A DURATION".
        if h2.is_keepalive_ping_outstanding():
            # The deadline on an unanswered probe. RFC 9113 §6.7 makes the ACK
            # mandatory, so this is a VERDICT on the connection, not a budget:
            # it names the mechanism, it is reached one ping-deadline after the
            # peer went quiet rather than at the far end of a 120s wall, and it
            # is unambiguously safe to re-dial.
            var ka_elapsed_ns = (
                Int64(_mono_now_ns()) - h2.keepalive_ping_sent_ns
            )
            var ka_expired_wall = (
                ka_elapsed_ns > _H2_KEEPALIVE_PING_TIMEOUT_US * Int64(1000)
            )
            # ⛔ THE TRIP BACKSTOP, UNDER BOTH GUARDS. See "A TRIP ANALOGUE
            # IS NOT A DURATION" above: unguarded, this arm declared the
            # connection dead ~780 ms inside a budget the caller had
            # already stated, on nothing but a darwin trip rate.
            var ka_expired_trips = (
                keepalive_idle_trips >= _H2_KEEPALIVE_PING_TIMEOUT_TRIPS
                and ka_trip_analogue_admissible
                and ka_elapsed_ns
                < _H2_KEEPALIVE_FREE_PARK_PROOF_US * Int64(1000)
            )
            if ka_expired_wall or ka_expired_trips:
                # ⚠ THE CLASS IS `TIMEOUT`, DELIBERATELY, AND IT IS NOT A NEW
                # ONE. Every caller that re-dials a wedged h2 conn keys on a
                # CLOSED set of typed prefixes
                # (the GCS client's retryable-connection set in `komira_gcp_bridge`,
                # `komira_aws_s3._is_retryable_transport`). A connection whose
                # peer stopped answering is the textbook member of that set, so
                # minting `HttpError[KEEPALIVE]` here would have SILENTLY
                # REMOVED this fault from every retry policy in the tree — a
                # strictly worse outcome than the 120s wall it replaces. The
                # disposition is unchanged; what changed is that the message
                # now names a cause instead of a budget.
                #
                # ⛔ AND IT CARRIES NO `parks=` / `idle_parks=` COUNTER. Only
                # this driver's SPIN give-ups print one, and a falsifier reads
                # their absence as "the loop did not burn a budget to discover
                # something it could have asked about"
                # (`test_L2_h2_over_tls_abrupt_close_no_spin
                # ._assert_did_not_spin`). This raise is the asking.
                raise Error(
                    "HttpError[TIMEOUT]: h2 keepalive PING went UNANSWERED"
                    " for " + String(ka_elapsed_ns // Int64(1_000_000))
                    + "ms — the connection is OPEN and the peer's HTTP/2 layer"
                    " is not responding (RFC 9113 §6.7 makes the ACK"
                    " mandatory, so a peer that does not send one is broken,"
                    " not merely slow). The connection is dead; re-dial. This"
                    " is a liveness verdict, NOT an expired budget: it names"
                    " the probe that failed rather than the loop that waited."
                    + " (silent_for_ms=" + String(
                        (Int64(_mono_now_ns()) - read_idle_since_ns)
                        // Int64(1_000_000)
                    )
                    + ", ping_deadline_ms="
                    + String(_H2_KEEPALIVE_PING_TIMEOUT_US // Int64(1000))
                    + ", response_bytes=" + String(total_read) + ")"
                )
        elif len(await_stream_ids) > 0 and len(h2.pending_out) == 0:
            # Arm a probe. Gated on `pending_out` being EMPTY on purpose: if we
            # still have bytes queued, the connection's problem is our own
            # un-drained write (a full send buffer, a blocked TLS flush), and
            # appending a PING to a queue that is not draining diagnoses
            # nothing while adding to the backlog. "We have nothing left to
            # say and the peer is saying nothing" is the ONLY shape this probe
            # is a question about.
            var idle_ns = Int64(_mono_now_ns()) - read_idle_since_ns
            var arm_wall = idle_ns > _H2_KEEPALIVE_READ_IDLE_US * Int64(1000)
            # Same two guards as the verdict: a probe this drive can never
            # act on is a frame we had no question to ask with.
            var arm_trips = (
                read_idle_trips >= _H2_KEEPALIVE_READ_IDLE_TRIPS
                and ka_trip_analogue_admissible
                and idle_ns < _H2_KEEPALIVE_FREE_PARK_PROOF_US * Int64(1000)
            )
            if arm_wall or arm_trips:
                # The opaque data is the send timestamp, so successive probes
                # DIFFER — which is what lets `note_ping_ack` reject a stale
                # ACK answering a probe from an earlier drive rather than let
                # it certify a connection nobody proved alive.
                var stamp = Int64(_mono_now_ns())
                var probe = SIMD[DType.uint8, 8](0)
                var bi = 0
                while bi < 8:
                    probe[bi] = UInt8((stamp >> Int64(8 * bi)) & Int64(0xFF))
                    bi = bi + 1
                h2.stage_keepalive_ping(probe, stamp)
                keepalive_idle_trips = 0
        # pump any pending request
        # body into `pending_out` as flow-control-sized DATA frames. On the
        # first iteration this stages the initial window's worth (if the caller
        # left a large body queued via `stage_request_body`); on later iterations
        # it refills the moment a server WINDOW_UPDATE (applied by Step 3's
        # `process_received_frames`) reopens the send window — the forward-
        # progress engine that lets an arbitrarily large upload reach END_STREAM.
        # No-op (early len() check) once every body is fully framed.
        if has_pending_request_bodies(h2):
            pump_pending_request_bodies(h2)
        # Step 1: drain pending_out if any.
        if len(h2.pending_out) > 0:
            var out_view = Span[UInt8](h2.pending_out).as_imm()
            var wres = stream.try_write[RT](reactor, out_view)
            if wres._state == STREAM_IO_READY:
                var n = Int(wres._payload)
                h2.consume_out_bytes_prefix(n)
                # Bytes moved => this trip made progress. A READY that accepted
                # ZERO bytes did not, and is counted as such: it is the one
                # shape that loops without ever reaching a park.
                if n > 0:
                    ready_no_progress = 0
                else:
                    # ★ WIRE-LAYER VETO. See `_H2_WIRE_PROGRESS_IS_PROGRESS`.
                    var wire_now = stream.wire_bytes_moved()
                    if wire_now != last_wire:
                        last_wire = wire_now
                        wire_resets = wire_resets + 1
                        ready_no_progress = 0
                    else:
                        last_no_progress_side = _H2_SIDE_WRITE_READY_ZERO
                        ready_no_progress = ready_no_progress + 1
                        if ready_no_progress > ready_no_progress_max:
                            ready_no_progress_max = ready_no_progress
                continue
            if wres._state == STREAM_IO_PENDING:
                # The socket's send buffer is full (EWOULDBLOCK on write). Under
                # an async runtime the scheduler's poll loop drives the reactor
                # and wakes us; under a SYNCHRONOUS drive (e.g. a BlockingRuntime
                # one-shot, or the plaintext h2c emulator path) NOTHING else
                # drives the reactor — a bare `continue` busy-spins the iteration
                # cap to a spurious TIMEOUT before the kernel drains the buffer.
                # PARK on write-readiness for ONE wake (the same self-driving
                # park the TLS handshake loop uses), then re-attempt. Guarded on
                # a real fd (>=0); scripted/socketpair streams (fd<0) fall back
                # to the bounded busy-loop.
                #
                # ⚠ WE DO NOT SAY WHICH DIRECTION — `park_on_pending` asks the
                # stream. We hand it the two FACTS it needs: the Pending's
                # token and that a `try_write` produced it. A conformer whose
                # transport inverts the two (a future s2n, kTLS, QUIC, a
                # non-s2n peer) is then correct here with no edit to this loop.
                # The buffered-plaintext shortcut is likewise derived there and
                # is OFF for a write: buffered PLAINTEXT cannot unblock a write
                # that is waiting for a TLS RECORD off the socket.
                #
                # ⛔ ON s2n-tls v1.5.6 THE TWO NEVER DIFFER, so this is a
                # by-construction guard for a future conformer. An abrupt peer
                # close laundered into Pending one layer down is a different
                # cause; see `s2n_shim._recv_outcome_and_n`.
                parks = parks + 1
                if not park_on_pending[S, RT](
                    stream, reactor,
                    pending_token=wres._payload, call_is_write=True,
                    slice_us=_H2_PARK_DEADLINE_US,
                    polls_per_slice_cap=_H2_POLLS_PER_SLICE_CAP,
                ):
                    idle_parks = idle_parks + 1
                    ready_no_progress = 0
                else:
                    # ★ WIRE-LAYER VETO, and this is the branch it was written
                    # for. `s2n_send`'s leading `POSIX_GUARD(s2n_flush(...))`
                    # returns -1/BLOCKED with ZERO plaintext accepted while
                    # that flush pushes real bytes onto a slow-draining
                    # socket, so pre-fix a congested upload reached the cap on
                    # a connection that was transferring the whole time.
                    var wire_now = stream.wire_bytes_moved()
                    if wire_now != last_wire:
                        last_wire = wire_now
                        wire_resets = wire_resets + 1
                        ready_no_progress = 0
                    else:
                        last_no_progress_side = _H2_SIDE_WRITE_PARK
                        ready_no_progress = ready_no_progress + 1
                        if ready_no_progress > ready_no_progress_max:
                            ready_no_progress_max = ready_no_progress
                continue
            if wres._state == STREAM_IO_ERROR:
                # ★ THE CLASS IS THE DISPOSITION, AND A WRITE ERROR BEFORE ANY
                # RESPONSE BYTE IS RE-ISSUABLE. This branch became
                # REACHABLE when `s2n_shim._error_typed_outcome` stopped
                # laundering a `write(2)` EPIPE/ECONNRESET into
                # BLOCKED_ON_WRITE; before that the same state SPUN to
                # `HttpError[LIVELOCK]`, which IS in the connection-level retry
                # set (the GCS client's retryable-connection set in `komira_gcp_bridge`).
                # Emitting a bare `IO_ERROR` here — which is NOT in that set —
                # would have fixed the spin by converting a fault that got
                # retried into one that fails the request outright. That is a
                # worse outcome, not a better one, so the class has to carry
                # the same disposition the spin accidentally did.
                #
                # `total_read == 0` is the discriminator, and it is the one h1
                # already uses for the mirror-image event on the read side
                # ("HttpError[RETRYABLE_TRANSPORT]: peer closed before any
                # response byte", `state_machine._drive_read_head`). Zero bytes
                # off the wire means the peer never answered, so re-issuing on
                # a fresh connection cannot duplicate an effect this
                # connection's peer reported. Once ANY response byte has
                # arrived the peer was talking to us, the request may have been
                # executed, and the class stays IO_ERROR — deliberately NOT
                # retryable.
                #
                # ⚠ NEITHER MESSAGE CARRIES A `parks=` / `iters=` COUNTER, AND
                # THAT IS DELIBERATE. Only this driver's SPIN give-ups (the
                # iteration cap, the wall clock, the livelock detector) print
                # one, and a falsifier asserts `"parks=" not in msg` to mean
                # "the loop did not burn a budget to discover something the
                # transport had already told it"
                # (`test_L2_h2_over_tls_abrupt_close_no_spin
                # ._assert_did_not_spin`). A classified transport raise that
                # printed one would defeat that assertion.
                if total_read == 0:
                    raise Error(
                        "HttpError[RETRYABLE_TRANSPORT]: h2 driver write"
                        " errno=" + String(Int(wres._payload))
                        + " with ZERO response bytes received — the peer went"
                        " away while the request was still being written (the"
                        " reaped-pooled-connection race). The request got no"
                        " verdict, so re-issuing it on a fresh connection is"
                        " safe."
                    )
                raise Error(
                    "HttpError[IO_ERROR]: h2 driver write errno="
                    + String(Int(wres._payload))
                    + " after " + String(total_read)
                    + " response bytes — the peer answered before the write"
                    " failed, so the request MAY have been executed and this"
                    " is deliberately not in the connection-level retry set"
                )
            # EOF on write side is impossible.
            raise Error("HttpError[IO_ERROR]: h2 driver write returned EOF")

        # Step 2: check completion BEFORE issuing another read.
        var awaited_n = len(await_stream_ids)
        var all_done = True
        var ai = 0
        while ai < awaited_n:
            var sid = await_stream_ids[ai]
            var idx = h2.find_stream_idx(sid)
            if idx < 0:
                # Stream was reset / never created — treat as done with
                # caller's responsibility to extract_response.
                ai = ai + 1
                continue
            # ★ A RESET STREAM HAS NO RESPONSE, AND USED TO LOOK LIKE A GOOD
            # ONE. If `process_received_frames` answered an inbound
            # RST_STREAM by setting `end_stream_seen`, the loop below would fall
            # straight through to `return` and the caller's
            # `extract_response_for_stream` would hand up a truncated body with a
            # 200. python-hyper `h2` reads the same bytes as
            # `StreamReset` with END_STREAM false.
            #
            # THE CLASS IS THE DISPOSITION, exactly as at the GOAWAY branch
            # below. RFC 9113 §8.7 gives REFUSED_STREAM the same definitive
            # not-processed guarantee GOAWAY-above-Last-Stream-ID has, so it is
            # re-issuable even for a non-idempotent verb. Every other code
            # means the peer MAY have executed the request before it gave up,
            # so it gets a class that is deliberately in NO retry set.
            if h2.streams[idx].reset_error_code >= Int64(0):
                var rst_code = UInt32(Int(h2.streams[idx].reset_error_code))
                if h2.streams[idx].reset_is_local:
                    # WE reset this stream (RFC 9113 §6.9 stream-scoped
                    # FLOW_CONTROL_ERROR: the peer overran THIS stream's
                    # receive window while staying inside the connection
                    # window). Reporting it as "server sent RST_STREAM" would
                    # name the wrong party and send the reader looking at the
                    # peer. The connection itself is healthy, so this is not a
                    # connection-level retry class either.
                    raise Error(
                        "HttpError[H2_STREAM_RESET]: this client sent"
                        " RST_STREAM(" + String(Int(rst_code)) + ") on stream "
                        + String(Int(sid))
                        + " — the peer sent more DATA than stream "
                        + String(Int(sid))
                        + "'s receive window allowed (RFC 9113 §6.9), so the"
                        " response is INCOMPLETE. The CONNECTION was not torn"
                        " down and its other streams are unaffected."
                    )
                if rst_code == H2_ERR_REFUSED_STREAM:
                    raise Error(
                        "HttpError[RETRYABLE_TRANSPORT]: server sent"
                        " RST_STREAM(REFUSED_STREAM) on stream "
                        + String(Int(sid))
                        + " — RFC 9113 §8.7: the peer definitively did NOT"
                        " process this request, so re-issuing it on a new"
                        " connection is safe even for a non-idempotent verb"
                    )
                # ⚠ EITHER SIDE MAY HAVE SENT IT, so the prose does not name
                # one. `process_received_frames` records this code both when
                # the SERVER sends RST_STREAM and when WE answer a
                # STREAM-scoped decode error on this stream with an RST of our
                # own; the disposition is identical in both cases (the peer was
                # mid-response, so it may well have executed the request), and
                # a message that asserted "server sent" would be a false lead
                # half the time.
                raise Error(
                    "HttpError[H2_STREAM_RESET]: stream "
                    + String(Int(sid))
                    + " was RESET with error code "
                    + String(Int(rst_code))
                    + " — the response is INCOMPLETE. This is NOT in the"
                    " connection-level retry set: outside REFUSED_STREAM the"
                    " peer may have executed the request before the reset, so"
                    " a caller that wants to retry must decide that for its"
                    " own verb."
                )
            # ★ A MALFORMED RESPONSE IS A GIVE-UP, NOT A WAIT.
            # `_refuse_malformed_response` has already sent
            # RST_STREAM(PROTOCOL_ERROR) and closed the stream, so END_STREAM
            # will never arrive on it. WITHOUT this branch the loop would park
            # on a stream the client itself reset and surface
            # `HttpError[TIMEOUT]` at the 120s wall — a silent stall arrived at
            # from the opposite direction. H2_PROTOCOL because that is what it is: the
            # peer sent a message RFC 9113 §8.1.1 forbids. Deliberately NOT in
            # any retry set — a re-issue would be answered by the same broken
            # origin with the same broken message.
            if h2.streams[idx].malformed_scope != H2_MALFORMED_SCOPE_NONE:
                raise Error(
                    "HttpError[H2_PROTOCOL]: the response on stream "
                    + String(Int(sid))
                    + " is MALFORMED — "
                    + h2_malformed_reason_text(
                        h2.streams[idx].malformed_reason
                    )
                    + ". RFC 9113 §8.1.1 requires a stream error of type"
                    " PROTOCOL_ERROR; the client sent RST_STREAM and refused"
                    " the message rather than delivering it."
                )
            if not h2.streams[idx].end_stream_seen:
                # GOAWAY check: if server emitted GOAWAY and this stream
                # has id > last_processed, it WILL NOT complete. Raise.
                #
                # THE TOKEN IS THE POINT. This branch — and only this branch —
                # has established `sid > Last-Stream-ID`, which is RFC 9113
                # §6.8's definitive not-processed guarantee. Stamping
                # `H2_GOAWAY_UNPROCESSED_TOKEN` here is what lets a caller
                # above re-issue the request safely without re-deriving the
                # comparison from a string. A caller that instead matched
                # "GOAWAY" would also match the at-or-below class below, where
                # the guarantee does NOT hold.
                if h2.is_goaway_received():
                    if sid > h2.goaway_last_stream_id:
                        raise Error(
                            "HttpError[H2_PROTOCOL]: GOAWAY received;"
                            " stream " + String(Int(sid))
                            + " > last_stream_id "
                            + String(Int(h2.goaway_last_stream_id))
                            + "; will not be processed ["
                            + H2_GOAWAY_UNPROCESSED_TOKEN
                            + "] — RFC 9113 §6.8: the peer definitively did"
                            " NOT process this stream, so re-issuing it on a"
                            " NEW connection is safe even for a non-idempotent"
                            " verb"
                            + h2_goaway_context(h2)
                        )
                all_done = False
                break
            ai = ai + 1
        if all_done:
            return

        # Step 3: read a chunk into scratch + drain into h2.
        var rres = stream.try_read[RT](reactor, Span[UInt8](scratch))
        if rres._state == STREAM_IO_PENDING:
            # No data yet (EWOULDBLOCK on read). As with the write branch above,
            # a bare `continue` busy-spins the iteration cap under a synchronous
            # drive before the server's response bytes land on the socket. PARK
            # on read-readiness for ONE wake, then re-attempt. Guarded on a real
            # fd (>=0); scripted/socketpair streams fall back to the busy-loop.
            #
            # ⚠ SAME RULE AS THE WRITE BRANCH: we state that a `try_read`
            # produced this Pending and let `park_on_pending` derive both the
            # direction and the buffered-plaintext shortcut (ON here — the
            # pending I/O IS a read, so already-decrypted plaintext genuinely
            # makes the retry productive).
            # (`s2n_recv` returning BLOCKED_ON_WRITE does not happen on
            # s2n-tls v1.5.6; the rule stands for the conformer that eventually
            # does it.)
            parks = parks + 1
            if not park_on_pending[S, RT](
                stream, reactor,
                pending_token=rres._payload, call_is_write=False,
                slice_us=_H2_PARK_DEADLINE_US,
                polls_per_slice_cap=_H2_POLLS_PER_SLICE_CAP,
            ):
                idle_parks = idle_parks + 1
                ready_no_progress = 0
                # ★★ READ-IDLE, and this is the branch a silent peer takes:
                # the park WAITED OUT its full slice and the peer still said
                # nothing. `ready_no_progress` is reset here (the loop is not
                # spinning — it genuinely waited), which is exactly why a
                # separate counter is needed: the connection being silent and
                # the loop being wedged are different facts, and only the
                # former is what a keepalive answers.
                read_idle_trips = read_idle_trips + 1
                keepalive_idle_trips = keepalive_idle_trips + 1
            else:
                # ★ WIRE-LAYER VETO. `s2n_recv` cannot complete a record until
                # every one of its TCP segments has landed; each intermediate
                # segment makes the fd ready and adds to `wire_bytes_in` while
                # returning no plaintext.
                var wire_now = stream.wire_bytes_moved()
                if wire_now != last_wire:
                    last_wire = wire_now
                    wire_resets = wire_resets + 1
                    ready_no_progress = 0
                    # The wire MOVED: the peer is transferring, so it is not
                    # silent and there is nothing to probe.
                    read_idle_trips = 0
                    read_idle_since_ns = Int64(_mono_now_ns())
                else:
                    last_no_progress_side = _H2_SIDE_READ_PARK
                    ready_no_progress = ready_no_progress + 1
                    if ready_no_progress > ready_no_progress_max:
                        ready_no_progress_max = ready_no_progress
                    read_idle_trips = read_idle_trips + 1
                    keepalive_idle_trips = keepalive_idle_trips + 1
            continue
        if rres._state == STREAM_IO_ERROR:
            # ★★ THE READ HALF OF THE DISPOSITION RULE. The WRITE branch above
            # has a `total_read == 0` discriminator, because a transport error before
            # any response byte means the peer never answered and the request
            # is therefore re-issuable. A bare `IO_ERROR` here is in NO retry
            # set — so a pooled connection reaped by a load balancer would fail
            # the request OUTRIGHT instead of being re-dialled.
            #
            # Socketpair spin fixtures structurally cannot reach it: over AF_UNIX the strongest departure a peer
            # can make is `close(2)`, which surfaces here as EOF (the branch
            # below), never as ERROR. A real TCP **RST** — what a load balancer
            # or a GFE actually sends when it reaps a pooled connection —
            # surfaces as ECONNRESET and lands HERE.
            #
            # The discriminator is the one h1 already uses for the mirror event
            # ("peer closed before any response byte",
            # `state_machine._drive_read_head`) and the one the write branch
            # above uses. Once ANY response byte has arrived the peer was
            # talking to us, the request may have been executed, and the class
            # stays IO_ERROR — deliberately NOT retryable.
            #
            # ⚠ `s2n_errno=`, NOT `errno=`. The payload is `last_s2n_errno()`
            # (`TlsClientStream._map_tls_outcome_to_stream_io` ->
            # `StreamIo.error(Int64(Int(last_s2n_errno())))`), i.e. an s2n
            # error CODE: e.g. `67108864` is `0x04000000`, the
            # `S2N_ERR_T_IO` base, and there is no POSIX errno 67108864.
            # Calling it `errno` sends every reader to the wrong table.
            #
            # ⚠ NEITHER MESSAGE CARRIES A `parks=` / `iters=` COUNTER, AND THAT
            # IS DELIBERATE — only the driver's SPIN give-ups do, and a
            # falsifier asserts `"parks=" not in msg` to mean "the loop did not
            # burn a budget to discover something the transport had already
            # told it".
            if total_read == 0:
                raise Error(
                    "HttpError[RETRYABLE_TRANSPORT]: h2 driver read"
                    " s2n_errno=" + String(Int(rres._payload))
                    + " with ZERO response bytes received — the peer went away"
                    " before answering (the reaped-pooled-connection race; a"
                    " TCP RST lands here rather than on the EOF path). The"
                    " request got no verdict, so re-issuing it on a fresh"
                    " connection is safe."
                )
            raise Error(
                "HttpError[IO_ERROR]: h2 driver read s2n_errno="
                + String(Int(rres._payload))
                + " after " + String(total_read)
                + " response bytes — the peer had already answered, so the"
                " request MAY have been executed and this is deliberately not"
                " in the connection-level retry set"
            )
        if rres._state == STREAM_IO_EOF:
            # Peer closed mid-response. If all in-flight streams are
            # done at this point, that's actually OK (graceful close);
            # we handled completion above. Hitting EOF here means at
            # least one awaited stream is incomplete.
            #
            # THE OTHER HALF OF THE GOAWAY DISCRIMINATOR. Reaching here WITH a
            # GOAWAY received means every awaited stream is AT-OR-BELOW
            # `Last-Stream-ID` — the branch above already raised for any stream
            # above it. RFC 9113 §6.8 gives NO not-processed guarantee for that
            # range ("activity on streams numbered lower or equal ... might
            # still complete successfully"), so this must NOT be auto-retried:
            # the request may have been executed. Naming the class explicitly
            # is what stops a future "just retry GOAWAYs" change from silently
            # duplicating a non-idempotent verb.
            if h2.is_goaway_received():
                raise Error(
                    "HttpError[EOF_MID_RESPONSE]: peer closed while h2 streams"
                    " in flight, after GOAWAY last_stream_id="
                    + String(Int(h2.goaway_last_stream_id))
                    + "; the awaited stream(s) are AT-OR-BELOW it ["
                    + H2_GOAWAY_MAYBE_PROCESSED_TOKEN
                    + "] — RFC 9113 §6.8 gives no not-processed guarantee in"
                    " that range, so this request MUST NOT be auto-retried"
                    + h2_goaway_context(h2)
                )
            raise Error(
                "HttpError[EOF_MID_RESPONSE]: peer closed while h2"
                " streams in flight"
            )
        # READY — append scratch[:n] to recv_buf.
        var n_read = Int(rres._payload)
        # Bytes off the wire are the definition of progress on this loop.
        total_read = total_read + n_read
        if n_read > 0:
            ready_no_progress = 0
            # ★★ The peer SPOKE. That is the one event that clears the silence
            # this drive is measuring, on both budgets.
            read_idle_trips = 0
            read_idle_since_ns = Int64(_mono_now_ns())
        else:
            # ★ WIRE-LAYER VETO. See `_H2_WIRE_PROGRESS_IS_PROGRESS`.
            var wire_now_r = stream.wire_bytes_moved()
            if wire_now_r != last_wire:
                last_wire = wire_now_r
                wire_resets = wire_resets + 1
                ready_no_progress = 0
                read_idle_trips = 0
                read_idle_since_ns = Int64(_mono_now_ns())
            else:
                last_no_progress_side = _H2_SIDE_READ_READY_ZERO
                ready_no_progress = ready_no_progress + 1
                if ready_no_progress > ready_no_progress_max:
                    ready_no_progress_max = ready_no_progress
                read_idle_trips = read_idle_trips + 1
                keepalive_idle_trips = keepalive_idle_trips + 1
        h2.append_recv_bytes(Span(scratch)[:n_read])
        _ = process_received_frames(h2)
        # Loop will re-check completion + pending_out (process_received_frames
        # may have queued e.g. SETTINGS-ACK / WINDOW_UPDATE / PING-ACK).
        continue

