# =============================================================================
# komira_crypto/rsa.mojo — RSA-SHA256 sign + RS256 verify via AWS-LC FFI
# =============================================================================
#
# `rsa_sha256_sign` is a thin re-export of rsa_sha256_sign_ffi (AWS-LC
# d2i_PrivateKey + EVP_DigestSign).
#
# Public surface:
#   * rsa_sha256_sign(pkcs8_der_key, message) raises -> List[UInt8]
#   * rsa_pkcs1_sha256_verify(...) -> Bool (below)
#
# A GCS OAuth2 service-account JWT is signed with this symbol.
# =============================================================================

from komira_crypto.internal.asm.rsa_sign_ffi import rsa_sha256_sign_ffi


def rsa_sha256_sign(
    pkcs8_der_key: Span[UInt8, _], message: Span[UInt8, _]
) raises -> List[UInt8]:
    """RSA-SHA256 (PKCS#1 v1.5) sign `message` with a PKCS#8-DER private key.

    Uses AWS-LC's d2i_PrivateKey + EVP_DigestSign* path. RFC 7518 §3.3
    RS256 algorithm signing for GCP OAuth2 JWTs.
    """
    return rsa_sha256_sign_ffi(pkcs8_der_key, message)


# =============================================================================
# RS256 VERIFY.
#
# The PKCS#1 v1.5 scheme RFC 7518 names RS256 — distinct from
# `rsa_pss.rsa_pss_verify` (PSS, used for X.509 chains). Verifying e.g. a
# Google metadata-server ID token stands on this primitive.
#
# ⛔ THIS IS NOT A KEY-TYPE WIDENING OF ANY EXISTING VERIFIER. It is the
# primitive under komira_jose's RS256 `JwsVerifier`, one pinned algorithm per
# verifier and per trust anchor. A service's own identity tokens stay behind
# that service's own (e.g. ES256-only) verifier.
# =============================================================================

from komira_crypto.sha256 import sha256
from komira_crypto.internal.asm.rsa_ffi import rsa_pkcs1_sha256_verify_ffi


def rsa_pkcs1_sha256_verify(
    n_be: Span[UInt8, _],
    e_value: UInt64,
    message: Span[UInt8, _],
    signature: Span[UInt8, _],
) -> Bool:
    """RSASSA-PKCS1-v1_5-SHA-256 (RFC 8017 §8.2.2 / RFC 7518 §3.3 **RS256**)
    verify of `signature` over `message` under the public key `(n_be, e_value)`.

    Does NOT raise: a wrong-length signature, a malformed key, an OOM in the FFI
    layer and a genuinely bad signature all collapse to `False`. There is
    deliberately no error channel — a caller must not be able to tell those apart
    from the outside, and every one of them means "did not verify".

    ⚠ THE KEY IS AN INPUT, NOT A TRUST DECISION. This says the bytes were signed
    by whoever holds the private half of `(n_be, e_value)`. It says NOTHING about
    whether that key should be trusted; establishing that is the caller's job
    (for a platform attestation: fetching the JWKS from the issuer's own
    well-known URL over TLS, and selecting by `kid`, as komira_jose does).

    Args:
        n_be: The RSA modulus, big-endian, unpadded-to-its-own-length (256 bytes
            for a 2048-bit key). This is the form a JWK `n` member decodes to.
        e_value: The public exponent (65537 for every key in practice).
        message: The bytes that were signed. For a JWS this is the ASCII signing
            input `base64url(header) || "." || base64url(payload)`.
        signature: The signature bytes. MUST be exactly `len(n_be)` long.

    Returns:
        True iff the signature verifies.
    """
    var digest = sha256(message)
    return rsa_pkcs1_sha256_verify_ffi(
        n_be,
        e_value,
        Span[UInt8, origin_of(digest)](digest),
        signature,
    )
