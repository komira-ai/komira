# =============================================================================
# test_client.mojo: the `client_credentials` client and
#   `ClientCredentialSource` (client.mojo) over a scripted transport that
#   records every request and replays canned answers.
# =============================================================================
#
# What each test proves:
# - test_request_on_the_wire: the exact form a token endpoint receives, and
#   that its assertion verifies under komira_jose's `verify_client_assertion`
#   with the client's public key: `iss = sub = client_id`, the audience
#   asked for, a 60 s lifetime from now, and a `jti` of 128 random bits that
#   differs per request. An assertion minted without a `jti` turns it red.
# - test_answer_read: the answer's token, lifetime and scope.
# - test_failures: each failure's exact message; the transport's own text
#   (which holds the request) and the body's description never appear; only
#   status 200 is an answer.
# - test_argument_refusals: each refused argument, refused before any
#   request is sent, for the function and the source.
# - test_source_refresh: a token is fetched on first use, served until 60 s
#   before it expires (the boundary second on each side), fetched again
#   from then on, and a short-lived token is fetched for every call.
# - test_failed_refresh_never_serves_stale: a refresh that fails raises, even
#   while the former token has not expired; the source holds nothing after
#   it, so a later call fetches rather than serving the former token; a
#   later success serves the new token.
# - test_time_bounds: a negative time and one too late for an expiry.
#
# Keys: RFC 7515 appendix A.3 (ES256), RFC 8037 appendix A.1 (EdDSA) and
# komira_http_core's RSA test key (an RS256 signer, refused).
#
# main runs every test and reports every failure.
# =============================================================================

from std.pathlib import Path
from std.testing import assert_equal, assert_false, assert_true

from komira_crypto import rsa_pkcs8_der_from_pem
from komira_encoding import base64_url_decode_nopad
from komira_jose import (
    ClaimPolicy,
    JwsSigner,
    JwsVerifier,
    verify_client_assertion,
)
from komira_jwks import Jwk, parse_jwk_set, render_jwk_set
from komira_oauth import (
    OAUTH_ASSERTION_TTL_S,
    OAUTH_REFRESH_SKEW_S,
    ClientCredentialSource,
    TokenEndpointReply,
    TokenEndpointTransport,
    fetch_client_credentials_token,
    parse_client_credentials_request,
    render_oauth_error,
    render_token_response,
)
from komira_secret_store import SecretValue


comptime A3_D = "jpsQnnGQmL-YBIffH1136cspYG6-0iY7X1fCE9-E9LI"
comptime SEED = "nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A"
comptime RSA_PEM = "src/komira_http_core/tests/fixtures/tls/leaf_key.pem"
comptime CLIENT = "client-1"
comptime ENDPOINT = "https://issuer.example/a/token"
comptime AUD = "https://issuer.example/a"
comptime RESOURCE = "https://pdp.example/v1"
comptime NOW: Int64 = 1000000
# A status the scripted transport reads as "raise instead of answering".
comptime DOWN = -1


struct Scripted(TokenEndpointTransport, Movable, Deinitable):
    """Answers from `replies` in order (status `DOWN` raises, with the
    request in its text); records every URL and form."""

    var replies: List[TokenEndpointReply]
    var urls: List[String]
    var forms: List[String]

    def __init__(out self):
        self.replies = List[TokenEndpointReply]()
        self.urls = List[String]()
        self.forms = List[String]()

    def answer(mut self, status: Int, body: String):
        self.replies.append(TokenEndpointReply(status, body))

    def token(mut self, token: String, expires_in: Int64):
        self.answer(200, render_token_response(token, expires_in, ""))

    def down(mut self):
        self.answer(DOWN, "")

    def post_form(mut self, url: String, form: String) raises -> TokenEndpointReply:
        self.urls.append(url)
        self.forms.append(form)
        if len(self.replies) == 0:
            raise Error(String("scripted: no answer left for ") + form)
        var r = self.replies.pop(0)
        if r.status == DOWN:
            raise Error(String("scripted: connection refused sending ") + form)
        return r^


def _signer(alg: String) raises -> JwsSigner:
    if alg == "ES256":
        var d = base64_url_decode_nopad(A3_D)
        return JwsSigner.es256(SecretValue(Span(d)))
    if alg == "EdDSA":
        var s = base64_url_decode_nopad(SEED)
        return JwsSigner.eddsa(SecretValue(Span(s)))
    var der = rsa_pkcs8_der_from_pem(Path(RSA_PEM).read_text())
    return JwsSigner.rs256(SecretValue(Span(der)))


