# =============================================================================
# test_wycheproof_jws.mojo: Wycheproof's JSON Web Signature corpus
#   (json_web_signature_test.json, //third_party/wycheproof, pinned by sha256)
#   through verifiers pinned to each of ES256, EdDSA and RS256.
# =============================================================================
#
# The corpus has 401 vectors in 23 groups (HS256, ES256, RS256/384/512,
# PS256/384/512, the RFC 7520 examples, keys meant for encryption, base64
# edge cases, special-case ES256 signatures), each group with the public JWK
# its vectors are checked against (none for the HMAC groups).
#
# For each vector and each pinned algorithm P:
#   * the group key is parsed with komira_jwks and a verifier is built from a
#     one-key set. If the key does not suit P (another type, `alg`, a `use`
#     other than `sig`, `key_ops` without `verify`), no verifier exists and
#     the vector counts as refused: that is the verifier's own refusal;
#   * a group without a key (HMAC) is run through a verifier holding an
#     unrelated key of P's type, so its tokens still meet the header gate.
#   * EXPECTED: the vector verifies if and only if Wycheproof marks it valid,
#     its group key's `alg` is ES256 or RS256, and P is that algorithm.
#
# Exactly ten vectors verify, each under its own algorithm only: tcId 18 and
# 378 (ES256); 33, 259 to 263, 345 and 349 (RS256; 345 and 349 are RFC 7520
# figure 13). Every other vector, Wycheproof-valid HMAC, PS* and ES512 ones
# included, is refused under all three. Two refusals are also pinned to their
# header-gate reason: tcId 32 (an attacker's key embedded as `jwk`) and tcId 31
# (HS256 signed with the EC key's bytes).
# =============================================================================

from std.testing import assert_equal

from komira_encoding import base64_url_decode_nopad
from komira_jose import JwsVerifier
from komira_json import JSON_OBJECT, JsonValue, parse_json_value
from komira_jwks import Jwk, JwkSet, parse_jwk


comptime CORPUS = "wycheproof/json_web_signature_test.json"
comptime CORPUS_TESTS = 401
comptime EXPECTED_ACCEPTS = 10


def _pins() -> List[String]:
    var out = List[String]()
    out.append("ES256")
    out.append("EdDSA")
    out.append("RS256")
    return out^


def _member(v: JsonValue, name: String) raises -> Optional[JsonValue]:
    if v.kind != JSON_OBJECT or not v.has(name):
        return Optional[JsonValue]()
    return Optional[JsonValue](v.get(name))


def _fallback_key(pin: String) raises -> Jwk:
    """An unrelated key of `pin`'s type: RFC 7515 A.3 (ES256), RFC 8037 A.2
    (EdDSA), RFC 7517 A.1's RSA modulus with e = 65537 (RS256)."""
    if pin == "ES256":
        var x = base64_url_decode_nopad("f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU")
        var y = base64_url_decode_nopad("x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0")
        return Jwk.ec_p256(Span(x), Span(y), kid=String("kid-ec-sign"))
    if pin == "EdDSA":
        var x = base64_url_decode_nopad("11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo")
        return Jwk.ed25519(Span(x), kid=String("kid-okp"))
    var n = List[UInt8]()
    n.append(0xC1)
    for _ in range(255):
        n.append(0x5B)
    var e = List[UInt8]()
    e.append(1)
    e.append(0)
    e.append(1)
    return Jwk.rsa(Span(n), Span(e), kid=String("kid-rsa-sign"))


def _verifier(key: Optional[Jwk], pin: String) raises -> Optional[JwsVerifier]:
    var keys = List[Jwk]()
    if key:
        keys.append(key.value().copy())
    else:
        keys.append(_fallback_key(pin))
    try:
        return Optional[JwsVerifier](
            JwsVerifier(pin, JwkSet(keys^, List[String]()))
        )
    except:
        return Optional[JwsVerifier]()


def _reason(v: Optional[JwsVerifier], token: String) -> String:
    """"" when the token verifies; the refusal text otherwise."""
    if not v:
        return "no verifier: the group key does not suit the algorithm"
    try:
        _ = v.value().verify(token)
    except e:
        return String(e)
    return ""


def test_corpus() raises:
    var doc: String
    with open(CORPUS, "r") as f:
        doc = f.read()
    var root = parse_json_value(doc, 32)
    var groups = root.get("testGroups")
    var pins = _pins()
    var seen = 0
    var accepts = 0
    var failures = String("")
    var accepted_ids = String("")
    for gi in range(groups.array_len()):
        var g = groups.element_at(gi)
        var pub = _member(g, "public")
        var key = Optional[Jwk]()
        var key_alg = String("")
        if pub and pub.value().kind == JSON_OBJECT:
            try:
                key = Optional[Jwk](parse_jwk(pub.value().serialize()))
            except:
                pass
            var a = _member(pub.value(), "alg")
            if a:
                key_alg = a.value().as_string()
        var verifiers = List[Optional[JwsVerifier]]()
        for p in range(len(pins)):
            verifiers.append(_verifier(key, pins[p]))
        var tests = g.get("tests")
        for ti in range(tests.array_len()):
            var t = tests.element_at(ti)
            seen += 1
            var id = String(t.get("tcId").as_int64())
            var token = t.get("jws").as_string()
            var valid = t.get("result").as_string() == "valid"
            for p in range(len(pins)):
                var want = (
                    valid
                    and Bool(key)
                    and (key_alg == "ES256" or key_alg == "RS256")
                    and pins[p] == key_alg
                )
                var why = _reason(verifiers[p], token)
                var got = why == ""
                if got:
                    accepts += 1
                    accepted_ids += id + " " + pins[p] + "; "
                if got != want:
                    failures += (
                        String("tcId ")
                        + id
                        + " under "
                        + pins[p]
                        + (String(": accepted") if got else String(": refused: ") + why)
                        + "\n"
                    )
                if id == "32" and pins[p] == "ES256":
                    assert_equal(
                        why,
                        String("JoseError: header member jwk is refused: the key")
                        + " never comes from the token",
                    )
                if id == "31" and pins[p] == "ES256":
                    assert_equal(why, "JoseError: an HMAC alg (HS*) is refused")
    assert_equal(seen, CORPUS_TESTS, "the corpus did not run in full")
    assert_equal(failures, "", "Wycheproof vectors disagree:\n" + failures)
    assert_equal(accepts, EXPECTED_ACCEPTS, "accepted: " + accepted_ids)


def main() raises:
    test_corpus()
    print("test_wycheproof_jws: OK")
