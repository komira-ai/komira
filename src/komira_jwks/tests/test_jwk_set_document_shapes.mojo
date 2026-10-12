# =============================================================================
# test_jwk_set_document_shapes.mojo: parse_jwk_set on the document shapes
#   komira_crypto's old RS256 JWKS reader was tested against
#   (test_rs256_jwks_parser_edges), with real RSA-2048 keys.
# =============================================================================
#
# That reader walked the JSON by hand and answered "no keys" for a document
# it could not read. parse_jwk_set reads through komira_json and refuses the
# whole document instead (`JwksError: ...`), so each ported case asserts the
# refusal, or the key that must survive, rather than a key count of zero.
# Each test names the defect it catches.
#
# The RSA-2048 modulus is the Python `cryptography` key of komira_crypto's
# test_rsa_sign_verify_edges, published as the JWK "n".
#
# main runs every test and reports every failure, so that one build shows
# each planted mutant's test.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_jwks import JWKS_MAX_DOCUMENT_BYTES, JWKS_MAX_KEYS, parse_jwk_set


def _n_b64() -> String:
    return (
        "wdMz9mntb2b_cpv8UWE504dJY8bjS5vDCf6D9aDr3bKXEbekLzGpdbFxngaNoHc_6Sa1QoaF520ZBSOlRIIeKN_QDHwtpELy"
        + "RzewfyZe846VUBRKn_AznyQk5-AH-VgaInjSCn2LV_hOkC1IY4CRLteGnqw70wDr8zDB49m_iDjD3wCMeBm3RmKWrE60wSyz"
        + "GT5RPb2u0rYjZBsPaXdv9qLFaI7t9RU-bPjnsHLxslaLhDCcqzql3OlGP7WtwCMOWpvPoJBriZVNVukwNXz3MxXJ9JO7hJny"
        + "wp2_DI768BrLJiSw4i8zfybyp-Dmr7sXrM2Iv6WeFEi4Fup6gf0ZRw"
    )


def _jwk(kid: String) -> String:
    return String('{"kty":"RSA","kid":"') + kid + '","n":"' + _n_b64() + '","e":"AQAB"}'


def _one() -> String:
    return String("[") + _jwk("k1") + "]"


def _err(doc: String) -> String:
    try:
        _ = parse_jwk_set(doc)
    except e:
        return String(e)
    return String("")


def _json_refused(doc: String, what: String) raises:
    """`doc` is refused by the JSON reader, not read leniently."""
    var got = _err(doc)
    assert_true(got.startswith("JwksError: JsonError: "), what + ": got [" + got + "]")


def _kids(doc: String) raises -> String:
    """The kids parse_jwk_set accepts, comma-joined in document order."""
    var s = parse_jwk_set(doc)
    var out = String("")
    for i in range(len(s.keys)):
        if i > 0:
            out += ","
        out += s.keys[i].kid().value()
    return out^


# --- old parse_rsa_jwks top level; _object_string_members -------------------


def test_member_shapes_refused() raises:
    # Defect: a malformed member before "keys" skipped over, so a document
    # no conforming reader accepts still yields keys.
    assert_equal(_kids(String('{"keys":') + _one() + "}"), "k1", "baseline")
    _json_refused(String('{1:2,"keys":') + _one() + "}", "non-string member name")
    _json_refused(String('{"x" 1,"keys":') + _one() + "}", "member without a colon")
    _json_refused(String('{"x":,"keys":') + _one() + "}", "member with no value")
    _json_refused(String('{"x":"y";"keys":') + _one() + "}", "bad separator")
    _json_refused(String('{"x":"y"'), "end of input after a member")
    _json_refused(String('{"x":"y",'), "trailing comma at end of input")
    _json_refused(String('{"x":"y",}'), "trailing comma before the brace")
    _json_refused(String(""), "empty document")


def test_keys_member_located() raises:
    # Defect: "keys" looked up anywhere but the top level, or not at all
    # past other members; a missing "keys" read as an empty set.
    assert_equal(_err(String("[") + _jwk("k1") + "]"), "JwksError: a JWK Set is a JSON object")
    assert_equal(
        _kids(String('{"x":{"keys":[]},"y":"z" , "keys":') + _one() + "}"),
        "k1",
        "keys after skipped members, one of them holding a nested keys",
    )
    assert_equal(_err(String('{"x":1}')), 'JwksError: member "keys" is missing')
    assert_equal(_err(String("{ }")), 'JwksError: member "keys" is missing')


# --- old _skip_json_value and _read_json_string -----------------------------


