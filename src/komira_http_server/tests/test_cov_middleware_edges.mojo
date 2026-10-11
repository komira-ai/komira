# =============================================================================
# test_cov_middleware_edges.mojo: the edges of the middleware and the router
# that the scenario tests do not reach
# =============================================================================
#
# Each test drives one public entry point at a boundary and asserts the exact
# answer, so the defect named beside it changes what the test sees.
#
# Groups (and the defect each would catch):
#   I  index accessors past either end: the bounds check off by one (an
#      index equal to the length read past the list), or the empty value
#      carrying a stale field.
#   M  a disabled metrics middleware: stamping a start, or reporting to its
#      sink.
#   J  the fault envelope's JSON escaping: a quote, backslash or control
#      byte copied raw into the body (invalid JSON a client cannot parse).
#   C  the chain: a CORS preflight not short-circuiting the canned or the
#      user-middleware chain, and a raising `after` not re-run best-effort
#      on the error response; around a dispatcher, a raise not mapped to
#      the 500, the after legs not run on it, or their own raise escaping.
#   R  the router: a malformed wildcard or an empty pattern accepted, a
#      wildcard route matching a path shorter than its prefix, a parameter
#      before a wildcard not captured.
# =============================================================================

from std.collections.dict import Dict
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.runtime_trait import Runtime
from komira_http_core.codec import HttpMethod, HttpRequest, HttpResponse
from komira_http_core.codec.types import HTTP_METHOD_UNKNOWN
from komira_http_server.middleware import (
    CorsMiddleware,
    ErrorMappingMiddleware,
    LoggingMiddleware,
    Middleware,
    MiddlewareChain,
    RequestContext,
    TracingMiddleware,
    fault_envelope,
)
from komira_http_server.middleware.metrics import (
    CapturingSink,
    MetricsMiddleware,
)
from komira_http_server.dispatch import (
    CtxRequestDispatcher,
    RequestDispatcher,
    _drive_chain_dispatch,
)
from komira_http_server.routing import Router

comptime _Rt = BlockingRuntime[NoopSink]


# -----------------------------------------------------------------------------
# I: index accessors past either end.
# -----------------------------------------------------------------------------


def test_error_mapper_log_entry_out_of_range_is_empty() raises:
    """One mapped error is entry 0; -1 and 1 (the length) are empty."""
    var em = ErrorMappingMiddleware.default()
    _ = em.map_error(Error("boom"))
    assert_equal(em.diagnostic_log_len(), 1)
    assert_true(em.diagnostic_log_entry(0).find(String("boom")) >= 0)
    assert_equal(em.diagnostic_log_entry(1), String(""))
    assert_equal(em.diagnostic_log_entry(-1), String(""))


def test_logging_entry_out_of_range_is_empty() raises:
    var lg = LoggingMiddleware.new()
    var req = HttpRequest(HttpMethod.get(), String("/seen"))
    var resp = HttpResponse(status=Int32(201))
    var ctx = RequestContext.new()
    _ = lg.before(req, ctx)
    lg.after(req, resp, ctx)
    assert_equal(lg.entries_len(), 1)
    assert_equal(lg.entry(0).path, String("/seen"))
    for idx in [1, -1]:
        var e = lg.entry(idx)
        assert_equal(e.method.code, HTTP_METHOD_UNKNOWN)
        assert_equal(e.path, String(""))
        assert_equal(e.status, Int32(0))
        assert_equal(e.latency_ns, UInt64(0))
        assert_equal(e.span_id, UInt64(0))
        assert_false(e.short_circuit)


def test_tracing_span_out_of_range_is_empty() raises:
    var tr = TracingMiddleware.new()
    var req = HttpRequest(HttpMethod.get(), String("/traced"))
    var resp = HttpResponse(status=Int32(200))
    var ctx = RequestContext.new()
    _ = tr.before(req, ctx)
    tr.after(req, resp, ctx)
    assert_equal(tr.spans_len(), 1)
    assert_equal(tr.span(0).path, String("/traced"))
    for idx in [1, -1]:
        var s = tr.span(idx)
        assert_equal(s.span_id, UInt64(0))
        assert_equal(s.worker_id, 0)
        assert_equal(s.start_ns, UInt64(0))
        assert_equal(s.end_ns, UInt64(0))
        assert_equal(s.status, Int32(0))
        assert_equal(s.method_code, UInt8(0))
        assert_equal(s.path, String(""))


