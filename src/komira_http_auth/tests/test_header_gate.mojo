# =============================================================================
# test_header_gate.mojo: the JOSE header gate refuses before any key work.
# =============================================================================
#
# Pins every header refusal of token.mojo (alg other than RS256, jwk / jku /
# x5u / x5c, crit, typ, duplicate keys, missing kid, malformed shapes) by its
# reason code AND by the JWKS fetch count staying 0: the gate runs before any
# key is fetched or any signature computed. Tokens are signed over their own
# hostile headers with komira_http_core's RSA test key (declared test data).
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
from komira_http_auth.token import split_compact_jws
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
# Every token below is SIGNED OVER ITS OWN HOSTILE HEADER with the test key,
# and the JWK Set publishing that key is scripted. So a token refused here is
# refused by the header gate and nothing else: were the gate's check removed,
# the fetch would happen (fetch_count 1, not 0) and the token would reach the
# signature check and fail with another reason (or pass). Each case asserts
# BOTH the gate's reason code and that no key was fetched.
# =============================================================================


def _refused_by_gate(header_json: String, want: String) raises:
    var key = _key()
    var rig = _Rig(_config())
    rig.fetcher.add(200, rsa_jwks_json(key, KID))
    var tok = sign_rs256_compact(header_json, _claims(NOW, NOW + 600), key)
    var out = rig.verifier.verify(tok)
    assert_false(out.ok(), "refused: " + header_json)
    assert_equal(out.reason, want, "reason for " + header_json)
    assert_equal(
        rig.fetcher.fetch_count(), 0, "no key fetched for " + header_json
    )


def test_control_a_well_formed_header_verifies() raises:
    """THE CONTROL: the same rig with an honest header verifies, so every
    refusal below is a refusal of the header and not of the rig."""
    var key = _key()
    var rig = _Rig(_config())
    rig.fetcher.add(200, rsa_jwks_json(key, KID))
    var tok = sign_rs256_compact(_header(KID), _claims(NOW, NOW + 600), key)
    var out = rig.verifier.verify(tok)
    assert_equal(out.reason, String(REASON_OK))
    assert_true(out.ok())
    assert_equal(rig.fetcher.fetch_count(), 1)


def test_alg_none_is_refused() raises:
    _refused_by_gate(
        String('{"alg":"none","typ":"JWT","kid":"test-key-1"}'), REASON_ALG
    )


def test_alg_hs256_is_refused() raises:
    _refused_by_gate(
        String('{"alg":"HS256","typ":"JWT","kid":"test-key-1"}'), REASON_ALG
    )


def test_alg_es256_on_an_rs256_anchor_is_refused() raises:
    _refused_by_gate(
        String('{"alg":"ES256","typ":"JWT","kid":"test-key-1"}'), REASON_ALG
    )


def test_other_rsa_algs_and_spellings_are_refused() raises:
    _refused_by_gate(
        String('{"alg":"PS256","typ":"JWT","kid":"test-key-1"}'), REASON_ALG
    )
    _refused_by_gate(
        String('{"alg":"RS384","typ":"JWT","kid":"test-key-1"}'), REASON_ALG
    )
    _refused_by_gate(
        String('{"alg":"rs256","typ":"JWT","kid":"test-key-1"}'), REASON_ALG
    )
    _refused_by_gate(
        String('{"alg":["RS256"],"typ":"JWT","kid":"test-key-1"}'), REASON_ALG
    )
    _refused_by_gate(String('{"typ":"JWT","kid":"test-key-1"}'), REASON_ALG)


def test_jku_is_refused() raises:
    _refused_by_gate(
        String(
            '{"alg":"RS256","typ":"JWT","kid":"test-key-1",'
            '"jku":"https://keys.example.net/jwks"}'
        ),
        REASON_KEY_IN_HEADER,
    )


def test_x5u_is_refused() raises:
    _refused_by_gate(
        String(
            '{"alg":"RS256","typ":"JWT","kid":"test-key-1",'
            '"x5u":"https://keys.example.net/cert.pem"}'
        ),
        REASON_KEY_IN_HEADER,
    )


def test_jwk_is_refused() raises:
    _refused_by_gate(
        String(
            '{"alg":"RS256","typ":"JWT","kid":"test-key-1",'
            '"jwk":{"kty":"RSA","n":"AQAB","e":"AQAB"}}'
        ),
        REASON_KEY_IN_HEADER,
    )


def test_x5c_is_refused() raises:
    _refused_by_gate(
        String(
            '{"alg":"RS256","typ":"JWT","kid":"test-key-1","x5c":["MIIB"]}'
        ),
        REASON_KEY_IN_HEADER,
    )


def test_crit_is_refused() raises:
    _refused_by_gate(
        String(
            '{"alg":"RS256","typ":"JWT","kid":"test-key-1","crit":["exp"],'
            '"exp":1}'
        ),
        REASON_CRIT,
    )
    _refused_by_gate(
        String('{"alg":"RS256","typ":"JWT","kid":"test-key-1","crit":[]}'),
        REASON_CRIT,
    )


