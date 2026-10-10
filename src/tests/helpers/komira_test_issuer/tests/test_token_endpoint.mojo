# =============================================================================
# test_token_endpoint.mojo: the test issuer's `client_credentials` token
#   endpoint (`TestIssuer.token_request`, token_endpoint.mojo), driven with
#   request bodies built by komira_oauth and assertions signed by komira_jose.
# =============================================================================
#
# What each test proves:
# - test_issues_a_token: a request with a client assertion gets a 200 whose
#   access token verifies under the issuer's own JWK Set as an `at+jwt` for
#   the requested resource, with `sub` and `client_id` the client, the max
#   lifetime and the scope asked for (or the record's whole scope); the
#   assertion's audience may be the issuer or the token endpoint URL; an
#   EdDSA client is served beside an ES256 one.
# - test_replayed_jti_refused: an accepted assertion sent again is refused
#   (401 invalid_client), even when its first use was refused for its
#   resource; another client may use the same jti; a jti is remembered until
#   the assertion's exp plus the leeway and forgotten exactly then.
# - test_assertion_refusals: every way a client assertion fails is 401
#   invalid_client: no jti, an empty jti, sub not iss, an audience that is
#   neither the issuer nor the endpoint (near misses of both), expired at
#   exp plus the leeway, a lifetime over 300 s, another key, an algorithm
#   the record does not pin, typ at+jwt, an unreadable assertion, an unknown
#   or mismatched client_id, a record with only a jwks_uri, a removed client.
# - test_request_refusals: a resource the client may not ask for (near
#   misses) is 400 invalid_target; a scope token outside the record's (first
#   or last) is 400 invalid_scope; the request parse's own codes pass through
#   with 400.
# - test_metadata_document: the RFC 8414 document's exact bytes, read back
#   by komira_oauth for the issuer.
# - test_register_refusals: each refusal of register and remove.
#
# main runs every test and reports every failure.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_jose import (
    ClaimPolicy,
    JwsSigner,
    JwsVerifier,
    assertion_claims,
    mint_client_assertion,
    verify_jwt,
)
from komira_jwks import Jwk, parse_jwk_set, render_jwk_set
from komira_oauth import (
    ClientCredentialsRequest,
    ClientMetadata,
    oauth_error_code,
    parse_authorization_server_metadata,
    parse_token_response,
)
from komira_test_issuer import TestIssuer, derived_key


comptime ISS = "https://issuer.example/a"
comptime ENDPOINT = "https://issuer.example/a/token"
comptime RESOURCE = "https://pdp.example/v1"
comptime OTHER_RESOURCE = "https://relay.example/v1"
comptime CLIENT = "client-1"
comptime CLIENT_B = "client-2"
comptime NOW: Int64 = 1000000
comptime LEEWAY: Int64 = 30


def _issuer() raises -> TestIssuer:
    return TestIssuer(
        issuer=ISS,
        alg="ES256",
        typ="at+jwt",
        max_ttl_s=300,
        leeway_s=LEEWAY,
        publish_lead_s=60,
        seed="issuer-seed",
        now=NOW,
    )


def _client_key(client: String, alg: String = "ES256") raises -> JwsSigner:
    return derived_key(alg, String("client ") + client, 0)


def _record(
    client: String, alg: String = "ES256", scope: String = "read write"
) raises -> ClientMetadata:
    var keys = List[Jwk]()
    keys.append(_client_key(client, alg).public_jwk())
    return ClientMetadata.with_jwks(
        client_id=client,
        client_name="",
        signing_alg=alg,
        scope=scope,
        jwks=parse_jwk_set(render_jwk_set(keys)),
        resource_types=List[String](),
    )


def _resources(*values: String) -> List[String]:
    var out = List[String]()
    for v in values:
        out.append(String(v))
    return out^


def _ready() raises -> TestIssuer:
    var i = _issuer()
    i.register_client(_record(CLIENT), _resources(RESOURCE, OTHER_RESOURCE))
    i.register_client(_record(CLIENT_B, "EdDSA", ""), _resources(RESOURCE))
    return i^


