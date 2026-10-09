# =============================================================================
# test_key_selection.mojo: which key verifies a token, and which keys a
#   verifier refuses (verifier.mojo steps 2 to 4).
# =============================================================================
#
# Tokens are minted with Ed25519 (the RFC 8037 appendix A key) unless a test
# says otherwise. The RS256 bounds are checked on keys built straight from
# `_JwkParts` (bypassing komira_jwks's constructors), which is how the
# verifier's own re-check of the key lengths is reached.
#
# main runs every test and reports every failure.
# =============================================================================

from std.testing import assert_equal

from komira_crypto import ed25519_sign
from komira_encoding import base64_url_decode_nopad, base64_url_encode_nopad
from komira_jose import JwsVerifier
from komira_jwks import Jwk, JwkSet, parse_jwk_set
from komira_jwks.jwk import _JwkParts
from komira_jose.verifier import _signature_verifies, key_refusal


comptime SEED = "nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A"
comptime X = "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo"
# RFC 7515 appendix A.3: an ES256 token without kid and its key.
def _a3_token() -> String:
    return (
        String("eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQog")
        + "Imh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ.DtEhU3ljbEg8L38VWAfUAqO"
        + "yKAM6-Xx-F4GawxaepmXFCgfTjDxw5djxLa8ISlSApmWQxfKTUJqPP3-Kg6NU1Q"
    )


comptime A3_X = "f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU"
comptime A3_Y = "x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0"
comptime SUIT = "JoseError: the key does not suit the pinned algorithm"


def _b64(s: String) -> String:
    return base64_url_encode_nopad(s.as_bytes())


def _mint(header: String, payload: String = "{}") raises -> String:
    var si = _b64(header) + "." + _b64(payload)
    var seed = base64_url_decode_nopad(SEED)
    var sig = ed25519_sign(Span(seed), si.as_bytes())
    var b = List[UInt8]()
    for i in range(64):
        b.append(sig[i])
    return si + "." + base64_url_encode_nopad(Span(b))


def _kid(k: String) raises -> String:
    return _mint(String('{"alg":"EdDSA","kid":"') + k + '"}')


def _okp(kid: String, member: String = "") -> String:
    return (
        String('{"kty":"OKP","crv":"Ed25519","kid":"')
        + kid
        + '"'
        + member
        + ',"x":"'
        + X
        + '"}'
    )


def _set(keys: String) raises -> JwkSet:
    return parse_jwk_set(String('{"keys":[') + keys + "]}")


def _err(v: JwsVerifier, token: String) -> String:
    try:
        _ = v.verify(token)
    except e:
        return String(e)
    return String("")


def _ctor_err(alg: String, keys: JwkSet) -> String:
    try:
        _ = JwsVerifier(alg, keys)
    except e:
        return String(e)
    return String("")


def _single_err(alg: String, key: Jwk) -> String:
    try:
        _ = JwsVerifier.single_key(alg, key)
    except e:
        return String(e)
    return String("")


def _bytes(n: Int, fill: UInt8) -> List[UInt8]:
    var out = List[UInt8]()
    for _ in range(n):
        out.append(fill)
    return out^


def _raw(
    kty: String, crv: String, x: Int, y: Int, n: Int, e: Int
) -> Jwk:
    """A key built around the checked constructors, with the given member
    lengths (0 for absent)."""
    return Jwk(
        _parts=_JwkParts(
            kty=kty,
            crv=crv,
            x=_bytes(x, 7),
            y=_bytes(y, 7),
            n=_bytes(n, 0xC1),
            e=_bytes(e, 3),
            kid=Optional[String](String("raw")),
            alg=Optional[String](),
            key_use=Optional[String](),
            key_ops=Optional[List[String]](),
        )
    )


