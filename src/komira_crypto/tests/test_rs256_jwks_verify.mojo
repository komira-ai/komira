# =============================================================================
# komira_crypto/tests/test_rs256_jwks_verify.mojo — the THIRD-PARTY platform
#   attestation path: an RS256 compact JWS verified against a fetched JWK Set.
# =============================================================================
#
# WHAT IS BEING PINNED, in order of how much it would cost to get wrong:
#
#   1. ALGORITHM CONFUSION. An ES256 token must not be accepted here, and an EC
#      JWK must never reach an RSA verifier. Both are refused, and refused
#      BEFORE any crypto runs.
#   2. `alg: none` and a missing `alg`. Refused at the same gate.
#   3. KEY SELECTION. A `kid` naming no key is a refusal, never a licence to try
#      the other keys; two keys under one `kid` is a refusal too.
#   4. THE PARSER, AGAINST A DOCUMENT WE DID NOT WRITE. The vector in §4 is
#      Google's JWK Set as fetched from
#      `https://www.googleapis.com/oauth2/v3/certs`. Its members
#      appear in a DIFFERENT ORDER IN EVERY ENTRY, which is why a POSITIONAL
#      JWKS reader ("find a kid, then take the FOLLOWING x") — sound only for
#      a document rendered in a fixed order by the reader's own side — must
#      not be used here.
#
# ⛔ A SERVICE'S OWN ES256 IDENTITY PATH IS NOT TOUCHED BY ANY OF THIS. The
# other direction of the algorithm-confusion pair — an RS256 token presented
# to the service's OWN verifier — belongs in that verifier's tests (its
# refused-`alg` list must carry `RS256`, with a signed-and-valid control
# token so the refusal is not vacuous). Nothing here may ever make that pass.
#
# ⛔⛔ WHERE THE HEADER GATE IS ACTUALLY PINNED: §5, NOT §3. §3's refusals are
# built by `_retag_header`, which swaps the header of a signed token and keeps
# the old signature — so the signature no longer covers the token and step 5
# refuses it whatever the gate does. Deleting the `alg`
# allowlist, the `crit` refusal or the `typ` gate each leaves §3 fully GREEN.
# §3 pins "the signature covers the header" (true, and worth having); §5 pins
# the gate, with tokens signed OVER THEIR OWN HOSTILE HEADERS. Add a header-gate
# case to §5.
# =============================================================================

from std.testing import assert_true, assert_false, assert_equal

from komira_crypto.rs256_jwks import (
    RsaJwk,
    parse_rsa_jwks,
    verify_rs256_jws,
    verify_rs256_jws_against_jwks,
)


# -----------------------------------------------------------------------------
# §1 — a Google-metadata-SHAPED RS256 ID token + the JWK Set that publishes its
# key. Generated once with python-cryptography (OpenSSL) — an
# implementation independent of the one under test.
# -----------------------------------------------------------------------------

comptime KAT_KID: String = "komira-rs256-kat-1"


def _kat_token() -> String:
    return String(
        "eyJhbGciOiJSUzI1NiIsImtpZCI6ImtvbWlyYS1yczI1Ni1rYXQtMSIsInR5cCI6IkpX"
        + "VCJ9.eyJpc3MiOiJodHRwczovL2FjY291bnRzLmdvb2dsZS5jb20iLCJhdWQiOiJodHR"
        + "wczovL3JlZ2lzdHJ5LmtvbWlyYS5leGFtcGxlLyIsImVtYWlsIjoic3ZjQHByb2plY3Q"
        + "uaWFtLmdzZXJ2aWNlYWNjb3VudC5jb20iLCJlbWFpbF92ZXJpZmllZCI6dHJ1ZSwiZXh"
        + "wIjoxNzk4NzYxNjAwLCJpYXQiOjE3OTg3NTgwMDAsInN1YiI6IjExNDcyNTAwMDAwMDA"
        + "wMDAwMDAwMSIsImdvb2dsZSI6eyJjb21wdXRlX2VuZ2luZSI6eyJpbnN0YW5jZV9uYW1"
        + "lIjoicnMtMSIsInByb2plY3RfaWQiOiJleGFtcGxlLXByb2plY3QiLCJ6b25lIjoiZXh"
        + "hbXBsZS16b25lLWEifX19.rO76J9_feEMRd1fiQEJi9axq-9n6v8hj71sqKs-UBMb1uM"
        + "rWlerpdpiwKQq02AepTQqO8EgOY1K7JQyaloHlNz5SyShCrUpkh-DqRJq0IthwAR7yhE"
        + "4eD1tvccZHvZZK0UeVQeNvEyZseFlDl8jgkNXl12KRgnX4Th9vVYuq3KiiWdEU5CGaXQ"
        + "UCr4A540p_NIPxDygyC5Ln5JlMWawNSeOm7Q8tMngHkQ4qVomYzIENKhCIM7uUfeY2De"
        + "ryHsW_ABHy0GAyAJG9sPAYGbF8EgyB1dtdthuhq3x9kPALsF-zYUGGwyTE6ok1M1fi58"
        + "xhN4eX2byjWFxSFG2cHIPzXg"
    )


def _kat_jwks() -> String:
    return String(
        "{\"keys\":[{\"use\":\"sig\",\"kty\":\"RSA\",\"alg\":\"RS256\",\"n\":\"uMwDkdTH16M0oYY"
        + "AjsexACiZ93YtS9qW_E7tg7hc1SXSNnKWHwM0D1gYzr4TX_201t20Z0FFVz9Sk9A2reZ_Hh__gM-mVlkqYwR8"
        + "PnFpGeqR6mtwfTMriLwOCSY_1XyYBoCYQmU7BYRYd9EU_9F0d1FzAsagPVxTWtAv5DBk2cCwkPwJQXkytVCLs"
        + "H0nrf2C7n0BKkvPBueg2xyitfDpQwn6SBegyD5lNTOKBiOX9_-3YzesfWgSh0wwCVBxGh7wbRgtHUg6i7buJh"
        + "hXLx_u9e6kRTW5pYvmYpnwoj2XvZCSq6zssPOT1Jx0Vfv4eHo90s6sLOHdV78lRIWRXJEpnQ\",\"e\":\"AQ"
        + "AB\",\"kid\":\"komira-rs256-kat-1\"}]}"
    )


def _kat_payload_json() -> String:
    return String(
        "{\"iss\":\"https://accounts.google.com\",\"aud\":\"https://registry.komira.exa"
        + "mple/\",\"email\":\"svc@project.iam.gserviceaccount.com\",\"email_verified\":t"
        + "rue,\"exp\":1798761600,\"iat\":1798758000,\"sub\":\"114725000000000000001\",\""
        + "google\":{\"compute_engine\":{\"instance_name\":\"rs-1\",\"project_id\":\"exam"
        + "ple-project\",\"zone\":\"example-zone-a\"}}}"
    )


# The SAME kid, published with a DIFFERENT (independently generated) modulus.
def _wrong_key_jwks() -> String:
    return String(
        "{\"keys\":[{\"kty\":\"RSA\",\"alg\":\"RS256\",\"use\":\"sig\",\"kid\":\"komira-rs256-"
        + "kat-1\",\"n\":\"xKwDizIK4EB8qv6WrWyzsLzTqMAOic92dQcR1FueXLmql01gYlzO4QzG"
        + "qJzmQqD8krnCFCa4ze248i8D0VYEheWlIneoJBM22y2IFQnKZ5DF8vmW1O4dgthwRI_5"
        + "ifXLY18XM5H0hCPEgT4PuN5HnJefx63w_JakjBTweBGMJKoWLvg6TXB1IvIccWIxIych"
        + "pR1J-q0tjW7g75qoBfbbkQmFt2OJKyLme_rIb1tgX_EjkuYj1PGLvrJYzy_ZYN95X2pC"
        + "GXfjG-LwobKBZQgwTm9GauTLxnem8mSsxzDrrIXX8nqtIyhMBqWmVo4f-3RLoZZ5yqx4"
        + "cUQFSfKt2c1NJQ\",\"e\":\"AQAB\"}]}"
    )


# A REAL ES256 token (P-256 signature, raw r||s per RFC 7518 §3.4) under the
# same kid, and the EC JWK Set publishing its key.
def _ec_token() -> String:
    return String(
        "eyJhbGciOiJFUzI1NiIsImtpZCI6ImtvbWlyYS1yczI1Ni1rYXQtMSIsInR5cCI6IkpX"
        + "VCJ9.eyJpc3MiOiJodHRwczovL2FjY291bnRzLmdvb2dsZS5jb20iLCJhdWQiOiJodHR"
        + "wczovL3JlZ2lzdHJ5LmtvbWlyYS5leGFtcGxlLyIsImVtYWlsIjoic3ZjQHByb2plY3Q"
        + "uaWFtLmdzZXJ2aWNlYWNjb3VudC5jb20iLCJlbWFpbF92ZXJpZmllZCI6dHJ1ZSwiZXh"
        + "wIjoxNzk4NzYxNjAwLCJpYXQiOjE3OTg3NTgwMDAsInN1YiI6IjExNDcyNTAwMDAwMDA"
        + "wMDAwMDAwMSIsImdvb2dsZSI6eyJjb21wdXRlX2VuZ2luZSI6eyJpbnN0YW5jZV9uYW1"
        + "lIjoicnMtMSIsInByb2plY3RfaWQiOiJleGFtcGxlLXByb2plY3QiLCJ6b25lIjoiZXh"
        + "hbXBsZS16b25lLWEifX19.9JeWkgHaitf_25RhuNSTjEwFjVj2zWXIDVGRiwY-F1_NJR"
        + "Oi3ZmB38cM2FZdrLDY6RnYSBX3C7ZKvLpEckcemw"
    )


def _ec_jwks() -> String:
    return String(
        "{\"keys\":[{\"kty\":\"EC\",\"crv\":\"P-256\",\"alg\":\"ES256\",\"use\":\"sig\",\"kid\":\""
        + "komira-rs256-kat-1\",\"x\":\"m0GWVoZcd6nD2qQdOspbgIKktTTLPZ12xsI9pwJw8h0\",\"y\":\"m3DnG8"
        + "K4bEVdkJXP_sqStcmww08X5BFbFp1waeklSIc\"}]}"
    )


# -----------------------------------------------------------------------------
# §2 — the happy path, and the tampering cases built from it.
# -----------------------------------------------------------------------------


def test_valid_rs256_token_verifies_against_its_jwks() raises:
    """THE CONTROL. Every refusal below is vacuous without it."""
    var got = verify_rs256_jws_against_jwks(_kat_token(), _kat_jwks())
    assert_true(Bool(got), "a valid RS256 token MUST verify against its JWKS")
    assert_equal(
        got.value(),
        _kat_payload_json(),
        "the payload returned MUST be the one that was signed, byte for byte",
    )


def test_parse_lifts_exactly_one_key_with_the_expected_kid() raises:
    var keys = parse_rsa_jwks(_kat_jwks())
    assert_equal(len(keys), 1, "the KAT JWKS publishes exactly one RSA key")
    assert_equal(keys[0].kid, KAT_KID, "kid must round-trip")
    assert_equal(len(keys[0].n_be), 256, "2048-bit modulus")
    assert_equal(Int(keys[0].e), 65537, "e = AQAB = 65537")


def test_tampered_payload_fails() raises:
    """Re-point the token at a different `aud` without re-signing. The segment
    stays valid base64url, so only the signature can catch it."""
    var tok = _kat_token()
    var d1 = tok.find(String("."))
    var d2 = tok.find(String("."), d1 + 1)
    var payload = String(tok[byte = d1 + 1 : d2])
    var flipped = String(payload[byte=0 : payload.byte_length() - 1]) + String(
        "A"
    )
    if flipped == payload:
        flipped = String(payload[byte=0 : payload.byte_length() - 1]) + String(
            "B"
        )
    var forged = String(tok[byte=0 : d1 + 1]) + flipped + String(
        tok[byte=d2 : tok.byte_length()]
    )
    assert_false(
        forged == tok, "the forgery must actually differ from the original"
    )
    assert_false(
        Bool(verify_rs256_jws_against_jwks(forged, _kat_jwks())),
        "a tampered payload MUST NOT verify",
    )


def test_tampered_signature_fails() raises:
    var tok = _kat_token()
    var d1 = tok.find(String("."))
    var d2 = tok.find(String("."), d1 + 1)
    var head = String(tok[byte=0 : d2 + 1])
    var sig = String(tok[byte = d2 + 1 : tok.byte_length()])
    var last = String(sig[byte = sig.byte_length() - 1 : sig.byte_length()])
    var repl = String("A")
    if last == String("A"):
        repl = String("B")
    var forged = head + String(
        sig[byte=0 : sig.byte_length() - 1]
    ) + repl
    assert_false(
        Bool(verify_rs256_jws_against_jwks(forged, _kat_jwks())),
        "a tampered signature MUST NOT verify",
    )


