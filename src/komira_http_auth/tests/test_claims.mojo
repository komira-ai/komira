# =============================================================================
# test_claims.mojo: claim checks and the principal of a valid token.
# =============================================================================
#
# The positive case (a valid RS256 token yields Principal{scheme jwt, sub,
# iss, aud, copied claims, presented credential}) and every claim refusal:
# iss, aud (missing, other, array without ours), sub, exp (missing, not an
# integer, expired past the 30 s leeway), iat, nbf, lifetime over max TTL,
# duplicate payload keys, and a spliced payload failing the signature.
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


# =============================================================================
# Every token is signed with the test key under an honest header, so it
# passes the header gate, the key lookup and the signature; what refuses it
# is the claim under test, named by its reason code.
# =============================================================================


def _payload(body: String) -> String:
    """A payload object whose members are `body` (JSON members text)."""
    return String("{") + body + String("}")


def _std(extra: String) -> String:
    """iss, aud, sub, iat=NOW, exp=NOW+600, then `extra` members."""
    var s = (
        String('"iss":"')
        + ISSUER
        + String('","aud":"')
        + AUDIENCE
        + String('","sub":"svc-1","iat":')
        + String(NOW)
        + String(',"exp":')
        + String(NOW + 600)
    )
    if extra.byte_length() > 0:
        s += String(",") + extra
    return _payload(s)


def _verify(payload_json: String) raises -> VerifyOutcome:
    var key = _key()
    var rig = _Rig(_config().with_copy_claim(String("email")).with_copy_claim(
        String("email_verified")
    ).with_copy_claim(String("name")).with_copy_claim(String("absent")))
    rig.fetcher.add(200, rsa_jwks_json(key, KID))
    var tok = sign_rs256_compact(_header(KID), payload_json, key)
    return rig.verifier.verify(tok)


def _expect(payload_json: String, want: String) raises:
    var out = _verify(payload_json)
    assert_equal(out.reason, want, payload_json)
    assert_equal(out.ok(), want == String(REASON_OK), payload_json)


def test_valid_token_yields_the_jwt_principal() raises:
    var key = _key()
    var rig = _Rig(
        _config()
        .with_copy_claim(String("email"))
        .with_copy_claim(String("email_verified"))
        .with_copy_claim(String("name"))
        .with_copy_claim(String("absent"))
    )
    rig.fetcher.add(200, rsa_jwks_json(key, KID))
    var tok = sign_rs256_compact(
        _header(KID),
        _std(
            String(
                '"email":"svc@example.com",'
                '"email_verified":true,"name":"Zoë"'
            )
        ),
        key,
    )
    var out = rig.verifier.verify(tok)
    assert_equal(out.reason, String(REASON_OK))
    assert_true(out.ok())
    var p = out.principal.value().copy()
    assert_equal(p.scheme, String("jwt"))
    assert_equal(p.subject, String("svc-1"))
    assert_equal(p.claims.get(String("iss")).value(), String(ISSUER))
    assert_equal(p.claims.get(String("aud")).value(), String(AUDIENCE))
    assert_equal(
        p.claims.get(String("email")).value(),
        String("svc@example.com"),
    )
    # A non-string claim is copied as its JSON text.
    assert_equal(p.claims.get(String("email_verified")).value(), String("true"))
    # Non-ASCII survives (komira_crypto's returned payload String would have
    # double-encoded it; the claims are read from the re-decoded segment).
    assert_equal(p.claims.get(String("name")).value(), String("Zoë"))
    # A copy-claim the token lacks is not set; claims not asked for are not
    # copied.
    assert_false(p.claims.has(String("absent")))
    assert_false(p.claims.has(String("exp")))
    assert_equal(p.claims.len(), 5)
    # The token rides along redacted.
    assert_true(Bool(p.presented))
    assert_equal(p.presented.value().expose(), tok)
    assert_false(tok in p.presented.value().redacted())


def test_wrong_issuer_is_refused() raises:
    var s = _std(String(""))
    _expect(
        s.replace(String(ISSUER), String("https://accounts.google.com/")),
        REASON_ISS,
    )
    _expect(
        s.replace(String(ISSUER), String("accounts.google.com")), REASON_ISS
    )


def test_missing_issuer_is_refused() raises:
    _expect(
        _payload(
            String('"aud":"')
            + AUDIENCE
            + String('","sub":"s","iat":')
            + String(NOW)
            + String(',"exp":')
            + String(NOW + 60)
        ),
        REASON_ISS,
    )


def _with_aud(aud_json: String) -> String:
    return _payload(
        String('"iss":"')
        + ISSUER
        + String('",')
        + aud_json
        + String('"sub":"svc-1","iat":')
        + String(NOW)
        + String(',"exp":')
        + String(NOW + 600)
    )


def test_audience_missing_is_refused() raises:
    _expect(_with_aud(String("")), REASON_AUD)


def test_other_audience_is_refused() raises:
    _expect(_with_aud(String('"aud":"https://other.example.com/",')), REASON_AUD)
    # A prefix of ours is not ours.
    _expect(_with_aud(String('"aud":"https://api.example.com",')), REASON_AUD)


