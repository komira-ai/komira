# =============================================================================
# tests/test_pump_flush_ordering.mojo — the invoke loop: WHERE the drain runs,
#   which channel each failure class takes, and what the dispatcher receives.
# =============================================================================
# The rule under test, from `pump.mojo`'s header:
#
#   poll `next`  ->  convert  ->  dispatch  ->  POST result  ->  FLUSH  ->  poll
#
# ⛔ HOW THE ORDERING IS OBSERVED WITHOUT SHARED STATE — this is the technique,
# and it is the reason this file needs no journal object, no ArcPointer and no
# global. The transport and the flush hook are two INDEPENDENT `mut` borrows;
# neither can see the other, so "the flush ran second" cannot be read off a
# shared log. Instead the transport is made to RAISE at a chosen instant, and
# the flush counter is read AFTER the pump has propagated that raise:
#
#   raise from `respond_ok` (the POST)   -> a correct pump has NOT drained yet
#                                           => flush_count == 0
#
#   raise from the SECOND `next_invocation` (the next POLL)
#                                        -> a correct pump HAS already drained
#                                           invocation 0 => flush_count == 1
#
# ⚠ WHICH DETECTOR CATCHES WHICH MISPLACEMENT — MEASURED, and the first version
# of this comment got it wrong, so the table is what the runs said and not what
# the shape suggests. Each row is a real edit to `run_api_gateway_pump` with the
# suite re-run:
#
#   drain moved ABOVE the result POST ......... D1 RED (1 vs 0)   D2 pass
#   drain moved to the TOP of the loop body,
#     i.e. immediately after the poll ......... D1 RED (1 vs 0)   D2 PASS ⚠
#   drain DELETED (shutdown-only flush) ....... D2 RED (0 vs 1)   D1 pass
#   drain DUPLICATED (added, not moved) ....... baseline RED (2 vs 1)
#   drain moved ABOVE `report_error` ONLY,
#     i.e. the ERROR arm alone ................ D3 RED (1 vs 0)
#                                               D1 pass, D2 pass, D4 pass ⚠⚠
#
# So D2 does NOT catch a post-poll placement — it scores 1 there and passes, and
# claiming otherwise was this file's own unmeasured assertion. D1 is what
# rejects that arm, because "at the top of the loop" is still BEFORE the POST.
#
# ⛔ AND THE LAST ROW IS THE HOLE D1+D2 STILL HAD, measured the same way. The
# pump's loop body ends in an `if converted:` with TWO exits, and D1 drives only
# the success one — its fixture converts fine and never reaches `report_error`.
# So a drain moved above the ERROR report ALONE was caught by nothing, over the
# DEPLOYMENT-FAULT path, where every invocation fails identically and every one
# would pay an S3 conditional PUT inside its billed duration forever, for a
# function that is answering nobody. D3 closes it. The detectors are the ARMS OF
# THE BRANCH, not a redundancy.
#
# ⇒ AND D4 READS THE ORDER FROM THE OTHER SIDE. D1–D3 all make the TRANSPORT
#   raise and read the FLUSH counter. D4 makes the DRAIN raise and reads the
#   TRANSPORT counter, which is the only way to state the consequence the rule
#   exists to prevent: with the drain after the POST a durability failure leaves
#   the caller ANSWERED (`post_count == 1`); with it before, the SAME failure
#   silently costs the caller their response (`post_count == 0`). It is also the
#   only assertion of `LambdaPostResponseFlush`'s documented raise contract —
#   `_CountingFlush` had never raised, so the pump had never once been driven
#   with a failing drain.
#
# ⇒ STATED EXACTLY, so the set is not over-read either: D1 forbids a drain CALL
#   at any instant before the result POST. D3 forbids the same before the ERROR
#   report. D2 forbids the ABSENCE of a per-invocation drain call. D4 forbids a
#   drain whose failure can reach back and unmake the caller's answer. The
#   conjunction leaves exactly one legal slot — after BOTH exits, inside the
#   same iteration — which is the rule.
#   ⚠ All four detectors count CALLS, not records. A drain call in the right slot
#   that drained the wrong thing would satisfy both; what rules that out is the
#   drain's own contract (`buffered_rows() == 0` after `flush_pending_now()`,
#   asserted by the drain's own tests), not this file.
#
# Each fixture differs from the happy-path transport in EXACTLY ONE field
# (`_raise_on_post_index` or `_raise_on_poll_index`), so a failure cannot be
# attributed to two changes.
#
# ⚠ WHY THE DISPATCHER HERE IS A RECORDER AND NOT A PRODUCTION ONE. A test here
# compiles against THIS library plus this library's own deps and nothing else.
# A production dispatcher lives in a CONSUMER layered ABOVE this package —
# reaching it from here needs the inverted edge this package exists to avoid.
# `_RecordingDispatcher`
# is a real `RequestDispatcher` conformer driven through the real `dispatch[RT]`
# seam; what it adds is that it keeps the fields it was handed.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import (
    MODEL_AWS_LAMBDA,
    MODEL_CLOUD_RUN,
    Runtime,
)
from komira_async.runtime.aws_lambda_runtime import AwsLambdaRuntime

