# =============================================================================
# komira_grpc/framing.mojo — Client-side streaming-envelope framer
# =============================================================================
#
#   Classic gRPC frames every message — request and response, in every
#   streaming mode — with a 5-byte prefix:
#     [flags:1][length:4-BE][payload:<length>]
#
#   The classic-gRPC framer in `komira_grpc` reads the 5-byte prefix off
#   the Frame-shaped response body and accumulates <length> bytes before
#   handing one complete message to Serializable.decode[W].
#
#   The 5-byte length-prefix framer is therefore one runtime primitive
#   shared by classic-gRPC (all modes) and Connect-streaming; only
#   Connect-unary skips it.
#
# This module ships `ClientFramer`: a stateful, sliding-buffer framer that
# accepts `Data(List[UInt8])` BodyFrame payloads (potentially mid-envelope
# fragmented) and yields complete envelopes one at a time. The streaming-mode
# `next()` loop drives it.
#
# Design decision: the framer ACCUMULATES into a single owned `List[UInt8]`
# buffer keyed by a `_cursor` head offset. When a complete envelope is
# available, `try_pop_envelope` returns Some(EnvelopeView pointing into the
# buffer) and advances `_cursor`. We periodically `_compact` the prefix to
# avoid unbounded buffer growth — once `_cursor` exceeds half the buffer
# size, the prefix is dropped via List-truncate-from-front (cheap memmove
# bounded by remainder size).
#
# Encapsulation: NO UnsafePointer in any public sig. The framer's buffer
# is `List[UInt8]` (owned). Envelope views are typed Span[UInt8, ...]
# parametric on the framer's origin (no wildcards).
# =============================================================================

from komira_connect.envelope import (
    ENVELOPE_HEADER_SIZE,
    ENVELOPE_FLAG_COMPRESSED,
    ENVELOPE_FLAG_END_STREAM,
)
from komira_connect.status import (
    GRPC_STATUS_INTERNAL,
    GRPC_STATUS_RESOURCE_EXHAUSTED,
    format_grpc_status_error,
)


# =============================================================================
# MAX RECEIVE MESSAGE SIZE — a limit on untrusted input.
#
# `try_pop_envelope` returns None while `avail < ENVELOPE_HEADER_SIZE + length`
# and the caller keeps feeding, so without a limit a hostile SERVER declaring
# length = 0xFFFFFFFF drives the CLIENT to accumulate ~4 GiB in `_buf` before a
# single message is ever produced. `_maybe_compact` cannot help: `_cursor`
# never advances, so there is no consumed prefix to drop.
#
# This is a MEMORY-exhaustion hazard, not an arithmetic one — the 4-byte BE
# decode into a 64-bit Int cannot go negative, and the `length < 0` check below
# correctly describes itself as unreachable. It therefore does not depend on
# ASSERT at all; it is simply a missing limit on untrusted input, and shipping
# at ASSERT=none removes nothing that was protecting it.
#
# 4 MiB is gRPC's own documented default `max_receive_message_length`, and the
# spec's mandated response to exceeding it is RESOURCE_EXHAUSTED — which is why
# the raise below names that status in its message rather than saying
# "too large".
# =============================================================================

comptime MAX_RECV_MESSAGE_SIZE: Int = 4 * 1024 * 1024


# =============================================================================
# §1 — ClientFramer state.
# =============================================================================


