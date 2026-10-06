# The requests the generated `ApiGatewayServiceClient` puts on the wire,
# one test per generated method, in the order a deploy builds an API edge:
# CreateApi, GetApi and DeleteApi; CreateApiConfig (an OpenAPI document),
# GetApiConfig and DeleteApiConfig; CreateGateway, GetGateway and
# DeleteGateway. Each sends through the client over komira_http_core's
# ScriptedConnector with a shared write capture (no socket) and checks the
# request line and body and the response it decoded. The client is pointed
# at `localhost`, so the send resolves no name; the default host is
# test_apigateway_default_host's.
#
# The expected forms are written from the API Gateway v1 REST reference
# (projects.locations.apis, apis.configs and gateways: create, get,
# delete): the parent or name in the path, `apiId`, `apiConfigId`,
# `gatewayId` and `view` in the query, and the resource as the body of a
# create. An OpenAPI document's `contents` is bytes, base64 in JSON. `view`
# is an enum and goes into the query as its name (`view=FULL`); left at its
# zero value (CONFIG_VIEW_UNSPECIFIED) it is not sent at all, as the proto3
# JSON mapping omits a default.
#
# A create body holds only the fields the caller set: a plain scalar or enum
# left at its default (`name`, the output-only `state`, the
# `*_UNSPECIFIED` enums) is omitted, as the proto3 JSON mapping omits it.
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_apigateway.apigateway import (
    Api,
    ApiConfig,
    ApiConfig_State,
    CreateApiConfigRequest,
    CreateApiRequest,
    CreateGatewayRequest,
    DeleteApiConfigRequest,
    DeleteApiRequest,
    DeleteGatewayRequest,
    Gateway,
    Gateway_State,
    GetApiConfigRequest,
    GetApiConfigRequest_ConfigView,
    GetApiRequest,
    GetGatewayRequest,
)
from komira_gcp_apigateway.apigateway_service import ApiGatewayServiceClient
from komira_gcp_core import StaticTokenSource
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json_lenient


comptime _RT = BlockingRuntime[NoopSink]
comptime SC = ScriptedConnector
comptime TS = StaticTokenSource
comptime _CLIENT = ApiGatewayServiceClient[SC, TS]
comptime _API = "projects/demo-project/locations/global/apis/orders"