from komira_http_core.codec.types import HttpRequest, HttpResponse
from komira_http_server.dispatch import RequestDispatcher
from komira_http_core.codec.types import HTTP_METHOD_POST

from komira_json import parse_json_value

from komira_aws_lambda_http.apigw_v2 import AUTHORIZER_HEADER_PREFIX
from komira_aws_lambda_http.pump import (
    LambdaInvocationTransport,
    LambdaInvokeEvent,
    LambdaPostResponseFlush,
    NoLambdaFlush,
    announce_init_failure,
    run_api_gateway_pump,
)


comptime _Rt = AwsLambdaRuntime[NoopSink]


# =============================================================================
# §1 — the scripted instruments.
# =============================================================================

struct _ScriptedTransport(
    LambdaInvocationTransport, Movable, Deinitable
):
    """A `LambdaInvocationTransport` with no socket: a list of events to hand
    out, counters for each channel, and TWO fault injectors.

    `_raise_on_poll_index` / `_raise_on_post_index` default to -1 (never). A
    negative-fixture sets exactly ONE of them; that single field is the entire
    difference from the happy path, which is what makes an ordering failure
    attributable."""

    var _events: List[String]
    var _next_index: Int
    var post_count: Int
    var error_count: Int
    var init_error_count: Int
    var last_payload: String
    var last_error: String
    var _raise_on_poll_index: Int
    var _raise_on_post_index: Int
    # ⛔ THE THIRD INJECTOR, and it exists because the other two leave an
    # ASYMMETRY open. The pump's per-invocation body has TWO exits --
    # `respond_ok` on the success channel and `report_error` on the
    # deployment-fault channel -- and until this field existed only the first
    # was ordering-guarded. A drain moved to sit ABOVE `report_error` while
    # staying below `respond_ok` passed every detector in this file. See
    # `test_the_drain_has_NOT_run_when_the_ERROR_report_fails`.
    var _raise_on_error_index: Int

    def __init__(out self, var events: List[String]):
        self._events = events^
        self._next_index = 0
        self.post_count = 0
        self.error_count = 0
        self.init_error_count = 0
        self.last_payload = String("")
        self.last_error = String("")
        self._raise_on_poll_index = -1
        self._raise_on_post_index = -1
        self._raise_on_error_index = -1

    def next_invocation(mut self) raises -> LambdaInvokeEvent:
        if self._next_index == self._raise_on_poll_index:
            raise Error(
                String("scripted-transport: poll ")
                + String(self._next_index)
                + String(" fails")
            )
        if self._next_index >= len(self._events):
            raise Error("scripted-transport: no invocation left to hand out")
        var event = self._events[self._next_index].copy()
        var rid = String("req-") + String(self._next_index)
        self._next_index += 1
        return LambdaInvokeEvent(rid^, event^)

    def respond_ok(mut self, request_id: String, payload: String) raises:
        if self.post_count == self._raise_on_post_index:
            raise Error(
                String("scripted-transport: POST ")
                + String(self.post_count)
                + String(" fails")
            )
        self.post_count += 1
        self.last_payload = payload

    def report_error(mut self, request_id: String, message: String) raises:
        if self.error_count == self._raise_on_error_index:
            raise Error(
                String("scripted-transport: ERROR report ")
                + String(self.error_count)
                + String(" fails")
            )
        self.error_count += 1
        self.last_error = message

    def report_init_error(mut self, message: String) raises:
        self.init_error_count += 1
        self.last_error = message


