# =============================================================================
# src/komira_http_server/tests/test_L3_metrics_sink.mojo
#   The configurable metrics-writer seam: MetricsMiddleware and MetricsSink.
# =============================================================================
#
# WHAT THIS FILE IS DEFENDING, in the order that matters:
#
#  1. ★ TWO OVERLAPPING REQUESTS PRODUCE TWO DISTINCT INTERVALS. The billable
#     quantity is the UNION of the request intervals on an instance, and a
#     union is computable only from intervals. This is the client half of that:
#     the payload must carry two ENDPOINTS per request and must not collapse
#     concurrent requests into one. A payload of per-request DURATIONS leaves
#     the server no choice but to SUM — which is identical to a union under
#     sequential traffic and overbills by the concurrency factor under load.
#     ⛔ A TEST THAT DOES NOT EXERCISE OVERLAPPING INTERVALS IS VACUOUS.
#  2. It fires on every request that reaches the chain's user slot — including
#     an inner short-circuit (401) and the error-mapper's 500.
#  3. The observation is complete BEFORE the response bytes are serialized, and
#     there is no background timer anywhere in the shipped source.
#  4. A sink that throws does not break the customer's request.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_http_core.codec.response_framing import serialize_response_framed
from komira_http_core.codec.types import (
    HTTP_METHOD_OPTIONS,
    HttpMethod,
    HttpRequest,
    HttpResponse,
)
from komira_http_server.middleware.chain import MiddlewareChain
from komira_http_server.middleware.metrics import (
    CapturingSink,
    MetricsMiddleware,
    MetricsSink,
    NullSink,
    PairMiddleware,
    RequestMetric,
)
from komira_http_server.middleware.middleware import Middleware, RequestContext
from komira_clock import now_ns as _now_ns


# =============================================================================
# Fixtures.
# =============================================================================

comptime _METRICS_SRC: String = (
    "src/komira_http_server/middleware/metrics.mojo"
)


def _req(method: HttpMethod, path: String) -> HttpRequest:
    return HttpRequest(method, path)


def _preflight(path: String) -> HttpRequest:
    var r = HttpRequest(HttpMethod(code=HTTP_METHOD_OPTIONS), path)
    r.headers[String("origin")] = String("https://example.test")
    r.headers[String("access-control-request-method")] = String("POST")
    return r^


def _spin_ns(min_delta: UInt64):
    """Busy-wait until the monotonic clock has advanced by at least
    `min_delta` ns.

    ⚠ NOT A SLEEP, AND NOT COSMETIC. The interval assertions below are STRICT
    (`a.start < b.start`, `sum > union`), and a coarse monotonic clock can
    return the same reading from two adjacent calls — which would make the
    strict comparisons flaky rather than wrong. Spinning makes the endpoints
    genuinely distinct so the inequalities mean what they say."""
    var t0 = _now_ns()
    while _now_ns() - t0 < min_delta:
        pass


struct DenyPathMiddleware(Middleware, Movable, Deinitable):
    """A minimal stand-in for an app's auth middleware: 401s one path, passes
    everything else. It occupies the INNER half of the `PairMiddleware`, which
    is where every production app's real auth middleware sits."""

    var _deny_path: String

    def __init__(out self, var deny_path: String):
        self._deny_path = deny_path^

    def before(
        mut self,
        mut req: HttpRequest,
        mut ctx: RequestContext,
    ) raises -> Optional[HttpResponse]:
        _ = ctx
        if String(req.path) == self._deny_path:
            return Optional[HttpResponse](HttpResponse(status=Int32(401)))
        return Optional[HttpResponse]()

    def after(
        mut self,
        ref req: HttpRequest,
        mut resp: HttpResponse,
        ref ctx: RequestContext,
    ) raises:
        _ = req
        _ = resp
        _ = ctx


struct ExplodingSink(MetricsSink, Movable, Deinitable):
    """A user-supplied sink that fails on every request. The point of the test
    it serves is that a customer whose metrics backend is down still serves
    traffic."""

    var calls: Int

    def __init__(out self):
        self.calls = 0

    def record(mut self, ref m: RequestMetric) raises:
        self.calls = self.calls + 1
        _ = m.start_mono_ns
        raise Error("ExplodingSink: the metrics backend is down")


# =============================================================================
# T1 — ★ THE ONE THAT MATTERS. Overlapping requests -> two distinct intervals.
# =============================================================================


