# =============================================================================
# test_jwks_cache.mojo: refetch rate limit, max-age, and validate-before-replace.
# =============================================================================
#
# An unknown kid costs exactly one refetch per window and is then refused;
# Cache-Control max-age decides freshness; a clock stepped back does not lock
# refreshes out; a truncated, partial, invalid, duplicate-keyed, repeated-kid,
# reader-ambiguous, non-ASCII-kid, empty, non-200 or failed fetch never
# replaces the current key set (the token under the current kid keeps
# verifying and the cache still holds one key).
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


from komira_http_auth import parse_cache_max_age


def _tok(key: List[UInt8], kid: String) raises -> String:
    return sign_rs256_compact(_header(kid), _claims(NOW, NOW + 600), key)


def _jwks_two(key: List[UInt8], kid_a: String, kid_b: String) raises -> String:
    return (
        String('{"keys":[')
        + rsa_jwk_json(key, kid_a)
        + String(",")
        + rsa_jwk_json(key, kid_b)
        + String("]}")
    )


# =============================================================================
# The unknown-kid refetch rate limit.
# =============================================================================


def test_unknown_kid_refetches_once_per_window_then_refuses() raises:
    var key = _key()
    var rig = _Rig(_config())
    # Fetch 1: the set publishes KID, fresh for an hour.
    rig.fetcher.add(200, String("max-age=3600"), rsa_jwks_json(key, KID))
    # Fetch 2: still no "rotated".
    rig.fetcher.add(200, String("max-age=3600"), rsa_jwks_json(key, KID))
    # Fetch 3: "rotated" is published.
    rig.fetcher.add(
        200, String("max-age=3600"), _jwks_two(key, KID, String("rotated"))
    )

    assert_equal(rig.verifier.verify(_tok(key, KID)).reason, String(REASON_OK))
    assert_equal(rig.fetcher.fetch_count(), 1)

    # Inside the first window (60 s from the last fetch): no refetch at all.
    rig.clock.set(NOW + 10)
    var rotated = _tok(key, String("rotated"))
    assert_equal(rig.verifier.verify(rotated).reason, String(REASON_UNKNOWN_KID))
    assert_equal(rig.fetcher.fetch_count(), 1)

    # Window passed: exactly one refetch, still unknown, refused.
    rig.clock.set(NOW + 61)
    assert_equal(rig.verifier.verify(rotated).reason, String(REASON_UNKNOWN_KID))
    assert_equal(rig.fetcher.fetch_count(), 2)

    # A burst of unknown-kid tokens inside the new window: no more fetches.
    for i in range(20):
        rig.clock.set(NOW + 62 + Int64(i))
        var out = rig.verifier.verify(_tok(key, String("rotated-") + String(i)))
        assert_equal(out.reason, String(REASON_UNKNOWN_KID))
    assert_equal(rig.fetcher.fetch_count(), 2)
    # The known kid still verifies throughout, from the cache.
    assert_equal(rig.verifier.verify(_tok(key, KID)).reason, String(REASON_OK))
    assert_equal(rig.fetcher.fetch_count(), 2)

    # Next window: one refetch, and the rotated key is now published.
    rig.clock.set(NOW + 121)
    assert_equal(rig.verifier.verify(rotated).reason, String(REASON_OK))
    assert_equal(rig.fetcher.fetch_count(), 3)
    assert_equal(rig.fetcher.pending(), 0)


def test_a_clock_stepped_back_does_not_lock_refreshes_out() raises:
    # Fetch at NOW, then the wall clock steps back 1000 s (an NTP
    # correction). `now - last_attempt` is negative; were it read as "inside
    # the window", a rotated kid would stay unknown until the clock passed
    # NOW + window again. It must refetch at once.
    var key = _key()
    var rig = _Rig(_config())
    rig.fetcher.add(200, String("max-age=3600"), rsa_jwks_json(key, KID))
    rig.fetcher.add(
        200, String("max-age=3600"), _jwks_two(key, KID, String("rotated"))
    )
    assert_equal(rig.verifier.verify(_tok(key, KID)).reason, String(REASON_OK))
    assert_equal(rig.fetcher.fetch_count(), 1)
    rig.clock.set(NOW - 1000)
    var rotated = sign_rs256_compact(
        _header(String("rotated")), _claims(NOW - 1000, NOW - 400), key
    )
    assert_equal(rig.verifier.verify(rotated).reason, String(REASON_OK))
    assert_equal(rig.fetcher.fetch_count(), 2)