def _assertion(
    client: String,
    now: Int64,
    *,
    audience: String = ISS,
    ttl_s: Int64 = 60,
    jti: String = "jti-0001",
    alg: String = "ES256",
) raises -> String:
    var claims = assertion_claims(
        issuer=client, subject=client, audience=audience, now=now, ttl_s=ttl_s, jti=jti
    )
    return _client_key(client, alg).sign(claims.as_bytes(), String("JWT"))


def _signed(client: String, claims: String, typ: String = "JWT") raises -> String:
    return _client_key(client).sign(claims.as_bytes(), typ)


def _form(
    assertion: String, resource: String = RESOURCE, scope: String = "", client_id: String = ""
) -> String:
    return ClientCredentialsRequest(
        client_assertion=assertion, resource=resource, scope=scope, client_id=client_id
    ).form()


def _outcome(mut i: TestIssuer, form: String) raises -> String:
    """`200`, or `<status> <code>`."""
    var r = i.token_request(form)
    if r.status == 200:
        return String("200")
    return String(r.status) + " " + oauth_error_code(r.body)


def _access_policy(i: TestIssuer, audience: String = RESOURCE) raises -> ClaimPolicy:
    """What a service holding `audience` checks the issuer's tokens with."""
    return ClaimPolicy(
        issuer=ISS, audience=audience, accept_typ="at+jwt", now=i.now(),
        leeway_s=LEEWAY, max_ttl_s=300,
    )


def test_issues_a_token() raises:
    var i = _ready()
    var signer = _client_key(CLIENT)
    var a = mint_client_assertion(signer, client_id=CLIENT, audience=ISS, now=NOW, ttl_s=60)
    var r = i.token_request(_form(a, scope="read"))
    assert_equal(r.status, 200)
    var answer = parse_token_response(r.body)
    assert_equal(answer.expires_in, 300)
    assert_equal(answer.scope, "read")
    var verifier = JwsVerifier("ES256", parse_jwk_set(i.jwks()))
    var jwt = verify_jwt(answer.access_token, verifier, _access_policy(i))
    assert_equal(jwt.subject, CLIENT)
    assert_equal(jwt.audience, RESOURCE)
    assert_equal(jwt.iat, NOW)
    assert_equal(jwt.exp, NOW + 300)
    assert_equal(jwt.claims.get("client_id").as_string(), CLIENT)
    assert_equal(jwt.claims.get("scope").as_string(), "read")
    assert_true(jwt.claims.get("jti").as_string().byte_length() > 0)
    # The token endpoint URL as the audience, the other resource, and no
    # scope asked: the record's whole scope.
    var b = mint_client_assertion(signer, client_id=CLIENT, audience=ENDPOINT, now=NOW, ttl_s=60)
    var r2 = i.token_request(_form(b, resource=OTHER_RESOURCE, client_id=CLIENT))
    assert_equal(r2.status, 200)
    var answer2 = parse_token_response(r2.body)
    assert_equal(answer2.scope, "read write")
    var jwt2 = verify_jwt(answer2.access_token, verifier, _access_policy(i, OTHER_RESOURCE))
    assert_equal(jwt2.claims.get("scope").as_string(), "read write")
    assert_true(jwt2.claims.get("jti").as_string() != jwt.claims.get("jti").as_string())
    # An EdDSA client with no scope: no scope member at all.
    var e = mint_client_assertion(_client_key(CLIENT_B, "EdDSA"), client_id=CLIENT_B, audience=ISS, now=NOW, ttl_s=60)
    var r3 = i.token_request(_form(e))
    assert_equal(r3.status, 200)
    var answer3 = parse_token_response(r3.body)
    assert_equal(answer3.scope, "")
    var jwt3 = verify_jwt(answer3.access_token, verifier, _access_policy(i))
    assert_equal(jwt3.subject, CLIENT_B)
    assert_false(jwt3.claims.has("scope"))


