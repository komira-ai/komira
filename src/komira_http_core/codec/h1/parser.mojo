# =============================================================================
# src/komira_http_core/codec/h1/parser.mojo — RFC 7230 HTTP/1.1 parser
# =============================================================================
#
#
#
# Pure-function HTTP/1.1 request parser. Splits in two halves:
#   * parse_request_head — request-line + headers; returns
#     `HeadersParseOutcome` describing the parsed HttpRequest, body
#     framing (Content-Length / chunked / none), expectations, and
#     whether the connection should stay open.
#   * Body decoding lives in `chunked.mojo` (chunked TE) and is a
#     simple Content-Length slice for the non-chunked case (caller
#     concern; see `serve_read_round` integration).
#
# No UnsafePointer in any public sig. No wildcard origin. No
# `unsafe_from_address`. Pure value semantics.
#
# =============================================================================

from std.collections.dict import Dict

from komira_http_core.codec.types import (
    HTTP_METHOD_UNKNOWN,
    HttpMethod,
    HttpRequest,
)
from komira_http_core.codec.h1.limits import (
    PARSE_ERR_BODY_TOO_LARGE,
    PARSE_ERR_HEADER_COUNT_OVERFLOW,
    PARSE_ERR_HEADER_NAME_INVALID,
    PARSE_ERR_HEADER_NO_COLON,
    PARSE_ERR_HEADER_OBS_FOLD,
    PARSE_ERR_HEADER_SIZE_OVERFLOW,
    PARSE_ERR_HEADER_TOTAL_OVERFLOW,
    PARSE_ERR_HEADER_VALUE_CONTROL_CHAR,
    PARSE_ERR_HTTP_09_REJECTED,
    PARSE_ERR_HTTP_VERSION_BAD,
    PARSE_ERR_HTTP_VERSION_UNSUPPORTED,
    PARSE_ERR_METHOD_LOWERCASE,
    PARSE_ERR_METHOD_UNKNOWN,
    PARSE_ERR_REQUEST_LINE_MALFORMED,
    PARSE_ERR_URI_TOO_LONG,
    PARSE_ERR_URI_WHITESPACE,
    PARSE_ERR_CONTENT_LENGTH_AND_CHUNKED,
    PARSE_ERR_CONTENT_LENGTH_CONFLICT,
    PARSE_ERR_CONTENT_LENGTH_INVALID,
    PARSE_ERR_EXPECT_UNSUPPORTED,
    PARSE_ERR_TRANSFER_ENCODING_UNSUPPORTED,
    ParseError,
    ParseLimits,
)
from komira_http_core.codec.h1.status_text import (
    _write_reason_phrase,
    _write_static_error_body,
)
from komira_http_core.codec.h1.utf8 import utf8_error_offset


# =============================================================================
# §1 — Headers parse outcome.
# =============================================================================


struct HeadersParseOutcome(Movable, Deinitable):
    """Result of `parse_request_head`.

    On success (`err.is_ok()`):
      * `request` is populated with method / path / query_string / headers
        (lowercase canonicalized names). `request.body` is empty — body
        decoding is a separate step.
      * `headers_end_off` is the offset of the byte after the terminating
        CRLFCRLF. The body (or further pipelined requests) begin at
        `buf[headers_end_off:]`.
      * `content_length` = -1 if absent; >=0 if a single well-formed CL
        header was found.
      * `is_chunked` = True iff Transfer-Encoding contains `chunked` (and
        no Content-Length present — conflict is rejected before here).
      * `expects_continue` = True iff Expect: 100-continue was present on
        an HTTP/1.1 request (RFC 9110 §10.1.1: a server MUST ignore it in
        an HTTP/1.0 request).
      * `connection_close` = True iff Connection: close was present (or
        HTTP/1.0 default without Connection: keep-alive).
      * `http_version_minor` = 0 for HTTP/1.0, 1 for HTTP/1.1 and for any
        higher HTTP/1 minor (RFC 9110 §6.2).

    On need-more (`err.is_need_more()`):
      * The buffer doesn't yet contain a complete headers block.
        Caller should read more bytes and retry. NOT a hard error.

    On hard error: `err.kind != PARSE_ERR_NONE` and `err.status` is the
    HTTP status to send. `request` is in default-constructed state.
    """

    var err: ParseError
    var request: HttpRequest
    var headers_end_off: Int
    var content_length: Int
    var is_chunked: Bool
    var expects_continue: Bool
    var connection_close: Bool
    var http_version_minor: Int8

    def __init__(out self):
        self.err = ParseError.none()
        self.request = HttpRequest()
        self.headers_end_off = -1
        self.content_length = -1
        self.is_chunked = False
        self.expects_continue = False
        self.connection_close = False
        self.http_version_minor = Int8(1)