struct ClientFramer(Movable, Deinitable):
    """Sliding-buffer streaming-envelope framer.

    Pattern (per `next()` call on a streaming-mode stream):
      1. Caller pulls a BodyFrame via `RecvRingBody.poll_frame[RT]`.
      2. If `Data(bytes)`: `framer.feed(bytes)` appends to internal buf.
      3. `framer.try_pop_envelope()` returns Some(payload+flags) if a
         complete envelope is now buffered; else None — caller polls
         again.
      4. If `End` or `Trailers`: caller exits the inner loop; if there
         was a final non-OK trailer status, raise GrpcError.

    Movable, NOT Copyable — owns the accumulator buffer.

    Field invariants:
      * `_cursor` is always ≤ `len(_buf)`.
      * Bytes `_buf[_cursor:]` are the unconsumed portion. When `_cursor
        == len(_buf)`, the framer is fully drained (caller should keep
        feeding).
      * Compaction (`_compact`) shifts `_buf[_cursor:]` to `_buf[0:]` and
        resets `_cursor=0`. Triggered when `_cursor > len(_buf) // 2 AND
        len(_buf) > 256` to bound the unbounded-growth risk.
    """

    var _buf: List[UInt8]
    """Accumulator buffer. Grows on feed(), compacts on demand."""

    var _cursor: Int
    """Read head into `_buf`. `_buf[_cursor:]` is the unconsumed remainder."""

    def __init__(out self):
        self._buf = List[UInt8]()
        self._cursor = 0

    @staticmethod
    def new() -> ClientFramer:
        return ClientFramer()

    @always_inline
    def unconsumed_len(imm self) -> Int:
        """Number of bytes still buffered after the read head."""
        return len(self._buf) - self._cursor

    def feed(mut self, data: Span[UInt8, _]):
        """Append `data` to the accumulator buffer.

        Caller produces `data` from a `RecvRingBody.poll_frame` Data
        BodyFrame; the chunk may be any length, possibly mid-envelope.
        """
        var n = len(data)
        var i = 0
        while i < n:
            self._buf.append(data[i])
            i = i + 1

    def feed_owned(mut self, var data: List[UInt8]):
        """Append `data` to the accumulator. Takes ownership (move) of
        the incoming List so we avoid the per-byte copy when the BodyFrame
        already owns the chunk's bytes.

        Optimisation: if `_cursor == len(_buf)` (buffer fully drained) AND
        the incoming data is non-empty, swap-extend rather than per-byte
        append.
        """
        if self._cursor == len(self._buf):
            # Drained — replace the buffer outright and reset cursor.
            self._buf = data^
            self._cursor = 0
            return
        # Otherwise append byte-by-byte. The owned List `data` is dropped
        # at scope end.
        var n = len(data)
        var i = 0
        while i < n:
            self._buf.append(data[i])
            i = i + 1

    def try_pop_envelope(mut self) raises -> Optional[PoppedEnvelope]:
        """If a complete envelope is buffered, consume it and return
        Some(PoppedEnvelope); else None — caller should `feed` more.

        Raises only on a malformed envelope (the 5-byte header read can't
        fail bytewise; the `length` field is unsigned uint32 and bounded
        by the buffer's actual size).

        PoppedEnvelope OWNS its payload bytes — the implementation copies
        out of `_buf` so the caller doesn't retain a view that ties to
        the framer's internal storage (avoids any lifetime confusion).
        This is a copy; rope-style buffers could elide it.
        """
        var avail = self.unconsumed_len()
        if avail < ENVELOPE_HEADER_SIZE:
            return Optional[PoppedEnvelope]()
        # Peek the header.
        var base = self._cursor
        var flags = self._buf[base]
        var length = (
            (Int(self._buf[base + 1]) << 24)
            | (Int(self._buf[base + 2]) << 16)
            | (Int(self._buf[base + 3]) << 8)
            | Int(self._buf[base + 4])
        )
        if length < 0:
            raise Error(
                format_grpc_status_error(
                    GRPC_STATUS_INTERNAL,
                    String(
                        "komira_grpc.framing: negative envelope length"
                        " (impossible from uint32 decode) — buffer corruption"
                    ),
                )
            )
        # Reject the DECLARED size before committing to buffer it. Checked
        # here — at the moment the header is first parsed — and not on every
        # `feed`, so the accumulation path stays a plain append with no
        # per-byte arithmetic. See MAX_RECV_MESSAGE_SIZE above. Without it a
        # header-only feed declaring 0xFFFFFFFF returns None, committing the
        # client to accumulate 4294967295 bytes before any message exists.
        if length > MAX_RECV_MESSAGE_SIZE:
            # ⚠ THE `[grpc:8]` ANCHOR IS THE POINT, NOT THE PROSE. Naming
            # RESOURCE_EXHAUSTED in the text tells a human the right word, but
            # without the anchor every classifier sees an anchorless transport
            # error (`parse_grpc_status_code` -> -1). Naming a status in prose
            # is not carrying a status. Both are kept: the anchor for the
            # machine, the sentence for the human.
            raise Error(
                format_grpc_status_error(
                    GRPC_STATUS_RESOURCE_EXHAUSTED,
                    String(
                        "komira_grpc.framing: envelope declares a payload of "
                    )
                    + String(length)
                    + " bytes, which exceeds the maximum receive message size"
                    " of "
                    + String(MAX_RECV_MESSAGE_SIZE)
                    + " bytes (gRPC RESOURCE_EXHAUSTED); refusing to buffer it",
                )
            )
        var total_needed = ENVELOPE_HEADER_SIZE + length
        if avail < total_needed:
            return Optional[PoppedEnvelope]()
        # Complete envelope is available — copy out the payload.
        var payload = List[UInt8]()
        var payload_start = base + ENVELOPE_HEADER_SIZE
        var payload_end = payload_start + length
        var i = payload_start
        while i < payload_end:
            payload.append(self._buf[i])
            i = i + 1
        # Advance the read head.
        self._cursor = payload_end
        # Maybe compact to bound memory.
        self._maybe_compact()
        return Optional(PoppedEnvelope(flags, payload^))

    def _maybe_compact(mut self):
        """Drop the consumed prefix if the read head has consumed more
        than half the buffer AND the buffer is larger than 256 bytes.

        This bounds the buffer at roughly 2x the peak unconsumed-frame
        size. For typical gRPC messages (~hundreds of bytes to a few KB)
        the compact runs once per few frames.
        """
        var blen = len(self._buf)
        if self._cursor < blen // 2 or blen <= 256:
            return
        # Shift the remainder down. We copy into a fresh List rather than
        # in-place memmove because the public List API doesn't expose a
        # `truncate_from_front` primitive in 1.0.0b1.
        var remainder = List[UInt8]()
        var n = blen
        var i = self._cursor
        while i < n:
            remainder.append(self._buf[i])
            i = i + 1
        self._buf = remainder^
        self._cursor = 0

    def reset(mut self):
        """Reset the framer to empty state. Used when a stream is
        starting over (e.g. on retry once the body is replayable)."""
        self._buf.clear()
        self._cursor = 0


