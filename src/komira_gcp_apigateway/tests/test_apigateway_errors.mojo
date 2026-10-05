# Two ways an API Gateway call fails. A non-2xx answer raises through
# komira_gcp_core's `gcp_status_error`: the error names the verb, the RPC,
# the HTTP status and the canonical code from the `google.rpc.Status`
# envelope's `status`, and counts bytes, never repeating a byte of the body.
# And a create or delete that was accepted (200, a google.longrunning
# Operation) can fail later: the operation comes back `done` with an
# `error` (a google.rpc.Status), which a caller following it reads.
#
# The envelopes are written in the form the Cloud APIs error model documents;
# the connector is komira_http_core's ScriptedConnector pointed at
# `localhost` (no socket, no name lookup).
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_apigateway.apigateway import (
    Api,
    CreateApiRequest,
    GetGatewayRequest,
)
from komira_gcp_apigateway.apigateway_service import ApiGatewayServiceClient
from komira_gcp_apigateway.operations import Operation
from komira_gcp_core import StaticTokenSource
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json_lenient


comptime _RT = BlockingRuntime[NoopSink]
comptime SC = ScriptedConnector
comptime TS = StaticTokenSource
comptime _GATEWAY = "projects/private-project/locations/us-central1/gateways/orders-gw"


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


def _client(var answer: List[UInt8]) raises -> ApiGatewayServiceClient[SC, TS]:
    var c = ApiGatewayServiceClient[SC, TS](
        HttpClient[SC].with_defaults(
            SC.with_stream_tls(ScriptedStream.from_read_script(answer^))
        ),
        TS(String("test-access-token")),
    )
    c.set_rest_host(String("localhost"))
    return c^


def _get_raised(var answer: List[UInt8]) raises -> String:
    var c = _client(answer^)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    try:
        _ = c.get_gateway[_RT](GetGatewayRequest(String(_GATEWAY)), reactor)
    except e:
        return String(e)
    raise Error("GetGateway returned on a non-2xx answer")


def _create_raised(var answer: List[UInt8]) raises -> String:
    var c = _client(answer^)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var api = decode_json_lenient[Api](String('{"displayName":"orders"}'))
    try:
        _ = c.create_api[_RT](
            CreateApiRequest(
                String("projects/private-project/locations/global"),
                String("orders"),
                api^,
            ),
            reactor,
        )
    except e:
        return String(e)
    raise Error("CreateApi returned on a non-2xx answer")


def test_gateway_not_found() raises:
    var message = String("Resource '") + _GATEWAY + String("' was not found")
    var body = String('{"error":{"code":404,"message":"') + message + String(
        '","status":"NOT_FOUND"}}'
    )
    var got = _get_raised(_answer("404 Not Found", body))
    assert_equal(
        got,
        String("GET GetGateway: HTTP 404, NOT_FOUND (code 5), error.message ")
        + String(message.byte_length())
        + " bytes, body "
        + String(body.byte_length())
        + " bytes",
    )
    assert_false("private-project" in got)
    assert_false("orders-gw" in got)


def test_api_already_exists() raises:
    var body = String(
        '{"error":{"code":409,"message":"Resource'
        + " 'projects/private-project/locations/global/apis/orders' already"
        + ' exists","status":"ALREADY_EXISTS"}}'
    )
    var got = _create_raised(_answer("409 Conflict", body))
    assert_true(got.startswith("POST CreateApi: HTTP 409, ALREADY_EXISTS (code 6), "))
    assert_false("private-project" in got)


def test_user_credentials_refused() raises:
    # The admin API answers a principal it does not accept with 403.
    var body = String(
        '{"error":{"code":403,"message":"The caller does not have permission",'
        + '"status":"PERMISSION_DENIED"}}'
    )
    var got = _create_raised(_answer("403 Forbidden", body))
    assert_true(got.startswith("POST CreateApi: HTTP 403, PERMISSION_DENIED (code 7), "))
    assert_false("caller" in got)


def test_an_accepted_create_that_failed_later() raises:
    var op = decode_json_lenient[Operation](
        String(
            '{"name":"projects/demo-project/locations/global/operations/operation-9",'
            + '"done":true,"error":{"code":3,"message":"Cannot convert to service'
            + ' config: openapi.yaml: unknown field"}}'
        )
    )
    assert_true(op.done)
    assert_equal(op.error.value().code, Int32(3))
    assert_false(op.response)


def main() raises:
    test_gateway_not_found()
    test_api_already_exists()
    test_user_credentials_refused()
    test_an_accepted_create_that_failed_later()
    print("OK")
