# =============================================================================
# tests/test_L2_codec_request_line.mojo
# =============================================================================
#
# request-line parser unit tests
#
# Covers RFC 7230 §3.1.1 request-line parsing:
#   * Happy path  — GET / HTTP/1.1 ; method+path+version round-trip
#   * Method-name case sensitivity (lowercase rejected)
#   * Unknown methods rejected
#   * URI with query string (split on '?')
#   * URI with whitespace rejected
#   * HTTP/0.9 simple requests rejected
#   * HTTP/2.0 / HTTP/3.0 rejected (505)
#   * Malformed version strings rejected
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.codec import (
    HTTP_METHOD_GET,
    HTTP_METHOD_POST,
    PARSE_ERR_HTTP_09_REJECTED,
    PARSE_ERR_HTTP_VERSION_BAD,
    PARSE_ERR_HTTP_VERSION_UNSUPPORTED,
    PARSE_ERR_METHOD_LOWERCASE,
    PARSE_ERR_METHOD_UNKNOWN,
    PARSE_ERR_NONE,
    PARSE_ERR_REQUEST_LINE_MALFORMED,
    PARSE_ERR_URI_WHITESPACE,
    ParseLimits,
    parse_request_head,
)


def _bytes(s: String) -> List[UInt8]:
    """Helper: copy a String into a List[UInt8]."""
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        out.append(bytes_ref[i])
        i = i + 1
    return out^


def test_request_line_happy_get() raises:
    """Vanilla GET / HTTP/1.1\\r\\n\\r\\n parses cleanly."""
    var buf = _bytes(String("GET / HTTP/1.1\r\n\r\n"))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_ok())
    assert_equal(Int(outcome.request.method.code), Int(HTTP_METHOD_GET))
    assert_equal(outcome.request.path, String("/"))
    assert_equal(outcome.request.query_string, String(""))
    assert_equal(Int(outcome.http_version_minor), 1)
    assert_false(outcome.is_chunked)
    assert_equal(outcome.content_length, -1)
    assert_false(outcome.expects_continue)


def test_request_line_post_with_path() raises:
    """POST /api/v1/users HTTP/1.1 parses; query-string is empty."""
    var buf = _bytes(String("POST /api/v1/users HTTP/1.1\r\n\r\n"))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_ok())
    assert_equal(Int(outcome.request.method.code), Int(HTTP_METHOD_POST))
    assert_equal(outcome.request.path, String("/api/v1/users"))
    assert_equal(outcome.request.query_string, String(""))


def test_request_line_query_string_split() raises:
    """GET /search?q=foo&n=10 — path / query split on first '?'."""
    var buf = _bytes(String("GET /search?q=foo&n=10 HTTP/1.1\r\n\r\n"))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_ok())
    assert_equal(outcome.request.path, String("/search"))
    assert_equal(outcome.request.query_string, String("q=foo&n=10"))


def test_request_line_http_10_keep_alive() raises:
    """HTTP/1.0 by default closes connection unless Connection: keep-alive."""
    var buf = _bytes(String("GET / HTTP/1.0\r\n\r\n"))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_ok())
    assert_equal(Int(outcome.http_version_minor), 0)
    assert_true(outcome.connection_close)


