# The long-running operations Cloud Run's mutating methods return, polled
# through the generated `OperationsClient` (the google.longrunning.Operations
# mixin, bound to Run's paths by run_v2.yaml's http.rules): GetOperation and
# WaitOperation, each once on the wire byte for byte, and the three states
# a caller reads off the Operation (running, done with a response, done
# with an error).
#
# A done operation's `response` is a google.protobuf.Any, which komira_wkt
# keeps opaque (`type_url` and the JSON members as sent); a caller that
# knows the type decodes the members as it, as the Service case below
# does. A failed operation answers 200 with `error` set: the call returns,
# and the google.rpc.Status is the caller's to read.
#
# The expected forms are written here from the Cloud Run Admin v2 REST
# reference (projects.locations.operations.get, .wait); no upstream test
# body is copied. The connector is komira_http_core's ScriptedConnector
# with a shared write capture; no socket is opened. The client is pointed
# at `localhost` with `set_rest_host`.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_core import StaticTokenSource
from komira_gcp_run.condition import Condition_State
from komira_gcp_run.operations import (
    GetOperationRequest,
    OperationsClient,
    WaitOperationRequest,
)
from komira_gcp_run.service import Service
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json, decode_json_lenient


comptime _RT = BlockingRuntime[NoopSink]
comptime _Client = OperationsClient[ScriptedConnector, StaticTokenSource]

comptime _OP = "projects/demo-project/locations/us-central1/operations/0f8e3a"


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


def _client(capture: ArcPointer[List[UInt8]], answer: String) raises -> _Client:
    var c = _Client(
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


def _expected(target: String, body: String = "") -> String:
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


def test_get_operation_done_with_a_service() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(
        capture,
        String('{"name":"')
        + _OP
        + '","metadata":{"@type":"type.googleapis.com/google.cloud.run.v2.Service",'
        + '"name":"projects/demo-project/locations/us-central1/services/web"},'
        + '"done":true,"response":{"@type":"type.googleapis.com/google.cloud.run.v2.Service",'
        + '"name":"projects/demo-project/locations/us-central1/services/web",'
        + '"generation":"4","terminalCondition":{"type":"Ready","state":"CONDITION_SUCCEEDED"},'
        + '"uri":"https://web-5q2kx3abcd-uc.a.run.app"}}',
    )
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.get_operation[_RT](
        decode_json[GetOperationRequest](String('{"name":"') + _OP + '"}'), reactor
    )
    assert_equal(_wire(capture), _expected(String("GET /v2/") + _OP))
    assert_equal(op.name, _OP)
    assert_true(op.done)
    assert_false(Bool(op.error))
    ref response = op.response.value()
    assert_equal(response.type_url, "type.googleapis.com/google.cloud.run.v2.Service")
    var svc = decode_json_lenient[Service](response.json_members.serialize())
    assert_equal(svc.name, "projects/demo-project/locations/us-central1/services/web")
    assert_equal(svc.generation, Int64(4))
    assert_true(
        svc.terminal_condition.value().state
        == Condition_State(Condition_State.CONDITION_SUCCEEDED)
    )
    assert_equal(svc.uri, "https://web-5q2kx3abcd-uc.a.run.app")


def test_get_operation_still_running() raises:
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, String('{"name":"') + _OP + '"}')
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.get_operation[_RT](
        decode_json[GetOperationRequest](String('{"name":"') + _OP + '"}'), reactor
    )
    # An operation in flight may omit `done` entirely: absent is false.
    assert_false(op.done)
    assert_false(Bool(op.response))
    assert_false(Bool(op.error))


def test_wait_operation_done_with_an_error() raises:
    # POST .../operations/{operation}:wait with `body: "*"`: the service
    # holds the call up to `timeout` and answers with the operation.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(
        capture,
        String('{"name":"')
        + _OP
        + '","done":true,"error":{"code":9,"message":"Revision web-00004-zzq is not'
        + ' ready and cannot serve traffic.","details":[{"@type":'
        + '"type.googleapis.com/google.rpc.ErrorInfo","reason":"HEALTH_CHECK_FAILED"}]}}',
    )
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.wait_operation[_RT](
        decode_json[WaitOperationRequest](
            String('{"name":"') + _OP + '","timeout":"30s"}'
        ),
        reactor,
    )
    assert_equal(
        _wire(capture),
        _expected(
            String("POST /v2/") + _OP + ":wait",
            String('{"timeout":"30s"}'),
        ),
    )
    assert_true(op.done)
    assert_false(Bool(op.response))
    ref status = op.error.value()
    assert_equal(status.code, Int32(9))
    assert_equal(
        status.message, "Revision web-00004-zzq is not ready and cannot serve traffic."
    )
    assert_equal(len(status.details), 1)
    assert_equal(status.details[0].type_url, "type.googleapis.com/google.rpc.ErrorInfo")


def test_an_operation_outside_runs_paths_is_refused_before_any_send() raises:
    # The binding is Run's: `projects/*/locations/*/operations/*`. A bare
    # `operations/...` name (the mixin's own default path) does not match it.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var c = _client(capture, "{}")
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var raised = False
    try:
        _ = c.get_operation[_RT](
            decode_json[GetOperationRequest]('{"name":"operations/0f8e3a"}'), reactor
        )
    except:
        raised = True
    assert_true(raised)
    assert_equal(c._client._connector.connect_call_count(), 0)


def main() raises:
    test_get_operation_done_with_a_service()
    test_get_operation_still_running()
    test_wait_operation_done_with_an_error()
    test_an_operation_outside_runs_paths_is_refused_before_any_send()
    print("OK")
