# =============================================================================
# test_token_wire.mojo: the token endpoint wire of token_wire.mojo: the
#   exact request and answer bytes; every refusal of the request parse with
#   its RFC 6749 error code, in order, with near-miss tables for the two
#   fixed values; every refusal of the answer parse at its boundary; and the
#   error code read from an error body, which never repeats any other byte.
# =============================================================================
#
# main runs every test and reports every failure.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_oauth import (
    OAUTH_ASSERTION_TYPE_JWT_BEARER,
    OAUTH_RESPONSE_MAX_BYTES,
    ClientCredentialsRequest,
    oauth_error_code,
    oauth_error_codes,
    parse_client_credentials_request,
    parse_token_response,
    render_oauth_error,
    render_token_response,
)


comptime URN_ENC = "urn%3Aietf%3Aparams%3Aoauth%3Aclient-assertion-type%3Ajwt-bearer"
comptime G_OK = "grant_type=client_credentials"
comptime T_OK = "client_assertion_type=" + URN_ENC
comptime A_OK = "client_assertion=aa.bb.cc"
comptime R_OK = "resource=r1"


def _form(
    g: String = G_OK,
    t: String = T_OK,
    a: String = A_OK,
    r: String = R_OK,
    extra: String = "",
) -> String:
    var parts = List[String]()
    for p in [g, t, a, r, extra]:
        if p.byte_length() > 0:
            parts.append(p)
    var out = String("")
    for i in range(len(parts)):
        if i > 0:
            out += "&"
        out += parts[i]
    return out^


def _outcome(body: String) -> String:
    """`<code>: <reason>`, or `ok`."""
    var p = parse_client_credentials_request(body)
    if p.ok():
        return String("ok")
    return p.error + ": " + p.reason


def _response_refusal(body: String) -> String:
    try:
        _ = parse_token_response(body)
    except e:
        return String(e)
    return String("accepted")


def _near_misses(v: String) -> List[String]:
    """Prefix, extension at each end, proper suffix, case variant, empty,
    first and last byte replaced."""
    var b = v.as_bytes()
    var n = len(b)
    var out = List[String]()
    out.append(String(v[byte = 0 : n - 1]))
    out.append(v + "x")
    out.append(String("x") + v)
    out.append(String(v[byte = 1:n]))
    out.append(v.upper())
    out.append(String(""))
    out.append(String("z") + String(v[byte = 1:n]))
    out.append(String(v[byte = 0 : n - 1]) + "z")
    return out^


def test_request_bytes() raises:
    var r = ClientCredentialsRequest(
        client_assertion="aa.bb.cc",
        resource="https://pdp.example/a",
        scope="read write",
    )
    assert_equal(
        r.form(),
        String("grant_type=client_credentials&client_assertion_type=")
        + URN_ENC
        + "&client_assertion=aa.bb.cc&resource=https%3A%2F%2Fpdp.example%2Fa"
        + "&scope=read%20write",
    )
    var bare = ClientCredentialsRequest(
        client_assertion="aa.bb.cc", resource="r1", scope=""
    )
    assert_equal(bare.form(), _form())
    var with_id = ClientCredentialsRequest(
        client_assertion="aa.bb.cc", resource="r1", scope="", client_id="c1"
    )
    assert_equal(
        with_id.form(),
        _form(a=String(A_OK) + "&client_id=c1"),
    )


def test_request_parse() raises:
    var p = parse_client_credentials_request(_form())
    assert_true(p.ok())
    assert_equal(p.error, "")
    assert_equal(p.request.client_assertion, "aa.bb.cc")
    assert_equal(p.request.resource, "r1")
    assert_equal(p.request.scope, "")
    assert_equal(p.request.client_id, "")
    var q = parse_client_credentials_request(
        _form(extra="scope=read+write&client_id=c1&unknown=1")
    )
    assert_true(q.ok())
    assert_equal(q.request.scope, "read write")
    assert_equal(q.request.client_id, "c1")
    # Round trip from the writer.
    var r = ClientCredentialsRequest(
        client_assertion="x.y.z",
        resource="https://pdp.example/a?b",
        scope="s1",
        client_id="c9",
    )
    var back = parse_client_credentials_request(r.form())
    assert_true(back.ok())
    assert_equal(back.request.client_assertion, "x.y.z")
    assert_equal(back.request.resource, "https://pdp.example/a?b")
    assert_equal(back.request.scope, "s1")
    assert_equal(back.request.client_id, "c9")


