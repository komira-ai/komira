# A non-2xx answer to `entries.list` raises, through komira_gcp_core's
# `gcp_status_error`: the error names the verb, the RPC, the HTTP status
# and the canonical code (from the `google.rpc.Status` envelope's `status`
# when it carries one, else from the HTTP status), and counts bytes. It
# never repeats a byte of the body: an error `message` can name projects,
# principals and filters, and the test checks for each such string.
#
# The envelopes are hand-written in the form the Cloud APIs error model
# documents (`{"error": {"code", "message", "status", "details"}}`); the
# connector is komira_http_core's ScriptedConnector, so no socket is used.
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_logging.logging import (
    ListLogEntriesRequest,
    LoggingServiceV2Client,
)
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


comptime _RT = BlockingRuntime[NoopSink]


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _answer(status_line: String, content_type: String, body: String) -> List[UInt8]:
    return _bytes(
        String("HTTP/1.1 ")
        + status_line
        + "\r\nContent-Type: "
        + content_type
        + "\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _raised(var answer: List[UInt8]) raises -> String:
    """The error `list_log_entries` raises on `answer`; fails if it returns."""
    var http = HttpClient[ScriptedConnector].with_defaults(
        ScriptedConnector.with_stream_tls(ScriptedStream.from_read_script(answer^))
    )
    var c = LoggingServiceV2Client[ScriptedConnector, StaticTokenSource](
        http^, StaticTokenSource(String("test-access-token"))
    )
    var names = List[String]()
    names.append(String("projects/private-project-name"))
    var req = ListLogEntriesRequest(
        names^, String(""), String("timestamp asc"), Int32(10), String("")
    )
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    try:
        _ = c.list_log_entries[_RT](req, reactor)
    except e:
        return String(e)
    raise Error("list_log_entries returned on a non-2xx answer")


def test_permission_denied() raises:
    var body = String(
        '{"error":{"code":403,"message":"Permission'
        + " 'logging.logEntries.list' denied on resource (or it may not"
        + ' exist): projects/private-project-name","status":"PERMISSION_DENIED"}}'
    )
    var msg_bytes = String(
        "Permission 'logging.logEntries.list' denied on resource (or it may"
        + " not exist): projects/private-project-name"
    ).byte_length()
    var got = _raised(_answer("403 Forbidden", "application/json", body))
    assert_equal(
        got,
        String("POST ListLogEntries: HTTP 403, PERMISSION_DENIED (code 7), error.message ")
        + String(msg_bytes)
        + " bytes, body "
        + String(body.byte_length())
        + " bytes",
    )
    assert_false("private-project-name" in got)
    assert_false("logEntries" in got)


def test_invalid_filter_names_its_status_not_the_filter() raises:
    var body = String(
        '{"error":{"code":400,"message":"Unparseable filter: secret_label=\\"x\\"",'
        + '"status":"INVALID_ARGUMENT"}}'
    )
    var got = _raised(_answer("400 Bad Request", "application/json", body))
    assert_true(
        got.startswith("POST ListLogEntries: HTTP 400, INVALID_ARGUMENT (code 3), ")
    )
    assert_false("secret_label" in got)
    assert_false("Unparseable" in got)


def test_quota_with_retry_info() raises:
    # The server's retry delay is reported (in ms, rounded up); the quota
    # metric in `message` is not.
    var body = String(
        '{"error":{"code":429,"message":"Quota exceeded for quota metric'
        + " 'Read requests' of service 'logging.googleapis.com'\","
        + '"status":"RESOURCE_EXHAUSTED","details":[{"@type":'
        + '"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"1.5s"}]}}'
    )
    var got = _raised(_answer("429 Too Many Requests", "application/json", body))
    assert_true(
        got.startswith(
            "POST ListLogEntries: HTTP 429, RESOURCE_EXHAUSTED (code 8), "
        )
    )
    assert_true(got.endswith(", RetryInfo 1500 ms"))
    assert_false("Quota" in got)


def test_status_from_http_when_there_is_no_envelope() raises:
    # A front end's own page, not an API error: the code comes from the
    # HTTP status, and the page is counted, not quoted.
    var body = String("<html><body>upstream connect error</body></html>")
    var got = _raised(_answer("503 Service Unavailable", "text/html", body))
    assert_equal(
        got,
        String("POST ListLogEntries: HTTP 503, UNAVAILABLE (code 14), ")
        + "body is not a JSON document, body "
        + String(body.byte_length())
        + " bytes",
    )
    assert_false("upstream" in got)


def test_empty_error_body() raises:
    var got = _raised(_answer("404 Not Found", "application/json", ""))
    assert_equal(
        got,
        "POST ListLogEntries: HTTP 404, NOT_FOUND (code 5), no google.rpc.Status"
        " envelope, body 0 bytes",
    )


def test_a_redirect_is_not_a_page() raises:
    # The 2xx boundary from above: a 3xx is not success, and no redirect is
    # followed (the client has no redirect layer). 300 is the first status
    # past 2xx; 307 is a front end moving the call, its Location not quoted.
    var got300 = _raised(_answer("300 Multiple Choices", "application/json", ""))
    assert_equal(
        got300,
        "POST ListLogEntries: HTTP 300, UNKNOWN (code 2), no google.rpc.Status"
        " envelope, body 0 bytes",
    )
    var got307 = _raised(
        _bytes(
            String("HTTP/1.1 307 Temporary Redirect\r\n")
            + "Location: https://elsewhere.example/v2/entries:list\r\n"
            + "Content-Length: 0\r\nConnection: close\r\n\r\n"
        )
    )
    assert_equal(
        got307,
        "POST ListLogEntries: HTTP 307, UNKNOWN (code 2), no google.rpc.Status"
        " envelope, body 0 bytes",
    )
    assert_false("elsewhere" in got307)


def test_unauthenticated() raises:
    var body = String(
        '{"error":{"code":401,"message":"Request had invalid authentication'
        + ' credentials.","status":"UNAUTHENTICATED"}}'
    )
    var got = _raised(_answer("401 Unauthorized", "application/json", body))
    assert_true(
        got.startswith("POST ListLogEntries: HTTP 401, UNAUTHENTICATED (code 16), ")
    )
    assert_false("credentials" in got)


def main() raises:
    test_permission_denied()
    test_invalid_filter_names_its_status_not_the_filter()
    test_quota_with_retry_info()
    test_status_from_http_when_there_is_no_envelope()
    test_empty_error_body()
    test_unauthenticated()
    test_a_redirect_is_not_a_page()
    print("OK")
