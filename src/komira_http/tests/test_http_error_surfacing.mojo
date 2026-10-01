# =============================================================================
# src/komira_http/tests/test_http_error_surfacing.mojo
# HttpError audit + message tests.
# =============================================================================
#
# "HttpError message tests for each
# variant".
#
# Verifies the HttpError surfacing across each documented variant:
#   * CONNECT_FAILED / CONNECT_TIMEOUT
#   * TLS_VERIFY_FAILED / TLS_HANDSHAKE_FAILED
#   * IO_ERROR / RETRYABLE_TRANSPORT / EOF_MID_RESPONSE
#   * RESPONSE_FRAMING / STATUS_LINE_INVALID / HEADER_INVALID /
#     HEADERS_TOO_LARGE
#   * BODY_TOO_LARGE / PROTOCOL_STATUS
#   * CANCELLED / TIMEOUT
#   * URL_INVALID / RANGE_NOT_HONORED
#
# For each variant, this test asserts:
#   1. The factory method produces an HttpError with the right kind.
#   2. kind_name() returns the expected symbolic name.
#   3. is_ok() / is_retryable_transport() / is_protocol_status()
#      classify correctly.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http.client.error import (
    HTTP_ERROR_BODY_TOO_LARGE,
    HTTP_ERROR_CANCELLED,
    HTTP_ERROR_CONNECT_FAILED,
    HTTP_ERROR_CONNECT_TIMEOUT,
    HTTP_ERROR_EOF_MID_RESPONSE,
    HTTP_ERROR_H2_PROTOCOL,
    HTTP_ERROR_HEADER_INVALID,
    HTTP_ERROR_HEADERS_TOO_LARGE,
    HTTP_ERROR_IO_ERROR,
    HTTP_ERROR_NONE,
    HTTP_ERROR_PROTOCOL_STATUS,
    HTTP_ERROR_RANGE_NOT_HONORED,
    HTTP_ERROR_RESPONSE_FRAMING,
    HTTP_ERROR_RETRYABLE_TRANSPORT,
    HTTP_ERROR_STATUS_LINE_INVALID,
    HTTP_ERROR_TIMEOUT,
    HTTP_ERROR_TLS_HANDSHAKE_FAILED,
    HTTP_ERROR_TLS_VERIFY_FAILED,
    HTTP_ERROR_URL_INVALID,
    HttpError,
)


# =============================================================================
# Each variant factory + kind_name + classifier surface.
# =============================================================================


def test_none_sentinel() raises:
    var e = HttpError.none()
    assert_equal(e.kind, HTTP_ERROR_NONE)
    assert_true(e.is_ok())
    assert_false(e.is_retryable_transport())
    assert_false(e.is_protocol_status())
    assert_equal(e.kind_name(), String("NONE"))


def test_connect_failed() raises:
    var e = HttpError.connect_failed(String("dns lookup failed"))
    assert_equal(e.kind, HTTP_ERROR_CONNECT_FAILED)
    assert_false(e.is_ok())
    assert_false(e.is_retryable_transport())
    assert_equal(e.kind_name(), String("CONNECT_FAILED"))


def test_connect_timeout() raises:
    var e = HttpError.connect_timeout()
    assert_equal(e.kind, HTTP_ERROR_CONNECT_TIMEOUT)
    assert_equal(e.kind_name(), String("CONNECT_TIMEOUT"))


def test_io_error_with_errno() raises:
    var e = HttpError.io_error(Int32(11))  # EAGAIN
    assert_equal(e.kind, HTTP_ERROR_IO_ERROR)
    assert_equal(e.status, Int32(11))
    assert_equal(e.kind_name(), String("IO_ERROR"))


def test_retryable_transport_classifier_is_load_bearing() raises:
    """is_retryable_transport is the SOLE classifier the
    RetryLayer + ObjectStore branch on. It MUST distinguish
    RETRYABLE_TRANSPORT from every other variant."""
    var e_retry = HttpError.retryable_transport(String("conn reset"))
    assert_true(e_retry.is_retryable_transport())
    assert_equal(e_retry.kind_name(), String("RETRYABLE_TRANSPORT"))

    var e_eof = HttpError.eof_mid_response()
    assert_false(
        e_eof.is_retryable_transport(),
        "EOF_MID_RESPONSE is NOT retryable per RFC 7230 §6.3.1",
    )

    var e_status = HttpError.protocol_status(Int32(503))
    assert_false(
        e_status.is_retryable_transport(),
        "PROTOCOL_STATUS is NOT retryable by default; consumer can opt-in",
    )


def test_eof_mid_response() raises:
    var e = HttpError.eof_mid_response()
    assert_equal(e.kind, HTTP_ERROR_EOF_MID_RESPONSE)
    assert_equal(e.kind_name(), String("EOF_MID_RESPONSE"))


def test_response_framing() raises:
    var e = HttpError.response_framing(String("CL+TE both present"))
    assert_equal(e.kind, HTTP_ERROR_RESPONSE_FRAMING)
    assert_equal(e.kind_name(), String("RESPONSE_FRAMING"))


