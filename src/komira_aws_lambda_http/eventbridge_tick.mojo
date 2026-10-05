# =============================================================================
# eventbridge_tick.mojo — an EventBridge Scheduler TICK payload -> the same
#   `HttpRequest` a `RequestDispatcher` already takes.
# =============================================================================
#
# =============================================================================
# WHY A SECOND CONVERTER EXISTS AT ALL — THE SCHEDULER CANNOT MAKE AN HTTP
#   REQUEST, SO A TICK IS NOT AN HTTP EVENT
# =============================================================================
#   **EVENTBRIDGE SCHEDULER CANNOT CALL AN HTTPS URL.** Its targets are
#   TEMPLATED AWS API operations (Lambda `Invoke`, SQS `SendMessage`, …) and
#   UNIVERSAL AWS SDK operations. Arbitrary HTTPS endpoints are an EventBridge
#   **RULES** feature (API destinations + Connections) and are NOT available to
#   Scheduler.
#
# So a scheduled call's `path` and `http_method` cannot travel in a request
# line, because there is no request. They travel as DATA, in `Target.Input`,
# rendered on the deploy side by exactly ONE place (the deploy side's schedule
# renderer) as
#
#   {"httpMethod":"POST","path":"/internal/tick/reconcile"}
#
# and the receiving function has to READ them. THIS FILE IS THE FAR SIDE OF
# THAT CONTRACT. Without it, the payload reaches `run_api_gateway_pump`,
# `api_gateway_v2_event_to_request` REFUSES it (correctly — it carries no
# `version`), and the pump routes that refusal to the invocation ERROR channel
# as a deployment fault. Every tick, forever, as a Lambda error: loudly and
# permanently broken rather than silently dropped, and still not a working
# backstop.
#
# =============================================================================
# THE DISCRIMINATOR IS `version`, IN BOTH DIRECTIONS, AND IT IS READ FIRST
# =============================================================================
# `apigw_v2.mojo`'s header carries the rule this file obeys — *"A CONVERTER THAT
# ACCEPTS BOTH ACCEPTS A MALFORMED ONE"* — and its `_require_v2` is the worked
# example: read the discriminator FIRST, refuse anything else BY NAME.
#
#   this file  : REFUSES on the PRESENCE of `version`  (that is an API Gateway
#                payload; it belongs to `api_gateway_v2_event_to_request`)
#   apigw_v2   : REFUSES on the ABSENCE of `version`
#
# SO THERE IS NO "TRY APIGW, FALL BACK TO TICK" READER IN THIS PACKAGE, AND
# ONE MUST NEVER BE WRITTEN. Handed a TRUNCATED 2.0 event — one that lost its
# `version` in transit, or an integration wired to a payload format nobody
# checked — such a reader does not report a truncated event. It reports A TICK,
# and dispatches whatever route the fallback invented. A tick fires a BACKSTOP,
# and a backstop invoked from a request the caller did not make is a write
# nobody asked for.
#
# => WHICH IS WHY NOTHING IN THIS FILE DEFAULTS A MISSING FIELD, even where the
#   RENDER side does. The renderer maps an empty `path` to `"/"` and an empty
#   `http_method` to `"POST"` — defaults applied where the author's intent is
#   known. Applying the same defaults on the READ side is precisely the
#   machinery that turns a truncated API Gateway event into "a tick for `/` by
#   POST": every field the fallback needed was supplied by the reader rather
#   than by the sender. A payload missing either key was not produced by the
#   renderer, so this file REFUSES it and names which key was absent.
#   `tests/test_eventbridge_tick.mojo:test_refuses_a_payload_with_no_path_
#   rather_than_defaulting_to_the_root` is that assertion.
#
# MEASURED: §1 IS SUBSUMED BY §2 IN *OUTCOME*, AND SEPARATED FROM IT ONLY BY
# ORDER AND MESSAGE. `version` is, trivially, a member outside the two-key
# contract, so §2 below would refuse every payload §1 refuses. Deleting the §1
# block and re-running the suite is GREEN — and a check no test can falsify is
# a check somebody deletes as dead. It is KEPT, and made observable, for two
# reasons that are not aesthetic:
#
#   1. **The message.** §1 runs FIRST, so a `version`-carrying payload is
#      reported as *"this is an API Gateway event, it belongs to the other
#      converter"* rather than as *"unknown member 'version'"*. Those send an
#      operator to two different places at 3am.
#   2. **It survives a loosening of §2.** §2's exactness is the strictest rule in
#      this file and therefore the likeliest to be relaxed ("ignore members we do
#      not read" is the ordinary wire-format instinct). §1 is what still refuses
#      an API Gateway event on the day somebody does that.
#
# `tests/test_eventbridge_tick.mojo:test_refuses_a_payload_that_carries_version_
# with_the_APIGW_refusal_not_the_shape_one` asserts the MESSAGE, because the
# message is the only thing that separates the two — and that test is RED under
# the §1 deletion, which is what makes this paragraph a measurement.
#
# =============================================================================
# §2 — THE SHAPE IS EXACT: AN UNKNOWN MEMBER IS A REFUSAL, NOT AN EXTRA
# =============================================================================
# `version` alone is not enough, and the counter-example is a REAL AWS event
# rather than a hypothetical one:
#
#   **A REST-API (payload format 1.0) PROXY EVENT CARRIES NO `version` FIELD AT
#   ALL**, and it carries `httpMethod` and `path` AT THE TOP LEVEL — the same
#   two keys, with the same spellings, as this contract. (An HTTP API opted in
#   to 1.0 does stamp `"version": "1.0"`; a REST API does not stamp one.) So a
#   REST proxy event handed to a `version`-only discriminator is a well-formed
#   TICK carrying the caller's method and the caller's path — a request from the
#   public internet, converted into an internal scheduled call, with its body,
#   its headers and its query silently discarded.
#
# The contract is a TWO-KEY OBJECT and nothing else, so that is what is
# asserted: any member other than `httpMethod` and `path` is a REFUSAL naming
# the member. That rejects the REST-1.0 shape by construction (on `resource`,
# `requestContext`, `headers`, `multiValueHeaders`, `queryStringParameters`,
# `body`, `isBase64Encoded` — whichever is hit first) and it does not depend on
# anyone having enumerated the shapes AWS may ship next.
#
# IT IS A REFUSAL AND NOT AN "IGNORE WHAT WE DO NOT READ" because this payload
# has exactly ONE author (the renderer above), so an unknown member is not a
# newer peer — it is a different event shape that got here by mistake, and the
# mistakes that reach a Lambda's invoke channel are misconfigured integrations,
# which is the class this package refuses by name everywhere else.
#
# =============================================================================
# §3 — AN UNRECOGNISED VERB RAISES HERE, AND THAT IS THE DELIBERATE INVERSION
#   OF `apigw_v2._method_from_name`'s RULE
# =============================================================================
# The verb TABLE is shared — `_method_from_name` is imported, not re-written, so
# the two arms cannot drift about what `PATCH` is. What differs is what an
# unrecognised verb MEANS, and it differs because the sender differs:
#
#   apigw arm : the sender is a CLIENT. An odd verb is a request-level condition
#               the dispatcher already answers (405). Raising would file a bad
#               request on the Lambda ERROR channel and page somebody.
#   tick  arm : the sender is OUR OWN DEPLOYMENT — the schedule's verb, rendered
#               by the deploy side. An odd verb here is deploy data that is
#               wrong, i.e. a deployment fault, which is exactly what the ERROR
#               channel is for. Answering 405 to a scheduler instead would
#               surface only as a `Target.Input` that "ran fine" and a backstop
#               that never ticks.
#
# =============================================================================
# §4 — A QUERY IN `path` IS SPLIT, FOR CROSS-CLOUD AGREEMENT
# =============================================================================
# On GCP, Cloud Scheduler delivers a real HTTP request to `<service url> +
# path`, so a query written into `path` survives to the handler as a query BY
# CONSTRUCTION. If this arm did not split it, the SAME schedule field would mean
# two different things on two clouds, and the AWS side's version of it would
# 404 in a scheduler metric nobody reads. So `path` is split on the FIRST `?`:
# everything before it is `req.path`, everything after is `req.query_string`,
# which is already that field's contract (no leading `?`, same as
# `rawQueryString`).
#
# =============================================================================
# §5 — A TICK CARRIES NO HEADERS, BY CONSTRUCTION, AND THAT IS A SECURITY
#   PROPERTY RATHER THAN A SIMPLIFICATION
# =============================================================================
# `apigw_v2.mojo` §3 spends its longest section on one hazard: the authorizer's
# answer reaches the handler through `req.headers`, and the CLIENT controls
# `headers` too, so every client header under the caller-chosen authorizer
# prefix is DESTROYED on entry. The request this file builds starts with an EMPTY header
# dict and never adds one, so the reserved namespace cannot be reached from a
# tick payload at all — and §2's exact-shape rule refuses a payload that tries
# to carry `headers` before the question arises.
#
# NO MARKER HEADER IS INJECTED EITHER (no `x-komira-tick`), deliberately. The
# payload's keys are the proxy event's keys so that a handler written against
# either reads this payload unchanged. A marker header would be a SECOND
# one-sided contract with nothing on the far side.
#
# =============================================================================
# §6 — THE RESIDUAL, STATED SO IT IS NOT MISTAKEN FOR COVERAGE
# =============================================================================
#   * **A TICK ANSWERED 5xx IS STILL REPORTED TO EVENTBRIDGE AS A SUCCESSFUL
#     INVOKE.** `run_api_gateway_and_tick_pump` posts the handler's response on
#     the RESULT channel for both shapes, so a backstop that answers 500 on every
#     pass looks green in the schedule's metrics. Routing a 5xx to the invocation
#     ERROR channel instead would make it visible AND would hand it to
#     EventBridge's retry policy, which a schedule that does not model it gets
#     reset to the service default (185 attempts) on every update. That is a
#     decision about the SCHEDULE and belongs to whatever owns the schedule,
#     not to this converter.
#   * NOTHING HERE PROVES A DEPLOYED SCHEDULE EVER INVOKED A DEPLOYED FUNCTION.
#     The read side of the payload contract is pinned by tests in this package,
#     which is a strictly different claim from a tick having arrived.
#
# ENCAPSULATION: every function here takes and returns owned values —
# `String`, `HttpRequest`. No `UnsafePointer` crosses any boundary, no wildcard
# origin, no `unsafe_from_address`.
# =============================================================================