def test_kid_selects_and_never_falls_back() raises:
    # Catches: a kid that names no key answered by trying the others, or a
    # verifier that uses the first key regardless of kid.
    var other = base64_url_encode_nopad(Span(_bytes(32, 9)))
    var v = JwsVerifier(
        "EdDSA",
        _set(
            String('{"kty":"OKP","crv":"Ed25519","kid":"k0","x":"')
            + other
            + '"},'
            + _okp("k1")
        ),
    )
    _ = v.verify(_kid("k1"))
    assert_equal(_err(v, _kid("k0")), "JoseError: the signature does not verify")
    assert_equal(_err(v, _kid("k2")), "JoseError: kid names no key in the set")
    # Exact match only: a kid that extends or shortens a key's kid, at
    # either end, names no key (catches a prefix or suffix comparison).
    assert_equal(_err(v, _kid("k1x")), "JoseError: kid names no key in the set")
    assert_equal(_err(v, _kid("k")), "JoseError: kid names no key in the set")
    assert_equal(_err(v, _kid("xk1")), "JoseError: kid names no key in the set")
    # RFC 7515 4.1.4: kid is case-sensitive. The near-miss table of `k1`: a
    # prefix, the kid extended at the end and at the front, a proper suffix,
    # a case variant, and the same length with the first or the last byte
    # replaced (an empty kid is refused by the header gate before any key is
    # looked at). A prefix, suffix or case-folded compare in either direction,
    # or a byte loop that skips the first or the last byte, accepts at least
    # one of them.
    var misses = String("")
    for k in ["k", "k1x", "xk1", "1", "K1", "z1", "k2"]:
        var got = _err(v, _kid(String(k)))
        if got != "JoseError: kid names no key in the set":
            misses += String(k) + " -> " + got + "; "
    assert_equal(misses, "")


def test_two_keys_one_kid_refused() raises:
    # Catches: an ambiguous set answered with either key. komira_jwks's
    # parser refuses such a set; a JwkSet built directly can still hold one.
    var x = base64_url_decode_nopad(X)
    var keys = List[Jwk]()
    keys.append(Jwk.ed25519(Span(x), kid=String("k1")))
    keys.append(Jwk.ed25519(Span(x), kid=String("k1")))
    var v = JwsVerifier("EdDSA", JwkSet(keys^, List[String]()))
    assert_equal(_err(v, _kid("k1")), "JoseError: kid names two keys in the set")


def test_unsupported_algorithms() raises:
    # Catches: a verifier built for an algorithm outside the three.
    var s = _set(_okp("k1"))
    # Each of the three names is matched exactly: its prefix, the name
    # extended at the end and at the front, a proper suffix, a case variant
    # and the same length with the first or the last byte replaced are all
    # unsupported. Every value is tried and every miss is
    # reported, so a loose compare on any one of the three names shows.
    var misses = String("")
    for alg in [
        "HS256", "none", "PS256", "ES384", "RS512", "",
        "ES25", "ES256x", "xES256", "S256", "es256", "FS256", "ES257",
        "EdDS", "EdDSAx", "xEdDSA", "dDSA", "eddsa", "FdDSA", "EdDSB",
        "RS25", "RS256x", "xRS256", "S256", "rs256", "SS256", "RS257",
    ]:
        var a = String(alg)
        var got = _ctor_err(a, s)
        var want = (
            String("JoseError: algorithm \"")
            + a
            + "\" is not supported (ES256, EdDSA and RS256 are)"
        )
        if got != want:
            misses += a + " -> " + got + "; "
    assert_equal(misses, "")


def test_set_without_a_suitable_key() raises:
    # Catches: a verifier built over keys none of which can verify.
    var s = _set(_okp("k1"))
    assert_equal(_ctor_err("ES256", s), "JoseError: the key set holds no key for ES256")
    assert_equal(_ctor_err("RS256", s), "JoseError: the key set holds no key for RS256")
    assert_equal(
        _ctor_err("EdDSA", _set(_okp("k1", ',"use":"enc"'))),
        "JoseError: the key set holds no key for EdDSA",
    )