def test_wrong_key_under_the_right_kid_fails() raises:
    """The kid matches; the key does not. This is what a JWKS swap looks like."""
    var keys = parse_rsa_jwks(_wrong_key_jwks())
    assert_equal(len(keys), 1, "the decoy JWKS must parse, or the test is vacuous")
    assert_equal(keys[0].kid, KAT_KID, "the decoy must carry the SAME kid")
    assert_false(
        Bool(verify_rs256_jws(_kat_token(), keys)),
        "a token whose kid matches a DIFFERENT key MUST NOT verify",
    )


# -----------------------------------------------------------------------------
# §3 — the header gate: `none`, algorithm confusion, `crit`, missing kid.
# -----------------------------------------------------------------------------


def _b64url_nopad_of(s: String) -> String:
    """base64url-nopad of an ASCII string, written here rather than imported so
    the forgeries below are built with no dependence on the code under test."""
    comptime AB: String = (
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )
    var b = s.as_bytes()
    var ab = AB.as_bytes()
    var out = String("")
    var i = 0
    while i + 2 < len(b):
        var v = (Int(b[i]) << 16) | (Int(b[i + 1]) << 8) | Int(b[i + 2])
        out += chr(Int(ab[(v >> 18) & 63]))
        out += chr(Int(ab[(v >> 12) & 63]))
        out += chr(Int(ab[(v >> 6) & 63]))
        out += chr(Int(ab[v & 63]))
        i += 3
    var rem = len(b) - i
    if rem == 1:
        var v = Int(b[i]) << 16
        out += chr(Int(ab[(v >> 18) & 63]))
        out += chr(Int(ab[(v >> 12) & 63]))
    elif rem == 2:
        var v = (Int(b[i]) << 16) | (Int(b[i + 1]) << 8)
        out += chr(Int(ab[(v >> 18) & 63]))
        out += chr(Int(ab[(v >> 12) & 63]))
        out += chr(Int(ab[(v >> 6) & 63]))
    return out^


def _retag_header(tok: String, header_json: String) -> String:
    """Replace the header segment, KEEPING the original payload + signature."""
    var d1 = tok.find(String("."))
    return _b64url_nopad_of(header_json) + String(
        tok[byte=d1 : tok.byte_length()]
    )


def test_b64url_helper_agrees_with_the_real_header() raises:
    """The forgery helper must be right, or §3's refusals prove nothing."""
    var tok = _kat_token()
    var d1 = tok.find(String("."))
    var real = String(tok[byte=0:d1])
    var rebuilt = _b64url_nopad_of(
        String('{"alg":"RS256","kid":"') + KAT_KID + String('","typ":"JWT"}')
    )
    assert_equal(
        rebuilt, real, "the in-test base64url encoder must reproduce the header"
    )
    # ...and re-tagging with the SAME header must still verify.
    assert_true(
        Bool(
            verify_rs256_jws_against_jwks(
                _retag_header(
                    tok,
                    String('{"alg":"RS256","kid":"')
                    + KAT_KID
                    + String('","typ":"JWT"}'),
                ),
                _kat_jwks(),
            )
        ),
        "re-tagging with an IDENTICAL header must still verify — otherwise the"
        " refusals below could be caused by the helper, not by the gate",
    )


def test_alg_none_is_refused() raises:
    var forged = _retag_header(
        _kat_token(),
        String('{"alg":"none","kid":"') + KAT_KID + String('","typ":"JWT"}'),
    )
    assert_false(
        Bool(verify_rs256_jws_against_jwks(forged, _kat_jwks())),
        "alg:none MUST be refused",
    )


def test_missing_alg_is_refused() raises:
    var forged = _retag_header(
        _kat_token(), String('{"kid":"') + KAT_KID + String('","typ":"JWT"}')
    )
    assert_false(
        Bool(verify_rs256_jws_against_jwks(forged, _kat_jwks())),
        "a header with no alg MUST be refused",
    )


def test_algorithm_confusion_es256_header_is_refused() raises:
    """A VALID RS256 signature, relabelled ES256. The signature is good and the
    key is right; only the allowlist can reject it."""
    var forged = _retag_header(
        _kat_token(),
        String('{"alg":"ES256","kid":"') + KAT_KID + String('","typ":"JWT"}'),
    )
    assert_false(
        Bool(verify_rs256_jws_against_jwks(forged, _kat_jwks())),
        "alg:ES256 MUST be refused by the allowlist, before any crypto",
    )


def test_algorithm_confusion_hs256_and_ps256_are_refused() raises:
    var algs = List[String]()
    algs.append(String("HS256"))
    algs.append(String("PS256"))
    algs.append(String("RS384"))
    algs.append(String("rs256"))
    for alg in algs:
        var forged = _retag_header(
            _kat_token(),
            String('{"alg":"')
            + alg
            + String('","kid":"')
            + KAT_KID
            + String('","typ":"JWT"}'),
        )
        assert_false(
            Bool(verify_rs256_jws_against_jwks(forged, _kat_jwks())),
            String("alg:") + alg + String(" MUST be refused"),
        )


def test_an_ec_key_never_enters_the_rsa_key_set() raises:
    """The OTHER direction of algorithm confusion: an EC JWK published under a
    kid an RS256 token names. The parser must drop it on `kty`, so selection
    fails and no EC coordinate is ever fed to an RSA verifier."""
    var keys = parse_rsa_jwks(_ec_jwks())
    assert_equal(
        len(keys),
        0,
        "an EC JWK Set MUST parse to ZERO RSA keys",
    )
    assert_false(
        Bool(verify_rs256_jws_against_jwks(_kat_token(), _ec_jwks())),
        "an RS256 token MUST NOT verify against an EC-only JWKS",
    )


def test_an_es256_token_is_refused_even_with_the_right_ec_key() raises:
    """A GENUINELY VALID ES256 token presented to this verifier. Its signature
    is good and its key is published under the kid it names — the only thing
    that can reject it is the allowlist."""
    var es_token = _ec_token()
    assert_false(
        Bool(verify_rs256_jws_against_jwks(es_token, _ec_jwks())),
        "an ES256 token MUST be refused here — this verifier is RS256-only",
    )
    assert_false(
        Bool(verify_rs256_jws_against_jwks(es_token, _kat_jwks())),
        "an ES256 token MUST be refused against the RSA JWKS too",
    )


def test_crit_header_is_refused() raises:
    """RFC 7515 §4.1.11 — we understand no extensions, so `crit` is a refusal."""
    var forged = _retag_header(
        _kat_token(),
        String('{"alg":"RS256","crit":"x","kid":"')
        + KAT_KID
        + String('","typ":"JWT"}'),
    )
    assert_false(
        Bool(verify_rs256_jws_against_jwks(forged, _kat_jwks())),
        "a `crit` header MUST be refused, not ignored",
    )


def test_missing_or_unknown_kid_is_refused() raises:
    var no_kid = _retag_header(
        _kat_token(), String('{"alg":"RS256","typ":"JWT"}')
    )
    assert_false(
        Bool(verify_rs256_jws_against_jwks(no_kid, _kat_jwks())),
        "a header with no kid MUST be refused — trying every key is an oracle",
    )
    var bad_kid = _retag_header(
        _kat_token(), String('{"alg":"RS256","kid":"nope","typ":"JWT"}')
    )
    assert_false(
        Bool(verify_rs256_jws_against_jwks(bad_kid, _kat_jwks())),
        "a kid naming no key MUST be refused, not fall back to the others",
    )


def test_wrong_typ_is_refused() raises:
    var forged = _retag_header(
        _kat_token(),
        String('{"alg":"RS256","kid":"') + KAT_KID + String('","typ":"JWE"}'),
    )
    assert_false(
        Bool(verify_rs256_jws_against_jwks(forged, _kat_jwks())),
        "typ other than JWT MUST be refused",
    )


def test_structurally_bad_tokens_are_refused() raises:
    var bad = List[String]()
    bad.append(String(""))
    bad.append(String("."))
    bad.append(String(".."))
    bad.append(_kat_token() + String(".extra"))
    var tok = _kat_token()
    var d2 = tok.find(String("."), tok.find(String(".")) + 1)
    bad.append(String(tok[byte=0 : d2 + 1]))  # empty signature segment
    bad.append(String(tok[byte=0:d2]))  # two segments only
    for t in bad:
        assert_false(
            Bool(verify_rs256_jws_against_jwks(t, _kat_jwks())),
            "a structurally malformed token MUST be refused",
        )


def test_empty_keyset_is_a_refusal_not_a_pass() raises:
    assert_false(
        Bool(verify_rs256_jws_against_jwks(_kat_token(), String("{}"))),
        "a JWKS with no keys member MUST refuse",
    )
    assert_false(
        Bool(
            verify_rs256_jws_against_jwks(_kat_token(), String('{"keys":[]}'))
        ),
        "an empty key set MUST refuse",
    )
    assert_false(
        Bool(verify_rs256_jws_against_jwks(_kat_token(), String("not json"))),
        "a non-JSON document MUST refuse",
    )
    var empty = List[RsaJwk]()
    assert_false(
        Bool(verify_rs256_jws(_kat_token(), empty)),
        "an empty key list MUST refuse",
    )


def test_duplicate_kid_in_the_set_is_refused() raises:
    """Two keys under one kid: there is no single answer to 'which key signed
    this', so there is no answer."""
    var keys = parse_rsa_jwks(_kat_jwks())
    var dup = parse_rsa_jwks(_wrong_key_jwks())
    assert_equal(len(keys), 1, "control")
    assert_equal(len(dup), 1, "control")
    keys.append(dup[0].copy())
    assert_equal(keys[0].kid, keys[1].kid, "the two entries must share a kid")
    assert_false(
        Bool(verify_rs256_jws(_kat_token(), keys)),
        "an ambiguous kid MUST be refused even though one of the two keys is"
        " the correct one",
    )


def test_undecodable_modulus_is_dropped() raises:
    """A JWK whose `n` is not decodable is dropped, not fatal to the rest
    of the document.

    This does NOT exercise the modulus floor: its `n` is **277** base64url
    characters, and 277 % 4 == 1, a residue no base64 string can have;
    `base64_url_decode` raises and `_parse_one_rsa_jwk` drops the key at
    the `except` two branches ABOVE the length test (lowering
    `RS256_MIN_MODULUS_BYTES` from 256 to 128 leaves this test green). The
    2048-bit floor is pinned by
    `test_undersized_modulus_is_refused_and_would_otherwise_verify` in §5,
    with a well-formed 1024-bit key and a token genuinely signed by it.
    """
    var short = String(
        '{"keys":[{"kty":"RSA","alg":"RS256","use":"sig","kid":"short","n":"'
    ) + String(
        "sXchDaQebHnPiGvyDOAT4saGEUetSyo9MKLOoWFsueri23bOdgWp4Dy1Wl"
        "UzewbgBHod5pcM9H95GQRV3JDXboIRROSBigeC5yjU1hGzHHyXss8UDpre"
        "cbAYxknTcQkhslANGRUZmdTOQ5qTRsLAt6BTYuyvVRdhS8exSZEy_c4gs_"
        "7svlJJQ4H9_NxsiIh3HdIwWwQlccpvA1BdSJ0OZ2mB0dp9tqzO6znJ7ov4"
        "P2W6t2GUFxJP-QIQfBtFAqLQNBiUBhTuXjCbvvQnREaXQ"
    ) + String('","e":"AQAB"}]}')
    var keys = parse_rsa_jwks(short)
    assert_equal(
        len(keys),
        0,
        "a JWK whose `n` is not decodable MUST be dropped (and must not abort"
        " the parse of the rest of the document)"
    )


def test_degenerate_exponents_are_dropped() raises:
    var keys0 = parse_rsa_jwks(_kat_jwks())
    assert_equal(len(keys0), 1, "control")
    var bad_es = List[String]()
    bad_es.append(String("AQ"))  # e = 1
    bad_es.append(String("Ag"))  # e = 2 (even)
    bad_es.append(String("AAEAAQ"))  # 65537 with a leading zero byte
    bad_es.append(String(""))  # absent
    for be in bad_es:
        var doc = String('{"keys":[{"kty":"RSA","kid":"') + KAT_KID + String(
            '","n":"'
        ) + _kat_n_b64() + String('","e":"') + be + String('"}]}')
        assert_equal(
            len(parse_rsa_jwks(doc)),
            0,
            String("exponent '") + be + String("' MUST be dropped"),
        )


def _kat_n_b64() -> String:
    return String(
        "uMwDkdTH16M0oYYAjsexACiZ93YtS9qW_E7tg7hc1SXSNnKWHwM0D1gYzr4TX_201t20"
        + "Z0FFVz9Sk9A2reZ_Hh__gM-mVlkqYwR8PnFpGeqR6mtwfTMriLwOCSY_1XyYBoCYQmU7"
        + "BYRYd9EU_9F0d1FzAsagPVxTWtAv5DBk2cCwkPwJQXkytVCLsH0nrf2C7n0BKkvPBueg"
        + "2xyitfDpQwn6SBegyD5lNTOKBiOX9_-3YzesfWgSh0wwCVBxGh7wbRgtHUg6i7buJhhX"
        + "Lx_u9e6kRTW5pYvmYpnwoj2XvZCSq6zssPOT1Jx0Vfv4eHo90s6sLOHdV78lRIWRXJEp"
        + "nQ"
    )


