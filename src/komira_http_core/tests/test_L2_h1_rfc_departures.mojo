# =============================================================================
# tests/test_L2_h1_rfc_departures.mojo
# =============================================================================
#
# The h1 request parser against five RFC rules it used to break, one test per
# rule:
#
#   * RFC 9112 section 2.2: a server SHOULD ignore at least one empty line
#     before the request-line (it was refused with 400).
#   * RFC 9110 section 6.2: a higher minor version of HTTP/1 is treated as
#     HTTP/1.1 (it was refused with 505).
#   * RFC 9110 section 9.1: an unrecognized method SHOULD get 501 (it got 400).
#   * RFC 9110 section 10.1.1: a server MUST ignore Expect: 100-continue in an
#     HTTP/1.0 request (it reported the expectation, so the server sent 100).
#   * RFC 9110 section 5.5: obs-text is opaque data (each byte was re-encoded
#     as the UTF-8 of the code point with that number). A value that is
#     well-formed UTF-8 is now kept as the octets sent. One that is not cannot
#     be held in the String header map unchanged; it is still served, with
#     each octet re-encoded as before, never refused. The well-formed set is
#     the Unicode Standard's Table 3-7, and each bound of each row has a case
#     on both sides.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_http_core.codec import (
    HeadersParseOutcome,
    HttpMethod,
    PARSE_ERR_EXPECT_UNSUPPORTED,
    PARSE_ERR_HEADER_TOTAL_OVERFLOW,
    PARSE_ERR_HTTP_VERSION_BAD,
    PARSE_ERR_METHOD_LOWERCASE,
    PARSE_ERR_METHOD_UNKNOWN,
    PARSE_ERR_REQUEST_LINE_MALFORMED,
    ParseLimits,
    build_error_response_bytes,
    parse_request_head,
)
from komira_http_core.codec.h1.utf8 import utf8_error_offset


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _parse(buf: List[UInt8], limits: ParseLimits) -> HeadersParseOutcome:
    return parse_request_head(Span[UInt8](buf), limits)


def _hex(b: List[UInt8]) -> String:
    var digits = String("0123456789ABCDEF").as_bytes()
    var out = String()
    for x in b:
        out += chr(Int(digits[Int(x) >> 4])) + chr(Int(digits[Int(x) & 15]))
        out += " "
    return out^


# -----------------------------------------------------------------------------
# RFC 9112 section 2.2: empty lines before the request-line.
# -----------------------------------------------------------------------------


def test_leading_empty_lines_are_ignored() raises:
    """One or several CRLFs before the request-line are skipped; the head ends
    at the same terminator, offsets stay absolute in the buffer, and the
    request-line limit is measured from the line itself."""
    for k in range(1, 4):
        var pre = String()
        for _ in range(k):
            pre += "\r\n"
        var s = pre + "GET /a HTTP/1.1\r\nHost: h\r\n\r\n"
        var o = _parse(_bytes(s), ParseLimits.defaults())
        assert_true(o.err.is_ok(), repr(s))
        assert_equal(o.headers_end_off, s.byte_length())
        assert_true(o.request.method == HttpMethod.get())
        assert_equal(o.request.path, String("/a"))
        assert_equal(o.request.headers[String("host")], String("h"))
    # The CRLF a client may send after a request body, then the next request.
    var nxt = _parse(_bytes("\r\nPOST /b HTTP/1.1\r\n\r\n"), ParseLimits.defaults())
    assert_true(nxt.err.is_ok())
    assert_true(nxt.request.method == HttpMethod.post())
    # An error on the request-line names its offset in the whole buffer.
    var bad = _parse(_bytes("\r\nG@T / HTTP/1.1\r\n\r\n"), ParseLimits.defaults())
    assert_equal(Int(bad.err.kind), Int(PARSE_ERR_REQUEST_LINE_MALFORMED))
    assert_equal(bad.err.offset, 3)
    # "GET / HTTP/1.1" is 14 bytes: within a 14-byte limit after 2 CRLFs.
    var lim = ParseLimits.defaults()
    lim.max_request_line_bytes = 14
    var at = _parse(_bytes("\r\n\r\nGET / HTTP/1.1\r\n\r\n"), lim)
    assert_true(at.err.is_ok())


