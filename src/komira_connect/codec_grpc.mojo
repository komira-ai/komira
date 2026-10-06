# =============================================================================
# codec_grpc.mojo — `grpc+proto` codec (HTTP/2 only)
# =============================================================================
#
# Per https://grpc.io/docs/guides/wire-format/ + the gRPC HTTP/2 spec:
# (https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md).
#
# The `grpc+proto` codec is:
#   - Content-Type: `application/grpc+proto` (or just `application/grpc`)
#   - Transport:    HTTP/2 ONLY (status in HTTP/2 trailers — HTTP/1.1
#                   doesn't support trailers in practice, so gRPC requires h2)
#   - Body wire:    [envelope (5 bytes)] [protobuf message bytes]
#                   For unary: one envelope. For streaming: many envelopes
#                   back-to-back over the lifetime of the stream.
#   - Status wire:  HTTP/2 trailers — `grpc-status: <code>` +
#                   optionally `grpc-message: <text>`. Always sent
#                   (even for success, code=0).
#
# This module is direction-agnostic: it provides the encode + decode
# primitives that BOTH the server and the gRPC client share (one
# implementation, no parallel API).
#
# Encapsulation: NO UnsafePointer in any public sig; ZERO wildcard origins.
# =============================================================================

from .envelope import (
    ENVELOPE_HEADER_SIZE,
    ENVELOPE_FLAG_COMPRESSED,
    EnvelopeView,
    write_envelope,
    split_first_envelope,
)
from .status import (
    GRPC_STATUS_OK,
    GRPC_STATUS_INTERNAL,
    GRPC_STATUS_UNIMPLEMENTED,
    format_grpc_status_error,
    grpc_status_to_http_status,
)


# =============================================================================
# §1 — Content-Type constants
# =============================================================================

comptime GRPC_CONTENT_TYPE: String = "application/grpc"
"""Bare `application/grpc` — gRPC default; the protobuf wire is implied."""

comptime GRPC_CONTENT_TYPE_PROTO: String = "application/grpc+proto"
"""Explicit `application/grpc+proto`."""


# =============================================================================
# §2 — gRPC trailer key constants (HTTP/2 trailers — lowercase per RFC 7540)
# =============================================================================

comptime GRPC_TRAILER_STATUS: String = "grpc-status"
"""Trailer key: `grpc-status` (always emitted on response; the gRPC
canonical numeric code 0..16)."""

comptime GRPC_TRAILER_MESSAGE: String = "grpc-message"
"""Trailer key: `grpc-message` (optional; human-readable error text;
percent-encoded per gRPC spec)."""


# =============================================================================
# §3 — Encode side: wrap a protobuf message into a single-envelope body.
# =============================================================================


def grpc_encode_unary(message: Span[UInt8, _]) -> List[UInt8]:
    """Encode a single protobuf message as a gRPC unary request/response body.

    Wraps `message` in exactly one 5-byte envelope with flags=0 (uncompressed).
    Suitable for both unary requests AND unary responses.

    For streaming, call `grpc_append_message` repeatedly on a single buffer.
    """
    var out = List[UInt8]()
    write_envelope(out, 0x00, message)
    return out^


def grpc_append_message(mut out: List[UInt8], message: Span[UInt8, _]):
    """Append one envelope-framed message to a streaming body buffer.

    Mutates `out` in place; each call appends 5 + len(message) bytes.
    Suitable for server-streaming or client-streaming bodies where multiple
    messages are concatenated.
    """
    write_envelope(out, 0x00, message)


# =============================================================================
# §4 — Decode side: extract protobuf message(s) from a gRPC body.
# =============================================================================


