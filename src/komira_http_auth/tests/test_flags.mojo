# =============================================================================
# test_flags.mojo: the flag set, its one spelling, and startup refusals.
# =============================================================================
#
# Single-anchor flags and their defaults, the --trust-anchor form (exactly
# one accepted; a second is refused), non-https JWKS URLs refused at startup
# (by the flags and by the verifier constructor), RS256/JWT only, max TTL,
# copy-claim rules (sub, iss, aud refused), the 0..60 s leeway cap, and the
# --name=value syntax.
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


from komira_http_auth import (
    HttpsJwksFetcher,
    SystemAuthClock,
    bearer_jwt_flag_names,
    parse_bearer_jwt_flags,
)


def _args(*xs: String) -> List[String]:
    var out = List[String]()
    for i in range(len(xs)):
        out.append(xs[i])
    return out^


def _base() -> List[String]:
    return _args(
        String("--issuer=") + ISSUER,
        String("--audience=") + AUDIENCE,
        String("--jwks-url=") + JWKS_URL,
    )


def _refused(args: List[String], needle: String) raises:
    try:
        _ = parse_bearer_jwt_flags(args)
    except e:
        var msg = String(e)
        assert_true(needle in msg, "want '" + needle + "' in: " + msg)
        return
    raise Error("expected a refusal containing '" + needle + "'")


def _plus(var base: List[String], extra: String) -> List[String]:
    base.append(extra)
    return base^


def test_single_anchor_flags() raises:
    var a = _base()
    a.append(String("--copy-claim=email"))
    a.append(String("--copy-claim=email_verified"))
    a.append(String("--max-ttl=600"))
    var cfg = parse_bearer_jwt_flags(a)
    assert_equal(cfg.anchor.name, String("default"))
    assert_equal(cfg.anchor.issuer, String(ISSUER))
    assert_equal(cfg.anchor.audience, String(AUDIENCE))
    assert_equal(cfg.anchor.jwks_url, String(JWKS_URL))
    assert_equal(cfg.anchor.alg, String("RS256"))
    assert_equal(cfg.anchor.typ, String("JWT"))
    assert_equal(cfg.anchor.max_ttl_s, Int64(600))
    assert_equal(len(cfg.copy_claims), 2)
    assert_equal(cfg.copy_claims[1], String("email_verified"))
    assert_equal(cfg.leeway_s, Int64(30))


def test_defaults_and_explicit_defaults() raises:
    var cfg = parse_bearer_jwt_flags(_base())
    assert_equal(cfg.anchor.max_ttl_s, Int64(3600))
    var a = _base()
    a.append(String("--jwks-alg=RS256"))
    a.append(String("--accept-typ=JWT"))
    _ = parse_bearer_jwt_flags(a)


def test_flag_names_cover_the_documented_set() raises:
    var n = bearer_jwt_flag_names()
    assert_equal(len(n), 8)
    var want = _args(
        "--issuer", "--audience", "--jwks-url", "--jwks-alg",
        "--accept-typ", "--max-ttl", "--copy-claim", "--trust-anchor",
    )
    for i in range(len(want)):
        assert_equal(n[i], want[i])


def test_non_https_jwks_url_is_refused_at_startup() raises:
    _refused(
        _args(
            String("--issuer=") + ISSUER,
            String("--audience=") + AUDIENCE,
            String("--jwks-url=http://www.googleapis.com/oauth2/v3/certs"),
        ),
        "https",
    )
    _refused(
        _args(
            String("--issuer=") + ISSUER,
            String("--audience=") + AUDIENCE,
            String("--jwks-url=https://user:pw@keys.example.com/certs"),
        ),
        "userinfo",
    )
    _refused(
        _args(
            String("--issuer=") + ISSUER,
            String("--audience=") + AUDIENCE,
            String("--jwks-url=https://keys.example.com/certs#k"),
        ),
        "fragment",
    )


def test_non_https_jwks_url_is_refused_when_a_verifier_is_built() raises:
    """The programmatic path validates too: no verifier exists for an http
    JWKS URL, whichever way its config was made."""
    var cfg = BearerJwtConfig(
        TrustAnchor.rs256(
            String("t"), ISSUER, AUDIENCE, String("http://keys.example.com/jwks")
        )
    )
    try:
        _ = Rs256JwksVerifier[HttpsJwksFetcher, SystemAuthClock](
            cfg, HttpsJwksFetcher(), SystemAuthClock()
        )
    except e:
        assert_true(String("https") in String(e), String(e))
        return
    raise Error("a verifier was built over an http JWKS URL")


def test_only_rs256_and_jwt_are_accepted_in_this_release() raises:
    _refused(_plus(_base(), String("--jwks-alg=ES256")), "alg must be RS256")
    _refused(_plus(_base(), String("--jwks-alg=HS256")), "alg must be RS256")
    _refused(_plus(_base(), String("--accept-typ=at+jwt")), "typ must be JWT")


