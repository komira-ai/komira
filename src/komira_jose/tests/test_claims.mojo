# =============================================================================
# test_claims.mojo: `ClaimPolicy` and `verify_jwt` (claims.mojo): the
#   policy's own bounds, the pinned `typ`, and every claim refusal at its
#   boundaries.
# =============================================================================
#
# Tokens are minted with Ed25519 (the RFC 8037 appendix A key) and a header
# `{"alg":"EdDSA","kid":"k1","typ":"at+jwt"}` unless a test says otherwise.
# The base time is NOW = 1000000 seconds. Every boundary is tested on both
# sides: the value that passes and the first value that is refused.
#
# main runs every test and reports every failure.
# =============================================================================

from std.testing import assert_equal

from komira_crypto import ed25519_sign
from komira_encoding import base64_url_decode_nopad, base64_url_encode_nopad
from komira_jose import (
    JOSE_MAX_LEEWAY_S,
    JOSE_MAX_TTL_S,
    ClaimPolicy,
    JwsVerifier,
    verify_jwt,
)
from komira_jwks import Jwk, JwkSet


comptime SEED = "nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A"
comptime X = "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
comptime HDR = '{"alg":"EdDSA","kid":"k1","typ":"at+jwt"}'
comptime ISS = "https://issuer.example/a"
comptime AUD = "service-a"
comptime NOW: Int64 = 1000000


def _b64(s: String) -> String:
    return base64_url_encode_nopad(s.as_bytes())


def _mint_h(header: String, payload: String) raises -> String:
    var si = _b64(header) + "." + _b64(payload)
    var seed = base64_url_decode_nopad(SEED)
    var sig = ed25519_sign(Span(seed), si.as_bytes())
    var b = List[UInt8]()
    for i in range(64):
        b.append(sig[i])
    return si + "." + base64_url_encode_nopad(Span(b))


def _mint(payload: String) raises -> String:
    return _mint_h(HDR, payload)


def _claims(
    exp: String = "1000100",
    iat: String = "1000000",
    extra: String = "",
    aud: String = '"service-a"',
    iss: String = '"https://issuer.example/a"',
    sub: String = '"user-1"',
) -> String:
    """A payload; an argument of "-" leaves that claim out."""
    var parts = List[String]()
    if iss != "-":
        parts.append(String('"iss":') + iss)
    if aud != "-":
        parts.append(String('"aud":') + aud)
    if sub != "-":
        parts.append(String('"sub":') + sub)
    if exp != "-":
        parts.append(String('"exp":') + exp)
    if iat != "-":
        parts.append(String('"iat":') + iat)
    if extra != "":
        parts.append(extra)
    var out = String("{")
    for i in range(len(parts)):
        if i > 0:
            out += ","
        out += parts[i]
    return out + "}"


def _verifier() raises -> JwsVerifier:
    var x = base64_url_decode_nopad(X)
    var keys = List[Jwk]()
    keys.append(Jwk.ed25519(Span(x), kid=String("k1")))
    return JwsVerifier("EdDSA", JwkSet(keys^, List[String]()))


def _policy(
    leeway: Int64 = 0, max_ttl: Int64 = 300, typ: String = "at+jwt"
) raises -> ClaimPolicy:
    return ClaimPolicy(
        issuer=ISS,
        audience=AUD,
        accept_typ=typ,
        now=NOW,
        leeway_s=leeway,
        max_ttl_s=max_ttl,
    )


def _err_p(token: String, p: ClaimPolicy) raises -> String:
    var v = _verifier()
    try:
        _ = verify_jwt(token, v, p)
    except e:
        return String(e)
    return String("")


def _err(token: String, leeway: Int64 = 0, max_ttl: Int64 = 300) raises -> String:
    return _err_p(token, _policy(leeway, max_ttl))


def _policy_err(
    issuer: String = ISS,
    audience: String = AUD,
    typ: String = "at+jwt",
    now: Int64 = NOW,
    leeway: Int64 = 0,
    max_ttl: Int64 = 300,
) -> String:
    try:
        _ = ClaimPolicy(
            issuer=issuer,
            audience=audience,
            accept_typ=typ,
            now=now,
            leeway_s=leeway,
            max_ttl_s=max_ttl,
        )
    except e:
        return String(e)
    return String("")


