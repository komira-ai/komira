# =============================================================================
# komira_http_auth/testing.mojo: fixtures for tests of code that uses this
#   package: sign an RS256 compact JWS with a test key, and publish that key
#   as a JWK Set.
# =============================================================================
#
# Tests of a bearer-JWT path need tokens whose signatures are VALID over
# hostile headers and claims; a token whose header was swapped after signing
# is refused by the signature check whatever the header gate does, so it
# proves nothing about the gate. These two functions make such tokens from a
# PKCS#8 RSA key (for example one read through komira_crypto's
# `rsa_pkcs8_der_from_pem`) with no network and no outside tool.
#
# Signing is komira_crypto's `rsa_sha256_sign`; the public half is read from
# the PKCS#8 DER with komira_crypto's ASN.1 reader. Nothing here verifies.
# =============================================================================

from komira_crypto import rsa_sha256_sign
from komira_crypto.cert.asn1 import der_parse_integer_to_bytes, der_parse_tlv
from komira_encoding import base64_url_encode_nopad


def sign_rs256_compact(
    header_json: String, payload_json: String, pkcs8_der: List[UInt8]
) raises -> String:
    """`b64url(header_json) . b64url(payload_json) . b64url(RS256 signature)`,
    signed over exactly those first two segments. The JSON texts are used
    verbatim, so a test can sign a header with a repeated key or any other
    shape it wants refused."""
    var h = base64_url_encode_nopad(Span(header_json.as_bytes()))
    var p = base64_url_encode_nopad(Span(payload_json.as_bytes()))
    var signing_input = h + String(".") + p
    var sig = rsa_sha256_sign(
        Span[UInt8, origin_of(pkcs8_der)](pkcs8_der), signing_input.as_bytes()
    )
    return (
        signing_input
        + String(".")
        + base64_url_encode_nopad(Span[UInt8, origin_of(sig)](sig))
    )


def _strip_leading_zeros(var b: List[UInt8]) -> List[UInt8]:
    var start = 0
    while start < len(b) - 1 and b[start] == UInt8(0):
        start += 1
    var out = List[UInt8]()
    for i in range(start, len(b)):
        out.append(b[i])
    return out^


def rsa_public_jwk_parts(pkcs8_der: List[UInt8]) raises -> Tuple[String, String]:
    """The base64url `n` and `e` of the RSA key in a PKCS#8 PrivateKeyInfo
    (RFC 5208: SEQUENCE { version, algorithm, OCTET STRING { RSAPrivateKey
    SEQUENCE { version, n, e, ... } } })."""
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
    return (
        base64_url_encode_nopad(Span[UInt8, origin_of(n_bytes)](n_bytes)),
        base64_url_encode_nopad(Span[UInt8, origin_of(e_bytes)](e_bytes)),
    )


def rsa_jwk_json(pkcs8_der: List[UInt8], kid: String) raises -> String:
    """One RSA JWK object (`kty`, `alg` RS256, `use` sig, `kid`, `n`, `e`)
    for the public half of `pkcs8_der`."""
    var ne = rsa_public_jwk_parts(pkcs8_der)
    return (
        String('{"kty":"RSA","alg":"RS256","use":"sig","kid":"')
        + kid
        + String('","n":"')
        + ne[0]
        + String('","e":"')
        + ne[1]
        + String('"}')
    )


def rsa_jwks_json(pkcs8_der: List[UInt8], kid: String) raises -> String:
    """A JWK Set publishing the public half of `pkcs8_der` under `kid`."""
    return String('{"keys":[') + rsa_jwk_json(pkcs8_der, kid) + String("]}")
