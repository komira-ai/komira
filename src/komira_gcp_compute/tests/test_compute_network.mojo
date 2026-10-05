# The VPC half of the generated Compute Engine client: one test per method a
# network conformer makes (Networks.Get, Insert and Delete; Subnetworks.Get,
# Insert and Delete; Firewalls.Get, Insert, Patch and Delete). The
# operations those writes start are followed through RegionOperations.Wait
# and GlobalOperations.Wait (test_compute_instances).
#
# Each test sends one request through the generated client over
# komira_http_core's ScriptedConnector with a shared write capture (no
# socket) and checks the request line and body the client wrote and the
# response it decoded. The client is pointed at `localhost`, so the send
# resolves no name.
#
# The expected forms are written from the Compute Engine v1 REST reference
# (networks, subnetworks and firewalls: get, insert, patch, delete). The
# firewall rule's protocol key is `IPProtocol`, as the reference spells it,
# for the proto field `I_p_protocol`: protoc's JSON name, which the
# generated code reads and writes.
#
# Firewalls.Patch is a JSON merge patch on the server: a key present in the
# body replaces that field, and a key absent leaves it. komira_proto_codec's
# JsonEncoder omits an empty list or map and an unset optional field, so a
# sparse patch sends only the fields the caller set (the exact body below
# pins that). An empty `targetTags` sent as `[]` would widen the rule to
# every instance on the network. The flip side: a patch cannot clear a list.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_compute.compute import (
    DeleteFirewallRequest,
    DeleteNetworkRequest,
    DeleteSubnetworkRequest,
    Firewall,
    FirewallsClient,
    GetFirewallRequest,
    GetNetworkRequest,
    GetSubnetworkRequest,
    InsertFirewallRequest,
    InsertNetworkRequest,
    InsertSubnetworkRequest,
    Network,
    NetworksClient,
    Operation_Status,
    PatchFirewallRequest,
    Subnetwork,
    SubnetworksClient,
)
from komira_gcp_core import StaticTokenSource
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json_lenient


comptime _RT = BlockingRuntime[NoopSink]
comptime SC = ScriptedConnector
comptime TS = StaticTokenSource

# A global operation as a network or firewall write answers it.
comptime _GLOBAL_OP = (
    '{"kind":"compute#operation","name":"operation-g-1","operationType":"insert",'
    + '"status":"RUNNING",'
    + '"selfLink":"https://www.googleapis.com/compute/v1/projects/demo-project/global/operations/operation-g-1"}'
)

