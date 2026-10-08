# =============================================================================
# tests/test_L2_h1_parser_coverage.mojo
# =============================================================================
#
# Every line and branch of codec/h1/parser.mojo, each with the exact outcome
# (error kind, HTTP status and byte offset; or the parsed fields), against the
# message syntax of RFC 9112 (HTTP/1.1) and the field rules of RFC 9110.
# The sibling codec tests assert the kind of most errors; these add the
# boundaries (each limit at its value and one past it), the offset each error
# names, and the arms they do not reach.
#
# The parser parses requests only: it has no status-line parser (a client's
# response head is parsed elsewhere), so RFC 9112 section 4 is not here.
#
# Byte-class predicates are checked over all 256 byte values against an
# oracle written from the RFC's ABNF in this file, not computed by the parser.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.codec import (
    HeadersParseOutcome,
    HttpMethod,
    PARSE_ERR_BODY_TOO_LARGE,
    PARSE_ERR_CONTENT_LENGTH_AND_CHUNKED,
    PARSE_ERR_CONTENT_LENGTH_CONFLICT,
    PARSE_ERR_CONTENT_LENGTH_INVALID,
    PARSE_ERR_EXPECT_UNSUPPORTED,
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
    PARSE_ERR_NEED_MORE,
    PARSE_ERR_REQUEST_LINE_MALFORMED,
    PARSE_ERR_TRANSFER_ENCODING_UNSUPPORTED,
    PARSE_ERR_URI_TOO_LONG,
    PARSE_ERR_URI_WHITESPACE,
    ParseLimits,
    build_100_continue_bytes,
    build_error_response_bytes,
    parse_request_head,
)
from komira_http_core.codec.h1.parser import (
    _find_crlf,
    _is_ows,
    _is_tchar,
    _is_vchar_or_obs_text,
    _parse_decimal,
    _parse_header_line,
    _reason_phrase,
    _static_error_body,
    _str_contains_token_ci,
    _to_lower_ascii,
)


# -----------------------------------------------------------------------------
# Helpers.
# -----------------------------------------------------------------------------


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


def _parse_bytes(buf: List[UInt8], limits: ParseLimits) -> HeadersParseOutcome:
    return parse_request_head(Span[UInt8](buf), limits)


def _parse(s: String, limits: ParseLimits) -> HeadersParseOutcome:
    var buf = _bytes(s)
    return parse_request_head(Span[UInt8](buf), limits)


def _expect_err(
    s: String, limits: ParseLimits, kind: UInt8, status: Int, offset: Int,
) raises:
    """`s` is refused with exactly this kind, status and offset."""
    var o = _parse(s, limits)
    assert_equal(Int(o.err.kind), Int(kind), String("kind for ") + repr(s))
    assert_equal(Int(o.err.status), status, String("status for ") + repr(s))
    assert_equal(o.err.offset, offset, String("offset for ") + repr(s))
    assert_equal(o.headers_end_off, -1, String("no head end for ") + repr(s))


def _ok(s: String, limits: ParseLimits) raises -> HeadersParseOutcome:
    var o = _parse(s, limits)
    assert_true(o.err.is_ok(), String("accepted: ") + repr(s))
    assert_equal(o.headers_end_off, len(s.as_bytes()), repr(s))
    return o^


def _header(o: HeadersParseOutcome, name: String) raises -> String:
    var v = o.request.headers.find(name)
    assert_true(v.__bool__(), String("header present: ") + name)
    return v.value()


def _D() -> ParseLimits:
    return ParseLimits.defaults()


comptime _RL = "GET / HTTP/1.1\r\n"
"""16 bytes: a header line that follows it starts at offset 16."""


# -----------------------------------------------------------------------------
# Byte classes (RFC 9110 section 5.6.2 tchar, 5.5 field-vchar, 5.6.3 OWS).
# -----------------------------------------------------------------------------


