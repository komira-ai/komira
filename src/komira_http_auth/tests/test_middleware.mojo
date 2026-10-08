# =============================================================================
# test_middleware.mojo: BearerJwtMiddleware's 401s and principal replacement.
# =============================================================================
#
# invalid_request for a missing or malformed Authorization header (including
# two comma-folded headers), invalid_token for every verification failure,
# the RFC 6750 WWW-Authenticate values, no token text in any response, and
# ctx.principal REPLACED on success and cleared on every refusal.
# =============================================================================

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_crypto import rsa_pkcs8_der_from_pem
from komira_http_auth import (
    BearerJwtConfig,
    FixedAuthClock,
    Rs256JwksVerifier,
    ScriptedJwksFetcher,
    TrustAnchor,
    VerifyOutcome,
)
from komira_http_auth.reasons import (
    REASON_ALG,
    REASON_AUD,
    REASON_CRIT,
    REASON_DUPLICATE_KEY,
    REASON_EXP,
    REASON_EXPIRED,
    REASON_HEADER_JSON,
    REASON_IAT,
    REASON_ISS,
    REASON_KEY_IN_HEADER,
    REASON_KID,
    REASON_MALFORMED_HEADER,
    REASON_MALFORMED_TOKEN,
    REASON_MISSING_HEADER,
    REASON_NBF,
    REASON_OK,
    REASON_PAYLOAD_JSON,
    REASON_SIGNATURE,
    REASON_SUB,
    REASON_TTL,
    REASON_TYP,
    REASON_UNKNOWN_KID,
)
from komira_http_auth.testing import (
    rsa_jwk_json,
    rsa_jwks_json,
    sign_rs256_compact,
)


comptime ISSUER = "https://accounts.google.com"
comptime AUDIENCE = "https://api.example.com/"
comptime JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs"
comptime KID = "test-key-1"
comptime NOW: Int64 = 1800000000

comptime Verifier = Rs256JwksVerifier[ScriptedJwksFetcher, FixedAuthClock]


def _key() raises -> List[UInt8]:
    """The repository's RSA-2048 PKCS#8 test key (komira_http_core's TLS
    fixture), declared as this test's data in the BUCK file."""
    return rsa_pkcs8_der_from_pem(
        Path("src/komira_http_core/tests/fixtures/tls/leaf_key.pem").read_text()
    )


def _config() -> BearerJwtConfig:
    return BearerJwtConfig(
        TrustAnchor.rs256(String("test"), ISSUER, AUDIENCE, JWKS_URL)
    )


def _header(kid: String) -> String:
    return String('{"alg":"RS256","typ":"JWT","kid":"') + kid + String('"}')


def _claims(iat: Int64, exp: Int64) -> String:
    return (
        String('{"iss":"')
        + ISSUER
        + String('","aud":"')
        + AUDIENCE
        + String('","sub":"svc-1","iat":')
        + String(iat)
        + String(',"exp":')
        + String(exp)
        + String("}")
    )


struct _Rig(Movable):
    """A verifier over a scripted JWKS fetcher and a fixed clock, with
    handles on both kept by the test."""

    var fetcher: ScriptedJwksFetcher
    var clock: FixedAuthClock
    var verifier: Verifier

    def __init__(out self, var cfg: BearerJwtConfig) raises:
        var f = ScriptedJwksFetcher()
        var c = FixedAuthClock(NOW)
        var v = Verifier(cfg, f.share(), c.share())
        self.fetcher = f^
        self.clock = c^
        self.verifier = v^


from komira_http_core.codec.types import HttpMethod, HttpRequest, HttpResponse
from komira_http_server.middleware import Principal, RequestContext
from komira_http_auth import (
    BearerJwtMiddleware,
    WWW_AUTHENTICATE_INVALID_REQUEST,
    WWW_AUTHENTICATE_INVALID_TOKEN,
)


comptime Mw = BearerJwtMiddleware[Verifier]


