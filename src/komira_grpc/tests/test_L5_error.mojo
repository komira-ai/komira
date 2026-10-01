# =============================================================================
# test_L5_error.mojo — GrpcError + trailer-parse + Connect-envelope shim
# =============================================================================
#
# error.mojo coverage.
#
# Coverage:
#   T1   GrpcError.ok / GrpcError.simple constructors + is_ok.
#   T2   format_grpc_error_message + parse_grpc_error_message round-trip.
#   T3   parse_grpc_error_message tolerance — malformed prefix → UNKNOWN +
#        full text.
#   T4   parse_grpc_status_trailers — happy path (`grpc-status: 0`, no
#        `grpc-message`) → GrpcError.ok.
#   T5   parse_grpc_status_trailers — non-OK with `grpc-message` (plain ASCII).
#   T6   parse_grpc_status_trailers — `grpc-message` with percent-encoded
#        space + non-ASCII (round-trips intact).
#   T7   parse_grpc_status_trailers — `grpc-status` missing → UNKNOWN.
#   T8   parse_grpc_status_trailers — malformed decimal `grpc-status` →
#        UNKNOWN with diagnostic message.
#   T9   parse_grpc_status_initial_headers — present → Some(GrpcError);
#        absent → None.
#   T10  grpc_error_from_http_non_200 — maps the HTTP status through the
#        spec's HTTP->gRPC table and keeps the status in the diagnostic
#        message — see the docstring.
#   T11  from_connect_error_envelope — code preserved + message preserved.
#   T12  parse_grpc_error_message — multi-digit code (e.g. 14) parses.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_grpc import (
    GrpcError,
    GRPC_STATUS_OK,
    GRPC_STATUS_UNKNOWN,
    GRPC_STATUS_NOT_FOUND,
    GRPC_STATUS_UNAVAILABLE,
    GRPC_STATUS_PERMISSION_DENIED,
    format_grpc_error_message,
    parse_grpc_error_message,
    parse_grpc_status_trailers,
    parse_grpc_status_initial_headers,
    grpc_error_from_http_non_200,
    from_connect_error_envelope,
)
from komira_http.client.header_map import HeaderMap
from komira_connect.codec_connect_json import ConnectErrorEnvelope


def test_t1_constructors() raises:
    """T1 — GrpcError.ok / simple + is_ok."""
    var ok = GrpcError.ok()
    assert_equal(ok.code, GRPC_STATUS_OK, "ok code is 0")
    assert_true(ok.is_ok(), "ok.is_ok() True")
    assert_false(ok.details.__bool__(), "ok has no details")

    var err = GrpcError.simple(GRPC_STATUS_NOT_FOUND, String("missing"))
    assert_equal(err.code, GRPC_STATUS_NOT_FOUND, "err code 5")
    assert_false(err.is_ok(), "err.is_ok() False")
    assert_equal(err.message, String("missing"), "message preserved")


def test_t2_format_parse_round_trip() raises:
    """T2 — format_grpc_error_message → parse_grpc_error_message round-trip."""
    var s = format_grpc_error_message(
        GRPC_STATUS_NOT_FOUND, String("user 42 not found")
    )
    var parsed = parse_grpc_error_message(s)
    assert_equal(parsed[0], GRPC_STATUS_NOT_FOUND, "code preserved")
    assert_equal(parsed[1], String("user 42 not found"), "msg preserved")


def test_t3_parse_tolerance() raises:
    """T3 — malformed prefix → (UNKNOWN, full text) fallback."""
    var parsed = parse_grpc_error_message(String("not a structured error"))
    assert_equal(parsed[0], GRPC_STATUS_UNKNOWN, "fallback to UNKNOWN")
    assert_equal(parsed[1], String("not a structured error"), "full text")

    var parsed2 = parse_grpc_error_message(String("[grpc:abc] bad code"))
    assert_equal(parsed2[0], GRPC_STATUS_UNKNOWN, "non-digit → UNKNOWN")


def test_t4_trailer_ok() raises:
    """T4 — `grpc-status: 0` → GrpcError.ok."""
    var tr = HeaderMap()
    tr.append(String("grpc-status"), String("0"))
    var err = parse_grpc_status_trailers(tr)
    assert_equal(err.code, GRPC_STATUS_OK, "OK code")
    assert_true(err.is_ok(), "is_ok")
    assert_equal(err.message, String(""), "no message on OK")


def test_t5_trailer_non_ok_plain_message() raises:
    """T5 — non-OK with plain ASCII grpc-message."""
    var tr = HeaderMap()
    tr.append(String("grpc-status"), String("14"))
    tr.append(String("grpc-message"), String("upstream-unavailable"))
    var err = parse_grpc_status_trailers(tr)
    assert_equal(err.code, GRPC_STATUS_UNAVAILABLE, "code 14")
    assert_equal(err.message, String("upstream-unavailable"), "msg")


def test_t6_trailer_percent_decoded_message() raises:
    """T6 — `grpc-message` with percent-encoded characters round-trips."""
    var tr = HeaderMap()
    tr.append(String("grpc-status"), String("13"))
    # "internal: not found" — space is percent-encoded as %20 per gRPC spec
    tr.append(
        String("grpc-message"),
        String("internal:%20not%20found"),
    )
    var err = parse_grpc_status_trailers(tr)
    assert_equal(err.code, UInt8(13), "code 13")
    # The space %20 should have been percent-decoded to literal space.
    assert_equal(err.message, String("internal: not found"), "percent-decoded")


