# =============================================================================
# komira_jose — sign and verify JSON Web Signatures (RFC 7515) and JSON Web
#   Tokens (RFC 7519) with exactly one algorithm per signer or verifier:
#   ES256, EdDSA (Ed25519, RFC 8037) or RS256 (RFC 7518).
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
#
# The sign half:
#
#   * `JwsSigner.es256` / `.eddsa` / `.rs256` — one private key, moved in as
#     a `SecretValue`, under one algorithm; `kid` is the key's RFC 7638
#     thumbprint (`jwk_thumbprint`, thumbprint.mojo) and `sign(payload, typ)`
#     writes the compact JWS (signer.mojo).
#   * `Keyring` — one algorithm's keys over time: `rotate` stages a key,
#     `render_jwks` publishes it, `promote` lets it sign only after it was
#     published, `retire` removes a former key only after the max token TTL
#     plus the leeway, and `sign` refuses a token that would outlive that
#     (keyring.mojo).
#   * `mint_assertion` / `mint_client_assertion` and `verify_assertion` /
#     `verify_client_assertion` — RFC 7523 JWT bearer assertions, each with
#     a random `jti`, which the verifier requires (assertion.mojo).
#
# Every refusal raises `JoseError: <fixed text>`; no text carries any byte
# of the token or of a key. It does not fetch key sets, cache them, or
# remember `jti`s.
#
# Dep closure: `komira_crypto` (ECDSA P-256, Ed25519 and RSA PKCS#1 v1.5
# sign and verify, SHA-256, the random source, the DER reader),
# `komira_encoding` (base64url), `komira_json` (the strict parser, the
# duplicate-member check and the writers), `komira_jwks` (the keys) and
# `komira_secret_store` (the private keys).
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
from komira_jose.thumbprint import jwk_thumbprint, thumbprint_input
from komira_jose.signer import JwsSigner
from komira_jose.keyring import (
    JOSE_KEYRING_MAX_RETIRING,
    JOSE_MAX_PUBLISH_LEAD_S,
    Keyring,
)
from komira_jose.assertion import (
    JOSE_ASSERTION_MAX_TTL_S,
    JOSE_JTI_BYTES,
    VerifiedAssertion,
    assertion_claims,
    mint_assertion,
    mint_client_assertion,
    new_jti,
    verify_assertion,
    verify_client_assertion,
)