from komira_http_core.codec.types import HttpRequest
from komira_http_core.codec.types import HTTP_METHOD_UNKNOWN

from komira_json import JsonValue, parse_json_value

from .apigw_v2 import _method_from_name


# The two members the schedule renderer emits, and the ONLY two this
# converter accepts (§2). ⛔ THE SPELLINGS ARE THE CONTRACT — the render side
# pins them with a test for the same reason, and a handler expecting `method`
# against a payload carrying `httpMethod` produces a function that runs, reports
# success, and does nothing forever.
comptime TICK_METHOD_KEY: String = "httpMethod"
comptime TICK_PATH_KEY: String = "path"

# The field whose PRESENCE means "this is an API Gateway payload, not a tick".
# Read FIRST, refused BY NAME — `apigw_v2._require_v2`'s discipline, mirrored.
comptime APIGW_DISCRIMINATOR_KEY: String = "version"

# The two answers `classify_lambda_event` gives. Ordinals rather than a Bool so
# a third shape (an SQS batch, an S3 notification) can be added as a NAMED case
# instead of by inverting somebody's `if`.
comptime LAMBDA_EVENT_KIND_API_GATEWAY: Int = 1
comptime LAMBDA_EVENT_KIND_SCHEDULED_TICK: Int = 2


def classify_lambda_event(event_json: String) raises -> Int:
    """Decide WHICH converter a raw invocation payload belongs to, before any
    conversion is attempted.

    ⛔ IT COMMITS; IT DOES NOT TRY. The answer is a function of ONE field —
    `version` present => API Gateway, absent => scheduled tick — and nothing
    downstream is permitted to change its mind. A classifier that fell through
    to a second converter on the first one's refusal would BE the "try apigw,
    fall back to tick" reader this file's header forbids, just spelled across two
    functions.

    ⚠ EACH CONVERTER RE-ASSERTS ITS OWN DISCRIMINATOR ANYWAY, and that is not
    redundancy. `api_gateway_v2_event_to_request` and
    `eventbridge_tick_event_to_request` are both PUBLIC and both are called
    directly (by `run_api_gateway_pump`, which is unchanged, and by the
    falsifiers), so each must be safe on its own. This function is a router, not
    a trusted preamble, and nothing may be deleted from either converter on the
    grounds that the router already checked it.

    RAISES when the payload is not a JSON object at all — a direct invoke
    carrying an array, an SQS batch, an S3 notification. Guessing a kind for one
    of those is guessing which handler gets a request nobody made."""
    var event = parse_json_value(event_json)
    if not event.is_object():
        raise Error(
            String(
                "lambda-event: the invocation payload is not a JSON object."
                " This function serves exactly two shapes — an API Gateway"
                " payload-format-2.0 proxy event, and the EventBridge Scheduler"
                " `Target.Input` tick the deploy side renders"
                ' ({"httpMethod":…,"path":…}) — and an array or a scalar is'
                " neither. If this fired, something other than API Gateway or"
                " EventBridge Scheduler is pointed at this function."
            )
        )
    if event.has(String(APIGW_DISCRIMINATOR_KEY)):
        return LAMBDA_EVENT_KIND_API_GATEWAY
    return LAMBDA_EVENT_KIND_SCHEDULED_TICK


