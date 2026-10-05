# =============================================================================
# pump.mojo — the Lambda invoke loop, driving a `RequestDispatcher` that does
#   not know it is on Lambda.
# =============================================================================
# A Lambda that receives an API Gateway message handles it exactly as a server
# handles a request: the same `RequestDispatcher` conformer serves both, and
# nothing in it is adapted, wrapped or re-registered for Lambda.
#
# The falsifiers in `tests/` drive a RECORDING `RequestDispatcher` conformer and
# assert on the FIELDS it received; a test here compiles against this library
# and its own deps and nothing else, so no production dispatcher is reached
# from this directory.
#
# =============================================================================
# THE TRANSPORT IS A TRAIT, AND THAT IS WHAT MAKES ANY OF THIS FALSIFIABLE
# =============================================================================
# A Lambda Runtime API client dials `AWS_LAMBDA_RUNTIME_API` (set by the Lambda
# platform) over loopback HTTP. A pump hardcoded to one can only be exercised
# inside a Lambda sandbox — i.e. after deploy, in the cloud, by hand. So the
# pump is parametric over `LambdaInvocationTransport`, the binary adapts its
# Runtime API client to it (four forwarding methods), and the falsifiers hand it
# a SCRIPTED transport that replays a real API-Gateway-shaped event with no
# socket, no cloud and no AWS. This package reads no environment variable.
#
# =============================================================================
# TWO FAILURE CLASSES, TWO CHANNELS, AND CONFLATING THEM IS THE BUG
# =============================================================================
# The Runtime API offers an invocation ERROR channel and an ordinary RESULT
# channel, and it matters which a failure takes:
#
#   * **The event could not be CONVERTED** (not payload 2.0, no
#     `requestContext.http`, a base64 body that does not decode) -> the
#     invocation ERROR channel. This is a MISCONFIGURED INTEGRATION, not a bad
#     request: no caller can fix it and every invocation will fail the same way.
#     It must show up in the function's error metric and page somebody. Answering
#     500 instead would render a permanently broken deployment as a trickle of
#     server errors indistinguishable from load.
#
#   * **The dispatcher RAISED** -> a 500 RESULT, exactly as the HTTP server's
#     serving path does when a handler raises. This parity is what makes the
#     same request reaching the same dispatcher get the same answer whether a
#     socket or API Gateway delivered it. Routing it to the error channel
#     instead would make Lambda RETRY an application error that the server
#     would simply have reported, and a retried non-idempotent verb performs
#     its side effect twice.
#
# =============================================================================
# THE DRAIN RUNS *AFTER* THE RESULT IS POSTED AND *BEFORE* THE NEXT POLL
# =============================================================================
# This ordering is the reason `LambdaPostResponseFlush` exists, and the two ways
# of getting it wrong are both silent.
#
#   poll `next`  ->  convert  ->  dispatch  ->  POST result  ->  FLUSH  ->  poll
#                                                               ^^^^^
#                                       the only correct place, and it is HERE
#
# WHY NOT EARLIER (before the result POST):
#   A typical drain is an object-store write (for example an S3 conditional
#   PUT of buffered log records). Putting it before the POST welds that round
#   trip into every response's BILLED DURATION and into the caller's latency.
#   Post-response it lands in the un-billed window. The premise that would
#   justify moving it earlier — "AWS freezes the environment the instant the
#   response returns" — is true of managed handlers and FALSE for a custom
#   runtime: the freeze is triggered by the `GET /invocation/next` POLL,
#   because that is where a custom runtime blocks.
#
# WHY NOT LATER (after the next poll, or only at shutdown):
#   After the poll there is no "later" — the process is frozen inside `recv` and
#   may never be resumed. And a final flush at shutdown alone has a loss window
#   of the whole process lifetime: Lambda signals a runtime on shutdown ONLY
#   when the function has a registered external extension; a timeout kill and
#   an OOM kill are abrupt either way.
#
# The structural twin is a Cloud Run serve loop that flushes AFTER writing the
# response. `tests/test_pump_flush_ordering.mojo` carries two detectors that
# between them go RED on every misplacement, and its header records WHICH
# detector caught WHICH — measured, because the obvious division of labour
# there is not the real one.
#
# THE FLUSH IS A TRAIT FOR THE SAME LAYERING REASON AS THE TRANSPORT. The real
# drain lives in a consumer layered above this package, so the pump
# parameterises over `LambdaPostResponseFlush` and the binary supplies a
# one-method adapter. A binary with no drain passes `NoLambdaFlush`, which does
# nothing and says so.
#
# =============================================================================
# AN INIT FAILURE IS ANNOUNCED, NOT SWALLOWED — `announce_init_failure`
# =============================================================================
# The init-error channel is used BEFORE any poll, because a runtime that dies
# silently produces a function that times out with no reason in the log. A
# binary that fails to build its dispatcher — a missing required flag, an unset
# AWS credential — must not simply exit: from outside, a runtime that never
# polled is indistinguishable from one nobody invoked. `announce_init_failure`
# prints a NAMED line and POSTs the same text to `/runtime/init/error`, and if
# that POST also fails it says so rather than losing the original cause.
#
# =============================================================================
# A SECOND ENTRY POINT — `run_api_gateway_and_tick_pump` — AND WHY IT IS A
#   SIBLING RATHER THAN A FLAG ON THE FIRST
# =============================================================================
# EventBridge Scheduler CANNOT call an HTTPS URL (the argument is in
# `eventbridge_tick.mojo`'s header), so a scheduled tick arrives at this
# function as a BARE Invoke whose whole payload is the schedule's
# `Target.Input`:
#
#     {"httpMethod":"POST","path":"/internal/tick/reconcile"}
#
# `run_api_gateway_pump` hands that to `api_gateway_v2_event_to_request`, which
# REFUSES it — correctly, it carries no `version` — and the refusal takes the
# invocation ERROR channel as a deployment fault. Every tick, forever, as a
# Lambda error and never as a dispatch.
#
# `run_api_gateway_and_tick_pump` is the loop that serves BOTH shapes. It
# CLASSIFIES first (`classify_lambda_event`) and then calls exactly one
# converter; it never tries one and falls back to the other. The argument for
# that discipline is `apigw_v2.mojo`'s ("a converter that accepts both accepts a
# malformed one") and its consequence here is sharper than a mis-route: the
# fallback reader, handed a TRUNCATED 2.0 event, reports a TICK — and a tick
# fires a backstop, which is a write nobody asked for.
#
# AND `run_api_gateway_pump` IS UNTOUCHED BY IT — not refactored, not wrapped,
# not given a parameter. Two reasons, and the second is the one that decided it:
#
#   1. A function that serves API Gateway and only API Gateway should not gain
#      the ability to serve a second shape because a sibling needed it.
#   2. The obvious cleanup — factor the shared loop body out of both — MOVES THE
#      DRAIN LINE, and the drain's position is held only by
#      `tests/test_pump_flush_ordering.mojo`'s detectors, which are written
#      against THIS function. A refactor that preserved behaviour would still
#      leave the rule asserted about a wrapper and unasserted about the loop.
#
# => SO THE LOOP BODY IS DUPLICATED, DELIBERATELY, AND THE DUPLICATION IS PAID FOR
#   IN TESTS RATHER THAN IN PROSE: `tests/test_eventbridge_tick.mojo` re-asserts
#   the drain position for the SECOND loop, exactly as
#   `tests/test_authorizer_pump.mojo` does for the THIRD. A rule that holds in
#   one loop is not a rule that holds in the code.
#
# ENCAPSULATION: owned values across every boundary; the reactor is a `mut`
# borrow threaded per invocation and never stored. No `UnsafePointer` crosses
# any boundary; no wildcard origin.
# =============================================================================

