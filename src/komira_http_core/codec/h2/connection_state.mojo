# =============================================================================
# src/komira_http_core/codec/h2/connection_state.mojo — per-connection H2 state
# =============================================================================
#
# composes the codec primitives (HpackEncoder/Decoder,
# StreamState dict, SendFlowController, RecvFlowController) into one
# per-connection container that the HttpServer accept loop owns alongside
# the existing ConnEntry.
#
# Pointer safety:
#   * H2ConnectionState owns a Dict[Int, StreamState] + lists/strings + Hpack
#     dynamic tables. All heap-Movable (regular Mojo storage with tracked
#     origins), NOT byte-backed: a byte-slab is the
#     stale-pointer trap; heap-Movable containers are safe.
#   * H2ConnectionState lives in `Optional[H2ConnectionState]` on ConnEntry —
#     the Optional carries the destructor-safe partial-move shape per
#     the pointer rules (use Optional.take to extract).
#
# No UnsafePointer in any public sig. No wildcard origin. No
# unsafe_from_address. Heap-Movable single-owner; not Copyable (the inner
# Dict is heap-owning + Movable-only; copy would alias).
# =============================================================================

from komira_collections.slab import Slab

from komira_http_core.codec.h2.flow_control import (
    H2_INITIAL_WINDOW_SIZE_DEFAULT,
    RecvFlowController,
    SendFlowController,
)
from komira_http_core.codec.h2.frame import MAX_FRAME_PAYLOAD_DEFAULT
from komira_http_core.codec.h2.hpack import HpackDecoder, HpackEncoder, HpackHeader
from komira_http_core.codec.h2.stream import StreamState


# =============================================================================
# §0 — Per-stream heap-owning side tables.
#
# outbound DATA flow control + content-length
# aggregation need per-stream heap-owning state (`List[UInt8]` deferred
# body + `List[HpackHeader]` saved request headers). StreamState is
# Copyable (so `List[StreamState]` is well-typed under Mojo 1.0.0b1's
# `List V: Copyable` bound), which forbids non-Copyable heap fields on
# StreamState itself. The canonical pattern is parallel side-tables on
# the (Movable-not-Copyable) H2ConnectionState, keyed by stream_id +
# guarded by the StreamState scalar flags
# (`has_deferred_response_body` / `has_pending_request`).
# =============================================================================


@fieldwise_init
struct H2DeferredResponse(Movable, Deinitable):
    """Un-sent outbound response body for one stream.

    Heap-Movable (owns `List[UInt8]`). Lives in
    `H2ConnectionState.deferred_responses: Slab[H2DeferredResponse]`,
    keyed by stream_id. Drained as outbound flow-control windows admit.
    """

    var stream_id: UInt32
    var body: List[UInt8]
    var offset: Int  # bytes already emitted (informational; len(body) is the source of truth)
    var send_end_stream_on_drain: Bool  # True if the final DATA chunk
                                        # (when body fully drains) must
                                        # carry FLAG_END_STREAM.
    # gRPC streaming close. When `grpc_trailer_status
    # >= 0`, the body is the residual of a STREAMING gRPC response: the final
    # DATA chunk does NOT carry FLAG_END_STREAM; instead, after the body fully
    # drains, the pump emits a trailing-HEADERS(grpc-status[, grpc-message])
    # frame (with END_STREAM) — the valid gRPC stream close. `-1` means an
    # ordinary h1-parity deferred body (END_STREAM on the final DATA chunk per
    # `send_end_stream_on_drain`).
    var grpc_trailer_status: Int16
    var grpc_trailer_message: String


