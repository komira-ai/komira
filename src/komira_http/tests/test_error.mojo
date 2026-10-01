# =============================================================================
# src/komira_http/tests/test_error.mojo — HttpError unit tests
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http.client.error import (
    HTTP_ERROR_CONNECT_FAILED,
    HTTP_ERROR_IO_ERROR,
    HTTP_ERROR_NONE,
    HTTP_ERROR_PROTOCOL_STATUS,
    HTTP_ERROR_RESPONSE_FRAMING,
    HTTP_ERROR_RETRYABLE_TRANSPORT,
    HTTP_ERROR_TIMEOUT,
    HttpError,
)


def test_none_is_ok() raises:
    var e = HttpError.none()
    assert_true(e.is_ok())
    assert_equal(Int(e.kind), Int(HTTP_ERROR_NONE))
    assert_equal(e.kind_name(), String("NONE"))


def test_connect_failed() raises:
    var e = HttpError.connect_failed(String("ECONNREFUSED to 127.0.0.1:9999"))
    assert_false(e.is_ok())
    assert_equal(Int(e.kind), Int(HTTP_ERROR_CONNECT_FAILED))
    assert_equal(e.kind_name(), String("CONNECT_FAILED"))


def test_io_error_carries_errno() raises:
    var e = HttpError.io_error(Int32(32))  # EPIPE
    assert_equal(Int(e.kind), Int(HTTP_ERROR_IO_ERROR))
    assert_equal(Int(e.status), 32)


def test_retryable_transport_predicate() raises:
    var e = HttpError.retryable_transport(String("peer reset before any response"))
    assert_true(e.is_retryable_transport())
    var e2 = HttpError.connect_failed(String("x"))
    assert_false(e2.is_retryable_transport())


def test_protocol_status_predicate() raises:
    var e = HttpError.protocol_status(Int32(503))
    assert_true(e.is_protocol_status())
    assert_equal(Int(e.status), 503)
    var e2 = HttpError.io_error(Int32(1))
    assert_false(e2.is_protocol_status())


def test_response_framing() raises:
    var e = HttpError.response_framing(String("CL+TE both present"))
    assert_equal(Int(e.kind), Int(HTTP_ERROR_RESPONSE_FRAMING))
    assert_equal(e.kind_name(), String("RESPONSE_FRAMING"))


def test_timeout() raises:
    var e = HttpError.timeout()
    assert_equal(Int(e.kind), Int(HTTP_ERROR_TIMEOUT))


def test_status_line_invalid() raises:
    var e = HttpError.status_line_invalid(String("malformed status"))
    assert_equal(e.kind_name(), String("STATUS_LINE_INVALID"))


def test_kind_name_all() raises:
    """Spot-check every kind has a name."""
    assert_equal(HttpError.none().kind_name(), String("NONE"))
    assert_equal(HttpError.connect_failed(String("x")).kind_name(), String("CONNECT_FAILED"))
    assert_equal(HttpError.connect_timeout().kind_name(), String("CONNECT_TIMEOUT"))
    assert_equal(HttpError.io_error(Int32(1)).kind_name(), String("IO_ERROR"))
    assert_equal(HttpError.retryable_transport(String("x")).kind_name(), String("RETRYABLE_TRANSPORT"))
    assert_equal(HttpError.eof_mid_response().kind_name(), String("EOF_MID_RESPONSE"))
    assert_equal(HttpError.response_framing(String("x")).kind_name(), String("RESPONSE_FRAMING"))
    assert_equal(HttpError.status_line_invalid(String("x")).kind_name(), String("STATUS_LINE_INVALID"))
    assert_equal(HttpError.header_invalid(String("x")).kind_name(), String("HEADER_INVALID"))
    assert_equal(HttpError.headers_too_large().kind_name(), String("HEADERS_TOO_LARGE"))
    assert_equal(HttpError.body_too_large().kind_name(), String("BODY_TOO_LARGE"))
    assert_equal(HttpError.protocol_status(Int32(404)).kind_name(), String("PROTOCOL_STATUS"))
    assert_equal(HttpError.cancelled().kind_name(), String("CANCELLED"))
    assert_equal(HttpError.timeout().kind_name(), String("TIMEOUT"))
    assert_equal(HttpError.url_invalid(String("x")).kind_name(), String("URL_INVALID"))


def main() raises:
    test_none_is_ok()
    test_connect_failed()
    test_io_error_carries_errno()
    test_retryable_transport_predicate()
    test_protocol_status_predicate()
    test_response_framing()
    test_timeout()
    test_status_line_invalid()
    test_kind_name_all()
    print("OK: test_error")