def test_key_type_must_suit_the_algorithm() raises:
    # Catches: an EC key selected by kid for an EdDSA verifier.
    var ec = (
        String('{"kty":"EC","crv":"P-256","kid":"e1","x":"')
        + A3_X
        + '","y":"'
        + A3_Y
        + '"}'
    )
    var v = JwsVerifier("EdDSA", _set(ec + "," + _okp("k1")))
    assert_equal(_err(v, _kid("e1")), SUIT)
    _ = v.verify(_kid("k1"))


def test_key_alg_use_and_key_ops() raises:
    # Catches: a key's alg, use or key_ops ignored (an encryption key or a
    # key published for another algorithm verifying signatures).
    var v = JwsVerifier(
        "EdDSA",
        _set(
            _okp("a-es", ',"alg":"ES256"')
            + ","
            + _okp("a-ok", ',"alg":"EdDSA"')
            + ","
            + _okp("u-enc", ',"use":"enc"')
            + ","
            + _okp("u-ok", ',"use":"sig"')
            + ","
            + _okp("o-sign", ',"key_ops":["sign"]')
            + ","
            + _okp("o-none", ',"key_ops":[]')
            + ","
            + _okp("o-ok", ',"key_ops":["sign","verify"]')
        ),
    )
    assert_equal(
        _err(v, _kid("a-es")), "JoseError: the key's alg is not the pinned algorithm"
    )
    assert_equal(_err(v, _kid("u-enc")), "JoseError: the key's use is not sig")
    comptime OPS = "JoseError: the key's key_ops does not include verify"
    assert_equal(_err(v, _kid("o-sign")), OPS)
    assert_equal(_err(v, _kid("o-none")), OPS)
    _ = v.verify(_kid("a-ok"))
    _ = v.verify(_kid("u-ok"))
    _ = v.verify(_kid("o-ok"))


def test_key_alg_use_and_key_ops_are_exact() raises:
    # Catches: a key's alg, use or key_ops element compared by prefix,
    # suffix, case or a byte loop that skips the first or last byte. Each
    # near-miss table holds a prefix, the value extended at the end and at
    # the front, a proper suffix, a case variant, "", and the same length
    # with the first or the last byte replaced, and every miss is reported.
    # A key_ops array with verify first
    # and another value after it is accepted (every element is looked at).
    var x = base64_url_decode_nopad(X)
    var misses = String("")
    for a in ["EdDS", "EdDSAx", "xEdDSA", "dDSA", "eDdsa", "", "FdDSA", "EdDSB"]:
        var got = key_refusal(Jwk.ed25519(Span(x), alg=String(a)), "EdDSA")
        if got != "the key's alg is not the pinned algorithm":
            misses += String("alg ") + String(a) + " -> " + got + "; "
    for u in ["si", "sigx", "xsig", "ig", "SIG", "", "zig", "sih"]:
        var got = key_refusal(Jwk.ed25519(Span(x), key_use=String(u)), "EdDSA")
        if got != "the key's use is not sig":
            misses += String("use ") + String(u) + " -> " + got + "; "
    for o in ["verif", "verifyx", "xverify", "erify", "VERIFY", "", "zerify", "verifz"]:
        var ops = List[String]()
        ops.append(String(o))
        var got = key_refusal(Jwk.ed25519(Span(x), key_ops=ops^), "EdDSA")
        if got != "the key's key_ops does not include verify":
            misses += String("key_ops ") + String(o) + " -> " + got + "; "
    var first = List[String]()
    first.append("verify")
    first.append("sign")
    var got = key_refusal(Jwk.ed25519(Span(x), key_ops=first^), "EdDSA")
    if got != "":
        misses += String("key_ops [verify, sign] -> ") + got + "; "
    assert_equal(misses, "")


