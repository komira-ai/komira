# =============================================================================
# test_jwk_rfc_vectors.mojo: conformance against the RFC examples.
#
#   RFC 7517 Appendix A.1  the public EC P-256 and RSA keys: parse, member
#                          bytes, canonical render, and render -> parse
#                          round trip.
#   RFC 7517 Appendix A.2  the same keys with private members: refused, naming
#                          the first private member ("d").
#   RFC 7517 Appendix A.3  symmetric keys: refused (the "k" member).
#   RFC 8037 Appendix A.2  the public Ed25519 key: parse and round trip.
#   RFC 8037 Appendix A.1  the private Ed25519 key: refused.
#
# The documents are the RFC text with the display line breaks inside values
# removed (A.1 keeps its whitespace between tokens, including the space after
# `"n":`). The expected member bytes and the canonical render string were
# computed outside this package (Python's json and base64 modules), from the
# RFC text.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_encoding import hex_encode
from komira_jwks import (
    JWK_KTY_EC,
    JWK_KTY_RSA,
    parse_jwk,
    parse_jwk_set,
    render_jwk,
)


def _rfc_n() -> String:
    return (
        String("0vx7agoebGcQSuuPiLJXZptN9nndrQmbXEps2aiAFbWhM78LhWx4cbbfAAtV")
        + String("T86zwu1RK7aPFFxuhDR1L6tSoc_BJECPebWKRXjBZCiFV4n3oknjhMstn64t")
        + String("Z_2W-5JsGY4Hc5n9yBXArwl93lqt7_RN5w6Cf0h4QyQ5v-65YGjQR0_FDW2Q")
        + String("vzqY368QQMicAtaSqzs8KJZgnYb9c7d0zgdAZHzu6qMQvRL5hajrn1n91CbO")
        + String("pbISD08qNLyrdkt-bFTWhAI4vMQFh6WeZu0fM4lFd2NcRwr3XPksINHaQ-G_")
        + String("xBniIqbw0Ls1jF44-csFCur-kEgU8awapJzKnqDKgw")
    )


def _a2_d() -> String:
    return (
        String("X4cTteJY_gn4FYPsXB8rdXix5vwsg1FLN5E3EaG6RJoVH-HLLKD9M7dx5oo7")
        + String("GURknchnrRweUkC7hT5fJLM0WbFAKNLWY2vv7B6NqXSzUvxT0_YSfqijwp3R")
        + String("TzlBaCxWp4doFk5N2o8Gy_nHNKroADIkJ46pRUohsXywbReAdYaMwFs9tv8d")
        + String("_cPVY3i07a3t8MN6TNwm0dSawm9v47UiCl3Sk5ZiG7xojPLu4sbg1U2jx4IB")
        + String("TNBznbJSzFHK66jT8bgkuqsk0GjskDJk19Z4qwjwbsnn4j2WBii3RL-Us2lG")
        + String("VkY8fkFzme1z0HbIkfz0Y6mqnOYtqc0X4jfcKoAC8Q")
    )


def _a2_p() -> String:
    return (
        String("83i-7IvMGXoMXCskv73TKr8637FiO7Z27zv8oj6pbWUQyLPQBQxtPVnwD20R")
        + String("-60eTDmD2ujnMt5PoqMrm8RfmNhVWDtjjMmCMjOpSXicFHj7XOuVIYQyqVWl")
        + String("WEh6dN36GVZYk93N8Bc9vY41xy8B9RzzOGVQzXvNEvn7O0nVbfs")
    )


def _a2_q() -> String:
    return (
        String("3dfOR9cuYq-0S-mkFLzgItgMEfFzB2q3hWehMuG0oCuqnb3vobLyumqjVZQO")
        + String("1dIrdwgTnCdpYzBcOfW5r370AFXjiWft_NGEiovonizhKpo9VVS78TzFgxkI")
        + String("drecRezsZ-1kYd_s1qDbxtkDEgfAITAG9LUnADun4vIcb6yelxk")
    )


def _a2_dp() -> String:
    return (
        String("G4sPXkc6Ya9y8oJW9_ILj4xuppu0lzi_H7VTkS8xj5SdX3coE0oimYwxIi2e")
        + String("mTAue0UOa5dpgFGyBJ4c8tQ2VF402XRugKDTP8akYhFo5tAA77Qe_NmtuYZc")
        + String("3C3m3I24G2GvR5sSDxUyAN2zq8Lfn9EUms6rY3Ob8YeiKkTiBj0")
    )