def test_baseline() raises:
    # Catches: a policy that never passes (every refusal below vacuous), and
    # the result fields read from the wrong claim.
    var t = _mint(_claims(extra='"scope":"read write","nbf":999990'))
    var got = verify_jwt(t, _verifier(), _policy())
    assert_equal(got.issuer, ISS)
    assert_equal(got.subject, "user-1")
    assert_equal(got.audience, AUD)
    assert_equal(got.kid, "k1")
    assert_equal(got.exp, Int64(1000100))
    assert_equal(got.iat, Int64(1000000))
    assert_equal(got.nbf.value(), Int64(999990))
    assert_equal(got.claims.get("scope").as_string(), "read write")


def test_policy_bounds() raises:
    # Catches: each bound of the policy moved by one, or not checked.
    assert_equal(_policy_err(issuer=""), "JoseError: the policy issuer is empty")
    assert_equal(_policy_err(audience=""), "JoseError: the policy audience is empty")
    comptime TYP = "JoseError: the policy typ must be at+jwt or JWT"
    assert_equal(_policy_err(typ="at+jwt"), "")
    assert_equal(_policy_err(typ="JWT"), "")
    # Each of the two accepted types is matched exactly: the near-miss
    # tables of `at+jwt` and `JWT` (a prefix, an extension at the end and at
    # the front, a proper suffix, a case variant, the same length with the
    # first or the last byte replaced), the long media type and
    # "". Every value is tried and every miss is reported, so a loose
    # compare (prefix, suffix, case-folded or a byte loop that skips the
    # first or last byte) on either type shows.
    var misses = String("")
    for t in [
        "at+jw", "at+jwtx", "xat+jwt", "t+jwt", "AT+JWT", "zt+jwt", "at+jwx",
        "JW", "JWTx", "xJWT", "WT", "jwt", "ZWT", "JWX",
        "application/at+jwt", "",
    ]:
        var got = _policy_err(typ=String(t))
        if got != TYP:
            misses += String(t) + " -> " + got + "; "
    assert_equal(misses, "")
    assert_equal(_policy_err(now=-1), "JoseError: the policy time is negative")
    assert_equal(_policy_err(now=0), "")
    comptime LEEWAY = "JoseError: the policy leeway must be 0 to 60 seconds"
    assert_equal(_policy_err(leeway=-1), LEEWAY)
    assert_equal(_policy_err(leeway=0), "")
    assert_equal(_policy_err(leeway=JOSE_MAX_LEEWAY_S), "")
    assert_equal(_policy_err(leeway=JOSE_MAX_LEEWAY_S + 1), LEEWAY)
    comptime TTL = "JoseError: the policy max TTL must be 1 to 86400 seconds"
    assert_equal(_policy_err(max_ttl=0), TTL)
    assert_equal(_policy_err(max_ttl=1), "")
    assert_equal(_policy_err(max_ttl=JOSE_MAX_TTL_S), "")
    assert_equal(_policy_err(max_ttl=JOSE_MAX_TTL_S + 1), TTL)
    # with_now keeps every other member and checks the time again.
    var p = _policy(leeway=5, max_ttl=600).with_now(2000)
    assert_equal(p.now(), Int64(2000))
    assert_equal(p.leeway_s(), Int64(5))
    assert_equal(p.max_ttl_s(), Int64(600))
    assert_equal(p.issuer(), ISS)
    assert_equal(p.audience(), AUD)
    assert_equal(p.accept_typ(), "at+jwt")
    var got = String("")
    try:
        _ = p.with_now(-1)
    except e:
        got = String(e)
    assert_equal(got, "JoseError: the policy time is negative")


