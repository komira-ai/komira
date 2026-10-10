# =============================================================================
# test_flags.mojo: the flag set, its one spelling, and startup refusals.
# =============================================================================
#
# Single-anchor flags, every one required, and the --trust-anchor form with
# all seven members required (exactly one accepted; a second is refused),
# non-https JWKS URLs refused at startup (by the flags and by the verifier
# constructor), RS256/JWT only, max TTL,
# copy-claim rules (every reserved name refused, scheme by name, by the flags
# and by the verifier constructor), the 0..60 s leeway cap and the
# --leeway-s flag (wired into the claim check), --jwks-max-stale (units,
# range, default 1 h), the 100 ms..60 s JWKS fetch timeout and its hand-over
# to the fetcher, an anchor
# built in code with an empty name, issuer or audience, and the --name=value
# syntax.
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
from komira_http_auth.config import (
    RESERVED_CLAIM_NAMES,
    is_reserved_claim_name,
    validate_trust_anchor,
)


def _args(*xs: String) -> List[String]:
    var out = List[String]()
    for i in range(len(xs)):
        out.append(xs[i])
    return out^


def _shorthand(skip: String) -> List[String]:
    """The six single-anchor flags, all required, less the one named `skip`
    (none when `skip` is empty)."""
    var every = _args(
        String("--issuer=") + ISSUER,
        String("--audience=") + AUDIENCE,
        String("--jwks-url=") + JWKS_URL,
        String("--jwks-alg=RS256"),
        String("--accept-typ=JWT"),
        String("--max-ttl=3600"),
    )
    var out = List[String]()
    for i in range(len(every)):
        if skip.byte_length() == 0 or not every[i].startswith(skip + String("=")):
            out.append(every[i])
    return out^


def _base() -> List[String]:
    return _shorthand(String(""))


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
    var a = _shorthand(String("--max-ttl"))
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


# An anchor has no defaults (flags.mojo header): a later release that
# brought in other ones would change what a running deployment accepts. One
# test per flag and per member, so a mutant that restores any one default
# names itself.


def test_the_shorthand_needs_every_flag() raises:
    # Control: all six parse, to exactly the values given.
    var cfg = parse_bearer_jwt_flags(_base())
    assert_equal(cfg.anchor.alg, String("RS256"))
    assert_equal(cfg.anchor.typ, String("JWT"))
    assert_equal(cfg.anchor.max_ttl_s, Int64(3600))
    var names = _args(
        "--issuer", "--audience", "--jwks-url", "--jwks-alg", "--accept-typ",
        "--max-ttl",
    )
    for i in range(len(names)):
        _refused(
            _shorthand(names[i]),
            String("missing required flag ") + names[i] + String("="),
        )


def test_the_shorthand_needs_jwks_alg() raises:
    _refused(_shorthand(String("--jwks-alg")), "missing required flag --jwks-alg=")


def test_the_shorthand_needs_accept_typ() raises:
    _refused(
        _shorthand(String("--accept-typ")), "missing required flag --accept-typ="
    )


def test_the_shorthand_needs_max_ttl() raises:
    _refused(_shorthand(String("--max-ttl")), "missing required flag --max-ttl=")


def test_a_trust_anchor_needs_every_member() raises:
    var keys = _args(
        "name", "issuer", "audience", "jwks_url", "alg", "typ", "max_ttl"
    )
    for i in range(len(keys)):
        _refused(
            _args(_anchor_flag_without(keys[i])),
            String("--trust-anchor needs ") + keys[i] + String("="),
        )
    # Control: all seven parse.
    var cfg = parse_bearer_jwt_flags(_args(_anchor_flag(String("a"))))
    assert_equal(cfg.anchor.name, String("a"))
    assert_equal(cfg.anchor.max_ttl_s, Int64(3600))


def test_a_trust_anchor_needs_alg() raises:
    _refused(_args(_anchor_flag_without(String("alg"))), "needs alg=")


def test_a_trust_anchor_needs_typ() raises:
    _refused(_args(_anchor_flag_without(String("typ"))), "needs typ=")


def test_a_trust_anchor_needs_max_ttl() raises:
    _refused(_args(_anchor_flag_without(String("max_ttl"))), "needs max_ttl=")


def test_flag_names_cover_the_documented_set() raises:
    var n = bearer_jwt_flag_names()
    assert_equal(len(n), 10)
    var want = _args(
        "--issuer", "--audience", "--jwks-url", "--jwks-alg",
        "--accept-typ", "--max-ttl", "--copy-claim", "--trust-anchor",
        "--leeway-s", "--jwks-max-stale",
    )
    for i in range(len(want)):
        assert_equal(n[i], want[i])