struct _CountingFlush(
    LambdaPostResponseFlush, Movable, Deinitable
):
    """Counts drains. It cannot see the transport, and that is the point (see
    this file's header): the ORDER is read off WHETHER this counter moved before
    a deliberately-raising transport call, never off a shared journal."""

    var flush_count: Int
    # ⛔ THE FOURTH INJECTOR, and it observes the ordering from the OTHER
    # SIDE. Every detector above reads the flush counter after making the
    # TRANSPORT raise. This one makes the DRAIN raise and reads the transport's
    # counter, which is the only way to assert the half of
    # `LambdaPostResponseFlush`'s contract that says the raise "cannot corrupt
    # the caller's answer -- the result was already posted". See
    # `test_a_raising_drain_still_leaves_the_caller_ANSWERED`.
    var _raise_on_flush_index: Int

    def __init__(out self):
        self.flush_count = 0
        self._raise_on_flush_index = -1

    def flush_after_response(mut self) raises -> Int:
        # Counts ATTEMPTS, so a raising drain is still observably a drain that
        # was reached -- otherwise the assertion below could not tell "the drain
        # raised" from "the drain never ran".
        self.flush_count += 1
        if self.flush_count - 1 == self._raise_on_flush_index:
            raise Error(
                String("counting-flush: drain ")
                + String(self.flush_count - 1)
                + String(" fails")
            )
        return 7


struct _RecordingDispatcher(
    RequestDispatcher, Movable, Deinitable
):
    """A real `RequestDispatcher` that keeps what it was handed.

    `_raise_on_dispatch` (default False) is the ONE field the dispatcher-raise
    fixture flips."""

    var seen_method: UInt8
    var seen_path: String
    var seen_query: String
    var seen_headers: Dict[String, String]
    var seen_body_len: Int
    var dispatch_count: Int
    var _raise_on_dispatch: Bool

    def __init__(out self):
        self.seen_method = UInt8(0)
        self.seen_path = String("")
        self.seen_query = String("")
        self.seen_headers = Dict[String, String]()
        self.seen_body_len = 0
        self.dispatch_count = 0
        self._raise_on_dispatch = False

    def dispatch[
        RT: Runtime,
    ](
        mut self, mut reactor: Reactor[RT.Sink], var req: HttpRequest
    ) raises -> HttpResponse:
        self.dispatch_count += 1
        self.seen_method = req.method.code
        self.seen_path = req.path.copy()
        self.seen_query = req.query_string.copy()
        self.seen_body_len = len(req.body)
        self.seen_headers = Dict[String, String]()
        for kv in req.headers.items():
            self.seen_headers[String(kv.key)] = String(kv.value)

        if self._raise_on_dispatch:
            raise Error("recording-dispatcher: the handler raised")

        var r = HttpResponse(status=Int32(200))
        r.headers[String("content-type")] = String("application/json")
        var body = String('{"handled": true}')
        var bs = body.as_bytes()
        for i in range(len(bs)):
            r.body.append(bs[i])
        return r^


def _send_event(rid_tag: String) -> String:
    """One realistic payload-format-2.0 event, with an authorizer context."""
    return String(
        '{"version": "2.0", "rawPath": "/api/v1/items",'
        '"rawQueryString": "tag=a&tag=b",'
        '"headers": {"Content-Type": "application/json",'
        '"x-komira-authorizer-orgid": "org-victim",'
        '"X-Request-Id": "'
    ) + rid_tag + String(
        '"},'
        '"requestContext": {"http": {"method": "POST"},'
        '"authorizer": {"lambda": {"orgId": "org-real"}}},'
        '"body": "{}", "isBase64Encoded": false}'
    )


