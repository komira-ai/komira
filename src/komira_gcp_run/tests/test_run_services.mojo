# Each generated Cloud Run `Services` and `Revisions` method, once: the
# request it puts on the wire, byte for byte (request line with the
# resource-name captures and the query, the headers, the JSON body), and
# the response it reads back. CreateService, UpdateService, DeleteService
# and DeleteRevision answer with a google.longrunning.Operation, which
# test_run_operations polls.
#
# The expected forms are written here from the Cloud Run Admin v2 REST
# reference (projects.locations.services.create, .get, .list, .patch,
# .delete, and services.revisions.list, .delete); no upstream test body is
# copied. The service is the shape komira deploys: one container from an
# image pinned by digest, an argument, a plain and a secret-backed
# environment variable, a port, a runtime service account and an instance
# ceiling. The connector is komira_http_core's ScriptedConnector with a
# shared write capture; no socket is opened. Each client is pointed at
# `localhost` (resolved without the network) with `set_rest_host`; the
# default host is test_run_endpoint's subject.
#
# A body holds only the fields the caller set: a plain field at its default
# (`uid`, `generation`, `launchStage`, the output-only fields) and an empty
# list or map are omitted, as the proto3 JSON mapping omits them; the
# service reads each as unset.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import GcpTokenSource, StaticTokenSource
from komira_gcp_run.condition import Condition_State
from komira_gcp_run.revision import (
    DeleteRevisionRequest,
    ListRevisionsRequest,
    RevisionsClient,
)
from komira_gcp_run.service import (
    CreateServiceRequest,
    DeleteServiceRequest,
    GetServiceRequest,
    ListServicesRequest,
    ServicesClient,
    UpdateServiceRequest,
)
from komira_gcp_run.traffic_target import TrafficTargetAllocationType
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json


comptime _RT = BlockingRuntime[NoopSink]

# 2026-09-30T12:00:00Z.
comptime _T0 = Int64(1790769600)

comptime _NAME = "projects/demo-project/locations/us-central1/services/web"

# The service as a caller states it.
comptime _SERVICE = (
    '{"labels":{"app":"web"},"ingress":"INGRESS_TRAFFIC_ALL","template":{'
    + '"serviceAccount":"web-runtime@demo-project.iam.gserviceaccount.com",'
    + '"containers":[{"image":"us-docker.pkg.dev/demo-project/apps/web@sha256:0f1e",'
    + '"args":["--port=8080"],"env":[{"name":"MODE","value":"serve"},'
    + '{"name":"SMTP_PASSWORD","valueSource":{"secretKeyRef":{"secret":"smtp-password",'
    + '"version":"3"}}}],"ports":[{"containerPort":8080}]}],'
    + '"scaling":{"maxInstanceCount":4}}}'
)

# The same service as the client writes it, after its name: the fields the
# caller set, in declaration order (`scaling` before `serviceAccount`).
comptime _SERVICE_WIRE_TAIL = (
    '"labels":{"app":"web"},"ingress":"INGRESS_TRAFFIC_ALL","template":{'
    + '"scaling":{"maxInstanceCount":4},'
    + '"serviceAccount":"web-runtime@demo-project.iam.gserviceaccount.com",'
    + '"containers":[{"image":"us-docker.pkg.dev/demo-project/apps/web@sha256:0f1e",'
    + '"args":["--port=8080"],"env":[{"name":"MODE","value":"serve"},'
    + '{"name":"SMTP_PASSWORD","valueSource":{"secretKeyRef":{"secret":"smtp-password",'
    + '"version":"3"}}}],"ports":[{"containerPort":8080}]}]}}'
)

# A running operation, as Create/Update/Delete answer.
comptime _OPERATION = (
    '{"name":"projects/demo-project/locations/us-central1/operations/0f8e3a",'
    + '"metadata":{"@type":"type.googleapis.com/google.cloud.run.v2.Service",'
    + '"name":"projects/demo-project/locations/us-central1/services/web"},'
    + '"done":false}'
)

# The service as the service answers it.
comptime _SERVICE_ANSWER = (
    '{"name":"projects/demo-project/locations/us-central1/services/web",'
    + '"uid":"5c2e8a1d-7f3b-4e0a-9d6c-1b2a3c4d5e6f","generation":"3",'
    + '"labels":{"app":"web"},"createTime":"2026-09-30T12:00:00.250Z",'
    + '"creator":"deployer@demo-project.iam.gserviceaccount.com",'
    + '"ingress":"INGRESS_TRAFFIC_ALL","launchStage":"GA",'
    + '"template":{"scaling":{"maxInstanceCount":4},'
    + '"serviceAccount":"web-runtime@demo-project.iam.gserviceaccount.com",'
    + '"containers":[{"image":"us-docker.pkg.dev/demo-project/apps/web@sha256:0f1e",'
    + '"ports":[{"name":"http1","containerPort":8080}]}]},'
    + '"traffic":[{"type":"TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST","percent":100}],'
    + '"observedGeneration":"3","terminalCondition":{"type":"Ready",'
    + '"state":"CONDITION_SUCCEEDED","lastTransitionTime":"2026-09-30T12:00:00Z"},'
    + '"latestReadyRevision":"projects/demo-project/locations/us-central1/services/web/'
    + 'revisions/web-00003-kxv",'
    + '"latestCreatedRevision":"projects/demo-project/locations/us-central1/services/web/'
    + 'revisions/web-00003-kxv",'
    + '"uri":"https://web-5q2kx3abcd-uc.a.run.app",'
    + '"urls":["https://web-123456789012.us-central1.run.app"],'
    + '"etag":"\\"COi_1bQGEJDq\\"","newFieldFromALaterApi":{"x":1}}'
)


