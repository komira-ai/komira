# =============================================================================
# test_custom_middleware.mojo — an embedder's own middleware plugs in, composes,
# and sees the per-request context.
# =============================================================================
#
# The library ships no identity or authorization of its own: everything an
# embedder needs is the `Middleware` trait, `RequestContext` (`principal` +
# `attributes`) and `PairMiddleware` (nest it to compose more than two). This
# file pins what an embedder relies on:
#
#   1. COMPOSE IN ORDER   — `before` runs outer -> inner, then the dispatcher,
#                           then `after` runs inner -> outer.
#   2. SHORT-CIRCUIT      — a `before` that returns a response skips every inner
#                           `before`, the dispatcher, and the inner `after`s of
#                           the layers that never ran; the outer `after`s still
#                           run on the short-circuit response.
#   3. MUTATE THE CONTEXT — a `before` may set `ctx.principal`,
#                           `ctx.attributes` and request headers, and an inner
#                           layer and the dispatcher read them.
#   4. WRAP THE RESPONSE  — an `after` may rewrite the response the inner
#                           layers (or the dispatcher) produced.
#
# Driven through `_drive_chain_dispatch`, the transport leaf the socket serve
# path calls per request, so the composition is exercised exactly as served.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime

from komira_http_core.codec.types import HttpMethod, HttpRequest, HttpResponse
from komira_http_server.dispatch import (
    CtxRequestDispatcher,
    RequestDispatcher,
    _drive_chain_dispatch,
)
from komira_http_server.middleware import (
    Middleware,
    MiddlewareChain,
    Principal,
    RequestContext,
)
from komira_http_server.middleware.metrics import PairMiddleware

comptime _Rt = BlockingRuntime[NoopSink]


def _rt() raises -> _Rt:
    return _Rt.new(NoopSink(_placeholder=UInt8(0)))


def _text(ref resp: HttpResponse) -> String:
    var out = String("")
    for i in range(len(resp.body)):
        out += chr(Int(resp.body[i]))
    return out^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _make_req() -> HttpRequest:
    var req = HttpRequest()
    req.method = HttpMethod.get()
    req.path = String("/probe")
    return req^


def _attr(ref ctx: RequestContext, key: String) -> String:
    var v = ctx.attributes.get(key)
    if v:
        return v.value()
    return String("")


# =============================================================================
# _Probe — records its name in order on the way in and on the way out, and can
# deny. `before` appends `name` to the `order` attribute; `after` appends it to
# the `x-after` response header.
# =============================================================================
struct _Probe(Middleware, Movable, Deinitable):
    var _name: String
    var _deny: Bool

    def __init__(out self, name: String, deny: Bool = False):
        self._name = name
        self._deny = deny

    def before(
        mut self,
        mut req: HttpRequest,
        mut ctx: RequestContext,
    ) raises -> Optional[HttpResponse]:
        var order = _attr(ctx, String("order")) + self._name
        ctx.attributes.set(String("order"), order)
        if self._deny:
            var r = HttpResponse(status=Int32(403))
            r.headers[String("content-length")] = String("0")
            return Optional[HttpResponse](r^)
        return Optional[HttpResponse]()

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        var seen = String("")
        if String("x-after") in resp.headers:
            seen = resp.headers[String("x-after")]
        resp.headers[String("x-after")] = seen + self._name


# =============================================================================
# _Identify — sets the principal, a claim and an attribute, and tags the request.
# _Derive   — inner layer: reads what _Identify wrote and derives from it.
# =============================================================================
struct _Identify(Middleware, Movable, Deinitable):
    def __init__(out self):
        pass

    def before(
        mut self,
        mut req: HttpRequest,
        mut ctx: RequestContext,
    ) raises -> Optional[HttpResponse]:
        ctx.principal = Optional[Principal](
            Principal(scheme=String("jwt"), subject=String("svc-7")).with_claim(String("role"), String("reader"))
        )
        ctx.attributes.set(String("request-id"), String("r-42"))
        req.headers[String("x-injected")] = String("yes")
        return Optional[HttpResponse]()

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        pass


