# =============================================================================
# tests/test_route_pack.mojo — the AppRouter[*Routes] gate.
# =============================================================================
#
# The unit for the Mojo-native route-registration API (routing/route.mojo). It
# proves the two load-bearing invariants the pack design rests on:
#
#   * CTOR reads the comptime METHOD / PATTERN off the TYPE pack element
#     (`Self.Routes[i].METHOD` / `.PATTERN`) — reading them off a runtime tuple
#     VALUE gives `can't access 'PATTERN' in non-parameter`. Proven indirectly:
#     if the ctor mis-registered the table, no route would match.
#   * MOVE-ONCE across the `comptime for` unroll via an `Optional`-stash +
#     `.take()` (a bare `req^` inside the unrolled loop gives
#     `use of uninitialized value 'req'`). Proven by dispatching each of THREE
#     distinct routes and getting each route's distinct response back.
#
# Coverage (the four gate assertions from the brief):
#   1. A 3-route pack dispatches each route to the correct handler.
#   2. The ctor read METHOD/PATTERN off Self.Routes[i] correctly (routes match).
#   3. Unknown path -> 404; known path + WRONG verb -> 405 (via has_path_match).
#   4. A `:param` route fills `req.path_params`.
#
# It drives `AppRouter.dispatch[RT]` directly (the transport leaf the socket
# serve path calls per request) so the seam is exercised without standing up a
# real listener — identical to what `serve_read_round_dispatch` invokes.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime

from komira_uuid.uuid import Uuid

from komira_http_core.codec.types import (
    HttpMethod,
    HttpRequest,
    HttpResponse,
)
from komira_http_server.routing.route import (
    Route,
    RouteBlock,
    AppRouter,
)


comptime _Rt = BlockingRuntime[NoopSink]


def _rt() raises -> _Rt:
    return _Rt.new(NoopSink(_placeholder=UInt8(0)))


def _body_str(ref resp: HttpResponse) -> String:
    """Decode a response body back to a String for assertion."""
    var s = String("")
    var i = 0
    var n = len(resp.body)
    while i < n:
        s = s + chr(Int(resp.body[i]))
        i = i + 1
    return s^


def _req(var method: HttpMethod, var path: String) -> HttpRequest:
    var r = HttpRequest()
    r.method = method
    r.path = path^
    return r^


# =============================================================================
# §1 — three distinct routes (each returns a distinct, identifiable response).
# =============================================================================
# Each route returns a body naming itself, so a mis-routed dispatch is
# observable (route A's request must NOT return route B's body). This is the
# direct falsifier of the move-once-across-unroll invariant AND the
# ctor-reads-off-type-pack invariant.