def test_non_https_jwks_url_is_refused_at_startup() raises:
    _refused(
        _plus(
            _shorthand(String("--jwks-url")),
            String("--jwks-url=http://www.googleapis.com/oauth2/v3/certs"),
        ),
        "https",
    )
    _refused(
        _plus(
            _shorthand(String("--jwks-url")),
            String("--jwks-url=https://user:pw@keys.example.com/certs"),
        ),
        "userinfo",
    )
    _refused(
        _plus(
            _shorthand(String("--jwks-url")),
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
    var no_alg = _shorthand(String("--jwks-alg"))
    var no_typ = _shorthand(String("--accept-typ"))
    _refused(_plus(no_alg.copy(), String("--jwks-alg=ES256")), "alg must be RS256")
    _refused(_plus(no_alg.copy(), String("--jwks-alg=HS256")), "alg must be RS256")
    _refused(_plus(no_typ.copy(), String("--accept-typ=at+jwt")), "typ must be JWT")
    _refused(_args(_anchor_flag_without(String("alg")) + String(",alg=ES256")), "alg must be RS256")
    _refused(_args(_anchor_flag_without(String("typ")) + String(",typ=at+jwt")), "typ must be JWT")


def test_bad_max_ttl_is_refused() raises:
    var no_ttl = _shorthand(String("--max-ttl"))
    _refused(_plus(no_ttl.copy(), String("--max-ttl=0")), "at least 1")
    _refused(_plus(no_ttl.copy(), String("--max-ttl=abc")), "positive integer")
    _refused(_plus(no_ttl.copy(), String("--max-ttl=-5")), "positive integer")
    _refused(_plus(no_ttl.copy(), String("--max-ttl=86401")), "max_ttl must be")
    _refused(
        _args(_anchor_flag_without(String("max_ttl")) + String(",max_ttl=0")),
        "at least 1",
    )


def _reserved_refusal(name: String) -> String:
    return String("--copy-claim=") + name + String(" is a reserved claim name")


def test_copy_claim_rules() raises:
    var a = _plus(_base(), String("--copy-claim=email"))
    _refused(_plus(a^, String("--copy-claim=email")), "more than once")


def test_copy_claim_scheme_is_refused_at_startup() raises:
    # An embedder may read claims['scheme'] as the principal's scheme; a
    # token claim copied under that name would forge it. Refused by the
    # flags and by the verifier constructor, naming the claim.
    _refused(
        _plus(_base(), String("--copy-claim=scheme")),
        _reserved_refusal(String("scheme")),
    )
    _verifier_refused(
        _config().with_copy_claim(String("scheme")),
        _reserved_refusal(String("scheme")),
    )
    # Exact match only: a name that merely contains a reserved one is copied.
    var ok = parse_bearer_jwt_flags(
        _plus(_base(), String("--copy-claim=schemes"))
    )
    assert_equal(ok.copy_claims[0], String("schemes"))


def test_the_reserved_set_is_exactly_these_names() raises:
    # Pins the set's contents: dropping any name from RESERVED_CLAIM_NAMES
    # turns this red even though the loop below iterates the constant.
    var want = List[String]()
    want.append(String("iss"))
    want.append(String("aud"))
    want.append(String("sub"))
    want.append(String("scheme"))
    want.append(String("subject"))
    want.append(String("claims"))
    want.append(String("presented"))
    var names = materialize[RESERVED_CLAIM_NAMES]()
    assert_equal(len(names), len(want))
    for i in range(len(want)):
        assert_true(is_reserved_claim_name(want[i]), want[i])
    assert_false(is_reserved_claim_name(String("email")))
    assert_false(is_reserved_claim_name(String("Scheme")))


def test_every_reserved_name_is_refused_by_flag_and_by_verifier() raises:
    var names = materialize[RESERVED_CLAIM_NAMES]()
    for i in range(len(names)):
        var n = String(names[i])
        _refused(
            _plus(_base(), String("--copy-claim=") + n), _reserved_refusal(n)
        )
        # Listed after an accepted name: every entry is checked, not the first.
        _verifier_refused(
            _config()
            .with_copy_claim(String("email"))
            .with_copy_claim(n),
            _reserved_refusal(n),
        )


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


def test_jwks_fetch_timeout_is_capped_and_reaches_the_fetcher() raises:
    # A fetch stalls a serving worker, so the bound has a ceiling.
    _verifier_refused(_config().with_jwks_fetch_timeout_us(0), "fetch timeout")
    _verifier_refused(_config().with_jwks_fetch_timeout_us(-1), "fetch timeout")
    # The floor is 100 ms: below it a TLS handshake cannot finish and every
    # refresh would fail.
    _verifier_refused(_config().with_jwks_fetch_timeout_us(1), "100 ms..60")
    _verifier_refused(
        _config().with_jwks_fetch_timeout_us(99_999), "fetch timeout"
    )
    _verifier_refused(
        _config().with_jwks_fetch_timeout_us(60_000_001), "fetch timeout"
    )
    # The configured value reaches the fetcher, whatever it held before; the
    # fetcher turns it into the handshake and request bounds
    # (test_https_fetcher).
    var f = ScriptedJwksFetcher()
    f.set_timeout_us(7)
    _ = Verifier(
        _config().with_jwks_fetch_timeout_us(2_500_000),
        f.share(),
        FixedAuthClock(NOW),
    )
    assert_equal(f.timeout_us(), 2_500_000)
    _ = Verifier(
        _config().with_jwks_fetch_timeout_us(60_000_000),
        f.share(),
        FixedAuthClock(NOW),
    )
    assert_equal(f.timeout_us(), 60_000_000)
    _ = Verifier(
        _config().with_jwks_fetch_timeout_us(100_000),
        f.share(),
        FixedAuthClock(NOW),
    )
    assert_equal(f.timeout_us(), 100_000)
    # The default config hands over the 5 s default.
    f.set_timeout_us(7)
    _ = Verifier(_config(), f.share(), FixedAuthClock(NOW))
    assert_equal(f.timeout_us(), 5_000_000)


def test_leeway_flag() raises:
    # Absent: the 30 s default.
    assert_equal(parse_bearer_jwt_flags(_base()).leeway_s, Int64(30))
    # Both ends of the range, with either anchor form.
    assert_equal(
        parse_bearer_jwt_flags(_plus(_base(), String("--leeway-s=0"))).leeway_s,
        Int64(0),
    )
    assert_equal(
        parse_bearer_jwt_flags(_plus(_base(), String("--leeway-s=60"))).leeway_s,
        Int64(60),
    )
    assert_equal(
        parse_bearer_jwt_flags(
            _args(_anchor_flag(String("a")), String("--leeway-s=5"))
        ).leeway_s,
        Int64(5),
    )
    # Out of range, not a number, twice.
    _refused(_plus(_base(), String("--leeway-s=61")), "0..60")
    _refused(_plus(_base(), String("--leeway-s=3600")), "0..60")
    _refused(_plus(_base(), String("--leeway-s=-1")), "non-negative integer")
    _refused(_plus(_base(), String("--leeway-s=30s")), "non-negative integer")
    _refused(_plus(_base(), String("--leeway-s=1234567890")), "non-negative")
    _refused(
        _plus(_plus(_base(), String("--leeway-s=1")), String("--leeway-s=2")),
        "more than once",
    )


def test_leeway_flag_reaches_the_claim_check() raises:
    # A verifier built from `--leeway-s=0` refuses a token at its exp, which
    # the 30 s default accepts: the parsed value is the one the claim check
    # uses.
    var key = _key()
    var tok = sign_rs256_compact(_header(KID), _claims(NOW - 600, NOW), key)
    var dflt = _Rig(parse_bearer_jwt_flags(_base()))
    dflt.fetcher.add(200, rsa_jwks_json(key, KID))
    assert_equal(dflt.verifier.verify(tok).reason, String(REASON_OK))
    var zero = _Rig(parse_bearer_jwt_flags(_plus(_base(), String("--leeway-s=0"))))
    zero.fetcher.add(200, rsa_jwks_json(key, KID))
    assert_equal(zero.verifier.verify(tok).reason, String(REASON_EXPIRED))


def test_jwks_max_stale_flag() raises:
    # Absent: one hour.
    assert_equal(parse_bearer_jwt_flags(_base()).jwks_max_stale_s, Int64(3600))
    assert_equal(
        BearerJwtConfig(
            TrustAnchor.rs256(String("t"), ISSUER, AUDIENCE, JWKS_URL)
        ).jwks_max_stale_s,
        Int64(3600),
    )
    # Each unit, and both ends of the range.
    var cases = List[String]()
    var want = List[Int64]()
    cases.append(String("90s"))
    want.append(Int64(90))
    cases.append(String("30m"))
    want.append(Int64(1800))
    cases.append(String("2h"))
    want.append(Int64(7200))
    cases.append(String("0s"))
    want.append(Int64(0))
    cases.append(String("24h"))
    want.append(Int64(86400))
    cases.append(String("86400s"))
    want.append(Int64(86400))
    # Leading zeros are digits like any other: 0001h is one hour.
    cases.append(String("0001h"))
    want.append(Int64(3600))
    for i in range(len(cases)):
        var cfg = parse_bearer_jwt_flags(
            _plus(_base(), String("--jwks-max-stale=") + cases[i])
        )
        assert_equal(cfg.jwks_max_stale_s, want[i], cases[i])
    # Out of range.
    _refused(_plus(_base(), String("--jwks-max-stale=25h")), "0..86400")
    _refused(_plus(_base(), String("--jwks-max-stale=86401s")), "0..86400")
    _refused(_plus(_base(), String("--jwks-max-stale=999999999h")), "0..86400")
    # Not a duration: no unit, another unit, a sign, no digits, too long.
    var bad = List[String]()
    bad.append(String("3600"))
    bad.append(String("1d"))
    bad.append(String("1H"))
    bad.append(String("-1s"))
    bad.append(String("h"))
    bad.append(String("1.5h"))
    bad.append(String("1h30m"))
    bad.append(String("1234567890s"))
    for i in range(len(bad)):
        _refused(
            _plus(_base(), String("--jwks-max-stale=") + bad[i]),
            "is not a duration",
        )
    _refused(
        _plus(
            _plus(_base(), String("--jwks-max-stale=1h")),
            String("--jwks-max-stale=2h"),
        ),
        "more than once",
    )
    # The setter's range is the same.
    _verifier_refused(_config().with_jwks_max_stale_s(Int64(-1)), "max-stale")
    _verifier_refused(_config().with_jwks_max_stale_s(Int64(86401)), "max-stale")


def _anchor_refused(var a: TrustAnchor, needle: String) raises:
    """`validate_trust_anchor(a)` and a verifier built over `a` both refuse,
    naming `needle`."""
    try:
        validate_trust_anchor(a)
    except e:
        var msg = String(e)
        assert_true(needle in msg, "want '" + needle + "' in: " + msg)
        _verifier_refused(BearerJwtConfig(a^), needle)
        return
    raise Error("expected a refusal containing '" + needle + "'")


def test_an_anchor_built_in_code_with_an_empty_field_is_refused() raises:
    # The flag parser refuses an empty value before an anchor exists, so
    # these reach only through TrustAnchor.rs256. An empty issuer or
    # audience must never build: the claim check compares them exactly, and
    # no verifier may exist whose accepted issuer or audience is "".
    _anchor_refused(
        TrustAnchor.rs256(String(""), ISSUER, AUDIENCE, JWKS_URL),
        "needs a name",
    )
    _anchor_refused(
        TrustAnchor.rs256(String("t"), String(""), AUDIENCE, JWKS_URL),
        "empty issuer",
    )
    _anchor_refused(
        TrustAnchor.rs256(String("t"), ISSUER, String(""), JWKS_URL),
        "empty audience",
    )
    # Control: the same anchor with every field set validates.
    validate_trust_anchor(
        TrustAnchor.rs256(String("t"), ISSUER, AUDIENCE, JWKS_URL)
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
    """A `--trust-anchor` with all seven members."""
    return (
        String("--trust-anchor=name=")
        + name
        + String(",issuer=")
        + ISSUER
        + String(",audience=")
        + AUDIENCE
        + String(",jwks_url=")
        + JWKS_URL
        + String(",alg=RS256,typ=JWT,max_ttl=3600")
    )


def _anchor_flag_without(skip: String) -> String:
    """`_anchor_flag("a")` less the member `skip`."""
    var members = _args(
        String("name=a"),
        String("issuer=") + ISSUER,
        String("audience=") + AUDIENCE,
        String("jwks_url=") + JWKS_URL,
        String("alg=RS256"),
        String("typ=JWT"),
        String("max_ttl=3600"),
    )
    var out = String("--trust-anchor=")
    var first = True
    for i in range(len(members)):
        if members[i].startswith(skip + String("=")):
            continue
        if not first:
            out += String(",")
        out += members[i]
        first = False
    return out^


def test_a_second_trust_anchor_is_refused() raises:
    _refused(
        _args(_anchor_flag(String("a")), _anchor_flag(String("b"))),
        "later release",
    )


def test_trust_anchor_value_rules() raises:
    _refused(_args(_anchor_flag(String("a")) + String(",colour=blue")), "unknown key")
    _refused(_args(_anchor_flag(String("a")) + String(",name=b")), "more than once")
    _refused(_args(_anchor_flag(String("a")) + String(",typ=")), "empty value")
    _refused(_args(_anchor_flag(String("a")) + String(",alg=RS256")), "more than once")
    _refused(_args(_anchor_flag_without(String("audience"))), "audience=")
    _refused(
        _args(_anchor_flag(String("a")), String("--issuer=") + ISSUER),
        "cannot be combined",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
