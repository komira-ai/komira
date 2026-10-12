# =============================================================================
# test_claims.mojo: claim checks and the principal of a valid token.
# =============================================================================
#
# The positive case (a valid RS256 token yields Principal{scheme jwt, sub,
# iss, aud, copied claims, presented credential}) and every claim refusal:
# iss (including a case variant), aud (missing, other, a case variant as a
# string or an array element, array without ours), sub, exp (missing, not an
# integer, expired past the 30 s leeway, and a configured leeway of 0 or
# 60 s honoured in place of it), iat, nbf, negative or past-9999
# times, lifetime over max TTL, duplicate payload keys, and a spliced payload
# failing the signature. A token carrying `scheme` (or another reserved
# name) never puts it into the principal's claims, and every claim the
# principal sets itself is a reserved name.
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
from komira_http_auth.config import is_reserved_claim_name
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
    # Non-ASCII survives (the claims are read from the decoded segment as
    # UTF-8, never one byte per character).
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


def _forging_payload() -> String:
    """A valid payload that also carries a claim under every Principal field
    name, `scheme` naming the other scheme."""
    return _std(
        String(
            '"email":"svc@example.com","scheme":"session",'
            '"subject":"admin","claims":"{}","presented":"x"'
        )
    )


def test_a_scheme_claim_never_reaches_the_principal() raises:
    var key = _key()
    var tok = sign_rs256_compact(_header(KID), _forging_payload(), key)

    # Copying only `email`: the token's `scheme` (and the other field names)
    # are not copied; the principal's scheme is jwt.
    var rig = _Rig(_config().with_copy_claim(String("email")))
    rig.fetcher.add(200, rsa_jwks_json(key, KID))
    var out = rig.verifier.verify(tok)
    assert_equal(out.reason, String(REASON_OK))
    var p = out.principal.value().copy()
    assert_equal(p.scheme, String("jwt"))
    assert_equal(p.subject, String("svc-1"))
    assert_false(p.claims.has(String("scheme")))
    assert_false(p.claims.has(String("subject")))
    assert_false(p.claims.has(String("claims")))
    assert_false(p.claims.has(String("presented")))
    assert_equal(
        p.claims.get(String("email")).value(), String("svc@example.com")
    )

    # An operator asking to copy `scheme`: the verifier is never built. Were
    # it built, the token below would plant claims['scheme'] = "session",
    # which this then reports as the forgery it is.
    var built = False
    try:
        var r2 = _Rig(_config().with_copy_claim(String("scheme")))
        built = True
        r2.fetcher.add(200, rsa_jwks_json(key, KID))
        var o2 = r2.verifier.verify(tok)
        if o2.ok():
            var p2 = o2.principal.value().copy()
            assert_false(
                p2.claims.has(String("scheme")),
                "forged claims['scheme'] = "
                + p2.claims.get(String("scheme")).or_else(String("")),
            )
    except e:
        if built:
            raise e^
        assert_true(
            String("--copy-claim=scheme is a reserved claim name") in String(e),
            String(e),
        )
        return
    raise Error("a verifier copying `scheme` was built")


def test_every_claim_the_principal_sets_is_reserved() raises:
    # Drift guard: a claim principal_from_claims writes that is not in
    # RESERVED_CLAIM_NAMES could be overwritten by a --copy-claim of the
    # same name. No copy-claims configured, so every key here is ours.
    var key = _key()
    var rig = _Rig(_config())
    rig.fetcher.add(200, rsa_jwks_json(key, KID))
    var out = rig.verifier.verify(
        sign_rs256_compact(_header(KID), _std(String("")), key)
    )
    assert_equal(out.reason, String(REASON_OK))
    var p = out.principal.value().copy()
    assert_true(p.claims.len() > 0)
    for i in range(p.claims.len()):
        var k = p.claims.key_at(i)
        assert_true(is_reserved_claim_name(k), k)


