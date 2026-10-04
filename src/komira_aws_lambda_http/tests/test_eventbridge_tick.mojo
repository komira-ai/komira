# =============================================================================
# tests/test_eventbridge_tick.mojo — the EventBridge Scheduler tick converter,
#   the classifier, and the classifying pump entry.
# =============================================================================
#
# ⛔⛔ THE PROPERTY UNDER TEST IS A MIRROR-IMAGE PAIR, AND ONLY THE PAIR IS THE
# PROPERTY. Either half alone is satisfied by a converter that accepts anything:
#
#   (a) a 2.0 API GATEWAY event handed the TICK converter must RAISE
#       -> `test_refuses_an_apigw_2_0_event`
#   (b) a TICK payload handed `api_gateway_v2_event_to_request` must RAISE
#       -> `test_the_tick_payload_is_REFUSED_by_the_apigw_converter`
#
# ⚠ (b) IS NOT A DUPLICATE OF `test_apigw_v2.mojo:test_refuses_an_event_with_no_
# version`, and the difference is the whole reason it is written here. That test
# drives a TRUNCATED 2.0 EVENT (`rawPath` + `requestContext.http`, `version`
# removed) and asserts the version rule. This one drives the SCHEDULER PAYLOAD —
# the two-key `{"httpMethod":…,"path":…}` object our own conformer renders — and
# asserts that the apigw arm refuses THAT. They exercise the same line today and
# they are falsified by different futures: a carve-out admitting the tick shape
# into the apigw converter (the "helpful" change somebody makes when a cron
# 500s) leaves the existing test green and turns this one red. A test pinned to
# the FIXTURE somebody would add a carve-out for is not the same test as one
# pinned to the rule.
#
# ⛔ AND (c) IS THE ONE THAT WOULD HAVE CAUGHT THE FORBIDDEN IMPLEMENTATION.
# `test_a_truncated_2_0_event_is_an_ERROR_and_NOT_a_tick_for_the_root` drives a
# 2.0 event with its `version` removed through the CLASSIFYING pump. A correct
# pump reports it on the invocation ERROR channel and never dispatches. A "try
# apigw, fall back to tick" pump dispatches — and what it dispatches is a TICK,
# which fires a backstop, which is a write nobody asked for. That is why the
# discrimination rule is stated in `eventbridge_tick.mojo`'s header as a rule and
# not as an implementation note.
#
# =============================================================================
# ⚠⚠ WHAT EACH ASSERTION ACTUALLY CATCHES — MEASURED, AND THE FIRST VERSION OF
#   THIS FILE GOT TWO OF THEM WRONG
# =============================================================================
# Every row below is a real mutation of the shipped code with this suite re-run
# on the farm. Two rows are here because the docstrings originally
# CLAIMED coverage the runs refused, which is the same defect this package's
# `test_pump_flush_ordering.mojo` header records about its own first version.
#
#   the tick converter made LENIENT (§2's exact-shape rule deleted AND the two
#     members defaulted — i.e. the "helpful" converter the header forbids)
#     .......................... RED, at `test_refuses_a_REST_1_0_proxy_event…`
#
#   §1 (the `version`-presence refusal) DELETED from the tick converter
#     .......................... GREEN before this file asserted the MESSAGE ⚠
#     `version` is trivially a member outside the two-key contract, so §2
#     refuses every payload §1 refuses and no OUTCOME separates them. What
#     separates them is which refusal fires first, i.e. the message. Now caught
#     by `test_refuses_a_payload_that_carries_version_with_the_APIGW_refusal_
#     not_the_shape_one`.
#
#   the classifying pump replaced by the FORBIDDEN "try apigw, fall back to
#     tick" reader, strict converter left intact
#     .......................... GREEN before this file asserted the MESSAGE ⚠⚠
#     This is the one worth understanding. `test_a_truncated_2_0_event_is_an_
#     ERROR_and_NOT_a_tick_for_the_root` asserts the OUTCOME (no dispatch, one
#     error) and the fallback pump PRODUCES THAT OUTCOME — because the strict
#     tick converter refuses the truncated event on its second try too. So the
#     "truncated 2.0 event is not a tick" property is held by THE TICK
#     CONVERTER'S STRICTNESS, and the classifier's commit-don't-try is a SECOND
#     line whose value shows up only when the first is loosened. What catches
#     the fallback is `test_a_1_0_event_reports_the_APIGW_refusal_and_not_the_
#     TICK_one`: on an event BOTH converters refuse, only the fallback reader
#     swallows the API Gateway refusal and reports the tick one.
#
# ⇒ SO THE TWO RULES ARE NOT REDUNDANT, AND NEITHER IS SUFFICIENT. A strict
#   converter with a fallback reader mis-reports every dual refusal; a strict
#   classifier with a lenient converter dispatches a caller's request as a
#   backstop. Both are asserted, and each is asserted by the thing that measured
#   RED against it rather than by the thing that reads as if it would.
#
# ⚠ WHY THE INSTRUMENTS ARE RE-DECLARED RATHER THAN IMPORTED FROM
# `test_pump_flush_ordering.mojo`. The layout property: the tests live in `tests/`, a subdirectory with NO `__init__.mojo`,
# which `mojo precompile` does not descend into — so there is no module for one
# falsifier to import a sibling falsifier's instruments from, by construction and
# on purpose (either half violated and editing a falsifier would move the
# library's `.mojoc` digest). The three conformers below are therefore the
# minimum re-statement, not a fork: only the fields these assertions read.
#
# ⚠ THE DISPATCHER HERE IS A RECORDER AND NOT A PRODUCTION DISPATCHER, for the
# reason `test_pump_flush_ordering.mojo` records: a test here compiles against
# THIS library plus this library's own deps and nothing else.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import Reactor
from komira_async.runtime.runtime_trait import Runtime
from komira_async.runtime.aws_lambda_runtime import AwsLambdaRuntime