def _one_event_transport() -> _ScriptedTransport:
    var events = List[String]()
    events.append(_send_event(String("req-a")))
    return _ScriptedTransport(events^)


def _two_event_transport() -> _ScriptedTransport:
    var events = List[String]()
    events.append(_send_event(String("req-a")))
    events.append(_send_event(String("req-b")))
    return _ScriptedTransport(events^)


# =============================================================================
# §2 — the RULE: where the drain runs.
# =============================================================================

def test_the_drain_runs_once_per_invocation() raises:
    """BASELINE. One invocation in, one result POSTed, exactly one drain.

    This is the arm both inversion detectors below are measured AGAINST: it
    proves the drain runs at all, so a `flush_count == 0` in the next test is a
    statement about ORDER and not about a drain that was simply never wired."""
    var transport = _one_event_transport()
    var dispatcher = _RecordingDispatcher()
    var flusher = _CountingFlush()
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()

    var handled = run_api_gateway_pump[
        _RecordingDispatcher, _Rt, _ScriptedTransport, _CountingFlush
    ](transport, dispatcher, reactor, flusher, 1)

    assert_equal(handled, 1)
    assert_equal(transport.post_count, 1)
    assert_equal(transport.error_count, 0)
    assert_equal(flusher.flush_count, 1)


def test_the_drain_has_NOT_run_when_the_result_post_fails() raises:
    """⛔ INVERSION DETECTOR 1 — proves the drain is AFTER the result POST.

    ONE FIELD differs from the baseline: `_raise_on_post_index = 0`, so the
    transport raises from `respond_ok` for the first invocation.

    A pump that drains AFTER the POST has not reached the drain when that raise
    propagates => `flush_count == 0`.
    A pump that drains at ANY point before the POST — immediately above it, or
    at the top of the loop body right after the poll — has already drained =>
    `flush_count == 1` and this goes RED. MEASURED at both placements: 1 vs 0.

    ⇒ THIS IS THE DETECTOR THAT COVERS THE TOP-OF-LOOP PLACEMENT. Its sibling
    below does NOT (it scores 1 there and passes) — see this file's header
    table.

    WHY THE ORDER IS WORTH A TEST: a typical drain is an S3 conditional PUT.
    Pre-response it is welded into every response's
    BILLED DURATION and into the caller's latency; post-response it lands in the
    un-billed, un-frozen window between the POST and the next poll. The premise
    that would justify moving it earlier — "AWS freezes the environment the
    instant the response returns" — is managed-handler folklore and is FALSE for
    a custom runtime, whose freeze is triggered by the `next` POLL."""
    var transport = _one_event_transport()
    transport._raise_on_post_index = 0
    var dispatcher = _RecordingDispatcher()
    var flusher = _CountingFlush()
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()

    var raised = False
    try:
        _ = run_api_gateway_pump[
            _RecordingDispatcher, _Rt, _ScriptedTransport, _CountingFlush
        ](transport, dispatcher, reactor, flusher, 1)
    except e:
        raised = True
        _ = e

    assert_true(raised)
    assert_equal(transport.post_count, 0)
    # The dispatcher DID run — so the pump reached the POST, and the zero below
    # is about ordering, not about a loop that never got that far.
    assert_equal(dispatcher.dispatch_count, 1)
    assert_equal(flusher.flush_count, 0)


