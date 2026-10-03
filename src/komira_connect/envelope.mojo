# =============================================================================
# envelope.mojo — Connect-RPC 5-byte envelope framing
# =============================================================================
#
# Per https://connectrpc.com/docs/protocol#streaming-rpcs:
# every gRPC / gRPC-Web / Connect-RPC payload (request OR response, unary OR
# streaming) is preceded by a 5-byte envelope header:
#
#   +--------+--------+--------+--------+--------+
#   | flags  |       length (4 bytes, BE)        |   payload (length bytes)
#   +--------+--------+--------+--------+--------+
#
# - flags bit 0 (LSB):   COMPRESSED (1 = payload is compressed)
# - flags bit 7 (MSB):   END_STREAM (1 = grpc-web trailers-on-wire envelope;
#                         this is the LAST envelope in a stream, and the
#                         payload is the HTTP-style trailer block. gRPC over
#                         HTTP/2 uses real HTTP/2 trailers and does NOT set
#                         this bit; Connect-JSON uses a separate body
#                         structure and does NOT set this bit.)
#
# For unary RPC: exactly one envelope per request body, one per response body.
# For streaming RPC: many envelopes back-to-back; the LAST envelope on a
# grpc-web client-stream response carries trailers (END_STREAM bit set).
#
# Implementation notes:
# - encode: append-to-`List[UInt8]` — `out` is the parent body buffer.
# - decode: split a span into a sequence of (flags, payload-span) tuples.
# - All length arithmetic is `Int`; max length is 4 GiB - 1 (well past any
#   realistic single RPC message).
#
# Encapsulation: NO UnsafePointer in any sig; pure Span / List arithmetic.
# =============================================================================


from .status import (
    GRPC_STATUS_INTERNAL,
    format_grpc_status_error,
)


# =============================================================================
# §1 — Envelope constants
# =============================================================================

comptime ENVELOPE_HEADER_SIZE: Int = 5
"""Fixed 5-byte envelope header per Connect-RPC spec."""

comptime ENVELOPE_FLAG_COMPRESSED: UInt8 = 0x01
"""Flags bit 0 — payload is compressed (compression algo negotiated via
`Grpc-Encoding` / `Connect-Content-Encoding` header)."""

comptime ENVELOPE_FLAG_END_STREAM: UInt8 = 0x80
"""Flags bit 7 — grpc-web "trailers-on-wire" envelope. Last envelope in the
response; payload is the HTTP-style trailer block (gRPC trailers serialized
as an HTTP/1.1 trailer block: `grpc-status: 0\\r\\ngrpc-message: ok\\r\\n`)."""


# =============================================================================
# §2 — Envelope encode (write side)
# =============================================================================


def write_envelope_header(mut out: List[UInt8], flags: UInt8, length: Int):
    """Append the 5-byte envelope header to `out`.

    Length is encoded big-endian uint32; caller is responsible for appending
    the payload bytes immediately after.

    Args:
        out: Destination byte buffer (mutated).
        flags: Envelope flags byte (see ENVELOPE_FLAG_*).
        length: Payload length in bytes; MUST be >= 0 and <= 0xFFFFFFFF.
    """
    out.append(flags)
    # Big-endian uint32 length
    out.append(UInt8((length >> 24) & 0xFF))
    out.append(UInt8((length >> 16) & 0xFF))
    out.append(UInt8((length >> 8) & 0xFF))
    out.append(UInt8(length & 0xFF))


def write_envelope(mut out: List[UInt8], flags: UInt8, payload: Span[UInt8, _]):
    """Append a complete envelope (header + payload) to `out`.

    Args:
        out: Destination byte buffer (mutated).
        flags: Envelope flags byte (see ENVELOPE_FLAG_*).
        payload: Payload bytes to copy.
    """
    write_envelope_header(out, flags, len(payload))
    for i in range(len(payload)):
        out.append(payload[i])


# =============================================================================
# §3 — Envelope decode (read side)
# =============================================================================


@fieldwise_init
struct EnvelopeView[origin: Origin[mut=False]](
    Copyable, Movable, ImplicitlyCopyable, Deinitable
):
    """A decoded envelope: flags byte + a view onto the payload bytes.

    The payload is a `Span[UInt8, origin]` — borrows the underlying buffer.
    The lifetime of the EnvelopeView is bounded by the source buffer's
    lifetime.
    """

    var flags: UInt8
    """Envelope flags (combination of ENVELOPE_FLAG_*)."""

    var payload: Span[UInt8, Self.origin]
    """Payload bytes (view; not copied)."""

    def is_compressed(imm self) -> Bool:
        """True iff the COMPRESSED bit is set."""
        return (self.flags & ENVELOPE_FLAG_COMPRESSED) != 0

    def is_end_stream(imm self) -> Bool:
        """True iff the END_STREAM bit is set (grpc-web trailers-on-wire)."""
        return (self.flags & ENVELOPE_FLAG_END_STREAM) != 0


