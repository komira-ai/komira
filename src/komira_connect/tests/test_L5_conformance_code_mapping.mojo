# =============================================================================
# test_L5_conformance_code_mapping.mojo — Connect conformance: code → HTTP +
# error-name round-trip, pinned to the connectrpc/conformance oracle.
# =============================================================================
#
# The full `connectrpc/conformance` matrix requires a live HTTP endpoint
# (the oracle is a separate process that drives real RPCs over TCP against
# a conformance client/server binary implementing the ConformanceService
# proto across all 4 streaming modes). This test does not run that live
# oracle.
#
# What IS extractable + bounded: the oracle's authoritative Connect
# `code → HTTP status` mapping table, materialized in its embedded
# `connect_client_code_to_http_code.yaml` test suite and cross-checked
# against https://connectrpc.com/docs/protocol/#error-codes. This test pins
# `komira_connect.grpc_status_to_http_status` against that exact table, plus
# the Connect error-name round-trip (`grpc_status_to_connect_name` ⇄
# `connect_name_to_grpc_status`).
#
# The conformance table values below were extracted from
# connectrpc.com/conformance@v1.0.5
#   internal/app/connectconformance/testsuites/data/connect_client_code_to_http_code.yaml
# and confirmed against the Connect protocol spec error-codes table.
#
# It regression-pins the two rows where the obvious HTTP choice is wrong:
#   - CANCELLED: the oracle requires 499 (Client Closed Request), not 408.
#   - FAILED_PRECONDITION: the oracle requires 400 (Bad Request), not 412.
# =============================================================================

from std.testing import assert_equal

from komira_connect.status import (
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
)


def test_connect_code_to_http_status_matches_oracle() raises:
    """Pin every gRPC code → HTTP status against the connectrpc/conformance
    `connect_client_code_to_http_code` oracle table."""
    # code -> expected HTTP status (oracle table, verbatim).
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_CANCELLED), UInt16(499), "canceled -> 499")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_UNKNOWN), UInt16(500), "unknown -> 500")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_INVALID_ARGUMENT), UInt16(400), "invalid_argument -> 400")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_DEADLINE_EXCEEDED), UInt16(504), "deadline_exceeded -> 504")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_NOT_FOUND), UInt16(404), "not_found -> 404")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_ALREADY_EXISTS), UInt16(409), "already_exists -> 409")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_PERMISSION_DENIED), UInt16(403), "permission_denied -> 403")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_RESOURCE_EXHAUSTED), UInt16(429), "resource_exhausted -> 429")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_FAILED_PRECONDITION), UInt16(400), "failed_precondition -> 400")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_ABORTED), UInt16(409), "aborted -> 409")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_OUT_OF_RANGE), UInt16(400), "out_of_range -> 400")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_UNIMPLEMENTED), UInt16(501), "unimplemented -> 501")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_INTERNAL), UInt16(500), "internal -> 500")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_UNAVAILABLE), UInt16(503), "unavailable -> 503")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_DATA_LOSS), UInt16(500), "data_loss -> 500")
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_UNAUTHENTICATED), UInt16(401), "unauthenticated -> 401")
    # OK stays 200 (not part of the error table but a sanity anchor).
    assert_equal(grpc_status_to_http_status(GRPC_STATUS_OK), UInt16(200), "ok -> 200")
    # Unrecognized (>16) maps to 500 INTERNAL.
    assert_equal(grpc_status_to_http_status(UInt8(200)), UInt16(500), "unrecognized -> 500")


def test_connect_error_name_round_trip() raises:
    """Every gRPC code → Connect error-name → gRPC code must round-trip,
    and the spellings must match the Connect spec (notably "canceled" with
    one L, which the conformance oracle uses)."""
    var codes = List[UInt8]()
    codes.append(GRPC_STATUS_CANCELLED)
    codes.append(GRPC_STATUS_UNKNOWN)
    codes.append(GRPC_STATUS_INVALID_ARGUMENT)
    codes.append(GRPC_STATUS_DEADLINE_EXCEEDED)
    codes.append(GRPC_STATUS_NOT_FOUND)
    codes.append(GRPC_STATUS_ALREADY_EXISTS)
    codes.append(GRPC_STATUS_PERMISSION_DENIED)
    codes.append(GRPC_STATUS_RESOURCE_EXHAUSTED)
    codes.append(GRPC_STATUS_FAILED_PRECONDITION)
    codes.append(GRPC_STATUS_ABORTED)
    codes.append(GRPC_STATUS_OUT_OF_RANGE)
    codes.append(GRPC_STATUS_UNIMPLEMENTED)
    codes.append(GRPC_STATUS_INTERNAL)
    codes.append(GRPC_STATUS_UNAVAILABLE)
    codes.append(GRPC_STATUS_DATA_LOSS)
    codes.append(GRPC_STATUS_UNAUTHENTICATED)
    for i in range(len(codes)):
        var code = codes[i]
        var name = grpc_status_to_connect_name(code)
        var back = connect_name_to_grpc_status(name)
        assert_equal(back, code, "round-trip code " + String(Int(code)))
    # Specific spelling anchors the oracle relies on.
    assert_equal(grpc_status_to_connect_name(GRPC_STATUS_CANCELLED), String("canceled"), "canceled spelling (one L)")
    assert_equal(grpc_status_to_connect_name(GRPC_STATUS_FAILED_PRECONDITION), String("failed_precondition"), "failed_precondition spelling")


def main() raises:
    test_connect_code_to_http_status_matches_oracle()
    test_connect_error_name_round_trip()
    print("test_L5_conformance_code_mapping: 2/2 PASS (oracle code->HTTP + name round-trip)")
