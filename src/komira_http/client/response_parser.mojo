# =============================================================================
# src/komira_http/client/response_parser.mojo — HTTP/1.1 response parser
# =============================================================================
#
# socket-free parser shape +
# §7.0 typed surfaces.
#
# This parser is symmetric to komira_http/codec/h1/parser.mojo's
# `parse_request_head` but operates on the response side:
#   request side  : METHOD path HTTP/1.1\r\n + headers
#   response side : HTTP/1.1 status reason\r\n + headers
#
# The body-decoding half REUSES the chunked decoder at
# `codec/h1/chunked.mojo::decode_block` (already public, no refactor
# needed); Content-Length framing is a simple bounded slice.
#
# Header byte-class predicates + line-finding helpers are
# COPIED-AND-ADAPTED from the server codec's parser (~30 LOC duplication),
# NOT refactored out of its private helpers. Rationale: The server tests
# stay untouched; the duplication has known fixed cost; future
# convergence can hoist these into a shared module if a third consumer
# appears.
#
# Pointer discipline:
#   * ZERO UnsafePointer in any public signature.
#   * ZERO wildcard origins.
#   * ZERO `unsafe_from_address`.
#   * Span-based input — caller's frame origin propagates.
# =============================================================================


from komira_http.client.error import (
    HTTP_ERROR_HEADERS_TOO_LARGE,
    HTTP_ERROR_HEADER_INVALID,
    HTTP_ERROR_RESPONSE_FRAMING,
    HTTP_ERROR_STATUS_LINE_INVALID,
    HttpError,
)
from komira_http.client.header_map import HeaderBytes, HeaderMap


# =============================================================================
# §1 — Response-parser limits.
# =============================================================================
# Symmetric to codec/h1/limits.ParseLimits but client-side. Different
# defaults make sense (response bodies can be larger; header counts
# tend to be similar).

comptime DEFAULT_RESP_MAX_HEADERS: Int = 100
comptime DEFAULT_RESP_MAX_HEADER_BYTES: Int = 16384
comptime DEFAULT_RESP_MAX_TOTAL_HEADER_BYTES: Int = 65536
comptime DEFAULT_RESP_MAX_STATUS_LINE_BYTES: Int = 8192


