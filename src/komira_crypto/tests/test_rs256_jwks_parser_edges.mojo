# =============================================================================
# komira_crypto/tests/test_rs256_jwks_parser_edges.mojo
#
# The RS256 / JWKS module's hand-written JSON readers and the verifier steps
# the Google-shaped fixtures never reach:
#   * _read_json_string: not at a quote, any backslash, a raw control byte,
#     no closing quote; 0x20 is accepted;
#   * _skip_json_value: leading whitespace, end of input, a container whose
#     string holds an escaped quote and a brace, an unterminated container,
#     literals ending at , } ] or whitespace, an empty literal;
#   * _object_string_members and _object_has_member: each malformed shape
#     (not an object, empty object, non-string key, missing colon, nothing
#     after the colon, a bad value, end of input after a value, a bad
#     separator, a trailing comma) - the first refuses, the second answers
#     "present" whenever it cannot rule the member out;
#   * parse_rsa_jwks: a top level that is not an object, a malformed member
#     before "keys", other members skipped before and instead of "keys", an
#     array element that is not an object or is malformed, a key without
#     "e", and the 64-key cap;
#   * parse_rsa_jwks's size limit: an empty document, one of exactly
#     RS256_MAX_JWKS_BYTES (read) and one byte more (not read);
#   * verify_rs256_jws: a header segment that is not base64url or not an
#     object, a signature segment that is not base64url or one byte short,
#     an empty middle segment, four segments, a kid two
#     keys share, a kid no key has, and a correctly signed token whose payload
#     segment is not base64url (signed here with rsa_sha256_sign).
# The RSA-2048 key is the Python `cryptography` key of
# test_rsa_sign_verify_edges; its modulus is published as the JWK "n".
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_encoding import base64_url_encode_nopad
from komira_crypto.rsa import rsa_sha256_sign
from komira_crypto.rs256_jwks import (
    RsaJwk,
    parse_rsa_jwks,
    verify_rs256_jws,
    _read_json_string,
    _skip_json_value,
    _object_string_members,
    _object_has_member,
)


def _hex(s: String) -> List[UInt8]:
    var b = s.as_bytes()
    var out = List[UInt8]()
    for i in range(0, len(b), 2):
        var hi = Int(b[i])
        var lo = Int(b[i + 1])
        hi = hi - 48 if hi < 58 else hi - 87
        lo = lo - 48 if lo < 58 else lo - 87
        out.append(UInt8(hi * 16 + lo))
    return out^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for c in s.as_bytes():
        out.append(c)
    return out^


