# =============================================================================
# test_gcp_status.mojo — the google.rpc.Status envelope, read without echo.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_gcp_core import (
    CODE_INVALID_ARGUMENT,
    CODE_NOT_FOUND,
    CODE_PERMISSION_DENIED,
    CODE_UNAVAILABLE,
    CODE_UNKNOWN,
    CODE_UNAUTHENTICATED,
    CODE_RESOURCE_EXHAUSTED,
    CODE_DEADLINE_EXCEEDED,
    CODE_OK,
    CODE_ABORTED,
    CODE_CANCELLED,
    CODE_INTERNAL,
    CODE_UNIMPLEMENTED,
    ENVELOPE_PRESENT,
    ENVELOPE_ABSENT,
    ENVELOPE_MALFORMED,
    CODE_DATA_LOSS,
    GcpGrpcStatusError,
    code_from_grpc_status,
    code_from_http_status,
    code_from_name,
    code_name,
    gcp_grpc_status_error,
    gcp_status_error,
    parse_gcp_status,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _has(hay: String, needle: String) -> Bool:
    return hay.find(needle) >= 0


comptime _SECRET_BODY = (
    '{"error": {"code": 403, "message": "Permission denied on'
    ' projects/acme-secret-project for principal leaked@example.com with'
    ' token ya29.SUPERSECRET", "status": "PERMISSION_DENIED", "details":'
    ' [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason":'
    ' "IAM_PERMISSION_DENIED", "metadata": {"resource": "projects/acme-secret-project"}}]}}'
)


def test_full_envelope_is_classified() raises:
    var body = _bytes(_SECRET_BODY)
    var e = parse_gcp_status("POST", "Logging.ListLogEntries", 403, body)
    assert_equal(e.envelope, ENVELOPE_PRESENT)
    assert_equal(e.envelope_code, 403)
    assert_equal(e.status, "PERMISSION_DENIED")
    assert_equal(e.code(), CODE_PERMISSION_DENIED)
    assert_equal(e.body_bytes, len(body))
    var msg = (
        "Permission denied on projects/acme-secret-project for principal"
        " leaked@example.com with token ya29.SUPERSECRET"
    )
    assert_equal(e.message_bytes, String(msg).byte_length())


def test_the_body_is_never_echoed() raises:
    var body = _bytes(_SECRET_BODY)
    var text = String(gcp_status_error("POST", "Logging.ListLogEntries", 403, body))
    assert_true(_has(text, "POST Logging.ListLogEntries"))
    assert_true(_has(text, "HTTP 403"))
    assert_true(_has(text, "PERMISSION_DENIED (code 7)"))
    assert_true(_has(text, String("body ") + String(len(body)) + " bytes"))
    for leak in [
        "acme-secret-project", "leaked@example.com", "ya29", "SUPERSECRET",
        "Permission denied", "ErrorInfo", "IAM_PERMISSION_DENIED", "{", "\"",
    ]:
        assert_false(_has(text, leak), String("echoed: ") + leak)


def test_malformed_json_is_classified_by_http_status() raises:
    var body = _bytes('<html>upstream ya29.SUPERSECRET connect error</html>')
    var e = parse_gcp_status("GET", "Svc.Get", 503, body)
    assert_equal(e.envelope, ENVELOPE_MALFORMED)
    assert_equal(e.code(), CODE_UNAVAILABLE)
    assert_equal(e.envelope_code, -1)
    assert_equal(e.message_bytes, -1)
    var text = e.message()
    assert_true(_has(text, "body is not a JSON document"))
    assert_false(_has(text, "SUPERSECRET"))
    assert_false(_has(text, "html"))
    # Truncated JSON.
    var t = parse_gcp_status("GET", "Svc.Get", 500, _bytes('{"error": {"code": 500, "status": "INTE'))
    assert_equal(t.envelope, ENVELOPE_MALFORMED)
    assert_equal(t.status, "")