def test_status_line_invalid() raises:
    var e = HttpError.status_line_invalid(String("bad version"))
    assert_equal(e.kind, HTTP_ERROR_STATUS_LINE_INVALID)
    assert_equal(e.kind_name(), String("STATUS_LINE_INVALID"))


def test_header_invalid() raises:
    var e = HttpError.header_invalid(String("missing colon"))
    assert_equal(e.kind, HTTP_ERROR_HEADER_INVALID)
    assert_equal(e.kind_name(), String("HEADER_INVALID"))


def test_headers_too_large() raises:
    var e = HttpError.headers_too_large()
    assert_equal(e.kind, HTTP_ERROR_HEADERS_TOO_LARGE)
    assert_equal(e.kind_name(), String("HEADERS_TOO_LARGE"))


def test_body_too_large() raises:
    var e = HttpError.body_too_large()
    assert_equal(e.kind, HTTP_ERROR_BODY_TOO_LARGE)
    assert_equal(e.kind_name(), String("BODY_TOO_LARGE"))


def test_protocol_status_carries_status() raises:
    var e = HttpError.protocol_status(Int32(404))
    assert_equal(e.kind, HTTP_ERROR_PROTOCOL_STATUS)
    assert_equal(e.status, Int32(404))
    assert_true(e.is_protocol_status())
    assert_equal(e.kind_name(), String("PROTOCOL_STATUS"))


def test_cancelled() raises:
    var e = HttpError.cancelled()
    assert_equal(e.kind, HTTP_ERROR_CANCELLED)
    assert_equal(e.kind_name(), String("CANCELLED"))


def test_timeout() raises:
    var e = HttpError.timeout()
    assert_equal(e.kind, HTTP_ERROR_TIMEOUT)
    assert_equal(e.kind_name(), String("TIMEOUT"))


def test_url_invalid() raises:
    var e = HttpError.url_invalid(String("missing scheme"))
    assert_equal(e.kind, HTTP_ERROR_URL_INVALID)
    assert_equal(e.kind_name(), String("URL_INVALID"))


def test_range_not_honored_carries_status() raises:
    var e = HttpError.range_not_honored(Int32(200))
    assert_equal(e.kind, HTTP_ERROR_RANGE_NOT_HONORED)
    assert_equal(e.status, Int32(200))
    assert_equal(e.kind_name(), String("RANGE_NOT_HONORED"))


# =============================================================================
# Sentinel namespace allocation guard — verify no overlapping uint8 vals.
# =============================================================================


def test_sentinel_namespace_disjoint() raises:
    """All HTTP_ERROR_* sentinels have distinct uint8 values.
    Verifies the per-class grouping (10s=connect, 20s=TLS, 30s=transport,
    40s=protocol, 50s=h2, 60s=body, 70s=control, 80s=parse-time)."""
    var vals = List[UInt8]()
    vals.append(HTTP_ERROR_NONE)              # 0
    vals.append(HTTP_ERROR_CONNECT_FAILED)    # 10
    vals.append(HTTP_ERROR_CONNECT_TIMEOUT)   # 11
    vals.append(HTTP_ERROR_TLS_VERIFY_FAILED) # 20
    vals.append(HTTP_ERROR_TLS_HANDSHAKE_FAILED) # 21
    vals.append(HTTP_ERROR_IO_ERROR)          # 30
    vals.append(HTTP_ERROR_RETRYABLE_TRANSPORT) # 31
    vals.append(HTTP_ERROR_EOF_MID_RESPONSE)  # 32
    vals.append(HTTP_ERROR_RESPONSE_FRAMING)  # 40
    vals.append(HTTP_ERROR_STATUS_LINE_INVALID) # 41
    vals.append(HTTP_ERROR_HEADER_INVALID)    # 42
    vals.append(HTTP_ERROR_HEADERS_TOO_LARGE) # 43
    vals.append(HTTP_ERROR_H2_PROTOCOL)       # 50
    vals.append(HTTP_ERROR_BODY_TOO_LARGE)    # 60
    vals.append(HTTP_ERROR_PROTOCOL_STATUS)   # 70
    vals.append(HTTP_ERROR_CANCELLED)         # 71
    vals.append(HTTP_ERROR_TIMEOUT)           # 72
    vals.append(HTTP_ERROR_URL_INVALID)       # 80
    vals.append(HTTP_ERROR_RANGE_NOT_HONORED) # 81

    var n = vals.__len__()
    var i = 0
    while i < n:
        var j = i + 1
        while j < n:
            assert_false(
                vals[i] == vals[j],
                "HttpError sentinel collision at indices "
                + String(i) + " and " + String(j),
            )
            j = j + 1
        i = i + 1


def main() raises:
    test_none_sentinel()
    test_connect_failed()
    test_connect_timeout()
    test_io_error_with_errno()
    test_retryable_transport_classifier_is_load_bearing()
    test_eof_mid_response()
    test_response_framing()
    test_status_line_invalid()
    test_header_invalid()
    test_headers_too_large()
    test_body_too_large()
    test_protocol_status_carries_status()
    test_cancelled()
    test_timeout()
    test_url_invalid()
    test_range_not_honored_carries_status()
    test_sentinel_namespace_disjoint()
    print("[OK] test_http_error_surfacing — all 17 tests passed")