from komira_http_core.codec.types import HttpRequest, HttpResponse
from komira_http_server.dispatch import RequestDispatcher
from komira_http_core.codec.types import (
    HTTP_METHOD_GET,
    HTTP_METHOD_POST,
    HTTP_METHOD_PUT,
)

from komira_aws_lambda_http.apigw_v2 import (
    AUTHORIZER_HEADER_PREFIX,
    api_gateway_v2_event_to_request,
)
from komira_aws_lambda_http.eventbridge_tick import (
    APIGW_DISCRIMINATOR_KEY,
    LAMBDA_EVENT_KIND_API_GATEWAY,
    LAMBDA_EVENT_KIND_SCHEDULED_TICK,
    TICK_METHOD_KEY,
    TICK_PATH_KEY,
    classify_lambda_event,
    eventbridge_tick_event_to_request,
)
from komira_aws_lambda_http.pump import (
    LambdaInvocationTransport,
    LambdaInvokeEvent,
    LambdaPostResponseFlush,
    run_api_gateway_and_tick_pump,
)


comptime _Rt = AwsLambdaRuntime[NoopSink]

# ⛔ THE FIXTURE IS THE RENDERER'S OUTPUT, BYTE FOR BYTE. It is what
# `komira_aws_iac/aws_scheduled_call_conformer.mojo:scheduled_call_input_payload`
# emits for `path: "/internal/tick/reconcile"` + `http_method: "POST"` — two
# members, `httpMethod` first, no whitespace. Writing a prettier fixture here
# would test a payload nothing produces.
comptime _TICK_RECONCILE: String = (
    '{"httpMethod":"POST","path":"/internal/tick/reconcile"}'
)


# =============================================================================
# §1 — the instruments (see the header for why they are re-declared).
# =============================================================================

struct _ScriptedTransport(LambdaInvocationTransport, Movable, Deinitable):
    """A transport with no socket: a list of events to hand out, one counter per
    channel, and ONE fault injector (`_raise_on_post_index`, default -1 = never)
    so the drain-ordering detector below differs from its baseline in exactly one
    field."""

    var _events: List[String]
    var _next_index: Int
    var post_count: Int
    var error_count: Int
    var init_error_count: Int
    var last_payload: String
    var last_error: String
    var _raise_on_post_index: Int

    def __init__(out self, var events: List[String]):
        self._events = events^
        self._next_index = 0
        self.post_count = 0
        self.error_count = 0
        self.init_error_count = 0
        self.last_payload = String("")
        self.last_error = String("")
        self._raise_on_post_index = -1

    def next_invocation(mut self) raises -> LambdaInvokeEvent:
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
        self.error_count += 1
        self.last_error = message

    def report_init_error(mut self, message: String) raises:
        self.init_error_count += 1
        self.last_error = message


struct _CountingFlush(LambdaPostResponseFlush, Movable, Deinitable):
    """Counts drains. It cannot see the transport — that independence is what
    makes "the drain had not run yet" an ORDERING statement rather than a read
    off a shared journal."""

    var flush_count: Int

    def __init__(out self):
        self.flush_count = 0

    def flush_after_response(mut self) raises -> Int:
        self.flush_count += 1
        return 3


struct _RecordingDispatcher(RequestDispatcher, Movable, Deinitable):
    """A real `RequestDispatcher` that keeps the fields it was handed."""

    var seen_method: UInt8
    var seen_path: String
    var seen_query: String
    var seen_header_count: Int
    var seen_body_len: Int
    var dispatch_count: Int

    def __init__(out self):
        self.seen_method = UInt8(0)
        self.seen_path = String("")
        self.seen_query = String("")
        self.seen_header_count = 0
        self.seen_body_len = 0
        self.dispatch_count = 0

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
        var n = 0
        for kv in req.headers.items():
            _ = kv
            n += 1
        self.seen_header_count = n

        var r = HttpResponse(status=Int32(200))
        var body = String('{"ticked": true}')
        var bs = body.as_bytes()
        for i in range(len(bs)):
            r.body.append(bs[i])
        return r^


def _one_event_transport(event: String) -> _ScriptedTransport:
    var events = List[String]()
    events.append(event)
    return _ScriptedTransport(events^)