def test_missing_fields_fall_back_to_http_status() raises:
    var e = parse_gcp_status("GET", "Svc.Get", 404, _bytes('{"error": {}}'))
    assert_equal(e.envelope, ENVELOPE_PRESENT)
    assert_equal(e.envelope_code, -1)
    assert_equal(e.status, "")
    assert_equal(e.message_bytes, -1)
    assert_equal(e.code(), CODE_NOT_FOUND)
    assert_true(_has(e.message(), "error.status absent or not a status token"))


def test_wrong_typed_and_smuggling_fields_are_dropped() raises:
    var body = _bytes(
        '{"error": {"code": "403", "message": {"x": 1},'
        ' "status": "PERMISSION_DENIED; see projects/leak"}}'
    )
    var e = parse_gcp_status("GET", "Svc.Get", 401, body)
    assert_equal(e.envelope, ENVELOPE_PRESENT)
    assert_equal(e.envelope_code, -1)
    assert_equal(e.message_bytes, -1)
    assert_equal(e.status, "")
    assert_equal(e.code(), CODE_UNAUTHENTICATED)
    assert_false(_has(e.message(), "leak"))
    # A lower-case or over-long status is not a token either.
    var lower = parse_gcp_status("GET", "S", 400, _bytes('{"error": {"status": "permission_denied"}}'))
    assert_equal(lower.status, "")
    var long_status = String()
    for _ in range(65):
        long_status += "A"
    var over = parse_gcp_status("GET", "S", 400, _bytes('{"error": {"status": "' + long_status + '"}}'))
    assert_equal(over.status, "")
    assert_equal(over.code(), CODE_INVALID_ARGUMENT)


def test_status_name_outranks_http_status() raises:
    # A 429 the server labels UNAVAILABLE is UNAVAILABLE.
    var e = parse_gcp_status("GET", "S", 429, _bytes('{"error": {"code": 429, "status": "UNAVAILABLE"}}'))
    assert_equal(e.code(), CODE_UNAVAILABLE)
    # An unknown token name falls back to the HTTP status.
    var u = parse_gcp_status("GET", "S", 429, _bytes('{"error": {"status": "NOT_A_CODE"}}'))
    assert_equal(u.status, "NOT_A_CODE")
    assert_equal(u.code(), CODE_RESOURCE_EXHAUSTED)


def test_no_envelope_and_empty_body() raises:
    var e = parse_gcp_status("GET", "S", 502, _bytes('{"foo": 1}'))
    assert_equal(e.envelope, ENVELOPE_ABSENT)
    assert_equal(e.code(), CODE_UNAVAILABLE)
    var arr = parse_gcp_status("GET", "S", 500, _bytes('[1, 2]'))
    assert_equal(arr.envelope, ENVELOPE_ABSENT)
    var err_not_obj = parse_gcp_status("GET", "S", 500, _bytes('{"error": "boom ya29.X"}'))
    assert_equal(err_not_obj.envelope, ENVELOPE_ABSENT)
    assert_false(_has(err_not_obj.message(), "ya29"))
    var empty = parse_gcp_status("GET", "S", 504, List[UInt8]())
    assert_equal(empty.envelope, ENVELOPE_ABSENT)
    assert_equal(empty.body_bytes, 0)
    assert_equal(empty.code(), CODE_DEADLINE_EXCEEDED)
    assert_true(_has(empty.message(), "no google.rpc.Status envelope"))


def test_deep_nesting_is_refused_not_recursed() raises:
    var s = String()
    for _ in range(10000):
        s += "["
    var e = parse_gcp_status("GET", "S", 500, _bytes(s))
    assert_equal(e.envelope, ENVELOPE_MALFORMED)
    assert_equal(e.body_bytes, 10000)


def test_non_utf8_message_is_counted_not_decoded() raises:
    var body = _bytes('{"error": {"status": "NOT_FOUND", "message": "')
    body.append(0xFF)
    body.append(0xC3)
    body.append(0xA9)
    for b in String('"}}').as_bytes():
        body.append(b)
    var e = parse_gcp_status("GET", "S", 404, body)
    assert_equal(e.envelope, ENVELOPE_PRESENT)
    assert_equal(e.status, "NOT_FOUND")
    assert_equal(e.message_bytes, 3)