def test_bad_max_ttl_is_refused() raises:
    _refused(_plus(_base(), String("--max-ttl=0")), "at least 1")
    _refused(_plus(_base(), String("--max-ttl=abc")), "positive integer")
    _refused(_plus(_base(), String("--max-ttl=-5")), "positive integer")
    _refused(_plus(_base(), String("--max-ttl=86401")), "max_ttl must be")


def test_copy_claim_rules() raises:
    _refused(_plus(_base(), String("--copy-claim=sub")), "always set")
    _refused(_plus(_base(), String("--copy-claim=aud")), "always set")
    _refused(_plus(_base(), String("--copy-claim=iss")), "always set")
    var a = _plus(_base(), String("--copy-claim=email"))
    _refused(_plus(a^, String("--copy-claim=email")), "more than once")


def _verifier_refused(var cfg: BearerJwtConfig, needle: String) raises:
    try:
        _ = Verifier(cfg^, ScriptedJwksFetcher(), FixedAuthClock(NOW))
    except e:
        var msg = String(e)
        assert_true(needle in msg, "want '" + needle + "' in: " + msg)
        return
    raise Error("expected a refusal containing '" + needle + "'")


def test_leeway_is_capped_at_60_seconds() raises:
    # The cap: a verifier with more than 60 s (or a negative) leeway is never
    # built, so an hour-expired token can never be accepted by configuration.
    _verifier_refused(_config().with_leeway_s(Int64(61)), "0..60")
    _verifier_refused(_config().with_leeway_s(Int64(3600)), "0..60")
    _verifier_refused(_config().with_leeway_s(Int64(-1)), "0..60")
    # Controls: both ends of the range build.
    _ = Verifier(
        _config().with_leeway_s(Int64(60)), ScriptedJwksFetcher(), FixedAuthClock(NOW)
    )
    _ = Verifier(
        _config().with_leeway_s(Int64(0)), ScriptedJwksFetcher(), FixedAuthClock(NOW)
    )


def test_flag_syntax_is_one_spelling() raises:
    _refused(_plus(_base(), String("--issuer")), "has no value")
    _refused(_plus(_base(), String("issuer=x")), "unexpected argument")
    _refused(_plus(_base(), String("--isuer=x")), "unknown flag")
    _refused(_plus(_base(), String("--copy-claim=")), "is empty")
    _refused(_plus(_base(), String("--issuer=https://x.example")), "more than once")
    _refused(
        _args(String("--issuer=") + ISSUER, String("--audience=") + AUDIENCE),
        "--jwks-url",
    )


def test_one_trust_anchor() raises:
    var cfg = parse_bearer_jwt_flags(
        _args(
            String("--trust-anchor=name=google,issuer=")
            + ISSUER
            + String(",audience=")
            + AUDIENCE
            + String(",jwks_url=")
            + JWKS_URL
            + String(",alg=RS256,typ=JWT,max_ttl=900"),
            String("--copy-claim=email"),
        )
    )
    assert_equal(cfg.anchor.name, String("google"))
    assert_equal(cfg.anchor.issuer, String(ISSUER))
    assert_equal(cfg.anchor.audience, String(AUDIENCE))
    assert_equal(cfg.anchor.jwks_url, String(JWKS_URL))
    assert_equal(cfg.anchor.max_ttl_s, Int64(900))
    assert_equal(cfg.copy_claims[0], String("email"))


def _anchor_flag(name: String) -> String:
    return (
        String("--trust-anchor=name=")
        + name
        + String(",issuer=")
        + ISSUER
        + String(",audience=")
        + AUDIENCE
        + String(",jwks_url=")
        + JWKS_URL
    )


def test_a_second_trust_anchor_is_refused() raises:
    _refused(
        _args(_anchor_flag(String("a")), _anchor_flag(String("b"))),
        "later release",
    )


def test_trust_anchor_value_rules() raises:
    _refused(_args(_anchor_flag(String("a")) + String(",colour=blue")), "unknown key")
    _refused(_args(_anchor_flag(String("a")) + String(",name=b")), "more than once")
    _refused(_args(_anchor_flag(String("a")) + String(",typ=")), "empty value")
    _refused(_args(_anchor_flag(String("a")) + String(",alg=ES256")), "alg must be RS256")
    _refused(
        _args(
            String("--trust-anchor=name=a,issuer=")
            + ISSUER
            + String(",jwks_url=")
            + JWKS_URL
        ),
        "audience=",
    )
    _refused(
        _args(_anchor_flag(String("a")), String("--issuer=") + ISSUER),
        "cannot be combined",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