def _apigw_send_event() -> String:
    """A realistic payload-format-2.0 proxy event — the shape a
    production API Gateway path serves. Present so the classifying pump is
    asserted on BOTH arms and not only on the new one."""
    return String(
        '{"version": "2.0", "rawPath": "/api/v1/items",'
        '"rawQueryString": "tag=a",'
        '"headers": {"Content-Type": "application/json"},'
        '"requestContext": {"http": {"method": "POST"}},'
        '"body": "{}", "isBase64Encoded": false}'
    )


def _must_raise_tick_naming(
    payload: String, needle: String, forbidden: String
) raises:
    """`eventbridge_tick_event_to_request(payload)` must REFUSE **with a message
    that names `needle` and does not name `forbidden`**.

    ⚠ ASSERTING A MESSAGE IS ORDINARILY OVER-FITTING, AND HERE IT IS THE ONLY
    INSTRUMENT THERE IS — see this file's header. Two of this converter's rules
    refuse exactly the same set of payloads and differ only in which fires
    first, so an outcome assertion cannot tell them apart, and the run that
    proved it is in the table above."""
    var raised = False
    var text = String("")
    try:
        var req = eventbridge_tick_event_to_request(payload)
        _ = req.path
    except e:
        raised = True
        text = String(e)
    if not raised:
        raise Error(
            String(
                "expected a REFUSAL and got a request instead; wanted a message"
                " naming '"
            )
            + needle
            + String("'")
        )
    if text.find(needle) == -1:
        raise Error(
            String("the refusal did not name '")
            + needle
            + String("'; it said: ")
            + text
        )
    if text.find(forbidden) != -1:
        raise Error(
            String("the refusal named '")
            + forbidden
            + String("', so the WRONG check fired first; it said: ")
            + text
        )


def _must_raise_tick(payload: String, because: String) raises:
    """`eventbridge_tick_event_to_request(payload)` must REFUSE."""
    var raised = False
    try:
        var req = eventbridge_tick_event_to_request(payload)
        _ = req.path
    except e:
        raised = True
        _ = e
    if not raised:
        raise Error(
            String("expected a REFUSAL and got a request instead: ") + because
        )


# =============================================================================
# §2 — the tick converter: what it ACCEPTS.
# =============================================================================

def test_the_rendered_tick_becomes_the_route_it_names() raises:
    """THE BASELINE, and it is the far side of a contract that had no far side.
    `scheduled_call_input_payload`'s docstring says the receiving handler "has to
    READ them" and its header admits "NOTHING IN THIS TREE CHECKS THAT THE
    HANDLER HONOURS IT". This is that check."""
    var req = eventbridge_tick_event_to_request(String(_TICK_RECONCILE))
    assert_equal(req.method.code, HTTP_METHOD_POST)
    assert_equal(req.path, String("/internal/tick/reconcile"))
    assert_equal(req.query_string, String(""))
    assert_equal(len(req.body), 0)


def test_the_key_spellings_are_the_ones_the_renderer_emits() raises:
    """⛔ THE CONTRACT IS THE SPELLING. The render side pins `httpMethod`/`path`
    with its own test; this is the same pin on the read side, so the pair cannot
    be "tidied" independently. A handler expecting `method` against a payload
    carrying `httpMethod` produces a function that runs, reports success to the
    scheduler, and does nothing forever."""
    assert_equal(String(TICK_METHOD_KEY), String("httpMethod"))
    assert_equal(String(TICK_PATH_KEY), String("path"))
    assert_equal(String(APIGW_DISCRIMINATOR_KEY), String("version"))


def test_the_method_comes_from_httpMethod_and_is_not_assumed_POST() raises:
    """ONE differing field from the baseline: `httpMethod` is `GET`. A converter
    that hardcoded POST (the renderer's default, and the only verb the two
    authored crons use) passes every other test in this file."""
    var req = eventbridge_tick_event_to_request(
        String('{"httpMethod":"GET","path":"/internal/tick/reconcile"}')
    )
    assert_equal(req.method.code, HTTP_METHOD_GET)
    assert_false(req.method.code == HTTP_METHOD_POST)


def test_a_lowercase_verb_is_accepted_through_the_SHARED_table() raises:
    """The verb table is `apigw_v2._method_from_name`, imported and not
    re-written, so the two arms cannot drift about what a verb is. This asserts
    the sharing behaviourally (that function upper-cases) rather than by reading
    the import line."""
    var req = eventbridge_tick_event_to_request(
        String('{"httpMethod":"put","path":"/internal/tick/reconcile"}')
    )
    assert_equal(req.method.code, HTTP_METHOD_PUT)


def test_a_query_in_the_path_becomes_the_query_string() raises:
    """§4 — CROSS-CLOUD AGREEMENT. The GCP peer delivers a real HTTP request to
    `<service url> + path`, so a query written into `path` survives to the
    handler there BY CONSTRUCTION. Not splitting it here would make the SAME
    bundle field mean two different things on two clouds, and the AWS half of the
    disagreement would 404 inside a scheduler metric nobody reads."""
    var req = eventbridge_tick_event_to_request(
        String('{"httpMethod":"POST","path":"/internal/tick/reconcile?deep=1"}')
    )
    assert_equal(req.path, String("/internal/tick/reconcile"))
    # No leading `?` — `HttpRequest.query_string`'s contract, the same one
    # `rawQueryString` satisfies on the API Gateway arm.
    assert_equal(req.query_string, String("deep=1"))