def test_tchar_all_bytes() raises:
    """tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." /
    "^" / "_" / "`" / "|" / "~" / DIGIT / ALPHA (RFC 9110 section 5.6.2);
    every other byte, SP, DEL, delimiters and bytes >= 0x80 included, is not."""
    var specials_str = String("!#$%&'*+-.^_`|~")
    var specials = specials_str.as_bytes()
    for c in range(256):
        var want = (
            (c >= 0x30 and c <= 0x39)
            or (c >= 0x41 and c <= 0x5A)
            or (c >= 0x61 and c <= 0x7A)
        )
        for s in specials:
            if Int(s) == c:
                want = True
        assert_equal(_is_tchar(UInt8(c)), want, String("tchar ") + String(c))


def test_field_vchar_and_ows_all_bytes() raises:
    """field-vchar = VCHAR (%x21-7E) / obs-text (%x80-FF) (RFC 9110 section
    5.5); OWS = *( SP / HTAB ) (section 5.6.3). Lowercasing touches A-Z only."""
    for c in range(256):
        var vchar = (c >= 0x21 and c <= 0x7E) or c >= 0x80
        assert_equal(_is_vchar_or_obs_text(UInt8(c)), vchar, String(c))
        assert_equal(_is_ows(UInt8(c)), c == 0x20 or c == 0x09, String(c))
        var lower = c + 32 if (c >= 0x41 and c <= 0x5A) else c
        assert_equal(Int(_to_lower_ascii(UInt8(c))), lower, String(c))


# -----------------------------------------------------------------------------
# Request line (RFC 9112 section 3).
# -----------------------------------------------------------------------------


def test_need_more_short_and_unterminated() raises:
    """A head is complete only at CRLFCRLF (RFC 9112 section 2.1); before it,
    need-more with the bytes seen so far as the offset, never an error."""
    var cases = List[String]()
    cases.append(String(""))
    cases.append(String("G"))
    cases.append(String("GE"))
    cases.append(String("GET"))
    cases.append(String("GET / HTTP/1.1\r\n\r"))
    for s in cases:
        var o = _parse(s, _D())
        assert_equal(Int(o.err.kind), Int(PARSE_ERR_NEED_MORE), repr(s))
        assert_equal(Int(o.err.status), 0, repr(s))
        var n = len(s.as_bytes())
        assert_equal(o.err.offset, 0 if n < 2 else n, repr(s))


def test_empty_request_line_refused() raises:
    """An empty line where the request-line belongs. RFC 9112 section 2.2 says
    a server SHOULD ignore at least one leading CRLF; this parser refuses it
    (400). This pins today's behaviour, a deviation from that SHOULD."""
    _expect_err("\r\n\r\n", _D(), PARSE_ERR_REQUEST_LINE_MALFORMED, 400, 0)


def test_single_token_is_http09() raises:
    """No SP at all: an HTTP/0.9 simple-request, refused (RFC 9112 section
    2.3: only HTTP/1.x is spoken here)."""
    _expect_err("GET\r\n\r\n", _D(), PARSE_ERR_HTTP_09_REJECTED, 400, 0)
    _expect_err("GET /\r\n\r\n", _D(), PARSE_ERR_HTTP_09_REJECTED, 400, 0)


def test_method_token_syntax() raises:
    """method = token (RFC 9112 section 3.1). A non-tchar byte is malformed at
    its own offset, before case is judged; methods are case-sensitive (RFC
    9110 section 9.1), so any lowercase letter is METHOD_LOWERCASE."""
    _expect_err("G@T / HTTP/1.1\r\n\r\n", _D(),
                PARSE_ERR_REQUEST_LINE_MALFORMED, 400, 1)
    _expect_err("g@T / HTTP/1.1\r\n\r\n", _D(),
                PARSE_ERR_REQUEST_LINE_MALFORMED, 400, 1)
    _expect_err("GeT / HTTP/1.1\r\n\r\n", _D(), PARSE_ERR_METHOD_LOWERCASE,
                400, 0)
    _expect_err(" / HTTP/1.1\r\n\r\n", _D(),
                PARSE_ERR_REQUEST_LINE_MALFORMED, 400, 0)
    _expect_err("BREW / HTTP/1.1\r\n\r\n", _D(), PARSE_ERR_METHOD_UNKNOWN,
                400, 0)