# -----------------------------------------------------------------------------
# §4 — the REAL document. Fetched from Google.
# -----------------------------------------------------------------------------


def _live_google_jwks() -> String:
    return String(
        "{\"keys\":[{\"kid\":\"8ff13a6fcdabf306712e58f35668a04eb5a5fae1\",\"use\":\"si"
        + "g\",\"kty\":\"RSA\",\"n\":\"2kuas6t-Pkn2ZP_dEWi4mf4gjRpFa8R6Hmjnq3u88f3cGe-O"
        + "XuJEUYo3ZC-vEToZ265Jb7iq-Ub-y3rQYseo-Da7SPz2M9MAOkAebfbfVoOIw7Jwl3A6"
        + "IEJXwefv-A6MSpkoiLiaL9OEuBcLjw1FXmhkMpx_8MX7WGu0zik10MfrvgOKFTysBIyV"
        + "N_hUqN-BNCuSASs4RRfj3XeWnLeF9b8VN8JSw-y738w3xglSEtvA7z1YQ-Ll2oFf1QZI"
        + "ucKhdzv-YOwgvNnh9jwztvW2KrYE6rWl1aJ_unjBR-KDsRiHF149h3Ouuw7EYp9VuzQd"
        + "cuEBNKmCfyYi_wU-X9VqWQ\",\"e\":\"AQAB\",\"alg\":\"RS256\"},{\"e\":\"AQAB\",\"kid\":"
        + "\"d6a0e659c3392d9e592a4b0ad88e7b2b88076909\",\"n\":\"xI3InXO2kFq7jdw3HKLC"
        + "XMuJwETbIkkI0QjcBI1HXDEcDNJIjiCEVM0c8638_CgIyXn_UWtYrogdtGfppF5KhNn9"
        + "5qkJ0oU7_PimD2GOx3g-vlj5LO2_LooHF8lebchgNqs_qSojGQjNvSPMZBT17707goy-"
        + "f0doLmUUjrkgZ0gWFwePb_53CpHAslo_JfkPpPstaY-KidkZl6xBGDoOByoX4Ze_saAD"
        + "mQRPa07pGntclvTRRouu5ubrVdMeaAKtcV6wyIHDiOY3Tuzes9tYgJFDTn54Zm9hMEAN"
        + "vhQLdPwacwvM_YpEh4GRp7ji00Q19s_OQC2UzBu3GG4nr4jmsw\",\"use\":\"sig\",\"kty"
        + "\":\"RSA\",\"alg\":\"RS256\"},{\"e\":\"AQAB\",\"alg\":\"RS256\",\"n\":\"pIpnzA2ezyEERJ"
        + "SxiqpLBmMeIqATH-V6iuBtKIibXEyYovujrx8niqTeO6RIyXT6uDUUv0V2kJ8V_iWYFx"
        + "zXY1BqK9IfcAmjg0XUDoyTVkoyLsF0gj299LH-zw5vCvy8jmamFIZKAbKcQ5hpHvSitt"
        + "M1vl-6vVL-i2GxyGbMA9aY6Hq15NylS1t7ELTYfQimlnvxcb7_DM0cuS5U1SfbCZMCpK"
        + "hh0nrSlYds240oxpCJOV2rBahs_Ea5c7tezS1nwVC9W_E-bR9TF6BHkC_fv-E8DcWfkI"
        + "_6geaJzBhINNxBfjx-w1-WUp2Jz3YYFWEfeQjxMqu-Fg6cGxwk7V16uQ\",\"kty\":\"RSA"
        + "\",\"use\":\"sig\",\"kid\":\"943a3a5d7d919625a454e489b75c29adab57acba\"},{\"ki"
        + "d\":\"f10f87405a979c1df36df26606734f33cd85c271\",\"e\":\"AQAB\",\"use\":\"sig\""
        + ",\"n\":\"4rY5uwZK1dQ-UVgB5s4NLyC-u5LC2MT7b8GWZztiNgMsp0Nnqx0pM7Ofx0ws32"
        + "N2aZcx10-J8ydQxnNb9uAcf-7LyhyOIcv_WEyzaSbUAMOgoF-nQmJetckxNg6ekhNfaF"
        + "cTQS0T-29ql2_CBLIML6CvSh-r0fgWRsqN2ayB7wCl74Gv6OOVbvagUWhj5z2L6o_plm"
        + "sPDwLVuvA7o3WDEDjoq-IXafRQowj92kQUenrOKD4YCopuLIBhel6VH8doFRNZ6KISQh"
        + "McOivWaLU_UtKKAMloGJieTf_3r-_nErs2h5wB7T7FrMCScmO7mvFQXKh8_4P-MlbfgS"
        + "9CUvQksw\",\"kty\":\"RSA\",\"alg\":\"RS256\"}]}"
    )


def test_parses_the_live_google_jwk_set() raises:
    """Google's own document, verbatim. This is the parser's real target and it
    is nothing like the one this repo renders: `n` sits in a different position
    in every entry."""
    var keys = parse_rsa_jwks(_live_google_jwks())
    assert_equal(
        len(keys), 4, "every RSA key in the live Google JWK Set must parse"
    )
    for i in range(len(keys)):
        assert_equal(
            len(keys[i].n_be),
            256,
            "Google publishes 2048-bit RS256 keys",
        )
        assert_equal(Int(keys[i].e), 65537, "e = AQAB")
        assert_true(
            keys[i].kid.byte_length() > 0, "every entry carries a kid"
        )
    # The kids must be DISTINCT — a positional reader that paired a kid with the
    # next entry's modulus would still produce distinct kids, so this is
    # necessary but not sufficient; the pinned kid->modulus pairing below is the
    # sufficient half.
    for i in range(len(keys)):
        for j in range(i + 1, len(keys)):
            assert_false(
                keys[i].kid == keys[j].kid, "kids must be distinct"
            )


def test_live_google_kid_to_modulus_pairing_is_positional_order_independent() raises:
    """THE FALSIFIER for the object-scoped parser. In the live document the
    members of each entry are in a different order, so a reader that takes 'the
    n after the kid' pairs entry 0's kid with entry 1's modulus. These pairs are
    the correct ones, read out of the document by an independent parser."""
    var keys = parse_rsa_jwks(_live_google_jwks())
    var expect_kids = List[String]()
    expect_kids.append(String("8ff13a6fcdabf306712e58f35668a04eb5a5fae1"))
    expect_kids.append(String("d6a0e659c3392d9e592a4b0ad88e7b2b88076909"))
    expect_kids.append(String("943a3a5d7d919625a454e489b75c29adab57acba"))
    expect_kids.append(String("f10f87405a979c1df36df26606734f33cd85c271"))
    var expect_n_head = List[String]()
    expect_n_head.append(String("da4b9ab3ab7e3e49"))
    expect_n_head.append(String("c48dc89d73b6905a"))
    expect_n_head.append(String("a48a67cc0d9ecf21"))
    expect_n_head.append(String("e2b639bb064ad5d4"))
    assert_equal(len(keys), len(expect_kids), "count")
    for i in range(len(keys)):
        assert_equal(keys[i].kid, expect_kids[i], "kid order")
        # First 8 bytes of the modulus, hex — enough to pin WHICH modulus went
        # with this kid.
        var h = String("")
        comptime HEX: String = "0123456789abcdef"
        var hx = HEX.as_bytes()
        for b in range(8):
            h += chr(Int(hx[Int(keys[i].n_be[b]) >> 4]))
            h += chr(Int(hx[Int(keys[i].n_be[b]) & 15]))
        assert_equal(
            h,
            expect_n_head[i],
            String("the modulus paired with kid ")
            + keys[i].kid
            + String(" is the WRONG one — this is what a positional reader"
                     " produces on a document whose member order varies"),
        )


# -----------------------------------------------------------------------------
# §5 — THE HEADER GATE, PINNED BY TOKENS WHOSE SIGNATURES ARE VALID.
#
# ⛔ READ THIS BEFORE ADDING ANYTHING TO §3. Every refusal in §3 is built by
# `_retag_header`, which swaps the header segment of an already-signed token and
# KEEPS the original signature. That changes the signing input, so the signature
# no longer covers the token and step 5 refuses it — WHATEVER the header gate
# does. Deleting the `alg` allowlist outright, deleting the
# `crit` refusal, or deleting the `typ` gate each leaves §3 fully GREEN. Those
# tests pin "the signature covers the header", which is true and worth having;
# they do not pin the gate, and reading them as if they did is how an
# algorithm-confusion hole survives a suite that names it in a docstring.
#
# Every token below is signed with PKCS#1 v1.5 / SHA-256 OVER ITS OWN HEADER, by
# a key this section's JWK Set publishes under the kid the header names. So for
# each one: the signature is valid, the key is right, the kid resolves, the
# signature length equals the modulus length. THE GATE IS THE ONLY THING LEFT
# THAT CAN SAY NO — and if it does not, the token is accepted and the assertion
# fires.
#
# Generated once with python-cryptography (OpenSSL) — an
# implementation independent of the one under test.
# -----------------------------------------------------------------------------


def _gate_jwks() -> String:
    """The JWK Set publishing the key EVERY token in this section is signed
    with."""
    return String(
        "{\"keys\":[{\"kty\":\"RSA\",\"alg\":\"RS256\",\"use\":\"sig\",\"k"
        + "id\":\"komira-rs256-gate-1\",\"n\":\"pykRbVjlVhThZ9ngFmbA60JHkio4"
        + "_N-GxaBpZWfSxCsNgi_RMgsPMdnnFBDsTVnjC0a_en83Nt561j_j-Dcc_ncnUAuTB"
        + "4omnKERzMZ-e-c3OZDdiZgoWKZpGjzsYjW-uqXmWryF2opWw2gV6e7JEGZhf3kJ1C"
        + "y3ekrbP-LH2aJ1DmFPn9Z6r7AM6rn8sEGFXvpQJwCLvaOQrdppkaxNHaWXzq9kGdj"
        + "mmK8B13zktKeP-hUE54-rLUdq50mCIDq5uFAUTo367b4nMIvIFQa6KOMaocIaCedk"
        + "UufsD7QgwOjyiFHi3K79O7yr3RgLZ_JKvwfWN7KHjM86xdqODlfzNQ\",\"e\":\""
        + "AQAB\"}]}"
    )


def _gate_payload_json() -> String:
    """The payload every token in this section carries, byte for byte."""
    return String(
        "{\"iss\":\"https://accounts.google.com\",\"aud\":\"https:"
        + "//registry.komira.example/\",\"sub\":\"114725000000000000"
        + "002\",\"exp\":1798761600,\"iat\":1798758000}"
    )


def _gate_token_ok() -> String:
    """THE CONTROL: a valid RS256 token. Every refusal below is vacuous
    without it."""
    return String(
        "eyJhbGciOiJSUzI1NiIsImtpZCI6ImtvbWlyYS1yczI1Ni1nYX"
        + "RlLTEiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJodHRwczovL2FjY"
        + "291bnRzLmdvb2dsZS5jb20iLCJhdWQiOiJodHRwczovL3JlZ2l"
        + "zdHJ5LmtvbWlyYS5leGFtcGxlLyIsInN1YiI6IjExNDcyNTAwM"
        + "DAwMDAwMDAwMDAwMiIsImV4cCI6MTc5ODc2MTYwMCwiaWF0Ijo"
        + "xNzk4NzU4MDAwfQ.KmlFs7dMluerlbpwFKcsy9vR0g_D6yfxP7"
        + "t4yvcyvII_b_h7TJD-CkIT9lR2n7LCCfbmjC0naulUNVfR0hpr"
        + "7O4gJaoa_05WPlcgUs3CSpMhGMVOQsO3lHqWCHBk-JS_mie4ZB"
        + "as_4RM5E0YUSSFruCpuyfDr8C8_S3-uqYKglX_ls_uXiaP74k_"
        + "MrrrnooSGH--hs4xr-HaFSIeJdbKdv8PRS9obQig3O8xy4Nm2k"
        + "HM7nqyx3tiZCRFWLShyWhLsWkWfWVlILeKONmXLoK-CZzn1_hT"
        + "cM4oDp2DsY4LHMg659zqv4rD47PLAbGQhqGMd8PcTWZ9fdBiF-"
        + "xxXijxjw"
    )


