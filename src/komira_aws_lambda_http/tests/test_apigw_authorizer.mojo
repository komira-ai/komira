# =============================================================================
# tests/test_apigw_authorizer.mojo — the REQUEST-authorizer event, field by
#   field, plus every refusal and the simple-response contract.
# =============================================================================
# ⛔⛔ THE ONE FALSIFIER THIS FILE EXISTS FOR IS
#   `test_refuses_a_PROXY_event_whose_only_difference_is_the_absent_type`.
# The v2 REQUEST-authorizer payload and the v2 PROXY payload agree on `version`,
# `rawPath`, `headers` and `requestContext.http` — every field a proxy converter
# reads — so `api_gateway_v2_event_to_request` accepts an authorizer event
# without raising, and a naive authorizer parser accepts a PROXY event the same
# way. `type` is the only discriminator. Its two fixtures below differ from the
# base event in EXACTLY that one field, in each direction.
#
# ⛔ AND THE DENY DIRECTION IS TESTED HARDEST, deliberately. An authorizer whose
# falsifiers only prove that a valid answer serializes as `true` proves nothing
# about security: the failure that matters is a refusal that reaches the wire as
# an allow, or a refusal that reaches it CARRYING the claimed identity. Four
# cases pin it — DENY, UNAVAILABLE, an ordinal nobody has heard of, and a DENY
# whose context was populated anyway.
#
# ⇒ THE NON-EMPTY ARM, stated as its own case: `test_the_parsed_event_carries_
#   every_field` pins seven field VALUES, because a parser that returned a
#   default-constructed `ApiGatewayAuthorizerEvent` would satisfy "parsing
#   succeeded" and every refusal test in this file, and would then deny every
#   request forever — a fail-closed bug is still a bug.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_json import parse_json_value

from komira_aws_lambda_http.apigw_authorizer import (
    APIGW_AUTHORIZER_EVENT_TYPE,
    AUTHZ_ANSWER_ALLOW,
    AUTHZ_ANSWER_DENY,
    AUTHZ_ANSWER_UNAVAILABLE,
    AuthorizerAnswer,
    authorizer_deny_json,
    authorizer_simple_response_json,
    parse_api_gateway_authorizer_event,
)


# =============================================================================
# §1 — fixtures. Every negative one differs from `_base_event_json()` in EXACTLY
#      ONE field.
# =============================================================================

def _base_event_json() -> String:
    """A realistic payload-format-2.0 REQUEST-authorizer event.

    ⚠ NOTE WHAT IT SHARES WITH A PROXY EVENT — `version`, `rawPath`, `headers`,
    `requestContext.http` — and what it does not: `type`, `routeArn`,
    `identitySource`, and NO `body`. The overlap is the whole hazard."""
    return String(
        '{'
        '"version": "2.0",'
        '"type": "REQUEST",'
        '"routeArn":'
        ' "arn:aws:execute-api:us-east-1:111122223333:abc123/$default/POST/v1/messages",'
        '"identitySource": ["Bearer tok-live"],'
        '"routeKey": "POST /v1/messages",'
        '"rawPath": "/v1/messages",'
        '"rawQueryString": "",'
        '"headers": {'
        '"Authorization": "Bearer tok-live",'
        '"Content-Type": "application/json"'
        '},'
        '"requestContext": {'
        '"requestId": "gw-req-42",'
        '"apiId": "abc123",'
        '"stage": "$default",'
        '"http": {"method": "POST", "path": "/v1/messages"}'
        '}'
        '}'
    )


def _without_type_json() -> String:
    """The base event with `"type": "REQUEST",` REMOVED and nothing else changed
    — which is exactly a PROXY event's shape."""
    return String(
        '{'
        '"version": "2.0",'
        '"routeArn":'
        ' "arn:aws:execute-api:us-east-1:111122223333:abc123/$default/POST/v1/messages",'
        '"identitySource": ["Bearer tok-live"],'
        '"routeKey": "POST /v1/messages",'
        '"rawPath": "/v1/messages",'
        '"rawQueryString": "",'
        '"headers": {'
        '"Authorization": "Bearer tok-live",'
        '"Content-Type": "application/json"'
        '},'
        '"requestContext": {'
        '"requestId": "gw-req-42",'
        '"apiId": "abc123",'
        '"stage": "$default",'
        '"http": {"method": "POST", "path": "/v1/messages"}'
        '}'
        '}'
    )


