# =============================================================================
# src/komira_http_server/middleware/logging.mojo — structured request/response log
# =============================================================================
#
# L3.
#
# Emits a structured log entry per request: method, path, status,
# latency_ns. Records start time in `before`; emits the line in
# `after`. Server-local `List[LogEntry]` buffer — test-asserted via
# CapturingExporter-style API.
#
# ⚠ THE EXPORT SEAM IS NO LONGER "A FOLLOW-UP" — IT IS
# `middleware/metrics.mojo`. `MetricsMiddleware[S: MetricsSink]` lets a user
# plug in their own writer and receive these same entries, plus the request's
# two monotonic ENDPOINTS, once per request, before the response is written.
# This middleware is deliberately unchanged and stays non-parametric: retyping
# it would change `MiddlewareChain._logging`'s field type and every chain
# construction site. The buffer below is still what it always was — a bounded
# in-process ring that DROPS THE OLDEST and dies with the container. Anything
# that must leave the process goes through a `MetricsSink`, not through here.
#
# Sensitive-header redaction: L3 "redaction of
# sensitive headers (`Authorization`, `Cookie`)". The LogEntry stores
# only allowlisted fields; never the full header map.
#
# Pointer discipline: pure value semantics. No UnsafePointer.
# =============================================================================

from komira_http_core.codec.types import (
    HTTP_METHOD_UNKNOWN,
    HttpMethod,
    HttpRequest,
    HttpResponse,
)
from komira_http_server.middleware.middleware import RequestContext


# =============================================================================
# §1 — Comptime clock function.
# =============================================================================
# Imports the platform-monotonic ns counter from komira_clock.
# Falls back to a stdlib monotonic counter via `perf_counter_ns` is the
# a later swap; for now we use komira_clock's now_ns directly.


from komira_clock import now_ns as _now_ns


# =============================================================================
# §2 — LogEntry.
# =============================================================================


@fieldwise_init
struct LogEntry(
    Copyable, ImplicitlyCopyable, Movable, Deinitable
):
    """One structured log entry, emitted at after-phase per request.

    Schema:
      method        — request HTTP method (GET / POST / ...)
      path          — request path; does NOT include query (query bytes
                      may carry sensitive params; logs path only)
      status        — response status code (200 / 404 / 500 / ...)
      latency_ns    — end_ns - start_ns; 0 if start_ns was not set
      span_id       — opaque span id (0 if no tracer)
      short_circuit — True iff the response did NOT come from a handler

    ⚠ THIS TYPE IS ALSO THE `MetricsSink` PAYLOAD (`metrics.mojo`), so it is
    now part of an OPEN-SOURCE API embedded in customer code: a field added
    here can land on a customer's metrics wire, and a field removed here breaks
    their sink. Change it deliberately.

    ⛔ AND `latency_ns` IS NOT A METERING QUANTITY. It is a per-request scalar,
    and scalars cannot be unioned — summing them overstates usage by the
    concurrency factor. Metering carries the two ENDPOINTS instead; see
    `RequestMetric` in `metrics.mojo`.

    Sensitive fields explicitly NOT included:
      - request body (size only)
      - response body
      - Authorization / Cookie / Set-Cookie headers
      - query_string (may carry tokens)
    """

    var method: HttpMethod
    var path: String
    var status: Int32
    var latency_ns: UInt64
    var span_id: UInt64
    var short_circuit: Bool

    @staticmethod
    def empty() -> LogEntry:
        return LogEntry(
            method=HttpMethod(code=HTTP_METHOD_UNKNOWN),
            path=String(""),
            status=Int32(0),
            latency_ns=UInt64(0),
            span_id=UInt64(0),
            short_circuit=False,
        )


# =============================================================================
# §3 — LoggingMiddleware.
# =============================================================================


struct LoggingMiddleware(Movable, Deinitable):
    """Records start-time in `before`, emits a LogEntry in `after`.

    Server-local buffer (`entries`) holds all emitted entries; tests
    assert against it. ⚠ THAT BUFFER IS THE END OF THE LINE: it is bounded,
    it drops the oldest on overflow, and it dies with the process. To get
    these entries OUT, install `MetricsMiddleware` from
    `middleware/metrics.mojo` with your own `MetricsSink` conformer.

    Configuration:
      enabled          — if False, no entries emitted (default True).
      max_buffer_size  — buffer is bounded; on overflow the oldest is
                         dropped. Default 1024 (per-server cap).

    Public surface:
      LoggingMiddleware.new() — defaults
      .before(req, ctx)       — sets ctx.start_ns
      .after(req, resp, ctx)  — emits LogEntry
      .entries                — buffer (List[LogEntry]; test-readable)
      .entries_len()          — len(entries)
      .clear()                — reset buffer
    """

    var enabled: Bool
    var max_buffer_size: Int
    var entries: List[LogEntry]

    def __init__(out self, enabled: Bool, max_buffer_size: Int):
        self.enabled = enabled
        self.max_buffer_size = max_buffer_size
        self.entries = List[LogEntry]()

    @staticmethod
    def new() -> LoggingMiddleware:
        return LoggingMiddleware(True, 1024)

    @staticmethod
    def with_capacity(max_buffer_size: Int) -> LoggingMiddleware:
        return LoggingMiddleware(True, max_buffer_size)

    @staticmethod
    def disabled() -> LoggingMiddleware:
        return LoggingMiddleware(False, 0)

    def before(
        mut self,
        mut req: HttpRequest,
        mut ctx: RequestContext,
    ) raises -> Optional[HttpResponse]:
        """Record request start time."""
        if self.enabled:
            ctx.start_ns = _now_ns()
        return Optional[HttpResponse]()

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        """Emit a LogEntry with method / path / status / latency."""
        if not self.enabled:
            return
        var end_ns = _now_ns()
        var latency = UInt64(0)
        if ctx.start_ns > UInt64(0):
            if end_ns >= ctx.start_ns:
                latency = end_ns - ctx.start_ns
        var entry = LogEntry(
            method=req.method,
            path=String(req.path),
            status=resp.status,
            latency_ns=latency,
            span_id=ctx.span_id,
            short_circuit=ctx.short_circuit,
        )
        # Bounded buffer: drop oldest on overflow.
        if len(self.entries) >= self.max_buffer_size:
            # Pop front: implemented as a swap-left compaction.
            # for now cap=1024 this is rare; the perf hit is acceptable.
            _ = self.entries.pop(0)
        self.entries.append(entry^)

    def entries_len(self) -> Int:
        return len(self.entries)

    def entry(self, idx: Int) -> LogEntry:
        if idx < 0 or idx >= len(self.entries):
            return LogEntry.empty()
        return self.entries[idx]

    def clear(mut self):
        self.entries = List[LogEntry]()
