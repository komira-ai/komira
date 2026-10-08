# =============================================================================
# test_jwk_set_strict.mojo: every REFUSED, SKIPPED and IGNORED rule of
# jwk_set.mojo, the checked constructors of jwk.mojo, and rendering of
# arbitrary string members. Each test names the defect it catches.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_encoding import base64_url_encode_nopad
from komira_jwks import (
    JWKS_MAX_DOCUMENT_BYTES,
    JWKS_MAX_KEYS,
    Jwk,
    parse_jwk,
    parse_jwk_set,
    render_jwk,
    render_jwk_set,
)


comptime PRIVATE_SUFFIX = "; a published key holds public members only"


def _b64(n: Int, fill: UInt8) -> String:
    var b = List[UInt8]()
    for _ in range(n):
        b.append(fill)
    return base64_url_encode_nopad(Span(b))


def _okp(kid: String) -> String:
    return (
        String('{"kty":"OKP","crv":"Ed25519","kid":"')
        + kid
        + '","x":"'
        + _b64(32, 7)
        + '"}'
    )


def _ec(crv: String, coord_bytes: Int) -> String:
    return (
        String('{"kty":"EC","crv":"')
        + crv
        + '","x":"'
        + _b64(coord_bytes, 1)
        + '","y":"'
        + _b64(coord_bytes, 2)
        + '"}'
    )


def _rsa(n: String, e: String) -> String:
    return String('{"kty":"RSA","n":"') + n + '","e":"' + e + '"}'


def _set(keys: String) -> String:
    return String('{"keys":[') + keys + "]}"


def _err_of_set(doc: String) -> String:
    try:
        _ = parse_jwk_set(doc)
    except e:
        return String(e)
    return String("")


def _skipped_only(doc: String) raises -> String:
    """The one skip reason of a one-key set that skips its key."""
    var s = parse_jwk_set(doc)
    assert_equal(len(s.keys), 0, "the key was accepted")
    assert_equal(len(s.skipped), 1)
    return s.skipped[0]


# --- REFUSED -----------------------------------------------------------------


def test_duplicate_member_refuses_the_document() raises:
    # Defect: a key whose "x" appears twice is read with the first value.
    var doc = (
        String('{"keys":[{"kty":"OKP","crv":"Ed25519","x":"')
        + _b64(32, 1)
        + '","x":"'
        + _b64(32, 2)
        + '"}]}'
    )
    assert_equal(
        _err_of_set(doc),
        "JwksError: JsonError: duplicate object key 'x' at line 1",
    )
    assert_equal(
        _err_of_set(String('{"keys":[],"keys":[') + _okp("a") + "]}"),
        "JwksError: JsonError: duplicate object key 'keys' at line 1",
    )


def test_size_cap_boundary() raises:
    # Defect: an unbounded document is read, or the limit is off by one.
    var base = String('{"keys":[]}')
    var pad = String(" ") * (JWKS_MAX_DOCUMENT_BYTES - base.byte_length())
    var at_limit = base + pad
    assert_equal(at_limit.byte_length(), JWKS_MAX_DOCUMENT_BYTES)
    assert_equal(len(parse_jwk_set(at_limit).keys), 0)
    assert_equal(
        _err_of_set(at_limit + " "),
        "JwksError: document is 262145 bytes; the limit is 262144",
    )


def test_key_count_boundary() raises:
    # Defect: an unbounded keys array is walked, or the limit is off by one.
    var keys = String("")
    for i in range(JWKS_MAX_KEYS):
        if i > 0:
            keys += ","
        keys += '{"kty":"unknown"}'
    var s = parse_jwk_set(_set(keys))
    assert_equal(len(s.skipped), JWKS_MAX_KEYS)
    assert_equal(
        _err_of_set(_set(keys + ',{"kty":"unknown"}')),
        "JwksError: the set holds 65 keys; the limit is 64",
    )