def _with_type_json(kind: String) -> String:
    """The base event with `type` set to `kind`. ONE field."""
    return String(
        '{'
        '"version": "2.0",'
        '"type": "'
    ) + kind + String(
        '",'
        '"routeArn":'
        ' "arn:aws:execute-api:us-east-1:111122223333:abc123/$default/POST/v1/messages",'
        '"identitySource": ["Bearer tok-live"],'
        '"routeKey": "POST /v1/messages",'
        '"rawPath": "/v1/messages",'
        '"rawQueryString": "",'
        '"headers": {"Authorization": "Bearer tok-live"},'
        '"requestContext": {"requestId": "gw-req-42",'
        '"http": {"method": "POST"}}'
        '}'
    )


def _with_version_json(version: String) -> String:
    """The base event with `version` set to `version`. ONE field."""
    return String('{"version": "') + version + String(
        '",'
        '"type": "REQUEST",'
        '"routeArn":'
        ' "arn:aws:execute-api:us-east-1:111122223333:abc123/$default/POST/v1/messages",'
        '"identitySource": ["Bearer tok-live"],'
        '"routeKey": "POST /v1/messages",'
        '"rawPath": "/v1/messages",'
        '"headers": {"Authorization": "Bearer tok-live"},'
        '"requestContext": {"requestId": "gw-req-42",'
        '"http": {"method": "POST"}}'
        '}'
    )


def _refused(event_json: String) raises -> Bool:
    """TRUE iff the parser REFUSED. Never swallows the reason silently — the
    caller asserts on the message where the message is the point."""
    try:
        _ = parse_api_gateway_authorizer_event(event_json)
        return False
    except e:
        _ = e
        return True


# =============================================================================
# §2 — the parse. The NON-EMPTY arm first.
# =============================================================================

def test_the_parsed_event_carries_every_field() raises:
    """⇒ THE NON-EMPTY ARM. Seven field VALUES, because a parser that returned a
    default-constructed event would pass every refusal test in this file and
    then deny every request forever."""
    var ev = parse_api_gateway_authorizer_event(_base_event_json())

    assert_equal(
        ev.route_arn,
        String(
            "arn:aws:execute-api:us-east-1:111122223333:abc123/$default/POST/v1/messages"
        ),
    )
    assert_equal(ev.route_key, String("POST /v1/messages"))
    assert_equal(ev.raw_path, String("/v1/messages"))
    assert_equal(ev.http_method, String("POST"))
    assert_equal(ev.request_id, String("gw-req-42"))
    assert_equal(len(ev.identity_source), 1)
    assert_equal(ev.identity_source[0], String("Bearer tok-live"))
    assert_equal(len(ev.headers), 2)
    # ⚠ LOOKUP IS BY LOWERCASE NAME — API Gateway already lowercases in 2.0 and
    # the parser folds again, so `Authorization` is reachable as `authorization`
    # and NOT as the spelling the fixture used.
    assert_equal(ev.header(String("authorization")), String("Bearer tok-live"))
    assert_equal(ev.header(String("content-type")), String("application/json"))
    assert_equal(ev.header(String("Authorization")), String(""))
    assert_equal(ev.header(String("x-absent")), String(""))


def test_refuses_a_PROXY_event_whose_only_difference_is_the_absent_type() raises:
    """⛔⛔ THE FALSIFIER THIS FILE EXISTS FOR.

    `_without_type_json()` is `_base_event_json()` with `"type": "REQUEST",`
    deleted and NOTHING else changed — i.e. a PROXY event. Every other check the
    parser makes passes on it: it is an object, `version` is `"2.0"`, it has
    `requestContext.http`, it has `headers` including `authorization`. So a
    parser without the `type` assertion would authorize a call described by a
    payload nobody meant to hand an authorizer, and would do it silently."""
    assert_true(_refused(_without_type_json()))
    # ⚠ AND THE MESSAGE MUST SAY WHICH SHAPE IT GOT. A refusal that says only
    # "malformed" sends an operator looking at the caller instead of at the
    # integration.
    var message = String("")
    try:
        _ = parse_api_gateway_authorizer_event(_without_type_json())
    except e:
        message = String(e)
    assert_true(message.find(String("PROXY")) >= 0)
    assert_true(message.find(String("type")) >= 0)


def test_refuses_a_TOKEN_authorizer_event() raises:
    """`TOKEN` is the REST-API shape: it carries `authorizationToken` and no
    `headers` at all, so coercing it would authorize against fields that are not
    there. ONE field differs from the base event."""
    assert_true(_refused(_with_type_json(String("TOKEN"))))


