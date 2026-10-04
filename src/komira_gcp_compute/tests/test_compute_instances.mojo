# The VM half of the generated Compute Engine client: one test per method a
# job-placement caller makes (Instances.Insert, Get and Delete, and
# ZoneOperations.Get and Wait to follow the zonal operation an insert or a
# delete starts), Regions.Get, which a region quota check reads, and
# RegionOperations.Wait and GlobalOperations.Wait, which follow the regional
# and global operations of the network and load-balancing methods.
#
# Each test sends one request through the generated client over
# komira_http_core's ScriptedConnector with a shared write capture (no
# socket), and checks the request line (path and query) and body the client
# wrote, and the response it decoded. The client is pointed at `localhost`
# so the send resolves no name: that a fresh client starts at
# compute.googleapis.com is test_compute_default_host's.
#
# The expected forms are written from the Compute Engine v1 REST reference
# (instances.insert/get/delete, zoneOperations.get/wait, regions.get,
# regionOperations.wait, globalOperations.wait): path parameters in the
# path, `requestId` and the other optional parameters in the query, and the
# resource itself (not the request message) as the JSON body of an insert.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_compute.compute import (
    DeleteInstanceRequest,
    GetInstanceRequest,
    GetRegionRequest,
    GetZoneOperationRequest,
    GlobalOperationsClient,
    InsertInstanceRequest,
    Instance,
    InstancesClient,
    Operation_Status,
    RegionOperationsClient,
    RegionsClient,
    WaitGlobalOperationRequest,
    WaitRegionOperationRequest,
    WaitZoneOperationRequest,
    ZoneOperationsClient,
)
from komira_gcp_core import StaticTokenSource
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json_lenient


comptime _RT = BlockingRuntime[NoopSink]
comptime SC = ScriptedConnector
comptime TS = StaticTokenSource

