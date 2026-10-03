# =============================================================================
# src/komira_http/tests/test_L3_metrics_sink_and_status_hook.mojo
#   The configurable metrics-writer seam + the job-manager status hook.
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
#  5. The hook posts both endpoints, no duration, and swallows every transport
#     failure.
#  6. The config REFUSES rather than defaulting.
#  7. A credential that cannot mint sends NOTHING (fail closed) and the request
#     still succeeds.
# =============================================================================

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_raises, assert_true

from komira_async.ops.waker_sink import NoopSink

from komira_http.client.header_map import HeaderEntry
from komira_http.codec.response_framing import serialize_response_framed
from komira_http.codec.types import (
    HTTP_METHOD_OPTIONS,
    HttpMethod,
    HttpRequest,
    HttpResponse,
)
from komira_http.middleware.chain import MiddlewareChain
from komira_http.middleware.logging import LogEntry
from komira_http.middleware.metrics import (
    CapturingSink,
    MetricsMiddleware,
    MetricsSink,
    NullSink,
    PairMiddleware,
    RequestMetric,
)
from komira_http.middleware.middleware import Middleware, RequestContext
from komira_http.middleware.status_hook import (
    HookCredential,
    NoCredential,
    StatusHookConfig,
    StatusHookSink,
    USAGE_PATH,
    render_usage_body,
)
from komira_http.transport.scripted import ScriptedConnector, ScriptedStream
from komira_clock import now_ns as _now_ns


# =============================================================================
# Fixtures.
# =============================================================================