def test_only_the_FIRST_question_mark_splits() raises:
    """RFC 3986: everything after the first `?` is the query, `?` included. A
    split on the LAST one silently moves a literal `?` out of the query."""
    var req = eventbridge_tick_event_to_request(
        String('{"httpMethod":"POST","path":"/t?a=1?2"}')
    )
    assert_equal(req.path, String("/t"))
    assert_equal(req.query_string, String("a=1?2"))


def test_a_converted_tick_carries_NO_headers_AT_ALL() raises:
    """⛔ A SECURITY PROPERTY, NOT A SIMPLIFICATION (§5). `apigw_v2.mojo` §3
    spends its longest section on one hazard: the authorizer's answer reaches a
    handler through `req.headers` and the CLIENT controls `headers` too, so the
    whole `x-komira-authorizer-` namespace is destroyed on entry there. The
    request this converter builds has an EMPTY header dict and never adds one, so
    the reserved namespace is unreachable from a tick payload by construction.

    Asserting the COUNT rather than the absence of one name is deliberate: a
    future line that injected a marker header would be caught here, and §5
    records why no marker header is injected (a second one-sided contract, when
    this file exists because the first one was one-sided)."""
    var req = eventbridge_tick_event_to_request(String(_TICK_RECONCILE))
    var n = 0
    for kv in req.headers.items():
        _ = kv
        n += 1
    assert_equal(n, 0)
    var reserved = String(AUTHORIZER_HEADER_PREFIX) + String("orgid")
    assert_false(reserved in req.headers)


# =============================================================================
# §3 — the tick converter: what it REFUSES. Falsifier (a) leads.
# =============================================================================

def test_refuses_an_apigw_2_0_event() raises:
    """⛔ FALSIFIER (a) — the first half of the mirror-image pair. A full,
    well-formed payload-format-2.0 proxy event handed the TICK converter RAISES.

    Without the `version` check this event carries no `httpMethod` and no `path`
    (2.0 spells them `requestContext.http.method` and `rawPath`), so a converter
    that merely required the two keys would also refuse it — which is why the
    NEXT test exists and is the sharper one."""
    _must_raise_tick(String(_apigw_send_event()), String("a real 2.0 event"))


def test_refuses_a_payload_that_carries_version_with_the_APIGW_refusal_not_the_shape_one() raises:
    """⛔ THE SHARPEST FORM OF (a): a payload that is byte-for-byte the tick
    contract PLUS a `version` field. Every other check in the converter passes on
    it — both members present, string, non-empty, the path starts with `/`, the
    verb is known — so the only things that can refuse it are §1 (the
    discriminator, read FIRST) and §2 (the exact-shape rule).

    ⚠⚠ AND IT ASSERTS THE MESSAGE, WHICH IS NOT FUSSINESS — IT IS THE ONLY
    INSTRUMENT. MEASURED (see this file's header table): deleting §1 outright
    leaves this suite GREEN, because `version` is trivially a member outside the
    two-key contract and §2 refuses it too. No OUTCOME separates the two rules;
    only which one fires first does, and that difference is real — §1 sends the
    reader to `api_gateway_v2_event_to_request`, §2 sends them looking for a
    stray member. §1 is also the rule that survives a loosening of §2, which is
    the strictest rule in the file and so the likeliest to be relaxed.

    So: the refusal must name the API GATEWAY arm, and must NOT be the
    unknown-member refusal."""
    _must_raise_tick_naming(
        String(
            '{"version":"2.0","httpMethod":"POST",'
            '"path":"/internal/tick/reconcile"}'
        ),
        String("API GATEWAY event"),
        String("not part of the scheduled-call contract"),
    )


def test_refuses_a_REST_1_0_proxy_event_which_carries_NO_version() raises:
    """⛔⛔ THE SHAPE THE EXACT-SHAPE RULE (§2) EXISTS FOR, and it is a real AWS
    event rather than a hypothetical.

    A REST-API (payload format 1.0) proxy event stamps NO `version` field at all
    — only an HTTP API opted in to 1.0 stamps `"version": "1.0"` — and it carries
    `httpMethod` and `path` AT THE TOP LEVEL with the same spellings as this
    contract. So a discriminator reading `version` alone converts a caller's
    PUBLIC request into an INTERNAL scheduled call, discarding its body, headers
    and query, and dispatches it.

    What refuses it is that the contract is exactly two members: `resource`,
    `requestContext`, `headers` and the rest are each a refusal by name."""
    _must_raise_tick(
        String(
            '{"resource": "/{proxy+}", "path": "/api/v1/items",'
            '"httpMethod": "POST",'
            '"headers": {"Host": "api.example.com"},'
            '"queryStringParameters": null,'
            '"requestContext": {"accountId": "1", "resourcePath": "/{proxy+}"},'
            '"body": "{}", "isBase64Encoded": false}'
        ),
        String("a REST-API 1.0 proxy event, which carries no `version`"),
    )