def read_envelope_header(buf: Span[UInt8, _], offset: Int) raises -> Tuple[UInt8, Int]:
    """Decode a 5-byte envelope header at `buf[offset:offset+5]`.

    Returns (flags, length). Raises if `buf` is too short.

    Args:
        buf: Source byte buffer.
        offset: Starting offset of the envelope header.

    Returns:
        Tuple (flags, length).
    """
    if offset + ENVELOPE_HEADER_SIZE > len(buf):
        # A short header is a TRUNCATED MESSAGE, and grpc-go answers a short
        # read of the 5-byte prefix with `codes.Internal` (io.ErrUnexpectedEOF
        # out of `parser.recvMsg`). Carry the `[grpc:13]` anchor so it is
        # visible to `parse_grpc_status_code` and every caller classifier —
        # without it the failure reaches the caller untyped.
        raise Error(
            format_grpc_status_error(
                GRPC_STATUS_INTERNAL,
                String(
                    "komira_connect.envelope: short read — need 5 bytes for"
                    " envelope header, have "
                )
                + String(len(buf) - offset),
            )
        )
    var flags = buf[offset]
    # Big-endian uint32 length
    var length = (
        (Int(buf[offset + 1]) << 24)
        | (Int(buf[offset + 2]) << 16)
        | (Int(buf[offset + 3]) << 8)
        | Int(buf[offset + 4])
    )
    return (flags, length)


def split_envelopes[
    origin: Origin[mut=False]
](buf: Span[UInt8, origin]) raises -> List[EnvelopeView[origin]]:
    """Split a contiguous byte span into a list of envelopes.

    Walks the buffer envelope-by-envelope; each iteration reads the 5-byte
    header + the declared-length payload, builds an EnvelopeView pointing
    into the same `buf`, and advances the cursor.

    Raises:
        - "short read" if the header runs past the buffer end.
        - "truncated payload" if the declared length exceeds remaining bytes.
        - "negative length" never (uint32 cast is unsigned), but treated as
          length >= 0 by Int reconstruction.

    Returns:
        A List of EnvelopeView, each carrying a Span view onto `buf`.
    """
    var result = List[EnvelopeView[origin]]()
    var cursor = 0
    while cursor < len(buf):
        var hdr = read_envelope_header(buf, cursor)
        var flags = hdr[0]
        var length = hdr[1]
        var payload_start = cursor + ENVELOPE_HEADER_SIZE
        var payload_end = payload_start + length
        if payload_end > len(buf):
            raise Error(
                format_grpc_status_error(
                    GRPC_STATUS_INTERNAL,
                    String(
                        "komira_connect.envelope: truncated payload — envelope"
                        " at offset "
                    )
                    + String(cursor)
                    + " declares "
                    + String(length)
                    + " bytes; only "
                    + String(len(buf) - payload_start)
                    + " remain",
                )
            )
        var payload_view = buf[payload_start:payload_end]
        result.append(EnvelopeView[origin](flags, payload_view))
        cursor = payload_end
    return result^


def split_first_envelope[
    origin: Origin[mut=False]
](
    buf: Span[UInt8, origin], offset: Int
) raises -> Tuple[EnvelopeView[origin], Int]:
    """Decode the next envelope at `buf[offset:]`; return (envelope, next_offset).

    Streaming-friendly variant of split_envelopes — returns ONE envelope
    plus the byte offset after it (for the caller to advance). Lets the
    caller iterate envelope-at-a-time without materializing the full List.
    """
    var hdr = read_envelope_header(buf, offset)
    var flags = hdr[0]
    var length = hdr[1]
    var payload_start = offset + ENVELOPE_HEADER_SIZE
    var payload_end = payload_start + length
    if payload_end > len(buf):
        raise Error(
            format_grpc_status_error(
                GRPC_STATUS_INTERNAL,
                String(
                    "komira_connect.envelope: truncated payload — envelope at"
                    " offset "
                )
                + String(offset)
                + " declares "
                + String(length)
                + " bytes; only "
                + String(len(buf) - payload_start)
                + " remain",
            )
        )
    var payload_view = buf[payload_start:payload_end]
    return (EnvelopeView[origin](flags, payload_view), payload_end)
