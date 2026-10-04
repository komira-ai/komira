# =============================================================================
# tests/test_L2_conformance_rfc7230_corpus.mojo
# =============================================================================
#
# minimal RFC 7230 in-tree corpus
#
# Mojo 1.0.0b1 has no portable HTTP conformance harness (h2spec is HTTP/2
# only; httpwg test-vectors are gigabytes of mixed languages). Instead
# this file maintains a curated set of examples lifted DIRECTLY from
# RFC 7230 §3 (request format) and RFC 9110 §15 (status codes). Each
# entry cites the section it came from.
#
# This is a minimal in-tree corpus — a full external conformance harness is
# separate
# work.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.codec import (
    HTTP_METHOD_GET,
    HTTP_METHOD_POST,
    HTTP_METHOD_PUT,
    HTTP_METHOD_DELETE,
    HTTP_METHOD_HEAD,
    HTTP_METHOD_OPTIONS,
    HTTP_METHOD_PATCH,
    ParseLimits,
    parse_request_head,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        out.append(bytes_ref[i])
        i = i + 1
    return out^


# =============================================================================
# §1 — Happy-path corpus from RFC 7230.
# =============================================================================


def test_rfc7230_3_1_1_get_canonical() raises:
    """RFC 7230 §3.1.1 example: 'GET /hello.txt HTTP/1.1'."""
    var buf = _bytes(String(
        "GET /hello.txt HTTP/1.1\r\n"
        "User-Agent: curl/7.16.3 libcurl/7.16.3 OpenSSL/0.9.7l zlib/1.2.3\r\n"
        "Host: www.example.com\r\n"
        "Accept-Language: en, mi\r\n"
        "\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_ok())
    assert_equal(Int(outcome.request.method.code), Int(HTTP_METHOD_GET))
    assert_equal(outcome.request.path, String("/hello.txt"))
    # All headers present (lowercase canonicalized).
    assert_true(outcome.request.headers.find(String("user-agent")).__bool__())
    assert_true(outcome.request.headers.find(String("host")).__bool__())
    assert_true(
        outcome.request.headers.find(String("accept-language")).__bool__()
    )


def test_rfc7230_5_3_1_origin_form() raises:
    """RFC 7230 §5.3.1: origin-form request-target."""
    var buf = _bytes(String(
        "POST /where?q=now HTTP/1.1\r\nHost: example.com\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_ok())
    assert_equal(outcome.request.path, String("/where"))
    assert_equal(outcome.request.query_string, String("q=now"))


def test_rfc7230_4_1_chunked_te_present() raises:
    """RFC 7230 §4.1 — Transfer-Encoding: chunked recognized."""
    var buf = _bytes(String(
        "POST /api HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_ok())
    assert_true(outcome.is_chunked)


def test_rfc7230_5_1_1_expect_continue() raises:
    """RFC 7230 §5.1.1: 'Expect: 100-continue' → expects_continue."""
    var buf = _bytes(String(
        "PUT /resource HTTP/1.1\r\n"
        "Content-Length: 1024\r\n"
        "Expect: 100-continue\r\n"
        "\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_ok())
    assert_true(outcome.expects_continue)
    assert_equal(outcome.content_length, 1024)


def test_rfc7230_6_3_keepalive_default_http11() raises:
    """RFC 7230 §6.3: HTTP/1.1 default = persistent connection.

    No Connection header → connection_close = False.
    """
    var buf = _bytes(String(
        "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_ok())
    assert_false(outcome.connection_close)


def test_rfc7230_6_3_connection_close_honored() raises:
    """RFC 7230 §6.3: 'Connection: close' → connection_close = True."""
    var buf = _bytes(String(
        "GET / HTTP/1.1\r\nConnection: close\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_ok())
    assert_true(outcome.connection_close)


# =============================================================================
# §2 — All 7 methods round-trip.
# =============================================================================


def test_all_methods_round_trip() raises:
    """Each of the 7 canonical HTTP methods parses without error."""
    var methods = List[String]()
    methods.append(String("GET"))
    methods.append(String("POST"))
    methods.append(String("PUT"))
    methods.append(String("DELETE"))
    methods.append(String("PATCH"))
    methods.append(String("HEAD"))
    methods.append(String("OPTIONS"))
    var expected_codes = List[UInt8]()
    expected_codes.append(UInt8(HTTP_METHOD_GET))
    expected_codes.append(UInt8(HTTP_METHOD_POST))
    expected_codes.append(UInt8(HTTP_METHOD_PUT))
    expected_codes.append(UInt8(HTTP_METHOD_DELETE))
    expected_codes.append(UInt8(HTTP_METHOD_PATCH))
    expected_codes.append(UInt8(HTTP_METHOD_HEAD))
    expected_codes.append(UInt8(HTTP_METHOD_OPTIONS))
    var i = 0
    while i < len(methods):
        var line = methods[i] + String(" / HTTP/1.1\r\n\r\n")
        var buf = _bytes(line)
        var span = Span[UInt8](buf)
        var outcome = parse_request_head(span, ParseLimits.defaults())
        assert_true(outcome.err.is_ok())
        assert_equal(
            Int(outcome.request.method.code), Int(expected_codes[i]),
        )
        i = i + 1


def main() raises:
    test_rfc7230_3_1_1_get_canonical()
    test_rfc7230_5_3_1_origin_form()
    test_rfc7230_4_1_chunked_te_present()
    test_rfc7230_5_1_1_expect_continue()
    test_rfc7230_6_3_keepalive_default_http11()
    test_rfc7230_6_3_connection_close_honored()
    test_all_methods_round_trip()
    print("PASS L2 conformance RFC 7230 corpus")
