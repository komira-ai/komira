# =============================================================================
# komira_gcp_core/rest_stream.mojo — a server-streaming method over REST.
# =============================================================================
#
# A Google API method that streams its responses over gRPC
# (`returns (stream M)`) answers over REST/JSON with ONE HTTP response whose
# body is a JSON array of `M` objects, in stream order:
#
#     [{...M...}, {...M...}, ...]
#
# A failure the server meets before it starts answering is an ordinary
# non-2xx with the `google.rpc.Status` envelope. One it meets after it has
# sent a 200 cannot change the status line any more, so it ends the array
# with an element that is that envelope instead of an `M`:
#
#     [{...M...}, {"error": {"code": 409, "status": "ABORTED", ...}}]
#
# `gcp_rest_stream_items` is the contract the generated REST clients call for
# such a method (proto-codegen `emit_rest.rs`, `GCP_REST_STREAM_ITEMS`): it
# returns each element's JSON text for the client to decode as an `M`, and
# raises an error element through `gcp_status_error`, so a mid-stream failure
# reads exactly like a failed status line (the HTTP status in it is the 200
# that was sent; the code is the envelope's). As there, no body byte is
# echoed: a body that is not a JSON array is refused by its byte count.
# =============================================================================

from komira_json import JsonValue, parse_json_bytes

from .status import gcp_status_error


comptime STREAM_MAX_PARSE_DEPTH: Int = 256
"""The nesting limit a streamed body is parsed under. Deeper than
`MAX_PARSE_DEPTH` (an error envelope's): a streamed element is a resource,
and a Firestore document nests its map values up to 20 levels, each taking
three JSON levels (`mapValue`, `fields`, the value)."""


def _is_ws(c: UInt8) -> Bool:
    return c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D


def _skip_ws(b: List[UInt8], pos: Int) -> Int:
    var i = pos
    while i < len(b) and _is_ws(b[i]):
        i += 1
    return i


def _value_end(b: List[UInt8], start: Int) -> Int:
    """The byte just past the JSON value starting at `start`, in a document
    already known to be well-formed: a string is skipped with its escapes,
    a container by its depth, and a scalar runs to the next `,`, `]`, `}`
    or whitespace."""
    var i = start
    var depth = 0
    var in_string = False
    while i < len(b):
        var c = b[i]
        if in_string:
            if c == 0x5C:  # backslash: the next byte is escaped
                i += 2
                continue
            if c == 0x22:
                in_string = False
                if depth == 0:
                    return i + 1
            i += 1
            continue
        if c == 0x22:
            in_string = True
        elif c == 0x7B or c == 0x5B:  # { [
            depth += 1
        elif c == 0x7D or c == 0x5D:  # } ]
            if depth == 0:
                return i
            depth -= 1
            if depth == 0:
                return i + 1
        elif depth == 0 and (c == 0x2C or _is_ws(c)):
            return i
        i += 1
    return i


def _slice(b: List[UInt8], start: Int, end: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=end - start)
    for i in range(start, end):
        out.append(b[i])
    return out^


def _not_an_array(verb: String, rpc: String, http_status: Int, n: Int) -> Error:
    return Error(
        verb
        + " "
        + rpc
        + ": HTTP "
        + String(http_status)
        + ", the streamed body is not a JSON array, body "
        + String(n)
        + " bytes"
    )


def gcp_rest_stream_items(
    verb: String, rpc: String, http_status: Int, body: List[UInt8]
) raises -> List[String]:
    """The elements of a REST server-stream body, each as its JSON text, in
    order. Raises an element that is a `google.rpc.Status` envelope through
    `gcp_status_error(verb, rpc, http_status, <that element>)`, and refuses
    a body that is not a JSON array (an empty body included), naming only
    its byte count."""
    var out = List[String]()
    var pos = _skip_ws(body, 0)
    if pos >= len(body) or body[pos] != 0x5B:
        raise _not_an_array(verb, rpc, http_status, len(body))
    # A body that does not parse is refused by its byte count alone: the
    # parser's own message can quote the body.
    var parsed = True
    var doc = JsonValue()
    try:
        doc = parse_json_bytes(body, STREAM_MAX_PARSE_DEPTH)
    except:
        parsed = False
    if not parsed or not doc.is_array():
        raise _not_an_array(verb, rpc, http_status, len(body))
    pos = _skip_ws(body, pos + 1)
    if pos < len(body) and body[pos] == 0x5D:
        return out^
    var index = 0
    while pos < len(body):
        var end = _value_end(body, pos)
        var item = _slice(body, pos, end)
        var element = doc.element_at(index)
        if element.is_object() and element.has(String("error")):
            raise gcp_status_error(verb, rpc, http_status, item)
        out.append(String(unsafe_from_utf8=Span(item)))
        index += 1
        pos = _skip_ws(body, end)
        if pos < len(body) and body[pos] == 0x2C:
            pos = _skip_ws(body, pos + 1)
            continue
        break
    return out^
