# =============================================================================
# src/komira_http/middleware/tracing.mojo — span timing, no live span
# =============================================================================
#
# L3 tracing middleware. Span name = "http.request" (comptime span names;
# FNV-1a digest at the call site). Dynamic method+route attribution happens
# via LoggingMiddleware, which records method + path + status.
#
# A full `Tracer` is non-Movable and requires a `worker_id` for the
# per-worker ring plus a comptime `name`, so this ships a SIMPLIFIED surface:
# when enabled, the middleware records (start_ns, end_ns) into a server-local
# `List[TracingSpan]` buffer; this is the test surface. It uses
# `komira_clock.now_ns` only for timestamps and emits NO live span.
#
# The simplified surface gives us:
#   - chain composability (before/after pair)
#   - test-asserted span emission (buffer count)
#   - latency capture per request
#
# A live-span integration should target the unified logging span surface —
# `log.span_open["http.request", "komira_http"](worker_id)` /
# `log.span_close(span_id, worker_id)` (ambient, no ctx needed), or
# `ctx.tracer()` where an EngineContext is in scope.
# =============================================================================

from komira_http.codec.types import HttpRequest, HttpResponse
from komira_http.middleware.middleware import RequestContext


# Use komira_clock directly for the platform-monotonic ns counter.
from komira_clock import now_ns as _now_ns


# =============================================================================
# §1 — TracingSpan: in-process span record.
# =============================================================================


@fieldwise_init
struct TracingSpan(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """One emitted span. carries the minimal field set; a later version swaps
    to komira_trace.SpanRecord on the production path.

    Schema:
      span_id     — sequential id assigned by TracingMiddleware (1, 2, ...)
      worker_id   — worker / pthread id (from ctx)
      start_ns    — span start (request-arrival monotonic ns)
      end_ns      — span end (after-phase monotonic ns)
      status      — final HTTP response status
      method_code — HTTP method code (avoids carrying the full HttpMethod
                    POD; tests can compare against HTTP_METHOD_*).
      path        — request path (route attribution; not the full URL)
    """

    var span_id: UInt64
    var worker_id: Int
    var start_ns: UInt64
    var end_ns: UInt64
    var status: Int32
    var method_code: UInt8
    var path: String

    @staticmethod
    def empty() -> TracingSpan:
        return TracingSpan(
            span_id=UInt64(0),
            worker_id=0,
            start_ns=UInt64(0),
            end_ns=UInt64(0),
            status=Int32(0),
            method_code=UInt8(0),
            path=String(""),
        )


# =============================================================================
# §2 — TracingMiddleware.
# =============================================================================


struct TracingMiddleware(Movable, Deinitable):
    """Emits a span per request into a server-local buffer.

    Construction:
      TracingMiddleware.new       — enabled
      TracingMiddleware.disabled()  — no-op (chain still runs the
                                       before/after, but doesn't record)

    Public surface:
      .before(req, ctx)            — assigns span_id; records start_ns
      .after(req, resp, ctx)       — records end_ns + status; appends
                                     TracingSpan to .spans
      .spans                       — List[TracingSpan]; test-readable
      .spans_len()                 — len(spans)
      .clear()                     — reset buffer

    Swap path: replace the in-process buffer with a borrowed
    `Pointer[Tracer]` field. The before/after pair becomes:
      .before — tracer[].start_span[name="http.request"](worker_id, 0)
      .after  — tracer[].end_span(span_id, worker_id)
    """

    var enabled: Bool
    var _next_span_id: UInt64
    var spans: List[TracingSpan]

    def __init__(out self, enabled: Bool, next_span_id: UInt64):
        self.enabled = enabled
        self._next_span_id = next_span_id
        self.spans = List[TracingSpan]()

    @staticmethod
    def new() -> TracingMiddleware:
        return TracingMiddleware(True, UInt64(1))

    @staticmethod
    def disabled() -> TracingMiddleware:
        return TracingMiddleware(False, UInt64(0))

    def before(
        mut self,
        mut req: HttpRequest,
        mut ctx: RequestContext,
    ) raises -> Optional[HttpResponse]:
        """Assign a span_id and record start time."""
        if not self.enabled:
            return Optional[HttpResponse]()
        var sid = self._next_span_id
        self._next_span_id = self._next_span_id + UInt64(1)
        ctx.span_id = sid
        if ctx.start_ns == UInt64(0):
            ctx.start_ns = _now_ns()
        return Optional[HttpResponse]()

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        """Record span end + status."""
        if not self.enabled:
            return
        if ctx.span_id == UInt64(0):
            # before was never called — no span to close. Defensive.
            return
        var end_ns = _now_ns()
        var span = TracingSpan(
            span_id=ctx.span_id,
            worker_id=ctx.worker_id,
            start_ns=ctx.start_ns,
            end_ns=end_ns,
            status=resp.status,
            method_code=req.method.code,
            path=String(req.path),
        )
        self.spans.append(span^)

    def spans_len(self) -> Int:
        return len(self.spans)

    def span(self, idx: Int) -> TracingSpan:
        if idx < 0 or idx >= len(self.spans):
            return TracingSpan.empty()
        return self.spans[idx]

    def clear(mut self):
        self.spans = List[TracingSpan]()
        self._next_span_id = UInt64(1)