def test_request_line_http_10_with_keepalive() raises:
    """HTTP/1.0 + Connection: keep-alive → keep-alive."""
    var buf = _bytes(String(
        "GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_ok())
    assert_false(outcome.connection_close)


def test_request_line_lowercase_method_rejected() raises:
    """get / HTTP/1.1 → 501 / PARSE_ERR_METHOD_LOWERCASE."""
    var buf = _bytes(String("get / HTTP/1.1\r\n\r\n"))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_false(outcome.err.is_ok())
    assert_equal(Int(outcome.err.kind), Int(PARSE_ERR_METHOD_LOWERCASE))
    assert_equal(Int(outcome.err.status), 501)


def test_request_line_unknown_method() raises:
    """FOOBAR / HTTP/1.1 → 501 / PARSE_ERR_METHOD_UNKNOWN."""
    var buf = _bytes(String("FOOBAR / HTTP/1.1\r\n\r\n"))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_false(outcome.err.is_ok())
    assert_equal(Int(outcome.err.kind), Int(PARSE_ERR_METHOD_UNKNOWN))
    assert_equal(Int(outcome.err.status), 501)


def test_request_line_uri_whitespace_rejected() raises:
    """GET /foo\\tbar HTTP/1.1 — embedded TAB inside URI → 400."""
    var buf = _bytes(String("GET /foo\tbar HTTP/1.1\r\n\r\n"))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_false(outcome.err.is_ok())
    assert_equal(Int(outcome.err.kind), Int(PARSE_ERR_URI_WHITESPACE))


def test_request_line_http_09_rejected() raises:
    """Simple request 'GET /\\r\\n\\r\\n' (no version) → 400."""
    var buf = _bytes(String("GET /\r\n\r\n"))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_false(outcome.err.is_ok())
    assert_equal(Int(outcome.err.kind), Int(PARSE_ERR_HTTP_09_REJECTED))
    assert_equal(Int(outcome.err.status), 400)


def test_request_line_http_2_unsupported() raises:
    """HTTP/2.0 → 505 / PARSE_ERR_HTTP_VERSION_UNSUPPORTED."""
    var buf = _bytes(String("GET / HTTP/2.0\r\n\r\n"))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_false(outcome.err.is_ok())
    assert_equal(
        Int(outcome.err.kind), Int(PARSE_ERR_HTTP_VERSION_UNSUPPORTED),
    )
    assert_equal(Int(outcome.err.status), 505)


def test_request_line_http_higher_minor_is_1_1() raises:
    """HTTP/1.5 — major 1, minor 5 → treated as HTTP/1.1 (RFC 9110 §6.2)."""
    var buf = _bytes(String("GET / HTTP/1.5\r\n\r\n"))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_ok())
    assert_equal(Int(outcome.http_version_minor), 1)


def test_request_line_version_bad_string() raises:
    """GET / HTTQ/1.1 → 400 PARSE_ERR_HTTP_VERSION_BAD."""
    var buf = _bytes(String("GET / HTTQ/1.1\r\n\r\n"))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_false(outcome.err.is_ok())
    assert_equal(Int(outcome.err.kind), Int(PARSE_ERR_HTTP_VERSION_BAD))


def test_request_line_empty_method_rejected() raises:
    """' / HTTP/1.1' (leading space → empty method) → malformed."""
    var buf = _bytes(String(" / HTTP/1.1\r\n\r\n"))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_false(outcome.err.is_ok())
    assert_equal(
        Int(outcome.err.kind), Int(PARSE_ERR_REQUEST_LINE_MALFORMED),
    )


def test_request_line_empty_target_rejected() raises:
    """'GET  HTTP/1.1' (empty path between two spaces) → malformed."""
    var buf = _bytes(String("GET  HTTP/1.1\r\n\r\n"))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_false(outcome.err.is_ok())
    assert_equal(
        Int(outcome.err.kind), Int(PARSE_ERR_REQUEST_LINE_MALFORMED),
    )


def test_uri_too_long() raises:
    """Request-line longer than limits.max_request_line_bytes → 414."""
    var limits = ParseLimits.defaults()
    limits.max_request_line_bytes = 32
    # 50-char path is plenty over 32.
    var buf = _bytes(String(
        "GET /abcdefghijklmnopqrstuvwxyz/abcdefghij HTTP/1.1\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, limits)
    assert_false(outcome.err.is_ok())
    assert_equal(Int(outcome.err.status), 414)


def test_need_more_partial_request() raises:
    """Buffer ends before CRLFCRLF → need_more."""
    var buf = _bytes(String("GET / HTTP/1.1\r\nHost: foo\r\n"))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_need_more())


def main() raises:
    test_request_line_happy_get()
    test_request_line_post_with_path()
    test_request_line_query_string_split()
    test_request_line_http_10_keep_alive()
    test_request_line_http_10_with_keepalive()
    test_request_line_lowercase_method_rejected()
    test_request_line_unknown_method()
    test_request_line_uri_whitespace_rejected()
    test_request_line_http_09_rejected()
    test_request_line_http_2_unsupported()
    test_request_line_http_higher_minor_is_1_1()
    test_request_line_version_bad_string()
    test_request_line_empty_method_rejected()
    test_request_line_empty_target_rejected()
    test_uri_too_long()
    test_need_more_partial_request()
    print("PASS L2 codec request-line unit tests")