def _verifier(alg: String) raises -> JwsVerifier:
    var keys = List[Jwk]()
    keys.append(_signer(alg).public_jwk())
    return JwsVerifier(alg, parse_jwk_set(render_jwk_set(keys)))


def _source(
    var t: Scripted, alg: String = "ES256", scope: String = ""
) raises -> ClientCredentialSource[Scripted]:
    return ClientCredentialSource[Scripted](
        t^,
        _signer(alg),
        client_id=CLIENT,
        token_endpoint=ENDPOINT,
        assertion_audience=AUD,
        resource=RESOURCE,
        scope=scope,
    )


def _fetch(
    mut t: Scripted,
    alg: String = "ES256",
    client_id: String = CLIENT,
    token_endpoint: String = ENDPOINT,
    audience: String = AUD,
    resource: String = RESOURCE,
    scope: String = "",
) raises -> String:
    var r = fetch_client_credentials_token(
        t,
        _signer(alg),
        client_id=client_id,
        token_endpoint=token_endpoint,
        assertion_audience=audience,
        resource=resource,
        scope=scope,
        now=NOW,
    )
    return r.access_token.copy()


def _fetch_refusal(
    mut t: Scripted,
    alg: String = "ES256",
    client_id: String = CLIENT,
    token_endpoint: String = ENDPOINT,
    audience: String = AUD,
    resource: String = RESOURCE,
    scope: String = "",
) -> String:
    try:
        _ = _fetch(t, alg, client_id, token_endpoint, audience, resource, scope)
    except e:
        return String(e)
    return String("accepted")


def _token_at(mut s: ClientCredentialSource[Scripted], now: Int64) -> String:
    try:
        return s.access_token(now)
    except e:
        return String("raised: ") + String(e)


def test_request_on_the_wire() raises:
    for alg in ["ES256", "EdDSA"]:
        var t = Scripted()
        t.token("tok-1", 300)
        t.token("tok-2", 300)
        assert_equal(_fetch(t, alg, scope="read write"), "tok-1")
        assert_equal(_fetch(t, alg), "tok-2")
        assert_equal(len(t.urls), 2)
        assert_equal(t.urls[0], ENDPOINT)
        var jtis = List[String]()
        for i in range(2):
            var p = parse_client_credentials_request(t.forms[i])
            assert_true(p.ok(), p.reason)
            var assertion = p.request.client_assertion.copy()
            var tail = String("&resource=https%3A%2F%2Fpdp.example%2Fv1")
            if i == 0:
                tail += "&scope=read%20write"
            assert_equal(
                t.forms[i],
                String("grant_type=client_credentials")
                + "&client_assertion_type=urn%3Aietf%3Aparams%3Aoauth%3Aclient-assertion-type%3Ajwt-bearer"
                + "&client_assertion="
                + assertion
                + tail,
            )
            var policy = ClaimPolicy(
                issuer=CLIENT,
                audience=AUD,
                accept_typ="JWT",
                now=NOW,
                leeway_s=0,
                max_ttl_s=OAUTH_ASSERTION_TTL_S,
            )
            var a = verify_client_assertion(assertion, _verifier(String(alg)), policy)
            assert_equal(a.jwt.issuer, CLIENT)
            assert_equal(a.jwt.subject, CLIENT)
            assert_equal(a.jwt.iat, NOW)
            assert_equal(a.jwt.exp, NOW + 60)
            assert_equal(a.jti.byte_length(), 22, "16 bytes, base64url")
            jtis.append(a.jti.copy())
        assert_true(jtis[0] != jtis[1], "a fresh jti per request")


def test_answer_read() raises:
    var t = Scripted()
    t.answer(200, render_token_response("abc.def.ghi", 120, "read"))
    var r = fetch_client_credentials_token(
        t,
        _signer("ES256"),
        client_id=CLIENT,
        token_endpoint=ENDPOINT,
        assertion_audience=AUD,
        resource=RESOURCE,
        scope="read",
        now=NOW,
    )
    assert_equal(r.access_token, "abc.def.ghi")
    assert_equal(r.expires_in, 120)
    assert_equal(r.scope, "read")


