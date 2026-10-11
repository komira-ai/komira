# =============================================================================
# komira_jose/thumbprint.mojo: the JWK thumbprint (RFC 7638) a signer uses
#   as its `kid`.
# =============================================================================
#
# RFC 7638 section 3: the SHA-256 of a JSON object holding only the key's
# required public members, named in lexicographic order, with no whitespace,
# then base64url without padding (43 characters):
#
#   EC   {"crv":"P-256","kty":"EC","x":"...","y":"..."}  (RFC 7638 3.2)
#   OKP  {"crv":"Ed25519","kty":"OKP","x":"..."}         (RFC 8037 2)
#   RSA  {"e":"...","kty":"RSA","n":"..."}               (RFC 7638 3.2)
#
# `kid`, `alg`, `use` and `key_ops` are not part of it, so the same key gives
# the same thumbprint however it is published. Every value written is a
# fixed name or base64url text: nothing needs escaping.
#
# ENCAPSULATION: a `Jwk` in, a `String` out. No pointer crosses this file's
# API, and every byte it reads is public key material.
# =============================================================================

from komira_crypto import sha256
from komira_encoding import base64_url_encode_nopad
from komira_jwks import JWK_KTY_EC, JWK_KTY_OKP, JWK_KTY_RSA, Jwk


def _member(name: String, value: String) -> String:
    return String('"') + name + '":"' + value + '"'


def _b64(b: List[UInt8]) -> String:
    return base64_url_encode_nopad(Span(b))


def thumbprint_input(key: Jwk) raises -> String:
    """The RFC 7638 JSON object hashed for `key`'s thumbprint. Raises
    `JoseError: ...` for a key type other than EC, OKP and RSA."""
    var kty = key.kty()
    if kty == JWK_KTY_EC:
        return (
            String("{")
            + _member("crv", key.crv())
            + ","
            + _member("kty", kty)
            + ","
            + _member("x", _b64(key.x()))
            + ","
            + _member("y", _b64(key.y()))
            + "}"
        )
    if kty == JWK_KTY_OKP:
        return (
            String("{")
            + _member("crv", key.crv())
            + ","
            + _member("kty", kty)
            + ","
            + _member("x", _b64(key.x()))
            + "}"
        )
    if kty == JWK_KTY_RSA:
        return (
            String("{")
            + _member("e", _b64(key.e()))
            + ","
            + _member("kty", kty)
            + ","
            + _member("n", _b64(key.n()))
            + "}"
        )
    raise Error("JoseError: the key type has no thumbprint here")


def jwk_thumbprint(key: Jwk) raises -> String:
    """The RFC 7638 SHA-256 thumbprint of `key`, base64url without padding.
    Raises as `thumbprint_input` does."""
    var digest = sha256(thumbprint_input(key).as_bytes())
    return base64_url_encode_nopad(Span[UInt8, origin_of(digest)](digest))