def test_request_target_syntax() raises:
    """request-target has no whitespace (RFC 9112 section 3.2): a HTAB is
    URI_WHITESPACE at its offset; an inner SP splits the line so the rest is
    not an HTTP-version; an empty target is malformed at the first SP."""
    _expect_err("GET /a\tb HTTP/1.1\r\n\r\n", _D(), PARSE_ERR_URI_WHITESPACE,
                400, 6)
    _expect_err("GET /a b HTTP/1.1\r\n\r\n", _D(), PARSE_ERR_HTTP_VERSION_BAD,
                400, 7)
    _expect_err("GET  HTTP/1.1\r\n\r\n", _D(),
                PARSE_ERR_REQUEST_LINE_MALFORMED, 400, 3)


def test_origin_form_query_split() raises:
    """origin-form = absolute-path [ "?" query ] (RFC 9112 section 3.2.1): the
    first "?" splits; later ones are query bytes; "?" alone gives an empty
    query."""
    var o = _ok("GET /p?a=1?b HTTP/1.1\r\n\r\n", _D())
    assert_equal(o.request.path, String("/p"))
    assert_equal(o.request.query_string, String("a=1?b"))
    assert_true(o.request.method == HttpMethod.get())
    var e = _ok("OPTIONS /? HTTP/1.1\r\n\r\n", _D())
    assert_equal(e.request.path, String("/"))
    assert_equal(e.request.query_string, String(""))
    assert_true(e.request.method == HttpMethod.options())
    var n = _ok("POST /x HTTP/1.1\r\n\r\n", _D())
    assert_equal(n.request.path, String("/x"))
    assert_equal(n.request.query_string, String(""))


def test_http_version_syntax() raises:
    """HTTP-version = "HTTP" "/" DIGIT "." DIGIT, HTTP-name case-sensitive
    (RFC 9112 section 2.3). Each malformed position is HTTP_VERSION_BAD at
    that byte; the version starts at offset 6 after "GET / "."""
    var bad = List[Tuple[String, Int]]()
    bad.append((String("HTTP/1.10"), 6))  # 9 bytes
    bad.append((String("HTTP/1"), 6))  # 6 bytes
    bad.append((String("HTTP/1.1 "), 6))  # trailing SP is part of it
    bad.append((String("XTTP/1.1"), 6))
    bad.append((String("HXTP/1.1"), 6))
    bad.append((String("HTXP/1.1"), 6))
    bad.append((String("HTTX/1.1"), 6))
    bad.append((String("HTTP-1.1"), 6))
    bad.append((String("http/1.1"), 6))
    bad.append((String("HTTP/x.1"), 11))
    bad.append((String("HTTP/1-1"), 12))
    bad.append((String("HTTP/1.x"), 13))
    for t in bad:
        _expect_err(
            String("GET / ") + t[0] + String("\r\n\r\n"), _D(),
            PARSE_ERR_HTTP_VERSION_BAD, 400, t[1],
        )


def test_http_version_unsupported() raises:
    """Only HTTP/1.0 and HTTP/1.1 (RFC 9112 section 2.3); another major is
    505 at the major digit, another minor of 1 is 505 at the minor digit
    (RFC 9110 section 15.6.6)."""
    _expect_err("GET / HTTP/0.9\r\n\r\n", _D(),
                PARSE_ERR_HTTP_VERSION_UNSUPPORTED, 505, 11)
    _expect_err("GET / HTTP/2.0\r\n\r\n", _D(),
                PARSE_ERR_HTTP_VERSION_UNSUPPORTED, 505, 11)
    _expect_err("GET / HTTP/1.2\r\n\r\n", _D(),
                PARSE_ERR_HTTP_VERSION_UNSUPPORTED, 505, 13)


def test_http_version_minor_and_persistence() raises:
    """HTTP/1.0 closes by default, HTTP/1.1 persists (RFC 9112 section 9.3)."""
    var a = _ok("GET / HTTP/1.0\r\n\r\n", _D())
    assert_equal(Int(a.http_version_minor), 0)
    assert_true(a.connection_close)
    assert_equal(a.content_length, -1)
    assert_false(a.is_chunked)
    assert_false(a.expects_continue)
    var b = _ok("GET / HTTP/1.1\r\n\r\n", _D())
    assert_equal(Int(b.http_version_minor), 1)
    assert_false(b.connection_close)


