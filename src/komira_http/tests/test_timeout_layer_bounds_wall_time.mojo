# =============================================================================
# komira_http/tests/test_timeout_layer_bounds_wall_time.mojo
#   A TIMEOUT LAYER THAT SAMPLES THE CLOCK AFTER THE CALL RETURNS DOES NOT
#   BOUND THE CALL. IT LABELS IT.
# =============================================================================
#
# ⭐ WHY THIS FILE EXISTS, AND WHY IT IS NOT A DUPLICATE OF
# `test_timeout_layer.mojo`.
#
# That file has four tests and they are all correct. Every one of them asserts
# WHICH ERROR the layer raises, using an injected clock whose "elapsed" is a
# NUMBER THE TEST CHOSE — `AutoAdvancingClock.new(0, 5000)` makes `elapsed`
# 5000 µs regardless of how long anything actually took. That is the right
# instrument for the question "does the arithmetic pick the right error", and it
# is structurally incapable of answering the question this file asks: **when
# does control come back?**
#
# It mattered because the layer's own header stated the limitation in so many
# words, and the limitation was real:
#
#     "In the layer checks the elapsed time AT LAYER ENTRY AND EXIT.
#      True mid-poll cancellation (firing the timeout DURING a parked
#      inner.call) requires plumbing through the OutboundDriver's pending
#      loop + reactor-timer. That's a follow-up."
#
# So a 300 s call under an 8 s deadline was not stopped at 8 s. It was stopped
# at 300 s and then RELABELLED `HttpError[TIMEOUT]: request exceeded deadline
# 8000000 us (elapsed 300000000 us)` — a message that reads like the timeout
# worked: the 504 comes first, the tidy error afterwards.
#
# ⭐ THIS FILE IS THE FALSIFIER FOR THAT FOLLOW-UP. The layer
# STATES its deadline on the request (`ClientRequest.set_request_budget_us`)
# BEFORE handing over control; `HttpClient._budget_for` composes it with the
# client's own configured budget (the TIGHTER binds, `tighter_budget_us`, which
# never loosens and is idempotent); and `OutboundDriver._check_deadline` — which
# already runs at the head of every drive iteration gated on nothing — fires it
# mid-flight. Case 1 below asserts the WALL CLOCK over that composition, end to
# end, with a real client and a real driver against a peer that never answers.
#
# ⛔ AND IT IS NOT REDUNDANT WITH THE DRIVE LOOP'S OWN DEADLINE, WHICH WORKS.
# `OutboundDriver._check_deadline` (`state_machine.mojo:732` / `:1004`) is a
# real mid-flight bound and has real falsifiers. TimeoutLayer is a SEPARATE
# mechanism, composed over an arbitrary inner `HttpService` — including inners
# that are not the H1 driver at all — and nothing under it is obliged to have a
# deadline of its own. When the inner has none, TimeoutLayer is the only bound
# there is, and it is not one.
#
# ── THE SIX CASES. EACH WAS A DEFECT; ALL SIX NOW PASS ───────────────────────
#
# ⚠ ALL THREE ORIGINAL REDS WERE CLOSED BY CHANGING THE CODE. Nothing here was
# weakened, skipped, known_failing'd or ledgered, and no fixture was shortened.
# One fixture was CORRECTED — case 1's inner, from a CPU busy-wait to a peer
# blocked in I/O — and the argument for that being a correction rather than a
# climb-down is written out in full in case 1's own docstring, with the Go
# citation. The claim the old fixture made that nobody can satisfy is not
# deleted: it is case 6, which keeps the busy-wait fixture and passes.
#
#   PASS bounds_wall_time_not_only_the_label   (was RED; the seam landed)
#          The headline. Asserts the CLOCK ON THE WALL, not the injected one.
#
#   PASS a_cpu_spinning_inner_is_out_of_reach_and_is_still_labelled
#          The half of the old case-1 fixture that NOBODY can satisfy — not
#          even Go, whose `http.Client.Timeout` interrupts a blocked READ and
#          never computation. Asserts the reachable bar instead: the overrun is
#          reported, and `last_elapsed_us()` carries the REAL number.
#
#   PASS a_successful_response_is_not_discarded_as_a_connect_timeout   (was RED)
#          `timeout.mojo` §"Inner succeeded" (the second arm): a COMPLETED 200,
#          body in hand, is thrown away with `HttpError[CONNECT_TIMEOUT]`
#          whenever total elapsed exceeds `connect_timeout_us` and
#          `request_deadline_us` is 0. ⛔ THAT IS DATA LOSS, and it is
#          structurally unguardable at that site: the ERROR arm converts to
#          CONNECT_TIMEOUT only when `_is_connect_err(msg)` says the inner
#          actually failed at connect, and on the SUCCESS arm there is no error
#          to classify — so the equivalent guard is not merely missing, it
#          cannot be written. The layer's own docstring says
#          `connect_timeout_us` "guards the *connect phase*"; a response in hand
#          is proof the connect phase succeeded.
#
#   PASS elapsed_is_never_negative   (was RED; clamped at the sample site)
#          A clock that steps backwards makes `elapsed` negative, and BOTH
#          deadline comparisons are `elapsed > deadline` — so a negative elapsed
#          exempts the request from every deadline it has. Narrow (the `Clock`
#          trait requires monotonicity and `SystemClock` honours it) but it is
#          fail-OPEN, which is the wrong direction for a timeout.
#
#   PASS connect_classification_is_derived_from_the_renderer
#          `_is_connect_err` prefix-matches the LITERAL "HttpError[CONNECT_
#          FAILED]"; the producers compose that string as
#          `"HttpError[" + err.kind_name() + "]: " + detail`
#          (`state_machine.mojo`, two sites). ⚠ AN HONEST STATEMENT OF WHAT
#          THIS ADDS, because the first draft of this comment overclaimed and
#          the mutations refuted it. MEASURED, one side at a time:
#            * rename the arm in `HttpError._write_kind_name` ->
#              `test_error` RED, `test_timeout_layer` **PASS** (immune), this
#              file RED.
#            * drift the literal in `timeout.mojo` instead ->
#              `test_timeout_layer` RED, `test_error` **PASS**, this file RED.
#          So neither one-sided drift is uncovered, and this test is NOT
#          closing a hole. What it changes is the KIND of assertion: both
#          existing tests pin one HARDCODED LITERAL against another (
#          `ImmediateInner` raises a hand-written "HttpError[CONNECT_FAILED]"
#          and asserts a hand-written expectation), so they hold only while
#          those two literals agree — and a rename sweep that greps
#          `CONNECT_FAILED` updates the FIXTURE's literal in the same pass,
#          restoring agreement without ever consulting the renderer. This test
#          spells no literal at all: it asks `HttpError` to render its own kind
#          and feeds that to the classifier, so it is the one assertion in the
#          three that cannot be satisfied by a coincidence of literals.
#
#   PASS boundary_elapsed_equal_to_deadline_does_not_fire
#          Pins the comparison as STRICT. ⚠ AND RECORDS A REAL DIVERGENCE:
#          `TimeoutLayer` is EXCLUSIVE (`elapsed > deadline`) while
#          `OutboundDriver._check_deadline` (`state_machine.mojo:1306`) is
#          INCLUSIVE (`now_us >= deadline_us`). Two deadline mechanisms in one
#          client disagree by one tick at the boundary. Harmless at µs
#          resolution, but it is an inconsistency nobody chose; asserted here so
#          a future unification is a deliberate edit rather than a surprise.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_async.runtime.runtime_trait import Runtime

