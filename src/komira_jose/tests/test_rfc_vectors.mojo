# =============================================================================
# test_rfc_vectors.mojo: the published JWS examples, byte for byte.
# =============================================================================
#
#   RFC 7515 appendix A.2  RS256, no kid       verifies (single_key)
#   RFC 7515 appendix A.3  ES256, no kid       verifies (single_key)
#   RFC 8037 appendix A.4  EdDSA (Ed25519)     verifies (single_key)
#   RFC 7520 section 4.1   RS256 with a kid    verifies through a JWK Set
#   RFC 7515 appendix A.1  HS256               refused by name
#   RFC 7515 appendix A.4  ES512               refused: not the pinned alg
#   RFC 7515 appendix A.5  alg none            refused (empty signature, and
#                                              by name once a signature is
#                                              appended)
#
# Each verifying vector is also refused by a verifier pinned to each other
# algorithm, with the header-gate reason (an EdDSA header never reaches an
# ES256 verifier's key work), and with one payload byte changed.
#
# The token and key literals are copied from the RFC texts with line breaks
# removed (rfc-editor.org plain text); the payload each must yield is written
# out in full. RFC 7520 figure 13 is also Wycheproof's tcId 345.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_encoding import base64_url_decode_nopad
from komira_jose import JwsVerifier
from komira_jwks import Jwk, parse_jwk_set