from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime

from komira_http_core.codec.types import HttpRequest, HttpResponse
from komira_http_server.dispatch import RequestDispatcher

from .apigw_v2 import (
    AuthorizerHeaderPrefix,
    api_gateway_v2_event_to_request,
    response_to_api_gateway_v2,
)
from .eventbridge_tick import (
    LAMBDA_EVENT_KIND_SCHEDULED_TICK,
    classify_lambda_event,
    eventbridge_tick_event_to_request,
)


struct LambdaInvokeEvent(Movable, Deinitable):
    """One invocation: the id a result must be addressed to, and the raw event.

    ⚠ A binary's Runtime API client will usually have its own invocation type;
    this one is declared here deliberately so the pump depends on no client
    (see the header). The adapter that converts one to the other lives at the
    binary, where the dependency edge is allowed to point that way."""

    var request_id: String
    var event: String

    def __init__(out self, var request_id: String, var event: String):
        self.request_id = request_id^
        self.event = event^


trait LambdaInvocationTransport(Movable, Deinitable):
    """The Lambda Runtime API, as the pump needs it — four verbs, no transport.

    A Runtime API client conforms via a forwarding adapter at the binary; a test conforms
    with a scripted list and assertion counters. Both drive the SAME pump, which
    is the only way the loop's behaviour can be asserted outside the cloud."""

    def next_invocation(mut self) raises -> LambdaInvokeEvent:
        """BLOCK until the next invocation. RAISES if the poll itself failed —
        which the pump treats as unrecoverable, never as a reason to re-poll."""
        ...

    def respond_ok(mut self, request_id: String, payload: String) raises:
        """POST the successful result JSON for `request_id`."""
        ...

    def report_error(mut self, request_id: String, message: String) raises:
        """POST a handler failure for `request_id` (the invocation ERROR
        channel)."""
        ...

    def report_init_error(mut self, message: String) raises:
        """POST a failure that happened BEFORE the first poll."""
        ...