def test_ignored_member_values() raises:
    # Defect: a value in an ignored member mis-skipped (an escaped quote or
    # a brace inside a string, a literal at a delimiter) or an unterminated
    # one accepted.
    var noise = String(
        '{"s":"x\\"}{[","a":[1,{"c":2}],"t":true,"n":null,"f":false,"num":-1.5e3, "w" :  7 ,"keys":'
    )
    assert_equal(_kids(noise + _one() + "}"), "k1", "every value kind skipped")
    _json_refused(String('{"x":{"a":1,"keys":') + _one() + "}", "unterminated object")
    _json_refused(String('{"x":[1,2,"keys":') + _one() + "}", "unterminated array")
    _json_refused(String('{"x":tru,"keys":') + _one() + "}", "truncated literal")


def test_string_reading() raises:
    # Defect: a raw control byte or an unterminated string accepted, or a
    # string's spaces or escapes read wrongly.
    _json_refused(String('{"x":"a\tb","keys":') + _one() + "}", "raw tab")
    _json_refused(String('{"x":"a\x01b","keys":') + _one() + "}", "raw 0x01")
    _json_refused(String('{"keys":') + _one() + ',"x":"abc', "unterminated string")
    assert_equal(_kids(String('{"keys":[') + _jwk(" a b") + "]}"), " a b", "spaces kept")
    # The old reader refused any backslash; JSON escapes are decoded now, so
    # the kid below is "k1".
    assert_equal(_kids(String('{"keys":[') + _jwk("k\\u0031") + "]}"), "k1", "escaped kid decoded")


# --- old parse_rsa_jwks array elements and caps -----------------------------


def test_array_elements() raises:
    # Defect: an element that is not an object skipped instead of refusing
    # the set, or a key missing "e" refusing the others.
    assert_equal(
        _err(String('{"keys":[1,') + _jwk("k1") + "]}"),
        "JwksError: key 0 is not a JSON object",
    )
    _json_refused(String('{"keys":[{"a" 1},') + _jwk("k1") + "]}", "malformed element")
    var no_e = String('{"kty":"RSA","kid":"k0","n":"') + _n_b64() + '"}'
    var s = parse_jwk_set(String('{"keys":[') + no_e + "," + _jwk("k1") + "]}")
    assert_equal(len(s.keys), 1, "key without e skipped, the other kept")
    assert_equal(s.keys[0].kid().value(), "k1")
    assert_equal(len(s.skipped), 1)
    assert_equal(s.skipped[0], 'key 0: member "e" is missing')


def test_key_cap_with_supported_keys() raises:
    # Defect: the cap off by one, or keys reordered. The old reader kept the
    # first 64 of 65; parse_jwk_set refuses 65.
    var body = String("")
    for i in range(JWKS_MAX_KEYS):
        if i > 0:
            body += ","
        body += _jwk("k" + String(i))
    var s = parse_jwk_set(String('{"keys":[') + body + "]}")
    assert_equal(len(s.keys), 64, "64 keys read")
    assert_equal(s.keys[0].kid().value(), "k0", "in document order")
    assert_equal(s.keys[63].kid().value(), "k63", "in document order")
    assert_equal(
        _err(String('{"keys":[') + body + "," + _jwk("k64") + "]}"),
        "JwksError: the set holds 65 keys; the limit is 64",
    )


def test_document_size_with_a_key() raises:
    # Defect: the size cap off by one, or padding to the limit losing the key.
    var doc = String('{"keys":[') + _jwk("k1") + "]}"
    doc += String(" ") * (JWKS_MAX_DOCUMENT_BYTES - doc.byte_length())
    assert_equal(doc.byte_length(), 262144, "padded to the limit")
    assert_equal(_kids(doc), "k1", "a document of exactly 262144 bytes is read")
    assert_equal(
        _err(doc + " "),
        "JwksError: document is 262145 bytes; the limit is 262144",
    )


def main() raises:
    var failures = String("")
    try:
        test_member_shapes_refused()
    except e:
        failures += String("test_member_shapes_refused: ") + String(e) + "\n"
    try:
        test_keys_member_located()
    except e:
        failures += String("test_keys_member_located: ") + String(e) + "\n"
    try:
        test_ignored_member_values()
    except e:
        failures += String("test_ignored_member_values: ") + String(e) + "\n"
    try:
        test_string_reading()
    except e:
        failures += String("test_string_reading: ") + String(e) + "\n"
    try:
        test_array_elements()
    except e:
        failures += String("test_array_elements: ") + String(e) + "\n"
    try:
        test_key_cap_with_supported_keys()
    except e:
        failures += String("test_key_cap_with_supported_keys: ") + String(e) + "\n"
    try:
        test_document_size_with_a_key()
    except e:
        failures += String("test_document_size_with_a_key: ") + String(e) + "\n"
    if failures != "":
        print(failures)
        raise Error("test_jwk_set_document_shapes: FAILED\n" + failures)
    print("test_jwk_set_document_shapes: OK")