def test_single_key() raises:
    # Catches: a single-key verifier that ignores a kid naming another key,
    # or that requires a kid (RFC 7515's own examples carry none).
    var x = base64_url_decode_nopad(X)
    var v = JwsVerifier.single_key("EdDSA", Jwk.ed25519(Span(x), kid=String("k1")))
    _ = v.verify(_kid("k1"))
    _ = v.verify(_mint('{"alg":"EdDSA"}'))
    assert_equal(
        _err(v, _kid("k2")), "JoseError: kid does not name the configured key"
    )
    assert_equal(
        _err(v, _kid("k1x")), "JoseError: kid does not name the configured key"
    )
    assert_equal(
        _err(v, _kid("k")), "JoseError: kid does not name the configured key"
    )
    assert_equal(
        _err(v, _kid("xk1")), "JoseError: kid does not name the configured key"
    )
    # The same near-miss table as the set path (see
    # test_kid_selects_and_never_falls_back), against the one key's kid.
    var misses = String("")
    for k in ["k", "k1x", "xk1", "1", "K1", "z1", "k2"]:
        var got = _err(v, _kid(String(k)))
        if got != "JoseError: kid does not name the configured key":
            misses += String(k) + " -> " + got + "; "
    assert_equal(misses, "")
    var anon = JwsVerifier.single_key("EdDSA", Jwk.ed25519(Span(x)))
    _ = anon.verify(_kid("anything"))
    var a3x = base64_url_decode_nopad(A3_X)
    var a3y = base64_url_decode_nopad(A3_Y)
    assert_equal(
        _single_err("EdDSA", Jwk.ec_p256(Span(a3x), Span(a3y))),
        SUIT,
    )
    assert_equal(
        _single_err("EdDSA", Jwk.ed25519(Span(x), key_use=String("enc"))),
        "JoseError: the key's use is not sig",
    )


def test_off_curve_key_does_not_verify() raises:
    # Catches: an EC point decode whose failure is ignored (AWS-LC then
    # uses the generator): the A.3 signature under the A.3 key with y's last
    # byte changed must not verify.
    var x = base64_url_decode_nopad(A3_X)
    var y = base64_url_decode_nopad(A3_Y)
    _ = JwsVerifier.single_key("ES256", Jwk.ec_p256(Span(x), Span(y))).verify(
        _a3_token()
    )
    y[31] = y[31] ^ 1
    var v = JwsVerifier.single_key("ES256", Jwk.ec_p256(Span(x), Span(y)))
    assert_equal(_err(v, _a3_token()), "JoseError: the signature does not verify")


def test_key_lengths_rechecked() raises:
    # Catches: the verifier trusting a Jwk's lengths (a Jwk built around
    # the constructors). ES256 x and y are each 31 and 33 bytes; EdDSA x is 31
    # and 33 bytes. The RS256 bounds are 256..512 modulus bytes and 1..8
    # exponent bytes, each edge on both sides.
    assert_equal(_single_err("EdDSA", _raw("OKP", "Ed25519", 31, 0, 0, 0)), SUIT)
    assert_equal(_single_err("EdDSA", _raw("OKP", "Ed25519", 33, 0, 0, 0)), SUIT)
    assert_equal(_single_err("EdDSA", _raw("OKP", "Ed25519", 32, 0, 0, 0)), "")
    assert_equal(_single_err("EdDSA", _raw("OKP", "X25519", 32, 0, 0, 0)), SUIT)
    assert_equal(_single_err("ES256", _raw("EC", "P-256", 32, 31, 0, 0)), SUIT)
    assert_equal(_single_err("ES256", _raw("EC", "P-256", 32, 33, 0, 0)), SUIT)
    assert_equal(_single_err("ES256", _raw("EC", "P-256", 31, 32, 0, 0)), SUIT)
    assert_equal(_single_err("ES256", _raw("EC", "P-256", 33, 32, 0, 0)), SUIT)
    assert_equal(_single_err("ES256", _raw("EC", "P-384", 32, 32, 0, 0)), SUIT)
    assert_equal(_single_err("ES256", _raw("EC", "P-256", 32, 32, 0, 0)), "")
    assert_equal(_single_err("RS256", _raw("RSA", "", 0, 0, 255, 3)), SUIT)
    assert_equal(_single_err("RS256", _raw("RSA", "", 0, 0, 256, 3)), "")
    assert_equal(_single_err("RS256", _raw("RSA", "", 0, 0, 512, 3)), "")
    assert_equal(_single_err("RS256", _raw("RSA", "", 0, 0, 513, 3)), SUIT)
    assert_equal(_single_err("RS256", _raw("RSA", "", 0, 0, 256, 0)), SUIT)
    assert_equal(_single_err("RS256", _raw("RSA", "", 0, 0, 256, 1)), "")
    assert_equal(_single_err("RS256", _raw("RSA", "", 0, 0, 256, 8)), "")
    assert_equal(_single_err("RS256", _raw("RSA", "", 0, 0, 256, 9)), SUIT)


