# =============================================================================
# authorizer_pump.mojo — the Lambda invoke loop for a REQUEST AUTHORIZER.
# =============================================================================
# The sibling of `pump.run_api_gateway_pump`, and its differences from that
# loop are the whole content of this file.
#
# WHAT IS THE SAME, AND IS THE SAME BY REUSE RATHER THAN BY RESEMBLANCE:
# `LambdaInvocationTransport`, `LambdaPostResponseFlush`, `NoLambdaFlush` and
# `announce_init_failure` are IMPORTED from `pump.mojo`, not re-declared. Two
# transport traits would mean two adapters at the binary and two chances for one
# of them to swallow a poll failure differently.
#
# AND THE DRAIN POSITION IS THE SAME RULE: after the result is POSTed, before
# the next `/invocation/next` poll. The argument is in `pump.mojo`'s header and
# is not restated here — what IS restated is that this loop obeys it on BOTH
# channels, because an invocation that could not be parsed is still an
# invocation that ended.
#
# =============================================================================
# THREE ANSWERS, TWO CHANNELS — THE ONE THING THIS LOOP DECIDES
# =============================================================================
#
#   AUTHZ_ANSWER_ALLOW        -> respond_ok `{"isAuthorized": true, "context":…}`
#   AUTHZ_ANSWER_DENY         -> respond_ok `{"isAuthorized": false,"context":{}}`
#                                API Gateway renders this as **403**.
#   AUTHZ_ANSWER_UNAVAILABLE  -> report_error. API Gateway renders a Lambda
#     ** and every other ordinal ** error as **500**, and — the half that
#                                matters — DOES NOT CACHE IT.
#
# The third arm is the design, and `apigw_authorizer.mojo`'s header §3 carries
# the argument: a `false` for "the backend could not be asked" would be CACHED
# for `AuthorizerResultTtlInSeconds`, converting one failed upstream call into
# the whole TTL of guaranteed failure. We do not control API Gateway's cache
# policy. We control which answers reach it.
#
# AND THE DEFAULT ARM IS THE ERROR CHANNEL, NOT THE DENY CHANNEL. Both are
# fail-closed; the error channel is chosen because an ordinal nobody has
# reasoned about is an internal fault, and rendering it as a 403 would file it
# under "customer's credential is bad" forever with nothing in the error metric.
#
# =============================================================================
# AN UNPARSEABLE EVENT TAKES THE ERROR CHANNEL, AND IT IS STILL FAIL-CLOSED
# =============================================================================
# Same split as `run_api_gateway_pump`, same reason: a payload that is not a
# 2.0 REQUEST-authorizer event is a MISCONFIGURED INTEGRATION — no caller can
# fix it and every invocation fails identically — so it must land in the
# function's error metric and page somebody, not read as a trickle of denials
# from a function that looks healthy.
#
# => THE PROPERTY THAT MAKES THAT SAFE, AND IT IS ASSERTED RATHER THAN ARGUED:
#   on the parse-failure arm `respond_ok` is NEVER CALLED, so no
#   `isAuthorized` of any value reaches API Gateway at all. An authorizer that
#   errors cannot grant access — a Lambda error is a 500 and the backend is not
#   invoked. `tests/test_authorizer_pump.mojo:test_an_unparseable_event_posts_
#   no_verdict_at_all` pins both halves.
#
# AND UNLIKE THE PROXY PUMP, THERE IS NO RETRY HAZARD HERE. That loop routes a
# dispatcher raise to a 500 RESULT specifically so Lambda does not RETRY a
# non-idempotent verb. API Gateway invokes an authorizer SYNCHRONOUSLY
# (RequestResponse) and the platform does not retry a synchronous invoke, and an
# authorization decision has no side effect to duplicate — so the argument that
# forces the proxy loop's hand does not reach this one, and the channel choice
# is free to follow the cacheability argument above instead.
#
# ENCAPSULATION: owned values across every boundary. No `UnsafePointer`; no
# wildcard origin.
# =============================================================================

from .apigw_authorizer import (
    AUTHZ_ANSWER_DENY,
    ApiGatewayAuthorizerEvent,
    AuthorizerAnswer,
    authorizer_simple_response_json,
    parse_api_gateway_authorizer_event,
)
from .pump import LambdaInvocationTransport, LambdaPostResponseFlush