def _rsa_pkcs8_hex() -> String:
    return (
        "308204be020100300d06092a864886f70d0101010500048204a8308204a40201000282010100c1d333f669ed6f66ff72"
        + "9bfc516139d3874963c6e34b9bc309fe83f5a0ebddb29711b7a42f31a975b1719e068da0773fe926b5428685e76d1905"
        + "23a544821e28dfd00c7c2da442f24737b07f265ef38e9550144a9ff0339f2424e7e007f9581a2278d20a7d8b57f84e90"
        + "2d486380912ed7869eac3bd300ebf330c1e3d9bf8838c3df008c7819b7466296ac4eb4c12cb3193e513dbdaed2b62364"
        + "1b0f69776ff6a2c5688eedf5153e6cf8e7b072f1b2568b84309cab3aa5dce9463fb5adc0230e5a9bcfa0906b89954d56"
        + "e930357cf73315c9f493bb8499f2c29dbf0c8efaf01acb2624b0e22f337f26f2a7e0e6afbb17accd88bfa59e1448b816"
        + "ea7a81fd19470203010001028201004a174e19b7cc47757bd877c02feb968b417fd0604aaab0541211f4a78468254b0b"
        + "6c7e628897d74b6215286f20dc6239500ab7e7423d158622b65035f0c63c792b750010c7f1ae95a69ba72033aec03394"
        + "e81399a321d2d9d69b34f7f29462153b702bfa4e9b61794daed7608088b8f6caf46edb2fd32cdb050f724e83023033b7"
        + "0793be4779cd265446272cdd27ecf5f65ef4812673897a86a9c78ec5f58927f64bb0eaabd336044a05927d2b6582170c"
        + "adefd3110fc521d727f3a22c5564cb3d6b87fc007e1d589060d457cfc29b1eb2c90740c61afc4505c3e8331b89665d1a"
        + "a23a615ab398ce1026210f15f7eb81990300d1445eb9d3524d45b58918696102818100fdf81e77f6e841d57671aae0cb"
        + "b7d60048657b330197d8a1bc9b9f41a74c95edaa5089d1724665c4ed200ca0ecba2ffef9405f3b75387b5b67d62a52a6"
        + "557b0694f42c1262f6a6e87bdaa2b76461471d2b79efc044f104048849a93ae7b96210be44381af5fc866e01290bcbad"
        + "c42a2f42dd7577cf65c99755f7fa4218cf288502818100c35ff7a4a348383ffb04a362d46d6b7c0cd794999a7bc67971"
        + "6852ad88924641b5ea64c934e8962321533aece247e283e47454d2cb21dcd3b3c7097872a2d912e888a42c5bde725d37"
        + "93b0744755b36c8cff6ef5be5086c410a060f50dc3ed3624ec801b92a1932d18aa2a1c6d20b03e53e668fe2087da58f8"
        + "2ab5d27b1a8a5b02818100caac5344511a104f95722877b49b44807d45df075962205311fcef1ea9b00885ddc0dffaf1"
        + "4314bc0eafe0e41b8689fee45266ad40628eaee732961bd6f9a8701c36af650cece14dee6910296245ef466c07a738bc"
        + "cbc9f503fe24bb09697bc4f8d1e02443e1fe35935f7a3654b993209c2fb72aa1ac0d30643ebccc3a9837310281806716"
        + "7800b2f72456fe08107dd1407afa557c5ab841bf159676b4690b8f883ef1e51eec570e47bb108640f8528d83088e3738"
        + "fa98cefdeb1af93d084e398e9ba35276e6c951202a8fed074c8fce23f62c4ca96aced7c07d9b6e7a712e5c39092d0c86"
        + "8d81fef8aa439d440c3c3b8887f61b26f43742caebf70ddadb5d57ff450902818100b7378fc6d462ab6e14fd929755e3"
        + "393a082214c28a88be5ef11a9bcfab877aa5aa4f9f9b24e25bcebacd83a665fed93cd01496952332a0b5c5c897cf9947"
        + "913af28778278c301be967707b83f230c84edf18e7d1f47b71b5a910afc4f955d710744a241908f685b4ead3d12a0aa5"
        + "5c77c5497bfc0d12b355f41a44afe8080cca"
    )


def _n_b64() -> String:
    return (
        "wdMz9mntb2b_cpv8UWE504dJY8bjS5vDCf6D9aDr3bKXEbekLzGpdbFxngaNoHc_6Sa1QoaF520ZBSOlRIIeKN_QDHwtpELy"
        + "RzewfyZe846VUBRKn_AznyQk5-AH-VgaInjSCn2LV_hOkC1IY4CRLteGnqw70wDr8zDB49m_iDjD3wCMeBm3RmKWrE60wSyz"
        + "GT5RPb2u0rYjZBsPaXdv9qLFaI7t9RU-bPjnsHLxslaLhDCcqzql3OlGP7WtwCMOWpvPoJBriZVNVukwNXz3MxXJ9JO7hJny"
        + "wp2_DI768BrLJiSw4i8zfybyp-Dmr7sXrM2Iv6WeFEi4Fup6gf0ZRw"
    )


def _jwk(kid: String) -> String:
    return String('{"kty":"RSA","kid":"') + kid + '","n":"' + _n_b64() + '","e":"AQAB"}'


# -----------------------------------------------------------------------------
# _read_json_string
# -----------------------------------------------------------------------------


def _rs(text: String, start: Int) -> Int:
    var b = _bytes(text)
    return _read_json_string(Span(b), start)[0]


def test_read_json_string() raises:
    assert_equal(_rs("", 0), -1, "empty input")
    assert_equal(_rs("x", 0), -1, "not at a quote")
    assert_equal(_rs('"ab"', 4), -1, "start past the end")
    assert_equal(_rs('"a\\"b"', 0), -1, "backslash escape")
    assert_equal(_rs('"a\tb"', 0), -1, "raw tab")
    assert_equal(_rs('"a\x01b"', 0), -1, "raw 0x01")
    assert_equal(_rs('"abc', 0), -1, "no closing quote")
    var b = _bytes('" a b"x')
    var r = _read_json_string(Span(b), 0)
    assert_equal(r[0], 6, "index after the closing quote")
    assert_equal(r[1], String(" a b"), "spaces kept")


# -----------------------------------------------------------------------------
# _skip_json_value
# -----------------------------------------------------------------------------