# =============================================================================
# §2 — Byte-class predicates (RFC 7230 §3.2 tchar).
# =============================================================================
# RFC 7230 §3.2.6: token = 1*tchar
# tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+"
#       / "-" / "." / "^" / "_" / "`" / "|" / "~" / DIGIT / ALPHA


def _is_tchar(b: UInt8) -> Bool:
    var c = Int(b)
    if c >= Int(ord("0")) and c <= Int(ord("9")):
        return True
    if c >= Int(ord("A")) and c <= Int(ord("Z")):
        return True
    if c >= Int(ord("a")) and c <= Int(ord("z")):
        return True
    # The 15 special tchars.
    if c == Int(ord("!")):
        return True
    if c == Int(ord("#")):
        return True
    if c == Int(ord("$")):
        return True
    if c == Int(ord("%")):
        return True
    if c == Int(ord("&")):
        return True
    if c == Int(ord("'")):
        return True
    if c == Int(ord("*")):
        return True
    if c == Int(ord("+")):
        return True
    if c == Int(ord("-")):
        return True
    if c == Int(ord(".")):
        return True
    if c == Int(ord("^")):
        return True
    if c == Int(ord("_")):
        return True
    if c == Int(ord("`")):
        return True
    if c == Int(ord("|")):
        return True
    if c == Int(ord("~")):
        return True
    return False


def _is_upper_alpha(b: UInt8) -> Bool:
    var c = Int(b)
    return c >= Int(ord("A")) and c <= Int(ord("Z"))


def _is_lower_alpha(b: UInt8) -> Bool:
    var c = Int(b)
    return c >= Int(ord("a")) and c <= Int(ord("z"))


def _is_digit(b: UInt8) -> Bool:
    var c = Int(b)
    return c >= Int(ord("0")) and c <= Int(ord("9"))


def _to_lower_ascii(b: UInt8) -> UInt8:
    if _is_upper_alpha(b):
        return UInt8(Int(b) + 32)
    return b


def _is_ows(b: UInt8) -> Bool:
    """RFC 7230 §3.2.3 OWS = *( SP / HTAB )."""
    return b == UInt8(0x20) or b == UInt8(0x09)


def _is_vchar_or_obs_text(b: UInt8) -> Bool:
    """Header field value chars per RFC 7230 §3.2.6:
    field-vchar = VCHAR / obs-text
    VCHAR       = %x21-7E
    obs-text    = %x80-FF  (allowed but the standard discourages)
    Implies disallow: CTL (< 0x20 except SP/HTAB inside field-content) +
    DEL (0x7F).
    """
    var c = Int(b)
    if c >= 0x21 and c <= 0x7E:
        return True
    if c >= 0x80:
        return True
    return False


# =============================================================================
# §3 — Byte buffer helpers.
# =============================================================================


def _find_crlf(buf: Span[UInt8, _], start: Int) -> Int:
    """Find the next CR LF (0x0D 0x0A) at or after `start`. Returns the
    offset of the CR byte, or -1 if not found."""
    var n = len(buf)
    var i = start
    while i + 1 < n:
        if buf[i] == UInt8(0x0D) and buf[i + 1] == UInt8(0x0A):
            return i
        i = i + 1
    return -1


def _find_crlfcrlf(buf: Span[UInt8, _], start: Int, scan_limit: Int) -> Int:
    """Find the next CR LF CR LF sequence at or after `start`. Returns the
    offset of the first CR, or -1 if not found within
    `min(len(buf), scan_limit)` bytes.
    """
    var n = len(buf)
    var lim = n if n < scan_limit else scan_limit
    if lim < 4:
        return -1
    var i = start
    while i + 4 <= lim:
        if (
            buf[i] == UInt8(0x0D)
            and buf[i + 1] == UInt8(0x0A)
            and buf[i + 2] == UInt8(0x0D)
            and buf[i + 3] == UInt8(0x0A)
        ):
            return i
        i = i + 1
    return -1