def test_the_drain_HAS_run_before_the_next_poll() raises:
    """⛔ INVERSION DETECTOR 2 — proves the drain is BEFORE the next poll.

    ONE FIELD differs from the baseline: `_raise_on_poll_index = 1`, so the
    SECOND `next_invocation()` raises. Invocation 0 completes normally.

    A correct pump drained invocation 0 before polling again => `flush_count == 1`.
    A pump with NO per-invocation drain — a shutdown-only `final_flush()` — scores
    0 and this goes RED. MEASURED by deleting the drain call: 0 vs 1.

    ⚠ WHAT THIS DETECTOR DOES **NOT** CATCH, stated because the first version of
    this docstring claimed it did: a drain moved to the TOP of the loop body
    (right after the poll) still scores 1 here and PASSES — measured. That arm
    is rejected by the sibling above, since top-of-loop is also before the POST.
    Neither detector alone brackets the drain position; the pair does.

    WHY: after the poll there is no "later". The process is blocked inside the
    Runtime API's `recv` and FROZEN there, and it may be destroyed without ever
    being resumed. `final_flush()` alone therefore has a loss window of the whole
    process lifetime: Lambda signals a runtime on shutdown ONLY when the function
    registers an external extension, and a timeout kill or an OOM kill is abrupt
    regardless."""
    var transport = _two_event_transport()
    transport._raise_on_poll_index = 1
    var dispatcher = _RecordingDispatcher()
    var flusher = _CountingFlush()
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()

    var raised = False
    try:
        _ = run_api_gateway_pump[
            _RecordingDispatcher, _Rt, _ScriptedTransport, _CountingFlush
        ](transport, dispatcher, reactor, flusher, 2)
    except e:
        raised = True
        _ = e

    assert_true(raised)
    assert_equal(transport.post_count, 1)
    assert_equal(flusher.flush_count, 1)


def test_the_drain_has_NOT_run_when_the_ERROR_report_fails() raises:
    """⛔ INVERSION DETECTOR 3 — the same ordering assertion as D1, on the OTHER
    EXIT of the loop body.

    ⚠ WHY D1 IS NOT ENOUGH, and this is an ASYMMETRY the file HAD rather than a
    hypothetical. The pump's per-invocation body ends in an `if converted:` with
    TWO arms — `respond_ok` and `report_error` — and every ordering detector
    before this one drives only the first. So a drain moved to sit ABOVE the
    `report_error` call while staying below `respond_ok` was caught by NOTHING:
    D1's fixture converts fine and never reaches the error arm, D2 counts a
    drain that did happen, and `test_the_drain_also_runs_on_the_error_channel`
    below asserts the drain HAPPENED on that arm but says nothing about WHEN.

    ⇒ AND THE HOLE WAS OVER THE EXPENSIVE HALF OF THE RULE. The error arm is
    the DEPLOYMENT-FAULT path: every invocation fails the same way, so every one
    of them would pay an S3 conditional PUT inside its billed duration, forever,
    for a function that is answering nobody.

    ONE FIELD differs from the error-channel fixture below:
    `_raise_on_error_index = 0`. A pump that drains after the report has not
    reached the drain when that raise propagates => `flush_count == 0`."""
    var events = List[String]()
    events.append(
        String(
            '{"version": "1.0", "rawPath": "/api/v1/items",'
            '"rawQueryString": "", "requestContext":'
            '{"http": {"method": "POST"}}}'
        )
    )
    var transport = _ScriptedTransport(events^)
    transport._raise_on_error_index = 0
    var dispatcher = _RecordingDispatcher()
    var flusher = _CountingFlush()
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()

    var raised = False
    try:
        _ = run_api_gateway_pump[
            _RecordingDispatcher, _Rt, _ScriptedTransport, _CountingFlush
        ](transport, dispatcher, reactor, flusher, 1)
    except e:
        raised = True
        _ = e

    assert_true(raised)
    assert_equal(transport.error_count, 0)
    # NON-VACUITY: the pump really did take the ERROR arm. Without these two,
    # `flush_count == 0` would also be satisfied by a loop that fell over before
    # reaching the `if converted:` at all.
    assert_equal(transport.post_count, 0)
    assert_equal(dispatcher.dispatch_count, 0)
    assert_equal(flusher.flush_count, 0)