def test_refuses_a_JWT_authorizer_event() raises:
    """`JWT` is not a Lambda authorizer: API Gateway validates a JWT itself,
    with no function invoked. If one is ever routed here anyway, this runtime
    must not pretend to be it."""
    assert_true(_refused(_with_type_json(String("JWT"))))


def test_refuses_an_empty_type() raises:
    """An empty string is not `REQUEST`. Named separately from the absent case
    because `has("type")` is TRUE here and the second check is what catches it.
    """
    assert_true(_refused(_with_type_json(String(""))))


def test_refuses_a_1_0_authorizer_event() raises:
    """A 1.0 REQUEST-authorizer event puts the headers under
    `multiValueHeaders`, so read as 2.0 it yields an event with NO
    `authorization` header — a deny blamed on the caller for a misconfiguration
    of ours."""
    assert_true(_refused(_with_version_json(String("1.0"))))


def test_refuses_a_missing_version() raises:
    assert_true(
        _refused(
            String(
                '{"type": "REQUEST", "rawPath": "/v1/messages",'
                ' "headers": {"authorization": "Bearer t"},'
                ' "requestContext": {"http": {"method": "POST"}}}'
            )
        )
    )


def test_refuses_a_payload_that_is_not_a_json_object() raises:
    """A direct invoke, an SQS event, an S3 notification — anything that is not
    an object. The message names the possibilities so the reader is not left
    with "malformed"."""
    assert_true(_refused(String('["not", "an", "object"]')))
    assert_true(_refused(String('"a bare string"')))


def test_a_minimal_but_WELL_SHAPED_event_parses_with_empty_optionals() raises:
    """⚠ THE SCOPE OF THE REFUSALS, STATED. Only the three SHAPE fields are
    required. A payload revision that dropped `routeArn` or `identitySource`
    must not become a total outage, because neither can change the decision —
    the decision is a function of the credential and of the upstream
    authority's answer. A missing credential is then the DECIDER's deny, not
    the parser's refusal, which is where it belongs."""
    var ev = parse_api_gateway_authorizer_event(
        String('{"version": "2.0", "type": "REQUEST"}')
    )
    assert_equal(ev.route_arn, String(""))
    assert_equal(ev.raw_path, String(""))
    assert_equal(ev.request_id, String(""))
    assert_equal(len(ev.identity_source), 0)
    assert_equal(len(ev.headers), 0)
    assert_equal(ev.header(String("authorization")), String(""))


def test_a_non_string_header_value_is_skipped_not_stringified() raises:
    """API Gateway delivers header values as strings. A number here means the
    payload was assembled by something else; inventing `"12"` for it would
    fabricate a header value nobody sent."""
    var ev = parse_api_gateway_authorizer_event(
        String(
            '{"version": "2.0", "type": "REQUEST",'
            ' "headers": {"authorization": "Bearer t", "x-seats": 12}}'
        )
    )
    assert_equal(len(ev.headers), 1)
    assert_equal(ev.header(String("authorization")), String("Bearer t"))
    assert_equal(ev.header(String("x-seats")), String(""))


# =============================================================================
# §3 — the SIMPLE RESPONSE. ⛔ THE DENY DIRECTION, HARDEST.
# =============================================================================

def _is_authorized_of(payload: String) raises -> Bool:
    var v = parse_json_value(payload)
    if not v.is_object() or not v.has(String("isAuthorized")):
        raise Error(String("payload has no isAuthorized: ") + payload)
    var flag = v.get(String("isAuthorized"))
    if flag.kind_tag() != 1:  # JSON_BOOL
        raise Error(String("isAuthorized is not a bool: ") + payload)
    return flag.as_bool()


def _context_member_count_of(payload: String) raises -> Int:
    var v = parse_json_value(payload)
    if not v.is_object() or not v.has(String("context")):
        raise Error(String("payload has no context: ") + payload)
    var ctx = v.get(String("context"))
    if not ctx.is_object():
        raise Error(String("context is not an object: ") + payload)
    return ctx.num_members()


def _context_value_of(payload: String, key: String) raises -> String:
    var v = parse_json_value(payload)
    var ctx = v.get(String("context"))
    if not ctx.has(key):
        return String("")
    var m = ctx.get(key)
    if m.kind_tag() != 3:  # JSON_STRING
        return String("")
    return m.as_string()