def _slice_to_string(buf: Span[UInt8, _], start: Int, end_excl: Int) -> String:
    """Construct a String from `buf[start:end_excl]`."""
    var out = String()
    var i = start
    while i < end_excl:
        out = out + chr(Int(buf[i]))
        i = i + 1
    return out^


def _slice_to_string_lower(
    buf: Span[UInt8, _], start: Int, end_excl: Int,
) -> String:
    """Lowercase ASCII slice → String. For header-name canonicalization."""
    var out = String()
    var i = start
    while i < end_excl:
        out = out + chr(Int(_to_lower_ascii(buf[i])))
        i = i + 1
    return out^


# =============================================================================
# §4 — Request-line parser.
# =============================================================================


@fieldwise_init
struct _RequestLineParse(Movable, Deinitable):
    var err: ParseError
    var method: HttpMethod
    var path: String
    var query_string: String
    var http_version_minor: Int8

    def __init__(out self):
        self.err = ParseError.none()
        self.method = HttpMethod.unknown()
        self.path = String()
        self.query_string = String()
        self.http_version_minor = Int8(1)


def _parse_request_line(
    buf: Span[UInt8, _], start: Int, crlf_off: Int,
) -> _RequestLineParse:
    """Parse the request line `buf[start:crlf_off]` (excluding CRLF).

    Shape: METHOD SP request-target SP HTTP-VERSION
    where HTTP-VERSION = "HTTP/" DIGIT "." DIGIT.

    Handles:
      * Bad method (unknown / lowercase) → method error (501)
      * Missing one of the two spaces → REQUEST_LINE_MALFORMED
      * HTTP/0.9 (no version on the line) → HTTP_09_REJECTED
      * A major version other than 1 → HTTP_VERSION_UNSUPPORTED
      * HTTP/1.2 to HTTP/1.9 → treated as HTTP/1.1 (RFC 9110 §6.2)
      * Whitespace inside request-target → URI_WHITESPACE
    """
    var out = _RequestLineParse()
    var line_len = crlf_off - start
    if line_len <= 0:
        out.err = ParseError.make(PARSE_ERR_REQUEST_LINE_MALFORMED, start)
        return out^

    # Find the first space.
    var sp1 = -1
    var i = start
    while i < crlf_off:
        if buf[i] == UInt8(0x20):
            sp1 = i
            break
        i = i + 1
    if sp1 < 0:
        # Single token = HTTP/0.9 simple request "GET /path\r\n".
        # Reject — we don't support 0.9.
        out.err = ParseError.make(PARSE_ERR_HTTP_09_REJECTED, start)
        return out^

    # Method = buf[start:sp1]. Validate.
    if sp1 == start:
        out.err = ParseError.make(PARSE_ERR_REQUEST_LINE_MALFORMED, start)
        return out^
    # Detect lowercase: any lowercase letter → reject (method is case-
    # sensitive per RFC 9110 §9.1; well-known methods are uppercase).
    var k = start
    var saw_lower = False
    while k < sp1:
        if not _is_tchar(buf[k]):
            # Some non-token char in method → malformed.
            out.err = ParseError.make(
                PARSE_ERR_REQUEST_LINE_MALFORMED, k,
            )
            return out^
        if _is_lower_alpha(buf[k]):
            saw_lower = True
        k = k + 1
    # The method's verdict waits until the rest of the line has parsed: 501
    # is for a well-formed request whose method is not implemented (RFC 9110
    # §9.1); a malformed line is 400 whatever its method.
    var method_str = _slice_to_string(buf, start, sp1)
    var method = HttpMethod.parse(method_str)

    # Find the next space (between request-target and HTTP-VERSION).
    # The request-target itself MUST NOT contain whitespace per RFC 7230.
    var sp2 = -1
    var j = sp1 + 1
    while j < crlf_off:
        if buf[j] == UInt8(0x20):
            sp2 = j
            break
        if buf[j] == UInt8(0x09):
            # Embedded TAB inside the URI — invalid.
            out.err = ParseError.make(PARSE_ERR_URI_WHITESPACE, j)
            return out^
        j = j + 1
    if sp2 < 0:
        # Two tokens but no version → could be 0.9; reject.
        out.err = ParseError.make(PARSE_ERR_HTTP_09_REJECTED, start)
        return out^

    if sp2 == sp1 + 1:
        # Empty request-target.
        out.err = ParseError.make(PARSE_ERR_REQUEST_LINE_MALFORMED, sp1)
        return out^

    # Request-target = buf[sp1+1:sp2]. Split on '?' for query.
    var qmark = -1
    var p = sp1 + 1
    while p < sp2:
        if buf[p] == UInt8(ord("?")):
            qmark = p
            break
        p = p + 1
    if qmark < 0:
        out.path = _slice_to_string(buf, sp1 + 1, sp2)
        out.query_string = String()
    else:
        out.path = _slice_to_string(buf, sp1 + 1, qmark)
        out.query_string = _slice_to_string(buf, qmark + 1, sp2)

    # HTTP-VERSION = buf[sp2+1:crlf_off]. Must be exactly 8 bytes,
    # "HTTP/" DIGIT "." DIGIT. Anything else is bad.
    var ver_start = sp2 + 1
    var ver_len = crlf_off - ver_start
    if ver_len != 8:
        out.err = ParseError.make(PARSE_ERR_HTTP_VERSION_BAD, ver_start)
        return out^
    # "HTTP/1." prefix.
    if (
        buf[ver_start] != UInt8(ord("H"))
        or buf[ver_start + 1] != UInt8(ord("T"))
        or buf[ver_start + 2] != UInt8(ord("T"))
        or buf[ver_start + 3] != UInt8(ord("P"))
        or buf[ver_start + 4] != UInt8(ord("/"))
    ):
        out.err = ParseError.make(PARSE_ERR_HTTP_VERSION_BAD, ver_start)
        return out^
    # Major version digit.
    if not _is_digit(buf[ver_start + 5]):
        out.err = ParseError.make(PARSE_ERR_HTTP_VERSION_BAD, ver_start + 5)
        return out^
    if buf[ver_start + 6] != UInt8(ord(".")):
        out.err = ParseError.make(PARSE_ERR_HTTP_VERSION_BAD, ver_start + 6)
        return out^
    if not _is_digit(buf[ver_start + 7]):
        out.err = ParseError.make(PARSE_ERR_HTTP_VERSION_BAD, ver_start + 7)
        return out^

    var major = Int(buf[ver_start + 5]) - Int(ord("0"))
    var minor = Int(buf[ver_start + 7]) - Int(ord("0"))
    if major != 1:
        # HTTP/0.x, HTTP/2.x, HTTP/3.x — not supported by this codec.
        out.err = ParseError.make(
            PARSE_ERR_HTTP_VERSION_UNSUPPORTED, ver_start + 5,
        )
        return out^
    if minor > 1:
        # RFC 9110 §6.2: a higher minor version of a major version the
        # recipient implements is treated as the highest minor it implements.
        minor = 1

    if saw_lower:
        out.err = ParseError.make(PARSE_ERR_METHOD_LOWERCASE, start)
        return out^
    if method.is_unknown():
        out.err = ParseError.make(PARSE_ERR_METHOD_UNKNOWN, start)
        return out^
    out.method = method
    out.http_version_minor = Int8(minor)
    return out^