struct HealthzRoute(Movable, Deinitable, Route):
    """GET /healthz -> 200 "healthz-ok"."""

    comptime METHOD = HttpMethod.get()
    comptime PATTERN = "/healthz"

    def __init__(out self):
        pass

    def handle[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        _ = reactor
        _ = req^
        return HttpResponse.ok(String("healthz-ok"))


struct EchoGetRoute(Movable, Deinitable, Route):
    """GET /echo -> 200 "echo-get"."""

    comptime METHOD = HttpMethod.get()
    comptime PATTERN = "/echo"

    def __init__(out self):
        pass

    def handle[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        _ = reactor
        _ = req^
        return HttpResponse.ok(String("echo-get"))


struct UserRoute(Movable, Deinitable, Route):
    """GET /users/:id -> 200 "user-<id>" (proves :param capture into
    req.path_params + that the matched route reads the capture)."""

    comptime METHOD = HttpMethod.get()
    comptime PATTERN = "/users/:id"

    def __init__(out self):
        pass

    def handle[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        _ = reactor
        # The match filled req.path_params["id"] BEFORE handle ran.
        var got = req.path_params.find(String("id"))
        var id_val = String("MISSING")
        if got:
            id_val = got.value()
        _ = req^
        return HttpResponse.ok(String("user-") + id_val)


comptime _HelloWorldRouter = AppRouter[HealthzRoute, EchoGetRoute, UserRoute]


def _make_router() raises -> _HelloWorldRouter:
    return _HelloWorldRouter(
        RouteBlock[HealthzRoute, EchoGetRoute, UserRoute](
            HealthzRoute(), EchoGetRoute(), UserRoute()
        )
    )


# =============================================================================
# 1 + 2. Each of the three routes dispatches to its OWN handler (proves the
#        move-once-across-unroll AND that the ctor registered each route off
#        Self.Routes[i].METHOD / .PATTERN correctly).
# =============================================================================
def test_three_route_pack_dispatches_each_route() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var router = _make_router()

    assert_equal(router.route_count(), 3, "pack has three routes")

    # GET /healthz -> route 0.
    var r0 = router.dispatch[_Rt](
        reactor, _req(HttpMethod.get(), String("/healthz"))
    )
    assert_equal(Int(r0.status), 200, "GET /healthz -> 200")
    assert_equal(_body_str(r0), String("healthz-ok"), "healthz body")

    # GET /echo -> route 1 (NOT route 0's body — the move-once falsifier).
    var r1 = router.dispatch[_Rt](
        reactor, _req(HttpMethod.get(), String("/echo"))
    )
    assert_equal(Int(r1.status), 200, "GET /echo -> 200")
    assert_equal(_body_str(r1), String("echo-get"), "echo body")

    # GET /users/42 -> route 2 (a DIFFERENT arm of the unroll again).
    var r2 = router.dispatch[_Rt](
        reactor, _req(HttpMethod.get(), String("/users/42"))
    )
    assert_equal(Int(r2.status), 200, "GET /users/42 -> 200")
    assert_equal(_body_str(r2), String("user-42"), "user body carries :id")

    _ = router^


# =============================================================================
# 3. Unknown path -> 404; known path + WRONG verb -> 405 (via has_path_match).
# =============================================================================
def test_404_unknown_path() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var router = _make_router()

    var r = router.dispatch[_Rt](
        reactor, _req(HttpMethod.get(), String("/nope"))
    )
    assert_equal(Int(r.status), 404, "unknown path -> 404")

    _ = router^


def test_405_wrong_verb_known_path() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var router = _make_router()

    # POST /healthz — the PATH is known (a GET route exists) but the VERB is
    # wrong. The pack gets 405 for free via has_path_match (NOT 404).
    var r = router.dispatch[_Rt](
        reactor, _req(HttpMethod.post(), String("/healthz"))
    )
    assert_equal(
        Int(r.status), 405, "known path + wrong verb -> 405 (not 404)"
    )

    # PUT /users/42 — the :param path is known, PUT is not registered -> 405.
    var r2 = router.dispatch[_Rt](
        reactor, _req(HttpMethod.put(), String("/users/42"))
    )
    assert_equal(Int(r2.status), 405, "known :param path + wrong verb -> 405")
    # The 405 names the path's methods (RFC 9110 §15.5.6).
    assert_equal(r.headers[String("allow")], String("GET"))
    assert_equal(r2.headers[String("allow")], String("GET"))

    _ = router^


# =============================================================================
# 4. A `:param` route fills req.path_params (asserted via the handler reading
#    the capture back into the response body).
# =============================================================================
def test_param_route_fills_path_params() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var router = _make_router()

    # /users/alice — the handler reads req.path_params["id"] == "alice" and
    # echoes it. If the match did NOT fill path_params, the body would be
    # "user-MISSING".
    var r = router.dispatch[_Rt](
        reactor, _req(HttpMethod.get(), String("/users/alice"))
    )
    assert_equal(Int(r.status), 200, "GET /users/alice -> 200")
    assert_equal(
        _body_str(r),
        String("user-alice"),
        "the :id capture landed in req.path_params before handle ran",
    )

    _ = router^


def main() raises:
    test_three_route_pack_dispatches_each_route()
    test_404_unknown_path()
    test_405_wrong_verb_known_path()
    test_param_route_fills_path_params()
    print("PASS test_route_pack")