@fieldwise_init
struct H2PendingRequest(Movable, Deinitable):
    """Saved decoded request headers for one stream whose dispatch is
    deferred to END_STREAM (RFC 7540 §8.1.2.6 content-length aggregation).

    Heap-Movable (owns `List[HpackHeader]` + `String` method/path). Lives
    in `H2ConnectionState.pending_requests: Slab[H2PendingRequest]`, keyed
    by stream_id. Popped at END_STREAM (DATA carrying FLAG_END_STREAM)
    after content-length validation succeeds.
    """

    var stream_id: UInt32
    var headers: List[HpackHeader]
    var method_str: String
    var path_str: String
    # gRPC request-body capture. The pre-existing
    # deferred path counted DATA bytes (`recv_data_bytes`) but DISCARDED
    # the payload. A gRPC request body (the 5-byte-framed envelope) is the
    # actual RPC argument, so it must be retained until END_STREAM dispatch.
    # `body` accumulates DATA payload bytes as they arrive (via
    # `append_pending_request_body`); `content_type` is captured at HEADERS
    # time so the END_STREAM dispatch can route gRPC content-types to the
    # GrpcDispatch seam without re-scanning the headers list.
    var body: List[UInt8]
    var content_type: String
    # The `GrpcDispatch.grpc_now_ns` reading taken when the HEADERS block
    # completed (0 for a non-gRPC request). The END_STREAM dispatch computes
    # the call's grpc-timeout deadline from it and the saved `headers`, so
    # the time the body took to arrive counts against the deadline.
    var arrival_ns: UInt64


# =============================================================================
# §1 — H2 conn lifecycle flags.
# =============================================================================

comptime H2_CONN_FLAG_PREFACE_OK: UInt8 = 1 << 0
"""Set after the 24-byte client preface validates."""

comptime H2_CONN_FLAG_SETTINGS_SENT: UInt8 = 1 << 1
"""Set after the server emits its initial non-ACK SETTINGS frame."""

comptime H2_CONN_FLAG_PEER_SETTINGS_ACK: UInt8 = 1 << 2
"""Set after the server's SETTINGS frame is ACKed by the peer (rarely
checked in practice — most servers proceed without strict ACK gating)."""

comptime H2_CONN_FLAG_GOAWAY_SENT: UInt8 = 1 << 3
"""Set after the server emits GOAWAY; new streams are rejected and the
connection is draining toward close."""

comptime H2_CONN_FLAG_GOAWAY_RECEIVED: UInt8 = 1 << 4
"""Set after we receive a GOAWAY from the peer. Per RFC 9113 §6.8 the
receiver SHOULD finish processing in-flight frames (PING in particular,
for h2spec's PING-ACK round-trip canary) and gracefully close. We don't
accept new streams once this flag is set."""


# =============================================================================
# §1b — HEADERS/CONTINUATION reassembly ceilings (CVE-2024-27316 shape).
# =============================================================================
#
# ⚠ HEADERS and CONTINUATION are NOT FLOW-CONTROLLED. RFC 9113 §5.2.1: flow
# control applies to DATA frames ONLY, and our `RecvFlowController` is charged
# only on FRAME_DATA. So NOTHING except these two ceilings bounds the header
# block a peer can make us buffer: one HEADERS without END_HEADERS followed by
# an endless CONTINUATION stream grows `cont_reasm_buf` until the process dies.
# That is the "HTTP/2 CONTINUATION Flood" (CVE-2024-27316) verbatim, and it is
# equally available to a hostile ORIGIN against our client.
#
# Both peers are told the budget: server and client each ADVERTISE
# SETTINGS_MAX_HEADER_LIST_SIZE = 8192. These ceilings are the enforcement that
# advertisement never had. They are deliberately far above 8192 (the advertised
# value bounds the DECODED list, which HPACK compresses into far fewer wire
# octets) so no compliant peer is disconnected — the decoded-list budget itself
# is enforced separately in `HpackDecoder.decode_block`.

comptime H2_MAX_HEADER_BLOCK_BYTES: Int = 65536
"""Ceiling on the accumulated HEADERS+CONTINUATION block for ONE connection."""

comptime H2_MAX_HEADER_BLOCK_FRAMES: Int = 64
"""Ceiling on the frame COUNT in one HEADERS+CONTINUATION sequence. Separate
from the byte ceiling because a ZERO-LENGTH CONTINUATION frame adds no bytes:
without this, an endless stream of empty CONTINUATIONs is an unbounded CPU +
syscall flood that the byte ceiling alone never trips."""


# =============================================================================
# §2 — H2ConnectionState.
# =============================================================================