# A zonal operation as instances.insert answers it: still running.
comptime _ZONE_OP = (
    '{"kind":"compute#operation","id":"7311","name":"operation-1700-abc",'
    + '"zone":"https://www.googleapis.com/compute/v1/projects/demo-project/zones/us-central1-a",'
    + '"operationType":"insert",'
    + '"targetLink":"https://www.googleapis.com/compute/v1/projects/demo-project/zones/us-central1-a/instances/job-vm-1",'
    + '"status":"RUNNING","progress":0,'
    + '"selfLink":"https://www.googleapis.com/compute/v1/projects/demo-project/zones/us-central1-a/operations/operation-1700-abc"}'
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


def test_instances_insert() raises:
    # The body is the Instance (`instanceResource` is the body field), and
    # the request's own fields go into the path; no requestId is set, so the
    # query is empty.
    var capture = _capture()
    var c = InstancesClient[SC, TS](_http(capture, _ZONE_OP), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var vm = decode_json_lenient[Instance](
        String(
            '{"name":"job-vm-1",'
            + '"machineType":"zones/us-central1-a/machineTypes/e2-small",'
            + '"labels":{"role":"job"}}'
        )
    )
    var op = c.insert[_RT](
        InsertInstanceRequest(
            vm^, String("demo-project"), None, None, None, String("us-central1-a")
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "POST /compute/v1/projects/demo-project/zones/us-central1-a/instances HTTP/1.1",
    )
    var body = _body(capture)
    assert_true('"name":"job-vm-1"' in body)
    assert_true(
        '"machineType":"zones/us-central1-a/machineTypes/e2-small"' in body
    )
    assert_true('"labels":{"role":"job"}' in body)
    # The request's path fields are not repeated in the body.
    assert_false('"project"' in body)
    assert_false('"zone"' in body)
    var sent = decode_json_lenient[Instance](body)
    assert_equal(sent.name.value(), "job-vm-1")
    assert_equal(op.name.value(), "operation-1700-abc")
    assert_true(op.status.value() == Operation_Status(Operation_Status.RUNNING))


def test_instances_insert_sends_a_request_id_the_caller_set() raises:
    # compute's `requestId` makes a retried insert idempotent; the client
    # sends one only when the caller sets it (nothing fills it in).
    var capture = _capture()
    var c = InstancesClient[SC, TS](_http(capture, _ZONE_OP), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var vm = decode_json_lenient[Instance](String('{"name":"job-vm-1"}'))
    _ = c.insert[_RT](
        InsertInstanceRequest(
            vm^,
            String("demo-project"),
            String("4a1c6f0e-8a7e-4c55-9b61-0f2d1e3c5a7b"),
            String("global/instanceTemplates/job"),
            None,
            String("us-central1-a"),
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "POST /compute/v1/projects/demo-project/zones/us-central1-a/instances"
        + "?requestId=4a1c6f0e-8a7e-4c55-9b61-0f2d1e3c5a7b"
        + "&sourceInstanceTemplate=global%2FinstanceTemplates%2Fjob HTTP/1.1",
    )


def test_instances_get() raises:
    var capture = _capture()
    var answer = String(
        '{"kind":"compute#instance","id":"88","name":"job-vm-1",'
        + '"status":"RUNNING",'
        + '"machineType":"https://www.googleapis.com/compute/v1/projects/demo-project/zones/us-central1-a/machineTypes/e2-small",'
        + '"networkInterfaces":[{"name":"nic0","networkIP":"10.128.0.7",'
        + '"accessConfigs":[{"type":"ONE_TO_ONE_NAT","natIP":"34.1.2.3"}]}]}'
    )
    var c = InstancesClient[SC, TS](_http(capture, answer), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var vm = c.get[_RT](
        GetInstanceRequest(
            String("job-vm-1"), String("demo-project"), String("us-central1-a")
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "GET /compute/v1/projects/demo-project/zones/us-central1-a/instances/job-vm-1 HTTP/1.1",
    )
    assert_equal(_body(capture), "")
    assert_equal(vm.name.value(), "job-vm-1")
    assert_equal(vm.status.value(), "RUNNING")
    assert_equal(len(vm.network_interfaces), 1)
    assert_equal(vm.network_interfaces[0].network_i_p.value(), "10.128.0.7")
    assert_equal(
        vm.network_interfaces[0].access_configs[0].nat_i_p.value(), "34.1.2.3"
    )


def test_instances_delete() raises:
    var capture = _capture()
    var c = InstancesClient[SC, TS](_http(capture, _ZONE_OP), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.delete[_RT](
        DeleteInstanceRequest(
            String("job-vm-1"),
            None,
            String("demo-project"),
            None,
            String("us-central1-a"),
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "DELETE /compute/v1/projects/demo-project/zones/us-central1-a/instances/job-vm-1 HTTP/1.1",
    )
    assert_equal(_body(capture), "")
    assert_equal(op.name.value(), "operation-1700-abc")


def test_zone_operations_get() raises:
    var capture = _capture()
    var answer = String(
        '{"kind":"compute#operation","name":"operation-1700-abc",'
        + '"status":"DONE","progress":100,"endTime":"2026-10-04T10:00:00.000-07:00"}'
    )
    var c = ZoneOperationsClient[SC, TS](_http(capture, answer), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.get[_RT](
        GetZoneOperationRequest(
            String("operation-1700-abc"),
            String("demo-project"),
            String("us-central1-a"),
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "GET /compute/v1/projects/demo-project/zones/us-central1-a/operations/operation-1700-abc HTTP/1.1",
    )
    assert_true(op.status.value() == Operation_Status(Operation_Status.DONE))
    assert_equal(op.progress.value(), 100)
    assert_false(op.error)


def test_zone_operations_wait() raises:
    # `wait` is a POST with no body; the server returns the operation when
    # it is DONE or after its own deadline, whichever comes first.
    var capture = _capture()
    var c = ZoneOperationsClient[SC, TS](_http(capture, _ZONE_OP), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.wait[_RT](
        WaitZoneOperationRequest(
            String("operation-1700-abc"),
            String("demo-project"),
            String("us-central1-a"),
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "POST /compute/v1/projects/demo-project/zones/us-central1-a/operations/operation-1700-abc/wait HTTP/1.1",
    )
    assert_equal(_body(capture), "")
    # A POST with no body still states its length: Google's front end
    # answers a bodyless POST without Content-Length with 411.
    assert_true("\r\nContent-Length: 0\r\n" in _wire(capture))
    assert_false("Transfer-Encoding" in _wire(capture))
    assert_true(op.status.value() == Operation_Status(Operation_Status.RUNNING))


def test_zone_operations_wait_returns_a_failed_operation() raises:
    # A write that failed comes back from `wait` as an HTTP 200 whose
    # operation is DONE with `error` set: the client returns it (it does not
    # raise), so the caller reads `error` after DONE. A field this pin does
    # not declare is skipped, and a status it does not know reads as the
    # zero value, never DONE.
    var capture = _capture()
    var answer = String(
        '{"kind":"compute#operation","name":"operation-1700-abc",'
        + '"status":"DONE","progress":100,"someNewField":{"x":1},'
        + '"httpErrorStatusCode":409,"httpErrorMessage":"CONFLICT",'
        + '"error":{"errors":[{"code":"RESOURCE_ALREADY_EXISTS",'
        + '"message":"The resource already exists"}]}}'
    )
    var c = ZoneOperationsClient[SC, TS](_http(capture, answer), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.wait[_RT](
        WaitZoneOperationRequest(
            String("operation-1700-abc"),
            String("demo-project"),
            String("us-central1-a"),
        ),
        reactor,
    )
    assert_true(op.status.value() == Operation_Status(Operation_Status.DONE))
    assert_equal(op.http_error_status_code.value(), 409)
    assert_true(op.error)
    assert_equal(len(op.error.value().errors), 1)
    assert_equal(
        op.error.value().errors[0].code.value(), "RESOURCE_ALREADY_EXISTS"
    )

    var later = _capture()
    var c2 = ZoneOperationsClient[SC, TS](
        _http(later, '{"name":"operation-1700-abc","status":"PAUSED"}'), _token()
    )
    c2.set_rest_host(String("localhost"))
    var op2 = c2.wait[_RT](
        WaitZoneOperationRequest(
            String("operation-1700-abc"),
            String("demo-project"),
            String("us-central1-a"),
        ),
        reactor,
    )
    assert_true(
        op2.status.value()
        == Operation_Status(Operation_Status.UNDEFINED_STATUS)
    )


def test_region_operations_wait() raises:
    var capture = _capture()
    var answer = String('{"name":"operation-r-1","status":"PENDING"}')
    var c = RegionOperationsClient[SC, TS](_http(capture, answer), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.wait[_RT](
        WaitRegionOperationRequest(
            String("operation-r-1"), String("demo-project"), String("us-central1")
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "POST /compute/v1/projects/demo-project/regions/us-central1/operations/operation-r-1/wait HTTP/1.1",
    )
    assert_equal(_body(capture), "")
    assert_true("\r\nContent-Length: 0\r\n" in _wire(capture))
    assert_true(op.status.value() == Operation_Status(Operation_Status.PENDING))


def test_global_operations_wait() raises:
    var capture = _capture()
    var answer = String('{"name":"operation-g-1","status":"DONE"}')
    var c = GlobalOperationsClient[SC, TS](_http(capture, answer), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.wait[_RT](
        WaitGlobalOperationRequest(String("operation-g-1"), String("demo-project")),
        reactor,
    )
    assert_equal(
        _head(capture),
        "POST /compute/v1/projects/demo-project/global/operations/operation-g-1/wait HTTP/1.1",
    )
    assert_equal(_body(capture), "")
    assert_true("\r\nContent-Length: 0\r\n" in _wire(capture))
    assert_true(op.status.value() == Operation_Status(Operation_Status.DONE))


def test_regions_get_reads_the_quotas() raises:
    # A region quota check reads `quotas`: each metric with its limit and
    # usage (doubles on the wire).
    var capture = _capture()
    var answer = String(
        '{"kind":"compute#region","name":"us-central1","status":"UP",'
        + '"quotas":[{"metric":"CPUS","limit":24,"usage":6.5},'
        + '{"metric":"IN_USE_ADDRESSES","limit":8,"usage":0}],'
        + '"zones":["https://www.googleapis.com/compute/v1/projects/demo-project/zones/us-central1-a"]}'
    )
    var c = RegionsClient[SC, TS](_http(capture, answer), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var region = c.get[_RT](
        GetRegionRequest(String("demo-project"), String("us-central1")), reactor
    )
    assert_equal(
        _head(capture),
        "GET /compute/v1/projects/demo-project/regions/us-central1 HTTP/1.1",
    )
    assert_equal(region.name.value(), "us-central1")
    assert_equal(len(region.quotas), 2)
    assert_equal(region.quotas[0].metric.value(), "CPUS")
    assert_equal(region.quotas[0].limit.value(), 24.0)
    assert_equal(region.quotas[0].usage.value(), 6.5)
    assert_equal(region.quotas[1].metric.value(), "IN_USE_ADDRESSES")
    assert_equal(region.quotas[1].usage.value(), 0.0)
    assert_equal(len(region.zones), 1)


def test_every_request_carries_the_bearer_token() raises:
    var capture = _capture()
    var c = RegionsClient[SC, TS](_http(capture, '{"name":"us-central1"}'), _token())
    c.set_rest_host(String("localhost"))
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    _ = c.get[_RT](
        GetRegionRequest(String("demo-project"), String("us-central1")), reactor
    )
    var wire = _wire(capture)
    assert_true("\r\nauthorization: Bearer test-access-token\r\n" in wire)
    assert_true("\r\nHost: localhost\r\n" in wire)


def main() raises:
    test_instances_insert()
    test_instances_insert_sends_a_request_id_the_caller_set()
    test_instances_get()
    test_instances_delete()
    test_zone_operations_get()
    test_zone_operations_wait()
    test_zone_operations_wait_returns_a_failed_operation()
    test_region_operations_wait()
    test_global_operations_wait()
    test_regions_get_reads_the_quotas()
    test_every_request_carries_the_bearer_token()
    print("OK")
