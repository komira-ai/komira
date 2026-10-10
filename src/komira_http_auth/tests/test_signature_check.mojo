# =============================================================================
# test_signature_check.mojo: the signature step is komira_jose's RS256
#   verifier over the cached RSA signing keys.
# =============================================================================
#
# Two layers.
#
# THE CACHE ALONE (`JwksCache.verify_signature`), with no header gate in
# front of it: every token here is signed with RS256 over its own header by
# komira_http_core's RSA test key, published under KID, so the signature is
# valid and only the pinned algorithm, the kid selection, the pinned typ or
# the signature bytes can refuse it. Each case asserts komira_jose's exact
# text. These catch a defect in the call into komira_jose that the header gate
# would hide at the verifier level (it refuses the same headers first, with
# its own reason codes).
#
# THE DOCUMENT FILTER (`parse_complete_rsa_jwks` and check 7 in
# jwks_cache.mojo), through the verifier: a mixed JWK Set keeps only the RSA
# signing keys; an EC key, an RS384-labelled or an encryption key under some
# kid leaves that kid unknown (REASON_UNKNOWN_KID, as before komira_jose);
# a key komira_jwks skips refuses the whole document; a set with no key
# that may verify RS256 never replaces a working one.
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
)
from komira_http_auth.jwks_cache import JwksCache, parse_complete_rsa_jwks
from komira_http_auth.reasons import (
    REASON_HEADER_JSON,
    REASON_OK,
    REASON_SIGNATURE,
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

# A P-256 public key of the right length (komira_jwks checks lengths, not the
# curve equation), so the parser keeps it.
comptime _EC_XY = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"


def _key() raises -> List[UInt8]:
    """The repository's RSA-2048 PKCS#8 test key (komira_http_core's TLS
    fixture), declared as this test's data in the BUCK file."""
    return rsa_pkcs8_der_from_pem(
        Path("src/komira_http_core/tests/fixtures/tls/leaf_key.pem").read_text()
    )


def _claims() -> String:
    return (
        String('{"iss":"')
        + ISSUER
        + String('","aud":"')
        + AUDIENCE
        + String('","sub":"svc-1","iat":')
        + String(NOW)
        + String(',"exp":')
        + String(NOW + 600)
        + String("}")
    )


def _signed(header: String, key: List[UInt8]) raises -> String:
    return sign_rs256_compact(header, _claims(), key)


def _cache(key: List[UInt8]) raises -> JwksCache[ScriptedJwksFetcher]:
    """A cache whose set is KID's key, fetched once."""
    var f = ScriptedJwksFetcher()
    f.add(200, String("max-age=3600"), rsa_jwks_json(key, KID))
    var c = JwksCache[ScriptedJwksFetcher](
        f^, String(JWKS_URL), Int64(60), Int64(300), Int64(3600)
    )
    c.ensure(String(KID), NOW)
    return c^


def _refusal(c: JwksCache[ScriptedJwksFetcher], token: String) -> String:
    try:
        _ = c.verify_signature(token)
    except e:
        return String(e)
    return String("verified")


# =============================================================================
# The cache alone.
# =============================================================================


def test_control_a_valid_token_verifies_through_komira_jose() raises:
    # The control for every refusal below: the same key, kid and typ verify.
    var key = _key()
    var c = _cache(key)
    var v = c.verify_signature(
        _signed(String('{"alg":"RS256","typ":"JWT","kid":"test-key-1"}'), key)
    )
    assert_equal(v.alg(), String("RS256"))
    assert_equal(v.kid().value(), String(KID))
    assert_equal(v.typ().value(), String("JWT"))
    var p = v.payload()
    var claims = _claims()
    var want = claims.as_bytes()
    assert_equal(len(p), len(want))
    for i in range(len(p)):
        assert_equal(p[i], want[i])


def test_the_algorithm_is_pinned_to_rs256() raises:
    # Catches: a call that lets the header's alg through. Each token carries
    # a valid RS256 signature, so a verifier that ran RS256 whatever the
    # header named would accept every one of them.
    var key = _key()
    var c = _cache(key)
    var misses = String("")
    for alg in ["RS384", "RS512", "PS256", "ES256", "RS25", "RS2566", "rs256"]:
        var tok = _signed(
            String('{"alg":"') + String(alg) + '","typ":"JWT","kid":"test-key-1"}',
            key,
        )
        var got = _refusal(c, tok)
        if got != "JoseError: alg is not the pinned algorithm":
            misses += String(alg) + " -> " + got + "; "
    assert_equal(misses, "")
    assert_equal(
        _refusal(
            c, _signed(String('{"alg":"none","typ":"JWT","kid":"test-key-1"}'), key)
        ),
        "JoseError: alg none is refused",
    )
    assert_equal(
        _refusal(
            c, _signed(String('{"alg":"HS256","typ":"JWT","kid":"test-key-1"}'), key)
        ),
        "JoseError: an HMAC alg (HS*) is refused",
    )


def test_a_kid_naming_no_key_never_falls_back_to_the_key_held() raises:
    # Catches: a kid that names no key answered with the only key held. The
    # signature is valid under that key, so a fallback would verify.
    var key = _key()
    var c = _cache(key)
    var misses = String("")
    for kid in ["other", "test-key-", "test-key-12", "xtest-key-1", "Test-key-1"]:
        var tok = _signed(
            String('{"alg":"RS256","typ":"JWT","kid":"') + String(kid) + '"}', key
        )
        var got = _refusal(c, tok)
        if got != "JoseError: kid names no key in the set":
            misses += String(kid) + " -> " + got + "; "
    assert_equal(misses, "")
    assert_equal(
        _refusal(c, _signed(String('{"alg":"RS256","typ":"JWT"}'), key)),
        "JoseError: header kid is missing",
    )


def test_the_typ_is_pinned_to_jwt() raises:
    # Catches: a call that passes no typ, so komira_jose checks none.
    var key = _key()
    var c = _cache(key)
    assert_equal(
        _refusal(
            c,
            _signed(String('{"alg":"RS256","typ":"at+jwt","kid":"test-key-1"}'), key),
        ),
        "JoseError: header typ is not the pinned type",
    )
    assert_equal(
        _refusal(c, _signed(String('{"alg":"RS256","kid":"test-key-1"}'), key)),
        "JoseError: header typ is missing or not a string",
    )


def test_the_signature_is_checked() raises:
    # Catches: a call path that skips the signature. The last signature
    # character is replaced; separately, another signed token's payload is
    # spliced in. Either way the signature no longer covers the token.
    var key = _key()
    var c = _cache(key)
    var header = String('{"alg":"RS256","typ":"JWT","kid":"test-key-1"}')
    var tok = _signed(header, key)
    var n = tok.byte_length()
    var last = String(tok[byte = n - 1 : n])
    # A 2048-bit signature ends in 4 zero bits: A and Q both keep them zero.
    var swap = String("A") if last != String("A") else String("Q")
    var forged = String(tok[byte = 0 : n - 1]) + swap
    assert_equal(_refusal(c, forged), "JoseError: the signature does not verify")
    var other = sign_rs256_compact(header, String('{"sub":"someone-else"}'), key)
    var d1 = tok.find(String("."))
    var d2 = tok.rfind(String("."))
    var mixed = (
        String(tok[byte = 0 : d1 + 1])
        + String(other[byte = other.find(String(".")) + 1 : other.rfind(String("."))])
        + String(tok[byte = d2 : n])
    )
    assert_equal(_refusal(c, mixed), "JoseError: the signature does not verify")


def test_no_key_set_refuses() raises:
    var f = ScriptedJwksFetcher()
    var c = JwksCache[ScriptedJwksFetcher](
        f^, String(JWKS_URL), Int64(60), Int64(300), Int64(3600)
    )
    assert_equal(
        _refusal(
            c,
            _signed(String('{"alg":"RS256","typ":"JWT","kid":"test-key-1"}'), _key()),
        ),
        "komira_http_auth: no key set",
    )


def test_headers_the_old_reader_accepted_are_refused() raises:
    # Malformed headers a lax literal skip would read as an object with no
    # `crit` (komira-ai/komira#1059). komira_jose refuses them as not JSON;
    # through the verifier the header gate refuses them first, before any
    # fetch, as header_not_json_object.
    var key = _key()
    var c = _cache(key)
    var shapes = List[String]()
    shapes.append(String('{"alg":"RS256","typ":"JWT","kid":"test-key-1","a":1;}'))
    shapes.append(
        String('{"alg":"RS256","typ":"JWT","kid":"test-key-1","x":1;"crit":"b"}')
    )
    var f = ScriptedJwksFetcher()
    var v = Verifier(
        BearerJwtConfig(TrustAnchor.rs256(String("test"), ISSUER, AUDIENCE, JWKS_URL)),
        f.share(),
        FixedAuthClock(NOW),
    )
    for i in range(len(shapes)):
        var tok = _signed(shapes[i], key)
        assert_equal(_refusal(c, tok), "JoseError: the header is not JSON")
        assert_equal(v.verify(tok).reason, String(REASON_HEADER_JSON))
    assert_equal(f.fetch_count(), 0)


# =============================================================================
# The document filter, through the verifier.
# =============================================================================


struct _Rig(Movable):
    var fetcher: ScriptedJwksFetcher
    var clock: FixedAuthClock
    var verifier: Verifier

    def __init__(out self) raises:
        var f = ScriptedJwksFetcher()
        var c = FixedAuthClock(NOW)
        var v = Verifier(
            BearerJwtConfig(
                TrustAnchor.rs256(String("test"), ISSUER, AUDIENCE, JWKS_URL)
            ),
            f.share(),
            c.share(),
        )
        self.fetcher = f^
        self.clock = c^
        self.verifier = v^


def _tok(key: List[UInt8], kid: String) raises -> String:
    return _signed(
        String('{"alg":"RS256","typ":"JWT","kid":"') + kid + String('"}'), key
    )


def _doc(entries: String) -> String:
    return String('{"keys":[') + entries + String("]}")


def _with_key_ops(key: List[UInt8], kid: String, ops: String) raises -> String:
    """KID's RSA JWK under `kid`, with `"key_ops":<ops>` added."""
    return rsa_jwk_json(key, kid).replace(
        String('"use":"sig"'), String('"use":"sig","key_ops":') + ops
    )


def test_only_rsa_signing_keys_are_held() raises:
    # Catches: a filter that lets a key of another type, alg or use into the
    # set (the parser's key list then differs from the expected kids and the
    # whole document is refused, so KID would not verify; two kty values, two
    # alg values and two use values other than RSA, RS256 and sig (EC and OKP,
    # RS384 and PS256, enc and tls), so a filter that excludes only
    # one of them is caught too), and one that drops
    # an RSA key with no alg or use ("bare" would be unknown).
    var key = _key()
    var rig = _Rig()
    var bare = rsa_jwk_json(key, String("bare")).replace(
        String('"alg":"RS256","use":"sig",'), String("")
    )
    rig.fetcher.add(
        200,
        String("max-age=3600"),
        _doc(
            String('{"kty":"EC","crv":"P-256","kid":"ec","x":"')
            + _EC_XY
            + '","y":"'
            + _EC_XY
            + '"},'
            + '{"kty":"OKP","crv":"Ed25519","kid":"okp","x":"'
            + _EC_XY
            + '"},'
            + rsa_jwk_json(key, String("rs384")).replace(
                String('"alg":"RS256"'), String('"alg":"RS384"')
            )
            + ","
            + rsa_jwk_json(key, String("ps256")).replace(
                String('"alg":"RS256"'), String('"alg":"PS256"')
            )
            + ","
            + rsa_jwk_json(key, String("enc")).replace(
                String('"use":"sig"'), String('"use":"enc"')
            )
            + ","
            + rsa_jwk_json(key, String("tls")).replace(
                String('"use":"sig"'), String('"use":"tls"')
            )
            + ","
            + rsa_jwk_json(key, KID)
            + ","
            + bare
        ),
    )
    assert_equal(rig.verifier.verify(_tok(key, KID)).reason, String(REASON_OK))
    assert_equal(rig.verifier.key_count(), 2)
    assert_equal(
        rig.verifier.verify(_tok(key, String("bare"))).reason, String(REASON_OK)
    )
    # A kid naming a key that is not held is unknown, as it was before
    # komira_jose: never handed to the signature check.
    for kid in ["ec", "okp", "rs384", "ps256", "enc", "tls"]:
        assert_equal(
            rig.verifier.verify(_tok(key, String(kid))).reason,
            String(REASON_UNKNOWN_KID),
            String(kid),
        )
    assert_equal(rig.fetcher.fetch_count(), 1)


def test_a_key_the_parser_skips_refuses_the_document() raises:
    # komira_jwks skips an RSA signing key whose key_ops is not an array; the
    # expected kids then outnumber the keys lifted. Catches: a filter that
    # compares nothing after the parse.
    var key = _key()
    var doc = _doc(
        rsa_jwk_json(key, String("other"))
        + ","
        + _with_key_ops(key, String("ops"), String('"verify"'))
    )
    var rig = _Rig()
    rig.fetcher.add(200, String("max-age=3600"), doc)
    assert_true(rig.verifier.verify(_tok(key, String("other"))).keys_unavailable())
    assert_equal(rig.verifier.key_count(), 0)
    var got = String("parsed")
    try:
        _ = parse_complete_rsa_jwks(List[UInt8](doc.as_bytes()))
    except e:
        got = String(e)
    assert_equal(got, "komira_http_auth: JWKS parsed partially")


def test_an_escaped_kid_reads_the_same_in_both_readers() raises:
    # `"kid":"\u0078"` (the JSON escape backslash, u, 0078) is "x" to
    # komira_json and to komira_jwks alike, so the document is whole and
    # replaces the set.
    var key = _key()
    var rig = _Rig()
    rig.fetcher.add(
        200,
        String("max-age=3600"),
        _doc(
            rsa_jwk_json(key, String("x")).replace(
                String('"kid":"x"'), String('"kid":"\\u0078"')
            )
        ),
    )
    assert_equal(rig.verifier.verify(_tok(key, String("x"))).reason, String(REASON_OK))


def test_key_ops_is_honoured() raises:
    # A held key whose key_ops does not include verify verifies nothing: its
    # kid is known, so komira_jose refuses the token (signature_invalid). A
    # key_ops that includes verify verifies.
    var key = _key()
    var rig = _Rig()
    rig.fetcher.add(
        200,
        String("max-age=3600"),
        _doc(
            _with_key_ops(key, String("enc-only"), String('["encrypt"]'))
            + ","
            + _with_key_ops(key, KID, String('["verify"]'))
        ),
    )
    assert_equal(rig.verifier.verify(_tok(key, KID)).reason, String(REASON_OK))
    assert_equal(
        rig.verifier.verify(_tok(key, String("enc-only"))).reason,
        String(REASON_SIGNATURE),
    )


def test_a_set_with_no_key_for_rs256_never_replaces_a_working_one() raises:
    # Check 7: the fetched set's only key has a key_ops without verify, so
    # komira_jose accepts no key of it. Catches: the set replaced before (or
    # without) the verifier over it being built; KID would then be unknown.
    var key = _key()
    var rig = _Rig()
    rig.fetcher.add(200, String("max-age=0"), rsa_jwks_json(key, KID))
    rig.fetcher.add(
        200,
        String("max-age=3600"),
        _doc(_with_key_ops(key, String("enc-only"), String('["encrypt"]'))),
    )
    assert_equal(rig.verifier.verify(_tok(key, KID)).reason, String(REASON_OK))
    rig.clock.set(NOW + 61)
    assert_equal(rig.verifier.verify(_tok(key, KID)).reason, String(REASON_OK))
    assert_equal(rig.fetcher.fetch_count(), 2, "the bad set was fetched")
    assert_equal(rig.verifier.key_count(), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