struct _MwRig(Movable):
    var fetcher: ScriptedJwksFetcher
    var mw: Mw

    def __init__(out self, key: List[UInt8]) raises:
        var f = ScriptedJwksFetcher()
        f.add(200, String("max-age=3600"), rsa_jwks_json(key, KID))
        var v = Verifier(
            _config().with_copy_claim(String("email")),
            f.share(),
            FixedAuthClock(NOW),
        )
        self.fetcher = f^
        self.mw = Mw(v^)


def _req(authorization: Optional[String]) -> HttpRequest:
    var req = HttpRequest()
    req.method = HttpMethod.get()
    req.path = String("/v1/things")
    if authorization:
        req.headers[String("authorization")] = authorization.value()
    return req^


def _text(ref resp: HttpResponse) -> String:
    return String(unsafe_from_utf8=Span(resp.body))


def _preset_principal() raises -> Optional[Principal]:
    """What an earlier layer (or a forged path) may have left on the context."""
    return Optional[Principal](
        Principal(scheme=String("session"), subject=String("someone-else"))
        .with_claim(String("role"), String("admin"))
        .with_claim(String("email"), String("forged@example.com"))
    )


def _good_token(key: List[UInt8]) raises -> String:
    return sign_rs256_compact(
        _header(KID),
        String('{"iss":"')
        + ISSUER
        + String('","aud":"')
        + AUDIENCE
        + String('","sub":"svc-1","email":"svc@example.com","iat":')
        + String(NOW)
        + String(',"exp":')
        + String(NOW + 600)
        + String("}"),
        key,
    )


def _assert_401(
    ref resp: HttpResponse, www_authenticate: String, what: String
) raises:
    assert_equal(Int(resp.status), 401, what)
    assert_equal(resp.headers[String("www-authenticate")], www_authenticate, what)
    assert_equal(_text(resp), String("unauthorized\n"), what)
    assert_equal(
        resp.headers[String("content-length")], String(len(resp.body)), what
    )


def _assert_no_echo(ref resp: HttpResponse, secret: String) raises:
    """Neither the body nor any header value holds `secret` or any of its
    dot-separated parts."""
    var parts = secret.split(".")
    var hay = _text(resp)
    for e in resp.headers.items():
        hay += String("\n") + e.key + String(": ") + e.value
    assert_false(secret in hay, "token echoed")
    for i in range(len(parts)):
        var p = String(parts[i])
        if p.byte_length() >= 8:
            assert_false(p in hay, "token segment echoed")


# =============================================================================
# RFC 6750 header shapes.
# =============================================================================


def test_header_values_are_the_rfc6750_shapes() raises:
    assert_equal(
        String(WWW_AUTHENTICATE_INVALID_REQUEST),
        String('Bearer error="invalid_request"'),
    )
    assert_equal(
        String(WWW_AUTHENTICATE_INVALID_TOKEN),
        String('Bearer error="invalid_token"'),
    )


def test_missing_authorization_is_invalid_request() raises:
    var rig = _MwRig(_key())
    var req = _req(Optional[String]())
    var ctx = RequestContext.new()
    ctx.principal = _preset_principal()
    var r = rig.mw.before(req, ctx)
    assert_true(Bool(r))
    _assert_401(r.value(), WWW_AUTHENTICATE_INVALID_REQUEST, "missing")
    assert_equal(rig.mw.last_reason(), String(REASON_MISSING_HEADER))
    assert_false(Bool(ctx.principal), "a refused request carries no principal")
    assert_equal(rig.fetcher.fetch_count(), 0)


