# A non-2xx answer from Service Usage raises through komira_gcp_core's
# `gcp_status_error`: the error names the verb, the RPC, the HTTP status
# and the canonical code (from the `google.rpc.Status` envelope's `status`,
# else from the HTTP status), and counts bytes without repeating any: a
# Service Usage error `message` names projects and services.
#
# The envelopes are hand-written in the form the Cloud APIs error model
# documents. (A failure that arrives inside a 200, as a finished operation's
# `error`, is read as data: test_serviceusage_services.) Through
# komira_http_core's ScriptedConnector; no socket.
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_serviceusage.serviceusage import (
    EnableServiceRequest,
    GetServiceRequest,
    ServiceUsageClient,
)
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


comptime _RT = BlockingRuntime[NoopSink]
comptime _SVC = "projects/private-project/services/run.googleapis.com"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _answer(status_line: String, body: String) -> List[UInt8]:
    return _bytes(
        String("HTTP/1.1 ")
        + status_line
        + "\r\nContent-Type: application/json\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _client(
    var answer: List[UInt8],
) raises -> ServiceUsageClient[ScriptedConnector, StaticTokenSource]:
    var c = ServiceUsageClient[ScriptedConnector, StaticTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(ScriptedStream.from_read_script(answer^))
        ),
        StaticTokenSource(String("test-access-token")),
    )
    c.set_rest_host(String("localhost"))
    return c^


def _enable_raised(var answer: List[UInt8]) raises -> String:
    var c = _client(answer^)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    try:
        _ = c.enable_service[_RT](EnableServiceRequest(String(_SVC)), reactor)
    except e:
        return String(e)
    raise Error("enable_service returned on a non-2xx answer")


def _get_raised(var answer: List[UInt8]) raises -> String:
    var c = _client(answer^)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    try:
        _ = c.get_service[_RT](GetServiceRequest(String(_SVC)), reactor)
    except e:
        return String(e)
    raise Error("get_service returned on a non-2xx answer")


def test_permission_denied() raises:
    var body = String(
        '{"error":{"code":403,"message":"Permission denied to enable service'
        + ' [run.googleapis.com]","status":"PERMISSION_DENIED","details":[{"@type":'
        + '"type.googleapis.com/google.rpc.ErrorInfo","reason":"AUTH_PERMISSION_DENIED",'
        + '"domain":"serviceusage.googleapis.com","metadata":{"permission":'
        + '"serviceusage.services.enable"}}]}}'
    )
    var got = _enable_raised(_answer("403 Forbidden", body))
    assert_true(
        got.startswith("POST EnableService: HTTP 403, PERMISSION_DENIED (code 7), "),
        got,
    )
    assert_true(got.endswith(String(" bytes, body ") + String(body.byte_length()) + " bytes"), got)
    assert_false("run.googleapis.com" in got)
    assert_false("serviceusage.services" in got)


def test_a_missing_project_is_not_found() raises:
    var body = String(
        '{"error":{"code":404,"message":"Project \'private-project\' not found or'
        + ' permission denied.","status":"NOT_FOUND"}}'
    )
    var got = _get_raised(_answer("404 Not Found", body))
    assert_true(got.startswith("GET GetService: HTTP 404, NOT_FOUND (code 5), "), got)
    assert_false("private" in got)


def test_quota_names_its_retry_delay_only() raises:
    var body = String(
        '{"error":{"code":429,"message":"Quota exceeded for quota metric'
        + ' \'Mutate requests\' of service \'serviceusage.googleapis.com\'",'
        + '"status":"RESOURCE_EXHAUSTED","details":[{"@type":'
        + '"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"2s"}]}}'
    )
    var got = _enable_raised(_answer("429 Too Many Requests", body))
    assert_true(
        got.startswith("POST EnableService: HTTP 429, RESOURCE_EXHAUSTED (code 8), "),
        got,
    )
    assert_true(got.endswith(", RetryInfo 2000 ms"), got)
    assert_false("Quota" in got)


def test_status_from_http_when_there_is_no_envelope() raises:
    var body = String("<html><body>upstream connect error</body></html>")
    var got = _get_raised(_answer("503 Service Unavailable", body))
    assert_equal(
        got,
        String("GET GetService: HTTP 503, UNAVAILABLE (code 14), ")
        + "body is not a JSON document, body "
        + String(body.byte_length())
        + " bytes",
    )


def main() raises:
    test_permission_denied()
    test_a_missing_project_is_not_found()
    test_quota_names_its_retry_delay_only()
    test_status_from_http_when_there_is_no_envelope()
    print("OK")
