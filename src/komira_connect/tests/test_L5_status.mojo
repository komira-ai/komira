# =============================================================================
# test_L5_status.mojo — gRPC canonical 17-code status mapping
# =============================================================================
#
# Status code mapping, per the Connect-RPC spec
# (https://connectrpc.com/docs/protocol/#error-codes).
#
# Coverage:
#   T1   grpc → HTTP status — all 17 canonical codes match the spec table.
#   T2   grpc → Connect name — all 17 canonical codes match the spec strings.
#   T3   Connect name → grpc — reverse mapping (round-trip identity).
#   T4   Unknown name → UNKNOWN code (fallback for malformed input).
#   T5   Unknown gRPC code (>16) → HTTP 500 + "unknown" name (fallback).
#   T6   format_connect_error + parse_connect_error round-trip.
#   T7   parse_connect_error rejects malformed prefix (fallback to UNKNOWN +
#        full text).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_connect import (
    GRPC_STATUS_OK,
    GRPC_STATUS_CANCELLED,
    GRPC_STATUS_UNKNOWN,
    GRPC_STATUS_INVALID_ARGUMENT,
    GRPC_STATUS_DEADLINE_EXCEEDED,
    GRPC_STATUS_NOT_FOUND,
    GRPC_STATUS_ALREADY_EXISTS,
    GRPC_STATUS_PERMISSION_DENIED,
    GRPC_STATUS_RESOURCE_EXHAUSTED,
    GRPC_STATUS_FAILED_PRECONDITION,
    GRPC_STATUS_ABORTED,
    GRPC_STATUS_OUT_OF_RANGE,
    GRPC_STATUS_UNIMPLEMENTED,
    GRPC_STATUS_INTERNAL,
    GRPC_STATUS_UNAVAILABLE,
    GRPC_STATUS_DATA_LOSS,
    GRPC_STATUS_UNAUTHENTICATED,
    grpc_status_to_http_status,
    grpc_status_to_connect_name,
    connect_name_to_grpc_status,
    format_connect_error,
    parse_connect_error,
)


def test_t1_grpc_to_http_status() raises:
    """T1 — gRPC code → HTTP status; all 17 codes match Connect spec."""
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_OK), UInt16(200), "OK")
    # Connect spec maps canceled → 499 (Client Closed Request), not 408.
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_CANCELLED), UInt16(499), "CANCELLED")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_UNKNOWN), UInt16(500), "UNKNOWN")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_INVALID_ARGUMENT), UInt16(400), "INVALID_ARGUMENT")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_DEADLINE_EXCEEDED), UInt16(504), "DEADLINE_EXCEEDED")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_NOT_FOUND), UInt16(404), "NOT_FOUND")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_ALREADY_EXISTS), UInt16(409), "ALREADY_EXISTS")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_PERMISSION_DENIED), UInt16(403), "PERMISSION_DENIED")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_RESOURCE_EXHAUSTED), UInt16(429), "RESOURCE_EXHAUSTED")
    # Connect spec maps failed_precondition → 400 (Bad Request), not 412.
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_FAILED_PRECONDITION), UInt16(400), "FAILED_PRECONDITION")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_ABORTED), UInt16(409), "ABORTED")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_OUT_OF_RANGE), UInt16(400), "OUT_OF_RANGE")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_UNIMPLEMENTED), UInt16(501), "UNIMPLEMENTED")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_INTERNAL), UInt16(500), "INTERNAL")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_UNAVAILABLE), UInt16(503), "UNAVAILABLE")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_DATA_LOSS), UInt16(500), "DATA_LOSS")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_UNAUTHENTICATED), UInt16(401), "UNAUTHENTICATED")


