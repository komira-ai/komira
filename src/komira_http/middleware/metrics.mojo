# =============================================================================
# src/komira_http/middleware/metrics.mojo — THE CONFIGURABLE METRICS
#   SEAM. A user plugs in THEIR OWN sink and gets their own request metrics out.
# =============================================================================
#
# ★ THIS IS A PRODUCT SURFACE, NOT AN INTERNAL SEAM. It ships in an open-source
# library and is embedded in CUSTOMER CODE. Logic put here cannot be changed
# without every customer redeploying. That single fact governs every judgement
# call in this file:
#
#   ⛔ NOTHING IN THIS FILE ACCUMULATES, UNIONS, SUMS, OR BILLS.
#
# The middleware takes a start timestamp and an end timestamp and hands them to
# a sink. It computes no totals, keeps no counters across requests, and knows
# nothing about vCPU allocation or money. Every bit of that arithmetic belongs
# to the collector the sink reports to, which is ONE service. If you find yourself adding a counter
# here, stop — you are putting a number in every customer binary that you
# then cannot correct.
#
# WHY TWO ENDPOINTS AND NEVER A DURATION
# --------------------------------------
# The billable quantity is the wall time during which AT LEAST ONE request was
# in flight on an instance — the UNION of the request intervals, not their sum:
#
#     80 requests, 1s each, fully overlapping  -> union =  1s  ✅
#     80 requests, 1s each, sequential         -> union = 80s  ✅
#     ...summed, the first case reports 80s — an 80x overbill.
#
# A union is computable ONLY from intervals. A payload carrying a scalar
# duration per request (`latency_ns` alone) forecloses it at the client and
# leaves the server no choice but to sum — a bug that is INVISIBLE under
# sequential traffic and silently overbills under concurrency. So
# `RequestMetric` carries `start_mono_ns` AND `end_mono_ns` as separate fields,
# and the two are never subtracted on their way to a sink.
#
# ⚠ THE ENDPOINTS ARE MONOTONIC (`komira_obs.clock.now_ns`) — the same clock
# `LoggingMiddleware.before` already stamps into `ctx.start_ns`. Monotonic,
# because a union taken over wall-clock stamps is corrupted by an NTP step, and
# a step is exactly the event a billing system must not be sensitive to.
# CONSEQUENCE, AND IT IS A CONTRACT ON THE CONFIGURATOR, NOT ON THIS CODE: a
# monotonic reading is comparable only WITHIN ONE PROCESS. The instance
# identifier a sink posts alongside these endpoints MUST therefore be unique per
# PROCESS (not merely per container image or per revision), or the server would
# union two processes' incomparable clocks. `StatusHookConfig` says so again at
# its own constructor, which is where an operator will actually read it.
#
# WHERE THE PER-REQUEST STATE LIVES, AND WHY IT IS NOT ON `self`
# --------------------------------------------------------------
# `MetricsMiddleware` stores the start timestamp on the per-request
# `RequestContext` (`ctx.start_ns`), NEVER on the middleware instance. One
# middleware instance serves every request on its serve loop, so a `self._start`
# field would be OVERWRITTEN by the next request's `before` — and under
# concurrency, two overlapping requests would report one collapsed interval,
# which is precisely the observation the union exists to make. The chain already
# threads a `RequestContext` per request; that is the object whose lifetime
# matches the measurement.
#
# POINTER DISCIPLINE: pure value semantics. No UnsafePointer, no wildcard
# origins, nothing heap-allocated outside the sink's own storage.
# =============================================================================

from komira_http.codec.types import HttpRequest, HttpResponse
from komira_http.middleware.logging import LogEntry
from komira_http.middleware.middleware import Middleware, RequestContext
from komira_obs.clock import now_ns as _now_ns


# =============================================================================
# §1 — RequestMetric: the payload a sink receives.
# =============================================================================