def test_refuses_a_tick_payload_that_tries_to_carry_headers() raises:
    """The §5 property, asserted from the attack side rather than the count side:
    a payload attempting to smuggle a header — the reserved authorizer namespace
    included — is refused before the question of what to do with it arises."""
    _must_raise_tick(
        String(
            '{"httpMethod":"POST","path":"/internal/tick/reconcile",'
            '"headers":{"x-komira-authorizer-orgid":"org-victim"}}'
        ),
        String("a tick payload carrying `headers`"),
    )


def test_refuses_a_payload_with_no_path_rather_than_defaulting_to_the_root() raises:
    """⛔⛔ THE REFUSAL THAT MAKES THE FALLBACK READER IMPOSSIBLE TO WRITE BY
    ACCIDENT, and the one this converter's whole no-defaulting rule exists for.

    `scheduled_call_input_payload` maps an empty `path` to `"/"` and an empty
    `http_method` to `"POST"` — the proto's own defaults, applied on the RENDER
    side where the author's intent is known. Applying the same defaults on the
    READ side is EXACTLY the machinery that turns a truncated event from some
    other source into "a tick for `/` by POST": every field the reader needed was
    supplied by the reader.

    So a missing member is a refusal naming which one, and this test is what goes
    red the day somebody makes the converter "more forgiving"."""
    _must_raise_tick(
        String('{"httpMethod":"POST"}'),
        String("a payload with no `path`"),
    )


def test_refuses_a_payload_with_no_httpMethod() raises:
    """The other half of the no-defaulting rule. `POST` is the renderer's default
    AND the verb both authored crons use, which is precisely what would make
    defaulting it here look harmless."""
    _must_raise_tick(
        String('{"path":"/internal/tick/reconcile"}'),
        String("a payload with no `httpMethod`"),
    )


def test_refuses_an_EMPTY_member_rather_than_substituting_the_default() raises:
    """Present-but-empty is the same defect as absent, and it is the shape a
    partially-populated renderer actually produces."""
    _must_raise_tick(
        String('{"httpMethod":"POST","path":""}'),
        String("an empty `path`"),
    )
    _must_raise_tick(
        String('{"httpMethod":"","path":"/internal/tick/reconcile"}'),
        String("an empty `httpMethod`"),
    )


def test_refuses_a_non_string_member() raises:
    """The renderer emits both members as string literals, so a number here means
    the payload was assembled by something else."""
    _must_raise_tick(
        String('{"httpMethod":"POST","path":7}'),
        String("a numeric `path`"),
    )


def test_refuses_a_path_that_does_not_start_with_a_slash() raises:
    """The third and last place this is refused (`validate.mojo` at authoring
    time, `scheduled_call_input_payload` at render time, here on the read side).
    Prefixing one back would launder a symptom into a route that dispatches
    somewhere."""
    _must_raise_tick(
        String('{"httpMethod":"POST","path":"internal/tick/reconcile"}'),
        String("a path with no leading slash"),
    )


def test_refuses_an_unrecognised_verb_INSTEAD_of_letting_it_405() raises:
    """⛔ THE DELIBERATE INVERSION of `apigw_v2._method_from_name`'s rule (§3),
    and the inversion is a statement about the SENDER, not about the verb.

    On the API Gateway arm the sender is a CLIENT: an odd verb is a request-level
    condition the dispatcher answers 405, and raising would file a bad request on
    the Lambda ERROR channel and page somebody. Here the sender is this
    repository's own bundle (`crons[].http_method`), so an odd verb is deploy
    data that is wrong — a deployment fault, which is what the ERROR channel is
    for. A 405 answered to a scheduler is visible to nobody and the backstop
    simply never ticks."""
    _must_raise_tick(
        String('{"httpMethod":"BREW","path":"/internal/tick/reconcile"}'),
        String("an unrecognised verb"),
    )


def test_refuses_a_payload_that_is_not_a_json_object() raises:
    """An SQS batch, an S3 notification, a direct invoke carrying an array."""
    _must_raise_tick(String('["not", "a", "tick"]'), String("a JSON array"))


# =============================================================================
# §4 — FALSIFIER (b): the mirror half, at the APIGW converter.
# =============================================================================

def test_the_tick_payload_is_REFUSED_by_the_apigw_converter() raises:
    """⛔ FALSIFIER (b). The scheduler payload handed
    `api_gateway_v2_event_to_request` must RAISE.

    ⚠ NOT A DUPLICATE of `test_apigw_v2.mojo:test_refuses_an_event_with_no_
    version` — see this file's header. That one drives a truncated 2.0 event and
    pins the version RULE; this one drives the SCHEDULER PAYLOAD and pins the
    rule's application to THIS shape. They exercise one line today and are
    falsified by different futures: a carve-out admitting the tick shape into the
    apigw converter — the "helpful" change somebody makes when a cron 500s —
    leaves that test green and turns this one red."""
    var raised = False
    try:
        var req = api_gateway_v2_event_to_request(String(_TICK_RECONCILE))
        _ = req.path
    except e:
        raised = True
        _ = e
    assert_true(raised)


