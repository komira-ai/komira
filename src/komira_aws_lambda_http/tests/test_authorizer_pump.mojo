# =============================================================================
# tests/test_authorizer_pump.mojo — the AUTHORIZER invoke loop: which channel
#   each answer takes, and WHERE the drain runs.
# =============================================================================
# The rules under test:
#
#   1. THREE ANSWERS, TWO CHANNELS (`apigw_authorizer.mojo` §3):
#        ALLOW / DENY      -> `respond_ok`  (200 / 403 at the gateway)
#        UNAVAILABLE,
#        a conformer raise,
#        an unparseable event,
#        every unknown ordinal
#                          -> `report_error` (500, and NOT CACHED)
#
#   2. THE DRAIN POSITION: after the result is POSTed, before
#      the next `/invocation/next` poll. Same rule as `run_api_gateway_pump`,
#      re-asserted here because this is a SECOND loop and a rule that holds in
#      one loop is not a rule that holds in the code.
#
# ⛔⛔ THE ASSERTION THAT MATTERS MOST IS A NEGATIVE ONE, AND IT IS MADE ON EVERY
# REFUSAL CASE: `post_count == 0`. "The error channel was used" does not by
# itself prove that no verdict reached API Gateway — a loop that reported an
# error AND posted `{"isAuthorized": true}` would satisfy an `error_count == 1`
# assertion. So each refusal case pins BOTH counters, and
# `last_payload == ""` besides.
#
# ⛔ AND `authorize_count` IS PINNED ON THE PARSE-FAILURE ARM. An unparseable
# event must never reach the decider: a decider handed a
# default-constructed event would find no credential and deny, which LOOKS
# correct and would hide the misconfiguration inside the deny rate forever.
#
# ⚠ HOW THE ORDERING IS OBSERVED WITHOUT SHARED STATE — the technique is
# `test_pump_flush_ordering.mojo`'s and is reused rather than reinvented: the
# transport and the flush hook are two INDEPENDENT `mut` borrows, so the order
# is read off WHETHER the flush counter moved before a deliberately-raising
# transport call, never off a shared journal.
#
#   raise from `respond_ok`                  -> a correct pump has NOT drained
#   raise from `report_error`                -> a correct pump has NOT drained
#   raise from the SECOND `next_invocation`  -> a correct pump HAS drained inv 0
#
# Each fixture differs from the happy path in EXACTLY ONE field.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_json import parse_json_value

from komira_aws_lambda_http.apigw_authorizer import (
    AUTHZ_ANSWER_ALLOW,
    AUTHZ_ANSWER_DENY,
    AUTHZ_ANSWER_UNAVAILABLE,
    ApiGatewayAuthorizerEvent,
    AuthorizerAnswer,
)
from komira_aws_lambda_http.authorizer_pump import (
    LambdaAuthorizer,
    run_authorizer_pump,
)
from komira_aws_lambda_http.pump import (
    LambdaInvocationTransport,
    LambdaInvokeEvent,
    LambdaPostResponseFlush,
    NoLambdaFlush,
)


# =============================================================================
# §1 — the scripted instruments.
# =============================================================================

struct _ScriptedTransport(
    LambdaInvocationTransport, Movable, Deinitable
):
    """A `LambdaInvocationTransport` with no socket. Three fault injectors, each
    defaulting to -1 (never); a negative fixture sets exactly ONE."""

    var _events: List[String]
    var _next_index: Int
    var post_count: Int
    var error_count: Int
    var init_error_count: Int
    var last_payload: String
    var last_error: String
    var _raise_on_poll_index: Int
    var _raise_on_post_index: Int
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
    """Counts drains, and cannot see the transport. That blindness is the point:
    the ORDER is read off whether this counter moved before a raising transport
    call."""

    var flush_count: Int

    def __init__(out self):
        self.flush_count = 0

    def flush_after_response(mut self) raises -> Int:
        self.flush_count += 1
        return 3