def test_request_refusals() raises:
    assert_equal(
        _outcome("a=1&&b=2"), "invalid_request: the body is not a form"
    )
    assert_equal(
        _outcome(_form(extra="client_secret=s")),
        "invalid_client: two client authentication methods",
    )
    assert_equal(
        _outcome(_form(extra="client_secret=")),
        "invalid_client: two client authentication methods",
    )
    assert_equal(
        _outcome(_form(g="")), "invalid_request: grant_type is missing"
    )
    assert_equal(
        _outcome(_form(g="grant_type=password")),
        "unsupported_grant_type: grant_type is not client_credentials",
    )
    assert_equal(
        _outcome(_form(t="")),
        "invalid_client: client_assertion_type is not the JWT bearer type",
    )
    assert_equal(
        _outcome(_form(a="")),
        "invalid_client: client_assertion is missing or empty",
    )
    assert_equal(
        _outcome(_form(a="client_assertion=")),
        "invalid_client: client_assertion is missing or empty",
    )
    assert_equal(
        _outcome(_form(extra="client_id=")), "invalid_client: client_id is empty"
    )
    assert_equal(
        _outcome(_form(r="")), "invalid_target: resource is missing or empty"
    )
    assert_equal(
        _outcome(_form(r="resource=")),
        "invalid_target: resource is missing or empty",
    )
    for s in ["scope=", "scope=a++b", "scope=+a", "scope=a+", "scope=a%22b"]:
        assert_equal(
            _outcome(_form(extra=s)), "invalid_scope: scope is not a scope"
        )
    # One-byte values are values.
    assert_equal(_outcome(_form(a="client_assertion=x", r="resource=y", extra="client_id=c&scope=s")), "ok")


def test_request_refusal_order() raises:
    # With two faults, the earlier check in the documented order answers.
    assert_equal(
        _outcome(String("a=1&a=2&") + "client_secret=s"),
        "invalid_request: the body is not a form",
    )
    assert_equal(
        _outcome(_form(g="", extra="client_secret=s")),
        "invalid_client: two client authentication methods",
    )
    assert_equal(
        _outcome(_form(g="", t="")), "invalid_request: grant_type is missing"
    )
    assert_equal(
        _outcome(_form(g="grant_type=x", t="")),
        "unsupported_grant_type: grant_type is not client_credentials",
    )
    assert_equal(
        _outcome(_form(t="", a="")),
        "invalid_client: client_assertion_type is not the JWT bearer type",
    )
    assert_equal(
        _outcome(_form(a="", r="", extra="client_id=")),
        "invalid_client: client_assertion is missing or empty",
    )
    assert_equal(
        _outcome(_form(r="", extra="client_id=")),
        "invalid_client: client_id is empty",
    )
    assert_equal(
        _outcome(_form(r="", extra="scope=")),
        "invalid_target: resource is missing or empty",
    )


def test_fixed_value_near_misses() raises:
    var misses = String("")
    for v in _near_misses("client_credentials"):
        var got = _outcome(_form(g=String("grant_type=") + v))
        if got != "unsupported_grant_type: grant_type is not client_credentials":
            misses += String("grant_type=") + v + " -> " + got + "\n"
    for v in _near_misses(OAUTH_ASSERTION_TYPE_JWT_BEARER):
        var got = _outcome(_form(t=String("client_assertion_type=") + v))
        if got != "invalid_client: client_assertion_type is not the JWT bearer type":
            misses += String("client_assertion_type=") + v + " -> " + got + "\n"
    assert_equal(misses, "")