def eventbridge_tick_event_to_request(event_json: String) raises -> HttpRequest:
    """Convert one EventBridge Scheduler `Target.Input` tick payload into the
    `HttpRequest` the shipped `RequestDispatcher` already takes.

    The payload is the schedule renderer's output and nothing else:

        {"httpMethod":"POST","path":"/internal/tick/reconcile"}

    RAISES — never returns a degraded request — when the payload carries
    `version` (it is an API Gateway event, §1), when it carries any member
    outside the two-key contract (§2), when either key is absent, empty, or not
    a string, when the path does not start with `/`, or when the verb is not one
    the shared `HttpMethod` table knows (§3). Every one of those is a case
    where a "best effort" request would fire a BACKSTOP on a route nobody
    scheduled.

    Field coverage (every one is asserted by a falsifier):
      `version`     -> must be ABSENT; its presence is the refusal (§1)
      `httpMethod`  -> `req.method`, unrecognised verb REFUSED (§3)
      `path`        -> `req.path` + `req.query_string`, split on the first `?` (§4)
      (anything else) -> REFUSED by name (§2)
      `req.headers` -> EMPTY, by construction and on purpose (§5)
      `req.body`    -> EMPTY. A tick carries no body; there is no key for one."""
    var event = parse_json_value(event_json)
    if not event.is_object():
        raise Error(
            String(
                "eventbridge-tick: the invocation payload is not a JSON object."
                " A scheduled tick is the `Target.Input` rendered by the"
                " deploy side's schedule renderer, which is always a two-member"
                ' object ({"httpMethod":…,"path":…}).'
            )
        )

    # ── §1. THE DISCRIMINATOR, READ FIRST. ──────────────────────────────────
    if event.has(String(APIGW_DISCRIMINATOR_KEY)):
        raise Error(
            String(
                "eventbridge-tick: payload carries `version`, which makes it an"
                " API GATEWAY event and not an EventBridge Scheduler tick."
                " Converting it here would produce a request built from"
                " whichever of `httpMethod`/`path` happened to be present — i.e."
                " a TICK, firing a backstop, for a request a caller made."
                " API Gateway events belong to"
                " `apigw_v2.api_gateway_v2_event_to_request`; if this fired on a"
                " real scheduled tick, something is rendering `Target.Input`"
                " other than the deploy side's schedule renderer."
            )
        )

    # ── §2. THE SHAPE IS EXACT. An unknown member is a refusal, by name. ─────
    for i in range(event.num_members()):
        var member = event.key_at(i)
        if member == String(TICK_METHOD_KEY) or member == String(TICK_PATH_KEY):
            continue
        raise Error(
            String("eventbridge-tick: payload carries the member '")
            + member
            + String(
                "', which is not part of the scheduled-call contract. That"
                " contract is exactly two members — `httpMethod` and `path` —"
                " rendered by the deploy side's schedule renderer and by"
                " nothing else. ⚠ THE SHAPE THIS REFUSAL EXISTS FOR is a"
                " REST-API (payload format 1.0) PROXY EVENT: it carries NO"
                " `version`, and"
                " it carries `httpMethod` and `path` at the top level with the"
                " same spellings as this contract — so a discriminator reading"
                " `version` alone would convert a caller's public request into"
                " an internal scheduled call, discarding its body, headers and"
                " query. Extra members are refused rather than ignored because"
                " this payload has exactly ONE author (that renderer), so an"
                " unknown member is a different event shape and not a newer"
                " peer."
            )
        )

    # ── the two members, each REQUIRED — never defaulted (§1). ──────────────
    var method_name = _require_string_member(event, String(TICK_METHOD_KEY))
    var raw_path = _require_string_member(event, String(TICK_PATH_KEY))

    var req = HttpRequest()

    # ── §3. the verb. Shared table, inverted rule for an unknown verb. ───────
    var method = _method_from_name(method_name)
    if method.code == HTTP_METHOD_UNKNOWN:
        raise Error(
            String("eventbridge-tick: `httpMethod` = '")
            + method_name
            + String(
                "' is not a verb this runtime's `HttpMethod` table knows. ⚠ THIS"
                " IS THE DELIBERATE INVERSION of the API Gateway arm, which maps"
                " an unrecognised verb to HTTP_METHOD_UNKNOWN and lets the"
                " dispatcher answer 405. There the sender is a CLIENT and an odd"
                " verb is a request-level condition; here the sender is the"
                " deploy side's own schedule (the schedule's verb, rendered"
                " into `Target.Input` at deploy time), so an odd verb is"
                " deploy data that is wrong — a deployment fault, which belongs"
                " on the invocation ERROR channel. A 405 answered to a scheduler"
                " is visible to nobody and the backstop simply never ticks."
            )
        )
    req.method = method

    # ── §4. path + query. Split on the FIRST `?`, for cross-cloud agreement. ─
    if not _starts_with_slash(raw_path):
        raise Error(
            String("eventbridge-tick: `path` = '")
            + raw_path
            + String(
                "' does not start with '/'. The deploy side's schedule"
                " validation governs this at authoring time and its"
                " schedule renderer refuses it again at render"
                " time; this is the third and last place, on the READ side,"
                " because a path that lost its leading slash between the three"
                " is a symptom and prefixing one back would launder it into a"
                " route that dispatches somewhere."
            )
        )
    var q_at = _index_of_question_mark(raw_path)
    if q_at < 0:
        req.path = raw_path^
        req.query_string = String("")
    else:
        req.path = _slice(raw_path, 0, q_at)
        req.query_string = _slice(raw_path, q_at + 1, raw_path.byte_length())

    # ── §5. NO headers, NO body. Both are the empty value `HttpRequest()` was
    #    constructed with, restated here so a reader does not go looking for the
    #    line that fills them in.
    return req^