struct _ScriptedAuthorizer(
    LambdaAuthorizer, Movable, Deinitable
):
    """A real `LambdaAuthorizer` that answers from a scripted ordinal list and
    records what it was handed.

    ⚠ IT IS NOT A PRODUCTION AUTHORIZER, and it cannot be: a test here compiles
    against THIS library plus this library's own deps and nothing else, and a
    production conformer lives in a consumer layered above it, which falsifies
    its own decisions; what THIS file proves is the loop's channel routing, which is a property of the
    loop and not of any decider."""

    var _answers: List[Int]
    var _next: Int
    var authorize_count: Int
    var seen_route_key: String
    var seen_authorization: String
    var _raise_on_authorize: Bool

    def __init__(out self, var answers: List[Int]):
        self._answers = answers^
        self._next = 0
        self.authorize_count = 0
        self.seen_route_key = String("")
        self.seen_authorization = String("")
        self._raise_on_authorize = False

    def authorize(
        mut self, event: ApiGatewayAuthorizerEvent
    ) raises -> AuthorizerAnswer:
        self.authorize_count += 1
        self.seen_route_key = event.route_key.copy()
        self.seen_authorization = event.header(String("authorization"))
        if self._raise_on_authorize:
            raise Error("scripted-authorizer: the decider raised")

        var kind = AUTHZ_ANSWER_DENY
        if self._next < len(self._answers):
            kind = self._answers[self._next]
        self._next += 1

        var out = AuthorizerAnswer(kind)
        if kind == AUTHZ_ANSWER_ALLOW:
            out.add_context(String("subject_id"), String("subject-proven"))
            out.add_context(String("session_id"), String("session-proven"))
        return out^


def _event_json() -> String:
    return String(
        '{'
        '"version": "2.0",'
        '"type": "REQUEST",'
        '"routeArn":'
        ' "arn:aws:execute-api:us-east-1:111122223333:abc123/$default/POST/v1/messages",'
        '"identitySource": ["Bearer tok-live"],'
        '"routeKey": "POST /v1/messages",'
        '"rawPath": "/v1/messages",'
        '"headers": {"Authorization": "Bearer tok-live"},'
        '"requestContext": {"requestId": "gw-req-9",'
        '"http": {"method": "POST"}}'
        '}'
    )


def _proxy_event_json() -> String:
    """`_event_json()` with `"type": "REQUEST",` REMOVED — one field, and it is
    the field that makes it a PROXY event rather than an authorizer event."""
    return String(
        '{'
        '"version": "2.0",'
        '"routeArn":'
        ' "arn:aws:execute-api:us-east-1:111122223333:abc123/$default/POST/v1/messages",'
        '"identitySource": ["Bearer tok-live"],'
        '"routeKey": "POST /v1/messages",'
        '"rawPath": "/v1/messages",'
        '"headers": {"Authorization": "Bearer tok-live"},'
        '"requestContext": {"requestId": "gw-req-9",'
        '"http": {"method": "POST"}}'
        '}'
    )


def _one(var events: List[String]) -> _ScriptedTransport:
    return _ScriptedTransport(events^)


def _events(n: Int) -> List[String]:
    var out = List[String]()
    for _ in range(n):
        out.append(_event_json())
    return out^


def _answers1(a: Int) -> _ScriptedAuthorizer:
    """⚠ FIXED-ARITY BUILDERS RATHER THAN A LIST LITERAL: `List[Int](a)` does not
    compile on Mojo 1.0 (the variadic ctor needs `__list_literal__`), and an
    explicit builder keeps every fixture's answer script readable at its call
    site."""
    var l = List[Int]()
    l.append(a)
    return _ScriptedAuthorizer(l^)


def _answers2(a: Int, b: Int) -> _ScriptedAuthorizer:
    var l = List[Int]()
    l.append(a)
    l.append(b)
    return _ScriptedAuthorizer(l^)


def _answers3(a: Int, b: Int, c: Int) -> _ScriptedAuthorizer:
    var l = List[Int]()
    l.append(a)
    l.append(b)
    l.append(c)
    return _ScriptedAuthorizer(l^)


def _is_authorized_of(payload: String) raises -> Bool:
    var v = parse_json_value(payload)
    var flag = v.get(String("isAuthorized"))
    return flag.as_bool()


# =============================================================================
# §2 — THE CHANNEL ROUTING. The non-empty arm first, then the deny direction.
# =============================================================================