def grpc_decode_unary[
    origin: Origin[mut=False]
](body: Span[UInt8, origin]) raises -> Span[UInt8, origin]:
    """Extract the single message from a unary gRPC body.

    Raises if the body is malformed (truncated envelope, multiple envelopes,
    or a compressed envelope: compression is not supported).

    Returns:
        A Span view into `body` pointing at the protobuf message bytes.
    """
    # ⚠ EVERY ARM BELOW CARRIES A `[grpc:<N>]` ANCHOR, AND THAT IS LOAD-BEARING.
    # Without it a malformed gRPC response reaches the caller as an UNTYPED
    # error: `parse_grpc_status_code` returns -1, `is_retryable_grpc_error`
    # returns False under every policy, and every caller-side classifier
    # misses it -- a response cut off mid-message would escape retry.
    # The status each arm carries is the one grpc-go answers with
    # (`parser.recvMsg` / `recvAndDecompress`): INTERNAL for a malformed or
    # truncated message, UNIMPLEMENTED for a compressed message with no
    # decompressor installed. Do NOT drop the anchor from a raise here.
    if len(body) == 0:
        raise Error(
            format_grpc_status_error(
                GRPC_STATUS_INTERNAL,
                String(
                    "komira_connect.grpc: empty body — expected at least one"
                    " envelope"
                ),
            )
        )
    # `split_first_envelope` raises its own `[grpc:13]`-anchored truncation /
    # short-header error; it is already typed and passes through unchanged.
    var result = split_first_envelope(body, 0)
    var env = result[0]
    var next_offset = result[1]
    if env.is_compressed():
        # grpc-go: `codes.Unimplemented, "grpc: Decompressor is not installed
        # for grpc-encoding %q"` — the peer used a compression the receiver
        # cannot undo, which is an unimplemented capability, not corruption.
        raise Error(
            format_grpc_status_error(
                GRPC_STATUS_UNIMPLEMENTED,
                String(
                    "komira_connect.grpc: compressed envelopes not supported"
                ),
            )
        )
    if next_offset != len(body):
        raise Error(
            format_grpc_status_error(
                GRPC_STATUS_INTERNAL,
                String(
                    "komira_connect.grpc: unary body has trailing bytes after"
                    " envelope — expected exactly one envelope"
                ),
            )
        )
    return env.payload


def grpc_decode_stream[
    origin: Origin[mut=False]
](body: Span[UInt8, origin]) raises -> List[EnvelopeView[origin]]:
    """Extract all messages from a streaming gRPC body.

    Returns a List of EnvelopeView, one per envelope. Each view's payload
    is the raw protobuf bytes. Raises on malformed framing.
    """
    var envelopes = List[EnvelopeView[origin]]()
    var cursor = 0
    while cursor < len(body):
        var step = split_first_envelope(body, cursor)
        var env = step[0]
        var next_offset = step[1]
        if env.is_compressed():
            raise Error(
                format_grpc_status_error(
                    GRPC_STATUS_UNIMPLEMENTED,
                    String(
                        "komira_connect.grpc: compressed envelopes not"
                        " supported"
                    ),
                )
            )
        envelopes.append(env)
        cursor = next_offset
    return envelopes^


# =============================================================================
# §5 — Trailer encoding: build the `grpc-status` / `grpc-message` trailer pair.
# =============================================================================