# =============================================================================
# §5 — Header line parser.
# =============================================================================


@fieldwise_init
struct _HeaderLineParse(Movable, Deinitable):
    var err: ParseError
    var name_lower: String
    var value: String

    def __init__(out self):
        self.err = ParseError.none()
        self.name_lower = String()
        self.value = String()


def _parse_header_line(
    buf: Span[UInt8, _], start: Int, crlf_off: Int,
) -> _HeaderLineParse:
    """Parse one header line `buf[start:crlf_off]`.

    Shape: field-name ":" OWS field-value OWS

    Per RFC 7230 §3.2.4: obs-fold (CRLF before WSP at line start) MUST
    be rejected by a recipient (we do). Whitespace immediately before
    ':' MUST be rejected (we do).
    """
    var out = _HeaderLineParse()

    # Empty line — caller should've used this as terminator before
    # calling us. Defensive.
    if crlf_off <= start:
        out.err = ParseError.make(PARSE_ERR_HEADER_NO_COLON, start)
        return out^

    # Reject obs-fold: line begins with SP or HTAB.
    if buf[start] == UInt8(0x20) or buf[start] == UInt8(0x09):
        out.err = ParseError.make(PARSE_ERR_HEADER_OBS_FOLD, start)
        return out^

    # Find ':' boundary. Name = [start, colon). No whitespace allowed
    # between name and colon.
    var colon = -1
    var i = start
    while i < crlf_off:
        if buf[i] == UInt8(ord(":")):
            colon = i
            break
        # No SP/HTAB inside name + before ':'.
        if buf[i] == UInt8(0x20) or buf[i] == UInt8(0x09):
            out.err = ParseError.make(PARSE_ERR_HEADER_NAME_INVALID, i)
            return out^
        if not _is_tchar(buf[i]):
            out.err = ParseError.make(PARSE_ERR_HEADER_NAME_INVALID, i)
            return out^
        i = i + 1
    if colon < 0:
        out.err = ParseError.make(PARSE_ERR_HEADER_NO_COLON, start)
        return out^
    if colon == start:
        out.err = ParseError.make(PARSE_ERR_HEADER_NAME_INVALID, start)
        return out^

    out.name_lower = _slice_to_string_lower(buf, start, colon)

    # Value: skip leading OWS, capture, then trim trailing OWS.
    var vs = colon + 1
    while vs < crlf_off and _is_ows(buf[vs]):
        vs = vs + 1
    var ve = crlf_off
    while ve > vs and _is_ows(buf[ve - 1]):
        ve = ve - 1
    # Validate each remaining byte is a field-vchar (or SP/HTAB
    # inside the value).
    var k = vs
    while k < ve:
        var b = buf[k]
        if not (_is_vchar_or_obs_text(b) or _is_ows(b)):
            out.err = ParseError.make(
                PARSE_ERR_HEADER_VALUE_CONTROL_CHAR, k,
            )
            return out^
        k = k + 1
    # RFC 9110 §5.5: obs-text is opaque data. The header map holds `String`s,
    # which must be well-formed UTF-8, so a value that is well-formed UTF-8 is
    # kept as the octets sent. A value that is not (a lone 0xFF, Latin-1 0xE9)
    # is still served: each octet becomes the code point of the same number,
    # as the HPACK decoder does, so the value is re-encoded, never refused.
    if utf8_error_offset(buf, vs, ve) >= 0:
        out.value = _slice_to_string(buf, vs, ve)
        return out^
    out.value = String(unsafe_from_utf8=buf[vs:ve])
    return out^