def test_request_line_limit_boundary() raises:
    """max_request_line_bytes is inclusive: a 14-byte line passes at 14 and is
    414 URI Too Long at 13 (RFC 9112 section 3, RFC 9110 section 15.5.15),
    the offset the line's CR."""
    var lim = _D()
    lim.max_request_line_bytes = 14
    _ = _ok("GET / HTTP/1.1\r\n\r\n", lim)
    lim.max_request_line_bytes = 13
    _expect_err("GET / HTTP/1.1\r\n\r\n", lim, PARSE_ERR_URI_TOO_LONG, 414, 14)


def test_total_header_window_boundary() raises:
    """max_total_header_bytes = 32: an unterminated head of 31 bytes is
    need-more, of 32 is 431 at offset 32 (RFC 6585 section 5); a head whose
    CRLFCRLF starts at offset 32 is accepted, one starting at 33 is not."""
    var lim = _D()
    lim.max_total_header_bytes = 32
    var head31 = String(_RL) + String("X-Pad: 12345678")  # 31 bytes
    var o = _parse(head31, lim)
    assert_equal(Int(o.err.kind), Int(PARSE_ERR_NEED_MORE))
    assert_equal(o.err.offset, 31)
    _expect_err(head31 + String("9"), lim, PARSE_ERR_HEADER_TOTAL_OVERFLOW,
                431, 32)
    var at32 = _ok(head31 + String("9\r\n\r\n"), lim)
    assert_equal(at32.headers_end_off, 36)
    assert_equal(_header(at32, String("x-pad")), String("123456789"))
    _expect_err(head31 + String("90\r\n\r\n"), lim,
                PARSE_ERR_HEADER_TOTAL_OVERFLOW, 431, 32)


# -----------------------------------------------------------------------------
# Header fields (RFC 9112 section 5, RFC 9110 section 5).
# -----------------------------------------------------------------------------


def test_obs_fold_refused_sp_and_htab() raises:
    """obs-fold: a server MUST reject it or replace it (RFC 9112 section 5.2);
    a line starting with SP or HTAB is OBS_FOLD at that line's start."""
    _expect_err(String(_RL) + "A: b\r\n c\r\n\r\n", _D(),
                PARSE_ERR_HEADER_OBS_FOLD, 400, 22)
    _expect_err(String(_RL) + "A: b\r\n\tc\r\n\r\n", _D(),
                PARSE_ERR_HEADER_OBS_FOLD, 400, 22)
    _expect_err(String(_RL) + "\tA: b\r\n\r\n", _D(),
                PARSE_ERR_HEADER_OBS_FOLD, 400, 16)


def test_whitespace_before_colon_refused() raises:
    """No whitespace between field-name and colon: a server MUST reject it
    with 400 (RFC 9112 section 5.1). SP and HTAB both, at their offsets."""
    _expect_err(String(_RL) + "Host : x\r\n\r\n", _D(),
                PARSE_ERR_HEADER_NAME_INVALID, 400, 20)
    _expect_err(String(_RL) + "Host\t: x\r\n\r\n", _D(),
                PARSE_ERR_HEADER_NAME_INVALID, 400, 20)


def test_field_name_token() raises:
    """field-name = token (RFC 9110 section 5.1): a non-tchar is NAME_INVALID
    at its offset, an empty name at the line start, a line with no colon
    NO_COLON. Every special tchar is a valid name and is stored lowercase."""
    _expect_err(String(_RL) + "Ho@st: x\r\n\r\n", _D(),
                PARSE_ERR_HEADER_NAME_INVALID, 400, 18)
    _expect_err(String(_RL) + ": x\r\n\r\n", _D(),
                PARSE_ERR_HEADER_NAME_INVALID, 400, 16)
    _expect_err(String(_RL) + "Host\r\n\r\n", _D(),
                PARSE_ERR_HEADER_NO_COLON, 400, 16)
    var o = _ok(String(_RL) + "!#$%&'*+-.^_`|~09AZaz: v\r\n\r\n", _D())
    assert_equal(_header(o, String("!#$%&'*+-.^_`|~09azaz")), String("v"))


