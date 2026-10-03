# =============================================================================
# codec_connect_json.mojo — `connect+json` codec
# =============================================================================
#
# Per https://connectrpc.com/docs/protocol/#unary-request +
# /#unary-response + /#streaming-rpcs. The `connect+json` codec is:
#   - Content-Type: `application/json` (unary) or
#                   `application/connect+json` (streaming)
#   - Transport:    HTTP/1.1 OR HTTP/2 (Connect designed for both)
#   - Unary body:   raw JSON (NO envelope framing) — request and response
#                   bodies are the JSON-encoded message directly.
#   - Stream body:  envelope-framed JSON messages — same 5-byte envelope
#                   as gRPC, but the payload is JSON instead of protobuf.
#                   End-of-stream is signaled via END_STREAM envelope
#                   carrying a Connect EndStreamResponse JSON object.
#   - Error wire:   for unary failures — JSON body of shape
#                   {"code": "<name>", "message": "<text>"} with the
#                   HTTP status set to the mapped status (per
#                   grpc_status_to_http_status). For streaming — a
#                   final END_STREAM envelope carrying the same JSON
#                   envelope shape.
#
# This codec does NOT touch the protobuf encoder — JSON encoding lives in
# komira_proto_codec's Proto3JsonWire backend. The codec is purely about wire
# framing + the Connect-JSON error envelope shape.
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
)
from .status import (
    GRPC_STATUS_OK,
    GRPC_STATUS_UNKNOWN,
    grpc_status_to_connect_name,
    connect_name_to_grpc_status,
)


# =============================================================================
# §1 — Content-Type constants
# =============================================================================

comptime CONNECT_JSON_CONTENT_TYPE_UNARY: String = "application/json"
"""Connect unary uses plain `application/json` (per Connect spec)."""

comptime CONNECT_JSON_CONTENT_TYPE_STREAM: String = "application/connect+json"
"""Connect streaming uses `application/connect+json`."""

comptime CONNECT_PROTO_CONTENT_TYPE_UNARY: String = "application/proto"
"""Connect-proto UNARY uses plain `application/proto` (per Connect spec).

The unary Connect-proto wire is byte-identical in framing to Connect-JSON:
bare body (NO 5-byte envelope) on success; on a non-2xx HTTP status the
body is a `{"code":"<name>","message":"<text>"}` Connect error envelope
(the error envelope is JSON for BOTH the json and proto Connect codecs,
per https://connectrpc.com/docs/protocol/#unary-response). Only the
SUCCESS payload bytes differ (protobuf-binary vs proto3-JSON) — and those
bytes are opaque to the dispatcher, which copies the message body through
unchanged. The dispatcher therefore routes `application/proto` onto the
same codec path as `application/json` (CODEC_ID_CONNECT_JSON): identical
bare-body framing + identical JSON error-envelope shape."""

comptime CONNECT_PROTO_CONTENT_TYPE_STREAM: String = "application/connect+proto"
"""Connect-proto STREAMING uses `application/connect+proto` (5-byte
envelope-framed, payload is protobuf-binary). The dispatcher handles the
UNARY path; streaming routes the same way (envelope handling is the
caller's; the dispatcher's unary copy-through is a superset for the
data-message body)."""


# =============================================================================
# §2 — Unary encode / decode — no envelope framing, raw JSON body.
# =============================================================================


def connect_json_encode_unary(json_bytes: Span[UInt8, _]) -> List[UInt8]:
    """Encode a unary Connect-JSON body: copy the raw JSON message bytes.

    Unary Connect-JSON has NO envelope framing — the body IS the JSON
    object. This function is a convenience copy operation (consumers can
    pass json_bytes directly to the HTTP body sink).
    """
    var out = List[UInt8](capacity=len(json_bytes))
    for i in range(len(json_bytes)):
        out.append(json_bytes[i])
    return out^


def connect_json_decode_unary[
    origin: Origin[mut=False]
](body: Span[UInt8, origin]) -> Span[UInt8, origin]:
    """Decode a unary Connect-JSON body: the body IS the JSON message.

    Returns a Span view into the body. The caller passes this Span to a
    JsonDecoder to materialize the typed message.
    """
    return body


# =============================================================================
# §3 — Streaming encode / decode — envelope-framed JSON messages.
# =============================================================================