def test_overlapping_requests_yield_two_unionable_intervals() raises:
    """Two requests whose lifecycles INTERLEAVE — before(A), before(B),
    after(B), after(A) — produce TWO metrics carrying TWO SEPARATE endpoints
    each, with A's interval strictly containing B's.

    ⛔ THIS IS THE ANTI-SUM ASSERTION. Assertion (4) states the very inequality
    that makes a sum a bug: the two durations SUM to strictly more than their
    UNION. Under the canonical case — 80 fully-overlapping one-second requests —
    this payload lets the server land on 1 instance-second; a payload carrying
    only `latency_ns` could only ever yield 80.

    MUTATION THAT REDS IT (design error A): carry the start on the MIDDLEWARE
    INSTANCE (`self._start_ns`) instead of on the per-request `RequestContext`.
    B's `before` then overwrites A's start, A's interval collapses onto B's,
    and assertion (3) fails.

    MUTATION THAT REDS IT (design error B, the silent overbill): give
    `RequestMetric` a single `latency_ns` instead of two endpoints. Assertions
    (2), (3) and (4) become unwriteable — the file stops compiling, which is
    the demonstration that a duration-only payload forecloses the union."""
    print("  test_overlapping_requests_yield_two_unionable_intervals...")
    var mw = MetricsMiddleware[CapturingSink].new(CapturingSink())

    # Two requests, each with its OWN context — exactly as the chain threads
    # one RequestContext per request.
    var req_a = _req(HttpMethod.get(), String("/a"))
    var req_b = _req(HttpMethod.get(), String("/b"))
    var ctx_a = RequestContext.new()
    var ctx_b = RequestContext.new()

    _ = mw.before(req_a, ctx_a)
    _spin_ns(UInt64(2_000))
    _ = mw.before(req_b, ctx_b)
    _spin_ns(UInt64(2_000))
    var resp_b = HttpResponse(status=Int32(200))
    mw.after(req_b, resp_b, ctx_b)  # B finishes INSIDE A.
    _spin_ns(UInt64(2_000))
    var resp_a = HttpResponse(status=Int32(200))
    mw.after(req_a, resp_a, ctx_a)

    ref sink = mw.sink_ref()
    # (1) TWO metrics, not one and not a merged one.
    assert_equal(
        sink.len(),
        2,
        "two concurrent requests must produce TWO metrics; one means the"
        " middleware collapsed them (per-instance state instead of per-ctx)",
    )
    var b = sink.at(0)  # B recorded first (it finished first).
    var a = sink.at(1)
    assert_equal(a.entry.path, String("/a"), "second record is request A")
    assert_equal(b.entry.path, String("/b"), "first record is request B")

    # (2) Each carries TWO endpoints, as separate fields — an INTERVAL, never
    #     a scalar.
    assert_true(a.start_mono_ns > UInt64(0), "A carries a start endpoint")
    assert_true(a.end_mono_ns > UInt64(0), "A carries an end endpoint")
    assert_true(b.start_mono_ns > UInt64(0), "B carries a start endpoint")
    assert_true(b.end_mono_ns > UInt64(0), "B carries an end endpoint")

    # (3) The intervals genuinely OVERLAP: A was in flight for the whole of B.
    assert_true(
        a.start_mono_ns < b.start_mono_ns,
        "A must start strictly before B — if these are equal the middleware is"
        " stamping one shared start, not a per-request one",
    )
    assert_true(
        b.end_mono_ns < a.end_mono_ns, "B must end strictly before A ends"
    )
    assert_true(
        a.start_mono_ns < b.end_mono_ns,
        "the intervals must OVERLAP — otherwise this test is exercising"
        " sequential traffic and proves nothing about the union",
    )

    # (4) ⛔ SUM > UNION. The inequality that makes a sum a bug.
    var dur_a = a.end_mono_ns - a.start_mono_ns
    var dur_b = b.end_mono_ns - b.start_mono_ns
    var sum_of_durations = dur_a + dur_b
    var union_start = a.start_mono_ns
    if b.start_mono_ns < union_start:
        union_start = b.start_mono_ns
    var union_end = a.end_mono_ns
    if b.end_mono_ns > union_end:
        union_end = b.end_mono_ns
    var union_span = union_end - union_start
    assert_true(
        sum_of_durations > union_span,
        "the SUM of the two durations must exceed their UNION — this payload"
        " is what lets the server bill the smaller, correct number",
    )
    assert_equal(
        Int(union_span),
        Int(dur_a),
        "A contains B, so the union is exactly A's own interval",
    )
    print(
        "    OK — sum", Int(sum_of_durations), "ns >", Int(union_span),
        "ns union",
    )


# =============================================================================
# T2 — it fires on every request that reaches the chain's user slot.
# =============================================================================


