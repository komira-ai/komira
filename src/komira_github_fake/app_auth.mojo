# =============================================================================
# komira_github_fake/app_auth.mojo -- how the fake checks an App JWT.
# =============================================================================
#
# The fake holds only the App's PUBLIC key, as GitHub does. An App JWT is
# accepted when it is three base64url segments; its header is JSON with no
# repeated member and `alg` exactly `RS256`; its claims are JSON with no
# repeated member, integer `iat` and `exp` and a string `iss` equal to the
# App's issuer; its RS256 signature verifies under the App's key; and
# komira_github's `check_app_jwt_window` accepts its times at the fake's
# clock (so an expired JWT, one issued in the future, and one spanning or
# reaching more than 10 minutes are refused, as GitHub refuses them).
# =============================================================================

from komira_crypto import rsa_pkcs1_sha256_verify
from komira_crypto.cert.asn1 import der_parse_integer_to_bytes, der_parse_tlv
from komira_encoding import base64_url_decode_nopad
from komira_github import check_app_jwt_window
from komira_json import JSON_STRING, JsonValue, parse_json_bytes, refuse_duplicate_keys


struct FakeAppPublicKey(Copyable, Movable, Deinitable):
    """An RSA public key: the big-endian modulus and the exponent."""

    var n: List[UInt8]
    var e: UInt64

    def __init__(out self, var n: List[UInt8], e: UInt64):
        self.n = n^
        self.e = e


def _strip_leading_zeros(b: List[UInt8]) -> List[UInt8]:
    var start = 0
    while start < len(b) - 1 and b[start] == UInt8(0):
        start += 1
    var out = List[UInt8]()
    for i in range(start, len(b)):
        out.append(b[i])
    return out^


def app_public_key_from_pkcs8(pkcs8_der: List[UInt8]) raises -> FakeAppPublicKey:
    """The public half of a PKCS#8 RSA PrivateKeyInfo (RFC 5208: SEQUENCE {
    version, algorithm, OCTET STRING { RSAPrivateKey SEQUENCE { version,
    n, e, ... } } }), so a test can give the fake the key its client signs
    with."""
    var der = Span[UInt8, origin_of(pkcs8_der)](pkcs8_der)
    var outer = der_parse_tlv(der, 0)
    var version = der_parse_tlv(der, outer.value_pos)
    var algorithm = der_parse_tlv(der, version.end_pos)
    var octets = der_parse_tlv(der, algorithm.end_pos)
    var rsa_key = der_parse_tlv(der, octets.value_pos)
    var rsa_version = der_parse_tlv(der, rsa_key.value_pos)
    var n = der_parse_tlv(der, rsa_version.end_pos)
    var e = der_parse_tlv(der, n.end_pos)
    var n_bytes = _strip_leading_zeros(
        der_parse_integer_to_bytes(der[n.value_pos : n.value_pos + n.value_len])
    )
    var e_bytes = _strip_leading_zeros(
        der_parse_integer_to_bytes(der[e.value_pos : e.value_pos + e.value_len])
    )
    if len(e_bytes) > 8:
        raise Error("FakeGitHub: the RSA exponent does not fit 64 bits")
    var e_value: UInt64 = 0
    for i in range(len(e_bytes)):
        e_value = (e_value << 8) | UInt64(e_bytes[i])
    return FakeAppPublicKey(n_bytes^, e_value)


def _segment_json(seg: String) raises -> JsonValue:
    var raw = base64_url_decode_nopad(seg)
    var doc = parse_json_bytes(raw)
    refuse_duplicate_keys(doc)
    return doc^


def _integral(doc: JsonValue, key: String) raises -> Int64:
    var v = doc.get(key)
    if not v.is_integral_number():
        raise Error(key + " is not an integer")
    return v.as_int64()


def check_app_jwt(
    token: String, issuer: String, key: FakeAppPublicKey, now_unix_s: Int64
) raises:
    """Raises (with GitHub-like text, never the token) unless `token` is an
    App JWT the App holding `key` signed for `issuer` and valid at
    `now_unix_s` (module header)."""
    var b = token.as_bytes()
    var dots = List[Int]()
    for i in range(len(b)):
        if b[i] == UInt8(ord(".")):
            dots.append(i)
    if len(dots) != 2:
        raise Error("A JSON web token could not be decoded")
    var h = String(token[byte=0 : dots[0]])
    var p = String(token[byte = dots[0] + 1 : dots[1]])
    var s = String(token[byte = dots[1] + 1 : token.byte_length()])
    var header: JsonValue
    var claims: JsonValue
    var sig: List[UInt8]
    try:
        header = _segment_json(h)
        claims = _segment_json(p)
        sig = base64_url_decode_nopad(s)
    except:
        raise Error("A JSON web token could not be decoded")
    var alg = header.get(String("alg"))
    if alg.kind_tag() != JSON_STRING or alg.as_string() != "RS256":
        raise Error("the JWT alg is not RS256")
    var iss = claims.get(String("iss"))
    if iss.kind_tag() != JSON_STRING or iss.as_string() != issuer:
        raise Error("'Issuer' claim ('iss') is not this App")
    var iat = _integral(claims, String("iat"))
    var exp = _integral(claims, String("exp"))
    var signing_input = h + String(".") + p
    if not rsa_pkcs1_sha256_verify(
        Span[UInt8, origin_of(key.n)](key.n),
        key.e,
        signing_input.as_bytes(),
        Span[UInt8, origin_of(sig)](sig),
    ):
        raise Error("the JWT signature does not verify under the App's key")
    check_app_jwt_window(iat, exp, now_unix_s)
