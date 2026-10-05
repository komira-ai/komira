# The host a client sends to when its caller names none. Every Compute
# Engine v1 service declares `option (google.api.default_host) =
# "compute.googleapis.com"`, and each generated client starts there, so a
# bearer token goes to the service it was minted for and to no other host.
#
# The default is read off fresh clients without sending (a send to
# compute.googleapis.com would resolve the name, which needs the network).
# That the client's host is what is dialled and named in the Host header is
# shown by the override, which sends to `localhost` (resolved without the
# network) through komira_http_core's ScriptedConnector, which records the
# host of every dial; no socket is used.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_compute.compute import (
    BackendBucketsClient,
    BackendServicesClient,
    FirewallsClient,
    GetRegionRequest,
    GlobalAddressesClient,
    GlobalForwardingRulesClient,
    GlobalOperationsClient,
    InstancesClient,
    NetworksClient,
    RegionNetworkEndpointGroupsClient,
    RegionOperationsClient,
    RegionsClient,
    SslCertificatesClient,
    SubnetworksClient,
    TargetHttpProxiesClient,
    TargetHttpsProxiesClient,
    UrlMapsClient,
    ZoneOperationsClient,
)
from komira_gcp_core import StaticTokenSource
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


comptime _RT = BlockingRuntime[NoopSink]
comptime SC = ScriptedConnector
comptime TS = StaticTokenSource
comptime _HOST = "compute.googleapis.com"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _ok() -> List[UInt8]:
    var body = String('{"name":"us-central1"}')
    return _bytes(
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _http() raises -> HttpClient[SC]:
    return HttpClient[SC].with_defaults(
        SC.with_stream_tls(ScriptedStream.from_read_script(_ok()))
    )


def _token() raises -> TS:
    return TS(String("test-access-token"))


def test_every_client_starts_at_compute_googleapis_com() raises:
    # No `set_rest_host`, nothing sent.
    var instances = InstancesClient[SC, TS](_http(), _token())
    assert_equal(instances._rest_host, _HOST)
    assert_equal(instances._client._connector.connect_call_count(), 0)
    assert_equal(ZoneOperationsClient[SC, TS](_http(), _token())._rest_host, _HOST)
    assert_equal(RegionOperationsClient[SC, TS](_http(), _token())._rest_host, _HOST)
    assert_equal(GlobalOperationsClient[SC, TS](_http(), _token())._rest_host, _HOST)
    assert_equal(RegionsClient[SC, TS](_http(), _token())._rest_host, _HOST)
    assert_equal(NetworksClient[SC, TS](_http(), _token())._rest_host, _HOST)
    assert_equal(SubnetworksClient[SC, TS](_http(), _token())._rest_host, _HOST)
    assert_equal(FirewallsClient[SC, TS](_http(), _token())._rest_host, _HOST)
    assert_equal(GlobalAddressesClient[SC, TS](_http(), _token())._rest_host, _HOST)
    assert_equal(SslCertificatesClient[SC, TS](_http(), _token())._rest_host, _HOST)
    assert_equal(
        RegionNetworkEndpointGroupsClient[SC, TS](_http(), _token())._rest_host,
        _HOST,
    )
    assert_equal(BackendBucketsClient[SC, TS](_http(), _token())._rest_host, _HOST)
    assert_equal(BackendServicesClient[SC, TS](_http(), _token())._rest_host, _HOST)
    assert_equal(UrlMapsClient[SC, TS](_http(), _token())._rest_host, _HOST)
    assert_equal(
        TargetHttpProxiesClient[SC, TS](_http(), _token())._rest_host, _HOST
    )
    assert_equal(
        TargetHttpsProxiesClient[SC, TS](_http(), _token())._rest_host, _HOST
    )
    assert_equal(
        GlobalForwardingRulesClient[SC, TS](_http(), _token())._rest_host, _HOST
    )


def test_set_rest_host_overrides_the_default() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = RegionsClient[SC, TS](
        HttpClient[SC].with_defaults(
            SC.with_stream_tls(
                ScriptedStream.from_read_script_with_capture(_ok(), capture)
            )
        ),
        _token(),
    )
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    _ = c.get[_RT](
        GetRegionRequest(String("demo-project"), String("us-central1")), reactor
    )
    assert_equal(c._client._connector.dial_hosts_len(), 1)
    assert_equal(c._client._connector.dial_host_at(0), "localhost")
    var wire = String(unsafe_from_utf8=Span(capture[]))
    assert_true(
        wire.startswith(
            "GET /compute/v1/projects/demo-project/regions/us-central1 HTTP/1.1\r\n"
        )
    )
    assert_true("\r\nHost: localhost\r\n" in wire)
    assert_true(not ("compute.googleapis.com" in wire))


def main() raises:
    test_every_client_starts_at_compute_googleapis_com()
    test_set_rest_host_overrides_the_default()
    print("OK")
