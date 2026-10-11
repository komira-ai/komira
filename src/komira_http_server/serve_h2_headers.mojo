# =============================================================================
# src/komira_http_server/serve_h2_headers.mojo: request header checks for the
# h2 serve loop
# =============================================================================
#
# The checks `serve_h2._handle_headers_or_continuation` runs on a decoded
# request header block (RFC 9113 §8.2, §8.3): lowercase field names,
# connection-specific fields, the pseudo-header set, and an overflow-safe
# parse of content-length. Pure functions over decoded headers; no I/O.
#
# No pointer in any signature. No wildcard origin.
# =============================================================================

from komira_http_core.codec.h2.hpack import HpackHeader


def _is_lowercase_or_pseudo(name: String) -> Bool:
    """RFC 9113 §8.1.2 — header field names MUST be lowercase (except
    pseudo-headers which start with ':'). Returns True if `name` is
    a valid h2 header name (all lowercase ASCII OR starts with ':')."""
    var bs = name.as_bytes()
    var n = len(bs)
    if n == 0:
        return False
    if bs[0] == UInt8(0x3A):  # ':'
        # Pseudo-header — rest must be ASCII lowercase / digit / hyphen.
        return True
    var i = 0
    while i < n:
        var b = bs[i]
        if b >= UInt8(0x41) and b <= UInt8(0x5A):  # 'A'..'Z'
            return False
        i = i + 1
    return True


def _is_connection_specific_header(name: String) -> Bool:
    """RFC 9113 §8.1.2.2 — these h1 connection-specific headers MUST
    NOT appear in h2 requests/responses."""
    var lower = name
    if lower == String("connection"):
        return True
    if lower == String("proxy-connection"):
        return True
    if lower == String("keep-alive"):
        return True
    if lower == String("transfer-encoding"):
        return True
    if lower == String("upgrade"):
        return True
    return False


struct _ValidationResult(
    Copyable, Movable, ImplicitlyCopyable, Deinitable,
):
    """Result of RFC 9113 §8.1.2 h2 request-header validation."""
    var ok: Bool
    var method_str: String
    var path_str: String
    var has_content_length: Bool
    var content_length: Int
    # captured `content-type` header value (empty if absent).
    # Used to decide whether the request routes to the GrpcDispatch seam.
    var content_type: String

    def __init__(out self):
        self.ok = False
        self.method_str = String("")
        self.path_str = String("")
        self.has_content_length = False
        self.content_length = 0
        self.content_type = String("")


comptime _H2_MAX_PARSED_INT: Int = 1 << 62
"""Overflow ceiling for `_parse_int_safe`, matching the h1 twin
`codec/h1/parser.mojo:_parse_decimal`. An h2 `content-length` is untrusted
peer bytes of unbounded digit count; without a ceiling a long digit run wraps
Int64 silently into `StreamState.expected_content_length` and then decides
the RFC 7540 §8.1.2.6 length-equality check — i.e. a smuggling primitive,
reachable whether or not stdlib bounds checks are compiled in.

⚠ THE CEILING ALONE IS NOT THE FIX, and the earlier wording here ("without
this a 25-digit value wraps") read as though it were. `1 << 62` is above
`Int64.MAX / 10`, so a value admitted AT the ceiling still wraps on the next
multiply — the ceiling only works when it is tested BEFORE the accumulate,
which is what `_H2_MAX_PARSED_INT_DIV10` is for. (This is also why the same
post-multiply pattern is harmless at `regexp_nfa.mojo:510` and
`git_lfs.mojo:387`: their ceilings are small enough that `ceiling * 10`
cannot overflow. The ceiling's MAGNITUDE is the discriminator.)"""


comptime _H2_MAX_PARSED_INT_DIV10: Int = _H2_MAX_PARSED_INT // 10
"""Pre-multiply admission bound — see `_parse_int_safe`."""


