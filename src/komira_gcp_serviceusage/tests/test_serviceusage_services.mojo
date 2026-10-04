# The generated `ServiceUsageClient`: EnableService, DisableService and
# GetService, each sent through komira_http_core's ScriptedConnector with a
# shared write capture (no socket): the request line, the headers that
# carry meaning and the JSON body, and the answer read back.
#
# The forms are written here from the Service Usage v1 REST reference:
# `services.enable` and `services.disable` (POST
# /v1/<parent>/services/<service>:enable / :disable, the request message,
# less the `name` the path carries, as the body, answered with a long-running `Operation`) and `services.get`
# (GET on the service's name, answered with a `Service`). A service is
# named `projects/<project>/services/<service>` (a project number or id),
# which the binding `*/*/services/*` takes.
#
# Enabling is a long-running operation. The `Operation` an enable answers
# with is either still running (`done` absent, a `metadata` Any naming the
# OperationMetadata) or already finished (`done` with a `response` Any, or
# an `error` google.rpc.Status). The client's callers converge by polling
# GetService until its `state` is ENABLED, so the operation is read here,
# not polled: OperationsClient.GetOperation is not generated (no caller
# polls an operation by name). The Any payloads stay opaque (komira_wkt has
# no type registry): their `@type` and members are kept as they came.
#
# GetService's `Service.config` is left out of the generated message
# (`omit_fields` in BUCK): no caller reads it, and its ServiceConfig reaches
# types the runtime does not represent. A real answer carries it; the read
# skips it as it skips any unknown key, and the state is still read.
#
# Default-valued body keys are komira_proto_codec's JsonEncoder writing
# defaults, not the API. Every client is pointed at `localhost`, so no test
# needs DNS; the default host is test_serviceusage_default_host's.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_serviceusage.resources import State
from komira_gcp_serviceusage.serviceusage import (
    DisableServiceRequest,
    DisableServiceRequest_CheckIfServiceHasUsage,
    EnableServiceRequest,
    GetServiceRequest,
    ServiceUsageClient,
)
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


comptime _RT = BlockingRuntime[NoopSink]
comptime _SVC = "projects/demo-project/services/run.googleapis.com"


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
    capture: ArcPointer[List[UInt8]], answer: String
) raises -> ServiceUsageClient[ScriptedConnector, StaticTokenSource]:
    var c = ServiceUsageClient[ScriptedConnector, StaticTokenSource](
        HttpClient[ScriptedConnector].with_defaults(
            ScriptedConnector.with_stream_tls(
                ScriptedStream.from_read_script_with_capture(_ok(answer), capture)
            )
        ),
        StaticTokenSource(String("test-access-token")),
    )
    c.set_rest_host(String("localhost"))
    return c^


def _wire(capture: ArcPointer[List[UInt8]]) -> String:
    return String(unsafe_from_utf8=Span(capture[]))


def _request_line(wire: String) -> String:
    return String(wire[byte = 0 : wire.find("\r\n")])


def _body(wire: String) -> String:
    return String(wire[byte = wire.find("\r\n\r\n") + 4 :])


def _has_header(wire: String, name: String) -> Bool:
    var head = String(wire[byte = 0 : wire.find("\r\n\r\n")]).lower()
    return (String("\r\n") + name.lower() + ":") in head


def _rt() raises -> _RT:
    return _RT.new(NoopSink(_placeholder=UInt8(0)))


comptime _RUNNING = (
    '{"name":"operations/op-1",'
    + '"metadata":{"@type":"type.googleapis.com/google.api.serviceusage.v1.OperationMetadata",'
    + '"resourceNames":["services/run.googleapis.com/projectSettings/123456789012"]}}'
)

comptime _DONE = (
    '{"name":"operations/noop.DONE_OPERATION","done":true,"response":'
    + '{"@type":"type.googleapis.com/google.api.serviceusage.v1.EnableServiceResponse",'
    + '"service":{"name":"projects/123456789012/services/run.googleapis.com",'
    + '"parent":"projects/123456789012","state":"ENABLED"}}}'
)

comptime _FAILED = (
    '{"name":"operations/op-2","done":true,"error":'
    + '{"code":9,"message":"Billing must be enabled for activation of service",'
    + '"details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo",'
    + '"reason":"UREQ_PROJECT_BILLING_NOT_FOUND","domain":"serviceusage.googleapis.com"}]}}'
)


def test_enable_sends_the_name_in_the_path_and_reads_a_running_operation() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String(_RUNNING))
    var rt = _rt()
    ref reactor = rt.reactor()
    var op = c.enable_service[_RT](EnableServiceRequest(String(_SVC)), reactor)
    var wire = _wire(capture)
    assert_equal(
        _request_line(wire),
        "POST /v1/projects/demo-project/services/run.googleapis.com:enable HTTP/1.1",
    )
    assert_true(_has_header(wire, "content-type"))
    # `name` is in the path, so the body is every other field: none.
    assert_equal(_body(wire), "{}")

    assert_equal(op.name, "operations/op-1")
    assert_false(op.done)
    assert_false(Bool(op.error))
    assert_false(Bool(op.response))
    assert_equal(
        op.metadata.value().type_url,
        "type.googleapis.com/google.api.serviceusage.v1.OperationMetadata",
    )