def test_capturing_sink_out_of_range_raises() raises:
    var sink = CapturingSink()
    for idx in [0, -1]:
        var raised = False
        try:
            _ = sink.at(idx)
        except e:
            raised = True
            assert_true(
                String(e).find(String("index out of range: ") + String(idx))
                >= 0,
                String(e),
            )
        assert_true(raised, "at(" + String(idx) + ") on an empty sink")


# -----------------------------------------------------------------------------
# M: a disabled metrics middleware.
# -----------------------------------------------------------------------------


def test_disabled_metrics_stamps_nothing_and_records_nothing() raises:
    var mw = MetricsMiddleware[CapturingSink].disabled(CapturingSink())
    assert_false(mw.enabled())
    var req = HttpRequest(HttpMethod.get(), String("/m"))
    var resp = HttpResponse(status=Int32(200))
    var ctx = RequestContext.new()
    assert_false(Bool(mw.before(req, ctx)))
    assert_equal(ctx.start_ns, UInt64(0), "a disabled before stamped a start")
    mw.after(req, resp, ctx)
    assert_equal(mw.sink_ref().len(), 0, "a disabled after reported")
    # The same request through an enabled one is recorded: the sink works.
    var on = MetricsMiddleware[CapturingSink].new(CapturingSink())
    var ctx2 = RequestContext.new()
    _ = on.before(req, ctx2)
    on.after(req, resp, ctx2)
    assert_equal(on.sink_ref().len(), 1)


# -----------------------------------------------------------------------------
# J: the fault envelope's JSON escaping.
# -----------------------------------------------------------------------------


def _body_text(r: HttpResponse) -> String:
    var s = String()
    for i in range(len(r.body)):
        s += chr(Int(r.body[i]))
    return s^


def test_fault_envelope_escapes_every_special_byte() raises:
    """RFC 8259 section 7: a quote, a backslash and the control bytes must be
    escaped inside a string. The envelope writes the named escapes for
    quote, backslash, LF, CR and TAB, and a space for any other control
    byte (here 0x01 and 0x1F)."""
    var msg = String('a"b\\c\nd\re\tf') + chr(1) + String("g") + chr(31)
    var r = fault_envelope(Int32(500), String("C"), String("I"), msg)
    var want = String('{"error":{"code":"C","message":"a\\"b\\\\c\\nd\\re\\tf g ')
    want += String('","incidentId":"I"}}')
    assert_equal(_body_text(r), want)
    assert_equal(r.headers[String("content-length")], String(want.byte_length()))


# -----------------------------------------------------------------------------
# C: the chain.
# -----------------------------------------------------------------------------


def _preflight() -> HttpRequest:
    var r = HttpRequest(HttpMethod.options(), String("/api"))
    r.headers[String("origin")] = String("https://example.com")
    r.headers[String("access-control-request-method")] = String("POST")
    return r^


def test_canned_chain_preflight_short_circuits() raises:
    """With CORS, tracing and logging installed, a preflight is answered by
    CORS's 204 instead of the canned 200, and the logging after-leg still
    records it."""
    var chain = MiddlewareChain.default()
    chain = chain^.with_tracing(TracingMiddleware.new())
    var out = chain.run_with_canned(_preflight(), HttpResponse(status=Int32(200)))
    assert_equal(Int(out.response.status), 204)
    assert_true(out.short_circuited)
    assert_true(
        out.response.headers.__contains__(String("access-control-allow-methods"))
    )
    assert_equal(chain.logging_ref().value().entries_len(), 1)
    assert_equal(chain.logging_ref().value().entry(0).status, Int32(204))


struct _CountingMw(Middleware, Movable, Deinitable):
    """Counts its legs; its `after` raises when `raise_after` is set."""

    var befores: Int
    var afters: Int
    var raise_after: Bool

    def __init__(out self, raise_after: Bool):
        self.befores = 0
        self.afters = 0
        self.raise_after = raise_after

    def before(
        mut self, mut req: HttpRequest, mut ctx: RequestContext
    ) raises -> Optional[HttpResponse]:
        self.befores += 1
        return Optional[HttpResponse]()

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        self.afters += 1
        if self.raise_after:
            raise Error("after leg failed")


def test_user_chain_preflight_skips_the_user_middleware() raises:
    var chain = MiddlewareChain.default()
    var mw = _CountingMw(False)
    var out = chain.run_with_user_mw[_CountingMw](
        _preflight(), HttpResponse(status=Int32(200)), mw
    )
    assert_equal(Int(out.response.status), 204)
    assert_true(out.short_circuited)
    assert_equal(mw.befores, 0, "the user before ran behind a preflight")
    assert_equal(mw.afters, 0, "the user after ran though its before did not")


