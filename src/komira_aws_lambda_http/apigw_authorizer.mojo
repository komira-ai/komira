# =============================================================================
# apigw_authorizer.mojo — the API Gateway **REQUEST AUTHORIZER** event, and the
#   simple response. A DIFFERENT PAYLOAD FROM THE PROXY EVENT, parsed as one.
# =============================================================================
#
# =============================================================================
# THE FINDING THAT DECIDES THIS FILE'S EXISTENCE
# =============================================================================
# The v2 REQUEST-authorizer payload is NOT a subset of the proxy payload and it
# is not a superset either — but it OVERLAPS the proxy payload on every field
# `api_gateway_v2_event_to_request` reads:
#
#     field                         proxy 2.0   REQUEST-authorizer 2.0
#     `version`                     "2.0"       "2.0"        <- SAME
#     `requestContext.http.method`  present     present      <- SAME
#     `rawPath`                     present     present      <- SAME
#     `headers`                     present     present      <- SAME
#     `body` / `isBase64Encoded`    present     ABSENT
#     `type`                        ABSENT      "REQUEST"    <- THE DISCRIMINATOR
#     `routeArn` / `identitySource` ABSENT      present
#
# => A proxy parser that did not read `type` would HAPPILY ACCEPT AN AUTHORIZER
# EVENT: it reads a 2.0 version, finds `requestContext.http`, and returns a
# well-formed `HttpRequest` with an empty body. Nothing raises. So "extend the
# proxy parser to also handle it" is not a shortcut with a cost — it is the
# defect, because the two shapes are indistinguishable to every check that
# parser makes. `apigw_v2._require_v2` REFUSES an event carrying `type`, and
# `tests/test_apigw_v2.mojo:test_refuses_a_request_authorizer_event` is the
# falsifier for that half; this file is the other half.
#
# `type` IS ASSERTED, NOT SNIFFED, FOR THE SAME REASON `version` IS. A parser
# here that accepted a payload with no `type` would accept a PROXY event, and
# would then authorize a request out of a body-bearing payload nobody meant to
# hand it. The value must be exactly `REQUEST`; `TOKEN` is the REST-API shape
# (it carries `authorizationToken`, not `headers`) and `JWT` is not a Lambda
# authorizer at all.
#
# =============================================================================
# §2 — WHAT MAY GO IN `context`: "RE-VERIFIABLE OR NOT AT ALL"
# =============================================================================
# `{"isAuthorized": true, "context": {...}}` is the SIMPLE response format. On
# an ALLOW, API Gateway copies `context`'s members into
# `requestContext.authorizer.lambda` of the PROXY event it then sends to the
# backend — where `apigw_v2._inject_authorizer_context` turns each into a
# header under the caller's `AuthorizerHeaderPrefix` the handler can read.
#
# => A `context` MEMBER IS AN ASSERTION THE BACKEND WILL TRUST WITHOUT PROOF.
# So the rule is not "what is useful" but:
#
#     PUT IN `context` ONLY FACTS THE AUTHORIZER PROVED **AND** THE BACKEND
#     COULD NOT RE-DERIVE MORE CHEAPLY — never a fact whose staleness changes
#     an authorization.
#
# AND THE STALENESS BOUND IS NOT OURS. API Gateway caches the authorizer's
# whole response for `AuthorizerResultTtlInSeconds`, keyed on the identity
# source. Every member of `context` is therefore a fact we are willing to be up
# to the TTL stale about.
#
# ON A DENY, `context` IS EMITTED EMPTY, UNCONDITIONALLY. API Gateway drops it
# anyway, so this buys nothing at the gateway — it buys the property that a
# refusal never CARRIES the claimed identity. A populated identity on a refusal
# is indistinguishable from a populated identity on an allow at the one point
# where the difference is the whole decision, and the serializer enforces it
# rather than trusting every caller to.
#
# =============================================================================
# §3 — THREE ANSWERS, TWO WIRE SHAPES, AND THE THIRD IS NOT `isAuthorized`
# =============================================================================
# An authorizer's decision core should keep DENY and UNAVAILABLE
# distinguishable — 403 vs 503 — so an outage is not hidden inside normal
# denials. The simple response has ONE BIT and cannot carry that distinction:
# `isAuthorized: false` is a 403 and there is no other value.
#
# => `AUTHZ_ANSWER_UNAVAILABLE` IS THEREFORE NOT A RESPONSE AT ALL. It is routed
# to the Lambda invocation ERROR channel by `authorizer_pump`, which API Gateway
# renders as a **500**. That is the only shape that does both of these at once:
#   * it keeps a backend outage in the function's ERROR metric instead of in
#     its deny rate; and
#   * it keeps the outage OUT OF API GATEWAY'S CACHE. A `false` would be cached
#     for the TTL, which would convert one failed upstream call into the whole
#     TTL of guaranteed failure — turning a blip into an outage. We do not
#     control API Gateway's cache policy; we control which answers reach it.
#
# All three are fail-closed. Only `AUTHZ_ANSWER_ALLOW` grants anything, and it
# is the only ordinal `is_allowed()` returns True for.
#
# ENCAPSULATION: owned values across every boundary — `String`,
# `List[String]`, `Dict[String, String]`. No `UnsafePointer`, no wildcard
# origin.
# =============================================================================

