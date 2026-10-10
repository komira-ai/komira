# =============================================================================
# test_rs256_third_party.mojo: RS256 tokens and key sets from outside this
#   repository, through komira_jwks' parser and komira_jose's verifier.
# =============================================================================
#
#   * a Google-metadata-shaped RS256 ID token and the JWK Set publishing its
#     key, generated once with python-cryptography (OpenSSL), an
#     implementation independent of the one under test: it verifies and
#     yields its payload byte for byte; a changed payload or signature
#     character, or a different modulus published under the same kid, does
#     not verify;
#   * a valid ES256 token under the same kid with its EC JWK Set: it
#     verifies under an ES256 verifier (the control), is refused by an RS256
#     verifier over either set, and an RS256 verifier cannot be built over
#     the EC set;
#   * Google's JWK Set as published, whose members come in a different order
#     in every entry: all four RSA keys are read, each kid paired with its
#     own modulus (a reader that took "the n after the kid" would pair a kid
#     with the next entry's modulus).
#
# These vectors moved here from komira_crypto's RS256 JWK Set verifier when
# komira_http_auth began verifying through komira_jose and that verifier was
# removed.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_jose import JwsVerifier
from komira_jwks import JWK_KTY_RSA, parse_jwk_set


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


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _err(v: JwsVerifier, token: String) -> String:
    try:
        _ = v.verify(token)
    except e:
        return String(e)
    return String("verified")


def _replace_last(s: String, at_end_of: Int) -> String:
    """`s` with the byte before offset `at_end_of` replaced by another
    base64url character."""
    var b = s.as_bytes()
    var out = String("")
    for i in range(len(b)):
        var c = b[i]
        if i == at_end_of - 1:
            c = UInt8(ord("A")) if c != UInt8(ord("A")) else UInt8(ord("B"))
        out += chr(Int(c))
    return out


def test_google_shaped_token_verifies() raises:
    # Catches: RS256 over a re-encoded signing input, a modulus or exponent
    # read wrongly from a JWK, or a payload that is not the signed bytes.
    var v = JwsVerifier("RS256", parse_jwk_set(_kat_jwks()))
    var got = v.verify(_kat_token())
    var want = _bytes_of(_kat_payload_json())
    var p = got.payload()
    assert_equal(len(p), len(want))
    for i in range(len(p)):
        assert_equal(p[i], want[i])
    assert_equal(got.kid().value(), KAT_KID)
    assert_equal(got.typ().value(), "JWT")


def test_a_changed_payload_or_signature_does_not_verify() raises:
    # Catches: a signature check skipped or run over the wrong bytes.
    var v = JwsVerifier("RS256", parse_jwk_set(_kat_jwks()))
    var tok = _kat_token()
    var d2 = tok.rfind(".")
    comptime NO = "JoseError: the signature does not verify"
    assert_equal(_err(v, _replace_last(tok, d2)), NO)
    assert_equal(_err(v, _replace_last(tok, tok.byte_length())), NO)


def test_another_modulus_under_the_same_kid_does_not_verify() raises:
    # Catches: a key chosen by anything but its own modulus (a key cached by
    # kid from another set, say).
    var ks = parse_jwk_set(_wrong_key_jwks())
    assert_equal(len(ks.keys), 1)
    assert_equal(ks.keys[0].kid().value(), KAT_KID)
    var v = JwsVerifier("RS256", ks)
    assert_equal(_err(v, _kat_token()), "JoseError: the signature does not verify")


def test_an_es256_token_never_reaches_an_rs256_key() raises:
    # Catches: a verifier that runs the algorithm the header names.
    var es = JwsVerifier("ES256", parse_jwk_set(_ec_jwks()))
    _ = es.verify(_ec_token())
    var rs = JwsVerifier("RS256", parse_jwk_set(_kat_jwks()))
    assert_equal(
        _err(rs, _ec_token()), "JoseError: alg is not the pinned algorithm"
    )
    var built = String("built")
    try:
        _ = JwsVerifier("RS256", parse_jwk_set(_ec_jwks()))
    except e:
        built = String(e)
    assert_equal(built, "JoseError: the key set holds no key for RS256")


def test_the_published_google_set_pairs_each_kid_with_its_modulus() raises:
    # Catches: a positional reader, and any key of the set dropped.
    var ks = parse_jwk_set(_live_google_jwks())
    var kids = List[String]()
    kids.append("8ff13a6fcdabf306712e58f35668a04eb5a5fae1")
    kids.append("d6a0e659c3392d9e592a4b0ad88e7b2b88076909")
    kids.append("943a3a5d7d919625a454e489b75c29adab57acba")
    kids.append("f10f87405a979c1df36df26606734f33cd85c271")
    # The first 8 bytes of each modulus, hex, read out of the document by an
    # independent parser.
    var heads = List[String]()
    heads.append("da4b9ab3ab7e3e49")
    heads.append("c48dc89d73b6905a")
    heads.append("a48a67cc0d9ecf21")
    heads.append("e2b639bb064ad5d4")
    assert_equal(len(ks.keys), 4)
    assert_equal(len(ks.skipped), 0)
    comptime HEX = "0123456789abcdef"
    var hx = HEX.as_bytes()
    for i in range(4):
        ref k = ks.keys[i]
        assert_equal(k.kty(), JWK_KTY_RSA)
        assert_equal(k.kid().value(), kids[i])
        var n = k.n()
        assert_equal(len(n), 256)
        var e = k.e()
        assert_equal(len(e), 3)
        assert_true(e[0] == 1 and e[1] == 0 and e[2] == 1, "e = AQAB")
        var h = String("")
        for b in range(8):
            h += chr(Int(hx[Int(n[b]) >> 4]))
            h += chr(Int(hx[Int(n[b]) & 15]))
        assert_equal(h, heads[i], kids[i])
    # Every key of the set is a usable RS256 key.
    _ = JwsVerifier("RS256", ks)


def main() raises:
    test_google_shaped_token_verifies()
    test_a_changed_payload_or_signature_does_not_verify()
    test_another_modulus_under_the_same_kid_does_not_verify()
    test_an_es256_token_never_reaches_an_rs256_key()
    test_the_published_google_set_pairs_each_kid_with_its_modulus()
    print("test_rs256_third_party: OK")