def test_replayed_jti_refused() raises:
    var i = _ready()
    var a = _assertion(CLIENT, NOW)
    assert_equal(_outcome(i, _form(a)), "200")
    assert_equal(_outcome(i, _form(a)), "401 invalid_client")
    # The same assertion with another resource or scope is still a replay.
    assert_equal(_outcome(i, _form(a, resource=OTHER_RESOURCE)), "401 invalid_client")
    # A first use refused for its resource still spends the jti.
    var b = _assertion(CLIENT, NOW, jti="jti-0002")
    assert_equal(_outcome(i, _form(b, resource="https://elsewhere.example/")), "400 invalid_target")
    assert_equal(_outcome(i, _form(b)), "401 invalid_client")
    # Another client's jti is its own.
    var c = _assertion(CLIENT_B, NOW, jti="jti-0001", alg="EdDSA")
    assert_equal(_outcome(i, _form(c)), "200")
    # The jti is remembered until exp + leeway (NOW + 60 + 30): a fresh
    # assertion with it is refused one second before and accepted then.
    i.advance(89)
    var d = _assertion(CLIENT, NOW + 89)
    assert_equal(_outcome(i, _form(d)), "401 invalid_client")
    i.advance(1)
    # Every jti whose time has come is forgotten in one step, including two
    # in a row (jti-0001 and jti-0002 were accepted one after the other).
    var g = _assertion(CLIENT, NOW + 90, jti="jti-0002")
    assert_equal(_outcome(i, _form(g)), "200")
    var f = _assertion(CLIENT, NOW + 90)
    assert_equal(_outcome(i, _form(f)), "200")
    assert_equal(_outcome(i, _form(f)), "401 invalid_client")


def test_assertion_refusals() raises:
    var i = _ready()
    var refused = String("401 invalid_client")
    var misses = String("")
    var cases = List[String]()
    var forms = List[String]()

    cases.append("no jti")
    forms.append(_form(_signed(CLIENT, String('{"iss":"client-1","sub":"client-1","aud":"https://issuer.example/a","iat":1000000,"exp":1000060}'))))
    cases.append("empty jti")
    forms.append(_form(_signed(CLIENT, String('{"iss":"client-1","sub":"client-1","aud":"https://issuer.example/a","iat":1000000,"exp":1000060,"jti":""}'))))
    cases.append("jti not a string")
    forms.append(_form(_signed(CLIENT, String('{"iss":"client-1","sub":"client-1","aud":"https://issuer.example/a","iat":1000000,"exp":1000060,"jti":7}'))))
    cases.append("sub not iss")
    forms.append(_form(_signed(CLIENT, String('{"iss":"client-1","sub":"client-2","aud":"https://issuer.example/a","iat":1000000,"exp":1000060,"jti":"j1"}'))))
    cases.append("lifetime 301 s")
    forms.append(_form(_signed(CLIENT, String('{"iss":"client-1","sub":"client-1","aud":"https://issuer.example/a","iat":1000000,"exp":1000301,"jti":"j2"}'))))
    var aud_near = _resources(
        "https://issuer.example/", "https://issuer.example/ab", "xhttps://issuer.example/a",
        "https://issuer.example/a/toke", "https://issuer.example/a/tokenx", "https://issuer.example/a/",
        "https://issuer.example/A", "https://issuer.example/z", "https://pdp.example/v1",
    )
    for k in range(len(aud_near)):
        cases.append(String("aud ") + aud_near[k])
        forms.append(_form(_assertion(CLIENT, NOW, audience=aud_near[k], jti=String("aud-") + String(k))))
    cases.append("signed by another key")
    var other = derived_key("ES256", "someone else", 0)
    forms.append(_form(other.sign(assertion_claims(issuer=CLIENT, subject=CLIENT, audience=ISS, now=NOW, ttl_s=60, jti="j3").as_bytes(), String("JWT"))))
    cases.append("typ at+jwt")
    forms.append(_form(_signed(CLIENT, assertion_claims(issuer=CLIENT, subject=CLIENT, audience=ISS, now=NOW, ttl_s=60, jti="j4"), "at+jwt")))
    cases.append("not a JWS")
    forms.append(_form("a.b.c"))
    cases.append("one segment")
    forms.append(_form("abc"))
    cases.append("a payload that is not base64url")
    forms.append(_form("eyJhbGciOiJFUzI1NiJ9.!!!.c2ln"))
    cases.append("a payload that is not JSON")
    forms.append(_form("eyJhbGciOiJFUzI1NiJ9.bm9wZQ.c2ln"))
    cases.append("no iss")
    forms.append(_form(_signed(CLIENT, String('{"sub":"client-1","aud":"https://issuer.example/a","iat":1000000,"exp":1000060,"jti":"j10"}'))))
    cases.append("an iss that names the client but is not a string")
    forms.append(_form(_signed(CLIENT, String('{"iss":["client-1"],"sub":"client-1","aud":"https://issuer.example/a","iat":1000000,"exp":1000060,"jti":"j9"}'))))
    cases.append("unknown client")
    forms.append(_form(_assertion("client-9", NOW, jti="j5")))
    cases.append("unknown client_id parameter")
    forms.append(_form(_assertion(CLIENT, NOW, jti="j6"), client_id="client-9"))
    cases.append("client_id parameter of another client")
    forms.append(_form(_assertion(CLIENT, NOW, jti="j7"), client_id=CLIENT_B))
    cases.append("EdDSA assertion for an ES256 record")
    forms.append(_form(_assertion(CLIENT, NOW, jti="j8", alg="EdDSA")))
    for k in range(len(cases)):
        var got = _outcome(i, forms[k])
        if got != refused:
            misses += cases[k] + " -> " + got + "\n"
    # Expiry: an assertion is dead at exp + leeway, alive one second before.
    var late_ok = _assertion(CLIENT, NOW, jti="late-ok")
    var late_no = _assertion(CLIENT, NOW, jti="late-no")
    i.advance(60 + LEEWAY - 1)
    var got1 = _outcome(i, _form(late_ok))
    if got1 != "200":
        misses += String("alive at exp + leeway - 1 -> ") + got1 + "\n"
    i.advance(1)
    var got2 = _outcome(i, _form(late_no))
    if got2 != refused:
        misses += String("dead at exp + leeway -> ") + got2 + "\n"
    assert_equal(misses, "")