def test_every_private_member_refused() raises:
    # Defect: a set leaking private material is used (or one name is missed).
    var names = List[String]()
    names.append(String("d"))
    names.append(String("p"))
    names.append(String("q"))
    names.append(String("dp"))
    names.append(String("dq"))
    names.append(String("qi"))
    names.append(String("oth"))
    names.append(String("k"))
    for i in range(len(names)):
        var doc = _set(
            _okp("a")
            + ',{"kty":"OKP","crv":"Ed25519","x":"'
            + _b64(32, 3)
            + '","'
            + names[i]
            + '":"AA"}'
        )
        assert_equal(
            _err_of_set(doc),
            String("JwksError: key 1 carries the private member \"")
            + names[i]
            + '"'
            + PRIVATE_SUFFIX,
        )


def test_private_member_refused_even_on_an_unsupported_key() raises:
    # Defect: the private check runs only on keys that are otherwise accepted.
    assert_equal(
        _err_of_set(_set('{"kty":"EC","crv":"P-521","d":"AA"}')),
        String("JwksError: key 0 carries the private member \"d\"")
        + PRIVATE_SUFFIX,
    )


def test_duplicate_kid_refused() raises:
    # Defect: two keys answer to one kid, so selection by kid is ambiguous.
    assert_equal(
        _err_of_set(_set(_okp("same") + "," + _okp("other") + "," + _okp("same"))),
        "JwksError: kid \"same\" names two keys",
    )
    # A key with no kid anywhere in the set must not end either comparison:
    # ahead of the pair (the outer loop), between the pair (the inner loop)
    # or after it. Kid-less keys sit in every one of those positions here.
    var nokid = _ec("P-256", 32)
    assert_equal(
        _err_of_set(_set(nokid + "," + _okp("same") + "," + _okp("same"))),
        "JwksError: kid \"same\" names two keys",
    )
    assert_equal(
        _err_of_set(_set(_okp("same") + "," + nokid + "," + _okp("same"))),
        "JwksError: kid \"same\" names two keys",
    )
    assert_equal(
        _err_of_set(
            _set(
                nokid + "," + _okp("same") + "," + nokid + "," + _okp("same")
                + "," + nokid
            )
        ),
        "JwksError: kid \"same\" names two keys",
    )
    # Keys of different types under one kid are just as ambiguous: the
    # check compares kids across the whole set, not within one key type.
    var ec_k = (
        String('{"kty":"EC","crv":"P-256","kid":"k","x":"')
        + _b64(32, 1)
        + '","y":"'
        + _b64(32, 2)
        + '"}'
    )
    var rsa_k = (
        String('{"kty":"RSA","kid":"k","n":"') + _b64(256, 0xC5) + '","e":"AQAB"}'
    )
    assert_equal(
        _err_of_set(_set(ec_k + "," + rsa_k)),
        "JwksError: kid \"k\" names two keys",
    )


def test_skipped_key_sharing_a_kid_is_not_a_duplicate() raises:
    # The duplicate-kid check compares accepted keys only. A P-384 key
    # skipped from the set does not make a P-256 key under the same kid
    # ambiguous: a verifier can select only the accepted one. Defect caught:
    # a check that also counts skipped keys, which would let one unsupported
    # key a reader is told to ignore (RFC 7517 section 5) refuse the set.
    var p384 = (
        String('{"kty":"EC","crv":"P-384","kid":"k","x":"')
        + _b64(48, 1)
        + '","y":"'
        + _b64(48, 2)
        + '"}'
    )
    var p256 = (
        String('{"kty":"EC","crv":"P-256","kid":"k","x":"')
        + _b64(32, 1)
        + '","y":"'
        + _b64(32, 2)
        + '"}'
    )
    var s = parse_jwk_set(_set(p384 + "," + p256))
    assert_equal(len(s.keys), 1)
    assert_equal(s.keys[0].crv(), "P-256")
    assert_equal(s.keys[0].kid().value(), "k")
    assert_equal(len(s.skipped), 1)
    assert_equal(s.skipped[0], "key 0: EC curve \"P-384\" is not supported (P-256 is)")


