# =============================================================================
# apigw_v2.mojo — an API Gateway proxy event <-> the `HttpRequest` /
#   `HttpResponse` a `RequestDispatcher` already takes. Payload format version
#   2.0, PINNED.
# =============================================================================
#
# =============================================================================
# THE VERSION IS 2.0, IT IS ASSERTED RATHER THAN SNIFFED, AND HERE IS WHY
# =============================================================================
# API Gateway emits two INCOMPATIBLE event shapes for the same HTTP request:
#
#            | 1.0 (REST API / HTTP API opt-in)   | 2.0 (HTTP API default)
#   method   | `httpMethod`                       | `requestContext.http.method`
#   path     | `path`                             | `rawPath`
#   query    | `queryStringParameters` + `multi…` | `rawQueryString` (no `?`)
#   headers  | `headers` + `multiValueHeaders`    | `headers` (comma-joined)
#   cookies  | inside `headers.Cookie`            | `cookies`, a JSON ARRAY
#   authzr   | `requestContext.authorizer` (flat) | `requestContext.authorizer.lambda`
#
# A CONVERTER THAT ACCEPTS BOTH ACCEPTS A MALFORMED ONE. The shapes overlap:
# a 1.0 event and a 2.0 event both have `headers` and both have `requestContext`.
# A "try 2.0, fall back to 1.0" reader handed a 2.0 event whose `requestContext`
# is truncated does not report a truncated event — it reports a 1.0 event with no
# method, and answers 405 to a request the caller sent as POST. So `version` is
# read FIRST and anything that is not exactly `"2.0"` is a REFUSAL naming what it
# got. `tests/test_apigw_v2.mojo:test_refuses_a_1_0_event` is that assertion.
#
# WHY 2.0 IS THE ONE PINNED, not merely the one picked:
#   1. **It is the HTTP API default.** A front door built as an API Gateway
#      HTTP API with a Lambda REQUEST authorizer receives 2.0 unless someone
#      opts out.
#   2. **It is the format whose authorizer answer we want.** 2.0 admits the
#      simple `{"isAuthorized": bool, "context": {...}}` authorizer response, so
#      the authorizer can hand the handler an identity without the handler
#      re-deriving one. See §3.
#   3. **Its query and cookie shapes are lossless.** `rawQueryString` is exactly
#      `HttpRequest.query_string`'s contract (no leading `?`), and `cookies` is a
#      real array rather than a header we would have to re-split.
#
# =============================================================================
# §3 — THE AUTHORIZER CONTEXT IS AN INPUT THE CLIENT CAN ALSO SPELL
# =============================================================================
# `RequestDispatcher.dispatch(reactor, req)` has no third argument, so the one
# place an authorizer's `context` can reach a handler is `req.headers`. That is
# workable and it is also THE trap in this entire file:
#
#   **the client controls `headers` too.**
#
# A caller who writes `x-komira-authorizer-org-id: org-victim` into their own
# request has, absent a defence, just handed the handler an identity that no
# authorizer vouched for. The defence is one rule, applied UNCONDITIONALLY:
#
#   => EVERY client header whose name begins `x-komira-authorizer-` is DROPPED
#      before anything is injected — including when there is NO authorizer on
#      the route, which is the case a "strip only what we overwrite" version
#      misses.
#
# `tests/test_apigw_v2.mojo:test_a_forged_authorizer_header_never_reaches_the_
# dispatcher` is the falsifier, and it runs on a route with NO authorizer block
# precisely because that is the arm where the sloppy implementation still
# passes. Its twin one layer out —
# `tests/test_pump_flush_ordering.mojo:test_the_authorizer_identity_reaches_the_
# dispatcher_and_the_forgery_does_not` — asserts the same property at the
# DISPATCHER, through the whole pump, on a route that DOES have an authorizer.
#
# The consequence is that a handler can tell an identity that came from
# `requestContext.authorizer.lambda` from one the request claimed, because the
# second is destroyed on entry.
#
# =============================================================================
# §4 — `isBase64Encoded` IS A ROUND TRIP, AND ITS FAILURE IS SILENT
# =============================================================================
# Corruption here does not raise, log, or 500. A binary body decoded as text
# arrives at the handler as mojibake that is still a valid `List[UInt8]`, and a
# binary response emitted as text is delivered by API Gateway as bytes the client
# cannot use. Both directions are therefore implemented and BOTH are falsified
# with a body that is NOT valid UTF-8 (`_binary_probe()`), because a probe made of
# ASCII round-trips through a broken implementation unharmed.
#
#   INBOUND : `isBase64Encoded == true`  -> base64-decode into `req.body`.
#   OUTBOUND: the body is base64-encoded IFF it is not valid UTF-8, and
#             `isBase64Encoded` is set to say so. Valid UTF-8 goes out as text
#             so a log or a `curl` shows the JSON a human expects.
#
# ENCAPSULATION: every function here takes and returns owned values —
# `String`, `HttpRequest`, `HttpResponse`, `List[UInt8]`. No `UnsafePointer`
# crosses any boundary, no wildcard origin, nothing enters a byte-slab.
# =============================================================================

