# =============================================================================
# tests/test_apigw_v2.mojo — the API-Gateway-2.0 <-> HTTP conversion, FIELD BY
#   FIELD, in both directions, plus every refusal.
# =============================================================================
# ⛔ WHY EVERY ASSERTION NAMES A FIELD VALUE AND NOT "a request was produced".
# The failure mode this converter has is SILENT LOSS, not a crash: a converter
# that dropped `rawQueryString`, or comma-split a multi-value header, or emitted
# a `Set-Cookie` as an ordinary header, still returns a perfectly well-formed
# `HttpRequest` / payload. So a test that asserts "conversion succeeded" passes
# against a converter that threw the request away.
#
# ⇒ THE NON-EMPTY ARM, stated as its own case: `test_a_dropping_converter_is_
#   not_accepted` pins method != UNKNOWN, path != "", query != "", the header
#   count, and the body length — the five things a "return an empty request /
#   500 and move on" implementation would satisfy vacuously if they were not
#   asserted individually.
#
# ⚠ THE BINARY PROBE IS NOT ASCII, ON PURPOSE (`_BINARY_PROBE`). A base64
# round-trip test whose payload is printable text passes through a BROKEN
# implementation unharmed — the "decode" that forgot to decode returns the same
# characters. `_BINARY_PROBE` contains 0x00, 0xFF and a lone 0x80 continuation
# byte, so it is invalid UTF-8 and cannot survive a text path.
#
# Every negative fixture below differs from `_base_event_json()` in EXACTLY ONE
# field, so a refusal cannot be attributed to two changes at once.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http_core.codec import ParseLimits, parse_request_head

from komira_http_core.codec.types import (
    HTTP_METHOD_GET,
    HTTP_METHOD_POST,
    HTTP_METHOD_UNKNOWN,
    HttpResponse,
)

from komira_json import parse_json_value
from komira_encoding import base64_decode, base64_encode

from komira_aws_lambda_http.apigw_v2 import (
    APIGW_PAYLOAD_VERSION,
    AuthorizerHeaderPrefix,
    api_gateway_v2_event_to_request,
    response_to_api_gateway_v2,
)


# =============================================================================
# Fixtures.
# =============================================================================

# The caller-chosen authorizer header namespace every fixture in this file uses.
# Deliberately an application name, not the library's: the converter must carry
# no namespace of its own (see
# `test_the_prefix_is_the_callers_and_only_the_callers`).
comptime _PREFIX: String = "x-example-authz-"


def _prefix() raises -> AuthorizerHeaderPrefix:
    return AuthorizerHeaderPrefix(String(_PREFIX))


def _binary_probe() -> List[UInt8]:
    """Bytes that are NOT valid UTF-8 — the only kind that falsifies a base64
    round trip.

    0xC3 0x28 is an invalid two-byte sequence; 0x80 alone is a continuation byte
    in lead position; 0x00 and 0xFF bracket the range. A converter that treats
    the body as text mangles at least three of these."""
    var out = List[UInt8]()
    out.append(UInt8(0x00))
    out.append(UInt8(0xC3))
    out.append(UInt8(0x28))
    out.append(UInt8(0x80))
    out.append(UInt8(0xFF))
    out.append(UInt8(0x41))
    return out^


def _base_event_json() -> String:
    """A realistic payload-format-2.0 proxy event. Every negative fixture in
    this file is this string with ONE field changed.

    Note the shapes that are 2.0-SPECIFIC and would be different (or absent) in
    a 1.0 event — they are what `_require_v2` protects:
      * the method under `requestContext.http.method`, NOT `httpMethod`
      * `rawPath` / `rawQueryString`, NOT `path` / `queryStringParameters`
      * `cookies` as a JSON ARRAY, not folded into `headers`
      * the authorizer's context under `requestContext.authorizer.lambda`
    """
    return String(
        '{'
        '"version": "2.0",'
        '"rawPath": "/api/v1/items",'
        '"rawQueryString": "tag=a&tag=b&dry_run=1",'
        '"cookies": ["session=abc", "theme=dark"],'
        '"headers": {'
        '"Content-Type": "application/json",'
        '"Accept": "text/html, application/json",'
        '"X-Request-Id": "req-77"'
        '},'
        '"requestContext": {'
        '"http": {"method": "POST", "path": "/api/v1/items"},'
        '"authorizer": {"lambda": {'
        '"subjectId": "subject-real",'
        '"Plan": "enterprise",'
        '"seatCount": 12'
        '}}'
        '},'
        '"body": "{\\"to\\": \\"a@example.com\\"}",'
        '"isBase64Encoded": false'
        '}'
    )


def _header(req_headers: Dict[String, String], name: String) raises -> String:
    if name not in req_headers:
        raise Error(String("expected header absent: ") + name)
    return req_headers[name]


def _bytes_to_ascii(data: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(data)):
        out += chr(Int(data[i]))
    return out^


