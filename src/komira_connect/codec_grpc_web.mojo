# =============================================================================
# codec_grpc_web.mojo — `grpc-web+proto` codec
# =============================================================================
#
# Per https://github.com/grpc/grpc-web/blob/master/doc/browser-features.md
# + the gRPC-Web spec:
# (https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-WEB.md).
#
# The `grpc-web+proto` codec is:
#   - Content-Type: `application/grpc-web+proto` (or `application/grpc-web`)
#   - Transport:    HTTP/1.1 OR HTTP/2 (designed for browsers; trailers
#                   can't reliably traverse HTTP/1.1 hops, so gRPC-Web
#                   moves trailers INTO the response body as a last
#                   `END_STREAM` envelope.)
#   - Body wire:    [envelope (5 bytes)] [protobuf message bytes] ... [envelope (5 bytes, END_STREAM flag set)] [HTTP-style trailer block]
#                   The last envelope carries the trailer block in HTTP/1.1
#                   trailer-header syntax: `grpc-status: 0\r\ngrpc-message: ok\r\n`.
#                   For HTTP/2 transport: the same trailers-on-wire shape
#                   (gRPC-Web is wire-compatible across HTTP/1.1 and HTTP/2).
#   - Status wire:  In the LAST envelope body (END_STREAM flag = 0x80).
#
# Reuses the message-framing primitives from codec_grpc — the only
# wire-level difference is where trailers go.
#
# Encapsulation: NO UnsafePointer in any public sig; ZERO wildcard origins.
# =============================================================================

from .envelope import (
    ENVELOPE_HEADER_SIZE,
    ENVELOPE_FLAG_COMPRESSED,
    ENVELOPE_FLAG_END_STREAM,
    EnvelopeView,
    write_envelope,
    split_first_envelope,
    split_envelopes,
)
from .codec_grpc import (
    GrpcTrailers,
    GRPC_TRAILER_STATUS,
    GRPC_TRAILER_MESSAGE,
    grpc_percent_encode_message,
    grpc_percent_decode_message,
)
from .status import (
    GRPC_STATUS_OK,
    GRPC_STATUS_INTERNAL,
    GRPC_STATUS_UNKNOWN,
)


# =============================================================================
# §1 — Content-Type constants
# =============================================================================

comptime GRPC_WEB_CONTENT_TYPE: String = "application/grpc-web"
"""Bare `application/grpc-web` — gRPC-Web default; the protobuf wire is implied."""

comptime GRPC_WEB_CONTENT_TYPE_PROTO: String = "application/grpc-web+proto"
"""Explicit `application/grpc-web+proto`."""


# =============================================================================
# §2 — Encode side: data envelopes + the trailer envelope.
# =============================================================================


def grpc_web_encode_unary(
    message: Span[UInt8, _], trailers: GrpcTrailers
) -> List[UInt8]:
    """Encode a unary gRPC-Web response: one data envelope + one trailer envelope.

    For unary requests, only the data envelope is sent (no trailers from
    the client). Use `grpc_web_encode_request(message)` instead.
    """
    var out = List[UInt8]()
    write_envelope(out, 0x00, message)
    # Trailer block
    var trailer_block = _format_trailer_block(trailers)
    write_envelope(out, ENVELOPE_FLAG_END_STREAM, Span(trailer_block))
    return out^


def grpc_web_encode_request(message: Span[UInt8, _]) -> List[UInt8]:
    """Encode a unary gRPC-Web request body: single data envelope, no trailers.

    Clients send only data envelopes; trailers are server → client only.
    """
    var out = List[UInt8]()
    write_envelope(out, 0x00, message)
    return out^


def grpc_web_append_message(mut out: List[UInt8], message: Span[UInt8, _]):
    """Append one data envelope to a streaming gRPC-Web body buffer."""
    write_envelope(out, 0x00, message)