def test_structure_refused() raises:
    assert_equal(_err_of_set("[]"), "JwksError: a JWK Set is a JSON object")
    assert_equal(_err_of_set("{}"), "JwksError: member \"keys\" is missing")
    assert_equal(
        _err_of_set('{"keys":{}}'), "JwksError: member \"keys\" is not an array"
    )
    assert_equal(
        _err_of_set('{"keys":["x"]}'), "JwksError: key 0 is not a JSON object"
    )
    assert_equal(
        _err_of_set('{"keys":[}'),
        "JwksError: JsonError: unexpected character at the start of a value"
        " at line 1, byte column 10",
    )


# --- SKIPPED -----------------------------------------------------------------


def test_p384_key_skipped_from_a_p256_set() raises:
    # Defect: an EC key of another curve enters the set. The second case has
    # 32-byte coordinates, so only the curve check keeps it out.
    var s = parse_jwk_set(
        _set(_ec("P-384", 48) + "," + _ec("P-384", 32) + "," + _ec("P-256", 32))
    )
    assert_equal(len(s.keys), 1)
    assert_equal(s.keys[0].crv(), "P-256")
    assert_equal(len(s.skipped), 2)
    assert_equal(s.skipped[0], "key 0: EC curve \"P-384\" is not supported (P-256 is)")
    assert_equal(s.skipped[1], "key 1: EC curve \"P-384\" is not supported (P-256 is)")


def test_unsupported_keys_do_not_hide_the_others() raises:
    # RFC 7517 section 5: a key this reader does not understand is ignored.
    var s = parse_jwk_set(
        _set('{"kty":"oct-like"},' + _okp("k1") + ',{"kty":"OKP","crv":"X25519","x":"AA"}')
    )
    assert_equal(len(s.keys), 1)
    assert_equal(s.keys[0].kid().value(), "k1")
    assert_equal(
        s.skipped[0], "key 0: kty \"oct-like\" is not supported (OKP, EC and RSA are)"
    )
    assert_equal(
        s.skipped[1], "key 2: OKP curve \"X25519\" is not supported (Ed25519 is)"
    )


def test_malformed_members_skipped() raises:
    assert_equal(
        _skipped_only(_set('{"crv":"Ed25519"}')), "key 0: member \"kty\" is missing"
    )
    assert_equal(
        _skipped_only(_set('{"kty":"OKP","crv":"Ed25519"}')),
        "key 0: member \"x\" is missing",
    )
    assert_equal(
        _skipped_only(_set('{"kty":"EC","x":"AA","y":"AA"}')),
        "key 0: member \"crv\" is missing",
    )
    assert_equal(
        _skipped_only(_set('{"kty":"OKP","crv":"Ed25519","x":7}')),
        "key 0: member \"x\" is not a string",
    )
    assert_equal(
        _skipped_only(_set(String('{"kty":"OKP","crv":"Ed25519","kid":1,"x":"') + _b64(32, 1) + '"}')),
        "key 0: member \"kid\" is not a string",
    )
    assert_equal(
        _skipped_only(_set(String('{"kty":"OKP","crv":"Ed25519","kid":"","x":"') + _b64(32, 1) + '"}')),
        "key 0: member \"kid\" is empty",
    )
    # Padding, and a standard-alphabet symbol, are not base64url without padding.
    assert_equal(
        _skipped_only(_set('{"kty":"OKP","crv":"Ed25519","x":"AA=="}')),
        "key 0: member \"x\" is not base64url without padding",
    )
    assert_equal(
        _skipped_only(_set('{"kty":"OKP","crv":"Ed25519","x":"A+A"}')),
        "key 0: member \"x\" is not base64url without padding",
    )
    assert_equal(
        _skipped_only(_set(String('{"kty":"OKP","crv":"Ed25519","x":"') + _b64(31, 1) + '"}')),
        "key 0: member \"x\" is 31 bytes; Ed25519 needs 32",
    )
    assert_equal(
        _skipped_only(_set(String('{"kty":"EC","crv":"P-256","x":"') + _b64(32, 1) + '","y":"' + _b64(33, 1) + '"}')),
        "key 0: member \"y\" is 33 bytes; P-256 needs 32",
    )