def test_a_raising_drain_still_leaves_the_caller_ANSWERED() raises:
    """⛔ INVERSION DETECTOR 4 — the ordering read from the DRAIN's side, and the
    only assertion of `LambdaPostResponseFlush`'s stated failure contract.

    That trait's docstring says a raise from `flush_after_response` "cannot
    corrupt the caller's answer — the result was already posted, so the request
    succeeded — but it does end the runtime". Both halves of that sentence were
    asserted by NOTHING: `_CountingFlush` never raised, so the pump had never
    once been driven with a failing drain.

    ⚠ AND IT IS A GENUINELY DIFFERENT OBSERVATION FROM D1, not a restatement.
    D1 makes the TRANSPORT raise and reads the FLUSH counter; this makes the
    FLUSH raise and reads the TRANSPORT counter. Under the ordering a
    failing drain leaves `post_count == 1` — the caller was already answered and
    keeps their answer. Under a drain placed above the POST the SAME failure
    leaves `post_count == 0`: a durability error the caller cannot see and
    cannot fix silently costs them their response. That consequence is what the
    rule prevents, and this is the only case that states it.

    The raise must also PROPAGATE. Swallowing it is the fail-quiet that makes a
    function stop recording anything while every invocation still returns 200;
    ending the runtime is the recoverable choice, because Lambda replaces a
    runtime that exits."""
    var transport = _one_event_transport()
    var dispatcher = _RecordingDispatcher()
    var flusher = _CountingFlush()
    flusher._raise_on_flush_index = 0
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()

    var raised = False
    try:
        _ = run_api_gateway_pump[
            _RecordingDispatcher, _Rt, _ScriptedTransport, _CountingFlush
        ](transport, dispatcher, reactor, flusher, 1)
    except e:
        raised = True
        _ = e

    # The raise ENDED the runtime rather than being swallowed.
    assert_true(raised)
    # ⭐ THE ORDERING ASSERTION: the caller was answered BEFORE the drain failed.
    assert_equal(transport.post_count, 1)
    assert_equal(transport.error_count, 0)
    # The drain WAS reached (the counter counts attempts), so the `post_count
    # == 1` above is a statement about ORDER and not about a drain that never
    # ran at all.
    assert_equal(flusher.flush_count, 1)


def test_the_drain_also_runs_on_the_error_channel() raises:
    """An invocation that could not be CONVERTED still ended, and the records
    explaining why are exactly the ones worth not losing.

    ONE FIELD differs from the baseline event: `version` is `"1.0"`."""
    var events = List[String]()
    events.append(
        String(
            '{"version": "1.0", "rawPath": "/api/v1/items",'
            '"rawQueryString": "", "requestContext":'
            '{"http": {"method": "POST"}}}'
        )
    )
    var transport = _ScriptedTransport(events^)
    var dispatcher = _RecordingDispatcher()
    var flusher = _CountingFlush()
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()

    var handled = run_api_gateway_pump[
        _RecordingDispatcher, _Rt, _ScriptedTransport, _CountingFlush
    ](transport, dispatcher, reactor, flusher, 1)

    assert_equal(handled, 1)
    assert_equal(transport.error_count, 1)
    assert_equal(transport.post_count, 0)
    assert_equal(dispatcher.dispatch_count, 0)
    assert_equal(flusher.flush_count, 1)


def test_the_no_drain_conformer_is_usable_and_does_nothing() raises:
    """`NoLambdaFlush` — the explicit "this binary buffers nothing" conformer.
    The pump must run identically with it in place."""
    var transport = _one_event_transport()
    var dispatcher = _RecordingDispatcher()
    var flusher = NoLambdaFlush()
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()

    var handled = run_api_gateway_pump[
        _RecordingDispatcher, _Rt, _ScriptedTransport, NoLambdaFlush
    ](transport, dispatcher, reactor, flusher, 1)

    assert_equal(handled, 1)
    assert_equal(transport.post_count, 1)


# =============================================================================
# §3 — the two failure channels.
# =============================================================================