def _nested_envelope(brackets: Int) -> List[UInt8]:
    """A BALANCED, otherwise valid envelope whose deepest point is
    `brackets + 2` (the outer object and `error` are two levels)."""
    var s = String('{"error": {"code": 403, "status": "PERMISSION_DENIED", "x": ')
    for _ in range(brackets):
        s += "["
    for _ in range(brackets):
        s += "]"
    s += "}}"
    return _bytes(s)


def test_balanced_nesting_past_the_limit_is_refused() raises:
    # Depth 65: refused by the depth limit komira_json is called with
    # (MAX_PARSE_DEPTH = 64, below komira_json's own default of 128), so
    # it is MALFORMED.
    var deep = _nested_envelope(63)
    var e = parse_gcp_status("GET", "S", 403, deep)
    assert_equal(e.envelope, ENVELOPE_MALFORMED)
    assert_equal(e.body_bytes, len(deep))
    # Depth 64 exactly is read.
    var at = parse_gcp_status("GET", "S", 403, _nested_envelope(62))
    assert_equal(at.envelope, ENVELOPE_PRESENT)
    assert_equal(at.status, "PERMISSION_DENIED")


def test_brackets_inside_a_string_do_not_count_as_nesting() raises:
    var msg = String()
    for _ in range(150):
        msg += "[{"
    var e = parse_gcp_status(
        "GET", "S", 403,
        _bytes('{"error": {"status": "NOT_FOUND", "message": "' + msg + '"}}'),
    )
    assert_equal(e.envelope, ENVELOPE_PRESENT)
    assert_equal(e.status, "NOT_FOUND")
    assert_equal(e.message_bytes, 300)


def test_escaped_quote_keeps_the_string_open() raises:
    # The depth limit must honour `\"`. Each case is wrong in a DIFFERENT
    # direction under a parser that treats `\"` as the end of the string, so
    # breaking the escape handling reds this test either way.
    #
    # (a) 100 `[` that really sit inside the message, after a `\"`. A guard
    # that ended the string at `\"` would count them and refuse a valid
    # envelope.
    var a = String('{"error": {"status": "NOT_FOUND", "message": "a\\"')
    for _ in range(100):
        a += "["
    a += '"}}'
    var ea = parse_gcp_status("GET", "S", 403, _bytes(a))
    assert_equal(ea.envelope, ENVELOPE_PRESENT)
    assert_equal(ea.status, "NOT_FOUND")
    assert_equal(ea.message_bytes, 102)
    # (b) 100 levels of REAL nesting that such a guard would mis-pair as
    # string content: after `"x\""` it sees one quote too many, opens a string
    # at `"b"`'s closing quote and never closes it, so the brackets go
    # uncounted. The real parser counts them and refuses.
    var b = String('{"error": {"status": "NOT_FOUND", "a": "x\\"", "b": ')
    for _ in range(100):
        b += "["
    for _ in range(100):
        b += "]"
    b += "}}"
    var eb = parse_gcp_status("GET", "S", 403, _bytes(b))
    assert_equal(eb.envelope, ENVELOPE_MALFORMED)
    assert_equal(eb.body_bytes, len(_bytes(b)))


def _padded_envelope(total: Int) -> List[UInt8]:
    """A valid envelope of exactly `total` bytes (the message pads it)."""
    var head = _bytes('{"error": {"status": "NOT_FOUND", "message": "')
    var tail = _bytes('"}}')
    var out = List[UInt8](capacity=total)
    for b in head:
        out.append(b)
    for _ in range(total - len(head) - len(tail)):
        out.append(UInt8(ord("a")))
    for b in tail:
        out.append(b)
    return out^


def test_the_parse_size_cap() raises:
    comptime CAP = 1 << 20
    var at = parse_gcp_status("GET", "S", 404, _padded_envelope(CAP))
    assert_equal(at.envelope, ENVELOPE_PRESENT)
    assert_equal(at.status, "NOT_FOUND")
    assert_equal(at.body_bytes, CAP)
    var over_body = _padded_envelope(CAP + 1)
    var over = parse_gcp_status("GET", "S", 404, over_body)
    assert_equal(over.envelope, ENVELOPE_MALFORMED)
    assert_equal(over.body_bytes, CAP + 1)
    assert_equal(over.status, "")


