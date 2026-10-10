# =============================================================================
# komira_gcp_fcm/tests/test_fcm_outcome.mojo -- what each `messages:send`
#   answer means for its token (outcome.mojo's table), with no body text.
# =============================================================================
#
# The error bodies are the `google.rpc.Status` envelope with an FcmError
# detail, in the shape FCM's v1 reference documents (`error.code`,
# `error.message`, `error.status`, `error.details[]` with
# `@type: type.googleapis.com/google.firebase.fcm.v1.FcmError` and
# `errorCode`). Synthetic: they prove the reading, not that FCM sends them.
#
# Every `error.message` holds the marker SECRET-BODY-TEXT, and each detail is
# asserted whole, so a detail that quoted the body fails.
#
# What each test proves, and the defect it catches:
#   * test_accepted: a 200 is ACCEPTED with the returned `name`.
#   * test_dead: 404 with UNREGISTERED, 404 with no body, and UNREGISTERED
#     on a 400 and on a 503 are DEAD. Catches 404 read as TRANSIENT (the
#     token is never reaped) and a dead check made after the transient one.
#   * test_transient: 429 and 500/502/503 are TRANSIENT, the delay from
#     Retry-After (seconds), else RetryInfo, else -1, and a huge Retry-After
#     clamped. Catches 429 or 503 read as REFUSED, and a delay that ignores
#     the header.
#   * test_refused: 400 INVALID_ARGUMENT, 401 and 403 SENDER_ID_MISMATCH are
#     REFUSED with no delay even when a Retry-After is present. Catches a 403
#     read as DEAD (a wrong project would delete every device).
#   * test_error_code_reading: only an FcmError's own `errorCode`, and only a
#     bare upper-case token, is read; a lower-case `unregistered` or one
#     under another `@type` does not make a token dead.
#   * test_send_failure_outcome: a send with no answer (client.mojo's
#     `send_failure_outcome` over komira_http_client's error text). Every
#     tagged failure but URL_INVALID (TIMEOUT, CONNECT_TIMEOUT,
#     EOF_MID_RESPONSE, RETRYABLE_TRANSPORT) is TRANSIENT, status 0, with the
#     detail keeping only `HttpError[<KIND>]`; an untagged one says
#     `transport error` and keeps no address; URL_INVALID raises the exact
#     refusal. Catches a check widened from URL_INVALID to any
#     `HttpError[` (a timeout would raise and stop a caller's loop over many
#     tokens), and a URL_INVALID read as TRANSIENT (retried forever).
# =============================================================================

from std.testing import assert_equal

from komira_gcp_fcm import (
    FCM_ACCEPTED,
    FCM_DEAD,
    FCM_REFUSED,
    FCM_TRANSIENT,
    FcmOutcome,
    classify_fcm_response,
    fcm_error_code,
    fcm_outcome_name,
    send_failure_outcome,
)


comptime _MSG = "Requested entity SECRET-BODY-TEXT was not found."
comptime _NAME = "projects/example-project-123/messages/0:1790000000000000%31bd1c9631bd1c96"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _envelope(code: Int, status: String, error_code: String, extra: String = String()) -> String:
    var details = String()
    if error_code.byte_length() > 0:
        details = (
            String(',"details":[{"@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError",')
            + '"errorCode":"' + error_code + '"}' + extra + "]"
        )
    return (
        String('{"error":{"code":') + String(code) + ',"message":"' + _MSG
        + '","status":"' + status + '"' + details + "}}"
    )


def _detail(http: Int, code_name: String, code: Int, body: String, fcm: String) -> String:
    """The detail outcome.mojo builds for a full envelope: verb, RPC,
    status, code, the message's byte count and the body's, then the
    FcmError token."""
    var out = (
        String("POST FirebaseMessaging.SendMessage: HTTP ") + String(http) + ", "
        + code_name + " (code " + String(code) + "), error.message "
        + String(String(_MSG).byte_length()) + " bytes, body "
        + String(body.byte_length()) + " bytes"
    )
    if fcm.byte_length() > 0:
        out += ", FcmError " + fcm
    return out^