trait LambdaAuthorizer(Movable, Deinitable):
    """Decide ONE API Gateway REQUEST-authorizer invocation.

    ⛔ A CONFORMER SHOULD NOT RAISE FOR "I COULD NOT DECIDE" — it should return
    `AUTHZ_ANSWER_UNAVAILABLE`, which is a value the loop routes deliberately.
    A raise is treated as an internal fault and takes the same ERROR channel, so
    the two are not different outcomes at the gateway; the difference is that
    the returned ordinal is a case somebody reasoned about and a raise is not.
    (A conformer that wraps a fallible upstream check should convert that
    check's raise into `AUTHZ_ANSWER_UNAVAILABLE` itself, for exactly this
    reason.)

    ⛔ AND IT MUST NOT RETURN ALLOW WITHOUT HAVING PROVEN AN IDENTITY. This trait
    is designed to be the ONLY thing between a publicly-reachable API Gateway
    and the backend: any caller may reach the gateway, and the authorizer is
    what limits it. There is no resource policy and no IAM auth behind it."""

    def authorize(
        mut self, event: ApiGatewayAuthorizerEvent
    ) raises -> AuthorizerAnswer:
        ...


def run_authorizer_pump[
    A: LambdaAuthorizer,
    T: LambdaInvocationTransport,
    F: LambdaPostResponseFlush,
](
    mut transport: T,
    mut authorizer: A,
    mut flush: F,
    max_invocations: Int,
) raises -> Int:
    """Pump REQUEST-authorizer invocations through `authorizer`, returning the
    count handled.

    `max_invocations < 0` runs forever (the deployed shape). A non-negative
    value stops after that many, which is what lets a falsifier drive a REAL
    authorizer over a scripted transport with no socket and no cloud.

    ⛔ A FAILED POLL EXITS THE LOOP RATHER THAN RETRYING — `run_api_gateway_
    pump`'s measured reason: the earlier `continue` form spun on `ECONNREFUSED`
    as fast as the kernel could return it and burned billed CPU for the whole
    function timeout. Lambda REPLACES an exited runtime; that is the recovery.

    ⚠ THERE IS NO REACTOR PARAMETER, and that absence is a real difference from
    the proxy pump rather than an omission. That loop threads the server's
    reactor into `dispatch[RT]` so a handler's async I/O parks on the caller's
    reactor. The authorizer's seam (`LambdaAuthorizer.authorize`) takes no
    runtime parameter because a conformer's I/O is expected to be one
    synchronous upstream call; adding a reactor here would be a parameter
    nothing threads.
    """
    var handled = 0
    while max_invocations < 0 or handled < max_invocations:
        var inv = transport.next_invocation()
        var request_id = inv.request_id.copy()
        var event_json = inv.event.copy()

        var parsed = True
        var fault = String("")
        var answer = AuthorizerAnswer(AUTHZ_ANSWER_DENY)
        try:
            var event = parse_api_gateway_authorizer_event(event_json)
            try:
                answer = authorizer.authorize(event)
            except ae:
                # ⛔ A CONFORMER RAISE IS AN INTERNAL FAULT, NOT A DENY. Routing
                # it to `false` would file a broken authorizer under "the
                # customer's credential is bad" AND let API Gateway cache that
                # verdict for the TTL. The trait's docstring says a conformer
                # should return UNAVAILABLE instead; this arm is what happens
                # when one does not.
                parsed = False
                fault = String("authorizer-raised: ") + String(ae)
        except pe:
            parsed = False
            fault = String("authorizer-event-unparseable: ") + String(pe)

        if parsed and answer.is_allowed():
            transport.respond_ok(
                request_id, authorizer_simple_response_json(answer)
            )
        elif parsed and answer.kind == AUTHZ_ANSWER_DENY:
            # 403 at the gateway. `authorizer_simple_response_json` emits an
            # EMPTY context here whatever the value carries — enforced by the
            # serializer, not by this call site.
            transport.respond_ok(
                request_id, authorizer_simple_response_json(answer)
            )
        else:
            # ⛔ EVERY REMAINING CASE: an unparseable event, a conformer raise,
            # `AUTHZ_ANSWER_UNAVAILABLE`, and any ordinal this package has never
            # heard of. All become a Lambda invocation ERROR -> 500 at the
            # gateway -> NOT CACHED. ⚠ `respond_ok` is not called on this arm,
            # so no `isAuthorized` of any value reaches API Gateway.
            var message = fault.copy()
            if message.byte_length() == 0:
                message = (
                    String(
                        "authorizer-cannot-decide: the control plane could not"
                        " be asked (answer ordinal "
                    )
                    + String(answer.kind)
                    + String(
                        "). Reported on the invocation ERROR channel rather"
                        " than as isAuthorized=false so the outage stays out of"
                        " the deny rate AND out of API Gateway's result cache."
                    )
                )
            print(message)
            transport.report_error(request_id, message^)

        # ─────────────────────────────────────────────────────────────────────
        # ⛔ THE DRAIN, at the pump's drain position: after the POST
        #    above, before the `while` reaches `next_invocation()` again. On
        #    BOTH channels — an invocation that failed to parse is still an
        #    invocation that ended, and the records explaining why are exactly
        #    the ones worth not losing.
        # ─────────────────────────────────────────────────────────────────────
        _ = flush.flush_after_response()

        handled += 1
    return handled