def test_response_bytes() raises:
    assert_equal(
        render_token_response("t.o.k", 300, "read write"),
        '{"access_token":"t.o.k","token_type":"Bearer","expires_in":300,"scope":"read write"}',
    )
    assert_equal(
        render_token_response("t.o.k", 1, ""),
        '{"access_token":"t.o.k","token_type":"Bearer","expires_in":1}',
    )


def test_response_parse() raises:
    var r = parse_token_response(render_token_response("t.o.k", 300, "a b"))
    assert_equal(r.access_token, "t.o.k")
    assert_equal(r.expires_in, 300)
    assert_equal(r.scope, "a b")
    for tt in ["Bearer", "bearer", "BEARER", "bEaReR"]:
        var body = String('{"access_token":"x","token_type":"') + tt + '","expires_in":86400}'
        var p = parse_token_response(body)
        assert_equal(p.expires_in, 86400)
        assert_equal(p.scope, "")
    var low = parse_token_response('{"expires_in":1,"token_type":"Bearer","access_token":"y","extra":[1]}')
    assert_equal(low.expires_in, 1)
    assert_equal(low.access_token, "y")


def test_response_refusals() raises:
    var ok_tail = String(',"token_type":"Bearer","expires_in":300}')
    assert_equal(_response_refusal("nope"), "OAuthError: the token response is not JSON")
    assert_equal(_response_refusal("[]"), "OAuthError: the token response is not a JSON object")
    assert_equal(
        _response_refusal('{"access_token":"a","access_token":"b","token_type":"Bearer","expires_in":300}'),
        "OAuthError: the token response names a member twice",
    )
    assert_equal(
        _response_refusal('{"access_token":"a","token_type":"Bearer","expires_in":300,"x":{"k":1,"k":2}}'),
        "OAuthError: the token response names a member twice",
    )
    assert_equal(_response_refusal('{"token_type":"Bearer","expires_in":300}'), "OAuthError: member access_token is missing")
    assert_equal(_response_refusal(String('{"access_token":1') + ok_tail), "OAuthError: member access_token is not a string")
    assert_equal(_response_refusal(String('{"access_token":""') + ok_tail), "OAuthError: member access_token is empty")
    assert_equal(_response_refusal('{"access_token":"a","expires_in":300}'), "OAuthError: member token_type is missing")
    var misses = String("")
    for tt in _near_misses("Bearer"):
        # The type is case-insensitive, so the upper-case variant is Bearer.
        if tt == "" or tt == "BEARER":
            continue
        var body = String('{"access_token":"a","token_type":"') + tt + '","expires_in":300}'
        var got = _response_refusal(body)
        if got != "OAuthError: member token_type is not Bearer":
            misses += tt + " -> " + got + "\n"
    assert_equal(misses, "")
    assert_equal(_response_refusal('{"access_token":"a","token_type":"MAC","expires_in":300}'), "OAuthError: member token_type is not Bearer")
    assert_equal(_response_refusal('{"access_token":"a","token_type":"Bearer"}'), "OAuthError: member expires_in is missing")
    var bad_exp = "OAuthError: member expires_in is not an integer from 1 to 86400"
    for v in ["0", "-1", "86401", '"300"', "300.5", "3e2", "null", "99999999999999999999"]:
        var body = String('{"access_token":"a","token_type":"Bearer","expires_in":') + v + "}"
        assert_equal(_response_refusal(body), bad_exp, v)
    assert_equal(
        _response_refusal('{"access_token":"a","token_type":"Bearer","expires_in":300,"scope":""}'),
        "OAuthError: member scope is empty",
    )
    assert_equal(
        _response_refusal('{"access_token":"a","token_type":"Bearer","expires_in":300,"scope":1}'),
        "OAuthError: member scope is not a string",
    )
    for sc in ["a  b", " a", "a ", "a\\\"b"]:
        var body = String('{"access_token":"a","token_type":"Bearer","expires_in":300,"scope":"') + sc + '"}'
        assert_equal(_response_refusal(body), "OAuthError: member scope is not a scope", sc)


