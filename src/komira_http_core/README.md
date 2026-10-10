# komira_http_core

The part of the HTTP stack that a client and a server share, used by
`komira_http_client` and `komira_http_server` (which do not depend on each
other). The package root exports nothing; import the submodules:

- `komira_http_core.codec`: HTTP/1.1 as pure functions over byte spans.
  `parse_request_head` parses a request line and header block under
  `ParseLimits` and reports need-more or a typed error with the status to
  answer (400, 413, 414, 417, 431, 501 or 505); `ChunkedDecoder` / `decode_block`
  decode a chunked body incrementally; `HttpRequest`, `HttpResponse` and
  `serialize_response` build the wire form.
- `komira_http_core.codec.h2`: HTTP/2 frames, HPACK (`HpackEncoder`,
  `HpackDecoder`, RFC 7541), stream and connection state, flow control, the
  connection preface and ALPN.
- `komira_http_core.tls`: TLS over s2n-tls (`TlsConfig`, `TlsConnection`,
  `TlsStream`), with certificate verification, SNI, ALPN and session
  resumption.
- `komira_http_core.transport`: the `IoStream` and `Connector` traits, plain
  TCP on `komira_async`'s reactor, a scripted in-memory stream for tests,
  stream parking, and gRPC trailer and `grpc-timeout` handling.

It is not a client or a server: connection pools, routing, redirects and
retries are in the packages above it.

## Examples

Parse an HTTP/1.1 request head; header names come back lowercase and the
body starts at `headers_end_off`:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_http_core.codec import HTTP_METHOD_POST, PARSE_ERR_METHOD_LOWERCASE
from komira_http_core.codec import ParseLimits, parse_request_head

def wire(text: String) -> List[UInt8]:
    var bytes = text.as_bytes()
    var out = List[UInt8]()
    for i in range(len(bytes)):
        out.append(bytes[i])
    return out^

var request = wire("POST /orders?id=7 HTTP/1.1\r\nHost: example.com\r\nContent-Length: 2\r\n\r\n{}")
var head = parse_request_head(Span(request), ParseLimits.defaults())
assert_true(head.err.is_ok())
assert_equal(Int(head.request.method.code), Int(HTTP_METHOD_POST))
assert_equal(head.request.path, "/orders")
assert_equal(head.request.query_string, "id=7")
assert_equal(head.request.headers["host"], "example.com")
assert_equal(head.content_length, 2)
assert_equal(len(request) - head.headers_end_off, 2)  # the body
assert_false(head.connection_close)

var partial = wire("GET / HTTP/1.1\r\nHost: exa")
assert_true(parse_request_head(Span(partial), ParseLimits.defaults()).err.is_need_more())

var bad = wire("get / HTTP/1.1\r\n\r\n")
var refused = parse_request_head(Span(bad), ParseLimits.defaults())
assert_equal(Int(refused.err.kind), Int(PARSE_ERR_METHOD_LOWERCASE))
assert_equal(Int(refused.err.status), 501)
```

A chunked body, decoded:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_http_core.codec import CHUNKED_RES_DONE, ChunkedDecoder, ParseLimits, decode_block

var text = "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".as_bytes()
var chunked = List[UInt8]()
for i in range(len(text)):
    chunked.append(text[i])
var decoder = ChunkedDecoder.init()
var body = List[UInt8]()
var result = decode_block(decoder, Span(chunked), ParseLimits.defaults(), body)
assert_equal(Int(result.outcome), Int(CHUNKED_RES_DONE))
assert_equal(len(body), 11)  # "hello world"
assert_equal(body[5], UInt8(ord(" ")))
```

HPACK: a header block encoded and decoded again, and the one-byte static
table entry for `:method: GET`:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_http_core.codec.h2 import HpackDecoder, HpackEncoder, HpackHeader

var encoder = HpackEncoder(max_table_size=4096)
var decoder = HpackDecoder(max_table_size=4096)
var headers = List[HpackHeader]()
headers.append(HpackHeader(":method", "POST"))
headers.append(HpackHeader(":path", "/api"))
headers.append(HpackHeader("content-type", "application/json"))
var block = encoder.encode_block(headers^)
var decoded = decoder.decode_block(Span(block))
assert_equal(len(decoded), 3)
assert_equal(decoded[1].name, ":path")
assert_equal(decoded[2].value, "application/json")

var indexed: List[UInt8] = [0x82]
var fresh = HpackDecoder()
var get = fresh.decode_block(Span(indexed))
assert_equal(get[0].name, ":method")
assert_equal(get[0].value, "GET")
```