from komira_json import JsonValue, parse_json_value

from .apigw_v2 import APIGW_PAYLOAD_VERSION, _ascii_lower, _opt_string


# The ONE authorizer payload `type` this file speaks. Read `_require_request_
# authorizer` before changing it: the value is asserted, not defaulted.
comptime APIGW_AUTHORIZER_EVENT_TYPE: String = "REQUEST"


# =============================================================================
# §1 — the three answers.
# =============================================================================
# Stable ordinals 0/1/2. A consumer whose own decision core spells these
# differently should pin the correspondence with a test that imports both sets
# and asserts equality, rather than translating at the seam — a translation is
# one more place for "the backend could not be asked" to be spelled as an allow.
comptime AUTHZ_ANSWER_ALLOW: Int = 0
comptime AUTHZ_ANSWER_DENY: Int = 1
comptime AUTHZ_ANSWER_UNAVAILABLE: Int = 2


struct ApiGatewayAuthorizerEvent(Movable, Deinitable):
    """One API Gateway payload-format-2.0 **REQUEST authorizer** invocation.

    ⚠ THERE IS NO `body` FIELD AND THERE MUST NOT BE ONE. The authorizer payload
    carries no body at all — API Gateway does not hand the request body to an
    authorizer — so a field for it could only ever be empty, and an empty field
    invites a caller to read it as "the request had no body"."""

    # `arn:aws:execute-api:<region>:<account>:<apiId>/<stage>/<method>/<path>` —
    # WHICH door invoked us. Informational here; never part of the decision.
    var route_arn: String
    # `$default`, `POST /v1/messages`, … — the route key as configured.
    var route_key: String
    var raw_path: String
    # `requestContext.http.method`, verbatim and uppercase as API Gateway sends
    # it. NOT converted to an `HttpMethod`: this file routes nothing.
    var http_method: String
    # ★ THE RESOLVED IDENTITY SOURCES, IN THE ORDER THE AUTHORIZER DECLARES
    # THEM. ⛔ AND THE CREDENTIAL IS **NOT** READ FROM HERE — see
    # `authorizer_header`'s docstring for why the header is the source of truth
    # and this list is diagnostic only.
    var identity_source: List[String]
    # Header names ASCII-LOWERCASED. API Gateway already lowercases them in a
    # 2.0 payload; doing it again costs nothing and removes a dependency on that
    # continuing to be true.
    var headers: Dict[String, String]
    # `requestContext.requestId` — the ONE field worth putting in a log line, so
    # a refusal here can be correlated with the gateway's own access log.
    var request_id: String

    def __init__(out self):
        self.route_arn = String("")
        self.route_key = String("")
        self.raw_path = String("")
        self.http_method = String("")
        self.identity_source = List[String]()
        self.headers = Dict[String, String]()
        self.request_id = String("")

    def header(self, name: String) -> String:
        """The named header's value, or `""`. `name` must already be lowercase.

        ⚠ ABSENT AND EMPTY ARE THE SAME ANSWER, and every caller's handling of
        both is identical: a credential of `""` is not a credential."""
        var got = self.headers.get(name)
        if not got:
            return String("")
        return got.value()