# =============================================================================
# A document that does not parse WHOLE never replaces the current set. Each
# case: fetch 1 publishes KID (max-age=0, so the set is stale at once and the
# next window refetches); fetch 2 is the bad document, which names only
# "other". Had it replaced the set, KID would be unknown afterwards. The
# token under KID must still verify after fetch 2, and the cache must still
# hold exactly one key.
# =============================================================================


def _bad_document_keeps_current_set(bad_status: Int, bad_body: String) raises:
    var key = _key()
    var rig = _Rig(_config())
    rig.fetcher.add(200, String("max-age=0"), rsa_jwks_json(key, KID))
    rig.fetcher.add(bad_status, String("max-age=3600"), bad_body)
    var tok = _tok(key, KID)
    assert_equal(rig.verifier.verify(tok).reason, String(REASON_OK))
    assert_equal(rig.fetcher.fetch_count(), 1)
    rig.clock.set(NOW + 61)
    assert_equal(rig.verifier.verify(tok).reason, String(REASON_OK), bad_body)
    assert_equal(rig.fetcher.fetch_count(), 2, "the bad document was fetched")
    assert_equal(rig.verifier.key_count(), 1, "the current set is unchanged")


def test_truncated_parse_keeps_the_current_set() raises:
    # komira_crypto's reader stops at the second entry (it refuses any
    # backslash escape) and returns the first: a PARTIAL set of one key that
    # is not KID. Valid JSON, so only the whole-document count catches it.
    var key = _key()
    var other = rsa_jwk_json(key, String("other"))
    var escaped = rsa_jwk_json(key, String("x")).replace(
        String('"kid":"x"'), String('"kid":"\\u0078"')
    )
    _bad_document_keeps_current_set(
        200, String('{"keys":[') + other + String(",") + escaped + String("]}")
    )


def test_unusable_rsa_entry_keeps_the_current_set() raises:
    # The second RSA entry has a too-short modulus: parse_rsa_jwks drops it
    # and returns one key where the document has two RSA entries.
    var key = _key()
    var other = rsa_jwk_json(key, String("other"))
    _bad_document_keeps_current_set(
        200,
        String('{"keys":[')
        + other
        + String(',{"kty":"RSA","kid":"short","n":"AQAB","e":"AQAB"}]}'),
    )


def test_invalid_json_keeps_the_current_set() raises:
    var key = _key()
    var other = rsa_jwk_json(key, String("other"))
    # Cut short: the array and object never close.
    _bad_document_keeps_current_set(200, String('{"keys":[') + other)
    # Trailing bytes after the value.
    _bad_document_keeps_current_set(
        200, String('{"keys":[') + other + String("]}x")
    )


def test_duplicate_keys_document_keeps_the_current_set() raises:
    var key = _key()
    var other = rsa_jwk_json(key, String("other"))
    _bad_document_keeps_current_set(
        200,
        String('{"keys":[') + other + String('],"keys":[]}'),
    )


def test_repeated_kid_keeps_the_current_set() raises:
    # Two keys under one kid: every token with that kid would be refused by
    # komira_crypto as ambiguous, and no refetch would fire because the kid
    # is "known". Such a document must not replace a working set.
    var key = _key()
    var other = rsa_jwk_json(key, String("other"))
    _bad_document_keeps_current_set(
        200, String('{"keys":[') + other + String(",") + other + String("]}")
    )


def test_readers_disagreeing_with_equal_counts_keeps_the_current_set() raises:
    # Entry "a" labels alg with a number: komira_crypto treats it as absent
    # and lifts the key; entry "b" has a too-short modulus, so komira_crypto
    # drops it. Each reader sees ONE key, but not the same one. The document
    # is refused: an RSA entry with a non-string alg or use is unreadable.
    var key = _key()
    var a = rsa_jwk_json(key, String("a")).replace(
        String('"alg":"RS256"'), String('"alg":5')
    )
    var b = String('{"kty":"RSA","kid":"b","n":"AQAB","e":"AQAB"}')
    _bad_document_keeps_current_set(
        200, String('{"keys":[') + a + String(",") + b + String("]}")
    )
    var u = rsa_jwk_json(key, String("a")).replace(
        String('"use":"sig"'), String('"use":["sig"]')
    )
    _bad_document_keeps_current_set(
        200, String('{"keys":[') + u + String(",") + b + String("]}")
    )


def test_non_ascii_kid_keeps_the_current_set() raises:
    # komira_crypto builds a kid one byte per character, so a non-ASCII kid
    # reads differently in the two readers; the document is refused.
    var key = _key()
    var k = rsa_jwk_json(key, String("k") + chr(0xE9) + String("y"))
    _bad_document_keeps_current_set(
        200, String('{"keys":[') + k + String("]}")
    )


