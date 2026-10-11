# =============================================================================
# komira_jose — verify JSON Web Signatures (RFC 7515) and JSON Web Tokens
#   (RFC 7519) with exactly one algorithm per verifier: ES256, EdDSA
#   (Ed25519, RFC 8037) or RS256 (RFC 7518).
# =============================================================================
#
#   * `JwsVerifier(alg, keys)` — one pinned algorithm and a `komira_jwks`
#     JWK Set; the token's `kid` selects the key. `JwsVerifier.single_key`
#     takes one configured key instead (verifier.mojo).
#   * `JwsVerifier.verify(token)` — the header gate (header.mojo: `none`,
#     `HS*`, any other algorithm, `jwk`, `jku`, `x5u`, `x5c` and `crit`
#     refused before any key work), the key checks and the signature; returns
#     the authentic payload as a `VerifiedJws`.
#   * `ClaimPolicy` and `verify_jwt(token, verifier, policy)` — the same,
#     with the header `typ` pinned to one type and `kid` required, then
#     `iss`, `aud`, `sub`, `exp`, `iat`, `nbf` and the lifetime checked
#     (claims.mojo); returns a `VerifiedJwt`.
#
# Every refusal raises `JoseError: <fixed text>`; no text carries any byte
# of the token. It does not sign, fetch key sets or cache them.
#
# Dep closure: `komira_crypto` (ECDSA P-256, Ed25519 and RSA PKCS#1 v1.5
# verify), `komira_encoding` (base64url), `komira_json` (the strict parser and
# the duplicate-member check), `komira_jwks` (the keys) and what they need
# (`komira_secret_store`).
# =============================================================================

from komira_jose.header import JWS_MAX_COMPACT_BYTES
from komira_jose.verifier import (
    JWS_ALG_EDDSA,
    JWS_ALG_ES256,
    JWS_ALG_RS256,
    JwsVerifier,
    VerifiedJws,
)
from komira_jose.claims import (
    JOSE_MAX_LEEWAY_S,
    JOSE_MAX_TTL_S,
    JWT_TYP_AT_JWT,
    JWT_TYP_JWT,
    ClaimPolicy,
    VerifiedJwt,
    verify_jwt,
)