def test_typ_is_pinned() raises:
    # Catches: a missing typ accepted, a second typ accepted, or typ checked
    # only after the signature (a garbage signature still gets the typ text).
    var c = _claims()
    comptime MISSING = "JoseError: header typ is missing or not a string"
    comptime OTHER = "JoseError: header typ is not the pinned type"
    assert_equal(_err(_mint_h('{"alg":"EdDSA","kid":"k1"}', c)), MISSING)
    assert_equal(_err(_mint_h('{"alg":"EdDSA","kid":"k1","typ":1}', c)), MISSING)
    assert_equal(_err(_mint_h('{"alg":"EdDSA","kid":"k1","typ":"JWT"}', c)), OTHER)
    # A prefix of the pinned type, or the type extended at either end, is
    # another type.
    assert_equal(_err(_mint_h('{"alg":"EdDSA","kid":"k1","typ":"xat+jwt"}', c)), OTHER)
    assert_equal(_err(_mint_h('{"alg":"EdDSA","kid":"k1","typ":""}', c)), OTHER)
    assert_equal(_err(_mint_h('{"alg":"EdDSA","kid":"k1","typ":"at+jw"}', c)), OTHER)
    assert_equal(_err(_mint_h('{"alg":"EdDSA","kid":"k1","typ":"at+jwtx"}', c)), OTHER)
    assert_equal(
        _err(_mint_h('{"alg":"EdDSA","kid":"k1","typ":"application/at+jwt"}', c)),
        OTHER,
    )
    assert_equal(
        _err(_b64('{"alg":"EdDSA","kid":"k1","typ":"JWT"}') + "." + _b64(c) + ".AAAA"),
        OTHER,
    )
    # The pin is byte for byte, case included (a deliberate narrowing of
    # RFC 7515 4.1.9's case-insensitive media types). The near-miss table of
    # `at+jwt`: a prefix, the type extended at the end and at the front, a
    # proper suffix, a case variant, "", and the same length with the first
    # or the last byte replaced. Every miss is reported.
    var misses = String("")
    for t in ["at+jw", "at+jwtx", "xat+jwt", "t+jwt", "AT+JWT", "", "zt+jwt", "at+jwx"]:
        var h = String('{"alg":"EdDSA","kid":"k1","typ":"') + String(t) + '"}'
        var got = _err(_mint_h(h, c))
        if got != OTHER:
            misses += String(t) + " -> " + got + "; "
    assert_equal(misses, "")
    # A JWT-typed policy accepts JWT and refuses at+jwt.
    var jwt = _policy(typ="JWT")
    assert_equal(_err_p(_mint_h('{"alg":"EdDSA","kid":"k1","typ":"JWT"}', c), jwt), "")
    assert_equal(_err_p(_mint(c), jwt), OTHER)


def test_kid_required_even_for_a_single_key() raises:
    # Catches: verify_jwt that lets a single-key verifier skip kid.
    var x = base64_url_decode_nopad(X)
    var v = JwsVerifier.single_key("EdDSA", Jwk.ed25519(Span(x)))
    var got = String("")
    try:
        _ = verify_jwt(
            _mint_h('{"alg":"EdDSA","typ":"at+jwt"}', _claims()), v, _policy()
        )
    except e:
        got = String(e)
    assert_equal(got, "JoseError: header kid is missing")


def test_payload_shape() raises:
    # Catches: a payload read leniently, or duplicates kept (RFC 7519 4).
    assert_equal(_err(_mint("{")), "JoseError: the payload is not JSON")
    assert_equal(_err(_mint("")), "JoseError: the payload is not JSON")
    assert_equal(_err(_mint("[]")), "JoseError: the payload is not a JSON object")
    comptime TWICE = "JoseError: the payload names a member twice"
    assert_equal(_err(_mint(_claims(extra='"aud":"x"'))), TWICE)
    assert_equal(_err(_mint(_claims(extra='"x":{"a":1,"a":2}'))), TWICE)


def test_iss() raises:
    # Catches: iss missing, non-string, or compared loosely.
    comptime BAD = "JoseError: claim iss is missing or not a string"
    comptime OTHER = "JoseError: claim iss is not the issuer"
    assert_equal(_err(_mint(_claims(iss="-"))), BAD)
    assert_equal(_err(_mint(_claims(iss="1"))), BAD)
    assert_equal(_err(_mint(_claims(iss='"issuer.example"'))), OTHER)
    # The near-miss table of the issuer `https://issuer.example/a`: prefixes
    # down to "" (a shortened host is not a reserved example name and the
    # public-boundary lint refuses it, so the prefixes stop before the host
    # or keep all of it), the issuer extended at the end and at the front, a
    # proper suffix, a case variant, and the same length with the first or
    # the last byte replaced. A prefix, suffix or case-folded compare, or a
    # byte loop that skips the first or the last byte, accepts at least one
    # of them; every miss is reported.
    var misses = String("")
    for i in [
        "https:/", "https://issuer.example/", "https://issuer.example/ax",
        "xhttps://issuer.example/a", "ttps://issuer.example/a",
        "HTTPS://issuer.example/a", "", "zttps://issuer.example/a",
        "https://issuer.example/b",
    ]:
        var s = String('"') + String(i) + '"'
        var got = _err(_mint(_claims(iss=s)))
        if got != OTHER:
            misses += s + " -> " + got + "; "
    # The member is named `iss` exactly: a payload whose only near name is
    # another member (a prefix, an extension at either end, a suffix, a case
    # variant, the first or last byte replaced) has no iss.
    for m in ["is", "issx", "xiss", "ss", "ISS", "zss", "isz"]:
        var e = String('"') + String(m) + '":"' + ISS + '"'
        var got = _err(_mint(_claims(iss="-", extra=e)))
        if got != BAD:
            misses += String("member ") + String(m) + " -> " + got + "; "
    assert_equal(misses, "")


