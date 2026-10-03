# =============================================================================
# tests/test_L2_codec_content_length.mojo
# =============================================================================
#
# Content-Length + Transfer-Encoding
# framing tests.
#
# Covers RFC 7230 §3.3 message body framing rules + smuggling defense:
#   * Content-Length parsing
#   * max_body_bytes enforced via 413
#   * Duplicate Content-Length headers with conflicting values → 400
#   * Content-Length + Transfer-Encoding chunked simultaneously → 400
#   * Transfer-Encoding: chunked alone → is_chunked
#   * Transfer-Encoding: gzip (unsupported coding) → 400
#   * Content-Length: -5 (non-decimal / negative) → 400
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.codec import (
    PARSE_ERR_BODY_TOO_LARGE,
    PARSE_ERR_CONTENT_LENGTH_AND_CHUNKED,
    PARSE_ERR_CONTENT_LENGTH_CONFLICT,
    PARSE_ERR_CONTENT_LENGTH_INVALID,
    PARSE_ERR_TRANSFER_ENCODING_UNSUPPORTED,
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


def test_content_length_basic() raises:
    """Content-Length: 42 → outcome.content_length == 42."""
    var buf = _bytes(String(
        "POST /api HTTP/1.1\r\nContent-Length: 42\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_ok())
    assert_equal(outcome.content_length, 42)
    assert_false(outcome.is_chunked)


def test_content_length_zero() raises:
    """Content-Length: 0 → 0 (not -1, not error)."""
    var buf = _bytes(String(
        "POST /api HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_ok())
    assert_equal(outcome.content_length, 0)


def test_content_length_invalid_non_numeric() raises:
    """Content-Length: abc → 400."""
    var buf = _bytes(String(
        "POST /api HTTP/1.1\r\nContent-Length: abc\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_false(outcome.err.is_ok())
    assert_equal(
        Int(outcome.err.kind), Int(PARSE_ERR_CONTENT_LENGTH_INVALID),
    )
    assert_equal(Int(outcome.err.status), 400)


def test_content_length_negative_rejected() raises:
    """Content-Length: -5 → 400 (our parser is unsigned only)."""
    var buf = _bytes(String(
        "POST /api HTTP/1.1\r\nContent-Length: -5\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_false(outcome.err.is_ok())
    assert_equal(
        Int(outcome.err.kind), Int(PARSE_ERR_CONTENT_LENGTH_INVALID),
    )


def test_content_length_too_large_413() raises:
    """Content-Length larger than max_body_bytes → 413."""
    var limits = ParseLimits.defaults()
    limits.max_body_bytes = 1000
    var buf = _bytes(String(
        "POST /api HTTP/1.1\r\nContent-Length: 100000\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, limits)
    assert_false(outcome.err.is_ok())
    assert_equal(Int(outcome.err.kind), Int(PARSE_ERR_BODY_TOO_LARGE))
    assert_equal(Int(outcome.err.status), 413)


def test_content_length_conflicting_dupes() raises:
    """Two Content-Length headers with different values → 400."""
    var buf = _bytes(String(
        "POST /api HTTP/1.1\r\nContent-Length: 5\r\n"
        "Content-Length: 7\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_false(outcome.err.is_ok())
    assert_equal(
        Int(outcome.err.kind), Int(PARSE_ERR_CONTENT_LENGTH_CONFLICT),
    )


def test_transfer_encoding_chunked_alone() raises:
    """Transfer-Encoding: chunked → is_chunked = True."""
    var buf = _bytes(String(
        "POST /api HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_true(outcome.err.is_ok())
    assert_true(outcome.is_chunked)
    assert_equal(outcome.content_length, -1)


def test_transfer_encoding_and_content_length_rejected() raises:
    """TE: chunked + Content-Length: 5 → 400 (smuggling defense, RFC 7230 §3.3.3 case 3)."""
    var buf = _bytes(String(
        "POST /api HTTP/1.1\r\n"
        "Transfer-Encoding: chunked\r\n"
        "Content-Length: 5\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_false(outcome.err.is_ok())
    assert_equal(
        Int(outcome.err.kind),
        Int(PARSE_ERR_CONTENT_LENGTH_AND_CHUNKED),
    )
    assert_equal(Int(outcome.err.status), 400)


def test_transfer_encoding_unsupported_coding() raises:
    """TE: gzip (no chunked anywhere) → 400."""
    var buf = _bytes(String(
        "POST /api HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, ParseLimits.defaults())
    assert_false(outcome.err.is_ok())
    assert_equal(
        Int(outcome.err.kind),
        Int(PARSE_ERR_TRANSFER_ENCODING_UNSUPPORTED),
    )
    assert_equal(Int(outcome.err.status), 400)


def main() raises:
    test_content_length_basic()
    test_content_length_zero()
    test_content_length_invalid_non_numeric()
    test_content_length_negative_rejected()
    test_content_length_too_large_413()
    test_content_length_conflicting_dupes()
    test_transfer_encoding_chunked_alone()
    test_transfer_encoding_and_content_length_rejected()
    test_transfer_encoding_unsupported_coding()
    print("PASS L2 codec content-length / transfer-encoding tests")
