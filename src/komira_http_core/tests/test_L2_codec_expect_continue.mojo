# =============================================================================
# tests/test_L2_codec_expect_continue.mojo
# =============================================================================
#
# Expect: 100-continue support tests
#
# Covers RFC 7230 §5.1.1:
#   * `Expect: 100-continue` recognized; expects_continue = True
#   * `Expect: <other>` rejected with 417 Expectation Failed
#   * `Expect` absent → expects_continue = False (default)
#   * Case-insensitive token matching (`Expect: 100-Continue` accepted)
#   * Interim 100 Continue bytes are well-formed
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.codec import (
    PARSE_ERR_EXPECT_UNSUPPORTED,
    ParseLimits,
    build_100_continue_bytes,
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


def test_expect_100_continue_detected() raises:
    """Standard Expect: 100-continue → expects_continue = True."""
    var buf = _bytes(String(
        "POST /api HTTP/1.1\r\n"
        "Content-Length: 10\r\n"
        "Expect: 100-continue\r\n"
        "\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_ok())
    assert_true(outcome.expects_continue)


def test_expect_100_continue_case_insensitive() raises:
    """Expect: 100-Continue (mixed case) → expects_continue = True."""
    var buf = _bytes(String(
        "POST /api HTTP/1.1\r\nExpect: 100-Continue\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_ok())
    assert_true(outcome.expects_continue)


def test_expect_absent() raises:
    """No Expect header → expects_continue = False."""
    var buf = _bytes(String("GET / HTTP/1.1\r\n\r\n"))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_ok())
    assert_false(outcome.expects_continue)


def test_expect_unsupported_token_417() raises:
    """Expect: <non-100-continue> → 417 Expectation Failed."""
    var buf = _bytes(String(
        "POST /api HTTP/1.1\r\nExpect: 200-ok\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_false(outcome.err.is_ok())
    assert_equal(Int(outcome.err.kind), Int(PARSE_ERR_EXPECT_UNSUPPORTED))
    assert_equal(Int(outcome.err.status), 417)


def test_build_100_continue_bytes_shape() raises:
    """build_100_continue_bytes emits 'HTTP/1.1 100 Continue\\r\\n\\r\\n'."""
    var out = List[UInt8]()
    build_100_continue_bytes(out)
    var s = String()
    var i = 0
    while i < len(out):
        s = s + chr(Int(out[i]))
        i = i + 1
    assert_equal(s, String("HTTP/1.1 100 Continue\r\n\r\n"))


def main() raises:
    test_expect_100_continue_detected()
    test_expect_100_continue_case_insensitive()
    test_expect_absent()
    test_expect_unsupported_token_417()
    test_build_100_continue_bytes_shape()
    print("PASS L2 codec expect:100-continue tests")