def test_t2_grpc_to_connect_name() raises:
    """T2 — gRPC code → Connect-JSON error name; all 17 match."""
    assert_equal(grpc_status_to_connect_name(GRPC_STATUS_OK), String(""), "OK")
    assert_equal(grpc_status_to_connect_name(GRPC_STATUS_CANCELLED), String("canceled"), "CANCELLED uses US spelling")
    assert_equal(grpc_status_to_connect_name(GRPC_STATUS_UNKNOWN), String("unknown"), "UNKNOWN")
    assert_equal(grpc_status_to_connect_name(GRPC_STATUS_INVALID_ARGUMENT), String("invalid_argument"), "INVALID_ARGUMENT")
    assert_equal(grpc_status_to_connect_name(GRPC_STATUS_DEADLINE_EXCEEDED), String("deadline_exceeded"), "DEADLINE_EXCEEDED")
    assert_equal(grpc_status_to_connect_name(GRPC_STATUS_NOT_FOUND), String("not_found"), "NOT_FOUND")
    assert_equal(grpc_status_to_connect_name(GRPC_STATUS_ALREADY_EXISTS), String("already_exists"), "ALREADY_EXISTS")
    assert_equal(grpc_status_to_connect_name(GRPC_STATUS_PERMISSION_DENIED), String("permission_denied"), "PERMISSION_DENIED")
    assert_equal(grpc_status_to_connect_name(GRPC_STATUS_RESOURCE_EXHAUSTED), String("resource_exhausted"), "RESOURCE_EXHAUSTED")
    assert_equal(grpc_status_to_connect_name(GRPC_STATUS_FAILED_PRECONDITION), String("failed_precondition"), "FAILED_PRECONDITION")
    assert_equal(grpc_status_to_connect_name(GRPC_STATUS_ABORTED), String("aborted"), "ABORTED")
    assert_equal(grpc_status_to_connect_name(GRPC_STATUS_OUT_OF_RANGE), String("out_of_range"), "OUT_OF_RANGE")
    assert_equal(grpc_status_to_connect_name(GRPC_STATUS_UNIMPLEMENTED), String("unimplemented"), "UNIMPLEMENTED")
    assert_equal(grpc_status_to_connect_name(GRPC_STATUS_INTERNAL), String("internal"), "INTERNAL")
    assert_equal(grpc_status_to_connect_name(GRPC_STATUS_UNAVAILABLE), String("unavailable"), "UNAVAILABLE")
    assert_equal(grpc_status_to_connect_name(GRPC_STATUS_DATA_LOSS), String("data_loss"), "DATA_LOSS")
    assert_equal(grpc_status_to_connect_name(GRPC_STATUS_UNAUTHENTICATED), String("unauthenticated"), "UNAUTHENTICATED")


def test_t3_connect_name_to_grpc() raises:
    """T3 — Connect-JSON name → gRPC code; reverse mapping is identity."""
    # Round-trip via the table: gRPC → name → gRPC for codes 1..16.
    assert_equal(connect_name_to_grpc_status(String("canceled")), GRPC_STATUS_CANCELLED, "canceled")
    assert_equal(connect_name_to_grpc_status(String("unknown")), GRPC_STATUS_UNKNOWN, "unknown")
    assert_equal(connect_name_to_grpc_status(String("invalid_argument")), GRPC_STATUS_INVALID_ARGUMENT, "invalid_argument")
    assert_equal(connect_name_to_grpc_status(String("deadline_exceeded")), GRPC_STATUS_DEADLINE_EXCEEDED, "deadline_exceeded")
    assert_equal(connect_name_to_grpc_status(String("not_found")), GRPC_STATUS_NOT_FOUND, "not_found")
    assert_equal(connect_name_to_grpc_status(String("already_exists")), GRPC_STATUS_ALREADY_EXISTS, "already_exists")
    assert_equal(connect_name_to_grpc_status(String("permission_denied")), GRPC_STATUS_PERMISSION_DENIED, "permission_denied")
    assert_equal(connect_name_to_grpc_status(String("resource_exhausted")), GRPC_STATUS_RESOURCE_EXHAUSTED, "resource_exhausted")
    assert_equal(connect_name_to_grpc_status(String("failed_precondition")), GRPC_STATUS_FAILED_PRECONDITION, "failed_precondition")
    assert_equal(connect_name_to_grpc_status(String("aborted")), GRPC_STATUS_ABORTED, "aborted")
    assert_equal(connect_name_to_grpc_status(String("out_of_range")), GRPC_STATUS_OUT_OF_RANGE, "out_of_range")
    assert_equal(connect_name_to_grpc_status(String("unimplemented")), GRPC_STATUS_UNIMPLEMENTED, "unimplemented")
    assert_equal(connect_name_to_grpc_status(String("internal")), GRPC_STATUS_INTERNAL, "internal")
    assert_equal(connect_name_to_grpc_status(String("unavailable")), GRPC_STATUS_UNAVAILABLE, "unavailable")
    assert_equal(connect_name_to_grpc_status(String("data_loss")), GRPC_STATUS_DATA_LOSS, "data_loss")
    assert_equal(connect_name_to_grpc_status(String("unauthenticated")), GRPC_STATUS_UNAUTHENTICATED, "unauthenticated")


