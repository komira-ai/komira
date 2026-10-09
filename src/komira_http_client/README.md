# komira_http_client

An HTTP/1.1 and HTTP/2 client on `komira_async`'s reactor. `HttpClient`
sends a `ClientRequest` over plain TCP or TLS (`TlsConnector`, s2n-tls, ALPN
picks h2 or http/1.1), with connection pools per host (`PoolKey`,
`H2ClientPool`), TLS session resumption, response size and header limits,
and a deadline on every phase. What it offers:

- requests: `Url.parse`, `HeaderMap` (case-insensitive, ordered, repeatable
  names), `build_get_request` / `build_request_with_body` /
  `build_streaming_request`, request bodies (`BytesBody`, `EmptyBody`,
  `StreamingBody`);
- responses: `parse_response_head` with `ResponseParseLimits`, buffered and
  streamed bodies (`collect_body`, `BodyFrame`), trailers;
- composable layers on `HttpService`: `RetryLayer` (only idempotent methods
  unless the caller opts in), `RedirectLayer`, `TimeoutLayer`, bearer-token
  auth (`AuthProvider`);
- typed failures (`HttpError`, the `HTTP_ERROR_*` kinds), and an outbound
  time budget (`outbound_budget_us`);
- `TlsConnector.upgrade`: STARTTLS, a TLS client handshake over an
  already-connected plaintext stream; it refuses a stream that still holds
  bytes the peer sent before the handshake;
- `ObjectStoreHttp`: ranged GETs over an object store's HTTP API, with a
  scripted double for tests;
- `Clock` / `Rng` seams (`MockClock`, `DeterministicRng`) so retry timing is
  testable.

Host names are resolved by `komira_net`. It has no cookie jar, no HTTP/3
and no proxy (`CONNECT`) support.

## Examples

Parse a URL and write the request head the client sends. `Host`,
`User-Agent` and `Content-Length` are added unless the caller set them, and
header names go out lowercase:

<!-- mojo-hidden from std.testing import assert_equal, assert_raises, assert_true -->
```mojo
from komira_http_client import HeaderMap, Url, method_get, serialize_request_head

var url = Url.parse("https://api.example.com:8443/v1/items?limit=10")
assert_true(url.is_https())
assert_equal(url.host, "api.example.com")
assert_equal(Int(url.effective_port()), 8443)
assert_equal(url.request_target(), "/v1/items?limit=10")
assert_equal(Url.parse("http://example.com/").authority(), "example.com")

var headers = HeaderMap()
headers.append("Accept", "application/json")
assert_equal(headers.get("accept").value(), "application/json")  # any case

var head = List[UInt8]()
serialize_request_head(method_get(), url, headers, 0, head)
var text = String()
for i in range(len(head)):
    text += chr(Int(head[i]))
assert_equal(
    text,
    "GET /v1/items?limit=10 HTTP/1.1\r\n"
    + "Host: api.example.com:8443\r\n"
    + "User-Agent: komira-http/1.0\r\n"
    + "Content-Length: 0\r\n"
    + "accept: application/json\r\n\r\n",
)

with assert_raises():
    _ = Url.parse("not a url")
```

Parse a response head as it arrives, and the retry rule for methods:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_http_client import ResponseParseLimits, parse_response_head
from komira_http_client import is_idempotent_method, method_get, method_post, method_put

def wire(text: String) -> List[UInt8]:
    var bytes = text.as_bytes()
    var out = List[UInt8]()
    for i in range(len(bytes)):
        out.append(bytes[i])
    return out^

var partial = wire("HTTP/1.1 200 OK\r\nContent-Ty")
assert_true(parse_response_head(Span(partial), ResponseParseLimits.defaults()).is_need_more())

var full = wire("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 9\r\n\r\nnot found")
var response = parse_response_head(Span(full), ResponseParseLimits.defaults())
assert_true(response.is_ok())
assert_equal(Int(response.status), 404)
assert_equal(response.reason, "Not Found")
assert_equal(response.content_length, 9)
assert_false(response.is_chunked)
assert_equal(response.headers.get("content-type").value(), "text/plain")
assert_equal(len(full) - response.headers_end_off, 9)  # the body

assert_true(is_idempotent_method(method_get()))
assert_true(is_idempotent_method(method_put()))
assert_false(is_idempotent_method(method_post()))
```