def test_failures() raises:
    var t = Scripted()
    t.down()
    var down = _fetch_refusal(t)
    assert_equal(down, "OAuthError: the token request failed")
    assert_false("client_assertion" in down, "the transport's text is dropped")
    t.answer(400, String('{"error":"invalid_client","error_description":"secret-xyz"}'))
    var refused = _fetch_refusal(t)
    assert_equal(refused, "OAuthError: the token endpoint answered 400 invalid_client")
    t.answer(401, render_oauth_error("not-a-code"))
    assert_equal(_fetch_refusal(t), "OAuthError: the token endpoint answered 401 not a known code")
    t.answer(500, "secret-xyz")
    assert_equal(_fetch_refusal(t), "OAuthError: the token endpoint answered 500")
    # A token in a body with any status but 200 is not an answer.
    for status in [199, 201, 204, 299, 302]:
        t.answer(status, render_token_response("tok", 300, ""))
        assert_equal(
            _fetch_refusal(t),
            String("OAuthError: the token endpoint answered ") + String(status),
        )
    t.answer(200, '{"token_type":"Bearer","expires_in":300}')
    assert_equal(_fetch_refusal(t), "OAuthError: member access_token is missing")
    t.answer(200, "secret-xyz")
    assert_equal(_fetch_refusal(t), "OAuthError: the token response is not JSON")
    assert_equal(len(t.replies), 0, "every answer was asked for")


def test_argument_refusals() raises:
    var t = Scripted()
    assert_equal(_fetch_refusal(t, client_id=""), "OAuthError: the client_id is empty")
    assert_equal(_fetch_refusal(t, token_endpoint="http://issuer.example/a/token"), "OAuthError: the token endpoint is not an https URL")
    assert_equal(_fetch_refusal(t, token_endpoint="https:///token"), "OAuthError: the token endpoint has no host")
    assert_equal(_fetch_refusal(t, token_endpoint="https://issuer.example/t#f"), "OAuthError: the token endpoint has a fragment")
    assert_equal(_fetch_refusal(t, audience=""), "OAuthError: the assertion audience is empty")
    assert_equal(_fetch_refusal(t, resource=""), "OAuthError: the resource is empty")
    assert_equal(_fetch_refusal(t, scope="a  b"), "OAuthError: the scope is not a scope")
    assert_equal(_fetch_refusal(t, scope=" a"), "OAuthError: the scope is not a scope")
    assert_equal(_fetch_refusal(t, alg="RS256"), "OAuthError: the client key must sign ES256 or EdDSA")
    assert_equal(len(t.forms), 0, "nothing was sent")
    # One-byte values and a query on the endpoint are accepted.
    t.token("tok", 300)
    assert_equal(
        _fetch(t, client_id="c", token_endpoint="https://issuer.example/t?x=1", audience="a", resource="r", scope="s"),
        "tok",
    )
    assert_equal(t.urls[0], "https://issuer.example/t?x=1")
    # The source refuses the same arguments.
    var msg = String("")
    try:
        _ = ClientCredentialSource[Scripted](
            Scripted(), _signer("ES256"), client_id="", token_endpoint=ENDPOINT,
            assertion_audience=AUD, resource=RESOURCE, scope="",
        )
    except e:
        msg = String(e)
    assert_equal(msg, "OAuthError: the client_id is empty")
    msg = String("")
    try:
        _ = ClientCredentialSource[Scripted](
            Scripted(), _signer("RS256"), client_id=CLIENT, token_endpoint=ENDPOINT,
            assertion_audience=AUD, resource=RESOURCE, scope="",
        )
    except e:
        msg = String(e)
    assert_equal(msg, "OAuthError: the client key must sign ES256 or EdDSA")