trait LambdaPostResponseFlush(Movable, Deinitable):
    """A durability drain the pump runs at exactly ONE point in the loop.

    ⛔ THAT POINT IS: after the invocation result has been POSTed, and before the
    next `/invocation/next` poll. See this file's header for why neither
    neighbouring instant works — earlier bills the caller for an S3 round trip,
    later runs inside a frozen sandbox or not at all.

    ONE verb, and it takes nothing: the pump has no business knowing what is
    being drained, and the drain has no business knowing which invocation just
    ended. That narrowness is what lets the real conformer be a ~5-line adapter
    over the binary's own log drain, with no
    OPEN -> CLOSED edge anywhere."""

    def flush_after_response(mut self) raises -> Int:
        """Drain whatever is buffered; return how many records were published.

        ⚠ A RAISE PROPAGATES OUT OF THE PUMP, and that is deliberate. It cannot
        corrupt the caller's answer — the result was already posted, so the
        request succeeded — but it does end the runtime, and Lambda replaces an
        exited runtime. That is the same failure semantics a failed poll gets,
        and it is the fail-LOUD choice: swallowing a durability error is how a
        function silently stops recording anything."""
        ...


struct NoLambdaFlush(LambdaPostResponseFlush, Movable, Deinitable):
    """The explicit no-drain conformer, for a binary that buffers nothing.

    ⚠ NAMED, not defaulted. A pump whose flush parameter could be omitted would
    make "this function has no durability drain" the invisible case; here it is
    a type the binary had to write down."""

    var _placeholder: UInt8

    def __init__(out self):
        self._placeholder = UInt8(0)

    def flush_after_response(mut self) raises -> Int:
        return 0


def run_api_gateway_pump[
    D: RequestDispatcher,
    RT: Runtime,
    T: LambdaInvocationTransport,
    F: LambdaPostResponseFlush,
](
    mut transport: T,
    mut dispatcher: D,
    mut reactor: Reactor[RT.Sink],
    mut flush: F,
    authorizer_header_prefix: AuthorizerHeaderPrefix,
    max_invocations: Int,
) raises -> Int:
    """Pump Lambda invocations through `dispatcher`, returning the count handled.

    `authorizer_header_prefix` is handed to `api_gateway_v2_event_to_request`
    unchanged: the header namespace the authorizer's context arrives under, and
    under which client-supplied headers are destroyed (`apigw_v2.mojo` §3).

    `max_invocations < 0` runs forever (the deployed shape — Lambda freezes the
    process between invocations and tears it down when the sandbox retires). A
    non-negative value stops after that many, which is what lets a falsifier
    drive a REAL dispatcher over a scripted loop and then assert.

    ⛔ A FAILED POLL EXITS THE LOOP RATHER THAN RETRYING, and the reason is
    measured, not theoretical: an earlier `continue` form spun on `ECONNREFUSED` as fast as the kernel could
    return it, burning billed CPU for the whole function timeout with a log line
    per iteration. A poll that fails is not a condition this process can fix —
    Lambda REPLACES an exited runtime, which is both the recovery and the thing
    the platform reports. The raise propagates to `main`, which exits non-zero.

    ⚠ THE REACTOR IS THREADED, NOT OWNED. It is the same `mut` borrow the HTTP
    server passes to `dispatch`, so a handler doing async I/O parks on the
    caller's reactor exactly as it would when serving. The pump replaces the
    SOCKET, not the seam.

    The two failure channels, per the header — an UNCONVERTIBLE event reaches
    `report_error` and NEVER the dispatcher (a deployment fault); a dispatcher
    RAISE becomes a 500 result (an application error, exactly as on the serving
    path). Both arms are falsified, and the second is what keeps a non-idempotent
    verb from being retried by the platform.

    The DRAIN runs once per invocation, after the result POST and before the next
    poll — on BOTH channels, because an invocation that failed to convert is
    still an invocation that ended, and the records explaining why are exactly
    the ones worth not losing.
    """
    var handled = 0
    while max_invocations < 0 or handled < max_invocations:
        var inv = transport.next_invocation()
        var request_id = inv.request_id.copy()
        var event = inv.event.copy()

        var converted = True
        var convert_err = String("")
        var response = HttpResponse(status=Int32(500))
        try:
            var req = api_gateway_v2_event_to_request(
                event, authorizer_header_prefix
            )
            try:
                response = dispatcher.dispatch[RT](reactor, req^)
            except de:
                response = _internal_error_response(String(de))
        except ce:
            converted = False
            convert_err = String(ce)

        if converted:
            transport.respond_ok(
                request_id, response_to_api_gateway_v2(response^)
            )
        else:
            # ⛔ NOT a 500 result. An unconvertible event is a deployment fault;
            # it must land in the function's error metric, not look like load.
            transport.report_error(request_id, convert_err^)

        # ─────────────────────────────────────────────────────────────────────
        # ⛔ THE DRAIN. Its position — after the POST above, before the `while`
        #    reaches `next_invocation()` again — is the whole rule; see the
        #    header for why each neighbouring instant is
        #    wrong. Two detectors in `tests/test_pump_flush_ordering.mojo`
        #    bracket it, using NO shared state (the transport and the flush hook
        #    are independent `mut` borrows and cannot see each other):
        #      * a transport that raises from `respond_ok` must find the drain
        #        NOT yet run — MEASURED RED (1 vs 0) when this line is moved
        #        above the POST, and equally when it is moved to the top of the
        #        loop body, since that is also before the POST;
        #      * a transport that raises from the SECOND poll must find it
        #        ALREADY run — MEASURED RED (0 vs 1) when this line is deleted
        #        in favour of a shutdown-only flush.
        # ─────────────────────────────────────────────────────────────────────
        _ = flush.flush_after_response()

        handled += 1
    return handled