comptime _METRICS_SRC: String = (
    "src/komira_http/middleware/metrics.mojo"
)
comptime _HOOK_SRC: String = (
    "src/komira_http/middleware/status_hook.mojo"
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


def _metric(start_ns: UInt64, end_ns: UInt64, path: String) -> RequestMetric:
    return RequestMetric(
        entry=LogEntry(
            method=HttpMethod.get(),
            path=String(path),
            status=Int32(200),
            latency_ns=UInt64(999_999),
            span_id=UInt64(7),
            short_circuit=False,
        ),
        start_mono_ns=start_ns,
        end_mono_ns=end_ns,
    )


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


struct FixedCredential(HookCredential, Movable, Deinitable):
    """Returns one canned header, and records what it was asked to sign."""

    var seen_scheme: String
    var seen_host: String
    var seen_port: UInt16
    var seen_method: String
    var seen_path: String
    var seen_body_len: Int

    def __init__(out self):
        self.seen_scheme = String()
        self.seen_host = String()
        self.seen_port = UInt16(0)
        self.seen_method = String()
        self.seen_path = String()
        self.seen_body_len = -1

    def headers(
        mut self,
        scheme: String,
        host: String,
        port: UInt16,
        method: String,
        path: String,
        body: List[UInt8],
    ) raises -> List[HeaderEntry]:
        self.seen_scheme = String(scheme)
        self.seen_host = String(host)
        self.seen_port = port
        self.seen_method = String(method)
        self.seen_path = String(path)
        self.seen_body_len = len(body)
        var out = List[HeaderEntry]()
        out.append(
            HeaderEntry(
                name=String("authorization"),
                value=String("Bearer test-hook-token"),
            )
        )
        return out^


struct UnmintableCredential(HookCredential, Movable, Deinitable):
    """A credential that cannot mint. It RAISES — it does not return an empty
    header list — which is what makes "this image cannot authenticate"
    distinguishable from "the network blipped"."""

    def __init__(out self):
        pass

    def headers(
        mut self,
        scheme: String,
        host: String,
        port: UInt16,
        method: String,
        path: String,
        body: List[UInt8],
    ) raises -> List[HeaderEntry]:
        _ = scheme
        _ = host
        _ = port
        _ = method
        _ = path
        _ = len(body)
        raise Error("metadata identity endpoint unreachable")


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def _canned_200() -> List[UInt8]:
    return _b(String("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"))


def _contains(hay: List[UInt8], needle: String) -> Bool:
    var nb = needle.as_bytes()
    var n = len(nb)
    if n == 0:
        return True
    if len(hay) < n:
        return False
    for i in range(len(hay) - n + 1):
        var ok = True
        for j in range(n):
            if hay[i + j] != nb[j]:
                ok = False
                break
        if ok:
            return True
    return False


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
    """STRUCTURAL: neither shipped source contains spawn / thread / sleep /
    timer machinery. The send is inline or it does not happen.

    The reader strips docstrings and comments first — both files DISCUSS
    background timers at length in their banners, and a gate that matched prose
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
    srcs.append(String(_HOOK_SRC))
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
    print("    OK — 2 sources, 5 forbidden tokens, inline call site present")


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


# =============================================================================
# T5 — the hook POSTs both endpoints, and no duration.
# =============================================================================


def test_status_hook_posts_two_endpoints_and_no_duration() raises:
    """The hook's wire body carries `start_mono_ns` AND `end_mono_ns` and the
    instance id — and carries NO accumulated, total, or duration field.

    The negative half is the falsifier for "the client started computing". If
    someone adds a duration, a running total or a vCPU number to this body, a
    number that the job manager must own has escaped into every deployed
    application."""
    print("  test_status_hook_posts_two_endpoints_and_no_duration...")
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var stream = ScriptedStream.from_read_script_with_capture(
        _canned_200(), capture
    )
    var connector = ScriptedConnector.with_stream(stream^)
    var cfg = StatusHookConfig.build(
        String("http://127.0.0.1:8080"), String("inst-abc-pid-7"), 250_000
    )
    var sink = StatusHookSink[ScriptedConnector, NoCredential].new(
        cfg^, connector^, NoCredential()
    )
    var m = _metric(UInt64(1_000_000), UInt64(4_000_000), String("/work"))
    sink.record(m)

    if sink.last_record_failed():
        print("    hook error:", sink.last_error())
    assert_false(
        sink.last_record_failed(), "the scripted 200 means the POST landed"
    )
    var wire = capture[].copy()
    assert_true(len(wire) > 0, "the hook actually wrote bytes")
    assert_true(
        _contains(wire, String("POST /internal/usage")),
        "the hook POSTs to the usage route",
    )
    assert_true(
        _contains(wire, String("inst-abc-pid-7")),
        "the instance id is on the wire — the server unions PER INSTANCE",
    )
    assert_true(
        _contains(wire, String('"start_mono_ns":1000000')),
        "the START endpoint is on the wire verbatim",
    )
    assert_true(
        _contains(wire, String('"end_mono_ns":4000000')),
        "the END endpoint is on the wire verbatim",
    )
    # ⛔ THE NEGATIVE HALF.
    var banned = List[String]()
    banned.append(String("latency"))
    banned.append(String("duration"))
    banned.append(String("elapsed"))
    banned.append(String("total"))
    banned.append(String("accumulat"))
    banned.append(String("vcpu"))
    banned.append(String("busy_seconds"))
    for i in range(len(banned)):
        assert_false(
            _contains(wire, banned[i]),
            String("the hook must compute NOTHING — `")
            + banned[i]
            + String(
                "` appeared on the wire. Every derived quantity belongs to the"
                " job manager, which is one deploy; this code is in customer"
                " binaries and cannot be corrected."
            ),
        )
    # The scalar duration exists on the metric and must NOT have been posted.
    assert_equal(
        Int(m.entry.latency_ns), 999_999, "the metric does carry latency_ns"
    )
    assert_false(
        _contains(wire, String("999999")),
        "`latency_ns` must never reach the metering wire — a scalar cannot be"
        " unioned, so posting it forces the server to sum",
    )
    print("    OK — two endpoints posted, zero derived quantities")


def test_status_hook_swallows_transport_failures() raises:
    """A refused dial and a dial that never resolves are both swallowed: the
    sink reports the failure on its own readback surface and `record` does not
    raise. A failed hook costs ONE LOST INTERVAL, which UNDER-reports usage —
    in the customer's favour, never in ours."""
    print("  test_status_hook_swallows_transport_failures...")
    var connector = ScriptedConnector.with_stream(
        ScriptedStream.from_read_script(_canned_200())
    )
    connector.arm_connect_error(Int64(111))  # ECONNREFUSED
    var cfg = StatusHookConfig.build(
        String("http://127.0.0.1:8080"), String("inst-1"), 250_000
    )
    var sink = StatusHookSink[ScriptedConnector, NoCredential].new(
        cfg^, connector^, NoCredential()
    )
    var m = _metric(UInt64(10), UInt64(20), String("/x"))
    sink.record(m)  # MUST NOT RAISE.
    assert_true(
        sink.last_record_failed(), "a refused dial is reported as a failure"
    )
    assert_true(
        sink.last_error().byte_length() > 0, "the failure carries a detail"
    )

    var connector2 = ScriptedConnector.with_stream(
        ScriptedStream.from_read_script(_canned_200())
    )
    connector2.arm_connect_never_resolves()
    var cfg2 = StatusHookConfig.build(
        String("http://127.0.0.1:8080"), String("inst-2"), 250_000
    )
    var sink2 = StatusHookSink[ScriptedConnector, NoCredential].new(
        cfg2^, connector2^, NoCredential()
    )
    sink2.record(m)  # MUST NOT RAISE.
    assert_true(
        sink2.last_record_failed(), "an unresolving dial is a failure too"
    )
    print("    OK — both dial faults swallowed, neither raised")


def test_a_failing_hook_still_serves_the_request() raises:
    """The end-to-end statement of the failure policy: a hook whose job manager
    is unreachable, installed in the real chain, still returns the customer's
    200."""
    print("  test_a_failing_hook_still_serves_the_request...")
    var connector = ScriptedConnector.with_stream(
        ScriptedStream.from_read_script(_canned_200())
    )
    connector.arm_connect_error(Int64(111))
    var cfg = StatusHookConfig.build(
        String("http://127.0.0.1:8080"), String("inst-3"), 250_000
    )
    var sink = StatusHookSink[ScriptedConnector, NoCredential].new(
        cfg^, connector^, NoCredential()
    )
    var mw = MetricsMiddleware[
        StatusHookSink[ScriptedConnector, NoCredential]
    ].new(sink^)
    var req = _req(HttpMethod.get(), String("/served"))
    var ctx = RequestContext.new()
    _ = mw.before(req, ctx)
    var resp = HttpResponse.ok(String("hi"))
    mw.after(req, resp, ctx)  # MUST NOT RAISE.
    assert_equal(
        Int(resp.status),
        200,
        "an unreachable job manager must never fail the customer's request",
    )
    ref s = mw.sink_ref()
    assert_true(s.last_record_failed(), "and the loss IS visible on readback")
    print("    OK — 200 served with the job manager unreachable")


# =============================================================================
# T6 — the config REFUSES rather than defaulting.
# =============================================================================


def test_config_refuses_rather_than_defaulting() raises:
    """Four refusals, each at CONSTRUCTION, naming the problem.

    MUTATION THAT REDS IT: default `timeout_us` to 0 instead of refusing. The
    fourth assertion goes red — and that mutation is exactly the wedged-job-manager hang,
    because this POST is synchronous on the serve thread."""
    print("  test_config_refuses_rather_than_defaulting...")
    with assert_raises():
        _ = StatusHookConfig.build(String(""), String("inst"), 1000)
    with assert_raises():
        _ = StatusHookConfig.build(String("not-a-url"), String("inst"), 1000)
    with assert_raises():
        _ = StatusHookConfig.build(
            String("http://127.0.0.1:8080"), String(""), 1000
        )
    with assert_raises():
        _ = StatusHookConfig.build(
            String("http://127.0.0.1:8080"), String("inst"), 0
        )
    with assert_raises():
        _ = StatusHookConfig.build(
            String("http://127.0.0.1:8080"), String("inst"), -1
        )

    # And the accepting case resolves what it should.
    var ok = StatusHookConfig.build(
        String("https://jm.example.test"), String("inst"), 250_000
    )
    assert_equal(ok.scheme, String("https"), "scheme parsed")
    assert_equal(ok.host, String("jm.example.test"), "host parsed")
    assert_equal(Int(ok.port), 443, "https default port resolved")
    assert_equal(
        ok.path, String(USAGE_PATH), "a path-less job-manager url gets the usage route"
    )
    var prefixed = StatusHookConfig.build(
        String("http://jm.example.test:9000/edge/usage"),
        String("inst"),
        250_000,
    )
    assert_equal(
        prefixed.path,
        String("/edge/usage"),
        "an explicit path is honoured verbatim, for prefix-routing proxies",
    )
    print("    OK — 5 refusals, 2 accepted shapes")


# =============================================================================
# T7 — the credential seam: headers on the wire; a mint failure sends NOTHING.
# =============================================================================


def test_credential_headers_reach_the_wire() raises:
    """A conformer's headers appear on the POST, and it is asked to sign the
    scheme / host / port / method / path / body the POST actually carries — the
    inputs an audience derivation (and, later, a SigV4 signature) needs."""
    print("  test_credential_headers_reach_the_wire...")
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var stream = ScriptedStream.from_read_script_with_capture(
        _canned_200(), capture
    )
    var connector = ScriptedConnector.with_stream(stream^)
    var cfg = StatusHookConfig.build(
        String("http://127.0.0.1:8080"), String("inst-9"), 250_000
    )
    var sink = StatusHookSink[ScriptedConnector, FixedCredential].new(
        cfg^, connector^, FixedCredential()
    )
    var m = _metric(UInt64(5), UInt64(9), String("/p"))
    sink.record(m)

    var wire = capture[].copy()
    assert_true(
        _contains(wire, String("Bearer test-hook-token")),
        "the credential's header must be on the wire",
    )
    ref cred = sink._cred
    assert_equal(cred.seen_scheme, String("http"), "scheme handed to minter")
    assert_equal(
        cred.seen_host, String("127.0.0.1"), "host handed to minter"
    )
    assert_equal(Int(cred.seen_port), 8080, "port handed to minter")
    assert_equal(cred.seen_method, String("POST"), "method handed to minter")
    assert_equal(
        cred.seen_path, String(USAGE_PATH), "path handed to minter"
    )
    assert_true(
        cred.seen_body_len > 0, "the body is handed to the minter for signing"
    )
    print("    OK — headers on the wire, six signing inputs delivered")


def test_unmintable_credential_sends_nothing_and_still_serves() raises:
    """⛔ FAIL CLOSED. A credential that cannot mint RAISES, and the hook writes
    ZERO bytes — there is no unauthenticated POST. The customer's request still
    succeeds.

    MUTATION THAT REDS IT: have the credential seam return an empty header list
    instead of raising, or move the credential call after the request is built
    and sent. Bytes then appear on the wire with no Authorization header, and
    the first assertion goes red."""
    print("  test_unmintable_credential_sends_nothing_and_still_serves...")
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var stream = ScriptedStream.from_read_script_with_capture(
        _canned_200(), capture
    )
    var connector = ScriptedConnector.with_stream(stream^)
    var cfg = StatusHookConfig.build(
        String("http://127.0.0.1:8080"), String("inst-10"), 250_000
    )
    var sink = StatusHookSink[ScriptedConnector, UnmintableCredential].new(
        cfg^, connector^, UnmintableCredential()
    )
    var mw = MetricsMiddleware[
        StatusHookSink[ScriptedConnector, UnmintableCredential]
    ].new(sink^)
    var req = _req(HttpMethod.get(), String("/served"))
    var ctx = RequestContext.new()
    _ = mw.before(req, ctx)
    var resp = HttpResponse.ok(String("hi"))
    mw.after(req, resp, ctx)

    assert_equal(
        len(capture[]),
        0,
        "a mint failure must send NOTHING — an unauthenticated POST would make"
        " 'this image cannot authenticate' look like 'the network blipped'",
    )
    assert_equal(
        Int(resp.status), 200, "and the customer's request still succeeds"
    )
    ref s = mw.sink_ref()
    assert_true(s.last_record_failed(), "the loss is visible on readback")
    print("    OK — zero bytes written, 200 served")


# =============================================================================
# Body renderer, directly.
# =============================================================================


def test_render_usage_body_escapes_and_carries_dimensions() raises:
    """The renderer emits valid JSON for a path containing a quote and a
    backslash, and carries the dimensions the server attributes on."""
    print("  test_render_usage_body_escapes_and_carries_dimensions...")
    var m = RequestMetric(
        entry=LogEntry(
            method=HttpMethod.post(),
            path=String('/a"b\\c'),
            status=Int32(503),
            latency_ns=UInt64(1),
            span_id=UInt64(2),
            short_circuit=True,
        ),
        start_mono_ns=UInt64(11),
        end_mono_ns=UInt64(22),
    )
    var body = render_usage_body(String('inst"1'), m)
    assert_true(
        _contains(body, String('"instance_id":"inst\\"1"')),
        "the instance id is JSON-escaped",
    )
    assert_true(
        _contains(body, String('"path":"/a\\"b\\\\c"')),
        "the path is JSON-escaped",
    )
    assert_true(_contains(body, String('"method":"POST"')), "method carried")
    assert_true(_contains(body, String('"status":503')), "status carried")
    assert_true(
        _contains(body, String('"short_circuit":true')),
        "short_circuit carried as a JSON bool",
    )
    assert_true(
        _contains(body, String('"start_mono_ns":11')), "start endpoint"
    )
    assert_true(_contains(body, String('"end_mono_ns":22')), "end endpoint")
    print("    OK — escaped, and six dimensions carried")


def main() raises:
    print("test_L3_metrics_sink_and_status_hook:")
    test_overlapping_requests_yield_two_unionable_intervals()
    test_fires_on_every_request_reaching_the_user_slot()
    test_cors_preflight_does_not_reach_the_user_slot()
    test_record_completes_before_response_is_serialized()
    test_shipped_source_has_no_deferred_send_machinery()
    test_throwing_sink_does_not_break_the_request()
    test_status_hook_posts_two_endpoints_and_no_duration()
    test_status_hook_swallows_transport_failures()
    test_a_failing_hook_still_serves_the_request()
    test_config_refuses_rather_than_defaulting()
    test_credential_headers_reach_the_wire()
    test_unmintable_credential_sends_nothing_and_still_serves()
    test_render_usage_body_escapes_and_carries_dimensions()
    print("test_L3_metrics_sink_and_status_hook: OK")