def test_t4_unknown_name_fallback() raises:
    """T4 — unrecognized error name → UNKNOWN code."""
    assert_equal(connect_name_to_grpc_status(String("bogus_name")), GRPC_STATUS_UNKNOWN, "bogus_name")
    assert_equal(connect_name_to_grpc_status(String("")), GRPC_STATUS_UNKNOWN, "empty string")
    assert_equal(connect_name_to_grpc_status(String("OK")), GRPC_STATUS_UNKNOWN, "OK (wrong case)")


def test_t5_unknown_grpc_code_fallback() raises:
    """T5 — unknown gRPC code (>16) → HTTP 500 + "unknown" name."""
    assert_equal(grpc_status_to_http_status(UInt8(99)), UInt16(500), "code 99 → 500")
    assert_equal(grpc_status_to_connect_name(UInt8(99)), String("unknown"), "code 99 → unknown")
    assert_equal(grpc_status_to_http_status(UInt8(17)), UInt16(500), "code 17 → 500 (next-after-last)")


def test_t6_format_parse_round_trip() raises:
    """T6 — format_connect_error + parse_connect_error round-trip."""
    var formatted = format_connect_error(GRPC_STATUS_NOT_FOUND, String("user 42 not found"))
    assert_equal(formatted, String("[connect:5] user 42 not found"), "formatted shape")

    var parsed = parse_connect_error(formatted)
    assert_equal(parsed[0], GRPC_STATUS_NOT_FOUND, "round-trip code")
    assert_equal(parsed[1], String("user 42 not found"), "round-trip message")

    # Multi-digit code: UNAUTHENTICATED = 16
    var f2 = format_connect_error(GRPC_STATUS_UNAUTHENTICATED, String("bad token"))
    var p2 = parse_connect_error(f2)
    assert_equal(p2[0], GRPC_STATUS_UNAUTHENTICATED, "multi-digit code")
    assert_equal(p2[1], String("bad token"), "multi-digit msg")


def test_t7_parse_malformed_prefix() raises:
    """T7 — malformed prefix → fallback to UNKNOWN + full text."""
    # No prefix
    var p1 = parse_connect_error(String("plain error message"))
    assert_equal(p1[0], GRPC_STATUS_UNKNOWN, "no prefix → UNKNOWN")
    assert_equal(p1[1], String("plain error message"), "no prefix → full text")

    # Half-prefix
    var p2 = parse_connect_error(String("[connect:5"))
    assert_equal(p2[0], GRPC_STATUS_UNKNOWN, "no closing bracket → UNKNOWN")

    # Non-digit code
    var p3 = parse_connect_error(String("[connect:abc] msg"))
    assert_equal(p3[0], GRPC_STATUS_UNKNOWN, "non-digit code → UNKNOWN")

    # Empty code
    var p4 = parse_connect_error(String("[connect:] msg"))
    assert_equal(p4[0], GRPC_STATUS_UNKNOWN, "empty code → UNKNOWN")


def main() raises:
    test_t1_grpc_to_http_status()
    test_t2_grpc_to_connect_name()
    test_t3_connect_name_to_grpc()
    test_t4_unknown_name_fallback()
    test_t5_unknown_grpc_code_fallback()
    test_t6_format_parse_round_trip()
    test_t7_parse_malformed_prefix()
    print("test_L5_status: 7/7 PASS")