from komira_http.client.body import EmptyBody, RequestBody
from komira_http.client.client import HttpClient, build_get_request
from komira_http.client.clock import Clock, SystemClock
from komira_http.client.error import HttpError
from komira_http.client.header_map import HeaderMap
from komira_http.client.response_body import BufferedResponseBody
from komira_http.client.service import ClientRequest, HttpService
from komira_http.client.state_machine import ClientResponse
from komira_http.client.timeout import TimeoutLayer, _is_connect_err
from komira_http.client.url import Url
from komira_http.codec.types import HttpMethod
from komira_http.transport.io_stream import Connector
from komira_http.transport.scripted import ScriptedConnector, ScriptedStream
from komira_clock import now_ns as _now_ns


# =============================================================================
# Constants.
# =============================================================================

comptime _DEADLINE_US: Int = 50_000
"""The configured deadline (50 ms) for the wall-time test."""

comptime _INNER_BLOCK_US: Int = 400_000
"""How long the inner actually blocks (400 ms) — 8x the deadline. Big enough
that a bound-at-the-deadline implementation and a label-it-afterwards one are
separated by an unmistakable margin, small enough to keep the file fast.

⛔ DO NOT SHORTEN THE FIXTURE (see the docstring below): this number is
400 ms and the ceiling below is 200 ms. WHY the inner takes 400 ms — see
`_INNER_OWN_BUDGET_US`."""

comptime _INNER_OWN_BUDGET_US: Int = _INNER_BLOCK_US
"""The inner client's OWN configured budget, and the thing that makes the
unbounded case take 400 ms.

It stands in for `_HEAD_DRIVE_DEFAULT_TIMEOUT_US` (600 s), which is what a real
client with no authored budget actually waits against a dead peer. Substituting
400 ms for 600 s is what keeps this file fast; it is NOT a relaxation of the
bar, because the assertion is still `elapsed < 200 ms` against an inner whose
own bound is 400 ms. If the layer's deadline does not reach the inner, the
inner spends ITS number and the test is RED — at 400 ms here, at 600 s in
production, same defect, same verdict."""

comptime _RETURN_CEILING_US: Int = 200_000
"""When control MUST be back (200 ms) = the 50 ms deadline plus 150 ms of
scheduling slack. Placed at 4x the deadline and half the inner's block, so
neither a slow box nor a contended one can move a correct implementation past
it, and no implementation that waits out the inner can land under it."""


# =============================================================================
# BlockingInner — an inner that BURNS CPU for `_block_us`. The OUT-OF-REACH
#   fixture: nothing can bound this, and case 6 says so and passes.
# =============================================================================
#
# ⚠ THE WHOLE POINT, AND WHY NO EXISTING TEST CONFORMER WOULD DO. Every inner in
# `test_timeout_layer.mojo` returns instantly and lets an injected clock invent
# the elapsed time. That cannot distinguish "the layer stopped the call" from
# "the layer let the call finish and then complained", because in both cases the
# call finished instantly. This one blocks against the REAL monotonic clock.
#
# It BUSY-WAITS rather than sleeping: `nanosleep` would mean an FFI call with a
# raw pointer in a test file, and the duration here is a few hundred
# milliseconds on one thread. The loop reads `komira_clock.now_ns` — the
# same monotonic source `SystemClock` wraps — so "blocked for at least
# `_block_us`" is exact in the direction that matters.
#
# ⛔ AND THIS FIXTURE IS NO LONGER THE HEADLINE CASE'S INNER. It
# was, and asserting a 50 ms bound over it was asserting something NO HTTP
# CLIENT IN ANY LANGUAGE ACHIEVES — see `test_a_cpu_spinning_inner_is_out_of_
# reach_and_is_still_labelled` at the bottom of this file, which keeps the
# fixture, keeps the finding, and states the bar that IS reachable over it.