from komira_http_core.codec.types import HttpMethod, HttpRequest, HttpResponse
from komira_http_core.codec.types import (
    HTTP_METHOD_DELETE,
    HTTP_METHOD_GET,
    HTTP_METHOD_HEAD,
    HTTP_METHOD_OPTIONS,
    HTTP_METHOD_PATCH,
    HTTP_METHOD_POST,
    HTTP_METHOD_PUT,
    HTTP_METHOD_UNKNOWN,
)

from komira_json import JsonValue, parse_json_value
from komira_encoding import base64_decode, base64_encode


# The ONE payload format this converter speaks. Read `_require_v2` before
# changing it: the value is asserted, not defaulted.
comptime APIGW_PAYLOAD_VERSION: String = "2.0"

# ⛔ THE RESERVED HEADER NAMESPACE. Anything under it in a CLIENT request is
# destroyed on entry (§3). Keep it long and vendor-scoped: a short prefix like
# `x-auth-` would collide with headers real clients legitimately send, and the
# strip would then be silently eating caller data.
comptime AUTHORIZER_HEADER_PREFIX: String = "x-komira-authorizer-"

# Where a 2.0 event carries a Lambda REQUEST authorizer's `context` map.
# ⚠ NOT `requestContext.authorizer` itself — that object holds the authorizer
# KIND as its key (`lambda` for a REQUEST authorizer, `jwt` for a JWT one), and
# reading it flat would pick up `jwt` as if it were a context entry.
comptime _AUTHORIZER_LAMBDA_KEY: String = "lambda"


