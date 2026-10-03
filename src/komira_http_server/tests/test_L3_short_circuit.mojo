# =============================================================================
# tests/test_L3_short_circuit.mojo
# =============================================================================
#
# middleware short-circuit semantics
# (L3: "middleware MAY return without calling
# next, e.g., 401 unauthorized").
#
# Coverage:
#   * User Middleware returns Some(401) from before() — handler/canned NOT invoked
#   * After-chain still runs in reverse on the short-circuit response
#   * outcome.short_circuited == True
#   * LoggingMiddleware still records the short-circuit in LogEntry
#   * Subsequent user middlewares are NOT invoked (chain stops at first short-circuit)
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_http_core.codec import (
    HttpMethod,
    HttpRequest,
    HttpResponse,
)
from komira_http_server.middleware import (
    ErrorMappingMiddleware,
    LoggingMiddleware,
    Middleware,
    MiddlewareChain,
    RequestContext,
    TracingMiddleware,
)


# -----------------------------------------------------------------------------
# Sample user-defined middleware that always returns 401 from before().
# -----------------------------------------------------------------------------


@fieldwise_init
struct AuthRejectMiddleware(Middleware, Movable, Deinitable):
    """User middleware that ALWAYS short-circuits with 401 Unauthorized.

    Demonstrates the short-circuit contract: a Middleware that returns
    Some(response) from before() halts the chain immediately. The
    handler / canned response at the bottom is NEVER invoked.

    Conforms to the Middleware trait — proves the trait surface admits
    user extensions even though This version ships only 4 builtins.
    """

    var calls_before: Int
    var calls_after: Int

    @staticmethod
    def new() -> AuthRejectMiddleware:
        return AuthRejectMiddleware(calls_before=0, calls_after=0)

    def before(
        mut self,
        mut req: HttpRequest,
        mut ctx: RequestContext,
    ) raises -> Optional[HttpResponse]:
        self.calls_before = self.calls_before + 1
        var resp = HttpResponse(status=Int32(401))
        resp.headers[String("content-type")] = String("text/plain")
        resp.headers[String("content-length")] = String("12")
        # Static body — NEVER echo a user input.
        var msg = String("Unauthorized")
        var msg_bytes = msg.as_bytes()
        var i = 0
        while i < len(msg_bytes):
            resp.body.append(msg_bytes[i])
            i = i + 1
        return Optional[HttpResponse](resp^)

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        self.calls_after = self.calls_after + 1


@fieldwise_init
struct PassthroughMiddleware(Middleware, Movable, Deinitable):
    """No-op middleware. Used to test "this layer never runs" assertions."""

    var calls_before: Int
    var calls_after: Int

    @staticmethod
    def new() -> PassthroughMiddleware:
        return PassthroughMiddleware(calls_before=0, calls_after=0)

    def before(
        mut self,
        mut req: HttpRequest,
        mut ctx: RequestContext,
    ) raises -> Optional[HttpResponse]:
        self.calls_before = self.calls_before + 1
        return Optional[HttpResponse]()

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        self.calls_after = self.calls_after + 1


def _make_get_request(path: String) -> HttpRequest:
    return HttpRequest(HttpMethod.get(), path)


def _canned_200() -> HttpResponse:
    return HttpResponse.ok(String("hello"))


def test_user_middleware_short_circuits_with_401() raises:
    """User middleware returning Some(401) from before() halts the
    chain — handler/canned NOT invoked, outcome.response is the 401."""
    var chain = MiddlewareChain.default()
    var req = _make_get_request(String("/protected"))
    var auth_mw = AuthRejectMiddleware.new()
    var outcome = chain.run_with_user_mw[AuthRejectMiddleware](
        req^, _canned_200(), auth_mw
    )
    assert_equal(Int(outcome.response.status), 401)
    assert_true(outcome.short_circuited)


def test_after_chain_still_runs_on_short_circuit() raises:
    """Even when the chain short-circuits, the after-phase runs in
    reverse for already-invoked middlewares. LoggingMiddleware's
    LogEntry captures the short-circuit response status (401)."""
    var chain = MiddlewareChain.default()
    var req = _make_get_request(String("/admin"))
    var auth_mw = AuthRejectMiddleware.new()
    var outcome = chain.run_with_user_mw[AuthRejectMiddleware](
        req^, _canned_200(), auth_mw
    )
    assert_equal(Int(outcome.response.status), 401)
    ref logging_opt = chain.logging_ref()
    assert_true(Bool(logging_opt))
    ref lg = logging_opt.value()
    assert_equal(lg.entries_len(), 1)
    var entry = lg.entry(0)
    # LogEntry records the short-circuit status.
    assert_equal(Int(entry.status), 401)
    assert_true(entry.short_circuit)


def test_short_circuit_response_carries_cors_headers() raises:
    """CORS.after still adds Access-Control-Allow-Origin on the
    short-circuit response (since the after-chain runs)."""
    var chain = MiddlewareChain.default()
    var req = _make_get_request(String("/admin"))
    var auth_mw = AuthRejectMiddleware.new()
    var outcome = chain.run_with_user_mw[AuthRejectMiddleware](
        req^, _canned_200(), auth_mw
    )
    # CORS headers applied even on 401.
    assert_true(
        outcome.response.headers.__contains__(
            String("access-control-allow-origin")
        )
    )


def test_passthrough_middleware_does_not_short_circuit() raises:
    """A user middleware that returns None from before() does NOT
    short-circuit — the canned response flows through normally."""
    var chain = MiddlewareChain.default()
    var req = _make_get_request(String("/healthz"))
    var pass_mw = PassthroughMiddleware.new()
    var outcome = chain.run_with_user_mw[PassthroughMiddleware](
        req^, _canned_200(), pass_mw
    )
    assert_equal(Int(outcome.response.status), 200)
    assert_false(outcome.short_circuited)


def main() raises:
    test_user_middleware_short_circuits_with_401()
    test_after_chain_still_runs_on_short_circuit()
    test_short_circuit_response_carries_cors_headers()
    test_passthrough_middleware_does_not_short_circuit()
    print("test_L3_short_circuit: OK")