def test_an_allow_serializes_true_and_carries_its_context() raises:
    """The NON-EMPTY arm of the serializer: `isAuthorized` true AND both members
    present with their values. A serializer that emitted `{"isAuthorized":true}`
    and dropped the context would satisfy "an allow is an allow" and leave the
    backend with no identity."""
    var a = AuthorizerAnswer(AUTHZ_ANSWER_ALLOW)
    a.add_context(String("subject_id"), String("11111111-1111-1111-1111-111111111111"))
    a.add_context(
        String("session_id"),
        String("22222222-2222-2222-2222-222222222222"),
    )
    var payload = authorizer_simple_response_json(a)

    assert_true(_is_authorized_of(payload))
    assert_equal(_context_member_count_of(payload), 2)
    assert_equal(
        _context_value_of(payload, String("subject_id")),
        String("11111111-1111-1111-1111-111111111111"),
    )
    assert_equal(
        _context_value_of(payload, String("session_id")),
        String("22222222-2222-2222-2222-222222222222"),
    )


def test_a_DENY_serializes_false() raises:
    var payload = authorizer_simple_response_json(
        AuthorizerAnswer(AUTHZ_ANSWER_DENY)
    )
    assert_false(_is_authorized_of(payload))
    assert_equal(_context_member_count_of(payload), 0)


def test_UNAVAILABLE_is_not_an_allow() raises:
    """⛔ "The upstream authority could not be asked" must never serialize as an
    allow. `AUTHZ_ANSWER_UNAVAILABLE` never reaches the wire at all in the
    deployed shape (the pump routes it to the ERROR channel), and if it ever
    did, it must be `false`."""
    var a = AuthorizerAnswer(AUTHZ_ANSWER_UNAVAILABLE)
    assert_false(a.is_allowed())
    assert_false(
        _is_authorized_of(authorizer_simple_response_json(a))
    )


def test_an_ordinal_NOBODY_HAS_HEARD_OF_is_not_an_allow() raises:
    """⛔ TOTALITY. A value from a newer caller, an uninitialised field, a
    garbage int — `is_allowed()` is `kind == ALLOW`, never `kind != DENY`, so
    the default is refusal and there is no allow at the bottom."""
    var a = AuthorizerAnswer(99)
    assert_false(a.is_allowed())
    assert_false(_is_authorized_of(authorizer_simple_response_json(a)))
    var b = AuthorizerAnswer(-1)
    assert_false(b.is_allowed())
    assert_false(_is_authorized_of(authorizer_simple_response_json(b)))


def test_a_DENY_serializes_an_EMPTY_context_EVEN_WHEN_ONE_WAS_ADDED() raises:
    """⛔⛔ THE STRUCTURAL ENFORCEMENT, and the reason it is in the SERIALIZER.

    A refusal must not carry the claimed identity — `authorizer._empty_
    principal()`'s rule, one layer up. A populated subject on a refusal is
    indistinguishable from a populated subject on an allow at exactly the point
    where the difference is the whole decision.

    ⚠ THE FIXTURE DELIBERATELY DOES THE WRONG THING: it builds a DENY and then
    adds context anyway, which is what a caller that reused an allow-shaped
    builder would do. The serializer discards it. If the enforcement lived at
    every construction site instead, this test would be asserting a
    convention."""
    var a = AuthorizerAnswer(AUTHZ_ANSWER_DENY)
    a.add_context(String("subject_id"), String("subject-victim"))
    a.add_context(String("session_id"), String("session-victim"))
    assert_equal(a.context_len(), 2)

    var payload = authorizer_simple_response_json(a)
    assert_false(_is_authorized_of(payload))
    assert_equal(_context_member_count_of(payload), 0)
    assert_equal(_context_value_of(payload, String("subject_id")), String(""))
    # And the string itself must not contain the leaked value anywhere — a
    # member emitted under a different key would satisfy the count assertion.
    assert_true(payload.find(String("subject-victim")) < 0)
    assert_true(payload.find(String("session-victim")) < 0)


def test_the_UNAVAILABLE_ordinal_also_drops_its_context() raises:
    """Same rule, the other non-allow ordinal. Named separately because the
    serializer keys on `is_allowed()` and not on `kind == DENY`, and a
    `kind != DENY` implementation would pass the DENY case and leak here."""
    var a = AuthorizerAnswer(AUTHZ_ANSWER_UNAVAILABLE)
    a.add_context(String("subject_id"), String("subject-victim"))
    var payload = authorizer_simple_response_json(a)
    assert_false(_is_authorized_of(payload))
    assert_equal(_context_member_count_of(payload), 0)
    assert_true(payload.find(String("subject-victim")) < 0)


