# komira_gcp_apigateway

A REST/JSON client for Google Cloud API Gateway v1, generated at build time
from the pinned googleapis protos. `ApiGatewayServiceClient[C, T]` sends
through komira_http_client's `HttpClient` over the komira_http_core
`Connector` it is given, takes each request's bearer token from a
komira_gcp_core `GcpTokenSource`, and raises a non-2xx answer through
komira_gcp_core's `gcp_status_error`. It reads no environment.

Nine methods are generated: Create, Get and Delete of an `Api`, of its
`ApiConfig` (the OpenAPI document and the service account the gateway calls
the backend as) and of the `Gateway` serving it. Not generated:
UpdateGateway, the listings, the Api and ApiConfig updates, and the
operation poll: Create and Delete answer a google.longrunning `Operation`,
and this package cannot follow it. The client starts at
`apigateway.googleapis.com`; `set_rest_host` points it elsewhere.

The messages live in `komira_gcp_apigateway.apigateway`, the client in
`komira_gcp_apigateway.apigateway_service` and `Operation` in
`komira_gcp_apigateway.operations`.

## Examples

The examples send over komira_http_core's `ScriptedConnector`, which answers
from a script and records what was written: no socket is opened and
`localhost` needs no name lookup. Reading a gateway back: the request line
and bearer header the client wrote, and the answer decoded into a `Gateway`:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_apigateway.apigateway import Api, CreateApiRequest, Gateway_State, GetGatewayRequest
from komira_gcp_apigateway.apigateway_service import ApiGatewayServiceClient
from komira_gcp_core import CODE_NOT_FOUND, StaticTokenSource, gcp_status_error_code
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json_lenient

comptime Runtime = BlockingRuntime[NoopSink]
comptime Client = ApiGatewayServiceClient[ScriptedConnector, StaticTokenSource]

def http_answer(status: String, body: String) -> List[UInt8]:
    var text = (
        String("HTTP/1.1 ") + status + "\r\nContent-Type: application/json\r\n"
        + "Content-Length: " + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n" + body
    )
    var out = List[UInt8]()
    out.extend(Span(text.as_bytes()))
    return out^

def scripted_client(answer: List[UInt8], sent: ArcPointer[List[UInt8]]) raises -> Client:
    var stream = ScriptedStream.from_read_script_with_capture(answer.copy(), sent)
    var c = Client(
        HttpClient[ScriptedConnector].with_defaults(ScriptedConnector.with_stream_tls(stream^)),
        StaticTokenSource(String("test-access-token")),
    )
    c.set_rest_host(String("localhost"))
    return c^