@fieldwise_init
struct RequestMetric(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    """One request's observation, as handed to a `MetricsSink`.

    Two parts, with different owners:

      `entry`          — the EXISTING `LogEntry`
                         (`method`/`path`/`status`/`latency_ns`/`span_id`/
                         `short_circuit`), unchanged and reused rather than
                         duplicated. This is the CUSTOMER's metrics payload:
                         whatever they already wanted out of request logging,
                         they now get through their own writer.

      `start_mono_ns`  — the two ENDPOINTS of the request, monotonic ns, as
      `end_mono_ns`      SEPARATE fields. This is the METERING payload. They are
                         never subtracted here; see the banner.

    ⚠ `entry.latency_ns` IS A CONVENIENCE FOR THE CUSTOMER'S OWN DASHBOARDS AND
    MUST NOT BE PUT ON A METERING WIRE. It is `end - start` for THIS request —
    a scalar, and therefore un-unionable. `StatusHookSink` deliberately omits
    it from its body, and a test asserts the captured bytes do not contain it.

    ⛔ DO NOT "SIMPLIFY" THIS STRUCT BY DROPPING AN ENDPOINT AND KEEPING THE
    DURATION. That is the silent-overbill bug in its entirety: every sequential
    test still passes, and production overbills by the concurrency factor.
    """

    var entry: LogEntry
    var start_mono_ns: UInt64
    var end_mono_ns: UInt64

    @staticmethod
    def of(
        var entry: LogEntry, start_mono_ns: UInt64, end_mono_ns: UInt64
    ) -> RequestMetric:
        return RequestMetric(
            entry=entry^,
            start_mono_ns=start_mono_ns,
            end_mono_ns=end_mono_ns,
        )


# =============================================================================
# §2 — MetricsSink: THE user-extension trait. Conform to it, plug it in.
# =============================================================================


trait MetricsSink(Movable, Deinitable):
    """A destination for per-request metrics. Conform to this and hand your
    conformer to `MetricsMiddleware` — that is the whole extension story.

        struct MySink(MetricsSink, Movable, Deinitable):
            def record(mut self, ref m: RequestMetric) raises:
                ...                       # statsd, OTLP, a file, anything

        var mw = MetricsMiddleware[MySink].new(MySink())

    CONTRACT:
      * `record` is called ONCE PER REQUEST, from the middleware's `after`
        phase, on the serve thread, BEFORE the response bytes are written.
        There is no background flush and no deferred queue — see
        `MetricsMiddleware.after` for why that is deliberate and not an
        oversight.
      * `record` MAY raise. The middleware catches it. A sink that throws
        never fails the customer's request — a metrics pipeline is not
        allowed to take down the thing it is measuring. What a raise COSTS
        is one lost observation, and nothing else.
      * `record` SHOULD be fast. Whatever it does is on the request's
        critical path by construction (see above); a sink that blocks for a
        second adds a second to every response.
    """

    def record(mut self, ref m: RequestMetric) raises:
        """Consume one request's observation."""
        ...


# =============================================================================
# §3 — Built-in conformers.
# =============================================================================


struct NullSink(MetricsSink, Movable, Deinitable):
    """Discards everything. The default, and the honest one: a middleware
    constructed with no sink does nothing rather than quietly buffering into
    memory nobody reads."""

    def __init__(out self):
        pass

    def record(mut self, ref m: RequestMetric) raises:
        _ = m.start_mono_ns


struct CapturingSink(MetricsSink, Movable, Deinitable):
    """Holds observations in memory, oldest-first, for readback.

    A PRODUCT SURFACE, not a test fixture — a customer exposing their own
    `/metrics` handler reads it exactly the way a test does. It is UNBOUNDED on
    purpose: bounding it would mean choosing a drop policy on a customer's
    behalf inside a library they cannot patch. Use it where something drains
    it; for a long-lived server that drains nothing, write a sink that
    forwards.
    """

    var _entries: List[RequestMetric]

    def __init__(out self):
        self._entries = List[RequestMetric]()

    def record(mut self, ref m: RequestMetric) raises:
        self._entries.append(
            RequestMetric(
                entry=m.entry,
                start_mono_ns=m.start_mono_ns,
                end_mono_ns=m.end_mono_ns,
            )
        )

    def len(self) -> Int:
        return len(self._entries)

    def at(self, idx: Int) raises -> RequestMetric:
        if idx < 0 or idx >= len(self._entries):
            raise Error(
                String("CapturingSink.at: index out of range: ")
                + String(idx)
            )
        return self._entries[idx]

    def clear(mut self):
        self._entries = List[RequestMetric]()


# =============================================================================
# §4 — MetricsMiddleware: the seam itself.
# =============================================================================


struct MetricsMiddleware[S: MetricsSink](Middleware, Movable, Deinitable):
    """Observes every request and hands it to the configured sink.

    ⭐ THE SINK IS A CONSTRUCTOR PARAMETER, NEVER AN AMBIENT ENV READ. This is
    the library form of a standing rule: a
    binary's configuration is stated at startup where it can be REFUSED, not
    discovered at the moment a line executes, where absent and configured-empty
    are the same bytes. Nothing in this file calls `getenv`.

        var mw = MetricsMiddleware[CapturingSink].new(CapturingSink())
        var off = MetricsMiddleware[NullSink].disabled(NullSink())

    PLACEMENT: this is a `Middleware`, so it goes in the chain's one user slot
    (`MiddlewareChain.run_before_legs` / `run_after_legs`). Where that slot is
    already occupied — every production app fills it with its auth middleware —
    compose the two with `PairMiddleware`, METRICS OUTER:

        PairMiddleware[MetricsMiddleware[MySink], MyAuthMw]

    Metrics outer is not a style preference. An inner metrics middleware is
    SKIPPED whenever auth short-circuits, so every 401 would go unmetered —
    and a rejected request still burned the instance's CPU.
    """

    var _sink: Self.S
    var _enabled: Bool

    def __init__(out self, var sink: Self.S, enabled: Bool):
        self._sink = sink^
        self._enabled = enabled

    @staticmethod
    def new(var sink: Self.S) -> MetricsMiddleware[Self.S]:
        """Enabled, writing to `sink`."""
        return MetricsMiddleware[Self.S](sink^, True)

    @staticmethod
    def disabled(var sink: Self.S) -> MetricsMiddleware[Self.S]:
        """Inert: no timestamps stamped, no `record` calls. The sink is still
        owned (so a caller can read back whatever it held) but never written."""
        return MetricsMiddleware[Self.S](sink^, False)

    def before(
        mut self,
        mut req: HttpRequest,
        mut ctx: RequestContext,
    ) raises -> Optional[HttpResponse]:
        """Stamp the request's START endpoint onto the per-request context.

        NEVER short-circuits — a metrics middleware that could reject a request
        is a metrics middleware that can take a customer's site down.

        ⚠ IT WRITES `ctx.start_ns` ONLY IF IT IS STILL ZERO. `LoggingMiddleware`
        is an OUTER leg of the standard chain and normally stamps it first; this
        middleware must then report the SAME start the log line reports, not a
        later one taken further in. Where logging is disabled (or this
        middleware runs without the chain at all) the field is still 0 here and
        this is the stamp that lands. Either way exactly one start exists per
        request and it is the earliest one observed.
        """
        _ = req
        if not self._enabled:
            return Optional[HttpResponse]()
        if ctx.start_ns == UInt64(0):
            ctx.start_ns = _now_ns()
        return Optional[HttpResponse]()

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        """Take the END endpoint and hand both endpoints to the sink — INLINE,
        on this thread, before the caller writes the response.

        ⛔ DO NOT MAKE THIS DEFERRED, BUFFERED, OR TIMER-DRIVEN. On a serverless
        platform the CPU is withdrawn the instant the response completes and the
        instance may never be woken again: there is no guaranteed next request
        to carry a buffered observation out, and a background timer does not
        tick. A periodic server tick on such a platform logs in bursts and
        then not at all for hours. Anything not sent here is not sent.
        (The ONE platform where a post-response window genuinely exists is AWS
        Lambda, whose runtime returns the result and only then polls for the
        next invoke — `komira_aws_lambda_http/pump.mojo`'s
        `LambdaPostResponseFlush`. A Lambda-shaped sink belongs THERE, behind
        this same `MetricsSink` trait; it is not this middleware's business.)

        FAILURE POLICY — STATED, AND ASSERTED BY TEST: a raising sink is
        SWALLOWED. The cost is ONE LOST OBSERVATION and nothing else — bounded
        to the single request, never compounding, and for a metering sink it
        under-reports, i.e. it errs in the customer's favour and never in ours.
        The alternative — letting it propagate — converts a metrics outage into
        a 500 for a request that had already succeeded.
        """
        if not self._enabled:
            return
        var end_mono_ns = _now_ns()
        var start_mono_ns = ctx.start_ns
        # `latency_ns` is the CUSTOMER-FACING scalar and is computed exactly as
        # `LoggingMiddleware.after` computes it, so a customer switching from
        # the log buffer to their own writer sees the same number. It is NOT
        # the metering quantity; the endpoints above are. A metering sink must
        # ignore it (see `RequestMetric`).
        var latency_ns = UInt64(0)
        if start_mono_ns > UInt64(0) and end_mono_ns >= start_mono_ns:
            latency_ns = end_mono_ns - start_mono_ns
        var entry = LogEntry(
            method=req.method,
            path=String(req.path),
            status=resp.status,
            latency_ns=latency_ns,
            span_id=ctx.span_id,
            short_circuit=ctx.short_circuit,
        )
        var metric = RequestMetric(
            entry=entry^,
            start_mono_ns=start_mono_ns,
            end_mono_ns=end_mono_ns,
        )
        try:
            self._sink.record(metric)
        except e:
            # Deliberately terminal. See the failure policy above.
            _ = e

    def sink_ref(ref self) -> ref [self._sink] Self.S:
        """Borrow the configured sink for readback (a customer's `/metrics`
        handler; a test's assertions)."""
        return self._sink

    def sink_mut(mut self) -> ref [self._sink] Self.S:
        """Mutably borrow the configured sink (to drain it)."""
        return self._sink

    def enabled(self) -> Bool:
        return self._enabled


# =============================================================================
# §5 — PairMiddleware: compose two conformers into the chain's ONE user slot.
# =============================================================================


struct PairMiddleware[A: Middleware, B: Middleware](
    Middleware, Movable, Deinitable
):
    """Runs `A` OUTSIDE `B`: `A.before -> B.before -> ... -> B.after -> A.after`.

    WHY IT EXISTS. `MiddlewareChain` holds its four builtins as concrete fields
    and exposes exactly ONE parametric slot for a user conformer — which every
    production app already fills with its auth middleware. Without a composer, a
    second user middleware could only be added by editing `chain.mojo` and every
    app's chain-construction site. This type makes it one type name and one
    constructor argument instead:

        chain.run_before_legs[PairMiddleware[MetricsMiddleware[MySink], MyAuth]](
            req, ctx, paired, before_ran
        )

    SHORT-CIRCUIT SEMANTICS, mirroring the chain's own: if `A.before` returns a
    response, `B.before` never runs and `B.after` is therefore skipped — the
    same symmetric pairing `MiddlewareChain` enforces with `user_before_ran`.
    `A.after` always runs.

    ⚠ IT HOLDS ONE BIT OF PER-REQUEST STATE (`_b_before_ran`), so ONE INSTANCE
    SERVES ONE SERVE LOOP AT A TIME — which is exactly how the chain's user slot
    is already used (`serve_one_iteration_dispatch_chained` takes one `mut
    user_mw` per loop, and each worker builds its own). It is NOT safe to share
    one instance across threads. The chain keeps the equivalent bit as a caller
    local because it can; the `Middleware` trait has no out-parameter, so this
    composer cannot.
    """

    var _a: Self.A
    var _b: Self.B
    var _b_before_ran: Bool

    def __init__(out self, var a: Self.A, var b: Self.B):
        self._a = a^
        self._b = b^
        self._b_before_ran = False

    @staticmethod
    def of(var a: Self.A, var b: Self.B) -> PairMiddleware[Self.A, Self.B]:
        return PairMiddleware[Self.A, Self.B](a^, b^)

    def before(
        mut self,
        mut req: HttpRequest,
        mut ctx: RequestContext,
    ) raises -> Optional[HttpResponse]:
        self._b_before_ran = False
        var ra = self._a.before(req, ctx)
        if ra:
            ctx.short_circuit = True
            return ra^
        self._b_before_ran = True
        var rb = self._b.before(req, ctx)
        if rb:
            ctx.short_circuit = True
            return rb^
        return Optional[HttpResponse]()

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        if self._b_before_ran:
            self._b.after(req, resp, ctx)
        self._a.after(req, resp, ctx)

    def outer_ref(ref self) -> ref [self._a] Self.A:
        return self._a

    def outer_mut(mut self) -> ref [self._a] Self.A:
        return self._a

    def inner_ref(ref self) -> ref [self._b] Self.B:
        return self._b