def test_an_unconvertible_event_never_reaches_the_dispatcher() raises:
    """A misconfigured integration takes the invocation ERROR channel, so it
    lands in the function's error metric instead of looking like a trickle of
    server errors indistinguishable from load.

    Asserts BOTH halves: the error channel was used AND the result channel was
    not — a pump that reported the error and ALSO posted a 500 would satisfy
    either half alone."""
    var events = List[String]()
    events.append(String('{"version": "2.0", "requestContext": {"a": 1}}'))
    var transport = _ScriptedTransport(events^)
    var dispatcher = _RecordingDispatcher()
    var flusher = _CountingFlush()
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()

    _ = run_api_gateway_pump[
        _RecordingDispatcher, _Rt, _ScriptedTransport, _CountingFlush
    ](transport, dispatcher, reactor, flusher, 1)

    assert_equal(transport.error_count, 1)
    assert_equal(transport.post_count, 0)
    assert_equal(dispatcher.dispatch_count, 0)
    assert_true(transport.last_error.byte_length() > 0)


def test_a_dispatcher_raise_becomes_a_500_RESULT_not_an_error() raises:
    """⛔ THE SERVER PARITY. An application error
    gets the same answer whether a socket or API Gateway delivered the request.

    ONE FIELD differs from the baseline: `_raise_on_dispatch = True`.

    Routing this to the error channel instead would make Lambda RETRY the
    invocation — and a retried non-idempotent verb performs its side effect twice."""
    var transport = _one_event_transport()
    var dispatcher = _RecordingDispatcher()
    dispatcher._raise_on_dispatch = True
    var flusher = _CountingFlush()
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()

    var handled = run_api_gateway_pump[
        _RecordingDispatcher, _Rt, _ScriptedTransport, _CountingFlush
    ](transport, dispatcher, reactor, flusher, 1)

    assert_equal(handled, 1)
    assert_equal(transport.post_count, 1)
    assert_equal(transport.error_count, 0)

    var v = parse_json_value(transport.last_payload)
    assert_equal(v.get(String("statusCode")).text, String("500"))
    # ⚠ The detail is PRINTED, not returned — an upstream error string echoed to
    # a customer is how an internal ARN or table name leaves the boundary.
    assert_equal(v.get(String("body")).as_string(), String('{"error": "internal"}'))
    assert_equal(flusher.flush_count, 1)


# =============================================================================
# §4 — what actually reaches the dispatcher, end to end through the pump.
# =============================================================================

def test_the_dispatcher_receives_the_converted_fields() raises:
    """The whole path, not the converter in isolation: event -> pump -> the real
    `dispatch[RT](reactor, req)` seam -> the fields the handler reads.

    NON-EMPTY ARM: every assertion names a VALUE. A pump that handed the
    dispatcher an empty `HttpRequest()` would still be "a request reaching the
    dispatcher"."""
    var transport = _one_event_transport()
    var dispatcher = _RecordingDispatcher()
    var flusher = _CountingFlush()
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()

    _ = run_api_gateway_pump[
        _RecordingDispatcher, _Rt, _ScriptedTransport, _CountingFlush
    ](transport, dispatcher, reactor, flusher, 1)

    assert_equal(dispatcher.dispatch_count, 1)
    assert_equal(dispatcher.seen_method, HTTP_METHOD_POST)
    assert_equal(dispatcher.seen_path, String("/api/v1/items"))
    assert_equal(dispatcher.seen_query, String("tag=a&tag=b"))
    assert_equal(dispatcher.seen_body_len, 2)
    assert_equal(
        dispatcher.seen_headers[String("x-request-id")], String("req-a")
    )

    var payload = parse_json_value(transport.last_payload)
    assert_equal(payload.get(String("statusCode")).text, String("200"))
    assert_equal(
        payload.get(String("body")).as_string(), String('{"handled": true}')
    )