def test_record_refusals() raises:
    var i = _issuer()
    var by_uri = ClientMetadata.with_jwks_uri(
        client_id="client-u", client_name="", signing_alg="ES256", scope="",
        jwks_uri="https://client-u.example/keys", resource_types=List[String](),
    )
    i.register_client(by_uri, _resources(RESOURCE))
    assert_equal(_outcome(i, _form(_assertion("client-u", NOW))), "401 invalid_client")
    # A record whose keys none suit its algorithm.
    var keys = List[Jwk]()
    keys.append(_client_key("client-k", "EdDSA").public_jwk())
    var mismatched = ClientMetadata.with_jwks(
        client_id="client-k", client_name="", signing_alg="ES256", scope="",
        jwks=parse_jwk_set(render_jwk_set(keys)), resource_types=List[String](),
    )
    i.register_client(mismatched, _resources(RESOURCE))
    assert_equal(_outcome(i, _form(_assertion("client-k", NOW, alg="EdDSA"))), "401 invalid_client")
    # A removed client.
    i.register_client(_record(CLIENT), _resources(RESOURCE))
    assert_equal(_outcome(i, _form(_assertion(CLIENT, NOW, jti="r1"))), "200")
    i.remove_client(CLIENT)
    assert_equal(_outcome(i, _form(_assertion(CLIENT, NOW, jti="r2"))), "401 invalid_client")


def test_request_refusals() raises:
    var i = _ready()
    var misses = String("")
    var near = _resources(
        "https://pdp.example/v", "https://pdp.example/v1/", "xhttps://pdp.example/v1",
        "ttps://pdp.example/v1", "HTTPS://PDP.EXAMPLE/V1", "zttps://pdp.example/v1",
        "https://pdp.example/v2",
    )
    for k in range(len(near)):
        var got = _outcome(i, _form(_assertion(CLIENT, NOW, jti=String("t") + String(k)), resource=near[k]))
        if got != "400 invalid_target":
            misses += String("resource ") + near[k] + " -> " + got + "\n"
    var scopes = _resources("admin", "read admin", "admin read", "rea", "reads", "read write admin")
    for k in range(len(scopes)):
        var got = _outcome(i, _form(_assertion(CLIENT, NOW, jti=String("s") + String(k)), scope=scopes[k]))
        if got != "400 invalid_scope":
            misses += String("scope ") + scopes[k] + " -> " + got + "\n"
    for s in ["write", "write read", "read write"]:
        var got = _outcome(i, _form(_assertion(CLIENT, NOW, jti=String("ok-") + String(s)), scope=String(s)))
        if got != "200":
            misses += String("scope ") + String(s) + " -> " + got + "\n"
    assert_equal(misses, "")
    assert_equal(_outcome(i, "grant_type=password"), "400 unsupported_grant_type")
    assert_equal(_outcome(i, "a=1&a=2"), "400 invalid_request")
    assert_equal(_outcome(i, _form("")), "401 invalid_client")
    var r = i.token_request("a=1&a=2")
    assert_equal(r.body, '{"error":"invalid_request"}')


