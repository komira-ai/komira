# =============================================================================
# test_client_roundtrip.mojo: komira_oauth's `ClientCredentialSource` against
#   the test issuer's token endpoint, in process (`IssuerTokenTransport`).
# =============================================================================
#
# What each test proves:
# - test_source_gets_verifiable_tokens: the token the source serves verifies
#   under the issuer's JWK Set as an access token for the resource, with
#   `sub` and `client_id` the client; it is served until 60 s before it
#   expires and a new one (a new jti) is fetched from then on; a key
#   rotation between fetches is followed (the new token names the new kid).
#   A client that sends an assertion without a jti, or the same jti twice,
#   gets no token: this is the end-to-end form of the two defects the
#   komira_oauth tests and test_token_endpoint pin.
# - test_failed_refresh_raises: a refresh over a failing connection raises,
#   and the former, unexpired token is not served; once the connection is
#   back a new token is.
# - test_removed_client_gets_no_token: deleting the client's record makes the
#   next refresh raise with the endpoint's invalid_client; nothing is served.
# - test_wrong_endpoint: a source pointed at another URL of the issuer gets
#   the transport's 404.
#
# main runs every test and reports every failure.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_jose import ClaimPolicy, JwsVerifier, verify_jwt
from komira_jwks import Jwk, parse_jwk_set, render_jwk_set
from komira_oauth import ClientCredentialSource, ClientMetadata
from komira_test_issuer import IssuerTokenTransport, TestIssuer, derived_key


comptime ISS = "https://issuer.example/a"
comptime RESOURCE = "https://pdp.example/v1"
comptime CLIENT = "client-1"
comptime NOW: Int64 = 1000000


def _transport() raises -> IssuerTokenTransport:
    var i = TestIssuer(
        issuer=ISS,
        alg="ES256",
        typ="at+jwt",
        max_ttl_s=300,
        leeway_s=30,
        publish_lead_s=60,
        seed="issuer-seed",
        now=NOW,
    )
    var keys = List[Jwk]()
    keys.append(derived_key("EdDSA", "client seed", 0).public_jwk())
    var record = ClientMetadata.with_jwks(
        client_id=CLIENT,
        client_name="",
        signing_alg="EdDSA",
        scope="read",
        jwks=parse_jwk_set(render_jwk_set(keys)),
        resource_types=List[String](),
    )
    var resources = List[String]()
    resources.append(RESOURCE)
    i.register_client(record, resources)
    return IssuerTokenTransport(i^)


def _source(
    var t: IssuerTokenTransport, endpoint: String = ISS + "/token"
) raises -> ClientCredentialSource[IssuerTokenTransport]:
    return ClientCredentialSource[IssuerTokenTransport](
        t^,
        derived_key("EdDSA", "client seed", 0),
        client_id=CLIENT,
        token_endpoint=endpoint,
        assertion_audience=ISS,
        resource=RESOURCE,
        scope="",
    )


def _check(mut s: ClientCredentialSource[IssuerTokenTransport], token: String) raises -> String:
    """Verify `token` as the resource would; return its jti."""
    ref issuer = s.transport().issuer
    var verifier = JwsVerifier("ES256", parse_jwk_set(issuer.jwks()))
    var policy = ClaimPolicy(
        issuer=ISS, audience=RESOURCE, accept_typ="at+jwt", now=issuer.now(),
        leeway_s=30, max_ttl_s=300,
    )
    var jwt = verify_jwt(token, verifier, policy)
    assert_equal(jwt.subject, CLIENT)
    assert_equal(jwt.claims.get("client_id").as_string(), CLIENT)
    assert_equal(jwt.claims.get("scope").as_string(), "read")
    assert_equal(jwt.kid, issuer.signing_kid())
    return jwt.claims.get("jti").as_string()


def _advance(mut s: ClientCredentialSource[IssuerTokenTransport], seconds: Int64) raises -> Int64:
    s.transport().issuer.advance(seconds)
    return s.transport().issuer.now()


def _token_at(mut s: ClientCredentialSource[IssuerTokenTransport], now: Int64) -> String:
    try:
        return s.access_token(now)
    except e:
        return String("raised: ") + String(e)


def test_source_gets_verifiable_tokens() raises:
    var s = _source(_transport())
    var first = s.access_token(NOW)
    var jti1 = _check(s, first)
    assert_equal(s.transport().posts, 1)
    var t = _advance(s, 239)
    assert_equal(s.access_token(t), first)
    assert_equal(s.transport().posts, 1, "held until exp - 60")
    # Rotate the issuer's key before the refresh is due.
    s.transport().issuer.begin_rotation()
    _ = s.transport().issuer.jwks()
    t = _advance(s, 1)
    var second = s.access_token(t)
    assert_equal(s.transport().posts, 2, "fetched at exp - 60")
    assert_true(second != first)
    var jti2 = _check(s, second)
    assert_true(jti1 != jti2)
    t = _advance(s, 60)
    s.transport().issuer.finish_rotation()
    t = _advance(s, 240)
    var third = s.access_token(t)
    assert_equal(s.transport().posts, 3)
    _ = _check(s, third)


def test_failed_refresh_raises() raises:
    var s = _source(_transport())
    var first = s.access_token(NOW)
    var t = _advance(s, 240)
    s.transport().down = True
    assert_equal(_token_at(s, t), "raised: OAuthError: the token request failed")
    t = _advance(s, 1)
    assert_equal(_token_at(s, t), "raised: OAuthError: the token request failed")
    s.transport().down = False
    t = _advance(s, 1)
    var fresh = _token_at(s, t)
    assert_true(fresh != first, "a new token, not the former one")
    _ = _check(s, fresh)
    assert_equal(s.transport().posts, 4)


def test_removed_client_gets_no_token() raises:
    var s = _source(_transport())
    _ = s.access_token(NOW)
    s.transport().issuer.remove_client(CLIENT)
    var t = _advance(s, 240)
    assert_equal(
        _token_at(s, t),
        "raised: OAuthError: the token endpoint answered 401 invalid_client",
    )
    assert_equal(
        _token_at(s, t + 1),
        "raised: OAuthError: the token endpoint answered 401 invalid_client",
    )


def test_wrong_endpoint() raises:
    var s = _source(_transport(), ISS + "/tokens")
    assert_equal(_token_at(s, NOW), "raised: OAuthError: the token endpoint answered 404")
    var s2 = _source(_transport(), "https://issuer.example/token")
    assert_equal(_token_at(s2, NOW), "raised: OAuthError: the token endpoint answered 404")


def main() raises:
    var failures = String("")
    try:
        test_source_gets_verifiable_tokens()
    except e:
        failures += String("test_source_gets_verifiable_tokens: ") + String(e) + "\n"
    try:
        test_failed_refresh_raises()
    except e:
        failures += String("test_failed_refresh_raises: ") + String(e) + "\n"
    try:
        test_removed_client_gets_no_token()
    except e:
        failures += String("test_removed_client_gets_no_token: ") + String(e) + "\n"
    try:
        test_wrong_endpoint()
    except e:
        failures += String("test_wrong_endpoint: ") + String(e) + "\n"
    if failures != "":
        print(failures)
        raise Error("test_client_roundtrip failed")
    print("PASS komira_test_issuer test_client_roundtrip")