def run_api_gateway_and_tick_pump[
    D: RequestDispatcher,
    RT: Runtime,
    T: LambdaInvocationTransport,
    F: LambdaPostResponseFlush,
](
    mut transport: T,
    mut dispatcher: D,
    mut reactor: Reactor[RT.Sink],
    mut flush: F,
    authorizer_header_prefix: AuthorizerHeaderPrefix,
    max_invocations: Int,
) raises -> Int:
    """The SIBLING of `run_api_gateway_pump` that also serves EventBridge
    Scheduler ticks. Returns the count of invocations handled.
    `authorizer_header_prefix` is as for `run_api_gateway_pump`; only the API
    Gateway arm uses it, because a tick carries no headers.

    ⛔ IT CLASSIFIES BEFORE IT CONVERTS, AND THAT IS THE WHOLE DIFFERENCE.
    `classify_lambda_event` reads ONE field — `version`, present => an API
    Gateway payload, absent => a scheduled tick — and the chosen converter is
    then the only one called. There is no fallback arm and none may be added:
    handed a TRUNCATED 2.0 event, a "try apigw, then try tick" reader does not
    report the truncation, it reports A TICK, and the tick arm's job is to fire a
    BACKSTOP. `apigw_v2.mojo`'s header documents the same failure one shape
    earlier ("a wrong guess routes the request to the wrong handler instead of
    reporting the truncation"); here the wrong guess performs a write.

    ⚠ THE CLASSIFIER IS NOT A TRUSTED PREAMBLE. Both converters re-assert their
    own discriminator — `api_gateway_v2_event_to_request` still refuses a payload
    with no `version`, `eventbridge_tick_event_to_request` still refuses one that
    HAS it — because both are public and both are called directly elsewhere.
    Nothing may be deleted from either on the grounds that this loop checked it.

    EVERYTHING ELSE IS `run_api_gateway_pump`'s BEHAVIOUR, UNCHANGED AND FOR ITS
    REASONS (which are in this file's header, not restated here):
      * a failed POLL exits the loop rather than retrying;
      * an UNCONVERTIBLE event — including a payload that is neither shape —
        reaches `report_error` and NEVER the dispatcher, because it is a
        misconfigured integration and not a bad request;
      * a DISPATCHER RAISE becomes a 500 RESULT, so the platform does not RETRY a
        non-idempotent verb;
      * the DRAIN runs once per invocation, on both channels, after the result
        POST and before the next poll.

    ⚠ THE RESIDUAL, and it is `eventbridge_tick.mojo` §6 restated at the loop
    that causes it: a TICK answered 5xx is posted on the RESULT channel, so
    EventBridge records a SUCCESSFUL invoke and a backstop that fails on every
    pass looks green in the schedule's metrics. Routing a tick 5xx to the error
    channel would make it visible and would also hand it to EventBridge's retry
    policy — which a schedule that does not model it has RESET to the service
    default on every update. That is a decision
    about the SCHEDULE and it is not taken here.
    """
    var handled = 0
    while max_invocations < 0 or handled < max_invocations:
        var inv = transport.next_invocation()
        var request_id = inv.request_id.copy()
        var event = inv.event.copy()

        var converted = True
        var convert_err = String("")
        var response = HttpResponse(status=Int32(500))
        try:
            # ⛔ CLASSIFY, THEN CONVERT — ONE converter, chosen, never tried.
            var kind = classify_lambda_event(event)
            var req: HttpRequest
            if kind == LAMBDA_EVENT_KIND_SCHEDULED_TICK:
                req = eventbridge_tick_event_to_request(event)
            else:
                req = api_gateway_v2_event_to_request(
                    event, authorizer_header_prefix
                )
            try:
                response = dispatcher.dispatch[RT](reactor, req^)
            except de:
                response = _internal_error_response(String(de))
        except ce:
            converted = False
            convert_err = String(ce)

        if converted:
            transport.respond_ok(
                request_id, response_to_api_gateway_v2(response^)
            )
        else:
            # ⛔ NOT a 500 result — same split as `run_api_gateway_pump`. A
            # payload that is neither shape is a deployment fault: nobody can fix
            # it from outside and every invocation fails identically, so it must
            # land in the function's error metric rather than look like load.
            transport.report_error(request_id, convert_err^)

        # ─────────────────────────────────────────────────────────────────────
        # ⛔ THE DRAIN, at the SAME position as the two sibling loops:
        #    after the POST above, before the `while` reaches
        #    `next_invocation()` again, on BOTH channels. The argument is in this
        #    file's header. ⚠ THE DETECTORS IN `tests/test_pump_flush_ordering.
        #    mojo` ARE WRITTEN AGAINST `run_api_gateway_pump` AND SAY NOTHING
        #    ABOUT THIS LOOP — moving this line turns none of them red.
        #    `tests/test_eventbridge_tick.mojo` re-asserts the position here, for
        #    the same reason `tests/test_authorizer_pump.mojo` re-asserts it for
        #    the authorizer loop: a rule that holds in one loop is not a rule
        #    that holds in the code.
        # ─────────────────────────────────────────────────────────────────────
        _ = flush.flush_after_response()

        handled += 1
    return handled