def test_an_ALLOW_is_POSTED_with_its_context_and_no_error() raises:
    """⇒ THE NON-EMPTY ARM. A loop that reported everything on the error channel
    would pass every refusal test in this file and grant nothing ever."""
    var transport = _one(_events(1))
    var authorizer = _answers1(AUTHZ_ANSWER_ALLOW)
    var flush = _CountingFlush()

    var handled = run_authorizer_pump[
        _ScriptedAuthorizer, _ScriptedTransport, _CountingFlush
    ](transport, authorizer, flush, 1)

    assert_equal(handled, 1)
    assert_equal(transport.post_count, 1)
    assert_equal(transport.error_count, 0)
    assert_true(_is_authorized_of(transport.last_payload))
    assert_true(transport.last_payload.find(String("subject-proven")) >= 0)
    # And the decider was handed the REAL parsed fields, not a default event.
    assert_equal(authorizer.authorize_count, 1)
    assert_equal(authorizer.seen_route_key, String("POST /v1/messages"))
    assert_equal(authorizer.seen_authorization, String("Bearer tok-live"))


def test_a_DENY_is_POSTED_as_false_and_is_NOT_an_error() raises:
    """A deny is an ANSWER, not a fault: `isAuthorized: false` is a 403 at the
    gateway. Routing it to the error channel would render every bad credential
    as a 500 and put customer errors in our error metric."""
    var transport = _one(_events(1))
    var authorizer = _answers1(AUTHZ_ANSWER_DENY)
    var flush = _CountingFlush()

    _ = run_authorizer_pump[
        _ScriptedAuthorizer, _ScriptedTransport, _CountingFlush
    ](transport, authorizer, flush, 1)

    assert_equal(transport.post_count, 1)
    assert_equal(transport.error_count, 0)
    assert_false(_is_authorized_of(transport.last_payload))


def test_UNAVAILABLE_takes_the_ERROR_channel_and_POSTS_NO_VERDICT() raises:
    """⛔⛔ THE RULE. "The backend could not be asked" must not reach API
    Gateway as `isAuthorized: false`, because API Gateway CACHES a response for
    `AuthorizerResultTtlInSeconds`, and a cached UNAVAILABLE would convert one
    failed upstream call into the whole TTL of guaranteed failure — turning a
    blip into an outage. A Lambda
    ERROR is a 500 and is not a cacheable authorizer result.

    ⚠ BOTH counters are pinned. `error_count == 1` alone would be satisfied by a
    loop that ALSO posted a verdict."""
    var transport = _one(_events(1))
    var authorizer = _answers1(AUTHZ_ANSWER_UNAVAILABLE)
    var flush = _CountingFlush()

    _ = run_authorizer_pump[
        _ScriptedAuthorizer, _ScriptedTransport, _CountingFlush
    ](transport, authorizer, flush, 1)

    assert_equal(transport.error_count, 1)
    assert_equal(transport.post_count, 0)
    assert_equal(transport.last_payload, String(""))
    assert_true(
        transport.last_error.find(String("authorizer-cannot-decide")) >= 0
    )


def test_an_UNKNOWN_ORDINAL_takes_the_ERROR_channel_and_posts_no_verdict() raises:
    """⛔ TOTALITY at the LOOP, not only at the answer. An ordinal from a newer
    caller must not fall through to either `respond_ok` arm — and in particular
    not to the ALLOW one, which is what an `if kind == DENY: false else: true`
    loop would do."""
    var transport = _one(_events(1))
    var authorizer = _answers1(77)
    var flush = _CountingFlush()

    _ = run_authorizer_pump[
        _ScriptedAuthorizer, _ScriptedTransport, _CountingFlush
    ](transport, authorizer, flush, 1)

    assert_equal(transport.error_count, 1)
    assert_equal(transport.post_count, 0)
    assert_equal(transport.last_payload, String(""))