def test_aud() raises:
    # Catches: aud missing, an array without ours accepted, an empty or
    # mixed array accepted, only the first or last element looked at, or a
    # prefix, suffix or case-folded match either way.
    comptime BAD = "JoseError: claim aud is not a string or a non-empty array of strings"
    comptime NOT_OURS = "JoseError: claim aud does not name the audience"
    assert_equal(_err(_mint(_claims(aud="-"))), "JoseError: claim aud is missing")
    assert_equal(_err(_mint(_claims(aud='"service-b"'))), NOT_OURS)
    assert_equal(_err(_mint(_claims(aud='["service-b","x"]'))), NOT_OURS)
    assert_equal(_err(_mint(_claims(aud="[]"))), BAD)
    assert_equal(_err(_mint(_claims(aud="5"))), BAD)
    assert_equal(_err(_mint(_claims(aud='["service-a",1]'))), BAD)
    assert_equal(_err(_mint(_claims(aud='[1,"service-a"]'))), BAD)
    assert_equal(_err(_mint(_claims(aud='["x","service-a"]'))), "")
    assert_equal(_err(_mint(_claims(aud='["service-a"]'))), "")
    # Exact match only: a prefix of the audience, or the audience extended at
    # either end, is not ours, as a string or as an array element.
    assert_equal(_err(_mint(_claims(aud='"service"'))), NOT_OURS)
    assert_equal(_err(_mint(_claims(aud='"service-ab"'))), NOT_OURS)
    assert_equal(_err(_mint(_claims(aud='"xservice-a"'))), NOT_OURS)
    assert_equal(_err(_mint(_claims(aud='["service"]'))), NOT_OURS)
    assert_equal(_err(_mint(_claims(aud='["service-ab"]'))), NOT_OURS)
    assert_equal(_err(_mint(_claims(aud='["x","service-ab"]'))), NOT_OURS)
    assert_equal(_err(_mint(_claims(aud='["xservice-a"]'))), NOT_OURS)
    # Ours first and another value after it: every element is looked at,
    # not only the last.
    assert_equal(_err(_mint(_claims(aud='["service-a","x"]'))), "")
    # RFC 7519 2 and 4.1.3: aud values are compared case-sensitively with no
    # transformation. The near-miss table of `service-a`: a prefix, the
    # audience extended at the end and at the front, a proper suffix, a case
    # variant, "", and the same length with the first or the last byte
    # replaced, each as a string and as the only array element. A prefix,
    # suffix or case-folded compare in either direction, or a byte loop that
    # skips the first or the last byte, accepts at least one of them; every
    # miss is reported.
    var misses = String("")
    for a in [
        "service", "service-ab", "xservice-a", "ervice-a", "SERVICE-A", "",
        "zervice-a", "service-b",
    ]:
        var s = String('"') + String(a) + '"'
        var got = _err(_mint(_claims(aud=s)))
        if got != NOT_OURS:
            misses += s + " -> " + got + "; "
        got = _err(_mint(_claims(aud=String("[") + s + "]")))
        if got != NOT_OURS:
            misses += String("[") + s + "] -> " + got + "; "
    assert_equal(misses, "")


def test_sub() raises:
    # Catches: an empty or non-string subject accepted.
    comptime BAD = "JoseError: claim sub is missing, empty or not a string"
    assert_equal(_err(_mint(_claims(sub="-"))), BAD)
    assert_equal(_err(_mint(_claims(sub='""'))), BAD)
    assert_equal(_err(_mint(_claims(sub="1"))), BAD)
    assert_equal(_err(_mint(_claims(sub='"x"'))), "")


def test_integer_claims() raises:
    # Catches: a fraction, exponent, sign, string or overflowing value read
    # as a time, or exp / iat optional.
    assert_equal(_err(_mint(_claims(exp="-"))), "JoseError: claim exp is missing")
    assert_equal(_err(_mint(_claims(iat="-"))), "JoseError: claim iat is missing")
    comptime EXP = "JoseError: claim exp is not a non-negative integer"
    assert_equal(_err(_mint(_claims(exp="1000100.0"))), EXP)
    assert_equal(_err(_mint(_claims(exp="1000100.5"))), EXP)
    assert_equal(_err(_mint(_claims(exp="1e7"))), EXP)
    assert_equal(_err(_mint(_claims(exp='"1000100"'))), EXP)
    assert_equal(_err(_mint(_claims(exp="-1"))), EXP)
    assert_equal(_err(_mint(_claims(exp="-0"))), EXP)
    assert_equal(_err(_mint(_claims(exp="99999999999999999999"))), EXP)
    assert_equal(_err(_mint(_claims(exp="null"))), EXP)
    assert_equal(
        _err(_mint(_claims(iat="1.5"))),
        "JoseError: claim iat is not a non-negative integer",
    )
    assert_equal(
        _err(_mint(_claims(extra='"nbf":"0"'))),
        "JoseError: claim nbf is not a non-negative integer",
    )