# =============================================================================
# §2 — PoppedEnvelope — the typed result of try_pop_envelope.
# =============================================================================


struct PoppedEnvelope(Movable, Deinitable):
    """A complete envelope extracted from the framer.

    OWNS its payload bytes (Movable, not Copyable) so the caller is free
    to pass it across method boundaries without lifetime concerns.

    Movable: the typical pattern is `var env = framer.try_pop_envelope().value()`
    then move `env.payload^` into a decoder.
    """

    var flags: UInt8
    """Envelope flags byte (combination of ENVELOPE_FLAG_COMPRESSED +
    ENVELOPE_FLAG_END_STREAM)."""

    var payload: List[UInt8]
    """Owned payload bytes. Movable so the consumer can move into a decoder."""

    def __init__(out self, flags: UInt8, var payload: List[UInt8]):
        self.flags = flags
        self.payload = payload^

    @always_inline
    def is_compressed(imm self) -> Bool:
        """True iff the COMPRESSED bit (bit 0) is set."""
        return (self.flags & ENVELOPE_FLAG_COMPRESSED) != 0

    @always_inline
    def is_end_stream(imm self) -> Bool:
        """True iff the END_STREAM bit (bit 7) is set — Connect-streaming's
        end-of-stream envelope, whose payload is the JSON status envelope."""
        return (self.flags & ENVELOPE_FLAG_END_STREAM) != 0


# =============================================================================
# §3 — write_envelope_to (mirror — for client-direction request encoding).
# =============================================================================
#
# `komira_connect.envelope.write_envelope` already does the right thing
# (mutates a `List[UInt8]`); callers use it directly, so there is no new
# symbol here.
# =============================================================================