def test_audience_array_without_ours_is_refused() raises:
    _expect(
        _with_aud(String('"aud":["https://a.example/","https://b.example/"],')),
        REASON_AUD,
    )
    _expect(_with_aud(String('"aud":[],')), REASON_AUD)
    _expect(
        _with_aud(String('"aud":["https://api.example.com/",7],')), REASON_AUD
    )
    _expect(_with_aud(String('"aud":{"x":"https://api.example.com/"},')), REASON_AUD)


def test_audience_array_with_ours_is_accepted() raises:
    _expect(
        _with_aud(
            String('"aud":["https://a.example/","https://api.example.com/"],')
        ),
        REASON_OK,
    )


def _with_sub(sub_json: String) -> String:
    return _payload(
        String('"iss":"')
        + ISSUER
        + String('","aud":"')
        + AUDIENCE
        + String('",')
        + sub_json
        + String('"iat":')
        + String(NOW)
        + String(',"exp":')
        + String(NOW + 600)
    )


def test_empty_or_missing_sub_is_refused() raises:
    _expect(_with_sub(String('"sub":"",')), REASON_SUB)
    _expect(_with_sub(String("")), REASON_SUB)
    _expect(_with_sub(String('"sub":12,')), REASON_SUB)


def _timed(times_json: String) -> String:
    return _payload(
        String('"iss":"')
        + ISSUER
        + String('","aud":"')
        + AUDIENCE
        + String('","sub":"svc-1"')
        + times_json
    )


def test_missing_or_non_integer_exp_is_refused() raises:
    _expect(_timed(String(',"iat":') + String(NOW)), REASON_EXP)
    _expect(
        _timed(String(',"iat":') + String(NOW) + String(',"exp":"1800000600"')),
        REASON_EXP,
    )
    _expect(
        _timed(String(',"iat":') + String(NOW) + String(',"exp":1800000600.5')),
        REASON_EXP,
    )
    _expect(
        _timed(String(',"iat":') + String(NOW) + String(',"exp":1.8e9')),
        REASON_EXP,
    )


def _iat_exp(iat: Int64, exp: Int64) -> String:
    return _timed(
        String(',"iat":') + String(iat) + String(',"exp":') + String(exp)
    )


def test_expired_past_leeway_is_refused_and_inside_leeway_accepted() raises:
    # Leeway is 30 s: refused at or after exp + 30.
    _expect(_iat_exp(NOW - 600, NOW - 30), REASON_EXPIRED)
    _expect(_iat_exp(NOW - 600, NOW - 31), REASON_EXPIRED)
    _expect(_iat_exp(NOW - 600, NOW - 29), REASON_OK)


def test_nbf_in_the_future_is_refused() raises:
    var base = String(',"iat":') + String(NOW) + String(',"exp":') + String(
        NOW + 600
    )
    _expect(_timed(base + String(',"nbf":') + String(NOW + 31)), REASON_NBF)
    _expect(_timed(base + String(',"nbf":') + String(NOW + 29)), REASON_OK)
    _expect(_timed(base + String(',"nbf":"soon"')), REASON_NBF)


def test_iat_missing_or_in_the_future_is_refused() raises:
    _expect(_timed(String(',"exp":') + String(NOW + 600)), REASON_IAT)
    _expect(_iat_exp(NOW + 31, NOW + 600), REASON_IAT)
    _expect(_iat_exp(NOW + 29, NOW + 600), REASON_OK)


def test_lifetime_over_max_ttl_is_refused() raises:
    _expect(_iat_exp(NOW, NOW + 3601), REASON_TTL)
    _expect(_iat_exp(NOW, NOW + 3600), REASON_OK)
    # exp not after iat is no lifetime at all.
    _expect(_iat_exp(NOW, NOW), REASON_TTL)


def test_a_smaller_max_ttl_is_honoured() raises:
    var key = _key()
    var anchor = TrustAnchor.rs256(String("test"), ISSUER, AUDIENCE, JWKS_URL)
    anchor.max_ttl_s = Int64(300)
    var rig = _Rig(BearerJwtConfig(anchor^))
    rig.fetcher.add(200, rsa_jwks_json(key, KID))
    var tok = sign_rs256_compact(_header(KID), _iat_exp(NOW, NOW + 301), key)
    assert_equal(rig.verifier.verify(tok).reason, String(REASON_TTL))


def test_duplicate_payload_keys_are_refused() raises:
    _expect(_std(String('"sub":"svc-2"')), REASON_DUPLICATE_KEY)
    _expect(_std(String('"x":{"a":1,"a":2}')), REASON_DUPLICATE_KEY)


def test_payload_that_is_not_an_object_is_refused() raises:
    _expect(String('["not","an","object"]'), REASON_PAYLOAD_JSON)


def test_a_tampered_payload_fails_the_signature() raises:
    var key = _key()
    var rig = _Rig(_config())
    rig.fetcher.add(200, rsa_jwks_json(key, KID))
    var tok = sign_rs256_compact(_header(KID), _std(String("")), key)
    var other = sign_rs256_compact(
        _header(KID), _std(String('"admin":true')), key
    )
    var d1 = tok.find(String("."))
    var d2 = tok.rfind(String("."))
    var o1 = other.find(String("."))
    var o2 = other.rfind(String("."))
    # other's payload under tok's header and signature.
    var spliced = (
        String(tok[byte=0:d1])
        + String(other[byte=o1:o2])
        + String(tok[byte=d2 : tok.byte_length()])
    )
    assert_equal(rig.verifier.verify(spliced).reason, String(REASON_SIGNATURE))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