# =============================================================================
# §1 — inbound: the API Gateway v2.0 proxy event -> HttpRequest.
# =============================================================================
def api_gateway_v2_event_to_request(event_json: String) raises -> HttpRequest:
    """Convert one API Gateway payload-format-2.0 proxy event into the
    `HttpRequest` the shipped `RequestDispatcher` already takes.

    RAISES — never returns a degraded request — when the event is not 2.0, when
    `requestContext.http` is missing, or when a declared base64 body does not
    decode. Each of those is a case where a "best effort" request would reach the
    handler describing a DIFFERENT call than the client made.

    Field coverage (every one is asserted by a falsifier):
      `version`                       -> checked, then discarded
      `requestContext.http.method`    -> `req.method`
      `rawPath`                       -> `req.path`
      `rawQueryString`                -> `req.query_string` (no leading `?`)
      `headers`                       -> `req.headers`, keys ASCII-lowercased,
                                         reserved prefix DROPPED first (§3)
      `cookies` (array)               -> a single `cookie` header, `"; "`-joined
      `body` + `isBase64Encoded`      -> `req.body` (§4)
      `requestContext.authorizer.lambda` -> `x-komira-authorizer-*` headers (§3)
    """
    var event = parse_json_value(event_json)
    if not event.is_object():
        raise Error(
            String(
                "apigw: the invocation payload is not a JSON object — this"
                " runtime is bound to an API Gateway proxy integration and"
                " received something else (a direct invoke? an SQS event?)"
            )
        )
    _require_v2(event)

    var req = HttpRequest()

    # --- method: 2.0 puts it under requestContext.http, NOT at the top level.
    if not event.has(String("requestContext")):
        raise Error(
            String(
                "apigw: event declares version 2.0 but carries no"
                " `requestContext` — there is no method and no path to route"
                " on, and defaulting either would answer a request nobody made"
            )
        )
    var rc = event.get(String("requestContext"))
    if not rc.is_object() or not rc.has(String("http")):
        raise Error(
            String(
                "apigw: `requestContext.http` is absent. In payload format 2.0"
                " this is where the METHOD lives (1.0's top-level `httpMethod`"
                " is a different format — see this file's header table)"
            )
        )
    var http = rc.get(String("http"))
    req.method = _method_from_name(_opt_string(http, String("method")))

    # --- path + query. `rawQueryString` is already `?`-free, which is exactly
    # `HttpRequest.query_string`'s contract — no trimming, and none is done.
    req.path = _opt_string(event, String("rawPath"))
    req.query_string = _opt_string(event, String("rawQueryString"))

    # --- headers. ⛔ ORDER IS LOAD-BEARING: client headers are copied WITH the
    # reserved prefix filtered out, and only then is the authorizer's context
    # injected. Injecting first and copying second would let the client's copy
    # overwrite the authorizer's answer, which is the same hole upside down.
    if event.has(String("headers")):
        var hdrs = event.get(String("headers"))
        if hdrs.is_object():
            for i in range(hdrs.num_members()):
                var raw_name = hdrs.key_at(i)
                var name = _ascii_lower(raw_name)
                if _starts_with(name, String(AUTHORIZER_HEADER_PREFIX)):
                    # §3 — a client may not spell an authorizer's answer.
                    continue
                var v = hdrs.value_at(i)
                if v.kind_tag() == 3:  # JSON_STRING
                    req.headers[name^] = v.as_string()

    # --- cookies. A 2.0 event NEVER puts them in `headers`; it hands an array.
    # Folding them back into one `cookie` header is what makes the dispatcher's
    # ordinary header read work unchanged.
    if event.has(String("cookies")):
        var cookies = event.get(String("cookies"))
        if cookies.is_array() and cookies.array_len() > 0:
            var joined = String("")
            for i in range(cookies.array_len()):
                var c = cookies.element_at(i)
                if c.kind_tag() != 3:
                    continue
                if joined.byte_length() > 0:
                    joined += String("; ")
                joined += c.as_string()
            if joined.byte_length() > 0:
                req.headers[String("cookie")] = joined^

    # --- the authorizer's context (§3), injected LAST so it always wins.
    _inject_authorizer_context(rc, req.headers)

    # --- body (§4).
    req.body = _decode_body(event)
    return req^