def _gate_token_alg_none() -> String:
    """`alg: none`, RS256-SIGNED over this very header. Only the allowlist
    can refuse it."""
    return String(
        "eyJhbGciOiJub25lIiwia2lkIjoia29taXJhLXJzMjU2LWdhdG"
        + "UtMSIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJodHRwczovL2FjY29"
        + "1bnRzLmdvb2dsZS5jb20iLCJhdWQiOiJodHRwczovL3JlZ2lzd"
        + "HJ5LmtvbWlyYS5leGFtcGxlLyIsInN1YiI6IjExNDcyNTAwMDA"
        + "wMDAwMDAwMDAwMiIsImV4cCI6MTc5ODc2MTYwMCwiaWF0IjoxN"
        + "zk4NzU4MDAwfQ.CxFPeHh_YOk3xnNDqPgBVm2yhQzCShpadSb0"
        + "ugNPPZY_k-7VJnSUVoiytknEk5rFVRoSXcPh0zL5q7HWWP0CNU"
        + "UX5CEQ44uTMfXOtm6L6pTKEx5wRbfbNIUcu8xzYdowWN-xjnn4"
        + "bjzPMolbEr-EMaW8R7MlO-Sf8PBlYNHlwNlxBHsNcPlXWfDOP1"
        + "lCEWQWUhrB_BRzn9jKXOcb-2hvJnr5-wBwA-F_Ff1kDFShJkK6"
        + "SwDQWOGpk7cSJrz-yQUWB41cXr6kQ_KT8WNfCmaonLLGjET345"
        + "_CVmlvfK6wVBBFc8NXCdxd0XuXdJxw6l_CdnY5QnDW6rZ1oy3a"
        + "sraxZw"
    )


def _gate_token_alg_hs256() -> String:
    """`alg: HS256`, RS256-SIGNED over this very header."""
    return String(
        "eyJhbGciOiJIUzI1NiIsImtpZCI6ImtvbWlyYS1yczI1Ni1nYX"
        + "RlLTEiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJodHRwczovL2FjY"
        + "291bnRzLmdvb2dsZS5jb20iLCJhdWQiOiJodHRwczovL3JlZ2l"
        + "zdHJ5LmtvbWlyYS5leGFtcGxlLyIsInN1YiI6IjExNDcyNTAwM"
        + "DAwMDAwMDAwMDAwMiIsImV4cCI6MTc5ODc2MTYwMCwiaWF0Ijo"
        + "xNzk4NzU4MDAwfQ.DcdBLM6IlcM-tEKgv0bx_6QcPm4DzhUa9z"
        + "oj62aS8xUdpWJJm4nTcss2b9Hf7p5n0pgJv6wZ1wmN_vxfoLOI"
        + "Dss0P6bBFeFo5jLOJyLxP180OC69yu9zU-12kfHfvshnDc2BEX"
        + "nvbCInqZABsKG99VAvNHc8Lf-wZw3KrjJfxTpuvA3V3BegSfhM"
        + "DBRVbnm4KZ4RzFiuZBvMwNpDcYh1330hMUjBhOt63lrQ2DzZZY"
        + "5R4CJZJgzsFSmuyg-t4ydN6ax9Nyg0FIdRXLGbCVj6qp9BHcUz"
        + "_Lob0KEcC77za3myP8hlDgnktiU5pbUzfA-9xxm8o6LdpDTNuo"
        + "oAHj7zOQ"
    )


def _gate_token_alg_es256() -> String:
    """ALGORITHM CONFUSION: an RS256 signature labelled ES256, signed over
    the ES256 header."""
    return String(
        "eyJhbGciOiJFUzI1NiIsImtpZCI6ImtvbWlyYS1yczI1Ni1nYX"
        + "RlLTEiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJodHRwczovL2FjY"
        + "291bnRzLmdvb2dsZS5jb20iLCJhdWQiOiJodHRwczovL3JlZ2l"
        + "zdHJ5LmtvbWlyYS5leGFtcGxlLyIsInN1YiI6IjExNDcyNTAwM"
        + "DAwMDAwMDAwMDAwMiIsImV4cCI6MTc5ODc2MTYwMCwiaWF0Ijo"
        + "xNzk4NzU4MDAwfQ.prDqBtLq9FxMSl0JTMc-I1_E6IDqVswJ5m"
        + "Yk8H7erDqEZ-jY74F_UeUo2m-xtDWBs4jmZixzYmKZIDEgYE8y"
        + "8_ZFrW698pBQjDwF7zdET_PI8vapHQtRMzegNepQntNShNfa6q"
        + "5aWoDoaOBMpmOqxYhAjyOxCY40KY6Wy-lsBEiVHa7E3y9LRRa7"
        + "Z232VaM5NpKpsd-okxKTRKHtcyUdAfi5NVfaSt8o58cWwJie4W"
        + "EnOwndrqSp2jr5078AtTGJWXQhx1hgLVbQjy_mJL91ohRQTRrb"
        + "9c-Vh1GQVVk6gvGTTHsdX6T1sYCUl4keuV2nJUe8TE_Ik4suyu"
        + "jutUJ_zg"
    )


def _gate_token_alg_ps256() -> String:
    """`alg: PS256` — the OTHER RSA scheme, and the near-miss most likely to
    be waved through."""
    return String(
        "eyJhbGciOiJQUzI1NiIsImtpZCI6ImtvbWlyYS1yczI1Ni1nYX"
        + "RlLTEiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJodHRwczovL2FjY"
        + "291bnRzLmdvb2dsZS5jb20iLCJhdWQiOiJodHRwczovL3JlZ2l"
        + "zdHJ5LmtvbWlyYS5leGFtcGxlLyIsInN1YiI6IjExNDcyNTAwM"
        + "DAwMDAwMDAwMDAwMiIsImV4cCI6MTc5ODc2MTYwMCwiaWF0Ijo"
        + "xNzk4NzU4MDAwfQ.YF3m_YnpFSakGxWD341o9QKhoQlFs_ydMV"
        + "i6HofvsKyHPEE8S3TCfLQgH_U-1htjeyoI6e2V3ABLWL0yN8Id"
        + "J7BUGFbQZLxosRO2sckUnTpexogvg6n2PcnZiQYnqeIWj6SHaO"
        + "iy_yKmqsa6QC1WxL1-69kBn7zlXFX8kfsgKS5n_vDr_zYp40-n"
        + "iCHZkv5V4VD27POcz98GA9Qe_KENKgIhbmpuc505q-m1k1G3Vh"
        + "kMHa08kCocIfV_7fAQdlHJa1fcQfhb1IaH5AgdHbhE8L-VZcrA"
        + "B6u6KTlpr0Oi1cKxV32VJzn5_0hKqDfaJl5b43Q-COc0HMai3Q"
        + "OVK-cauA"
    )


def _gate_token_alg_rs384() -> String:
    """`alg: RS384` — right family, wrong digest."""
    return String(
        "eyJhbGciOiJSUzM4NCIsImtpZCI6ImtvbWlyYS1yczI1Ni1nYX"
        + "RlLTEiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJodHRwczovL2FjY"
        + "291bnRzLmdvb2dsZS5jb20iLCJhdWQiOiJodHRwczovL3JlZ2l"
        + "zdHJ5LmtvbWlyYS5leGFtcGxlLyIsInN1YiI6IjExNDcyNTAwM"
        + "DAwMDAwMDAwMDAwMiIsImV4cCI6MTc5ODc2MTYwMCwiaWF0Ijo"
        + "xNzk4NzU4MDAwfQ.a5VK_U8zcpDa0sH2L5Al5wTEJwNdPRw4ly"
        + "-MsMF8x-8T3clhPPYJcVSdBL9I4iOf2tT1Cd2RaM_R9QSePB7O"
        + "dvAzIjE1fb0xvsAvcMvGXDAuysCeyO4B0EiX2qIBoOMq_FjWoh"
        + "QVFVKli1pnLdmo4KCYH3qsq191jwnBX3ejbeNHGa8MPpmEuAE9"
        + "18z7r4AolpYDdiaXXMtsu68twwF7wsK_lASjcz-9-7rXwhsxBk"
        + "LsoDCyPw3TyMkbXZgMYrGmCvKISar3I8B6f6U25E47II-M7M3d"
        + "fk4MvHZeofRyA1yEbDY38DnfH6K0aBlJy87zEpiWga6KuDGMvi"
        + "lVdNH12Q"
    )


def _gate_token_alg_lower() -> String:
    """`alg: rs256` — the allowlist is case-SENSITIVE."""
    return String(
        "eyJhbGciOiJyczI1NiIsImtpZCI6ImtvbWlyYS1yczI1Ni1nYX"
        + "RlLTEiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJodHRwczovL2FjY"
        + "291bnRzLmdvb2dsZS5jb20iLCJhdWQiOiJodHRwczovL3JlZ2l"
        + "zdHJ5LmtvbWlyYS5leGFtcGxlLyIsInN1YiI6IjExNDcyNTAwM"
        + "DAwMDAwMDAwMDAwMiIsImV4cCI6MTc5ODc2MTYwMCwiaWF0Ijo"
        + "xNzk4NzU4MDAwfQ.buWdcX3Ft9ti1kVFFst_A2a4ivvA1-M1En"
        + "FHJ3n7uy0Vo5_Xo7h_PX3AfTLf36Eo1dI56XFub98sN8h3fML_"
        + "Gbx-y1hcPVkzgVYe-PoSZiIecCK3Rf02z69UawGIuRZvPZNnkw"
        + "IFzzy7x17Ra8WrmnhCbUYZXWMcKkONpg408d5lSyr9VK7KxRug"
        + "eao4Pbb5Vexj93yPG1ZX4CKbOI-6gs8HCaaAnKnEfqAKrkRD6m"
        + "TRzk1oy6JfxH3s2TGO7uBFwyVZntmf2HYRNAezqLH557ZkI9MH"
        + "pOWCXKUataA1pEg2VyGkd30K-mb6i201rT87vZydY7v-7XzFMT"
        + "ql8QOoyg"
    )


def _gate_token_alg_missing() -> String:
    """No `alg` at all, RS256-SIGNED. Absent must not read as acceptable."""
    return String(
        "eyJraWQiOiJrb21pcmEtcnMyNTYtZ2F0ZS0xIiwidHlwIjoiSl"
        + "dUIn0.eyJpc3MiOiJodHRwczovL2FjY291bnRzLmdvb2dsZS5j"
        + "b20iLCJhdWQiOiJodHRwczovL3JlZ2lzdHJ5LmtvbWlyYS5leG"
        + "FtcGxlLyIsInN1YiI6IjExNDcyNTAwMDAwMDAwMDAwMDAwMiIs"
        + "ImV4cCI6MTc5ODc2MTYwMCwiaWF0IjoxNzk4NzU4MDAwfQ.Us_"
        + "JcWQ0ENRNr88Y29mFjU994BtIyFJhASMd4DFXCH-6tuckmTDBJ"
        + "9v50V4qgKV0tVXdWQhOUbmbc4eRut7xRQAKAkiiT-SNKnTaLPb"
        + "0OKP2r0yZYSLytay39tmt6j2Fgou7Sd-865oR2a0LYlAij0tnE"
        + "Ex2jD56l5B-KxYYCA2wBtwVg7xuXHCe2KqSvKeN3TJZOtsKjDn"
        + "9YALeac-QxdVe1CezTXESZcfG2KGmldk8_lcO8EfmLusE8-jue"
        + "nDW4evxWH-5wLEILdAtIf0pCE5YDlDc21MQl494xnL4SjLwEGv"
        + "Zc17inAzhAQWP-KRDLgurrlwZ94V5-bzOv15UDw"
    )


def _gate_token_crit_array() -> String:
    """`crit` IN ITS RFC 7515 SHAPE — an ARRAY. This is the spelling a real
    signer emits."""
    return String(
        "eyJhbGciOiJSUzI1NiIsImNyaXQiOlsiYjY0Il0sImtpZCI6Im"
        + "tvbWlyYS1yczI1Ni1nYXRlLTEiLCJ0eXAiOiJKV1QifQ.eyJpc"
        + "3MiOiJodHRwczovL2FjY291bnRzLmdvb2dsZS5jb20iLCJhdWQ"
        + "iOiJodHRwczovL3JlZ2lzdHJ5LmtvbWlyYS5leGFtcGxlLyIsI"
        + "nN1YiI6IjExNDcyNTAwMDAwMDAwMDAwMDAwMiIsImV4cCI6MTc"
        + "5ODc2MTYwMCwiaWF0IjoxNzk4NzU4MDAwfQ.oWIECSHyg_GOMF"
        + "EpQLvJwTGymEqmDvtKucnrTcQMsAzv0LgUnWU8I2BBLKxQIYjZ"
        + "O64VcBFDxHfh74SyaUK1F3loSxV3EeFdTzwcrKa9i4Fx0LgElV"
        + "HParxOYreePrXjwPa4LUBZuRdXAJbkn8hbf6EAJhwCuUfLsclt"
        + "r8WOsNeZ0rkhx0NUrAwQLlOPEy4LBmn8zOF4tip6zJF-wo1EMB"
        + "xF6po8N8o-f5wik2R3R554bXhSfZJDsdaJtICs1bkC040sTMz4"
        + "Y6kz1UooGXvH6x0yg2j0L5M-UhhHi1mmUR99GvRSH8fvfb5Mzn"
        + "_Um4jjrHWmo0Y5EqSVn4Iqb0JpEg"
    )