# =============================================================================
# §6 — Header semantic post-processing.
# =============================================================================
# Handles Content-Length / Transfer-Encoding / Expect / Connection.


comptime _MAX_PARSED_DECIMAL: Int = 1 << 62
"""Ceiling on a parsed Content-Length. Retained from the original guard."""

comptime _MAX_PARSED_DECIMAL_DIV10: Int = _MAX_PARSED_DECIMAL // 10
"""Pre-multiply admission bound — see `_parse_decimal`. Comptime, so the
division is not in the binary."""


def _parse_decimal(s: String) -> Int:
    """Parse an unsigned decimal integer. Returns -1 on any error
    (negative, non-digit, empty, leading-zero with more digits is
    still OK per RFC 7230). Caller should pre-trim whitespace.

    ⚠ THE OVERFLOW GUARD IS BEFORE THE MULTIPLY. Accumulating first
    (`v = v * 10 + d`) and testing `v > (1 << 62)` after does not work: the multiply that wraps has already happened, and Int
    wrap is two's-complement, so the wrapped value can land small and
    POSITIVE and sail through the test. At ASSERT=none
    `Content-Length: 18446744073709551621` (2^64 + 5) would parse to **5** and
    be accepted by `parse_request_head` as the framing length. The
    `content_length_invalid` rejection at the call site only catches a
    NEGATIVE result, so it does not cover this. That is request smuggling, and
    it is live in every assert mode — nothing on this path was ever a bounds
    check.
    """
    var bytes = s.as_bytes()
    var n = len(bytes)
    if n == 0:
        return -1
    var v = 0
    var i = 0
    while i < n:
        var b = bytes[i]
        if not _is_digit(b):
            return -1
        if v > _MAX_PARSED_DECIMAL_DIV10:
            return -1
        v = v * 10 + (Int(b) - Int(ord("0")))
        if v > _MAX_PARSED_DECIMAL:
            return -1
        i = i + 1
    return v


