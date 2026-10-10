# komira_http_server

An HTTP server on `komira_async`'s reactor, over `komira_http_core`'s codecs:
HTTP/1.1 (keep-alive, pipelining, chunked request bodies, `100-continue`),
HTTP/2 and TLS. The pieces:

- `HttpServer` with `HttpServerConfig`: binds, accepts and drives
  connections, handing each parsed `HttpRequest` to a dispatcher (the
  `RequestDispatcher` trait, or one of its context-carrying, suspendable or
  type-erased variants) and writing its `HttpResponse`.
- `komira_http_server.routing`: `Router` maps a method and a path pattern
  (`/users/:id` binds `id`; a trailing `/*` matches any suffix) to a handler
  id, tells a wrong method (405, with the path's methods for its `Allow`
  header) from an unknown path (404), and refuses a duplicate or malformed
  pattern when the route is added. `ComposedRoutes[*Services]` serves several
  `RoutedDispatcher`s (a dispatcher that can say which routes it has, such as
  a generated `<Service>Routes`) from one server: the first with a route for
  the request dispatches it, else 405 when any has the path, else 404.
- `komira_http_server.middleware`: the `Middleware` trait (`before` may answer
  early, `after` sees every response), a `MiddlewareChain`, and built-ins for
  CORS, error mapping, request logging, tracing headers and metrics, plus
  fault reporting with an incident id. `Principal` carries who a request
  was authenticated as: its scheme (`jwt` or `session`; the constructor
  refuses any other), a subject, a `Claims` map the library never
  interprets, and optionally the `PresentedCredential`, which is not
  printable (`redacted()` to log, `expose()` to forward).
- `komira_http_server.serving`: `ServerlessEntry`, the trait for a serving
  driver that runs one router on a platform's runtime (one conformer today,
  `GcpServerlessEntry`, for Google Cloud Run), and `parse_serve_port`.

It does not authenticate requests, serve static files or compress
responses.

## Examples

Routing, with path parameters, a wildcard, and the 404 / 405 distinction:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_raises, assert_true -->
```mojo
from std.collections.dict import Dict
from komira_http_core.codec import HttpMethod
from komira_http_server.routing import Router

comptime GET_ORDER = 1
comptime CREATE_ORDER = 2
comptime STATIC = 3

var router = Router()
router.add(HttpMethod.get(), "/orders/:id", GET_ORDER)
router.add(HttpMethod.post(), "/orders", CREATE_ORDER)
router.add(HttpMethod.get(), "/static/*", STATIC)
assert_equal(router.len(), 3)

var params = Dict[String, String]()
var hit = router.match_route(HttpMethod.get(), "/orders/42", params)
assert_equal(hit.value(), GET_ORDER)
assert_equal(params["id"], "42")
assert_equal(router.match_route(HttpMethod.get(), "/static/css/site.css", params).value(), STATIC)

# DELETE /orders/42: the path exists, the method does not -> 405, not 404.
assert_false(router.match_route(HttpMethod.delete(), "/orders/42", params).__bool__())
assert_true(router.has_path_match("/orders/42"))
assert_false(router.has_path_match("/invoices/1"))  # -> 404
assert_equal(len(router.allowed_methods("/orders/42")), 1)  # Allow: GET

with assert_raises():
    router.add(HttpMethod.get(), "/orders/:id", 9)  # already registered
```

The CORS middleware answers a preflight itself and decorates ordinary
responses:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
from komira_http_server.middleware import CorsMiddleware, RequestContext

var cors = CorsMiddleware.permissive()
var ctx = RequestContext.new()

var preflight = HttpRequest(HttpMethod.options(), "/api/items")
preflight.headers["origin"] = "https://app.example.com"
preflight.headers["access-control-request-method"] = "POST"
var early = cors.before(preflight, ctx)
assert_true(Bool(early))
assert_equal(Int(early.value().status), 204)
assert_equal(early.value().headers["access-control-allow-origin"], "*")

var get = HttpRequest(HttpMethod.get(), "/api/items")
get.headers["origin"] = "https://app.example.com"
assert_false(Bool(cors.before(get, ctx)))  # not a preflight: the handler runs
var response = HttpResponse(status=Int32(200))
cors.after(get, response, ctx)
assert_equal(response.headers["access-control-allow-origin"], "*")
```

The listen port from a port flag's value:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_http_server.serving import DEFAULT_SERVE_PORT, parse_serve_port

assert_equal(parse_serve_port("9090"), 9090)
assert_equal(parse_serve_port("0"), 0)  # the kernel picks a port
assert_equal(parse_serve_port(""), DEFAULT_SERVE_PORT)
assert_equal(parse_serve_port("70000"), DEFAULT_SERVE_PORT)  # out of range
assert_equal(DEFAULT_SERVE_PORT, 8080)
```
