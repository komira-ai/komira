# =============================================================================
# src/komira_http_core/codec/h2/flow_control.mojo — RFC 9113 §5.2 / §6.9 flow control
# =============================================================================
#
#
# Two-level (per-stream + per-connection) flow control:
#   * SendFlowController — send-side; signed stream send-windows; park on ≤0
#     ( — RFC 9113 §6.9.2 allows negative after retroactive
#     SETTINGS_INITIAL_WINDOW_SIZE decrease).
#   * RecvFlowController — receive-side; emits WINDOW_UPDATE at ring-drain
#     time.
#
# No UnsafePointer in any public sig. No wildcard origin.
# =============================================================================

from komira_http_core.codec.h2.frame import (
    H2_ERR_FLOW_CONTROL_ERROR,
    H2_ERR_PROTOCOL_ERROR,
)


# =============================================================================
# §1 — FlowResult discriminator.
# =============================================================================

comptime FLOW_RESULT_OK: UInt8 = 0
comptime FLOW_RESULT_RST_STREAM: UInt8 = 1     # per-stream WINDOW_UPDATE error
comptime FLOW_RESULT_GOAWAY: UInt8 = 2         # connection WINDOW_UPDATE error
comptime FLOW_RESULT_FLOW_CONTROL_ERROR: UInt8 = 3  # overflow on either side