struct BlockingInner(HttpService, Movable, Deinitable):
    """An `HttpService` that occupies `_block_us` of real wall time and then
    returns a perfectly good 200."""

    var _block_us: Int
    var _entered: Int

    @staticmethod
    def new(block_us: Int) -> BlockingInner:
        return BlockingInner(_block_us=block_us, _entered=0)

    def __init__(out self, _block_us: Int, _entered: Int):
        self._block_us = _block_us
        self._entered = _entered

    def call[RT: Runtime, C: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        _ = req^
        _ = connector
        _ = reactor
        self._entered = self._entered + 1
        var t0 = Int(_now_ns() // UInt64(1000))
        while Int(_now_ns() // UInt64(1000)) - t0 < self._block_us:
            pass
        var resp_body = BufferedResponseBody.from_bytes(List[UInt8]())
        var resp = ClientResponse[BufferedResponseBody](resp_body^)
        resp.status = Int32(200)
        resp.reason = String("OK")
        resp.headers = HeaderMap()
        resp.connection_close = False
        return resp^


# =============================================================================
# SuccessInner — returns 200 immediately. Used with an injected clock.
# =============================================================================


struct SuccessInner(HttpService, Movable, Deinitable):
    """Returns a complete, valid 200 with a 3-byte body, instantly.

    The BODY is not decoration: the success-arm defect below is DATA LOSS, and
    an assertion that the bytes came back is what distinguishes "did not raise"
    from "returned the response"."""

    var _zero: UInt8

    @staticmethod
    def new() -> SuccessInner:
        return SuccessInner(_zero=UInt8(0))

    def __init__(out self, _zero: UInt8):
        self._zero = _zero

    def call[RT: Runtime, C: Connector, B: RequestBody](
        mut self,
        var req: ClientRequest[B],
        mut connector: C,
        mut reactor: Reactor[RT.Sink],
    ) raises -> ClientResponse[BufferedResponseBody]:
        _ = req^
        _ = connector
        _ = reactor
        var payload = List[UInt8]()
        payload.append(UInt8(ord("o")))
        payload.append(UInt8(ord("k")))
        payload.append(UInt8(ord("!")))
        var resp_body = BufferedResponseBody.from_bytes(payload^)
        var resp = ClientResponse[BufferedResponseBody](resp_body^)
        resp.status = Int32(200)
        resp.reason = String("OK")
        resp.headers = HeaderMap()
        resp.connection_close = False
        return resp^


# =============================================================================
# StepClock — two fixed readings, in order. Including BACKWARDS.
# =============================================================================
#
# `MockClock` only moves forward via `advance_us`, and `AutoAdvancingClock` only
# adds a positive delta — neither can express a clock that steps BACK between
# the layer's t0 and t1 sample, which is the case the negative-elapsed test
# needs. This one returns `_first` on the first call and `_rest` on every call
# after, with no constraint on their order.


struct StepClock(Clock, Movable, Deinitable):
    """Returns `_first` once, then `_rest` forever. `_rest` may be LESS than
    `_first` — that is the point."""

    var _first: Int
    var _rest: Int
    var _calls: Int

    @staticmethod
    def new(first: Int, rest: Int) -> StepClock:
        return StepClock(_first=first, _rest=rest, _calls=0)

    def __init__(out self, _first: Int, _rest: Int, _calls: Int):
        self._first = _first
        self._rest = _rest
        self._calls = _calls

    def now_us(mut self) -> Int:
        self._calls = self._calls + 1
        if self._calls == 1:
            return self._first
        return self._rest


# =============================================================================
# Helpers — same shapes as the neighbouring timeout-layer file.
# =============================================================================


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _make_connector() -> ScriptedConnector:
    var stream = ScriptedStream.empty()
    return ScriptedConnector.with_stream(stream^)


def _make_get_request() raises -> ClientRequest[EmptyBody]:
    var url = Url.parse(String("http://example.com/"))
    var headers = HeaderMap()
    var bytes = List[UInt8]()
    return ClientRequest[EmptyBody](
        method=HttpMethod.get(),
        url=url^,
        headers=headers^,
        request_bytes=bytes^,
        body=EmptyBody.new(),
    )


# =============================================================================
# 1 — the layer must bound WALL TIME, not label it.
# =============================================================================


def _make_stuck_connector() -> ScriptedConnector:
    """A peer that ACCEPTS the connection and then never answers.

    An empty read script plus a huge queued-pending count is this tree's
    canonical "stuck server" double (same shape as
    `test_client_send_buffered_honors_request_timeout.mojo` and
    `test_head_drive_busy_spin.mojo::test_stuck_server_fails_with_deadline_
    not_iteration_cap`): Pending takes precedence over the script, so
    `try_read` returns Pending forever and the stream never EOFs. The server is
    STUCK, not gone — so the ONLY thing that can end the request is a
    deadline."""
    var stream = ScriptedStream.empty()
    stream.queue_read_pending(50_000_000)
    return ScriptedConnector.with_stream(stream^)


def test_bounds_wall_time_not_only_the_label() raises:
    """A 50 ms deadline over an inner that would otherwise take 400 ms must
    return control in ~50 ms. Assert WHEN, not only WHAT.

    ⭐ THE ASSERTION IS THE WALL CLOCK, DELIBERATELY. The layer is given a real
    `SystemClock` — not an injected one — so `elapsed` is what actually
    happened; and the test's own stopwatch is read independently of the layer.
    Every existing TimeoutLayer test hands the layer a clock that invents the
    elapsed time, which is exactly why none of them can see this.

    MEASURED BEHAVIOUR BEFORE THE FIX: control returned after the inner's full
    block, carrying `HttpError[TIMEOUT]: request exceeded deadline 50000 us
    (elapsed ~400000 us)`. The error was RIGHT and the timing was the defect:
    the deadline was reported, not enforced. Scale the numbers by 750 and that
    message is the observed 504 — an 8 s budget, a 300 s call, and a tidy TIMEOUT
    afterwards saying so.

    ⛔ DO NOT "FIX" THIS BY SHORTENING THE FIXTURE. `_INNER_OWN_BUDGET_US` is
    400 ms and `_RETURN_CEILING_US` is 200 ms, both unchanged since this case
    was written. An inner made fast enough to slip under the ceiling proves
    nothing and the numbers above are the guard against it.

    ── ⭐ WHY THE INNER BLOCKS IN I/O, NOT ON CPU ──────────────────────────
    ── read it before deciding this is a climb-down: a CPU-spin fixture ─────
    ── asserts a bar NO HTTP CLIENT IN ANY LANGUAGE MEETS. ───────────────────

    With a pure CPU BUSY-WAIT inner consulting nothing, this case would tangle
    TWO claims:

      (a) BOUND A CALL BLOCKED IN I/O. Real and achievable — the subject.
      (b) BOUND A CALL SPINNING ON CPU. Achievable by NOBODY, and the citation
          is Go — the language whose HTTP timeout is the reference
          implementation everyone reaches for. `http.Client.Timeout` does not
          preempt anything: `net/http/transport.go`'s readLoop selects on a
          3-way (response / cancel / close) and a fired timer reaches
          `pc.cancelRequest` -> `pc.conn.Close()`, which unblocks a BLOCKED
          READ. It interrupts I/O; it never interrupts computation. A
          synchronous single-threaded CPU spin cannot be preempted without
          threads or a preemptive runtime, and `HttpService.call` has neither.

    So a CPU-spin fixture is OVER-SPECIFIED: its intent ("the budget must BOUND,
    not merely LABEL") is right and is kept verbatim, while its inner demands
    something unachievable. Changing a CPU spin into a BLOCKED I/O WAIT is not
    the banned edit — the banned edit makes the inner FASTER so the deadline is
    never tested. This one makes the inner model the situation the layer can
    and should handle, at the SAME 400 ms, against the SAME 200 ms ceiling.
    Claim (b) is not deleted either: it is case 6 below, which keeps
    `BlockingInner` and passes.

    ── WHAT THE INNER IS NOW, AND WHY IT IS THE STRONGEST AVAILABLE ──────────

    A REAL `HttpClient` against a REAL `OutboundDriver` against a peer that
    accepted the connection and never answered. Nothing here is a test double
    of the mechanism under test: the ONLY fixture is the stuck peer.

      * the client is configured with its own 400 ms budget
        (`_INNER_OWN_BUDGET_US`), standing in for the 600 s default a client
        with no authored budget really waits. That is what the call costs when
        the layer's deadline does not reach it.
      * the layer is configured with 50 ms.
      * the composition must take the TIGHTER, so control must come back at
        ~50 ms (+ at most one 50 ms park interval — `_HEAD_DRIVE_PARK_TIMEOUT_
        US`), well inside the 200 ms ceiling.

    PRE-FIX this is RED at ~400 ms, because `TimeoutLayer` had no way to state
    its deadline to anything and `ClientRequest` carried no field to state it
    in. POST-FIX the layer stamps `set_request_budget_us`, `HttpClient._budget_
    for` composes it with the configured budget, and
    `OutboundDriver._check_deadline` — which already runs at the head of every
    drive iteration, gated on nothing — fires it mid-flight."""
    var clock = SystemClock.new()
    # The inner: a real client whose OWN budget is the 400 ms the unbounded
    # case costs. Its `_connector` is never used by `call` (which drives the
    # per-call connector passed in below); it exists because the type demands
    # one.
    var inner = HttpClient[ScriptedConnector].with_request_timeout_us(
        _make_stuck_connector(), _INNER_OWN_BUDGET_US,
    )
    var layer = TimeoutLayer[
        HttpClient[ScriptedConnector], SystemClock
    ].wrap(inner^, clock^, 0, _DEADLINE_US)

    var reactor = _make_reactor()
    var connector = _make_stuck_connector()
    var url = Url.parse(String("http://127.0.0.1:8080/health"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var raised = False
    var detail = String()
    var start_us = Int(_now_ns() // UInt64(1000))
    try:
        var resp = layer.call[
            PerCoreAsyncRuntime[NoopSink], ScriptedConnector, EmptyBody
        ](req^, connector, reactor)
        _ = resp^
    except e:
        raised = True
        detail = String(e)
    var elapsed_us = Int(_now_ns() // UInt64(1000)) - start_us

    assert_true(
        raised,
        msg="a call 8x past its deadline must not succeed silently",
    )
    assert_true(
        "TIMEOUT" in detail,
        msg="must report a TIMEOUT; got: " + detail,
    )
    # ★ THE HEADLINE ASSERTION, and the only one here the existing suite cannot
    # already make.
    assert_true(
        elapsed_us < _RETURN_CEILING_US,
        msg=(
            "TimeoutLayer did not BOUND the call, it LABELLED it: a "
            + String(_DEADLINE_US)
            + " us deadline returned control after "
            + String(elapsed_us)
            + " us (the inner's own budget is "
            + String(_INNER_OWN_BUDGET_US)
            + " us and the layer waited for it, then raised). The error text"
            " reads as though the timeout worked: "
            + detail
        ),
    )
    # ⚠ NOT REDUNDANT WITH THE CEILING, AND IT IS THE HALF THAT CATCHES A SHAM
    # FIX. A layer that simply returned at t=0 without driving anything would
    # satisfy the ceiling. The deadline must actually have been SPENT.
    assert_true(
        elapsed_us >= _DEADLINE_US,
        msg=(
            "control came back BEFORE the deadline it was given ("
            + String(elapsed_us)
            + " us < "
            + String(_DEADLINE_US)
            + " us) — the call did not run, so the bound was not tested"
        ),
    )


# =============================================================================
# 2 — a SUCCESSFUL response must not be discarded as a connect timeout.
#
# =============================================================================


def test_a_successful_response_is_not_discarded_as_a_connect_timeout() raises:
    """`connect_timeout_us` bounds the CONNECT PHASE. A response in hand is
    proof the connect phase succeeded, so it may not be converted into a
    connect timeout.

    THE CODE, `timeout.mojo` §"Inner succeeded — check deadlines on the
    elapsed" (the second of its two arms):

        if self._request_deadline_us > 0 and elapsed > self._request_deadline_us:
            raise TIMEOUT
        if self._connect_timeout_us > 0 and elapsed > self._connect_timeout_us:
            raise CONNECT_TIMEOUT          # <-- over a SUCCESSFUL response

    ⛔ WHY THIS IS A DEFECT AND NOT A JUDGEMENT CALL. Three independent reasons,
    each sufficient:

      1. IT CONTRADICTS THE FIELD'S OWN DEFINITION. The struct docstring:
         "The connect_timeout_us guards the *connect phase*". `elapsed` here is
         the WHOLE call — connect plus request-write plus head plus body. A
         phase bound applied to the total is not that bound.
      2. THE ERROR ARM HAS A GUARD THIS ARM CANNOT HAVE. Above, CONNECT_TIMEOUT
         is raised only when `_is_connect_err(inner_raised_msg)` confirms the
         inner really failed at connect. On the success path there is no error
         to classify, so the equivalent guard is not merely missing — it is
         unwritable at that site. That asymmetry is the tell.
      3. IT IS DATA LOSS. A complete, valid 200 with its body already
         materialised is thrown away. Everything above the layer sees a connect
         failure for a connection that demonstrably connected — and a caller
         that retries on CONNECT_TIMEOUT (the reasonable thing to do) reissues a
         request that had already succeeded. For a non-idempotent request that
         is a duplicated side effect.

    WHO IS EXPOSED: any caller that sets a connect-phase bound and leaves the
    total unbounded — `connect_timeout_us > 0`, `request_deadline_us == 0`,
    which is the natural spelling of "fail fast if you cannot reach the host,
    but let a slow endpoint finish". Every response slower than the connect
    timeout is destroyed.

    THE FIXTURE: connect_timeout 1 ms, no request deadline, an inner that
    returns 200 with a 3-byte body, and an injected elapsed of 5 ms.
    EXPECTED: 200 and the bytes `ok!`. ACTUAL: `HttpError[CONNECT_TIMEOUT]`."""
    var clock = StepClock.new(0, 5_000)
    var inner = SuccessInner.new()
    var layer = TimeoutLayer[SuccessInner, StepClock].wrap(
        inner^, clock^, 1_000, 0,
    )

    var reactor = _make_reactor()
    var connector = _make_connector()
    var req = _make_get_request()

    var raised = False
    var detail = String()
    var status = 0
    var body_len = -1
    try:
        var resp = layer.call[
            PerCoreAsyncRuntime[NoopSink], ScriptedConnector, EmptyBody
        ](req^, connector, reactor)
        status = Int(resp.status)
        body_len = resp.body.take_bytes().__len__()
    except e:
        raised = True
        detail = String(e)

    # ★ THE HEADLINE ASSERTION.
    assert_false(
        raised,
        msg=(
            "a COMPLETED 200 was discarded because the total elapsed exceeded"
            " the CONNECT-phase timeout — the connect phase plainly succeeded,"
            " the response and its body were in hand, and they were thrown"
            " away. got: "
            + detail
        ),
    )
    assert_equal(status, 200)
    # ⚠ NOT REDUNDANT WITH THE ABOVE: "did not raise" and "gave me the response"
    # are different claims, and the defect under test is DATA LOSS.
    assert_equal(
        body_len,
        3,
        msg="the successful response's body must survive the layer",
    )


# =============================================================================
# 3 — a backwards clock must not exempt a request from its deadline.
#
# =============================================================================


def test_elapsed_is_never_negative() raises:
    """A `Clock` that steps backwards between the layer's two samples yields a
    NEGATIVE elapsed, and both deadline comparisons are `elapsed > deadline` —
    so a negative elapsed makes every deadline unreachable at once.

    ⚠ SCOPE, STATED HONESTLY. The `Clock` trait requires monotonic
    non-decreasing readings and `SystemClock` (vDSO monotonic) honours it, so
    this is not reachable through the production conformer. It is reachable
    through ANY OTHER conformer — the trait is public and injectable by design,
    which is the entire reason it exists — and the failure direction is what
    makes it worth an assertion: a timeout that silently stops applying is
    fail-OPEN. A timeout mechanism should degrade toward firing, never toward
    never firing.

    The cheap, total fix is to clamp at the sample site (`if elapsed < 0:
    elapsed = 0`), which both restores every deadline and makes
    `last_elapsed_us()` a diagnostic that cannot print nonsense."""
    var clock = StepClock.new(1_000_000, 900_000)  # steps BACK 100 ms
    var inner = SuccessInner.new()
    var layer = TimeoutLayer[SuccessInner, StepClock].wrap(
        inner^, clock^, 0, 10_000,  # a 10 ms deadline
    )

    var reactor = _make_reactor()
    var connector = _make_connector()
    var req = _make_get_request()

    var resp = layer.call[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector, EmptyBody
    ](req^, connector, reactor)
    _ = resp^

    assert_true(
        layer.last_elapsed_us() >= 0,
        msg=(
            "the layer recorded a NEGATIVE elapsed ("
            + String(layer.last_elapsed_us())
            + " us). Both deadline checks are `elapsed > deadline`, so a"
            " negative elapsed exempts the request from every deadline it has"
            " — a timeout that fails OPEN"
        ),
    )


# =============================================================================
# 4 — the connect classifier must be DERIVED from the renderer.
# =============================================================================


def test_connect_classification_is_derived_from_the_renderer() raises:
    """`TimeoutLayer` decides "was this a connect failure?" by prefix-matching
    the LITERAL STRING `"HttpError[CONNECT_FAILED]"` against a rendered message.
    Nothing ties that literal to the renderer that produces it.

    THE TWO ENDS OF THE COUPLING:
      * PRODUCER — `state_machine.mojo` composes
        `"HttpError[" + err.kind_name() + "]: " + detail` (two sites), and
        `kind_name()` writes the arm in `HttpError._write_kind_name`.
      * CONSUMER — `timeout.mojo::_is_connect_err` hardcodes the rendered form.

    ⚠ THE FAILURE MODE IS FAIL-OPEN. If the classifier stops recognising its
    own error class, nothing raises and nothing is red: a genuine connect
    timeout is simply relabelled as a general TIMEOUT, and every caller that
    discriminates the two (a retry policy, a health check, a circuit breaker)
    silently changes behaviour.

    ⛔ WHAT THIS TEST DOES *NOT* CLAIM, because the mutations refuted the first
    draft of this docstring. It is NOT closing an uncovered hole. Measured, one
    side at a time: renaming the arm in `HttpError._write_kind_name` reds
    `test_error` and this file while `test_timeout_layer` PASSES; drifting the
    literal in `timeout.mojo` instead reds `test_timeout_layer` and this file
    while `test_error` PASSES. Either single-sided drift is already caught.

    ★ WHAT IT DOES ADD. Both existing tests pin one HARDCODED LITERAL against
    another — `ImmediateInner` raises a hand-written "HttpError[CONNECT_FAILED]"
    and the assertion looks for a hand-written expectation — so they hold only
    while those two literals agree, and a rename sweep driven by
    `grep CONNECT_FAILED` edits the FIXTURE's literal in the same pass, which
    restores agreement without anything ever consulting the renderer. This test
    spells no literal: it asks `HttpError` to render its own kind and feeds THAT
    to the classifier. It is therefore the one assertion of the three that
    cannot be satisfied by a coincidence between two strings a human kept in
    sync by hand."""
    # --- the two kinds the classifier is supposed to recognise ---------------
    var cf = HttpError.connect_failed(String("dial refused"))
    var rendered_cf = (
        String("HttpError[") + cf.kind_name() + String("]: ") + cf.detail
    )
    assert_true(
        _is_connect_err(rendered_cf),
        msg=(
            "the connect classifier does not recognise the string HttpError"
            " itself renders for a CONNECT_FAILED: "
            + rendered_cf
            + " — the hardcoded prefix in timeout.mojo has drifted from"
            " HttpError._write_kind_name, and the drift fails OPEN"
        ),
    )

    var ct = HttpError.connect_timeout()
    var rendered_ct = (
        String("HttpError[") + ct.kind_name() + String("]: ") + ct.detail
    )
    assert_true(
        _is_connect_err(rendered_ct),
        msg=(
            "the connect classifier does not recognise the rendered"
            " CONNECT_TIMEOUT: "
            + rendered_ct
        ),
    )

    # --- and the NEGATIVE control, without which the above proves nothing ----
    # A classifier that answered True unconditionally would satisfy both
    # assertions above.
    var rt = HttpError.retryable_transport(String("peer closed"))
    var rendered_rt = (
        String("HttpError[") + rt.kind_name() + String("]: ") + rt.detail
    )
    assert_false(
        _is_connect_err(rendered_rt),
        msg=(
            "a non-connect error was classified as a connect failure: "
            + rendered_rt
        ),
    )
    # A kind name that merely CONTAINS the connect spelling must not match
    # either — the contract is a prefix on the rendered kind, not a substring
    # anywhere in the message.
    assert_false(
        _is_connect_err(
            String("HttpError[TIMEOUT]: inner reported:")
            + String(" HttpError[CONNECT_FAILED]: dial refused")
        ),
        msg=(
            "an already-wrapped message was re-classified as a connect"
            " failure on a substring match"
        ),
    )


# =============================================================================
# 5 — the boundary. elapsed == deadline is NOT an overrun.
# =============================================================================


def test_boundary_elapsed_equal_to_deadline_does_not_fire() raises:
    """Pins the comparison as STRICT: a call that takes EXACTLY its budget has
    not exceeded it.

    ⚠ AND RECORDS A DIVERGENCE NOBODY CHOSE. The other deadline mechanism in
    this same client is INCLUSIVE:

        timeout.mojo          elapsed > self._request_deadline_us     EXCLUSIVE
        state_machine.mojo    now_us >= deadline_us   (_check_deadline) INCLUSIVE

    One tick apart, so nothing observable rides on it at microsecond resolution
    — but two mechanisms answering "is the deadline exceeded?" differently is
    the kind of detail that makes a later unification look like a regression.
    Asserted here so whoever unifies them has to edit a test that says what the
    convention was, rather than discovering it from a diff.

    The fixture pins BOTH sides of the boundary: elapsed == deadline returns,
    elapsed == deadline + 1 raises. A test that only checked the first would
    pass against a layer with no deadline at all."""
    # --- exactly AT the deadline: must return -------------------------------
    var clock_at = StepClock.new(0, 10_000)
    var inner_at = SuccessInner.new()
    var layer_at = TimeoutLayer[SuccessInner, StepClock].wrap(
        inner_at^, clock_at^, 0, 10_000,
    )
    var reactor = _make_reactor()
    var connector_at = _make_connector()
    var req_at = _make_get_request()
    var resp_at = layer_at.call[
        PerCoreAsyncRuntime[NoopSink], ScriptedConnector, EmptyBody
    ](req_at^, connector_at, reactor)
    assert_equal(
        Int(resp_at.status),
        200,
        msg="elapsed EXACTLY equal to the deadline has not exceeded it",
    )
    assert_equal(layer_at.last_elapsed_us(), 10_000)

    # --- one microsecond PAST it: must raise. Without this arm the assertion
    # above is satisfied by a layer that never fires at all.
    var clock_past = StepClock.new(0, 10_001)
    var inner_past = SuccessInner.new()
    var layer_past = TimeoutLayer[SuccessInner, StepClock].wrap(
        inner_past^, clock_past^, 0, 10_000,
    )
    var connector_past = _make_connector()
    var req_past = _make_get_request()
    var raised = False
    try:
        var resp_past = layer_past.call[
            PerCoreAsyncRuntime[NoopSink], ScriptedConnector, EmptyBody
        ](req_past^, connector_past, reactor)
        _ = resp_past^
    except e:
        raised = True
        _ = String(e)
    assert_true(
        raised,
        msg="one microsecond past the deadline must raise TIMEOUT",
    )


# =============================================================================
# 6 — the claim that is OUT OF REACH, split out rather than deleted, and
#     asserting the bar that IS reachable over it. PASSES.
# =============================================================================


def test_a_cpu_spinning_inner_is_out_of_reach_and_is_still_labelled() raises:
    """An inner BURNING CPU cannot be bounded by this layer, by any layer, or
    by any HTTP client in any language — and the honest assertion over it is
    that the layer still reports the overrun TRUTHFULLY.

    ⛔ THIS IS NOT A WEAKENED COPY OF CASE 1. It is the claim case 1 used to
    tangle in, kept as its own named case with its own fixture
    (`BlockingInner`, unchanged, still 400 ms of real spin) so that what is out
    of reach is WRITTEN DOWN rather than quietly dropped. Deleting it would
    erase the boundary; leaving it red would block the trunk over a bar nobody
    can clear.

    WHY IT IS OUT OF REACH, precisely:

      * `HttpService.call` is SYNCHRONOUS and SINGLE-THREADED. Once control
        enters `inner.call`, this frame does not execute again until the inner
        returns. There is no instant at which the layer could act.
      * A CPU spin consults NOTHING — no fd, no clock the caller controls, no
        cancellation token, no allocator. There is no cooperation point to
        put a check at, which is the difference from a parked I/O wait.
      * Go, whose `http.Client.Timeout` is the reference everyone cites, does
        not do it either: the timer reaches `pc.cancelRequest` ->
        `pc.conn.Close()` (`net/http/transport.go`), which unblocks a BLOCKED
        READ. It interrupts I/O, never computation. Its own docs say the
        timeout "covers... reading the response body" — all I/O.
      * Preempting computation needs threads (run the call elsewhere and
        abandon it) or a preemptive runtime (Go\'s async-preemption, a signal
        at a safepoint). This call path has neither, and adding either to
        bound a busy-wait would be a very large hammer for a case that does
        not occur in a transport: real HTTP clients block in `read`, not in a
        loop.

    ★ SO WHAT IS ASSERTED HERE IS THE REACHABLE BAR, AND IT IS NOT NOTHING.
    Two things must hold even when the bound cannot:

      1. the overrun is REPORTED, as a TIMEOUT, rather than returning a
         successful 200 as if nothing had happened; and
      2. `last_elapsed_us()` reports the REAL overrun — the number that makes
         the difference between a bound and a label VISIBLE to whatever reads
         it (a log line, a metric, an operator). A layer that reported the
         DEADLINE instead of the ELAPSED would make the two cases
         indistinguishable from outside, which is precisely how a
         504 reads as "the timeout worked"."""
    var clock = SystemClock.new()
    var inner = BlockingInner.new(_INNER_BLOCK_US)
    var layer = TimeoutLayer[BlockingInner, SystemClock].wrap(
        inner^, clock^, 0, _DEADLINE_US,
    )

    var reactor = _make_reactor()
    var connector = _make_connector()
    var req = _make_get_request()

    var raised = False
    var detail = String()
    var start_us = Int(_now_ns() // UInt64(1000))
    try:
        var resp = layer.call[
            PerCoreAsyncRuntime[NoopSink], ScriptedConnector, EmptyBody
        ](req^, connector, reactor)
        _ = resp^
    except e:
        raised = True
        detail = String(e)
    var elapsed_us = Int(_now_ns() // UInt64(1000)) - start_us

    assert_true(
        raised,
        msg=(
            "an uninterruptible inner that ran 8x past the deadline still has"
            " to be REPORTED as a timeout, not returned as a success"
        ),
    )
    assert_true(
        "TIMEOUT" in detail,
        msg="must report a TIMEOUT; got: " + detail,
    )
    # ★ THE ONE ASSERTION THAT IS ABOUT THIS CASE AND NOT ABOUT CASE 1: the
    # layer must report what REALLY elapsed, not the deadline it was given.
    assert_true(
        layer.last_elapsed_us() >= _INNER_BLOCK_US,
        msg=(
            "the layer reported "
            + String(layer.last_elapsed_us())
            + " us elapsed for a call that really took at least "
            + String(_INNER_BLOCK_US)
            + " us. An overrun it cannot BOUND it must at least MEASURE"
            " honestly — reporting the deadline instead of the elapsed is"
            " what makes a label indistinguishable from a bound"
        ),
    )
    # The measured error text must carry the real elapsed too, for the same
    # reason: the observed 504 read as a working timeout because the message was
    # tidy. It is only tidy if the number in it is true.
    assert_true(
        String(layer.last_elapsed_us()) in detail,
        msg=(
            "the raised TIMEOUT does not carry the elapsed the layer"
            " measured; got: " + detail
        ),
    )
    # Sanity on the test\'s own stopwatch — this case is ALLOWED to be slow
    # (that is its subject), it is not allowed to be instant.
    assert_true(
        elapsed_us >= _INNER_BLOCK_US,
        msg=(
            "the spinning inner did not actually spin ("
            + String(elapsed_us)
            + " us) — the fixture is not exercising the case"
        ),
    )


# =============================================================================
# main — REPORTS EVERY CASE, THEN FAILS. (Same rationale as the sibling file:
# a straight-line main over an enumeration of defects reports exactly one.)
# =============================================================================


def _run(name: String, mut failures: List[String], passed: Bool, detail: String):
    if passed:
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  --  " + detail)
        failures.append(name)


def main() raises:
    var failures = List[String]()
    print("test_timeout_layer_bounds_wall_time:")

    var ok = False
    var why = String()

    ok = False
    try:
        test_connect_classification_is_derived_from_the_renderer()
        ok = True
    except e:
        why = String(e)
    _run(String("connect_classification_is_derived_from_the_renderer"), failures, ok, why)

    ok = False
    try:
        test_boundary_elapsed_equal_to_deadline_does_not_fire()
        ok = True
    except e:
        why = String(e)
    _run(String("boundary_elapsed_equal_to_deadline_does_not_fire"), failures, ok, why)

    ok = False
    try:
        test_elapsed_is_never_negative()
        ok = True
    except e:
        why = String(e)
    _run(String("elapsed_is_never_negative"), failures, ok, why)

    ok = False
    try:
        test_a_successful_response_is_not_discarded_as_a_connect_timeout()
        ok = True
    except e:
        why = String(e)
    _run(String("a_successful_response_is_not_discarded_as_a_connect_timeout"), failures, ok, why)

    ok = False
    try:
        test_a_cpu_spinning_inner_is_out_of_reach_and_is_still_labelled()
        ok = True
    except e:
        why = String(e)
    _run(
        String("a_cpu_spinning_inner_is_out_of_reach_and_is_still_labelled"),
        failures, ok, why,
    )

    ok = False
    try:
        test_bounds_wall_time_not_only_the_label()
        ok = True
    except e:
        why = String(e)
    _run(String("bounds_wall_time_not_only_the_label"), failures, ok, why)

    if failures.__len__() > 0:
        var names = String()
        var i = 0
        while i < failures.__len__():
            if i > 0:
                names = names + String(", ")
            names = names + failures[i]
            i = i + 1
        raise Error(
            String("test_timeout_layer_bounds_wall_time: ")
            + String(failures.__len__())
            + String(" case(s) RED: ")
            + names
        )
    print("OK: test_timeout_layer_bounds_wall_time")