def _str_eq_ci(a: String, b_lower_const: String) -> Bool:
    """Case-insensitive string equality; b is assumed lowercase."""
    var ab = a.as_bytes()
    var bb = b_lower_const.as_bytes()
    var an = len(ab)
    var bn = len(bb)
    if an != bn:
        return False
    var i = 0
    while i < an:
        if _to_lower_ascii(ab[i]) != bb[i]:
            return False
        i = i + 1
    return True


def _str_contains_token_ci(
    haystack: String, needle_lower: String,
) -> Bool:
    """Case-insensitive substring-as-comma-delimited-token search.

    Used for Transfer-Encoding (comma-delimited list of codings) and
    Connection (comma-delimited list of options).
    """
    var hb = haystack.as_bytes()
    var nb = needle_lower.as_bytes()
    var hn = len(hb)
    var nn = len(nb)
    if nn == 0:
        return False
    var i = 0
    while i < hn:
        # Skip whitespace and ',' separators.
        while i < hn and (
            hb[i] == UInt8(0x20)
            or hb[i] == UInt8(0x09)
            or hb[i] == UInt8(ord(","))
        ):
            i = i + 1
        # Try to match needle starting at i.
        if i + nn <= hn:
            var ok = True
            var k = 0
            while k < nn:
                if _to_lower_ascii(hb[i + k]) != nb[k]:
                    ok = False
                    break
                k = k + 1
            if ok:
                # Boundary check: end of haystack OR next char is
                # whitespace / comma.
                var after = i + nn
                if (
                    after == hn
                    or hb[after] == UInt8(0x20)
                    or hb[after] == UInt8(0x09)
                    or hb[after] == UInt8(ord(","))
                ):
                    return True
        # Advance past this token.
        while i < hn and hb[i] != UInt8(ord(",")):
            i = i + 1
    return False


# =============================================================================
# §7 — parse_request_head — the public entry point.
# =============================================================================