def _check(
    got: FcmOutcome,
    kind: Int,
    http: Int,
    fcm_error: String,
    retry_ms: Int64,
    detail: String,
    what: String,
) raises:
    assert_equal(fcm_outcome_name(got.kind), fcm_outcome_name(kind), what + ": kind")
    assert_equal(got.http_status, http, what + ": http status")
    assert_equal(got.fcm_error, fcm_error, what + ": FcmError")
    assert_equal(got.retry_after_ms, retry_ms, what + ": retry delay")
    assert_equal(got.detail, detail, what + ": detail")


def test_accepted() raises:
    var got = classify_fcm_response(
        200, -1, _bytes(String('{"name":"') + _NAME + '"}')
    )
    _check(got, FCM_ACCEPTED, 200, String(), -1, String(), "200")
    assert_equal(got.message_name, _NAME)
    assert_equal(classify_fcm_response(200, -1, List[UInt8]()).message_name, "")
    print("  test_accepted PASS")


def test_dead() raises:
    var b404 = _envelope(404, String("NOT_FOUND"), String("UNREGISTERED"))
    _check(
        classify_fcm_response(404, -1, _bytes(b404)),
        FCM_DEAD, 404, String("UNREGISTERED"), -1,
        _detail(404, String("NOT_FOUND"), 5, b404, String("UNREGISTERED")),
        "404 UNREGISTERED",
    )
    _check(
        classify_fcm_response(404, -1, List[UInt8]()),
        FCM_DEAD, 404, String(), -1,
        String("POST FirebaseMessaging.SendMessage: HTTP 404, NOT_FOUND (code 5),")
        + " no google.rpc.Status envelope, body 0 bytes",
        "404 no body",
    )
    var b400 = _envelope(400, String("INVALID_ARGUMENT"), String("UNREGISTERED"))
    _check(
        classify_fcm_response(400, -1, _bytes(b400)),
        FCM_DEAD, 400, String("UNREGISTERED"), -1,
        _detail(400, String("INVALID_ARGUMENT"), 3, b400, String("UNREGISTERED")),
        "400 UNREGISTERED",
    )
    var b503 = _envelope(503, String("UNAVAILABLE"), String("UNREGISTERED"))
    _check(
        classify_fcm_response(503, 9, _bytes(b503)),
        FCM_DEAD, 503, String("UNREGISTERED"), -1,
        _detail(503, String("UNAVAILABLE"), 14, b503, String("UNREGISTERED")),
        "503 UNREGISTERED",
    )
    print("  test_dead PASS")


def test_transient() raises:
    var b429 = _envelope(429, String("RESOURCE_EXHAUSTED"), String("QUOTA_EXCEEDED"))
    _check(
        classify_fcm_response(429, 7, _bytes(b429)),
        FCM_TRANSIENT, 429, String("QUOTA_EXCEEDED"), 7000,
        _detail(429, String("RESOURCE_EXHAUSTED"), 8, b429, String("QUOTA_EXCEEDED")),
        "429 Retry-After 7",
    )
    var retry_info = String(
        ',{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"2.5s"}'
    )
    var b503 = _envelope(503, String("UNAVAILABLE"), String("UNAVAILABLE"), retry_info)
    _check(
        classify_fcm_response(503, -1, _bytes(b503)),
        FCM_TRANSIENT, 503, String("UNAVAILABLE"), 2500,
        _detail(503, String("UNAVAILABLE"), 14, b503, String("UNAVAILABLE"))
            .replace(", FcmError", ", RetryInfo 2500 ms, FcmError"),
        "503 RetryInfo",
    )
    assert_equal(
        classify_fcm_response(503, 3, _bytes(b503)).retry_after_ms,
        3000,
        "Retry-After wins over RetryInfo",
    )
    var b500 = _envelope(500, String("INTERNAL"), String("INTERNAL"))
    _check(
        classify_fcm_response(500, -1, _bytes(b500)),
        FCM_TRANSIENT, 500, String("INTERNAL"), -1,
        _detail(500, String("INTERNAL"), 13, b500, String("INTERNAL")),
        "500",
    )
    _check(
        classify_fcm_response(502, -1, _bytes(String("<html>bad gateway</html>"))),
        FCM_TRANSIENT, 502, String(), -1,
        String("POST FirebaseMessaging.SendMessage: HTTP 502, UNAVAILABLE (code 14),")
        + " body is not a JSON document, body 24 bytes",
        "502 html",
    )
    assert_equal(
        classify_fcm_response(429, 9_000_000_000_000, List[UInt8]()).retry_after_ms,
        1_000_000_000_000,
        "a huge Retry-After is clamped",
    )
    print("  test_transient PASS")