def test_empty_line_helper_contract() raises:
    """_parse_header_line on an empty span (its caller treats an empty line as
    the end of the head, so it never passes one) is NO_COLON at the start."""
    var buf = _bytes(String("GET / HTTP/1.1\r\n"))
    var r = _parse_header_line(Span[UInt8](buf), 5, 5)
    assert_equal(Int(r.err.kind), Int(PARSE_ERR_HEADER_NO_COLON))
    assert_equal(r.err.offset, 5)
    var r2 = _parse_header_line(Span[UInt8](buf), 6, 5)
    assert_equal(Int(r2.err.kind), Int(PARSE_ERR_HEADER_NO_COLON))
    assert_equal(r2.err.offset, 6)


def test_find_crlf_helper_contract() raises:
    """_find_crlf gives the CR of the first CRLF at or after `start`, and -1
    when there is none (a lone CR, a lone LF, LF before CR); its caller only
    asks after a CRLFCRLF was found, so the -1 is reached here alone."""
    var buf = _bytes(String("a\rb\n\n\rc\r\nd\r\n"))
    var sp = Span[UInt8](buf)
    assert_equal(_find_crlf(sp, 0), 7)
    assert_equal(_find_crlf(sp, 8), 10)
    assert_equal(_find_crlf(sp, 11), -1)
    var none = _bytes(String("a\rb\n\n\r"))
    assert_equal(_find_crlf(Span[UInt8](none), 0), -1)


def test_field_value_ows_and_content() raises:
    """field-value excludes leading and trailing OWS (RFC 9112 section 5.1);
    inner SP/HTAB stay; an all-OWS or empty value is empty (RFC 9110 section
    5.5 allows an empty value)."""
    var o = _ok(
        String(_RL)
        + "A:\t a\tb c \t\r\nB: \t \r\nC:\r\nD:x\r\n\r\n",
        _D(),
    )
    assert_equal(_header(o, String("a")), String("a\tb c"))
    assert_equal(_header(o, String("b")), String(""))
    assert_equal(_header(o, String("c")), String(""))
    assert_equal(_header(o, String("d")), String("x"))


def test_field_value_ctl_and_del_refused() raises:
    """CTLs and DEL are not field-vchar (RFC 9110 section 5.5): refused at
    their offset. obs-text (0x80-0xFF) is accepted."""
    _expect_err(String(_RL) + "X: a" + chr(0x7F) + "b\r\n\r\n", _D(),
                PARSE_ERR_HEADER_VALUE_CONTROL_CHAR, 400, 20)
    _expect_err(String(_RL) + "X: a" + chr(0x01) + "\r\n\r\n", _D(),
                PARSE_ERR_HEADER_VALUE_CONTROL_CHAR, 400, 20)
    var buf = _bytes(String(_RL) + "X: a")
    buf.append(UInt8(0x80))
    buf.append(UInt8(0xFF))
    var tail = _bytes(String("\r\n\r\n"))
    for b in tail:
        buf.append(b)
    var o = _parse_bytes(buf, _D())
    assert_true(o.err.is_ok())
    assert_equal(o.headers_end_off, len(buf))
    assert_true(o.request.headers.find(String("x")).__bool__())


def test_header_line_size_boundary() raises:
    """max_header_bytes is inclusive (the line without its CRLF): "X: abc" is
    6 bytes, accepted at 6, 431 at 5 with the line's start as the offset."""
    var lim = _D()
    lim.max_header_bytes = 6
    _ = _ok(String(_RL) + "X: abc\r\n\r\n", lim)
    lim.max_header_bytes = 5
    _expect_err(String(_RL) + "X: abc\r\n\r\n", lim,
                PARSE_ERR_HEADER_SIZE_OVERFLOW, 431, 16)


def test_header_count_boundary() raises:
    """max_headers is inclusive: 2 lines pass at 2; a third is 431 at its
    own start (RFC 6585 section 5)."""
    var lim = _D()
    lim.max_headers = 2
    _ = _ok(String(_RL) + "A: 1\r\nB: 2\r\n\r\n", lim)
    _expect_err(String(_RL) + "A: 1\r\nB: 2\r\nC: 3\r\n\r\n", lim,
                PARSE_ERR_HEADER_COUNT_OVERFLOW, 431, 28)