def _drive(
    mut chain: MiddlewareChain,
    mut paired: PairMiddleware[
        MetricsMiddleware[CapturingSink], DenyPathMiddleware
    ],
    mut req: HttpRequest,
    raise_in_dispatcher: Bool,
) raises -> HttpResponse:
    """Drive one request through the REAL chain, mirroring
    `transport/dispatch.mojo:_drive_chain_dispatch` exactly: before-legs,
    then a stand-in dispatcher, then the after-legs — with the error path
    going through `map_chain_error` the same way."""
    var ctx = RequestContext.new()
    var user_before_ran = False
    var response: HttpResponse
    try:
        var sc = chain.run_before_legs[
            PairMiddleware[MetricsMiddleware[CapturingSink], DenyPathMiddleware]
        ](req, ctx, paired, user_before_ran)
        if sc:
            response = sc.take()
        else:
            if raise_in_dispatcher:
                raise Error("stand-in dispatcher exploded")
            response = HttpResponse.ok(String("hi"))
        chain.run_after_legs[
            PairMiddleware[MetricsMiddleware[CapturingSink], DenyPathMiddleware]
        ](req, response, ctx, paired, user_before_ran)
    except e:
        response = chain.map_chain_error(
            e, String(req.method.name()), String(req.path), String("")
        )
        ctx.short_circuit = True
        chain.run_after_legs[
            PairMiddleware[MetricsMiddleware[CapturingSink], DenyPathMiddleware]
        ](req, response, ctx, paired, user_before_ran)
    return response^


def test_fires_on_every_request_reaching_the_user_slot() raises:
    """Four requests of four different SHAPES through the real chain — a plain
    200, a second 200, an inner-auth 401 short-circuit, and a dispatcher raise
    mapped to a 500 — produce FOUR metrics from ONE sink.

    MUTATION THAT REDS IT: guard `record` with `if resp.status < 400` in
    `MetricsMiddleware.after` — 2 of 4, red. That is the shape a naive hook
    takes, and it silently stops metering exactly the requests an operator most
    wants counted."""
    print("  test_fires_on_every_request_reaching_the_user_slot...")
    var chain = MiddlewareChain.default()
    var paired = PairMiddleware[
        MetricsMiddleware[CapturingSink], DenyPathMiddleware
    ].of(
        MetricsMiddleware[CapturingSink].new(CapturingSink()),
        DenyPathMiddleware(String("/denied")),
    )

    var r1 = _req(HttpMethod.get(), String("/a"))
    var resp1 = _drive(chain, paired, r1, False)
    assert_equal(Int(resp1.status), 200, "plain request is 200")

    var r2 = _req(HttpMethod.post(), String("/b"))
    var resp2 = _drive(chain, paired, r2, False)
    assert_equal(Int(resp2.status), 200, "second plain request is 200")

    var r3 = _req(HttpMethod.get(), String("/denied"))
    var resp3 = _drive(chain, paired, r3, False)
    assert_equal(Int(resp3.status), 401, "inner auth short-circuited")

    var r4 = _req(HttpMethod.get(), String("/boom"))
    var resp4 = _drive(chain, paired, r4, True)
    assert_equal(Int(resp4.status), 500, "dispatcher raise mapped to 500")

    ref mm = paired.outer_ref()
    ref sink = mm.sink_ref()
    assert_equal(
        sink.len(),
        4,
        "every request reaching the user slot must be metered: 2 x 200 + a 401"
        " short-circuit + a 500 from the error mapper",
    )
    assert_equal(Int(sink.at(2).entry.status), 401, "the 401 was metered")
    assert_true(
        sink.at(2).entry.short_circuit,
        "the 401 is marked short_circuit — it never reached a handler",
    )
    assert_equal(Int(sink.at(3).entry.status), 500, "the 500 was metered")
    for i in range(4):
        var m = sink.at(i)
        assert_true(
            m.end_mono_ns >= m.start_mono_ns and m.start_mono_ns > UInt64(0),
            "every metered request carries a well-ordered interval",
        )
    print("    OK — 4 shapes, 4 metrics")