struct H2ConnectionState(Movable, Deinitable):
    """Per-connection HTTP/2 state.

    Owned by `ConnEntry._h2: Optional[H2ConnectionState]` when the
    connection was ALPN-negotiated to `h2`. The h1 path (Optional == None)
    is unaffected.

    Fields:
      hpack_encoder       — outbound header encoder (per-conn dynamic table)
      hpack_decoder       — inbound header decoder (per-conn dynamic table)
      streams             — List[StreamState]; linear-scan by stream_id.
                            StreamState is Movable-not-Copyable (owns
                            List[UInt8] header_block + List entries for
                            flow-control accounting), so Dict[K, V] is
                            ruled out by Mojo 1.0.0b1's `Dict V: Copyable`
                            trait bound. Linear scan is acceptable:
                            connections typically have ≤ a few hundred
                            active streams (RFC default
                            SETTINGS_MAX_CONCURRENT_STREAMS = 100).
      send_fc             — connection-level + driver for stream send windows
      recv_fc             — connection-level + driver for stream recv windows
      recv_buf            — bytes pulled from TLS stream but not yet consumed
                            by decode_frame (handles cross-read framing)
      pending_out         — outbound bytes the server wants to send but
                            haven't been flushed to TLS yet (matches the
                            h1 `_pending_buf` pattern conceptually but
                            heap-Movable because h2 frames can be large)
      max_frame_size_peer — peer's SETTINGS_MAX_FRAME_SIZE (default 16384)
      max_frame_size_local — what WE advertised; we use this as the
                            outbound encoder's per-frame size cap.
      max_concurrent_streams_peer — peer's SETTINGS_MAX_CONCURRENT_STREAMS;
                            advisory (the peer is the SERVER for this
                            connection's outgoing direction... no, the
                            client is the peer in our role). Tracked for
                            symmetry; not enforced on outbound until
                            push support arrives.
      next_expected_stream_id — RFC 9113 §5.1.1: client-initiated streams
                            are odd-numbered, monotonically increasing.
                            A new HEADERS on an even/odd ID violation is
                            a connection PROTOCOL_ERROR.
      last_processed_stream_id — for GOAWAY: the highest server-processed
                            stream id.
      flags               — H2_CONN_FLAG_* bitset.
      goaway_error_code   — if H2_CONN_FLAG_GOAWAY_SENT: the error code
                            we emitted (for the caller to log).
      cont_reasm_stream_id — RFC 9113 §6.10: at most ONE in-flight HEADERS
                            sequence per CONNECTION. This field tracks
                            which stream's HEADERS+CONTINUATION block is
                            currently being assembled; 0 = no active
                            reassembly.
      cont_reasm_buf      — the accumulated header-block bytes (HEADERS
                            payload + CONTINUATION payloads). Drained
                            into HpackDecoder.decode_block at the
                            END_HEADERS-bearing frame.
    """

    var hpack_encoder: HpackEncoder
    var hpack_decoder: HpackDecoder
    var streams: List[StreamState]
    var send_fc: SendFlowController
    var recv_fc: RecvFlowController
    var recv_buf: List[UInt8]
    var pending_out: List[UInt8]
    # Leading bytes of `pending_out` that `prepend_out_bytes` must not
    # overtake (see `pin_out_bytes`).
    var out_pinned: Int
    var max_frame_size_peer: Int
    var max_frame_size_local: Int
    var max_concurrent_streams_peer: UInt32
    var next_expected_stream_id: UInt32
    var last_processed_stream_id: UInt32
    var flags: UInt8
    var goaway_error_code: UInt32
    var cont_reasm_stream_id: UInt32
    var cont_reasm_buf: List[UInt8]
    # Frames seen in the CURRENT HEADERS+CONTINUATION sequence.
    var cont_reasm_frames: Int
    # per-stream heap-owning side tables (see §0 above).
    var deferred_responses: Slab[H2DeferredResponse]
    var pending_requests: Slab[H2PendingRequest]

    def __init__(out self):
        self.hpack_encoder = HpackEncoder(max_table_size=4096)
        self.hpack_decoder = HpackDecoder(max_table_size=4096)
        self.streams = List[StreamState]()
        self.send_fc = SendFlowController()
        self.recv_fc = RecvFlowController()
        self.recv_buf = List[UInt8]()
        self.pending_out = List[UInt8]()
        self.out_pinned = 0
        self.max_frame_size_peer = MAX_FRAME_PAYLOAD_DEFAULT
        self.max_frame_size_local = MAX_FRAME_PAYLOAD_DEFAULT
        self.max_concurrent_streams_peer = UInt32(100)
        # First client-initiated stream is 1 (RFC 9113 §5.1.1). We track
        # "next expected"; the first HEADERS with stream_id != 1 is a
        # connection PROTOCOL_ERROR.
        self.next_expected_stream_id = UInt32(1)
        self.last_processed_stream_id = UInt32(0)
        self.flags = UInt8(0)
        self.goaway_error_code = UInt32(0)
        self.cont_reasm_stream_id = UInt32(0)
        self.cont_reasm_buf = List[UInt8]()
        self.cont_reasm_frames = 0
        self.deferred_responses = Slab[H2DeferredResponse]()
        self.pending_requests = Slab[H2PendingRequest]()

    def append_header_block(mut self, payload: Span[UInt8, _]) -> Bool:
        """Append one HEADERS/CONTINUATION payload to the reassembly buffer,
        enforcing the §1b ceilings.

        Returns False if a ceiling was exceeded — the caller MUST treat that
        as a connection error (GOAWAY) and MUST NOT continue reassembly. The
        buffer is left untouched on refusal, so nothing hostile is retained.

        This is the ONE place the header-block reassembly grows; validating
        here (once per frame, on the length the frame decoder already parsed)
        rather than per byte keeps the check off the copy path entirely.
        """
        self.cont_reasm_frames = self.cont_reasm_frames + 1
        if self.cont_reasm_frames > H2_MAX_HEADER_BLOCK_FRAMES:
            return False
        if len(self.cont_reasm_buf) + len(payload) > H2_MAX_HEADER_BLOCK_BYTES:
            return False
        self.cont_reasm_buf.extend(payload)
        return True

    def reset_header_block(mut self):
        """Drop the reassembly buffer + its frame counter (block complete, or
        the connection is being torn down)."""
        self.cont_reasm_stream_id = UInt32(0)
        self.cont_reasm_buf = List[UInt8]()
        self.cont_reasm_frames = 0

    def _slab_len_deferred(self) -> Int:
        return len(self.deferred_responses)

    def _slab_len_pending(self) -> Int:
        return len(self.pending_requests)

    def is_preface_ok(self) -> Bool:
        return (self.flags & H2_CONN_FLAG_PREFACE_OK) != UInt8(0)

    def mark_preface_ok(mut self):
        self.flags = self.flags | H2_CONN_FLAG_PREFACE_OK

    def is_settings_sent(self) -> Bool:
        return (self.flags & H2_CONN_FLAG_SETTINGS_SENT) != UInt8(0)

    def mark_settings_sent(mut self):
        self.flags = self.flags | H2_CONN_FLAG_SETTINGS_SENT

    def is_goaway_sent(self) -> Bool:
        return (self.flags & H2_CONN_FLAG_GOAWAY_SENT) != UInt8(0)

    def mark_goaway_sent(mut self, error_code: UInt32):
        self.flags = self.flags | H2_CONN_FLAG_GOAWAY_SENT
        self.goaway_error_code = error_code

    def is_goaway_received(self) -> Bool:
        return (self.flags & H2_CONN_FLAG_GOAWAY_RECEIVED) != UInt8(0)

    def mark_goaway_received(mut self):
        self.flags = self.flags | H2_CONN_FLAG_GOAWAY_RECEIVED

    def append_recv_bytes(mut self, bytes_view: Span[UInt8, _]):
        """Append freshly-decrypted bytes from the TLS stream into the
        recv accumulator. Subsequent `decode_frame` calls consume from
        the front of this buffer."""
        var n = len(bytes_view)
        var i = 0
        while i < n:
            self.recv_buf.append(bytes_view[i])
            i = i + 1

    def consume_recv_bytes(mut self, n: Int):
        """Pop the first `n` bytes off the recv buffer (after a successful
        decode). Implemented as O(n) shift; acceptable, perf
        follow-up if needed for hot paths."""
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
        """Stage encoded frame bytes into the outbound queue. The driver
        flushes the queue to TLS in bulk per serve iteration."""
        var n = len(bytes)
        var i = 0
        while i < n:
            self.pending_out.append(bytes[i])
            i = i + 1

    def prepend_out_bytes(mut self, var bytes: List[UInt8]):
        """Stage encoded frame bytes at the FRONT of the outbound queue.

        Used for priority-out frames that must overtake any queued
        normal-path frames on the wire: the
        RFC 9113 §5.1.2 concurrent-stream-limit gate emits RST_STREAM +
        GOAWAY when the peer opens a stream past the advertised limit;
        h2spec's `VerifyStreamError` loop has a per-frame 10s deadline
        and under heavy machine load the inter-frame gap between
        the 100 queued HEADERS-resps and the gate's RST/GOAWAY can
        exceed that deadline. Prepending RST/GOAWAY puts them on the
        wire FIRST so h2spec matches them on its first WaitEvent.

        O(N+M) where N is the current pending_out size and M is the
        incoming bytes count. For the RFC 9113 §5.1.2 case N is bounded by 100
        HEADERS-resps (~6-8 KB) and M is RST+GOAWAY (~30 bytes); a
        ~6KB byte-copy is negligible vs a TLS handshake.

        Normal-path callers MUST continue to use append_out_bytes(...).
        Use prepend_out_bytes(...) ONLY for session-terminating frames
        (GOAWAY) and stream-refusing frames (RST_STREAM(REFUSED_STREAM))
        that the protocol semantics permit to bypass FIFO.

        The bytes go in after the pinned prefix (`pin_out_bytes`), not at
        offset 0: the server's connection preface (its first SETTINGS,
        RFC 9113 §3.4) and the unwritten tail of a partial write are never
        overtaken.
        """
        var at = self.out_pinned
        var n = len(self.pending_out)
        var new_buf = List[UInt8](capacity=n + len(bytes))
        new_buf.extend(Span(self.pending_out)[0:at])
        new_buf.extend(Span(bytes))
        new_buf.extend(Span(self.pending_out)[at:n])
        swap(self.pending_out, new_buf)

    def pin_out_bytes(mut self):
        """Pin every byte now queued: a later `prepend_out_bytes` goes in
        behind them. Two callers need this. The server preface (its first
        SETTINGS frame) must be the first frame on the wire (RFC 9113
        §3.4). And the unwritten tail of a partial write may begin in the
        middle of a frame, which the TLS layer also expects to be offered
        again unchanged; a frame put in front of it would corrupt the
        framing. `take_out_bytes` clears the pin."""
        self.out_pinned = len(self.pending_out)

    def take_out_bytes(mut self) -> List[UInt8]:
        """Move-out the outbound staging buffer and clear the pin. Caller
        writes the bytes to the TLS stream then drops the returned List."""
        var out = List[UInt8]()
        swap(out, self.pending_out)
        self.out_pinned = 0
        return out^

    def find_stream_idx(self, stream_id: UInt32) -> Int:
        """Linear-scan lookup. Returns the List index of the
        StreamState with the matching `stream_id`, or -1 if not present.

        Linear scan is acceptable: connections typically have ≤ a
        few hundred active streams (RFC default
        SETTINGS_MAX_CONCURRENT_STREAMS = 100). If hot-path profiling
        flags this, switch to a Dict[UInt32, Int] index alongside the
        List (StreamState itself remains Movable-only).
        """
        var n = len(self.streams)
        var i = 0
        while i < n:
            if self.streams[i].stream_id == stream_id:
                return i
            i = i + 1
        return -1

    def has_stream(self, stream_id: UInt32) -> Bool:
        return self.find_stream_idx(stream_id) >= 0

    def get_or_create_stream(
        mut self, stream_id: UInt32,
    ) -> Bool:
        """Ensure a StreamState exists for `stream_id`. Returns True if
        newly created, False if already present.

        The stream is initialized with `send_window = peer's initial
        window size` and `recv_window = our initial window size`.
        uses the default 65535 for both unless SETTINGS adjusts.
        """
        if self.has_stream(stream_id):
            return False
        var initial_send = Int32(Int(self.send_fc.initial_window_size))
        var initial_recv = Int32(Int(self.recv_fc.initial_recv_window))
        # For the stream's send_window we use the PEER's initial_window
        # (controlled by the peer's SETTINGS_INITIAL_WINDOW_SIZE which
        # `send_fc.initial_window_size` tracks).
        var ss = StreamState(
            stream_id=stream_id, initial_window=initial_send,
        )
        # Override recv_window if differing.
        ss.recv_window = initial_recv
        self.streams.append(ss^)
        if stream_id > self.last_processed_stream_id:
            self.last_processed_stream_id = stream_id
        return True

    # ----------------------------------------------------------------------
    # deferred-response side-table helpers.
    # ----------------------------------------------------------------------

    def find_deferred_response_idx(self, stream_id: UInt32) -> Int:
        """Linear scan over `deferred_responses`. Returns the index of
        the entry for `stream_id` or -1 if absent."""
        var n = len(self.deferred_responses)
        var i = 0
        while i < n:
            if self.deferred_responses[i].stream_id == stream_id:
                return i
            i = i + 1
        return -1

    def push_deferred_response(
        mut self,
        stream_id: UInt32,
        var body: List[UInt8],
        offset: Int,
        send_end_stream_on_drain: Bool,
    ):
        """Stage the un-sent tail of a response body on the
        deferred-responses side table. Caller must also set
        `streams[idx].has_deferred_response_body = True`."""
        self.deferred_responses.append(
            H2DeferredResponse(
                stream_id=stream_id,
                body=body^,
                offset=offset,
                send_end_stream_on_drain=send_end_stream_on_drain,
                grpc_trailer_status=Int16(-1),
                grpc_trailer_message=String(""),
            )
        )

    def push_deferred_grpc_response(
        mut self,
        stream_id: UInt32,
        var body: List[UInt8],
        grpc_status: UInt8,
        var grpc_message: String,
    ):
        """Stage the residual of a STREAMING gRPC response. The
        residual is the concatenated tail of the gRPC message bytes that did
        not fit the send window in the first emit pass. Unlike an ordinary
        deferred body, the final DATA chunk does NOT carry END_STREAM; the pump
        emits a trailing-HEADERS(grpc-status) close after the body drains.
        Caller must also set `streams[idx].has_deferred_response_body = True`."""
        self.deferred_responses.append(
            H2DeferredResponse(
                stream_id=stream_id,
                body=body^,
                offset=0,
                send_end_stream_on_drain=False,
                grpc_trailer_status=Int16(Int(grpc_status)),
                grpc_trailer_message=grpc_message^,
            )
        )

    def deferred_response_grpc_trailer_status(
        self, stream_id: UInt32,
    ) -> Int16:
        """The gRPC trailer status for `stream_id`'s deferred
        entry, or -1 if it is an ordinary (non-gRPC) deferred body / absent."""
        var idx = self.find_deferred_response_idx(stream_id)
        if idx < 0:
            return Int16(-1)
        return self.deferred_responses[idx].grpc_trailer_status

    def deferred_response_grpc_trailer_message(
        self, stream_id: UInt32,
    ) -> String:
        """The gRPC trailer message for `stream_id`'s deferred
        entry (empty if absent / no message)."""
        var idx = self.find_deferred_response_idx(stream_id)
        if idx < 0:
            return String("")
        return self.deferred_responses[idx].grpc_trailer_message

    def take_deferred_response_body_chunk(
        mut self,
        stream_id: UInt32,
        var n: Int,
    ) -> List[UInt8]:
        """Pop the first `n` bytes of the deferred-response body for
        `stream_id`. Returns the chunk; the residual stays at
        `deferred_responses[idx].body`. If `n >= len(body)` after pop,
        the entry remains (caller drains separately via
        `drop_deferred_response_if_empty`)."""
        var idx = self.find_deferred_response_idx(stream_id)
        var chunk = List[UInt8]()
        if idx < 0:
            return chunk^
        ref entry = self.deferred_responses[idx]
        var avail = len(entry.body)
        if n > avail:
            n = avail
        var i = 0
        while i < n:
            chunk.append(entry.body[i])
            i = i + 1
        # Shift residual.
        var new_body = List[UInt8]()
        var j = n
        while j < avail:
            new_body.append(entry.body[j])
            j = j + 1
        swap(entry.body, new_body)
        entry.offset = entry.offset + n
        return chunk^

    def deferred_response_body_len(self, stream_id: UInt32) -> Int:
        """Returns how many bytes remain un-sent for `stream_id`. 0 if
        no deferred response is staged."""
        var idx = self.find_deferred_response_idx(stream_id)
        if idx < 0:
            return 0
        return len(self.deferred_responses[idx].body)

    def deferred_response_sends_end_stream(self, stream_id: UInt32) -> Bool:
        """Returns the `send_end_stream_on_drain` flag for the deferred
        response on `stream_id`. False if no such entry."""
        var idx = self.find_deferred_response_idx(stream_id)
        if idx < 0:
            return False
        return self.deferred_responses[idx].send_end_stream_on_drain

    def drop_deferred_response(mut self, stream_id: UInt32):
        """Remove the deferred-response entry for `stream_id`. Caller
        must also clear `streams[idx].has_deferred_response_body`."""
        var idx = self.find_deferred_response_idx(stream_id)
        if idx < 0:
            return
        _ = self.deferred_responses.swap_remove(idx)

    # ----------------------------------------------------------------------
    # pending-request side-table helpers.
    # ----------------------------------------------------------------------

    def find_pending_request_idx(self, stream_id: UInt32) -> Int:
        """Linear scan over `pending_requests`. Returns the index of the
        entry for `stream_id` or -1 if absent."""
        var n = len(self.pending_requests)
        var i = 0
        while i < n:
            if self.pending_requests[i].stream_id == stream_id:
                return i
            i = i + 1
        return -1

    def push_pending_request(
        mut self,
        stream_id: UInt32,
        var headers: List[HpackHeader],
        var method_str: String,
        var path_str: String,
        var content_type: String = String(""),
        arrival_ns: UInt64 = UInt64(0),
    ):
        """Stage a deferred request on the pending-requests side table.
        Caller must also set `streams[idx].has_pending_request = True`.

        `content_type` is captured here so the END_STREAM
        dispatch can route gRPC content-types without re-scanning headers.
        The request `body` starts empty and is grown via
        `append_pending_request_body` as DATA frames arrive."""
        self.pending_requests.append(
            H2PendingRequest(
                stream_id=stream_id,
                headers=headers^,
                method_str=method_str^,
                path_str=path_str^,
                body=List[UInt8](),
                content_type=content_type^,
                arrival_ns=arrival_ns,
            )
        )

    def append_pending_request_body(
        mut self, stream_id: UInt32, payload: Span[UInt8, _],
    ):
        """Append DATA-frame payload bytes onto the pending request's body.

        gRPC request-body capture. Called for each DATA frame on
        a stream whose dispatch is deferred (`has_pending_request`). No-op if
        no pending entry exists for `stream_id` (non-deferred streams discard
        their body as before)."""
        var idx = self.find_pending_request_idx(stream_id)
        if idx < 0:
            return
        ref entry = self.pending_requests[idx]
        var n = len(payload)
        var i = 0
        while i < n:
            entry.body.append(payload[i])
            i = i + 1

    def take_pending_request(
        mut self, stream_id: UInt32,
    ) -> H2PendingRequest:
        """Move-out the pending request entry for `stream_id`. Caller
        must check `find_pending_request_idx(stream_id) >= 0` first;
        if absent this returns an empty stub. Caller must also clear
        `streams[idx].has_pending_request`."""
        var idx = self.find_pending_request_idx(stream_id)
        if idx < 0:
            return H2PendingRequest(
                stream_id=UInt32(0),
                headers=List[HpackHeader](),
                method_str=String(""),
                path_str=String(""),
                body=List[UInt8](),
                content_type=String(""),
                arrival_ns=UInt64(0),
            )
        var out = self.pending_requests.swap_remove(idx)
        return out^