struct CountingTokenSource(GcpTokenSource, Movable, Deinitable):
    """Counts the tokens asked of it in a cell the test keeps."""

    var calls: ArcPointer[Int]

    def __init__(out self, calls: ArcPointer[Int]):
        self.calls = calls

    def access_token(mut self) raises -> String:
        self.calls[] += 1
        return String("test-access-token")


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _ok(body: String) -> List[UInt8]:
    """A 200 with a JSON body, closing the connection after it."""
    return _bytes(
        String("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n")
        + "Content-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def _http(
    capture: ArcPointer[List[UInt8]], answer: String
) -> HttpClient[ScriptedConnector]:
    return HttpClient[ScriptedConnector].with_defaults(
        ScriptedConnector.with_stream_tls(
            ScriptedStream.from_read_script_with_capture(_ok(answer), capture)
        )
    )


def _services(
    capture: ArcPointer[List[UInt8]], answer: String
) raises -> ServicesClient[ScriptedConnector, StaticTokenSource]:
    var c = ServicesClient[ScriptedConnector, StaticTokenSource](
        _http(capture, answer), StaticTokenSource(String("test-access-token"))
    )
    c.set_rest_host(String("localhost"))
    return c^


def _revisions(
    capture: ArcPointer[List[UInt8]], answer: String
) raises -> RevisionsClient[ScriptedConnector, StaticTokenSource]:
    var c = RevisionsClient[ScriptedConnector, StaticTokenSource](
        _http(capture, answer), StaticTokenSource(String("test-access-token"))
    )
    c.set_rest_host(String("localhost"))
    return c^


def _wire(capture: ArcPointer[List[UInt8]]) -> String:
    return String(unsafe_from_utf8=Span(capture[]))


def _expected(target: String, body: String = "") -> String:
    """The request as written: komira_http's Host, User-Agent and
    Content-Length, then the client's headers (lowercased on the wire), a
    content-type only with a body, then the body."""
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


def test_create_service() raises:
    # POST .../locations/{location}/services?serviceId=..., the Service as
    # the body; the answer is a running operation.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _services(capture, _OPERATION)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.create_service[_RT](
        decode_json[CreateServiceRequest](
            String('{"parent":"projects/demo-project/locations/us-central1",')
            + '"serviceId":"web","service":'
            + _SERVICE
            + "}"
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            "POST /v2/projects/demo-project/locations/us-central1/services?serviceId=web",
            String('{') + _SERVICE_WIRE_TAIL,
        ),
    )
    assert_equal(op.name, "projects/demo-project/locations/us-central1/operations/0f8e3a")
    assert_false(op.done)
    assert_equal(
        op.metadata.value().type_url, "type.googleapis.com/google.cloud.run.v2.Service"
    )
    assert_false(Bool(op.error))
    assert_false(Bool(op.response))


def test_get_service() raises:
    # A field this pin does not know (`newFieldFromALaterApi`) is skipped.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _services(capture, _SERVICE_ANSWER)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var svc = c.get_service[_RT](
        decode_json[GetServiceRequest](String('{"name":"') + _NAME + '"}'), reactor
    )
    assert_equal(_wire(capture), _expected(String("GET /v2/") + _NAME))
    assert_equal(svc.name, _NAME)
    assert_equal(svc.generation, Int64(3))
    assert_equal(svc.observed_generation, Int64(3))
    assert_equal(svc.create_time.value().seconds, _T0)
    assert_equal(svc.create_time.value().nanos, Int32(250000000))
    assert_equal(svc.template.value().containers[0].ports[0].container_port, Int32(8080))
    assert_equal(svc.traffic[0].percent, Int32(100))
    assert_true(
        svc.traffic[0].type
        == TrafficTargetAllocationType(
            TrafficTargetAllocationType.TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST
        )
    )
    ref ready = svc.terminal_condition.value()
    assert_equal(ready.type, "Ready")
    assert_true(ready.state == Condition_State(Condition_State.CONDITION_SUCCEEDED))
    assert_equal(
        svc.latest_ready_revision,
        "projects/demo-project/locations/us-central1/services/web/revisions/web-00003-kxv",
    )
    assert_equal(svc.uri, "https://web-5q2kx3abcd-uc.a.run.app")
    assert_equal(len(svc.urls), 1)
    assert_equal(svc.etag, '"COi_1bQGEJDq"')


