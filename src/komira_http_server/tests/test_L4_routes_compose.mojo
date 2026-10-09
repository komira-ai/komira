# ComposedRoutes: several RoutedDispatchers behind one server. Each service
# here is a Router plus a name; its dispatch answers 200 with "<name> <id>"
# for a matched route (or 404 for the route whose handler says "not found").
# Each test names the defect it catches.

from std.collections.dict import Dict
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime

from komira_http_core.codec.types import HttpMethod, HttpRequest, HttpResponse
from komira_http_server.routing import ComposedRoutes, RoutedDispatcher, Router


comptime _Rt = BlockingRuntime[NoopSink]

# A route id whose handler answers 404 itself (a record that does not exist).
comptime _HANDLER_404 = 99


def _rt() raises -> _Rt:
    return _Rt.new(NoopSink(_placeholder=UInt8(0)))


struct _Svc(RoutedDispatcher):
    var name: String
    var router: Router
    var calls: Int

    def __init__(out self, var name: String, var router: Router):
        self.name = name^
        self.router = router^
        self.calls = 0

    def has_route(self, method: HttpMethod, path: String) -> Bool:
        var params = Dict[String, String]()
        return Bool(self.router.match_route(method, path, params))

    def allowed_methods(self, path: String, mut methods: List[HttpMethod]):
        methods.extend(self.router.allowed_methods(path))

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        _ = reactor
        self.calls += 1
        var params = Dict[String, String]()
        var hit = self.router.match_route(req.method, req.path, params)
        if not hit:
            return HttpResponse.not_found()
        if hit.value() == _HANDLER_404:
            return HttpResponse.not_found()
        return HttpResponse.ok(self.name + String(" ") + String(hit.value()))


def _a() raises -> _Svc:
    var r = Router()
    r.add(HttpMethod.get(), "/a/items", 0)
    r.add(HttpMethod.post(), "/a/items", 1)
    r.add(HttpMethod.get(), "/shared/:id", 2)
    r.add(HttpMethod.get(), "/a/missing", _HANDLER_404)
    return _Svc(String("A"), r^)


def _b() raises -> _Svc:
    var r = Router()
    r.add(HttpMethod.get(), "/b/things/:id", 0)
    r.add(HttpMethod.delete(), "/shared/:id", 1)
    r.add(HttpMethod.get(), "/a/missing", 2)
    r.add(HttpMethod.put(), "/b/things/:id", 3)
    return _Svc(String("B"), r^)


def _req(method: HttpMethod, var path: String) -> HttpRequest:
    var r = HttpRequest()
    r.method = method
    r.path = path^
    return r^


def _body(resp: HttpResponse) -> String:
    var s = String("")
    for i in range(len(resp.body)):
        s = s + chr(Int(resp.body[i]))
    return s^


def test_the_last_services_last_route_is_reached() raises:
    """Catches a composite that asks only its first service."""
    var rt = _rt()
    ref reactor = rt.reactor()
    var app = ComposedRoutes[_Svc, _Svc](_a(), _b())
    var r = app.dispatch[_Rt](reactor, _req(HttpMethod.put(), String("/b/things/7")))
    assert_equal(Int(r.status), 200)
    assert_equal(_body(r), String("B 3"))
    var first = app.dispatch[_Rt](reactor, _req(HttpMethod.post(), String("/a/items")))
    assert_equal(_body(first), String("A 1"))


def test_a_path_another_service_knows_is_405() raises:
    """Catches a composite that answers 404 when the method is wrong but
    some service (here only the second) has the path; the 405 names the
    methods of every service for the path, sorted."""
    var rt = _rt()
    ref reactor = rt.reactor()
    var app = ComposedRoutes[_Svc, _Svc](_a(), _b())
    var r = app.dispatch[_Rt](reactor, _req(HttpMethod.post(), String("/b/things/7")))
    assert_equal(Int(r.status), 405)
    assert_equal(r.headers[String("allow")], String("GET, PUT"))
    # Both services have /shared/:id, under different methods.
    var both = app.dispatch[_Rt](reactor, _req(HttpMethod.put(), String("/shared/1")))
    assert_equal(Int(both.status), 405)
    assert_equal(both.headers[String("allow")], String("DELETE, GET"))
    # The first service with the method wins: GET /shared/1 is A's, DELETE B's.
    assert_equal(_body(app.dispatch[_Rt](reactor, _req(HttpMethod.get(), String("/shared/1")))), String("A 2"))
    assert_equal(_body(app.dispatch[_Rt](reactor, _req(HttpMethod.delete(), String("/shared/1")))), String("B 1"))


def test_an_unknown_path_is_404_and_dispatches_nothing() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var app = ComposedRoutes[_Svc, _Svc](_a(), _b())
    var r = app.dispatch[_Rt](reactor, _req(HttpMethod.get(), String("/c")))
    assert_equal(Int(r.status), 404)
    assert_false(String("allow") in r.headers)
    assert_equal(app.services[0].calls, 0)
    assert_equal(app.services[1].calls, 0)


def test_a_handlers_404_is_not_passed_on() raises:
    """Catches a composite that tries the next service on a 404 status: A's
    handler answers GET /a/missing with 404, and B (which also routes it) is
    never called."""
    var rt = _rt()
    ref reactor = rt.reactor()
    var app = ComposedRoutes[_Svc, _Svc](_a(), _b())
    var r = app.dispatch[_Rt](reactor, _req(HttpMethod.get(), String("/a/missing")))
    assert_equal(Int(r.status), 404)
    assert_equal(app.services[0].calls, 1)
    assert_equal(app.services[1].calls, 0)


def test_a_composite_nests() raises:
    """A composite is itself a RoutedDispatcher: its routes and methods are
    its services'."""
    var rt = _rt()
    ref reactor = rt.reactor()
    var inner = ComposedRoutes[_Svc, _Svc](_a(), _b())
    assert_true(inner.has_route(HttpMethod.delete(), "/shared/9"))
    assert_false(inner.has_route(HttpMethod.patch(), "/shared/9"))
    var app = ComposedRoutes[ComposedRoutes[_Svc, _Svc]](inner^)
    var r = app.dispatch[_Rt](reactor, _req(HttpMethod.get(), String("/b/things/1")))
    assert_equal(_body(r), String("B 0"))


def main() raises:
    test_the_last_services_last_route_is_reached()
    test_a_path_another_service_knows_is_405()
    test_an_unknown_path_is_404_and_dispatches_nothing()
    test_a_handlers_404_is_not_passed_on()
    test_a_composite_nests()
    print("PASS test_L4_routes_compose")