# A long-running operation as every create and delete answers it.
comptime _LRO = (
    '{"name":"projects/demo-project/locations/global/operations/operation-9",'
    + '"metadata":{"@type":"type.googleapis.com/google.cloud.apigateway.v1.OperationMetadata",'
    + '"verb":"create"},"done":false}'
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


def _client(capture: ArcPointer[List[UInt8]], answer: String) raises -> _CLIENT:
    var c = _CLIENT(_http(capture, answer), _token())
    c.set_rest_host(String("localhost"))
    return c^


def test_create_api() raises:
    var capture = _capture()
    var c = _client(capture, _LRO)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var api = decode_json_lenient[Api](
        String('{"displayName":"orders","labels":{"app":"orders"}}')
    )
    var op = c.create_api[_RT](
        CreateApiRequest(
            String("projects/demo-project/locations/global"), String("orders"), api^
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "POST /v1/projects/demo-project/locations/global/apis?apiId=orders HTTP/1.1",
    )
    assert_equal(
        _body(capture),
        '{"labels":{"app":"orders"},"displayName":"orders"}',
    )
    assert_equal(
        op.name, "projects/demo-project/locations/global/operations/operation-9"
    )
    assert_false(op.done)


def test_get_api() raises:
    var capture = _capture()
    var answer = String(
        '{"name":"' + _API + '","displayName":"orders","state":"ACTIVE",'
        + '"managedService":"orders-0a1b2c.apigateway.demo-project.cloud.goog"}'
    )
    var c = _client(capture, answer)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var api = c.get_api[_RT](GetApiRequest(String(_API)), reactor)
    assert_equal(
        _head(capture),
        "GET /v1/projects/demo-project/locations/global/apis/orders HTTP/1.1",
    )
    assert_equal(_body(capture), "")
    assert_equal(api.managed_service, "orders-0a1b2c.apigateway.demo-project.cloud.goog")


def test_delete_api() raises:
    var capture = _capture()
    var c = _client(capture, _LRO)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    _ = c.delete_api[_RT](DeleteApiRequest(String(_API)), reactor)
    assert_equal(
        _head(capture),
        "DELETE /v1/projects/demo-project/locations/global/apis/orders HTTP/1.1",
    )
    assert_equal(_body(capture), "")


def test_create_api_config_with_an_openapi_document() raises:
    var capture = _capture()
    var c = _client(capture, _LRO)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    # `contents` is the document's bytes: "swagger: '2.0'\n", base64.
    var config = decode_json_lenient[ApiConfig](
        String(
            '{"displayName":"orders-v1",'
            + '"gatewayServiceAccount":"projects/-/serviceAccounts/edge@demo-project.iam.gserviceaccount.com",'
            + '"openapiDocuments":[{"document":{"path":"openapi.yaml",'
            + '"contents":"c3dhZ2dlcjogJzIuMCcK"}}]}'
        )
    )
    assert_equal(len(config.openapi_documents[0].document.value().contents), 15)
    _ = c.create_api_config[_RT](
        CreateApiConfigRequest(String(_API), String("orders-v1"), config^),
        reactor,
    )
    assert_equal(
        _head(capture),
        "POST /v1/projects/demo-project/locations/global/apis/orders/configs"
        + "?apiConfigId=orders-v1 HTTP/1.1",
    )
    var body = _body(capture)
    assert_true(
        '"openapiDocuments":[{"document":{"path":"openapi.yaml",'
        + '"contents":"c3dhZ2dlcjogJzIuMCcK"}}]' in body
    )
    assert_true(
        '"gatewayServiceAccount":"projects/-/serviceAccounts/edge@demo-project.iam.gserviceaccount.com"'
        in body
    )
    var sent = decode_json_lenient[ApiConfig](body)
    assert_equal(sent.display_name, "orders-v1")


def test_get_api_config_full_view() raises:
    var capture = _capture()
    var answer = String(
        '{"name":"' + _API + '/configs/orders-v1","state":"ACTIVE",'
        + '"serviceConfigId":"orders-v1-0a1b2c3d4e5f"}'
    )
    var c = _client(capture, answer)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var config = c.get_api_config[_RT](
        GetApiConfigRequest(
            String(_API + "/configs/orders-v1"),
            GetApiConfigRequest_ConfigView(GetApiConfigRequest_ConfigView.FULL),
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "GET /v1/projects/demo-project/locations/global/apis/orders/configs/orders-v1"
        + "?view=FULL HTTP/1.1",
    )
    assert_true(config.state == ApiConfig_State(ApiConfig_State.ACTIVE))
    assert_equal(config.service_config_id, "orders-v1-0a1b2c3d4e5f")


def test_get_api_config_unspecified_view_is_not_sent() raises:
    var capture = _capture()
    var c = _client(capture, '{"name":"x"}')
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    _ = c.get_api_config[_RT](
        GetApiConfigRequest(
            String(_API + "/configs/orders-v1"),
            GetApiConfigRequest_ConfigView(
                GetApiConfigRequest_ConfigView.CONFIG_VIEW_UNSPECIFIED
            ),
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "GET /v1/projects/demo-project/locations/global/apis/orders/configs/orders-v1"
        + " HTTP/1.1",
    )


def test_delete_api_config() raises:
    var capture = _capture()
    var c = _client(capture, _LRO)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    _ = c.delete_api_config[_RT](
        DeleteApiConfigRequest(String(_API + "/configs/orders-v1")), reactor
    )
    assert_equal(
        _head(capture),
        "DELETE /v1/projects/demo-project/locations/global/apis/orders/configs/orders-v1 HTTP/1.1",
    )


def test_create_gateway() raises:
    var capture = _capture()
    var c = _client(capture, _LRO)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var gw = decode_json_lenient[Gateway](
        String(
            '{"displayName":"orders","apiConfig":"' + _API + '/configs/orders-v1"}'
        )
    )
    _ = c.create_gateway[_RT](
        CreateGatewayRequest(
            String("projects/demo-project/locations/us-central1"),
            String("orders-gw"),
            gw^,
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "POST /v1/projects/demo-project/locations/us-central1/gateways"
        + "?gatewayId=orders-gw HTTP/1.1",
    )
    assert_equal(
        _body(capture),
        '{"displayName":"orders",'
        + '"apiConfig":"projects/demo-project/locations/global/apis/orders/configs/orders-v1"}',
    )


def test_get_gateway() raises:
    var capture = _capture()
    var answer = String(
        '{"name":"projects/demo-project/locations/us-central1/gateways/orders-gw",'
        + '"apiConfig":"' + _API + '/configs/orders-v1","state":"ACTIVE",'
        + '"defaultHostname":"orders-gw-0a1b2c3d.uc.gateway.dev",'
        + '"createTime":"2026-10-02T10:00:00Z"}'
    )
    var c = _client(capture, answer)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var gw = c.get_gateway[_RT](
        GetGatewayRequest(
            String("projects/demo-project/locations/us-central1/gateways/orders-gw")
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "GET /v1/projects/demo-project/locations/us-central1/gateways/orders-gw HTTP/1.1",
    )
    assert_true(gw.state == Gateway_State(Gateway_State.ACTIVE))
    assert_equal(gw.default_hostname, "orders-gw-0a1b2c3d.uc.gateway.dev")
    assert_equal(gw.api_config, _API + "/configs/orders-v1")
    assert_true(gw.create_time)


def test_delete_gateway() raises:
    var capture = _capture()
    var c = _client(capture, _LRO)
    var rt = _RT.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var op = c.delete_gateway[_RT](
        DeleteGatewayRequest(
            String("projects/demo-project/locations/us-central1/gateways/orders-gw")
        ),
        reactor,
    )
    assert_equal(
        _head(capture),
        "DELETE /v1/projects/demo-project/locations/us-central1/gateways/orders-gw HTTP/1.1",
    )
    assert_equal(
        op.metadata.value().type_url,
        "type.googleapis.com/google.cloud.apigateway.v1.OperationMetadata",
    )


def main() raises:
    test_create_api()
    test_get_api()
    test_delete_api()
    test_create_api_config_with_an_openapi_document()
    test_get_api_config_full_view()
    test_get_api_config_unspecified_view_is_not_sent()
    test_delete_api_config()
    test_create_gateway()
    test_get_gateway()
    test_delete_gateway()
    print("OK")
