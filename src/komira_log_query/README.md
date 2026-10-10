# komira_log_query

The read side of a log a service writes to an object store: a seam a
storage-specific reader conforms to, and an HTTP route a service mounts to
answer log queries over that seam.

- `ServiceLogQuery` is one read: an inclusive time window (`t0_ns`, `t1_ns`),
  an optional term (empty means everything in the window) and a page bound.
  `ServiceLogHit` is a timestamp, a score and the record's JSON object;
  `ServiceLogPage` carries the hits plus `total_matches` and
  `sources_scanned`, so a truncated page and an empty index are told apart.
- `ServiceLogSearch` is the trait a reader implements (`scan(query) ->
  page`); `ErasedServiceLogSearch.erase(reader)` wraps any conformer in one
  non-generic type a service can hold as a field.
- `LogReadAccess` decides who may read. `DenyLogReads` refuses everything;
  `HeaderTokenAccess(header, token)` allows a request whose header carries
  exactly the token (compared without an early exit), and refuses everything
  while either is empty. No allow-everything hook ships.
- `is_service_log_request(req, path)` matches `GET <path>` exactly.
  `service_log_response(reader, req, access, now_ns)` never raises: a refused
  caller, a raising hook and an unwired reader (`None`) all get the same
  `404 {"error":"not found"}`. Only an allowed caller sees argument errors
  (`400` for an inverted or out-of-range window), and a reader that raises
  becomes a `500` (or a `400` carrying the reader's message when the query had
  no term). The query string takes `q`, `since_ms`, `until_ms` (default: the
  30 days before `now_ns`) and `limit` (default 50, clamped to 500). A hit's
  record is embedded as JSON only when it is a well-formed object, and is
  quoted as a string otherwise.

The package ships no reader, reads no environment and no clock: the service
supplies the mount path, the access hook, the reader and the current time.

## Examples

Mount the route over an in-memory reader, query it with the right token, and
see a caller without the token get the same 404 as an unwired route:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo module
from komira_http_core.codec.types import HttpMethod, HttpRequest
from komira_log_query import ErasedServiceLogSearch, HeaderTokenAccess, ServiceLogHit, ServiceLogPage, ServiceLogQuery, ServiceLogSearch, is_service_log_request, service_log_response


struct TwoLines(ServiceLogSearch, Movable, Deinitable):
    """A reader over two fixed records; it honours the term, not the window."""

    def __init__(out self):
        pass

    def scan(mut self, q: ServiceLogQuery) raises -> ServiceLogPage:
        var hits = List[ServiceLogHit]()
        if not q.has_term() or q.term == "started":
            hits.append(ServiceLogHit(Int64(1_000), 1.0, '{"msg":"started"}'))
        if not q.has_term() or q.term == "stopped":
            hits.append(ServiceLogHit(Int64(2_000), 1.0, '{"msg":"stopped"}'))
        return ServiceLogPage(hits^, len(hits), 2)


def log_request(query: String, token: String) -> HttpRequest:
    var r = HttpRequest(HttpMethod.get(), "/logs")
    r.query_string = query
    if token.byte_length() > 0:
        r.headers["x-log-token"] = token
    return r^


def main() raises:
    var reader = Optional(ErasedServiceLogSearch.erase(TwoLines()))
    var access = HeaderTokenAccess("x-log-token", "reader-token")
    var now_ns = Int64(5_000_000_000_000_000)  # the service passes its clock in

    var req = log_request("q=stopped&limit=10", "reader-token")
    assert_true(is_service_log_request(req, "/logs"))
    var ok = service_log_response(reader, req, access, now_ns)
    assert_equal(ok.status, Int32(200))
    var body = String(unsafe_from_utf8=ok.body.copy())
    assert_true(body.find('"q":"stopped"') >= 0)
    assert_true(body.find('"limit":10') >= 0)
    assert_true(body.find('"returned":1') >= 0)
    assert_true(body.find('"source":{"msg":"stopped"}') >= 0)

    var refused = service_log_response(reader, log_request("", "wrong"), access, now_ns)
    var unwired = Optional[ErasedServiceLogSearch](None)
    var no_reader = service_log_response(unwired, log_request("", "reader-token"), access, now_ns)
    assert_equal(refused.status, Int32(404))
    assert_equal(no_reader.status, Int32(404))
    assert_equal(
        String(unsafe_from_utf8=refused.body.copy()),
        String(unsafe_from_utf8=no_reader.body.copy()),
    )
    assert_false(is_service_log_request(HttpRequest(HttpMethod.get(), "/logs/x"), "/logs"))
```

An allowed caller asking for an inverted window is told so, and the window
is never swapped:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo module
from komira_http_core.codec.types import HttpMethod, HttpRequest
from komira_log_query import ErasedServiceLogSearch, HeaderTokenAccess, ServiceLogPage, ServiceLogQuery, ServiceLogSearch, service_log_response


struct EmptyLog(ServiceLogSearch, Movable, Deinitable):
    def __init__(out self):
        pass

    def scan(mut self, q: ServiceLogQuery) raises -> ServiceLogPage:
        return ServiceLogPage()


def main() raises:
    var reader = Optional(ErasedServiceLogSearch.erase(EmptyLog()))
    var req = HttpRequest(HttpMethod.get(), "/logs")
    req.query_string = "since_ms=2000&until_ms=1000"
    req.headers["x-log-token"] = "reader-token"
    var r = service_log_response(
        reader, req, HeaderTokenAccess("x-log-token", "reader-token"), Int64(0)
    )
    assert_equal(r.status, Int32(400))
    assert_true(String(unsafe_from_utf8=r.body.copy()).find("is after 'until_ms'") >= 0)
```