def _require_v2(event: JsonValue) raises:
    """⛔ THE FORMAT ASSERTION. A missing or non-2.0 `version` is a refusal, and
    so is a payload carrying `type` — which is an AUTHORIZER event, not a proxy
    event.

    A 1.0 event reaches here with `httpMethod` at the top level and no
    `requestContext.http`; without this check it would be converted into a
    request with an UNKNOWN method and an EMPTY path, and answered 404 — a
    misconfigured integration reported as a routing miss.

    ⛔⛔ THE `type` HALF CLOSES
    A HOLE THIS FUNCTION'S OWN ARGUMENT DID NOT COVER. The v2 REQUEST-authorizer
    payload agrees with the proxy payload on EVERY field this converter reads —
    `version` is `"2.0"`, `requestContext.http.method` is present, `rawPath` and
    `headers` are present — so before this check an authorizer event was
    converted into a perfectly well-formed `HttpRequest` with an empty body and
    NOTHING RAISED. `type` is the only field that separates the two shapes, and
    the file header's own rule ("a converter that accepts both accepts a
    malformed one") therefore demands it be read here. Its twin is
    `apigw_authorizer._require_v2_authorizer`, which refuses the payload with NO
    `type` for the mirror-image reason."""
    if not event.has(String("version")):
        raise Error(
            String(
                "apigw: event carries no `version` field. This runtime speaks"
                " payload format "
            )
            + String(APIGW_PAYLOAD_VERSION)
            + String(
                " ONLY (API Gateway HTTP API default). A REST API, or an HTTP"
                " API configured for 1.0, must be re-pointed rather than"
                " coerced — the two shapes disagree about where the method,"
                " the path and the authorizer context live."
            )
        )
    if event.has(String("type")):
        # ⛔ AN AUTHORIZER EVENT, NOT A PROXY EVENT. See this function's
        # docstring: the two payloads are indistinguishable to every other check
        # here, so without this arm a REQUEST-authorizer invocation is silently
        # converted into a bodyless `HttpRequest` and dispatched.
        var kind = event.get(String("type"))
        var kind_s = String("")
        if kind.kind_tag() == 3:
            kind_s = kind.as_string()
        raise Error(
            String(
                "apigw: event carries `type`='"
            )
            + kind_s
            + String(
                "', which makes it a Lambda AUTHORIZER payload and not a PROXY"
                " payload. The two agree on `version`, `rawPath`, `headers` and"
                " `requestContext.http`, so this converter would have produced a"
                " well-formed request with an empty body and raised nothing."
                " Authorizer events belong to"
                " `apigw_authorizer.parse_api_gateway_authorizer_event`; if this"
                " fired on a real proxy request, an integration is pointed at"
                " the wrong function."
            )
        )
    var got = event.get(String("version"))
    var got_s = String("")
    if got.kind_tag() == 3:
        got_s = got.as_string()
    if got_s != String(APIGW_PAYLOAD_VERSION):
        raise Error(
            String("apigw: unsupported payload format version '")
            + got_s
            + String("' — this runtime speaks ")
            + String(APIGW_PAYLOAD_VERSION)
            + String(
                " only. Accepting both would mean guessing which shape a"
                " truncated event was, and a wrong guess routes the request to"
                " the wrong handler instead of reporting the truncation."
            )
        )


def _inject_authorizer_context(
    rc: JsonValue, mut headers: Dict[String, String]
) raises:
    """Copy `requestContext.authorizer.lambda`'s STRING members into `headers`
    under the reserved prefix (§3).

    ⚠ ONLY STRING MEMBERS. A Lambda authorizer's `context` is documented to carry
    strings; API Gateway stringifies numbers and booleans and REJECTS nested
    objects. Silently flattening a nested object here would invent a header value
    that the authorizer never wrote, so a non-string member is skipped rather
    than serialized.

    Absent authorizer -> nothing injected. The client's own attempt was already
    destroyed by the caller, unconditionally, which is the half that matters."""
    if not rc.has(String("authorizer")):
        return
    var authz = rc.get(String("authorizer"))
    if not authz.is_object() or not authz.has(String(_AUTHORIZER_LAMBDA_KEY)):
        return
    var ctx = authz.get(String(_AUTHORIZER_LAMBDA_KEY))
    if not ctx.is_object():
        return
    for i in range(ctx.num_members()):
        var v = ctx.value_at(i)
        if v.kind_tag() != 3:  # JSON_STRING
            continue
        var key = String(AUTHORIZER_HEADER_PREFIX) + _ascii_lower(ctx.key_at(i))
        headers[key^] = v.as_string()


