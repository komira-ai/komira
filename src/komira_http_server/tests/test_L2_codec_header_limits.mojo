# =============================================================================
# tests/test_L2_codec_header_limits.mojo
# =============================================================================
#
# header / body limits enforcement
#
# Targeted coverage of the limits-overflow gates:
#   * Per-header line size cap (1e) → 431
#   * Total header section cap (1e) → 431
#   * Header count cap (1e) → 431
#   * Content-Length body cap (1c) → 413
#   * Request-line cap → 414
#   * Configurable via HttpServerConfig fields → to_parse_limits round-trip
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_server.server import HttpServerConfig
from komira_http_core.codec import (
    PARSE_ERR_BODY_TOO_LARGE,
    PARSE_ERR_HEADER_COUNT_OVERFLOW,
    PARSE_ERR_HEADER_SIZE_OVERFLOW,
    PARSE_ERR_HEADER_TOTAL_OVERFLOW,
    PARSE_ERR_URI_TOO_LONG,
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


def test_config_to_parse_limits_round_trip() raises:
    """HttpServerConfig.to_parse_limits() materializes the right ParseLimits."""
    var cfg = HttpServerConfig.default_ephemeral()
    cfg.max_headers = 5
    cfg.max_header_bytes = 16
    cfg.max_total_header_bytes = 128
    cfg.max_body_bytes = 256
    cfg.max_request_line_bytes = 32
    var lim = cfg.to_parse_limits()
    assert_equal(lim.max_headers, 5)
    assert_equal(lim.max_header_bytes, 16)
    assert_equal(lim.max_total_header_bytes, 128)
    assert_equal(lim.max_body_bytes, 256)
    assert_equal(lim.max_request_line_bytes, 32)


def test_header_count_overflow_with_config() raises:
    """Tight max_headers config → 431 on the 4th header."""
    var cfg = HttpServerConfig.default_ephemeral()
    cfg.max_headers = 3
    var buf = _bytes(String(
        "GET / HTTP/1.1\r\n"
        "A: 1\r\n"
        "B: 2\r\n"
        "C: 3\r\n"
        "D: 4\r\n"
        "\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, cfg.to_parse_limits())
    assert_false(outcome.err.is_ok())
    assert_equal(
        Int(outcome.err.kind), Int(PARSE_ERR_HEADER_COUNT_OVERFLOW),
    )
    assert_equal(Int(outcome.err.status), 431)


def test_header_size_overflow_with_config() raises:
    """Tight max_header_bytes → 431."""
    var cfg = HttpServerConfig.default_ephemeral()
    cfg.max_header_bytes = 10
    var buf = _bytes(String(
        "GET / HTTP/1.1\r\nX-Very-Long-Header: foo\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, cfg.to_parse_limits())
    assert_false(outcome.err.is_ok())
    assert_equal(
        Int(outcome.err.kind), Int(PARSE_ERR_HEADER_SIZE_OVERFLOW),
    )
    assert_equal(Int(outcome.err.status), 431)


def test_total_header_overflow_with_config() raises:
    """Tight max_total_header_bytes — CRLFCRLF never found within scan → 431."""
    var cfg = HttpServerConfig.default_ephemeral()
    cfg.max_total_header_bytes = 48
    # Many headers — total well exceeds 48.
    var buf = _bytes(String(
        "GET / HTTP/1.1\r\n"
        "X1: aaaaaaaaaa\r\n"
        "X2: aaaaaaaaaa\r\n"
        "X3: aaaaaaaaaa\r\n"
        "X4: aaaaaaaaaa\r\n"
        "\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, cfg.to_parse_limits())
    assert_false(outcome.err.is_ok())
    assert_equal(
        Int(outcome.err.kind), Int(PARSE_ERR_HEADER_TOTAL_OVERFLOW),
    )
    assert_equal(Int(outcome.err.status), 431)


def test_body_limit_overflow_with_config() raises:
    """Content-Length larger than configured max_body_bytes → 413."""
    var cfg = HttpServerConfig.default_ephemeral()
    cfg.max_body_bytes = 1024
    var buf = _bytes(String(
        "POST /api HTTP/1.1\r\nContent-Length: 99999\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, cfg.to_parse_limits())
    assert_false(outcome.err.is_ok())
    assert_equal(Int(outcome.err.kind), Int(PARSE_ERR_BODY_TOO_LARGE))
    assert_equal(Int(outcome.err.status), 413)


def test_request_line_overflow_with_config() raises:
    """Tight max_request_line_bytes → 414."""
    var cfg = HttpServerConfig.default_ephemeral()
    cfg.max_request_line_bytes = 20
    var buf = _bytes(String(
        "GET /aaaaaaaaaaaaaaaaaaaaaaaaaaa HTTP/1.1\r\n\r\n"
    ))
    var span = Span[UInt8](buf)
    var outcome = parse_request_head(span, cfg.to_parse_limits())
    assert_false(outcome.err.is_ok())
    assert_equal(Int(outcome.err.kind), Int(PARSE_ERR_URI_TOO_LONG))
    assert_equal(Int(outcome.err.status), 414)


def main() raises:
    test_config_to_parse_limits_round_trip()
    test_header_count_overflow_with_config()
    test_header_size_overflow_with_config()
    test_total_header_overflow_with_config()
    test_body_limit_overflow_with_config()
    test_request_line_overflow_with_config()
    print("PASS L2 codec header / body limits with config")