def test_code_tables() raises:
    # The full google/rpc/code.proto table, both directions.
    var names: List[String] = [
        "OK", "CANCELLED", "UNKNOWN", "INVALID_ARGUMENT", "DEADLINE_EXCEEDED",
        "NOT_FOUND", "ALREADY_EXISTS", "PERMISSION_DENIED",
        "RESOURCE_EXHAUSTED", "FAILED_PRECONDITION", "ABORTED", "OUT_OF_RANGE",
        "UNIMPLEMENTED", "INTERNAL", "UNAVAILABLE", "DATA_LOSS",
        "UNAUTHENTICATED",
    ]
    assert_equal(len(names), 17)
    for c in range(17):
        assert_equal(code_name(c), names[c])
        assert_equal(code_from_name(names[c]), c)
    assert_equal(code_name(17), "")
    assert_equal(code_name(-1), "")
    assert_equal(code_from_name("nope"), -1)
    assert_equal(code_from_name(""), -1)


def test_http_status_mapping() raises:
    # Every row code_from_http_status states.
    assert_equal(code_from_http_status(400), CODE_INVALID_ARGUMENT)
    assert_equal(code_from_http_status(401), CODE_UNAUTHENTICATED)
    assert_equal(code_from_http_status(403), CODE_PERMISSION_DENIED)
    assert_equal(code_from_http_status(404), CODE_NOT_FOUND)
    assert_equal(code_from_http_status(409), CODE_ABORTED)
    assert_equal(code_from_http_status(429), CODE_RESOURCE_EXHAUSTED)
    assert_equal(code_from_http_status(499), CODE_CANCELLED)
    assert_equal(code_from_http_status(500), CODE_INTERNAL)
    assert_equal(code_from_http_status(501), CODE_UNIMPLEMENTED)
    assert_equal(code_from_http_status(502), CODE_UNAVAILABLE)
    assert_equal(code_from_http_status(503), CODE_UNAVAILABLE)
    assert_equal(code_from_http_status(504), CODE_DEADLINE_EXCEEDED)
    # The 2xx bounds.
    assert_equal(code_from_http_status(199), CODE_UNKNOWN)
    assert_equal(code_from_http_status(200), CODE_OK)
    assert_equal(code_from_http_status(299), CODE_OK)
    assert_equal(code_from_http_status(300), CODE_UNKNOWN)
    # Anything else.
    assert_equal(code_from_http_status(418), CODE_UNKNOWN)
    assert_equal(code_from_http_status(505), CODE_UNKNOWN)


def test_grpc_status_mapping() raises:
    # gRPC's codes are google.rpc.Code's, number for number.
    for c in range(17):
        assert_equal(code_from_grpc_status(c), c)
    assert_equal(code_from_grpc_status(14), CODE_UNAVAILABLE)
    assert_equal(code_from_grpc_status(16), CODE_UNAUTHENTICATED)
    assert_equal(code_from_grpc_status(15), CODE_DATA_LOSS)
    # A status gRPC does not define is UNKNOWN.
    assert_equal(code_from_grpc_status(17), CODE_UNKNOWN)
    assert_equal(code_from_grpc_status(99), CODE_UNKNOWN)
    assert_equal(code_from_grpc_status(-1), CODE_UNKNOWN)


def test_grpc_status_error_names_the_code_not_the_text() raises:
    var server_text = String(
        "[grpc:7] Permission denied on projects/acme-secret-project for"
        " leaked@example.com"
    )
    var rpc = String("/google.storage.v2.Storage/ReadObject")
    var e = GcpGrpcStatusError.from_transport_text(rpc, 7, server_text)
    assert_equal(e.code(), CODE_PERMISSION_DENIED)
    assert_equal(e.attempts, 1)
    # What follows the anchor and its space: the grpc-message.
    assert_equal(e.message_bytes, server_text.byte_length() - 9)
    var text = String(gcp_grpc_status_error(rpc, 7, server_text))
    assert_equal(text, e.message())
    assert_equal(
        text,
        String("[grpc:7] gRPC /google.storage.v2.Storage/ReadObject:")
        + " PERMISSION_DENIED (code 7), error text "
        + String(server_text.byte_length() - 9)
        + " bytes",
    )
    for leak in ["acme-secret-project", "leaked@example.com", "Permission denied"]:
        assert_false(_has(text, leak), String("echoed: ") + leak)