struct _Derive(Middleware, Movable, Deinitable):
    def __init__(out self):
        pass

    def before(
        mut self,
        mut req: HttpRequest,
        mut ctx: RequestContext,
    ) raises -> Optional[HttpResponse]:
        # Only reachable data: what the OUTER layer attached.
        if not ctx.principal:
            return Optional[HttpResponse](HttpResponse(status=Int32(401)))
        var who = ctx.principal.value().subject
        var role = ctx.principal.value().claims.get(String("role"))
        if role:
            who = who + String(":") + role.value()
        ctx.attributes.set(String("who"), who)
        return Optional[HttpResponse]()

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        pass


# =============================================================================
# _Wrap — an `after` that rewrites the body the inner layers produced.
# =============================================================================
struct _Wrap(Middleware, Movable, Deinitable):
    var _open: String
    var _close: String

    def __init__(out self, open: String, close: String):
        self._open = open
        self._close = close

    def before(
        mut self,
        mut req: HttpRequest,
        mut ctx: RequestContext,
    ) raises -> Optional[HttpResponse]:
        return Optional[HttpResponse]()

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        var wrapped = self._open + _text(resp) + self._close
        resp.body = _bytes(wrapped)
        resp.headers[String("content-length")] = String(len(resp.body))
        resp.headers[String("x-wrapped")] = String("1")


# =============================================================================
# _Dispatcher — reports what reached it, in the body.
# =============================================================================
struct _Dispatcher(Movable, RequestDispatcher, CtxRequestDispatcher):
    var reached: Bool

    def __init__(out self):
        self.reached = False

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        var anon = RequestContext.new()
        return self.dispatch_with_ctx[RT](reactor, req, anon)

    def dispatch_with_ctx[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        mut req: HttpRequest,
        ctx: RequestContext,
    ) raises -> HttpResponse:
        self.reached = True
        var body = (
            String("order=")
            + _attr(ctx, String("order"))
            + String(";who=")
            + _attr(ctx, String("who"))
            + String(";rid=")
            + _attr(ctx, String("request-id"))
        )
        if String("x-injected") in req.headers:
            body += String(";injected=") + req.headers[String("x-injected")]
        return HttpResponse.ok(body^)


def _header(ref resp: HttpResponse, key: String) raises -> String:
    if key in resp.headers:
        return resp.headers[key]
    return String("<absent>")


# =============================================================================
# 1. COMPOSE IN ORDER — before outer->inner, after inner->outer, three deep.
# =============================================================================
def test_compose_in_order() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    comptime Inner = PairMiddleware[_Probe, _Probe]
    comptime Outer = PairMiddleware[_Probe, Inner]
    var chain = MiddlewareChain.default()
    var mw = Outer(_Probe(String("a")), Inner(_Probe(String("b")), _Probe(String("c"))))
    var disp = _Dispatcher()

    var resp = _drive_chain_dispatch[_Dispatcher, Outer, _Rt](
        chain, mw, disp, reactor, _make_req()
    )

    assert_equal(Int(resp.status), 200)
    assert_true(disp.reached)
    assert_true(
        _text(resp).startswith(String("order=abc;")),
        "before must run outer -> inner (a, b, c): " + _text(resp),
    )
    assert_equal(
        _header(resp, String("x-after")),
        String("cba"),
        "after must run inner -> outer (c, b, a)",
    )
    _ = chain^
    _ = mw^
    _ = disp^