# =============================================================================
# §5 — the classifier.
# =============================================================================

def test_the_classifier_reads_version_presence_and_nothing_else() raises:
    """Both directions, off ONE field. The tick fixture and the apigw fixture
    differ in many members; the classifier is asserted to be indifferent to all
    of them."""
    assert_equal(
        classify_lambda_event(String(_TICK_RECONCILE)),
        LAMBDA_EVENT_KIND_SCHEDULED_TICK,
    )
    assert_equal(
        classify_lambda_event(String(_apigw_send_event())),
        LAMBDA_EVENT_KIND_API_GATEWAY,
    )


def test_the_classifier_says_APIGW_for_a_1_0_version_it_cannot_serve() raises:
    """⛔ CLASSIFY IS NOT VALIDATE, AND CONFLATING THEM IS HOW THE FALLBACK GETS
    RE-INVENTED. A `"version": "1.0"` event is an API Gateway payload that this
    runtime REFUSES — but it is refused BY THE APIGW CONVERTER, naming the format
    (`_require_v2`), not by being classified as a tick. A classifier that
    answered SCHEDULED_TICK here because "the apigw arm would reject it anyway"
    would dispatch a caller's request as a backstop."""
    assert_equal(
        classify_lambda_event(
            String(
                '{"version": "1.0", "rawPath": "/x", "rawQueryString": "",'
                '"requestContext": {"http": {"method": "POST"}}}'
            )
        ),
        LAMBDA_EVENT_KIND_API_GATEWAY,
    )


def test_the_classifier_refuses_a_payload_that_is_not_an_object() raises:
    """Guessing a kind for an SQS batch is guessing which handler gets a request
    nobody made."""
    var raised = False
    try:
        _ = classify_lambda_event(String('["Records"]'))
    except e:
        raised = True
        _ = e
    assert_true(raised)


# =============================================================================
# §6 — FALSIFIER (c): the classifying pump, end to end.
# =============================================================================

def test_a_tick_reaches_the_dispatcher_as_POST_on_its_own_route() raises:
    """⛔ FALSIFIER (c). One scheduler tick in; the dispatcher is handed method
    POST and path `/internal/tick/reconcile`, the result is POSTed on the RESULT
    channel, and NOTHING reaches the error channel.

    This is the whole capability: before it, this exact payload reached
    `api_gateway_v2_event_to_request`, was refused for carrying no `version`, and
    was reported as a deployment fault — every tick, forever."""
    var transport = _one_event_transport(String(_TICK_RECONCILE))
    var dispatcher = _RecordingDispatcher()
    var flusher = _CountingFlush()
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()

    var handled = run_api_gateway_and_tick_pump[
        _RecordingDispatcher, _Rt, _ScriptedTransport, _CountingFlush
    ](transport, dispatcher, reactor, flusher, 1)

    assert_equal(handled, 1)
    assert_equal(dispatcher.dispatch_count, 1)
    assert_equal(dispatcher.seen_method, HTTP_METHOD_POST)
    assert_equal(dispatcher.seen_path, String("/internal/tick/reconcile"))
    assert_equal(dispatcher.seen_query, String(""))
    assert_equal(dispatcher.seen_header_count, 0)
    assert_equal(transport.post_count, 1)
    assert_equal(transport.error_count, 0)


def test_an_apigw_event_still_reaches_the_dispatcher_through_the_same_pump() raises:
    """The OTHER arm, and it is what keeps the classification from being a
    regression dressed as a feature: the API Gateway proxy shape still
    converts, still dispatches, and still carries its query."""
    var transport = _one_event_transport(String(_apigw_send_event()))
    var dispatcher = _RecordingDispatcher()
    var flusher = _CountingFlush()
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()

    var handled = run_api_gateway_and_tick_pump[
        _RecordingDispatcher, _Rt, _ScriptedTransport, _CountingFlush
    ](transport, dispatcher, reactor, flusher, 1)

    assert_equal(handled, 1)
    assert_equal(dispatcher.dispatch_count, 1)
    assert_equal(dispatcher.seen_method, HTTP_METHOD_POST)
    assert_equal(dispatcher.seen_path, String("/api/v1/items"))
    assert_equal(dispatcher.seen_query, String("tag=a"))
    assert_equal(transport.error_count, 0)


