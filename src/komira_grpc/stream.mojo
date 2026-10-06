# =============================================================================
# komira_grpc/stream.mojo — Streaming-mode wire codecs (transport-free)
# =============================================================================
#
# The streaming modes (server-streaming, client-streaming, bidi) as
# transport-free state machines, with no function pointers anywhere.
#
# ServerStream / ClientStream / BidiStream are PULL ITERATORS. `next()` calls
# `poll_frame` on the response Body, runs the 5-byte length-prefix framer
# over the Data frames, decodes one message.
#
# This module ships the TRANSPORT-FREE side of those pull-iterators:
#
#   ServerStreamDecoder[P]    — feeds Data bytes into a ClientFramer; pops
#                                envelopes; on END_STREAM (Connect-streaming)
#                                or trailers (classic gRPC) yields the
#                                terminating status.
#   ClientStreamEncoder[P]    — accumulates messages into an outgoing
#                                envelope-framed buffer; emits a final
#                                close-send marker (half-close).
#   BidiStreamCodec[P]        — composition of both halves; the structural
#                                invariant is that the
#                                two halves are INDEPENDENTLY-OWNED — no
#                                shared field.
#
# These are NOT generic-streaming pull iterators wired to HttpClient — they
# are the WIRE-FORMAT primitives an iterator wires through. The
# iterator's `next()` calls `_decoder.try_next_message()`; the iterator's
# `send()` calls `_encoder.encode_message(...)`; the iterator's
# `close_send()` calls `_encoder.mark_close()`.
#
# Wire form:
#   - Classic gRPC streaming: every request and response message is a
#     5-byte envelope (flags + uint32 BE length + payload). Status arrives
#     in HTTP/2 trailers as `grpc-status` / `grpc-message`.
#   - Connect streaming: same 5-byte envelope. Status arrives as a FINAL
#     envelope with the END_STREAM (0x02) flag set; payload is a JSON object
#     `{"error":{...}}` or `{}` on success.
#
# Encapsulation: NO UnsafePointer in any public sig. The two halves of a
# bidi stream OWN INDEPENDENT buffers; no shared
# pointer field; no long-lived borrowed-pointer field.
# =============================================================================

from komira_connect.envelope import (
    ENVELOPE_HEADER_SIZE,
    ENVELOPE_FLAG_COMPRESSED,
    ENVELOPE_FLAG_END_STREAM,
    write_envelope,
)
from komira_connect.codec_connect_json import (
    parse_connect_error_json,
    build_connect_end_stream_json,
)

from komira_grpc.protocol import Protocol
from komira_grpc.framing import ClientFramer, PoppedEnvelope
from komira_grpc.error import GrpcError, parse_grpc_status_trailers
from komira_grpc.wire import encode_stream_message
from komira_connect.status import (
    GRPC_STATUS_INTERNAL,
    GRPC_STATUS_OK,
    GRPC_STATUS_UNKNOWN,
)
from komira_http_client.header_map import HeaderMap


# =============================================================================
# §1 — StreamOutcome — the result of a try_next_message poll on a server
#       stream / response half of a bidi.
# =============================================================================


comptime STREAM_OUTCOME_MESSAGE: UInt8 = 0
"""`try_next_message`: one message decoded (payload owned in `message_bytes`)."""

comptime STREAM_OUTCOME_PENDING: UInt8 = 1
"""`try_next_message`: more wire bytes needed; caller should feed and retry."""

comptime STREAM_OUTCOME_END_OK: UInt8 = 2
"""`try_next_message`: stream terminated successfully (Connect END_STREAM
envelope with empty `{}` body, OR classic gRPC trailers with grpc-status=0)."""

comptime STREAM_OUTCOME_END_ERROR: UInt8 = 3
"""`try_next_message`: stream terminated with a non-OK status. The decoded
GrpcError is in `error` (and `message_bytes` is empty)."""