def test_cors_preflight_does_not_reach_the_user_slot() raises:
    """⚠ A KNOWN GAP, ASSERTED SO IT CANNOT BE FORGOTTEN — NOT A BLESSING.

    `MiddlewareChain.run_before_legs` runs CORS OUTSIDE the user slot, and a
    CORS-preflight short-circuit returns before `user_before_ran` is set — so
    `run_after_legs` skips the user slot's `after` entirely. A preflight
    therefore goes UNMETERED even though it consumed the instance's CPU.

    Closing it means changing `chain.mojo` (running the user `after`
    unconditionally, or making metrics a chain builtin), which is outside this
    change's ownership. This assertion pins the CURRENT behaviour so that
    whoever closes it is REQUIRED to come back and update this test — red on
    good news, the same ratchet shape the known-failing ledger uses."""
    print("  test_cors_preflight_does_not_reach_the_user_slot...")
    var chain = MiddlewareChain.default()
    var paired = PairMiddleware[
        MetricsMiddleware[CapturingSink], DenyPathMiddleware
    ].of(
        MetricsMiddleware[CapturingSink].new(CapturingSink()),
        DenyPathMiddleware(String("/denied")),
    )
    var r = _preflight(String("/c"))
    var resp = _drive(chain, paired, r, False)
    assert_equal(Int(resp.status), 204, "CORS answered the preflight")
    ref mm = paired.outer_ref()
    ref sink = mm.sink_ref()
    assert_equal(
        sink.len(),
        0,
        "KNOWN GAP: a CORS preflight short-circuits OUTSIDE the chain's user"
        " slot, so it is not metered. If this is now 1, the chain was fixed —"
        " delete this test and fold the preflight into the T2 count.",
    )
    print("    OK — gap pinned (preflight unmetered, by chain shape)")


# =============================================================================
# T3 — complete before the response is serialized; no background timer.
# =============================================================================


def test_record_completes_before_response_is_serialized() raises:
    """The metric is in the sink the instant `run_after_legs` returns — i.e.
    BEFORE the caller serializes a single response byte.

    This is the ordering `transport/dispatch.mojo` has: `_drive_chain_dispatch`
    returns only after `run_after_legs`, and `serialize_response_framed` +
    `_write_all_or_buffer` run after that. On a serverless platform it is the
    only ordering that works — the CPU is withdrawn when the response
    completes.

    MUTATION THAT REDS IT: buffer the metric in `after` and flush it on the
    NEXT request's `before`. `sink.len()` is 0 at the assertion below — which
    is the Cloud-Run-CPU-withdrawn bug, caught in a unit test."""
    print("  test_record_completes_before_response_is_serialized...")
    var chain = MiddlewareChain.default()
    var paired = PairMiddleware[
        MetricsMiddleware[CapturingSink], DenyPathMiddleware
    ].of(
        MetricsMiddleware[CapturingSink].new(CapturingSink()),
        DenyPathMiddleware(String("/denied")),
    )
    var r = _req(HttpMethod.get(), String("/ordering"))
    var resp = _drive(chain, paired, r, False)

    # THE ORDERING ASSERTION — the sink is already populated, and not one
    # response byte has been produced yet.
    ref mm = paired.outer_ref()
    ref sink = mm.sink_ref()
    assert_equal(
        sink.len(),
        1,
        "the observation must be COMPLETE when the after-phase returns; a"
        " deferred / buffered / timer-driven send is never delivered on a"
        " serverless instance whose CPU is withdrawn at response completion",
    )
    var wire = List[UInt8]()
    serialize_response_framed(resp, False, wire)
    assert_true(len(wire) > 0, "the response serializes after the fact")
    print("    OK — metric landed before", len(wire), "response bytes existed")


def _code_lines(text: String) -> List[String]:
    """`text` with docstrings and comments removed, so a structural search
    reads CODE and not the prose that talks ABOUT the code. (This file's own
    banners discuss background timers at length; a naive grep would match
    them.)"""
    var out = List[String]()
    var rows = text.split(String("\n"))
    var in_doc = False
    for i in range(len(rows)):
        var raw = String(rows[i])
        var triples = 0
        var bs = raw.as_bytes()
        var k = 0
        while k + 2 < len(bs):
            if (
                bs[k] == UInt8(ord('"'))
                and bs[k + 1] == UInt8(ord('"'))
                and bs[k + 2] == UInt8(ord('"'))
            ):
                triples = triples + 1
                k = k + 3
            else:
                k = k + 1
        if in_doc:
            if triples > 0 and triples % 2 == 1:
                in_doc = False
            continue
        if triples > 0:
            if triples % 2 == 1:
                in_doc = True
            continue
        var hash_at = raw.find(String("#"))
        if hash_at >= 0:
            out.append(String(raw[byte=0:hash_at]))
        else:
            out.append(raw)
    return out^


def _joined_code(path: String) raises -> String:
    with open(path, "r") as f:
        var lines = _code_lines(f.read())
        var joined = String()
        for i in range(len(lines)):
            joined += lines[i]
            joined += String("\n")
        return joined^