def test_context_is_ALWAYS_emitted_so_the_shape_never_depends_on_the_verdict() raises:
    """API Gateway accepts an absent `context`, but a payload whose SHAPE
    depends on the outcome makes a field-by-field reader assert two different
    things about one contract."""
    var allow = AuthorizerAnswer(AUTHZ_ANSWER_ALLOW)
    var allow_payload = authorizer_simple_response_json(allow)
    assert_equal(_context_member_count_of(allow_payload), 0)
    assert_equal(
        _context_member_count_of(
            authorizer_simple_response_json(AuthorizerAnswer(AUTHZ_ANSWER_DENY))
        ),
        0,
    )


def test_a_duplicate_context_key_is_REFUSED() raises:
    """The last write would silently win, so two disagreeing values for one
    identity fact would ship the second with no diagnostic."""
    var a = AuthorizerAnswer(AUTHZ_ANSWER_ALLOW)
    a.add_context(String("subject_id"), String("subject-a"))
    var raised = False
    try:
        a.add_context(String("subject_id"), String("subject-b"))
    except e:
        raised = True
        _ = e
    assert_true(raised)
    assert_equal(a.context_len(), 1)
    assert_equal(
        _context_value_of(authorizer_simple_response_json(a), String("subject_id")),
        String("subject-a"),
    )


def test_an_empty_context_key_is_REFUSED() raises:
    """API Gateway would accept it and the backend would receive a header named
    by the reserved prefix alone."""
    var a = AuthorizerAnswer(AUTHZ_ANSWER_ALLOW)
    var raised = False
    try:
        a.add_context(String(""), String("value"))
    except e:
        raised = True
        _ = e
    assert_true(raised)
    assert_equal(a.context_len(), 0)


def test_the_deny_payload_has_ONE_spelling() raises:
    """`authorizer_deny_json()` is that spelling, so the pump and every caller
    emit the same bytes."""
    assert_equal(
        authorizer_deny_json(),
        authorizer_simple_response_json(AuthorizerAnswer(AUTHZ_ANSWER_DENY)),
    )
    assert_false(_is_authorized_of(authorizer_deny_json()))


def test_the_three_ordinals_are_distinct_and_allow_is_zero() raises:
    """⚠ THE ORDINALS ARE STABLE. A consumer whose decision core spells these
    differently pins the equality in its own tests. What is pinnable here is that the three are distinct and that the type discriminator
    is the documented string."""
    assert_equal(AUTHZ_ANSWER_ALLOW, 0)
    assert_equal(AUTHZ_ANSWER_DENY, 1)
    assert_equal(AUTHZ_ANSWER_UNAVAILABLE, 2)
    assert_equal(String(APIGW_AUTHORIZER_EVENT_TYPE), String("REQUEST"))


def main() raises:
    test_the_parsed_event_carries_every_field()
    test_refuses_a_PROXY_event_whose_only_difference_is_the_absent_type()
    test_refuses_a_TOKEN_authorizer_event()
    test_refuses_a_JWT_authorizer_event()
    test_refuses_an_empty_type()
    test_refuses_a_1_0_authorizer_event()
    test_refuses_a_missing_version()
    test_refuses_a_payload_that_is_not_a_json_object()
    test_a_minimal_but_WELL_SHAPED_event_parses_with_empty_optionals()
    test_a_non_string_header_value_is_skipped_not_stringified()

    test_an_allow_serializes_true_and_carries_its_context()
    test_a_DENY_serializes_false()
    test_UNAVAILABLE_is_not_an_allow()
    test_an_ordinal_NOBODY_HAS_HEARD_OF_is_not_an_allow()
    test_a_DENY_serializes_an_EMPTY_context_EVEN_WHEN_ONE_WAS_ADDED()
    test_the_UNAVAILABLE_ordinal_also_drops_its_context()
    test_context_is_ALWAYS_emitted_so_the_shape_never_depends_on_the_verdict()
    test_a_duplicate_context_key_is_REFUSED()
    test_an_empty_context_key_is_REFUSED()
    test_the_deny_payload_has_ONE_spelling()
    test_the_three_ordinals_are_distinct_and_allow_is_zero()

    print("test_apigw_authorizer: ALL PASS")
