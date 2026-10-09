# =============================================================================
# src/komira_http_core/codec/h2/stream.mojo — RFC 9113 §5.1 stream state machine
# =============================================================================
#
#
# Per-stream state + transition matrix. CONTINUATION reassembly logic
# (HEADERS + CONTINUATION* → one header block).
#
# No UnsafePointer in any public sig. No wildcard origin.
# =============================================================================

from komira_http_core.codec.h2.frame import (
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FRAME_CONTINUATION,
    FRAME_DATA,
    FRAME_HEADERS,
    FRAME_PRIORITY,
    FRAME_RST_STREAM,
    FRAME_WINDOW_UPDATE,
    H2_ERR_PROTOCOL_ERROR,
    H2_ERR_STREAM_CLOSED,
)


# =============================================================================
# §1 — Stream state discriminator (RFC 9113 §5.1).
# =============================================================================

comptime STREAM_STATE_IDLE: UInt8 = 0
comptime STREAM_STATE_RESERVED_LOCAL: UInt8 = 1
comptime STREAM_STATE_RESERVED_REMOTE: UInt8 = 2
comptime STREAM_STATE_OPEN: UInt8 = 3
comptime STREAM_STATE_HALF_CLOSED_LOCAL: UInt8 = 4   # we sent END_STREAM
comptime STREAM_STATE_HALF_CLOSED_REMOTE: UInt8 = 5  # peer sent END_STREAM
comptime STREAM_STATE_CLOSED: UInt8 = 6


# =============================================================================
# §2 — Stream action discriminator (driver decides on-wire response).
# =============================================================================

comptime H2_STREAM_ACTION_KEEP: UInt8 = 0    # accept frame, no on-wire reply needed
comptime H2_STREAM_ACTION_RST: UInt8 = 1     # send RST_STREAM with action.error_code
comptime H2_STREAM_ACTION_GOAWAY: UInt8 = 2  # send GOAWAY + close connection