def test_wrong_issuer_is_refused() raises:
    var s = _std(String(""))
    _expect(
        s.replace(String(ISSUER), String("https://accounts.google.com/")),
        REASON_ISS,
    )
    _expect(
        s.replace(String(ISSUER), String("accounts.google.com")), REASON_ISS
    )
    # iss is compared EXACTLY, never case-folded: the issuer upper-cased,
    # and one letter changed in case, are other issuers.
    _expect(
        s.replace(String(ISSUER), String("HTTPS://ACCOUNTS.GOOGLE.COM")),
        REASON_ISS,
    )
    _expect(
        s.replace(String(ISSUER), String("https://accounts.Google.com")),
        REASON_ISS,
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
    # aud is compared EXACTLY, never case-folded: ours upper-cased, and one
    # letter changed in case, are other audiences.
    _expect(_with_aud(String('"aud":"HTTPS://API.EXAMPLE.COM/",')), REASON_AUD)
    _expect(_with_aud(String('"aud":"https://api.Example.com/",')), REASON_AUD)


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
    # An array element that is ours only when case-folded is not ours.
    _expect(
        _with_aud(
            String('"aud":["https://a.example/","HTTPS://API.EXAMPLE.COM/"],')
        ),
        REASON_AUD,
    )
    _expect(
        _with_aud(String('"aud":["https://api.Example.com/"],')), REASON_AUD
    )


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


def _verify_with(var cfg: BearerJwtConfig, payload_json: String) raises -> String:
    """The reason a verifier built from `cfg` gives for a token carrying
    `payload_json`, at NOW."""
    var key = _key()
    var rig = _Rig(cfg^)
    rig.fetcher.add(200, rsa_jwks_json(key, KID))
    var tok = sign_rs256_compact(_header(KID), payload_json, key)
    return rig.verifier.verify(tok).reason


def test_leeway_zero_refuses_at_exp_where_the_default_accepts() raises:
    # The configured leeway reaches the claim check (a verifier that kept the
    # 30 s default whatever the config said would accept exp == NOW here).
    var at_exp = _iat_exp(NOW - 600, NOW)
    assert_equal(_verify_with(_config(), at_exp), String(REASON_OK))
    assert_equal(
        _verify_with(_config().with_leeway_s(0), at_exp), String(REASON_EXPIRED)
    )
    # One second before exp is still inside a zero leeway.
    assert_equal(
        _verify_with(_config().with_leeway_s(0), _iat_exp(NOW - 600, NOW + 1)),
        String(REASON_OK),
    )


def test_leeway_sixty_accepts_past_the_default() raises:
    # NOW == exp + 45: past the default 30 s, inside a configured 60 s.
    var past_45 = _iat_exp(NOW - 600, NOW - 45)
    assert_equal(_verify_with(_config(), past_45), String(REASON_EXPIRED))
    assert_equal(
        _verify_with(_config().with_leeway_s(60), past_45), String(REASON_OK)
    )
    # Refused at exp + 60 (refused at or after exp + leeway).
    assert_equal(
        _verify_with(_config().with_leeway_s(60), _iat_exp(NOW - 600, NOW - 60)),
        String(REASON_EXPIRED),
    )


def test_nbf_in_the_future_is_refused() raises:
    var base = String(',"iat":') + String(NOW) + String(',"exp":') + String(
        NOW + 600
    )
    _expect(_timed(base + String(',"nbf":') + String(NOW + 31)), REASON_NBF)
    # Exactly at the 30 s leeway is still accepted (refused only past it).
    _expect(_timed(base + String(',"nbf":') + String(NOW + 30)), REASON_OK)
    _expect(_timed(base + String(',"nbf":') + String(NOW + 29)), REASON_OK)
    _expect(_timed(base + String(',"nbf":"soon"')), REASON_NBF)


def test_iat_missing_or_in_the_future_is_refused() raises:
    _expect(_timed(String(',"exp":') + String(NOW + 600)), REASON_IAT)
    _expect(_iat_exp(NOW + 31, NOW + 600), REASON_IAT)
    # Exactly at the 30 s leeway is still accepted (refused only past it).
    _expect(_iat_exp(NOW + 30, NOW + 600), REASON_OK)
    _expect(_iat_exp(NOW + 29, NOW + 600), REASON_OK)


def test_time_claims_outside_the_valid_range_are_refused() raises:
    # A negative time is not a time: each claim is refused with its own
    # reason, not read as long expired / long valid.
    _expect(_iat_exp(NOW, -1), REASON_EXP)
    _expect(_iat_exp(-1, NOW + 600), REASON_IAT)
    var base = String(',"iat":') + String(NOW) + String(',"exp":') + String(
        NOW + 600
    )
    _expect(_timed(base + String(',"nbf":-1')), REASON_NBF)
    # One past _MAX_TIME_S (9999-12-31T23:59:59Z) is refused as a bad exp,
    # not as an over-long lifetime.
    _expect(_iat_exp(NOW, 253402300800), REASON_EXP)


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