def test_shipped_source_has_no_deferred_send_machinery() raises:
    """STRUCTURAL: the shipped source contains no spawn / thread / sleep /
    timer machinery. The send is inline or it does not happen.

    The reader strips docstrings and comments first — the file DISCUSSES
    background timers at length in its banner, and a gate that matched prose
    would be green for the wrong reason. It also asserts it found a non-trivial
    amount of code, because "found nothing to look at" must never read as
    "found nothing wrong"."""
    print("  test_shipped_source_has_no_deferred_send_machinery...")
    var forbidden = List[String]()
    forbidden.append(String("spawn"))
    forbidden.append(String("pthread"))
    forbidden.append(String("sleep"))
    forbidden.append(String("Timer"))
    forbidden.append(String("set_interval"))

    var srcs = List[String]()
    srcs.append(String(_METRICS_SRC))
    for s in range(len(srcs)):
        var code = _joined_code(srcs[s])
        assert_true(
            code.byte_length() > 1500,
            String("the source reader found almost no CODE in ")
            + srcs[s]
            + String(
                " — an empty read satisfies every negative assertion below"
            ),
        )
        for f in range(len(forbidden)):
            assert_true(
                code.find(forbidden[f]) < 0,
                String("`")
                + forbidden[f]
                + String("` appears in the CODE of ")
                + srcs[s]
                + String(
                    ". The send must be inline: a serverless instance's CPU is"
                    " withdrawn at response completion and a background timer"
                    " never ticks."
                ),
            )
    # POSITIVE half, so the gate cannot pass by reading nothing: the inline
    # call site must be present.
    var metrics_code = _joined_code(String(_METRICS_SRC))
    assert_true(
        metrics_code.find(String("self._sink.record(")) >= 0,
        "MetricsMiddleware must call the sink INLINE in its after phase",
    )
    print("    OK — 1 source, 5 forbidden tokens, inline call site present")


# =============================================================================
# T4 — a throwing sink does not break the customer's request.
# =============================================================================


def test_throwing_sink_does_not_break_the_request() raises:
    """A user-supplied sink that raises on every request costs ONE LOST
    OBSERVATION and nothing else: the response is still 200 and byte-identical
    to the same request served with an inert sink.

    MUTATION THAT REDS IT: delete the `try/except` around `self._sink.record`
    in `MetricsMiddleware.after`. The raise escapes into the driver's
    error-mapper and the customer gets a 500 for a request that had already
    succeeded."""
    print("  test_throwing_sink_does_not_break_the_request...")
    var mw = MetricsMiddleware[ExplodingSink].new(ExplodingSink())
    var req = _req(HttpMethod.get(), String("/still-works"))
    var ctx = RequestContext.new()
    _ = mw.before(req, ctx)
    var resp = HttpResponse.ok(String("hi"))
    # THE ASSERTION: this does not raise.
    mw.after(req, resp, ctx)
    assert_equal(Int(resp.status), 200, "the response is untouched")

    ref exploded = mw.sink_ref()
    assert_equal(exploded.calls, 1, "the sink WAS called (and did throw)")

    # Byte-identical to the inert-sink run.
    var wire_throwing = List[UInt8]()
    serialize_response_framed(resp, False, wire_throwing)

    var mw2 = MetricsMiddleware[NullSink].new(NullSink())
    var req2 = _req(HttpMethod.get(), String("/still-works"))
    var ctx2 = RequestContext.new()
    _ = mw2.before(req2, ctx2)
    var resp2 = HttpResponse.ok(String("hi"))
    mw2.after(req2, resp2, ctx2)
    var wire_inert = List[UInt8]()
    serialize_response_framed(resp2, False, wire_inert)

    assert_equal(
        len(wire_throwing),
        len(wire_inert),
        "a failing metrics sink must not change one byte of the response",
    )
    for i in range(len(wire_inert)):
        assert_equal(
            Int(wire_throwing[i]),
            Int(wire_inert[i]),
            "response byte differs between throwing-sink and inert-sink runs",
        )
    print("    OK — request survived a sink that throws every time")


def main() raises:
    print("test_L3_metrics_sink:")
    test_overlapping_requests_yield_two_unionable_intervals()
    test_fires_on_every_request_reaching_the_user_slot()
    test_cors_preflight_does_not_reach_the_user_slot()
    test_record_completes_before_response_is_serialized()
    test_shipped_source_has_no_deferred_send_machinery()
    test_throwing_sink_does_not_break_the_request()
    print("test_L3_metrics_sink: OK")
