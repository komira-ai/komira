# =============================================================================
# src/komira_http_client/tests/test_response_parser.mojo
# =============================================================================
# Tier-1 socket-free response-parser tests over Span[UInt8].

from std.testing import assert_equal, assert_true, assert_false

from komira_http_client.response_parser import (
    ResponseParseLimits,
    parse_response_head,
)


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        out.append(bytes_ref[i])
        i = i + 1
    return out^


def test_simple_200_ok() raises:
    var body = _b(String("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"))
    var r = parse_response_head(Span[UInt8](body), ResponseParseLimits.defaults())
    assert_true(r.is_ok())
    assert_equal(Int(r.status), 200)
    assert_equal(r.reason, String("OK"))
    assert_equal(Int(r.http_version_minor), 1)
    assert_equal(r.content_length, 5)
    assert_false(r.is_chunked)
    assert_false(r.connection_close)
    # headers_end_off = byte after the CRLFCRLF — the body's "hello"
    # begins there.
    assert_equal(r.headers_end_off, len(body) - 5)


def test_no_body_204_no_content() raises:
    var body = _b(String("HTTP/1.1 204 No Content\r\n\r\n"))
    var r = parse_response_head(Span[UInt8](body), ResponseParseLimits.defaults())
    assert_true(r.is_ok())
    assert_equal(Int(r.status), 204)
    assert_equal(r.content_length, -1)
    assert_false(r.is_chunked)


def test_chunked_response() raises:
    var body = _b(String("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"))
    var r = parse_response_head(Span[UInt8](body), ResponseParseLimits.defaults())
    assert_true(r.is_ok())
    assert_true(r.is_chunked)
    assert_equal(r.content_length, -1)


def test_multi_value_set_cookie() raises:
    var body = _b(String("HTTP/1.1 200 OK\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\nContent-Length: 0\r\n\r\n"))
    var r = parse_response_head(Span[UInt8](body), ResponseParseLimits.defaults())
    assert_true(r.is_ok())
    var cookies = r.headers.get_all(String("set-cookie"))
    assert_equal(cookies.__len__(), 2)
    assert_equal(cookies[0], String("a=1"))
    assert_equal(cookies[1], String("b=2"))


def test_connection_close() raises:
    var body = _b(String("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"))
    var r = parse_response_head(Span[UInt8](body), ResponseParseLimits.defaults())
    assert_true(r.is_ok())
    assert_true(r.connection_close)


def test_http10_default_close() raises:
    var body = _b(String("HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n"))
    var r = parse_response_head(Span[UInt8](body), ResponseParseLimits.defaults())
    assert_true(r.is_ok())
    assert_equal(Int(r.http_version_minor), 0)
    # HTTP/1.0 default = connection close.
    assert_true(r.connection_close)


def test_http10_keep_alive() raises:
    var body = _b(String("HTTP/1.0 200 OK\r\nConnection: keep-alive\r\nContent-Length: 0\r\n\r\n"))
    var r = parse_response_head(Span[UInt8](body), ResponseParseLimits.defaults())
    assert_true(r.is_ok())
    assert_false(r.connection_close)


def test_empty_reason() raises:
    """Status line "HTTP/1.1 204 \r\n" is acceptable per RFC 7230."""
    var body = _b(String("HTTP/1.1 204 \r\nContent-Length: 0\r\n\r\n"))
    var r = parse_response_head(Span[UInt8](body), ResponseParseLimits.defaults())
    assert_true(r.is_ok())
    assert_equal(Int(r.status), 204)


def test_status_with_no_reason_no_sp() raises:
    """Just "HTTP/1.1 200" — no reason and no SP — is allowed."""
    var body = _b(String("HTTP/1.1 200\r\nContent-Length: 0\r\n\r\n"))
    var r = parse_response_head(Span[UInt8](body), ResponseParseLimits.defaults())
    assert_true(r.is_ok())
    assert_equal(Int(r.status), 200)
    assert_equal(r.reason, String(""))


def test_need_more_partial() raises:
    """No CRLFCRLF yet — need_more."""
    var body = _b(String("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n"))
    var r = parse_response_head(Span[UInt8](body), ResponseParseLimits.defaults())
    assert_true(r.is_need_more())


def test_need_more_empty() raises:
    var body = List[UInt8]()
    var r = parse_response_head(Span[UInt8](body), ResponseParseLimits.defaults())
    assert_true(r.is_need_more())


def test_reject_bad_version() raises:
    var body = _b(String("HTTP/2.0 200 OK\r\n\r\n"))
    var r = parse_response_head(Span[UInt8](body), ResponseParseLimits.defaults())
    assert_true(r.is_error())