def test_response_size_limit() raises:
    var head = String('{"access_token":"')
    var tail = String('","token_type":"Bearer","expires_in":300}')
    var buf = List[UInt8]()
    buf.extend(Span(head.as_bytes()))
    while len(buf) < OAUTH_RESPONSE_MAX_BYTES - tail.byte_length():
        buf.append(0x61)
    buf.extend(Span(tail.as_bytes()))
    var at_limit = String(unsafe_from_utf8=Span(buf))
    assert_equal(at_limit.byte_length(), OAUTH_RESPONSE_MAX_BYTES)
    assert_equal(parse_token_response(at_limit).expires_in, 300)
    var over = head + "a" + String(at_limit[byte = head.byte_length() :])
    assert_equal(
        _response_refusal(over),
        "OAuthError: the token response is longer than 65536 bytes",
    )


def test_error_codec() raises:
    assert_equal(render_oauth_error("invalid_target"), '{"error":"invalid_target"}')
    var codes = oauth_error_codes()
    assert_equal(len(codes), 7)
    var want = List[String]()
    for c in [
        "invalid_request",
        "invalid_client",
        "invalid_grant",
        "unauthorized_client",
        "unsupported_grant_type",
        "invalid_scope",
        "invalid_target",
    ]:
        want.append(String(c))
    var misses = String("")
    for i in range(len(want)):
        if codes[i] != want[i]:
            misses += String("codes[") + String(i) + "]\n"
        if oauth_error_code(render_oauth_error(want[i])) != want[i]:
            misses += want[i] + " not read back\n"
        for near in _near_misses(want[i]):
            if near == "":
                continue
            var got = oauth_error_code(render_oauth_error(near))
            if got != "not a known code":
                misses += near + " -> " + got + "\n"
    assert_equal(misses, "")
    # Nothing but an allowed code ever comes back.
    var secret = String('{"error":"invalid_client","error_description":"secret-xyz"}')
    assert_equal(oauth_error_code(secret), "invalid_client")
    assert_equal(oauth_error_code('{"error":"secret-xyz"}'), "not a known code")
    assert_equal(oauth_error_code('{"error":1}'), "")
    assert_equal(oauth_error_code('{"err":"invalid_client"}'), "")
    assert_equal(oauth_error_code("secret-xyz"), "")
    assert_equal(oauth_error_code('["invalid_client"]'), "")
    assert_equal(oauth_error_code('{"error":"invalid_client","error":"invalid_client"}'), "")


def main() raises:
    var failures = String("")
    try:
        test_request_bytes()
    except e:
        failures += String("test_request_bytes: ") + String(e) + "\n"
    try:
        test_request_parse()
    except e:
        failures += String("test_request_parse: ") + String(e) + "\n"
    try:
        test_request_refusals()
    except e:
        failures += String("test_request_refusals: ") + String(e) + "\n"
    try:
        test_request_refusal_order()
    except e:
        failures += String("test_request_refusal_order: ") + String(e) + "\n"
    try:
        test_fixed_value_near_misses()
    except e:
        failures += String("test_fixed_value_near_misses: ") + String(e) + "\n"
    try:
        test_response_bytes()
    except e:
        failures += String("test_response_bytes: ") + String(e) + "\n"
    try:
        test_response_parse()
    except e:
        failures += String("test_response_parse: ") + String(e) + "\n"
    try:
        test_response_refusals()
    except e:
        failures += String("test_response_refusals: ") + String(e) + "\n"
    try:
        test_response_size_limit()
    except e:
        failures += String("test_response_size_limit: ") + String(e) + "\n"
    try:
        test_error_codec()
    except e:
        failures += String("test_error_codec: ") + String(e) + "\n"
    if failures != "":
        print(failures)
        raise Error("test_token_wire failed")
    print("PASS komira_oauth test_token_wire")