def _decode_body(event: JsonValue) raises -> List[UInt8]:
    """`body` + `isBase64Encoded` -> the request's raw bytes (§4).

    ⛔ A DECODE FAILURE RAISES. The alternative — falling back to the literal
    base64 text — hands the handler a body that parses as neither the JSON it
    expects nor the bytes the client sent, and does it without a diagnostic."""
    if not event.has(String("body")):
        return List[UInt8]()
    var body = event.get(String("body"))
    if body.is_null():
        return List[UInt8]()
    if body.kind_tag() != 3:  # JSON_STRING
        raise Error(
            String(
                "apigw: `body` is present but is not a JSON string. API Gateway"
                " always delivers the body as a string (base64-wrapped when"
                " binary); a non-string here means the payload was assembled by"
                " something other than a proxy integration."
            )
        )
    var text = body.as_string()

    var is_b64 = False
    if event.has(String("isBase64Encoded")):
        var flag = event.get(String("isBase64Encoded"))
        if flag.kind_tag() == 1:  # JSON_BOOL
            is_b64 = flag.as_bool()

    if not is_b64:
        var out = List[UInt8]()
        var bs = text.as_bytes()
        for i in range(len(bs)):
            out.append(bs[i])
        return out^

    try:
        return base64_decode(text)
    except e:
        raise Error(
            String(
                "apigw: `isBase64Encoded` is true but `body` is not valid"
                " base64 — refusing rather than handing the handler the literal"
                " encoded text, which would parse as neither JSON nor the"
                " client's bytes. Underlying: "
            )
            + String(e)
        )


# =============================================================================
# §2 — outbound: HttpResponse -> the API Gateway v2.0 response payload.
# =============================================================================
def response_to_api_gateway_v2(var res: HttpResponse) raises -> String:
    """Serialize an `HttpResponse` into the JSON API Gateway expects back from a
    payload-format-2.0 proxy integration.

    Emits `{"statusCode", "headers", "cookies"?, "body", "isBase64Encoded"}`.

    ⛔ `set-cookie` BECOMES `cookies`, NOT A HEADER. In format 2.0 a `Set-Cookie`
    returned as an ordinary header is DROPPED by API Gateway; the `cookies` array
    is the only channel. Emitting it as a header produces a response that is a
    valid JSON payload, is accepted, and silently sets no cookie — so the login
    that "works locally" fails only behind the gateway.

    ⛔ `isBase64Encoded` IS DERIVED FROM THE BYTES, NEVER ASSUMED (§4). A body
    that is valid UTF-8 goes out as text (readable in a log); anything else is
    base64-encoded and declared as such. Hardcoding `false` corrupts every binary
    response and raises nothing."""
    var out = JsonValue.empty_object()
    out.set_member(
        String("statusCode"), JsonValue.from_number(String(Int(res.status)))
    )

    var hdrs = JsonValue.empty_object()
    var cookies = JsonValue.empty_array()
    var have_cookie = False
    for kv in res.headers.items():
        var name = _ascii_lower(String(kv.key))
        if name == String("set-cookie"):
            cookies.push(JsonValue.from_string(String(kv.value)))
            have_cookie = True
            continue
        hdrs.set_member(name^, JsonValue.from_string(String(kv.value)))
    out.set_member(String("headers"), hdrs^)
    if have_cookie:
        out.set_member(String("cookies"), cookies^)

    if _is_valid_utf8(res.body):
        out.set_member(
            String("body"),
            JsonValue.from_string(String(unsafe_from_utf8=Span(res.body))),
        )
        out.set_member(String("isBase64Encoded"), JsonValue.from_bool(False))
    else:
        out.set_member(
            String("body"), JsonValue.from_string(base64_encode(res.body))
        )
        out.set_member(String("isBase64Encoded"), JsonValue.from_bool(True))

    return out.serialize()