def test_repeated_field_combined() raises:
    """Repeated field lines combine in order with ", " (RFC 9110 section
    5.3), names matched case-insensitively."""
    var o = _ok(String(_RL) + "A: 1\r\na: 2\r\nA: 3\r\n\r\n", _D())
    assert_equal(_header(o, String("a")), String("1, 2, 3"))


# -----------------------------------------------------------------------------
# Message body length (RFC 9112 section 6).
# -----------------------------------------------------------------------------


def test_content_length_syntax() raises:
    """Content-Length = 1*DIGIT (RFC 9110 section 8.6). An empty value, a
    sign, or a list is invalid: 400 (RFC 9112 section 6.3 item 5), offset the
    request line's CR (14)."""
    var bad = List[String]()
    bad.append(String(""))
    bad.append(String("+5"))
    bad.append(String("5, 5"))
    bad.append(String("0x5"))
    for v in bad:
        _expect_err(
            String(_RL) + "Content-Length: " + v + "\r\n\r\n", _D(),
            PARSE_ERR_CONTENT_LENGTH_INVALID, 400, 14,
        )
    var o = _ok(String(_RL) + "content-LENGTH: 007\r\n\r\n", _D())
    assert_equal(o.content_length, 7)
    assert_false(o.is_chunked)
    # A field name of the same length that is not Content-Length frames
    # nothing: the name must match whole (RFC 9110 section 5.1).
    var near = _ok(String(_RL) + "Content-Lengtx: 7\r\n\r\n", _D())
    assert_equal(near.content_length, -1)
    assert_equal(_header(near, String("content-lengtx")), String("7"))


def test_parse_decimal_bounds() raises:
    """The ceiling 2^62 is accepted; 2^62 + 1 and anything that would pass it
    before the multiply are refused; empty and non-digits are refused."""
    assert_equal(_parse_decimal(String("")), -1)
    assert_equal(_parse_decimal(String("1a")), -1)
    assert_equal(_parse_decimal(String("0")), 0)
    assert_equal(_parse_decimal(String("4611686018427387904")), 1 << 62)
    assert_equal(_parse_decimal(String("4611686018427387905")), -1)
    assert_equal(_parse_decimal(String("46116860184273879040")), -1)


def test_content_length_repeated_refused() raises:
    """Two Content-Length lines, equal or not, are refused as a conflict:
    RFC 9110 section 8.6 lets a recipient reject repeated identical values or
    collapse them, and this parser rejects (RFC 9112 section 6.3 item 5). An
    invalid value wins over a conflict."""
    _expect_err(String(_RL) + "Content-Length: 5\r\nContent-Length: 5\r\n\r\n",
                _D(), PARSE_ERR_CONTENT_LENGTH_CONFLICT, 400, 14)
    _expect_err(String(_RL) + "Content-Length: 5\r\nContent-Length: 6\r\n\r\n",
                _D(), PARSE_ERR_CONTENT_LENGTH_CONFLICT, 400, 14)
    _expect_err(
        String(_RL)
        + "Content-Length: 5\r\nContent-Length: 6\r\nContent-Length: x\r\n\r\n",
        _D(), PARSE_ERR_CONTENT_LENGTH_INVALID, 400, 14,
    )


def test_content_length_with_chunked_refused() raises:
    """Transfer-Encoding and Content-Length together: the server MAY reject
    (RFC 9112 section 6.3 item 3), and this one does, whichever comes first."""
    _expect_err(
        String(_RL) + "Content-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n",
        _D(), PARSE_ERR_CONTENT_LENGTH_AND_CHUNKED, 400, 14,
    )
    _expect_err(
        String(_RL) + "Transfer-Encoding: chunked\r\nContent-Length: 3\r\n\r\n",
        _D(), PARSE_ERR_CONTENT_LENGTH_AND_CHUNKED, 400, 14,
    )


