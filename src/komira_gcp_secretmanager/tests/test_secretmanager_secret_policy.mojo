# A secret read and changed in place, and its IAM policy: GetSecret,
# UpdateSecret, GetIamPolicy and SetIamPolicy of the generated
# `SecretManagerServiceClient`, each once: the request it puts on the wire,
# byte for byte (request line, headers, JSON body), and the response it
# reads back. A deploy reads a secret to compare its labels, changes them in
# place, and grants a workload read through the secret's policy.
#
# The expected forms are written here from the Secret Manager v1 REST
# reference (projects.secrets.get, .patch, .getIamPolicy, .setIamPolicy);
# no upstream test body is copied. UpdateSecret's body is the `secret`
# field, its update mask a query parameter; getIamPolicy is a GET with no
# body, its `GetPolicyOptions` in the query; setIamPolicy's body is the
# request less the `resource` its path carries. The connector is
# komira_http_core's ScriptedConnector with a shared write capture; no socket
# is opened. The client is pointed at `localhost` with `set_rest_host`.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_secretmanager.iam_policy import GetIamPolicyRequest, SetIamPolicyRequest
from komira_gcp_secretmanager.options import GetPolicyOptions
from komira_gcp_secretmanager.policy import Policy
from komira_gcp_secretmanager.service import (
    GetSecretRequest,
    SecretManagerServiceClient,
    UpdateSecretRequest,
)
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json


comptime _RT = BlockingRuntime[NoopSink]
comptime _Client = SecretManagerServiceClient[ScriptedConnector, StaticTokenSource]

comptime _NAME = "projects/demo-project/secrets/smtp-password"

# The secret as the service answers it.
comptime _SECRET = (
    '{"name":"projects/123456789012/secrets/smtp-password",'
    + '"replication":{"automatic":{}},"createTime":"2026-09-30T12:00:00Z",'
    + '"labels":{"owner":"deploy"},"etag":"\\"16a0c2\\""}'
)

# A policy granting one workload read: version 3, the etag "BwXhqDuVJ8g=".
comptime _POLICY = (
    '{"version":3,"bindings":[{"role":"roles/secretmanager.secretAccessor",'
    + '"members":["serviceAccount:web@example.com"]}],'
    + '"etag":"BwXhqDuVJ8g="}'
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _ok(body: String) -> List[UInt8]:
    return _bytes(
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _client(capture: ArcPointer[List[UInt8]], answer: String) raises -> _Client:
    var stream = ScriptedStream.from_read_script_with_capture(_ok(answer), capture)
    var c = _Client(
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(stream^)
        ),
        StaticTokenSource(String("test-access-token")),
    )
    c.set_rest_host(String("localhost"))
    return c^


def _wire(capture: ArcPointer[List[UInt8]]) -> String:
    return String(unsafe_from_utf8=Span(capture[]))


def _expected(target: String, body: String = "") -> String:
    """The request as written: komira_http's Host, User-Agent and
    Content-Length, then the client's headers, a content-type only with a
    body, then the body."""
    var out = (
        target
        + " HTTP/1.1\r\n"
        + "Host: localhost\r\n"
        + "User-Agent: komira-http/1.0\r\n"
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\n"
        + "authorization: Bearer test-access-token\r\n"
    )
    if body.byte_length() > 0:
        out += "content-type: application/json\r\n"
    return out + "\r\n" + body


def _check_policy(p: Policy) raises:
    assert_equal(p.version, 3)
    assert_equal(len(p.bindings), 1)
    assert_equal(p.bindings[0].role, "roles/secretmanager.secretAccessor")
    var etag: List[UInt8] = [0x07, 0x05, 0xE1, 0xA8, 0x3B, 0x95, 0x27, 0xC8]
    assert_true(p.etag == etag)


def test_get_secret() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _SECRET)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var s = c.get_secret[_RT](
        decode_json[GetSecretRequest](String('{"name":"') + _NAME + '"}'), reactor
    )
    assert_equal(_wire(capture), _expected(String("GET /v1/") + _NAME))
    assert_equal(s.name, "projects/123456789012/secrets/smtp-password")
    assert_equal(s.labels["owner"], "deploy")
    assert_equal(s.etag, '"16a0c2"')


def test_update_secret() raises:
    # PATCH /v1/{secret.name=...}?updateMask=..., the Secret as the body.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _SECRET)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var s = c.update_secret[_RT](
        decode_json[UpdateSecretRequest](
            String('{"secret":{"name":"')
            + _NAME
            + '","labels":{"owner":"deploy"}},"updateMask":"labels"}'
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            String("PATCH /v1/") + _NAME + "?updateMask=labels",
            String('{"name":"') + _NAME + '","labels":{"owner":"deploy"}}',
        ),
    )
    assert_equal(s.labels["owner"], "deploy")


def test_get_iam_policy() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _POLICY)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var p = c.get_iam_policy[_RT](
        GetIamPolicyRequest(
            String(_NAME), Optional[GetPolicyOptions](GetPolicyOptions(Int32(3)))
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            String("GET /v1/") + _NAME + ":getIamPolicy?options.requestedPolicyVersion=3"
        ),
    )
    _check_policy(p)


def test_set_iam_policy() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, _POLICY)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var p = c.set_iam_policy[_RT](
        SetIamPolicyRequest(String(_NAME), decode_json[Policy](_POLICY), None),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            String("POST /v1/") + _NAME + ":setIamPolicy",
            String('{"policy":') + _POLICY + "}",
        ),
    )
    _check_policy(p)


def main() raises:
    test_get_secret()
    test_update_secret()
    test_get_iam_policy()
    test_set_iam_policy()
    print("OK")