def test_metadata_document() raises:
    var i = _issuer()
    assert_equal(i.token_endpoint_url(), ENDPOINT)
    assert_equal(i.jwks_uri(), "https://issuer.example/a/jwks")
    var doc = i.metadata_document()
    assert_equal(
        doc,
        String('{"issuer":"https://issuer.example/a","token_endpoint":"https://issuer.example/a/token",')
        + '"jwks_uri":"https://issuer.example/a/jwks","grant_types_supported":["client_credentials"],'
        + '"token_endpoint_auth_methods_supported":["private_key_jwt"],'
        + '"token_endpoint_auth_signing_alg_values_supported":["ES256","EdDSA"]}',
    )
    var m = parse_authorization_server_metadata(doc, ISS)
    assert_equal(m.token_endpoint, ENDPOINT)


def _register_refusal(mut i: TestIssuer, client: String, resources: List[String]) -> String:
    try:
        i.register_client(_record(client), resources)
    except e:
        return String(e)
    return String("accepted")


def test_register_refusals() raises:
    var i = _ready()
    assert_equal(_register_refusal(i, CLIENT, _resources(RESOURCE)), "TestIssuerError: the client is already registered")
    assert_equal(_register_refusal(i, "c3", List[String]()), "TestIssuerError: a client needs a resource")
    assert_equal(_register_refusal(i, "c3", _resources(RESOURCE, "")), "TestIssuerError: a resource is empty")
    assert_equal(_register_refusal(i, "c3", _resources("a", "b", "a")), "TestIssuerError: a resource is named twice")
    assert_equal(_register_refusal(i, "c3", _resources("a", "b")), "accepted")
    # Ids near a registered one are other clients.
    assert_equal(_register_refusal(i, "client-", _resources("a")), "accepted")
    assert_equal(_register_refusal(i, "client-10", _resources("a")), "accepted")
    assert_equal(_register_refusal(i, "lient-1", _resources("a")), "accepted")
    assert_equal(_register_refusal(i, "xclient-1", _resources("a")), "accepted")
    assert_equal(_register_refusal(i, "CLIENT-1", _resources("a")), "accepted")
    var msg = String("")
    try:
        i.remove_client("client-9")
    except e:
        msg = String(e)
    assert_equal(msg, "TestIssuerError: no such client")


def main() raises:
    var failures = String("")
    try:
        test_issues_a_token()
    except e:
        failures += String("test_issues_a_token: ") + String(e) + "\n"
    try:
        test_replayed_jti_refused()
    except e:
        failures += String("test_replayed_jti_refused: ") + String(e) + "\n"
    try:
        test_assertion_refusals()
    except e:
        failures += String("test_assertion_refusals: ") + String(e) + "\n"
    try:
        test_record_refusals()
    except e:
        failures += String("test_record_refusals: ") + String(e) + "\n"
    try:
        test_request_refusals()
    except e:
        failures += String("test_request_refusals: ") + String(e) + "\n"
    try:
        test_metadata_document()
    except e:
        failures += String("test_metadata_document: ") + String(e) + "\n"
    try:
        test_register_refusals()
    except e:
        failures += String("test_register_refusals: ") + String(e) + "\n"
    if failures != "":
        print(failures)
        raise Error("test_token_endpoint failed")
    print("PASS komira_test_issuer test_token_endpoint")