def _suit_misses(alg: String, kty: String, crv: String, key: Jwk) -> String:
    var got = key_refusal(key, alg)
    if got == "the key does not suit the pinned algorithm":
        return String("")
    return alg + " kty=" + kty + " crv=" + crv + " -> \"" + got + "\"; "


def test_kty_crv_and_alg_are_exact() raises:
    # Catches: a key-type, curve or algorithm compare in the key check that
    # is not exact (a Jwk built around the constructors reaches it with any
    # strings). Each key below has the right lengths, so only the one wrong
    # string can refuse it. The near-miss table of each expected value: a
    # prefix, the value extended at the end and at the front, a proper
    # suffix, a case variant, "", and the same length with the first, the
    # middle (index len/2) or the last byte replaced; the kty tables also
    # hold the other two key types and the crv tables a sibling curve. A
    # prefix, suffix, case-folded, always-true or byte loop that skips the
    # first, the middle or the last byte, in either direction, accepts at
    # least one of them; every miss is reported.
    var m = String("")
    for k in ["E", "ECx", "xEC", "C", "ec", "", "zC", "Ez", "OKP", "RSA"]:
        m += _suit_misses("ES256", String(k), "P-256", _raw(String(k), "P-256", 32, 32, 0, 0))
    for k in ["OK", "OKPx", "xOKP", "KP", "okp", "", "zKP", "OzP", "OKz", "EC", "RSA"]:
        m += _suit_misses("EdDSA", String(k), "Ed25519", _raw(String(k), "Ed25519", 32, 0, 0, 0))
    for k in ["RS", "RSAx", "xRSA", "SA", "rsa", "", "zSA", "RzA", "RSz", "EC", "OKP"]:
        m += _suit_misses("RS256", String(k), "", _raw(String(k), "", 0, 0, 256, 3))
    for c in ["P-25", "P-256x", "xP-256", "-256", "p-256", "", "z-256", "P-z56", "P-25z", "P-384"]:
        m += _suit_misses("ES256", "EC", String(c), _raw("EC", String(c), 32, 32, 0, 0))
    for c in [
        "Ed2551", "Ed25519x", "xEd25519", "d25519", "ed25519", "", "zd25519",
        "Ed2z519", "Ed2551z", "X25519",
    ]:
        m += _suit_misses("EdDSA", "OKP", String(c), _raw("OKP", String(c), 32, 0, 0, 0))
    for a in ["ES25", "ES256x", "xES256", "S256", "es256", "", "zS256", "ESz56", "ES25z"]:
        m += _suit_misses(String(a), "EC", "P-256", _raw("EC", "P-256", 32, 32, 0, 0))
    for a in ["EdDS", "EdDSAx", "xEdDSA", "dDSA", "eddsa", "", "zdDSA", "EdzSA", "EdDSz"]:
        m += _suit_misses(String(a), "OKP", "Ed25519", _raw("OKP", "Ed25519", 32, 0, 0, 0))
    for a in ["RS25", "RS256x", "xRS256", "S256", "rs256", "", "zS256", "RSz56", "RS25z"]:
        m += _suit_misses(String(a), "RSA", "", _raw("RSA", "", 0, 0, 256, 3))
    assert_equal(m, "")
    # The controls: each expected triple is accepted.
    assert_equal(key_refusal(_raw("EC", "P-256", 32, 32, 0, 0), "ES256"), "")
    assert_equal(key_refusal(_raw("OKP", "Ed25519", 32, 0, 0, 0), "EdDSA"), "")
    assert_equal(key_refusal(_raw("RSA", "", 0, 0, 256, 3), "RS256"), "")