struct StreamOutcome(Movable, Deinitable):
    """The result of polling a streaming decoder for the next message.

    Movable, NOT Copyable — owns `message_bytes` + `error.message` /
    `error.details`. Pattern:
        var outcome = decoder.try_next_message()
        if outcome.kind == STREAM_OUTCOME_MESSAGE:
            ... decode outcome.message_bytes ...
        elif outcome.kind == STREAM_OUTCOME_PENDING:
            ... feed more bytes ...
        elif outcome.kind == STREAM_OUTCOME_END_OK:
            ... clean shutdown ...
        elif outcome.kind == STREAM_OUTCOME_END_ERROR:
            ... raise outcome.error ...
    """

    var kind: UInt8
    """STREAM_OUTCOME_* sentinel."""

    var message_bytes: List[UInt8]
    """For STREAM_OUTCOME_MESSAGE: the decoded message bytes (envelope
    stripped). Empty for all other kinds."""

    var error: GrpcError
    """For STREAM_OUTCOME_END_ERROR: the terminating status. Default
    (GRPC_STATUS_OK) for all other kinds."""

    def __init__(out self):
        self.kind = STREAM_OUTCOME_PENDING
        self.message_bytes = List[UInt8]()
        self.error = GrpcError.ok()

    @staticmethod
    def message(var bytes: List[UInt8]) -> StreamOutcome:
        var o = StreamOutcome()
        o.kind = STREAM_OUTCOME_MESSAGE
        o.message_bytes = bytes^
        return o^

    @staticmethod
    def pending() -> StreamOutcome:
        var o = StreamOutcome()
        o.kind = STREAM_OUTCOME_PENDING
        return o^

    @staticmethod
    def end_ok() -> StreamOutcome:
        var o = StreamOutcome()
        o.kind = STREAM_OUTCOME_END_OK
        return o^

    @staticmethod
    def end_error(var err: GrpcError) -> StreamOutcome:
        var o = StreamOutcome()
        o.kind = STREAM_OUTCOME_END_ERROR
        o.error = err^
        return o^


# =============================================================================
# §2 — ServerStreamDecoder[P] — decode side for server-stream + bidi-response.
# =============================================================================


