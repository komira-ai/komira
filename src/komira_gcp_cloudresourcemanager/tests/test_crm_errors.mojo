# A non-2xx answer from Resource Manager raises through komira_gcp_core's
# `gcp_status_error`: the error names the verb, the RPC, the HTTP status
# and the canonical code (from the `google.rpc.Status` envelope's `status`,
# else from the HTTP status), and counts bytes without repeating any: a
# Resource Manager error `message` names projects and principals.
#
# The envelopes are hand-written in the form the Cloud APIs error model
# documents. The stale-etag answer is what a read-modify-write meets when
# the project's policy changed after its read: 409 with status ABORTED,
# which the caller tells apart by its code and answers by reading again.
# Through komira_http_core's ScriptedConnector; no socket.
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_cloudresourcemanager.iam_policy import SetIamPolicyRequest
from komira_gcp_cloudresourcemanager.policy import AuditConfig, Binding, Policy
from komira_gcp_cloudresourcemanager.projects import GetProjectRequest, ProjectsClient
from komira_gcp_core import StaticTokenSource
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


comptime _RT = BlockingRuntime[NoopSink]


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
) raises -> ProjectsClient[ScriptedConnector, StaticTokenSource]:
    var c = ProjectsClient[ScriptedConnector, StaticTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(ScriptedStream.from_read_script(answer^))
        ),
        StaticTokenSource(String("test-access-token")),
    )
    c.set_rest_host(String("localhost"))
    return c^


def _get_raised(var answer: List[UInt8]) raises -> String:
    var c = _client(answer^)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    try:
        _ = c.get_project[_RT](GetProjectRequest(String("projects/private-project")), reactor)
    except e:
        return String(e)
    raise Error("get_project returned on a non-2xx answer")


def _set_raised(var answer: List[UInt8]) raises -> String:
    var c = _client(answer^)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var members = List[String]()
    members.append(String("user:private-owner@example.com"))
    var bindings = List[Binding]()
    bindings.append(Binding(String("roles/viewer"), members^, None))
    var etag: List[UInt8] = [0x07, 0x05, 0xE1, 0xA8, 0x3B, 0x95, 0x27, 0xC8]
    var p = Policy(Int32(1), bindings^, List[AuditConfig](), etag^)
    try:
        _ = c.set_iam_policy[_RT](
            SetIamPolicyRequest(String("projects/private-project"), p^, None), reactor
        )
    except e:
        return String(e)
    raise Error("set_iam_policy returned on a non-2xx answer")


def test_permission_denied() raises:
    var body = String(
        '{"error":{"code":403,"message":"The caller does not have permission",'
        + '"status":"PERMISSION_DENIED"}}'
    )
    var got = _get_raised(_answer("403 Forbidden", body))
    assert_equal(
        got,
        String("GET GetProject: HTTP 403, PERMISSION_DENIED (code 7), error.message 35 bytes, body ")
        + String(body.byte_length())
        + " bytes",
    )
    assert_false("caller" in got)
    assert_false("private" in got)


def test_a_stale_etag_is_aborted() raises:
    var body = String(
        '{"error":{"code":409,"message":"There were concurrent policy changes.'
        + ' Please retry the whole read-modify-write with exponential backoff.'
        + ' The request\'s ETag \'BwXhqDuVJ8g=\' did not match the current'
        + ' policy\'s ETag \'BwXhqEc2a1U=\'.","status":"ABORTED"}}'
    )
    var got = _set_raised(_answer("409 Conflict", body))
    assert_true(got.startswith("POST SetIamPolicy: HTTP 409, ABORTED (code 10), "), got)
    assert_false("ETag" in got)
    assert_false("BwXh" in got)


def test_an_invalid_policy_names_its_status_not_the_member() raises:
    var body = String(
        '{"error":{"code":400,"message":"Policy members must be of the form'
        + ' \\"<type>:<value>\\". private-owner","status":"INVALID_ARGUMENT"}}'
    )
    var got = _set_raised(_answer("400 Bad Request", body))
    assert_true(
        got.startswith("POST SetIamPolicy: HTTP 400, INVALID_ARGUMENT (code 3), "), got
    )
    assert_false("private" in got)


def test_status_from_http_when_there_is_no_envelope() raises:
    var got = _get_raised(_answer("502 Bad Gateway", String("")))
    assert_equal(
        got,
        "GET GetProject: HTTP 502, UNAVAILABLE (code 14), no google.rpc.Status"
        " envelope, body 0 bytes",
    )


def main() raises:
    test_permission_denied()
    test_a_stale_etag_is_aborted()
    test_an_invalid_policy_names_its_status_not_the_member()
    test_status_from_http_when_there_is_no_envelope()
    print("OK")