def test_grpc_status_error_keeps_a_readable_code_anchor() raises:
    # The anchor carries the google.rpc.Code, at the front, in komira_grpc's
    # `[grpc:N]` shape, so `parse_grpc_status_code` reads the mapped code.
    for status in [5, 14, 16]:
        var text = String(
            gcp_grpc_status_error("/a.B/C", status, String("[grpc:") + String(status) + "] x")
        )
        assert_true(
            text.startswith(String("[grpc:") + String(status) + "] gRPC /a.B/C: "), text
        )
    # A status outside google.rpc.Code is anchored as UNKNOWN.
    assert_true(
        String(gcp_grpc_status_error("/a.B/C", 42, "[grpc:42] x")).startswith(
            "[grpc:2] gRPC /a.B/C: UNKNOWN"
        )
    )


def test_unknown_grpc_status_is_named_as_received() raises:
    var text = String(gcp_grpc_status_error("/a.B/C", 42, "[grpc:42] "))
    assert_equal(
        text,
        "[grpc:2] gRPC /a.B/C: UNKNOWN (code 2), grpc-status 42, error text 0 bytes",
    )


def test_retry_exhaustion_is_stated_and_counts_only_the_last_status_text() raises:
    var last = String("Service unavailable for acme-secret-bucket")
    var text = (
        String("[grpc-retry:EXHAUSTED] gave up replaying /a.B/C after 4")
        + " attempt(s) (policy max_attempts=4, max_backoff_ms=1000); every"
        + " attempt returned a status this method's policy treats as transient."
        + " Last: [grpc:14] "
        + last
    )
    var e = GcpGrpcStatusError.from_transport_text("/a.B/C", 14, text)
    assert_equal(e.attempts, 4)
    assert_equal(e.message_bytes, last.byte_length())
    assert_equal(
        String(gcp_grpc_status_error("/a.B/C", 14, text)),
        String("[grpc:14] gRPC /a.B/C: UNAVAILABLE (code 14), retries exhausted")
        + " after 4 attempts, error text "
        + String(last.byte_length())
        + " bytes",
    )
    # Not an exhaustion error, or one whose count does not read: one attempt.
    assert_equal(
        GcpGrpcStatusError.from_transport_text("/a.B/C", 14, "[grpc:14] after 9").attempts,
        1,
    )
    assert_equal(
        GcpGrpcStatusError.from_transport_text(
            "/a.B/C", 14, "[grpc-retry:EXHAUSTED] gave up after x [grpc:14] y"
        ).attempts,
        1,
    )
    # No anchor at all: the whole text is counted.
    assert_equal(
        GcpGrpcStatusError.from_transport_text("/a.B/C", 2, "abc").message_bytes, 3
    )


def main() raises:
    test_full_envelope_is_classified()
    test_the_body_is_never_echoed()
    test_malformed_json_is_classified_by_http_status()
    test_missing_fields_fall_back_to_http_status()
    test_wrong_typed_and_smuggling_fields_are_dropped()
    test_status_name_outranks_http_status()
    test_no_envelope_and_empty_body()
    test_deep_nesting_is_refused_not_recursed()
    test_balanced_nesting_past_the_limit_is_refused()
    test_brackets_inside_a_string_do_not_count_as_nesting()
    test_escaped_quote_keeps_the_string_open()
    test_the_parse_size_cap()
    test_non_utf8_message_is_counted_not_decoded()
    test_code_tables()
    test_http_status_mapping()
    test_grpc_status_mapping()
    test_grpc_status_error_names_the_code_not_the_text()
    test_grpc_status_error_keeps_a_readable_code_anchor()
    test_unknown_grpc_status_is_named_as_received()
    test_retry_exhaustion_is_stated_and_counts_only_the_last_status_text()
    print("all gcp status tests passed")