def _a2_dq() -> String:
    return (
        String("s9lAH9fggBsoFR8Oac2R_E2gw282rT2kGOAhvIllETE1efrA6huUUvMfBcMp")
        + String("n8lqeW6vzznYY5SSQF7pMdC_agI3nG8Ibp1BUb0JUiraRNqUfLhcQb_d9GF4")
        + String("Dh7e74WbRsobRonujTYN1xCaP6TO61jvWrX-L18txXw494Q_cgk")
    )


def _a2_qi() -> String:
    return (
        String("GyM_p6JrXySiz1toFgKbWV-JdI3jQ4ypu9rbMWx3rQJBfmt0FoYzgUIZEVFE")
        + String("cOqwemRN81zoDAaa-Bk0KWNGDjJHZDdDmFhW3AN7lI-puxk_mHZGJ11rxyR8")
        + String("O55XLSe3SPmRfKwZI6yU24ZxvQKFYItdldUKGzO6Ia6zTKhAVRU")
    )


comptime EC_X = "MKBCTNIcKUSDii11ySs3526iDZ8AiTo7Tu6KPAqv7D4"
comptime EC_Y = "4Etl6SRW2YiLUrN5vfvVHuhp7x8PxltmWWlbbM4IFyM"
comptime EC_D = "870MB6gfuTJ4HtUnUvYMyJpr5eUZNP4Bk43bVdj3eAE"
comptime EC_X_HEX = "30a0424cd21c2944838a2d75c92b37e76ea20d9f00893a3b4eee8a3c0aafec3e"
comptime EC_Y_HEX = "e04b65e92456d9888b52b379bdfbd51ee869ef1f0fc65b6659695b6cce081723"
comptime OKP_X = "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
comptime OKP_D = "nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A"
comptime OKP_X_HEX = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
comptime RSA_KID = "2011-04-29"


def _rfc7517_a1() -> String:
    return (
        String('{"keys":\n  [\n    {"kty":"EC",\n     "crv":"P-256",\n')
        + '     "x":"' + EC_X + '",\n'
        + '     "y":"' + EC_Y + '",\n'
        + '     "use":"enc",\n     "kid":"1"},\n\n'
        + '    {"kty":"RSA",\n     "n": "' + _rfc_n() + '",\n'
        + '     "e":"AQAB",\n     "alg":"RS256",\n'
        + '     "kid":"' + RSA_KID + '"}\n  ]\n}'
    )


def _rfc7517_a2() -> String:
    return (
        String('{"keys":[{"kty":"EC","crv":"P-256",')
        + '"x":"' + EC_X + '","y":"' + EC_Y + '","d":"' + EC_D + '",'
        + '"use":"enc","kid":"1"},'
        + _rfc7517_a2_rsa()
        + "]}"
    )


def _rfc7517_a2_rsa() -> String:
    return (
        String('{"kty":"RSA","n":"') + _rfc_n() + '","e":"AQAB",'
        + '"d":"' + _a2_d() + '","p":"' + _a2_p() + '","q":"' + _a2_q()
        + '","dp":"' + _a2_dp() + '","dq":"' + _a2_dq() + '","qi":"'
        + _a2_qi() + '","alg":"RS256","kid":"' + RSA_KID + '"}'
    )


def _rfc7517_a3() -> String:
    return (
        String('{"keys":[{"kty":"oct","alg":"A128KW",')
        + '"k":"GawgguFyGrWKav7AX4VKUg"},'
        + '{"kty":"oct","k":"AyM1SysPpbyDfgZld3umj1qzKObwVMkoqQ-EstJQLr_T-1qS0gZH75'
        + 'aKtMN3Yj0iPS4hcgUuTwjAzZr1Z9CAow",'
        + '"kid":"HMAC key used in JWS spec Appendix A.1 example"}]}'
    )


def _canonical_a1() -> String:
    return (
        String('{"keys":[{"kty":"EC","crv":"P-256","use":"enc","kid":"1",')
        + '"x":"' + EC_X + '","y":"' + EC_Y + '"},'
        + '{"kty":"RSA","alg":"RS256","kid":"' + RSA_KID + '",'
        + '"n":"' + _rfc_n() + '","e":"AQAB"}]}'
    )