def test_source_refresh() raises:
    var t = Scripted()
    t.token("A", 300)
    t.token("B", 300)
    t.token("C", 120)
    t.token("D", 60)
    t.token("E", 60)
    t.token("F", 61)
    var s = _source(t^)
    assert_equal(len(s.transport().forms), 0, "nothing before first use")
    assert_equal(s.access_token(NOW), "A")
    assert_equal(len(s.transport().forms), 1)
    assert_equal(s.access_token(NOW), "A")
    assert_equal(s.access_token(NOW + 300 - OAUTH_REFRESH_SKEW_S - 1), "A")
    assert_equal(len(s.transport().forms), 1, "held until exp - 60")
    var t1 = NOW + 300 - OAUTH_REFRESH_SKEW_S
    assert_equal(s.access_token(t1), "B")
    assert_equal(len(s.transport().forms), 2, "fetched at exp - 60")
    # B's expiry counts from its own request.
    assert_equal(s.access_token(t1 + 239), "B")
    assert_equal(s.access_token(t1 + 240), "C")
    var t2 = t1 + 240
    assert_equal(s.access_token(t2 + 59), "C")
    assert_equal(s.access_token(t2 + 60), "D")
    # A 60 s token is fetched for every call.
    assert_equal(s.access_token(t2 + 60), "E")
    assert_equal(s.access_token(t2 + 60), "F")
    # A 61 s token is held for its first second.
    assert_equal(s.access_token(t2 + 60), "F")
    assert_equal(len(s.transport().forms), 6)
    var policy = ClaimPolicy(
        issuer=CLIENT, audience=AUD, accept_typ="JWT", now=t1,
        leeway_s=0, max_ttl_s=OAUTH_ASSERTION_TTL_S,
    )
    var p = parse_client_credentials_request(s.transport().forms[1])
    var a = verify_client_assertion(p.request.client_assertion, _verifier("ES256"), policy)
    assert_equal(a.jwt.iat, t1, "the refresh asserts at its own time")


def test_failed_refresh_never_serves_stale() raises:
    var t = Scripted()
    t.token("A", 300)
    t.down()
    t.answer(503, "")
    t.token("C", 300)
    t.down()
    t.token("D", 300)
    var s = _source(t^)
    assert_equal(s.access_token(NOW), "A")
    var due = NOW + 300 - OAUTH_REFRESH_SKEW_S
    # A is unexpired until NOW + 300, but the refresh failed: raise.
    assert_equal(_token_at(s, due), "raised: OAuthError: the token request failed")
    assert_equal(_token_at(s, due + 1), "raised: OAuthError: the token endpoint answered 503")
    assert_equal(_token_at(s, due + 2), "C")
    assert_equal(len(s.transport().forms), 4)
    # After a failure the source holds nothing, so even a time before the
    # refresh point fetches instead of serving the former token.
    var due_c = due + 2 + 300 - OAUTH_REFRESH_SKEW_S
    assert_equal(_token_at(s, due_c), "raised: OAuthError: the token request failed")
    assert_equal(_token_at(s, due + 3), "D")
    assert_equal(len(s.transport().forms), 6)
    # Past the former token's exp, a failure still raises.
    var t2 = Scripted()
    t2.token("A", 300)
    t2.down()
    var s2 = _source(t2^)
    assert_equal(s2.access_token(NOW), "A")
    assert_equal(_token_at(s2, NOW + 300), "raised: OAuthError: the token request failed")


def test_time_bounds() raises:
    var t = Scripted()
    t.token("late", 86400)
    var s = _source(t^)
    assert_equal(_token_at(s, -1), "raised: OAuthError: the time is negative")
    assert_equal(
        _token_at(s, Int64.MAX - 86400 + 1),
        "raised: OAuthError: the time is too late for a token expiry",
    )
    assert_equal(len(s.transport().forms), 0)
    assert_equal(_token_at(s, Int64.MAX - 86400), "late")
    assert_equal(_token_at(s, Int64.MAX - 86400), "late")
    assert_equal(len(s.transport().forms), 1)
    var t0 = Scripted()
    t0.token("zero", 300)
    var s0 = _source(t0^)
    assert_equal(_token_at(s0, 0), "zero")


def main() raises:
    var failures = String("")
    try:
        test_request_on_the_wire()
    except e:
        failures += String("test_request_on_the_wire: ") + String(e) + "\n"
    try:
        test_answer_read()
    except e:
        failures += String("test_answer_read: ") + String(e) + "\n"
    try:
        test_failures()
    except e:
        failures += String("test_failures: ") + String(e) + "\n"
    try:
        test_argument_refusals()
    except e:
        failures += String("test_argument_refusals: ") + String(e) + "\n"
    try:
        test_source_refresh()
    except e:
        failures += String("test_source_refresh: ") + String(e) + "\n"
    try:
        test_failed_refresh_never_serves_stale()
    except e:
        failures += String("test_failed_refresh_never_serves_stale: ") + String(e) + "\n"
    try:
        test_time_bounds()
    except e:
        failures += String("test_time_bounds: ") + String(e) + "\n"
    if failures != "":
        print(failures)
        raise Error("test_client failed")
    print("PASS komira_oauth test_client")