@fieldwise_init
struct FlowResult(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    """Outcome of a flow-control state event.

    Fields:
      kind        — FLOW_RESULT_*
      error_code  — H2 error code to send on the wire (only for non-OK)
      stream_id   — affected stream (0 = connection-level)
    """
    var kind: UInt8
    var error_code: UInt32
    var stream_id: UInt32

    @staticmethod
    def ok() -> FlowResult:
        return FlowResult(
            kind=FLOW_RESULT_OK, error_code=UInt32(0), stream_id=UInt32(0),
        )

    @staticmethod
    def rst(stream_id: UInt32, error_code: UInt32) -> FlowResult:
        return FlowResult(
            kind=FLOW_RESULT_RST_STREAM,
            error_code=error_code,
            stream_id=stream_id,
        )

    @staticmethod
    def goaway(error_code: UInt32) -> FlowResult:
        return FlowResult(
            kind=FLOW_RESULT_GOAWAY,
            error_code=error_code,
            stream_id=UInt32(0),
        )

    @staticmethod
    def flow_control_error(stream_id: UInt32) -> FlowResult:
        return FlowResult(
            kind=FLOW_RESULT_FLOW_CONTROL_ERROR,
            error_code=H2_ERR_FLOW_CONTROL_ERROR,
            stream_id=stream_id,
        )


# Default initial window size per RFC 9113 §6.5.2.
comptime H2_INITIAL_WINDOW_SIZE_DEFAULT: Int32 = Int32(65535)
comptime H2_MAX_WINDOW_SIZE: Int64 = Int64(2147483647)  # 2**31 - 1


# =============================================================================
# §2 — SendFlowController.
# =============================================================================


struct SendFlowController(Movable, Deinitable):
    """Send-side flow control.

    Tracks the connection (stream 0) send window. Per-stream send windows
    live on `StreamState.send_window` — this controller's `can_send`
    method takes a `StreamState`-derived stream_send_window value as
    argument; the caller passes the result of `min(...)` to bound the
    DATA frame size.

    Invariants:
      * connection_send_window stored as Int32 (always non-negative until
        2**31-1 cap is enforced).
      * Stream send windows are signed (see StreamState.send_window):
        retroactive SETTINGS_INITIAL_WINDOW_SIZE *decrease* can drive an
        active stream's send window negative; senders park on ≤ 0.
      * Window overflow (would exceed 2**31-1) → FLOW_CONTROL_ERROR.
      * Zero-increment WINDOW_UPDATE: stream → RST_STREAM, conn → GOAWAY.

    The retroactive SETTINGS update is handled by `on_settings_initial_window`
    — the caller walks all live streams and applies the delta.
    """

    var conn_send_window: Int32
    var initial_window_size: UInt32  # current SETTINGS_INITIAL_WINDOW_SIZE

    def __init__(out self):
        self.conn_send_window = H2_INITIAL_WINDOW_SIZE_DEFAULT
        self.initial_window_size = UInt32(65535)

    def on_window_update(
        mut self,
        stream_id: UInt32,
        increment: UInt32,
        mut stream_send_window: Int32,  # per-stream send window borrowed
    ) -> FlowResult:
        """Apply a WINDOW_UPDATE frame.

        For connection-level (stream_id == 0): increment conn_send_window.
        For per-stream: increment the caller's stream_send_window.

        Per RFC 9113 §6.9.1:
          * increment == 0 already caught at decode_frame (split-error path).
            This method assumes a positive increment; if 0 leaks through,
            treat as PROTOCOL_ERROR symmetric to the decoder split.
          * overflow (push past 2^31-1) → FLOW_CONTROL_ERROR.
        """
        if increment == UInt32(0):
            # Defensive: decode_frame catches this; if it leaks here,
            # signal the same split.
            if stream_id == UInt32(0):
                return FlowResult.goaway(H2_ERR_PROTOCOL_ERROR)
            return FlowResult.rst(stream_id, H2_ERR_PROTOCOL_ERROR)
        if stream_id == UInt32(0):
            # Connection-level WINDOW_UPDATE.
            var new_val = Int64(Int(self.conn_send_window)) + Int64(Int(increment))
            if new_val > H2_MAX_WINDOW_SIZE:
                return FlowResult.goaway(H2_ERR_FLOW_CONTROL_ERROR)
            self.conn_send_window = Int32(Int(new_val))
            return FlowResult.ok()
        # Per-stream.
        var new_val = Int64(Int(stream_send_window)) + Int64(Int(increment))
        if new_val > H2_MAX_WINDOW_SIZE:
            return FlowResult.flow_control_error(stream_id)
        stream_send_window = Int32(Int(new_val))
        return FlowResult.ok()

    def on_settings_initial_window_delta(
        mut self,
        new_initial: UInt32,
    ) -> Int32:
        """Update `initial_window_size` and return the DELTA the caller
        must apply to every live stream's send_window.

        Per RFC 9113 §6.9.2: SETTINGS_INITIAL_WINDOW_SIZE change applies
        retroactively to ALL existing streams' send windows. The caller
        walks streams and adds `delta` to each `stream.send_window` —
        sign-aware (can go negative).
        """
        var delta = Int32(Int(new_initial) - Int(self.initial_window_size))
        self.initial_window_size = new_initial
        return delta

    def can_send(
        self,
        stream_send_window: Int32,
        requested: Int,
    ) -> Int:
        """Return `min(stream_send_window, conn_send_window, requested)`,
        clamped at 0. Caller emits a DATA frame of this byte count then
        decrements both windows via `consume(...)`."""
        if stream_send_window <= Int32(0):
            return 0
        if self.conn_send_window <= Int32(0):
            return 0
        var slim = Int(stream_send_window)
        var clim = Int(self.conn_send_window)
        var lim = slim if slim < clim else clim
        return lim if lim < requested else requested

    def consume(
        mut self,
        n: Int,
        mut stream_send_window: Int32,
    ):
        """Charge `n` bytes against both windows. Caller invokes after
        emitting a DATA frame of `n` bytes."""
        self.conn_send_window = self.conn_send_window - Int32(n)
        stream_send_window = stream_send_window - Int32(n)


# =============================================================================
# §3 — RecvFlowController.
# =============================================================================


struct RecvFlowController(Movable, Deinitable):
    """Receive-side flow control.

    Tracks the connection's receive window + per-stream receive windows.
    Emits WINDOW_UPDATE at ring-drain time — when bytes EXIT
    the recv ring (the buffer between network and codec/app) — NOT when
    the application requests the next chunk. The application's `poll_frame`
    cadence is decoupled from WINDOW_UPDATE issuance.

    The driver invokes `on_ring_drain` whenever bytes leave the recv ring
    (chunk delivered to caller or codec). The result tells the driver
    whether to emit WINDOW_UPDATE frames now.
    """

    var conn_recv_window: Int32
    var initial_recv_window: UInt32
    # Drain watermark: emit WINDOW_UPDATE after this many bytes have
    # accumulated since the last update (default half the initial window).
    var drain_watermark: UInt32

    def __init__(out self):
        self.conn_recv_window = H2_INITIAL_WINDOW_SIZE_DEFAULT
        self.initial_recv_window = UInt32(65535)
        self.drain_watermark = UInt32(32768)  # half default

    def on_data_received(
        mut self,
        n: Int,
        mut stream_recv_window: Int32,
        stream_id: UInt32 = UInt32(0),
    ) -> FlowResult:
        """Charge `n` recv'd octets against both windows.

        ⚠ `n` IS THE DATA FRAME'S **LENGTH FIELD**, NOT ITS DECODED PAYLOAD.
        RFC 9113 §6.1: "The entire DATA frame payload is included in flow
        control, including the Pad Length and Padding fields if present."
        The decoder strips Pad Length + Padding before it fills
        `frame.payload`, so a caller that passes `len(frame.payload)` charges
        `pad_len + 1` octets too few on every padded frame and drifts the two
        views of the window apart monotonically, toward a silent park.
        (This docstring used to say "excluding padding" — it was the defect,
        stated.)

        WHICH WINDOW OVERRAN DECIDES THE SCOPE OF THE ERROR (RFC 9113 §6.9,
        "A receiver MAY respond with a stream error ... or a connection error
        ... of type FLOW_CONTROL_ERROR"):

          * CONNECTION window would go negative → FLOW_CONTROL_ERROR with
            stream_id 0. Nothing is charged; the connection is unrecoverable
            and the caller emits GOAWAY.
          * STREAM window would go negative → RST_STREAM(FLOW_CONTROL_ERROR)
            naming `stream_id`, and **the connection window is still charged**
            — RFC 9113 §6.9.1: "A receiver that receives a flow-controlled
            frame MUST always account for its contribution against the
            connection flow-control window, unless the receiver treats this as
            a connection error." Skipping that charge leaks the connection
            window for the life of the connection.

        `stream_id` defaults to 0 for callers that only ever act on the
        connection; they see the pre-existing FLOW_CONTROL_ERROR shape
        unchanged, because a zero-stream_id RST is not a frame anyone may send.
        """
        var new_conn = Int64(Int(self.conn_recv_window)) - Int64(n)
        if new_conn < 0:
            # Connection-level overrun: the connection cannot continue, so
            # §6.9.1's "unless the receiver treats this as a connection error"
            # carve-out applies and NOTHING is charged.
            return FlowResult.flow_control_error(UInt32(0))
        var new_stream = Int64(Int(stream_recv_window)) - Int64(n)
        if new_stream < 0:
            if stream_id == UInt32(0):
                # No stream identity, so a stream-scoped refusal would be
                # unaddressable (stream 0 is the connection). Fall back to the
                # connection error — and, as above, charge nothing.
                return FlowResult.flow_control_error(UInt32(0))
            # §6.9.1 — the stream is refused, but its octets are still
            # accounted for against the CONNECTION window. The stream window
            # is deliberately left untouched: that stream is over.
            self.conn_recv_window = Int32(Int(new_conn))
            return FlowResult.rst(stream_id, H2_ERR_FLOW_CONTROL_ERROR)
        self.conn_recv_window = Int32(Int(new_conn))
        stream_recv_window = Int32(Int(new_stream))
        return FlowResult.ok()

    def on_conn_data_received(mut self, n: Int) -> FlowResult:
        """Charge `n` recv'd bytes against the CONNECTION window ONLY.

        ★ WHY A SECOND ENTRY POINT EXISTS. RFC 9113 §6.9.1: "The entire DATA
        frame payload is included in flow control ... A receiver MUST NOT
        announce a reduction in flow-control window ... A receiver that
        receives a flow-controlled frame MUST always account for its
        contribution against the connection flow-control window, unless the
        receiver treats this as a connection error." The account is owed
        WHATEVER the stream's fate -- including when the receiving endpoint
        has no per-stream window left to charge, because it already retired
        (or never had) that stream. `on_data_received` cannot express that
        case: it requires a live `stream_recv_window` to decrement, and
        passing it a throwaway local would silently make the stream half of
        a two-level accounting system a no-op that LOOKS charged.

        The connection window is the one that matters here. The peer has
        already decremented its connection send window by `n`; if we never
        charge and never credit those bytes back, the peer's window is short
        by `n` forever and a long-lived pooled connection walks it to zero
        and stalls."""
        var new_conn = Int64(Int(self.conn_recv_window)) - Int64(n)
        if new_conn < 0:
            return FlowResult.flow_control_error(UInt32(0))
        self.conn_recv_window = Int32(Int(new_conn))
        return FlowResult.ok()

    def on_ring_drain(
        mut self,
        stream_id: UInt32,
        n_consumed: Int,
        mut stream_recv_window: Int32,
        mut stream_pending_update: UInt32,
        mut conn_pending_update: UInt32,
    ) -> Tuple[Bool, Bool]:
        """Emit WINDOW_UPDATE pair when ring drains past watermark.

        Called every time bytes exit the recv ring for stream `stream_id`.
        Accumulates into per-stream + per-connection pending update
        counters. When either crosses `drain_watermark`, the corresponding
        WINDOW_UPDATE is emitted (caller writes the frame to wire) and
        the pending counter resets.

        Returns (emit_stream_update, emit_conn_update). The actual
        frame bytes (and stream / conn windows refills) are the caller's
        job — this controller only signals timing.
        """
        # Restore windows by `n_consumed`.
        stream_recv_window = stream_recv_window + Int32(n_consumed)
        self.conn_recv_window = self.conn_recv_window + Int32(n_consumed)
        stream_pending_update = stream_pending_update + UInt32(n_consumed)
        conn_pending_update = conn_pending_update + UInt32(n_consumed)

        var emit_stream = (stream_pending_update >= self.drain_watermark)
        var emit_conn = (conn_pending_update >= self.drain_watermark)
        if emit_stream:
            stream_pending_update = UInt32(0)
        if emit_conn:
            conn_pending_update = UInt32(0)
        return (emit_stream, emit_conn)
