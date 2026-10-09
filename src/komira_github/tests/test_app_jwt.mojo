# =============================================================================
# komira_github/tests/test_app_jwt.mojo -- the App JWT's shape and GitHub's
#   time window.
# =============================================================================
#
# The key is the repository's RSA-2048 PKCS#8 test key (komira_http_core's TLS
# fixture), declared as this test's data. That the signature verifies under
# the key's public half is tested in komira_github_fake (its App check
# verifies every JWT this package mints).
#
# What each test proves, and the defect it catches:
#   * test_mint_shape: header and claims decode to exactly
#     {"alg":"RS256","typ":"JWT"} and {"iat":T-60,"exp":T+540,"iss":...}, the
#     token is three segments, and AppJwt carries the same times. Catches a
#     missing backdate, an `exp` at or past GitHub's 10 minutes, a claim
#     written under another name.
#   * test_window_edges: `check_app_jwt_window` at every edge: exp == now is
#     EXPIRED and refused, exp == now + 1 is accepted; iat == now accepted,
#     iat == now + 1 refused; exp - now == 600 accepted, 601 refused;
#     exp - iat == 600 accepted, 601 refused. Catches
#     `<=`/`<` swapped on each bound, and a bound dropped.
#   * test_remint_margin: a cached JWT is re-minted from exp - 60 on
#     (exp - 61 is kept), and when its iat is after now (the clock went
#     back). Catches re-minting only at expiry (a JWT that expires in flight).
#   * test_credentials_refused: an issuer outside [A-Za-z0-9.]{1,64} (a quote
#     that would break the claims JSON, empty, 65 bytes) and an empty key.
# =============================================================================

from std.pathlib import Path
from std.testing import assert_equal, assert_false, assert_true

from komira_crypto import rsa_pkcs8_der_from_pem
from komira_encoding import base64_url_decode_nopad
from komira_github import (
    APP_JWT_HEADER_JSON,
    AppCredentials,
    AppJwt,
    app_jwt_needs_remint,
    check_app_jwt_window,
    github_error_kind,
    mint_app_jwt,
)


comptime ISSUER = "Iv23liTESTCLIENT"
comptime NOW: Int64 = 1_800_000_000


def _key() raises -> List[UInt8]:
    return rsa_pkcs8_der_from_pem(
        Path("src/komira_http_core/tests/fixtures/tls/leaf_key.pem").read_text()
    )


def _segments(token: String) -> List[String]:
    var out = List[String]()
    var b = token.as_bytes()
    var start = 0
    for i in range(len(b) + 1):
        if i == len(b) or b[i] == UInt8(ord(".")):
            out.append(String(token[byte=start:i]))
            start = i + 1
    return out^


def _decoded(seg: String) raises -> String:
    var raw = base64_url_decode_nopad(seg)
    return String(unsafe_from_utf8=Span(raw))


def test_mint_shape() raises:
    var creds = AppCredentials(String(ISSUER), _key())
    var jwt = mint_app_jwt(creds, NOW)
    var segs = _segments(jwt.token)
    assert_equal(len(segs), 3, "three segments")
    assert_equal(_decoded(segs[0]), String(APP_JWT_HEADER_JSON))
    assert_equal(_decoded(segs[0]), String('{"alg":"RS256","typ":"JWT"}'))
    assert_equal(
        _decoded(segs[1]),
        String('{"iat":1799999940,"exp":1800000540,"iss":"Iv23liTESTCLIENT"}'),
    )
    assert_equal(jwt.iat, NOW - 60)
    assert_equal(jwt.exp, NOW + 540)
    assert_equal(len(base64_url_decode_nopad(segs[2])), 256, "an RSA-2048 signature")
    print("  test_mint_shape PASS")


def _window(iat: Int64, exp: Int64, now: Int64) -> String:
    try:
        check_app_jwt_window(iat, exp, now)
    except e:
        return String(e)
    return String("")


def test_window_edges() raises:
    var t: Int64 = NOW
    assert_true(_window(t - 60, t, t).find("expired") >= 0, "exp == now is expired")
    assert_equal(github_error_kind(_window(t - 60, t, t)), String("AUTH"))
    assert_equal(_window(t - 60, t + 1, t), String(""), "exp == now + 1 is valid")
    assert_equal(_window(t, t + 540, t), String(""), "iat == now is valid")
    assert_true(_window(t + 1, t + 540, t).find("future") >= 0, "iat == now + 1 is refused")
    assert_equal(_window(t - 1, t + 599, t), String(""), "span exactly 600")
    assert_equal(_window(t, t + 600, t), String(""), "exp - now == 600")
    assert_true(_window(t, t + 601, t).find("10 minutes ahead") >= 0, "exp - now == 601")
    assert_true(_window(t - 2, t + 599, t).find("spans") >= 0, "exp - iat == 601")
    print("  test_window_edges PASS")


def test_remint_margin() raises:
    var jwt = AppJwt(String("x.y.z"), NOW - 60, NOW + 540)
    assert_false(app_jwt_needs_remint(jwt, NOW), "fresh")
    assert_false(app_jwt_needs_remint(jwt, NOW + 479), "61 s left: kept")
    assert_true(app_jwt_needs_remint(jwt, NOW + 480), "60 s left: re-minted")
    assert_true(app_jwt_needs_remint(jwt, NOW + 540), "expired: re-minted")
    assert_true(app_jwt_needs_remint(jwt, NOW - 61), "clock went back past iat: re-minted")
    assert_false(app_jwt_needs_remint(jwt, NOW - 60), "now == iat: kept")
    print("  test_remint_margin PASS")


def _creds_refusal(issuer: String, var key: List[UInt8]) -> String:
    try:
        _ = AppCredentials(issuer, key^)
    except e:
        return String(e)
    return String("")


def test_credentials_refused() raises:
    var k = List[UInt8]()
    k.append(1)
    assert_equal(_creds_refusal(String("12345"), k.copy()), String(""), "an App ID")
    assert_equal(_creds_refusal(String("Iv1.0123abcd"), k.copy()), String(""), "a client ID")
    assert_true(_creds_refusal(String('Iv1"x'), k.copy()).byte_length() > 0, "a quote")
    assert_true(_creds_refusal(String("a b"), k.copy()).byte_length() > 0, "a space")
    assert_true(_creds_refusal(String(""), k.copy()).byte_length() > 0, "empty")
    var long = String("")
    for _ in range(64):
        long += "a"
    assert_equal(_creds_refusal(long, k.copy()), String(""), "64 bytes")
    assert_true(_creds_refusal(long + String("a"), k.copy()).byte_length() > 0, "65 bytes")
    assert_true(_creds_refusal(String("12345"), List[UInt8]()).find("key is empty") >= 0, "no key")
    print("  test_credentials_refused PASS")


def main() raises:
    test_mint_shape()
    test_window_edges()
    test_remint_margin()
    test_credentials_refused()
    print("PASS komira_github app_jwt")