def _bytes_equal(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


# =============================================================================
# §1 — INBOUND, field by field.
# =============================================================================

def test_method_comes_from_request_context_http_not_the_top_level() raises:
    """`requestContext.http.method` -> `req.method`.

    FALSIFIES: a converter reading 1.0's top-level `httpMethod`. The base event
    has NO `httpMethod` key at all, so such a converter yields
    `HTTP_METHOD_UNKNOWN` and the dispatcher answers 405 to a POST."""
    var req = api_gateway_v2_event_to_request(_base_event_json(), _prefix())
    assert_equal(req.method.code, HTTP_METHOD_POST)
    assert_false(req.method.code == HTTP_METHOD_UNKNOWN)
    assert_false(req.method.code == HTTP_METHOD_GET)


def test_raw_path_becomes_the_request_path() raises:
    """`rawPath` -> `req.path`, verbatim."""
    var req = api_gateway_v2_event_to_request(_base_event_json(), _prefix())
    assert_equal(req.path, String("/api/v1/items"))


def test_a_repeated_query_key_survives_whole() raises:
    """`rawQueryString` -> `req.query_string`, VERBATIM, `?`-free.

    ⛔ THE REPEAT IS THE POINT. `tag` appears TWICE. A converter that routed the
    query through 1.0's `queryStringParameters` — a JSON OBJECT — cannot
    represent that: one key wins and the other is gone, with no error. Asserting
    the whole string is what makes both `tag` values observable.

    Also asserts NO leading `?` — `HttpRequest.query_string`'s documented
    contract, and already `rawQueryString`'s, so any trimming here would be a
    net change."""
    var req = api_gateway_v2_event_to_request(_base_event_json(), _prefix())
    assert_equal(req.query_string, String("tag=a&tag=b&dry_run=1"))
    assert_false(req.query_string.startswith(String("?")))


def test_a_multi_value_header_arrives_comma_joined_and_unsplit() raises:
    """A 2.0 event comma-joins repeated header values into ONE string; the
    converter must hand that string over untouched.

    FALSIFIES: a converter that split on ',' to "normalise" — `Accept` would
    arrive as `text/html` alone and content negotiation would silently change.
    Asserting the joined value, not merely that the key exists, is what detects
    that."""
    var req = api_gateway_v2_event_to_request(_base_event_json(), _prefix())
    assert_equal(
        _header(req.headers, String("accept")),
        String("text/html, application/json"),
    )


def test_header_names_are_ascii_lowercased() raises:
    """`HttpRequest.headers` is documented case-INSENSITIVE with lowercase
    canonical keys, so `X-Request-Id` must be reachable as `x-request-id` and
    the original spelling must NOT also be present (two entries for one header
    is how a lookup silently misses)."""
    var req = api_gateway_v2_event_to_request(_base_event_json(), _prefix())
    assert_equal(_header(req.headers, String("x-request-id")), String("req-77"))
    assert_true(String("content-type") in req.headers)
    assert_false(String("X-Request-Id") in req.headers)
    assert_false(String("Content-Type") in req.headers)


def test_the_cookies_array_folds_into_one_cookie_header() raises:
    """2.0 delivers cookies as a JSON ARRAY and NEVER inside `headers`. Folding
    them into a single `cookie` header, `"; "`-joined, is what lets the
    dispatcher's ordinary header read work with no Lambda-specific branch.

    FALSIFIES: dropping `cookies` (the session vanishes and the user is silently
    logged out behind the gateway only), and joining with the wrong separator."""
    var req = api_gateway_v2_event_to_request(_base_event_json(), _prefix())
    assert_equal(
        _header(req.headers, String("cookie")),
        String("session=abc; theme=dark"),
    )


def test_a_text_body_arrives_as_its_own_bytes() raises:
    """`isBase64Encoded: false` -> the body string's bytes, unchanged."""
    var req = api_gateway_v2_event_to_request(_base_event_json(), _prefix())
    assert_equal(_bytes_to_ascii(req.body), String('{"to": "a@example.com"}'))


def test_a_base64_binary_body_is_decoded_inbound() raises:
    """§4 INBOUND: `isBase64Encoded: true` -> base64-decode into `req.body`.

    The probe is NOT valid UTF-8 (see `_binary_probe`), so a converter that
    skipped the decode — or that round-tripped the body through a `String` —
    cannot produce these bytes.

    ONE FIELD differs from the base event: `body` is the base64 text and
    `isBase64Encoded` is true. (Two keys, but they are one fact; a base64 body
    with the flag false is a DIFFERENT case, covered below.)"""
    var probe = _binary_probe()
    var event = (
        String('{"version": "2.0", "rawPath": "/bin", "rawQueryString": "",')
        + String('"requestContext": {"http": {"method": "POST"}},')
        + String('"body": "')
        + base64_encode(probe)
        + String('", "isBase64Encoded": true}')
    )
    var req = api_gateway_v2_event_to_request(event, _prefix())
    assert_true(_bytes_equal(req.body, probe))
    assert_equal(len(req.body), 6)


def test_base64_text_with_the_flag_false_is_NOT_decoded() raises:
    """The complement of the case above, and the reason the flag is read rather
    than sniffed: identical `body`, `isBase64Encoded` FALSE (the ONE differing
    field), and the bytes must be the literal base64 CHARACTERS.

    FALSIFIES: a converter that decoded whenever the body "looks like" base64 —
    which silently corrupts every plain-text body that happens to be
    alphabet-only and length-4-aligned."""
    var probe = _binary_probe()
    var encoded = base64_encode(probe)
    var event = (
        String('{"version": "2.0", "rawPath": "/bin", "rawQueryString": "",')
        + String('"requestContext": {"http": {"method": "POST"}},')
        + String('"body": "')
        + encoded
        + String('", "isBase64Encoded": false}')
    )
    var req = api_gateway_v2_event_to_request(event, _prefix())
    assert_equal(_bytes_to_ascii(req.body), encoded)
    assert_false(_bytes_equal(req.body, probe))


def test_an_absent_body_is_empty_not_a_refusal() raises:
    """No `body` key -> an empty body. A GET has no body and must not be a
    deployment fault."""
    var event = String(
        '{"version": "2.0", "rawPath": "/health", "rawQueryString": "",'
        '"requestContext": {"http": {"method": "GET"}}}'
    )
    var req = api_gateway_v2_event_to_request(event, _prefix())
    assert_equal(len(req.body), 0)
    assert_equal(req.method.code, HTTP_METHOD_GET)


# =============================================================================
# §2 — THE AUTHORIZER CONTEXT, and the forgery defence (§3 of apigw_v2.mojo).
# =============================================================================

def test_the_authorizer_context_reaches_the_request_as_reserved_headers() raises:
    """`requestContext.authorizer.lambda`'s STRING members become
    `<prefix><key>` headers (here `x-example-authz-<key>`), key
    ASCII-lowercased.

    `dispatch(reactor, req)` has no third argument, so `req.headers` is the only
    channel an authorizer's answer has. This is the assertion that the channel
    carries."""
    var req = api_gateway_v2_event_to_request(_base_event_json(), _prefix())
    assert_equal(
        _header(req.headers, String(_PREFIX) + String("subjectid")),
        String("subject-real"),
    )
    assert_equal(
        _header(req.headers, String(_PREFIX) + String("plan")),
        String("enterprise"),
    )


def test_a_non_string_authorizer_member_is_skipped_not_stringified() raises:
    """`seatCount` is a JSON NUMBER in the base event and must NOT appear.

    API Gateway stringifies numbers before we ever see them, so a NUMBER here
    means something other than a Lambda authorizer assembled the object.
    Inventing `"12"` for it would hand the handler a value no authorizer
    wrote."""
    var req = api_gateway_v2_event_to_request(_base_event_json(), _prefix())
    assert_false(
        (String(_PREFIX) + String("seatcount")) in req.headers
    )


def test_a_forged_authorizer_header_never_reaches_the_dispatcher() raises:
    """⛔ THE SECURITY ASSERTION. A client header under the reserved prefix is
    DESTROYED on entry — including on a route with NO authorizer at all.

    THE NO-AUTHORIZER ARM IS THE POINT, and it is the ONE field that differs
    from the fixture below it: an implementation that strips only what it is
    about to overwrite passes the with-authorizer case and FAILS here, leaving
    `subject-victim` in the handler's hands on every unauthenticated route.

    FAILS ON A "strip only what we overwrite" CONVERTER: `req.headers` would
    contain `x-example-authz-subjectid: subject-victim`."""
    var event = String(
        '{"version": "2.0", "rawPath": "/public", "rawQueryString": "",'
        '"headers": {"x-example-authz-subjectid": "subject-victim",'
        '"X-Example-Authz-Plan": "enterprise",'
        '"x-request-id": "req-9"},'
        '"requestContext": {"http": {"method": "GET"}}}'
    )
    var req = api_gateway_v2_event_to_request(event, _prefix())
    assert_false(
        (String(_PREFIX) + String("subjectid")) in req.headers
    )
    assert_false(
        (String(_PREFIX) + String("plan")) in req.headers
    )
    # ⚠ NON-EMPTY ARM: the strip must be SURGICAL. A converter that dropped all
    # headers would satisfy the two assertions above vacuously.
    assert_equal(_header(req.headers, String("x-request-id")), String("req-9"))


def test_the_authorizer_wins_over_a_client_header_of_the_same_name() raises:
    """Same forged header, but WITH an authorizer present (the one differing
    field vs the fixture above). The handler must see the AUTHORIZER's value.

    FALSIFIES the injection-then-copy ordering: injecting first and copying
    client headers second lets the client's `subject-victim` overwrite
    `subject-real` — the same hole upside down, and it passes the no-authorizer
    test."""
    var event = String(
        '{"version": "2.0", "rawPath": "/private", "rawQueryString": "",'
        '"headers": {"x-example-authz-subjectid": "subject-victim"},'
        '"requestContext": {"http": {"method": "GET"},'
        '"authorizer": {"lambda": {"subjectId": "subject-real"}}}}'
    )
    var req = api_gateway_v2_event_to_request(event, _prefix())
    assert_equal(
        _header(req.headers, String(_PREFIX) + String("subjectid")),
        String("subject-real"),
    )


def test_a_context_key_that_is_not_a_header_token_is_skipped() raises:
    """A context member whose KEY is not an RFC 9110 token (a space, a colon,
    CR LF) or is empty is skipped, like a non-string value. The prefix is
    validated, so the key is the only half of the injected name left to check.

    FALSIFIES a converter that appends the key unchecked: it would inject
    `x-example-authz-a b`, `x-example-authz-a:b` and a name carrying CR LF,
    none of which a header can carry. The `subjectId` member is the non-empty
    arm: a converter that skipped every key would fail on it."""
    var event = String(
        '{"version": "2.0", "rawPath": "/private", "rawQueryString": "",'
        '"requestContext": {"http": {"method": "GET"},'
        '"authorizer": {"lambda": {'
        '"subjectId": "subject-real",'
        '"a b": "space",'
        '"a:b": "colon",'
        '"a\\r\\nb": "crlf",'
        '"": "empty"'
        '}}}}'
    )
    var req = api_gateway_v2_event_to_request(event, _prefix())
    assert_equal(
        _header(req.headers, String(_PREFIX) + String("subjectid")),
        String("subject-real"),
    )
    assert_false((String(_PREFIX) + String("a b")) in req.headers)
    assert_false((String(_PREFIX) + String("a:b")) in req.headers)
    assert_false((String(_PREFIX) + String("a\r\nb")) in req.headers)
    assert_false(String(_PREFIX) in req.headers)
    assert_equal(len(req.headers), 1)


def test_a_jwt_authorizer_kind_is_not_read_as_a_context_entry() raises:
    """`requestContext.authorizer` keys are authorizer KINDS (`lambda`, `jwt`),
    not context entries. Reading the object flat would turn the `jwt` key into a
    header. Only the `lambda` arm is read; a `jwt`-only event injects nothing."""
    var event = String(
        '{"version": "2.0", "rawPath": "/private", "rawQueryString": "",'
        '"requestContext": {"http": {"method": "GET"},'
        '"authorizer": {"jwt": {"claims": {"sub": "u1"}}}}}'
    )
    var req = api_gateway_v2_event_to_request(event, _prefix())
    assert_false((String(_PREFIX) + String("jwt")) in req.headers)
    assert_equal(len(req.headers), 0)


def test_the_prefix_is_the_callers_and_only_the_callers() raises:
    """The SAME event converted under two prefixes. Under `x-other-authz-` the
    context arrives under `x-other-authz-`, a client header under
    `x-example-authz-` is an ordinary header and passes through, and a client
    header under `x-other-authz-` is the forgery and is dropped.

    FALSIFIES a converter that keeps a namespace of its own: one that still
    strips or injects under a fixed prefix fails the pass-through arm or the
    injection arm, whichever prefix it hard-codes."""
    var event = String(
        '{"version": "2.0", "rawPath": "/private", "rawQueryString": "",'
        '"headers": {"x-example-authz-subjectid": "subject-ordinary",'
        '"x-other-authz-plan": "enterprise"},'
        '"requestContext": {"http": {"method": "GET"},'
        '"authorizer": {"lambda": {"subjectId": "subject-real"}}}}'
    )
    var other = AuthorizerHeaderPrefix(String("x-other-authz-"))
    var req = api_gateway_v2_event_to_request(event, other)
    assert_equal(
        _header(req.headers, String("x-other-authz-subjectid")),
        String("subject-real"),
    )
    assert_false(String("x-other-authz-plan") in req.headers)
    assert_equal(
        _header(req.headers, String("x-example-authz-subjectid")),
        String("subject-ordinary"),
    )
    assert_equal(len(req.headers), 2)

    # And under the file's own prefix the roles swap.
    var req2 = api_gateway_v2_event_to_request(event, _prefix())
    assert_equal(
        _header(req2.headers, String(_PREFIX) + String("subjectid")),
        String("subject-real"),
    )
    assert_equal(
        _header(req2.headers, String("x-other-authz-plan")),
        String("enterprise"),
    )
    assert_equal(len(req2.headers), 2)


def test_a_valid_prefix_is_kept_exactly_as_given() raises:
    """FALSIFIES a constructor that normalizes what it accepts (folding,
    trimming, or appending a separator): the value comes back byte for
    byte."""
    assert_equal(_prefix().value(), String(_PREFIX))
    assert_equal(
        AuthorizerHeaderPrefix(String("authz-")).value(), String("authz-")
    )
    assert_equal(
        AuthorizerHeaderPrefix(String("x-app_1.authz-")).value(),
        String("x-app_1.authz-"),
    )


def _prefix_must_be_refused(
    prefix: String, mention: String, because: String
) raises:
    """The constructor must RAISE, and the message must name the rule
    (`mention`), so a refusal for the wrong reason does not count."""
    var raised = False
    try:
        var p = AuthorizerHeaderPrefix(prefix)
        _ = p.value()
    except e:
        raised = True
        if String(e).find(mention) < 0:
            raise Error(
                String("prefix refused for the wrong reason (")
                + because
                + String("): ")
                + String(e)
            )
    if not raised:
        raise Error(String("expected the prefix to be REFUSED: ") + because)


def test_refuses_an_empty_prefix() raises:
    """FALSIFIES a constructor that accepts `""`, which reserves every header
    name and makes the strip drop the whole client request's headers."""
    _prefix_must_be_refused(String(""), String("EMPTY"), String("empty"))


def test_refuses_a_prefix_containing_cr_or_lf() raises:
    """A line break in a field name is a header-injection vector; each of CR,
    LF and CRLF is refused BY NAME, not merely as a non-token byte."""
    _prefix_must_be_refused(
        String("x-app-\rauthz-"), String("CR or LF"), String("CR")
    )
    _prefix_must_be_refused(
        String("x-app-\nauthz-"), String("CR or LF"), String("LF")
    )
    _prefix_must_be_refused(
        String("x-app-authz-\r\n"), String("CR or LF"), String("trailing CRLF")
    )


def test_refuses_an_upper_case_prefix() raises:
    """Client header names are lower-cased before the compare, so an upper-case
    prefix would strip nothing. Refused rather than silently folded."""
    _prefix_must_be_refused(
        String("X-App-Authz-"), String("UPPER-CASE"), String("upper case")
    )


def test_refuses_a_prefix_that_is_not_a_header_token() raises:
    """FALSIFIES a constructor that accepts `x app-`, `x-app:`, `x/app-` or a
    non-ASCII byte: no header name could ever carry such a prefix."""
    _prefix_must_be_refused(
        String("x app-"), String("token character"), String("space")
    )
    _prefix_must_be_refused(
        String("x-app:"), String("token character"), String("colon")
    )
    _prefix_must_be_refused(
        String("x/app-"), String("token character"), String("slash")
    )
    _prefix_must_be_refused(
        String("x-") + chr(0xE9) + String("-"),
        String("token character"),
        String("non-ASCII"),
    )


def test_refuses_a_prefix_not_ending_in_a_dash() raises:
    """FALSIFIES a constructor that accepts `x-app-authz` and yields the header
    `x-app-authzsubjectid`."""
    _prefix_must_be_refused(
        String("x-app-authz"), String("END with '-'"), String("no dash")
    )
    _prefix_must_be_refused(
        String("x-app-authz_"), String("END with '-'"), String("underscore")
    )


def test_refuses_a_prefix_naming_nothing() raises:
    """FALSIFIES a constructor that accepts `-` or `--`, which reserve every
    header starting with a dash and name no namespace."""
    _prefix_must_be_refused(
        String("-"), String("no letter or digit"), String("a lone dash")
    )
    _prefix_must_be_refused(
        String("--"), String("no letter or digit"), String("dashes only")
    )


def test_refuses_a_prefix_of_a_header_the_gateway_adds() raises:
    """API Gateway v2 adds `x-forwarded-for`, `x-forwarded-proto`,
    `x-forwarded-port` and `x-amzn-trace-id` to every request. A prefix that
    starts any of them would strip it on every request.

    FALSIFIES a constructor that accepts `x-`, `x-forwarded-`, `x-amzn-` or
    `x-amzn-trace-`; the message must name the header that would be lost."""
    _prefix_must_be_refused(
        String("x-"), String("'x-forwarded-for'"), String("x-")
    )
    _prefix_must_be_refused(
        String("x-forwarded-"),
        String("'x-forwarded-for'"),
        String("x-forwarded-"),
    )
    _prefix_must_be_refused(
        String("x-amzn-"), String("'x-amzn-trace-id'"), String("x-amzn-")
    )
    _prefix_must_be_refused(
        String("x-amzn-trace-"),
        String("'x-amzn-trace-id'"),
        String("x-amzn-trace-"),
    )


def test_a_short_prefix_shared_with_client_headers_is_accepted() raises:
    """The stated LIMIT of the type: a prefix that only collides with headers
    CLIENTS send (`content-`, `x-auth-`, `x-amz-`) is accepted, because whether
    those headers matter is the application's judgement, not the library's.

    Pinned so the limit is a checked fact, not only a docstring: if the type
    starts refusing these, this test says the contract changed. `x-amz-` is
    here because it is NOT a prefix of `x-amzn-trace-id`."""
    assert_equal(
        AuthorizerHeaderPrefix(String("content-")).value(), String("content-")
    )
    assert_equal(
        AuthorizerHeaderPrefix(String("x-auth-")).value(), String("x-auth-")
    )
    assert_equal(
        AuthorizerHeaderPrefix(String("x-amz-")).value(), String("x-amz-")
    )


# =============================================================================
# §3 — REFUSALS. Each fixture differs from `_base_event_json()` in ONE field.
# =============================================================================

def _must_raise(event: String, because: String) raises:
    var raised = False
    try:
        var req = api_gateway_v2_event_to_request(event, _prefix())
        _ = req.path
    except e:
        raised = True
        _ = e
    if not raised:
        raise Error(
            String("expected a REFUSAL and got a request instead: ") + because
        )


def test_refuses_a_1_0_event() raises:
    """⛔ A 1.0 event is REFUSED, not coerced. The ONE differing field is
    `version`: `"1.0"` instead of `"2.0"`.

    Without the assertion this event converts into a request with an UNKNOWN
    method and an EMPTY path — a misconfigured integration reported to the
    caller as a 404, forever."""
    _must_raise(
        String(
            '{"version": "1.0", "rawPath": "/api/v1/items",'
            '"rawQueryString": "", "requestContext":'
            '{"http": {"method": "POST"}}}'
        ),
        String("payload format 1.0"),
    )


def test_refuses_a_REQUEST_AUTHORIZER_event() raises:
    """⛔⛔ THE HOLE THIS FILE'S OWN ARGUMENT DID NOT COVER.

    The v2 REQUEST-authorizer payload agrees with the PROXY payload on EVERY
    field this converter reads: `version` is `"2.0"`, `requestContext.http` is
    present, `rawPath` and `headers` are present. There is no `body`, and an
    absent body is legitimately not a refusal
    (`test_an_absent_body_is_empty_not_a_refusal`). So before the `type` check
    this event converted into a perfectly well-formed `HttpRequest` and NOTHING
    RAISED — the exact failure this file's header names ("a converter that
    accepts both accepts a malformed one"), reached by a shape the header's own
    1.0-vs-2.0 table does not mention.

    The ONE field that differs from a real proxy event is `type`."""
    _must_raise(
        String(
            '{"version": "2.0", "type": "REQUEST",'
            '"routeArn": "arn:aws:execute-api:us-east-1:1:a/$default/POST/v1",'
            '"identitySource": ["Bearer t"],'
            '"routeKey": "POST /v1/messages",'
            '"rawPath": "/v1/messages", "rawQueryString": "",'
            '"headers": {"authorization": "Bearer t"},'
            '"requestContext": {"requestId": "r-1",'
            '"http": {"method": "POST"}}}'
        ),
        String("a REQUEST authorizer payload, not a proxy payload"),
    )


def test_refuses_an_event_with_no_version() raises:
    """ONE differing field: `version` absent entirely."""
    _must_raise(
        String(
            '{"rawPath": "/api/v1/items", "rawQueryString": "",'
            '"requestContext": {"http": {"method": "POST"}}}'
        ),
        String("no version field"),
    )


def test_refuses_a_2_0_event_with_no_request_context_http() raises:
    """ONE differing field: `requestContext` present but carrying no `http`.

    This is the shape a "try 2.0, fall back to 1.0" reader mis-reports: it sees
    `headers` + `requestContext` on both formats, concludes 1.0, and answers 405
    to a POST rather than naming the truncation."""
    _must_raise(
        String(
            '{"version": "2.0", "rawPath": "/api/v1/items",'
            '"rawQueryString": "", "requestContext": {"accountId": "1"}}'
        ),
        String("requestContext without http"),
    )


def test_refuses_a_base64_body_that_does_not_decode() raises:
    """ONE differing field: `body` is not valid base64 while `isBase64Encoded`
    stays true.

    Falling back to the literal encoded text hands the handler a body that
    parses as neither JSON nor the client's bytes, with no diagnostic."""
    _must_raise(
        String(
            '{"version": "2.0", "rawPath": "/bin", "rawQueryString": "",'
            '"requestContext": {"http": {"method": "POST"}},'
            '"body": "!!!not base64!!!", "isBase64Encoded": true}'
        ),
        String("undecodable base64 body"),
    )


def test_refuses_a_payload_that_is_not_a_json_object() raises:
    """A direct invoke or an SQS event is not a proxy event."""
    _must_raise(String('["not", "a", "proxy", "event"]'), String("JSON array"))


def _event_with_body(body_json: String, is_b64: Bool) -> String:
    """A minimal 2.0 event whose `body` member is `body_json`, written as JSON
    source text (escapes and all), with `isBase64Encoded` set to `is_b64`."""
    return (
        String('{"version": "2.0", "rawPath": "/bin", "rawQueryString": "",')
        + String('"requestContext": {"http": {"method": "POST"}},')
        + String('"body": "')
        + body_json
        + String('", "isBase64Encoded": ')
        + (String("true") if is_b64 else String("false"))
        + String("}")
    )


def test_an_escaped_surrogate_pair_body_arrives_as_one_4_byte_character() raises:
    """A text body carrying `\\ud83d\\ude00` (U+1F600, escaped as a UTF-16
    surrogate pair, which is how a JSON encoder writes a non-BMP character)
    arrives as its one 4-byte UTF-8 sequence, F0 9F 98 80.

    FALSIFIES: a JSON reader that decodes each `\\u` escape on its own, which
    turns the pair into two 3-byte sequences (ED A0 BD ED B8 80) — ill-formed
    UTF-8 handed to the handler as the client's text."""
    var req = api_gateway_v2_event_to_request(
        _event_with_body(String("\\ud83d\\ude00"), False), _prefix()
    )
    var want = List[UInt8]()
    want.append(UInt8(0xF0))
    want.append(UInt8(0x9F))
    want.append(UInt8(0x98))
    want.append(UInt8(0x80))
    assert_true(_bytes_equal(req.body, want))


def test_refuses_a_body_carrying_a_lone_surrogate_escape() raises:
    """A lone `\\ud800` has no UTF-8 encoding, so a text body carrying one has
    no bytes to become. It is refused (the event goes to the invocation ERROR
    channel) rather than handed on as ill-formed UTF-8."""
    _must_raise(
        _event_with_body(String("\\ud800"), False),
        String("a lone surrogate escape in a text body"),
    )


def test_refuses_a_non_canonical_base64_body() raises:
    """`QR==` has non-zero unused trailing bits; the canonical spelling of the
    same byte is `QQ==`. The decoder is strict, so the non-canonical form is
    the "undecodable base64 body" refusal. The canonical form is decoded
    first, so the refusal is about the trailing bits and not the byte."""
    var req = api_gateway_v2_event_to_request(
        _event_with_body(String("QQ=="), True), _prefix()
    )
    assert_equal(_bytes_to_ascii(req.body), String("A"))
    _must_raise(
        _event_with_body(String("QR=="), True),
        String("non-canonical base64 (non-zero unused bits)"),
    )


def test_the_pinned_version_is_2_0() raises:
    """The constant the refusals are written against. If this changes, every
    fixture above is describing a different contract."""
    assert_equal(String(APIGW_PAYLOAD_VERSION), String("2.0"))


# =============================================================================
# §4 — OUTBOUND: HttpResponse -> the 2.0 response payload.
# =============================================================================

def _response_with_text_body(status: Int32, body: String) raises -> HttpResponse:
    var r = HttpResponse(status=status)
    r.headers[String("content-type")] = String("application/json")
    var bs = body.as_bytes()
    for i in range(len(bs)):
        r.body.append(bs[i])
    return r^


def test_a_text_response_goes_out_as_text_with_the_flag_false() raises:
    """§4 OUTBOUND: valid UTF-8 -> `body` as text, `isBase64Encoded: false`, so
    a log or a `curl` shows the JSON a human expects."""
    var payload = response_to_api_gateway_v2(
        _response_with_text_body(Int32(201), String('{"ok": true}'))
    )
    var v = parse_json_value(payload)
    assert_equal(v.get(String("statusCode")).text, String("201"))
    assert_equal(v.get(String("body")).as_string(), String('{"ok": true}'))
    assert_false(v.get(String("isBase64Encoded")).as_bool())
    assert_equal(
        v.get(String("headers")).get(String("content-type")).as_string(),
        String("application/json"),
    )


def test_a_binary_response_is_base64_encoded_and_declared() raises:
    """§4 OUTBOUND: the flag is DERIVED FROM THE BYTES, never assumed.

    The probe is invalid UTF-8, so it must take the base64 path AND round-trip
    back to the identical bytes. Hardcoding `isBase64Encoded: false` corrupts
    every binary response and raises nothing — the client receives mojibake and
    the function's error metric stays flat."""
    var probe = _binary_probe()
    var r = HttpResponse(status=Int32(200))
    r.headers[String("content-type")] = String("application/octet-stream")
    for i in range(len(probe)):
        r.body.append(probe[i])

    var v = parse_json_value(response_to_api_gateway_v2(r^))
    assert_true(v.get(String("isBase64Encoded")).as_bool())
    assert_true(
        _bytes_equal(base64_decode(v.get(String("body")).as_string()), probe)
    )


def test_set_cookie_becomes_the_cookies_array_and_not_a_header() raises:
    """⛔ In format 2.0 a `Set-Cookie` returned as an ordinary header is DROPPED
    by API Gateway. The response is still valid JSON and is still accepted — so
    the login "works locally" and silently sets no cookie behind the gateway.

    Asserts BOTH halves: it IS in `cookies`, and it is NOT in `headers`."""
    var r = HttpResponse(status=Int32(200))
    r.headers[String("content-type")] = String("text/plain")
    r.headers[String("set-cookie")] = String("session=abc; HttpOnly")

    var v = parse_json_value(response_to_api_gateway_v2(r^))
    assert_true(v.has(String("cookies")))
    assert_equal(v.get(String("cookies")).array_len(), 1)
    assert_equal(
        v.get(String("cookies")).element_at(0).as_string(),
        String("session=abc; HttpOnly"),
    )
    assert_false(v.get(String("headers")).has(String("set-cookie")))
    # NON-EMPTY ARM: the other header must survive the extraction.
    assert_equal(
        v.get(String("headers")).get(String("content-type")).as_string(),
        String("text/plain"),
    )


def test_no_set_cookie_emits_no_cookies_key_at_all() raises:
    """The complement — `cookies: []` on every response would be noise API
    Gateway does not need, and its absence is what makes the case above
    meaningful."""
    var v = parse_json_value(
        response_to_api_gateway_v2(
            _response_with_text_body(Int32(200), String("{}"))
        )
    )
    assert_false(v.has(String("cookies")))


# =============================================================================
# §5 — THE NON-EMPTY ARM, as its own case.
# =============================================================================

def test_a_dropping_converter_is_not_accepted() raises:
    """⚠ THE GUARD ON THIS WHOLE FILE. A converter that discarded everything and
    produced an empty request (or that answered 500 and never converted) would
    satisfy any test phrased as "conversion did not raise". This case pins the
    five things such an implementation cannot produce, in one place, so the
    requirement is visible rather than distributed across the file.

    FAILS ON: an empty `HttpRequest()`; a converter that returns 500 instead of
    converting; one that keeps only the path."""
    var req = api_gateway_v2_event_to_request(_base_event_json(), _prefix())

    assert_false(req.method.code == HTTP_METHOD_UNKNOWN)   # method present
    assert_true(req.path.byte_length() > 0)                 # path present
    assert_true(req.query_string.byte_length() > 0)         # query present
    assert_true(len(req.body) > 0)                          # body present

    # 3 client headers + `cookie` + 2 authorizer entries (`seatCount` is a
    # number and is correctly skipped) = 6. An exact count, because ">0" is
    # satisfied by a converter that kept one header and dropped five.
    assert_equal(len(req.headers), 6)


# =============================================================================
# §6 — ⛔ THE CLOUD-RUN PARITY ORACLE, and the two outbound cases §4 left out.
# =============================================================================
# ⚠ WHAT §1 CANNOT ASSERT, AND WHY IT MATTERS. Every case above compares the
# converter against a value THIS FILE chose. That falsifies "the converter lost
# a field", which is the right first question — but it cannot falsify the
# package's actual claim, that a Lambda receiving an API Gateway message handles
# it exactly like a server request. A converter can be
# self-consistently wrong: comma-JOIN with `","` instead of `", "`, keep the `?`
# on the query string, title-case the header keys. Each of those passes §1 with
# a one-character fixture edit, and each produces a request the shipped
# dispatcher has never seen on the serving path.
#
# ⇒ THE ORACLE IS THE OTHER PRODUCER OF `HttpRequest`, NOT A FIXTURE.
# `parse_request_head` (`komira_http_core.codec.h1`) is the function that builds
# the request on Cloud Run, from socket bytes. §6 hands the two producers THE
# SAME REQUEST — one as HTTP/1.1 wire bytes, one as the API Gateway 2.0 event
# API Gateway emits for it — and asserts the results are equal FIELD BY FIELD
# and, for headers, as SETS IN BOTH DIRECTIONS. Nothing this file believes about
# canonical form enters the comparison; if both producers changed convention
# together the test would still be true, which is exactly the property wanted.
#
# ⚠ THE ONE DIFFERENCE, STATED RATHER THAN ENGINEERED AROUND: the parity fixture
# carries NO `requestContext.authorizer`. The injected `<prefix>*`
# headers have no wire counterpart BY CONSTRUCTION — §3 of `apigw_v2.mojo`
# destroys any client attempt at them — so an event with an authorizer block is
# deliberately NOT the same request, and comparing one would be asserting the
# forgery hole open. That arm is covered by §2 instead.


def _parity_wire_bytes() -> List[UInt8]:
    """The parity request as HTTP/1.1 wire bytes — what a Cloud Run socket
    delivers.

    ⚠ THE COOKIES ARE ONE `Cookie:` HEADER HERE AND A JSON ARRAY IN THE EVENT.
    That asymmetry is the point of including them: it is the one field where the
    two producers are handed genuinely different shapes, so it is the field a
    converter is most likely to fold differently, and the assertion is that they
    land on the same string anyway."""
    var text = String(
        "POST /api/v1/items?tag=a&tag=b&dry_run=1 HTTP/1.1\r\n"
        "Host: api.example.test\r\n"
        "Content-Type: application/json\r\n"
        "Accept: text/html\r\n"
        "Accept: application/json\r\n"
        "X-Request-Id: req-77\r\n"
        "Cookie: session=abc; theme=dark\r\n"
        "Content-Length: 23\r\n"
        "\r\n"
        '{"to": "a@example.com"}'
    )
    var out = List[UInt8]()
    var bs = text.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def _parity_event_json() -> String:
    """THE SAME REQUEST as `_parity_wire_bytes`, as API Gateway 2.0 emits it.

    ⚠ `Accept` IS SENT TWICE ON THE WIRE AND ARRIVES COMMA-JOINED HERE. That is
    not this fixture taking a liberty — it is what API Gateway does to a repeated
    header in payload format 2.0, and it is independently what RFC 7230 §3.2.2
    tells the h1 parser to do (`parser.mojo` folds a duplicate with `", "`). The
    two producers agreeing on `"text/html, application/json"` from two different
    inputs is the strongest single assertion in this file."""
    return String(
        '{'
        '"version": "2.0",'
        '"rawPath": "/api/v1/items",'
        '"rawQueryString": "tag=a&tag=b&dry_run=1",'
        '"cookies": ["session=abc", "theme=dark"],'
        '"headers": {'
        '"host": "api.example.test",'
        '"Content-Type": "application/json",'
        '"Accept": "text/html, application/json",'
        '"X-Request-Id": "req-77",'
        '"Content-Length": "23"'
        '},'
        '"requestContext": {'
        '"http": {"method": "POST", "path": "/api/v1/items"}'
        '},'
        '"body": "{\\"to\\": \\"a@example.com\\"}",'
        '"isBase64Encoded": false'
        '}'
    )


def test_the_converted_request_equals_what_the_h1_parser_produces() raises:
    """⛔ THE PARITY ORACLE. The API Gateway path and the SOCKET path must build
    the same `HttpRequest` for the same request.

    The oracle is `parse_request_head` — the function the Cloud Run serving path
    uses — not a value written here.

    FALSIFIES (each of these passes every case in §1 after a one-character
    fixture edit, and each ships a request the dispatcher has never seen):
      * comma-joining multi-value headers with `","` instead of `", "`;
      * keeping the `?` on `query_string`;
      * emitting header keys in their original case;
      * joining cookies with `";"` instead of `"; "`;
      * dropping `host` or `content-length` because "the gateway handles it".

    ⚠ THE HEADER COMPARISON IS A SET EQUALITY IN BOTH DIRECTIONS. One-directional
    containment plus a count would let a converter that dropped one header and
    invented another pass."""
    var wire = _parity_wire_bytes()
    var parsed = parse_request_head(Span(wire), ParseLimits.defaults())
    if not parsed.err.is_ok():
        raise Error(
            String(
                "the parity fixture is not a request the h1 parser accepts —"
                " the oracle, not the converter, is what failed here (parse err"
                " kind "
            )
            + String(Int(parsed.err.kind))
            + String(")")
        )

    var converted = api_gateway_v2_event_to_request(
        _parity_event_json(), _prefix()
    )

    assert_equal(converted.method.code, parsed.request.method.code)
    assert_equal(converted.path, parsed.request.path)
    assert_equal(converted.query_string, parsed.request.query_string)

    # Headers: same size, and every entry of each present-and-equal in the
    # other. `assert_equal` on the size alone would accept a swap.
    assert_equal(len(converted.headers), len(parsed.request.headers))
    for kv in parsed.request.headers.items():
        assert_equal(
            _header(converted.headers, String(kv.key)), String(kv.value)
        )
    for kv in converted.headers.items():
        assert_equal(
            _header(parsed.request.headers, String(kv.key)), String(kv.value)
        )

    # The body is NOT part of `parse_request_head`'s result — it stops at the
    # CRLFCRLF and reports where the body starts, so the comparison is against
    # the wire bytes from that offset, which is the same thing the serving
    # path's body reader consumes.
    var body_off = parsed.headers_end_off
    assert_equal(len(converted.body), len(wire) - body_off)
    for i in range(len(converted.body)):
        assert_equal(converted.body[i], wire[body_off + i])

    # ⚠ NON-VACUITY. Two EMPTY requests are also equal. If the oracle ever stops
    # producing headers (a parser change, a fixture typo) this comparison would
    # go quietly green over nothing.
    assert_true(len(converted.headers) >= 6)
    assert_true(len(converted.body) > 0)
    assert_equal(converted.method.code, HTTP_METHOD_POST)


def test_a_non_2xx_status_is_carried_verbatim() raises:
    """§4 OUTBOUND, the arm the success cases cannot cover: a FAILURE status must
    reach API Gateway as itself.

    ⛔ WHY IT IS ITS OWN CASE. Both existing outbound tests use 2xx (200, 201), so
    an emitter that clamped anything unexpected to 200 — or that dropped
    `statusCode` and let API Gateway's own default apply — passes every one of
    them. The client then receives 200 for a 404 and for a 503: its retry never
    fires, its error branch never runs, and the function's own error metric stays
    flat while the caller silently gets nothing.

    Both a 4xx and a 5xx, because they are handled by different code on the
    caller's side and a clamp could be written for one range only. The body is
    asserted too — an emitter that carried the status and dropped the explanation
    is the same defect one field over."""
    var not_found = parse_json_value(
        response_to_api_gateway_v2(
            _response_with_text_body(Int32(404), String('{"error": "no_route"}'))
        )
    )
    assert_equal(not_found.get(String("statusCode")).text, String("404"))
    assert_equal(
        not_found.get(String("body")).as_string(), String('{"error": "no_route"}')
    )
    assert_false(not_found.get(String("isBase64Encoded")).as_bool())

    var unavailable = parse_json_value(
        response_to_api_gateway_v2(
            _response_with_text_body(Int32(503), String('{"error": "upstream"}'))
        )
    )
    assert_equal(unavailable.get(String("statusCode")).text, String("503"))
    assert_equal(
        unavailable.get(String("body")).as_string(),
        String('{"error": "upstream"}'),
    )


def test_an_empty_response_body_goes_out_as_empty_TEXT() raises:
    """§4 OUTBOUND: a body of ZERO bytes — a 204, a HEAD, a DELETE that answers
    nothing.

    ⛔ THE EDGE IS IN THE DISCRIMINATOR, NOT THE BODY. `_is_valid_utf8` decides
    the `isBase64Encoded` flag by scanning the bytes, and its loop does not
    execute at all on an empty list. The empty body is therefore the one input
    where the branch is taken with nothing examined, and it is the input most
    likely to be got wrong by a rewrite that reaches for "did we find any
    multi-byte sequence" instead of "did we find an invalid one" — that reading
    sends the empty body down the BASE64 path, and API Gateway then delivers
    `isBase64Encoded: true` with an empty payload, which some clients reject
    outright rather than reading as zero bytes.

    Asserts all three: `body` is PRESENT (not absent — the key missing is a
    third, distinct wrong answer), it is the empty string, and the flag is
    false."""
    var v = parse_json_value(
        response_to_api_gateway_v2(
            _response_with_text_body(Int32(204), String(""))
        )
    )
    assert_equal(v.get(String("statusCode")).text, String("204"))
    assert_true(v.has(String("body")))
    assert_equal(v.get(String("body")).as_string(), String(""))
    assert_false(v.get(String("isBase64Encoded")).as_bool())
    # NON-EMPTY ARM: the rest of the payload must survive an empty body.
    assert_equal(
        v.get(String("headers")).get(String("content-type")).as_string(),
        String("application/json"),
    )


def main() raises:
    test_method_comes_from_request_context_http_not_the_top_level()
    test_raw_path_becomes_the_request_path()
    test_a_repeated_query_key_survives_whole()
    test_a_multi_value_header_arrives_comma_joined_and_unsplit()
    test_header_names_are_ascii_lowercased()
    test_the_cookies_array_folds_into_one_cookie_header()
    test_a_text_body_arrives_as_its_own_bytes()
    test_a_base64_binary_body_is_decoded_inbound()
    test_base64_text_with_the_flag_false_is_NOT_decoded()
    test_an_absent_body_is_empty_not_a_refusal()

    test_the_authorizer_context_reaches_the_request_as_reserved_headers()
    test_a_non_string_authorizer_member_is_skipped_not_stringified()
    test_a_forged_authorizer_header_never_reaches_the_dispatcher()
    test_the_authorizer_wins_over_a_client_header_of_the_same_name()
    test_a_context_key_that_is_not_a_header_token_is_skipped()
    test_a_jwt_authorizer_kind_is_not_read_as_a_context_entry()
    test_the_prefix_is_the_callers_and_only_the_callers()
    test_a_valid_prefix_is_kept_exactly_as_given()
    test_refuses_an_empty_prefix()
    test_refuses_a_prefix_containing_cr_or_lf()
    test_refuses_an_upper_case_prefix()
    test_refuses_a_prefix_that_is_not_a_header_token()
    test_refuses_a_prefix_not_ending_in_a_dash()
    test_refuses_a_prefix_naming_nothing()
    test_refuses_a_prefix_of_a_header_the_gateway_adds()
    test_a_short_prefix_shared_with_client_headers_is_accepted()

    test_refuses_a_1_0_event()
    test_refuses_a_REQUEST_AUTHORIZER_event()
    test_refuses_an_event_with_no_version()
    test_refuses_a_2_0_event_with_no_request_context_http()
    test_refuses_a_base64_body_that_does_not_decode()
    test_refuses_a_payload_that_is_not_a_json_object()
    test_an_escaped_surrogate_pair_body_arrives_as_one_4_byte_character()
    test_refuses_a_body_carrying_a_lone_surrogate_escape()
    test_refuses_a_non_canonical_base64_body()
    test_the_pinned_version_is_2_0()

    test_a_text_response_goes_out_as_text_with_the_flag_false()
    test_a_binary_response_is_base64_encoded_and_declared()
    test_set_cookie_becomes_the_cookies_array_and_not_a_header()
    test_no_set_cookie_emits_no_cookies_key_at_all()

    test_a_dropping_converter_is_not_accepted()

    test_the_converted_request_equals_what_the_h1_parser_produces()
    test_a_non_2xx_status_is_carried_verbatim()
    test_an_empty_response_body_goes_out_as_empty_TEXT()

    print("test_apigw_v2: ALL PASS")