def test_transfer_encoding_codings() raises:
    """chunked, matched case-insensitively (RFC 9112 section 7), is framing;
    a coding list without chunked, over one or several lines, is refused."""
    var o = _ok(String(_RL) + "Transfer-Encoding: Chunked\r\n\r\n", _D())
    assert_true(o.is_chunked)
    assert_equal(o.content_length, -1)
    _expect_err(
        String(_RL) + "Transfer-Encoding: gzip\r\nTransfer-Encoding: br\r\n\r\n",
        _D(), PARSE_ERR_TRANSFER_ENCODING_UNSUPPORTED, 400, 14,
    )
    _expect_err(String(_RL) + "Transfer-Encoding: chunkedx\r\n\r\n", _D(),
                PARSE_ERR_TRANSFER_ENCODING_UNSUPPORTED, 400, 14)
    # An unsupported coding is judged before the Content-Length checks.
    _expect_err(
        String(_RL) + "Content-Length: x\r\nTransfer-Encoding: gzip\r\n\r\n",
        _D(), PARSE_ERR_TRANSFER_ENCODING_UNSUPPORTED, 400, 14,
    )


def test_body_limit_boundary() raises:
    """max_body_bytes is inclusive: Content-Length 10 passes at 10, is 413 at
    9 (RFC 9110 section 15.5.14)."""
    var lim = _D()
    lim.max_body_bytes = 10
    var o = _ok(String(_RL) + "Content-Length: 10\r\n\r\n", lim)
    assert_equal(o.content_length, 10)
    lim.max_body_bytes = 9
    _expect_err(String(_RL) + "Content-Length: 10\r\n\r\n", lim,
                PARSE_ERR_BODY_TOO_LARGE, 413, 14)


# -----------------------------------------------------------------------------
# Expect (RFC 9110 section 10.1.1) and Connection (RFC 9112 section 9.3).
# -----------------------------------------------------------------------------


def test_expect() raises:
    """100-continue (case-insensitive) is the only expectation; anything else,
    alone or with it, is 417. An empty Expect is no expectation."""
    var o = _ok(String(_RL) + "Expect: 100-Continue\r\n\r\n", _D())
    assert_true(o.expects_continue)
    var e = _ok(String(_RL) + "Expect:\r\n\r\n", _D())
    assert_false(e.expects_continue)
    _expect_err(String(_RL) + "Expect: 100-continue\r\nExpect: x\r\n\r\n",
                _D(), PARSE_ERR_EXPECT_UNSUPPORTED, 417, 14)
    _expect_err(String(_RL) + "Expect: x\r\nExpect: 100-continue\r\n\r\n",
                _D(), PARSE_ERR_EXPECT_UNSUPPORTED, 417, 14)


def test_connection_options() raises:
    """connection-option tokens, comma-separated with OWS, case-insensitive
    (RFC 9110 section 7.6.1): close wins over keep-alive; keep-alive keeps an
    HTTP/1.0 connection; other tokens change nothing; "closed" is not close."""
    var cases = List[Tuple[String, String, Bool]]()
    cases.append((String("1.1"), String("Connection: keep-alive, CLOSE"), True))
    cases.append((String("1.1"), String("Connection: x,close"), True))
    cases.append((String("1.1"), String("Connection: close\t,x"), True))
    cases.append((String("1.1"), String("Connection: close ,x"), True))
    cases.append((String("1.1"), String("Connection: up\r\nConnection: close"),
                  True))
    cases.append((String("1.1"), String("Connection: close\r\nConnection: up"),
                  True))
    cases.append((String("1.1"), String("Connection: closed, cl"), False))
    cases.append((String("1.1"), String("Connection: upgrade"), False))
    cases.append((String("1.1"), String("Connection: upgrade,"), False))
    cases.append((String("1.0"), String("Connection: upgrade"), True))
    cases.append((String("1.0"), String("Connection: Keep-Alive"), False))
    cases.append((String("1.0"), String("Connection:"), True))
    for t in cases:
        var s = (
            String("GET / HTTP/") + t[0] + "\r\n" + t[1] + String("\r\n\r\n")
        )
        var o = _ok(s, _D())
        assert_equal(o.connection_close, t[2], repr(s))