def _err_of_set(doc: String) -> String:
    try:
        _ = parse_jwk_set(doc)
    except e:
        return String(e)
    return String("")


def _err_of_key(doc: String) -> String:
    try:
        _ = parse_jwk(doc)
    except e:
        return String(e)
    return String("")


def test_rfc7517_a1_parses_both_keys() raises:
    var s = parse_jwk_set(_rfc7517_a1())
    assert_equal(len(s.keys), 2)
    assert_equal(len(s.skipped), 0)
    ref ec = s.keys[0]
    assert_equal(ec.kty(), JWK_KTY_EC)
    assert_equal(ec.crv(), "P-256")
    var ex = ec.x()
    var ey = ec.y()
    assert_equal(hex_encode(Span(ex)), EC_X_HEX)
    assert_equal(hex_encode(Span(ey)), EC_Y_HEX)
    assert_equal(ec.key_use().value(), "enc")
    assert_equal(ec.kid().value(), "1")
    assert_true(not ec.alg())
    ref rsa = s.keys[1]
    assert_equal(rsa.kty(), JWK_KTY_RSA)
    assert_equal(rsa.crv(), "")
    assert_equal(len(rsa.n()), 256)
    var n = rsa.n()
    assert_equal(hex_encode(Span(n)[0:2]), "d2fc")
    assert_equal(hex_encode(Span(n)[254:256]), "ca83")
    var e = rsa.e()
    assert_equal(hex_encode(Span(e)), "010001")
    assert_equal(rsa.alg().value(), "RS256")
    assert_equal(rsa.kid().value(), RSA_KID)
    assert_true(not rsa.key_use())
    assert_equal(s.index_of_kid(RSA_KID).value(), 1)
    assert_equal(s.index_of_kid("1").value(), 0)
    assert_true(not s.index_of_kid("2"))


def test_rfc7517_a1_round_trip() raises:
    var s = parse_jwk_set(_rfc7517_a1())
    var rendered = s.render()
    assert_equal(rendered, _canonical_a1())
    var again = parse_jwk_set(rendered)
    assert_equal(len(again.keys), 2)
    assert_true(again.keys[0] == s.keys[0])
    assert_true(again.keys[1] == s.keys[1])
    assert_equal(again.render(), rendered)


def test_rfc7517_a2_private_keys_refused() raises:
    assert_equal(
        _err_of_set(_rfc7517_a2()),
        "JwksError: key 0 carries the private member \"d\"; a published key"
        " holds public members only",
    )
    # The RSA key alone: its first private member is also "d".
    assert_equal(
        _err_of_set(String('{"keys":[') + _rfc7517_a2_rsa() + "]}"),
        "JwksError: key 0 carries the private member \"d\"; a published key"
        " holds public members only",
    )


def test_rfc7517_a3_symmetric_keys_refused() raises:
    assert_equal(
        _err_of_set(_rfc7517_a3()),
        "JwksError: key 0 carries the private member \"k\"; a published key"
        " holds public members only",
    )


def test_rfc8037_a2_public_key_round_trip() raises:
    var doc = String('{"kty":"OKP","crv":"Ed25519",\n"x":"') + OKP_X + '"}'
    var k = parse_jwk(doc)
    assert_equal(k.crv(), "Ed25519")
    var kx = k.x()
    assert_equal(hex_encode(Span(kx)), OKP_X_HEX)
    assert_true(not k.kid())
    var rendered = render_jwk(k)
    assert_equal(
        rendered, String('{"kty":"OKP","crv":"Ed25519","x":"') + OKP_X + '"}'
    )
    assert_true(parse_jwk(rendered) == k)


def test_rfc8037_a1_private_key_refused() raises:
    var doc = (
        String('{"kty":"OKP","crv":"Ed25519",\n"d":"')
        + OKP_D
        + '",\n"x":"'
        + OKP_X
        + '"}'
    )
    assert_equal(
        _err_of_key(doc),
        "JwksError: the key carries the private member \"d\"; a published key"
        " holds public members only",
    )


def main() raises:
    test_rfc7517_a1_parses_both_keys()
    test_rfc7517_a1_round_trip()
    test_rfc7517_a2_private_keys_refused()
    test_rfc7517_a3_symmetric_keys_refused()
    test_rfc8037_a2_public_key_round_trip()
    test_rfc8037_a1_private_key_refused()
    print("test_jwk_rfc_vectors: OK")