def parse_api_gateway_authorizer_event(
    event_json: String,
) raises -> ApiGatewayAuthorizerEvent:
    """Parse one API Gateway payload-format-2.0 REQUEST-authorizer event.

    RAISES — never returns a degraded event — when the payload is not a JSON
    object, when `version` is not `2.0`, or when `type` is not exactly
    `REQUEST`. Those three together are what distinguishes this payload from the
    PROXY payload, which overlaps it on every other field this parser reads (see
    the file header); accepting a proxy event here would mean authorizing a call
    described by a payload nobody meant to hand an authorizer.

    ⚠ EVERY OTHER FIELD IS OPTIONAL AND DEFAULTS TO EMPTY, deliberately. A
    missing `routeArn` or `identitySource` cannot change the decision — the
    decision is a function of the credential and of the upstream authority's
    answer — so refusing on their absence would convert an AWS payload
    revision into a total outage while buying no safety. What is NOT optional
    is the shape assertion, because that is the one that keeps a different
    event out.

    Raises:
        If the payload is not an object, is not version 2.0, or is not a
        `REQUEST` authorizer event.
    """
    var event = parse_json_value(event_json)
    if not event.is_object():
        raise Error(
            String(
                "apigw-authorizer: the invocation payload is not a JSON object"
                " — this runtime is bound to an API Gateway REQUEST authorizer"
                " and received something else (a direct invoke? an SQS event?)"
            )
        )
    _require_v2_authorizer(event)

    var out = ApiGatewayAuthorizerEvent()
    out.route_arn = _opt_string(event, String("routeArn"))
    out.route_key = _opt_string(event, String("routeKey"))
    out.raw_path = _opt_string(event, String("rawPath"))

    if event.has(String("identitySource")):
        var ids = event.get(String("identitySource"))
        if ids.is_array():
            for i in range(ids.array_len()):
                var el = ids.element_at(i)
                if el.kind_tag() == 3:  # JSON_STRING
                    out.identity_source.append(el.as_string())

    if event.has(String("headers")):
        var hdrs = event.get(String("headers"))
        if hdrs.is_object():
            for i in range(hdrs.num_members()):
                var v = hdrs.value_at(i)
                if v.kind_tag() != 3:  # JSON_STRING
                    continue
                var name = _ascii_lower(hdrs.key_at(i))
                out.headers[name^] = v.as_string()

    if event.has(String("requestContext")):
        var rc = event.get(String("requestContext"))
        if rc.is_object():
            out.request_id = _opt_string(rc, String("requestId"))
            if rc.has(String("http")):
                var http = rc.get(String("http"))
                if http.is_object():
                    out.http_method = _opt_string(http, String("method"))

    return out^


def _require_v2_authorizer(event: JsonValue) raises:
    """⛔ THE SHAPE ASSERTION. Two fields, and BOTH are load-bearing.

    `version` for `apigw_v2._require_v2`'s reason: a 1.0 REQUEST authorizer
    event puts the method at `httpMethod` and the headers under
    `multiValueHeaders`, so reading one as 2.0 yields an event with no method
    and NO `authorization` header — i.e. a DENY attributed to the caller for a
    misconfiguration of ours.

    `type` because it is the ONLY field that separates this payload from the
    PROXY payload. A parser that skipped it would accept a proxy event, which is
    exactly the mistake this whole file exists to make impossible."""
    if not event.has(String("version")):
        raise Error(
            String(
                "apigw-authorizer: event carries no `version` field. This"
                " runtime speaks payload format "
            )
            + String(APIGW_PAYLOAD_VERSION)
            + String(
                " ONLY. A 1.0 authorizer event carries the headers under"
                " `multiValueHeaders` and would produce a request with NO"
                " authorization header — a deny blamed on the caller for a"
                " misconfiguration of ours."
            )
        )
    var got = event.get(String("version"))
    var got_s = String("")
    if got.kind_tag() == 3:
        got_s = got.as_string()
    if got_s != String(APIGW_PAYLOAD_VERSION):
        raise Error(
            String("apigw-authorizer: unsupported payload format version '")
            + got_s
            + String("' — this runtime speaks ")
            + String(APIGW_PAYLOAD_VERSION)
            + String(" only.")
        )

    if not event.has(String("type")):
        raise Error(
            String(
                "apigw-authorizer: event carries no `type` field, so it is a"
                " PROXY event and not an authorizer event. The two payloads"
                " agree on `version`, `rawPath`, `headers` and"
                " `requestContext.http` — `type` is the ONLY field that tells"
                " them apart, which is why its absence is a refusal rather than"
                " a default."
            )
        )
    var t = event.get(String("type"))
    var t_s = String("")
    if t.kind_tag() == 3:
        t_s = t.as_string()
    if t_s != String(APIGW_AUTHORIZER_EVENT_TYPE):
        raise Error(
            String("apigw-authorizer: REFUSED authorizer event type '")
            + t_s
            + String("' — this runtime speaks ")
            + String(APIGW_AUTHORIZER_EVENT_TYPE)
            + String(
                " only. `TOKEN` is the REST-API shape (it carries"
                " `authorizationToken` and no `headers` at all) and `JWT` is"
                " not a Lambda authorizer; coercing either would authorize"
                " against fields that are not there."
            )
        )


