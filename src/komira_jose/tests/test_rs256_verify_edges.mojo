# =============================================================================
# test_rs256_verify_edges.mojo: the verifier steps komira_crypto's old RS256
#   JWKS verifier was tested against (test_rs256_jwks_parser_edges), on a
#   JwsVerifier pinned to RS256 with a real RSA-2048 key.
# =============================================================================
#
# Tokens are signed here with komira_crypto's rsa_sha256_sign (the Python
# `cryptography` key of test_rsa_sign_verify_edges, whose modulus is the
# JWK "n"), so a token the verifier should accept does verify
# (test_signed_token_verifies) and each refusal below is the step it names,
# not a signature failure in disguise.
#
# The old verifier answered "no payload" for every failure; JwsVerifier
# raises a fixed `JoseError: ...` text per step, asserted exactly here.
#
# main runs every test and reports every failure, so that one build shows
# each planted mutant's test.
# =============================================================================

from std.testing import assert_equal

from komira_crypto import rsa_sha256_sign
from komira_encoding import base64_url_encode_nopad
from komira_jose import JwsVerifier
from komira_jwks import Jwk, JwkSet, parse_jwk_set


comptime THREE = "JoseError: a compact JWS has exactly three segments"
comptime NOT_JSON = "JoseError: the header is not JSON"
comptime LEN = "JoseError: the signature has the wrong length"
comptime CRIT = "JoseError: header member crit is refused: no extension is understood"
comptime GOOD = '{"alg":"RS256","kid":"k1"}'


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


def _b64(s: String) -> String:
    return base64_url_encode_nopad(s.as_bytes())


def _bytes(n: Int, fill: UInt8) -> List[UInt8]:
    var out = List[UInt8]()
    for _ in range(n):
        out.append(fill)
    return out^


def _signed(header_json: String, payload_seg: String) raises -> String:
    var key = _hex(_rsa_pkcs8_hex())
    var signing_input = _b64(header_json) + "." + payload_seg
    var sig = rsa_sha256_sign(Span(key), signing_input.as_bytes())
    return signing_input + "." + base64_url_encode_nopad(Span(sig))


def _set(*kids: String) raises -> JwkSet:
    var doc = String('{"keys":[')
    for i in range(len(kids)):
        if i > 0:
            doc += ","
        doc += _jwk(kids[i])
    doc += "]}"
    return parse_jwk_set(doc)


def _err_with(keys: JwkSet, token: String) raises -> String:
    var v = JwsVerifier("RS256", keys)
    try:
        _ = v.verify(token)
    except e:
        return String(e)
    return String("")


def _err(token: String) raises -> String:
    return _err_with(_set("k1"), token)


def _set_err(doc: String) -> String:
    try:
        _ = parse_jwk_set(doc)
    except e:
        return String(e)
    return String("")


def test_signed_token_verifies() raises:
    # Defect: a signing helper or verifier that never accepts, which would
    # make every refusal below vacuous.
    var got = JwsVerifier("RS256", _set("k1")).verify(_signed(GOOD, _b64("{}")))
    var p = got.payload()
    assert_equal(len(p), 2)
    assert_equal(p[0], UInt8(0x7B))
    assert_equal(got.kid().value(), "k1")


def test_segments() raises:
    # Defect: four segments accepted, or a signed empty payload refused.
    # The old verifier refused an empty middle segment; RFC 7515 appendix F
    # allows it, and JwsVerifier verifies it.
    assert_equal(_err(String("a.b.c.d")), THREE)
    assert_equal(_err(_signed(GOOD, _b64("{}")) + ".x"), THREE)
    var empty = JwsVerifier("RS256", _set("k1")).verify(_signed(GOOD, ""))
    assert_equal(len(empty.payload()), 0, "signed empty payload")