def test_no_usable_key_keeps_the_current_set() raises:
    _bad_document_keeps_current_set(
        200,
        String(
            '{"keys":[{"kty":"EC","crv":"P-256","kid":"other",'
            '"x":"AA","y":"AA"}]}'
        ),
    )
    _bad_document_keeps_current_set(200, String('{"keys":[]}'))


def test_http_error_keeps_the_current_set() raises:
    var key = _key()
    _bad_document_keeps_current_set(500, rsa_jwks_json(key, String("other")))


def test_transport_failure_keeps_the_current_set() raises:
    var key = _key()
    var rig = _Rig(_config())
    rig.fetcher.add(200, String("max-age=0"), rsa_jwks_json(key, KID))
    rig.fetcher.add_failure()
    var tok = _tok(key, KID)
    assert_equal(rig.verifier.verify(tok).reason, String(REASON_OK))
    rig.clock.set(NOW + 61)
    assert_equal(rig.verifier.verify(tok).reason, String(REASON_OK))
    assert_equal(rig.fetcher.fetch_count(), 2)


def test_first_fetch_failing_is_invalid_token_not_a_pass() raises:
    var key = _key()
    var rig = _Rig(_config())
    rig.fetcher.add_failure()
    var out = rig.verifier.verify(_tok(key, KID))
    assert_false(out.ok())
    assert_equal(out.reason, String(REASON_UNKNOWN_KID))


# =============================================================================
# Cache-Control.
# =============================================================================


def test_max_age_is_honoured() raises:
    var key = _key()
    var rig = _Rig(_config())
    rig.fetcher.add(200, String("public, max-age=120"), rsa_jwks_json(key, KID))
    rig.fetcher.add(200, String("public, max-age=120"), rsa_jwks_json(key, KID))
    var tok = _tok(key, KID)
    assert_equal(rig.verifier.verify(tok).reason, String(REASON_OK))
    assert_equal(rig.fetcher.fetch_count(), 1)
    # Fresh at 119 s: served from the cache.
    rig.clock.set(NOW + 119)
    assert_equal(rig.verifier.verify(tok).reason, String(REASON_OK))
    assert_equal(rig.fetcher.fetch_count(), 1)
    # Stale at 120 s: refetched.
    rig.clock.set(NOW + 120)
    assert_equal(rig.verifier.verify(tok).reason, String(REASON_OK))
    assert_equal(rig.fetcher.fetch_count(), 2)


def test_default_max_age_applies_without_cache_control() raises:
    var key = _key()
    var rig = _Rig(_config())
    rig.fetcher.add(200, rsa_jwks_json(key, KID))
    rig.fetcher.add(200, rsa_jwks_json(key, KID))
    var tok = _tok(key, KID)
    assert_equal(rig.verifier.verify(tok).reason, String(REASON_OK))
    rig.clock.set(NOW + 299)
    assert_equal(rig.verifier.verify(tok).reason, String(REASON_OK))
    assert_equal(rig.fetcher.fetch_count(), 1)
    rig.clock.set(NOW + 300)
    assert_equal(rig.verifier.verify(tok).reason, String(REASON_OK))
    assert_equal(rig.fetcher.fetch_count(), 2)


def test_parse_cache_max_age() raises:
    var d = Int64(300)
    assert_equal(parse_cache_max_age(Optional[String](), d), d)
    assert_equal(parse_cache_max_age(Optional[String](String("max-age=10")), d), Int64(10))
    assert_equal(parse_cache_max_age(Optional[String](String("MAX-AGE=10")), d), Int64(10))
    assert_equal(
        parse_cache_max_age(Optional[String](String('public, max-age="15"')), d),
        Int64(15),
    )
    assert_equal(
        parse_cache_max_age(Optional[String](String("max-age=10, max-age=5")), d),
        Int64(5),
    )
    assert_equal(parse_cache_max_age(Optional[String](String("no-store")), d), Int64(0))
    assert_equal(
        parse_cache_max_age(Optional[String](String("max-age=60, no-cache")), d),
        Int64(0),
    )
    assert_equal(parse_cache_max_age(Optional[String](String("max-age=abc")), d), d)
    assert_equal(parse_cache_max_age(Optional[String](String("max-age=-5")), d), d)
    assert_equal(parse_cache_max_age(Optional[String](String("public")), d), d)
    assert_equal(
        parse_cache_max_age(Optional[String](String("max-age=9999999999")), d),
        Int64(86400),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