def announce_init_failure[
    T: LambdaInvocationTransport,
](mut transport: T, stage: String, cause: String) -> String:
    """Make an init failure LOUD and NAMED, then return the message it announced.

    ⛔ THE FAILURE MODE THIS EXISTS TO PREVENT: a binary whose dispatcher could
    not be built exits, Lambda reports nothing useful, and the function looks
    exactly like one nobody invoked. The `stage` names WHICH step failed
    (`build-dispatcher`, `read-config`) so the log line is actionable without a
    rebuild.

    It NEVER raises. A reporting failure is itself printed, with the ORIGINAL
    cause still in the line — losing the real reason while reporting that we
    could not report it is the exact fail-quiet this function is against. The
    caller exits non-zero afterwards; that decision is the binary's, not this
    library's."""
    var message = (
        String("lambda-init-failed: ") + stage + String(": ") + cause
    )
    print(message)
    try:
        transport.report_init_error(message)
    except e:
        # The channel is unreachable too. Say BOTH things — the original cause
        # is the one somebody needs.
        print(
            String(
                "lambda-init-failed: could not reach the init-error channel"
                " either ("
            )
            + String(e)
            + String(") — the original cause was: ")
            + message
        )
    return message^


def _internal_error_response(detail: String) -> HttpResponse:
    """The 500 an uncaught dispatcher raise becomes.

    ⚠ THE DETAIL IS PRINTED, NOT RETURNED IN THE BODY. An upstream error string echoed to a
    customer is how an internal ARN, a table name or a role name leaves the
    boundary. The operator gets the text in the log; the caller gets a code."""
    print(String("lambda-dispatch-raised: ") + detail)
    var r = HttpResponse(status=Int32(500))
    r.headers[String("content-type")] = String("application/json")
    var body = String('{"error": "internal"}')
    var bs = body.as_bytes()
    for i in range(len(bs)):
        r.body.append(bs[i])
    r.headers[String("content-length")] = String(len(r.body))
    return r^