struct ServerStreamDecoder[P: Protocol](Movable, Deinitable):
    """Decodes one half of an HTTP/2 stream: the SERVER → CLIENT direction.

    Used by:
      - ServerStream (1 req → N resp)
      - BidiStream's response half
      - ClientStream's terminal response (single message; caller treats
        the first STREAM_OUTCOME_MESSAGE as the response and stops there)

    State machine:
      _framer        — accumulates wire bytes, yields envelopes.
      _terminated    — True once we've yielded a STREAM_OUTCOME_END_* —
                       further calls return STREAM_OUTCOME_END_OK (idempotent).

    Caller pattern:
        decoder.feed(data_bytes)        # from Data BodyFrame
        var outcome = decoder.try_next_message()
        ... iterate ...
        # When the HTTP body ends (End BodyFrame):
        decoder.feed_trailers(trailer_headers)  # classic gRPC only
        # The next try_next_message picks up the status.

    For Connect-streaming: the terminating envelope has END_STREAM bit set
    and the payload is JSON ({} on success; {"error":{...}} on failure).
    The decoder handles this internally — no `feed_trailers` needed.

    For classic gRPC: the trailers arrive as a Trailers(HeaderMap) BodyFrame
    AFTER all Data BodyFrames. The caller calls `feed_trailers(hm)` once,
    then `try_next_message` yields STREAM_OUTCOME_END_*.

    Encapsulation: P comptime parametric; framer is OwnedPointer-equivalent
    (List[UInt8] field); NO long-lived borrowed-pointer fields.
    """

    var _framer: ClientFramer
    """Sliding-buffer envelope framer."""

    var _terminated: Bool
    """True once a STREAM_OUTCOME_END_* has been yielded. Further calls
    REPLAY that same terminal outcome — see `_terminal_code` below."""

    var _terminal_code: UInt8
    """⭐ THE TERMINAL STATUS ITSELF, not merely the fact that there was one.

    With only a `_terminated` Bool and a replay hardcoded to
    `StreamOutcome.end_ok()`, a stream that ended UNAVAILABLE would report that
    error on the first poll and SUCCESS on every poll after it. A consumer that
    re-polls — a retry wrapper, a drain-to-completion loop, a second pass over
    an iterator — would be told the stream succeeded.

    A stickiness test that covers only the OK case cannot see that: with the
    replay hardcoded to `end_ok()`, the OK case is sticky BY ACCIDENT rather
    than by construction. `test_grpc_truncation_and_terminal` therefore pins the ERROR cases
    too."""

    var _terminal_message: String
    """The terminal status message, replayed with `_terminal_code`."""

    var _terminal_details: Optional[List[UInt8]]
    """The terminal status' details payload, if it carried one, so a replay is
    byte-identical to the first poll rather than a lossy summary of it."""

    var _pending_status: Optional[GrpcError]
    """Set by feed_trailers (classic gRPC) before the FIRST poll after
    body End. The next try_next_message extracts it and yields END."""

    def __init__(out self):
        self._framer = ClientFramer.new()
        self._terminated = False
        self._terminal_code = GRPC_STATUS_OK
        self._terminal_message = String("")
        self._terminal_details = Optional[List[UInt8]]()
        self._pending_status = Optional[GrpcError]()

    @staticmethod
    def new() -> ServerStreamDecoder[Self.P]:
        return ServerStreamDecoder[Self.P]()

    def feed(mut self, data: Span[UInt8, _]):
        """Feed wire bytes from a Data BodyFrame."""
        self._framer.feed(data)

    def feed_owned(mut self, var data: List[UInt8]):
        """Feed wire bytes from an owned Data BodyFrame chunk."""
        self._framer.feed_owned(data^)

    def feed_trailers(mut self, trailers: HeaderMap):
        """Feed the HTTP/2 trailer block (classic gRPC only).

        After this, the next `try_next_message` call yields STREAM_OUTCOME_END
        carrying the parsed grpc-status / grpc-message. For Connect-streaming
        this is NOT called — the terminating envelope's END_STREAM bit
        signals end-of-stream internally.
        """
        var err = parse_grpc_status_trailers(trailers)
        self._pending_status = Optional[GrpcError](err^)

    def try_next_message(mut self) raises -> StreamOutcome:
        """Try to yield the next message (or termination signal).

        Returns one of:
          - STREAM_OUTCOME_MESSAGE: a decoded message is available.
          - STREAM_OUTCOME_PENDING: caller should feed more bytes and retry.
          - STREAM_OUTCOME_END_OK / END_ERROR: stream terminated.

        Pattern (response-stream consumer):
            while True:
                var outcome = decoder.try_next_message()
                if outcome.kind == STREAM_OUTCOME_PENDING:
                    var frame = body.poll_frame(...)
                    match frame.kind:
                        Data(bytes): decoder.feed_owned(bytes^); continue
                        Trailers(hm): decoder.feed_trailers(hm); continue
                        End: break
                        ...
                elif outcome.kind == STREAM_OUTCOME_MESSAGE:
                    yield outcome.message_bytes
                else:
                    # END_OK / END_ERROR
                    if outcome.kind == STREAM_OUTCOME_END_ERROR:
                        raise outcome.error
                    return
        """
        if self._terminated:
            return self._replay_terminal()
        # Try to pop one envelope.
        var opt = self._framer.try_pop_envelope()
        if opt.__bool__():
            var env = opt.take()
            # Extract payload via swap (no partial moves) —
            # this leaves env.payload as an empty List, env still drops
            # cleanly. Equivalent to `env.payload^` but compiler-visible
            # as "field replaced with default", not "partial move".
            var payload_out = List[UInt8]()
            swap(payload_out, env.payload)
            var flags = env.flags
            comptime if Self.P.stream_has_end_stream_envelope():
                # Connect-streaming / gRPC-Web. The
                # terminating envelope has the END_STREAM bit set and its
                # payload is a JSON status; the flags byte IS a bitfield in
                # this dialect, so bit-testing is correct HERE.
                if (flags & ENVELOPE_FLAG_END_STREAM) != 0:
                    # Split across two statements: `_terminate` and
                    # `_parse_connect_end_stream` both take `mut self`, and
                    # nesting them would be two mutable borrows of `self` in
                    # one expression.
                    var eos = self._parse_connect_end_stream(payload_out^)
                    return self._terminate(eos^)
                if (flags & ENVELOPE_FLAG_COMPRESSED) != 0:
                    return self._terminate(
                        StreamOutcome.end_error(
                            GrpcError.simple(
                                GRPC_STATUS_UNKNOWN,
                                String(
                                    "komira_grpc: compressed envelopes not"
                                    " supported (Grpc-Encoding: identity"
                                    " only)"
                                ),
                            )
                        )
                    )
                return StreamOutcome.message(payload_out^)
            else:
                # ⭐ CLASSIC gRPC: THE FLAGS BYTE IS A 1-BYTE UNSIGNED VALUE,
                # NOT A BITFIELD.
                #
                # Per PROTOCOL-HTTP2 the Compressed-Flag is "a 1 byte unsigned
                # integer" whose only defined values are 0 and 1, and grpc-go
                # switches on the WHOLE BYTE, failing anything else with
                #   status.Errorf(codes.Internal,
                #                 "grpc: received unexpected payload format %d")
                #
                # Testing two BITS here would be wrong in BOTH directions,
                # and silently:
                #   * 0x02..0x7F set neither bit, so a desynchronised framing,
                #     a gRPC-unaware intermediary or a peer speaking a
                #     different envelope dialect would be handed to the
                #     application AS ORDINARY DATA;
                #   * 0x80 would be read as END_STREAM — a marker classic gRPC
                #     over HTTP/2 DOES NOT HAVE (its terminal status rides in
                #     real HTTP/2 trailers). `_parse_connect_end_stream` would
                #     then find no `"error"` key in what are protobuf bytes and
                #     terminate the stream as END_OK, so one corrupt byte
                #     TRUNCATES the response and reports it complete.
                if flags == UInt8(0):
                    return StreamOutcome.message(payload_out^)
                if flags == ENVELOPE_FLAG_COMPRESSED:
                    # 0x01 is a VALID flag value — the peer compressed the
                    # message and we have no decompressor. A different question
                    # from a byte the spec admits no reading of, and pinned to
                    # UNKNOWN by `test_L5_stream`'s t8 case.
                    return self._terminate(
                        StreamOutcome.end_error(
                            GrpcError.simple(
                                GRPC_STATUS_UNKNOWN,
                                String(
                                    "komira_grpc: compressed envelopes not"
                                    " supported (Grpc-Encoding: identity"
                                    " only)"
                                ),
                            )
                        )
                    )
                return self._terminate(
                    StreamOutcome.end_error(
                        GrpcError.simple(
                            GRPC_STATUS_INTERNAL,
                            String(
                                "komira_grpc: received unexpected payload"
                                " format "
                            )
                            + String(Int(flags))
                            + " — the classic-gRPC Compressed-Flag is a 1-byte"
                            " unsigned integer whose only defined values are 0"
                            " and 1",
                        )
                    )
                )
        # No envelope available. Check for a pending status (classic gRPC
        # trailers arrived).
        if self._pending_status.__bool__():
            var err = self._pending_status.take()
            # The server's own non-OK status is the RPC's answer and outranks
            # any framing remainder — it states WHY the stream ended.
            if not err.is_ok():
                return self._terminate(StreamOutcome.end_error(err^))
            # ⭐ A TRUNCATED MESSAGE IS AN ERROR, NEVER A CLEAN END.
            #
            # The stream has ENDED and bytes are still buffered that do not
            # form a complete envelope: the peer stopped mid-message. Reporting
            # END_OK and silently DISCARDING those bytes would be a SILENT
            # WRONG ANSWER, the worst failure mode a decoder has (the class of
            # an `EOF_MID_RESPONSE` defect): the consumer would be told a
            # truncated response had completed successfully.
            #
            # grpc-go reads the 5-byte header then exactly `length` bytes, and
            # a short read at end-of-stream is `io.ErrUnexpectedEOF` — the RPC
            # FAILS. The evidence is in hand (`unconsumed_len()`); the check
            # lives HERE because the FRAMER cannot tell "feed me more" from
            # "this is truncated" — only its caller knows the stream ended,
            # and this is that caller.
            var leftover = self._framer.unconsumed_len()
            if leftover > 0:
                return self._terminate(
                    StreamOutcome.end_error(
                        GrpcError.simple(
                            GRPC_STATUS_INTERNAL,
                            self._truncation_message(leftover),
                        )
                    )
                )
            return self._terminate(StreamOutcome.end_ok())
        return StreamOutcome.pending()

    def _truncation_message(imm self, leftover: Int) -> String:
        """Name WHICH truncation this is — a partial length prefix reads very
        differently from a partial payload, and an operator seeing only
        "truncated" cannot tell them apart.

        Fewer than 5 buffered bytes means the stream ended INSIDE the length
        prefix; otherwise the header was readable and the payload was cut
        short.
        """
        if leftover < ENVELOPE_HEADER_SIZE:
            return (
                String(
                    "komira_grpc: stream ended inside the 5-byte length"
                    " prefix — "
                )
                + String(leftover)
                + " of 5 prefix bytes were received. A partial prefix is"
                " io.ErrUnexpectedEOF, not a clean end-of-stream"
            )
        return (
            String(
                "komira_grpc: stream ended mid-message — "
            )
            + String(leftover)
            + " byte(s) remained buffered as an INCOMPLETE envelope when the"
            " stream terminated. A truncated message fails the RPC; it must"
            " never be reported as a successful end-of-stream"
        )

    def _terminate(mut self, var outcome: StreamOutcome) -> StreamOutcome:
        """Record `outcome` as THE terminal outcome and return it.

        Every terminal path goes through here, which is what makes the
        stickiness a property of the DECODER rather than of each call site
        remembering to set a flag. The replay is `_replay_terminal`.
        """
        self._terminated = True
        self._terminal_code = outcome.error.code
        self._terminal_message = outcome.error.message
        var details_copy = Optional[List[UInt8]]()
        if outcome.error.details.__bool__():
            ref src = outcome.error.details.value()
            var c = List[UInt8]()
            for i in range(len(src)):
                c.append(src[i])
            details_copy = Optional[List[UInt8]](c^)
        self._terminal_details = details_copy^
        return outcome^

    def _replay_terminal(imm self) -> StreamOutcome:
        """Re-yield the recorded terminal outcome.

        ⚠ A TERMINAL ERROR IS AS STICKY AS A TERMINAL OK. Returning `end_ok()`
        here unconditionally means an error is reported exactly once and
        success forever after. Do not introduce
        that shortcut: `test_end_error_is_sticky_across_repeated_polls` and its
        two sibling cases (the Connect end-stream path and the
        unreadable-envelope path) exist to red the moment it comes back.
        """
        if self._terminal_code == GRPC_STATUS_OK:
            return StreamOutcome.end_ok()
        var details_copy = Optional[List[UInt8]]()
        if self._terminal_details.__bool__():
            ref src = self._terminal_details.value()
            var c = List[UInt8]()
            for i in range(len(src)):
                c.append(src[i])
            details_copy = Optional[List[UInt8]](c^)
        return StreamOutcome.end_error(
            GrpcError(
                self._terminal_code, self._terminal_message, details_copy^
            )
        )

    def _parse_connect_end_stream(
        mut self, var payload: List[UInt8]
    ) -> StreamOutcome:
        """Parse a Connect end-of-stream envelope payload into a terminating
        StreamOutcome.

        Shape:
          - success: `{}` → STREAM_OUTCOME_END_OK
          - error:   `{"error":{"code":"...","message":"..."}}` →
                     STREAM_OUTCOME_END_ERROR
        Implementation: look for an `"error"` substring; if present,
        re-parse the inner shape via parse_connect_error_json (which
        tolerates leading-whitespace + the wrapping `error:` key by virtue
        of `_extract_json_string_field`'s tolerant key scan).
        """
        # Empty `{}` or no "error" substring → success.
        var has_error_key = False
        var needle = String("\"error\"")
        var nb = needle.as_bytes()
        var hay_len = len(payload)
        var needle_len = len(nb)
        var i = 0
        while i + needle_len <= hay_len:
            var matches = True
            var j = 0
            while j < needle_len:
                if payload[i + j] != nb[j]:
                    matches = False
                    break
                j = j + 1
            if matches:
                has_error_key = True
                break
            i = i + 1
        if not has_error_key:
            return StreamOutcome.end_ok()
        # Has "error": parse it.
        var parsed_code = GRPC_STATUS_UNKNOWN
        var parsed_msg = String("")
        var parsed_ok: Bool
        try:
            var env = parse_connect_error_json(Span(payload))
            parsed_code = env.code
            parsed_msg = env.message
            parsed_ok = True
        except _:
            parsed_ok = False
        if parsed_ok:
            return StreamOutcome.end_error(
                GrpcError.simple(parsed_code, parsed_msg^)
            )
        return StreamOutcome.end_error(
            GrpcError.simple(
                GRPC_STATUS_UNKNOWN,
                String(
                    "komira_grpc: malformed Connect end-of-stream envelope"
                ),
            )
        )