def test_leading_empty_lines_count_against_the_header_window() raises:
    """Skipped CRLFs are bytes of the head: 10 CRLFs (20 bytes) fill a
    20-byte window, so a request after them is 431, not parsed."""
    var lim = ParseLimits.defaults()
    lim.max_total_header_bytes = 20
    var s = String()
    for _ in range(10):
        s += "\r\n"
    s += "GET / HTTP/1.1\r\n\r\n"
    var o = _parse(_bytes(s), lim)
    assert_equal(Int(o.err.kind), Int(PARSE_ERR_HEADER_TOTAL_OVERFLOW))
    assert_equal(Int(o.err.status), 431)


def test_bare_cr_before_request_line_is_not_skipped() raises:
    """Only CR followed by LF is an empty line: a CR followed by anything else
    is the first byte of the request-line, which is then malformed (400 at 0).
    Skipping a CR and the byte after it would turn "\rXGET" into GET."""
    var cases = List[String]()
    cases.append(String("\rGET / HTTP/1.1\r\n\r\n"))
    cases.append(String("\rXGET / HTTP/1.1\r\n\r\n"))
    cases.append(String("\r\n\rXGET / HTTP/1.1\r\n\r\n"))
    var at = List[Int]()
    at.append(0)
    at.append(0)
    at.append(2)
    for i in range(len(cases)):
        var o = _parse(_bytes(cases[i]), ParseLimits.defaults())
        assert_equal(
            Int(o.err.kind), Int(PARSE_ERR_REQUEST_LINE_MALFORMED), repr(cases[i])
        )
        assert_equal(Int(o.err.status), 400, repr(cases[i]))
        assert_equal(o.err.offset, at[i], repr(cases[i]))


# -----------------------------------------------------------------------------
# RFC 9110 section 6.2: a higher HTTP/1 minor version.
# -----------------------------------------------------------------------------


def test_higher_http1_minor_is_http11() raises:
    """HTTP/1.2 and HTTP/1.9 are parsed as HTTP/1.1: minor 1, persistent."""
    for m in range(2, 10):
        var s = String("GET / HTTP/1.") + String(m) + "\r\n\r\n"
        var o = _parse(_bytes(s), ParseLimits.defaults())
        assert_true(o.err.is_ok(), repr(s))
        assert_equal(Int(o.http_version_minor), 1, repr(s))
        assert_false(o.connection_close, repr(s))


# -----------------------------------------------------------------------------
# RFC 9110 section 9.1: an unrecognized method is 501.
# -----------------------------------------------------------------------------


def test_unrecognized_method_is_501() raises:
    """A method this parser does not know is 501 Not Implemented, a lowercase
    spelling of a known one included (methods are case-sensitive); the error
    response says so."""
    var methods = List[String]()
    methods.append(String("BREW"))
    methods.append(String("CONNECT"))
    methods.append(String("TRACE"))
    for m in methods:
        var o = _parse(_bytes(m + " / HTTP/1.1\r\n\r\n"), ParseLimits.defaults())
        assert_equal(Int(o.err.kind), Int(PARSE_ERR_METHOD_UNKNOWN), m)
        assert_equal(Int(o.err.status), 501, m)
    var low = _parse(_bytes("get / HTTP/1.1\r\n\r\n"), ParseLimits.defaults())
    assert_equal(Int(low.err.kind), Int(PARSE_ERR_METHOD_LOWERCASE))
    assert_equal(Int(low.err.status), 501)
    # A malformed line is 400 whatever its method: "NOT HTTP" is no version.
    var junk = _parse(_bytes("THIS IS NOT HTTP\r\n\r\n"), ParseLimits.defaults())
    assert_equal(Int(junk.err.kind), Int(PARSE_ERR_HTTP_VERSION_BAD))
    assert_equal(Int(junk.err.status), 400)
    var out = List[UInt8]()
    build_error_response_bytes(UInt16(501), out)
    var want = _bytes(
        "HTTP/1.1 501 Not Implemented\r\n"
        "Content-Type: text/plain; charset=us-ascii\r\n"
        "Content-Length: 16\r\nConnection: close\r\n\r\nNot Implemented\n"
    )
    assert_equal(_hex(out), _hex(want))


# -----------------------------------------------------------------------------
# RFC 9110 section 10.1.1: Expect: 100-continue on HTTP/1.0.
# -----------------------------------------------------------------------------