def test_an_UNPARSEABLE_event_never_reaches_the_decider_and_posts_no_verdict() raises:
    """⛔ THE PARSE-FAILURE ARM, and it pins THREE things.

    `_proxy_event_json()` is the happy-path event with `type` removed — a PROXY
    event, which the proxy converter would have accepted happily.

      * `authorize_count == 0`: the decider is never called. A decider handed a
        degraded event would find no credential and DENY, which looks correct
        and hides a misconfigured integration inside the deny rate forever.
      * `error_count == 1`: it lands in the function's ERROR metric, where a
        deployment fault belongs — every invocation fails identically and no
        caller can fix it.
      * `post_count == 0`: no `isAuthorized` of any value reaches API Gateway,
        which is what makes the error channel FAIL-CLOSED rather than merely
        loud."""
    var events = List[String]()
    events.append(_proxy_event_json())
    var transport = _one(events^)
    var authorizer = _answers1(AUTHZ_ANSWER_ALLOW)
    var flush = _CountingFlush()

    _ = run_authorizer_pump[
        _ScriptedAuthorizer, _ScriptedTransport, _CountingFlush
    ](transport, authorizer, flush, 1)

    assert_equal(authorizer.authorize_count, 0)
    assert_equal(transport.error_count, 1)
    assert_equal(transport.post_count, 0)
    assert_equal(transport.last_payload, String(""))
    assert_true(
        transport.last_error.find(String("authorizer-event-unparseable")) >= 0
    )


def test_a_RAISING_decider_takes_the_ERROR_channel_and_posts_no_verdict() raises:
    """A conformer raise is an internal fault. It must not become an allow, and
    it must not become a cached `false` either — the trait's docstring tells a
    conformer to return UNAVAILABLE instead, and this arm is what happens when
    one does not."""
    var transport = _one(_events(1))
    var authorizer = _answers1(AUTHZ_ANSWER_ALLOW)
    authorizer._raise_on_authorize = True
    var flush = _CountingFlush()

    _ = run_authorizer_pump[
        _ScriptedAuthorizer, _ScriptedTransport, _CountingFlush
    ](transport, authorizer, flush, 1)

    assert_equal(authorizer.authorize_count, 1)
    assert_equal(transport.error_count, 1)
    assert_equal(transport.post_count, 0)
    assert_equal(transport.last_payload, String(""))
    assert_true(transport.last_error.find(String("authorizer-raised")) >= 0)


# =============================================================================
# §3 — THE DRAIN POSITION, re-asserted for THIS loop.
# =============================================================================

def test_the_drain_runs_ONCE_per_invocation() raises:
    var transport = _one(_events(3))
    var authorizer = _answers3(
        AUTHZ_ANSWER_ALLOW, AUTHZ_ANSWER_DENY, AUTHZ_ANSWER_ALLOW
    )
    var flush = _CountingFlush()

    var handled = run_authorizer_pump[
        _ScriptedAuthorizer, _ScriptedTransport, _CountingFlush
    ](transport, authorizer, flush, 3)

    assert_equal(handled, 3)
    assert_equal(flush.flush_count, 3)
    assert_equal(transport.post_count, 3)


def test_the_drain_also_runs_on_the_ERROR_channel() raises:
    """An invocation that could not be decided is still an invocation that
    ended, and the records explaining why are exactly the ones worth not
    losing."""
    var transport = _one(_events(1))
    var authorizer = _answers1(AUTHZ_ANSWER_UNAVAILABLE)
    var flush = _CountingFlush()

    _ = run_authorizer_pump[
        _ScriptedAuthorizer, _ScriptedTransport, _CountingFlush
    ](transport, authorizer, flush, 1)

    assert_equal(transport.error_count, 1)
    assert_equal(flush.flush_count, 1)


def test_the_drain_has_NOT_run_when_the_result_POST_fails() raises:
    """D1. A drain moved above the POST — or to the top of the loop body, which
    is also before the POST — scores 1 here instead of 0."""
    var transport = _one(_events(1))
    transport._raise_on_post_index = 0
    var authorizer = _answers1(AUTHZ_ANSWER_ALLOW)
    var flush = _CountingFlush()

    var raised = False
    try:
        _ = run_authorizer_pump[
            _ScriptedAuthorizer, _ScriptedTransport, _CountingFlush
        ](transport, authorizer, flush, 1)
    except e:
        raised = True
        _ = e
    assert_true(raised)
    assert_equal(flush.flush_count, 0)