def test_token_list_matcher() raises:
    """The comma-list token matcher: an empty needle matches nothing; a token
    must match whole, at the end or before SP, HTAB or comma."""
    assert_false(_str_contains_token_ci(String("close"), String("")))
    assert_true(_str_contains_token_ci(String(" ,\tClose"), String("close")))
    assert_false(_str_contains_token_ci(String("clos"), String("close")))
    assert_false(_str_contains_token_ci(String("closex,y"), String("close")))
    assert_true(_str_contains_token_ci(String("a, b,close"), String("close")))
    assert_false(_str_contains_token_ci(String("x, ,"), String("close")))


# -----------------------------------------------------------------------------
# Static responses (RFC 9112 section 4 status-line, RFC 9110 section 15).
# -----------------------------------------------------------------------------


def _str_of(b: List[UInt8]) -> String:
    var s = String()
    for x in b:
        s = s + chr(Int(x))
    return s^


def test_error_responses_exact_bytes() raises:
    """Each status serializes to exactly its status-line, the three headers,
    and the static body, with a Content-Length equal to the body; the buffer
    is cleared first. An unlisted status gets "Error"."""
    var rows = List[Tuple[Int, String]]()
    rows.append((400, String("Bad Request")))
    rows.append((413, String("Payload Too Large")))
    rows.append((414, String("URI Too Long")))
    rows.append((417, String("Expectation Failed")))
    rows.append((431, String("Request Header Fields Too Large")))
    rows.append((500, String("Internal Server Error")))
    rows.append((505, String("HTTP Version Not Supported")))
    rows.append((418, String("Error")))
    for r in rows:
        var out = _bytes(String("stale"))
        build_error_response_bytes(UInt16(r[0]), out)
        var body = r[1] + "\n"
        var want = (
            String("HTTP/1.1 ") + String(r[0]) + " " + r[1] + "\r\n"
            + "Content-Type: text/plain; charset=us-ascii\r\n"
            + "Content-Length: " + String(len(body.as_bytes())) + "\r\n"
            + "Connection: close\r\n\r\n" + body
        )
        assert_equal(_str_of(out), want)
        assert_equal(_static_error_body(UInt16(r[0])), body)


def test_reason_phrases_interim_and_ok() raises:
    """The 1xx and 2xx reason phrases (RFC 9110 sections 15.2.1, 15.3.1); the
    error body for them is the generic one."""
    assert_equal(_reason_phrase(UInt16(100)), String("Continue"))
    assert_equal(_reason_phrase(UInt16(200)), String("OK"))
    assert_equal(_reason_phrase(UInt16(299)), String("Error"))
    assert_equal(_static_error_body(UInt16(200)), String("Error\n"))


def test_100_continue_exact_bytes() raises:
    """The interim response is exactly "HTTP/1.1 100 Continue" CRLF CRLF (RFC
    9110 section 15.2.1), written over what the buffer held."""
    var out = _bytes(String("stale bytes"))
    build_100_continue_bytes(out)
    assert_equal(_str_of(out), String("HTTP/1.1 100 Continue\r\n\r\n"))


def main() raises:
    test_tchar_all_bytes()
    test_field_vchar_and_ows_all_bytes()
    test_need_more_short_and_unterminated()
    test_empty_request_line_refused()
    test_single_token_is_http09()
    test_method_token_syntax()
    test_request_target_syntax()
    test_origin_form_query_split()
    test_http_version_syntax()
    test_http_version_unsupported()
    test_http_version_minor_and_persistence()
    test_request_line_limit_boundary()
    test_total_header_window_boundary()
    test_obs_fold_refused_sp_and_htab()
    test_whitespace_before_colon_refused()
    test_field_name_token()
    test_empty_line_helper_contract()
    test_find_crlf_helper_contract()
    test_field_value_ows_and_content()
    test_field_value_ctl_and_del_refused()
    test_header_line_size_boundary()
    test_header_count_boundary()
    test_repeated_field_combined()
    test_content_length_syntax()
    test_parse_decimal_bounds()
    test_content_length_repeated_refused()
    test_content_length_with_chunked_refused()
    test_transfer_encoding_codings()
    test_body_limit_boundary()
    test_expect()
    test_connection_options()
    test_token_list_matcher()
    test_error_responses_exact_bytes()
    test_reason_phrases_interim_and_ok()
    test_100_continue_exact_bytes()
    print("PASS L2 h1 parser coverage")
