# A non-2xx answer from IAM raises through komira_gcp_core's
# `gcp_status_error`: the error names the verb, the RPC, the HTTP status
# and the canonical code (from the `google.rpc.Status` envelope's `status`,
# else from the HTTP status) and counts bytes. It never repeats a byte of
# the body: an IAM error `message` names projects, accounts and members,
# and each test checks such a string is absent.
#
# The envelopes are hand-written in the form the Cloud APIs error model
# documents (`{"error": {"code", "message", "status", "details"}}`). The
# stale-etag answer is the one a read-modify-write meets when the policy
# changed after its read: 409 with status ABORTED, which a caller tells
# apart by its code and answers by reading again. Through komira_http_core's
# ScriptedConnector; no socket.
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_iam.iam import GetServiceAccountRequest, IAMClient
from komira_gcp_iam.iam_policy import SetIamPolicyRequest
from komira_gcp_iam.policy import AuditConfig, Binding, Policy
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


comptime _RT = BlockingRuntime[NoopSink]
comptime _SA = "projects/private-project/serviceAccounts/private-runner@private-project.iam.gserviceaccount.com"


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
) raises -> IAMClient[ScriptedConnector, StaticTokenSource]:
    var c = IAMClient[ScriptedConnector, StaticTokenSource](
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
        _ = c.get_service_account[_RT](GetServiceAccountRequest(String(_SA)), reactor)
    except e:
        return String(e)
    raise Error("get_service_account returned on a non-2xx answer")


def _set_raised(var answer: List[UInt8]) raises -> String:
    var c = _client(answer^)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var members = List[String]()
    members.append(String("user:private-owner@example.com"))
    var bindings = List[Binding]()
    bindings.append(Binding(String("roles/iam.serviceAccountUser"), members^, None))
    var etag: List[UInt8] = [0x07, 0x05, 0xE1, 0xA8, 0x3B, 0x95, 0x27, 0xC8]
    var p = Policy(Int32(3), bindings^, List[AuditConfig](), etag^)
    try:
        _ = c.set_iam_policy[_RT](SetIamPolicyRequest(String(_SA), p^, None), reactor)
    except e:
        return String(e)
    raise Error("set_iam_policy returned on a non-2xx answer")


def test_not_found() raises:
    var body = String(
        '{"error":{"code":404,"message":"Unknown service account",'
        + '"status":"NOT_FOUND"}}'
    )
    var got = _get_raised(_answer("404 Not Found", body))
    assert_equal(
        got,
        String("GET GetServiceAccount: HTTP 404, NOT_FOUND (code 5), error.message 23 bytes, body ")
        + String(body.byte_length())
        + " bytes",
    )
    assert_false("Unknown" in got)


def test_permission_denied_names_no_principal() raises:
    var body = String(
        '{"error":{"code":403,"message":"Permission'
        + " 'iam.serviceAccounts.get' denied on resource (or it may not exist)."
        + '","status":"PERMISSION_DENIED","details":[{"@type":'
        + '"type.googleapis.com/google.rpc.ErrorInfo","reason":"IAM_PERMISSION_DENIED",'
        + '"domain":"iam.googleapis.com","metadata":{"permission":'
        + '"iam.serviceAccounts.get","resource":"' + _SA + '"}}]}}'
    )
    var got = _get_raised(_answer("403 Forbidden", body))
    assert_true(
        got.startswith("GET GetServiceAccount: HTTP 403, PERMISSION_DENIED (code 7), "),
        got,
    )
    assert_false("private" in got)
    assert_false("iam.serviceAccounts.get" in got)


def test_a_stale_etag_is_aborted() raises:
    # The policy changed after the read this write's etag came from.
    var body = String(
        '{"error":{"code":409,"message":"There were concurrent policy changes.'
        + ' Please retry the whole read-modify-write with exponential backoff.",'
        + '"status":"ABORTED"}}'
    )
    var got = _set_raised(_answer("409 Conflict", body))
    assert_true(
        got.startswith("POST SetIamPolicy: HTTP 409, ABORTED (code 10), "), got
    )
    assert_false("concurrent" in got)
    assert_false("private" in got)


def test_status_from_http_when_there_is_no_envelope() raises:
    var body = String("<html><body>upstream connect error</body></html>")
    var got = _get_raised(_answer("503 Service Unavailable", body))
    assert_equal(
        got,
        String("GET GetServiceAccount: HTTP 503, UNAVAILABLE (code 14), ")
        + "body is not a JSON document, body "
        + String(body.byte_length())
        + " bytes",
    )


def main() raises:
    test_not_found()
    test_permission_denied_names_no_principal()
    test_a_stale_etag_is_aborted()
    test_status_from_http_when_there_is_no_envelope()
    print("OK")