def test_t7_trailer_missing_status() raises:
    """T7 — `grpc-status` absent → UNKNOWN with diagnostic message."""
    var tr = HeaderMap()
    var err = parse_grpc_status_trailers(tr)
    assert_equal(err.code, GRPC_STATUS_UNKNOWN, "absent → UNKNOWN")
    assert_true(
        err.message.startswith(String("missing")), "diagnostic message"
    )


def test_t8_trailer_malformed_decimal() raises:
    """T8 — malformed decimal `grpc-status` → UNKNOWN."""
    var tr = HeaderMap()
    tr.append(String("grpc-status"), String("abc"))
    var err = parse_grpc_status_trailers(tr)
    assert_equal(err.code, GRPC_STATUS_UNKNOWN, "malformed → UNKNOWN")
    assert_true(
        err.message.startswith(String("malformed")), "diagnostic message"
    )


def test_t9_initial_headers_branch() raises:
    """T9 — parse_grpc_status_initial_headers Some/None branches."""
    # Trailers-only response — initial HEADERS carries grpc-status
    var hdrs = HeaderMap()
    hdrs.append(String(":status"), String("200"))
    hdrs.append(String("grpc-status"), String("7"))  # PermissionDenied
    var maybe_err = parse_grpc_status_initial_headers(hdrs)
    assert_true(maybe_err.__bool__(), "Some on trailers-only response")
    var err = maybe_err.take()
    assert_equal(err.code, GRPC_STATUS_PERMISSION_DENIED, "code 7")

    # Normal case — initial HEADERS has no grpc-status
    var hdrs2 = HeaderMap()
    hdrs2.append(String(":status"), String("200"))
    hdrs2.append(String("content-type"), String("application/grpc+proto"))
    var maybe_err2 = parse_grpc_status_initial_headers(hdrs2)
    assert_false(maybe_err2.__bool__(), "None on normal initial headers")


def test_t10_http_non_200_synthesis() raises:
    """T10 — HTTP non-200 → the spec's mapped status, status in the message.

    ⚠ NOT `502 -> UNKNOWN(2)`. `grpc/doc/http-grpc-status-mapping.md` ("HTTP to gRPC
    Status Code Mapping") and grpc-go's `HTTPStatusConvTab`
    (`internal/transport/http_util.go`) BOTH map 502 Bad Gateway to
    UNAVAILABLE(14); UNKNOWN is what the spec assigns to a status NOT in the
    table, which 502 is not.

    The consequence is not cosmetic: `RetryPolicy.idempotent()` carries
    `RETRY_CODES_AIP194` = UNAVAILABLE alone, so with every non-200 collapsed
    to UNKNOWN the whole edge-proxy failure class — including a front end's
    503/504 — would never be retried.

    The out-of-table polarity (405/415/418/500/505 -> UNKNOWN) is asserted in
    `test_grpc_status_metadata_conformance.mojo`, so removing UNKNOWN from
    this row does not remove it from the suite.
    """
    var err = grpc_error_from_http_non_200(UInt16(502))
    assert_equal(err.code, GRPC_STATUS_UNAVAILABLE, "502 -> UNAVAILABLE(14)")
    assert_true(
        grpc_error_from_http_non_200(UInt16(418)).code == GRPC_STATUS_UNKNOWN,
        "a status OUTSIDE the table is still UNKNOWN",
    )
    # Diagnostic message contains the actual HTTP status
    var pos = -1
    var needle = String("502")
    var hay_len = err.message.byte_length()
    var needle_len = needle.byte_length()
    var i = 0
    while i + needle_len <= hay_len:
        var matches = True
        var j = 0
        while j < needle_len:
            if ord(err.message[byte=i + j]) != ord(needle[byte=j]):
                matches = False
                break
            j = j + 1
        if matches:
            pos = i
            break
        i = i + 1
    assert_true(pos >= 0, "message contains the HTTP status code")


def test_t11_from_connect_envelope() raises:
    """T11 — ConnectErrorEnvelope → GrpcError pass-through."""
    var env = ConnectErrorEnvelope(GRPC_STATUS_NOT_FOUND, String("missing"))
    var err = from_connect_error_envelope(env)
    assert_equal(err.code, GRPC_STATUS_NOT_FOUND, "code preserved")
    assert_equal(err.message, String("missing"), "msg preserved")


def test_t12_multi_digit_code() raises:
    """T12 — parse_grpc_error_message handles multi-digit codes."""
    var s = format_grpc_error_message(GRPC_STATUS_UNAVAILABLE, String("503"))
    var parsed = parse_grpc_error_message(s)
    assert_equal(parsed[0], GRPC_STATUS_UNAVAILABLE, "code 14 parses")
    assert_equal(parsed[1], String("503"), "msg")


def main() raises:
    test_t1_constructors()
    test_t2_format_parse_round_trip()
    test_t3_parse_tolerance()
    test_t4_trailer_ok()
    test_t5_trailer_non_ok_plain_message()
    test_t6_trailer_percent_decoded_message()
    test_t7_trailer_missing_status()
    test_t8_trailer_malformed_decimal()
    test_t9_initial_headers_branch()
    test_t10_http_non_200_synthesis()
    test_t11_from_connect_envelope()
    test_t12_multi_digit_code()
    print("test_L5_error: 12/12 PASS")
