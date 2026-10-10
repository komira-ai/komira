# komira_grpc

The client side of gRPC and Connect-RPC. `GrpcClient` sends unary,
server-streaming, client-streaming and bidirectional calls over
`komira_http_client`; the wire protocol is a compile-time parameter:

- `ProtocolGrpcProto`: classic gRPC over HTTP/2 (`application/grpc`, every
  message in a 5-byte envelope, the status in trailers);
- `ProtocolConnectProto` and `ProtocolConnectJson`: Connect
  (`application/proto`, `application/json`; a unary body is the bare message
  and an error is a JSON envelope).

Around the calls it provides: request headers (`build_unary_request_headers`,
with `grpc-timeout` from a `CallOptions` deadline and the caller's
`RpcMetadata`), body framing (`encode_unary_request`,
`decode_unary_response`, stream encoders and decoders), status handling (a
failed call raises an error whose text starts `[grpc:<code>]`;
`parse_grpc_status_code` reads it back, `grpc_error_from_http_non_200` maps
a proxy's HTTP error to a gRPC code), retry (`RetryPolicy.none()`,
`idempotent()` which makes up to 5 attempts in total (4 retries) on
`UNAVAILABLE` with a 1 s, x1.3, 10 s capped backoff, and `is_retryable_grpc_error`), and the
`x-goog-request-params` routing header (`match_path_template`,
`build_routing_params`). The 17 `GRPC_STATUS_*` codes are re-exported from
`komira_connect`, which is also where the server side lives.

Messages are opaque bytes: serializing them is the generated stub's job, and
this package has no protobuf codec. Compression is not supported.

## Examples

The same message framed for each protocol, and a response decoded or turned
into a status error:

<!-- mojo-hidden from std.testing import assert_equal, assert_raises -->
```mojo
from komira_grpc import ProtocolConnectJson, ProtocolGrpcProto
from komira_grpc import GRPC_STATUS_UNAVAILABLE, decode_unary_response
from komira_grpc import encode_unary_request, parse_grpc_status_code

var message: List[UInt8] = [0x08, 0x2A]  # protobuf: field 1 = 42

var grpc_body = encode_unary_request[ProtocolGrpcProto](Span(message))
assert_equal(len(grpc_body), 7)  # flags, 4-byte big-endian length, message
assert_equal(grpc_body[0], 0)
assert_equal(grpc_body[4], 2)
assert_equal(len(encode_unary_request[ProtocolConnectJson](Span(message))), 2)  # bare

var payload = decode_unary_response[ProtocolGrpcProto](Span(grpc_body), 200)
assert_equal(len(payload), 2)
assert_equal(payload[1], 0x2A)

# A classic gRPC response is always HTTP 200; a 503 came from a proxy.
try:
    _ = decode_unary_response[ProtocolGrpcProto](Span(grpc_body), 503)
    raise Error("expected a status error")
except e:
    assert_equal(parse_grpc_status_code(String(e)), Int(GRPC_STATUS_UNAVAILABLE))
```

Request headers, retry decisions and routing parameters:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_grpc import CallOptions, ProtocolConnectProto, ProtocolGrpcProto
from komira_grpc import GRPC_HEADER_CONNECT_PROTOCOL_VERSION, GRPC_HEADER_CONTENT_TYPE
from komira_grpc import GRPC_HEADER_GRPC_TIMEOUT, build_unary_request_headers
from komira_grpc import GRPC_STATUS_NOT_FOUND, GRPC_STATUS_UNAVAILABLE
from komira_grpc import RetryPolicy, backoff_cap_ms, format_grpc_error_message
from komira_grpc import is_retryable_grpc_error
from komira_grpc import build_routing_params, match_path_template

var opts = CallOptions.new()
opts.with_deadline_micros(5_000_000)
opts.metadata.set("request-id", "abc")
var grpc_headers = build_unary_request_headers[ProtocolGrpcProto](opts, now_us=0)
assert_equal(grpc_headers.get(GRPC_HEADER_CONTENT_TYPE).value(), "application/grpc")
assert_equal(grpc_headers.get(GRPC_HEADER_GRPC_TIMEOUT).value(), "5S")
assert_equal(grpc_headers.get("request-id").value(), "abc")
assert_false(grpc_headers.get(GRPC_HEADER_CONNECT_PROTOCOL_VERSION).__bool__())

var connect_headers = build_unary_request_headers[ProtocolConnectProto](CallOptions.new(), now_us=0)
assert_equal(connect_headers.get(GRPC_HEADER_CONTENT_TYPE).value(), "application/proto")
assert_equal(connect_headers.get(GRPC_HEADER_CONNECT_PROTOCOL_VERSION).value(), "1")

var policy = RetryPolicy.idempotent()
var unavailable = format_grpc_error_message(GRPC_STATUS_UNAVAILABLE, "try again")
assert_equal(unavailable, "[grpc:14] try again")
assert_true(is_retryable_grpc_error(unavailable, policy))
assert_false(is_retryable_grpc_error(format_grpc_error_message(GRPC_STATUS_NOT_FOUND, "gone"), policy))
assert_false(is_retryable_grpc_error(unavailable, RetryPolicy.none()))
assert_equal(backoff_cap_ms(1, policy), 1000)
assert_equal(backoff_cap_ms(2, policy), 1300)
assert_equal(backoff_cap_ms(50, policy), 10_000)  # capped

var location = match_path_template(
    "projects/p1/locations/us-south1/services/svc-a", "projects/*/locations/{location=*}/**"
)
assert_equal(location.value(), "us-south1")
assert_false(match_path_template("organizations/1", "projects/*/locations/{location=*}").__bool__())
var pairs = List[Tuple[StaticString, String]]()
pairs.append((StaticString("parent"), String("projects/p1")))
pairs.append((StaticString("location"), location.value()))
assert_equal(build_routing_params(pairs), "parent=projects%2Fp1&location=us-south1")
```