def test_malformed_authorization_is_invalid_request() raises:
    var key = _key()
    var good = _good_token(key)
    var cases = List[String]()
    cases.append(String("Basic dXNlcjpwYXNz"))
    cases.append(String("Bearer"))
    cases.append(String("Bearer "))
    cases.append(String("Bearer  ") + good)  # two spaces
    cases.append(String("Bearer ") + good + String(" "))
    cases.append(String("Bearer\t") + good)
    cases.append(String("Token ") + good)
    # Two Authorization headers, comma-folded by the HTTP/1 parser.
    cases.append(String("Bearer ") + good + String(", Bearer ") + good)
    cases.append(String("Bearer ") + good + String(",") + good)
    cases.append(String("Bearer a=b"))
    for i in range(len(cases)):
        var rig = _MwRig(key)
        var req = _req(Optional[String](cases[i]))
        var ctx = RequestContext.new()
        ctx.principal = _preset_principal()
        var r = rig.mw.before(req, ctx)
        assert_true(Bool(r), "case " + String(i))
        _assert_401(r.value(), WWW_AUTHENTICATE_INVALID_REQUEST, "case " + String(i))
        _assert_no_echo(r.value(), good)
        assert_equal(rig.mw.last_reason(), String(REASON_MALFORMED_HEADER))
        assert_false(Bool(ctx.principal))
        assert_equal(rig.fetcher.fetch_count(), 0)


def test_bad_token_is_invalid_token_and_not_echoed() raises:
    var key = _key()
    var good = _good_token(key)
    # The same token with one character inside its signature changed (not
    # the last, whose low bits are padding).
    var at = good.byte_length() - 10
    var was = String(good[byte=at : at + 1])
    var flipped = (
        String(good[byte=0:at])
        + (String("A") if was != String("A") else String("B"))
        + String(good[byte = at + 1 : good.byte_length()])
    )
    var cases = List[String]()
    cases.append(flipped)
    cases.append(String("not-a-jwt-at-all"))
    cases.append(String("aaaa.bbbb.cccc"))
    for i in range(len(cases)):
        var rig = _MwRig(key)
        var req = _req(Optional[String](String("Bearer ") + cases[i]))
        var ctx = RequestContext.new()
        ctx.principal = _preset_principal()
        var r = rig.mw.before(req, ctx)
        assert_true(Bool(r), "case " + String(i))
        _assert_401(r.value(), WWW_AUTHENTICATE_INVALID_TOKEN, "case " + String(i))
        _assert_no_echo(r.value(), cases[i])
        assert_false(Bool(ctx.principal), "case " + String(i))
        assert_true(rig.mw.last_reason() != String(REASON_OK))
        assert_false(cases[i] in rig.mw.last_reason())


def test_valid_token_replaces_a_preset_principal() raises:
    var key = _key()
    var rig = _MwRig(key)
    var tok = _good_token(key)
    var req = _req(Optional[String](String("Bearer ") + tok))
    var ctx = RequestContext.new()
    ctx.principal = _preset_principal()
    var r = rig.mw.before(req, ctx)
    assert_false(Bool(r), "the request goes on")
    assert_equal(rig.mw.last_reason(), String(REASON_OK))
    assert_true(Bool(ctx.principal))
    ref p = ctx.principal.value()
    assert_equal(p.scheme, String("jwt"))
    assert_equal(p.subject, String("svc-1"))
    # REPLACED, not merged: nothing of the preset principal survives.
    assert_false(p.claims.has(String("role")), "preset claim leaked")
    assert_equal(p.claims.get(String("email")).value(), String("svc@example.com"))
    assert_equal(p.claims.len(), 3)  # iss, aud, email
    assert_equal(p.claims.get(String("iss")).value(), String(ISSUER))
    assert_equal(p.claims.get(String("aud")).value(), String(AUDIENCE))


def test_scheme_name_is_case_insensitive() raises:
    var key = _key()
    var rig = _MwRig(key)
    var req = _req(Optional[String](String("bearer ") + _good_token(key)))
    var ctx = RequestContext.new()
    var r = rig.mw.before(req, ctx)
    assert_false(Bool(r))
    assert_true(Bool(ctx.principal))


def test_a_refusal_after_a_success_clears_the_principal() raises:
    var key = _key()
    var rig = _MwRig(key)
    var ctx = RequestContext.new()
    var ok_req = _req(Optional[String](String("Bearer ") + _good_token(key)))
    _ = rig.mw.before(ok_req, ctx)
    assert_true(Bool(ctx.principal))
    var bad_req = _req(Optional[String](String("Bearer aaaa.bbbb.cccc")))
    var r = rig.mw.before(bad_req, ctx)
    assert_true(Bool(r))
    assert_false(Bool(ctx.principal))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