def test_the_drain_has_NOT_run_when_the_ERROR_REPORT_fails() raises:
    """D3 — the OTHER exit of the loop body. D1 drives only the success arm, so
    a drain moved above `report_error` alone would be caught by nothing: over
    the deployment-fault path, where every invocation fails identically and
    every one would pay the drain inside its billed duration forever, for a
    function answering nobody."""
    var transport = _one(_events(1))
    transport._raise_on_error_index = 0
    var authorizer = _answers1(AUTHZ_ANSWER_UNAVAILABLE)
    var flush = _CountingFlush()

    var raised = False
    try:
        _ = run_authorizer_pump[
            _ScriptedAuthorizer, _ScriptedTransport, _CountingFlush
        ](transport, authorizer, flush, 1)
    except e:
        raised = True
        _ = e
    assert_true(raised)
    assert_equal(flush.flush_count, 0)


def test_the_drain_HAS_run_before_the_NEXT_poll() raises:
    """D2. A drain deleted in favour of a shutdown-only flush scores 0 here
    instead of 1."""
    var transport = _one(_events(2))
    transport._raise_on_poll_index = 1
    var authorizer = _answers2(AUTHZ_ANSWER_ALLOW, AUTHZ_ANSWER_ALLOW)
    var flush = _CountingFlush()

    var raised = False
    try:
        _ = run_authorizer_pump[
            _ScriptedAuthorizer, _ScriptedTransport, _CountingFlush
        ](transport, authorizer, flush, 2)
    except e:
        raised = True
        _ = e
    assert_true(raised)
    assert_equal(transport.post_count, 1)
    assert_equal(flush.flush_count, 1)


def test_a_FAILED_FIRST_POLL_exits_rather_than_spinning() raises:
    """A poll that fails is not a condition this process can fix. The measured
    reason `run_api_gateway_pump` records: the earlier `continue` form spun on
    `ECONNREFUSED` as fast as the kernel could return it and burned billed CPU
    for the whole function timeout. Nothing is posted and nothing is drained."""
    var transport = _one(_events(1))
    transport._raise_on_poll_index = 0
    var authorizer = _answers1(AUTHZ_ANSWER_ALLOW)
    var flush = _CountingFlush()

    var raised = False
    try:
        _ = run_authorizer_pump[
            _ScriptedAuthorizer, _ScriptedTransport, _CountingFlush
        ](transport, authorizer, flush, -1)
    except e:
        raised = True
        _ = e
    assert_true(raised)
    assert_equal(transport.post_count, 0)
    assert_equal(transport.error_count, 0)
    assert_equal(flush.flush_count, 0)
    assert_equal(authorizer.authorize_count, 0)


def test_the_NO_DRAIN_conformer_is_usable_and_does_nothing() raises:
    """`NoLambdaFlush` is REUSED from `pump.mojo`, not re-declared — and the
    authorizer binary is exactly the case it exists for: it buffers nothing, so
    "this function has no durability drain" is a claim the binary states rather
    than a case that arises from an argument nobody passed."""
    var transport = _one(_events(1))
    var authorizer = _answers1(AUTHZ_ANSWER_ALLOW)
    var flush = NoLambdaFlush()

    var handled = run_authorizer_pump[
        _ScriptedAuthorizer, _ScriptedTransport, NoLambdaFlush
    ](transport, authorizer, flush, 1)

    assert_equal(handled, 1)
    assert_equal(transport.post_count, 1)
    assert_equal(flush.flush_after_response(), 0)


def main() raises:
    test_an_ALLOW_is_POSTED_with_its_context_and_no_error()
    test_a_DENY_is_POSTED_as_false_and_is_NOT_an_error()
    test_UNAVAILABLE_takes_the_ERROR_channel_and_POSTS_NO_VERDICT()
    test_an_UNKNOWN_ORDINAL_takes_the_ERROR_channel_and_posts_no_verdict()
    test_an_UNPARSEABLE_event_never_reaches_the_decider_and_posts_no_verdict()
    test_a_RAISING_decider_takes_the_ERROR_channel_and_posts_no_verdict()

    test_the_drain_runs_ONCE_per_invocation()
    test_the_drain_also_runs_on_the_ERROR_channel()
    test_the_drain_has_NOT_run_when_the_result_POST_fails()
    test_the_drain_has_NOT_run_when_the_ERROR_REPORT_fails()
    test_the_drain_HAS_run_before_the_NEXT_poll()
    test_a_FAILED_FIRST_POLL_exits_rather_than_spinning()
    test_the_NO_DRAIN_conformer_is_usable_and_does_nothing()

    print("test_authorizer_pump: ALL PASS")
