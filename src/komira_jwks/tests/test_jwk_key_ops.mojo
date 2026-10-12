# =============================================================================
# test_jwk_key_ops.mojo: the `key_ops` member (RFC 7517 section 4.3) is read,
# kept in order, rendered, compared, and refused when malformed. A verifier
# (komira_jose) refuses a key whose `key_ops` does not allow "verify", so a
# parser that dropped the member would let an encryption-only key verify.
# Each test names the defect it catches.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_encoding import base64_url_encode_nopad
from komira_jwks import Jwk, parse_jwk_set, render_jwk


def _b64(n: Int, fill: UInt8) -> String:
    var b = List[UInt8]()
    for _ in range(n):
        b.append(fill)
    return base64_url_encode_nopad(Span(b))


def _okp_with(ops_member: String) -> String:
    return (
        String('{"keys":[{"kty":"OKP","crv":"Ed25519",')
        + ops_member
        + ',"kid":"k","x":"'
        + _b64(32, 9)
        + '"}]}'
    )


def _skipped_only(doc: String) raises -> String:
    var s = parse_jwk_set(doc)
    assert_equal(len(s.keys), 0, "the key was accepted")
    assert_equal(len(s.skipped), 1)
    return s.skipped[0]


def _ops(a: String, b: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    out.append(b)
    return out^


def test_key_ops_kept_in_order_and_rendered() raises:
    # Catches: the member dropped by the parser (key_ops() is None) or by
    # the renderer (the rendering loses it), or its order changed.
    var s = parse_jwk_set(_okp_with('"key_ops":["verify","sign"]'))
    assert_equal(len(s.keys), 1)
    var ops = s.keys[0].key_ops()
    assert_true(Bool(ops), "key_ops was dropped")
    assert_equal(len(ops.value()), 2)
    assert_equal(ops.value()[0], "verify")
    assert_equal(ops.value()[1], "sign")
    assert_equal(
        render_jwk(s.keys[0]),
        String('{"kty":"OKP","crv":"Ed25519","key_ops":["verify","sign"],')
        + '"kid":"k","x":"'
        + _b64(32, 9)
        + '"}',
    )
    # An empty array is kept as present and empty, not as absent.
    var e = parse_jwk_set(_okp_with('"key_ops":[]'))
    assert_true(Bool(e.keys[0].key_ops()), "an empty key_ops read as absent")
    assert_equal(len(e.keys[0].key_ops().value()), 0)
    # Absent stays absent.
    var a = parse_jwk_set(_okp_with('"use":"sig"'))
    assert_false(Bool(a.keys[0].key_ops()))


def test_malformed_key_ops_skips_the_key() raises:
    # Catches: a non-array, a non-string element or a repeated value
    # accepted (RFC 7517 section 4.3: "Duplicate key operation values MUST
    # NOT be present in the array").
    assert_equal(
        _skipped_only(_okp_with('"key_ops":"verify"')),
        'key 0: member "key_ops" is not an array',
    )
    assert_equal(
        _skipped_only(_okp_with('"key_ops":["verify",1]')),
        'key 0: member "key_ops" holds a non-string',
    )
    assert_equal(
        _skipped_only(_okp_with('"key_ops":["sign","verify","sign"]')),
        'key 0: member "key_ops" names "sign" twice',
    )


def test_constructor_checks_key_ops() raises:
    # Catches: a constructor that skips the check the parser runs.
    var got = String("")
    var raw = List[UInt8]()
    for _ in range(32):
        raw.append(5)
    try:
        _ = Jwk.ed25519(Span(raw), key_ops=_ops("verify", "verify"))
    except e:
        got = String(e)
    assert_equal(got, 'JwksError: member "key_ops" names "verify" twice')


def test_key_ops_in_equality() raises:
    # Catches: __eq__ that ignores key_ops (two keys with different
    # permitted operations compare equal).
    var raw = List[UInt8]()
    for _ in range(32):
        raw.append(5)
    var a = Jwk.ed25519(Span(raw), key_ops=_ops("verify", "sign"))
    var b = Jwk.ed25519(Span(raw), key_ops=_ops("sign", "verify"))
    var c = Jwk.ed25519(Span(raw))
    var d = Jwk.ed25519(Span(raw), key_ops=_ops("verify", "sign"))
    var one = List[String]()
    one.append("verify")
    var shorter = Jwk.ed25519(Span(raw), key_ops=one^)
    assert_true(a != b, "key_ops order ignored by ==")
    assert_true(a != c, "a present key_ops equal to an absent one")
    assert_true(c != a, "an absent key_ops equal to a present one")
    assert_true(a == d)
    assert_true(a != shorter, "a key_ops prefix compared equal")
    assert_true(shorter != a, "a key_ops prefix compared equal")


def main() raises:
    # Every test runs and every failure is reported.
    var failures = String("")
    try:
        test_key_ops_kept_in_order_and_rendered()
    except e:
        failures += String("test_key_ops_kept_in_order_and_rendered: ") + String(e) + "\n"
    try:
        test_malformed_key_ops_skips_the_key()
    except e:
        failures += String("test_malformed_key_ops_skips_the_key: ") + String(e) + "\n"
    try:
        test_constructor_checks_key_ops()
    except e:
        failures += String("test_constructor_checks_key_ops: ") + String(e) + "\n"
    try:
        test_key_ops_in_equality()
    except e:
        failures += String("test_key_ops_in_equality: ") + String(e) + "\n"
    if failures != "":
        print(failures)
        raise Error("test_jwk_key_ops: FAILED\n" + failures)
    print("test_jwk_key_ops: OK")