def test_enable_reads_an_operation_that_is_already_done() raises:
    # Enabling an enabled service answers with a finished no-op operation
    # whose response holds the service.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String(_DONE))
    var rt = _rt()
    ref reactor = rt.reactor()
    var op = c.enable_service[_RT](EnableServiceRequest(String(_SVC)), reactor)
    assert_true(op.done)
    assert_false(Bool(op.error))
    ref resp = op.response.value()
    assert_equal(
        resp.type_url,
        "type.googleapis.com/google.api.serviceusage.v1.EnableServiceResponse",
    )
    assert_equal(len(resp.json_members.obj_keys), 1)
    assert_equal(resp.json_members.obj_keys[0], "service")


def test_enable_reads_a_failed_operation() raises:
    # A 200 can carry a failure: the operation is done with an error, a
    # google.rpc.Status (here FAILED_PRECONDITION, code 9).
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String(_FAILED))
    var rt = _rt()
    ref reactor = rt.reactor()
    var op = c.enable_service[_RT](EnableServiceRequest(String(_SVC)), reactor)
    assert_true(op.done)
    assert_false(Bool(op.response))
    ref err = op.error.value()
    assert_equal(err.code, 9)
    assert_equal(len(err.details), 1)
    assert_equal(err.details[0].type_url, "type.googleapis.com/google.rpc.ErrorInfo")


def test_disable() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String(_RUNNING))
    var rt = _rt()
    ref reactor = rt.reactor()
    _ = c.disable_service[_RT](
        DisableServiceRequest(
            String(_SVC),
            False,
            DisableServiceRequest_CheckIfServiceHasUsage(
                DisableServiceRequest_CheckIfServiceHasUsage.CHECK
            ),
        ),
        reactor,
    )
    var wire = _wire(capture)
    assert_equal(
        _request_line(wire),
        "POST /v1/projects/demo-project/services/run.googleapis.com:disable HTTP/1.1",
    )
    assert_equal(
        _body(wire),
        '{"disableDependentServices":false,"checkIfServiceHasUsage":"CHECK"}',
    )


def test_get_reads_the_state_and_skips_the_config() raises:
    # The answer as the API gives it, `config` included; only the name,
    # parent and state are read.
    var answer = String(
        '{"name":"projects/123456789012/services/run.googleapis.com",'
        + '"config":{"name":"run.googleapis.com","title":"Cloud Run Admin API",'
        + '"apis":[{"name":"google.cloud.run.v2.Services","methods":[{"name":"GetService"}]}],'
        + '"quota":{"limits":[{"name":"x","values":{"STANDARD":"600"}}]},'
        + '"usage":{"requirements":["serviceusage.googleapis.com/tos/cloud"]}},'
        + '"state":"ENABLED","parent":"projects/123456789012"}'
    )
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, answer)
    var rt = _rt()
    ref reactor = rt.reactor()
    var s = c.get_service[_RT](GetServiceRequest(String(_SVC)), reactor)
    var wire = _wire(capture)
    assert_equal(
        _request_line(wire),
        "GET /v1/projects/demo-project/services/run.googleapis.com HTTP/1.1",
    )
    assert_equal(_body(wire), "")
    assert_false(_has_header(wire, "content-type"))
    assert_equal(s.name, "projects/123456789012/services/run.googleapis.com")
    assert_equal(s.parent, "projects/123456789012")
    assert_true(s.state == State(State.ENABLED))


def test_get_of_a_service_never_enabled_reads_disabled() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(
        capture,
        String(
            '{"name":"projects/123456789012/services/apigateway.googleapis.com",'
            + '"state":"DISABLED","parent":"projects/123456789012"}'
        ),
    )
    var rt = _rt()
    ref reactor = rt.reactor()
    var s = c.get_service[_RT](
        GetServiceRequest(String("projects/demo-project/services/apigateway.googleapis.com")),
        reactor,
    )
    assert_true(s.state == State(State.DISABLED))


def test_a_name_outside_the_binding_is_refused_before_the_dial() raises:
    # A bare service name has no parent: `*/*/services/*` refuses it.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String(_RUNNING))
    var rt = _rt()
    ref reactor = rt.reactor()
    var raised = String("")
    try:
        _ = c.enable_service[_RT](
            EnableServiceRequest(String("run.googleapis.com")), reactor
        )
    except e:
        raised = String(e)
    assert_equal(raised, "path variable `name` does not match `*/*/services/*`")
    assert_equal(c._client._connector.connect_call_count(), 0)


def main() raises:
    test_enable_sends_the_name_in_the_path_and_reads_a_running_operation()
    test_enable_reads_an_operation_that_is_already_done()
    test_enable_reads_a_failed_operation()
    test_disable()
    test_get_reads_the_state_and_skips_the_config()
    test_get_of_a_service_never_enabled_reads_disabled()
    test_a_name_outside_the_binding_is_refused_before_the_dial()
    print("OK")