def _sk(text: String) -> Int:
    var b = _bytes(text)
    return _skip_json_value(Span(b), 0)


def test_skip_json_value() raises:
    assert_equal(_sk("  \t\r\n123"), 8, "whitespace then a number")
    assert_equal(_sk("   "), -1, "only whitespace")
    var nested = String('{"a":"x\\"}","b":[1,{"c":2}]}')
    assert_equal(_sk(nested + ",rest"), nested.byte_length(), "escaped quote and brace in a string")
    assert_equal(_sk('{"a":1'), -1, "unterminated object")
    assert_equal(_sk('[1,2'), -1, "unterminated array")
    assert_equal(_sk("123,"), 3, "number ends at ,")
    assert_equal(_sk("true}"), 4, "literal ends at }")
    assert_equal(_sk("null]"), 4, "literal ends at ]")
    assert_equal(_sk("false x"), 5, "literal ends at whitespace")
    assert_equal(_sk(",1"), -1, "empty literal")


# -----------------------------------------------------------------------------
# _object_string_members / _object_has_member
# -----------------------------------------------------------------------------


def _om(text: String) -> Int:
    var b = _bytes(text)
    return _object_string_members(Span(b), 0)[0]


def _has(text: String) -> Bool:
    var b = _bytes(text)
    return _object_has_member(Span(b), 0, String("crit"))


def test_object_string_members() raises:
    assert_equal(_om("[1]"), -1, "not an object")
    assert_equal(_om("{ }"), 3, "empty object")
    assert_equal(_om("{1:2}"), -1, "non-string key")
    assert_equal(_om('{"a" 1}'), -1, "missing colon")
    assert_equal(_om('{"a": '), -1, "nothing after the colon")
    assert_equal(_om('{"a":"x\\y"}'), -1, "bad string value")
    assert_equal(_om('{"a":,}'), -1, "bad non-string value")
    assert_equal(_om('{"a":1'), -1, "end of input after a value")
    assert_equal(_om('{"a":"b";}'), -1, "bad separator")
    assert_equal(_om('{"a":"b",'), -1, "trailing comma at end of input")
    var b = _bytes('{"a":1,"b":"c" , "d":[2]}')
    var r = _object_string_members(Span(b), 0)
    assert_equal(r[0], len(b), "whole object read")
    assert_equal(len(r[1]), 1, "only the string member recorded")
    assert_equal(r[1][0][0], String("b"), "its name")
    assert_equal(r[1][0][1], String("c"), "its value")


def test_object_has_member() raises:
    assert_true(_has("[]"), "not an object: assume present")
    assert_false(_has("{ }"), "empty object")
    assert_true(_has("{1:2}"), "non-string key")
    assert_true(_has('{"a" 1}'), "missing colon")
    assert_true(_has('{"a":}'), "bad value")
    assert_true(_has('{"a":1'), "end of input after a value")
    assert_true(_has('{"a":1,'), "trailing comma at end of input")
    assert_true(_has('{"a":"b";}'), "bad separator after a string")
    assert_true(_has('{"a":1,"crit":["b64"]}'), "present with an array value")
    assert_false(_has('{"a":1,"b":{"crit":1}}'), "absent at the top level")


# -----------------------------------------------------------------------------
# parse_rsa_jwks
# -----------------------------------------------------------------------------


def _count(doc: String) -> Int:
    return len(parse_rsa_jwks(doc))


def test_parse_top_level_shapes() raises:
    var one = String('[') + _jwk("k1") + "]"
    assert_equal(_count(String('{"keys":') + one + "}"), 1, "baseline")
    assert_equal(_count(String("[") + _jwk("k1") + "]"), 0, "top level is an array")
    assert_equal(_count(String('{1:2,"keys":') + one + "}"), 0, "non-string member name")
    assert_equal(_count(String('{"x" 1,"keys":') + one + "}"), 0, "member without a colon")
    assert_equal(_count(String('{"x":,"keys":') + one + "}"), 0, "member with no value")
    assert_equal(_count(String('{"x":"y";"keys":') + one + "}"), 0, "bad separator")
    assert_equal(_count(String('{"x":"y"')), 0, "end of input after a member")
    assert_equal(_count(String('{"x":{"keys":[]},"y":"z" , "keys":') + one + "}"), 1, "keys after skipped members")
    assert_equal(_count(String('{"x":1}')), 0, "no keys member")
    assert_equal(_count(String('{ }')), 0, "empty object")