# =============================================================================
# §3 — ClientStreamEncoder[P] — encode side for client-stream + bidi-request.
# =============================================================================


struct ClientStreamEncoder[P: Protocol](Movable, Deinitable):
    """Encodes one half of an HTTP/2 stream: the CLIENT → SERVER direction.

    Used by:
      - ClientStream (N req → 1 resp): caller calls `send(req)` N times
        then `mark_close()` to half-close.
      - BidiStream's request half: same shape, but the caller's `close_send`
        method drives mark_close while the response-half decoder continues.

    Pattern:
        for req in requests:
            encoder.encode_message(serialized_bytes)
        encoder.mark_close()
        # When the underlying StreamingBody.poll_frame is called by the
        # HTTP/2 codec:
        #   var chunk = encoder.drain_chunk(max_bytes)
        #   if chunk.empty() and encoder.is_closed(): return End frame
        #   else return Data(chunk)

    Encapsulation: P comptime parametric; ONE owned List[UInt8] buffer;
    NO shared pointer field with the response decoder (the two halves
    never alias).
    """

    var _buf: List[UInt8]
    """Outbound message-framing buffer. Each encode_message appends a
    5-byte envelope + payload."""

    var _drain_cursor: Int
    """Bytes already drained out via drain_chunk."""

    var _closed: Bool
    """True after mark_close() — no more sends accepted; once _buf is
    drained, the StreamingBody yields End and the HTTP/2 codec emits
    END_STREAM."""

    def __init__(out self):
        self._buf = List[UInt8]()
        self._drain_cursor = 0
        self._closed = False

    @staticmethod
    def new() -> ClientStreamEncoder[Self.P]:
        return ClientStreamEncoder[Self.P]()

    def encode_message(mut self, message_bytes: Span[UInt8, _]) raises:
        """Append one message (5-byte envelope + payload) to the outbound
        buffer.

        Raises if mark_close was already called (half-closed; no more
        sends allowed). This is the gRPC client_streaming `send(req)`
        operation.
        """
        if self._closed:
            raise Error(
                "komira_grpc.stream: ClientStreamEncoder.encode_message after"
                " mark_close — request side half-closed"
            )
        encode_stream_message[Self.P](self._buf, message_bytes)

    def mark_close(mut self):
        """Mark the encoder as half-closed (no more sends).

        After this, drain_chunk continues to drain remaining buffered bytes
        until exhausted; then `is_drained_and_closed()` returns True and the
        owning StreamingBody yields End → HTTP/2 codec emits END_STREAM.
        Half-close = the END_STREAM bit.
        """
        self._closed = True

    @always_inline
    def is_closed(imm self) -> Bool:
        return self._closed

    @always_inline
    def is_drained_and_closed(imm self) -> Bool:
        """True iff every byte has been drained AND mark_close was called.
        The StreamingBody.poll_frame caller treats this as the End signal."""
        return self._closed and self._drain_cursor >= len(self._buf)

    def drain_chunk(mut self, max_bytes: Int) -> List[UInt8]:
        """Drain up to `max_bytes` from the outbound buffer.

        Returns the next chunk (potentially empty if no buffered bytes
        remain). The HTTP/2 codec's StreamingBody adapter calls this in a
        loop; when the result is empty AND `is_drained_and_closed()`, the
        body yields End.

        This is a copy-out drain (the costly path is the per-byte loop);
        rope-style buffers could elide it.
        """
        var avail = len(self._buf) - self._drain_cursor
        if avail <= 0:
            return List[UInt8]()
        var to_take = avail if avail < max_bytes else max_bytes
        var out = List[UInt8]()
        var i = 0
        while i < to_take:
            out.append(self._buf[self._drain_cursor + i])
            i = i + 1
        self._drain_cursor += to_take
        return out^

    def rewind_for_reissue(mut self):
        """Reset the drain cursor to 0 so the WHOLE framed body can be drained
        again, byte-identically, for a re-issued attempt.

        ⚠ THIS IS NOT A GENERAL "UNDO". It exists for exactly one caller —
        `GrpcClient._send_client_stream_bounded_goaway_retry` — and it is sound
        there for a structural reason worth stating, because the opposite is
        easy to believe:

        **`drain_chunk` NEVER TRUNCATES `_buf`.** It is a COPY-OUT drain that
        copies `[_drain_cursor, _drain_cursor + n)` into a fresh `List` and then
        advances the cursor; `_buf` still holds every byte `encode_message` ever
        appended, for the whole life of the encoder. So "the encoder is empty
        after one drain" is false — only the CURSOR moved, and moving it back is
        the entire cost of making a client-streaming request replayable. There
        is no retained copy of the body and no extra allocation: a re-issue
        costs exactly what the first drain cost, and the SUCCESS path (one
        drain, cursor never rewound) does no extra work.

        `_closed` is deliberately NOT cleared. Half-close is a property of the
        REQUEST — the caller said "these N messages are the whole request" — and
        a re-issue sends that same whole request. Re-opening it would let a
        replay accept messages the original never carried.
        """
        self._drain_cursor = 0

    def pending_bytes(imm self) -> Int:
        """Number of buffered bytes still awaiting drain."""
        return len(self._buf) - self._drain_cursor