def parse_request_head(
    buf: Span[UInt8, _],
    limits: ParseLimits,
) -> HeadersParseOutcome:
    """Parse the request line + headers block out of `buf`.

    See HeadersParseOutcome for the result shape. Pure function; no
    side effects; no allocations beyond the dict + strings inside the
    HttpRequest on success.

    On NEED_MORE the caller should buffer more bytes and call again.
    On hard error the integration layer should serialize a
    `HttpResponse` with status `outcome.err.status` and close.
    """
    var out = HeadersParseOutcome()
    var n = len(buf)
    if n < 2:
        out.err = ParseError.need_more(0)
        return out^

    # RFC 9112 §2.2: a server SHOULD ignore at least one empty line (CRLF)
    # received before the request-line. Every leading CRLF is skipped; the
    # skipped bytes still count against the headers-scan window below.
    var start = 0
    while (
        start + 1 < n
        and buf[start] == UInt8(0x0D)
        and buf[start + 1] == UInt8(0x0A)
    ):
        start = start + 2

    # Find CRLFCRLF terminator within the headers-scan window.
    var scan_lim = limits.max_total_header_bytes
    # The scan limit also caps the request-line length implicitly, but
    # we re-check below after we know where it ends.
    var headers_end = _find_crlfcrlf(buf, start, scan_lim + 4)
    if headers_end < 0:
        if n >= scan_lim:
            # We've read scan_lim bytes without finding the terminator.
            out.err = ParseError.make(
                PARSE_ERR_HEADER_TOTAL_OVERFLOW, scan_lim,
            )
            return out^
        out.err = ParseError.need_more(n)
        return out^

    # The first CRLF inside the block is the request-line terminator.
    var line_end = _find_crlf(buf, start)
    if line_end < 0:
        # Shouldn't happen (we already saw CRLFCRLF), but be defensive.
        out.err = ParseError.make(PARSE_ERR_REQUEST_LINE_MALFORMED, 0)
        return out^

    if line_end - start > limits.max_request_line_bytes:
        out.err = ParseError.make(PARSE_ERR_URI_TOO_LONG, line_end)
        return out^

    var rl = _parse_request_line(buf, start, line_end)
    if not rl.err.is_ok():
        out.err = rl.err
        return out^

    # Build the request. We must use stdlib `swap()` to extract the
    # heap-owning fields from `rl` without partial-moving — the latter
    # leaves `rl` in a destructor-unsafe state per the pointer rules.
    var rl_method = rl.method
    var rl_version_minor = rl.http_version_minor
    var path_tmp = String()
    var query_tmp = String()
    swap(path_tmp, rl.path)
    swap(query_tmp, rl.query_string)
    out.request = HttpRequest(method=rl_method, path=path_tmp^)
    out.request.query_string = query_tmp^
    out.http_version_minor = rl_version_minor
    # HTTP/1.0 default is connection close unless keep-alive is asked.
    out.connection_close = (rl_version_minor == Int8(0))

    # Iterate header lines from line_end+2 (skip past CRLF) up to
    # headers_end (which points at the second CR — empty line CR).
    var hi = line_end + 2
    var header_count = 0
    var content_length_seen = -1
    var content_length_dupe = False
    var content_length_invalid = False
    var transfer_encoding_value = String()
    var transfer_encoding_seen = False
    var connection_value = String()
    var expect_value = String()
    while hi < headers_end:
        var line_crlf = _find_crlf(buf, hi)
        if line_crlf < 0:
            # Should not happen — defensive.
            out.err = ParseError.make(
                PARSE_ERR_REQUEST_LINE_MALFORMED, hi,
            )
            return out^
        var line_len = line_crlf - hi
        if line_len > limits.max_header_bytes:
            out.err = ParseError.make(
                PARSE_ERR_HEADER_SIZE_OVERFLOW, hi,
            )
            return out^
        var hlp = _parse_header_line(buf, hi, line_crlf)
        if not hlp.err.is_ok():
            out.err = hlp.err
            return out^
        header_count = header_count + 1
        if header_count > limits.max_headers:
            out.err = ParseError.make(
                PARSE_ERR_HEADER_COUNT_OVERFLOW, hi,
            )
            return out^

        # Extract name + value via stdlib swap (the pointer rules
        # replacement — partial move via UnsafePointer is banned).
        var name = String()
        var value = String()
        swap(name, hlp.name_lower)
        swap(value, hlp.value)

        # Semantic fan-out for framing-impacting headers.
        if _str_eq_ci(name, String("content-length")):
            var v = _parse_decimal(value)
            if v < 0:
                content_length_invalid = True
            elif content_length_seen < 0:
                content_length_seen = v
            elif content_length_seen != v:
                # Two CL with different values → 400. RFC 7230 §3.3.3
                # case 3 says reject conflicting.
                content_length_dupe = True
            else:
                # Two identical CLs → defensible to accept; we still
                # reject as ambiguous (smuggling-defense posture).
                content_length_dupe = True
        elif _str_eq_ci(name, String("transfer-encoding")):
            transfer_encoding_seen = True
            if len(transfer_encoding_value.as_bytes()) > 0:
                transfer_encoding_value = (
                    transfer_encoding_value + String(", ") + value
                )
            else:
                transfer_encoding_value = value
        elif _str_eq_ci(name, String("connection")):
            if len(connection_value.as_bytes()) > 0:
                connection_value = (
                    connection_value + String(", ") + value
                )
            else:
                connection_value = value
        elif _str_eq_ci(name, String("expect")):
            if len(expect_value.as_bytes()) > 0:
                expect_value = expect_value + String(", ") + value
            else:
                expect_value = value

        # Store into the request's header dict. Multi-valued headers
        # get comma-folded per RFC 7230 §3.2.2.
        var existing = out.request.headers.find(name)
        if existing:
            out.request.headers[name] = (
                existing.value() + String(", ") + value
            )
        else:
            out.request.headers[name^] = value^
        hi = line_crlf + 2

    # ---- Framing rules ----

    # Reject TE: <anything> we don't support. We only accept "chunked".
    if transfer_encoding_seen:
        var te_lower_chunked = String("chunked")
        if not _str_contains_token_ci(transfer_encoding_value, te_lower_chunked):
            out.err = ParseError.make(
                PARSE_ERR_TRANSFER_ENCODING_UNSUPPORTED, line_end,
            )
            return out^
        out.is_chunked = True

    if content_length_invalid:
        out.err = ParseError.make(
            PARSE_ERR_CONTENT_LENGTH_INVALID, line_end,
        )
        return out^
    if content_length_dupe:
        out.err = ParseError.make(
            PARSE_ERR_CONTENT_LENGTH_CONFLICT, line_end,
        )
        return out^

    if out.is_chunked and content_length_seen >= 0:
        # RFC 7230 §3.3.3 case 3: chunked + CL → reject (smuggling defense).
        out.err = ParseError.make(
            PARSE_ERR_CONTENT_LENGTH_AND_CHUNKED, line_end,
        )
        return out^

    if content_length_seen >= 0:
        if content_length_seen > limits.max_body_bytes:
            out.err = ParseError.make(
                PARSE_ERR_BODY_TOO_LARGE, line_end,
            )
            return out^
        out.content_length = content_length_seen

    # Expect: handle "100-continue" specifically; reject other expects.
    if len(expect_value.as_bytes()) > 0:
        if _str_eq_ci(expect_value, String("100-continue")):
            # RFC 9110 §10.1.1: a server MUST ignore a 100-continue
            # expectation in an HTTP/1.0 request (and §15.2: it MUST NOT
            # send a 1xx response to an HTTP/1.0 client).
            out.expects_continue = rl_version_minor != Int8(0)
        else:
            out.err = ParseError.make(
                PARSE_ERR_EXPECT_UNSUPPORTED, line_end,
            )
            return out^

    # Connection header — toggle keep-alive vs close.
    if len(connection_value.as_bytes()) > 0:
        if _str_contains_token_ci(connection_value, String("close")):
            out.connection_close = True
        elif _str_contains_token_ci(connection_value, String("keep-alive")):
            out.connection_close = False

    out.headers_end_off = headers_end + 4
    return out^