# =============================================================================
# §2 — the answer, and what it is allowed to carry.
# =============================================================================
struct AuthorizerAnswer(Movable, Deinitable):
    """One authorizer verdict plus the context an ALLOW hands the backend.

    ★ THE CONTEXT IS TWO PARALLEL LISTS, NOT A `Dict`, and the reason is
    `add_context`'s duplicate-key REFUSAL: a `Dict` assignment overwrites
    silently, so two disagreeing values for one identity fact would ship the
    second one with no diagnostic. A list can be searched before it is appended
    to, which is what makes that refusal expressible at all."""

    var kind: Int
    var _ctx_keys: List[String]
    var _ctx_values: List[String]

    def __init__(out self, kind: Int):
        self.kind = kind
        self._ctx_keys = List[String]()
        self._ctx_values = List[String]()

    def is_allowed(self) -> Bool:
        """⛔ THE ONLY ALLOW PATH. Everything that is not exactly
        `AUTHZ_ANSWER_ALLOW` is not an allow — UNAVAILABLE included, and so is
        any ordinal this package has never heard of."""
        return self.kind == AUTHZ_ANSWER_ALLOW

    def add_context(mut self, var key: String, var value: String) raises:
        """Add ONE `context` member.

        ⛔ REFUSES AN EMPTY KEY AND A DUPLICATE KEY. API Gateway's own
        serializer would accept both and the LAST duplicate would silently win —
        so a caller that computed a subject id twice, differently, would ship the
        second one with no diagnostic. Refusing is the only outcome that cannot
        be a silently-wrong identity.

        ⚠ IT DOES NOT VALIDATE THE VALUE, and it must not: the value is an
        opaque string the AUTHORIZER proved. What it is allowed to BE is a
        policy question the caller answers (see the file header §2), and a
        length check here would read like one."""
        if key.byte_length() == 0:
            raise Error(
                String(
                    "apigw-authorizer: refused an EMPTY context key. API"
                    " Gateway would accept it and the backend would receive a"
                    " header named by the reserved prefix alone."
                )
            )
        for i in range(len(self._ctx_keys)):
            if self._ctx_keys[i] == key:
                raise Error(
                    String(
                        "apigw-authorizer: refused a DUPLICATE context key '"
                    )
                    + key
                    + String(
                        "'. The last write would silently win, so two"
                        " disagreeing values for one identity fact would ship"
                        " the second with no diagnostic."
                    )
                )
        self._ctx_keys.append(key^)
        self._ctx_values.append(value^)

    def context_len(self) -> Int:
        """Diagnostic. Lets a falsifier assert that a DENY carries nothing."""
        return len(self._ctx_keys)


def authorizer_simple_response_json(answer: AuthorizerAnswer) raises -> String:
    """Serialize one verdict into API Gateway's SIMPLE response format:
    `{"isAuthorized": <bool>, "context": {...}}`.

    ⛔ `isAuthorized` IS TRUE ONLY FOR `AUTHZ_ANSWER_ALLOW`. It is derived from
    `is_allowed()` — the single predicate — rather than from `kind != DENY`, so
    an ordinal nobody has reasoned about serializes as `false`.

    ⛔⛔ A NON-ALLOW SERIALIZES AN EMPTY `context`, WHATEVER THE VALUE HOLDS.
    That is enforced HERE rather than at every construction site, because "the
    caller remembered to clear it" is a convention and this is a type. See the
    file header §2: a refusal must not carry the claimed identity.

    ⚠ `context` IS ALWAYS EMITTED, even when empty. API Gateway accepts its
    absence, but a payload whose shape depends on the outcome makes a
    field-by-field falsifier assert two different things about one contract."""
    var out = JsonValue.empty_object()
    var allowed = answer.is_allowed()
    out.set_member(String("isAuthorized"), JsonValue.from_bool(allowed))

    var ctx = JsonValue.empty_object()
    if allowed:
        for i in range(answer.context_len()):
            ctx.set_member(
                answer._ctx_keys[i].copy(),
                JsonValue.from_string(answer._ctx_values[i].copy()),
            )
    out.set_member(String("context"), ctx^)
    return out.serialize()


def authorizer_deny_json() raises -> String:
    """The payload for "no", with nothing else in it.

    The ONE spelling of a deny on the wire, so the pump and every caller emit
    the same bytes and a falsifier can compare against a literal."""
    return authorizer_simple_response_json(
        AuthorizerAnswer(AUTHZ_ANSWER_DENY)
    )