# A regional operation, as a subnetwork write answers it.
comptime _REGION_OP = (
    '{"kind":"compute#operation","name":"operation-r-1","operationType":"insert",'
    + '"region":"https://www.googleapis.com/compute/v1/projects/demo-project/regions/us-central1",'
    + '"status":"PENDING"}'
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


def _capture() -> ArcPointer[List[UInt8]]:
    return ArcPointer[List[UInt8]](List[UInt8]())


def _http(capture: ArcPointer[List[UInt8]], answer: String) raises -> HttpClient[SC]:
    return HttpClient[SC].with_defaults(
        SC.with_stream_tls(
            ScriptedStream.from_read_script_with_capture(_ok(answer), capture)
        )
    )


def _token() raises -> TS:
    return TS(String("test-access-token"))


def _wire(capture: ArcPointer[List[UInt8]]) -> String:
    return String(unsafe_from_utf8=Span(capture[]))


def _head(capture: ArcPointer[List[UInt8]]) -> String:
    """The request line."""
    return String(_wire(capture).split("\r\n")[0])


def _body(capture: ArcPointer[List[UInt8]]) -> String:
    """What follows the header block."""
    var parts = _wire(capture).split("\r\n\r\n")
    return String(parts[1]) if len(parts) > 1 else String("")


def test_networks_get() raises:
    var capture = _capture()
    var answer = String(
        '{"kind":"compute#network","name":"apps","autoCreateSubnetworks":false,'
        + '"mtu":1460,"routingConfig":{"routingMode":"REGIONAL"},'
        + '"subnetworks":["https://www.googleapis.com/compute/v1/projects/demo-project/regions/us-central1/subnetworks/apps-usc1"]}'
    )
    var c = NetworksClient[SC, TS](_http(capture, answer), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var net = c.get[_RT](
        GetNetworkRequest(String("apps"), String("demo-project")), reactor
    )
    assert_equal(
        _head(capture),
        "GET /compute/v1/projects/demo-project/global/networks/apps HTTP/1.1",
    )
    assert_equal(_body(capture), "")
    assert_equal(net.name.value(), "apps")
    assert_false(net.auto_create_subnetworks.value())
    assert_equal(net.mtu.value(), 1460)
    assert_equal(net.routing_config.value().routing_mode.value(), "REGIONAL")
    assert_equal(len(net.subnetworks), 1)


def test_networks_insert() raises:
    # A custom-mode network: `autoCreateSubnetworks` false is sent (the
    # field has presence, so a set false is not dropped).
    var capture = _capture()
    var c = NetworksClient[SC, TS](_http(capture, _GLOBAL_OP), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var net = decode_json_lenient[Network](
        String('{"name":"apps","autoCreateSubnetworks":false,"mtu":1460}')
    )
    var op = c.insert[_RT](
        InsertNetworkRequest(net^, String("demo-project"), None), reactor
    )
    assert_equal(
        _head(capture),
        "POST /compute/v1/projects/demo-project/global/networks HTTP/1.1",
    )
    assert_equal(
        _body(capture),
        '{"autoCreateSubnetworks":false,"mtu":1460,"name":"apps"}',
    )
    assert_equal(op.name.value(), "operation-g-1")


def test_networks_delete() raises:
    var capture = _capture()
    var c = NetworksClient[SC, TS](_http(capture, _GLOBAL_OP), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.delete[_RT](
        DeleteNetworkRequest(
            String("apps"),
            String("demo-project"),
            String("0b5e6f7a-1c2d-4e3f-8a9b-0c1d2e3f4a5b"),
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "DELETE /compute/v1/projects/demo-project/global/networks/apps"
        + "?requestId=0b5e6f7a-1c2d-4e3f-8a9b-0c1d2e3f4a5b HTTP/1.1",
    )
    assert_equal(op.name.value(), "operation-g-1")


def test_subnetworks_get() raises:
    var capture = _capture()
    var answer = String(
        '{"kind":"compute#subnetwork","name":"apps-usc1",'
        + '"ipCidrRange":"10.10.0.0/24","privateIpGoogleAccess":true,'
        + '"secondaryIpRanges":[{"rangeName":"pods","ipCidrRange":"10.20.0.0/16"}]}'
    )
    var c = SubnetworksClient[SC, TS](_http(capture, answer), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var sub = c.get[_RT](
        GetSubnetworkRequest(
            String("demo-project"), String("us-central1"), String("apps-usc1"), None
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "GET /compute/v1/projects/demo-project/regions/us-central1/subnetworks/apps-usc1 HTTP/1.1",
    )
    assert_equal(sub.ip_cidr_range.value(), "10.10.0.0/24")
    assert_true(sub.private_ip_google_access.value())
    assert_equal(len(sub.secondary_ip_ranges), 1)
    assert_equal(sub.secondary_ip_ranges[0].range_name.value(), "pods")


def test_subnetworks_insert() raises:
    var capture = _capture()
    var c = SubnetworksClient[SC, TS](_http(capture, _REGION_OP), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var sub = decode_json_lenient[Subnetwork](
        String(
            '{"name":"apps-usc1","ipCidrRange":"10.10.0.0/24",'
            + '"network":"projects/demo-project/global/networks/apps",'
            + '"privateIpGoogleAccess":true}'
        )
    )
    var op = c.insert[_RT](
        InsertSubnetworkRequest(
            String("demo-project"), String("us-central1"), None, sub^
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "POST /compute/v1/projects/demo-project/regions/us-central1/subnetworks HTTP/1.1",
    )
    var body = _body(capture)
    assert_true('"name":"apps-usc1"' in body)
    assert_true('"ipCidrRange":"10.10.0.0/24"' in body)
    assert_true('"privateIpGoogleAccess":true' in body)
    assert_false('"region"' in body)
    assert_true(op.status.value() == Operation_Status(Operation_Status.PENDING))


def test_subnetworks_delete() raises:
    var capture = _capture()
    var c = SubnetworksClient[SC, TS](_http(capture, _REGION_OP), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.delete[_RT](
        DeleteSubnetworkRequest(
            String("demo-project"), String("us-central1"), None, String("apps-usc1")
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "DELETE /compute/v1/projects/demo-project/regions/us-central1/subnetworks/apps-usc1 HTTP/1.1",
    )
    assert_equal(op.name.value(), "operation-r-1")


def test_firewalls_get() raises:
    var capture = _capture()
    var answer = String(
        '{"kind":"compute#firewall","name":"allow-health-checks",'
        + '"network":"https://www.googleapis.com/compute/v1/projects/demo-project/global/networks/apps",'
        + '"direction":"INGRESS","priority":1000,'
        + '"allowed":[{"IPProtocol":"tcp","ports":["8080","9000-9100"]}],'
        + '"sourceRanges":["35.191.0.0/16","130.211.0.0/22"]}'
    )
    var c = FirewallsClient[SC, TS](_http(capture, answer), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var fw = c.get[_RT](
        GetFirewallRequest(String("allow-health-checks"), String("demo-project")),
        reactor,
    )
    assert_equal(
        _head(capture),
        "GET /compute/v1/projects/demo-project/global/firewalls/allow-health-checks HTTP/1.1",
    )
    assert_equal(fw.direction.value(), "INGRESS")
    assert_equal(fw.priority.value(), 1000)
    assert_equal(len(fw.allowed), 1)
    assert_equal(fw.allowed[0].I_p_protocol.value(), "tcp")
    assert_equal(len(fw.allowed[0].ports), 2)
    assert_equal(fw.allowed[0].ports[1], "9000-9100")
    assert_equal(len(fw.source_ranges), 2)


def test_firewalls_insert() raises:
    var capture = _capture()
    var c = FirewallsClient[SC, TS](_http(capture, _GLOBAL_OP), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var fw = decode_json_lenient[Firewall](
        String(
            '{"name":"allow-health-checks","network":"global/networks/apps",'
            + '"allowed":[{"IPProtocol":"tcp","ports":["8080"]}],'
            + '"sourceRanges":["35.191.0.0/16"]}'
        )
    )
    _ = c.insert[_RT](
        InsertFirewallRequest(fw^, String("demo-project"), None), reactor
    )
    assert_equal(
        _head(capture),
        "POST /compute/v1/projects/demo-project/global/firewalls HTTP/1.1",
    )
    var body = _body(capture)
    assert_true('"allowed":[{"IPProtocol":"tcp","ports":["8080"]}]' in body)
    assert_true('"sourceRanges":["35.191.0.0/16"]' in body)


def test_firewalls_patch_sends_only_what_is_set() raises:
    # The exact body: the one list the caller set, and no other key. An
    # empty list sent as `[]` would be read by the server's merge patch as
    # "set to empty" (module header).
    var capture = _capture()
    var c = FirewallsClient[SC, TS](_http(capture, _GLOBAL_OP), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var fw = decode_json_lenient[Firewall](
        String('{"sourceRanges":["35.191.0.0/16","130.211.0.0/22"]}')
    )
    var op = c.patch[_RT](
        PatchFirewallRequest(
            String("allow-health-checks"), fw^, String("demo-project"), None
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "PATCH /compute/v1/projects/demo-project/global/firewalls/allow-health-checks HTTP/1.1",
    )
    assert_equal(
        _body(capture),
        '{"sourceRanges":["35.191.0.0/16","130.211.0.0/22"]}',
    )
    assert_equal(op.name.value(), "operation-g-1")


def test_firewalls_delete() raises:
    var capture = _capture()
    var c = FirewallsClient[SC, TS](_http(capture, _GLOBAL_OP), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    _ = c.delete[_RT](
        DeleteFirewallRequest(
            String("allow-health-checks"), String("demo-project"), None
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "DELETE /compute/v1/projects/demo-project/global/firewalls/allow-health-checks HTTP/1.1",
    )
    assert_equal(_body(capture), "")


def main() raises:
    test_networks_get()
    test_networks_insert()
    test_networks_delete()
    test_subnetworks_get()
    test_subnetworks_insert()
    test_subnetworks_delete()
    test_firewalls_get()
    test_firewalls_insert()
    test_firewalls_patch_sends_only_what_is_set()
    test_firewalls_delete()
    print("OK")