def test_refused() raises:
    var b400 = _envelope(400, String("INVALID_ARGUMENT"), String("INVALID_ARGUMENT"))
    _check(
        classify_fcm_response(400, 30, _bytes(b400)),
        FCM_REFUSED, 400, String("INVALID_ARGUMENT"), -1,
        _detail(400, String("INVALID_ARGUMENT"), 3, b400, String("INVALID_ARGUMENT")),
        "400",
    )
    var b401 = _envelope(401, String("UNAUTHENTICATED"), String())
    _check(
        classify_fcm_response(401, -1, _bytes(b401)),
        FCM_REFUSED, 401, String(), -1,
        _detail(401, String("UNAUTHENTICATED"), 16, b401, String()),
        "401",
    )
    var b403 = _envelope(403, String("PERMISSION_DENIED"), String("SENDER_ID_MISMATCH"))
    _check(
        classify_fcm_response(403, -1, _bytes(b403)),
        FCM_REFUSED, 403, String("SENDER_ID_MISMATCH"), -1,
        _detail(403, String("PERMISSION_DENIED"), 7, b403, String("SENDER_ID_MISMATCH")),
        "403 SENDER_ID_MISMATCH",
    )
    print("  test_refused PASS")


def test_error_code_reading() raises:
    assert_equal(
        fcm_error_code(_bytes(_envelope(400, String("INVALID_ARGUMENT"), String("unregistered")))),
        "",
        "lower case",
    )
    assert_equal(
        fcm_error_code(_bytes(_envelope(400, String("INVALID_ARGUMENT"), String("UNREGISTERED x")))),
        "",
        "not a bare token",
    )
    var other_type = String(
        '{"error":{"code":400,"status":"INVALID_ARGUMENT","details":[{"@type":'
        + '"type.googleapis.com/google.rpc.BadRequest","errorCode":"UNREGISTERED"}]}}'
    )
    assert_equal(fcm_error_code(_bytes(other_type)), "", "another @type")
    assert_equal(
        fcm_outcome_name(classify_fcm_response(400, -1, _bytes(other_type)).kind),
        "REFUSED",
        "an UNREGISTERED under another @type is not DEAD",
    )
    assert_equal(fcm_error_code(_bytes(String("not json"))), "")
    print("  test_error_code_reading PASS")


def _failure_refusal(text: String) -> String:
    try:
        _ = send_failure_outcome(text)
    except e:
        return String(e)
    return String("<not raised>")


def test_send_failure_outcome() raises:
    comptime NO_ANSWER = "POST FirebaseMessaging.SendMessage: no answer, "
    var tagged = List[String]()
    tagged.append(String("TIMEOUT"))
    tagged.append(String("CONNECT_TIMEOUT"))
    tagged.append(String("EOF_MID_RESPONSE"))
    tagged.append(String("RETRYABLE_TRANSPORT"))
    for i in range(len(tagged)):
        var kind = String("HttpError[") + tagged[i] + "]"
        _check(
            send_failure_outcome(kind + ": 127.0.0.1:9 after 30000 ms"),
            FCM_TRANSIENT,
            0,
            "",
            -1,
            String(NO_ANSWER) + kind,
            kind,
        )
    _check(
        send_failure_outcome(String("connect 127.0.0.1:9: errno 111")),
        FCM_TRANSIENT,
        0,
        "",
        -1,
        String(NO_ANSWER) + "transport error",
        "an untagged failure",
    )
    comptime REFUSAL = (
        "komira_gcp_fcm: komira_http_client refused the request URL"
        " (HttpError[URL_INVALID]: the endpoint's scheme and the connector"
        " disagree); nothing was sent"
    )
    assert_equal(
        _failure_refusal(
            String("HttpError[URL_INVALID]: https:// URL requires a TLS connector")
        ),
        REFUSAL,
        "URL_INVALID raises",
    )
    assert_equal(
        _failure_refusal(String("send: HttpError[URL_INVALID]: empty host")),
        REFUSAL,
        "URL_INVALID after a prefix raises",
    )
    print("  test_send_failure_outcome PASS")


def main() raises:
    test_accepted()
    test_dead()
    test_transient()
    test_refused()
    test_error_code_reading()
    test_send_failure_outcome()
    print("PASS komira_gcp_fcm outcome")
