# The workload identity provider read of the generated
# `WorkloadIdentityPoolsClient`: GetWorkloadIdentityPoolProvider, sent through
# komira_http_core's ScriptedConnector with a shared write capture (no
# socket). A trust check reads the provider a cell's deploy identity is
# reached through and compares its issuer, audiences and attribute condition
# with what bootstrap wrote; this test holds the read's wire form and that
# each of those fields is decoded.
#
# The form is written here from the IAM REST reference for
# `projects.locations.workloadIdentityPools.providers.get`. The pinned
# googleapis holds the workload identity pools at v1beta only, so the path is
# `/v1beta/{name=projects/*/locations/*/workloadIdentityPools/*/providers/*}`,
# a GET with no body. The client starts at iam.googleapis.com, the host the
# file declares; every other client here is pointed at `localhost`, so no test
# needs DNS.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_iam.workload_identity_pool import (
    GetWorkloadIdentityPoolProviderRequest,
    WorkloadIdentityPoolProvider_State,
    WorkloadIdentityPoolsClient,
)
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json


comptime _RT = BlockingRuntime[NoopSink]
comptime _NAME = (
    "projects/123456789012/locations/global/workloadIdentityPools/ci/providers/repo"
)

# The provider as the service answers it: an OIDC issuer, one audience, the
# attribute mapping and the condition naming one repository.
comptime _PROVIDER = (
    '{"name":"projects/123456789012/locations/global/workloadIdentityPools/ci/'
    + 'providers/repo","displayName":"ci","state":"ACTIVE","disabled":false,'
    + '"attributeMapping":{"google.subject":"assertion.sub",'
    + '"attribute.repository":"assertion.repository"},'
    + '"attributeCondition":"assertion.repository == \\"example/app\\"",'
    + '"oidc":{"issuerUri":"https://issuer.example.com",'
    + '"allowedAudiences":["https://example.com/deploy"]}}'
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


def _client(
    capture: ArcPointer[List[UInt8]],
) raises -> WorkloadIdentityPoolsClient[ScriptedConnector, StaticTokenSource]:
    var c = WorkloadIdentityPoolsClient[ScriptedConnector, StaticTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(
                ScriptedStream.from_read_script_with_capture(_ok(_PROVIDER), capture)
            )
        ),
        StaticTokenSource(String("test-access-token")),
    )
    c.set_rest_host(String("localhost"))
    return c^


def _request(name: String) raises -> GetWorkloadIdentityPoolProviderRequest:
    return decode_json[GetWorkloadIdentityPoolProviderRequest](
        String('{"name":"') + name + '"}'
    )


def test_a_fresh_client_starts_at_the_iam_host() raises:
    var c = WorkloadIdentityPoolsClient[ScriptedConnector, StaticTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(ScriptedStream.from_read_script(_ok("{}")))
        ),
        StaticTokenSource(String("test-access-token")),
    )
    assert_equal(c._rest_host, "iam.googleapis.com")
    assert_equal(c._client._connector.connect_call_count(), 0)


def test_get_provider() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var p = c.get_workload_identity_pool_provider[_RT](_request(_NAME), reactor)
    assert_equal(
        String(unsafe_from_utf8=Span(capture[])),
        String("GET /v1beta/")
        + _NAME
        + " HTTP/1.1\r\n"
        + "Host: localhost\r\n"
        + "User-Agent: komira-http/1.0\r\n"
        + "Content-Length: 0\r\n"
        + "authorization: Bearer test-access-token\r\n"
        + "\r\n",
    )
    assert_equal(p.name, _NAME)
    assert_true(
        p.state == WorkloadIdentityPoolProvider_State(WorkloadIdentityPoolProvider_State.ACTIVE)
    )
    assert_false(p.disabled)
    assert_equal(p.attribute_mapping["attribute.repository"], "assertion.repository")
    assert_equal(p.attribute_condition, 'assertion.repository == "example/app"')
    # `oidc` is the second arm of the `provider_config` oneof (`aws` first).
    assert_equal(p._oneof0_case, 2)
    ref oidc = p.oidc.value()
    assert_equal(oidc.issuer_uri, "https://issuer.example.com")
    assert_equal(len(oidc.allowed_audiences), 1)
    assert_equal(oidc.allowed_audiences[0], "https://example.com/deploy")


def test_a_name_outside_the_pattern_is_refused_before_the_dial() raises:
    # A pool's name is not a provider's.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var raised = String("")
    try:
        _ = c.get_workload_identity_pool_provider[_RT](
            _request("projects/123456789012/locations/global/workloadIdentityPools/ci"),
            reactor,
        )
    except e:
        raised = String(e)
    assert_equal(
        raised,
        "path variable `name` does not match"
        " `projects/*/locations/*/workloadIdentityPools/*/providers/*`",
    )
    assert_equal(c._client._connector.connect_call_count(), 0)


def main() raises:
    test_a_fresh_client_starts_at_the_iam_host()
    test_get_provider()
    test_a_name_outside_the_pattern_is_refused_before_the_dial()
    print("OK")