def _gate_token_crit_string() -> String:
    """`crit` mis-typed as a string. Refused too — malformed is not a
    licence."""
    return String(
        "eyJhbGciOiJSUzI1NiIsImNyaXQiOiJiNjQiLCJraWQiOiJrb2"
        + "1pcmEtcnMyNTYtZ2F0ZS0xIiwidHlwIjoiSldUIn0.eyJpc3Mi"
        + "OiJodHRwczovL2FjY291bnRzLmdvb2dsZS5jb20iLCJhdWQiOi"
        + "JodHRwczovL3JlZ2lzdHJ5LmtvbWlyYS5leGFtcGxlLyIsInN1"
        + "YiI6IjExNDcyNTAwMDAwMDAwMDAwMDAwMiIsImV4cCI6MTc5OD"
        + "c2MTYwMCwiaWF0IjoxNzk4NzU4MDAwfQ.pGJcx-N_8lx1cltEY"
        + "ayHXTYVfG--Inz9D3rKeTUtd230oOThgRH_Wv2OTX8KoexYNRU"
        + "767jCAvU-COzZA5PIm4klGvaJqK0HBYoVjAVbHZnFl2Kq-Tacz"
        + "XGgzpP6J9v5XcsqGcop2uPyLJArP6ce7mo1yrGYNvkJOkAukWy"
        + "2j6S_c_snY-xd03UgYRTwP7brHWqUlKWIvcEiIC6bj3pQlS_s-"
        + "6N_7VhZhK8gNgMRUzZRxCWLrom286wfSGkee1ySaMd3KXApB5M"
        + "xV8L-77Afs5q-1eHr9vZ__-INXGdRq66-RPJRxLvQTVwbouWbi"
        + "mMhMDtEhlrxnK_SzQdmi8Lseg"
    )


def _gate_token_typ_jwe() -> String:
    """`typ: JWE`, RS256-SIGNED. Only the typ gate can refuse it."""
    return String(
        "eyJhbGciOiJSUzI1NiIsImtpZCI6ImtvbWlyYS1yczI1Ni1nYX"
        + "RlLTEiLCJ0eXAiOiJKV0UifQ.eyJpc3MiOiJodHRwczovL2FjY"
        + "291bnRzLmdvb2dsZS5jb20iLCJhdWQiOiJodHRwczovL3JlZ2l"
        + "zdHJ5LmtvbWlyYS5leGFtcGxlLyIsInN1YiI6IjExNDcyNTAwM"
        + "DAwMDAwMDAwMDAwMiIsImV4cCI6MTc5ODc2MTYwMCwiaWF0Ijo"
        + "xNzk4NzU4MDAwfQ.m7B4_rYBP0vk2ZgueSxGz6-8_Jka61VokU"
        + "qU4bQ7m4ARuonfNagXulfUkasF-uGMe9Vn9uWHK9dGHeUTjvdg"
        + "Jb9eLzqYH737Deu9s081u82tVQ681wFJSeOuuglrDM3OALB19n"
        + "LtOqya1MjResaVgPsSedJ9xRPQfCTUjLU5XYVcwD93TCGQFieS"
        + "of3s9sIUCwmvfx6S1AStvyC9bJ052kyBtHsU-HgYixcszdoKX9"
        + "dOTZU3Xhrqu-CqBKQlANSAmKttAxbrQXHMoOa9HQDLBnCQlTuR"
        + "SMp0QS25nNWVVRQKAx9hiHqyk0FTT5S-zav2i1DMBneoxKmjpp"
        + "N2ZwaSkA"
    )


def _gate_token_typ_absent() -> String:
    """NO `typ`. RFC 7515 A.2 omits it, so this one must be ACCEPTED — the
    gate is conditional-on-present, and a test that only ever asserts
    refusal cannot tell a gate from a blanket ban."""
    return String(
        "eyJhbGciOiJSUzI1NiIsImtpZCI6ImtvbWlyYS1yczI1Ni1nYX"
        + "RlLTEifQ.eyJpc3MiOiJodHRwczovL2FjY291bnRzLmdvb2dsZ"
        + "S5jb20iLCJhdWQiOiJodHRwczovL3JlZ2lzdHJ5LmtvbWlyYS5"
        + "leGFtcGxlLyIsInN1YiI6IjExNDcyNTAwMDAwMDAwMDAwMDAwM"
        + "iIsImV4cCI6MTc5ODc2MTYwMCwiaWF0IjoxNzk4NzU4MDAwfQ."
        + "Wf14PVLG0tlZRLHhn4ZEzhNePVRGAQ37yoMHfgy2GVnXXWyWYV"
        + "ia28d016A7-P1_miPC-WYyNDOMVzgr9gasDhY_JRrHCr2xKr9F"
        + "eemL5VDE9S9oJFdPU018ryih4LQ7IdJtvSXRWitbXgVRYQrEFV"
        + "2caSXKrXUYVU3rJs4hYm8YzC_0e2FHQYKQaZFZxn8z6ZHlwZwE"
        + "41i706ymFipJ2ryy0iMqAmRo5x8qboYKH5ImgMDJKZkRHp5FiK"
        + "6TwdacDLCNb_QO7cymgiXIa_6_tL3reLm-VB2Ur84pHkakL_JJ"
        + "-J6jhbTKi-L3Lo_X3RxcJVVYFCUJTOZVCFG7LB6i1A"
    )


def _short_jwks() -> String:
    """A REAL, well-formed 1024-bit RSA JWK. Correct base64url, correct
    length for its size — so the only thing that can drop it is the
    2048-bit floor."""
    return String(
        "{\"keys\":[{\"kty\":\"RSA\",\"alg\":\"RS256\",\"use\":\"sig\",\"k"
        + "id\":\"komira-rs256-short-1\",\"n\":\"1eDDD1HAKHYcaxe_1AyPybBkZyE"
        + "r3zbhaxc-tFJ0JXo4dY3pKlSx8-bQzQacxN5X1d-mEZPDlGzRg5YHZfm0exZUAdRb"
        + "u4qjAlS-56GKKtyCNAyD2CPMgYim8MeJuY_T8-JcopLspYxqu-j8llnIh6o_l4jNN"
        + "hvkfJS3bYT15Ls\",\"e\":\"AQAB\"}]}"
    )


def _short_token() -> String:
    """A token GENUINELY SIGNED by the 1024-bit key. Drop the floor and it
    verifies."""
    return String(
        "eyJhbGciOiJSUzI1NiIsImtpZCI6ImtvbWlyYS1yczI1Ni1zaG"
        + "9ydC0xIiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2Fj"
        + "Y291bnRzLmdvb2dsZS5jb20iLCJhdWQiOiJodHRwczovL3JlZ2"
        + "lzdHJ5LmtvbWlyYS5leGFtcGxlLyIsInN1YiI6IjExNDcyNTAw"
        + "MDAwMDAwMDAwMDAwMiIsImV4cCI6MTc5ODc2MTYwMCwiaWF0Ij"
        + "oxNzk4NzU4MDAwfQ.JHPrVqgJ3yl-7ty1mm3IRDYWk2Cx9T-kV"
        + "cq25G129zcXSfev528cbYYirgboPd34EpsKEkKVf5pzlC41KSC"
        + "jTPHAx2YXcjRfYTYBtzanb8MQcof4wcDSoT98B4MVAkAQTdtoW"
        + "dPPdgg-6g5yNSYkdqE6C-DmWX3LCYTPuB3hC8E"
    )


def _oversize_jwks() -> String:
    """A 4608-bit RSA JWK — above the 512-byte ceiling that bounds the work
    an unauthenticated document can make us do."""
    return String(
        "{\"keys\":[{\"kty\":\"RSA\",\"alg\":\"RS256\",\"use\":\"sig\",\"k"
        + "id\":\"komira-rs256-big-1\",\"n\":\"qNZS4uogIlxa8PMD2oPM"
        + "Z_9CTwqlsaT99_afXYUio0xS8_pSsbSzKXTbCnH6Z0Bf6prYT6"
        + "tFfN0OIhPoL50wkmYbTpb9tWFqxzJdW2xrs0znutU10TTbjdYN"
        + "seHMfroQdfZG7F-facN2dktx9G0DbLtTVgUtibzB5_UeStQwI3"
        + "1QSJa5okETcAvQugByFHRnH8AfNPP1YRgothPMubMmbIwTz6bI"
        + "E5qtlq-EtcXgVn-Scxq4M50fZM7i-cgT_TuPK8dEjTuzm7mtTT"
        + "pqFpwqWhzDkIOx8FAYxqYJmS5sKFm9MuaAYQnHTTFiNkIigneL"
        + "7TZEmL1JctqBI1WAajWxgRqsCGRRfogmFNTH9eLvr_zB9GtZ4H"
        + "XkKqEY9bNlr-pwKVRaqQcQF3p5JWi2Ez8A3_kiXP8XKxROItE9"
        + "jjaSSzck0WDbR5tnpK4pvYQfA7fJem8pe9nmKStIbWi-t4FpwW"
        + "1BcbCKOQanG_d5qNoYnz499lXLXTo4q5qB9NMbrHx7W6FE5QqU"
        + "qiRTtUp0RaI5oHWWYSrHZK-5RsoOoh84YugnaBuvJJQ-MHTYo0"
        + "nQ9sHdPgP_MEq2NUDGdK0JJWekODT48Qn50KnuGkRoWRT6bT2j"
        + "GgtFndLs81Tl_PyNkLf9UmJyn35ByI-4ktbmA9lDQVO8CmnA1R"
        + "eYGjVfDLs5d0RD198pJRYGFbYKbO6aPIw2XkcQQiH8Y5RsTvSy"
        + "Ssu3o9xO17JI7mzIVny0txz4rJFD2dsIpnaR_616nTVCvGMj\","
        + "\"e\":\"AQAB\"}]}"
    )


def _leading_zero_jwks() -> String:
    """THE GATE KEY, published with a non-minimal modulus: one leading zero
    byte. Same integer, second spelling, 257 bytes — inside the length
    window, so length cannot catch it and the minimality check is the only
    thing that can."""
    return String(
        "{\"keys\":[{\"kty\":\"RSA\",\"alg\":\"RS256\",\"use\":\"sig\",\"k"
        + "id\":\"komira-rs256-gate-1\",\"n\":\"AKcpEW1Y5VYU4WfZ4BZmwOtCR5Iq"
        + "OPzfhsWgaWVn0sQrDYIv0TILDzHZ5xQQ7E1Z4wtGv3p_NzbeetY_4_g3HP53J1ALk"
        + "weKJpyhEczGfnvnNzmQ3YmYKFimaRo87GI1vrql5lq8hdqKVsNoFenuyRBmYX95Cd"
        + "Qst3pK2z_ix9midQ5hT5_Weq-wDOq5_LBBhV76UCcAi72jkK3aaZGsTR2ll86vZBn"
        + "Y5pivAdd85LSnj_oVBOePqy1HaudJgiA6ubhQFE6N-u2-JzCLyBUGuijjGqHCGgnn"
        + "ZFLn7A-0IMDo8ohR4tyu_Tu8q90YC2fySr8H1jeyh4zPOsXajg5X8zU\",\"e\":"
        + "\"AQAB\"}]}"
    )


def _gate_n_b64() -> String:
    """The gate key's modulus, base64url — for building hostile JWKS
    variants."""
    return String(
        "pykRbVjlVhThZ9ngFmbA60JHkio4_N-GxaBpZWfSxCsNgi_RMg"
        + "sPMdnnFBDsTVnjC0a_en83Nt561j_j-Dcc_ncnUAuTB4omnKER"
        + "zMZ-e-c3OZDdiZgoWKZpGjzsYjW-uqXmWryF2opWw2gV6e7JEG"
        + "Zhf3kJ1Cy3ekrbP-LH2aJ1DmFPn9Z6r7AM6rn8sEGFXvpQJwCL"
        + "vaOQrdppkaxNHaWXzq9kGdjmmK8B13zktKeP-hUE54-rLUdq50"
        + "mCIDq5uFAUTo367b4nMIvIFQa6KOMaocIaCedkUufsD7QgwOjy"
        + "iFHi3K79O7yr3RgLZ_JKvwfWN7KHjM86xdqODlfzNQ"
    )