def _require_string_member(event: JsonValue, key: String) raises -> String:
    """One contract member: present, a JSON string, and NON-EMPTY.

    ⛔ ALL THREE ARE REFUSALS AND NONE IS A DEFAULT — this is where §1's rule
    lands in code. The schedule renderer maps an empty `path` to `"/"`
    and an empty `http_method` to `"POST"` on the RENDER side, where the author's
    intent is known; supplying those same values on the READ side is exactly the
    machinery that lets a payload which is NOT a tick be read as "a tick for `/`
    by POST"."""
    if not event.has(key):
        raise Error(
            String("eventbridge-tick: payload has no `")
            + key
            + String(
                "` member. Both members of the scheduled-call contract are"
                " REQUIRED on the read side, and neither is defaulted — a"
                " payload missing one was not rendered by the deploy side's"
                " schedule renderer, and inventing the missing"
                " value is how a truncated event from some other source becomes"
                " a well-formed tick that fires a backstop."
            )
        )
    var v = event.get(key)
    if v.kind_tag() != 3:  # JSON_STRING
        raise Error(
            String("eventbridge-tick: `")
            + key
            + String(
                "` is present but is not a JSON string."
                " The schedule renderer emits both members as string"
                " literals, so a non-string here means the payload was assembled"
                " by something else."
            )
        )
    var s = v.as_string()
    if s.byte_length() == 0:
        raise Error(
            String("eventbridge-tick: `")
            + key
            + String(
                "` is present but EMPTY. The renderer substitutes the"
                " schedule's default before emitting (`/` for the path, `POST`"
                " for the method), so an empty value never leaves it; accepting"
                " one here"
                " would mean re-deriving that default from a payload whose"
                " author is unknown."
            )
        )
    return s^