def grpc_web_append_trailers(mut out: List[UInt8], trailers: GrpcTrailers):
    """Append the closing trailer envelope to a streaming gRPC-Web body buffer.

    The END_STREAM flag is set on the envelope; the payload is the
    HTTP-style trailer block (`grpc-status: N\\r\\ngrpc-message: text\\r\\n`).
    """
    var trailer_block = _format_trailer_block(trailers)
    write_envelope(out, ENVELOPE_FLAG_END_STREAM, Span(trailer_block))


def _format_trailer_block(trailers: GrpcTrailers) -> List[UInt8]:
    """Format the trailer-envelope payload as HTTP/1.1 trailer-block syntax.

    Shape: `grpc-status: N\\r\\ngrpc-message: percent-encoded-text\\r\\n`.

    grpc-message is omitted when the message string is empty (gRPC spec:
    grpc-message is only required for non-OK responses).
    """
    # Copied as bytes: the lines are ASCII today (the message is
    # percent-encoded), but indexing `line[byte=i]` would abort the process on
    # the first UTF-8 continuation byte if that ever changed.
    var out = List[UInt8]()
    var status_line = String("grpc-status: ") + String(Int(trailers.status_code)) + "\r\n"
    out.extend(status_line.as_bytes())
    if trailers.message.byte_length() > 0:
        var encoded = grpc_percent_encode_message(trailers.message)
        var msg_line = String("grpc-message: ") + encoded + "\r\n"
        out.extend(msg_line.as_bytes())
    return out^


# =============================================================================
# §3 — Decode side: split data envelopes from the trailer envelope.
# =============================================================================


@fieldwise_init
struct GrpcWebDecodedBody[origin: Origin[mut=False]](
    Movable, Deinitable
):
    """A fully-decoded gRPC-Web response body.

    `messages` lists every data envelope's payload (one for unary).
    `trailers` is the closing trailer envelope decoded into GrpcTrailers.

    For requests (client → server, no trailers): `trailers.status_code = OK`
    and `trailers.message = ""` (sentinel for "no trailers seen").
    """

    var messages: List[Span[UInt8, Self.origin]]
    var trailers: GrpcTrailers
    var saw_trailers: Bool


def grpc_web_decode_response[
    origin: Origin[mut=False]
](body: Span[UInt8, origin]) raises -> GrpcWebDecodedBody[origin]:
    """Split a gRPC-Web response body into data messages + trailers.

    Walks the body envelope-by-envelope. Every envelope with END_STREAM
    cleared is a data message; the final envelope with END_STREAM set is
    the trailer block (which is decoded into GrpcTrailers).

    Raises if:
      - any envelope is compressed (compression is not supported)
      - the trailer block is malformed (missing grpc-status header, etc.)
      - more than one trailer envelope is seen
    """
    var messages = List[Span[UInt8, origin]]()
    var trailers = GrpcTrailers(GRPC_STATUS_OK, String(""))
    var saw_trailers = False
    var cursor = 0
    while cursor < len(body):
        var step = split_first_envelope(body, cursor)
        var env = step[0]
        var next_offset = step[1]
        if env.is_compressed():
            raise Error("komira_connect.grpc_web: compressed envelopes not supported")
        if env.is_end_stream():
            if saw_trailers:
                raise Error("komira_connect.grpc_web: duplicate trailer envelope")
            trailers = _parse_trailer_block(env.payload)
            saw_trailers = True
        else:
            messages.append(env.payload)
        cursor = next_offset
    return GrpcWebDecodedBody[origin](messages^, trailers, saw_trailers)


def grpc_web_decode_request[
    origin: Origin[mut=False]
](body: Span[UInt8, origin]) raises -> List[Span[UInt8, origin]]:
    """Split a gRPC-Web REQUEST body into data messages (no trailers expected).

    Clients send only data envelopes. Raises if any envelope has the
    END_STREAM flag (trailers are server → client only).
    """
    var messages = List[Span[UInt8, origin]]()
    var cursor = 0
    while cursor < len(body):
        var step = split_first_envelope(body, cursor)
        var env = step[0]
        var next_offset = step[1]
        if env.is_compressed():
            raise Error("komira_connect.grpc_web: compressed envelopes not supported")
        if env.is_end_stream():
            raise Error("komira_connect.grpc_web: client request body cannot carry trailers")
        messages.append(env.payload)
        cursor = next_offset
    return messages^