def test_gate_control_a_validly_signed_token_verifies() raises:
    """THE CONTROL FOR ALL OF §5. If this fails, every refusal below is
    satisfiable by a broken harness rather than by the gate."""
    var got = verify_rs256_jws_against_jwks(_gate_token_ok(), _gate_jwks())
    assert_true(
        Bool(got),
        "the §5 control token MUST verify — its signature, key, kid and"
        " signature length are all correct by construction",
    )
    assert_equal(
        got.value(),
        _gate_payload_json(),
        "the payload returned MUST be the one that was signed, byte for byte",
    )
    var keys = parse_rsa_jwks(_gate_jwks())
    assert_equal(len(keys), 1, "the §5 JWK Set publishes exactly one key")
    assert_equal(len(keys[0].n_be), 256, "2048-bit modulus")


def test_signed_alg_none_is_refused_by_the_gate() raises:
    """`alg: none` with a VALID RS256 signature over the `alg: none` header.

    This is the whole reason the allowlist exists. Delete it and this token is
    accepted: nothing downstream examines `alg` again, so nothing downstream
    can notice.
    """
    assert_false(
        Bool(
            verify_rs256_jws_against_jwks(
                _gate_token_alg_none(), _gate_jwks()
            )
        ),
        "alg:none MUST be refused BY THE ALLOWLIST — this token's signature is"
        " valid over its own header, so nothing else can refuse it",
    )


def test_signed_algorithm_confusion_is_refused_by_the_gate() raises:
    """Every non-RS256 `alg`, each carried by a token whose RS256 signature is
    valid over that very header.

    `ES256` is the algorithm-confusion pair's near half: an RSA signature
    presented as an EC one. `PS256` is the near-miss inside RSA itself — a
    different padding scheme for the same key — and `RS384` the same digest
    family at the wrong width. `rs256` pins that the comparison is
    case-SENSITIVE. An ABSENT `alg` is included because absent must not read as
    acceptable.
    """
    var toks = List[Tuple[String, String]]()
    toks.append((String("ES256"), _gate_token_alg_es256()))
    toks.append((String("HS256"), _gate_token_alg_hs256()))
    toks.append((String("PS256"), _gate_token_alg_ps256()))
    toks.append((String("RS384"), _gate_token_alg_rs384()))
    toks.append((String("rs256"), _gate_token_alg_lower()))
    toks.append((String("<absent>"), _gate_token_alg_missing()))
    for i in range(len(toks)):
        assert_false(
            Bool(verify_rs256_jws_against_jwks(toks[i][1], _gate_jwks())),
            String("alg:")
            + toks[i][0]
            + String(
                " MUST be refused by the allowlist — the signature over this"
                " header is VALID, so the allowlist is the only thing left"
            ),
        )


def test_signed_crit_is_refused_by_the_gate() raises:
    """RFC 7515 §4.1.11 `crit`, in the shape a real signer emits: an ARRAY.

    ⚠ THE ARRAY ARM IS THE ONE THAT MATTERS, and it is the one §3 could not
    reach. The header member list this verifier builds records only
    STRING-valued members, so `{"crit":["b64"]}` left no trace in it at all and
    the refusal — the reason this verifier will not silently ignore an
    extension the signer marked essential — passed it through. Only the
    malformed string-valued spelling `{"crit":"b64"}` was ever refused, and
    that is the spelling nothing produces.
    """
    assert_false(
        Bool(
            verify_rs256_jws_against_jwks(
                _gate_token_crit_array(), _gate_jwks()
            )
        ),
        "an RFC-shaped `crit` ARRAY MUST be refused, not ignored — this token's"
        " signature is valid over its own header",
    )
    assert_false(
        Bool(
            verify_rs256_jws_against_jwks(
                _gate_token_crit_string(), _gate_jwks()
            )
        ),
        "a mis-typed string `crit` MUST be refused too — malformed is not a"
        " licence to proceed",
    )


def test_signed_wrong_typ_is_refused_and_absent_typ_is_accepted() raises:
    """The `typ` gate is CONDITIONAL ON PRESENCE, and both halves are pinned.

    A test that only ever asserts refusal cannot tell a gate from a blanket
    ban: replacing the condition with an unconditional `return None` would
    satisfy it. RFC 7515 A.2's own vector omits `typ`, so the accept arm is
    required behaviour, not leniency.
    """
    assert_false(
        Bool(
            verify_rs256_jws_against_jwks(_gate_token_typ_jwe(), _gate_jwks())
        ),
        "typ:JWE MUST be refused — the signature over this header is valid, so"
        " the typ gate is the only thing left that can refuse it",
    )
    assert_true(
        Bool(
            verify_rs256_jws_against_jwks(
                _gate_token_typ_absent(), _gate_jwks()
            )
        ),
        "a token with NO typ MUST verify (RFC 7515 A.2 omits it) — the gate is"
        " conditional on presence, not a ban",
    )


def test_undersized_modulus_is_refused_and_would_otherwise_verify() raises:
    """A REAL 1024-bit RSA key, and a token GENUINELY SIGNED BY IT.

    A key whose `n` does not decode never reaches the floor at all: it is
    dropped as UNDECODABLE (see `test_undecodable_modulus_is_dropped`).

    The key below decodes cleanly to exactly 128 bytes, so only the floor can
    drop it; and the second assertion shows what the floor is BUYING — with it
    lowered, this token verifies and returns a payload.
    """
    var keys = parse_rsa_jwks(_short_jwks())
    assert_equal(
        len(keys),
        0,
        "a well-formed 1024-bit RSA JWK MUST NOT enter the trusted set",
    )
    assert_false(
        Bool(verify_rs256_jws_against_jwks(_short_token(), _short_jwks())),
        "a token signed by a 1024-bit key MUST NOT verify — its signature is"
        " genuinely valid, so the modulus floor is the only refusal available",
    )


def test_oversized_modulus_is_refused() raises:
    """The ceiling bounds the work an unauthenticated document can make us do.
    A 4608-bit modulus is 576 bytes, past the 512-byte limit."""
    assert_equal(
        len(parse_rsa_jwks(_oversize_jwks())),
        0,
        "a modulus above RS256_MAX_MODULUS_BYTES MUST be dropped",
    )


def test_non_minimal_modulus_is_dropped_at_parse() raises:
    """THE GATE KEY ITSELF, republished with one leading zero byte.

    Same integer, second spelling, 257 bytes — inside the length window, so
    neither the floor nor the ceiling can catch it. Two spellings of one key
    are two kids for one key, and RFC 7518 §6.3.1.1 says the octet sequence is
    minimal. THE FIRST ASSERTION IS THE DISCRIMINATING ONE: deleting the
    minimality check leaves this document parsing to one key, and only that
    assertion notices.

    ⚠ THE SECOND ASSERTION IS NOT A SECOND FALSIFIER. With the minimality
    check deleted AND the first assertion relaxed, the token is still refused, by step 4's
    `len(sig) == len(n)` (RFC 8017 §8.2.2 step 1) — 256 against 257. So the
    length check backstops this one, which is worth knowing and is NOT the same
    as the minimality check being redundant: it is redundant for a modulus
    inflated by exactly the bytes that break the length equality, and for
    nothing else. The assertion is kept for what it does pin — that the two
    spellings of one key do not interoperate, which is the harm — and it is
    labelled so nobody counts it twice.
    """
    assert_equal(
        len(parse_rsa_jwks(_leading_zero_jwks())),
        0,
        "a non-minimal (leading-zero) modulus MUST be dropped",
    )
    assert_false(
        Bool(
            verify_rs256_jws_against_jwks(
                _gate_token_ok(), _leading_zero_jwks()
            )
        ),
        "the CONTROL token — which verifies against the minimal spelling of"
        " this very key — MUST be refused when the key is published"
        " non-minimally",
    )


def test_the_es256_identity_path_is_not_reachable_from_here() raises:
    """⛔ THE SEPARATION, ASSERTED. This verifier is for a THIRD-PARTY (Google)
    RS256 token; a service's OWN identity tokens are ES256, verified by the
    service's own verifier against a DIFFERENT trust anchor. Google will sign
    an ID token for anyone with a Google account, so a verifier willing to
    accept one where a service-signed token is required is the break — and so
    is the reverse.

    Both directions are refused here, and neither may ever be fused:

      * an RS256 token whose kid resolves to an EC JWK — dropped on `kty`, so no
        EC coordinate ever reaches an RSA verifier;
      * a GENUINELY VALID ES256 token — refused whichever key set it is offered
        against.
    """
    assert_equal(
        len(parse_rsa_jwks(_ec_jwks())),
        0,
        "an EC JWK Set MUST parse to ZERO RSA keys",
    )
    assert_false(
        Bool(verify_rs256_jws_against_jwks(_ec_token(), _ec_jwks())),
        "an ES256 token MUST be refused against its own EC key set",
    )
    assert_false(
        Bool(verify_rs256_jws_against_jwks(_ec_token(), _gate_jwks())),
        "an ES256 token MUST be refused against an RSA key set too",
    )
    assert_false(
        Bool(verify_rs256_jws_against_jwks(_kat_token(), _ec_jwks())),
        "an RS256 token MUST be refused when the ONLY key published under the"
        " very kid it names is an EC one",
    )


# -----------------------------------------------------------------------------
# §6 — THE FLOORS §5 STILL DID NOT PIN.
#
# ⛔ §5 closed the HEADER gate. It did not close the JWK-SELECTION gate, and it
# did not close the EXACTNESS of the two header comparisons it does exercise.
# Each mutant below, applied alone to `rs256_jwks.mojo`, passes the suite
# without §6 and fails it with §6:
#
#   (a)  delete the JWK `use` gate (an enc key verifies)
#   (b)  delete the JWK `alg` gate (an RS512-labelled key
#        becomes an RS256 verification key)
#   (c)  `_member`'s duplicate-name refusal -> last-wins
#   (d)  header `alg` equality -> `startswith(RS256)`
#
# (c) is the one that matters most. `_object_string_members` records a repeated
# member TWICE and `_member` refuses the object, and the docstring calls that
# "an authentication bypass waiting for a proxy to sit in front of us" — a
# `{"alg":"none","alg":"RS256"}` header on which we and a fronting proxy pick
# differently. Without §6 that control has no test in either direction.
#
# The JWK-side arms need no signature: a key that never enters the trusted set
# cannot verify anything, so `parse_rsa_jwks` answers on its own. The
# header-side arms DO need one, and this suite holds no private key for the §5
# key, so §6 carries a SECOND, independently generated 2048-bit key and signs
# its own hostile headers with it.
#
# ⚠ EVERY REFUSAL HERE IS PAIRED WITH ITS CONDITIONAL ACCEPT. `alg` and `use`
# are "IF PRESENT" gates: a mutant replacing either with a blanket refusal is a
# different defect and must not read as a pass. `test_the_jwks_splice_is_faithful`
# is the control for the whole section — without it a typo in the splice makes
# every refusal below vacuous.
# -----------------------------------------------------------------------------


def _gate_jwks_with(pre: String, post: String) -> String:
    """The §5 gate key republished with `pre` spliced in BEFORE its `kid` and
    `post` appended AFTER its `e`, so a member can be introduced on either
    side of the real one.

    Same modulus, same exponent, same kid as `_gate_jwks()` — so
    `_gate_token_ok()` is a genuine, valid token for every document this
    builds, and the ONLY thing that can change the outcome is the member
    spliced in.
    """
    var tail = String("")
    if post.byte_length() > 0:
        tail = String(",") + post
    return (
        String("{\"keys\":[{\"kty\":\"RSA\",")
        + pre
        + String("\"kid\":\"komira-rs256-gate-1\",\"n\":\"")
        + _gate_n_b64()
        + String("\",\"e\":\"AQAB\"")
        + tail
        + String("}]}")
    )


def _gate2_jwks() -> String:
    """The JWK Set publishing §6's second, independent key."""
    return (
        String("{\"keys\":[{\"kty\":\"RSA\",\"alg\":\"RS256\",\"use\":\"sig\"")
        + String(",\"kid\":\"komira-rs256-gate-2\",\"n\":\"")
        + _gate2_n_b64()
        + String("\",\"e\":\"AQAB\"}]}")
    )


def _gate2_n_b64() -> String:
    """The SECOND, independently generated 2048-bit RSA modulus, base64url.

    §6 carries its own key because its arms need tokens signed over headers
    the §5 key's owner never signed, and this suite holds no private key.
    Generated with python-cryptography (OpenSSL)."""
    return String(
        "sUvrVSEIW9XodNeke82Sk5nItKTOK8GISDvPfZEndgqvacWG9t"
        + "eWWUJTeOhaLutpiCLrI0uQEtpXSJg75zxQhzXhpTTW4KwwlyJT"
        + "T57vXLaYAAUidcnPcYapT-j4XRlVlpt7MDuFqjRirDYKvUMcRG"
        + "7keNuepqxHJIm72aEPx8qoKak_O2lU7UBelc4evr71DeCR9DCs"
        + "hjm_269Fv1vJZ5sGGxKv8SbD_Bw1Kv8qMiJrq7FnGbhiFpPOut"
        + "rQijTZCBaLTArAmbWrn_Ww2Hv9pY32RbzCe_kiG81GowXsRrfK"
        + "-V9IP4Mo1r09n6lytqb0cTSeBheoQNxer4_qMt0sEQ"
    )


