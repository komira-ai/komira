# =============================================================================
# http_util -- the small HTTP and text helpers the capture routes share.
# =============================================================================
#
# What a route needs and nothing else: a JSON response and a JSON error, a
# query-string value (percent-decoded, and refused if it is not valid UTF-8),
# the bearer-token check, and the label check for the names a caller supplies
# (a surface tag, a partition id). The first three are exported for hosts that
# write their own `CaptureRoutes`.
#
# Every string that reaches a response is built through `komira_json`, so a
# multi-byte character passes through unchanged and every control byte is
# escaped.
# =============================================================================

from komira_http_core.codec import HttpResponse
from komira_json import JsonValue, write_json_string
from komira_kg_format.utf8_check import bytes_are_utf8

comptime LABEL_MAX_BYTES: Int = 256
"""The longest surface tag or partition id the server accepts."""


def json_response(status: Int32, body: JsonValue) -> HttpResponse:
    """A response with `body` serialized as JSON.

    Args:
        status: The HTTP status.
        body: The JSON value to send.

    Returns:
        The response, with `content-type` and `content-length` set.
    """
    var text = body.serialize()
    var out = HttpResponse(status=status)
    out.body.extend(text.as_bytes())
    out.headers[String("content-type")] = String("application/json")
    out.headers[String("content-length")] = String(len(out.body))
    return out^


def error_response(status: Int32, message: String) -> HttpResponse:
    """A response whose body is `{"error": message}`.

    Args:
        status: The HTTP status.
        message: What went wrong. The caller keeps internal detail (paths, the
            text of a lower-level error) out of it.

    Returns:
        The response.
    """
    var body = List[UInt8]()
    body.extend("{\"error\":".as_bytes())
    write_json_string(body, message)
    body.append(0x7D)  # '}'
    var out = HttpResponse(status=status)
    out.body = body^
    out.headers[String("content-type")] = String("application/json")
    out.headers[String("content-length")] = String(len(out.body))
    return out^


def _hex_value(c: UInt8) -> Int:
    if c >= 0x30 and c <= 0x39:
        return Int(c) - 0x30
    if c >= 0x41 and c <= 0x46:
        return Int(c) - 0x41 + 10
    if c >= 0x61 and c <= 0x66:
        return Int(c) - 0x61 + 10
    return -1


def _percent_decode[o: Origin[mut=False]](raw: Span[UInt8, o]) raises -> String:
    var out = List[UInt8](capacity=len(raw))
    var i = 0
    while i < len(raw):
        if raw[i] == 0x25:  # '%'
            if len(raw) - i < 3:
                raise Error("a percent escape is cut short")
            var hi = _hex_value(raw[i + 1])
            var lo = _hex_value(raw[i + 2])
            if hi < 0 or lo < 0:
                raise Error("a percent escape is not two hex digits")
            out.append(UInt8(hi * 16 + lo))
            i += 3
        else:
            out.append(raw[i])
            i += 1
    if not bytes_are_utf8(Span(out)):
        raise Error("the value is not valid UTF-8")
    # SAFETY: `out` was checked as well-formed UTF-8 on the line above.
    return String(unsafe_from_utf8=Span(out))


def query_value(query_string: String, key: String) raises -> String:
    """The value of the first `key=value` pair of a query string, percent
    decoded; "" if the key is absent or has no value.

    Args:
        query_string: The query part of the request target, without the '?'.
        key: The parameter name, compared as it is written.

    Returns:
        The decoded value.

    Raises:
        If the value holds a broken percent escape or is not valid UTF-8.
    """
    var q = query_string.as_bytes()
    var want = key.as_bytes()
    var start = 0
    while start <= len(q):
        var end = start
        while end < len(q) and q[end] != 0x26:  # '&'
            end += 1
        var eq = start
        while eq < end and q[eq] != 0x3D:  # '='
            eq += 1
        if eq - start == len(want):
            var same = True
            for j in range(len(want)):
                if q[start + j] != want[j]:
                    same = False
                    break
            if same:
                if eq == end:
                    return String("")
                return _percent_decode(q[eq + 1 : end])
        start = end + 1
    return String("")


def check_label(what: String, value: String) raises:
    """Refuse a name that is empty, over `LABEL_MAX_BYTES` or holds a control
    byte.

    Args:
        what: The name's role, for the error text.
        value: The name.

    Raises:
        If the name breaks a rule.
    """
    var b = value.as_bytes()
    if len(b) == 0:
        raise Error(what + " must not be empty")
    if len(b) > LABEL_MAX_BYTES:
        raise Error(what + " is over " + String(LABEL_MAX_BYTES) + " bytes")
    for i in range(len(b)):
        if b[i] < 0x20 or b[i] == 0x7F:
            raise Error(what + " must not hold a control byte")


def check_token(token: String) raises:
    """Refuse a bearer token the server could not be asked for: empty, over
    4096 bytes, or holding anything but visible ASCII (0x21 to 0x7E).

    Raises:
        If the token breaks a rule.
    """
    var b = token.as_bytes()
    if len(b) == 0:
        raise Error("the token must not be empty")
    if len(b) > 4096:
        raise Error("the token is over 4096 bytes")
    for i in range(len(b)):
        if b[i] < 0x21 or b[i] > 0x7E:
            raise Error("the token must be visible ASCII with no space")


def bearer_matches(authorization: String, token: String) -> Bool:
    """Whether an `Authorization` header value is `Bearer <token>`.

    The scheme is compared without regard to case, followed by one space and the
    token exactly. The token comparison reads every byte of the expected token
    whatever the presented one holds, so its time does not say how long a prefix
    matched.

    Args:
        authorization: The header value.
        token: The expected token.

    Returns:
        True only for an exact match.
    """
    var h = authorization.as_bytes()
    var scheme = "bearer ".as_bytes()
    if len(h) < len(scheme):
        return False
    for i in range(len(scheme)):
        var c = h[i]
        if c >= 0x41 and c <= 0x5A:
            c += 32
        if c != scheme[i]:
            return False
    var presented = h[len(scheme) :]
    var expected = token.as_bytes()
    var diff = len(presented) ^ len(expected)
    for i in range(len(expected)):
        var p = UInt8(0)
        if i < len(presented):
            p = presented[i]
        diff |= Int(p ^ expected[i])
    return diff == 0