# =============================================================================
# 2. SHORT-CIRCUIT — the middle layer denies.
# =============================================================================
def test_short_circuit_skips_inner_and_dispatcher() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    comptime Inner = PairMiddleware[_Probe, _Probe]
    comptime Outer = PairMiddleware[_Probe, Inner]
    var chain = MiddlewareChain.default()
    var mw = Outer(
        _Probe(String("a")),
        Inner(_Probe(String("b"), deny=True), _Probe(String("c"))),
    )
    var disp = _Dispatcher()

    var resp = _drive_chain_dispatch[_Dispatcher, Outer, _Rt](
        chain, mw, disp, reactor, _make_req()
    )

    assert_equal(Int(resp.status), 403, "the deny response is the answer")
    assert_false(disp.reached, "the dispatcher must not run after a deny")
    assert_equal(
        _header(resp, String("x-after")),
        String("ba"),
        "c never ran its before, so c.after is skipped; b and a still wrap",
    )
    _ = chain^
    _ = mw^
    _ = disp^


def test_outermost_short_circuit_skips_every_inner_after() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    comptime Pair = PairMiddleware[_Probe, _Probe]
    var chain = MiddlewareChain.default()
    var mw = Pair(_Probe(String("a"), deny=True), _Probe(String("b")))
    var disp = _Dispatcher()

    var resp = _drive_chain_dispatch[_Dispatcher, Pair, _Rt](
        chain, mw, disp, reactor, _make_req()
    )

    assert_equal(Int(resp.status), 403)
    assert_false(disp.reached)
    assert_equal(_header(resp, String("x-after")), String("a"))
    _ = chain^
    _ = mw^
    _ = disp^


# =============================================================================
# 3. MUTATE THE CONTEXT — principal, claims, attributes and the request itself.
# =============================================================================
def test_context_and_request_mutation_reach_inner_layer_and_dispatcher() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    comptime Pair = PairMiddleware[_Identify, _Derive]
    var chain = MiddlewareChain.default()
    var mw = Pair(_Identify(), _Derive())
    var disp = _Dispatcher()

    var resp = _drive_chain_dispatch[_Dispatcher, Pair, _Rt](
        chain, mw, disp, reactor, _make_req()
    )

    assert_equal(Int(resp.status), 200)
    assert_equal(
        _text(resp),
        String("order=;who=svc-7:reader;rid=r-42;injected=yes"),
        "the inner layer read the outer layer's principal + claim, and the "
        "dispatcher read the attributes and the mutated request",
    )
    _ = chain^
    _ = mw^
    _ = disp^


def test_inner_layer_without_outer_identity_refuses() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    var chain = MiddlewareChain.default()
    var mw = _Derive()
    var disp = _Dispatcher()

    var resp = _drive_chain_dispatch[_Dispatcher, _Derive, _Rt](
        chain, mw, disp, reactor, _make_req()
    )

    assert_equal(Int(resp.status), 401)
    assert_false(disp.reached)
    _ = chain^
    _ = mw^
    _ = disp^


# =============================================================================
# 4. WRAP THE RESPONSE — and wrappers compose in reverse order.
# =============================================================================
def test_after_wraps_response_in_reverse_order() raises:
    var rt = _rt()
    ref reactor = rt.reactor()
    comptime Pair = PairMiddleware[_Wrap, _Wrap]
    var chain = MiddlewareChain.default()
    var mw = Pair(_Wrap(String("<a>"), String("</a>")), _Wrap(String("<b>"), String("</b>")))
    var disp = _Dispatcher()

    var resp = _drive_chain_dispatch[_Dispatcher, Pair, _Rt](
        chain, mw, disp, reactor, _make_req()
    )

    assert_equal(Int(resp.status), 200)
    var t = _text(resp)
    assert_true(t.startswith(String("<a><b>order=")), "outer wraps inner: " + t)
    assert_true(t.endswith(String("</b></a>")), "outer wraps inner: " + t)
    assert_equal(_header(resp, String("x-wrapped")), String("1"))
    _ = chain^
    _ = mw^
    _ = disp^


def main() raises:
    test_compose_in_order()
    test_short_circuit_skips_inner_and_dispatcher()
    test_outermost_short_circuit_skips_every_inner_after()
    test_context_and_request_mutation_reach_inner_layer_and_dispatcher()
    test_inner_layer_without_outer_identity_refuses()
    test_after_wraps_response_in_reverse_order()
    print("PASS test_custom_middleware")