def test_parse_document_size_limits() raises:
    assert_equal(_count(String("")), 0, "empty document")
    var doc = String('{"keys":[') + _jwk("k1") + "]}"
    while doc.byte_length() < 262144:
        doc += " "
    assert_equal(doc.byte_length(), 262144, "padded to the limit")
    assert_equal(_count(doc), 1, "a document of exactly 262144 bytes is read")
    doc += " "
    assert_equal(_count(doc), 0, "one byte over the limit is not read")


def test_parse_array_elements() raises:
    assert_equal(_count(String('{"keys":[1,') + _jwk("k1") + "]}"), 0, "element not an object")
    assert_equal(_count(String('{"keys":[{"a" 1},') + _jwk("k1") + "]}"), 0, "malformed element")
    var no_e = String('{"kty":"RSA","kid":"k0","n":"') + _n_b64() + '"}'
    assert_equal(_count(String('{"keys":[') + no_e + "," + _jwk("k1") + "]}"), 1, "key without e skipped")


def test_parse_caps_at_64_keys() raises:
    var doc = String('{"keys":[')
    for i in range(65):
        if i > 0:
            doc += ","
        doc += _jwk("k" + String(i))
    doc += "]}"
    var keys = parse_rsa_jwks(doc)
    assert_equal(len(keys), 64, "65 keys published, 64 read")
    assert_equal(keys[63].kid, String("k63"), "the first 64 in order")


# -----------------------------------------------------------------------------
# verify_rs256_jws
# -----------------------------------------------------------------------------


def _b64(s: String) -> String:
    return base64_url_encode_nopad(s.as_bytes())


def _signed(header_json: String, payload_seg: String) raises -> String:
    var key = _hex(_rsa_pkcs8_hex())
    var signing_input = _b64(header_json) + "." + payload_seg
    var sig = rsa_sha256_sign(Span(key), signing_input.as_bytes())
    return signing_input + "." + base64_url_encode_nopad(Span(sig))


def _keys(*kids: String) -> List[RsaJwk]:
    var doc = String('{"keys":[')
    for i in range(len(kids)):
        if i > 0:
            doc += ","
        doc += _jwk(kids[i])
    doc += "]}"
    return parse_rsa_jwks(doc)


def test_segments() raises:
    var keys = _keys("k1")
    assert_false(Bool(verify_rs256_jws(String("a..c"), keys)), "empty payload segment")
    assert_false(Bool(verify_rs256_jws(String("a.b.c.d"), keys)), "four segments")


def test_header_and_signature_segments() raises:
    var keys = _keys("k1")
    var hdr = _b64('{"alg":"RS256","kid":"k1"}')
    var payload = _b64("{}")
    var sig255 = List[UInt8]()
    for _ in range(255):
        sig255.append(0x01)
    assert_false(Bool(verify_rs256_jws(String("!!.") + payload + ".AAAA", keys)), "header not base64url")
    assert_false(Bool(verify_rs256_jws(_b64("[1]") + "." + payload + ".AAAA", keys)), "header not an object")
    assert_false(Bool(verify_rs256_jws(hdr + "." + payload + ".!!", keys)), "signature not base64url")
    assert_false(
        Bool(verify_rs256_jws(hdr + "." + payload + "." + base64_url_encode_nopad(Span(sig255)), keys)),
        "255-byte signature for a 256-byte modulus",
    )


def test_kid_selection_and_payload_decoding() raises:
    var hdr = String('{"alg":"RS256","kid":"k1"}')
    var good = _signed(hdr, _b64("{}"))
    var keys = _keys("k1")
    var out = verify_rs256_jws(good, keys)
    assert_true(Bool(out), "the signed token verifies")
    assert_equal(out.value(), String("{}"), "its payload")
    assert_false(Bool(verify_rs256_jws(good, _keys("k1", "k1"))), "kid shared by two keys")
    assert_false(Bool(verify_rs256_jws(good, _keys("k2"))), "kid no key has")
    # A valid signature over a payload segment that is not base64url.
    var bad_payload = _signed(hdr, String("e3!!"))
    assert_false(Bool(verify_rs256_jws(bad_payload, keys)), "undecodable payload")


def main() raises:
    test_read_json_string()
    test_skip_json_value()
    test_object_string_members()
    test_object_has_member()
    test_parse_top_level_shapes()
    test_parse_document_size_limits()
    test_parse_array_elements()
    test_parse_caps_at_64_keys()
    test_segments()
    test_header_and_signature_segments()
    test_kid_selection_and_payload_decoding()
    print("test_rs256_jwks_parser_edges: 11 tests PASS")