@fieldwise_init
struct StreamAction(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    """The driver's response to a stream-state event.

    `kind` is H2_STREAM_ACTION_*. For RST/GOAWAY, `error_code` is the
    RFC 9113 §7 error code to put on the wire."""

    var kind: UInt8
    var error_code: UInt32

    @staticmethod
    def keep() -> StreamAction:
        return StreamAction(kind=H2_STREAM_ACTION_KEEP, error_code=UInt32(0))

    @staticmethod
    def rst(error_code: UInt32) -> StreamAction:
        return StreamAction(kind=H2_STREAM_ACTION_RST, error_code=error_code)

    @staticmethod
    def goaway(error_code: UInt32) -> StreamAction:
        return StreamAction(
            kind=H2_STREAM_ACTION_GOAWAY, error_code=error_code,
        )


# =============================================================================
# §3 — StreamState.
# =============================================================================


struct StreamState(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    """One stream's state + flow-control accounting.

    POD: all fields are scalar (UInt8 / UInt32 / Int32 / Int64 / Bool).
    Copyable so `List[StreamState]` is well-typed in Mojo 1.0.0b1 (List
    requires `T: Copyable`).

    HEADERS+CONTINUATION reassembly state was moved OUT of StreamState
    onto H2ConnectionState because RFC 9113 §6.10 forbids interleaving
    CONTINUATION across different streams — at most ONE in-flight
    HEADERS sequence per CONNECTION. The connection-level reassembly
    buffer + the stream_id-being-reassembled tracker live on
    H2ConnectionState.

    `continuation_pending` is intentionally retained here as a Bool flag
    purely for the state-machine API contract (`advance_on_recv_frame`
    consults it to validate CONTINUATION arrival order on the same
    stream); the actual byte buffer lives on the connection state.

    added scalar (Copyable-safe) flow-control +
    content-length fields. Heap-owning per-stream side-tables
    (deferred-response body, pending-request headers) live on
    H2ConnectionState parallel arrays to preserve StreamState
    Copyability for `List[StreamState]` storage.
      * `expected_content_length: Int64` — set when HEADERS arrives
        with content-length AND no END_STREAM (we defer dispatch
        until END_STREAM via RFC 7540 §8.1.2.6 validation). -1 = unset.
      * `recv_data_bytes: Int64` — accumulated DATA payload bytes.
      * `has_deferred_response_body: Bool` — True iff this stream has
        un-sent DATA body bytes in the connection's deferred-body
        side table.
      * `has_pending_request: Bool` — True iff this stream's dispatch
        was deferred awaiting body bytes (RFC 7540 §8.1.2.6 content-length
        gate); the request headers + method + path live in the
        connection's pending-request side table.
      * `reset_sent: Bool` — True once this endpoint has sent RST_STREAM
        on the stream through the serve loop's stream-error path. RFC 9113
        §5.1: frames received on a closed stream after sending RST_STREAM
        MUST be ignored, while one the peer closed is answered
        STREAM_CLOSED; the state alone (CLOSED) cannot tell the two apart.
    """

    var state: UInt8
    var stream_id: UInt32
    var send_window: Int32   # SIGNED
    var recv_window: Int32
    var recv_buffered: UInt32  # bytes currently buffered (recv-ring drain accounting)
    var continuation_pending: Bool
    var end_stream_seen: Bool  # END_STREAM flag was set on a recv'd frame
    # content-length aggregation + dispatch-gating fields
    # (scalar-only to preserve StreamState Copyability; heap-owning side
    # tables live on H2ConnectionState).
    var expected_content_length: Int64  # -1 = no content-length header
    var recv_data_bytes: Int64
    var has_deferred_response_body: Bool
    var has_pending_request: Bool
    var reset_sent: Bool

    def __init__(out self, stream_id: UInt32, initial_window: Int32):
        self.state = STREAM_STATE_IDLE
        self.stream_id = stream_id
        self.send_window = initial_window
        self.recv_window = initial_window
        self.recv_buffered = UInt32(0)
        self.continuation_pending = False
        self.end_stream_seen = False
        self.expected_content_length = Int64(-1)
        self.recv_data_bytes = Int64(0)
        self.has_deferred_response_body = False
        self.has_pending_request = False
        self.reset_sent = False

    def is_terminal(self) -> Bool:
        return self.state == STREAM_STATE_CLOSED

    def advance_on_recv_frame(
        mut self,
        kind: UInt8,
        flags: UInt8,
    ) -> StreamAction:
        """Apply a recv'd frame's effect on this stream's state.

        Per RFC 9113 §5.1 transition matrix. Receiving a frame in an
        illegal state for the stream → RST_STREAM(PROTOCOL_ERROR) for
        per-stream violations, or GOAWAY(PROTOCOL_ERROR) for connection
        violations (caller distinguishes via frame type / stream_id).

        CONTINUATION frame strictness (RFC 9113 §6.10): a CONTINUATION
        MUST follow a HEADERS / PUSH_PROMISE / CONTINUATION on the same
        stream that did NOT carry END_HEADERS. A CONTINUATION at any
        other time is a connection PROTOCOL_ERROR.
        """
        if kind == FRAME_HEADERS:
            # IDLE → OPEN (or HALF_CLOSED_REMOTE if END_STREAM).
            # OPEN → unchanged.
            # CLOSED → STREAM_CLOSED error.
            if self.state == STREAM_STATE_IDLE:
                self.state = STREAM_STATE_OPEN
                if (flags & FLAG_END_STREAM) != UInt8(0):
                    self.state = STREAM_STATE_HALF_CLOSED_REMOTE
                    self.end_stream_seen = True
                if (flags & FLAG_END_HEADERS) == UInt8(0):
                    self.continuation_pending = True
                return StreamAction.keep()
            if self.state == STREAM_STATE_HALF_CLOSED_REMOTE:
                # We already saw END_STREAM; trailing HEADERS frames are
                # used for trailers in RFC 9113 §8.1 but only if we hadn't
                # seen END_STREAM. After END_STREAM the peer must not
                # send more HEADERS on this stream.
                return StreamAction.rst(H2_ERR_STREAM_CLOSED)
            if self.state == STREAM_STATE_CLOSED:
                return StreamAction.rst(H2_ERR_STREAM_CLOSED)
            # Other states accept HEADERS as a no-op for state but the
            # parser/router consumes it.
            if (flags & FLAG_END_HEADERS) == UInt8(0):
                self.continuation_pending = True
            return StreamAction.keep()

        if kind == FRAME_CONTINUATION:
            # CONTINUATION valid only if continuation_pending == True.
            if not self.continuation_pending:
                return StreamAction.goaway(H2_ERR_PROTOCOL_ERROR)
            if (flags & FLAG_END_HEADERS) != UInt8(0):
                self.continuation_pending = False
            return StreamAction.keep()

        if kind == FRAME_DATA:
            # DATA legal only in OPEN or HALF_CLOSED_LOCAL.
            if self.state != STREAM_STATE_OPEN and (
                self.state != STREAM_STATE_HALF_CLOSED_LOCAL
            ):
                return StreamAction.rst(H2_ERR_STREAM_CLOSED)
            if (flags & FLAG_END_STREAM) != UInt8(0):
                self.end_stream_seen = True
                if self.state == STREAM_STATE_OPEN:
                    self.state = STREAM_STATE_HALF_CLOSED_REMOTE
                elif self.state == STREAM_STATE_HALF_CLOSED_LOCAL:
                    self.state = STREAM_STATE_CLOSED
            return StreamAction.keep()

        if kind == FRAME_RST_STREAM:
            # RST_STREAM in IDLE → connection PROTOCOL_ERROR per RFC 9113 §6.4.
            if self.state == STREAM_STATE_IDLE:
                return StreamAction.goaway(H2_ERR_PROTOCOL_ERROR)
            self.state = STREAM_STATE_CLOSED
            return StreamAction.keep()

        if kind == FRAME_WINDOW_UPDATE:
            # WINDOW_UPDATE legal in any non-IDLE state (RFC 9113 §6.9).
            # IDLE → PROTOCOL_ERROR.
            if self.state == STREAM_STATE_IDLE:
                return StreamAction.goaway(H2_ERR_PROTOCOL_ERROR)
            return StreamAction.keep()

        if kind == FRAME_PRIORITY:
            # PRIORITY is deprecated but tolerated in any state including IDLE.
            return StreamAction.keep()

        # Other frame types are unexpected on a stream context; the caller
        # routes them at the connection level.
        return StreamAction.keep()

    def advance_on_send_end_stream(mut self):
        """Apply state change after WE send END_STREAM on this stream
        (server response done)."""
        if self.state == STREAM_STATE_OPEN:
            self.state = STREAM_STATE_HALF_CLOSED_LOCAL
        elif self.state == STREAM_STATE_HALF_CLOSED_REMOTE:
            self.state = STREAM_STATE_CLOSED