def test_reject_short_line() raises:
    var body = _b(String("HTTP/1.1\r\n\r\n"))
    var r = parse_response_head(Span[UInt8](body), ResponseParseLimits.defaults())
    assert_true(r.is_error())


def test_reject_status_not_digits() raises:
    var body = _b(String("HTTP/1.1 abc OK\r\n\r\n"))
    var r = parse_response_head(Span[UInt8](body), ResponseParseLimits.defaults())
    assert_true(r.is_error())


def test_reject_status_out_of_range() raises:
    var body = _b(String("HTTP/1.1 099 X\r\n\r\n"))
    var r = parse_response_head(Span[UInt8](body), ResponseParseLimits.defaults())
    assert_true(r.is_error())


def test_reject_obs_fold() raises:
    """RFC 7230 §3.2.4 — obs-fold (LF + SP/HTAB) MUST be rejected by
    recipient. A line that begins with SP/HTAB is the obs-fold shape."""
    var body = _b(String("HTTP/1.1 200 OK\r\n A: B\r\n\r\n"))
    var r = parse_response_head(Span[UInt8](body), ResponseParseLimits.defaults())
    assert_true(r.is_error())


def test_reject_header_no_colon() raises:
    var body = _b(String("HTTP/1.1 200 OK\r\nBadHeader\r\n\r\n"))
    var r = parse_response_head(Span[UInt8](body), ResponseParseLimits.defaults())
    assert_true(r.is_error())


def test_reject_cl_and_te() raises:
    """RFC 7230 §3.3.3 — Content-Length + Transfer-Encoding together MUST
    be rejected by a recipient (smuggling defense)."""
    var body = _b(String("HTTP/1.1 200 OK\r\nContent-Length: 10\r\nTransfer-Encoding: chunked\r\n\r\n"))
    var r = parse_response_head(Span[UInt8](body), ResponseParseLimits.defaults())
    assert_true(r.is_error())


def test_reject_unsupported_te() raises:
    """Any TE other than chunked is rejected by this codec."""
    var body = _b(String("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n"))
    var r = parse_response_head(Span[UInt8](body), ResponseParseLimits.defaults())
    assert_true(r.is_error())


def test_reject_duplicate_cl_conflict() raises:
    var body = _b(String("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 10\r\n\r\n"))
    var r = parse_response_head(Span[UInt8](body), ResponseParseLimits.defaults())
    assert_true(r.is_error())


def test_reject_invalid_cl() raises:
    var body = _b(String("HTTP/1.1 200 OK\r\nContent-Length: abc\r\n\r\n"))
    var r = parse_response_head(Span[UInt8](body), ResponseParseLimits.defaults())
    assert_true(r.is_error())


def test_headers_case_insensitive_match() raises:
    var body = _b(String("HTTP/1.1 200 OK\r\nCONTENT-LENGTH: 0\r\n\r\n"))
    var r = parse_response_head(Span[UInt8](body), ResponseParseLimits.defaults())
    assert_true(r.is_ok())
    assert_equal(r.content_length, 0)


def test_too_many_headers() raises:
    var lim = ResponseParseLimits.defaults()
    lim.max_headers = 2
    # Build with 3 headers — should fail.
    var body = _b(String("HTTP/1.1 200 OK\r\nA: 1\r\nB: 2\r\nC: 3\r\n\r\n"))
    var r = parse_response_head(Span[UInt8](body), lim)
    assert_true(r.is_error())


def test_headers_too_large() raises:
    var lim = ResponseParseLimits.defaults()
    lim.max_total_header_bytes = 32
    # Build a header block exceeding 32 bytes.
    var body = _b(String("HTTP/1.1 200 OK\r\nLong-Header-Name: very-long-value\r\n\r\n"))
    var r = parse_response_head(Span[UInt8](body), lim)
    assert_true(r.is_error())


def main() raises:
    test_simple_200_ok()
    test_no_body_204_no_content()
    test_chunked_response()
    test_multi_value_set_cookie()
    test_connection_close()
    test_http10_default_close()
    test_http10_keep_alive()
    test_empty_reason()
    test_status_with_no_reason_no_sp()
    test_need_more_partial()
    test_need_more_empty()
    test_reject_bad_version()
    test_reject_short_line()
    test_reject_status_not_digits()
    test_reject_status_out_of_range()
    test_reject_obs_fold()
    test_reject_header_no_colon()
    test_reject_cl_and_te()
    test_reject_unsupported_te()
    test_reject_duplicate_cl_conflict()
    test_reject_invalid_cl()
    test_headers_case_insensitive_match()
    test_too_many_headers()
    test_headers_too_large()
    print("OK: test_response_parser")