@fieldwise_init
struct ResponseParseLimits(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    """Limits enforced on every response parse. All sizes in bytes."""

    var max_headers: Int
    var max_header_bytes: Int
    var max_total_header_bytes: Int
    var max_status_line_bytes: Int

    @staticmethod
    def defaults() -> ResponseParseLimits:
        return ResponseParseLimits(
            max_headers=DEFAULT_RESP_MAX_HEADERS,
            max_header_bytes=DEFAULT_RESP_MAX_HEADER_BYTES,
            max_total_header_bytes=DEFAULT_RESP_MAX_TOTAL_HEADER_BYTES,
            max_status_line_bytes=DEFAULT_RESP_MAX_STATUS_LINE_BYTES,
        )


# =============================================================================
# §2 — Parse outcome.
# =============================================================================
# A parse can:
#   * succeed (outcome.err.is_ok()): status / headers are filled in,
#     headers_end_off is the byte after the terminating CRLFCRLF.
#     The body begins at buf[headers_end_off:].
#   * need_more: input buffer doesn't yet hold a complete headers block.
#     Caller should read more bytes and retry. NOT a hard error.
#   * hard error: outcome.err is a populated HttpError.


comptime _RESP_PARSE_RESULT_OK: UInt8 = 0
comptime _RESP_PARSE_RESULT_NEED_MORE: UInt8 = 1
comptime _RESP_PARSE_RESULT_ERROR: UInt8 = 2


struct ResponseHead(Movable, Deinitable):
    """Parsed response head (status line + headers).

    On success: `result == _RESP_PARSE_RESULT_OK`, fields populated.
    On NEED_MORE: `result == _RESP_PARSE_RESULT_NEED_MORE`, err is the
      no-error sentinel.
    On hard error: `result == _RESP_PARSE_RESULT_ERROR`, err carries the
      typed HttpError.
    """

    var result: UInt8
    var err: HttpError
    var status: Int32
    """RFC 9110 status code: 100-599. 0 if !ok."""
    var reason: String
    """Reason phrase. May be empty (HTTP/1.1 allows it)."""
    var http_version_minor: Int8
    """0 for HTTP/1.0, 1 for HTTP/1.1."""
    var headers: HeaderMap
    var headers_end_off: Int
    """Offset of first byte AFTER the CRLFCRLF terminator. The body
    begins here. -1 on need_more or error."""
    var content_length: Int
    """-1 if absent (chunked or read-until-EOF).
       0..N when a single well-formed CL header is present."""
    var is_chunked: Bool
    """True iff Transfer-Encoding contains `chunked`."""
    var connection_close: Bool
    """True iff Connection: close was present (or HTTP/1.0 default
    without keep-alive)."""

    def __init__(out self):
        self.result = _RESP_PARSE_RESULT_NEED_MORE
        self.err = HttpError.none()
        self.status = Int32(0)
        self.reason = String()
        self.http_version_minor = Int8(1)
        self.headers = HeaderMap()
        self.headers_end_off = -1
        self.content_length = -1
        self.is_chunked = False
        self.connection_close = False

    @always_inline
    def is_ok(self) -> Bool:
        return self.result == _RESP_PARSE_RESULT_OK

    @always_inline
    def is_need_more(self) -> Bool:
        return self.result == _RESP_PARSE_RESULT_NEED_MORE

    @always_inline
    def is_error(self) -> Bool:
        return self.result == _RESP_PARSE_RESULT_ERROR


# =============================================================================
# §3 — Byte-class predicates (copied-and-adapted from codec/h1/parser.mojo).
# =============================================================================
# Same as's `_is_tchar` / `_is_ows` etc.  Kept local to the client
# module so the server tests' surface stays untouched.


@always_inline
def _is_tchar(b: UInt8) -> Bool:
    """RFC 7230 §3.2.6 tchar."""
    var c = Int(b)
    if c >= Int(ord("0")) and c <= Int(ord("9")):
        return True
    if c >= Int(ord("A")) and c <= Int(ord("Z")):
        return True
    if c >= Int(ord("a")) and c <= Int(ord("z")):
        return True
    if c == Int(ord("!")) or c == Int(ord("#")) or c == Int(ord("$")):
        return True
    if c == Int(ord("%")) or c == Int(ord("&")) or c == Int(ord("'")):
        return True
    if c == Int(ord("*")) or c == Int(ord("+")) or c == Int(ord("-")):
        return True
    if c == Int(ord(".")) or c == Int(ord("^")) or c == Int(ord("_")):
        return True
    if c == Int(ord("`")) or c == Int(ord("|")) or c == Int(ord("~")):
        return True
    return False


@always_inline
def _is_digit(b: UInt8) -> Bool:
    var c = Int(b)
    return c >= Int(ord("0")) and c <= Int(ord("9"))


@always_inline
def _is_ows(b: UInt8) -> Bool:
    return b == UInt8(0x20) or b == UInt8(0x09)


@always_inline
def _is_vchar_or_obs_text(b: UInt8) -> Bool:
    var c = Int(b)
    if c >= 0x21 and c <= 0x7E:
        return True
    if c >= 0x80:
        return True
    return False


@always_inline
def _to_lower_ascii(b: UInt8) -> UInt8:
    var c = Int(b)
    if c >= Int(ord("A")) and c <= Int(ord("Z")):
        return UInt8(c + 32)
    return b


def _find_crlf(buf: Span[UInt8, _], start: Int) -> Int:
    var n = len(buf)
    var i = start
    while i + 1 < n:
        if buf[i] == UInt8(0x0D) and buf[i + 1] == UInt8(0x0A):
            return i
        i = i + 1
    return -1


def _find_crlfcrlf(buf: Span[UInt8, _], start: Int, scan_limit: Int) -> Int:
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
    var out = String()
    var i = start
    while i < end_excl:
        out = out + chr(Int(buf[i]))
        i = i + 1
    return out^


def _slice_to_string_lower(buf: Span[UInt8, _], start: Int, end_excl: Int) -> String:
    var out = String()
    var i = start
    while i < end_excl:
        out = out + chr(Int(_to_lower_ascii(buf[i])))
        i = i + 1
    return out^


# =============================================================================
# §4 — Status line parser.
# =============================================================================
# Per RFC 7230 §3.1.2:
#   status-line = HTTP-version SP status-code SP reason-phrase CRLF
#   HTTP-version = "HTTP/" DIGIT "." DIGIT  (we accept 1.0 / 1.1 only)
#   status-code  = 3DIGIT
#   reason-phrase = *( HTAB / SP / VCHAR / obs-text )  -- may be empty
# Reason-phrase may contain spaces — must read up to the CRLF, not the
# next SP.


@fieldwise_init
struct _StatusLineParse(Movable, Deinitable):
    var ok: Bool
    var http_version_minor: Int8
    var status: Int32
    var reason: String
    var detail: String

    def __init__(out self):
        self.ok = False
        self.http_version_minor = Int8(1)
        self.status = Int32(0)
        self.reason = String()
        self.detail = String()


def _parse_status_line(
    buf: Span[UInt8, _], start: Int, crlf_off: Int,
) -> _StatusLineParse:
    var out = _StatusLineParse()
    var line_len = crlf_off - start
    if line_len < 12:
        # Minimum: "HTTP/1.1 200" — 12 bytes (no reason needed).
        out.detail = String("status line too short")
        return out^

    # Version literal "HTTP/x.y".
    if line_len < 8:
        out.detail = String("missing HTTP-version")
        return out^
    if (
        buf[start] != UInt8(ord("H"))
        or buf[start + 1] != UInt8(ord("T"))
        or buf[start + 2] != UInt8(ord("T"))
        or buf[start + 3] != UInt8(ord("P"))
        or buf[start + 4] != UInt8(ord("/"))
    ):
        out.detail = String("HTTP-version bad prefix")
        return out^
    if not _is_digit(buf[start + 5]):
        out.detail = String("HTTP-version major bad")
        return out^
    if buf[start + 6] != UInt8(ord(".")):
        out.detail = String("HTTP-version separator bad")
        return out^
    if not _is_digit(buf[start + 7]):
        out.detail = String("HTTP-version minor bad")
        return out^
    var major = Int(buf[start + 5]) - Int(ord("0"))
    var minor = Int(buf[start + 7]) - Int(ord("0"))
    if major != 1 or (minor != 0 and minor != 1):
        out.detail = String("unsupported HTTP-version")
        return out^

    # SP after version.
    if buf[start + 8] != UInt8(0x20):
        out.detail = String("missing SP after HTTP-version")
        return out^

    # 3-digit status.
    if line_len < 12:
        out.detail = String("missing status-code")
        return out^
    if (
        not _is_digit(buf[start + 9])
        or not _is_digit(buf[start + 10])
        or not _is_digit(buf[start + 11])
    ):
        out.detail = String("status-code not 3 digits")
        return out^
    var status_val = (
        (Int(buf[start + 9]) - Int(ord("0"))) * 100
        + (Int(buf[start + 10]) - Int(ord("0"))) * 10
        + (Int(buf[start + 11]) - Int(ord("0")))
    )
    if status_val < 100 or status_val > 599:
        out.detail = String("status-code out of range")
        return out^

    # Reason phrase (optional, may be empty). The line might be
    # "HTTP/1.1 200" (12 bytes, no reason, no SP) — RFC 7230 §3.1.2
    # allows an empty reason phrase but the SP is still required.
    # Real-world servers (nginx, Apache) emit "HTTP/1.1 200\r\n" or
    # "HTTP/1.1 200 OK\r\n" — we accept both.
    var reason = String()
    if line_len >= 13:
        # Expect SP at offset 12.
        if buf[start + 12] != UInt8(0x20):
            out.detail = String("missing SP before reason-phrase")
            return out^
        # Reason runs from start+13 to crlf_off. Validate each byte.
        var i = start + 13
        while i < crlf_off:
            var b = buf[i]
            if not (_is_vchar_or_obs_text(b) or _is_ows(b)):
                out.detail = String("control char in reason-phrase")
                return out^
            i = i + 1
        reason = _slice_to_string(buf, start + 13, crlf_off)
    else:
        # line_len == 12: bytes are "HTTP/1.1 200" only. Acceptable per
        # the grammar (reason-phrase is *( ... ), can be 0-length).
        # No SP-before-reason required.
        # Note: line_len < 12 was rejected above.
        pass

    out.ok = True
    out.http_version_minor = Int8(minor)
    out.status = Int32(status_val)
    out.reason = reason^
    return out^


# =============================================================================
# §5 — Header line parser.
# =============================================================================
# Same structure as the server codec — name (tchar+) ":" OWS value OWS, with
# obs-fold rejected and control chars in value rejected.


@fieldwise_init
struct _HeaderLineParse(Movable, Deinitable):
    var ok: Bool
    var name_lower: String
    var value: String
    var detail: String

    def __init__(out self):
        self.ok = False
        self.name_lower = String()
        self.value = String()
        self.detail = String()


def _parse_header_line(
    buf: Span[UInt8, _], start: Int, crlf_off: Int,
) -> _HeaderLineParse:
    var out = _HeaderLineParse()
    if crlf_off <= start:
        out.detail = String("empty header line")
        return out^
    # obs-fold rejection.
    if buf[start] == UInt8(0x20) or buf[start] == UInt8(0x09):
        out.detail = String("obs-fold in response header")
        return out^

    # Find ':' boundary.
    var colon = -1
    var i = start
    while i < crlf_off:
        if buf[i] == UInt8(ord(":")):
            colon = i
            break
        if buf[i] == UInt8(0x20) or buf[i] == UInt8(0x09):
            out.detail = String("whitespace in header name")
            return out^
        if not _is_tchar(buf[i]):
            out.detail = String("invalid char in header name")
            return out^
        i = i + 1
    if colon < 0:
        out.detail = String("missing colon")
        return out^
    if colon == start:
        out.detail = String("empty header name")
        return out^

    out.name_lower = _slice_to_string_lower(buf, start, colon)

    # Value with OWS trim.
    var vs = colon + 1
    while vs < crlf_off and _is_ows(buf[vs]):
        vs = vs + 1
    var ve = crlf_off
    while ve > vs and _is_ows(buf[ve - 1]):
        ve = ve - 1
    var k = vs
    while k < ve:
        var b = buf[k]
        if not (_is_vchar_or_obs_text(b) or _is_ows(b)):
            out.detail = String("control char in header value")
            return out^
        k = k + 1
    out.value = _slice_to_string(buf, vs, ve)
    out.ok = True
    return out^


# =============================================================================
# §5.1 — Offsets-only header parser.
# =============================================================================
# Parses one header line into byte offsets WITHOUT building Strings.
# The parser hot path calls this + then uses the offsets to slice the
# per-response head SAB. Framing fan-out (content-length /
# transfer-encoding / connection) uses byte-direct CI compare against
# StaticString constants.


@fieldwise_init
struct _HeaderLineOffsets(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    var ok: Bool
    var name_start: Int
    var name_end: Int   # exclusive
    var value_start: Int
    var value_end: Int  # exclusive

    def __init__(out self):
        self.ok = False
        self.name_start = 0
        self.name_end = 0
        self.value_start = 0
        self.value_end = 0


def _parse_header_line_offsets(
    buf: Span[UInt8, _], start: Int, crlf_off: Int,
) -> _HeaderLineOffsets:
    """Same byte-level validation as `_parse_header_line` but emits
    offsets only — no String construction."""
    var out = _HeaderLineOffsets()
    if crlf_off <= start:
        return out^
    if buf[start] == UInt8(0x20) or buf[start] == UInt8(0x09):
        return out^

    var colon = -1
    var i = start
    while i < crlf_off:
        if buf[i] == UInt8(ord(":")):
            colon = i
            break
        if buf[i] == UInt8(0x20) or buf[i] == UInt8(0x09):
            return out^
        if not _is_tchar(buf[i]):
            return out^
        i = i + 1
    if colon < 0:
        return out^
    if colon == start:
        return out^

    var vs = colon + 1
    while vs < crlf_off and _is_ows(buf[vs]):
        vs = vs + 1
    var ve = crlf_off
    while ve > vs and _is_ows(buf[ve - 1]):
        ve = ve - 1
    var k = vs
    while k < ve:
        var b = buf[k]
        if not (_is_vchar_or_obs_text(b) or _is_ows(b)):
            return out^
        k = k + 1

    out.name_start = start
    out.name_end = colon
    out.value_start = vs
    out.value_end = ve
    out.ok = True
    return out^


@always_inline
def _byte_span_eq_ci_lower(
    buf: Span[UInt8, _], start: Int, name_len: Int, lower: StaticString,
) -> Bool:
    """CI compare buf[start:start+name_len] against `lower` (assumed
    already-lowercase). Used for framing-header detection without
    allocating a String."""
    var lower_bytes = lower.as_bytes()
    var ln = len(lower_bytes)
    if name_len != ln:
        return False
    var i = 0
    while i < ln:
        if _to_lower_ascii(buf[start + i]) != lower_bytes[i]:
            return False
        i = i + 1
    return True


comptime _MAX_PARSED_DECIMAL: Int = 1 << 62
"""Ceiling on a parsed response Content-Length. Retained from the original
guard."""

comptime _MAX_PARSED_DECIMAL_DIV10: Int = _MAX_PARSED_DECIMAL // 10
"""Pre-multiply admission bound: `v <= this` makes `v * 10 + 9` unable to
exceed `_MAX_PARSED_DECIMAL + 9`, so the accumulate cannot wrap Int64."""


def _parse_decimal_bytes(buf: Span[UInt8, _], start: Int, length: Int) -> Int:
    """Parse decimal int from buf[start:start+length] without
    constructing a String. Returns -1 on invalid input.

    ⚠ THE OVERFLOW GUARD IS BEFORE THE MULTIPLY — see the twin in
    `codec/h1/parser.mojo:_parse_decimal` for the full reasoning. With
    the guard after the multiply, a response
    `Content-Length: 18446744073709551621` parsed to **5**. On the CLIENT this
    is response splitting — we would consume 5 body bytes and then read the
    attacker's remaining bytes as the next response's status line.
    """
    if length == 0:
        return -1
    var v = 0
    var i = 0
    while i < length:
        var b = buf[start + i]
        if not _is_digit(b):
            return -1
        if v > _MAX_PARSED_DECIMAL_DIV10:
            return -1
        v = v * 10 + (Int(b) - Int(ord("0")))
        if v > _MAX_PARSED_DECIMAL:
            return -1
        i = i + 1
    return v


def _byte_span_contains_token_ci(
    buf: Span[UInt8, _], start: Int, length: Int, needle_lower: StaticString,
) -> Bool:
    """Byte-direct equivalent of `_str_contains_token_ci` over a
    sub-span of `buf`. Tokens are delimited by SP / HTAB / comma."""
    var nb = needle_lower.as_bytes()
    var nn = len(nb)
    if nn == 0:
        return False
    var end = start + length
    var i = start
    while i < end:
        while i < end and (
            buf[i] == UInt8(0x20)
            or buf[i] == UInt8(0x09)
            or buf[i] == UInt8(ord(","))
        ):
            i = i + 1
        if i + nn <= end:
            var ok = True
            var k = 0
            while k < nn:
                if _to_lower_ascii(buf[i + k]) != nb[k]:
                    ok = False
                    break
                k = k + 1
            if ok:
                var after = i + nn
                if (
                    after == end
                    or buf[after] == UInt8(0x20)
                    or buf[after] == UInt8(0x09)
                    or buf[after] == UInt8(ord(","))
                ):
                    return True
        while i < end and buf[i] != UInt8(ord(",")):
            i = i + 1
    return False


# =============================================================================
# §6 — Decimal-parse helper.
# =============================================================================


def _parse_decimal(s: String) -> Int:
    """String-input twin of `_parse_decimal_bytes` — same pre-multiply
    overflow discipline, same ceiling. Kept in lockstep deliberately: the
    round-1 pass fixed one accumulator of this shape and left its twins, which
    is the failure this comment exists to stop repeating."""
    var bytes_ref = s.as_bytes()
    var n = len(bytes_ref)
    if n == 0:
        return -1
    var v = 0
    var i = 0
    while i < n:
        var b = bytes_ref[i]
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


def _str_last_token_is_ci(haystack: String, needle_lower: String) -> Bool:
    """True iff the LAST non-empty comma-separated list element of
    `haystack`, OWS-trimmed, equals `needle_lower` case-insensitively.

    THIS IS THE FRAMING PREDICATE, AND IT IS NOT `_str_contains_token_ci`.
    RFC 9112 6.3(3) makes chunked framing conditional on chunked being the
    FINAL transfer coding, so the question is "what is the last element",
    never "does the list contain one". `chunked, gzip` says chunked was
    applied first and THEN gzip: what is on the wire is gzip-framed, and
    running the chunked decoder over it reads attacker-chosen bytes as
    chunk-size lines -- the primitive request/response-desync attacks are
    built from.

    Empty list elements are parsed and ignored per RFC 9110 5.6.1, so
    `,chunked` and `chunked,` both have `chunked` as their last non-empty
    element. Comparison is whole-element, so `chunkedchunked`, `xchunked`,
    `chunked-x` and `chunked;q=1` are all correctly NOT chunked.

    Note `Connection` keeps using `_str_contains_token_ci`: `close` and
    `keep-alive` are position-INSENSITIVE by definition, so that predicate
    is right there and wrong here.
    """
    var hb = haystack.as_bytes()
    var nb = needle_lower.as_bytes()
    var hn = len(hb)
    var nn = len(nb)
    if nn == 0:
        return False
    # Walk every comma-delimited element, remembering the last NON-EMPTY one.
    var last_start = -1
    var last_end = -1
    var i = 0
    while i <= hn:
        var j = i
        while j < hn and hb[j] != UInt8(ord(",")):
            j = j + 1
        # Trim OWS (SP / HTAB) off both ends of the element [i, j).
        var lo = i
        var hi2 = j
        while lo < hi2 and (
            hb[lo] == UInt8(0x20) or hb[lo] == UInt8(0x09)
        ):
            lo = lo + 1
        while hi2 > lo and (
            hb[hi2 - 1] == UInt8(0x20) or hb[hi2 - 1] == UInt8(0x09)
        ):
            hi2 = hi2 - 1
        if hi2 > lo:
            last_start = lo
            last_end = hi2
        if j >= hn:
            break
        i = j + 1
    if last_start < 0:
        return False
    if last_end - last_start != nn:
        return False
    var k = 0
    while k < nn:
        if _to_lower_ascii(hb[last_start + k]) != nb[k]:
            return False
        k = k + 1
    return True


def _str_contains_token_ci(haystack: String, needle_lower: String) -> Bool:
    var hb = haystack.as_bytes()
    var nb = needle_lower.as_bytes()
    var hn = len(hb)
    var nn = len(nb)
    if nn == 0:
        return False
    var i = 0
    while i < hn:
        while i < hn and (
            hb[i] == UInt8(0x20)
            or hb[i] == UInt8(0x09)
            or hb[i] == UInt8(ord(","))
        ):
            i = i + 1
        if i + nn <= hn:
            var ok = True
            var k = 0
            while k < nn:
                if _to_lower_ascii(hb[i + k]) != nb[k]:
                    ok = False
                    break
                k = k + 1
            if ok:
                var after = i + nn
                if (
                    after == hn
                    or hb[after] == UInt8(0x20)
                    or hb[after] == UInt8(0x09)
                    or hb[after] == UInt8(ord(","))
                ):
                    return True
        while i < hn and hb[i] != UInt8(ord(",")):
            i = i + 1
    return False


# =============================================================================
# §7 — parse_response_head — the public entry point.
# =============================================================================


def parse_response_head(
    buf: Span[UInt8, _],
    limits: ResponseParseLimits,
) raises -> ResponseHead:
    """Parse the response head out of `buf` (status line + headers, up
    to and including the terminating CRLFCRLF).

    .3.F.2b — header storage: on parse success (headers_end found),
    allocate a HeaderBytes-backed `List[UInt8]` holding
    `buf[0:headers_end+4]` and populate HeaderMap via
    `append_view(head_bytes, ...)` — one memcpy per response, then
    zero-copy slices per header (ArcPointer refcount-inc only). Framing
    fan-out uses byte-direct CI compare against StaticString.

    On NEED_MORE: caller should append more bytes to `buf` and retry.
    On hard error: result.err carries the typed HttpError.
    On success: result fields are populated; the body begins at
    `buf[result.headers_end_off:]`.
    """
    var out = ResponseHead()
    var n = len(buf)
    if n < 2:
        # Cannot even hold a CRLF. need_more.
        out.result = _RESP_PARSE_RESULT_NEED_MORE
        return out^

    # Find CRLFCRLF terminator.
    var scan_lim = limits.max_total_header_bytes
    var headers_end = _find_crlfcrlf(buf, 0, scan_lim + 4)
    if headers_end < 0:
        if n >= scan_lim:
            out.result = _RESP_PARSE_RESULT_ERROR
            out.err = HttpError.headers_too_large()
            return out^
        out.result = _RESP_PARSE_RESULT_NEED_MORE
        return out^

    # Status line ends at first CRLF.
    var line_end = _find_crlf(buf, 0)
    if line_end < 0:
        out.result = _RESP_PARSE_RESULT_ERROR
        out.err = HttpError.status_line_invalid(String("no CRLF found"))
        return out^

    if line_end > limits.max_status_line_bytes:
        out.result = _RESP_PARSE_RESULT_ERROR
        out.err = HttpError.status_line_invalid(String("status line too long"))
        return out^

    var sl = _parse_status_line(buf, 0, line_end)
    if not sl.ok:
        out.result = _RESP_PARSE_RESULT_ERROR
        var detail_tmp = String()
        swap(detail_tmp, sl.detail)
        out.err = HttpError.status_line_invalid(detail_tmp^)
        return out^

    out.status = sl.status
    out.http_version_minor = sl.http_version_minor
    var reason_tmp = String()
    swap(reason_tmp, sl.reason)
    out.reason = reason_tmp^
    # HTTP/1.0 default is connection close unless keep-alive is asked.
    out.connection_close = (sl.http_version_minor == Int8(0))

    #.3.F.2b: build the per-response head HeaderBytes backing. ONE
    # memcpy of headers_end+4 bytes (typically 200-500) into a
    # `List[UInt8]` wrapped in ArcPointer[List[UInt8]] via HeaderBytes.
    # Subsequent header entries reference sub-slices of this HeaderBytes;
    # ArcPointer keeps the bytes alive until the ResponseHead's
    # HeaderMap drops.
    var head_total = headers_end + 4  # include terminating CRLFCRLF
    var head_storage = List[UInt8]()
    head_storage.reserve(head_total)
    var copy_i = 0
    while copy_i < head_total:
        head_storage.append(buf[copy_i])
        copy_i = copy_i + 1
    var head_bytes = HeaderBytes(head_storage^)

    # Header iteration.
    var hi = line_end + 2  # skip past status-line CRLF
    var header_count = 0
    var content_length_seen = -1
    var content_length_dupe = False
    var content_length_invalid = False
    # transfer_encoding / connection accumulate across multiple header lines
    # via comma-join. Stored as Strings since the multi-line case requires
    # concatenation; in practice these appear at most once per response.
    var transfer_encoding_value = String()
    var transfer_encoding_seen = False
    var connection_value = String()
    while hi < headers_end:
        var line_crlf = _find_crlf(buf, hi)
        if line_crlf < 0:
            out.result = _RESP_PARSE_RESULT_ERROR
            out.err = HttpError.header_invalid(String("no CRLF for header line"))
            return out^
        var line_len = line_crlf - hi
        if line_len > limits.max_header_bytes:
            out.result = _RESP_PARSE_RESULT_ERROR
            out.err = HttpError.headers_too_large()
            return out^
        var hlo = _parse_header_line_offsets(buf, hi, line_crlf)
        if not hlo.ok:
            out.result = _RESP_PARSE_RESULT_ERROR
            out.err = HttpError.header_invalid(String("malformed header line"))
            return out^
        header_count = header_count + 1
        if header_count > limits.max_headers:
            out.result = _RESP_PARSE_RESULT_ERROR
            out.err = HttpError.headers_too_large()
            return out^

        var name_len = hlo.name_end - hlo.name_start
        var value_len = hlo.value_end - hlo.value_start

        # Semantic fan-out for framing-impacting headers — byte-direct
        # CI compare against StaticString to avoid String allocations.
        if _byte_span_eq_ci_lower(buf, hlo.name_start, name_len, "content-length"):
            var v = _parse_decimal_bytes(buf, hlo.value_start, value_len)
            if v < 0:
                content_length_invalid = True
            elif content_length_seen < 0:
                content_length_seen = v
            elif content_length_seen != v:
                # RFC 9112 6.3(4): only DIFFERING values are the
                # unrecoverable case. A repeated field-value that AGREES is
                # not a framing ambiguity -- there is exactly one length
                # every recipient in the chain will compute.
                content_length_dupe = True
            # else: byte-identical repeat. RFC 9110 8.6 lets a recipient
            # replace several identical Content-Length field-values with the
            # single value; Go (`http.fixLength`), hyper and nginx accept it,
            # and proxies do emit it. Keep `content_length_seen`, carry on.
            # Pinned by `test_cl_duplicate_identical_values_is_accepted`.
        elif _byte_span_eq_ci_lower(buf, hlo.name_start, name_len, "transfer-encoding"):
            transfer_encoding_seen = True
            # Rare-path String accumulation (typically 1 header line).
            var v_str = _slice_to_string(buf, hlo.value_start, hlo.value_end)
            if len(transfer_encoding_value.as_bytes()) > 0:
                transfer_encoding_value = (
                    transfer_encoding_value + String(", ") + v_str
                )
            else:
                transfer_encoding_value = v_str^
        elif _byte_span_eq_ci_lower(buf, hlo.name_start, name_len, "connection"):
            # Rare-path String accumulation.
            var v_str2 = _slice_to_string(buf, hlo.value_start, hlo.value_end)
            if len(connection_value.as_bytes()) > 0:
                connection_value = connection_value + String(", ") + v_str2
            else:
                connection_value = v_str2^

        # Append (NOT insert — Set-Cookie may repeat) into the header map
        # via zero-copy sub-slices of the head HeaderBytes.
        out.headers.append_view(
            head_bytes,
            hlo.name_start, name_len,
            hlo.value_start, value_len,
        )
        hi = line_crlf + 2

    # ---- Framing rules ----

    if transfer_encoding_seen:
        # RFC 9112 6.1 + 6.3(3): chunked framing applies only when chunked is
        # the FINAL transfer coding. Anything else -- an unrecognised coding,
        # or chunked applied before another one -- means we cannot know where
        # this body ends, and we REJECT rather than guess.
        #
        # We are deliberately STRICTER than 6.3(3), which makes an unusable
        # Transfer-Encoding on a RESPONSE close-delimited rather than an
        # error. Pinned, with the departure stated, by
        # `test_response_with_unusable_te_is_rejected_not_close_delimited`.
        var te_chunked = String("chunked")
        if not _str_last_token_is_ci(transfer_encoding_value, te_chunked):
            out.result = _RESP_PARSE_RESULT_ERROR
            out.err = HttpError.response_framing(
                String(
                    "Transfer-Encoding does not end in chunked: "
                ) + transfer_encoding_value,
            )
            return out^
        out.is_chunked = True

    if content_length_invalid:
        out.result = _RESP_PARSE_RESULT_ERROR
        out.err = HttpError.response_framing(
            String("Content-Length invalid"),
        )
        return out^
    if content_length_dupe:
        out.result = _RESP_PARSE_RESULT_ERROR
        out.err = HttpError.response_framing(
            String("Content-Length conflict"),
        )
        return out^

    if out.is_chunked and content_length_seen >= 0:
        # RFC 7230 §3.3.3 case 3 — smuggling defense.
        out.result = _RESP_PARSE_RESULT_ERROR
        out.err = HttpError.response_framing(
            String("Content-Length with chunked TE"),
        )
        return out^

    if content_length_seen >= 0:
        out.content_length = content_length_seen

    # Connection toggle.
    if len(connection_value.as_bytes()) > 0:
        if _str_contains_token_ci(connection_value, String("close")):
            out.connection_close = True
        elif _str_contains_token_ci(connection_value, String("keep-alive")):
            out.connection_close = False

    out.headers_end_off = headers_end + 4
    out.result = _RESP_PARSE_RESULT_OK
    return out^
