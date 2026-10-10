# komira_connect

The server side of [Connect-RPC](https://connectrpc.com): one method table
answering three wire protocols.

- gRPC (`application/grpc`, `application/grpc+proto`; HTTP/2),
- gRPC-Web (`application/grpc-web`, `application/grpc-web+proto`),
- Connect (`application/json` and `application/proto` unary,
  `application/connect+json` and `application/connect+proto` streaming).

`ConnectService` maps a method path (`/<package.Service>/<Method>`) to a
handler, `def (codec_id: UInt8, request: List[UInt8]) raises -> List[UInt8]`,
plus server- and client-streaming handlers. `handle_request(path,
content_type, body)` picks the codec from the content type, unwraps the
request, calls the handler and wraps the answer, returning a
`DispatchResult` (body, HTTP status, gRPC status and message). An unknown
path is `NOT_FOUND`, an unknown content type `UNIMPLEMENTED`; a handler that
raises a `format_connect_error(code, message)` text gets that status, any
other error is `UNKNOWN`. `register_connect_wildcard` adds the one POST `/*`
route a `komira_http_server` router needs to send RPC calls here.

Each layer is public on its own: the 5-byte message envelope
(`write_envelope`, `split_envelopes`), the gRPC, gRPC-Web and Connect-JSON
codecs (unary and stream bodies, trailers, error envelopes), the 17 gRPC
status codes with their HTTP and Connect names, and `grpc-timeout` /
`connect-timeout-ms` parsing.

Payloads are opaque bytes: it does not generate code from `.proto` files,
encode protobuf messages or parse JSON message bodies, and it rejects
compressed messages. It is a server; there is no client here.

## Examples

A service with two methods, called through each protocol in memory:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_connect import CODEC_ID_CONNECT_JSON, CODEC_ID_GRPC
from komira_connect import CONNECT_JSON_CONTENT_TYPE_UNARY, GRPC_CONTENT_TYPE_PROTO
from komira_connect import GRPC_STATUS_INVALID_ARGUMENT, GRPC_STATUS_NOT_FOUND
from komira_connect import GRPC_STATUS_OK, GRPC_STATUS_UNIMPLEMENTED
from komira_connect import GRPC_WEB_CONTENT_TYPE_PROTO, ConnectService
from komira_connect import format_connect_error, grpc_decode_unary, grpc_encode_unary
from komira_connect import grpc_web_decode_response, grpc_web_encode_request

def echo(codec_id: UInt8, request: List[UInt8]) raises -> List[UInt8]:
    return request.copy()

def reject(codec_id: UInt8, request: List[UInt8]) raises -> List[UInt8]:
    raise Error(format_connect_error(GRPC_STATUS_INVALID_ARGUMENT, "bad input"))

def as_text(bytes: List[UInt8]) -> String:
    var out = String()
    for i in range(len(bytes)):
        out += chr(Int(bytes[i]))
    return out^

var svc = ConnectService("demo.v1.Demo")
svc.register_method("/demo.v1.Demo/Echo", echo)
svc.register_method("/demo.v1.Demo/Reject", reject)
assert_equal(svc.method_count(), 2)

# gRPC: the request and the response are one envelope-framed message.
var message: List[UInt8] = [0x0A, 0x02, 0x68, 0x69]
var grpc_request = grpc_encode_unary(Span(message))
assert_equal(len(grpc_request), 5 + 4)  # flags byte, 4-byte length, payload
var grpc = svc.handle_request("/demo.v1.Demo/Echo", GRPC_CONTENT_TYPE_PROTO, Span(grpc_request))
assert_true(grpc.is_ok())
assert_equal(grpc.codec_id, CODEC_ID_GRPC)
assert_equal(len(grpc_decode_unary(Span(grpc.body))), 4)

# gRPC-Web: the trailers travel in the body, after the message.
var web_request = grpc_web_encode_request(Span(message))
var web = svc.handle_request("/demo.v1.Demo/Echo", GRPC_WEB_CONTENT_TYPE_PROTO, Span(web_request))
var decoded = grpc_web_decode_response(Span(web.body))
assert_equal(len(decoded.messages), 1)
assert_true(decoded.saw_trailers)
assert_equal(decoded.trailers.status_code, GRPC_STATUS_OK)

# Connect with JSON: the body is the JSON message itself; an error is a
# JSON envelope with the mapped HTTP status.
var json: List[UInt8] = [0x7B, 0x7D]  # {}
var ok = svc.handle_request("/demo.v1.Demo/Echo", CONNECT_JSON_CONTENT_TYPE_UNARY, Span(json))
assert_equal(ok.codec_id, CODEC_ID_CONNECT_JSON)
assert_equal(as_text(ok.body), "{}")
var bad = svc.handle_request("/demo.v1.Demo/Reject", CONNECT_JSON_CONTENT_TYPE_UNARY, Span(json))
assert_equal(bad.grpc_status, GRPC_STATUS_INVALID_ARGUMENT)
assert_equal(bad.http_status, 400)
assert_equal(as_text(bad.body), '{"code":"invalid_argument","message":"bad input"}')

var missing = svc.handle_request("/demo.v1.Demo/Nope", GRPC_CONTENT_TYPE_PROTO, Span(grpc_request))
assert_equal(missing.grpc_status, GRPC_STATUS_NOT_FOUND)
var wrong_type = svc.handle_request("/demo.v1.Demo/Echo", "text/plain", Span(json))
assert_equal(wrong_type.grpc_status, GRPC_STATUS_UNIMPLEMENTED)
assert_false(wrong_type.is_ok())
```

Status names and deadlines:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_connect import DEADLINE_UNSET_MICROS, GRPC_STATUS_NOT_FOUND
from komira_connect import GRPC_STATUS_UNAVAILABLE, connect_name_to_grpc_status
from komira_connect import grpc_status_to_connect_name, grpc_status_to_http_status
from komira_connect import parse_connect_timeout_ms, parse_grpc_timeout

assert_equal(grpc_status_to_connect_name(GRPC_STATUS_NOT_FOUND), "not_found")
assert_equal(connect_name_to_grpc_status("unavailable"), GRPC_STATUS_UNAVAILABLE)
assert_equal(grpc_status_to_http_status(GRPC_STATUS_UNAVAILABLE), 503)

assert_equal(parse_grpc_timeout("1500m"), 1_500_000)  # microseconds
assert_equal(parse_grpc_timeout("2S"), 2_000_000)
assert_equal(parse_grpc_timeout("soon"), DEADLINE_UNSET_MICROS)  # malformed
assert_equal(parse_connect_timeout_ms("250"), 250_000)
```