def test_the_authorizer_identity_reaches_the_dispatcher_and_the_forgery_does_not() raises:
    """⛔ THE SECURITY PROPERTY, asserted where it matters — at the DISPATCHER,
    after the whole pump, not at the converter's return value.

    The scripted event carries BOTH a client-supplied
    `x-komira-authorizer-orgid: org-victim` AND a real authorizer context
    `{"orgId": "org-real"}`. The handler must act on `org-real`.

    FAILS ON: injecting the authorizer context BEFORE copying client headers
    (the client's copy then overwrites it); and on stripping only the keys about
    to be overwritten (which passes here and fails
    `test_a_forged_authorizer_header_never_reaches_the_dispatcher` in
    test_apigw_v2.mojo — the no-authorizer route)."""
    var transport = _one_event_transport()
    var dispatcher = _RecordingDispatcher()
    var flusher = _CountingFlush()
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()

    _ = run_api_gateway_pump[
        _RecordingDispatcher, _Rt, _ScriptedTransport, _CountingFlush
    ](transport, dispatcher, reactor, flusher, 1)

    var key = String(AUTHORIZER_HEADER_PREFIX) + String("orgid")
    assert_true(key in dispatcher.seen_headers)
    assert_equal(dispatcher.seen_headers[key], String("org-real"))
    assert_false(dispatcher.seen_headers[key] == String("org-victim"))


# =============================================================================
# §5 — the runtime conformer + the init-error announcement.
# =============================================================================

def test_the_runtime_is_one_inline_worker_and_its_own_model() raises:
    """`AwsLambdaRuntime` reports one worker (a Lambda environment serves one
    invocation at a time) and a sentinel DISTINCT from Cloud Run's — the two
    place the drain edge at different instants, so sharing a sentinel would
    inherit gating written for the wrong edge."""
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    assert_equal(rt.worker_count(), 1)
    assert_equal(_Rt.RUNTIME_MODEL, MODEL_AWS_LAMBDA)
    assert_false(_Rt.RUNTIME_MODEL == MODEL_CLOUD_RUN)
    assert_false(_Rt.TASKS_ARE_THREAD_PINNED)


def test_a_nonzero_worker_index_raises_rather_than_being_clamped() raises:
    """Silently accepting worker 3 on a one-worker runtime would let a caller
    believe it was driving a reactor that does not exist."""
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    var raised = False
    try:
        _ = rt.poll_completions(3, Int32(0))
    except e:
        raised = True
        _ = e
    assert_true(raised)


def test_an_init_failure_is_announced_on_the_init_error_channel() raises:
    """A runtime that dies before its first poll is indistinguishable from one
    nobody invoked. `announce_init_failure` POSTs a NAMED line naming the
    STAGE, and never raises."""
    var transport = _one_event_transport()
    var msg = announce_init_failure[_ScriptedTransport](
        transport, String("build-dispatcher"), String("required flag --upstream-url missing")
    )
    assert_equal(transport.init_error_count, 1)
    assert_true(msg.startswith(String("lambda-init-failed: build-dispatcher: ")))
    assert_equal(transport.last_error, msg)


def main() raises:
    test_the_drain_runs_once_per_invocation()
    test_the_drain_has_NOT_run_when_the_result_post_fails()
    test_the_drain_HAS_run_before_the_next_poll()
    test_the_drain_has_NOT_run_when_the_ERROR_report_fails()
    test_a_raising_drain_still_leaves_the_caller_ANSWERED()
    test_the_drain_also_runs_on_the_error_channel()
    test_the_no_drain_conformer_is_usable_and_does_nothing()

    test_an_unconvertible_event_never_reaches_the_dispatcher()
    test_a_dispatcher_raise_becomes_a_500_RESULT_not_an_error()

    test_the_dispatcher_receives_the_converted_fields()
    test_the_authorizer_identity_reaches_the_dispatcher_and_the_forgery_does_not()

    test_the_runtime_is_one_inline_worker_and_its_own_model()
    test_a_nonzero_worker_index_raises_rather_than_being_clamped()
    test_an_init_failure_is_announced_on_the_init_error_channel()

    print("test_pump_flush_ordering: ALL PASS")