def test_rsa_ranges_skipped() raises:
    var n2048 = _b64(256, 0xC5)
    assert_equal(len(parse_jwk_set(_set(_rsa(n2048, "AQAB"))).keys), 1)
    assert_equal(
        _skipped_only(_set(_rsa(_b64(255, 0xC5), "AQAB"))),
        "key 0: RSA modulus is 2040 bits; supported are 2048 to 4096",
    )
    assert_equal(len(parse_jwk_set(_set(_rsa(_b64(512, 0xC5), "AQAB"))).keys), 1)
    assert_equal(
        _skipped_only(_set(_rsa(_b64(513, 0xC5), "AQAB"))),
        "key 0: RSA modulus is 4104 bits; supported are 2048 to 4096",
    )
    # A leading zero byte is a second spelling of the same integer.
    var padded = List[UInt8]()
    padded.append(0)
    for _ in range(256):
        padded.append(0xC5)
    assert_equal(
        _skipped_only(_set(_rsa(base64_url_encode_nopad(Span(padded)), "AQAB"))),
        "key 0: member \"n\" is not a minimal Base64urlUInt (empty or a leading"
        " zero byte)",
    )
    assert_equal(
        _skipped_only(_set(_rsa(n2048, "AAEAAQ"))),
        "key 0: member \"e\" is not a minimal Base64urlUInt (empty or a leading"
        " zero byte)",
    )
    assert_equal(
        _skipped_only(_set(_rsa(n2048, "AQAA"))),
        "key 0: RSA exponent must be odd and at least 3",
    )
    assert_equal(
        _skipped_only(_set(_rsa(n2048, "AQ"))),
        "key 0: RSA exponent must be odd and at least 3",
    )
    assert_equal(len(parse_jwk_set(_set(_rsa(n2048, "Aw"))).keys), 1)
    assert_equal(
        _skipped_only(_set(_rsa(n2048, _b64(9, 1)))),
        "key 0: RSA exponent is 9 bytes; at most 8",
    )


# --- IGNORED -----------------------------------------------------------------


def test_unknown_members_ignored() raises:
    var doc = _set(
        String('{"x5c":["MIIB"],"key_ops":["verify"],"ext":{"a":1},')
        + '"kty":"OKP","crv":"Ed25519","x":"'
        + _b64(32, 9)
        + '","kid":"k"}'
    )
    var s = parse_jwk_set(doc)
    assert_equal(len(s.keys), 1)
    assert_equal(
        render_jwk(s.keys[0]),
        String('{"kty":"OKP","crv":"Ed25519","kid":"k","x":"') + _b64(32, 9) + '"}',
    )
    # Still checked for duplicates, at any depth.
    assert_equal(
        _err_of_set(_set('{"ext":{"a":1,"a":2},"kty":"OKP"}')),
        "JwksError: JsonError: duplicate object key 'a' at line 1",
    )


# --- parse_jwk ---------------------------------------------------------------


def test_parse_jwk_raises_what_a_set_skips() raises:
    var got = String("")
    try:
        _ = parse_jwk(_ec("P-384", 48))
    except e:
        got = String(e)
    assert_equal(got, "JwksError: EC curve \"P-384\" is not supported (P-256 is)")
    got = String("")
    try:
        _ = parse_jwk("[]")
    except e:
        got = String(e)
    assert_equal(got, "JwksError: a JWK is a JSON object")


# --- constructors and render -------------------------------------------------