# =============================================================================
# §3 — small helpers. Deliberately local: each is one screen and has a falsifier.
# =============================================================================
def _method_from_name(name: String) -> HttpMethod:
    """`requestContext.http.method` -> `HttpMethod`.

    An unrecognised verb becomes `HTTP_METHOD_UNKNOWN` rather than raising, on
    purpose: an odd verb is a REQUEST-level condition the dispatcher already
    answers (405), whereas raising would report it on the Lambda ERROR channel
    as a runtime fault and page somebody."""
    var m = _ascii_upper(name)
    if m == String("GET"):
        return HttpMethod(code=HTTP_METHOD_GET)
    if m == String("POST"):
        return HttpMethod(code=HTTP_METHOD_POST)
    if m == String("PUT"):
        return HttpMethod(code=HTTP_METHOD_PUT)
    if m == String("DELETE"):
        return HttpMethod(code=HTTP_METHOD_DELETE)
    if m == String("PATCH"):
        return HttpMethod(code=HTTP_METHOD_PATCH)
    if m == String("HEAD"):
        return HttpMethod(code=HTTP_METHOD_HEAD)
    if m == String("OPTIONS"):
        return HttpMethod(code=HTTP_METHOD_OPTIONS)
    return HttpMethod(code=HTTP_METHOD_UNKNOWN)


def _opt_string(obj: JsonValue, key: String) raises -> String:
    """`obj[key]` when it is a string, else `""`. Absent and empty are the same
    answer here because every caller's fallback for both is the empty value."""
    if not obj.has(key):
        return String("")
    var v = obj.get(key)
    if v.kind_tag() != 3:  # JSON_STRING
        return String("")
    return v.as_string()


def _starts_with(s: String, prefix: String) -> Bool:
    var sb = s.as_bytes()
    var pb = prefix.as_bytes()
    if len(pb) > len(sb):
        return False
    for i in range(len(pb)):
        if sb[i] != pb[i]:
            return False
    return True


def _ascii_lower(s: String) -> String:
    """ASCII-only case fold. ⚠ ASCII-ONLY IS CORRECT, not a shortcut: HTTP field
    names are ASCII by RFC 9110, and a Unicode fold would map non-ASCII bytes in
    a hostile header name onto ASCII ones and could forge a reserved prefix."""
    var out = String("")
    var bs = s.as_bytes()
    for i in range(len(bs)):
        var b = bs[i]
        if b >= UInt8(0x41) and b <= UInt8(0x5A):
            out += chr(Int(b) + 32)
        else:
            out += chr(Int(b))
    return out^


def _ascii_upper(s: String) -> String:
    var out = String("")
    var bs = s.as_bytes()
    for i in range(len(bs)):
        var b = bs[i]
        if b >= UInt8(0x61) and b <= UInt8(0x7A):
            out += chr(Int(b) - 32)
        else:
            out += chr(Int(b))
    return out^


def _is_valid_utf8(data: List[UInt8]) -> Bool:
    """Strict UTF-8 validation — the discriminator for `isBase64Encoded` (§4).

    STRICT, because the permissive readings are exactly what would make the
    branch wrong: overlong encodings, surrogate halves (U+D800..U+DFFF) and
    code points above U+10FFFF are all REJECTED, so a body carrying any of them
    takes the base64 path and survives instead of being emitted as text that
    API Gateway or the client will re-interpret."""
    var i = 0
    var n = len(data)
    while i < n:
        var b0 = Int(data[i])
        if b0 < 0x80:
            i += 1
            continue
        var need: Int
        var cp: Int
        if b0 >= 0xC2 and b0 <= 0xDF:
            need = 1
            cp = b0 & 0x1F
        elif b0 >= 0xE0 and b0 <= 0xEF:
            need = 2
            cp = b0 & 0x0F
        elif b0 >= 0xF0 and b0 <= 0xF4:
            need = 3
            cp = b0 & 0x07
        else:
            # 0x80..0xC1 (continuation byte in lead position, or an overlong
            # two-byte lead) and 0xF5..0xFF (beyond U+10FFFF) are never legal.
            return False
        if i + need >= n:
            return False
        for k in range(1, need + 1):
            var bk = Int(data[i + k])
            if bk < 0x80 or bk > 0xBF:
                return False
            cp = (cp << 6) | (bk & 0x3F)
        if need == 2 and cp < 0x800:
            return False
        if need == 3 and cp < 0x10000:
            return False
        if cp >= 0xD800 and cp <= 0xDFFF:
            return False
        if cp > 0x10FFFF:
            return False
        i += need + 1
    return True