def connect_json_append_message(mut out: List[UInt8], json_bytes: Span[UInt8, _]):
    """Append one envelope-framed JSON message to a streaming body buffer."""
    write_envelope(out, 0x00, json_bytes)


def connect_json_append_end_stream(
    mut out: List[UInt8], end_stream_envelope_json: Span[UInt8, _]
):
    """Append the closing END_STREAM envelope carrying the Connect end-of-stream
    JSON object.

    Per Connect spec, the END_STREAM envelope payload is a JSON object:
      {"error": {"code": "<name>", "message": "<text>"}} on failure,
      {} on success.
    """
    write_envelope(out, ENVELOPE_FLAG_END_STREAM, end_stream_envelope_json)


@fieldwise_init
struct ConnectStreamDecodedBody[origin: Origin[mut=False]](
    Movable, Deinitable
):
    """A fully-decoded Connect-JSON streaming body.

    `messages` is the list of data-envelope payloads (each is a JSON
    message). `end_stream_payload` is the END_STREAM envelope payload
    (the Connect end-of-stream JSON object) when seen.
    """

    var messages: List[Span[UInt8, Self.origin]]
    var end_stream_payload: Span[UInt8, Self.origin]
    var saw_end_stream: Bool


def connect_json_decode_stream[
    origin: Origin[mut=False]
](body: Span[UInt8, origin]) raises -> ConnectStreamDecodedBody[origin]:
    """Split a Connect-JSON streaming body into data messages + the
    END_STREAM payload.

    Walks envelopes in order. Data envelopes (END_STREAM bit clear) accumulate
    as messages; the single END_STREAM envelope's payload becomes
    end_stream_payload.

    Raises on:
      - compressed envelopes (compression is not supported)
      - duplicate END_STREAM envelopes
    """
    var messages = List[Span[UInt8, origin]]()
    # Start with an empty sentinel slice for end_stream_payload.
    var empty_end = body[0:0]
    var saw_end = False
    var cursor = 0
    while cursor < len(body):
        var step = split_first_envelope(body, cursor)
        var env = step[0]
        var next_offset = step[1]
        if env.is_compressed():
            raise Error("komira_connect.connect_json: compressed envelopes not supported")
        if env.is_end_stream():
            if saw_end:
                raise Error("komira_connect.connect_json: duplicate END_STREAM envelope")
            empty_end = env.payload
            saw_end = True
        else:
            messages.append(env.payload)
        cursor = next_offset
    return ConnectStreamDecodedBody[origin](messages^, empty_end, saw_end)


# =============================================================================
# §4 — Error envelope encoding/decoding — `{"code": "name", "message": "text"}`.
# =============================================================================


def build_connect_error_json(code: UInt8, message: String) -> List[UInt8]:
    """Build the Connect-JSON error envelope body bytes.

    Shape: `{"code":"<name>","message":"<text>"}` — minimal JSON with no
    whitespace, double-quoted keys + string values. Backslash + double-quote
    in `message` are escaped per JSON rules.

    For OK (code=0): returns an empty object `{}` (Connect spec).
    """
    var out = List[UInt8]()
    if code == GRPC_STATUS_OK:
        out.append(UInt8(ord("{")))
        out.append(UInt8(ord("}")))
        return out^
    # `{"code":"<name>","message":"<json-escaped-text>"}`
    var name = grpc_status_to_connect_name(code)
    _append_str(out, String("{\"code\":\""))
    _append_str(out, name)
    _append_str(out, String("\",\"message\":\""))
    _append_json_escaped(out, message)
    _append_str(out, String("\"}"))
    return out^


def build_connect_end_stream_json(code: UInt8, message: String) -> List[UInt8]:
    """Build the END_STREAM envelope payload for a Connect streaming response.

    Shape:
      - on success: `{}` (Connect spec)
      - on error:   `{"error":{"code":"<name>","message":"<text>"}}`
    """
    if code == GRPC_STATUS_OK:
        var out = List[UInt8]()
        out.append(UInt8(ord("{")))
        out.append(UInt8(ord("}")))
        return out^
    var out = List[UInt8]()
    var name = grpc_status_to_connect_name(code)
    _append_str(out, String("{\"error\":{\"code\":\""))
    _append_str(out, name)
    _append_str(out, String("\",\"message\":\""))
    _append_json_escaped(out, message)
    _append_str(out, String("\"}}"))
    return out^