def test_a_truncated_2_0_event_is_an_ERROR_and_NOT_a_tick_for_the_root() raises:
    """⛔⛔ THE TEST THE DISCRIMINATION RULE EXISTS FOR — the one a "try apigw,
    fall back to tick" pump fails.

    The fixture is `_apigw_send_event()` with its `version` member REMOVED and
    nothing else changed: a 2.0 event that lost its discriminator, which is the
    shape `apigw_v2.mojo`'s header names as the one a fallback reader
    mis-reports.

    A correct pump classifies it as a tick (no `version`), the TICK converter
    refuses it (`rawPath`/`requestContext`/`headers` are not contract members),
    and the refusal takes the invocation ERROR channel: `dispatch_count == 0`,
    `post_count == 0`, `error_count == 1`.

    ⚠⚠ THIS DOCSTRING USED TO END *"a fallback pump dispatches it … dispatch_
    count == 1 is the RED"*, AND THAT WAS FALSE. MEASURED: replacing the
    classifier with the forbidden "try apigw, fall back to tick" reader leaves
    this test GREEN, because the strict tick converter refuses the truncated
    event on the fallback's second try as readily as on the classifier's first.

    ⇒ WHAT THIS TEST ACTUALLY HOLDS is that the truncated event is not dispatched
      AT ALL — and what holds it is the TICK CONVERTER'S STRICTNESS (§1's
      no-defaulting and §2's exact shape), not the classifier. It is the
      falsifier for `test_refuses_a_payload_with_no_path_rather_than_defaulting_
      to_the_root` seen from the loop, and it goes red the moment either rule is
      relaxed, which is the mutation that actually produces "a tick for `/`".
      The FALLBACK READER is caught one test below, by message."""
    var truncated = String(
        '{"rawPath": "/api/v1/items", "rawQueryString": "tag=a",'
        '"headers": {"Content-Type": "application/json"},'
        '"requestContext": {"http": {"method": "POST"}},'
        '"body": "{}", "isBase64Encoded": false}'
    )
    var transport = _one_event_transport(truncated)
    var dispatcher = _RecordingDispatcher()
    var flusher = _CountingFlush()
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()

    var handled = run_api_gateway_and_tick_pump[
        _RecordingDispatcher, _Rt, _ScriptedTransport, _CountingFlush
    ](transport, dispatcher, reactor, flusher, 1)

    assert_equal(handled, 1)
    assert_equal(dispatcher.dispatch_count, 0)
    assert_equal(transport.post_count, 0)
    assert_equal(transport.error_count, 1)


def test_a_1_0_event_reports_the_APIGW_refusal_and_not_the_TICK_one() raises:
    """⛔⛔ THE DETECTOR FOR THE FORBIDDEN FALLBACK READER, and it was derived
    from a measurement rather than from the shape of the code.

    The fixture is an event BOTH converters refuse: a payload-format-1.0 API
    Gateway event. That is the only class of payload on which "classify, then
    convert" and "try apigw, fall back to tick" produce different observable
    results, because it is the only one where the fallback's FIRST refusal is
    swallowed:

      correct  : classify => API GATEWAY => `_require_v2` refuses, naming the
                 payload FORMAT. The operator is told the integration speaks 1.0.
      fallback : apigw refuses, the reader eats it, the TICK converter is tried
                 and refuses too — and the message the function reports is the
                 TICK one. The operator is told their scheduled-call payload is
                 malformed, about an event no scheduler sent.

    Every other fixture in this file scores identically under both readers —
    MEASURED, see the header table — so this assertion is the whole of the
    "never write a fallback" rule's enforcement. It reads the message off the
    ERROR channel, which is where the pump puts a conversion refusal."""
    var transport = _one_event_transport(
        String(
            '{"version": "1.0", "rawPath": "/api/v1/items",'
            '"rawQueryString": "", "requestContext":'
            '{"http": {"method": "POST"}}}'
        )
    )
    var dispatcher = _RecordingDispatcher()
    var flusher = _CountingFlush()
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()

    var handled = run_api_gateway_and_tick_pump[
        _RecordingDispatcher, _Rt, _ScriptedTransport, _CountingFlush
    ](transport, dispatcher, reactor, flusher, 1)

    assert_equal(handled, 1)
    assert_equal(dispatcher.dispatch_count, 0)
    assert_equal(transport.post_count, 0)
    assert_equal(transport.error_count, 1)

    # The API Gateway arm's own refusal, naming the FORMAT.
    assert_true(
        transport.last_error.find(String("unsupported payload format version"))
        != -1
    )
    # ⛔ And NOT the tick arm's. A fallback reader reports this one.
    assert_equal(transport.last_error.find(String("eventbridge-tick")), -1)


def test_an_unconvertible_payload_reaches_the_ERROR_channel_not_a_500() raises:
    """The two-channel split, inherited from `run_api_gateway_pump` and asserted
    for THIS loop. A payload that is neither shape is a MISCONFIGURED
    INTEGRATION: no caller can fix it and every invocation fails identically, so
    it must land in the function's error metric rather than look like load."""
    var transport = _one_event_transport(String('["neither", "shape"]'))
    var dispatcher = _RecordingDispatcher()
    var flusher = _CountingFlush()
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()

    var handled = run_api_gateway_and_tick_pump[
        _RecordingDispatcher, _Rt, _ScriptedTransport, _CountingFlush
    ](transport, dispatcher, reactor, flusher, 1)

    assert_equal(handled, 1)
    assert_equal(dispatcher.dispatch_count, 0)
    assert_equal(transport.post_count, 0)
    assert_equal(transport.error_count, 1)