def test_expect_continue_ignored_on_http10() raises:
    """An HTTP/1.0 request's 100-continue is not reported (so no 100 is sent);
    the same request as HTTP/1.1 is. Any other expectation is still 417."""
    var head = String(" / HTTP/1.")
    var tail = String("\r\nExpect: 100-continue\r\nContent-Length: 1\r\n\r\n")
    var v10 = _parse(_bytes(String("POST") + head + "0" + tail), ParseLimits.defaults())
    assert_true(v10.err.is_ok())
    assert_false(v10.expects_continue)
    var v11 = _parse(_bytes(String("POST") + head + "1" + tail), ParseLimits.defaults())
    assert_true(v11.err.is_ok())
    assert_true(v11.expects_continue)
    var other = _parse(
        _bytes("POST / HTTP/1.0\r\nExpect: x\r\n\r\n"), ParseLimits.defaults()
    )
    assert_equal(Int(other.err.kind), Int(PARSE_ERR_EXPECT_UNSUPPORTED))


# -----------------------------------------------------------------------------
# RFC 9110 section 5.5: obs-text kept as sent when it is well-formed UTF-8.
# -----------------------------------------------------------------------------


def _value_with(seq: List[UInt8]) -> List[UInt8]:
    """`GET / HTTP/1.1` CRLF `X: a<seq>z` CRLF CRLF; `seq` starts at 20."""
    var buf = _bytes("GET / HTTP/1.1\r\nX: a")
    for b in seq:
        buf.append(b)
    var end = _bytes("z\r\n\r\n")
    for b in end:
        buf.append(b)
    return buf^


def _seq(a: Int, b: Int = -1, c: Int = -1, d: Int = -1) -> List[UInt8]:
    var out = List[UInt8]()
    out.append(UInt8(a))
    if b >= 0:
        out.append(UInt8(b))
    if c >= 0:
        out.append(UInt8(c))
    if d >= 0:
        out.append(UInt8(d))
    return out^


def _per_octet(b: List[UInt8]) -> List[UInt8]:
    """The UTF-8 of `b` with each octet taken as the code point of the same
    number: what a value that is not well-formed UTF-8 is stored as."""
    var s = String()
    for x in b:
        s += chr(Int(x))
    return _bytes(s)