@fieldwise_init
struct ConnectErrorEnvelope(Copyable, Movable, Deinitable):
    """Decoded Connect-JSON error envelope."""

    var code: UInt8
    """GRPC numeric code recovered from the Connect error-name string."""

    var message: String
    """Human-readable error text (JSON-unescaped)."""


def parse_connect_error_json(body: Span[UInt8, _]) raises -> ConnectErrorEnvelope:
    """Parse a `{"code":"name","message":"text"}` Connect error envelope.

    Returns ConnectErrorEnvelope with code mapped via connect_name_to_grpc_status.
    Raises on malformed JSON (basic shape check; this is NOT a full JSON parser,
    just a tolerant scan for the two known keys).
    """
    var text = _bytes_to_string(body)
    var code_name = _extract_json_string_field(text, String("code"))
    var message = _extract_json_string_field(text, String("message"))
    var code = connect_name_to_grpc_status(code_name)
    return ConnectErrorEnvelope(code, message^)


# =============================================================================
# §5 — Helpers — minimal JSON escape + tolerant scan for two keys.
# =============================================================================


def _append_str(mut out: List[UInt8], s: String):
    """Append the bytes of `s` to `out`."""
    for i in range(s.byte_length()):
        out.append(UInt8(ord(s[byte=i])))


def _append_json_escaped(mut out: List[UInt8], s: String):
    """Append `s` to `out` with JSON string-escapes applied.

    Escapes:  `\\` -> `\\\\`, `"` -> `\\"`, control chars (0x00..0x1F) -> `\\uXXXX`.
    """
    for i in range(s.byte_length()):
        var b = ord(s[byte=i])
        if b == ord("\\"):
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("\\")))
        elif b == ord("\""):
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("\"")))
        elif b == 0x08:
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("b")))
        elif b == 0x09:
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("t")))
        elif b == 0x0A:
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("n")))
        elif b == 0x0C:
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("f")))
        elif b == 0x0D:
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("r")))
        elif b < 0x20:
            # \uXXXX
            out.append(UInt8(ord("\\")))
            out.append(UInt8(ord("u")))
            out.append(UInt8(ord("0")))
            out.append(UInt8(ord("0")))
            out.append(_hex_char(b >> 4))
            out.append(_hex_char(b & 0x0F))
        else:
            out.append(UInt8(b))


@always_inline
def _hex_char(nibble: Int) -> UInt8:
    if nibble < 10:
        return UInt8(ord("0") + nibble)
    return UInt8(ord("a") + nibble - 10)


def _bytes_to_string(b: Span[UInt8, _]) -> String:
    """Convert a Span[UInt8] to String via unsafe_from_utf8."""
    var buf = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        buf.append(b[i])
    return String(unsafe_from_utf8=Span(buf))