def test_raising_user_after_is_mapped_and_retried_once() raises:
    """The user `after` raises: the chain answers the mapped 500, then runs
    the after legs once more on that 500, best-effort; the second raise is
    swallowed."""
    var chain = MiddlewareChain.default()
    var mw = _CountingMw(True)
    var out = chain.run_with_user_mw[_CountingMw](
        HttpRequest(HttpMethod.get(), String("/x")),
        HttpResponse(status=Int32(200)),
        mw,
    )
    assert_equal(Int(out.response.status), 500)
    assert_true(out.short_circuited)
    assert_equal(mw.befores, 1)
    assert_equal(mw.afters, 2)


struct _Raising(Movable, RequestDispatcher, CtxRequestDispatcher):
    """A dispatcher whose handler always raises."""

    var calls: Int

    def __init__(out self):
        self.calls = 0

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        var ctx = RequestContext.new()
        return self.dispatch_with_ctx[RT](reactor, req, ctx)

    def dispatch_with_ctx[
        RT: Runtime,
    ](
        mut self,
        mut reactor: Reactor[RT.Sink],
        mut req: HttpRequest,
        ctx: RequestContext,
    ) raises -> HttpResponse:
        self.calls += 1
        raise Error("handler failed")


def _raise_through_chain(raise_after: Bool) raises:
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var chain = MiddlewareChain.default()
    var mw = _CountingMw(raise_after)
    var d = _Raising()
    var resp = _drive_chain_dispatch[_Raising, _CountingMw, _Rt](
        chain, mw, d, reactor, HttpRequest(HttpMethod.get(), String("/r"))
    )
    assert_equal(d.calls, 1)
    assert_equal(Int(resp.status), 500)
    assert_true(resp.headers.__contains__(String("x-incident-id")))
    assert_equal(mw.befores, 1)
    # The after legs ran once, on the 500 (the raise skipped the first run).
    assert_equal(mw.afters, 1)
    if not raise_after:
        assert_equal(chain.logging_ref().value().entries_len(), 1)
        assert_equal(chain.logging_ref().value().entry(0).status, Int32(500))


def test_dispatcher_raise_is_mapped_and_after_legs_run() raises:
    _raise_through_chain(False)


def test_dispatcher_raise_with_a_raising_after_is_still_mapped() raises:
    _raise_through_chain(True)


# -----------------------------------------------------------------------------
# R: the router.
# -----------------------------------------------------------------------------


def _refused(pattern: String, needle: String) raises:
    var r = Router()
    var raised = False
    try:
        r.add(HttpMethod.get(), pattern, 1)
    except e:
        raised = True
        assert_true(String(e).find(needle) >= 0, String(e))
    assert_true(raised, "pattern '" + pattern + "' was accepted")
    assert_equal(r.len(), 0)


def test_wildcard_with_a_suffix_is_refused() raises:
    _refused(String("/files/*x"), String("single-character segment"))
    _refused(String("/files/**"), String("single-character segment"))


def test_empty_pattern_is_refused() raises:
    _refused(String(""), String("must not be empty"))


def test_wildcard_needs_its_whole_prefix() raises:
    var r = Router()
    r.add(HttpMethod.get(), String("/a/b/*"), 7)
    var p = Dict[String, String]()
    assert_false(Bool(r.match_route(HttpMethod.get(), String("/a"), p)))
    assert_false(Bool(r.match_route(HttpMethod.get(), String("/"), p)))
    assert_false(r.has_path_match(String("/a")))
    var hit = r.match_route(HttpMethod.get(), String("/a/b/c/d"), p)
    assert_equal(hit.value(), 7)


def test_parameter_before_a_wildcard_is_captured() raises:
    var r = Router()
    r.add(HttpMethod.get(), String("/u/:id/*"), 3)
    var p = Dict[String, String]()
    var hit = r.match_route(HttpMethod.get(), String("/u/42/files/x"), p)
    assert_equal(hit.value(), 3)
    assert_equal(p[String("id")], String("42"))
    var p2 = Dict[String, String]()
    var miss = r.match_route(HttpMethod.get(), String("/v/42/files"), p2)
    assert_false(Bool(miss))
    assert_equal(len(p2), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