def test_list_services_in_every_location() raises:
    # `locations/-` lists every region; `-` is an unreserved byte, sent as
    # it is.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _services(
        capture,
        String('{"services":[')
        + _SERVICE_ANSWER
        + '],"nextPageToken":"CiRib2FyZA==","unreachable":["europe-west9"]}',
    )
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var page = c.list_services[_RT](
        decode_json[ListServicesRequest](
            '{"parent":"projects/demo-project/locations/-","pageSize":100,'
            + '"pageToken":"CiRhcGk=","showDeleted":true}'
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            "GET /v2/projects/demo-project/locations/-/services"
            + "?pageSize=100&pageToken=CiRhcGk%3D&showDeleted=true"
        ),
    )
    assert_equal(len(page.services), 1)
    assert_equal(page.services[0].name, _NAME)
    assert_equal(page.next_page_token, "CiRib2FyZA==")
    assert_equal(len(page.unreachable), 1)
    assert_equal(page.unreachable[0], "europe-west9")


def test_update_service() raises:
    # PATCH /v2/{service.name=...}: the path is the body's service name.
    # With no update mask the Service replaces the old one whole;
    # allowMissing creates it if absent.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _services(capture, _OPERATION)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var service = (
        String('{"name":"') + _NAME + '",' + String(String(_SERVICE)[byte=1:])
    )
    var op = c.update_service[_RT](
        decode_json[UpdateServiceRequest](
            String('{"service":') + service + ',"allowMissing":true}'
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            String("PATCH /v2/") + _NAME + "?allowMissing=true",
            String('{"name":"') + _NAME + '",' + _SERVICE_WIRE_TAIL,
        ),
    )
    assert_false(op.done)


def test_update_service_without_a_service_is_refused_before_any_send() raises:
    var calls = ArcPointer[Int](0)
    var c = ServicesClient[ScriptedConnector, CountingTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(ScriptedStream.from_read_script(_ok("{}")))
        ),
        CountingTokenSource(calls),
    )
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var got = String("")
    try:
        _ = c.update_service[_RT](
            decode_json[UpdateServiceRequest]('{"validateOnly":true}'), reactor
        )
    except e:
        got = String(e)
    assert_equal(
        got,
        "update_service: the request's `service` is unset, and the path is built"
        " from `service.name`",
    )
    assert_equal(calls[], 0)
    assert_equal(c._client._connector.connect_call_count(), 0)


def test_delete_service() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _services(capture, _OPERATION)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.delete_service[_RT](
        decode_json[DeleteServiceRequest](String('{"name":"') + _NAME + '"}'), reactor
    )
    assert_equal(_wire(capture), _expected(String("DELETE /v2/") + _NAME))
    assert_equal(op.name, "projects/demo-project/locations/us-central1/operations/0f8e3a")


def test_list_revisions() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _revisions(
        capture,
        '{"revisions":[{"name":"'
        + _NAME
        + '/revisions/web-00003-kxv","generation":"1",'
        + '"createTime":"2026-09-30T12:00:00Z","service":"'
        + _NAME
        + '","containers":[{"image":"us-docker.pkg.dev/demo-project/apps/web@sha256:0f1e"}],'
        + '"scalingStatus":{"desiredMinInstanceCount":1},"timeout":"300s"},'
        + '{"name":"'
        + _NAME
        + '/revisions/web-00002-pqr","generation":"1"}],'
        + '"nextPageToken":"CgVib2FyZA=="}',
    )
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var page = c.list_revisions[_RT](
        decode_json[ListRevisionsRequest](
            String('{"parent":"') + _NAME + '","pageSize":50}'
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(String("GET /v2/") + _NAME + "/revisions?pageSize=50"),
    )
    assert_equal(len(page.revisions), 2)
    ref r0 = page.revisions[0]
    assert_equal(r0.name, String(_NAME) + "/revisions/web-00003-kxv")
    assert_equal(r0.service, _NAME)
    assert_equal(r0.create_time.value().seconds, _T0)
    assert_equal(r0.timeout.value().seconds, Int64(300))
    assert_equal(r0.scaling_status.value().desired_min_instance_count, Int32(1))
    assert_equal(page.next_page_token, "CgVib2FyZA==")


def test_delete_revision() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _revisions(capture, _OPERATION)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.delete_revision[_RT](
        decode_json[DeleteRevisionRequest](
            String('{"name":"') + _NAME + '/revisions/web-00001-abc","etag":"\\"x1\\""}'
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            String("DELETE /v2/") + _NAME + "/revisions/web-00001-abc?etag=%22x1%22"
        ),
    )
    assert_false(op.done)


def main() raises:
    test_create_service()
    test_get_service()
    test_list_services_in_every_location()
    test_update_service()
    test_update_service_without_a_service_is_refused_before_any_send()
    test_delete_service()
    test_list_revisions()
    test_delete_revision()
    print("OK")