def _parse_int_safe(s: String) -> Tuple[Bool, Int]:
    """Parse a non-negative integer from `s`. Returns (ok, value).

    Rejects (rather than wraps) anything above `_H2_MAX_PARSED_INT`. The
    guard is per-digit because that is the only place the magnitude is
    known, and the input is a header value (tens of bytes), not a hot loop.

    ⚠ THE GUARD IS BEFORE THE MULTIPLY. A guard AFTER the accumulate —
    `v = v * 10 + d` then `if v > CEIL` — does not work: with `v` admitted at
    `1 << 62`, the next `v * 10` is ~2^65 and wraps Int64; two's-complement
    wrap can land on a small POSITIVE value that passes the test. A falsifier
    like `"9999999999999999999999999"` (25 nines) happens to land in the
    rejected band and goes green over the defect, while at ASSERT=none
    `_parse_int_safe("18446744073709551621")` would return `(True, 5)`.
    `StreamState.expected_content_length` would then carry 5 while the peer
    sent 2^64 + 5: the RFC 7540 §8.1.2.6 length-equality check becomes a
    smuggling primitive.
    """
    var bs = s.as_bytes()
    var n = len(bs)
    if n == 0:
        return (False, 0)
    var v = 0
    var i = 0
    while i < n:
        var b = bs[i]
        if b < UInt8(0x30) or b > UInt8(0x39):
            return (False, 0)
        if v > _H2_MAX_PARSED_INT_DIV10:
            return (False, 0)
        v = v * 10 + Int(b) - Int(UInt8(0x30))
        if v > _H2_MAX_PARSED_INT:
            return (False, 0)
        i = i + 1
    return (True, v)


def _validate_h2_request_headers(
    headers: List[HpackHeader],
) -> _ValidationResult:
    """RFC 9113 §8.1.2 validation. Returns ValidationResult.ok=False on
    any violation; on success ok=True with extracted method + path.

    Checks:
      - All names lowercase (no uppercase letters except for pseudo-headers).
      - No connection-specific h1 headers (connection / transfer-encoding etc.).
      - TE header only if value == "trailers" (RFC 7540 §8.1.2.2).
      - Pseudo-headers all come BEFORE regular headers (no pseudo after regular).
      - No unknown pseudo-headers (only :method/:scheme/:authority/:path).
      - No duplicate pseudo-headers.
      - :method, :scheme, :path are present.
      - :path is non-empty (RFC 7540 §8.1.2.3).
    """
    var result = _ValidationResult()
    var has_method = False
    var has_scheme = False
    var has_path = False
    var has_authority = False
    var seen_regular = False
    var n = len(headers)
    var i = 0
    while i < n:
        var name = String(headers[i].name)
        var value = String(headers[i].value)
        if len(name.as_bytes()) > 0 and name.as_bytes()[0] == UInt8(0x3A):
            # Pseudo-header.
            if seen_regular:
                return result
            if name == String(":method"):
                if has_method:
                    return result
                has_method = True
                result.method_str = value
            elif name == String(":scheme"):
                if has_scheme:
                    return result
                has_scheme = True
            elif name == String(":path"):
                if has_path:
                    return result
                if len(value.as_bytes()) == 0:
                    return result
                has_path = True
                result.path_str = value
            elif name == String(":authority"):
                if has_authority:
                    return result
                has_authority = True
            else:
                # Unknown pseudo (incl. response :status in request).
                return result
        else:
            seen_regular = True
            if not _is_lowercase_or_pseudo(name):
                return result
            if _is_connection_specific_header(name):
                return result
            if name == String("te"):
                if value != String("trailers"):
                    return result
            if name == String("content-length"):
                var parsed = _parse_int_safe(value)
                if not parsed[0]:
                    # Invalid content-length value → PROTOCOL_ERROR
                    # per RFC 7540 §8.1.2.6.
                    return result
                result.has_content_length = True
                result.content_length = parsed[1]
            if name == String("content-type"):
                # capture for gRPC routing at dispatch time.
                result.content_type = value
        i = i + 1
    if not has_method or not has_scheme or not has_path:
        return result
    result.ok = True
    return result^
