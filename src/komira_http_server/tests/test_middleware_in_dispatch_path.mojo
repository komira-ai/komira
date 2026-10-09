# =============================================================================
# test_middleware_in_dispatch_path.mojo — the middleware-in-path seam gate.
# =============================================================================
#
# The regression guard for the chain-around-dispatcher architecture: prove the
# `komira_http` middleware chain actually RUNS in the H1 dispatch path (around a
# `CtxRequestDispatcher`), rather than the serve-dispatch path handing the
# parsed request straight to the dispatcher, never invoking the chain.
#
# It asserts:
#
#   1. a probe `Middleware` stamps a marker on the per-
#      request context in `before`; the dispatcher (reached on a non-short-
#      circuit request) observes the marker via `ctx.principal` — proving the
#      chain's `before` leg ran BEFORE the dispatcher.
#   2. a probe middleware that short-
#      circuits with a 401 means a dispatcher that would otherwise 200 is NEVER
#      reached (its "I ran" flag stays false) and the response is the 401.
#   3. AFTER-LEGS-RUN: the response from the dispatcher flows back through the
#      chain unchanged (the builtins' `after` are no-ops here, so we assert the
#      200 survives the after phase).
#
# It drives `_drive_chain_dispatch[D, M, RT]` directly (the transport leaf the
# socket serve path calls per request) so the seam is exercised without standing
# up a real listener — the chain → dispatcher composition is the load-bearing
# unit, identical to what `serve_read_round_dispatch_chained` invokes.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime

from komira_http_core.codec.types import (
    HttpRequest,
    HttpResponse,
    HttpMethod,
)
from komira_http_server.middleware import (
    Middleware,
    MiddlewareChain,
    Principal,
    RequestContext,
)
from komira_http_server.dispatch import (
    CtxRequestDispatcher,
    RequestDispatcher,
    _drive_chain_dispatch,
)


comptime _Rt = BlockingRuntime[NoopSink]


def _rt() raises -> _Rt:
    return _Rt.new(NoopSink(_placeholder=UInt8(0)))


# A marker subject the probe middleware stamps so the dispatcher can observe
# that the chain's `before` leg ran and populated the ctx.
comptime _MARKER_SUBJECT = "probe-subject"


# =============================================================================
# Probe middleware — stamps a marker Principal on `before`, OR short-circuits.
# =============================================================================
struct _ProbeMiddleware(Movable, Deinitable, Middleware):
    """A `Middleware` conformer for the test. When `_short_circuit` is False, its
    `before` stamps a marker `Principal` on the ctx (proving the chain ran
    before the dispatcher) and returns None (continue). When True, it short-
    circuits with a 401 (proving the dispatcher is never reached)."""

    var _short_circuit: Bool

    def __init__(out self, short_circuit: Bool):
        self._short_circuit = short_circuit

    def before(
        mut self,
        mut req: HttpRequest,
        mut ctx: RequestContext,
    ) raises -> Optional[HttpResponse]:
        if self._short_circuit:
            var r = HttpResponse(status=Int32(401))
            r.headers[String("content-length")] = String("0")
            return Optional[HttpResponse](r^)
        # Stamp the marker identity onto the ctx (the seam an authentication
        # middleware uses).
        ctx.principal = Optional[Principal](Principal(scheme=String("jwt"), subject=String(_MARKER_SUBJECT)))
        return Optional[HttpResponse]()

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        pass


# =============================================================================
# Probe dispatcher — records whether it was reached; reads the marker off ctx.
# =============================================================================
struct _ProbeDispatcher(Movable, RequestDispatcher, CtxRequestDispatcher):
    """A `CtxRequestDispatcher` for the test. `dispatch_with_ctx` flips
    `_reached` (so a short-circuit that skips it is observable), reads the
    marker `Principal` off the ctx (proving the chain ran first), and returns
    200 (with the marker's presence reflected in the status path)."""

    var _reached: Bool
    var _saw_marker: Bool

    def __init__(out self):
        self._reached = False
        self._saw_marker = False

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        # The chain-less path (RequestDispatcher) — delegates to the ctx form
        # with an empty/anon context (no identity).
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
        self._reached = True
        if ctx.principal:
            if ctx.principal.value().subject == String(_MARKER_SUBJECT):
                self._saw_marker = True
        return HttpResponse.ok(String('{"ok":true}'))


def _make_req() -> HttpRequest:
    var req = HttpRequest()
    req.method = HttpMethod.get()
    req.path = String("/probe")
    return req^


# =============================================================================
# 1. — the probe middleware's `before` ran before dispatch,
#    the dispatcher saw the marker, and the 200 flows back through the chain.
# =============================================================================
def test_chain_runs_before_dispatch() raises:
    var rt = _rt()
    ref reactor = rt.reactor()

    var chain = MiddlewareChain.default()
    var mw = _ProbeMiddleware(short_circuit=False)
    var disp = _ProbeDispatcher()

    var resp = _drive_chain_dispatch[_ProbeDispatcher, _ProbeMiddleware, _Rt](
        chain, mw, disp, reactor, _make_req()
    )

    assert_equal(Int(resp.status), 200, "non-short-circuit -> dispatcher 200")
    assert_true(disp._reached, "the dispatcher WAS reached")
    assert_true(
        disp._saw_marker,
        "the dispatcher saw the marker the middleware stamped on ctx "
        "(proves the chain ran BEFORE the dispatcher)",
    )

    _ = chain^
    _ = mw^
    _ = disp^


# =============================================================================
# 2. — a 401 short-circuit means the
#    dispatcher is NEVER reached, and the response is the 401.
# =============================================================================
def test_short_circuit_skips_dispatcher() raises:
    var rt = _rt()
    ref reactor = rt.reactor()

    var chain = MiddlewareChain.default()
    var mw = _ProbeMiddleware(short_circuit=True)
    var disp = _ProbeDispatcher()

    var resp = _drive_chain_dispatch[_ProbeDispatcher, _ProbeMiddleware, _Rt](
        chain, mw, disp, reactor, _make_req()
    )

    assert_equal(Int(resp.status), 401, "short-circuit -> 401")
    assert_false(
        disp._reached,
        "the dispatcher was NEVER reached (the 401 short-circuited before it)",
    )

    _ = chain^
    _ = mw^
    _ = disp^


def main() raises:
    test_chain_runs_before_dispatch()
    test_short_circuit_skips_dispatcher()
    print("PASS test_middleware_in_dispatch_path")