def _gate2_token_ok() -> String:
    """THE CONTROL for §6's signed arms: a valid RS256 token under key 2."""
    return String(
        "eyJhbGciOiJSUzI1NiIsImtpZCI6ImtvbWlyYS1yczI1Ni1nYX"
        + "RlLTIiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJodHRwczovL2FjY"
        + "291bnRzLmdvb2dsZS5jb20iLCJhdWQiOiJodHRwczovL3JlZ2l"
        + "zdHJ5LmtvbWlyYS5leGFtcGxlLyIsInN1YiI6IjExNDcyNTAwM"
        + "DAwMDAwMDAwMDAwMiIsImV4cCI6MTc5ODc2MTYwMCwiaWF0Ijo"
        + "xNzk4NzU4MDAwfQ.JzNqAYhxQ2uzuR0wnyMWOeX9qznRbsZMG7"
        + "oF8furnn7vDfjTCB0NCVlqAIin4OeHmI-PWfVRdYPXkdzGKims"
        + "upNV7vj7_sZRn6A4pJe4GZjW2vVrCNCdGwttFxYr4yZTZ-f_VE"
        + "4LXYJ5EwwpMABSwVNc878mcW-05PipEtAyDrExU6HhJS8KSyz8"
        + "uEF61J1gMQauxR2DyJzLzlxvmRCeybteEekhQQGx2yUnrgHPW1"
        + "mBZ-gTfIe1bdGL9I6pKRSKVWF8E-Xa31tYAupZLuEYMm_LJ5Y8"
        + "1iVx4ehzDsT0E4XpT5zBAoMi9JNGpqosaTLnMak7EBYRuYZVyH"
        + "QDl8md7Q"
    )


def _gate2_token_alg_suffix() -> String:
    """`alg: \"RS256X\"`, RS256-SIGNED over this very header. Only an EXACT
    comparison refuses it; a `startswith` accepts it."""
    return String(
        "eyJhbGciOiJSUzI1NlgiLCJraWQiOiJrb21pcmEtcnMyNTYtZ2"
        + "F0ZS0yIiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2Fj"
        + "Y291bnRzLmdvb2dsZS5jb20iLCJhdWQiOiJodHRwczovL3JlZ2"
        + "lzdHJ5LmtvbWlyYS5leGFtcGxlLyIsInN1YiI6IjExNDcyNTAw"
        + "MDAwMDAwMDAwMDAwMiIsImV4cCI6MTc5ODc2MTYwMCwiaWF0Ij"
        + "oxNzk4NzU4MDAwfQ.Bre3OOLesILv0MPGiu_BcxC9GGYjTpgHv"
        + "Ter8EeFGGiweowJJ5AdulWJVqAsFluCCdXDxXZVgPk4Ny9Gxik"
        + "l3o2tTq7w2kMnfNqWnqZtUabgGkokB8200aLtMfuqGXnokIW4A"
        + "EJEDgpfjUovEFf6_PZnYpBhvnJ18CCCTEmZv_Wk0pX148KFX2l"
        + "LIpFg4M1BqOb9fLQluHD7BlUhELELdvDw-u1tLcOlhwTe4DeO9"
        + "UgbDoyYxZ0OKnq1fOzUuV5vbnDRalZgYuBZBxmtogfDuRXM38Y"
        + "wM1QfQs7KN23Zqtjdj8Lrs5EgYE5cT9UM7PYvyJzMo2zCSgBNH"
        + "s59kuneCg"
    )


def _gate2_token_typ_suffix() -> String:
    """`typ: \"JWTX\"` \u2014 the same one-token relaxation, on the other gate."""
    return String(
        "eyJhbGciOiJSUzI1NiIsImtpZCI6ImtvbWlyYS1yczI1Ni1nYX"
        + "RlLTIiLCJ0eXAiOiJKV1RYIn0.eyJpc3MiOiJodHRwczovL2Fj"
        + "Y291bnRzLmdvb2dsZS5jb20iLCJhdWQiOiJodHRwczovL3JlZ2"
        + "lzdHJ5LmtvbWlyYS5leGFtcGxlLyIsInN1YiI6IjExNDcyNTAw"
        + "MDAwMDAwMDAwMDAwMiIsImV4cCI6MTc5ODc2MTYwMCwiaWF0Ij"
        + "oxNzk4NzU4MDAwfQ.r2sK2NTPxa0kiBVJ9Zr5ESOF8IO-KlBR0"
        + "1V7W19l5tA8A0Pvkux4gpktsmABtNwC5dfItzTGAKYxVDNOD7f"
        + "dgxqvHJCVXAQZFt1yrrZnV02mzPluibQj6UXp7lqeIvNwok6ap"
        + "k72DJTgUKSIjas85fvCM1pmE0bvJMrLabldnULAyHnfMcbH4FV"
        + "zqWxIoY0SzQ-TJqNFZndvIN1yFXXSPGbNeen8ighnLCRZMkvVm"
        + "KJ3fJ6pf9rvI6PwkzMEeO3sJUi7hpibrFBFyjAqDZLIZ69jnQP"
        + "C56d4zKhMD8tAZlxaON3NaP4Z3xN-kS9_Sl_pKZcNa1s2v9EHJ"
        + "L72f4eyNA"
    )


def _gate2_token_kid_dup() -> String:
    """`kid` twice: `\"attacker\"` FIRST, the real kid second. A LAST-wins reader
    resolves the real key and verifies."""
    return String(
        "eyJhbGciOiJSUzI1NiIsImtpZCI6ImF0dGFja2VyIiwia2lkIj"
        + "oia29taXJhLXJzMjU2LWdhdGUtMiIsInR5cCI6IkpXVCJ9.eyJ"
        + "pc3MiOiJodHRwczovL2FjY291bnRzLmdvb2dsZS5jb20iLCJhd"
        + "WQiOiJodHRwczovL3JlZ2lzdHJ5LmtvbWlyYS5leGFtcGxlLyI"
        + "sInN1YiI6IjExNDcyNTAwMDAwMDAwMDAwMDAwMiIsImV4cCI6M"
        + "Tc5ODc2MTYwMCwiaWF0IjoxNzk4NzU4MDAwfQ.Vx9fS_iquoDC"
        + "eEnHn7mUWJoFRa6aK9Zzbm86hVW48dZYSeqlS7ydV0-w7vjbbe"
        + "FV3gBPgGLOqNHWIsFsaEzImPM55_XhqY22Y2d_7MLpxta-r1bf"
        + "uu9FrAon3cEESdGC5x5hawrZhzyOFB0kHxZMYJuyKaxqFvVZhf"
        + "6jHcIazJz83BjRSqWNWaTj0SjocI2DJYSL-tbK4yzyiJ7cql7Q"
        + "TiuLPhiv0jD6DslgSaR4V7SoP1sSzfHWj34K0AxGl8pbu9NLL4"
        + "LCF37XSr18MK1PMa1LxW9-TL3v_goUR1jikOAkXRMdmD4qTeVp"
        + "_GQBPMsV10bHFIFRfCtYk2zlR5Iggw"
    )


def _gate2_token_kid_dup_rev() -> String:
    """`kid` twice, the other order: the real kid FIRST. A FIRST-wins reader
    resolves the real key and verifies. Neither token alone catches both
    relaxations \u2014 the OTHER order is refused for the honest reason (the kid
    it resolves names no key), so it would pass a broken reader."""
    return String(
        "eyJhbGciOiJSUzI1NiIsImtpZCI6ImtvbWlyYS1yczI1Ni1nYX"
        + "RlLTIiLCJraWQiOiJhdHRhY2tlciIsInR5cCI6IkpXVCJ9.eyJ"
        + "pc3MiOiJodHRwczovL2FjY291bnRzLmdvb2dsZS5jb20iLCJhd"
        + "WQiOiJodHRwczovL3JlZ2lzdHJ5LmtvbWlyYS5leGFtcGxlLyI"
        + "sInN1YiI6IjExNDcyNTAwMDAwMDAwMDAwMDAwMiIsImV4cCI6M"
        + "Tc5ODc2MTYwMCwiaWF0IjoxNzk4NzU4MDAwfQ.SZEJwO2GgPSF"
        + "LSyjcPZSxM3NZAPsbcd-oudFkVWpO1j-JEz1fzwvbi_ubPkupD"
        + "qIoUf5bjVLRrJU1zy8BW2TrBKKxL78CTdBABfifmddmB4MHwiG"
        + "yrK5QoN0W5bZay7y-OVvNrXZzpfej-1Dbp2_9SWBKC_4a5BiRb"
        + "Lgg_-UWT_hv1V_GgibXUtRYjOSSG5H3oQDQU02obbR1nYk7FU2"
        + "hnbWXy8ogsAs2rnYEYDFU0LX2MN9JyzUMrOGjVPgybeLFoQxiG"
        + "_juWDGUZWfzb0391wAOu9EuXCis8Ww1dHqgN2xHAzQ4mK213jk"
        + "JSMhapcC44dhVG1VUflbiL2XWV4a7Q"
    )


def _gate2_token_alg_dup() -> String:
    """`alg` twice: `\"none\"` then `\"RS256\"`. A LAST-wins reader verifies it."""
    return String(
        "eyJhbGciOiJub25lIiwiYWxnIjoiUlMyNTYiLCJraWQiOiJrb2"
        + "1pcmEtcnMyNTYtZ2F0ZS0yIiwidHlwIjoiSldUIn0.eyJpc3Mi"
        + "OiJodHRwczovL2FjY291bnRzLmdvb2dsZS5jb20iLCJhdWQiOi"
        + "JodHRwczovL3JlZ2lzdHJ5LmtvbWlyYS5leGFtcGxlLyIsInN1"
        + "YiI6IjExNDcyNTAwMDAwMDAwMDAwMDAwMiIsImV4cCI6MTc5OD"
        + "c2MTYwMCwiaWF0IjoxNzk4NzU4MDAwfQ.nB4e0x5RMLqNGITks"
        + "VDyhM-TjC3NfaqJu_rkxv3rLm33JHFYnLTwwpI-aFTflh5hfSx"
        + "CzW6kQWCBpDqBlQvleGv-kT_5NA2nzCa0e8G3QxVh322odJwR8"
        + "aG-bWVCE9airVomm01R2-s-sf8uHF5Y6rlX2R446NUbNUTz_Ri"
        + "lYxeoO7KZHVTfWfWfot6hVeN4C8_MnjiJMxvfp2X2oSYVRAzSg"
        + "CA0K5R8RU7-6_aqMD9FaZKYBkOn7tfRIypo2XE3WHYJlpuJutd"
        + "wmN88_afhw_DYJEmSkKQ58GrJlrpV6ike9QycsCJog8_FRvQAB"
        + "vO14BdfLHhpHtxEG9M3fTaekA"
    )


def _gate2_token_alg_dup_rev() -> String:
    """`alg` twice: `\"RS256\"` then `\"none\"`. A FIRST-wins reader verifies it.
    Together with the token above this is the whole point: WHICHEVER way a
    reader resolves the repetition, one of these two is accepted, and a
    proxy in front of us that resolves the other way sees a different `alg`
    than we do."""
    return String(
        "eyJhbGciOiJSUzI1NiIsImFsZyI6Im5vbmUiLCJraWQiOiJrb2"
        + "1pcmEtcnMyNTYtZ2F0ZS0yIiwidHlwIjoiSldUIn0.eyJpc3Mi"
        + "OiJodHRwczovL2FjY291bnRzLmdvb2dsZS5jb20iLCJhdWQiOi"
        + "JodHRwczovL3JlZ2lzdHJ5LmtvbWlyYS5leGFtcGxlLyIsInN1"
        + "YiI6IjExNDcyNTAwMDAwMDAwMDAwMDAwMiIsImV4cCI6MTc5OD"
        + "c2MTYwMCwiaWF0IjoxNzk4NzU4MDAwfQ.OutGyKDlJxSKio7Yy"
        + "mmwK9ogWAtjMnffx59G0ZvrSpuYvAovQcE1Ove1z18zZnq4HPg"
        + "TSSmB6pi4eP3VqkwX4DGXLmGjtpe9v9-GdZ2NgX2bfflbum_eK"
        + "VDcWYy9cM_g78Ehb1o2BgRc-NWCSANKz0YMgx2HY9Mh_Fa8jSI"
        + "aBcD07QH2nbdkBkktIN5Av4MXfGZwchNCXYUrFrLK64znNXQtK"
        + "6zVP07rDxTgTau3clsj4dDBdOhBt0tBZMryioTMwYgn58g9Xyr"
        + "im48chdn9d4E8FzwNXKp0GpoIeIzx_kLY2-DaxIdeoxd4PB81v"
        + "pXTcptiQfA2slH9VKfvKxvwdQ"
    )