def _starts_with_slash(s: String) -> Bool:
    var b = s.as_bytes()
    if len(b) == 0:
        return False
    return b[0] == UInt8(0x2F)


def _index_of_question_mark(s: String) -> Int:
    """Byte offset of the FIRST `?`, or -1. First rather than last: everything
    after the first `?` is the query, `?` included, per RFC 3986."""
    var b = s.as_bytes()
    for i in range(len(b)):
        if b[i] == UInt8(0x3F):
            return i
    return -1


def _slice(s: String, start: Int, end: Int) -> String:
    """The byte-range substring `s[start:end]`, built with the in-tree
    `StringSlice(unsafe_from_utf8=Span(...))` pattern (Mojo's `String` has no
    byte-range slice-getitem).

    ⚠ IT MUST NOT BE THE `out += chr(Int(b[i]))` LOOP that several siblings use
    for the same job. That loop re-ENCODES each byte as its own code point, so a
    path carrying any byte >= 0x80 — a UTF-8 route, a percent-decoded segment —
    comes back mojibake, silently, and the tick dispatches to a route that is not
    the one the schedule named. The split point itself is safe either way (an
    ASCII `?` cannot occur inside a multi-byte sequence, every continuation byte
    being >= 0x80), but the BYTES ON EITHER SIDE OF IT are not."""
    var b = s.as_bytes()
    var n = len(b)
    var lo = start if start > 0 else 0
    var hi = end if end < n else n
    if hi <= lo:
        return String("")
    var out = List[UInt8](capacity=hi - lo)
    for i in range(lo, hi):
        out.append(b[i])
    return String(StringSlice(unsafe_from_utf8=Span(out)))