def _a1_token() -> String:
    return String(
        "eyJ0eXAiOiJKV1QiLA0KICJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJ"
        + "leHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp"
        + "0cnVlfQ.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    )


def _a2_token() -> String:
    return String(
        "eyJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODA"
        + "sDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ.cC4hiUPoj9Ee"
        + "tdgtv3hF80EGrhuB__dzERat0XF9g2VtQgr9PJbu3XOiZj5RZmh7AAuHIm4Bh-0Q"
        + "c_lF5YKt_O8W2Fp5jujGbds9uJdbF9CUAr7t1dnZcAcQjbKBYNX4BAynRFdiuB--"
        + "f_nZLgrnbyTyWzO75vRK5h6xBArLIARNPvkSjtQBMHlb1L07Qe7K0GarZRmB_eSN"
        + "9383LcOLn6_dO--xi12jzDwusC-eOkHWEsqtFZESc6BfI7noOPqvhJ1phCnvWh6I"
        + "eYI2w9QOYEUipUTI8np6LbgGY9Fs98rqVt5AXLIhWkWywlVmtVrBp0igcN_IoypG"
        + "lUPQGe77Rw"
    )


def _a2_n() -> String:
    return String(
        "ofgWCuLjybRlzo0tZWJjNiuSfb4p4fAkd_wWJcyQoTbji9k0l8W26mPddxHmfHQp"
        + "-Vaw-4qPCJrcS2mJPMEzP1Pt0Bm4d4QlL-yRT-SFd2lZS-pCgNMsD1W_YpRPEwOW"
        + "vG6b32690r2jZ47soMZo9wGzjb_7OMg0LOL-bSf63kpaSHSXndS5z5rexMdbBYUs"
        + "LA9e-KXBdQOS-UTo7WTBEMa2R2CapHg665xsmtdVMTBQY4uDZlxvb3qCo5ZwKh9k"
        + "G4LT6_I5IhlJH7aGhyxXFvUK-DWNmoudF8NAco9_h9iaGNj8q2ethFkMLs91kzk2"
        + "PAcDTW9gb54h4FRWyuXpoQ"
    )


def _a3_token() -> String:
    return String(
        "eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODA"
        + "sDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ.DtEhU3ljbEg8"
        + "L38VWAfUAqOyKAM6-Xx-F4GawxaepmXFCgfTjDxw5djxLa8ISlSApmWQxfKTUJqP"
        + "P3-Kg6NU1Q"
    )


def _a4_token() -> String:
    return String(
        "eyJhbGciOiJFUzUxMiJ9.UGF5bG9hZA.AdwMgeerwtHoh-l192l60hp9wAHZFVJb"
        + "LfD_UxMi70cwnZOYaRI1bKPWROc-mZZqwqT2SI-KGDKB34XO0aw_7XdtAG8GaSwF"
        + "KdCAPZgoXD2YBJZCPEX3xKpRwcdOO8KpEHwJjyqOgzDO7iKvU8vcnwNrmxYbSW9E"
        + "RBXukOXolLzeO_Jn"
    )


def _rfc8037_a4_token() -> String:
    return String(
        "eyJhbGciOiJFZERTQSJ9.RXhhbXBsZSBvZiBFZDI1NTE5IHNpZ25pbmc.hgyY0il"
        + "_MGCjP0JzlnLWG1PPOt7-09PGcvMg3AIbQR6dWbhijcNR4ki4iylGjg5BhVsPt9g"
        + "7sVvpAr_MuM0KAg"
    )


def _rfc7520_figure13_token() -> String:
    return String(
        "eyJhbGciOiJSUzI1NiIsImtpZCI6ImJpbGJvLmJhZ2dpbnNAaG9iYml0b24uZXhh"
        + "bXBsZSJ9.SXTigJlzIGEgZGFuZ2Vyb3VzIGJ1c2luZXNzLCBGcm9kbywgZ29pbmc"
        + "gb3V0IHlvdXIgZG9vci4gWW91IHN0ZXAgb250byB0aGUgcm9hZCwgYW5kIGlmIHl"
        + "vdSBkb24ndCBrZWVwIHlvdXIgZmVldCwgdGhlcmXigJlzIG5vIGtub3dpbmcgd2h"
        + "lcmUgeW91IG1pZ2h0IGJlIHN3ZXB0IG9mZiB0by4.MRjdkly7_-oTPTS3AXP41iQ"
        + "IGKa80A0ZmTuV5MEaHoxnW2e5CZ5NlKtainoFmKZopdHM1O2U4mwzJdQx996ivp8"
        + "3xuglII7PNDi84wnB-BDkoBwA78185hX-Es4JIwmDLJK3lfWRa-XtL0RnltuYv74"
        + "6iYTh_qHRD68BNt1uSNCrUCTJDt5aAE6x8wW1Kt9eRo4QPocSadnHXFxnt8Is9Uz"
        + "pERV0ePPQdLuW3IS_de3xyIrDaLGdjluPxUAhb6L2aXic1U12podGU0KLUQSE_oI"
        + "-ZnmKJ3F4uOZDnd6QZWJushZ41Axf_fcIe8u9ipH84ogoree7vjbU5y18kDquDg"
    )


def _rfc7520_figure3_n() -> String:
    return String(
        "n4EPtAOCc9AlkeQHPzHStgAbgs7bTZLwUBZdR8_KuKPEHLd4rHVTeT-O-XV2jRoj"
        + "dNhxJWTDvNd7nqQ0VEiZQHz_AJmSCpMaJMRBSFKrKb2wqVwGU_NsYOYL-QtiWN2l"
        + "bzcEe6XC0dApr5ydQLrHqkHHig3RBordaZ6Aj-oBHqFEHYpPe7Tpe-OfVfHd1E6c"
        + "S6M1FZcD1NNLYD5lFHpPI9bTwJlsde3uhGqC0ZCuEHg8lhzwOHrtIQbS0FVbb9k3"
        + "-tVTU4fg_3L_vniUFAKwuCLqKnS2BYwdq_mzSnbLY7h_qixoR7jig3__kRhuaxwU"
        + "kRz5iaiQkqgc5gHdrNP5zw"
    )


comptime A3_X = "f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU"
comptime A3_Y = "x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0"
comptime RFC8037_X = "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
comptime RFC7515_PAYLOAD = (
    '{"iss":"joe",\r\n "exp":1300819380,\r\n "http://example.com/is_root":true}'
)


def _d(s: String) raises -> List[UInt8]:
    return base64_url_decode_nopad(s)


def _a2_key() raises -> Jwk:
    var n = _d(_a2_n())
    var e = _d("AQAB")
    return Jwk.rsa(Span(n), Span(e))


def _a3_key() raises -> Jwk:
    var x = _d(A3_X)
    var y = _d(A3_Y)
    return Jwk.ec_p256(Span(x), Span(y))


def _ed_key() raises -> Jwk:
    var x = _d(RFC8037_X)
    return Jwk.ed25519(Span(x))


def _rfc7520_set() raises -> String:
    # RFC 7520 figure 3, whitespace removed.
    return (
        String('{"keys":[{"kty":"RSA","kid":"bilbo.baggins@hobbiton.example",')
        + '"use":"sig","n":"'
        + _rfc7520_figure3_n()
        + '","e":"AQAB"}]}'
    )


def _text(b: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(b)):
        out += chr(Int(b[i]))
    return out


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _err(v: JwsVerifier, token: String) -> String:
    try:
        _ = v.verify(token)
    except e:
        return String(e)
    return String("")


def _tamper_payload(token: String) -> String:
    """The token with its first payload character changed (A <-> B), so the
    signing input differs by one byte and the payload is still base64url."""
    var b = token.as_bytes()
    var out = String("")
    var dots = 0
    var done = False
    for i in range(len(b)):
        var c = b[i]
        if not done and dots == 1:
            c = UInt8(ord("B")) if c != UInt8(ord("B")) else UInt8(ord("C"))
            done = True
        if b[i] == UInt8(ord(".")):
            dots += 1
        out += chr(Int(c))
    return out


def test_rfc7515_a2_rs256_verifies() raises:
    # Catches: RS256 over a re-encoded signing input, a wrong exponent read,
    # or the RS256 arm calling another primitive.
    var v = JwsVerifier.single_key("RS256", _a2_key())
    var got = v.verify(_a2_token())
    assert_equal(_text(got.payload()), RFC7515_PAYLOAD)
    assert_equal(got.alg(), "RS256")
    assert_true(not got.kid(), "A.2 has no kid")
    assert_true(not got.typ(), "A.2 has no typ")
    assert_equal(
        _err(v, _tamper_payload(_a2_token())),
        "JoseError: the signature does not verify",
    )


def test_rfc7515_a3_es256_verifies() raises:
    # Catches: ES256 fed a DER signature or a hashed-twice input, or x and y
    # swapped when the 64-byte public key is built.
    var v = JwsVerifier.single_key("ES256", _a3_key())
    var got = v.verify(_a3_token())
    assert_equal(_text(got.payload()), RFC7515_PAYLOAD)
    assert_equal(got.alg(), "ES256")
    assert_equal(
        _err(v, _tamper_payload(_a3_token())),
        "JoseError: the signature does not verify",
    )


def test_rfc8037_a4_eddsa_verifies() raises:
    # Catches: EdDSA verified over the payload instead of the signing input.
    var v = JwsVerifier.single_key("EdDSA", _ed_key())
    var got = v.verify(_rfc8037_a4_token())
    assert_equal(_text(got.payload()), "Example of Ed25519 signing")
    assert_equal(got.alg(), "EdDSA")
    assert_equal(
        _err(v, _tamper_payload(_rfc8037_a4_token())),
        "JoseError: the signature does not verify",
    )


def test_rfc7520_4_1_rs256_with_kid_through_a_set() raises:
    # Catches: kid selection that misses a present key, or a payload decoded
    # as anything but the signed bytes (it holds U+2019, 3 bytes in UTF-8).
    var v = JwsVerifier("RS256", parse_jwk_set(_rfc7520_set()))
    var got = v.verify(_rfc7520_figure13_token())
    var want = _bytes_of(
        String("It’s a dangerous business, Frodo, going out your door. You step onto")
        + " the road, and if you don't keep your feet, there’s no knowing where"
        + " you might be swept off to."
    )
    var p = got.payload()
    assert_equal(len(p), len(want))
    for i in range(len(p)):
        assert_equal(p[i], want[i])
    assert_equal(got.kid().value(), "bilbo.baggins@hobbiton.example")


def test_each_vector_refused_by_every_other_algorithm() raises:
    # Catches: a verifier that dispatches on the header's alg instead of its
    # pinned one (an EdDSA header reaching an ES256 verifier, and so on).
    var es = JwsVerifier.single_key("ES256", _a3_key())
    var ed = JwsVerifier.single_key("EdDSA", _ed_key())
    var rs = JwsVerifier.single_key("RS256", _a2_key())
    comptime WRONG = "JoseError: alg is not the pinned algorithm"
    assert_equal(_err(es, _rfc8037_a4_token()), WRONG)
    assert_equal(_err(es, _a2_token()), WRONG)
    assert_equal(_err(ed, _a3_token()), WRONG)
    assert_equal(_err(ed, _a2_token()), WRONG)
    assert_equal(_err(rs, _a3_token()), WRONG)
    assert_equal(_err(rs, _rfc8037_a4_token()), WRONG)


def test_rfc7515_a1_a4_a5_refused() raises:
    var rs = JwsVerifier.single_key("RS256", _a2_key())
    var es = JwsVerifier.single_key("ES256", _a3_key())
    # A.1: HS256 (with typ JWT and a CRLF in the header) is refused by name.
    assert_equal(_err(rs, _a1_token()), "JoseError: an HMAC alg (HS*) is refused")
    # A.4: ES512 is not ES256.
    assert_equal(
        _err(es, _a4_token()), "JoseError: alg is not the pinned algorithm"
    )
    # A.5: the unsecured JWS has an empty signature segment.
    var A5 = (
        String("eyJhbGciOiJub25lIn0.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQog")
        + "Imh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ."
    )
    assert_equal(_err(es, A5), "JoseError: the signature segment is empty")
    # With a signature appended, `none` is refused by name.
    assert_equal(_err(es, A5 + "AAAA"), "JoseError: alg none is refused")


def main() raises:
    test_rfc7515_a2_rs256_verifies()
    test_rfc7515_a3_es256_verifies()
    test_rfc8037_a4_eddsa_verifies()
    test_rfc7520_4_1_rs256_with_kid_through_a_set()
    test_each_vector_refused_by_every_other_algorithm()
    test_rfc7515_a1_a4_a5_refused()
    print("test_rfc_vectors: OK")