# =============================================================================
# §4 — BidiStreamCodec[P] — composition of both halves.
# =============================================================================


struct BidiStreamCodec[P: Protocol](Movable, Deinitable):
    """A bidi-stream's two independently-owned halves: request encoder
    + response decoder.

    No-aliasing: the two halves
    are TWO DISTINCT OWNED VALUES THAT NEVER ALIAS THE SAME BUFFER. Each
    half owns its own List[UInt8] / cursor. The HTTP/2 codec multiplexes
    the DATA frames of one stream in both directions, but at the Mojo
    level there is no shared mutable buffer behind a pointer.

    GrpcServerStream / GrpcClientStream / GrpcBidiStream as live structs
    in the call path are short-lived (one per RPC call) and carry NO
    long-lived borrowed-pointer fields — runtime is threaded per
    `next()` / `send()` call as `ref reactor` + `ref token` args.

    Encapsulation: P comptime parametric; encoder + decoder are two
    independently-owned Movable values; no shared field.
    """

    var encoder: ClientStreamEncoder[Self.P]
    """The request-side half. send/close_send drive this."""

    var decoder: ServerStreamDecoder[Self.P]
    """The response-side half. next() polls this."""

    def __init__(out self):
        self.encoder = ClientStreamEncoder[Self.P]()
        self.decoder = ServerStreamDecoder[Self.P]()

    @staticmethod
    def new() -> BidiStreamCodec[Self.P]:
        return BidiStreamCodec[Self.P]()