def test_obs_text_kept_as_sent() raises:
    """Every well-formed sequence at the edges of each Table 3-7 row is kept
    byte for byte; every sequence one step outside an edge is served, not
    refused, with each octet re-encoded. The two stored forms differ for every
    case, so a wrong bound in the check shows. Each failing case is named,
    not only the first."""
    var good = List[List[UInt8]]()
    good.append(_seq(0xC2, 0x80))
    good.append(_seq(0xDF, 0xBF))
    good.append(_seq(0xE0, 0xA0, 0x80))
    good.append(_seq(0xE0, 0xBF, 0xBF))
    good.append(_seq(0xE1, 0x80, 0x80))
    good.append(_seq(0xEC, 0xBF, 0xBF))
    good.append(_seq(0xED, 0x80, 0x80))
    good.append(_seq(0xED, 0x9F, 0xBF))
    good.append(_seq(0xEE, 0x80, 0x80))
    good.append(_seq(0xEF, 0xBF, 0xBF))
    good.append(_seq(0xF0, 0x90, 0x80, 0x80))
    good.append(_seq(0xF0, 0xBF, 0xBF, 0xBF))
    good.append(_seq(0xF1, 0x80, 0x80, 0x80))
    good.append(_seq(0xF3, 0xBF, 0xBF, 0xBF))
    good.append(_seq(0xF4, 0x80, 0x80, 0x80))
    good.append(_seq(0xF4, 0x8F, 0xBF, 0xBF))
    var bad = List[List[UInt8]]()
    bad.append(_seq(0x80))  # a continuation byte with no lead
    bad.append(_seq(0xBF))
    bad.append(_seq(0xC0, 0x80))  # overlong leads
    bad.append(_seq(0xC1, 0xBF))
    bad.append(_seq(0xF5, 0x80, 0x80, 0x80))  # past U+10FFFF
    bad.append(_seq(0xFF))
    bad.append(_seq(0xC2, 0x41))  # second byte below 80
    bad.append(_seq(0xDF, 0xC0))  # second byte above BF
    bad.append(_seq(0xE0, 0x9F, 0xBF))  # E0 floor A0
    bad.append(_seq(0xE0, 0xC0, 0x80))
    bad.append(_seq(0xE1, 0x7E, 0x80))
    bad.append(_seq(0xEC, 0xC0, 0x80))
    bad.append(_seq(0xE1, 0x80, 0x41))  # third byte below 80
    bad.append(_seq(0xEF, 0xBF, 0xC0))  # third byte above BF
    bad.append(_seq(0xED, 0xA0, 0x80))  # ED ceiling 9F (surrogates)
    bad.append(_seq(0xED, 0x7E, 0x80))
    bad.append(_seq(0xEE, 0x7E, 0x80))
    bad.append(_seq(0xF0, 0x8F, 0xBF, 0xBF))  # F0 floor 90
    bad.append(_seq(0xF0, 0xC0, 0x80, 0x80))
    bad.append(_seq(0xF1, 0x7E, 0x80, 0x80))
    bad.append(_seq(0xF3, 0xC0, 0x80, 0x80))
    bad.append(_seq(0xF1, 0x80, 0x41, 0x80))  # third byte
    bad.append(_seq(0xF1, 0x80, 0xC0, 0x80))
    bad.append(_seq(0xF1, 0x80, 0x80, 0x41))  # fourth byte
    bad.append(_seq(0xF3, 0x80, 0x80, 0xC0))
    bad.append(_seq(0xF4, 0x90, 0x80, 0x80))  # F4 ceiling 8F
    bad.append(_seq(0xF4, 0x7E, 0x80, 0x80))
    var failed = List[String]()
    for g in good:
        var o = _parse(_value_with(g), ParseLimits.defaults())
        var want = _bytes("a")
        for b in g:
            want.append(b)
        want.append(UInt8(ord("z")))
        if not o.err.is_ok():
            failed.append(String("refused ") + _hex(g))
            continue
        var v = o.request.headers[String("x")]
        var got = _bytes(v)
        if _hex(got) != _hex(want):
            failed.append(String("kept ") + _hex(g) + "as " + _hex(got))
    for x in bad:
        var o = _parse(_value_with(x), ParseLimits.defaults())
        var raw = _bytes("a")
        for b in x:
            raw.append(b)
        raw.append(UInt8(ord("z")))
        if not o.err.is_ok():
            failed.append(
                String("refused ") + _hex(x) + "kind "
                + String(Int(o.err.kind)) + " offset " + String(o.err.offset)
            )
            continue
        var got = _bytes(o.request.headers[String("x")])
        if _hex(got) != _hex(_per_octet(raw)):
            failed.append(String("ill-formed ") + _hex(x) + "as " + _hex(got))
    # A sequence cut short by the value's end: by the CR, and by trailing OWS.
    var cut = List[List[UInt8]]()
    cut.append(_seq(0xC2))
    cut.append(_seq(0xE1, 0x80))
    cut.append(_seq(0xF1, 0x80, 0x80))
    var ows_end = _bytes(" \r\n\r\n")
    for s in cut:
        var buf = _bytes("GET / HTTP/1.1\r\nX: a")
        for b in s:
            buf.append(b)
        for b in ows_end:
            buf.append(b)
        var o = _parse(buf, ParseLimits.defaults())
        var raw = _bytes("a")
        for b in s:
            raw.append(b)
        if not o.err.is_ok():
            failed.append(String("truncated refused: ") + _hex(s))
            continue
        var got = _bytes(o.request.headers[String("x")])
        if _hex(got) != _hex(_per_octet(raw)):
            failed.append(String("truncated ") + _hex(s) + "as " + _hex(got))
    for f in failed:
        print("FAIL", f)
    assert_equal(len(failed), 0)


def test_utf8_range_end_is_not_read_past() raises:
    """The check reads nothing at or past the range end: C2 then 80 is
    well-formed, but the range [0, 1) holds only C2 and is ill-formed at 0."""
    var buf = _seq(0xC2, 0x80)
    assert_equal(utf8_error_offset(Span[UInt8](buf), 0, 2), -1)
    assert_equal(utf8_error_offset(Span[UInt8](buf), 0, 1), 0)
    var three = _seq(0x41, 0xE1, 0x80, 0x80)
    assert_equal(utf8_error_offset(Span[UInt8](three), 0, 4), -1)
    assert_equal(utf8_error_offset(Span[UInt8](three), 0, 3), 1)
    var four = _seq(0xF1, 0x80, 0x80, 0x80)
    assert_equal(utf8_error_offset(Span[UInt8](four), 0, 3), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
