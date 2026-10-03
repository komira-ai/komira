# =============================================================================
# tests/test_L2_codec_headers.mojo
# =============================================================================
#
# header parser unit tests
#
# Covers RFC 7230 §3.2 header parsing:
#   * Single + multiple headers
#   * Case-insensitive header-name lookup
#   * Whitespace around value (OWS trimmed)
#   * Folded headers (obs-fold) rejected
#   * Missing colon rejected
#   * Invalid name characters rejected
#   * Control chars in value rejected
#   * Header count overflow → 431
#   * Per-header size overflow → 431
#   * Total-headers overflow → 431
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.codec import (
    PARSE_ERR_HEADER_COUNT_OVERFLOW,
    PARSE_ERR_HEADER_NAME_INVALID,
    PARSE_ERR_HEADER_NO_COLON,
    PARSE_ERR_HEADER_OBS_FOLD,
    PARSE_ERR_HEADER_SIZE_OVERFLOW,
    PARSE_ERR_HEADER_TOTAL_OVERFLOW,
    PARSE_ERR_HEADER_VALUE_CONTROL_CHAR,
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


def test_headers_single() raises:
    """Single Host header parses; canonicalized to lowercase."""
    var buf = _bytes(String("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_ok())
    var entry = outcome.request.headers.find(String("host"))
    assert_true(entry.__bool__())
    assert_equal(entry.value(), String("localhost"))


def test_headers_case_insensitive_lookup() raises:
    """Header names are stored lowercase regardless of input case."""
    var buf = _bytes(String(
        "GET / HTTP/1.1\r\nUSER-Agent: curl/8.0\r\nHOST: ex\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_ok())
    assert_true(outcome.request.headers.find(String("user-agent")).__bool__())
    assert_true(outcome.request.headers.find(String("host")).__bool__())
    # Original casing keys absent.
    assert_false(
        outcome.request.headers.find(String("USER-Agent")).__bool__()
    )


def test_headers_ows_trimmed() raises:
    """Leading + trailing OWS around header value trimmed."""
    var buf = _bytes(String(
        "GET / HTTP/1.1\r\nX-Foo:    bar   \r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_ok())
    var entry = outcome.request.headers.find(String("x-foo"))
    assert_true(entry.__bool__())
    assert_equal(entry.value(), String("bar"))


def test_headers_multi_value_folded_via_comma() raises:
    """Two headers with the same name → comma-folded per RFC 7230 §3.2.2."""
    var buf = _bytes(String(
        "GET / HTTP/1.1\r\nX-Trace: a\r\nX-Trace: b\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_ok())
    var entry = outcome.request.headers.find(String("x-trace"))
    assert_true(entry.__bool__())
    assert_equal(entry.value(), String("a, b"))


def test_headers_obs_fold_rejected() raises:
    """RFC 7230 §3.2.4 obs-fold (line beginning with SP/HTAB) rejected."""
    # First header line: 'X-Multi: foo'; second 'line' begins with SP
    # (continuation per obs-fold).
    var buf = _bytes(String(
        "GET / HTTP/1.1\r\nX-Multi: foo\r\n bar\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_false(outcome.err.is_ok())
    assert_equal(Int(outcome.err.kind), Int(PARSE_ERR_HEADER_OBS_FOLD))
    assert_equal(Int(outcome.err.status), 400)


def test_headers_no_colon_rejected() raises:
    """A line without ':' → 400 PARSE_ERR_HEADER_NO_COLON."""
    var buf = _bytes(String("GET / HTTP/1.1\r\nBogusHeader\r\n\r\n"))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_false(outcome.err.is_ok())
    assert_equal(Int(outcome.err.kind), Int(PARSE_ERR_HEADER_NO_COLON))


def test_headers_name_invalid_space_before_colon() raises:
    """Whitespace before ':' in header name → 400."""
    var buf = _bytes(String(
        "GET / HTTP/1.1\r\nX-Bad : value\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_false(outcome.err.is_ok())
    assert_equal(Int(outcome.err.kind), Int(PARSE_ERR_HEADER_NAME_INVALID))


def test_headers_value_control_char_rejected() raises:
    """Embedded NUL inside header value → 400.

    Builds the header line byte-by-byte since String literals can't
    embed a NUL byte cleanly.
    """
    var buf = List[UInt8]()
    var s = String("GET / HTTP/1.1\r\nX-Foo: ")
    var sb = s.as_bytes()
    var k = 0
    while k < len(sb):
        buf.append(sb[k])
        k = k + 1
    buf.append(UInt8(0x00))    # NUL — control char in value
    buf.append(UInt8(ord("x")))
    buf.append(UInt8(0x0D))
    buf.append(UInt8(0x0A))
    buf.append(UInt8(0x0D))
    buf.append(UInt8(0x0A))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_false(outcome.err.is_ok())
    assert_equal(
        Int(outcome.err.kind), Int(PARSE_ERR_HEADER_VALUE_CONTROL_CHAR),
    )


def test_headers_count_overflow_431() raises:
    """More headers than limits.max_headers → 431."""
    var limits = ParseLimits.defaults()
    limits.max_headers = 2
    var buf = _bytes(String(
        "GET / HTTP/1.1\r\n"
        "A: 1\r\n"
        "B: 2\r\n"
        "C: 3\r\n"
        "\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, limits)
    assert_false(outcome.err.is_ok())
    assert_equal(
        Int(outcome.err.kind), Int(PARSE_ERR_HEADER_COUNT_OVERFLOW),
    )
    assert_equal(Int(outcome.err.status), 431)


def test_headers_single_header_size_overflow_431() raises:
    """A header line longer than max_header_bytes → 431."""
    var limits = ParseLimits.defaults()
    limits.max_header_bytes = 16
    var buf = _bytes(String(
        "GET / HTTP/1.1\r\nX-A-Very-Long: aaaaaaaaaaaaaaaaaaaa\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, limits)
    assert_false(outcome.err.is_ok())
    assert_equal(
        Int(outcome.err.kind), Int(PARSE_ERR_HEADER_SIZE_OVERFLOW),
    )
    assert_equal(Int(outcome.err.status), 431)


def test_headers_total_overflow_431() raises:
    """Total headers section exceeds max_total_header_bytes → 431.

    Set the cap low and stuff many headers in; we don't reach CRLFCRLF
    within the scan window."""
    var limits = ParseLimits.defaults()
    limits.max_total_header_bytes = 64
    var buf = _bytes(String(
        "GET / HTTP/1.1\r\n"
        "X1: aaaaaaaaaa\r\n"
        "X2: aaaaaaaaaa\r\n"
        "X3: aaaaaaaaaa\r\n"
        "X4: aaaaaaaaaa\r\n"
        "\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, limits)
    assert_false(outcome.err.is_ok())
    assert_equal(
        Int(outcome.err.kind), Int(PARSE_ERR_HEADER_TOTAL_OVERFLOW),
    )
    assert_equal(Int(outcome.err.status), 431)


def main() raises:
    test_headers_single()
    test_headers_case_insensitive_lookup()
    test_headers_ows_trimmed()
    test_headers_multi_value_folded_via_comma()
    test_headers_obs_fold_rejected()
    test_headers_no_colon_rejected()
    test_headers_name_invalid_space_before_colon()
    test_headers_value_control_char_rejected()
    test_headers_count_overflow_431()
    test_headers_single_header_size_overflow_431()
    test_headers_total_overflow_431()
    print("PASS L2 codec header parser unit tests")