# =============================================================================
# §8 — Response serialization helpers.
# =============================================================================


def build_error_response_bytes(
    status: UInt16,
    mut out: List[UInt8],
):
    """Serialize a static error response (no client-derived bytes) into
    `out`. Always emits `Connection: close` so the caller can drop the
    conn after the bytes flush.

    Static bodies per status; no XSS surface.
    """
    out.clear()
    var line = String("HTTP/1.1 ") + String(Int(status)) + String(" ")
    # Reason phrase (kept short; standard).
    var reason = _reason_phrase(status)
    line = line + reason + String("\r\n")
    # Body string (static).
    var body = _static_error_body(status)
    var body_bytes = body.as_bytes()
    var body_len = len(body_bytes)
    var headers = String(
        "Content-Type: text/plain; charset=us-ascii\r\n"
        "Content-Length: "
    )
    headers = headers + String(body_len) + String("\r\n")
    headers = headers + String("Connection: close\r\n\r\n")

    var lb = line.as_bytes()
    var i = 0
    while i < len(lb):
        out.append(lb[i])
        i = i + 1
    var hb = headers.as_bytes()
    i = 0
    while i < len(hb):
        out.append(hb[i])
        i = i + 1
    i = 0
    while i < body_len:
        out.append(body_bytes[i])
        i = i + 1


def build_100_continue_bytes(mut out: List[UInt8]):
    """Serialize the interim 100 Continue response."""
    out.clear()
    var s = String("HTTP/1.1 100 Continue\r\n\r\n")
    var bytes = s.as_bytes()
    var i = 0
    while i < len(bytes):
        out.append(bytes[i])
        i = i + 1


def _reason_phrase(status: UInt16) -> String:
    var out = String()
    _write_reason_phrase(out, status)
    return out^


def _static_error_body(status: UInt16) -> String:
    """Static, non-client-derived error body text.

    NEVER include client input here. The strings are short, in
    plain ASCII, and identical across calls.
    """
    var out = String()
    _write_static_error_body(out, status)
    return out^