def _parse_trailer_block(block: Span[UInt8, _]) raises -> GrpcTrailers:
    """Parse the HTTP/1.1-style trailer block payload into GrpcTrailers.

    Expected shape: `grpc-status: N\\r\\ngrpc-message: text\\r\\n`. Lines may
    be in any order; lines NOT matching `grpc-status` / `grpc-message` are
    ignored (forward-compat).

    Raises if grpc-status is missing or malformed.
    """
    var status_code = UInt8(0)
    var status_seen = False
    var message = String("")

    # Split block into lines by \r\n
    var lines = _split_lines(block)
    for li in range(len(lines)):
        var line = lines[li]
        # Find the ':' separator
        var colon_idx = -1
        for ci in range(len(line)):
            if line[ci] == UInt8(ord(":")):
                colon_idx = ci
                break
        if colon_idx < 0:
            continue
        # Extract key (case-insensitive match) and value (strip leading space)
        var key_lower = _ascii_lower_span(line[0:colon_idx])
        var value_start = colon_idx + 1
        if value_start < len(line) and line[value_start] == UInt8(ord(" ")):
            value_start += 1
        var value_span = line[value_start:len(line)]
        if _span_equals_str(Span(key_lower), GRPC_TRAILER_STATUS):
            status_code = _parse_uint8_decimal(value_span)
            status_seen = True
        elif _span_equals_str(Span(key_lower), GRPC_TRAILER_MESSAGE):
            message = grpc_percent_decode_message(_span_to_string(value_span))

    if not status_seen:
        raise Error(
            "komira_connect.grpc_web: trailer block missing required `grpc-status` header"
        )
    return GrpcTrailers(status_code, message^)


def _split_lines[
    origin: Origin[mut=False]
](block: Span[UInt8, origin]) -> List[Span[UInt8, origin]]:
    """Split a CRLF-delimited block into a list of line spans (lines do NOT
    include the trailing CRLF). Empty trailing lines are dropped."""
    var lines = List[Span[UInt8, origin]]()
    var n = len(block)
    var line_start = 0
    var i = 0
    while i < n:
        if i + 1 < n and block[i] == UInt8(ord("\r")) and block[i + 1] == UInt8(ord("\n")):
            if i > line_start:
                lines.append(block[line_start:i])
            line_start = i + 2
            i += 2
        else:
            i += 1
    # Tail without trailing CRLF — still valid line
    if line_start < n:
        lines.append(block[line_start:n])
    return lines^


def _ascii_lower_span(s: Span[UInt8, _]) -> List[UInt8]:
    """Build a lowercase copy of an ASCII span (only A..Z folded; non-ASCII
    bytes pass through unchanged)."""
    var out = List[UInt8](capacity=len(s))
    for i in range(len(s)):
        var b = s[i]
        if b >= UInt8(ord("A")) and b <= UInt8(ord("Z")):
            out.append(b + UInt8(0x20))
        else:
            out.append(b)
    return out^


def _span_equals_str(s: Span[UInt8, _], ref needle: String) -> Bool:
    """Byte-compare `s` against `needle` (ASCII)."""
    var nb = needle.as_bytes()
    if len(s) != len(nb):
        return False
    for i in range(len(s)):
        if s[i] != nb[i]:
            return False
    return True


def _span_to_string(s: Span[UInt8, _]) -> String:
    """Construct a String from a Span[UInt8] view (byte-copy)."""
    var buf = List[UInt8](capacity=len(s))
    for i in range(len(s)):
        buf.append(s[i])
    return String(unsafe_from_utf8=Span(buf))


def _parse_uint8_decimal(s: Span[UInt8, _]) -> UInt8:
    """Parse a small decimal integer from an ASCII span; saturates at 255."""
    var v = UInt8(0)
    for i in range(len(s)):
        var b = s[i]
        if b >= UInt8(ord("0")) and b <= UInt8(ord("9")):
            v = v * 10 + (b - UInt8(ord("0")))
    return v