# =============================================================================
# §7 — the drain position, re-asserted for THIS loop.
# =============================================================================
# ⛔ `tests/test_pump_flush_ordering.mojo`'s four detectors are written against
# `run_api_gateway_pump` and say NOTHING about `run_api_gateway_and_tick_pump` —
# moving the drain line in the new loop turns none of them red. This section is
# the same re-assertion `tests/test_authorizer_pump.mojo` makes for the
# authorizer loop, for the reason the package gives: *a rule that holds
# in one loop is not a rule that holds in the code.*
#
# The technique is that file's and needs no shared state: the transport and the
# flush hook are independent `mut` borrows, so the ORDER is read off whether the
# flush counter had moved when a deliberately-raising transport call propagated.
# =============================================================================

def test_the_drain_runs_once_per_invocation() raises:
    """BASELINE for the detector below: the drain runs at all, exactly once, so a
    `flush_count == 0` there is a statement about ORDER and not about a drain
    that was never wired."""
    var transport = _one_event_transport(String(_TICK_RECONCILE))
    var dispatcher = _RecordingDispatcher()
    var flusher = _CountingFlush()
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()

    _ = run_api_gateway_and_tick_pump[
        _RecordingDispatcher, _Rt, _ScriptedTransport, _CountingFlush
    ](transport, dispatcher, reactor, flusher, 1)

    assert_equal(transport.post_count, 1)
    assert_equal(flusher.flush_count, 1)


def test_the_drain_has_NOT_run_when_the_result_post_fails() raises:
    """⛔ INVERSION DETECTOR — proves the drain is AFTER the result POST in the
    NEW loop.

    ONE FIELD differs from the baseline: `_raise_on_post_index = 0`. A pump that
    drains after the POST has not reached the drain when that raise propagates
    (`flush_count == 0`); a pump that drains at ANY point before it — immediately
    above the POST, or at the top of the loop body right after the poll — scores
    1 and this goes RED. That is the detector `test_pump_flush_ordering.mojo`
    measured as the one covering BOTH misplacements.

    WHY THE POSITION IS WORTH RE-ASSERTING RATHER THAN INHERITED: the drain is an
    S3 conditional PUT. Pre-response it is welded into every invocation's BILLED
    DURATION; post-response it lands in the un-billed window before the next
    poll, which is where a custom runtime's freeze actually happens."""
    var transport = _one_event_transport(String(_TICK_RECONCILE))
    transport._raise_on_post_index = 0
    var dispatcher = _RecordingDispatcher()
    var flusher = _CountingFlush()
    var rt = _Rt.new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()

    var raised = False
    try:
        _ = run_api_gateway_and_tick_pump[
            _RecordingDispatcher, _Rt, _ScriptedTransport, _CountingFlush
        ](transport, dispatcher, reactor, flusher, 1)
    except e:
        raised = True
        _ = e

    assert_true(raised)
    assert_equal(transport.post_count, 0)
    # The dispatcher DID run, so the pump reached the POST and the zero below is
    # about ordering, not about a loop that never got that far.
    assert_equal(dispatcher.dispatch_count, 1)
    assert_equal(flusher.flush_count, 0)


def main() raises:
    test_the_rendered_tick_becomes_the_route_it_names()
    test_the_key_spellings_are_the_ones_the_renderer_emits()
    test_the_method_comes_from_httpMethod_and_is_not_assumed_POST()
    test_a_lowercase_verb_is_accepted_through_the_SHARED_table()
    test_a_query_in_the_path_becomes_the_query_string()
    test_only_the_FIRST_question_mark_splits()
    test_a_converted_tick_carries_NO_headers_AT_ALL()

    test_refuses_an_apigw_2_0_event()
    test_refuses_a_payload_that_carries_version_with_the_APIGW_refusal_not_the_shape_one()
    test_refuses_a_REST_1_0_proxy_event_which_carries_NO_version()
    test_refuses_a_tick_payload_that_tries_to_carry_headers()
    test_refuses_a_payload_with_no_path_rather_than_defaulting_to_the_root()
    test_refuses_a_payload_with_no_httpMethod()
    test_refuses_an_EMPTY_member_rather_than_substituting_the_default()
    test_refuses_a_non_string_member()
    test_refuses_a_path_that_does_not_start_with_a_slash()
    test_refuses_an_unrecognised_verb_INSTEAD_of_letting_it_405()
    test_refuses_a_payload_that_is_not_a_json_object()

    test_the_tick_payload_is_REFUSED_by_the_apigw_converter()

    test_the_classifier_reads_version_presence_and_nothing_else()
    test_the_classifier_says_APIGW_for_a_1_0_version_it_cannot_serve()
    test_the_classifier_refuses_a_payload_that_is_not_an_object()

    test_a_tick_reaches_the_dispatcher_as_POST_on_its_own_route()
    test_an_apigw_event_still_reaches_the_dispatcher_through_the_same_pump()
    test_a_truncated_2_0_event_is_an_ERROR_and_NOT_a_tick_for_the_root()
    test_a_1_0_event_reports_the_APIGW_refusal_and_not_the_TICK_one()
    test_an_unconvertible_payload_reaches_the_ERROR_channel_not_a_500()

    test_the_drain_runs_once_per_invocation()
    test_the_drain_has_NOT_run_when_the_result_post_fails()

    print("test_eventbridge_tick: ALL PASS")