def test_constructors_check() raises:
    var short = List[UInt8]()
    for _ in range(31):
        short.append(1)
    var ok = List[UInt8]()
    for _ in range(32):
        ok.append(1)
    var got = String("")
    try:
        _ = Jwk.ed25519(Span(short))
    except e:
        got = String(e)
    assert_equal(got, "JwksError: member \"x\" is 31 bytes; Ed25519 needs 32")
    got = String("")
    try:
        _ = Jwk.ec_p256(Span(ok), Span(short))
    except e:
        got = String(e)
    assert_equal(got, "JwksError: member \"y\" is 31 bytes; P-256 needs 32")
    got = String("")
    try:
        var ok2 = ok.copy()
        _ = Jwk.rsa(Span(ok), Span(ok2))
    except e:
        got = String(e)
    assert_equal(got, "JwksError: RSA modulus is 256 bits; supported are 2048 to 4096")
    got = String("")
    try:
        _ = Jwk.ed25519(Span(ok), kid=Optional[String](String("")))
    except e:
        got = String(e)
    assert_equal(got, "JwksError: member \"kid\" is empty")
    got = String("")
    try:
        var ok_y = ok.copy()
        _ = Jwk.ec_p256(Span(ok), Span(ok_y), kid=Optional[String](String("")))
    except e:
        got = String(e)
    assert_equal(got, "JwksError: member \"kid\" is empty")
    var n2048 = List[UInt8]()
    for _ in range(256):
        n2048.append(0xC5)
    var e3 = List[UInt8]()
    e3.append(1)
    e3.append(0)
    e3.append(1)
    got = String("")
    try:
        _ = Jwk.rsa(Span(n2048), Span(e3), kid=Optional[String](String("")))
    except e:
        got = String(e)
    assert_equal(got, "JwksError: member \"kid\" is empty")


def test_constructed_keys_round_trip() raises:
    var c = List[UInt8]()
    for i in range(32):
        c.append(UInt8(i))
    var c2 = c.copy()
    var n = List[UInt8]()
    for _ in range(256):
        n.append(0xC5)
    var e = List[UInt8]()
    e.append(1)
    e.append(0)
    e.append(1)
    var keys = List[Jwk]()
    # A kid with a quote, a backslash and a newline: rendered escaped, and
    # read back to the same string.
    keys.append(Jwk.ed25519(Span(c), kid=Optional[String](String('a"b\\c\nd'))))
    keys.append(
        Jwk.ec_p256(
            Span(c),
            Span(c2),
            kid=Optional[String](String("ec")),
            alg=Optional[String](String("ES256")),
            key_use=Optional[String](String("sig")),
        )
    )
    keys.append(Jwk.rsa(Span(n), Span(e), kid=Optional[String](String("rsa"))))
    var doc = render_jwk_set(keys)
    assert_true('"kid":"a\\"b\\\\c\\nd"' in doc, doc)
    var s = parse_jwk_set(doc)
    assert_equal(len(s.keys), 3)
    for i in range(3):
        assert_true(s.keys[i] == keys[i], String("key ") + String(i))
    assert_true(s.keys[0] != s.keys[1])
    assert_equal(s.render(), doc)


def main() raises:
    test_duplicate_member_refuses_the_document()
    test_size_cap_boundary()
    test_key_count_boundary()
    test_every_private_member_refused()
    test_private_member_refused_even_on_an_unsupported_key()
    test_duplicate_kid_refused()
    test_skipped_key_sharing_a_kid_is_not_a_duplicate()
    test_structure_refused()
    test_p384_key_skipped_from_a_p256_set()
    test_unsupported_keys_do_not_hide_the_others()
    test_malformed_members_skipped()
    test_rsa_ranges_skipped()
    test_unknown_members_ignored()
    test_parse_jwk_raises_what_a_set_skips()
    test_constructors_check()
    test_constructed_keys_round_trip()
    print("test_jwk_set_strict: OK")