@fieldwise_init
struct GrpcTrailers(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    """The two-field trailer block that closes every gRPC response stream.

    Always carries grpc-status (the numeric code). grpc-message is optional
    (only sent on non-OK responses).
    """

    var status_code: UInt8
    """GRPC canonical code 0..16. Always sent on response."""

    var message: String
    """Human-readable error text. Empty for OK; percent-encoded for errors."""


def grpc_make_trailers(status_code: UInt8, message: String) -> GrpcTrailers:
    """Build a GrpcTrailers value. Caller emits the trailers via the h2
    codec's per-stream WriteTrailers hook."""
    return GrpcTrailers(status_code, message)


def grpc_make_ok_trailers() -> GrpcTrailers:
    """Build the canonical success trailer pair (`grpc-status: 0`)."""
    return GrpcTrailers(GRPC_STATUS_OK, String(""))


# =============================================================================
# §6 — Trailer percent-encoding (gRPC spec §"Status Header Value").
# =============================================================================
#
# Per https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md#responses
# the grpc-message header value uses percent-encoding for bytes outside
# the US-ASCII printable range (0x20..0x7e) and for the literal '%' character.
# This avoids HTTP-header-value violations for arbitrary error strings.
# =============================================================================


def grpc_percent_encode_message(text: String) -> String:
    """Percent-encode a grpc-message header value per the gRPC HTTP/2 spec.

    Characters in the US-ASCII printable range [0x20..0x7e] (excluding '%')
    pass through verbatim. The '%' character itself is encoded as `%25`.
    All other byte values become `%XX` (uppercase hex).

    Operates on the UTF-8 bytes of `text`, so a non-ASCII character becomes
    one `%XX` per byte: `café` is `caf%C3%A9`. (Reading `text[byte=i]` would
    assert on the first continuation byte and abort the process.)
    """
    return grpc_percent_encode_bytes(text.as_bytes())


def grpc_percent_encode_bytes(text: Span[UInt8, _]) -> String:
    """Percent-encode a raw byte sequence (the byte-level form). Output is
    ASCII-only so safe to return as String."""
    var out_bytes = List[UInt8]()
    var n = len(text)
    for i in range(n):
        var b = Int(text[i])
        if b == ord("%"):
            out_bytes.append(UInt8(ord("%")))
            out_bytes.append(UInt8(ord("2")))
            out_bytes.append(UInt8(ord("5")))
        elif b >= 0x20 and b <= 0x7E:
            out_bytes.append(UInt8(b))
        else:
            # %XX uppercase hex
            out_bytes.append(UInt8(ord("%")))
            out_bytes.append(_hex_char_uppercase((b >> 4) & 0x0F))
            out_bytes.append(_hex_char_uppercase(b & 0x0F))
    return String(unsafe_from_utf8=Span(out_bytes))


def grpc_percent_decode_message(text: String) raises -> String:
    """Reverse of grpc_percent_encode_message.

    Decoded byte sequence is wrapped in a String via unsafe_from_utf8 —
    non-UTF-8 bytes are preserved at the byte level. Raises on malformed %XX.
    """
    var n = text.byte_length()
    var out_bytes = List[UInt8]()
    var i = 0
    while i < n:
        var b = Int(text.as_bytes()[i])
        if b == ord("%"):
            if i + 2 >= n:
                raise Error("komira_connect.grpc: truncated %XX at end of grpc-message")
            var h1 = _hex_to_int(Int(text.as_bytes()[i + 1]))
            var h2 = _hex_to_int(Int(text.as_bytes()[i + 2]))
            if h1 < 0 or h2 < 0:
                raise Error("komira_connect.grpc: malformed %XX in grpc-message")
            out_bytes.append(UInt8((h1 << 4) | h2))
            i += 3
        else:
            out_bytes.append(UInt8(b))
            i += 1
    return String(unsafe_from_utf8=Span(out_bytes))


@always_inline
def _hex_uppercase(nibble: Int) -> String:
    """Convert a 4-bit value to an uppercase hex character (0..F)."""
    if nibble < 10:
        return String(chr(ord("0") + nibble))
    return String(chr(ord("A") + nibble - 10))


@always_inline
def _hex_char_uppercase(nibble: Int) -> UInt8:
    """Convert a 4-bit value to the ASCII byte for its uppercase hex char."""
    if nibble < 10:
        return UInt8(ord("0") + nibble)
    return UInt8(ord("A") + nibble - 10)


@always_inline
def _hex_to_int(byte: Int) -> Int:
    """Convert an ASCII hex char byte to its 4-bit value, or -1 if invalid."""
    if byte >= ord("0") and byte <= ord("9"):
        return byte - ord("0")
    if byte >= ord("A") and byte <= ord("F"):
        return byte - ord("A") + 10
    if byte >= ord("a") and byte <= ord("f"):
        return byte - ord("a") + 10
    return -1
