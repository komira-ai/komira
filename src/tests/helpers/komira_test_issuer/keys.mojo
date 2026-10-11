# =============================================================================
# komira_test_issuer/keys.mojo: the test issuer's signing keys, derived from
#   a seed so that a test run is reproducible.
# =============================================================================
#
# `derived_key(alg, seed, index)` is the `JwsSigner` of key number `index`
# of `seed`: the 32 bytes are SHA-256 of
#
#   "komira_test_issuer " + alg + " " + String(index) + " " + seed
#
# used as the P-256 scalar (ES256) or the Ed25519 seed (EdDSA). The same
# inputs give the same key and so the same `kid` (the RFC 7638 thumbprint,
# komira_jose); another seed, index or algorithm gives another key. A digest
# that is not a P-256 scalar from 1 to n - 1 (a chance of about 2^-32) is
# refused by `JwsSigner.es256`, and the refusal reaches the caller: choose
# another seed. RS256 keys are not derived (an RSA key is not a hash
# output). These keys are for tests only: anyone who reads the seed can sign.
#
# Every refusal raises `TestIssuerError: <fixed text>`.
#
# ENCAPSULATION: `String` and `Int` in, `JwsSigner` out. No pointer crosses
# this file's API.
# =============================================================================

from komira_crypto import sha256
from komira_jose import JWS_ALG_EDDSA, JWS_ALG_ES256, JwsSigner
from komira_secret_store import SecretValue


def derived_key(alg: String, seed: String, index: Int) raises -> JwsSigner:
    """Key number `index` of `seed` under `alg` (see the file header).
    Raises `TestIssuerError: ...` for an empty seed, a negative index, or an
    algorithm other than ES256 and EdDSA, and `JoseError: ...` when the digest
    is not a P-256 scalar."""
    if seed.byte_length() == 0:
        raise Error("TestIssuerError: the key seed is empty")
    if index < 0:
        raise Error("TestIssuerError: the key index is negative")
    var label = (
        String("komira_test_issuer ") + alg + " " + String(index) + " " + seed
    )
    var digest = sha256(label.as_bytes())
    var d = List[UInt8](length=32, fill=UInt8(0))
    for i in range(32):
        d[i] = digest[i]
    if alg == JWS_ALG_ES256:
        return JwsSigner.es256(SecretValue(Span(d)))
    if alg == JWS_ALG_EDDSA:
        return JwsSigner.eddsa(SecretValue(Span(d)))
    raise Error("TestIssuerError: the test issuer derives ES256 and EdDSA keys only")