def test_exp_boundary() raises:
    # Catches: `now >= exp + leeway` moved by one (exp == now accepted with
    # zero leeway, or exp == now + 1 refused), with and without leeway.
    comptime EXPIRED = "JoseError: the token has expired"
    assert_equal(_err(_mint(_claims(exp="1000000", iat="999900"))), EXPIRED)
    assert_equal(_err(_mint(_claims(exp="1000001", iat="999900"))), "")
    assert_equal(
        _err(_mint(_claims(exp="999970", iat="999900")), leeway=30), EXPIRED
    )
    assert_equal(_err(_mint(_claims(exp="999971", iat="999900")), leeway=30), "")


def test_iat_and_nbf_boundaries() raises:
    # Catches: iat or nbf in the future beyond the leeway accepted, or the
    # bound moved by one.
    assert_equal(
        _err(_mint(_claims(exp="1000100", iat="1000030")), leeway=30), ""
    )
    assert_equal(
        _err(_mint(_claims(exp="1000100", iat="1000031")), leeway=30),
        "JoseError: claim iat is in the future",
    )
    assert_equal(
        _err(_mint(_claims(exp="1000100", iat="1000001"))),
        "JoseError: claim iat is in the future",
    )
    assert_equal(_err(_mint(_claims(extra='"nbf":1000030')), leeway=30), "")
    assert_equal(
        _err(_mint(_claims(extra='"nbf":1000031')), leeway=30),
        "JoseError: the token is not yet valid",
    )
    assert_equal(
        _err(_mint(_claims(extra='"nbf":1000001'))),
        "JoseError: the token is not yet valid",
    )
    assert_equal(_err(_mint(_claims(extra='"nbf":1000000'))), "")


def test_lifetime_boundaries() raises:
    # Catches: exp == iat accepted, or the max TTL moved by one.
    assert_equal(
        _err(_mint(_claims(exp="1000010", iat="1000010")), leeway=30),
        "JoseError: claim exp is not after iat",
    )
    assert_equal(
        _err(_mint(_claims(exp="1000009", iat="1000010")), leeway=30),
        "JoseError: claim exp is not after iat",
    )
    assert_equal(
        _err(_mint(_claims(exp="1000011", iat="1000010")), leeway=30), ""
    )
    assert_equal(_err(_mint(_claims(exp="1000300", iat="1000000"))), "")
    assert_equal(
        _err(_mint(_claims(exp="1000301", iat="1000000"))),
        "JoseError: the token lives longer than the max TTL",
    )


def main() raises:
    var failures = String("")
    try:
        test_baseline()
    except e:
        failures += String("test_baseline: ") + String(e) + "\n"
    try:
        test_policy_bounds()
    except e:
        failures += String("test_policy_bounds: ") + String(e) + "\n"
    try:
        test_typ_is_pinned()
    except e:
        failures += String("test_typ_is_pinned: ") + String(e) + "\n"
    try:
        test_kid_required_even_for_a_single_key()
    except e:
        failures += String("test_kid_required_even_for_a_single_key: ") + String(e) + "\n"
    try:
        test_payload_shape()
    except e:
        failures += String("test_payload_shape: ") + String(e) + "\n"
    try:
        test_iss()
    except e:
        failures += String("test_iss: ") + String(e) + "\n"
    try:
        test_aud()
    except e:
        failures += String("test_aud: ") + String(e) + "\n"
    try:
        test_sub()
    except e:
        failures += String("test_sub: ") + String(e) + "\n"
    try:
        test_integer_claims()
    except e:
        failures += String("test_integer_claims: ") + String(e) + "\n"
    try:
        test_exp_boundary()
    except e:
        failures += String("test_exp_boundary: ") + String(e) + "\n"
    try:
        test_iat_and_nbf_boundaries()
    except e:
        failures += String("test_iat_and_nbf_boundaries: ") + String(e) + "\n"
    try:
        test_lifetime_boundaries()
    except e:
        failures += String("test_lifetime_boundaries: ") + String(e) + "\n"
    if failures != "":
        print(failures)
        raise Error("test_claims: FAILED\n" + failures)
    print("test_claims: OK")