var sent = ArcPointer[List[UInt8]](List[UInt8]())
var c = scripted_client(
    http_answer(
        "200 OK",
        '{"name":"projects/demo/locations/us-central1/gateways/orders-gw",'
        + '"apiConfig":"projects/demo/locations/global/apis/orders/configs/v1",'
        + '"state":"ACTIVE","defaultHostname":"orders-gw.example"}',
    ),
    sent,
)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var gw = c.get_gateway[Runtime](
    GetGatewayRequest(String("projects/demo/locations/us-central1/gateways/orders-gw")),
    reactor,
)
var wire = String(unsafe_from_utf8=Span(sent[]))
assert_true(wire.startswith(
    "GET /v1/projects/demo/locations/us-central1/gateways/orders-gw HTTP/1.1\r\n"
))
assert_true("\r\nauthorization: Bearer test-access-token\r\n" in wire)
assert_true(gw.state == Gateway_State(Gateway_State.ACTIVE))
assert_equal(gw.default_hostname, "orders-gw.example")
```

Creating an Api sends the message as JSON with the id in the query, and
answers the long-running `Operation`, here not yet done:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_apigateway.apigateway import Api, CreateApiRequest
from komira_gcp_apigateway.apigateway_service import ApiGatewayServiceClient
from komira_gcp_core import StaticTokenSource
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_proto_codec.codec import decode_json_lenient

comptime Runtime = BlockingRuntime[NoopSink]

comptime Client = ApiGatewayServiceClient[ScriptedConnector, StaticTokenSource]

def http_answer(status: String, body: String) -> List[UInt8]:
    var text = (
        String("HTTP/1.1 ") + status + "\r\nContent-Type: application/json\r\n"
        + "Content-Length: " + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n" + body
    )
    var out = List[UInt8]()
    out.extend(Span(text.as_bytes()))
    return out^

def scripted_client(answer: List[UInt8], sent: ArcPointer[List[UInt8]]) raises -> Client:
    var stream = ScriptedStream.from_read_script_with_capture(answer.copy(), sent)
    var c = Client(
        HttpClient[ScriptedConnector].with_defaults(ScriptedConnector.with_stream_tls(stream^)),
        StaticTokenSource(String("test-access-token")),
    )
    c.set_rest_host(String("localhost"))
    return c^
-->
```mojo
var sent = ArcPointer[List[UInt8]](List[UInt8]())
var c = scripted_client(
    http_answer(
        "200 OK",
        '{"name":"projects/demo/locations/global/operations/operation-1","done":false}',
    ),
    sent,
)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var api = decode_json_lenient[Api](String('{"displayName":"orders"}'))
var op = c.create_api[Runtime](
    CreateApiRequest(String("projects/demo/locations/global"), String("orders"), api^),
    reactor,
)
var wire = String(unsafe_from_utf8=Span(sent[]))
assert_true(wire.startswith(
    "POST /v1/projects/demo/locations/global/apis?apiId=orders HTTP/1.1\r\n"
))
assert_true(wire.endswith('\r\n\r\n{"displayName":"orders"}'))
assert_equal(op.name, "projects/demo/locations/global/operations/operation-1")
assert_false(op.done)
```

A non-2xx answer raises. The error names the verb, the method, the HTTP
status and the canonical code from the `google.rpc.Status` envelope, and
quotes no byte of the body; `gcp_status_error_code` reads the code back:

<!-- mojo-hidden
from std.testing import assert_equal, assert_false, assert_true
from std.memory import ArcPointer
from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_gcp_apigateway.apigateway import GetGatewayRequest
from komira_gcp_apigateway.apigateway_service import ApiGatewayServiceClient
from komira_gcp_core import CODE_NOT_FOUND, StaticTokenSource, gcp_status_error_code
from komira_http_client.client import HttpClient
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

comptime Runtime = BlockingRuntime[NoopSink]

comptime Client = ApiGatewayServiceClient[ScriptedConnector, StaticTokenSource]

def http_answer(status: String, body: String) -> List[UInt8]:
    var text = (
        String("HTTP/1.1 ") + status + "\r\nContent-Type: application/json\r\n"
        + "Content-Length: " + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n" + body
    )
    var out = List[UInt8]()
    out.extend(Span(text.as_bytes()))
    return out^

def scripted_client(answer: List[UInt8], sent: ArcPointer[List[UInt8]]) raises -> Client:
    var stream = ScriptedStream.from_read_script_with_capture(answer.copy(), sent)
    var c = Client(
        HttpClient[ScriptedConnector].with_defaults(ScriptedConnector.with_stream_tls(stream^)),
        StaticTokenSource(String("test-access-token")),
    )
    c.set_rest_host(String("localhost"))
    return c^
-->
```mojo
var sent = ArcPointer[List[UInt8]](List[UInt8]())
var c = scripted_client(
    http_answer(
        "404 Not Found",
        '{"error":{"code":404,"message":"Resource secret-gw was not found",'
        + '"status":"NOT_FOUND"}}',
    ),
    sent,
)
var rt = Runtime.new(NoopSink(_placeholder=UInt8(0)))
ref reactor = rt.reactor()
var raised = String()
try:
    _ = c.get_gateway[Runtime](
        GetGatewayRequest(String("projects/demo/locations/us-central1/gateways/secret-gw")),
        reactor,
    )
except e:
    raised = String(e)
assert_true(raised.startswith("GET GetGateway: HTTP 404, NOT_FOUND (code 5)"))
assert_false("secret-gw" in raised)
assert_equal(gcp_status_error_code("GET", "GetGateway", raised), CODE_NOT_FOUND)
```