def test_rs256_signature_length_is_the_modulus_length() raises:
    # Catches: an RS256 signature of another length passed to the
    # primitive. A key of 257 modulus bytes takes 257-byte signatures only.
    var v = JwsVerifier.single_key("RS256", _raw("RSA", "", 0, 0, 257, 3))
    var h = _b64('{"alg":"RS256"}') + ".e30."
    comptime LEN = "JoseError: the signature has the wrong length"
    assert_equal(_err(v, h + base64_url_encode_nopad(Span(_bytes(256, 1)))), LEN)
    assert_equal(_err(v, h + base64_url_encode_nopad(Span(_bytes(258, 1)))), LEN)
    assert_equal(
        _err(v, h + base64_url_encode_nopad(Span(_bytes(257, 1)))),
        "JoseError: the signature does not verify",
    )


def test_internal_arms_refuse_an_unknown_algorithm() raises:
    # Catches: a signature or key check that answers yes for an algorithm
    # outside the three. The constructors admit only the three, so these
    # arms are reached only directly.
    var x = base64_url_decode_nopad(X)
    var key = Jwk.ed25519(Span(x))
    var si = List[UInt8]()
    si.append(46)
    assert_equal(_signature_verifies("HS256", key, si, _bytes(64, 0)), False)
    assert_equal(_signature_verifies("", key, si, _bytes(64, 0)), False)
    assert_equal(key_refusal(key, "HS256"), "the key does not suit the pinned algorithm")


def main() raises:
    var failures = String("")
    try:
        test_kid_selects_and_never_falls_back()
    except e:
        failures += String("test_kid_selects_and_never_falls_back: ") + String(e) + "\n"
    try:
        test_two_keys_one_kid_refused()
    except e:
        failures += String("test_two_keys_one_kid_refused: ") + String(e) + "\n"
    try:
        test_unsupported_algorithms()
    except e:
        failures += String("test_unsupported_algorithms: ") + String(e) + "\n"
    try:
        test_set_without_a_suitable_key()
    except e:
        failures += String("test_set_without_a_suitable_key: ") + String(e) + "\n"
    try:
        test_key_type_must_suit_the_algorithm()
    except e:
        failures += String("test_key_type_must_suit_the_algorithm: ") + String(e) + "\n"
    try:
        test_key_alg_use_and_key_ops()
    except e:
        failures += String("test_key_alg_use_and_key_ops: ") + String(e) + "\n"
    try:
        test_key_alg_use_and_key_ops_are_exact()
    except e:
        failures += (
            String("test_key_alg_use_and_key_ops_are_exact: ") + String(e) + "\n"
        )
    try:
        test_single_key()
    except e:
        failures += String("test_single_key: ") + String(e) + "\n"
    try:
        test_off_curve_key_does_not_verify()
    except e:
        failures += String("test_off_curve_key_does_not_verify: ") + String(e) + "\n"
    try:
        test_key_lengths_rechecked()
    except e:
        failures += String("test_key_lengths_rechecked: ") + String(e) + "\n"
    try:
        test_kty_crv_and_alg_are_exact()
    except e:
        failures += String("test_kty_crv_and_alg_are_exact: ") + String(e) + "\n"
    try:
        test_rs256_signature_length_is_the_modulus_length()
    except e:
        failures += String("test_rs256_signature_length_is_the_modulus_length: ") + String(e) + "\n"
    try:
        test_internal_arms_refuse_an_unknown_algorithm()
    except e:
        failures += String("test_internal_arms_refuse_an_unknown_algorithm: ") + String(e) + "\n"
    if failures != "":
        print(failures)
        raise Error("test_key_selection: FAILED\n" + failures)
    print("test_key_selection: OK")