def test_wrong_or_absent_typ_is_refused() raises:
    _refused_by_gate(
        String('{"alg":"RS256","typ":"at+jwt","kid":"test-key-1"}'), REASON_TYP
    )
    _refused_by_gate(
        String('{"alg":"RS256","typ":"jwt","kid":"test-key-1"}'), REASON_TYP
    )
    _refused_by_gate(String('{"alg":"RS256","kid":"test-key-1"}'), REASON_TYP)


def test_duplicate_header_keys_are_refused() raises:
    # A repeat of a member the gate reads (kid)...
    _refused_by_gate(
        String('{"alg":"RS256","typ":"JWT","kid":"test-key-1","kid":"x"}'),
        REASON_DUPLICATE_KEY,
    )
    # ...one it would not (a member it never reads)...
    _refused_by_gate(
        String('{"alg":"RS256","typ":"JWT","kid":"test-key-1","z":1,"z":2}'),
        REASON_DUPLICATE_KEY,
    )
    # ...and one spelled differently: "alg" is "alg" after unescaping.
    _refused_by_gate(
        String(
            '{"alg":"RS256","typ":"JWT","kid":"test-key-1",'
            '"\\u0061lg":"none"}'
        ),
        REASON_DUPLICATE_KEY,
    )


def test_missing_or_empty_kid_is_refused() raises:
    _refused_by_gate(String('{"alg":"RS256","typ":"JWT"}'), REASON_KID)
    _refused_by_gate(String('{"alg":"RS256","typ":"JWT","kid":""}'), REASON_KID)


def test_non_ascii_kid_is_refused_before_any_fetch() raises:
    # komira_jose refuses a kid that is not printable ASCII, so such a kid
    # can never verify; it is a bad kid, refused before it costs a refetch (fetch_count 0 is asserted by _refused_by_gate).
    _refused_by_gate(
        String('{"alg":"RS256","typ":"JWT","kid":"k') + chr(0xE9) + String('y"}'),
        REASON_KID,
    )
    _refused_by_gate(
        String('{"alg":"RS256","typ":"JWT","kid":"k\\u0001y"}'), REASON_KID
    )
    # DEL (0x7F) is the byte just past the printable range.
    _refused_by_gate(
        String('{"alg":"RS256","typ":"JWT","kid":"k\\u007fy"}'), REASON_KID
    )


def test_header_that_is_not_a_json_object_is_refused() raises:
    _refused_by_gate(String('["RS256"]'), REASON_HEADER_JSON)
    _refused_by_gate(String('{"alg":"RS256",}'), REASON_HEADER_JSON)


def test_malformed_compact_shapes_are_refused_before_any_fetch() raises:
    var key = _key()
    var rig = _Rig(_config())
    rig.fetcher.add(200, rsa_jwks_json(key, KID))
    var good = sign_rs256_compact(_header(KID), _claims(NOW, NOW + 600), key)
    var bad = List[String]()
    bad.append(String(""))
    bad.append(String("abc"))
    bad.append(String("abc.def"))
    bad.append(good + String(".x"))  # four segments
    bad.append(good + String("="))  # padding (RFC 7515 section 2: none)
    bad.append(String(".") + good)  # empty header segment
    bad.append(String(good[byte = 0 : good.find(String(".")) + 1]) + String(".sig"))
    bad.append(String(good[byte = 0 : good.rfind(String(".")) + 1]))  # no sig
    for i in range(len(bad)):
        var out = rig.verifier.verify(bad[i])
        assert_equal(out.reason, String(REASON_MALFORMED_TOKEN), "case " + String(i))
    assert_equal(rig.fetcher.fetch_count(), 0)


def _shaped_of_length(n: Int) -> String:
    """A three-segment base64url run of exactly `n` bytes ("a..a.b.c")."""
    var s = String("")
    for _ in range(n - 4):
        s += "a"
    return s + String(".b.c")


def test_split_compact_jws_caps_at_max_token_bytes() raises:
    # MAX_TOKEN_BYTES is 8192: a well-shaped token of exactly 8192 bytes
    # splits; one byte more is refused before any segment is read.
    var at = split_compact_jws(_shaped_of_length(8192))
    assert_true(Bool(at), "8192 bytes splits")
    assert_equal(at.value().payload_seg, String("b"))
    assert_equal(at.value().signature_seg, String("c"))
    assert_equal(at.value().header_seg.byte_length(), 8188)
    assert_false(Bool(split_compact_jws(_shaped_of_length(8193))), "8193 bytes")
    var rig = _Rig(_config())
    var out = rig.verifier.verify(_shaped_of_length(8193))
    assert_equal(out.reason, String(REASON_MALFORMED_TOKEN))
    assert_equal(rig.fetcher.fetch_count(), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
