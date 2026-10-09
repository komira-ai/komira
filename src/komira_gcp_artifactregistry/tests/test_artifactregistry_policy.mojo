# A repository's IAM policy through the generated `ArtifactRegistryClient`:
# GetIamPolicy and SetIamPolicy, each once: the request it puts on the wire,
# byte for byte (request line, headers, JSON body), and the policy it reads
# back. A cell's bootstrap reads its image repository's policy and writes
# it back with the cell's runtime granted pull, sending the etag it read.
#
# The forms are written here from the Artifact Registry v1 REST reference
# (projects.locations.repositories.getIamPolicy, .setIamPolicy); no
# upstream test body is copied. getIamPolicy is a GET with no body, so its
# `GetPolicyOptions` rides the query as `options.requestedPolicyVersion`;
# setIamPolicy's body is the request less the `resource` its path carries.
# The connector is komira_http_core's ScriptedConnector with a shared write
# capture; no socket is opened. The client is pointed at `localhost`.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_artifactregistry.iam_policy import (
    GetIamPolicyRequest,
    SetIamPolicyRequest,
)
from komira_gcp_artifactregistry.options import GetPolicyOptions
from komira_gcp_artifactregistry.policy import Policy
from komira_gcp_artifactregistry.service import ArtifactRegistryClient
from komira_gcp_core import StaticTokenSource
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json


comptime _RT = BlockingRuntime[NoopSink]
comptime _Client = ArtifactRegistryClient[ScriptedConnector, StaticTokenSource]

comptime _REPO = "projects/demo-project/locations/us-central1/repositories/images"

# The policy a read answers with: the runtime's pull, version 3, the etag
# "BwXhqDuVJ8g=".
comptime _POLICY = (
    '{"version":3,"bindings":[{"role":"roles/artifactregistry.reader",'
    + '"members":["serviceAccount:runtime@example.com"]}],'
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


def _client(capture: ArcPointer[List[UInt8]]) raises -> _Client:
    var c = _Client(
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(
                ScriptedStream.from_read_script_with_capture(_ok(_POLICY), capture)
            )
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
    assert_equal(p.bindings[0].role, "roles/artifactregistry.reader")
    assert_equal(
        p.bindings[0].members[0],
        "serviceAccount:runtime@example.com",
    )
    var etag: List[UInt8] = [0x07, 0x05, 0xE1, 0xA8, 0x3B, 0x95, 0x27, 0xC8]
    assert_true(p.etag == etag)


def test_get_iam_policy() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var p = c.get_iam_policy[_RT](
        GetIamPolicyRequest(
            String(_REPO), Optional[GetPolicyOptions](GetPolicyOptions(Int32(3)))
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            String("GET /v1/") + _REPO + ":getIamPolicy?options.requestedPolicyVersion=3"
        ),
    )
    _check_policy(p)


def test_set_iam_policy_sends_back_the_etag_it_read() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var p = c.set_iam_policy[_RT](
        SetIamPolicyRequest(String(_REPO), decode_json[Policy](_POLICY), None),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            String("POST /v1/") + _REPO + ":setIamPolicy",
            String('{"policy":') + _POLICY + "}",
        ),
    )
    _check_policy(p)


def main() raises:
    test_get_iam_policy()
    test_set_iam_policy_sends_back_the_etag_it_read()
    print("OK")