def test_header_and_signature_segments() raises:
    # Defect: a header or signature segment that is not base64url read
    # anyway, a header that is not an object accepted, or a signature one
    # byte off the 256-byte modulus handed to the primitive.
    var hdr = _b64(GOOD)
    var payload = _b64("{}")
    assert_equal(
        _err(String("!!.") + payload + ".AAAA"),
        "JoseError: the header segment is not base64url without padding",
    )
    assert_equal(
        _err(_b64("[1]") + "." + payload + ".AAAA"),
        "JoseError: the header is not a JSON object",
    )
    assert_equal(
        _err(hdr + "." + payload + ".!!"),
        "JoseError: the signature segment is not base64url without padding",
    )
    var dot = hdr + "." + payload + "."
    assert_equal(_err(dot + base64_url_encode_nopad(Span(_bytes(255, 1)))), LEN)
    assert_equal(_err(dot + base64_url_encode_nopad(Span(_bytes(257, 1)))), LEN)
    assert_equal(
        _err(dot + base64_url_encode_nopad(Span(_bytes(256, 1)))),
        "JoseError: the signature does not verify",
    )


def test_header_member_shapes() raises:
    # Defect: crit missed at the top level, refused when only nested, or a
    # malformed header read leniently. The old reader answered "crit present"
    # whenever it could not rule crit out; the header is now refused as not
    # JSON before any member is looked at.
    assert_equal(_err(_signed('{"alg":"RS256","kid":"k1","crit":["b64"]}', _b64("{}"))), CRIT)
    var nested = JwsVerifier("RS256", _set("k1")).verify(
        _signed('{"alg":"RS256","kid":"k1","b":{"crit":1}}', _b64("{}"))
    )
    assert_equal(nested.kid().value(), "k1", "crit nested in another member")
    assert_equal(
        _err(_signed("{ }", _b64("{}"))),
        "JoseError: header alg is missing or not a string",
    )
    var bad = List[String]()
    bad.append(String("{1:2}"))
    bad.append(String('{"a" 1}'))
    bad.append(String('{"a":}'))
    bad.append(String('{"a":1'))
    bad.append(String('{"a":1,'))
    bad.append(String('{"a":"b";}'))
    for i in range(len(bad)):
        assert_equal(_err(_signed(bad[i], _b64("{}"))), NOT_JSON, bad[i])


def test_kid_selection_and_payload_decoding() raises:
    # Defect: a kid that two keys share answered with one of them, a kid no
    # key has answered by another key, or an undecodable payload returned.
    var good = _signed(GOOD, _b64("{}"))
    # A parsed set cannot hold two keys under one kid...
    assert_equal(
        _set_err(String('{"keys":[') + _jwk("k1") + "," + _jwk("k1") + "]}"),
        'JwksError: kid "k1" names two keys',
    )
    # ...and the verifier refuses a set built around the parser that does.
    var one = _set("k1")
    var twice = List[Jwk]()
    twice.append(one.keys[0].copy())
    twice.append(one.keys[0].copy())
    assert_equal(
        _err_with(JwkSet(twice^, List[String]()), good),
        "JoseError: kid names two keys in the set",
    )
    assert_equal(_err_with(_set("k2"), good), "JoseError: kid names no key in the set")
    # A valid signature over a payload segment that is not base64url.
    assert_equal(
        _err(_signed(GOOD, String("e3!!"))),
        "JoseError: the payload segment is not base64url without padding",
    )


def main() raises:
    var failures = String("")
    try:
        test_signed_token_verifies()
    except e:
        failures += String("test_signed_token_verifies: ") + String(e) + "\n"
    try:
        test_segments()
    except e:
        failures += String("test_segments: ") + String(e) + "\n"
    try:
        test_header_and_signature_segments()
    except e:
        failures += String("test_header_and_signature_segments: ") + String(e) + "\n"
    try:
        test_header_member_shapes()
    except e:
        failures += String("test_header_member_shapes: ") + String(e) + "\n"
    try:
        test_kid_selection_and_payload_decoding()
    except e:
        failures += String("test_kid_selection_and_payload_decoding: ") + String(e) + "\n"
    if failures != "":
        print(failures)
        raise Error("test_rs256_verify_edges: FAILED\n" + failures)
    print("test_rs256_verify_edges: OK")