def test_the_jwks_splice_is_faithful() raises:
    """THE CONTROL FOR ALL OF §6's JWK-side arms.

    `_gate_jwks_with` rebuilds the §5 gate key's JWK by hand. If that rebuild
    is wrong in any way — a stray comma, a mangled modulus — the document
    parses to zero keys for a reason that has nothing to do with the member
    under test, and every refusal below passes for free. So: spliced with
    exactly the members `_gate_jwks()` already carries, it must parse to one
    key AND the §5 control token must verify against it.
    """
    var doc = _gate_jwks_with(
        String("\"alg\":\"RS256\",\"use\":\"sig\","), String("")
    )
    var keys = parse_rsa_jwks(doc)
    assert_equal(
        len(keys),
        1,
        "the splice helper MUST rebuild a usable key — if it does not, every"
        " §6 refusal below is vacuous",
    )
    assert_equal(len(keys[0].n_be), 256, "and it is the 2048-bit gate key")
    var got = verify_rs256_jws_against_jwks(_gate_token_ok(), doc)
    assert_true(
        Bool(got), "the §5 control token MUST verify against the rebuilt set"
    )
    assert_equal(got.value(), _gate_payload_json(), "byte for byte")


def test_a_jwk_labelled_for_another_alg_is_dropped_and_absent_alg_is_kept(
) raises:
    """`parse_rsa_jwks`'s stated floor: *`alg`, IF present, == "RS256" — an
    issuer that labels a key must be obeyed.*

    Without this test, deleting that gate outright leaves the whole suite
    GREEN. An issuer that publishes `"alg":"RS512"` has said what the key is
    for; using it to verify RS256 is us overruling the key's owner, and it is
    the same class of break as ignoring `crit`.

    BOTH HALVES ARE PINNED. The gate is conditional on presence — RFC 7517
    §4.4 makes `alg` OPTIONAL and the live Google set stamps it, but a set that
    omits it is well-formed — so a blanket refusal is a different defect and
    the second arm is what tells them apart.
    """
    var labelled = _gate_jwks_with(
        String("\"alg\":\"RS512\",\"use\":\"sig\","), String("")
    )
    assert_equal(
        len(parse_rsa_jwks(labelled)),
        0,
        "a JWK its own issuer labels `alg:RS512` MUST NOT enter the RS256"
        " trusted set",
    )
    assert_false(
        Bool(verify_rs256_jws_against_jwks(_gate_token_ok(), labelled)),
        "and the control token — genuinely signed by THIS key — MUST then be"
        " refused, because the key it names is not in the set",
    )
    var unlabelled = _gate_jwks_with(String("\"use\":\"sig\","), String(""))
    assert_equal(
        len(parse_rsa_jwks(unlabelled)),
        1,
        "a JWK with NO `alg` MUST still be usable (RFC 7517 §4.4 makes it"
        " optional) — the gate is conditional on presence, not a ban",
    )
    assert_true(
        Bool(verify_rs256_jws_against_jwks(_gate_token_ok(), unlabelled)),
        "and a token under it MUST verify",
    )


def test_a_jwk_published_for_encryption_is_dropped_and_absent_use_is_kept(
) raises:
    """`parse_rsa_jwks`'s stated floor: *`use`, IF present, == "sig" — an
    encryption key must not verify.*

    Without this test, deleting that gate leaves the whole suite GREEN. An
    RSA key published `"use":"enc"` is a key the issuer intends for key
    transport; accepting signatures under it is cross-protocol reuse of one
    keypair, which is exactly the situation the JWK `use` member exists to
    prevent.

    Both halves again: `use` is optional, so its absence must stay usable.
    """
    var enc = _gate_jwks_with(
        String("\"alg\":\"RS256\",\"use\":\"enc\","), String("")
    )
    assert_equal(
        len(parse_rsa_jwks(enc)),
        0,
        "a JWK published `use:enc` MUST NOT enter a signature-verification"
        " trusted set",
    )
    assert_false(
        Bool(verify_rs256_jws_against_jwks(_gate_token_ok(), enc)),
        "and the control token MUST then be refused",
    )
    var no_use = _gate_jwks_with(String("\"alg\":\"RS256\","), String(""))
    assert_equal(
        len(parse_rsa_jwks(no_use)),
        1,
        "a JWK with NO `use` MUST still be usable — conditional on presence",
    )
    assert_true(
        Bool(verify_rs256_jws_against_jwks(_gate_token_ok(), no_use)),
        "and a token under it MUST verify",
    )


def test_a_duplicate_member_name_in_a_jwk_is_refused_in_both_orders() raises:
    """`_member`'s duplicate-name refusal.

    `{"kid":"a","kid":"b"}` is legal JSON with no defined winner. Its own
    docstring calls two readers that pick differently "an authentication
    bypass waiting for a proxy to sit in front of us" — and, without this
    test, relaxing the refusal to LAST-WINS leaves the whole suite GREEN.

    ⚠ THE FIRST ARM IS THE DISCRIMINATING ONE, AND THE SECOND IS NOT A SECOND
    FALSIFIER. Under either relaxation, at PARSE
    level `len(keys) == 0` fails under ANY resolution — last-wins resolves the
    real kid and first-wins resolves `"attacker"`, and either way A KEY ENTERS
    THE SET — so the attacker-FIRST arm alone catches both mutants. The
    attacker-SECOND arm is kept for what it states, that neither position is
    privileged, and it is labelled so nobody counts it twice. The order that
    genuinely does need both spellings is the SIGNED header path, where the
    two directions are refused for different reasons — see
    `test_a_duplicate_header_member_is_refused_in_both_directions`.

    The third arm duplicates `n` with the SAME value twice, which pins that
    the refusal is about the NAME being repeated and not about the two values
    disagreeing — a reader that compared them and shrugged would be just as
    forkable by a reader that took the first.
    """
    var attacker_first = _gate_jwks_with(
        String("\"alg\":\"RS256\",\"use\":\"sig\",\"kid\":\"attacker\","),
        String(""),
    )
    assert_equal(
        len(parse_rsa_jwks(attacker_first)),
        0,
        "a JWK naming `kid` twice (attacker's first) MUST be refused, not"
        " resolved to the later one",
    )
    var attacker_last = _gate_jwks_with(
        String("\"alg\":\"RS256\",\"use\":\"sig\","),
        String("\"kid\":\"attacker\""),
    )
    assert_equal(
        len(parse_rsa_jwks(attacker_last)),
        0,
        "a JWK naming `kid` twice (attacker's second) MUST be refused, not"
        " resolved to the earlier one",
    )
    var dup_n = _gate_jwks_with(
        String("\"alg\":\"RS256\",\"use\":\"sig\","),
        String("\"n\":\"") + _gate_n_b64() + String("\""),
    )
    assert_equal(
        len(parse_rsa_jwks(dup_n)),
        0,
        "a JWK naming `n` twice MUST be refused even when the two spellings"
        " AGREE — the repetition is the defect",
    )


def test_gate2_control_a_validly_signed_token_verifies() raises:
    """THE CONTROL for §6's signed arms. §6 signs its own hostile headers with
    a second, independently generated key because this suite holds no private
    key for the §5 one. If this fails, the three refusals below are satisfiable
    by a broken fixture rather than by the gate."""
    var got = verify_rs256_jws_against_jwks(_gate2_token_ok(), _gate2_jwks())
    assert_true(
        Bool(got),
        "the §6 control token MUST verify — signature, key, kid and signature"
        " length are all correct by construction",
    )
    assert_equal(got.value(), _gate_payload_json(), "byte for byte")
    var keys = parse_rsa_jwks(_gate2_jwks())
    assert_equal(len(keys), 1, "the §6 JWK Set publishes exactly one key")
    assert_equal(len(keys[0].n_be), 256, "2048-bit modulus")


def test_the_alg_and_typ_comparisons_are_exact_not_prefix() raises:
    """One token per gate, each RS256-SIGNED OVER ITS OWN HEADER, whose value
    is the accepted one WITH A SUFFIX.

    §5 pins that `none` / `HS256` / `ES256` / `PS256` / `RS384` / `rs256` are
    refused — six values that share no prefix with `RS256`. Without this test,
    relaxing `alg.value() != RS256_ALG` to
    `not alg.value().startswith(RS256_ALG)` — a one-token change to the single
    line that carries the meaning — leaves the WHOLE suite GREEN, §5 included.
    A gate that says "begins with the right answer" is not an allowlist.
    """
    assert_false(
        Bool(
            verify_rs256_jws_against_jwks(
                _gate2_token_alg_suffix(), _gate2_jwks()
            )
        ),
        "alg:RS256X MUST be refused — the comparison is EQUALITY, not a"
        " prefix; this token's signature is valid over its own header",
    )
    assert_false(
        Bool(
            verify_rs256_jws_against_jwks(
                _gate2_token_typ_suffix(), _gate2_jwks()
            )
        ),
        "typ:JWTX MUST be refused for the same reason",
    )


def test_a_duplicate_header_member_is_refused_in_both_directions() raises:
    """The header side of the duplicate-name refusal, with valid signatures.

    All four tokens are RS256-SIGNED over the very headers described, so the
    signature, the key and the signature length are all correct and the
    reader's duplicate handling is the only thing left that can refuse them.

    ⚠ HERE BOTH ORDERS ARE REQUIRED, and this is where the parse-level test's
    pair is not. A token whose repetition resolves — under the relaxation being
    tested — to the REAL kid / to `RS256` verifies and the assertion fires; the
    other order resolves to `"attacker"` / to `"none"` and is refused for an
    honest reason, so it says nothing about the relaxation.
    `_member` relaxed to last-wins is caught only by the two
    `_dup` tokens, and relaxed to first-wins only by the two `_dup_rev` ones.

    `{"alg":"none","alg":"RS256"}` and its reverse are the break in its purest
    form: whichever way a reader resolves the repetition, one of the two is
    accepted — and a proxy in front of us resolving the other way reads a
    different `alg` than we do. That is why the answer is "no answer".
    """
    var toks = List[Tuple[String, String]]()
    toks.append((String("kid twice, attacker first"), _gate2_token_kid_dup()))
    toks.append(
        (String("kid twice, attacker second"), _gate2_token_kid_dup_rev())
    )
    toks.append((String("alg twice, none first"), _gate2_token_alg_dup()))
    toks.append(
        (String("alg twice, none second"), _gate2_token_alg_dup_rev())
    )
    for i in range(len(toks)):
        assert_false(
            Bool(verify_rs256_jws_against_jwks(toks[i][1], _gate2_jwks())),
            String("a header naming a member twice (")
            + toks[i][0]
            + String(
                ") MUST be refused, not resolved — the signature over this"
                " header is VALID, so the duplicate refusal is the only thing"
                " left"
            ),
        )


def main() raises:
    test_valid_rs256_token_verifies_against_its_jwks()
    test_parse_lifts_exactly_one_key_with_the_expected_kid()
    test_tampered_payload_fails()
    test_tampered_signature_fails()
    test_wrong_key_under_the_right_kid_fails()
    test_b64url_helper_agrees_with_the_real_header()
    test_alg_none_is_refused()
    test_missing_alg_is_refused()
    test_algorithm_confusion_es256_header_is_refused()
    test_algorithm_confusion_hs256_and_ps256_are_refused()
    test_an_ec_key_never_enters_the_rsa_key_set()
    test_an_es256_token_is_refused_even_with_the_right_ec_key()
    test_crit_header_is_refused()
    test_missing_or_unknown_kid_is_refused()
    test_wrong_typ_is_refused()
    test_structurally_bad_tokens_are_refused()
    test_empty_keyset_is_a_refusal_not_a_pass()
    test_duplicate_kid_in_the_set_is_refused()
    test_undecodable_modulus_is_dropped()
    test_degenerate_exponents_are_dropped()
    test_parses_the_live_google_jwk_set()
    test_live_google_kid_to_modulus_pairing_is_positional_order_independent()
    test_gate_control_a_validly_signed_token_verifies()
    test_signed_alg_none_is_refused_by_the_gate()
    test_signed_algorithm_confusion_is_refused_by_the_gate()
    test_signed_crit_is_refused_by_the_gate()
    test_signed_wrong_typ_is_refused_and_absent_typ_is_accepted()
    test_undersized_modulus_is_refused_and_would_otherwise_verify()
    test_oversized_modulus_is_refused()
    test_non_minimal_modulus_is_dropped_at_parse()
    test_the_es256_identity_path_is_not_reachable_from_here()
    test_the_jwks_splice_is_faithful()
    test_a_jwk_labelled_for_another_alg_is_dropped_and_absent_alg_is_kept()
    test_a_jwk_published_for_encryption_is_dropped_and_absent_use_is_kept()
    test_a_duplicate_member_name_in_a_jwk_is_refused_in_both_orders()
    test_gate2_control_a_validly_signed_token_verifies()
    test_the_alg_and_typ_comparisons_are_exact_not_prefix()
    test_a_duplicate_header_member_is_refused_in_both_directions()
    print("OK")