def _extract_json_string_field(text: String, key: String) raises -> String:
    """Tolerant scan for `"<key>":"<value>"` and return `<value>` (JSON-unescaped).

    Returns empty String if the key is not present. Raises on truncated /
    malformed quote shape. NOT a full JSON parser — handles the two-key
    Connect error envelope shape only.
    """
    # Search for the literal `"<key>"` in text
    var needle_bytes = List[UInt8]()
    needle_bytes.append(UInt8(ord("\"")))
    for i in range(key.byte_length()):
        needle_bytes.append(UInt8(ord(key[byte=i])))
    needle_bytes.append(UInt8(ord("\"")))
    var idx = _find_byte_sequence(text, Span(needle_bytes))
    if idx < 0:
        return String("")
    # Skip past `"<key>"`
    var cursor = idx + len(needle_bytes)
    # Skip optional whitespace + ':' + optional whitespace
    cursor = _skip_ws(text, cursor)
    if cursor >= text.byte_length() or ord(text[byte=cursor]) != ord(":"):
        raise Error("komira_connect.connect_json: expected ':' after key")
    cursor += 1
    cursor = _skip_ws(text, cursor)
    # Expect opening quote
    if cursor >= text.byte_length() or ord(text[byte=cursor]) != ord("\""):
        raise Error("komira_connect.connect_json: expected '\"' opening string value")
    cursor += 1
    # Scan for closing quote, JSON-unescaping
    var out_bytes = List[UInt8]()
    while cursor < text.byte_length():
        var b = ord(text[byte=cursor])
        if b == ord("\""):
            return String(unsafe_from_utf8=Span(out_bytes))
        elif b == ord("\\"):
            if cursor + 1 >= text.byte_length():
                raise Error("komira_connect.connect_json: dangling escape at end of string")
            var nxt = ord(text[byte=cursor + 1])
            if nxt == ord("\""):
                out_bytes.append(UInt8(ord("\"")))
                cursor += 2
            elif nxt == ord("\\"):
                out_bytes.append(UInt8(ord("\\")))
                cursor += 2
            elif nxt == ord("/"):
                out_bytes.append(UInt8(ord("/")))
                cursor += 2
            elif nxt == ord("n"):
                out_bytes.append(UInt8(0x0A))
                cursor += 2
            elif nxt == ord("t"):
                out_bytes.append(UInt8(0x09))
                cursor += 2
            elif nxt == ord("r"):
                out_bytes.append(UInt8(0x0D))
                cursor += 2
            elif nxt == ord("b"):
                out_bytes.append(UInt8(0x08))
                cursor += 2
            elif nxt == ord("f"):
                out_bytes.append(UInt8(0x0C))
                cursor += 2
            elif nxt == ord("u"):
                # \uXXXX — basic ASCII-range support
                if cursor + 5 >= text.byte_length():
                    raise Error("komira_connect.connect_json: truncated \\u escape")
                var h1 = _hex_to_int_v(ord(text[byte=cursor + 2]))
                var h2 = _hex_to_int_v(ord(text[byte=cursor + 3]))
                var h3 = _hex_to_int_v(ord(text[byte=cursor + 4]))
                var h4 = _hex_to_int_v(ord(text[byte=cursor + 5]))
                if h1 < 0 or h2 < 0 or h3 < 0 or h4 < 0:
                    raise Error("komira_connect.connect_json: malformed \\u escape")
                var codepoint = (h1 << 12) | (h2 << 8) | (h3 << 4) | h4
                if codepoint <= 0x7F:
                    out_bytes.append(UInt8(codepoint))
                else:
                    # Multi-byte UTF-8 encode (basic 0x80..0x7FF and 0x800..0xFFFF)
                    if codepoint <= 0x7FF:
                        out_bytes.append(UInt8(0xC0 | (codepoint >> 6)))
                        out_bytes.append(UInt8(0x80 | (codepoint & 0x3F)))
                    else:
                        out_bytes.append(UInt8(0xE0 | (codepoint >> 12)))
                        out_bytes.append(UInt8(0x80 | ((codepoint >> 6) & 0x3F)))
                        out_bytes.append(UInt8(0x80 | (codepoint & 0x3F)))
                cursor += 6
            else:
                raise Error("komira_connect.connect_json: unrecognized escape sequence")
        else:
            out_bytes.append(UInt8(b))
            cursor += 1
    raise Error("komira_connect.connect_json: unterminated string value")


def _find_byte_sequence(text: String, needle: Span[UInt8, _]) -> Int:
    """Find the first occurrence of `needle` in `text`. Returns -1 if not found."""
    var n = text.byte_length()
    var m = len(needle)
    if m == 0:
        return 0
    if m > n:
        return -1
    for i in range(n - m + 1):
        var is_match = True
        for j in range(m):
            if UInt8(ord(text[byte=i + j])) != needle[j]:
                is_match = False
                break
        if is_match:
            return i
    return -1


def _skip_ws(text: String, start: Int) -> Int:
    """Skip JSON whitespace (space / tab / newline / CR) starting at `start`."""
    var cursor = start
    while cursor < text.byte_length():
        var b = ord(text[byte=cursor])
        if b == ord(" ") or b == 0x09 or b == 0x0A or b == 0x0D:
            cursor += 1
        else:
            break
    return cursor


@always_inline
def _hex_to_int_v(byte: Int) -> Int:
    if byte >= ord("0") and byte <= ord("9"):
        return byte - ord("0")
    if byte >= ord("A") and byte <= ord("F"):
        return byte - ord("A") + 10
    if byte >= ord("a") and byte <= ord("f"):
        return byte - ord("a") + 10
    return -1
